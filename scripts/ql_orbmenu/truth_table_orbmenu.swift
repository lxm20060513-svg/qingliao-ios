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
check("环形绽放 = 弧线错峰入场", orbMenuSrc.contains("private static let angles") && orbMenuSrc.contains(".delay(Double(index) * 0.05)"))
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

// ── 5. 纯计算回归：弧线落点几何 ──────────────────────────────
// 镜像 OrbQuickMenuLayer 的 pillOffset 计算（度→弧度、外侧半径放大）
let angles: [Double] = [-57, -19, 19, 57]
func offset(_ deg: Double) -> (x: Double, y: Double) {
    let a = deg * Double.pi / 180
    let r = 106 + abs(deg) / 57 * 30
    return (sin(a) * r, -cos(a) * r)
}
// 中心两颗在球心上方且近似对称
let l1 = offset(angles[1]), r1 = offset(angles[2])
check("中间两颗左右对称", abs(l1.x + r1.x) < 0.001)
check("胶囊都在球心上方", angles.allSatisfy { offset($0).y < 0 })
// 外侧两颗半径更大 → 拱形弧线（y 比中间的高不了太多但 x 分得更开）
let l0 = offset(angles[0]), r0 = offset(angles[3])
check("外侧两颗比中间分得更开", abs(l0.x) > abs(l1.x) * 2.0)
// 向上拱：中间两颗最高（y 最小 = 屏上最高），外侧两颗更低 → 拱顶在中间、两翼下垂。
// ⚠️ 方向别写反：屏幕 y 向下增大，所以「拱顶」= y 更小。首版断言写成 l0.y < l1.y 是错的（假红）。
check("弧线：拱顶在中间两颗（外侧 y 更大 = 更低）", l0.y > l1.y && r0.y > r1.y)
check("弧线左右对称", abs(l0.y - r0.y) < 0.001 && abs(l0.x + r0.x) < 0.001)
// 胶囊整体仍在球心上方（不能压到 dock / 屏幕外）
check("四颗胶囊都在球心上方 40～130pt 区间", angles.allSatisfy { (40...130).contains(-offset($0).y) })
// 错峰延迟单调（50ms 步进）——⚠️ 不能直接 == [0,0.05,0.10,0.15]：0.05*3 二进制不精确
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

// ── 7. 发版前双审查修复的护栏（v3.9.59） ─────────────────────
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
// ③ 弧线几何与源码字面量绑定（第 5 节是镜像计算，源码改了必须同步改表）
check("弧线角度表与源码绑定", orbMenuSrc.contains("[-57, -19, 19, 57]"))
check("弧线半径公式与源码绑定", orbMenuSrc.contains("106 + abs(deg) / 57 * 30"))
check("角度表取模防越界（加第 5 颗胶囊不崩）", orbMenuSrc.contains("Self.angles[index % Self.angles.count]"))
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

print("智慧球长按菜单真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
