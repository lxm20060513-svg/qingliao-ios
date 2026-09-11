import Foundation

/// 剪贴板提示去重（v3.8.1）。
///
/// 背景：地图分享兜底入口靠 `UIPasteboard.changeCount` 记住"这份内容处理过了"，原来只存在 `@State` 里——
/// 每次冷启动都归零，于是**同一份剪贴板内容每次进 App 都重新提示一遍**（用户 2026-09-11 反馈）。
/// 这里把判断抽成纯逻辑：跨启动持久化 + 处理设备重启（重启后 changeCount 从头计数，旧记录必须作废）。
enum ClipboardPromptGate {

    /// 这份剪贴板内容是否已经处理过（处理过 = 不再提示）
    /// - Parameters:
    ///   - changeCount: `UIPasteboard.general.changeCount` 当前值
    ///   - lastHandledChange: 上次处理的 changeCount
    ///   - lastHandledUptime: 上次处理时的 `ProcessInfo.systemUptime`
    ///   - currentUptime: 当前 `ProcessInfo.systemUptime`
    static func isHandled(changeCount: Int,
                          lastHandledChange: Int,
                          lastHandledUptime: Double,
                          currentUptime: Double) -> Bool {
        // 当前 uptime 比记录时小 ⇒ 期间设备重启过 ⇒ changeCount 已从头计数，旧记录不可比 → 作废
        guard currentUptime >= lastHandledUptime else { return false }
        return changeCount == lastHandledChange
    }
}
