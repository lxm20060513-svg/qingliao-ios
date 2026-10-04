// v4.0.39 气泡动画（发送弹出 / 流式光带 / 三点上浮）接线真值表 —— Linux 本地预检用，纯 Foundation
//
// 编译运行（仓库根目录，权威入口是 check_swift.sh 末段）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_bubbleanim \
//       scripts/ql_bubbleanim/truth_table_bubbleanim.swift
//
// 为什么全是源级断言、没有一个「纯函数」可测：
//   本轮三处动画全是 SwiftUI 修饰符挂载（.transition / .offset / repeatForever），
//   没有可抽成纯函数的算法——headless Linux 也跑不了 SwiftUI。所以这张表的定位是
//   **钉死挂载点 + 钉死调度纪律 + 钉死旧形态已清除**，防的是「动画被顺手删掉」
//   与「有人改回会凝帧的调度」这两类静默回归（动画删了不报错，UI 只是回到旧观感）。
//
// 本轮踩过的坑（断言 D 段专门钉它）：
//   插过一次 StreamSweepBand 组件时，patch 的锚点字符串 `// v4.0.x：骨架换真图走淡入` 在
//   AIImageView 内部也出现 → 组件被塞进了 Image(...).clipShape() 的修饰符链里。
//   Swift 能编译过，但整段视图语义彻底错位。所以 B7 钉「StreamSweepBand 的 struct 定义
//   必须与 MessageBubble 同为顶层声明」，且必须出现在 MessageBubble **之前**。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

/// 断言：正例（要求为真）/ 反例（要求为假）分开计数，末尾核验反例占比。
func check(_ name: String, _ cond: Bool, negative: Bool = false) {
    print("\(cond ? "✅" : "❌") \(name)")
    if negative { negatives += 1 } else { positives += 1 }
    if !cond { failures += 1 }
}

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉 `//` 行注释（每行 `//` 之后全丢）。本仓注释里大量留有旧口径记录（正面教材），
/// 不剥就会把注释喂成假绿护栏。
func stripComments(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }
        .joined(separator: "\n")
}

// ———————————————————— 源载入 ————————————————————
let bubbleRaw = read("qingliao/Features/Chat/ChatMessageBubble.swift")
let chatRaw = read("qingliao/Features/Chat/ChatView.swift")
let motionRaw = read("qingliao/Theme/Motion.swift")

let bubble = stripComments(bubbleRaw)
let chat = stripComments(chatRaw)
let motion = stripComments(motionRaw)

check("源文件可读（bubble=\(bubbleRaw.count) chat=\(chatRaw.count) motion=\(motionRaw.count)）",
      !bubble.isEmpty && !chat.isEmpty && !motion.isEmpty)

// ———————————————————— A 段：Motion 令牌 ————————————————————
print("\n—— A 段：Motion 动效令牌 ——")

check("A1 Motion.enter 是带过冲的 spring（damping 0.72，本轮从 0.80 调下来）",
      motion.contains("static var enter: Animation") && motion.contains("dampingFraction: 0.72"))

check("A2 bubbleRise 位移常量存在且为 12pt",
      motion.contains("static let bubbleRise: CGFloat = 12"))

check("A3 streamBorn 浮现动画存在（流式首帧 / 三点上浮共用）",
      motion.contains("static var streamBorn: Animation"))

check("A4 光带时长 1.2s 与不透明度 3.5% 有独立常量（不散落魔法数）",
      motion.contains("streamSweepDuration: Double = 1.2")
      && motion.contains("streamSweepOpacity: Double = 0.035"))

// 光带不透明度上限：动画被系统冻住时会停在 56pt 宽的一条亮带上。3.5% 是「看不见」的量级，
// 0.1 就已经在白底上是一条明确的斜条了（用户会当成渲染 bug 报上来）。钉上限防手滑调亮。
let sweepOpacity = Double(
    motion.split(separator: "streamSweepOpacity: Double = ").last?
        .prefix(while: { $0.isNumber || $0 == "." }) ?? "1") ?? 1
check("A5 光带不透明度 ≤ 0.05（冻住时不可见）", sweepOpacity <= 0.05)

