// MARK: - #16a「目标可编辑」真值表（v4.0.104）
//
// 口径：目标建完改不了 —— 标题、早/晚提醒开关与时刻本该能改（后端 goals_update 早就支持）。
// 落点：Core/GoalEditKit.swift（纯逻辑：payload/钳位/是否改动）+ Core/GoalStore.swift（updateOnBackend）
//       + Features/Life/GoalsSection.swift（长按菜单「编辑」→ 页级浮层 → **复用同一份表单**）
//
// 为什么值得钉（坏了都不报错）：
//   ① 两套表单（新建一套、编辑一套）→ 时刻区间/开关文案/落库口径迟早分叉；
//   ② 表单能选 13 点、payload 却按别的区间裁 → 用户改了「没生效」，后端其实收到了别的值；
//   ③ 只改本地不推后端 → 卡片看着改了，每天两段推送还是旧的（用户以为改了）；
//   ④ 推失败静默 → 同上，且用户没有任何提示；
//   ⑤ 编辑入口把「暂停/删除」顶掉 → 危险动作凭空消失；
//   ⑥ 没改动也发请求 → 白盖 updatedAt，多设备合并时旧快照反把新数据盖回去。
//
// 单文件（读源文件做护栏）+ 纯逻辑真跑（test_goal_edit.swift）→ run_unit。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥 `//` 行注释（注释里写了「原先那样是错的」这类说明，直接 grep 原文会被自己的注释判红）
func code(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            let head = line[line.startIndex..<r.lowerBound]
            if head.filter({ $0 == "\"" }).count % 2 == 1 { return String(line) }
            return String(head)
        }
        .joined(separator: "\n")
}

func countOf(_ needle: String, in hay: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return hay.components(separatedBy: needle).count - 1
}

/// 取两个标记之间的片段（nil = 标记缺失 → 调用方必须判失败，别静默放过）
func slice(_ text: String, from: String, to: String) -> String? {
    guard let a = text.range(of: from)?.upperBound,
          let b = text.range(of: to, range: a..<text.endIndex)?.lowerBound else { return nil }
    return String(text[a..<b])
}

let kitPath = "qingliao/Core/GoalEditKit.swift"
let storePath = "qingliao/Core/GoalStore.swift"
let goalsPath = "qingliao/Features/Life/GoalsSection.swift"

let kitRaw = src(kitPath)
let storeRaw = src(storePath)
let goalsRaw = src(goalsPath)

let kit = code(kitRaw)
let store = code(storeRaw)
let goals = code(goalsRaw)

check("前置：三个源文件都读到内容（路径漂移会静默全绿）",
      [kit, store, goals].allSatisfy { $0.count > 800 })

// MARK: - ① 区间口径：表单 Stepper 与 payload 钳位必须逐字一致

check("① 早间区间逐字一致（表单 6...12 = GoalEditKit 6...12）",
      goals.contains("in: 6...12") && kit.contains("morningRange = 6...12"))
check("① 晚间区间逐字一致（表单 18...23 = GoalEditKit 18...23）",
      goals.contains("in: 18...23") && kit.contains("eveningRange = 18...23"))
check("① payload 用钳位后的时刻（不是原始输入）",
      kit.contains("\"morningHour\": clampMorning(morningHour)")
      && kit.contains("\"eveningHour\": clampEvening(eveningHour)"))
check("① 后端六个键名齐（id/title/morningEnabled/eveningEnabled/morningHour/eveningHour）",
      ["\"id\"", "\"title\"", "\"morningEnabled\"", "\"eveningEnabled\"", "\"morningHour\"", "\"eveningHour\""]
        .allSatisfy { kit.contains($0) })

// MARK: - ② 单一真源：复用同一份表单，不另起编辑界面

check("② 表单只有一个（GoalsAddBody 一份）",
      countOf("struct GoalsAddBody: View {", in: goals) == 1)
check("② 没有第二套编辑表单（不许出现 EditGoalBody / GoalsEditBody）",
      !goals.contains("EditGoalBody") && !goals.contains("GoalsEditBody"))
check("② 编辑靠 editing 入参驱动（nil = 新建）",
      goals.contains("var editing: GoalItem? = nil"))
check("② 编辑态预填该目标当前值（title/开关/时刻五处）",
      goals.contains("_draft = State(initialValue: editing?.title ?? \"\")")
      && goals.contains("_addMorning = State(initialValue: editing?.morningEnabled ?? true)")
      && goals.contains("_addEvening = State(initialValue: editing?.eveningEnabled ?? true)")
      && goals.contains("_addMorningHour = State(initialValue: editing?.morningHour ?? 9)")
      && goals.contains("_addEveningHour = State(initialValue: editing?.eveningHour ?? 21)"))

// MARK: - ③ 入口与浮层状态

check("③ 长按菜单有「编辑」项（opens 页级编辑浮层）",
      goals.contains("Label(\"编辑\", systemImage: \"pencil\")")
      && goals.contains("p.showEdit = g") && goals.contains("p.editSession += 1"))
