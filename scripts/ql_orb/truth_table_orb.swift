// 轻聊「欢迎页特征智能球」真值表（v3.9.57，本机可跑，不 import 项目代码）
//
// 守三件事：
//   ① 冻结判定语义 —— live=true 时 idle 不冻结；freezesMotion（减弱动态效果）优先于 live；
//      头像场景（live=false）保持 v3.9.2 起的静止态零 GPU 开销冻结设计
//   ② thinking 态永远不冻结（无论 live / freezesMotion）
//   ③ 源护栏 —— 欢迎页大球必须 live: true、接 AI 状态、带交互；
//      旧形态（气泡图标压在球上 + 渐变底圆）不得回归；消息头像/思考头像不得被误设 live
//
// 用法：python3 /opt/data/scripts/ql.py test
// 或单表：LD_LIBRARY_PATH=/opt/data/swift-libs \
//   /opt/data/swift-toolchain/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swiftc -O \
//   -o /tmp/tt_orb scripts/ql_orb/truth_table_orb.swift && /tmp/tt_orb

import Foundation

var failures = 0
var total = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok {
        print("✅ \(name)\(detail.isEmpty ? "" : " — " + detail)")
    } else {
        print("❌ \(name)\(detail.isEmpty ? "" : " — " + detail)")
        failures += 1
    }
}

// MARK: - ① 镜像冻结判定（源：LiquidOrbAvatar.swift 的 updatePacing）

/// 与源同口径：是否走冻结路径（播完过渡后 isPaused=true）
func mirrorShouldFreeze(state: String, live: Bool, freezesMotion: Bool) -> Bool {
    (state == "idle" && !live) || freezesMotion
}

check("头像场景（live=false）idle 冻结 —— 省电设计不回退",
      mirrorShouldFreeze(state: "idle", live: false, freezesMotion: false))
check("欢迎页特征球（live=true）idle 不冻结 —— 常驻流动",
      !mirrorShouldFreeze(state: "idle", live: true, freezesMotion: false))
check("thinking 永不冻结（live=true）",
      !mirrorShouldFreeze(state: "thinking", live: true, freezesMotion: false))
check("thinking 永不冻结（live=false，头像）",
      !mirrorShouldFreeze(state: "thinking", live: false, freezesMotion: false))
check("减弱动态效果优先于 live：freezesMotion=true 时头像 idle 仍冻结",
      mirrorShouldFreeze(state: "idle", live: false, freezesMotion: true))
check("减弱动态效果优先于 live：freezesMotion=true 时特征球 idle 也冻结",
      mirrorShouldFreeze(state: "idle", live: true, freezesMotion: true))
check("减弱动态效果下 thinking 也冻结（v3.9.42 口径不变）",
      mirrorShouldFreeze(state: "thinking", live: false, freezesMotion: true))

// MARK: - ② 源护栏

print("\n=== ② 源护栏 ===")

// v3.9.78：欢迎页形象从「96pt 液态球（Metal 着色器）」换成**用户拍板的卡通宠物**（三选一）。
// 本表原来的球渲染器护栏（live 透传 / 冻结判定）随之退役 —— 球文件保留但**不得再被引用**，
// 新的口径护栏见下：宠物组件 / 三只形态 / 动画三档 / 设置项同源 / 省电门控 / 不打扰红线。
let petPath = "/opt/data/qingliao_ios/qingliao/Features/Chat/PetAvatar.swift"
/// v3.9.79：形象枚举（PetKeys / PetStyle / PetMotion / PetState）已抽到 PetModel.swift
/// —— 实时活动挂件 target 也要编它（挂件不带 AppStorage/View）。枚举类断言一律读这里。
let petModelPath = "/opt/data/qingliao_ios/qingliao/Features/Chat/PetModel.swift"
let painterPath = "/opt/data/qingliao_ios/qingliao/Features/Chat/PetPainter.swift"
let chatPath = "/opt/data/qingliao_ios/qingliao/Features/Chat/ChatView.swift"
/// v4.0.x 工程治理拆分：通知名单（`extension Notification.Name`）与 AppDelegate 已从 ChatView.swift
/// 搬到 ChatAppDelegate.swift。凡是断言「通知名/通知广播」的真值表，**必须同时读这两个文件**——
/// 只读 ChatView.swift 会在拆分当天全部假红（本人实测：ql_orb 104 条里报红 1 条就是这个原因）。
/// 口径：名单是**全仓单一真源**，跨这两个文件合计只允许出现 1 次。
let chatDelegatePath = "/opt/data/qingliao_ios/qingliao/Features/Chat/ChatAppDelegate.swift"
let bubblePath = "/opt/data/qingliao_ios/qingliao/Features/Chat/ChatMessageBubble.swift"
let settingsPath = "/opt/data/qingliao_ios/qingliao/Features/Settings/SettingsCommon.swift"
// v4.0.6：宠物配置（形象三选一 + 表情 + 行为动作 + 动画三档）已从外观页**搬去独立页** PetStudioSheet，
// 入口挂在设置页顶部大头像。护栏的读取源随之改成「外观页 + 宠物页」两份，
// 断言内容不变（仍是同一组 key、同一套三选一 idiom），只是不再假定它住在外观页里。
let petStudioPath = "/opt/data/qingliao_ios/qingliao/Features/Settings/PetStudioSheet.swift"

let petSrc = (try? String(contentsOfFile: petPath, encoding: .utf8)) ?? ""
let petModelSrc = (try? String(contentsOfFile: petModelPath, encoding: .utf8)) ?? ""
// 读不到就报出来（否则断言会指向错处：enumLines("") 返回 []，「三只形象齐备」变红但看不出是文件被搬走）
check("护栏：PetModel.swift 读得到", !petModelSrc.isEmpty, petModelPath)
// 进挂件的**唯一理由**是「纯模型」：挂件 target 不编 View / 不读 @AppStorage（审查 F3）。
// 与 PetPainter 那条同类红线（!contains("import UIKit")）成对，别只钉一头。
// ⚠️ 必须先剥注释行：本文件的注释里为说明「为什么不能塞 AppStorage/View」会写出这些字样（实测假红）。
let petModelCode = petModelSrc.split(separator: "\n", omittingEmptySubsequences: false)
    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    .joined(separator: "\n")
