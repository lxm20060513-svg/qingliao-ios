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
///   · 玻璃用 iOS 26 `glassEffect(.regular.interactive())` **逐颗**加在 Button 上
///     （加在整条背景上不会响应触摸，v3.0.62 踩过）。
///   · 选中态 = accent 12% 胶囊 + accent 图标，与系统 tab bar 的观感对齐。
struct DockPagingBar: View {
    @Binding var selected: DockTab
    let tabs: [DockTab]

    var body: some View {
        GlassEffectContainer(spacing: 4) {
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
                    .glassEffect(.regular.interactive())
                    .padding(4)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("底部导航")
    }
}
