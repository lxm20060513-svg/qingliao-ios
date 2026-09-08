import SwiftUI

// MARK: - 液态玻璃主题组件（iOS 26+ 原生 glassEffect 真液态玻璃）
// v2.0.87e：按 Apple 官方 Liquid Glass 规范——glassEffect 提供光泽/折射/边缘高光，
// 替换旧的 material+描边模拟（用户反馈不是真液态玻璃）

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            // 原生液态玻璃（iOS 26+，部署目标已 26）
            .glassEffect()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // 液态玻璃自带边缘光泽，仅保留极轻描边增强边界
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 14, y: 5)
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
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            // v3.4.21：分组容器 0.8pt 浅描边（追平门锁卡/PinCard/SessionRow 全站卡片规范）
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.14 : 0.08), lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            ? Color.accentColor.opacity(0.14)
            : (scheme == .dark ? Color(uiColor: .systemGray5) : Color(uiColor: .systemGray6))
    }
}

// MARK: - 看板卡片统一样式（DeviceCard / MeterCard / ServiceCard 共用）
// 背景 + 0.8pt 描边 + 圆角裁剪，一处定义三处复用

struct DashboardCardStyle: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
    func glassListCard() -> some View {
        modifier(GlassListCard())
    }
    func dashboardCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(DashboardCardStyle(cornerRadius: cornerRadius))
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

    /// 显式 init：避免复杂调用处 memberwise init 推断导致类型检查超时
    init(title: String, subtitle: String? = nil, trailing: AnyView? = nil,
         showStatus: Bool = false, statusColor: Color = .green) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.showStatus = showStatus
        self.statusColor = statusColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                if let trailing { trailing }
            }
            if let subtitle {
                HStack(spacing: 5) {
                    if showStatus {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 8)
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

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // v2.0.87bl：GeometryReader 取容器尺寸 + 顶部补偿状态栏；只 ignoresSafeArea(.top)
            //（底部 dock 的 safe area 保持不动 → 根治 dock 偏位）
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height + geo.safeAreaInsets.top
                // v2.0.87bm：呼吸效果（透明度 sin 周期变化）；v2.0.90a：频率/幅度/亮度可调
                let breathe = (0.30 + glowAmp * (sin(t * glowFreq) + 1) / 2) * glowBrightness
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
        .ignoresSafeArea(edges: .top)
    }
}

// MARK: - v3.0.36 灵动岛发光（AI 回答时灵动岛外一圈 Siri 同款光晕）

/// 围绕灵动岛（顶部居中胶囊）的呼吸光晕；复用 Siri 发光 4 参数（外观统一）。
/// 与 SiriGlowOverlay 同条件触发（streaming）且可独立开关（qingliao_island_glow）。
struct IslandGlowOverlay: View {
    @AppStorage("qingliao_siri_glow_brightness") private var glowBrightness = 1.0
    @AppStorage("qingliao_siri_glow_freq") private var glowFreq = 2.2
    @AppStorage("qingliao_siri_glow_amp") private var glowAmp = 0.18

    // 灵动岛胶囊近似尺寸（iPhone 14 Pro 系列 ~126×37，15 Pro 系列 ~121×37；取通用值光晕略大更醒目）
    private let islandW: CGFloat = 132
    private let islandH: CGFloat = 40

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 呼吸（与 Siri 发光同公式，参数联动）；灵动岛版底值 0.30→0.46：整体更亮（0.46~0.64）
            let breathe = (0.46 + glowAmp * (sin(t * glowFreq) + 1) / 2) * glowBrightness
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
        .ignoresSafeArea(edges: .top)
    }
}
