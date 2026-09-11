import SwiftUI

// MARK: - 粒子结构
struct OrbDot {
    var x, y, z, r, white, alpha: CGFloat
}

struct OrbFrame {
    var dots: [OrbDot]
}

// MARK: - 预设参数
struct OrbOpts {
    // orbits (working)
    var orbitN: Int = 12
    var ghostN: Int = 40
    var ghostR: CGFloat = 0.9
    var ghostA: CGFloat = 0.5
    var particles: Int = 3
    var partR: CGFloat = 1.2
    var partRDepth: CGFloat = 1.6
    // ring (breathing)
    var lanes: Int = 5
    var segs: Int = 88
    var faceOn: CGFloat = 1
    var rBase: CGFloat = 1.1
    var rDepth: CGFloat = 1.7
    var wobMul: CGFloat = 0.368
    var bandMul: CGFloat = 3.627
    var spin: CGFloat = 0
    // common
    var rsPow: CGFloat = 0.6
    var rMin: CGFloat = 0.3
}

// MARK: - 核心数学

typealias Projector = (CGFloat, CGFloat, CGFloat) -> (CGFloat, CGFloat, CGFloat)

func hashD(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
    let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
    return h - floor(h)
}

func makeProj(yaw: CGFloat, tilt: CGFloat, cx: CGFloat, cy: CGFloat, scale: CGFloat) -> Projector {
    let st = sin(tilt), ct = cos(tilt)
    let sy = sin(yaw), cyw = cos(yaw)
    return { x, y, z in
        let x1 = x * cyw + z * sy
        let z1 = -x * sy + z * cyw
        let y1 = y * ct - z1 * st
        let z2 = y * st + z1 * ct
        return (cx + x1 * scale, cy - y1 * scale, z2)
    }
}

func radiusScale(_ size: CGFloat, _ power: CGFloat) -> CGFloat {
    return pow(size / 300, power)
}

func fibDir(_ i: Int, _ n: Int) -> (CGFloat, CGFloat, CGFloat) {
    let golden = CGFloat.pi * (3 - sqrt(5))
    let y = 1 - (2 * (CGFloat(i) + 0.5)) / CGFloat(n)
    let rad = sqrt(1 - y * y)
    let a = CGFloat(i) * golden
    return (rad * cos(a), y, rad * sin(a))
}

func finalizeFrame(dots: [OrbDot], rMin: CGFloat) -> OrbFrame {
    var visible = dots.filter { $0.alpha >= 0.02 }
    for i in visible.indices { visible[i].r = max(rMin, visible[i].r) }
    visible.sort { $0.z < $1.z }
    return OrbFrame(dots: visible)
}

// MARK: - Orbits（working — 点点在倾斜轨道上旋转）

func frameOrbits(size: CGFloat, t: CGFloat, opts: OrbOpts) -> OrbFrame {
    let cx = size / 2, cy = size / 2, R = (size / 2) * 0.82
    let pt = makeProj(yaw: t * 0.12, tilt: 0.3, cx: cx, cy: cy, scale: 1)
    let rs = radiusScale(size, opts.rsPow)
    var dots: [OrbDot] = []
    for orb in 0..<opts.orbitN {
        let h1 = hashD(CGFloat(orb), 1.7), h2 = hashD(CGFloat(orb), 5.2), h3 = hashD(CGFloat(orb), 8.9)
        let ro = R * (0.45 + 0.52 * h1), th = h1 * 2 * .pi, phi = acos(2 * h2 - 1)
        let nx = sin(phi) * cos(th), ny = cos(phi), nz = sin(phi) * sin(th)
        var ux = -ny, uy = nx; let uz: CGFloat = 0
        let ul = max(1e-6, sqrt(ux * ux + uy * uy)); ux /= ul; uy /= ul
        let vx = ny * uz - nz * uy, vy = nz * ux - nx * uz, vz = nx * uy - ny * ux
        let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)
        for k in 0..<opts.ghostN {
            let a = (CGFloat(k) / CGFloat(opts.ghostN)) * 2 * .pi
            let (px, py, z) = pt(
                (ux * cos(a) + vx * sin(a)) * ro,
                (uy * cos(a) + vy * sin(a)) * ro,
                (uz * cos(a) + vz * sin(a)) * ro)
            let depth = (z / ro + 1) / 2
            dots.append(OrbDot(x: px, y: py, z: z, r: opts.ghostR * rs, white: 0.72, alpha: opts.ghostA * (0.4 + 0.6 * depth)))
        }
        for m in 0..<opts.particles {
            let a = t * speed + (CGFloat(m) / CGFloat(opts.particles)) * 2 * .pi + h2 * 6
            let (px, py, z) = pt(
                (ux * cos(a) + vx * sin(a)) * ro,
                (uy * cos(a) + vy * sin(a)) * ro,
                (uz * cos(a) + vz * sin(a)) * ro)
            let depth = (z / ro + 1) / 2
            dots.append(OrbDot(x: px, y: py, z: z, r: (opts.partR + opts.partRDepth * depth) * rs, white: 0.3 - 0.22 * depth, alpha: 0.85))
        }
    }
    return finalizeFrame(dots: dots, rMin: opts.rMin)
}

