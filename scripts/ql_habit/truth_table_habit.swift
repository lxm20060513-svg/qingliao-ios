// v4.0.46 待做池⑤ 习惯打卡真值表 —— Linux 本地预检用
//
// 编译运行（在仓库根目录，权威入口是 check_swift.sh 第 72 段）：
//   ./check_swift.sh
// 等价于：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_habit \
//       scripts/ql_habit/truth_table_habit.swift qingliao/Core/HabitKit.swift
//
// 本表钉死的口径（漏一条 → 用户看到假连续天数 / 打卡被吞 / 跨日算错）：
//   · 同一天重复打卡只记一次（幂等）
//   · 归日按**本地日历**（23:59 与次日 00:01 分属两天；跨时区不错算）
//   · 连续天数漏一天归零；当前连续 = 今天已打卡从今天数、今天未打卡从昨天数（不谎报）
//   · bestStreak 保留历史、空习惯不崩
//   · lastNDays 近 N 天升序、缺天补 false、含今天
//   · 用户拍板口径：**每天一次 + 不可补签** → HabitKit 代码里不得出现任何补签路径
//   · 源级：生活页栏目已接线、Store 走 SyncedStore FIFO 写链、视图不越权直接改 days
//
// A–C 段真编译真跑 qingliao/Core/HabitKit.swift（与实现同一份文件 → 没有表/实现漂移的洞）；
// D 段为反例 / 边界；E 段用剥注释的源级断言钉接线与护栏。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

func fixedCalendar(_ tz: String = "Asia/Shanghai") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz) ?? TimeZone(secondsFromGMT: 0)!
    return c
}

func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0,
          _ cal: Calendar = fixedCalendar()) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mi
    return cal.date(from: c) ?? Date(timeIntervalSince1970: 0)
}

/// 剥行注释（源级断言必须看「代码形态」：注释里写了不等于接线了 —— 本仓假绿的老坑）
func stripComments(_ s: String) -> String {
    s.components(separatedBy: "\n").map { String($0.components(separatedBy: "//")[0]) }
        .joined(separator: "\n")
}

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

@main
enum HabitTruthTable {

