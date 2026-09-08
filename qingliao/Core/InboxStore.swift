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
                await consumeOne(id: id, text: text, sourceTaskId: sourceTaskId,
                                 taskType: taskType, auth: auth, chat: chat)
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
            guard !items.isEmpty else { return }
            // v3.0.90 fix：流式进行中不注入。后端 AI 回复 done 即推收件箱（_maybe_push_app），
            // 而流式回复要等 done → finish → upsertAssistant 才落库到 chat.messages；若本轮
            // 轮询抢在落库前拉到推送，shouldSkipDuplicate 遍历不到这条回复 → 误判不重复 →
            // 重复注入（AI 回答气泡 + 🔔推送气泡同内容）。流式中跳过本轮（不 markDone），
            // 流结束 15s 后下一轮再比对，此时回复已落库，去重必然命中。
            if let s = stream, s.isStreaming { return }
            for it in items {
                await consumeOne(id: it.id, text: it.text, sourceTaskId: it.sourceTaskId,
                                 taskType: it.taskType, auth: auth, chat: chat)
            }
            // 注入后保存会话，让推送消息也落库（用户切会话/重开还能看到）
            await chat.saveToServer(auth: auth)
        } catch {
            lastError = "\(error)"
        }
    }

    /// v3.4.23：单条收件消息消费（去重 → 分流任务中心/会话气泡 → 通知 → 标已读）。
    /// pollOnce（5s 轮询）与 ingestPiggyback（搭载投递）共用。
    private func consumeOne(id: String, text: String, sourceTaskId: String?, taskType: String,
                            auth: AuthStore, chat: ChatStore) async {
        guard !consumedIds.contains(id) else {
            await markDone(id, auth: auth)
            return
        }
        consume(id)
        // 非 reply（定时/后台/系统事件）不注入会话气泡，进任务中心列表
        if taskType != "reply" {
            TaskCenterStore.shared.add(TaskCenterItem(
                id: id, text: text, taskType: taskType,
                sourceTaskId: sourceTaskId))
            NotificationHelper.notify(title: "轻聊 · 任务", body: text, sessionId: chat.sessionId)
            await markDone(id, auth: auth)
            return
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
    private func shouldSkipDuplicate(push text: String, in messages: [ChatMessage], extra: String = "", sourceTaskId: String? = nil) -> Bool {
        InboxDedup.shouldSkip(push: text, in: messages, extra: extra, sourceTaskId: sourceTaskId, currentTaskId: stream?.taskId)
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

    private func inboxItems(_ auth: AuthStore) async throws -> [(id: String, text: String, sourceTaskId: String?, taskType: String)] {
        let json = try await auth.json("/api/inbox", method: "GET")
        guard let arr = json["items"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let id = d["id"] as? String, let text = d["text"] as? String else { return nil }
            return (id, text, d["source_task_id"] as? String, d["task_type"] as? String ?? "reply")
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
            if core.count >= 10, cm.contains(core) || core.contains(cm) { return true }
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
