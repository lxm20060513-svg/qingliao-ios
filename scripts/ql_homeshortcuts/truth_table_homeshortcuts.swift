import Foundation

// MARK: - v3.9.82 桌面图标长按快捷方式 真值表（源码形态，本机可跑）
//
// 用户 2026-09-25 点名要 6 项：AI识别 / 语音对话 / 语音输入 / 新建会话 / AI速记 / 今日待办；
// v4.0.x 长按菜单 6 颗 → 8 颗后，候选跟着长到 8 项（新增「会话纪要」/「拍照识别」排尾）。
// iOS 桌面长按菜单**系统上限就是 4 项**（静态 plist 与动态 shortcutItems 同一口径），
// 所以本版口径 = 候选全做（v4.0.x = 8 项）、设置页自己挑 4 项、按设置重建系统菜单。
//
// 本表钉八件事（都是「本机一眼能查、真机上才看得出来」的形态）：
//   ① 候选顺序 = 用户点名顺序 + 新胶囊排尾（order == [4,5,2,0,1,3,6,7]），默认勾选 = 前 4 项；
//   ② **不复制第二套动作表**：HomeShortcuts.swift 里不许出现快捷方式标题/图标字面量，
//      标题与动作语义只有 `OrbQuickAction.all` 一个真源（复制必然漂移）；
//   ③ 动作派发只经过 `handleOrbAction`（桌面菜单与长按智慧球同一套动作语义）；
//   ④ **「全关」与「从没设置过」必须区分**（off 哨兵）—— 否则最后一项永远关不掉（点掉又自己亮回来）；
//   ⑤ 系统菜单按设置动态重建（不用 plist 静态 UIApplicationShortcutItems）；
//   ⑥ 接收点挂在 `OrbMenuFromPetModifier`（body 巨型链不许再挂第二个 .modifier —— CI 类型检查超时红线）；
//   ⑦ 设置页有入口、弹窗有「恢复默认」（且判据用集合比较）；
//   ⑧ **v3.9.83：接收端必须是 scene delegate**（SwiftUI 进程是 scene-based，AppDelegate 的
//      performActionFor 永不被调用 —— v3.9.82 真机「点了不跳转」的根因，见下方 ⑦ 段注释）。

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}
func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
/// 去注释行：负断言必须走它（注释里讲清「不许出现什么」时，否则会被自己染红）
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}
/// 去掉全部空白 —— 顺序/相邻类断言不受缩进漂移影响
func flat(_ s: String) -> String { s.filter { !$0.isWhitespace } }
/// 截取 [from, to) 区段
func region(_ s: String, from: String, to: String) -> String {
    guard let a = s.range(of: from), let b = s.range(of: to, range: a.upperBound..<s.endIndex) else { return "" }
    return String(s[a.lowerBound..<b.lowerBound])
}

let shortcuts = src("qingliao/Features/HomeShortcuts.swift")
let sheet = src("qingliao/Features/Settings/HomeShortcutSheet.swift")
let dock = src("qingliao/Features/DockTabView.swift")
let chat = src("qingliao/Features/Chat/ChatView.swift")
let sections = src("qingliao/Features/Settings/SettingsViewSections.swift")
let settings = src("qingliao/Features/Settings/SettingsView.swift")
let orbMenu = src("qingliao/Features/OrbQuickMenu.swift")
let proj = src("project.yml")

check("HomeShortcuts.swift 源可读", !shortcuts.isEmpty)
check("HomeShortcutSheet.swift 源可读", !sheet.isEmpty)
check("DockTabView.swift 源可读", !dock.isEmpty)

// ── ① 候选与默认：顺序 = 用户点名顺序 ───────────────────────────────
check("候选顺序 = 用户点名顺序 + 新胶囊排尾：order == [4, 5, 2, 0, 1, 3, 6, 7]",
      flat(shortcuts).contains("staticletorder:[Int]=[4,5,2,0,1,3,6,7]"))
