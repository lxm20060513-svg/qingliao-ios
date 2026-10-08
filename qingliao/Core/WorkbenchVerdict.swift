import Foundation

// MARK: - P1 首屏结论条（VerdictBar）· 纯逻辑
//
// 依据：`design-plans/finesse-refactor-checklist.md` v2 的 P1 五项（VerdictBar + 只读聚合口 + 下钻 + 空态）。
//
// 为什么单独摊成一个纯 Foundation 文件：下面这些判断在真机上只能靠肉眼（「0 到底显不显示」「跨天的
// 「昨夜」怎么切」「断网时是显示 `--` 还是说句人话」），而它们全是可枚举的取值 → 写成真值表
// （`scripts/ql_verdict/truth_table_verdict.swift`，check_swift.sh 第 92 段）才能防回归。
// 本文件**不许 import SwiftUI**（真值表要能在 Linux 上编跑）。
//
// 口径（P1 拍板）：
//   · 三个槽位固定、顺序固定：待你处理 · 目标今日步 · 昨夜任务；
//   · **不显示 0、也不显示 `--`**：某槽为 0 时给一句人话（都清了 / 还没推进 / 无任务）；
//     三个槽都没有数字 = 空态，整条换成「一句引导 + 一个动作按钮」；
//   · 后端读不到（断网 / 老后端）时**只降级夜任务那一槽**（本地两项照旧给真数字），
//     并补一句人话 + 「重试」动作 —— 断网不等于整条消失。
enum WorkbenchVerdict {

    // MARK: - 槽位

    /// 三个槽位（`allCases` 的顺序 = 界面上从左到右的顺序）
    enum Slot: String, CaseIterable, Identifiable {
        case pending, todaySteps, night
        var id: String { rawValue }
        var label: String {
            switch self {
            case .pending:    return "待你处理"
            case .todaySteps: return "目标今日步"
            case .night:      return "昨夜任务"
            }
        }
    }

