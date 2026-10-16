// v4.0.118 推送及时性 & 后台保活 —— 混合真值表（② 后台补拉收件箱 + ③ BGAppRefreshTask / 唤醒台账）
//
// 口径（用户 2026-10-16 拍板 ①②③ 三条一起做）：
//   ② 后台唤醒时**除了查流式任务，还要补拉收件箱**——原来只查流式任务，Hermes 推进收件箱的
//      消息（任务中心 / 告警 / 目标日报 / AI 追问）在挂起期间一条都弹不出来；
//   ③ 换成 BGAppRefreshTask（可设 earliestBeginDate）+ 进后台重排下一次 + 每次唤醒写台账，
//      把"及时性"变成可测数字（系统调度时刻不保证，只能实测分布）。
//
// 为什么必须有这张表（全是**静默失效**：编译过、预检绿、只有真机/隔天才看出来）：
//   ① performFetch 又退回「只有 stream pending 才动」→ 收件箱推送在后台继续静默丢失（本表的
//      **反例**就是钉这个），症状是"消息不弹"，而前台一切正常 ⇒ 极难怀疑到后台；
//   ② identifier 不在 project.yml 的 `BGTaskSchedulerPermittedIdentifiers` 白名单里 →
//      `BGTaskScheduler.register` **抛异常**（真机冷启动崩，`swiftc -parse` 与 CI archive 都查不出）；
//      且代码里再写一遍字面量 → 两处漂移后同样崩，所以下面既查"逐字一致"也查"代码只用常量"；
//   ③ BGTask 回调在**后台队列**，方法体进了 MainActor 隔离 = SIGTRAP（v3.9.4 通知回调同源坑）；
//   ④ 忘了重排下一次 → 只响一次就断供（系统同时只保留一个未完成请求）；
//   ⑤ 以为是 `applicationDidEnterBackground` 就够了 —— 本 App 是 scene 化进程，它**永不被调用**，
//      真入口只有 `QingliaoSceneDelegate.sceneDidEnterBackground`（v4.0.118 之前没人碰后台队列的根因）；
//   ⑥ 两条腿都回调 completion（或过期收尾又回调一次）→ 未定义行为；
//   ⑦ 已消费键名各写一份（InboxStore 一份、后台补拉一份）→ 漂移后同一条推送弹两次；
//   ⑧ 后台补拉忘了跳过 progress / 不设上限 → 一次唤醒刷满通知中心，用户当成故障。
// ⚠️ **必须 cwd = 仓库根**（下列路径是相对路径）。
// ⚠️ 多文件编译时顶层代码必须在名为 main.swift 的文件里（check_swift.sh 里已 cp 一份）。

import Foundation

var pass = 0
var fail = 0

@MainActor
func ck(_ name: String, _ cond: Bool) {
    if cond { pass += 1 } else { fail += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉行注释，但**不动字符串字面量里**的 `//`（`"https://…"` 被削成 `"https:` 会让
/// URL 断言静默失效）。不支持 `\"` 转义 —— 本仓这几处用不到。
func code(_ text: String) -> String {
    var out: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var inStr = false
        var cut = line.endIndex
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "\"" { inStr.toggle() }
            if !inStr && c == "/" {
                let n = line.index(after: i)
                if n < line.endIndex && line[n] == "/" { cut = i; break }
            }
            i = line.index(after: i)
        }
        out.append(String(line[line.startIndex..<cut]))
    }
    return out.joined(separator: "\n")
}

/// 取某段实现的正文（从 signature 起到第一个 `\n    }`）——做「这个方法里必须有两件事」的断言用
func body(of signature: String, in text: String) -> String {
    guard let r = text.range(of: signature) else { return "" }
    let tail = text[r.lowerBound...]
    guard let end = tail.range(of: "\n    }") else { return String(tail) }
    return String(tail[..<end.lowerBound])
}

/// 取 `marker = "字面量"` 里的字面量
func literal(after marker: String, in text: String) -> String? {
    guard let r = text.range(of: marker) else { return nil }
    let rest = text[r.upperBound...]
    guard let q1 = rest.firstIndex(of: "\""),
          let q2 = rest[rest.index(after: q1)...].firstIndex(of: "\"") else { return nil }
    return String(rest[rest.index(after: q1)..<q2])
}

