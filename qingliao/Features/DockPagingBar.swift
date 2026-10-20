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
///   · 底材 = `Capsule().fill(.ultraThinMaterial)` 白毛玻璃 + **自绘玻璃层**
///     （上方白色高光渐变 + 上沿 1pt 镜面描边），不把彩调吸进来、也不会压灰。
///     🚨 别换回 `.glassEffect()`：v4.0.128 实测整条比周围卡片灰一档，用户两次报「颜色不协调」。
///     🚨 别退回「逐颗 Button 各加 glassEffect」：渲染成 5 个独立玻璃圆、整条 dock 条消失
///     （v4.0.126 实发一版，v4.0.127 修）。
///   · v4.0.130 用户三条口径：
///     ① 图标一律**实心填充**（`.symbolVariant(.fill)`，全 5 颗都填 —— 与原生 dock 一致），
///        未选中 = `Color.primary`（浅色下即黑色），选中 = accent。别退回「未选中空心灰线」。
///     ② 点按有**放大回弹**（`DockIconPressStyle`，原生 dock 那颗的手感）。
///     ③ dock 下方不许再露出一层白色底栏 —— 宿主 DockTabView 里由 page 底兜住（见那里的注释）。
///   · 选中态 = accent 12% 胶囊。图标 22pt、文字 10pt semibold —— 老版原样，别再自创字号。
struct DockPagingBar: View {
    @Binding var selected: DockTab
    let tabs: [DockTab]

    @Environment(\.colorScheme) private var scheme

    /// 未选中图标色：浅色下取 primary（黑），深色下自动翻白，不做灰度衰减。
    private var idleInk: Color { Color.primary }

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
                            .font(.system(size: 22, weight: .semibold))
                            // 原生 dock 口径：实心填充，选中/未选中只靠颜色区分
                            .symbolVariant(.fill)
                        Text(tab.title)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(selected == tab ? Color.accentColor : idleInk)
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
                // 点按放大回弹（原生 dock 手感）；与 Haptics.tap() 同帧
                .buttonStyle(DockIconPressStyle())
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected == tab ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 4)
        // 内容 52（图标 22 + 间距 3 + 文字 ≈12 + 内边距 16）+ 4 ≈ 60，留在 62 的框里不溢出
        .padding(.vertical, 4)
        // 底材：白毛玻璃（老版口径，绝不用 glassEffect —— 它会压灰）
        .background { glassBody }
        .clipShape(Capsule())
        .overlay { glassEdge }
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.10), radius: 12, x: 0, y: 5)
        .frame(height: 62)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("底部导航")
    }

    // MARK: - 自绘玻璃

    /// 材质模糊 + 两层白色高光：上沿透亮、下半略沉，做出玻璃厚度感。
    /// 只用白色叠加（不提灰），避免 v4.0.128 glassEffect 把页底彩调吸进来再压一层灰。
    private var glassBody: some View {
        ZStack {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(
                LinearGradient(
                    stops: scheme == .dark
                        ? [.init(color: .white.opacity(0.10), location: 0),
                           .init(color: .white.opacity(0.02), location: 0.55),
                           .init(color: .white.opacity(0.05), location: 1)]
                        : [.init(color: .white.opacity(0.62), location: 0),
                           .init(color: .white.opacity(0.16), location: 0.55),
                           .init(color: .white.opacity(0.30), location: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // 上沿镜面高光带（玻璃折射的那道亮线），只铺上半段
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(scheme == .dark ? 0.16 : 0.55), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .blendMode(.plusLighter)
        }
    }

    /// 边缘：外描边（白→透）+ 内侧上亮下暗，玻璃的「倒角」感。
    private var glassEdge: some View {
        ZStack {
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(scheme == .dark ? 0.22 : 0.75),
                             Color.white.opacity(0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.75
            )
            Capsule().strokeBorder(Color.black.opacity(scheme == .dark ? 0.30 : 0.05), lineWidth: 0.5)
                .blur(radius: 0.8)
                .offset(y: 0.6)
                .mask(Capsule())
        }
    }
}

/// 图标点按放大（原生 dock 手感）：按下 1.16、松开回弹，不用长按态。
private struct DockIconPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.16 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.55), value: configuration.isPressed)
    }
}
