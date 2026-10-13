import Foundation
import Observation

/// 专注计时（番茄钟）状态机 —— v4.0.104 待做池⑫。
///
/// 设计要点（每一条都是故意为之）：
/// 1. **会话可持久化**：只存「习惯 id + 开始时刻 + 计划分钟」三个数（`FocusSession`），
///    剩余时间一律由 `now` 现算。逐秒递减的写法一挂起就停表，这条躲开了。
/// 2. **落账不依赖视图**：冷启动 `init` → `refresh()` 就能把「杀 App 期间已到点」的那一轮补记
///    （走 `onRecord` 回调；回调还没接线时先压进 `pendingRecords`，接线瞬间补账，绝不静默丢一次专注）。
/// 3. **记录交出去、量不自己写**：本 store 只管计时与会话，习惯的量由 `HabitStore` 落
///    （单一真源：习惯数据只有 HabitStore 一个写入口）。
/// 4. 归日 = **开始那一刻**（`HabitKit.focusDayKey`），跨零点的一轮只记给开始那天。
@Observable
@MainActor
final class FocusTimerStore {

    static let shared = FocusTimerStore()

    /// 进行中的会话（nil = 没在专注）
    private(set) var session: FocusSession?
    /// 剩余秒数（仅用于显示；真相永远由 session + now 现算）
    private(set) var remaining: Int = 0
    /// 最近一次落账回执（UI 用来提示「已记 25 分钟」；新会话开始时清空）
    private(set) var lastRecord: (habitId: String, minutes: Int)?

    /// 落账回调（App 启动时接线到 HabitStore）
    var onRecord: ((_ habitId: String, _ startedAt: Date, _ minutes: Int) -> Void)?
    /// 回调尚未接线时暂存的待落账（接线时补）
    private var pendingRecords: [(habitId: String, startedAt: Date, minutes: Int)] = []

    private var ticker: Task<Void, Never>?
    private let defaults: UserDefaults
    private let storageKey: String

    var isRunning: Bool { session != nil }

    init(defaults: UserDefaults = .standard,
         storageKey: String = UserDefaultsKey.focusSession) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.session = Self.loadSession(defaults: defaults, key: storageKey)
        // 冷启动即对账（含「杀 App 期间已到点」→ 自动落账）
        if session != nil {
            refresh()
            // ⚠️ 恢复出来的会话**必须补起节拍**：只在 start() 里 startTicker 的话，冷启动/杀 App
            //    重启后的那一轮倒计时会冻在原地、到点也不自动落账 —— 静默违背本功能最核心的
            //    「杀 App / 挂起都不丢」口径（只读审查用探针实测：恢复后 remaining 恒 1500）。
            //    refresh() 可能已把它收尾（杀 App 期间就到点）→ 再判一次 session。
            if session != nil { startTicker() }
        } else {
            remaining = 0
        }
    }

    // MARK: - 生命周期

    /// 开始一轮专注（已有会话则先按现在结算 —— 不静默丢半分）
    func start(habitId: String, minutes: Int, now: Date = Date()) {
        guard !habitId.isEmpty else { return }
        if session != nil { finish(now: now) }
        lastRecord = nil
        let s = FocusSession(habitId: habitId, startedAt: now, plannedMinutes: minutes)
        session = s
        persist(s)
        remaining = HabitKit.focusRemaining(s, now: now)
        startTicker()
    }

    /// 前台的每秒节拍：只刷新显示，到点自动收尾落账
    func refresh(now: Date = Date()) {
        guard let s = session else { remaining = 0; return }
        remaining = HabitKit.focusRemaining(s, now: now)
        if remaining == 0 { finish(now: now) }
    }

    /// 用户主动结束：返回本轮记了多少分钟（0 = 不足 1 分钟，不记）
    @discardableResult
    func stop(now: Date = Date()) -> Int {
        guard session != nil else { return 0 }
        let minutes = HabitKit.focusRecordMinutes(session!, now: now)
        finish(now: now)
        return minutes
    }

    /// 放弃本轮：**不记任何量**，直接清会话（UI 上要说清「放弃不记录」）
    func cancel() {
        session = nil
        remaining = 0
        lastRecord = nil
        persist(nil)
        ticker?.cancel()
        ticker = nil
    }

    /// 接线落账回调 + 补交待落账
    func attach(_ record: @escaping (_ habitId: String, _ startedAt: Date, _ minutes: Int) -> Void) {
        onRecord = record
        guard !pendingRecords.isEmpty else { return }
        let queued = pendingRecords
        pendingRecords.removeAll()
        for item in queued { record(item.habitId, item.startedAt, item.minutes) }
    }

    // MARK: - 内部

    /// 收尾：算该记多少 → 落账 → 清会话
    private func finish(now: Date) {
        guard let s = session else { return }
        let minutes = HabitKit.focusRecordMinutes(s, now: now)
        session = nil
        remaining = 0
        persist(nil)
        ticker?.cancel()
        ticker = nil
        guard minutes > 0 else { return }   // 不足 1 分钟：不记（不留假进度）
        lastRecord = (s.habitId, minutes)
        if let onRecord {
            onRecord(s.habitId, s.startedAt, minutes)
        } else {
            pendingRecords.append((s.habitId, s.startedAt, minutes))
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
                if self.session == nil { return }   // 已收尾，停表
            }
        }
    }

    private func persist(_ s: FocusSession?) {
        guard let s else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: storageKey) }
    }

    private static func loadSession(defaults: UserDefaults, key: String) -> FocusSession? {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(FocusSession.self, from: data),
              s.plannedMinutes > 0 else { return nil }
        return s
    }
}
