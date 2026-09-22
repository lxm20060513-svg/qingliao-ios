import Foundation
import Observation
import SwiftUI

// MARK: - 聊天会话状态：当前会话 id + 消息列表（UserDefaults 持久化当前会话）

@MainActor
@Observable
final class ChatStore {
    var sessionId: String
    var messages: [ChatMessage] = []
    var title = ""
    /// v3.4.29：最近一次从会话列表加载进来的会话——供欢迎页「继续上次」入口一键回归（内存态，无需持久化）
    private(set) var lastLoadedSession: ChatSession?

    // MARK: - v3.9.9：AI 回复「真正落库」信号（自动朗读触发器）
    //
    // 自动朗读原来监听 `messages.last?.id`，这个信号不干净（两位只读审查都抓到）：
    //   ① 切会话 / 冷启动加载（`load` 整组替换 messages）**也会**让它变 → 会把刚打开那个会话的
    //      历史旧答案念出来（正是本版声称要修掉的「切会话念旧内容」，实际没修掉）；
    //   ② AI 回答中用户又发一条（排队）时，本轮回复 `insert` 到数组中段、末条仍是排队 user 消息
    //      → 信号不变，这一轮**永远不朗读**。
    // 改成在**真正 append/insert 了一条 assistant 回复**时自增 token 并记下这条消息：
    // 触发面精确到"这一条回复落库"，与会话加载 / 删除消息 / regenerate 截断全部无关。
    private(set) var assistantLandedToken = 0
    private(set) var lastLandedAssistantUID: String?

    /// 按 uid 取消息——自动朗读要念"刚落库的那条"，不能用 `messages.last`（排队场景下末条是 user 消息）
    func message(withUID uid: String?) -> ChatMessage? {
        guard let uid, !uid.isEmpty else { return nil }
        return messages.first { $0.uid == uid }
    }

    private func noteAssistantLanded(_ m: ChatMessage) {
        lastLandedAssistantUID = m.uid
        assistantLandedToken &+= 1
    }

