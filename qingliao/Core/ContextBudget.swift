//
//  ContextBudget.swift
//  轻聊
//
//  v4.0.154：上下文压缩按「体量」而不是「条数」决定保留多少（纯函数，可真值表测）。
//
//  🚨 为什么必须按体量（2026-10-24 用户实报「手动压缩上下文失效」）：
//     原实现写死「保留最近 20 条」。而用户的会话恰好 20 条、其中**一条 AI 回复就有 13 万字**
//     （14.3 万字 / 3.6 万 tokens）→ ① 条数不满足 `count > keepLast + 1`，压缩直接静默返回 false，
//     用户点了没有任何反应；② 即便有 30 条，压完还是十几万字，体感上等于没压。
//     条数是「消息个头均匀」时代的代理指标，对「少数超长回复」完全失效 → 改成按字符预算累计。
//
//  口径：从最新一条往前累加字符数，累计超过 budget 就停（至少保留 minKeep 条，
//        防止「最后一条本身超预算」时把会话压成空）。
//

import Foundation

enum ContextBudget {
    /// 手动压缩的默认字符预算（约 2500 tokens，中文）。
    /// 取值理由：留足最近几轮对话的原文可读性，同时把「十几万字」这种量级直接压到 1/10 以下。
    static let defaultCharacterBudget = 10_000

    /// 至少保留的条数（预算再小也留最近这几条，保证「接着聊」有上下文）。
    static let minKeep = 2

    /// 从最新往前按预算累计，返回应当保留的条数（∈ [minKeep, count]）。
    ///
    /// - Parameters:
    ///   - charCounts: 每条消息的字符数（**顺序与 messages 一致**，从旧到新）
    ///   - budget: 字符预算
    ///   - minKeep: 至少保留条数（≤ 0 时按 1 处理；大于总数时按总数处理）
    /// - Returns: 应保留的条数；空数组返回 0
    static func keepCount(charCounts: [Int], budget: Int, minKeep: Int = ContextBudget.minKeep) -> Int {
        let total = charCounts.count
        if total == 0 { return 0 }
        let floorKeep = Swift.min(Swift.max(1, minKeep), total)
        var kept = 0
        var sum = 0
        for i in stride(from: total - 1, through: 0, by: -1) {
            let c = Swift.max(0, charCounts[i])
            // 已经保够下限、再加这一条就超预算 → 到此为止（更早的一律归入摘要）
            if kept >= floorKeep && sum + c > budget { break }
            sum += c
            kept += 1
        }
        return Swift.max(kept, floorKeep)
    }
}
