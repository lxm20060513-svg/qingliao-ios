import Foundation

/// 待做池⑥：弱网/多会话「排队消息」的**队列总览**口径（纯逻辑，真值表主对象）。
///
/// 真缺口：排队消息此前只在气泡上顶一枚「排队中」角标 —— 用户看不到队列全貌，
/// 也不知道「在等什么、排第几」。本文件把 `pendingQueue` 转成带序号的展示行 +
/// 顶部摘要，视图层（`SendQueueBar`）只负责画。
///
/// 纯 Foundation（不 import SwiftUI），真值表可**直接编译**验证，与 `ResumeInfo` 同套做法。
enum SendQueueOverview {

    /// 单条排队消息的展示行。`position` 从 1 起、**只统计属于该会话**的条目。
    struct Row: Equatable, Identifiable {
        /// 稳定 id（纯函数可复现，无 UUID 依赖）：`序号@文本`。
        let id: String
        let position: Int
        let text: String
        let hasImage: Bool
    }

    /// 当前会话的排队条目 → 带序号的展示行。
    /// - 只取 `belongs(to: sessionId)` 的条目（别的会话的仍留在队列里，但不进本会话总览）。
    /// - 空文本且无图 → 跳过（不产生空白行，序号也不会被它占掉）。
    /// - 文本截断到 `maxLen`（默认 40）并补「…」；纯图片条目显示占位「[图片]」。
    static func rows(_ queue: [PendingSend], sessionId: String?, maxLen: Int = 40) -> [Row] {
        var out: [Row] = []
        var pos = 0
        for item in queue where item.belongs(to: sessionId) {
            let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasImage = !((item.imageData ?? "").isEmpty)
            if t.isEmpty && !hasImage { continue }
            pos += 1
            let label = t.isEmpty ? "[图片]" : clip(t, maxLen)
            out.append(Row(id: "\(pos)@\(label)", position: pos, text: label, hasImage: hasImage))
        }
        return out
    }

    /// 顶部摘要：还有几条待发、按什么次序走。空队列 → nil（整条不渲染）。
    static func summary(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        if count == 1 { return "还有 1 条待发 · 当前回答结束后自动发送" }
        return "还有 \(count) 条待发 · 依次等前面发完"
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        guard n > 0, s.count > n else { return s }
        return String(s.prefix(n)) + "…"
    }
}
