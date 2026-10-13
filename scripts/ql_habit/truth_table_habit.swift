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
        sectionF_计量维度(cal)
        sectionG_专注计时(cal)
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
        // v4.0.97：页级单卡由**行卡**换成 **HabitProgressCard**（圆环 + 三行指标，用户 2026-10-11
        // 「习惯卡片做成上图的样式」），行卡只剩「全部列表」一处消费者 → `compact` 形参与
        // MemoCardMetrics 兜底一并撤掉。页卡几何改由 HabitProgressCard 自己定（比待办/目标卡的环大一档）。
        check("源级：页级单卡 = HabitProgressCard（圆环 + 三行指标），不再走行卡几何",
              sectionCode.contains("HabitProgressCard(")
              && sectionCode.contains("HabitProgressRing(progress: stats.rate)")
              && !sectionCode.contains("HabitRowCard(h: top"))
        positives += 1
        check("源级：空态走 LifeEmptyStateCard",
              sectionCode.contains("LifeEmptyStateCard("))
        positives += 1
        check("源级：标题行走 LifeSectionHeader",
              sectionCode.contains("LifeSectionHeader("))

        // ── v4.0.99 页卡「点击不弹窗，改成跟待办一样的卡片展开显示」（用户 2026-10-12）──
        // 旧口径（点卡 = 开「全部习惯」浮层 / 单条直接进详情，见已退役的 openTop）作废：
        // 点卡 = 就地展开；浮层入口挪到展开区底部那行 —— 不许丢。
        positives += 1
        check("源级：页卡有就地展开态 @State（habitExpanded）",
              sectionCode.contains("@State private var habitExpanded = false"))
        positives += 1
        check("源级：点卡 = 就地展开/收起（withAnimation(Motion.cardExpand) + toggle + 展开区挂在卡下）",
              sectionCode.contains("withAnimation(Motion.cardExpand) { habitExpanded.toggle() }")
              && sectionCode.contains("if habitExpanded {"))
        negatives += 1
        check("源级：点卡不再走裸 onTapGesture / 直接开浮层（openTop 口径已退役）",
              !sectionCode.contains(".onTapGesture { openTop("))
        positives += 1
        // v4.0.104：展开区调用点多了尾部形参 onOpenFocus（专注计时入口）→ 断言改成
        // 「有 checkAsButton: false 的 HabitRowCard 调用」+「展开区走 tapHabit 分流」，
        // 免得以后每次加尾部形参都要改这条锚（断言钉的是形态，不是那一整行的逐字文本）。
        check("源级：展开区逐条复用 HabitRowCard（checkAsButton: false —— 整行已是 Button）",
              sectionCode.contains("private func habitExpandList(")
              && sectionCode.contains("HabitRowCard(h: h, today: today, checkAsButton: false,")
              && sectionCode.contains("tapHabit(h, today: today)"))
        positives += 1
        check("源级：展开区底部保留「全部习惯」浮层入口（openAllHabits → glass.showAll = true）",
              sectionCode.contains("private func openAllHabits()")
              && sectionCode.contains("glass.showAll = true"))
        negatives += 1
        check("源级：删空后复位展开态（与记录/目标两张卡同款，否则新建第一条以已展开形态凭空出现）",
              sectionCode.contains("if empty { habitExpanded = false }"))

        // ── v4.0.97 行为断言（审查：新统计此前只有源级字符串断言，口径改坏 CI 仍绿）──
        // 真跑 HabitKit.cardStats，钉死：窗口 = 含今天的连续 7 个日键、取整、streak 取 max、空态。
        let v97Cal = fixedCalendar()
        let v97Today = date(2026, 10, 11, 12, 0, v97Cal)
        // 6 个习惯，各自「昨天起往前 6 天」打过卡（今天故意不打 → 顺带验「今天未打卡从昨天数」）
        var v97Six: [HabitItem] = []
        for i in 0..<6 {
            var h = HabitItem(title: "习惯\(i)")
            for off in 1...6 {
                if let d = v97Cal.date(byAdding: .day, value: -off, to: v97Today) {
                    h.days.insert(HabitKit.dayKey(d, calendar: v97Cal))
                }
            }
            v97Six.append(h)
        }
        let v97Stats = HabitKit.cardStats(v97Six, today: v97Today, days: 7, calendar: v97Cal)
        check("行为：近 7 天窗口 = 6 习惯 × 7 天 = 42（不重不漏）",
              v97Stats.total == 42)
        positives += 1
        check("行为：42 里命中 36 → 完成率取整 86%（与行②同源，参考图那个数）",
              v97Stats.done == 36 && Int((v97Stats.rate * 100).rounded()) == 86)
        positives += 1
        check("行为：环与行②恒同源（rate == done / total）",
              v97Stats.rate == Double(v97Stats.done) / Double(v97Stats.total))
        positives += 1
        check("行为：今天未打卡 → 连续天数从昨天起算（6，不谎报 7）",
              v97Stats.streak == 6)
        positives += 1
        // 窗口外的打卡不许计进来：再往前推一天（第 7 天前）补一次打卡 → done 不动
        var v97Out = v97Six
        if let d7 = v97Cal.date(byAdding: .day, value: -7, to: v97Today) {
            v97Out[0].days.insert(HabitKit.dayKey(d7, calendar: v97Cal))
        }
        check("行为：窗口外（第 7 天前）的打卡不计入 —— 窗口边界不多不少",
              HabitKit.cardStats(v97Out, today: v97Today, days: 7, calendar: v97Cal).done == 36)
        negatives += 1
        check("行为：空列表 → .empty（rate 0，不 NaN 不崩）",
              HabitKit.cardStats([], today: v97Today, calendar: v97Cal) == .empty)
        negatives += 1

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

    // MARK: - F. 计量维度（v4.0.104 待做池⑫）

    static func sectionF_计量维度(_ cal: Calendar) {
        print("\n=== F. 计量维度（量/时长 · 老数据零迁移 · 不污染连续天数）===")
        let today = date(2026, 10, 13, 12, 0, cal)

        // ── 老数据零迁移：手写一份「只有 v4.0.46 字段」的 JSON（ISO8601 日期）真解码 ──
        let legacyJSON = """
        [{"id":"old-1","title":"旧习惯","createdAt":"2026-10-01T03:00:00Z",
          "updatedAt":"2026-10-12T03:00:00Z","days":["2026-10-12"]}]
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let legacy = (try? dec.decode([HabitItem].self, from: Data(legacyJSON.utf8))) ?? []
        positives += 1
        check("迁移：旧 JSON（无 metric/target/unit/progress）能解码，条数 1", legacy.count == 1)
        positives += 1
        check("迁移：缺键回落 = 二值（metric nil / target nil / progress 空 / isMetric false）",
              legacy.first?.metric == nil && legacy.first?.target == nil
              && (legacy.first?.progress.isEmpty ?? false) && (legacy.first?.isMetric == false))
        positives += 1
        check("迁移：旧数据的打卡判定与打卡动作逐字不变",
              HabitKit.isDone(legacy[0], on: date(2026, 10, 12, 12, 0, cal), calendar: cal)
              && HabitKit.checkingIn(legacy[0], on: today, calendar: cal).days.contains("2026-10-13"))
        negatives += 1
        check("迁移反例：旧数据不被误判成计量（isMetric 必须 false）", legacy[0].isMetric == false)

        // ── 计量习惯：达标才算完成；超额照实 ──
        var water = HabitItem(title: "喝水", metric: .amount, target: 8, unit: "杯")
        water = HabitKit.settingProgress(3, for: water, on: today, calendar: cal)
        positives += 1
        check("计量：3/8 未达标 → isDone false", !HabitKit.isDone(water, on: today, calendar: cal))
        water = HabitKit.settingProgress(8, for: water, on: today, calendar: cal)
        positives += 1
        check("计量：到 8/8 → isDone true", HabitKit.isDone(water, on: today, calendar: cal))
        water = HabitKit.settingProgress(9, for: water, on: today, calendar: cal)
        positives += 1
        check("计量：超额 9/8 仍算达标、进度比例封顶 1",
              HabitKit.isDone(water, on: today, calendar: cal)
              && HabitKit.progressFraction(water, on: today, calendar: cal) == 1)
        positives += 1
        check("计量：单一真源 —— 达标后 days 里不被冗余写（仍为空）", water.days.isEmpty)

        // ── 未填目标 = 不是计量（防「永远判不成完成」静默污染统计）──
        let noTarget = HabitItem(title: "半成品", metric: .amount, target: 0, unit: "次")
        let halfBuilt = HabitItem(title: "没填目标", metric: .duration, target: nil)
        negatives += 1
        check("反例：metric 有但 target=0/nil → isMetric false（不参与达标判定）",
              !noTarget.isMetric && !halfBuilt.isMetric)
        negatives += 1
        check("反例：二值习惯加量 = 无操作（不会被量维度改坏）",
              HabitKit.adding(5, to: HabitItem(title: "跑步", days: []), on: today, calendar: cal).progress.isEmpty)
        positives += 1
        check("兜底：metric 有但目标无效 → 退回二值形态，打卡圈照常可用（不至于变成永远完不成的习惯）",
              HabitKit.checkingIn(noTarget, on: today, calendar: cal).days.contains("2026-10-13"))

        // ── 打卡圈对计量习惯无效（否则点一下就伪造达标）──
        negatives += 1
        check("反例：计量习惯 checkingIn 原样返回（不伪造达标、不写 days）",
              HabitKit.checkingIn(water, on: today, calendar: cal).days.isEmpty)

        // ── 加量 / 撤销 / 夹值 ──
        var run = HabitItem(title: "阅读", metric: .amount, target: 30, unit: "页")
        run = HabitKit.adding(10, to: run, on: today, calendar: cal)
        run = HabitKit.adding(10, to: run, on: today, calendar: cal)
        positives += 1
        check("计量：累加 10+10 → 20/30，未达标", HabitKit.dayProgress(run, on: today, calendar: cal) == 20
              && !HabitKit.isDone(run, on: today, calendar: cal))
        run = HabitKit.adding(-50, to: run, on: today, calendar: cal)
        positives += 1
        check("计量：负加量夹到 0（不会出现负进度）",
              HabitKit.dayProgress(run, on: today, calendar: cal) == 0)
        run = HabitKit.undoing(run, on: today, calendar: cal)
        negatives += 1
        check("计量：undoing = 当天清零（而不是从 days 里删）", run.progress.isEmpty && run.days.isEmpty)

        // ── 连续天数口径不被量维度污染（同一 isDone 判定，漏一天照旧归零）──
        var streakHabit = HabitItem(title: "冥想", metric: .duration, target: 10, unit: "分钟")
        for off in 1...3 {
            if let d = cal.date(byAdding: .day, value: -off, to: today) {
                streakHabit = HabitKit.settingProgress(10, for: streakHabit, on: d, calendar: cal)
            }
        }
        positives += 1
        check("口径：计量习惯今天未达标 → 连续天数从昨天数（3，不谎报）",
              HabitKit.currentStreak(streakHabit, today: today, calendar: cal) == 3)
        // 中间漏一天（前天只到 5/10 未达标）→ 连续区被打断
        var gapHabit = streakHabit
        if let d2 = cal.date(byAdding: .day, value: -2, to: today) {
            gapHabit = HabitKit.settingProgress(5, for: gapHabit, on: d2, calendar: cal)
        }
        positives += 1
        check("口径：计量习惯「量没到」= 当天未达标 → 连续天数归零（与二值同口径）",
              HabitKit.currentStreak(gapHabit, today: today, calendar: cal) == 1)

        // ── 页卡统计（原实现直读 days，计量习惯会被静默少算 —— 本轮收口）──
        var mix = HabitItem(title: "二值习惯")
        mix = HabitKit.checkingIn(mix, on: today, calendar: cal)
        let metricDone = HabitKit.settingProgress(8, for: water, on: today, calendar: cal)
        let stats = HabitKit.cardStats([mix, metricDone], today: today, days: 7, calendar: cal)
        positives += 1
        check("统计：二值 + 计量各达标 1 天 → done = 2（不是 1）", stats.done == 2)
        positives += 1
        check("统计：total 仍 = 习惯数 × 窗口天数", stats.total == 14)
        // topTitle 必须用「累计达标天数」判：给计量习惯再补一天达标，它就该胜出
        var water2 = metricDone
        if let y = cal.date(byAdding: .day, value: -1, to: today) {
            water2 = HabitKit.settingProgress(8, for: water2, on: y, calendar: cal)
        }
        let stats2 = HabitKit.cardStats([mix, water2], today: today, days: 7, calendar: cal)
        positives += 1
        check("统计：topTitle 用「累计达标天数」判（计量习惯 2 天 > 二值 1 天 → 它胜出）",
              stats2.topTitle == "喝水")
        positives += 1
        check("统计：doneDayCount 计量 = 达标日数（不达标的日子不算）",
              HabitKit.doneDayCount(metricDone) == 1 && HabitKit.doneDayCount(mix) == 1)

        // ── 文案 / 数字去尾零 ──
        let water3 = HabitKit.settingProgress(3, for: water, on: today, calendar: cal)
        positives += 1
        check("文案：3/8 杯", HabitKit.progressText(water3, on: today, calendar: cal) == "3/8 杯")
        positives += 1
        check("文案：达标 → 已完成", HabitKit.progressText(metricDone, on: today, calendar: cal) == "已完成")
        positives += 1
        check("文案：7.5 显示 7.5（不出现 7.5000 / 8.0 这种假精度）",
              HabitKit.numberText(7.5) == "7.5" && HabitKit.numberText(8) == "8"
              && HabitKit.numberText(0.25) == "0.25")
        positives += 1
        check("单位：duration 缺 unit 时回落「分钟」",
              HabitItem(title: "专注", metric: .duration, target: 30).unitText == "分钟")
        negatives += 1
        check("反例：二值习惯 progressText 为空串（圈由视图画，不显示 0/0）",
              HabitKit.progressText(mix, on: today, calendar: cal).isEmpty)

        // ── 曲线点带 value（计量习惯能看到部分进度）──
        var curve = HabitItem(title: "曲线", metric: .amount, target: 4, unit: "杯")
        curve = HabitKit.settingProgress(1, for: curve, on: today, calendar: cal)
        let pts = HabitKit.lastNDays(curve, days: 3, today: today, calendar: cal)
        positives += 1
        check("曲线：近 3 天升序、缺天 value = 0、今天 value = 0.25",
              pts.count == 3 && pts[0].value == 0 && pts[2].value == 0.25)
        negatives += 1
        check("曲线反例：二值习惯的 value 只能是 0/1（不出现分数）",
              HabitKit.lastNDays(mix, days: 3, today: today, calendar: cal).allSatisfy { $0.value == 0 || $0.value == 1 })

        // ── 归日：计量进度也按本地日（23:59 与次日 00:01 分属两天）──
        var edge = HabitItem(title: "跨日", metric: .amount, target: 2, unit: "次")
        edge = HabitKit.settingProgress(1, for: edge,
                                        on: date(2026, 10, 13, 23, 59, cal), calendar: cal)
        edge = HabitKit.settingProgress(1, for: edge,
                                        on: date(2026, 10, 14, 0, 1, cal), calendar: cal)
        positives += 1
        check("归日：计量进度按本地日切分（两天各 1，不并到一天）",
              edge.progress.count == 2 && HabitKit.progressValue(edge, key: "2026-10-13") == 1
              && HabitKit.progressValue(edge, key: "2026-10-14") == 1)
    }

    // MARK: - G. 专注计时（v4.0.104 待做池⑫ · 番茄钟）

    static func sectionG_专注计时(_ cal: Calendar) {
        print("\n=== G. 专注计时（剩余现算 · 归日=开始那天 · 记录整分钟）===")
        let t0 = date(2026, 10, 13, 9, 0, cal)
        let s = FocusSession(habitId: "h1", startedAt: t0, plannedMinutes: 25)

        positives += 1
        check("专注：结束时刻 = 开始 + 计划分钟", s.endsAt == t0.addingTimeInterval(25 * 60))
        positives += 1
        check("专注：刚开始时剩余 = 1500 秒", HabitKit.focusRemaining(s, now: t0) == 1500)
        positives += 1
        check("专注：不做逐秒累加 —— 同一会话隔 10 分钟问，剩余少 600 秒（切后台也不停表）",
              HabitKit.focusRemaining(s, now: t0.addingTimeInterval(600)) == 900)
        positives += 1
        check("专注：剩余向上取整（剩 0.4s 显示 1 秒，不会 00:00 但没到点）",
              HabitKit.focusRemaining(s, now: t0.addingTimeInterval(1499.6)) == 1)
        positives += 1
        check("专注：到点/超时剩余恒 0（不出现负倒计时）",
              HabitKit.focusRemaining(s, now: s.endsAt) == 0
              && HabitKit.focusRemaining(s, now: s.endsAt.addingTimeInterval(999)) == 0)

        // ── 记录分钟数 ──
        positives += 1
        check("专注：到点 → 记计划分钟", HabitKit.focusRecordMinutes(s, now: s.endsAt) == 25)
        positives += 1
        check("专注：超时后才回来 → 仍只记计划分钟（不因挂后台多记）",
              HabitKit.focusRecordMinutes(s, now: s.endsAt.addingTimeInterval(3600)) == 25)
        positives += 1
        check("专注：提前结束 → 记已过整分钟（3 分 30 秒 → 3）",
              HabitKit.focusRecordMinutes(s, now: t0.addingTimeInterval(210)) == 3
              && HabitKit.focusRecordMinutes(s, now: t0.addingTimeInterval(210)) == 3)
        negatives += 1
        check("专注反例：不到 1 分钟就退出 → 记 0（不许留下假进度）",
              HabitKit.focusRecordMinutes(s, now: t0.addingTimeInterval(59)) == 0)
        positives += 1
        check("专注：已过分钟下取整（59 秒 = 0 分钟）",
              HabitKit.focusElapsedMinutes(s, now: t0.addingTimeInterval(59)) == 0
              && HabitKit.focusElapsedMinutes(s, now: t0.addingTimeInterval(60)) == 1)

        // ── 归日 = 开始那一刻（跨零点不许劈成两天）──
        let lateNight = FocusSession(habitId: "h1", startedAt: date(2026, 10, 13, 23, 50, cal),
                                     plannedMinutes: 25)
        positives += 1
        check("归日：23:50 开始 25 分钟 → 记给 10-13（开始那天，不劈两天）",
              HabitKit.focusDayKey(lateNight, calendar: cal) == "2026-10-13"
              && lateNight.endsAt > date(2026, 10, 14, 0, 0, cal))
        negatives += 1
        check("归日反例：不许归到结束那天的日键",
              HabitKit.focusDayKey(lateNight, calendar: cal) != "2026-10-14")

        // ── 时钟文案 ──
        positives += 1
        check("文案：1499 → 24:59 / 0 → 00:00 / 3723 → 1:02:03",
              HabitKit.focusClock(1499) == "24:59" && HabitKit.focusClock(0) == "00:00"
              && HabitKit.focusClock(3723) == "1:02:03")
        negatives += 1
        check("文案反例：负数秒不崩、显示 00:00", HabitKit.focusClock(-5) == "00:00")
        positives += 1
        check("预设：标准番茄 25 在档位里且档位非空", HabitKit.focusPresets.contains(25)
              && HabitKit.focusPresets.allSatisfy { $0 > 0 })

        // ── 步长（点一下加多少）：必须 > 0，否则「点一下毫无反应」而表只钉数值会漏掉哑掉 ──
        positives += 1
        check("步长：量维度 1、时长维度 5，且都 > 0",
              HabitKit.metricStep(HabitItem(title: "水", metric: .amount, target: 8)) == 1
              && HabitKit.metricStep(HabitItem(title: "专注", metric: .duration, target: 25)) == 5)
        negatives += 1
        check("步长反例：任何形态的步长都不许为 0 / 负",
              HabitKit.metricStep(HabitItem(title: "空")) > 0
              && HabitKit.metricStep(HabitItem(title: "目标无效", metric: .amount, target: 0)) > 0)
    }


}
