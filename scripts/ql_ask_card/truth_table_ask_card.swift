// MARK: - 问题卡（AI 中途追问）投递路由真值表（v4.0.46）
//
// 用户原话（2026-10-04）：*「要弹选题卡呀，现在是不弹选题卡导致我选不了」*
//   *「轻聊投递不支持回复，又不弹出选题卡，我没法选」*
//
// 现场取证：NAS `inbox_archive/inbox_20261004.jsonl` 里那条
//   `{id: c07ab04a2409, task_type: question, session_id: qingliao_delivery,
//     source_task_id: pool5-habit-scope, reason: mark_done}`
// —— 卡**推出来了**，但归属会话填的是固定投递壳「轻聊投递」；App 侧那条
//   「归属会话 == 投递壳 → 静默 markDone + return」的短路把 question 一起吃掉 →
//   卡既不显示也不能答，用户干等、AI 侧超时（队列里查不到 = 归档原因就是 mark_done）。
//   而 v3.9.110 的显式取舍写得很清楚：question **刻意不在投递闸门里** —— 必须落进会话
//   成可作答卡。v4.0.21 加短路线时漏了这条豁免，本次补上。
//
// 本表钉三件事：
//   ① 路由镜像：投递壳短路只吃 reply/progress/agent，**question 一律落成卡**
//   ② iOS 接线：InboxStore 短路条件带 question 豁免；question 分支不 markDone；答案走 /api/inbox/answer
//   ③ 后端接线（NAS 源码，本机没挂载时明确跳过）：push 放行 question；投递壳只 append cron/system

import Foundation

var pass = 0, fail = 0
func ok(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("  ✅ \(name)") } else { fail += 1; print("  ❌ \(name)") }
}

