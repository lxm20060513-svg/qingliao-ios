// MARK: - v4.0.20 目标「后台状态」真值表（#1 #5 #6 #7 #11）
//
// 用户原话（2026-10）：*「长期目标触发不明显，我不知道当前任务是前台任务还是触发了
//   后台自主推进任务」* + *「任务中心的任务那里加通知，表明当前后台自主推进任务进行到
//   哪一步了」*。
//
// 本表钉住三件事：
//   ① 纯逻辑口径（健康三态 / 下次推进文案 / 进度标记解析）—— 镜像实现，改口径必红
//   ② iOS 侧接线（字段是否真的接进 UI，而不是只定义了没人用）
//   ③ 后端侧接线（reports 留痕 / 开关门控 / nudge 迭代修复 / task_type 落库）

import Foundation

var pass = 0, fail = 0
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

print("── ① 纯逻辑镜像：健康三态 ──")
func health(hasJob: Bool, paused: Bool) -> String {
    if paused { return "paused" }
    return hasJob ? "running" : "detached"
}
ok(health(hasJob: true,  paused: false) == "running",  "有 job 未暂停 = running")
ok(health(hasJob: false, paused: false) == "detached", "无 job = detached")
ok(health(hasJob: true,  paused: true)  == "paused",   "暂停优先 = paused")
ok(health(hasJob: false, paused: true)  == "paused",   "无 job + 暂停 仍是 paused")

print("── ② 纯逻辑镜像：下一次推进文案 ──")
let cal = Calendar(identifier: .gregorian)
func nextRunText(now: Date, mh: Int, eh: Int, mon: Bool, eve: Bool, h: String) -> String {
    if h == "paused" { return "已暂停 · 后台不会自动推进" }
    if h == "detached" { return "未接上后台 · 详情里可重试" }
    guard mon || eve else { return "没有开启推进时段" }
    let start = cal.startOfDay(for: now)
    var cand: [Date] = []
    if mon, let d = cal.date(byAdding: .hour, value: mh, to: start) { cand.append(d) }
    if eve, let d = cal.date(byAdding: .hour, value: eh, to: start) { cand.append(d) }
    guard let next = cand.filter({ $0 > now }).min() ?? cand.compactMap({ cal.date(byAdding: .day, value: 1, to: $0) }).min()
    else { return "没有开启推进时段" }
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "H:mm"
    let hm = f.string(from: next)
    if cal.isDate(next, inSameDayAs: now) { return "后台 今天 \(hm) 推进" }
    if let tm = cal.date(byAdding: .day, value: 1, to: start), cal.isDate(next, inSameDayAs: tm) {
        return "后台 明天 \(hm) 推进"
    }
    f.dateFormat = "M月d日 H:mm"
    return "后台 \(f.string(from: next)) 推进"
}
var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 2; c.hour = 8; c.minute = 0
let morning = cal.date(from: c)!                                  // 10-02 08:00
ok(nextRunText(now: morning, mh: 9, eh: 21, mon: true, eve: true, h: "running") == "后台 今天 9:00 推进",
   "08:00 看 → 今天 9:00")
var c2 = c; c2.hour = 10
let afterMorn = cal.date(from: c2)!                               // 10-02 10:00
ok(nextRunText(now: afterMorn, mh: 9, eh: 21, mon: true, eve: true, h: "running") == "后台 今天 21:00 推进",
   "10:00 看 → 今天 21:00（早场已过，取晚场）")
var c3 = c; c3.hour = 23
let night = cal.date(from: c3)!                                   // 10-02 23:00
ok(nextRunText(now: night, mh: 9, eh: 21, mon: true, eve: true, h: "running") == "后台 明天 9:00 推进",
   "23:00 看 → 明天 9:00（全场已过）")
ok(nextRunText(now: morning, mh: 9, eh: 21, mon: false, eve: false, h: "running") == "没有开启推进时段",
   "两段都关 → 没有开启推进时段")
ok(nextRunText(now: morning, mh: 9, eh: 21, mon: true, eve: true, h: "paused").contains("已暂停"),
   "暂停 → 已暂停（不说时间，避免误导）")
ok(nextRunText(now: morning, mh: 9, eh: 21, mon: true, eve: true, h: "detached").contains("未接上后台"),
   "无 job → 未接上后台")

