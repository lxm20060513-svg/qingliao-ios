// v4.0.x 自定义下拉刷新（用户 2026-10-14 定案）：
//   形态 = **液体填充杯子** —— 下拉时液面随距离上升；达阈值松手 → 满杯「晃一下」→ 弹性回位。
//   为什么自绘：系统 `.refreshable` 的转圈指示器**不可定制**，要换动画只能自接滚动几何自己画。
//
// 口径（写死在这，改之前先读）：
//   ① **只挂滚动容器本体**（ScrollView / List）——挂到内层 VStack 上拿不到滚动几何，
//      下拉会毫无反应且编译不报（静默失效，本仓老坑）。
//   ② 与 `.refreshable` **互斥**：同一容器两个都挂 = 双触发 + 系统转圈与杯子同屏。替换时删旧的那个。
//   ③ 达阈值给一次 `Haptics.medium()`（用户口径「震动要明显」）；刷新/回位期间**不响应**新的下拉（防重入）。
//   ④ 位移与回位一律走 `Motion` 令牌，不写字面 duration；杯子尺寸/线宽随 `size` 参数走，不散落魔数。
//   ⑤ **松手判定走几何回弹、不用 `onScrollPhaseChange`**：后者全仓无先例（List 上是否发布相位无从静态确认），
//      而聊天页底部上拉拉取（`InboxPullRefresh`）用「曾拉满 armed → 明显回弹」这套纯几何口径已跑通多版
//      → 与之统一，少一个未验证 API 的编译/失效风险。
//   ⑥ **投影必须自带夹紧**：`onScrollGeometryChange` 只在**投影值变化**时回调；投影取裸 offset 的话，
//      正常向下翻列表全程 60fps 回调、每帧写 @State → 整页 body 每帧失效掉帧
//      （仓内 ChatView v3.9.48 / SessionsView v4.0.86 都栽过这一处）。夹 0 后正常滚动期投影恒为 0，一次回调都不发。
//   ⑦ **指示器落点要算顶部 inset**：overlay 对齐的是滚动容器顶边，不加 inset 杯子会整段落进页头/状态栏背后。
//
// 用法：把 `.refreshable { await load() }` 换成 `.pullRefreshCup { await load() }`

import SwiftUI

/// 下拉刷新的四态机：idle（未拉）→ pulling（跟手）→ refreshing（在执行）→ finishing（回位）
enum PullRefreshPhase: Equatable { case idle, pulling, refreshing, finishing }

struct PullRefreshCupModifier: ViewModifier {
    /// 杯子色（默认跟随品牌色）
    var tint: Color = .accentColor
    /// 刷新动作（原 `.refreshable` 闭包原样搬过来）
    var action: @MainActor () async -> Void

    /// 触发阈值（pt）：太小会误触，太大在短列表上根本拉不满
    private let trigger: CGFloat = 76
    /// 杯子高度
    private let size: CGFloat = 26
    /// 回位曲线跑完的等待：必须 ≥ `Motion.settle` 时长，否则曲线后段（含弹回过冲）会被撤层，看着「闪一下不见」
    private let settleWait: UInt64 = 450_000_000
    /// 刷新动作的兜底超时：action 若挂死（接口不返回 / 蜂窝下 CFStream 静默挂），
    /// 到点强制把杯子收回去 —— 「一定会自己消失」的最后一道防线（见 `resetToIdle`）。
    private let actionTimeout: UInt64 = 20_000_000_000

    @State private var pull: CGFloat = 0
    /// 滚动容器顶部 inset（指示器落点要算上它，见头注 ⑦）
    @State private var topInset: CGFloat = 0
    @State private var phase: PullRefreshPhase = .idle
    /// 本次下拉是否已达过阈值（达阈给一次触觉；也是松手判定的前置条件）
    @State private var armed = false
    /// 满杯摇晃动画的触发计数（keyframeAnimator 的 trigger）
    @State private var sloshTick = 0
    /// 刷新任务句柄：页面销毁时取消，避免卸载后仍在跑网络与写状态
    @State private var refreshTask: Task<Void, Never>?

