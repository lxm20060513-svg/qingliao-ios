// MARK: - 生活页四卡交互/视觉对齐真值表（v4.0.99 · 用户 2026-10-12 六条要求）
//
// 口径（用户原话）：
//   ①「记录卡片首页去掉最新一条记录，全部放在展开条目里」
//   ②「待办清单卡片和长期目标卡片底色串到了标题栏」
//   ③「待办清单卡片圆环做 3 重环，内环橙色中环紫色外环绿色」
//   ④「长期目标卡片圆环中间显示进度完成百分比」
//   ⑤「习惯卡片和长期目标卡片点击不弹窗，改成跟待办清单一样的卡片展开显示」
//   ⑥「app 整体做视觉对齐」
//
//   · **②的根因**：栏目根节点上那层 `.background(alignment: .top) { LinearGradient(...) }` 是从
//     **栏目最顶边**（= 玻璃标题行）开始铺的 —— 标题行半透，底色就串上去了。修法 = 整层撤掉，
//     染色只留卡内那一层 `Color.green/.accentColor.opacity(tint)` 圆角底。
//     ⚠️ 谁把「栏目级光晕」加回来（哪怕只加一边），标题栏串色立刻复发 → 本表负断言盯着。
//   · **③的坑**：三圈共用同一个 progress（待办只有一个完成度指标），但**底色轨必须各用自己的颜色**
//     （统一灰 → 零进度时看不见「橙紫绿」三层，退化成一枚灰环）。外径仍是 70（与目标/习惯环同外径
//     → 三张卡等高）；线宽 8→6 才塞得下三圈。
//   · **⑤的口径**：点卡 = 就地展开（与待办卡同一套），**浮层入口不许丢** —— 挪到展开区底部那行
//     「全部目标 / 全部习惯」。步骤勾选、打卡都在卡下就地做。
//   · **⑥的落点**：四张卡展开区的左右内缩 / 顶部间距逐字同值（10 / 8）；勾选圈只有 `LifeCheckCircle`
//     一个出口（谁在各自文件里再画一枚，两处会长得不一样，而且不报错）。
//
// 为什么值得钉：这些都是**静默**错 —— 点卡又变回弹浮层、底色轨退回灰、百分比环被删、
// 光晕加回来串色、勾选圈各画各的，全都不报错，只等用户下次装包再吐槽一轮。
//
// 单文件（读源文件做护栏，不 import 项目代码）→ run_unit 直接编跑。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉 `//` 行注释：注释里刻意写了「原来那样是错的」的说明，直接 grep 原文会被自己的注释判红。
func code(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            let head = line[line.startIndex..<r.lowerBound]
            if head.filter({ $0 == "\"" }).count % 2 == 1 { return String(line) }
            return String(head)
        }
        .joined(separator: "\n")
}

/// 取 `start` 到 `end` 之间的源码切片（end 缺省 = 文件末）
func slice(_ text: String, _ start: String, _ end: String? = nil) -> String {
    guard let a = text.range(of: start) else { return "" }
    let tail = text[a.lowerBound...]
    guard let e = end, let b = tail.range(of: e) else { return String(tail) }
    return String(tail[..<b.lowerBound])
}

func countOf(_ needle: String, in hay: String) -> Int {
    hay.components(separatedBy: needle).count - 1
}

let root = "qingliao/Features/Life/"
let todo = src(root + "TodoSection.swift")
let goals = src(root + "GoalsSection.swift")
let habit = src(root + "HabitSection.swift")
let record = src(root + "RecordSection.swift")
let scaffold = src(root + "LifeSectionScaffold.swift")

let todoCode = code(todo)
let goalsCode = code(goals)
let habitCode = code(habit)
let recordCode = code(record)