    static func main() {
        let cal = fixedCalendar()
        sectionA_打卡与归日(cal)
        sectionB_连续天数(cal)
        sectionC_边界与曲线(cal)
        sectionD_反例()
        sectionE_源级接线()
        let total = positives + negatives
        let ratio = total == 0 ? 0 : Double(negatives) / Double(total)
        check("反例 ≥ 四分之一（正例 \(positives) / 反例 \(negatives) / 占比 \(Int(ratio * 100))%）",
              ratio >= 0.25)
        print(failures == 0 ? "\n🎉 全部通过（0 失败）" : "\n❌ \(failures) 个失败")
        print("结果：正例 \(positives) / 反例 \(negatives) / \(failures) 失败")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - A. 打卡与归日

    static func sectionA_打卡与归日(_ cal: Calendar) {
        print("\n=== A. 打卡（幂等）/ 归日（本地日）===")

        let d1 = date(2026, 9, 24, 9, 0, cal)
        var h = HabitItem(title: "跑步")
        positives += 1
        check("初始未打卡", !HabitKit.isDone(h, on: d1, calendar: cal))

        h = HabitKit.checkingIn(h, on: d1, calendar: cal)
        positives += 1
        check("打卡后 isDone 为真", HabitKit.isDone(h, on: d1, calendar: cal))
        positives += 1
        check("打卡集合记 1 天", h.days.count == 1)

        // 幂等：同一天再打一次
        let again = HabitKit.checkingIn(h, on: date(2026, 9, 24, 23, 59, cal), calendar: cal)
        positives += 1
        check("同一天重复打卡只记一次（幂等）", again.days.count == 1)
        negatives += 1
        check("同一自然日内不同时刻不产生第二个键", again.days == h.days)

        h = HabitKit.undoing(h, on: d1, calendar: cal)
        positives += 1
        check("取消当天打卡 → 集合清空", h.days.isEmpty)

        // 归日：本地日切分（东八区）
        let beforeMidnight = date(2026, 9, 26, 23, 59, cal)
        let afterMidnight = date(2026, 9, 27, 0, 1, cal)
        positives += 1
        check("23:59 归到 09-26", HabitKit.dayKey(beforeMidnight, calendar: cal) == "2026-09-26")
        positives += 1
        check("次日 00:01 归到 09-27", HabitKit.dayKey(afterMidnight, calendar: cal) == "2026-09-27")
        negatives += 1
        check("跨午夜两刻不归同一天", HabitKit.dayKey(beforeMidnight, calendar: cal)
              != HabitKit.dayKey(afterMidnight, calendar: cal))

        // 同一瞬间、不同时区 → 不同本地日（证明按传入日历归日，不是写死 UTC）
        let instant = date(2026, 9, 27, 0, 30, cal)      // 上海 09-27 00:30 = UTC 09-26 16:30
        let utc = fixedCalendar("UTC")
        positives += 1
        check("同一瞬间在本地是 09-27", HabitKit.dayKey(instant, calendar: cal) == "2026-09-27")
        negatives += 1
        check("同一瞬间在 UTC 是 09-26（归日随日历，不是写死）",
              HabitKit.dayKey(instant, calendar: utc) == "2026-09-26")
    }

    // MARK: - B. 连续天数

    static func sectionB_连续天数(_ cal: Calendar) {
        print("\n=== B. 连续天数（漏一天归零）===")

        let a = date(2026, 9, 22, 12, 0, cal)
        let b = date(2026, 9, 23, 12, 0, cal)
        let c = date(2026, 9, 24, 12, 0, cal)
        let e = date(2026, 9, 26, 12, 0, cal)      // 09-25 缺失

        let h = HabitItem(title: "读书", days: [
            HabitKit.dayKey(a, calendar: cal),
            HabitKit.dayKey(b, calendar: cal),
            HabitKit.dayKey(c, calendar: cal),
            HabitKit.dayKey(e, calendar: cal),
        ])

        positives += 1
        check("连续 3 天（22/23/24）", HabitKit.streak(h, endingAt: c, calendar: cal) == 3)
        positives += 1
        check("锚点当天未打卡 → 0（漏一天归零）", HabitKit.streak(h, endingAt: date(2026, 9, 25, 12, 0, cal), calendar: cal) == 0)
        positives += 1
        check("断点后单日 → 1", HabitKit.streak(h, endingAt: e, calendar: cal) == 1)
        positives += 1
        check("bestStreak 保留历史最长 = 3", HabitKit.bestStreak(h, calendar: cal) == 3)
        negatives += 1
        check("bestStreak 不把断点后单独一天算成延续（≠4）", HabitKit.bestStreak(h, calendar: cal) != 4)
        negatives += 1
        check("streak 不跨断点累加（ending 09-26 = 1 而非 4）", HabitKit.streak(h, endingAt: e, calendar: cal) != 4)

        // currentStreak：今天已打卡 → 从今天数
        positives += 1
        check("currentStreak 今天已打卡 = 1", HabitKit.currentStreak(h, today: e, calendar: cal) == 1)
        // currentStreak：今天未打卡 → 从昨天数（不谎报 0）
        positives += 1
        check("currentStreak 今天未打卡 → 从昨天数 = 1",
              HabitKit.currentStreak(h, today: date(2026, 9, 27, 8, 0, cal), calendar: cal) == 1)
        // 真漏一整天后归零
        positives += 1
        check("连漏两天 → currentStreak 归零",
              HabitKit.currentStreak(h, today: date(2026, 9, 28, 8, 0, cal), calendar: cal) == 0)
    }

    // MARK: - C. 边界与曲线

    static func sectionC_边界与曲线(_ cal: Calendar) {
        print("\n=== C. 空习惯 / 曲线边界 ===")

        let empty = HabitItem(title: "空")
        positives += 1
        check("空习惯 streak = 0（不崩）", HabitKit.streak(empty, endingAt: date(2026, 9, 26, 12, 0, cal), calendar: cal) == 0)
        positives += 1
        check("空习惯 bestStreak = 0", HabitKit.bestStreak(empty, calendar: cal) == 0)
        positives += 1
        check("空习惯 currentStreak = 0", HabitKit.currentStreak(empty, today: date(2026, 9, 26, 12, 0, cal), calendar: cal) == 0)

        let today = date(2026, 9, 26, 12, 0, cal)
        var h = HabitItem(title: "冥想")
        h = HabitKit.checkingIn(h, on: date(2026, 9, 20, 7, 0, cal), calendar: cal)   // 窗口内
        h = HabitKit.checkingIn(h, on: today, calendar: cal)                          // 今天
        h = HabitKit.checkingIn(h, on: date(2026, 9, 10, 7, 0, cal), calendar: cal)   // 窗口外

        let pts = HabitKit.lastNDays(h, days: 7, today: today, calendar: cal)
        positives += 1
        check("近 7 天 → 7 个点", pts.count == 7)
        positives += 1
        check("升序首日 = 09-20", pts.first?.key == "2026-09-20")
        positives += 1
        check("末位 = 今天 09-26", pts.last?.key == "2026-09-26")
        positives += 1
        check("键严格递增", zip(pts, pts.dropFirst()).allSatisfy { $0.0.key < $0.1.key })
        positives += 1
        check("缺天补 false（09-21 … 未打卡）",
              pts.first { $0.key == "2026-09-21" }?.done == false)
        positives += 1
        check("打卡日 done = true（09-20）", pts.first { $0.key == "2026-09-20" }?.done == true)
        negatives += 1
        check("窗口外旧打卡（09-10）不进序列", !pts.contains { $0.key == "2026-09-10" })
        positives += 1
        check("标签形态 m/d", pts.first?.label == "9/20")
        negatives += 1
        check("lastNDays 不多不少正好 N 点（≠8）",
              HabitKit.lastNDays(h, days: 7, today: today, calendar: cal).count != 8)
        negatives += 1
        check("缺天不误标 done（09-25 未打卡）",
              pts.first { $0.key == "2026-09-25" }?.done != true)
        negatives += 1
        check("窗口首日不越界（≠ 09-19）", pts.first?.key != "2026-09-19")
        positives += 1
        check("days 参数 0 → 夹到至少 1 个点（不崩）",
              HabitKit.lastNDays(h, days: 0, today: today, calendar: cal).count == 1)
        positives += 1
        check("dayKey 反解可用（2026-09-20 → 当月 20 日）",
              (HabitKit.date(fromDayKey: "2026-09-20", calendar: cal).map {
                  cal.component(.day, from: $0) } ) == 20)
    }

    // MARK: - D. 反例

    static func sectionD_反例() {
        print("\n=== D. 反例 / 编解码（坏数据不放大）===")
        negatives += 1
        check("非法日键反解 → nil（不造日期）", HabitKit.date(fromDayKey: "2026-09") == nil)
        negatives += 1
        check("乱码日键反解 → nil", HabitKit.date(fromDayKey: "hello") == nil)

        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601

        // 往返：days 存得住
        let h = HabitItem(title: "往返", days: ["2026-09-24", "2026-09-26"])
        if let data = try? e.encode([h]),
           let back = try? d.decode([HabitItem].self, from: data), let first = back.first {
            positives += 1
            check("编解码往返：打卡集合原样保留", first.days == h.days)
        } else {
            check("编解码往返：打卡集合原样保留", false)
        }

        // 旧数据缺 days 键 → decodeIfPresent 兜底为空集合（不解崩）
        let legacy = "[{\"id\":\"x\",\"title\":\"旧\",\"createdAt\":\"2026-09-24T00:00:00Z\"}]"
        if let legacyBack = try? d.decode([HabitItem].self, from: Data(legacy.utf8)),
           let first = legacyBack.first {
            negatives += 1
            check("旧数据缺 days 键 → 解码为未打卡集合", first.days.isEmpty)
        } else {
            check("旧数据缺 days 键 → 解码为未打卡集合", false)
        }
    }

    // MARK: - E. 源级接线

    static func sectionE_源级接线() {
        print("\n=== E. 源级接线（剥注释后看代码形态）===")

        let kitSrc = read("qingliao/Core/HabitKit.swift")
        let kitCode = stripComments(kitSrc)
        let storeCode = stripComments(read("qingliao/Core/HabitStore.swift"))
        let sectionCode = stripComments(read("qingliao/Features/Life/HabitSection.swift"))
        let lifeViewCode = stripComments(read("qingliao/Features/Life/LifeView.swift"))
        let lifeSectionCode = stripComments(read("qingliao/Features/Life/LifeSection.swift"))
        let appCode = stripComments(read("qingliao/QingliaoApp.swift"))

        positives += 1
        check("源级：读得到 HabitKit（读不到=护栏空转）", !kitCode.isEmpty)
        positives += 1
        check("源级：读得到 HabitSection", !sectionCode.isEmpty)

        // 用户拍板：每天一次 + 不可补签 → 代码里不得有任何补签路径
        negatives += 1
        check("口径：HabitKit 无补签实现（不可补签）",
              !kitCode.contains("补签") && !kitCode.contains("backfill") && !kitCode.contains("makeup"))
        negatives += 1
        check("口径：HabitStore 无补签入口",
              !storeCode.contains("补签") && !storeCode.contains("backfill"))

        // 单一真源：视图不越权重算连续天数 / 不直接改 days
        positives += 1
        check("源级：HabitSection 走 HabitKit.currentStreak（不自己算）",
              sectionCode.contains("HabitKit.currentStreak("))
        positives += 1
        check("源级：详情曲线走 HabitKit.lastNDays", sectionCode.contains("HabitKit.lastNDays("))
        // v4.0.47 复审：跨午夜显示刷新 —— 「今天」必须是被观察的依赖，否则 App 常驻跨天
        // 一直显示昨天的「今日已打卡 · 连续 N 天」（数据没错、显示骗人）。
        positives += 1
        check("源级：HabitSection 把「今天」提成 @State（跨天刷新的依赖）",
              sectionCode.contains("@State private var today = Date()"))
        positives += 1
        check("源级：打卡/连续天数都传这个 today（渲染读它才会重算）",
              sectionCode.contains("store.isDone(h, on: today)")
              && sectionCode.contains("HabitKit.currentStreak(h, today: today)"))
        negatives += 1
        check("源级：没有漏网的「现取 Date()」（漏一处就有一半显示不刷新）",
              !sectionCode.contains("today: Date())") && !sectionCode.contains("store.isDone(h)"))
        positives += 1
        check("源级：跨天与回前台两条触发都在",
              sectionCode.contains(".onReceive(dayTicker)") && sectionCode.contains(".onChange(of: scenePhase)"))
        negatives += 1
        check("源级：HabitSection 不直接操作 habit.days（口径收在 HabitKit）",
              !sectionCode.contains(".days"))
        negatives += 1
        check("源级：HabitSection 无第二套天数算法（不含 while 循环）",
              !sectionCode.contains("while "))
        negatives += 1
        check("源级：HabitSection 不自行按 Calendar 归日（口径收在 HabitKit）",
              !sectionCode.contains("calendar.date(byAdding"))
        positives += 1
        // v4.0.78：打卡入口从 View 的 `store` 属性（@State store = HabitStore.shared）迁到**文件级**
        // toggleHabit（宿主菜单 + 浮层列表共用一份，自由函数里拿不到 View 的属性）→ 判据放宽成
        // 「store. / HabitStore.shared.」两形态都认；强度不变：仍必须真的走 checkIn/undo（不许自己改 days）。
        // 迁移自证：把 checkIn 调用删掉 → 本项必须转红。
        let callsStore: (String) -> Bool = { m in
            sectionCode.contains("store." + m + "(") || sectionCode.contains("HabitStore.shared." + m + "(")
        }
        check("源级：HabitSection 走 store.checkIn / store.undo",
              callsStore("checkIn") && callsStore("undo"))
        positives += 1
        check("源级：HabitSection 用 HabitStore.shared",
              sectionCode.contains("HabitStore.shared"))
        positives += 1
        check("源级：打卡圆有可访问标签", sectionCode.contains("accessibilityLabel(done"))

        // 生活页几何单一来源
        positives += 1
        check("源级：页级单卡走 MemoCardMetrics.minHeight（单一几何来源）",
              sectionCode.contains("MemoCardMetrics.minHeight"))
        positives += 1
        check("源级：空态走 LifeEmptyStateCard",
              sectionCode.contains("LifeEmptyStateCard("))
        positives += 1
        check("源级：标题行走 LifeSectionHeader",
              sectionCode.contains("LifeSectionHeader("))

        // Store 走 SyncedStore FIFO 写链 + NAS 文件双写
        positives += 1
        check("源级：HabitStore 落 habits.json", storeCode.contains("fileName = \"habits.json\""))
        positives += 1
        check("源级：HabitStore FIFO 写链（await prev.value）",
              storeCode.contains("await prev.value"))
        positives += 1
        check("源级：HabitStore 走 SyncedStore.writeToFile / readRemote",
              storeCode.contains("SyncedStore.writeToFile(") && storeCode.contains("SyncedStore.readRemote("))
        positives += 1
        check("源级：HabitStore 有 loadFromServer 并集合并",
              storeCode.contains("func loadFromServer() async") && storeCode.contains("byID["))

        // 生活页栏目接线
        positives += 1
        check("源级：LifeSection 新增 .habit",
              lifeSectionCode.contains("case .habit"))
        positives += 1
        check("源级：LifeView switch 接线 .habit → HabitSection()",
              lifeViewCode.contains("case .habit: HabitSection()"))
        positives += 1
        check("源级：App 启动 attach HabitStore",
              appCode.contains("HabitStore.shared.attach(auth: auth)"))
        negatives += 1
        check("源级：App 只 attach 一次 HabitStore（不重复挂）",
              appCode.components(separatedBy: "HabitStore.shared.attach").count == 2)
    }
}
