import Foundation
import SwiftUI

// MARK: - v3.9.35 待办清单（生活页栏目 + 聊天气泡「加入待办」+ AI 输出自动提取）
//
// 定位：待办事项 —— 聊天长按手动加入 / AI 回复里的清单自动收进来 / 生活页手写。
// 存储：复刻 MemoStore 架构（本地 UserDefaults 兜底 + NAS pin_write/pin_read 文件双写，
//       文件 todos.json 与 memos.json 同目录），零后端改动。
// 🚨 从 MemoStore 踩过的坑直接继承：
//   · 手写 init(from:) + decodeIfPresent（旧数据缺键不解崩）
//   · loadLocal 的解码策略必须与 save 的 .iso8601 对齐
//   · loadFromServer 必须按 id 合并而不是整体替换（save 是异步写 NAS）

struct TodoItem: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var content: String
    var done: Bool
    var createdAt: Date
    /// 来源标签：chat（聊天气泡长按）/ ai（AI 回复自动提取）/ manual（生活页手写）
    var source: String
    var updatedAt: Date

    init(id: String = UUID().uuidString, content: String, done: Bool = false,
         createdAt: Date = Date(), source: String = "manual", updatedAt: Date? = nil) {
        self.id = id
        self.content = content
        self.done = done
        self.createdAt = createdAt
        self.source = source
        self.updatedAt = updatedAt ?? createdAt
    }

    /// 手写解码（见文件头坑 1）：新增字段必须 decodeIfPresent + 默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        content = try c.decode(String.self, forKey: .content)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, done, createdAt, source, updatedAt
    }

    var sortDate: Date { updatedAt }

    var sourceLabel: String {
        switch source {
        case "chat": return "聊天"
        case "ai": return "AI"
        case "orb": return "智能球"   // v3.9.59：dock 智慧球长按 → 今日待办
        case "intent": return "识别"   // v3.9.71：意图管道（识别出来的内容一键加待办）
        default: return "手动"
        }
    }

    var sourceIcon: String {
        switch source {
        case "chat": return "bubble.left.fill"
        case "ai": return "sparkles"
        case "orb": return "circle.dashed"   // v3.9.59：智能球来源
        case "intent": return "sparkles"     // v3.9.71：识别来源
        default: return "square.and.pencil"
        }
    }

    var timeText: String { MemoItem.relativeTime(updatedAt) }

    /// v3.9.75：AI 输出的 ql-card 卡片条目 → 候选待办行。
    /// 只认两类卡：`plan`（提示词定义 = 多步骤任务的步骤，天然就是待办）；
    /// `list` 需卡片标题带待办语义词（待办/任务/todo/计划/安排/清单）才收 ——
    /// 无门控时「磁盘分区列表」「容器列表」这类结果清单会成批灌进待办，和上面那条
    /// 「普通编号列表是叙述不是待办」的口径一致。
    static func extractCardItems(from text: String) -> [(String, Bool)] {
        guard AgentCardParser.containsCardMarker(text) else { return [] }
        let signals = ["待办", "任务", "todo", "计划", "安排", "清单"]
        var out: [(String, Bool)] = []
        for seg in AgentCardParser.parse(text) {
            guard case .card(let card) = seg else { continue }
            switch card.kind {
            case .plan:
                break
            case .list:
                let head = ((card.title ?? "") + (card.subtitle ?? "")).lowercased()
                guard signals.contains(where: { head.contains($0) }) else { continue }
            default:
                continue
            }
            for item in card.items {
                let title = item.title.trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { continue }
                // tone=ok 或 status 含「完成」→ 收进来就是勾上的
                let done = item.tone == .ok || (item.status.map { $0.contains("完成") } ?? false)
                out.append((title, done))
            }
        }
        return out
    }

    /// 纯函数：从 AI 回复文本提取待办行（真值表 /opt/data/scripts/ql_todo/truth_table_todo.swift 守护）。
    /// 识别：markdown 勾选框（- [ ] / * [ ] / - [x]）与 ☐ □ ☑ ☒ 行；其余行不收
    ///（普通编号列表是叙述不是待办，收进来会淹没真实待办——刻意只认勾选框语义）。
    static func extractChecklist(from text: String) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            var done = false
            var body = ""
            if line.hasPrefix("- [ ]") || line.hasPrefix("* [ ]") {
                body = String(line.dropFirst(5))
            } else if line.hasPrefix("- [x]") || line.hasPrefix("- [X]")
                        || line.hasPrefix("* [x]") || line.hasPrefix("* [X]") {
                body = String(line.dropFirst(5))
                done = true
            } else if line.hasPrefix("☐") || line.hasPrefix("□") {
                body = String(line.dropFirst(1))
            } else if line.hasPrefix("☑") || line.hasPrefix("☒") {
                body = String(line.dropFirst(1))
                done = true
            } else {
                continue
            }
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            out.append((trimmed, done))
        }
        return out
    }
}

@Observable
@MainActor
final class TodoStore {
    static let shared = TodoStore()

    private(set) var todos: [TodoItem] = []
    private let storagePathKey = "qingliao_todo_storage_path"
    private let fileName = "todos.json"
    private let defaultsKey = "qingliao_todos_data"