let repo: String = {
    if let e = ProcessInfo.processInfo.environment["QL_REPO"], !e.isEmpty { return e }
    // #filePath = <repo>/scripts/ql_*/truth_table_*.swift → 上溯三级到仓库根
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
}()
func read(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
/// 去注释（注释里提到旧写法不算数）
func strip(_ src: String, _ mark: String) -> String {
    src.split(separator: "\n").map { line -> String in
        guard let r = line.range(of: mark) else { return String(line) }
        return String(line[line.startIndex..<r.lowerBound])
    }.joined(separator: "\n")
}

let DELIVERY = "qingliao_delivery"

// ── ① 路由镜像：App 收到一条收件箱消息后「落哪里」的判定 ──
//    口径来源：InboxStore.consumeOne（owned 分支 → 投递壳短路 → 进度 → 投递闸门 → question/agent 分支）
enum Route: String { case swallow = "静默收尾(markDone)", toOwned = "落归属会话", toCurrent = "落当前会话成卡" }

func route(taskType: String, ownedSid: String?, currentSid: String) -> Route {
    // ownedSessionId(sessionId, current:)：归属会话 == 当前会话 → nil（走下面「当前会话」分支）
    let sid = (ownedSid != nil && ownedSid != currentSid) ? ownedSid : nil
    if let sid = sid, ["reply", "progress"].contains(taskType) {
        // 投递壳短路：question 压根**不进这条归属分支**（v4.0.46 修）→ 下面按「落当前会话」处理
        if sid == DELIVERY { return .swallow }
        if taskType == "progress" { return .swallow }        // 归属会话没打开 → 无位置可放
        return .toOwned                                     // reply → 落归属会话
    }
    // 投递闸门（当前会话就是投递壳）：reply/progress/agent 拦；question 刻意不拦
    if currentSid == DELIVERY, ["reply", "progress", "agent"].contains(taskType) { return .swallow }
    return .toCurrent                                        // question/agent/cron/system 落到当前会话
}

print("── ① 路由镜像（这次的 bug 就在这张表里）──")
ok(route(taskType: "question", ownedSid: DELIVERY, currentSid: "main") == .toCurrent,
   "question 归属投递壳 → 落**当前会话**（本次修复：①不被静默吃掉 ②不写归属壳；旧口径=swallow/.toOwned）")
ok(route(taskType: "reply", ownedSid: DELIVERY, currentSid: "main") == .swallow,
   "reply 归属投递壳 → 仍静默收尾（只弹通知，不进壳）")
ok(route(taskType: "progress", ownedSid: DELIVERY, currentSid: "main") == .swallow,
   "progress 归属投递壳 → 仍静默收尾")
ok(route(taskType: "question", ownedSid: nil, currentSid: "main") == .toCurrent,
   "question 无归属 → 落当前会话成卡（ask_user.py 的路径）")
ok(route(taskType: "question", ownedSid: "main", currentSid: "main") == .toCurrent,
   "question 归属==当前会话 → 落当前会话成卡")
ok(route(taskType: "question", ownedSid: DELIVERY, currentSid: DELIVERY) == .toCurrent,
   "question 归属投递壳、用户正停在投递壳 → 落在当前会话（=壳）成卡（v3.9.110：人看得到才答得了）")
ok(route(taskType: "reply", ownedSid: "sessA", currentSid: "sessB") == .toOwned,
   "reply 归属别的会话 → 落归属会话（v4.0.21 防串位）")
ok(route(taskType: "agent", ownedSid: nil, currentSid: DELIVERY) == .swallow,
   "agent 落在投递壳 → 拦（与 question 相反，v4.0.11 口径）")
ok(route(taskType: "question", ownedSid: nil, currentSid: DELIVERY) == .toCurrent,
   "question 落投递壳 → 不拦（就是「投递壳里冒出一张卡」那条已知取舍）")

// ── ② iOS 接线 ──
print("── ② iOS 接线（InboxStore / ChatQuestionCard）──")
let inbox = strip(read(repo + "/qingliao/Core/InboxStore.swift"), "//")
ok(inbox.contains("taskType == \"reply\" || taskType == \"progress\" {"),
   "归属分支只收 reply/progress（question 不在里面；回退成带 question 即红）")
ok(!inbox.contains("\"progress\" || taskType == \"question\""),
   "反向自证：归属分支条件里不许再出现 question")
ok(inbox.contains("if sid == ChatStore.deliverySessionId {"),
   "投递壳短路本身保持原样（question 已不经过它）")
if let m = inbox.range(of: "qmsg.questionId = id"),
   let a = inbox.range(of: "if taskType == \"question\" {", options: .backwards,
                         range: inbox.startIndex..<m.lowerBound),
   let b = inbox.range(of: "if taskType ==", range: m.upperBound..<inbox.endIndex) {
    let qbranch = String(inbox[a.lowerBound..<b.lowerBound])
    ok(qbranch.contains("qmsg.questionId = id"), "question 分支挂 questionId（气泡才渲染成卡）")
    ok(qbranch.contains("qmsg.questionOptions"), "question 分支挂选项（胶囊按钮）")
    ok(qbranch.contains("NotificationHelper.notify"), "question 分支弹通知（侧载无 APNs，不弹人不知道）")
    ok(!qbranch.contains("markDone"), "question 分支**不** markDone（卡要一直留着让人随时答）")
} else {
    ok(false, "找不到 question 分支边界 → 需同步本表")
}
ok(inbox.contains("\"/api/inbox/answer\""), "答案出口是 POST /api/inbox/answer（与会话能否回复无关）")
let card = strip(read(repo + "/qingliao/Features/Chat/ChatQuestionCard.swift"), "//")
ok(card.contains("optionButtons"), "卡片有选项胶囊（点一下即答）")
ok(card.contains("submit(draft)") || card.contains("submit("), "卡片有自由输入提交")

// ── ③ 后端接线（NAS 真源；本机没挂载时明确跳过）──
print("── ③ 后端接线（inbox_api.py）──")
let bePath = "/opt/hermes_host/微信文件/轻聊web/backend/inbox_api.py"
let beRaw = read(bePath)
if beRaw.isEmpty {
    print("  ⏭  本机没挂载 NAS（\(bePath) 读不到）→ 跳过后端检查")
} else {
    let be = strip(beRaw, "#")
    ok(be.contains("\"question\""), "push 放行 task_type=question（App 才会渲染成卡）")
    ok(be.contains("if task_type in (\"cron\", \"system\")"),
       "投递壳只 append cron/system —— question 不会混进壳内容（App 端才必须自己出卡）")
    ok(be.contains("want_id"), "push 支持 want_id（AI 侧要靠 id 轮询答案）")
    ok(be.contains("def answer_question"), "后端有 answer_question（App 作答写回队列）")
}

// ── ④ 问题卡回执（v4.0.46：用户「之后选卡之后给个回馈，不然不确定回复完成没」）──
print("── ④ 问题卡回执（选完能给回馈）──")
// 镜像 InboxStore.refreshQuestionAcks 的判定（后端 taken/gone_reason → 卡上说什么）
enum Receipt: String { case pending = "已提交·等AI确认", acked = "AI已收到", expired = "卡片已过期" }
func receipt(taken: Bool, why: String) -> Receipt {
    guard taken else { return .pending }          // 条目还在队列里 → 还没人取
    return why == "mark_done" ? .acked : .expired // 只有 mark_done 才算真送达
}
ok(receipt(taken: false, why: "") == .pending, "还在队列里等 AI → 保持「已提交 · 等 AI 确认」")
ok(receipt(taken: true, why: "mark_done") == .acked, "AI 侧 mark_done 取走 → 「AI 已收到」")
ok(receipt(taken: true, why: "sending_stale_24h") == .expired, "过期清理 ≠ AI 收到 → 「卡片已过期」（不许报假回执）")
ok(receipt(taken: true, why: "pending_stale_24h") == .expired, "同上（pending 侧过期）")
ok(receipt(taken: true, why: "unknown") == .expired, "原因不明 → 不猜「已收到」，按未确认处理")

ok(inbox.contains("func refreshQuestionAcks"), "InboxStore 有回执轮询入口")
ok(inbox.contains("await refreshQuestionAcks(auth: auth, chat: chat)"),
   "pollOnce 每轮都刷回执（与「有没有新条目」无关，否则空队列时永远不确认）")
ok(inbox.contains("d[\"taken\"] as? Bool") && inbox.contains("gone_reason"),
   "回执判据取后端 taken / gone_reason（不靠猜）")
ok(inbox.contains("(d[\"ok\"] as? Bool) ?? false, (d[\"taken\"] as? Bool) ?? false"),
   "ok 与 taken 都要查（后端 200 也可能语义失败，不当成查到了）")
ok(inbox.contains("lastAckSweep") && inbox.contains(">= 10 else { return }"),
   "回执扫描节流 10s（5s 的 poll 不许每轮都打接口）")
ok(inbox.contains("if why == \"mark_done\"") && inbox.contains("markQuestionAcked")
   && inbox.contains("markQuestionExpired"),
   "mark_done → 已收到；其它 → 已过期（两条分支都在，缺一条就是把过期报成送达）")
let chat = strip(read(repo + "/qingliao/Core/ChatStore.swift"), "//")
ok(chat.contains("func markQuestionAcked(messageId:") && chat.contains("func markQuestionExpired(messageId:"),
   "ChatStore 两个回执入口都在")
ok(chat.contains("questionExpired = false"),
   "acked / expired 互斥（过期态要清 acked，否则卡头 acked 优先会把「已过期」盖成假回执）")
let models = strip(read(repo + "/qingliao/Core/Models.swift"), "//")
ok(models.contains("var questionAcked: Bool = false") && models.contains("var questionExpired: Bool = false"),
   "ChatMessage 带回执字段（默认 false → 旧数据/旧包不炸）")
ok(card.contains("\"AI 已收到\"") && card.contains("卡片已过期") && card.contains("已提交 · 等 AI 确认"),
   "卡头四态文案齐全（待答 / 已提交 / AI 已收到 / 已过期）")
ok(card.contains("receiptText"), "答案下方有回执行（用户能看到送到哪一步）")

if !beRaw.isEmpty {
    let be = strip(beRaw, "#")
    ok(be.contains("def _gone_reason"), "后端 _gone_reason：回查归档说清「为什么消失」")
    ok(be.contains("\"gone_reason\": (_gone_reason(mid) if not found else \"\")"), "answer 端点回传 gone_reason")
    ok(be.contains("\"taken\": (not found)"), "answer 端点回传 taken")
    ok(be.contains("_archive(hit, \"mark_done\")"), "mark_done 的归档原因就是 mark_done（回执才认得出）")
}

print("\n通过 \(pass) 项，失败 \(fail) 项")
exit(fail == 0 ? 0 : 1)
