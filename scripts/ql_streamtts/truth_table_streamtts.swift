import Foundation

// MARK: - v4.0.x 流式 TTS 分段朗读真值表
//
// 口径（需求原话：流式增量每凑满一个气泡段落就送 TTS 朗读，不等全文输出完）：
//   ① 切分口径与 MessageBubble.splitParagraphs 同源（空行分界、``` 围栏内空行不分段）——
//      本表用源护栏钉住两边不漂移（围栏行循环体逐字比对）；
//   ② feed() 只吐**新凑满**的段落（增量幂等：同全文重复喂不重复出声）；
//   ③ 未凑满的尾段不送（流式中最后一行还在长）；全文完成后最后一段必须送出；
//   ④ 纯代码围栏段（``` 块）整段跳过、不占朗读序号；未闭合围栏永不误送半截；
//   ⑤ 队列生命周期：未启用 isActive=false 喂了不吐；reset 后停喂；activate 后重新起算；
//   ⑥ 接线护栏：StreamClient 增量处调 feedStreamingTTS（不等 finish）；ChatView 落库边沿
//      整段朗读有 hasStreamingSpeech 守卫；SpeechManager.speakSegment 存在且不先 stop。
//
// 编译：与 qingliao/Core/StreamTTSSegmenter.swift 两文件编跑（check_swift.sh 26b 步）。
// 多文件模式顶层可执行表达式不允许 → 全部断言收进 @main（与 ql_intents 等同口径）。

@main
struct StreamTTSTruthTable {
    // Swift 6 严格并发：静态可变全局共享态不让编 → 收进 @MainActor（单线程表，语义不变）。
    @MainActor static var passCount = 0
    @MainActor static var failCount = 0

