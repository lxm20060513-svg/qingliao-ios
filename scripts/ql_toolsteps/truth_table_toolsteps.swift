// MARK: - v3.9.80 工具步数显示 · 真值表（源护栏 + 步数算式镜像）
//
// 用户原话（真机反馈，配图：对话里「AI 正在思考中 / 10 步工具调用」）：
//   「这个目前最多就显示10步，改成显示实际步数」。
//
// 根因：后端 `/api/stream/{taskId}` 为控体积，只下发**最近 10 步**的工具名
//   （`stream_api.py` 里 `_th = [...][-10:]`），而 App 摘要行直接用 `toolNames.count`
//   → 任何跑过 10 步以上的任务，一律显示成「10 步工具调用」。
// 修法：后端同一响应里**已经有**全量计数 `toolSeq`（每收到一个 function_call 事件 +1，
//   不受 10 步裁剪影响）→ App 解出它，摘要行改吃 `stream.toolSteps`（= max(toolSeq, toolNames.count)，
//   老后端无此键时回落条数，不显示假步数）。
//   v3.9.80 同批还把后端 `_th`/`_tspans` 的 `[-10:]` 去掉（明细与耗时都全量下发，两端同序同长）。
//
// 护栏三件事：
//   1. 源侧形态在位（解键 / 单一复位入口 / 门控与显示同口径 / 用 toolSteps 而不是 toolNames.count）；
//   2. 卫生项：耗时列表刷新判据用内容签名（防「条数不变内容变」的滑动窗口冻结）、
//      明细截断提示带非空守卫；工具卡失败行按钮与气泡同名（「重新生成」）；
//   3. 步数算式镜像（本机可算，改 max 口径表同步红）。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

let root = "qingliao"
func src(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: "\(root)/\(path)", encoding: .utf8) else { return "" }
    return s
}
/// 去注释行：负断言必须走它，否则「讲清旧形态」的注释会把断言染红（本仓已踩）
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

let streamSrc = src("Core/StreamClient.swift")
let authSrc = src("Core/AuthStore.swift")

/// v4.0.112（审查收口）：把「同一次解构」框起来再断言 —— 原来两条独立 `contains`
/// 可以各自命中文件里**不同位置**，位序 / 成员失守照样绿。切片取最近一个 `let (`
/// 到 `) = try await auth.streamPoll`；仍然**不认尾位**（下次再加字段不必改表），
/// 但断言里的成员必须落在同一次解构里。
func pollDeconstruct(_ src: String) -> String {
    guard let b = src.range(of: ") = try await auth.streamPoll") else { return "" }
    let head = src[src.startIndex..<b.lowerBound]
    guard let a = head.range(of: "let (", options: .backwards) else { return "" }
    return String(head[a.upperBound...])
}
let pollTuple = pollDeconstruct(streamSrc)
let chatViewSrc = src("Features/Chat/ChatView.swift")
// v4.0.x 工程治理拆分：工具卡的 4 个视图（ToolStepRow / ToolStepsTruncationNote / ToolProgressNote /
// ToolStepsSummaryRow）已从 ChatView.swift 搬到 ChatToolStepCards.swift。断言「卡片长什么样」读新文件，
// 断言「谁在调它 / 门控口径」仍读 ChatView.swift。混读会得到「源码在但看不见」的假红。
let toolCardsSrc = src("Features/Chat/ChatToolStepCards.swift")

// ── 0. 源可读（空了后面全是空真） ─────────────────────────────
check("StreamClient.swift 源可读", !streamSrc.isEmpty)
check("AuthStore.swift 源可读", !authSrc.isEmpty)
check("ChatView.swift 源可读", !chatViewSrc.isEmpty)
check("ChatToolStepCards.swift 源可读", !toolCardsSrc.isEmpty)

// ── 1. 后端键名对齐：toolSeq（App 解的就是它，改键名必须两处一起改） ──
check("AuthStore 解出全量步数键 toolSeq（与后端响应键同名）",
      authSrc.contains("j[\"toolSeq\"]"))
// v4.0.120：元组尾位会随新字段增长（本轮追加 memoAdded），所以这里**不再钉死**具体元组文本 ——
// 钉死的原意是「AuthStore 返回什么，调用方就同步解构什么」（漏解构 = 编译不过，本就不必测），
// 真正该守的是**新字段两端都接上了**：后端键名同名 + 出现在返回值里。
// 旧写法 `[[String: Any]], Double, Int) {` 在追加 `[String]` 后必然假红，且与本意无关。
check("streamPoll 元组已带上 memoAdded（v4.0.120 追加位）",
      authSrc.contains("let memoAdded = j[\"memoAdded\"] as? [String] ?? []")
      && authSrc.contains("toolSeq, memoAdded, reasoning"))