check("PetModel.swift 是纯模型（无 View / 无 @AppStorage / 无 UIKit）——否则挂件编不过",
      !petModelCode.contains(": View") && !petModelCode.contains("@AppStorage")
      && !petModelCode.contains("import UIKit"))
let painterSrc = (try? String(contentsOfFile: painterPath, encoding: .utf8)) ?? ""
let chatSrc = (try? String(contentsOfFile: chatPath, encoding: .utf8)) ?? ""
let delegateSrc = (try? String(contentsOfFile: chatDelegatePath, encoding: .utf8)) ?? ""
let bubbleSrc = (try? String(contentsOfFile: bubblePath, encoding: .utf8)) ?? ""
let settingsSrc = (try? String(contentsOfFile: settingsPath, encoding: .utf8)) ?? ""
let petStudioSrc = (try? String(contentsOfFile: petStudioPath, encoding: .utf8)) ?? ""

// 读不到 → 全部护栏都会假绿，先钉住
check("护栏：PetAvatar.swift 读得到", !petSrc.isEmpty, petPath)
check("护栏：PetPainter.swift 读得到", !painterSrc.isEmpty, painterPath)
check("护栏：ChatView.swift 读得到", !chatSrc.isEmpty, chatPath)
check("护栏：ChatAppDelegate.swift 读得到", !delegateSrc.isEmpty, chatDelegatePath)
check("护栏：ChatMessageBubble.swift 读得到", !bubbleSrc.isEmpty, bubblePath)
check("护栏：SettingsCommon.swift 读得到", !settingsSrc.isEmpty, settingsPath)
check("护栏：PetStudioSheet.swift 读得到（v4.0.6 宠物配置新家）", !petStudioSrc.isEmpty, petStudioPath)

// ① 球退役：全仓不得再出现调用点（渲染器文件保留是为了可回滚，但一旦被引用说明口径被破坏）
func swiftSources(under dir: String) -> [(String, String)] {
    let fm = FileManager.default
    guard let en = fm.enumerator(atPath: dir) else { return [] }
    var out: [(String, String)] = []
    for case let rel as String in en where rel.hasSuffix(".swift") {
        let full = dir + "/" + rel
        out.append((full, (try? String(contentsOfFile: full, encoding: .utf8)) ?? ""))
    }
    return out
}
let allSources = swiftSources(under: "/opt/data/qingliao_ios/qingliao")
check("护栏：源码枚举不为空（空了下面的清零断言全是空真）", allSources.count > 50, "\(allSources.count) 个 .swift")
// A=（用户拍板）球渲染器**文件直接删掉**：不只是「没人调用」，而是不许再进包。
// 断言必须能区分「代码复活」与「注释里提了旧文件名」→ 查代码 token，不查任意字符串。
let orbPath = "/opt/data/qingliao_ios/qingliao/Features/Chat/LiquidOrbAvatar.swift"
let orbMetalPath = "/opt/data/qingliao_ios/qingliao/Features/Chat/LiquidOrbEffect.metal"
let orbTokens = ["LiquidOrbAvatar(", "LiquidOrbView(", "LiquidOrbSurface(", "LiquidOrbState", "orbUniformSeed"]
let orbResidue = allSources.filter { src in orbTokens.contains { src.1.contains($0) } }.map(\.0)
check("球渲染器文件已删除（A=删）+ 全仓无 LiquidOrbAvatar 代码残留（命中 \(orbResidue.count) 处：\(orbResidue.joined(separator: ","))）",
      !FileManager.default.fileExists(atPath: orbPath)
      && !FileManager.default.fileExists(atPath: orbMetalPath)
      && orbResidue.isEmpty)
check("护栏：幽灵路径（删错了也读不到的那两个文件）",
      orbPath.hasSuffix("LiquidOrbAvatar.swift") && orbMetalPath.hasSuffix("LiquidOrbEffect.metal"))
// 🚨 删源文件时**必须扫 CI 断言**：CI 的 Verify 原来硬断言包内有 default.metallib（护着那个着色器），
// 文件删了断言还在 → 这一版必然在 CI 判红（本轮实测拦下一次白烧构建）。这条护栏把两者绑死。
let workflowPath = "/opt/data/qingliao_ios/.github/workflows/build-ios.yml"
let workflowSrc = (try? String(contentsOfFile: workflowPath, encoding: .utf8)) ?? ""
check("护栏：CI workflow 读得到", !workflowSrc.isEmpty, workflowPath)
let metalLeft = allSources.contains { $0.0.hasSuffix(".metal") }
check("全仓已无 .metal 时，CI 不得再硬断言 default.metallib（否则包必然判红）",
      metalLeft || !workflowSrc.contains("❌ 包内缺 default.metallib"))
check("Metal 工具链那步改成条件式（有 .metal 才装，回头再加也不用改 CI）",
      workflowSrc.contains("if find qingliao -name '*.metal' | grep -q .; then"))

// ② 欢迎页形象 = 宠物（尺寸仍是 96pt：欢迎页身份，不因布局改动而变）
check("欢迎页形象 = PetAvatar 96pt",
      chatSrc.contains("PetAvatar(size: 96,"))
check("欢迎页形象走 petState（状态集中一处，调用点不写三元）",
      chatSrc.contains("state: petState,") && chatSrc.contains("private var petState: PetState {"))
// B=（用户拍板）alert 态**接线**：只接既有信号，不新增状态源
check("alert 接「后端离线」既有信号（serverOnline，欢迎页本来就没有失败通道）",
      chatSrc.contains("if serverOnline == false || generationFailed { return .alert }"))
