//
//  PickupCodeKit.swift
//  轻聊
//
//  v4.0.93：聊天首页「取件码」卡的**纯逻辑**（无 SwiftUI / UIKit 依赖）——从待办正文里摘取件码。
//
//  为什么单独一个文件：本仓规矩「任何新写的纯计算函数先落真值表编译跑一遍再推 CI」
//  （scripts/ql_chat_home/truth_table_homecards.swift §⑬），而真值表只能用 swiftc 编译单文件，
//  混进 SwiftUI 依赖就编不过。
//
//  链路（v4.0.92 已打通）：收到取件码短信 → iOS 快捷指令「记到轻聊待办」→ 待办里一行
//  「取件码 A1234 · 丰巢 · 3号柜」；本文件把这行里的**码**摘出来，首页取件码卡与取件码弹窗
//  共用同一份口径（数据源 = 本地 TodoStore，零后端改动）。
//
//  🚨 唯一口径：**只从原文里摘，不猜不补**。
//     解不出 → 这条待办不算取件码条目（卡面不认它）。宁可卡空着，也不许编一个码 ——
//     错的取件码会让用户白跑一趟快递柜，代价远大于「这张卡暂时空着」。
//
//  认码三步（全部可测）：
//    ① 正文压成一行（换行/制表 → 空格，连续空白合一）；
//    ② 找「取件码」锚点，从它之后跳过说明字/分隔符/空白，取第一段连续 [A-Za-z0-9-]：
//       长度 3...20 才算码（短于 3 = 被截断的碎词；长于 20 = 快递单号/手机号，都不认）；
//    ③ 码之后按「· / ｜ / | / ／」切段（= 提炼格式的分隔符），每段 ≤ 12 字、最多 2 段 → 详情
//       （A1234 · 丰巢 · 3号柜 → 详情「丰巢 · 3号柜」）。
//       ⚠️ 不做同义词扩展、不认逗号句尾：短信原文那种「取件码 123456 请及时取件」里，
//          「请及时取件」既不是公司也不是地点 —— **没有分隔符就只显示码**，不把整句当详情。
//

import Foundation

/// 一条待办解出来的取件码（值类型：卡面 / 弹窗 / 真值表共用同一份）
struct PickupCode: Equatable, Identifiable {
    /// 来源待办 id —— 弹窗的「已取件」要拿它回 TodoStore 勾掉那一条
    let todoId: String
    /// 取件码本身（恒为原文子串，绝不拼接/补位）
    let code: String
    /// 详情（快递公司 · 地点；提炼格式才有，取不到是空串）
    let detail: String
    /// 原文一行（已截断）—— 详情为空时卡面/弹窗退回显示它
    let rawLine: String

    var id: String { todoId }

    /// 副行口径：详情优先，没有就退回原文一行（两者都空 → 空串）
    var subLine: String { detail.isEmpty ? rawLine : detail }
}

/// 取件码解析（纯函数，无状态）
enum PickupCodeKit {
    /// 锚点关键词：只在「取件码」三字上认（短信原文必现此词；扩同义词只会把无关待办误判成取件码）
    static let keyword = "取件码"
    /// 码长上下限
    static let codeMin = 3
    static let codeMax = 20
    /// 详情每段字数上限（公司/地点都很短；整句会超 → 详情只可能来自提炼格式）
    static let detailMaxChars = 12
    /// 详情最多几段
    static let detailSegments = 2
    /// 一行正文的展示上限（卡面/弹窗恒单行）
    static let lineLimit = 40

    // MARK: - 基础

    /// 正文压成一行：换行/制表 → 空格，连续空白合一
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 单行截断（超长加「…」）—— 卡面恒单行口径；超长加省略号的观感与 HomeCardTipKit.ellipsisLine 一致
    /// （本函数输入的正文已压成一行，两者结果相同，故不再调它、避免第二份实现漂移）
    static func ellipsis(_ text: String, max: Int = lineLimit) -> String {
        let line = oneLine(text)
        return line.count > max ? String(line.prefix(max)) + "…" : line
    }

    /// 码字符：ASCII 字母 / 数字 / 连字符（恒不含中文 —— 中文一律是说明文字）
    static func isCodeChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-")
    }

    /// 详情分隔符（提炼格式「码 · 公司 · 地点」的切点）
    static func isDetailSeparator(_ c: Character) -> Bool {
        c == "·" || c == "｜" || c == "|" || c == "／"
    }

    // MARK: - 解析

    /// 从任意正文里解出码（解不出 → nil）
    static func code(in text: String) -> String? {
        let line = oneLine(text)
        guard let anchor = line.range(of: keyword) else { return nil }
        // ② 跳到锚点之后的第一段码字符（中间的说明字/冒号/空白全跳过）
        var i = anchor.upperBound
        while i < line.endIndex, !isCodeChar(line[i]) { i = line.index(after: i) }
        var j = i
        while j < line.endIndex, isCodeChar(line[j]) { j = line.index(after: j) }
        let token = String(line[i..<j])
        guard token.count >= codeMin, token.count <= codeMax else { return nil }
        return token
    }

    /// 码之后的详情（**必须带分隔符**才认 —— 否则整句说明会被当成公司/地点）
    static func detail(in line: String, code: String) -> String {
        // ⚠️ 必须从「取件码」锚点**之后**定位这段码：全行 range(of:) 会命中码字符在锚点前先出现的那次
        //    （「订单 123 取件码 123 · 丰巢」会被切出「取件码 123 · 丰巢」这种错前缀），锚点语义只认码之后的段。
        guard !code.isEmpty, let anchor = line.range(of: keyword) else { return "" }
        let after = line[anchor.upperBound...]
        guard let r = after.range(of: code) else { return "" }
        let tail = String(after[r.upperBound...])
        guard tail.contains(where: { isDetailSeparator($0) }) else { return "" }
        let segs = tail.split(whereSeparator: { isDetailSeparator($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= detailMaxChars }
        return segs.prefix(detailSegments).joined(separator: " · ")
    }

    /// 从一条待办正文建 PickupCode（解不出 → nil）
    static func make(todoId: String, content: String) -> PickupCode? {
        let line = oneLine(content)
        guard let code = code(in: line) else { return nil }
        return PickupCode(todoId: todoId,
                          code: code,
                          detail: detail(in: line, code: code),
                          rawLine: ellipsis(line))
    }

    /// 批量：未完成的待办进，取件码条目出（顺序保持传入顺序 —— 调用方一律传 TodoStore.sorted，最新在最前）
    static func list(_ todos: [(id: String, content: String)]) -> [PickupCode] {
        todos.compactMap { make(todoId: $0.id, content: $0.content) }
    }

    // MARK: - 卡面文案（卡面与真值表共用同一份，别在视图里再编一套）

    /// 主行：有码就显示码（用户原话「卡片上可以显示取件码」），没有则显示卡名
    static func cardTitle(_ items: [PickupCode]) -> String {
        items.first?.code ?? keyword
    }

    /// 副行（恒单行）：多条报条数 → 单条报详情 → 空态给一句引导
    static func cardSubtitle(_ items: [PickupCode]) -> String {
        guard let first = items.first else { return "收到取件码短信自动进来" }
        guard items.count == 1 else { return "等 \(items.count) 个取件码 · 点开看" }
        return first.subLine.isEmpty ? "点开看取件码" : first.subLine
    }
}
