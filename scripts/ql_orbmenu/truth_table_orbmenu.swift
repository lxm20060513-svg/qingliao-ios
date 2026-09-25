// MARK: - v3.9.59 智慧球长按快捷菜单 · 真值表（源护栏 + 纯计算回归）
//
// 护栏三件事（ql_ui 技能口径）：
//   1. 长按接线在位（ExclusiveGesture 长按优先、球命中层、菜单层挂载）
//   2. 四个动作全部复用既有入口（requestNewSession / MemoStore / toggleVoiceMode 通知 / TodoStore）
//   3. 旧形态清零（DockOrbOverlay 的 allowsHitTesting(false) 仍在——视觉层不抢事件）
// 纯计算：胶囊弧线落点几何（角度→坐标、错峰延迟表）本机可算，断言在合理范围。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

let root = "qingliao"
func src(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: "\(root)/\(path)", encoding: .utf8) else { return "" }
    return s
}

let widgetSrc = src("../qingliaoWidget/QingliaoLiveActivityWidget.swift")
let orbMenuSrc = src("Features/OrbQuickMenu.swift")
let dockSrc = src("Features/DockTabView.swift")
let chatViewSrc = src("Features/Chat/ChatView.swift")
let chatEffectsSrc = src("Features/Chat/ChatEffects.swift")

// ── 源护栏：非空 ─────────────────────────────────────────────
check("OrbQuickMenu.swift 源可读", !orbMenuSrc.isEmpty)
check("DockTabView.swift 源可读", !dockSrc.isEmpty)
check("ChatView.swift 源可读", !chatViewSrc.isEmpty)
check("ChatEffects.swift 源可读", !chatEffectsSrc.isEmpty)

// ── 0. 球心几何单一真源（命中圈 / 菜单弧心 / 可见球必须同源） ─────
// 背景：DockOrbOverlay 的球心 x 优先取**真实槽位按钮中心**（slotCenterGlobal），y 是几何定位；
// 命中层若自己写一份 width*(i+0.5)/n 等分估算，iOS 26 玻璃 tab bar 内容内缩时圈就偏 → 按球没反应。
check("ChatEffects 提供全局球心 orbCenterGlobal", chatEffectsSrc.contains("static func orbCenterGlobal("))
check("orbCenterGlobal 的 x 优先真实槽位中心", chatEffectsSrc.contains("slotCenterGlobal(index: slotIndex, count: slotCount)?.x"))
check("orbCenterGlobal 的 y 与可见球同一条几何公式（内容差值同源，别各写一份）",
      chatEffectsSrc.contains("let drop = contentCenterDrop(index: slotIndex, count: slotCount)")
      && chatEffectsSrc.contains("keyWindowHeight - keyWindowSafeBottom - barH / 2 + drop"))
// v3.9.79（用户横屏报修「智慧球在 dock 里上下没居中」）：内容差值必须**按当前朝向实测**，
// 写死的 6.3 只是竖屏量出来的兜底值 —— 横屏 tab bar 紧凑形态下差值≈0。
check("dock 内容差值按朝向实测（6.3 只当兜底）",
      chatEffectsSrc.contains("static func slotContentDrop(index: Int, count: Int) -> CGFloat?")
      && chatEffectsSrc.contains("static func contentCenterDrop(index: Int = 2, count: Int = 5) -> CGFloat")
      && chatEffectsSrc.contains("if let d = slotContentDrop(index: index, count: count) { return d }")
      && chatEffectsSrc.contains("let shortScreen = keyWindow?.traitCollection.verticalSizeClass == .compact"))
// 审查① 实测指出：可见球曾用 @State liveDrop 缓存，命中层走实时值 → 转屏后 0.15s 窗口内差 6.3pt
// =「球看着在那儿、按上去没反应」。口径固定为：**五处几何全部调同一个 contentCenterDrop，任何一处都不许缓存**。
check("几何差值单一出口：可见球 / 球心 / 烟花原点都走 contentCenterDrop，且源里不许再有缓存状态",
      chatEffectsSrc.contains("let drop = DockOrbOverlay.contentCenterDrop(index: slotIndex, count: slotCount)")
      && chatEffectsSrc.contains("let drop = contentCenterDrop(index: slotIndex, count: slotCount)")
      && chatEffectsSrc.contains("barHeight / 2 - contentCenterDrop(index: index, count: count)")
      && !chatEffectsSrc.contains("@State private var liveDrop")
      && !chatEffectsSrc.contains("latestDrop")
      && !chatEffectsSrc.contains("barH / 2 + dockContentCenterDrop"))
check("命中层走 orbCenterGlobal", orbMenuSrc.contains("DockOrbOverlay.orbCenterGlobal(slotIndex: slotIndex"))
check("命中层 + 菜单层两处共用（出现 2 次）",
      orbMenuSrc.components(separatedBy: "DockOrbOverlay.orbCenterGlobal(").count - 1 == 2)
check("旧的手算等分几何已清零", !orbMenuSrc.contains("geo.size.width * (CGFloat(slotIndex) + 0.5)"))
check("DockOrbOverlay 仍是唯一几何源（body 里 position 用 target）", chatEffectsSrc.contains("target: CGPoint = CGPoint(x: liveCenter.map { $0.x - g.minX }" ))

// ── 1. 手势接线（ExclusiveGesture 口径，长按优先） ─────────────
check("球命中层存在", orbMenuSrc.contains("struct OrbHitLayer: View"))
check("长按+轻点用 ExclusiveGesture（分开挂会补认 tap，v2.0.107 实踩）",
      orbMenuSrc.contains("ExclusiveGesture(") && orbMenuSrc.contains("LongPressGesture(minimumDuration: 0.45)"))
check("DockTabView 挂了球命中层", dockSrc.contains("OrbHitLayer(barHeight: dockBarHeight"))
// v3.9.76：条件扩成「菜单 / 识别浮层 / 语音对话页都不在」——三层都要模态接管，缺一个就是两层抢触摸
check("菜单开着时命中层隐藏（菜单层模态接管）",
      dockSrc.contains("if !showOrbMenu && !showIdentify && !showVoiceDialog {") && dockSrc.contains("OrbHitLayer"))
check("长按触感 press", dockSrc.contains("Haptics.press()") )

// ── 2. 四个动作复用既有入口 ──────────────────────────────────
check("新建会话走 requestNewSession（两步走，勿直接清数据）",
      dockSrc.contains("chat.requestNewSession()"))
check("AI 速记走 MemoStore.add", orbMenuSrc.contains("MemoStore.shared.add(content: content, source: \"orb\")"))
check("今日待办走 TodoStore.add", orbMenuSrc.contains("TodoStore.shared.add(content: content, source: \"orb\")"))
check("语音输入走进程内通知（DockTabView 摸不到 ChatView @State）",
      dockSrc.contains(".qingliaoOrbVoiceInput") && chatViewSrc.contains(".qingliaoOrbVoiceInput"))
check("ChatView 消费通知后走 toggleVoiceMode（与输入框长按同一路径）",
      chatViewSrc.contains("toggleVoiceMode(keyboardWasUp: kb.isVisible)"))
check("通知名已注册", chatViewSrc.contains("static let qingliaoOrbVoiceInput = Notification.Name(\"qingliao_orb_voice_input\")"))

// ── 3. 菜单层形态（A+C 方案定稿护栏） ─────────────────────────
check("菜单浮层挂在 DockTabView", dockSrc.contains("OrbQuickMenuOverlay(barHeight: dockBarHeight"))
check("速记弹窗 sheet(item:) 挂载", dockSrc.contains(".sheet(item: $quickCapture,"))   // 后面还跟着 onDismiss 复位
// 🚨 v3.9.77 **用户口径推翻方案 C 的「不做全屏磨砂」**（原话：「这个背景上下白，中间灰，改全半模糊效果」）。
//   旧形态 `Color.black.opacity(0.12)` 既不模糊、又没铺安全区 → 上下露原页面、中间一条灰纱（用户看到的就是这个）。
//   现在必须是**整屏材质模糊 + 铺满安全区**。**别照旧定稿改回去。**
check("遮罩 = 全屏半透明模糊（ultraThinMaterial 铺满安全区）",
      orbMenuSrc.contains("Rectangle().fill(.ultraThinMaterial)") && orbMenuSrc.contains(".ignoresSafeArea()"))
check("旧的纯色黑纱已清零（无模糊、没铺满的形态）",
      !stripCommentLines(orbMenuSrc).contains("Color.black.opacity(shown ? 0.12 : 0)"))
check("绽放动效 = 从球心弹射（initial 位置 = 球心）+ 错峰入场",
      orbMenuSrc.contains(".position(reduceMotion ? p : (shown ? p : ballCenter))")
      && orbMenuSrc.contains(".delay(Double(index) * 0.05)"))
check("球心光晕（C 元素）在位", orbMenuSrc.contains("RadialGradient"))
check("减弱动态效果：读系统 accessibilityReduceMotion（全仓环境值口径，别自造开关）",
      orbMenuSrc.contains("@Environment(\\.accessibilityReduceMotion)"))
check("减弱动态效果：胶囊原地淡入（不做从球心弹射落位）",
      orbMenuSrc.contains("reduceMotion ? Motion.tap")
      && orbMenuSrc.contains(".position(reduceMotion ? p : (shown ? p : ballCenter))"))
check("减弱动态效果：装饰性扩散环不渲染", orbMenuSrc.contains("if !reduceMotion {"))

// ── 4. 视觉层不抢事件（穿透铁律不被破坏） ─────────────────────
// ⚠️ 断言必须**切片**：整文件 grep ".allowsHitTesting(false)" 会被 FullScreenBurst 那处（烟花层，
// DockTabView 里同款串）假绿——删掉球层那一处，断言照样通过。只查球 overlay 那一段。
let orbOverlaySlice: String = {
    guard let a = dockSrc.range(of: "DockOrbOverlay(slotIndex: 2"),
          let b = dockSrc.range(of: "长按球快捷菜单浮层", range: a.upperBound..<dockSrc.endIndex)
    else { return "" }
    return String(dockSrc[a.lowerBound..<b.lowerBound])
}()
check("球 overlay 片段可截取（哨兵：截不到就是文件结构变了，护栏要跟着改）", !orbOverlaySlice.isEmpty)
check("可见球层仍 allowsHitTesting(false)（球面触摸归命中层/系统 tab item）",
      orbOverlaySlice.contains(".allowsHitTesting(false)"))
check("命中层挂在可见球之后（同 overlay 内后挂者在上，才拿得到触摸）",
      orbOverlaySlice.contains("OrbHitLayer(barHeight: dockBarHeight"))

// ── 5. 纯计算回归：胶囊落点几何（v3.9.60 两排两列 —— 本次 bug 正题） ──
// 镜像 OrbQuickMenuLayout（第 7 节 ③ 用源护栏钉住字面量，源改了这里必须同步改）
let pillW = 101.0, pillH = 36.0            // 胶囊尺寸估值（令牌算式见 OrbQuickMenuLayout.pillSize 注释）
let columnDX = 118.0, upperDY = 160.0, lowerDY = 104.0   // v3.9.76：一排 2 颗 → 3 颗

