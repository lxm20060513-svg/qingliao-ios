// MARK: - 全屏爆发特效 + 智能球（从 ChatComponents.swift 拆出）
import SwiftUI
import UIKit

// MARK: - v2.0.132 全屏爆发特效（点击智能球：满屏粒子散开）

/// 点击智能球展开输入框时的全屏级爆发：粒子从球心（底部中央）向全屏飞散。
/// 触发方在 ~0.95s 后移除本层。
/// v2.0.135 性能修复：扩散波纹从 Canvas 逐帧 stroke（每帧 3 个全屏大椭圆）改为
/// Core Animation 隐式动画（GPU 合成）——但 60fps 下 3 层全屏大圆持续放大插值仍卡顿，
/// v2.0.138 决定直接移除波纹层（修不好宁可整体移除，用户确认），只保留粒子特效。
struct FullScreenBurst: View {
    /// v3.9.19：无障碍——「降低动态效果」时跳过全屏粒子爆发（一次性特效，功能无损）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spawn = Date()
    /// v3.6.2：粒子发射原点距屏幕底部距离——原写死 136 = 聊天页输入栏智能球位置；
    /// 智能球迁到 dock 槽位后由 DockOrbOverlay 的几何定位给出（见 body 内 geoCenterY）
    var originFromBottom: CGFloat = 136

