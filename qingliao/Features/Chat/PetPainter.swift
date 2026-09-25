import SwiftUI

// MARK: - v3.9.78 宠物矢量绘制（纯 Canvas + Path，零依赖）
//
// 三只形态的坐标一律**归一化到 0…1**，乘以画布边长 → 同一个画法在任意尺寸都对，
// 且「细节量」由 `simplify` 控制（76pt 以下只画头 + 眼 + 嘴，见 PetAvatar）。
// 造型来源 = 用户拍板的效果稿（scripts/ql_pet/mock/pet_states_compare.png），别自由改造型。

struct PetPainter {
    let style: PetStyle
    let state: PetState
    let blink: Bool
    let simplify: Bool

    // 调色板（与效果稿同一套；液态沿用原球的蓝紫）
    private enum Pal {
        static let ink = Color(red: 0.06, green: 0.11, blue: 0.24)
        static let liquidTop = Color(red: 0.56, green: 0.70, blue: 1.00)
        static let liquidMid = Color(red: 0.31, green: 0.40, blue: 0.92)
        static let liquidDeep = Color(red: 0.42, green: 0.27, blue: 0.84)
        static let liquidEdge = Color(red: 0.24, green: 0.18, blue: 0.56)
        static let liquidRim = Color(red: 0.78, green: 0.84, blue: 1.00)
        static let blush = Color(red: 1.00, green: 0.56, blue: 0.72)
        static let sparkle = Color(red: 1.00, green: 0.80, blue: 0.35)
        static let catTop = Color(red: 1.00, green: 0.95, blue: 0.89)
        static let catBottom = Color(red: 1.00, green: 0.85, blue: 0.68)
        static let catLine = Color(red: 0.91, green: 0.71, blue: 0.51)
        static let catInk = Color(red: 0.23, green: 0.17, blue: 0.13)
        static let catNose = Color(red: 0.89, green: 0.50, blue: 0.42)
        static let sealTop = Color(red: 0.92, green: 0.95, blue: 1.00)
        static let sealMid = Color(red: 0.77, green: 0.85, blue: 0.95)
        static let sealBottom = Color(red: 0.62, green: 0.74, blue: 0.88)
        static let sealLine = Color(red: 0.58, green: 0.69, blue: 0.82)
        static let sealInk = Color(red: 0.15, green: 0.19, blue: 0.25)
        static let sealMuzzle = Color(red: 0.95, green: 0.97, blue: 1.00)
        static let shadow = Color(red: 0.30, green: 0.36, blue: 0.45)
    }

    func draw(_ ctx: inout GraphicsContext, size canvas: CGSize) {
        let s = canvas.width
        switch style {
        case .liquid: drawLiquid(&ctx, s)
        case .cat: drawCat(&ctx, s)
        case .seal: drawSeal(&ctx, s)
        }
    }

    // MARK: 坐标助手

