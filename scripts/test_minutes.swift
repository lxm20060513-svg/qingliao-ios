// 会话纪要（现场长录音 → 设备端转写 → AI 整理 → 存备忘 + 会话卡）真值表 —— Linux 本地预检用，纯 Foundation，无 UI 依赖
//
// 编译运行（在**仓库根目录**，工具链路径见 check_swift.sh 第 30 段；表内读源码用的是相对路径）：
//   ./check_swift.sh
// 等价于：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_minutes scripts/test_minutes.swift \
//       qingliao/Core/MinutesKit.swift qingliao/Core/AgentCardParser.swift
//
// 口径（本文件钉死的东西）：
//   · **不丢字**：切片是按位置切分，chunks.joined() == 原文（不 trim、不合并空白）；分段状态机同理。
//   · **超长必须走 map-reduce**：> 4000 字 → 每片一次 map + 最后一次 reduce（askCount = 片数 + 1）。
//   · **不要输出思考过程**：single / map / reduce 三条提示词都必须显式带这句（模型爱先把过程写出来）。
//   · **卡片必须被真的 AgentCardParser 解出来**（不是手写字符串自证）：type/title/fields/footer 逐项断言。
//   · **空转写不产卡**：抽不出内容 → 卡片 ""，录音页走「重试 / 存原文备忘」。
//   · 录音页护栏（读源码）：不许 Text(整篇 liveText)、必须按段渲染、失败态必须有重试入口。

import Foundation

// MARK: - 断言工具

nonisolated(unsafe) var failures = 0

func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

func checkEq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    let ok = got == want
    print("\(ok ? "✅" : "❌") \(name)\(ok ? "" : "（得 \(got)，期望 \(want)）")")
    if !ok { failures += 1 }
}

/// 读源文件做护栏（**必须**从仓库根跑，check_swift.sh 已钉死工作目录）
func readSource(_ path: String) -> String {
    guard let d = FileManager.default.contents(atPath: path),
          let s = String(data: d, encoding: .utf8) else { return "" }
    return s
}

/// 构造一段像真转写的文本：每句 10 字 + 句号
let transcriptSentence = "这一步我们先定预算和排期。"   // 13 字（含句号）
func makeTranscript(sentences: Int) -> String {
    String(repeating: transcriptSentence, count: sentences)
}

