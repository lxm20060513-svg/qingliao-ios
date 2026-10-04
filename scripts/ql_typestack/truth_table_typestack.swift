// MARK: - 启动期类型栈深度真值表（v4.0.48）
//
// 事故（2026-10-04 真机实报）：v4.0.47 侧载装完**一点开就闪退**，用户给到设备 .ips 才定死：
//   · app_version = 4.0.47（注意：App 内崩溃记录写的是 4.0.46 —— 记录是下次启动补传，
//     补传时盖的是当时进程版本号，**不能当版本真值**；真值只认 .ips 的 app_version）
//   · exception = EXC_BAD_ACCESS / SIGSEGV，termination = "stack guard region" → **主线程栈溢出**
//   · 栈 = _main → App.main → 首次提交(CA commit/_firstCommitBlock) → UIHostingView.layoutSubviews
//     → ViewGraph.render → ChatView.body → chatTranscriptArea → **messageList**
//     → ___swift_instantiateConcreteTypeFromMangledNameV2 → swift_getTypeByMangledNameInContext2
//     → swift::Demangle::TypeDecoder::decodeMangledType ↔ decodeGenericArgs 递归 ~112 帧
//     → 1MB 主线程栈吃干、撞栈保护页
//
// 定量根因（用 dSYM 符号表量出来的，不是猜）：messageList 里 LazyVStack 的元组类型静态嵌套 **21 层**，
//   最深的两条元素链 = ① thinkingIndicatorRow（TypingIndicator + 10 条修饰器 = 12 层）
//   ② toolStepCards（两层 TimelineView 嵌套 = 9 层）。demangler 每层约 5.3 帧 → 21 × 5.3 ≈ 112 帧，
//   与 .ips 实测帧数吻合。4.0.46 与 4.0.47 的深度**逐字节相同**（同一类型名长度都是 9290）——
//   说明这是长期贴边的隐患，任何一点波动都可能让它从「偶尔」变「必崩」。
//
// 修法 = **类型擦除**（AnyView），只让类型名变浅，视图树/修饰器/动画/身份一律不动：
//   · 21 层 → ~11 层（demangler 递归 112 帧 → ~55 帧，省出约 400KB 栈）
//   · ⚠️ `.transition` / `.id` 必须留在 AnyView **外面**：前者管三点行 ↔ 流式气泡互换的退场，
//     后者是流式区身份真源（搬进去 = 静默改语义，本表专门钉这一条）。
//
// 为什么必须有这张表：这类事故**本地预检查不出**（要设备 + 真机启动才暴露），
//   而「顺手把 AnyView 去掉更简洁」是极自然的重构动作，一旦回退就是必崩包发出去。
//   本表把「深链必须擦除 + transition/id 必须在擦除之外」钉成硬断言。
//
// ⚠️ 文本级断言（视图代码无可跑逻辑）：只钉判别性子串；注释按**整行**剥离
//   （行内剥会把 `//` 后面的说明截断造成假红）。

import Foundation

nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0
func ok(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("  ✅ \(name)") } else { fail += 1; print("  ❌ \(name)") }
}

let repo: String = {
    if let e = ProcessInfo.processInfo.environment["QL_REPO"], !e.isEmpty { return e }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
}()
let path = repo + "/qingliao/Features/Chat/ChatView.swift"
let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
if raw.isEmpty { print("❌ 读不到 \(path)"); exit(1) }

// 整行剥注释（保留其它行，子串定位不受影响）
let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    .joined(separator: "\n")

func slice(_ s: String, from a: String, to b: String) -> String {
    guard let ra = s.range(of: a) else { return "" }
    guard let rb = s.range(of: b, range: ra.upperBound..<s.endIndex) else { return "" }
    return String(s[ra.lowerBound..<rb.lowerBound])
}
func idx(_ s: String, _ sub: String) -> Int? {
    guard let r = s.range(of: sub) else { return nil }
    return s.distance(from: s.startIndex, to: r.lowerBound)
}

// ── ① thinkingIndicatorRow：深链必须被 AnyView 擦除，transition/id 必须留在外面
let tir = slice(code, from: "private var thinkingIndicatorRow: some View {",
                to: "private var streamingAnchorID")
