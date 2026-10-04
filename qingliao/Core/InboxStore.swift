import Foundation
import Observation

/// v3.0.82：Hermes 主动推送给轻聊App 的收件箱（本地轮询版）。
///
/// 背景：App 是「App 主动请求 → 服务端响应」模型，服务端没法主动往 App 塞消息。
/// 本 Store 轮询后端 /api/inbox（Hermes 主动推的消息队列），拉到就：
///   1. 注入当前聊天会话（assistant 角色，isPush 标记 → 气泡显示「🔔 推送」标签）
///   2. 弹本地通知（侧载 App 无 APNs，只能本地通知）
///   3. 标记已读（POST /api/inbox/{id}/done），防重复显示
///
/// 方案B 取舍：消息直接进当前聊天会话（改动小），代价是会随会话历史一起进
/// 模型上下文（下轮发消息全带进去）——用户已确认接受此取舍。
@MainActor
@Observable
final class InboxStore {
    static let shared = InboxStore()

    private var auth: AuthStore?
    private weak var chat: ChatStore?
    private weak var stream: StreamClient?
    var lastError: String?
    var lastInjectedCount = 0

    /// 已注入的消息 id（本地防重复——App 前后台频繁轮询，done 标记有网络延迟）
    /// v3.0.84fix：持久化到 UserDefaults（原纯内存 Set，App 重启丢 → 未 markDone 的推送会重复注入+重复通知）
    private var consumedIds: Set<String>
    /// v3.0.x fix：按插入顺序记录 id，用于清理时保留最近的而非按字典序（字典序会丢掉最近的 id）
    private var consumedOrder: [String] = []
    private var pollingTask: Task<Void, Never>?
    private let consumedKey = "qingliao_inbox_consumed_ids"
    /// v3.9.76（用户规则：进度要按时间前后推）：**按来源任务分组**的最后一条进度快照。
    /// 用途：迟到的旧快照（投递层重投导致）必须丢弃——见 `InboxProgressOrder`。
    /// 只存内存：App 重启后为空 → 重启后第一条进度无条件接受（本来也没有累积的旧快照要防），
    /// 跨重启的兜底走会话里「15 分钟内最后一条进度气泡」（见 consumeOne）。
    private var progressSnapshots: [String: InboxProgressOrder.Snapshot] = [:]

    /// v4.0.11：**已经落地最终回复**的任务 id（source_task_id）。
    /// 用途：任务落地后到达的同任务进度快照全是残片，必须丢弃 —— 否则会注入到列表末尾，
    /// 排在完整回复**下面**（用户 2026-09-30 实报：「AI 已经完整回复了，推送的反而还在完整回复后」）。
    /// 只存内存：重启后靠「本机流式已收尾」这条判据兜着。
    private var finishedProgressTasks: Set<String> = []

