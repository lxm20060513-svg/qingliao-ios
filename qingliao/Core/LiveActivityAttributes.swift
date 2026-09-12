import ActivityKit
import Foundation

/// 灵动岛 / 锁屏「实时活动」的共享数据模型（v3.8.0）。
///
/// ⚠️ 本文件**同时编入主 App 与挂件 Extension 两个 target**（project.yml 里都引用了它）——
/// 实时活动的属性类型必须两侧完全一致，改这里等于同时改两侧，别各自复制一份。
struct QingliaoActivityAttributes: ActivityAttributes {

    /// v3.9.7：回复阶段——驱动灵动岛三态（同一份字符串主 App / 挂件共用，别各处硬编码）
    enum Phase: String {
        /// 已发出、首个字符还没到
        case thinking
        /// 正在流式输出
        case streaming
        /// 已结束（保留 2s 展示「已完成」，再收起）
        case done
    }

    /// 动态数据：可随 `Activity.update` 变化
    struct ContentState: Codable, Hashable {
        /// 会话标题（空则挂件显示「轻聊」）
        var sessionTitle: String
        /// 当前模型名（展示用）
        var modelName: String
        /// 本轮开始时间。v3.9.9 起用户要求**不显示计时**，展开态/锁屏都不再走秒；
        /// 字段保留：完成态/后续形态与「同会话续更不重启」的判定仍要用它。
        var startedAt: Date
        /// 是否仍在回复中（false = 已完成，用于收起前的最终态）
        var isAnswering: Bool
        /// v3.9.7：阶段（thinking / streaming / done）——见 `Phase`
        var phase: String
        /// v3.9.7：状态行文案，空则不显示。**只写能确证的内容，不虚构工具名**
        var actionText: String
        /// v3.9.7：当前这轮是否**真能被按钮停掉**（只有本地流可以——云端流没有停止接口，
        /// 与聊天页输入栏「停止」按钮同口径：`stream.isStreaming` 才出现停止）。
        /// 挂件据此决定要不要显示「停止生成」：不可停就别显示，避免出现一个点了没反应的按钮。
        var canStop: Bool
        /// v3.9.10：**本轮推进度**（0…1），不是「总进度承诺」——流式回答没有真实总长。
        /// 由 `LiveActivityManager` 按节奏推进（思考 0.18 → 开始生成 0.35 → 逐步逼近 0.86，
        /// 只有真结束才落 1.0）。挂件的环据此持续往前长，用户看到「在动」。
        var progress: Double

        init(sessionTitle: String, modelName: String, startedAt: Date, isAnswering: Bool,
             phase: String = QingliaoActivityAttributes.Phase.thinking.rawValue,
             actionText: String = "", canStop: Bool = false,
             progress: Double = 0.18) {
            self.sessionTitle = sessionTitle
            self.modelName = modelName
            self.startedAt = startedAt
            self.isAnswering = isAnswering
            self.phase = phase
            self.actionText = actionText
            self.canStop = canStop
            self.progress = progress
        }

        private enum CodingKeys: String, CodingKey {
            case sessionTitle, modelName, startedAt, isAnswering, phase, actionText, canStop, progress
        }

        /// v3.9.7：手写解码。
        /// Codable 的合成解码**不会**使用属性默认值——升级后若系统里还留着旧版本创建的活动
        /// （缺 phase/actionText/canStop 这些新键），合成解码会直接抛 keyNotFound，灵动岛变空白。
        /// 这里逐个 `decodeIfPresent` 兜底，缺字段按「思考中」渲染。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionTitle = try c.decodeIfPresent(String.self, forKey: .sessionTitle) ?? "轻聊"
            modelName = try c.decodeIfPresent(String.self, forKey: .modelName) ?? "AI"
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
            isAnswering = try c.decodeIfPresent(Bool.self, forKey: .isAnswering) ?? true
            phase = try c.decodeIfPresent(String.self, forKey: .phase)
                ?? QingliaoActivityAttributes.Phase.thinking.rawValue
            actionText = try c.decodeIfPresent(String.self, forKey: .actionText) ?? ""
            canStop = try c.decodeIfPresent(Bool.self, forKey: .canStop) ?? false
            // 旧活动没有这个键 → 按「思考中」的初始值渲染，而不是 0（0 会让环看上去空掉）
            progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0.18
        }
    }

    /// 静态数据：创建后不变
    var sessionId: String
}