check("默认勾选 = 点名的前 4 项：defaultIds == [4, 5, 2, 0]",
      flat(shortcuts).contains("staticletdefaultIds:[Int]=[4,5,2,0]"))
check("上限 4 = iOS 系统限制（maxCount = 4，不写死在别处）",
      flat(shortcuts).contains("staticletmaxCount=4"))
check("候选按 id 从 OrbQuickAction.all 取（不是自建数组）",
      flat(shortcuts).contains("order.compactMap") && flat(shortcuts).contains("OrbQuickAction.all.first"))

// ── ② 不复制第二套（标题/图标只有一个真源） ──────────────────────────
// 候选清单里的名字（v4.0.x = 8 个）只要在 HomeShortcuts.swift 的**代码行**里出现，就说明有人抄了第二套。
let codeOnly = stripCommentLines(shortcuts)
let copiedTitles = ["AI 识别", "语音对话", "语音输入", "新建会话", "AI 速记", "今日待办",
                    "会话纪要", "拍照识别"]
      .filter { codeOnly.contains($0) }
check("HomeShortcuts.swift 代码行里没有快捷方式标题字面量（防复制第二套）—— 命中：\(copiedTitles)",
      copiedTitles.isEmpty)
check("图标也走同一真源（用 a.icon / a.title / a.color，不自写 SF Symbol）",
      flat(codeOnly).contains("localizedTitle:a.title") && flat(codeOnly).contains("systemImageName:a.icon"))

// ── ③ 动作派发单一真源 ──────────────────────────────────────────────
let dispatchRegion = region(dock, from: "private func dispatchQuickAction", to: "// MARK: - v3.4.14")
check("dispatchQuickAction 里只有一层转发：调 handleOrbAction(action)（不复制动作分发）",
      flat(dispatchRegion).contains("handleOrbAction(action)"))
let handleRegion = region(dock, from: "private func handleOrbAction", to: "// MARK: - v3.9.82")
check("handleOrbAction 仍在 DockTabView（唯一动作真源），且被桌面快捷方式复用",
      !handleRegion.isEmpty && handleRegion.contains("switch"))

// ── ④ 「全关」哨兵（本次真机必踩坑：最后一项关不掉） ──────────────────
check("全关写哨兵：write() 里 normalized.isEmpty ? offSentinel",
      flat(codeOnly).contains("normalized.isEmpty?offSentinel"))
check("哨兵非空且非数字（解析不出合法 id → ids(from:) 返回 [] 而不是回落默认）",
      flat(codeOnly).contains("staticletoffSentinel=\"off\""))
check("空串仍判为「从未设置」→ 回落默认 4 项（老用户升级后菜单不空）",
      flat(codeOnly).contains("ifvalid.isEmpty&&!raw.isEmpty{return[]}"))
check("超上限时截断到 4 项（prefix(maxCount)）",
      flat(codeOnly).contains("prefix(HomeShortcut.maxCount)"))
check("勾满后不再悄悄顶掉已选项（set 返回 false 而不是替换）",
      flat(codeOnly).contains("guardlist.count<HomeShortcut.maxCountelse{returnfalse}"))
check("弹窗「恢复默认」判据用集合比较（选了 4 个但非默认时也给出口）",
      flat(stripCommentLines(sheet)).contains("Set(selected)!=Set(HomeShortcut.defaultIds)"))

// ── ⑤ 动态重建系统菜单（不用 plist 静态项） ──────────────────────────
check("System 菜单按设置重建：UIApplication.shared.shortcutItems = ids.compactMap",
      flat(codeOnly).contains("UIApplication.shared.shortcutItems=HomeShortcutStore.ids.compactMap"))
check("project.yml 里没有静态 UIApplicationShortcutItems（动态方案的唯一真源是设置页）",
      !proj.contains("UIApplicationShortcutItems"))
