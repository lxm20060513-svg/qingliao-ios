import SwiftUI

// MARK: - 启动动画（v4.0.117：Logo 呼吸一拍 → 以 Logo 为圆心圆形遮罩扩散铺满 → 首页各块次第上浮）
//
// 用户 2026-10-15：「轻聊 App 的启动页，Logo 放大变成进首页的门，像拉开幕布：打开时背景中间是圆形 Logo，
//   先轻轻呼吸缩放一次（约 600ms）；然后以 Logo 为圆心做圆形遮罩从中间放大到铺满屏幕（约 700ms，先慢后快），
//   首页从圆里露出来；首页内容从下往上次浮上来（每块间隔约 60ms，带淡入）；全程不出现白屏、不硬切」。
// 同轮拍板（用户回「1b 2b 3b 4b」）：② 2b 分拍式（圆先铺满，圆满之后再浮起）· ③ 3b 启动页**只留 Logo**
//   （删掉「Qimo（轻聊）/ AI AGENT」两行文字，Logo 落回屏幕正中）· ④ 4b 呼吸幅度 **+3%** · ① 1b 细粒度
//   （hero 内部也拆块，落点见 SessionsView 的 launchRiseBlock）。
// 补充（用户 2026-10-16 回「2」）：Logo 下方加回**一行**品牌字标「Qimo Agent」（版式 a：整组上下居中）。
//   ⚠️ 加回的只是这一行**新**字标 —— 3b 删掉的那两行（「Qimo（轻聊）」「AI AGENT」）仍不许回来，护栏同钉。
//
// 三拍怎么落：
//   ① 呼吸：Logo 自身 scale 1 → 1.03 → 1（0.3 张 + 0.3 收，两段 withAnimation 串联）。
//      ⚠️ 不用 keyframeAnimator —— 本仓既踩过它在降频/后台凝帧，两段串联最稳。
//   ② 扩散：本层用 `RevealHoleShape` 把**自己挖空**（圆内透明、圆外不透明），半径 0 → pageRevealMaxRadius。
//      首页在本层之下**一直渲染着**，圆扫到哪就露出哪 —— 不是「先白屏再加载」，也不会硬切。
//      曲线是 `Motion.launchReveal`（.easeIn 0.7）= 用户要的「先慢后快」；
//      ⚠️ 别拿 Motion.pageReveal 顶替：那枚 `.smooth` 是首尾对称的，语义是 dock 切页 / 滑动返回的匀速扫过。
//   ③ 铺满后回调 onRevealed：宿主撤掉本层（此时整层已被挖空，撤掉零观感）+ 放行首页各块次第上浮。
//
// 圆心：取 **Logo 中心**（用户口径「以 Logo 为圆心」）。3b 删掉文字时 Logo 恰好落在屏幕正中；
//   本轮加回字标后是「Logo + 字标」整组居中，Logo 因此比屏幕正中高约 21pt ——
//   这里仍按**实测**中心走（圆心自动跟随），不用手改常量。
//   坐标口径与 DockTabView 的圆形扩散同源：window 坐标 − 本层全局原点。
struct SplashView: View {
    /// 圆形遮罩铺满时回调（宿主据此撤层 + 放行首页上浮）。减弱动态效果下**立即**回调。
    var onRevealed: (() -> Void)? = nil

    /// 呼吸一次的**半程**时长：用户口径「约 600ms」= 0.3 张 + 0.3 收。
    static let breathHalf: Double = 0.3
    /// 呼吸幅度（4b：+3%，比初稿的 +6% 更轻）
    static let breathScale: CGFloat = 1.03
    /// 遮罩扩散时长：用户口径「约 700ms」。⚠️ 与 `Motion.launchReveal` 的 0.7 **必须同值**（护栏同钉两处）。
    static let revealDuration: Double = 0.7
    /// 首页每块上浮的位移量（pt）
    static let riseOffset: CGFloat = 18
    /// 首页每块上浮的错峰（秒）：用户口径「每块间隔约 60ms」
    static let riseStagger: Double = 0.06

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Logo 呼吸缩放（1 → 1.03 → 1）
    @State private var breath: CGFloat = 1
    /// 挖洞半径：0 = 整层盖住（开场态）；pageRevealMaxRadius = 全屏露完
    @State private var revealRadius: CGFloat = 0
    /// 本层全局原点 + Logo 中心的 window 坐标（挖洞圆心换算用）
    @State private var pageOrigin: CGPoint = .zero
    @State private var logoGlobal: CGPoint = .zero
    /// 代际令牌：视图重建 / 二次 onAppear 时让在跑的延时任务自动作废（同 DockTabView 的两处入场 modifier）
    @State private var seq = 0

