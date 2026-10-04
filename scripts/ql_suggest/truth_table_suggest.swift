import Foundation

// 建议池① 提问推荐「猜你想问」· App 侧真值表
// 分三段：
//   A. FollowUpSuggest 纯函数（真实编译 Core/FollowUpSuggest.swift，跑真逻辑）
//   B. ChatStore.applySuggestions 语义（用一份 ChatStore 影子实现跑同款锚点算法）
//   C. 源级接线断言（钉死「点了不重复插 user 消息」「换一批是替换」「空候选不渲染」等）

nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0
nonisolated(unsafe) var fails: [String] = []

func ck(_ name: String, _ got: Any, _ want: Any) {
    if "\(got)" == "\(want)" { pass += 1 } else {
        fail += 1
        fails.append("\(name)\n     期望=\(want)\n     实得=\(got)")
    }
}

func ckTrue(_ name: String, _ b: Bool) { ck(name, b, true) }
func ckFalse(_ name: String, _ b: Bool) { ck(name, b, false) }

// ================= A. FollowUpSuggest 纯函数 =================
ck("端点路径", FollowUpSuggest.endpoint, "/api/agent/suggest_questions")

ck("解析正常三条", FollowUpSuggest.parseQuestions(["a？", "b？", "c？"]).count, 3)
ck("解析 nil → 空", FollowUpSuggest.parseQuestions(nil), [])
ck("解析缺字段 → 空", FollowUpSuggest.parseQuestions(nil as Any?), [])
ck("解析非数组 → 空", FollowUpSuggest.parseQuestions("abc"), [])
ck("解析剔空串", FollowUpSuggest.parseQuestions(["", "  ", "真问题？"]).count, 1)
ck("解析剔非字符串", FollowUpSuggest.parseQuestions([1, nil, "真问题？"]).count, 1)
ck("解析去重（带问号差异）", FollowUpSuggest.parseQuestions(["吃什么？", "吃什么"]).count, 1)
ck("解析截断到 3", FollowUpSuggest.parseQuestions(["1？", "2？", "3？", "4？", "5？"]).count, 3)
ck("解析自定义上限", FollowUpSuggest.parseQuestions(["1？", "2？", "3？"], maxCount: 2).count, 2)
ck("解析上限 0 → 空", FollowUpSuggest.parseQuestions(["1？"], maxCount: 0), [])
ck("解析保留原文不改写", FollowUpSuggest.parseQuestions(["  晚上吃火锅？  "]), ["晚上吃火锅？"])

ck("shouldRender 空数组", FollowUpSuggest.shouldRender([]), false)
ck("shouldRender 一条", FollowUpSuggest.shouldRender(["x？"]), true)

ck("dedupKey 去问号", FollowUpSuggest.dedupKey("a？"), "a")
ck("dedupKey 去句号+感叹号", FollowUpSuggest.dedupKey("a。!"), "a")
ck("dedupKey 去空白", FollowUpSuggest.dedupKey("  a  "), "a")
ck("dedupKey 保留中间空格", FollowUpSuggest.dedupKey("a b？"), "a b")

// exclude 累积：上一批 ∪ 已问过
ck("exclude 合并两组", FollowUpSuggest.excludeBatch(previous: ["p1"], askedTexts: ["a1"]).count, 2)
ck("exclude 跨组去重", FollowUpSuggest.excludeBatch(previous: ["吃火锅？"], askedTexts: ["吃火锅"]).count, 1)
ck("exclude 组内去重", FollowUpSuggest.excludeBatch(previous: ["x", "x"], askedTexts: []).count, 1)
ck("exclude 剔空", FollowUpSuggest.excludeBatch(previous: ["", "  "], askedTexts: []), [])
ck("exclude 上限截断", FollowUpSuggest.excludeBatch(previous: ["1", "2", "3"], askedTexts: ["4", "5", "6"], maxCount: 4).count, 4)
ck("exclude 单条截断 60", FollowUpSuggest.excludeBatch(previous: [String(repeating: "字", count: 200)], askedTexts: []).first!.count, 60)
ck("exclude 前一批优先", FollowUpSuggest.excludeBatch(previous: ["prev"], askedTexts: ["asked"]), ["prev", "asked"])

