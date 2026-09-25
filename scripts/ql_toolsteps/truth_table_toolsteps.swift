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
let chatViewSrc = src("Features/Chat/ChatView.swift")

// ── 0. 源可读（空了后面全是空真） ─────────────────────────────
check("StreamClient.swift 源可读", !streamSrc.isEmpty)
check("AuthStore.swift 源可读", !authSrc.isEmpty)
check("ChatView.swift 源可读", !chatViewSrc.isEmpty)

// ── 1. 后端键名对齐：toolSeq（App 解的就是它，改键名必须两处一起改） ──
check("AuthStore 解出全量步数键 toolSeq（与后端响应键同名）",
      authSrc.contains("j[\"toolSeq\"]"))
check("streamPoll 返回值带上 toolSeq（元组尾多一位 Int，调用方同步解构）",
      authSrc.contains("[[String: Any]], Double, Int) {")
      && authSrc.contains("toolSpans, lastToolAt, toolSeq)"))

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
      chatViewSrc.contains("struct ToolStepsTruncationNote: View {")
      && chatViewSrc.contains("Text(\"更早的 \\(hidden) 步未列出（只留最近 \\(shown) 步）\")"))
check("提示行带「明细非空」守卫（否则会输出「只留最近 0 步」这种自相矛盾的文案）",
      chatViewSrc.contains("if !stream.toolNames.isEmpty, stream.toolSteps > stream.toolNames.count {"))
check("工具卡门控与显示口径一致（用 toolSteps，不再只认 toolNames 是否为空）",
      chatViewSrc.contains("if stream.toolSteps > 0, auth.currentStreamSessionId == chat.sessionId {"))
check("旧门控清零：不再用 !stream.toolNames.isEmpty 当工具卡门控",
      !stripCommentLines(chatViewSrc).contains("if !stream.toolNames.isEmpty, auth.currentStreamSessionId"))
check("耗时列表刷新判据用内容签名（防「条数不变但内容变」的滑动窗口冻结 → 第 11 步起秒数错位）",
      streamSrc.contains("if spanSig != toolSpansSig {")
      && !stripCommentLines(streamSrc).contains("if spansIn.count != toolSpans.count {"))

// ── 3b. 同一动作一个名字：工具卡失败行 = 「重新生成」（v3.9.80 文案统一） ──
check("工具卡失败行按钮写「重新生成」（与气泡/长按菜单/选择文本菜单同名）",
      chatViewSrc.contains("Label(\"重新生成\", systemImage: \"arrow.clockwise\")"))
check("无障碍标签说对行为（「重新生成回复」，不再误称「重试这步工具」）",
      chatViewSrc.contains(".accessibilityLabel(\"重新生成回复\")"))
check("旧文案清零：工具行不再用「重试」命名这个动作（注释里可以提历史）",
      !stripCommentLines(chatViewSrc).contains("重试这步工具")
      && !stripCommentLines(chatViewSrc).contains("Label(\"重试\", systemImage:"))

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
