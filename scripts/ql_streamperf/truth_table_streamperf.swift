import Foundation

// ql_streamperf —— v4.0.164「长回答流式/打字卡顿」回归护栏
//
// 背景（真机取证，不是推测）：
//   4.0.163 的 150 条看门狗上报里，用同一次构建的 dSYM 符号化 App 帧，抓到两处：
//     · StreamClient.startSmooth 的异步闭包内 `String.distance`（1.08s 连续繁忙段）
//     · PetAvatar.body / PetPainter.drawDot（1.3~1.5s 连续繁忙段）
//   机制：流式每 48ms 一个 tick，每个 tick 都对**全文**做 O(n) 的 count/prefix/contains/
//   分段；回答 5 万字时单 tick 就是几十毫秒 → 主线程连续繁忙，键盘输入事件排队 =
//   用户报的「文字越多、打字越迟钝」。修法 = 把每 tick 的代价从 O(全文) 压到 O(增量/固定窗口)。
//
// 本表只做**源码形状**断言（离线可跑、不依赖 iOS）。语义单测仍由 SmoothRelease 真值表覆盖。
// ⚠️ 每条断言都要自问一句「把违规写法加回去，这条会红吗」——纯存在性断言最容易写成恒真。

var pass = 0
var fail = 0
@MainActor func check(_ name: String, _ ok: Bool) {
    if ok { pass += 1; print("✅ \(name)") } else { fail += 1; print("❌ \(name)") }
}

// 仓库根：优先 QL_REPO（check_swift.sh 会钉住），否则 cwd —— 与 truth_table_draft / clipboard 同一口径。
// ⚠️ 别写死本机绝对路径：换机器/CI 会把「环境差异」伪装成四条①全红。
let repoRoot = ProcessInfo.processInfo.environment["QL_REPO"] ?? FileManager.default.currentDirectoryPath
func read(_ p: String) -> String {
    (try? String(contentsOfFile: repoRoot + "/qingliao/" + p, encoding: .utf8)) ?? ""
}
/// 去掉整行注释（本仓惯例：注释里会提到旧写法，不剥会假红）
func code(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("//") ? "" : String(line)
    }.joined(separator: "\n")
}
func slice(_ src: String, from: String, to: String) -> String {
    guard let a = src.range(of: from), let b = src.range(of: to, range: a.upperBound..<src.endIndex) else { return "" }
    return String(src[a.lowerBound..<b.lowerBound])
}

let streamSrc = code(read("Core/StreamClient.swift"))
let bubbleSrc = code(read("Features/Chat/ChatMessageBubble.swift"))
let chatSrc = code(read("Features/Chat/ChatView.swift"))
let petSrc = code(read("Features/Chat/PetAvatar.swift"))

// ① 源可读（路径写错要报红，不能静默全绿）
check("① 源可读（StreamClient）", streamSrc.count > 20000)
check("① 源可读（ChatMessageBubble）", bubbleSrc.count > 20000)
check("① 源可读（ChatView）", chatSrc.count > 100000)
check("① 源可读（PetAvatar）", petSrc.count > 10000)

// ② displayContent 必须命中缓存：缓存命中分支在、且**在读取全文 strip 之前**
check("② displayContent 有命中缓存分支", streamSrc.contains("if displayCacheValid { return displayCached }"))
let rawRead = streamSrc.range(of: "let raw = smoothTask != nil ? smoothedContent : content")
let cacheHit = streamSrc.range(of: "if displayCacheValid { return displayCached }")
check("② 先读可观察属性再判缓存（否则流式文字会停在最后一帧）",
      rawRead != nil && cacheHit != nil && rawRead!.lowerBound < cacheHit!.lowerBound)
check("② 无标记时不再扫全文", streamSrc.contains("contentMayContainMarker ? ChatStore.strippingBrowserLiveMarker(raw) : raw"))

// ②b 缓存失效的唯一机制是两处 didSet —— 删掉它 = 流式文字永久停在第一帧（最阴的静默 bug）。
// 实测：删掉这两行后，本表其余断言全绿（所以必须单独钉）。
check("②b content 写入会标脏缓存", streamSrc.contains("var content = \"\" { didSet { displayCacheValid = false } }"))
check("②b smoothedContent 写入会标脏缓存", streamSrc.contains("var smoothedContent = \"\" { didSet { displayCacheValid = false } }"))