let appSrc = src("qingliao/Features/Chat/ChatAppDelegate.swift")
let app = code(appSrc)
let shortcuts = code(src("qingliao/Features/HomeShortcuts.swift"))
let yml = src("project.yml")
let inboxStore = code(src("qingliao/Core/InboxStore.swift"))
let wakeSrc = code(src("qingliao/Core/BackgroundWake.swift"))
let planSrc = code(src("qingliao/Core/InboxBackgroundPlan.swift"))
let modelsRaw = src("qingliao/Core/Models.swift")

ck("前置：ChatAppDelegate 读到了（cwd 必须是仓库根）", app.count > 2000)
ck("前置：project.yml 读到了", yml.count > 1000)

// ─────────── ② 后台补拉收件箱：接线形态 ───────────

let fetchBody = body(of: "performFetchWithCompletionHandler", in: app)
ck("② performFetch 里两条腿都在（checkStream + checkInbox）",
   fetchBody.contains("checkStream(") && fetchBody.contains("checkInbox("))
ck("② performFetch 不再「只有 stream pending 才动」（旧早退 guard 已移出本方法）",
   !fetchBody.contains("qingliao_stream_pending"))
ck("② 两条腿用同一个聚合器（系统只接受一次 completion）",
   fetchBody.contains("BackgroundFetchAggregator(legs: 2") && fetchBody.split(separator: "agg").count >= 3)

let inboxBody = body(of: "nonisolated static func checkInbox", in: app)
ck("② 收件箱腿：GET /api/inbox", inboxBody.contains("/api/inbox"))
ck("② 收件箱腿带鉴权头 X-Auth-Token", inboxBody.contains("X-Auth-Token"))
ck("② 收件箱腿弹通知走统一入口 NotificationHelper.notify(kind:",
   inboxBody.contains("NotificationHelper.notify(kind:"))
ck("② 判据走纯函数 InboxBackgroundPlan.plan（不在网络层现写规则）",
   inboxBody.contains("InboxBackgroundPlan.plan(items:"))
ck("② 已消费集合读跨层单一真源 InboxKeys.consumedIds",
   inboxBody.contains("InboxKeys.consumedIds"))
ck("② 后台腿不消费条目（不 markDone、不碰 InboxStore 前台注入）",
   !inboxBody.contains("markDone") && !inboxBody.contains("InboxStore"))
ck("② 两条腿都设了超时（后台窗口有限，不许把窗口耗在一次请求上）",
   inboxBody.contains("timeoutInterval") && body(of: "nonisolated static func checkStream", in: app).contains("timeoutInterval"))
ck("② 两条腿的结果都进聚合器（.noData 也要回调，否则另一条腿等不到）",
   inboxBody.contains("agg.finish("))

// ─────────── ③ BGAppRefreshTask：接线形态 ───────────

let regBody = body(of: "func registerBackgroundRefresh", in: app)
ck("③ 注册了后台刷新任务（BGTaskScheduler.shared.register）",
   regBody.contains("BGTaskScheduler.shared.register"))
ck("③ register 用常量 refreshTaskId，不在别处再写一遍字面量",
   regBody.contains("forTaskWithIdentifier: Self.refreshTaskId")
   && !app.contains("forTaskWithIdentifier: \"com.qingliao"))
ck("③ 有 import BackgroundTasks（漏了本地 -parse 照样绿、CI Archive 才报 cannot find type）",
   app.contains("import BackgroundTasks"))
ck("③ registerBackgroundRefresh 在 didFinishLaunching 里被调用（否则永不注册）",
   body(of: "didFinishLaunchingWithOptions", in: app).contains("registerBackgroundRefresh()"))

let tid = literal(after: "static let refreshTaskId = ", in: app) ?? ""
ck("③ 取到 refreshTaskId 字面量", tid == "com.qingliao.app2.refresh")
// ⚠️ 必须**整行相等**：`contains("- com.qingliao.app2.refresh")` 会把
//    "…refresher" 也判绿（子串包含）—— 实测放过过一次，改坏了表还是绿的。
let ymlHasId = yml.split(separator: "\n").contains {
    $0.trimmingCharacters(in: .whitespaces) == "- \(tid)"
}
ck("③ project.yml 白名单 `BGTaskSchedulerPermittedIdentifiers` 里有这个 id（整行相等；真机崩溃的唯一防线）",
   yml.contains("BGTaskSchedulerPermittedIdentifiers:") && ymlHasId)
