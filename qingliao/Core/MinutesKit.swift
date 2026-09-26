import Foundation

// MARK: - v4.0.x 会话纪要：切片 / 提示词 / 摘要抽取 / 纪要卡（纯 Foundation，可被真值表驱动）
//
// 为什么单独成文件、且零 SwiftUI：
//   · 录音页（MeetingMinutesView）只做「录 → 显示 → 存 → 发卡」这四件事；
//     所有**口径**都收在这里：切片边界、提示词全文、模型啰嗦输出怎么抽干净、
//     卡片 JSON 长什么样、空/超长/失败各说什么话。
//   · 这样本机（无 iOS SDK、无 Xcode）也能用 `scripts/test_minutes.swift` 真的编跑，
//     并且用**真的** AgentCardParser 解一遍卡 —— 口径被改坏会红，不会静默溜到真机。
//
// 三条硬口径（改动前先读这三条）：
//   ① **不丢字**：切片按位置切原文，`chunks(of:).joined() == 原文`（不 trim、不合并空白、不加分隔符）。
//   ② **不整篇重绘**：录音中的分段走 `MinutesSegments` 状态机（已定稿段只增不改），录音页按段渲染。
//   ③ **不静默失败**：空转写 / 超长 / 模型抽不出内容，各有明确判定与文案（`state(of:)` / `extract` → nil）。
//
// 摘要链路复用既有「一次调用拿一段文本」的入口 `QingliaoIntentClient.oneShot`（非流式、120s 上限），
// 所以长转写必须自己切片 map-reduce —— 本文件只产出**提示词**，调用编排在视图里（保持本文件零依赖）。

enum MinutesKit {

    // MARK: - 常量（只在这里定义，别散落到视图/测试里）

    /// 每片上限（用户口径 3~5k 字，取 4k：一次 oneShot 的稳妥输入量）
    static let chunkLimit = 4_000
    /// 切片找边界的窗口：在「片长 * 60%~100%」这段里挑最后一个句末标点，尽量不从句子中间断
    static let boundarySearchPercent = 60
    /// 单次调用（map 每片）的超时。留出后端跑工具循环的余量
    static let mapTimeout: TimeInterval = 100
    /// 汇总（reduce）那一次的超时 —— 输入是各段要点，比单片长，给到接近 oneShot 默认上限
    static let reduceTimeout: TimeInterval = 115
    /// reduce 输入里每份分段要点的上限（N 段拼起来不许无限膨胀）
    static let partialLimit = 1_200
    /// 转写超长硬闸：超过就只给「存原文备忘」，不再整篇送模型
    static let maxTranscriptLength = 60_000
    /// 少于这个字数视为「没识别到内容」（别把一两个语气词送去整理）
    static let minTranscriptLength = 12
    /// 摘要正文上限（模型有时会啰嗦成一篇长文）
    static let maxSummaryLength = 3_000
    /// 抽出来的正文短于这个长度 → 判为「没整理出内容」
    static let minSummaryLength = 20
    /// 卡片里「摘要」字段的截断上限（卡是预览，全文在备忘里）
    static let cardSummaryLimit = 220
    /// 卡片/标题里的主题截断
    static let titleLimit = 20

    /// 四节（顺序即输出顺序，也是抽取时的「小节开头」判据）
    static let sectionOrder = ["主题", "关键结论", "待办事项", "时间线"]
    /// 待办事项节标题（todoCount 只认它）
    static let todoSection = "待办事项"

    /// 必须写进**每一条**提示词的反-思考句（本仓口径：模型只给结果，不给过程）
    static let noThinkingRule = "不要输出思考过程、推理步骤，也不要解释你在做什么、更不要复述原文，直接给整理好的结果"
    /// 四节格式句
    static let sectionsRule = "按「主题 / 关键结论 / 待办事项 / 时间线」四节输出，每节单独起一行写「主题：」「关键结论：」这样的标题；某一节没有内容就写「无」"

