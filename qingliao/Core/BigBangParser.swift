import Foundation

// MARK: - BigBang 分词器（复刻锤子"大爆炸"语义分词）
// 中文：CFStringTokenizer（ICU 词典分词，按词切分）
// 英文/数字/URL：ICU 按词切分
// 标点：独立成块（便于选择）；空白：跳过

struct BigBangWord: Identifiable {
    let id: Int
    let text: String
}

enum BigBangParser {
    /// 将文本按语义拆成词块（默认限制 5000 字，防超长消息卡 UI；可通过 maxChars 自定义）
    static func tokenize(_ text: String, maxChars: Int = 5000) -> [BigBangWord] {
        let ns = text as NSString
        let maxLen = min(ns.length, maxChars)
        var words: [BigBangWord] = []
        var cursor = 0

        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, text as CFString,
            CFRange(location: 0, length: ns.length),
            kCFStringTokenizerUnitWord,
            Locale(identifier: "zh_CN") as CFLocale
        ) else {
            // CFStringTokenizerCreate 返回 nil（内存压力/输入异常），降级为逐字拆分
            // v-review fix：按 Unicode 标量遍历（勿用 UTF-16 ns.character(at:)——emoji 等代理对
            // 会被拆成两个孤立码元显示乱码）
            guard !text.isEmpty else { return [] }
            var fallback: [BigBangWord] = []
            var used = 0
            for scalar in text.unicodeScalars {
                if used >= maxLen { break }
                fallback.append(BigBangWord(id: fallback.count, text: String(scalar)))
                used += 1
            }
            return fallback
        }

        func appendGap(from: Int, to: Int) {
            guard to > from else { return }
            let gap = ns.substring(with: NSRange(location: from, length: to - from))
            var i = 0
            for scalar in gap.unicodeScalars {
                let ch = String(scalar)
                if !scalar.properties.isWhitespace {
                    words.append(BigBangWord(id: words.count, text: ch))
                }
                i += 1
            }
        }

        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let loc = r.location
            let len = r.length
            if loc >= maxLen { break }
            // 词前的空隙（标点/空白）
            appendGap(from: cursor, to: loc)
            let word = ns.substring(with: NSRange(location: loc, length: len))
            words.append(BigBangWord(id: words.count, text: word))
            cursor = loc + len
        }
        // 尾部空隙
        appendGap(from: cursor, to: maxLen)

        return words.isEmpty ? [BigBangWord(id: 0, text: text)] : words
    }
}
