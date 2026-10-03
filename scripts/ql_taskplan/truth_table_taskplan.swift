// MARK: - v4.0.37 任务中心结构化步骤真值表（plan[] 解析语义 + 两端接线护栏）
//
// 需求来源（OpenMuse 借鉴⑧）：任务中心原先只有**一行拼出来的字符串**进度
// （后端 `_stream_progress_detail`：「第 N 步 工具 · N 字 · 静默 X · 最近：…」），
// 用户看不出「一共几步 / 跑到第几步 / 每步花了多久」。本批给后端 `/api/agent/tasks/active`
// 的流式任务补 `plan[]` + `planSeq`（**零新增采集**，复用 toolSpans/toolSeq/lastTool 埋点），
// App 任务中心把它画成步骤清单。
//
// 编译运行（仓库根目录，权威入口是 check_swift.sh）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_taskplan \
//       scripts/ql_taskplan/truth_table_taskplan.swift qingliao/Core/ActiveTaskPlan.swift
//
// 真值表三件事：
//   1. plan[] 解析语义（**编译真实** `Core/ActiveTaskPlan.swift`，不是重写一份镜像 →
//      没有「表绿了但实现漂了」的洞；双文件编译故整体走 @main 结构）
//   2. 两端接线在位（App 解析 + 任务中心渲染；后端下发 plan/planSeq）
//   3. 老后端优雅退化（无键=空数组 → 整块不渲染，不显示假数据）

import Foundation

nonisolated(unsafe) var passCount = 0
nonisolated(unsafe) var failCount = 0

func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥行注释后再匹配：注释里提到同名串不算数，否则是假绿护栏。
/// 只在 `//` 位于行首或前面是空白时才算注释（不截断 "https://"）。
func code(_ path: String) -> String {
    let s = read(path)
    return s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        let str = String(line)
        guard let r = str.range(of: "//") else { return str }
        let before = str[str.startIndex..<r.lowerBound]
        if before.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if let last = before.last, last == " " || last == "\t" { return String(before) }
        return str
    }.joined(separator: "\n")
}