check("生成失败判定提成单一真源（原来只写在 pushLiveActivity 里）",
      chatSrc.contains("private var generationFailed: Bool {")
      && chatSrc.contains("let streamFailed = generationFailed")
      && chatSrc.components(separatedBy: "stream.status == \"error\"").count - 1 == 1)
// 注释里提「为什么没接 unseen」是允许的（还有维护价值）→ 断言先**剥注释**，只查代码
func stripComments(_ src: String) -> String {
    src.split(separator: "\n").map { line -> String in
        if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
        return String(line)
    }.joined(separator: "\n")
}
check("不接死信号：欢迎页**代码**里不得出现 orbUnseen（本页可见期间它恒为假）",
      !stripComments(chatSrc).contains("orbUnseen"))
check("思考态仍归 aiBusy（既有状态变量，不新增状态源）",
      chatSrc.contains("return aiBusy ? .thinking : .idle"))
check("三只造型都有 alert 表情（不是只在组件加个角标）",
      painterSrc.components(separatedBy: "case .alert:").count - 1 == 3)
check("轻点挂抚摸触发器（petPat 自增 → 一次性反应；不进任何功能页）",
      chatSrc.contains("patTrigger: petPat") && chatSrc.contains("petPat += 1"))
check("护栏：球上不再压气泡图标",
      !chatSrc.contains("bubble.left.and.bubble.right.fill"))
check("护栏：球外渐变底圆已移除",
      !chatSrc.contains("v3.4.25：粒子球版 logo 替代静态渐变圆"))

// 切片：欢迎页形象那一块（从组件的 96pt 调用到 tap 分支）—— 按结构边界判定，不按全文件首个字符串命中。
// 终点取 `inputFocus = true`（tap 分支最后一句）：必须**晚于**长按分支与 tap 分支，
// 否则那几行落在切片外 → 断言假绿（第一次就踩到：终点写 TapGesture 行时「轻点聚焦输入框」直接假红）。
func slice(_ src: String, from: String, to: String) -> String {
    guard let a = src.range(of: from), let b = src.range(of: to, range: a.upperBound..<src.endIndex) else { return "" }
    return String(src[a.lowerBound..<b.upperBound])
}
let heroSrc = slice(chatSrc, from: "PetAvatar(size: 96,", to: "inputFocus = true")
check("护栏：欢迎页形象切片切得出（空了下面几条就是空真）", !heroSrc.isEmpty)
check("护栏：切片必须覆盖长按分支（终点锚点在长按之后）",
      heroSrc.contains("LongPressGesture(minimumDuration: 0.45)"))
// v4.0.0：命中域从裸 Rectangle() 扩成带 inset 的形状（走动位移 ±14pt 会溢出 96×96 框，
//   不扩则宠物走到框外那半截点不到）。护栏守的是「**形象有命中域**」这个意图，不是某个具体形状字面量。
// ⚠️ 命中域必须用**仓里真实存在**的 API。v4.0.0 连续两次猜错：
//   ① `Rectangle().inset(by: EdgeInsets)` → Rectangle 的 inset(by:) 收 CGFloat，编不过；
//   ② `Path(insetBy:)` → 这个重载根本不存在（iOS 17 的 Path 没有）。
//   终解是「裸 Rectangle() + 透明扩边 overlay」，两者都是 iOS 17 起就有的稳定 API。
// v4.0.0：命中域是两段 —— ①横向扩边 18pt 的透明 overlay（v4.0.0 踱步位移 ±14pt 会溢出 96×96 框，
// 不扩边则走到框外那半截点不到）；②96×96 本体 contentShape 双保险。
// ⚠️ 断言必须钉**扩边那一段的具体数字**：只判「文件里有 .contentShape(Rectangle())」会被
// ChatView 里另外 8 处同名调用满足 —— 删掉扩边层照样全绿（变异脚本 ⑱ 实测撞过）。
// ⚠️ 锚点必须带**本体那行前面那句注释**：ChatView 里 .contentShape(Rectangle()) 有 9 处，
// 只判「切片里有 contentShape」会被 overlay 扩边层那处满足 —— 删掉本体命中域照样全绿
// （变异脚本 ⑱ 实测撞过，exit=0 红=0）。
check("护栏：形象本体补了 contentShape 命中域（自身 allowsHitTesting(false)）",
      heroSrc.contains("双保险）\n        .contentShape(Rectangle())")
      && petSrc.contains(".allowsHitTesting(false)"))
// ⚠️ v4.0.2 补：上一版这条是无锚点的裸 contains（`.frame(96+18*2)` + `.contentShape`），
// 变异实测：删掉 overlay 里那行 `.contentShape(Rectangle())`（保留 Color.clear + 扩边 frame）
// 新旧两条**都还是绿的** —— 第二条被本体那处 contentShape 满足，等于没加任何保护。
// 现钉**三行连续**的 overlay 块（Color.clear → 扩边 frame → contentShape），
// 删任一行都红；顺序变了也红（overlay 的成立前提就是这两行叠在同一个 Color.clear 上）。
check("命中域扩边 overlay 三行连续在位（删任一行必红，v4.0.2 补锚点）",
      heroSrc.contains("Color.clear\n"
                     + "                .frame(width: 96 + 18 * 2, height: 96)\n"
                     + "                .contentShape(Rectangle())"))
// ⚠️ 这里刻意**没有**「不许出现 .contentShape(Rectangle())」这类断言：
//   裸 Rectangle 正是终解的一部分（96×96 本体命中 + overlay 扩边），
//   禁掉它会与上一条正向断言自相矛盾。真约束是「扩边靠 overlay」+「不猜不存在的重载」。
// 正向：扩边命中靠**透明 overlay**，不靠撑宽 frame（撑宽会把旁边文字挤走）
check("护栏：命中域扩边用透明 overlay（不撑宽 frame，避免挤走旁边文字）",
      heroSrc.contains("Color.clear") && heroSrc.contains("96 + 18 * 2"))
