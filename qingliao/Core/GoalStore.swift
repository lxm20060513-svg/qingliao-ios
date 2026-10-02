import Foundation
import SwiftUI

// v4.0.7：长期目标 Store —— 与 TodoStore/MemoStore 完全同构（UserDefaults + /api/files/pin_read|pin_write）。
// 存在的意义：AI 在聊天里说「我在筹备 XX」→ 后端 agent 判定为长期目标 → 回一张「建目标卡」→
// 用户点确认 → 落进本 Store → 后端建一个每天跑的 cron job（早推进 + 晚复盘）→
// 推进结果回到 App 生活页「长期目标」卡片 + 微信。
//
// 🚨 铁律（全部来自 TodoStore 的踩坑记录，抄骨架时不要改）：
// 1) 手写 init(from:) + decodeIfPresent —— 否则旧数据缺新键 → 全量解码失败 → 用户数据消失。
// 2) sortDate 必须是 updatedAt —— 否则「编辑过但 createdAt 未变」会被远端旧内容覆盖。
// 3) save() 必须走 FIFO 写链（bind authForWrite 到局部 + await prev.value）——
//    否则并集 union merge 会把删掉的目标复活。
// 4) loadLocal 的解码策略必须 .iso8601 对齐 save()，否则本地兜底恒空。
// 5) auth 必须是**强引用** —— weak 时调用方返回即 nil，NAS 回写静默丢。

// ── 单个目标 ──────────────────────────────────────────────
struct GoalItem: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    /// AI 拆出的步骤（用户确认时一起落库）
    var steps: [GoalStep]
    /// 后端 cron job id —— 空串 = 还没建 job（或已删）
    var cronJobID: String
    /// 每日两段：早推进 / 晚复盘
    var morningEnabled: Bool
    var eveningEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    /// 最近一次推进的汇报正文（cron 回写）
    var lastReport: String
    var lastPushedAt: Date?
    /// v4.0.20（#6）：后台推进留痕（倒序时间线）。老数据为空 —— 后端从本版起追加写入。
    var reports: [GoalReport]
    /// 手动暂停（暂停时 cron job 被 disable，用户自己掌控节奏）
    var paused: Bool
    /// 每日两段的时间点（0-23），默认早 9 / 晚 21
    var morningHour: Int
    var eveningHour: Int

    init(id: String = UUID().uuidString,
         title: String,
         steps: [GoalStep] = [],
         cronJobID: String = "",
         morningEnabled: Bool = true,
         eveningEnabled: Bool = true,
         morningHour: Int = 9,
         eveningHour: Int = 21,
         lastReport: String = "",
         lastPushedAt: Date? = nil,
         reports: [GoalReport] = [],
         paused: Bool = false,
         createdAt: Date = Date(),
         updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.steps = steps
        self.cronJobID = cronJobID
        self.morningEnabled = morningEnabled
        self.eveningEnabled = eveningEnabled
        self.morningHour = min(max(morningHour, 0), 23)
        self.eveningHour = min(max(eveningHour, 0), 23)
        self.lastReport = lastReport
        self.lastPushedAt = lastPushedAt
        self.reports = reports
        self.paused = paused
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    // 🚨 手写解码：新增字段一律 decodeIfPresent + 默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        steps = try c.decodeIfPresent([GoalStep].self, forKey: .steps) ?? []
        cronJobID = try c.decodeIfPresent(String.self, forKey: .cronJobID) ?? ""
        morningEnabled = try c.decodeIfPresent(Bool.self, forKey: .morningEnabled) ?? true
        eveningEnabled = try c.decodeIfPresent(Bool.self, forKey: .eveningEnabled) ?? true
        morningHour = try c.decodeIfPresent(Int.self, forKey: .morningHour) ?? 9
        eveningHour = try c.decodeIfPresent(Int.self, forKey: .eveningHour) ?? 21
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastReport = try c.decodeIfPresent(String.self, forKey: .lastReport) ?? ""
        lastPushedAt = try c.decodeIfPresent(Date.self, forKey: .lastPushedAt)
        reports = try c.decodeIfPresent([GoalReport].self, forKey: .reports) ?? []
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, steps, cronJobID, morningEnabled, eveningEnabled
        case morningHour, eveningHour, createdAt, updatedAt
        case lastReport, lastPushedAt, paused, reports
    }

    var sortDate: Date { updatedAt }

    /// 进度 = 已完成步骤 / 总步骤；没拆步骤时给 0（不假装有进度）
    var progressRatio: Double {
        guard !steps.isEmpty else { return 0 }
        return Double(steps.filter { $0.done }.count) / Double(steps.count)
    }
    var doneCount: Int { steps.filter { $0.done }.count }
    var isFinished: Bool { !steps.isEmpty && steps.allSatisfy { $0.done } }

    /// 明天要推进哪一步（第一个未完成的）
    var nextStep: GoalStep? { steps.first { !$0.done } }
}

