import Foundation

// MARK: - v3.9.95 AI 本地动作协议（```ql-action 围栏）模型 + 解析器
//
// 为什么是围栏协议而不是别的：App 已有成熟的 ```ql-card 围栏管线（见 AgentCardParser.swift），
// AI 输出「文字 + 结构化块」是既有事实。**复用它**意味着零新增通道、零新增解析器，
// 后端只要学会多写一个围栏，不用改 App↔后端协议；前端的流式安全、未闭合围栏、
// 非法 JSON 退化等坑也一并继承。
//
// 协议：
//   ```ql-action
//   {"action": "calendar.create", "params": {...}, "summary": "新建日历事件「…」"}
//   ```
//
// 与 ql-card 相同的**三条硬约束**（改这个文件务必保持）：
//   ① 零回归：无标记 / JSON 坏 / action 不认识 → 一律退化成原文（与纯文本渲染逐字一致）。
//      解析器**只做纯函数解析**，绝不执行任何东西 —— 执行在 AgentActionExecutor（另一文件）。
//   ② 流式安全：围栏未闭合前整块按文本处理，绝不渲染半截动作卡。
//   ③ 纯 Foundation：不引 SwiftUI/EventKit，可在无 UI 环境单测（见 scripts/test_agent_action.swift）。
//
// ⚠️ **安全**：解析器绝不信任 AI 的措辞。`summary` 只是给用户看的**提议**文案，
//    真正执行前一律走 `AppPermissionKit.mutationGuard`（双闸门 + 后台保护）。
//    这是「AI 下发动作」这条链路上唯一必须守住的地方。

// MARK: - 动作

/// 一个待执行动作。**只有** `runsInBackground == false` 且过了权限闸门的才允许执行。
struct AgentAction: Equatable, Sendable {

    /// 动作标识。用命名空间 `能力.动作` 形式，便于后端自解释、也便于 App 拒绝未知能力。
    enum Kind: String, Equatable, Sendable, CaseIterable {
        // 日历
        case calendarCreate = "calendar.create"
        case calendarDelete = "calendar.delete"
        case calendarFree  = "calendar.free"       // 查空闲（只读）
        case calendarToday = "calendar.today"      // 今天日程（只读）
        // 相册
        case photoSave    = "photo.save"           // 存图（写）
        // 通知
        case notify       = "notify"              // 系统通知（写）

        var capability: AppCapability {
            switch self {
            case .calendarCreate, .calendarDelete, .calendarFree, .calendarToday:
                return .calendar
            case .photoSave:   return .photos
            case .notify:      return .notifications
            }
        }

        /// 只读 = 免确认直接执行；写 = 胶囊确认；删 = 必须明确确认（口径 ②）。
        /// ⚠️ 新增动作**必须**显式归类，编译器会逼你写全 switch（漏了编不过，这是故意的）。
        enum Impact: String, Equatable, Sendable {
            case read, write, delete
        }

        var impact: Impact {
            switch self {
            case .calendarFree, .calendarToday: return .read
            case .calendarCreate, .photoSave, .notify: return .write
            case .calendarDelete: return .delete
            }
        }

        /// 给用户看的一行说明（失败时也用它解释为什么不能做）。
        var capabilityLabel: String {
            switch self {
            case .calendarCreate: return "新建日历事件"
            case .calendarDelete: return "删除日历事件"
            case .calendarFree:   return "查询空闲时段"
            case .calendarToday:  return "查看今日日程"
            case .photoSave:      return "保存到相册"
            case .notify:         return "发送系统通知"
            }
        }
    }

    let kind: Kind
    /// 参数字典（保持松散：不同动作的字段本就不同，强行建模会绑死协议演进）。
    /// 只读 `[String: String]` 而非任意 JSON —— 执行器只需要字符串参数（时间/标题/URL），
    /// 真要传二进制（存图的 data URL）由 photoSave 单独读 `dataURL` 字段。
    let params: [String: String]
    /// AI 写的提议文案（**不可信，仅展示**）
    let summary: String?

    // MARK: 参数读取（统一在这里做类型/格式校验，勿在执行器里散落 parse）

