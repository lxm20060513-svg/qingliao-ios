// MARK: - v4.0.57「迟到回复落库」同族收口 · 真值表（源护栏 + 覆盖语义镜像 + 反向自证）
//
// 为什么有这张表（2026-10-05 只读审查指出，同族第二条）：
//   v4.0.56 修掉「链外判重 / 链内写入」两读不同源的双投后，审查在**同族**又翻出两处写者——
//   `BackgroundStreamRunner.finish` 与 `ChatView.landAwayReply` 都拿「**发起时快照** + 回复」**整份写**
//   服务端会话，而后端 merge 对同 id 会话是**整会话覆盖** → 这条流跑着期间落进该会话的其他写者内容
//   （收件箱推送注入 / 其他端同步）会被这份旧数组直接抹掉 = **丢消息**（比多一条气泡更糟，用户看不见）。
//   机理与双投事故同源：判定/写入用的数据不是同一份新鲜度，只不过这里表现为「覆盖」而不是「重复」。
//
// 修法（v4.0.57）：两处都改走 ChatStore 的 FIFO 链内 `appendMessageToOwnedSession`
//   （链内重读服务端最新快照 → 同内容查重 → 追加 → 写）；原「发起时快照」降级为
//   **服务端确实查不到该会话（.targetMissing）时的回落兜底**，且回落仍保留「空快照不许覆盖」守卫
//   （2026-09-30 发布前审查拦下的真数据破坏）。
//
// v4.0.57b（同日只读审查复审 3 条应改/建议）——本表补三组护栏：
//   ⑦ **判重口径按调用方分派**：两处 away 递的是**权威原文** → 必须 `.authoritativeReply`
//      （只认「规范化后相等 / 新文本是已有文本的前缀」）。若沿用推送侧宽口径，其
//      `core.contains(cm)`（新回答包含旧回答、两边 ≥10 字）会把「带着旧消息没有的新内容的回答」
//      判成 `.duplicate` → 这条回复**永远不落库、只活在内存**（冷启动/登出即丢）。
//   ⑧ **回落兜底加正向缺席门禁**：`.targetMissing` 也可能是「这次列表读失败」（`fetchSessionSnapshot`
//      用 `try?` 把传输错误也吞成 nil）→ 拿它当「会话不存在」就会用旧快照整份覆盖。
//      门禁 = `writeBackSnapshotIfSessionAbsent`（列表读成功且无此会话才真写）。
//   ⑨ **内存补回判据与落库侧统一**（`hasSameAssistantContent`），不再整串精确 `==`：
//      否则同一条回复可以「服务端算已有、内存算没有」→ 多插一条同义气泡（用户可见重复）。
//
// 本表九件事：
//   1. finish 走链内；回落兜底只在 .targetMissing 分支里，且排在链内调用之后；
//   2. finish 负断言：旧形态「entry.snapshot 紧接 m2」的整份写指纹消失；
//   3. landAwayReply 走链内；快照只用于回落兜底，且带 !snapshot.isEmpty 守卫；
//   4. landAwayReply 负断言：无条件 `Task { saveToServer(msgs) }` 整份写指纹消失；
//   5. 覆盖语义镜像：旧写法丢消息 / 新写法保住并追加 / 链内查重命中则不重复追加；
//   6. 反向自证（纯函数级，改回旧形态本表必红）；
//   7. 两处 away 都带 `.authoritativeReply`（且本路径不出现宽口径调用）；
//   8. 两处回落都过缺席门禁（不再裸 saveToServer），门禁自身「读失败/会话在 → 不写」；
//   9. `patchAwayLanded` 与落库侧同判据。

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
/// 取 `from` 之后的 n 个字符（函数体取景：改别的函数不该影响本表判据）
func slice(_ s: String, from marker: String, _ n: Int) -> String? {
    guard let r = s.range(of: marker) else { return nil }
    return String(s[r.lowerBound...].prefix(n))
}

let runnerRaw = src("Core/BackgroundStreamRunner.swift")
let runner = stripCommentLines(runnerRaw)
let chatViewRaw = src("Features/Chat/ChatView.swift")
let chatView = stripCommentLines(chatViewRaw)
let chatRaw = src("Core/ChatStore.swift")
let chat = stripCommentLines(chatRaw)
let inboxRaw = src("Core/InboxStore.swift")
let inbox = stripCommentLines(inboxRaw)
check("前置：四个源都读到了（路径/QL_REPO 对不对）",
      !runner.isEmpty && !chatView.isEmpty && !chat.isEmpty && !inbox.isEmpty)

