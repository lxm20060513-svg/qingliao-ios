import SwiftUI

/// v4.0.126：page 分页模式下的**自绘玻璃 dock**。
///
/// 为什么需要它：`.tabViewStyle(.page(indexDisplayMode: .never))` 会由 PageTabViewStyle
/// 内部控制/隐藏系统 `UITabBar`（tabItem 仍在，但 bar 不渲染）。要给用户「贴手指滑动切页」，
/// 就只能回到 page 样式 + 自绘 dock —— 这正是 v3.0.63 之前的形态，用户说「那版滑动效果不错」。
///
/// 口径（v4.0.128 按用户「尽量跟原生一样」重定）：
///   · 档序/显隐**只读 DockLayoutKit 的结论**（`tabs` 由 DockTabView 的 dockRenderTabs 传入），
///     本文件不写死任何档位 —— 与系统 tab bar 那条路同源，顺序改了这里跟着变。
///   · 条身 = **原生液态玻璃**（`Capsule().glassEffect()`，与系统 UITabBar 同一档材质）+
///     全站唯一的柔影（`GlassEdgeSurface` 只补影，不铺底、不加边 —— 那层玻璃自带高光与描边）。
///     🚨 别给它套 `.clipShape(Capsule())`：玻璃的边缘高光会被裁掉，整条只剩中间那层灰底
///     （v4.0.127 的用户观感「发灰、颜色不协调」就是这么来的）。
///     🚨 别退回「逐颗 Button 各加 glassEffect」：那样渲染成 5 个独立玻璃圆、整条 dock 条消失
///     （v4.0.126 实发一版，v4.0.127 修）。
///   · 配色/字号/字重全部对齐系统 UITabBar：选中 = 系统 tint（accent）+ 淡色胶囊底 + 实心符号，
///     未选中 = `Color.secondary`（= secondaryLabel），图标 22pt regular、文字 10pt medium。
///     别自创主文字色/其他字号 —— 与原生并排看就会「不是同一种东西」。
struct DockPagingBar: View {
    @Binding var selected: DockTab
    let tabs: [DockTab]

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // 原生 tab bar 同款容器：条身玻璃与选中胶囊同组，液体玻璃才有统一的折射/形变
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { tab in
                    Button {
                        guard selected != tab else { return }
                        Haptics.tap()
                        withAnimation(Motion.page) { selected = tab }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 22, weight: .regular))
                                .symbolVariant(selected == tab ? .fill : .none)
                            Text(tab.title)
                                .font(.system(size: 10, weight: .medium))
                        }
                        // 与系统 tab bar 同源：选中 tint、未选中 secondaryLabel
                        .foregroundStyle(selected == tab ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if selected == tab {
                                // iOS 26 原生选中态：tint 淡色胶囊（不是实心色块）
                                Capsule()
                                    .fill(Color.accentColor.opacity(Tint.coloredFill(scheme)))
                                    .animation(.easeInOut(duration: 0.22), value: selected)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            // 5 + 内容 52（图标 22 + 间距 2 + 文字 ≈12 + 内边距 14）+ 5 ≈ 60，留在 62 的框里不溢出
            .padding(.vertical, 5)
            // 条身：原生液态玻璃（形状即 Capsule，别再加 clipShape）
            .background { Capsule().glassEffect() }
            // 只补原生那层柔影：不铺底、不加边（玻璃自带边缘高光）
            .modifier(GlassEdgeSurface(cornerRadius: 31, fill: false, edge: false))
        }
        .frame(height: 62)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("底部导航")
    }
}
