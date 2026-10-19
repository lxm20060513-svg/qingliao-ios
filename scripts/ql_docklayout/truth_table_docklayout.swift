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
let sessionsView = readSource("Features/Sessions/SessionsView.swift")
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
      && dockView.contains(".tabTransition(for: .workspace, selected: $selected, order: dockRenderTabs)"))
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
// v4.0.120：切页入场改**内容层定向滑入**（用户 2026-10-17「圆扩散只留启动页」）—— 圆心 / `dockRevealCenter`
// 整套退役；方向改按**渲染档序**判（`order` 形参 + firstIndex），仍然不碰写死的 slotIndex。
check("定向滑入的方向按**渲染档序**判（order 形参 + firstIndex），不读写死的 slotIndex，且圆心那套已退役",
      dockView.contains("let order: [DockTab]")
      && dockView.contains("order.firstIndex(of: tab)")
      && !dockView.contains("dockRevealCenter"))
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
check("用页面级令牌 Motion.page 驱动两态切换（进入 + 返回按钮两处都要）",
      // v4.0.122：进对话页那条收口里多了 resetBackFollow()（跟手窗口里的点击必须清跟手状态），
      // 所以这里钉「同一条语句的两种写法」都能被认出，别把 reset 当成引进了第二套令牌。
      (dockView.contains("withAnimation(Motion.page) { showSessionHome = false }")
        || dockView.contains("withAnimation(Motion.page) { resetBackFollow(); showSessionHome = false }"))
        && dockView.contains("withAnimation(Motion.page) { showSessionHome = true }"))
// v4.0.115：工作台「待你处理」卡片进对话页走的是同一个跳转 —— 原先用 Motion.tap（控件曲线）驱动整页位移。
let wsCallWindow = String((dockView.components(separatedBy: "WorkspaceView(isActive: selected == .workspace,").last ?? "").prefix(900))
check("工作台进会话同用页面级令牌（原先 Motion.tap 整页位移 = 读作「啪一下」）",
      wsCallWindow.contains("withAnimation(Motion.page)")
        && !wsCallWindow.contains("withAnimation(Motion.tap)"))
// v4.0.116（用户 2026-10-13「聊天页滑动返回聊天主页采用圆形扩散转场特效：新页面就从手指滑动位置向外
// 扩散直到铺满整个屏幕」）：**返回方向**（对话页 → 会话首页）从「列表左滑进来」整条换成**圆形扩散** ——
// 形状 / 最大半径与 dock 切页同一套（RevealCircleShape + pageRevealMaxRadius）；
// **曲线 v4.0.117 起分家**（切页 = pageReveal，返回 = sessionBackReveal，见下面那条），
// 圆心也不同：切页取被点槽位中心；返回这一侧 v4.0.122 起只剩**页头返回按钮**（兜底屏幕中心），
// 左缘手势那条已换成跟手位移（不播扩散，见下面 Ⓟ 段与本节负断言）。
// ⚠️ 旧口径（返回也是纯 move 的 push/pop）在返回这一侧**已作废**：整页横移与扩散同时演 = 位移把圆切碎，
//    正是 v4.0.115 治过的病。离场侧（进对话页 = 列表左滑出 + 聊天右滑入）**一字未改**，下面钉住。
check("返回方向 = 首页挂 sessionHomeReveal(center:)（页头返回按钮那条的圆形扩散，仍在这一支）",
      dockView.contains(".sessionHomeReveal(center: $homeRevealCenter)"))
// 🚨 v4.0.122（用户 2026-10-18 对着参考截图拍板「要这种跟手滑动返回」）：**左缘手势这条换成跟手位移** ——
//   拖动时对话页贴着手指右移、会话首页从左侧同步露出来；松手按位移/甩动预测判完成或回弹。
//   于是两条老口径当场作废（下面钉死，别让它们复活）：
//     ① 圆心 = 手势**抬手**位置（`onBack(value.location)`）—— 跟手压根不等抬手；圆心只剩页头返回按钮那条
//        （无手指可依 → 宿主兜底屏幕中心，扩散照旧演）；
//     ② 判定 = 「抬手位移 ≥ 70pt 就跳转」（Kit 里的 shouldGoBack / minTranslation）—— 抬手才认 = 不跟手。
//   纯逻辑那半在本表末尾「Ⓟ 跟手判定」段用**编译真值**钉（ChatEdgeBackKit.swift 已加进本表编译行）。
check("🚫 手势那条不许再拿抬手位置当扩散圆心（跟手口径已作废 onBack(value.location)）",
      !readSource("Features/Chat/ChatView.swift").contains("onBack(value.location)"))
