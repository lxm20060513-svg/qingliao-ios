// MARK: - v3.9.81 聊天页工具卡进度小字 · 真值表
//
// 用户原话（真机反馈，配图：任务中心「进行中」卡片）：
//   「在聊天页的工具调用下面同步显示这段小字，也是用小字」。
//
// 背景：任务中心「进行中」卡片刻能看到后端 `_stream_progress_detail` 那行
//   `第 55 步 运行代码 · 837 字 · 静默 26 秒 · 最近：…`，而聊天页工具卡只有
//   「N 步工具调用」摘要 + 每步名/耗时 → 长任务里在聊天页看不出"跑到哪了"，
//   用户得专门开任务中心。修法：聊天页摘要行下面补同一行小字（App 侧自算，零后端改动）。
//
// 拍板口径（2026-09-27 clarify，用户从我的编号选项里选的）：位置 = 摘要行下面固定一行（收起/展开都看得到）；
//   文案 = **2b**：去掉「第 N 步」前缀（摘要行就写着「N 步工具调用」，小字再报一次步数是重复；
//   工具名照旧显示，看的还是「在干什么」）；时机 = 流式进行中显示，收尾即隐藏。
//
// ⚠️ 2026-10-11 口径反转（用户真机，本条覆盖上面那条 09-27 拍板）：他说「这个工具运行代码的小字…不需要了」
//   → 聊天页那行小字**已撤**（只撤视图层：ToolProgressNote 与 ChatView 调用点删除；模型层 progressNote /
//   文案层 StreamProgressText 一行未删，留作恢复点）。第 2b 段因此是**反向断言**；上半段（两端同口径 /
//   App 侧文案形态 / 算式镜像）**原样保留** —— 任务中心仍吃后端那行，护栏继续生效。
//
// 护栏三件事：
//   1. **两端同口径**：直接读后端 stream_api.py —— 格式串 / 尾部长度 / 静默分档 / 空白折叠
//      必须仍与 App 侧的 StreamProgressText 一致（任一端改了这里就红）；
//      「第 N 步」前缀是**唯一一处有意不去对齐**的差异（口径 2b）：后端保留（任务中心那张卡
//      没有摘要行）、App 侧删掉 —— 两个方向各有断言钉住，谁改动谁红。
//   2. 源侧形态在位：静默锚点（contentGrowAt）的**每一处**赋值点都在（漏一处 = 静默永远 0 秒）、
//      码点计数被标 nonisolated、门控 isStreaming、ChatView 插在摘要行之后；
//   3. 算式镜像（本机可算）：码点计数 / 尾部不切代理对 / 静默分档 / 空内容两种文案。

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

let noteSrc = src("Core/StreamProgressText.swift")
let streamSrc = src("Core/StreamClient.swift")
let chatSrc = src("Features/Chat/ChatView.swift")
// v4.0.x 工程治理拆分：ToolProgressNote 的**定义**搬到 ChatToolStepCards.swift，**调用点**仍在 ChatView.swift。
// 「struct 存在 / 样式令牌 / lineLimit」读新文件，「插在摘要行与明细之间」读 ChatView.swift。
let toolCardsSrc = src("Features/Chat/ChatToolStepCards.swift")
// 后端真源路径可用 QL_BACKEND_SRC 覆盖；找不到时下面的「两端同口径」段按 ⚠️ 跳过（并有独立断言兜住）
let backendPath = ProcessInfo.processInfo.environment["QL_BACKEND_SRC"] ?? "/opt/data/qingliao_backend/src/stream_api.py"
let backend = (try? String(contentsOfFile: backendPath, encoding: .utf8)) ?? ""
var skipped = 0
func checkBackend(_ name: String, _ cond: Bool) {
    if backend.isEmpty { skipped += 1; print("⚠️ 跳过（后端源码不在本机）：\(name)") }
    else { check(name, cond) }
}

// ── 0. 源可读（空了后面全是空真） ─────────────────────────────
check("StreamProgressText.swift 源可读", !noteSrc.isEmpty)
check("StreamClient.swift 源可读", !streamSrc.isEmpty)
check("ChatView.swift 源可读", !chatSrc.isEmpty)
check("后端 stream_api.py 可读（两端同口径的前提；缺则本段 ⚠️ 跳过）",
      !backend.isEmpty || ProcessInfo.processInfo.environment["QL_BACKEND_SRC"] == nil)

