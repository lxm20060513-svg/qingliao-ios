// 待做池⑥ 长任务断点续传 · **App 半程**真值表 —— Linux 本地预检用
//
// 编译运行（在仓库根目录，权威入口是 check_swift.sh 新增段）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_resume_ui \
//       scripts/ql_resume_ui/truth_table_resume_ui.swift \
//       qingliao/Core/ResumeInfo.swift qingliao/Core/SendQueueOverview.swift \
//       qingliao/Core/ActiveTaskPlan.swift qingliao/Features/Chat/ChatPendingSend.swift
//
// 本表钉死的口径（后端「稳妥档」已上线，本轮做 App 侧消费）：
//   · 中断任务（后端 outcome=outcome_unknown）→ 如实外显「已完成第 k 步 · 结果未知 · 未自动重放」
//   · 非中断任务 notice=nil → **绝不误伤**普通 404/断网的原错误文案
//   · 已完成步数：planSeq 优先，老后端退 plan 已收口数；都不编数
//   · 队列总览：只统计当前会话、序号从 1 起、空文本跳过（不占号）、长文本截断
//
// A/B 段**真编译真跑** Core/ResumeInfo.swift + Core/SendQueueOverview.swift（与实现同一份文件 →
// 没有「表/实现漂移」的洞）；C 段用**剥注释**的源级断言钉接线（注释里写了不等于接线了）。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func ok(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}
func pos(_ name: String, _ cond: Bool) { positives += 1; ok(name, cond) }
func neg(_ name: String, _ cond: Bool) { negatives += 1; ok(name, cond) }

func stripComments(_ s: String) -> String {
    s.components(separatedBy: "\n").map { String($0.components(separatedBy: "//")[0]) }
        .joined(separator: "\n")
}
func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

@main
enum ResumeUITruthTable {

    static func step(_ t: String, _ state: ActiveTaskPlan.StepState, _ sec: Double? = nil) -> ActiveTaskPlan.Step {
        ActiveTaskPlan.Step(id: 0, title: t, state: state, seconds: sec)
    }