check("🚫 老口径 shouldGoBack / minTranslation 不许复活（抬手才认 = 不跟手，用户 2026-10-18 拍的板）",
      !readSource("Core/ChatEdgeBackKit.swift").contains("func shouldGoBack")
        && !readSource("Core/ChatEdgeBackKit.swift").contains("static let minTranslation")
        && !readSource("Features/Chat/ChatView.swift").contains("ChatEdgeBackKit.shouldGoBack"))
check("跟手位移挂载点 = 对话页整页 offset（恰好一处；且只在 backFollowLive 时生效 —— 不跟手恒 0）",
      dockView.components(separatedBy: ".offset(x: backFollowLive ? backFollowOffset : 0)").count - 1 == 1
        && readSource("Features/Chat/ChatView.swift").contains("ChatEdgeBackKit.followOffset(dx: dx,"))
check("跟手收敛 / 回弹各一处、都走页面级令牌 Motion.page（不许引第二套时长）",
      dockView.contains("withAnimation(Motion.page) { backFollowOffset = width }")
        && dockView.contains("withAnimation(Motion.page) { backFollowOffset = 0 }"))
check("🚫 跟手帧必须是裸赋值（过动画事务 = 页面落在手指后面）",
      dockView.contains("backFollowOffset = dx")
        && !dockView.contains("withAnimation(Motion.page) { backFollowOffset = dx }")
        && !dockView.contains("withAnimation(Motion.tap) { backFollowOffset"))
check("🚫 两态不许退回 if/else 单页结构（跟手要的就是「两页同框」那一帧）",
      dockView.contains("if showSessionHome || backFollowLive {"))
check("跟手有记忆性：认领后本轮不再逐帧过门（否则手指一偏 |dy| 变大 → 位移归 0 = 手底下抖回去）",
      readSource("Features/Chat/ChatView.swift").contains("@State private var claimedStart: CGPoint? = nil")
        && readSource("Features/Chat/ChatView.swift").contains("if claimedStart == nil {"))
// 🚨 v4.0.122 审查补（2026-10-18 夜，独立评审抓的两个必修）：跟手状态多了两个**兜底出口** ——
// 原来只有「正常抬手」一条路，手势被打断（`onEnded` 压根不来：来电/通知/进后台/视图被摘下）就会残留。
// ① 手势侧：锁存改判**起手点**（一次 DragGesture 内恒定、跨手势必不同）→ 换手势就把上一轮收干净，
//    不用依赖 onEnded；残留的老 Bool 锁存会让下一轮**任意**拖动都跳过起手门与方向门。
// ② 宿主侧：进对话页必须先 `resetBackFollow()` —— 跟手/回弹窗口里首页是垫底页、完全可点，
//    不清状态的话 0.4s 收尾任务会用 `showSessionHome = true` 把这次点击覆盖回去（点了没反应，会话还已被 load + 标已读）。
check("🚫 老 Bool 锁存不许复活（打断后残留 = 下一轮任意拖动跳过起手门与方向门，把整页推走）",
      !readSource("Features/Chat/ChatView.swift").contains("private var following = false"))
check("跟手兜底①：换手势就收回上一轮（不依赖 onEnded）+ 跟手期间禁掉页内滚动",
      readSource("Features/Chat/ChatView.swift").contains("claimed != value.startLocation")
        && readSource("Features/Chat/ChatView.swift").contains("onFollowEnd?(false)")
        && readSource("Features/Chat/ChatView.swift").contains(".scrollDisabled(claimedStart != nil)"))
check("跟手兜底②：进对话页收口必须先 resetBackFollow()（宿主有这条函数：位移归 0 + 卸垫底页 + 作废待办）",
      dockView.contains("withAnimation(Motion.page) { resetBackFollow(); showSessionHome = false }")
        && dockView.contains("private func resetBackFollow()")
        && dockView.contains("backFollowOffset = 0\n        backFollowLive = false"))
check("🚫 手势壳不许再接 onBack（页头返回按钮那条直连 onBackToHome，不走手势壳，别让人改错一侧）",
      !readSource("Features/Chat/ChatView.swift").contains("ChatEdgeBackModifier(onBack:"))
