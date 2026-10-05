// MARK: - v4.0.56「AI 回复双投」根治 · 真值表（源护栏 + 谓词镜像 + 事故反向自证）
//
// 事故实据（2026-10-05，NAS 会话库 + 收件箱归档 + 后端 body_dump 三处对齐）：
//   同一句回复在同一会话里落了两条，相隔 107ms：
//     [3] ts=…042269.904  agent:true                     ← 后台流式落地（BackgroundStreamRunner）
//     [4] ts=…042376.582  isPush:true, pushKind:"reply"  ← 收件箱推送注入（landPushInOwnedSession）
//   两条 content md5 完全相同；推送原文与会话正文压空白后 296==296 逐字相等 →
//   **不是模型复读、也不是生成两次**（body_dump 该轮只有一次模型调用）＝ 同一个回复被追加了两遍。
//   机理：去重判定读#1（链外快照）与写入读#2（链内重读）是**两份不同新鲜度的数据**；
//   两次读之间后台落地把回复写进同一会话 → 读#2 已含它，却仍然无条件 `msgs.append(msg)`。
//
// 只读审查（2026-10-05，两路独立）补充抓到的洞：链内复检若用「整串精确 ==」，多段回复必失配 ——
//   后端推送正文是 `re.sub(r"\s+"," ")` 压过空白的**单行摘要**（换行变空格），落库正文保留换行。
//   本表 ⑤b / ⑦ 就是为这一格立的桩。
//
// 护栏五件事：
//   1. 落库侧口径唯一：`hasSameAssistantContent` 一份规则（规范化后相等/互为前缀，>30 字，不看 isPush）；
//   2. 推送侧口径唯一：`isDuplicateReply` 直接委托 `InboxDedup.shouldSkip`，不另写一份；
//   3. 注入侧总判据 `isReplyAlreadyInSession` = 上面两道取并集（补「已有推送副本」这一格）；
//   4. 判定数据 = 写入数据：归属写入链内复检必须存在，且必须排在 `msgs.append(msg)` **之前**；
//   5. 反向自证：删掉链内复检 / 注入改回裸 append / 判据退回整串精确相等 → 对应断言必须转红。

import Foundation

var passCount = 0
var failCount = 0
@MainActor func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

let root = ProcessInfo.processInfo.environment["QL_REPO"] ?? "."
func src(_ path: String) -> String {
    guard let s = try? String(contentsOfFile: "\(root)/qingliao/\(path)", encoding: .utf8) else { return "" }
    return s
}
/// 去注释行：负断言必须走它，否则「讲清旧形态」的注释会把断言染红（本仓已踩）
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

let chatRaw = src("Core/ChatStore.swift")
let chat = stripCommentLines(chatRaw)
let inboxRaw = src("Core/InboxStore.swift")
let inbox = stripCommentLines(inboxRaw)
check("前置：两份源都读到了（路径/QL_REPO 对不对）", !chat.isEmpty && !inbox.isEmpty)

// ── ① 落库侧口径（hasSameAssistantContent）：一份规则，规范化后比对 ──
check("① 落库侧口径 hasSameAssistantContent 存在",
      chat.contains("static func hasSameAssistantContent("))
check("① 口径含长度门槛 >30（短回复不同轮可合法同文，v3.4.25）",
      chat.contains("guard core.count > 30 else { return false }"))
check("① 口径排除折叠态 edited（v4.0.44：折叠的旧回答是历史陈列物）",
      chat.contains("!m.edited"))
check("① 口径两侧都走规范化 normalizeForDedup（剥 … + 压空白）",
      chat.contains("static func normalizeForDedup(")
        && chat.contains("let core = normalizeForDedup(text)")
        && chat.contains("let other = normalizeForDedup(m.content)"))
