import SwiftUI

// MARK: - 宠物矢量绘制（纯 Canvas + Path，零依赖）
//
// v4.0.1：**圆形基形重做**（用户 2026-09-27 拍板 `/opt/data/scripts/ql_pet/mock/pet_round_compare.png`）。
// 造型口径照那份效果稿，别自由发挥：
//   · 主形一律**一个圆**（96pt 容器内，半径 0.37~0.40），个体靠「五官比例 + 附件 + 配色」区分
//     —— 液态小生物＝圆 + 两只小手（蓝紫玻璃）；圆胖小兽＝圆 + 两只圆耳（暖橙）；
//        圆头小机器人＝圆 + 头顶天线 + 面罩带（青绿金属）。
//   · 附件画在主形**之后或之前**已定序：耳/天线在身体之后（会被圆压住耳根），手在身体之前。
//   · 三只共用 `shell()` 一套壳（外发光 / 径向渐变 / 高光 / 底部反光 / 描边），
//     只有附件与五官各自一份 —— 这不是「换色冒充」，附件与五官比例确实不同。
//   · 状态四态只改五官（idle / patting / thinking / alert）；思考气泡与新消息角标是
//     SwiftUI 覆盖层（`PetAvatar.decoration`），**不在这里画**（那是护栏钉住的分工）。
// 坐标一律**归一化到 0…1**，乘画布边长 → 任意尺寸都对；76pt 以下走 `simplify`
// （只画主形 + 眼 + 嘴，附件与高光全丢，小了会糊成一团）。

struct PetPainter {
    let style: PetStyle
    let state: PetState
    let blink: Bool
    let simplify: Bool

    // 调色板（与效果稿同一套）
    private enum Pal {
        static let liquidTop = Color(red: 0.56, green: 0.70, blue: 1.00)
        static let liquidMid = Color(red: 0.31, green: 0.40, blue: 0.92)
        static let liquidDeep = Color(red: 0.42, green: 0.27, blue: 0.84)
        static let liquidEdge = Color(red: 0.24, green: 0.18, blue: 0.56)
        static let liquidGlow = Color(red: 0.61, green: 0.71, blue: 1.00)
        static let liquidRim = Color(red: 0.62, green: 0.71, blue: 1.00)
        static let liquidInk = Color(red: 0.06, green: 0.11, blue: 0.24)

        static let beastTop = Color(red: 1.00, green: 0.90, blue: 0.77)
        static let beastMid = Color(red: 1.00, green: 0.77, blue: 0.54)
        static let beastBottom = Color(red: 0.94, green: 0.60, blue: 0.34)
        static let beastEdge = Color(red: 0.78, green: 0.47, blue: 0.25)
        static let beastGlow = Color(red: 1.00, green: 0.79, blue: 0.55)
        static let beastEarIn = Color(red: 1.00, green: 0.71, blue: 0.63)
        static let beastNose = Color(red: 0.89, green: 0.50, blue: 0.42)
        static let beastInk = Color(red: 0.16, green: 0.12, blue: 0.09)

        static let botTop = Color(red: 0.75, green: 0.95, blue: 0.91)
        static let botMid = Color(red: 0.37, green: 0.85, blue: 0.75)
        static let botBottom = Color(red: 0.15, green: 0.62, blue: 0.61)
        static let botEdge = Color(red: 0.05, green: 0.44, blue: 0.44)
        static let botGlow = Color(red: 0.37, green: 0.85, blue: 0.75)
        static let botInk = Color(red: 0.05, green: 0.23, blue: 0.29)
        static let botLamp = Color(red: 0.22, green: 0.82, blue: 0.69)

        static let blush = Color(red: 1.00, green: 0.56, blue: 0.65)
        static let sparkleWarm = Color(red: 1.00, green: 0.79, blue: 0.24)
        static let shadow = Color(red: 0.30, green: 0.36, blue: 0.45)
    }

    func draw(_ ctx: inout GraphicsContext, size canvas: CGSize) {
        let s = canvas.width
        switch style {
        case .liquid: drawLiquid(&ctx, s)
        case .beast: drawBeast(&ctx, s)
        case .robot: drawRobot(&ctx, s)
        }
    }

