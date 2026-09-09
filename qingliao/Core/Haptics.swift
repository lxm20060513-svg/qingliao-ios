import UIKit
import SwiftUI

// MARK: - v3.4.25 统一触感反馈工具
// 全站触感一处封装：语义化 API（成功/警告/轻点/长按），替代散落的 UIImpactFeedbackGenerator。
// 用 UINotificationFeedbackGenerator 表达结果类反馈（成功✓/失败✗），impact 表达动作类。

@MainActor
enum Haptics {
    private static let lightGen = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let notifyGen = UINotificationFeedbackGenerator()

    /// 轻点类动作：发送消息、开关切换
    static func tap() {
        lightGen.impactOccurred()
    }

    /// 长按菜单呼出、拖拽开始等中等强度确认
    static func press() {
        mediumGen.impactOccurred()
    }

    /// 操作成功：复制完成、发送成功、拉取到新推送
    static func success() {
        notifyGen.notificationOccurred(.success)
    }

    /// 操作失败/警告：发送失败、内容为空
    static func error() {
        notifyGen.notificationOccurred(.error)
    }
}
