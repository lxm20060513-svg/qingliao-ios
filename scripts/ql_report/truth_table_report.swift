// v4.0.45 待做池④ 生活数据可视化报表真值表 —— Linux 本地预检用
//
// 编译运行（在仓库根目录，权威入口是 check_swift.sh 第 71 段）：
//   ./check_swift.sh
// 等价于：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_report \
//       scripts/ql_report/truth_table_report.swift qingliao/Core/RecordKit.swift
//
// 本表钉死的口径（都是「漏一条 → 用户看到假数字/坏图」的点）：
//   · 逐日序列：近 days 个自然日（含今天）升序、缺天补 0（折线连续），按 createdAt 归日
//   · 只算「元」支出：收入（kind=income）、读数（unit≠元）、无金额条目一律不进折线
//   · 窗口边界：窗口外旧账 / 未来日期脏数据不得进序列
//   · 就绪门槛：有支出的**不同日期数** ≥ reportMinDays(7) 才画趋势；否则引导卡（不出空图）
//   · 同源对拍：窗口逐日合计 == 本月合计 == 分类占比合计（图表数字必须与列表同源）
//   · 零值/单点不崩：空账本、单点、days=0 都不许除零、不许画假趋势
//   · 源级：报表视图必须调 RecordKit 的纯函数喂数，**禁视图内二次聚合**；折线(addLine)与
//     环图(addArc)都必须在；入口已接线。
//
// A–D 段真编译真跑 qingliao/Core/RecordKit.swift（与实现同一份文件 → 没有表/实现漂移的洞）；
// E 段用剥注释的源级断言钉接线（UI 测不到，靠源码形态兜底）。

import Foundation

// MARK: - 断言工具

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

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

func fixedNow() -> Date { date(2026, 9, 26, 14, 3) }

func item(_ title: String, _ amount: Double?, unit: String = "元", kind: String = "amount",
          category: String = "", at: Date) -> RecordItem {
    RecordItem(kind: kind, title: title, amount: amount, unit: unit,
               note: "", category: category, source: "manual",
               createdAt: at, updatedAt: at)
}

func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

/// 剥行注释（源级断言必须看「代码形态」：注释里写了不等于接线了 —— 本仓假绿的老坑）
func stripComments(_ s: String) -> String {
    s.components(separatedBy: "\n").map { String($0.components(separatedBy: "//")[0]) }
        .joined(separator: "\n")
}

@main
enum ReportTruthTable {

    static func runAllTests() {
        let cal = fixedCalendar()
        let now = fixedNow()
        sectionA_逐日序列(cal, now)
        sectionB_零值与单点(cal, now)
        sectionC_就绪门槛(cal, now)
        sectionD_反例(cal, now)
        sectionE_同源对拍(cal, now)
        sectionF_源级接线()
    }

    // MARK: - A. 逐日序列（14 天窗口）

    static func sectionA_逐日序列(_ cal: Calendar, _ now: Date) {
        print("\n=== A. 逐日序列（折线数据源）===")
        let recs = [
            item("买菜", 10, at: date(2026, 9, 20)),
            item("午饭", 20, at: date(2026, 9, 24)),
            item("咖啡", 5, at: date(2026, 9, 24)),                      // 同日第二笔
            item("打车", 3, at: date(2026, 9, 26)),                      // 今天
            item("工资", 100, kind: "income", at: date(2026, 9, 25)),    // 收入：不进支出
            item("电表", 123, unit: "度", kind: "meter", at: date(2026, 9, 26)), // 读数：不进
            item("旧账", 99, at: date(2026, 9, 1)),                      // 窗口外
        ]
        let s = RecordKit.dailySeries(recs, days: 14, now: now, calendar: cal)
        positives += 1
        check("序列长度 = days(14)", s.count == 14)
        positives += 1
        check("升序首日 = 09-13（含今天共 14 天）", s.first?.key == "2026-09-13")
        positives += 1
        check("末位 = 今天 09-26", s.last?.key == "2026-09-26")
        positives += 1
        check("键严格递增（升序 = 图表从左到右）", zip(s, s.dropFirst()).allSatisfy { $0.0.key < $0.1.key })
        func point(_ k: String) -> Double { s.first { $0.key == k }?.expense ?? -1 }
        positives += 1
        check("同日多笔相加（09-24 = 25）", approx(point("2026-09-24"), 25))
        positives += 1
        check("今天只有支出计入（读数 123 不计）", approx(point("2026-09-26"), 3))
        positives += 1
        check("收入不进支出（09-25 = 0）", approx(point("2026-09-25"), 0))
        positives += 1
        check("窗口外旧账不出现（09-01 不在序列）", !s.contains { $0.key == "2026-09-01" })
        positives += 1
        check("序列总额 = 38（收入/读数/旧账全排除）", approx(s.reduce(0) { $0 + $1.expense }, 38))
        positives += 1
        check("X 轴标签形态 m/d", s.first?.label == "9/13")
        positives += 1
        check("shortDayLabel 非法输入原样返回（不崩）", RecordKit.shortDayLabel("空白") == "空白")
    }

