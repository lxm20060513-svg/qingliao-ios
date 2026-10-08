// P3 深度（工作模式「把数字变成判断」）真值表 —— Linux 本地预检用
//
// 编译运行（仓库根目录，权威入口是 check_swift.sh 第 94 段）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_insight \
//       scripts/ql_insight/truth_table_insight.swift \
//       qingliao/Core/WorkbenchInsight.swift qingliao/Core/WorkbenchScope.swift \
//       qingliao/Core/HabitKit.swift qingliao/Core/HomeCardOrder.swift
//   ⚠️ HomeCardOrder.swift 必须有：WorkbenchScope 的快捷卡清单用到它定义的 HomeCardKind。
//   ⚠️ 多文件编译只有 main.swift 允许顶层代码 → 段 94 会先把它复制成 main.swift。
//
// 为什么需要这张表（P3 的四项全是「编译不报、真机才难看」的形态）：
//   ① **阈值与文案必须同源**：界面说「3 天没动」实际按 5 天算，只有肉眼能发现 ——
//      所以阈值、判定、话术全在 `WorkbenchInsight`，表直接编它。
//   ② **不许谎报**：停滞要排除「cron 每天照常汇报」（把汇报算成推进 → 告警永远不响）；
//      断签要说清「今天还没结束不算今天漏了」；失败原因取不到就**这行不出现**（不写「未知错误」）。
//   ③ **生活模式零变更**（用户红线）：四项深度在工作模式才生效，生活模式那四个入口
//      必须原样（结论条不多一行、目标卡不多徽标、习惯卡不多一段、用量卡不多趋势条）。
//   ④ **口径不许散落**：视图只许问「有没有这条提示」，自己再写一遍阈值/日期话术必漏改。
//
// 口径：断言只看**代码**（`code()` 先剥掉整行注释）——注释里为了讲清道理举的例子字面量
// 不该被当成违规；反过来，代码里真出现就是真违规。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var total = 0
func check(_ name: String, _ cond: Bool) {
    total += 1
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

// ⚠️ 多行断言块写成**具名函数**再由 `check("名字", fn())` 调用：
//   顶层代码里「多行闭包当普通实参」与「多行闭包尾随」两种写法在 Swift 6.0.3 上都有解析/推断坑
//   （expected ')' in expression list / cannot call value of non-function type），具名函数最稳。

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉**整行注释**后的源码
func code(_ src: String) -> String {
    src.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

/// 仓库内所有 .swift（相对路径），用于「单一真源 / 接线不许散落」这类全仓断言
func swiftFiles() -> [String] {
    var out: [String] = []
    let root = "qingliao"
    guard let en = FileManager.default.enumerator(atPath: root) else { return out }
    for case let p as String in en where p.hasSuffix(".swift") {
        out.append("\(root)/\(p)")
    }
    return out.sorted()
}

/// 上海时区日历（App 用户所在时区；归日/连续天数口径都按它算）
func shanghaiCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    return c
}

/// 造一个固定时刻（上海时区），避免用例随机器时区漂移
func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
    let cal = shanghaiCalendar()
    var comp = DateComponents()
    comp.year = y; comp.month = mo; comp.day = d; comp.hour = h; comp.minute = mi
    comp.timeZone = cal.timeZone
    return cal.date(from: comp) ?? Date(timeIntervalSince1970: 0)
}

let INSIGHT = "qingliao/Core/WorkbenchInsight.swift"
let insightSrc = code(read(INSIGHT))
let cal = shanghaiCalendar()

// ─────────────────────────────────────────────────────────────────────────────
// A. 条目 13 目标停滞告警
// ─────────────────────────────────────────────────────────────────────────────

func t1() -> Bool {
    let defined = swiftFiles().filter { code(read($0)).contains("static let stallThresholdDays") }
    return defined == [INSIGHT] && WorkbenchInsight.stallThresholdDays == 3
}

let now = at(2026, 10, 8)

check("A2 恰好 3 天没推进（含阈值当天）→ 判停滞，天数 = 3",
      WorkbenchInsight.stallDays(.init(createdAt: at(2026, 10, 5)), now: now, calendar: cal) == 3)
