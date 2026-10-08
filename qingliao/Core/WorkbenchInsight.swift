//
//  WorkbenchInsight.swift
//  轻聊
//
//  P3 深度（工作模式）：「把数字变成判断」的**唯一口径文件**（纯逻辑，无 SwiftUI 依赖）。
//
//  四项深度（清单第 13~16 项）：
//    13. 目标停滞告警 —— N 天没推进 → 结论条与目标卡上出「该管了」
//    14. 习惯断签提示 —— 连续天数中断
//    15. 任务失败原因下钻 —— 不只红点，能看到为什么失败（原因文本由后端只读聚合口下发）
//    16. 用量趋势 —— 复用既有用量数据（state.db 按日聚合），不加任何录入
//
//  ⚠️ 三条纪律（与前几个 P 阶段同口径）：
//    1) **只对工作模式生效**：所有对外函数第一句都问 `Self.active`；生活模式拿到的永远是 nil/空。
//       口径取值仍只走 `WorkbenchScope.launched`（启动常量），本文件是本仓**唯一**为「深度」读它的地方
//       —— 视图层只问「有没有这条提示」，不自己写 `== .work`（真值表 D4 白名单钉着）。
//    2) **判断与文案都在这里**：视图只负责画 `label`，不许在视图里再拼一遍阈值/日期话术
//       （阈值改一处却漏改文案 = 界面说「3 天」实际按 5 天算）。
//    3) **纯 Foundation**：真值表直接编译本文件（Linux 上没有 SwiftUI），
//       所以这里只收**值**（日期、字符串集合、整数），不收 `GoalItem` 这类带 SwiftUI 文件的类型。
//       习惯那部分借 `HabitKit`（同为纯 Foundation）算连续天数 —— 归日/连续天数口径不在这里抄第二份。
//
//  口径取舍（2026-10-08，按 P2 同款「拍板 + 一行可回退」处理）：
//    · 停滞阈值 = **3 天**（`stallDays`）；断签下限 = 历史最好 **≥2 天** 才算「断」（`minBreakStreak`）。
//    · 「推进」的定义里**刻意排除 cron 汇报**：定时任务每天照常回一张「今天推第 N 步」，
//      若把汇报算成推进，本项要解决的「目标放凉了没人管」就永远不会响。详见 `GoalProgress`。
//    · 用量趋势取 **近 7 个自然日**（含今天）的 token 总量，按日键升序；全 0 = 没数据 = 不出这条。

import Foundation

enum WorkbenchInsight {

    // MARK: - 口径常量（单一真源）

    /// 目标停滞阈值：连续 N 个自然日没有真推进 → 「该管了」（含第 N 天当天就提示）
    static let stallThresholdDays = 3
    /// 断签下限：历史最好连续天数 < 这个值就谈不上「断签」（从没连过两天 = 还没养成，不打扰）
    static let minBreakStreak = 2
    /// 用量趋势的天数（含今天）
    static let trendDays = 7

    /// 深度四项是否生效。**只在这里读一次** `WorkbenchScope.launched`（生活模式 = 全不生效）。
    static var active: Bool { WorkbenchScope.launched == .work }

    // MARK: - 13. 目标停滞

    /// 目标推进的输入（**值**，不带 SwiftUI 类型；由卡片/结论条从 `GoalItem` 里取）
    struct GoalProgress: Equatable {
        var createdAt: Date
        /// 已全部完成（`isFinished`）
        var finished: Bool
        /// 用户手动暂停
        var paused: Bool
        /// 用户手动「现在开始推进」的时刻（`manualPushAt`）
        var manualPushAt: Date?
        /// 各步骤的「开始时间」——后台第一次把它列为「今天推这一步」时打戳（`startedAt`）
        var stepStartedAt: [Date]
        /// 各步骤的完成时刻（`doneAt`）
        var stepDoneAt: [Date]