    // MARK: - B. 零值与单点

    static func sectionB_零值与单点(_ cal: Calendar, _ now: Date) {
        print("\n=== B. 零值 / 单点 / 边界（不许除零、不许假趋势）===")
        let empty = RecordKit.dailySeries([], days: 14, now: now, calendar: cal)
        positives += 1
        check("空账本 → 14 个零点（不是空数组，折线要连续）", empty.count == 14 && empty.allSatisfy { $0.expense == 0 })
        positives += 1
        check("空账本峰值 0（不许拿它做除数）", RecordKit.seriesPeak(empty) == 0)
        positives += 1
        check("空账本有支出天数 0、不就绪", RecordKit.daysWithExpense(empty) == 0 && !RecordKit.trendReady(empty))
        let one = RecordKit.dailySeries([item("一笔", 8, at: date(2026, 9, 26))], days: 14, now: now, calendar: cal)
        positives += 1
        check("单点：只有一个非零点", RecordKit.daysWithExpense(one) == 1)
        positives += 1
        check("单点：天数不够不就绪（不画假趋势）", !RecordKit.trendReady(one))
        positives += 1
        check("单点：峰值 = 该笔金额", approx(RecordKit.seriesPeak(one), 8))
        positives += 1
        check("days=1 只出 1 个点", RecordKit.dailySeries([], days: 1, now: now, calendar: cal).count == 1)
        positives += 1
        check("days=0 被夹到 ≥1（不返回空序列）", RecordKit.dailySeries([], days: 0, now: now, calendar: cal).count == 1)
    }

    // MARK: - C. 就绪门槛

    static func sectionC_就绪门槛(_ cal: Calendar, _ now: Date) {
        print("\n=== C. 就绪门槛（记满 7 天才出图）===")
        func daysOf(_ n: Int, _ amount: Double = 1) -> [RecordItem] {
            (0..<n).map { i in
                item("d\(i)", amount, at: cal.date(byAdding: .day, value: -i, to: now) ?? now)
            }
        }
        let six = RecordKit.dailySeries(daysOf(6), days: 14, now: now, calendar: cal)
        positives += 1
        check("6 天有支出 → 不就绪（不出空图）", RecordKit.daysWithExpense(six) == 6 && !RecordKit.trendReady(six))
        let seven = RecordKit.dailySeries(daysOf(7), days: 14, now: now, calendar: cal)
        positives += 1
        check("7 天有支出 → 就绪（门槛 7）", RecordKit.trendReady(seven))
        positives += 1
        check("reportMinDays 常量 = 7", RecordKit.reportMinDays == 7)
        let sameDay = RecordKit.dailySeries([item("a", 1, at: now), item("b", 2, at: now)], days: 14, now: now, calendar: cal)
        positives += 1
        check("同一天两笔只算 1 天（不是 2 天）", RecordKit.daysWithExpense(sameDay) == 1)
        positives += 1
        check("minDays 可覆盖（6 天用 minDays:6 → 就绪）", RecordKit.trendReady(six, minDays: 6))
    }

    // MARK: - D. 反例（不该计入的）