check("A3 只过了 2 天 → 不打扰（nil）",
      WorkbenchInsight.stallDays(.init(createdAt: at(2026, 10, 6)), now: now, calendar: cal) == nil)
check("A4 推进时刻取「最新一次」（创建早但昨天刚动过 → 不判停滞）",
      WorkbenchInsight.stallDays(.init(createdAt: at(2026, 9, 20),
                                       stepDoneAt: [at(2026, 10, 6)]),
                                 now: now, calendar: cal) == nil)
check("A5 手动「现在推进」也算推进（manualPushAt 最晚 → 不判停滞）",
      WorkbenchInsight.stallDays(.init(createdAt: at(2026, 9, 1),
                                       manualPushAt: at(2026, 10, 7)),
                                 now: now, calendar: cal) == nil)
check("A6 已完成 / 已暂停的目标不告警（用户自己按的暂停不算凉了）",
      WorkbenchInsight.stallDays(.init(createdAt: at(2026, 9, 1), finished: true), now: now, calendar: cal) == nil
        && WorkbenchInsight.stallDays(.init(createdAt: at(2026, 9, 1), paused: true), now: now, calendar: cal) == nil)
check("A7 停滞输入里没有任何「汇报」字段（cron 天天汇报不许算成推进）",
      !insightSrc.contains("lastReport") && !insightSrc.contains("lastPushedAt")
        && insightSrc.contains("([manualPushAt] + stepStartedAt.map { Optional($0) } + stepDoneAt.map { Optional($0) })"))
check("A8 跨月 / 跨年按自然日算（12-30 → 次年 01-02 = 3 天，不用秒数除 86400）",
      WorkbenchInsight.dayGap(from: at(2026, 12, 30), to: at(2027, 1, 2), calendar: cal) == 3
        && WorkbenchInsight.dayGap(from: at(2026, 10, 8, 0, 5), to: at(2026, 10, 8, 23, 55), calendar: cal) == 0)
func t1b() -> Bool {
    WorkbenchScope.adopt(.work)
    defer { WorkbenchScope.resetForTesting() }
    let badge = WorkbenchInsight.stallBadge(.init(createdAt: at(2026, 10, 4)), now: now, calendar: cal)
    return badge?.contains("该管了") == true && badge?.contains("4 天") == true
}
check("A9 目标卡徽标：工作模式 + 停滞 → 含「该管了」与实际天数", t1b())
check("A1 停滞阈值 = 3 天（含第 3 天当天），常量只有一处定义", t1())
func t2() -> Bool {
    WorkbenchScope.adopt(.work)
    defer { WorkbenchScope.resetForTesting() }
    return WorkbenchInsight.stallHint(0) == nil && WorkbenchInsight.stallHint(2)?.contains("2 个") == true
}
check("A10 结论条汇总：0 个 → nil（不多那一行）；2 个 → 报个数", t2())
func t3() -> Bool {
    WorkbenchScope.resetForTesting()
    let badge = WorkbenchInsight.stallBadge(.init(createdAt: at(2026, 10, 4)), now: now, calendar: cal)
    return WorkbenchInsight.active == false && badge == nil && WorkbenchInsight.stallHint(2) == nil
}
check("A11 生活模式：停滞徽标与汇总一律不出（生活页一字不动）", t3())

// ─────────────────────────────────────────────────────────────────────────────
// B. 条目 14 习惯断签
// ─────────────────────────────────────────────────────────────────────────────

let today = at(2026, 10, 8)
WorkbenchScope.adopt(.work)   // 断签提示是工作模式的东西（B9 专门验证生活模式不出）

check("B1 「今天还没结束」不算今天漏了：今天打过卡 → 不判断签（哪怕昨天是空档）",
      WorkbenchInsight.habitBreak(dayKeys: ["2026-10-08", "2026-10-01", "2026-10-02"], today: today, calendar: cal) == nil)
check("B2 昨天打过卡 → 连续没断（今天还没打也不提示）",
      WorkbenchInsight.habitBreak(dayKeys: ["2026-10-07", "2026-10-06", "2026-10-05"], today: today, calendar: cal) == nil)
