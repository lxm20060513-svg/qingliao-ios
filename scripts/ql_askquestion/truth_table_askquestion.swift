// MARK: - v3.9.110 AI 中途追问「问题卡」· 真值表（源护栏）
//
// 由头：AI 干长任务时中途要用户确认一个选择（后端 ask_user.py 推 task_type=question 的
//       收件箱条目）。用户从三方案对比稿拍板「方案 A」，三条口径：
//         ① 会话内联一张卡，不做独立页/不做弹窗（上下文不丢）；
//         ② 快捷选项胶囊 + 自由输入框并存（有选项也能自己打字）；
//         ③ 卡一直留着，答过变「已答态」（题干+答案，不再可交互）。
//
// 本表钉住的是**接线**，不是观感 —— 这类功能最容易的坏法是「删了一处接线，卡片还在
// 界面上出现，只是变成死卡/宠物文案」，静态看全绿、真机上点不动。所以每条断言都要求
// 「切片内」命中，而不是整个文件里出现过（全文件 `contains` 判定 = 假绿）。
//
// 契约两端（改一边必须同步改另一边，本表在两端都能读到时会同时校验）：
//   iOS 解析 qingliao/Core/Models.swift: splitQuestion(_:)
//   后端生成 scripts/ql_ask/ask_user.py: OPT_SEP_LINE / build_text()
//
// 用法：./check_swift.sh 第 48 步
// 注：后端副本（../scripts/ql_ask/ask_user.py）在 CI 上不存在 → 那两条自动跳过并打印提示，
//     不允许因此变红（CI 仓里没有 Hermes 侧脚本）。

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
/// 去注释行：源码注释里必然会提到历史形态与反例，不算违规
func stripComments(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard let r = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<r.lowerBound])
    }.joined(separator: "\n")
}
/// 取 from..to 之间的源码（切片失败返回空串 —— 由「能切到」断言抓出，不让后续断言白写）
func slice(_ s: String, from: String, to: String) -> String {
    guard let a = s.range(of: from) else { return "" }
    let rest = s[a.upperBound...]
    guard let b = rest.range(of: to) else { return "" }
    return String(rest[..<b.lowerBound])
}
/// 首次出现的行号（1-based；找不到 = 0）—— 用于「A 必须写在 B 之前」这类顺序断言
func lineNo(_ s: String, _ needle: String) -> Int {
    for (i, l) in s.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
    where l.contains(needle) { return i + 1 }
    return 0
}

// ── 读源 ──────────────────────────────────────────────────────────────
let models = stripComments(src("Core/Models.swift"))
let bubble = stripComments(src("Features/Chat/ChatMessageBubble.swift"))
let chatview = stripComments(src("Features/Chat/ChatView.swift"))
let chatstore = stripComments(src("Core/ChatStore.swift"))
let inbox = stripComments(src("Core/InboxStore.swift"))
let card = stripComments(src("Features/Chat/ChatQuestionCard.swift"))

check("五个源文件都读到了（读不到 = 路径变了，后面全是白写）",
      !models.isEmpty && !bubble.isEmpty && !chatview.isEmpty && !chatstore.isEmpty
      && !inbox.isEmpty && !card.isEmpty)

// ── 1. 数据层：三个字段 + 落库/decode 必须都在 ──────────────────────────
check("ChatMessage 有 questionId（没有它 → 卡片退化成普通气泡）",
      models.contains("var questionId: String?"))
check("ChatMessage 有 questionOptions（快捷选项）",
      models.contains("var questionOptions: [String]?"))
check("ChatMessage 有 questionAnswer（已答态唯一的真值源）",
      models.contains("var questionAnswer: String?"))
check("decode 读了 questionId",
      models.contains("msg.questionId = d[\"questionId\"] as? String"))
check("decode 读了 questionOptions",
      models.contains("msg.questionOptions = d[\"questionOptions\"] as? [String]"))
check("decode 读了 questionAnswer",
      models.contains("msg.questionAnswer = d[\"questionAnswer\"] as? String"))
// 落库：三个字段都要进 payload，漏一个 → 换机/重开 App 后卡片信息丢一半
let payload = slice(chatstore, from: "if let q = m.questionId {", to: "if let q = m.quotedText")
check("持久化 payload 带上 questionId", payload.contains("p[\"questionId\"] = q"))
check("持久化 payload 带上 questionOptions", payload.contains("p[\"questionOptions\"] = o"))
check("持久化 payload 带上 questionAnswer", payload.contains("p[\"questionAnswer\"] = a"))

// ── 2. 解析：切分必须「严格等号」，不能宽松包含 ──────────────────────────
let split = slice(models, from: "static func splitQuestion", to: "static func local(")
check("能切到 splitQuestion 实现体", !split.isEmpty)
check("分隔行按 trimming 后 == \"选项：\" 严格判定（宽松 contains 会把正文里的「选项：」当分隔）",
      split.contains("trimmingCharacters(in: .whitespaces) == \"选项：\""))
check("分隔行判定没有退化成 contains（假绿形态）",
      !split.contains("contains(\"选项") && !split.contains("contains(OPT_SEP"))
