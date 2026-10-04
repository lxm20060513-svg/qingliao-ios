// MARK: - v4.0.40 长期目标 5 项改进真值表（#1 胶囊 / #2 任务中心 / #3 推原会话 / #4 自动划掉 / #5 开始时间）
//
// 用户原话（2026-10-04）：
//   ① 长期目标卡片加一个「现在开始推进」的胶囊
//   ② 任务中心的任务应该要显示后台推进任务
//   ③ 后台推进任务里需要我确认回复的，推送轻聊投递的同时把消息推送到原会话
//   ④ 已完成的项目请自己在待办清单和长期目标卡片里面划掉
//   ⑤ 长期目标任务卡片里面明确备注好每一个任务的开始时间
//
// 本表钉住：
//   ① 纯逻辑口径（步骤时间文案 / 完成判定 / 未完成优先排序 / needs-user 解析）—— 镜像实现，改口径必红
//   ② iOS 侧接线（新字段真解码 / 胶囊真挂在卡片 / 已完成折叠 / 端点字面量）
//   ③ 后端侧接线（push_now 路由 / bgjobs 落盘 / 待办联动 / originSessionId）
//
// 🚨 与 ql_goalbg 的分工：那表钉的是「后台状态可见性」，本表钉的是「手动推进 + 自动收尾闭环」。
//    改动口径时两张都要改，别只改一张。

import Foundation

var pass = 0, fail = 0
func ok(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("  ✅ \(name)") } else { fail += 1; print("  ❌ \(name)") }
}

let repo = ProcessInfo.processInfo.environment["QL_REPO"] ?? "."
func read(_ rel: String) -> String {
    (try? String(contentsOfFile: repo + "/" + rel, encoding: .utf8)) ?? ""
}
func code(_ rel: String) -> String { stripComments(read(rel)) }

/// 剥注释：护栏要匹配代码形态，防「注释里写了就算过」（ql_goalbg 同款做法）
func stripComments(_ s: String) -> String {
    var out = ""
    for ln in s.split(separator: "\n", omittingEmptySubsequences: false) {
        let t = ln.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("//") || t.hasPrefix("*") || t.hasPrefix("/*") { continue }
        out += ln + "\n"
    }
    return out
}

func stamp(_ iso: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    guard let d = f.date(from: iso) else { return iso }
    let g = DateFormatter(); g.dateFormat = "M月d日 HH:mm"
    return g.string(from: d)
}

// ── ① 步骤时间文案（镜像 GoalsSection.stepTimeText）────────────────
func stepTimeText(startedAt: String?, doneAt: String?) -> String? {
    let started = startedAt.map { "已开始 " + stamp($0) }
    let done = doneAt.map { "已完成 " + stamp($0) }
    switch (started, done) {
    case let (a?, b?): return "\(a) · \(b)"
    case let (a?, nil): return a
    case let (nil, b?): return b
    default: return nil
    }
}

print("── ⑤ 步骤开始时间文案 ──")
ok(stepTimeText(startedAt: "2026-10-04T11:14:00", doneAt: nil) == "已开始 10月4日 11:14",
   "只开始 → 只显已开始")
ok(stepTimeText(startedAt: "2026-10-04T11:14:00", doneAt: "2026-10-06T21:03:00") == "已开始 10月4日 11:14 · 已完成 10月6日 21:03",
   "开始+完成 → 两行并显")
ok(stepTimeText(startedAt: nil, doneAt: "2026-10-06T21:03:00") == "已完成 10月6日 21:03",
   "老数据只回填了完成时间也能显示")
ok(stepTimeText(startedAt: nil, doneAt: nil) == nil,
   "🔑 一个时间都没有 → 返回 nil（整行不渲染，不显示「未开始」噪声）")

// ── ④ 完成判定 + 未完成优先排序（镜像 GoalStore）────────────────────
struct FakeStep { var done: Bool; var startedAt: String?; var updated: String }
struct FakeGoal { var id: String; var finishedAt: String?; var updatedAt: String; var steps: [FakeStep] }

func isFinished(_ g: FakeGoal) -> Bool { !g.steps.isEmpty && g.steps.allSatisfy { $0.done } }
func activeCount(_ gs: [FakeGoal]) -> Int { gs.filter { !isFinished($0) }.count }

print("── ④ 已完成自动划掉 ──")
let gAll = FakeGoal(id: "a", finishedAt: nil, updatedAt: "2026-10-06", steps: [FakeStep(done: true, startedAt: nil, updated: "1")])
let gSome = FakeGoal(id: "b", finishedAt: nil, updatedAt: "2026-10-05", steps: [
    FakeStep(done: true, startedAt: nil, updated: "1"), FakeStep(done: false, startedAt: nil, updated: "1")])
