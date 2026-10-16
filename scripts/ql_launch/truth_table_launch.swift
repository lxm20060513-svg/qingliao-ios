import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// ql_launch 真值表 —— v4.0.117「启动页三拍转场」
//
// 用户口径（2026-10-15 原话）：「轻聊 App 的启动页，Logo 放大变成进首页的门，像拉开幕布：
//   打开时背景中间是圆形 Logo，先轻轻呼吸缩放一次（约 600ms）；然后以 Logo 为圆心做圆形遮罩
//   从中间放大到铺满屏幕（约 700ms，先慢后快），首页从圆里露出来；首页内容从下往上次浮上来
//   （每块间隔约 60ms，带淡入）；全程不出现白屏、不硬切」。
// 同轮拍板：用户回「1b 2b 3b 4b」→ ② 分拍式（圆先铺满再浮起）③ 启动页只留 Logo（删两行文字）
//   ④ 呼吸 +3% ① 细粒度（hero 内部拆块）。
// 补充（2026-10-16 用户回「2」）：Logo 下加回**一行**字标「Qimo Agent」（20pt / semibold / 字距 2 /
//   与 Logo 间距 14pt，整组上下居中）—— 3b 的「只留 Logo」升级为「Logo + 一行字标」，
//   但那两行旧文字仍不许回来（见下方反例）。
//
// 本表是**纯源码护栏**（不混 SwiftUI —— 仓规：真值表只读源码/跑纯逻辑，不引 SwiftUI 编译）：
//   事故面 = 这四拍全靠**时序**串起来，任何一拍被后人「顺手简化」（把分拍改回同步、把挖洞换成淡出、
//   把新曲线换成 pageReveal、把 Index 顺序打乱）都不会有编译错、不会崩、日志也没有，
//   人眼回归极可能漏 —— 只能代码级钉死。
//
// 编译方式（纯源码，无外部依赖）：
//   swiftc -swift-version 6 main.swift -o /tmp/tt_launch
// ═══════════════════════════════════════════════════════════════════════════════

nonisolated(unsafe) var ok = 0
nonisolated(unsafe) var fail = 0
func check(_ name: String, _ cond: Bool) {
    if cond { ok += 1; print("  ✓ \(name)") } else { fail += 1; print("  ❌ \(name)") }
}

/// 仓根：优先环境变量（check_swift.sh 会钉死），兜底 cwd / 固定路径
func repoRoot() -> String {
    if let env = ProcessInfo.processInfo.environment["QL_REPO"],
       FileManager.default.fileExists(atPath: env + "/qingliao/Features/SplashView.swift") {
        return env
    }
    let cwd = FileManager.default.currentDirectoryPath
    if FileManager.default.fileExists(atPath: cwd + "/qingliao/Features/SplashView.swift") { return cwd }
    return "/opt/data/qingliao_ios"
}
func readRepo(_ rel: String) -> String {
    (try? String(contentsOfFile: repoRoot() + "/" + rel, encoding: .utf8)) ?? ""
}

let splash = readRepo("qingliao/Features/SplashView.swift")
let app = readRepo("qingliao/QingliaoApp.swift")
let sessions = readRepo("qingliao/Features/Sessions/SessionsView.swift")
let dock = readRepo("qingliao/Features/DockTabView.swift")
let motion = readRepo("qingliao/Theme/Motion.swift")

check("四个源文件都读到了（读不到 = 本表全绿也无意义）",
      !splash.isEmpty && !app.isEmpty && !sessions.isEmpty && !dock.isEmpty && !motion.isEmpty)

// ── ① 三拍的时间线常量（用户口径逐条落数字）─────────────────────────────
check("呼吸半程 = 0.3s（一呼一吸 = 0.6s，用户「约 600ms」）",
      splash.contains("static let breathHalf: Double = 0.3"))
check("呼吸幅度 = +3%（4b 口径，不是初稿的 +6%）",
      splash.contains("static let breathScale: CGFloat = 1.03") && !splash.contains("breathScale: CGFloat = 1.06"))
check("扩散时长 = 0.7s（用户「约 700ms」）",
      splash.contains("static let revealDuration: Double = 0.7"))
check("每块上浮位移 18pt / 错峰 60ms（用户「每块间隔约 60ms」）",
      splash.contains("static let riseOffset: CGFloat = 18") && splash.contains("static let riseStagger: Double = 0.06"))
check("呼吸是「张 → 收」两段串联，不是一次性赋值",
      splash.contains("breath = SplashView.breathScale") && splash.contains("breath = 1"))
if let a = splash.range(of: "breath = 1"), let b = splash.range(of: "withAnimation(Motion.launchReveal)") {
    check("呼吸完**再**起扩散（时间轴上 guard + sleep 串起来，不是同拍并发）", a.lowerBound < b.lowerBound)
} else {
    check("呼吸完**再**起扩散（要素缺失：呼吸收回 或 扩散起点）", false)
}

