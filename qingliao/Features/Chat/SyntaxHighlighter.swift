import Foundation
import UIKit

/// v3.4.x 代码块语法高亮：按语言词法把代码 token 着色为 NSAttributedString。
/// 实现取舍：用 NSRegularExpression 预编译匹配 关键字/字符串/注释/数字 四类 token，
/// 不引第三方高亮库（无网络/无依赖，App 侧加载零成本）；对未知语言返回纯等宽字。
///
/// 期望效果：代码块从"一片灰字"变成"关键字蓝/字符串绿/注释灰/数字橙"的可读排版。
/// 支持的 token：行注释、块注释、字符串、数字、常见关键字。
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
    private static func keywordRegex(_ lang: String) -> NSRegularExpression? {
        guard let list = keywords[lang], !list.isEmpty else { return nil }
        let pattern = "\\b(" + list.joined(separator: "|") + ")\\b"
        return try? NSRegularExpression(pattern: pattern)
    }

    /// 高亮入口：返回 NSAttributedString，等宽字体 + 按 token 着色。
    /// 浅色/深色模式无需特殊处理（systemBlue/Green/Gray/Orange 自动适配）。
    static func highlight(_ code: String, language: String, baseSize: CGFloat) -> NSAttributedString {
        guard let lang = aliases(language) else {
            // 未知语言：原样等宽字
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
        var taken = [NSRange]()
        func isTaken(_ r: NSRange) -> Bool {
            taken.contains { NSIntersectionRange($0, r).length > 0 }
        }
        func mark(_ r: NSRange, color: UIColor) {
            guard !isTaken(r), r.location != NSNotFound else { return }
            out.addAttribute(.foregroundColor, value: color, range: r)
            taken.append(r)
        }

        // ① 注释（先匹配——注释内不做其它高亮）
        let ns = code as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let le = lineCommentRegex {
            for m in le.matches(in: code, range: full) { mark(m.range, color: commentColor) }
        }
        if let be = blockCommentRegex {
            for m in be.matches(in: code, range: full) { mark(m.range, color: commentColor) }
        }
        // ② 字符串
        if let se = stringRegex {
            for m in se.matches(in: code, range: full) { mark(m.range, color: stringColor) }
        }
        // ③ 关键字
        if let ke = keywordRegex(lang) {
            for m in ke.matches(in: code, range: full) { mark(m.range, color: keywordColor) }
        }
        // ④ 数字（关键词/字符串已占用则跳过）
        if let ne = numberRegex {
            for m in ne.matches(in: code, range: full) { mark(m.range, color: numberColor) }
        }
        return out
    }
}
