import Foundation

/// 待做池⑨「会话分享卡片美化（长图版）」的**纯逻辑真源**（不 import UIKit/SwiftUI → 可脱壳单测）。
///
/// 用户已拍板两条口径：① **长图**（不是多页分页卡片）② **用新的 App logo**（仓内 `AboutLogo` 资产）。
///
/// 口径（全部收在这一处，View 只做接线）：
///  · 长图须有**明确上限**（条数 + 估算高度），超限**从最早端整条丢**（绝不切断单条消息），
///    并出**尾注**告知了被省略的条数 —— 不静默丢；
///  · 至少保留**最新 1 条**（哪怕它本身超高：宁可图略长，也不出空卡/切消息）；
///  · 高度估算与渲染共用同一组常量（卡片宽 / 气泡内边距 / 行高 / 行距），改一处两边同步。
///
/// ⚠️ 为什么把「上限与截断」收进纯逻辑：本机无 iOS SDK（只有 `swiftc -parse`，不做类型检查），
/// 「超长会话把 ImageRenderer 一次渲染爆内存 / 尾注漏出 / 切了半条消息」这类缺陷本地查不出、真机才炸，
/// 故用真值表（scripts/ql_sessioncard/）真跑本文件把口径钉死。
enum SessionCardKit {

    /// 卡片里的一行 = 一条消息的忠实呈现（role 与 ChatMessage.role 同源）
    struct CardRow: Equatable {
        var role: String
        var text: String
        init(role: String, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// 截断计划：rows = 实际渲染的行（时间序，最新在尾）；omitted = 从最早端丢掉的条数
    struct Plan: Equatable {
        var rows: [CardRow]
        var omitted: Int
        var truncated: Bool { omitted > 0 }
        init(rows: [CardRow], omitted: Int) {
            self.rows = rows
            self.omitted = omitted
        }
    }

    // MARK: - 口径常量（View 与估算共用，单一真源）

    /// 长图版心宽（pt）。旧 340 定宽 → 长图略加宽，正文更好读
    static let cardWidth: Double = 400
    /// 卡片左右/上下内边距（pt）
    static let hPadding: Double = 20
    /// 气泡最大宽度占内容宽的比例
    static let bubbleWidthRatio: Double = 0.78
    /// 气泡内边距（pt）
    static let bubbleHPad: Double = 12
    static let bubbleVPad: Double = 10
    /// 正文字号 / 行高（pt）——与 View 里 `.font(size:)` 同源
    static let bodyFont: Double = 15
    static let lineHeight: Double = 22
    /// 行与行之间间距（pt）
    static let rowSpacing: Double = 10
    /// 标题栏 + 尾注 + 上下内边距的估算固定高度（pt）
    static let chromeHeight: Double = 132

    /// 上限①：条数上限
    static let maxRows = 80
    /// 上限②：估算高度上限（pt；×@3x 后 ≈ 16500px，防 ImageRenderer 一次性渲染爆内存）
    static let maxHeight: Double = 5500

    /// 每行可容纳的字符数估算（CJK 每字 ≈ avgCharWidth）
    static let avgCharWidth: Double = 16
    /// 内容宽（气泡外框）
    static var contentWidth: Double { cardWidth - hPadding * 2 }
    /// 气泡最大宽
    static var bubbleMaxWidth: Double { contentWidth * bubbleWidthRatio }
    /// 气泡内文字可用宽
    static var textWidth: Double { bubbleMaxWidth - bubbleHPad * 2 }
    /// 每行字数
    static var charsPerLine: Int { max(1, Int(textWidth / avgCharWidth)) }
    /// 行内对侧留白（行总宽 = gutter + bubbleMaxWidth = 内容宽；固定值 → 渲染确定、可估算）
    static var gutter: Double { contentWidth - bubbleMaxWidth }

    // MARK: - 纯逻辑

    /// 文本占几行（按换行分段，每段按字数估算，至少 1 行）
    static func lineCount(_ text: String) -> Int {
        let per = charsPerLine
        var lines = 0
        for para in text.components(separatedBy: "\n") {
            let n = max(1, (para.count + per - 1) / per)
            lines += n
        }
        return max(1, lines)
    }

    /// 单行估算高度（pt）
    static func rowHeight(_ row: CardRow) -> Double {
        Double(lineCount(row.text)) * lineHeight + bubbleVPad * 2 + rowSpacing
    }

    /// 生成截断计划：从最新端往前累计，直到触到条数/高度上限；绝不切断单条消息。
    static func layout(_ rows: [CardRow]) -> Plan {
        if rows.isEmpty { return Plan(rows: [], omitted: 0) }
        var kept: [CardRow] = []
        var h: Double = 0
        for row in rows.reversed() {
            if kept.count >= maxRows { break }
            let rh = rowHeight(row)
            // 始终至少保留 1 条（最新）；之后超出高度上限即停（丢的是更早的整条）
            if !kept.isEmpty && (chromeHeight + h + rh > maxHeight) { break }
            h += rh
            kept.append(row)
        }
        return Plan(rows: Array(kept.reversed()), omitted: rows.count - kept.count)
    }

    /// 超限尾注文案（不给 omit 为 0 的情况 —— 那种情况 View 不渲染尾注）
    static func footerNote(omitted: Int, shown: Int) -> String {
        "已省略更早的 \(omitted) 条消息 · 仅显示最近 \(shown) 条"
    }
}