    /// 落库来源（MemoItem.sourceLabel/sourceIcon 里对应「会议纪要」）
    static let memoSrc = "meeting"
    /// 备忘正文标题前缀（原文备忘用 rawMemoPrefix）
    static let memoPrefix = "【会议纪要】"
    static let rawMemoPrefix = "【录音原文】"
    /// 卡片固定段
    static let cardTitlePrefix = "会议纪要 · "
    static let cardSubtitle = "现场录音 · 设备端转写"
    static let cardFooter = "已存备忘 · 生活页「备忘」可看全文"
    /// 卡片字段名（顺序 = 卡上顺序；真值表断言这几个 key 一个不少）
    static let cardFieldKeys = ["时长", "字数", "待办", "摘要"]

    // MARK: - 空 / 超长 / 失败态文案与判定

    /// 转写状态：录音页只判一次，判完就按状态给路（不猜、不占位）
    enum TranscriptState: String, Sendable {
        case ok, empty, tooLong
    }

    static let emptyTranscriptHint = "没识别到内容。换个安静点的地方，或把麦克风靠近一点，再来一次。"
    /// 用户自己按了「停止录音」（不是失败）：转写的老本还得留着
    static let cancelledHint = "录音已停下，转写文字还留着。想留原文就点「存原文备忘」，不想留直接关掉。"
    /// 已存备忘的指向（页内展示 + 卡片 footer 同一句）
    static let memoSavedHint = "已存备忘 · 生活页「备忘」里可看全文"
    /// 原文备忘存好后的提示
    static let rawMemoSavedHint = "转写原文已存备忘（来源：会议纪要）"
    static let micDeniedHint = "没拿到麦克风权限：设置 → 轻聊 → 麦克风打开后，点「重试」。"
    static let startFailedHint = "录音没能启动。点「重试」再试一次；仍不行请确认麦克风没被别的 App 占着。"
    /// 机型/系统不支持设备端识别（转写器给的诊断原话是 SpeechTranscriber.isAvailable=false）
    static let unsupportedHint = "这台设备不支持设备端语音识别（需要 iOS 26 且机型支持）。纪要就没法在这儿做了。"
    static let tooLongHint = "录音太长了（上限 6 万字）。先用「存原文备忘」把原文留下，再分段整理。"
    static let emptySummaryHint = "这次没整理出内容。点「重试」再来一次，或用「存原文备忘」把原文留下。"
    static let loginHint = "轻聊还没登录：先打开 App 登录一次，再回来整理。"

    /// 分段整理有失败时（网络/超时），不许整单失败：说明哪几条没整理
    static func partialHint(_ failed: Int) -> String {
        "有 \(failed) 段没能整理（网络或超时），其余段落已汇总。"
    }

