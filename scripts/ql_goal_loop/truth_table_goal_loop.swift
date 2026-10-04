// MARK: - v4.0.44 长期目标「后台推进闭环」真值表（用户 7 条要求的 ③④⑤⑥）
//
// 用户 2026-10-04 原始 7 条要求里，本表钉住这 4 条：
//   ③ 后台推进需要我确认的 → 推**可点选/可手输的确认卡**到投递中心，回复要回传后端任务会话
//   ④ 某步完成 → 待办清单与目标卡片都划掉；下一步要标「进行中」或「预计 X 开始」
//   ⑤ 每步完成 → 推一条完成消息到轻聊投递会话
//   ⑥ 步骤清单带显式完成顺序（「第 N 步」）
//
// 本表钉住三件事：
//   ① 纯逻辑口径（nextRunMomentText 时刻短语 + 与 nextRunText 的单一真源关系）—— 改口径必红
//   ② iOS 源级接线（步骤序号真上屏 / 下一步状态标真挂在卡片 / 纯逻辑真被卡片用）
//   ③ 后端源级接线（报告回写入口 / 每步完成通知 / 单步待办联动 / 确认卡 + 答案回写 / cron 桥）
//
// 🚨 与 ql_goalbg（后台状态可见性）、ql_goal_pushnow（手动推进 + 收尾闭环）的分工：
//    本表钉「**后台**推进闭环」—— 报告回写、每步通知、确认卡、步骤序号。
//
// 编译运行（仓库根目录，权威入口 = check_swift.sh 第 69 段）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_goal_loop scripts/ql_goal_loop/truth_table_goal_loop.swift
// 本表**不编译真源**（GoalSchedule.swift 里 GoalItem 扩展依赖 GoalStore.swift，而后者 import SwiftUI，
// 本机无 SwiftUI）：走「镜像纯逻辑 + 剥注释后的源级断言」，与 ql_goal_pushnow（第 68 段）同口径。

import Foundation

nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0
func ok(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("  ✅ \(name)") } else { fail += 1; print("  ❌ \(name)") }
}

let repo = ProcessInfo.processInfo.environment["QL_REPO"] ?? "."
func read(_ rel: String) -> String { (try? String(contentsOfFile: repo + "/" + rel, encoding: .utf8)) ?? "" }

/// 剥注释：护栏只认代码形态，防「注释里写了就算过」（ql_goalbg / ql_goal_pushnow 同款）
func stripComments(_ s: String) -> String {
    var out = ""
    for ln in s.split(separator: "\n", omittingEmptySubsequences: false) {
        let t = ln.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("//") || t.hasPrefix("*") || t.hasPrefix("/*") { continue }
        out += ln + "\n"
    }
    return out
}
func code(_ rel: String) -> String { stripComments(read(rel)) }

// ── ① nextRunMomentText 镜像（口径源：Core/GoalSchedule.swift）──────────────
let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return c
}()
let hm: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "H:mm"; f.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return f
}()
let dayHm: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "M月d日 H:mm"; f.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return f
}()
func at(_ s: String) -> Date {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return f.date(from: s)!
}

/// 镜像 GoalSchedule.nextRun 的取时刻口径
func nextRun(now: Date, morning: Int, evening: Int,
             morningOn: Bool, eveningOn: Bool, running: Bool) -> Date? {
    guard running, morningOn || eveningOn else { return nil }
    let start = cal.startOfDay(for: now)
    var cands: [Date] = []
    if morningOn, let d = cal.date(byAdding: .hour, value: morning, to: start) { cands.append(d) }
    if eveningOn, let d = cal.date(byAdding: .hour, value: evening, to: start) { cands.append(d) }
    guard !cands.isEmpty else { return nil }
    if let today = cands.filter({ $0 > now }).min() { return today }
    return cands.compactMap { cal.date(byAdding: .day, value: 1, to: $0) }.min()
}

/// 镜像 GoalSchedule.nextRunMomentText（v4.0.44 新增）
func nextRunMoment(now: Date, morning: Int, evening: Int,
                   morningOn: Bool, eveningOn: Bool, running: Bool) -> String? {
    guard let next = nextRun(now: now, morning: morning, evening: evening,
                             morningOn: morningOn, eveningOn: eveningOn, running: running) else { return nil }
    let t = hm.string(from: next)
    if cal.isDate(next, inSameDayAs: now) { return "今天 \(t)" }
    if let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)),
       cal.isDate(next, inSameDayAs: tomorrow) { return "明天 \(t)" }
    return dayHm.string(from: next)
}

