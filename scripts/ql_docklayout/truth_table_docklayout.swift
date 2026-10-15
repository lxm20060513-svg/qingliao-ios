import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// ql_docklayout 真值表 —— v4.0.82「Dock 栏设置（顺序 + 隐藏）」
//
// 用户口径（2026-10-09 原话）：「设置里面增加 dock 栏设置，聊天、生活、看板、设置页可以调整顺序，
// 可以隐藏某一页，唯独设置页不能隐藏」。
//
// v4.0.108（用户 2026-10-14：「在 dock 加一个 tab 叫工作区」）—— **4 档 → 5 档**：
//   出厂序 = chat,life,workspace,dashboard,settings（工作区排第 3，紧跟「生活」）。
//   ⚠️ 本表所有期望值已整组翻成 5 档口径；**老用户已存的 4 档顺序串不迁移**（sanitizedOrder 把
//      缺的档按出厂序补到末尾 = 工作区出现在 dock 最右），下面有一条专门的断言钉这个行为。
//
// 编译方式（纯源码，不混 SwiftUI —— 仓规）：
//   swiftc -swift-version 6 main.swift qingliao/Core/DockLayoutKit.swift -o /tmp/tt
// 本表覆盖两层：
//   ① 纯逻辑真值：DockLayoutKit 的顺序净化 / 隐藏净化 / 渲染裁剪 / 槽位序号；
//   ② 源护栏：把「用户可见的真挂载」钉住（渲染走配置、几何不写死、设置页入口真接上了）。
// ═══════════════════════════════════════════════════════════════════════════════

// Swift 6 严格并发：main.swift 顶层代码是 @MainActor 隔离的，而顶层变量不能挂 global actor
// → 计数器用 nonisolated(unsafe)（单线程顺序跑，无并发访问），这样 check 从顶层调用得通
nonisolated(unsafe) var ok = 0
nonisolated(unsafe) var fail = 0
func check(_ name: String, _ cond: Bool) {
    if cond { ok += 1; print("  ✓ \(name)") } else { fail += 1; print("  ❌ \(name)") }
}

/// 仓根：优先当前目录（手动跑 = cd 仓根），兜底固定路径（表只在本仓用）
func repoRoot() -> String {
    let cwd = FileManager.default.currentDirectoryPath
    if FileManager.default.fileExists(atPath: cwd + "/qingliao/Core/DockLayoutKit.swift") { return cwd }
    return "/opt/data/qingliao_ios"
}
func readSource(_ rel: String) -> String {
    (try? String(contentsOfFile: repoRoot() + "/qingliao/" + rel, encoding: .utf8)) ?? ""
}

let A = DockLayoutKit.allRaw
let D_ORDER = "chat,life,workspace,dashboard,settings"
/// v4.0.108 之前的出厂序（老用户机器上存的就是这个值）
let D_ORDER_LEGACY = "chat,life,dashboard,settings"

print("== ⓿ allRaw 口径：5 档（v4.0.108 加「工作区」）")
check("allRaw 恰好 5 档", A.count == 5)
check("工作区排第 3（chat,life,workspace,dashboard,settings）",
      A == ["chat", "life", "workspace", "dashboard", "settings"])
check("defaultOrderRaw 与 allRaw 同序", DockLayoutKit.defaultOrderRaw == D_ORDER)

print("== ① sanitizedOrder：顺序净化（坏串一律回出厂序，宁可回默认也不许悄悄少一格）")
check("空串 → 出厂序", DockLayoutKit.sanitizedOrder("") == A)
check("出厂序原样通过", DockLayoutKit.sanitizedOrder(D_ORDER) == A)
check("设置页可前移（顺序自由：用户只说不能隐藏，没说不能移动）",
      DockLayoutKit.sanitizedOrder("settings,chat,life,workspace,dashboard")
        == ["settings", "chat", "life", "workspace", "dashboard"])
