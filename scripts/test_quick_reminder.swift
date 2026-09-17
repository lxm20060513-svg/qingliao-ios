// 一句话本地定时提醒：自然语言时间解析真值表
// 被测逻辑：qingliao/Core/QuickReminder.swift（生产代码，非镜像副本）
//
// 为什么必须逐条断言：时间解析错一格不是「界面难看」，是**提醒不响 / 在错的时间响**——
// 而本机没有 iOS SDK，真机验证一轮很贵（打包 + 安装 + 等时间到）。解析器刻意写成纯函数
// （now + 文本 → 结果），就是为了能在这里把边界一次钉死。
//
// 编译运行（在仓库根目录，工具链见 check_swift.sh 第 8 步）：
//   rm -rf /tmp/ql_reminder_main && mkdir -p /tmp/ql_reminder_main
//   cp scripts/test_quick_reminder.swift /tmp/ql_reminder_main/main.swift
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_quick_reminder \
//       /tmp/ql_reminder_main/main.swift qingliao/Core/QuickReminder.swift
//   /tmp/test_quick_reminder
//
// 固定基准：2026-09-17（周四）14:23 CST —— 周四不是随便挑的：它让「本周已过 / 下周 / 兜底明天」
// 三条分支同时可测（周一测不出「今天已过」，周日测不出「下周一 ≠ 明天」）。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var total = 0

nonisolated(unsafe) var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
cal.locale = Locale(identifier: "zh_CN")

let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 14, minute: 23))!

let stampFormatter: DateFormatter = {
    let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"; return df
}()

func stamp(_ d: Date) -> String {
    stampFormatter.timeZone = cal.timeZone
    stampFormatter.calendar = cal
    return stampFormatter.string(from: d)
}

func check(_ name: String, _ ok: Bool) {
    total += 1
    if ok {
        print("✅ \(name)")
    } else {
        failures += 1
        print("❌ \(name)")
    }
}

/// 期望解析成功，并核对：触发时刻 / 重复规则 / 可读描述 / 剥掉时间后剩下的文案
func expectOK(_ input: String, _ ymd: String, rule: QuickReminderRule = .once,
              summary: String? = nil, hint: String? = nil) {
    total += 1
    switch QuickReminderParser.parseDetailed(input, now: now, calendar: cal) {
    case .failure(let msg):
        failures += 1
        print("❌ 「\(input)」应解析成功，实际失败：\(msg)")
    case .success(let p):
        var bad: [String] = []
        if stamp(p.fireDate) != ymd { bad.append("时刻 \(stamp(p.fireDate)) ≠ \(ymd)") }
        if p.rule != rule { bad.append("规则 \(p.rule.label) ≠ \(rule.label)") }
        if let s = summary, p.summary != s { bad.append("描述「\(p.summary)」≠「\(s)」") }
        if let h = hint, p.subjectHint != h { bad.append("文案「\(p.subjectHint)」≠「\(h)」") }
        if bad.isEmpty {
            let extra = p.subjectHint.isEmpty ? "" : " · 文案「\(p.subjectHint)」"
            print("✅ 「\(input)」→ \(p.summary) · \(p.rule.label)\(extra)")
        } else {
            failures += 1
            print("❌ 「\(input)」→ " + bad.joined(separator: "；"))
        }
    }
}

/// 期望解析失败（且必须给得出可读原因——静默 nil 等同于「用户以为定上了其实没有」）
func expectFail(_ input: String, mustContain keyword: String? = nil) {
    total += 1
    switch QuickReminderParser.parseDetailed(input, now: now, calendar: cal) {
    case .success(let p):
        failures += 1
        print("❌ 「\(input)」应解析失败，实际解析成 \(p.summary)（\(p.rule.label)）")
    case .failure(let msg):
        if let kw = keyword, !msg.contains(kw) {
            failures += 1
            print("❌ 「\(input)」失败原因「\(msg)」里没有「\(kw)」")
        } else {
            print("✅ 「\(input)」→ 拒绝：\(msg)")
        }
    }
}

// MARK: - 0. 相对时间

