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
//   · **⑤的口径**（v4.0.101 起**目标与习惯又合流**，「不弹窗」这半句一直是用户点名要的）：
//     **长期目标** = 点卡**在卡下逐条弹出目标卡**（用户 2026-10-12 真机「这个卡片不是弹窗显示，
//     是点击长期目标任务卡时候从长期任务卡下方弹出，跟待办清单卡片弹出方式一样」）——
//     「全部目标」浮层 v4.0.100 一度回潮，v4.0.101 撤掉；展开区内容是**目标卡**不是步骤行；
//     **习惯** = 也是就地展开（浮层入口在展开区底部那行「全部习惯」，习惯侧没变）。
//     ⚠️ 目标侧**别再开「全部目标」浮层**（用户真机点名「不是弹窗」），也别把展开内容换成步骤行。
//   · **⑥的落点**：四处展开区（待办 / 目标 / 习惯 / 记录）的左右内缩 / 顶部间距逐字同值（10 / 8）；
//     勾选圈只有 `LifeCheckCircle` 一个出口（谁在各自文件里再画一枚，两处会长得不一样，而且不报错）。
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
let memo = src(root + "MemoSection.swift")   // v4.0.100：四张生活卡同一档，备忘卡此前漏在护栏外
let scaffold = src(root + "LifeSectionScaffold.swift")
let motion = src("qingliao/Theme/Motion.swift")

let todoCode = code(todo)
let goalsCode = code(goals)
let habitCode = code(habit)
let recordCode = code(record)
let memoCode = code(memo)

// ⚠️ 切片边界只能用**代码**锚：注释会被 code() 剥掉，切不到边就会一路吃到文件末（负断言随即假绿）。
// 结束锚用 `private func goalTint`（撤掉 goalTopTint 后换的稳定代码锚 —— 拿一个已被删掉的成员当锚，
// 切片会一路吃到文件末，⓪ 的 <2000 收边检查当场判红）。
let todoRoot = slice(todoCode, "private var root: some View", "private var completionTint")
let goalsRoot = slice(goalsCode, "private var root: some View", "private func goalTint")
let todoRing = slice(todoCode, "private struct TodoProgressRing", "private struct TodoCheckBox")
let goalRing = slice(goalsCode, "private struct GoalProgressRing", "private struct GoalProgressCard")
let habitRing = slice(habitCode, "private struct HabitProgressRing", "private struct HabitMetricRow")
// v4.0.101：长期目标侧重新有「卡下逐条弹出」展开区（内容 = 目标卡，与待办同形态），
// 切片回到本表监控范围；浮层形态（GoalsAllListBody / glass.showAll）改由 goalsCode 级反向断言盯着。
let goalExpand = slice(goalsCode, "private struct GoalExpandList", "private func goalCardMenuItems")
let habitExpand = slice(habitCode, "private func habitExpandList", "private func openAllHabits")
let recordExpand = slice(recordCode, "private var recordCardExpandList", "private var categoryBreakdown")

