// v4.0.118 推送及时性 ①「已知时刻事件预排成本地通知」—— 真值表
//
// 口径（用户 2026-10-16 拍板 ①②③ 三条一起做；本表是第 ① 条）：
//   后台唤醒的时刻由 iOS 定（②③ 只能压时延），而 `UNCalendarNotificationTrigger` 是**系统闹钟**：
//   请求一登记，到点必响 —— App 被杀 / 手机重启 / 从没打开过都照样响。
//   链路：Hermes `push_schedule.py`（读 cron/jobs.json 展开 48h 时刻表）→ 后端 `schedule_api.py`
//   （存 + 校验）→ App `ScheduleStore`（拉清单 → 按 SchedulePlanner 判据排系统通知）。
//
// 为什么必须有这张表（全是**静默失效**：编译过、预检绿，只有真机/隔天才看出来）：
//   ① identifier 每次现造（不带稳定 id）→ 重排变**新增**，同一条任务弹 N 遍；
//   ② 不清孤儿 → 任务被删/时间被改后，旧请求永远留在系统里继续响（用户以为任务没删掉）；
//   ③ 前缀与用户自建提醒（`quick_reminder_`）混用 → 两边对账互删对方的通知；
//   ④ 把过去时刻也排进去 → 一条永远不响的哑通知白占配额（iOS 每 App 上限 64 条）；
//   ⑤ 不设条数上限 → 排满 64 条，把用户自建提醒一起挤掉；
//   ⑥ 拉不到时刻表就清空 → 断网一次把已排好的闹钟全拆了；
//   ⑦ 启动时顺手申请权限 → 和首条推送/提醒页抢同一次系统弹窗，另一处回调拿到 false（v3.9.x 踩过）；
//   ⑧ 登记失败只打日志不上屏 → 「清单里有、到点没响」，用户完全无从查起。
//
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

/// 剥掉行注释（**不动字符串字面量里**的 `//`，否则 URL 类断言会静默失效）
func code(_ text: String) -> String {
    var out: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var inStr = false
        var cut = line.endIndex
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" { inStr.toggle() }
            if !inStr, ch == "/", line.index(after: i) < line.endIndex, line[line.index(after: i)] == "/" {
                cut = i
                break
            }
            i = line.index(after: i)
        }
        out.append(String(line[line.startIndex..<cut]))
    }
    return out.joined(separator: "\n")
}

let plannerSrc = src("qingliao/Core/SchedulePlanner.swift")
let storeSrc = src("qingliao/Core/ScheduleStore.swift")
let copySrc = src("qingliao/Core/QingliaoNotifyCopy.swift")
let appSrc = src("qingliao/QingliaoApp.swift")
let delegateSrc = src("qingliao/Features/Chat/ChatAppDelegate.swift")

let planner = code(plannerSrc)
let store = code(storeSrc)
let copy = code(copySrc)
let app = code(appSrc)
let delegate = code(delegateSrc)

let cal = Calendar.current
/// 固定"现在"（用 Calendar.current 造，跨时区稳定）：2026-10-16 08:00 本地时间
let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 8, minute: 0))!
let h = 3600.0

func notice(_ id: String, _ title: String, at: Date, note: String? = nil) -> ScheduledNotice {
    ScheduledNotice(id: id, title: title, fireAt: at.timeIntervalSince1970, note: note)
}

// MARK: - 0. 文件都在（路径写错会让下面全变成"空文件通过"）

ck("SchedulePlanner.swift 读到内容", plannerSrc.count > 800)
ck("ScheduleStore.swift 读到内容", storeSrc.count > 800)
ck("QingliaoNotifyCopy.swift 读到内容", copySrc.count > 1000)
ck("QingliaoApp.swift 读到内容", appSrc.count > 500)
ck("ChatAppDelegate.swift 读到内容", delegateSrc.count > 500)

// MARK: - 1. 后端解析（坏条目逐条丢，不整批失败）