print("── ① 下一步「预计 X 开始」的时刻口径 ──")
// 目标默认早 9:00 / 晚 21:00
ok(nextRunMoment(now: at("2026-10-04 08:00"), morning: 9, evening: 21, morningOn: true, eveningOn: true, running: true)
   == "今天 9:00", "早上未过点 → 今天 9:00")
ok(nextRunMoment(now: at("2026-10-04 12:00"), morning: 9, evening: 21, morningOn: true, eveningOn: true, running: true)
   == "今天 21:00", "早段已过 → 取最近的晚段（今天 21:00）")
ok(nextRunMoment(now: at("2026-10-04 22:00"), morning: 9, evening: 21, morningOn: true, eveningOn: true, running: true)
   == "明天 9:00", "两段都过 → 明天 9:00（不许说「今天」）")
ok(nextRunMoment(now: at("2026-10-04 23:00"), morning: 9, evening: 21, morningOn: false, eveningOn: true, running: true)
   == "明天 21:00", "只开晚段 → 明天 21:00")
ok(nextRunMoment(now: at("2026-10-04 08:00"), morning: 9, evening: 21, morningOn: false, eveningOn: true, running: true)
   == "今天 21:00", "只开晚段且今天未过 → 今天 21:00")
// 反例：后台不会自己动 → 必须 nil（卡片退化成「待开始」，**不许编时间**）
ok(nextRunMoment(now: at("2026-10-04 08:00"), morning: 9, evening: 21, morningOn: true, eveningOn: true, running: false) == nil,
   "反例：后台暂停/未接上 → nil（不编「预计」时间）")
ok(nextRunMoment(now: at("2026-10-04 08:00"), morning: 9, evening: 21, morningOn: false, eveningOn: false, running: true) == nil,
   "反例：两段都关 → nil")
// 单项口径：状态标文案（镜像 GoalsSection.nextStepStatusMark 的三分支）
func mark(started: Bool, moment: String?) -> String {
    started ? "进行中" : (moment.map { "预计 \($0) 开始" } ?? "待开始")
}
ok(mark(started: true, moment: "明天 9:00") == "进行中", "已开始 → 进行中（有时刻也只说进行中）")
ok(mark(started: false, moment: "明天 9:00") == "预计 明天 9:00 开始", "未开始 → 预计 X 开始")
ok(mark(started: false, moment: nil) == "待开始", "反例：编不出时刻 → 待开始，不硬凑时间")

print("── ② iOS 源级接线 ──")
let gschedule = code("qingliao/Core/GoalSchedule.swift")
ok(gschedule.contains("static func nextRunMomentText("), "GoalSchedule 有 nextRunMomentText")
ok(gschedule.contains("guard let moment = nextRunMomentText("), "nextRunText 复用 nextRunMomentText（单一真源，不各写一套）")
ok(gschedule.contains("\"今天 \\(hm)\"") && gschedule.contains("\"明天 \\(hm)\""), "时刻短语格式在真源里（今天/明天 + H:mm）")
ok(gschedule.contains("func nextRunMoment(now: Date) -> String?"), "GoalItem 上有便捷取法（视图层唯一入口）")
ok(gschedule.contains("guard health == .running, morningEnabled || eveningEnabled else { return nil }"),
   "只在后台会自己动时才给时刻（反例口径不变）")

let gsec = code("qingliao/Features/Life/GoalsSection.swift")
// ⑥ 步骤序号
ok(gsec.contains("ForEach(Array(g.steps.enumerated()), id: \\.element.id)"),
   "⑥ 步骤行用 enumerated + element.id（序号上屏、身份不变）")
ok(gsec.contains("\"第\\(idx + 1)步\""), "⑥ 步骤清单显示「第N步」")
ok(gsec.contains(".foregroundStyle(.tertiary)") && gsec.contains(".monospacedDigit()"),
   "⑥ 序号有独立视觉层级（tertiary + 等宽数字，真渲染出文本）")
