// 自定义下拉刷新（液体杯子）—— 源级真值表（读源文件做护栏，不 import 项目代码）
//
// 口径（用户 2026-10-14 定案）：下拉液面上升填满 → 松手满杯晃一下 → 弹性回位。
// 覆盖范围：**主列表页**（会话列表 / 工作台 / 生活 / 看板 / 任务中心）；设置类 Form/List 页
// 本批不动（仍走系统 .refreshable），故下表带**反例**：设置页不许出现自绘杯子（防止误扩散）。
//
// 为什么必须有这张表（全是**静默失效**，编译过、真机才发现）：
//   ① 组件挂错层（挂到内层 VStack/容器上）→ 拿不到滚动几何 → 下拉毫无反应，编译不报；
//   ② 同一容器 `.refreshable` 与 `.pullRefreshCup` 并存 → 双触发 + 系统转圈与杯子同屏；
//   ③ 少写 `.onScrollPhaseChange` → 永远不触发刷新（液面涨上去又弹回，看着像「没生效」）；
//   ④ 阈值/尺寸/触觉被改成字面量或漏 `Haptics.medium()` → 用户口径「震动要明显」失守（他真机必报）；
//   ⑤ 刷新期间不锁态 → 连拉两次 = 同一个 load() 跑两遍（在途闸门在页面侧，双触发会绕过它）。
// ⚠️ **必须 cwd = 仓库根**（下列路径是相对路径）。

import Foundation

var passCount = 0
var failCount = 0

func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉 `//` 行注释（注释里刻意写了「原来那样是错的」，直接 grep 原文会被自己的注释判红）
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

func countOf(_ needle: String, in hay: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return hay.components(separatedBy: needle).count - 1
}

let cupSrc = src("qingliao/Theme/PullRefreshCup.swift")
let cupCode = code(cupSrc)

// ── 1. 源可读（空了后面全是空真） ─────────────────────────────
check("① 组件源可读（PullRefreshCup.swift）", cupSrc.count > 1500)
check("① View 扩展出口唯一（pullRefreshCup）", countOf("func pullRefreshCup(", in: cupCode) == 1)

// ── 2. 组件核心机制：几何 + 松手 + 摇晃 + 状态机 ────────────────
check("② 读滚动几何（onScrollGeometryChange）", cupCode.contains(".onScrollGeometryChange(for: CGFloat.self)"))
check("② 松手判定走几何回弹（曾拉满 armed + 回弹过半）——与聊天页 InboxPullRefresh 同款口径",
      cupCode.contains("} else if armed, d < trigger * 0.5 {"))
check("② 反例：不得引入 onScrollPhaseChange（全仓无先例，List 上是否发布相位无从静态确认）",
      !cupCode.contains("onScrollPhaseChange"))
check("② 投影自带夹紧+取整（投影取裸 offset = 正常滚动全程 60fps 回调写 @State，整页 body 掉帧）",
      cupCode.contains("max(0, -(geo.contentOffset.y + geo.contentInsets.top)).rounded()"))
check("② 顶部 inset 单独投影（指示器落点要用，且不参与每帧）",
      cupCode.contains("geo.contentInsets.top\n            } action: { _, top in"))
check("② 指示器落点算上 topInset（不算 = 杯子整段落进页头/状态栏背后）",
      cupCode.contains(".offset(y: travel)")
      && cupCode.contains("topInset + min(pull, trigger) * 0.55"))
check("② 页面销毁取消刷新任务（不取消 = 卸载后仍在跑网络与写状态）",
      cupCode.contains(".onDisappear { refreshTask?.cancel()"))
check("② 回位等够曲线时长（短于曲线 = 弹回过冲段被撤层，看着「闪一下不见」）",
      cupCode.contains("settleWait: UInt64 = 450_000_000") && cupCode.contains("Task.sleep(nanoseconds: settleWait)"))
check("② 完全归位才复位 armed（中途清会被松手回弹路径误清 → 拉满也不触发）",
      cupCode.contains("if d == 0 { armed = false }"))
