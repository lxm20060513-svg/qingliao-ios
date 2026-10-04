// 待做池⑨「会话分享卡片美化（长图版）」真值表 —— Linux 本地预检用（权威入口 = check_swift.sh 第 81 段）
//
// 编译运行（在仓库根目录）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_sessioncard \
//       scripts/ql_sessioncard/truth_table_sessioncard.swift qingliao/Core/SessionCardKit.swift
//
// 本表钉死的口径（与台账护栏一一对应）：
//   · 长图有**明确条数/高度上限**，超限**从最早端整条丢**并出尾注（不静默丢、不切单条）（A 段）
//   · 至少保留最新 1 条（哪怕本身超高，也不出空卡 / 不切消息）（A 段）
//   · 时间序保持不变、条与条之间不重排（A 段）
//   · 空会话 → 空计划 / 不截断（B 段反例）
//   · 渲染口径常量（版心宽 / 气泡宽 / 行宽自洽 / 每行字数）与估算同源（C 段）
//   · 源级接线：整会话渲染 / scale=3 不降档 / logo 同源 / 旧 SF Symbol 清零 / 尾注接线（D 段）
//
// A/B/C 段**真编译真跑** Core/SessionCardKit.swift（与实现同一份文件 → 无「表/实现漂移」洞）；
// D 段为源级断言（剥注释），钉接线在源码里真实存在。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func ok(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}
func pos(_ name: String, _ cond: Bool) { positives += 1; ok(name, cond) }
func neg(_ name: String, _ cond: Bool) { negatives += 1; ok(name, cond) }

/// 整行剥注释（不按行内 `//` 剥：Swift 里有 `http://` 之类字面量会被截断）
func stripComments(_ s: String) -> String {
    s.components(separatedBy: "\n").map { line -> String in
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("//") ? "" : line
    }.joined(separator: "\n")
}
func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

@main
enum SessionCardTruthTable {