    /// 摘要失败文案：带上真实原因（只说「失败了」用户没法自救）
    static func failedHint(_ reason: String?) -> String {
        let r = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return "整理没成功。点「重试」再来一次，或用「存原文备忘」把原文留下。" }
        return "整理没成功：\(r)（可点「重试」，或用「存原文备忘」把原文留下）"
    }

    /// 定稿文本状态判定
    static func state(of transcript: String) -> TranscriptState {
        let t = normalized(transcript)
        if t.count > maxTranscriptLength { return .tooLong }
        guard t.count >= minTranscriptLength else { return .empty }
        // 光有标点/空白不算「识别到内容」
        let meaningful = t.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
        return meaningful ? .ok : .empty
    }

    /// 状态对应的提示语（`.ok` → nil，正常走整理）
    static func hint(for state: TranscriptState) -> String? {
        switch state {
        case .ok: return nil
        case .empty: return emptyTranscriptHint
        case .tooLong: return tooLongHint
        }
    }

    static func isUsableTranscript(_ transcript: String) -> Bool { state(of: transcript) == .ok }

    // MARK: - 文本归一（只在切片/判定前用；切片本身不动原文）

    /// 换行归一 + 去首尾空白 + 连续空行折叠成一行（转写里的空行是随机的，留着只会撑高卡片）
    static func normalized(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        while t.contains("\n\n\n") { t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 定稿全文取更完整的那份：`stop()` 的返回串 与 页面自己累积的分段，取长。
    /// （转写的 volatile 尾巴偶发被重写 → 谁长用谁，不许把用户说过的话弄丢）
    static func bestTranscript(_ a: String, _ b: String) -> String {
        normalized(a).count >= normalized(b).count ? normalized(a) : normalized(b)
    }

    // MARK: - 切片（map 的输入）

    /// 按 `limit` 切片，优先在句末标点处断开；**不丢字**：`joined() == 原文`
    static func chunks(of text: String, limit: Int = chunkLimit) -> [String] {
        guard !text.isEmpty else { return [] }
        guard limit > minSliceLimit else { return [text] }
        var out: [String] = []
        var start = text.startIndex
        let searchFrom = max(1, limit * boundarySearchPercent / 100)
        while text.distance(from: start, to: text.endIndex) > limit {
            guard let hard = text.index(start, offsetBy: limit, limitedBy: text.endIndex) else { break }
            let window = text.index(start, offsetBy: searchFrom, limitedBy: hard) ?? hard
            let cut = lastBoundary(in: text, from: window, to: hard) ?? hard
            out.append(String(text[start..<cut]))
            start = cut
        }
        if start < text.endIndex { out.append(String(text[start...])) }
        return out
    }

    /// 太小的 limit 没有意义（也别让调用方把 limit 传成 0 死循环）
    static let minSliceLimit = 16

    /// 句末标点（切片的「安全断点」）
    static let sentenceEnders: Set<Character> = ["。", "！", "？", "；", "…", "!", "?", ";", "\n"]

    /// [from, to) 里最后一个句末标点**之后**的位置；没有 → nil（调用方硬切）
    private static func lastBoundary(in text: String, from: String.Index, to: String.Index) -> String.Index? {
        var cursor = to
        while cursor > from {
            cursor = text.index(before: cursor)
            if sentenceEnders.contains(text[cursor]) { return text.index(after: cursor) }
        }
        return nil
    }

    /// 是否走 map-reduce（超过一片就要）
    static func needsMapReduce(_ text: String) -> Bool { text.count > chunkLimit }

    // MARK: - 提示词（中文；每条都带 noThinkingRule）

    /// 短转写：一次调用直接出四节纪要
    static func singlePrompt(_ transcript: String) -> String {
        """
        你是会议纪要助手。下面是现场录音的设备端转写（可能有识别错字、口语重复、口误），请整理成一份会议纪要。
        要求：
        1. \(noThinkingRule)；
        2. \(sectionsRule)；
        3. 待办事项逐条一行、以「- 」开头，尽量保留负责人与时间，转写里没有就写「未指明」；
        4. 时间线按时间先后排列，只写转写里真的出现过的信息，不要编；
        5. 输出要短：每条一行，不要开场白（「好的」「以下是」）、不要结尾寒暄。
        转写正文：
        \(transcript)
        """
    }

    /// 长转写：第 index+1/total 片（每片各整理一次）
    static func mapPrompt(index: Int, total: Int, chunk: String) -> String {
        """
        你是会议纪要助手。下面是**同一次**现场录音转写的第 \(index + 1)/\(total) 段（按顺序切分，段内可能有识别错字）。
        只整理这一段，不要猜测其它段落的内容。
        要求：
        1. \(noThinkingRule)；
        2. \(sectionsRule)；
        3. 待办事项逐条一行、以「- 」开头，保留负责人与时间，转写里没有就写「未指明」；
        4. 本段没有的内容写「无」，不要编；
        5. 不要开场白、不要复述原文。
        本段转写：
        \(chunk)
        """
    }

    /// 长转写：把各段要点合并成最终纪要（reduce）
    static func reducePrompt(partials: [String]) -> String {
        let body = partials.enumerated()
            .map { "【第 \($0.offset + 1) 段要点】\n\(brief($0.element))" }
            .joined(separator: "\n\n")
        return """
        你是会议纪要助手。下面是**同一场会议**分段整理出的 \(partials.count) 份要点，请合并成一份最终纪要。
        要求：
        1. \(noThinkingRule)；
        2. 只输出四节：\(sectionOrder.joined(separator: " / "))，某节没有内容写「无」；
        3. 合并重复项；同一件事在多段里都提到时只留一条更完整的说法；互相冲突又不确定的不要写；
        4. 待办事项合并同义条目，逐条一行、以「- 」开头，保留负责人与时间，没有就写「未指明」；
        5. 时间线按时间先后排列；
        6. 直接给正文：不要「好的」「以下是纪要」这类开场，不要结尾寒暄。
        分段要点：
        \(body)
        """
    }

    /// 单份分段要点的输入截断（reduce 的输入不能无限膨胀）
    static func brief(_ text: String, limit: Int = partialLimit) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }

    // MARK: - 调用计划（视图照着发请求；真值表也断言这个）

    /// 要依次发的提示词。1 条 = 直接整理；≥2 条 = 先分段 map，最后再 reduce 汇总一次
    struct SummaryPlan: Equatable, Sendable {
        let mapPrompts: [String]
        var needsReduce: Bool { mapPrompts.count > 1 }
        /// 期望的模型调用次数（含最后的 reduce）
        var askCount: Int { needsReduce ? mapPrompts.count + 1 : mapPrompts.count }
    }

    static func plan(for transcript: String) -> SummaryPlan {
        let pieces = chunks(of: normalized(transcript))
        guard pieces.count > 1 else {
            return SummaryPlan(mapPrompts: [singlePrompt(pieces.first ?? "")])
        }
        return SummaryPlan(mapPrompts: pieces.enumerated().map {
            mapPrompt(index: $0.offset, total: pieces.count, chunk: $0.element)
        })
    }

    // MARK: - 摘要抽取（模型输出可能带闲聊/思考过程/代码围栏）

    /// 从模型原文里稳态抽出四节正文。抽不到（太短 / 没内容）→ nil，调用方按失败处理
    static func extract(_ raw: String) -> String? {
        var text = stripFences(raw)
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = dropThinkingBlocks(text)
        text = cutLeadingChatter(text)
        text = cutTrailingChatter(text)
        text = normalized(text)
        guard text.count >= minSummaryLength, containsHan(text) else { return nil }
        return clamp(text, to: maxSummaryLength)
    }

    /// 去掉 ``` 围栏行（模型爱把纪要包进代码块；围栏行本身不是内容）
    static func stripFences(_ raw: String) -> String {
        raw.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
    }

    // 模型思考块的标记（用拼接写法定义：本仓多处源码/注释里写过尖括号字面量容易看串）
    static let thinkingOpenTag = "<" + "think" + ">"
    static let thinkingCloseTag = "</" + "think" + ">"
    static let thinkingEndTag = "<" + "|end_of_thinking" + "|>"

    /// 去掉思考块（少数模型会带）；未闭合 → 后面全是思考，整段丢掉
    static func dropThinkingBlocks(_ text: String) -> String {
        var t = text
        while let open = t.range(of: thinkingOpenTag) {
            let after = open.upperBound
            let closes = [thinkingCloseTag, thinkingEndTag].compactMap { t.range(of: $0, range: after..<t.endIndex) }
            guard let close = closes.min(by: { $0.lowerBound < $1.lowerBound }) else {
                t.removeSubrange(open.lowerBound..<t.endIndex)
                break
            }
            t.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return t
    }

    /// 砍掉正文之前的引导语/思考段：有四个小节标题 → 从第一个标题那行开始；
    /// 没有标题（模型没照格式来）→ 只剥掉开头的寒暄行
    static func cutLeadingChatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        if let idx = lines.firstIndex(where: { isSectionHead($0) }) {
            return lines[idx...].joined(separator: "\n")
        }
        // 标题与思考挤在同一行：在文本里找最早的那个「前面是分隔符」的小节标题
        if let r = firstSectionRange(in: text) { return String(text[r.lowerBound...]) }
        var start = 0
        while start < lines.count {
            let t = lines[start].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || isChatterLine(t) { start += 1; continue }
            break
        }
        return lines[start...].joined(separator: "\n")
    }

    /// 文本里最早的小节标题位置；且标题前一个字符必须是分隔符（避免命中正文中间的同名词）
    static func firstSectionRange(in text: String) -> Range<String.Index>? {
        let separators: Set<Character> = ["\n", "。", "！", "？", "；", "：", ":", "，", " ", "　", ")", "）", "\"", "”"]
        var best: Range<String.Index>? = nil
        for label in sectionOrder {
            var search = text.startIndex..<text.endIndex
            while let r = text.range(of: label, range: search) {
                let okAtHead = r.lowerBound == text.startIndex
                let okAfter = !okAtHead && separators.contains(text[text.index(before: r.lowerBound)])
                if okAtHead || okAfter {
                    if best == nil || r.lowerBound < best!.lowerBound { best = r }
                    break
                }
                guard r.upperBound < text.endIndex else { break }
                search = r.upperBound..<text.endIndex
            }
        }
        return best
    }

    /// 砍掉结尾寒暄（只在小节格式成立时做；否则可能把用户的结论当寒暄删掉）
    static func cutTrailingChatter(_ text: String) -> String {
        guard text.components(separatedBy: "\n").contains(where: { isSectionHead($0) }) else { return text }
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last {
            let t = last.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { lines.removeLast(); continue }
            if isClosingLine(t) { lines.removeLast(); continue }
            break
        }
        return lines.joined(separator: "\n")
    }

    /// 小节标题行（容忍 `**主题**：` / `## 主题` / `- 主题：` 这些写法）
    static func isSectionHead(_ line: String) -> Bool {
        var t = line.trimmingCharacters(in: .whitespaces)
        while let f = t.first, "#*-—•>　 ".contains(f) { t.removeFirst() }
        return sectionOrder.contains { t.hasPrefix($0) }
    }

    /// 只剩标点的空壳行也算空
    private static func isBlankish(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

    static let chatterHeads = ["好的", "好，", "收到", "以下是", "下面是", "我来", "这是", "已整理",
                               "整理如下", "抱歉", "思考", "推理", "分析", "thinking", "reasoning",
                               "分析过程", "思路"]
    static let closingHeads = ["以上", "希望", "如需", "如还", "需要我", "还需要", "要不要", "请确认",
                               "感谢", "谢谢", "祝", "注意：以上"]

    /// 引导句：以 chatterHeads 开头，或「…：」这种短引导（且不是小节标题）
    static func isChatterLine(_ line: String) -> Bool {
        if isSectionHead(line) { return false }
        let lower = line.lowercased()
        if chatterHeads.contains(where: { line.hasPrefix($0) || lower.hasPrefix($0.lowercased()) }) { return true }
        if (line.hasSuffix("：") || line.hasSuffix(":")), line.count <= 40 { return true }
        return false
    }

    /// 结尾寒暄：短行 + 以 closingHeads 开头（长行一律当正文，防误删结论）
    static func isClosingLine(_ line: String) -> Bool {
        guard line.count <= 32 else { return false }
        return closingHeads.contains { line.hasPrefix($0) }
    }

    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    /// 硬截断（带省略号）——卡片字段/摘要正文的上限
    static func clamp(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" : text
    }

    // MARK: - 章节取值 / 主题 / 待办数

    /// 取某节正文（从该节标题行之后，到下一个已知小节标题之前）。没有该节 → nil
    static func sectionBody(_ label: String, in summary: String) -> String? {
        let lines = summary.components(separatedBy: "\n")
        guard let head = lines.firstIndex(where: { isSectionHead($0) && headLabel($0) == label }) else { return nil }
        var body: [String] = []
        // 标题行本身可能带「主题：xxx」→ 冒号后的那段也算正文
        let headRest = tailAfterColon(lines[head])
        if !headRest.isEmpty { body.append(headRest) }
        for line in lines[(head + 1)...] {
            if isSectionHead(line), headLabel(line) != label { break }
            body.append(line)
        }
        return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 该行的节名（去掉 #*- 与冒号后的内容）
    static func headLabel(_ line: String) -> String? {
        var t = line.trimmingCharacters(in: .whitespaces)
        while let f = t.first, "#*-—•>　 ".contains(f) { t.removeFirst() }
        return sectionOrder.first { t.hasPrefix($0) }
    }

    static func tailAfterColon(_ line: String) -> String {
        guard let r = line.firstIndex(where: { $0 == "：" || $0 == ":" }) else { return "" }
        return String(line[line.index(after: r)...]).trimmingCharacters(in: .whitespaces)
    }

    /// 待办条数（「无 / 暂无」→ 0；小节缺失 → 0）
    static func todoCount(of summary: String) -> Int {
        guard let body = sectionBody(todoSection, in: summary) else { return 0 }
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || noneWords.contains(t) { return 0 }
        return t.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isListItem($0) }
            .count
    }

    static let noneWords: Set<String> = ["无", "暂无", "无。", "无、", "没有", "无待办", "暂无待办", "（无）", "(无)", "—", "-", "–"]

    /// 清单行判据（- / * / · / • / □ / ☐ / 1. / 1、 / 1) ）
    static func isListItem(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let markers = ["- ", "* ", "+ ", "· ", "• ", "□ ", "☐ ", "✅ ", "-", "—"]
        if markers.contains(where: { line.hasPrefix($0) }) {
            return line.count > 1
        }
        if let first = line.first, first.isNumber, line.count >= 3,
           let second = line.dropFirst().first, ["、", ".", ")", "）"].contains(String(second)) {
            return true
        }
        return false
    }

    /// 主题：优先「主题：」那行，其次第一行非空内容（标题里要短，所以截断）
    static func theme(of summary: String) -> String {
        if let body = sectionBody("主题", in: summary) {
            let first = body.components(separatedBy: "\n")
                .first { !isBlankish($0) }
                .map { cleanInline($0) } ?? ""
            if !first.isEmpty { return clamp(first, to: titleLimit) }
        }
        let first = summary.components(separatedBy: "\n")
            .first { !isBlankish($0) }
            .map { cleanInline(stripLabelPrefix($0)) } ?? ""
        return clamp(first, to: titleLimit)
    }

    /// 去掉行首的节名前缀（「关键结论：xxx」→「xxx」）：模型没按格式来时，标题别带着节名
    static func stripLabelPrefix(_ line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        for label in sectionOrder where t.hasPrefix(label) { return tailAfterColon(t) }
        return t
    }

    /// 去掉行内 markdown 装饰（两端 `**加粗**` / `#` / 反引号）——卡片标题里不该带这些
    static func cleanInline(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        while let f = t.first, "*#`*".contains(f) { t.removeFirst() }
        while let l = t.last, "*#`".contains(l) { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 纪要本体（页面展示 / 备忘 / 卡片 共用一份数据）

    struct Summary: Equatable, Sendable {
        let theme: String
        let body: String
        let todoCount: Int
        let duration: TimeInterval
        let charCount: Int
    }

    /// 从模型原文组装纪要；抽不出内容 → nil（页面按失败态给「重试 / 存原文备忘」）
    static func summary(raw: String, duration: TimeInterval, charCount: Int) -> Summary? {
        guard let body = extract(raw) else { return nil }
        return Summary(theme: theme(of: body), body: body, todoCount: todoCount(of: body),
                       duration: duration, charCount: charCount)
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h) 小时 \(m) 分" }
        if m > 0 { return s == 0 ? "\(m) 分" : "\(m) 分 \(s) 秒" }
        return "\(s) 秒"
    }

    /// 计时器文案（录音页顶上：00:12 / 1:02:03）
    static func clockText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    static func countText(_ n: Int) -> String { "\(grouped(max(0, n))) 字" }

    static func todoText(_ n: Int) -> String { n > 0 ? "\(n) 项" : "无待办" }

    /// 千分位（不用 NumberFormatter：不同 locale 的分组符不一样，真值表要跨机器稳定）
    static func grouped(_ n: Int) -> String {
        var s = String(max(0, n))
        var out = ""
        while s.count > 3 {
            out = "," + String(s.suffix(3)) + out
            s = String(s.dropLast(3))
        }
        return s + out
    }

    /// 存备忘的正文（带主题与三个数值，全文在 push 的未截断版）
    static func memoText(_ s: Summary) -> String {
        """
        \(memoPrefix)\(s.theme)
        时长 \(durationText(s.duration))｜字数 \(countText(s.charCount))｜待办 \(todoText(s.todoCount))
        \(s.body)
        """
    }

    /// 存原文备忘（失败/超长/取消时的退路）
    static func rawMemoText(_ transcript: String, duration: TimeInterval = 0) -> String {
        let t = normalized(transcript)
        let head = duration > 0 ? "\(rawMemoPrefix)\(durationText(duration))\(countText(t.count))\n" : "\(rawMemoPrefix)\(countText(t.count))\n"
        return head + t
    }

    // MARK: - 纪要卡（```ql-card 围栏 + type=result → AgentCardParser → AgentResultCard）

    /// 卡片文本。`summary` 为空 / 摘要为空 → ""（**空转写不产卡**）
    static func cardText(_ s: Summary) -> String {
        guard !s.theme.isEmpty else { return "" }
        let body = clamp(s.body, to: cardSummaryLimit)
        guard body.count >= minSummaryLength else { return "" }
        let payload: [String: Any] = [
            "type": "result",
            "title": cardTitlePrefix + s.theme,
            "subtitle": cardSubtitle,
            "status": ["text": "已生成", "tone": "ok"],
            "fields": [
                ["key": "时长", "value": durationText(s.duration)],
                ["key": "字数", "value": countText(s.charCount)],
                ["key": "待办", "value": todoText(s.todoCount)],
                ["key": "摘要", "value": body],
            ],
            "footer": cardFooter,
        ]
        // sortedKeys：同一条纪要每次序列化结果一致（落库/比对才稳定）
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return "```ql-card\n" + json + "\n```"
    }

    /// 录音中的分段状态机（**按段渲染**的数据源：已定稿段只增不改，最后一段是会被重写的尾巴）
    ///
    /// 页面只渲染 `closed` 的每一段 + `open` 一段 —— 绝不 `Text(整篇 liveText)`：
    /// 一小时的会议转写有几万字，整篇作为一个 Text 每帧重建 = 打字卡死。
    struct MinutesSegments: Equatable, Sendable {
        /// 已定稿段（会话内只增不减：转写被重写/取消回填都不许抹掉它）
        private(set) var closed: [String]
        /// 正在说的尾巴（转写反复重写这一段）
        private(set) var open: String

        init(closed: [String] = [], open: String = "") {
            self.closed = closed
            self.open = open
        }

        static let empty = MinutesSegments()

        var text: String { closed.joined() + open }
        var charCount: Int { text.count }
        var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 推进分段状态机。三条口径：
    ///   ① 空串更新不动状态（`cancel()` 会把 liveText 回填成 baseline="" —— 不许抹掉已转写内容）
    ///   ② 新文本以「已定稿段」开头 → 正常增长：把「后面还有字的句末边界」之前的全部定稿
    ///   ③ 不认识的新串（转写被整体重写）→ 自愈重算，但**已定稿段永不丢**（新串比旧内容短时直接保留）
    static func advance(_ state: MinutesSegments, with text: String) -> MinutesSegments {
        guard !text.isEmpty else { return state }
        let closedText = state.closed.joined()
        guard text.hasPrefix(closedText) else {
            // ③ 新串被旧内容包含（更短的旧前缀）→ 保留已定稿段；否则整串当新尾巴（不丢已定稿段）
            if closedText.hasPrefix(text) { return state }
            return MinutesSegments(closed: state.closed, open: text)
        }
        let rest = String(text.dropFirst(closedText.count))
        var closed = state.closed
        guard let cut = lastSettledBoundary(in: rest) else {
            return MinutesSegments(closed: closed, open: rest)
        }
        closed.append(String(rest[rest.startIndex..<cut]))
        return MinutesSegments(closed: closed, open: String(rest[cut...]))
    }

    /// rest 里「后面还有内容」的最后一个句末边界之后的位置（末尾那个标点可能是 volatile 的，不定稿）
    private static func lastSettledBoundary(in rest: String) -> String.Index? {
        guard rest.count >= 2 else { return nil }
        var cursor = rest.endIndex
        let end = rest.endIndex
        while cursor > rest.startIndex {
            cursor = rest.index(before: cursor)
            guard sentenceEnders.contains(rest[cursor]) else { continue }
            let after = rest.index(after: cursor)
            if after < end { return after }   // 后面还有字 → 这句已说完
        }
        return nil
    }

    /// 整篇一次算完（开页/恢复时用；与 above 同口径）
    static func segments(of text: String) -> MinutesSegments {
        advance(.empty, with: text)
    }
}
