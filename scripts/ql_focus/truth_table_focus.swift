// v4.0.104 待做池⑫ 专注计时（番茄钟）真值表 —— Linux 本地预检用
//
// 编译运行（在仓库根目录，权威入口是 check_swift.sh 第 96 段）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/tt_focus \
//       scripts/ql_focus/truth_table_focus.swift scripts/ql_focus/keyconf.swift \
//       qingliao/Core/HabitKit.swift qingliao/Core/FocusTimerStore.swift
//
// 本表钉死的口径（漏一条 → 用户看到「专注到点却没记上」/「切个后台回来少记一半」）：
//   · 剩余时间由 now **现算**：挂起/杀 App 都不丢进度（逐秒递减即 bug）
//   · 会话可持久化：杀 App 后重启还在；杀 App 期间到点 → 冷启动补账（绝不静默丢一轮）
//   · 归日 = **开始那一刻**（跨零点只记一天）
//   · 记录 = 整分钟（下取整），到点/超时记计划分钟、提前结束记已过分钟、<1 分钟不记
//   · 落账回调未接线时压 pendingRecords，接线瞬间补一次（且只补一次）
//   · 「放弃」= 不记任何量
// 源级断言钉：App 已接线 attach/refresh、量只走 HabitStore、UI 入口存在。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0,
          _ cal: Calendar = fixedCalendar()) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mi
    return cal.date(from: c) ?? Date(timeIntervalSince1970: 0)
}

func fixedCalendar(_ tz: String = "Asia/Shanghai") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz) ?? TimeZone(secondsFromGMT: 0)!
    return c
}

func stripComments(_ s: String) -> String {
    s.components(separatedBy: "\n").map { String($0.components(separatedBy: "//")[0]) }
        .joined(separator: "\n")
}

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

@main
@MainActor
enum FocusTruthTable {

