// 待做池⑧「链接预览卡片」真值表 —— Linux 本地预检用（权威入口 = check_swift.sh 第 80 段）
//
// 编译运行（在仓库根目录）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_linkpreview \
//       scripts/ql_linkpreview/truth_table_linkpreview.swift qingliao/Core/LinkPreviewKit.swift
//
// 本表钉死的口径（与台账护栏一一对应）：
//   · 一条消息含多个 URL 只取**首个**（A 段）
//   · 只认 http/https；ftp / 裸域名 / javascript: / 空 host → 不预览（A 段反例）
//   · 抓取失败 / ok:false / 三字段全空 → parse 返回 nil（**不显示空卡**）（B 段）
//   · 站点名 = og:site_name → host → 空（C 段）
//   · 源级接线：入口行 / 卡片 / 缓存 store / 缩略图 URL / 重新抓取 / 关闭（D 段）
//
// A/B/C 段**真编译真跑** Core/LinkPreviewKit.swift（与实现同一份文件 → 无「表/实现漂移」洞）；
// D 段为源级断言（剥注释），钉接线在源码里真实存在。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func ok(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}
func pos(_ name: String, _ cond: Bool) { positives += 1; ok(name, cond) }
func neg(_ name: String, _ cond: Bool) { negatives += 1; ok(name, cond) }

/// 整行剥注释（不按行内 `//` 剥：Swift 里有 `http://` 之类字面量会被截断）
func stripComments(_ s: String) -> String {
    s.components(separatedBy: "\n").map { line -> String in
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("//") ? "" : line
    }.joined(separator: "\n")
}
func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

@main
enum LinkPreviewTruthTable {