    /// 挖洞圆心换算到本层局部坐标（口径同 DockTabView.localCenter：
    /// shape 的 path 落在本层坐标系里，window 坐标必须减掉本层原点，否则整圆偏一个安全区）
    private var localCenter: CGPoint {
        CGPoint(x: logoGlobal.x - pageOrigin.x, y: logoGlobal.y - pageOrigin.y)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            // 环境光晕（与 Dock 同款：蓝/靛/青底部光）
            // v4.0.133：光晕层也吃满全屏 —— 否则停在底部安全区边界，Home 条上方留一条纯白带
            //（2026-10-20 用户真机「开屏动画底部没填满」，像素剖面实测分界 ≈96% 屏高 = 安全区线）。
            ZStack {
                Circle().fill(Color.blue.opacity(Tint.soft)).frame(width: 300, height: 300).blur(radius: 70)
                    .offset(y: 260)
                Circle().fill(Color.indigo.opacity(Tint.faint)).frame(width: 240, height: 240).blur(radius: 60)
                    .offset(x: 150, y: 220)
                Circle().fill(Color.cyan.opacity(Tint.faint)).frame(width: 220, height: 220).blur(radius: 55)
                    .offset(x: -150, y: 230)
            }
            .ignoresSafeArea()

            // 用户 2026-10-16 回「2」：Logo 下方加回**一行**品牌字标「Qimo Agent」。
            // 口径 = ② 品牌字标（Typography.headline = 20pt / semibold / 主色 / 字距 2）+ 版式 a（整组上下居中），
            // 与 Logo 间距 14pt。于是 Logo 比屏幕正中高约 21pt，挖洞圆心自动跟随（下面仍是**实测** Logo 中心）。
            // ⚠️ 3b 删掉的「Qimo（轻聊）」标题与「AI AGENT」副标题**不许回来**（ql_launch 表同钉）。
            // v4.0.x 起 logo 用正式图标资产（卡片叠层立体 Q，与 AppIcon 同款），这一处不变。
            VStack(spacing: 14) {
                Image("AboutLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .shadow(color: Color.blue.opacity(0.35), radius: 18, y: 6)
                    .scaleEffect(breath)
                    // 实测 Logo 中心（window 坐标）：挖洞圆心与它严格同点
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { logoGlobal = SplashView.center(of: proxy.frame(in: .global)) }
                                .onChange(of: proxy.frame(in: .global)) { _, new in
                                    logoGlobal = SplashView.center(of: new)
                                }
                        }
                    )

                // 品牌字标（整组居中的下半截）：**不参与呼吸** —— 用户口径是「Logo 呼吸缩放」
                Text("Qimo Agent")
                    .font(.system(size: Typography.headline, weight: .semibold))
                    .foregroundStyle(.primary)
                    .tracking(2)
            }
        }
        // 实测本层全局原点（供圆心换算，口径同 DockTabView 的 pageOrigin）
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { pageOrigin = proxy.frame(in: .global).origin }
                    .onChange(of: proxy.frame(in: .global).origin) { _, new in pageOrigin = new }
            }
        )
        // 挖洞遮罩：圆内透出**底下已经渲染好的首页**，圆外仍是本层（未铺满时整屏就是启动页）。
        // radius = 0 时整层盖住 → 开场不会有半帧白屏。
        .mask(
            RevealHoleShape(center: localCenter, radius: revealRadius)
                .fill(style: FillStyle(eoFill: true))
        )
        .onAppear { start() }
    }

    private static func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private func start() {
        seq &+= 1
        let mySeq = seq

        // 减弱动态效果：三拍全部落终态（不呼吸、不扩散、立刻放行首页）
        if reduceMotion {
            revealRadius = Motion.pageRevealMaxRadius
            onRevealed?()
            return
        }

        // ① 呼吸：0.3 张
        withAnimation(.easeInOut(duration: SplashView.breathHalf)) { breath = SplashView.breathScale }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(SplashView.breathHalf))
            guard mySeq == seq else { return }
            // ① 呼吸：0.3 收
            withAnimation(.easeInOut(duration: SplashView.breathHalf)) { breath = 1 }

            // ② 呼吸收回那一拍 = 扩散起点（用户口径「先呼吸一次，然后扩散」）
            try? await Task.sleep(for: .seconds(SplashView.breathHalf))
            guard mySeq == seq else { return }
            withAnimation(Motion.launchReveal) { revealRadius = Motion.pageRevealMaxRadius }

            // ③ 铺满后放行（2b 分拍式：宿主收到才让首页各块起浮）
            try? await Task.sleep(for: .seconds(SplashView.revealDuration))
            guard mySeq == seq else { return }
            onRevealed?()
        }
    }
}