// 🔒 反向绑定：上面的「镜像常量」必须等于 OrbQuickMenuLayout 里的真值 —— 否则源改了表照样绿（假护栏）
func parseCGSize(_ s: String, _ marker: String) -> (Double, Double)? {
    guard let r = s.range(of: marker) else { return nil }
    var rest = Substring(s[r.upperBound...])
    guard let w = Double(rest.prefix { $0.isNumber || $0 == "." }),
          let hR = rest.range(of: ", height: ") else { return nil }
    rest = rest[hR.upperBound...]
    guard let h = Double(rest.prefix { $0.isNumber || $0 == "." }) else { return nil }
    return (w, h)
}
func parseNumber(_ s: String, _ marker: String) -> Double? {
    guard let r = s.range(of: marker) else { return nil }
    return Double(Substring(s[r.upperBound...]).prefix { $0.isNumber || $0 == "." })
}
let srcPill = parseCGSize(orbMenuSrc, "static let pillSize = CGSize(width: ")
let srcBreath = parseNumber(orbMenuSrc, "static let minGapAboveBall: CGFloat = ")
check("表内 pillW/pillH 与源码 pillSize 同源（源改了这里必红）",
      srcPill?.0 == pillW && srcPill?.1 == pillH)
check("表内呼吸间距与源码 minGapAboveBall 同源（74pt）", srcBreath == 74)
let breathGap = srcBreath ?? 74
func center(_ index: Int) -> (x: Double, y: Double) {
    let i = ((index % 6) + 6) % 6
    let col = Double(i % 3) - 1                 // −1 / 0 / +1
    let isUpper = i >= 3
    return (col * columnDX, -(isUpper ? upperDY : lowerDY))
}
let pts = (0..<6).map { center($0) }