let goodBody: [String: Any] = ["ok": true, "items": [
    ["id": "a_1", "jobId": "a", "title": "每日早报", "fireAt": now.addingTimeInterval(2 * h).timeIntervalSince1970],
    ["id": "b_2", "jobId": "b", "title": "收盘播报", "fireAt": 1_770_000_000, "note": "定时任务"],
]]
let good = SchedulePlanner.parse(goodBody)
ck("解析正常响应：两条", good.count == 2)
ck("解析出 id/title/fireAt", good.first?.id == "a_1" && good.first?.title == "每日早报")
ck("note 空串归成 nil（不塞空串给通知）",
   SchedulePlanner.parse(["items": [["id": "c_1", "title": "x", "fireAt": 1, "note": "   "]]]).first?.note == nil)

let dirty = SchedulePlanner.parse(["items": [
    ["id": "", "title": "无 id", "fireAt": 1],
    ["id": "d_1", "title": "  ", "fireAt": 1],
    ["id": "e_1", "title": "无时刻", "fireAt": 0],
    ["id": "e_2", "title": "时刻是字符串", "fireAt": "明天"],
    "整条不是字典",
    ["id": "f_1", "title": "好条目", "fireAt": 1_770_000_000],
]])
ck("脏数据逐条丢弃，只留合法那一条", dirty.count == 1 && dirty.first?.id == "f_1")

let dup = SchedulePlanner.parse(["items": [
    ["id": "g_1", "title": "第一次", "fireAt": 1_770_000_000],
    ["id": "g_1", "title": "重复下发", "fireAt": 1_770_000_000],
]])
ck("同一 id 重复下发只留一条（防后端重投）", dup.count == 1 && dup.first?.title == "第一次")

ck("非字典体不崩、返回空", SchedulePlanner.parse(["items": "不是数组"]).isEmpty)

// MARK: - 2. 排期判据（plan）

let items = [
    notice("past_0", "昨天的", at: now.addingTimeInterval(-h)),          // 已过
    notice("soon_1", "马上到", at: now.addingTimeInterval(10)),          // 太近
    notice("ok_2", "今天晚点", at: now.addingTimeInterval(2 * h)),
    notice("ok_3", "明早", at: now.addingTimeInterval(24 * h)),
    notice("far_4", "两天半后", at: now.addingTimeInterval(60 * h)),     // 超窗口
    notice("ok_5", "后天", at: now.addingTimeInterval(47 * h)),
]
let plan = SchedulePlanner.plan(items: items, now: now)
ck("过期的条目不排（排了就是永远不响的哑通知）", !plan.contains { $0.id == "past_0" })
ck("60s 内的不排（登记完成时已过去，系统直接丢）", !plan.contains { $0.id == "soon_1" })
ck("48h 外的不排（窗口外）", !plan.contains { $0.id == "far_4" })
ck("窗口内三条全排上", plan.count == 3)
ck("按时刻升序（用户看清单/系统按序触发都对）",
   plan.map { $0.fireAt } == plan.map { $0.fireAt }.sorted())

let many = (0..<30).map { notice("m_\($0)", "任务\($0)", at: now.addingTimeInterval(Double($0 + 5) * h)) }
ck("超上限截断到 maxPending（iOS 每 App 上限 64 条挂起通知）",
   SchedulePlanner.plan(items: many, now: now).count == SchedulePlanner.maxPending)
ck("截断取的是**最近**的 N 条",
   SchedulePlanner.plan(items: many, now: now).first?.id == "m_0")
ck("limit=0 时一条不排", SchedulePlanner.plan(items: many, now: now, limit: 0).isEmpty)

// MARK: - 3. identifier 与孤儿清理（最容易出静默故障的两处）

let one = notice("job_123_1770000000", "每日早报", at: now.addingTimeInterval(h))
let ident = SchedulePlanner.identifier(for: one)
ck("identifier = 固定前缀 + 后端稳定 id", ident == "ql_sched_job_123_1770000000")
ck("前缀与用户自建提醒不同（混用会互删通知）",
   !ident.hasPrefix("quick_reminder_") && SchedulePlanner.identifierPrefix != "quick_reminder_")