// ── ⓪ 切片自身收边正常（否则下面所有基于切片的断言都是假的）──────────────
check("⓪ 切片收边正常：三处 root / 三个环 / 四处展开区都取到了边界",
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

// ── ⑤ 习惯 / 长期目标：点卡就地展开（不再弹浮层）────────────────────────
check("⑤ v4.0.101：长期目标点卡 = **卡下逐条弹出目标卡**（用户真机「不是弹窗显示…跟待办清单卡片弹出方式一样」）",
      goalsCode.contains("onTapCard: toggleExpand")
      && goalsCode.contains("withAnimation(Motion.cardExpand) { goalsExpanded.toggle() }")
      && goalsCode.contains("if goalsExpanded {"))
check("🚫 反向⑤：目标侧「全部目标」浮层入口/内容清零（用户真机点名「不是弹窗」）",
      !goalsCode.contains("openAllGoals") && !goalsCode.contains("glass.showAll = true")
      && !goalsCode.contains("GoalsAllListBody"))
check("⑤ 目标展开区弹的是**目标卡**（GoalRowCard），不是步骤行",
      goalExpand.contains("GoalRowCard(goal: g, compact: false)")
      && !goalExpand.contains("toggleStep"))
check("⑤ 目标展开区底部「清空」入口不丢（原浮层顶栏那颗，确认浮层走页级宿主 GoalsGlassLayerHost）",
      goalExpand.contains("onClearAll") && goalsCode.contains("glass.confirmKind = .clearAll"))
check("⑤ 步骤勾选入口不丢（展开区点一条目标 → 详情里仍是 store.toggleStep + 同步待办两步）",
      goalsCode.contains("onOpenDetail: { openDetail($0) }")
      && goalsCode.contains("store.toggleStep(goalID: g.id, stepID: s.id)")
      && goalsCode.contains("GoalTodoBridge.syncStepDone(step: step, goal: goal)"))

check("⑤ 习惯有就地展开态 @State（habitExpanded）",
      habitCode.contains("@State private var habitExpanded = false"))
check("⑤ 习惯点卡 = 就地展开（Button + toggleExpand + withAnimation(Motion.cardExpand) + toggle）",
      habitCode.contains("withAnimation(Motion.cardExpand) { habitExpanded.toggle() }")
      && habitCode.contains("if habitExpanded {"))
check("🚫 反向⑤：习惯点卡不许再走裸 onTapGesture / 直接开浮层",
      !habitCode.contains(".onTapGesture { openTop("))
// v4.0.104：展开区点行改走 tapHabit 分流（二值=打卡 / 计量=加一笔 / 专注中=回计时器）。
// 原意必须保住：点行**不许自己拼数据**（days/progress 都不许出现），只能经 store + Kit 口径。
check("⑤ 习惯展开区点行 = tapHabit 分流（二值仍复用 toggleHabit，不自己改 days）",
      habitExpand.contains("tapHabit(h, today: today)")
      && !habitExpand.contains(".days")
      && !habitExpand.contains("progress["))
check("⑤ 习惯浮层入口不丢（展开区底部「全部习惯」→ openAllHabits → glass.showAll = true）",
      habitExpand.contains("openAllHabits()") && habitCode.contains("glass.showAll = true"))
check("⑤ 习惯 / 目标 / 记录三张卡仍挂「删空复位展开态」（目标侧 v4.0.101 展开态回来了）",
      habitCode.contains("if empty { habitExpanded = false }")
      && recordCode.contains("if empty { recordExpanded = false }")
      && goalsCode.contains("if isEmpty { goalsExpanded = false }"))

// ── ① 记录卡面不再画「最近 1 条」────────────────────────────────────────────
check("🚫 反向①：记录卡面不许再画「最近 1 条 / 还有 N 条」（用户 2026-10-12 点名去掉）",
      !recordCode.contains("if !recordExpanded {")
      && !recordCode.contains("还有 \\(store.records.count - 1) 条"))
check("① 记录展开区仍在（记录一律看展开条目）",
      recordCode.contains("if recordExpanded { recordCardExpandList }"))
check("① 展开区仍复用 RecordRowCard + 保留「全部记录」浮层入口",
      recordExpand.contains("RecordRowCard(item: r)") && recordExpand.contains("glass.showAll = true"))

// ── ⑤+ 点卡反馈对齐：五张生活卡「点卡展开」一律 cardExpand + Haptics.tap() ──
// v4.0.x（用户真机：「记录卡片点击无震动反馈，没对齐其他」）——记录卡此前漏了 tap，
// 另四张一直都有；钉成五卡同断言，以后新增生活卡漏震动会直接红。
check("⑤+ 五张生活卡点卡展开 = withAnimation(Motion.cardExpand) + Haptics.tap() 全对齐",
      todoCode.contains("withAnimation(Motion.cardExpand) { todoExpanded.toggle() }")
      && goalsCode.contains("withAnimation(Motion.cardExpand) { goalsExpanded.toggle() }")
      && habitCode.contains("withAnimation(Motion.cardExpand) { habitExpanded.toggle() }")
      && recordCode.contains("withAnimation(Motion.cardExpand) { recordExpanded.toggle() }")
      && memoCode.contains("withAnimation(Motion.cardExpand) { memoExpanded.toggle() }")
      && todoCode.contains("Haptics.tap()") && goalsCode.contains("Haptics.tap()")
      && habitCode.contains("Haptics.tap()") && recordCode.contains("Haptics.tap()")
      && memoCode.contains("Haptics.tap()"))

// ── ⑥ 视觉对齐：展开区几何同值 + 勾选圈单一来源 ───────────────────────────
check("⑥ 四处展开区（待办 / 目标 / 习惯 / 记录）左右内缩 / 顶部间距逐字同值（10 / 8）",
      countOf(".padding(.horizontal, 10)\n        .padding(.top, 8)", in: todoCode) >= 1
      && countOf(".padding(.horizontal, 10)\n        .padding(.top, 8)", in: goalsCode) >= 1
      && countOf(".padding(.horizontal, 10)\n        .padding(.top, 8)", in: habitCode) >= 1
      && countOf(".padding(.horizontal, 10)\n        .padding(.top, 8)", in: recordCode) >= 1)
check("⑥ 展开区行距都是 8（待办/目标 VStack(spacing: 8)；习惯/记录 VStack(alignment: .leading, spacing: 8)）",
      goalExpand.contains("VStack(spacing: 8)")
      && habitExpand.contains("VStack(alignment: .leading, spacing: 8)")
      && recordExpand.contains("VStack(alignment: .leading, spacing: 8)"))
check("⑥ 勾选圈只有一个出口 LifeCheckCircle（跨文件单一来源，收在 LifeSectionScaffold）",
      scaffold.contains("struct LifeCheckCircle: View")
      && todoCode.contains("LifeCheckCircle(done: done, tint: .green)")
      && habitCode.contains("LifeCheckCircle(done: done, tint: .green)")
      && goalsCode.contains("LifeCheckCircle(done: s.done, tint: Color.accentColor)"))
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
      goalsCode.contains("LifeCheckCircle(done: s.done, tint: Color.accentColor)")
      && todoCode.contains("LifeCheckCircle(done: current.done, tint: .green)")
      && habitCode.contains("LifeCheckCircle(done: store.isDone(current, on: today), tint: .green)"))