// ① 四颗落点互不相同（曾出现两颗重合 = 视觉上压在一起）
check("六颗胶囊落点互不相同", Set(pts.map { String($0.x) + "," + String($0.y) }).count == 6)
// ② 两两不重叠（AABB：横向或纵向任一方向分开即不重叠）
func overlaps(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Bool {
    abs(a.x - b.x) < pillW && abs(a.y - b.y) < pillH
}
var overlapPairs: [String] = []
for i in 0..<6 {
    for j in (i + 1)..<6 where overlaps(pts[i], pts[j]) {
        overlapPairs.append(String(i) + "-" + String(j))
    }
}
check("六颗胶囊两两不重叠（AABB）", overlapPairs.isEmpty)
// ③ 最小间隙 ≥ 12pt（不重叠还不够——贴在一起观感仍是糊成一团）
let hGap = columnDX - pillW                // 同排相邻水平间隙（一排 3 颗）
let vGap = upperDY - lowerDY - pillH       // 两排纵向间隙
check("同排水平间隙 ≥ 12pt", hGap >= 12)
check("两排纵向间隙 ≥ 12pt", vGap >= 12)
// ④ 屏内（最小 iPhone 宽度 375pt 兜底；球心 y = 屏底往上 安全区 + tab bar 一半）
let screenW = 375.0, screenH = 667.0, safeBottom = 34.0, barH = 49.0
let ball = (x: screenW / 2, y: screenH - safeBottom - barH / 2)
let halfW = pillW / 2, halfH = pillH / 2
for (i, p) in pts.enumerated() {
    check("胶囊左右不越界（#" + String(i) + "）",
          ball.x + p.x - halfW >= 8 && ball.x + p.x + halfW <= screenW - 8)
    check("胶囊上缘不越界（#" + String(i) + "）", ball.y + p.y - halfH >= 8)
}
// ⑤ 不压球：下排胶囊底边到球心 ≥ 球半径(34) + 呼吸(40) = minGapAboveBall（与源码同源，见上）
for (i, p) in pts.enumerated() {
    check("胶囊在球上方留有呼吸（#" + String(i) + "）", -(p.y + halfH) >= breathGap)
}
// ⑥ 🚨 事故证据：旧「弧线散开」公式必须算出重叠 —— 否则第 ② 条只是空真（从没复现过原 bug）
func oldOffset(_ deg: Double) -> (x: Double, y: Double) {
    let a = deg * Double.pi / 180
    let r = 106 + abs(deg) / 57 * 30
    return (sin(a) * r, -cos(a) * r)
}
let oldInnerGap = abs(oldOffset(19).x - oldOffset(-19).x)
let oldRowGap = abs(oldOffset(-19).y - oldOffset(-57).y)
check("旧弧线内侧中心距 < 胶囊宽（横向重叠 = 事故证据）", oldInnerGap < pillW)
check("旧弧线内外排纵向差 < 胶囊高（上下贴合 = 事故证据）", oldRowGap < pillH)
// ⑦ 错峰延迟单调（50ms 步进）——⚠️ 不能直接 == [0,0.05,0.10,0.15]：0.05*3 二进制不精确
// （= 0.15000000000000002）会假红，必须用单调 + 容差断言。
let delays = (0..<6).map { Double($0) * 0.05 }
check("错峰延迟单调递增（50ms 步进）",
      zip(delays, delays.dropFirst()).allSatisfy { $1 > $0 }
      && abs(delays[5] - 0.25) < 1e-9)

// ⑧ v3.9.80：锚点是宠物时整组镜像到**宠物下方**（用户截图口径：「这个界面胶囊弹出放在卡通宠物下方」）──
// 镜像判据：x 逐点不变（横向排布不动）、y = 向上版的相反数。近排仍是 index 0-2。
func centerBelow(_ index: Int) -> (x: Double, y: Double) {
    let i = ((index % 6) + 6) % 6
    let col = Double(i % 3) - 1
    let isUpper = i >= 3
    return (col * columnDX, (isUpper ? upperDY : lowerDY))
}
let ptsBelow = (0..<6).map { centerBelow($0) }
check("镜像后 x 与向上版逐点一致（只翻方向，不改横向排布）",
      zip(pts, ptsBelow).allSatisfy { $0.x == $1.x })
check("镜像后 y = 向上版的相反数（整组落到锚点下方）",
      zip(pts, ptsBelow).allSatisfy { $0.y == -$1.y })
check("镜像后六颗仍两两不重叠（AABB）", {
    for i in 0..<6 { for j in (i + 1)..<6 where overlaps(ptsBelow[i], ptsBelow[j]) { return false } }
    return true
}())
// 宠物锚点位置（欢迎页竖屏）：顶部安全区 59 + 弹性留白 ≤120 + 宠物半径 48 → 最靠上的球心 y = 227
// 宠物半径按 96pt 身份尺寸算（ChatView：`PetAvatar(size: 96`）——比 dock 球（半径 34）大一倍。
let petRadius = 48.0
let petBallY = 59.0 + 120.0 + petRadius
for (i, p) in ptsBelow.enumerated() {
    check("镜像后胶囊不压宠物本体（#" + String(i) + "）", p.y - halfH >= petRadius)
    check("镜像后与宠物留视觉呼吸 ≥ 24pt（#" + String(i) + "）", p.y - halfH - petRadius >= 24)
    check("镜像后胶囊下缘在输入栏之上（#" + String(i) + "，输入栏顶 ≈ 屏高 852 − 安全区 34 − 输入栏 120）",
          petBallY + p.y + halfH <= 852 - 34 - 120)
}

// ── 6. 速记弹窗口径 ─────────────────────────────────────────
check("弹窗背景不覆盖（系统默认玻璃底，全站口径）",
      !orbMenuSrc.contains("presentationBackground") && !orbMenuSrc.contains(".systemBackground"))
check("空内容不可保存", orbMenuSrc.contains(".disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)"))
check("保存成功有触感", orbMenuSrc.contains("Haptics.success()"))

// ── 7. 输入框上移：速记弹窗内容沉底改贴顶（用户反馈「观感不协调」）────
// 形态护栏：断言「贴顶 + 按钮前有 Spacer」这个新布局特征，防止回退成垂直居中。
// 注：sheet 内容默认居中，靠 frame(alignment: .top) 贴顶；Spacer 在按钮前把操作区压到底。
check("速记弹窗内容贴顶（frame maxHeight + .top）",
      orbMenuSrc.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"))
check("内容分隔 Spacer 紧跟按钮组 HStack（贴顶+操作区沉底的形态证据）",
      orbMenuSrc.contains("            Spacer()\n            HStack(spacing: Spacing.lg) {"))
check("Spacer 总数 = 2（内容分隔 + 按钮组左推）",
      orbMenuSrc.components(separatedBy: "Spacer()").count - 1 == 2)

// ── 8. 发版前双审查修复的护栏（v3.9.59） ─────────────────────
// 本节每条都绑定源码字面量：改一侧不改另一侧就红。都是「旧护栏拦不住、但真出过或极易出」的回归点。
let memoSrc = src("Core/MemoStore.swift")
let todoSrc = src("Core/TodoStore.swift")
check("MemoStore.swift 源可读", !memoSrc.isEmpty)
check("TodoStore.swift 源可读", !todoSrc.isEmpty)

// ① 命中域：Color.clear / 半透明遮罩不补 contentShape 就点不到（本仓已知坑）
check("命中圈补了 contentShape(Circle())", orbMenuSrc.contains(".contentShape(Circle())"))
check("轻纱补了 contentShape(Rectangle())（点空白收起靠它）", orbMenuSrc.contains("contentShape(Rectangle())"))
// ② 可点玻璃胶囊走 .regular.interactive()（Pill.swift 定版；裸 glassEffect 是静态卡口径，无按压反馈）
check("可点胶囊走 glassEffect(.regular.interactive())", orbMenuSrc.contains("glassEffect(.regular.interactive())"))
// ③ 落点几何与源码字面量绑定（第 5 节是镜像计算，源码改了必须同步改表）
check("落点常量与源码绑定（columnDX / upperDY / lowerDY）",
      orbMenuSrc.contains("static let columnDX: CGFloat = 118")
      && orbMenuSrc.contains("static let upperDY: CGFloat = 160")
      && orbMenuSrc.contains("static let lowerDY: CGFloat = 104"))
check("落点单一真源 = OrbQuickMenuLayout.center（方向作为参数传入，不在调用点手写加减）",
      orbMenuSrc.contains("OrbQuickMenuLayout.center(index: index, ballCenter: ballCenter, below: pillsBelow)"))
check("取模防越界（胶囊数量再变也不崩）", orbMenuSrc.contains("let i = ((index % 6) + 6) % 6"))
// 🔒 公式级反向绑定（v3.9.76 反向自证抓到）：第 5 节的落点回归是**表内镜像计算**，
//    只绑常量字面量时，把源码取模从 %6 改回 %4（四颗重叠的老 bug）仍能让落点断言全绿 ——
//    必须把公式本身也钉住，镜像回归才有意义。
check("落点公式与源码绑定（%6 取模 · 每排 3 列 · 上排 = i >= 3）",
      orbMenuSrc.contains("let i = ((index % 6) + 6) % 6")
      && orbMenuSrc.contains("let col = CGFloat(i % 3) - 1")
      && orbMenuSrc.contains("let isUpper = i >= 3"))
// ③′ 🚨 旧「角度散开」实现必须清零（四颗胶囊重叠的根因；断言带声明形态的串，别断言裸符号名）
check("旧角度表已删除", !orbMenuSrc.contains("private static let angles: [Double]"))
check("旧角度取模已删除", !orbMenuSrc.contains("Self.angles[index % Self.angles.count]"))
check("旧半径公式已删除", !orbMenuSrc.contains("106 + abs(deg) / 57 * 30"))
// ④ 速记弹窗：onDismiss 复位（present 被别的 sheet 挡掉后 detail 恒非 nil → 之后再也打不开）
check("速记弹窗 onDismiss 复位", dockSrc.contains("onDismiss: { quickCapture = nil }"))
check("速记弹窗与全站同档 detents", orbMenuSrc.contains(".presentationDetents([.medium, .large])"))
check("主操作走 pill(.primary, tone: .accent) 统一出口",
      orbMenuSrc.contains("Text(\"保存\").pill(.primary, tone: .accent)") && !orbMenuSrc.contains("borderedProminent"))
// ⑤ 菜单随切页收起（深链 / 分享 / 备忘录「发给 AI」等程序化切页不留残影）
check("切页时收起菜单", dockSrc.contains("if showOrbMenu { showOrbMenu = false }"))
// ⑥ 已在聊天页时轻点球要有反馈（selected 不变 → onChange 不触发，触感/清提示会整体丢失）
check("轻点球语义补齐（已在聊天页补触感 + 清提示）",
      dockSrc.contains("if selected == .chat { Haptics.tap(); clearOrbNotice() }"))
check("程序化切页前的 skipBurstOnce 加守卫（避免标志空置吞掉下一次真点击烟花）",
      dockSrc.contains("if selected != .chat { skipBurstOnce() }"))
// ⑦ 来源标注：source "orb" 不补分支会显示成「手记 / 手动」，与手动条目无法区分
check("备忘录来源标注认 orb", memoSrc.contains("case \"orb\": return \"智能球\""))
check("待办来源标注认 orb", todoSrc.contains("case \"orb\": return \"智能球\""))
check("来源图标认 orb", memoSrc.contains("case \"orb\": return \"circle.dashed\"")
      && todoSrc.contains("case \"orb\": return \"circle.dashed\""))

// MARK: - v3.9.61 锁屏横幅「液态玻璃」观感 · 源护栏
//
// 硬约束（Apple 官方口径，已核实）：
//   灵动岛三态背景不可自定义；锁屏横幅只有 activityBackgroundTint（纯色+透明度）。
//   所以玻璃层是自绘的「伪玻璃」，且只能加在锁屏横幅，不能加到岛上。
// 本例事故证据 = 改动前的死黑平涂 tint 0.35（不透壁纸 = 没有玻璃可能）。

check("横幅源码可读", !widgetSrc.isEmpty)

// ① tint 必须降到透得出壁纸的档位（玻璃的前提）
check("横幅 tint 0.35 → 0.18（透出锁屏壁纸，玻璃的前提）",
      widgetSrc.contains(".activityBackgroundTint(Color.black.opacity(0.18))"))
check("旧死黑 tint 0.35 已清零", !widgetSrc.contains("opacity(0.35))"))

// ② 玻璃层三件套在横幅上（亮边高光 / 0.8pt 白描边 / 内侧柔光）
check("横幅挂了自绘玻璃层", widgetSrc.contains(".background(alignment: .top) { self.bannerGlass }"))
check("玻璃层 = 独立计算属性（不给灵动岛用）", widgetSrc.contains("private var bannerGlass: some View"))
check("边缘细亮线 0.8pt 白描边（全站玻璃卡同口径）",
      widgetSrc.contains("RoundedRectangle(cornerRadius: 10, style: .continuous)")
      && widgetSrc.contains(".strokeBorder(Color.white.opacity(0.15), lineWidth: 0.8)"))
check("顶部亮边高光（环境光在玻璃上缘的亮带）",
      widgetSrc.contains("Color.white.opacity(0.07), Color.clear"))
check("内侧柔光在（上下内缘漫射）",
      widgetSrc.contains("Color.white.opacity(0.05), Color.clear")
      && widgetSrc.contains("Color.clear, Color.white.opacity(0.04)"))
// 🚨 v3.9.72：改成**切片式**——原来断的是整文件「存在 .allowsHitTesting(false)」，
// 而岛内新增的 expandedGlass 也带它 → 从"唯一提供者"变成"两处之一"= 假绿：
// 把横幅那一处删掉（横幅会重新抢触摸、widgetURL 点不动）断言照样绿。
let glassSlice: String = {
    guard let a = widgetSrc.range(of: "private var bannerGlass"),
          let b = widgetSrc.range(of: "// MARK: - 轻聊球") else { return "" }
    return String(widgetSrc[a.lowerBound..<b.lowerBound])
}()
check("横幅玻璃层切片可切出（空了就是空真）", !glassSlice.isEmpty)
check("玻璃层不抢触摸（横幅本身可点，见 widgetURL）", glassSlice.contains(".allowsHitTesting(false)"))

// ③ 内容投在玻璃上的层影（玻璃有厚度；缺了它就是一张贴纸）
check("横幅内容有层影", widgetSrc.contains(".shadow(color: .black.opacity(0.22), radius: 6, y: 2)"))

// ④ 灵动岛不能被这套自绘层污染（官方：岛内背景不可改；且挂件无连续帧源）
//    切片必须止于「锁屏横幅」之前——岛的代码在横幅上面，直接切到文件尾会把横幅的
//    bannerGlass/shadow 一起圈进来（本轮就这样假红过一轮），所以闭合处对齐下一段标记。
let islandSlice: String
if let start = widgetSrc.range(of: "dynamicIsland: { context in"),
   let end = widgetSrc.range(of: "private func lockScreenBanner(") {
    islandSlice = String(widgetSrc[start.lowerBound..<end.lowerBound])
} else {
    islandSlice = ""
}
check("dynamicIsland 段可切出（切片空了本条就是空真）", !islandSlice.isEmpty)
// 排除式断言要排除「调用/声明形态」，不能排除裸符号名——否则会被文档注释与同名柔光绊倒
// （本轮教训：bannerGlass 命中在横幅自己的文档注释上、.shadow( 命中 phaseRing 的固有柔光）。
check("岛内三态未挂 bannerGlass（玻璃只做锁屏横幅）",
      !islandSlice.contains("self.bannerGlass") && !islandSlice.contains("var bannerGlass"))
check("岛内三态未挂投影层（phaseRing 的柔光 .shadow(color: tint...) 是固有项，不属投影）",
      !islandSlice.contains(".shadow(color: .black"))

// ⑤ 展开态停止按钮：v3.9.72 从 glassEffect **回退**成自绘胶囊（用户真机报「展开态胶囊不显示内容」）
// 老护栏（v3.9.61）写的是「小元素上 glassEffect 在挂件里可渲染（装机确认）」——已被真机截图推翻：
// 岛上只剩一圈描边、连字都没有 = 按钮本体整块没渲染，而 .overlay 的描边是独立图层照旧画。
// ⚠️ 别再照老护栏把这里改回 glassEffect：岛内玻璃感只能靠静态图层自绘。
let stopBtnSlice: String = {
    guard let a = widgetSrc.range(of: "private var stopButton"),
          let b = widgetSrc.range(of: "/// v3.9.10：右侧阶段指示改为") else { return "" }
    return String(widgetSrc[a.lowerBound..<b.lowerBound])
}()
/// 取两段锚点之间的切片（任一锚点不存在就返回空串 → 由调用方断言非空，避免"空了就是空真"）。
func between(_ s: String, _ a: String, _ b: String) -> String {
    guard let ra = s.range(of: a), let rb = s.range(of: b, range: ra.upperBound..<s.endIndex) else { return "" }
    return String(s[ra.upperBound..<rb.lowerBound])
}

// 排除式断言先去注释：本仓已两次被「注释里写着旧写法」绊成假红/假绿
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}
check("停止按钮切片可切出（切片空了本条就是空真）", !stopBtnSlice.isEmpty)
check("停止按钮不再调用 glassEffect（岛内不渲染）", !stripCommentLines(stopBtnSlice).contains("glassEffect"))
check("停止按钮走自绘淡底（accent 0.22）", stopBtnSlice.contains("OrbPalette.accent.opacity(0.22)"))
check("停止按钮带顶部亮边高光", stopBtnSlice.contains("LinearGradient(stops:"))
check("停止按钮描边与 pill(.accent) 同参（accent 0.28 / 0.8pt）",
      stopBtnSlice.contains("Capsule().strokeBorder(OrbPalette.accent.opacity(0.28), lineWidth: 0.8)"))

// ⑥ v3.9.72 展开态底部玻璃底衬（自绘：activityBackgroundTint 官方只管锁屏横幅，岛内无材质接口）
check("展开态底部有自绘玻璃底衬定义", widgetSrc.contains("private var expandedGlass"))
check("底衬挂在 expandedBottom 上", widgetSrc.contains(".background(alignment: .top) { self.expandedGlass }"))
// 🚨 v3.9.72 审查修正：底衬**刻意不画描边**。横幅 bannerGlass 能用 `RoundedRectangle(radius: 10)`
// 是因为它铺满锁屏横幅**整张卡**（卡面圆角就是 10）；岛内 `.bottom` 只是岛的一块区域，外面还有系统
// 自己的大圆角遮罩 —— 在岛内画 radius 10 的小圆角描边，真机上更可能看到「岛里又套了个小方框 + 一条横线」
// 而不是底衬。所以只做上缘高光 + 内侧柔光，要不要补边线等真机看过再定。
let expandedGlassSlice: String = {
    // ⚠️ 终点取「下一个声明」而不是 lockScreenBanner：落到横幅会把 stopButton 的 accent 描边
    // （合法，与底衬无关）一起切进来 → 断言假红（实测踩到）。
    guard let a = widgetSrc.range(of: "private var expandedGlass"),
          let b = widgetSrc.range(of: "private var stopButton") else { return "" }
    return String(widgetSrc[a.lowerBound..<b.lowerBound])
}()
check("底衬切片可切出（空了就是空真）", !expandedGlassSlice.isEmpty)
check("底衬只做上缘高光（白 0.12 渐隐）", expandedGlassSlice.contains("Color.white.opacity(0.12), Color.clear"))
check("底衬不画小圆角描边（审查：与系统大圆角错位）",
      !stripCommentLines(expandedGlassSlice).contains("strokeBorder")
      && !stripCommentLines(expandedGlassSlice).contains("RoundedRectangle"))

// ⑦ v3.9.72：**整个挂件文件**都不许出现 glassEffect / Material（规则级护栏）
// 真机结论：挂件 / Live Activity 进程拿不到背景采样 → 这类层整块不渲染，只剩描边（= 空胶囊）。
// 之前这条规则只被 ⑤ 的 stopButton 切片守着，别处（横幅/新形态/未来 widget）加玻璃没人拦。
// ⚠️ 必须先剥注释行：本文件注释里为说明事故会出现 "glassEffect" / "Material" 字样，直接 contains 会假红。
check("挂件代码里没有 glassEffect（岛内一律自绘）", !stripCommentLines(widgetSrc).contains("glassEffect"))
check("挂件代码里没有 Material（同上）", !stripCommentLines(widgetSrc).contains("Material"))

// ⑧ v3.9.79：灵动岛图标跟随卡通形象 + 右侧环 → 进度条（用户 2026-09-25 两条真机要求）
//
// 用户原话：「加改一条，灵动岛球图标跟随卡通形象动态图」/「灵动岛右边的圈圈也改成进度条」。
// 这一节钉住的都是「改起来容易、回归起来没感觉」的点：
//   a) 形象必须由 `ContentState.petStyle` 下发 —— 挂件读不到主 App 的 UserDefaults（免费签名无 App Groups）
//   b) 形象画法复用主 App 的 PetPainter —— 挂件里另抄一套造型 = 两处造型必然分叉
//   c) 动效只随数据更新 —— 往实时活动塞自走帧源是历史事故（「动几下就不动了」）
//   d) 进度条高光必须折返 —— 取余到 1 会瞬跳回 0，白块每轮倒着闪（环时代审查踩过）
//   e) 挂件 target 源码清单 —— 漏一个文件本机预检照样全绿，只有 CI Archive 会红（典型假绿）
let attributesSrc = src("Core/LiveActivityAttributes.swift")
let managerSrc = src("Core/LiveActivityManager.swift")
let projectSrc = src("../project.yml")
let islandIconCount = islandSlice.components(separatedBy: "PetOrbView(size:").count - 1
check("灵动岛三处图标都是卡通形象（展开 36 / 紧凑 27 / 极简 24）",
      islandIconCount == 3
      && islandSlice.contains("PetOrbView(size: 36,")
      && islandSlice.contains("PetOrbView(size: 27,")
      && islandSlice.contains("PetOrbView(size: 24,"))
// ⚠️ 不能用 contains("OrbView(")：`PetOrbView(` 本身就含这个子串（实测假红）。用「减去 Pet 前缀」的计数。
let islandPlainOrbCalls = stripCommentLines(islandSlice).components(separatedBy: "OrbView(").count
    - stripCommentLines(islandSlice).components(separatedBy: "PetOrbView(").count
check("全挂件已无 OrbView 调用（球体视图整块退役；横幅也画形象）",
      islandPlainOrbCalls == 0
      && stripCommentLines(widgetSrc).components(separatedBy: "OrbView(").count
         - stripCommentLines(widgetSrc).components(separatedBy: "PetOrbView(").count == 0
      && widgetSrc.contains("PetOrbView(size: 46, styleRaw: state.petStyle"))
check("形象走共享矢量绘制（PetPainter），挂件不另抄造型",
      widgetSrc.contains("PetPainter(style: style,"))
let petOrbSlice = between(widgetSrc, "struct PetOrbView: View {", "/// 轻聊球调色板")
check("PetOrbView 切片可切出（空了本条就是空真）", !petOrbSlice.isEmpty)
// 实参**顺序**要按声明逐字对齐（本仓最贵的失败类型，只有 CI Archive 会暴露）。
// ⚠️ 不能用「逐个标签 contains」：那样把 state/blink 换序照样绿（反向自证实测）——必须断言有序片段。
let iBlink = petOrbSlice.range(of: "blink: false,")
let iSimplify = petOrbSlice.range(of: "simplify: size < PetKeys.simplifyBelow)")
check("PetPainter 实参序 = 声明序（style→state→blink→simplify）",
      widgetSrc.contains("PetPainter(style: style,\n                       state: petState,\n                       blink: false,")
      && iBlink != nil && iSimplify != nil && iBlink!.lowerBound < iSimplify!.lowerBound)
// ⚠️ 必须按**三处都在传**判（反向自证实测：只断言 contains 时，把其中一处改成写死液态仍然全绿）
check("形象随 ContentState.petStyle 下发（三处图标都传，不是只传一处）",
      widgetSrc.components(separatedBy: "styleRaw: context.state.petStyle").count - 1 == 3
      && attributesSrc.contains("var petStyle: String"))
check("petStyle 刻意不给默认值（漏传必须编译不过 → 不会静默画回球）",
      !attributesSrc.contains("petStyle: String =")
      && attributesSrc.contains("?? PetStyle.liquid.rawValue"))
check("主 App 四处状态构造都下发当前形象",
      managerSrc.components(separatedBy: "petStyle: PetStyle.current.rawValue").count - 1 == 4)
check("形象动效只随数据更新（呼吸按拍换向，无自走帧源）",
      petOrbSlice.contains("OrbBeat.spinStep")
      && petOrbSlice.contains("OrbBeat.animation(beat)")
      && !stripCommentLines(petOrbSlice).contains("repeatForever")
      && !stripCommentLines(widgetSrc).contains("TimelineView"))
check("眨眼底层不做（岛内渲染不出瞬时眨眼）", petOrbSlice.contains("blink: false"))
check("spin 步长单一真源 OrbBeat.spinStep（App 侧不许再写死 0.125）",
      attributesSrc.contains("static let spinStep: Double = 0.125")
      && !managerSrc.contains("+ 0.125"))
check("紧凑态右侧是进度条（28×5.5）", islandSlice.contains("phaseBar(state: state, width: 28, height: 5.5)"))
check("展开态右侧是进度条（54×6.5）", islandSlice.contains("phaseBar(state: context.state, width: 54, height: 6.5)"))
// ⚠️ 断言「调用」而不是裸名字：声明 `private func phaseRing(state:` 也含同名子串（实测假红）
check("全挂件已无 phaseRing 调用（环整块退役；横幅也改进度条 52×7）",
      !stripCommentLines(widgetSrc).contains("phaseRing(state: state, size:")
      && !stripCommentLines(islandSlice).contains("self.phaseRing(")
      && widgetSrc.contains("phaseBar(state: state, width: 52, height: 7)"))
let phaseBarSlice = between(widgetSrc, "private func phaseBar(", "/// v3.9.10：右侧阶段指示改为")
check("phaseBar 切片可切出（空了本条就是空真）", !phaseBarSlice.isEmpty)
check("进度条高光位置用折返（取余会瞬跳回 0，白块倒着闪）",
      phaseBarSlice.contains("truncatingRemainder(dividingBy: 2)")
      && !phaseBarSlice.contains("spin.truncatingRemainder(dividingBy: 1)"))
check("进度条语义仍是「本轮推进度」不是答案完成度",
      phaseBarSlice.contains("min(1.0, max(0.06, state.progress))"))
check("进度条颜色口径与环一致（failed 红 / done 绿 / streaming 紫）",
      phaseBarSlice.contains("failed ? OrbPalette.fail")
      && phaseBarSlice.contains("done ? OrbPalette.success")
      && phaseBarSlice.contains("streaming ? OrbPalette.tail"))
// 退役符号不得复活：只钉「无调用」不够 —— 把定义整块加回来（无人调用）或换个拼法调用都能绕过（审查④ F2）。
// `phaseRing(` 带括号是为了不误伤退役注释里的裸符号名；`struct OrbView` 没有括号，所以另判一次。
check("退役的球体视图/阶段环不得复活（定义与任何拼法的调用都算）",
      !stripCommentLines(widgetSrc).contains("phaseRing(")
      && !widgetSrc.contains("struct OrbView"))
check("进度条过渡按本拍现算（不许写死秒数）",
      phaseBarSlice.contains("OrbBeat.animation(state.beatSeconds)"))
// 呼吸只许往内收：外扩 + 向上 offset 会让 36pt 展开态顶出布局框 ~1.26pt，
// 而同一区域上方就是传感器区（36.67pt 顶行，38 就被圆角遮罩切边）——审查 F5 的推算。
check("形象呼吸只往内收（不外扩、不越框）",
      widgetSrc.contains(".scaleEffect(inhale ? 0.97 : 1.0)")
      && !stripCommentLines(widgetSrc).contains(".scaleEffect(inhale ? 1.0 : 1.03)"))
// ⚠️ 必须断言「在挂件的 sources 块里」而不是「文件里出现过这行」：条目挪到主 App 的 sources 下、
//    或在别处残留同样字符串，都曾能让本条假绿（＝它自称要堵的那类假绿）。审查 F1 指出。
let widgetSourcesBlock = between(projectSrc, "QingliaoWidget:", "info:")
check("挂件 target sources 块非空（空了本条就是空真）", !widgetSourcesBlock.isEmpty)
check("挂件 target 编入 PetModel.swift + PetPainter.swift（漏了只有 CI Archive 会红）",
      widgetSourcesBlock.contains("- qingliao/Features/Chat/PetModel.swift")
      && widgetSourcesBlock.contains("- qingliao/Features/Chat/PetPainter.swift"))
check("横幅玻璃层不抢触摸（独立切片断言，见 ②）", glassSlice.contains(".allowsHitTesting(false)"))
check("展开态玻璃底衬自绘（无描边版）", widgetSrc.contains("private var expandedGlass")
      && !widgetSrc.contains("cornerRadius: 10, style: .continuous)\n                .strokeBorder(Color.white.opacity(0.16)"))


// ── 9. v3.9.76 智慧球两个新入口（AI 识别浮层 / 语音对话页）────────────
// 用户拍板：「长按智慧球增加 AI 识别和语音对话胶囊」；形态 = 识别走**球上悬浮卡 + 扫描环 + 背景虚化**，
// 语音走**全屏涟漪页 · 深色科幻 · 全念**。本节钉住这两页最容易走形的口径。
let identifySrc = src("Features/OrbIdentifyOverlay.swift")
let voiceSrc = src("Features/VoiceDialogView.swift")
check("OrbIdentifyOverlay.swift 源可读", !identifySrc.isEmpty)
check("VoiceDialogView.swift 源可读", !voiceSrc.isEmpty)

// ① 不新造第二套识别/动作口径：认内容走意图管道、画结果与执行动作复用动作条
check("识别浮层走 IntentExtractor.extract(image:auth:)（与聊天页同一条管道）",
      identifySrc.contains("await IntentExtractor.extract(image: image, auth: auth)"))
check("识别浮层复用 IntentActionBar（不新造动作条）",
      identifySrc.contains("IntentActionBar(intent: intent,"))
// ② 背景虚化 + 空白可收起（不补 contentShape 就点不到，本仓已知坑）
check("背景走材质虚化（用户拍板「虚化背景」）", identifySrc.contains(".fill(.ultraThinMaterial)"))
check("虚化层补 contentShape（否则空白点不到 = 收不起来）",
      identifySrc.contains(".contentShape(Rectangle())"))
// ③ 几何同源：扫描环与卡片位置都用球心真源，别自己算等分
check("扫描环/卡片位置走 orbCenterGlobal（与可见球严格同源）",
      identifySrc.contains("DockOrbOverlay.orbCenterGlobal(slotIndex: slotIndex"))
// ④ 相机两道闸：可用性 + ignoresSafeArea（后者是 v3.9.75 顶部黑边的修复）
check("相机先查可用性（无相机设备 present 会抛异常）",
      identifySrc.contains("UIImagePickerController.isSourceTypeAvailable(.camera)"))
check("相机内容 ignoresSafeArea（顶部黑边修复不许回退）",
      identifySrc.contains("CameraPicker { img in recognize(img) }") && identifySrc.contains(".ignoresSafeArea()"))
// ⑤ 没认出 ≠ 失败：不得出现「识别失败」这类报错口气（用户看到会以为坏了）
// 剥注释行再断言：本文件注释里为说明口径会出现「识别失败」字样，直接 contains 会假红
check("没认出内容不算失败（代码里不出现「识别失败」报错口气）",
      !stripCommentLines(identifySrc).contains("识别失败"))
// ⑥ 纯视觉层不吃触摸（扫描环 / 涟漪不许吞掉卡片与空白的点击）
// ⚠️ 切片断言（本文件自己立的反面教材：整文件 grep 会被另一处喂饱）
let ringSlice = between(identifySrc, "private func scanRings", "private func startScanLoop")
check("扫描环层切片取到（切片空了本条就是空真）", !ringSlice.isEmpty)
check("扫描环层 allowsHitTesting(false)（纯视觉，不吃触摸）", ringSlice.contains(".allowsHitTesting(false)"))
// ⑦ 「问 AI」复用既有跨页发送通道，不新造通知
// 切片到 onAskAI 闭包内：整文件任意一处 post 就能喂饱（今天恰好只此一处才侥幸成立），
// 而「没切页 → 通知落空 → 消息静默消失」这个真缺口它根本覆盖不到。
let askAISlice = between(dockSrc, "onAskAI: { text in", "onClose:")
check("「问 AI」闭包切片取到（切片空了本条就是空真）", !askAISlice.isEmpty)
check("「问 AI」走既有 .qingliaoTaskSend（不新造通道）",
      askAISlice.contains("NotificationCenter.default.post(name: .qingliaoTaskSend,"))
check("「问 AI」先切到聊天页 + 0.35s 闸（否则 ChatView 不在树 → 通知落空）",
      askAISlice.contains("selected = .chat") && askAISlice.contains("seconds(0.35)"))

// ⑩ v3.9.79 横屏欢迎页两栏（用户拍板方案 2）+ 横屏判据的根因修复
// 根因：原来 AdaptiveLayout 拿 horizontalSizeClass == .regular 判横屏，而 iPhone 横屏仍是 .compact
// → 那些"横屏放宽"的分支从来没生效过，横屏一直按竖屏尺寸硬排。
check("横屏判据收在 AdaptiveLayout.isShort（只认 verticalSizeClass）",
      src("Theme/AdaptiveLayout.swift").contains("static func isShort(_ vSize: UserInterfaceSizeClass?) -> Bool")
      && src("Theme/AdaptiveLayout.swift").contains("vSize == .compact"))
check("欢迎页按矮屏分流（横屏走两栏，不再拿竖屏尺寸硬排）",
      chatViewSrc.contains("if AdaptiveLayout.isShort(vSize) { welcomeLandscape } else { welcomePortrait }"))
check("横屏两栏 = 左形象+问候 / 右芯片竖排（用户拍板方案 2）",
      chatViewSrc.contains("private var welcomeLandscape: some View")
      && chatViewSrc.contains("private var landscapeChips: some View")
      && chatViewSrc.contains("HStack(alignment: .center, spacing: Spacing.xxl + 18)"))
// 拆件必须共用：形象手势 / 芯片样式 / 续聊卡各只有一处实现（横屏复制第二套 = 迟早两边走样）
check("形象/芯片/续聊卡只此一份（横屏复用拆件，不许复制第二套手势与样式）",
      chatViewSrc.components(separatedBy: "name: .qingliaoOrbMenuFromPet").count - 1 == 1
      && chatViewSrc.components(separatedBy: "private func suggestionChip(_ s: WelcomeSuggestion)").count - 1 == 1
      && chatViewSrc.components(separatedBy: "Text(\"继续上次\")").count - 1 == 1
      && chatViewSrc.components(separatedBy: "petHero").count - 1 == 3)   // 定义 1 + 竖屏 1 + 横屏 1
check("横屏 + 键盘弹起时芯片列收起（否则顶出屏幕）",
      chatViewSrc.contains("if !kb.isVisible {\n                    landscapeChips\n                }"))

// ⑨ v3.9.79「AI 翻译」胶囊（用户拍板：拍照/相册旁边加第三颗 → 拍照或选图**直接出译文**，不再给动作条；
//    方向口径 = **自动双向**：中文→英文、其他语言→中文）
check("识别浮层有第三颗「AI 翻译」胶囊（入口在位）",
      identifySrc.contains("Label(\"AI 翻译\", systemImage: \"character.book.closed\")"))
check("翻译模式可见且可退出（胶囊变「退出翻译」，错点一下能退回识别）",
      identifySrc.contains("Label(\"退出翻译\", systemImage: \"xmark\")")
      && identifySrc.contains("@State private var translateMode = false"))
check("进翻译模式时提示文案改口（否则用户不知道这次拍照会出译文）",
      identifySrc.contains("\"拍一张或选一张，AI 直接给你译文\""))
// 关键行为：翻译分支**只取字 + 就地出译文** —— 不许走 extract（那条路没字时会去叫云端视觉模型，
// 会把「做个总结」之类的内容塞进译文提示词），也不许自动把用户弹去聊天页（用户拍板「译文别回聊天页」）。
let translateSlice = between(identifySrc, "if translating {", "let found = await IntentExtractor.extract")
check("翻译分支切片取到（切片空了下面几条就是空真）", !translateSlice.isEmpty)
check("翻译分支 = 只取字 + 一问一答 + 就地落成译文卡（不进 IntentActionBar）",
      translateSlice.contains("await IntentExtractor.ocrText(in: image)")
      && translateSlice.contains("QingliaoIntentClient.oneShot(TranslateKit.prompt(for: source),")
      && translateSlice.contains("auth: auth, timeout: 30)")   // v3.9.79b：一问一答不挂 120s 默认超时
      && translateSlice.contains("phase = .translated(source: source")
      && !translateSlice.contains(".result(")
      && !translateSlice.contains("onAskAI("))          // 就地显示为主路：别在分支里直接发会话
check("翻译失败不静默退回选区（落在卡里给重试，且留着原图）",
      translateSlice.contains("phase = .translateFailed")
      && identifySrc.contains("@State private var lastImage: UIImage?")
      && identifySrc.contains("guard let img = lastImage"))
check("一问一答入口只有一处实现（ask 复用它，别再各写一份 payload）",
      src("Core/AppIntents.swift").contains("static func oneShot(_ prompt: String, auth: AuthStore")
      && src("Core/AppIntents.swift").contains("return try await oneShot(style.instructionPrefix + q, auth: auth)"))
check("只取字的新入口收在 IntentExtractor（复用非 Sendable 那套处理，不另起后台闭包）",
      src("Core/IntentExtractor.swift").contains("static func ocrText(in image: UIImage) async -> String?"))
check("每次进浮层复位翻译模式（否则下次拍照莫名出译文）",
      identifySrc.contains("translateMode = false\n            lastImage = nil"))
check("译文卡三件套在位（复制 / 换一张 / 发给 AI 出口）+ 原文留 3 行便于核对",
      identifySrc.contains("copyTranslation(text)")
      && identifySrc.contains("restartTranslate()")
      && identifySrc.contains("Text(copiedTranslation ? \"已复制\" : \"复制\")")
      && identifySrc.contains(".lineLimit(3)"))
// v3.9.80（用户口径「译文卡片根据译文字体多少自适应大小」）：译文区高度必须跟着内容走。
// 旧形态 = 贪婪 ScrollView 直接挂 `.frame(maxHeight: 220)` → 2 行译文也被撑满 220（卡内约 180pt 空白）。
// 新形态 = `ViewThatFits` 两稿（整段放得下就整段渲染，放不下才限高滚动）+ 上限收在单一常量。
check("译文区自适应：ViewThatFits 两稿（整段稿在前、限高滚动稿在后）",
      identifySrc.contains("ViewThatFits(in: .vertical)")
      && identifySrc.contains(".frame(maxHeight: Self.translationMaxHeight)"))
check("译文区上限收在单一常量 translationMaxHeight（=220，改一处即改天花板）",
      identifySrc.contains("private static let translationMaxHeight: CGFloat = 220"))
check("旧的贪婪译文框形态已清零（不许再出现 ScrollView 直接挂 maxHeight: 220）",
      // 先去注释行：本文件的注释里为了讲清「旧形态」会原样写下那个字符串（踩过一次假红）
      !stripCommentLines(identifySrc).contains(".frame(maxHeight: 220)"))
// 方向判据：真值表内复刻同一条判据并断言行为，再断言源侧同形（源改了而这里没改会红）
func mirrorTranslateTarget(_ t: String) -> String {
    t.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } ? "英文" : "中文"
}
let translateSrc = src("Core/TranslateKit.swift")
check("TranslateKit 源读得到（空了后面是空真）", !translateSrc.isEmpty)
check("判据 = 汉字基本区 0x4E00...0x9FFF（与镜像同形）",
      translateSrc.contains("(0x4E00...0x9FFF).contains($0.value)"))
