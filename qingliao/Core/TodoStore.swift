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
    /// 来源标签真源（改值必须同时改 sourceLabel/sourceIcon 的分支，缺分支会静默渲染成「手动」）：
    /// chat 聊天 / ai AI 提取 / orb 智能球 / intent 识别 / shortcut 快捷指令（v4.0.92）/ goal 目标步骤 / manual 手写
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
        // v4.0.92：快捷指令 / 自动化（取件码短信自动进待办）；缺这一支就会渲染成「手动」，
        // 用户就看不出这条是自动化记进来的
        case "shortcut": return "快捷指令"
        // v4.0.92（审查抓到的同类漏分支）：目标建卡时灌进来的步骤一直落 default → 用户看到「手动」
        case "goal": return "目标"
        default: return "手动"
        }
    }

    var sourceIcon: String {
        switch source {
        case "chat": return "bubble.left.fill"
        case "ai": return "sparkles"
        case "orb": return "circle.dashed"   // v3.9.59：智能球来源
        case "intent": return "sparkles"     // v3.9.71：识别来源
        case "shortcut": return "wand.and.stars"   // v4.0.92：快捷指令来源
        case "goal": return "flag"                 // v4.0.92：目标步骤来源
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

    /// v4.0.25 确认制：AI 提取出的**候选**行（不落库，等用户在确认卡上勾选）。
    /// 放 TodoStore 类级别（v4.0.25 审查修复：原嵌在 TodoItem 内，裸名引用解析不到，CI 必挂）
    struct TodoCandidate: Identifiable, Equatable, Sendable {
        let id: UUID = UUID()
        var content: String
        /// AI 侧语义已完成（[x] / ☑ / tone=ok）→ 默认勾选态照抄，加入时保持
        var suggestedDone: Bool
        /// 确认卡上的勾选态（默认全选——AI 判定已完成的也先选上，用户可取消）
        var selected: Bool = true

        init(content: String, suggestedDone: Bool, selected: Bool = true) {
            self.content = content
            self.suggestedDone = suggestedDone
            self.selected = selected
        }
    }
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

    /// v4.0.x 复核补：NAS 写链 FIFO（等前一次写完再写本次快照），防并发写同一 path 时
    /// 慢的旧快照后到 → 远端复活已删条目。排队形态由 SyncedStore 统一注释说明
    /// （5 个 Store 的写链是同一份修法，见 Core/SyncedStore.swift 的「FIFO 写链」段）。
    private var writeChain: Task<Void, Never> = Task {}

    private var filePath: String {
        SyncedStore.remotePath(storagePath: storagePath, fileName: fileName)
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

    /// AI 回复结束提取的**候选**待办（v4.0.25 确认制：不再静默落库，见 stageCandidates）。
    /// key = 消息 id（ChatMessage.id 稳定：含持久化 uid，跨重启/会话切换不漂移）。
    /// 内存态即可：App 重启后候选丢失 = 该回复回到「不提取」——静默丢候选好过静默灌清单。
    private(set) var pendingCandidates: [String: [TodoCandidate]] = [:]
    /// 已确认的消息 → 实际加入条数（确认卡就地切回执用）
    private(set) var confirmedCounts: [String: Int] = [:]
    /// 已忽略的消息（「忽略」后确认卡消失）
    private(set) var dismissedMessageIDs: Set<String> = []

    // MARK: - AI 提取确认制（v4.0.25）

    /// 落库口调用：提取候选**只挂账不落库**。返回 nil = 本回复没有可提取项（含已被 AI
    /// 重复产出且已在清单里的——全部命中已有项时不出卡，保持老行为零打扰）。
    @discardableResult
    func stageCandidates(from text: String, messageID: String) -> [TodoCandidate]? {
        guard !dismissedMessageIDs.contains(messageID), confirmedCounts[messageID] == nil else { return nil }
        // 幂等：同一条消息重复落库（重试/恢复链路会双命中 upsertAssistant）不重挂——
        // 重挂会覆盖用户已改过的勾选态
        if let staged = pendingCandidates[messageID] { return staged }
        var items = TodoItem.extractChecklist(from: text)
        items += TodoItem.extractCardItems(from: text)
        guard !items.isEmpty else { return nil }
        let existing = Set(todos.map { $0.content })
        var seen = Set<String>()
        var candidates: [TodoCandidate] = []
        for (content, done) in items where !existing.contains(content) && !seen.contains(content) {
            seen.insert(content)
            candidates.append(TodoCandidate(content: content, suggestedDone: done))
        }
        guard !candidates.isEmpty else { return nil }
        pendingCandidates[messageID] = candidates
        return candidates
    }

    /// 确认卡勾选态切换（纯内存，不动 store）
    func toggleCandidate(messageID: String, index: Int) {
        guard pendingCandidates[messageID]?.indices.contains(index) == true else { return }
        pendingCandidates[messageID]?[index].selected.toggle()
    }

    /// 用户点「加入」：只把勾选中的落库（source=ai），就地切回执。
    @discardableResult
    func confirmCandidates(messageID: String) -> Int {
        guard let cands = pendingCandidates[messageID], !cands.isEmpty else { return 0 }
        let existing = Set(todos.map { $0.content })
        var added = 0
        for c in cands where c.selected && !existing.contains(c.content) {
            todos.insert(TodoItem(content: c.content, done: c.suggestedDone, source: "ai", updatedAt: Date()), at: 0)
            added += 1
        }
        pendingCandidates[messageID] = nil
        if added > 0 { save() }
        confirmedCounts[messageID] = added
        return added
    }

    /// 用户点「忽略」：候选丢弃，不再出卡（同一条回复重试落库也不会再弹）
    func dismissCandidates(messageID: String) {
        pendingCandidates[messageID] = nil
        dismissedMessageIDs.insert(messageID)
    }

    func delete(_ item: TodoItem) {
        todos.removeAll { $0.id == item.id }
        save()
    }

    /// 全部删除（含已完成）——「全部待办」弹窗顶栏「清空」胶囊用。
    /// 必须走 save() 同一条 FIFO 写链：否则远端留旧快照，loadFromServer 的并集合并会把条目复活。
    @discardableResult
    func removeAll() -> Int {
        let n = todos.count
        guard n > 0 else { return 0 }
        todos.removeAll()
        save()
        return n
    }

    /// v4.0.25：批量删除已完成条目——「全部待办」顶栏「清理已完成」胶囊用（与「清空」并存）。
    /// 同走 save() FIFO 写链（理由同 removeAll）。
    @discardableResult
    func clearCompleted() -> Int {
        let n = todos.filter { $0.done }.count
        guard n > 0 else { return 0 }
        todos.removeAll { $0.done }
        save()
        return n
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
        // 编解码策略（.iso8601）由 SyncedStore 统一持有，两端天然对齐
        guard let data = SyncedStore.encode(todos) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)

        let path = filePath
        // SR33：强捕获（先绑局部），理由同 MemoStore
        let authForWrite = auth
        // v4.0.x 复核补：FIFO 串行写链，防「删除+编辑」并发写导致远端复活（并集合并挡不住）。
        // 排队形态见 Core/SyncedStore.swift 的「FIFO 写链」段。
        let prev = writeChain
        writeChain = Task {
            await prev.value                                  // FIFO：等前一次写完再写本次快照
            await SyncedStore.writeToFile(auth: authForWrite, path: path, data: data)
        }
    }

    private func loadLocal() {
        // 解码策略必须与 save() 的 .iso8601 对齐（MemoStore 实踩：不对齐 = 本地兜底恒空）
        if let decoded = SyncedStore.readLocal([TodoItem].self, defaultsKey: defaultsKey) {
            todos = decoded
        }
    }

    /// 从 NAS 拉取（按 id 合并取较新，不整体替换——MemoStore 实踩：替换会让未落远端的条目"消失"）
    func loadFromServer() async {
        guard let remote = await SyncedStore.readRemote([TodoItem].self, auth: auth, path: filePath) else { return }

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
}
