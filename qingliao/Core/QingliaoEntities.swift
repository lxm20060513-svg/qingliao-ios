import AppIntents
import Foundation

// MARK: - 轻聊实体（App Entity · v4.0.91 配合 iOS 27 快捷指令）
//
// 为什么值得做实体：现在轻聊的 intent 只能**返回字符串**（AskQingliaoIntent 那种），
// Siri / 快捷指令拿到的是一段文本就完事了；而 iOS 27 新接入的端侧模型（快捷指令「用模型」+
// App Intent 动作）能读的是 **App Entity 的 @Property** —— 也就是说：
//   · 实体化之前：模型只知道「轻聊返回了『有 3 项待办：买电池；交电费』」这句话
//   · 实体化之后：模型拿到 3 个 TodoEntity，能按 `done` / `source` **结构化**过滤、排序、比对
// 于是「读轻聊待办写早报」「按目标推进情况写复盘」这类自动化才成立。
//
// 三条硬约束（想不清楚就会写出「能编译、真机没反应」的东西）：
//   1. **实体查询不许触网**。intent 可能被系统在后台无界面拉起，查询里 fetch 后端会卡住
//      Siri（等 120s 超时）。所以下面只读 App 本地缓存（store 在 init 里 loadLocal）；
//      「拉最新」仍是 App 自己 pollOnce 的职责，不经这里。
//   2. **查询方法不能标 @MainActor**（`EntityQuery` 的成员是非隔离的），而 store 是
//      `@MainActor` 的 → 一律 `await MainActor.run { }` 在主线程取一份**值类型副本**再出闭包。
//      别把 store 实例带出去（那就成了跨隔离域持有主线程对象）。
//   3. **实体不占 Siri 短语名额**。每 App 最多 10 条 App Shortcuts（本仓已用 9 条），
//      而 AppEntity 只是类型声明 —— 加实体不需要动 AppShortcutsProvider。
//
// ⚠️ 本文件 import AppIntents（本机 Linux 没有 iOS SDK，**编不了**）→ 只能靠
//    `swiftc -parse`（语法）+ CI Archive 验证；所以逻辑尽量薄，规则集中在
//    QingliaoNotifyCopy 这类纯 Foundation 文件里由真值表钉住。

// MARK: - 待办实体

/// 一条轻聊待办。`id` 用 TodoItem 自己的稳定 id（本地 UUID，跨设备不保证一致 —— 够用：
/// 实体主要给「本机自动化」用，不存在跨设备引用场景）。
struct TodoEntity: AppEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "轻聊待办")
    }

    static var defaultQuery = TodoEntityQuery()

    var id: String

    /// @Property 就是端侧模型能读到的字段（快捷指令「用模型」把它当结构化输入）
    @Property(title: "内容") var content: String
    @Property(title: "已完成") var done: Bool
    @Property(title: "来源") var source: String

    init(_ item: TodoItem) {
        self.id = item.id
        self.content = item.content
        self.done = item.done
        self.source = item.sourceLabel
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: content),
                              subtitle: LocalizedStringResource(stringLiteral: done ? "已完成" : "待办"))
    }
}

struct TodoEntityQuery: EntityQuery, EntityStringQuery, EnumerableEntityQuery {

    /// 未完成的排前面（与生活页同口径），已完成的沉底但不丢（用户可能想盘「昨天干了啥」）
    static func snapshot() async -> [TodoEntity] {
        await MainActor.run {
            TodoStore.shared.todos
                .sorted { a, b in
                    if a.done != b.done { return !a.done }
                    return a.sortDate > b.sortDate
                }
                .map(TodoEntity.init)
        }
    }

    func entities(for identifiers: [String]) async throws -> [TodoEntity] {
        let all = await Self.snapshot()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TodoEntity] {
        await Self.snapshot()
    }

    /// EnumerableEntityQuery：让快捷指令能生成「查找轻聊待办」动作并自己过滤
    func allEntities() async throws -> [TodoEntity] {
        await Self.snapshot()
    }

    func entities(matching string: String) async throws -> [TodoEntity] {
        let kw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = await Self.snapshot()
        guard !kw.isEmpty else { return all }
        return all.filter { $0.content.localizedCaseInsensitiveContains(kw) }
    }
}

// MARK: - 备忘实体

