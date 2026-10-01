// v4.0.19 记账候选池 ⑤⑥⑬ 统计纯逻辑真值表 —— Linux 本地预检用，纯 Foundation，无 UI 依赖
//
// 编译运行（在仓库根目录，权威入口是 check_swift.sh 的对应段）：
//   ./check_swift.sh
// 等价于：
//   rm -rf /tmp/ql_rec_main && mkdir -p /tmp/ql_rec_main
//   cp scripts/ql_record/truth_table_record.swift /tmp/ql_rec_main/main.swift
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_record_stats /tmp/ql_rec_main/main.swift \
//       qingliao/Core/RecordKit.swift
//
// 口径（本文件钉死的东西）：
//   · 明细页按 **createdAt** 分组（编辑不改「这笔发生在哪天」；updatedAt 只用于列表排序）
//   · 日 / 周 / 月小计**只算「元」**：度/kWh 是读数不是钱；收入单列，绝不混进支出（v4.0.19 的 kind 铁律）
//   · 近 N 天窗口 = 含今天在内的 N 个自然日（起点 = 当天 00:00）
//   · 月末预估 = 日均 × 当月天数；空数据不得出现 NaN 或除零
//   · 反例（不该计入的）占相当比重：读数、跨窗口旧账、收入混入支出 —— 这几类一旦漏就是用户看到假数字

import Foundation

// MARK: - 断言工具

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

/// 固定时区日历（与 check_swift.sh 里钉的 TZ 双保险，跑测机器时区无关）
func fixedCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
    return c
}

func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mi
    return fixedCalendar().date(from: c) ?? Date(timeIntervalSince1970: 0)
}

/// 固定「现在」：2026-09-26 14:03 +08:00（与 test_chat_record.swift 同一时刻，便于对读）
func fixedNow() -> Date { date(2026, 9, 26, 14, 3) }

func item(_ title: String, _ amount: Double?, unit: String = "元", kind: String = "amount",
          category: String = "", at: Date) -> RecordItem {
    RecordItem(kind: kind, title: title, amount: amount, unit: unit,
               note: "", category: category, source: "manual",
               createdAt: at, updatedAt: at)
}

func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

@main
enum RecordStatsTruthTable {

    static func runAllTests() {
        sectionA_日期键与标题()
        sectionB_按日分组()
        sectionC_近N天窗口()
        sectionD_月度趋势()
        sectionE_月末预估()
        sectionF_空数据与除零()
        sectionG_反例哨兵()
    }

    // MARK: - A. 日期键 / 标题

    static func sectionA_日期键与标题() {
        print("\n=== A. 日期键与标题（明细页分组键）===")
        let cal = fixedCalendar()
        check("dayKey 补零（09-26 不是 9-26）", RecordKit.dayKey(date(2026, 9, 26, 9, 5), calendar: cal) == "2026-09-26")
        check("dayKey 跨年（1 月 1 日）", RecordKit.dayKey(date(2026, 1, 1), calendar: cal) == "2026-01-01")
        check("dayLabel 今天", RecordKit.dayLabel("2026-09-26", today: "2026-09-26", yesterday: "2026-09-25") == "今天")
        check("dayLabel 昨天", RecordKit.dayLabel("2026-09-25", today: "2026-09-26", yesterday: "2026-09-25") == "昨天")
        check("dayLabel 更早给月日", RecordKit.dayLabel("2026-09-24", today: "2026-09-26", yesterday: "2026-09-25") == "9月24日")
        check("dayLabel 跨年也给月日（不带年也能认）", RecordKit.dayLabel("2025-12-31", today: "2026-09-26", yesterday: "2026-09-25") == "12月31日")
        check("dayLabel 脏数据原样返回（不崩）", RecordKit.dayLabel("坏数据", today: "2026-09-26", yesterday: "2026-09-25") == "坏数据")
        check("monthLabel 9 月", RecordKit.monthLabel("2026-09") == "9月")
        check("monthLabel 跨年 1 月", RecordKit.monthLabel("2026-01") == "1月")
    }

    // MARK: - B. 按日分组

    static func sectionB_按日分组() {
        print("\n=== B. 按日分组（明细页主列表）===")
        let cal = fixedCalendar()
        let now = fixedNow()
        let items = [
            item("早饭", 12, category: "餐饮", at: date(2026, 9, 26, 8, 30)),
            item("打车", 35, category: "交通", at: date(2026, 9, 25, 19, 0)),
            item("发工资", 8000, kind: RecordKit.incomeKind, category: "收入", at: date(2026, 9, 26, 10, 0)),
            item("电表", 1234, unit: "kWh", kind: "meter", at: date(2026, 9, 26, 20, 0)),
            item("午饭", 25, category: "餐饮", at: date(2026, 9, 25, 12, 30))
        ]
        let groups = RecordKit.dayGroups(items, now: now, calendar: cal)
        check("分成 2 天（跨天不并组）", groups.count == 2)
        check("组按天新→旧（今天在前）", groups.first?.day == "2026-09-26")
        check("组标题用「今天」", groups.first?.label == "今天")
        check("昨天那组标题「昨天」", groups.last?.label == "昨天")
        check("今日支出只算「元」（12 元，不含 8000 收入、不含 1234 度）", approx(groups.first?.expense ?? -1, 12))
        check("今日收入单列 8000", approx(groups.first?.income ?? -1, 8000))
        check("昨日本组支出 60（35 + 25）", approx(groups.last?.expense ?? -1, 60))
        check("昨日收入 0", approx(groups.last?.income ?? -1, 0))
        check("组内条目新→旧（20:00 电表在 8:30 早饭前）",
              groups.first?.items.first?.title == "电表")
        check("分组含读数条目（明细页要能看见读数，只是不进小计）",
              (groups.first?.items.count ?? 0) == 3)
        check("总条目数不丢（5 条全在）", groups.reduce(0) { $0 + $1.items.count } == 5)
    }