// 反向：不再出现那两个不存在的重载（v4.0.0 连续两次 CI 挂在这上面）。
// ⚠️ 必须先 stripComments —— 上面那段注释**故意**留着这两个坏 API 作为反面教材，
//    不剥注释就会自己判自己红。
let heroCode = stripComments(heroSrc)
check("护栏：代码里不再用 Rectangle().inset(by:)（收 CGFloat，编译失败）",
      !heroCode.contains("Rectangle().inset("))
check("护栏：代码里不再用 Path(insetBy:)（该重载不存在）",
      !heroCode.contains("Path(insetBy:"))
// 反向：扩边命中层不许退回「只靠本体」（那正是 v4.0.0 修前的失灵状态）
check("护栏：扩边命中层还在（位移 ±14pt 段仍可点）",
      heroCode.contains("Color.clear") && heroCode.contains("96 + 18 * 2"))

// ③ 交互口径：点 = 聚焦输入框 + 抚摸；**长按 = 与长按智慧球完全同一套快捷菜单**（v3.9.78 用户要求）
check("护栏：形象挂了 ExclusiveGesture（点/长按互斥）",
      heroSrc.contains("ExclusiveGesture("))
check("护栏：轻点聚焦输入框", heroSrc.contains("inputFocus = true"))
check("长按宠物 = 长按智慧球同一套菜单（切片内发 qingliaoOrbMenuFromPet）",
      heroSrc.contains(".qingliaoOrbMenuFromPet"))
check("长按宠物与长按球同一触感（Haptics.press，不是 .tap）",
      heroSrc.contains("Haptics.press()"))
check("长按不再直连语音转文字（改由菜单里的「语音输入/语音对话」进）",
      !heroSrc.contains("toggleVoiceMode("))
check("菜单锚点 = 宠物真实中心（全局坐标 + 96pt，走 onGeometryChange 实时量）",
      heroSrc.contains("OrbPetAnchor(center: petGlobalCenter, size: 96)")
      && chatSrc.contains("} action: { petGlobalCenter = $0 }"))
check("护栏：输入框/发送键长按仍走 toggleVoiceMode（没被宠物改动误伤）",
      chatSrc.contains("toggleVoiceMode(keyboardWasUp: kb.isVisible)"))
check("护栏：长按的 keyboardWasUp 用 kb.isVisible（不是 inputFocus）",
      !chatSrc.contains("toggleVoiceMode(keyboardWasUp: inputFocus)"))

// ⑦ 长按宠物 → 复用智慧球那一套菜单层（单真源，不在聊天页搭第二套）
let menuPath = "/opt/data/qingliao_ios/qingliao/Features/OrbQuickMenu.swift"
let dockPath = "/opt/data/qingliao_ios/qingliao/Features/DockTabView.swift"
let effectsPath = "/opt/data/qingliao_ios/qingliao/Features/Chat/ChatEffects.swift"
let identifyPath = "/opt/data/qingliao_ios/qingliao/Features/OrbIdentifyOverlay.swift"
let menuSrc = (try? String(contentsOfFile: menuPath, encoding: .utf8)) ?? ""
let dockSrc = (try? String(contentsOfFile: dockPath, encoding: .utf8)) ?? ""
let effectsSrc = (try? String(contentsOfFile: effectsPath, encoding: .utf8)) ?? ""
let identifySrc = (try? String(contentsOfFile: identifyPath, encoding: .utf8)) ?? ""
check("护栏：OrbQuickMenu/DockTabView/ChatEffects/OrbIdentifyOverlay 都读得到（空了下面的断言就是空真）",
      !menuSrc.isEmpty && !dockSrc.isEmpty && !effectsSrc.isEmpty && !identifySrc.isEmpty)
check("护栏：OrbQuickMenu.swift 读得到", !menuSrc.isEmpty, menuPath)
check("护栏：DockTabView.swift 读得到", !dockSrc.isEmpty, dockPath)
check("菜单锚点做成参数（dock 球 / 宠物），不是两套菜单",
      menuSrc.contains("enum OrbQuickMenuAnchor: Equatable {") && menuSrc.contains("case pet(size: CGFloat)")
      && menuSrc.contains("var anchor: OrbQuickMenuAnchor = .dockOrb"))
// 🚨 v3.9.82 口径（用户 2026-09-27：「长按智慧球跳转画面改为长按卡通宠物跳转画面，只保留一个跳转画面」）：
//    画法**只留宠物这一套** —— 上面那条「dock 分支口径一字未改（仍是 SiriBallView）」已**故意作废**：
//    dock 入口也画宠物，球版分支整段删掉。谁把球版加回来，这里就红。
check("菜单锚点画法只留宠物（v3.9.82：不是「按宠物弹出一颗球」，也不是两种画法）",
      menuSrc.contains("PetAvatar(size: anchorSize, state: thinking ? .thinking : .idle)")
      && !menuSrc.contains("SiriBallView"))
check("锚点尺寸仍走单一真源（dock → DockOrbOverlay.defaultBallSize / 宠物 → 自己的尺寸）",
      menuSrc.contains("return DockOrbOverlay.defaultBallSize"))
check("宠物只覆盖锚点中心，几何原点与坐标换算不变",
      menuSrc.contains("let c = petAnchor?.center ?? DockOrbOverlay.floatingOrbCenter(barHeight: barH)")
      && menuSrc.contains("ballCenter: CGPoint(x: c.x - g.minX, y: c.y - g.minY)"))
// v4.0.79：球从 dock 槽位摘出、浮在 dock 上方 → 全仓都不该再有「读槽位坐标 / 手算等分」的几何
//（旧口径 slotCenterGlobal + width*(i+0.5)/n 已整块退役；留一处就是两套几何 → 球按不到）。
check("球心只走单一出口（全仓无槽位坐标读取、无手算等分）",
      !menuSrc.contains("slotCenterGlobal")
      && !menuSrc.contains("geo.size.width *")
      && !effectsSrc.contains("static func slotCenterGlobal"))
