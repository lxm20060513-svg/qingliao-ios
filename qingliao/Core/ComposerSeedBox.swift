import Foundation
import Observation

/// P4 冷启动：把「示例指令」一次性送进会话输入框的投递位（跨页可用）。
///
/// 为什么要有它：会话、生活、看板三页的冷启动引导都带**一个动作**，落点统一是
/// 「把一句示例指令放进输入框，用户改一改就能发」。会话页自己是 `@State inputText`，
/// 别的页摸不到 → 用这个页级单例做**一次性投递**（取走即清，不会重复灌）。
///
/// 口径：
///   · 取走即清（`take`），避免每次 body 重算都重灌一遍；
///   · **不动焦点**：调用方不要顺手 `inputFocus = true`（键盘已开保持、未开不弹）；
///   · 只存文本，不替用户发送 —— 用户还能改，动作是「开始」，不是「替他决定」。
@MainActor
@Observable
final class ComposerSeedBox {
    static let shared = ComposerSeedBox()

    /// 待消费的示例指令（nil = 没有）
    private(set) var text: String?

    private init() {}

    /// 投递（空白串视为没投）
    func put(_ seed: String) {
        let t = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        text = t.isEmpty ? nil : t
    }

    /// 取走并清空
    func take() -> String? {
        defer { text = nil }
        return text
    }
}
