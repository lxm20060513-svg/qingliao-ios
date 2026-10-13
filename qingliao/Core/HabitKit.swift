import Foundation

// MARK: - v4.0.46 待做池⑤ 习惯打卡（纯逻辑真值对象 · 与 UI / Store 解耦）
//
// 口径（用户 2026-10-04 在 App 卡片拍板 = 选项①）：**每天一次 + 不可补签**。
//   · 频次固定「每天一次」；不做「每周 N 次」（选项③未选）。
//   · 连续天数 = 连续自然日；漏一天归零。**不实现任何补签路径**
//     —— 故 HabitItem 里没有「补签标记」字段，数据模型只存「打卡日期集合」。
//   · 归日一律按传入 Calendar 的时区（默认本地）—— 23:59 与次日 00:01 分属两天，
//     绝不按 UTC 归日（否则东八区 08:00 前的打卡会算到前一天）。
//
// 本文件**不 import SwiftUI**：纯 Foundation，既给 HabitStore/HabitSection 用，也让
// scripts/ql_habit/truth_table_habit.swift 能直接编这份实现（真编译真跑，没有表/实现漂移的洞）。

/// 习惯的计量维度（v4.0.104 待做池⑫）。
/// `nil` = 二值打卡（老数据零迁移：缺键回落 nil，一切旧行为逐字不变）。
enum HabitMetric: String, Codable, Sendable {
    /// 量：杯 / 页 / 次 …（手动加减或直接设值）
    case amount
    /// 时长：单位固定「分钟」，可接专注计时（番茄钟）自动累计
    case duration
}

struct HabitItem: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// 打卡日期集合，键 = 本地日 "yyyy-MM-dd"（去重天然成立：同一自然日只有一个键）。
    /// ⚠️ **只有二值习惯用它**；计量习惯的达标状态一律由 `progress` 现算
    /// （单一真源：绝不在达标时往 days 里冗余写一份，否则两处会分叉）。
    var days: Set<String>
    /// 计量维度（nil = 二值）
    var metric: HabitMetric?
    /// 目标量（> 0 才生效；配合 unit 变成「8 杯 / 30 分钟」）
    var target: Double?
    /// 计量单位（"杯" / "分钟" / "页" …）；duration 恒为「分钟」
    var unit: String?
    /// 按本地日累计的已完成量（键 = 本地日，与 days 同一套日键）
    var progress: [String: Double]

    init(id: String = UUID().uuidString, title: String,
         createdAt: Date = Date(), updatedAt: Date? = nil, days: Set<String> = [],
         metric: HabitMetric? = nil, target: Double? = nil, unit: String? = nil,
         progress: [String: Double] = [:]) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.days = days
        self.metric = metric
        self.target = target
        self.unit = unit
        self.progress = progress
    }

    /// 手写解码（继承 MemoStore/TodoStore 的坑 1）：新增字段必须 decodeIfPresent + 默认值，
    /// 旧数据缺键不解崩。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        days = try c.decodeIfPresent(Set<String>.self, forKey: .days) ?? []
        metric = try c.decodeIfPresent(HabitMetric.self, forKey: .metric)
        target = try c.decodeIfPresent(Double.self, forKey: .target)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        progress = try c.decodeIfPresent([String: Double].self, forKey: .progress) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, days, metric, target, unit, progress
    }

    var sortDate: Date { updatedAt }

    /// 是否是「达到目标才算完成」的计量习惯：metric 与正 target 必须同时在场。
    /// ⚠️ 只判 `metric != nil` 会让「建了计量但没填目标」的习惯永远判不成完成 →
    ///    连续天数/页卡统计被静默污染，故把有效性判定收在这一个地方。
    var isMetric: Bool { metric != nil && (target ?? 0) > 0 }

    /// 单位文案（duration 恒「分钟」；量维度缺单位时退回空串，由 UI 只显示数字）
    var unitText: String {
        if let u = unit, !u.isEmpty { return u }
        return metric == .duration ? "分钟" : ""
    }
}

enum HabitKit {

    // MARK: - 归日