check("② 下拉距离折算：offset + inset（少加 inset 会永远差一截拉不满）",
      cupCode.contains("geo.contentOffset.y + geo.contentInsets.top"))
check("② 满杯摇晃走 keyframeAnimator（不是 rotationEffect 硬设角度）",
      cupCode.contains(".keyframeAnimator(initialValue: 0.0, trigger: sloshTick)"))
check("② 状态机四态齐（idle/pulling/refreshing/finishing）",
      cupCode.contains("case idle, pulling, refreshing, finishing"))
check("② action 标 @MainActor（Swift 6 严格并发：非隔离闭包进 Task{@MainActor} 编不过）",
      cupCode.contains("var action: @MainActor () async -> Void")
      && cupCode.contains("action: @escaping @MainActor () async -> Void"))

// ── 3. 手感口径：震动 / 防重入 / 弹性回位 / 令牌 ─────────────────
check("③ 达阈值给 medium 触觉（用户口径「震动要明显」）", cupCode.contains("Haptics.medium()"))
check("③ 达阈只震一次（armed 闸门，防跟手期间连震）",
      cupCode.contains("if !armed { armed = true"))
check("③ 刷新/回位期间不吃新下拉（防重入）",
      cupCode.contains("guard phase == .idle || phase == .pulling else { return }"))
check("④ 弹性回位走 Motion 令牌（不是字面 duration）",
      cupCode.contains("withAnimation(Motion.settle) { pull = 0 }"))
check("④ 没拉够的缩回走 Motion 令牌", cupCode.contains("withAnimation(Motion.settle) { pull = 0 }"))
check("④ 不写字面动画时长（withAnimation(.easeIn…)/duration: 之外的动画一律令牌）",
      !cupCode.contains("withAnimation(.ease")
      && !cupCode.contains("withAnimation(.linear")
      && !cupCode.contains("withAnimation(.spring("))

// ── 4. 五页接入：挂点正确（滚动容器上）且旧 API 已撤 ──────────────
// 每页 = (路径, 该页原 .refreshable 闭包体片段，用于认「这页挂的是滚动容器本体」)
let pages: [(String, String)] = [
    ("qingliao/Features/Sessions/SessionsView.swift", "if !isSearching { await load() }"),
    ("qingliao/Features/Workspace/WorkspaceView.swift", "await load(); await loadPending()"),
    ("qingliao/Features/Life/LifeView.swift", "await loadLife(fresh: true, queued: true)"),
    ("qingliao/Features/Dashboard/DashboardView.swift", "await refresh()"),
    ("qingliao/Features/TaskCenterView.swift", "historyTasks = await auth.fetchTaskHistory()"),
]
for (path, body) in pages {
    let name = (path as NSString).lastPathComponent
    let s = code(src(path))
    check("⑤ \(name) 挂了自绘杯子下拉刷新", s.contains(".pullRefreshCup {"))
    check("⑤ \(name) 已撤掉系统 .refreshable（互斥：并存 = 双触发 + 双指示器）",
          !s.contains(".refreshable"))
    check("⑤ \(name) 刷新闭包语义原样保留（替换动作不许把 load 换掉）",
          s.contains(body))
}

// ── 5. 反例：设置类页面本批未覆盖，不许出现杯子（防误扩散） ────────
for path in ["qingliao/Features/Settings/SettingsData.swift",
             "qingliao/Features/Settings/SettingsCommon.swift",
             "qingliao/Features/Settings/SettingsLifeCards.swift",
             "qingliao/Features/Settings/CloudDriveBrowserSheet.swift"] {
    let name = (path as NSString).lastPathComponent
    let s = code(src(path))
    check("⑥ 反例：\(name) 仍是系统 .refreshable（本批范围外，误改要在这里显式改口径）",
          s.contains(".refreshable") && !s.contains(".pullRefreshCup"))
}

print("自定义下拉刷新（液体杯子）真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
