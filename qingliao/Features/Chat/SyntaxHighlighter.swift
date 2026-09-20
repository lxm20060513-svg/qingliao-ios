import Foundation
import UIKit

/// v3.4.x 代码块语法高亮：按语言词法把代码 token 着色为 NSAttributedString。
/// 实现取舍：用 NSRegularExpression 预编译匹配 关键字/字符串/注释/数字 四类 token，
/// 不引第三方高亮库（无网络/无依赖，App 侧加载零成本）；对未知语言返回纯等宽字。
///
/// 期望效果：代码块从"一片灰字"变成"关键字蓝/字符串绿/注释灰/数字橙"的可读排版。
/// 支持的 token：行注释、块注释、字符串、数字、常见关键字。
///
/// v3.9.41（SR44）：标 @MainActor——本类型现在带了一份高亮结果缓存（可变静态），
/// 调用方只有 SwiftUI 视图（ChatComponents 的代码块分支），全部在主线程。
@MainActor
enum SyntaxHighlighter {

    /// 已支持高亮的语言集合（fenceLanguage 规范化后的小写别名）
    static func supports(_ lang: String) -> Bool {
        aliases(lang) != nil
    }

    /// 规范化语言别名 → 统一内部语言标识（nil = 不支持）
    private static func aliases(_ lang: String) -> String? {
        switch lang.lowercased() {
        case "swift": return "swift"
        case "python", "py", "python3": return "python"
        case "javascript", "js", "jsx", "ts", "typescript", "node": return "js"
        case "shell", "sh", "bash", "zsh", "console": return "shell"
        case "json", "yaml", "yml", "toml": return "json"
        default: return nil
        }
    }

    // MARK: - 配色（跟随系统深浅色：UIColor dynamic 或固定色）

    private static let keywordColor = UIColor.systemBlue
    private static let stringColor  = UIColor.systemGreen
    private static let commentColor = UIColor.systemGray
    private static let numberColor  = UIColor.systemOrange

    // MARK: - 预编译正则（static let，避免每次调用重建）

    /// 字符串：双引号/单引号（含转义），多行三双引号（python）
    private static let stringRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|"""[\s\S]*?"""|```[\s\S]*?```"#)

    /// 行注释：// ... 或 # ...（# 不误伤颜色十六进制/URL 里的 # 由 keyword 判断隔离，简化处理）
    private static let lineCommentRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"//[^\n]*"#)

    /// 块注释：/* ... */（Swift/C 风格）
    private static let blockCommentRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"/\*[\s\S]*?\*/"#)

    /// 数字：整数/小数/科学计数/常见进制
    private static let numberRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b\d+(\.\d+)?([eE][+-]?\d+)?\b|0x[0-9a-fA-F]+"#)