    private var progress: CGFloat { min(1, max(0, pull / trigger)) }
    /// 刷新中/回位中液面恒满
    private var liquid: CGFloat { (phase == .refreshing || phase == .finishing) ? 1 : progress }
    /// 前 10pt 渐显（不给的话杯子在首次下拉时整块「啪」地出现）
    private var fade: Double { min(1, Double(pull) / 10) }
    /// 杯子整体上移量（pt）—— **微调只动这一个常量**。
    /// v4.0.114：用户「下拉刷新杯子位置靠上一点」→ 8。
    /// 本轮（2026-10-16 用户截图红圈标注「把刷新的水杯放到我红圈标注的位置」）：8 → 44。
    ///   实测自用户截图（1179×2556 @3x）：红圈圆心绝对 y = **131.5pt**，圈住的是**页头栏下沿与首卡上沿之间那条空白带**
    ///   （页头栏底 ≈115–123pt，备忘录卡上沿 151pt）。按 `travel` 算式，
    ///   杯子字形中心 = 内容可见顶(T+I) + 45.8 − nudge ⇒ nudge = 44 时停在 ≈131pt；
    ///   原值 8 ⇒ ≈161pt，正好压在首卡第一行标题上（用户要挪走的就是这个）。
    ///   ⚠️ 真机若还差一两毫米：**只改这一个数**，别动 travel 的其它项（inset 项去掉杯子会钻到页头背后）。
    private let cupTopNudge: CGFloat = 44
    /// 指示器下移量：乘 0.55 让它比手指慢半拍，松手时才有「送出去」的手感
    private var travel: CGFloat { topInset + min(pull, trigger) * 0.55 - cupTopNudge }

    func body(content: Content) -> some View {
        content
            // 下拉距离：offset 为负，加回顶部 inset 才是手指拉出的真实距离；**夹紧 + 取整写在投影里**（见头注 ⑥）
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                max(0, -(geo.contentOffset.y + geo.contentInsets.top)).rounded()
            } action: { _, d in
                guard phase == .idle || phase == .pulling else { return }   // 刷新/回位期间不吃新下拉
                pull = d
                phase = d > 0 ? .pulling : .idle
                if d >= trigger {
                    if !armed { armed = true; Haptics.medium() }             // 达阈提示：可以松手了（只震一次）
                } else if armed, d < trigger * 0.5 {
                    beginRefresh()                                           // 曾拉满 + 回弹过半 = 已松手（见头注 ⑤）
                }
                if d == 0 { armed = false }                                  // 完全归位才复位（中途清会被回弹路径误清）
            }
            // 顶部 inset 单独投影：只在 inset 变化时回调，不参与每帧
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentInsets.top
            } action: { _, top in
                topInset = top
            }
            .overlay(alignment: .top) {
                if phase != .idle || pull > 0 {
                    CupPullIndicator(progress: liquid, tint: tint, size: size, sloshTick: sloshTick)
                        .offset(y: travel)
                        .opacity(fade)
                        .allowsHitTesting(false)
                }
            }
            // ⚠️ 消失时必须**连状态一起复位**：原来是只 cancel、不动 phase ——
            //    在刷新/回位途中切走 Tab 后，`phase` 永远停在 .refreshing/.finishing
            //    ⇒ overlay 条件 `phase != .idle` 恒真 = 满杯挂在那页**再也不消失**，
            //    且该页此后下拉全被第一道 guard 挡死（下拉刷新永久失效）。
            .onDisappear {
                refreshTask?.cancel()
                refreshTask = nil
                resetToIdle()
            }
    }

    /// 唯一的复位出口（idle + 液面归零 + 解除 armed）——
    /// **所有退出路径都必须走它**：正常刷完 / 刷新途中被取消 / 兜底超时。
    /// 漏走任何一条 = 杯子停在那页再也不消失（用户 2026-10-14 报的那条）。
    private func resetToIdle() {
        phase = .idle
        pull = 0
        armed = false
    }

    private func beginRefresh() {
        phase = .refreshing
        withAnimation(Motion.enter) { pull = trigger }        // 液面推到满
        sloshTick &+= 1                                       // 满杯晃一下
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            // 兜底看门狗：与刷新动作并行跑；action 挂死时到点强制复位（正常刷完时 phase 已变，它什么都不做）
            let watchdog = Task { @MainActor in
                try? await Task.sleep(nanoseconds: actionTimeout)
                guard !Task.isCancelled else { return }
                if phase == .refreshing { resetToIdle() }
            }
            await action()
            watchdog.cancel()
            guard !Task.isCancelled else { resetToIdle(); return }
            guard phase == .refreshing else { return }        // 已被看门狗兜底复位 → 不再演回位动画
            phase = .finishing
            withAnimation(Motion.settle) { pull = 0 }         // 弹性回位
            try? await Task.sleep(nanoseconds: settleWait)    // 等回位跑完再复位态
            resetToIdle()
        }
    }
}

