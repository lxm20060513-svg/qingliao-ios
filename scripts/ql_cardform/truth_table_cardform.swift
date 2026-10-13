// MARK: - #25 可交互表单卡真值表（v4.0.104）
//
// 口径（台账 §2499 待做池 #25 原文）：
//   ql-card 支持「卡片内提交 / 算数」；**卡片动作必须走既有白名单**，不可用时**降级只读**，
//   **反复提交幂等**。
//
// 落点：
//   · 协议/解析  Core/AgentCardParser.swift（Kind.form + Form/FormField + compose/missingRequired）
//   · 回执存储  Core/CardFormStore.swift（本地 UserDefaults，指纹隔离 + 容量上限 + 一键清空）
//   · 视图      Features/Chat/AgentCardFormSection.swift（独立小 View）
//   · 接线      AgentResultCard → ChatComponents → MessageBubble → ChatView(sendCore)
//
// 为什么值得钉：下面每一条**坏了都不报错** ——
//   ① 提交回调没接上 → 卡永远只读（用户以为 AI 不会问话）；
//   ② 视图里自己拼合成文本 → 与解析层口径分叉，模板占位符对不上且没人发现；
//   ③ 先回调后落账 → 提交瞬间杀 App 就丢回执，重进会话又能再提交一遍（幂等破）；
//   ④ 视图自己读写 UserDefaults → 单一真源破，清缓存/换键名时两张表各自失忆；
//   ⑤ 只读分支排到交互分支之前 → 有回调也点不了（顺序错，编译不报错）；
//   ⑥ 视图直接执行动作/发网络 → 绕过既有白名单与权限闸门。
//
// 单文件（读源文件做护栏，不 import 项目代码）→ run_unit 直接编跑。

import Foundation

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

// MARK: 读源

let parserPath = "qingliao/Core/AgentCardParser.swift"
let storePath = "qingliao/Core/CardFormStore.swift"
let sectionPath = "qingliao/Features/Chat/AgentCardFormSection.swift"
let cardPath = "qingliao/Features/Chat/AgentResultCard.swift"
let compsPath = "qingliao/Features/Chat/ChatComponents.swift"
let bubblePath = "qingliao/Features/Chat/ChatMessageBubble.swift"
let viewPath = "qingliao/Features/Chat/ChatView.swift"

let parserRaw = src(parserPath)
let storeRaw = src(storePath)
let sectionRaw = src(sectionPath)
let cardRaw = src(cardPath)
let compsRaw = src(compsPath)
let bubbleRaw = src(bubblePath)
let viewRaw = src(viewPath)

let parser = code(parserRaw)
let store = code(storeRaw)
let section = code(sectionRaw)
let card = code(cardRaw)
let comps = code(compsRaw)
let bubble = code(bubbleRaw)
let view = code(viewRaw)

// 路径漂移必须炸（读不到文件时上面全是空串 —— 不钉住的话整表会静默全绿）
check("前置：七个源文件都读到了内容（路径漂移会静默全绿）",
      [parser, store, section, card, comps, bubble, view].allSatisfy { $0.count > 500 })

// MARK: ① 协议与解析

check("① 解析层有 form 卡类型（Kind.form）", parser.contains("case form"))
check("① form 段解析有独立出口（parseFields）", parser.contains("private static func parseFields("))
check("① 构造卡片时真的把 form 传进去了", parser.contains("form: form"))
check("① 无字段/字段无名 → 返回 nil（不画空表单）", parser.contains("guard !fields.isEmpty else { return nil }"))
check("① 未知字段类型回落 text（不丢字段）", parser.contains("return .text"))
check("① choice 无选项回落 text（否则用户点不了任何东西）",
      parser.contains("return options.isEmpty ? .text : .choice"))

// MARK: ② 空卡判定 + 纯文本降级

check("② isEmpty 把 form 计入（只有表单段的卡不算空卡）", parser.contains("&& form == nil"))
check("② plainText 落表单字段（只读降级/复制/导出不丢字）",
      parser.contains("if let form {") && parser.contains("· \\(f.label)"))

// MARK: ③ 回执存储（单一真源 + 容量 + 幂等 + 隐私）

check("③ 回执指纹＝消息种子 + 标题 + 内容签名（只取标题+字段 key 会跨卡误判）",
      store.contains("static func fingerprint(seed: String, title: String, signature: String) -> UInt64"))
check("③ 键前缀只此一处定义（索引键另立一条，不许把前缀拼在别处）",
      countOf("\"qingliao_card_form_\"", in: storeRaw) == 1
      && storeRaw.contains("\"qingliao_card_form_index\""))
check("③ 键前缀在全仓不散落（只有存储层知道键名）",
      countOf("qingliao_card_form_", in: parserRaw + sectionRaw + cardRaw + viewRaw) == 0)