check("① 口径只认「相等」或「新文本是已有文本的前缀」，不认泛包含 / 不认反向前缀（防吞掉更长的答复）",
      chat.contains("other == core || other.hasPrefix(core)")
        && !chat.contains("core.hasPrefix(other)")
        && !chat.contains("other.contains(core)"))
check("① 落库侧 upsertAssistant 复用同一口径",
      chat.contains("Self.hasSameAssistantContent(text, in: messages)"))
check("① 负断言：落库侧不再留 inline 版全历史查重（两份规则＝早晚漂移）",
      !chat.contains("messages.contains(where: { $0.role == \"assistant\" && !$0.edited && $0.content == text })"))
check("① 备注：尾窗/连续同文那条老规则（tail.dropLast 最近 5 条）保持原样，与全历史口径是两件事",
      chat.contains("let hasDuplicateInTail = tail.dropLast().contains"))

// ── ①b 推送侧口径：直接委托 InboxDedup.shouldSkip，不另写一份 ──
check("①b 推送侧口径 isDuplicateReply 委托 InboxDedup.shouldSkip",
      chat.contains("static func isDuplicateReply(")
        && chat.contains("InboxDedup.shouldSkip(push: text, in: msgs)"))
check("①b 负断言：推送侧口径不再自己写一套「压空白 + 包含」判据（避免与 shouldSkip 漂移）",
      !chat.contains("if cm.contains(core)"))

// ── ①c 注入侧总判据 = 推送口径 ∪ 严格口径（补「已有推送副本」这一格）──
func unionHolds(_ chatSrc: String) -> Bool {
    guard let r = chatSrc.range(of: "static func isReplyAlreadyInSession(") else { return false }
    let body = String(chatSrc[r.lowerBound...].prefix(300))
    return body.contains("isDuplicateReply(text, in: msgs) || hasSameAssistantContent(text, in: msgs)")
}
check("①c 总判据 isReplyAlreadyInSession = isDuplicateReply ∪ hasSameAssistantContent", unionHolds(chat))

// ── ② 判定数据 = 写入数据（链内复检，且必须在 append 之前）──
func chainGateHolds(_ chatSrc: String) -> Bool {
    guard let r = chatSrc.range(of: "func appendMessageToOwnedSession(") else { return false }
    let body = String(chatSrc[r.lowerBound...].prefix(1500))
    guard let g = body.range(of: "isAlreadyInSession(msg.content, in: snap.messages, dedup: dedup)"),
          let a = body.range(of: "msgs.append(msg)") else { return false }
    return g.lowerBound < a.lowerBound
}
check("② 归属会话写入：链内对读#2 复检，且排在 msgs.append 之前", chainGateHolds(chat))
check("② 归属会话写入不再返回裸 Bool（三态区分 duplicate / targetMissing）",
      chat.contains("enum OwnedAppendOutcome { case written, duplicate, targetMissing }")
        && chat.contains("async -> OwnedAppendOutcome"))
check("② 调用方按三态处理：有 case .duplicate 分支", inbox.contains("case .duplicate:"))
check("② 调用方在 duplicate 分支注明「不补弹横幅」是显式取舍（未读红点在后台流式那侧）",
      inboxRaw.contains("这里**不补弹横幅**是显式取舍"))
check("② 负断言：调用方不再用 guard-else 把 duplicate 与 targetMissing 混为一谈",
      !inbox.contains("guard await chat.appendMessageToOwnedSession("))

// ── ③ 注入侧不再裸 append ──
func replyInjectGuardHolds(_ inboxSrc: String) -> Bool {
    guard let r = inboxSrc.range(of: "msg.pushKind = \"reply\"") else { return false }
    let tail = String(inboxSrc[r.upperBound...].prefix(400))
    return tail.contains("appendPushReplyIfNew(msg)") && !tail.contains("chat.append(msg)")
}
check("③ 推送回复注入走查重入口 appendPushReplyIfNew（不再裸 chat.append）", replyInjectGuardHolds(inbox))
check("③ 注入入口用总判据（两道并集），不是单一严格口径",
      chat.contains("if Self.isReplyAlreadyInSession(msg.content, in: messages) { return false }"))
