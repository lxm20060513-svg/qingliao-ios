import SwiftUI

// MARK: - 液态玻璃主题组件（iOS 26+ 原生 glassEffect 真液态玻璃）
// v2.0.87e：按 Apple 官方 Liquid Glass 规范——glassEffect 提供光泽/折射/边缘高光，
// 替换旧的 material+描边模拟（用户反馈不是真液态玻璃）

struct GlassCard: ViewModifier {
    // v3.9.19：卡片圆角全站统一 16（原 18，与 .dashboardCard() 不一致）
    var cornerRadius: CGFloat = 16
    @Environment(\.colorScheme) private var scheme   // v3.4.25：深色描边对比度需要感知深浅色

    func body(content: Content) -> some View {
        content
            // 原生液态玻璃（iOS 26+，部署目标已 26）
            .glassEffect()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // 液态玻璃自带边缘光泽，仅保留极轻描边增强边界
            // v3.4.25：深色模式描边对比度校准——纯黑下白 0.15 描边在玻璃边缘几乎不可见（发灰糊边），
            // 深色提到 0.22；浅色玻璃自带亮边反而过亮，降到 0.12，深浅观感一致
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(scheme == .dark ? 0.22 : 0.12), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(Tint.subtle), radius: 14, y: 5)
    }
}

// v2.0.87g：设置页密集列表卡改回毛玻璃（glassEffect 在密集卡上透出背景光斑显脏，
// 单卡场景（看板 GlassCard）保留 glassEffect；列表用低调 material 保证文字可读）
// v2.0.87ac：浅色下去 thinMaterial 灰蒙板 → 白底 0.85（用户反馈灰色蒙板）
struct GlassListCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(
                scheme == .dark
                    ? AnyShapeStyle(.ultraThinMaterial)
                    : AnyShapeStyle(Color.white.opacity(0.85)),
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)   // v3.9.19：卡片圆角统一 16（原 14）
            )
            // v3.4.21：分组容器 0.8pt 浅描边（追平门锁卡/PinCard/SessionRow 全站卡片规范）
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Tint.line(scheme), lineWidth: 0.8)   // v3.9.19：深浅描边统一走 Tint.line
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

// MARK: - 聊天气泡色值（集中管理，消除 ChatComponents.swift 内硬编码 RGB）

struct BubbleTheme {
    /// 用户气泡蓝色（深色/浅色模式 × 正常/高亮状态）
    static func userBubble(scheme: ColorScheme, highlighted: Bool = false) -> Color {
        highlighted
            ? (scheme == .dark ? Color(red: 0.20, green: 0.32, blue: 0.62) : Color(red: 0.38, green: 0.55, blue: 0.92))
            : (scheme == .dark ? Color(red: 0.13, green: 0.22, blue: 0.45) : Color(red: 0.27, green: 0.47, blue: 0.88))
    }

    /// AI 气泡灰色（深色 systemGray5 / 浅色 systemGray6）
    static func aiBubble(scheme: ColorScheme, highlighted: Bool = false) -> Color {
        highlighted
            ? Color.accentColor.opacity(Tint.subtle)
            : (scheme == .dark ? Color(uiColor: .systemGray5) : Color(uiColor: .systemGray6))
    }
}

// MARK: - 看板卡片统一样式（DeviceCard / MeterCard / ServiceCard 共用）
// 玻璃底（v3.9.83，用户拍板「跟长按智慧球功能胶囊同款」）+ 0.8pt 白描边 + 圆角裁剪，一处定义全站复用
//
// ⚠️ 圆角约定（v3.8.1 起，防回归）：
//   · 卡片一律 **16**（dashboardCard() 默认值）：看板 DeviceCard/MeterCard/ServiceCard、智能建议卡、
//     空态/提示条，生活股票格/资讯长卡/备忘录卡、提示条，云端看板统计卡 —— 用户要求"都要一致"
//   · 唯一例外：看板空调高亮卡（渐变 + 投影 + 1pt 描边）刻意用 22，属 hero 卡，未拉平
//   · 图标底板 / 分段控件等非卡片元素不受此约定（8/10/12/14 各自合适即可）
//   改一侧就要同步另一侧，别让生活页看着比看板"方"（用户 2026-09-11 反馈）

