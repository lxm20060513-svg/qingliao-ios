import Foundation

// MARK: - v3.0 云端模式会话本地存储（文件 JSON，替代后端 /api/sessions/merge）
// 数据格式与后端 sessions.json 一致：{"sessions": [{"id","title","messages":[{role,content,timestamp}]}]}
// 存 App Documents/cloud_sessions.json，云端模式会话历史完全本地化

@MainActor
@Observable
final class CloudSessionStore {
    static let shared = CloudSessionStore()

    private(set) var sessions: [ChatSession] = []

    /// v3.4.x code review fix（中）：encode+写盘移到串行后台队列（写按入队顺序执行，天然防乱序覆盖），
    /// 避免主线程全量 JSON 序列化 + 原子写盘卡顿（会话多/含大图 base64 时每 500ms 触发一次）
    private let writeQueue = DispatchQueue(label: "qingliao.cloudsessions.write", qos: .utility)

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("cloud_sessions.json")
    }

    init() {
        load()
    }

    /// 全量加载
    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["sessions"] as? [Any] else { return }
        sessions = arr.compactMap { ChatSession.parse($0 as? [String: Any] ?? [:]) }
        // 按最后时间倒序（新会话在前）
        sessions.sort { ($0.lastTime ?? 0) > ($1.lastTime ?? 0) }
    }

    /// 保存单个会话（upsert）
    func upsert(_ s: ChatSession) {
        if let idx = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions[idx] = s
        } else {
            sessions.append(s)
        }
        persist()
    }

    /// 删除会话
    func delete(id: String) {
        sessions.removeAll { $0.id == id }
        persist()
    }

    /// 重命名
    func rename(id: String, title: String) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].title = title
            persist()
        }
    }

    /// 从 ChatStore 保存当前会话（消息保留 imageDataURL，避免重启/切会话后只剩 [图片] 占位）
    func saveChat(store: ChatStore) {
        saveChat(sessionId: store.sessionId, messages: store.messages, title: store.title)
    }

    /// v3.0.7：参数化快照版（切换角色前调用，捕获消息快照防清空竞态）
    func saveChat(sessionId: String, messages msgs: [ChatMessage], title t: String) {
        guard !msgs.isEmpty else { return }
        let msgsPayload: [[String: Any]] = msgs.map { m in
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
            if m.isPush { p["isPush"] = true }    // v3.0.83fix：isPush 持久化（云端磁盘）
            if m.agent { p["agent"] = true }
            return p
        }
        let firstUserText = msgs.first(where: { $0.isUser })?.content.prefix(30).description ?? ""
        let title = t.isEmpty ? firstUserText : t
        let payload = ChatSession(id: sessionId, title: title,
                                  messages: msgsPayload.compactMap { ChatMessage.parse($0) })
        upsert(payload)
    }

    /// v3.4.x code review fix（中）：同步 API 保持原语义（upsert/delete/rename 后即返回），
    /// 序列化与写盘在串行后台队列完成（入队顺序 = 落盘顺序，最后入队的最新快照最后写，不会旧覆盖新）
    private func persist() {
        let snapshot = sessions
        let url = fileURL
        writeQueue.async {
            let arr: [[String: Any]] = snapshot.map { s in
                [
                    "id": s.id,
                    "title": s.title,
                    "messages": s.messages.map { m in
                        var p: [String: Any] = ["role": m.role, "content": m.content]
                        if let ts = m.timestamp { p["timestamp"] = ts }
                        // v3.4.x code review fix：uid 与消息一同落盘（跨重启 id 稳定）
                        if let u = m.uid, !u.isEmpty { p["uid"] = u }
                        if m.isPush { p["isPush"] = true }    // v3.0.83fix：isPush 持久化（云端磁盘）
                        if m.agent { p["agent"] = true }
                        return p
                    }
                ]
            }
            let obj: [String: Any] = ["sessions": arr]
            do {
                let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
                try data.write(to: url, options: [.atomic])
            } catch {
                // v3.0.x fix：写失败时记录错误（原静默丢数据）
                print("[CloudSessionStore] persist failed: \(error)")
            }
        }
    }
}
