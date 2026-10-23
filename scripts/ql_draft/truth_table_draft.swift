import Foundation

// 轻聊输入框草稿 · 源码契约真值表（v4.0.103 待做池 #5）
// 与 scripts/ql_draft/test_draft.swift 分工：那边真跑 ChatDraftStore 的行为（按会话隔离 / 重载仍在 /
// 清空落盘 / 容量上限），这边钉**接线形态** —— 写入口唯一 + 四个时机在不在 + 键单一真源 + 落盘节流。
//
// 为什么必须钉（两条都真踩过）：
//   ① 草稿链路的退化全是静默的：输入栏改回 `text: $inputText` 直绑、别处新添一行 `inputText = x`
//      绕过写入口、清空时机挪成「点发送就清」……编译过、-parse 过、其它 60+ 张表照旧全绿，
//      只有用户装机后才发现「打的字又没了 / 切回来草稿变成上一个会话的」。
//   ② **扫描面本身也要钉**：第一版只扫 ChatView.swift，于是 `Features/Chat/ChatViewVoice.swift`
//      （同一类型的另一个文件）里两处直写 `inputText` 全程假绿 —— 而语音定稿那次文本变化恰好被
//      ChatView.swift 的 liveText 观察守卫挡掉，盘上只剩缺尾的中间结果（真丢字，只读审查才发现）。
//      所以现在扫描面 = `qingliao/Features/Chat/*.swift` **全目录**，并断言文件数 ≥ 5（防扫描面缩小）。
var pass = 0
var fail = 0
// ⚠️ @MainActor 不能去掉：-swift-version 6 下顶层全局变量（pass/fail）是 MainActor 隔离的，
//    非隔离函数改不了它（本地实测：main actor-isolated var 'pass' can not be mutated
//    from a nonisolated context）。同 scripts/ql_notifycopy 的教训。
@MainActor func ck(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { pass += 1; print("✅ \(name)") }
    else { fail += 1; print("❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

let repo = ProcessInfo.processInfo.environment["QL_REPO"] ?? FileManager.default.currentDirectoryPath
func read(_ rel: String) -> String {
    (try? String(contentsOfFile: repo + "/" + rel, encoding: .utf8)) ?? ""
}
/// 只留代码行：注释里提到 `inputText = …` 是说明，不该被计数（否则每写一段解释就要改表）。
func codeOnly(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { let t = $0.trimmingCharacters(in: .whitespaces); return !t.hasPrefix("//") && !t.hasPrefix("*") }
        .joined(separator: "\n")
}
func hits(_ hay: String, _ needle: String) -> Int {
    hay.components(separatedBy: needle).count - 1
}
/// 截取 [anchor, end] 之间的源码（含两端）；end 缺失时给前 4000 字符，避免静默空串假绿。
func slice(from anchor: String, to end: String, in src: String) -> String {
    guard let a = src.range(of: anchor) else { return "" }
    let rest = String(src[a.lowerBound...])
    guard let e = rest.range(of: end) else { return String(rest.prefix(4000)) }
    return String(rest[rest.startIndex..<e.upperBound])
}

// ── 读取面：Features/Chat 全目录（含 ChatViewVoice / ChatInputBar / ChatEffects / ChatViewExport …）──
let storeSrc = codeOnly(read("qingliao/Core/ChatDraftStore.swift"))
let modelsSrc = read("qingliao/Core/Models.swift")
let keyconfSrc = codeOnly(read("scripts/ql_draft/keyconf.swift"))
let chatView = codeOnly(read("qingliao/Features/Chat/ChatView.swift"))
let voiceSrc = codeOnly(read("qingliao/Features/Chat/ChatViewVoice.swift"))

var chatFiles: [String] = []
if let en = FileManager.default.enumerator(atPath: repo + "/qingliao/Features/Chat") {
    while let f = en.nextObject() as? String {
        if f.hasSuffix(".swift") { chatFiles.append(f) }
    }
}
chatFiles.sort()
var chatAll = ""
for f in chatFiles { chatAll += "\n" + codeOnly(read("qingliao/Features/Chat/" + f)) }

// ── A. 源可读 + 扫描面 ──────────────────────────────────────────
ck("ChatDraftStore.swift 源可读（路径变了会静默假绿）", !storeSrc.isEmpty)
ck("ChatView.swift 源可读", !chatView.isEmpty)
ck("ChatViewVoice.swift 源可读（P1 就发生在该文件）", !voiceSrc.isEmpty)
ck("Features/Chat 扫描面完整（≥5 个 .swift，实得 \(chatFiles.count)：\(chatFiles.joined(separator: ","))）",
   chatFiles.count >= 5)

// ── B. 键单一真源 ───────────────────────────────────────────────
let keyLine = #"static let chatDrafts = "qingliao_chat_drafts""#
ck("Models.swift 声明了唯一键（UserDefaultsKey.chatDrafts）", modelsSrc.contains(keyLine))
ck("测试替身与真值同字面量（防两处漂移）", keyconfSrc.contains(keyLine))

var appFiles: [String] = []
if let en = FileManager.default.enumerator(atPath: repo + "/qingliao") {
    while let f = en.nextObject() as? String {
        if f.hasSuffix(".swift") { appFiles.append(f) }
    }
}
appFiles.sort()
let literalUsers = appFiles.filter { read("qingliao/" + $0).contains(#""qingliao_chat_drafts""#) }
ck("键字面量在 App 源里恰好 1 处（实得 \(literalUsers)）", literalUsers == ["Core/Models.swift"])
let symbolUsers = appFiles.filter { read("qingliao/" + $0).contains("chatDrafts") }
ck("只有 Models.swift（声明）与 ChatDraftStore.swift（唯一消费）碰这个键（实得 \(symbolUsers)）",
   symbolUsers == ["Core/ChatDraftStore.swift", "Core/Models.swift"])
ck("唯一写盘点：ChatDraftStore 里 defaults.set( 恰好 1 处", hits(storeSrc, "defaults.set(") == 1)
ck("唯一读盘点：ChatDraftStore 里 defaults.dictionary( 恰好 1 处", hits(storeSrc, "defaults.dictionary(") == 1)
// 视图层**可以**为别的功能用 UserDefaults（ChatView 另有 server 缓存 / 待发队列 / 模型名等），
// 但草稿键一个字符都不许碰 —— 碰了就是绕过 ChatDraftStore 的第二套真源。
ck("视图层不许直接引用草稿键（UserDefaultsKey.chatDrafts）", !chatAll.contains("UserDefaultsKey.chatDrafts"))
ck("视图层不许出现草稿键字面量", !chatAll.contains(#""qingliao_chat_drafts""#))

// ── C. 写入口唯一 ───────────────────────────────────────────────
ck("输入栏走草稿绑定，不是 $inputText 直绑", chatView.contains("ChatInputBar(text: inputTextDraftBinding,"))
ck("反向：不得再有 text: $inputText（那是绕过草稿的老写法）", !chatAll.contains("text: $inputText"))
ck("写入口 setInputText 定义在场", chatView.contains("    func setInputText(_ text: String, clearingDraft: Bool = false) {"))
ck("写入口必须 internal：private 跨文件不可见，语音文件就只能退回直写（P1 复发）",
   !chatView.contains("private func setInputText("))
ck("打字即时落盘：binding 的 set 走同一个写入口", chatView.contains("set: { newValue in setInputText(newValue) }"))

// 直写白名单：整个 Features/Chat 目录里 `inputText = ` 只许这 4 处
// v4.0.151：声明那一处随「@State String → @Observable 载体」一并消失（见本节末尾三条正向断言）
let directWrites = hits(chatAll, "inputText = ")
ck("Chat 全目录直写 inputText 恰好 4 处（onAsk 点即发 / setInputText 体内 / 冷启动恢复 / 切会话恢复），实得 \(directWrites)",
   directWrites == 4)
ck("白名单①：onAsk「点一下就发」保持直写（立即发送，不落草稿）", chatAll.contains("inputText = q"))
let blankWrites = hits(chatAll, "inputText = \"\"")
ck("反向：inputText = \"\" 一处都没有（清空一律过写入口），实得 \(blankWrites)", blankWrites == 0)
// v4.0.151（长会话打字卡顿根治）：正文状态从 `@State String` 换成 @Observable 载体 ——
// 旧写法下每敲一键 SwiftUI 都重建整个聊天页（消息列表 + 全部浮层 + 二十多条 onChange），
// 会话越长越卡（用户真机「键盘按半天没反应」）。下面正反各钉一条，防有人「顺手改回 @State」。
ck("正文是 @Observable 载体（ChatView 持有 @State private var composerDraft）",
   chatView.contains("@State private var composerDraft = ChatComposerDraft()"))
ck("正文对外仍是 inputText（读写点零改动），且不再是 @State 字符串",
   chatView.contains("var inputText: String {") && chatView.contains("get { composerDraft.text }")
   && !chatView.contains("@State var inputText"))
ck("⚠️ 页级 body 不许读正文派生内容（读了 = 每次按键重建整页 = 打字卡顿复发）",
   !chatView.contains("SlashParser.panelPrefix(inputText)"))
ck("载体文件在场且只有一处 var text（单一真源）",
   read("qingliao/Core/ChatComposerDraft.swift").contains("final class ChatComposerDraft")
   && hits(read("qingliao/Core/ChatComposerDraft.swift"), "var text: String = \"\"") == 1)
ck("反向：语音文件（ChatViewVoice）直写 0 处 —— P1 的复发点", hits(voiceSrc, "inputText = ") == 0)
ck("语音两处都走写入口（exitVoiceMode 定稿 + onTextChange 中间结果）",
   hits(voiceSrc, "setInputText(") == 2 && voiceSrc.contains("setInputText(text)"))

let entryCalls = hits(chatAll, "setInputText(")
ck("写入口调用点 11 处（定义 1 + binding 1 + 语音 2 + 快捷指令 1 + Hermes 捷径 1 + 面板点选 1 + 发送清空 3），实得 \(entryCalls)",
   entryCalls == 11)
ck("快捷指令填充落草稿", chatView.contains("setInputText(prompt)"))
ck("Hermes 捷径填充落草稿", chatView.contains("setInputText(cmd)"))
// v4.0.104 #3：斜杠命令面板点选只**填入**命令文本（执行仍走 send() 唯一拦截口），填入也必须过写入口
// —— 直写 inputText 会绕过草稿：点了命令填上字、切走再回来就没了（与语音定稿同一个 P1 类）。
ck("面板点选命令走写入口（不是直写 inputText）", chatView.contains("setInputText(cmd.fillTemplate)"))

// ── D. 四个时机 ─────────────────────────────────────────────────
let switchSlice = slice(from: ".onChange(of: chat.sessionId) { prior, _ in",
                        to: "dropPendingQueue(dropping: prior)", in: chatView)
ck("切会话段定位成功", !switchSlice.isEmpty)
ck("切会话：先把离开会话的正文落档", switchSlice.contains("ChatDraftStore.shared.set(inputText, for: prior)"))
ck("切会话：再取回目标会话那份", switchSlice.contains("inputText = ChatDraftStore.shared.draft(for: chat.sessionId)"))
if let a = switchSlice.range(of: "ChatDraftStore.shared.set(inputText, for: prior)"),
   let b = switchSlice.range(of: "ChatDraftStore.shared.draft(for: chat.sessionId)") {
    ck("切会话：先存后取（顺序错了 = 切回来草稿变成上一个会话的）", a.lowerBound < b.lowerBound)
} else {
    ck("切会话：先存后取（顺序错了 = 切回来草稿变成上一个会话的）", false, "两处有一处缺失")
}
ck("切会话：立刻落盘（草稿有 0.4s 节流，「切走马上被杀」不能等）",
   switchSlice.contains("ChatDraftStore.shared.flush()"))

let bootSlice = slice(from: "private func bootstrapChat() async {", to: "refreshVisibleMessages()", in: chatView)
ck("冷启动段定位成功", !bootSlice.isEmpty)
ck("冷启动回填草稿（sessionId 首帧前就定好，onChange 冷启动不触发，只能这里补）",
   bootSlice.contains("ChatDraftStore.shared.draft(for: chat.sessionId)"))
ck("冷启动只在输入框空着时回填（绝不覆盖已在屏上的正文）", bootSlice.contains("if inputText.isEmpty {"))

// scenePhase 段：本文件只有一处 onChange(of: scenePhase)（5308），且 flush 在 checkMapClipboard 之后，
// 切片容易截早 → 直接在全文件里断言「非 active 分支落盘」（配合下面 flush 恰 2 处的计数即为定契）。
ck("离开前台落盘（scenePhase 非 active → flush）", chatView.contains("else { ChatDraftStore.shared.flush() }"))
let flushCalls = hits(chatAll, "ChatDraftStore.shared.flush()")
ck("flush 调用点恰好 2 处（切会话 + 离开前台）—— 治「flush() 是死代码」，实得 \(flushCalls)", flushCalls == 2)

let clearCalls = hits(chatView, "setInputText(\"\", clearingDraft: true)")
// v4.0.104 #3 起是 3 处：sendPendingNow（长上下文弹窗确认的后半程）+ send 直发 + 斜杠命令**命中**。
// 为什么不能只数个数（本表踩过）：个数对不上只会让后来人顺手把数字改大，方向性错误照旧放过 ——
// 所以三处逐个对上号，另加一条「未知命令支必须不清」的反向断言。
ck("「确认发送才清」恰好 3 处（sendPendingNow + send 直发 + 斜杠命令命中）", clearCalls == 3, "实得 \(clearCalls)")
// v4.1.x（插话）：`send()` 加了默认参数 → 签名变 `func send(interject: Bool = false) {`。
// 签名是这两个切片的锚点，改名会让 sendPendingNow 的切片静默退化（slice 找不到 end 时取 4000 字符，
// 反而「更宽」照样绿）——所以先把签名本身的唯一性钉住，再拿它当锚点。
ck("send() 签名唯一且带插话参数（v4.1.x：⚡ 复用同一入口，不再另开一个发送函数）",
   hits(chatView, "func send(interject: Bool = false) {") == 1,
   "实得 \(hits(chatView, "func send(interject: Bool = false) {"))")
let spnSlice = slice(from: "private func sendPendingNow(", to: "func send(interject: Bool = false) {", in: chatView)
ck("清点①：sendPendingNow 段定位成功", !spnSlice.isEmpty)
ck("清点①：sendPendingNow 里清（弹窗点「确认发送」才走到这）", spnSlice.contains("setInputText(\"\", clearingDraft: true)"))
// 终点取 send() 的**下一个**函数 —— 插话这一版 send() 后面紧跟 interjectSendCore（它不清草稿，
// 含在切片里不改变计数，但少截 130 行源码 = 变异更难藏）。
let sendSlice = slice(from: "func send(interject: Bool = false) {", to: "private func interjectSendCore(", in: chatView)
ck("send() 段定位成功（含斜杠拦截 + 直发清空）", !sendSlice.isEmpty)
ck("清点②③：send() 段内恰好 2 处清（斜杠命中 + 直发，多一处就是漏了确认闸）",
   hits(sendSlice, "setInputText(\"\", clearingDraft: true)") == 2,
   "实得 \(hits(sendSlice, "setInputText(\"\", clearingDraft: true)"))")
let slashSlice = slice(from: "if let (cmd, arg) = SlashParser.parse(inputText) {", to: "if chat.messages.count > 60 {", in: chatView)
ck("斜杠拦截段定位成功", !slashSlice.isEmpty)
ck("清点③：斜杠段内恰好 1 处清（只有「命令命中」那支）",
   hits(slashSlice, "setInputText(\"\", clearingDraft: true)") == 1,
   "实得 \(hits(slashSlice, "setInputText(\"\", clearingDraft: true)"))")
// 反向：未知命令支（/foobar）必须**保留原文** —— 审查抓到的误伤是「原话被销毁且没有回头发送的路径」
// 光看「appendSlashCard 之后」不够：往 else 支的**前面**插一处 clearingDraft 照样看不见
// （变异实测抓到的洞）→ 改成把「命中支」与「else 支」两侧分别切出来钉。
let hitBranch = slice(from: "if let cmd {", to: "runSlashCommand(cmd, arg: arg)", in: chatView)
ck("清点③：清的那支是「命令命中」分支（if let cmd → runSlashCommand）",
   !hitBranch.isEmpty && hitBranch.contains("setInputText(\"\", clearingDraft: true)"))
let elseBranch = slice(from: "runSlashCommand(cmd, arg: arg)", to: "appendSlashCard(SlashCardKit.unknownCommandText())", in: chatView)
ck("未知命令支不清草稿（命中支之后、appendSlashCard 之前无 clearingDraft）",
   !elseBranch.isEmpty && !elseBranch.contains("clearingDraft: true"))
if let r = slashSlice.range(of: "appendSlashCard(SlashCardKit.unknownCommandText())") {
    let after = String(slashSlice[r.upperBound...])
    ck("未知命令支不清草稿（appendSlashCard 之后无 clearingDraft）", !after.contains("clearingDraft: true"))
    ck("未知命令支在清那支**之后**（先清后 appendSlashCard = 分支搞反了）",
       slashSlice.range(of: "setInputText(\"\", clearingDraft: true)")!.lowerBound < r.lowerBound)
} else {
    ck("未知命令支不清草稿", false, "appendSlashCard 锚点缺失（被删了？自救出口不能省）")
}

// ── E. 落盘节流（只读审查 P2：每敲一键整表重建 + 整键写盘） ──────
ck("节流窗口常量在场（defaultCoalesceWindow = 0.4，取舍写在它的注释里）",
   storeSrc.contains("static let defaultCoalesceWindow: TimeInterval = 0.4"))
// 双真源事故面（第 3 轮审查抓到过）：旧常量没删干净 → 谁改那行 0.4 都静默无边（改小 = 逐键写盘回归）。
ck("窗口只有一处真源：全文 TimeInterval = 0.4 恰好 1 处", hits(storeSrc, "TimeInterval = 0.4") == 1)
ck("死代码清零：没有第二个同名窗口常量", !storeSrc.contains("static let coalesceWindow"))
ck("注入的窗口真被用上（防注入参数只存不用）",
   storeSrc.contains("let window = coalesceWindow") && storeSrc.contains("UInt64(window * 1_000_000_000)"))
ck("set 走节流（正常输入不逐键写盘）", storeSrc.contains("if text.isEmpty { flush() } else { scheduleFlush() }"))
ck("clear 走立即落盘（发完立刻被杀不许把草稿写回去）",
   storeSrc.contains("else { return }\n        needsPersist = true\n        flush()"))
ck("节流取消：flush 先 cancel 再写", storeSrc.contains("flushTask?.cancel()\n        flushTask = nil\n        guard needsPersist else { return }\n        persist()"))
// 脏标记：scenePhase 的 active→inactive→background 会连来两次 flush，没脏标记就是每次退后台白写两次
ck("脏标记：set 置脏", storeSrc.contains("needsPersist = true\n        evictIfNeeded()"))
ck("脏标记：clear 置脏", storeSrc.contains("else { return }\n        needsPersist = true\n        flush()"))
ck("脏标记：persist 落盘后清脏", storeSrc.contains("forKey: UserDefaultsKey.chatDrafts)\n        needsPersist = false"))
ck("节流任务真在写盘（防有人把 Task 体掏空成空壳）", storeSrc.contains("self?.persist()"))

// ── F. 行为表在场 ───────────────────────────────────────────────
ck("行为表 test_draft.swift 在场且真跑生产源码（带注入窗口）",
   read("scripts/ql_draft/test_draft.swift").contains("ChatDraftStore(defaults: suite, coalesceWindow:"))
ck("行为表覆盖「节流窗口内未写盘 + flush 后仍在」两条（与本节流契约互为印证）",
   read("scripts/ql_draft/test_draft.swift").contains("s1.flush()"))
ck("行为表注入长窗口（600s）换确定性，并单独钉出厂值 0.4",
   read("scripts/ql_draft/test_draft.swift").contains("coalesceWindow: 600")
   && read("scripts/ql_draft/test_draft.swift").contains("ChatDraftStore.defaultCoalesceWindow == 0.4"))
ck("替身 keyconf.swift 在场", !keyconfSrc.isEmpty)

print(fail == 0 ? "✅ ALL PASS（\(pass) 项）" : "❌ \(fail) 项失败")
exit(fail == 0 ? 0 : 1)