check("③ 通知只在真注入时弹（挂在 appendPushReplyIfNew 的 true 分支内）",
      inbox.contains("if chat.appendPushReplyIfNew(msg) {"))
check("③ 负断言：注入点不再有「先 append 再无条件通知」的旧形态",
      !inbox.contains("chat.append(msg)\n            lastInjectedCount += 1"))

// ── ④ 落库侧谓词镜像真值表 ──
struct M { let role: String; let content: String; let edited: Bool; var isPush: Bool = false }
func mirrorNormalize(_ s: String) -> String {
    s.replacingOccurrences(of: "…", with: "")
        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}
/// 镜像落库侧口径：规范化后 >30 字 + 相等或「新文本是已有文本的前缀」
func mirrorStrict(_ text: String, _ msgs: [M]) -> Bool {
    let core = mirrorNormalize(text)
    guard core.count > 30 else { return false }
    return msgs.contains { m in
        guard m.role == "assistant", !m.edited else { return false }
        let other = mirrorNormalize(m.content)
        return other == core || other.hasPrefix(core)
    }
}
/// 旧形态（v4.0.56 初版）：整串精确相等 —— 只用于反向自证，证明它拦不住多段回复
func mirrorExactOld(_ text: String, _ msgs: [M]) -> Bool {
    guard text.count > 30 else { return false }
    return msgs.contains { $0.role == "assistant" && !$0.edited && $0.content == text }
}
let long = String(repeating: "字", count: 40)
let short = "好的"
check("④ 镜像：长回复同内容已在会话 → 判重",
      mirrorStrict(long, [M(role: "assistant", content: long, edited: false)]))
check("④ 镜像：短回复（≤30）同内容 → 不判重（不同轮可合法同文）",
      !mirrorStrict(short, [M(role: "assistant", content: short, edited: false)]))
check("④ 镜像：折叠态 edited 同内容 → 不判重",
      !mirrorStrict(long, [M(role: "assistant", content: long, edited: true)]))
check("④ 镜像：user 角色同内容 → 不判重",
      !mirrorStrict(long, [M(role: "user", content: long, edited: false)]))
check("④ 镜像：同长度但内容不同 → 不判重",
      !mirrorStrict(String(repeating: "词", count: 40), [M(role: "assistant", content: long, edited: false)]))
check("④ 镜像：新回答比已有的长（旧消息是其前缀）→ 不判重（别吞掉新增内容）",
      !mirrorStrict(long + "新增段落", [M(role: "assistant", content: long, edited: false)]))
check("④ 镜像：换行/多空格差异 → 判重（规范化后同一条）",
      mirrorStrict(long + "\n\n第二段", [M(role: "assistant", content: long + "   第二段", edited: false)]))
check("④ 镜像：推送被截断（前缀 + 省略号）→ 判重",
      mirrorStrict(String(long.prefix(35)) + "…", [M(role: "assistant", content: long, edited: false)]))
check("④ 镜像：新回答只是旧长消息的子串（非前缀）→ 不判重（防误吞新回答）",
      !mirrorStrict(String(long.prefix(35)) + "尾", [M(role: "assistant", content: String(long.prefix(25)) + "中段" + String(long.prefix(35)) + "尾", edited: false)]))