check("哨兵：解构切片取到（取不到 = 下面两条在空串上判绿）",
      !pollTuple.isEmpty && pollTuple.count < 400)
check("调用方同步解构出 memoAdded（漏了就是忘了接 UI）",
      pollTuple.contains("toolSeqIn") && pollTuple.contains("memoIn")
      && streamSrc.contains("!memoDismissed.contains($0)"))
// v4.0.90 思考流透传：同样只守「新字段两端都接上」——后端键名同名 + 出现在返回值里 + 调用方解构。
// ⚠️ v4.0.112 又追加 `notice` 位（阶段总结标记）→ 再次印证：**只认前缀串、不认尾位**。
//    本轮这 4 条就是被尾部闭括号钉死才假红（功能没问题、元组却长得不一样了）。
//    「新字段是否两端接上」由 scripts/ql_notice/ 的表负责，这里不重复钉。
check("streamPoll 已解出 reasoning 思考流键（v4.0.90 追加位）",
      authSrc.contains("let reasoning = j[\"reasoning\"] as? String ?? \"\"")
      && authSrc.contains("memoAdded, reasoning"))
check("调用方同步解构出 reasoningIn（漏了 = 思考气泡没数据源）",
      pollTuple.contains("memoIn") && pollTuple.contains("reasoningIn")
      && streamSrc.contains("if reasoningIn != streamReasoning { streamReasoning = reasoningIn }"))
check("StreamClient 思考流状态位 + 随流复位（同 toolSeq 生命周期）",
      streamSrc.contains("var streamReasoning: String = \"\"")
      && streamSrc.contains("toolStartedAt = 0\n        streamReasoning = \"\""))
// v4.0.94（用户 2026-10-11 真机口径）：「把模型思考过程吐出小字放到工具调用胶囊下面」+「那个 ☁️ 图标用
// 多彩圆角美化一下」。原断言只钉「一行 if + 调用」的形态 —— 位置一改就假红，而它真正该守的是
// **位置关系**（在工具卡之后、三点行之前）+ **单处挂载** + **行首图标形态**，故按位置重写。
// 索引一律在 messageList 切片内取：toolStepCards / thinkingIndicatorRow 的**定义**都在它之前（848 / 3222），
// 全文里搜会先命中的是定义而不是渲染点，那样位置断言会静默失效。
let chatCode = stripCommentLines(chatViewSrc)
let messageListCode: String = {
    guard let r = chatCode.range(of: "private var messageList: some View {") else { return "" }
    return String(chatCode[r.lowerBound...])
}()
let reasonIdx = messageListCode.range(of: "ReasoningPeekRow(text: stream.streamReasoning)")?.lowerBound
let toolCardIdx = messageListCode.range(of: "toolStepCards")?.lowerBound
let threeDotIdx = messageListCode.range(of: "thinkingIndicatorRow")?.lowerBound
check("思考气泡只在非空时渲染（老后端无键 → 不出现，优雅退化）",
      chatCode.contains("!stream.streamReasoning.isEmpty")
      && chatCode.contains("ReasoningPeekRow(text: stream.streamReasoning)"))
check("messageList 切片可读（空了下面两条位置断言就是空真）", !messageListCode.isEmpty)
check("思考小字落在「工具调用胶囊」正下方（toolStepCards 之后、三点行之前）",
      reasonIdx != nil && toolCardIdx != nil && threeDotIdx != nil
      && reasonIdx! > toolCardIdx! && reasonIdx! < threeDotIdx!)
check("思考小字只挂载一处（两处挂载 = 真机两份小字）",
      chatCode.components(separatedBy: "ReasoningPeekRow(text: stream.streamReasoning)").count - 1 == 1)