    /// 点一个槽位去哪儿（P1 验收：每个数字都要点得进去）
    enum Drill: String, Identifiable {
        case pendingList      // → 任务中心
        case todayStepList    // → 今日推进明细
        case nightList        // → 昨夜任务明细
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pendingList:   return Slot.pending.label
            case .todayStepList: return "今日推进"
            case .nightList:     return Slot.night.label
            }
        }
    }

    static func drill(_ slot: Slot) -> Drill {
        switch slot {
        case .pending:    return .pendingList
        case .todaySteps: return .todayStepList
        case .night:      return .nightList
        }
    }

    // MARK: - 取数结果

    /// 汇总数字。`nightTotal == nil` = 夜里那一项还没拿到（加载中或读不到）。
    struct Counts: Equatable {
        var pending: Int
        var todaySteps: Int
        var nightTotal: Int?
        var nightFailed: Int?

        init(pending: Int, todaySteps: Int, nightTotal: Int? = nil, nightFailed: Int? = nil) {
            self.pending = pending
            self.todaySteps = todaySteps
            self.nightTotal = nightTotal
            self.nightFailed = nightFailed
        }
    }

    enum State: Equatable {
        case loading
        case ready(Counts)
        /// 后端读不到：夜任务未知，本地两项照旧
        case offline(Counts)
    }

    /// 界面上的一格
    struct Chip: Equatable, Identifiable {
        var slot: Slot
        /// 数字位：有数字时是 `"3"` / `"5 · 失败 1"`，没数字时是一句人话
        var value: String
        /// 这一格到底是不是数字（决定字号/颜色，也决定整条算不算空态）
        var hasNumber: Bool
        /// 需要提醒（昨夜有失败 / 读不到）
        var warn: Bool
        var id: String { slot.rawValue }
    }

    // MARK: - 文案（唯一真源：护栏按这些常量断言，界面不许再写字面量）

    static let emptyPending = "都清了"
    static let emptySteps = "还没推进"
    static let emptyNight = "无任务"
    static let loadingHint = "正在同步…"
    static let emptyHint = "今天还没有要处理的事"
    static let offlineHint = "连不上后端，昨夜任务读不到"
    static let startAction = "说一句话就能开始"
    static let retryAction = "重试"

    // MARK: - 时间窗口

    /// 「昨夜」= 昨天 20:00 → 今天 09:00（本地日历）。
    /// 若现在还没到 09:00，右端取「现在」——否则会统计到未来（比「显示 0」更糟的错）。
    static func nightWindow(now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let yday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let start = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: yday) ?? yday
        let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
        let end = now < nine ? now : nine
        return (start, end)
    }

    /// 某时刻是否落在「昨夜」窗口内（左闭右闭）
    static func inNightWindow(_ t: Date, now: Date, calendar: Calendar) -> Bool {
        let (start, end) = nightWindow(now: now, calendar: calendar)
        return t >= start && t <= end
    }

    /// 某时刻是否属于「今天」（本地日历）
    static func isToday(_ t: Date, now: Date, calendar: Calendar) -> Bool {
        calendar.isDate(t, inSameDayAs: now)
    }

    // MARK: - 三格怎么显示

    /// 三格（`.loading` 返回空数组 = 还没数可给，界面只显示那句「正在同步…」）
    static func chips(_ state: State) -> [Chip] {
        let counts: Counts
        switch state {
        case .loading:        return []
        case .ready(let c):   counts = c
        case .offline(let c): counts = c
        }
        return Slot.allCases.map { slot in
            switch slot {
            case .pending:
                let n = max(0, counts.pending)
                return Chip(slot: slot,
                            value: n > 0 ? "\(n)" : emptyPending,
                            hasNumber: n > 0, warn: false)

            case .todaySteps:
                let n = max(0, counts.todaySteps)
                return Chip(slot: slot,
                            value: n > 0 ? "\(n)" : emptySteps,
                            hasNumber: n > 0, warn: false)

            case .night:
                guard let total = counts.nightTotal else {
                    // 还没拿到：不写 `--`，写「读不到」（人话）
                    return Chip(slot: slot, value: "读不到", hasNumber: false, warn: true)
                }
                let failed = max(0, counts.nightFailed ?? 0)
                if total <= 0 {
                    return Chip(slot: slot, value: emptyNight, hasNumber: false, warn: false)
                }
                return Chip(slot: slot,
                            value: failed > 0 ? "\(total) · 失败 \(failed)" : "\(total)",
                            hasNumber: true, warn: failed > 0)
            }
        }
    }

    /// 汇总数字（`.loading` → nil：还没数可给）。
    /// 视图要单取某一格（下钻里要把话说准）走这里，别自己 switch `State`。
    static func counts(_ state: State) -> Counts? {
        switch state {
        case .loading:        return nil
        case .ready(let c):   return c
        case .offline(let c): return c
        }
    }

    static func isOffline(_ state: State) -> Bool {
        if case .offline = state { return true }
        return false
    }

    /// 三个槽一个数字都没有（且不是断网、不是加载中）＝空态。
    /// 只有 `.ready` 才可能是空态：加载中/读不到都另有话说，不该被当成「今天没事做」。
    static func isEmpty(_ state: State) -> Bool {
        guard case .ready(let counts) = state else { return false }
        return chips(.ready(counts)).allSatisfy { !$0.hasNumber }
    }

    /// 配的一句话（nil = 不需要：三格都在报数字）
    static func hint(_ state: State) -> String? {
        switch state {
        case .loading:
            return loadingHint
        case .ready(let c):
            let anyNumber = c.pending > 0 || c.todaySteps > 0 || (c.nightTotal ?? 0) > 0
            return anyNumber ? nil : emptyHint
        case .offline(let c):
            // 本地还有事 → 明说只有夜任务读不到；本地也空 → 先给引导（别拿网络问题吓人）
            let localHasWork = c.pending > 0 || c.todaySteps > 0
            return localHasWork ? offlineHint : emptyHint
        }
    }

    /// 配的动作按钮文案（nil = 不给按钮）
    static func actionTitle(_ state: State) -> String? {
        switch state {
        case .loading:
            return nil
        case .ready:
            return isEmpty(state) ? startAction : nil
        case .offline(let c):
            return (c.pending == 0 && c.todaySteps == 0) ? startAction : retryAction
        }
    }

    // MARK: - 后端只读聚合口的解析

    /// 昨夜的一条任务
    /// `reason` = P3-15 失败原因下钻：后端只读聚合口把留档 `## Error` 段洗成一行下发；
    /// 老后端没有这个键 → nil（列表照旧只显示「失败」，绝不假装有原因）。
    struct NightTask: Equatable, Identifiable {
        var id: String
        var title: String
        var failed: Bool
        var at: Date
        var reason: String? = nil
    }

    /// 解析 `GET /api/agent/tasks/night` 的返回体。
    /// `ok != true` 一律当读不到（返回 nil）——**不猜、不编数字**：宁可界面写「读不到」。
    /// items 里缺字段/时间戳非法的那几条直接跳过（明细少一条好过整条结论是假的）。
    static func parseNight(_ json: [String: Any]) -> (total: Int, failed: Int, items: [NightTask])? {
        guard (json["ok"] as? Bool) == true else { return nil }
        guard let night = json["night"] as? [String: Any],
              let total = intValue(night["total"]) else { return nil }
        let failed = intValue(night["failed"]) ?? 0
        var items: [NightTask] = []
        for raw in (night["items"] as? [[String: Any]]) ?? [] {
            guard let title = raw["title"] as? String, !title.isEmpty,
                  let ts = doubleValue(raw["at"]) else { continue }
            let id = (raw["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(ts)-\(items.count)"
            let status = (raw["status"] as? String) ?? ""
            // P3-15：失败原因可选下发（非字符串 / 空串一律当「没有原因」）
            let reason = (raw["reason"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            items.append(NightTask(id: id, title: title, failed: status == "error" || status == "failed",
                                   at: Date(timeIntervalSince1970: ts), reason: reason))
        }
        items.sort { $0.at > $1.at }
        return (max(0, total), max(0, failed), items)
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
