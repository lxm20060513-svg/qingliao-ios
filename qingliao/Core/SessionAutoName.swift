import Foundation

// MARK: - v3.9.90 会话自动命名 · 纯逻辑（用户拍板口径 3a）
//
// 产品口径（用户拍板，本文件只服务这两条）：
//   ① 会话自动命名 = **首条消息后起一次名**；
//   ② **用户手动改过名字的会话，之后不再自动改名**。
//
// 为什么单独一个文件、且只 import Foundation：
//   「触发」与「落库」的接线在 ChatStore.swift（那边有 auth、有落库的 FIFO 串行链、有 title 的读写），
//   而「该不该起名 / 模型输出怎么洗成标题 / 这个线上标题是不是我们自己写的」是**纯判断**。
//   纯判断放这里 = 本机没有 Xcode、没有 iOS SDK 也能用 swiftc 编跑真值表
//   （scripts/ql_autoname/truth_table_autoname.swift，做法同 Core/LaunchSession.swift）。
//   留在 ChatStore 里就只能靠人眼核对，而本仓的历史已经反复证明「靠人眼核对的口径」必漂移。
//
// 三条硬约束（改这里之前先读）：
//   ① 起名失败 / 超时 / 输出不可用 → **静默回落**「首条消息前 30 字」（既有口径）。
//      绝不阻塞首条消息发送、绝不弹错、绝不写空标题（空标题会让会话列表显示成「未命名」）。
//   ② App 自己写的标题只有两个形态：30 字兜底、自动命名结果。两者都不是 = 有人改过
//      （会话列表的「重命名」/ 网页端改名）→ 记为「用户手动改过」，不再自动改。
//   ③ 投递壳会话（`ChatStore.deliverySessionId`）标题由后端锁定 → 永不自动命名。

enum SessionAutoName {

    // MARK: - 常量

    /// 兜底标题长度：与既有实现逐字一致（原来是 `String(m.content.prefix(30))`）。
    /// 这里收成**唯一真源**：老会话升级后标题不变；自动命名失败回落的值 = 同一个函数算出。
    static let fallbackLength = 30

    /// 自动标题长度上限：会话列表一行放得下（中文 ≈12 字；英文按字符数算，也够用）
    static let maxTitleLength = 12

    /// 送模型的用户首条消息上限：起名只要「话题」，不要全文。
    /// 顺手挡住「把一篇文章粘成首条消息」→ 起名请求被撑成一次又慢又贵的调用。
    static let inputLimit = 400

    /// 系统提示词：只要标题本身。
    /// 为什么写这么死：模型很容易回「好的，这个会话可以命名为「…」」或者写一段解释。
    /// 提示词先约束，`sanitize` 再兜一层——两层都要，提示词挡不住带思考链的模型。
    static let systemPrompt = """
    你是会话命名助手。根据用户的第一条消息，给这次对话起一个简短标题。
    要求：用用户所用的语言，不超过 12 个字；只输出标题本身，不要引号、不要书名号、不要句号、不要换行、不要解释。
    """

    /// 送模型的用户侧文本
    static func prompt(firstMessage: String) -> String {
        let t = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = t.count > inputLimit ? String(t.prefix(inputLimit)) + "…" : t
        return "用户的第一条消息：\n\(clipped)"
    }

    // MARK: - 兜底标题（既有口径）

    /// 首条消息的 30 字兜底标题
    static func fallbackTitle(_ content: String) -> String {
        String(content.prefix(fallbackLength))
    }

    /// 这条首条消息值不值得起名。
    /// 纯图片 / 纯语音 / 纯符号起不出名字（只会得到「图片」这类没信息量的标题），
    /// 那就别花这次请求——直接留 30 字兜底。
    static func isNameable(_ content: String) -> Bool {
        var t = content
        for ph in placeholders { t = t.replacingOccurrences(of: ph, with: " ") }
        // 「像话的字」（中英文数字）至少 2 个：一个字母、一个标点起名只会得到空转
        return t.filter { $0.isLetter || $0.isNumber }.count >= 2
    }

    /// 图片 / 语音 / 文件占位（App 侧降级形态，见 ChatStore.historyPayload / messagesPayload）
    private static let placeholders = ["[图片]", "![图片]", "[语音]", "[文件]", "[视频]"]