// v4.0.94：图标四条断言一律**限定在 `ReasoningIconTile` 切片内**（审查建议 ②）——
// 全文 contains 时，日后别处新增任一 20pt frame 就能把「色块改成 18pt」喂成绿。
// 切片按花括号配平取（锚到 struct 头、数到配对闭合 `}`），不依赖下一个声明的位置。
let iconTileCode: String = {
    guard let r = chatCode.range(of: "struct ReasoningIconTile: View") else { return "" }
    var depth = 0, started = false, end = r.upperBound
    var i = r.upperBound
    while i < chatCode.endIndex {
        let c = chatCode[i]
        if c == "{" { depth += 1; started = true }
        else if c == "}" {
            depth -= 1
            if started && depth == 0 { end = chatCode.index(after: i); break }
        }
        i = chatCode.index(after: i)
    }
    return String(chatCode[r.lowerBound..<end])
}()
check("思考行行首图标 = 多彩圆角色块（💭 emoji 已退役）",
      chatCode.contains("ReasoningIconTile()")
      && !chatCode.contains("Text(\"💭\")"))
check("图标色块切片可读（空了下面三条断言就是空真）",
      !iconTileCode.isEmpty && iconTileCode.count < 900)
check("圆角色块几何单一出口（20 / r6 / 11.5，与长按菜单 MenuIconTile.small 同口径）",
      iconTileCode.contains(".frame(width: 20, height: 20)")
      && iconTileCode.contains("cornerRadius: 6, style: .continuous")
      && iconTileCode.contains(".font(.system(size: 11.5, weight: .semibold))"))
// v4.0.94 定稿：用户 2026-10-11 看四版对比稿拍板**第 3 版「靛底 + 白大脑」**
//（首版曾按我推荐的「渐变 + 白云」落地，已被拍板覆盖 —— 断言把云和渐变都钉成不许回来）。
// 负断言只查 ChatView.swift：HomeCards 的天气卡/云卡也用 cloud.fill，那是别处的合法用法。
check("思考行行首图标符号 = 白大脑（用户拍板第 3 版）",
      iconTileCode.contains("Image(systemName: \"brain.fill\")")
      && !chatCode.contains("Image(systemName: \"cloud.fill\")"))
check("图标底色 = 靛且直取真源（Color(uiColor: MenuIconTint.indigo.uiColor)，不许抄 RGB 字面量）",
      iconTileCode.contains("Color(uiColor: MenuIconTint.indigo.uiColor)")
      && !iconTileCode.contains("Color(red:")
      && iconTileCode.contains(".background(Self.tileTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))"))

// ── 2. StreamClient：状态位 + 清零 + 同步 + 口径 ────────────────
check("StreamClient 有全量步数状态位 toolSeq",
      streamSrc.contains("var toolSeq: Int = 0"))
check("工具四件套有单一复位入口 resetToolProgress()（含 toolSeq/toolSpans/签名）",
      streamSrc.contains("func resetToolProgress() {")
      && streamSrc.contains("toolNames = []\n        toolSpans = []\n        toolSpansSig = \"\"\n        toolSeq = 0\n        toolStartedAt = 0"))
check("开新流走单一入口复位（不再各处手写四行）",
      streamSrc.contains("resetToolProgress()   // v3.9.80：工具四件套统一复位"))
check("切会话也走同一入口（原先这里手写三行、漏 toolSeq → 会把上一会话步数当本会话的）",
      chatViewSrc.contains("stream.resetToolProgress()"))
check("接回在途任务的两条路径也复位（restoreIfNeeded / adoptRemote 原先一件都不清）",
      streamSrc.components(separatedBy: "resetToolProgress()").count - 1 >= 4)
check("轮询落地 toolSeq（只在变化时写入，防每轮重建）",
      streamSrc.contains("if toolSeqIn != toolSeq { toolSeq = toolSeqIn }"))
check("摘要口径 = max(toolSeq, toolNames.count)（单一入口 toolSteps）",
      streamSrc.contains("var toolSteps: Int { max(toolSeq, toolNames.count) }"))

// ── 3. ChatView：摘要行吃 toolSteps；明细给截断提示 ────────────
check("摘要行步数吃 stream.toolSteps（不是 toolNames.count）",
      chatViewSrc.contains("ToolStepsSummaryRow(count: stream.toolSteps,"))
check("旧形态清零：摘要行不再直接用 stream.toolNames.count",
      !stripCommentLines(chatViewSrc).contains("ToolStepsSummaryRow(count: stream.toolNames.count"))
check("明细被裁时说清「更早的 N 步未列出」（抽成 ToolStepsTruncationNote，避免深层 ViewBuilder type-check 超时）",
      toolCardsSrc.contains("struct ToolStepsTruncationNote: View {")
      && toolCardsSrc.contains("Text(\"更早的 \\(hidden) 步未列出（只留最近 \\(shown) 步）\")"))