check("方向镜像：含汉字 → 英文", mirrorTranslateTarget("出发去北京") == "英文")
check("方向镜像：纯拉丁 → 中文", mirrorTranslateTarget("Hello world") == "中文")
check("提示词句式 = 「翻译成<方向>（保留原意，只输出译文）」+ 原文另起一行",
      translateSrc.contains("请把下面这段文字翻译成\\(targetLabel(for: text))（保留原意，只输出译文）：\\n\\(text)"))

// ⑧ 语音对话页：判断在 engine、页面只执行动作；发送与朗读都复用既有口径
check("语音页不自己判「该不该发」（只执行 engine 给的动作）",
      voiceSrc.contains("perform(engine.handle("))
check("语音页发送走 .qingliaoTaskSend（与键盘发送同一条流）",
      voiceSrc.contains("NotificationCenter.default.post(name: .qingliaoTaskSend, object: text)"))
check("语音页临时打开自动朗读并在退出还原（全念复用 + 不偷改用户设置）",
      voiceSrc.contains("autoReadBefore = autoReadReply")
      && voiceSrc.contains("if let before = autoReadBefore { autoReadReply = before }"))
check("语音页观察 speakingID 做半双工（念的时候停麦）",
      voiceSrc.contains(".onChange(of: speech.speakingID)"))