    static func main() {
        let K = LinkPreviewKit.self

        // ---- A 段：candidateURL（取首个 http(s) 链接）----
        pos("A1 正文中的链接被认出", K.candidateURL(in: "看看这个 https://www.example.com/ 不错") == "https://www.example.com/")
        pos("A2 纯链接", K.candidateURL(in: "https://apple.com") == "https://apple.com")
        pos("A3 多个链接 → 只取首个", K.candidateURL(in: "A https://a.com/1 和 B https://b.com/2") == "https://a.com/1")
        pos("A4 带 query 不被截断", K.candidateURL(in: "x https://s.cn/a?b=1&c=2 y") == "https://s.cn/a?b=1&c=2")
        pos("A5 大写 scheme 也认", K.candidateURL(in: "HTTP://Example.COM/P") == "HTTP://Example.COM/P")
        pos("A6 中文句号收尾被剥离", K.candidateURL(in: "详情见 https://news.cn/a。谢谢") == "https://news.cn/a")
        pos("A7 括号包裹时剥离右括号", K.candidateURL(in: "(https://a.com/b)") == "https://a.com/b")
        pos("A8 中文逗号收尾被剥离", K.candidateURL(in: "见 https://a.com/x，谢谢") == "https://a.com/x")
        pos("A9 http 明文也认", K.candidateURL(in: "http://a.com/p") == "http://a.com/p")

        neg("A10 无链接纯文本 → nil", K.candidateURL(in: "今天天气不错，没有链接") == nil)
        neg("A11 ftp → nil", K.candidateURL(in: "ftp://files.example.com") == nil)
        neg("A12 裸域名 → nil", K.candidateURL(in: "裸域名 example.com 不算") == nil)
        neg("A13 只有 http:// 没有主机 → nil", K.candidateURL(in: "http://") == nil)
        neg("A14 www 开头不算 → nil", K.candidateURL(in: "www.example.com/path") == nil)
        neg("A15 javascript: → nil", K.candidateURL(in: "javascript:alert(1)") == nil)
        neg("A16 空串 → nil", K.candidateURL(in: "") == nil)

        // ---- B 段：parse（失败/空值不显示空卡）----
        let p1 = K.parse(["ok": true, "title": "标题"])
        pos("B1 ok + title → 出卡", p1?.title == "标题")
        let p2 = K.parse(["ok": true, "title": "", "desc": "", "image": "https://i.cn/x.png", "site": ""])
        pos("B2 只有缩略图也算（无标题降级形态可用）", p2?.hasImage == true)
        let p3 = K.parse(["ok": true, "desc": "摘要"])
        pos("B3 只有摘要 → 出卡", p3?.desc == "摘要")
        let p4 = K.parse(["ok": true, "title": "  T  ", "desc": " ", "image": "", "site": ""])
        pos("B4 首尾空白被裁剪", p4?.title == "T" && p4?.desc == "")

        neg("B5 ok:false → nil（抓取失败不出空卡）", K.parse(["ok": false, "error": "打不开"]) == nil)
        neg("B6 ok:true 但三字段全空 → nil（不出空卡）", K.parse(["ok": true, "title": "", "desc": "", "image": ""]) == nil)
        neg("B7 缺 ok key → nil", K.parse(["title": "T"]) == nil)
        neg("B8 全空白三字段 → nil", K.parse(["ok": true, "title": "   ", "desc": " ", "image": "\n"]) == nil)

        // ---- C 段：站点名 ----
        let siteFull = LinkPreviewKit.LinkPreview(url: "https://a.com/x", title: "T", desc: "", image: "", site: "示例站")
        let siteEmpty = LinkPreviewKit.LinkPreview(url: "https://a.com/x", title: "T", desc: "", image: "", site: "")
        let siteNone = LinkPreviewKit.LinkPreview(url: "", title: "T", desc: "", image: "", site: "")
        pos("C1 有 site → 用 site", K.hostLabel(of: siteFull) == "示例站")
        pos("C2 无 site → 退化 host", K.hostLabel(of: siteEmpty) == "a.com")
        pos("C3 都没有 → 空串", K.hostLabel(of: siteNone) == "")

        // ---- D 段：源级接线（剥注释后断言真实存在）----
        let cv = stripComments(read("qingliao/Features/Chat/ChatView.swift"))
        pos("D1 messageRow 挂了 linkPreviewRow", cv.contains("linkPreviewRow(msg)"))
        pos("D2 用 Kit 的候选判定", cv.contains("LinkPreviewKit.candidateURL(in:"))
        pos("D3 接线出卡", cv.contains("LinkPreviewCard("))
        pos("D4 拉取走 store.load", cv.contains("linkPreviews.load("))
        pos("D5 关闭走 store.dismiss", cv.contains("linkPreviews.dismiss("))
        pos("D6 缓存是行级 @State（单例持有：GoalStore.shared 同款）", cv.contains("@State private var linkPreviews = LinkPreviewStore.shared"))

        let card = stripComments(read("qingliao/Features/Chat/LinkPreviewCard.swift"))
        pos("D7 缩略图按 URL 自加载（AsyncImage）", card.contains("AsyncImage"))
        pos("D8 长按可「重新抓取预览」", card.contains("重新抓取预览"))
        pos("D9 可手动关闭（onDismiss）", card.contains("onDismiss"))
        pos("D10 加载不到即无图降级（default 分支给 clear）", card.contains("default:"))

        let store = stripComments(read("qingliao/Core/LinkPreviewStore.swift"))
        pos("D11 store 打的是 /api/agent/linkpreview", store.contains("/api/agent/linkpreview"))
        pos("D12 失败/在途/已就绪 → 不重复打后端", store.contains("case .loading?, .ready?, .failed?: return"))
        pos("D13 已关的消息不再抓", store.contains("if dismissed.contains(id) { return }"))

        let kit = stripComments(read("qingliao/Core/LinkPreviewKit.swift"))
        neg("D14 Kit 保持纯 Foundation（不 import SwiftUI）", !kit.contains("import SwiftUI"))
        neg("D15 不依赖 NSDataDetector（corelibs 上是空壳，会假绿）", !kit.contains("NSDataDetector"))

        print("----")
        print("正例 \(positives) / 反例 \(negatives) / \(failures) 失败")
        if failures > 0 { exit(1) }
    }
}