    @MainActor static func check(_ name: String, _ cond: Bool) {
        if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
    }
    static func src(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
    static func stripCommentLines(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @MainActor static func main() {
        // ───────── ① 切分口径护栏：与 MessageBubble.splitParagraphs 的围栏循环逐字同构 ─────────
        let bubbleSrc = src("qingliao/Features/Chat/ChatMessageBubble.swift")
        let segSrc = src("qingliao/Core/StreamTTSSegmenter.swift")
        let loopLine = "if trimmed.isEmpty && !inFence {"
        check("护栏·气泡切分围栏循环仍在", bubbleSrc.contains(loopLine))
        check("护栏·分段器围栏循环与气泡同构", segSrc.contains(loopLine))
        check("护栏·分段器围栏开关与气泡同构", bubbleSrc.contains("if trimmed.hasPrefix(\"```\") { inFence.toggle() }")
            && segSrc.contains("if trimmed.hasPrefix(\"```\") { inFence.toggle() }"))

        // ───────── ② feed() 增量语义 ─────────
        var seg = StreamTTSSegmenter()
        seg.activate()

        // 「第一段\n\n第二段」逐字喂入。口径与 splitParagraphs 一致：单个 \n 已是终止符
        //（后随空行 "" 触发 flush）→ 段落凑满；没遇到任何换行的尾行扣住不送。
        var out = seg.feed(full: "第一段")
        check("② 未满一段不吐", out.isEmpty)
        out = seg.feed(full: "第一段\n")
        check("② 换行终止 → 第一段立即凑满送读", out == ["第一段"])
        check("② fedCount 推进", seg.fedCount == 1)
        out = seg.feed(full: "第一段\n\n")
        check("② 空行重复喂不重复出声（增量幂等）", out.isEmpty)
        out = seg.feed(full: "第一段\n\n第二段")
        check("② 尾段未完不吐", out.isEmpty)
        out = seg.feed(full: "第一段\n\n第二段\n")
        check("② 第二段凑满送读", out == ["第二段"])

        // ───────── ③ 全文完成：最后一段必须送出 ─────────
        var seg2 = StreamTTSSegmenter()
        seg2.activate()
        let full = "开头段\n\n结尾段"
        let out2a = seg2.feed(full: String(full.prefix(full.count - 1)))   // 流式中：最后一字未到
        check("③ 流式中只送已凑满段", out2a == ["开头段"])
        let out2 = seg2.feed(full: full, isFinal: true)   // 收尾定格 → 尾段送出
        check("③ 全文完 → 末段送出", out2 == ["结尾段"])

        // ───────── ④ 代码围栏：纯代码段跳过；未闭合围栏永不送半截 ─────────
        var seg3 = StreamTTSSegmenter()
        seg3.activate()
        let out3 = seg3.feed(full: "普通段\n\n```swift\nlet a = 1\n```\n\n")
        check("④ 纯代码段整段跳过", out3 == ["普通段"])
        check("④ 代码段不占朗读序号", seg3.fedCount == 2)   // 普通(1) + 代码(2，跳过不计朗读)
        var seg4 = StreamTTSSegmenter()
        seg4.activate()
        var out4 = seg4.feed(full: "前文\n\n```python\nprint('hi')\nprint('still typing')")
        check("④ 未闭合围栏不送半截", out4 == ["前文"])
        out4 = seg4.feed(full: "前文\n\n```python\nprint('hi')\nprint('done')\n```\n\n正文段\n\n")
        check("④ 围栏闭合后跳过代码段、后续段正常", out4 == ["正文段"])
        // 围栏内的空行不分段（与 UI 同口径：代码块整体不拆）
        var seg5 = StreamTTSSegmenter()
        seg5.activate()
        let out5 = seg5.feed(full: "```go\na := 1\n\nb := 2\n```\n\n")
        check("④ 围栏内空行不分段", out5.isEmpty && seg5.fedCount == 1)

        // ───────── ⑤ 队列生命周期 ─────────
        var seg6 = StreamTTSSegmenter()
        check("⑤ 未启用时喂了不吐", seg6.feed(full: "一段\n\n").isEmpty)
        seg6.reset()
        check("⑤ reset 后仍不吐", seg6.feed(full: "一段\n\n").isEmpty)
        seg6.activate()
        check("⑤ activate 后重新起算", seg6.feed(full: "一段\n\n") == ["一段"])
        seg6.reset()
        check("⑤ reset 后 isActive=false", !seg6.isActive)
        check("⑤ 新建队列 isActive=false", !StreamTTSSegmenter().isActive)

        // ───────── ⑥ 接线护栏：源码钉住调用链 ─────────
        let streamSrc = stripCommentLines(src("qingliao/Core/StreamClient.swift"))
        let chatSrc = src("qingliao/Features/Chat/ChatView.swift")
        let speechSrc = src("qingliao/Core/SpeechManager.swift")
        check("⑥ StreamClient 增量分支调 feedStreamingTTS（流式中即读，不等 finish）",
              streamSrc.contains("feedStreamingTTS()   // v4.0.x"))
        check("⑥ 收尾定格送末段（finish 里 isFinal 喂入）",
              streamSrc.contains("feed(full: content, isFinal: true)"))
        check("⑥ 新流入口复位队列（ttsReset 存在且有调用）",
              streamSrc.contains("func ttsReset()") && streamSrc.contains("ttsReset()"))
        check("⑥ ChatView 落库边沿整段朗读有分段守卫",
              chatSrc.contains("if stream.hasStreamingSpeech { return }"))
        check("⑥ SpeechManager 提供分段入口 speakSegment",
              speechSrc.contains("func speakSegment(_ raw: String, id: String)"))
        check("⑥ speakSegment 是流式签名路径（先记 streamingSpeechID，不与整段 speak 混用）",
              stripCommentLines(speechSrc).range(of: #"func speakSegment[\s\S]*?streamingSpeechID = id"#, options: .regularExpression) != nil)

        print("流式分段朗读真值表：\(passCount) 项全绿" + (failCount > 0 ? "，\(failCount) 项失败" : ""))
        if failCount > 0 { exit(1) }
    }
}