struct DashboardCardStyle: ViewModifier {
    var cornerRadius: CGFloat = 16
    // v3.9.34：描边跟随深浅色。原先写死 Tint.faint（0.08）——深色下卡片边界几乎消失，
    // 且与设置页 GlassListCard 的 Tint.line（浅 0.08 / 深 0.16）不是一路。
    // 现统一走 Tint.line，档位/线宽（0.8pt）与 GlassListCard 完全同参，未新增档位。
    // v3.9.35：方案 A「柔影精修」（用户从对比稿拍板）——层次不再只靠一条描边硬撑：
    //   两层柔影（近层收边界 1px/6%、远层撑浮起 16px/5%），对应对比稿
    //   box-shadow: 0 1px 2px rgba(0,0,0,.06), 0 6px 16px rgba(0,0,0,.05)。
    //   深色下柔影物理不可见（纯黑底），层次仍由 Tint.line 描边承担——与对比稿结论一致。
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            // v3.9.83（用户拍板）：卡底改「长按智慧球功能胶囊」同款原生玻璃
            //（OrbQuickMenu.swift:398 口径 = glassEffect + 白 0.8pt 描边浅 0.12/深 0.22 + 单层柔影）。
            // 🚨 矩形卡必须显式 in: RoundedRectangle（裸 glassEffect 默认 Capsule，会渲染成大弧度胶囊蒙版）。
            // 卡不是可点元素本体（可点性在卡内 Button 上），走静态卡口径不加 .interactive()。
            // 圆角仍 16（用户明确 16，非胶囊档）；GlassCard 的 shadow 档（14/5）比胶囊重，取胶囊档 10/4。
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(scheme == .dark ? 0.22 : 0.12), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

// MARK: - v3.9.47 弹窗内卡片（半透明毛玻璃底 · 圆角 16）
//
// 由头：v3.9.46 那五张看板详情弹窗的卡底走 `.dashboardCard()` = `secondarySystemGroupedBackground`
// 实色灰白。铺在**弹窗**那层系统材质上等于盖了块白板，把弹窗材质完全遮死（用户 2026-09-21：
// 「所有卡片不要用白色背景，用半透明毛玻璃背景，16 的圆角」）。
// 这里只换背景那一层：卡形/描边/圆角/两层柔影与 `dashboardCard()` 逐字同参，
// 材质取 `.ultraThinMaterial`（真半透明，透出弹窗底色），**不是** `GlassListCard` 浅色档那种
// `Color.white.opacity(0.85)`（用户明确不要白底）。
// ⚠️ 与 v3.9.23/v3.9.24 那条红线不冲突：那条说的是**弹窗自身**不要铺背景盖住系统材质；
//    本修饰器只作用在弹窗内部的卡片上，弹窗根层依旧一个 background 都不加。

struct SheetFrostCard: ViewModifier {
    var cornerRadius: CGFloat = 16      // 全站卡片圆角口径 16（见上方 v3.8.1 圆角约定）
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Tint.line(scheme), lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }
}

// MARK: - v4.0.0 整页玻璃底（设置页）
//
// 由用户定稿：「设置页的背景也改成跟意图卡一样的玻璃式」→ 拍板「**整页铺玻璃底**（含二级页），分组卡浮在上面透光」。
//
// 为什么不是「给页底铺一个 .ultraThinMaterial」：Material 只是把背后内容模糊，**背后没内容时就退化成一块
// 白/灰板** —— 这正是本轮刚修掉的「意图卡看着像实心白卡」的同一个坑（浅色底上模糊后仍接近白）。
// 原生 `.glassEffect` 才有折射与边缘高光，所以这里底层给不透明 systemBackground 当折射源，上层再铺玻璃。
//
// ⚠️ 玻璃层挂在**内容下面**（zOrder 靠 background 实现），分组卡（glassListCard）浮在上面，
//    不要改成盖在内容之上，否则列表文字会被玻璃糊住。