print("— 相对时间 —")
expectOK("5 分钟后", "09-17 14:28", summary: "5 分钟后（今天 14:28）")
expectOK("半小时后", "09-17 14:53", summary: "30 分钟后（今天 14:53）")
expectOK("一个小时后", "09-17 15:23", summary: "1 小时后（今天 15:23）")
expectOK("90 分钟后", "09-17 15:53", summary: "90 分钟后（今天 15:53）")
expectOK("2 小时后", "09-17 16:23", summary: "2 小时后（今天 16:23）")
expectOK("两小时后", "09-17 16:23")

// MARK: - 1. 定点（今天/明天/后天/大后天/裸时刻）

print("— 定点 —")
expectOK("明天 8 点", "09-18 08:00", summary: "明天 08:00")
expectOK("明天早上 7 点半", "09-18 07:30", summary: "明天 07:30")
expectOK("明早 7 点", "09-18 07:00")
expectOK("明天晚上 9 点", "09-18 21:00", summary: "明天 21:00")
expectOK("明天中午 12 点", "09-18 12:00")
expectOK("今晚 9 点", "09-17 21:00", summary: "今天 21:00")
expectOK("今天晚上 9 点", "09-17 21:00")
expectOK("今晚 12 点", "09-18 00:00")          // 跨零点：今晚 12 点 = 明天 0 点
expectOK("凌晨 12 点", "09-18 00:00")          // 今天 0 点已过 → 明天 0 点
expectOK("后天下午 3 点", "09-19 15:00", summary: "后天 15:00")
expectOK("大后天 9 点", "09-20 09:00")
expectOK("3 天后 9 点", "09-20 09:00")
expectOK("下午 3 点", "09-17 15:00")           // 裸时刻，今天还没到
expectOK("8 点", "09-18 08:00")                // 裸时刻，今天 8 点已过 → 兜底明天
expectOK("早上 7 点", "09-18 07:00")
expectOK("明天", "09-18 09:00", summary: "明天 09:00")   // 只给日子 → 默认早上 9 点

// MARK: - 2. 星期

print("— 星期 —")
expectOK("下周一 9 点", "09-21 09:00", summary: "9月21日 周一 09:00")
expectOK("下周日 10 点", "09-27 10:00")        // 周一为一周之始 → 下周的周日
expectOK("周日 10 点", "09-20 10:00")          // 无「下」→ 最近的将来那个周日
expectOK("周四 20 点", "09-17 20:00")          // 就是今天，只要还没到
expectOK("周四 8 点", "09-24 08:00")           // 今天已过 → 下周四
expectOK("下下周一 8 点", "09-28 08:00")

// MARK: - 3. 重复

print("— 重复 —")
expectOK("每天 7:30", "09-18 07:30", rule: .daily, summary: "每天 07:30")
expectOK("每晚 9 点", "09-17 21:00", rule: .daily, summary: "每天 21:00")
expectOK("每天早上 7 点", "09-18 07:00", rule: .daily)
expectOK("每周一 8 点", "09-21 08:00", rule: .weekly(weekday: 2), summary: "每周一 08:00")
expectOK("每周日 10 点", "09-20 10:00", rule: .weekly(weekday: 1))

// MARK: - 4. 无效输入（宁可拒绝，不可错响）

print("— 无效输入 —")
expectFail("")
expectFail("随便聊聊", mustContain: "没识别到时间")
expectFail("30 分钟前", mustContain: "过去")
expectFail("2 小时前", mustContain: "过去")
expectFail("今天 8 点", mustContain: "已经过了")
expectFail("每天", mustContain: "具体时刻")
expectFail("每周", mustContain: "星期几")
expectFail("每天明天 8 点", mustContain: "不能再指定某一天")
expectFail("25 点", mustContain: "不是有效时间")
expectFail("每天 5 分钟后", mustContain: "不能和")

// MARK: - 5. 文案剥离（一句话里时间 + 内容）

print("— 文案剥离 —")
expectOK("明天 8 点 买菜", "09-18 08:00", hint: "买菜")
expectOK("提醒我 5 分钟后 关火", "09-17 14:28", hint: "关火")
expectOK("记得 晚上 9 点 给妈妈打电话", "09-17 21:00", hint: "给妈妈打电话")
expectOK("每周一 8 点 周会", "09-21 08:00", rule: .weekly(weekday: 2), hint: "周会")
expectOK("明天早上 7 点半 赶火车", "09-18 07:30", hint: "赶火车")

