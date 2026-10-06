import SwiftUI

/// v4.0.69：会话 → 聊天 的入场变换参数（整页按 (sx, sy) 缩放、锚点 `.center`，再平移 (dx, dy)）。
///
/// 位移刻意用**相对页中心**而不是绝对坐标：`frame(in: .global)` 与「页内局部原点」会因为 safe area /
/// TabView 内容区差出几十 pt，而「页中心 ≈ 屏幕中心」在 iPhone 竖屏成立 —— 这样起点矩形能跟会话卡对齐，
/// 又不必知道聊天页自己的原点在哪，也就绕开了「入场那一帧几何还没量到」的时序问题
/// （参数在**点击时**就算好了，不依赖聊天页的 onGeometryChange）。
struct ChatEntryZoomSpec {
    let sx: CGFloat
    let sy: CGFloat
    let dx: CGFloat
    let dy: CGFloat
}

/// v4.0.69：会话 → 聊天的**空间连续转场**（聊天页从被点的会话卡位置放大展开）。
///
/// 起因（用户 2026-10-07 真机）：「从会话页点击会话进入聊天内容这个过渡非常生硬，没有任何动画过渡」。
/// 成因：会话卡点击 = `SessionsView.open` → `onOpenSession` → `selected = .chat`，是一次 **TabView 换页**。
/// 系统只给 NavigationStack push 做 zoom 转场，TabView 换页是硬切 —— 而 chatTab 连其他 4 个 tab 那种
/// 0.985 微缩放都没挂（`tabTransition`），所以观感是「啪」地换一屏。
///
/// 做法（不引入 NavigationStack、不动全仓导航结构，只把这一步自己演一遍）：
///   ① 会话卡用 `onGeometryChange` 把全局 frame 静默登记到这里（**写引用类型，不触发 SwiftUI 刷新**）；
///   ② 用户点卡那一刻，用「卡片矩形 + 会话页容器矩形」算出变换参数记下（见 `begin`）；
///   ③ 聊天页入场时取走参数，把整页从「卡片大小 + 卡片位置」动画到全屏（见 `ChatZoomEntryModifier`）。
///
/// ⚠️ 为什么是类而不是 @State/@AppStorage：登记发生在**每帧滚动**里（几何一变就回调），
///    走 @State 会让整张会话列表每帧重算 body；这里只写一个字典，视图侧零成本。
@MainActor
final class ChatEntryZoom {
    static let shared = ChatEntryZoom()
    private init() {}

    /// sessionId → 该会话卡当前的全局 frame（滚动中持续刷新；行被回收后的残留值无害，取用时校验尺寸）
    private var cardFrames: [String: CGRect] = [:]
    /// 待消费的入场参数（nil = 这次换页不播展开动画，走原来的硬切）
    private var pending: ChatEntryZoomSpec?
    /// pending 的登记时刻（v4.0.69 审查）：用来丢「没人消费」的登记 —— iPad 宽屏双栏点会话不换页
    /// （那一档的 chatTab 没挂 ChatZoomEntryModifier），参数会一直留到下一次窄屏进聊天页，让那次入场
    /// 从一张不相干的旧卡片位置展开（错位动画）。超过 2s 未被取走即视为过期。
    private var pendingAt: Date?

    /// 会话卡登记自己的位置（每帧可能调用，成本 = 一次字典写）
    func record(sessionId: String, rect: CGRect) {
        guard rect.width > 1, rect.height > 1 else { return }
        cardFrames[sessionId] = rect
    }

    /// 点卡 → 记下这次展开的起点。
    ///
    /// 取不到卡片几何（搜索命中行 / 远端命中行这类没登记过的入口）= 不播，退化成原来的硬切 ——
    /// 「没登记」绝不能变成「不跳转」。
    func begin(sessionId: String, container: CGRect) {
        guard let r = cardFrames[sessionId], r.width > 1, r.height > 1,
              container.width > 1, container.height > 1 else {
            pending = nil
            pendingAt = nil
            return
        }
        // 夹到 (0.05, 1]：卡片比容器还宽（横屏 / iPad 双栏）时不放大，只做平移
        pending = ChatEntryZoomSpec(sx: min(1, max(0.05, r.width / container.width)),
                                    sy: min(1, max(0.05, r.height / container.height)),
                                    dx: r.midX - container.midX,
                                    dy: r.midY - container.midY)
        pendingAt = Date()
    }

    /// 聊天页入场取走参数（取走即清空：一次换页只消费一次）
    func consume() -> ChatEntryZoomSpec? {
        defer { pending = nil; pendingAt = nil }
        // 过期登记不播（见 pendingAt 注释）：宁可退化成硬切，也别从一张不相干的旧卡片位置展开
        guard let p = pending, let t = pendingAt, Date().timeIntervalSince(t) < 2 else { return nil }
        return p
    }
}
