import Foundation
import UserNotifications

/// 「叫醒用户」的兜底手段：本地通知。
///
/// 背景：**iOS 18 起系统明令禁止 App 扩展拉起宿主 App**（`extensionContext.open` 抛
/// `LSApplicationWorkspaceErrorDomain 115`），扩展只能把内容放进剪贴板等人来取。
/// Apple 对「扩展要引起用户注意」的建议做法正是**发一条本地通知**：通知由系统在点击后
/// 打开宿主 App（轻聊），而 App 回前台会自动接住剪贴板里的载荷（见主 App `ShareIntake.resume`）
/// —— 所以这条 nudge 是有实际作用的，不是装饰。
///
/// 全链路**尽力而为**：未授权 / 投递失败 / 被系统静默丢掉 → 什么都不做。
/// 扩展 UI 的主文案已经写清「手动打开轻聊」，不依赖这条通知也走得通。
enum ShareNudge {

    /// 投一条即时通知（`trigger: nil` = 立即送达）。
    static func notify() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            guard granted else { return }   // 没授权就静默放弃（扩展里没有别的出口可提示权限问题）
            let content = UNMutableNotificationContent()
            content.title = "分享还没送出去"
            content.body = "点这条通知打开轻聊，刚分享的内容会自动进当前会话。"
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content,
                                                trigger: nil)
            // ⚠️ 回调里**重新取** `current()`，不把 center 捕获进来：`UNUserNotificationCenter`
            // 不是 Sendable，捕获它在 Swift 6 严格并发下是编译错误。
            // 本仓既有写法同此（QuickReminderScheduler / NotificationHelper 的续体桥接）。
            UNUserNotificationCenter.current().add(request, completionHandler: nil)
        }
    }
}
