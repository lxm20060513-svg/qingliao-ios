import SwiftUI

// MARK: - v4.0.66 环境渐变主题（A+C 定稿：多彩轻盈 · 灵动跟手）
//
// 来源：用户从三方向对比稿中拍板「A+C 组合」——
//   · C 的「环境渐变页底」：白/黑页底上三团 radial 弥散光晕（桃粉右上 / 天蓝左侧 / 薄荷底部），
//     全站每页一个 modifier 铺底，浅深色各一套取值（色值逐字取自定稿稿 ql_uimock/gen_ac.py 的
//     light.page / dark.page，勿手调）；
//   · A 的「淡彩渐变卡」：AI 气泡/生活卡换淡彩渐变底 + 紫调柔影 —— **v4.0.81 方案3 起整块退役**，
//     改「玻璃厚边」（见下方 cardGlassFill / cardEdgeGradient / cardShadow）与 LiquidGlass.GlassEdgeSurface。
//
// 设计约束：
//   · 每团光晕 opacity ≤ 0.38：压在白底上是「空气感」，正文对比度不受影响（A11y 红线）；
//   · 深色取同构的暗调版本（同位置、同形状、浓度相近），不是简单调透明度；
//   · P1 聊天页先接（ChatView 全页底），后续 P2-P5 逐页迁移；每页只铺一层，不叠团。

enum EnvironmentGradient {

    // MARK: - v4.0.81 方案3「玻璃厚边」（用户 2026-10-09 从四列对比稿拍板）
    //
    // 口径：**彩收进页底**（页底带色 + 三团光晕降浓），**卡面全站转玻璃**——
    //   · 底 = `ultraThinMaterial` + 半透明叠层（浅 白 0.55 / 深 30,30,40 0.62）；
    //   · 边 = 1pt 渐变厚边（左上高光 → 右下渐隐）+ 顶部内高光（inset 0 1px 0）；
    //   · 影 = 加重的柔影（深色重做：层次靠影 + 描边，不再靠底色差）。
    // 色值**逐字取自对比稿** `ql_uimock/gen_beautify.py` 的 light.cols[3] / dark.cols[3]（勿手调）；
    // 与旧口径（v4.0.66 A+C 淡彩渐变卡 `pastelCardStyle` / 紫调 `pastelShadow`）的区别：
    // 那套是「渐变实底 + 0.8pt 灰描边 + 轻影」，已整块退役（护栏钉「不得再出现」）。

