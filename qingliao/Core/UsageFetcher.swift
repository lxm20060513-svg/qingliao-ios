// MARK: - #3 `/usage` 数据抓取单一真源
//
// 看板「Token 用量」卡（Features/Dashboard/DashboardView.loadTokenUsage）与斜杠命令 `/usage`
// 读的是同一份数据。原先端点字面量 + `TokenUsage.parse` 只长在 Dashboard 里；命令层要复用就
// 得把它抽成这里的一个函数 —— **端点字符串只此一处构造**（相对路径单一真源规约），
// Dashboard 与命令都调它，改端点只改这一行。
//
// ⚠️ AuthStore 是 @MainActor，故本出口也标 @MainActor（调用方已在 MainActor 上下文里）。

import Foundation

enum UsageFetcher {
    /// 后端 token 用量端点（读 Hermes state.db）。
    static let tokenUsagePath = "/api/nas/token-usage"

    /// 失败原因（**文案单一真源**）：看板与 `/usage` 都显示这里给的 message，别再各自编一套。
    /// 三种情形逐字沿用看板 v3.9.82 原有口径 —— 网络失败 / 后端 `error` 字段（真因）/ 结构不符。
    enum Failure: Equatable {
        case request            // 请求失败（断网、401、超时…）
        case backend(String)    // 后端给了 error 字段：把它当提示（如「state.db 不存在」）
        case unparsable         // 200 但结构不符（后端改了口径）

        var message: String {
            switch self {
            case .request:            return "token 用量查询失败"
            case .backend(let reason): return reason
            case .unparsable:         return "token 用量暂不可用"
            }
        }
    }

    /// 拉取并解析 token 用量。失败也带上原因（不是一刀切 nil），调用方直接显示 `Failure.message`。
    @MainActor
    static func fetchTokenUsage(auth: AuthStore) async -> Result<TokenUsage, Failure> {
        guard let j = await auth.jsonOrLog(tokenUsagePath) else { return .failure(.request) }
        if let u = TokenUsage.parse(j) { return .success(u) }
        if let e = j["error"] as? String, !e.isEmpty { return .failure(.backend(e)) }
        return .failure(.unparsable)
    }
}
