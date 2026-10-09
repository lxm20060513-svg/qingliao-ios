import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// ql_docklayout 真值表 —— v4.0.82「Dock 栏设置（顺序 + 隐藏）」
//
// 用户口径（2026-10-09 原话）：「设置里面增加 dock 栏设置，聊天、生活、看板、设置页可以调整顺序，
// 可以隐藏某一页，唯独设置页不能隐藏」。
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
let D_ORDER = "chat,life,dashboard,settings"

print("== ① sanitizedOrder：顺序净化（坏串一律回出厂序，宁可回默认也不许悄悄少一格）")
check("空串 → 出厂序", DockLayoutKit.sanitizedOrder("") == A)
check("出厂序原样通过", DockLayoutKit.sanitizedOrder(D_ORDER) == A)
check("设置页可前移（顺序自由：用户只说不能隐藏，没说不能移动）",
      DockLayoutKit.sanitizedOrder("settings,chat,life,dashboard") == ["settings", "chat", "life", "dashboard"])
check("任意排列都放行（倒序）",
      DockLayoutKit.sanitizedOrder("settings,dashboard,life,chat") == ["settings", "dashboard", "life", "chat"])
check("缺项按出厂序补到末尾",
      DockLayoutKit.sanitizedOrder("life,chat") == ["life", "chat", "dashboard", "settings"])
check("未知项剔除",
      DockLayoutKit.sanitizedOrder("chat,zzz,life,dashboard,settings") == A)
check("重复项去重",
      DockLayoutKit.sanitizedOrder("chat,chat,life,dashboard,settings") == A)
check("全坏值 → 出厂序", DockLayoutKit.sanitizedOrder("zzz,qqq") == A)
check("空白容错（trim）",
      DockLayoutKit.sanitizedOrder(" chat , life , dashboard , settings ") == A)
check("结果恒为 4 档",
      ["", "zzz", D_ORDER, "settings,chat"].allSatisfy { DockLayoutKit.sanitizedOrder($0).count == 4 })

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
check("canHide：只有设置页是 false（其余三档都可隐藏）",
      !DockLayoutKit.canHide(raw: "settings")
      && ["chat", "life", "dashboard"].allSatisfy { DockLayoutKit.canHide(raw: $0) })

print("== ③ visible：渲染裁剪（顺序 − 隐藏；设置页兜底必须在列）")
check("默认 = 4 档出厂序",
      DockLayoutKit.visible(order: A, hidden: []) == A)
check("隐藏生活页 → 3 档（槽位自动收窄）",
      DockLayoutKit.visible(order: A, hidden: ["life"]) == ["chat", "dashboard", "settings"])
check("隐藏生活 + 看板 → 2 档",
      DockLayoutKit.visible(order: A, hidden: ["life", "dashboard"]) == ["chat", "settings"])
check("★ 极限：隐藏聊天 + 生活 + 看板 → 只剩设置页（渲染列表永不为空）",
      DockLayoutKit.visible(order: A, hidden: ["chat", "life", "dashboard"]) == ["settings"])
check("★ 坏数据（隐藏串含设置页）→ 设置页仍在列且位置不乱",
      DockLayoutKit.visible(order: A, hidden: ["settings", "life"]) == ["chat", "dashboard", "settings"])
check("换序 + 隐藏组合：order=settings,dashboard,life,chat 隐藏 life → 保序裁剪",
      DockLayoutKit.visible(order: ["settings", "dashboard", "life", "chat"], hidden: ["life"])
        == ["settings", "dashboard", "chat"])
check("forcing：临时插回被隐藏的档 → 回到它**原本的**位置（不是追加到末尾）",
      DockLayoutKit.visible(order: A, hidden: ["life"], forcing: ["life"]) == A)
check("forcing 只影响被强制的那档，其余隐藏照旧",
      DockLayoutKit.visible(order: A, hidden: ["life", "dashboard"], forcing: ["life"])
        == ["chat", "life", "settings"])
check("order 与 hidden 全空 → 仍给设置页（兜底不空屏）",
      DockLayoutKit.visible(order: [], hidden: []) == ["settings"])

print("== ④ slotIndex：槽位序号（微滑方向 / 浮层锚点几何，禁止再写死）")
check("默认序：chat=0 / life=1 / dashboard=2 / settings=3",
      ["chat", "life", "dashboard", "settings"].enumerated().allSatisfy {
          DockLayoutKit.slotIndex(of: $0.element, in: A) == $0.offset
      })
check("换序后序号跟着走（settings 前移 → settings=0 / chat=1）",
      DockLayoutKit.slotIndex(of: "settings", in: ["settings", "chat", "life", "dashboard"]) == 0
      && DockLayoutKit.slotIndex(of: "chat", in: ["settings", "chat", "life", "dashboard"]) == 1)
check("★ 隐藏后自动收窄：隐藏 life → dashboard 由 2 变 1",
      DockLayoutKit.slotIndex(of: "dashboard", in: DockLayoutKit.visible(order: A, hidden: ["life"])) == 1)
check("不在列表 → 0（退第一格，不崩、不锚到屏外）",
      DockLayoutKit.slotIndex(of: "life", in: ["chat", "settings"]) == 0)

print("== ⑤ encodeHidden：写回形态（按出厂序的规范串）")
check("按出厂序规范", DockLayoutKit.encodeHidden(["dashboard", "life"]) == "life,dashboard")
check("空集合 → 空串", DockLayoutKit.encodeHidden([]) == "")
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

check("DockTab 的 rawValue 四档与 allRaw 一致（映射靠 rawValue，错一个字符就整串失效）",
      dockView.contains("case sessions, life, chat, dashboard, settings"))
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
check("微滑方向按当前渲染档序判（order 形参），不再读写死的 slotIndex",
      dockView.contains("let myIdx = order.firstIndex(of: tab) ?? 0")
      && dockView.contains("let myIdx = order.firstIndex(of: .chat) ?? 0"))
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

print("\n通过 \(ok) 项，失败 \(fail) 项")
if fail > 0 { exit(1) }