func t4() -> Bool {
    let b = WorkbenchInsight.habitBreak(dayKeys: ["2026-10-01", "2026-10-02", "2026-10-03"], today: today, calendar: cal)
    return b?.gapDays == 4 && b?.best == 3
}
check("B3 真断了：连断 4 天 + 之前连续 3 天 → 天数与「历史最好」都对", t4())
check("B4 从没连过 2 天（只有孤立打卡）→ 谈不上断签，不打扰",
      WorkbenchInsight.habitBreak(dayKeys: ["2026-09-01"], today: today, calendar: cal) == nil)
check("B5 一条打卡都没有 → nil（还没开始养成的习惯不打扰）",
      WorkbenchInsight.habitBreak(dayKeys: [], today: today, calendar: cal) == nil)
check("B6 脏数据（远古连打卡 + 超长空洞）不打转：连断天数有 366 天上限",
      WorkbenchInsight.habitBreak(dayKeys: ["2000-01-01", "2000-01-02"], today: today, calendar: cal)?.gapDays == 366)
check("B7 连续天数口径借用 HabitKit（不在本文件抄第二份算法）",
      insightSrc.contains("HabitKit.bestStreak(HabitItem(title: \"\", days: dayKeys)") && !insightSrc.contains("private static func bestStreak"))
func t5() -> Bool {
    WorkbenchScope.adopt(.work)
    defer { WorkbenchScope.resetForTesting() }
    let t = WorkbenchInsight.habitBreakBadge(dayKeys: ["2026-10-01", "2026-10-02", "2026-10-03"],
                                             today: today, calendar: cal)
    return t?.contains("断了 4 天") == true && t?.contains("连续 3 天") == true
}
check("B8 习惯卡文案：工作模式 + 真断了 → 含「断了 N 天 · 之前连续 M 天」", t5())
func t6() -> Bool {
    WorkbenchScope.resetForTesting()
    let t = WorkbenchInsight.habitBreakBadge(dayKeys: ["2026-10-01", "2026-10-02", "2026-10-03"],
                                             today: today, calendar: cal)
    return t == nil
}
check("B9 生活模式：断签提示不出（习惯卡历史观感不变）", t6())

// ─────────────────────────────────────────────────────────────────────────────
// C. 条目 15 失败原因下钻
// ─────────────────────────────────────────────────────────────────────────────

check("C1 没有原因（nil / 空串 / 全空白）→ nil（那行整体不出现，不写「未知错误」充数）",
      WorkbenchInsight.failureReason(nil) == nil
        && WorkbenchInsight.failureReason("") == nil
        && WorkbenchInsight.failureReason("  \n \t \n ") == nil)
check("C2 多行取第一行非空（后端可能带 fence / 缩进）",
      WorkbenchInsight.failureReason("\n  \n RuntimeError: 连不上模型\n堆栈...") == "RuntimeError: 连不上模型")
func t7() -> Bool {
    let long = String(repeating: "x", count: 200)
    let out = WorkbenchInsight.failureReason(long) ?? ""
    return out.count == WorkbenchInsight.reasonMaxChars + 1 && out.hasSuffix("…")
}
check("C3 超长截断到 120 字 + 省略号（卡片两行放得下）", t7())
func t8() -> Bool {
    let exact = String(repeating: "y", count: WorkbenchInsight.reasonMaxChars)
    return WorkbenchInsight.failureReason(exact) == exact
}
check("C4 正好 120 字不截断（边界不许少一字多一省略号）", t8())
func t9() -> Bool {
    let verdictSrc = code(read("qingliao/Core/WorkbenchVerdict.swift"))
    return verdictSrc.contains("var reason: String? = nil")
        && verdictSrc.contains("let reason = (raw[\"reason\"] as? String)")
        && verdictSrc.contains("isEmpty ? nil : $0")
}
check("C5 昨夜明细带着原因字段 + 解析容错（老后端没这个键 → nil，不假装有原因）", t9())
check("C6 明细界面：有原因才画那行（`if let why = ...`，不是永远占位）",
      code(read("qingliao/Features/Workbench/VerdictBar.swift")).contains("if let why = WorkbenchInsight.failureReason(t.reason)"))

