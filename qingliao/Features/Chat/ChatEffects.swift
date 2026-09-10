// MARK: - 全屏爆发特效 + 智能球（从 ChatComponents.swift 拆出）
import SwiftUI

// MARK: - v2.0.132 全屏爆发特效（点击智能球：满屏粒子散开）

/// 点击智能球展开输入框时的全屏级爆发：粒子从球心（底部中央）向全屏飞散。
/// 触发方在 ~0.95s 后移除本层。
/// v2.0.135 性能修复：扩散波纹从 Canvas 逐帧 stroke（每帧 3 个全屏大椭圆）改为
/// Core Animation 隐式动画（GPU 合成）——但 60fps 下 3 层全屏大圆持续放大插值仍卡顿，
/// v2.0.138 决定直接移除波纹层（修不好宁可整体移除，用户确认），只保留粒子特效。
struct FullScreenBurst: View {
    @State private var spawn = Date()

    var body: some View {
        // 锁 60fps（v2.0.133d：ProMotion 120Hz 下每帧全屏 Canvas 重绘开销大，60fps 肉眼已顺滑）
        // v2.0.134 修复 CI：TimelineView content 只返回简单类型 BurstCanvas——原内联 Canvas 多语句闭包
        // 类型错误会让编译器报外层 generic parameter 'Content' could not be inferred（check_swift.sh 查不出）
        GeometryReader { geo in
            // 粒子层：160 颗飞散粒子（v2.0.138：波纹层已移除，仅粒子）
            let schedule: AnimationTimelineSchedule = .animation(minimumInterval: 1.0 / 30.0)
            TimelineView(schedule) { context in
                BurstCanvas(date: context.date, spawn: spawn)
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
            let origin = CGPoint(x: w / 2, y: h - 136)
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

    var body: some View {
        let schedule: AnimationTimelineSchedule = .animation(minimumInterval: 1.0 / 30.0)
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
                    .blur(radius: 6)
                    .frame(width: 84, height: 84)
                Circle()
                    .fill(AngularGradient(colors: bodyColors, center: .center))
                    .frame(width: 72, height: 72)
                    .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1.2))
                    .shadow(color: Color.indigo.opacity(0.45 * breathe), radius: 14)
                OrbCanvasView(mode: thinking ? .orbits : .ring, size: 60)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 92, height: 92)
        .contentShape(Circle())
        // v3.1.4+：长按语音转文字 / 单击展开（ExclusiveGesture 互斥，防长按同时触发单击）
        .gesture(
            ExclusiveGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in if voiceEnabled { onLongPress() } },
                TapGesture().onEnded { _ in onTap() }
            )
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