    var body: some View {
        // 锁 60fps（v2.0.133d：ProMotion 120Hz 下每帧全屏 Canvas 重绘开销大，60fps 肉眼已顺滑）
        // v2.0.134 修复 CI：TimelineView content 只返回简单类型 BurstCanvas——原内联 Canvas 多语句闭包
        // 类型错误会让编译器报外层 generic parameter 'Content' could not be inferred（check_swift.sh 查不出）
        GeometryReader { geo in
            // 粒子层：160 颗飞散粒子（v2.0.138：波纹层已移除，仅粒子）
            let schedule: AnimationTimelineSchedule = .animation(minimumInterval: 1.0 / 30.0)
            if reduceMotion {
                Color.clear          // 降低动态效果：不播粒子
            } else {
                TimelineView(schedule) { context in
                    BurstCanvas(date: context.date, spawn: spawn, originFromBottom: originFromBottom)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 全屏爆发粒子 Canvas 绘制层（v2.0.134 从 FullScreenBurst 提出，独立编译定位类型错误）。
/// 确定性伪随机粒子：160 颗从球心（底部中央）向全屏飞散，先快后慢爆开感 + 平滑淡出。
/// 性能：单位圆 Path 循环外建一次，循环内 translate/scale 变换复用（原每帧 320 次 Path 分配是掉帧主因）。
struct BurstCanvas: View {
    let date: Date
    let spawn: Date
    /// v3.6.2：发射原点距屏幕底部（默认 136 = 原输入栏球位置）
    var originFromBottom: CGFloat = 136

    /// 确定性伪随机（0-1），粒子参数稳定不闪烁
    private func hash(_ i: Int, _ salt: Int) -> Double {
        let v = sin(Double(i * 127 + salt * 311)) * 43758.5453
        return v - v.rounded(.down)
    }

    var body: some View {
        let t = date.timeIntervalSince(spawn)
        Canvas { ctx, size in
            let w = size.width, h = size.height
            // v2.0.135：扩散波纹移出 Canvas（改隐式动画），v2.0.138：波纹层整体移除（仍卡顿），
            // 仅保留粒子绘制——160 颗小圆，绘制面积小
            // 发射原点：底部中央（智能球位置，Dock 上方；v2.0.137 随球下沉同步 h-164；v2.0.140 球再下移同步 h-136）
            let origin = CGPoint(x: w / 2, y: h - originFromBottom)
            // 粒子群：160 颗。v2.0.133 放烟花参数：
            //    速度调慢（250-650）且减速加大（0.25→0.55）= 先快后慢的爆开感；
            //    生命周期拉长（0.7-1.2s）平滑淡出（v2.0.133c：去掉末段 sin 闪烁，用户觉得闪烁多余）
            //    v2.0.133d：单位圆 Path 复用 + translate/scale 变换绘制（原每帧 320 次
            //    Path(ellipseIn:) 对象分配是掉帧主因，现仅 1 个 Path 实例复用）
            //    v2.0.137：粒子提速（480-950）提寿命（0.9-1.45s）+ 减重力下拉（70→25），
            //    最大飞行距离 ~826pt 可冲到灵动岛/屏幕顶，不再只在下半屏；向上粒子占比 92%
            let colors: [Color] = [.blue, .indigo, .pink, .purple]
            let unitDot = Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2))
            // v2.0.139 性能：160→120 颗（-25% fill），且光晕大圆只对半数粒子绘制（-50% 光晕 fill），
            // 每帧绘制调用 320 → ~180（-44%）；视觉密度几乎无差（小粒子光晕本就淡）
            for i in 0..<120 {
                let life = 0.9 + hash(i, 1) * 0.55
                guard t < life else { continue }
                let progress = t / life
                let speed = 480 + hash(i, 2) * 470
                let upBias = hash(i, 3) < 0.92
                let angle: Double
                if upBias {
                    angle = .pi * (0.08 + hash(i, 4) * 0.84)   // 收窄朝上扇形（8%-92%），直冲顶部灵动岛
                } else {
                    angle = .pi * 2 * hash(i, 5)
                }
                let dist = speed * t * (1 - 0.55 * progress)   // 减速 0.25→0.55：爆开初速快、末端近乎悬停
                let x = origin.x + CGFloat(cos(angle)) * dist
                let y = origin.y - CGFloat(sin(angle)) * dist + 25 * CGFloat(progress * progress)
                let colorIdx = Int(hash(i, 6) * 4)
                let c = colors[colorIdx]
                let coreR = 2.0 + hash(i, 7) * 3.6
                let alpha = 0.9 * (1 - progress)   // 平滑淡出（v2.0.133c：去掉 twinkle 闪烁）
                // 注：GraphicsContext 无 saveGState/restoreGState（那是 CGContext API），保存/恢复 transform 等效
                let savedTransform = ctx.transform
                ctx.translateBy(x: x, y: y)
                // 光晕（大圆低透明）只对半数粒子绘制（hash<0.5），减半 fill 次数
                if hash(i, 8) < 0.5 {
                    ctx.scaleBy(x: CGFloat(coreR * 3.5), y: CGFloat(coreR * 3.5))
                    ctx.fill(unitDot, with: .color(c.opacity(alpha * 0.22)))
                    ctx.transform = savedTransform
                    ctx.translateBy(x: x, y: y)
                }
                // 核心（小圆高透明）：缩放 1 倍单位圆（CGFloat 显式转换——GraphicsContext 参数是 CGFloat，Double 直传会类型错误）
                ctx.scaleBy(x: CGFloat(coreR), y: CGFloat(coreR))
                ctx.fill(unitDot, with: .color(c.opacity(alpha)))
                ctx.transform = savedTransform
            }
        }
    }
}

/// 多彩光晕圆球：TimelineView 驱动 AngularGradient 呼吸（复用 Siri 发光配色：蓝紫粉红淡雅）。
/// 单击 → 展开输入框；长按 → 语音转文字（球保持特效）。
/// ⚠️ 手势用 ExclusiveGesture(LongPress, Tap) 互斥（v2.0.98 SIGTRAP 教训：勿叠加 onTap+onLongPress）。
struct SiriBallView: View {
    // v3.0.12：思考球——流式回答中 orbits(点点旋转) / 空闲 ring(缓慢脉动)
    var thinking: Bool = false
    var onTap: () -> Void = {}
    // v3.1.4+：长按语音转文字（与发送按钮长按功能一致）
    var onLongPress: () -> Void = {}
    var voiceEnabled: Bool = true
    // v3.6.2：尺寸参数化——92 = 原聊天页输入栏球外框（基准），dock 槽位传 36
    // （球体 ≈28pt，与 dock 其它图标等高）；内部所有尺寸按 k 等比缩放
    var size: CGFloat = 92
    /// 动画帧率（默认 30；dock 槽位空闲态传 15 —— 常驻视图省电，思考态仍用 30）
    var fps: Double = 30
    /// v3.9.33：第三态「刚答完未查看」——球右上亮点（让球成为唯一的状态指示器）
    var unseen: Bool = false
    /// v3.9.33：错误态——上一次请求失败时压暗（一眼看出「那一次没成」）
    var failed: Bool = false
    /// v3.9.19：无障碍——「降低动态效果」时球静止（慢速刷新代替每帧重绘，同时省电）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var k: CGFloat { size / 92 }

    /// v3.6.2：内层 orb 参数——大尺寸（原输入栏 92）用默认；小尺寸（dock 槽位 36 → canvas 23.5pt）
    /// 必须换成放大参数：点半径经 radiusScale(size, 0.6) 缩放后默认值只剩 ≈0.5pt 近乎不可见
    /// （项目内 30/38pt 头像球同样显式传大参数，见 ChatMessageBubble / ChatView 思考球）
    private var orbOpts: OrbOpts {
        guard k < 0.7 else { return OrbOpts() }
        return thinking ? Self.dockOrbitOpts : Self.dockRingOpts
    }

    /// dock 小尺寸 orbits（点点旋转）：对齐项目 30pt 头像球参数并再放宽一点
    private static let dockOrbitOpts = OrbOpts(orbitN: 10, ghostN: 34, ghostR: 1.7, ghostA: 0.85,
                                               particles: 4, partR: 2.6, partRDepth: 3.2,
                                               rsPow: 0.6, rMin: 0.9)
    /// dock 小尺寸 ring（空闲呼吸）：环点数与 ring64 一致，半径按 ≈1.8 倍放大保证可见
    private static let dockRingOpts = OrbOpts(ghostN: 150, ghostR: 1.7, ghostA: 0.5,
                                              lanes: 5, segs: 88, faceOn: 1,
                                              rBase: 2.0, rDepth: 3.2,
                                              wobMul: 0.368, bandMul: 3.627, spin: 0,
                                              rsPow: 0.6, rMin: 0.9)

    var body: some View {
        // v3.6.2：帧率可调——dock 槽位常驻显示（5 个 tab 全程可见），空闲呼吸降 15fps 省电，
        // 流式思考中保留 30fps 让 orbits 旋转顺滑（原写死 30fps）
        // v3.9.19：降低动态效果时近乎不刷新（视觉静止，同时省电）。
        // ⚠️ 必须用 AnimationTimelineSchedule 自身构造：`.periodic(from:by:)` 返回的是
        // PeriodicTimelineSchedule，与这里期望的类型不同 —— CI #502 就是栽在这一行
        let schedule = AnimationTimelineSchedule(minimumInterval: reduceMotion ? 600 : 1.0 / fps)
        TimelineView(schedule) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathe = 0.35 + 0.30 * (sin(t * 2.2) + 1) / 2
            let glowColors: [Color] = [
                .blue.opacity(0.55 * breathe), .indigo.opacity(0.5 * breathe),
                .pink.opacity(0.5 * breathe), .purple.opacity(0.42 * breathe),
                .blue.opacity(0.55 * breathe)]
            let bodyColors: [Color] = [
                .blue.opacity(0.85 * breathe), .indigo.opacity(0.8 * breathe),
                .pink.opacity(0.8 * breathe), .purple.opacity(0.72 * breathe),
                .blue.opacity(0.85 * breathe)]
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: glowColors, center: .center))
                    .blur(radius: 6 * k)
                    .frame(width: 84 * k, height: 84 * k)
                Circle()
                    .fill(AngularGradient(colors: bodyColors, center: .center))
                    .frame(width: 72 * k, height: 72 * k)
                    .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: max(0.8, 1.2 * k)))
                    .shadow(color: Color.indigo.opacity(0.45 * breathe), radius: 14 * k)
                OrbCanvasView(mode: thinking ? .orbits : .ring, size: 60 * k, opts: orbOpts, fps: fps)   // v3.9.1：透传帧率
                    .allowsHitTesting(false)
            }
            // v3.9.33：错误态压暗（去饱和 + 降不透明度）——「那一次没成」的持续可见信号
            .opacity(failed ? 0.5 : 1)
            .saturation(failed ? 0.3 : 1)
            // v3.9.33：第三态「刚答完未查看」——球右上小亮点（轻微呼吸；进聊天页即清）
            .overlay(alignment: .topTrailing) {
                if unseen {
                    OrbNoticeDot(size: size, pulse: 0.7 + 0.3 * (sin(t * 3.0) + 1) / 2)
                }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        // v3.1.4+：长按语音转文字 / 单击展开（ExclusiveGesture 互斥，防长按同时触发单击）
        .gesture(
            ExclusiveGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in if voiceEnabled { onLongPress() } },
                TapGesture().onEnded { _ in onTap() }
            )
        )
    }
}

