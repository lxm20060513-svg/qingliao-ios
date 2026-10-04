// MARK: - v4.0.57「迟到回复落库」同族收口 · 真值表（源护栏 + 覆盖语义镜像 + 反向自证）
//
// 为什么有这张表（2026-10-05 只读审查指出，同族第二条）：
//   v4.0.56 修掉「链外判重 / 链内写入」两读不同源的双投后，审查在**同族**又翻出两处写者——
//   `BackgroundStreamRunner.finish` 与 `ChatView.landAwayReply` 都拿「**发起时快照** + 回复」**整份写**
//   服务端会话，而后端 merge 对同 id 会话是**整会话覆盖** → 这条流跑着期间落进该会话的其他写者内容
//   （收件箱推送注入 / 其他端同步）会被这份旧数组直接抹掉 = **丢消息**（比多一条气泡更糟，用户看不见）。
//   机理与双投事故同源：判定/写入用的数据不是同一份新鲜度，只不过这里表现为「覆盖」而不是「重复」。
//
// 修法：两处都改走 ChatStore 的 FIFO 链内 `appendMessageToOwnedSession`
//   （链内重读服务端最新快照 → 同内容查重 → 追加 → 写）；原「发起时快照」降级为
//   **服务端查不到该会话（.targetMissing）时的回落兜底**，且回落仍保留「空快照不许覆盖」守卫
//   （2026-09-30 发布前审查拦下的真数据破坏）。
//
// 本表六件事：
//   1. finish 走链内；回落兜底只在 .targetMissing 分支里，且排在链内调用之后；
//   2. finish 负断言：旧形态「entry.snapshot 紧接 m2」的整份写指纹消失；
//   3. landAwayReply 走链内；快照只用于回落兜底，且带 !snapshot.isEmpty 守卫；
//   4. landAwayReply 负断言：无条件 `Task { saveToServer(msgs) }` 整份写指纹消失；
//   5. 覆盖语义镜像：旧写法丢消息 / 新写法保住并追加 / 链内查重命中则不重复追加；
//   6. 反向自证（纯函数级，改回旧形态本表必红）。

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
check("前置：两份源都读到了（路径/QL_REPO 对不对）", !runner.isEmpty && !chatView.isEmpty)

// ── ① BackgroundStreamRunner.finish：落库走链内，快照降级为回落兜底 ──
let finishBody = slice(runner, from: "private func finish(sessionId sid: String", 3000)
check("① finish 函数体取到（锚点还在）", finishBody != nil)
if let b = finishBody {
    check("① finish 落库走链内 appendMessageToOwnedSession（链内重读服务端最新快照）",
          b.contains("await chat.appendMessageToOwnedSession(m2, sessionId: sid, auth: auth)"))
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
let awayBody = slice(chatView, from: "func landAwayReply(_ text: String", 1600)
check("② landAwayReply 函数体取到（锚点还在）", awayBody != nil)
if let b = awayBody {
    check("② landAwayReply 落库走链内 appendMessageToOwnedSession",
          b.contains("await chat.appendMessageToOwnedSession(m, sessionId: sid, auth: auth)"))
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

// ── ⑤ 反向自证：把任一处改回旧形态 → 本表必红 ──
func finishUsesChain(_ s: String) -> Bool {
    guard let b = slice(s, from: "private func finish(sessionId sid: String", 3000) else { return false }
    return b.contains("await chat.appendMessageToOwnedSession(m2, sessionId: sid, auth: auth)")
        && b.contains("if case .targetMissing = outcome {")
        && !b.contains("var msgs = entry.snapshot\n        var m2 = ChatMessage.local")
}
func awayUsesChain(_ s: String) -> Bool {
    guard let b = slice(s, from: "func landAwayReply(_ text: String", 1600) else { return false }
    return b.contains("await chat.appendMessageToOwnedSession(m, sessionId: sid, auth: auth)")
        && b.contains("if case .targetMissing = outcome, !snapshot.isEmpty {")
        && !b.contains("Task { await chat.saveToServer(auth: auth, sessionId: sid, messages: msgs, title: title) }")
}

check("⑤ 正例：当前源码过 finish 判据", finishUsesChain(runner))
check("⑤ 正例：当前源码过 landAwayReply 判据", awayUsesChain(chatView))

let revertedFinishOld = runner.replacingOccurrences(
    of: "        // 🚨 v4.0.57", with: "        // (reverted)")
    .replacingOccurrences(of: "let outcome = await chat.appendMessageToOwnedSession(m2, sessionId: sid, auth: auth)",
                          with: "let outcome = ChatStore.OwnedAppendOutcome.written")
check("⑤ 反向自证：finish 去掉链内调用（退回整份写）→ 判据必红", !finishUsesChain(revertedFinishOld))

let revertedFinishNoGuard = runner.replacingOccurrences(of: "if case .targetMissing = outcome {",
                                                       with: "if true {")
check("⑤ 反向自证：finish 回落兜底变成无条件（旧形态）→ 判据必红", !finishUsesChain(revertedFinishNoGuard))

let revertedAway = chatView.replacingOccurrences(
    of: "            let outcome = await chat.appendMessageToOwnedSession(m, sessionId: sid, auth: auth)",
    with: "            let outcome = ChatStore.OwnedAppendOutcome.written")
    .replacingOccurrences(of: "if case .targetMissing = outcome, !snapshot.isEmpty {", with: "if false {")
check("⑤ 反向自证：landAwayReply 去掉链内调用（退回快照整份写）→ 判据必红", !awayUsesChain(revertedAway))

let revertedAwayNoGuard = chatView.replacingOccurrences(
    of: "if case .targetMissing = outcome, !snapshot.isEmpty {", with: "if case .targetMissing = outcome {")
check("⑤ 反向自证：landAwayReply 回落丢掉「空快照不覆盖」守卫 → 判据必红", !awayUsesChain(revertedAwayNoGuard))

print("迟到回复落库真值表：\(passCount) 通过 / \(failCount) 失败")
exit(failCount == 0 ? 0 : 1)
