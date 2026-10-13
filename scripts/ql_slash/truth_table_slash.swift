// #3 轻聊斜杠命令层 —— 源级真值表（读源文件做护栏，不 import 项目代码）
//
// 口径：方案 `.hermes/plans/2026-10-05_235848-qingliao-slash-commands.md`（v1 六条：
//   /new /model /stop /usage /记一笔 /help）。定案（§八 开放问题按建议值）：/usage = 插只读卡（不跳看板）、
//   /new 不带草稿、不做 /清空、不做面板最近使用记忆。
//
// 为什么必须有这张表（全是**静默退化**，编译过、-parse 过、其它 60+ 张表照旧全绿，装机才发现）：
//   ① 后端 api_server **没有任何命令分发** → 命令层只能建在 App 侧、靠自己拦输入。拦截一旦从 send()
//      顶部挪走一行、或被别的分支抢先，`/new` 就会被当普通消息发给模型（污染上下文 / 复读源 / 白烧 token）；
//   ② 未知命令（`/foobar`）若 parse 返回 nil → 同样直通 LLM，用户以为「命令没生效」，实际给模型发了条乱码；
//   ③ 命令注册表被复制成第二份（面板/帮助卡各写一份清单）→ 两条清单必然漂移，加命令只改一处；
//   ④ 面板改回 `if 命令模式 { … }` 插进输入栏 VStack 子节点 → 改 TextField 父级/兄弟集合 → 键盘弹一下又收回
//      （本仓老坑）；或把面板挂到 fullInputBar 父链上 → 父链 mangled 类型名变长（demangler 栈溢出病史）；
//   ⑤ `/usage` 的端点/解析在视图里再写一遍 → 与看板分叉，改端点漏一处；
//   ⑥ 卡片文本绕过 isPush → 卡 JSON 进 historyPayload → 模型把自己的卡读进上下文（复读/乱答）。
//
// 断言一律用**片段连续性**（closureBody / onlyWhitespaceBetween / orderedPair）取到片段再判，
// 禁用「整文件找位置」写法（恒真假绿）；每处取不到片段都有非空哨兵，否则反向断言恒真。
// ⚠️ **必须 cwd = 仓库根**（下面全是相对路径，漂移会静默全绿 → 前置哨兵会报红）。

import Foundation

// run_unit（Swift 5 口径）编跑 → 顶层不是 MainActor，check 用普通函数即可（本表全是纯文本判定，无并发面）。
var passCount = 0
var failCount = 0

func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉 `//` 行注释（注释里刻意写了「原来那样是错的」的说明，直接 grep 原文会被自己的注释判红）
func code(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            let head = line[line.startIndex..<r.lowerBound]
            if head.filter({ $0 == "\"" }).count % 2 == 1 { return String(line) }
            return String(head)
        }
        .joined(separator: "\n")
}

func countOf(_ needle: String, in hay: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return hay.components(separatedBy: needle).count - 1
}

/// 取标记之间的片段（nil = 标记缺失 → 调用方必须判失败，不能静默放过）
func closureBody(_ text: String, from: String, to: String) -> String? {
    guard let a = text.range(of: from)?.upperBound,
          let b = text.range(of: to, range: a..<text.endIndex)?.lowerBound else { return nil }
    return String(text[a..<b])
}

/// 两标记之间是否只有空白（「紧跟/相邻」类断言的唯一可靠写法）
func onlyWhitespaceBetween(_ text: String, _ a: String, _ b: String) -> Bool {
    guard let ra = text.range(of: a)?.upperBound,
          let rb = text.range(of: b, range: ra..<text.endIndex)?.lowerBound else { return false }
    return text[ra..<rb].allSatisfy { $0.isWhitespace }
}

/// 位置比较（after 必须先于 before 出现）
func orderedPair(_ text: String, after: String, before: String) -> Bool {
    guard let a = text.range(of: after)?.lowerBound,
          let b = text.range(of: before)?.lowerBound else { return false }
    return a < b
}

/// 递归列出目录下的 .swift（端点字面量要全仓唯一，得扫全仓）
func swiftFiles(_ dir: String) -> [String] {
    var out: [String] = []
    if let e = FileManager.default.enumerator(atPath: dir) {
        for case let p as String in e where p.hasSuffix(".swift") { out.append(dir + "/" + p) }
    }
    return out.sorted()
}