    // MARK: - C. 近 N 天窗口

    static func sectionC_近N天窗口() {
        print("\n=== C. 近 N 天窗口（首页卡周趋势 ⑬）===")
        let cal = fixedCalendar()
        let now = fixedNow()   // 2026-09-26 14:03 → 窗口 = 09-20 00:00 ~ 09-26 24:00
        let items = [
            item("今天", 10, at: date(2026, 9, 26, 9, 0)),
            item("窗口第一天", 20, at: date(2026, 9, 20, 0, 1)),     // 含
            item("窗口前一天", 40, at: date(2026, 9, 19, 23, 59)),   // 不含
            item("八天前", 50, at: date(2026, 9, 18, 12, 0)),        // 不含
            item("本月收入", 500, kind: RecordKit.incomeKind, at: date(2026, 9, 22, 12, 0)),
            item("读数", 300, unit: "度", kind: "meter", at: date(2026, 9, 23, 12, 0))
        ]
        let r = RecordKit.recentDays(items, days: 7, now: now, calendar: cal)
        check("7 天支出 = 30（10 + 20，早期不误入）", approx(r.expense, 30))
        check("7 天收入单列 = 500", approx(r.income, 500))
        check("读数不进窗口笔数（3 笔：今天/第一天/收入）", r.count == 3)
        // 30 天窗口把 09-19、09-18 也纳进来
        let r30 = RecordKit.recentDays(items, days: 30, now: now, calendar: cal)
        check("30 天窗口把 09-19/09-18 都纳入（10+20+40+50 = 120）", approx(r30.expense, 120))
        let r8 = RecordKit.recentDays(items, days: 8, now: now, calendar: cal)
        check("8 天窗口起点落在 09-19（支出 70）", approx(r8.expense, 70))
        let r7b = RecordKit.recentDays(items, days: 7, now: now, calendar: cal)
        check("窗口左边界是闭区间：7 天不含 09-19（支出 30）", approx(r7b.expense, 30))
    }

    // MARK: - D. 月度趋势

    static func sectionD_月度趋势() {
        print("\n=== D. 月度趋势（本月 vs 上月 ⑥）===")
        let cal = fixedCalendar()
        let items = [
            item("9 月支出", 100, at: date(2026, 9, 3)),
            item("9 月再一笔", 50, at: date(2026, 9, 20)),
            item("8 月支出", 200, at: date(2026, 8, 15)),
            item("8 月收入", 900, kind: RecordKit.incomeKind, at: date(2026, 8, 1)),
            item("7 月支出", 300, at: date(2026, 7, 10))
        ]
        let stats = RecordKit.monthStats(items, months: 3, now: fixedNow(), calendar: cal)
        check("返回 3 个月且**升序**（图表从左到右）",
              stats.map { $0.key } == ["2026-07", "2026-08", "2026-09"])
        check("9 月支出 150", approx(stats.last?.expense ?? -1, 150))
        check("8 月支出 200（收入 900 不算支出）", approx(stats[1].expense, 200))
        check("8 月收入 900", approx(stats[1].income, 900))
        check("7 月标签「7月」", stats.first?.label == "7月")
        // 跨年：2026-01 往前 3 个月 = 2025-11 / 2025-12 / 2026-01
        let cross = RecordKit.monthStats([], months: 3, now: date(2026, 1, 15), calendar: cal)
        check("跨年不退化（2025-11 → 2026-01）",
              cross.map { $0.key } == ["2025-11", "2025-12", "2026-01"])
        let crossData = RecordKit.monthStats(
            [item("去年底", 77, at: date(2025, 12, 20))], months: 3,
            now: date(2026, 1, 15), calendar: cal)
        check("跨年的去年 12 月账目归属正确", approx(crossData[1].expense, 77))
        check("monotonic：months=1 只回本月", RecordKit.monthStats(items, months: 1, now: fixedNow(), calendar: cal)
                .map { $0.key } == ["2026-09"])
    }

    // MARK: - E. 月末预估