    static func main() {
        let K = SessionCardKit.self

        func short(_ n: Int) -> [SessionCardKit.CardRow] {
            (0..<n).map { SessionCardKit.CardRow(role: $0 % 2 == 0 ? "user" : "assistant",
                                                  text: "短消息\($0)") }
        }
        // 60 字无换行 → 4 行 → 高 4*22+20+10 = 118pt
        func long(_ n: Int) -> [SessionCardKit.CardRow] {
            let body = String(repeating: "字", count: 60)
            return (0..<n).map { SessionCardKit.CardRow(role: "assistant", text: body + "END\($0)") }
        }

        // ---- A 段：上限与截断口径 ----
        pos("A1 行高估算 = 行数*行高 + 上下内边距 + 行距",
            abs(K.rowHeight(SessionCardKit.CardRow(role: "user", text: "单行")) - (K.lineHeight + K.bubbleVPad * 2 + K.rowSpacing)) < 0.001)
        pos("A2 换行按段计行（a\\nb → 2 行）", K.lineCount("a\nb") == 2)

        let plan80 = K.layout(short(100))
        pos("A3 超条数上限 → 保留最新 \(K.maxRows) 条", plan80.rows.count == K.maxRows)
        pos("A4 被丢条数 = 总数 - 保留数（不静默丢）", plan80.omitted == 100 - K.maxRows)
        pos("A5 截断标志置位", plan80.truncated)
        pos("A6 丢的是**最早**那批（保留段首条 = 源[omitted]）", plan80.rows.first == short(100)[plan80.omitted])
        pos("A7 最新一条恒在末尾（时间序不变）", plan80.rows.last == short(100).last)
        pos("A8 保留段严格等于源对应切片（不重排、不切单条）",
            plan80.rows == Array(short(100).suffix(K.maxRows)))

        let planH = K.layout(long(60))
        pos("A9 高度上限生效（60 行长消息 → 少于 60 条）", planH.rows.count < 60 && planH.rows.count > 0)
        pos("A10 高度上限下也保留最新段", planH.rows.last == long(60).last)
        pos("A11 长消息文本**整条保留**（末尾 END 标记在，未被截断）",
            planH.rows.first?.text.hasSuffix("END\(planH.omitted)") == true)
        pos("A12 高度上限下 omitted 自洽", planH.omitted == 60 - planH.rows.count)

        let giant = [SessionCardKit.CardRow(role: "assistant", text: String(repeating: "超", count: 5000))]
        let planG = K.layout(giant)
        pos("A13 单条超高也**至少保留 1 条**（不出空卡）", planG.rows.count == 1 && planG.omitted == 0)
        pos("A14 超高单条文本不被切断", planG.rows.first == giant[0])

        // ---- B 段：不截断 / 空的边界 ----
        let three = short(3)
        let plan3 = K.layout(three)
        pos("B1 未超限 → 原样全保留", plan3.rows == three && plan3.omitted == 0)
        neg("B2 未超限 → 截断标志必须为假（不乱出尾注）", !plan3.truncated)

        let empty = K.layout([])
        neg("B3 空会话 → 不截断", !empty.truncated)
        pos("B4 空会话 → 空计划", empty.rows.isEmpty && empty.omitted == 0)

        // ---- C 段：渲染口径常量自洽 ----
        pos("C1 版心宽加宽到 400", K.cardWidth == 400)
        pos("C2 行宽自洽：gutter + 气泡最大宽 = 内容宽", abs(K.gutter + K.bubbleMaxWidth - K.contentWidth) < 0.001)
        pos("C3 气泡 < 内容宽（留出对侧留白）", K.bubbleMaxWidth < K.contentWidth && K.gutter > 0)
        pos("C4 每行字数与 (气泡内宽/字宽) 同源", K.charsPerLine == 16)
        pos("C5 尾注含被省略条数与显示条数",
            K.footerNote(omitted: 7, shown: 80).contains("7") && K.footerNote(omitted: 7, shown: 80).contains("80"))

        // ---- D 段：源级接线（剥注释后断言真实存在）----
        let exportSrc = stripComments(read("qingliao/Features/Chat/ChatViewExport.swift"))
        pos("D1 长图 = 整会话渲染（不再 suffix(15)）", exportSrc.contains("chat.messages.map { cardRow(for: $0) }"))
        neg("D2 旧的「最近 15 条」窗口已清零", !exportSrc.contains("suffix(15)"))
        pos("D3 行类型换成 SessionCardKit.CardRow", exportSrc.contains("-> SessionCardKit.CardRow"))
        pos("D4 @3x 高清不降档（shareSessionCard）", exportSrc.contains("renderer.scale = 3"))

        let card = stripComments(read("qingliao/Features/Chat/ChatComponents.swift"))
        pos("D5 标题栏用新 logo（Image(\"AboutLogo\") 同源资产）", card.contains("Image(\"AboutLogo\")"))
        neg("D6 旧 SF Symbol 图标已清零", !card.contains("bubble.left.and.bubble.right.fill"))
        pos("D7 卡片走 Kit 的截断计划", card.contains("SessionCardKit.layout(rows)"))
        pos("D8 超限渲染尾注（plan.truncated 分支）", card.contains("if plan.truncated"))
        pos("D9 尾注文案来自 Kit（单一真源）", card.contains("SessionCardKit.footerNote(omitted:"))
        pos("D10 版心宽取 Kit 常量", card.contains("width: CGFloat(SessionCardKit.cardWidth)"))
        pos("D11 微信式左右分栏（按 role 分左右/配色）", card.contains("let isUser = row.role == \"user\""))
        pos("D12 行宽用固定 gutter（与估算同源，不靠 Spacer 分配）", card.contains("SessionCardKit.gutter"))

        let kit = stripComments(read("qingliao/Core/SessionCardKit.swift"))
        neg("D13 Kit 保持纯 Foundation（不 import SwiftUI/UIKit）",
            !kit.contains("import SwiftUI") && !kit.contains("import UIKit"))
        pos("D14 上限是显式常量（条数 + 高度）", kit.contains("static let maxRows") && kit.contains("static let maxHeight"))

        print("----")
        print("正例 \(positives) / 反例 \(negatives) / \(failures) 失败")
        if failures > 0 { exit(1) }
    }
}