// ─────────────────────────────────────────────────────────────────────────────
// D. 条目 16 用量趋势
// ─────────────────────────────────────────────────────────────────────────────

func days(_ totals: [Int]) -> [WorkbenchInsight.UsageDay] {
    let keys = ["2026-10-02", "2026-10-03", "2026-10-04", "2026-10-05",
                "2026-10-06", "2026-10-07", "2026-10-08"]
    return zip(keys.suffix(totals.count), totals).map { WorkbenchInsight.UsageDay(key: $0, total: $1) }
}

WorkbenchScope.adopt(.work)   // 趋势条是工作模式的东西（D7 专门验证生活模式不出）
check("D1 不足 2 天 → nil（不出趋势条，卡片与历史一致）",
      WorkbenchInsight.usageTrend(days([100])) == nil)
check("D2 全 0（没数据）→ nil（不许画一排空柱子）",
      WorkbenchInsight.usageTrend(days([0, 0, 0, 0, 0, 0, 0])) == nil)
func t10() -> Bool {
    guard let t = WorkbenchInsight.usageTrend(days([-5, 0, 0, 0, 0, 0, 10])) else { return false }
    return t.bars.first?.ratio == 0 && t.bars.count == 7
}
check("D3 负值当 0 看（脏数据不画负高度）", t10())

func t11() -> Bool {
    WorkbenchScope.adopt(.work)
    defer { WorkbenchScope.resetForTesting() }
    guard let t = WorkbenchInsight.usageTrend(days([1, 2, 3, 400, 50, 60, 70])) else { return false }
    let peak = t.bars[3]
    return t.bars.count == 7 && peak.ratio == 1.0 && t.bars.last?.isToday == true
        && t.bars.first?.isToday == false && t.bars[0].ratio == 1.0 / 400.0
}
check("D4 近 7 天：柱子数 = 天数、峰值日比例 = 1、最后一天是「今天」（高亮）", t11())
func t12() -> Bool {
    WorkbenchScope.adopt(.work)
    defer { WorkbenchScope.resetForTesting() }
    let t = WorkbenchInsight.usageTrend(days([1, 2, 3, 4, 5, 6, 7]))
    let labels = t?.bars.map(\.label)
    return labels == ["10/2", "10/3", "10/4", "10/5", "10/6", "10/7", "10/8"]
}
check("D5 顺序保序（后端按日升序下发，图不许自己重排）", t12())
func t13() -> Bool {
    WorkbenchScope.adopt(.work)
    defer { WorkbenchScope.resetForTesting() }
    guard let t = WorkbenchInsight.usageTrend(days([10_000_000, 0, 0, 0, 0, 0, 0])) else { return false }
    return t.note.contains("近 7 天合计") && t.note.contains("10/2") && t.note.contains("10.0M")
        && t.peakLabel.hasPrefix("10/2")
}
check("D6 文案含近 7 天合计与峰值那天（说清「为什么是这个数」）", t13())
func t14() -> Bool {
    WorkbenchScope.resetForTesting()
    return WorkbenchInsight.usageTrend(days([1, 2, 3, 4, 5, 6, 7])) == nil
        && WorkbenchInsight.usageTrendNote(days([1, 2, 3, 4, 5, 6, 7])) == nil
}
check("D7 生活模式：用量卡不出趋势（生活模式的卡片一字不动）", t14())
check("D8 token 文本两档口径（M / G，一位小数）与轴标签一致",
      WorkbenchInsight.mText(353_600_000) == "353.6M"
        && WorkbenchInsight.mText(1_200_000_000) == "1.2G"
        && WorkbenchInsight.axisLabel("2026-10-08") == "10/8"
        && WorkbenchInsight.axisLabel("垃圾键") == "垃圾键")

// ─────────────────────────────────────────────────────────────────────────────
// E. 接线 / 单一真源（P3 的四处改动都在视图层，最容易「改了一处忘了另一处」）
// ─────────────────────────────────────────────────────────────────────────────