struct MemoEntity: AppEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "轻聊备忘")
    }

    static var defaultQuery = MemoEntityQuery()

    var id: String

    @Property(title: "内容") var content: String
    @Property(title: "置顶") var pinned: Bool
    @Property(title: "来源") var source: String
    /// 相对时间（「3 小时前」）—— 模型读得到才写得出生动的早报
    @Property(title: "记录时间") var timeText: String

    init(_ item: MemoItem) {
        self.id = item.id
        self.content = item.content
        self.pinned = item.pinned
        self.source = item.source
        self.timeText = MemoItem.relativeTime(item.createdAt)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: content),
                              subtitle: LocalizedStringResource(stringLiteral: pinned ? "置顶" : timeText))
    }
}

struct MemoEntityQuery: EntityQuery, EntityStringQuery, EnumerableEntityQuery {

    static func snapshot() async -> [MemoEntity] {
        await MainActor.run {
            MemoStore.shared.memos
                .sorted { a, b in
                    if a.pinned != b.pinned { return a.pinned }
                    return a.updatedAt > b.updatedAt
                }
                .map(MemoEntity.init)
        }
    }

    func entities(for identifiers: [String]) async throws -> [MemoEntity] {
        let all = await Self.snapshot()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MemoEntity] {
        Array(await Self.snapshot().prefix(10))
    }

    func allEntities() async throws -> [MemoEntity] {
        await Self.snapshot()
    }

    func entities(matching string: String) async throws -> [MemoEntity] {
        let kw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = await Self.snapshot()
        guard !kw.isEmpty else { return all }
        return all.filter { $0.content.localizedCaseInsensitiveContains(kw) }
    }
}

// MARK: - 长期目标实体

/// 长期目标。步骤不做成 [String] 数组属性（实体属性的集合类型在各系统版本上行为不一致），
/// 而是压成一行可读文本 —— 模型要的是「第三步是什么」，一行文本足够。
struct GoalEntity: AppEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "轻聊长期目标")
    }

    static var defaultQuery = GoalEntityQuery()

    var id: String

    @Property(title: "目标") var title: String
    @Property(title: "步骤") var stepsText: String
    @Property(title: "已完成步数") var doneSteps: Int
    @Property(title: "总步数") var totalSteps: Int
    @Property(title: "已暂停") var paused: Bool
    @Property(title: "已完成") var finished: Bool
    @Property(title: "最近一次推进") var lastReport: String

    init(_ item: GoalItem) {
        self.id = item.id
        self.title = item.title
        self.stepsText = GoalEntity.stepsText(item.steps)
        self.doneSteps = item.steps.filter { $0.done }.count
        self.totalSteps = item.steps.count
        self.paused = item.paused
        self.finished = item.isFinished
        self.lastReport = QingliaoAIReply.shorten(item.lastReport, limit: 200)
    }

    /// 「1. 定产品线 ✅；2. 备货 5000」——序号 + 勾选状态，Siri 念与模型读都顺
    static func stepsText(_ steps: [GoalStep]) -> String {
        guard !steps.isEmpty else { return "（还没拆步骤）" }
        return steps.enumerated()
            .map { "\($0.offset + 1). \($0.element.title)\($0.element.done ? " ✅" : "")" }
            .joined(separator: "；")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: title),
            subtitle: LocalizedStringResource(stringLiteral: finished ? "已完成"
                                              : (paused ? "已暂停" : "\(doneSteps)/\(totalSteps) 步"))
        )
    }
}

struct GoalEntityQuery: EntityQuery, EntityStringQuery, EnumerableEntityQuery {

    static func snapshot() async -> [GoalEntity] {
        await MainActor.run {
            GoalStore.shared.sortedActiveFirst.map(GoalEntity.init)
        }
    }

    func entities(for identifiers: [String]) async throws -> [GoalEntity] {
        let all = await Self.snapshot()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [GoalEntity] {
        Array(await Self.snapshot().prefix(10))
    }

    func allEntities() async throws -> [GoalEntity] {
        await Self.snapshot()
    }

    func entities(matching string: String) async throws -> [GoalEntity] {
        let kw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = await Self.snapshot()
        guard !kw.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(kw) }
    }
}

// MARK: - 动作：看待办（只读，返回值就是实体数组）

struct ListTodosIntent: AppIntent {

    static var title: LocalizedStringResource { "看轻聊待办" }

    static var description: IntentDescription {
        IntentDescription("念出轻聊待办清单（返回值是结构化待办实体，可接「用模型」/「重复」等下一步）")
    }

