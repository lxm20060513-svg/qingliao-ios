// AgentCardParser 单元测试（Linux 本地预检用，纯 Foundation，无 UI 依赖）
//
// 编译运行（在仓库根目录，cq 工具链见 check_swift.sh）：
//   $SWIFT/swiftc -o /tmp/test_agent_card qingliao/Core/AgentCardParser.swift scripts/test_agent_card.swift
//   /tmp/test_agent_card
//
// 覆盖：零回归（无标记/非法 JSON/空卡片）· 流式安全（未闭合不出卡片）· 卡片解析与字段容错 · plainText 降级

import Foundation

// MARK: - 断言工具

nonisolated(unsafe) var failures = 0   // 仅测试进程内使用（Swift 6 严格并发下需显式标注）
func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

/// 简化断言：解析结果必须是单文本段且与原文逐字相同（零回归的核心判据）
func expectSingleText(_ name: String, _ input: String) {
    let segs = AgentCardParser.parse(input)
    guard segs.count == 1, case .text(let t) = segs[0] else {
        check(name + "（应为单个文本段）", false)
        return
    }
    check(name + "（文本逐字保留）", t == input)
}

func cardOf(_ segs: [AgentCardParser.Segment], _ idx: Int) -> AgentCard? {
    guard segs.indices.contains(idx), case .card(let c) = segs[idx] else { return nil }
    return c
}

func textOf(_ segs: [AgentCardParser.Segment], _ idx: Int) -> String? {
    guard segs.indices.contains(idx), case .text(let t) = segs[idx] else { return nil }
    return t
}