check("③ 容量上限存在且是真的（超限删掉最旧那条的键）",
      store.contains("static let maxRecords = 60") && store.contains("for old in idx[Self.maxRecords...]"))
check("③ 一键清空存在（隐私口径：本地记录用户可整体清掉）", store.contains("func clearAll()"))
check("③ 落盘走 Codable（Linux corelibs 下 JSONSerialization 读回嵌套字典必失败）",
      store.contains("JSONEncoder().encode(stored)") && !store.contains("JSONSerialization"))

// MARK: ④ 视图：门控顺序 / 幂等顺序 / 不越权

check("④ 可交互门控 = 有回调且未提交（唯一真源）",
      section.contains("private var canSubmit: Bool { onSubmit != nil && submitted == nil }"))
check("④ 分支顺序：已提交 → 可交互 → 只读（顺序错 = 有回调也点不了，编译不报错）",
      section.contains("            if let receipt = submitted {\n                receiptView(receipt)\n            } else if canSubmit {\n                inputs\n                submitRow\n            } else {\n                readOnlyRows\n            }"))
check("④ 提交是「先落账后回调」（反了 → 提交瞬间杀 App 丢回执、重进还能再提交）",
      section.contains("        let receipt = CardFormStore.Submission(values: values, summary: text)\n        CardFormStore.shared.record(receipt, for: fingerprint)\n        submitted = receipt"))
check("④ 提交入口有在飞闸门 + 必填闸门", section.contains("guard canSubmit, !inFlight, missing.isEmpty else { return }"))
check("④ 合成文本只此一条口径（视图不得自己拼模板）",
      section.contains("form.compose(values: values)") && !section.contains("replacingOccurrences(of: \"{"))
check("④ 视图不直接执行动作（不碰动作执行器 / 收件箱 / 网络）",
      !section.contains("AgentActionExecutor") && !section.contains("InboxStore") && !section.contains("await "))
check("④ 视图不自己读写 UserDefaults（一切经 CardFormStore）",
      !section.contains("UserDefaults"))
check("④ 视图按 (seed: 消息id, title:, signature: 内容签名) 算指纹（退回标题+key 就是那起跨卡事故）",
      section.contains("CardFormStore.fingerprint(seed: seed, title: title, signature: form.signature)"))
check("④ 已提交卡有「重填」自救入口（清回执 + 清输入态；没有它卡就永久锁死）",
      section.contains("Text(\"重填\")")
      && section.contains("CardFormStore.shared.clear(for: fingerprint)")
      && section.contains("submitted = nil"))
check("④ 重填按钮挂在回执行里（不在只读降级分支，否则等于没入口）",
      { guard let body = closureBody(section, from: "private func receiptView(", to: "private var readOnlyRows") else { return false }
        return body.contains("Text(\"重填\")") }())
check("④ Features/ 下不许出现表单回执键名（单一真源在 Core/CardFormStore.swift）",
      countOf("qingliao_card_form_", in: sectionRaw) == 0)

// MARK: ⑤ 宿主接线（提交走既有 sendCore 全链路，不绕闸门）

check("⑤ ChatView 的提交闭包走 sendCore 全链路", view.contains("} onCardSubmit: { text in")
      && view.contains("sendCore(text: text, imageData: nil)"))
check("⑤ 提交闭包不自己插消息（绕开落库/排队/流式互斥 = 绕过闸门）",
      { () -> Bool in
          guard let body = closureBody(view, from: "} onCardSubmit: { text in", to: "} onProactiveFeedback:") else { return false }
          return !body.contains("append(")
      }())
check("⑤ 卡片段渲染与 kind 无关（靠 form != nil，别再加 .form 门控）",
      card.contains("if let form = card.form {") && !card.contains("card.kind == .form"))
check("⑤ 表单段位置：表格之后、页脚之前（交互控件是卡的收尾动作）",
      (card.range(of: "AgentCardTable(rows: tableRows(table))")?.lowerBound ?? card.endIndex)
      < (card.range(of: "AgentCardFormSection(form: form")?.lowerBound ?? card.startIndex)
      && (card.range(of: "AgentCardFormSection(form: form")?.lowerBound ?? card.endIndex)
      < (card.range(of: "if let footer = card.footer, !footer.isEmpty {")?.lowerBound ?? card.startIndex))

// MARK: ⑥ 参数序（实参序 = 声明序，CI 才报的那类错）

func orderedPair(_ text: String, after: String, before: String, in region: Range<String.Index>? = nil) -> Bool {
    let scope = region.map { String(text[$0]) } ?? text
    guard let a = scope.range(of: after)?.lowerBound,
          let b = scope.range(of: before)?.lowerBound else { return false }
    return a < b
}