    /// 推送轮询间隔（秒）。App 前台持续轮询；后台系统会冻结 task。
    /// v3.0.x fix：流式结束后临时缩短间隔快速拉取（1s），3 轮后恢复默认 5s
    var pollInterval: Double = 5
    /// 流式结束后剩余快拉轮数
    private var fastPollRemaining = 0

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: "qingliao_inbox_consumed_ids") ?? []
        consumedIds = Set(saved)
        // 恢复插入顺序（字典序保存的旧数据无法精确恢复，用 sorted 兜底）
        consumedOrder = saved.isEmpty ? saved : Array(consumedIds).sorted()
    }

    /// v4.0.x：把一条主动 Agent 消息落进固定主动会话「轻聊主动」。
    ///
    /// 🚫 刻意**不**用 `chat.loadById(...)` 来"切到那个会话再 append" ——
    /// `load()` 会整体替换 ChatStore 的 messages/sessionId，用户正看着的对话会被当场清空。
    /// 注入必须对当前内存态**无感**。
    ///
    /// 落库职责在**后端**，不在这里：`inbox_api.push(task_type="agent")` 已经调用
    /// `sessions_api.append_proactive_message()` 把这条消息写进「轻聊主动」了
    /// （本轮 v4.0.x 给后端加的分支，已实测落库成功）。App 侧只负责**让气泡可见**：
    ///   ① 用户此刻正停在「轻聊主动」里 → 直接 append（气泡实时出现）；
    ///   ② 停在别的会话（常见）→ 什么都不做，**绝不碰 ChatStore 内存态**。
    ///      用户切过去时 `loadById` 从 NAS 读到的就是后端已落库的那条。
    ///
    /// ⚠️ 这里刻意**不做** App 侧写库：App 对 /api/sessions 的唯一写入口是 merge（全量上传），
    /// 拿它追加一条就得先拉全量再整体覆盖，既多余又有把「用户回复」被空数组冲掉的风险
    /// （投递壳 v3.9.72 踩过，后端为此单独维护 _CLIENT_WINS_IDS）。
    private func injectToProactiveSession(_ msg: ChatMessage) {
        guard let chat, chat.sessionId == ChatStore.proactiveSessionId else { return }
        chat.append(msg)
        lastInjectedCount += 1
    }

    private func consume(_ id: String) {
        guard !consumedIds.contains(id) else { return }
        consumedIds.insert(id)
        consumedOrder.append(id)
        // 只保留最近 200 个去重 id（防无限增长；远大于队列上限 100）
        if consumedOrder.count > 200 {
            let dropped = consumedOrder.prefix(consumedOrder.count - 200)
            for old in dropped { consumedIds.remove(old) }
            consumedOrder = Array(consumedOrder.suffix(200))
        }
        UserDefaults.standard.set(Array(consumedIds), forKey: consumedKey)
    }

    /// 注入依赖（QingliaoApp .task 调用，与 PinStore.shared.attach 一致）
    func attach(auth: AuthStore, chat: ChatStore, stream: StreamClient? = nil) {
        self.auth = auth
        self.chat = chat
        self.stream = stream
    }

    /// v4.0.11：主动 Agent 消息「有用/没用」→ POST /api/agent/proactive/feedback
    /// + 就地把该条切终态并落库。
    ///
    /// 口径与 answerQuestion 刻意一致：**先本地落地再走网络**。反馈是「一次性的表态」，
    /// 网络失败不该让用户再点一次（重复点 = 采纳率被计两次，阈值学歪）；
    /// 失败时**不回滚**本地态（用户确实表过态了），只打日志——服务端丢一次反馈
    /// 代价远小于「用户点了但界面像没反应」。
    /// @param verdict 只能 "adopted"（有用）/ "ignored"（没用），与后端白名单一致
    func sendProactiveFeedback(messageId: String, proactiveId: String, verdict: String) async {
        guard verdict == "adopted" || verdict == "ignored", let auth else { return }
        // 已表过态就不重复提交（采纳率只能计一次）
        guard (chat?.proactiveVerdictOf(messageId: messageId) ?? "").isEmpty else { return }
        chat?.markProactiveVerdict(messageId: messageId, verdict: verdict)
        do {
            let d = try await auth.json("/api/agent/proactive/feedback", method: "POST",
                                        body: ["id": proactiveId, "verdict": verdict])
            // 后端这个端点失败时同样是 HTTP 200 + ok:false（id 找不到/verdict 非法）
            guard (d["ok"] as? Bool) ?? false else {
                print("[proactive] 反馈未被后端接受: \(d["error"] as? String ?? "-")")
                return
            }
            await chat?.saveToServer(auth: auth)
        } catch {
            print("[proactive] 反馈提交失败: \(error.localizedDescription)")
        }
    }

    /// v3.9.110：用户作答问题卡 → POST /api/inbox/answer（AI 侧 ask_user.py 的长轮询正在等这个答案）
    /// + 就地更新会话里那条消息为「已回答」并落库。
    ///
    /// ⚠️ **刻意不 markDone**（与后端口径一致：inbox_api docstring 写明「App 侧不 markDone question」）：
    /// ① 收尾归 AI 侧（它拿到答案后自己调 done）；② read_answer 只看 answer 值、不看 status，
    /// 但 App 提前 done 会让「AI 还没取走答案」的窗口里卡片从队列消失——平白多一条竞态。
    /// 代价：AI 已超时退出时该条目会 pending 到后端 STALE_TTL（24h）自动清理；期间被
    /// consumedIds 去重挡住，不会重复注入/重复通知，只是每轮 poll 多带一条字节。
    func answerQuestion(messageId: String, inboxId: String, answer: String) async {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let auth else { return }
        // 先本地落地：用户点完立刻看到已答态，不等网络往返。
        // 失败时**不回滚这条答案**（卡上保留用户真实给过的答复），而是把卡片切到「提交失败」态
        // （markQuestionFailed）——答案与失败态并存、可重试，绝不静默假装已送达。
        chat?.markQuestionAnswered(messageId: messageId, answer: text)
        do {
            let d = try await auth.json("/api/inbox/answer", method: "POST",
                                        body: ["id": inboxId, "text": text])
            // ⚠️ 后端这个端点失败时仍是 **HTTP 200 + ok:false**（条目已被 AI done / 被 STALE_TTL 清掉）；
            //    早期写法 `_ = try await auth.request(...)` 把失败当成功 → 卡片停在「已回答」，
            //    而 AI 侧长轮询永远等不到答案（直到超时），用户却以为答案送出去了。
            //    与 MailSettingsSheet 同口径：一律查 ok。
            guard (d["ok"] as? Bool) ?? false else {
                chat?.markQuestionFailed(messageId: messageId,
                                         reason: (d["error"] as? String) ?? "提交失败")
                return
            }
            await chat?.saveToServer(auth: auth)
        } catch {
            chat?.markQuestionFailed(messageId: messageId, reason: error.localizedDescription)
        }
    }

    /// 某个任务已落地（最终回复已进会话）→ 之后同任务的进度快照一律按残片丢弃。
    /// 发布前审查（2026-09-30）：`finishedProgressTasks` 原先**只有后端 reply 分支**写入，
    /// 而被移交的后台任务落库（BackgroundStreamRunner.finish）根本不走后端 reply 推送，
    /// 另一条判据（stream.isDone/taskId 同源）又被 detachLocally 清空 → 移交/重启后
    /// 同任务的迟到快照仍会排到完整回复下面（用户实报那条的移交形态）。
    func markTaskLanded(_ taskId: String) {
        guard !taskId.isEmpty else { return }
        finishedProgressTasks.insert(taskId)
        progressSnapshots.removeValue(forKey: taskId)
    }

    /// v3.4.23：搭载投递消费——StreamClient poll 响应捎带的收件箱消息走此入口。
    /// 与 pollOnce 同一套去重/分流/标记已读逻辑（复用 consumeOne），
    /// 立即处理不等 5s 轮询（推送滞后根治）。
    func ingestPiggyback(_ items: [[String: Any]]) {
        guard let auth, let chat else { return }
        guard !items.isEmpty else { return }
        // 流式进行中仍可安全消费：reply 类有 shouldSkipDuplicate+延迟重检兜底，
        // 非 reply 类直接进任务中心，均不依赖流式结束
        Task {
            for d in items {
                guard let id = d["id"] as? String, !id.isEmpty,
                      let text = d["text"] as? String else { continue }
                let sourceTaskId = d["source_task_id"] as? String
                let taskType = d["task_type"] as? String ?? "reply"
                let sessionId = d["session_id"] as? String   // v4.0.21：归属会话
                // 🚨 发布前审查（2026-09-30，同族缺口）：pollOnce 早已有「流式进行中只放行 progress」的闸门
                //（见上面 :180），这条搭载入口没有 → 同一批迟到快照从这里绕过去。
                // 上面那句「reply 类有 shouldSkipDuplicate+延迟重检兜底」不成立：延迟重检的条件是
                // `stream.isDone`，流式进行中它**根本不执行**（正是 v3.0.90 要拦的窗口）。
                if (stream?.isStreaming ?? false), taskType != "progress" { continue }
                await consumeOne(id: id, text: text, sourceTaskId: sourceTaskId,
                                 taskType: taskType, sessionId: sessionId, auth: auth, chat: chat)
            }
            await chat.saveToServer(auth: auth)
        }
    }

    // MARK: - 消费消息（注入当前会话 + 通知 + 标已读）

    /// 拉一次收件箱，把新消息注入当前聊天会话。
    func pollOnce() async {
        guard let auth, let chat else { return }
        lastError = nil  // 每次拉取前清空旧错误，避免上一次失败持续显示
        do {
            let items = try await inboxItems(auth)
            lastInjectedCount = 0
            // v4.0.46：问题卡回执与「有没有新条目」无关，先扫一遍（用户报「选完卡不确定回复完成没」）
            await refreshQuestionAcks(auth: auth, chat: chat)
            guard !items.isEmpty else { return }
            // v3.0.90 fix：流式进行中不注入。后端 AI 回复 done 即推收件箱（_maybe_push_app），
            // 而流式回复要等 done → finish → upsertAssistant 才落库到 chat.messages；若本轮
            // 轮询抢在落库前拉到推送，shouldSkipDuplicate 遍历不到这条回复 → 误判不重复 →
            // 重复注入（AI 回答气泡 + 🔔推送气泡同内容）。流式中跳过本轮（不 markDone），
            // 流结束 15s 后下一轮再比对，此时回复已落库，去重必然命中。
            // v3.9.7：进度类（task_type="progress"）不受此闸门限制——用户回到 App 时要立刻看到
            // "跑到哪了"，否则这批进度会被压到流结束才一起涌出来（老观感：长任务中途像失联）。
            // reply 类仍按 v3.0.90 的落库竞态修复跳过（去重依赖 chat.messages 已 upsert）。
            let streaming = (stream?.isStreaming ?? false)
            for it in items {
                // review 收口：只放行 progress，cron/system 仍按老规矩等流结束再消费
                // （它们的消费会弹通知 + 进任务中心，流式期间插进来是计划外副作用）
                if streaming, it.taskType != "progress" { continue }
                await consumeOne(id: it.id, text: it.text, sourceTaskId: it.sourceTaskId,
                                 taskType: it.taskType, sessionId: it.sessionId, auth: auth, chat: chat)
            }
            // 注入后保存会话，让推送消息也落库（用户切会话/重开还能看到）
            await chat.saveToServer(auth: auth)
        } catch {
            lastError = "\(error)"
        }
    }

    /// v4.0.46：问题卡**回执轮询**（用户报「选完卡之后给个回馈，不然不确定回复完成没」）。
    ///
    /// 只问「已经提交过答案、但还没拿到回执」的卡（通常 0~1 条，绝大多数轮次直接 return）：
    ///   taken=false            → 条目还在队列里等 AI 取 → 保持「已提交 · 等 AI 确认」
    ///   taken=true  + mark_done → AI 真的取走了答案 → 「✅ AI 已收到」
    ///   taken=true  + 其它原因  → 是 24h 过期清理（AI 早超时了）→ 「卡片已过期」，**不许报假回执**
    ///
    /// ⚠️ 刻意沿用 answerQuestion 里那套「后端 200 也可能语义失败」的判断口径：一律查 ok/taken，
    ///    不做 `try?` 吞错——吞了就会把「查不到」当成「查到了」。
    /// 节流：poll 默认 5s / 快拉 1s，而「等 AI 确认」可能持续几分钟 → 回执扫描最多 10s 一次，
    /// 否则同一张卡每轮都打一次接口（审查点名的新增请求量）。
    private var lastAckSweep: Date = .distantPast

    func refreshQuestionAcks(auth: AuthStore, chat: ChatStore) async {
        guard Date().timeIntervalSince(lastAckSweep) >= 10 else { return }
        lastAckSweep = Date()
        let pending = chat.messages.filter { m in
            guard let q = m.questionId, !q.isEmpty else { return false }
            guard !((m.questionAnswer ?? "").isEmpty) else { return false }   // 没提交过，无可确认
            guard m.questionError == nil else { return false }                // 没送到 → 等重试，别报回执
            return !m.questionAcked && !m.questionExpired
        }
        guard !pending.isEmpty else { return }
        for m in pending {
            guard let q = m.questionId else { continue }
            // 口径同 answerQuestion：后端 200 也可能语义失败（ok=false）→ 查 ok 且查 taken，不做 try? 吞错
            do {
                let d = try await auth.json("/api/inbox/answer?id=\(q)", method: "GET")
                guard (d["ok"] as? Bool) ?? false, (d["taken"] as? Bool) ?? false else { continue }
                let why = (d["gone_reason"] as? String) ?? ""
                if why == "mark_done" {
                    chat.markQuestionAcked(messageId: m.id)
                } else {
                    chat.markQuestionExpired(messageId: m.id)
                }
            } catch {
                continue   // 网络错 → 下一轮再查；绝不能把「查不到」当成「查到了」
            }
        }
    }

    /// v3.4.23：单条收件消息消费（去重 → 分流任务中心/会话气泡 → 通知 → 标已读）。
    /// pollOnce（5s 轮询）与 ingestPiggyback（搭载投递）共用。
    private func consumeOne(id: String, text: String, sourceTaskId: String?, taskType: String,
                            sessionId: String?,
                            auth: AuthStore, chat: ChatStore) async {
        guard !consumedIds.contains(id) else {
            // v3.9.110：**问题卡重复投递时不 markDone** —— 后端 pop/peek 只看 status=="pending"，
            // 一旦 done 就永久不再投递；卡要一直留着让用户随时能答（用户 2026-09 拍板 3a）。
            // 重复注入/重复通知由 consumedIds 挡住，队列里的 pending 由 AI 侧拿到答案后自己 done；
            // 没人取走的僵尸条目由后端 STALE_TTL（24h）自动清理。
            if taskType != "question" { await markDone(id, auth: auth) }
            return
        }
        consume(id)
        // 🚨 v4.0.21 根治（用户实报「消息串进不同会话」）：收件箱推送现在带**会话归属**
        // （后端 inbox_api.push 的 `session_id`，reply/progress/question 三类都会带）。
        // 气泡必须落进**它归属的那个会话**，而不是「App 此刻打开的会话」。三种情形：
        //   · 无 session_id（老后端 / agent / cron / system）→ 不拦，行为零变化；
        //   · 归属会话 == 当前打开的会话 → 不拦，走下面各分支既有内存注入（去重/渲染/通知口径全不变）；
        //   · 归属会话 != 当前打开的会话 → 落进归属会话（**写库不切会话**）。
        // ⚠️ 这段必须在下面**投递壳闸门之前**：那条闸门对 reply/progress 无条件 markDone 并 return，
        //   放在它后面，用户停在投递壳时归属别的会话的推送会被它就地吃掉（串位的镜像：丢件）。
        // 纪律同 `injectToProactiveSession`：ChatStore 内存态必须无感 —— 绝不能 `loadById` 切过去
        // （那会把用户正看着的对话当场清空）。
        // 归属会话在 NAS 上查不到（被删/未同步）→ 回落到旧行为：宁可串位，绝不丢消息。
        if let sid = ownedSessionId(sessionId, current: chat.sessionId),
           taskType == "reply" || taskType == "progress" {
            // 固定投递壳的内容由后端 `append_delivery_message` 维护，App 一律不注入（与投递闸门同口径）
            // v4.0.46 修（用户实报「不弹选题卡，我选不了」）：**question 不进这条归属分支**。
            //   起因：AI 侧推的问题卡带 session_id=qingliao_delivery（投递壳只收不发 / 内容由后端维护），
            //   ① 老代码把它归进这里 → 撞上下面的投递壳闸门就被静默 markDone：卡不显示、不能答、
            //      归档原因 mark_done（队列里查不到），用户干等、AI 侧一直超时；
            //   ② 只把它从闸门里放出来还不够（审查抓到）：归属分支走 `landPushInOwnedSession`，
            //      非当前会话时是**整会话写回**（fetchSessionSnapshot + writeSessionSnapshot），
            //      与后端并发 append 投递壳会互相吞行；
            //   ③ 故 question 一律落到**当前会话**（下方 `taskType == "question"` 分支 `chat.append`）：
            //      与 v3.9.110 的显式口径一致（「AI 追问必须落到用户此刻停留的会话」，否则人看不到卡），
            //      且不写任何归属壳。答案走 POST /api/inbox/answer（见 answerQuestion），
            //      **与会话能否回复无关** —— 所以投递壳里弹卡也不影响作答。
            if sid == ChatStore.deliverySessionId {
                if taskType == "reply" {
                    NotificationHelper.notify(title: "轻聊 · 推送", body: text, sessionId: sid)
                }
                await markDone(id, auth: auth)
                return
            }
            // 进度快照是「正在进行中」的实时指示器：归属会话没打开就没有可展示的位置，
            // 写进历史只会攒一批过期进度气泡（还要复制整套「前进 / 残片」判据）。
            // 任务中心另有「进行中」卡片实时刷新（不依赖这条推送）；最终回复会经 reply 路径落进归属会话。
            if taskType == "progress" {
                await markDone(id, auth: auth)
                return
            }
            var msg = ChatMessage(role: "assistant", content: text,
                                  timestamp: Date().timeIntervalSince1970 * 1000)
            msg.isPush = true
            msg.pushKind = taskType
            var notifyBody = text
            if taskType == "question" {
                let parts = ChatMessage.splitQuestion(text)
                msg.questionId = id
                msg.questionOptions = parts.options.isEmpty ? nil : parts.options
                notifyBody = parts.body
            }
            // reply 落地记账（与下面 reply 分支同一口径，同样放在判定之前：去重命中也算「已落地」）：
            // 缺这条 → 该任务后续进度快照的「残片」判据拿不到铁证，会追加到完整回复下面（v4.0.11 回归）
            if taskType == "reply", let key = sourceTaskId, !key.isEmpty {
                finishedProgressTasks.insert(key)
                progressSnapshots.removeValue(forKey: key)
            }
            switch await landPushInOwnedSession(msg, sessionId: sid, sourceTaskId: sourceTaskId,
                                                auth: auth, chat: chat) {
            case .landed:
                lastInjectedCount += 1
                // 通知口径与各分支既有规则一致：reply 弹横幅、question 弹「需要你确认」、progress 静默
                if taskType == "reply" {
                    NotificationHelper.notify(title: "轻聊 · 推送", body: notifyBody, sessionId: sid)
                } else if taskType == "question" {
                    NotificationHelper.notify(title: "轻聊 · AI 需要你确认", body: notifyBody, sessionId: sid)
                }
                // question 刻意不 markDone（卡要一直留着让用户随时能答，见下面对应分支的说明）
                if taskType != "question" { await markDone(id, auth: auth) }
                return
            case .duplicate:
                // 归属会话里已有同一条（本机流式已落库 / away 分支补回）→ 只收尾，不重复注入
                if taskType != "question" { await markDone(id, auth: auth) }
                return
            case .targetMissing:
                break   // 回落到下面各分支的旧行为（注入当前会话 / 任务中心）
            }
        }
        // v3.9.76：固定投递会话（qingliao_delivery）是「只装 cron/system 投递详情」的壳，
        // App 侧**不许**把推送气泡注入进去。起因（用户实测）：「轻聊投递会混进普通 AI 推送内容」
        // ——投递会话里出现了「⏳ AI 正在回复（已生成 152 字，第 17 步 运行代码）」这种普通 AI 进度残片：
        // 后端只把 cron/system 写进该会话（`inbox_api.push` 刻意排除 reply/progress），
        // 混入源是**这里**——progress/reply 被无条件注入「当前会话」，当天用户开着的恰是投递壳。
        // 命中时：reply 类仍弹通知（用户要知道有回复来了），progress 类静默丢弃（任务中心另有「进行中」卡片）；
        // cron/system 类**不受影响**（继续走下面的任务中心分支，别在这里拦掉）。
        // ⚠️ 判据用会话 id（`ChatStore.deliverySessionId`），不用标题。
        // v3.9.110 补记：**question 类刻意不在这个闸门里** —— AI 追问必须落到用户此刻停留的会话，
        //   否则人看不到卡、也没法作答（AI 侧一直等到超时）。代价是投递壳里可能冒出一张问题卡；
        //   这是**显式取舍**（审查提过要不要一并拦掉，结论：不拦），不是漏写。
        // v4.0.11 补记：**agent 类也归进这个闸门**（与 question 相反）。理由同 reply——
        //   投递会话是 cron/system 的固定壳，主动消息混进去等于把「AI 主动开口」塞进
        //   一个用户当归档看待的会话里（用户当年报过的同一个 bug）。回落到这里的
        //   agent 消息只弹通知不注入（quiet: 静默时段本来也不会有，但手动 run 兜底）。
        if chat.isDeliverySession, taskType == "reply" || taskType == "progress" || taskType == "agent" {
            if taskType == "reply" || taskType == "agent" {
                NotificationHelper.notify(title: taskType == "agent" ? "轻聊 · 主动" : "轻聊 · 推送",
                                          body: text, sessionId: chat.sessionId)
            }
            await markDone(id, auth: auth)
            return
        }
        // v3.9.110：AI 中途追问「问题卡」（后端 ask_user.py 推的 task_type=question）→
        // 注入当前会话成一张**可作答卡**（不是普通气泡：带 questionId，气泡层渲染成
        // ChatQuestionCard —— 选项胶囊 + 自由输入 + 答完留痕）。
        // 四处刻意与其它类不同（用户 2026-09 拍板「方案 A 会话内联 / 快捷选项 / 卡一直留着」）：
        //   ① 不进任务中心：追问的语义就是「AI 在对话里问你」，去任务中心找是两处分散；
        //   ② **不 markDone**：卡要一直留着（用户随时能答），AI 侧拿到答案后自己收尾；
        //   ③ isPush=true：留在会话展示，但 historyPayload 会滤掉它 → 不进模型上下文
        //      （问题本来就是 AI 自己提的，回灌只会造成自问自答的重复）；
        //   ④ 弹本地通知（侧载无 APNs）：不弹的话用户根本不知道 AI 卡在等他。
        if taskType == "question" {
            let parts = ChatMessage.splitQuestion(text)
            var qmsg = ChatMessage(role: "assistant", content: text,
                                   timestamp: Date().timeIntervalSince1970 * 1000)
            qmsg.isPush = true
            qmsg.pushKind = "question"
            qmsg.questionId = id
            qmsg.questionOptions = parts.options.isEmpty ? nil : parts.options
            chat.append(qmsg)
            lastInjectedCount += 1
            NotificationHelper.notify(title: "轻聊 · AI 需要你确认", body: parts.body,
                                      sessionId: chat.sessionId)
            return
        }
        // v4.0.11：主动 Agent 消息（后端 proactive_agent 投的 task_type=agent）→
        // 注入**固定主动会话**「轻聊主动」成**可回复的普通气泡**（不是任务中心卡片）。
        //
        // 🚨 v4.0.x 修（用户实测：「主动消息串进正常会话」）：原先这里 `chat.append(amsg)`
        // 注入的是**当前会话** —— 用户当时开着哪个会话，主动消息就落进哪个，
        // 于是「AI 主动开口」被塞进用户正在聊的正事里。现在改为注入
        // ChatStore.proactiveSessionId 那个固定会话：不可删、标题锁定、内容以 NAS 为准。
        // 口径与 reply 一致但三处刻意不同：
        //   ① 不走 reply 去重（InboxDedup 是给「AI 回复双投」用的；主动消息与 AI 回复
        //      是两套不同来源，共用双向包含判据会把「你刚问的和你刚被主动提醒的
        //      话题相近」误判成重复 → 主动消息被吞。主动消息带 proactiveId 天然唯一）。
        //   ② 弹通知标题写「轻聊 · 主动」而非「轻聊 · 推送」——用户能一眼分清
        //      这是 AI 主动开口，不是自己发问的回复。
        //   ③ 注入目标固定 → 即使用户正停在别的会话，主动消息也只会进「轻聊主动」，
        //      不会打断当前对话（这正是本次要修的核心）。
        // isPush=true：留在会话展示但 historyPayload 会滤掉它 → 不进模型上下文。
        if taskType == "agent" {
            var amsg = ChatMessage(role: "assistant", content: text,
                                   timestamp: Date().timeIntervalSince1970 * 1000)
            amsg.isPush = true
            amsg.pushKind = "agent"
            amsg.proactiveId = sourceTaskId?.isEmpty == false ? sourceTaskId : id
            injectToProactiveSession(amsg)
            NotificationHelper.notify(title: "轻聊 · 主动", body: text,
                                      sessionId: ChatStore.proactiveSessionId)
            await markDone(id, auth: auth)
            return
        }
        // v3.9.7：进行中进度推送（后端在静默期推来的「已生成 N 字 + 最近片段」）→ 注入会话 🔔 进度气泡。
        // 三处刻意的不同：① 不走 reply 去重（带字数的快照天然唯一，也绝不能和最终回复互判重复）；
        // ② 不弹本地通知（进度是"回到 App 时看"的信息，弹横幅只会在回前台那一瞬轰炸）；
        // ③ 不进任务中心（进度留痕在会话里，任务中心另有「进行中」卡片实时刷新进度）。
        // isPush=true 保证它留在会话展示但**不进模型上下文**（historyPayload 会滤掉 isPush）。
        if taskType == "progress" {
            // 🚨 v3.9.76 用户规则：「进度这类回复要按时间前后推，不要 20 步推在 17 步前」。
            // 进度是状态快照，只有前进才有意义 → **迟到的旧快照直接丢弃**（投递层会把僵尸 sending
            // 重置回 pending 重投，旧快照就会落在更新的快照之后，用户看到 20 步排在 17 步前）。
            // 分组键用 source_task_id：toolSeq 每任务独立计数，跨任务比会误丢新任务的第一条进度。
            // ⚠️ 分组键**必须**是 source_task_id，且**拿不到就整段闸门放行**：
            //   ① 原来 nil 落 "unknown" 共用桶 —— 两个都没有 source_task_id 的任务会互相判回退
            //      （A 的 20 步存进桶后，B 的第一条 step 1 被判「迟到」丢弃 + markDone，那条进度永久丢失），
            //      正是上面注释要避免的跨任务比较；
            //   ② 重启后的「会话里最后一条进度气泡」兜底同理：气泡文本里取不到来源任务，
            //      用户 15 分钟内连发两条消息时，第二条的第一条进度会被拿第一条当基准误丢。
            //   → 基准**只信内存里的同任务快照**。代价是重启后同任务可能有极少一次乱序，
            //     但「宁可偶尔乱序，绝不丢进度」（丢数据不可恢复，乱序下次快照就正过来了）。
            // 🚨 v4.0.11 用户规则（2026-09-30 真机实报）：「AI 已经完整回复了，推送的反而还在完整回复后」。
            // 进度是**进行中**的快照；任务一旦落地（最终回复已进会话，或本机流式已收尾），
            // 之后到达的同任务进度全是残片 —— 不拦就会被注入到列表末尾，排在完整回复**下面**。
            // 两条落地路径都认：① reply 分支已写入 finishedProgressTasks；② 本机流式 isDone 且 taskId 同源。
            // 分组键同铁律：拿不到 source_task_id 就放行（别跨任务误丢）。
            if InboxProgressOrder.isTaskLanded(sourceTaskId: sourceTaskId,
                                              finishedTasks: finishedProgressTasks,
                                              streamDone: stream?.isDone ?? false,
                                              streamTaskId: stream?.taskId) {
                await markDone(id, auth: auth)   // 丢弃也要 markDone，否则后端会一直重投这条残片
                return
            }
            let nowMs = Date().timeIntervalSince1970 * 1000   // 注入气泡的时间戳（闸门不再需要它）
            if let snap = InboxProgressOrder.snapshot(from: text) {
                let baseline: InboxProgressOrder.Snapshot? = sourceTaskId.flatMap { progressSnapshots[$0] }
                if let key = sourceTaskId {
                    if !InboxProgressOrder.shouldAccept(snap, after: baseline) {
                        // 丢弃也要 markDone：否则后端认为没送到，会一直重投这条旧快照
                        await markDone(id, auth: auth)
                        return
                    }
                    progressSnapshots[key] = snap
                }
            }
            var pmsg = ChatMessage(role: "assistant", content: text,
                                   timestamp: nowMs)
            pmsg.isPush = true
            pmsg.pushKind = "progress"
            chat.append(pmsg)
            lastInjectedCount += 1
            await markDone(id, auth: auth)
            return
        }
        // 非 reply（定时/后台/系统事件）不注入会话气泡，进任务中心列表
        if taskType != "reply" {
            TaskCenterStore.shared.add(TaskCenterItem(
                id: id, text: text, taskType: taskType,
                sourceTaskId: sourceTaskId))
            NotificationHelper.notify(title: "轻聊 · 任务", body: text, sessionId: chat.sessionId,
                                      sound: false)   // #10：定时/后台任务走静默，别抢前台对话铃声
            await markDone(id, auth: auth)
            return
        }
        // v4.0.11：最终回复落地 → 记住这个任务，之后同任务的进度快照一律按残片丢弃（见 progress 闸门）。
        // 放在去重判定**之前**：去重命中（回复已在会话里）同样算「已落地」。
        if let key = sourceTaskId, !key.isEmpty {
            finishedProgressTasks.insert(key)
            progressSnapshots.removeValue(forKey: key)
        }
        // reply 去重（详见 InboxDedup）：taskId 同源铁证 + 双向包含 + 截断前缀
        if !shouldSkipDuplicate(push: text, in: chat.messages, extra: stream?.content ?? "", sourceTaskId: sourceTaskId) {
            // 流式已结束（isDone）但去重未命中 → 极可能是"后台完成/落库竞态"窗口（chat.messages
            // 的 upsertAssistant 尚未执行、stream.content 已被清空重建）。此时去重比对源暂空，
            // 若直接注入必双份。延迟 1.5s 等落库/恢复稳定后再重比对一次，仍不命中才注入。
            // 不违背「在看也推」——最终仍会注入，只是先确认不重复再注入。
            if let s = stream, s.isDone {
                try? await Task.sleep(for: .seconds(1.5))
                if shouldSkipDuplicate(push: text, in: chat.messages, extra: stream?.content ?? "", sourceTaskId: sourceTaskId) {
                    await markDone(id, auth: auth)
                    return
                }
            }
            // 注入当前会话（assistant 角色 + 推送标记）
            var msg = ChatMessage(role: "assistant", content: text,
                                  timestamp: Date().timeIntervalSince1970 * 1000)
            msg.isPush = true
            msg.pushKind = "reply"
            chat.append(msg)
            lastInjectedCount += 1
            // 弹本地通知（侧载无 APNs，用本地通知横幅兜底；App 前台也弹）
            NotificationHelper.notify(title: "轻聊 · 推送", body: text, sessionId: chat.sessionId)
        }
        await markDone(id, auth: auth)
    }

    /// v3.0.88 fix：收件箱推送 vs 会话内流式回复去重（v3.0.87 版因空白格式不匹配失效）。
    /// 后端 _maybe_push_app 用 re.sub(r"\s+"," ",...) 把回复压成单行摘要，而流式回复 content 保留换行/段落，
    /// 直接 contains 会匹配失败 → 重复注入。改为双方先压缩空白再双向比对 + 截断前缀兜底。
    /// v3.2.1 加固：extra 参数额外比对 stream.content（流式进行中的当前回复）——即使 chat.messages
    /// 因时序暂缺该回复（pollOnce 抢在 upsertAssistant 落库前），只要 stream.content 持有即可命中去重。
    /// v3.4.x 收敛：判定逻辑抽到静态纯函数 InboxDedup.shouldSkip（可单测防漂移），实例方法只做壳。
    /// v4.0.21：`useCurrentStream` —— 被 InboxDedup 隐式用于「taskId 同源」的铁证判定。
    /// 归属会话路由**必须传 false**：`stream` 是**当前打开会话**的流式态，拿它去比对归属会话的消息
    /// 会跨会话误命中，判定 duplicate → markDone → 归属会话永久丢这条气泡。
    private func shouldSkipDuplicate(push text: String, in messages: [ChatMessage], extra: String = "",
                                     sourceTaskId: String? = nil, useCurrentStream: Bool = true) -> Bool {
        InboxDedup.shouldSkip(push: text, in: messages, extra: extra, sourceTaskId: sourceTaskId,
                              currentTaskId: useCurrentStream ? stream?.taskId : nil)
    }

    // MARK: - v4.0.21 会话归属（推送落进「它归属的会话」）

    /// 这条推送的**归属会话**：只有「非空且不同于当前打开的会话」才返回（否则 nil = 不拦，走旧路径）。
    private func ownedSessionId(_ sessionId: String?, current: String) -> String? {
        guard let sid = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sid.isEmpty, sid != current else { return nil }
        return sid
    }

    private enum PushLanding {
        case landed          // 已写进归属会话
        case duplicate       // 归属会话里已有同内容 → 不重复注入
        case targetMissing   // 归属会话在 NAS 上查不到 → 调用方回落旧行为
    }

    /// v4.0.21：把推送气泡落进**归属会话**（写库不切会话）。
    ///
    /// 去重比对源是**归属会话自己的消息**（不是当前会话），且**不看当前会话的流式态**
    /// （`extra` / `currentTaskId` 都属于当前打开的会话，跨会话比对会把别的会话的推送误判成重复而永久丢弃）。
    /// 读-改-写整体交给 `ChatStore.appendMessageToOwnedSession`（在 FIFO 串行链内**重读**）：
    /// 链外「先读快照 → 再写」的间隙里，后台流式落地的最终回复会被这份旧快照整会话抹掉。
    private func landPushInOwnedSession(_ msg: ChatMessage, sessionId sid: String,
                                        sourceTaskId: String?, auth: AuthStore,
                                        chat: ChatStore) async -> PushLanding {
        guard let target = await chat.fetchSessionSnapshot(sessionId: sid, auth: auth) else {
            print("[inbox] 归属会话 \(sid.prefix(8))… 在 NAS 上查不到 → 回落到当前会话注入")
            return .targetMissing
        }
        if shouldSkipDuplicate(push: msg.content, in: target.messages, extra: "",
                               sourceTaskId: sourceTaskId, useCurrentStream: false) {
            print("[inbox] 归属会话 \(sid.prefix(8))… 已有同内容 → 不重复注入")
            return .duplicate
        }
        guard await chat.appendMessageToOwnedSession(msg, sessionId: sid, auth: auth) else {
            print("[inbox] 归属会话 \(sid.prefix(8))… 写入时已查不到 → 回落到当前会话注入")
            return .targetMissing
        }
        print("[inbox] 推送已落归属会话 \(sid.prefix(8))…（当前会话未受影响）")
        return .landed
    }

    // MARK: - 轮询启动/停止

    /// 启动后台轮询（App 前台持续拉）。防重复启动。
    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.pollOnce()
                // v3.1.9 fix：消费快拉计数——triggerFastPoll 设置后此处真正缩短间隔
                //（原实现只置 fastPollRemaining 但循环恒用 pollInterval，快拉从未生效）
                let interval = self.fastPollRemaining > 0 ? 1.0 : self.pollInterval
                if self.fastPollRemaining > 0 { self.fastPollRemaining -= 1 }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// 前台恢复：重启轮询任务（旧任务可能已被系统冻结）
    func refreshOnActive() {
        // 若轮询任务已停止（后台冻结），重启；若还在则不需重复启（startPolling 幂等）
        if pollingTask == nil { startPolling() }
        // 立即拉一次，不等下一轮
        Task { await self.pollOnce() }
    }

    /// v3.0.x fix：流式结束后触发快拉（临时缩短轮询间隔，快速拉取可能的推送）
    func triggerFastPoll() {
        fastPollRemaining = 3  // 连续 3 轮用 1s 间隔
    }

    // MARK: - 后端 API

    private func inboxItems(_ auth: AuthStore) async throws -> [(id: String, text: String, sourceTaskId: String?, taskType: String, sessionId: String?)] {
        let json = try await auth.json("/api/inbox", method: "GET")
        guard let arr = json["items"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let id = d["id"] as? String, let text = d["text"] as? String else { return nil }
            // v4.0.21：session_id = 这条推送**归属的会话**（后端 inbox_api.push 补的字段；
            // 老后端/agent/cron/system 不带 → nil → 走旧行为）
            return (id, text, d["source_task_id"] as? String, d["task_type"] as? String ?? "reply",
                    d["session_id"] as? String)
        }
    }

    private func markDone(_ id: String, auth: AuthStore) async {
        _ = try? await auth.request("/api/inbox/\(id)/done", method: "POST", body: [:])
    }
}