check("任意排列都放行（倒序）",
      DockLayoutKit.sanitizedOrder("settings,dashboard,workspace,life,chat")
        == ["settings", "dashboard", "workspace", "life", "chat"])
check("缺项按出厂序补到末尾",
      DockLayoutKit.sanitizedOrder("life,chat") == ["life", "chat", "workspace", "dashboard", "settings"])
check("★ 老用户已存的 4 档串（无 workspace）→ 工作区补到末尾，不写迁移代码",
      DockLayoutKit.sanitizedOrder(D_ORDER_LEGACY)
        == ["chat", "life", "dashboard", "settings", "workspace"])
check("未知项剔除",
      DockLayoutKit.sanitizedOrder("chat,zzz,life,workspace,dashboard,settings") == A)
check("重复项去重",
      DockLayoutKit.sanitizedOrder("chat,chat,life,workspace,dashboard,settings") == A)
check("全坏值 → 出厂序", DockLayoutKit.sanitizedOrder("zzz,qqq") == A)
check("空白容错（trim）",
      DockLayoutKit.sanitizedOrder(" chat , life , workspace , dashboard , settings ") == A)
check("结果恒为 5 档",
      ["", "zzz", D_ORDER, "settings,chat", D_ORDER_LEGACY].allSatisfy {
          DockLayoutKit.sanitizedOrder($0).count == 5
      })

print("== ② sanitizedHidden：隐藏净化（★设置页永不可隐藏 = 唯一闸门）")
check("空串 → 空集合", DockLayoutKit.sanitizedHidden("").isEmpty)
check("隐藏生活页", DockLayoutKit.sanitizedHidden("life") == ["life"])
check("★ 隐藏串里塞了设置页 → 被剔除（用户口径「唯独设置页不能隐藏」）",
      DockLayoutKit.sanitizedHidden("life,settings") == ["life"])
check("★ 只塞设置页 → 空集合（等于没隐藏任何页）",
      DockLayoutKit.sanitizedHidden("settings").isEmpty)
check("未知项剔除", DockLayoutKit.sanitizedHidden("zzz,life") == ["life"])
check("重复去重", DockLayoutKit.sanitizedHidden("life,life") == ["life"])
check("回显按出厂序（sanitizedHidden ≠ 写入序，便于相等判断）",
      DockLayoutKit.sanitizedHidden("dashboard,life") == ["life", "dashboard"])
check("canHide：只有设置页是 false（其余四档都可隐藏，含新增的工作区）",
      !DockLayoutKit.canHide(raw: "settings")
      && ["chat", "life", "workspace", "dashboard"].allSatisfy { DockLayoutKit.canHide(raw: $0) })

print("== ③ visible：渲染裁剪（顺序 − 隐藏；设置页兜底必须在列）")
check("默认 = 5 档出厂序",
      DockLayoutKit.visible(order: A, hidden: []) == A)
check("隐藏生活页 → 4 档（槽位自动收窄）",
      DockLayoutKit.visible(order: A, hidden: ["life"]) == ["chat", "workspace", "dashboard", "settings"])
check("隐藏生活 + 看板 → 3 档",
      DockLayoutKit.visible(order: A, hidden: ["life", "dashboard"]) == ["chat", "workspace", "settings"])
check("★ 极限：隐藏聊天 + 生活 + 看板 + 工作区 → 只剩设置页（渲染列表永不为空）",
      DockLayoutKit.visible(order: A, hidden: ["chat", "life", "workspace", "dashboard"]) == ["settings"])
check("★ 坏数据（隐藏串含设置页）→ 设置页仍在列且位置不乱",
      DockLayoutKit.visible(order: A, hidden: ["settings", "life"]) == ["chat", "workspace", "dashboard", "settings"])
check("换序 + 隐藏组合：order=settings,dashboard,life,chat,workspace 隐藏 life → 保序裁剪",
      DockLayoutKit.visible(order: ["settings", "dashboard", "life", "chat", "workspace"], hidden: ["life"])
        == ["settings", "dashboard", "chat", "workspace"])