/// v3.9.33：智能球的「刚答完未查看」亮点（第三态指示器）。
/// 独立小 struct：SiriBallView 的 TimelineView 闭包已经很长，内联塞条件视图易触发 CI 的 type-check 超时。
private struct OrbNoticeDot: View {
    /// 球外框边长（与 SiriBallView 的 size 同口径）
    let size: CGFloat
    /// 呼吸透明度（TimelineView 每帧给值——纯静态点用户容易忽略，轻闪一下才叫「有新回复」）
    let pulse: Double

    var body: some View {
        // 小尺寸球（dock 槽位 52）按比例算只有 6pt → 设 7pt 下限，保证一眼可见
        let d = Swift.max(7, size * 0.115)
        Circle()
            .fill(Color.orange)
            .frame(width: d, height: d)
            .overlay(Circle().strokeBorder(.white.opacity(0.92), lineWidth: 1.2))
            .shadow(color: Color.orange.opacity(0.55), radius: 3)
            .padding(2)
            .opacity(pulse)
    }
}


// MARK: - v3.6.2 dock 槽位智能球（系统 tab item 的自定义替身）
//
// 背景：iOS 26 原生 TabView 的 tab item 只接受系统图标 + 文字（官方未提供自定义视图 API）。
// 因此聊天槽位的 item 置为不可见（Text("")，无图标无文字），整颗球由本层自绘并居中于该槽位。
// 本层必须 .allowsHitTesting(false)：触摸要穿透给下层的系统 tab item（点球 = 系统切页，行为不变）。
struct DockOrbOverlay: View {
    /// 目标槽位序号（本地：会话0 / 看板1 / 聊天2 / 生活3 / 设置4）
    var slotIndex: Int = 2
    /// dock 槽位总数（当前 5：会话/看板/聊天/生活/设置）
    var slotCount: Int = 5
    /// v3.9.78：球体外框边长**单一真源** —— dock 常驻球与长按菜单里重画的「锚点球」必须同尺寸；
    /// 改尺寸只动这一处（菜单层引用本常量，别再各写一个 52）。
    static let defaultBallSize: CGFloat = 52
    /// 外框（含光晕）边长；球体 ≈ size × 0.783 —— 52 时球体 ≈ 41pt
    /// v3.6.3：36 → 44；v3.6.4：44 → 50；v3.6.5：50 → 52（用户指定）
    var ballSize: CGFloat = DockOrbOverlay.defaultBallSize
    /// 装机微调预留：正值下移
    var verticalNudge: CGFloat = 0
    /// AI 正在流式回答 → 球切 orbits（点点旋转）；空闲 → ring（缓慢脉动）
    var thinking: Bool = false
    /// v3.9.33：刚答完未查看 → 球右上亮点（第三态）
    var unseen: Bool = false
    /// v3.9.33：上一次请求失败 → 球压暗
    var failed: Bool = false
    /// v3.9.33：实测系统 tab bar 高度回写给宿主（烟花原点与球心同源；读不到时保持 fallbackBarHeight）
    @Binding var measuredBarHeight: CGFloat