ck("recentUserTexts 只取 user", FollowUpSuggest.recentUserTexts(roles: ["user", "assistant", "user"], contents: ["q1", "a1", "q2"]),
   ["q2", "q1"])
ck("recentUserTexts 跳过空", FollowUpSuggest.recentUserTexts(roles: ["user", "user"], contents: ["", "  "]), [])
ck("recentUserTexts 无 user", FollowUpSuggest.recentUserTexts(roles: ["assistant"], contents: ["a"]), [])
ck("recentUserTexts 上限", FollowUpSuggest.recentUserTexts(
    roles: ["user", "user", "user"], contents: ["a", "b", "c"], limit: 2), ["c", "b"])
ck("recentUserTexts 长度不齐不崩", FollowUpSuggest.recentUserTexts(roles: ["user", "user"], contents: ["only"]), ["only"])
ck("recentUserTexts 空数组", FollowUpSuggest.recentUserTexts(roles: [], contents: []), [])

// ================= B. ChatStore 锚点算法（影子实现，同款语义） =================
struct M {
    var role: String, id: String
    var isUser: Bool { role == "user" }
    var suggestions: [String]?
}

/// ChatStore.applySuggestions 的锚点算法影子（口径必须与 Core/ChatStore.swift 一致）
func applySuggestions(_ qs: [String], afterUserID: String?, _ msgs: inout [M]) {
    let cleaned = FollowUpSuggest.parseQuestions(qs)
    guard let anchorID = afterUserID, !anchorID.isEmpty,
          let anchorIdx = msgs.lastIndex(where: { $0.isUser && $0.id == anchorID }) else { return }
    var regionEnd = anchorIdx + 1
    while regionEnd < msgs.count, !msgs[regionEnd].isUser { regionEnd += 1 }
    guard let target = msgs[(anchorIdx + 1)..<regionEnd].last(where: { $0.role == "assistant" }),
          let idx = msgs.firstIndex(where: { $0.id == target.id }) else {
        if cleaned.isEmpty { clear(afterUserID: anchorID, &msgs) }
        return
    }
    if !FollowUpSuggest.shouldRender(cleaned) { msgs[idx].suggestions = nil; return }
    msgs[idx].suggestions = cleaned   // ② 替换，不是追加
}

func clear(afterUserID: String?, _ msgs: inout [M]) {
    guard let anchorID = afterUserID, !anchorID.isEmpty,
          let anchorIdx = msgs.lastIndex(where: { $0.isUser && $0.id == anchorID }) else { return }
    var regionEnd = anchorIdx + 1
    while regionEnd < msgs.count, !msgs[regionEnd].isUser { regionEnd += 1 }
    for i in (anchorIdx + 1)..<regionEnd where msgs[i].role == "assistant" { msgs[i].suggestions = nil }
}

func sample() -> [M] {
    [M(role: "user", id: "u1"), M(role: "assistant", id: "a1"),
     M(role: "user", id: "u2"), M(role: "assistant", id: "a2"),
     M(role: "assistant", id: "a3")]
}

// 样本下标：0=u1 1=a1 2=u2 3=a2 4=a3
// 该轮回复区 = 锚点之后、下一个 user 之前（开区间）；挂**区内最后一条** assistant。
var m = sample()
applySuggestions(["x？", "y？"], afterUserID: "u2", &m)
ck("B 候选挂在本轮最后一条回答", (m[4].suggestions?.count ?? -1), 2)
ck("B 同轮非末条不挂", m[3].suggestions == nil, true)
ck("B 不挂到上一轮", m[1].suggestions == nil, true)
ck("B 不挂到用户消息", m[2].suggestions == nil, true)

// 单条 assistant 的轮次 → 挂那一条
var m2 = sample()
applySuggestions(["z？"], afterUserID: "u1", &m2)
ck("B 单条轮挂该条", (m2[1].suggestions?.count ?? -1), 1)
ck("B 单条轮不动下一轮", m2[3].suggestions == nil, true)

// 空数组 = 清掉旧候选（宁缺勿滥，不留陈旧）
var m3 = sample()
applySuggestions(["old1？", "old2？"], afterUserID: "u2", &m3)
applySuggestions([], afterUserID: "u2", &m3)
ck("B 空数组清掉旧候选", m3[4].suggestions == nil, true)