// MARK: - Ring（breathing — 正面圆环缓慢脉动）

func frameRing(size: CGFloat, t: CGFloat, opts: OrbOpts) -> OrbFrame {
    let cx = size / 2, cy = size / 2, R = (size / 2) * 0.78
    let pt = makeProj(yaw: 0, tilt: 0.3, cx: cx, cy: cy, scale: 1)
    let rs = radiusScale(size, opts.rsPow)
    var dots: [OrbDot] = []
    // 背景幽灵球
    for i in 0..<opts.ghostN {
        let d = fibDir(i, opts.ghostN)
        let (px, py, z) = pt(d.0 * R, d.1 * R, d.2 * R)
        let depth = (z / R + 1) / 2
        dots.append(OrbDot(x: px, y: py, z: z, r: 0.8 * rs, white: 0.78, alpha: 0.1 + 0.22 * depth))
    }
    // 正面圆环
    let wobAmp: CGFloat = 0.23 * opts.wobMul
    let baseR = R / (1 + 0.85 * wobAmp)
    let lanes = max(1, Int(round(CGFloat(opts.lanes) * opts.bandMul)))
    for w in 0..<lanes {
        let laneOff = (CGFloat(w) - CGFloat(lanes - 1) / 2) * 0.075
        let edge = abs(CGFloat(w) - CGFloat(lanes - 1) / 2) / max(1, CGFloat(lanes - 1) / 2)
        for k in 0..<opts.segs {
            let a = (CGFloat(k) / CGFloat(opts.segs)) * 2 * .pi
            let wob = (0.16 * sin(a * 3 - t * 1.7 + CGFloat(w) * 0.22) + 0.07 * sin(a * 5 + t * 1.1)) * opts.wobMul
            let radial: CGFloat = 1 + wob
            let x = cos(a) + 0 * laneOff  // faceOn: 平面圆环，法线方向不偏移
            let y = sin(a) + 0 * laneOff
            let z: CGFloat = 0
            let l = sqrt(x * x + y * y + z * z)
            let rr = baseR * radial
            let (px, py, zr) = pt((x / l) * rr, (y / l) * rr, (z / l) * rr)
            let depth = (zr / R + 1) / 2
            dots.append(OrbDot(
                x: px, y: py, z: zr,
                r: (opts.rBase + opts.rDepth * depth) * (1 - 0.25 * edge) * rs,
                white: 0.52 - 0.44 * depth + 0.18 * edge,
                alpha: 0.4 + 0.6 * depth))
        }
    }
    return finalizeFrame(dots: dots, rMin: opts.rMin)
}

// MARK: - VoiceWave（语音输入中 — 从球心向外扩散的声波涟漪，一眼区分"正在录音"）