check("type 前缀可逆解出 id（系统回调只回字符串 type）",
      flat(codeOnly).contains("typePrefix+String(id)") && flat(codeOnly).contains("Int(type.dropFirst"))

// ── ⑥ 接收点：挂在 OrbMenuFromPetModifier 内，body 链不多挂修饰符 ────
let petMod = region(dock, from: "private struct OrbMenuFromPetModifier", to: "\n}\n")
let petFlat = flat(stripCommentLines(petMod))
check("接收点仍在 OrbMenuFromPetModifier（新开修饰符 = body 巨型链类型检查超时红线）",
      petFlat.contains("letonQuickAction:(Int)->Void"))
check("两路接收都在：通知直达 + 冷启动补取",
      petFlat.contains(".onReceive(NotificationCenter.default.publisher(for:.qingliaoQuickAction))")
      && petFlat.contains("dispatchPendingQuickAction()"))
// v3.9.82（代码审查补）：上面那条只断言「文本在」，于是「调用点在修饰符里、定义留在宿主里」也能全绿 ——
// 而那是 CI Archive 才报的 has no member（本地 swiftc -parse 不做名字解析，任何一步都抓不到）。
// 把两头都钉死：定义必须**就在这个类型内**，且真的走注入的方法引用、不碰宿主私有成员。
check("dispatchPendingQuickAction 的定义就在 OrbMenuFromPetModifier 内（不许只留调用点）",
      petFlat.contains("privatefuncdispatchPendingQuickAction()->Bool"))
check("分发走注入的 onQuickAction 方法引用（不引用宿主私有成员）",
      petFlat.contains("onQuickAction(id)"))
check("冷启动补取有 0.8s 二次机会（观察者刚注册时的窄窗口）",
      petFlat.contains("Task.sleep(for:.seconds(0.8))"))
check("body 链上 OrbMenuFromPetModifier 只挂一处（没多出第二个 .modifier(…))",
      stripCommentLines(dock).components(separatedBy: ".modifier(OrbMenuFromPetModifier(").count - 1 == 1)

// ── ⑦ App 生命周期接线 + 设置页入口 ─────────────────────────────────
let appDelegate = region(chat, from: "final class QingliaoAppDelegate", to: "// v2.0.110")
check("启动时重建菜单：didFinishLaunching 里 HomeShortcutManager.sync()",
      flat(appDelegate).contains("HomeShortcutManager.sync()"))
// 🚨 v3.9.83（真机 bug：点快捷方式只把 App 打开、不跳转）——下面这组才是**接收端的真形态**：
//    SwiftUI 生命周期（@main App + WindowGroup）下进程是 scene-based 的，UIKit 把快捷方式事件
//    交给 **scene delegate**，`UIApplicationDelegate.application(_:performActionFor:)` 在 scene-based
//    进程上**根本不会被调用**（Apple 文档：非 scene app 才用 app delegate 那条）。
//    v3.9.82 只写了 AppDelegate 那条 → 整条链路是死代码，而且原来这里那条
//    「系统回调在 AppDelegate：performActionFor」断言**正好把错形态钉成了正确形态**，所以本地全绿、
//    真机全废。教训：断言要钉「事件真实到达的路径」，不能钉「我写了哪个方法」。
check("AppDelegate 注册了 scene delegate（缺这条，快捷方式事件永远到不了 App）",
      flat(appDelegate).contains("configurationForConnectingconnectingSceneSession")
      && flat(appDelegate).contains("config.delegateClass=QingliaoSceneDelegate.self"))
check("scene delegate 实现 UIWindowSceneDelegate（不是只声明）",
      flat(stripCommentLines(shortcuts)).contains("finalclassQingliaoSceneDelegate:NSObject,UIWindowSceneDelegate"))
check("两条入口都在：冷启动 connectionOptions.shortcutItem + 运行中 windowScene(performActionFor:)",
      flat(stripCommentLines(shortcuts)).contains("connectionOptions.shortcutItem")
      && flat(stripCommentLines(shortcuts)).contains("funcwindowScene(_windowScene:UIWindowScene,performActionFor"))