// ── ⑥b 勾选圈「同一档尺寸」= 用户 2026-10-12 追加要求 ────────────────────────
// 「待办清单的勾选圆再变小一点，其他卡片的勾选圆大小也一并对齐」
//（v4.0.99 时是 24 / 26 / 18 三档混用 —— 同一枚圈在三处肉眼可辨地不一样大）
check("⑥b 勾选圈尺寸只有一处真源（LifeCheckCircle.defaultSize = 20）",
      scaffold.contains("static let defaultSize: CGFloat = 20")
      && scaffold.contains("var size: CGFloat = LifeCheckCircle.defaultSize"))
check("🚫 反向⑥b：调用点一律不许再写死 size（三档混用就是用户点名的「没对齐」，「size: size」那种透传也算）",
      ![todoCode, habitCode, goalsCode, recordCode].contains {
          $0.contains("size: 26, tint") || $0.contains("size: 24, tint")
          || $0.contains("size: 18, tint") || $0.contains("size: size, tint")
      })

// ── ⑤c 卡片「点一下弹开」曲线（用户 2026-10-12「点击弹开动画也再丝滑一点」）──
// 四张生活卡展开走专用 cardExpand；**不能**靠把通用 settle 改慢来实现 ——
// settle 同时驱动聊天流式气泡生长（ChatMessageBubble），慢下来流式文字读作卡顿。
check("⑤c 卡片展开走专用曲线 Motion.cardExpand（生活页四卡 + 三处逐条错峰）",
      [todoCode, goalsCode, habitCode, recordCode, memoCode].allSatisfy { $0.contains("Motion.cardExpand") }
      && todoCode.contains("Motion.cardExpand.delay")
      && goalsCode.contains("Motion.cardExpand.delay")
      && habitCode.contains("Motion.cardExpand.delay"))
check("🚫 反向⑤c：备忘卡不许退回通用 settle（v4.0.100 起四卡同一档；此前备忘卡漏在护栏外）",
      memoCode.contains("withAnimation(Motion.cardExpand) { memoExpanded.toggle() }")
      && !memoCode.contains("withAnimation(Motion.settle) { memoExpanded")
      && !memoCode.contains(".animation(Motion.settle, value: expanded)"))
check("⑤c 曲线真源 Motion.cardExpand = .smooth(0.38)（比 settle 更长、更无回弹 = 「丝滑」）",
      motion.contains("static var cardExpand: Animation { .smooth(duration: 0.38) }"))
check("🚫 反向⑤c：通用 settle 不许被改慢（它归聊天流式生长/列表插入，两令牌分立不是冗余）",
      motion.contains("static var settle: Animation { .snappy(duration: 0.30) }")
      && !habitCode.contains("Motion.settle.delay") && !todoCode.contains("Motion.settle.delay"))
check("🚫 反向⑥：三张详情浮层不许再自绘 SF Symbol 勾选圈（旧形态，v4.0.99 已统一）",
      !goalsCode.contains("checkmark.circle.fill")
      && !todoCode.contains("Image(systemName: current.done ? \"checkmark.circle.fill\" : \"circle\")")
      && !habitCode.contains("Image(systemName: store.isDone(current, on: today) ? \"checkmark.circle.fill\" : \"circle\")"))