@main
struct TaskPlanTruthTable {
    static func main() {
        let root = "qingliao"

        // ── 0. 源文件就位（路径变了会静默假绿，故先断言非空） ──
        let planCoreSrc = code("\(root)/Core/ActiveTaskPlan.swift")
        let authSrc = code("\(root)/Core/AuthStore.swift")
        let taskCenterSrc = code("\(root)/Features/TaskCenterView.swift")
        check("Core/ActiveTaskPlan.swift 非空", !planCoreSrc.isEmpty)
        check("AuthStore.swift 非空", !authSrc.isEmpty)
        check("TaskCenterView.swift 非空", !taskCenterSrc.isEmpty)

        // ── 1. 解析语义（真实源码；类型来自 Core/ActiveTaskPlan.swift） ──
        check("老后端（nil）→ 空数组", ActiveTaskPlan.parse(nil).isEmpty)
        check("非数组（字符串）→ 空数组", ActiveTaskPlan.parse("plan").isEmpty)
        check("非数组（数字）→ 空数组", ActiveTaskPlan.parse(42).isEmpty)
        check("空数组 → 空数组", ActiveTaskPlan.parse([] as [[String: Any]]).isEmpty)
        check("项不是字典 → 丢弃（空）", ActiveTaskPlan.parse(["坏了", 7] as [Any]).isEmpty)

        // 1b. 正常两步：中文名 + 耗时（含 0.0 —— 与聊天页工具卡同口径，0 秒照显）
        let two = ActiveTaskPlan.parse([
            ["n": "执行命令", "st": "done", "s": 1.2],
            ["n": "搜索网页", "st": "done", "s": 0.0],
        ] as [[String: Any]])
        check("两步条数", two.count == 2)
        check("两步标题", two.map(\.title) == ["执行命令", "搜索网页"])
        check("两步都已完成", two.allSatisfy { $0.done })
        check("耗时保留（1.2）", two.first?.seconds == 1.2)
        check("耗时保留（0.0，不吞）", two.last?.seconds == 0.0)

        // 1c. 在跑那步：st=running → 不显示耗时（还没结束，0.0s 是假的）
        let running = ActiveTaskPlan.parse([
            ["n": "执行命令", "st": "done", "s": 1.2],
            ["n": "读取文件", "st": "running", "s": 9.9],
        ] as [[String: Any]])
        check("末步在跑", running.count == 2 && running.last?.done == false)
        check("在跑不显示耗时（即便后端给了 s）", running.last?.seconds == nil)
        check("在跑状态码", running.last?.state == .running)

        // 1d. 保守口径：st 缺键 / 未知值 → 已完成（宁可写已完成，也不要已完成的一直转圈）
        let weird = ActiveTaskPlan.parse([
            ["n": "缺 st 键"],
            ["n": "未知 st", "st": "weird", "s": 2],
            ["n": "大写 RUNNING", "st": "RUNNING"],
        ] as [[String: Any]])
        check("缺 st 键 → 已完成", weird[0].state == .done)
        check("未知 st → 已完成（保守）", weird[1].state == .done && weird[1].seconds == 2.0)
        check("大小写不匹配不算在跑", weird[2].state == .done)

        // 1e. 脏数据：缺 n / n 全空白 → 丢弃；s 非数值 → nil；s 是 Int → Double
        let dirty = ActiveTaskPlan.parse([
            ["st": "done"],
            ["n": "   ", "st": "done"],
            ["n": "写入文件", "st": "done", "s": "1.0"],
            ["n": "修改文件", "st": "done", "s": 2],
        ] as [[String: Any]])
        check("缺 n / 全空白 n 都丢弃", dirty.count == 2)
        check("id 保留下标（丢弃后不错位）", dirty.map(\.id) == [2, 3])
        check("s 非数值 → nil（不显示成 0.0s）", dirty[0].seconds == nil)
        check("s 是 Int → Double", dirty[1].seconds == 2.0)

        // 1f. 「更早的 N 步未列出」判据
        check("被裁：25 步明细 21 → 提示 4", ActiveTaskPlan.hiddenCount(planSeq: 25, shown: 21) == 4)
        check("刚好相等 → 不提示", ActiveTaskPlan.hiddenCount(planSeq: 20, shown: 20) == nil)
        check("老后端（都是 0）→ 不提示", ActiveTaskPlan.hiddenCount(planSeq: 0, shown: 0) == nil)
        check("明细比全量还多（异常）→ 不提示负数", ActiveTaskPlan.hiddenCount(planSeq: 2, shown: 5) == nil)

        // ── 2. App 侧接线护栏 ──
        check("AuthStore 用真实解析函数（不是内联手解）",
              authSrc.contains("ActiveTaskPlan.parse(d[\"plan\"])"))
        check("AuthStore 解 planSeq（含 Double 兜底）",
              authSrc.contains("(d[\"planSeq\"] as? Double).map(Int.init)"))
        check("ActiveTask 新增 plan 字段（类型指向 Core）",
              authSrc.contains("let plan: [ActiveTaskPlan.Step]"))
        check("ActiveTask 新增 planSeq 字段", authSrc.contains("let planSeq: Int"))
        check("任务中心门控 = plan 非空（老后端整块不渲染）",
              taskCenterSrc.contains("if !task.plan.isEmpty {"))
        check("任务中心渲染步骤清单", taskCenterSrc.contains("PlanStepList(steps: task.plan)"))
        check("任务中心复用既有截断提示（同一口径，不自造文案）",
              taskCenterSrc.contains("ToolStepsTruncationNote(hidden: hidden, shown: task.plan.count)"))
        check("截断判据走 hiddenCount（单一真源）",
              taskCenterSrc.contains("ActiveTaskPlan.hiddenCount(planSeq: task.planSeq,"))
        check("步骤清单是独立 struct（深 ViewBuilder 不内联，避免 CI 类型检查超时）",
              taskCenterSrc.contains("private struct PlanStepList: View"))
        check("步骤清单与聊天页工具卡同套语义（绿勾 + 耗时等宽数字 + 同一耗时文案）",
              taskCenterSrc.contains("checkmark.circle.fill")
              && taskCenterSrc.contains(".monospacedDigit()")
              && taskCenterSrc.contains("Text(d < 10 ? String(format: \"%.1fs\", d)"))

        // ── 3. 后端护栏（读 NAS 运行源，与 ql_goalbg 同一做法） ──
        let bePath = "/opt/hermes_host/微信文件/轻聊web/backend/stream_api.py"
        let beSrc = read(bePath)
        if beSrc.isEmpty {
            print("⚠️ 后端源不可读（\(bePath)）—— 跳过后端护栏（不误判为通过）")
        } else {
            check("后端有 _task_plan 函数", beSrc.contains("def _task_plan(st):"))
            check("后端任务卡下发 plan 字段", beSrc.contains("\"plan\": _task_plan(st),"))
            check("后端下发 planSeq（全量步数）",
                  beSrc.contains("\"planSeq\": int(st.get(\"toolSeq\") or 0),"))
            check("后端「在跑」判据 = toolSeq > 已完成条数",
                  beSrc.contains("if seq > len(spans) and st.get(\"lastTool\"):"))
            check("后端步骤名走 _TOOL_NAME_ZH（单一真源，App 不维护映射表）",
                  beSrc.contains("_TOOL_NAME_ZH.get(str(x.get(\"n\") or \"\")"))
            check("后端异常兜底返回空数组（不把任务卡打挂）",
                  beSrc.contains("    except Exception:\n        return []"))
            check("plan 是纯增量键（旧 detail 字段原样保留）",
                  beSrc.contains("\"detail\": _stream_progress_detail(st, now),"))
        }

        print("任务中心结构化步骤真值表：\(passCount) 通过 / \(failCount) 失败")
        if failCount > 0 { exit(1) }
    }
}