check("两条入口都汇到 HomeShortcutManager.handle（单一真源，不再各写一套）",
      flat(stripCommentLines(shortcuts)).components(separatedBy: "HomeShortcutManager.handle(").count - 1 == 2)
check("scene delegate 里不建窗口（窗口仍归 SwiftUI 的 WindowGroup 管）",
      !flat(stripCommentLines(shortcuts)).contains("makeKeyAndVisible"))
check("AppDelegate 的 performActionFor 降为兜底但仍在（非 scene 进程的唯一入口）",
      flat(appDelegate).contains("performActionForshortcutItem")
      && flat(appDelegate).contains("completionHandler(HomeShortcutManager.handle(shortcutItem))"))
check("冷启动兜底读 launchOptions[.shortcutItem]（非 scene 进程的冷启动路径）",
      flat(appDelegate).contains("launchOptions?[.shortcutItem]"))
// 第二条注册途径（plist 兜底）：只在 AppDelegate 那条被系统绕过时才起作用，但不写就少一层保险。
check("project.yml 声明 scene manifest + 指向同一个 SceneDelegate（plist 兜底途径）",
      flat(proj).contains("UIApplicationSceneManifest")
      && flat(proj).contains("UISceneDelegateClassName:\"$(PRODUCT_MODULE_NAME).QingliaoSceneDelegate\""))
check("设置页有「桌面快捷方式」入口，行尾计数读同一真值",
      sections.contains("桌面快捷方式") && flat(sections).contains("HomeShortcutStore.ids(from:homeShortcutsRaw).count"))
check("入口打开 HomeShortcutSheet（弹窗挂了 medium/large 两档高度）",
      flat(stripCommentLines(settings)).contains("HomeShortcutSheet()"))
check("OrbQuickAction.all 已是 8 项（候选清单的来源，被删/改数会连带失效）",
      orbMenu.components(separatedBy: "OrbQuickAction(id:").count - 1 == 8)

// ── ⑨ v4.0.x：候选清单必须**跟着 OrbQuickAction.all 长**（6 → 8）──────────
// 这是本条不是「改数字」而是**绑定**：order 少写一个 id = 设置页少一个可勾选项（用户看不到新胶囊），
// 写了个不存在的 id = 那一项整条消失（candidates 是 compactMap 过滤，不会崩但会静默少一颗）。
let orbAllIds: Set<Int> = {
    var s = Set<Int>()
    for chunk in orbMenu.components(separatedBy: "OrbQuickAction(id: ").dropFirst() {
        if let n = Int(chunk.prefix { $0.isNumber }) { s.insert(n) }
    }
    return s
}()
let orderIds: [Int] = {
    guard let a = shortcuts.range(of: "static let order: [Int] = ["),
          let b = shortcuts.range(of: "]", range: a.upperBound..<shortcuts.endIndex) else { return [] }
    return shortcuts[a.upperBound..<b.lowerBound]
        .split(separator: ",")
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
}()
check("候选数 = OrbQuickAction.all 数量（v4.0.x：8 = 8；order 是候选清单唯一真源）",
      !orderIds.isEmpty && orderIds.count == orbAllIds.count)
check("order 里每个 id 都能在 OrbQuickAction.all 找到（错一个 = 设置页整项消失）",
      !orderIds.isEmpty && Set(orderIds).isSubset(of: orbAllIds))
check("新胶囊 id 6/7 已进候选（排尾，不动老用户已熟悉的候选次序）",
      Array(orderIds.suffix(2)) == [6, 7])
check("默认勾选与上限未动（新候选不自动上位 —— 老用户桌面菜单不因发版而变）",
      flat(shortcuts).contains("staticletdefaultIds:[Int]=[4,5,2,0]")
      && flat(shortcuts).contains("staticletmaxCount=4"))

print("桌面快捷方式真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