// ④ 下一步状态标
ok(gsec.contains("nextStepStatusMark(goal, s)"), "④ 下一步行挂了状态标")
ok(gsec.contains("func nextStepStatusMark("), "④ 状态标有实现")
// ④ 审查抓到的真缺陷类：定义与调用必须落在**同一个 struct** 里。
//    跨类型裸调用（定义在 GoalsSection、调用在平级的 GoalRowCard）本机 -parse 全绿、CI Archive 必炸。
//    判法：各自往前找最近一条顶层 `struct` 声明，比名字（不比先后顺序——定义可能追加在调用之后）。
func enclosingStruct(_ src: String, _ pos: String.Index?) -> String {
    guard let pos = pos else { return "" }
    let names = String(src[src.startIndex..<pos]).components(separatedBy: "\n")
        .filter { $0.hasPrefix("struct ") || $0.hasPrefix("private struct ") }
    return names.last ?? ""
}
let defOwner = enclosingStruct(gsec, gsec.range(of: "func nextStepStatusMark(")?.lowerBound)
let callOwner = enclosingStruct(gsec, gsec.range(of: "nextStepStatusMark(goal, s)")?.lowerBound)
ok(!defOwner.isEmpty && defOwner == callOwner,
   "④ 状态标的定义与调用在同一 struct 内（跨类型裸调用 CI 必炸）：\(defOwner) / \(callOwner)")
ok(gsec.contains("\"进行中\""), "④ 有「进行中」文案")
ok(gsec.contains("\"预计 \\($0) 开始\""), "④ 有「预计 X 开始」文案")
ok(gsec.contains("\"待开始\""), "④ 反例兜底：编不出时刻时不编时间")
ok(gsec.contains("goal.nextRunMoment(now: Date())"), "④ 时刻真从 GoalSchedule 取（不是本地硬编码）")
ok(gsec.contains("let started = s.startedAt != nil"), "④ 进行中判据 = 该步已有 startedAt")

// ── ③ 后端源级接线 ─────────────────────────────────────────────
print("── ③④⑤ 后端接线 ──")
let be = "/opt/hermes_host/微信文件/轻聊web/backend/"
func beRead(_ f: String) -> String { (try? String(contentsOfFile: be + f, encoding: .utf8)) ?? "" }