// ── 1. 两端同口径：后端那行文案的每个部件都还在 ────────────────
checkBackend("后端仍用「{工具} · N 字 · 静默 X · 最近：tail」格式串",
      backend.contains("%s · %d 字 · 静默 %s · 最近：%s"))
checkBackend("后端仍有无工具版「已生成 N 字 · 静默 X · 最近：tail」",
      backend.contains("已生成 %d 字 · 静默 %s · 最近：%s"))
checkBackend("后端空内容两条：工具版「工具：%s」/ 无工具版「思考中」",
      backend.contains("(\"工具：%s\" % tool_txt)") && backend.contains("\"思考中\""))
checkBackend("后端静默分档仍是 <60 秒显示秒、否则整分（%d 秒 / %d 分）",
      backend.contains("\"%d 秒\" % silent if silent < 60 else \"%d 分\" % (silent // 60)"))
checkBackend("后端尾部长度常量 PROGRESS_DETAIL_TAIL = 40",
      backend.contains("PROGRESS_DETAIL_TAIL = 40"))
checkBackend("后端尾部先按码点切片（content[-PROGRESS_DETAIL_TAIL:]）再折叠空白",
      backend.contains("content[-PROGRESS_DETAIL_TAIL:]") && backend.contains("re.sub(r\"\\s+\", \" \""))
checkBackend("后端仍保留「第 N 步」前缀（任务中心那张卡没有摘要行；App 侧刻意不拼 → 见下一段差异断言）",
      backend.contains("if seq > 1:") && backend.contains("\"第 %d 步 %s\" % (seq, zh)"))

// ── 2. App 侧形态在位 ────────────────────────────────────────
check("App 侧尾部长度同值 40（static let detailTail = 40）",
      noteSrc.contains("static let detailTail = 40"))
check("App 侧三种文案齐备（工具： / 思考中 / 已生成）",
      noteSrc.contains("\"工具：\\(tool)\"") && noteSrc.contains("\"思考中\"")
      && noteSrc.contains("\"已生成 \\(chars) 字 · 静默 \\(silentTxt) · 最近：\\(tail)\""))
check("App 侧有工具版格式串与后端同形",
      noteSrc.contains("\"\\(tool) · \\(chars) 字 · 静默 \\(silentTxt) · 最近：\\(tail)\""))
check("App 侧静默分档同口径（<60 秒显示秒，否则整分）",
      noteSrc.contains("silent < 60 ? \"\\(silent) 秒\" : \"\\(silent / 60) 分\""))
// 🚨 口径 2b：聊天页这行**刻意不带「第 N 步」**——摘要行已写步数，再报一次是重复。
//    负断言走 stripCommentLines：讲清旧形态的注释不算「拼了前缀」（本仓已踩过这个坑）。
check("App 侧工具名前缀是恒等实现（口径 2b：不拼「第 N 步」）",
      noteSrc.contains("static func toolBrief(name: String) -> String { name }"))
check("App 侧不再出现「第 N 步」拼接（含 seq 参数也一并删掉）",
      !stripCommentLines(noteSrc).contains("第 \\(seq) 步") && !stripCommentLines(noteSrc).contains("toolSeq"))
check("App 侧尾部走码点（codePointTail，不切代理对）",
      noteSrc.contains("static func codePointTail(") && noteSrc.contains("0xDC00"))
check("App 侧空白折叠同口径（\\s+ → 单空格 再 trim）",
      noteSrc.contains("collapseWhitespace") && noteSrc.contains("isWhitespace"))
check("App 侧字数按码点走 StreamClient.codePointCount（与后端 len() 对齐）",
      noteSrc.contains("StreamClient.codePointCount(content)"))

// 静默锚点：声明 + 每一处内容赋值点都要刷新（漏一处 = 静默永远 0 秒/永不走）
let sNoComment = stripCommentLines(streamSrc)
check("StreamClient 有静默锚点 contentGrowAt（private(set)）",
      sNoComment.contains("private(set) var contentGrowAt: TimeInterval = 0"))
check("codePointCount 标 nonisolated（StreamProgressText 是非隔离上下文）",
      sNoComment.contains("nonisolated static func codePointCount("))
check("进度文案出口 progressNote 存在", sNoComment.contains("var progressNote: String? {"))
check("progressNote 口径：只用真实 content + 最后一步工具名（不传 toolSeq —— 口径 2b 用不上）",
      sNoComment.contains("content: content,") && sNoComment.contains("toolName: toolNames.last ?? \"\"")
      && !sNoComment.contains("toolSeq: toolSeq,"))
