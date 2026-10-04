import Foundation

// MARK: - v4.0.42 待做池 ①：提问推荐「猜你想问」纯逻辑
//
// 后端 `POST /api/agent/suggest_questions`（suggest_api.build_questions）返回
// `{"ok":true,"questions":["…","…","…"]}`，0~3 条；**空数组是合法成功**（宁缺勿滥）。
//
// 本文件只放纯逻辑（解析 + 口径判定 + exclude 累积），不碰网络与视图，
// 这样「候选为空不渲染 / 点候选不重复插消息 / 换一批是替换不是追加」这些
// 口径能被单测钉住，而不是只靠真机肉眼。
enum FollowUpSuggest {

    /// 后端返回 questions 数组时的清洗口径（与后端 suggest_api._normalize 对齐）：
    /// · 剔空串 / 剔纯空白
    /// · 去重（与后端同款：去首尾空白与句末标点后比较）
    /// · 截断到 `maxCount`（后端上限 3）
    /// 注意：这里**不再**做「是不是问句」的判定 —— 后端已用更严格的问句闸门过一遍，
    /// App 再判一次只会把后端放过的候选误杀（两道闸门口径必须只有一处）。
    static func parseQuestions(_ raw: Any?, maxCount: Int = 3) -> [String] {
        // 上限 ≤0 直接返空（否则会因「先 append 后判上限」多吐一条 —— 反向自证抓到过）
        guard maxCount > 0 else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for item in (raw as? [Any] ?? []) {
            guard let s = item as? String else { continue }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let k = dedupKey(t)
            guard !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(t)
            if out.count >= maxCount { break }
        }
        return out
    }

    /// 去重键：与后端 suggest_api._key 同口径（去首尾空白 + 句末标点）
    static func dedupKey(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, "？?。.!！ 　".contains(last) {
            t.removeLast()
        }
        return t
    }

    /// 该不该渲染候选区：**空数组 / 数量不足 1 条 ⇒ 整区不渲染**（后端已守 MIN_Q=2，
    /// App 这道只是防御：ok:false、字段缺失、字段类型错一律静默无该区，不出声、不占位）。
    static func shouldRender(_ questions: [String]) -> Bool {
        !questions.isEmpty
    }

    /// 「换一批」的 exclude：已看过的候选 ∪ 用户已问过的原文（近若干条）。
    /// `askedTexts` 由调用方给（通常是最近几条 user 消息原文），这里只做口径收口与截断：
    /// · 已问过的原文与候选共用同一批槽位（模型 prompt 里就是同一个 exclude 位）
    /// · 去重 + 单条截断 + 总条数上限（后端只取前 8 条，App 侧多给无益反增 token）
    static func excludeBatch(previous: [String], askedTexts: [String], maxCount: Int = 8) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in (previous + askedTexts) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let k = dedupKey(t)
            guard !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(String(t.prefix(60)))
            if out.count >= maxCount { break }
        }
        return out
    }

    /// 近 N 条用户原文（作为 exclude 输入）。`roles`/`contents` 分开传以便单测，
    /// 实际调用方传 `chat.messages` 的 role/content。
    static func recentUserTexts(roles: [String], contents: [String], limit: Int = 6) -> [String] {
        var out: [String] = []
        for i in stride(from: min(roles.count, contents.count) - 1, through: 0, by: -1) {
            guard roles[i] == "user" else { continue }
            let t = contents[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            out.append(String(t.prefix(60)))
            if out.count >= limit { break }
        }
        return out
    }

    /// 后端路径（单一真源，护栏钉死——改了要同步 nginx/lucky/relay，故禁散落字面量）
    static let endpoint = "/api/agent/suggest_questions"
}