func frameVoiceWave(size: CGFloat, t: CGFloat, opts: OrbOpts) -> OrbFrame {
    let cx = size / 2, cy = size / 2
    let R = (size / 2) * 0.92
    let rs = radiusScale(size, opts.rsPow)
    var dots: [OrbDot] = []
    let rings = 6
    let segs = opts.segs
    // 多圈声波涟漪，半径随相位扩散，越外越淡；中心一颗亮核
    for r in 0..<rings {
        let phase = (t * 0.35) + CGFloat(r) / CGFloat(rings)
        let prog = phase - floor(phase)   // 0..1 扩散进度
        let rad = R * prog
        let baseAlpha = (1 - prog) * 0.85
        for k in 0..<segs {
            let a = (CGFloat(k) / CGFloat(segs)) * 2 * .pi
            let x = cx + cos(a) * rad
            let y = cy + sin(a) * rad
            dots.append(OrbDot(
                x: x, y: y, z: 0,
                r: (1.4 + 0.6 * (1 - prog)) * rs,
                white: 0.6, alpha: baseAlpha))
        }
    }
    dots.append(OrbDot(x: cx, y: cy, z: 0, r: 2.2 * rs, white: 0.9, alpha: 0.9))
    return finalizeFrame(dots: dots, rMin: opts.rMin)
}

// MARK: - 渲染

enum OrbMode { case orbits, ring, voiceWave }

func renderOrb(size: CGFloat, time: CGFloat, mode: OrbMode, dark: Bool, opts: OrbOpts) -> OrbFrame {
    switch mode {
    case .orbits:    return frameOrbits(size: size, t: time, opts: opts)
    case .ring:      return frameRing(size: size, t: time, opts: opts)
    case .voiceWave: return frameVoiceWave(size: size, t: time, opts: opts)
    }
}

// MARK: - SwiftUI 组件

struct OrbCanvasView: View {
    let mode: OrbMode
    let size: CGFloat
    // v3.0.16：可传定制粒子参数（小尺寸场景默认参数粒子过小≈0.2pt 不可见，如 30pt 头像）
    var opts: OrbOpts = OrbOpts()
    // v3.0.17：可传彩色粒子（按 dot 索引循环取色、保留深度 alpha；nil = 默认灰白按深浅色适配）
    var dotColors: [Color]? = nil
    /// v3.9.1：帧率可调——原来写死 30fps，导致 dock 空闲传 fps:15 只省了外层光晕，最贵的 Canvas 层仍 30fps
    var fps: Double = 30
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let schedule: AnimationTimelineSchedule = .animation(minimumInterval: 1.0 / fps)
        TimelineView(schedule) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let speed: CGFloat = mode == .orbits ? 1.885 : 3.24
            let colors = dotColors
            Canvas { gfx, sz in
                let frame = renderOrb(size: size, time: t * speed, mode: mode, dark: colorScheme == .dark, opts: opts)
                for (i, dot) in frame.dots.enumerated() {
                    let alpha = min(1, max(0, dot.alpha))
                    let c: Color
                    if let colors, !colors.isEmpty {
                        c = colors[i % colors.count].opacity(Double(alpha))
                    } else {
                        let gray = colorScheme == .dark ? (1 - dot.white) : dot.white
                        c = Color(white: Double(gray), opacity: Double(alpha))
                    }
                    let rect = CGRect(x: dot.x - dot.r, y: dot.y - dot.r, width: dot.r * 2, height: dot.r * 2)
                    gfx.fill(Path(ellipseIn: rect), with: .color(c))
                }
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - 预设（64px 版本）

extension OrbOpts {
    static let orbits64 = OrbOpts(
        orbitN: 12, ghostN: 40, ghostR: 0.9, ghostA: 0.5,
        particles: 3, partR: 1.2, partRDepth: 1.6,
        rsPow: 0.6, rMin: 0.3
    )
    static let ring64 = OrbOpts(
        ghostN: 150, lanes: 5, segs: 88, faceOn: 1,
        rBase: 1.1, rDepth: 1.7, wobMul: 0.368, bandMul: 3.627, spin: 0,
        rsPow: 0.6, rMin: 0.3
    )
}