check("🚫 反向⑥：展开区行卡 / 浮层入口行不许用裸 onTapGesture（无按压反馈、读屏不当按钮）",
      !habitExpand.contains("onTapGesture") && !recordExpand.contains("onTapGesture"))

// ── ⑥c 展开区行卡圆角 = 22（用户 2026-10-12 真机截图圈定的两张卡）────────────────
// 原话：「画红线标注的两张卡片圆角改22」——截图上红线下划的是**展开区里的行卡**
// （习惯栏目的「回国倒计时7天」行卡 + 长期目标栏目的「微信公众号涨粉100」卡），
// 上面那张圆环统计卡（26，上一条⑥钉着）不在点名范围内，两档是**有意分叉**、别去「对齐」。
// 行卡原来是默认 `.pastelCard()`（= Radius.card 16），与同栏目页卡 26 摆在一起弧度差得明显。
// 用户给的是精确值 22，正好落在既有令牌 `Radius.hero` 上 → 取令牌、不写字面量。
let habitRowCard = slice(habitCode, "struct HabitRowCard", "struct HabitAddBody")
let goalRowCard = slice(goalsCode, "struct GoalRowCard", "extension GoalsSection")
check("⑥c 两张行卡切片可取（端点名变了会静默变空，先钉一道）",
      !habitRowCard.isEmpty && !goalRowCard.isEmpty
      && habitRowCard.count > 200 && goalRowCard.count > 200)
check("⑥c 习惯行卡 / 目标卡圆角都是 22（`.pastelCard(cornerRadius: Radius.hero)`）",
      habitRowCard.contains(".pastelCard(cornerRadius: Radius.hero)")
      && goalRowCard.contains(".pastelCard(cornerRadius: Radius.hero)"))
check("🚫 反向⑥c：这两张卡不许退回默认 `.pastelCard()`（= 16，本轮用户点名的就是它）",
      !habitRowCard.contains(".pastelCard()") && !goalRowCard.contains(".pastelCard()"))
check("⑥c 圆角令牌真值 Radius.hero == 22（令牌被改这两张卡会跟着漂，用户点名要的就是这个数）",
      src("qingliao/Theme/Radius.swift").contains("static let hero: CGFloat = 22"))

// ── ⑦ 习惯页卡三行指标的图标改「彩色」（用户 2026-10-12 真机截图圈定）──────────────
// 原话：「红圈中的图标改成彩色」—— 圈住的是习惯圆环卡右侧那三行（火焰 / 日历 / 柱状图）。
// 原实现是 **灰底圆 + 灰符号**（`Color.primary.opacity(0.08)` + `.foregroundStyle(.secondary)`），
// 改成语义实色底 + 白符号，口径与看板栏目头（`BoardCardStyle`）/ 设置页行首色块 /
// 列表行 `BadgeShell` 一致（那几处都是实色底 + 白符号，不新造第二种彩色写法）。
// ⚠️ `tint` 由**调用方**（页卡）给，组件内不再建第二份 icon→color 映射；三行取三种颜色
// —— 三行同色等于又退回一片同色（同 `BoardCard.tint` 的「12 栏目取 12 色」口径）。
let habitMetricRow = slice(habitCode, "struct HabitMetricRow", "struct HabitProgressCard")
let habitProgressCard = slice(habitCode, "struct HabitProgressCard", "struct HabitRowCard")
check("⑦ 三行指标 / 页卡切片可取（端点改名会静默变空，先钉一道）",
      habitMetricRow.count > 200 && habitProgressCard.count > 200)
check("⑦ 图标圆底吃传入色（`.fill(tint)`）、符号转白（`.foregroundStyle(.white)`）",
      habitMetricRow.contains(".fill(tint)")
      && habitMetricRow.contains(".foregroundStyle(.white)"))
check("🚫 反向⑦：图标圆底不许退回灰底（`Color.primary.opacity(0.08)` = 用户点名的旧形态）",
      !habitMetricRow.contains("Color.primary.opacity(0.08)"))
check("⑦ 三行分别是 橙(火焰) / 蓝(日历) / 绿(柱状图)，且恰好三行（不多不少）",
      habitProgressCard.contains("HabitMetricRow(icon: \"flame.fill\", tint: .orange,")
      && habitProgressCard.contains("HabitMetricRow(icon: \"calendar\", tint: .blue,")
      && habitProgressCard.contains("HabitMetricRow(icon: \"chart.bar.fill\", tint: .green,")
      && countOf("HabitMetricRow(", in: habitProgressCard) == 3)

print("生活页四卡对齐真值表：\(passCount) 通过 / \(failCount) 失败")
exit(failCount == 0 ? 0 : 1)