/// 只留代码行（去掉整行注释）：护栏查「有没有真的这么渲染」，不该被文档注释里的反例误伤
func codeOnly(_ source: String) -> String {
    source.components(separatedBy: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

@main
enum MinutesTruthTable {

    static func main() {
        sectionOne_切片不丢字()
        sectionTwo_分段状态机()
        sectionThree_提示词()
        sectionFour_调用计划超长走mapReduce()
        sectionFive_摘要抽取()
        sectionSix_主题与待办数()
        sectionSeven_文案与判定()
        sectionEight_卡片可被真解析器解出()
        sectionNine_录音页与接线护栏()
        print("\n=== 结果 ===")
        if failures == 0 {
            print("✅ 会话纪要真值表全绿")
        } else {
            print("❌ 会话纪要真值表 \(failures) 条不过")
        }
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 1. 切片：边界与不丢字

    static func sectionOne_切片不丢字() {
        print("\n=== 1. 切片（3~5k 字/片，优先句末断开，绝不丢字）===")
        checkEq("空转写 → 无片", MinutesKit.chunks(of: "").count, 0)
        checkEq("一小段 → 1 片", MinutesKit.chunks(of: "就只有一句话。").count, 1)

        let limit = MinutesKit.chunkLimit
        check("每片上限是 3~5k 字（\(limit)）", limit >= 3_000 && limit <= 5_000)

        // 边界：正好一片不切，多 1 字切 2 片（反例：不能因为差一个字就切出 3 片）
        let exact = makeTranscript(sentences: limit / transcriptSentence.count)
        check("刚好一片的文本不切（\(exact.count) 字）", MinutesKit.chunks(of: exact).count == 1)
        let pinned = exact + String(repeating: "续", count: limit - exact.count)
        checkEq("正好 \(limit) 字 → 1 片", MinutesKit.chunks(of: pinned).count, 1)
        let over = pinned + "续"
        let overChunks = MinutesKit.chunks(of: over)
        checkEq("超出 1 字 → 2 片", overChunks.count, 2)
        checkEq("超一片时仍不丢字", overChunks.joined(), over)
        check("每片都不超上限", overChunks.allSatisfy { $0.count <= limit })

        // 长文本：不丢字 + 每片 ≤ limit + 无空片
        let long = makeTranscript(sentences: 900)      // 9000 字
        let pieces = MinutesKit.chunks(of: long)
        check("9000 字 → 多片（\(pieces.count) 片）", pieces.count >= 3)
        checkEq("长文本切片不丢字", pieces.joined(), long)
        check("长文本每片 ≤ 上限", pieces.allSatisfy { $0.count <= limit })
        check("没有空片", pieces.allSatisfy { !$0.isEmpty })
        check("优先在句末断开（第 1 片以「。」结尾）", pieces[0].hasSuffix("。"))
        check("优先在句末断开（第 2 片也以「。」结尾）", pieces[1].hasSuffix("。"))

        // 没有任何标点：硬切，同样不丢字、片数 = 向上取整
        let solid = String(repeating: "字", count: 10_000)
        let hard = MinutesKit.chunks(of: solid)
        checkEq("无标点 → 按上限硬切（片数 = ceil(10000/\(limit))）", hard.count, (10_000 + limit - 1) / limit)
        checkEq("硬切也不丢字", hard.joined(), solid)
        check("硬切每片不超上限", hard.allSatisfy { $0.count <= limit })

        // 标点落在窗口外（靠前）：仍不丢字（宁可断在标点之后稍早的位置）
        let early = String(repeating: "开头很短。", count: 20) + String(repeating: "持续说很久没有标点的内容", count: 900)
        let earlyChunks = MinutesKit.chunks(of: early)
        checkEq("标点靠前时也不丢字", earlyChunks.joined(), early)
        check("标点靠前时每片不超上限", earlyChunks.allSatisfy { $0.count <= limit })

        // 反例：limit 太小没有意义 → 原样一片（不然会切出几千片）
        checkEq("limit 过小 → 原样一片", MinutesKit.chunks(of: "一二三四五六七八九十", limit: 4).count, 1)

        checkEq("4000 字不走 map-reduce", MinutesKit.needsMapReduce(String(repeating: "字", count: limit)), false)
        checkEq("4001 字走 map-reduce", MinutesKit.needsMapReduce(String(repeating: "字", count: limit + 1)), true)
    }

    // MARK: - 2. 分段状态机（录音中按段渲染的数据源）

    static func sectionTwo_分段状态机() {
        print("\n=== 2. 分段状态机（已定稿段只增不改 / 不丢字 / 取消不抹）===")
        var s = MinutesKit.MinutesSegments.empty
        checkEq("空状态无内容", s.text, "")
        checkEq("末尾标点也先不定稿（后面还没字）",
                MinutesKit.advance(MinutesKit.MinutesSegments.empty, with: "你好。").closed.count, 0)

        s = MinutesKit.advance(s, with: "你好。世界")
        checkEq("有后文时上一句定稿", s.closed.count, 1)
        checkEq("定稿内容 = 第一句", s.closed.first ?? "", "你好。")
        checkEq("未定稿部分在尾巴上", s.open, "世界")
        checkEq("分段拼接 == 当前全文（不丢字）", s.text, "你好。世界")

        s = MinutesKit.advance(s, with: "你好。世界。接下来")
        checkEq("第二句也定稿", s.closed.count, 2)
        checkEq("第二段内容", s.closed.last ?? "", "世界。")
        checkEq("尾巴 = 未说完那句", s.open, "接下来")
        checkEq("分段拼接 == 当前全文（不丢字）", s.text, "你好。世界。接下来")

        // 逐前缀喂入：已定稿段单调不减，且任意时刻 closed.joined()+open == 当前文本
        let full = makeTranscript(sentences: 12)
        var st = MinutesKit.MinutesSegments.empty
        var mono = true
        var lossless = true
        var prevClosed = 0
        var idx = full.startIndex
        while idx < full.endIndex {
            idx = full.index(after: idx)
            let prefix = String(full[full.startIndex..<idx])
            st = MinutesKit.advance(st, with: prefix)
            if st.closed.count < prevClosed { mono = false }
            prevClosed = st.closed.count
            if st.text != prefix { lossless = false }
        }
        check("逐字喂入：已定稿段单调不减", mono)
        check("逐字喂入：任何时刻都不丢字", lossless)
        check("逐字喂入：12 句最终都定稿了", st.closed.count >= 10)
        checkEq("全部内容都在（拼接一致）", st.text, full)
        check("按段渲染：段数 > 1（不是一整篇）", st.closed.count > 1)

        // 反例：取消会把 liveText 回填成 baseline=""（cannot 抹掉已转写内容）
        let before = st
        st = MinutesKit.advance(st, with: "")
        checkEq("空串更新不动状态（取消回填不抹字）", st.text, before.text)
        checkEq("空串更新不动段数", st.closed.count, before.closed.count)

        // 反例：转写被整体重写成更短的旧前缀 → 已定稿段不许丢
        let shorter = "你好"
        let kept = MinutesKit.advance(before, with: shorter)
        checkEq("更短的旧前缀不丢已定稿段", kept.closed.count, before.closed.count)

        // 反例：完全陌生的新串 → 已定稿段仍在，新串当尾巴（不静默清空）
        let alien = "换了一段完全不同的内容"
        let alienState = MinutesKit.advance(before, with: alien)
        checkEq("陌生串不清空已定稿段", alienState.closed.count, before.closed.count)
        check("陌生串进尾巴", alienState.open == alien)

        checkEq("整篇一次算（segments(of:)）与推进口径一致",
                MinutesKit.segments(of: full).text, full)
    }

    // MARK: - 3. 提示词（中文 / 四节 / 不许输出思考过程）

    static func sectionThree_提示词() {
        print("\n=== 3. 提示词（四节 + 不许输思考过程 + 输入可核对）===")
        let single = MinutesKit.singlePrompt("大家好，今天我们讨论排期。")
        check("单次提示词含「不要输出思考过程」", single.contains("不要输出思考过程"))
        check("单次提示词含完整反-思考句", single.contains(MinutesKit.noThinkingRule))
        check("单次提示词要求四节", MinutesKit.sectionOrder.allSatisfy { single.contains($0) })
        check("单次提示词带上了转写原文", single.contains("今天我们讨论排期"))
        check("单次提示词要求待办逐条一行", single.contains("- "))

        let map = MinutesKit.mapPrompt(index: 0, total: 3, chunk: "这一段说了预算。")
        check("map 提示词含「不要输出思考过程」", map.contains("不要输出思考过程"))
        check("map 提示词标明段序（第 1/3 段）", map.contains("第 1/3 段"))
        check("map 提示词带上了本段原文", map.contains("这一段说了预算。"))
        check("map 提示词要求只整理本段", map.contains("只整理这一段"))
        check("map 提示词要求四节", MinutesKit.sectionOrder.allSatisfy { map.contains($0) })

        let map2 = MinutesKit.mapPrompt(index: 2, total: 3, chunk: "第三段。")
        check("map 段序随下标变化", map2.contains("第 3/3 段"))

        let reduce = MinutesKit.reducePrompt(partials: ["主题：排期\n关键结论：延后一周", "主题：排期\n待办事项：- 张三 周五前出方案"])
        check("reduce 提示词含「不要输出思考过程」", reduce.contains("不要输出思考过程"))
        check("reduce 提示词含完整反-思考句", reduce.contains(MinutesKit.noThinkingRule))
        check("reduce 提示词要求四节", MinutesKit.sectionOrder.allSatisfy { reduce.contains($0) })
        check("reduce 提示词带上了各段要点", reduce.contains("周五前出方案"))
        check("reduce 提示词要求合并重复项", reduce.contains("合并"))
        check("reduce 提示词标明份数", reduce.contains("2 份要点"))

        // 超长：各段要点必须被截断，reduce 的输入不许无限膨胀
        let many = Array(repeating: String(repeating: "要", count: 5_000), count: 20)
        let bigReduce = MinutesKit.reducePrompt(partials: many)
        check("reduce 输入被封顶（20 份 5000 字要点 < 30000 字）", bigReduce.count < 30_000)
        check("reduce 里每份要点都被截断", bigReduce.contains("…"))
        checkEq("brief 短文本不截断", MinutesKit.brief("很短"), "很短")
        check("brief 长文本被截到 limit", MinutesKit.brief(String(repeating: "字", count: 3_000)).count <= MinutesKit.partialLimit + 1)
    }

    // MARK: - 4. 调用计划：超长必须走 map-reduce

    static func sectionFour_调用计划超长走mapReduce() {
        print("\n=== 4. 调用计划（短 = 1 次；超长 = 片数 + 1 次）===")
        let short = makeTranscript(sentences: 20)      // 200 字
        let planShort = MinutesKit.plan(for: short)
        checkEq("短转写只发 1 条提示词", planShort.mapPrompts.count, 1)
        checkEq("短转写不需要 reduce", planShort.needsReduce, false)
        checkEq("短转写只调 1 次模型", planShort.askCount, 1)
        checkEq("短转写用的是单次提示词", planShort.mapPrompts.first, MinutesKit.singlePrompt(short))

        let long = makeTranscript(sentences: 900)      // 9000 字
        let planLong = MinutesKit.plan(for: long)
        let expectPieces = MinutesKit.chunks(of: long).count
        check("超长必须走 map-reduce（\(planLong.mapPrompts.count) 片）", planLong.mapPrompts.count >= 2)
        checkEq("条数 = 切片数", planLong.mapPrompts.count, expectPieces)
        checkEq("超长需要 reduce", planLong.needsReduce, true)
        checkEq("调用次数 = 片数 + 1（最后一次 reduce）", planLong.askCount, expectPieces + 1)
        let firstPiece = MinutesKit.chunks(of: long)[0]
        check("第 1 条 map 提示词带上了第 1 片原文", planLong.mapPrompts[0].contains(String(firstPiece.prefix(20))))
        check("每条 map 提示词都带反-思考句", planLong.mapPrompts.allSatisfy { $0.contains("不要输出思考过程") })

        let huge = String(repeating: "字", count: MinutesKit.maxTranscriptLength)   // 6 万字
        let planHuge = MinutesKit.plan(for: huge)
        checkEq("6 万字 → 15 片", planHuge.mapPrompts.count, MinutesKit.maxTranscriptLength / MinutesKit.chunkLimit)
        checkEq("6 万字 → 16 次调用", planHuge.askCount, 16)
    }

    // MARK: - 5. 摘要抽取（模型爱带闲聊 / 思考过程 / 代码围栏）

    static func sectionFive_摘要抽取() {
        print("\n=== 5. 摘要抽取（多余的都不算内容）===")
        let clean = """
        主题：iOS 4.0 版本排期
        关键结论：本周先冻结需求，下周开始联调。
        待办事项：
        - 张三：周五前出接口文档
        - 李四：周三前补齐测试用例
        时间线：
        09:10 需求冻结
        09:40 联调计划确认
        """
        let extracted = MinutesKit.extract(clean)
        check("规整输出原样抽出", extracted == clean.trimmingCharacters(in: .whitespacesAndNewlines))
        check("抽出内容含四节标题", MinutesKit.sectionOrder.allSatisfy { extracted?.contains($0) == true })

        let chatty = """
        好的，我先看看这段转写。

        思考：用户提到的预算和排期是两件事，需要分别归到关键结论里。

        主题：项目周会
        关键结论：预算按季度拆，排期顺延一周。
        待办事项：
        - 王五：周一前给预算拆分表
        时间线：
        未指明

        以上是本次纪要，希望有帮助。
        """
        let chattyOut = MinutesKit.extract(chatty)
        check("带闲聊时能抽出摘要", chattyOut != nil)
        check("闲聊被剥掉（开场白不在结果里）", chattyOut?.hasPrefix("主题") == true)
        check("思考过程不出现在结果里", chattyOut?.contains("思考") == false)
        check("思考过程的内容也不在结果里", chattyOut?.contains("需要分别归到") == false)
        check("结尾寒暄被剥掉", chattyOut?.contains("希望有帮助") == false)
        check("正文要点没被误删", chattyOut?.contains("周一前给预算拆分表") == true)

        let fenced = """
        ```text
        主题：一次评审
        关键结论：方案通过，先做小流量。
        待办事项：
        - 未指明：灰度方案
        时间线：
        未指明
        ```
        """
        let fencedOut = MinutesKit.extract(fenced)
        check("围栏包裹也能抽出", fencedOut?.hasPrefix("主题") == true)
        check("围栏行本身不算内容", fencedOut?.contains("```") == false)

        let thinking = "<" + "think" + ">" + "先想想怎么归类……" + "</" + "think" + ">\n主题：临时会议\n关键结论：下周三上线。\n待办事项：\n- 未指明：准备发布说明\n时间线：\n未指明"
        let thinkingOut = MinutesKit.extract(thinking)
        check("思考块被整块去掉", thinkingOut?.contains("怎么归类") == false)
        check("思考块之后的内容保留", thinkingOut?.contains("下周三上线") == true)

        // 反例组：抽不出内容必须返回 nil（页面才会给「重试 / 存原文备忘」）
        checkEq("空输出 → nil", MinutesKit.extract(""), nil)
        checkEq("只有寒暄 → nil", MinutesKit.extract("好的，收到，我来整理一下。"), nil)
        checkEq("只有空白 → nil", MinutesKit.extract("   \n\n  "), nil)
        checkEq("太短 → nil", MinutesKit.extract("主题：会"), nil)
        checkEq("没有汉字（英文）→ nil", MinutesKit.extract("Topic: weekly sync meeting"), nil)
        checkEq("只有标点 → nil", MinutesKit.extract("。。。！！！"), nil)

        // 超长摘要被截断
        let verbose = "主题：很长\n" + String(repeating: "这是一条很长的结论。", count: 500)
        let clamped = MinutesKit.extract(verbose)
        check("超长摘要被截到上限", (clamped?.count ?? 0) <= MinutesKit.maxSummaryLength + 1)
        check("截断留了省略号", clamped?.hasSuffix("…") == true)
    }

    // MARK: - 6. 主题 / 待办数 / 数值文案

    static func sectionSix_主题与待办数() {
        print("\n=== 6. 主题 / 待办数 / 数值文案 ===")
        let body = """
        主题：**版本排期会**
        关键结论：先冻结需求。
        待办事项：
        - 张三：周五前出文档
        - 李四：周三前补用例
        3. 未指明：预约下次评审
        时间线：
        09:10 需求冻结
        """
        checkEq("主题取「主题：」那行", MinutesKit.theme(of: body), "版本排期会")
        checkEq("待办数 = 3", MinutesKit.todoCount(of: body), 3)
        checkEq("待办文案", MinutesKit.todoText(3), "3 项")

        let none = "主题：临时会\n关键结论：无。\n待办事项：\n无\n时间线：\n未指明"
        checkEq("待办「无」→ 0", MinutesKit.todoCount(of: none), 0)
        checkEq("0 条待办文案", MinutesKit.todoText(0), "无待办")

        let noSection = "关键结论：没事。"
        checkEq("没有待办节 → 0", MinutesKit.todoCount(of: noSection), 0)
        checkEq("没有主题节 → 取首行（剥掉「关键结论：」前缀）", MinutesKit.theme(of: noSection), "没事。")

        checkEq("时长 0 秒", MinutesKit.durationText(0), "0 秒")
        checkEq("时长 45 秒", MinutesKit.durationText(45), "45 秒")
        checkEq("时长 90 秒", MinutesKit.durationText(90), "1 分 30 秒")
        checkEq("时长整 2 分", MinutesKit.durationText(120), "2 分")
        checkEq("时长 1 小时", MinutesKit.durationText(3_600), "1 小时 0 分")
        checkEq("时长负数兜底", MinutesKit.durationText(-5), "0 秒")

        checkEq("计时 0 秒", MinutesKit.clockText(0), "00:00")
        checkEq("计时 75 秒", MinutesKit.clockText(75), "01:15")
        checkEq("计时 1 小时零 3 分", MinutesKit.clockText(3_780), "1:03:00")

        checkEq("字数千分位（1234）", MinutesKit.countText(1_234), "1,234 字")
        checkEq("字数（0）", MinutesKit.countText(0), "0 字")
        checkEq("分组（100）", MinutesKit.grouped(100), "100")
        checkEq("分组（1000）", MinutesKit.grouped(1_000), "1,000")
        checkEq("分组（1234567）", MinutesKit.grouped(1_234_567), "1,234,567")

        let memo = MinutesKit.memoText(MinutesKit.Summary(theme: "版本排期会", body: body, todoCount: 3,
                                                         duration: 90, charCount: 2_000))
        check("备忘正文带标题前缀", memo.hasPrefix(MinutesKit.memoPrefix))
        check("备忘正文带时长/字数/待办", memo.contains("1 分 30 秒") && memo.contains("2,000 字") && memo.contains("3 项"))
        check("备忘正文含摘要全文", memo.contains("先冻结需求"))
        let raw = MinutesKit.rawMemoText("这是原文。", duration: 30)
        check("原文备忘带前缀", raw.hasPrefix(MinutesKit.rawMemoPrefix))
        check("原文备忘含原文", raw.contains("这是原文。"))
        checkEq("取更长的一份（不丢已转写内容）", MinutesKit.bestTranscript("短", "长一些的内容"), "长一些的内容")
        checkEq("取更长的一份（stop 返回值更长时用返回值）",
                MinutesKit.bestTranscript("更长的定稿内容", "短"), "更长的定稿内容")
    }

    // MARK: - 7. 空 / 超长 / 失败态判定与文案

    static func sectionSeven_文案与判定() {
        print("\n=== 7. 空 / 超长 / 失败态（不许静默失败）===")
        checkEq("空转写 → empty", MinutesKit.state(of: "").rawValue, "empty")
        checkEq("几个字 → empty", MinutesKit.state(of: "嗯 啊 那个").rawValue, "empty")
        checkEq("正常转写 → ok", MinutesKit.state(of: makeTranscript(sentences: 5)).rawValue, "ok")
        checkEq("超长转写 → tooLong",
                MinutesKit.state(of: String(repeating: "字", count: MinutesKit.maxTranscriptLength + 1)).rawValue, "tooLong")
        checkEq("正好上限 → ok",
                MinutesKit.state(of: String(repeating: "字", count: MinutesKit.maxTranscriptLength)).rawValue, "ok")
        checkEq("只有标点 → empty", MinutesKit.state(of: "。。。。。").rawValue, "empty")

        checkEq("ok 没有提示语", MinutesKit.hint(for: .ok), nil)
        checkEq("empty 的提示语", MinutesKit.hint(for: .empty), MinutesKit.emptyTranscriptHint)
        checkEq("tooLong 的提示语", MinutesKit.hint(for: .tooLong), MinutesKit.tooLongHint)
        check("无权限文案指到设置里", MinutesKit.micDeniedHint.contains("设置"))
        check("机型不支持文案说清门槛", MinutesKit.unsupportedHint.contains("iOS 26"))
        check("起不来文案给重试", MinutesKit.startFailedHint.contains("重试"))
        check("超长文案给原文退路", MinutesKit.tooLongHint.contains("存原文备忘"))
        check("空摘要文案给重试", MinutesKit.emptySummaryHint.contains("重试"))
        check("失败文案带真实原因", MinutesKit.failedHint("请求超时").contains("请求超时"))
        check("失败文案给退路", MinutesKit.failedHint("请求超时").contains("存原文备忘"))
        check("无原因时也给文案", !MinutesKit.failedHint(nil).isEmpty)
        check("分段失败会点名段数", MinutesKit.partialHint(2).contains("2 段"))
        check("可用转写判定", MinutesKit.isUsableTranscript(makeTranscript(sentences: 3)))
        check("不可用转写判定", !MinutesKit.isUsableTranscript("嗯"))
        check("停下录音的文案给原文退路", MinutesKit.cancelledHint.contains("存原文备忘"))
        check("页内「已存备忘」指向", MinutesKit.memoSavedHint.contains("已存备忘"))
        check("原文备忘提示点明来源", MinutesKit.rawMemoSavedHint.contains("会议纪要"))
        checkEq("来源常量与 MemoStore 白名单一致（meeting）", MinutesKit.memoSrc, "meeting")
        checkEq("归一折叠连续空行", MinutesKit.normalized("甲\n\n\n\n乙"), "甲\n\n乙")
    }

    // MARK: - 8. 纪要卡（用真的 AgentCardParser 解）

    static func sectionEight_卡片可被真解析器解出() {
        print("\n=== 8. 纪要卡（```ql-card 围栏 + type=result，必须被真解析器解出）===")
        let summary = MinutesKit.Summary(theme: "iOS 4.0 版本排期", body: """
        主题：iOS 4.0 版本排期
        关键结论：本周先冻结需求，下周开始联调。
        待办事项：
        - 张三：周五前出接口文档
        时间线：
        09:10 需求冻结
        """, todoCount: 1, duration: 90, charCount: 2_000)

        let card = MinutesKit.cardText(summary)
        check("卡片非空", !card.isEmpty)
        check("卡片是 ql-card 围栏", card.hasPrefix("```ql-card\n") && card.hasSuffix("\n```"))
        check("门控识别得到卡片标记", AgentCardParser.containsCardMarker(card))

        let segments = AgentCardParser.parse(card)
        checkEq("解析出且只有 1 段", segments.count, 1)
        guard case .card(let parsed)? = segments.first else {
            check("AgentCardParser 解出了卡片（不是退化成文本）", false)
            return
        }
        check("真的解出了卡片（不是退化成文本）", true)
        checkEq("type=result", parsed.kind, .result)
        check("标题带前缀与主题", (parsed.title ?? "").hasPrefix(MinutesKit.cardTitlePrefix)
                && (parsed.title ?? "").contains("iOS 4.0 版本排期"))
        checkEq("副标题", parsed.subtitle, MinutesKit.cardSubtitle)
        checkEq("状态胶囊是好的", parsed.status?.tone, .ok)
        checkEq("字段数 = 4", parsed.fields.count, MinutesKit.cardFieldKeys.count)
        checkEq("字段名逐项一致", parsed.fields.map(\.key), MinutesKit.cardFieldKeys)
        let fieldDict = Dictionary(uniqueKeysWithValues: parsed.fields.map { ($0.key, $0.value) })
        checkEq("时长字段", fieldDict["时长"], "1 分 30 秒")
        checkEq("字数字段", fieldDict["字数"], "2,000 字")
        checkEq("待办字段", fieldDict["待办"], "1 项")
        check("摘要字段有正文", (fieldDict["摘要"] ?? "").contains("先冻结需求"))
        check("footer 写「已存备忘」", (parsed.footer ?? "").contains("已存备忘"))
        check("卡片不是空卡", !parsed.isEmpty)
        check("降级纯文本里也能看到主题与待办", parsed.plainText.contains("iOS 4.0") && parsed.plainText.contains("1 项"))

        // 卡片里的摘要是预览：必须被截断（全文在备忘里）
        let longSummary = MinutesKit.Summary(theme: "长会", body: String(repeating: "很长的一条结论。", count: 200),
                                             todoCount: 0, duration: 600, charCount: 20_000)
        let longCard = MinutesKit.cardText(longSummary)
        let longParsed: AgentCard? = {
            if case .card(let c)? = AgentCardParser.parse(longCard).first { return c }
            return nil
        }()
        let longField = longParsed?.fields.first { $0.key == "摘要" }?.value ?? ""
        check("卡片里的摘要被截断", longField.count <= MinutesKit.cardSummaryLimit + 1)
        check("截断了才点省略号", longField.hasSuffix("…"))

        // 反例：抽不出内容的纪要 → 不产卡（空转写不产卡）
        let emptySummary = MinutesKit.Summary(theme: "", body: "", todoCount: 0, duration: 0, charCount: 0)
        checkEq("空摘要 → 不产卡", MinutesKit.cardText(emptySummary), "")
        let shortBody = MinutesKit.Summary(theme: "会", body: "太短", todoCount: 0, duration: 0, charCount: 3)
        checkEq("正文太短 → 不产卡", MinutesKit.cardText(shortBody), "")
        checkEq("空转写经真解析器也解不出卡（会退化成文本）", AgentCardParser.parse(MinutesKit.cardText(emptySummary)).count, 1)

        // 摘要组装：原文抽不出内容 → nil（页面才能走失败态）
        checkEq("抽不出内容 → 组装失败", MinutesKit.summary(raw: "好的，收到。", duration: 10, charCount: 100), nil)
        let assembled = MinutesKit.summary(raw: """
        主题：预算会
        关键结论：按季度拆。
        待办事项：
        - 未指明：拆分表
        时间线：
        未指明
        """, duration: 65, charCount: 800)
        check("能组装出纪要", assembled != nil)
        checkEq("组装后主题", assembled?.theme, "预算会")
        checkEq("组装后待办数", assembled?.todoCount, 1)
        checkEq("组装后时长", assembled?.duration, 65)
    }

    // MARK: - 9. 录音页与聊天页接线护栏（读源码）

    static func sectionNine_录音页与接线护栏() {
        print("\n=== 9. 录音页 / 聊天页接线护栏（读源码）===")
        let view = readSource("qingliao/Features/Chat/MeetingMinutesView.swift")
        let chat = readSource("qingliao/Features/Chat/ChatView.swift")
        let memo = readSource("qingliao/Core/MemoStore.swift")
        check("录音页源码读到了", !view.isEmpty)
        check("聊天页源码读到了", !chat.isEmpty)

        check("起手先要麦克风权限", view.contains("ensureMicrophonePermission()"))
        check("起手真的起麦（baseline 空）", view.contains("start(baseline: \"\")"))
        check("停止走 stop() 拿全文", view.contains("await liveSpeech.stop()"))
        check("音量走 currentInputLevel()", view.contains("currentInputLevel()"))
        check("分段走 MinutesKit 状态机", view.contains("MinutesKit.advance("))
        check("按段渲染（ForEach 已定稿段）", view.contains("ForEach") && view.contains("closed"))
        // 这两条查的是**代码**：注释里写反例（「绝不 Text(liveText)」）不该被判违规
        let viewCode = codeOnly(view)
        check("严禁整篇 Text(liveText) 重绘",
              !viewCode.contains("Text(liveSpeech.liveText)") && !viewCode.contains("Text(liveText)"))
        check("尾迹也不许整篇渲染", !viewCode.contains("Text(segments.text)"))
        check("整理走 MinutesKit 计划（超长自动 map-reduce）", view.contains("MinutesKit.plan(for:"))
        check("整理有进度态", view.contains("progress"))
        check("存备忘（source=meeting）", view.contains("MemoStore.shared.add(content:") && view.contains("MinutesKit.memoSrc"))
        check("往会话发纪要卡", view.contains("Notification.Name.qingliaoMinutesCard"))
        check("失败态有重试入口", view.contains("重试"))
        check("中途退出给「存原文备忘」退路", view.contains("存原文备忘"))
        check("视图可无参构造（另一个 agent 这么调）", view.contains("struct MeetingMinutesView: View"))

        checkEq("聊天页只声明了一处通知名",
                chat.components(separatedBy: "static let qingliaoMinutesCard").count - 1, 1)
        checkEq("聊天页只挂了一处 onReceive",
                chat.components(separatedBy: "for: .qingliaoMinutesCard").count - 1, 1)
        check("插入点复用本地卡片路径（isPush，不进模型上下文）",
              chat.contains("msg.isPush = true"))
        check("备忘来源白名单加了会议纪要", memo.contains("case \"meeting\": return \"会议纪要\""))

        checkEq("抽不出内容不产卡（组合判定）",
                MinutesKit.cardText(MinutesKit.Summary(theme: "x", body: "", todoCount: 0, duration: 1, charCount: 1)), "")
    }
}
