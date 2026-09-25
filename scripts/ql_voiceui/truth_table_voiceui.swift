import Foundation

// MARK: - v3.9.82 语音对话页「回复正文」口径真值表（源码形态，本机可跑）
//
// 钉五件事（都是真机上才看得出来、本机一眼能查的形态）：
//   ① **两稿**：`ViewThatFits(in: .vertical)` 在位 —— 稿 1 = 内容自然高度，稿 2 = `ScrollView` + 上限。
//   ② **两稿顺序**：稿 1 必须是「无 ScrollView」的自然高度那一稿。**调换 = 短回复又白撑** ——
//      v3.9.78 那版就是这个病：贪婪 `ScrollView` 吃掉提案给它的全部高度，只说两三句也占满 220pt。
//   ③ **上限不被悄悄抬高/删掉**：`replyMaxHeight` 仍是 `static let = 220`（长文上限的单一真源）。
//   ④ **贴底机制仍挂在 `ViewThatFits` 外层**（挂到可滚动那一稿里，切换稿件时会丢）。
//   ⑤ 两稿**共用同一 `replyTextBody`**（内容只写一处，防两稿漂移）+ 不退回 `.lineLimit(`（v3.9.78 红线）。
//
// 同口径先例（本次对齐）：译文卡 `OrbIdentifyOverlay.swift`、崩溃日志预览 `QingliaoApp.swift`
// —— 两处都在 v3.9.80 用「`ViewThatFits` 两稿」替掉了「贪婪 ScrollView + 限高」。

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}
func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
/// 去注释行：负断言必须走它，否则「讲清旧形态」的注释会把断言染红（本仓已踩）
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}
/// 去掉全部空白（含换行）——用于「顺序/相邻」类断言，不受缩进漂移影响
func flat(_ s: String) -> String {
    s.filter { !$0.isWhitespace }
}

let viewSrc = src("qingliao/Features/VoiceDialogView.swift")

// ── 0. 源可读 + 能截出 replyText 区段（空了后面全是空真） ─────────────
var replyRegion = ""
if let a = viewSrc.range(of: "private var replyText: some View {"),
   let b = viewSrc.range(of: "private static let replyMaxHeight"),
   a.lowerBound < b.lowerBound {
    replyRegion = String(viewSrc[a.lowerBound..<b.lowerBound])
}
check("VoiceDialogView.swift 源可读", !viewSrc.isEmpty)
check("能截出 replyText 区段（只在这个区段内断言，避免吃到文件里别处的 ScrollView/lineLimit）",
      replyRegion.count > 200)

let replyFlat = flat(replyRegion)

// ── 1. 两稿在位 ───────────────────────────────────────────────────
check("两稿在位：replyText 区段里有 ViewThatFits(in: .vertical)",
      replyFlat.contains("ViewThatFits(in:.vertical)"))

// ── 2. 稿 1 = 自然高度那一稿（顺序断言，最重要的一条） ────────────────
var firstDraft = ""
if let v = replyRegion.range(of: "ViewThatFits(in: .vertical) {"),
   let s = replyRegion.range(of: "ScrollView", range: v.upperBound..<replyRegion.endIndex) {
    firstDraft = flat(String(replyRegion[v.upperBound..<s.lowerBound]))
}
check("稿 1 = 自然高度那一稿（ViewThatFits 的第一个子视图不是 ScrollView，而是 replyTextBody）"
      + " —— 截到的是「\(firstDraft)」",
      firstDraft == "replyTextBody")

// ── 3. 稿 2 = 可滚动 + 上限走同一真源 ───────────────────────────────
check("稿 2 = ScrollView 可滚动那一稿",
      replyFlat.contains("ScrollView(.vertical,showsIndicators:false){replyTextBody}"))
check("稿 2 的上限 = .frame(maxHeight: Self.replyMaxHeight)（不写死数字）",
      replyFlat.contains(".frame(maxHeight:Self.replyMaxHeight)"))

// ── 4. 两稿共用同一 body + 上限真值未动 ─────────────────────────────
check("两稿共用同一 replyTextBody（区段内 2 处引用 + 文件内有定义）—— 防两稿内容漂移",
      replyRegion.components(separatedBy: "replyTextBody").count - 1 >= 2
      && viewSrc.contains("private var replyTextBody: some View {"))
check("上限真值未被抬高/删掉：replyMaxHeight 仍是 private static let = 220",
      viewSrc.contains("private static let replyMaxHeight: CGFloat = 220"))

// ── 5. 贴底机制仍在，且挂在 ViewThatFits **外层** ────────────────────
check("贴底机制在位：.onChange(of: displayText) + scrollTo(…, anchor: .bottom) 都在区段内",
      replyFlat.contains(".onChange(of:displayText)") && replyFlat.contains("anchor:.bottom"))
let replyCodeFlat = flat(stripCommentLines(replyRegion))   // 去注释后再拼：注释夹在两稿与外层修饰符之间
check("贴底挂在 ViewThatFits 外层（紧跟在两稿闭合之后 + 上限之后，不是只写在可滚动那一稿里）",
      replyCodeFlat.contains("}.frame(maxHeight:Self.replyMaxHeight).onChange(of:displayText)"))

// ── 6. 不退回旧形态 ────────────────────────────────────────────────
check("不退回 .lineLimit(（v3.9.78 红线：那等于把「后面的文字」重新关掉）",
      !stripCommentLines(replyRegion).contains(".lineLimit("))
check("上限只出现一次，且钳在 ViewThatFits **外层（提案）**—— 稿 1 的「放得下」= 不超过 220；"
      + "退回旧形态「贪婪 ScrollView 直接吃上限」或「上限只挂稿 2」都会红",
      stripCommentLines(replyRegion).components(separatedBy: ".frame(maxHeight:").count - 1 == 1
      && flat(stripCommentLines(replyRegion)).contains("}.frame(maxHeight:Self.replyMaxHeight)"))

// ── 7. 同口径先例都还在（本页只是补齐，不是单独立规矩） ─────────────
let orbSrc = stripCommentLines(src("qingliao/Features/OrbIdentifyOverlay.swift"))
let appSrc = stripCommentLines(src("qingliao/QingliaoApp.swift"))
// v3.9.82：先例 1（译文卡两稿）**已作废** —— 用户拍板改成弹窗（Features/TranslateSheet.swift），
// 那套 `ViewThatFits` 两稿随译文卡一起删了。本页两稿口径仍对标先例 2（崩溃日志预览）。
// 留一条负断言：浮层里不许再把 ViewThatFits 加回来（加回来 = 有人又在浮层里造译文卡）。
check("先例 1 已作废：识别浮层里不许再有 ViewThatFits（两稿随译文卡搬走）",
      !orbSrc.contains("ViewThatFits"))
check("先例 2 崩溃日志预览仍是两稿（QingliaoApp 有 ViewThatFits）",
      appSrc.contains("ViewThatFits"))

print("语音页正文两稿口径真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
