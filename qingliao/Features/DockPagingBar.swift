import SwiftUI

/// v4.0.126：page 分页模式下的**自绘玻璃 dock**。
///
/// 为什么需要它：`.tabViewStyle(.page(indexDisplayMode: .never))` 会由 PageTabViewStyle
/// 内部控制/隐藏系统 `UITabBar`（tabItem 仍在，但 bar 不渲染）。要给用户「贴手指滑动切页」，
/// 就只能回到 page 样式 + 自绘 dock —— 这正是 v3.0.63 之前的形态，用户说「那版滑动效果不错」。
///
/// 口径：
///   · 档序/显隐**只读 DockLayoutKit 的结论**（`tabs` 由 DockTabView 的 dockRenderTabs 传入），
///     本文件不写死任何档位 —— 与系统 tab bar 那条路同源，顺序改了这里跟着变。
///   · 玻璃是**一整条 Capsule**（`.background { Capsule().glassEffect() }`），
///     恢复 v3.0.61 的「一条毛玻璃 dock 条」观感。
///     🚨 别退回「逐颗 Button 各加 glassEffect」：那样渲染成 5 个独立玻璃圆、
///     整条 dock 条消失（v4.0.126 实发一版，v4.0.127 修）。
///     代价：没有 v3.0.62 那种逐颗按压放大/折射；点击与左右滑动切页不受影响
///     （玻璃只作底图，命中区仍是上面的 Button）。
///   · 选中态 = accent 12% 胶囊 + accent 图标 + 实心符号，与系统 tab bar 的观感对齐。
struct DockPagingBar: View {
    @Binding var selected: DockTab
    let tabs: [DockTab]

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { tab in
                    Button {
                        guard selected != tab else { return }
                        Haptics.tap()
                        withAnimation(Motion.page) { selected = tab }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 21, weight: .medium))
                                .symbolVariant(selected == tab ? .fill : .none)
                            Text(tab.title)
                                .font(.system(size: 10, weight: .semibold))
                        }
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
            // 5 + 内容 52（图标 21 + 间距 3 + 文字 ≈12 + 内边距 16）+ 5 = 62，与 `.frame(height: 62)` 对齐
            .padding(.vertical, 5)
            // 整条毛玻璃：与 v3.0.61 同款（一层 Capsule 玻璃 + 上亮下暗 0.5pt 描边 + 投影）
            .background { Capsule().glassEffect() }
            .clipShape(Capsule())
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.24), Color.white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
            }
            .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 6)
        }
        .frame(height: 62)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("底部导航")
    }
}