check("收尾即隐藏（guard isStreaming）", sNoComment.contains("guard isStreaming else { return nil }"))
// 内容赋值点：start() 清零 + poll 追加 + recover 两处 + 恢复 + 接管 + detachLocally = 7 处刷新
// ⚠️ 算式：`components(separatedBy:)` 的 count = 出现次数 + 1（声明行是 `var contentGrowAt: TimeInterval`
// 带冒号、不匹配 `contentGrowAt =`），所以期望 8 = 7 次写入 + 1。别按「声明 1 + 写入 N」改期望值。
let growWrites = sNoComment.components(separatedBy: "contentGrowAt =").count
// 期望 8 = 写入 7（start 清零 / poll 追加 / recover 同任务 / recover 换任务 / 杀后台恢复 / 接管远端
// / v4.1.x detachLocally 移交后台跑流器时清零）+ 1
check("静默锚点赋值点齐（期望 8，实际 \(growWrites)）—— 漏一处 = 静默永远 0 秒", growWrites == 8)
check("start() 新流清零锚点", sNoComment.contains("contentGrowAt = 0"))
let pollWrite = sNoComment.contains("content += c") &&
    sNoComment.range(of: "content \\+= c(?:\\s*\\n\\s*contentGrowAt =)", options: .regularExpression) != nil
check("poll 追加内容后刷新锚点（漏了 → 静默永远 0 秒）", pollWrite)

// ── 2b. 聊天页**不再渲染**这行小字（2026-10-11 用户真机口径反转）────────────────
// 用户原话（配截图，红圈就点在那行「工具：运行代码」上）：「这个工具运行代码的小字…不需要了」。
// 处置：**只撤视图层** —— `ToolProgressNote` struct 与 ChatView 的调用点一并删除；模型层
// （StreamClient.progressNote）与文案层（StreamProgressText）一行未删，任务中心「进行中」
// 那行仍由后端 `_stream_progress_detail` 供（那才是它原本的落点）。要恢复聊天页这行，把
// 视图层那几行拿回来即可 —— 本表上半段的文案形态断言与第 3 段算式镜像都还在，回归即有护栏。
check("聊天页不再有 ToolProgressNote struct（视图层已撤；若有意恢复请连同本段一起改回正向断言）",
      !stripCommentLines(toolCardsSrc).contains("struct ToolProgressNote"))
check("ChatView 不再渲染进度小字（调用点与 stream.progressNote 都没了）",
      !stripCommentLines(chatSrc).contains("ToolProgressNote(text:") &&
      !stripCommentLines(chatSrc).contains("stream.progressNote"))
// 恢复点必须在位：模型层/文案层一行未删（上面第 1、2 段全绿即证 + 这两条兜底）
check("恢复点：StreamClient.progressNote 出口仍在", sNoComment.contains("var progressNote: String? {"))
check("恢复点：StreamProgressText 文案算式仍在", noteSrc.contains("static func line(content: String, toolName: String,"))
// 原子性：没误伤同卡片的其它口径（摘要行步数 / 答完折叠 / 1s 走秒仍服务于明细）
check("未改摘要行步数口径（仍读 stream.toolSteps）",
      chatSrc.contains("ToolStepsSummaryRow(count: stream.toolSteps,"))
check("未改答完折叠口径（toolStepsExpanded 仍在）", chatSrc.contains("toolStepsExpanded"))

