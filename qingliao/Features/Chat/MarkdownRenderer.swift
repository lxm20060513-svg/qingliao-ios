import Foundation
import UIKit
import SwiftUI

/// 轻量 Markdown → AttributedString 渲染器（v2.0.34 修复"AI 回复纯文本无排版"）
/// 覆盖 AI 回复常见语法：标题 / 加粗 / 斜体 / 行内代码 / 列表 / 引用 / 链接 / 分隔线。
/// 手动构建 runs，不依赖 AttributedString(markdown:) 的系统解析行为（iOS 上不可控）。
enum MarkdownRenderer {
    /// v4.0 fix：NSMutableAttributedString.append 是摊销 O(1)，替代 AttributedString += 的 O(n) 拷贝；
    /// 首次渲染从 O(n²) 降为 O(n)（n = 全文字符数）
    static func render(_ text: String, baseSize: CGFloat = 14) -> AttributedString {
        let lines = text.components(separatedBy: "\n")
        let nsResult = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            if i > 0 { nsResult.append(NSAttributedString(string: "\n")) }
            nsResult.append(NSAttributedString(renderLine(line, baseSize: baseSize)))
        }
        return AttributedString(nsResult)
    }

    // MARK: - v3.0.43 全局渲染缓存（跨 LazyVStack cell 生命周期）

    /// LazyVStack 滚动离屏会销毁 cell（@State 缓存随之丢失），滚回时若重新完整解析
    /// 几万字长文（render 逐行 += 是 O(n²)）→ 主线程阻塞数秒 = 全 App 卡死。
    /// 全局字典缓存：cell 重建直接命中，永不重复解析同一文本。
    private static nonisolated(unsafe) var renderCache: [String: NSAttributedString] = [:]
    private static nonisolated(unsafe) var renderAttrCache: [String: AttributedString] = [:]
    private static nonisolated(unsafe) let renderCacheLock = NSLock()

    /// 缓存版渲染（返回 NSAttributedString 供 SelectableTextLabel / AttributedString 转换）
    static func renderCached(_ text: String, baseSize: CGFloat) -> NSAttributedString {
        renderCachedPair(text, baseSize: baseSize).0
    }

    /// 缓存版渲染（返回 AttributedString 供 SwiftUI Text 直接渲染）
    static func renderCachedAttr(_ text: String, baseSize: CGFloat) -> AttributedString {
        renderCachedPair(text, baseSize: baseSize).1
    }

    /// 双缓存统一入口：NSAttributedString + AttributedString 一次解析两形态都存，
    /// 跨 LazyVStack cell 生命周期命中（超长文本 O(n²) 解析绝不在滚动/重建时重复发生）
    static func renderCachedPair(_ text: String, baseSize: CGFloat) -> (NSAttributedString, AttributedString) {
        let key = "\(text.hashValue)|\(baseSize)"
        renderCacheLock.lock()
        defer { renderCacheLock.unlock() }
        if let ns = renderCache[key], let at = renderAttrCache[key] {
            return (ns, at)
        }
        let rendered = render(text, baseSize: baseSize)   // 首次 O(n²) 全量解析
        let ns = NSAttributedString(rendered)
        if renderCache.count > 120 {
            renderCache.removeAll()   // 简单防爆：上限内保留，超了清空重来（一次性成本可接受）
            renderAttrCache.removeAll()
        }
        renderCache[key] = ns
        renderAttrCache[key] = rendered
        return (ns, rendered)
    }

    // MARK: - 行级语法

    private static func renderLine(_ line: String, baseSize: CGFloat) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // 标题：### / ## / #
        for (mark, size) in [("###", baseSize + 3), ("##", baseSize + 5), ("#", baseSize + 7)] {
            if trimmed.hasPrefix(mark + " ") {
                return renderInline(String(trimmed.dropFirst(mark.count + 1)),
                                    .systemFont(ofSize: size, weight: .bold), .label)
            }
        }
        // 引用：>
        if trimmed.hasPrefix(">") {
            return renderInline(String(trimmed.dropFirst(1)),
                                .italicSystemFont(ofSize: baseSize), .secondaryLabel)
        }
        // 无序列表：- / *
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            let body = String(trimmed.dropFirst(2))
            return styled("•  ", .systemFont(ofSize: baseSize, weight: .bold), .secondaryLabel)
                 + renderInline(body, .systemFont(ofSize: baseSize), .label)
        }
        // 有序列表：1. / 1、（使用预编译正则避免每行创建 NSRegularExpression）
        if let re = orderedListRegex,
           let m = re.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) {
            let end = m.range.location + m.range.length
            let nsTrimmed = trimmed as NSString
            let num = nsTrimmed.substring(to: end)
            let body = nsTrimmed.substring(from: end)
            return styled(num, .systemFont(ofSize: baseSize, weight: .semibold), .secondaryLabel)
                 + renderInline(body, .systemFont(ofSize: baseSize), .label)
        }
        // 分隔线
        if trimmed.hasPrefix("---") || trimmed.hasPrefix("***") {
            return styled("────────", .systemFont(ofSize: baseSize), .tertiaryLabel)
        }
        return renderInline(line, .systemFont(ofSize: baseSize), .label)
    }

    // MARK: - 预编译正则（避免每行重复创建 NSRegularExpression）
    /// 行内语法：**加粗** `代码` *斜体* [链接](url)
    private static let inlineRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\*\*.+?\*\*|`[^`]+?`|\*[^*]+?\*|\[[^\]]+\]\([^)]+\)"#)
    }()
    /// 有序列表行首：1. / 1、/ 12. 等
    private static let orderedListRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^\d+[\.、]\s"#)
    }()
    /// v3.4.28：裸链接（非 markdown 语法的 http/https/www 直链）
    private static let bareLinkRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"https?://[^\s<>()\[\]{}"']+|www\.[^\s<>()\[\]{}"']+"#)
    }()

    // MARK: - 行内语法：**加粗** `代码` *斜体* [链接](url)

    // v4.0 fix：NSMutableAttributedString.append 是摊销 O(1)，替代 AttributedString += 的 O(n) 拷贝；
    // 首次渲染从 O(n²) 降为 O(n)（n = 行内文本字符数）
    private static func renderInline(_ text: String, _ font: UIFont, _ color: UIColor) -> AttributedString {
        let ns = text as NSString
        guard let re = inlineRegex else {
            return styled(text, font, color)
        }
        let out = NSMutableAttributedString()
        var pos = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range
            if r.location > pos {
                out.append(renderPlainWithLinks(ns.substring(with: NSRange(location: pos, length: r.location - pos)), font, color))
            }
            let token = ns.substring(with: r)
            if token.hasPrefix("**"), token.hasSuffix("**") {
                out.append(NSAttributedString(string: String(token.dropFirst(2).dropLast(2)),
                                              attributes: [.font: UIFont.systemFont(ofSize: font.pointSize, weight: .bold),
                                                           .foregroundColor: color]))
            } else if token.hasPrefix("`"), token.hasSuffix("`") {
                out.append(NSAttributedString(string: String(token.dropFirst().dropLast()),
                                              attributes: [.font: UIFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                                                           .foregroundColor: color]))
            } else if token.hasPrefix("*"), token.hasSuffix("*") {
                out.append(NSAttributedString(string: String(token.dropFirst().dropLast()),
                                              attributes: [.font: UIFont.italicSystemFont(ofSize: font.pointSize),
                                                           .foregroundColor: color]))
            } else if token.hasPrefix("[") {
                // [text](url) → 蓝色 + .link 属性（v3.4.28：Text/UITextView 点击可开浏览器）
                let body = String(token.dropFirst().dropLast())
                if let close = body.range(of: "](") {
                    let label = String(body[..<close.lowerBound])
                    var urlStr = String(body[close.upperBound...])
                    // 相对/无 scheme 的 url 补 https（防点击无效）
                    if !urlStr.contains("://") { urlStr = "https://" + urlStr }
                    out.append(linkText(label, urlStr, font))
                }
            }
            pos = r.location + r.length
        }
        if pos < ns.length {
            out.append(renderPlainWithLinks(ns.substring(from: pos), font, color))
        }
        return AttributedString(out)
    }

    // MARK: - v3.4.28 裸链接识别

    /// 普通文本渲染 + 裸链接识别（http/https/www 直链 → 蓝色下划线可点击）
    private static func renderPlainWithLinks(_ text: String, _ font: UIFont, _ color: UIColor) -> AttributedString {
        guard let re = bareLinkRegex, !text.isEmpty else {
            return styled(text, font, color)
        }
        let ns = text as NSString
        let out = NSMutableAttributedString()
        var pos = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range
            if r.location > pos {
                out.append(NSAttributedString(string: ns.substring(with: NSRange(location: pos, length: r.location - pos)),
                                              attributes: [.font: font, .foregroundColor: color]))
            }
            var urlStr = ns.substring(with: r)
            // 尾部标点剥离（中文句读/英文句号常紧跟链接，属句子而非 URL）
            while let last = urlStr.last, ".,;!?。，；！？）】》".contains(last) {
                urlStr.removeLast()
            }
            let trimmedLen = urlStr.count
            if trimmedLen > 0 {
                out.append(linkText(urlStr, urlStr, font))
                pos = r.location + trimmedLen
            } else {
                pos = r.location
            }
        }
        if pos < ns.length {
            out.append(NSAttributedString(string: ns.substring(from: pos),
                                          attributes: [.font: font, .foregroundColor: color]))
        }
        return AttributedString(out)
    }

    /// 链接统一样式：蓝色 + 下划线 + .link 属性（SwiftUI Text 可点 / UITextView dataDetector 兜底）
    private static func linkText(_ label: String, _ urlStr: String, _ font: UIFont) -> AttributedString {
        var full = urlStr
        if !full.contains("://") { full = "https://" + full }
        var attr = AttributedString(label)
        attr.font = .systemFont(ofSize: font.pointSize)
        attr.foregroundColor = .systemBlue
        attr.underlineStyle = .single
        if let u = URL(string: full) { attr.link = u }
        return attr
    }

    private static func styled(_ s: String, _ font: UIFont, _ color: UIColor) -> AttributedString {
        // NSAttributedString 桥接最稳（基础 API 全版本可用）：UIKit 字体/颜色属性
        // 转换后 Text(AttributedString) 直接按属性渲染
        let ns = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key.font: font,
            NSAttributedString.Key.foregroundColor: color
        ])
        return AttributedString(ns)
    }

    // MARK: - v3.0.27 章节列表：提取 Markdown 标题（供章节列表弹窗静态展示）

    struct TOCItem: Identifiable {
        let id = UUID()
        let level: Int       // 1 = #, 2 = ##, 3 = ###
        let title: String
        let lineIndex: Int   // 在原文中的行号（0-based）
    }

    /// 从 Markdown 文本中提取标题列表（# / ## / ###）
    static func extractHeaders(_ text: String) -> [TOCItem] {
        var items: [TOCItem] = []
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for (mark, level) in [("### ", 3), ("## ", 2), ("# ", 1)] {
                if trimmed.hasPrefix(mark) {
                    let title = String(trimmed.dropFirst(mark.count))
                    if !title.isEmpty {
                        items.append(TOCItem(level: level, title: title, lineIndex: i))
                    }
                    break
                }
            }
        }
        return items
    }
}