check("forcing：临时插回被隐藏的档 → 回到它**原本的**位置（不是追加到末尾）",
      DockLayoutKit.visible(order: A, hidden: ["life"], forcing: ["life"]) == A)
check("forcing 只影响被强制的那档，其余隐藏照旧",
      DockLayoutKit.visible(order: A, hidden: ["life", "dashboard"], forcing: ["life"])
        == ["chat", "life", "workspace", "settings"])
check("order 与 hidden 全空 → 仍给设置页（兜底不空屏）",
      DockLayoutKit.visible(order: [], hidden: []) == ["settings"])

print("== ④ slotIndex：槽位序号（微滑方向 / 浮层锚点几何，禁止再写死）")
check("默认序：chat=0 / life=1 / workspace=2 / dashboard=3 / settings=4",
      ["chat", "life", "workspace", "dashboard", "settings"].enumerated().allSatisfy {
          DockLayoutKit.slotIndex(of: $0.element, in: A) == $0.offset
      })
check("换序后序号跟着走（settings 前移 → settings=0 / chat=1）",
      DockLayoutKit.slotIndex(of: "settings", in: ["settings", "chat", "life", "dashboard", "workspace"]) == 0
      && DockLayoutKit.slotIndex(of: "chat", in: ["settings", "chat", "life", "dashboard", "workspace"]) == 1)
check("★ 隐藏后自动收窄：隐藏 life → dashboard 由 3 变 2",
      DockLayoutKit.slotIndex(of: "dashboard", in: DockLayoutKit.visible(order: A, hidden: ["life"])) == 2)
check("不在列表 → 0（退第一格，不崩、不锚到屏外）",
      DockLayoutKit.slotIndex(of: "life", in: ["chat", "settings"]) == 0)

print("== ⑤ encodeHidden：写回形态（按出厂序的规范串）")
check("按出厂序规范", DockLayoutKit.encodeHidden(["dashboard", "life"]) == "life,dashboard")
check("空集合 → 空串", DockLayoutKit.encodeHidden([]) == "")
check("workspace 的规范串形态（排 life 之后、dashboard 之前）",
      DockLayoutKit.encodeHidden(["dashboard", "workspace"]) == "workspace,dashboard")
check("与 sanitizedHidden 往返一致",
      DockLayoutKit.sanitizedHidden(DockLayoutKit.encodeHidden(["dashboard", "life"])) == ["life", "dashboard"])
check("visibleRaw 摘要路径与 visible 一致",
      DockLayoutKit.visibleRaw(orderRaw: D_ORDER, hiddenRaw: "life")
        == DockLayoutKit.visible(order: A, hidden: ["life"]))

print("== ⑥ 源护栏：真挂载（逻辑对但没接上 = 用户看到的还是老 dock）")
let dockView = readSource("Features/DockTabView.swift")
let sheet = readSource("Features/Settings/DockLayoutSheet.swift")
let core = readSource("Features/Settings/SettingsCore.swift")
let models = readSource("Core/Models.swift")

check("DockTab 的 rawValue 五档与 allRaw 一致（映射靠 rawValue，错一个字符就整串失效）",
      dockView.contains("case sessions, life, chat, workspace, dashboard, settings"))
check("工作台档的 title / icon 真存在（公文包 briefcase —— 用户 2026-10-14 拍定；v4.0.x 文案工作区→工作台）",
      dockView.contains("case .workspace: \"工作台\"") && dockView.contains("case .workspace: \"briefcase\""))
check("★ workspace 的页面真挂上了（dockPage 有分支 + 套 tabTransition，漏挂则该档没图标）",
      dockView.contains("case .workspace:")
      && dockView.contains("WorkspaceView(isActive: selected == .workspace,")
      && dockView.contains(".tabTransition(for: .workspace, selected: $selected, revealCenter: revealCenter)"))
