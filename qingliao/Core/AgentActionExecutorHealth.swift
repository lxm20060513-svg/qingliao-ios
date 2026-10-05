import Foundation

// MARK: - v4.0.60 健康数据动作的执行（HealthKit 只读）
//
// 单独一个文件：AgentActionExecutorLocal.swift 里已经有两个大块（动作执行 + 定位 delegate），
// 再往里塞只会更难读；这里只放 health.query 的执行体，二级分派那一行在
// AgentActionExecutorLocal.runLocal 里（口径：本地动作只由 runLocal 一处分派）。
//
// 🚨 铁律：健康数据的一切判断都建立在 HealthStore.isAvailable 之上 ——
//    侧载没带 healthkit entitlement 时，碰任何 HealthKit 的请求/查询 API 都会抛 ObjC 异常
//    **直接闪退**（Swift 抓不住）。见 HealthStore.swift 文件头。
//
// 🚨 别把「读授权态」当硬闸门（v4.0.60 首版真踩过）：HealthKit **不回传读权限**，
//    authorizationStatus 报的是写权限（本 App toShare: [] → 恒 notDetermined）。
//   所以这里放行到查询，用「有没有读到数据」判结果：读到 → 正常出卡；
//   读到 0 条 → 按本地区分「已授权但确实没记录」/「还没授权」，照实说并给授权入口。
//   这样即使用户绕过 App 在系统设置里开的权限，也能正常出数据（不会恒报「未授权」）。

extension AgentActionExecutor {

    /// health.query：把最近 N 天的健康数据聚合成一段中文，显示在只读动作卡上。
    /// 参数：days（可选，1~7，默认 1）、metric（可选：steps/sleep/heart/workout，默认全部）
    static func healthSummary(_ action: AgentAction) async -> Outcome {
        guard HealthStore.isAvailable else {
            return .failed("这个安装方式读不到健康数据（IPA 没带 HealthKit 授权声明）；换带声明的版本再试")
        }

        let days = max(1, min(Int(action.param("days") ?? "") ?? 1, 7))
        let metric = action.param("metric")

        if let text = await HealthStore.shared.summary(days: days, metric: metric) {
            return .doneNoUndo(message: text)
        }

        // 一条都没读到：不能断言「没授权」（只读权限不可观测），照实给两种可能
        if HealthStore.shared.authorizationState == .granted {
            return .failed("最近 \(days) 天没读到健康记录 —— 「健康」App 里可能确实没有这类数据")
        }
        return .failed("健康数据没读到：可能还没授权，或最近 \(days) 天确实没记录。到「设置 → 权限与 AI 操控 → 健康」点一下授权（也可在系统「设置 → 隐私与安全性 → 健康 → 轻聊」里打开读取）")
    }
}