    func param(_ key: String) -> String? {
        let v = params[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty ?? true) ? nil : v
    }

    /// ISO8601 解析。**不接受本地化日期串**（"明天 3 点" 这类靠后端解析成 ISO 传来，
    /// App 端不再猜 —— 猜时区是最容易出错的地方）。
    static func isoDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// 解析 JSON 围栏体。**永不抛错、越界返回 nil**。
    static func parse(json raw: String) -> AgentAction? {
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kindRaw = obj["action"] as? String else { return nil }
        // 未知动作 → nil（退化成原文），不猜、不"尽力而为"地执行半个动作
        guard let kind = Kind(rawValue: kindRaw.trimmingCharacters(in: .whitespaces).lowercased()) else {
            NSLog("[QLACTION] 未知动作，已忽略: %@", kindRaw)
            return nil
        }
        var params: [String: String] = [:]
        if let p = obj["params"] as? [String: Any] {
            for (k, v) in p {
                // 只取标量：数组/对象不参与动作协议（真要传结构化参数再加类型化入口）
                if let s = v as? String { params[k] = s }
                else if let b = v as? Bool { params[k] = b ? "true" : "false" }
                else if let n = v as? NSNumber { params[k] = n.stringValue }
            }
        }
        return AgentAction(kind: kind, params: params, summary: obj["summary"] as? String)
    }
}

// MARK: - 围栏解析

/// ```ql-action 围栏 → 动作卡。与 AgentCardParser 同构，但**刻意独立**：
/// 动作有安全含义，不能和结果卡片共用一个 Segment 类型 —— 那样渲染层一个 switch
/// 就能同时画出「可点的执行卡」和「纯展示卡」，将来加动作时容易漏掉守卫。
enum AgentActionParser {

    enum Segment: Equatable, Sendable {
        case text(String)
        case action(AgentAction)
    }

    /// 廉价门控（流式每帧先跑）：无标记 → 老路径零开销
    static func containsActionMarker(_ text: String) -> Bool {
        text.contains("ql-action") || text.contains("ql_action") || text.contains("qlaction")
    }

    static func isActionFence(_ lang: String) -> Bool {
        let l = lang.trimmingCharacters(in: .whitespaces).lowercased()
        return l == "ql-action" || l == "ql_action" || l == "qlaction"
    }

    /// 主入口。围栏未闭合 → 整段按文本（流式安全，口径 ②）。
    static func parse(_ text: String) -> [Segment] {
        guard containsActionMarker(text) else { return [.text(text)] }

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
            let lang = fenceLanguage(lines[i])
            if let lang, isActionFence(lang) {
                // 收集围栏体到闭合行。⚠️ **未闭合一律不出卡**（同 ql-card 的理由：
                //   流式生成中先出卡、下一帧闭合又退回原文 = 用户看到卡闪一下变代码块）
                var body: [String] = []
                var j = i + 1
                var closed = false
                while j < lines.count {
                    if isFenceLine(lines[j]) { closed = true; break }
                    body.append(lines[j])
                    j += 1
                }
                if closed, let action = AgentAction.parse(json: body.joined(separator: "\n")) {
                    flushText()
                    segments.append(.action(action))
                    i = j + 1
                    continue
                }
                // 解析失败 → 整块退回文本（零回归，口径 ①）
                let stop = min(j, lines.count - 1)
                buffer.append(contentsOf: lines[i...stop])
                i = closed ? j + 1 : j
                continue
            }
            buffer.append(lines[i])
            i += 1
        }
        flushText()
        return segments
    }

    // MARK: 围栏行识别（与 AgentCardParser 同款宽容写法）

    /// 行首 ``` 后跟的语言标记（裸 ``` 返回 nil —— 它同时是闭合行写法）
    static func fenceLanguage(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("```") else { return nil }
        let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return lang.isEmpty ? nil : lang
    }

    /// 行首闭合围栏 ```（允许尾随空白）
    static func isFenceLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("```") else { return false }
        return t.dropFirst(3).trimmingCharacters(in: .whitespaces).isEmpty
    }
}