// MARK: - 读源

let core = code(src("qingliao/Core/SlashCommands.swift"))
let panel = code(src("qingliao/Features/Chat/SlashCommandPanel.swift"))
let inputbar = code(src("qingliao/Features/Chat/ChatInputBar.swift"))
let cv = code(src("qingliao/Features/Chat/ChatView.swift"))
let dashboard = code(src("qingliao/Features/Dashboard/DashboardView.swift"))
let usageFetcher = code(src("qingliao/Core/UsageFetcher.swift"))
let orb = code(src("qingliao/Features/OrbQuickMenu.swift"))
let recordKit = code(src("qingliao/Core/RecordKit.swift"))

// MARK: - 0. 前置哨兵（文件缺失 / cwd 漂移 → 后面全是恒真假绿）

check("哨兵：Core/SlashCommands.swift 非空（cwd 必须 = 仓库根）", core.count > 400)
check("哨兵：Features/Chat/SlashCommandPanel.swift 非空", panel.count > 400)
check("哨兵：ChatInputBar / ChatView / Dashboard / UsageFetcher / OrbQuickMenu / RecordKit 都可读",
      !inputbar.isEmpty && !cv.isEmpty && !dashboard.isEmpty
      && !usageFetcher.isEmpty && !orb.isEmpty && !recordKit.isEmpty)

// MARK: - A. 命令注册表单一真源（6 条，标题/说明/是否带参只定义一次）

check("注册表在 Core/SlashCommands.swift：enum SlashCommand 全仓只此一处",
      countOf("enum SlashCommand", in: core) == 1
      && !panel.contains("enum SlashCommand") && !cv.contains("enum SlashCommand"))

for c in ["case new", "case model", "case stop", "case usage", "case help"] {
    check("注册表含 \(c)", core.contains(c))
}
check("⚠️ 中文命令名逐字一致：case expense = \"记一笔\"（改字即用户那条命令失效）",
      core.contains("case expense = \"记一笔\""))

check("六条命令的说明（hint）表只在注册表里",
      core.contains("var hint: String")
      && !panel.contains("var hint") && !cv.contains("var hint"))
check("hint 表覆盖六条命令（6 个 return，无遗漏）",
      countOf("return \"", in: (closureBody(core, from: "var hint: String {", to: "var takesArgument") ?? "")) == 6)
check("takesArgument 只在注册表定义，且只有 /记一笔 为真",
      core.contains("var takesArgument: Bool { self == .expense }")
      && !panel.contains("var takesArgument"))
check("title 统一补前导 /（面板/帮助卡不再各自拼）",
      core.contains("var title: String { \"/\" + rawValue }")
      && !panel.contains("\" /\" + ") && !cv.contains("var title: String"))
check("点选填入模板（带参留尾空格）也在注册表",
      core.contains("var fillTemplate: String { takesArgument ? title + \" \" : title }"))

// MARK: - B. 解析口径（前导/尾部空白、参数切分、未知命令返回非 nil）

guard let parseTail = closureBody(core, from: "let hit = SlashCommand.allCases.first",
                                 to: "\n    }\n") else {
    check("哨兵：能取到 parse 尾部片段", false); exit(1)
}
check("哨兵：parse 尾部片段非空", parseTail.count > 40)
check("⚠️ parse 尾部只有 `return (hit, arg)`：未知命令**不是** nil（否则 send() 会把它发给模型）",
      parseTail.contains("return (hit, arg)") && !parseTail.contains("return nil"))
// 🚨 口径已改（独立审查误伤项）：单独 `/` 与路径类问句一律 nil（直通给 AI），**不再是**命令形态
check("单独 `/` → nil 直通（旧的 `return (nil, \"\")` 形态不得复活）",
      core.contains("guard !token.isEmpty else { return nil }")
      && !core.contains("return (nil, \"\")"))
check("前导/尾部空白容错：先 trim 再判前缀",
      orderedPair(core, after: "static func parse(_ raw: String)",
                  before: "guard trimmed.hasPrefix(\"/\") else { return nil }"))
