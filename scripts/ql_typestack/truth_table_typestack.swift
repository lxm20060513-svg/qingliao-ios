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
//
// ── v4.0.49 复盘：4.0.48 为什么还是崩（同一台设备、同一份 .ips 形状） ──────────
// 4.0.48 的擦除只做在**内层元组元素**（thinkingIndicatorRow/toolStepCards），而崩点那个
//   类型名是 messageList 自己的返回类型：`_ConditionalContent<欢迎页分支, ScrollViewReader<
//   ScrollView<LazyVStack<…>>>>` 之外还挂着 **22 条 ZStack 级修饰器** + ScrollView 上 **11 条**，
//   全部**内联**在名字里 → 实测该类型名 1951 字符（dSYM 符号表量出；同段还并存 9290 字符的
//   lazy witness 名）。demangler 递归 102 帧 ↔ 每 19 字符 ≈ 1 帧、每帧 ~9.3KB → 1MB 栈吃干。
// 结论修正：危险量是**名字的字符数**，不是元组嵌套层数；AnyView 只擦内联子链，擦不掉
//   「父视图自己那条修饰器链」。iOS 27.2 beta 运行时多几帧泛型校验 → 从「偶尔」变「必崩」。
// 修法（v4.0.49）= 把长链**折成具名 ViewModifier 分组**（父名里只剩组名，链在各组自己的
//   调用里解析），另把 LazyVStack 内容里的内联按钮链抽成不透明属性。护栏在 ③′。

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

// ── ③′ v4.0.49：启动链的长修饰器链必须折成具名 ViewModifier 分组 ─────────
// 量纲：类型名**字符数**。实测 19 字符 ≈ 1 帧 demangler 递归 ≈ 9.3KB 栈（4.0.48：1951 字符 ↔ 102 帧）。
// 折前 messageList 返回类型名里内联了 ScrollView 链 11 条 + ZStack 链 22 条 + 欢迎页分支 3 条
//   + 内联按钮链 ≈ 1250+ 字符；折后这三处只剩 `.modifier(组名)`，实测目标 ≤8 层/≤900 字符。
let foldGroups = ["MessageListScroll1(host: self, proxy: proxy)",
                  "MessageListScroll2(host: self, proxy: proxy)",
                  "MessageListScroll3(host: self, proxy: proxy)",
                  "MessageListChrome1(host: self)", "MessageListChrome2(host: self)",
                  "MessageListChrome3(host: self)", "MessageListChrome4(host: self)",
                  "MessageListChrome5(host: self)", "MessageListChrome6(host: self)",
                  "WelcomeBranchChrome(host: self)"]
for g in foldGroups {
    ok(ml.contains(".modifier(\(g))"), "③′ 折叠组已就位：.modifier(\(g))")
}
// 链不许再内联回 messageList（回退 = 名字长度回升 ≈ 1250 字符 ≈ 65 帧 ≈ 600KB 栈 = 回到必崩区）
for m in [".onScrollGeometryChange(", ".scrollDismissesKeyboard(", ".fileExporter(",
          ".fullScreenCover(", ".quickLookPreview(", ".alert(", ".sheet(",
          ".onTapGesture {", ".scrollContentBackground("] {
    ok(!ml.contains(m), "③′ 负断言：\(m) 未内联回 messageList（回退 = 启动链名字变长）")
}
// 内联按钮链已抽成属性（原来 ~350 字符直接压在 LazyVStack 内容类型里）
ok(ml.contains("loadEarlierButton"), "③′ 「加载更早」按钮已抽成不透明属性（内容类型不再内联按钮链）")
ok(!ml.contains("Text(\"加载更早 "), "③′ 负断言：按钮链文案未内联回 messageList")
// 组必须**短**：单组 ≤5 条链式修饰器（组太胖 = 折叠没落地，名字还是会涨）
// 注：`code` 已整行剥注释，锚点必须是**代码行**（首个折叠方法）
let foldExt: String = {
    guard let a = idx(code, "func applyMessageListScroll1<C: View>") else { return "" }
    return String(code.dropFirst(a))
}()
ok(!foldExt.isEmpty, "③′ 折叠区（extension）定位成功（锚点 = 首个折叠方法还在）")
if !foldExt.isEmpty {
    for n in ["MessageListScroll1", "MessageListScroll2", "MessageListScroll3",
              "MessageListChrome1", "MessageListChrome2", "MessageListChrome3",
              "MessageListChrome4", "MessageListChrome5", "MessageListChrome6",
              "WelcomeBranchChrome"] {
        guard let a = idx(foldExt, "func apply\(n)<C: View>") else {
            ok(false, "③′ 找不到折叠方法 apply\(n)"); continue
        }
        let body = String(foldExt.dropFirst(a))
        let seg: String = {
            if let e = idx(body, "\n    }") { return String(body.prefix(e)) }
            return body
        }()
        let dots = seg.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(".") }.count
        ok(dots >= 1 && dots <= 5, "③′ 组 \(n) 只承载 \(dots) 条修饰器（要求 1…5）")
    }
}
print("  —— 类型栈深度真值表：\(pass) 通过 / \(fail) 失败")
if fail > 0 { exit(1) }