// ── ① BackgroundStreamRunner.finish：落库走链内，快照降级为回落兜底 ──
let finishBody = slice(runner, from: "private func finish(sessionId sid: String", 3000)
check("① finish 函数体取到（锚点还在）", finishBody != nil)
if let b = finishBody {
    check("① finish 落库走链内 appendMessageToOwnedSession（链内重读服务端最新快照）",
          b.contains("await chat.appendMessageToOwnedSession(m2, sessionId: sid, auth: auth,"))
    check("① finish 落库带 .authoritativeReply（权威原文口径）", b.contains("dedup: .authoritativeReply"))
    check("① finish 负断言：本路径不许出现推送侧宽口径调用", !b.contains("isReplyAlreadyInSession"))
    check("① 旧快照写法只在 .targetMissing 分支里（服务端查不到该会话才回落，绝不丢消息）",
          b.contains("if case .targetMissing = outcome {"))
    let iCall = b.range(of: "appendMessageToOwnedSession")?.lowerBound
    let iSnap = b.range(of: "var msgs = entry.snapshot")?.lowerBound
    check("① 快照整份写排在链内调用**之后**（不再是落库基底）",
          iCall != nil && iSnap != nil
            && b.distance(from: b.startIndex, to: iCall!) < b.distance(from: b.startIndex, to: iSnap!))
    check("① 回落兜底仍带「空快照不覆盖」守卫（2026-09-30 真数据破坏那条）",
          b.contains("if !entry.snapshot.isEmpty {"))
    check("① 负断言：旧形态指纹「var msgs = entry.snapshot 紧接 var m2 = ChatMessage.local」已消失",
          !b.contains("var msgs = entry.snapshot\n        var m2 = ChatMessage.local"))
}

// ── ② ChatView.landAwayReply：同上，且快照参数降级为兜底 ──
let awayBody = slice(chatView, from: "func landAwayReply(_ text: String", 2200)
check("② landAwayReply 函数体取到（锚点还在）", awayBody != nil)
if let b = awayBody {
    check("② landAwayReply 落库走链内 appendMessageToOwnedSession",
          b.contains("await chat.appendMessageToOwnedSession(m, sessionId: sid, auth: auth,"))
    check("② landAwayReply 落库带 .authoritativeReply（权威原文口径）", b.contains("dedup: .authoritativeReply"))
    check("② landAwayReply 负断言：本路径不许出现推送侧宽口径调用", !b.contains("isReplyAlreadyInSession"))
    check("② 回落兜底带 .targetMissing + !snapshot.isEmpty 双条件",
          b.contains("if case .targetMissing = outcome, !snapshot.isEmpty {"))
    let iCall = b.range(of: "appendMessageToOwnedSession")?.lowerBound
    let iSnap = b.range(of: "var msgs = snapshot")?.lowerBound
    check("② 快照只用于回落兜底（排在链内调用之后）",
          iCall != nil && iSnap != nil
            && b.distance(from: b.startIndex, to: iCall!) < b.distance(from: b.startIndex, to: iSnap!))
    check("② 负断言：无条件「Task { saveToServer(整份 msgs) }」旧写法已消失",
          !b.contains("Task { await chat.saveToServer(auth: auth, sessionId: sid, messages: msgs, title: title) }"))
    check("② 迟到回复登记仍在落库同一条路径上（进会话时补回，别漏）",
          b.contains("chat.noteAwayLandedReply(sessionId: sid, text: text)"))
}

// ── ③ 调用点：快照参数仍在（回落兜底要用），别被顺手删掉 ──
check("③ ChatView 侧调用点仍传 snapshot（回落兜底依赖它）",
      chatView.contains("landAwayReply(body, agent: stream.isAgent,"))

// ── ④ 覆盖语义镜像：为什么必须改成「链内重读 + 追加」 ──
struct Msg { let role: String; let content: String }
/// 镜像两种写法的服务端结果：整份写（旧）/ 在读到的快照上追加（新）
func overwriteWrite(_ base: [Msg], _ reply: String) -> [Msg] { base + [Msg(role: "assistant", content: reply)] }
func appendWrite(_ fresh: [Msg], _ reply: String) -> [Msg] { fresh + [Msg(role: "assistant", content: reply)] }
/// 镜像链内查重（同内容已在会话里 → 不追加）
func alreadyIn(_ msgs: [Msg], _ text: String) -> Bool {
    msgs.contains { $0.role == "assistant" && $0.content == text }
}