struct GlassPageBackground: ViewModifier {
    // v4.0.0 审查 F3 后**故意不再有 cornerRadius 参数**：整页玻璃一律不圆角
    //   （ignoresSafeArea 只扩 frame 不裁形状，带圆角会露四个切角）。留着这个参数会诱导
    //   后来人又传回 22，玻璃页就又变成「浮在屏幕上的面板」。
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                // 🚨 审查 F2 抓到的真错：原先写成 `.background(A).background(B)` 两层 ——
                //   SwiftUI 里**先挂的 background 画得更靠前**（叠放顺序 内容 → A → B），
                //   而 A 是不透明 systemBackground，等于**把玻璃 B 压死**，玻璃完全不可见，
                //   页面观感就是纯 systemBackground —— 玻璃白做了（且注释里的推理正好写反）。
                // 改法：**单层 ZStack 一次画完**，顺序无关：折射源在最下、玻璃盖在上面。
                //   分组卡（glassListCard）是 content 的一部分，天然浮在玻璃之上。
                ZStack {
                    // 折射源：必须不透明，且**不是纯白**——留一点明度差，原生玻璃才有东西可折射
                    Color(uiColor: .systemBackground)
                    Color.accentColor.opacity(scheme == .dark ? 0.10 : 0.06)
                    // 与 dashboardCard / 意图卡同一档玻璃（.regular）。
                    // 🚨 审查 F3：整页档**不能沿用卡片的 22 圆角** —— ignoresSafeArea 只扩 frame
                    //   不裁形状，22 圆角会留四个切角 + 角外露底，看着像浮在屏幕上的面板而非整页底。
                    //   故整页一律不圆角（用 Rectangle 形状本身，in: 同形）。
                    Rectangle()
                        .glassEffect(.regular, in: Rectangle())
                        .ignoresSafeArea()
                }
                .ignoresSafeArea()
            }
    }
}

// MARK: - v3.9.78 浮层卡片（半透明毛玻璃底 · 淡色描边 + 白亮边 · 大圆角）
//
// 由头（用户 2026-09-25）：「弹窗卡片圆角加大，背景改成模糊半透明」——先出三候选稿
// （16+玻璃 / 22+玻璃 / 22+更透），用户拍板 **方案 C = 圆角 22 + ultraThinMaterial（同族最薄、最透）**。
//
// 与 `SheetFrostCard`(v3.9.47) 的分工（别混用，也别合并）：
//   · `SheetFrostCard` = **弹窗内部**的常规卡片：圆角 16、`Tint.line` 发丝描边、自带两层柔影；
//   · 本修饰器 = **浮层卡片**（意图动作卡 / AI 识别浮层卡 / 速记待办输入卡）：圆角默认 `Radius.hero`(22)、
//     **外圈淡色描边**（`Tint.line` 0.8pt，浅 0.08 / 深 0.16 —— 用户 2026-09-25 追加：「弹窗卡片边框加淡色描边」，
//     纯白亮边在浅色底上几乎看不见）+ **内缩 0.8pt 的白 0.8pt 亮边**（浅 0.12 / 深 0.22，与 `GlassCard` 同参）、
//     **不带阴影**（阴影由调用点自己给，浮层各自的投影半径不同）。
// ⚠️ 与 v3.9.23「弹窗自身不铺背景」那条红线不冲突：本修饰器只作用在**卡片**上。
// ⚠️ 圆角与描边必须同一个角值 —— 漏一处就会出现「方框套圆框」（本仓 v3.9.63 实录）。

struct OverlayGlassCard: ViewModifier {
    var cornerRadius: CGFloat = Radius.hero
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // v3.9.78 追加（用户：「弹窗卡片边框加淡色描边」）：纯白亮边在**浅色底**（聊天页 systemBackground）上
            // 几乎看不见 → 外圈压一条 `Tint.line` 淡色线做可见边界（浅 0.08 / 深 0.16，全站描边同参）。
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Tint.line(scheme), lineWidth: 0.8)
            )
            // 白 0.8pt 亮边**内缩 0.8pt** 排在外圈淡色线里侧：保留玻璃高光，两条线不重叠（仍只有一处半径参数）
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(scheme == .dark ? 0.22 : 0.12), lineWidth: 0.8)
                    .padding(0.8)
            )
    }
}

