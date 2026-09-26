import Foundation

// v4.0.0：启动会话模式定义（设置入口在「外观」页 AppearanceSheet 内，本文件只放纯逻辑/枚举）

/// 三档语义（**必须分清，否则用户会觉得「选了没用」**）：
///   · 新对话：冷启动一律开空白新会话
///   · 上次会话：一律回到上次那个会话（不等时间）
///   · 自动：距上次离开 App 超过阈值（默认 15 分钟）就开新对话，否则回上次会话
enum LaunchSessionMode: String, CaseIterable, Identifiable {
    case auto, last, new

    /// 用户没设置过时的默认空闲阈值 = 需求里的 15 分钟
    static let defaultIdleMinutes = 15
    /// 阈值可选档位（分钟）
    static let idleOptions = [5, 10, 15, 30, 60, 120]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .last: return "上次会话"
        case .new:  return "新对话"
        }
    }
}

// MARK: - 判定逻辑（**必须住在这里，不能只写在 ChatStore 里**）
//
// 🚨 v4.0.0 审查抓到的真问题：原先判定只写在 `ChatStore.applyLaunchSessionPolicy` 内，
//   而真值表 `test_launch_session.swift` 在表内**另写了一份**镜像实现、且**不编译生产源码**
//   → 改 `>=` 成 `>`、改默认 15、改 nil 兜底、删掉整条 touchLastActive 接线，表**全绿**。
//   判据：`LaunchSession.swift` 是纯 Foundation、无 UIKit 依赖 → 可以直接编进测试单，
//   于是公式与常量都从生产源码来，公式一改必红。
//
// 语义（`idleMinutes == nil` = 无记录/首次安装 → **保守回上次会话**）：
//   没有证据说明上次会话久未使用，凭空开新对话只会让用户丢上下文。
func shouldOpenNewSession(mode: LaunchSessionMode, idleMinutes: Int?, threshold: Int) -> Bool {
    switch mode {
    case .new:
        return true
    case .last:
        return false
    case .auto:
        guard let idleMinutes else { return false }
        return idleMinutes >= threshold
    }
}

/// 上次活跃（离开 App）距今的分钟数；无记录/时间戳非法返回 nil。
/// `guard raw > 0` 挡的是**存量**为 0；`elapsed >= 0` 挡的是**未来**时间戳（时钟回拨/改机时间）
/// —— 后者算出来是负数，会让「自动」档永远判「刚离开过」。
func idleMinutesSince(nowMs: Double, lastActiveAtMs: Double) -> Int? {
    guard lastActiveAtMs > 0 else { return nil }
    let elapsed = nowMs - lastActiveAtMs
    guard elapsed >= 0 else { return nil }
    return Int(elapsed / 60_000)
}
