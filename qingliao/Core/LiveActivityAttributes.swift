import ActivityKit
import Foundation

/// 灵动岛 / 锁屏「实时活动」的共享数据模型（v3.8.0）。
///
/// ⚠️ 本文件**同时编入主 App 与挂件 Extension 两个 target**（project.yml 里都引用了它）——
/// 实时活动的属性类型必须两侧完全一致，改这里等于同时改两侧，别各自复制一份。
struct QingliaoActivityAttributes: ActivityAttributes {

    /// 动态数据：可随 `Activity.update` 变化
    struct ContentState: Codable, Hashable {
        /// 会话标题（空则挂件显示「轻聊」）
        var sessionTitle: String
        /// 当前模型名（展示用）
        var modelName: String
        /// 本轮开始时间——展开态用 `Text(_:style: .timer)` 让**系统**自走计时，
        /// App 被挂起也照走（免费签名没有推送更新，这是唯一能保证进度不僵死的办法）
        var startedAt: Date
        /// 是否仍在回复中（false = 已完成，用于收起前的最终态）
        var isAnswering: Bool
    }

    /// 静态数据：创建后不变
    var sessionId: String
}