// ── ② 扩散：挖洞遮罩 + Logo 圆心 + 新曲线 ────────────────────────────────
check("遮罩是「挖洞」形状 RevealHoleShape（不是整层淡出）",
      splash.contains("RevealHoleShape(center: localCenter, radius: revealRadius)"))
check("挖洞靠 eoFill 才真挖得动（少了它圆和矩形同向 = 整层不透明，遮罩形同不存在）",
      splash.contains("FillStyle(eoFill: true)"))
check("遮罩挂在启动页本层（mask），底下的首页因此一直渲染着（「不白屏」的根）",
      splash.contains(".mask(") && splash.contains("RevealHoleShape("))
check("半径起点 = 0（开场整层盖住，不会有半帧白屏/硬切）",
      splash.contains("@State private var revealRadius: CGFloat = 0"))
check("半径终点 = Motion.pageRevealMaxRadius（与 dock 切页共用同一枚最大半径常量）",
      splash.contains("withAnimation(Motion.launchReveal) { revealRadius = Motion.pageRevealMaxRadius }"))
check("曲线用 Motion.launchReveal（.easeIn「先慢后快」），**不是** pageReveal（.smooth 首尾对称）",
      splash.contains("withAnimation(Motion.launchReveal) { revealRadius") &&
      !splash.contains("withAnimation(Motion.pageReveal) { revealRadius"))
check("圆心取**实测 Logo 中心**（不是写死屏幕中心）：logoGlobal 由 GeometryReader 量",
      splash.contains("logoGlobal = SplashView.center(of: proxy.frame(in: .global))"))
check("圆心做 window → 本层局部换算（不减 pageOrigin 会偏一个安全区，dock 侧同款坑）",
      splash.contains("CGPoint(x: logoGlobal.x - pageOrigin.x, y: logoGlobal.y - pageOrigin.y)"))

// ── ③ 铺满才放行（2b 分拍式的落点）──────────────────────────────────────
// 从「起扩散」那一行往后切：reduceMotion 分支里还有一个更早的 onRevealed?()，不能拿它当基准
if let seg = splash.range(of: "withAnimation(Motion.launchReveal)") {
    let tail = String(splash[seg.lowerBound...])
    if let s = tail.range(of: "Task.sleep(for: .seconds(SplashView.revealDuration))"),
       let c = tail.range(of: "onRevealed?()") {
        check("回调发生在扩散**之后**（先睡满 0.7s 扩散时长，再 onRevealed —— 这就是 2b 分拍式）",
              s.lowerBound < c.lowerBound)
    } else {
        check("回调发生在扩散之后（扩散起点之后缺「睡满 revealDuration」或 onRevealed）", false)
    }
} else {
    check("回调发生在扩散之后（要素缺失：扩散起点）", false)
}
check("减弱动态效果：三拍全落终态 + 立即回调（不许把动画播完才放行）",
      splash.contains("if reduceMotion {") && splash.contains("revealRadius = Motion.pageRevealMaxRadius\n            onRevealed?()"))
check("在跑的延时任务带代际令牌（视图重建后老任务不许再放行/再回调）",
      splash.contains("guard mySeq == seq else { return }"))

// ── 宿主：撤层时机 + 放行 + 兜底 ────────────────────────────────────────
check("宿主由 onRevealed 驱动撤层（不再自己按固定时长抢撤）",
      app.contains("SplashView(onRevealed: {") && app.contains("showSplash = false"))
check("回调里**同时**放行首页各块上浮",
      app.contains("launchRise = true"))
check("撤层用 .identity（遮罩已铺满，整层被挖空 → 瞬时撤零观感；改回 .opacity 淡出会重启「先白后切」）",
      app.contains(".transition(.identity)"))
check("launchRise 初值 false（首页各块先停在下方，等启动页放行）",
      app.contains("@State private var launchRise = false"))
check("DockTabView 拿到放行开关",
      app.contains("DockTabView(launchRise: launchRise)"))
check("兜底：回调链断掉时 2.4s 内强制放行 + 撤层（首页不许永远停在未上浮状态）",
      app.contains(".seconds(2.4)") && app.contains("if !launchRise { launchRise = true }"))

// ── 首页各块（1b 细粒度：6 块）──────────────────────────────────────────
let blockCount = sessions.components(separatedBy: "launchRiseBlock(").count - 1
check("SessionsView 挂了 6 个块（页头/搜索框/宠物/每日一言/卡片行/会话列表），实得 \(blockCount)",
      blockCount == 6)
check("块序号 0…5 连续无缺（缺号 = 该块永远停在未上浮态）",
      (0...5).allSatisfy { sessions.contains(".launchRiseBlock(\($0), shown: launchRise)") })
check("块序号不重复（同一序号出现两次 = 两块同拍，错峰失效）",
      (0...5).allSatisfy { sessions.components(separatedBy: ".launchRiseBlock(\($0), shown: launchRise)").count - 1 == 1 })
check("launchRise 默认 true（切 tab / 从对话页返回 / iPad 双栏这些路径直接显示，不进启动流程）",
      sessions.contains("var launchRise: Bool = true") && dock.contains("var launchRise: Bool = true"))
