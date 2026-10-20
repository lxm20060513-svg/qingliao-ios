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
        // v4.0.131：双层影 —— 大范围柔影负责「浮起来」，1pt 紧贴影负责「贴住」，
        // 单层影在近白页底上几乎看不见（旧版 0.10 / r12 / y5 就是被说「发平」的一半原因）。
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.14), radius: 16, x: 0, y: 6)
        .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.06), radius: 3, x: 0, y: 1)
        .frame(height: 62)
        .padding(.horizontal, 16)
        .padding(.bottom, Self.bottomGap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("底部导航")
    }

    // MARK: - 自绘玻璃

    /// v4.0.131（用户 2026-10-20「玻璃太白发平，不像毛玻璃」）——
    /// 旧版把 0.62 的白铺满上半段、下缘又压 0.30 白，等于在近白的页底（#FAFAFC）上
    /// 刷了一层**实心白药片**：没有面的层次、没有边、也没有透光，观感就是「一条白条」。
    /// 现在按玻璃的四层来搭（全部仍是白色/极淡冷色叠加，**不引灰**、不碰 glassEffect 红线）：
    ///   ① 材质层 `.ultraThinMaterial` —— 唯一负责「透」的一层，白叠得越少它越显；
    ///   ② 面层：上 0.24 白 → 中段近乎透明（0.04）→ 底部一点冷蓝 0.10，做出「上薄下厚」的体积；
    ///   ③ 折射亮线：只在最上面 20% 收一道 0.62 白（plusLighter），玻璃被光切到的那个高光沿；
    ///   ④ 边界：外描边改为 白0.85(顶) → 白0.20(中) → 黑0.10(底) 的三段渐变，
    ///      底缘那道深线是「玻璃厚度」的关键 —— 白底上只看白边的话永远糊成一片。
    private var glassBody: some View {
        ZStack {
            Capsule().fill(.ultraThinMaterial)
            // ② 面：上亮下透 + 一点点冷色收底
            Capsule().fill(
                LinearGradient(
                    stops: scheme == .dark
                        ? [.init(color: .white.opacity(0.10), location: 0),
                           .init(color: .white.opacity(0.02), location: 0.5),
                           .init(color: .black.opacity(0.12), location: 1)]
                        : [.init(color: .white.opacity(0.24), location: 0),
                           .init(color: .white.opacity(0.04), location: 0.45),
                           .init(color: Color(red: 0.80, green: 0.86, blue: 1.0).opacity(0.10), location: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // ③ 折射亮线：窄窄一条，别铺半张脸
            Capsule()
                .fill(
                    LinearGradient(
                        stops: [.init(color: .white.opacity(scheme == .dark ? 0.14 : 0.62), location: 0),
                                .init(color: .clear, location: 0.20)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.plusLighter)
        }
    }

    /// 边缘：三段渐变描边（顶高光 → 中段弱 → 底缘深线），把玻璃的「倒角」立起来。
    private var glassEdge: some View {
        Capsule().strokeBorder(
            LinearGradient(
                stops: scheme == .dark
                    ? [.init(color: .white.opacity(0.26), location: 0),
                       .init(color: .white.opacity(0.08), location: 0.55),
                       .init(color: .black.opacity(0.35), location: 1)]
                    : [.init(color: .white.opacity(0.85), location: 0),
                       .init(color: .white.opacity(0.20), location: 0.55),
                       .init(color: .black.opacity(0.10), location: 1)],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: 1
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