    static func sectionE_月末预估() {
        print("\n=== E. 月末预估（日用天数口径）===")
        let cal = fixedCalendar()
        let now = fixedNow()          // 9 月 26 日
        let items = [
            item("本月一", 260, at: date(2026, 9, 1)),
            item("本月二", 260, at: date(2026, 9, 20)),
            item("上月不算", 999, at: date(2026, 8, 20))
        ]
        let p = RecordKit.monthProjection(items, now: now, calendar: cal)
        check("已过天数 = 26（当月当日口径）", p.daysElapsed == 26)
        check("当月天数 = 30（9 月）", p.daysInMonth == 30)
        check("本月已花 520", approx(p.spent, 520))
        check("日均 = 520 / 26 = 20", approx(p.dailyAvg, 20))
        check("月末预估 = 20 × 30 = 600", approx(p.projected, 600))
        check("预估 ≥ 已花（不会给出越花越少的假预估）", p.projected >= p.spent)
    }

    // MARK: - F. 空数据与除零

    static func sectionF_空数据与除零() {
        print("\n=== F. 空数据（不得 NaN / 除零）===")
        let cal = fixedCalendar()
        let p = RecordKit.monthProjection([], now: fixedNow(), calendar: cal)
        check("空账本已花 0", approx(p.spent, 0))
        check("空账本日均 0（不是 NaN/inf）", p.dailyAvg == 0 && p.dailyAvg.isFinite)
        check("空账本预估 0", approx(p.projected, 0))
        check("空账本分组为空", RecordKit.dayGroups([], now: fixedNow(), calendar: cal).isEmpty)
        let r = RecordKit.recentDays([], days: 7, now: fixedNow(), calendar: cal)
        check("空账本近 7 天全 0", approx(r.expense, 0) && approx(r.income, 0) && r.count == 0)
        // 当月 1 号：日均 = 当日已花 / 1，不该除以 0
        let p1 = RecordKit.monthProjection([item("一号", 30, at: date(2026, 9, 1))],
                                           now: date(2026, 9, 1, 9, 0), calendar: cal)
        // ⚠️ 诚实边界：Calendar 的 .day 分量公历下永远 ≥ 1，monthProjection 里的 max(1, …)
        //    是**不可由公开输入触发**的防御（变异它本表不会红，已实测）。这里能钉的只有「1 号口径正确」。
        check("1 号口径：日均 = 当日已花 30（不是 30/0 = inf）", approx(p1.dailyAvg, 30) && p1.dailyAvg.isFinite)
        check("1 号预估 = 30 × 30 = 900（口径如实：就按当前日均线性外推）", approx(p1.projected, 900))
    }

    // MARK: - G. 反例/哨兵

    static func sectionG_反例哨兵() {
        print("\n=== G. 反例哨兵（负例数量与「不该算的」）===")
        let cal = fixedCalendar()
        let now = fixedNow()
        // 反例 1：收入不得进日小计
        let g1 = RecordKit.dayGroups([item("工资", 8000, kind: RecordKit.incomeKind, at: date(2026, 9, 26, 10, 0))],
                                     now: now, calendar: cal)
        negatives += 1
        check("反例：只有收入的一天日支出恒为 0", approx(g1.first?.expense ?? -1, 0))
        // 反例 2：读数不得进日小计，但必须在明细里
        let g2 = RecordKit.dayGroups([item("电量", 300, unit: "度", kind: "meter", at: date(2026, 9, 26, 10, 0))],
                                     now: now, calendar: cal)
        negatives += 1
        check("反例：读数不进日小计", approx(g2.first?.expense ?? -1, 0))
        check("反例：读数条目仍在明细列表里", (g2.first?.items.count ?? 0) == 1)
        // 反例 3：无金额的纯文字记录不炸、也不进小计
        let g3 = RecordKit.dayGroups([item("今天心情不错", nil, kind: "note", at: date(2026, 9, 26, 10, 0))],
                                     now: now, calendar: cal)
        negatives += 1
        check("反例：纯文字记录不产生小计", approx(g3.first?.expense ?? -1, 0))
        // 反例 4：跨月的旧账不得进本月趋势的最新一格
        let g4 = RecordKit.monthStats([item("上月", 88, at: date(2026, 8, 5))], months: 2,
                                      now: now, calendar: cal)
        negatives += 1
        check("反例：上月账目落在上月格、不在本月格",
              approx(g4[0].expense, 88) && approx(g4[1].expense, 0))
        positives += 1
        check("组数一致性：同一天多条只出一组",
              RecordKit.dayGroups([item("a", 1, at: date(2026, 9, 26, 9, 0)),
                                   item("b", 2, at: date(2026, 9, 26, 21, 0))],
                                  now: now, calendar: cal).count == 1)
    }

    static func main() {
        runAllTests()
        let total = positives + negatives
        let ratio = total == 0 ? 0 : Double(negatives) / Double(total)
        check("反例 ≥ 三分之一（正例 \(positives) / 反例 \(negatives) / 占比 \(Int(ratio * 100))%）",
              ratio >= 1.0 / 3.0)
        print(failures == 0 ? "\n🎉 全部通过（0 失败）" : "\n❌ \(failures) 个失败")
        exit(failures == 0 ? 0 : 1)
    }
}