// 🚨 v4.0.117（用户 2026-10-15 真机拍板「滑动返回聊天主页的扩散就是太快，再慢一点」）：**曲线分家**。
// 🚨 v4.0.120（用户 2026-10-17「圆扩散只留启动页」）：**切页那一侧整条换掉** → 定向滑入。于是本段口径变成：
// ① 返回那份恰好一处 ② **切页两处不许**再出现 pageReveal 圆扩散 ③ 返回那支 modifier 自己不许再出现 pageReveal。
// 返回曲线仍是 sessionBackReveal（.smooth 1.10），一字未动。
let sessionBackCall = "withAnimation(Motion.sessionBackReveal) { revealRadius = Motion.pageRevealMaxRadius }"
let pageRevealCall = "withAnimation(Motion.pageReveal) { revealRadius = Motion.pageRevealMaxRadius }"
let pageEnterCall = "withAnimation(Motion.pageEnterSlide) { slideOffset = 0 }"
check("返回的圆形扩散走**返回专用**曲线 sessionBackReveal（恰好一处）+ 起点仍是半径归 0",
      dockView.components(separatedBy: sessionBackCall).count - 1 == 1
        && dockView.contains("revealRadius = 0"))
check("🚫 切页两处**不许**再走 pageReveal 圆扩散（v4.0.120 已整条换掉；扩散只留返回 + 启动页）",
      dockView.components(separatedBy: pageRevealCall).count - 1 == 0)
check("切页两处入场 = 同一个 pageEnterSlide 事务 + 起点 pageEnterShift（两处 modifier 各一份）",
      dockView.components(separatedBy: pageEnterCall).count - 1 == 2
        && dockView.components(separatedBy: "direction(from: oldVal) * Motion.pageEnterShift").count - 1 == 2)
// 第 12 项（2026-10-18 特效总档）：令牌形态 = tuned(.smooth(...)) ⇒ 只钉**曲线 + 时长字面**，
// 不钉整行（改时长 / 换曲线仍报红）。
check("sessionBackReveal 令牌存在、且比切页的 0.75 慢（.smooth 1.10）",
      motionSrc.contains(".smooth(duration: 1.10)"))
// 切片自证：锚点取真代码行（注释行会被 strip 掉的写法在别处踩过），且先断言切片非空（否则下面那条是空真）
let backSlice = String((dockView.components(separatedBy: "private struct SessionHomeRevealModifier").last ?? "")
    .components(separatedBy: "MARK: - v3.9.78").first ?? "")
check("切片取到（切片空了下面那条就是空真）", !backSlice.isEmpty)
check("🚫 返回那支 modifier 里不许再出现 Motion.pageReveal（改回共用 = 「太快」复发）",
      backSlice.contains("Motion.sessionBackReveal") && !backSlice.contains("Motion.pageReveal)"))
check("🚫 首页入场不许再挂整页横移（须为 .identity：移了就是位移把扩散切碎）",
      dockView.contains(".transition(.asymmetric(insertion: .identity, removal: .move(edge: .leading)))"))
check("🚫 返回时对话页不许再右滑（removal 已改 .identity；右滑 + 扩散会各演各的）",
      dockView.contains(".transition(.asymmetric(insertion: .move(edge: .trailing), removal: .identity))"))
check("离场侧保留方向感（进对话页 = 列表左滑出 + 聊天右滑入）",
      dockView.contains("removal: .move(edge: .leading)")
        && dockView.contains("insertion: .move(edge: .trailing)"))
check("圆心「取走即清空」：只有**页头返回按钮**那条播扩散（跟手不写圆心 = 不播；切 tab / 冷启动 / 深链落首页也不播 —— 那些路外层 chatZoomEntry 有自己的整页入场）",
      dockView.contains("private func backToSessionHome()")
        && dockView.contains("guard let c = pendingCenter else { return }")
        && dockView.contains("pendingCenter = nil"))
// v4.0.115（用户「**还是**动效生硬」）：v4.0.114 的 `.combined(with: .opacity)` 是错的 ——
// 横移叠淡入淡出，两页各淡各的，位移被稀释成「叠着闪一下」，方向感白给。必须是**纯位移**。
check("🚫 两分支不许再叠 .opacity（交叉淡化会吃掉横移，v4.0.115 已摘）",
      !dockView.contains(".transition(.move(edge: .leading).combined(with: .opacity))")
        && !dockView.contains(".transition(.move(edge: .trailing).combined(with: .opacity))"))
check("🚫 两态切换不许复活 Motion.tap（0.12 = 闪一下，本次修复的病根）",
      !dockView.contains("withAnimation(Motion.tap) { showSessionHome"))
check("Motion.page 存在且是页面级时长（退回 0.12 级就是老毛病）",
      motionSrc.contains(".smooth(duration: 0.34)"))
// v4.0.115：整屏位移不许用带回弹的弹簧（.snappy 收尾那点回弹读作到位时「顿一下」）。
check("🚫 Motion.page 不许退回 .snappy（整页位移要无回弹的 .smooth）",
      !motionSrc.contains(".snappy(duration: 0.34)"))

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