// v4.0.109：「待你处理」点进会话的回调必须在宿主真接上 —— 漏了的话会话装进了 ChatStore
// 但用户停在原地（页不切、也不退出会话首页），症状 =「点了没反应」。
check("★ 工作区「待你处理」跳转回调真接上（切聊天 tab + 落到对话页）",
      dockView.contains("onOpenSession: {")
      && dockView.contains("showSessionHome = false")
      && dockView.contains("selected = .chat"))
check("TabView 按配置渲染（ForEach(dockRenderTabs)），不是写死的静态四块",
      dockView.contains("ForEach(dockRenderTabs, id: \\.self) { tab in")
      && dockView.contains("private func dockPage(_ tab: DockTab) -> some View"))
check("🚫 不许再写死档数（`dockSlotCount: Int { 4 }` 已删）",
      !dockView.contains("private var dockSlotCount: Int { 4 }"))
check("🚫 不许再有写死的槽位序号表（slotIndex 的 switch 0..3 已删）",
      !dockView.contains("case .life: return 1"))
check("槽位数 / 聊天槽位走 DockLayoutKit（浮层锚点与烟花原点按动态槽位算）",
      dockView.contains("DockLayoutKit.slotIndex(of: DockTab.chat.rawValue")
      && dockView.contains("private var dockSlotCount: Int { dockRenderTabs.count }"))
check("TabView 挂 .id(dockRenderKey)：顺序/显隐变更后 tab bar 才会重排",
      dockView.contains(".id(dockRenderKey)"))
check("配置读取走 UserDefaultsKey 两键（AppStorage 同键跨视图同步）",
      dockView.contains("@AppStorage(UserDefaultsKey.dockOrder)") 
      && dockView.contains("@AppStorage(UserDefaultsKey.dockHidden)")
      && models.contains("static let dockOrder  = \"qingliao_dock_order\"")
      && models.contains("static let dockHidden = \"qingliao_dock_hidden\""))
// v4.0.97：切页入场改**圆形扩散**，横向微滑（dx / myIdx 方向判）连同 `order` 形参一并撤掉 ——
// 扩散圆心由宿主 `dockRevealCenter` 按**当前渲染档序**定位被点的槽位（dockRenderTabs.firstIndex），
// 仍然不碰写死的 slotIndex（下一条断言继续钉这点）。
check("扩散圆心按当前渲染档序定位槽位，不读写死的 slotIndex",
      dockView.contains("private func dockRevealCenter(_ tab: DockTab) -> CGPoint")
      && dockView.contains("dockRenderTabs.firstIndex(of: tab) ?? 0"))
check("深链/卡片点到被隐藏的页 → 临时插回（forcedTabs.insert）",
      dockView.contains("if !dockRenderTabs.contains(tab) { forcedTabs.insert(tab) }"))
check("切到常驻档即清空 forcedTabs（隐藏恢复，配置不被动过）",
      dockView.contains("if !forcedTabs.contains(newVal) { forcedTabs.removeAll() }"))
check("隐藏了当前所在页 → 兜底切到第一个可见档（不允许停在已摘除的档上）",
      dockView.contains(".onChange(of: dockRenderKey) { _, _ in")
      && dockView.contains("selected = dockRenderTabs.first ?? .settings"))

check("设置页入口真存在（title: \"Dock 栏\" + 打开 DockLayoutSheet）",
      core.contains("title: \"Dock 栏\"") && core.contains("DockLayoutSheet()")
      && core.contains("showDockLayout = true"))
check("DockLayoutSheet：设置页那行不给开关、标「必显示」（闸门走 canHide）",
      sheet.contains("if DockLayoutKit.canHide(raw: tab.rawValue)") && sheet.contains("必显示"))
check("DockLayoutSheet：升降序写回整串（move 里 swapAt + join）",
      sheet.contains("now.swapAt(i, i + delta)") && sheet.contains("orderRaw = now.joined(separator: \",\")"))