check("语音页保持纯 SwiftUI（import UIKit 会让本机无法预检）",
      !voiceSrc.contains("import UIKit"))
check("语音页半双工口径写进注释（防后人改成全双工导致自问自答）",
      voiceSrc.contains("半双工"))
check("引擎判停/超时可注入时间（否则这条回归只能靠真机手感）",
      src("Core/VoiceDialogEngine.swift").contains("mutating func handle(_ event: Event, now: Date = Date()) -> Action"))

// ⑨ 接线：两个胶囊都要有真实分支，且切页时不许留死层
check("DockTabView 分发「AI 识别」胶囊", dockSrc.contains("showIdentify = true"))
check("DockTabView 分发「语音对话」胶囊", dockSrc.contains("showVoiceDialog = true"))
check("切页时两个新层都收起（不留浮在新页面上的死层）",
      dockSrc.contains("if showIdentify { showIdentify = false }")
      && dockSrc.contains("if showVoiceDialog { showVoiceDialog = false }"))
check("识别浮层开着时摘掉球命中层（不许两层同时吃触摸）",
      dockSrc.contains("if !showOrbMenu && !showIdentify && !showVoiceDialog {"))

// ⑨′ 语音对话页的两条命脉 + 降级口径（v3.9.76 审查抓到的真缺口，补护栏防回退）
//    ① 「发送」= 发出 + **停麦**（Action.sendNow 的语义）；不停麦 → 发送到开口那段还在收音，
//       且停麦的音频会话收尾会和朗读起播抢时序，把刚开口的念读掐掉。
//    ② 宿主进入本页前**必须先切到聊天页**：本页发送走 `.qingliaoTaskSend`（唯一接收方 ChatView）、
//       「全念」走 ChatView 的 assistantLandedToken —— 两者都只在 ChatView 在树时生效。
//       球在任意 tab 都在，不切页 = 用户说完消息静默消失、一句也不念。
let voiceSendSlice = between(voiceSrc, "case .sendNow(let text):", "case .openMic:")
check("语音页发送切片取到（切片空了本条就是空真）", !voiceSendSlice.isEmpty)
check("语音页发送时同步停麦（Action.sendNow 语义 = 发出 + 停麦）",
      voiceSendSlice.contains("await closeMic()"))