let enterDamping = Double(
    motion.split(separator: "dampingFraction: ").last?
        .prefix(while: { $0.isNumber || $0 == "." }) ?? "1") ?? 1
check("A6 Motion.enter 阻尼 ∈ [0.65, 0.85]（过冲够轻、又不过冲）",
      enterDamping >= 0.65 && enterDamping <= 0.85)

// ———————————————————— B 段：发送气泡动画接线 ————————————————————
print("\n—— B 段：发送气泡「弹上来」 ——")

// v4.0.40：判定源从 ChatMessageBubble 改成 ChatView.messageRow —— 过渡本来就在这一层
// （被判定 inserted 的是 messageRow 整块，气泡内部没有独立插入时刻）。
// ⚠️ 旧口径钉在气泡文件上，而实现已搬到 ChatView → 5 条断言集体判红、整张表被 check_swift.sh
// 直接 exit 1 掐停（后续护栏全不执行）。**改挂载点就要同步改判定源**，别留两处。
check("B1 用户与 AI 气泡走两套不同的 insertion 过渡（按 msg.isUser 分流）",
      chat.contains("msg.isUser")
      && chat.contains("insertion: msg.isUser"))

check("B2 用户气泡带位移入场（用 Motion.bubbleRise，不是裸魔法数）",
      chat.contains(".offset(y: Motion.bubbleRise)"))

check("B3 用户气泡锚点钉 .trailing（贴边侧放大，不朝屏幕中间漂）",
      chat.contains("scale: 0.88, anchor: .trailing"))

check("B4 AI 气泡入场克制（0.97 缩放，非 0.88）",
      chat.contains("AnyTransition.scale(scale: 0.97, anchor: .leading)"))

// v4.0.40 新增负向口径：过渡收敛到 messageRow 一处后，气泡文件里**不许**再留一份
// 「两套 transition 叠在一行上」的旧挂载（旧口径要求的那几串必须彻底不在气泡里）。
check("B4b 气泡文件已不含分角色 insertion 过渡（挂载点单一真源 = messageRow）",
      !bubble.contains("insertion: msg.isUser")
      && !bubble.contains(".scale(scale: 0.88, anchor: .trailing)"))

check("B5 移除态只淡入不位移（删消息不该也弹一下）",
      chat.contains("removal: .opacity"))

check("B6 旧的统一 0.94 过渡已清除",
      !chat.contains(".scale(scale: 0.94, anchor: msg.isUser")
      && !bubble.contains(".scale(scale: 0.94, anchor: message.isUser"))

// B6b v4.0.40：动画事务必须由 refreshVisibleMessages 的纯追加分支开（v4.0.39 失效的真根因：
// onChange 的 action 不带动画上下文 → transition 静默不播，无报错无日志）。
check("B6b 纯追加才播插入动画（无事务则 transition 静默不播）",
      chat.contains("MessageInsertAnim.isSingleAppend(prev: prevIDs, next: next.map(\\.id))")
      && chat.contains("withAnimation(Motion.enter) { visibleMessagesCache = next }"))

// ———————————————————— B6c 段：MessageInsertAnim 纯函数实跑 ————————————————————
// v4.0.40 新增。这个纯函数是「批量移除闪退」的唯一闸门，之前**零测试覆盖**，
// 且文件头自称的单测位置还是错的（说在 C 段，实际 C 段全是流式光带断言）。
// 「接会话/换会话」类路径全靠它挡：只认「旧序列是新的严格前缀 + 恰好多一条」。
print("\n—— B6c 段：纯追加判定（批量移除闪退闸门） ——")

check("B6c1 纯追加一条 → 播", MessageInsertAnim.isSingleAppend(prev: ["a", "b"], next: ["a", "b", "c"]))
check("B6c2 首条（prev 为空）→ 也播（否则用户第一句看不到动画，等于没修）",
      MessageInsertAnim.isSingleAppend(prev: [], next: ["a"]))
check("B6c3 变短（删消息 / 清空）→ 不播",
      !MessageInsertAnim.isSingleAppend(prev: ["a", "b"], next: ["a"]))