if beRead("goal_module.py").isEmpty {
    print("  ⚠️ 跳过（后端源不可见；本地覆盖：ql backend fetch）")
} else {
    let gm = beRead("goal_module.py")
    // ③① 报告回写入口（cron 桥用它，按 cronJobID 精确匹配 —— 不靠 job 名猜）
    ok(gm.contains("def goals_report_from_cron("), "① 有 cron 回写入口 goals_report_from_cron")
    ok(gm.contains("cronJobIDs") && gm.contains("cronJobID"), "① 按 cronJobID 匹配（也兼容老字段）")
    ok(gm.contains("\"skipped\": True"), "① 非目标 job → skipped（不算失败，桥照常推进游标）")
    ok(gm.contains("or _parse_done_steps(report)"), "① 桥没带 doneSteps 时从正文兜底解析")
    // ④⑤ 每步完成：划待办 + 推投递
    ok(gm.contains("def _notify_step_done("), "⑤ 每步完成有通知函数")
    ok(gm.contains("def _sync_todos_steps("), "④ 单步完成有针对性划待办（不是只在全完成时一把划）")
    ok(gm.contains("if newly:") && gm.contains("_sync_todos_steps(gid,"), "④⑤ 报告回写后真的调它们")
    ok(gm.contains("asking = \"✅ 第 %d/%d 步已完成") || gm.contains("第 %d/%d 步已完成"), "⑤ 通知文案带第几步/共几步")
    // ③ 确认卡 + 答案回写
    ok(gm.contains("def _ask_user("), "③ 有确认卡推送函数")
    ok(gm.contains("task_type=\"question\""), "③ 用 question 卡（可点选/可手输），不是纯文本")
    ok(gm.contains("选项："), "③ 卡片带「选项：」段（App 才会渲染成按钮）")
    ok(gm.contains("def _watch_answer(") && gm.contains("def _apply_answer("), "③ 有等答案 + 落地函数")
    ok(gm.contains("def _inject_to_session("), "③ 答案会注入原会话（用户能看到闭环）")
    ok(gm.contains("read_answer("), "③ 走既有答案读取口径")
    // ④ 进行中作业带步骤
    ok(gm.contains("def _current_step_text("), "④ 有「第 k/N 步」文案函数")
    ok(gm.contains("\"正在推进 %s\" % step_txt"), "④ 进行中作业详情带步骤")
    // 提示词机器段
    ok(gm.contains("完成步骤："), "提示词要求输出「完成步骤：N」（机器可读）")
    ok(gm.contains("选项：<"), "提示词要求输出「选项：」（供确认卡按钮）")

    let ia = beRead("inbox_api.py")
    ok(ia.contains("goal_report=None"), "① inbox push 接受 goal_report")
    ok(ia.contains("goals_report_from_cron("), "① 同进程直调回写（零新增路由）")
    ok(ia.contains("\"goal_ok\": goal_ok"), "① 响应如实回报 goal_ok（桥据此决定是否重试）")
    ok(ia.contains("or bool(res.get(\"skipped\"))"), "① skipped 不算失败（否则游标卡死无限重试）")
    // ── v4.0.44 审查修复钉桩（这几条都是审查抓到的真缺陷：改回去必须变红）──
    ok(gm.contains("inbox_api.mark_done(mid)"),
       "③ 问题卡答完立刻 mark_done 收尾（否则永久 pending → 每 60s 重投同一张已答卡）")
    ok(gm.contains("qid = \"goalask-%s-%d\" % (goal.get(\"id\", \"\")[:8], _cur + 1)"),
       "③ 问题卡 task_id 稳定 =「目标+当前步序号」")
    ok(!gm.contains("int(time.time())]"),
       "③ 问题卡 id 不再带秒级时间戳（重推变 id → App 去重失效）")
    ok(gm.contains("for _h in hits:"), "① 一个 job 挂多个目标 → 全部回写（此前 break 只更新第一个）")
    ok(gm.contains("\"warn\": warn"), "④⑤ 联动失败如实报 warn（不再静默 ok=True 推进游标）")
    ok(gm.contains("_WATCH_MAX"), "③ 等答案线程有并发上限（每张卡一个 daemon，防长期空转堆积）")
    ok(ia.contains("question 卡幂等复用"), "③ question 卡按 task_id 幂等复用（同一步不出两张卡）")
    // push 返回序：goal_report 分支必须在 want_id 之前（否则 want_id 调用方拿到纯 mid
    // → HTTP 层 isinstance(msg,dict) 为假 → goal_ok 恒为默认 True → 桥误判成功、静默丢汇报）
    func idx(_ s: String, _ sub: String) -> Int {
        guard let r = s.range(of: sub) else { return -1 }
        return s.distance(from: s.startIndex, to: r.lowerBound)
    }
    let iGoalRep = idx(ia, "if goal_report:")
    let iWantId = idx(ia, "if want_id:\n        return True, mid")
    ok(iGoalRep > 0 && iWantId > 0 && iGoalRep < iWantId,
       "① goal_report 分支排在 want_id 之前（否则「看着成功其实丢汇报」）")
}

// cron 桥（Hermes 宿主侧，不在后端目录）
let bridge = "/opt/data/scripts/ql_task_push.py"
if FileManager.default.fileExists(atPath: bridge) {
    let b = (try? String(contentsOfFile: bridge, encoding: .utf8)) ?? ""
    ok(b.contains("def extract_goal_writeback("), "① 桥有 goal 回写提取")
    ok(b.contains("_RE_GOAL_REPORT.search(body or '')"), "① 认 ##GOAL_REPORT## 机器段")
    // 🚨 v4.0.44 审查修复：判据必须**只认机器段**。此前还合取「【目标推进 k/N】或 job 名以「目标·」开头」，
    // 于是「自定义 job 名 + 模型某轮漏写首行进度标记」的路径整条 return None
    // （要求③④⑤ 100% 不生效，且游标照常推进 = 静默丢汇报）。是否属于某目标由后端按 cronJobID 定夺。
    ok(!b.contains("startswith('目标·')") && !b.contains("_RE_PROGRESS.search(body"),
       "① 判据只认机器段（不再合取进度前缀 / job 名）")
    ok(b.contains("'doneSteps': done"), "① 桥把 doneSteps 一起送后端")
    ok(b.contains("goal_ok"), "① 回写失败不推进游标（下一轮重试，汇报不丢）")
} else {
    print("  ⚠️ 跳过（cron 桥不可见）")
}

print("\n长期目标后台推进闭环真值表：\(pass) 通过 / \(fail) 失败")
if fail > 0 { exit(1) }
