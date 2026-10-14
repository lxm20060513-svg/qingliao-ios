import Foundation

// MARK: - v4.0.112 「阶段总结」气泡角标（本轮没跑完）
//
// 存在的理由：Hermes 打满迭代上限时会额外请模型写一版**收尾总结**再交差，但这条总结
// 在 wire 上就是一段普通 assistant 文本 —— App 分不出它和「正常答完」。用户会把
// 「我没跑完，先给你这些」当成最终结果。
//
// 全链（v4.0.112「阶段总结」标记）：
//   Hermes `/v1/responses` 的 `hermes.budget_exhausted` 加法字段
//        （gateway/platforms/api_server_openai_routes.py 的 `_budget_handoff_note`）
//   → 轻聊后端 stream_api.py `st["notice"] = "budget"`（只记标记、**不碰 content**：
//        App 轮询是 offset 增量协议，正文只能追加不能插入）
//   → 轮询体多一个 `notice` 键 → App 落库 / 读回 → 气泡上出角标
//
// 本文件只做**纯映射**（不 import SwiftUI），好让真值表把生产源直接编进来钉住口径。
enum MessageNotice {

    /// 后端取值（与 `stream_api.py` 的 `st["notice"]` 取值域一致）
    static let budget = "budget"

    /// 角标样式：颜色用字符串表达（UI 层映射成 Color），方便纯逻辑真值表断言
    struct Style: Equatable {
        let label: String     // 角标文案
        let colorKey: String  // orange
    }

    /// notice → 角标样式。
    /// ⚠️ 空 / 未知一律 nil：**老后端不发这个键时零行为变化**（收不到就不出角标）；
    /// 后端将来加新取值也只是「暂时不显示」，不会显示成错的。
    ///
    /// 用 `if` 比较而不是 `switch n { case budget: }` —— 后者在 Swift 里会被解析成
    /// 值绑定模式（`case` 后裸标识符），绑出一个同名新变量，永远为真。
    static func style(for notice: String?) -> Style? {
        guard let n = notice, !n.isEmpty else { return nil }
        if n == budget { return Style(label: "阶段总结", colorKey: "orange") }
        return nil
    }
}
