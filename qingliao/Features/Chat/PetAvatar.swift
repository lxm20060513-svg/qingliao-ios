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
        // 呼吸：整层缩放（不触发 Canvas 重绘，最省）——「减弱/关闭」时恒为 1
        .scaleEffect(breath && animate ? 1.02 : 1.0)
        // 思考中的三点气泡 / 新消息角标：SwiftUI 覆盖层（自带动画，不重绘 Canvas）
        .overlay(alignment: .topTrailing) { decoration }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if animate { startBreath() } }
        .onChange(of: animate) { _, now in
            if now { startBreath() } else { withAnimation(nil) { breath = false } }
        }
        .task(id: animate) { await blinkLoop() }
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