// ⚠️ 切片边界只能用**代码**锚：注释会被 code() 剥掉，切不到边就会一路吃到文件末（负断言随即假绿）。
// 结束锚用 `private func goalTint`（撤掉 goalTopTint 后换的稳定代码锚 —— 拿一个已被删掉的成员当锚，
// 切片会一路吃到文件末，⓪ 的 <2000 收边检查当场判红）。
let todoRoot = slice(todoCode, "private var root: some View", "private var completionTint")
let goalsRoot = slice(goalsCode, "private var root: some View", "private func goalTint")
let todoRing = slice(todoCode, "private struct TodoProgressRing", "private struct TodoCheckBox")
let goalRing = slice(goalsCode, "private struct GoalProgressRing", "private struct GoalProgressCard")
let habitRing = slice(habitCode, "private struct HabitProgressRing", "private struct HabitMetricRow")
let goalExpand = slice(goalsCode, "private func goalExpandList", "private func toggleStep(goalID:")
let habitExpand = slice(habitCode, "private func habitExpandList", "private func openAllHabits")
let recordExpand = slice(recordCode, "private var recordCardExpandList", "private var categoryBreakdown")

// ── ⓪ 切片自身收边正常（否则下面所有基于切片的断言都是假的）──────────────
check("⓪ 切片收边正常：三处 root / 三个环 / 三处展开区都取到了边界",
      !todoRoot.isEmpty && todoRoot.count < 2000
      && !goalsRoot.isEmpty && goalsRoot.count < 2000
      && !todoRing.isEmpty && todoRing.count < 2500
      && !goalRing.isEmpty && goalRing.count < 2500
      && !habitRing.isEmpty && habitRing.count < 2500
      && !goalExpand.isEmpty && goalExpand.count < 3500
      && !habitExpand.isEmpty && habitExpand.count < 3500
      && !recordExpand.isEmpty && recordExpand.count < 5000)

// ── ② 串色根治：栏目级光晕整层撤掉（两边都不许留）────────────────────────
check("🚫 反向②：待办栏目根不许再有环境光晕（.background(alignment: .top) = 从标题行顶边铺色 → 串标题栏）",
      !todoRoot.contains(".background(alignment: .top)"))
check("🚫 反向②：长期目标栏目根同样不许有（用户点名这两张卡）",
      !goalsRoot.contains(".background(alignment: .top)"))
check("🚫 反向②′：整文件不许再有「绿色/主题色渐变铺到栏目顶」那种写法",
      !todoCode.contains("LinearGradient(colors: [Color.green.opacity(completionTint)")
      && !goalsCode.contains("LinearGradient(colors: [Color.accentColor.opacity(goalTopTint)"))
check("② 染色强度真源仍在（卡内那层圆角底照用，别把染色一起删了）",
      todoCode.contains("private var completionTint") && todoCode.contains("Color.green.opacity(tint)")
      && goalsCode.contains("private func goalTint") && goalsCode.contains("Color.accentColor.opacity(tint)"))

// ── ③ 待办三重环：外绿 / 中紫 / 内橙 ──────────────────────────────────────
check("③ 三重环三圈都在（外绿 / 中紫 / 内橙，顺序即内外）",
      todoRing.contains("ring(Color.green, inset: 0)")
      && todoRing.contains("ring(Color.purple, inset: insetStep)")
      && todoRing.contains("ring(Color.orange, inset: insetStep * 2)"))
check("③ 底色轨各用自己的颜色（统一灰 → 零进度时看不见三层）",
      todoRing.contains("Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)"))
check("③ 外径仍是 70（与目标/习惯环同外径 = 三张卡等高），线宽降到 6 才塞得下三圈",
      todoRing.contains("var size: CGFloat = 70") && todoRing.contains("var lineWidth: CGFloat = 6"))
check("③ 每圈内缩 = 线宽 + 缝（写成裸 lineWidth 会让相邻色带正好相切 = 一整条三色粗带，分不出三重）",
      todoRing.contains("private var insetStep: CGFloat { lineWidth + ringGap }")
      && todoRing.contains("private var ringGap: CGFloat { 3 }"))
check("③ 三圈同源同进度（同一个 progress 变量喂三层，不许各算各的）",
      todoRing.contains("to: min(1, max(0, progress))")
      && !todoRing.contains("progress2") && !todoRing.contains("outerProgress"))