    /// 本地日键（"yyyy-MM-dd"）。口径唯一真源：所有「今天是不是打了卡」「哪几天打了卡」
    /// 都走这里，避免各处自己 format 出不一致的键。
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 某个自然日是否已达标 —— **全仓唯一的分流点**：二值看 `days`，计量看 `progress >= target`。
    /// 连续天数 / 页卡统计 / 曲线 / 今日计数一律经这里，计量维度才可能不污染既有口径。
    static func isDoneKey(_ habit: HabitItem, key: String) -> Bool {
        if habit.isMetric { return progressValue(habit, key: key) >= (habit.target ?? 0) }
        return habit.days.contains(key)
    }

    /// 某个自然日是否已打卡（日键版本的上层包装）
    static func isDone(_ habit: HabitItem, on date: Date, calendar: Calendar = .current) -> Bool {
        isDoneKey(habit, key: dayKey(date, calendar: calendar))
    }

    // MARK: - 计量维度（v4.0.104）

    /// 某日已累计的完成量（负值一律当 0，防止历史脏数据把进度条画到反面）
    static func progressValue(_ habit: HabitItem, key: String) -> Double {
        max(0, habit.progress[key] ?? 0)
    }

    /// 某日已累计的完成量（按日期）
    static func dayProgress(_ habit: HabitItem, on date: Date,
                            calendar: Calendar = .current) -> Double {
        progressValue(habit, key: dayKey(date, calendar: calendar))
    }

    /// 今日进度比例（0…1；非计量或目标无效 → 二值形态：已完成 1 / 未完成 0）
    static func progressFraction(_ habit: HabitItem, on date: Date,
                                 calendar: Calendar = .current) -> Double {
        guard habit.isMetric else { return isDone(habit, on: date, calendar: calendar) ? 1 : 0 }
        let t = habit.target ?? 0
        guard t > 0 else { return 0 }
        return min(1, dayProgress(habit, on: date, calendar: calendar) / t)
    }

    /// 进度文案：「3/8 杯」/「12/30 分钟」/ 完成时「已完成」；二值习惯返回空串（由调用方画圈）
    /// 数字去尾零：8 显示 "8"、7.5 显示 "7.5"（避免出现 "8.0 杯" 这种假精度）
    static func progressText(_ habit: HabitItem, on date: Date,
                             calendar: Calendar = .current) -> String {
        guard habit.isMetric else { return "" }
        let t = habit.target ?? 0
        guard t > 0 else { return "" }
        if isDone(habit, on: date, calendar: calendar) { return "已完成" }
        let cur = dayProgress(habit, on: date, calendar: calendar)
        let u = habit.unitText
        return u.isEmpty ? "\(numberText(cur))/\(numberText(t))"
                         : "\(numberText(cur))/\(numberText(t)) \(u)"
    }

    /// 该习惯**已达标**的日键集合 —— 连续天数 / 最长连续 / 累计天数 / 统计一律经这里。
    /// ⚠️ 绝不直接读 `habit.days`：计量习惯的达标日不在 days 里，直读会让连续天数恒为 0
    ///    （本轮落码时真踩过：`isDone` 判对了，`streak` 却直读 days → 计量习惯连续天数永远 0）。
    static func doneDayKeys(_ habit: HabitItem) -> Set<String> {
        guard habit.isMetric else { return habit.days }
        let t = habit.target ?? 0
        guard t > 0 else { return [] }
        return Set(habit.progress.filter { max(0, $0.value) >= t }.keys)
    }

    /// 计量习惯「点一下」的步长：量维度 = 1（一页/一杯），时长维度 = 5 分钟。
    /// ⚠️ 必须 > 0：步长为 0 会让「点一下毫无反应」，而真值表只钉会漏掉这种哑掉。
    static func metricStep(_ habit: HabitItem) -> Double {
        habit.metric == .duration ? 5 : 1
    }