// MARK: - 挖洞遮罩形状

/// v4.0.117：启动页「挖洞」遮罩 —— 整屏不透明、**圆内挖空**（配合 `FillStyle(eoFill: true)`）。
/// 于是底下已经渲染好的首页从圆里透出来：既能「从中间放大到铺满」，又不用把首页重新加载一遍，
/// 也就不会出现白屏 / 硬切。半径是唯一可动画量（圆心固定 = Logo 中心）。
///
/// ⚠️ 与 DockTabView 的 `RevealCircleShape` 是一对**反义**形状，别互相顶替：
///     · `RevealCircleShape`（切页 / 滑动返回）**留圆** —— 新页从圆里长出来，圆外是垫底渐变；
///     · `RevealHoleShape`（启动页）**挖圆** —— 旧层从圆里退开，圆外仍是启动页。
struct RevealHoleShape: Shape {
    var center: CGPoint
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        guard radius > 0 else { return path }
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))
        return path
    }
}

// MARK: - 首页各块「次第上浮」

/// v4.0.117：首页各块的入场 —— 从下方 18pt 浮上来 + 淡入，每块比前一块晚 60ms
/// （用户口径「首页内容从下往上次浮上来，每块间隔约 60ms，带淡入」）。
///
/// `shown` 由宿主在**启动页圆形遮罩铺满之后**才置 true —— 「2b 分拍式」的落点就在这一根线上。
/// 非启动路径（切 tab / 从对话页返回 / iPad 双栏）宿主直接传 true，本修饰器等于不生效（初值即终态）。
///
/// ⚠️ 只作用于**块**（首页头 / 搜索框 / 宠物 / 每日一言 / 卡片行 / 会话列表），
///    不许挂到整页 —— 整页级的入场一直是圆形扩散（回退⑯ 的禁令：整页缩放 / 上浮 / 低起点淡入不许回来）。
struct LaunchRiseBlock: ViewModifier {
    /// 第几块（从 0 起），错峰 = index × riseStagger
    let index: Int
    /// 是否已就位（false = 停在下方且全透明）
    let shown: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let settled = shown || reduceMotion
        return content
            .offset(y: settled ? 0 : SplashView.riseOffset)
            .opacity(settled ? 1 : 0)
            .animation(reduceMotion ? nil : Motion.launchRise.delay(Double(index) * SplashView.riseStagger),
                       value: shown)
    }
}

extension View {
    /// 首页第 `index` 块的次第上浮（index 从 0 起，每块错峰 60ms）。详见 `LaunchRiseBlock`。
    func launchRiseBlock(_ index: Int, shown: Bool) -> some View {
        modifier(LaunchRiseBlock(index: index, shown: shown))
    }
}