ok(!tir.isEmpty, "thinkingIndicatorRow 段落定位成功（锚点还在）")
ok(tir.contains("AnyView("), "① 三点行深链已类型擦除（AnyView 包裹，21 层 → ~11 层）")
ok(tir.contains("TypingIndicator()"), "① AnyView 内仍是原 TypingIndicator（没换实现）")
ok(tir.contains(".transition(.opacity)"), "① 退场淡出 .transition(.opacity) 仍在（没删动画）")
ok(tir.contains(".id(streamingAnchorID)"), "① 身份真源 .id(streamingAnchorID) 仍在（没删身份）")
if let a = idx(tir, "AnyView("), let t = idx(tir, ".transition(.opacity)") {
    ok(a < t, "① .transition 在 AnyView **之后**（擦除之外，退场语义不变）")
} else {
    ok(false, "① 找不到 AnyView( 或 .transition(.opacity)（无法判定内外）")
}
// v4.0.48 复审补强：只比「首次出现位置」会漏掉「AnyView 内部又加了一条 transition/id」这种变异
// （真机变异实测：往 AnyView 里塞 EmptyView().transition(.opacity) 曾假绿）→ 按**区域**判定：
// AnyView( 到它那一行 `        )` 闭合之间，不得出现 .transition( / .id(。
let innerRegion: String = {
    guard let a = tir.range(of: "AnyView(") else { return "" }
    guard let r = tir.range(of: "\n        )", range: a.upperBound..<tir.endIndex) else { return "" }
    return String(tir[a.upperBound..<r.lowerBound])
}()
ok(!innerRegion.isEmpty, "① 能切出 AnyView 内部区域（闭合行 `        )` 还在）")
ok(!innerRegion.contains(".transition("), "① AnyView **内部**无 .transition（退场必须在擦除之外）")
ok(!innerRegion.contains(".id("), "① AnyView **内部**无 .id（身份必须在擦除之外）")
if let t = idx(tir, ".transition(.opacity)"), let i = idx(tir, ".id(streamingAnchorID)") {
    ok(t < i, "① .id 在 .transition 之后（原顺序未被打乱）")
} else {
    ok(false, "① 找不到 .transition / .id 顺序（无法判定）")
}
// 擦除必须是「整串链一起擦」：AnyView( 与它的闭合 ) 之间要含 ≥8 条修饰器，
// 防止有人只擦一两层（把链拆两半 = 深度只降一点点，仍然贴边）
if let a = idx(tir, "AnyView(") {
    let after = String(tir.dropFirst(a))
    let inner = slice(after, from: "TypingIndicator()", to: ".transition(.opacity)")
    let dots = inner.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(".") }.count
    ok(dots >= 8, "① 整串链一起擦（AnyView 内修饰器条数 = \(dots)，要求 ≥8）")
} else {
    ok(false, "① 找不到 AnyView(（无法统计链内修饰器）")
}
// 负断言：裸链形态（TypingIndicator 直接跟 .padding，未被 AnyView 包）必须不存在
ok(!code.contains("TypingIndicator()\n            .padding(.horizontal, Spacing.section)"),
   "① 裸链形态不复存在（回退成内联链 = 闪退复发）")

// ── ② toolStepCards：第二条深链同样擦除，transition 留在外面
let tsc = slice(code, from: "private var toolStepCards: some View {",
                to: "var body: some View {")
ok(!tsc.isEmpty, "toolStepCards 段落定位成功（锚点还在）")
ok(tsc.contains("AnyView(VStack("), "② 工具卡深链已类型擦除（AnyView(VStack(...))，~9 层 → 1 层）")
if let a = idx(tsc, "AnyView(VStack("), let t = idx(tsc, ".transition(.opacity)") {
    ok(a < t, "② .transition(.opacity) 在 AnyView **之后**（工具卡淡入淡出语义不变）")
} else {
    ok(false, "② 找不到 AnyView(VStack( 或 .transition(.opacity)（无法判定）")
}

// ── ③ messageList：外层三条 padding 合并成一条（少两层）
let ml = slice(code, from: "private var messageList: some View {",
               to: "private func scrollBottom(")
ok(!ml.isEmpty, "messageList 段落定位成功（锚点还在）")
ok(ml.contains(".padding(EdgeInsets(top: Spacing.md, leading: 6, bottom: Spacing.md, trailing: 6))"),
   "③ 外层 padding 已合并为一条 EdgeInsets（视觉等价、类型少两层）")
ok(!ml.contains(".padding(.horizontal, 6)\n                    .padding(.top, Spacing.md)"),
   "③ 负断言：三条分散 padding 已不存在（回退 = 深度回升）")

print("  —— 类型栈深度真值表：\(pass) 通过 / \(fail) 失败")
if fail > 0 { exit(1) }
