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

    /// v3.9.72（用户：剪切板有内容不要每次进 App 都提示）：**探测门**。
    ///
    /// 旧门 `isHandled` 比的是「**上次处理过**的那一版」——语义有两个漏斗：
    ///   ① 用户从没点过「忽略 / 发给 AI」→ 没有任何「处理」记录 → 每次进 App 都重新弹；
    ///   ② 两次之间设备重启 → uptime 校验让旧记录作废 → 同一份内容又弹一遍。
    /// 新门比的是「**上次进 App 时看到过**的那一版」（进入前台时无条件记账，不管认没认出来）：
    /// 内容没变 → `.silentSameContent`，一次都不打扰；只有剪贴板真变了（在别的 App 拷了东西再切回来，
    /// 也就是地图分享兜底那套流程）才 `.probe` 继续往下认。
    enum ProbeDecision: Equatable {
        /// 与上次进 App 时看到的完全同一版 → 静默，不探测也不提示
        case silentSameContent
        /// 剪贴板变了（含设备重启后计数回退）→ 值得探一次
        case probe
    }

    static func decide(changeCount: Int, lastSeenChange: Int) -> ProbeDecision {
        // 不区分「变大/变小」：重启后 changeCount 会回退，任何不同都当作「有新内容」去探一次
        changeCount == lastSeenChange ? .silentSameContent : .probe
    }
}

/// 剪贴板提示条的展示参数（v3.9.72）。
/// 放纯 Foundation 文件是为了能进真值表：这条「一段时间没操作就自动收起」的时长必须可断言
/// （0 = 永不收起、过大 = 形同不收起），别让它在 UI 文件里随手改。
enum ClipboardBanner {
    /// 提示条弹出后，用户一直没操作 → 自动收起（秒）
    static let autoHideSeconds: Double = 10
}