check("语音页发完仍走既有 .qingliaoTaskSend 通道",
      voiceSendSlice.contains("NotificationCenter.default.post(name: .qingliaoTaskSend"))
let voiceCase5 = between(dockSrc, "case 5:   // 语音对话", "default:")
check("语音对话入口切片取到（切片空了本条就是空真）", !voiceCase5.isEmpty)
check("语音对话入口先切聊天页（否则通知落空 = 消息静默消失）",
      voiceCase5.contains("selected = .chat"))
// ⚠️ 停麦判据含 isPreparing：isRunning 直到起麦那刻才 true，准备期（首次权限框 / 下模型）用户
//    完全可能点退出 —— 只看 isRunning 会 return，随后 start() 跑完在页面消失后开麦 → 残余收音。
let voiceCloseMic = between(voiceSrc, "private func closeMic() async {", "private func toggleMode")
check("停麦切片取到", !voiceCloseMic.isEmpty)
check("停麦判据含 isPreparing 且用 cancel()（准备期也能中断）",
      voiceCloseMic.contains("liveSpeech.isPreparing") && voiceCloseMic.contains("await liveSpeech.cancel()"))
check("退出路径停朗读（否则「明明关了自动朗读还在响」）",
      voiceSrc.contains("SpeechManager.shared.stop()"))
check("降级文案带真实原因（不支持设备端识别的机型不能只报「没打开」）",
      voiceSrc.contains("liveSpeech.lastError ?? "))
check("准备期文案（这段时间不能显示「聆听中」）",
      voiceSrc.contains("正在准备语音模型"))

// ── ⑩ v3.9.77 界面口径（用户 2026-09-25 装机后报的 4 条）────────────────────
// 这四条都不是「审美偏好」，而是**可回退的具体口径**，所以逐条钉住。
let micSrc = src("Core/LiveSpeechTranscriber.swift")
let speechSrc = src("Core/SpeechManager.swift")
// ⚠️ 排除式断言一律先剥注释：本仓已被「注释里叙述旧写法」绊倒过多次 ——
//    这次就是 `.pill(.primary)` 那条（注释原文里写着旧口径 → 断言假红）。
let voiceClean = stripCommentLines(voiceSrc)
let micClean = stripCommentLines(micSrc)
let speechClean = stripCommentLines(speechSrc)

// 1) 语音对话页跟随系统明暗（原来按深色稿写死了深底 + .environment(\\.colorScheme, .dark)）
check("语音页不再写死深色环境", !voiceClean.contains(".environment(\\.colorScheme, .dark)"))
check("语音页底色走系统语义（Color(.systemBackground)）", voiceSrc.contains("Color(.systemBackground)"))
check("语音页文字走语义色（不再 foregroundStyle(.white) 硬写）", !voiceClean.contains("foregroundStyle(.white)"))
check("柔光/涟漪强度按主题分档（isDark 判定存在）", voiceSrc.contains("private var isDark: Bool"))
// 2) 球高光接近球心 —— 偏左上会让人眼觉得整球离开了涟漪中心（几何本来就同心）
check("球高光居中（UnitPoint 0.44/0.40）", voiceSrc.contains("UnitPoint(x: 0.44, y: 0.40)"))
check("旧的偏心高光已消失（0.36/0.32）", !voiceClean.contains("UnitPoint(x: 0.36, y: 0.32)"))
// 3) 波条跟真实麦克风电平起伏
check("波条每帧自读电平（TimelineView + currentInputLevel，不靠广播）",
      voiceClean.contains("TimelineView(") && voiceClean.contains("liveSpeech.currentInputLevel()"))
// ── v3.9.77 用户定稿「方案 2」：波形 = 单条横向渐变波浪线 + 一条淡副波 ──────────────
//    （取代原来那排 11 根竖柱；灵动感 = 振幅跟电平 + 相位随时间推进）
check("波形是 Canvas 画的波浪线（不再是那排竖柱）",
      voiceClean.contains("Canvas { context, size in") && voiceClean.contains("Self.wavePath("))
check("渐变描边（蓝 → 紫 → 青，横向）",
      voiceClean.contains(".linearGradient(Gradient(colors: mainColors)"))
check("振幅跟电平（安静仍留 2.4pt 呼吸，不平成死直线）", voiceClean.contains("2.4 + 32 * lv"))
check("相位随时间推进（此起彼伏）；减弱动态效果时静止",
      voiceClean.contains("reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate * 2.2"))
check("两条波：主波 + 淡副波（层次感）", voiceClean.contains("amp * 0.58"))
check("旧的 11 根竖柱系数数组已删除", !voiceClean.contains("private static let waveShape"))
check("写死的固定波高数组已删（不然又变成不说话也一个样）", !voiceClean.contains("waveHeights"))
check("识别引擎暴露**非隔离**电平读数（波条每帧读它，不走广播）",
      micClean.contains("nonisolated func currentInputLevel() -> Float"))
check("tap 里算 RMS 且不碰 self（捕获 Sendable 的 micMeter）—— 接线不能断",
      micClean.contains("[feeder, micMeter]") && micClean.contains("MicLevelMeter.rms(of: buffer)")
      && micClean.contains("micMeter.update("))
check("电平转发器 @unchecked Sendable（音频线程写、主线程读）",
      micClean.contains("final class MicLevelMeter: @unchecked Sendable"))
// 🚨 v3.9.77 修审查：电平**不能**走 @Published —— 本类被聊天页共用，广播会让聊天页超大 body
//     在整段录音里被 14Hz 全量重绘（性能硬要求）。原来那套「0.07s 定时器写 @Published」已整块删掉。
check("电平不走 @Published（否则聊天页被连坐重绘）",
      !micClean.contains("@Published private(set) var inputLevel"))
check("电平没有独立定时器了（定时器那套已整块删除）", !micClean.contains("startLevelTimer"))
check("teardown 把电平清零（否则波条停在最后一帧）", micClean.contains("micMeter.update(0)"))
// 4) AI 文字跟随语音逐字输出
// 🚨 v3.9.77 复审修：逐字进度原来挂在 SpeechManager 自身的 @Published 上 —— 而 SpeechManager.shared
//    被聊天列表每颗气泡观察（ChatMessageBubble 的 @ObservedObject）→ 朗读全程以 ≈12.5Hz 让整片
//    聊天列表 body 全量重算（与「麦克风电平不走 @Published」同一类）。现在改成独立发布箱，只语音页订阅。
check("逐字进度走独立发布箱 SpokenProgress（挂共享单例上会让聊天页连坐重绘）",
      speechSrc.contains("final class SpokenProgress: ObservableObject")
      && speechSrc.contains("let progress = SpokenProgress()"))
check("逐字进度的旧形态已清零（不再是 SpeechManager 的 @Published）",
      !speechClean.contains("@Published private(set) var spokenCharCount")
      && !speechClean.contains("@Published private(set) var spokenText"))
// ⚠️ 这里必须查**带参数名的完整签名**且剥注释：只查 `willSpeakRangeOfSpeechString` 会被
//    「注释里提到这个方法名」命中 —— 反向自证 D4 实测把真回调删掉它照样绿（假护栏）。
check("系统引擎走精确逐字回调（带参数名的完整签名）",
      speechClean.contains("willSpeakRangeOfSpeechString characterRange"))
check("云端按时长估算且读播放位置（currentTime，不用墙钟 → 缓冲/暂停都不飘）",
      speechSrc.contains("pl.currentTime / perChar"))
check("语音页按逐字进度输出（读独立箱 prefix(charCount)）",
      voiceSrc.contains("prefix(spokenProgress.charCount)"))

// 5) 大爆炸底部胶囊统一样式与尺寸（原来那颗「复制」混用 .pill(.primary) = 另一套尺寸）
let bbSrc = src("Features/BigBang/BigBangView.swift")
let bbBar = between(bbSrc, "private func bottomBar(showCopyCount: Bool)", "private func wordChip")
check("大爆炸底部条切片取到（切片空了下面两条就是空真）", !bbBar.isEmpty)
check("底部条不再混用 .pill(.primary)（那是另一套尺寸，会高出一截）",
      !stripCommentLines(bbBar).contains(".pill(.primary)"))
// 🚨 v3.9.77 用户二次澄清：「统一样式和大小」= **样式与尺寸都要一致**（我第一版只统一了尺寸、
//   还留着主操作的强调色，不合口径）→ 5 颗现在全部 .pill(.topBar, tone: .neutral)。
// 🚨 v3.9.77 复审修：原来数的是**未剥注释**的切片 —— 注释里那句「5 颗全部 .pill(.topBar, tone: .neutral)」
//    也被计入（实测计数 6）→ `>= 5` 实际只要求 4 颗，退回一颗也不红（假护栏）。改成剥注释 + 精确条数。
check("底部条 5 颗胶囊完全一致（同尺寸 + 同色调，剥注释后精确 5 颗）",
      stripCommentLines(bbBar).components(separatedBy: ".pill(.topBar, tone: .neutral)").count - 1 == 5
      && !stripCommentLines(bbBar).contains(".pill(.topBar, tone: .accent)"))


// 6) 长按菜单的背景遮罩 = **全屏半透明模糊**（用户 2026-09-25：「这个背景上下白，中间灰，改全半模糊效果」）
//    旧形态 = 一层 `Color.black.opacity(0.12)`，既不模糊、又没铺安全区 → 上下露原页面、中间一条灰纱。
let orbSrc = src("Features/OrbQuickMenu.swift")
let orbClean = stripCommentLines(orbSrc)
check("菜单遮罩走材质模糊（.ultraThinMaterial 自带背景模糊）",
      orbClean.contains("Rectangle().fill(.ultraThinMaterial)"))
check("菜单遮罩铺满全屏（.ignoresSafeArea()）—— 去掉就回到「上下白、中间灰」",
      orbClean.contains(".ignoresSafeArea()"))
check("旧的纯色 12% 黑纱已清零（无模糊、没铺满的旧形态）",
      !orbClean.contains("Color.black.opacity(shown ? 0.12 : 0)"))
check("遮罩仍吃掉空白点击（点空白收起保住）",
      orbClean.contains("onTapGesture(perform: dismissAnimated)"))


// 7) 长按菜单 6 颗胶囊**大小统一**（用户 2026-09-25：「这个截图的 6 个胶囊也大小统一一下」）
let orbPill = between(orbSrc, "private func pillVisual(", "private func pillHitArea")
check("菜单胶囊切片取到（切空了下面就是空真）", !orbPill.isEmpty)
check("菜单视觉层钉统一宽度（与命中层同源 pillSize）",
      orbPill.contains(".frame(width: OrbQuickMenuLayout.pillSize.width)"))
// ⚠️ 令牌真值：Spacing.xl = 12（原来写 `Spacing.xl + 2` = 14）。统一宽度 101 下，
//    内容 73pt + padding 12×2 = 97 → 余量 4pt。改回 14 会顶到 101、再宽一点就挤压截字。
check("水平 padding 用 Spacing.xl（12），别改回 xl + 2",
      orbPill.contains(".padding(.horizontal, Spacing.xl)")
      && !orbPill.contains(".padding(.horizontal, Spacing.xl + 2)"))
