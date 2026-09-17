import Foundation

// MARK: - v3.9.32 一句话本地定时提醒（模型 + 自然语言时间解析）
//
// 背景：轻聊是无 APNs 的侧载 App，此前所有通知都是 `trigger: nil` 的**即时**通知——用户说的「定个
// 提醒」只能靠后端 cron + 前台轮询，App 一杀就没了。本文件引入**系统级** `UNCalendarNotificationTrigger`
// 的那一半：模型 + 自然语言时间解析（纯 Foundation、零网络、零第三方依赖）。
//
// 分层（刻意的）：
//   · 本文件（QuickReminder.swift）= 模型 + 解析器，**纯 Foundation**，可用 `swiftc` 在无 iOS SDK 的
//     机器上编译跑真值表（见 scripts/test_quick_reminder.swift）——时间解析错一格就是「提醒不响/响错点」，
//     必须能在本地回归；
//   · QuickReminderScheduler.swift = 申请权限 + 注册/撤销 UNCalendarNotificationTrigger（依赖 UserNotifications）；
//   · Features/Settings/QuickReminderSheet.swift = 列表 / 新建 / 确认解析结果的 UI。
//
// 解析器契约：`parseDetailed(_:now:calendar:)` 是**纯函数**（同一 now + 同一输入 → 同一结果，不读系统时钟、
// 不写任何状态），方便真值表逐条断言；`parse` 是它的 nil 糖。
//
// 支持的说法（不追求 LLM 级理解，只覆盖日常高频且**可确定**的一档）：
//   相对  5 分钟后 / 半小时后 / 一个半小时后 / 90 分钟后 / 2 小时后
//   定点  明天 8 点 / 明天早上 7 点半 / 今晚 9 点 / 后天下午 3 点 / 下周一 9 点 / 周四 20:00 / 3 天后 9 点
//   重复  每天 7:30 / 每晚 9 点 / 每周一 8 点 / 每隔…（不支持，明确报错）
//   拒绝  30 分钟前（过去）、每天（无具体时间）、本周已过的今天某点
// 解析不出来 → `.failure(可读提示)`，UI 直接显示该提示，不做静默兜底（静默兜底 = 用户以为定上了而其实没有）。

// MARK: - 重复规则

/// 提醒的重复方式（与 UNCalendarNotificationTrigger 的 dateComponents 一一对应）
enum QuickReminderRule: Codable, Equatable, Sendable {
    /// 只响一次
    case once
    /// 每天同一时刻
    case daily
    /// 每周同一星期几 + 同一时刻（weekday 用 Calendar 口径：1 = 周日 … 7 = 周六）
    case weekly(weekday: Int)

    /// 会重复的规则 → trigger 用 repeats: true
    var repeats: Bool { self != .once }

    /// 中文标签（列表里显示）
    var label: String {
        switch self {
        case .once: return "仅一次"
        case .daily: return "每天"
        case .weekly(let weekday): return "每周" + QuickReminderParser.weekdayName(weekday)
        }
    }
}

// MARK: - 提醒条目

struct QuickReminder: Identifiable, Codable, Equatable, Sendable {
    var id: String
    /// 提醒文案（点开通知看到的第一行）
    var text: String
    /// 下一次触发时刻（重复提醒 = 下一次的那一天；仅作展示与兜底，真正定闹钟靠 rule + 时分）
    var fireDate: Date
    var rule: QuickReminderRule
    var createdAt: Date
    /// 一次性提醒已经响过（App 下次启动 reconcile 时置位）
    var fired: Bool

    init(id: String = UUID().uuidString, text: String, fireDate: Date,
         rule: QuickReminderRule = .once, createdAt: Date = Date(), fired: Bool = false) {
        self.id = id
        self.text = text
        self.fireDate = fireDate
        self.rule = rule
        self.createdAt = createdAt
        self.fired = fired
    }