let storeSrc = code(read("qingliao/Core/WorkbenchVerdictStore.swift"))
let goalsSrc = code(read("qingliao/Features/Life/GoalsSection.swift"))
let habitSrc = code(read("qingliao/Features/Life/HabitSection.swift"))
let barSrc = code(read("qingliao/Features/Workbench/VerdictBar.swift"))
let usageSrc = code(read("qingliao/Features/Dashboard/UsageCard.swift"))
let modelsSrc = code(read("qingliao/Core/Models.swift"))

func t15() -> Bool {
    guard let local = storeSrc.range(of: "stalledGoalCount = Self.stalledGoalCount"),
          let net = storeSrc.range(of: "/api/agent/tasks/night") else { return false }
    return local.lowerBound < net.lowerBound && storeSrc.contains("WorkbenchInsight.stallDays(")
}
check("E1 停滞后端无关：结论条那行断网也在（本地算，写在网络请求之前）", t15())
func t18() -> Bool {
    let mapper = swiftFiles().filter { code(read($0)).contains("var insightProgress") }
    return mapper == ["qingliao/Features/Life/GoalsSection.swift"]
        && goalsSrc.contains("WorkbenchInsight.stallBadge(goal.insightProgress")
}
check("E2 目标卡：走唯一映射 `insightProgress`（不是自己拼字段）+ 徽标来自 WorkbenchInsight", t18())
check("E3 习惯卡：断签文案来自 WorkbenchInsight（视图里不许有自己的天数话术；原始日键走 HabitKit 透传口）",
      habitSrc.contains("WorkbenchInsight.habitBreakBadge(dayKeys: HabitKit.dayKeys(h)")
        && !habitSrc.contains(".days")
        && !habitSrc.contains("断了 \\(gap"))
func t16() -> Bool {
    let seg = barSrc.range(of: "private var stallRow")
    guard let a = seg?.upperBound else { return false }
    let body = String(barSrc[a...].prefix(1200))
    return body.contains("WorkbenchInsight.stallHint(store.stalledGoalCount)")
        && body.contains("QingliaoRouteHandoff.request(.life)")
}
check("E4 结论条：停滞行读 store 的个数 + 点一下去生活页", t16())
check("E5 用量卡：趋势条来自 WorkbenchInsight（比例/标签/话术都不在视图里算）",
      usageSrc.contains("WorkbenchInsight.usageTrend(")
        && usageSrc.contains("trend.note") && !usageSrc.contains("maxTotal"))
func t17() -> Bool {
    let allowed: Set<String> = ["qingliao/Core/HomeCardOrder.swift",
                                "qingliao/Features/HomeCards.swift",
                                "qingliao/Features/Life/LifeView.swift",
                                "qingliao/Features/Dashboard/DashboardView.swift",
                                "qingliao/Core/WorkbenchOnboard.swift",
                                INSIGHT]
    let hits = Set(swiftFiles().filter { code(read($0)).contains("WorkbenchScope.launched") })
    return hits == allowed
}
check("E6 视图层不自己读口径（`WorkbenchScope.launched` 全仓只五处白名单，含本表钉的口径文件）", t17())
check("E7 Models 解析 daily：坏项跳过（宁可少一天，也不把坏值画成柱子）",
      modelsSrc.contains("let daily: [Daily]") && modelsSrc.contains("daily(j[\"daily\"])")
        && modelsSrc.contains("key.count == 10") && modelsSrc.contains("max(0, n)"))
check("E8 文案/阈值字面量不许外泄（界面说「该管了」的地方只有口径文件一处）",
      swiftFiles().filter { code(read($0)).contains("\"该管了") } == [INSIGHT]
        && swiftFiles().filter { code(read($0)).contains("\"断了 ") } == [INSIGHT])
check("E9 本文件是纯 Foundation（Linux 上能直接编：无 SwiftUI / UIKit 依赖）",
      !insightSrc.contains("import SwiftUI") && !insightSrc.contains("import UIKit")
        && insightSrc.contains("import Foundation"))

print("\n——— 汇总 ———")
print("共 \(total) 条断言 · \(failures) 失败")
WorkbenchScope.resetForTesting()
exit(failures == 0 ? 0 : 1)