check("统一尺寸常量仍是几何算式的基准（101×36）",
      orbSrc.contains("static let pillSize = CGSize(width: 101, height: 36)"))


// 9) v3.9.77 修审查：两条「跑起来才暴露」的缺陷用源码形态钉住（预检/编译都查不出这类）
check("系统逐字回调带身份护栏（丢弃上一条的迟到回调，否则新一条整段瞬显）",
      speechClean.contains("guard self.currentUtteranceID == uid else { return }"))
check("云端播毕回收 ticker（自然播完是最常见路径，原来没人清 → 永不回收的空转定时器）",
      // 自毁统一走实例方法（BLOCKER 修复后 Timer 闭包参数改成 `_`，不再用 `t`）→ 断言认方法体里的那一行
      speechClean.contains("private func stopCloudTicker()")
      && speechClean.contains("cloudTickTimer?.invalidate()")
      && speechClean.contains("self.stopCloudTicker()"))
// 🚨 v3.9.77 BLOCKER 护栏：Timer 的 block 是 @Sendable，它的参数 `t`（Timer 非 Sendable）**不能**
//    被送进 `Task { @MainActor in }` —— 真编译报 `sending '...' risks causing data races`，
//    而 `-parse` / `-typecheck` **全部放行**（本机预检永远绿）。这条断言是唯一能拦住它回潮的东西。
check("Timer 闭包参数是 `_`、且不使用 t（用 t 会让 Archive 直接失败）",
      speechClean.contains("repeats: true) { [weak self] _ in")
      && !speechClean.contains("t.invalidate()"))
check("UTF-16 偏移换算成 Character（含 emoji 时逐字不会跑到语音前面）",
      speechClean.contains("private func charOffset(utf16: Int) -> Int"))
check("stop() 一并清掉逐字文本（防非朗读路径读到上一条内容）",
      speechClean.contains("progress.text = \"\""))

// 🚨 v3.9.77 复审修（第二批）：空闲超时（播放已死）必须**连状态一起收尾** ——
//    只收 ticker 会让语音页永久停在「朗读中」（页面状态机只由 speakingID 驱动）→ 麦克风再不开、闭环断死。
let idleSlice = between(speechClean, "guard pl.isPlaying else {", "self.cloudIdleTicks = 0")
check("空闲超时切片取到（切片空了下面这条就是空真）", !idleSlice.isEmpty)
check("空闲超时一并清 player/speakingID（否则语音页卡在朗读中，只能手点打断）",
      idleSlice.contains("self.speakingID = nil") && idleSlice.contains("self.player = nil"))
// 🚨 v3.9.77 复审修（第二轮）：空闲看门狗必须区分「从未起播」与「播过又停」——
//    一律按「播放已死」收尾会把起播慢（蓝牙/车机路由）的朗读整条误杀：静音 + speakingID 归 nil
//    → 引擎直接跳「聆听中」，用户看到的是一整条朗读被吞。
check("起播宽限：从未起播给 ≈4.8s（60 拍），播过又停才用 11 拍",
      speechClean.contains("let limit = self.cloudPlaybackSeen ? 10 : 60")
      && speechClean.contains("self.cloudPlaybackSeen = true"))
check("ticker 的 Task 带代次护栏（旧 Task 不得写新文本进度、不得停新 ticker）",
      speechClean.contains("guard gen == self.ttsGeneration else { return }"))
// 🚨 浅色下球体不能只有深色稿那套白心（白球贴白底 = 球看不见，复审实测半径 43 处只剩 ≈22% accent）
check("球体渐变按深浅色分档（ballColors）", voiceClean.contains("private var ballColors: [Color]"))
// 断言点是「渲染处取变量」而不是「文件里不许出现 0.92」——分档本体的深色分支里仍然要有 0.92。
check("球体渲染处取自分档变量（不再写死颜色数组）",
      voiceClean.contains(".fill(RadialGradient(colors: ballColors,"))
// 🚨 v3.9.77 复审修：只钉「变量存在 + 渲染处取变量」不够 —— 把 ballColors 改回单档（只留深色那套）
//    正是要修的「白球贴白底看不见」，那两条仍会全绿。所以必须钉**两套参数都在**。
check("球体分档两套参数都在（浅色档必须压白心，否则白球贴白底）",
      voiceClean.contains("isDark ? [.white.opacity(0.92)")
      && voiceClean.contains(": [.white.opacity(0.42)"))
// 固定宽度胶囊的文字软兜底（宽度常量是按令牌算式估的，图标 advance 有波动）
check("胶囊文字有软兜底（lineLimit(1) + minimumScaleFactor）",
      orbClean.contains(".lineLimit(1)") && orbClean.contains(".minimumScaleFactor(0.85)"))
// 逐字进度只在真的前进时写（值没变也写会白白触发订阅方重算）
check("逐字进度只在前进时写（next != 当前值）", speechClean.contains("if next != self.progress.charCount"))

// 8) v3.9.78：菜单层在材质模糊**之上**重画一颗「锚点球」（用户：「这个界面需要把底部的智慧球显示出来」）
//    真因：v3.9.77 把遮罩改成整屏 `.ultraThinMaterial` 后，dock 那颗球被压在磨砂层**下面**
//    （整条 dock 一起糊掉，球只剩一团浅蓝光斑）—— 而六颗胶囊恰恰是**从球心弹射**出来的，
//    锚点看不见，绽放就没了起点。修法 = 在材质之后、胶囊之前按**同源几何/尺寸/状态**重画一颗。
// v3.9.78 追加：锚点做成参数（`.dockOrb` / `.pet(size:)`）—— 原来的 `private var ball` 改名 `anchorObject`
// 并内部分支；切片口径不变（同一段文本里同时含两个分支）。
let orbBall = between(orbClean, "private var anchorObject: some View", "private func pillOffset")
check("锚点球切片取到（切空了下面就是空真）", !orbBall.isEmpty)
check("锚点球与可见球同源球心（ballCenter）", orbBall.contains(".position(ballCenter)"))
check("锚点球尺寸走单一真源 DockOrbOverlay.defaultBallSize",
      orbBall.contains("size: DockOrbOverlay.defaultBallSize")
      && orbBall.contains("width: DockOrbOverlay.defaultBallSize"))
check("锚点球三态直传 + fps 分档（与 dock 那颗同一套观感）",
      orbBall.contains("thinking: thinking") && orbBall.contains("unseen: unseen")
      && orbBall.contains("failed: failed") && orbBall.contains("fps: thinking ? 30 : 15"))
// ⚠️ 菜单层是**模态**的：锚点球只能看不能吃事件，否则点球收起这条（与轻纱同语义）会被抢掉。
check("锚点球不吃事件（allowsHitTesting(false)，点球 = 点空白 = 收起）",
      orbBall.contains(".allowsHitTesting(false)") && !orbBall.contains("onTapGesture"))
// v3.9.78：锚点是**参数**（dock 球 / 聊天页宠物）——同一套菜单层，不在聊天页搭第二套
check("锚点做成参数（默认 .dockOrb，另有 .pet(size:)）",
      orbClean.contains("var anchor: OrbQuickMenuAnchor = .dockOrb")
      && orbClean.contains("case pet(size: CGFloat)"))
check("锚点是宠物时必须重画宠物（不是画球）",
      orbBall.contains("PetAvatar(size: size, state: thinking ? .thinking : .idle)"))
check("宠物锚点只覆盖中心（几何换算同源：petAnchor.center → ballCenter，不在聊天页另算一套）",
      orbClean.contains("let c = petAnchor?.center ?? DockOrbOverlay.orbCenterGlobal(slotIndex: slotIndex,")
      && orbClean.contains("ballCenter: CGPoint(x: c.x - g.minX, y: c.y - g.minY)"))
// v3.9.80：宠物锚点与 dock 球**方向相反** —— dock 球贴屏底向上绽放；宠物在上半屏整组落到宠物下方
// （用户 2026-09-25 截图：「这个界面胶囊弹出放在卡通宠物下方」）。方向只在 pillsBelow 一处判定。
check("锚点是宠物时胶囊落在宠物下方（方向由 pillsBelow 判定，不散落多处）",
      orbClean.contains("if case .pet = anchor { return true }")
      && orbClean.contains("below: pillsBelow"))
check("落点几何支持镜像（below ? 加 : 减，只此一处判定方向）",
      orbClean.contains("y: below ? ballCenter.y + dy : ballCenter.y - dy"))
check("旧「一律向上」调用形态清零（不许再出现不带 below 参数的调用）",
      !orbClean.contains("OrbQuickMenuLayout.center(index: index, ballCenter: ballCenter)"))
// ZStack 层序是本次修复的**真身**：材质 → 光晕 → 锚点球 → 胶囊。
// 球若回到材质之前，就等于没修（又被糊掉）；若跑到胶囊之后，会盖住胶囊底排的呼吸。
let orbZStack = between(orbClean, "ZStack {", "ForEach(Array(OrbQuickAction.all.enumerated())")
check("菜单 ZStack 切片取到（切空了层序断言就是空真）", !orbZStack.isEmpty)
let iMaterial = orbZStack.range(of: "Rectangle().fill(.ultraThinMaterial)")
let iHaloIn = orbZStack.range(of: "halo")
let iBallIn = orbZStack.range(of: "anchorObject")   // v3.9.78：原 `ball` 改名（层序断言跟着改）
check("层序 = 材质 → 光晕 → 锚点球（球在材质之上，否则又被糊掉）",
      iMaterial != nil && iHaloIn != nil && iBallIn != nil
      && iMaterial!.lowerBound < iHaloIn!.lowerBound
      && iHaloIn!.lowerBound < iBallIn!.lowerBound)
check("Overlay → Layer 三态透传接线完整",
      between(orbClean, "OrbQuickMenuLayer(ballCenter:", "onAction: onAction")
          .contains("thinking: thinking")
      && !between(orbClean, "OrbQuickMenuLayer(ballCenter:", "onAction: onAction").isEmpty)
// DockTabView 侧：状态直传（切片到调用点，别整文件 grep —— DockOrbOverlay 那处也有同款串）
let menuCall = between(stripCommentLines(dockSrc),
                       "OrbQuickMenuOverlay(barHeight: dockBarHeight",
                       "onClose: { showOrbMenu = false })")
check("DockTabView 调用点切片取到", menuCall.contains("slotCount: dockSlotCount"))
check("DockTabView 把三态传进菜单（球在原位也跟随真实状态）",
      menuCall.contains("thinking: stream.isStreaming")
      && menuCall.contains("unseen: orbUnseen")
      && menuCall.contains("failed: orbFailed"))
// 尺寸单一真源：dock 侧不再写字面量、菜单层也不许自己写一个
check("球尺寸单一真源在 DockOrbOverlay（dock 侧改引用常量）",
      chatEffectsSrc.contains("static let defaultBallSize: CGFloat = 52")
      && chatEffectsSrc.contains("var ballSize: CGFloat = DockOrbOverlay.defaultBallSize"))
check("菜单层不再出现写死的球尺寸字面量", !orbClean.contains("size: 52"))

