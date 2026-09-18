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
        /// v3.9.30：失败（保留 2s 展示红球+「生成失败」，再收起——此前失败时岛上无感知，
        /// 用户以为还在跑，回 App 才发现早已报错）
        case failed
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
        /// v3.9.13：**累计不确定态相位**（每拍 +0.125，**不回绕**）。
        /// 为什么需要它：实时活动**没有连续自走的帧源**（Apple 明文：视图只在数据更新时重绘），
        /// 所以「球上旋转弧 / 环上脉冲」一直在动只能靠 App 侧每拍 `update` 推进一个相位量。
        /// progress 会在 0.86 封顶（不能假装总长），此时若只靠它，画面就彻底静止了——
        /// 用户报的「动几下就不动了」正是这个；spin 到顶后仍每拍前进，弧因此持续转。
        /// **必须是累计值而非 0…1 循环值**（子代理静态审查抓到）：取模回绕会让弧角度
        /// 从 315° 插值回 0°，每轮（约 9.6s）倒着急扫一圈，与「一直在转」相反。
        /// 挂件要 0…1 的地方自己取余（如脉冲相位）。
        var spin: Double
        /// v3.9.37：**当前拍间隔（秒）**——App 侧推手的节奏（起步 `OrbBeat.fast`，长回答后 `OrbBeat.slow`）。
        /// 为什么必须下发给挂件：挂件的过渡时长要「略短于拍间隔」才不会在两拍之间留静止段。
        /// 原来挂件写死 1.1s，而长回答（>36s）后 App 侧放慢到 2.5s 一拍 → 每拍有约 1.4s
        /// 完全静止（用户报的「灵动岛动画还是会断」＝这个顿挫）。
        /// 现在两侧共用同一个数：过渡 = `OrbBeat.duration(拍)`（>2s 的过渡 Apple 侧不保证播完）。
        var beatSeconds: Double

        init(sessionTitle: String, modelName: String, startedAt: Date, isAnswering: Bool,
             phase: String = QingliaoActivityAttributes.Phase.thinking.rawValue,
             actionText: String = "", canStop: Bool = false,
             progress: Double = 0.18, spin: Double = 0, beatSeconds: Double = OrbBeat.fast) {
            self.sessionTitle = sessionTitle
            self.modelName = modelName
            self.startedAt = startedAt
            self.isAnswering = isAnswering
            self.phase = phase
            self.actionText = actionText
            self.canStop = canStop
            self.progress = progress
            self.spin = spin
            self.beatSeconds = beatSeconds
        }

        private enum CodingKeys: String, CodingKey {
            case sessionTitle, modelName, startedAt, isAnswering, phase, actionText, canStop,
                 progress, spin, beatSeconds
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
            // v3.9.13：新增字段同样必须 decodeIfPresent——系统里留着的旧版活动缺这个键，
            // 合成解码会抛 keyNotFound 导致灵动岛整块空白（v3.9.7 加 phase 时踩过同一个坑）
            spin = try c.decodeIfPresent(Double.self, forKey: .spin) ?? 0
            // v3.9.37：旧活动缺这个键 → 按 1.2s 一拍渲染（= 与新推手起步节奏一致，不会跳变）
            beatSeconds = try c.decodeIfPresent(Double.self, forKey: .beatSeconds) ?? OrbBeat.fast
        }
    }

    /// 静态数据：创建后不变
    var sessionId: String
}


/// 实时活动「拍间隔（App 侧推手节奏）→ 挂件过渡时长」的**唯一真源**。
///
/// 为什么放在这个文件：主 App 与挂件**共编同一份源码**（project.yml 的 widget sources），
/// 而节奏这个数两侧都必须用同一个——过渡略短于拍间隔，两拍之间才不会留静止段
/// （留静止段就是用户报的「灵动岛动画还是会断」）。这套数字以前散在 4 处
/// （App 侧 fastBeat/slowBeat、ContentState init 默认值、解码兜底、挂件 OrbView 默认值），
/// 改一处别处不知道 → 静默回归。现在只有这里一份，其余全部引用它。
///
/// ⚠️ **不变量：`slow - leadIn ≤ cap`**（慢档的过渡也必须落在 Apple 的 2s 上限内兜得住）。
/// 真值表 `scripts/qingliao_island/truth_table_progress.swift` 钉住了这条与「换档那一拍」的口径。
enum OrbBeat {
    /// 起步节奏：前 30 拍（约 36s）一拍。= 挂件过渡 1.12s，两拍之间只留 0.08s 缝。
    static let fast: Double = 1.2
    /// 长回答后的省电档。**别再回 2.5**：今天的过渡上限是 `cap` = 1.95s（随本档一起引入），
    /// 2.5 − 1.95 = 0.55s 静止段会每拍出现一次。（本次事故的真实根因是更早那版
    /// 「拍 2.5s + 挂件写死过渡 1.1s = 每拍静止 1.4s」。）
    static let slow: Double = 2.0
    /// 过渡比拍间隔早收尾这么多（给相邻两段动画留缝，避免首尾相压）。
    static let leadIn: Double = 0.08
    /// Apple 口径：实时活动里的动画最长 2s，超了不保证播完 → 上限取 1.95s。
    static let cap: Double = 1.95
    /// 下限：拍间隔被写成异常小值时，别让过渡退化成瞬跳。
    static let floor: Double = 0.45

    /// 数值换算（本文件刻意不 import SwiftUI；挂件的 `animation(_:)` 只是它外面包一层）。
    static func duration(_ beat: Double) -> Double {
        min(cap, max(floor, beat - leadIn))
    }
}
