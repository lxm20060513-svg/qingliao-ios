// MARK: - v4.0.44 待做池 3「改口重答」真值表（编辑已发消息 → 旧回答折叠「已修改」+ 重答）
//
// 用户 2026-10-04 卡片拍板（两项都选 1）：
//   ① 被取代的旧回答 → 复用现有灰气泡（与「撤回」同款，最省事）
//   ② 只允许改**最后一条** user 消息（改动面最小）
//
// 本表钉四件事：
//   ① MessageEditKit 纯逻辑真编译真跑（能改哪条 / 折叠哪几条）—— 改口径必红
//   ② iOS 侧接线（判定与折叠真的接进 UI/Store，而不是只定义没人用）
//   ③ 护栏②③④⑥（失败回退不留白 / 折叠不进上下文 / AI 菜单没有编辑 / edited 不复用 withdrawn）
//   ④ 折叠的语义边界：只 flip 标记、**不清正文**（原文要留给回退/导出/分享）
//
// 编译方式（多文件 → 必须 @main，与 ql_bill / ql_suggest 同口径）：
//   与本表一起编 qingliao/Core/MessageEditKit.swift（该文件只依赖 Foundation）。
//   入口：check_swift.sh 第 70 段。

import Foundation

nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0

func ok(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("  ✅ \(name)") } else { fail += 1; print("  ❌ \(name)") }
}

let repo = ProcessInfo.processInfo.environment["QL_REPO"] ?? "."
func read(_ rel: String) -> String {
    (try? String(contentsOfFile: repo + "/" + rel, encoding: .utf8)) ?? ""
}
/// 去行注释：注释里提到旧口径不算数（防「代码改坏但注释还对」的假通过）
func code(_ rel: String) -> String {
    read(rel).split(separator: "\n").map { line -> String in
        guard let r = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<r.lowerBound])
    }.joined(separator: "\n")
}
/// 取某函数体片段（从 from 起、到 to 止的近似切片）
func body(_ src: String, from: String, to: String) -> String {
    guard let a = src.range(of: from) else { return "" }
    let rest = src[a.lowerBound...]
    guard let b = rest.range(of: to) else { return String(rest) }
    return String(rest[rest.startIndex..<b.lowerBound])
}
func row(_ role: String, withdrawn: Bool = false, failed: Bool = false,
         isPush: Bool = false, isQuestion: Bool = false, edited: Bool = false,
         queued: Bool = false) -> MessageEditKit.Row {
    MessageEditKit.Row(role: role, withdrawn: withdrawn, failed: failed,
                       isPush: isPush, isQuestion: isQuestion, edited: edited, queued: queued)
}

@main
struct EditMsgTruthTable {
    static func main() {
        logicEditableIndex()
        logicFoldTargets()
        wiringModels()
        wiringChatStore()
        wiringBubbleAndMenu()
        wiringChatView()
        wiringExport()

        print("\n改口重答真值表：\(pass) 通过 / \(fail) 失败")
        exit(fail == 0 ? 0 : 1)
    }

    // MARK: - ① 纯逻辑：能改哪条（用户拍板②：只允许最后一条 user 消息）

    static func logicEditableIndex() {
        print("── ① 纯逻辑：editableIndex（只允许最后一条 user 消息）──")

        ok(MessageEditKit.editedLabel == "已修改", "折叠文案 = 「已修改」（与撤回区分）")
        ok(MessageEditKit.editableIndex([]) == nil, "空列表 → 无可改")
        ok(MessageEditKit.editableIndex([row("assistant")]) == nil, "只有 AI 回答 → 无可改")
        ok(MessageEditKit.editableIndex([row("user"), row("assistant")]) == 0, "单轮 user → 可改")
        ok(MessageEditKit.editableIndex([row("user"), row("assistant"), row("user"), row("assistant")]) == 2,
           "多轮：改的是**最后一条** user（下标 2），不是第一条")
        ok(MessageEditKit.editableIndex([row("user"), row("assistant"), row("user")]) == 2,
           "最后一条 user 还没回答 → 也能改")
        ok(MessageEditKit.editableIndex([row("user"), row("assistant"), row("user", failed: true)]) == nil,
           "发送失败的那条 → 入口是「重试」不是「编辑」")
        ok(MessageEditKit.editableIndex([row("user"), row("assistant"), row("user", withdrawn: true)]) == nil,
           "已撤回 → 不可改（正文已不存在）")
        ok(MessageEditKit.editableIndex([row("user"), row("assistant"), row("user", isPush: true)]) == nil,
           "推送消息冒充 user → 不可改")
        ok(MessageEditKit.editableIndex([row("user"), row("assistant"), row("user", isQuestion: true)]) == nil,
           "问题卡 → 不可改")
        ok(MessageEditKit.editableIndex([row("user"), row("assistant"), row("user", edited: true)]) == nil,
           "已折叠 → 不可改（自己已是陈列态）")
        // v4.0.47 复审补：排队中（AI 回答时发的、还没真发出去）不能改 —— 改了口令队列里仍是旧文，
        // sendQueued 按 content == item.text 匹配不到 → 那条排队消息被静默丢弃。
        ok(MessageEditKit.editableIndex([row("user"), row("assistant"), row("user", queued: true)]) == nil,
           "排队中 → 不可改（否则编辑会把排队消息静默丢掉）")
    }