    static func sectionD_反例(_ cal: Calendar, _ now: Date) {
        print("\n=== D. 反例（漏一条就是用户看到假数字）===")
        negatives += 1
        check("反例：收入（kind=income）不进逐日支出",
              RecordKit.dailySeries([item("工资", 100, kind: "income", at: now)],
                                    days: 14, now: now, calendar: cal).allSatisfy { $0.expense == 0 })
        negatives += 1
        check("反例：读数（unit=度）不进支出",
              RecordKit.dailySeries([item("电表", 50, unit: "度", kind: "meter", at: now)],
                                    days: 14, now: now, calendar: cal).allSatisfy { $0.expense == 0 })
        negatives += 1
        check("反例：无金额条目不计（amount=nil）",
              RecordKit.dailySeries([item("备注", nil, kind: "note", at: now)],
                                    days: 14, now: now, calendar: cal).allSatisfy { $0.expense == 0 })
        negatives += 1
        check("反例：未来日期脏数据不进窗口",
              RecordKit.dailySeries([item("未来", 9, at: date(2026, 9, 30))],
                                    days: 14, now: now, calendar: cal).allSatisfy { $0.expense == 0 })
        negatives += 1
        check("反例：跨月旧账（8 月）不进窗口",
              !RecordKit.dailySeries([item("旧", 9, at: date(2026, 8, 30))],
                                     days: 14, now: now, calendar: cal).contains { $0.expense > 0 })
        negatives += 1
        check("反例：负数金额不得把当日支出抵小（口径：原样求和，不做符号修正）",
              approx(RecordKit.dailySeries([item("退", -5, at: now), item("买", 20, at: now)],
                                           days: 14, now: now, calendar: cal).last!.expense, 15))
        negatives += 1
        check("反例：窗口外一天（09-12）不进窗口",
              RecordKit.dailySeries([item("边界外", 9, at: date(2026, 9, 12))],
                                    days: 14, now: now, calendar: cal).allSatisfy { $0.expense == 0 })
        negatives += 1
        check("反例：金额为 0 的条目不构成「有支出的一天」",
              RecordKit.daysWithExpense(RecordKit.dailySeries([item("零", 0, at: now)],
                                                              days: 14, now: now, calendar: cal)) == 0)
        negatives += 1
        check("反例：seriesPeak 取单日最大值而非总和（两天 3、4 → 4，不是 7）",
              approx(RecordKit.seriesPeak(RecordKit.dailySeries([item("a", 3, at: date(2026, 9, 25)),
                                                                 item("b", 4, at: date(2026, 9, 26))],
                                                                days: 14, now: now, calendar: cal)), 4))
        negatives += 1
        check("反例：单位「块」未归一时不进「元」口径（报表只认已归一的单位）",
              RecordKit.dailySeries([item("未归一", 9, unit: "块", at: now)],
                                    days: 14, now: now, calendar: cal).allSatisfy { $0.expense == 0 })
        negatives += 1
        check("反例：kWh 读数不进支出",
              RecordKit.dailySeries([item("电表", 88, unit: "kWh", kind: "meter", at: now)],
                                    days: 14, now: now, calendar: cal).allSatisfy { $0.expense == 0 })
        negatives += 1
        check("反例：未来月份的账不进窗口（10 月）",
              RecordKit.dailySeries([item("未来月", 9, at: date(2026, 10, 1))],
                                    days: 14, now: now, calendar: cal).allSatisfy { $0.expense == 0 })
        negatives += 1
        check("反例：就绪只看天数不看金额（6 天各 1 亿仍不就绪）",
              !RecordKit.trendReady(RecordKit.dailySeries(
                  (0..<6).map { item("m\($0)", 100_000_000,
                                     at: cal.date(byAdding: .day, value: -$0, to: now) ?? now) },
                  days: 14, now: now, calendar: cal)))
    }

    // MARK: - E. 同源对拍（图表数字 == 列表数字）

    static func sectionE_同源对拍(_ cal: Calendar, _ now: Date) {
        print("\n=== E. 同源对拍（折线/环图 == 本月合计）===")
        let same = [item("a", 12, at: date(2026, 9, 25)), item("b", 8, at: date(2026, 9, 26))]
        let seriesSum = RecordKit.dailySeries(same, days: 14, now: now, calendar: cal).reduce(0) { $0 + $1.expense }
        let monthSum = RecordKit.monthTotal(same, now: now, calendar: cal).amount
        positives += 1
        check("窗口内逐日合计 == 本月合计（都与列表同源）", approx(seriesSum, monthSum) && approx(monthSum, 20))
        let catSum = RecordKit.categoryTotals(same, now: now, calendar: cal).reduce(0) { $0 + $1.amount }
        positives += 1
        check("分类占比合计 == 本月已花（环图中心额 == 汇总卡，用 projection.spent 成立）", approx(catSum, monthSum))
    }