    /// 卡玻璃底的**半透明叠层**（材质层由调用点铺 `.ultraThinMaterial`，两者合起来才是稿上的卡面）
    static func cardGlassFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 30 / 255, green: 30 / 255, blue: 40 / 255).opacity(0.62)
            : Color.white.opacity(0.55)
    }

    /// 1pt **渐变厚边**（稿 gradbd：135° 左上高光 → 右下渐隐）——方案3 的视觉主角，
    /// 有了它卡才有「厚度」；浅色下缘收到黑 0.06 收边界，深色下缘几乎全透（靠影撑）。
    static func cardEdgeGradient(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.02)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color.white.opacity(0.95), Color.black.opacity(0.06)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 顶部**内高光**（稿 inset 0 1px 0）：只亮上缘，纵向 22% 处归零 —— 玻璃「光从上打下来」的暗示。
    static func cardTopHighlight(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.10 : 0.60), .clear],
                       startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.22))
    }

    /// 玻璃卡柔影（稿 cardshadow 0 8px 22px）：浅 黑 0.10 / 深 黑 0.60（深色提亮页底后必须加重影才浮得起来）。
    static func cardShadow(scheme: ColorScheme) -> (color: Color, radius: CGFloat, y: CGFloat) {
        scheme == .dark
            ? (Color.black.opacity(0.60), 22, 8)
            : (Color.black.opacity(0.10), 22, 8)
    }

    /// 页底兜底色（稿 page）：浅 #FAFAFC（微偏冷中性，不是纯白）/ 深 #12121A（提亮带色，不是纯黑）。
    static func pageBase(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x1A / 255)
            : Color(red: 0xFA / 255, green: 0xFA / 255, blue: 0xFC / 255)
    }

    /// 主交互色对（发送键 / 添加胶囊等「实底小圆钮」用）：与用户气泡同一套蓝→紫，
    /// 拆成 [Color] 是因为发送键的渐变动画按色数组插值（sendColors 三态切换）。
    static func userBubbleColors(_ scheme: ColorScheme) -> [Color] {
        scheme == .dark
            ? [Color(red: 0x3B / 255, green: 0x82 / 255, blue: 0xE0 / 255),
               Color(red: 0x6A / 255, green: 0x4F / 255, blue: 0xD8 / 255)]
            : [Color(red: 0x4D / 255, green: 0xA3 / 255, blue: 0xFF / 255),
               Color(red: 0x7A / 255, green: 0x5C / 255, blue: 0xFF / 255)]
    }

    /// 用户气泡渐变（A 方案：蓝→紫，稿 aUser 逐字）
    static func userBubbleGradient(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(colors: userBubbleColors(scheme),
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

}

// MARK: - 页底三团弥散光晕（radial 光斑层，纯视觉层零布局影响）

/// 页底环境渐变入口：`EnvironmentGradient.pageBackground(scheme)` 挂在页面最底层
/// （`.background(EnvironmentGradient.pageBackground(scheme))`，ignoresSafeArea 随页面既有口径）。
struct EnvironmentGlowLayers: View {
    let scheme: ColorScheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // v4.0.71：**页底过扫描**。页底此前与屏幕严格同大，于是被任何「整页缩放/位移」的过渡
            //   掀开边角——切页入场正是 scale 0.96 + 下移 10pt（DockTabView 的切页入场），
            //   动画期间四周那几 pt 露出窗口白底，看起来像「先白底再填渐变」
            //   （用户 2026-10-07 真机反馈「其他界面切换以后顶部才会填充渐变色，先白底再填渐变」）。
            //   作画区每边放大 `overscan`，**但光团几何仍按屏幕坐标 w/h 计算**并整体平移 (ox, oy)
            //   —— 与定稿稿逐像素一致，多出来的余量只用来给过渡吃。
            //   ⚠️ 光团中心那对 `+ (ox, oy)` 与画布的「重新居中」（下面 `.offset(-ox,-oy)`）是**一对**：
            //     少任何一半，三团都会整体偏移 ≈2×overscan（≈16% 屏宽，右上桃粉直接出屏）。
            //     v4.0.71 首版就是漏了居中那一半，被发版前审查抓到。
            //   余量下限：0.96 缩放（竖向各 2%×屏高 ≈ 17pt）+ 10pt 下移 ≈ 27pt；8% ≈ 68pt，留足。
            let overscan: CGFloat = 0.08
            let W = w * (1 + overscan * 2)
            let H = h * (1 + overscan * 2)
            let ox = (W - w) / 2
            let oy = (H - h) / 2
            ZStack {
                // 底色：浅 #FAFAFC / 深 #12121A（v4.0.81 方案3 稿 page 兜底色，走单一真源）
                EnvironmentGradient.pageBase(scheme)

                // 团 1：桃粉 · 右上（v4.0.81 方案3 降浓：稿 light 团1 rgba(255,180,214,.26)
                //                    dark 团1 rgba(150,60,110,.22)；旧值 .38/.35）
                GlowBlob(tint: scheme == .dark
                             ? Color(red: 150 / 255, green: 60 / 255, blue: 110 / 255)
                             : Color(red: 1, green: 180 / 255, blue: 214 / 255),
                         opacity: scheme == .dark ? 0.22 : 0.26,
                         center: CGPoint(x: w * 0.85 + ox, y: h * -0.05 + oy),
                         radius: CGSize(width: w * 0.60, height: h * 0.30))

                // 团 2：天蓝 · 左侧（v4.0.81 方案3 降浓：稿 rgba(150,200,255,.24) / dark rgba(40,90,160,.24)；旧 .34/.35）
                GlowBlob(tint: scheme == .dark
                             ? Color(red: 40 / 255, green: 90 / 255, blue: 160 / 255)
                             : Color(red: 150 / 255, green: 200 / 255, blue: 255 / 255),
                         opacity: scheme == .dark ? 0.24 : 0.24,
                         center: CGPoint(x: w * -0.10 + ox, y: h * 0.30 + oy),
                         radius: CGSize(width: w * 0.55, height: h * 0.275))

                // 团 3：薄荷 · 底部（v4.0.81 方案3 降浓：稿 rgba(190,240,200,.22) / dark rgba(40,120,70,.20)；旧 .36/.30）
                GlowBlob(tint: scheme == .dark
                             ? Color(red: 40 / 255, green: 120 / 255, blue: 70 / 255)
                             : Color(red: 190 / 255, green: 240 / 255, blue: 200 / 255),
                         opacity: scheme == .dark ? 0.20 : 0.22,
                         center: CGPoint(x: w * 0.60 + ox, y: h * 1.08 + oy),
                         radius: CGSize(width: w * 0.60, height: h * 0.275))
            }
            .frame(width: W, height: H)
            // 🚨 放大后的画布**必须重新居中到窗口**再裁：GeometryReader 把内容摆在左上角、
            //    `.frame` 又把自己的子视图居中——不抵消这两层，三团光团会整体右移/下移
            //    ≈2×overscan（≈16% 屏宽），右上那团桃粉直接跑出屏幕（v4.0.71 审查实抓）。
            //    有了它，光团中心的 `+ ox / + oy` 才真正等价于「仍按屏幕坐标」。
            .offset(x: -ox, y: -oy)
            .clipped()
        }
        // v4.0.70 修：`ignoresSafeArea` 必须挂在 **GeometryReader 本身** 上。
        // 挂在里面那个已 `.frame(w,h)` 钉死的子视图上等于没挂：尺寸/裁剪都按安全区矩形算，
        // 于是状态栏 59pt 与底部 home indicator 34pt 露白（用户 2026-10-07 真机反馈
        // 「聊天首页右上角没有被渐变底色填充」——右上角正是桃粉团的落点，露白最扎眼）。
        // 挂到 GeometryReader 上后 geo.size = 整屏，光团百分比也回到定稿稿的「全页」基准。
        .ignoresSafeArea()
    }
}

/// 单团弥散光晕：径向渐变椭圆，中心浓度 → 边缘透明（对应 CSS radial-gradient 的 0%→60% 衰减）。
/// 纯视觉层：不参与布局、不接收点击。
private struct GlowBlob: View {
    let tint: Color        // 基色（深浅色由调用点选好传入）
    let opacity: Double
    let center: CGPoint    // 椭圆中心（宿主坐标，可越界形成「从页外打光」）
    let radius: CGSize     // 椭圆半轴

    var body: some View {
        Ellipse()
            // EllipticalGradient 的半径走单位空间（0.5=椭圆边缘），正好铺满形状边界后归零
            .fill(EllipticalGradient(colors: [tint.opacity(opacity), tint.opacity(0)],
                                     center: .center))
            .frame(width: radius.width * 2, height: radius.height * 2)
            .position(center)
            .allowsHitTesting(false)
    }
}