    /// 数字去尾零（纯展示；真值表钉 8 → "8"、7.5 → "7.5"、0.25 → "0.25"）
    static func numberText(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var t = String(format: "%.4f", v)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    /// 加量（可负，用于撤销）：结果夹在 ≥ 0；非计量习惯原样返回（二值习惯加量无意义）。
    /// 返回是否真的发生了变化（UI 用它决定要不要播动画/震动）。
    static func adding(_ amount: Double, to habit: HabitItem, on date: Date,
                       calendar: Calendar = .current) -> HabitItem {
        guard habit.isMetric, amount != 0 else { return habit }
        let key = dayKey(date, calendar: calendar)
        return settingProgress(progressValue(habit, key: key) + amount, for: habit, on: date,
                               calendar: calendar)
    }

    /// 直接设值（夹在 0…目标量不设上限：允许超额，超额照实显示）
    static func settingProgress(_ value: Double, for habit: HabitItem, on date: Date,
                                calendar: Calendar = .current) -> HabitItem {
        guard habit.isMetric else { return habit }
        var h = habit
        let key = dayKey(date, calendar: calendar)
        let v = max(0, value)
        guard progressValue(habit, key: key) != v || h.progress[key] == nil else { return h }
        if v == 0 { h.progress.removeValue(forKey: key) } else { h.progress[key] = v }
        h.updatedAt = date
        return h
    }

    // MARK: - 打卡 / 取消（幂等）

    /// 打卡：同一天重复打卡**只记一次**（已是该日成员则原样返回）。
    /// ⚠️ 计量习惯不走这里（它的完成度由 `progress` 现算）—— 直接原样返回，
    ///    免得「点一下圆圈」就把计量习惯伪造成已达标（那会污染连续天数）。
    static func checkingIn(_ habit: HabitItem, on date: Date, calendar: Calendar = .current) -> HabitItem {
        guard !habit.isMetric else { return habit }
        var h = habit
        let key = dayKey(date, calendar: calendar)
        guard !h.days.contains(key) else { return h }
        h.days.insert(key)
        h.updatedAt = date
        return h
    }

    /// 取消当天的打卡（仅当天的误点可撤；历史日不可改 —— 与「不可补签」同一口径）。
    /// 计量习惯的「撤销今天」= 把当天累计量清零（不是从 days 里删 —— 它根本不在 days 里）。
    static func undoing(_ habit: HabitItem, on date: Date, calendar: Calendar = .current) -> HabitItem {
        if habit.isMetric { return settingProgress(0, for: habit, on: date, calendar: calendar) }
        var h = habit
        let key = dayKey(date, calendar: calendar)
        guard h.days.contains(key) else { return h }
        h.days.remove(key)
        h.updatedAt = date
        return h
    }

    // MARK: - 连续天数

    /// 从 `day` 当天起往前数的连续打卡天数。`day` 当天未打卡 → **0**（漏一天归零）。
    static func streak(_ habit: HabitItem, endingAt day: Date, calendar: Calendar = .current) -> Int {
        var count = 0
        var cursor = calendar.startOfDay(for: day)
        let done = doneDayKeys(habit)   // 一次取出（计量习惯现算达标日），循环里不再摸 days
        while done.contains(dayKey(cursor, calendar: calendar)) {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }

    /// 展示用「当前连续天数」：今天已打卡 → 从今天数；今天还没打卡 → 从昨天数。
    /// 理由：今天尚未结束，不该在零点一到就把数字显示成 0；一旦真的漏掉**一整天**，
    /// 第二天回看时归零（口径仍是「漏一天归零」，只是不谎报「今天已漏」）。
    static func currentStreak(_ habit: HabitItem, today: Date, calendar: Calendar = .current) -> Int {
        if isDone(habit, on: today, calendar: calendar) {
            return streak(habit, endingAt: today, calendar: calendar)
        }
        guard let yesterday = calendar.date(byAdding: .day, value: -1,
                                           to: calendar.startOfDay(for: today)) else { return 0 }
        return streak(habit, endingAt: yesterday, calendar: calendar)
    }

    /// 历史最长连续天数（与当前连续无关，永不归零）。
    static func bestStreak(_ habit: HabitItem, calendar: Calendar = .current) -> Int {
        let done = doneDayKeys(habit)
        guard !done.isEmpty else { return 0 }
        var best = 0
        for key in done {
            guard let d = date(fromDayKey: key, calendar: calendar) else { continue }
            // 只在每段连续区的**终点**起算（次日也打卡的跳过），避免同一段被重复测量
            if let next = calendar.date(byAdding: .day, value: 1, to: d),
               done.contains(dayKey(next, calendar: calendar)) { continue }
            best = max(best, streak(habit, endingAt: d, calendar: calendar))
        }
        return best
    }

    // MARK: - 曲线点（近 N 天，供打卡曲线用）

    struct DayPoint: Equatable, Sendable {
        let key: String
        let label: String
        let done: Bool
        /// 该日完成度 0…1（二值习惯：done ? 1 : 0；计量习惯：已累计/目标，超额封顶 1）。
        /// 新增字段带默认值 → 老调用点（`[DayPoint]` 的解构/构造）不受影响。
        var value: Double = 0
    }

    /// 近 `days` 个自然日（含今天）升序的打卡点：缺天补 `done=false`（曲线连续，不跳格）。
    static func lastNDays(_ habit: HabitItem, days: Int, today: Date,
                          calendar: Calendar = .current) -> [DayPoint] {
        let n = max(1, days)
        var out: [DayPoint] = []
        let end = calendar.startOfDay(for: today)
        var offset = n - 1
        while offset >= 0 {
            if let d = calendar.date(byAdding: .day, value: -offset, to: end) {
                let key = dayKey(d, calendar: calendar)
                let done = isDoneKey(habit, key: key)
                out.append(DayPoint(key: key,
                                    label: shortLabel(d, calendar: calendar),
                                    done: done,
                                    value: habit.isMetric
                                        ? progressFraction(habit, on: d, calendar: calendar)
                                        : (done ? 1 : 0)))
            }
            offset -= 1
        }
        return out
    }

    /// X 轴标签形态，如 "9/26"
    static func shortLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    // MARK: - 内部

    /// 日键反解为当日正午（避开夏令时切换时的 00:00 不存在问题）。
    static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var comp = DateComponents()
        comp.year = y; comp.month = m; comp.day = d; comp.hour = 12
        return calendar.date(from: comp)
    }
}

// MARK: - v4.0.97 习惯页卡统计（口径收在 Kit）
//
// 用户 2026-10-11「习惯卡片做成上图的样式」—— 页卡要「圆环 + 三行指标」，数字在这里一次算好。
// 🚨 归日 / 近 N 天窗口 / 连续天数**全部收在本文件**：视图层不许自己 Calendar 归日、也不许直接摸
//    `habit.days`（第 72 段真值表有两条源级护栏钉着这点，v4.0.97 落码时挨过一次红）。

/// 习惯页卡统计快照（视图层只渲染，不重算）
struct HabitCardStats: Equatable {
    /// 近 N 天打卡次数
    var done: Int
    /// 近 N 天应打卡次数（习惯数 × 窗口天数）
    var total: Int
    /// 当前最长连续天数（所有习惯取 max）
    var streak: Int
    /// 累计打卡次数最多的习惯标题（无习惯时为空串）
    var topTitle: String

