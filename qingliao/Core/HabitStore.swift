import Foundation
import SwiftUI

// MARK: - v4.0.46 待做池⑤ 习惯 Store
//
// 存储：复刻 TodoStore / MemoStore 架构（本地 UserDefaults 兜底 + NAS pin_write/pin_read 文件双写，
//       文件 habits.json 与 todos.json 同目录），**零后端改动**。
// 继承 TodoStore 的坑：手写解码 decodeIfPresent / loadLocal 解码策略与 save 对齐 /
//       loadFromServer 按 id 合并（并集）而非整体替换 / FIFO 写链（防慢的旧快照后到让已删条目复活）。
// 口径见 Core/HabitKit.swift（每天一次 + 不可补签，归日按本地日）。

@Observable
@MainActor
final class HabitStore {

    static let shared = HabitStore()

    private(set) var habits: [HabitItem] = []
    private let storagePathKey = "qingliao_habit_storage_path"
    private let fileName = "habits.json"
    private let defaultsKey = "qingliao_habits_data"

    // 强引用（与 MemoStore/TodoStore 同源）：weak 时调用方一返回 auth 就没了，
    // NAS 回写会在 writeToFile 的 `guard let auth` 处静默 return。
    var auth: AuthStore?

    func attach(auth: AuthStore) {
        self.auth = auth
    }

    var storagePath: String {
        get { UserDefaults.standard.string(forKey: storagePathKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: storagePathKey) }
    }

    /// FIFO 串行写链（排队形态与理由见 Core/SyncedStore.swift 的「FIFO 写链」段）
    private var writeChain: Task<Void, Never> = Task {}

    private var filePath: String {
        SyncedStore.remotePath(storagePath: storagePath, fileName: fileName)
    }

    private init() {
        loadLocal()
    }

    // MARK: - CRUD

    /// 新增习惯（最新在前；同标题 5 分钟内连点不重复）
    @discardableResult
    func add(title: String) -> Bool {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if let first = habits.first, first.title == text,
           Date().timeIntervalSince(first.createdAt) < 300 {
            return true
        }
        habits.insert(HabitItem(title: text, updatedAt: Date()), at: 0)
        save()
        return true
    }

    func delete(_ item: HabitItem) {
        habits.removeAll { $0.id == item.id }
        save()
    }