check("命令 token = 首个空白之前（参数内允许空格）",
      core.contains("body.firstIndex(where: { $0.isWhitespace })"))
check("ASCII 命令名大小写不敏感",
      core.contains("let lower = token.lowercased()")
      && core.contains("$0.rawValue.lowercased() == lower"))
check("金额抽取的唯一实现只一处（两个出口共用一条正则）",
      countOf("firstNumberRange", in: core) == 3
      && countOf("#\"\\d+(?:\\.\\d+)?\"#", in: core) == 1)
check("金额口径 = 首个数字（leadingNumber + expenseParts 两个出口都在）",
      core.contains("static func leadingNumber(_ s: String) -> Double?")
      && core.contains("static func expenseParts(_ arg: String) -> (amount: Double, item: String)?"))
check("面板触发口径单一真源：panelPrefix（以 / 开头且不含空白）",
      core.contains("static func panelPrefix(_ text: String) -> String?")
      && core.contains("!t.contains(where: { $0.isWhitespace })"))

// MARK: - C. 面板：allCases 迭代（无第二份清单）+ 高度上限

check("面板行数迭代注册表过滤结果（不写死清单）",
      panel.contains("SlashParser.matches(prefix: prefix)")
      && panel.contains("ForEach(items, id: \\.self)"))
check("点选回调就是 onPick(cmd)（宿主决定填入）", panel.contains("Button { onPick(cmd) }"))

guard let helpBody = closureBody(panel, from: "static func helpText() -> String {",
                                 to: "static func unknownCommandText()") else {
    check("哨兵：能取到 /help 卡文案片段", false); exit(1)
}
check("哨兵：/help 卡片段非空", helpBody.count > 60)
check("⚠️ /help 卡迭代 SlashCommand.allCases（命令清单只有一份）",
      helpBody.contains("SlashCommand.allCases"))
check("反向：/help 卡里不得出现任何命令名字面量（否则是第二份清单）",
      !helpBody.contains("\"/new\"") && !helpBody.contains("\"/model\"")
      && !helpBody.contains("\"/stop\"") && !helpBody.contains("\"/usage\"")
      && !helpBody.contains("\"/记一笔\"") && !helpBody.contains("\"/help\""))

// ⚠️ 收敛到函数体切片（原先整文件级 `panel.contains` 是审查抓到的假绿缺口：
//    同文件别处出现同样文案照样过）
guard let unknownBody = closureBody(panel, from: "static func unknownCommandText() -> String {",
                                    to: "static func noticeText(") else {
    check("哨兵：能取到未注册命令卡文案片段", false); exit(1)
}
check("哨兵：未注册命令卡片段非空", unknownBody.count > 60)
check("未知命令文案逐字一致（标题 + 自救出口，用户看到的就是这句）",
      unknownBody.contains("\"title\": \"没有这个命令\"")
      && unknownBody.contains("输入 /help 看列表；这条想当普通消息发给 AI 的话，删掉开头的斜杠再发一次"))

check("面板高度：行高 44、上限 200（超出滚动）",
      panel.contains("static let rowHeight: CGFloat = 44")
      && panel.contains("static let maxContentHeight: CGFloat = 200")
      && panel.contains("min(CGFloat(itemCount) * rowHeight, maxContentHeight)"))
check("面板走全站玻璃出口（a11yGlass，不自造材质）",
      panel.contains("a11yGlass(.regular,") && panel.contains("Radius.card"))
check("面板不手拼任何其它路径/协议字符串（没有 URL / UserDefaults）",
      !panel.contains("UserDefaults") && !panel.contains("http"))

// 解析口径（审查误伤项）：只有「/ + 单 token 且 token 不含斜杠」才是命令形态
check("单独 `/` → 不是命令（nil），不吞不清草稿",
      core.contains("guard !token.isEmpty else { return nil }"))
check("⚠️ 路径类问句（token 里还有斜杠）→ 不是命令（直通给 AI）",
      core.contains("guard !token.contains(\"/\") else { return nil }"))

// MARK: - D. 输入栏：overlay 常驻层（绝不用 if 插 VStack 子节点）

check("⚠️ 面板挂 `.overlay(alignment:)` 常驻层",
      inputbar.contains(".overlay(alignment: .top) { slashCommandLayer }"))