check("B6c4 等长整组替换（切会话）→ 不播",
      !MessageInsertAnim.isSingleAppend(prev: ["a", "b"], next: ["x", "y"]))
check("B6c5 多加两条（批量加载）→ 不播",
      !MessageInsertAnim.isSingleAppend(prev: ["a"], next: ["a", "b", "c"]))
check("B6c6 前缀相同但身份重排 → 不播",
      !MessageInsertAnim.isSingleAppend(prev: ["a", "b"], next: ["b", "a", "c"]))
check("B6c7 空→空与空→空不崩",
      !MessageInsertAnim.isSingleAppend(prev: [], next: []))

// B4b 的负向锚点：气泡文件里不许再留分角色 insertion 过渡
check("B4c 气泡文件不含 .transition(.asymmetric 分角色挂载（旧口径残留）",
      !bubble.contains(".transition(.asymmetric"))

// B7：本轮实踩的坑 —— 组件被 patch 塞进了 AIImageView 的修饰符链里（能编译、语义全错）。
let bandStructTopLevel = bubble.range(of: "\nstruct StreamSweepBand: View") != nil
let bandInsideAIImage = bubble.range(of: "                struct StreamSweepBand: View") != nil
check("B7 StreamSweepBand 是顶层声明（不在任何修饰符链里缩进）",
      bandStructTopLevel && !bandInsideAIImage)

let bandIdx = bubble.range(of: "struct StreamSweepBand: View")?.lowerBound
    ?? bubble.endIndex
let msgIdx = bubble.range(of: "struct MessageBubble: View")?.lowerBound ?? bubble.endIndex
check("B8 StreamSweepBand 定义排在 MessageBubble 之前",
      bandStructTopLevel && bandIdx < msgIdx)

check("B9 光带被 clip 在气泡内（GeometryReader + clipped，不溢出气泡）",
      bubble.contains("GeometryReader") && bubble.contains(".clipped()"))

check("B10 光带不吃点击（allowsHitTesting(false)，不能挡住气泡长按菜单/复制）",
      bubble.contains(".allowsHitTesting(false)"))

// ———————————————————— C 段：流式气泡动画接线 ————————————————————
print("\n—— C 段：流式气泡 ——")

check("C1 StreamingBubbleView 有首帧浮现开关 born",
      bubble.contains("@State private var born = false"))

check("C2 首帧浮现 = 淡入 + 上浮 8pt，且挂在 MessageBubble 之外（不动内部排版）",
      bubble.contains(".opacity(born ? 1 : 0)") && bubble.contains(".offset(y: born ? 0 : 8)"))

check("C3 首帧浮现自带 withAnimation 事务（插入发生在无事务的网络回调里，不带事务不播）",
      bubble.contains("withAnimation(Motion.streamBorn) { born = true }"))

check("C4 流式气泡以 streamingSweep: true 开启光带",
      bubble.contains("streamingSweep: true"))

let stIdx = bubble.range(of: "var streamingText: Bool")?.lowerBound ?? bubble.endIndex
let swIdx = bubble.range(of: "var streamingSweep: Bool")?.lowerBound ?? bubble.endIndex
check("C5 streamingSweep 参数声明在 streamingText 之后（仓库实参序=声明序铁律）",
      stIdx < swIdx)

check("C6 光带只在单气泡模式挂（多气泡段落会割成条纹）",
      bubble.contains("streamingSweep && !isMultiBubbleAI && !reduceMotion"))

check("C7 开「降低动态效果」时流式气泡不播浮现",
      bubble.contains("if reduceMotion { born = true }"))

// v4.0.39（审查建议⑥修正）：born 必须逐轮复位，否则回答中途重连会冒一次淡入。
check("C7b born 按 stream.startSeq 逐轮复位（重连时不冒第二次浮现）",
      bubble.contains(".onChange(of: stream.startSeq)"))

// v4.0.39（审查建议③修正）：光带位移取「实测高 + 带宽」与下限取大，
// 否则高于 320pt 的长回复（代码块/表格）光带会从气泡中部凭空出现。
check("C7c 光带位移按实测高度算（max(下限, geo 高 + 带宽)），不是硬编码 320",
      bubble.contains("max(travelFloor, geo.size.height + bandWidth)")
      && bubble.contains("private let travelFloor: CGFloat = 320"))

