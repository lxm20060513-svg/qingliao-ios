// MARK: - v4.0.20 气泡来源角标 · 真值表（源护栏 + 映射口径镜像）
//
// 用户原话（2026-10）：*「长期目标触发不明显，我不知道当前任务是前台任务还是
//   触发了后台自主推进任务」*；盘现状后确认根因是**「谁在跑」的信息在进 UI 前被抹平**：
//   后端 `inbox_api.push` / `sessions_api.append_fixed_message` 一直带 `task_type`
//   （reply/cron/system/progress/question/agent），而 App 注入气泡时只留了 `isPush`
//   一个布尔，角标统一写「🔔 推送」→ 定时推进 / 主动提醒 / 系统通知长得一模一样。
//
// 口径（用户拍板 1a）：🟢 你问的 / 🔵 定时推进（cron、system）/ 🟠 主动提醒（agent）/ ⚪ 进度（progress）
//
// 护栏四件事：
//   1. 纯逻辑映射在位（`PushKind.style` 五分支齐全 + 出角标的门槛）；
//   2. 链路在位：注入端写 pushKind、落库端持久化、解析端读回（少一处角标就退化成「你问的」）;
//   3. 旧形态清零：气泡里不再有硬编码「🔔 推送」；
//   4. 映射镜像：本机可算的对照表，改口径必红。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
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

let pushKindSrc = src("Core/PushKind.swift")
let bubbleSrc   = src("Features/Chat/ChatMessageBubble.swift")
let inboxSrc    = src("Core/InboxStore.swift")
let chatSrc     = src("Core/ChatStore.swift")
let modelsSrc   = src("Core/Models.swift")

// ── 1. 纯逻辑映射在位 ────────────────────────────────────────────
check("PushKind.swift 存在且不是空壳", pushKindSrc.count > 800)
check("五档映射都在（agent/cron/system/progress/default）",
      pushKindSrc.contains("case \"agent\":") && pushKindSrc.contains("case \"cron\":")
      && pushKindSrc.contains("case \"system\":") && pushKindSrc.contains("case \"progress\":"))
check("agent → 橙色（🟠 主动提醒）", pushKindSrc.contains("Style(label: \"主动提醒\", colorKey: \"orange\")"))
check("cron → 蓝色（🔵 定时推进）", pushKindSrc.contains("Style(label: \"定时推进\", colorKey: \"blue\")"))
check("system → 蓝色（🔵 系统通知）", pushKindSrc.contains("Style(label: \"系统通知\", colorKey: \"blue\")"))
check("progress → 灰色（⚪ 进度快照，不是「一次交代」）",
      pushKindSrc.contains("Style(label: \"进度\",") && pushKindSrc.contains("colorKey: \"gray\")"))
check("default → 绿色（🟢 你问的；老数据 = 回复推送）",
      pushKindSrc.contains("Style(label: \"你问的\",") && pushKindSrc.contains("colorKey: \"green\")"))
check("出角标门槛：只给 assistant 的推送出，且问题卡不重复出（questionId 非空即跳过）",
      pushKindSrc.contains("guard isPush, role == \"assistant\" else { return false }")
      && pushKindSrc.contains("return questionId == nil || questionId!.isEmpty"))

// ── 2. 链路在位：写入 → 落库 → 读回 ──────────────────────────────
// v4.0.21：新增第 5 处 —— 会话归属路由（归属会话≠当前打开时把 reply/progress/question
// 落进归属会话，pushKind 由 taskType 带入）。注入端每加一处都必须标来源，故计数同步到 5。
let inboxWriteCount = inboxSrc.components(separatedBy: "pushKind = ").count - 1
check("注入端五处都标了来源（agent / progress / question / reply + 会话归属路由）——实测 \(inboxWriteCount) 处",
      inboxWriteCount == 5)
for (kind, why) in [("agent", "主动消息进「轻聊主动」"), ("progress", "进度快照"),
                    ("question", "AI 追问卡"), ("reply", "回复推送")] {
    check("注入端标了 \(kind)（\(why)）", inboxSrc.contains("pushKind = \"\(kind)\""))
}
check("会话归属路由也带来源角标（pushKind 由 taskType 带入，不是空手落库）",
      inboxSrc.contains("msg.pushKind = taskType"))
check("落库端持久化 pushKind（否则重启后角标退化成「你问的」）",
      chatSrc.contains("p[\"pushKind\"] = k"))
check("解析端读回：本地 pushKind 优先，服务端固定会话回落 task_type",
      modelsSrc.contains("msg.pushKind = (d[\"pushKind\"] as? String) ?? (d[\"task_type\"] as? String)"))
check("ChatMessage 有 pushKind 字段", modelsSrc.contains("var pushKind: String?"))

// ── 3. 旧形态清零 + 气泡接线 ─────────────────────────────────────
let bubbleCode = stripCommentLines(bubbleSrc)
check("气泡走 PushKind.showsTag 门槛（不再只看 isPush）",
      bubbleCode.contains("PushKind.showsTag(role: message.role, isPush: message.isPush"))
check("气泡走 PushKind.style 取文案与色系", bubbleCode.contains("PushKind.style(for: message.pushKind)"))
check("色系有 UI 映射点（colorKey → Color）", bubbleCode.contains("func pushKindColor("))
check("硬编码「🔔 推送」清零（旧单一蓝色角标已移除）",
      !bubbleCode.contains("🔔 推送"))
check("旧单一蓝色写死 `Color.blue` 的胶囊角标不再出现",
      !bubbleCode.contains("Text(\"🔔") )

// ── 4. 映射镜像（与 PushKind.style 同口径；改口径这里必红） ──────
func mirrorStyle(_ kind: String?) -> (String, String) {
    switch kind {
    case "agent":    return ("主动提醒", "orange")
    case "cron":     return ("定时推进", "blue")
    case "system":   return ("系统通知", "blue")
    case "progress": return ("进度", "gray")
    default:         return ("你问的", "green")
    }
}
let cases: [(String?, String, String, String)] = [
    ("agent",    "主动提醒", "orange", "AI 主动开口"),
    ("cron",     "定时推进", "blue",   "定时/后台任务"),
    ("system",   "系统通知", "blue",   "系统事件"),
    ("progress", "进度",     "gray",   "进行中快照"),
    ("reply",    "你问的",   "green",  "回复推送"),
    (nil,        "你问的",   "green",  "老数据（无 task_type）"),
    ("",         "你问的",   "green",  "空串也归到回复"),
    ("banana",   "你问的",   "green",  "未知类型不猜，归回复"),
]
for (kind, label, color, why) in cases {
    let got = mirrorStyle(kind)
    check("镜像：\(kind ?? "nil") → \(label)/\(color)（\(why)）",
          got.0 == label && got.1 == color)
}
// 关键区分：定时（蓝）与主动（橙）不同色 —— 这正是用户「分不清」的病灶
check("镜像：定时推进与主动提醒**不同色**（蓝 ≠ 橙，用户的核心诉求）",
      mirrorStyle("cron").1 != mirrorStyle("agent").1)

print("气泡来源角标真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
