import Foundation

// MARK: - v3.5.0 Agent 结果卡片（```ql-card 围栏协议）模型 + 解析器
//
// 背景：Agent 跑完常把结构化结果（体检项/指标/表格/清单）铺成一长串文字，用户要逐行读。
// 本文件定义「卡片标记协议」并解析：AI 回复里出现 ```ql-card 围栏 + 单 JSON 对象时，
// 围栏整块 → AgentCard（App 端渲染成卡片）；其余文本原样保留。
//
// 三条硬约束（设计红线，改动务必保持）：
//   ① 零回归：无标记 / JSON 解析失败 / 空卡片 → 一律退化成原文（与现有纯文本/Markdown 渲染逐字一致）；
//   ② 流式安全：围栏未闭合（或闭合前）时整块按文本处理 —— 绝不渲染半截卡片；
//   ③ 纯 Foundation：不引第三方依赖，不引 SwiftUI（可在无 UI 环境单测，见 scripts/test_agent_card.swift）。
//
// 协议说明文档：docs/agent-card-protocol.md

// MARK: - 模型

/// 一张 Agent 结果卡片。所有字段都可缺省；渲染端按「有内容的段才画」处理。
struct AgentCard: Equatable, Sendable {

    /// 卡片语义（只影响头部图标/强调色，不改变段渲染 —— 有什么段画什么段）
    enum Kind: String, Equatable, Sendable {
        case result, metrics, list, table, status

        static func parse(_ raw: String?) -> Kind {
            guard let raw, let k = Kind(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else {
                return .result
            }
            return k
        }
    }

    /// 状态语义色（映射到渲染端绿/橙/红/蓝）
    enum Tone: String, Equatable, Sendable {
        case ok, warn, error, info

        /// 容错解析：接受常见别名与中文，未知 → nil（渲染端按 info 处理）
        static func parse(_ raw: String?) -> Tone? {
            guard let raw else { return nil }
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "ok", "good", "success", "done", "normal", "正常", "完成", "成功":
                return .ok
            case "warn", "warning", "pending", "注意", "警告", "部分", "进行中":
                return .warn
            case "error", "fail", "failed", "bad", "异常", "失败", "错误":
                return .error
            case "info", "neutral", "note", "信息", "提示":
                return .info
            default:
                return nil
            }
        }
    }

    struct Status: Equatable, Sendable {
        let text: String
        let tone: Tone?
    }

    struct Field: Equatable, Sendable {
        let key: String
        let value: String
        let tone: Tone?
    }

    /// 指标（大号数值 + 单位，渲染端用 contentTransition(.numericText()) 滚动）
    struct Metric: Equatable, Sendable {
        let label: String
        let value: String
        let unit: String?
        let tone: Tone?
    }

    /// 清单项（标题 + 副标题 + 状态）
    struct Item: Equatable, Sendable {
        let title: String
        let subtitle: String?
        let status: String?
        let tone: Tone?
    }

    struct Table: Equatable, Sendable {
        let columns: [String]
        let rows: [[String]]
    }

    let kind: Kind
    let title: String?
    let subtitle: String?
    let status: Status?
    let fields: [Field]
    let metrics: [Metric]
    let items: [Item]
    let table: Table?
    let footer: String?

    /// 无任何可渲染内容 → 调用方按纯文本处理（不给用户空白卡）
    var isEmpty: Bool {
        let hasTitle = !(title ?? "").isEmpty
        let hasStatus = !(status?.text ?? "").isEmpty
        return !hasTitle && !hasStatus && fields.isEmpty && metrics.isEmpty
            && items.isEmpty && table == nil && (footer ?? "").isEmpty
    }

    /// 纯文本降级：复制 / 大爆炸 / 朗读 / 导出用（卡片内容不丢字）
    var plainText: String {
        var lines: [String] = []
        if let title, !title.isEmpty {
            lines.append(subtitle.map { "\(title)（\($0)）" } ?? title)
        } else if let subtitle, !subtitle.isEmpty {
            lines.append(subtitle)
        }
        if let status, !status.text.isEmpty { lines.append("状态：\(status.text)") }
        for f in fields where !f.key.isEmpty || !f.value.isEmpty {
            lines.append("\(f.key)：\(f.value)")
        }
        for m in metrics {
            lines.append("\(m.label)：\(m.value)\(m.unit ?? "")")
        }
        for i in items {
            var line = "· " + i.title
            if let s = i.subtitle, !s.isEmpty { line += "（\(s)）" }
            if let s = i.status, !s.isEmpty { line += "[\(s)]" }
            lines.append(line)
        }
        if let t = table {
            lines.append(t.columns.joined(separator: " | "))
            for row in t.rows { lines.append(row.joined(separator: " | ")) }
        }
        if let footer, !footer.isEmpty { lines.append(footer) }
        return lines.joined(separator: "\n")
    }

    // MARK: 容错 JSON 解析

    /// 解析围栏内 JSON 文本。任何结构性问题 → nil（调用方退化为原文，绝不吞内容）
    static func parse(json: String) -> AgentCard? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else { return nil }

        let statusDict = dict["status"] as? [String: Any]
        let status: Status? = {
            // "status": "已完成" 与 "status": {"text": "...", "tone": "ok"} 两种写法都收
            if let s = str(dict["status"]), !s.isEmpty {
                return Status(text: s, tone: Tone.parse(str(dict["tone"])))
            }
            if let sd = statusDict, let t = str(sd["text"]), !t.isEmpty {
                return Status(text: t, tone: Tone.parse(str(sd["tone"])))
            }
            return nil
        }()