    static func main() async {
        sectionA_会话与恢复()
        sectionB_落账与放弃()
        await sectionD_恢复后自动滴答()
        sectionC_源级接线()
        let total = positives + negatives
        let ratio = total == 0 ? 0 : Double(negatives) / Double(total)
        check("反例 ≥ 四分之一（正例 \(positives) / 反例 \(negatives) / 占比 \(Int(ratio * 100))%）",
              ratio >= 0.25)
        print(failures == 0 ? "\n🎉 全部通过（0 失败）" : "\n❌ \(failures) 个失败")
        print("结果：正例 \(positives) / 反例 \(negatives) / \(failures) 失败")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - A. 会话、持久化、现算

    static func sectionA_会话与恢复() {
        print("\n=== A. 会话 / 持久化 / 剩余现算 ===")
        let d = freshDefaults("ql_focus_tt_a")
        let store = FocusTimerStore(defaults: d, storageKey: "k")
        positives += 1
        check("冷启动无会话 → 未在专注、剩余 0", !store.isRunning && store.remaining == 0)

        let t0 = Date()
        store.start(habitId: "h1", minutes: 25, now: t0)
        positives += 1
        check("开始时剩余 = 1500 秒", store.remaining == 1500)
        positives += 1
        check("会话立刻落盘（UserDefaults 有 Data）", d.data(forKey: "k") != nil)

        // 杀 App 后重启：同一份存储、新实例 —— 这是「切后台/被系统杀掉」的主场景
        let store2 = FocusTimerStore(defaults: d, storageKey: "k")
        positives += 1
        check("杀 App 后恢复：会话还在，剩余≈1500（不是从头开始也不是归零）",
              store2.isRunning && store2.remaining <= 1500 && store2.remaining >= 1480)

        // 挂起 10 分钟再回来
        store2.refresh(now: t0.addingTimeInterval(600))
        positives += 1
        check("挂起 10 分钟后对表：剩余 900（停表就是 bug）", store2.remaining == 900)
        negatives += 1
        check("反例：剩余不会因为「没走节拍」而停在 1500", store2.remaining != 1500)

        // 跨零点归日：开始那一刻
        let late = FocusSession(habitId: "h1", startedAt: date(2026, 10, 13, 23, 50),
                                plannedMinutes: 25)
        positives += 1
        check("归日 = 开始那天（23:50 开始 → 10-13，不劈两天）",
              HabitKit.focusDayKey(late, calendar: fixedCalendar()) == "2026-10-13")

        // start 覆盖：已有会话先按现在结算，不静默丢
        let d2 = freshDefaults("ql_focus_tt_a2")
        var got: [(String, Date, Int)] = []
        let s3 = FocusTimerStore(defaults: d2, storageKey: "k")
        s3.attach { id, at, m in got.append((id, at, m)) }
        s3.start(habitId: "h1", minutes: 25, now: Date())
        s3.start(habitId: "h2", minutes: 15, now: Date())
        positives += 1
        check("换习惯再开一轮：旧会话先结算（<1 分钟不记 → 0 条），新会话生效",
              got.isEmpty && s3.isRunning && s3.remaining == 900)
    }

    // MARK: - B. 落账 / 提前结束 / 放弃 / 补账

    static func sectionB_落账与放弃() {
        print("\n=== B. 落账（自动 / 提前 / 放弃 / 补账）===")

        // ① 到点自动落账
        let d = freshDefaults("ql_focus_tt_b1")
        var got: [(String, Date, Int)] = []
        let store = FocusTimerStore(defaults: d, storageKey: "k")
        store.attach { id, at, m in got.append((id, at, m)) }
        let t0 = Date()
        store.start(habitId: "h1", minutes: 25, now: t0)
        store.refresh(now: t0.addingTimeInterval(1500))
        positives += 1
        check("到点自动落账 25 分钟，会话清空、盘上键删除",
              got.count == 1 && got[0].0 == "h1" && got[0].2 == 25
              && !store.isRunning && d.data(forKey: "k") == nil)
        positives += 1
        check("落账回执 lastRecord = (h1, 25)", store.lastRecord?.habitId == "h1"
              && store.lastRecord?.minutes == 25)

        // ② 超时后才回来：只记计划分钟，不多记
        let d2 = freshDefaults("ql_focus_tt_b2")
        var got2: [(String, Date, Int)] = []
        let s2 = FocusTimerStore(defaults: d2, storageKey: "k")
        s2.attach { id, at, m in got2.append((id, at, m)) }
        let u0 = Date()
        s2.start(habitId: "h1", minutes: 25, now: u0)
        s2.refresh(now: u0.addingTimeInterval(3600))
        negatives += 1
        check("反例：挂后台 1 小时才回来 → 仍只记 25（不按墙钟多记）", got2.count == 1 && got2[0].2 == 25)

        // ③ 提前结束：记已过整分钟
        let d3 = freshDefaults("ql_focus_tt_b3")
        var got3: [(String, Date, Int)] = []
        let s3 = FocusTimerStore(defaults: d3, storageKey: "k")
        s3.attach { id, at, m in got3.append((id, at, m)) }
        let v0 = Date()
        s3.start(habitId: "h7", minutes: 25, now: v0)
        let mins = s3.stop(now: v0.addingTimeInterval(210))
        positives += 1
        check("提前结束：返回 3 分钟并落账", mins == 3 && got3.count == 1 && got3[0].2 == 3)
        positives += 1
        check("提前结束后会话清空、盘上键删除",
              !s3.isRunning && d3.data(forKey: "k") == nil)

        // ④ 不到 1 分钟
        let d4 = freshDefaults("ql_focus_tt_b4")
        var got4: [(String, Date, Int)] = []
        let s4 = FocusTimerStore(defaults: d4, storageKey: "k")
        s4.attach { id, at, m in got4.append((id, at, m)) }
        let w0 = Date()
        s4.start(habitId: "h1", minutes: 25, now: w0)
        let short = s4.stop(now: w0.addingTimeInterval(30))
        negatives += 1
        check("反例：30 秒就结束 → 记 0、不落账（不留假进度）",
              short == 0 && got4.isEmpty && !s4.isRunning)

        // ⑤ 放弃：不记任何量
        let d5 = freshDefaults("ql_focus_tt_b5")
        var got5: [(String, Date, Int)] = []
        let s5 = FocusTimerStore(defaults: d5, storageKey: "k")
        s5.attach { id, at, m in got5.append((id, at, m)) }
        let x0 = Date()
        s5.start(habitId: "h1", minutes: 25, now: x0)
        s5.cancel()
        negatives += 1
        check("反例：放弃 → 一条都不落账，会话清空",
              got5.isEmpty && !s5.isRunning && d5.data(forKey: "k") == nil)

        // ⑥ 杀 App 期间到点：冷启动补账（回调未接线 → 压 pending → attach 瞬补一次）
        let d6 = freshDefaults("ql_focus_tt_b6")
        let stale = FocusSession(habitId: "h9", startedAt: Date().addingTimeInterval(-1800),
                                 plannedMinutes: 25)
        d6.set(try! JSONEncoder().encode(stale), forKey: "k")
        let s6 = FocusTimerStore(defaults: d6, storageKey: "k")
        positives += 1
        check("杀 App 期间已到点：冷启动当场收尾（会话清空、盘上键删除）",
              !s6.isRunning && d6.data(forKey: "k") == nil)
        var late1: [(String, Date, Int)] = []
        s6.attach { id, at, m in late1.append((id, at, m)) }
        positives += 1
        check("接线瞬间补账一次：记 25 分钟、归到开始那天",
              late1.count == 1 && late1[0].0 == "h9" && late1[0].2 == 25
              && HabitKit.focusDayKey(stale, calendar: fixedCalendar()) == HabitKit.dayKey(late1[0].1))
        var late2: [(String, Date, Int)] = []
        s6.attach { id, at, m in late2.append((id, at, m)) }
        negatives += 1
        check("反例：再 attach 一次不重复补账（否则会重复记时长）", late2.isEmpty)

        // ⑦ 坏数据不崩：盘上是垃圾 / 计划分钟为 0
        let d7 = freshDefaults("ql_focus_tt_b7")
        d7.set(Data("not json".utf8), forKey: "k")
        let s7 = FocusTimerStore(defaults: d7, storageKey: "k")
        negatives += 1
        check("反例：盘上垃圾数据 → 视为无会话，不崩", !s7.isRunning && s7.remaining == 0)
        let zero = FocusSession(habitId: "h1", startedAt: Date(), plannedMinutes: 0)
        positives += 1
        check("边界：plannedMinutes 0 被抬到 1（不会出现 0 分钟会话）", zero.plannedMinutes == 1)
        negatives += 1
        check("反例：空 habitId 不启动", { let d8 = freshDefaults("ql_focus_tt_b8")
            let s8 = FocusTimerStore(defaults: d8, storageKey: "k")
            s8.start(habitId: "", minutes: 25); return !s8.isRunning }())
    }

    // MARK: - C. 源级接线（剥注释）

    static func sectionC_源级接线() {
        print("\n=== C. 源级接线（App / Store / UI 入口）===")
        let app = stripComments(read("qingliao/QingliaoApp.swift"))
        positives += 1
        check("App 启动接线专注落账（attach + addAmount 到 HabitStore）",
              app.contains("FocusTimerStore.shared.attach") && app.contains("HabitStore.shared.addAmount"))
        positives += 1
        check("App 在 scenePhase 变化时对表（回前台立刻纠正剩余）",
              app.contains("FocusTimerStore.shared.refresh()"))
        // 归日口径断在 App 边界上：把 on: startedAt 改成 on: Date() 时**曾经两张表全绿**（审查变异证实），
        // 那等于「跨零点专注会不会记错天」没有任何护栏。
        let startedAtWired = app.components(separatedBy: "on: startedAt").count - 1
        positives += 1
        check("App 落账处把「开始时刻」交下去（on: startedAt ×2：正常路径 + 维度补正路径）",
              startedAtWired == 2 && !app.contains(", on: Date()"))
        let models = stripComments(read("qingliao/Core/Models.swift"))
        positives += 1
        check("键真源：Models.swift 里 focusSession 字面量与替身逐字相同",
              models.contains("static let focusSession = \"qingliao_focus_session\""))
        let store = stripComments(read("qingliao/Core/FocusTimerStore.swift"))
        positives += 1
        check("FocusTimerStore 不自己写习惯数据（量只经回调交出去）",
              !store.contains("habit.progress") && !store.contains("HabitStore"))
        negatives += 1
        check("反例：FocusTimerStore 里不许出现逐秒递减（remaining -= 1 之类）",
              !store.contains("remaining -= 1") && !store.contains("remaining = remaining - 1"))
        let kit = stripComments(read("qingliao/Core/HabitKit.swift"))
        positives += 1
        check("HabitKit 走现算：focusRemaining 依赖 endsAt 差值", kit.contains("s.endsAt.timeIntervalSince(now)"))

        // ── UI 接线（视图层：入口存在 + 不越权）──
        let section = stripComments(read("qingliao/Features/Life/HabitSection.swift"))
        positives += 1
        check("行卡：计量习惯走进度行（二值仍走原连续天数行）",
              section.contains("if h.isMetric { metricLine } else { streakLine }"))
        positives += 1
        check("点行分流：展开区改走 tapHabit（二值打卡 / 计量加一笔 / 专注中回计时器）",
              section.contains("tapHabit(h, today: today)"))
        positives += 1
        check("详情页：计量设置区 + 内联编辑器 + 改目标入口",
              section.contains("metricSettingsBlock") && section.contains("beginMetricEditing()")
              && section.contains("store.updateMetric(current, metric:"))
        positives += 1
        check("详情页：计量习惯的进度卡与「专注」入口（时长维度）",
              section.contains("metricDetailCard") && section.contains("FocusGlassPresenter.shared.open(habitId: current.id)"))
        // 第四层顺序：详情 → 专注 → 新建。顺序错了（比如插到新建层后面）关掉专注层就会弹回列表，
        // 或者专注层被新建层盖住点不到 —— 光查两个子串在不在是**假绿**（改顺序照样绿）。
        let iDetail = section.range(of: "if let fid = FocusGlassPresenter.shared.habitId")
        let iFocus = section.range(of: "FocusTimerBody(habitId: fid")
        let iAdd = section.range(of: "if glass.showAdd")
        let layerOrdered: Bool
        if let d = iDetail, let f = iFocus, let a = iAdd {
            layerOrdered = d.lowerBound < f.lowerBound && f.lowerBound < a.lowerBound
        } else {
            layerOrdered = false
        }
        positives += 1
        check("第四层渲染次序 = 详情 → 专注 → 新建（关掉专注层回到详情层，不被新建层盖住）", layerOrdered)
        positives += 1
        check("浮层已挂宿主（第四层，与前三层同形）",
              section.contains("FocusTimerBody(habitId: fid") && section.contains("FocusGlassPresenter.shared.reset()"))
        positives += 1
        check("进度条单一来源：行卡与详情复用 MetricProgressBar",
              section.contains("MetricProgressBar(fraction:"))
        negatives += 1
        check("反例：视图层不直接读写习惯数据（量只经 HabitStore）",
              !section.contains(".progress[") && !section.contains("habit.days"))

        let focusUI = stripComments(read("qingliao/Features/Life/FocusTimerSection.swift"))
        positives += 1
        check("专注浮层：预设档来自 HabitKit.focusPresets（不写死第二套档位）",
              focusUI.contains("ForEach(HabitKit.focusPresets"))
        positives += 1
        check("开始专注前明示「会自动设成时长习惯」（改用户数据必须写清）",
              focusUI.contains("会自动设为「时长」习惯") && focusUI.contains("开始后会改成「时长」"))
        negatives += 1
        check("反例：专注浮层不自己写盘 / 不自己算剩余（真相在 FocusTimerStore + HabitKit）",
              !focusUI.contains("UserDefaults") && !focusUI.contains("timeIntervalSince"))
        negatives += 1
        check("反例：视图不重复实现倒计时时钟（文案统一走 HabitKit.focusClock）",
              !focusUI.contains("String(format: \"%02d"))
        positives += 1
        check("到点/结束后有回执（否则用户以为「时间到了却没记上」）",
              focusUI.contains("已记录 \\(rec.minutes) 分钟到"))
    }

    // MARK: - D. 恢复会话后节拍必须自己在走（只读审查 D1 的回归守卫）

    /// 这一节是**行为**断言：真等 1.4 秒看节拍有没有自己把剩余时间往前推。
    /// 原缺陷：init 恢复「进行中会话」只 refresh() 不起表 → 冷启动/杀 App 重启后倒计时冻在原地、
    /// 到点也不自动落账（审查用探针实测 remaining 恒 1500）；当时 96 段护栏全绿，因为旧断言一律
    /// 手动调 refresh(now:)，从不验证「恢复后节拍自己在走」。这条就是补那个洞。
    static func sectionD_恢复后自动滴答() async {
        print("\n=== D. 恢复会话后节拍自动走（冷启动 / 杀 App 重启）===")

        let d = freshDefaults("ql_focus_tt_d1")
        let live = FocusSession(habitId: "hd", startedAt: Date(), plannedMinutes: 25)
        d.set(try! JSONEncoder().encode(live), forKey: "k")
        let store = FocusTimerStore(defaults: d, storageKey: "k")
        let r0 = store.remaining
        try? await Task.sleep(for: .milliseconds(1400))
        let r1 = store.remaining
        positives += 1
        check("恢复出来的会话：节拍自己在走（r0=\(r0) → r1=\(r1)，期间没手动 refresh）", r1 < r0)

        // 恢复出来的会话到点 → 节拍自己收尾并落账（不靠用户点任何东西）
        let d2 = freshDefaults("ql_focus_tt_d2")
        let nearly = FocusSession(habitId: "hd2",
                                  startedAt: Date().addingTimeInterval(-25 * 60 + 0.5),   // 还剩 0.5 秒 → 节拍一响就该收尾
                                  plannedMinutes: 25)
        d2.set(try! JSONEncoder().encode(nearly), forKey: "k")
        let s2 = FocusTimerStore(defaults: d2, storageKey: "k")
        var got: [(String, Date, Int)] = []
        s2.attach { id, at, m in got.append((id, at, m)) }
        try? await Task.sleep(for: .milliseconds(1800))
        positives += 1
        check("恢复后到点：节拍自动收尾并落账计划分钟（\(got.count) 笔 / 会话已停=\(!s2.isRunning)）",
              got.count == 1 && got[0].2 == 25 && !s2.isRunning)
    }

    static func freshDefaults(_ suite: String) -> UserDefaults {
        let d = UserDefaults(suiteName: suite)!
        for k in d.dictionaryRepresentation().keys { d.removeObject(forKey: k) }
        return d
    }
}