// ── 3. 算式镜像（与 StreamProgressText.line 同口径，本机可算） ──
func mirrorCodePointCount(_ s: String) -> Int {
    let u = Array(s.utf16); var n = 0, i = 0
    while i < u.count {
        if u[i] >= 0xD800, u[i] <= 0xDBFF, i + 1 < u.count,
           u[i + 1] >= 0xDC00, u[i + 1] <= 0xDFFF { i += 2 } else { i += 1 }
        n += 1
    }
    return n
}
func mirrorTail(_ s: String, _ n: Int) -> String {
    let u = Array(s.utf16); var i = u.count; var taken = 0
    while i > 0, taken < n {
        let c = u[i - 1]
        if c >= 0xDC00, c <= 0xDFFF, i >= 2, u[i - 2] >= 0xD800, u[i - 2] <= 0xDBFF { i -= 2 } else { i -= 1 }
        taken += 1
    }
    return String(decoding: u[i...], as: UTF16.self)
}
func mirrorCollapse(_ s: String) -> String {
    var out = ""; var sp = false
    for ch in s {
        if ch.isWhitespace { if !sp { out.append(" ") }; sp = true } else { out.append(ch); sp = false }
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}
// 口径 2b：不带「第 N 步」（App 侧）；镜像只按工具名拼
func mirrorLine(content: String, tool: String, growAt: TimeInterval, now: TimeInterval) -> String {
    let brief = tool
    if content.isEmpty { return brief.isEmpty ? "思考中" : "工具：\(brief)" }
    let chars = mirrorCodePointCount(content)
    let silent = growAt > 0 ? max(0, Int(now - growAt)) : 0
    let st = silent < 60 ? "\(silent) 秒" : "\(silent / 60) 分"
    let tail = mirrorCollapse(mirrorTail(content, 40))
    if !brief.isEmpty { return "\(brief) · \(chars) 字 · 静默 \(st) · 最近：\(tail)" }
    return "已生成 \(chars) 字 · 静默 \(st) · 最近：\(tail)"
}

// 3.1 码点 vs 字素簇：用户截图里那行是中文正文，但 emoji 一旦进正文，字数必须仍与后端 len() 一致
let family = "👨‍👩‍👧"   // 5 码点 / 1 字素簇
check("镜像：emoji 家族按码点计（\(family) × 20 = 100 码点，字素簇只有 20）",
      mirrorCodePointCount(String(repeating: family, count: 20)) == 100)
check("镜像：emoji + 中文混排计数（5 + 3 = 8）", mirrorCodePointCount(family + "你好啊") == 8)

// 3.2 尾部：40 码点、不切代理对（8 个 emoji 家族正好 40 码点）
let manyFamily = String(repeating: family, count: 12)   // 60 码点
let tailFamily = mirrorTail(manyFamily, 40)
check("镜像：尾部 40 码点不切代理对（60 码点 → 8 个完整 emoji 家族）",
      tailFamily == String(repeating: family, count: 8))
check("镜像：纯中文尾部（50 字 + 尾巴 → 取后 40 字，字素=码点）",
      mirrorCollapse(mirrorTail(String(repeating: "汉", count: 50), 40)) == String(repeating: "汉", count: 40))
check("镜像：空白折叠（换行/连续空格 → 单空格 + 去首尾）",
      mirrorCollapse("  改成真抓\n\n全绿\t。 ") == "改成真抓 全绿 。")

// 3.3 整行文案（三条分支 + 静默分档，数值取自用户截图那行）
let shotContent = String(repeating: "汉", count: 500) + "改成真抓全绿。"
let l1 = mirrorLine(content: shotContent, tool: "运行代码", growAt: 1000, now: 1026)
check("镜像：与截图同形但去掉步数前缀（口径 2b，第 55 步不再出现）",
      l1.hasPrefix("运行代码 · ") && l1.contains(" 字 · 静默 26 秒 · 最近：") && !l1.contains("第 55 步"))
check("镜像：静默满 60 秒 → 整分（125 秒 → 2 分）",
      mirrorLine(content: "x", tool: "运行代码", growAt: 1000, now: 1125).contains("静默 2 分"))
check("镜像：静默 59 秒 → 仍显示秒", mirrorLine(content: "x", tool: "", growAt: 1000, now: 1059).contains("静默 59 秒"))
check("镜像：工具名开头，任何步数前缀都不拼（含第 1 步）",
      mirrorLine(content: "x", tool: "执行命令", growAt: 1000, now: 1000).hasPrefix("执行命令 · "))
check("镜像：无工具名 → 无工具版（老后端不报工具名也不崩）",
      mirrorLine(content: "abc", tool: "", growAt: 1000, now: 1005) == "已生成 3 字 · 静默 5 秒 · 最近：abc")
check("镜像：内容为空 + 有工具 → 「工具：运行代码」（同样不带步数）",
      mirrorLine(content: "", tool: "运行代码", growAt: 0, now: 9999) == "工具：运行代码")
check("镜像：内容为空 + 无工具 → 「思考中」",
      mirrorLine(content: "", tool: "", growAt: 0, now: 9999) == "思考中")
check("镜像：锚点缺失（growAt=0）不显示负静默", mirrorLine(content: "ab", tool: "", growAt: 0, now: 0).contains("静默 0 秒"))
check("镜像：时钟回拨不出现负静默（max(0, …)）",
      mirrorLine(content: "ab", tool: "", growAt: 2000, now: 1000).contains("静默 0 秒"))

print("进度小字真值表：通过 \(passCount) 项，失败 \(failCount) 项，跳过 \(skipped) 项")
if failCount > 0 { exit(1) }