    /// 手写解码（与 MemoItem 同规矩）：以后新增字段必须走 decodeIfPresent + 默认值，
    /// 否则旧数据缺键 → 整表解码失败 → 用户已有提醒全部消失。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        fireDate = try c.decode(Date.self, forKey: .fireDate)
        rule = try c.decodeIfPresent(QuickReminderRule.self, forKey: .rule) ?? .once
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        fired = try c.decodeIfPresent(Bool.self, forKey: .fired) ?? false
    }

    private enum CodingKeys: String, CodingKey { case id, text, fireDate, rule, createdAt, fired }

    /// 通知标识（稳定 → 同一条提醒重复注册会**替换**而不是堆叠）
    var notificationIdentifier: String { "quick_reminder_" + id }

    /// 触发用的日期分量：
    ///   · 一次性 → 年月日时分（系统到这个时刻精确触发，App 被杀/重启都照样响）
    ///   · 每天   → 仅时分（每天同一时刻）
    ///   · 每周   → 星期几 + 时分
    /// 不含 second（缺省 = 该分钟的第一秒），也**不要**塞太多分量——分量越多越容易漏触发。
    var triggerComponents: DateComponents {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: fireDate)
        let minute = cal.component(.minute, from: fireDate)
        switch rule {
        case .once:
            return cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        case .daily:
            return DateComponents(hour: hour, minute: minute)
        case .weekly:
            // ⚠️ 实参顺序必须与 DateComponents 的属性声明顺序一致（hour/minute 在 weekday 之前），
            // 否则 CI 直接报 "argument 'hour' must precede argument 'weekday'"
            return DateComponents(hour: hour, minute: minute, weekday: cal.component(.weekday, from: fireDate))
        }
    }

    /// 通知正文（标题固定为 App 名，正文 = 文案）
    var notificationBody: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "定时提醒" : t
    }

    /// 列表里显示的时间文案：重复 → 「每天 07:30」；一次性 → 「明天 08:00」/「9月21日 周一 09:00」
    var timeText: String {
        switch rule {
        case .once: return QuickReminderParser.dayLabel(fireDate) + " " + QuickReminderParser.hhmm(fireDate)
        case .daily, .weekly: return rule.label + " " + QuickReminderParser.hhmm(fireDate)
        }
    }

    /// 一次性提醒是否已经过期（用于 reconcile 标记 fired）
    func isExpired(now: Date = Date()) -> Bool {
        rule == .once && !fired && fireDate <= now
    }
}

// MARK: - 解析结果

/// 解析成功的产物：触发时刻 + 重复规则 + 可读描述
struct QuickReminderParse: Equatable {
    var fireDate: Date
    var rule: QuickReminderRule
    /// 可读时间描述（UI 用来让用户确认，如「明天 08:00」「每天 07:30」「5 分钟后（今天 14:28）」）
    var summary: String
    /// 从输入里剥掉时间部分后剩下的文字（可能就是提醒内容，如「明天 8 点 买菜」→「买菜」）
    var subjectHint: String
}

enum QuickReminderParseResult: Equatable {
    case success(QuickReminderParse)
    case failure(String)

    var value: QuickReminderParse? {
        if case .success(let p) = self { return p }
        return nil
    }
    var failureMessage: String? {
        if case .failure(let m) = self { return m }
        return nil
    }
}

// MARK: - 解析器

enum QuickReminderParser {

    // MARK: 对外入口

    /// 便捷入口：解析不出来就 nil（UI 若要显示原因用 parseDetailed）
    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> QuickReminderParse? {
        parseDetailed(raw, now: now, calendar: calendar).value
    }

