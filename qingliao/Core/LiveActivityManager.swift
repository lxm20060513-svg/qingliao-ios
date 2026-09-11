import ActivityKit
import Foundation

/// 「AI 正在回复」实时活动管理器（v3.8.0）。
///
/// 设计边界（刻意为之，别随手扩）：
/// - **只做本地驱动**：`Activity.request/update/end`，不依赖 APNs。侧载免费签名拿不到 Push 能力，
///   远程更新/push-to-start 必须付费开发者账号，所以不做，也不留半成品接口。
/// - **不长期持有 `Activity` 本体**（Swift 6 硬约束，CI #34599892145 实测踩到）：
///   `Activity` 非 Sendable，而 `update/end` 是 nonisolated async——把它存进 `@MainActor` 隔离存储后
///   再 `await activity.update(...)`，编译器报 `sending 'activity' risks causing data races`（三处）。
///   改为：只存 Sendable 状态（sessionId/startedAt），每次从 `Activity.activities` 现取新鲜值再用，
///   这样送进 nonisolated async 方法的是「新值/无隔离归属的值」，符合 Swift 6 的 sending 规则。
@MainActor
final class LiveActivityManager {

    static let shared = LiveActivityManager()

    /// 用户开关的存储 key（设置 → 外观 → 交互）。**默认开**：
    /// `UserDefaults` 无值即视为开启；设置页与这里共用同一 key，避免两套真相。
    static let enabledKey = "qingliao_live_activity"

    /// 开关当前是否开启
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    // MARK: - 本进程状态（只放 Sendable 值）

    /// 当前活动对应的会话（nil = 本进程没有在跟的活动）
    private var currentSessionId: String?
    /// 本轮开始时间——同会话续更时保留，保证灵动岛计时不重启
    private var startedAt: Date?

    private init() {}

    /// 启动收敛：清掉上一进程遗留的活动。
    /// 新进程里我们不认任何活动，而实时活动在 App 被杀/闪退后由系统保留数小时 →
    /// 不收敛就会留下「锁屏一直挂着 AI 正在回复、计时还在跑」的僵尸活动。
    /// 开关关着也走这里：清完不会再新建，新建由 `sync` 的 isEnabled 闸门把关。
    func convergeOnLaunch() async {
        // 本进程已在跟活动 → 说明不是冷启动（防 .task 意外重跑误杀正在显示的实时活动）
        guard currentSessionId == nil else { return }
        currentSessionId = nil
        startedAt = nil
        for activity in Activity<QingliaoActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// 按「AI 是否在回复」同步实时活动：busy=true 开始/更新，busy=false 结束。
    func sync(isBusy: Bool, sessionId: String, sessionTitle: String, modelName: String) async {
        // 用户关掉开关 → 立即收起，且不再新建
        guard isBusy, Self.isEnabled else { await end(); return }
        guard !sessionId.isEmpty, ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let title = sessionTitle.isEmpty ? "轻聊" : sessionTitle
        let model = modelName.isEmpty ? "AI" : modelName
        let now = Date()
        // 同一会话继续回复 → 保留原起始时间（计时不重启）
        let start = (currentSessionId == sessionId) ? (startedAt ?? now) : now

        if currentSessionId != sessionId {
            await end()   // 换了会话：先收旧活动再开新的
        }
        currentSessionId = sessionId
        startedAt = start

        let state = QingliaoActivityAttributes.ContentState(sessionTitle: title,
                                                           modelName: model,
                                                           startedAt: start,
                                                           isAnswering: true)
        let content = ActivityContent(state: state, staleDate: Self.staleDate())

        let existing = Activity<QingliaoActivityAttributes>.activities
        guard existing.isEmpty else {
            for activity in existing {
                await activity.update(content)
            }
            return
        }

        do {
            _ = try Activity.request(attributes: QingliaoActivityAttributes(sessionId: sessionId),
                                     content: content,
                                     pushType: nil)
        } catch {
            // 实时活动被系统拒绝（用户关了「实时活动」/ 数量上限）——静默降级，不影响聊天
            currentSessionId = nil
            startedAt = nil
        }
    }

    /// 结束当前活动（回复完成 / 用户离开会话 / 开关关闭）。幂等：没有活动时是空操作。
    func end() async {
        let hadSession = currentSessionId != nil
        currentSessionId = nil
        startedAt = nil
        var pending = Activity<QingliaoActivityAttributes>.activities
        if pending.isEmpty, hadSession {
            // Activity.activities 是「最终一致」的：刚 request 出来的活动可能还没出现在列表里，
            // 等一拍再收一次，免得留下收不掉的残留（Apple 侧行为，Pocket Casts 亦有同样注释）
            try? await Task.sleep(for: .milliseconds(600))
            pending = Activity<QingliaoActivityAttributes>.activities
        }
        // 立即撤下灵动岛：回复已结束，不需要留「已完成」尾巴
        for activity in pending {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// 过期时间：进程意外消失后（强杀/闪退）系统能把活动标记为过期，而不是无限计时
    private static func staleDate() -> Date {
        Date().addingTimeInterval(15 * 60)
    }
}
