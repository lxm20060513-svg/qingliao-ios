import SwiftUI

/// v4.0.126：page 分页模式下的**自绘 dock**。
///
/// 为什么需要它：`.tabViewStyle(.page(indexDisplayMode: .never))` 会由 PageTabViewStyle
/// 内部控制/隐藏系统 `UITabBar`（tabItem 仍在，但 bar 不渲染）。要给用户「贴手指滑动切页」，
/// 就只能回到 page 样式 + 自绘 dock —— 这正是 v3.0.63 之前的形态，用户说「那版滑动效果不错」。
///
/// 口径（v4.0.129 用户拍板：**回到更早那版「胶囊毛玻璃 dock」**，液态玻璃那套试验全部作废）：
///   · 档序/显隐**只读 DockLayoutKit 的结论**（`tabs` 由 DockTabView 的 dockRenderTabs 传入），
///     本文件不写死任何档位 —— 与系统 tab bar 那条路同源，顺序改了这里跟着变。
///   · 底材 = `Capsule().fill(.ultraThinMaterial)` 白毛玻璃（v3.0.46 之前的老口径，
///     与页面卡片同一层白，不会像液态玻璃那样把页底彩调吸进来再压一层灰）。
///     🚨 别换回 `.glassEffect()`：v4.0.128 实测整条比周围卡片灰一档，用户两次报「颜色不协调」。
///     🚨 别退回「逐颗 Button 各加 glassEffect」：渲染成 5 个独立玻璃圆、整条 dock 条消失
///     （v4.0.126 实发一版，v4.0.127 修）。
///   · 选中态 = accent 12% 胶囊 + accent 图标 + 实心符号；未选中 = `Color.secondary`。
///     图标 22pt medium、文字 10pt semibold —— 老版原样，别再自创字号/字重/主文字色。
struct DockPagingBar: View {
    @Binding var selected: DockTab
    let tabs: [DockTab]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    guard selected != tab else { return }
                    Haptics.tap()
                    withAnimation(Motion.page) { selected = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 22, weight: .medium))
                            .symbolVariant(selected == tab ? .fill : .none)
                        Text(tab.title)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    // 与老版 dock 同源：选中 accent、未选中 secondaryLabel
                    .foregroundStyle(selected == tab ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if selected == tab {
                            Capsule()
                                .fill(Color.accentColor.opacity(0.12))
                                .animation(.easeInOut(duration: 0.22), value: selected)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        // 内容 52（图标 22 + 间距 3 + 文字 ≈12 + 内边距 16）+ 4 ≈ 60，留在 62 的框里不溢出
        .padding(.vertical, 4)
        // 底材：白毛玻璃（老版口径，绝不用 glassEffect —— 它会压灰）
        .background { Capsule().fill(.ultraThinMaterial) }
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.38), Color.white.opacity(0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.5
            )
        }
        .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 5)
        .frame(height: 62)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("底部导航")
    }
}