    /// 纯函数：输入（now + 文本）→ 输出（fireDate + 重复规则）或可读失败原因。
    /// 不读 Date()、不碰 UserDefaults、不碰通知中心 —— 真值表逐条断言的就是它。
    static func parseDetailed(_ raw: String, now: Date = Date(),
                              calendar: Calendar = .current) -> QuickReminderParseResult {
        let s = stripNoiseEdges(normalize(raw))
        guard !s.isEmpty else {
            return .failure("说一句时间试试：「5 分钟后」「明天早上 7 点半」「每天 7:30」")
        }
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        var consumed: [NSRange] = []

        func firstMatch(_ pattern: String) -> NSTextCheckingResult? {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            for m in re.matches(in: s, range: full) {
                let overlap = consumed.contains { NSIntersectionRange($0, m.range).length > 0 }
                if !overlap { return m }
            }
            return nil
        }
        func consume(_ r: NSRange) { consumed.append(r) }
        func text(_ r: NSRange) -> String { ns.substring(with: r) }

        // 0) 明确拒掉「过去的时间」——最容易出错的一类：用户打了「30 分钟前」，若被误解析成
        //    「30 分钟后」就会在错误的时间响，比不解析更糟。
        if let m = firstMatch(#"(半|[0-9]{1,3}|[一二两三四五六七八九十]{1,3})\s*个?\s*(分钟|分|小时|钟头)\s*(之前|以前|前)"#) {
            return .failure("「\(text(m.range))」是已经过去的时间，提醒只能定在未来")
        }

        // 1) 重复规则（每天 / 每周X）
        var rule: QuickReminderRule = .once
        var impliedPeriod: DayPeriod? = nil
        if let m = firstMatch(#"每(个)?\s*(周|星期|礼拜)\s*([一二三四五六日天七]|末)?"#) {
            let weekdayGroup = m.range(at: 3)
            guard weekdayGroup.location != NSNotFound else {
                return .failure("「每周」后面要加星期几，例如「每周一 8 点」")
            }
            rule = .weekly(weekday: weekdayNumber(text(weekdayGroup)))
            consume(m.range)
        } else if let m = firstMatch(#"(每天|每日|每一天|每晚|每日晚|每天晚)"#) {
            rule = .daily
            if text(m.range).contains("晚") { impliedPeriod = .evening }
            consume(m.range)
        }

        // 2) 相对时间（N 分钟后 / 半小时后 / N 小时后）——与绝对时间互斥
        let relMinutes = relativeMinutes(firstMatch: firstMatch, text: text, consume: consume)
        if let delta = relMinutes {
            if rule != .once {
                return .failure("「\(rule.label)」不能和「N 分钟后」一起用，选一种说法")
            }
            let fireDate = now.addingTimeInterval(Double(delta) * 60)
            let label = delta % 60 == 0 && delta >= 60 ? "\(delta / 60) 小时后" : "\(delta) 分钟后"
            return .success(QuickReminderParse(
                fireDate: fireDate,
                rule: .once,
                summary: "\(label)（\(dayLabel(fireDate, now: now, calendar: calendar)) \(hhmm(fireDate, calendar: calendar))）",
                subjectHint: leftover(s, consumed: consumed)))
        }

        // 3) 哪一天
        var day = DaySpec.none
        var dayIsExplicit = false
        var crossMidnight = false

        if let m = firstMatch(#"大后天"#) {
            day = .offset(3); dayIsExplicit = true; consume(m.range)
        } else if let m = firstMatch(#"(后天|后日)"#) {
            day = .dayAfter; dayIsExplicit = true; consume(m.range)
        } else if let m = firstMatch(#"(明早|明儿早|明晨)"#) {
            day = .tomorrow; dayIsExplicit = true; impliedPeriod = .morning; consume(m.range)
        } else if let m = firstMatch(#"(明晚|明儿晚上|明儿晚)"#) {
            day = .tomorrow; dayIsExplicit = true; impliedPeriod = .evening; consume(m.range)
        } else if let m = firstMatch(#"(明天|明日|明儿|明个)"#) {
            day = .tomorrow; dayIsExplicit = true; consume(m.range)
        } else if let m = firstMatch(#"(今晚|今儿晚上|今儿晚|今天晚上|今晚上)"#) {
            day = .today; dayIsExplicit = true; impliedPeriod = .evening; consume(m.range)
        } else if let m = firstMatch(#"(今天|今日|今儿|今个)"#) {
            day = .today; dayIsExplicit = true; consume(m.range)
        } else if let m = firstMatch(#"(下下|下|这|本)?\s*(周|星期|礼拜)\s*([一二三四五六日天七]|末)"#) {
            let prefix = m.range(at: 1).location == NSNotFound ? "" : text(m.range(at: 1))
            let weeksAhead = prefix == "下下" ? 2 : (prefix == "下" ? 1 : 0)
            day = .weekday(weekdayNumber(text(m.range(at: 3))), weeksAhead: weeksAhead)
            dayIsExplicit = true
            consume(m.range)
        } else if let m = firstMatch(#"(?<![0-9])([0-9]{1,2}|[一二两三四五六七八九十]{1,3})\s*天\s*(之后|以后|后)"#) {
            guard let n = chineseNumber(text(m.range(at: 1))), n > 0 else {
                return .failure("没看懂「\(text(m.range))」是几天后")
            }
            day = .offset(n); dayIsExplicit = true; consume(m.range)
        }

        // 3b) 重复规则不能再指定某一天（「每天明天 8 点」＝自相矛盾）
        if rule != .once && day != .none {
            return .failure("「\(rule.label)」不能再指定某一天，去掉「\(hhmmLabel(for: day))」或改成一次性")
        }

        // 4) 上午/下午等时段（日词已隐含时段时不重复解析，显式时段优先）
        var period = impliedPeriod
        if let m = firstMatch(#"(凌晨|清晨|一早|早晨|早上|上午|中午|下午|傍晚|晚上|晚间|夜里|深夜)"#) {
            period = DayPeriod(token: text(m.range)) ?? period
            consume(m.range)
        }

        // 5) 时刻（HH:MM 优先，其次「H 点 [M 分 / 半 / 一刻 / 三刻]」）
        var clock: (hour: Int, minute: Int)? = nil
        if let m = firstMatch(#"(?<![0-9])([0-9]{1,2})\s*[:：]\s*([0-9]{1,2})(?![0-9])"#) {
            guard let h = Int(text(m.range(at: 1))), let mi = Int(text(m.range(at: 2))),
                  (0...23).contains(h), (0...59).contains(mi) else {
                return .failure("时间格式看不懂，试试「明天 8 点」「每天 7:30」")
            }
            clock = (h, mi)
            consume(m.range)
        } else if let m = firstMatch(#"(?<![0-9])([0-9]{1,2}|[一二两三四五六七八九十]{1,3})\s*点(?!点)\s*(半|一刻|三刻|整|([0-9]{1,2}|[一二两三四五六七八九十]{1,3})\s*分?)?"#) {
            guard let h = chineseNumber(text(m.range(at: 1))) else {
                return .failure("没看懂「\(text(m.range))」是几点")
            }
            var minute = 0
            // ⚠️ 取 **第 2 组**（整个「半|一刻|三刻|整|N 分」片段），不是嵌套的第 3 组数字——
            // 第 3 组只在写成阿拉伯数字时才参与匹配，「7 点半」会取到 nil（07:00 静默错响）。
            if m.range(at: 2).location != NSNotFound {
                let tail = text(m.range(at: 2)).replacingOccurrences(of: "分", with: "").trimmingCharacters(in: .whitespaces)
                switch tail {
                case "半": minute = 30
                case "一刻": minute = 15
                case "三刻": minute = 45
                case "整": minute = 0
                default:
                    guard let mi = chineseNumber(tail), (0...59).contains(mi) else {
                        return .failure("「\(text(m.range))」的分钟看不懂，试试「7 点半」「7:30」")
                    }
                    minute = mi
                }
            }
            // 有「上午/下午/晚上」等时段时，小时按 12 小时制理解；没时段则必须是 0-23
            if period != nil {
                guard (1...12).contains(h) else { return .failure("「\(text(m.range))」不像十二小时制的说法，试试「20 点」") }
            } else {
                guard (0...23).contains(h) else { return .failure("「\(text(m.range))」不是有效时间") }
            }
            clock = (h, minute)
            consume(m.range)
        }

        // 6) 没有时刻：重复提醒必须给时刻；一次性有明确日子则默认早上 9 点
        var hour = 0, minute = 0
        if let c = clock {
            hour = c.hour; minute = c.minute
            if let p = period {
                let adjusted = p.hour24(hour)
                if p == .evening && hour == 12 { crossMidnight = true }   // 「今晚 12 点」= 明天 0 点
                hour = adjusted
            }
        } else if rule != .once {
            return .failure("「\(rule.label)」需要一个具体时刻，例如「每天 7:30」")
        } else if dayIsExplicit {
            hour = 9; minute = 0
        } else {
            return .failure("没识别到时间，试试「5 分钟后」「明天 8 点」「每天 7:30」")
        }

        // 7) 算出触发日
        let startOfToday = calendar.startOfDay(for: now)
        var baseDay: Date
        switch rule {
        case .daily:
            baseDay = addDays(0, to: startOfToday, calendar: calendar)
        case .weekly(let weekday):
            let todayWeekday = calendar.component(.weekday, from: now)
            let delta = (weekday - todayWeekday + 7) % 7
            baseDay = addDays(delta, to: startOfToday, calendar: calendar)
        case .once:
            switch day {
            case .none: baseDay = startOfToday
            case .today: baseDay = addDays(0, to: startOfToday, calendar: calendar)
            case .tomorrow: baseDay = addDays(1, to: startOfToday, calendar: calendar)
            case .dayAfter: baseDay = addDays(2, to: startOfToday, calendar: calendar)
            case .offset(let n): baseDay = addDays(n, to: startOfToday, calendar: calendar)
            case .weekday(let weekday, let weeksAhead):
                if weeksAhead > 0 {
                    // 「下周X」按中文习惯（周一为一周之始）算：下周 = 下周一那天起的那一周
                    baseDay = nextWeekDay(weekday, weeksAhead: weeksAhead, now: now, calendar: calendar)
                } else {
                    // 「周X」= 最近的将来那个周X（今天还算数 → 时分已过则在第 8 步 +7）
                    let todayWeekday = calendar.component(.weekday, from: now)
                    let delta = (weekday - todayWeekday + 7) % 7
                    baseDay = addDays(delta, to: startOfToday, calendar: calendar)
                }
            }
        }
        if crossMidnight { baseDay = addDays(1, to: baseDay, calendar: calendar) }

        guard var fireDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: baseDay) else {
            return .failure("这个时间算不出来，换个说法试试（如「明天 8 点」）")
        }