ck("③ 老 fetch 的最小间隔也报了（不报 = 系统按最懒的档排）",
   regBody.contains("setMinimumBackgroundFetchInterval"))

let schedBody = body(of: "static func scheduleAppRefresh", in: app)
ck("③ 重排走 BGAppRefreshTaskRequest + earliestBeginDate（「不早于」而不是「准时」）",
   schedBody.contains("BGAppRefreshTaskRequest(identifier: refreshTaskId)")
   && schedBody.contains("earliestBeginDate"))
ck("③ submit 失败不静默（有 catch + 日志）",
   schedBody.contains("catch") && schedBody.contains("NSLog"))

let refreshBody = body(of: "nonisolated static func handleAppRefresh", in: app)
ck("③ handleAppRefresh 是 nonisolated（后台队列回调，进 MainActor 体 = SIGTRAP）",
   app.contains("nonisolated static func handleAppRefresh"))
ck("③ 进窗口先排下一次（被收回也不断供）",
   refreshBody.contains("scheduleAppRefresh()"))
ck("③ 挂了 expirationHandler（系统收回窗口时必须收尾）",
   refreshBody.contains("expirationHandler"))
ck("③ 窗口里跑的是与 legacy fetch 同一套两条腿",
   refreshBody.contains("checkStream(") && refreshBody.contains("checkInbox("))
ck("③ 读 Keychain 那步在 MainActor（endpoint 标了 @MainActor，nonisolated 里读不到）",
   app.contains("@MainActor static func endpoint()"))
ck("③ 进后台真入口是 scene delegate 转发（scene 化进程里 applicationDidEnterBackground 永不调用）",
   shortcuts.contains("QingliaoAppDelegate.didEnterBackground()")
   && shortcuts.contains("sceneDidEnterBackground")
   && shortcuts.contains("QingliaoAppDelegate.willEnterForeground()")
   && shortcuts.contains("sceneWillEnterForeground"))

// 聚合器：只回调一次
ck("② 聚合器保证 completion 只回调一次（fired 闸门）",
   app.contains("private var fired = false") && app.contains("if fired {"))
ck("② 聚合器状态全在锁内（@unchecked Sendable + NSLock）",
   app.contains("final class BackgroundFetchAggregator: @unchecked Sendable")
   && app.contains("NSLock()"))
ck("② 过期收尾 force 一次即终局（不会与迟到那条腿各回调一半）",
   app.contains("if force || remaining <= 0 { fired = true }"))

// 台账记账点
ck("③ 两条腿的记账带来源（legacy fetch 与后台任务能分开统计）",
   app.contains("BackgroundWakeLog.record(kind, outcome:"))
ck("③ 记账点：进后台 / 冷启动都在", app.contains("BackgroundWakeLog.record(.entering)")
   && app.contains("BackgroundWakeLog.record(.launch)"))
ck("③ 台账不落通知正文（只记时刻+来源+结果计数）",
   !app.contains("BackgroundWakeLog.record(kind, outcome: it.body")
   && !app.contains("outcome: it.body"))

// 键名单一真源
ck("② 已消费键只在 InboxKeys 里定义一次",
   wakeSrc.contains("static let consumedIds = \"qingliao_inbox_consumed_ids\""))
ck("② InboxStore 用的是这个常量（不再各写一份字面量）",
   inboxStore.contains("private let consumedKey = InboxKeys.consumedIds")
   && !inboxStore.contains("\"qingliao_inbox_consumed_ids\"")
   && !app.contains("\"qingliao_inbox_consumed_ids\""))

// ─────────── ② 纯函数真跑：InboxBackgroundPlan.plan ───────────

let items: [[String: Any]] = [
    ["id": "a", "text": "任务跑完了", "task_type": "reply"],
    ["id": "b", "text": "帮我确认一下", "task_type": "question", "session_id": "s1"],
    ["id": "c", "text": "AI 正在干活", "task_type": "progress"],
    ["id": "d", "text": "   ", "task_type": "reply"],
    ["text": "没有 id", "task_type": "reply"],
    ["id": "e", "text": "目标日报", "task_type": "alert"],
]
let p0 = InboxBackgroundPlan.plan(items: items, consumedIds: [])
ck("plan：只留该弹的 3 条（progress / 空正文 / 无 id 都被剔）", p0.count == 3)
ck("plan：保序（旧→新，通知顺序与队列一致）", p0.map(\.id) == ["a", "b", "e"])
ck("plan：question 带「需要你确认」，其余 detail 为空",
   p0[1].detail == "需要你确认" && p0[0].detail == nil && p0[2].detail == nil)