let pending = [
    "ql_sched_job_123_1770000000",   // 本次清单里有 → 留
    "ql_sched_job_456_1770009999",   // 清单里没有 → 孤儿（任务删了/时间改了）
    "quick_reminder_abc",            // 用户自建提醒 → **绝对不许动**
    "other_prefix_x",                // 别人家的 → 不动
]
let known: Set<String> = ["ql_sched_job_123_1770000000"]
let gone = SchedulePlanner.orphans(pending: pending, known: known)
ck("孤儿只挑「本前缀且不在清单」的那条", gone == ["ql_sched_job_456_1770009999"])
ck("清理不碰用户自建提醒（quick_reminder_）", !gone.contains("quick_reminder_abc"))
ck("清理不碰无关前缀", !gone.contains("other_prefix_x"))

// MARK: - 4. 文案与路径（可本机验证的部分都在 SchedulePlanner）

ck("timeText 今天", SchedulePlanner.timeText(for: notice("t1", "x", at: now.addingTimeInterval(h)), now: now) == "今天 09:00")
ck("timeText 明天",
   SchedulePlanner.timeText(for: notice("t2", "x", at: cal.date(byAdding: .day, value: 1, to: now)!), now: now) == "明天 08:00")
ck("timeText 更远给日期",
   SchedulePlanner.timeText(for: notice("t3", "x", at: cal.date(byAdding: .day, value: 2, to: now)!), now: now) == "10-18 08:00")
ck("timeText 一定给出 HH:mm（预排通知必须让人知道是几点的事）",
   SchedulePlanner.timeText(for: notice("t4", "x", at: now.addingTimeInterval(h)), now: now).contains(":"))
ck("bodyText 带任务名 + 说的是「查看」不是「已生成」",
   SchedulePlanner.bodyText(for: one).contains("每日早报") && SchedulePlanner.bodyText(for: one).contains("打开轻聊"))
ck("userInfo 键名稳定", SchedulePlanner.userInfoKey == "qingliao_schedule")
ck("路径走 /api/agent/schedule（lucky/relay/nginx 只放行 /api/agent 前缀，实测三入口 401=已路由）",
   SchedulePlanner.path == "/api/agent/schedule")
ck("常量齐备（上限 24 / 最少提前 60s / 窗口 48h）",
   SchedulePlanner.maxPending == 24 && SchedulePlanner.minLead == 60 && SchedulePlanner.horizon == 48 * 3600)

// MARK: - 5. 通知类别：新增「轻聊·定时」（真跑 QingliaoNotifyCopy —— 纯 Foundation 可编译）

ck("新增 .scheduled 类别", QingliaoNotifyKind.scheduled.rawValue == "scheduled")
ck(".scheduled 标题 = 【轻聊·定时】", QingliaoNotifyKind.scheduled.title == "【轻聊·定时】")
ck("前缀与 .reminder 不撞（否则快捷指令分不清来源）",
   QingliaoNotifyKind.scheduled.prefix != QingliaoNotifyKind.reminder.prefix)
ck("所有类别前缀都非空且互不相同", {
    let ps = QingliaoNotifyKind.allCases.map { $0.prefix }
    return !ps.contains("") && Set(ps).count == ps.count
}())
ck("类别表覆盖 .scheduled（prefix switch 不漏）", copy.contains("case .scheduled: return \"轻聊·定时\""))

// MARK: - 6. 接线源级断言（防"文件躺着、没人调"）

ck("ScheduleStore 调 SchedulePlanner.plan（判据不在 store 里重写一遍）", store.contains("SchedulePlanner.plan("))
ck("ScheduleStore 用 SchedulePlanner.identifier（不许现造 identifier 字面量）",
   store.contains("SchedulePlanner.identifier(for:") && !store.contains("\"ql_sched_"))
ck("ScheduleStore 清孤儿：removePendingNotificationRequests(withIdentifiers: gone)",
   store.contains("removePendingNotificationRequests(withIdentifiers: gone)"))
