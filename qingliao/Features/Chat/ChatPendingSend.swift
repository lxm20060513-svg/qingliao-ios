import Foundation

/// v2.0.88：排队待发消息（AI 回答中发送，当前回答结束后自动逐条发送）
struct PendingSend: Codable, Equatable {
    let text: String
    let imageData: String?
    /// v3.9.41（SR60）：入队时的会话。原队列是「无主」的，重启后恢复的第 2..n 条会等不到派发：
    /// 派发点要么在无脑拿队首（拿错会话 → 上屏找不到排队行 → 静默丢弃），
    /// 要么被切会话的 clearPendingQueue 一把清掉（盘上那份在恢复时已被删除）→ 消息永久消失。
    /// 可选类型：老版本落盘的 JSON 没这个键，`decodeIfPresent` 解成 nil，按「当前会话」处理。
    var sessionId: String? = nil
    /// v3.9.41（SR60）：由启动恢复读上来的条目标记。派发时用它区分两种匹配口径：
    /// 会话内新排队的条目一定能按 `queued` 行匹配上；恢复出来的条目不能（queued 不落盘），
    /// 需要按内容回捞历史行。只有恢复条目允许回捞，才不至于把「用户已删除的那条」也复活。
    var fromRestore: Bool = false

    /// 是否属于某个会话（nil = 旧数据，无从判断，按当前会话对待）
    func belongs(to sid: String?) -> Bool { sessionId == nil || sessionId == sid }

    /// v3.9.41（SR60）：显式列出键——①老版本（无 sessionId）落盘的 JSON 缺键必须仍能解出，
    /// 否则整份队列 `try?` 解失败 = 恢复直接归零；②fromRestore 只是本次运行内的标记，不参与持久化。
    enum CodingKeys: String, CodingKey {
        case text, imageData, sessionId
    }
}