check("DockLayoutSheet：隐藏写回走 encodeHidden（规范形态，别自己拼串）",
      sheet.contains("hiddenRaw = DockLayoutKit.encodeHidden(now)"))
check("DockLayoutSheet：新增的 workspace 档有行首色块配色（rowTint 穷尽，漏一个色 CI 编译不过）",
      sheet.contains("case .workspace: return .indigo"))

print("== Ⓝ 会话首页 ↔ 对话页：过渡必须是「看得见的横移」（v4.0.114 用户「聊天详情手势滑动返回过渡太生硬」）==")
// 事故形态：整页切换套 Motion.tap（.snappy 0.12 —— 那枚令牌自称「按压/开关/小状态：几乎瞬时」），
// 拿小控件曲线驱动整页位移 → 读作「啪一下闪过去」；且 if/else 默认交叉淡化、没有方向感。
// 老毛病容易复发（下一个改聊天页的人顺手写回 tap），故正反两面都钉。
let motionSrc = readSource("Theme/Motion.swift")
check("用页面级令牌 Motion.page 驱动两态切换（进入 + 返回两处都要）",
      dockView.contains("withAnimation(Motion.page) { showSessionHome = false }")
        && dockView.contains("withAnimation(Motion.page) { showSessionHome = true }"))
// v4.0.115：工作台「待你处理」卡片进对话页走的是同一个跳转 —— 原先用 Motion.tap（控件曲线）驱动整页位移。
let wsCallWindow = String((dockView.components(separatedBy: "WorkspaceView(isActive: selected == .workspace,").last ?? "").prefix(900))
check("工作台进会话同用页面级令牌（原先 Motion.tap 整页位移 = 读作「啪一下」）",
      wsCallWindow.contains("withAnimation(Motion.page)")
        && !wsCallWindow.contains("withAnimation(Motion.tap)"))
check("两分支各有方向感转场（列表 .leading / 聊天 .trailing）—— 少了就退回交叉淡化",
      dockView.contains(".transition(.move(edge: .leading))")
        && dockView.contains(".transition(.move(edge: .trailing))"))
// v4.0.115（用户「**还是**动效生硬」）：v4.0.114 的 `.combined(with: .opacity)` 是错的 ——
// 横移叠淡入淡出，两页各淡各的，位移被稀释成「叠着闪一下」，方向感白给。必须是**纯位移**。
check("🚫 两分支不许再叠 .opacity（交叉淡化会吃掉横移，v4.0.115 已摘）",
      !dockView.contains(".transition(.move(edge: .leading).combined(with: .opacity))")
        && !dockView.contains(".transition(.move(edge: .trailing).combined(with: .opacity))"))
check("🚫 两态切换不许复活 Motion.tap（0.12 = 闪一下，本次修复的病根）",
      !dockView.contains("withAnimation(Motion.tap) { showSessionHome"))
check("Motion.page 存在且是页面级时长（退回 0.12 级就是老毛病）",
      motionSrc.contains("static var page: Animation { .smooth(duration: 0.34) }"))
// v4.0.115：整屏位移不许用带回弹的弹簧（.snappy 收尾那点回弹读作到位时「顿一下」）。
check("🚫 Motion.page 不许退回 .snappy（整页位移要无回弹的 .smooth）",
      !motionSrc.contains("static var page: Animation { .snappy("))

print("\n== Ⓞ 返回会话首页：滑进来那一帧必须**已经有内容**（v4.0.115 用户「还是动效生硬」）==")
// 事故形态：SessionsView 是 if/else 的一支，进聊天时整只销毁、@State 数组归零；
// 返回时头几帧列表为空 → 滑进来的是一张「还没有会话」空态插画页，内容再在动画途中长出来。
// 用户读到的「生硬」大半在这儿（v4.0.114 只调了曲线与方向，所以他回「还是」）。
// 判据 = 初值必须取自本地缓存快照（纯函数，不是空数组）。
let sessionsSrc = readSource("Features/Sessions/SessionsView.swift")
check("sessions 初值取自缓存快照 SessionsView.cacheSnapshot()（否则返回时那一帧是空态）",
      sessionsSrc.contains("@State private var sessions: [ChatSession] = SessionsView.cacheSnapshot()"))
