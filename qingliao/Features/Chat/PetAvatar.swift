import SwiftUI

// MARK: - v3.9.78 聊天页形象：卡通宠物（用户 2026-09-25 拍板）
//
// 背景：欢迎页原来立着 96pt 液态球（Metal 着色器版「液态智能球」，球本身即 logo；该渲染器已于 v3.9.78 删除）。
// 用户原话：「聊天页的大圆球能评估改成一个精致的卡通宠物，点击可以互动的那种，可以去网上找找方案」
// → 三份调研（scripts/ql_pet/：技术路线 / 素材授权 / 交互范式）+ 两版效果稿 → 拍板
//   **三种都要 + 设置里「外观 → 聊天页形象」三选一**。
//
// 口径（照调研结论，别自由发挥）：
//   · 技术：**原生 SwiftUI 矢量**（Canvas + Path），零 SPM 依赖、包体积增量 0、深浅色自适应
//     —— 唯一同时满足「零依赖 / 包体积敏感 / 与 iOS 26 液态玻璃契合」的路线（见 research_tech_routes.md）
//   · 交互：**单击 = 抚摸**（一次触感 + 一条 ≤1.2s 一次性反应，**不进任何功能页**）；
//     **长按仍是语音**（口径不变，由调用点持有手势）；待机只做呼吸 + 随机眨眼
//   · 状态：**冗余表达** —— 同样的信息必须在文案/角标层也能读到，关了动画不能丢状态
//   · 红线：不主动弹、不主动震、不出声、不做养成与惩罚、不阻塞输入
//   · 低功耗：设置「关闭」/ 系统「减弱动态效果」/ 非活跃场景（后台）→ 一律不动；
//     76pt 以下自动简化成「头 + 眼 + 嘴」（小了细节糊成一团）
//
// ⚠️ 球渲染器（原 `LiquidOrbAvatar.swift` + `LiquidOrbEffect.metal`）已按用户拍板**删除**：
//    欢迎页/消息头像这两个位置是本文件独占，删掉的 605 行 + 一个 76KB 着色器不再进包。
//    护栏「全仓无球渲染器残留引用」钉住不得复活（要回滚请从 git 历史取，别凭记忆重写）。

// ⚠️ 形象枚举（PetKeys / PetStyle / PetMotion / PetState）已抽到同目录 `PetModel.swift`：
//    实时活动挂件 target 也要画同一只形象（v3.9.79），挂件不带 AppStorage/View，所以模型单独一个文件。

// MARK: - 形象视图

struct PetAvatar: View {
    var size: CGFloat = 96
    var state: PetState = .idle
    /// 一次性抚摸反应触发器：宿主在「轻点」时自增即可（同一路径已由宿主自己发触感）
    var patTrigger: Int = 0
    /// 设置页预览用：不受用户当前选择影响（nil = 跟随用户选择）
    var styleOverride: PetStyle? = nil
    /// 设置页缩略图用：**按小尺寸直接画**但要保留完整细节（绕过 76pt 简化阈值）。
    /// ⚠️ 别再退回「以 96 画 + `.frame(52,52)` 显示」那套：frame 只改布局槽位、不缩放画面，
    /// 96pt 画布会从 52pt 槽位四周各溢出 22pt —— 形象压住卡片圆角边框和自家名字（v3.9.78 真机报修）。
    var keepDetail: Bool = false

    @AppStorage(PetKeys.style) private var storedStyle: PetStyle = .liquid
    @AppStorage(PetKeys.motion) private var motionSetting: PetMotion = .system
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var breath = false
    @State private var blink = false
    @State private var patting = false
    // v3.9.85：灵动微动作——idle 时每隔一段时间随机来一下，让宠物「像活的」。
    // 全部走 SwiftUI 层变换（rotate/offset），不触发 Canvas 重绘，成本与呼吸同级。
    @State private var quirky: Quirk = .none

    /// 一次性微动作（形变 + 时长）
    private enum Quirk: Equatable {
        case none
        case headTilt      // 歪头好奇
        case lookAround    // 左右张望
        case happyWiggle   // 开心扭动
        case stretch       // 伸懒腰（拉长一下）
        // v4.0.0（用户：「增加走动搞怪动画让它活起来」）：真·位移，不是原地形变。
        // v3.9.85 那四个动作全在原地（rotate/scale/offset 幅度都是 0.0x×size），
        // 观感上仍是「贴着原地晃」→ 补两个踱步动作：横向挪 + 朝向翻转 + 上下颠步。
        case strollLeft
        case strollRight

