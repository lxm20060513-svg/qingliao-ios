import Foundation
import Observation

// MARK: - 聊天会话状态：当前会话 id + 消息列表（UserDefaults 持久化当前会话）

@MainActor
@Observable
final class ChatStore {
    var sessionId: String
    var messages: [ChatMessage] = []
    var title = ""

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
    // v3.0.1 fix：云端/本地会话 id 用不同 key 隔离（原共用一个 key → 切模式串 sessionId）
    // 注意：init 里不能访问 self.sessionKey（sessionId 未初始化会报 'self' used before init），
    // 因此 init 内直接判断 CloudConfig.shared（静态单例，不依赖 self）
    private var sessionKey: String {
        CloudConfig.shared.isCloudMode ? "qingliao_current_session_cloud" : "qingliao_current_session"
    }

    init() {
        let key = CloudConfig.shared.isCloudMode ? "qingliao_current_session_cloud" : "qingliao_current_session"
        if let saved = defaults.string(forKey: key), !saved.isEmpty {
            sessionId = saved
        } else {
            sessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(13).description
            defaults.set(sessionId, forKey: key)
        }
    }

    /// 切换会话（从会话列表点入）
    func load(_ s: ChatSession) {
        sessionId = s.id
        title = s.title
        messages = s.messages
        defaults.set(sessionId, forKey: sessionKey)
    }

    // MARK: - v3.1.5 启动自动加载上次会话（解决"App 忘记上下文"）
    /// App 重启后自动从后端/本地存储加载当前 sessionId 对应的会话消息，
    /// 让 historyPayload() 有上下文可发，不再每条消息都"从零开始"。
    /// 云端模式从 CloudSessionStore（init 已加载）直接取；本地模式拉 /api/sessions/list。
    func loadLastSession(auth: AuthStore) async {
        guard messages.isEmpty else { return }   // 已有消息不覆盖（用户已手动加载）
        let sid = sessionId
        if CloudConfig.shared.isCloudMode {
            // 云端模式：CloudSessionStore.init() 已 load()，直接查
            if let match = CloudSessionStore.shared.sessions.first(where: { $0.id == sid }) {
                await MainActor.run { self.load(match) }
            }
            return
        }
        // 本地模式：从后端拉会话列表
        guard let j = try? await auth.json("/api/sessions/list"),
              let raw = j["sessions"] as? [Any] else { return }
        let sessions = raw.compactMap { ChatSession.parse($0 as? [String: Any] ?? [:]) }
        if let match = sessions.first(where: { $0.id == sid }) {
            await MainActor.run { self.load(match) }
        }
    }

    /// v3.0.2 fix（会话串位根治）：模式切换时调用——清空当前模式的内存数据，
    /// 并按**新模式的 key** 重新读取当前会话 id。原实现：ChatStore 是全局单例，
    /// 切模式不复位 → 云端聊天时内存里还带本地 messages → 界面串位。
    /// v3.3.0：不再解析 bot 前缀（bot 模式已移除）
    func switchToMode() {
        let key = CloudConfig.shared.isCloudMode ? "qingliao_current_session_cloud" : "qingliao_current_session"
        if let saved = defaults.string(forKey: key), !saved.isEmpty {
            sessionId = saved
        } else {
            sessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(13).description
            defaults.set(sessionId, forKey: key)
        }
        title = ""
        messages = []
        highlightTarget = nil
    }