check("动作分发单一真源：聊天页没有复制 handleOrbAction",
      dockSrc.contains("onReceive(NotificationCenter.default.publisher(for: .qingliaoOrbMenuFromPet))")
      && !chatSrc.contains("handleOrbAction("))
check("接收侧把锚点交给菜单并复用 handleOrbAction（六条入口不变）",
      dockSrc.contains("petAnchor: orbMenuPetAnchor,") && dockSrc.contains("onAction: { handleOrbAction($0) }"))
// ⚠️ 必须断言**跨行片段**：拆成两段 contains 时，把 `petAnchor = nil` 挪进 else（行为反转）也照样绿
//    —— 发版前审查第二轮实测指出（当时就是这么写宽的）。
check("菜单收起即清锚点（否则下次长按球会锚在宠物位置）",
      dockSrc.contains("if !shown {\n                    petAnchor = nil"))
check("互斥口径与 dock 命中层一致（识别浮层/语音页开着时不弹）",
      dockSrc.contains("guard !showOrbMenu, !blocked else { return }")
      && dockSrc.contains("blocked: showIdentify || showVoiceDialog"))
// 相对位置断言：带闭包的 onReceive 必须在 modifier 定义**之后**（= 在它体内），不能在 body 链上。
// （别写成 !contains(...) —— 那个字符串在 modifier 里本来就有，写成取反只会假红）
let iMenuModifier = dockSrc.range(of: "private struct OrbMenuFromPetModifier: ViewModifier {")
let iMenuOnReceive = dockSrc.range(of: ".onReceive(NotificationCenter.default.publisher(for: .qingliaoOrbMenuFromPet))")
check("body 巨型链上只挂一个 .modifier，带闭包的修饰符收进独立类型（否则类型检查超时）",
      dockSrc.contains(".modifier(OrbMenuFromPetModifier(showOrbMenu: $showOrbMenu,")
      && iMenuModifier != nil && iMenuOnReceive != nil
      && iMenuModifier!.lowerBound < iMenuOnReceive!.lowerBound)
check("菜单浮层抽成独立计算属性（8 参 + 两闭包不留 body 里）",
      dockSrc.contains("var orbMenuOverlay: some View {") && dockSrc.contains("if showOrbMenu { orbMenuOverlay }"))
// ── v3.9.79：长按菜单弹出即收键盘（用户 2026-09-25 真机：「这个界面自动收回键盘」）──
// 由头：键盘开着时长按球/宠物，六颗胶囊被键盘挤在上半屏。收在 `showOrbMenu` 一处 onChange
// （长按球 OrbHitLayer 与长按宠物 .qingliaoOrbMenuFromPet 两条路都经过它），键盘实际怎么收在 ChatView 侧。
// ⚠️ v3.9.79 审查后口径变更：广播点**合进既有 `OrbMenuFromPetModifier`**（同一个 onChange），
//    不再单独加第二个 .modifier —— body 巨型链上多一个泛型调用就是 CI run #571 类型检查超时那类风险。
check("菜单弹出即收键盘：收在既有修饰符的 onChange(of: showOrbMenu) 里（两条打开路径都覆盖）",
      dockSrc.contains("private struct OrbMenuFromPetModifier: ViewModifier {")
      && dockSrc.contains(".onChange(of: showOrbMenu) { _, shown in"))
// 相对位置断言：post 必须在修饰符定义之后（= 在它体内），不许挂回 body 巨型链
let iDismissModifier = dockSrc.range(of: "private struct OrbMenuFromPetModifier: ViewModifier {")
let iDismissPost = dockSrc.range(of: "NotificationCenter.default.post(name: .qingliaoDismissKeyboard, object: nil)")
check("收键盘的 post 收在 else 分支里（＝菜单**弹出**时收；挪到别处任何位置都该变红）",
      iDismissModifier != nil && iDismissPost != nil
      && iDismissModifier!.lowerBound < iDismissPost!.lowerBound
      && dockSrc.contains("} else {\n                    NotificationCenter.default.post(name: .qingliaoDismissKeyboard, object: nil)"))
check("dock body 巨型链上只挂一个 .modifier（多挂一个泛型调用 = 类型检查超时，run #571 实录）",
      dockSrc.components(separatedBy: ".modifier(OrbMenuFromPetModifier(").count - 1 == 1
      && !dockSrc.contains(".modifier(OrbMenuKeyboardDismissModifier("))
check("通知名单一真源（只在一处定义）",
      (chatSrc.components(separatedBy: "static let qingliaoDismissKeyboard = Notification.Name(").count - 1)
        + (delegateSrc.components(separatedBy: "static let qingliaoDismissKeyboard = Notification.Name(").count - 1) == 1)
// ── v3.9.79b：菜单锚点必须跟着宠物走（发版前审查实测的真机交互缺陷）──
// 链：菜单弹出即收键盘 → 宠物随 Spacer 回弹下移 ≥56pt → 锚点若还停在长按那一刻的快照，
//     菜单层会在旧位置**再画一只宠物** → 观感「两只宠物 + 胶囊挂在上方那只身上」。
// 两条通知必须分开：拿「打开菜单」那条来做锚点刷新，宠物任何位移都会把菜单重新弹出来。
check("锚点刷新走独立通知（不能复用「打开菜单」那条，否则宠物位移会重弹菜单）",
      menuSrc.contains("static let qingliaoPetAnchorMoved = Notification.Name(\"qingliao_pet_anchor_moved\")")
      && menuSrc.contains("static let qingliaoOrbMenuFromPet = Notification.Name(\"qingliaoOrbMenuFromPet\")"))
check("聊天页：宠物真实中心一变即广播锚点（onGeometryChange 之后紧接 onChange）",
      chatSrc.contains("} action: { petGlobalCenter = $0 }")
      && chatSrc.contains(".onChange(of: petGlobalCenter) { _, center in")
      && chatSrc.contains("userInfo: OrbPetAnchor(center: center, size: 96).userInfo)"))
