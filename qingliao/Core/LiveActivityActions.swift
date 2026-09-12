import AppIntents
import Foundation

/// 灵动岛按钮 → 主 App 的进程内通道（v3.9.7）。
///
/// 为什么绕这一下：
/// · 侧载免费签名**拿不到 App Groups 能力**，挂件扩展与主 App 的 `UserDefaults` 是两个容器，不能直接共享；
/// · Apple 文档：`LiveActivityIntent`（而非 `AppIntent`）会在**主 App 进程**里执行、且不打开 App
///   → 挂件里的按钮动作能直接落进 App 进程，于是用「NotificationCenter 通知 + UserDefaults 兜底」
///   把动作交给正在跑的那份 App（通知覆盖 App 活着在后台的常见情形，flag 覆盖 App 进程刚被拉起的冷启动）。
///
/// ⚠️ 本文件同时编入主 App 与挂件 target（project.yml 两处都列了它）：只有在两个 target 里都存在，
/// 系统才会优先在 App 进程执行；只放在挂件里会固定在挂件进程执行（那样就触不到 App 的流）。
enum LiveActivityAction {
    /// 停止当前 AI 回复
    static let stopGeneration = "stopGeneration"
}

enum LiveActivityActionBridge {

    /// 主 App 侧监听这条通知（进程内即时生效）
    static let notification = Notification.Name("qingliao.liveActivityAction")

    /// 兜底存储 key：App 冷启动时读一次（进程刚起来时观察者还没注册，通知会丢）
    static let defaultsKey = "qingliao_live_activity_action"

    /// 兜底动作的有效期：超过这个时长就丢弃。
    /// 理由：intent 若在「根视图已出现但通知没被消费」的罕见时序下投递，flag 会一直留到下次冷启动，
    /// 届时误触发一次停止——所以写入时带时间戳，读取时过期即丢。
    private static let staleAfter: TimeInterval = 60

    /// 投递动作（在 App 进程里被调用）
    static func deliver(_ action: String) {
        UserDefaults.standard.set("\(action)|\(Date().timeIntervalSince1970)", forKey: defaultsKey)
        NotificationCenter.default.post(name: notification, object: nil, userInfo: ["action": action])
    }

    /// 取出并清空待处理动作；没有 / 已过期 / 格式不对都返回 nil（幂等，可重复调用）
    static func consume() -> String? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let parts = raw.split(separator: "|", maxSplits: 1)
        guard let action = parts.first.map(String.init), !action.isEmpty else { return nil }
        if parts.count > 1, let stamped = TimeInterval(parts[1]),
           Date().timeIntervalSince1970 - stamped > staleAfter {
            return nil
        }
        return action
    }
}

/// 灵动岛「停止生成」按钮（v3.9.7）。
///
/// 刻意用 `LiveActivityIntent` 而不是 `AppIntent`：
/// · `AppIntent` 只放在挂件 target 里 → 固定在**挂件进程**执行，触不到 App 的 StreamClient；
/// · `openAppWhenRun` 已废弃，且在 app extension 里置 true 会直接报编译错误 —— 不用它。
///
/// ⚠️ `title` 必须是**计算属性或 `let`**：Swift 6 严格并发下，`static var title: X = …`
/// （即使是 Sendable 类型）会报 `static property 'title' is not concurrency-safe because it is
/// nonisolated global shared mutable state`，CI Archive 直接失败（本机实测复现）。
struct StopGenerationIntent: LiveActivityIntent {

    static var title: LocalizedStringResource { "停止生成" }

    func perform() async throws -> some IntentResult {
        LiveActivityActionBridge.deliver(LiveActivityAction.stopGeneration)
        return .result()
    }
}