check("cacheSnapshot() 真存在且从同一份缓存 key 解析",
      sessionsSrc.contains("static func cacheSnapshot() -> [ChatSession]")
        && sessionsSrc.contains("forKey: sessionCacheKey"))
check("🚫 不许把初值改回空数组（病根原样复发）",
      !sessionsSrc.contains("@State private var sessions: [ChatSession] = []"))
// 默认值表达式每次建帧都求值 → 解析必须命中进程内快照（本机实测最坏量级 ~39ms/次，不能摊在建帧路径上）
check("cacheSnapshot() 命中进程内快照 snapshotMemo（不是每次现解 JSON）",
      sessionsSrc.contains("private static nonisolated(unsafe) var snapshotMemo: [ChatSession] = []")
        && sessionsSrc.contains("private static nonisolated(unsafe) var snapshotLoaded = false")
        && sessionsSrc.contains("if loaded { return memo }"))
// v4.0.115（审查②）：命中判据曾是「数组非空」—— 无缓存/顶层不是数组/schema 漂移时 memo 写空数组，
// 空数组永远不命中 → 每次建帧重解 1.6MB JSON（本机最坏 ~39ms），正好是这个护栏要防的事。
check("🚫 不许拿「数组非空」当命中判据（空快照也要标记已解析）",
      !sessionsSrc.contains("if !memo.isEmpty { return memo }"))

print("\n== Ⓝ′ 纪要页入口：必须先把聊天页拉进视图树（两个入口共用一份实现）==")
// v4.0.115 审查抓到的事故形态：工作台工具格自己 present 纪要页 → 那条路上 ChatView 不在视图树，
// 整理完那张卡由 MeetingMinutesView post、唯一接收方 ChatView 的 onReceive 收不到 → 卡静默丢失，
// 页内照旧显示「已放进会话」。修法 = 两个入口都走 openMinutesPage（先切聊天页再弹全屏页）。
let wsSrc2 = readSource("Features/Workspace/WorkspaceView.swift")
check("工作台「会议纪要」格走宿主回调 onOpenMinutes（不自己挂全屏页）",
      wsSrc2.contains("var onOpenMinutes: (() -> Void)? = nil")
        && wsSrc2.contains("{ onOpenMinutes?() }"))
check("🚫 工作台不许自己挂纪要全屏页（ChatView 不在树 = 卡静默丢失 + 假「已放进会话」）",
      !wsSrc2.contains(".fullScreenCover(isPresented: $showMinutes)"))
check("两个入口共用一份实现：openMinutesPage 声明 1 次、被调 2 次（长按球 case 6 + 工作台回调）",
      dockView.components(separatedBy: "private func openMinutesPage()").count - 1 == 1
        && dockView.components(separatedBy: "openMinutesPage()").count - 1 == 3)
let minsBody = String((dockView.components(separatedBy: "private func openMinutesPage()").last ?? "").prefix(700))
if let a = minsBody.range(of: "selected = .chat"),
   let b = minsBody.range(of: "showSessionHome = false"),
   let c = minsBody.range(of: "showMinutes = true") {
    check("openMinutesPage：先切聊天页（selected = .chat + showSessionHome = false）再弹纪要页",
          a.lowerBound < c.lowerBound && b.lowerBound < c.lowerBound)
} else {
    check("openMinutesPage：三要素都在（缺 = 卡静默丢失的病根复发）", false)
}

print("\n通过 \(ok) 项，失败 \(fail) 项")
if fail > 0 { exit(1) }
