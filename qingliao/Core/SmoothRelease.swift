// MARK: - 流式打字机「平滑释放」推进算法（v4.0.23）
//
// 从 StreamClient.startSmooth 的 48ms tick 循环里抽出的**纯算法**，只为可单测。
//
// 为什么要有这个文件（事故背景）：
//   v3.4.20 引入平滑层时，推进写成了「在自己的副本上切片」——
//       let s = self.smoothedContent
//       let idx = s.index(s.startIndex, offsetBy: min(step, backlog), limitedBy: s.endIndex) ?? s.endIndex
//       self.smoothedContent = String(s[..<idx])
//   空串起步时 index(_:offsetBy:limitedBy:) 恒返回 nil → 落到 `?? s.endIndex` → 每 tick 都切出空串：
//   smoothedContent 永远停在 ""。于是 displayContent（smoothTask 非空时 = smoothedContent）在**整个流式期间为空**：
//   聊天页那口气泡从「思考三点」被换成 streamingBubble 后什么都没有（空气泡），
//   只有收尾 stopSmooth 才一次性补齐全文（观感 = 整段蹦出）。
//   真机表现就是用户 2026-10-02 报的：「工具调用一出来，思考气泡动画就会消失」
//   —— Agent 先有中间文本、气泡早早切成空泡，而工具阶段长达几十秒，空气泡特别显眼。
//
// 口径：本函数只回答「这一 tick 该显示到第几个字符」，取前缀交给调用方（String(content.prefix(n))）。
//   · 起步（0）每 tick 1 字：首字必现，不会再出现"永远空"。
//   · 积压越多释放越快（>20 字 2/tick，>60 字 4/tick）：追赶下游轮询增量，不掉队。
//   · 收敛：恒 <= contentCount，绝不越界；追平后原样返回。
//   · 只依赖 Int，不碰 String 内部索引 —— 上次正是索引语义写错才静默失效。
enum SmoothRelease {
    /// 单 tick 释放步长（按积压分级）
    static func step(backlog: Int) -> Int {
        backlog > 60 ? 4 : (backlog > 20 ? 2 : 1)
    }

    /// 本 tick 应显示的前缀长度（字符口径，与 String.count 一致）
    static func nextLength(smoothedCount: Int, contentCount: Int) -> Int {
        guard smoothedCount < contentCount else { return smoothedCount }
        let backlog = contentCount - smoothedCount
        return min(smoothedCount + step(backlog: backlog), contentCount)
    }
}