check("DockTabView 把开关透传给 SessionsView",
      dock.contains("launchRise: launchRise)"))
check("块修饰器 reduceMotion 直接落终态（不播位移与淡入）",
      splash.contains("let settled = shown || reduceMotion"))
check("块修饰器只做位移 + 淡入，**不**做缩放（整页缩放是回退⑯ 的禁令）",
      !splash.contains("scaleEffect(settled"))

// ── 冷启动不叠两层圆 ────────────────────────────────────────────────────
check("chatZoomEntry 新增 skipFirstEntry 开关（冷启动首帧不播整页扩散）",
      dock.contains("skipFirstEntry: !launchRise") && dock.contains("let skipFirstEntry: Bool"))
check("onAppear 只认第一帧（didAppear 守卫）—— 切页那条路走 onChange",
      dock.contains("@State private var didAppear = false") && dock.contains("guard !didAppear else { return }"))
check("skip 分支直接落终态（不是半路 enter）",
      dock.contains("if skipFirstEntry {"))

// ── 两枚令牌各管一段，不许互相顶替 ──────────────────────────────────────
check("Motion.launchReveal = .easeIn(0.7)（先慢后快，用户口径）",
      motion.contains("static var launchReveal: Animation { .easeIn(duration: 0.7) }"))
check("Motion.launchRise = .smooth(0.40)（块内位移，无回弹）",
      motion.contains("static var launchRise: Animation { .smooth(duration: 0.40) }"))
check("dock 切页那枚 pageReveal 未被顺手改掉（仍是 .smooth 0.75）",
      motion.contains("static var pageReveal: Animation { .smooth(duration: 0.75) }"))
check("两处时长同值：Motion.launchReveal 的 0.7 == SplashView.revealDuration 的 0.7",
      motion.contains(".easeIn(duration: 0.7)") && splash.contains("revealDuration: Double = 0.7"))

// ── 反例：不许回来 / 不许混用（≥ 三分之一）──────────────────────────────
// ⚠️ 断言必须认**代码形态**（Text("…")）：本文件注释里就写着「AI AGENT」这个被删项的名字，
//    裸 contains 会把注释当违规 —— 这类误伤会逼后人删掉解释性注释，比漏检更坏。
check("✅ 启动页 Logo 下方是唯一一行品牌字标「Qimo Agent」（20pt / semibold / 字距 2 / 间距 14）",
      splash.contains("Text(\"Qimo Agent\")") &&
      splash.contains("Image(\"AboutLogo\")") &&
      splash.contains("Typography.headline, weight: .semibold") &&
      splash.contains(".tracking(2)") &&
      splash.contains("VStack(spacing: 14)") &&
      // 顺序：VStack 里 Logo 在前、字标在后 → 字标落在 Logo **下方**（别被后人调成放在上面）
      splash.range(of: "Image(\"AboutLogo\")")!.lowerBound < splash.range(of: "Text(\"Qimo Agent\")")!.lowerBound)
check("🚫 3b 删掉的那两行旧文字不许回来（启动页不再有第二行文字）",
      !splash.contains("Text(\"Qimo（轻聊）\")") && !splash.contains("Text(\"AI AGENT\")"))
check("🚫 老的整页淡入/缩放入场不许回来（appeared 那套）",
      !splash.contains("appeared"))
check("🚫 启动页不许改用「留圆」形状 RevealCircleShape（那是切页的语义，方向正好相反）",
      !splash.contains("RevealCircleShape(center:"))
check("🚫 DockTabView 不许改用「挖圆」形状 RevealHoleShape（同上，反向）",
      !dock.contains("RevealHoleShape(center:"))
check("🚫 老那行 0.6s 定时撤除不许回来（会把刚起头的扩散拦腰截断）",
      !app.contains("Task.sleep(for: .seconds(0.6))"))
check("🚫 老的 withAnimation(Motion.emerge) 撤除不许回来（淡出 = 先白后切）",
      !app.contains("withAnimation(Motion.emerge) { showSplash = false }"))
check("🚫 启动页不许出现第二条并发的整页扩散（pageReveal 那条留给切页）",
      !splash.contains("Motion.pageReveal)"))
// v4.0.116（发版审查 P2）：原断言 `!contains(".opacity(0)") || contains("opacity(settled")`
// 两个分句都恒真（文件里既无字面量 .opacity(0)、又有 opacity(settled ? 1 : 0)）→ 零鉴别力：
// 真把「先淡入再扩散」加回来也判不出红。改为正面断言：
//   ① 启动页必须用「挖洞」形（第一帧就有 Logo，靠形状开洞而不是靠透明度）
//   ② 旧的整页淡出撤除不许回来
check("🚫 启动页不许出现「先淡入再扩散」的两段式开场（用户要的是第一帧就有 Logo）",
      splash.contains("RevealHoleShape(") && !splash.contains("withAnimation(Motion.emerge)"))

print("\n通过 \(ok) 项，失败 \(fail) 项")
if fail > 0 { exit(1) }