// MARK: - 滚动层次感（v3.9.0 批3）
// 卡片进出视口时轻微缩放 + 淡出。**必须挂在 Lazy 容器内的元素上**（挂在外层 ScrollView 上无效）。
// 数值收在这一处：原来只有会话列表手写 0.965/0.75，现在看板/生活卡片复用同一档。

struct ScrollDepth: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollTransition(.interactive, axis: .vertical) { view, phase in
            view
                .scaleEffect(phase.isIdentity ? 1 : 0.965)
                .opacity(phase.isIdentity ? 1 : 0.75)
        }
    }
}

extension View {
    /// 滚动层次感（卡片/列表行用；Lazy 容器内才生效）
    func scrollDepth() -> some View { modifier(ScrollDepth()) }

    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
    func glassListCard() -> some View {
        modifier(GlassListCard())
    }
    /// v4.0.0：整页玻璃底（设置页用）。
    /// 做法与意图卡（`.glassEffect(.regular)`）**同一口径**，但铺满全页：
    ///   · 底层 = systemBackground（不透明，作玻璃要折射的内容源；玻璃是「透出背后的东西」，
    ///     底下什么都没有的话玻璃只会退化成一块白/灰板 —— 这正是「material 垫浅色底看着像实心白卡」的坑）
    ///   · 上层 = 全页 `.glassEffect(.regular, in: RoundedRectangle)`，与 dashboardCard 同一档玻璃
    /// 分两层而非只铺 material：只有真·原生玻璃才有折射/高光，换 Material 得不到那个观感。
    func glassPageBackground() -> some View {
        modifier(GlassPageBackground())
    }
    func dashboardCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(DashboardCardStyle(cornerRadius: cornerRadius))
    }
    /// 弹窗内的卡片：毛玻璃底 + 16 圆角（卡形与 `dashboardCard()` 同参，只把实色卡底换成半透明）
    func frostedCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(SheetFrostCard(cornerRadius: cornerRadius))
    }
    /// v3.9.78 浮层卡片：毛玻璃底 + 大圆角（默认 `Radius.hero` 22）+ 外圈淡色描边（`Tint.line` 0.8pt）+
    /// 内缩 0.8pt 的白 0.8pt 亮边，**不带阴影**（阴影由调用点按各自的浮层投影给；
    /// 意图动作卡 / 识别浮层卡 / 速记待办输入卡都走这个）
    func overlayGlassCard(cornerRadius: CGFloat = Radius.hero) -> some View {
        modifier(OverlayGlassCard(cornerRadius: cornerRadius))
    }
}

// MARK: - 页面通用头部

struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var trailing: AnyView? = nil
    // 真实状态点：默认不显示（装饰性绿点已废弃），需要状态指示的页面显式传入
    var showStatus: Bool = false
    var statusColor: Color = .green
    // v3.5.1：AI 正在输入态（微信式）——subtitle 位置显示「AI 正在输入…」+ 三点呼吸，替代状态点
    var busy: Bool = false

    /// 显式 init：避免复杂调用处 memberwise init 推断导致类型检查超时
    init(title: String, subtitle: String? = nil, trailing: AnyView? = nil,
         showStatus: Bool = false, statusColor: Color = .green, busy: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.showStatus = showStatus
        self.statusColor = statusColor
        self.busy = busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: Typography.titleXL, weight: .bold))
                    .accessibilityAddTraits(.isHeader)   // v3.9.19：VoiceOver 转子按标题跳转
                Spacer()
                if let trailing { trailing }
            }
            if let subtitle {
                HStack(spacing: 5) {
                    if busy {
                        // v3.5.1：AI 正在输入（三点呼吸，仅 opacity 动画——守 v3.2.3 渲染红线）
                        BusyDots()
                    } else if showStatus {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                    }
                    Text(busy ? "AI 正在思考中" : subtitle)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(busy ? Color.accentColor : Color.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.md)
    }
}

/// v3.5.1：header 小三点（AI 正在输入）——3 个 3.5pt 圆点依次呼吸。
/// 只用 opacity 动画、无 shadow/blur，守住 v3.2.3 渲染卡死红线。
struct BusyDots: View {
    // v3.9.19：无障碍——系统「降低动态效果」开启时不做循环呼吸（照抄 Skeleton.swift 先例）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 3.5, height: 3.5)
                    .opacity(on ? 1.0 : 0.28)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.16), value: on)
            }
        }
        .onAppear { on = true }
    }
}