// ── ④ 目标环环心百分比（与习惯环同口径）──────────────────────────────────
check("④ 目标环环心画百分比（Text(percentText)）", goalRing.contains("Text(percentText)"))
check("④ 百分比口径与习惯环逐字一致（0…100 取整 + 越界钳住）",
      goalRing.contains("Int((min(1, max(0, progress)) * 100).rounded()))%")
      && habitRing.contains("Int((min(1, max(0, progress)) * 100).rounded()))%"))
check("④ 环心字号 18 粗体（与习惯环同一档，用户要「一样大」）",
      goalRing.contains(".font(.system(size: 18, weight: .bold))")
      && habitRing.contains(".font(.system(size: 18, weight: .bold))"))

// ── ⑤ 习惯 / 长期目标：点卡就地展开（不再弹浮层），浮层入口不丢 ──────────
check("⑤ 长期目标有就地展开态 @State（存 id 不存 Bool —— 主目标一换就自动收起）",
      goalsCode.contains("@State private var expandedGoalID: String?"))
check("⑤ 长期目标点卡 = 就地展开（onTapCard: toggleExpand + withAnimation(Motion.settle) + 翻 id）",
      goalsCode.contains("onTapCard: toggleExpand")
      && goalsCode.contains("withAnimation(Motion.settle) { expandedGoalID = (expandedGoalID == id) ? nil : id }"))
check("🚫 反向⑤：长期目标点卡不许再直接开「全部目标」浮层",
      !goalsCode.contains("onTapCard: openAllGoals"))
check("⑤ 长期目标展开区存在且挂在卡下（绑 id 渲染：if expandedGoalID == top.id { goalExpandList(top) }）",
      goalsCode.contains("if expandedGoalID == top.id {") && goalsCode.contains("goalExpandList(top)"))
check("⑤ 长期目标浮层入口不丢（展开区底部「全部目标」→ openAllGoals → glass.showAll = true）",
      goalExpand.contains("openAllGoals()") && goalsCode.contains("glass.showAll = true"))
check("⑤ 长期目标展开区勾一步 = 写库 + 同步待办（不许只改界面）",
      goalsCode.contains("store.toggleStep(goalID: goalID, stepID: step.id)")
      && goalsCode.contains("GoalTodoBridge.syncStepDone(step: fresh, goal: goal)"))

check("⑤ 习惯有就地展开态 @State（habitExpanded）",
      habitCode.contains("@State private var habitExpanded = false"))
check("⑤ 习惯点卡 = 就地展开（Button + toggleExpand + withAnimation(Motion.settle) + toggle）",
      habitCode.contains("withAnimation(Motion.settle) { habitExpanded.toggle() }")
      && habitCode.contains("if habitExpanded {"))
check("🚫 反向⑤：习惯点卡不许再走裸 onTapGesture / 直接开浮层",
      !habitCode.contains(".onTapGesture { openTop("))
check("⑤ 习惯展开区点行 = 打卡（复用 toggleHabit，不自己改 days）",
      habitExpand.contains("toggleHabit(h, today: today)"))
check("⑤ 习惯浮层入口不丢（展开区底部「全部习惯」→ openAllHabits → glass.showAll = true）",
      habitExpand.contains("openAllHabits()") && habitCode.contains("glass.showAll = true"))
check("⑤ 两张卡都挂了「删空复位展开态」（否则下次新建第一条以已展开形态凭空出现）",
      goalsCode.contains("if empty { expandedGoalID = nil }")
      && habitCode.contains("if empty { habitExpanded = false }")
      && recordCode.contains("if empty { recordExpanded = false }"))

// ── ① 记录卡面不再画「最近 1 条」────────────────────────────────────────────
check("🚫 反向①：记录卡面不许再画「最近 1 条 / 还有 N 条」（用户 2026-10-12 点名去掉）",
      !recordCode.contains("if !recordExpanded {")
      && !recordCode.contains("还有 \\(store.records.count - 1) 条"))
check("① 记录展开区仍在（记录一律看展开条目）",
      recordCode.contains("if recordExpanded { recordCardExpandList }"))
check("① 展开区仍复用 RecordRowCard + 保留「全部记录」浮层入口",
      recordExpand.contains("RecordRowCard(item: r)") && recordExpand.contains("glass.showAll = true"))

