// MARK: - v4.0.x「快捷指令 / Siri 打开某页」真值表（纯逻辑 + 源护栏）
//
// 口径来源（用户 2026-09-27 真机实测报错截图）：
//   快捷指令自动化「打开轻聊看板」跑起来当场失败 ——
//   `The provided URL scheme `qingliao` is unsupported; launch is prohibited`。
//   旧写法：intent `perform()` 返回 `.result(opensIntent: OpenURLIntent(qingliao://dashboard))`，
//   即请**系统**去 launch 本 App 的自定义 scheme；iOS 26 把这条拒了（launch is prohibited）。
//
// 新口径（本表钉的这条链）：
//   ① intent 声明 `supportedModes = .foreground(.immediate)` —— 系统先把 App 带到前台，
//      intent 代码在 **App 进程**里跑（替代已废弃的 `openAppWhenRun`）
//   ② 目标页不再过系统 launch：`QingliaoRouteHandoff.request(route)` 进程内投递
//      （通知广播 + 带时间戳的兜底值），`DockTabView` 侧「广播 + 冷启动补读」两条腿都在
//   ③ 「深链 / intent → 切哪一页」全 App **只有一个落地点** `applyRoute(_:)`
//      （`onOpenURL` 的 `qingliao://<tab>`、intent 广播、兜底补读共用它）
//      v4.0.x：**非 tab 路由**（`quickActions` 快捷动作菜单）也落在这里 —— 开覆盖层、不切页；
//      白名单唯一真源是 `QingliaoDeepLink.nonTabRoutes`，本表⑤段按它扣除后再比 DockTab
//   ④ `qingliao://` scheme 本身保留：灵动岛 `widgetURL` / 分享回跳 / `onOpenURL` 深链还用它
//   ⑤ `.foreground(.immediate)` 下 `perform()` 必须 `@MainActor`：它内部同步 post 通知，
//      App 侧 `.onReceive` 会直接在投递线程上改 SwiftUI 状态（切 tab / 白置烟花标志）
//
// 用法（必须在仓库根跑，表内用相对路径读源）：
//   check_swift.sh 第 35 段（**唯一跑本表的入口**）—— 复制本表成 main.swift，再带
//   `qingliao/Core/QingliaoIntentSupport.swift` 一起编（该文件纯 Foundation，无 AppIntents/SwiftUI 依赖，
//   所以本机没 iOS SDK 也能跑它的真值）。
//   `python3 /opt/data/scripts/ql.py test` 只扫 /opt/data/scripts/*/ 下的表，**不跑仓内 scripts/**。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ " + name) }
}

let root = "qingliao"
func src(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: root + "/" + path, encoding: .utf8) else { return "" }
    return s
}

/// 去掉整行注释后再做「不许出现 XX」这类否定断言 —— 注释里解释历史写法不算产物
/// （本仓口径：护栏钉真实产物；`AppIntents.swift` 的表头注释**故意**留了 `OpenURLIntent` 这个词讲为什么不用它）。
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

/// 数某个子串出现次数（源护栏用）
func count(_ hay: String, _ needle: String) -> Int {
    hay.components(separatedBy: needle).count - 1
}

// MARK: 源

let intentSrc = src("Core/AppIntents.swift")
let intentCode = stripCommentLines(intentSrc)
let supportSrc = src("Core/QingliaoIntentSupport.swift")
let supportCode = stripCommentLines(supportSrc)
let dockSrc = src("Features/DockTabView.swift")
let dockCode = stripCommentLines(dockSrc)

check("源能读到（路径对）", !intentSrc.isEmpty && !supportSrc.isEmpty && !dockSrc.isEmpty)

// MARK: ① 旧写法必须连根拔掉（这就是报错源头）

check("AppIntents 代码里不再有 OpenURLIntent", !intentCode.contains("OpenURLIntent"))
check("不再用 .result(opensIntent:)", !intentCode.contains("opensIntent"))
check("perform 不再返回 & OpensIntent（回到 some IntentResult）", !intentCode.contains("IntentResult & OpensIntent"))
check("不用已废弃的 openAppWhenRun", !intentCode.contains("openAppWhenRun"))

// MARK: ② 「打开 App 到某处」的 intent 都声明前台模式（4 个 tab 页 + 1 个快捷菜单）

check("supportedModes 出现 5 处（chat/sessions/dashboard/life + quickActions 各一）",
      count(intentCode, "static var supportedModes: IntentModes { .foreground(.immediate) }") == 5)