    /// v3.6.3：系统 tab bar 真实槽位中心（window 坐标）。读得到就用它，读不到回退等分估算
    @State private var liveCenter: CGPoint?
    /// v3.6.3：回前台/转屏后 frame 会变 → 重读真实槽位
    @Environment(\.scenePhase) private var scenePhase

    /// iOS 26 原生 tab bar 高度**兜底值**（不含底部安全区）。
    /// v3.9.33：不再是唯一来源——系统「放大字体」等辅助功能会把玻璃 tab bar 顶高，写死 49 会让球
    ///          纵向跑偏；改为优先读真实 UITabBar 高度（`slotBarHeight()`），本值只在读不到时兜底。
    static let fallbackBarHeight: CGFloat = 49

    /// v3.6.5 实测：dock 内容（图标 + 文字整块）中心比 UITabBar 几何中心低约 6.3pt。
    /// 装机截图 @3x（1179×2556 = 393×852pt）像素测量：球心 793.5pt（= tab bar 几何中心）
    /// vs 槽位内容中心 799.8pt → 球比内容偏上 6.3pt，用户报「没在 dock 上下居中」。
    /// 即 iOS 26 玻璃 tab bar 的 bounds 中心高于其内容中心（内容在 tab bar 内并非垂直居中）。
    static let dockContentCenterDrop: CGFloat = 6.3