// 10) v3.9.78：语音对话页「后面的文字显示不出来」（用户报修，配图 = 朗读态）
//     真因：正文挂 `.lineLimit(4)` + 逐字增长 → 念到第 5 行以后新吐的字全部落在被裁掉的那段里。
//     修法：正文改**定高 ScrollView + 逐字变化自动贴底**，且不再截 120 字。
let replySlice = between(voiceClean, "private var replyText: some View", "private static let replyMaxHeight")
check("正文切片取到（切空了下面就是空真）", !replySlice.isEmpty)
check("正文不再挂 lineLimit（旧 4 行裁切必须清零，它就是把「后面的文字」关掉的那一行）",
      !voiceClean.contains("lineLimit")
      && !between(voiceClean, "Text(phaseLabel)", "if let voiceError").isEmpty)
check("core 里正文改走 replyText（不再是裸 Text(displayText) + 裁切）",
      between(voiceClean, "Text(phaseLabel)", "if let voiceError").contains("replyText"))
check("正文走 ScrollView + 定高上限（长文可读、不外扩挤走底栏）",
      replySlice.contains("ScrollView(") && replySlice.contains(".frame(maxHeight: Self.replyMaxHeight)"))
check("正文区高度上限走常量（≈8 行），不写魔法数",
      voiceClean.contains("private static let replyMaxHeight: CGFloat = 220"))
check("逐字增长时自动贴底（新念出来的字始终在眼前）",
      replySlice.contains("proxy.scrollTo(Self.replyBottomAnchor, anchor: .bottom)")
      && replySlice.contains(".onChange(of: displayText)")
      && voiceClean.contains("private static let replyBottomAnchor = \"voice_reply_bottom\""))
check("长文阅读走行距令牌（LineSpacing.long）", replySlice.contains(".lineSpacing(LineSpacing.long)"))
// 朗读结束切回摘要段时也不能只有开头 —— 旧的 120 字硬截断是同一个症状的另一半
check("最后一条回答不再截 120 字（截断理由已被 ScrollView 取代）",
      !voiceClean.contains("text.count > 120"))

// ── 12. v3.9.78 语音页顶栏（用户 2026-09-25 装机报：「语音对话四个字居中，退出胶囊同步改成右边胶囊样式」）──
// 居中的真因：原来是 `HStack[退出, Spacer, 标题, Spacer, 自动发送]` —— 双 Spacer 只在**两侧等宽**时才把标题
// 顶到屏幕中线，而「退出」比「自动发送 · 开」窄一大截 → 标题实际偏左。改法 = ZStack + 标题吃满屏宽。
let voiceHeaderSlice: String = {
    guard let a = voiceSrc.range(of: "private var header: some View {"),
          let b = voiceSrc.range(of: "// MARK: 核心视觉") else { return "" }
    return String(voiceSrc[a.lowerBound..<b.lowerBound])
}()
check("语音页顶栏切片可切出（空了后面全是空真）", !voiceHeaderSlice.isEmpty)
check("顶栏改 ZStack 承载（标题不再夹在两个宽度不等的胶囊之间）",
      voiceHeaderSlice.contains("ZStack {"))
check("标题吃满屏宽 → 恒在屏幕中线（不随两侧胶囊宽窄漂移）",
      voiceHeaderSlice.contains(".frame(maxWidth: .infinity)"))
check("标题文案不变", voiceHeaderSlice.contains("Text(\"语音对话\")"))
check("退出胶囊与右侧同款（accent：蓝字 + 蓝描边，不再走中性灰）",
      voiceHeaderSlice.contains("Text(\"退出\").pill(.topBar, tone: .accent)"))
check("右侧模式胶囊仍在（顶栏没被改坏）",
      voiceHeaderSlice.contains("Text(engine.mode == .auto ? \"自动发送 · 开\" : \"自动发送 · 关\")"))

// ── 11. v3.9.78 浮层卡片口径（用户 2026-09-25：圆角加大 + 背景改模糊半透明，随后「同口径也推到其它弹窗」）──
// 由头：聊天页那张意图动作卡在他眼里「圆角小 + 背景像实心白卡」→ 出三候选稿（16+玻璃 / 22+玻璃 / 22+更透）
// → 他拍板 **C**（圆角 22 + 同族最薄的 `.ultraThinMaterial`）；再要求推到识别浮层与速记/待办弹窗。
// 口径收在 `Theme/LiquidGlass.swift` 的 `OverlayGlassCard`（`.overlayGlassCard()`）：
// 调用点只准写调用，材质/圆角/描边三个数值只准出现在那一处（否则改一处漏两处 = 方框套圆框）。
let lgSrc = src("Theme/LiquidGlass.swift")
let overlayMod: String = {
    guard let a = lgSrc.range(of: "struct OverlayGlassCard: ViewModifier"),
          let b = lgSrc.range(of: "// MARK: - 滚动层次感") else { return "" }
    return String(lgSrc[a.lowerBound..<b.lowerBound])
}()
check("浮层卡片口径切片可切出（空了后面全是空真）", !overlayMod.isEmpty)
check("材质 = .ultraThinMaterial（用户挑的「更透」那档，不是 regularMaterial）",
      overlayMod.contains(".background(.ultraThinMaterial,"))
check("圆角默认 Radius.hero(22)（用户从 12/16/22 三档里选的 22）",
      overlayMod.contains("var cornerRadius: CGFloat = Radius.hero"))
check("描边 = 白 0.8pt 亮边，浅 0.12 / 深 0.22（与 GlassCard 同参）",
      overlayMod.contains("strokeBorder(Color.white.opacity(scheme == .dark ? 0.22 : 0.12), lineWidth: 0.8)"))
// v3.9.78 追加（用户 2026-09-25「弹窗卡片边框加淡色描边」）：外圈再压一条 `Tint.line` 淡色线 ——
// 纯白亮边在浅色底（聊天页 systemBackground）上几乎看不见，用户看到的是「卡片没边框」。
check("边框有可见淡色描边：外圈 Tint.line 0.8pt（浅 0.08 / 深 0.16，全站描边同参）",
      overlayMod.contains(".strokeBorder(Tint.line(scheme), lineWidth: 0.8)"))
// 两条线必须错开：白亮边内缩 0.8pt，否则同一条弧上叠两条线（观感更糊，且浪费一层）
check("白亮边内缩 0.8pt 排在外圈淡色线里侧（两条线不重叠）",
      overlayMod.contains(".strokeBorder(Color.white.opacity(scheme == .dark ? 0.22 : 0.12), lineWidth: 0.8)\n                    .padding(0.8)"))
check("描边只有一层半径源（圆角与描边必须同一个角值，防方框套圆框）",
      overlayMod.components(separatedBy: "RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)").count - 1 == 3)
check("对外暴露 .overlayGlassCard() 且默认走 hero 档",
      lgSrc.contains("func overlayGlassCard(cornerRadius: CGFloat = Radius.hero) -> some View"))

// 调用点①：聊天页意图动作卡（聊天页那张，用户原图就是它）
check("① 意图动作卡走 .overlayGlassCard()",
      src("Features/Chat/IntentActionBar.swift").contains(".overlayGlassCard()"))
// 调用点②：AI 识别浮层两张卡（扫描中 / 没认出可用内容）
// ⚠️ identifySrc 已在第 9 节声明过 —— 顶层重复 `let` = 编译不过（本节第一版就踩了），直接复用。
// ⚠️ 计数/排除式断言先剥注释：这两张卡的注释里就写着 `.overlayGlassCard()` 与旧口径（说明「改了什么」），
//    不剥会数出 4 处（注释 2 + 代码 2）→ 假红。
let identifyClean = stripCommentLines(identifySrc)
check("② 识别浮层所有卡都走新口径（v3.9.79 起 5 张：识别中/没认出/翻译中/译文/翻译失败；应当是 5 处）",
      identifyClean.components(separatedBy: ".overlayGlassCard()").count - 1 == 5)
check("② 识别浮层旧的实心卡口径清零（regularMaterial / Radius.inset / 暗发丝线）",
      !identifyClean.contains(".regularMaterial")
      && !identifyClean.contains("Radius.inset")
      && !identifyClean.contains("Color.primary.opacity(0.06)"))
// 调用点③：速记/待办弹窗里的输入卡（弹窗自身底不动 —— v3.9.23 决策：系统玻璃底不许覆盖）
let captureSrc = src("Features/OrbQuickMenu.swift")
check("③ 速记/待办输入卡走新口径（圆角取 Radius.card 档，不是 hero）",
      captureSrc.contains(".overlayGlassCard(cornerRadius: Radius.card)"))
check("③ 输入卡旧的实灰底清零（.background(.quaternary,）",
      !captureSrc.contains(".background(.quaternary,"))
check("③ 弹窗自身依旧不铺背景（v3.9.23 红线：别给 sheet 挂 presentationBackground）",
      !captureSrc.contains(".presentationBackground"))

// ── ⑪ v3.9.80：设置页「系统音色」行文字错位（用户真机原话：「系统音色文字错位调整一下」）──
// 真机取证（截图 1179×2556，红色手绘圈标出该行右侧）：该行右侧值是**两条墨迹带**
// （y 701~716pt 与 719.7~734.3pt，中心 708.5/727 关于左侧标签中心 717.8 对称）——
// 值折成了两行，左标签被垂直居中夹在中间 = 错位。宽度实测：折行前整串 ≈ 130pt。
let settingsSrc = src("Features/Settings/SettingsModelSheets.swift")
check("护栏：设置页文件读得到（读不到下面的断言会指向错处）", !settingsSrc.isEmpty)
let settingsClean = stripCommentLines(settingsSrc)
// 根因①：label 把质量说了两遍 —— 系统 name 自带「（高音质）」还再拼「· 优质」
check("音色 label 去重函数存在（名字已含质量字样就不再追加）",
      speechClean.contains("static func voiceLabel(name: String, tag: String)"))
check("音色 label 必须走去重函数（不许再直接拼 name + tag）",
      speechClean.contains("label: voiceLabel(name: v.name, tag: qualityTag(v))")
      && !speechClean.contains("\"\\($0.name) · \\(qualityTag($0))\"")
      && !speechClean.contains("\"\\(v.name) · \\(qualityTag(v))\""))
check("去重覆盖四类质量字样（高音质/高清/优质/增强）",
      speechClean.contains("[\"高音质\", \"高清\", \"优质\", \"增强\"]"))
// 根因②（防线）：值一旦折行，行内左标签就会被垂直居中 → 钉死单行
let sysVoiceRow = between(settingsClean, "Text(\"系统音色\")", "Text(voiceHintText")
check("系统音色行切片取到（空了下面的断言等于白写）", !sysVoiceRow.isEmpty)
check("系统音色行的值钉单行（折行=左标签被居中夹住=错位）",
      sysVoiceRow.contains(".lineLimit(1)")
      && !sysVoiceRow.contains(".truncationMode"))
// Spacer() 在 HStack 里本就带约 8pt 最小间距，`Spacer(minLength: 8)` 是**显式化**而非修复：
// 真正修好错位的是 SpeechManager 的 label 去重 + 值钉单行（上面两条）。这一条钉的是「别退回 0 间距」。
check("系统音色行显式留最小间距（退成裸 Spacer() 只是口径退回，视觉等价）",
      sysVoiceRow.contains("Spacer(minLength: 8)"))
// 同类行一并扫（神经语音「音色」行同样用 menu Picker 显示长名字）
let neuralVoiceRow = between(settingsClean, "Text(\"音色\")", "Text(\"开启后 AI 回复")
check("神经语音音色行切片取到", !neuralVoiceRow.isEmpty)
check("神经语音音色行同口径钉单行", neuralVoiceRow.contains(".lineLimit(1)"))

print("智慧球长按菜单真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