let gEmpty = FakeGoal(id: "c", finishedAt: nil, updatedAt: "2026-10-04", steps: [])
ok(isFinished(gAll), "全勾完 → 已完成")
ok(!isFinished(gSome), "还差一步 → 进行中")
ok(!isFinished(gEmpty), "零步骤不算完成（否则新建目标立刻进已完成）")
ok(activeCount([gAll, gSome, gEmpty]) == 2, "activeCount 只数未完成")

// 排序：未完成优先，其次 updatedAt 倒序
let sorted = [gAll, gSome, gEmpty].sorted { a, b in
    if isFinished(a) != isFinished(b) { return !isFinished(a) }
    return a.updatedAt > b.updatedAt
}
ok(sorted.map(\.id) == ["b", "c", "a"],
   "🔑 未完成优先 + 组内最新在前（已完成沉底）")

// ⚠️ 取消一个勾选应立刻回到「进行中」——所以 finishedAt 不参与判定
var reopened = gAll
reopened.steps[0].done = false
reopened.finishedAt = "2026-10-06T21:00:00"
ok(!isFinished(reopened),
   "🔑 后端 finishedAt 已在，但用户手动取消勾选 → 仍算进行中（不被 finishedAt 锁死）")

// ── ③ 「需要你做」解析（镜像 goal_module._report_needs_user）────────
func needsUser(_ report: String) -> String {
    for ln in report.split(separator: "\n") {
        let l = String(ln).trimmingCharacters(in: .whitespaces)
        guard l.hasPrefix("需要你做") else { continue }
        // 镜像 goal_module._report_needs_user：`val = ln.split("：",1)[-1].split(":",1)[-1].strip()`
        // 🚨 Swift 的 split **默认 omitEmptySubsequences=true**，切「需要你做：」会得到 "需要你做"
        //    而不是 Python 的空串 —— 直接照抄会把这个空值误判成真需要确认。
        //    正确镜像：先按首次出现位置切出后半段（保空），再按半角冒号切一次。
        func afterColon(_ s: String) -> String {
            if let r = s.range(of: "：") { return String(s[r.upperBound...]) }
            if let r = s.range(of: ":") { return String(s[r.upperBound...]) }
            return s
        }
        var val = afterColon(l)
        val = val.trimmingCharacters(in: CharacterSet(charactersIn: "。．.！!，,、 "))
        if val.isEmpty || ["无", "无需", "不用", "不需要", "无。", "-", "—", "0", "无额外"].contains(val) { return "" }
        // v4.0.40：逐字枚举会漏掉「无需额外操作」这类自然说法 → 每天早上都弹「请确认」→ 被当噪声
        if val.range(of: "^(无|没|不用|不需要|不必|不必再|暂时不)", options: .regularExpression) != nil { return "" }
        if val.range(of: "(无需额外|没有需要|没有要你|不用回复|无需回复|不需要回复|无额外)", options: .regularExpression) != nil { return "" }
        return val
    }
    return ""
}

print("── ③ 需要确认才推原会话 ──")
ok(needsUser("今天推进：x\n需要你做：确认第一步方案") == "确认第一步方案", "有事 → 解析出来")
ok(needsUser("今天推进：x\n需要你做：无") == "", "「无」→ 不推（否则每天早上都弹确认）")
ok(needsUser("今天推进：x\n需要你做：无需额外操作") == "", "「无需额外操作」→ 不推（曾漏网，会每天弹确认）")
ok(needsUser("今天推进：x\n需要你做：没有要你做的事") == "", "「没有要你做的事」→ 不推")
ok(needsUser("今天推进：x\n需要你做：不必回复") == "", "「不必回复」→ 不推")
ok(needsUser("今天推进：x\n需要你做：暂时不用管") == "", "「暂时不用管」→ 不推")
ok(needsUser("今天推进：x\n需要你做：") == "", "空值 → 不推")
ok(needsUser("今天推进：x") == "", "没有该行 → 不推")
ok(needsUser("") == "", "空报告 → 不推")

// ── ② iOS 侧接线 ────────────────────────────────────────────────
print("── ①②④⑤ iOS 接线 ──")
let gs = code("qingliao/Core/GoalStore.swift")
ok(gs.contains("var startedAt: Date?"), "#5 GoalStep 有 startedAt")
ok(gs.contains("decodeIfPresent(Date.self, forKey: .startedAt)"), "#5 startedAt 用 decodeIfPresent（老数据不炸）")
ok(gs.contains("case id, title, todoLinked, done, doneAt, startedAt"), "#5 GoalStep CodingKeys 登记 startedAt")
ok(gs.contains("var manualPushAt: Date?") && gs.contains("var finishedAt: Date?"), "#1/#4 新字段在 GoalItem 上")
ok(gs.contains("var originSessionId: String"), "#3 GoalItem 记 originSessionId")
ok(gs.contains("\"sessionId\": goal.originSessionId"), "#3 同步给后端时带 sessionId（否则推不回原会话）")
ok(gs.contains("var sortedActiveFirst: [GoalItem]"), "#4 有未完成优先排序")
ok(gs.contains("var finishedGoals: [GoalItem]"), "#4 有已完成分组")
ok(gs.contains("var activeGoals: [GoalItem]"), "#4 主卡数据源 = 未完成")
ok(gs.contains("/api/life/goal/push_now"), "#1 pushNowOnBackend 端点字面量")
ok(gs.contains("g.finishedAt != r.finishedAt") && gs.contains("g.originSessionId != r.originSessionId"),
   "#1/#4/#3 新字段进了差异比对（不回灌就等于没同步）")