ck("plan：session_id 透传（点通知能直达会话）", p0[1].sessionId == "s1" && p0[0].sessionId == nil)
ck("plan：前台已消费的跳过（防同一条弹两次）",
   InboxBackgroundPlan.plan(items: items, consumedIds: ["a", "e"]).map(\.id) == ["b"])
ck("plan：一次唤醒最多 5 条（防刷屏）",
   InboxBackgroundPlan.plan(
       items: Array(repeating: ["id": "x", "text": "t", "task_type": "reply"] as [String: Any],
                    count: 9),
       consumedIds: []).count == 5)
ck("plan：limit = 0 → 空（边界不越界）",
   InboxBackgroundPlan.plan(items: items, consumedIds: [], limit: 0).isEmpty)
ck("plan：缺 task_type 时按 reply 处理（老字段名也不炸）",
   InboxBackgroundPlan.plan(items: [["id": "z", "text": "x"]], consumedIds: []).first?.kind == "reply")
ck("plan：空输入 → 空（不崩）",
   InboxBackgroundPlan.plan(items: [], consumedIds: []).isEmpty)
ck("plan：上限常量不是 1（至少能覆盖一次唤醒的多条）", InboxBackgroundPlan.maxPerWake >= 3)

// ─────────── ③ 纯函数真跑：唤醒台账 ───────────

let d0 = Date(timeIntervalSince1970: 1_700_000_000)
let l0 = BackgroundWakeLog.line(at: d0, kind: .fetch, outcome: "newData inbox:2/9")
ck("台账：三段格式（时刻 | 来源 | 结果）", l0.split(separator: "|").count == 3)
ck("台账：时刻可被解析回来（带时区往返不漂）",
   (BackgroundWakeLog.dateOf(l0).map { abs($0.timeIntervalSince(d0)) < 1 }) ?? false)
ck("台账：来源可反查成枚举", BackgroundWakeLog.kindOf(l0) == .fetch)
ck("台账：结果列可取出（统计靠它）", BackgroundWakeLog.outcomeOf(l0) == "newData inbox:2/9")
ck("台账：空结果退化成 `-`（不留空列）",
   BackgroundWakeLog.line(at: d0, kind: .entering, outcome: "  ").hasSuffix("| -"))
ck("台账：坏行不炸（解析失败返回 nil，台账要能容忍手改/截断）",
   BackgroundWakeLog.dateOf("垃圾行") == nil && BackgroundWakeLog.kindOf("垃圾行") == nil)
ck("台账：六类来源都有中文标签",
   BackgroundWakeKind.allCases.allSatisfy { !$0.label.isEmpty }
   && Set(BackgroundWakeKind.allCases.map(\.label)).count == BackgroundWakeKind.allCases.count)

let now = Date(timeIntervalSince1970: 1_800_000_000)
func entry(_ k: BackgroundWakeKind, _ ago: TimeInterval, _ outcome: String) -> String {
    BackgroundWakeLog.line(at: now.addingTimeInterval(-ago), kind: k, outcome: outcome)
}
let ledger = [
    entry(.foreground, 30 * 3600, "newData"),          // 窗口外：不算
    entry(.fetch, 3 * 3600, "newData inbox:1/4"),
    entry(.refreshTask, 2 * 3600, "noData inbox:0/4"),
    entry(.entering, 100, "-"),
]
let sum = BackgroundWakeLog.summary(entries: ledger, now: now, hours: 24)
ck("摘要：只统计窗口内的（30h 前那条不计）", sum.contains("系统叫醒 2 次"))
ck("摘要：报来源分布（后台刷新 / 后台任务各有几条）",
   sum.contains("后台刷新 1") && sum.contains("后台任务 1"))
ck("摘要：取到新数据 / 空转分开算（空转率靠首词 newData 判定）",
   sum.contains("取到新数据 1 次") && sum.contains("空转 1 次"))