print("\n== Ⓟ 左缘右滑**跟手**返回的判定真值（v4.0.122；Kit 纯逻辑，本表编译跑真值）==")
// 用户口径（2026-10-18，对着参考截图「拖到中途两页同框」那一帧拍板）：「要这种跟手滑动返回」。
// 判定分三段：起手门（左缘）→ 认领门（够横，只过一次）→ 松手门（过半或甩过半）。
// 阈值真源 = Core/ChatEdgeBackKit.swift（本表编译行已带上它，下面的数是**跑出来的**不是抄的）。
check("起手门：左缘 24pt 内才算（24 在内、24.5 在外）",
      ChatEdgeBackKit.isEdgeStart(x: 0) && ChatEdgeBackKit.isEdgeStart(x: 24)
        && !ChatEdgeBackKit.isEdgeStart(x: 24.5))
check("认领门够横：dx ≥ 8 且 dx ≥ |dy| × 1.8（纵向滚动 / 往上往下斜划都要被挡）",
      ChatEdgeBackKit.isHorizontal(dx: 8, dy: 0)
        && !ChatEdgeBackKit.isHorizontal(dx: 7.9, dy: 0)
        && ChatEdgeBackKit.isHorizontal(dx: 36, dy: 20)
        && !ChatEdgeBackKit.isHorizontal(dx: 36, dy: 21)
        && !ChatEdgeBackKit.isHorizontal(dx: 36, dy: -21)
        && !ChatEdgeBackKit.isHorizontal(dx: -40, dy: 0))
check("跟手位移 clamp：回拉归 0、超屏宽归屏宽、宽度非法归 0（拖不出屏外 / 不出现负位移）",
      ChatEdgeBackKit.followOffset(dx: -12, width: 390) == 0
        && ChatEdgeBackKit.followOffset(dx: 100, width: 390) == 100
        && ChatEdgeBackKit.followOffset(dx: 999, width: 390) == 390
        && ChatEdgeBackKit.followOffset(dx: 50, width: 0) == 0)
check("松手门（慢放）：位移过半即完成（195/390 边界含）、差 5pt 就回弹",
      ChatEdgeBackKit.shouldComplete(dx: 195, projectedEnd: 195, width: 390)
        && !ChatEdgeBackKit.shouldComplete(dx: 190, projectedEnd: 190, width: 390))
check("松手门（轻甩）：位移没过半但甩动预测终点过半也算（微信同款：甩一把就翻页）",
      ChatEdgeBackKit.shouldComplete(dx: 80, projectedEnd: 260, width: 390)
        && !ChatEdgeBackKit.shouldComplete(dx: 80, projectedEnd: 190, width: 390))
check("松手门兜底：dx ≤ 0 / 宽度非法一律不算完成（往回甩不许触发返回）",
      !ChatEdgeBackKit.shouldComplete(dx: 0, projectedEnd: 999, width: 390)
        && !ChatEdgeBackKit.shouldComplete(dx: -30, projectedEnd: 999, width: 390)
        && !ChatEdgeBackKit.shouldComplete(dx: 200, projectedEnd: 999, width: 0))
check("松手门取「同一枚阈值」= 屏宽 × completeRatio（0.5）；不许在这条链上再写死 70 之类的绝对值",
      ChatEdgeBackKit.completeRatio == 0.5
        && ChatEdgeBackKit.shouldComplete(dx: 390 * 0.5, projectedEnd: 0, width: 390))

// ── ⑦ v4.0.124：对话页隐藏 dock（用户 2026-10-19）+ 垫底页不拉数据（滑动返回流畅性）──
check("对话页隐藏 tab bar；跟手一开始就恢复（首页正露出，底栏跟着出现才是微信观感）",
      dockView.contains(".toolbar(showSessionHome || backFollowLive ? .visible : .hidden, for: .tabBar)"))
check("垫底页不触发 load（.task / .onAppear 双闸），收敛回首页后补刷一次",
      sessionsView.contains("var isBackdrop: Bool = false")
      && sessionsView.contains(".task { if !isBackdrop { await load() } }")
      && sessionsView.contains("if !isBackdrop { Task { await load() } }")
      && sessionsView.contains(".onChange(of: isBackdrop)"))
check("isBackdrop 只在「跟手垫底」时为真（正式首页恒 false —— 否则首页会永不刷新）",
      dockView.contains("isBackdrop: backFollowLive && !showSessionHome)"))

print("\n通过 \(ok) 项，失败 \(fail) 项")
if fail > 0 { exit(1) }