let anchorRefreshSlice = slice(dockSrc,
                               from: ".onReceive(NotificationCenter.default.publisher(for: .qingliaoPetAnchorMoved))",
                               to: "    }\n}\n")
check("dock 侧锚点刷新切片切得出（空了本条就是空真）", !anchorRefreshSlice.isEmpty)
check("dock 侧只在菜单开着时更新锚点（关着丢弃，且**不打开**菜单）",
      anchorRefreshSlice.contains("guard showOrbMenu, !blocked else { return }")
      && !anchorRefreshSlice.contains("showOrbMenu = true"))
// ── v4.0.79：球浮到 dock 上方后，烟花原点不再需要槽位号（球恒在屏幕水平中线上）──
check("烟花原点与浮动球心同源（不再传槽位号，旧接口已退役）",
      dockSrc.contains("floatingBallCenterFromBottom(barHeight: dockBarHeight")
      && !effectsSrc.contains("static func ballCenterFromBottom(")
      && effectsSrc.contains("return barH + floatingGap + ballSize / 2"))
// ── v3.9.82：译文改弹窗后，这条护栏跟着搬（译文卡整套搬进 Features/TranslateSheet.swift）──
// 旧断言钉的是 restartTranslate 里的「已复制」复位 —— 那段状态随译文卡一起走了。
// 现在钉「浮层不再持有复制反馈状态」（两处状态各管各 = 迟早漂移）；弹窗侧由
// scripts/ql_translatesheet/ 那张表管。
check("译文卡搬走后浮层不再持有「已复制」状态（两处不再打架）",
      !identifySrc.contains("copiedTranslation")
      && identifySrc.contains("private func restartTranslate() {\n        translateMode = true"))
check("翻译只一问一答：oneShot 超时收到 30s（默认 120s 会让卡 2 分钟无可重试、无可取消）",
      identifySrc.contains("auth: auth, timeout: 30)"))
// ChatView 侧：消费通知 + 收法与语音模式同口径（先清 FocusState，再 60ms UIKit 兜底）
let dismissSlice = slice(chatSrc,
                         from: ".onReceive(NotificationCenter.default.publisher(for: .qingliaoDismissKeyboard))",
                         to: ".onAppear {")
check("ChatView 收键盘切片切得出（空了后面全是空真）", !dismissSlice.isEmpty)
check("收法 = 先清 FocusState 让输入栏缩回第一层，再 60ms UIKit 兜底（iOS 27 触摸聚焦会覆盖 FocusState）",
      dismissSlice.contains("inputFocus = false")
      && dismissSlice.contains("try? await Task.sleep(for: .seconds(0.06))")
      && dismissSlice.contains("UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),"))
check("语音入口没丢：菜单里仍有「语音输入」+「语音对话」",
      menuSrc.contains("title: \"语音输入\"") && menuSrc.contains("title: \"语音对话\""))
check("宠物锚点打包/解包成对（NSValue 包 CGPoint，尺寸随包带）",
      menuSrc.contains("var userInfo: [String: Any] { [\"center\": NSValue(cgPoint: center), \"size\": size] }")
      && menuSrc.contains("init?(userInfo: [AnyHashable: Any]?)"))

// ④ 组件口径：三只形态 + 三档动画 + 两个设置 key
// 形态/档位一律**按枚举体精确判定**——子串式 contains("case seal") 会被 "case sealX" 骗过（反向自证实锤过）
func enumLines(_ src: String, _ name: String) -> [String] {
    guard let a = src.range(of: "enum \(name)"),
          let b = src.range(of: "\n}", range: a.upperBound..<src.endIndex) else { return [] }
    return src[a.upperBound..<b.lowerBound].split(separator: "\n").compactMap { line -> String? in
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("case "), !t.hasPrefix("case .") else { return nil }
        return t.dropFirst(5).split(separator: " ").first.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ","))
        }
    }
}
let styleCases = enumLines(petModelSrc, "PetStyle")
// v4.0.1：三只改「圆胖小兽 / 圆头小机器人」，但**槽位 rawValue 故意不变**（cat / seal）——
// 老用户 UserDefaults 与在跑的实时活动 ContentState.petStyle 靠它认人，改名=静默回第一格。
check("三只形象齐备且顺序固定（liquid / beast / robot —— 设置页三格顺序跟着它）",
      styleCases == ["liquid", "beast", "robot"], styleCases.joined(separator: "/"))
check("槽位 rawValue 仍沿用旧的 cat / seal（改了会静默回落第一格：老设置与在跑的实时活动都认不出）",
      styleCases.count == 3
      && petModelSrc.contains("case beast = \"cat\"") && petModelSrc.contains("case robot = \"seal\""))
check("三只名字是圆形基形这一代（液态小生物 / 圆胖小兽 / 圆头小机器人）",
      petModelSrc.contains("return \"液态小生物\"") && petModelSrc.contains("return \"圆胖小兽\"")
      && petModelSrc.contains("return \"圆头小机器人\""))
let motionCases = enumLines(petModelSrc, "PetMotion")
check("动画三档齐备且顺序固定（system / reduced / off）",
      motionCases == ["system", "reduced", "off"], motionCases.joined(separator: "/"))
check("三只都有各自画法（不是同一套换色；锚点带括号，防「drawRobotX」式假绿）",
      painterSrc.contains("private func drawLiquid(") && painterSrc.contains("private func drawBeast(")
      && painterSrc.contains("private func drawRobot("))
// v4.0.1 圆形基形口径：主形是一个圆（画笔里必须有 shell 共用壳），个体靠附件区分。
// 这条不是「证明存在」的空真：变异脚本 ㉘ 把 shell 调用换掉就会红。
check("圆形基形：主形走共用壳 shell（三个尺寸各自给半径），个体只靠附件区分",
      painterSrc.contains("private func shell(")
      && painterSrc.contains("shell(&layer, s, radius: 0.40,") && painterSrc.contains("shell(&layer, s, radius: 0.37,")
      && painterSrc.contains("shell(&layer, s, radius: 0.38,"))