// v3.9.110：序号剥离必须**锚在行首**（正则），不能用行内 `range(of: ". ")`
// —— 行内写法会把选项自己带的「. 」当分隔符无声截断（「2. 用 A. 再验证」→ 只剩「再验证」）。
check("选项剥掉行首序号前缀（1. / 1、 / 1) 三种形态，不剥 → 按钮上带序号）",
      split.contains("#\"^\\s*\\d+\\s*[.、)．]\\s*\"#"))
check("序号剥离锚在行首、不许退回行内 range(of: \". \")（去注释判，防被说明性注释喂饱）",
      !stripComments(split).contains("range(of: \". \")"))
check("找不到分隔行时回落成「全是题干、无选项」",
      split.contains("return (text.trimmingCharacters(in: .whitespacesAndNewlines), [])"))

// ── 3. 渲染：问题卡必须从 body 早退，且走独立卡组件 ─────────────────────
let bodyBlock = slice(bubble, from: "var body: some View {", to: "private var normalBubbleBody")
check("能切到 MessageBubble.body 的早退段", !bodyBlock.isEmpty)
check("body 里按 questionId 早退（删掉 → 问题卡 msg 又走普通气泡链）",
      bodyBlock.contains("message.questionId != nil"))
check("早退分支渲染 ChatQuestionCard（删掉 → 空卡/白屏）",
      bodyBlock.contains("ChatQuestionCard(message:"))
check("早退分支把 onAnswerQuestion 传进卡（不传 → 卡片只读、点不动）",
      bodyBlock.contains("onAnswer: onAnswerQuestion"))
// 反断言：普通链里**不许**出现 ChatQuestionCard —— 否则说明早退被合并回去、口径分裂
let normalBlock = slice(bubble, from: "private var normalBubbleBody", to: "private func")
check("普通气泡链里没有 ChatQuestionCard（早退没被合并回去）",
      !normalBlock.contains("ChatQuestionCard"))
check("MessageBubble 声明了 onAnswerQuestion 参数",
      bubble.contains("var onAnswerQuestion: ((String) -> Void)? = nil"))

// ── 4. 作答回调：ChatView 必须传，且真的提交 ────────────────────────────
let callSite = slice(chatview, from: "MessageBubble(message: msg,", to: "onAnswerQuestion:")
check("能切到 ChatView 的 MessageBubble 调用点", !callSite.isEmpty)
check("调用点这次真的在遍历里（切到了 onContinueStep，不是切到别处）",
      callSite.contains("onContinueStep"))
check("调用点传了 onAnswerQuestion",
      chatview.contains("onAnswerQuestion: { answer in"))
check("作答回调真的调 InboxStore.answerQuestion（不调 → 点了没反应）",
      chatview.contains("inbox.answerQuestion(messageId:"))

// ── 5. 提交语义：先本地落地再网络，且打对端点 ────────────────────────────
let answerFn = slice(inbox, from: "func answerQuestion(", to: "\n    }")
check("能切到 answerQuestion 实现体", !answerFn.isEmpty)
check("作答端点 = /api/inbox/answer（后端 answer_question 就认这个）",
      answerFn.contains("\"/api/inbox/answer\""))
let lnLocal = lineNo(answerFn, "chat?.markQuestionAnswered")
let lnNet = lineNo(answerFn, "/api/inbox/answer")
check("先本地落地再发网络（本地行 \(lnLocal) < 网络行 \(lnNet)）：网络失败也不该丢用户给的答复",
      lnLocal > 0 && lnNet > 0 && lnLocal < lnNet)
check("空答案直接 return（不让空串占掉一条提问）",
      answerFn.contains("guard !text.isEmpty"))

// ── 6. 卡片自身：只读门控 + 已答态 + 三条拍板口径 ───────────────────────
check("无回调时不画输入控件（画了却点不动 = 比不画更差）",
      card.contains("else if onAnswer != nil"))
check("已答态由 questionAnswer 非空驱动",
      card.contains("questionAnswer ?? \"\")"))
check("卡一直留着：已答只切形态、不隐藏卡（口径③）",
      card.contains("answerBlock"))
check("选项胶囊存在（口径② 点一下就答）",
      card.contains("optionPills") || card.contains("questionOptions"))
check("自由输入框与选项并存（口径② 有选项也能自己打字）",
      card.contains("TextField"))
check("作答统一走 submit 收敛（不许选项/输入两条各自发）",
      card.contains("onAnswer(text)"))

// ── 7. 两端契约：题干格式必须一致（后端副本在才校验）────────────────────
let bePath = "../scripts/ql_ask/ask_user.py"
if let be = try? String(contentsOfFile: bePath, encoding: .utf8) {
    check("后端 OPT_SEP_LINE 就是 iOS 严格等号比较的那个串",
          be.contains("OPT_SEP_LINE = \"选项：\""))
    check("后端问句条目带 task_type=\"question\"（App 才按问题卡分流）",
          be.contains("\"task_type\": \"question\""))
    check("后端 want_id=True（没有 id，App 作答后 AI 侧取不走答案）",
          be.contains("\"want_id\": True"))
} else {
    print("⚠️ 跳过 3 条后端契约断言（\(bePath) 不在 CI 仓里，Hermes 侧才有）")
}

print("问题卡真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