    // 缓存的 DateFormatter，避免循环内重复创建（~1ms/次）
    private static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f
    }()
    private static let exportMDDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    private let defaults = UserDefaults.standard
    // 重复回复兜底：assistant 内容归一化指纹
    private static func assistantKey(_ text: String) -> String {
        let lowered = text.lowercased()
        let trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed
    }

    private func isAssistantDuplicate(_ text: String, in region: ArraySlice<ChatMessage>) -> Bool {
        let key = ChatStore.assistantKey(text)
        guard !key.isEmpty else { return false }
        let window = region.suffix(8)
        for m in window where m.role == "assistant" {
            if ChatStore.assistantKey(m.content) == key { return true }
        }
        return false
    }
    // v3.0.7 修复：debounce 保存任务——快速切换会话/连续操作时只保存最后一次
    private var saveTask: Task<Void, Never>?
    // v3.0.1 fix：会话 id 用固定 key（v3.9.28：云端/本地双 key 已随云端模式移除）
    private var sessionKey: String { "qingliao_current_session" }

    init() {
        let key = "qingliao_current_session"
        if let saved = defaults.string(forKey: key), !saved.isEmpty {
            sessionId = saved
        } else {
            sessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(13).description
            defaults.set(sessionId, forKey: key)
        }
    }

    /// 切换会话（从会话列表点入）
    func load(_ s: ChatSession) {
        imageRetryTask?.cancel()   // SR4：旧会话的图还没传完就切走 → 停掉，避免与新会话的重传争写
        sessionId = s.id
        title = s.title
        messages = patchAwayLanded(s.id, s.messages)
        lastLoadedSession = s   // v3.4.29：欢迎页「继续上次」用
        defaults.set(sessionId, forKey: sessionKey)
    }

    /// v3.9.39 A1：「迟到的回复」——用户在回答期间切走了会话，答案按发起时的快照落回**原会话**
    /// （见 ChatView.startStream 收尾的 away 分支）。但会话列表可能是那次落库**之前**拉的
    /// （SessionsView.load 有 3 秒节流 + 冷启动缓存先显），拿旧数组 load 进来后任何一次写库
    /// 都会把这条回复盖掉（后端 merge 是整会话覆盖）。所以落库时记一笔，进该会话时补回内存，补一次即清。
    private var awayLandedReplies: [String: String] = [:]

    func noteAwayLandedReply(sessionId sid: String, text: String) {
        awayLandedReplies[sid] = text
    }

    /// 快照里缺这条迟到回复就补到末尾（已有则只清记录，不重复插）
    private func patchAwayLanded(_ sid: String, _ msgs: [ChatMessage]) -> [ChatMessage] {
        guard let pending = awayLandedReplies.removeValue(forKey: sid) else { return msgs }
        if msgs.contains(where: { $0.role == "assistant" && $0.content == pending }) { return msgs }
        var patched = msgs
        patched.append(ChatMessage(role: "assistant", content: pending,
                                   timestamp: Date().timeIntervalSince1970 * 1000))
        return patched
    }

    // MARK: - v3.1.5 启动自动加载上次会话（解决"App 忘记上下文"）
    /// App 重启后自动从后端/本地存储加载当前 sessionId 对应的会话消息，
    /// 让 historyPayload() 有上下文可发，不再每条消息都"从零开始"。
    func loadLastSession(auth: AuthStore) async {
        guard messages.isEmpty else { return }   // 已有消息不覆盖（用户已手动加载）
        let sid = sessionId
        // 从后端拉会话列表
        guard let j = try? await auth.json("/api/sessions/list"),
              let raw = j["sessions"] as? [Any] else { return }
        let sessions = raw.compactMap { ChatSession.parse($0 as? [String: Any] ?? [:]) }
        if let match = sessions.first(where: { $0.id == sid }) {
            await MainActor.run { self.load(match) }
        }
    }

    /// 新会话（v3.3.0：bot 模式已移除，仅生成普通新会话 id）
    func newSession() {
        sessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(13).description
        title = ""
        messages = []
        highlightTarget = nil   // v2.0.44：新建会话清除残留定位目标
        defaults.set(sessionId, forKey: sessionKey)
    }

    /// v3.9.58c：「继续上次任务」横幅用——按 id 从后端拉会话并切换（含消息加载）。
    /// 返回 false = 会话不存在/已删除（调用方据此提示放弃）。
    @discardableResult
    func loadById(_ sid: String, auth: AuthStore) async -> Bool {
        guard let j = try? await auth.json("/api/sessions/list"),
              let raw = j["sessions"] as? [Any] else { return false }
        let sessions = raw.compactMap { ChatSession.parse($0 as? [String: Any] ?? [:]) }
        guard let match = sessions.first(where: { $0.id == sid }) else { return false }
        load(match)
        return true
    }

    /// SR10：登出时彻底丢弃上一个账号的状态。
    /// `logout()` 只清 token/isLoggedIn，ChatStore 是 App 级 @State、跨登录态存活：
    /// 换账号登录后 messages/未读仍属旧账号（`loadLastSession` 的 `messages.isEmpty` 护栏
    /// 反而让它**不会**覆盖），旧会话内容继续可见、甚至继续往旧 sessionId 写库。
    func resetForLogout() {
        imageRetryTask?.cancel()
        imageRetryTask = nil
        saveTask?.cancel()
        saveTask = nil
        awayLandedReplies = [:]
        unread = [:]
        seenTimes = [:]
        lastLoadedSession = nil
        pendingNewSession = false
        pendingNewSessionReset = false
        newSession()          // 生成全新 id（不沿用上一个账号的 sessionId）
    }

    // MARK: - v2.0.58 两步走新建会话
    // MARK: - v2.0.65 未读红点（本地概念：会话有新消息且未打开）

    var unread: [String: Bool] = [:]              // sessionId -> 有未读
    private var seenTimes: [String: TimeInterval] = [:]   // 各会话上次查看时间

    /// 列表加载后同步未读（有 lastTime 且晚于上次查看 → 标未读）
    func syncUnread(from sessions: [ChatSession], currentId: String) {
        for s in sessions {
            guard s.id != currentId, let lt = s.lastTime else { continue }
            if lt > (seenTimes[s.id] ?? 0) + 1000 {
                unread[s.id] = true
            }
        }
    }

    func markRead(_ id: String) {
        unread[id] = nil
        seenTimes[id] = Date().timeIntervalSince1970 * 1000
    }

    var totalUnread: Int { unread.count }

    /// 请求新建会话（只设标志不清数据）：ChatView 观察到后先切欢迎页卸载列表，
    /// 下一帧再 newSession——v2.0.44 的"先切tab再清空"在 tab 切换动画期间（半隐藏状态）
    /// 清空仍崩（用户实测 v2.0.57 新建/删除都闪退）；两步走是清空按钮验证过的稳定模式
    var pendingNewSession = false

    /// v3.4.29：新建会话时是否补发 /new（加号入口 = 等同 /new，触发 gateway 侧上下文一并重置）。
    /// 只换本地 sessionId 不会动 gateway 的会话上下文——这正是「新建会话后 AI 还记得上文」的根因
    var pendingNewSessionReset = false

    func requestNewSession(sendReset: Bool = false) {
        pendingNewSession = true
        pendingNewSessionReset = sendReset
    }

    /// 追加本地消息（发送/流式开始）
    func append(_ m: ChatMessage) {
        // v3.9.31：插入带上滑入位动画事务（Motion.enter）——此前只有 ChatView 发送路径
        // 包 withAnimation，恢复/重试/收件箱等 append 无动画上下文 → 气泡凭空出现。
        // 切会话/清空走 load/clearMessages 的数组替换，不经过这里，不会误播动画。
        withAnimation(Motion.enter) {
            messages.append(m)
        }
        if title.isEmpty, m.isUser, !m.content.isEmpty {
            title = String(m.content.prefix(30))
        }
    }

    /// 流式结束后落库 assistant 消息（与最后一条相同则跳过，防重复）
    /// v2.0.102：去重仅限"连续两条 assistant 内容相同"（流式重复场景）——
    ///           上一条若是用户消息（新一轮提问），即使内容相同也必须新增（修复相同回复被吞）
    /// 扩大去重范围到最近 5 条：极短时间多次调用（重试/网络抖动）可能产生多条相同 assistant
    /// v3.3.3：错位复读根治（2026-09-04 实据）——支持 afterUserID 锚定：回答必须落在
    ///          "发起它的 user 消息"之后。此前所有完成回调无条件 append 到 messages 末尾，
    ///          后台恢复/延迟完成回调执行时若用户已发新消息，旧答被贴到新问题后（App 侧
    ///          历史错位：13:40 的回答 13:43:41 才落库贴在"告诉我哪个版本"后；Hermes 侧
    ///          transcript 全程正常 = 模型无辜，纯 App 落库锚点缺陷）。带锚点时仅在该轮
    ///          回复区（锚点后、下一个 user 前）去重与插入，杜绝跨轮污染。
    func upsertAssistant(_ text: String, agent: Bool = false, afterUserID: String? = nil) {
        let ts = Date().timeIntervalSince1970 * 1000
        // v3.9.35：AI 回复落库时自动提取待办（勾选框行 → 待办清单）。
        // 挂在唯一落库口：正常完成/重试/恢复收尾全覆盖；addAuto 内部按内容去重，
        // 同一条待办多轮重复产出不会重复收录。错误占位（⚠️ 前缀）不含勾选框，天然不触发。
        if text.count >= 8, !text.hasPrefix("⚠️") {
            TodoStore.shared.addAuto(from: text)
        }
        // 🚨 v3.4.22 复读根治第一层：全历史精确查重（在所有分支之前）。
        // 实证（2026-09-08 晚 stream dump）：恢复链路 anchor 失配/重试路径会把同一条旧回答
        // 重复落库 3 次（msg1==msg3==msg7，1284 字完全相同）——原去重只查锚点同轮区域/末尾
        // 8 条，隔了新消息就漏。旧回答一旦重复进历史，模型每轮都能看到 → 持续复读。
        // v3.4.25：加长度门槛——短回复（≤30字）不同上下文可合法同文（"好的"/"1"），全历史
        // 查重会误吞；只对长回复做全历史拦截，短回复仍走锚点区域去重兜底。
        if text.count > 30,
           messages.contains(where: { $0.role == "assistant" && $0.content == text }) {
            return
        }
        if let anchorID = afterUserID,
           let anchorIdx = messages.lastIndex(where: { $0.isUser && $0.id == anchorID }) {
            // 该轮回复区右边界（开区间）：锚点之后直到下一个 user 消息
            var regionEnd = anchorIdx + 1
            while regionEnd < messages.count, !messages[regionEnd].isUser { regionEnd += 1 }
            let region = messages[anchorIdx..<regionEnd]
            // 同轮竞态双落库（正常完成 + 恢复完成/重放）→ 区域内最后一条内容相同则跳过
            if regionEnd - 1 > anchorIdx,
               messages[regionEnd - 1].role == "assistant",
               messages[regionEnd - 1].content == text {
                messages[regionEnd - 1].agent = agent || messages[regionEnd - 1].agent
                return
            }
            // 归一化相似度兜底：改写型重复也跳过
            if isAssistantDuplicate(text, in: region) {
                if let last = region.last, last.role == "assistant" {
                    messages[regionEnd - 1].agent = agent || messages[regionEnd - 1].agent
                }
                return
            }
            // 插入到该轮回复区末尾——其后若有排队/新发 user 消息，保持原位不被错位污染
            var m = ChatMessage(role: "assistant", content: text, timestamp: ts)
            m.agent = agent   // v2.0.96b：Agent 回复标记
            // v3.9.31：插入带上滑入位动画（append 同款；完成回调多为裸调用无动画上下文）
            withAnimation(Motion.enter) {
                messages.insert(m, at: regionEnd)
            }
            noteAssistantLanded(m)   // v3.9.9：本轮回答真正落库 → 触发自动朗读（哪怕它插在数组中段）
            return
        }
        // —— 无锚点：原末尾语义（兼容无发起消息的调用方）——
        let tail = messages.suffix(8)
        // 检查最近 N 条中是否有连续相同内容的 assistant（含当前最后一条）
        if let idx = messages.indices.last, idx > 0,
           messages[idx].role == "assistant", messages[idx].content == text {
            // 检查前面是否有相同内容的 assistant（最近 5 条内任一相同即可去重）
            let hasDuplicateInTail = tail.dropLast().contains { $0.role == "assistant" && $0.content == text }
            if hasDuplicateInTail || (idx > 0 && messages[idx - 1].role == "assistant") {
                messages[idx].agent = agent || messages[idx].agent
                return
            }
        }
        // 归一化相似度兜底：最近 8 条 assistant 文本高度相似则跳过
        if isAssistantDuplicate(text, in: tail) {
            if let lastIdx = messages.indices.last, messages[lastIdx].role == "assistant" {
                messages[lastIdx].agent = agent || messages[lastIdx].agent
            }
            return
        }
        var m = ChatMessage(role: "assistant", content: text, timestamp: ts)
        m.agent = agent   // v2.0.96b：Agent 回复标记
        // v3.9.31：插入带上滑入位动画（append 同款）
        withAnimation(Motion.enter) {
            messages.append(m)
        }
        noteAssistantLanded(m)   // v3.9.9：同上
    }

    /// v2.0.59：按 id 标记消息发送失败（显示重试按钮）
    func markFailed(id: String) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].failed = true
        }
    }

    /// v3.9.41（SR20）：failed 的复位点。原先全仓只有置真、没有任何清零路径——
    /// 自动重试（`autoRetryStream`）复用**同一条** user 消息（不删除、id 不变），
    /// 重试成功后气泡上的 ❗/重试按钮仍在（ChatView:2414 的注释「重试成功会覆盖」是错的），
    /// 用户再点一次就是「删掉这条已送达的消息重发」= 服务器多一轮重复问答。
    func clearFailed(id: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }), messages[idx].failed else { return }
        messages[idx].failed = false
    }

    /// 发送请求用的历史消息（payload 形态）
    /// 只保留最后一条带图消息的 imageDataURL（前面已发过的图片不进 payload，防 base64 全量重复膨胀）
    /// - Parameters:
    ///   - model: 本次请求**实际要用的**模型名（来自 ChatView.resolveModel()，优先级链 视觉>Agent>主）。
    ///            传 nil 时回落到本地 UserDefaults（默认值与 ChatView 的 @AppStorage 一致）。
    ///            为什么要传：闸门必须和真正发出去的模型同源。若只用主模型键兜底，就会丢掉
    ///            resolveModel 的覆盖（视觉模型 / Agent 模型），两侧判定不一致即会误压或漏压。
    ///   - provider: 同上，与 model 成对传入。
    func historyPayload(model: String? = nil, provider: String? = nil) -> [[String: Any]] {
        // v3.0.10：图片保留条件（不降级为文本）
        // 主模型支持视觉 OR 配置了视觉模型自动切换
        let visionOK: Bool = {
            // v3.9.26 fix：取源优先级 —— 入参是本次**真正要发出去的**模型（ChatView.resolveModel() 的
            // 视觉 / Agent / 主 三档覆盖）。此前闸门只读 mainModelAndProvider，等于拿「主模型」
            // 去判断「实际请求的模型」：主模型有视觉而实际路由到无视觉的模型时仍带 base64（静默丢图），
            // 反向则白降级。未传参才回落到统一取源。
            let (curModelName, curProviderName): (model: String, provider: String) = {
                if let m = model, !m.isEmpty { return (m, provider ?? "") }
                return CloudConfig.mainModelAndProvider
            }()
            // ① provider 反例优先于任何持久化标记：
            //    存量配置里的 supportsVision 是旧逻辑（只看模型名）写下并落盘的，
            //    若先被它短路，「商汤 + deepseek-v4-flash」这类同名不同能力的反例永远修不到。
            if CloudConfig.providerDeniesVision(model: curModelName, provider: curProviderName) {
                return false
            }
            // ② 主模型支持视觉 → 直接 OK
            if !curModelName.isEmpty,
               CloudConfig.modelSupportsVision(curModelName, provider: curProviderName) { return true }
            // 主模型不支持 → 开关开 + 有视觉模型配置才保留图片，否则降级文本
            return CloudConfig.visionFallbackEnabled && CloudConfig.localVisionModel != nil
        }()
        // v3.0.83fix：isPush=1 的推送消息不进模型上下文（推送被当AI回复污染对话的根治）
        // 推送消息是 Hermes 主动注入的，不该作为历史喂给模型。保留在会话展示，但历史重放滤掉。
        // v3.1.12：错误占位（⚠️/HTTP Error/连接中断）同样不进上下文——脏历史诱导模型复读
        // v3.4.9 防复读：在滤脏占位后，再做历史净化（去连续重复 assistant / 保证以 user 结尾 /
        //              断掉"紧贴最新 user 的 assistant 续写种子" msgs[-2]）——镜像后端 _sanitize_history
        //              + _break_repeat_seed 的 App 侧防御，确保喂给 Hermes 的上下文不再含"可续写素材"。
        // v3.9.15：断种子这步按模型分流（弱模型才压），判定用**本次真实请求的模型**。
        // v3.9.15：强模型不做「断种子」占位（与后端 _is_strong_model 同规则）——App 此前无条件压占位，
        // 强模型看不到自己上一条回答，用户的短追问（「不用」「为什么」）失去指代对象 → 重跑上一轮任务
        // （2026-09-13 实证：一句「不用」被回三份 NAS 内存诊断）。
        let (curProvider, curModel): (String, String) = {
            if let m = model, !m.isEmpty { return (provider ?? "", m) }
            // 兜底默认值必须与 ChatView 的 @AppStorage 默认值一致（未设置时 @AppStorage 也返回它们）
            return (UserDefaults.standard.string(forKey: "qingliao_provider") ?? "opencode",
                    UserDefaults.standard.string(forKey: "qingliao_model") ?? "deepseek-v4-flash")
        }()
        let breakRepeatSeed = !CloudConfig.isStrongModel(provider: curProvider, model: curModel)
        // SR6：撤回的消息同样不得进模型上下文（原来只滤推送与错误占位，撤回正文照发给 AI）
        let ctxMessages = Self.sanitizeForContext(messages.filter { !$0.isPush && !$0.isErrorPlaceholder && !$0.withdrawn },
                                                  breakRepeatSeed: breakRepeatSeed)
        // v3.4.x code review fix：落实注释原语义——只保留"最后一条带图消息"的 imageDataURL
        //（前面已发过的图片不进 payload，防 base64 全量重复膨胀）；其余带图消息降级为 [图片] 占位文本
        let lastImageIdx = ctxMessages.lastIndex { $0.imageDataURL != nil }
        return ctxMessages.enumerated().map { (i, m) in
            // v3.9.60：图片串决策——`data:` 原样；落库 URL 只认本地缓存（上游下不到只有 IPv6 的自家地址，
            // 见 sendableImageURL 注释）。拿不到 base64 时**绝不**把 URL 发出去，走下面的文本降级。
            // 发送前按网络档位压一档：历史图过去走 URL（body 很小），现在走 base64，不压会撑爆上行
            let sendable = Self.sendableImageURL(m.imageDataURL, cache: localImageBase64)
                .map { self.sizedForSend($0) }
            var p = m.asPayload(imageURLOverride: sendable ?? "")
            if m.imageDataURL == nil {
                p["content"] = m.content
            } else if i != lastImageIdx || !visionOK || sendable == nil {
                // 非最后一条带图消息：图片不再携带 base64，降级为文本（内容 + [图片] 标记）；
                // 最后一条但当前不支持视觉 → 同样降级（原逻辑）
                let t = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
                p["content"] = t.isEmpty ? "[图片]" : t + "\n[图片]"
            }
            return p
        }
    }

    /// v3.4.9 防复读：历史净化（镜像后端 `_sanitize_history` + `_break_repeat_seed` 的 App 侧防御）。
    ///
    /// 复读根因（2026-09-03 实证）：模型"续写"上下文里紧邻的旧 assistant 回复/工具播报结语，而非回答新问题。
    /// 三原则：
    ///   ① 剔脏占位——isPush / 错误占位（⚠️/HTTP Error/连接中断）已在上层 filter 剔除。
    ///   ② 去连续重复 assistant/user——连续相同 assistant 或 user 只留最后一条（复读产物）。
    ///   ③ 保证以 user 结尾——剥离末尾孤立 assistant/system，防模型续写旧回复；
    ///      并把"紧贴最新 user 的 assistant（msgs[-2]）"压缩为不可续写占位，断掉可续写素材。
    /// 只压缩成占位、绝不删除内容；对过期历史同样生效——喂进上下文的复读种子被抽掉，弱模型不再复读。
    /// ⚠️ 第③步**只对弱模型**生效（`breakRepeatSeed=false` 时跳过）：强模型被压会失忆，
    /// 用户的短追问（「不用」「为什么」）失去指代对象 → 重跑上一轮任务。规则同后端 `_is_strong_model`。
    ///
    /// v3.9.15：第③步（断种子占位）改成**按模型开关**（`breakRepeatSeed`）。强模型被压会失忆 →
    /// 用户的短追问失去指代对象 → 重跑上一轮任务；规则与后端 `_is_strong_model` 一致。
    private static func sanitizeForContext(_ msgs: [ChatMessage],
                                           breakRepeatSeed: Bool) -> [ChatMessage] {
        var out: [ChatMessage] = []
        // 🚨 v3.4.22 复读根治第二层：全历史 assistant 去重（不要求连续）。
        // 存量损坏会话里同一条旧回答可能已重复 N 次（非连续分布），原"连续相同"过滤拦不住；
        // 重复旧回答进上下文 = 模型每轮都有复读素材。同文只保留最早一条。
        var seenAssistant = Set<String>()
        for m in msgs {
            if m.role == "assistant" {
                if !seenAssistant.insert(m.content).inserted { continue }
            }
            // ② 连续相同 assistant 只留最后一条（复读产物）
            if m.role == "assistant",
               let last = out.last, last.role == "assistant",
               last.content == m.content {
                continue
            }
            // ②.5 v3.4.18 复读根治：连续相同 user 只留最后一条。
            // 发送重试/恢复错位会在历史里堆出 N 条相同 user（后端 body_dump 实证 8 条
            // 重复 user 淹没最新问题），原样进上下文 → 模型把旧问题当最新问题作答。
            if m.role == "user",
               let last = out.last, last.role == "user",
               last.content == m.content {
                continue
            }
            out.append(m)
        }
        // ③ 剥离末尾孤立 assistant/system → 保证以 user 结尾
        while let last = out.last, last.role != "user" {
            out.removeLast()
        }
        // ③ 断掉"紧贴最新 user 的 assistant 续写种子"（msgs[-2]）：压缩为不可续写占位
        // ⚠️ v3.9.15：只对弱模型做（breakRepeatSeed=false 时跳过）——强模型需要看得到自己上一条回答，
        // 否则短追问（「不用」「为什么」）无指代对象，模型会重跑上一轮任务。
        if breakRepeatSeed,
           out.count >= 2, out[out.count - 1].role == "user", out[out.count - 2].role == "assistant" {
            let prev = out[out.count - 2]
            let placeholder = ChatMessage(role: prev.role,
                                          content: "（上一轮回复已省略，请直接回答最新用户消息，不要续写或复述此条内容）",
                                          timestamp: prev.timestamp, imageDataURL: prev.imageDataURL)
            out[out.count - 2] = placeholder
        }
        // 边界保护：若剥离后全空（异常历史），保留最后一条原始消息，避免模型收到空上下文
        if out.isEmpty, let lastOriginal = msgs.last {
            out = [lastOriginal]
        }
        return out
    }

    /// 保存会话（走后端 /api/sessions/merge）
    /// 本地模式：POST /api/sessions/merge（2.0 原逻辑）
    /// 云端模式：写 App 本地文档（防云端会话串进本地 AI 后端 sessions）
    /// 图片消息降级为文本（不带 base64 data URL，防 sessions.json 膨胀；历史重放本就不渲染图片）
    /// v3.0.7 fix：debounce 机制——快速切换会话/连续操作时只保存最后一次，防覆盖
    func saveToServer(auth: AuthStore) async {
        saveTask?.cancel()
        // 快照当前状态（cancel 后旧 Task 读到的是旧快照）
        let sid = sessionId
        let msgs = messages
        let t = title
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.saveToServer(auth: auth, sessionId: sid, messages: msgs, title: t)
        }
    }

    // v3.4.25：写库串行链——所有 saveToServer 的实际网络写经此 FIFO 排队。
    // 根治乱序覆盖：旧快照的网络写若慢于新快照（500ms 防抖后仍可能并发在途），
    // 后到者会以旧消息数组覆盖新数组丢消息；串行链保证写入顺序 = 调度顺序，
    // 最终落库状态必为最新快照。
    private var saveWriteChain: Task<Void, Never> = Task {}

    /// 参数化快照版：切换会话前调用——切换会清空 messages，异步保存若不捕获快照会读到空数组丢会话。
    /// v3.4.x fix：图片消息保留 imageDataURL，避免重启/切会话后只剩 [图片] 占位
    /// SR5：`allowEmpty` 只有「清空本会话」这一条显式路径传 true。默认 false 的护栏要留着——
    /// 切会话/冷启动等很多地方读的是 messages 快照，一旦拿到空数组就写库会把线上整会话抹掉。
    func saveToServer(auth: AuthStore, sessionId sid: String, messages msgs: [ChatMessage],
                      title t: String, allowEmpty: Bool = false) async {
        let prev = saveWriteChain
        saveWriteChain = Task { [weak self] in
            await prev.value   // 等前一个写完成（FIFO）
            await self?.writeSessionSnapshot(auth: auth, sessionId: sid, messages: msgs,
                                             title: t, allowEmpty: allowEmpty)
        }
        await saveWriteChain.value
    }

    /// v3.9.39：消息序列化的**唯一**口径。后端 merge 对同 id 会话是整体覆盖
    /// （sessions_api.merge_sessions：App 不发 updatedAt，恒 `0 >= 0` → incoming 全量替换），
    /// 因此少写一个字段就等于把该字段在线上抹掉。任何要写整会话的路径（含会话列表改名）
    /// 都必须走这里，不要再各自复制一份 map——历史上复制出的两份都已漂移（都漏了 audioPath → [语音]）。
    static func messagesPayload(_ msgs: [ChatMessage]) -> [[String: Any]] {
        msgs.map { m in
            var p: [String: Any] = ["role": m.role, "content": m.content]
            if let ts = m.timestamp { p["timestamp"] = ts }
            if let img = m.imageDataURL, !img.isEmpty {
                p["imageDataURL"] = img
            }
            // v3.4.x code review fix：持久化 uid，跨重启消息 id 稳定（消息唯一性/杀后台锚定依赖）
            if let u = m.uid, !u.isEmpty { p["uid"] = u }
            if m.audioPath != nil {
                p["content"] = "[语音]"
            }
            // SR6：撤回状态此前**只存在于内存**——payload 不写 withdrawn、parse 也不读，
            // 于是「撤回」后任何一次重启/重进会话，原文就从 NAS 原样回来了（且仍照旧进模型上下文）。
            // 现在写标记并**同时清空正文**：撤回的语义就是内容不再存在，别只靠客户端自觉隐藏。
            if m.withdrawn {
                p["withdrawn"] = true
                p["content"] = ""
                p["imageDataURL"] = nil
            }
            if m.isPush { p["isPush"] = true }
            if m.agent { p["agent"] = true }
            // v3.4.x：持久化引用原文（重启/切会话后气泡仍渲染）
            if let q = m.quotedText, !q.isEmpty { p["quotedText"] = q }
            return p
        }
    }

    /// 实际写库（原 saveToServer 参数版逻辑，移入此名；由串行链调用）
    private func writeSessionSnapshot(auth: AuthStore, sessionId sid: String, messages msgs: [ChatMessage], title t: String, allowEmpty: Bool = false) async {
        guard allowEmpty || !msgs.isEmpty else { return }
        let msgsPayload = Self.messagesPayload(msgs)
        let firstUserText = msgs.first(where: { $0.isUser })?.content.prefix(30).description ?? ""
        let payload: [String: Any] = [
            "id": sid,
            "title": t.isEmpty ? firstUserText : t,
            "messages": msgsPayload
        ]
        do {
            _ = try await auth.request("/api/sessions/merge", method: "POST", body: [
                "sessions": [payload],
                "deleted": [] as [Any]
            ])
        } catch {
            print("[saveToServer] 保存会话失败 sid=\(sid.prefix(8)) error=\(error.localizedDescription)")
        }
    }

    // MARK: - v2.0.36

    /// 导出当前会话为纯文本（用户/AI 消息 + 时间）
    func exportText() -> String {
        var lines: [String] = []
        lines.append("轻聊会话导出 · " + (title.isEmpty ? "未命名会话" : title))
        lines.append("===================================")
        for m in messages {
            let who = m.isUser ? "我" : "AI"
            let t = m.timestamp.map { ts -> String in
                let d = Date(timeIntervalSince1970: ts / 1000)
                return Self.exportDateFormatter.string(from: d)
            } ?? ""
            var content = m.content
            if m.imageDataURL != nil {
                let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
                content = c.isEmpty ? "[图片]" : c + "\n[图片]"
            }
            lines.append("\n[\(who) \(t)]")
            lines.append(content)
        }
        return lines.joined(separator: "\n")
    }

    /// v3.0.22：导出为 Markdown 格式（保留结构化排版）
    func exportMarkdown() -> String {
        var lines: [String] = []
        lines.append("# " + (title.isEmpty ? "未命名会话" : title))
        lines.append("")
        for m in messages {
            let who = m.isUser ? "**我**" : "**AI**"
            let t = m.timestamp.map { ts -> String in
                let d = Date(timeIntervalSince1970: ts / 1000)
                return Self.exportMDDateFormatter.string(from: d)
            } ?? ""
            var content = m.content
            if m.imageDataURL != nil {
                let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
                content = c.isEmpty ? "![图片]" : c + "\n![图片]"
            }
            lines.append("### \(who) · \(t)")
            lines.append("")
            lines.append(content)
            lines.append("")
            lines.append("---")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// 清空当前会话消息（保留会话 id 与标题）
    func clearMessages() {
        messages = []
    }

    // MARK: - v2.0.43 上下文管理 / 搜索定位

    /// 搜索定位目标（从会话列表点搜索结果时设置，ChatView 滚动+高亮）
    var highlightTarget: (role: String, content: String)?

    /// 上下文估算（近似 token = 字符数/4 + 消息数基础开销）
    var contextInfo: (tokens: Int, count: Int) {
        let chars = messages.reduce(0) { $0 + $1.content.count }
        return (chars / 4 + messages.count * 3, messages.count)
    }

    /// 压缩上下文：保留最近 20 条，更早的消息替换为一条占位标记
    /// （本地压缩不调 AI 摘要，立省 token；需要摘要可让 AI 从占位标记处续聊）
    func compressContext(keepLast: Int = 20) -> Bool {
        guard messages.count > keepLast + 1 else { return false }
        let dropped = messages.count - keepLast
        let firstUser = messages.first { $0.isUser }?.content.prefix(30).description ?? ""
        let marker = ChatMessage(role: "system", content: "（已压缩上下文：早期对话共 \(dropped) 条已省略，首条主题：\(firstUser)）",
                                 timestamp: messages.first?.timestamp)
        messages.removeFirst(dropped)
        messages.insert(marker, at: 0)
        return true
    }

    /// AI 摘要压缩：用 AI 总结旧消息，替换为一条摘要，保留最近 keepLast 条
    /// 返回 true = 压缩成功，false = 无需压缩或失败
    @MainActor
    func compressContextWithAI(auth: AuthStore, keepLast: Int = 20) async -> Bool {
        guard messages.count > keepLast + 1 else { return false }
        // SR3：「读旧消息 → await AI 摘要 → 整体覆写 messages」中间隔着一次网络 await。
        // 期间切到别的会话（chat.load 换掉 messages/sessionId）后再覆写，会把 A 的摘要
        // 压进 B 的消息列表，并以 B 的 sessionId 落库——后端同 id 是全量替换，直接毁掉 B 的历史。
        let startSid = sessionId
        let startCount = messages.count
        let oldMessages = Array(messages.prefix(messages.count - keepLast))
        let recentMessages = Array(messages.suffix(keepLast))

        // 构建摘要请求：把旧消息拼成文本让 AI 总结
        let conversationText = oldMessages.map { m in
            let role = m.isUser ? "用户" : "AI"
            let content = m.content.prefix(200) // 截断过长消息
            return "\(role): \(content)"
        }.joined(separator: "\n")

        let summaryPrompt = "请用简洁的要点总结以下对话内容（保留关键信息、结论、待办，不超过200字）：\n\n\(conversationText)"

        // 调用 AI 摘要（用当前模型）
        let model = UserDefaults.standard.string(forKey: "qingliao_model") ?? "deepseek-v4-flash"
        let provider = UserDefaults.standard.string(forKey: "qingliao_provider") ?? "deepseek"

        do {
            // 直接 await（无需 withCheckedThrowingContinuation + Task 嵌套，
            // 避免外层取消时 continuation 永远不 resume 的泄漏）
            let payload: [String: Any] = [
                "model": model,
                "provider": provider,
                "messages": [["role": "user", "content": summaryPrompt]],
                "stream": false
            ]
            let j = try await auth.json("/api/stream/chat", method: "POST", body: payload)
            var summary: String = ""
            if let content = j["content"] as? String {
                summary = content
            } else if let choices = j["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let message = first["message"] as? [String: Any],
                      let content = message["content"] as? String {
                summary = content
            }

            guard !summary.isEmpty else {
                // 摘要失败，降级为本地压缩
                print("[ContextCompress] AI摘要为空，降级本地压缩")
                guard sessionId == startSid else { return false }   // 本地降级按当前消息重算，只需会话没变
                return compressContext(keepLast: keepLast)
            }

            // 用摘要替换旧消息
            let marker = ChatMessage(role: "system",
                                     content: "（AI 摘要：\(summary)）",
                                     timestamp: oldMessages.first?.timestamp)
            // 覆写用的是 await 之前的快照：必须会话没变、且期间没插新消息
            guard sameCompressTarget(sid: startSid, count: startCount) else { return false }
            messages = [marker] + recentMessages
            print("[ContextCompress] AI摘要压缩成功：\(oldMessages.count)条→摘要 + \(recentMessages.count)条")
            return true

        } catch {
            // AI 调用失败，降级为本地压缩
            print("[ContextCompress] AI摘要失败(\(error.localizedDescription))，降级本地压缩")
            guard sessionId == startSid else { return false }
            return compressContext(keepLast: keepLast)
        }
    }

    /// SR3：覆写前的会话归属校验——sid 未变（没切会话）且条数未变（await 期间没插新消息）。
    /// 任一不满足就放弃这次压缩（下一条消息再触发），也不能拿旧快照去写 messages。
    private func sameCompressTarget(sid: String, count: Int) -> Bool {
        sessionId == sid && messages.count == count
    }

    /// 检查是否需要压缩（基于 token 阈值）
    /// 返回 true = 需要压缩
    func needsCompress(threshold: Int = 4000) -> Bool {
        return contextInfo.tokens > threshold
    }

    /// 上下文使用率（0.0 ~ 1.0+）
    func contextUsage(maxTokens: Int = 8000) -> Double {
        return Double(contextInfo.tokens) / Double(maxTokens)
    }

    /// 按角色+内容前缀查找消息索引（搜索定位用，内容太长时前缀匹配）
    func indexOfMessage(role: String, contentPrefix: String) -> Int? {
        let prefix = String(contentPrefix.prefix(60))
        return messages.firstIndex {
            $0.role == role && $0.content.hasPrefix(prefix)
        }
    }

    // MARK: - v3.0.51 A1 图片持久化增强（待传队列 + 失败重传 + 重启续传）

    /// SR4：同一时刻只允许一条重传链（切会话/前台回 App 会反复触发，旧链不取消会并发写 messages）。
    @ObservationIgnored private var imageRetryTask: Task<Void, Never>?
    /// v3.9.60：图片 base64 预取链（独立于补传链，见下）
    @ObservationIgnored private var imagePrefetchTask: Task<Void, Never>?

    func startImageRetryUploads(auth: AuthStore) {
        // v3.9.60：预取（下载已落库的图换回 base64）与补传（上传仍是 base64 的图）拆成两条链——
        // 预取走的是网络下载（Wi-Fi 直连超时 30s），串在补传前面会把「补传」这条原始职责一起顶住。
        imagePrefetchTask?.cancel()
        imagePrefetchTask = Task { [weak self] in
            await self?.prefetchStoredImagesForSend(auth: auth)
        }
        imageRetryTask?.cancel()
        imageRetryTask = Task { [weak self] in
            await self?.retryPendingImageUploads(auth: auth)
        }
    }

    /// 扫描 messages 里仍为 base64（data:image/）的用户图片消息，重传换 URL。
    /// 队列天然派生自消息数组（重启后内存 messages 重新加载，残留 base64 的就是待传的），无需单独持久化。
    /// 触发点：会话加载后 / 前台回到 App / 发送路径降级后。
    /// 保持类级 MainActor 隔离（与改前一致）：链上的 `await uploadImage(...)` 全程是协作挂起，
    /// 不占主线程；写成 nonisolated 反而会让每次读写 messages 都得显式 hop，收益为零。
    func retryPendingImageUploads(auth: AuthStore, maxRetries: Int = 3) async {
        // SR4：原实现预取了一组**下标**，中间夹多次 await（上传 + 指数退避 sleep），
        // 回来只判 `indices.contains(idx)` 就写 messages[idx] —— 删除/切会话后下标仍合法，
        // 会把 A 会话的图 URL 写到 B 会话的第 N 条消息上，并用**当时的** sessionId 落库（全量替换）。
        // 现在：按 uid 定位、每轮校验会话没变、并响应任务取消（切会话/退出会 cancel 这个 Task）。
        let sid = sessionId
        let targets: [(uid: String?, content: String, timestamp: TimeInterval?, b64: Data)] = messages.compactMap { m in
            guard m.isUser, let img = m.imageDataURL, img.hasPrefix("data:image/"),
                  let comma = img.firstIndex(of: ",") else { return nil }
            guard let data = Data(base64Encoded: String(img[img.index(after: comma)...]),
                                  options: .ignoreUnknownCharacters) else { return nil }
            return (m.uid, m.content, m.timestamp, data)
        }
        guard !targets.isEmpty else { return }
        for target in targets {
            guard sessionId == sid, !Task.isCancelled else { return }
            // 无 uid 的历史消息（老数据）退化为「内容+时间戳」定位，命中不唯一时宁可不重传
            func locate() -> Int? {
                if let uid = target.uid, !uid.isEmpty {
                    return messages.firstIndex { $0.uid == uid }
                }
                let hits = messages.indices.filter {
                    messages[$0].isUser && messages[$0].content == target.content
                        && messages[$0].timestamp == target.timestamp
                        && (messages[$0].imageDataURL?.hasPrefix("data:image/") ?? false)
                }
                return hits.count == 1 ? hits[0] : nil
            }
            guard locate() != nil else { continue }   // 该消息已被删除/替换 → 跳过
            // 指数退避重试
            var ok: String? = nil
            for attempt in 0..<maxRetries {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
                }
                if Task.isCancelled || sessionId != sid { return }
                ok = await uploadImage(target.b64, auth: auth)
                if ok != nil { break }
            }
            guard let url = ok, sessionId == sid, !Task.isCancelled else { continue }
            guard let idx = locate() else { continue }
            messages[idx].imageDataURL = url
            // 会话没变（上面已判）→ 用参数化重载显式落到 sid，防止读到已被换掉的 self.sessionId
            await saveToServer(auth: auth, sessionId: sid, messages: messages, title: title)
        }
    }

    // MARK: - v3.9.60 图片发送串决策（payload 用 base64，落库仍存 URL）

    /// 落库 URL → 本地 base64（进程内内存，不持久化；重启后由 prefetchStoredImagesForSend 回填）。
    /// 只留最近 `localImageMaxEntries` 条（FIFO）：payload 只用「最后一条带图消息」，留多了纯占内存
    /// ——base64 是原字节 +33%，3MB 的图一条就 4MB 常驻。
    @ObservationIgnored private var localImageBase64: [String: String] = [:]
    /// 插入序（配合上面的 FIFO 淘汰；Dictionary 本身无序）
    @ObservationIgnored private var localImageOrder: [String] = []
    /// 发送前的下采样结果缓存（key = 串的**哈希**，不是串本身——拿整条 base64 当 key 等于又常驻一份 MB）
    @ObservationIgnored private var localImageSized: [String: String] = [:]
    @ObservationIgnored private var localImageSizedOrder: [String] = []
    private static let localImageMaxEntries = 3
    /// 字节预算：条数有上限还不够（预取单条可到 2MB → 3 条 ≈ 8MB 常驻），超预算从队首淘汰
    private static let localImageMaxBytes = 6 * 1024 * 1024
    /// 预取单条上限：别把 MB 级原图捞回内存（与蜂窝上行 4MB 闸门同口径，见 RemoteFiles.cellularSafeBytes）
    private static let prefetchMaxBytes = 2 * 1024 * 1024
    /// 蜂窝下多大的串才值得压：小于它多半已是压缩过的小图（再压只会更糊 + 白耗 CPU）
    private static let cellularDownscaleThreshold = 300_000
    /// WiFi 侧的体积闸门（v3.9.60 起 WiFi 的图也走 base64，不再有「几百字节 URL」这条退路）
    private static let wifiDownscaleThreshold = 1_500_000

    /// 发送给模型时用的图片串（纯函数，真值表覆盖；**不许**在图块里出现自家 http URL）：
    ///   · `data:` 开头（本地 base64）→ 原样
    ///   · `http(s)` 开头（已落库为 URL）→ 只认本地缓存；未命中返回 nil（调用方降级 [图片]）
    ///   · 其它/空 → nil
    ///
    /// 为什么不能把 http URL 交给模型：图片 URL 指向自家 `webui.<域名>`，该域**只有 AAAA（IPv6）、
    /// 没有 A 记录**（2026-09-23 在 NAS 上 `nslookup -type=A` 实测 No answer），而上游厂商
    /// （DeepSeek / StepFun / 智谱…）是 IPv4 云 → 必现
    /// `HTTP 400 .messages[1].image[0]: Failed to download image from https://webui.<域名>:16666/...`。
    /// 结论：图片必须以 base64 内嵌发送，URL 只用于 App 本地显示与落库。
    static func sendableImageURL(_ stored: String?, cache: [String: String]) -> String? {
        guard let s = stored, !s.isEmpty else { return nil }
        if s.hasPrefix("data:") { return s }
        if s.hasPrefix("http") { return cache[s] }
        return nil
    }

    /// 发送前把待发 base64 压到「该网络能载得动」的档位并缓存（只压大串；压不动 → 原样返回）。
    /// 为什么要在这一层做：v3.9.60 起历史图也以 base64 进 body（过去是 URL，body 很小），
    ///   · 蜂窝：CFStream 直连 / relay 载不动大 body（v3.0.52/53 实踩 bad json 400）→ 480px / 0.45
    ///   · WiFi：没有 CFStream 限制，但 MB 级 body 只会给上游添堵 → 1024px / 0.6 兜底
    private func sizedForSend(_ b64: String) -> String {
        let cellular = NetworkMonitor.shared.isCellular
        let threshold = cellular ? Self.cellularDownscaleThreshold : Self.wifiDownscaleThreshold
        guard b64.count > threshold else { return b64 }
        let key = String(b64.hashValue)
        if let hit = localImageSized[key] { return hit }
        let out = ImageDownscale.dataURL(
            b64,
            maxSide: cellular ? ImageDownscale.cellularMaxSide : ImageDownscale.wifiMaxSide,
            quality: cellular ? ImageDownscale.cellularQuality : ImageDownscale.wifiQuality
        ) ?? b64
        localImageSized[key] = out
        if let i = localImageSizedOrder.firstIndex(of: key) { localImageSizedOrder.remove(at: i) }
        localImageSizedOrder.append(key)
        while localImageSizedOrder.count > Self.localImageMaxEntries {
            localImageSized[localImageSizedOrder.removeFirst()] = nil
        }
        return out
    }

    /// 上传成功（拿到可落库 URL）时把原始字节登进内存缓存，供本次发送的 payload 使用（FIFO + 字节预算）。
    /// 魔数不认识（不是图 / mp4 / avif…）就**不登记**：宁可发送时降级成 [图片]，也别贴个 image/jpeg 骗上游。
    func rememberLocalImage(url: String, imageData: Data) {
        guard !url.isEmpty, let mime = Self.imageMime(imageData) else { return }
        localImageBase64[url] = "data:" + mime + ";base64," + imageData.base64EncodedString()
        if let i = localImageOrder.firstIndex(of: url) { localImageOrder.remove(at: i) }
        localImageOrder.append(url)
        while localImageOrder.count > Self.localImageMaxEntries
            || localImageBase64.values.reduce(0, { $0 + $1.count }) > Self.localImageMaxBytes {
            let old = localImageOrder.removeFirst()
            localImageBase64[old] = nil
        }
    }

    /// 图片字节 → MIME；**不是图片返回 nil**（别把 mp4/avif 当 heic 塞进 payload —— 上游会拒，
    /// 正是本次要修的那类 400）。原先 mimeForImage / looksLikeImage 是同一组探针写两遍，已合并。
    static func imageMime(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(12))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
           b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A { return "image/png" }
        if b.count >= 12, String(bytes: b[4..<8], encoding: .ascii) == "ftyp" {
            // ftyp 是「ISO BMFF 家族」的共用头：mp4 / avif / m4a 也是它——必须核 brand，别一律当 heic
            switch String(bytes: b[8..<12], encoding: .ascii) ?? "" {
            case "heic", "heix", "hevc", "heim", "heis", "mif1": return "image/heic"
            default: return nil
            }
        }
        if b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: b[8..<12], encoding: .ascii) == "WEBP" { return "image/webp" }
        if b.count >= 3, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        return nil
    }

    /// 落库图片 URL → 自家下载端点路径（相对路径，走 auth.request 带 X-Auth-Token）。
    /// 形态不对（不是自家端点 / 相对路径 / 带 fragment 变体）→ nil：预取宁可跳过，别拿错路径去要图。
    /// 抽成纯函数是为了能进真值表——内联在 prefetch 里没法测（真值表只能测纯函数）。
    static func downloadPath(from url: String) -> String? {
        guard url.hasPrefix("http"), let q = url.firstIndex(of: "?"),
              url[..<q].hasSuffix("/api/files/download") else { return nil }
        let qs = String(url[q...])
        guard !qs.contains("#") else { return nil }   // fragment 不会被发到服务器 → 拿回来的是 404 页
        return "/api/files/download" + qs
    }

    /// v3.9.60：把 messages 里最近的「已落库为 http URL」用户图片下载回 base64 填缓存。
    /// 触发点：冷启动（QingliaoApp 的 .task）/ 切会话（与 startImageRetryUploads 同处）。
    ///
    /// 为什么取「最近 N 条」而不是只取最后一条：payload 的判定基于**净化后**的 ctxMessages
    /// （会剔掉连续重复的纯图消息），只挑一条可能正好挑中会被剔掉的那条 → 缓存了却不命中。
    ///
    /// ⚠️ 蜂窝下一律不预取：`auth.request` 对带 query 的请求必然落 relay 分支，而 relay 每次都新建
    /// ASWebAuthenticationSession（无授权缓存）→ 冷启动就弹系统 Safari 授权窗；relay 还是**串行**队列，
    /// 会把用户紧接着的聊天请求排到后面；且 relay 响应体经 JSON 字符串 → utf8 重编码，二进制图必坏。
    /// 即纯白跑还扰民。蜂窝下拿不到就拿不到，发送时按既定口径降级 [图片]。
    func prefetchStoredImagesForSend(auth: AuthStore) async {
        guard !NetworkMonitor.shared.isCellular else { return }
        var targets: [String] = []
        for m in messages.reversed() where m.isUser {
            guard let u = m.imageDataURL, u.hasPrefix("http"),
                  localImageBase64[u] == nil, !targets.contains(u) else { continue }
            targets.append(u)
            if targets.count >= Self.localImageMaxEntries { break }
        }
        for url in targets {
            if Task.isCancelled { return }
            guard let path = Self.downloadPath(from: url) else { continue }
            guard let (data, resp) = try? await auth.request(path), resp.statusCode == 200,
                  !data.isEmpty, data.count <= Self.prefetchMaxBytes,
                  Self.imageMime(data) != nil else { continue }
            rememberLocalImage(url: url, imageData: data)
        }
    }

    // MARK: - v3.0.27 图片持久化

    /// 上传图片到服务器，返回可访问的 URL（落库用）；同时把原始字节登进本地缓存（发送 payload 用）。
    func uploadImage(_ imageData: Data, auth: AuthStore) async -> String? {
        let url = await uploadImageInner(imageData, auth: auth)
        if let url { rememberLocalImage(url: url, imageData: imageData) }
        return url
    }

    /// 真正干活的上传实现（两个入口——WiFi multipart / 蜂窝分片——各自返回落库 URL）
    private func uploadImageInner(_ imageData: Data, auth: AuthStore) async -> String? {
        // v3.0.54：蜂窝分片上传 —— URLSession multipart 在蜂窝 IPv6 POST 必挂（退回 base64 大 body
        // → CFStream/relay 载不动 → bad json 400）。蜂窝改走 auth.request（CFStream 直连+relay 兜底、
        // 自动带 X-Auth-Token，正是文字聊天走通的小 body 通路）把图切小片 JSON base64 上传、服务端重组。
        // WiFi 仍走原 URLSession 直连大文件，质量不变。
        if NetworkMonitor.shared.isCellular {
            return await uploadImageChunked(imageData, auth: auth)
        }
        // v3.4.x code review fix（高）：上传目标必须是自家 NAS（auth.serverURL），此前误用
        // 端点 /api/files/upload → WiFi 图片持久化恒打错主机静默失败，且把 NAS 的 X-Auth-Token
        // 发给了第三方云厂商（token 泄露面）。现统一拼 NAS：X-Auth-Token 只发自家服务器；
        guard let base = Self.nasBaseURL(auth: auth) else { return nil }
        guard let url = URL(string: base + "/api/files/upload") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(auth.token, forHTTPHeaderField: "X-Auth-Token")

        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileURL = json["url"] as? String else { return nil }
        // v3.0.37：后端返回相对路径 → 拼 NAS base 成完整可访问 URL
        if fileURL.hasPrefix("/") {
            return base + fileURL
        }
        return fileURL
    }

    /// 蜂窝分片上传：把图片切小块 base64，逐片经 auth.request（直连+relay 兜底）传 /api/files/upload_chunk，
    /// 服务端按 offset 写 staging、收齐自动组回完整文件返回 url。
    /// 片大小自适应：从 16KB 起，某一片失败 → 整体减半重试（换新 uploadId），直到摸出蜂窝能通过的临界值。
    private func uploadImageChunked(_ imageData: Data, auth: AuthStore) async -> String? {
        // v3.4.x code review fix（高）：与 WiFi 路径同源——目标主机取 NAS（auth.serverURL），
        // 相对路径回填拼 NAS 专属地址（v3.9.28：云端厂商 baseURL 分支已随云端模式移除）。
        guard let base = Self.nasBaseURL(auth: auth) else { return nil }

        var slice = min(imageData.count, 16 * 1024)
        while slice >= 1024 {
            let uploadId = UUID().uuidString
            let total = (imageData.count + slice - 1) / slice
            var success = true
            var index = 0
            var offset = 0
            while offset < imageData.count {
                let len = min(slice, imageData.count - offset)
                let chunkB64 = imageData.subdata(in: offset..<(offset + len)).base64EncodedString()
                let payload: [String: Any] = [
                    "uploadId": uploadId, "index": index, "total": total,
                    "ext": "jpg", "slice": slice, "base64": chunkB64,
                ]
                guard let (data, resp) = try? await auth.request("/api/files/upload_chunk", method: "POST", body: payload),
                      resp.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    success = false
                    break
                }
                // 最后一片：服务端返回组装好的 fileURL
                if let rel = json["url"] as? String {
                    if rel.hasPrefix("/") {
                        return base + rel
                    }
                    return rel
                }
                offset += len
                index += 1
            }
            if success { break }
            slice /= 2
        }
        return nil
    }

    /// NAS 上传基准地址（从 auth.serverURL 归一化：补 scheme、去尾斜杠）。
    /// 空/不可用返回 nil（调用方走 base64 fallback）。
    private static func nasBaseURL(auth: AuthStore) -> String? {
        var base = auth.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return nil }
        if !base.hasPrefix("http") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }
}