    func update(_ item: HabitItem, title: String) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let idx = habits.firstIndex(where: { $0.id == item.id }) else { return }
        guard habits[idx].title != text else { return }
        habits[idx].title = text
        habits[idx].updatedAt = Date()
        save()
    }

    /// 打卡（幂等：同一天重复打卡只记一次）。返回 true 表示本次真的新增了一次打卡。
    @discardableResult
    func checkIn(_ item: HabitItem, on day: Date = Date()) -> Bool {
        guard let idx = habits.firstIndex(where: { $0.id == item.id }) else { return false }
        let before = habits[idx].days.count
        habits[idx] = HabitKit.checkingIn(habits[idx], on: day)
        guard habits[idx].days.count != before else { return false }
        save()
        return true
    }

    /// 取消当天的打卡（仅当天可撤；与「不可补签」同口径）
    @discardableResult
    func undo(_ item: HabitItem, on day: Date = Date()) -> Bool {
        guard let idx = habits.firstIndex(where: { $0.id == item.id }) else { return false }
        let before = habits[idx].days.count
        habits[idx] = HabitKit.undoing(habits[idx], on: day)
        guard habits[idx].days.count != before else { return false }
        save()
        return true
    }

    /// 以 store 里的**当前**副本为准判今日是否已打卡（视图传进来的可能是旧快照）
    func isDone(_ item: HabitItem, on day: Date = Date()) -> Bool {
        guard let cur = habits.first(where: { $0.id == item.id }) else { return false }
        return HabitKit.isDone(cur, on: day)
    }

    // MARK: - 计量维度（v4.0.104 待做池⑫）

    /// 新建计量习惯（量 / 时长）。target 必须 > 0，否则退回二值形态（与 isMetric 同一口径）。
    /// 时长维度单位固定「分钟」，可接专注计时自动累计。
    @discardableResult
    func addMetric(title: String, metric: HabitMetric, target: Double, unit: String) -> Bool {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, target > 0 else { return false }
        if let first = habits.first, first.title == text,
           Date().timeIntervalSince(first.createdAt) < 300 {
            return true
        }
        let u = metric == .duration ? "分钟" : unit.trimmingCharacters(in: .whitespacesAndNewlines)
        habits.insert(HabitItem(title: text, updatedAt: Date(), metric: metric,
                                target: target, unit: u), at: 0)
        save()
        return true
    }

    /// 改计量设置（目标 / 单位 / 维度）。也用于把二值习惯**升级**成计量（此时 target 必填）。
    func updateMetric(_ item: HabitItem, metric: HabitMetric, target: Double, unit: String) {
        guard target > 0, let idx = habits.firstIndex(where: { $0.id == item.id }) else { return }
        let u = metric == .duration ? "分钟" : unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard habits[idx].metric != metric || habits[idx].target != target || habits[idx].unit != u
        else { return }
        habits[idx].metric = metric
        habits[idx].target = target
        habits[idx].unit = u
        habits[idx].updatedAt = Date()
        save()
    }

    /// 退回二值形态（metric = nil）。⚠️ **progress 保留不删**：万一用户点错还能改回来，
    /// 数据本身不再参与判定（isMetric = false → isDone 回到 days 口径）。
    func clearMetric(_ item: HabitItem) {
        guard let idx = habits.firstIndex(where: { $0.id == item.id }) else { return }
        guard habits[idx].metric != nil else { return }
        habits[idx].metric = nil
        habits[idx].target = nil
        habits[idx].unit = nil
        habits[idx].updatedAt = Date()
        save()
    }

    /// 加量（可负）；返回是否真的变化了
    @discardableResult
    func addAmount(_ amount: Double, to item: HabitItem, on day: Date = Date()) -> Bool {
        guard let idx = habits.firstIndex(where: { $0.id == item.id }) else { return false }
        var next = HabitKit.adding(amount, to: habits[idx], on: day)
        // ⚠️ updatedAt 必须是「此刻」而不是被写的那天（专注落账的 day = 会话开始时刻）：
        //    同步合并按 updatedAt 取较新，用过去时刻会让本地刚记的量被远端旧快照盖掉。
        next.updatedAt = Date()
        guard next != habits[idx] else { return false }
        habits[idx] = next
        save()
        return true
    }

    /// 直接设值（进度条拖动 / 详情页输入框）
    @discardableResult
    func setProgress(_ value: Double, for item: HabitItem, on day: Date = Date()) -> Bool {
        guard let idx = habits.firstIndex(where: { $0.id == item.id }) else { return false }
        var next = HabitKit.settingProgress(value, for: habits[idx], on: day)
        next.updatedAt = Date()   // 同上：同步合并看 updatedAt，不能用过去时刻
        guard next != habits[idx] else { return false }
        habits[idx] = next
        save()
        return true
    }

    /// 以 store 里的**当前**副本为准取当日进度（视图传进来的可能是旧快照）
    func progress(_ item: HabitItem, on day: Date = Date()) -> Double {
        guard let cur = habits.first(where: { $0.id == item.id }) else { return 0 }
        return HabitKit.dayProgress(cur, on: day)
    }

    /// 今日已打卡个数（页级副标题用）
    var todayDoneCount: Int {
        let today = Date()
        return habits.filter { HabitKit.isDone($0, on: today) }.count
    }

    /// 列表顺序 = 最后修改时间倒序
    var sorted: [HabitItem] {
        habits.sorted { $0.sortDate > $1.sortDate }
    }

    // MARK: - 持久化（与 TodoStore 同款：本地 UserDefaults + NAS 文件双写）

    private func save() {
        guard let data = SyncedStore.encode(habits) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)

        let path = filePath
        let authForWrite = auth   // 强捕获（先绑局部），理由同 MemoStore
        let prev = writeChain
        writeChain = Task {
            await prev.value                                  // FIFO：等前一次写完再写本次快照
            await SyncedStore.writeToFile(auth: authForWrite, path: path, data: data)
        }
    }

    private func loadLocal() {
        if let decoded = SyncedStore.readLocal([HabitItem].self, defaultsKey: defaultsKey) {
            habits = decoded
        }
    }

    /// 从 NAS 拉取（按 id 合并取较新，不整体替换）
    func loadFromServer() async {
        guard let remote = await SyncedStore.readRemote([HabitItem].self, auth: auth, path: filePath) else { return }

        var byID: [String: HabitItem] = [:]
        for h in remote { byID[h.id] = h }
        for h in habits {
            if let r = byID[h.id] {
                byID[h.id] = r.sortDate >= h.sortDate ? r : h
            } else {
                byID[h.id] = h
            }
        }
        let merged = byID.values.sorted { $0.sortDate > $1.sortDate }
        // changed 判定要比 title + days（打卡集合），否则只在本地打卡不合并、NAS 那份长期失真。
        // 时间按整秒比，避免编码丢小数秒导致每次拉取白写一次 NAS。
        var remoteByID: [String: HabitItem] = [:]
        for h in remote { remoteByID[h.id] = h }
        let changed = merged.count != remote.count || merged.contains { h in
            guard let r = remoteByID[h.id] else { return true }
            // ⚠️ 计量字段与 progress 必须一起比：只比 title/days 时，计量习惯的「只在本地记的量」
            //    永远判成「没变化」→ 不写 NAS，下次拉取被旧快照盖掉（与当年 days 的坑同型）。
            return h.title != r.title || h.days != r.days
                || h.metric != r.metric || h.target != r.target || h.unit != r.unit
                || h.progress != r.progress
                || Int(h.updatedAt.timeIntervalSince1970) != Int(r.updatedAt.timeIntervalSince1970)
        }
        habits = merged
        if changed { save() }
    }
}