/// 两标记之间是否只有空白（注释剥离后注释行变空行）——「紧跟/相邻」类断言唯一可靠写法：
/// 整文件找位置那种写法，把顺序挪了照样绿（实测假绿），必须钉连续性。
func onlyWhitespaceBetween(_ text: String, _ a: String, _ b: String) -> Bool {
    guard let ra = text.range(of: a)?.upperBound,
          let rb = text.range(of: b, range: ra..<text.endIndex)?.lowerBound else { return false }
    return text[ra..<rb].allSatisfy { $0.isWhitespace }
}

/// 取标记之间的片段（nil = 标记缺失 → 调用方必须判失败，不能静默放过）
func closureBody(_ text: String, from: String, to: String) -> String? {
    guard let a = text.range(of: from)?.upperBound,
          let b = text.range(of: to, range: a..<text.endIndex)?.lowerBound else { return nil }
    return String(text[a..<b])
}

/// 统计「first 后面紧跟（中间只有空白）second」出现次数
func occurrencesAdjacent(_ text: String, first: String, second: String) -> Int {
    var count = 0
    var searchStart = text.startIndex
    while let r = text.range(of: first, range: searchStart..<text.endIndex) {
        let after = r.upperBound
        if let r2 = text.range(of: second, range: after..<text.endIndex),
           text[after..<r2.lowerBound].allSatisfy({ $0.isWhitespace }) {
            count += 1
        }
        searchStart = r.upperBound
    }
    return count
}

check("⑥ MessageBubble 声明序：onCardSubmit 紧跟 onContinueStep（中间不许插别的参数）",
      onlyWhitespaceBetween(bubble, "var onContinueStep: ((String) -> Void)? = nil",
                            "var onCardSubmit: ((String) -> Void)? = nil")
      && orderedPair(bubble, after: "var onCardSubmit: ((String) -> Void)? = nil",
                     before: "var onAnswerQuestion: ((String) -> Void)? = nil"))
check("⑥ MessageBubble 两个调用点都把 onCardSubmit 紧跟在 onContinueStep 之后传（实参序 = 声明序）",
      occurrencesAdjacent(bubble, first: "onContinueStep: onContinueStep,", second: "onCardSubmit: onCardSubmit,") == 2)
check("⑥ 消息种子接线：AgentResultCard 声明 cardSeed 紧跟 onCardSubmit（中间不许插别的参数）",
      onlyWhitespaceBetween(card, "var onCardSubmit: ((String) -> Void)? = nil", "var cardSeed: String = \"\"")
      && card.contains("seed: cardSeed, onSubmit: onCardSubmit)"))
check("⑥ ChatComponents 把消息 id 当种子传下去（回执按消息隔离）",
      comps.contains("cardSeed: messageId)"))
check("⑥ ChatComponents 声明 + 透传给 AgentResultCard",
      comps.contains("var onCardSubmit: ((String) -> Void)? = nil")
      && comps.contains("onCardSubmit: onCardSubmit,"))

// MARK: ⑦ 上限保护（一次提交不许塞爆上下文）

check("⑦ 合成文本有长度上限且真的用了",
      parser.contains("static let maxComposedLength = 4000")
      && parser.contains("String(out.prefix(Self.maxComposedLength))"))
check("⑦ 必填校验出口唯一（视图/后续调用方都用它）", parser.contains("func missingRequired(values: [String: String]) -> [String]"))
// render 函数体切片（终点锚必须在 render **之后**：Form 段里 render 在 compose 之前、missingRequired 之后
// → 锚成 missingRequired 会返回 nil，下方 !contains 恒真 = 假绿，是独立复查抓到的）
let renderBody = closureBody(parser, from: "static func render(template: String", to: "func compose(values:") ?? ""
check("⑦ 单遍渲染哨兵：切片必须真取到内容（取不到 = 下一条恒真）", !renderBody.isEmpty)
check("⑦ render 本体不得用逐字段替换（串味写法）", !renderBody.contains("replacingOccurrences"))
// ⚠️ 承重断言在**调用侧**：光查 render 函数体是瞄错目标 —— 把 compose 换回逐字段替换、
// render 原样留着，整表照样全绿（变异实测）。必须钉 compose 委托 render。
check("⑦ compose 必须委托单遍渲染（换回逐字段替换 = 串味回归）",
      parser.contains("                out = Self.render(template: template, fields: fields, values: values)"))
check("⑦ 字段 key 去重（ForEach(id: \\.key) 重复 id 是未定义行为）",
      parser.contains("if seen.contains(key)") && parser.contains("seen.insert(key)"))
check("⑦ 内容签名随字段结构变（label/单位/选项/模板都参与）",
      parser.contains("var signature: String")
      && parser.contains("f.options.joined(separator: \",\")")
      && parser.contains("parts.append(template ?? \"\")"))

print("可交互表单卡真值表：#25 \(passCount) 通过 / \(failCount) 失败")
exit(failCount == 0 ? 0 : 1)
