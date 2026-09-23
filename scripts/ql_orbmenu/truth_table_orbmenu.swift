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
check("orbCenterGlobal 的 y 与可见球同一条几何公式",
      chatEffectsSrc.contains("keyWindowHeight - keyWindowSafeBottom - barH / 2 + dockContentCenterDrop"))
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
check("菜单开着时命中层隐藏（菜单层模态接管）",
      dockSrc.contains("if !showOrbMenu {") && dockSrc.contains("OrbHitLayer"))
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
check("不做全屏磨砂（方案 C 只取光晕——轻纱 0.12 是黑色淡遮罩非 material）",
      orbMenuSrc.contains("Color.black.opacity(shown ? 0.12 : 0)") && !orbMenuSrc.contains(".ultraThinMaterial"))
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
let columnDX = 64.0, upperDY = 160.0, lowerDY = 104.0

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
    let i = ((index % 4) + 4) % 4
    let isLeft = (i == 0 || i == 1)
    let isUpper = (i == 1 || i == 2)
    return (isLeft ? -columnDX : columnDX, -(isUpper ? upperDY : lowerDY))
}
let pts = (0..<4).map { center($0) }

// ① 四颗落点互不相同（曾出现两颗重合 = 视觉上压在一起）
check("四颗胶囊落点互不相同", Set(pts.map { String($0.x) + "," + String($0.y) }).count == 4)
// ② 两两不重叠（AABB：横向或纵向任一方向分开即不重叠）
func overlaps(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Bool {
    abs(a.x - b.x) < pillW && abs(a.y - b.y) < pillH
}
var overlapPairs: [String] = []
for i in 0..<4 {
    for j in (i + 1)..<4 where overlaps(pts[i], pts[j]) {
        overlapPairs.append(String(i) + "-" + String(j))
    }
}
check("四颗胶囊两两不重叠（AABB）", overlapPairs.isEmpty)
// ③ 最小间隙 ≥ 12pt（不重叠还不够——贴在一起观感仍是糊成一团）
let hGap = 2 * columnDX - pillW            // 同排水平间隙
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
let delays = (0..<4).map { Double($0) * 0.05 }
check("错峰延迟单调递增（50ms 步进）",
      zip(delays, delays.dropFirst()).allSatisfy { $1 > $0 }
      && abs(delays[3] - 0.15) < 1e-9)

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
      orbMenuSrc.contains("static let columnDX: CGFloat = 64")
      && orbMenuSrc.contains("static let upperDY: CGFloat = 160")
      && orbMenuSrc.contains("static let lowerDY: CGFloat = 104"))
check("落点单一真源 = OrbQuickMenuLayout.center",
      orbMenuSrc.contains("OrbQuickMenuLayout.center(index: index, ballCenter: ballCenter)"))
check("取模防越界（加第 5 颗胶囊不崩）", orbMenuSrc.contains("let i = ((index % 4) + 4) % 4"))
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
check("玻璃层不抢触摸（横幅本身可点，见 widgetURL）",
      widgetSrc.contains(".allowsHitTesting(false)"))

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

// ⑤ 展开态停止按钮改真玻璃（小元素上 glassEffect 在挂件里可渲染，装机确认）
check("停止按钮走 glassEffect(.regular.interactive())",
      widgetSrc.contains("glassEffect(.regular.interactive())"))
check("停止按钮旧淡底已清零", !widgetSrc.contains("background(OrbPalette.accent.opacity(0.22), in: Capsule())"))
check("停止按钮描边与 pill(.accent) 同参（accent 0.28 / 0.8pt）",
      widgetSrc.contains("Capsule().strokeBorder(OrbPalette.accent.opacity(0.28), lineWidth: 0.8)"))

print("智慧球长按菜单真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