        // 8) 已过期 → 按规则前滚或直接拒绝（**不要**把过期时间注册给系统：注册了也永远不会响）
        if fireDate <= now {
            switch rule {
            case .daily:
                fireDate = addDays(1, to: fireDate, calendar: calendar)
            case .weekly:
                fireDate = addDays(7, to: fireDate, calendar: calendar)
            case .once:
                if case .weekday(_, 0) = day {
                    fireDate = addDays(7, to: fireDate, calendar: calendar)   // 「周四 8 点」今天已过 → 下周四
                } else if day == .none {
                    fireDate = addDays(1, to: fireDate, calendar: calendar)   // 裸时刻「8 点」已过 → 明天 8 点
                } else if day == .today {
                    return .failure("今天的 \(hhmm(fireDate, calendar: calendar)) 已经过了，说「明天 …」或「N 小时后」")
                }
            }
        }

        // 9) 汇总
        let summary: String
        switch rule {
        case .daily:
            summary = "每天 \(hhmm(fireDate, calendar: calendar))"
        case .weekly(let weekday):
            summary = "每周\(weekdayName(weekday)) \(hhmm(fireDate, calendar: calendar))"
        case .once:
            summary = "\(dayLabel(fireDate, now: now, calendar: calendar)) \(hhmm(fireDate, calendar: calendar))"
        }
        return .success(QuickReminderParse(fireDate: fireDate, rule: rule, summary: summary,
                                          subjectHint: leftover(s, consumed: consumed)))
    }

    // MARK: 内部：日 / 时段

    /// 「哪一天」的解析结果
    enum DaySpec: Equatable {
        case none
        case today
        case tomorrow
        case dayAfter
        case offset(Int)
        /// 星期几（1 = 周日 … 7 = 周六）+ 往后推几周（0 = 本周/最近的将来，1 = 下周，2 = 下下周）
        case weekday(Int, weeksAhead: Int)
    }

    /// 时段（中文口语的上午/下午/晚上）→ 24 小时制换算
    enum DayPeriod: Equatable {
        case early      // 凌晨 / 清晨 / 夜里 / 深夜
        case morning    // 早上 / 早晨 / 上午 / 一早
        case noon       // 中午
        case afternoon  // 下午 / 傍晚
        case evening    // 晚上 / 晚间

        init?(token: String) {
            switch token {
            case "凌晨", "清晨", "夜里", "深夜": self = .early
            case "早上", "早晨", "上午", "一早": self = .morning
            case "中午": self = .noon
            case "下午", "傍晚": self = .afternoon
            case "晚上", "晚间": self = .evening
            default: return nil
            }
        }

        /// 十二小时制的 h → 24 小时制
        func hour24(_ h: Int) -> Int {
            if h > 12 { return h }              // 已按 24 小时制写（如「晚上 20 点」）
            switch self {
            case .early: return h == 12 ? 0 : h
            case .morning: return h == 12 ? 12 : h
            case .noon: return h == 12 ? 12 : h + 12
            case .afternoon: return h == 12 ? 12 : h + 12
            case .evening: return h == 12 ? 0 : h + 12
            }
        }
    }

    // MARK: 内部：数字 / 星期

    /// 阿拉伯数字或中文数字 → Int（支持 十 / 十一 / 二十 / 两）
    static func chineseNumber(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let n = Int(s) { return n }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3,
                                        "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0
        var pending = 0
        var sawAny = false
        for ch in s {
            if let d = digits[ch] {
                pending = d
                sawAny = true
            } else if ch == "十" {
                total += (pending == 0 ? 1 : pending) * 10
                pending = 0
                sawAny = true
            } else {
                return nil
            }
        }
        return sawAny ? total + pending : nil
    }

    /// 「一/二/…/日/天/七/末」→ Calendar.weekday（1 = 周日 … 7 = 周六）
    static func weekdayNumber(_ token: String) -> Int {
        switch token {
        case "日", "天", "七": return 1
        case "末": return 7
        case "一": return 2
        case "二": return 3
        case "三": return 4
        case "四": return 5
        case "五": return 6
        case "六": return 7
        default: return 2
        }
    }

    /// 星期几的中文单字（1 = 日 … 7 = 六）
    static func weekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "日"
        case 2: return "一"
        case 3: return "二"
        case 4: return "三"
        case 5: return "四"
        case 6: return "五"
        case 7: return "六"
        default: return "一"
        }
    }

    // MARK: 内部：文案 / 时间工具

    private static let hhmmFormatter: DateFormatter = {
        let df = DateFormatter(); df.dateFormat = "HH:mm"; return df
    }()
    private static let monthDayFormatter: DateFormatter = {
        let df = DateFormatter(); df.dateFormat = "M月d日"; return df
    }()

    static func hhmm(_ date: Date, calendar: Calendar = .current) -> String {
        let df = hhmmFormatter
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        return df.string(from: date)
    }

    /// 相对今天的天数差（用于「今天/明天/后天/M月d日」）
    static func dayDiff(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let a = calendar.startOfDay(for: now)
        let b = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let diff = dayDiff(date, now: now, calendar: calendar)
        switch diff {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        default:
            let weekday = calendar.component(.weekday, from: date)
            return "\(monthDayFormatter.string(from: date)) 周\(weekdayName(weekday))"
        }
    }

    private static func addDays(_ n: Int, to date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: n, to: date) ?? date
    }

    /// 「下周X / 下下周X」的日期：以**周一为一周之始**（中文习惯），
    /// 下周 = 下周一那天起的那一周；与设备 locale 的 firstWeekday 无关（避免随语言设置漂移）。
    /// 例：今天周四 → 下周一 = +4 天，下周日 = +10 天。
    static func nextWeekDay(_ targetWeekday: Int, weeksAhead: Int, now: Date, calendar: Calendar) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        let weekdayOfToday = calendar.component(.weekday, from: now)   // 1 = 周日 … 7 = 周六
        let daysSinceMonday = (weekdayOfToday + 5) % 7
        let mondayThisWeek = addDays(-daysSinceMonday, to: startOfToday, calendar: calendar)
        let offsetInWeek = (targetWeekday - 2 + 7) % 7                 // 周一 = 0 … 周日 = 6
        return addDays(7 * weeksAhead + offsetInWeek, to: mondayThisWeek, calendar: calendar)
    }

    private static func hhmmLabel(for day: DaySpec) -> String {
        switch day {
        case .today: return "今天"
        case .tomorrow: return "明天"
        case .dayAfter: return "后天"
        case .offset(let n): return "\(n) 天后"
        case .weekday: return "周X"
        case .none: return ""
        }
    }

    /// 相对时间（分钟数）；命中即消费掉匹配片段，返回 nil 表示没这种说法
    private static func relativeMinutes(firstMatch: (String) -> NSTextCheckingResult?,
                                        text: (NSRange) -> String,
                                        consume: (NSRange) -> Void) -> Int? {
        if let m = firstMatch(#"([0-9]{1,3}|[一二两三四五六七八九十]|半|一个|两)\s*(个)?\s*(小时|钟头)\s*(之后|以后|后)"#) {
            let token = text(m.range(at: 1))
            let hours = token == "半" ? 0.5 : Double(chineseNumber(token) ?? 0)
            guard hours > 0 else { return nil }
            consume(m.range)
            return Int((hours * 60).rounded())
        }
        if let m = firstMatch(#"([0-9]{1,3}|[一二两三四五六七八九十]+|半|一个|两)\s*(分钟|分)\s*(之后|以后|后)"#) {
            let token = text(m.range(at: 1))
            let minutes = token == "半" ? 30 : (chineseNumber(token) ?? 0)
            guard minutes > 0 else { return nil }
            consume(m.range)
            return minutes
        }
        return nil
    }

    /// 去掉消费掉的时间片段后剩下的文字（可能就是提醒内容）
    private static func leftover(_ s: String, consumed: [NSRange]) -> String {
        var units = Array(s.utf16)
        for r in consumed where r.location + r.length <= units.count {
            for i in r.location..<(r.location + r.length) { units[i] = 0x20 }
        }
        let rest = String(decoding: units, as: UTF16.self)
        return stripNoiseEdges(collapseSpaces(rest))
    }

    // MARK: 内部：文本预处理

    /// 全角→半角、去 markdown 标记、压空白（纯文本变换，可测）
    static func normalize(_ raw: String) -> String {
        var s = raw
        let toHalf: [Character: Character] = ["０": "0", "１": "1", "２": "2", "３": "3", "４": "4",
                                              "５": "5", "６": "6", "７": "7", "８": "8", "９": "9",
                                              "：": ":", "　": " ", "\n": " ", "\t": " "]
        s = String(s.map { toHalf[$0] ?? $0 })
        s = s.replacingOccurrences(of: "「", with: " ")
        s = s.replacingOccurrences(of: "」", with: " ")
        s = s.replacingOccurrences(of: "“", with: " ")
        s = s.replacingOccurrences(of: "”", with: " ")
        s = s.replacingOccurrences(of: "，", with: ", ")
        s = s.replacingOccurrences(of: "。", with: " ")
        // 开头的行首标记（markdown / 列表）与「提醒:」这类前缀
        for prefix in ["## ", "# ", "- ", "* ", "> "] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if let colon = s.firstIndex(of: ":"), s[s.startIndex..<colon].trimmingCharacters(in: .whitespaces) == "提醒" {
            s = String(s[s.index(after: colon)...])
        }
        return collapseSpaces(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 连续空白压成一个空格
    static func collapseSpaces(_ raw: String) -> String {
        var out = ""
        var lastWasSpace = false
        for ch in raw {
            let isSpace = ch == " " || ch == "\u{3000}" || ch == "\n" || ch == "\t"
            if isSpace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out
    }

    /// 语气词（「提醒我」「记得」「帮我」…）只去**首尾**——中间出现的可能是要提醒的正事
    /// （如「记得买药」里的「记得」在开头，就该去掉；「考试别忘记带笔」里的不能动）
    static let noiseWords = ["提醒我一下", "帮我提醒一下", "提醒我", "提醒一下", "提醒一声", "帮我提醒",
                             "帮忙提醒", "记得提醒我", "记得提醒", "记得", "叫我一声", "叫我",
                             "到时候提醒", "到时候", "的时候", "麻烦你", "麻烦", "请帮我", "请", "帮我"]

    static func stripNoiseEdges(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var rounds = 0
        var changed = true
        while changed && rounds < 10 {
            changed = false
            rounds += 1
            for w in noiseWords {
                if s.hasPrefix(w) {
                    s = String(s.dropFirst(w.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    break
                }
                if s.hasSuffix(w) {
                    s = String(s.dropLast(w.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    break
                }
            }
        }
        return s
    }

    /// 聊天消息 → 默认提醒文案：去掉换行/markdown 标记，截断到合理长度
    static func seedText(from raw: String, limit: Int = 60) -> String {
        var s = raw.replacingOccurrences(of: "\n", with: " ")
        for mark in ["```", "**", "##", "#", "`", ">"] { s = s.replacingOccurrences(of: mark, with: "") }
        s = collapseSpaces(s).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count <= limit { return s }
        return String(s.prefix(limit)) + "…"
    }
}