// MARK: - 6. 通知触发分量（UNCalendarNotificationTrigger 只吃这些字段）

print("— 触发分量 —")
if let p = QuickReminderParser.parse("每周一 8 点", now: now, calendar: cal) {
    let r = QuickReminder(text: "周会", fireDate: p.fireDate, rule: p.rule)
    let c = r.triggerComponents
    check("每周一 → weekday 2 / hour 8 / minute 0", c.weekday == 2 && c.hour == 8 && c.minute == 0)
    check("每周一 → 不带年月日（否则只响一次）", c.year == nil && c.day == nil && c.month == nil)
    check("每周一 → repeats = true", r.rule.repeats)
    check("通知标识稳定", r.notificationIdentifier == "quick_reminder_" + r.id)
}
if let p = QuickReminderParser.parse("每天 7:30", now: now, calendar: cal) {
    let c = QuickReminder(text: "吃药", fireDate: p.fireDate, rule: p.rule).triggerComponents
    check("每天 → 只有时分", c.hour == 7 && c.minute == 30 && c.year == nil && c.weekday == nil)
}
if let p = QuickReminderParser.parse("明天 8 点", now: now, calendar: cal) {
    let c = QuickReminder(text: "买菜", fireDate: p.fireDate, rule: p.rule).triggerComponents
    check("一次性 → 年月日时分齐全", c.year == 2026 && c.month == 9 && c.day == 18 && c.hour == 8 && c.minute == 0)
    check("一次性 → repeats = false", !p.rule.repeats)
}

// MARK: - 7. 列表文案 / 过期判定 / Codable 往返

print("— 模型 —")
// createdAt 显式给 now：默认 Date() 带亚秒，而存储用 .iso8601 编码会丢亚秒 → 往返比对必然不等
let repeatItem = QuickReminder(text: "周会", fireDate: now.addingTimeInterval(86400),
                               rule: .weekly(weekday: 2), createdAt: now)
check("重复提醒列表文案", repeatItem.timeText.hasPrefix("每周一 "))
check("重复提醒永不过期", !repeatItem.isExpired(now: now.addingTimeInterval(86400 * 30)))
let onceItem = QuickReminder(text: "吃药", fireDate: now.addingTimeInterval(-60), rule: .once, createdAt: now)
check("一次性过期判定", onceItem.isExpired(now: now))
check("已标记 fired 的不再算过期", !QuickReminder(text: "吃药", fireDate: now.addingTimeInterval(-60), fired: true).isExpired(now: now))

let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
if let data = try? encoder.encode([repeatItem, onceItem]),
   let back = try? decoder.decode([QuickReminder].self, from: data) {
    check("Codable 往返无损", back == [repeatItem, onceItem])
} else {
    check("Codable 往返无损", false)
}
// 旧数据缺键（模拟以后新增字段）→ 必须能解出来，而不是整表清空
if let legacy = #"[{"id":"a","text":"x","fireDate":"2026-09-18T00:00:00Z"}]"#.data(using: .utf8),
   let decoded = try? decoder.decode([QuickReminder].self, from: legacy) {
    check("缺键旧数据容错（rule/createdAt/fired 走默认）",
          decoded.count == 1 && decoded[0].rule == .once && decoded[0].fired == false)
} else {
    check("缺键旧数据容错（rule/createdAt/fired 走默认）", false)
}

// MARK: - 8. 输入清洗

print("— 清洗 —")
check("全角数字/冒号归一", QuickReminderParser.normalize("明天８：３０") == "明天8:30")
check("聊天文案截断", QuickReminderParser.seedText(from: String(repeating: "字", count: 100)).count == 61)
check("聊天文案去换行与 markdown", QuickReminderParser.seedText(from: "**买牛奶**\n和面包") == "买牛奶 和面包")
expectOK("提醒：明天 8 点 买菜", "09-18 08:00", hint: "买菜")
expectOK("　　5 分钟后　", "09-17 14:28")

// MARK: - 汇总

print("")
if failures == 0 {
    print("✅ 全部 \(total) 条断言通过（基准：2026-09-17 周四 14:23 Asia/Shanghai）")
    exit(0)
} else {
    print("❌ \(failures)/\(total) 条断言失败")
    exit(1)
}