    // MARK: - ② 纯逻辑：折叠哪几条（锚点之后、assistant、非推送/非问题卡/未折叠/未撤回）

    static func logicFoldTargets() {
        print("── ② 纯逻辑：foldTargets ──")

        ok(MessageEditKit.foldTargets([row("user"), row("assistant")], afterUserIndex: 0) == [1],
           "该轮旧回答 → 折叠")
        ok(MessageEditKit.foldTargets([row("user")], afterUserIndex: 0) == [],
           "还没回答 → 没有可折叠的")
        ok(MessageEditKit.foldTargets([row("user"), row("assistant"), row("assistant")], afterUserIndex: 0) == [1, 2],
           "同轮多条旧回答 → 全折叠")
        ok(MessageEditKit.foldTargets([row("user"), row("assistant", isPush: true)], afterUserIndex: 0) == [],
           "推送不进折叠（不是「一条被取代的回答」）")
        ok(MessageEditKit.foldTargets([row("user"), row("assistant", isQuestion: true)], afterUserIndex: 0) == [],
           "问题卡不折叠（折叠掉 = 用户答不了、后端干等超时）")
        ok(MessageEditKit.foldTargets([row("user"), row("assistant", edited: true)], afterUserIndex: 0) == [],
           "已折叠的不重复折叠（幂等）")
        ok(MessageEditKit.foldTargets([row("user"), row("assistant", withdrawn: true)], afterUserIndex: 0) == [],
           "已撤回的不折叠（语义已终态）")
        ok(MessageEditKit.foldTargets([row("user"), row("assistant"), row("assistant", isPush: true), row("assistant")],
                                      afterUserIndex: 0) == [1, 3],
           "推送夹在中间：只折叠两边的回答")
        ok(MessageEditKit.foldTargets([row("user"), row("assistant"), row("user"), row("assistant")],
                                      afterUserIndex: 2) == [3],
           "只折叠锚点**之后**的（历史轮次不动）")
        ok(MessageEditKit.foldTargets([row("user"), row("assistant")], afterUserIndex: 1) == [],
           "锚点不是 user 消息 → 不折叠（判据不成立就别动）")
        ok(MessageEditKit.foldTargets([row("user"), row("assistant")], afterUserIndex: 9) == [],
           "越界下标 → 不折叠（不崩）")
    }

    // MARK: - ③ 源级接线（剥注释后按代码形态断言）

    static func wiringModels() {
        print("── ③ 源级接线：模型层 ──")

        let models = code("qingliao/Core/Models.swift")
        ok(models.contains("var edited: Bool = false"), "ChatMessage 有独立字段 edited")
        ok(models.contains("var withdrawn: Bool = false") && models.contains("var edited: Bool = false"),
           "护栏⑥：edited 与 withdrawn 是**两个独立字段**（没有复用同一标记）")
        ok(models.contains("msg.edited = d[\"edited\"] as? Bool ?? false"), "持久化读回 edited（重启后仍是已修改）")
        ok(models.contains("var content: String"), "content 由 let 改 var（改口要就地换原文）")
    }