let stale: [Msg] = [Msg(role: "user", content: "帮我把每日一言接进早报")]
let landedDuringStream = Msg(role: "assistant", content: "（这条是流跑着的时候，收件箱推送/其他端落进来的）")
let fresh: [Msg] = stale + [landedDuringStream]
let reply = "（本轮迟到的最终回复）"

check("④ 镜像·旧写法：发起时快照 + 回复整份写 → 期间落地的消息被抹掉（丢消息）",
      !overwriteWrite(stale, reply).contains { $0.content == landedDuringStream.content })
check("④ 镜像·新写法：最新快照 + 追加 → 保住期间落地的消息，且回复在末尾",
      appendWrite(fresh, reply).contains { $0.content == landedDuringStream.content }
        && appendWrite(fresh, reply).count == 3
        && appendWrite(fresh, reply).last?.content == reply)
check("④ 镜像·链内查重：最新快照已含同内容回复 → 命中、不再追加（双投的反向顺序也堵住）",
      alreadyIn(fresh, landedDuringStream.content) && !alreadyIn(fresh, reply))

// ── ⑤ 判据纯函数（供正例与反向自证共用）──
func finishUsesChain(_ s: String) -> Bool {
    guard let b = slice(s, from: "private func finish(sessionId sid: String", 3000) else { return false }
    return b.contains("await chat.appendMessageToOwnedSession(m2, sessionId: sid, auth: auth,")
        && b.contains("dedup: .authoritativeReply")
        && b.contains("if case .targetMissing = outcome {")
        && !b.contains("var msgs = entry.snapshot\n        var m2 = ChatMessage.local")
}
func awayUsesChain(_ s: String) -> Bool {
    guard let b = slice(s, from: "func landAwayReply(_ text: String", 2200) else { return false }
    return b.contains("await chat.appendMessageToOwnedSession(m, sessionId: sid, auth: auth,")
        && b.contains("dedup: .authoritativeReply")
        && b.contains("if case .targetMissing = outcome, !snapshot.isEmpty {")
        && !b.contains("Task { await chat.saveToServer(auth: auth, sessionId: sid, messages: msgs, title: title) }")
}
/// ⑦ 判重口径：两处 away 都用权威原文口径，且本路径不出现宽口径调用
func awayAuthoritative(_ s: String) -> Bool {
    guard let b = slice(s, from: "func landAwayReply(_ text: String", 2200) else { return false }
    return b.contains("dedup: .authoritativeReply") && !b.contains("isReplyAlreadyInSession")
}
/// ⑧ 回落门禁：两处 away 都走 writeBackSnapshotIfSessionAbsent，不再裸整份写
func awayGatedFallback(_ s: String) -> Bool {
    guard let b = slice(s, from: "func landAwayReply(_ text: String", 2200) else { return false }
    return b.contains("await chat.writeBackSnapshotIfSessionAbsent(sessionId: sid, messages: msgs,")
        && !b.contains("await chat.saveToServer(auth: auth, sessionId: sid, messages: msgs")
}
func finishGatedFallback(_ s: String) -> Bool {
    guard let b = slice(s, from: "private func finish(sessionId sid: String", 3000) else { return false }
    return b.contains("await chat.writeBackSnapshotIfSessionAbsent(sessionId: sid, messages: msgs,")
        && !b.contains("await chat.saveToServer(auth: auth, sessionId: sid, messages: msgs")
}
/// ⑦ finish 侧：权威原文口径 + 无宽口径调用
func finishAuthoritative(_ s: String) -> Bool {
    guard let b = slice(s, from: "private func finish(sessionId sid: String", 3000) else { return false }
    return b.contains("dedup: .authoritativeReply") && !b.contains("isReplyAlreadyInSession")
}
/// ⑨ 内存补回：与落库侧**同一个**判据（isReplyAlreadyLanded = 尾部窗口内 精确相等 ∪ >30 宽松）。
///    🚨 不许只挂带 >30 门槛的那条（短回复漏判 → 重复补插）；也不许对**全历史**判（不同轮同文误吞 → 该补的不补）。
func patchUnified(_ s: String) -> Bool {
    guard let b = slice(s, from: "private func patchAwayLanded(", 1200) else { return false }
    return b.contains("Self.isReplyAlreadyLanded(pending, in: msgs)")
        && !b.contains("$0.content == pending")
}
/// ⑨d 统一判据**必须限尾部窗口**（对全 msgs 判会把几轮前的同文回复误吞成「已有」）
func landedTailScoped(_ s: String) -> Bool {
    guard let b = slice(s, from: "static func isReplyAlreadyLanded(", 400) else { return false }
    return b.contains("Array(msgs.suffix(replyDedupTail))")
        && b.contains("isSameAssistantText(text, in: tail)")
        && !b.contains("(text, in: msgs)")          // 不得直接对全历史判
}
/// ⑨b 精确相等判据**必须无长度门槛**（若也带 >30，短回复照漏 → 等于没补）
func exactJudgeHolds(_ s: String) -> Bool {
    guard let b = slice(s, from: "static func isSameAssistantText(", 380) else { return false }
    return b.contains("normalizeForDedup(m.content) == core") && !b.contains("> 30")
}
/// ⑧ 门禁函数自身：**整段在 FIFO 串行链内**（链内重读 + 门禁 + 写）；读失败不写 / 会话在不写 / 确认缺席才写
/// 🚨 必须用**位置断言**：只查 token 存在拦不住真实反模式 —— 保留 `await prev.value`、只把
///    列表读挪到 `Task {}` 闭包之外（读在链外 = 判定与写不是同一份数据 → 插入窗口照旧）。
func gateBodyHolds(_ s: String) -> Bool {
    guard let b = slice(s, from: "func writeBackSnapshotIfSessionAbsent(", 1600) else { return false }
    guard let jobIdx = b.range(of: "let job = Task<Bool, Never> { [weak self] in")?.lowerBound,
          let readIdx = b.range(of: "try? await auth.json(\"/api/sessions/list\")")?.lowerBound,
          let writeIdx = b.range(of: "await self.writeSessionSnapshot(auth: auth, sessionId: sid, messages: msgs, title: title)")?.lowerBound
    else { return false }
    return jobIdx < readIdx && readIdx < writeIdx          // 读必须夹在「进闭包」与「写」之间
        && b.contains("await prev.value")                   // 链内：等前一个写
        && b.contains("saveWriteChain = Task { _ = await job.value }")
        && b.contains("guard !ids.contains(sid) else { return false }")
}