    // MARK: 坐标助手

    private func p(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
    private func r(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ s: CGFloat) -> CGRect {
        CGRect(x: (cx - rx) * s, y: (cy - ry) * s, width: rx * 2 * s, height: ry * 2 * s)
    }
    /// 绕 `around` 旋转 `degrees` 度。
    /// ⚠️ `around` 传的是 `p(x, y, s)` 的**绝对坐标**（已乘过 s），这里**绝不能再乘一次 s**。
    /// v4.0.2 实测：多乘一次 → 旋转中心跑到 s² 尺度（96pt 下 (1981,-143)）→ 附件与高光
    /// 全被裁到 96×96 画布外，真机上「两只小手」「顶部高光」从不显示。护栏只判 drawXxx 存在，
    /// 抓不到这个 —— 已加 `scripts/ql_orb/truth_table_orb.swift` 旋转中心断言。
    private func rotated(_ path: Path, _ degrees: CGFloat, _ around: CGPoint, _ s: CGFloat) -> Path {
        let t = CGAffineTransform(translationX: around.x, y: around.y)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -around.x, y: -around.y)
        return path.applying(t)
    }
    private func sparkle(_ cx: CGFloat, _ cy: CGFloat, _ radius: CGFloat, _ s: CGFloat) -> Path {
        let c = p(cx, cy, s); let rad = radius * s; let k = rad * 0.30
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - rad))
        path.addQuadCurve(to: CGPoint(x: c.x + rad, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + rad), control: CGPoint(x: c.x + k, y: c.y + k))
        path.addQuadCurve(to: CGPoint(x: c.x - rad, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - rad), control: CGPoint(x: c.x - k, y: c.y - k))
        path.closeSubpath()
        return path
    }
    private func soft(_ ctx: inout GraphicsContext, radius: CGFloat, _ body: (inout GraphicsContext) -> Void) {
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: radius))
            body(&layer)
        }
    }

    // MARK: 通用壳：外发光 + 径向渐变主形 + 顶部高光 + 底部反光 + 描边
    //
    // ⚠️ `simplify` 时只画主形与描边（高光/反光/发光全丢）—— 30pt 上这些是一层糊灰。
    private func shell(_ ctx: inout GraphicsContext, _ s: CGFloat,
                       radius: CGFloat,
                       stops: [(CGFloat, Color)],
                       glow: Color,
                       edge: Color) {
        if !simplify {
            soft(&ctx, radius: 0.03 * s) { layer in
                layer.fill(Path(ellipseIn: r(0.5, 0.5, radius + 0.01, radius + 0.01, s)),
                           with: .radialGradient(
                            Gradient(colors: [glow.opacity(0.55), .clear]),
                            center: p(0.5, 0.5, s), startRadius: radius * 0.6 * s, endRadius: (radius + 0.01) * s))
            }
        }
        let body = Path(ellipseIn: r(0.5, 0.5, radius, radius, s))
        ctx.fill(body, with: .radialGradient(
            Gradient(stops: stops.map { Gradient.Stop(color: $0.1, location: $0.0) }),
            center: p(0.36, 0.28, s), startRadius: 0, endRadius: (radius + 0.12) * s))
        if !simplify {
            // 顶部高光
            soft(&ctx, radius: 0.02 * s) { layer in
                let hl = Path(ellipseIn: r(0.36, 0.30, 0.15, 0.09, s))
                layer.fill(rotated(hl, -24, p(0.36, 0.30, s), s), with: .color(.white.opacity(0.42)))
            }
            // 底部反光弧
            var rim = Path()
            rim.addArc(center: p(0.5, 0.5, s), radius: (radius - 0.02) * s,
                       startAngle: .degrees(30), endAngle: .degrees(150), clockwise: false)
            soft(&ctx, radius: 0.015 * s) { layer in
                layer.stroke(rim, with: .color(.white.opacity(0.38)),
                             style: StrokeStyle(lineWidth: 0.03 * s, lineCap: .round))
            }
        }
        ctx.stroke(body, with: .color(edge.opacity(simplify ? 0.45 : 0.55)), lineWidth: max(1, 0.012 * s))
    }

    /// 五态共用的两层变换：抚摸整体上抬一点；新消息整体歪头。
    /// 五官在这两层**之内**画 → 歪头时脸跟着歪（否则脸是正的、头歪着，更怪）。
    private func withBodyTransforms(_ ctx: inout GraphicsContext, _ s: CGFloat,
                                    _ paint: (inout GraphicsContext) -> Void) {
        let lift: CGFloat = state == .patting ? -0.02 : 0
        let tilt: CGFloat = state == .alert ? -4 : 0
        ctx.translateBy(x: 0, y: lift * s)
        if tilt == 0 {
            paint(&ctx)
        } else {
            ctx.drawLayer { layer in
                layer.translateBy(x: 0.5 * s, y: 0.62 * s)
                layer.rotate(by: .degrees(tilt))
                layer.translateBy(x: -0.5 * s, y: -0.62 * s)
                paint(&layer)
            }
        }
    }

    /// 眼睛：睁眼（黑豆 + 双高光）/ 闭眼（上弯弧，抚摸与眨眼共用）
    private func dotEyes(_ ctx: inout GraphicsContext, _ s: CGFloat,
                         _ cx1: CGFloat, _ cx2: CGFloat, _ cy: CGFloat,
                         _ rx: CGFloat, _ ry: CGFloat, _ color: Color, closed: Bool) {
        if closed {
            for cx in [cx1, cx2] {
                var arc = Path()
                arc.move(to: p(cx - rx * 0.95, cy + ry * 0.15, s))
                arc.addQuadCurve(to: p(cx + rx * 0.95, cy + ry * 0.15, s),
                                 control: p(cx, cy - ry * 0.9, s))
                ctx.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: max(1, 0.020 * s), lineCap: .round))
            }
        } else {
            for cx in [cx1, cx2] {
                ctx.fill(Path(ellipseIn: r(cx, cy, rx, ry, s)), with: .color(color))
                ctx.fill(Path(ellipseIn: r(cx + rx * 0.36, cy - ry * 0.38, rx * 0.42, ry * 0.36, s)),
                         with: .color(.white.opacity(0.95)))
            }
        }
    }
    /// 腮红：抚摸时更浓（唯一的状态冗余强度差）
    private func blushPair(_ ctx: inout GraphicsContext, _ s: CGFloat,
                           _ cx1: CGFloat, _ cx2: CGFloat, _ cy: CGFloat,
                           _ rx: CGFloat, _ ry: CGFloat, _ base: CGFloat = 0.45) {
        let o = state == .patting ? min(1, base + 0.2) : base
        ctx.fill(Path(ellipseIn: r(cx1, cy, rx, ry, s)), with: .color(Pal.blush.opacity(o)))
        ctx.fill(Path(ellipseIn: r(cx2, cy, rx, ry, s)), with: .color(Pal.blush.opacity(o)))
    }
    /// 抚摸反馈：两颗四角星（第一只暖黄，后两只跟自身配色）
    private func patSparkles(_ ctx: inout GraphicsContext, _ s: CGFloat, _ color: Color) {
        guard state == .patting else { return }
        ctx.fill(sparkle(0.80, 0.17, 0.050, s), with: .color(color))
        ctx.fill(sparkle(0.20, 0.30, 0.034, s), with: .color(color.opacity(0.85)))
    }
    /// 眉毛式「思考」横线：呆住的表情，两端不接边
    private func flatMouth(_ ctx: inout GraphicsContext, _ s: CGFloat,
                           _ y: CGFloat, _ half: CGFloat, _ color: Color, _ opacity: CGFloat = 0.6) {
        var line = Path()
        line.move(to: p(0.5 - half, y, s)); line.addLine(to: p(0.5 + half, y, s))
        ctx.stroke(line, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: max(1, 0.016 * s), lineCap: .round))
    }
    private func smile(_ ctx: inout GraphicsContext, _ s: CGFloat,
                       _ y: CGFloat, _ half: CGFloat, _ depth: CGFloat,
                       _ color: Color, _ opacity: CGFloat = 0.75, _ width: CGFloat = 0.016) {
        var m = Path()
        m.move(to: p(0.5 - half, y, s))
        m.addQuadCurve(to: p(0.5 + half, y, s), control: p(0.5, y + depth, s))
        ctx.stroke(m, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: max(1, width * s), lineCap: .round))
    }

    // MARK: 1 · 液态小生物（圆 + 两只小手；蓝紫玻璃，延续原球身份）

    private func drawLiquid(_ ctx: inout GraphicsContext, _ s: CGFloat) {
        withBodyTransforms(&ctx, s) { layer in
            if !simplify {
                // 两只小手（同材质小球，画在主形之前 → 半个身子被圆压住，像从后面伸出来）
                layer.fill(rotated(Path(ellipseIn: r(0.17, 0.60, 0.085, 0.10, s)), 20, p(0.17, 0.60, s), s),
                           with: .color(Pal.liquidMid))
                layer.fill(rotated(Path(ellipseIn: r(0.83, 0.60, 0.085, 0.10, s)), -20, p(0.83, 0.60, s), s),
                           with: .color(Pal.liquidMid))
            }
            shell(&layer, s, radius: 0.40,
                  stops: [(0.0, Pal.liquidTop), (0.45, Pal.liquidMid), (0.80, Pal.liquidDeep), (1.0, Pal.liquidEdge)],
                  glow: Pal.liquidGlow, edge: Pal.liquidEdge)
            paintLiquidFace(&layer, s)
        }
        patSparkles(&ctx, s, Pal.sparkleWarm)
    }

    private func paintLiquidFace(_ ctx: inout GraphicsContext, _ s: CGFloat) {
        switch state {
        case .idle:
            dotEyes(&ctx, s, 0.40, 0.60, 0.46, 0.050, 0.064, Pal.liquidInk, closed: blink)
            smile(&ctx, s, 0.58, 0.03, 0.035, Pal.liquidInk, 0.72, 0.015)
            blushPair(&ctx, s, 0.30, 0.70, 0.55, 0.040, 0.024)
        case .patting:
            dotEyes(&ctx, s, 0.40, 0.60, 0.49, 0.050, 0.060, Pal.liquidInk, closed: true)
            ctx.fill(Path(ellipseIn: r(0.50, 0.57, 0.035, 0.026, s)),
                     with: .color(Pal.blush.opacity(0.9)))
            blushPair(&ctx, s, 0.30, 0.70, 0.56, 0.044, 0.026)
        case .thinking:
            dotEyes(&ctx, s, 0.40, 0.60, 0.46, 0.050, 0.064, Pal.liquidInk, closed: blink)
            flatMouth(&ctx, s, 0.585, 0.04, Pal.liquidInk, 0.55)
        case .alert:
            dotEyes(&ctx, s, 0.40, 0.60, 0.47, 0.050, 0.064, Pal.liquidInk, closed: blink)
            ctx.fill(Path(ellipseIn: r(0.50, 0.59, 0.028, 0.034, s)), with: .color(Pal.liquidInk.opacity(0.85)))
        }
    }

    // MARK: 2 · 圆胖小兽（圆 + 两只圆耳；暖橙，辨识度最高）

    private func drawBeast(_ ctx: inout GraphicsContext, _ s: CGFloat) {
        withBodyTransforms(&ctx, s) { layer in
            if !simplify {
                // 两只圆耳（画在主形之前 → 耳根被圆压住）
                // ⚠️ 耳心/半径是算过的：体半径 0.37，耳心到体心 0.368 → 耳朵露出
                // (0.368+0.095-0.37)=0.093 ≈ 8.9pt@96pt，耳根仍被圆压住。
                // 内耳同心 0.050 → 露出 0.048 ≈ 4.6pt 的粉色耳尖。
                // v4.0.2 实测：旧值(0.27,0.27,r0.09/0.042) 只露 4.3pt，内耳 0.26pt 半径
                // **完全被身体盖住 = 死代码**，等于「圆 + 两只圆耳」在真机上不成立。
                for cx in [CGFloat(0.255), CGFloat(0.745)] {
                    layer.fill(Path(ellipseIn: r(cx, 0.225, 0.095, 0.095, s)), with: .color(Pal.beastMid))
                    layer.fill(Path(ellipseIn: r(cx, 0.225, 0.050, 0.050, s)), with: .color(Pal.beastEarIn.opacity(0.85)))
                }
            }
            shell(&layer, s, radius: 0.37,
                  stops: [(0.0, Pal.beastTop), (0.55, Pal.beastMid), (1.0, Pal.beastBottom)],
                  glow: Pal.beastGlow, edge: Pal.beastEdge)
            paintBeastFace(&layer, s)
        }
        patSparkles(&ctx, s, Pal.sparkleWarm)
    }

    private func paintBeastFace(_ ctx: inout GraphicsContext, _ s: CGFloat) {
        // 口鼻：三角鼻 + 一竖（辨识度锚点，四态都在）
        switch state {
        case .idle:
            dotEyes(&ctx, s, 0.39, 0.61, 0.44, 0.064, 0.080, Pal.beastInk, closed: blink)
            ctx.fill(Path(ellipseIn: r(0.50, 0.555, 0.040, 0.030, s)), with: .color(Pal.beastNose))
            var ph = Path()
            ph.move(to: p(0.50, 0.585, s)); ph.addLine(to: p(0.50, 0.615, s))
            ctx.stroke(ph, with: .color(Pal.beastEdge), style: StrokeStyle(lineWidth: max(1, 0.012 * s), lineCap: .round))
        case .patting:
            dotEyes(&ctx, s, 0.39, 0.61, 0.45, 0.060, 0.074, Pal.beastInk, closed: true)
            ctx.fill(Path(ellipseIn: r(0.50, 0.555, 0.040, 0.030, s)), with: .color(Pal.beastNose))
            smile(&ctx, s, 0.585, 0.05, 0.05, Pal.beastInk, 0.7, 0.015)
        case .thinking:
            dotEyes(&ctx, s, 0.39, 0.61, 0.44, 0.064, 0.080, Pal.beastInk, closed: blink)
            ctx.fill(Path(ellipseIn: r(0.50, 0.550, 0.034, 0.026, s)), with: .color(Pal.beastNose))
            flatMouth(&ctx, s, 0.595, 0.03, Pal.beastInk, 0.6)
        case .alert:
            dotEyes(&ctx, s, 0.39, 0.61, 0.43, 0.072, 0.090, Pal.beastInk, closed: blink)
            ctx.fill(Path(ellipseIn: r(0.50, 0.550, 0.034, 0.026, s)), with: .color(Pal.beastNose))
            ctx.fill(Path(ellipseIn: r(0.50, 0.600, 0.026, 0.022, s)), with: .color(Pal.beastEdge.opacity(0.85)))
        }
        blushPair(&ctx, s, 0.27, 0.73, 0.565, 0.040, 0.024)
    }

    // MARK: 3 · 圆头小机器人（圆 + 头顶天线 + 面罩带；青绿金属）

    private func drawRobot(_ ctx: inout GraphicsContext, _ s: CGFloat) {
        withBodyTransforms(&ctx, s) { layer in
            if !simplify {
                // 天线（画在主形之前）
                layer.fill(rounded(0.49, 0.02, 0.02, 0.15, 0.01, s), with: .color(Pal.botInk.opacity(0.55)))
                layer.fill(Path(ellipseIn: r(0.50, 0.03, 0.034, 0.034, s)), with: .color(Pal.botLamp))
            }
            shell(&layer, s, radius: 0.38,
                  stops: [(0.0, Pal.botTop), (0.50, Pal.botMid), (1.0, Pal.botBottom)],
                  glow: Pal.botGlow, edge: Pal.botEdge)
            // 面罩带：一条压在**眼上沿**的深色弧带（机器人辨识度锚点）
            // v4.0.2 实测：旧几何(arc 中心 0.66 / 半径 0.315 / 238°→302°) 的带子落在
            // y 33.1~38.9pt，而眼占 y 39.8~47.3pt → **根本没压到眼**；右侧还单独
            // addLine 到 (0.76,0.40) 甩出一个左无对应的尖角。改成左右对称的双同心弧带：
            // 圆心 (0.5,0.66)，外弧 R=0.275 / 内弧 R=0.248，250°↔290° 走正上方 →
            // 带子覆盖 y 0.385~0.4269（37.0~41.0pt），与眼上沿 0.415(39.8pt) 有交叠，
            // 眼睛画在带子之后 → 视觉是「眉带压着眼上沿」。
            // 端点坐标用常量写死（cos250/sin250 = -0.342/-0.940），不引 cosl：
            // `import SwiftUI` 虽通常带上 Foundation，但为两个端点赌它不必要。
            if !simplify {
                var visor = Path()
                visor.move(to: p(0.4179, 0.4345, s))
                visor.addArc(center: p(0.5, 0.66, s), radius: 0.240 * s,
                             startAngle: .degrees(250), endAngle: .degrees(290), clockwise: false)
                visor.addLine(to: p(0.5941, 0.4016, s))
                visor.addArc(center: p(0.5, 0.66, s), radius: 0.275 * s,
                             startAngle: .degrees(290), endAngle: .degrees(250), clockwise: true)
                visor.closeSubpath()
                layer.fill(visor, with: .color(Pal.botInk.opacity(0.22)))
            }
            paintRobotFace(&layer, s)
        }
        patSparkles(&ctx, s, Pal.botLamp)
    }

    private func paintRobotFace(_ ctx: inout GraphicsContext, _ s: CGFloat) {
        // 眼睛是**圆角方块**（不是豆眼）—— 与另两只一眼分得开
        let rect = { (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) in
            rounded(x, y, w, h, 0.018, s)
        }
        switch state {
        case .idle:
            // 待机眼别太小：真图看下来 0.09×0.07 在 96pt 上像两条缝 → 放大到 0.10×0.078
            ctx.fill(rect(0.36, 0.415, 0.10, 0.078), with: .color(Pal.botInk))
            ctx.fill(rect(0.54, 0.415, 0.10, 0.078), with: .color(Pal.botInk))
            ctx.fill(rounded(0.45, 0.555, 0.10, 0.03, 0.015, s), with: .color(Pal.botInk.opacity(0.8)))
        case .patting:
            for x in [CGFloat(0.37), CGFloat(0.54)] {
                var arc = Path()
                arc.move(to: p(x, 0.47, s)); arc.addQuadCurve(to: p(x + 0.09, 0.47, s), control: p(x + 0.045, 0.40, s))
                ctx.stroke(arc, with: .color(Pal.botInk), style: StrokeStyle(lineWidth: max(1, 0.020 * s), lineCap: .round))
            }
            smile(&ctx, s, 0.55, 0.06, 0.06, Pal.botInk, 0.8, 0.020)
        case .thinking:
            ctx.fill(rect(0.36, 0.415, 0.10, 0.078), with: .color(Pal.botInk))
            ctx.fill(rect(0.54, 0.415, 0.10, 0.078), with: .color(Pal.botInk))
            ctx.fill(rounded(0.46, 0.565, 0.08, 0.03, 0.015, s), with: .color(Pal.botInk.opacity(0.7)))
        case .alert:
            ctx.fill(rounded(0.36, 0.41, 0.10, 0.08, 0.022, s), with: .color(Pal.botInk))
            ctx.fill(rounded(0.54, 0.41, 0.10, 0.08, 0.022, s), with: .color(Pal.botInk))
            ctx.fill(Path(ellipseIn: r(0.50, 0.575, 0.030, 0.034, s)), with: .color(Pal.botInk.opacity(0.85)))
        }
        blushPair(&ctx, s, 0.26, 0.74, 0.60, 0.055, 0.032, 0.38)
    }

    /// 圆角矩形（眼睛/天线/嘴都是方件，Path 拼的）
    private func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                         _ cr: CGFloat, _ s: CGFloat) -> Path {
        let rect = CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
        return Path(roundedRect: rect, cornerRadius: cr * s, style: .continuous)
    }
}