check("反向：不得用 if 命令模式插节点（那会改 TextField 父级 → 键盘抖动）",
      !inputbar.contains("if slashPanelVisible") && !inputbar.contains("if slashPanelPrefix"))

guard let layerBody = closureBody(inputbar, from: "private var slashCommandLayer: some View {",
                                  to: "\n    }\n") else {
    check("哨兵：能取到 slashCommandLayer 片段", false); exit(1)
}
check("哨兵：面板层片段非空", layerBody.count > 120)
check("面板层用 opacity 显隐（不是条件插入/移除）",
      layerBody.contains(".opacity(slashPanelVisible ? 1 : 0)"))
check("面板层用 offset 起伏（向上位移 = 面板高 + 间距）",
      layerBody.contains(".offset(y:") && layerBody.contains("SlashCommandPanel.height(itemCount: count)")
      && layerBody.contains("+ Spacing.md)"))
check("⚠️ 位移量取自面板自身高度（底边恒在输入栏上缘之上：单条 44pt 也不再压住输入框行）",
      layerBody.contains("-(SlashCommandPanel.height(itemCount: count) + Spacing.md)"))
check("隐藏态不接收点击（避免挡住输入栏）",
      layerBody.contains(".allowsHitTesting(slashPanelVisible)"))
check("面板层本身就是面板（prefix + onPick 接线）",
      layerBody.contains("SlashCommandPanel(prefix: slashPanelPrefix, onPick: onPickSlash)"))
check("反向：面板层里不许再有 if 分支", !layerBody.contains("if "))

guard let frameBody = closureBody(inputbar, from: "private var fullInputBar: some View {",
                                  to: "\n    }\n") else {
    check("哨兵：能取到 fullInputBar 片段", false); exit(1)
}
check("哨兵：fullInputBar 片段非空", frameBody.count > 120)
check("⚠️ 输入栏 VStack 子集合不变（还是 messageRow + toolRow 两行）",
      frameBody.contains("VStack(spacing:") && frameBody.contains("messageRow")
      && frameBody.contains("toolRow") && !frameBody.contains("SlashCommandPanel")
      && !frameBody.contains("slashPanelVisible"))
check("⚠️ 父链仍是 3 个具名组（面板不许再往 fullInputBar 父链挂，防 mangled 类型名变长）",
      countOf(".modifier(InputBar", in: frameBody) == 3 && !frameBody.contains(".overlay("))

guard let glowBody = closureBody(inputbar, from: "private func applyInputBarGlowChrome",
                                 to: "private var slashCommandLayer") else {
    check("哨兵：能取到 applyInputBarGlowChrome 片段", false); exit(1)
}
check("哨兵：玻璃光晕组片段非空", glowBody.count > 120)
check("面板 overlay 挂在具名修饰器组内（改链只改这里的口径）",
      glowBody.contains(".overlay(alignment: .top) { slashCommandLayer }"))
check("⚠️ 必须 `.top` 对齐：用 `.bottom` 时单条面板会落进输入栏内约 18pt 压住输入框行（独立审查实测）",
      !glowBody.contains(".overlay(alignment: .bottom)"))

check("新增三参数追加在 onToggleAutoRead 之后（实参序 = 声明序）",
      orderedPair(inputbar, after: "var onToggleAutoRead: () -> Void = {}",
                  before: "var slashPanelVisible: Bool = false")
      && orderedPair(inputbar, after: "var slashPanelVisible: Bool = false",
                     before: "var slashPanelPrefix: String = \"\"")
      && orderedPair(inputbar, after: "var slashPanelPrefix: String = \"\"",
                     before: "var onPickSlash: (SlashCommand) -> Void = { _ in }"))

guard let callBody = closureBody(cv, from: "autoReadIcon: \"speaker.wave.2.fill\",",
                                 to: ".id(chat.sessionId)") else {
    check("哨兵：能取到 ChatInputBar 调用点片段", false); exit(1)
}
check("哨兵：调用点片段非空", callBody.count > 100)
check("调用点按同序传三个新参数（实参序 = 声明序，CI 才过）",
      orderedPair(callBody, after: "slashPanelVisible: slashPanelVisible,",
                  before: "slashPanelPrefix: slashPanelPrefix,")
      && orderedPair(callBody, after: "slashPanelPrefix: slashPanelPrefix,",
                     before: "onPickSlash:"))