        var duration: TimeInterval {
            switch self {
            case .none: return 0
            case .headTilt: return 1.4
            case .lookAround: return 1.6
            case .happyWiggle: return 0.9
            case .stretch: return 1.5
            case .strollLeft, .strollRight: return 2.2
            }
        }
        static let pool: [Quirk] = [.headTilt, .lookAround, .happyWiggle, .stretch,
                                    .strollLeft, .strollRight]

        /// 是否是「走动」类：需要按行进方向镜像朝向
        var isStroll: Bool { self == .strollLeft || self == .strollRight }
    }

    private var style: PetStyle { styleOverride ?? storedStyle }

    /// 是否允许动：设置「关闭」否；「减弱」+ 系统或设置任一要求减弱否；后台否
    private var motionAllowed: Bool {
        switch motionSetting {
        case .off: return false
        case .reduced: return false
        case .system: return !systemReduceMotion
        }
    }

    private var animate: Bool { motionAllowed && scenePhase == .active }

    /// 有效状态：抚摸反应优先（一次性），其次传入的状态
    private var effectiveState: PetState { patting ? .patting : state }

    // v3.9.85：微动作 → 三轴变换值（idle 才生效，thinking/alert 保持稳重）
    private var quirkyActive: Bool { animate && state == .idle && !patting && quirky != .none }
    private var quirkyScale: CGFloat {
        guard quirkyActive else { return 1.0 }
        switch quirky {
        case .stretch: return 1.04
        case .happyWiggle: return 1.02
        default: return 1.0
        }
    }
    private var quirkyAngle: CGFloat {
        guard quirkyActive else { return 0 }
        switch quirky {
        case .headTilt: return 6
        case .lookAround: return -3
        // 踱步时的前倾（走路重心前移的身体感），左右一致 → 用同一个正角度
        case .strollLeft, .strollRight: return 2.5
        default: return 0
        }
    }
    private var quirkyShift: CGFloat {
        guard quirkyActive else { return 0 }
        switch quirky {
        case .lookAround: return size * 0.03
        case .happyWiggle: return size * 0.015
        // 走动位移：14pt（≈96pt 形象的 15%），落在宿主 96×96 框外的欢迎页空白区，不压文字
        case .strollLeft: return -size * 0.145
        case .strollRight: return size * 0.145
        default: return 0
        }
    }
    /// 踱步的行进方向：0 = 正向，1 = 水平镜像（scaleEffect(x: -1)）
    /// ⚠️ 只镜像 Canvas 层的位移与朝向，**不影响 overlay 的角标/思考点**（那些挂在本层之外）。
    private var quirkyMirror: CGFloat { quirkyActive && quirky == .strollLeft ? -1.0 : 1.0 }
    /// 踱步时的上下颠步（每步一点，锚点在底部 = 脚不离地）
    private var quirkyBob: CGFloat {
        guard quirkyActive, quirky.isStroll else { return 0 }
        return strollPhase ? -size * 0.03 : 0
    }
    /// 颠步相位：独立 @State，由 strollLoop 定时翻转（与 quirky 的进出是两段时间轴）
    @State private var strollPhase = false

    private var simplify: Bool { keepDetail ? false : size < PetKeys.simplifyBelow }

