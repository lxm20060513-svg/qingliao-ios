import SwiftUI
import UIKit

// MARK: - v3.9.47 Dock 玻璃方案 B：聊天页卸掉系统 tab bar 的液态玻璃

/// 挂在 `TabView` 上的**零尺寸**探针视图：`clear == true` 时把系统 tab bar 的外观换成透明副本，
/// 切走后再原样还回去。只挂一处（TabView），切页由 `selected == .chat` 驱动。
///
/// 为什么走 UIKit：方案 A（SwiftUI `.toolbarBackground(.hidden, for: .tabBar)`）真机实测只褪背景色、
/// 玻璃层照旧。这里直接改真实 `UITabBar` 的 `standardAppearance` / `scrollEdgeAppearance`。
/// ⚠️ iOS 26 的系统玻璃是否吃 `UITabBarAppearance` 没有权威文档背书 —— **需真机验收**；
/// 若无效就到此为止，**不要**改回「在 TabView 下面铺不透明层」（v3.4.29 红线：会掐死滚动边缘折射）。
struct TabBarGlassClearer: UIViewRepresentable {
    var clear: Bool

    func makeUIView(context: Context) -> TabBarGlassProbe {
        TabBarGlassProbe(clear: clear)
    }

    func updateUIView(_ uiView: TabBarGlassProbe, context: Context) {
        uiView.setClear(clear)
    }
}

/// 状态全放在这个 UIView 上（它天生 `@MainActor`，生命周期与挂载点一致）：
/// 不用 Coordinator，省掉 Swift 6 下「nonisolated `makeCoordinator` 里造 `@MainActor` 实例」的隔离问题。
final class TabBarGlassProbe: UIView {

    private var clearRequested: Bool
    private weak var bar: UITabBar?
    /// 系统原始外观，只在第一次改动前存一份，切走时原样还原
    private var original: (standard: UITabBarAppearance?, scrollEdge: UITabBarAppearance?)?
    private var applied = false
    /// 首次挂上时 tab bar 往往还没布局好，延迟重扫（口径同 `DockOrbOverlay.refreshLiveCenter`）
    private var retryScheduled = false

    init(clear: Bool) {
        self.clearRequested = clear
        super.init(frame: .zero)
        // 不隐藏：隐藏视图虽然仍在层级里，但没必要赌 SwiftUI 会不会为它建宿主 —— 透明零尺寸本身就不画东西
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { .zero }

    func setClear(_ clear: Bool) {
        clearRequested = clear
        attach()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        attach()
    }

    // MARK: - 装卸

    /// 找到当前真实 tab bar 并同步外观；bar 还没长出来时排两次延迟重试
    private func attach() {
        guard let found = locateTabBar() else {
            guard !retryScheduled, window != nil else { return }
            retryScheduled = true
            for delay in [0.15, 0.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.attach()
                }
            }
            return
        }
        retryScheduled = false
        if bar !== found {
            // tab bar 被系统重建（换 appearance 缓存失效）→ 重新认一次
            bar = found
            original = nil
            applied = false
        }
        apply()
    }

    @MainActor
    private func locateTabBar() -> UITabBar? {
        if let host = window, let t = DockOrbOverlay.findTabBar(in: host) { return t }
        // 探针还没进窗口层级时（首次 updateUIView 早于 didMoveToWindow）退到 keyWindow 找
        guard let key = DockOrbOverlay.keyWindow else { return nil }
        return DockOrbOverlay.findTabBar(in: key)
    }

    private func apply() {
        guard let bar else { return }
        if clearRequested {
            if original == nil {
                original = (bar.standardAppearance, bar.scrollEdgeAppearance)
            }
            guard !applied else { return }
            bar.standardAppearance = transparentAppearance()
            bar.scrollEdgeAppearance = transparentAppearance()
            applied = true
        } else {
            guard applied, let saved = original else { return }
            bar.standardAppearance = saved.standard ?? UITabBarAppearance()
            bar.scrollEdgeAppearance = saved.scrollEdge
            applied = false
        }
    }

    /// 透明副本：背景色清空 + 去掉 backgroundEffect（iOS 26 的玻璃若挂在 appearance 上就是这一层）
    private func transparentAppearance() -> UITabBarAppearance {
        let a = UITabBarAppearance()
        a.configureWithTransparentBackground()
        a.backgroundEffect = nil
        a.shadowColor = .clear
        a.shadowImage = UIImage()
        return a
    }
}
