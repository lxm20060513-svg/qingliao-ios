import SwiftUI
import UIKit
import UserNotifications

// MARK: - v2.0.65 发送完成通知（Dock 轻跳）

// MARK: - v2.0.60 通知点击直达会话（AppDelegate 捕获通知点击 → 存 sessionId）

extension Notification.Name {
    static let qingliaoSent = Notification.Name("qingliao_sent")
    // v3.4.26：看板轮询 Leave/Refresh 通知已移除——改 DockTabView → DashboardView(isActive:) 参数直传，
    // 生命周期收进 DashboardView 自身（见 DashboardView.onChange/.task(id:)）；通知名定义随引用清除
    // v3.4.14：系统分享收件通知（DockTabView.onOpenURL 捕获分享后广播，ChatView 消费发送）
    static let qingliaoShareIncoming = Notification.Name("qingliao_share_incoming")
    // v3.4.x：任务中心「发送到当前会话」通知（TaskCenterView 广播，ChatView 消费发送）
    static let qingliaoTaskSend = Notification.Name("qingliao_task_send")
    // v3.9.14：备忘录「发给 AI」——生活页发通知，这里发送 + DockTabView 切回聊天页
    static let qingliaoMemoSend = Notification.Name("qingliao_memo_send")
    // v3.9.79：长按快捷菜单弹出 → 收键盘（DockTabView 广播，ChatView 消费）
    // （用户 2026-09-25：「这个界面自动收回键盘」——键盘开着时长按球/宠物，六颗胶囊被键盘挤在上半屏）
    static let qingliaoDismissKeyboard = Notification.Name("qingliao_dismiss_keyboard")
    // v3.9.59：长按 dock 智慧球 →「语音输入」胶囊——DockTabView 切聊天页后广播，ChatView 消费进语音模式
    static let qingliaoOrbVoiceInput = Notification.Name("qingliao_orb_voice_input")
    // v4.0.x：会话纪要页整理完 → 把纪要卡放进当前会话（MeetingMinutesView 广播，object = 卡片文本）
    static let qingliaoMinutesCard = Notification.Name("qingliao_minutes_card")
    // v4.0.1：分享接收（ShareIntake，在 Core 层摸不到 DockTabView 的 selected）投递前，
    // 先请宿主把聊天页切进视图树 —— 载荷的落点全是 ChatView 挂的 onReceive，人不在就落空。
    static let qingliaoOpenChat = Notification.Name("qingliao_open_chat")
}

// MARK: - v2.0.60 通知点击直达会话（AppDelegate 捕获通知点击 → 存 sessionId）