    /// 窗口完成率（0…1；无应打卡次数时为 0）
    var rate: Double { total > 0 ? Double(done) / Double(total) : 0 }

    static let empty = HabitCardStats(done: 0, total: 0, streak: 0, topTitle: "")
}

extension HabitKit {

    /// 近 `days` 天（含今天）的页卡统计。
    /// ⚠️ 空列表分支是**防御性**的：视图侧 `HabitSection.root` 在 `store.habits.isEmpty` 时走
    /// `LifeEmptyStateCard`，根本不渲染这张卡（v4.0.97 审查指出原注释与事实不符）。
    /// ⚠️ 行②与环**同源**（done / total）—— 参考图里 36/42 = 85.7% ≈ 86%，两个数字对得上才不显假。
    static func cardStats(_ habits: [HabitItem], today: Date,
                          days: Int = 7, calendar: Calendar = .current) -> HabitCardStats {
        guard !habits.isEmpty else { return .empty }
        var keys = Set<String>()
        for offset in 0..<days {
            if let d = calendar.date(byAdding: .day, value: -offset, to: today) {
                keys.insert(dayKey(d, calendar: calendar))
            }
        }
        // ⚠️ 必须经 isDoneKey 分流：原实现直读 `days`，计量习惯的达标日不在 days 里 → 统计恒少算。
        let done = habits.reduce(0) { acc, h in acc + keys.filter { isDoneKey(h, key: $0) }.count }
        let streak = habits.map { currentStreak($0, today: today, calendar: calendar) }.max() ?? 0
        let top = habits.max { doneDayCount($0) < doneDayCount($1) }
        return HabitCardStats(done: done, total: habits.count * keys.count,
                              streak: streak, topTitle: top?.title ?? "")
    }