ck("ScheduleStore 调 orphans 判据", store.contains("SchedulePlanner.orphans("))
ck("ScheduleStore 只**读**权限，不申请（抢系统弹窗会让另一处拿到 false）",
   store.contains("notificationSettings()") && !store.contains("requestAuthorization"))
ck("未授权时只跳过、不排（authStatus 判 .authorized/.provisional）",
   store.contains(".authorized") && store.contains(".provisional"))
ck("登记走 UNCalendarNotificationTrigger 且 repeats=false（每条都是具体某次出现）",
   store.contains("UNCalendarNotificationTrigger(") && store.contains("repeats: false"))
ck("登记失败能上屏（lastError 而非只 NSLog）", store.contains("lastError"))
ck("拉不到时刻表时不撤已排通知（fulfill 失败只用旧清单继续对账）",
   store.contains("if let list = await fetch(auth)") && store.contains("items = list"))
ck("通知标题走统一分类表（compose 用 .scheduled）", store.contains("compose(.scheduled"))
ck("threadIdentifier 固定（通知中心成组）", store.contains("threadIdentifier = \"qingliao_schedule\""))
ck("userInfo 用常量键（不写字面量）",
   store.contains("[SchedulePlanner.userInfoKey: item.id]") && !store.contains("\"qingliao_schedule\":"))

ck("App 启动接线：ScheduleStore 注入 auth", app.contains("ScheduleStore.shared.attach(auth: auth)"))
ck("App 启动接线：真拉了清单（attach 后必须调 refreshAndReconcile）",
   app.contains("ScheduleStore.shared.refreshAndReconcile()"))
ck("回前台重排（scene 化进程的真入口链路里调）",
   delegate.contains("ScheduleStore.shared.refreshAndReconcile()"))
ck("回前台重排挂在 willEnterForeground 里（不是 applicationDidBecomeActive —— 同 scene 化坑）",
   delegate.contains("static func willEnterForeground()"))

// ─────────── 清孤儿用「该保留集」而不是「本次登记集」（发版前审查抓到的 P0） ───────────
//
// 真事故形态：08:00 那条通知在 07:58:30 回前台时排上；用户 07:59:30 再回前台 →
// `plan` 的「60s 内不排」把它滤掉 → 若拿 plan 当保留集，它就被当**孤儿删掉** → 08:00 静默不响。
// 而「每次回前台都重排」是本功能的既定口径（真值表上一段刚钉过）⇒ 这个窗口必然被踩到。
// 同类：48h 窗口 / 上限 24 条把条目滤出去时，也会把**已经排好**的请求删掉（排上→删掉→再排上 抖动）。

ck("清孤儿用保留集（未过期的清单项）而不是本次登记集",
   store.contains("let retain = Set(items.filter { $0.fireAt > now }"))
ck("清孤儿不再拿 plan 当保留集（旧写法会把即将到点的已排通知删掉）",
   !store.contains("orphans(pending: pending, known: known)")
   && store.contains("orphans(pending: pending, known: retain)"))
ck("未授权只跳过登记、不提前 return（否则旧挂起请求永远留在系统里占 64 条配额）",
   !store.contains("guard settings.authorizationStatus == .authorized")
   && store.contains("let plan = authorized ? SchedulePlanner.plan(items: items, now: Date()) : []"))
ck("登记计数只认「真排成功」的条数（报「打算排」的数 = 另一种静默失效）",
   store.contains("scheduledCount = registered") && store.contains("registered += 1"))
ck("ObservableObject 显式 import Combine（Foundation 不 re-export，靠别的框架碰巧能过）",
   storeSrc.contains("import Combine"))

// MARK: - 结果

print("推送及时性 ①（预排已知时刻事件）真值表：\(pass) 通过 / \(fail) 失败")
if fail == 0 {
    print("🎉 全部通过")
} else {
    print("❌ 有护栏失守")
}
exit(fail == 0 ? 0 : 1)