// ③ 平滑层：未上屏尾部缓冲 + 字节口径步长（旧写法每 tick 数全文）
let smooth = slice(streamSrc, from: "private func startSmooth()", to: "private func stopSmooth()")
check("③ 平滑层切到（切片空了下面几条就是空真）", smooth.count > 500)
check("③ 不再每 tick 数已显示长度", !smooth.contains("smoothedContent.count"))
check("③ 不再每 tick 数全文长度", !smooth.contains("content.count"))
check("③ 用未上屏尾部缓冲推进", smooth.contains("self.pendingRelease.prefix(step)"))
check("③ 步长走 SmoothRelease.step(backlogBytes:)（单一真源）",
      smooth.contains("SmoothRelease.step(backlogBytes: backlogBytes)"))
// ③b 字素/码点混算回归：整数游标（把 String.count 相加）会在 emoji/组合字素跨 delta 时算大 →
// 取尾部时把已显示字符重放一遍，正文出现重复字（实测 👍 + 肤色修饰符 稳定复现）。
check("③b 不再用字符计数游标", !streamSrc.contains("smoothedCount") && !streamSrc.contains("contentCount"))

// ④ 流式中途整体替换（换任务/续流/接管）必须把已上屏内容一起清掉，否则新旧正文混拼
// ⚠️ 切片终点不能用 `///` 注释行：code() 会把整行注释清掉，切片直接空 → 三条④假红。
let replaceFn = slice(streamSrc, from: "private func replaceContent(", to: "var displayContent: String {")
check("④ 整体替换切到", replaceFn.count > 100)
check("④ 替换时清掉已上屏内容（防新旧混拼）", replaceFn.contains("if smoothTask != nil { smoothedContent = \"\" }"))
check("④ 替换时重置未上屏缓冲", replaceFn.contains("pendingRelease = s"))

// ⑤ hasContent：只在空↔非空翻转时变（ChatView body 不再挂到每段增量上）
check("⑤ 增量路径维护 hasContent", streamSrc.contains("if !hasContent { hasContent = true }"))
check("⑤ ChatView 气泡条件改用 hasContent", chatSrc.contains("if !thisSessionStreaming || !stream.hasContent {"))
check("⑤ 反向：不许退回 stream.content.isEmpty 判定", !chatSrc.contains("!thisSessionStreaming || stream.content.isEmpty"))

// ⑥ 气泡：流式期只处理尾部窗口（lineCount / blocks key / 分段不再是 O(全文)）
let shownBody = slice(bubbleSrc, from: "private var shownContent: String {", to: "private var contentBlocks")
check("⑥ shownContent 切到", shownBody.count > 300)
check("⑥ 流式分支先截尾窗（而不是先读全文再判断）",
      shownBody.contains("if streamingText {") &&
      shownBody.range(of: "if streamingText {")!.lowerBound < shownBody.range(of: "displayContent.suffix(Self.streamingTailChars)")!.lowerBound)
check("⑥ lineCount 提前退出", bubbleSrc.contains("if n > maxStreamingLineBubbles { break }"))
check("⑥ 超长流式一律单块（窗口被截过就不走行模式，防开头几行消失）",
      bubbleSrc.contains("let windowed = streamingText && shownContent.utf8.count < displayContent.utf8.count"))
check("⑥ 窗口起点落在围栏内时跳过原始 JSON", shownBody.contains("fences % 2 == 1"))

// ⑦ 宠物：光晕慢闪降到 15fps（真机栈里 PetPainter.drawDot 是 1.3s 段的一部分）
check("⑦ 光晕重绘降到 15fps", petSrc.contains(".milliseconds(66)"))

// ⑧ 反向自证：把旧写法拼回字符串，**同一个判据**必须判红（防空真断言）
func looksLegacySmooth(_ s: String) -> Bool {
    s.contains("self.smoothedContent.count") || s.contains("String(self.content.prefix(target))")
}
let legacyStub = """
while let self, !Task.isCancelled {
    if self.smoothedContent.count < self.content.count {
        let target = SmoothRelease.nextLength(smoothedCount: self.smoothedContent.count, contentCount: self.content.count)
        self.smoothedContent = String(self.content.prefix(target))
    }
}
"""
check("⑧ 反向自证：判据对旧写法必红", looksLegacySmooth(legacyStub))
check("⑧ 反向自证：判据对现源码必绿（与 ③ 共用同一判据）", !looksLegacySmooth(smooth))

print("ql_streamperf：通过 \(pass) / 失败 \(fail)")
if fail > 0 { exit(1) }