    var body: some View {
        GeometryReader { geo in
            let g = geo.frame(in: .global)          // 本叠加层在 window 中的位置
            // v3.6.5：球心 y 用「几何定位」——屏幕底(去安全区)上溯半个 tab bar 高，再按实测差值
            //        dockContentCenterDrop 下移到内容中心。**不再取 UITabBar / UITabBarButton 的
            //        bounds 中心**：装机截图实测（@3x）球心落在 tab bar 几何中心时比槽位内容中心偏上
            //        6.3pt；而按钮 bounds 是否撑满 tab bar 高度无法在本地证实（若撑满则 br.midY ==
            //        tr.midY，改基准等于没改，且读写两条路径还会差 6.3pt 造成跳变）。几何定位有
            //        截图实测锚点（852 - 34 - 24.5 + 6.3 = 799.8pt = 实测内容中心），一次到位。
            // v3.6.3 教训：原实现 cy = h - centerFromBottom 把底部安全区算了两遍 → 球高约 34pt。
            // v3.9.33：bar 高改用实测值（放大字体下会变高）；实测与兜底走**同一条公式**，
            //          两条路径坐标系一致（窗口底 − 安全区 − bar高/2 + 实测差值）→ 读不到也不会跳变
            let barH = measuredBarHeight > 1 ? measuredBarHeight : DockOrbOverlay.fallbackBarHeight
            let geoCenterY = DockOrbOverlay.keyWindowHeight - DockOrbOverlay.keyWindowSafeBottom
                             - barH / 2 + DockOrbOverlay.dockContentCenterDrop
            let fallbackX = geo.size.width * (CGFloat(slotIndex) + 0.5) / CGFloat(slotCount)
            // ⚠️ ViewBuilder 内只能用表达式：`let x: T` + if/else 赋值会被当作条件视图
            //（CI 报 "type '()' cannot conform to 'View'"）→ 用 map/?? 表达式写
            let target: CGPoint = CGPoint(x: liveCenter.map { $0.x - g.minX } ?? fallbackX,
                                          y: geoCenterY - g.minY + verticalNudge)
            // 空闲呼吸 15fps / 思考旋转 30fps —— dock 常驻视图按状态降帧
            SiriBallView(thinking: thinking, size: ballSize, fps: thinking ? 30 : 15,
                         unseen: unseen, failed: failed)
                .frame(width: ballSize, height: ballSize)
                .position(x: target.x, y: target.y)
        }
        .task { await refreshLiveCenter() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            Task { await refreshLiveCenter() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshLiveCenter() } }
        }
    }

    /// 读系统真实槽位：首帧布局未落定、转屏/后台恢复后会读到旧值，
    /// 故连读 3 次、每次覆盖，取最后一次有效值（不再「首成功即定」而锁死旧 frame）
    @MainActor
    private func refreshLiveCenter() async {
        var latest: CGPoint?
        // v3.9.33：同一轮里一并取真实 bar 高（放大字体/转屏/回前台后都会变；读不到就保持兜底值）
        var latestBarH: CGFloat = 0
        for delay in [0.15, 0.6, 1.6] {
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }        // 视图已消失 → 别再写 @State
            if let c = DockOrbOverlay.slotCenterGlobal(index: slotIndex, count: slotCount) { latest = c }
            if let h = DockOrbOverlay.slotBarHeight() { latestBarH = h }
        }
        if let latest, latest != liveCenter { liveCenter = latest }
        if latestBarH > 1, abs(latestBarH - measuredBarHeight) > 0.5 { measuredBarHeight = latestBarH }
    }

    /// 系统 tab bar 第 index 个按钮的中心（window 坐标）。读不到 / 数量对不上 → nil（调用方回退）
    @MainActor
    static func slotCenterGlobal(index: Int, count: Int) -> CGPoint? {
        guard let window = keyWindow, let tabBar = findTabBar(in: window) else { return nil }
        var found: [UIView] = []
        collectTabButtons(in: tabBar, into: &found)
        // 数量必须与槽位数一致才敢用，否则宁可回退（避免误取别的槽位）
        guard found.count == count, index >= 0, index < found.count else { return nil }
        let b = found.sorted { $0.frame.minX < $1.frame.minX }[index]
        let br = b.convert(b.bounds, to: nil)     // to: nil = window 坐标
        guard br.width > 1, br.height > 1 else { return nil }
        // v3.6.5：本函数只取 **x** 用于水平对准槽位；y 已改由 DockOrbOverlay 的几何定位给出
        //（不取按钮/tab bar 的 bounds 中心——两者中心是否相等无法在本地证实，见 body 注释）。
        return CGPoint(x: br.midX, y: br.midY)
    }

    /// v3.9.33：系统 tab bar 的**实际高度**（不含底部安全区）。放大字体下玻璃 tab bar 会变高，
    /// `fallbackBarHeight`(49) 就不再成立 → 球纵向跑偏。读不到 / 值离谱 → nil（调用方用兜底值）。
    ///
    /// 用「bar 顶边 → 内容底边」求高，而不是直接取 `bounds.height`：UITabBar 的 frame 是否把底部
    /// 安全区算进去各版本不一（算进去时 height ≈ 49 + 安全区）→ 直接取会多算一遍安全区。
    /// 收敛到内容底边（窗口底 − 安全区）后，两种形态都得到 49 这类真实内容高。
    @MainActor
    static func slotBarHeight() -> CGFloat? {
        guard let window = keyWindow, let tabBar = findTabBar(in: window) else { return nil }
        let r = tabBar.convert(tabBar.bounds, to: nil)          // to: nil = window 坐标
        let contentBottom = window.bounds.height - window.safeAreaInsets.bottom
        let effectiveBottom = Swift.min(r.maxY, contentBottom)  // bar 覆盖了安全区时按内容底收敛
        let h = effectiveBottom - r.minY
        guard h > 20, h < 120 else { return nil }               // 离谱值宁可回退（防误取别的视图）
        return h
    }

    /// 递归收集 tab 按钮：iOS 26 玻璃 tab bar 可能把按钮放进中间容器，只扫直接子视图会漏掉（改进空转）
    @MainActor
    private static func collectTabButtons(in view: UIView, into out: inout [UIView]) {
        for sub in view.subviews {
            if String(describing: type(of: sub)).contains("TabBarButton") {
                out.append(sub)
            } else if !sub.subviews.isEmpty {
                collectTabButtons(in: sub, into: &out)
            }
        }
    }

    @MainActor
    private static func findTabBar(in view: UIView) -> UITabBar? {
        if let t = view as? UITabBar { return t }
        for sub in view.subviews {
            if let f = findTabBar(in: sub) { return f }
        }
        return nil
    }

    @MainActor
    static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        return scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
    }

    /// window 高度（坐标换算用）—— 不用 UIScreen.main（iOS 26 已弃用）
    @MainActor
    static var keyWindowHeight: CGFloat {
        if let h = keyWindow?.bounds.height, h > 0 { return h }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.coordinateSpace.bounds.height ?? 0
    }

    /// 球心到**叠加层底部**的距离（DockTabView 的烟花原点用；与 BurstCanvas 的 `h - originFromBottom`
    /// 同一坐标系，h = 叠加层高）。⚠️ 叠加层底 ≠ 窗口底（差一个底部安全区）。
    /// v3.6.5：改为与球实际位置同源的几何口径 —— (屏高−安全区−tabBar高/2+6.3) 距叠加层底
    ///         = tabBar高/2 − 6.3 = 18.2pt（v3.6.4 用 tab bar 几何中心时是 24.5pt，差 6.3pt）。
    /// v3.9.33：bar 高不再是常量——宿主把实测值传进来（放大字体下 tab bar 变高，原点要跟着球动）；
    ///          默认参数 = 兜底 bar 高（读不到实测值时与原行为逐字一致）。
    /// 删除本函数会连带 DockTabView 编译失败（v3.6.5 首发 CI #468 实录）→ 改口径时务必全仓 grep。
    @MainActor
    static func ballCenterFromBottom(barHeight: CGFloat = fallbackBarHeight) -> CGFloat {
        barHeight / 2 - dockContentCenterDrop
    }

    /// 读 key window 底部安全区（不依赖叠加层自身的 safeAreaInsets——叠加层会被 tab bar 吃掉安全区）
    @MainActor
    static var keyWindowSafeBottom: CGFloat {
        keyWindow?.safeAreaInsets.bottom ?? 0
    }

    /// v3.9.59：window 宽度（等分回退估算用）——同上口径，不用已弃用的 UIScreen.main
    @MainActor
    static var keyWindowWidth: CGFloat {
        if let w = keyWindow?.bounds.width, w > 0 { return w }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.coordinateSpace.bounds.width ?? 0
    }

    /// v3.9.59：智能球的**全局球心**（window 坐标）——球命中层 / 长按菜单浮层与本层共用同一套几何，
    /// 禁止各自算一份（命中圈与可见球错位是这类浮层最隐蔽的 bug：球看着在那儿，手指按上去没反应）。
    ///
    /// 与 body 的 target 完全同源：
    ///   x → 优先真实槽位按钮中心（`slotCenterGlobal`，读不到才回退等分估算）；
    ///   y → 几何定位（窗口底 − 底部安全区 − bar高/2 + 实测 6.3pt 差值）。
    /// ⚠️ 不要把 y 改成「按钮 bounds 中心」：那条路已在 v3.6.5 装机实测里被否掉（球会偏上 6.3pt）。
    @MainActor
    static func orbCenterGlobal(slotIndex: Int = 2, slotCount: Int = 5, barHeight: CGFloat) -> CGPoint {
        let barH = barHeight > 1 ? barHeight : fallbackBarHeight
        let y = keyWindowHeight - keyWindowSafeBottom - barH / 2 + dockContentCenterDrop
        let x = slotCenterGlobal(index: slotIndex, count: slotCount)?.x
                ?? keyWindowWidth * (CGFloat(slotIndex) + 0.5) / CGFloat(slotCount)
        return CGPoint(x: x, y: y)
    }
}