extension View {
    /// 液体杯子下拉刷新（替换 `.refreshable`；只能挂 ScrollView / List 本体）
    func pullRefreshCup(tint: Color = .accentColor, action: @escaping @MainActor () async -> Void) -> some View {
        modifier(PullRefreshCupModifier(tint: tint, action: action))
    }
}

// MARK: - 指示器（杯子 + 液面 + 摇晃）

private struct CupPullIndicator: View {
    let progress: CGFloat
    let tint: Color
    let size: CGFloat
    let sloshTick: Int

    var body: some View {
        // 造型口径（v4.0.x 用户 2026-10-14 从候选稿里挑的 B「实心马克杯」）：
        //   杯身一层 0.07 极淡底纹（让杯子有「体」而不是只有线）＋ 描边 0.32 加重、线宽 1.4 略收，
        //   液面单层渐变 0.35→0.62（比原来 0.12→0.22 浓得多，小尺寸下才看得出「有液体」），
        //   把手加粗到 2.4、半径 0.26、开口 ±85°。数值刻意写成字面量：Tint 是**全库共用令牌**，
        //   改令牌会波及卡片/分组等所有调用点。
        CupShape()
            .fill(Color.secondary.opacity(0.07))                            // B：杯身极淡底纹
            .overlay {
                CupShape().stroke(Color.secondary.opacity(0.32), lineWidth: 1.4)   // B：描边加重
            }
            .overlay(alignment: .bottom) {
                // 液面：底部对齐的高度条，被杯身形状裁掉溢出的部分
                LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.62)],
                               startPoint: .bottom, endPoint: .top)         // B：液体更浓
                    .frame(height: size * progress)
                    .clipShape(CupShape().inset(by: 1.2))                    // 略缩，别盖住轮廓线
            }
            .overlay { CupHandle().stroke(Color.secondary.opacity(0.32), lineWidth: 2.4) }   // B：把手更粗更实
            .frame(width: size * 0.86, height: size)
            .keyframeAnimator(initialValue: 0.0, trigger: sloshTick) { view, deg in
                view.rotationEffect(.degrees(deg))
            } keyframes: { _ in
                // 满杯「晃一下」：快出快收的三段摆，幅度递减
                // （keyframeAnimator 只用于这种**一次性**动画；常驻/循环动画别用它 —— 降频/后台会凝帧）
                KeyframeTrack(\.self) {
                    CubicKeyframe(-9, duration: 0.10)
                    CubicKeyframe(7, duration: 0.13)
                    CubicKeyframe(-3.5, duration: 0.11)
                    SpringKeyframe(0, duration: 0.22, spring: .bouncy)
                }
            }
            .padding(.top, Spacing.xs)
            .frame(height: 44)
    }
}

/// 杯身：上宽下窄、圆底（开口朝上）
private struct CupShape: InsettableShape {
    var inset: CGFloat = 0
    func inset(by amount: CGFloat) -> CupShape { CupShape(inset: inset + amount) }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let topInset = r.width * 0.08                       // B：顶部略宽（原 0.04）
        let bottomInset = r.width * 0.18                    // B：底部收窄（原 0.26，收得少些更像马克杯）
        let radius = r.width * 0.30                         // B：底部圆角（原 0.22）
        let tl = CGPoint(x: r.minX + topInset, y: r.minY)
        let tr = CGPoint(x: r.maxX - topInset, y: r.minY)
        let bl = CGPoint(x: r.minX + bottomInset, y: r.maxY - radius)
        let br = CGPoint(x: r.maxX - bottomInset, y: r.maxY - radius)

        var p = Path()
        p.move(to: tl)
        p.addLine(to: CGPoint(x: bl.x, y: bl.y))
        // 底部：左圆角 → 平底 → 右圆角
        p.addQuadCurve(to: CGPoint(x: bl.x + radius, y: bl.y + radius),
                       control: CGPoint(x: bl.x, y: bl.y + radius))
        p.addLine(to: CGPoint(x: br.x - radius, y: br.y + radius))
        p.addQuadCurve(to: CGPoint(x: br.x, y: br.y),
                       control: CGPoint(x: br.x, y: br.y + radius))
        p.addLine(to: tr)
        return p
    }
}

/// 杯把：右侧开口圆环
private struct CupHandle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cx = rect.maxX - rect.width * 0.10              // B：把手右移（原 0.13）
        let cy = rect.midY + rect.height * 0.02             // B：略上提（原 0.04）
        let r = rect.width * 0.26                           // B：更大（原 0.20）
        p.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                 startAngle: .degrees(-85), endAngle: .degrees(85), clockwise: false)   // B：开口更宽（原 ±72）
        return p
    }
}