    private func p(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
    private func r(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ s: CGFloat) -> CGRect {
        CGRect(x: (cx - rx) * s, y: (cy - ry) * s, width: rx * 2 * s, height: ry * 2 * s)
    }
    private func rotated(_ path: Path, _ degrees: CGFloat, _ around: CGPoint, _ s: CGFloat) -> Path {
        let t = CGAffineTransform(translationX: around.x * s, y: around.y * s)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -around.x * s, y: -around.y * s)
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
    /// 眼睛：睁眼（黑豆 + 双高光）/ 闭眼（上弯弧，用于抚摸与眨眼）
    private func eyes(_ ctx: inout GraphicsContext, _ s: CGFloat,
                      _ cx1: CGFloat, _ cx2: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat,
                      _ color: Color, closed: Bool) {
        if closed {
            for cx in [cx1, cx2] {
                var arc = Path()
                arc.move(to: p(cx - rx * 0.9, cy + ry * 0.15, s))
                arc.addQuadCurve(to: p(cx + rx * 0.9, cy + ry * 0.15, s),
                                 control: p(cx, cy - ry * 0.85, s))
                ctx.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: max(1, 0.042 * s), lineCap: .round))
            }
        } else {
            for cx in [cx1, cx2] {
                ctx.fill(Path(ellipseIn: r(cx, cy, rx, ry, s)), with: .color(color))
                ctx.fill(Path(ellipseIn: r(cx + rx * 0.32, cy - ry * 0.36, rx * 0.40, ry * 0.34, s)),
                         with: .color(.white.opacity(0.95)))
            }
        }
    }

    // MARK: 方向 1 · 液态小生物（沿用原球的材质与配色，身份不断层）

    private func drawLiquid(_ ctx: inout GraphicsContext, _ s: CGFloat) {
        let lift: CGFloat = state == .patting ? -0.02 : 0
        let tilt: CGFloat = state == .alert ? -4 : 0
        ctx.translateBy(x: 0, y: lift * s)

        if !simplify {
            // 外发光
            soft(&ctx, radius: 0.03 * s) { layer in
                layer.fill(Path(ellipseIn: r(0.5, 0.5, 0.49, 0.49, s)),
                           with: .radialGradient(Gradient(colors: [Color(red: 0.61, green: 0.71, blue: 1.0).opacity(0.55), .clear]),
                                                 center: p(0.5, 0.5, s), startRadius: 0.28 * s, endRadius: 0.49 * s))
            }
            // 两只小手（同材质小球，收在身后一点）
            let arm = Path(ellipseIn: r(0.21, 0.62, 0.09, 0.11, s))
            ctx.fill(rotated(arm, 18, p(0.21, 0.62, s), s), with: .color(Pal.liquidMid))
            ctx.fill(rotated(Path(ellipseIn: r(0.79, 0.62, 0.09, 0.11, s)), -18, p(0.79, 0.62, s), s),
                     with: .color(Pal.liquidMid))
        }

        // 身体
        let body = Path(ellipseIn: r(0.5, 0.5, 0.41, 0.41, s))
        ctx.fill(body, with: .radialGradient(
            Gradient(stops: [.init(color: Pal.liquidTop, location: 0.0),
                             .init(color: Pal.liquidMid, location: 0.45),
                             .init(color: Pal.liquidDeep, location: 0.80),
                             .init(color: Pal.liquidEdge, location: 1.0)]),
            center: p(0.38, 0.30, s), startRadius: 0, endRadius: 0.52 * s))
        ctx.stroke(body, with: .color(Pal.liquidEdge.opacity(0.55)), lineWidth: max(1, 0.012 * s))

        if !simplify {
            // 顶部高光 + 底部反光（精致感来自高光，不来自细节堆叠）
            soft(&ctx, radius: 0.02 * s) { layer in
                let hl = Path(ellipseIn: r(0.38, 0.32, 0.14, 0.09, s))
                layer.fill(rotated(hl, -22, p(0.38, 0.32, s), s), with: .color(.white.opacity(0.45)))
            }
            var rim = Path()
            rim.addArc(center: p(0.5, 0.5, s), radius: 0.38 * s,
                       startAngle: .degrees(30), endAngle: .degrees(150), clockwise: false)
            soft(&ctx, radius: 0.015 * s) { layer in
                layer.stroke(rim, with: .color(Pal.liquidRim.opacity(0.55)),
                             style: StrokeStyle(lineWidth: 0.03 * s, lineCap: .round))
            }
        }

        // 面部
        let tiltCtx = tilt == 0
        if tiltCtx {
            paintLiquidFace(&ctx, s)
        } else {
            ctx.drawLayer { layer in
                layer.translateBy(x: 0.5 * s, y: 0.62 * s)
                layer.rotate(by: .degrees(tilt))
                layer.translateBy(x: -0.5 * s, y: -0.62 * s)
                paintLiquidFace(&layer, s)
            }
        }

        if state == .patting {
            ctx.fill(sparkle(0.74, 0.20, 0.055, s), with: .color(Pal.sparkle))
            ctx.fill(sparkle(0.24, 0.30, 0.038, s), with: .color(Pal.sparkle.opacity(0.85)))
            if !simplify {
                var arc = Path()
                arc.move(to: p(0.28, 0.84, s))
                arc.addQuadCurve(to: p(0.72, 0.84, s), control: p(0.50, 0.92, s))
                ctx.stroke(arc, with: .color(Pal.liquidRim.opacity(0.5)),
                           style: StrokeStyle(lineWidth: max(1, 0.02 * s), lineCap: .round, dash: [0.03 * s, 0.04 * s]))
            }
        }
    }

    private func paintLiquidFace(_ ctx: inout GraphicsContext, _ s: CGFloat) {
        switch state {
        case .patting:
            eyes(&ctx, s, 0.39, 0.61, 0.48, 0.05, 0.062, Pal.ink, closed: true)
            var smile = Path()
            smile.move(to: p(0.45, 0.56, s))
            smile.addQuadCurve(to: p(0.55, 0.56, s), control: p(0.50, 0.63, s))
            ctx.stroke(smile, with: .color(Pal.ink.opacity(0.75)), style: StrokeStyle(lineWidth: max(1, 0.018 * s), lineCap: .round))
            ctx.fill(Path(ellipseIn: r(0.29, 0.57, 0.05, 0.03, s)), with: .color(Pal.blush.opacity(0.6)))
            ctx.fill(Path(ellipseIn: r(0.71, 0.57, 0.05, 0.03, s)), with: .color(Pal.blush.opacity(0.6)))
        case .thinking:
            eyes(&ctx, s, 0.39, 0.61, 0.48, 0.046, 0.062, Pal.ink, closed: blink)
            var line = Path()
            line.move(to: p(0.46, 0.585, s)); line.addLine(to: p(0.54, 0.585, s))
            ctx.stroke(line, with: .color(Pal.ink.opacity(0.55)), style: StrokeStyle(lineWidth: max(1, 0.016 * s), lineCap: .round))
        case .alert:
            eyes(&ctx, s, 0.39, 0.61, 0.48, 0.052, 0.068, Pal.ink, closed: blink)
            ctx.fill(Path(ellipseIn: r(0.50, 0.59, 0.03, 0.036, s)), with: .color(Pal.ink.opacity(0.85)))
        case .idle:
            eyes(&ctx, s, 0.39, 0.61, 0.48, 0.046, 0.062, Pal.ink, closed: blink)
            var smile = Path()
            smile.move(to: p(0.47, 0.58, s))
            smile.addQuadCurve(to: p(0.53, 0.58, s), control: p(0.50, 0.615, s))
            ctx.stroke(smile, with: .color(Pal.ink.opacity(0.72)), style: StrokeStyle(lineWidth: max(1, 0.016 * s), lineCap: .round))
            ctx.fill(Path(ellipseIn: r(0.31, 0.56, 0.04, 0.024, s)), with: .color(Pal.blush.opacity(0.45)))
            ctx.fill(Path(ellipseIn: r(0.69, 0.56, 0.04, 0.024, s)), with: .color(Pal.blush.opacity(0.45)))
        }
    }

    // MARK: 方向 2 · 圆润小猫

    private func drawCat(_ ctx: inout GraphicsContext, _ s: CGFloat) {
        let lift: CGFloat = state == .patting ? -0.02 : 0
        let tilt: CGFloat = state == .alert ? -4 : 0
        ctx.translateBy(x: 0, y: lift * s)

        // 接触阴影：把角色「放」在平面上
        soft(&ctx, radius: 0.02 * s) { layer in
            layer.fill(Path(ellipseIn: r(0.50, 0.90, 0.26, 0.045, s)),
                       with: .color(Pal.shadow.opacity(0.22)))
        }

        ctx.drawLayer { layer in
            if tilt != 0 {
                layer.translateBy(x: 0.5 * s, y: 0.62 * s)
                layer.rotate(by: .degrees(tilt))
                layer.translateBy(x: -0.5 * s, y: -0.62 * s)
            }
            if !simplify {
                // 尾巴（画在身体后）
                var tail = Path()
                tail.move(to: p(0.74, 0.78, s))
                tail.addQuadCurve(to: p(0.86, 0.64, s), control: p(0.92, 0.80, s))
                layer.stroke(tail, with: .color(Color(red: 1.00, green: 0.81, blue: 0.62)),
                             style: StrokeStyle(lineWidth: 0.09 * s, lineCap: .round))
                // 身体
                let body = Path(ellipseIn: r(0.50, 0.72, 0.23, 0.20, s))
                layer.fill(body, with: .linearGradient(
                    Gradient(colors: [Pal.catTop, Pal.catBottom]), startPoint: p(0.5, 0.5, s), endPoint: p(0.5, 0.95, s)))
                layer.stroke(body, with: .color(Pal.catLine), lineWidth: max(1, 0.016 * s))
            }

            // 耳朵（在头之前画，耳根被头压住）
            let earL = Path { path in
                path.move(to: p(0.31, 0.24, s)); path.addLine(to: p(0.27, 0.09, s))
                path.addLine(to: p(0.43, 0.20, s)); path.closeSubpath()
            }
            let earR = Path { path in
                path.move(to: p(0.69, 0.24, s)); path.addLine(to: p(0.73, 0.09, s))
                path.addLine(to: p(0.57, 0.20, s)); path.closeSubpath()
            }
            let grad = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Pal.catTop, Pal.catBottom]), startPoint: p(0.5, 0.1, s), endPoint: p(0.5, 0.7, s))
            layer.fill(earL, with: grad); layer.fill(earR, with: grad)
            layer.stroke(earL, with: .color(Pal.catLine), style: StrokeStyle(lineWidth: max(1, 0.016 * s), lineJoin: .round))
            layer.stroke(earR, with: .color(Pal.catLine), style: StrokeStyle(lineWidth: max(1, 0.016 * s), lineJoin: .round))
            layer.fill(Path { path in
                path.move(to: p(0.33, 0.22, s)); path.addLine(to: p(0.31, 0.14, s))
                path.addLine(to: p(0.40, 0.19, s)); path.closeSubpath()
            }, with: .color(Color(red: 1.00, green: 0.71, blue: 0.63).opacity(0.85)))

            // 头
            let head = Path { path in
                path.move(to: p(0.50, 0.17, s))
                path.addCurve(to: p(0.215, 0.47, s), control1: p(0.31, 0.17, s), control2: p(0.215, 0.30, s))
                path.addCurve(to: p(0.50, 0.705, s), control1: p(0.215, 0.63, s), control2: p(0.33, 0.705, s))
                path.addCurve(to: p(0.785, 0.47, s), control1: p(0.67, 0.705, s), control2: p(0.785, 0.63, s))
                path.addCurve(to: p(0.50, 0.17, s), control1: p(0.785, 0.30, s), control2: p(0.69, 0.17, s))
                path.closeSubpath()
            }
            layer.fill(head, with: .linearGradient(
                Gradient(colors: [Pal.catTop, Pal.catBottom]), startPoint: p(0.5, 0.17, s), endPoint: p(0.5, 0.71, s)))
            layer.stroke(head, with: .color(Pal.catLine), lineWidth: max(1, 0.016 * s))

            // 腮红
            let strong = state == .patting
            layer.fill(Path(ellipseIn: r(0.32, 0.55, 0.06, 0.034, s)),
                       with: .color(Pal.blush.opacity(strong ? 0.65 : 0.42)))
            layer.fill(Path(ellipseIn: r(0.68, 0.55, 0.06, 0.034, s)),
                       with: .color(Pal.blush.opacity(strong ? 0.65 : 0.42)))

            // 脸
            switch state {
            case .patting:
                eyes(&layer, s, 0.385, 0.615, 0.46, 0.055, 0.066, Pal.catInk, closed: true)
                layer.fill(triangle(0.475, 0.52, 0.525, 0.52, 0.50, 0.55, s), with: .color(Pal.catNose))
                var mouth = Path()
                mouth.move(to: p(0.44, 0.555, s))
                mouth.addQuadCurve(to: p(0.56, 0.555, s), control: p(0.50, 0.62, s))
                layer.stroke(mouth, with: .color(Pal.catNose.opacity(0.9)), style: StrokeStyle(lineWidth: max(1, 0.016 * s), lineCap: .round))
            case .thinking:
                eyes(&layer, s, 0.385, 0.615, 0.45, 0.054, 0.066, Pal.catInk, closed: blink)
                layer.fill(triangle(0.475, 0.52, 0.525, 0.52, 0.50, 0.55, s), with: .color(Pal.catNose))
                var mouth = Path()
                mouth.move(to: p(0.47, 0.565, s)); mouth.addLine(to: p(0.53, 0.565, s))
                layer.stroke(mouth, with: .color(Pal.catInk.opacity(0.6)), style: StrokeStyle(lineWidth: max(1, 0.014 * s), lineCap: .round))
            case .alert:
                eyes(&layer, s, 0.385, 0.615, 0.45, 0.062, 0.074, Pal.catInk, closed: blink)
                layer.fill(triangle(0.475, 0.52, 0.525, 0.52, 0.50, 0.55, s), with: .color(Pal.catNose))
                layer.fill(Path(ellipseIn: r(0.50, 0.585, 0.026, 0.022, s)), with: .color(Pal.catInk.opacity(0.8)))
            case .idle:
                eyes(&layer, s, 0.385, 0.615, 0.45, 0.054, 0.066, Pal.catInk, closed: blink)
                layer.fill(triangle(0.475, 0.52, 0.525, 0.52, 0.50, 0.55, s), with: .color(Pal.catNose))
                var mouth = Path()
                mouth.move(to: p(0.50, 0.55, s)); mouth.addQuadCurve(to: p(0.45, 0.575, s), control: p(0.485, 0.575, s))
                mouth.move(to: p(0.50, 0.55, s)); mouth.addQuadCurve(to: p(0.55, 0.575, s), control: p(0.515, 0.575, s))
                layer.stroke(mouth, with: .color(Pal.catInk.opacity(0.7)), style: StrokeStyle(lineWidth: max(1, 0.014 * s), lineCap: .round))
            }

            if !simplify {
                var whiskers = Path()
                whiskers.move(to: p(0.18, 0.46, s)); whiskers.addLine(to: p(0.27, 0.46, s))
                whiskers.move(to: p(0.18, 0.51, s)); whiskers.addLine(to: p(0.27, 0.51, s))
                whiskers.move(to: p(0.82, 0.46, s)); whiskers.addLine(to: p(0.73, 0.46, s))
                whiskers.move(to: p(0.82, 0.51, s)); whiskers.addLine(to: p(0.73, 0.51, s))
                layer.stroke(whiskers, with: .color(Pal.catLine.opacity(0.85)),
                             style: StrokeStyle(lineWidth: max(1, 0.013 * s), lineCap: .round))
            }
        }

        if state == .patting {
            ctx.fill(sparkle(0.76, 0.18, 0.055, s), with: .color(Pal.sparkle))
            ctx.fill(sparkle(0.24, 0.28, 0.038, s), with: .color(Pal.sparkle.opacity(0.85)))
        }
    }

    private func triangle(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat,
                          _ x3: CGFloat, _ y3: CGFloat, _ s: CGFloat) -> Path {
        Path { path in
            path.move(to: p(x1, y1, s)); path.addLine(to: p(x2, y2, s))
            path.addLine(to: p(x3, y3, s)); path.closeSubpath()
        }
    }

    // MARK: 方向 3 · 小海豹

    private func drawSeal(_ ctx: inout GraphicsContext, _ s: CGFloat) {
        let lift: CGFloat = state == .patting ? -0.02 : 0
        let tilt: CGFloat = state == .alert ? -4 : 0
        ctx.translateBy(x: 0, y: lift * s)

        soft(&ctx, radius: 0.02 * s) { layer in
            layer.fill(Path(ellipseIn: r(0.50, 0.90, 0.27, 0.045, s)), with: .color(Pal.shadow.opacity(0.22)))
        }

        ctx.drawLayer { layer in
            if tilt != 0 {
                layer.translateBy(x: 0.5 * s, y: 0.62 * s)
                layer.rotate(by: .degrees(tilt))
                layer.translateBy(x: -0.5 * s, y: -0.62 * s)
            }
            if !simplify {
                // 尾鳍 + 侧鳍
                layer.fill(triangle(0.28, 0.82, 0.12, 0.79, 0.28, 0.79, s),
                           with: .color(Color(red: 0.66, green: 0.78, blue: 0.90)))
                layer.fill(triangle(0.72, 0.82, 0.88, 0.79, 0.72, 0.79, s),
                           with: .color(Color(red: 0.66, green: 0.78, blue: 0.90)))
                for (cx, deg) in [(CGFloat(0.19), CGFloat(20.0)), (CGFloat(0.81), CGFloat(-20.0))] {
                    let flipper = Path(ellipseIn: r(cx, 0.66, 0.075, 0.13, s))
                    let rot = rotated(flipper, CGFloat(deg), p(cx, 0.66, s), s)
                    layer.fill(rot, with: .color(Color(red: 0.73, green: 0.82, blue: 0.93)))
                    layer.stroke(rot, with: .color(Color(red: 0.59, green: 0.71, blue: 0.84)), lineWidth: max(1, 0.012 * s))
                }
            }

            // 身体（上窄下宽的梨形，保留球的体积感）
            let body = Path { path in
                path.move(to: p(0.50, 0.14, s))
                path.addCurve(to: p(0.26, 0.50, s), control1: p(0.33, 0.14, s), control2: p(0.26, 0.30, s))
                path.addCurve(to: p(0.50, 0.86, s), control1: p(0.26, 0.72, s), control2: p(0.36, 0.86, s))
                path.addCurve(to: p(0.74, 0.50, s), control1: p(0.64, 0.86, s), control2: p(0.74, 0.72, s))
                path.addCurve(to: p(0.50, 0.14, s), control1: p(0.74, 0.30, s), control2: p(0.67, 0.14, s))
                path.closeSubpath()
            }
            layer.fill(body, with: .linearGradient(
                Gradient(colors: [Pal.sealTop, Pal.sealMid, Pal.sealBottom]),
                startPoint: p(0.25, 0.0, s), endPoint: p(0.75, 1.0, s)))
            layer.stroke(body, with: .color(Pal.sealLine), lineWidth: max(1, 0.016 * s))

            // 吻部
            if !simplify {
                layer.fill(Path(ellipseIn: r(0.50, 0.58, 0.18, 0.14, s)), with: .color(Pal.sealMuzzle.opacity(0.9)))
            }

            switch state {
            case .patting:
                eyes(&layer, s, 0.37, 0.63, 0.44, 0.06, 0.072, Pal.sealInk, closed: true)
                layer.fill(Path(ellipseIn: r(0.50, 0.50, 0.046, 0.034, s)), with: .color(Pal.sealLine))
                var smile = Path()
                smile.move(to: p(0.44, 0.56, s))
                smile.addQuadCurve(to: p(0.56, 0.56, s), control: p(0.50, 0.62, s))
                layer.stroke(smile, with: .color(Color(red: 1.00, green: 0.62, blue: 0.71)),
                             style: StrokeStyle(lineWidth: max(1, 0.02 * s), lineCap: .round))
            case .thinking:
                eyes(&layer, s, 0.37, 0.63, 0.43, 0.06, 0.072, Pal.sealInk, closed: blink)
                layer.fill(Path(ellipseIn: r(0.50, 0.50, 0.046, 0.034, s)), with: .color(Pal.sealLine))
                var mouth = Path()
                mouth.move(to: p(0.46, 0.58, s)); mouth.addLine(to: p(0.54, 0.58, s))
                layer.stroke(mouth, with: .color(Pal.sealLine), style: StrokeStyle(lineWidth: max(1, 0.014 * s), lineCap: .round))
            case .alert:
                eyes(&layer, s, 0.37, 0.63, 0.43, 0.068, 0.08, Pal.sealInk, closed: blink)
                layer.fill(Path(ellipseIn: r(0.50, 0.50, 0.046, 0.034, s)), with: .color(Pal.sealLine))
                layer.fill(Path(ellipseIn: r(0.50, 0.575, 0.028, 0.032, s)), with: .color(Pal.sealLine.opacity(0.85)))
            case .idle:
                eyes(&layer, s, 0.37, 0.63, 0.43, 0.06, 0.072, Pal.sealInk, closed: blink)
                layer.fill(Path(ellipseIn: r(0.50, 0.50, 0.046, 0.034, s)), with: .color(Pal.sealLine))
                var mouth = Path()
                mouth.move(to: p(0.50, 0.535, s)); mouth.addLine(to: p(0.50, 0.565, s))
                mouth.move(to: p(0.50, 0.565, s)); mouth.addQuadCurve(to: p(0.44, 0.555, s), control: p(0.472, 0.578, s))
                mouth.move(to: p(0.50, 0.565, s)); mouth.addQuadCurve(to: p(0.56, 0.555, s), control: p(0.528, 0.578, s))
                layer.stroke(mouth, with: .color(Pal.sealLine), style: StrokeStyle(lineWidth: max(1, 0.014 * s), lineCap: .round))
            }

            if !simplify {
                var whiskers = Path()
                whiskers.move(to: p(0.30, 0.56, s)); whiskers.addLine(to: p(0.19, 0.56, s))
                whiskers.move(to: p(0.30, 0.60, s)); whiskers.addLine(to: p(0.19, 0.60, s))
                whiskers.move(to: p(0.70, 0.56, s)); whiskers.addLine(to: p(0.81, 0.56, s))
                whiskers.move(to: p(0.70, 0.60, s)); whiskers.addLine(to: p(0.81, 0.60, s))
                layer.stroke(whiskers, with: .color(Pal.sealLine.opacity(0.85)),
                             style: StrokeStyle(lineWidth: max(1, 0.012 * s), lineCap: .round))
            }
        }

        if state == .patting {
            ctx.fill(sparkle(0.74, 0.20, 0.055, s), with: .color(Color(red: 0.50, green: 0.82, blue: 0.91)))
            ctx.fill(sparkle(0.26, 0.28, 0.038, s), with: .color(Color(red: 0.50, green: 0.82, blue: 0.91).opacity(0.85)))
        }
    }
}