    static func wiringChatStore() {
        print("── ③ 源级接线：ChatStore（口径 / 上下文 / 落库 / 查重）──")

        let cs = code("qingliao/Core/ChatStore.swift")
        ok(cs.contains("var editRows: [MessageEditKit.Row]"), "editRows：ChatMessage → 纯逻辑判定输入")
        ok(cs.contains("var editableUserMessageID: String?"), "editableUserMessageID（UI 显隐的唯一真源）")
        ok(cs.contains("MessageEditKit.editableIndex(messages[i...].map(Self.editRow)) == 0"),
           "可改判定走纯逻辑层（不自己写一份）")
        // v4.0.47 复审：本属性被**每个气泡**各问一次 → 不许每次 map 全表（长会话 + 流式重绘 = O(n²)）。
        // 口径仍归 MessageEditKit，只是把「最后一条 user 起」的尾巴喂进去（结论等价，见源码注释）。
        ok(cs.contains("messages.lastIndex(where: { $0.role == \"user\" })"),
           "🔑 可改判定从尾部切片（不再每次 map 全表，防 O(n²)）")
        ok(cs.contains("queued: m.queued"), "Row 带上 queued（排队消息不可改的口径有真值来源）")
        ok(cs.contains("func updateUserText(id: String, newText: String) -> Bool"), "updateUserText：就地换原文")
        ok(cs.contains("func foldRepliesAfterUser(_ anchorID: String) -> [ChatMessage]"), "foldRepliesAfterUser")
        ok(cs.contains("func unfoldReplies(_ snapshots: [ChatMessage])"), "unfoldReplies：失败回退")
        ok(cs.contains("MessageEditKit.foldTargets(editRows, afterUserIndex: a)"), "折叠范围走纯逻辑层")
        // 护栏③：折叠态不进模型上下文
        ok(cs.contains("!$0.isPush && !$0.isErrorPlaceholder && !$0.withdrawn && !$0.edited"),
           "护栏③：historyPayload 把 edited 挡在模型上下文之外")
        // 落库：标记要写、正文要留（与撤回刻意不同）
        ok(cs.contains("if m.edited { p[\"edited\"] = true }"), "落库写 edited 标记")
        // 切片到下一个真实声明（不能用注释当界标：code() 已剥注释）
        let foldBody = body(cs, from: "func foldRepliesAfterUser", to: "func unfoldReplies(_ snapshots")
        ok(foldBody.contains(".edited = true"), "折叠就是置 edited")
        ok(!foldBody.contains(".content =") && !foldBody.contains("content = \"\""),
           "护栏①：折叠**不清正文**（原文留给回退/导出/分享）")
        ok(foldBody.contains("snap.append(messages[i])"), "护栏②：先存快照再翻标记（回退取的是原样）")
        if let snapAt = foldBody.range(of: "snap.append(messages[i])"), let flagAt = foldBody.range(of: ".edited = true") {
            ok(snapAt.lowerBound < flagAt.lowerBound, "护栏②：快照必须在翻标记**之前**（顺序反了 = 回退回折叠态）")
        } else {
            ok(false, "护栏②：折叠体里应当同时有快照与翻标记")
        }
        ok(foldBody.contains("suggestions = nil"), "旧候选区随旧回答一起收走")
        // 查重：折叠态是历史陈列物，不参与任何查重（否则「改了错别字→同款回答」会被整条吞掉）
        ok(cs.contains("$0.role == \"assistant\" && !$0.edited && $0.content == text"), "全历史查重跳过折叠态")
        ok(cs.contains("!messages[regionEnd - 1].edited"), "同轮区域查重跳过折叠态")
        ok(cs.contains("isAssistantDuplicate(text, in: region.filter { !$0.edited })"), "相似度兜底跳过折叠态")
        ok(cs.contains("let tail = messages.filter { !$0.edited }.suffix(8)"), "尾窗查重跳过折叠态")
    }

    static func wiringBubbleAndMenu() {
        print("── ③ 源级接线：气泡 / 菜单 ──")

        let mb = code("qingliao/Features/Chat/ChatMessageBubble.swift")
        ok(mb.contains("if message.edited {"), "气泡有折叠态早退分支")
        ok(mb.contains("editedBubbleBody"), "折叠态独立渲染（不塞进 normalBubbleBody）")
        ok(mb.contains("Text(MessageEditKit.editedLabel)"), "折叠气泡文案走纯逻辑常量（与导出/分享同源）")
        ok(mb.contains("var onEdit: (() -> Void)? = nil"), "MessageBubble 有 onEdit（nil = 菜单没「编辑」）")
        ok(mb.contains("onEdit: onEdit,"), "onEdit 传给 SelectableTextLabel（文字气泡的长按菜单）")

        let stl = code("qingliao/Features/Chat/SelectableTextLabel.swift")
        ok(stl.contains("var onEdit: (() -> Void)? = nil"), "SelectableTextLabel 有 onEdit")
        ok(stl.contains("if let onEdit = parent.onEdit"), "护栏④：编辑入口由 onEdit 门控（assistant 侧不传 = 没这一项）")
        ok(stl.contains("title: \"编辑\"") && stl.contains("pencil"), "菜单项「编辑」+ 铅笔图标")
        ok(stl.contains("title: \"撤回\""), "撤回入口在（没被本次改动误伤）")
        ok(!code("qingliao/Features/Chat/ChatComponents.swift").contains("\"编辑\""),
           "护栏④：AI 侧菜单常量（ChatComponents）没有「编辑」")
    }