// 换一批 = 替换
var m4 = sample()
applySuggestions(["a？", "b？"], afterUserID: "u2", &m4)
applySuggestions(["c？", "d？"], afterUserID: "u2", &m4)
ck("B 换一批是替换不追加", (m4[4].suggestions ?? []), ["c？", "d？"])

// 全是垃圾（剔空后为空）⇒ 视为无候选
var m5 = sample()
applySuggestions(["x？"], afterUserID: "u2", &m5)
applySuggestions(["", "  "], afterUserID: "u2", &m5)
ck("B 全垃圾 → 清空", m5[3].suggestions == nil, true)

// anchor 不存在 / 空串 ⇒ 不动（不误挂）
var m6 = sample()
applySuggestions(["x？"], afterUserID: "nope", &m6)
ckTrue("B 锚点不存在 → 全无候选", m6.allSatisfy { $0.suggestions == nil })
var m7 = sample()
applySuggestions(["x？"], afterUserID: "", &m7)
ckTrue("B 锚点空串 → 全无候选", m7.allSatisfy { $0.suggestions == nil })

// 该轮没有 assistant ⇒ 不挂
var m8 = [M(role: "user", id: "u1"), M(role: "user", id: "u2")]
applySuggestions(["x？"], afterUserID: "u2", &m8)
ckTrue("B 该轮无回答 → 不挂", m8.allSatisfy { $0.suggestions == nil })

// clear：只清本轮
var m9 = sample()
applySuggestions(["a？"], afterUserID: "u1", &m9)
applySuggestions(["b？"], afterUserID: "u2", &m9)
clear(afterUserID: "u2", &m9)
ck("B clear 只清本轮·本轮已清", m9[4].suggestions == nil, true)
ck("B clear 不动别轮", (m9[1].suggestions?.count ?? -1), 1)

// ================= C. 源级接线断言 =================
func src(_ p: String) -> String { try! String(contentsOfFile: p, encoding: .utf8) }
let ROOT = "qingliao"
let chatView = src("\(ROOT)/Features/Chat/ChatView.swift")
let chatStore = src("\(ROOT)/Core/ChatStore.swift")
let models = src("\(ROOT)/Core/Models.swift")
let followUp = src("\(ROOT)/Core/FollowUpSuggest.swift")

// C1 候选为空不渲染该区
ckTrue("C 视图用 shouldRender 门控", followUpSuggestionsHasGuard(chatView))
ckTrue("C 视图从 suggestions 取", chatView.contains("if let qs = msg.suggestions"))

// C2 点候选不重复插入 user 消息（禁 chat.append）
let tapBody = chatView.slice(from: "private func tapFollowUpSuggestion", to: "private func refreshFollowUpSuggestions")
ckTrue("C 点候选调 sendCore", tapBody.contains("sendCore(text: text, imageData: nil)"))
ckFalse("C 点候选绝不 chat.append", tapBody.contains("chat.append"))
ckFalse("C 点候选绝不 chat.upsert", tapBody.contains("chat.upsert"))
// 实参序 = 声明序（sendCore(text:imageData:quotedText:allowExpense:)）
let callLine = tapBody.split(separator: "\n").first(where: { $0.contains("sendCore(text:") }) ?? ""
ckTrue("C 实参序=声明序（text 在前）", callLine.contains("sendCore(text:") && !callLine.contains("quotedText:"))
// 点候选顺带清候选区
ckTrue("C 点候选前清候选区", tapBody.contains("clearAllSuggestions()"))

// C3 换一批是替换 + 同端点
ckTrue("C 换一批走同一端点", chatView.contains("fetchFollowUpSuggestions(afterUserID: chat.messages[anchorIdx].id, batch: suggestBatch + 1)"))
ckTrue("C 换一批字样在", chatView.contains("Text(\"换一批\")"))
ckTrue("C store 侧替换非追加", chatStore.contains("messages[idx].suggestions = cleaned"))
ckFalse("C store 侧禁 append 候选", chatStore.contains("suggestions = (messages[idx].suggestions ?? []) + cleaned"))