check("⑤ 正例：当前源码过 finish 判据", finishUsesChain(runner))
check("⑤ 正例：当前源码过 landAwayReply 判据", awayUsesChain(chatView))
check("⑦ 正例：landAwayReply 用权威原文口径且无宽口径调用", awayAuthoritative(chatView))
check("⑦ 正例：finish 用权威原文口径且无宽口径调用", finishAuthoritative(runner))
check("⑧ 正例：两处回落都过缺席门禁", finishGatedFallback(runner) && awayGatedFallback(chatView))
check("⑧ 正例：门禁函数整段在链内、口径正确（读失败/会话在 → 不写）", gateBodyHolds(chat))
check("⑨ 正例：patchAwayLanded 用「任意长度精确相等 ∪ 落库侧宽松口径」", patchUnified(chat))
check("⑨b 正例：精确相等判据无长度门槛（>30 门槛只属于宽松口径那条）", exactJudgeHolds(chat))
check("⑨d 正例：统一判据限尾部窗口（不对全历史判）", landedTailScoped(chat))
check("⑨ 正例：推送注入路径仍是推送侧口径（没被顺手改成权威原文口径）",
      inbox.contains("dedup: .pushReplica"))

let revertedFinishOld = runner
    .replacingOccurrences(of: "let outcome = await chat.appendMessageToOwnedSession(m2, sessionId: sid, auth: auth,",
                          with: "let outcome = ChatStore.OwnedAppendOutcome.written\n            _ = (m2, sid, auth, entry)")
check("⑤ 反向自证：finish 去掉链内调用（退回整份写）→ 判据必红", !finishUsesChain(revertedFinishOld))

let revertedFinishNoGuard = runner.replacingOccurrences(of: "if case .targetMissing = outcome {",
                                                       with: "if true {")
check("⑤ 反向自证：finish 回落兜底变成无条件（旧形态）→ 判据必红", !finishUsesChain(revertedFinishNoGuard))

let revertedAway = chatView.replacingOccurrences(
    of: "            let outcome = await chat.appendMessageToOwnedSession(m, sessionId: sid, auth: auth,",
    with: "            let outcome = ChatStore.OwnedAppendOutcome.written\n            _ = (m, sid, auth, title)")
    .replacingOccurrences(of: "if case .targetMissing = outcome, !snapshot.isEmpty {", with: "if false {")
check("⑤ 反向自证：landAwayReply 去掉链内调用（退回快照整份写）→ 判据必红", !awayUsesChain(revertedAway))

let revertedAwayNoGuard = chatView.replacingOccurrences(
    of: "if case .targetMissing = outcome, !snapshot.isEmpty {", with: "if case .targetMissing = outcome {")
