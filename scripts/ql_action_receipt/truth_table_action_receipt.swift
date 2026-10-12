// MARK: - v4.0.100 动作卡「执行回执」真值表
//
// 用户原话（2026-10-12）：*「已经执行完的动作卡，下次打开还是显示未执行的状态」*。
//
// 根因：`AgentActionCard` 的执行态只是**视图级 `@State phase`** —— 重启 / 切会话 /
//       消息重建全丢，卡片回落成 `.idle`。后果分两档：
//         · 只读卡：每次重进会话都重跑一遍（白跑 + 结果闪一下）
//         · **写 / 删卡：「执行」胶囊重新长出来，用户再点一次就是第二个日程 / 第二个目标**
//           （文件头那句「用户狂点会建出三个事件 —— 这真会发生」）
//
// 口径（落库 = `ChatMessage.actionOutcomes`，键 = `AgentAction.stateKey`）：
//   ① 成功 → 落回执，重启后回到终态
//   ② 失败 → **不落**（失败是「这次没成」不是「这件事做过了」；冻住 = 授权后再也点不动）
//   ③ 撤销 → **抹掉**（撤销 = 这件事没有发生；留着会被一条「已执行」冻住，而用户按撤销正是想重来）
//   ④ **只读卡不落回执**（v4.0.100 审查补）—— 回执 =「副作用已经发生过了」的凭证，只读卡没有副作用；
//      而它的结果常带时效（「今天 14:00 有空」），冻住会让隔天翻到这条消息时卡上还写着「今天」。
//   ⑤ **流式临时气泡里的卡不给可点胶囊**（同一 bug 的流式版本）—— 那条消息每帧新建、不在
//      `store.messages` 里，回执按 messageId 找不到宿主 → 点下去静默失败、落地后胶囊重生、再点就是第二个日程。
//
// 本表钉：① `stateKey` 真的稳定（编进来的是**生产源码**，不是镜像实现）
//        ② 落库链路两端都在  ③ 三条口径的反例（尤其「失败也落回执」这种一眼看不出的错）
//
// ⚠️ 编法（多文件时顶层代码必须收进 @main，见 test_agent_action.swift 同款）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/tt_ar qingliao/Core/AgentAction.swift \
//       scripts/shims/AppCapabilityShim.swift scripts/ql_action_receipt/truth_table_action_receipt.swift

import Foundation

nonisolated(unsafe) var pass = 0, fail = 0
func ok(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("  ✅ \(name)") } else { fail += 1; print("  ❌ \(name)") }
}

let repo = ProcessInfo.processInfo.environment["QL_REPO"] ?? "."
func read(_ rel: String) -> String {
    (try? String(contentsOfFile: repo + "/" + rel, encoding: .utf8)) ?? ""
}
/// 去注释：注释里提到旧口径不算数（防「改了代码但注释还对」的假通过）
func code(_ rel: String) -> String {
    read(rel).split(separator: "\n").map { line -> String in
        guard let r = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<r.lowerBound])
    }.joined(separator: "\n")
}
/// 取 [from, to) 之间的片段（找不到任一端 = 空串，断言自然判红）
func slice(_ s: String, _ from: String, _ to: String) -> String {
    guard let a = s.range(of: from),
          let b = s.range(of: to, range: a.upperBound..<s.endIndex) else { return "" }
    return String(s[a.lowerBound..<b.lowerBound])
}
func count(_ s: String, _ needle: String) -> Int {
    s.components(separatedBy: needle).count - 1
}