@main
enum AgentCardTestMain {
    /// 全部用例（顶层代码收敛进函数：多文件编译时 swiftc 只允许 main.swift 有顶层表达式）
    static func runAllTests() {
    // MARK: - 1. 零回归：无标记的普通文本 / Markdown / 代码块

    let plain = "# 标题\n\n这是**加粗**、`代码`、还有列表：\n- a\n- b"
    expectSingleText("无标记纯文本原样", plain)

    let codeOnly = "看这段代码：\n```swift\nlet x = 1\n```\n完事"
    expectSingleText("普通代码块不误判为卡片", codeOnly)

    expectSingleText("空字符串", "")

    // 标记只出现在正文（非围栏行）也不该被当成卡片
    let mention = "这个协议用 ql-card 标记，行内提到不算卡片。"
    expectSingleText("行内提到 ql-card 不解析", mention)

    // MARK: - 2. 完整卡片：标记 + 字段解析

    let fullJSON = """
    {"type":"result","title":"家庭网络体检","subtitle":"2026-09-10 21:40",
     "status":{"text":"已完成","tone":"ok"},
     "metrics":[{"label":"下载","value":94.2,"unit":"Mbps","tone":"ok"},{"label":"延迟","value":18,"unit":"ms"}],
     "fields":[{"key":"路由器","value":"小米 RM1800"}],
     "list":[{"title":"重启路由器","subtitle":"耗时 2 分钟","status":"完成","tone":"ok"},
             {"title":"刷新 DNS 缓存","status":"跳过","tone":"warn"}],
     "table":{"columns":["设备","IP"],"rows":[["NAS","192.168.x.x"]]},
     "footer":"共 2 项操作"}
    """
    let cardText = "已经修好路由器，结果如下：\n\n```ql-card\n\(fullJSON)\n```\n\n还要我做什么吗？"

    let segs = AgentCardParser.parse(cardText)
    check("完整卡片：3 段（文本/卡片/文本）", segs.count == 3)

    let c1 = cardOf(segs, 1)
    check("卡片解析成功", c1 != nil)
    check("type=result", c1?.kind == .result)
    check("title", c1?.title == "家庭网络体检")
    check("subtitle", c1?.subtitle == "2026-09-10 21:40")
    check("status.text", c1?.status?.text == "已完成")
    check("status.tone=ok", c1?.status?.tone == .ok)
    check("metrics 2 条", c1?.metrics.count == 2)
    check("metric 数值去尾零（94.2）", c1?.metrics.first?.value == "94.2")
    check("metric 标签", c1?.metrics.first?.label == "下载")
    check("metric 单位", c1?.metrics.first?.unit == "Mbps")
    check("metric 无 tone → nil", c1?.metrics.last?.tone == nil)
    check("fields 键值", c1?.fields.first?.key == "路由器" && c1?.fields.first?.value == "小米 RM1800")
    check("list 2 条", c1?.items.count == 2)
    check("list 项 subtitle/status", c1?.items.first?.subtitle == "耗时 2 分钟" && c1?.items.first?.status == "完成")
    check("list 项 tone=warn", c1?.items.last?.tone == .warn)
    check("table 列/行", c1?.table?.columns == ["设备", "IP"] && c1?.table?.rows == [["NAS", "192.168.x.x"]])
    check("footer", c1?.footer == "共 2 项操作")
    check("前段文本保留", textOf(segs, 0) == "已经修好路由器，结果如下：\n")
    check("后段文本保留", textOf(segs, 2) == "\n还要我做什么吗？")
    check("非空卡片", c1?.isEmpty == false)

    // plainText 降级：各段文字都在（复制/大爆炸/朗读用）
    let pt = c1?.plainText ?? ""
    check("plainText 含标题", pt.contains("家庭网络体检"))
    check("plainText 含指标", pt.contains("下载：94.2Mbps"))
    check("plainText 含清单", pt.contains("· 重启路由器（耗时 2 分钟）[完成]"))
    check("plainText 含表格", pt.contains("设备 | IP") && pt.contains("NAS | 192.168.x.x"))
    check("plainText 含页脚", pt.contains("共 2 项操作"))

    // MARK: - 3. 流式安全：围栏未闭合 → 全部按文本（绝不半截卡片）

    let half = "开始输出：\n\n```ql-card\n{\"title\":\"家庭网络体检\",\"metrics\":[{\"label\":\"下载\",\"value\":9"
    let halfSegs = AgentCardParser.parse(half)
    check("未闭合围栏不产卡片", halfSegs.allSatisfy { if case .text = $0 { return true } else { return false } })
    check("未闭合围栏文本逐字保留", halfSegs.count == 1 && textOf(halfSegs, 0) == half)

    let closed = half + "4.2}]}\n```"
    let closedSegs = AgentCardParser.parse(closed)
    check("闭合瞬间出卡片", cardOf(closedSegs, 1)?.title == "家庭网络体检")

    // 标记出现在流式文本里但还没到 JSON
    let justMarker = "文字\n```ql-card\n"
    expectSingleText("只有围栏头（无内容）不产卡片", justMarker)

    // MARK: - 4. 零回归：非法 JSON / 空卡片 → 原文照旧（连围栏一起）

    let badJSON = "结果：\n```ql-card\n{这不是合法 JSON,,}\n```\n完"
    let badSegs = AgentCardParser.parse(badJSON)
    check("非法 JSON → 单文本段", badSegs.count == 1)
    check("非法 JSON 原文逐字保留", textOf(badSegs, 0) == badJSON)

    let rawArrayJSON = "结果：\n```ql-card\n[1,2,3]\n```"
    let arrSegs = AgentCardParser.parse(rawArrayJSON)
    check("JSON 是数组（非对象）→ 原文保留", arrSegs.count == 1 && textOf(arrSegs, 0) == rawArrayJSON)

    let emptyCard = "结果：\n```ql-card\n{}\n```"
    let emptySegs = AgentCardParser.parse(emptyCard)
    check("空卡片 {} → 原文保留", emptySegs.count == 1 && textOf(emptySegs, 0) == emptyCard)

    let unknownKeys = "结果：\n```ql-card\n{\"foo\":\"bar\"}\n```"
    let unknownSegs = AgentCardParser.parse(unknownKeys)
    check("无已知字段 → 原文保留", unknownSegs.count == 1 && textOf(unknownSegs, 0) == unknownKeys)

    // MARK: - 5. 容错：类型别名 / 值类型 / 起始围栏写法

    let loose = "```ql_card\n{\"type\":\"METRICS\",\"status\":\"已完成\",\"metrics\":[{\"label\":\"CPU\",\"value\":1.0},{\"label\":\"内存\",\"value\":\"50%\"}],\"list\":[\"纯字符串项\"],\"fields\":[{\"label\":\"用 label 当 key\",\"value\":true}]}\n```"
    let looseSegs = AgentCardParser.parse(loose)
    let c2 = cardOf(looseSegs, 0)
    check("ql_card 围栏被识别", c2 != nil)
    check("type 大小写不敏感 → metrics", c2?.kind == .metrics)
    check("status 字符串写法", c2?.status?.text == "已完成")
    check("整数 1.0 → \"1\"", c2?.metrics.first?.value == "1")
    check("字符串值原样", c2?.metrics.last?.value == "50%")
    check("list 纯字符串项", c2?.items.count == 1 && c2?.items.first?.title == "纯字符串项")
    check("fields/label 当 key + 布尔值", c2?.fields.first?.key == "用 label 当 key" && c2?.fields.first?.value == "是")

    // items 作为 list 的别名（单独一张卡，验证键名兼容）
    let itemsAlias = "```ql-card\n{\"title\":\"t\",\"items\":[{\"text\":\"用 text 当标题\",\"detail\":\"用 detail 当副标题\"}]}\n```"
    check("items 键名兼容 + text/detail 别名",
          cardOf(AgentCardParser.parse(itemsAlias), 0)?.items.first?.title == "用 text 当标题"
          && cardOf(AgentCardParser.parse(itemsAlias), 0)?.items.first?.subtitle == "用 detail 当副标题")

    let toneAlias = "```qlcard\n{\"title\":\"t\",\"status\":{\"text\":\"异常\",\"tone\":\"FAILED\"}}\n```"
    check("tone 别名 failed → error", cardOf(AgentCardParser.parse(toneAlias), 0)?.status?.tone == .error)

    let cnTone = "```ql-card\n{\"title\":\"t\",\"status\":{\"text\":\"成功\",\"tone\":\"完成\"}}\n```"
    check("tone 中文别名 → ok", cardOf(AgentCardParser.parse(cnTone), 0)?.status?.tone == .ok)

    // 缩进的围栏行（AI 偶发缩进）也能识别
    let indented = "  ```ql-card\n  {\"title\":\"缩进卡片\"}\n  ```"
    check("缩进围栏行可识别", cardOf(AgentCardParser.parse(indented), 0)?.title == "缩进卡片")

    // MARK: - 6. 多卡片 + 与代码块共存

    let two = "```ql-card\n{\"title\":\"卡片一\"}\n```\n\n中间文字\n\n```swift\nlet a = 1\n```\n\n```ql-card\n{\"title\":\"卡片二\"}\n```"
    let twoSegs = AgentCardParser.parse(two)
    var cardTitles: [String] = []
    for s in twoSegs { if case .card(let c) = s, let t = c.title { cardTitles.append(t) } }
    check("两张卡片都被识别（顺序正确）", cardTitles == ["卡片一", "卡片二"])
    check("卡片间的 swift 代码块留在文本段", twoSegs.contains { if case .text(let t) = $0 { return t.contains("```swift") } else { return false } })

    // 门控函数
    check("containsCardMarker：有标记", AgentCardParser.containsCardMarker("x\n```ql-card\ny"))
    check("containsCardMarker：无标记", !AgentCardParser.containsCardMarker("普通文本 ```swift\nlet a = 1"))

    // MARK: - 7. 中文 / emoji / 多行 JSON 安全

    let emojiCard = "```ql-card\n{\"title\":\"体检 ✅ 完成\",\"subtitle\":\"📶 5GHz\",\"status\":{\"text\":\"已通过\"}}\n```"
    check("中文 emoji 标题正常", cardOf(AgentCardParser.parse(emojiCard), 0)?.title == "体检 ✅ 完成")

    // MARK: - 8. plan 类型（v3.9.58 任务计划卡）

    // type=plan 解析为 .plan Kind（大小写/空白容错与其他 type 同口径）
    let planCard = "```ql-card\n{\"type\":\"plan\",\"title\":\"备份照片\",\"status\":{\"text\":\"2/3 完成\",\"tone\":\"ok\"},"
        + "\"list\":[{\"title\":\"扫描相册\",\"subtitle\":\"发现 128 张新照片\",\"status\":\"完成\",\"tone\":\"ok\"},"
        + "{\"title\":\"上传到 NAS\",\"subtitle\":\"已传 86 张\",\"status\":\"进行中\",\"tone\":\"warn\"},"
        + "{\"title\":\"生成缩略图\",\"status\":\"待开始\",\"tone\":\"info\"}]}\n```"
    let planSegs = AgentCardParser.parse(planCard)
    let plan = cardOf(planSegs, 0)
    check("plan 类型解析为 .plan", plan?.kind == .plan)
    check("plan 卡步骤数正确", plan?.items.count == 3)
    check("plan 卡步骤带状态胶囊数据", plan?.items[1].status == "进行中" && plan?.items[1].tone == .warn)
    check("plan 卡 subtitle 段保留", plan?.items[0].subtitle == "发现 128 张新照片")
    // 大写 PLAN 容错
    let planUpper = "```ql-card\n{\"type\":\"PLAN\",\"title\":\"大写容错\"}\n```"
    check("PLAN 大写容错", cardOf(AgentCardParser.parse(planUpper), 0)?.kind == .plan)
    // plainText 降级不丢步骤
    let planPlain = plan?.plainText ?? ""
    check("plan plainText 含全部步骤", planPlain.contains("扫描相册") && planPlain.contains("上传到 NAS") && planPlain.contains("生成缩略图"))
    // 未知 type 仍回退 .result（原有容错不被 plan 破坏）
    let unknownType = "```ql-card\n{\"type\":\"whatever\",\"title\":\"未知类型\"}\n```"
    check("未知 type 回退 .result", cardOf(AgentCardParser.parse(unknownType), 0)?.kind == .result)

    // MARK: - 9. 行内闭合围栏（2026-09-26 实锤：模型把 ``` 粘在 JSON 末尾同一行）
    // 现象：解析器只认行首 ```，认不出闭合 → 整块卡片当代码块原样显示（用户报「出一堆代码」）。

    let inlineClosed = "已经同步完了，结果如下：\n\n```ql-card\n{\"type\":\"result\",\"title\":\"同步完成\",\"footer\":\"未发版：攒着\"}```\n\n还要继续吗？"
    let inlineSegs = AgentCardParser.parse(inlineClosed)
    check("行内闭合围栏出卡片", cardOf(inlineSegs, 1)?.title == "同步完成")
    check("行内闭合：footer 完整", cardOf(inlineSegs, 1)?.footer == "未发版：攒着")
    check("行内闭合：前段文本保留", textOf(inlineSegs, 0) == "已经同步完了，结果如下：\n")
    // 切点行之后各行原样进下一文本段（含紧跟的空行）
    check("行内闭合：后段文本保留", textOf(inlineSegs, 2) == "\n还要继续吗？")

    // 多行 JSON + 行内闭合（真实事故形态：JSON 跨行，最后一行 }``` 同行）
    let inlineMulti = "```ql-card\n{\"title\":\"跨行卡\",\n \"list\":[{\"title\":\"步骤一\",\"tone\":\"ok\"},{\"title\":\"步骤二\",\"tone\":\"warn\"}],\n \"footer\":\"2 步\"}```"
    let inlineMultiSegs = AgentCardParser.parse(inlineMulti)
    check("多行 JSON 行内闭合出卡", cardOf(inlineMultiSegs, 0)?.title == "跨行卡")
    check("多行 JSON 行内闭合：清单完整", cardOf(inlineMultiSegs, 0)?.items.count == 2)
    check("多行 JSON 行内闭合：footer", cardOf(inlineMultiSegs, 0)?.footer == "2 步")

    // 反向自证：行内 ``` 之后 JSON 仍非法 → 必须退回原文（不能瞎截出半截卡片）
    let inlineBad = "```ql-card\n{这不是 JSON}```"
    let inlineBadSegs = AgentCardParser.parse(inlineBad)
    check("行内闭合但 JSON 非法 → 原文保留", inlineBadSegs.count == 1 && textOf(inlineBadSegs, 0) == inlineBad)

    // 反向自证：流式半截 JSON 后面跟着普通代码（无闭合）→ 不出卡、原文逐字保留
    let inlineStreaming = "文字\n```ql-card\n{\"title\":\"半截\",\"metrics\":[{\"label\":\"下\",\"value\":9"
    let inlineStreamingSegs = AgentCardParser.parse(inlineStreaming)
    check("流式半截 + 行内无闭合 → 不出卡", inlineStreamingSegs.allSatisfy { if case .text = $0 { return true } else { return false } })
    check("流式半截原文逐字保留", inlineStreamingSegs.count == 1 && textOf(inlineStreamingSegs, 0) == inlineStreaming)

    // 行内 ``` 在普通代码块里不误伤（无 ql-card 围栏 → 门控短路，零改动）
    let plainInlineFence = "看代码：\n```\nlet a = 1\n```swift\nlet b = 2\n```"
    expectSingleText("无卡片标记的代码块不受影响", plainInlineFence)

    // 卡片围栏后的行内 ``` 收尾（卡片仍出，后面残留文字另起文本段）
    let inlineTail = "```ql-card\n{\"title\":\"卡\"}```尾巴文字"
    let inlineTailSegs = AgentCardParser.parse(inlineTail)
    check("行内闭合后残留文字进文本段", cardOf(inlineTailSegs, 0)?.title == "卡" && textOf(inlineTailSegs, 1) == "尾巴文字")

    // 对抗：卡片 JSON 的文本字段里合法含 ``` （行内）→ 截断必然切坏 JSON，
    // 必须退回原文，绝不能把好卡截成半截。
    let inlineInField = "```ql-card\n{\"title\":\"卡\",\"text\":\"用 ```ql-card 包裹\"}```"
    let inlineInFieldSegs = AgentCardParser.parse(inlineInField)
    check("字段内含 ``` → 退回原文不截半", inlineInFieldSegs.count == 1 && textOf(inlineInFieldSegs, 0) == inlineInField)

    // 对抗：两张卡片之间夹 ```swift 代码块（行内闭合写法也不能吞掉中间的代码块）
    let twoCards = "```ql-card\n{\"title\":\"甲\"}```\n\n```swift\nlet a = 1\n```\n\n```ql-card\n{\"title\":\"乙\"}```"
    let twoCardsSegs = AgentCardParser.parse(twoCards)
    check("两卡片 + 中间代码块：甲出卡", cardOf(twoCardsSegs, 0)?.title == "甲")
    // 段序 = 甲卡(0) / 中间代码块文本(1) / 乙卡(2)：两张卡之间必然夹一个文本段
    check("两卡片 + 中间代码块：乙出卡", cardOf(twoCardsSegs, 2)?.title == "乙")
    check("两卡片 + 中间代码块：乙卡前是代码块段", cardOf(twoCardsSegs, 1) == nil
        && textOf(twoCardsSegs, 1)?.contains("```swift") == true)
    check("两卡片 + 中间代码块：代码块原文保留", twoCardsSegs.contains { if case .text(let t) = $0 { return t.contains("let a = 1") } else { return false } })

    // 对抗：行内闭合 + 后面紧跟一张正常独占行闭合的卡（两次消费互不干扰）
    let mixedClose = "```ql-card\n{\"title\":\"内\"}```\n```ql-card\n{\"title\":\"外\"}\n```"
    let mixedSegs = AgentCardParser.parse(mixedClose)
    check("行内闭合后紧跟独占行闭合：两卡都在", cardOf(mixedSegs, 0)?.title == "内" && cardOf(mixedSegs, 1)?.title == "外")

    // 对抗：行内闭合 + 卡片有 3 个以上段落，前置普通代码块不受影响
    let preCode = "先看代码：\n```python\nprint(1)\n```\n然后：\n```ql-card\n{\"title\":\"后卡\"}```"
    let preCodeSegs = AgentCardParser.parse(preCode)
    check("前置普通代码块 + 行内闭合卡", cardOf(preCodeSegs, 1)?.title == "后卡"
        && preCodeSegs.contains { if case .text(let t) = $0 { return t.contains("print(1)") } else { return false } })

    // 回归 v3.9.87：裸 ``` 是「闭合行」写法，不能被当成非卡围栏的开块
    // （曾把后面整段连同真卡一起吞成文本）
    let bareFenceThenCard = "```ql-card\n{\"title\":\"A\"}```\n```\n说明文字\n```ql-card\n{\"title\":\"B\"}\n```\n尾部"
    // 段序 = 甲卡(0) / 裸 ```+说明文字 文本段(1) / 乙卡(2) / 尾部文本(3)
    let bfSegs = AgentCardParser.parse(bareFenceThenCard)
    check("裸 ``` 闭合行后的真卡不丢（B 卡仍在）", cardOf(bfSegs, 2)?.title == "B")
    check("裸 ``` 之后到 B 卡之间的原文保留",
          textOf(bfSegs, 1)?.contains("说明文字") == true)

    // 回归：正常独占行闭合的老写法必须逐字不变
    let normalClosed = "```ql-card\n{\"title\":\"老写法\"}\n```"
    check("老写法（独占行闭合）不受影响", cardOf(AgentCardParser.parse(normalClosed), 0)?.title == "老写法")

    // 反向自证：完整 JSON + 围栏未闭合（流式中间帧）必须逐字保留原文，
    // 绝不能先渲染卡片、下一帧又退成代码块（v3.9.87 审查发现的用户可见跳动）。
    let unclosedComplete = "```ql-card\n{\"title\":\"还没写完\"}"
    let unclosedSegs = AgentCardParser.parse(unclosedComplete)
    check("完整 JSON + 未闭合围栏 → 不出卡（防流式回退跳动）",
        unclosedSegs.allSatisfy { if case .text = $0 { return true } else { return false } })
    check("完整 JSON + 未闭合围栏 → 原文逐字保留",
        unclosedSegs.count == 1 && textOf(unclosedSegs, 0) == unclosedComplete)
    // 逐帧复现流式：末帧补上闭合围栏后必须变成卡片（不得反向吞成代码块）
    let unclosedThenClosed = unclosedComplete + "\n```"
    check("下一帧补上闭合围栏 → 正常出卡",
        cardOf(AgentCardParser.parse(unclosedThenClosed), 0)?.title == "还没写完")
    // 完整性对照：同一份 JSON 显式闭合的形态必须仍然出卡（证明上一条不是被门槛整体堵死）
    check("显式闭合的同款 JSON 仍出卡（门槛只拦未闭合）",
        cardOf(AgentCardParser.parse("```ql-card\n{\"title\":\"还没写完\"}\n```"), 0)?.title == "还没写完")

    // 反向自证：外层围栏未闭合时，内层 ```ql-card 是「文档里贴的示例」，不得渲染成真卡
    let nestedExample = "```markdown\n```ql-card\n{\"title\":\"示例卡\"}\n```\n```"
    let nestedSegs = AgentCardParser.parse(nestedExample)
    check("外层围栏未闭合：内层 ql-card 示例不渲染成卡（防假卡）",
        nestedSegs.allSatisfy { if case .text = $0 { return true } else { return false } }
        && textOf(nestedSegs, 0) == nestedExample)
    }

    static func main() {
        runAllTests()
        print(failures == 0 ? "\n🎉 全部通过" : "\n❌ \(failures) 个失败")
        exit(failures == 0 ? 0 : 1)
    }
}