// ── 目标的一个步骤 ──────────────────────────────────────────
struct GoalStep: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String
    var title: String
    /// 同步进待办清单时带上这个前缀，便于在待办里认出属于哪个目标
    var todoLinked: Bool
    var done: Bool
    var doneAt: Date?

    init(id: String = UUID().uuidString,
         title: String,
         todoLinked: Bool = false,
         done: Bool = false,
         doneAt: Date? = nil) {
        self.id = id
        self.title = title
        self.todoLinked = todoLinked
        self.done = done
        self.doneAt = doneAt
    }

    // 🚨 手写解码
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        todoLinked = try c.decodeIfPresent(Bool.self, forKey: .todoLinked) ?? false
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, todoLinked, done, doneAt
    }
}

// ── Store ──────────────────────────────────────────────
@Observable @MainActor
final class GoalStore {
    static let shared = GoalStore()

    private(set) var goals: [GoalItem] = []
    /// 挂掉的目标 id —— 挡 union merge 复活（抄 RecordStore 的墓碑机制）。
    /// 🚨 GoalItem 跟 TodoItem/MemoItem 一样是 id 并集模型，没有墓碑会复活已删目标。
    private(set) var tombstones: Set<String> = []

    private let defaultsKey = "qingliao_goals_data"
    private let storagePathKey = "qingliao_goal_storage_path"
    private let fileName = "goals.json"

    /// 强引用（SR33：weak 时调用方返回即 nil，NAS 回写静默丢）
    var auth: AuthStore?
    func attach(auth: AuthStore) { self.auth = auth }

    var storagePath: String {
        get { UserDefaults.standard.string(forKey: storagePathKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: storagePathKey) }
    }

    /// 认账的默认 NAS 目录（与 TodoStore 完全一致，见 SyncedStore.remotePath）
    private var filePath: String {
        SyncedStore.remotePath(storagePath: storagePath, fileName: fileName)
    }

    /// 🚨 FIFO 串行写链：防远端 union merge 复活刚删的目标。
    /// 排队形态见 Core/SyncedStore.swift 的「FIFO 写链」段（5 仓同一份修法）。
    private var writeChain: Task<Void, Never> = Task {}

    private init() { loadLocal() }

    var sorted: [GoalItem] { goals.sorted { $0.sortDate > $1.sortDate } }
    var activeCount: Int { goals.filter { !$0.isFinished }.count }

    // ── 本地 ──────────────────────────────────────────
    private func loadLocal() {
        // 🚨 解码策略由 SyncedStore 统一持有，与 save() 天然对齐（原来靠两处手写对齐，容易抄漏）
        if let decoded = SyncedStore.readLocal([GoalItem].self, defaultsKey: defaultsKey) {
            goals = decoded
        }
    }

    private func save() {
        guard let data = SyncedStore.encode(goals) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        // 🚨 FIFO 写链：先绑局部 authForWrite + path 再排队
        let path = filePath
        let authForWrite = auth
        let prev = writeChain
        writeChain = Task {
            await prev.value                                  // FIFO：等前一次写完再写本次快照
            await SyncedStore.writeToFile(auth: authForWrite, path: path, data: data)
        }
    }

    // ── 增删改 ──────────────────────────────────────────
    func add(_ goal: GoalItem) {
        goals.append(goal)
        save()
    }

    func update(_ goal: GoalItem) {
        guard let i = goals.firstIndex(where: { $0.id == goal.id }) else { return }
        goals[i] = goal
        touch(goal.id)
        save()
    }

    /// 更新某个目标（原地改 + 自动盖 updatedAt）
    func mutate(_ id: String, _ block: (inout GoalItem) -> Void) {
        guard let i = goals.firstIndex(where: { $0.id == id }) else { return }
        block(&goals[i])
        goals[i].updatedAt = Date()
        save()
    }

    /// 只更新时间戳（远端回写进度时用，不覆盖用户本地的其他字段）
    func touch(_ id: String) {
        guard let i = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[i].updatedAt = Date()
    }

    /// 勾/取消某个步骤（勾上的同时把对应待办也划掉）
    func toggleStep(goalID: String, stepID: String) {
        mutate(goalID) { g in
            guard let j = g.steps.firstIndex(where: { $0.id == stepID }) else { return }
            g.steps[j].done.toggle()
            g.steps[j].doneAt = g.steps[j].done ? Date() : nil
        }
    }