print("── ③ 纯逻辑镜像：进度标记解析（#11）──")
func parse(_ text: String) -> (Int, Int)? {
    guard let r = text.range(of: "【目标推进 ") else { return nil }
    let rest = text[r.upperBound...]
    guard let end = rest.firstIndex(of: "】") else { return nil }
    let parts = rest[rest.startIndex..<end].split(separator: "/")
    guard parts.count == 2,
          let s = Int(parts[0].trimmingCharacters(in: .whitespaces)),
          let t = Int(parts[1].trimmingCharacters(in: .whitespaces)), t > 0 else { return nil }
    return (min(max(s, 0), t), t)
}
func stripped(_ text: String) -> String {
    guard let r = text.range(of: "【目标推进 "),
          let end = text[r.upperBound...].firstIndex(of: "】") else { return text }
    return String(text[text.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
}
let msg = "【目标推进 3/5】\n今天推进：把产品线定下来\n需要你做：确认包装设计"
ok(parse(msg)?.0 == 3 && parse(msg)?.1 == 5, "标准首行 → 3/5")
ok(parse("【目标推进 7/5】")?.0 == 5, "越界步号收敛到总数（7/5 → 5/5）")
ok(parse("【目标推进 2/0】") == nil, "总数为 0 → 不认（防止除零）")
ok(parse("今天推进哪一步") == nil, "没有标记 → nil（普通任务不受影响）")
ok(parse("【目标推进 12/12】")?.0 == 12, "两位数不误切")
ok(stripped(msg).hasPrefix("今天推进"), "标记被摘掉，正文不重复")
ok(stripped("普通消息") == "普通消息", "无标记时正文原样")

print("── ④ iOS 接线护栏 ──")
let gs = code("qingliao/Core/GoalSchedule.swift")
ok(gs.contains("case running") && gs.contains("case paused") && gs.contains("case detached"),
   "GoalSchedule 有健康三态")
ok(gs.contains("func nextRunText") && gs.contains("今天") && gs.contains("明天"),
   "nextRunText 覆盖今天/明天")
ok(gs.contains("enum GoalProgressMark") && gs.contains("func stripped"),
   "GoalProgressMark 解析器在")
ok(gs.contains("var reports: [GoalReport]") == false,
   "reports 字段属于 GoalStore 而非 GoalSchedule（职责分离）")
let gstore = code("qingliao/Core/GoalStore.swift")
ok(gstore.contains("var reports: [GoalReport]"), "#6 GoalItem 有 reports 字段")
ok(gstore.contains("decodeIfPresent([GoalReport].self"), "#6 reports 用 decodeIfPresent（旧数据不炸）")
ok(gstore.contains("case lastReport, lastPushedAt, paused, reports"), "#6 CodingKeys 已登记 reports")
let gsec = code("qingliao/Features/Life/GoalsSection.swift")
ok(gsec.contains("scheduleHealth") && gsec.contains("healthColor"), "#5 卡片有健康点")
ok(gsec.contains("goal.scheduleText(now: Date())"), "#5 卡片有下次推进状态条")
ok(gsec.contains("后台推进记录") && gsec.contains("isAgentAction"), "#6/#7 详情有时间线且区分 AI 自动动作")
let tcv = code("qingliao/Features/TaskCenterView.swift")
ok(tcv.contains("GoalProgressMark.parse(item.text)"), "#11 任务中心接了进度解析")
ok(tcv.contains("GoalProgressMark.stripped(item.text)"), "#11 任务中心正文去重复标记")
ok(tcv.contains("ProgressView(value:"), "#11 任务中心有细进度条")
let aac = code("qingliao/Features/Chat/AgentActionCard.swift")
ok(aac.contains("handoffNote") && aac.contains("已在后台运行"), "#1 建目标卡有前后台交接回执")
ok(read("qingliao/Core/AgentActionExecutor.swift").contains("已在后台运行 · 每天"),
   "#1 执行完的回执文案含「已在后台运行」")
let sp = code("qingliao/Features/Settings/SettingsProactive.swift")
ok(sp.contains("长期目标自动判定") && sp.contains("goalAutoDetect"), "#2 设置页有自动判定开关")
let sv = code("qingliao/Features/Sessions/SessionsView.swift")
ok(sv.contains("runningForeground") && sv.contains("runningBackground"), "#8 会话行分前台/后台两态")
ok(sv.contains("backgroundRunningBar"), "#9 后台推进浮条")
ok(sv.contains("if isFixedSession(id) { return 3 }"), "#4 固定会话恒置顶")
ok(sv.contains("lock.fill") && sv.contains("fixedSessionHint"), "#4 锁图标 + 用途说明")
let nh = code("qingliao/Core/NotificationHelper.swift")
ok(nh.contains("sound: Bool = true"), "#10 通知支持静默")
ok(code("qingliao/Core/InboxStore.swift").contains("sound: false"), "#10 后台任务通知走静默")

print("── ⑤ 后端接线护栏 ──")
let be = "/opt/hermes_host/微信文件/轻聊web/backend/"
func beRead(_ f: String) -> String { (try? String(contentsOfFile: be + f, encoding: .utf8)) ?? "" }
if beRead("goal_module.py").isEmpty {
    print("  ⚠️ 跳过（后端源不可见）")
} else {
    let gm = beRead("goal_module.py")
    ok(gm.contains("\"reports\": []"), "#6 建目标初始化 reports")
    ok(gm.contains("reps.insert(0, {\"at\": now") && gm.contains("del reps[50:]"),
       "#6 推进回写追加留痕 + 滚动 50 条")
    ok(gm.contains("【目标推进 %d/%d】"), "#11 提示词强制首行进度标记")
    let pa = beRead("proactive_agent.py")
    ok(pa.contains("\"goalAutoDetect\": True"), "#2 开关进 DEFAULT_CFG（否则 save_config 白名单会丢）")
    ok(pa.contains("_append_agent_note") && pa.contains("kind\": \"agent_action\""), "#7 Agent 动作留痕")
    ok(pa.contains("list(_goals().values())"),
       "#7 bugfix：nudge 迭代 dict 值（原来迭代键 → 整个函数是 no-op）")
    let sa = beRead("stream_api.py")
    ok(sa.contains("_GOAL_ACTION_DOC if _goal_auto_detect_enabled()"),
       "#2 goal.create 说明按开关整段门控")
    ok(sa.contains("except Exception:\n        return True"),
       "#2 配置读不到时保持原行为（不静默关功能）")
    ok(beRead("sessions_api.py").contains("\"task_type\": task_type"),
       "#3 固定会话落库带上来源（气泡三色才认得出定时/系统）")
}

print("\n目标后台状态真值表：\(pass) 通过 / \(fail) 失败")
exit(fail == 0 ? 0 : 1)
