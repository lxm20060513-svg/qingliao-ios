import Foundation

/// 待做池⑥（后端「稳妥档」断点续传的 **App 侧消费**）：中断任务的「结果未知」外显口径。
///
/// 背景：后端 `/api/stream/recover` 的**磁盘兜底**分支对「被重启/异常切断的孤儿任务」回
/// `outcome=outcome_unknown` + 保留已生成内容与已完成步（`plan` / `planSeq`），
/// 并**绝不自动重放**（见 `stream_api.reconcile_streams_on_startup`）。此前 App 侧
/// `streamRecover` 只解 5 个字段，这几个断点信息全被丢掉 → 用户只看到一句笼统的
/// 「连接中断，请重试」，既不知道「跑了多少步」也不知道「结果未知、没重放」。
///
/// 本文件是纯 Foundation 口径真源（不 import SwiftUI、不含几何），可被真值表**直接编译**验证
/// —— 与 `ActiveTaskPlan` / `ChatScrollPin` 同一套做法。
enum ResumeInfo {
    /// 后端约定的「结果未知」标记值。
    static let unknownOutcome = "outcome_unknown"

    /// 是否是「中断且结果未知」的任务（后端磁盘兜底/reconcile 打的标）。
    /// 空串 / 未知键（老后端）一律 false → 调用方走原有错误口径，零行为变化。
    static func isUnknown(_ outcome: String?) -> Bool {
        (outcome ?? "") == unknownOutcome
    }

    /// 已完成步数：`planSeq`（后端全量步数）优先；老后端无该键（0）时退 `plan` 里已收口步数。
    /// 不编数：两者都拿不到就返回 0。
    static func doneSteps(plan: [ActiveTaskPlan.Step], planSeq: Int) -> Int {
        if planSeq > 0 { return planSeq }
        return plan.filter { $0.done }.count
    }

    /// 用户可见提示。**返回 nil = 不是中断任务** → 调用方保留原错误文案（不误伤普通 404/断网）。
    static func notice(outcome: String?, plan: [ActiveTaskPlan.Step], planSeq: Int) -> String? {
        guard isUnknown(outcome) else { return nil }
        let n = doneSteps(plan: plan, planSeq: planSeq)
        if n > 0 {
            return "任务中断（服务重启或异常）：已完成第 \(n) 步，结果未知，未自动重放"
        }
        return "任务中断（服务重启或异常）：结果未知，未自动重放"
    }
}