check("C8 v3.9.30 的 settle 平滑生长保留（光带不能把逐字生长顶掉）",
      bubble.contains(".animation(Motion.settle, value: stream.displayContent)"))

// ———————————————————— D 段：思考三点 + 调度纪律 ————————————————————
print("\n—— D 段：思考三点与调度纪律 ——")

check("D1 三点行已抽成 thinkingIndicatorRow（几何沿用原 inline 写法）",
      chat.contains("private var thinkingIndicatorRow: some View"))

check("D2 三点行有浮现开关 typingBorn 与 8pt 上浮",
      chat.contains("@State private var typingBorn = false")
      && chat.contains(".offset(y: typingBorn ? 0 : 8)"))

// v4.0.39 修正：复位必须挂 startSeq。挂在 thisSessionStreaming 的 busy 翻转上会在
// 排队自动续发（finish()→start() 同帧）时被吞掉边沿 → 那一轮三点凭空显示。
let startSeqOnChange = chat.split(separator: ".onChange(of: stream.startSeq)")
    .last.map { String($0.prefix(1800)) } ?? ""
check("D3 typingBorn 复位挂在 stream.startSeq 的 onChange 里（busy 翻转会吞同帧续发的边沿）",
      startSeqOnChange.contains("typingBorn = false"))
check("D3b typingBorn 复位没有挂在 thisSessionStreaming 边沿上（同型陷阱）",
      !chat.contains("if !was && now { typingBorn = false }"))

// ⚠️ v4.0.39：身份已改成走单一真源（见 D4b），这里只钉「三点行仍是贴底滚动的锚点」，
// 且 scrollTo 与 .id 用的是同一个 streamingAnchorID（裸字符串一律不认）。
check("D4 三点行仍带 streaming 身份的 id（贴底滚动锚点，行删了流式就不贴底）",
      chat.contains(".id(streamingAnchorID)") && chat.contains("private var thinkingIndicatorRow"))
// v4.0.39（审查阻断②修正）：三点行身份必须逐轮变，且**走单一真源**。
// 恒定身份 + 纯 remoteBusy 常驻屏 → onAppear 不再触发 → 复位后整轮三点静默不可见。
// ⚠️ 还有第三处耦合：scrollBottom 的 scrollTo 锚点。id 字符串曾散在三处（.id ×2 + scrollTo），
// 改一处忘另两处 → 贴底静默失效。断言钉死「三处全用 streamingAnchorID、零处写裸字符串」。
check("D4b 三点行身份走单一真源 streamingAnchorID（含 startSeq，每轮重建浮现必播）",
      chat.contains("private var streamingAnchorID: String { \"streaming-\\(stream.startSeq)\" }")
      && chat.range(of: ".id(streamingAnchorID)") != nil
      && chat.components(separatedBy: ".id(streamingAnchorID)").count - 1 == 2
      && chat.contains("proxy.scrollTo(streamingAnchorID, anchor: .bottom)"))

// v4.0.39（审查阻断①修正）：随机一言必须存 @State、在 onAppear 抽，
// 不能在 body 的计算属性里直调 pick()（body 每次重算都换一句 → 停在欢迎页也在抖）。
check("D9 随机一言存 @State，welcomeSubtitle 只读 state 不直调 pick()",
      chat.contains("@State private var welcomeQuote = WelcomeQuotes.pick()")
      && chat.contains("chat.messages.isEmpty ? welcomeQuote :")
      && !chat.contains("chat.messages.isEmpty ? WelcomeQuotes.pick() :"))

check("D5 ChatView 顶层有 reduceMotion 环境值（三点浮现要用）",
      chat.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))

// 调度纪律：本仓三点动画在 keyframe/TimelineView(.animation) 上翻车三次
// （v4.0.12 消失 / v4.0.14 强度不足 / v4.0.19 动一会儿就停，真根因＝官方定义的 pausable schedule）。
// 本轮所有循环动画必须走 repeatForever（transform 类）或 .periodic 墙钟，绝不能新增
// keyframeAnimation / TimelineView(.animation)。
check("D6 本轮未引入 keyframeAnimation（本仓三次翻车的调度）",
      !bubble.contains("keyframeAnimation") && !chat.contains("keyframeAnimation"))