// ── ⑤ 推送侧谓词镜像真值表（InboxDedup.shouldSkip 口径）──
/// 镜像推送侧口径（`InboxDedup.shouldSkip` ② 分支，逐条对齐）：压空白（剥 …）后 core ≥10 字 +
/// 「已有含新文本」／「新文本含已有（且已有 ≥10）」／「已有是新文本的前缀」；扫描时跳过 isPush 气泡
func mirrorPushSkip(_ text: String, _ msgs: [M]) -> Bool {
    let core = mirrorNormalize(text)
    guard !core.isEmpty else { return false }
    for m in msgs.reversed() {
        guard m.role == "assistant", !m.isPush else { continue }
        let cm = mirrorNormalize(m.content)
        if core.count >= 10, cm.contains(core) { return true }
        if core.count >= 10, cm.count >= 10, core.contains(cm) { return true }
        if core.count >= 10, cm.hasPrefix(core) { return true }
    }
    return false
}
let body = "已把「每日一言」加进早报第 6 项，明早 08:00 起跟早报一起推给你。"
let bodyCollapsed = mirrorNormalize(body)
check("⑤ 镜像：推送摘要是同一条的压空白版 → 判重（这就是 2026-10-05 事故情形）",
      mirrorPushSkip(bodyCollapsed, [M(role: "assistant", content: body, edited: false)]))
check("⑤ 镜像：短文本（<10 字，如「好的」）→ 不判重（避免历史短条吞掉新推送）",
      !mirrorPushSkip("好的", [M(role: "assistant", content: "好的", edited: false)]))
check("⑤ 镜像：已有的是 isPush 气泡 → 推送口径看不见它（所以 ①c 还要并上严格口径）",
      !mirrorPushSkip(bodyCollapsed, [M(role: "assistant", content: body, edited: false, isPush: true)])
        && mirrorStrict(body, [M(role: "assistant", content: body, edited: false, isPush: true)]))

// ── ⑤b 多段回复（审查抓到的洞）：推送压单行 vs 落库带换行 ──
let multiBody = "第一段：已把每日一言加进早报第 6 项。\n第二段：明早 08:00 起跟早报一起推。\n第三段：需要改成英文原文+翻译吗？"
let multiPush = multiBody.replacingOccurrences(of: "\n", with: " ")
check("⑤b 多段回复：推送是压掉换行的摘要，落库正文带换行 → 推送口径仍判重",
      mirrorPushSkip(multiPush, [M(role: "assistant", content: multiBody, edited: false)]))
check("⑤b 多段回复：落库侧严格口径也判重（规范化压掉换行差）",
      mirrorStrict(multiBody, [M(role: "assistant", content: multiPush, edited: false)]))
check("⑤b 反向自证：旧「整串精确相等」对多段回复判不重 → 这就是链内复检失守的原因",
      !mirrorExactOld(multiPush, [M(role: "assistant", content: multiBody, edited: false)]) && multiBody != multiPush)

// ── ⑥ 事故重现：读#1 判必漏、读#2 判必拦 ──
let beforeLanding: [M] = [M(role: "user", content: "跟早报一起推", edited: false)]
let afterLanding: [M] = beforeLanding + [M(role: "assistant", content: multiBody, edited: false)]
func inSession(_ text: String, _ msgs: [M]) -> Bool { mirrorPushSkip(text, msgs) || mirrorStrict(text, msgs) }
check("⑥ 事故重现：只在读#1（后台落地前）上判 → 漏（这就是双投的来源）",
      !inSession(multiPush, beforeLanding))
check("⑥ 修复行为：链内读#2（同一条回复已落地）上判 → 拦住",
      inSession(multiPush, afterLanding))

// ── ⑦ 反向自证：改回旧形态 → 对应断言必红 ──
let revertedChain = chat.replacingOccurrences(
    of: "isAlreadyInSession(msg.content, in: snap.messages, dedup: dedup)", with: "true")
check("⑦ 反向自证：链内复检被去掉 → ② 必红", !chainGateHolds(revertedChain))
let revertedInject = inbox.replacingOccurrences(of: "appendPushReplyIfNew(msg)", with: "append(msg)")
check("⑦ 反向自证：注入侧改回裸 append → ③ 必红", !replyInjectGuardHolds(revertedInject))
let revertedUnion = chat.replacingOccurrences(
    of: "isDuplicateReply(text, in: msgs) || hasSameAssistantContent(text, in: msgs)",
    with: "text == msgs.first?.content")