    @Parameter(title: "包含已完成", description: "留空只看还没做完的", default: false)
    var includeDone: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("看轻聊待办")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[TodoEntity]> & ProvidesDialog {
        let all = TodoStore.shared.todos
            .sorted { a, b in
                if a.done != b.done { return !a.done }
                return a.sortDate > b.sortDate
            }
            .map(TodoEntity.init)
        let items = includeDone ? all : all.filter { !$0.done }
        guard !items.isEmpty else {
            return .result(value: items, dialog: "轻聊待办是空的")
        }
        let head = items.prefix(3).map { QingliaoAIReply.shorten($0.content, limit: 24) }
            .joined(separator: "；")
        return .result(value: items, dialog: qlDialog("轻聊待办 \(items.count) 项：\(head)"))
    }
}

// MARK: - 动作：勾选待办（写，需在快捷指令里确认）

struct ToggleTodoIntent: AppIntent {

    static var title: LocalizedStringResource { "勾选轻聊待办" }

    static var description: IntentDescription {
        IntentDescription("把某条轻聊待办标成已完成（或撤回来），会同步到 NAS")
    }

    @Parameter(title: "待办")
    var todo: TodoEntity

    @Parameter(title: "标为完成", description: "关掉则撤回到未完成", default: true)
    var done: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$todo) 标为完成")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = TodoStore.shared
        // 与 AddMemoIntent 同规矩：写 NAS 前先把最新的 auth 挂上（改过服务器地址/token 后
        // 旧的那份不该继续被单例用下去；没挂 auth 时 save() 只落本地）。
        if let auth = try? QingliaoIntentClient.auth() { store.attach(auth: auth) }
        guard let item = store.todos.first(where: { $0.id == todo.id }) else {
            return .result(dialog: "没找到这条待办（可能已删除）")
        }
        if item.done != done { store.toggleDone(item) }
        let name = QingliaoAIReply.shorten(item.content, limit: 20)
        return .result(dialog: done ? "已勾掉「\(name)」" : "已恢复「\(name)」")
    }
}

// MARK: - 动作：搜备忘（只读）

struct SearchMemosIntent: AppIntent {

    static var title: LocalizedStringResource { "搜轻聊备忘" }

    static var description: IntentDescription {
        IntentDescription("按关键词在轻聊备忘里找（返回值是结构化备忘实体）")
    }

    @Parameter(title: "关键词", description: "留空 = 按「置顶 + 最近修改」给前 10 条")
    var keyword: String?

    static var parameterSummary: some ParameterSummary {
        Summary("搜轻聊备忘 \(\.$keyword)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[MemoEntity]> & ProvidesDialog {
        let kw = (keyword ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let all = MemoStore.shared.memos
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                return a.updatedAt > b.updatedAt
            }
            .map(MemoEntity.init)
        let items = kw.isEmpty ? Array(all.prefix(10))
                               : all.filter { $0.content.localizedCaseInsensitiveContains(kw) }
        guard !items.isEmpty else {
            return .result(value: items, dialog: kw.isEmpty ? "轻聊备忘是空的" : "没找到含「\(kw)」的备忘")
        }
        let head = items.prefix(3).map { QingliaoAIReply.shorten($0.content, limit: 24) }
            .joined(separator: "；")
        return .result(value: items, dialog: qlDialog("轻聊备忘 \(items.count) 条：\(head)"))
    }
}

// MARK: - 动作：看长期目标（只读）

struct ListGoalsIntent: AppIntent {

    static var title: LocalizedStringResource { "看轻聊长期目标" }

    static var description: IntentDescription {
        IntentDescription("念出长期目标与每步进展（返回值是结构化目标实体，模型能直接读到步骤）")
    }

    @Parameter(title: "包含已完成", description: "留空只看进行中的", default: false)
    var includeFinished: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("看轻聊长期目标")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[GoalEntity]> & ProvidesDialog {
        let all = GoalStore.shared.sortedActiveFirst.map(GoalEntity.init)
        let items = includeFinished ? all : all.filter { !$0.finished }
        guard !items.isEmpty else {
            return .result(value: items, dialog: "现在没有进行中的长期目标")
        }
        let head = items.prefix(2)
            .map { "\(QingliaoAIReply.shorten($0.title, limit: 16))（\($0.doneSteps)/\($0.totalSteps) 步）" }
            .joined(separator: "；")
        return .result(value: items, dialog: qlDialog("长期目标 \(items.count) 个：\(head)"))
    }
}