// MARK: - v2.0.87bb 新版 Siri 边框发光特效（AI 回答时屏幕边缘渐变光晕）

struct SiriGlowOverlay: View {
    // v2.0.90a：动效参数可调（设置 → 外观 → Siri 边框发光 → 动效调整）
    // 默认值 = v2.0.87bn 定稿效果（亮度 1.0 / 频率 2.2 / 幅度 0.18 / 光带 22pt）
    @AppStorage("qingliao_siri_glow_brightness") private var glowBrightness = 1.0
    @AppStorage("qingliao_siri_glow_freq") private var glowFreq = 2.2
    @AppStorage("qingliao_siri_glow_amp") private var glowAmp = 0.18
    @AppStorage("qingliao_siri_glow_width") private var glowWidth = 22.0
    /// v3.9.42：「减弱动态效果」→ 不接帧源，定稿一帧（见 body 注释）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // v3.9.1：锁 30fps（原 .animation = 系统全帧率，ProMotion 最高 120fps）。
        //          呼吸是 0.55s 慢正弦，30fps 肉眼无差；全屏渐变 + mask + blur 是全 App 最贵的画面，
        //          减半帧率就是直接省电（与 ChatEffects 粒子「锁 30fps」同一约定）
        // v3.9.42：该辅助功能开启时连 30fps 都不给——TimelineView 整条不建，取正弦中值画静态一帧。
        //          光晕本身是"AI 正在回答"的状态提示，静态照样传达，只是不呼吸。
        Group {
            if reduceMotion {
                glow(breathe: (0.30 + glowAmp / 2) * glowBrightness)
            } else {
                let schedule: AnimationTimelineSchedule = .animation(minimumInterval: 1.0 / 30.0)
                TimelineView(schedule) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    glow(breathe: (0.30 + glowAmp * (sin(t * glowFreq) + 1) / 2) * glowBrightness)
                }
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    /// 一帧发光（breathe = 该帧的整体透明度系数）；拆函数同时给 body 与静态分支复用，也避开 CI 类型检查超时
    private func glow(breathe: Double) -> some View {
        // v2.0.87bl：GeometryReader 取容器尺寸 + 顶部补偿状态栏；只 ignoresSafeArea(.top)
        //（底部 dock 的 safe area 保持不动 → 根治 dock 偏位）
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height + geo.safeAreaInsets.top
            Rectangle()
                .fill(
                    AngularGradient(
                        colors: [.blue.opacity(0.42 * breathe), .indigo.opacity(0.38 * breathe),
                                 .pink.opacity(0.38 * breathe), .red.opacity(0.28 * breathe), .blue.opacity(0.42 * breathe)],
                        center: .center
                    )
                )
                .mask(
                    Path { p in
                        // v2.0.90a：光带宽度可调（默认 22pt）
                        let e = CGFloat(glowWidth)
                        p.addRect(CGRect(x: 0, y: 0, width: w, height: h))
                        p.addRect(CGRect(x: e, y: e, width: w - 2 * e, height: h - 2 * e))
                    }
                    .fill(style: FillStyle(eoFill: true))
                )
                .blur(radius: 8)
                .frame(width: w, height: h)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - v3.0.36 灵动岛发光（AI 回答时灵动岛外一圈 Siri 同款光晕）

/// 围绕灵动岛（顶部居中胶囊）的呼吸光晕；复用 Siri 发光 4 参数（外观统一）。
/// 与 SiriGlowOverlay 同条件触发（streaming）且可独立开关（qingliao_island_glow）。
struct IslandGlowOverlay: View {
    @AppStorage("qingliao_siri_glow_brightness") private var glowBrightness = 1.0
    @AppStorage("qingliao_siri_glow_freq") private var glowFreq = 2.2
    @AppStorage("qingliao_siri_glow_amp") private var glowAmp = 0.18
    /// v3.9.42：「减弱动态效果」→ 不接帧源，定稿一帧（同 SiriGlowOverlay）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 灵动岛胶囊近似尺寸（iPhone 14 Pro 系列 ~126×37，15 Pro 系列 ~121×37；取通用值光晕略大更醒目）
    private let islandW: CGFloat = 132
    private let islandH: CGFloat = 40

    var body: some View {
        // v3.9.1：锁 30fps（原 .animation = 系统全帧率，ProMotion 最高 120fps）。
        //          呼吸是 0.55s 慢正弦，30fps 肉眼无差；全屏渐变 + mask + blur 是全 App 最贵的画面，
        //          减半帧率就是直接省电（与 ChatEffects 粒子「锁 30fps」同一约定）
        Group {
            if reduceMotion {
                glow(breathe: (0.46 + glowAmp / 2) * glowBrightness)
            } else {
                let schedule: AnimationTimelineSchedule = .animation(minimumInterval: 1.0 / 30.0)
                TimelineView(schedule) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    // 呼吸（与 Siri 发光同公式，参数联动）；灵动岛版底值 0.30→0.46：整体更亮（0.46~0.64）
                    glow(breathe: (0.46 + glowAmp * (sin(t * glowFreq) + 1) / 2) * glowBrightness)
                }
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    /// 一帧发光（breathe = 该帧的整体透明度系数）
    private func glow(breathe: Double) -> some View {
        GeometryReader { geo in
            let top = geo.safeAreaInsets.top
            // 灵动岛中心 Y = 状态栏内（v3.0.37：下移 10pt 贴合真实灵动岛——原 -6 偏上；v3.0.44：再下移 1pt；v3.0.57：再下移 2pt；v3.0.58：再下移 1pt）
            let cx = geo.size.width / 2
            let cy = top + islandH / 2 + 8
            ZStack {
                // 外圈光晕（胶囊描边 + 渐变呼吸）
                // v3.0.57：颜色调亮——透明度系数提高（0.65/0.55/0.5 → 0.9/0.8/0.75）；v3.0.58：再调亮调艳（→ 1.0/0.95/0.92 近满饱和）
                // 三度调亮调艳——呼吸底值 0.30→0.46、饱和度 ×1.5、光带 5→7pt、blur 5→4（色芯更聚更艳）
                RoundedRectangle(cornerRadius: islandH / 2, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            colors: [.blue.opacity(1.00 * breathe), .indigo.opacity(0.95 * breathe),
                                     .pink.opacity(0.92 * breathe), .blue.opacity(1.00 * breathe)],
                            center: .center
                        ),
                        lineWidth: 7
                    )
                    .frame(width: islandW + 8, height: islandH + 8)
                    .blur(radius: 4)
                    .saturation(1.5)
                // 内层实心发光（贴近胶囊边缘）
                RoundedRectangle(cornerRadius: islandH / 2, style: .continuous)
                    .strokeBorder(.white.opacity(0.9 * breathe), lineWidth: 2)
                    .frame(width: islandW, height: islandH)
                    .blur(radius: 2)
            }
            .position(x: cx, y: cy)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - 弹窗背景：不做材质覆盖（v3.9.23 决策记录，勿再尝试）
//
// 一轮试错（v3.9.22）：曾给全仓 59 个 `.sheet` 挂 `.presentationBackground(.ultraThinMaterial)`
// 想"统一毛玻璃"，真机反馈**观感回退** —— 因为 iOS 26 系统给弹窗的默认底本身就是玻璃材质，
// 用 `ultraThinMaterial` 盖上去等于拿旧材质覆盖系统那层，反而显得又旧又灰。
//
// 结论（用户所说的"设置里关于轻聊那种" = 系统默认）：
//   · **弹窗背景一律不覆盖**，让系统默认生效，这就是"统一"；
//   · 真正让弹窗看起来不统一的是**内容视图自带的不透明底**
//     （`.background(Color(uiColor: .systemBackground))` / `.systemGroupedBackground`）→ 已清理 11 处；
//   · 内容为 `List` / `Form` 时自带底同样会盖住系统材质 → 用 `.scrollContentBackground(.hidden)`（全仓 23 处）；
//   · `.fullScreenCover` 本就不支持 `presentationBackground`；系统分享面板背景由系统控制。