    // MARK: - F. 源级接线（UI 测不到，靠源码形态兜底）

    static func sectionF_源级接线() {
        print("\n=== F. 源级接线（剥注释后看代码形态）===")
        // 路径写成**字面量**直接喂 contentsOfFile：check_guard_coverage.py 会正则扫它做「断链」检查。
        let reportSrc = (try? String(contentsOfFile: "qingliao/Features/Life/RecordReportSheet.swift",
                                     encoding: .utf8)) ?? ""
        let reportCode = stripComments(reportSrc)
        let sectionCode = stripComments(
            (try? String(contentsOfFile: "qingliao/Features/Life/RecordSection.swift",
                          encoding: .utf8)) ?? "")
        positives += 1
        check("源级：读得到报表页源码（读不到=护栏空转）", !reportSrc.isEmpty)
        positives += 1
        check("源级：折线数据来自 RecordKit.dailySeries", reportCode.contains("RecordKit.dailySeries("))
        positives += 1
        check("源级：环图数据来自 RecordKit.categoryTotals", reportCode.contains("RecordKit.categoryTotals("))
        positives += 1
        check("源级：汇总来自 RecordKit.monthProjection", reportCode.contains("RecordKit.monthProjection("))
        positives += 1
        check("源级：就绪判据来自 RecordKit.trendReady + daysWithExpense",
              reportCode.contains("RecordKit.trendReady(") && reportCode.contains("RecordKit.daysWithExpense("))
        positives += 1
        check("源级：门槛引用 RecordKit.reportMinDays（不写死 7）", reportCode.contains("RecordKit.reportMinDays"))
        // v4.0.47 复审：环图判据必须是「有 >0 金额」，不能是 totals 非空 ——
        // amount == 0 的条目（固定支出照抄 f.amount）也会进 totals → 全零时会画出灰圈空图，
        // 与口径「数据不足出引导卡、不生成空图」相悖。
        positives += 1
        check("源级：环图判据 = 有 >0 的金额（全零走引导卡，不出空图）",
              reportCode.contains("!totals.contains(where: { $0.amount > 0 })")
              && !reportCode.contains("if totals.isEmpty {"))
        positives += 1
        check("源级：配色复用 RecordCategoryColor.tint，不自造第二套调色板",
              reportCode.contains("RecordCategoryColor.tint(") && !reportCode.contains("static let palette"))
        positives += 1
        check("源级：禁视图内二次聚合（无 reduce / 无对 store.records 过滤求和）",
              !reportCode.contains(".reduce(") && !reportCode.contains("store.records.filter"))
        positives += 1
        check("源级：折线与环图都真在画（addLine + addArc 都在）",
              reportCode.contains("addLine(") && reportCode.contains("addArc("))
        positives += 1
        check("源级：入口已接线（.sheet(isPresented: $showReport) { RecordReportSheet() }）",
              sectionCode.contains(".sheet(isPresented: $showReport) { RecordReportSheet() }"))
        positives += 1
        check("源级：入口可访问标签在（accessibilityLabel(\"数据报表\")）",
              sectionCode.contains("accessibilityLabel(\"数据报表\")"))
    }

    // MARK: - 主入口

    static func main() {
        runAllTests()
        let total = positives + negatives
        let ratio = total == 0 ? 0 : Double(negatives) / Double(total)
        check("反例 ≥ 四分之一（正例 \(positives) / 反例 \(negatives) / 占比 \(Int(ratio * 100))%）",
              ratio >= 0.25)
        print(failures == 0 ? "\n🎉 全部通过（0 失败）" : "\n❌ \(failures) 个失败")
        // 结论行：必须以「/ 0 失败」结尾（check_swift.sh 第 71 段的双闸门判据之一，
        // 与第 69/70 段同款收紧写法 —— 防「10 失败 / 20 失败」子串误命中）。
        print("结果：正例 \(positives) / 反例 \(negatives) / \(failures) 失败")
        exit(failures == 0 ? 0 : 1)
    }
}