    /// 删除一个目标 + 记墓碑（防远端复活）
    func remove(_ id: String) {
        goals.removeAll { $0.id == id }
        tombstones.insert(id)
        save()
    }

    /// 全部删除（清空胶囊）—— 🚨 必须走 save() 同一条 FIFO 写链，否则并集会把目标复活
    func removeAll() -> Int {
        // 🚨 墓碑必须**在清空前**收齐：清空后再 map 就永远是空集，墓碑形同虚设
        let victims = goals.map { $0.id }
        guard !victims.isEmpty else { return 0 }
        goals.removeAll()
        tombstones.formUnion(victims)
        save()
        return victims.count
    }

    // ── 远端同步 ──────────────────────────────────────────
    func loadFromServer() async {
        guard let remote = await SyncedStore.readRemote([GoalItem].self, auth: auth, path: filePath) else { return }

        // 🚨 墓碑优先：墓碑里的 id 一律不复活
        var byID: [String: GoalItem] = [:]
        for g in remote where !tombstones.contains(g.id) { byID[g.id] = g }
        for g in goals { byID[g.id] = byID[g.id].map { $0.sortDate >= g.sortDate ? $0 : g } ?? g }
        let merged = byID.values.sorted { $0.sortDate > $1.sortDate }

        // 回写判定：逐条比内容（不能只比条数，否则勾选/编辑永不回写）。
        // 墓碑里的 id 已被剔除，比分母用「远端去掉墓碑」后的条数。
        let liveRemote = remote.filter { !tombstones.contains($0.id) }
        var remoteByID: [String: GoalItem] = [:]
        for g in liveRemote { remoteByID[g.id] = g }

        var changed = merged.count != liveRemote.count
        for g in merged {
            guard let r = remoteByID[g.id] else { changed = true; continue }
            if g.title != r.title
                || g.cronJobID != r.cronJobID
                || g.lastReport != r.lastReport
                || g.paused != r.paused
                || g.morningEnabled != r.morningEnabled
                || g.eveningEnabled != r.eveningEnabled
                || g.steps.count != r.steps.count
                || Int(g.updatedAt.timeIntervalSince1970) != Int(r.updatedAt.timeIntervalSince1970) {
                changed = true
            }
        }
        goals = merged
        if changed { save() }
    }

    // ── 后端 API 桥（建目标时让后端建 cron job）──────────
    //
    // 为什么不纯靠文件通道：cron job 只能由后端建（进程内 POST 127.0.0.1:9123/api/jobs）。
    // iOS 端建目标必须先问后端「把 job 建上」，否则目标卡片在、每天却没人推。
    //
    // 🚨 口径：建 job 失败**不阻塞**本地落库 —— 目标卡片照常出现，用户能在详情里看到
    // 「没建上每日推送」并重试。宁可少推，不可让用户以为建好了其实没有。

    /// 建目标并让后端把每日 cron job 建上。返回后端回的 goal（含 cronJobID），失败返回 nil。
    @discardableResult
    func createOnBackend(_ goal: GoalItem) async -> GoalItem? {
        guard let auth else { return nil }
        let body: [String: Any] = [
            "id": goal.id,
            "title": goal.title,
            "steps": goal.steps.map { s -> [String: Any] in
                ["id": s.id, "title": s.title, "todoLinked": s.todoLinked]
            },
            "morningEnabled": goal.morningEnabled,
            "eveningEnabled": goal.eveningEnabled,
            "morningHour": goal.morningHour,
            "eveningHour": goal.eveningHour
        ]
        guard let j = try? await auth.json("/api/life/goal", method: "POST", body: body),
              let remote = j["goal"] as? [String: Any] else { return nil }
        var merged = goal
        if let ids = remote["cronJobIDs"] as? [String], !ids.isEmpty {
            merged.cronJobID = ids[0]
        } else if let one = remote["cronJobID"] as? String, !one.isEmpty {
            merged.cronJobID = one
        }
        return merged
    }

    /// 暂停/恢复每日推进（后端要同步 disable/enable job）
    func setPausedOnBackend(goalID: String, paused: Bool) async {
        guard let auth else { return }
        _ = try? await auth.json("/api/life/goal", method: "PATCH",
                                 body: ["id": goalID, "paused": paused])
    }

    /// 删目标 —— 后端负责连带删掉它的 cron job（否则明天还会推一个已删目标）
    func deleteOnBackend(goalID: String) async {
        guard let auth else { return }
        let path = goalID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? goalID
        _ = try? await auth.json("/api/life/goal?id=\(path)", method: "DELETE")
    }
}