        init(createdAt: Date,
             finished: Bool = false,
             paused: Bool = false,
             manualPushAt: Date? = nil,
             stepStartedAt: [Date] = [],
             stepDoneAt: [Date] = []) {
            self.createdAt = createdAt
            self.finished = finished
            self.paused = paused
            self.manualPushAt = manualPushAt
            self.stepStartedAt = stepStartedAt
            self.stepDoneAt = stepDoneAt
        }

        /// 最近一次**真推进**的时刻。
        /// 🚨 刻意**不含** `lastReport` / `lastPushedAt`：那是 cron 的汇报，不是目标在动。
        /// 把汇报算成推进 → 每天都有「推进」→ 停滞告警永远不响（本项就白做了）。
        var lastAdvancedAt: Date? {
            ([manualPushAt] + stepStartedAt.map { Optional($0) } + stepDoneAt.map { Optional($0) })
                .compactMap { $0 }
                .max()
        }
    }

    /// 停滞天数：返回「距最近一次推进几个自然日」，没到阈值 / 不适用（已完成、已暂停）→ nil。
    static func stallDays(_ g: GoalProgress,
                          now: Date,
                          calendar: Calendar = .current) -> Int? {
        guard !g.finished, !g.paused else { return nil }
        let base = g.lastAdvancedAt ?? g.createdAt
        let days = dayGap(from: base, to: now, calendar: calendar)
        guard days >= stallThresholdDays else { return nil }
        return days
    }

    /// 目标卡上的徽标文案（工作模式 + 该目标停滞时才有值）
    static func stallBadge(_ g: GoalProgress,
                           now: Date,
                           calendar: Calendar = .current) -> String? {
        guard active, let d = stallDays(g, now: now, calendar: calendar) else { return nil }
        return "该管了 · \(d) 天没动"
    }

    /// 结论条那句汇总（`count` = 停滞目标个数）。0 个 → nil（不出这条，不打扰）。
    static func stallHint(_ count: Int) -> String? {
        guard active, count > 0 else { return nil }
        return "有 \(count) 个长期目标 \(stallThresholdDays) 天以上没动过"
    }

    // MARK: - 14. 习惯断签

    struct HabitBreak: Equatable {
        /// 连续未打卡天数（从昨天往前数，**不含今天** —— 今天还没结束，不谎报「今天已漏」）
        var gapDays: Int
        /// 历史最长连续天数
        var best: Int
    }