check("D7 流式气泡首帧/三点浮现用的是 easeOut（streamBorn），不是循环调度",
      motion.contains("static var streamBorn: Animation { .easeOut(duration: 0.22)"))

check("D8 光带用 repeatForever(autoreverses: true)（往返循环，不引第二套墙钟）",
      bubble.contains("repeatForever(autoreverses: true)"))

// ———————————————————— E 段：反向自证 ————————————————————
// 把旧形态塞回源文本 → 对应断言必须变红。否则那些断言可能恒真（压根没匹配到目标串）。
// 这里不用 check(..., negative: true)：那个参数的语义是「断言必须为假」，而本段要的恰是相反
// ——「反例文本跑起来断言必须转红」为真时，本段算通过。所以自己计数。
print("\n—— E 段：反向自证 ——")
nonisolated(unsafe) var selfProved = 0
func selfProof(_ name: String, _ turnedRed: Bool) {
    print("\(turnedRed ? "✅" : "❌") \(name)")
    selfProved += 1
    if !turnedRed { failures += 1 }
}

// ⚠️ 这三条必须**重跑对应断言的判定表达式**（不是断言「替换后的文本不再含原串」）。
// v4.0.39 审查建议④：旧写法只断言 `!replaced.contains(原串)` —— 那个条件在任何输入下都成立
// （替换掉的东西当然找不到了），压根没验 B1/C6/B7 的判定式 → 恒真、零防恒真价值。
// 正确形态：把被验的判定表达式抽成闭包，此处对「被改坏的文本」跑同一份判定，要求它变假。
func b1Holds(_ src: String) -> Bool {
    src.contains("msg.isUser")
        && src.contains("insertion: msg.isUser")
}
func c6Holds(_ src: String) -> Bool {
    src.contains("streamingSweep && !isMultiBubbleAI && !reduceMotion")
}
func b7Holds(_ src: String) -> Bool {
    src.range(of: "\nstruct StreamSweepBand: View") != nil
        && src.range(of: "                struct StreamSweepBand: View") == nil
}

let bubbleWithOld = chat.replacingOccurrences(
    of: "insertion: msg.isUser",
    with: "insertion: .scale(scale: 0.94, anchor: msg.isUser ? .trailing : .leading).combined(with: .opacity)" )
selfProof("E1 把用户过渡改回旧 0.94 → B1 判定必须转红（证明 B1 不是恒真）",
          !b1Holds(bubbleWithOld))

let bubbleNoSweepGate = bubble.replacingOccurrences(
    of: "streamingSweep && !isMultiBubbleAI && !reduceMotion", with: "true")
selfProof("E2 去掉多气泡/reduceMotion 门 → C6 判定必须转红（证明 C6 不是恒真）",
          !c6Holds(bubbleNoSweepGate))

let bubbleBandIndented = bubble.replacingOccurrences(
    of: "struct StreamSweepBand: View", with: "                struct StreamSweepBand: View")
selfProof("E3 把光带组件缩进塞进修饰符链 → B7 判定必须转红（证明 B7 钉的就是本轮实踩的坑）",
          !b7Holds(bubbleBandIndented))

let chatNoReset = chat.replacingOccurrences(of: "typingBorn = false", with: "")
selfProof("E4 删掉 typingBorn 复位 → D3 断言必须转红（证明 D3 不是恒真）",
    !(chatNoReset.split(separator: ".onChange(of: stream.startSeq)").last.map { String($0.prefix(1800)) } ?? "").contains("typingBorn = false"))

// ———————————————————— 汇总 ————————————————————
print("\n———————————————")
print("正例 \(positives) · 反证 \(selfProved) · 共 \(positives + selfProved)")
if selfProved < 4 {
    print("❌ 反证不足 4 条：断言可能恒真，这张表不设防")
    failures += 1
}
print(failures == 0 ? "✅ 全部通过 \(positives + selfProved)" : "❌ 失败 \(failures)")
exit(failures == 0 ? 0 : 1)