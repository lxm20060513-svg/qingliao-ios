import Foundation

/// 待做池第 8 项「链接预览卡片」的**纯逻辑口径**（真值表主对象）。
///
/// 微信式：消息里出现一条 http(s) 链接 → 后端抓 og:title/description/image →
/// 气泡下方渲染一张预览卡片（标题 + 摘要 + 缩略图）。
///
/// 本文件只做判定与解析，**不 import SwiftUI / UIKit** → 真值表可直接编译运行。
/// 口径要点（与台账护栏一一对应）：
///  ① 一条消息含**多个** URL 也只取**第一个**（不堆多张卡）；
///  ② 抓取失败 / 返回 ok:false / 三字段全空 → `parse` 返回 nil（**不显示空卡**）；
///  ③ 只认 http / https（ftp / 自定义 scheme / 裸域名不预览）。
enum LinkPreviewKit {

    /// 一张已解析好的预览卡数据。
    struct LinkPreview: Equatable {
        let url: String       // 规范化后的目标链接（后端回传，可能跟随重定向）
        let title: String
        let desc: String
        let image: String     // 缩略图 URL（可能为空 = 无图降级形态）
        let site: String      // 站点名（无 og:site_name 时 = host）

        var hasImage: Bool { !image.isEmpty }
    }

    /// URL 的终止符：遇到这些字符即认为链接结束（中英文标点一并算）。
    private static let terminators: Set<Character> = [
        " ", "\t", "\n", "\r", "\"", "'", "<", ">", "(", ")", "[", "]", "{", "}", "|", "\\", "^",
        "，", "。", "、", "；", "：", "！", "？", "“", "”", "‘", "’", "（", "）", "【", "】",
        "《", "》", "「", "」", "·",
    ]

    /// URL 末尾允许被吞掉的收尾标点（句末的点/逗号/右括号不该进链接）。
    private static let trailingJunk: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "。", "，", "、", "；", "：", "！", "？",
    ]

    /// 取消息里**第一个** http(s) 链接（没有则 nil）。
    ///
    /// 用「先找 `http` 再检查紧跟 `://` / `s://`」的显式扫描（**不用 NSDataDetector**：
    /// 它在 swift-corelibs-foundation 上是空壳，真值表会假绿）。
    static func candidateURL(in text: String) -> String? {
        var searchFrom = text.startIndex
        while searchFrom < text.endIndex,
              let r = text.range(of: "http", options: .caseInsensitive, range: searchFrom..<text.endIndex) {
            let after = r.upperBound
            let tail = text[after...]
            if tail.hasPrefix("://") || tail.hasPrefix("s://") {
                // 往后吃到终止符
                var end = r.lowerBound
                while end < text.endIndex, !terminators.contains(text[end]) {
                    end = text.index(after: end)
                }
                var raw = String(text[r.lowerBound..<end])
                while let last = raw.last, trailingJunk.contains(last) { raw.removeLast() }
                if let u = URL(string: raw), let h = u.host, !h.isEmpty, !raw.isEmpty {
                    return raw
                }
            }
            searchFrom = text.index(after: r.lowerBound)
        }
        return nil
    }

    /// 后端响应字典 → 预览数据。`ok != true` 或三字段全空 → nil（不显示空卡）。
    static func parse(_ obj: [String: Any]) -> LinkPreview? {
        guard (obj["ok"] as? Bool) == true else { return nil }
        let url = (obj["url"] as? String) ?? ""
        let title = ((obj["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = ((obj["desc"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let image = ((obj["image"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let site = ((obj["site"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty && desc.isEmpty && image.isEmpty { return nil }
        return LinkPreview(url: url, title: title, desc: desc, image: image, site: site)
    }

    /// 卡片底部展示的站点名：优先后端给的 site，退化为 host，再退化空。
    static func hostLabel(of preview: LinkPreview) -> String {
        if !preview.site.isEmpty { return preview.site }
        if let h = URL(string: preview.url)?.host { return h }
        return ""
    }
}
