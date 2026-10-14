import Foundation

// MARK: - v4.0.109 工作区「待你处理」聚合（纯逻辑）
//
// 用户 2026-10-14：「『待你处理』聚合」——工作区要有**一个地方**列出「AI 问我、我还欠一个回答」的事。
//
// 口径（用户理解优先）：
//   · 真源 = 会话里的**问题卡**（消息 `questionId` 非空，App 内渲染成 `ChatQuestionCard`）；
//   · 未答 = `questionAnswer` 为空（已答的卡不再要用户动作，不算「待你处理」）；
//   · 跨会话聚合 —— 用户不必记得「哪条会话里 AI 问过我」。
//
// 数据来源 = `GET /api/sessions/list`（一次拿全部会话 + 消息全文，与 App 会话列表页 `SessionsView.load`
// 完全同一条读路径）→ 本功能**零后端改动**，也没新增轮询。
//
// ⚠️ 字段名与 `Core/Models.swift`（`ChatMessage.parse` / `ChatSession.parse`）**同源**：
//    sessions[].id / .title / .messages[]、messages[].timestamp(ms) / .content / .questionId / .questionAnswer。
//    改那边必须同时改这里，否则「待你处理」会**静默变空**（不报错，最难查的一类）。
//
// ⚠️ 本文件只 `import Foundation`（不碰 SwiftUI）—— 真值表单文件即可编译，护栏见 `scripts/ql_workspace_pending/`。
enum WorkspacePendingKit {

    struct Item: Identifiable, Equatable {
        /// "会话 id#问题 id"：同一张卡只出现一次（问题卡会重复投递给同一条会话）
        let id: String
        let sessionId: String
        /// 问题正文（单行，已剥掉选项行 / 媒体行等展示噪声）
        let question: String
        /// 归属会话标题（空标题会话兜底「未命名会话」）
        let sessionTitle: String
        /// 归属会话最后一条消息时间（**毫秒** —— 与 `ChatMessage.timestamp` / `ChatStore.markRead` 同单位）
        let time: Double
    }

    /// 抽出全部未答问题卡，按时间**新 → 旧**排序。
    /// - Parameter json: `/api/sessions/list` 的原始返回体
    static func parse(_ json: [String: Any]?) -> [Item] {
        guard let sessions = json?["sessions"] as? [[String: Any]] else { return [] }
        var out: [Item] = []
        for s in sessions {
            guard let sid = text(s["id"]), !sid.isEmpty else { continue }
            let msgs = (s["messages"] as? [[String: Any]]) ?? []
            let lastTs = msgs.compactMap { ms($0["timestamp"]) }.max() ?? 0
            var seen = Set<String>()
            for m in msgs {
                guard let qid = text(m["questionId"]), !qid.isEmpty else { continue }
                guard text(m["questionAnswer"]) == nil else { continue }   // 已答 → 不是「待你处理」
                guard let body = questionLine(m["content"]) else { continue }
                let id = sid + "#" + qid
                guard seen.insert(id).inserted else { continue }            // 同卡重复投递只留一条
                out.append(Item(id: id,
                                sessionId: sid,
                                question: body,
                                sessionTitle: text(s["title"]) ?? "未命名会话",
                                time: lastTs))
            }
        }
        return out.sorted { $0.time > $1.time }
    }

    // MARK: - JSON 取值小工具（JSONSerialization 给的是 Any，可能是 String / NSNumber）

    private static func text(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func ms(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// 问题卡的正文行：取内容里**第一条可读文本行**、剥掉 markdown 标记、超长截断。
    ///
    /// 为什么取第一行而不是全文：问题卡的 `content` 里「选项：A|B」也在同一串
    /// （落库口径见 `InboxStore` 的 `ChatMessage.splitQuestion`），工作区只展示问题本身，
    /// 选项留给会话内的卡（那里点一下就答）。
    static func questionLine(_ v: Any?, limit: Int = 42) -> String? {
        guard let raw = v as? String else { return nil }
        for rawLine in raw.components(separatedBy: .newlines) {
            let t = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if t.hasPrefix("MEDIA:") || t.hasPrefix("![") { continue }        // 媒体占位行
            if t.hasPrefix("选项：") || t.hasPrefix("选项:") { continue }       // 快捷选项行
            // 只剥行首标记字符（# * - > 反引号 与全角空格），不动行内文字
            let clean = t.trimmingCharacters(in: CharacterSet(charactersIn: "#*-—>` 　"))
            if clean.isEmpty { continue }
            return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
        }
        return nil
    }

    /// 相对时间（入参**毫秒**）。刻意不用 `RelativeDateTimeFormatter`：
    /// 本文件要能在真值表单文件里编译，也不该依赖系统语言的措辞（App 全中文口径）。
    static func relative(_ ts: Double, now: Double = Date().timeIntervalSince1970 * 1000) -> String {
        let diff = now - ts
        if diff < 60_000 { return "刚刚" }
        if diff < 3_600_000 { return "\(Int(diff / 60_000)) 分钟前" }
        if diff < 86_400_000 { return "\(Int(diff / 3_600_000)) 小时前" }
        if diff < 7 * 86_400_000 { return "\(Int(diff / 86_400_000)) 天前" }
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: Date(timeIntervalSince1970: ts / 1000))
    }
}
