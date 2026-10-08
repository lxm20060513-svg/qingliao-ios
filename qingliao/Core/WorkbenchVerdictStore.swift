import Foundation
import Observation

// MARK: - P1 首屏结论条 · 取数（只读）
//
// 三个数字的来源（P1 清单第 3 项：**不新增写接口**，只读聚合）：
//   ① 待你处理   = 任务中心的未完成条目（本地，`TaskCenterStore`）
//   ② 目标今日步 = 今天（本地日历）勾掉的步骤（本地，`GoalStore`）
//   ③ 昨夜任务   = 后端只读聚合口 `GET /api/agent/tasks/night`（窗口 = 昨天 20:00 → 今天 09:00）
//
// 准绳：**本地两项绝不因为网络失败而消失**（用户最烦的是「一断网整条就空了」）；
// 夜里那一项失败 → 只它降级成「读不到」+ 重试，其余照常报数。
@MainActor
@Observable
final class WorkbenchVerdictStore {
    static let shared = WorkbenchVerdictStore()

    private(set) var state: WorkbenchVerdict.State = .loading
    /// 下钻用：待你处理（任务中心未完成）
    private(set) var pendingItems: [TaskCenterItem] = []
    /// 下钻用：今日推进（今天勾掉的步骤）
    private(set) var todaySteps: [TodayStep] = []
    /// 下钻用：昨夜任务明细
    private(set) var nightItems: [WorkbenchVerdict.NightTask] = []

    struct TodayStep: Identifiable, Equatable {
        var id: String
        var goal: String
        var step: String
        var at: Date
    }

    private var inFlight = false

    private init() {}

    /// 取一次数：冷启动、回前台、下钻后返回、点「重试」都走这里。
    /// 并发调用只留一次（结论条可能在多个页面同时挂着）。
    func refresh(auth: AuthStore) async {
        if inFlight { return }
        inFlight = true
        defer { inFlight = false }

        let now = Date()
        let cal = Calendar.current

        // 本地两项：同步取（都在内存里，无 IO）
        pendingItems = TaskCenterStore.shared.tasks.filter { !$0.completed }
        todaySteps = Self.todaySteps(now: now, calendar: cal)
        let local = WorkbenchVerdict.Counts(pending: pendingItems.count,
                                           todaySteps: todaySteps.count)

        do {
            let json = try await auth.json("/api/agent/tasks/night", method: "GET")
            guard let parsed = WorkbenchVerdict.parseNight(json) else { throw VerdictError.badPayload }
            nightItems = parsed.items
            everLoaded = true
            state = .ready(WorkbenchVerdict.Counts(pending: local.pending,
                                                  todaySteps: local.todaySteps,
                                                  nightTotal: parsed.total,
                                                  nightFailed: parsed.failed))
        } catch {
            nightItems = []
            // 只降级夜里那一槽：本地两项照旧给真数字（状态里带着 local）
            state = .offline(local)
        }
    }

    enum VerdictError: Error { case badPayload }

    /// 纯逻辑：今天勾掉的步骤（倒序）
    static func todaySteps(now: Date, calendar: Calendar) -> [TodayStep] {
        GoalStore.shared.goals.flatMap { goal in
            goal.steps.compactMap { step -> TodayStep? in
                guard step.done, let at = step.doneAt,
                      WorkbenchVerdict.isToday(at, now: now, calendar: calendar) else { return nil }
                return TodayStep(id: step.id, goal: goal.title, step: step.title, at: at)
            }
        }
        .sorted { $0.at > $1.at }
    }
}
