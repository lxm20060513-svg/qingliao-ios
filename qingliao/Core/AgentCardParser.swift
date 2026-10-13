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
        /// v3.9.58：多步任务计划卡 —— 语义上强调「步骤有先后、状态是完成度」；
        /// 渲染复用 items 段（标题+副标题+状态胶囊），只是头部图标换 checklist 高亮款。
        case plan
        /// v4.0.104（#25）：可交互表单卡 —— 用户在卡内填/选，点提交把填写内容合成一条
        /// 用户消息发回会话（走既有 sendCore 全链路，不新开动作执行面）。
        case form
        /// #17：AI 成品文件卡 —— AI 生成的文件（Word/Excel/PPT/PDF/图片，落后端只读别名根
        /// office/ 下）在聊天里出一张卡，点「查看」下载 + QuickLook 预览。
        /// 渲染只认 file 段（与 form 同级、互斥），头部图标换文档款。
        case file

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

    /// v4.0.104（#25）：可交互表单的一个字段。
    /// 类型只用三种（text/number/choice）—— 未知写法一律回落 text，宁可退化成输入框也别丢字段。
    struct FormField: Equatable, Sendable {

        enum Kind: String, Equatable, Sendable {
            case text, number, choice

            /// 容错解析：未知类型 → text；`choice` 但没有可选项 → text（否则用户点不了任何东西）
            static func parse(_ raw: String?, options: [String]) -> Kind {
                switch (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
                case "number", "num", "int", "decimal", "float", "数字", "数值":
                    return .number
                case "choice", "choose", "select", "picker", "radio", "options", "单选", "选择", "选项":
                    return options.isEmpty ? .text : .choice
                default:
                    return .text
                }
            }
        }

        let key: String            // 模板占位符名（无 key 时回落 label）
        let label: String          // 给用户看的字段名（也为空 → 该字段被丢弃）
        let kind: Kind
        let placeholder: String?
        let unit: String?          // number 字段的单位（「元」「分钟」），仅展示用
        let options: [String]      // kind == .choice 时的可选项（保序）
        let defaultValue: String?
        let required: Bool
    }

    /// v4.0.104（#25）：可交互表单段。
    ///
    /// 设计口径（改动务必保持）：
    ///   ① **提交 = 合成一条用户消息**（由视图经宿主回调交给 sendCore），App 不直接执行任何动作
    ///      —— 天然复用既有动作白名单与权限闸门，不新开执行面；
    ///   ② 合成是**纯逻辑**（可在无 UI 环境单测）：模板 `{key}` 替换，未填的用字段默认值；
    ///      无模板时自动拼「（表单）label=值」，空值字段跳过；
    ///   ③ 无字段 / 字段全无名 / 段不是对象 → `nil`（卡片照旧只读渲染，零回归）；
    ///   ④ 合成结果有长度上限，防止一次提交塞爆上下文。
    struct Form: Equatable, Sendable {

        /// 合成文本上限（超长填写值截断）
        static let maxComposedLength = 4000

        let fields: [FormField]
        let submitLabel: String
        /// 回传模板（含 `{key}` 占位符）；nil → 自动合成
        let template: String?

        /// 字段的有效值：用户填的 → 字段默认值 → 空（都做 trim，空格不算填写）
        func value(_ field: FormField, in values: [String: String]) -> String {
            (values[field.key] ?? field.defaultValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// 还差哪些必填项（视图据此禁用提交按钮并提示；空串/纯空格算未填）
        func missingRequired(values: [String: String]) -> [String] {
            fields.filter { $0.required && value($0, in: values).isEmpty }.map(\.label)
        }

        /// 内容签名（**不含用户填的值**）：提交回执的隔离依据之一。
        /// ⚠️ 光靠「标题 + 字段 key」不够：同标题同 key、label/单位/选项/模板不同的两张卡会被判成同一张
        ///    → 第二张一进去就显示「已提交」、输入框永不出现（审查实测 fpA==fpB）。
        var signature: String {
            var parts: [String] = []
            for f in fields {
                parts.append([f.key, f.label, f.kind.rawValue, f.unit ?? "",
                              f.options.joined(separator: ","), f.defaultValue ?? "",
                              f.required ? "1" : "0"].joined(separator: "\u{1F}"))
            }
            parts.append(template ?? "")
            return parts.joined(separator: "\u{1E}")
        }

        /// 单遍渲染：只在**模板原文**上找 `{key}` 并替换成字段值，**绝不再扫已插入的值**。
        /// 逐字段 `replacingOccurrences` 会把「用户填的值里恰好含 {另一个字段key}」也吃掉（审查实测串味：
        /// 姓名填 `{city}` + 城市填「北京」→ 输出「姓名：北京」）。
        static func render(template: String, fields: [FormField], values: [String: String]) -> String {
            var byKey: [String: FormField] = [:]
            for f in fields where byKey[f.key] == nil { byKey[f.key] = f }   // 重复 key 取先出现的
            var out = ""
            out.reserveCapacity(template.count)
            var i = template.startIndex
            while i < template.endIndex {
                if template[i] == "{",
                   let close = template[i...].firstIndex(of: "}") {
                    let key = String(template[template.index(after: i)..<close])
                    if let f = byKey[key] {
                        out += (values[f.key] ?? f.defaultValue ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        i = template.index(after: close)
                        continue
                    }
                }
                out.append(template[i])
                i = template.index(after: i)
            }
            return out
        }

        /// 合成回传文本（提交的唯一出口）
        func compose(values: [String: String]) -> String {
            var out: String
            if let template, !template.isEmpty {
                out = Self.render(template: template, fields: fields, values: values)
            } else {
                let parts = fields.compactMap { f -> String? in
                    let v = value(f, in: values)
                    return v.isEmpty ? nil : "\(f.label)=\(v)"
                }
                out = parts.isEmpty ? "" : "（表单）" + parts.joined(separator: "；")
            }
            return out.count > Self.maxComposedLength ? String(out.prefix(Self.maxComposedLength)) : out
        }
    }

    /// #17：AI 成品文件段（与 form 同级、互斥的可选段）。
    ///
    /// 设计口径（改动务必保持）：
    ///   ① **path 必填**（相对后端允许根的路径，本批只有 `office/` 这一条别名根）；
    ///      **缺 path / path 为空 → 整段丢弃**（退化成普通只读卡，绝不出「查看」按钮、绝不崩）；
    ///   ② name 缺省用 path 的最后一段；kind 缺省由 name 扩展名推断；
    ///   ③ size 缺省 0（未知 → 卡上不显示大小）；
    ///   ④ kind 只认 docx/xlsx/pptx/pdf/image/other，未知值一律 other。
    struct File: Equatable, Sendable {

        enum Kind: String, Equatable, Sendable {
            case docx, xlsx, pptx, pdf, image, other

            /// 容错解析：只认白名单，未知值一律 other（不许退回 nil 丢字段）
            static func parse(_ raw: String?) -> Kind {
                Kind(rawValue: (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()) ?? .other
            }

            /// 由文件名扩展名推断（kind 缺省时用）；认不出的扩展名 → other
            static func infer(fromName name: String) -> Kind {
                switch (name as NSString).pathExtension.lowercased() {
                case "docx", "doc": return .docx
                case "xlsx", "xls": return .xlsx
                case "pptx", "ppt": return .pptx
                case "pdf": return .pdf
                case "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tiff", "ico":
                    return .image
                default: return .other
                }
            }
        }

        let path: String
        let name: String
        let kind: Kind
        let size: Int
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
    /// v4.0.104（#25）：可交互表单段（nil = 只读卡，行为与旧版逐字一致）
    let form: Form?
    /// #17：AI 成品文件段（nil = 无文件段，行为与旧版逐字一致）
    let file: File?

    /// 无任何可渲染内容 → 调用方按纯文本处理（不给用户空白卡）
    var isEmpty: Bool {
        let hasTitle = !(title ?? "").isEmpty
        let hasStatus = !(status?.text ?? "").isEmpty
        return !hasTitle && !hasStatus && fields.isEmpty && metrics.isEmpty
            && items.isEmpty && table == nil && (footer ?? "").isEmpty && form == nil && file == nil
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
        // v4.0.104（#25）：表单段也要落进纯文本 —— 只读降级/复制/导出时字段名不能丢
        if let form {
            for f in form.fields {
                var line = "· \(f.label)"
                if let d = f.defaultValue, !d.isEmpty { line += "：\(d)" }
                lines.append(line)
            }
            if !form.submitLabel.isEmpty { lines.append("（\(form.submitLabel)）") }
        }
        // #17：成品文件段也要落进纯文本 —— 只读降级/复制/导出时文件名不能丢
        if let file {
            lines.append("文件：\(file.name)")
        }
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
            /// 从给定容器取 columns/rows（两者都空 → nil）
            func build(_ src: [String: Any]) -> Table? {
                let columns = (src["columns"] as? [Any] ?? []).compactMap { str($0) }
                let rows: [[String]] = (src["rows"] as? [Any] ?? []).compactMap { raw in
                    guard let arr = raw as? [Any] else { return nil }
                    let cells = arr.compactMap { str($0) }
                    return cells.isEmpty ? nil : cells
                }
                guard !columns.isEmpty || !rows.isEmpty else { return nil }
                return Table(columns: columns, rows: rows)
            }
            // 标准写法：{"table":{"columns":[…],"rows":[[…]]}}
            if let td = dict["table"] as? [String: Any], let t = build(td) { return t }
            // 容错：模型常把 columns/rows 写到 JSON 顶层（prompt 平铺列举导致的误写）。
            // 只认嵌套时整张表格被静默丢弃，卡片只剩标题/结论 —— 用户看到的是「内容不完整」。
            return build(dict)
        }()

        // v4.0.104（#25）：可交互表单段（无字段/字段全无名/段不是对象 → nil，退化成只读卡）
        let form: Form? = {
            guard let fd = dict["form"] as? [String: Any] else {
                // 容错：`"form"` 也可能是数组（模型把字段直接摊开写）→ 当成 fields 用
                if let arr = dict["form"] as? [Any] {
                    let fields = AgentCard.parseFields(arr)
                    return fields.isEmpty ? nil : Form(fields: fields, submitLabel: "提交", template: nil)
                }
                return nil
            }
            let fields = AgentCard.parseFields(fd["fields"] as? [Any] ?? [])
            guard !fields.isEmpty else { return nil }

            // submit 两种写法：{"label":"算一下","template":"…"}（标准）或 "算一下"（只给按钮文案）
            var submitLabel = "提交"
            var template: String?
            if let sd = fd["submit"] as? [String: Any] {
                if let l = str(sd["label"]) ?? str(sd["text"]), !l.isEmpty { submitLabel = l }
                template = str(sd["template"]) ?? str(sd["prompt"])
            } else if let s = str(fd["submit"]), !s.isEmpty {
                submitLabel = s
            }
            return Form(fields: fields, submitLabel: submitLabel, template: template)
        }()

        // #17：AI 成品文件段（缺 path / path 为空 → nil，退化成普通只读卡；绝不出「查看」按钮）
        let file: File? = {
            guard let fd = dict["file"] as? [String: Any] else { return nil }
            let path = (str(fd["path"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }   // 容错口径：缺 path → 整段丢弃（不崩、不空壳）
            let rawName = (str(fd["name"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // name 缺省 → path 最后一段（相对路径只按 "/" 切，与本仓 FilesManagerKit.safeLocalName 同口径）
            // 取最后一个**非空**片段：`office/` 这种以斜杠结尾的 path 用 separatedBy.last 会拿到空串
            // → 卡面标题空白 + plainText 出「文件：」空行（独立审查抓到的边界，size 0 时更明显）
            let lastSegment = path.components(separatedBy: "/").filter { !$0.isEmpty }.last ?? ""
            let name = rawName.isEmpty ? (lastSegment.isEmpty ? "文件" : lastSegment) : rawName
            let kind: File.Kind = {
                let raw = (str(fd["kind"]) ?? "").trimmingCharacters(in: .whitespaces)
                // kind 给了但不在白名单 → other（不回落推断）；缺省 → 由扩展名推断
                return raw.isEmpty ? File.Kind.infer(fromName: name) : File.Kind.parse(raw)
            }()
            let size = max(0, Int(str(fd["size"]) ?? "") ?? 0)   // 缺省 / 脏值 → 0（未知，不显示大小）
            return File(path: path, name: name, kind: kind, size: size)
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
            footer: str(dict["footer"]),
            form: form,
            file: file
        )
        return card.isEmpty ? nil : card
    }

    /// 表单字段数组解析（容错口径：字段名取 label/key/name 之一；两者皆空 → 丢弃该字段）
    private static func parseFields(_ raw: [Any]) -> [FormField] {
        // key 去重：视图用 ForEach(id: \.key)，重复 id 是 SwiftUI 未定义行为（可能只渲染一个）；
        // 模板占位符也必须各自独立 → 重复的往后加序号（key2、key3…），保留字段不丢
        var seen = Set<String>()
        return raw.compactMap { item -> FormField? in
            guard let d = item as? [String: Any] else { return nil }
            let label = str(d["label"]) ?? str(d["key"]) ?? str(d["name"]) ?? ""
            var key = str(d["key"]) ?? str(d["name"]) ?? label
            guard !key.isEmpty || !label.isEmpty else { return nil }
            if seen.contains(key) {
                var n = 2
                while seen.contains("\(key)\(n)") { n += 1 }
                key = "\(key)\(n)"
            }
            seen.insert(key)
            let options = (d["options"] as? [Any] ?? []).compactMap { str($0) }
            // required 用 str() 统一归一（JSON 布尔在 Linux corelibs 上 as? Bool 不稳，
            // str() 已把布尔转成「是/否」）
            let reqRaw = (str(d["required"]) ?? "").lowercased()
            let required = reqRaw == "是" || reqRaw == "true" || reqRaw == "1"
            return FormField(
                key: key,
                label: label.isEmpty ? key : label,
                kind: FormField.Kind.parse(str(d["type"]) ?? str(d["kind"]), options: options),
                placeholder: str(d["placeholder"]) ?? str(d["hint"]),
                unit: str(d["unit"]),
                options: options,
                defaultValue: str(d["default"]) ?? str(d["value"]),
                required: required
            )
        }
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

        // 四反引号降级改写（2026-10-03 实战形态）：模型偶发把卡片写成 ````ql-card … ````，
        // 内部再套 ```json。解析器只认三反引号 → 整块退化成代码块。改写成功 → 按
        // 三反引号路径继续；外层围栏不成对（流式中）或非卡片语言（用户真贴 markdown）
        // → 原文一字不动，零回归。
        if let demoted = demoteFourBacktickCard(text) {
            return parse(demoted)
        }

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
            if isFenceLine(lines[i]), let lang = fenceLanguage(lines[i]), !isCardFence(lang) {
                // 带语言标记的非卡片围栏（```swift / ```markdown …）：整块原样保留。
                // 必须在卡片判定**之前**吞掉它，否则「文档里贴 ql-card 示例」会渲染成假卡。
                //
                // 🚨 裸 ```（无语言标记）**不能**进这里：它同时是「闭合行」的写法，
                // 当成开块会一路吞到文末、把后面的真卡整块吃掉。裸围栏走下面的
                // buffer 路径（与本轮改动前完全一致）。
                var k = i + 1
                while k < lines.count, !isFenceLine(lines[k]) { k += 1 }
                let stop = min(k, lines.count - 1)   // 未闭合 → 一直保留到文末
                buffer.append(contentsOf: lines[i...stop])
                i = (k < lines.count) ? k + 1 : lines.count
                continue
            }
            if let lang = fenceLanguage(lines[i]), isCardFence(lang) {
                // 收集围栏体：找到闭合 ``` 才算「完成」
                // 两阶段：先整块收（到行首闭合围栏或文末）；整块 JSON 解析失败时，
                // 再按「行内 ```」逐行截断重试一次 —— 兼容模型把闭合三反引号
                // 粘在 JSON 末尾同一行的写法（`..."}``` `），不改则整块被当代码块显示。
                var body: [String] = []
                var j = i + 1
                var closed = false
                while j < lines.count {
                    if isFenceLine(lines[j]) { closed = true; break }
                    body.append(lines[j])
                    j += 1
                }
                // 未闭合围栏**不得出卡**（哪怕当前围栏体恰好是合法 JSON）：流式生成中
                // 先渲染卡片、下一帧闭合围栏到了又退成原文 = 用户看到卡片闪一下变代码块。
                // 行内 ``` 截断那条路径自带定界符，可豁免这道门槛。
                var card = closed ? AgentCard.parse(json: body.joined(separator: "\n")) : nil
                // consumed = 卡片结束后应继续扫描的行号：闭合时跳过闭合行本身
                var consumed = closed ? j + 1 : j
                var trailing: [String] = []
                var cut = false
                if card == nil {
                    // 行内闭合兜底（无论是否找到行首闭合围栏都试；行首闭合的写法
                    // 行内截断必然解析失败 → 自然不走这条路，行为不变）。
                    // 截不出卡就走原文（流式半截 JSON 依然整块当文本，绝不出半截卡片）。
                    var cutBody: [String] = []
                    for line in body {
                        if let idx = inlineFenceIndex(line) {
                            cutBody.append(String(line[line.startIndex..<idx]))
                            cut = true
                            break
                        }
                        cutBody.append(line)
                    }
                    if cut, let c2 = AgentCard.parse(json: cutBody.joined(separator: "\n")) {
                        card = c2
                        consumed = i + 1 + cutBody.count
                        // 闭合 ``` 之后同一行的残留文字不能吞掉（按零回归逐字保留）
                        let cutLineIdx = consumed - 1
                        if cutLineIdx < lines.count,
                           let idx = inlineFenceIndex(lines[cutLineIdx]) {
                            let line = lines[cutLineIdx]
                            // 从 ``` 之后取（index(after:) 只跳过一个反引号，会漏两个）
                            let rest = line.index(idx, offsetBy: 3, limitedBy: line.endIndex)
                                .map { String(line[$0...]) } ?? ""
                            if !rest.isEmpty { trailing = [rest] }
                        }
                    }
                }
                if let card {
                    flushText()
                    segments.append(.card(card))
                    buffer.append(contentsOf: trailing)
                    i = consumed
                    continue
                }
                // 未闭合（流式中） / JSON 非法 / 空卡片 → 原文照旧（含围栏行本身）。
                // 退化区 = 围栏头 + 围栏体；闭合/截断成功后 consumed 已越过它，
                // 故退化区上界取 consumed-1（否则会把闭合行之后的内容也算进来）。
                let end = (closed || cut) ? consumed - 1 : j   // cut 时 consumed-1 = 切点行
                let last = min(end, lines.count - 1)
                if i <= last { buffer.append(contentsOf: lines[i...last]) }
                i = (closed || cut) ? consumed : lines.count
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

    /// 行内 ``` 的位置（非行首）。模型偶发把闭合三反引号粘在 JSON 末尾同一行
    /// （`..."}" + "```"）—— 不做这个兜底，整块卡片会被当代码块原样显示。
    /// 零回归：截断后的 JSON 仍须通过 JSONSerialization，否则照样退化为原文。
    private static func inlineFenceIndex(_ line: String) -> String.Index? {
        guard isFenceLine(line) == false else { return nil }
        return line.range(of: "```")?.lowerBound
    }

    private static func isFenceLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    // MARK: - 四反引号降级改写

    /// 把 ````ql-card … ```` 包裹的卡片降级改写成三反引号裸 JSON 形态（协议归一化）。
    /// 只在「外层四反引号围栏成对、语言标记是卡片」时改写，返回 nil = 原样保留：
    /// - 外层未闭合（流式中间帧）→ 不改（防卡片闪一下退回原文）
    /// - ````markdown 等非卡片语言 → 不改（用户真贴的 markdown 原文逐字保留）
    /// - 内层 ```json 语言行 → 顺带剥掉（JSON 裸写在围栏内）
    /// 改写后仍走三反引号路径的全部门槛（闭合 + JSONSerialization），改不动 = 零回归。
    static func demoteFourBacktickCard(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        var openIdx: Int?
        var count = 0
        for (idx, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("````") {
                if openIdx == nil {
                    // 开头行：四反引号 + 卡片语言标记（ql-card / ql_card / qlcard）
                    let lang = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                        .lowercased()
                        .replacingOccurrences(of: "-", with: "")
                        .replacingOccurrences(of: "_", with: "")
                    guard lang == "qlcard" else { return nil }
                    openIdx = idx
                } else {
                    // 闭合行：必须是「行首纯四反引号」才算成对闭合
                    guard t == "````" else { return nil }
                    count += 1
                }
            }
        }
        // 恰好一开一闭才算成对；0 个或多个闭合 = 流式半截 / 形态不认识 → 原样
        guard let open = openIdx, count == 1 else { return nil }
        // 外层闭合行 = 最后一个行首纯四反引号行（count==1 时唯一）
        let close = lines.lastIndex { $0.trimmingCharacters(in: .whitespaces) == "````" }

        var out: [String] = []
        for (idx, line) in lines.enumerated() {
            if idx == open {
                out.append("```ql-card")
            } else if idx == close {
                out.append("```")
            } else if idx == open + 1 || idx == close! - 1 {
                // 内层 ```json 开行 / 内层闭合 ``` 行：整行剥掉（JSON 本体裸写）。
                // 仅在确实是围栏行时剥，普通内容行不受影响。
                let t = line.trimmingCharacters(in: .whitespaces)
                out.append(t == "```json" || t == "```" ? "" : line)
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }
}