check("三只附件齐全（液态=两只小手 / 小兽=两只圆耳 / 机器人=天线+面罩带）",
      // v4.0.26：液态的手改为**姿势驱动**（不再写死坐标 0.17/0.83，改为按 handCenter 定位）。
      // 断言随之升级：钉「手按 handCenter 画 + 手色比身体深一档」——
      //   · 比钉死坐标更抗改（以后调手势参数不必同步改这条）
      //   · 仍然挡得住「把手删了」「手色改回同色系（=隐形）」两种真回归
      painterSrc.contains("r(c.x / s, c.y / s, 0.070, 0.082, s)")
      && painterSrc.contains("Pal.liquidDeep")
      && painterSrc.contains("for cx in [CGFloat(0.255), CGFloat(0.745)]")
      && painterSrc.contains("rounded(0.49, 0.02, 0.02, 0.15, 0.01, s)") && painterSrc.contains("var visor = Path()"))
// v4.0.2 起的核心几何护栏：附件**必须真的露在身体外面**，否则「圆+附件」= 一个光球。
// ⚠️ 几何数值**必须从 painterSrc 真抓**（不是表里写死）：v4.0.2 实测写死版是**假绿** ——
//   把源码内耳半径改成 0.042（被身体全盖的死代码）时，表里仍按 0.050 算 → 全绿。
// 抓不到（模式与源码漂移）时**必须报红**：空真比没断言更坏。
// 正则刻意带**后续 with: 颜色/角度**做锚，否则 `r(cx, ...)` 会先匹配到别处。
func grabOne(_ re: String, _ groups: Int = 2) -> [Double]? {
    guard let m = try? NSRegularExpression(pattern: re),
          let hit = m.firstMatch(in: painterSrc, range: NSRange(painterSrc.startIndex..., in: painterSrc))
    else { return nil }
    let ns = painterSrc as NSString
    var out: [Double] = []
    for i in 1 ... groups {
        let r = hit.range(at: i)
        guard r.location != NSNotFound, let d = Double(ns.substring(with: r)) else { return nil }
        out.append(d)
    }
    return out
}
let earCX   = grabOne("for cx in \\[CGFloat\\(([0-9.]+)\\), CGFloat\\(([0-9.]+)\\)\\]")
let earOutG = grabOne("r\\(cx, ([0-9.]+), ([0-9.]+), [0-9.]+, s\\)\\), with: \\.color\\(Pal\\.beastMid")
let earInG  = grabOne("r\\(cx, ([0-9.]+), ([0-9.]+), [0-9.]+, s\\)\\), with: \\.color\\(Pal\\.beastEarIn")
let bodyR   = grabOne("shell\\(&layer, s, radius: ([0-9.]+),\\s*\\n\\s*stops: \\[\\(0\\.0, Pal\\.beastTop\\)", 1)?.first
// 眉带两条弧：圆心必须**与半径同在一条 addArc 上**抓（分开抓会先命中 shell() 里那条
// 同形的底部反光弧 center p(0.5, 0.5, s) → 圆心抓成 0.5，带子位置全错）。
// 两条弧靠**角度**区分：内弧 .degrees(250)→290，外弧 .degrees(290)→250。
let visorIn  = grabOne("addArc\\(center: p\\(0\\.5, ([0-9.]+), s\\), radius: ([0-9.]+) \\* s,\\s*\\n\\s*startAngle: \\.degrees\\(250\\)", 2)
let visorOut = grabOne("addArc\\(center: p\\(0\\.5, ([0-9.]+), s\\), radius: ([0-9.]+) \\* s,\\s*\\n\\s*startAngle: \\.degrees\\(290\\), endAngle: \\.degrees\\(250\\)", 2)
check("三只附件几何能从源码抓到（抓不到 = 下面几条全是空真，必须报红）",
      earCX != nil && earOutG != nil && earInG != nil && bodyR != nil
      && visorIn != nil && visorOut != nil,
      "cx=\(String(describing: earCX)) 耳=\(String(describing: earOutG)) 内耳=\(String(describing: earInG)) 体=\(String(describing: bodyR)) 内弧=\(String(describing: visorIn)) 外弧=\(String(describing: visorOut))")
// 露出量 = 附件外沿到体心距离 - 体半径（镜像 PetPainter「附件画在主形之前」的遮挡语义）
func expose(_ cx: Double, _ cy: Double, _ rad: Double, _ body: Double) -> Double {
    (hypot(cx - 0.5, cy - 0.5) + rad) - body
}
if let cx = earCX?.first, let eg = earOutG, let ig = earInG, let br = bodyR {
    let out = expose(cx, eg[0], eg[1], br)
    let inn = expose(cx, ig[0], ig[1], br)
    check("小兽耳朵真露在身体外（露出 ≥8pt@96pt：旧值只露 4.3pt，等于没有耳朵）",
          out * 96 >= 8.0, String(format: "外耳露出 %.1fpt", out * 96))
    check("小兽内耳也真露在身体外（≥3pt@96pt：旧几何 0.26pt → 完全被盖 = 死代码）",
          inn * 96 >= 3.0, String(format: "内耳露出 %.1fpt", inn * 96))
}
// 机器人眉带必须真压到**眼上沿**，且不能整条飘到眼睛上方或整条掉进眼睛里。
// ⚠️ 判据必须**双边**：v4.0.2 实测只判 `lo ≤ 0.415` 是单边漏洞 —— 把外弧从 0.275 缩到
// 0.20 时 lo 仍 = 0.66-0.248 = 0.412 ≤ 0.415 → 假绿，可带子已高悬在眼睛上方、完全不碰眼。
// 正确语义：带子 y 区间 [lo,hi] 必须与眼上沿**有交叠**（lo ≤ 0.415 ≤ hi），
// 且不能盖满整只眼（hi ≤ 0.45，眼高 0.415~0.494）。
if let vi = visorIn, let vo = visorOut {
    let lo = vi[0] - max(vi[1], vo[1]), hi = vi[0] - min(vi[1], vo[1])
    check("机器人眉带真压着眼上沿（带子 y 区间须跨过 0.415：旧几何 y 0.331~0.389 一线不沾眼；"
          + "单边判据是假绿漏洞，缩小弧反而不报红）",
          lo <= 0.415 && hi >= 0.415,
          String(format: "带子 y %.3f~%.3f，眼上沿 0.415", lo, hi))
    check("机器人眉带不盖住整只眼（带子上沿 ≤0.45：眼占 0.415~0.494）",
          hi <= 0.45, String(format: "带子上沿 %.3f", hi))
}
// v4.0.2 高危：rotated() 的旋转中心**不能再乘一次 s**。around 传的是 p(x,y,s)（已缩放），
// 旧代码 `around.x * s` → 中心跑到 s² 尺度（96pt 下 (1981,-143)）→ 附件/高光全被
// 裁到画布外 = 「液态的小手从不显示」。这里钉住旋转中心不缩放。
check("旋转中心不二次缩放（around 已是 p() 的绝对坐标；再乘 s 会把附件/高光甩出画布）",
      !painterSrc.contains("translationX: around.x * s") && !painterSrc.contains("y: around.y * s")
      && painterSrc.contains("CGAffineTransform(translationX: around.x, y: around.y)"))