    static func main() {
        // ---------- A. ResumeInfo（中断任务外显口径） ----------
        pos("A1 后端标记 outcome_unknown 判为中断", ResumeInfo.isUnknown("outcome_unknown"))
        neg("A2 空串不是中断（老后端无键）", !ResumeInfo.isUnknown(""))
        neg("A3 nil 不是中断", !ResumeInfo.isUnknown(nil))
        neg("A4 别的 outcome 值不是中断（不误伤）", !ResumeInfo.isUnknown("done"))

        pos("A5 doneSteps 优先用 planSeq（后端全量步数）",
            ResumeInfo.doneSteps(plan: [], planSeq: 4) == 4)
        pos("A6 无 planSeq 时退 plan 已收口数",
            ResumeInfo.doneSteps(plan: [step("a", .done), step("b", .done), step("c", .running)], planSeq: 0) == 2)
        pos("A7 都拿不到 → 0（不编数）",
            ResumeInfo.doneSteps(plan: [], planSeq: 0) == 0)
        neg("A8 running 步不计入 doneSteps（不把在跑的当完成）",
            ResumeInfo.doneSteps(plan: [step("x", .running)], planSeq: 0) == 0)

        let n1 = ResumeInfo.notice(outcome: "outcome_unknown",
                                   plan: [step("读文件", .done)], planSeq: 3)
        pos("A9 中断+有步 → 含「已完成第 3 步」", (n1 ?? "").contains("已完成第 3 步"))
        pos("A10 中断提示含「结果未知」", (n1 ?? "").contains("结果未知"))
        pos("A11 中断提示含「未自动重放」", (n1 ?? "").contains("未自动重放"))

        neg("A12 非中断 → notice=nil（保持原错误文案，零误伤）",
            ResumeInfo.notice(outcome: "", plan: [], planSeq: 0) == nil)
        neg("A13 nil outcome → notice=nil", ResumeInfo.notice(outcome: nil, plan: [], planSeq: 2) == nil)
        let n2 = ResumeInfo.notice(outcome: "outcome_unknown", plan: [], planSeq: 0)
        pos("A14 中断+0 步 → 提示仍含「结果未知」", (n2 ?? "").contains("结果未知"))
        neg("A15 中断+0 步不出现「第 0 步」（不编步号）", !(n2 ?? "").contains("第 0 步"))

        // ---------- B. SendQueueOverview（队列总览口径） ----------
        func item(_ t: String, img: String? = nil, sid: String? = "s1") -> PendingSend {
            PendingSend(text: t, imageData: img, sessionId: sid)
        }
        let q = [item("第一条"), item("第二条"), item("别的会话的", sid: "s2"), item("第三条")]
        let rows = SendQueueOverview.rows(q, sessionId: "s1")
        pos("B1 只统计当前会话（别的会话不进总览）", rows.count == 3)
        pos("B2 序号从 1 起且连续", rows.map { $0.position } == [1, 2, 3])
        pos("B3 文本保留", rows[0].text == "第一条" && rows[2].text == "第三条")
        neg("B4 完全不属会话 → 空", SendQueueOverview.rows(q, sessionId: "s9").isEmpty)

        let mixed = [item("  "), item("有内容"), item("", img: "data:image/png;base64,AAA")]
        let rows2 = SendQueueOverview.rows(mixed, sessionId: "s1")
        pos("B5 空文本且无图 → 跳过（不占号）", rows2.count == 2 && rows2[0].position == 1 && rows2[1].position == 2)
        pos("B6 文本条目文本正确", rows2[0].text == "有内容")
        pos("B7 纯图片条目显示占位", rows2[1].text == "[图片]" && rows2[1].hasImage)

        let long = String(repeating: "字", count: 60)
        let rows3 = SendQueueOverview.rows([item(long)], sessionId: "s1", maxLen: 40)
        pos("B8 长文本截断到 maxLen 并补「…」", rows3[0].text.count == 41 && rows3[0].text.hasSuffix("…"))
        pos("B9 恰好等于 maxLen 不截断",
            SendQueueOverview.rows([item(String(repeating: "字", count: 40))], sessionId: "s1", maxLen: 40)[0].text.count == 40)

        pos("B10 nil sessionId（老数据）按当前会话对待",
            SendQueueOverview.rows([item("老的", sid: nil)], sessionId: "s1").count == 1)

        neg("B11 空队列摘要 nil（整条不渲染）", SendQueueOverview.summary(0) == nil)
        pos("B12 一条摘要含「1 条」", (SendQueueOverview.summary(1) ?? "").contains("1 条"))
        pos("B13 多条摘要含条数", (SendQueueOverview.summary(3) ?? "").contains("3 条"))
        neg("B14 负数摘要 nil（防脏数据）", SendQueueOverview.summary(-1) == nil)

        // 幂等 / 稳定 id：同输入两次结果一致
        pos("B15 rows 幂等", SendQueueOverview.rows(q, sessionId: "s1") == rows)

        // ---------- C. 源级接线（剥注释只看代码形态） ----------
        let sc = stripComments(read("qingliao/Core/StreamClient.swift"))
        pos("C1 StreamClient 消费 ResumeInfo.notice", sc.contains("ResumeInfo.notice("))
        pos("C2 StreamClient 用 interruptedNote 兜底错误文案", sc.contains("interruptedNote"))
        pos("C3 未采纳分支用中断提示（?? 原文案）",
            sc.contains("interruptedNote ?? \"连接中断，请重试\""))
        neg("C4 未采纳分支不得退回硬编码文案（防护栏失效）",
            !sc.contains("if localTaskGone { finish(success: false, error: \"连接中断，请重试\") }"))

        let asrc = stripComments(read("qingliao/Core/AuthStore.swift"))
        pos("C5 AuthStore 解析 recover 的 outcome 键", asrc.contains("j[\"outcome\"]"))
        pos("C6 AuthStore 解析 recover 的 plan 键", asrc.contains("ActiveTaskPlan.parse(j[\"plan\"])"))
        pos("C7 AuthStore 解析 recover 的 planSeq 键", asrc.contains("j[\"planSeq\"]"))
        pos("C8 streamRecover 返回结构化 RecoverResult", asrc.contains("struct RecoverResult"))
        neg("C9 不再返回 5 元组（旧形态清零）",
            !asrc.contains("-> (String?, String, Bool, String, String)"))

        let cv = stripComments(read("qingliao/Features/Chat/ChatView.swift"))
        pos("C10 队列条挂进 chatRecordBarSlot（互斥槽位）",
            cv.contains("SendQueueBar(rows: pendingQueueRows"))
        pos("C11 有 pendingQueueRows 计算属性", cv.contains("private var pendingQueueRows"))
        pos("C12 pendingQueueRows 走 SendQueueOverview.rows", cv.contains("SendQueueOverview.rows(pendingQueue"))
        pos("C13 探针恢复调用已改用 RecoverResult（let tid = r.taskId）",
            cv.contains("let tid = r.taskId"))
        pos("C14 SendQueueBar 存在", read("qingliao/Features/Chat/SendQueueBar.swift").contains("struct SendQueueBar"))
        pos("C15 SendQueueBar 用 summary + rows 单一真源",
            stripComments(read("qingliao/Features/Chat/SendQueueBar.swift"))
                .contains("SendQueueOverview.summary(rows.count)"))

        print("")
        print(failures == 0 ? "🎉 全部通过（0 失败）" : "❌ \(failures) 个失败")
        print("结果：正例 \(positives) / 反例 \(negatives) / \(failures) 失败")
        if failures > 0 { exit(1) }
    }
}