// MARK: - E. 触发口径 + 点选填入

guard let prefixBody = closureBody(cv, from: "private var slashPanelPrefix: String {",
                                   to: "private func pickSlashCommand") else {
    check("哨兵：能取到 slashPanelPrefix 片段", false); exit(1)
}
check("触发口径走 SlashParser.panelPrefix（单一真源）",
      prefixBody.contains("SlashParser.panelPrefix(inputText)"))
check("语音态不渲染面板", prefixBody.contains("guard !voiceMode"))
check("不主动收/弹键盘（这里不碰 inputFocus）", !prefixBody.contains("inputFocus"))

guard let pickBody = closureBody(cv, from: "private func pickSlashCommand(_ cmd: SlashCommand) {",
                                 to: "private func runSlashCommand") else {
    check("哨兵：能取到 pickSlashCommand 片段", false); exit(1)
}
check("点选只填入命令文本，执行仍走 send() 的唯一拦截口（不在这里直接执行）",
      pickBody.contains("setInputText(cmd.fillTemplate)") && !pickBody.contains("runSlashCommand"))

// MARK: - F. send() 顶部拦截（在其它分支之前 / 命令不发 LLM）

check("⚠️ send() 的**第一句**就是命令拦截（前面只允许空白）",
      onlyWhitespaceBetween(cv, "func send() {",
                            "if let (cmd, arg) = SlashParser.parse(inputText) {"))

guard let sendBody = closureBody(cv, from: "if let (cmd, arg) = SlashParser.parse(inputText) {",
                                 to: "SpeechManager.shared.stop()") else {
    check("哨兵：能取到 send() 拦截体片段", false); exit(1)
}
check("哨兵：拦截体片段非空", sendBody.count > 100)
check("拦截体清空输入框且**过写入口**（不直写 inputText）",
      sendBody.contains("setInputText(\"\", clearingDraft: true)") && !sendBody.contains("inputText = "))
check("命中命令 → runSlashCommand(cmd, arg:)",
      sendBody.contains("runSlashCommand(cmd, arg: arg)"))
check("未识别命令 → 本地提示卡（不是发 LLM）",
      sendBody.contains("appendSlashCard(SlashCardKit.unknownCommandText())"))
check("未注册命令卡给出自救出口（说清怎样当普通消息再发一次）",
      panel.contains("删掉开头的斜杠"))
guard let unknownBranch = closureBody(sendBody, from: "} else {",
                                      to: "appendSlashCard(SlashCardKit.unknownCommandText())") else {
    check("哨兵：能取到未注册命令分支片段", false); exit(1)
}
check("哨兵：未注册命令分支片段非空", unknownBranch.count > 20)
check("⚠️ 未注册命令**不清草稿**（原文留在输入框，可改可重发 —— 审查误伤项）",
      !unknownBranch.contains("clearingDraft") && !unknownBranch.contains("setInputText"))
check("⚠️ 清空输入框只发生在**命中命令**分支内（排在 if let cmd 之后）",
      orderedPair(sendBody, after: "if let cmd {", before: "setInputText(\"\", clearingDraft: true)"))
check("⚠️ 拦截后直接 return（不进 sendCore / 不进 SendQueue）",
      sendBody.contains("return") && !sendBody.contains("sendCore")
      && !sendBody.contains("SendQueue") && !sendBody.contains("enqueue"))
check("拦截在「空文本 guard」之前（命令形态不该被空文本判定吃掉）",
      orderedPair(cv, after: "SlashParser.parse(inputText) {", before: "guard !text.isEmpty || img != nil"))

check("parse 非 nil 才进拦截（nil = 非命令，照常走原路径）",
      countOf("SlashParser.parse(inputText)", in: cv) == 1)

// MARK: - G. 命令派发：穷尽 6 条、零 LLM、逐条复用既有能力

