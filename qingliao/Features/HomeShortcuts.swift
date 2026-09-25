//
//  HomeShortcuts.swift
//  轻聊
//
//  v3.9.82：桌面 App 图标长按快捷方式（Home Screen Quick Actions）
//
//  为什么是「动态」而不是 plist 里的静态 UIApplicationShortcutItems：
//    ① iOS 桌面长按菜单**系统上限就是 4 项**（静态/动态一个口径），而用户要的 6 项塞不下；
//    ② 用户要「设置里自己挑 4 个显示」——静态 plist 改不了，只能按设置重建 shortcutItems。
//  所以：6 项全做候选，设置页勾选 4 项（HomeShortcutStore），每次同步重建系统菜单。
//
//  ⚠️ 动作分发**不复制第二套**：id 语义与长按智慧球菜单完全一致（OrbQuickAction.all），
//     点击后统一交给 DockTabView.handleOrbAction —— 那边是唯一真源，这里只负责「把 id 送到」。
//

import SwiftUI
import UIKit

// MARK: - 候选清单

enum HomeShortcut {
    /// 候选展示顺序（= 用户点名的顺序：AI识别 / 语音对话 / 语音输入 / 新建会话 / AI速记 / 今日待办）。
    /// 存的是 OrbQuickAction.id，不是数组下标 —— 与智慧球菜单同一套语义标识。
    static let order: [Int] = [4, 5, 2, 0, 1, 3]

    /// iOS 桌面长按菜单的上限（系统硬限制，改不了）
    static let maxCount = 4

    /// 默认勾选 = 用户点名的前 4 个
    static let defaultIds: [Int] = [4, 5, 2, 0]

    /// UIApplicationShortcutItem.type 前缀（系统回调只回传字符串 type，用它找回 id）
    static let typePrefix = "ql.action."

    /// 候选动作（按展示顺序；标题/图标单一真源仍是 OrbQuickAction.all）
    static var candidates: [OrbQuickAction] {
        order.compactMap { id in OrbQuickAction.all.first { $0.id == id } }
    }

    static func action(id: Int) -> OrbQuickAction? {
        OrbQuickAction.all.first { $0.id == id }
    }

    static func shortcutType(for id: Int) -> String { typePrefix + String(id) }

    static func actionId(from type: String) -> Int? {
        guard type.hasPrefix(typePrefix) else { return nil }
        return Int(type.dropFirst(typePrefix.count))
    }
}

// MARK: - 勾选持久化（设置页与同步共用）

enum HomeShortcutStore {
    static let defaultsKey = "qingliao_home_shortcuts"

    /// 已勾选的 id（最多 4 个，按 HomeShortcut.order 归一化顺序输出）。
    /// `ids(from:)` 独立出来是给设置页行尾计数用 —— 那里用 @AppStorage 拿原始串，改完即时刷新。
    static func ids(from raw: String) -> [Int] {
        let parsed = raw.split(separator: ",").compactMap { Int($0) }
        let valid = HomeShortcut.order.filter { parsed.contains($0) }
        if valid.isEmpty && !raw.isEmpty { return [] }   // 用户主动全关 = 真的不要快捷方式
        if valid.isEmpty { return HomeShortcut.defaultIds }
        return Array(valid.prefix(HomeShortcut.maxCount))
    }

    static var ids: [Int] {
        ids(from: UserDefaults.standard.string(forKey: defaultsKey) ?? "")
    }

    static func isOn(_ id: Int) -> Bool { ids.contains(id) }

    static var selectedCount: Int { ids.count }

    /// 勾选 / 取消。勾满 4 个后再勾新的：**不动已选项、直接忽略**（设置页把未选项置灰并说明），
    /// 比「悄悄顶掉最早那个」可预期 —— 用户看不到自己哪一项被换掉了会当成 bug。
    @discardableResult
    static func set(_ id: Int, on: Bool) -> Bool {
        var list = ids
        if on {
            guard !list.contains(id) else { return true }
            guard list.count < HomeShortcut.maxCount else { return false }
            list.append(id)
        } else {
            list.removeAll { $0 == id }
        }
        write(list)
        Task { @MainActor in HomeShortcutManager.sync() }
        return true
    }

    static func reset() {
        write(HomeShortcut.defaultIds)
        Task { @MainActor in HomeShortcutManager.sync() }
    }