check("⑤ 反向自证：landAwayReply 回落丢掉「空快照不覆盖」守卫 → 判据必红", !awayUsesChain(revertedAwayNoGuard))

// ── ⑦ 反向自证：away 口径退回推送侧宽口径 → 必红 ──
let revertedWideDedup = chatView.replacingOccurrences(of: "dedup: .authoritativeReply",
                                                     with: "dedup: .pushReplica")
check("⑦ 反向自证：away 改用推送侧宽口径 → 口径判据必红", !awayAuthoritative(revertedWideDedup))

// ── ⑧ 反向自证：回落退回裸 saveToServer / 门禁去掉正面确认 → 必红 ──
let revertedBareFallback = chatView
    .replacingOccurrences(of: "await chat.writeBackSnapshotIfSessionAbsent(sessionId: sid, messages: msgs,",
                          with: "await chat.saveToServer(auth: auth, sessionId: sid, messages: msgs,")
check("⑧ 反向自证：回落退回裸 saveToServer 整份写 → 门禁判据必红", !awayGatedFallback(revertedBareFallback))

let revertedGateNoConfirm = chat
    .replacingOccurrences(of: "guard !ids.contains(sid) else { return false }", with: "")

// ── ⑧ 反向自证：只把**列表读**挪到闭包外（await prev.value / 链尾赋值全保留）→ 必红 ──
// 这才是真实反模式形态；若只做「删 token」式的变异，断言的鉴别力没有被证明。
let revertedGateOutsideChain = chat
    .replacingOccurrences(of: "            guard let j = try? await auth.json(\"/api/sessions/list\"),\n                  let raw = j[\"sessions\"] as? [Any] else { return false }    // 读不到 ≠ 不存在\n",
                          with: "")
    .replacingOccurrences(of: "        let prev = saveWriteChain\n        let job = Task<Bool, Never> { [weak self] in\n            await prev.value\n            guard let self else { return false }",
                          with: "        guard let j = try? await auth.json(\"/api/sessions/list\"),\n              let raw = j[\"sessions\"] as? [Any] else { return false }    // 读不到 ≠ 不存在\n        let prev = saveWriteChain\n        let job = Task<Bool, Never> { [weak self] in\n            await prev.value\n            guard let self else { return false }")
check("⑧ 反向自证：只把列表读挪出闭包（token 全留）→ 位置断言必红", !gateBodyHolds(revertedGateOutsideChain))
check("⑧ 反向自证：门禁去掉「会话在就不写」→ 门禁判据必红", !gateBodyHolds(revertedGateNoConfirm))

// ── ⑨ 反向自证：内存补回退回整串精确 == → 必红 ──
let revertedPatch = chat.replacingOccurrences(
    of: "if Self.isReplyAlreadyLanded(pending, in: msgs) { return msgs }",
    with: "if msgs.contains(where: { $0.role == \"assistant\" && $0.content == pending }) { return msgs }")
check("⑨ 反向自证：内存补回退回整串精确 == → 判据必红", !patchUnified(revertedPatch))

// ── ⑨b/⑨c 反向自证：短回复漏判（只挂带 >30 门槛的宽松口径）→ 必红 ──
let revertedPatchStrictOnly = chat.replacingOccurrences(
    of: "if Self.isReplyAlreadyLanded(pending, in: msgs) { return msgs }",
    with: "if Self.hasSameAssistantContent(pending, in: msgs) { return msgs }")
check("⑨b 反向自证：内存补回退回只挂 >30 宽松口径（短回复重复窗口）→ 必红", !patchUnified(revertedPatchStrictOnly))

let revertedFullHistory = chat.replacingOccurrences(
    of: "        let tail = Array(msgs.suffix(replyDedupTail))\n        return isSameAssistantText(text, in: tail) || hasSameAssistantContent(text, in: tail)",
    with: "        return isSameAssistantText(text, in: msgs) || hasSameAssistantContent(text, in: msgs)")
check("⑨e 反向自证：判据退回对全历史判（不同轮同文会被误吞）→ ⑨d 必红", !landedTailScoped(revertedFullHistory))

let revertedExactGated = chat.replacingOccurrences(
    of: "        let core = normalizeForDedup(text)\n        guard !core.isEmpty else { return false }",
    with: "        let core = normalizeForDedup(text)\n        guard core.count > 30 else { return false }")
check("⑨c 反向自证：精确相等判据被加上 >30 门槛 → ⑨b 判据必红", !exactJudgeHolds(revertedExactGated))

print("迟到回复落库真值表：\(passCount) 通过 / \(failCount) 失败")
exit(failCount == 0 ? 0 : 1)