    /// 关键字（按语言分组；用词边界 \b 避免误伤标识符子串）
    private static let keywords: [String: [String]] = [
        "swift": ["func", "let", "var", "if", "else", "guard", "for", "while", "return",
                  "class", "struct", "enum", "protocol", "extension", "import", "public",
                  "private", "internal", "static", "final", "override", "init", "self",
                  "nil", "true", "false", "throws", "async", "await", "try", "switch",
                  "case", "default", "break", "continue", "defer", "in", "where", "as",
                  "is", "any", "some"],
        "python": ["def", "class", "import", "from", "if", "elif", "else", "for", "while",
                   "return", "try", "except", "finally", "with", "as", "pass", "break",
                   "continue", "lambda", "yield", "global", "nonlocal", "None", "True",
                   "False", "and", "or", "not", "in", "is", "raise", "assert"],
        "js": ["function", "var", "let", "const", "if", "else", "for", "while", "return",
               "class", "extends", "import", "export", "from", "default", "async", "await",
               "new", "this", "try", "catch", "finally", "switch", "case", "break",
               "continue", "typeof", "instanceof", "null", "undefined", "true", "false",
               "throw", "yield"],
        "shell": ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
                  "esac", "function", "return", "exit", "echo", "export", "local", "source",
                  "alias", "set", "readonly", "shift"],
        "json": ["true", "false", "null"],
    ]

    /// 从文本中抽取语言关键字正则（把 keyword 列表拼成 alternation）
    /// v3.9.41（SR44）：**每个语言的表达式只在首次访问时编译一次**。
    /// 原来是每次 highlight 都 `try? NSRegularExpression(pattern:)` 重新编译（拼串 + 编译 ≈ 数十 µs，
    /// 而流式渲染每一帧都会重跑 highlight → 一条长回答里持续付这笔钱）。
    private static let keywordRegexes: [String: NSRegularExpression?] = {
        var out = [String: NSRegularExpression?]()
        for (lang, list) in keywords where !list.isEmpty {
            let pattern = "\\b(" + list.joined(separator: "|") + ")\\b"
            out[lang] = try? NSRegularExpression(pattern: pattern)
        }
        return out
    }()

    private static func keywordRegex(_ lang: String) -> NSRegularExpression? {
        keywordRegexes[lang] ?? nil
    }

    /// v3.9.41（SR44）：超长代码块不做 token 着色（直接等宽字）。
    /// 正则匹配 + 区间互斥判定都是按 token 数增长的，几百 KB 的代码块能把一帧吃掉很多毫秒；
    /// 这种块在手机上本来也只能横向滚动看，着色收益为 0。
    private static let maxHighlightLength = 30_000   // NSString(UTF-16) 长度

    /// 高亮结果缓存（key = 语言 + 字号 + 正文哈希）。
    /// 与 ChatMessageBubble 里 `_blocksCache` 同一口径（同样用 hashValue 做键）：
    /// View struct 每次 body 重建，static 缓存跨次评估存活。
    private static var _attrCache: [String: NSAttributedString] = [:]

    /// 高亮入口：返回 NSAttributedString，等宽字体 + 按 token 着色。
    /// 浅色/深色模式无需特殊处理（systemBlue/Green/Gray/Orange 自动适配）。
    static func highlight(_ code: String, language: String, baseSize: CGFloat) -> NSAttributedString {
        let langOK = aliases(language) != nil
        let ns0 = code as NSString
        let cacheable = langOK && ns0.length <= maxHighlightLength
        let key = "\(language)|\(baseSize)|\(ns0.length)|\(code.hashValue)"
        if cacheable, let hit = _attrCache[key] { return hit }
        let made = makeHighlight(code, language: language, baseSize: baseSize)
        if cacheable {
            if _attrCache.count > 200 { _attrCache.removeAll() }
            _attrCache[key] = made
        }
        return made
    }

    private static func makeHighlight(_ code: String, language: String, baseSize: CGFloat) -> NSAttributedString {
        guard let lang = aliases(language) else {
            // 未知语言：原样等宽字
            return NSAttributedString(string: code, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: baseSize, weight: .regular),
                .foregroundColor: UIColor.label
            ])
        }
        let ns = code as NSString
        guard ns.length <= maxHighlightLength else {
            return NSAttributedString(string: code, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: baseSize, weight: .regular),
                .foregroundColor: UIColor.label
            ])
        }
        let font = UIFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
        let out = NSMutableAttributedString(string: code, attributes: [
            .font: font, .foregroundColor: UIColor.label
        ])

        // 取已匹配 token 的区间集合，避免注释/字符串内部再次被关键字/数字覆盖
        // v3.9.41（SR44）：`taken` 每个阶段结束后按 location 排序（同阶段匹配本来就是升序、
        // mark 又保证互不相交），于是 isTaken 从「线性扫全表」变成二分——
        // 原来是 O(token 数²)：一个几千 token 的块要几十万次区间求交。
        var taken = [NSRange]()
        func settle() { taken.sort { $0.location < $1.location } }
        func isTaken(_ r: NSRange) -> Bool {
            // 第一个 end > r.location 的候选（二分下界）
            var lo = 0
            var hi = taken.count - 1
            var start = taken.count
            while lo <= hi {
                let mid = (lo + hi) / 2
                if NSMaxRange(taken[mid]) <= r.location { lo = mid + 1 } else { start = mid; hi = mid - 1 }
            }
            var i = start
            while i < taken.count, taken[i].location < NSMaxRange(r) {
                if NSIntersectionRange(taken[i], r).length > 0 { return true }
                i += 1
            }
            return false
        }
        func mark(_ r: NSRange, color: UIColor) {
            guard !isTaken(r), r.location != NSNotFound else { return }
            out.addAttribute(.foregroundColor, value: color, range: r)
            taken.append(r)
        }

        // ① 注释（先匹配——注释内不做其它高亮）
        let full = NSRange(location: 0, length: ns.length)
        if let le = lineCommentRegex {
            for m in le.matches(in: code, range: full) { mark(m.range, color: commentColor) }
        }
        settle()
        if let be = blockCommentRegex {
            for m in be.matches(in: code, range: full) { mark(m.range, color: commentColor) }
        }
        settle()
        // ② 字符串
        if let se = stringRegex {
            for m in se.matches(in: code, range: full) { mark(m.range, color: stringColor) }
        }
        settle()
        // ③ 关键字
        if let ke = keywordRegex(lang) {
            for m in ke.matches(in: code, range: full) { mark(m.range, color: keywordColor) }
        }
        settle()
        // ④ 数字（关键词/字符串已占用则跳过）
        if let ne = numberRegex {
            for m in ne.matches(in: code, range: full) { mark(m.range, color: numberColor) }
        }
        return out
    }
}