    private static func write(_ list: [Int]) {
        let normalized = HomeShortcut.order.filter { list.contains($0) }
        // ⚠️ 「全关」必须与「从没设置过」区分开：都写空串的话，下一次 ids(from:) 会把空串判成
        // 未设置 → 回落到默认 4 项，用户永远关不掉最后一项（点掉又自己亮回来）。
        // 所以全关时写哨兵值（非空、解析不出任何合法 id → ids(from:) 返回 []）。
        let raw = normalized.isEmpty ? offSentinel : normalized.map { String($0) }.joined(separator: ",")
        UserDefaults.standard.set(raw, forKey: defaultsKey)
    }

    /// 「全关」哨兵（见 write 注释；不是 id，任何合法 id 解析都会跳过它）
    static let offSentinel = "off"
}

// MARK: - 系统菜单同步 + 点击派发

extension Notification.Name {
    /// 桌面快捷方式被点击 → 广播「去取待处理动作」（跨视图信号本仓统一走 NotificationCenter）
    static let qingliaoQuickAction = Notification.Name("qingliao_quick_action")
}

@MainActor
enum HomeShortcutManager {
    /// App 刚被图标长按拉起时，观察者还没注册、通知会丢 → 先存下，视图树就绪后再取
    private static var pendingActionId: Int?

    /// 按设置重建系统快捷方式菜单（启动、设置变更后调用）
    static func sync() {
        UIApplication.shared.shortcutItems = HomeShortcutStore.ids.compactMap { id in
            guard let a = HomeShortcut.action(id: id) else { return nil }
            return UIApplicationShortcutItem(type: HomeShortcut.shortcutType(for: id),
                                             localizedTitle: a.title,
                                             localizedSubtitle: nil,
                                             icon: UIApplicationShortcutIcon(systemImageName: a.icon),
                                             userInfo: nil)
        }
    }

    /// 系统回调（QingliaoSceneDelegate 的两条入口）→ 存待处理 + 广播。返回 false = 不是我们的快捷方式。
    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard let id = HomeShortcut.actionId(from: item.type), HomeShortcut.action(id: id) != nil else {
            return false
        }
        pendingActionId = id
        NotificationCenter.default.post(name: .qingliaoQuickAction, object: nil)
        return true
    }

    /// 取一次待处理动作（取走即清空；返回 nil = 当前没有）
    static func consumePending() -> Int? {
        defer { pendingActionId = nil }
        return pendingActionId
    }
}

// MARK: - v3.9.83 系统快捷方式的**真正接收端**（SceneDelegate）
//
// 🚨 为什么必须有这个类：SwiftUI 生命周期（@main App + WindowGroup）下进程是 **scene-based** 的，
//    UIKit 把「桌面图标长按项被点」交给 **scene delegate**：
//      · App 已在运行（前台/后台）→ `windowScene(_:performActionFor:completionHandler:)`
//      · App 未运行（冷启动）      → `scene(_:willConnectTo:options:)` 的 `connectionOptions.shortcutItem`
//    而 `UIApplicationDelegate.application(_:performActionFor:completionHandler:)` 在 scene-based app 上
//    **根本不会被调用**（Apple 文档明说：非 scene app 才走 app delegate 那条）。
//
//    v3.9.82 只在 AppDelegate 里实现了 performActionFor → 整条链路是死代码：
//    真机表现 = 点快捷方式只把 App 打开、不跳转（用户 2026-09-26 报的就是这个）。
//
// ⚠️ 这个类**不建窗口**：WindowGroup 的窗口仍归 SwiftUI 管，我们只是借 scene delegate 收快捷方式事件。
//    注册方式见 QingliaoAppDelegate.application(_:configurationForConnecting:options:)
//    （注册途径有两条：app delegate 或 Info.plist 的 UIApplicationSceneManifest，前者优先）。
final class QingliaoSceneDelegate: NSObject, UIWindowSceneDelegate {

    /// ① App 未运行 → 从桌面快捷方式冷启动：此时快捷方式在 connectionOptions 里
    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let item = connectionOptions.shortcutItem else { return }
        HomeShortcutManager.handle(item)
    }

    /// ② App 已在运行 → 系统第二条回调（返回 true = 我们处理了，系统不再走默认行为）
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(HomeShortcutManager.handle(shortcutItem))
    }
}