// ── ⑥ 视觉对齐：展开区几何同值 + 勾选圈单一来源 ───────────────────────────
check("⑥ 四处展开区左右内缩 / 顶部间距逐字同值（10 / 8）",
      countOf(".padding(.horizontal, 10)\n        .padding(.top, 8)", in: todoCode) >= 1
      && countOf(".padding(.horizontal, 10)\n        .padding(.top, 8)", in: goalsCode) >= 1
      && countOf(".padding(.horizontal, 10)\n        .padding(.top, 8)", in: habitCode) >= 1
      && countOf(".padding(.horizontal, 10)\n        .padding(.top, 8)", in: recordCode) >= 1)
check("⑥ 三处展开区行距都是 8（VStack(alignment: .leading, spacing: 8)）",
      goalExpand.contains("VStack(alignment: .leading, spacing: 8)")
      && habitExpand.contains("VStack(alignment: .leading, spacing: 8)")
      && recordExpand.contains("VStack(alignment: .leading, spacing: 8)"))
check("⑥ 勾选圈只有一个出口 LifeCheckCircle（跨文件单一来源，收在 LifeSectionScaffold）",
      scaffold.contains("struct LifeCheckCircle: View")
      && todoCode.contains("LifeCheckCircle(done: done, size: size, tint: .green)")
      && goalExpand.contains("LifeCheckCircle(done: s.done, tint: Color.accentColor)")
      && habitCode.contains("LifeCheckCircle(done: done, size: 26, tint: .green)"))
check("🚫 反向⑥：待办展开区不许再自己画勾选圈（几何漂移的入口）",
      !slice(todoCode, "private struct TodoCheckBox", "private struct TodoProgressCard")
          .contains("Circle()"))
check("🚫 反向⑥：习惯行卡不许退回 SF Symbol 勾选圈（与另两处不同款）",
      !habitCode.contains("done ? \"checkmark.circle.fill\" : \"circle\""))
check("⑥ 三张进度卡同挂 MemoCardMetrics.progressCardMinHeight（「一样大」的构造性保证）",
      countOf("MemoCardMetrics.progressCardMinHeight", in: todoCode) >= 1
      && countOf("MemoCardMetrics.progressCardMinHeight", in: goalsCode) >= 1
      && countOf("MemoCardMetrics.progressCardMinHeight", in: habitCode) >= 1)
check("⑥ 三张进度卡圆角都是 26（页卡一档）",
      todoCode.contains(".pastelCard(cornerRadius: 26)")
      && goalsCode.contains(".pastelCard(cornerRadius: 26)")
      && habitCode.contains(".pastelCard(cornerRadius: 26)"))
check("⑥ 勾选圈连**详情浮层**也统一（同一步骤/同一习惯在两处两种圈 = 用户点名的「没对齐」）",
      goalsCode.contains("LifeCheckCircle(done: s.done, size: 18, tint: Color.accentColor)")
      && todoCode.contains("LifeCheckCircle(done: current.done, size: 26, tint: .green)")
      && habitCode.contains("LifeCheckCircle(done: store.isDone(current, on: today), size: 26, tint: .green)"))
check("🚫 反向⑥：三张详情浮层不许再自绘 SF Symbol 勾选圈（旧形态，v4.0.99 已统一）",
      !goalsCode.contains("checkmark.circle.fill")
      && !todoCode.contains("Image(systemName: current.done ? \"checkmark.circle.fill\" : \"circle\")")
      && !habitCode.contains("Image(systemName: store.isDone(current, on: today) ? \"checkmark.circle.fill\" : \"circle\")"))
check("🚫 反向⑥：展开区行卡 / 浮层入口行不许用裸 onTapGesture（无按压反馈、读屏不当按钮）",
      !goalExpand.contains("onTapGesture") && !habitExpand.contains("onTapGesture")
      && !recordExpand.contains("onTapGesture"))

print("生活页四卡对齐真值表：\(passCount) 通过 / \(failCount) 失败")
exit(failCount == 0 ? 0 : 1)