check("③ 编辑项写在「暂停/删除」之前（不许顶掉危险动作）",
      (goals.range(of: "p.showEdit = g")?.lowerBound ?? goals.endIndex)
      < (goals.range(of: "Label(g.paused ? \"恢复每日推进\" : \"暂停每日推进\"")?.lowerBound ?? goals.startIndex)
      && (goals.range(of: "Label(\"编辑\", systemImage: \"pencil\")")?.lowerBound ?? goals.endIndex)
      < (goals.range(of: "Label(\"删除\", systemImage: \"trash\")")?.lowerBound ?? goals.startIndex))
check("③ 页级单例声明 showEdit / editSession",
      goals.contains("var showEdit: GoalItem?") && goals.contains("var editSession = 0"))
check("③ reset() 清 showEdit（否则回生活页又弹着上次的编辑框）",
      goals.contains("override func reset() {") && {
          guard let body = slice(goals, from: "override func reset() {", to: "}") else { return false }
          return body.contains("super.reset()") && body.contains("showEdit = nil")
      }())
check("③ 宿主渲染编辑浮层：复用 GoalsAddBody + 实参序 store→editing→onCancel→onSaved",
      goals.contains("if let editing = glass.showEdit {")
      && goals.contains("GoalsAddBody(\n                        store: store,\n                        editing: editing,\n                        onCancel: { glass.showEdit = nil },\n                        onSaved: { glass.showEdit = nil }")
      && goals.contains(".id(glass.editSession)"))

// MARK: - ④ 保存路径：先本地、后异步推后端；没改动不发请求；失败有提示

check("④ 保存分支在新建之前（编辑模式先分流，否则会新建出重复目标）",
      goals.contains("if let target = editing {\n            confirmEdit(target, title: t)\n            return\n        }"))
check("④ 本地先落库，再异步推后端",
      { guard let body = slice(goals, from: "private func confirmEdit(", to: "\n    }\n}") else { return false }
        guard let a = body.range(of: "store.mutate(target.id)")?.lowerBound,
              let b = body.range(of: "await store.updateOnBackend(")?.lowerBound else { return false }
        return a < b }())
check("④ 没改动就不发请求（hasChanges 不成立时提前 onSaved 返回，不落库不发请求）",
      goals.contains("eveningHour: addEveningHour) else {\n            onSaved()\n            return\n        }\n        store.mutate(target.id) { g in"))
check("④ 推后端只此一处调用，且失败分支紧跟其后（不许塞进死代码）",
      countOf("await store.updateOnBackend(", in: goals) == 1
      && goals.contains("            let ok = await store.updateOnBackend(goalID: target.id, title: title,\n                                                 morningEnabled: addMorning, eveningEnabled: addEvening,\n                                                 morningHour: addMorningHour, eveningHour: addEveningHour)\n            guard !ok else { return }"))
check("④ 推失败不静默（写 lastReport 让用户看得见）",
      { guard let body = slice(goals, from: "private func confirmEdit(", to: "\n    }\n}") else { return false }
        return body.contains("lastReport") && body.contains("没同步给后台") }())
check("④ 编辑时刻按钳位口径写本地（与 payload 同一份区间）",
      goals.contains("g.morningHour = GoalEditKit.clampMorning(addMorningHour)")
      && goals.contains("g.eveningHour = GoalEditKit.clampEvening(addEveningHour)"))

// MARK: - ⑤ Store 侧：请求体只经 GoalEditKit，别再手拼字典

check("⑤ updateOnBackend 存在且走 PATCH /api/life/goal",
      store.contains("func updateOnBackend(goalID: String, title: String,")
      && store.contains("auth.json(\"/api/life/goal\", method: \"PATCH\", body: body)"))
check("⑤ 请求体只此一条口径（GoalEditKit.payload，函数体内不许手拼键）",
      { guard let body = slice(store, from: "func updateOnBackend(", to: "\n    }") else { return false }
        return body.contains("GoalEditKit.payload(") && !body.contains("\"morningHour\":") }())
check("⑤ 后端规范化后的字段回灌本地（否则卡片显示与实际生效不一致）",
      { guard let body = slice(store, from: "func updateOnBackend(", to: "\n    }") else { return false }
        return body.contains("mutate(goalID)") && body.contains("remote[\"title\"]") }())
check("⑤ 推失败返回 false（调用方据此提示，不许悄悄吞掉）",
      { guard let body = slice(store, from: "func updateOnBackend(", to: "\n    }") else { return false }
        return body.contains("else { return false }") && body.contains("return true") }())

// MARK: - ⑥ 反向：既有危险动作与后端路由都没被动过

check("⑥ 暂停/恢复入口还在（编辑不许顶掉它）",
      goals.contains("setPausedOnBackend(goalID: g.id, paused: now)"))
check("⑥ 删除入口还在",
      goals.contains("Label(\"删除\", systemImage: \"trash\")"))
check("⑥ 新建路径仍在（编辑只加分流，不改新建）",
      goals.contains("store.add(g)") && goals.contains("GoalTodoBridge.pushStepsToTodo(g)"))
check("⑥ 删目标仍走后端（不许因本轮改动丢 cron 清理）",
      store.contains("func deleteOnBackend(goalID: String)"))

print("目标可编辑真值表：#16a \(passCount) 通过 / \(failCount) 失败")
exit(failCount == 0 ? 0 : 1)