check("两个设置 key 收在 PetKeys（单一真源）",
      petModelSrc.contains("static let style = \"qingliao_pet_style\"")
      && petModelSrc.contains("static let motion = \"qingliao_pet_motion\""))
check("76pt 以下自动简化（30/38pt 头像走简化形态，细节不糊；设置页缩略图走 keepDetail 旁路）",
      petModelSrc.contains("static let simplifyBelow: CGFloat = 76")
      && petSrc.contains("private var simplify: Bool { keepDetail ? false : size < PetKeys.simplifyBelow }"))
check("省电门控：关闭 / 减弱 / 后台 一律不动",
      petSrc.contains("case .off: return false") && petSrc.contains("case .reduced: return false")
      && petSrc.contains("scenePhase == .active"))
check("呼吸与眨眼都受 animate 门控（关掉后必须完全静止）",
      petSrc.contains("breath && animate") && petSrc.contains("guard animate"))
check("状态冗余表达：形象对 VoiceOver 隐藏（信息另有文案/角标通道）",
      petSrc.contains(".accessibilityHidden(true)"))
check("不打扰红线：组件自身不出声、不发触感（触感由宿主的用户手势触发）",
      !petSrc.contains("Haptics") && !petSrc.contains("AVAudio") && !petSrc.contains("UIImpactFeedbackGenerator"))
check("零依赖：画笔只有 SwiftUI（不引 Lottie / Rive / 任何运行时）",
      painterSrc.contains("import SwiftUI") && !painterSrc.contains("import Lottie")
      && !painterSrc.contains("import RiveRuntime") && !painterSrc.contains("import UIKit"))

// ⑤ 消息头像：v4.0.31 删两侧头像、v4.0.32 思考期头像也删（用户复看截图拍板）—— 反转为删除护栏
check("思考头像（38pt）已删（思考期只留三点气泡本体，ChatView 清零）",
      !chatSrc.contains("PetAvatar(size: 38"))
// v4.0.31：消息头像已删（用户拍板「取消 AI 头像和我的头像」）—— 断言反转为删除护栏
check("消息头像（30pt）已删（PetAvatar(size: 30 全仓气泡文件清零）",
      !bubbleSrc.contains("PetAvatar(size: 30"))
check("消息头像未误设常驻（无 live / repeatForever 类标记）",
      !bubbleSrc.contains("live: true"))

// ⑥ 设置项：设置页顶部大头像 → PetStudioSheet（形象三选一 + 表情 + 行为动作 + 动画三档），且与聊天页同源
// v4.0.6 起这段住在 PetStudioSheet.swift；外观页**必须已经不在**（两处都能改迟早不一致）。
check("宠物配置有独立页（PetStudioSheet）且从设置页顶部进",
      petStudioSrc.contains("struct PetStudioSheet"))
check("形象三选一走 PetStyle.allCases（加形态不用改设置页）",
      petStudioSrc.contains("ForEach(PetStyle.allCases)"))
check("动画三档走 PetMotion.allCases",
      petStudioSrc.contains("ForEach(PetMotion.allCases)"))
check("设置页读的是同一组 key（不是另写一份，本地/云端天然一致）",
      petStudioSrc.contains("@AppStorage(PetKeys.style)") && petStudioSrc.contains("@AppStorage(PetKeys.motion)"))
check("缩略图按显示尺寸直接画（52 画 = 52 显示，keepDetail 保细节）——不得再用「96 画 + frame 52」硬塞（会溢出卡片）",
      petStudioSrc.contains("PetAvatar(size: 52, state: .idle, styleOverride: style,")
      && !petStudioSrc.contains(".frame(width: 52, height: 52)"))
check("选中态可见（蓝框/highlight）+ 无障碍标注",
      petStudioSrc.contains("accessibilityLabel(\"形象：\\(style.name)\")")
      && petStudioSrc.contains("accessibilityAddTraits(selected ? [.isSelected] : [])"))
// 🚨 反向红线：这段已经从外观页搬走，别为了"好找"又复制回去
check("外观页不再重复宠物配置（搬走不是复制）",
      !settingsSrc.contains("Section(\"聊天页形象\")") && !settingsSrc.contains("ForEach(PetStyle.allCases)"))

print(failures == 0 ? "\n🎉 真值表全部通过（\(total) 项）" : "\n💥 失败 \(failures)/\(total) 条")
exit(failures == 0 ? 0 : 1)