ck("摘要：进后台/回前台不算「被叫醒」（否则空转率失真）",
   !sum.contains("系统叫醒 3 次"))
ck("摘要：报最近一次唤醒距今多久", sum.contains("最近一次唤醒"))
ck("摘要：空台账给的是人话（不是崩溃或空串）",
   BackgroundWakeLog.summary(entries: [], now: now).contains("还没有记录"))
ck("摘要：全是坏行也不崩（退化成「还没有记录」）",
   BackgroundWakeLog.summary(entries: ["xxx", "yyy"], now: now).contains("还没有记录"))
ck("摘要：一次都没被叫醒时明确说出来（不许把 0 次说成正常）",
   BackgroundWakeLog.summary(entries: [entry(.entering, 60, "-")], now: now, hours: 24)
       .contains("一次都没叫醒过"))

// ─────────── 发版前两路只读审查抓到的问题（2026-10-16）───────────

// ① P1：question 正文口径必须与前台一致 —— 后台原来塞原始 text（带选项清单），
//    而前台用 `splitQuestion().body`（已剥选项）⇒ 两条正文不同 ⇒ NotificationHelper 的
//    正文哈希 identifier 不同 ⇒ **同一条追问在通知中心留两条**（前后台各自看都"对"）。
ck("问题卡题干切法：分隔行与前台同源（Models.swift 仍以 `选项：` 为独立分隔行）",
   modelsRaw.contains("== \"选项：\""))
ck("问题卡题干切法：真跑一遍（剥选项 / 无分隔行时原样 / 题干是空时兜底回原文）",
   InboxBackgroundPlan.questionBody("先选哪个？\n选项：\n1. A\n2. B") == "先选哪个？"
   && InboxBackgroundPlan.questionBody("  只有题干  ") == "只有题干"
   && InboxBackgroundPlan.questionBody("\n选项：\n1. A") == "\n选项：\n1. A")
ck("plan 对 question 用 questionBody、其他类型用原文",
   planSrc.contains("let body = (type == \"question\") ? questionBody(text) : text"))

// ② P1：BGAppRefreshTask 的「未登录 / 无 endpoint」路径必须 force 收尾
//    否则 `finish` 只把 remaining 减 1（legs=2）→ setTaskCompleted 永不触发 → 每次唤醒白等满窗口
ck("聚合器有 abandon（force 收尾）", app.contains("func abandon(_ r: UIBackgroundFetchResult)"))
ck("未登录路径用 abandon，不用 finish（legs=2 时 finish 永远不会收尾）",
   refreshBody.contains("agg.abandon(.noData)") && !refreshBody.contains("agg.finish(.noData)"))
ck("收尾时摘掉 expirationHandler（否则 task ⇄ agg 互引，每次唤醒漏一对）",
   refreshBody.contains("task.expirationHandler = nil"))
ck("早退路径也记台账（有来源没结果 = 「叫醒几次」统计失真）",
   app.contains("BackgroundWakeLog.record(.refreshTask, outcome: \"noData no-endpoint\")")
   && app.contains("BackgroundWakeLog.record(.fetch, outcome: \"noData no-endpoint\")")
   && app.contains("outcome: \"failed inbox:url\""))

// ③ 台账三处卫生
ck("「最近一次唤醒」只算系统叫醒那两类（回前台/冷启动不算）",
   wakeSrc.contains("let lastWake = parsed.last { $0.1 == .fetch || $0.1 == .refreshTask }"))
ck("摘要：最近一次唤醒取的是系统叫醒那条（末行是「回前台」也不受影响）",
   sum.contains("最近一次唤醒 2 小时前"))
ck("台账窗口带下界（时钟回拨 / 未来行不计入「近 N 小时」）",
   wakeSrc.contains("return d <= window && d >= 0"))
ck("台账时刻用本地时区（默认 GMT → 导出给用户看时所有时刻早 8 小时）",
   wakeSrc.contains("f.timeZone = TimeZone.current"))
ck("台账文件也是环形（只 append 会无限增长，与「最多 limit 条」的承诺不符）",
   wakeSrc.contains("rewriteFile(arr)") && wakeSrc.contains("private static func rewriteFile(")
   && !wakeSrc.contains("appendToFile"))

print("推送及时性 & 后台保活真值表：\(pass) 通过 / \(fail) 失败")
exit(fail == 0 ? 0 : 1)
