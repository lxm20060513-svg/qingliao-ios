import Foundation

/// v4.0.44 待做池 3「改口重答」的纯逻辑层（**无 SwiftUI / 无 ChatMessage 依赖**，可单测）。
///
/// 为什么单独抽一层：口径（「哪条能改」「改完折叠哪几条」）是**产品判定**，不是 UI 细节。
/// 散在 ChatView（决定菜单里有没有「编辑」）和 ChatStore（决定折叠谁）两处必然漂移——
/// 一边放行一边拒绝的典型症状就是「长按有『编辑』，点完没反应」。这里收成一份纯函数：
/// UI 只问「这条能不能改」，Store 只按返回值折叠。
///
/// 用户 2026-10-04 卡片拍板（两项都是选项 1）：
///   ① 被取代的旧回答 → 复用现有灰气泡（与「撤回」同款，最省事）
///   ② 只允许改**最后一条** user 消息（改动面最小：只牵连这一轮）
enum MessageEditKit {

    /// 折叠后的灰气泡文案（与「已撤回」同款灰底，靠文案区分语义）
    static let editedLabel = "已修改"

    /// 一条消息的最小特征（从 ChatMessage 摘出来，避免纯逻辑层依赖 SwiftUI 模型）
    struct Row: Equatable {
        var role: String
        var withdrawn: Bool
        var failed: Bool
        var isPush: Bool
        var isQuestion: Bool
        var edited: Bool
        /// v4.0.47：还在队列里没真正发出去的消息（AI 回答中发送的）。不能改：
        /// 改了屏上那条，队列里仍是旧文，sendQueued 按 `content == item.text` 匹配不到 → 静默丢弃。
        var queued: Bool = false

        init(role: String, withdrawn: Bool = false, failed: Bool = false,
             isPush: Bool = false, isQuestion: Bool = false, edited: Bool = false,
             queued: Bool = false) {
            self.role = role
            self.withdrawn = withdrawn
            self.failed = failed
            self.isPush = isPush
            self.isQuestion = isQuestion
            self.edited = edited
            self.queued = queued
        }
    }

    /// 可编辑的消息下标（nil = 本轮无可改）。
    ///
    /// 口径＝**最后一条 user 消息**，且它本身是「干净的用户消息」：
    ///   · 非 user（AI 回答不能改——用户没打过这段字）
    ///   · 已撤回（内容已不存在，落库时正文就是空的）
    ///   · 发送失败（那种消息的入口是「重试」，不是「编辑」）
    ///   · 推送（不是用户发的）
    ///   · 问题卡（那是待作答的交互件）
    ///   · 已折叠（本身已是「已修改」陈列态）
    ///   · 排队中（还没真的发出去；改了口令队列按旧文匹配，那条排队消息会被静默丢弃）
    static func editableIndex(_ rows: [Row]) -> Int? {
        guard let i = rows.lastIndex(where: { $0.role == "user" }) else { return nil }
        let r = rows[i]
        guard !r.withdrawn, !r.failed, !r.isPush, !r.isQuestion, !r.edited, !r.queued else { return nil }
        return i
    }

    /// 需要折叠为「已修改」的旧回答下标：锚点 user 消息**之后**、role=assistant、
    /// 非推送、未折叠、未撤回。
    ///
    /// 问题卡刻意**不折叠**：它是等用户点选的交互件（折叠掉 = 用户答不了、后端长轮询干等到超时），
    /// 不属于「一条被取代的旧回答」。
    static func foldTargets(_ rows: [Row], afterUserIndex i: Int) -> [Int] {
        guard rows.indices.contains(i), rows[i].role == "user" else { return [] }
        return rows.indices.filter { j in
            j > i
                && rows[j].role == "assistant"
                && !rows[j].isPush
                && !rows[j].isQuestion
                && !rows[j].edited
                && !rows[j].withdrawn
        }
    }
}