check("⑦ 反向自证：总判据退回「整串精确相等」→ ①c 必红", !unionHolds(revertedUnion))

// ── ⑧ v4.0.57b：落库判重口径**必须按调用方分派**（2026-10-05 只读审查 应改1）──
// 背景：`.duplicate` 直接穿过（不落库），所以宽口径里那条 `core.contains(cm)`
//（新回答包含旧回答）在「权威原文」路径上会把带新内容的回答判成重复 → 回复只活在内存。
func dedupDispatchHolds(_ chatSrc: String) -> Bool {
    guard let r = chatSrc.range(of: "static func isAlreadyInSession(") else { return false }
    let body = String(chatSrc[r.lowerBound...].prefix(520))
    // 去空白归一后再比对：别钉精确空格对齐（缩进/对齐一变就假红，等于没断言语义）
    let flat = body.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    // 2026-10-05 只读审查 应改2：权威原文侧必须走 isReplyAlreadyLanded =
    // **尾部窗口**内的「无门槛精确相等 ∪ >30 宽松」。
    // 只挂 hasSameAssistantContent（>30 门槛）→ 10~30 字的权威回复对已落库推送副本恒不判重 → 双投；
    // 不限尾部（对全历史判）→ 不同轮曾经出现过的同文短回复被误吞成 .duplicate → 不落库、冷启动即丢。
    return flat.contains("case .pushReplica: return isReplyAlreadyInSession(text, in: msgs)")
        && flat.contains("case .authoritativeReply: return Self.isReplyAlreadyLanded(text, in: msgs)")
        && !flat.contains("case .authoritativeReply: return isReplyAlreadyInSession(text, in: msgs)")
}
check("⑧ 口径分派：pushReplica → 推送侧宽口径；authoritativeReply → 统一判据（尾部窗口 精确相等 ∪ >30 宽松）",
      chat.contains("enum OwnedAppendDedup { case pushReplica, authoritativeReply }") && dedupDispatchHolds(chat))
check("⑧ 链内复检走分派函数（不直接调宽口径）",
      chainGateHolds(chat) && !String(chat[chat.range(of: "func appendMessageToOwnedSession(")!.lowerBound...].prefix(1500))
        .contains("isReplyAlreadyInSession(msg.content"))
check("⑧ 负断言：推送注入路径用 .pushReplica（不许改用权威原文口径，多段回复会漏判）",
      inbox.contains("dedup: .pushReplica")
        && !inbox.contains("dedup: .authoritativeReply")
        && String(chat[chat.range(of: "func appendMessageToOwnedSession(")!.lowerBound...].prefix(1500))
            .contains("dedup: dedup"))

// ── ⑨ 反向自证：分派退回「一律宽口径」→ ⑧ 必红 ──
let revertedDispatch = chat.replacingOccurrences(
    of: "case .authoritativeReply: return Self.isReplyAlreadyLanded(text, in: msgs)",
    with: "case .authoritativeReply: return isReplyAlreadyInSession(text, in: msgs)")
check("⑨ 反向自证：判重分派被抹平（authoritativeReply 也用宽口径）→ ⑧ 必红",
      !dedupDispatchHolds(revertedDispatch))

// ── ⑨b 反向自证：权威原文侧退回只挂 >30 宽松口径（短回复双投窗口）→ ⑧ 必红 ──
let revertedStrictOnly = chat.replacingOccurrences(
    of: "case .authoritativeReply: return Self.isReplyAlreadyLanded(text, in: msgs)",
    with: "case .authoritativeReply: return hasSameAssistantContent(text, in: msgs)")
check("⑨b 反向自证：权威原文侧退回只挂 >30 宽松口径（10~30 字双投窗口）→ ⑧ 必红",
      !dedupDispatchHolds(revertedStrictOnly))

print("AI 回复双投真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