// MARK: - v3.4.x 任务中心：收件箱从"推送气泡"升级为"任务列表"

/// 一条任务（收件箱非 AI 回复的来源：定时/自动任务/系统通知）
struct TaskCenterItem: Identifiable, Codable, Equatable {
    let id: String
    let text: String
    let taskType: String        // cron / system（reply 不进任务中心，只进会话气泡）
    let sourceTaskId: String?   // 用于跳原文/去重
    let createdAt: TimeInterval
    var completed: Bool

    init(id: String, text: String, taskType: String, sourceTaskId: String? = nil,
         createdAt: TimeInterval = Date().timeIntervalSince1970, completed: Bool = false) {
        self.id = id; self.text = text; self.taskType = taskType
        self.sourceTaskId = sourceTaskId; self.createdAt = createdAt; self.completed = completed
    }
}

/// 任务中心存储：收件箱非 reply 推送汇总为可分类任务列表，本地持久化。
/// 生命周期：inbox pollOnce 拉到非 reply → addTask（按 sourceTaskId 去重）→ 用户点击跳原会话/标记完成。
@MainActor
@Observable
final class TaskCenterStore {
    static let shared = TaskCenterStore()
    private let key = "qingliao_task_center"
    private(set) var tasks: [TaskCenterItem] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let arr = try? JSONDecoder().decode([TaskCenterItem].self, from: data) {
            tasks = arr
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 新增任务（按 id/sourceTaskId 去重，避免轮询重复拉取堆积）
    func add(_ item: TaskCenterItem) {
        if !item.id.isEmpty, tasks.contains(where: { $0.id == item.id }) { return }
        if let sid = item.sourceTaskId, !sid.isEmpty,
           tasks.contains(where: { $0.sourceTaskId == sid }) { return }
        tasks.append(item)
        if tasks.count > 200 { tasks = Array(tasks.suffix(200)) }   // 防无限增长
        save()
        // v3.4.23：App 图标角标跟随未完成数（通知中心 badge）
        NotificationHelper.setBadge(uncompleted)
    }

    /// 标记完成/未完成
    func setCompleted(_ id: String, _ done: Bool) {
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].completed = done
            save()
            NotificationHelper.setBadge(uncompleted)
        }
    }

    /// 清理已完成
    func clearCompleted() {
        tasks.removeAll { $0.completed }
        save()
        NotificationHelper.setBadge(uncompleted)
    }

    /// v3.9.30：全部已读——未完成任务一次全标完成（角标同步清零）。
    /// 与「清理已完成」分工：这是逐条标记太繁琐的批量化；清理是删除，这是标记。
    func markAllCompleted() {
        var changed = false
        for i in tasks.indices where !tasks[i].completed {
            tasks[i].completed = true
            changed = true
        }
        if changed {
            save()
            NotificationHelper.setBadge(uncompleted)
        }
    }

    var uncompleted: Int { tasks.count { !$0.completed } }
}