guard let runBody = closureBody(cv, from: "private func runSlashCommand(_ cmd: SlashCommand, arg: String) {",
                                to: "private func runUsageCommand() {") else {
    check("哨兵：能取到 runSlashCommand 片段", false); exit(1)
}
check("哨兵：派发片段非空", runBody.count > 200)
check("派发就是一句 switch cmd（穷尽性检查认的就是它）",
      runBody.contains("switch cmd {") && countOf("switch cmd {", in: cv) == 1)
check("⚠️ 六个 case 一个不漏、且没有 default（漏一条 ql ios check 穷尽性即红）",
      countOf("case .", in: runBody) == 6 && !runBody.contains("default:"))
check("命令层永不发 LLM / 不进发送队列",
      !runBody.contains("sendCore") && !runBody.contains("SendQueue") && !runBody.contains("chat.send"))
check("命令层不自写 UserDefaults（单一真源）", !runBody.contains("UserDefaults"))

guard let newBody = closureBody(runBody, from: "case .new:", to: "case .model:") else {
    check("哨兵：能取到 /new 分支", false); exit(1)
}
check("哨兵：/new 分支非空", newBody.count > 40)
check("⚠️ /new 复用「新建会话」既有唯一入口 requestNewSession()",
      newBody.contains("chat.requestNewSession()"))
check("⚠️ /new 不带草稿：不搬草稿、不清草稿、也不直接 newSession() 清数据",
      !newBody.contains("ChatDraftStore") && !newBody.contains("setInputText")
      && !newBody.contains("chat.newSession()"))

guard let modelBody = closureBody(runBody, from: "case .model:", to: "case .stop:") else {
    check("哨兵：能取到 /model 分支", false); exit(1)
}
check("/model 复用输入栏模型胶囊同一条路径（ComposerModelSheet）",
      modelBody.contains("showComposerModel = true"))

guard let stopBody = closureBody(runBody, from: "case .stop:", to: "case .usage:") else {
    check("哨兵：能取到 /stop 分支", false); exit(1)
}
check("/stop 与输入栏停止键同口径（清队列 + 停流）",
      stopBody.contains("clearPendingQueue()") && stopBody.contains("stream.stop(auth: auth)"))

guard let usageBranch = closureBody(runBody, from: "case .usage:", to: "case .expense:") else {
    check("哨兵：能取到 /usage 分支", false); exit(1)
}
check("⚠️ /usage 插卡（runUsageCommand），**不跳看板**",
      usageBranch.contains("runUsageCommand()")
      && !usageBranch.contains("Dashboard") && !usageBranch.contains("selectedTab"))

guard let expenseBranch = closureBody(runBody, from: "case .expense:", to: "case .help:") else {
    check("哨兵：能取到 /记一笔 分支", false); exit(1)
}
check("哨兵：/记一笔 分支非空", expenseBranch.count > 40)
check("/记一笔 调用同一份解析（expenseParts）", expenseBranch.contains("runExpenseCommand(arg)"))

// MARK: - H. /usage 数据抓取单一真源（Dashboard 也改调它）

check("UsageFetcher 是端点/解析的唯一出口",
      usageFetcher.contains("static let tokenUsagePath = \"/api/nas/token-usage\"")
      && usageFetcher.contains("TokenUsage.parse(j)")
      && usageFetcher.contains("@MainActor"))

check("看板改调 UsageFetcher（不再自己带端点串）",
      dashboard.contains("await UsageFetcher.fetchTokenUsage(auth: auth)")
      && !dashboard.contains("\"/api/nas/token-usage\""))

check("⚠️ 全仓 `/api/nas/token-usage` 字面量只此一处（改端点只改一行）",
      countOf("\"/api/nas/token-usage\"", in: swiftFiles("qingliao").map { src($0) }.joined(separator: "\n")) == 1)

// 失败原因也必须是单一真源：抽共享入口时不许把看板原有的「真因/暂不可用」区分弄丢
// ⚠️ 必须钉「分支 → 返值」配对（空白归一化后逐字比）：只查「文件里有没有这句文案」会被
// 「把后端真因也一律返回查询失败」这种变异骗过（父代理复验抓到过一次假绿）。
let usageFlat = usageFetcher.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
check("失败原因单一真源：三分支各自返回自己的文案（不是一刀切）",
      usageFlat.contains("case .request: return \"token 用量查询失败\"")
      && usageFlat.contains("case .backend(let reason): return reason")
      && usageFlat.contains("case .unparsable: return \"token 用量暂不可用\""))
