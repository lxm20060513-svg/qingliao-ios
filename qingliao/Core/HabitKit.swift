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

struct HabitItem: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// 打卡日期集合，键 = 本地日 "yyyy-MM-dd"（去重天然成立：同一自然日只有一个键）。
    var days: Set<String>

    init(id: String = UUID().uuidString, title: String,
         createdAt: Date = Date(), updatedAt: Date? = nil, days: Set<String> = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.days = days
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, days
    }

    var sortDate: Date { updatedAt }
}

enum HabitKit {

    // MARK: - 归日

    /// 本地日键（"yyyy-MM-dd"）。口径唯一真源：所有「今天是不是打了卡」「哪几天打了卡」
    /// 都走这里，避免各处自己 format 出不一致的键。
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 某个自然日是否已打卡
    static func isDone(_ habit: HabitItem, on date: Date, calendar: Calendar = .current) -> Bool {
        habit.days.contains(dayKey(date, calendar: calendar))
    }

    /// 习惯已打卡的日键集合。
    /// 为什么要这个透传口：视图层不许直接摸 `habit.days`（口径收在本文件 —— 预检 ql_habit 段
    /// 有「HabitSection 不直接操作 habit.days」的源级断言），要原始日键就只能走这里。
    static func dayKeys(_ habit: HabitItem) -> Set<String> { habit.days }

    // MARK: - 打卡 / 取消（幂等）

    /// 打卡：同一天重复打卡**只记一次**（已是该日成员则原样返回）。
    static func checkingIn(_ habit: HabitItem, on date: Date, calendar: Calendar = .current) -> HabitItem {
        var h = habit
        let key = dayKey(date, calendar: calendar)
        guard !h.days.contains(key) else { return h }
        h.days.insert(key)
        h.updatedAt = date
        return h
    }

    /// 取消当天的打卡（仅当天的误点可撤；历史日不可改 —— 与「不可补签」同一口径）。
    static func undoing(_ habit: HabitItem, on date: Date, calendar: Calendar = .current) -> HabitItem {
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
        while habit.days.contains(dayKey(cursor, calendar: calendar)) {
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
        guard !habit.days.isEmpty else { return 0 }
        var best = 0
        for key in habit.days {
            guard let d = date(fromDayKey: key, calendar: calendar) else { continue }
            // 只在每段连续区的**终点**起算（次日也打卡的跳过），避免同一段被重复测量
            if let next = calendar.date(byAdding: .day, value: 1, to: d),
               habit.days.contains(dayKey(next, calendar: calendar)) { continue }
            best = max(best, streak(habit, endingAt: d, calendar: calendar))
        }
        return best
    }

    // MARK: - 曲线点（近 N 天，供打卡曲线用）

    struct DayPoint: Equatable, Sendable {
        let key: String
        let label: String
        let done: Bool
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
                out.append(DayPoint(key: key,
                                    label: shortLabel(d, calendar: calendar),
                                    done: habit.days.contains(key)))
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