check("前台模式用 .foreground(.immediate)（不是 .deferred/.dynamic）",
      !intentCode.contains(".foreground(.deferred)") && !intentCode.contains(".foreground(.dynamic)"))
check("supportedModes 是计算属性而非 static let（Swift 6 并发安全）",
      !intentCode.contains("static let supportedModes"))
check("五个 perform 都标 @MainActor（同步 post 通知 → 必须主线程改 SwiftUI 状态）",
      count(intentCode, "@MainActor\n    func perform() async throws -> some IntentResult {") == 5)

// MARK: ③ 五个 intent 各自投对页（route 与 title 一一对应，不许复制粘贴串页）

let routeByIntent: [(String, String, String)] = [
    ("OpenChatIntent", "chat", "打开轻聊聊天"),
    ("OpenSessionsIntent", "sessions", "打开轻聊会话列表"),
    ("OpenDashboardIntent", "dashboard", "打开轻聊看板"),
    ("OpenLifeIntent", "life", "打开轻聊生活页"),
    ("OpenQuickActionsIntent", "quickActions", "打开轻聊快捷菜单"),
]
for (type, route, title) in routeByIntent {
    guard let start = intentSrc.range(of: "struct \(type): AppIntent"),
          let end = intentSrc.range(of: "struct ", range: start.upperBound..<intentSrc.endIndex) else {
        check("找得到 \(type) 定义", false); continue
    }
    let body = String(intentSrc[start.lowerBound..<end.lowerBound])
    check("\(type) 投递 .\(route)", body.contains("QingliaoRouteHandoff.request(.\(route))"))
    check("\(type) 标题仍是「\(title)」", body.contains(title))
    check("\(type) 走前台模式", body.contains("supportedModes"))
}

// MARK: ④ 投递件本身（纯逻辑，直接调生产代码）

check("QingliaoRouteHandoff 在 QingliaoIntentSupport.swift（纯 Foundation，可上表）",
      supportSrc.contains("enum QingliaoRouteHandoff"))
check("request 同时落盘 + 广播（缺一条就是「App 冷启动点快捷指令没反应」）",
      supportCode.contains("UserDefaults.standard.set(") && supportCode.contains("NotificationCenter.default.post("))
check("兜底值带时间戳、读取有有效期（过期即丢，免得下次冷启动莫名切页）",
      supportCode.contains("timeIntervalSince1970") && supportSrc.contains("staleAfter"))
check("consume 读到即清（幂等可重复调用）", supportCode.contains("removeObject(forKey: defaultsKey)"))

// 真值：request → consume 一次到手、第二次为 nil
let ud = UserDefaults.standard
ud.removeObject(forKey: QingliaoRouteHandoff.defaultsKey)

var broadcast: [String] = []
let token = NotificationCenter.default.addObserver(forName: QingliaoRouteHandoff.notification,
                                                  object: nil, queue: nil) { note in
    if let name = note.object as? String { broadcast.append(name) }
}
QingliaoRouteHandoff.request(.dashboard)
check("request 广播一次、载荷是 route 名", broadcast == ["dashboard"])
check("consume 取回 .dashboard", QingliaoRouteHandoff.consume() == .dashboard)
check("consume 第二次为 nil（读到即清）", QingliaoRouteHandoff.consume() == nil)

// 真值：过期的兜底值必须丢弃
ud.set("life|\(Date().timeIntervalSince1970 - 120)", forKey: QingliaoRouteHandoff.defaultsKey)
check("过期（>60s）的兜底路由被丢弃", QingliaoRouteHandoff.consume() == nil)
check("过期判定后也清掉了 key", ud.string(forKey: QingliaoRouteHandoff.defaultsKey) == nil)

// 真值：脏数据不崩、不当成有效路由
ud.set("nope|\(Date().timeIntervalSince1970)", forKey: QingliaoRouteHandoff.defaultsKey)
check("白名单外的名字返回 nil", QingliaoRouteHandoff.consume() == nil)
ud.set("dashboard", forKey: QingliaoRouteHandoff.defaultsKey)          // 老格式（无时间戳）也要能认
check("无时间戳的老格式仍可消费", QingliaoRouteHandoff.consume() == .dashboard)
check("route(named:) 白名单外为 nil", QingliaoRouteHandoff.route(named: "settings2") == nil)
check("route(named:) 认得 6 个路由（5 个 tab 页 + 快捷菜单）",
      ["chat", "sessions", "dashboard", "life", "settings", "quickActions"].allSatisfy { QingliaoRouteHandoff.route(named: $0) != nil })
