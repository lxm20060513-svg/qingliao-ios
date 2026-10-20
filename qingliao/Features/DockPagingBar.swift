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
///   · v4.0.131 用户三条口径（2026-10-20，真机 v4.0.130 反馈「玻璃太白发平 / 白底栏还在 /
///     点按手感不行 / dock 太靠上」）：
///     ① 玻璃重搭四层：材质 → 面（上 0.24 白 → 中段近透 → 底冷蓝 0.10）→ 顶部 20% 折射亮线
///        → 三段描边（顶白 0.85 / 中 0.20 / **底黑 0.10**）+ 双层影。旧版 0.62 白铺满脸 = 白药片。
///     ② 白底栏：宿主那条兜底从**纯色** `pageBase` 换成 `EnvironmentGlowLayers`（与页面同视图）。
///     ③ 点按：缩放对象收窄到「图标+文字」（格宽/选中胶囊不再跟着胀），1.18 + 上抬 1.5pt + 压影，
///        spring response 0.22 / damping 0.62（旧 0.26/0.55 拖半拍）。
///     ④ 纵向落点走 `bottomGap`（见下）。
///   · v4.0.132 用户拍板「方案 A · 磨砂 + 实心图标」（2026-10-20，对比稿四选一）：
///     **只换质感，不动图标与交互** —— 实心图标、accent 12% 选中胶囊、DockIconPressStyle
///     手感全部维持 v4.0.131 原样。玻璃四层简化成「均匀磨砂」：
///     ① 材质 `.ultraThinMaterial` + ② 一层**均匀**白雾（不带任何上下渐变），
///     ③ 折射亮线与三段描边**删除**，描边换成 0.8pt 单色淡线（浅色黑 0.08 / 深色白 0.14），
///     ④ 双层影收成**单层柔影**。对比稿与近观条：scripts/ql_dockflat/mock/。
///   · 选中态 = accent 12% 胶囊。图标 22pt、文字 10pt semibold —— 老版原样，别再自创字号。
struct DockPagingBar: View {
    @Binding var selected: DockTab
    let tabs: [DockTab]

    @Environment(\.colorScheme) private var scheme

    /// dock 与底部安全区之间的留白。**负值 = 往安全区里压**（往屏幕底边走）。
    ///
    /// v4.0.131（用户 2026-10-20：「dock 太靠上了，下移一点」）：原值是 `4`，
    /// 胶囊下沿 = 安全区底(34) + 4 ≈ 距屏幕底 38pt，真机观感「悬在半空」。
    /// 改 `-8` 后胶囊下沿距屏幕底 ≈ 26pt，仍在 home indicator 上方，不压可点区。
    /// 🚨 纵向落点只认这一个常量：别再另加 `.offset(y:)`（两个位移真源必然漂移）。
    static let bottomGap: CGFloat = -8

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
                    // v4.0.131：**只让图标+文字这一坨**参与缩放（原生 dock 就是图标自己在长大，
                    // 选中胶囊和格宽不动）。v4.0.130 把 `frame(maxWidth:.infinity)` + 胶囊底
                    // 都塞在 label 里 → ButtonStyle 缩放的是**整格**（≈70pt 宽的透明块），
                    // 放大 1.16 后与邻居相压、且胶囊底跟着一起胀，真机手感「像整块在抖」。
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 22, weight: .semibold))
                            // 原生 dock 口径：实心填充，选中/未选中只靠颜色区分
                            .symbolVariant(.fill)
                        Text(tab.title)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(selected == tab ? Color.accentColor : idleInk)
                    .padding(.vertical, 8)
                    // 满格命中区留在 label 里（缩放的这一坨是透明盒，只有居中的图标会变大）
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                // 点按放大回弹（原生 dock 手感）；与 Haptics.tap() 同帧
                .buttonStyle(DockIconPressStyle())
                // 选中胶囊挂在 Button **外面** → 不跟着图标一起胀（v4.0.130 整格在胀的来源）
                .background {
                    if selected == tab {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.12))
                            .animation(.easeInOut(duration: 0.22), value: selected)
                    }
                }
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
        // v4.0.132：双层影收成**单层柔影**（磨砂方案 A：浮起来即可，不再追求玻璃的「厚度感」）
        .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.10), radius: 16, x: 0, y: 6)
        .frame(height: 62)
        .padding(.horizontal, 16)
        .padding(.bottom, Self.bottomGap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("底部导航")
    }

    // MARK: - 均匀磨砂

    /// v4.0.132「方案 A · 磨砂」：**均匀薄雾**，与 v4.0.131 玻璃四层的分界 ——
    ///   · 删「上 0.24 白 → 中透 → 底冷蓝」的面层渐变（上亮下透 = 立体感来源，磨砂不要）；
    ///   · 删顶部 20% 折射亮线（plusLighter 高光沿 = 「玻璃感」来源，磨砂不要）；
    ///   · 只留材质 + 一层**均匀**白雾：浅色白 0.16，深色白 0.06 —— 把材质调匀成一整片哑光，
    ///     不引灰（白雾只加在白系上）、不碰 glassEffect 红线（🚨 v4.0.128 两次「颜色不协调」）。
    private var glassBody: some View {
        ZStack {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(.white.opacity(scheme == .dark ? 0.06 : 0.16))
        }
    }

    /// 边缘：0.8pt **单色**淡描边（浅色黑 0.08 / 深色白 0.14）——
    /// 只负责把磨砂条从近白页底上勾出来，不再做三段渐变的「倒角厚度」。
    private var glassEdge: some View {
        Capsule().strokeBorder(
            scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08),
            lineWidth: 0.8
        )
    }
}

/// 图标点按放大（原生 dock 手感）：按下图标自己长大一点、微微抬起，松开弹回。
/// v4.0.131：缩放对象已缩到「图标+文字」本身（格宽/胶囊不参与），幅度 1.18、回弹更快
/// （response 0.22 / damping 0.62）—— 旧版 0.26/0.55 拖半拍、且整格在胀。
private struct DockIconPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.18 : 1)
            .offset(y: configuration.isPressed ? -1.5 : 0)
            .shadow(color: .black.opacity(configuration.isPressed ? 0.16 : 0), radius: 6, y: 3)
            .animation(.spring(response: 0.22, dampingFraction: 0.62), value: configuration.isPressed)
    }
}