/// 收件箱推送 vs 会话内流式回复去重。
/// 纯函数、无实例/无 IO：输入推送文本 + 会话消息 + 流式内容 + taskId，输出是否该跳过（不注入重复）。
///
/// 背景：后端 _maybe_push_app 在 AI 回复 done 时把完整回复 `re.sub(r"\s+"," ",...)` 压成单行摘要推收件箱；
/// 而 App 会话内是带换行的流式回复。若直接字符串相等匹配会因空白/换行不一致而失配 → 重复注入。
/// 因此：① normalizeWhitespace 两边压成单行 ② 双向 contains（完整含摘要 / 摘要含完整）③ 截断前缀兜底
/// ④ v3.4.8 taskId 同源铁证（推送 source_task_id == 当前流式 taskId → 必然同一条）。
enum InboxDedup {
    static func shouldSkip(push text: String, in messages: [ChatMessage], extra: String = "",
                           sourceTaskId: String? = nil, currentTaskId: String? = nil) -> Bool {
        // ④ taskId 同源去重：推送 source_task_id 与当前流式任务 taskId 相同 → 同一回复必然跳过（最可靠）
        if let sid = sourceTaskId, !sid.isEmpty, sid == currentTaskId { return true }

        let core = normalizeWhitespace(text).replacingOccurrences(of: "…", with: "")
        guard !core.isEmpty else { return false }

        // ① 先比对当前流式内容（流式回复一定在 extra=stream.content）
        let ex = normalizeWhitespace(extra).replacingOccurrences(of: "…", with: "")
        // 流式内容是"完整原文"，core 是压单行的摘要——同一份文本压制后应相等或互为包含。
        var streamHit = false
        if !ex.isEmpty {
            if ex == core { streamHit = true }
            else if core.count >= 10, ex.contains(core) || core.contains(ex) { streamHit = true }
        }
        if streamHit { return true }

        // ② 会话内已落库的 assistant（非推送）双向包含
        for m in messages.reversed() {
            guard m.role == "assistant", !m.isPush else { continue }
            let cm = normalizeWhitespace(m.content)
            // 子串包含同样要 core ≥10 字：短推送（如"好的/收到"）是正常口语，被长历史包含会误判跳过
            if core.count >= 10, cm.contains(core) { return true }
            // v3.9.41（SR42）反向包含（cm ⊂ core）还要约束历史本身 ≥10 字：会话里有一条「好的」级别的
            // 短历史时，任何包含它的长推送都会被判重复 → 不注入不通知，但调用方照样 markDone → 推送永久丢失。
            if core.count >= 10, cm.count >= 10, core.contains(cm) { return true }
            // ③ 截断前缀兜底：推送是完整回复的截断（前 N 字）摘要，且摘要足够长避免短文本误判
            if core.count >= 10, cm.hasPrefix(core) { return true }
        }
        return false
    }

    /// 压缩全部空白（换行/多空格 → 单空格），使推送摘要（已压单行）与流式回复（带换行）可比对
    static func normalizeWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ").joined(separator: " ")
    }
}