check("提示行带「明细非空」守卫（否则会输出「只留最近 0 步」这种自相矛盾的文案）",
      chatViewSrc.contains("if !stream.toolNames.isEmpty, stream.toolSteps > stream.toolNames.count {"))
check("工具卡门控与显示口径一致（用 toolSteps，不再只认 toolNames 是否为空）",
      chatViewSrc.contains("if stream.toolSteps > 0, auth.currentStreamSessionId == chat.sessionId {"))
check("旧门控清零：不再用 !stream.toolNames.isEmpty 当工具卡门控",
      !stripCommentLines(chatViewSrc).contains("if !stream.toolNames.isEmpty, auth.currentStreamSessionId"))
check("耗时列表刷新判据用内容签名（防「条数不变但内容变」的滑动窗口冻结 → 第 11 步起秒数错位）",
      streamSrc.contains("if spanSig != toolSpansSig {")
      && !stripCommentLines(streamSrc).contains("if spansIn.count != toolSpans.count {"))

// ── 3c. 工具卡外缘与 AI 气泡左缘齐平（v4.0.38 气泡内容侧贴边） ──
// 由头：v4.0.31 起本块自留 `.padding(.horizontal, Spacing.xl)`（12），是对着「AI 气泡外缘 18pt」
// （列表 6 + 气泡侧 Spacer 12）标定的；v4.0.38 气泡内容侧不再留白、外缘收到 6pt，本块若继续
// 自留 12 就会比它所属的 AI 气泡多缩进一档（真机可见错位）。只读 ChatView 的 toolStepCards 块，
// 免得把输入区/引用条里同名的 padding 一起误判。
func sliceBlock(_ s: String, from: String, to: String) -> String {
    guard let a = s.range(of: from) else { return "" }
    let rest = s[a.upperBound...]
    guard let b = rest.range(of: to) else { return String(rest) }
    return String(rest[..<b.lowerBound])
}
let toolStepCardsBlock = sliceBlock(chatViewSrc,
                                    from: "private var toolStepCards: some View {",
                                    to: "var body: some View {")
check("工具卡块读得到（切块非空，否则下面两条是空真）", !toolStepCardsBlock.isEmpty)
check("工具卡块不再自留横向留白（外缘与 AI 气泡齐平，v4.0.38 贴边）",
      !stripCommentLines(toolStepCardsBlock).contains(".padding(.horizontal, Spacing.xl)"))
check("工具卡仍受会话门控（防切片/改写误伤门控）",
      toolStepCardsBlock.contains("auth.currentStreamSessionId == chat.sessionId"))

// ── 3b. 同一动作一个名字：工具卡失败行 = 「重新生成」（v3.9.80 文案统一） ──
check("工具卡失败行按钮写「重新生成」（与气泡/长按菜单/选择文本菜单同名）",
      toolCardsSrc.contains("Label(\"重新生成\", systemImage: \"arrow.clockwise\")"))
check("无障碍标签说对行为（「重新生成回复」，不再误称「重试这步工具」）",
      toolCardsSrc.contains(".accessibilityLabel(\"重新生成回复\")"))
check("旧文案清零：工具行不再用「重试」命名这个动作（注释里可以提历史）",
      !stripCommentLines(toolCardsSrc).contains("重试这步工具")
      && !stripCommentLines(toolCardsSrc).contains("Label(\"重试\", systemImage:"))

// ── 4. 算式镜像：与 StreamClient.toolSteps 同口径，本机可算 ──────
func mirrorToolSteps(toolSeq: Int, names: Int) -> Int { max(toolSeq, names) }
let stepCases: [(Int, Int, Int, String)] = [
    (0, 4, 4, "老后端（无 toolSeq）→ 回落可数到的条数"),
    (3, 3, 3, "未超 10 步 → 两者一致"),
    (10, 10, 10, "正好 10 步"),
    (17, 10, 17, "17 步被后端裁到 10 → 必须显示 17（本次修复的核心用例）"),
    (25, 0, 25, "明细为空但计数在 → 显示 25"),
]
for (seq, names, want, why) in stepCases {
    check("镜像：toolSeq=\(seq) / 明细=\(names) → \(want)（\(why)）",
          mirrorToolSteps(toolSeq: seq, names: names) == want)
}

print("工具步数显示真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