    /// 断签判定：今天没打卡 + 昨天也没打卡 + 历史最好连续 ≥ `minBreakStreak` → 断签。
    /// `dayKeys` = 打卡日键集合（`HabitItem.days`，与 `HabitKit.dayKey` 同口径）。
    static func habitBreak(dayKeys: Set<String>,
                           today: Date,
                           calendar: Calendar = .current) -> HabitBreak? {
        guard active else { return nil }
        guard !dayKeys.isEmpty else { return nil }
        // 今天已打卡，或昨天的打卡还在 → 连续没断
        if dayKeys.contains(HabitKit.dayKey(today, calendar: calendar)) { return nil }
        guard let yesterday = calendar.date(byAdding: .day, value: -1,
                                           to: calendar.startOfDay(for: today)) else { return nil }
        if dayKeys.contains(HabitKit.dayKey(yesterday, calendar: calendar)) { return nil }

        // 从昨天往前数连续未打卡的天数（上限 366 天，防脏数据里出现超长空洞时死循环）
        var gap = 0
        var cursor = yesterday
        while gap < 366, !dayKeys.contains(HabitKit.dayKey(cursor, calendar: calendar)) {
            gap += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        guard gap > 0 else { return nil }

        // 历史最好连续：借 HabitKit 的现有口径（不在这里抄第二份连续算法）
        let best = HabitKit.bestStreak(HabitItem(title: "", days: dayKeys), calendar: calendar)
        guard best >= minBreakStreak else { return nil }
        return HabitBreak(gapDays: gap, best: best)
    }

    /// 习惯卡上的断签文案（工作模式 + 真断了才有值）
    static func habitBreakBadge(dayKeys: Set<String>,
                                today: Date,
                                calendar: Calendar = .current) -> String? {
        guard let b = habitBreak(dayKeys: dayKeys, today: today, calendar: calendar) else { return nil }
        return "断了 \(b.gapDays) 天 · 之前连续 \(b.best) 天"
    }

    // MARK: - 15. 任务失败原因

    /// 失败原因文本归一：把后端下发的 `reason` 洗成一行能显示的短句；
    /// 空/空白/只有空白行 → nil（此时卡片照旧只显示「失败」，不假装有原因）。
    static let reasonMaxChars = 120

    static func failureReason(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let oneLine = raw
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard !oneLine.isEmpty else { return nil }
        if oneLine.count <= reasonMaxChars { return oneLine }
        return String(oneLine.prefix(reasonMaxChars)) + "…"
    }

    // MARK: - 16. 用量趋势

    /// 一天的用量（日键 = `yyyy-MM-dd`，按**北京时区**由后端切好，App 不再自己归日）
    struct UsageDay: Equatable {
        var key: String
        var total: Int
    }

    struct UsageBar: Equatable {
        /// 轴标签，如 "10/3"
        var label: String
        /// 高度比例 0…1（按当期最大值归一；全 0 时不出趋势，见 `usageTrend`）
        var ratio: Double
        /// 是不是今天（高亮）
        var isToday: Bool
    }

    struct UsageTrend: Equatable {
        var bars: [UsageBar]
        /// 峰值那天（"10/5 · 421.3M"）
        var peakLabel: String
        /// 近 7 天合计（"1.2G" / "353.6M"）
        var totalLabel: String
        var note: String
    }

    /// 用量趋势：**近 7 天全 0（或不足 2 天有值）→ nil**（不出这条，界面保持原样）；
    /// 非工作模式 → nil（生活模式的用量卡一字不动）。
    static func usageTrend(_ days: [UsageDay]) -> UsageTrend? {
        guard active else { return nil }
        guard days.count >= 2 else { return nil }
        let maxTotal = days.map(\.total).max() ?? 0
        guard maxTotal > 0 else { return nil }
        let sum = days.reduce(0) { $0 + $1.total }
        let todayKey = days.last?.key
        let bars = days.map { d -> UsageBar in
            UsageBar(label: axisLabel(d.key),
                     ratio: maxTotal > 0 ? Double(max(d.total, 0)) / Double(maxTotal) : 0,
                     isToday: d.key == todayKey)
        }
        let peak = days.max { $0.total < $1.total }
        let peakLabel = peak.map { "\(axisLabel($0.key)) · \(mText($0.total))" } ?? ""
        return UsageTrend(bars: bars,
                          peakLabel: peakLabel,
                          totalLabel: mText(sum),
                          note: "近 \(days.count) 天合计 \(mText(sum))，最多 \(peakLabel)")
    }

    /// 趋势条上方的说明；趋势为空时 nil
    static func usageTrendNote(_ days: [UsageDay]) -> String? { usageTrend(days)?.note }

    // MARK: - 内部

    /// 自然日差（跨夏令时也稳定：按 `startOfDay` 的日序算，不用秒数除以 86400）
    static func dayGap(from: Date, to: Date, calendar: Calendar = .current) -> Int {
        let a = calendar.startOfDay(for: from)
        let b = calendar.startOfDay(for: to)
        let days = calendar.dateComponents([.day], from: a, to: b).day ?? 0
        return max(0, days)
    }

    /// "2026-10-08" → "10/8"（解析失败原样返回，不炸）
    static func axisLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let m = Int(parts[1]), let d = Int(parts[2]) else { return key }
        return "\(m)/\(d)"
    }

    /// token 数 → 文本（与 `TokenUsage.mText` 同口径：M / G 两档，一位小数）
    static func mText(_ n: Int) -> String {
        let v = Double(max(n, 0))
        if v >= 1_000_000_000 { return String(format: "%.1fG", v / 1_000_000_000) }
        return String(format: "%.1fM", v / 1_000_000)
    }
}