    // v3.9.41（SR33，与 MemoStore 同源）：强引用——weak 时调用方一返回 auth 就没了，
    // 下面 detached 的 NAS 回写会在 `guard let auth` 处静默 return。
    var auth: AuthStore?

    func attach(auth: AuthStore) {
        self.auth = auth
    }

    var storagePath: String {
        get { UserDefaults.standard.string(forKey: storagePathKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: storagePathKey) }
    }

    private var filePath: String {
        let base = storagePath.isEmpty
            ? "/volume1/docker/hermes/微信文件/轻聊web/data"
            : storagePath
        return "\(base)/\(fileName)"
    }

    private init() {
        loadLocal()
    }

    // MARK: - CRUD

    /// 新增（未完成排前，同级最新在前）
    @discardableResult
    func add(content: String, source: String = "manual") -> Bool {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        // 同内容去重（5 分钟内连点不重复）
        if let first = todos.first, first.content == text,
           Date().timeIntervalSince(first.createdAt) < 300 {
            return true
        }
        todos.insert(TodoItem(content: text, source: source, updatedAt: Date()), at: 0)
        save()
        return true
    }

    /// AI 回复结束自动提取（勾选框行 + 计划/待办卡片条目，全历史按内容去重
    ///——AI 每轮可能重复产出同一条待办，且落库口 upsertAssistant 会被多次命中）
    @discardableResult
    func addAuto(from text: String) -> Int {
        var items = TodoItem.extractChecklist(from: text)
        items += TodoItem.extractCardItems(from: text)
        guard !items.isEmpty else { return 0 }
        let existing = Set(todos.map { $0.content })
        var seen = Set<String>()
        var added = 0
        for (content, done) in items where !existing.contains(content) && !seen.contains(content) {
            seen.insert(content)
            todos.append(TodoItem(content: content, done: done, source: "ai", updatedAt: Date()))
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    func delete(_ item: TodoItem) {
        todos.removeAll { $0.id == item.id }
        save()
    }

    func update(_ item: TodoItem, content: String) {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let idx = todos.firstIndex(where: { $0.id == item.id }) else { return }
        guard todos[idx].content != text else { return }
        todos[idx].content = text
        todos[idx].updatedAt = Date()
        save()
    }

    func toggleDone(_ item: TodoItem) {
        guard let idx = todos.firstIndex(where: { $0.id == item.id }) else { return }
        todos[idx].done.toggle()
        todos[idx].updatedAt = Date()
        save()
    }

    /// 列表顺序 = 未完成优先，其次按最后修改时间倒序
    var sorted: [TodoItem] {
        todos.sorted { a, b in
            if a.done != b.done { return !a.done }
            return a.sortDate > b.sortDate
        }
    }

    var pendingCount: Int { todos.filter { !$0.done }.count }

    // MARK: - 持久化（与 MemoStore 同款：本地 UserDefaults + NAS 文件双写）

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(todos) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)

        let path = filePath
        // SR33：强捕获（先绑局部），理由同 MemoStore
        let authForWrite = auth
        Task.detached {
            await Self.writeToFile(auth: authForWrite, path: path, data: data)
        }
    }

    private func loadLocal() {
        // 解码策略必须与 save() 的 .iso8601 对齐（MemoStore 实踩：不对齐 = 本地兜底恒空）
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? decoder.decode([TodoItem].self, from: data) {
            todos = decoded
        }
    }

    /// 从 NAS 拉取（按 id 合并取较新，不整体替换——MemoStore 实踩：替换会让未落远端的条目"消失"）
    func loadFromServer() async {
        guard let auth else { return }
        guard let path = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let j = try? await auth.json("/api/files/pin_read?path=\(path)"),
              let b64 = j["data"] as? String,
              let data = Data(base64Encoded: b64) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let remote = try? decoder.decode([TodoItem].self, from: data) else { return }

        var byID: [String: TodoItem] = [:]
        for t in remote { byID[t.id] = t }
        for t in todos {
            if let r = byID[t.id] {
                byID[t.id] = r.sortDate >= t.sortDate ? r : t
            } else {
                byID[t.id] = t
            }
        }
        let merged = byID.values.sorted { $0.sortDate > $1.sortDate }
        // v3.9.41（SR40，与 MemoStore 同源）：只比条数 → 勾选完成/改内容这类 id 不变的变更
        // 永不回写，NAS 那份对这台设备无限期失真。时间按整秒比，避免 .iso8601 丢小数秒造成
        // 「同一份内容判成不同 → 每次拉取白写一次 NAS」。
        var remoteByID: [String: TodoItem] = [:]
        for t in remote { remoteByID[t.id] = t }
        let changed = merged.count != remote.count || merged.contains { t in
            guard let r = remoteByID[t.id] else { return true }
            return t.content != r.content || t.done != r.done || t.source != r.source
                || Int(t.updatedAt.timeIntervalSince1970) != Int(r.updatedAt.timeIntervalSince1970)
        }
        todos = merged
        if changed { save() }
    }

    private static func writeToFile(auth: AuthStore?, path: String, data: Data) async {
        guard let auth else { return }
        let body: [String: Any] = ["path": path, "data": data.base64EncodedString()]
        _ = try? await auth.json("/api/files/pin_write", method: "POST", body: body)
    }
}