ok(gs.contains("g.manualPushAt != r.manualPushAt"), "#1 manualPushAt 进了差异比对")

let gsec = code("qingliao/Features/Life/GoalsSection.swift")
ok(gsec.contains("\"现在开始推进\""), "#1 卡片上有「现在开始推进」")
ok(gsec.contains("onPushNow"), "#1 胶囊通过 onPushNow 回调（不是硬编码）")
ok(gsec.contains("pushingIDs"), "#1 推进中防连点")
ok(gsec.contains("store.pushNowOnBackend"), "#1 真调后端")
ok(gsec.contains("已完成 \\(store.finishedGoals.count) 个"), "#4 已完成折叠行")
ok(gsec.contains("var finishedFold: some View"), "#4 折叠行有实现")
ok(gsec.contains("store.sortedActiveFirst"), "#4 列表用未完成优先排序")
ok(gsec.contains("开始于 "), "#5 卡片显示开始时间")
ok(gsec.contains("if let t = stepTimeText(s)"), "#5 步骤时间无戳时不渲染")
ok(gsec.contains("func stepTimeText"), "#5 有 stepTimeText")
ok(gsec.contains("Text(\"\\(a) 个进行中 · \\(f) 个已完成\")") || gsec.contains("个进行中 · "),
   "#4 页头报已完成数")
// 🚨 Button 套 Button：卡片外层若还是 Button，点胶囊会变成打开详情
ok(!gsec.contains("GoalRowCard(goal: top, compact: true)\n            .buttonStyle"),
   "#1 主卡不是 Button 包裹（否则胶囊点不动）")
ok(gsec.contains(".onTapGesture { openCard() }"), "#1 主卡用 onTapGesture 承接点击")

// ── ③ 后端侧接线 ────────────────────────────────────────────────
print("── ②③④⑤ 后端接线 ──")
let be = "/opt/hermes_host/微信文件/轻聊web/backend/"
func beRead(_ f: String) -> String { (try? String(contentsOfFile: be + f, encoding: .utf8)) ?? "" }

if beRead("goal_module.py").isEmpty {
    print("  ⚠️ 跳过（后端源不可见）")
} else {
    let gm = beRead("goal_module.py")
    ok(gm.contains("def goals_push_now("), "#1 后端有 goals_push_now")
    ok(gm.contains("def _run_push_now("), "#1 后台线程执行体")
    ok(gm.contains("_goal_morning_prompt(g)"), "#1 复用早推进提示词（不另造一套）")
    ok(gm.contains("_bg_register(") && gm.contains("_bg_update("), "#2 push_now 登记任务中心作业")
    ok(gm.contains("originSessionId"), "#3 建目标时记 originSessionId")
    ok(gm.contains("def _push_to_origin("), "#3 有推原会话的函数")
    ok(gm.contains("qingliao_proactive"), "#3 老目标无 sessionId 时回落「轻聊主动」")
    ok(gm.contains("def _sync_todos_finish("), "#4 待办联动函数")
    ok(gm.contains("［目标·%s］"), "#4 匹配口径与 iOS GoalTodoBridge 一致")
    ok(gm.contains("finishedAt"), "#4 有 finishedAt")

    let la = beRead("life_api.py")
    ok(la.contains("/api/life/goal/push_now"), "#1 路由已挂（挂 /api/life/goal 前缀下 = 零 nginx 改动）")

    let sa = beRead("stream_api.py")
    ok(sa.contains("def _bgjobs_flush(") && sa.contains("def _bgjobs_load("), "#2 bg 作业落盘/回填成对")
    ok(sa.contains("bgjobs.json"), "#2 落盘文件名")
    // 🚨 这条曾经真炸过：变量名笔误 _BGJOBS_LOADED vs _BGJOB_LOADED，py_compile 查不出
    ok(!sa.contains("_BGJOBS_LOADED"), "#2 变量名无笔误（曾 NameError，真跑才暴露）")
    ok(sa.contains("_bgjobs_load()"), "#2 collect 时会回填")
}

print("\n长期目标 5 项改进真值表：\(pass) 通过 / \(fail) 失败")
exit(fail == 0 ? 0 : 1)