    var body: some View {
        let drawSize = size
        Canvas { context, canvasSize in
            PetPainter(style: style,
                       state: effectiveState,
                       blink: blink && animate,
                       simplify: simplify)
                .draw(&context, size: canvasSize)
        }
        .frame(width: drawSize, height: drawSize)
        // v4.0.0：走动 = 真位移。层级：Canvas → 镜像 → 呼吸缩放 → 形变缩放 → 旋转 → 位移 + 颠步。
        //   锚点统一 .bottom：位移与颠步都从「脚」出发，不出现整体漂浮。
        //   ⚠️ 镜像与位移的**先后顺序对结果没有影响**（外层 offset 在未镜像的父空间里做，
        //     不会被内层 scaleEffect 镜像）—— 真正要守住的是**两者的方向配对**：
        //     strollLeft 必须 shift<0 且 mirror<0（朝左走、朝左看），strollRight 反之。
        //     配对错了才是「横着滑」（朝右走却朝左看）。该约束由 ql_pet 真值表逐档钉住。
        .scaleEffect(x: quirkyMirror, y: 1, anchor: .bottom)
        // 呼吸：整层缩放（不触发 Canvas 重绘，最省）——「减弱/关闭」时恒为 1
        .scaleEffect(breath && animate ? 1.02 : 1.0)
        // 微动作形变层（同呼吸，纯变换不重绘；锚点在底部 = 从「脚」上长出来）
        .scaleEffect(quirkyScale, anchor: .bottom)
        .rotationEffect(.degrees(quirkyAngle), anchor: .bottom)
        .offset(x: quirkyShift, y: quirkyBob)
        // 思考中的三点气泡 / 新消息角标：SwiftUI 覆盖层（自带动画，不重绘 Canvas）
        .overlay(alignment: .topTrailing) { decoration }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if animate { startBreath() } }
        .onChange(of: animate) { _, now in
            if now {
                startBreath()
            } else {
                // v4.0.0：不动时必须把姿态复位，否则切后台/被系统挂起时正卡在「抬起」，
                // 回前台会看到宠物僵在半抬状态；同时 quirky 也清零（无动画包裹 = 立即归位）。
                strollPhase = false
                quirky = .none
                withAnimation(nil) { breath = false }
            }
        }
        .task(id: animate) { await blinkLoop() }
        .task(id: animate) { await quirkyLoop() }   // v3.9.85：灵动微动作
        .onChange(of: patTrigger) { _, _ in playPat() }
    }

    private func startBreath() {
        breath = false
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breath = true }
    }

    /// 眨眼：3~7s 随机一次、每次 0.12s —— 制造「活着」的错觉，几乎零成本
    private func blinkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 3...7)))
            guard animate, !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.06)) { blink = true }
            try? await Task.sleep(for: .seconds(0.12))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.10)) { blink = false }
        }
    }

    private func playPat() {
        patting = true
        Task {
            try? await Task.sleep(for: .seconds(1.1))
            patting = false
        }
    }

    /// v3.9.85：微动作循环——8~16s 随机播一个，每个动作「出去 + 回来」两段动画
    private func quirkyLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 6...14)))
            guard animate, !Task.isCancelled, state == .idle, !patting else { continue }
            let q = Quirk.pool.randomElement() ?? .headTilt
            let d = q.duration
            if q.isStroll {
                await playStroll(q, duration: d)
            } else {
                withAnimation(.easeInOut(duration: d * 0.4)) { quirky = q }
                try? await Task.sleep(for: .seconds(d * 0.6))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: d * 0.4)) { quirky = .none }
            }
        }
    }

    /// v4.0.0 踱步：真实位移的完整编排（四段）
    ///   ① 迈出去（easeInOut，位移到 0.145×size，同步镜像朝向）
    ///   ② 途中颠步 2 次（每步 duration/4，起脚一次落一次）
    ///   ③ 站定顿一下（0.35×duration，活着但没走）
    ///   ④ 走回原位（镜像必须先回正向，否则回程是「倒着滑」）
    private func playStroll(_ q: Quirk, duration d: TimeInterval) async {
        withAnimation(.easeInOut(duration: d * 0.3)) { quirky = q }
        // 颠步：纵向起伏由 quirkyBob 承担（strollPhase 翻转），横向位移保持不变
        for _ in 0..<2 {
            try? await Task.sleep(for: .seconds(d * 0.2))
            guard animate, !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: d * 0.1)) { strollPhase = true }
            try? await Task.sleep(for: .seconds(d * 0.1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: d * 0.1)) { strollPhase = false }
        }
        // 站定顿一下：憋一下再走，像真的停下来看了一眼
        try? await Task.sleep(for: .seconds(d * 0.35))
        guard animate, !Task.isCancelled else { return }
        strollPhase = false
        withAnimation(.easeInOut(duration: d * 0.3)) { quirky = .none }
    }

    @ViewBuilder
    private var decoration: some View {
        switch effectiveState {
        case .thinking where !simplify:
            ThinkingDots(size: size, animated: animate)
                .offset(x: size * 0.02, y: -size * 0.04)
        case .alert where !simplify:
            Circle()
                .fill(Color(red: 1.0, green: 0.23, blue: 0.19))
                .overlay(Circle().strokeBorder(.white, lineWidth: max(1, size * 0.02)))
                .frame(width: size * 0.16, height: size * 0.16)
                .offset(x: -size * 0.02, y: size * 0.02)
        default:
            EmptyView()
        }
    }
}

/// 思考中的三点气泡（状态冗余表达之一；文案层另有「正在输入」）
private struct ThinkingDots: View {
    let size: CGFloat
    let animated: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: size * 0.03) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(uiColor: .secondaryLabel))
                    .frame(width: size * 0.03, height: size * 0.03)
                    .opacity(pulse ? 1.0 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.18), value: pulse)
            }
        }
        .padding(.horizontal, size * 0.05)
        .padding(.vertical, size * 0.035)
        .background(
            RoundedRectangle(cornerRadius: size * 0.10, style: .continuous)
                .fill(.white.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onAppear { if animated { pulse = true } }
    }
}