NotificationCenter.default.removeObserver(token)

// MARK: ⑤ Route ↔ DockTab 一一对应（两张表漂移 = 深链静默失效）

check("Route 恰好 6 个 case（5 个 tab 页 + quickActions）", QingliaoDeepLink.Route.allCases.count == 6)
let routeNames = Set(QingliaoDeepLink.Route.allCases.map(\.rawValue))
check("Route rawValue 是 5 个 tab 页 + quickActions",
      routeNames == ["chat", "sessions", "dashboard", "life", "settings", "quickActions"])
check("非 tab 白名单里的名字都在 Route 里（白名单不许写错名）",
      Set(QingliaoDeepLink.nonTabRoutes.map(\.rawValue)).isSubset(of: routeNames))
// DockTab 的 case 列表（App 层 SwiftUI 类型，本机编不了 → 从源里取那一行）
if let line = dockSrc.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("case ") }) {
    let tabs = Set(line.replacingOccurrences(of: "case", with: "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    check("DockTab 的 case 与 Route 的 tab 路由完全一致（两张表不许漂移；非 tab 路由按白名单扣除，扣完仍须相等）",
          tabs == routeNames.subtracting(QingliaoDeepLink.nonTabRoutes.map(\.rawValue)))
} else {
    check("找得到 DockTab 的 case 列表", false)
}

// 真值：深链解析回归（这次改的是消费方式，解析口径不许被顺手改坏）
check("qingliao://dashboard → .dashboard", QingliaoDeepLink.route(for: URL(string: "qingliao://dashboard")!) == .dashboard)
check("大小写不敏感：QINGLIAO://Chat → .chat", QingliaoDeepLink.route(for: URL(string: "QINGLIAO://Chat")!) == .chat)
check("http 链接不算深链（交给分享分支）", QingliaoDeepLink.route(for: URL(string: "https://example.com/dashboard")!) == nil)
check("白名单外的 host 不算深链", QingliaoDeepLink.route(for: URL(string: "qingliao://whatever")!) == nil)

// MARK: ⑥ 宿主侧：广播 + 冷启动补读两条腿，落地点只有一处

check("DockTabView 监听 QingliaoRouteHandoff.notification", dockCode.contains("QingliaoRouteHandoff.notification"))
check("冷启动兜底补读存在（.task + consume）",
      dockCode.contains("QingliaoRouteHandoff.consume()") && dockCode.contains(".task {"))
check("intent 广播也走 applyRoute（不另写一份切页）",
      dockCode.contains("applyRoute(route)"))
check("深链 onOpenURL 同样走 applyRoute",
      dockCode.contains("if let route = QingliaoDeepLink.route(for: url)") && !dockCode.contains("skipBurstOnce()\n            selected = tab"))
check("applyRoute 用 DockTab(rawValue: route.rawValue) 映射",
      dockCode.contains("DockTab(rawValue: route.rawValue)"))

// v4.0.x：非 tab 路由（快捷动作菜单）必须**在 applyRoute 里**有分支，且排在 tab 映射之前 ——
// 只加 Route case 不加分支 = `DockTab(rawValue:)` 落空静默 return，用户侧看到的是「点了没反应」。
if let s = dockCode.range(of: "private func applyRoute("),
   let e = dockCode.range(of: "private func handleShareURL("),
   s.lowerBound < e.lowerBound {
    let applyBody = String(dockCode[s.lowerBound..<e.lowerBound])
    let nonTab = applyBody.range(of: "QingliaoDeepLink.nonTabRoutes.contains(route)")
    let tabMap = applyBody.range(of: "DockTab(rawValue:")
    // v4.0.x：弹菜单已收进具名方法（openOrbMenuAtDockSlot / requestOrbMenuAtPetAnchor），
    // 这里查的是「非 tab 分支确实开了菜单」而不是裸 showOrbMenu = true（裸赋值会绕过互斥守卫）。
    check("applyRoute 认非 tab 路由（快捷菜单走宠物锚点弹菜单）",
          nonTab != nil && applyBody.contains("requestOrbMenuAtPetAnchor()"))
    check("非 tab 分支排在 tab 映射之前（顺序反了 = 静默落空）",
          nonTab != nil && tabMap != nil && nonTab!.lowerBound < tabMap!.lowerBound)
    let beforeTabMap = String(applyBody[applyBody.startIndex..<(tabMap?.lowerBound ?? applyBody.endIndex)])
    // ⚠️ v4.0.x：这条口径已改 —— 快捷菜单**现在会切到聊天页**（宠物锚点只有 ChatView 有）。
    // 旧断言查的是 `selected = tab`（tab 映射那行的字面量），新代码写的是 `selected = .chat` → 查不到 = 空真。
    // 现在钉的真正约束是「切页与弹菜单不许在同一轮」：切过页的**全部**路径都走 milliseconds(400) 延后请求
    // （与「会话有没有消息」正交，两支都要延），否则 onChange(of: selected) 会在同一帧把刚弹的菜单收掉。
    let tabSwitchSlice = stripCommentLines(
        String(beforeTabMap.components(separatedBy: "let wasOnChat = selected == .chat").last ?? ""))
    func firstIndex(_ hay: String, _ needle: String) -> Int? {
        guard let r = hay.range(of: needle) else { return nil }
        return hay.distance(from: hay.startIndex, to: r.lowerBound)
    }
    let taskAt = firstIndex(tabSwitchSlice, "Task { @MainActor in")
    let slotAt = firstIndex(tabSwitchSlice, "openOrbMenuAtDockSlot()")
    let petAt = firstIndex(tabSwitchSlice, "requestOrbMenuAtPetAnchor()")
    check("切页后弹菜单必须延到下一轮（onChange(of: selected) 会同帧收掉菜单）",
          taskAt != nil && slotAt != nil && petAt != nil
          && slotAt! > taskAt! && petAt! > taskAt!)
    check("弹菜单的落点只有两个具名方法（不许再散落裸 showOrbMenu = true）",
          applyBody.contains("openOrbMenuAtDockSlot()")
          && applyBody.contains("requestOrbMenuAtPetAnchor()")
          && !applyBody.contains("showOrbMenu = true"))
} else {
    check("找得到 applyRoute 函数体（applyRoute → handleShareURL）", false)
}

// MARK: ⑦ 双审查（2026-09-27）修正项 —— 每条都是「复发了就再出同样事故」

// ⑦-1 body 巨型链红线（CI run #571）：带闭包的监听必须抽成 ViewModifier，不许直接挂在链上
check("带闭包的投递监听抽成 IntentRouteModifier（body 巨型链不许再挂闭包修饰符）",
      dockSrc.contains("private struct IntentRouteModifier: ViewModifier")
      && dockCode.contains(".modifier(IntentRouteModifier(onRoute: applyRoute))"))

// 该结构是本文件最后一个类型 → 取标记之后的部分即可（不引 between：本表没这个助手）
let intentModSlice = dockCode.components(separatedBy: "private struct IntentRouteModifier").last ?? ""
check("IntentRouteModifier 自己碰不到 selected（切页必须由宿主注入）",
      !intentModSlice.isEmpty && !intentModSlice.contains("selected"))
check("广播这条也清兜底 flag（幂等：不清 = 60s 内重进会被拽回那一页）",
      intentModSlice.contains("_ = QingliaoRouteHandoff.consume()"))

// ⑦-2 文本链路模型取源：纯文本回主模型（翻译浮层的 30s 超时是配主模型的；切 Agent 档位会成片掐断）
check("纯文本链路只认主模型（imageDataURL == nil → CloudConfig.mainModelAndProvider）",
      intentCode.contains("imageDataURL == nil")
      && intentCode.contains("? CloudConfig.mainModelAndProvider")
      && intentCode.contains(": modelForImage(true)"))
check("模型取源不许合并回一条（modelForImage(imageDataURL != nil) 已撤）",
      !intentCode.contains("modelForImage(imageDataURL != nil)"))

// ⑦-3 「造 qingliao:// 串」的助手不许复活（复活 = 又请系统 launch，iOS 26 必拒）
check("造 qingliao:// 串的 url/openURL 助手不许复活",
      !supportCode.contains("static func openURL(") && !supportCode.contains("c.scheme = scheme"))

// ⑦-4 浮层载荷成对设/清：译文「换一张」重开浮层前必须先清载荷
check("译文「换一张」重开浮层前清 identifyPhoto（否则老照片被当拍照识别）",
      dockCode.contains("identifyPhoto = nil\n                                   identifyStartTranslate = true"))
check("applyRoute 已在目标页时不白置烟花标志",
      dockCode.contains("if selected != tab { skipBurstOnce() }"))

// MARK: 收尾

ud.removeObject(forKey: QingliaoRouteHandoff.defaultsKey)
print("快捷指令打开页真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
