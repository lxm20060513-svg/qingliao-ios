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
     "table":{"columns":["设备","IP"],"rows":[["NAS","192.168.31.40"]]},
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
    check("table 列/行", c1?.table?.columns == ["设备", "IP"] && c1?.table?.rows == [["NAS", "192.168.31.40"]])
    check("footer", c1?.footer == "共 2 项操作")
    check("前段文本保留", textOf(segs, 0) == "已经修好路由器，结果如下：\n")
    check("后段文本保留", textOf(segs, 2) == "\n还要我做什么吗？")
    check("非空卡片", c1?.isEmpty == false)

    // plainText 降级：各段文字都在（复制/大爆炸/朗读用）
    let pt = c1?.plainText ?? ""
    check("plainText 含标题", pt.contains("家庭网络体检"))
    check("plainText 含指标", pt.contains("下载：94.2Mbps"))
    check("plainText 含清单", pt.contains("· 重启路由器（耗时 2 分钟）[完成]"))
    check("plainText 含表格", pt.contains("设备 | IP") && pt.contains("NAS | 192.168.31.40"))
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
    }

    static func main() {
        runAllTests()
        print(failures == 0 ? "\n🎉 全部通过" : "\n❌ \(failures) 个失败")
        exit(failures == 0 ? 0 : 1)
    }
}