    static func wiringChatView() {
        print("── ③ 源级接线：ChatView（入口 / 重答 / 失败回退 / 面板）──")

        let cv = code("qingliao/Features/Chat/ChatView.swift")
        ok(cv.contains("func editAction(_ msg: ChatMessage) -> (() -> Void)?"), "editAction：入口显隐")
        ok(cv.contains("chat.editableUserMessageID == msg.id"), "护栏：入口按「最后一条 user」判定（与 Store 同源）")
        // v4.0.47 复审（阻断①）：入口原用按会话收窄的 thisSessionStreaming，执行端 editMessage 用
        // **全局** stream.isStreaming —— 多会话并行时别的会话在跑流，本会话菜单照样显示「编辑」，
        // 点完 editMessage 静默 return（消息没改也没提示）。本文件 286-292 明文规定：凡「单例是否
        // 被占用」的护栏一律用全局判据，绝不能换成按会话收窄的那个。
        ok(cv.contains("guard !stream.isStreaming, chat.editableUserMessageID == msg.id else { return nil }"),
           "🔑 编辑入口用**全局**流判据（与执行端同源，防「菜单有编辑、点了没反应」）")
        ok(!cv.contains("!thisSessionStreaming, chat.editableUserMessageID"),
           "旧「按会话收窄」写法清零（改回即红）")
        ok(cv.contains("onEdit: editAction(msg)"), "接线：气泡括号实参传 onEdit（nil = 不显示）")
        ok(cv.contains("func editMessage(_ msg: ChatMessage, newText: String)"), "editMessage：改口重答主流程")
        ok(cv.contains("MessageEditKit.editableIndex(chat.editRows) == idx"), "主流程再兜一层「只允许最后一条」")
        ok(cv.contains("chat.updateUserText(id: msg.id, newText: text)"), "换原文")
        ok(cv.contains("let anchorID = chat.messages[idx].id"), "护栏：改完**重取 id**（content 参与 id 计算）")
        ok(cv.contains("let folded = chat.foldRepliesAfterUser(anchorID)"), "折叠旧回答（拿快照）")
        ok(cv.contains("chat.unfoldReplies(folded)"), "护栏②：失败路径还原旧回答（不留白）")
        ok(cv.contains("stream.pendingUserMsgId = anchorID"), "杀后台恢复的锚点接上")
        ok(cv.contains("landAwayReply(body, agent: stream.isAgent, snapshot: snap"), "切走会话落回发起时的会话")
        ok(cv.contains("if let i = snap.firstIndex(where: { $0.id == f.id }) { snap[i] = f }"),
           "切走 + 失败：快照里的折叠态也还原（否则那会话留一条「已修改」没收尾）")
        ok(cv.contains("MessageEditSheet(originalText: m.content)"), "改口面板接线")
        ok(cv.contains(".sheet(item: $editingMessage)"), "面板宿主")
        // v4.0.47 复审（阻断②）：失败只还原旧答 → 落成「新文 + 旧答」＝ 用新问题配旧答案。
        // 口径：失败要连**用户原文**一起还原（同会话分支 + 切走会话分支各一处）。
        ok(cv.contains("let originalText = chat.messages[idx].content"), "回退前先留底原文")
        ok(cv.contains("chat.updateUserText(id: anchorID, newText: originalText)"),
           "🔑 失败连用户原文一起还原（不留答非所问的幽灵态）")
        ok(cv.contains("if let i = snap.firstIndex(where: { $0.id == anchorID }) { snap[i] = msg }"),
           "🔑 切走会话分支：快照里的用户原文同口径回滚")
        // v4.0.47 复审（次要③）：编辑要**立刻落盘** —— 否则杀后台窗口内编辑丢失，而恢复锚点已是新 id，
        // 服务端旧文 + 新锚点 → 恢复时锚点失配、旧文配新答。与 sendCore 同口径。
        ok(cv.contains("Task { await chat.saveToServer(auth: auth) }"), "编辑立刻落盘")
        ok(cv.contains("editFailedAlert"), "失败出声（告警条）")

        let sheet = code("qingliao/Features/Chat/MessageEditSheet.swift")
        ok(sheet.contains("var onSubmit: (String) -> Void"), "面板只回传新原文（判定不在这里）")
        ok(sheet.contains("disabled(!canSubmit)"), "原文没改/为空 → 保存按钮置灰")
        ok(sheet.contains("placement: .cancellationAction"), "弹窗胶囊左位（全站口径）")
    }

    static func wiringExport() {
        print("── ③ 源级接线：分享 / 导出（折叠态不许漏原文）──")

        ok(code("qingliao/Features/Chat/ChatViewExport.swift")
            .contains("if msg.edited { return (msg.role, MessageEditKit.editedLabel) }"),
           "分享卡片：折叠态用「已修改」占位（不漏已被改掉的旧原文）")
        ok(code("qingliao/Features/Chat/ChatComponents.swift").contains("m.edited ? MessageEditKit.editedLabel"),
           "HTML 导出：同上")
    }
}