@main
struct QLActionReceiptMain {
    static func main() {
        let actionCode = code("qingliao/Core/AgentAction.swift")
        let modelCode  = code("qingliao/Core/Models.swift")
        let storeCode  = code("qingliao/Core/ChatStore.swift")
        let cardCode   = code("qingliao/Features/Chat/AgentActionCard.swift")
        let compCode   = code("qingliao/Features/Chat/ChatComponents.swift")
        let bubbleCode = code("qingliao/Features/Chat/ChatMessageBubble.swift")
        let rawCard    = read("qingliao/Features/Chat/AgentActionCard.swift")

        // ── ① stateKey：真跑（编进来的就是生产源码）───────────────────────────
        print("── ① stateKey 稳定性（真跑生产代码）──")

        func act(_ json: String) -> AgentAction? { AgentAction.parse(json: json) }

        let a1 = act(#"{"action":"calendar.create","params":{"title":"开会","start":"2026-10-13T09:00:00Z"},"summary":"新建日历事件「开会」"}"#)
        let a2 = act(#"{"action":"calendar.create","params":{"start":"2026-10-13T09:00:00Z","title":"开会"},"summary":"完全换一句措辞"}"#)
        let a3 = act(#"{"action":"calendar.create","params":{"title":"开会","start":"2026-10-13T10:00:00Z"},"summary":"新建日历事件「开会」"}"#)
        let a4 = act(#"{"action":"reminder.create","params":{"title":"开会","start":"2026-10-13T09:00:00Z"}}"#)

        ok(a1 != nil && a2 != nil && a3 != nil && a4 != nil, "四份 JSON 都能解析成动作（前提没塌）")
        if let a1, let a2, let a3, let a4 {
            ok(a1.stateKey == a2.stateKey, "同参**键序不同** + summary 换措辞 → 同一个键（回执才挂得住）")
            ok(a1.stateKey != a3.stateKey, "参数值变了 → 换键（换了个时间就是另一个动作）")
            ok(a1.stateKey != a4.stateKey, "动作名不同 → 换键")
            ok(a1.stateKey.hasPrefix("calendar.create#"), "键带动作名前缀（日志里一眼看出是哪张卡）")
        }
        // 确定性：同输入跑两遍必须同键（防哪天有人换成 hashValue —— 那个带进程随机种子，跨启动会漂）
        let k1 = act(#"{"action":"file.write","params":{"path":"a.txt"}}"#)?.stateKey ?? "x"
        let k2 = act(#"{"action":"file.write","params":{"path":"a.txt"}}"#)?.stateKey ?? "y"
        ok(k1 == k2, "同输入两次解析 → 同键（跨启动稳定，不依赖 String.hashValue）")

        ok(actionCode.contains("struct AgentActionOutcome"), "回执结构 AgentActionOutcome 存在（纯 Foundation，可单测）")
        ok(actionCode.contains("var stateKey: String"), "stateKey 定义在 AgentAction 上（卡与 store 共用一处真源）")

        // ── ② 落库链路：写端 + 读端 + 就地改 ────────────────────────────────
        print("── ② 落库链路两端都在 ──")

        ok(modelCode.contains("var actionOutcomes: [String: AgentActionOutcome]?"),
           "ChatMessage 带上回执字段（真源跟着消息走，不另起旁表）")
        ok(modelCode.contains("d[\"actionOutcomes\"] as? [String: [String: Any]]"),
           "parse 读回（重启 / 切会话后认得出）")
        ok(modelCode.contains("msg.actionOutcomes = ao.isEmpty ? nil : ao"),
           "空回执归一成 nil（别留一个空字典当真值）")
        ok(storeCode.contains("p[\"actionOutcomes\"] = ao.mapValues"),
           "messagesPayload 把回执写进落库 payload")

        ok(storeCode.contains("func actionOutcome(messageId: String, key: String) -> AgentActionOutcome?"),
           "store 有读回执入口（卡片 seed 用它）")
        ok(storeCode.contains("func markActionOutcome(messageId: String, key: String, outcome: AgentActionOutcome) -> Bool"),
           "store 有写回执入口")
        ok(storeCode.contains("func clearActionOutcome(messageId: String, key: String) -> Bool"),
           "store 有抹回执入口（撤销用）")
        ok(slice(storeCode, "func markActionOutcome", "func clearActionOutcome").contains("messageRev &+= 1"),
           "写回执喊聊天页重建（就地改字段、count 不变 —— 少这句卡面不刷新）")

        ok(compCode.contains("AgentActionCard(action: action, messageId: messageId, streamingHost: streamingHost)"),
           "ChatComponents 把所属消息 id + 流式标记传给动作卡（否则回执无处可写 / 流式点下去静默失败）")
        ok(count(bubbleCode, "messageId: message.id") == 2,
           "气泡两条渲染路径（单段落 / 多气泡逐段）**都**传了 messageId，实得 \(count(bubbleCode, "messageId: message.id"))")
        ok(count(bubbleCode, "streamingHost:") == 2,
           "两条渲染路径**都**传了 streamingHost（单段落 streamingText / 逐段 streaming），实得 \(count(bubbleCode, "streamingHost:"))")
        ok(compCode.contains("var streamingHost = false"),
           "MessageBlockView 带 streamingHost 参数（流式临时气泡 = 动作卡没有归宿）")
        ok(cardCode.contains("@Environment(ChatStore.self) private var store"),
           "卡片自己取 store（真源在会话里，不在视图生命周期里）")

        // ── ③ 三条口径 + 反例 ───────────────────────────────────────────────
        print("── ③ 口径与反例 ──")

        let beforeAuto = slice(cardCode, ".task {", "if autoRuns { await execute() }")
        ok(beforeAuto.contains("storedOutcome"), "🚫 .task **先认回执**再决定跑不跑（顺序反了 = 先跑一遍再把结果盖掉）")
        ok(beforeAuto.contains("guard !streamingHost else { return }"),
           "🚫 流式临时气泡里的卡不动作（回执无处可落：点下去静默失败、落地后胶囊重生）")
        let iStream = beforeAuto.range(of: "guard !streamingHost")?.lowerBound
        let iStored = beforeAuto.range(of: "storedOutcome")?.lowerBound
        ok(iStream != nil && iStored != nil && iStream! < iStored!,
           "🚫 流式早退必须排在**认回执之前**（顺序反了会先认一个不存在的回执）")
        ok(beforeAuto.contains("applyStored(") && beforeAuto.contains("return"),
           "🚫 认到回执就回到终态并 return（不许落到自动跑）")
        ok(rawCard.contains("storedOutcome"), "认回执的入口名留给后人搜得到")

        let failedBranch = slice(cardCode, "case .failed(let msg):", "private var storedOutcome")
        ok(!failedBranch.isEmpty, "取到 execute() 的失败分支")
        ok(failedBranch.contains("phase = .failed(msg)"), "失败仍然出声（红字留在卡上）")
        ok(!failedBranch.contains("persist("), "🚫 失败分支**不落回执**（失败=这次没成；冻住=授权后点不动，回到未执行才是重试入口）")

        let undoBranch = slice(cardCode, "await u()", "Haptics.success()")
        ok(undoBranch.contains("forgetOutcome()"), "🚫 撤销要**抹掉**回执（撤销=这件事没有发生，留着会被「已执行」冻住）")

        ok(cardCode.contains("guard case .idle = phase else { return }"),
           "防重复执行的老闸门还在（本轮没动它）")
        ok(cardCode.contains("markActionOutcome") && cardCode.contains("saveToServer"),
           "成功分支写回执 + 落库都要（只写内存 = 重启又回未执行，正是用户报的 bug）")

        let persistBody = slice(cardCode, "private func persist", "Task { await store.saveToServer")
        ok(!persistBody.isEmpty, "取到 persist 函数体")
        ok(persistBody.contains("guard !autoRuns else { return }"),
           "🚫 只读卡不落回执（回执 = 副作用已发生的凭证；只读结果带时效，冻住会让「今天」永远停在昨天）")
        ok(persistBody.contains("markActionOutcome") && persistBody.contains("!messageId.isEmpty"),
           "写/删卡的成功回执照旧落库（本批没动这条主路径）")

        ok(cardCode.contains("case .idle where streamingHost:"),
           "🚫 流式期间不给可点胶囊（走的是等待分支，不是「执行」按钮）")
        let streamBranch = slice(cardCode, "case .idle where streamingHost:", "case .idle where autoRuns:")
        ok(!streamBranch.isEmpty && streamBranch.contains("回复生成中"),
           "🚫 流式分支画的确实是等待文案，不是执行按钮")
        ok(!streamBranch.contains("Button"),
           "🚫 流式分支里**不许有 Button**（有 = 又能点 = 回执静默失败、再点就是第二个日程）")

        ok(storeCode.contains("guard ao[key] != outcome else { return true }"),
           "🚫 markActionOutcome 同值也返回 true：false 只留给「消息不在 store」—— 否则内存有回执、后端什么都没有，再无补写机会")
        ok(actionCode.contains(".utf8.count):"),
           "🚫 stateKey 用长度前缀编码（`k=v&` 拼接会被值里的 = / & 注成同一个键）")

        let hist = slice(storeCode, "func historyPayload", "\n    func ")
        ok(!hist.isEmpty, "取到 historyPayload")
        ok(!hist.contains("actionOutcomes"), "🚫 回执不许进模型上下文（进了就是复读源 / 白烧 token）")
        ok(count(storeCode, "\"actionOutcomes\"") == 1,
           "回执只在一处落库（messagesPayload），别处不许再复制一份，实得 \(count(storeCode, "\"actionOutcomes\""))")

        // id 不含回执 —— 进了 id，每执行一次都换 id（插入动画重播 / 行身份漂移 / 去重错乱）
        let idBody = slice(modelCode, "var id: String {", "var isUser: Bool")
        ok(!idBody.contains("actionOutcomes"), "🚫 actionOutcomes 不许进 ChatMessage.id（同 suggestions 的教训）")

        print("\n动作卡执行回执真值表：\(pass) 通过 / \(fail) 失败")
        exit(fail == 0 ? 0 : 1)
    }
}