    /// 累计达标天数（条数统计的唯一口径）
    static func doneDayCount(_ habit: HabitItem) -> Int {
        doneDayKeys(habit).count
    }
}

// MARK: - v4.0.104 待做池⑫ 专注计时（番茄钟）
//
// 口径（三条都是踩过就会流血的）：
//   · **不靠逐秒累加**：会话只存「开始时刻 + 计划分钟」，剩余时间一律由 `now` **现算**
//     → 切后台 / 系统挂起 / 杀 App 都不会丢进度（逐秒递减的写法一挂起就停表）。
//   · **归日 = 开始那一刻**的本地日：跨零点的一轮只记给开始那天，绝不劈成两天
//     （否则「23:50 开始 25 分钟」会在两天各记一笔，连续天数被无中生有）。
//   · 记录量 = 实际专注的**整分钟**（下取整）：到点/超时记计划分钟；提前结束记已过分钟，
//     不到 1 分钟 = 0（不记 —— 免得点开即退也留下假进度）。
//
// 本文件仍是纯 Foundation：会话是纯数据 + 纯函数，真值表可直接真编译真跑。
struct FocusSession: Codable, Equatable, Sendable {
    var habitId: String
    var startedAt: Date
    /// 计划专注分钟数（> 0；由 UI 从 HabitKit.focusPresets 或自定义值传入）
    var plannedMinutes: Int

    init(habitId: String, startedAt: Date = Date(), plannedMinutes: Int) {
        self.habitId = habitId
        self.startedAt = startedAt
        self.plannedMinutes = max(1, plannedMinutes)
    }

    /// 结束时刻（会话的唯一派生真源：剩余 / 是否到点都从它算）
    var endsAt: Date {
        startedAt.addingTimeInterval(Double(plannedMinutes) * 60)
    }
}

extension HabitKit {

    /// 预设档（UI 选择器用；25 = 标准番茄）
    static let focusPresets: [Int] = [15, 25, 45, 60]

    /// 剩余秒数（0 = 已到点）。向上取整：剩 0.4s 显示 1 而不是 0，避免「显示 00:00 但还没到点」
    static func focusRemaining(_ s: FocusSession, now: Date) -> Int {
        max(0, Int(ceil(s.endsAt.timeIntervalSince(now))))
    }

    /// 已专注的整分钟（下取整）
    static func focusElapsedMinutes(_ s: FocusSession, now: Date) -> Int {
        max(0, Int(floor(max(0, now.timeIntervalSince(s.startedAt)) / 60)))
    }

    /// 本轮该记多少分钟：到点/超时 → 计划分钟；提前结束 → 已过整分钟（0 = 不记）
    static func focusRecordMinutes(_ s: FocusSession, now: Date) -> Int {
        if now >= s.endsAt { return s.plannedMinutes }
        return min(s.plannedMinutes, focusElapsedMinutes(s, now: now))
    }

    /// 倒计时文案 "24:59"；超过 1 小时 "1:02:03"（预设最长 60 分钟，但不写死上限）
    static func focusClock(_ seconds: Int) -> String {
        let t = max(0, seconds)
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    /// 本轮记录归到哪个日键（= 开始那一刻的本地日）
    static func focusDayKey(_ s: FocusSession, calendar: Calendar = .current) -> String {
        dayKey(s.startedAt, calendar: calendar)
    }
}