    /// 新会话（v3.3.0：bot 模式已移除，仅生成普通新会话 id）
    func newSession() {
        sessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(13).description
        title = ""
        messages = []
        highlightTarget = nil   // v2.0.44：新建会话清除残留定位目标
        defaults.set(sessionId, forKey: sessionKey)
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

    func requestNewSession() {
        pendingNewSession = true
    }

    /// 追加本地消息（发送/流式开始）
    func append(_ m: ChatMessage) {
        messages.append(m)
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
            messages.insert(m, at: regionEnd)
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
        messages.append(m)
    }

    /// v2.0.59：按 id 标记消息发送失败（显示重试按钮）
    func markFailed(id: String) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].failed = true
        }
    }

    /// 发送请求用的历史消息（payload 形态）
    /// 只保留最后一条带图消息的 imageDataURL（前面已发过的图片不进 payload，防 base64 全量重复膨胀）
    func historyPayload() -> [[String: Any]] {
        // v3.0.10：图片保留条件（不降级为文本）
        // 云端模式：当前厂商 supportsVision
        // 本地模式：主模型支持视觉 OR 配置了视觉模型自动切换
        let visionOK: Bool = {
            if CloudConfig.shared.isCloudMode {
                if CloudConfig.shared.activeConfig?.supportsVision ?? false { return true }
                let modelName = CloudConfig.shared.activeConfig?.model ?? ""
                if !modelName.isEmpty, CloudConfig.modelSupportsVision(modelName) { return true }
                return false
            }
            // 本地模式：主模型支持视觉 → 直接 OK
            let mainModel = UserDefaults.standard.string(forKey: "qingliao_model") ?? ""
            if CloudConfig.modelSupportsVision(mainModel) { return true }
            // 主模型不支持 → 开关开 + 有视觉模型配置才保留图片，否则降级文本
            return CloudConfig.visionFallbackEnabled && CloudConfig.localVisionModel != nil
        }()
        // v3.0.83fix：isPush=1 的推送消息不进模型上下文（推送被当AI回复污染对话的根治）
        // 推送消息是 Hermes 主动注入的，不该作为历史喂给模型。保留在会话展示，但历史重放滤掉。
        // v3.1.12：错误占位（⚠️/HTTP Error/连接中断）同样不进上下文——脏历史诱导模型复读
        let ctxMessages = messages.filter { !$0.isPush && !$0.isErrorPlaceholder }
        return ctxMessages.map { m in
            var p = m.asPayload()
            if m.imageDataURL == nil {
                p["content"] = m.content
            } else if !visionOK {
                // 不支持视觉 → 图片降级为文本（内容 + [图片] 标记）
                let t = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
                p["content"] = t.isEmpty ? "[图片]" : t + "\n[图片]"
            }
            return p
        }
    }

    /// 保存会话（v3.0.1：按模式分流——云端写本地 CloudSessionStore 文件，本地走后端）
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

    /// 参数化快照版：切换会话前调用——切换会清空 messages，异步保存若不捕获快照会读到空数组丢会话。
    /// v3.4.x fix：图片消息保留 imageDataURL，避免重启/切会话后只剩 [图片] 占位
    func saveToServer(auth: AuthStore, sessionId sid: String, messages msgs: [ChatMessage], title t: String) async {
        guard !msgs.isEmpty else { return }
        if CloudConfig.shared.isCloudMode {
            CloudSessionStore.shared.saveChat(sessionId: sid, messages: msgs, title: t)
            return
        }
        let msgsPayload: [[String: Any]] = msgs.map { m in
            var p: [String: Any] = ["role": m.role, "content": m.content]
            if let ts = m.timestamp { p["timestamp"] = ts }
            if let img = m.imageDataURL, !img.isEmpty {
                p["imageDataURL"] = img
            }
            if m.audioPath != nil {
                p["content"] = "[语音]"
            }
            if m.isPush { p["isPush"] = true }
            if m.agent { p["agent"] = true }
            return p
        }
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
                return compressContext(keepLast: keepLast)
            }

            // 用摘要替换旧消息
            let marker = ChatMessage(role: "system",
                                     content: "（AI 摘要：\(summary)）",
                                     timestamp: oldMessages.first?.timestamp)
            messages = [marker] + recentMessages
            print("[ContextCompress] AI摘要压缩成功：\(oldMessages.count)条→摘要 + \(recentMessages.count)条")
            return true

        } catch {
            // AI 调用失败，降级为本地压缩
            print("[ContextCompress] AI摘要失败(\(error.localizedDescription))，降级本地压缩")
            return compressContext(keepLast: keepLast)
        }
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

    /// 扫描 messages 里仍为 base64（data:image/）的用户图片消息，重传换 URL。
    /// 队列天然派生自消息数组（重启后内存 messages 重新加载，残留 base64 的就是待传的），无需单独持久化。
    /// 触发点：会话加载后 / 前台回到 App / 发送路径降级后。
    func retryPendingImageUploads(auth: AuthStore, maxRetries: Int = 3) async {
        guard !CloudConfig.shared.isCloudMode else { return }   // 云端本地上传链路不同，跳过
        let indices = messages.indices.filter { idx in
            let m = messages[idx]
            return m.isUser && (m.imageDataURL?.hasPrefix("data:image/") ?? false)
        }
        guard !indices.isEmpty else { return }
        for idx in indices {
            guard let img = messages[idx].imageDataURL,
                  img.hasPrefix("data:image/"),
                  let comma = img.firstIndex(of: ",") else { continue }
            let b64 = String(img[img.index(after: comma)...])
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { continue }
            // 指数退避重试
            var ok: String? = nil
            for attempt in 0..<maxRetries {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
                }
                ok = await uploadImage(data, auth: auth)
                if ok != nil { break }
            }
            guard let url = ok else { continue }
            if messages.indices.contains(idx) {   // 重试期间数组可能已变化（删除/切会话）
                messages[idx].imageDataURL = url
                await saveToServer(auth: auth, sessionId: sessionId, messages: messages, title: title)
            }
        }
    }

    // MARK: - v3.0.27 图片持久化

    /// 上传图片到服务器，返回可访问的 URL
    func uploadImage(_ imageData: Data, auth: AuthStore) async -> String? {
        // v3.0.54：蜂窝分片上传 —— URLSession multipart 在蜂窝 IPv6 POST 必挂（退回 base64 大 body
        // → CFStream/relay 载不动 → bad json 400）。蜂窝改走 auth.request（CFStream 直连+relay 兜底、
        // 自动带 X-Auth-Token，正是文字聊天走通的小 body 通路）把图切小片 JSON base64 上传、服务端重组。
        // WiFi 仍走原 URLSession 直连大文件，质量不变。
        if NetworkMonitor.shared.isCellular {
            return await uploadImageChunked(imageData, auth: auth)
        }
        guard let config = CloudConfig.shared.activeConfig else { return nil }
        var base = config.baseURL
        if !base.hasPrefix("http") { base = "https://" + base }
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

        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileURL = json["url"] as? String else { return nil }
        // v3.0.37：后端返回相对路径 → 拼 baseURL 成完整可访问 URL（WiFi 直连 / 蜂窝中继均按各自 base）
        if fileURL.hasPrefix("/") {
            let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
            return trimmedBase + fileURL
        }
        return fileURL
    }

    /// 蜂窝分片上传：把图片切小块 base64，逐片经 auth.request（直连+relay 兜底）传 /api/files/upload_chunk，
    /// 服务端按 offset 写 staging、收齐自动组回完整文件返回 url。
    /// 片大小自适应：从 16KB 起，某一片失败 → 整体减半重试（换新 uploadId），直到摸出蜂窝能通过的临界值。
    private func uploadImageChunked(_ imageData: Data, auth: AuthStore) async -> String? {
        guard let config = CloudConfig.shared.activeConfig else { return nil }
        var base = config.baseURL
        if !base.hasPrefix("http") { base = "https://" + base }

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
                        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
                        return trimmed + rel
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
}
