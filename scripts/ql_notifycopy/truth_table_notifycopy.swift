import Foundation

// 轻聊通知文案规范化 · **源码契约**真值表（v4.0.91）
// ============================================================
// 分工：行为（前缀/截断/nil 语义）由 comp 一起编译的 test_notifycopy.swift 钉；
// 这里钉**结构**——「分类表只有一份」「没有遗漏的调用点」「老标题写法没残留」，
// 这三件事只在源码层面能查（跑起来是查不出来的）。
//
// 为什么必须有这一张：这次改动的对象是**分散在 5 个文件里的 11 个弹通知点**。
// 漏掉一个不会有任何编译错误 —— 表现是「大部分通知标题统一了，就那一条还是老样子」，
// 而用户恰恰可能按那条写自动化条件。漏点必须由机器数出来。

var pass = 0
var fail = 0

func ck(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { pass += 1; print("✅ \(name)") }
    else { fail += 1; print("❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

let repo = ProcessInfo.processInfo.environment["QL_REPO"] ?? FileManager.default.currentDirectoryPath

func read(_ rel: String) -> String {
    (try? String(contentsOfFile: repo + "/" + rel, encoding: .utf8)) ?? ""
}

let copySrc = read("qingliao/Core/QingliaoNotifyCopy.swift")
let helperSrc = read("qingliao/Core/NotificationHelper.swift")
let inboxSrc = read("qingliao/Core/InboxStore.swift")
let reminderSrc = read("qingliao/Core/QuickReminderScheduler.swift")
let actionSrc = read("qingliao/Core/AgentActionExecutor.swift")
let exportSrc = read("qingliao/Features/Chat/ChatViewExport.swift")

// MARK: - 1. 分类表只有一份，且前缀与测试一致

ck("QingliaoNotifyCopy.swift 存在且非空", copySrc.count > 1000)
for (kind, prefix) in [("reminder", "轻聊·提醒"), ("reply", "轻聊·回复"), ("proactive", "轻聊·主动"),
                       ("confirm", "轻聊·待确认"), ("inbox", "轻聊·投递"), ("alert", "轻聊·告警")] {
    ck("分类表里有 \(kind) → \(prefix)", copySrc.contains("return \"\(prefix)\""))
}
// 后端的 5 个 task_type 必须各有映射（少一个 → 那类推送会掉到兜底类别，自动化筛不出来）
for tt in ["agent", "question", "cron", "system"] {
    ck("fromTaskType 覆盖 \(tt)", copySrc.contains("case \"\(tt)\""))
}
ck("fromTaskType 是唯一映射点（static func）", copySrc.contains("static func fromTaskType("))

// 纯 Foundation 是这一层「本机能验」的前提：import 了 UserNotifications 就编不了真值表了
ck("只 import Foundation（否则真值表编不了）",
   copySrc.contains("import Foundation") && !copySrc.contains("import UserNotifications")
   && !copySrc.contains("import UIKit") && !copySrc.contains("import SwiftUI"))

// 副标题上限是契约（写进注释也要能被查）
ck("副标题上限 24", copySrc.contains("subtitleLimit = 24"))

// MARK: - 2. 所有弹通知点都走 kind（不许再有硬编码标题）

let notifyFiles: [(String, String)] = [
    ("NotificationHelper.swift", helperSrc),
    ("InboxStore.swift", inboxSrc),
    ("QuickReminderScheduler.swift", reminderSrc),
    ("AgentActionExecutor.swift", actionSrc),
    ("ChatViewExport.swift", exportSrc),
]
for (name, src) in notifyFiles {
    ck("\(name) 没有残留 notify(title:)", !src.contains("notify(title:"))
}
for old in ["轻聊 · 推送", "轻聊 · 主动", "轻聊 · AI 需要你确认", "轻聊 · 任务"] {
    let hit = notifyFiles.filter { $0.1.contains(old) }.map { $0.0 }
    ck("老标题「\(old)」已无残留", hit.isEmpty, "还在：\(hit.joined(separator: ","))")
}
ck("QuickReminderScheduler 不再写死「轻聊提醒」", !reminderSrc.contains("content.title = \"轻聊提醒\"")
   && !reminderSrc.contains("title = \"轻聊提醒\""))
ck("AgentActionExecutor 不再让 AI 标题当通知标题",
   !actionSrc.contains("content.title = action.param(\"title\")"))

// MARK: - 3. 收件箱 8 个弹点一个都不能漏

let inboxCalls = inboxSrc.components(separatedBy: "NotificationHelper.notify(").count - 1
ck("InboxStore 弹通知点数量 = 8（漏一个只在真机表现为「有一条通知标题没统一」）",
   inboxCalls == 8, "实得 \(inboxCalls)")
let viaMap = inboxSrc.components(separatedBy: "QingliaoNotifyKind.fromTaskType(taskType)").count - 1
ck("InboxStore 8 个点全走 fromTaskType(taskType)（唯一映射点）",
   viaMap == inboxCalls, "fromTaskType \(viaMap) 处 / 调用点 \(inboxCalls) 处")

// 收件箱里出现过的 task_type 必须都在映射表内（后端将来加新类型 → 这张表先红）
var taskTypes = Set<String>()
for chunk in inboxSrc.components(separatedBy: "taskType == \"") .dropFirst() {
    if let v = chunk.split(separator: "\"").first { taskTypes.insert(String(v)) }
}
let known: Set<String> = ["reply", "question", "agent", "cron", "system", "progress"]
ck("InboxStore 用到的 task_type 全部在映射表内", taskTypes.isSubset(of: known),
   "多出来：\(taskTypes.subtracting(known).sorted())")
ck("InboxStore 用到的 task_type 数量 ≥ 4（确实是多类型分发）", taskTypes.count >= 4,
   "实得 \(taskTypes.count)：\(taskTypes.sorted())")

// MARK: - 4. 各专用路径的关键约定

ck("notifyReply 走 .reply 类别", helperSrc.contains("notify(kind: .reply,"))
ck("notifyReply 用 QingliaoNotifyCopy.replyPreview（预览逻辑只有一份）",
   helperSrc.contains("QingliaoNotifyCopy.replyPreview(reply)")
   && !helperSrc.contains("components(separatedBy: .newlines).first"))
ck("notify(kind:) 组装走 compose（标题/副标题/正文一处拼）",
   helperSrc.contains("QingliaoNotifyCopy.compose(kind,"))
ck("副标题只在非 nil 时设置（空串会让通知多一行空白）",
   helperSrc.contains("if let sub = copy.subtitle { content.subtitle = sub }"))
ck("定时提醒带时间副标题（可判别 + 关键值）",
   reminderSrc.contains("compose(.reminder, detail: item.timeText"))
ck("AI 发的通知把 AI 标题降级到副标题",
   actionSrc.contains("compose(.reminder, detail: action.param(\"title\")"))
ck("后台投递保持静默（sound: false 没被改掉）", inboxSrc.contains("sound: false"))

// MARK: - 5. 反问：如果这张表只查了注释/文档而不是代码，等于没查

ck("被检查的 6 个文件都真的读到了内容", [copySrc, helperSrc, inboxSrc, reminderSrc, actionSrc, exportSrc]
    .allSatisfy { $0.count > 500 })

print("")
if fail == 0 { print("通过 \(pass) 项 / 失败 0 项") }
else { print("通过 \(pass) 项，失败 \(fail) 项") }
exit(fail == 0 ? 0 : 1)