    // MARK: - 模型输出 → 标题

    /// 清洗模型输出 → 可用标题；返回 nil = 不可用（调用方静默回落 30 字兜底）
    ///
    /// 为什么要洗：这条链路拿回来的是**模型文本**，不是结构化字段：
    ///   · 带思考链的模型把推理写在前面，结论在**最后**一行；
    ///   · 普通模型爱加引号 / 书名号 / 句号 /「标题：」前缀，或先说一句「好的，我来…」；
    ///   · 失败时还会回「抱歉，我无法…」这类话（照写进会话列表非常难看）。
    /// 顺序：切行 → 逐行 clean → 挑「像标题的」候选 → 取**最后一个**候选 → 超长截断。
    /// 为什么取最后一个：思考链的结论在末尾；而普通模型单行输出时前后是同一行（真值表两侧都钉了）。
    static func sanitize(_ raw: String) -> String? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { clean(String($0)) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        // 「像标题的行」= 2 倍上限以内；一行几十个字的只可能是解释句，不当候选
        let titled = lines.filter { $0.count <= maxTitleLength * 2 }
        let picked = titled.last ?? lines[lines.count - 1]
        return truncate(picked, to: maxTitleLength)
    }

    /// 截断到 n 字。
    /// 多一步「退到空格」：中文与英文混排（「如何用 Python 批量重命名…」）硬切会得到
    /// 「如何用 Python 批」这种半截词；只在**切点前 1 个字**处是空格时才退（避免把
    /// 「关于 NAS 磁盘满了的排查」误退成「关于 NAS」）。
    static func truncate(_ s: String, to n: Int) -> String {
        guard s.count > n else { return s }
        let cut = String(s.prefix(n))
        guard cut.count == n else { return cut }
        var out = cut
        if let sp = cut.lastIndex(of: " "),
           cut.distance(from: cut.startIndex, to: sp) >= n - 2 {
            out = String(cut[cut.startIndex..<sp])
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 单行 → 候选标题；不可用返回 ""
    private static func clean(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") { return "" }   // 代码围栏
        // 行内装饰与列表/编号前缀（`## 标题`、`- 标题`、`1. 标题`、`1、标题`）——模型很爱加
        while let f = t.first, "#>*-·•+=~".contains(f) {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        if let r = numberedPrefixEnd(t) { t = String(t.dropFirst(r)).trimmingCharacters(in: .whitespaces) }
        // 「标题：xxx」「会话标题: xxx」这类标签前缀
        for label in labels where t.hasPrefix(label) {
            t = String(t.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        // 首尾包裹符号（引号 / 书名号 / 括号 / 反引号）
        while let f = t.first, wrappers.contains(f) { t.removeFirst() }
        while let l = t.last, wrappers.contains(l) { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        // 结尾标点：会话列表里一排句号很脏
        while let l = t.last, tailPunctuation.contains(l) { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "" }
        // 一眼就是「话」而不是标题的（这几条与长度无关：短到 4 个字也是话）
        if hardReject.contains(where: { t.contains($0) }) { return "" }
        // 软判据：长句里出现「抱歉/无法/请提供」这类多半是解释或拒答；
        // 但短句仍可能是正经标题（如「无法登录」）→ 只在超上限时才判死。
        if t.count > maxTitleLength, softReject.contains(where: { t.contains($0) }) { return "" }
        // 纯符号/表情不成标题
        guard t.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return t
    }

    /// “1.” / “1、” / “1)” 这类编号前缀的长度；没有返回 nil
    private static func numberedPrefixEnd(_ s: String) -> Int? {
        var digits = 0
        for ch in s {
            if ch.isNumber { digits += 1; continue }
            if digits > 0, ".、)）:：".contains(ch) { return digits + 1 }
            return nil
        }
        return nil
    }

    private static let labels = ["会话标题：", "会话标题:", "会话命名：", "标题：", "标题:", "名字：", "名字:", "名称：", "名称:", "Title:", "title:"]
    private static let wrappers: Set<Character> = ["\"", "“", "”", "‘", "’", "'", "`", "「", "」", "『", "』", "《", "》", "【", "】", "(", ")", "（", "）"]
    private static let tailPunctuation: Set<Character> = ["。", ".", "!", "！", "?", "？", ",", "，", ";", "；", ":", "：", "、", " ", "…"]
    /// 与长度无关的硬拒答/元话（出现即不是标题）
    private static let hardReject = ["语言模型", "作为AI", "作为一个AI", "无法命名", "无法起名", "无法为这个会话", "请提供更多", "需要更多信息"]
    /// 长句里出现即判定为解释（短句仍可能是正经标题）
    private static let softReject = ["抱歉", "无法", "不能", "请提供", "需要更多", "unable", "I cannot"]

    // MARK: - 两个判定（真值表逐条钉死）

    /// 该不该给这个会话起名。
    /// 调用方只负责提供事实，判断全在这里 —— 这样这条产品口径是可测的，不是散落在
    /// ChatStore 各分支里靠人眼维护的 if。
    /// - Parameters:
    ///   - messageCount: 本次落库快照的消息条数（只认 1 = 首条消息刚落库）
    ///   - firstIsUser: 那唯一一条是不是用户发的（推送/系统注入的 assistant 不算）
    ///   - firstMessageNameable: 内容值不值得起名（见 isNameable）
    ///   - alreadyAutoNamed: 这个会话已经自动命名过（本地持久化标记，含跨启动）
    ///   - userRenamed: 这个会话用户手动改过名字（本地持久化标记）
    ///   - isDeliverySession: 是不是投递壳会话（标题后端锁定）
    static func shouldFire(messageCount: Int,
                           firstIsUser: Bool,
                           firstMessageNameable: Bool,
                           alreadyAutoNamed: Bool,
                           userRenamed: Bool,
                           isDeliverySession: Bool) -> Bool {
        guard messageCount == 1, firstIsUser else { return false }   // 只认「首条消息落库」这一刻
        guard !isDeliverySession else { return false }               // ③ 投递壳标题锁定
        guard !alreadyAutoNamed else { return false }                // ① 一个会话只起一次
        guard !userRenamed else { return false }                     // ② 用户改过 → 不再自动改
        return firstMessageNameable
    }

    /// 起名结果该不该落地。请求是异步的，回来时世界可能已经变了 —— 四个「不」都要挡住，
    /// 宁可不写（留 30 字兜底），也不许拿一个过期结果去覆盖用户的改名或另一段对话。
    /// - Parameters:
    ///   - isSameSession: 当前打开的仍是发起命名那个会话
    ///   - currentTitle: 当前内存里的标题（用户可能刚在会话列表改过）
    ///   - snapshotFallback: 发起命名时写入的 30 字兜底标题
    ///   - currentFirstUser: 当前会话的首条用户消息内容
    ///   - snapshotFirstUser: 发起命名时的首条用户消息内容（同一 id 被清空后换了话题的判据）
    ///   - userRenamed: 用户手动改过名字
    static func shouldApply(isSameSession: Bool,
                            currentTitle: String,
                            snapshotFallback: String,
                            currentFirstUser: String,
                            snapshotFirstUser: String,
                            userRenamed: Bool) -> Bool {
        guard isSameSession else { return false }            // 已切走：结果丢弃（旧快照写库会盖掉新消息）
        guard !userRenamed else { return false }
        guard currentTitle == snapshotFallback else { return false }      // 标题被改过 → 不抢
        guard currentFirstUser == snapshotFirstUser else { return false } // 话题换了 → 旧名字配新消息
        return true
    }

    /// 线上这个标题是不是「App 自己写的」（30 字兜底 或 自动命名结果）。
    /// 用它在**没有事件**的地方反推「用户手动改过名」：会话列表的重命名（SessionsView.rename）
    /// 与网页端改名都只是把 title 写进后端，App 侧收不到任何回调 —— 唯一可靠的证据就是
    /// 「这个标题既不是我们的兜底、也不是我们的命名结果」。
    static func isAppTitle(_ title: String, autoNamed: String?, fallback: String) -> Bool {
        // 比之前先 trim：后端/网页端可能顺手把首尾空白去掉，那不算「人改的名字」
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }                 // 空标题不是「人改的名字」（列表里改不出空名）
        if let autoNamed, t == autoNamed.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        return t == fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