check("解析失败时仍按后端 error 字段区分（真因优先）",
      usageFetcher.contains("if let e = j[\"error\"] as? String, !e.isEmpty { return .failure(.backend(e)) }"))
check("看板显示失败真因（tokenUsageError = f.message，不再一律「查询失败」）",
      dashboard.contains("tokenUsageError = f.message")
      && !dashboard.contains("tokenUsageError = \"token 用量查询失败\""))
check("/usage 卡失败也走同一份文案（noticeText(f.message)，不自己编）",
      cv.contains("appendSlashCard(SlashCardKit.noticeText(f.message))"))

guard let usageCard = closureBody(panel, from: "static func usageText(_ usage: TokenUsage) -> String {",
                                  to: "private static func qlCard(") else {
    check("哨兵：能取到 /usage 卡文案片段", false); exit(1)
}
check("哨兵：/usage 卡片段非空", usageCard.count > 150)
check("⚠️ /usage 卡是**只读**（metrics 段，没有任何可提交表单）",
      usageCard.contains("\"type\": \"metrics\"") && !usageCard.contains("\"form\""))
check("/usage 卡标注只读 + 今日/本月两档",
      usageCard.contains("\"text\": \"只读\"")
      && usageCard.contains("usage.today.totalM") && usageCard.contains("usage.month.totalM"))

// MARK: - I. /记一笔 落库口径（与 OrbQuickMenu 同口径）+ 解析不出不落库

guard let expenseImpl = closureBody(cv, from: "private func runExpenseCommand(_ arg: String) {",
                                    to: "private func appendSlashCard") else {
    check("哨兵：能取到 runExpenseCommand 片段", false); exit(1)
}
check("哨兵：记账实现片段非空", expenseImpl.count > 200)
check("⚠️ 解析不出数字 → 先出提示卡、直接 return（不落库）",
      orderedPair(expenseImpl, after: "SlashParser.expenseParts(arg)",
                  before: "RecordStore.shared.addDetailed(")
      && expenseImpl.contains("appendSlashCard(SlashCardKit.noticeText(")
      && expenseImpl.contains("return"))
check("落库走唯一写入口 RecordStore.shared.addDetailed（不直写数组/文件名）",
      expenseImpl.contains("RecordStore.shared.addDetailed(kind: \"amount\"")
      && !expenseImpl.contains("RecordStore.shared.add(")
      && !expenseImpl.contains("UserDefaults"))
check("⚠️ 与 OrbQuickMenu 同口径：kind=amount / unit=元 / 分类走同一份词表",
      expenseImpl.contains("unit: \"元\"")
      && expenseImpl.contains("ChatRecordKit.category(for:")
      && orb.contains("addDetailed(kind: \"amount\"")
      && orb.contains("unit: \"元\"")
      && orb.contains("ChatRecordKit.category(for:"))
check("落库来源可辨（source: slash）且来源中文名已登记（账本/导出里不出现英文标识）",
      expenseImpl.contains("source: \"slash\"")
      && recordKit.contains("case \"slash\": return \"斜杠命令\""))
check("/记一笔 的回执卡复用既有记账卡文案（不自造第二套）",
      expenseImpl.contains("ChatRecordKit.cardText("))

// MARK: - J. 命令卡落会话：isPush（不进模型上下文）

guard let appendBody = closureBody(cv, from: "private func appendSlashCard(_ card: String) {",
                                   to: "\n    }\n") else {
    check("哨兵：能取到 appendSlashCard 片段", false); exit(1)
}
check("哨兵：落卡片段非空", appendBody.count > 120)
check("⚠️ 命令卡是 assistant + isPush → historyPayload 滤掉它（卡 JSON 不进上下文）",
      appendBody.contains("ChatMessage.local(role: \"assistant\"")
      && appendBody.contains("msg.isPush = true")
      && appendBody.contains("chat.append(msg)")
      && !appendBody.contains("historyPayload"))

// MARK: - 入口

if failCount == 0 {
    print("✅ ALL PASS（\(passCount) 项）")
    exit(0)
}
print("❌ 失败 \(failCount) 项 / 通过 \(passCount) 项")
exit(1)