// C4 一条 assistant 只挂一组候选（单一 suggestions 字段，不另设数组表）
ckTrue("C 模型只有单个 suggestions 字段", models.contains("var suggestions: [String]?"))
ckFalse("C 没有第二个 suggestions 容器", models.contains("var suggestionsList"))

// C5 后端异常静默（try? + 无 alert/toast）
let fetchBody = chatView.slice(from: "func fetchFollowUpSuggestions", to: "private func tapFollowUpSuggestion")
ckTrue("C 拉取用 try? 吞异常", fetchBody.contains("try? await auth.json"))
ckFalse("C 拉取失败不弹窗", fetchBody.contains("alert") || fetchBody.contains("showToast"))
ckTrue("C 会话切走则丢弃", fetchBody.contains("guard chat.sessionId == sid else { return }"))
ckTrue("C 同轮并发去重", fetchBody.contains("guard suggestLoadingAnchor != afterUserID else { return }"))

// C6 新提问清空候选
ckTrue("C sendCore 里清候选", chatView.contains("        clearAllSuggestions()\n        sendingLock = true"))

// C7 端点单一真源（字面量只在 FollowUpSuggest 里）
ckTrue("C 端点字面量单一真源", followUp.contains("static let endpoint = \"/api/agent/suggest_questions\""))
ck("C 端点字面量只出现一次", chatView.components(separatedBy: "/api/agent/suggest_questions").count - 1, 0)

// C8 候选不进 id、不进 payload（防行重插 / 防复读源）
let idBlock = models.slice(from: "    var id: String {", to: "var isUser: Bool")
ckFalse("C id 计算不含 suggestions", idBlock.contains("suggestions"))
let payloadBlock = models.slice(from: "func asPayload(", to: "// MARK: - v3.0.68")
ckFalse("C asPayload 不含 suggestions", payloadBlock.contains("suggestions"))
let payloadStore = chatStore.slice(from: "static func messagesPayload", to: "if m.isPush")
ckFalse("C messagesPayload 不含 suggestions", payloadStore.contains("suggestions"))

// C9 胶囊口径走统一出口（不自造 padding+Capsule）
ckTrue("C 胶囊用 topBar 口径", chatView.contains("PillSize.topBar.fontSize") && chatView.contains("PillSize.topBar.hPad"))
ckTrue("C 换一批胶囊用 page 口径", chatView.contains("Text(\"换一批\")") && chatView.contains("PillSize.page.fontSize"))

// C10 后端挂 /api/agent 前缀（免 nginx）—— 由后端表覆盖，这里钉 App 只打这一个端点
ckTrue("C 纯逻辑端点可读", FollowUpSuggest.endpoint.hasPrefix("/api/agent/"))

// C11 **问句判定只有后端一道闸门**：App 侧不得重复判「是不是问句」——
// 两道闸门口径一旦分叉（后端用疑问词表、App 用问号字面量），后端放过的候选会被 App 误杀，
// 而「模型偶尔漏打问号」那条补位能力也就没了。App 只做剔空/去重/截断。
ckFalse("C App 侧不判问号（不双闸门）",
        followUp.contains("contains(\"?\")") || followUp.contains("contains(\"？\")"))
ckFalse("C App 侧不引疑问词表", followUp.contains("怎么") || followUp.contains("为什么"))
// 且必须真做了剔空（证明不是把清洗整段删了来「绕开」这条断言）
ckTrue("C 仍做剔空白", followUp.contains("trimmingCharacters(in: .whitespacesAndNewlines)"))

// ---------- 切片/源级小工具 ----------
func followUpSuggestionsHasGuard(_ s: String) -> Bool {
    s.contains("if let qs = msg.suggestions, FollowUpSuggest.shouldRender(qs)")
}

extension String {
    func slice(from: String, to: String) -> String {
        guard let a = range(of: from)?.lowerBound else { return "" }
        guard let b = range(of: to, range: a..<endIndex)?.lowerBound else { return String(self[a...]) }
        return String(self[a..<b])
    }
}

print("\n建议池① 提问推荐 · App 侧真值表：\(pass) 通过 / \(fail) 失败")
if fail > 0 {
    print("\n失败明细：")
    for f in fails { print("  ❌ " + f) }
    exit(1)
}
print("🎉 全部通过 \(pass)")