        let fields: [Field] = (dict["fields"] as? [Any] ?? []).compactMap { raw in
            guard let d = raw as? [String: Any], let v = str(d["value"]) else { return nil }
            let k = str(d["key"]) ?? str(d["label"]) ?? ""
            guard !k.isEmpty || !v.isEmpty else { return nil }
            return Field(key: k, value: v, tone: Tone.parse(str(d["tone"])))
        }

        let metrics: [Metric] = (dict["metrics"] as? [Any] ?? []).compactMap { raw in
            guard let d = raw as? [String: Any], let v = str(d["value"]) else { return nil }
            let label = str(d["label"]) ?? str(d["key"]) ?? ""
            guard !label.isEmpty || !v.isEmpty else { return nil }
            return Metric(label: label, value: v, unit: str(d["unit"]), tone: Tone.parse(str(d["tone"])))
        }

        // 清单键名兼容 list / items，元素支持纯字符串
        let itemSource = (dict["list"] as? [Any]) ?? (dict["items"] as? [Any]) ?? []
        let items: [Item] = itemSource.compactMap { raw in
            if let s = str(raw), !s.isEmpty {
                return Item(title: s, subtitle: nil, status: nil, tone: nil)
            }
            guard let d = raw as? [String: Any] else { return nil }
            let title = str(d["title"]) ?? str(d["text"]) ?? str(d["name"]) ?? ""
            let sub = str(d["subtitle"]) ?? str(d["detail"])
            let st = str(d["status"])
            guard !title.isEmpty else { return nil }
            return Item(title: title, subtitle: sub, status: st, tone: Tone.parse(str(d["tone"])))
        }

        let table: Table? = {
            guard let td = dict["table"] as? [String: Any] else { return nil }
            let columns = (td["columns"] as? [Any] ?? []).compactMap { str($0) }
            let rows: [[String]] = (td["rows"] as? [Any] ?? []).compactMap { raw in
                guard let arr = raw as? [Any] else { return nil }
                let cells = arr.compactMap { str($0) }
                return cells.isEmpty ? nil : cells
            }
            guard !columns.isEmpty || !rows.isEmpty else { return nil }
            return Table(columns: columns, rows: rows)
        }()

        let card = AgentCard(
            kind: Kind.parse(str(dict["type"])),
            title: str(dict["title"]),
            subtitle: str(dict["subtitle"]),
            status: status,
            fields: fields,
            metrics: metrics,
            items: items,
            table: table,
            footer: str(dict["footer"])
        )
        return card.isEmpty ? nil : card
    }

    /// 任意 JSON 标量/数组 → 字符串（字符串原样；数字去尾零；布尔「是/否」；数组用「、」连接）。
    /// 容错是刻意的：后端/Agent 产出格式不完全可控，能用就不要丢弃整张卡片。
    private static func str(_ any: Any?) -> String? {
        switch any {
        case let s as String:
            return s
        case let n as NSNumber:
            // objCType == "c" 是 JSON 布尔（Linux/Darwin 一致；Bool 直转会与数字 0/1 混淆）
            if String(cString: n.objCType) == "c" { return n.boolValue ? "是" : "否" }
            let d = n.doubleValue
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return String(format: "%g", d)
        case let arr as [Any]:
            let parts = arr.compactMap { str($0) }
            return parts.isEmpty ? nil : parts.joined(separator: "、")
        default:
            return nil
        }
    }
}

// MARK: - 围栏切分

/// 把 AI 回复文本切分为「文本段 / 卡片段」。解析失败一律退化文本段 —— 零回归的收口点。
enum AgentCardParser {

    enum Segment: Equatable, Sendable {
        case text(String)
        case card(AgentCard)
    }

    /// 廉价门控（流式每帧先跑它）：无卡片标记 → 老路径零额外开销。
    /// 标记约定小写 `ql-card`（兼容 `ql_card` / `qlcard`）。
    static func containsCardMarker(_ text: String) -> Bool {
        text.contains("ql-card") || text.contains("ql_card") || text.contains("qlcard")
    }

    /// 主入口：文本 → 段序列。无标记时返回单个文本段（调用方据此走原渲染路径）。
    static func parse(_ text: String) -> [Segment] {
        guard containsCardMarker(text) else { return [.text(text)] }

        let lines = text.components(separatedBy: "\n")
        var segments: [Segment] = []
        var buffer: [String] = []

        func flushText() {
            guard !buffer.isEmpty else { return }
            segments.append(.text(buffer.joined(separator: "\n")))
            buffer = []
        }

        var i = 0
        while i < lines.count {
            if let lang = fenceLanguage(lines[i]), isCardFence(lang) {
                // 收集围栏体：找到闭合 ``` 才算「完成」
                var body: [String] = []
                var j = i + 1
                var closed = false
                while j < lines.count {
                    if isFenceLine(lines[j]) { closed = true; break }
                    body.append(lines[j])
                    j += 1
                }
                if closed, let card = AgentCard.parse(json: body.joined(separator: "\n")) {
                    flushText()
                    segments.append(.card(card))
                    i = j + 1
                    continue
                }
                // 未闭合（流式中） / JSON 非法 / 空卡片 → 原文照旧（含围栏行本身）
                let last = min(j, lines.count - 1)
                if i <= last { buffer.append(contentsOf: lines[i...last]) }
                i = closed ? j + 1 : lines.count
                continue
            }
            buffer.append(lines[i])
            i += 1
        }
        flushText()
        return segments
    }

    /// 行首 ``` 后跟的语言标记（```ql-card → "ql-card"）
    private static func fenceLanguage(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("```") else { return nil }
        let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return lang.isEmpty ? nil : lang
    }

    /// 卡片围栏标记（宽容写法：ql-card / ql_card / qlcard / 大小写不敏感）
    private static func isCardFence(_ lang: String) -> Bool {
        lang.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "") == "qlcard"
    }

    private static func isFenceLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }
}
