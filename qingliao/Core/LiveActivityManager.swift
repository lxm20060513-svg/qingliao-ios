import ActivityKit
import Foundation

/// 「AI 正在回复」实时活动管理器（v3.8.0）。
///
/// 设计边界（刻意为之，别随手扩）：
/// - **只做本地驱动**：`Activity.request/update/end`，不依赖 APNs。侧载免费签名拿不到 Push 能力，
///   远程更新/push-to-start 必须付费开发者账号，所以不做，也不留半成品接口。
/// - **幂等**：同一会话在跑时重复 sync 只做 update，不重复创建活动。
/// - 频道状态由调用方（ChatView 的 `aiBusy`）决定，这里只负责开始/更新/结束。
@MainActor
final class LiveActivityManager {

    static let shared = LiveActivityManager()

    /// 当前活动（每个 App 同一时刻只保留一个「AI 正在回复」活动）
    private var activity: Activity<QingliaoActivityAttributes>?
    private var currentSessionId: String?

    private init() {}

    /// 按「AI 是否在回复」同步实时活动：busy=true 开始/更新，busy=false 结束。
    func sync(isBusy: Bool, sessionId: String, sessionTitle: String, modelName: String) {
        guard isBusy else { end(); return }
        guard !sessionId.isEmpty, ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let title = sessionTitle.isEmpty ? "轻聊" : sessionTitle
        let model = modelName.isEmpty ? "AI" : modelName

        // 同一会话继续回复 → 只更新文案，保留原 startedAt（计时不重启）
        if let activity, currentSessionId == sessionId {
            var state = activity.content.state
            state.sessionTitle = title
            state.modelName = model
            state.isAnswering = true
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }

        end()   // 换了会话：先收旧活动再开新的

        do {
            let attributes = QingliaoActivityAttributes(sessionId: sessionId)
            let state = QingliaoActivityAttributes.ContentState(sessionTitle: title,
                                                               modelName: model,
                                                               startedAt: Date(),
                                                               isAnswering: true)
            activity = try Activity.request(attributes: attributes,
                                            content: ActivityContent(state: state, staleDate: nil),
                                            pushType: nil)
            currentSessionId = sessionId
        } catch {
            // 实时活动被系统拒绝（用户关了「实时活动」/ 数量上限）——静默降级，不影响聊天
            activity = nil
            currentSessionId = nil
        }
    }

    /// 结束当前活动（回复完成 / 用户离开会话）。
    func end() {
        guard let activity else {
            currentSessionId = nil
            return
        }
        var state = activity.content.state
        state.isAnswering = false
        self.activity = nil
        currentSessionId = nil
        // 立即撤下灵动岛：回复已结束，不需要留「已完成」尾巴
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate) }
    }
}