// v2.0.64：@preconcurrency 抑制 Swift 6 的 delegate 跨 MainActor Sendable 检查
final class QingliaoAppDelegate: NSObject, UIApplicationDelegate,
                                 @preconcurrency UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // v3.9.83：非 scene 进程的冷启动路径（App 未采用 scene 时，系统把快捷方式塞进 launchOptions）。
        // scene 化进程（SwiftUI 生命周期）走 QingliaoSceneDelegate —— 两条互补，互不干扰。
        if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            HomeShortcutManager.handle(item)
        }
        // v3.9.82：桌面图标长按快捷方式 —— 按用户设置重建系统菜单（动态 shortcutItems；
        // 桌面长按菜单系统上限 4 项，所以 6 个候选里只挂选中的那几个）
        HomeShortcutManager.sync()
        return true
    }

    /// v3.9.83：注册自己的 scene delegate —— SwiftUI 生命周期下快捷方式事件**只发给 scene delegate**，
    /// 不注册 = AppDelegate 的 performActionFor 永远不会被调用（v3.9.82 真机「点了不跳转」的根因）。
    /// 只借它收快捷方式事件，窗口仍归 SwiftUI 的 WindowGroup 管（delegate 里不建窗口）。
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = QingliaoSceneDelegate.self
        return config
    }

    /// v3.9.82 起保留、v3.9.83 起降为**兜底**：只有非 scene 进程会走这条（scene 进程走 QingliaoSceneDelegate）。
    /// 留着零成本 —— 哪天进程不再是 scene-based，链路照样通。
    /// 返回 false = 不是本 App 的快捷方式类型，交回系统默认行为。
    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(HomeShortcutManager.handle(shortcutItem))
    }

    // v2.0.110：后台刷新（方案2推送）——iOS 定期唤醒 App，检查流式任务是否完成 →
    // 完成则发本地通知（侧载无 entitlement 也能用；唤醒间隔由系统决定，非实时）
    func application(_ application: UIApplication,
                     performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let server = UserDefaults.standard.string(forKey: "qingliao_server") ?? ""
        // v3.0.84fix：token 迁 Keychain，后台刷新从 Keychain 读（原 UserDefaults 明文已弃）
        let token = AuthStore.keychainReadToken() ?? ""
        guard let d = UserDefaults.standard.dictionary(forKey: "qingliao_stream_pending"),
              let taskId = d["taskId"] as? String, !taskId.isEmpty,
              !server.isEmpty, !token.isEmpty else {
            completionHandler(.noData)
            return
        }
        var base = server
        if !base.hasPrefix("http") { base = "https://" + base }
        guard let url = URL(string: base + "/api/stream/" + taskId) else {
            completionHandler(.failed)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completionHandler(.failed)
                return
            }
            let status = j["status"] as? String ?? ""
            if status == "done" || status == "error" {
                // 回复完成 → 本地通知 + 清理持久化任务
                let sid = d["sessionId"] as? String
                // v3.4.26：正文取回复首句（后端 GET /api/stream/{taskId} 返回 content）
                NotificationHelper.notifyReply((j["content"] as? String) ?? "", sessionId: sid)
                UserDefaults.standard.removeObject(forKey: "qingliao_stream_pending")
                // v3.9.54：修「后台跑完灵动岛不收尾」。上面这条通知说明**这个回调就是本进程
                // 在后台唯一知道「任务已结束」的时刻**——但原来它从不碰实时活动，于是活动一直
                // 停在「AI 正在回复」，直到用户回前台才被收敛/兜底收掉（用户报的现象逐字一致）。
                // ⚠️ 本闭包由 URLSession 在任意线程回调，`LiveActivityManager` 是 @MainActor，
                // 且这里只能送 Sendable 值（sid / failed），所以走 `Task { @MainActor in … }`。
                // 口径同 v2.0.60 注释：唤醒时机由系统决定，非实时（见 reconcile 的能力边界说明）。
                let failed = (status == "error")
                Task { @MainActor in
                    await LiveActivityManager.shared.reconcileAfterBackgroundCheck(sessionId: sid,
                                                                                  failed: failed)
                }
                completionHandler(.newData)
            } else {
                completionHandler(.noData)   // 未完成，等下次系统唤醒再查
            }
        }.resume()
    }

    // v2.0.63：用 completionHandler 版（async 版在 Swift 6 下 non-Sendable 参数报错）
    // v3.9.4 加固：本类因 `UIApplicationDelegate`（SDK 里是 @MainActor 协议）被推断为 MainActor 隔离，
    // 而 `UNUserNotificationCenterDelegate` **不是** @MainActor（Apple 文档声明仅 NSObjectProtocol，
    // 对回调线程无任何承诺）⇒ 上面的 @preconcurrency 只是把隔离检查**推迟到运行时**：
    // 一旦系统在后台线程回调「点通知」，进方法体即触发隔离断言 = SIGTRAP（与 v3.9.3 语音那次同源）。
    // 方法体只读写 UserDefaults（线程安全、非隔离）并转调 completionHandler，本就不需要主 actor
    // ⇒ 标 nonisolated 即消除该断言，行为零变化（当前线上恰好都在主线程，故一直没暴露）。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let sid = response.notification.request.content.userInfo["qingliao_session"] as? String {
            UserDefaults.standard.set(sid, forKey: "qingliao_open_session")
        }
        completionHandler()
    }

    /// v3.9.39 A6：**前台到点不响**的根治。Apple 的规则是「设了 delegate 但没实现 willPresent
    /// ⇒ 前台来的通知不弹横幅、不出声、也不进通知中心（直接丢弃）」。本类自 v2.0.60 起就是全仓
    /// 唯一的 UNUserNotificationCenterDelegate（:33 赋值），所以所有本地通知在 App 前台时被静默吃掉：
    /// · 一句话定时提醒（典型用法就是「聊天里长按消息 → 5 分钟后提醒」，用户 100% 停在 App 里）
    ///   ——到点无声，下次冷启动 `markExpiredLocally()` 还把它标成「已提醒」，等于凭空消失；
    /// · 收件箱推送 / AI 回复完成通知——InboxStore 注释里写的「App 前台也弹」一直没成立过。
    /// 不给 `.badge`：图标角标由 `NotificationHelper.setBadge` 按任务中心未读数**整体对账**设置
    /// （v3.4.23），再让系统 +1 会变成双重计数、且没有清零路径。
    /// 与 `didReceive` 同样标 `nonisolated`：理由见上面那段 v3.9.4 说明（后台线程回调进 MainActor 体 = SIGTRAP）。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
