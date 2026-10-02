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
    /// v4.0.27：宿主「AI 刚回答完」信号 —— 每 +1 播一次**庆祝动作**（与 patTrigger 的抚摸态区分：
    /// 抚摸是被点，这个是回应「我答完了」）。走同一套 quirk 动作池，喜庆向动作优先。
    var celebrateTrigger: Int = 0
    /// 设置页预览用：不受用户当前选择影响（nil = 跟随用户选择）
    var styleOverride: PetStyle? = nil
    /// v4.0.6：表情缩略图用（每张脸要单独画出选中的那一张，故不能只跟随全局选择）
    var faceOverride: PetFace? = nil
    /// 设置页缩略图用：**按小尺寸直接画**但要保留完整细节（绕过 76pt 简化阈值）。
    /// ⚠️ 别再退回「以 96 画 + `.frame(52,52)` 显示」那套：frame 只改布局槽位、不缩放画面，
    /// 96pt 画布会从 52pt 槽位四周各溢出 22pt —— 形象压住卡片圆角边框和自家名字（v3.9.78 真机报修）。
    var keepDetail: Bool = false

    @AppStorage(PetKeys.style) private var storedStyle: PetStyle = .liquid
    @AppStorage(PetKeys.motion) private var motionSetting: PetMotion = .system
    // v4.0.6：常态表情（只影响 idle 态的脸；thinking/alert 仍走宿主信号，见 PetModel 口径）
    @AppStorage(PetKeys.face) private var storedFace: PetFace = .calm
    // v4.0.6：行为动作勾选集（逗号分隔串；缺失 key = 全开，见 PetKeys.enabledQuirks）
    @AppStorage(PetKeys.quirks) private var quirksRaw: String = ""
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var breath = false
    @State private var blink = false
    @State private var patting = false
    // v3.9.85：灵动微动作——idle 时每隔一段时间随机来一下，让宠物「像活的」。
    // 全部走 SwiftUI 层变换（rotate/offset），不触发 Canvas 重绘，成本与呼吸同级。
    // v4.0.6：Quirk 已从本文件 private 提到 PetModel.swift（设置页要给它做多选，
    // 文件级 private 跨文件不可见 —— 当年 MiniCapsule 就栽在这条上）。
    // 用 Optional 表达「不在动作中」：模型里那个 .none 是给设置页枚举用的哨兵，不该混进来。
    @State private var quirky: Quirk? = nil
    /// v4.0.26：当前手部姿势。由动作编排逐段写入（可被 withAnimation 插值 → 手连贯摆动）。
    /// 与 `quirky` 同生命周期：动作结束回 `.rest`（贴身），不动时恒为 `.rest`。
    @State private var quirkyHands: PetHandPose = .rest

    /// 当前勾选的动作集合。⚠️ 本组件用 @AppStorage 拿到的是**非 optional String**，
    /// 「没设过」与「设成空串」在这里长得一样 —— 两种语义在 PetKeys.enabledQuirks 里
    /// 靠 UserDefaults.string(forKey:) 分开；这里只有在 key 真正缺失时才回全开。
    private var enabledQuirks: Set<Quirk> {
        UserDefaults.standard.string(forKey: PetKeys.quirks) == nil
            ? Set(Quirk.pool) : PetKeys.enabledQuirks()
    }

    private var style: PetStyle { styleOverride ?? storedStyle }
    /// v4.0.6：表情缩略图走 override，其余走用户选择
    private var face: PetFace { faceOverride ?? storedFace }
    /// v4.0.6：动作预览时手动播一个（不参与随机循环；预览用 state=.idle）
    ///
    /// ⚠️ 刻意**不加 private**：加了会让本 struct 的 memberwise init 变私有，
    /// 7 个跨文件调用点（PetStudioSheet / SettingsCore / OrbQuickMenu / ChatView /
    /// ChatMessageBubble）全部编译红。memberwise init 的实参序 = 属性声明序，
    /// **新增存储属性时必须排在本行之后**，并同步核对全部调用点传参序。
    var quirkPreview: Quirk? = nil

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
    // v4.0.6：quirky 改成 Optional（Quirk 模型里没有 .none），所以这里统一走
    // `current` 这个「已归一化」的值：不在动作中 → nil，switch 落到 default 全 0。
    private var quirkyActive: Bool { animate && state == .idle && !patting && quirky != nil }
    /// v4.0.6：设置页动作预览走 `quirkPreview`（手动定格，不看动画档），
    /// 聊天页走随机循环的 `quirky`。
    private var current: Quirk? { quirkPreview ?? (quirkyActive ? quirky : nil) }

    /// v4.0.26：当前手部姿势。
    /// · 设置页预览/缩略图（quirkPreview 非空）→ 定格该动作的「代表姿势」
    /// · 聊天页播放中 → quirkyHands（编排逐段写入）
    /// · 其余（idle/thinking/不动）→ 贴身静止
    private var currentHandPose: PetHandPose {
        if let q = quirkPreview { return Self.representativePose(q) }
        return quirkyActive || !quirkyHands.magnitudeSquared.isZero ? quirkyHands : .rest
    }

    /// 各动作的「代表姿势」：设置页缩略图 / 预览定格用。
    /// ⚠️ 与聊天页编排里的关键帧**同一套姿势值**（改一处要同步改 `playHandAction`），
    ///    否则缩略图与真机播放对不上。
    static func representativePose(_ q: Quirk) -> PetHandPose {
        switch q {
        case .waveHello:
            return PetHandPose(left: PetHandSide(),
                               right: PetHandSide(lift: 0.65, fold: 0, spread: 0.55, swing: 18))
        case .clap:       return .both(lift: 0.20, fold: 0.85)
        case .heartHands: return .both(lift: 0.28, fold: 0.95)
        case .cheer:      return .both(lift: 0.85, fold: 0, spread: 0.80)
        case .chinRest:
            return PetHandPose(left: PetHandSide(),
                               right: PetHandSide(lift: 0.20, fold: 0.35, spread: -0.10, swing: -20))
        default:          return .rest
        }
    }
    private var quirkyScale: CGFloat {
        switch current {
        case .some(.stretch): return 1.04
        case .some(.happyWiggle): return 1.02
        // v4.0.26：欢呼时身体也跟着「拔」一下（配合双手高举）
        case .some(.cheer): return 1.06
        default: return 1.0
        }
    }
    private var quirkyAngle: CGFloat {
        switch current {
        case .some(.headTilt): return 6
        case .some(.lookAround): return -3
        // 踱步时的前倾（走路重心前移的身体感），左右一致 → 用同一个正角度
        case .some(.strollLeft), .some(.strollRight): return 2.5
        // v4.0.26：托腮时头微微偏一下（手扶着才像在发呆）
        case .some(.chinRest): return 5
        default: return 0
        }
    }
    private var quirkyShift: CGFloat {
        switch current {
        case .some(.lookAround): return size * 0.03
        case .some(.happyWiggle): return size * 0.015
        // 走动位移：14pt（≈96pt 形象的 15%），落在宿主 96×96 框外的欢迎页空白区，不压文字
        case .some(.strollLeft): return -size * 0.145
        case .some(.strollRight): return size * 0.145
        default: return 0
        }
    }
    /// 踱步的行进方向：0 = 正向，1 = 水平镜像（scaleEffect(x: -1)）
    /// ⚠️ 只镜像 Canvas 层的位移与朝向，**不影响 overlay 的角标/思考点**（那些挂在本层之外）。
    private var quirkyMirror: CGFloat { current == .strollLeft ? -1.0 : 1.0 }
    /// 踱步时的上下颠步（每步一点，锚点在底部 = 脚不离地）
    /// v4.0.26：欢呼复用同一条相位（蹦得更高一点）——手举起来时身体不能钉在地上。
    private var quirkyBob: CGFloat {
        guard let q = current else { return 0 }
        if q == .cheer { return strollPhase ? -size * 0.06 : 0 }
        guard q.isStroll else { return 0 }
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
                       face: face,
                       blink: blink && animate,
                       simplify: simplify,
                       handPose: currentHandPose)
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
                quirky = nil
                // v4.0.26：手部姿势也一并归位（否则切后台时正卡在「手抬起」→ 回前台悬在半空）
                quirkyHands = .rest
                withAnimation(nil) { breath = false }
            }
        }
        .task(id: animate) { await blinkLoop() }
        // v4.0.6：task id 里带上勾选串 —— 用户在设置页改了勾选，这一层必须重挂一次，
        // 否则循环还拿着旧池子，新勾的动作要等下次进聊天页才生效。
        .task(id: "\(animate)-\(quirksRaw)") { await quirkyLoop() }   // v3.9.85：灵动微动作
        .onChange(of: patTrigger) { _, _ in playPat() }
        // v4.0.27：AI 回答完成 → 播一次庆祝动作（header 中央宠物用）
        .onChange(of: celebrateTrigger) { _, _ in playCelebrate() }
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

    /// v4.0.27：庆祝动作 —— 「AI 刚回答完」时播一次，庆祝味优先。
    /// 与 quirkyLoop 的区别：那个是 6~14s 的空闲自娱（受 state == .idle 门控、且不抢手头动作），
    /// 这个由宿主明确触发，不看 state（回答完那一刻 state 刚从 .thinking 落回 .idle，
    /// 用 state 门控反而可能因时序差漏播）。
    ///
    /// 动作池 = 用户勾选的那几个；**喜庆向优先**（欢呼/比心/鼓掌/挥手）再随机 ——
    /// 固定取第一个会每次都播同一个，失去「不同动作」的观感。
    /// 用户一个都没勾时退回抚摸态：至少动一下，不能像个静止图标。
    private func playCelebrate() {
        guard animate else { return }
        let pool = Quirk.pool.filter { enabledQuirks.contains($0) }
        let festive = [Quirk.cheer, .heart, .clap, .wave].filter { pool.contains($0) }
        guard let q = festive.randomElement() ?? pool.randomElement() else {
            playPat()
            return
        }
        Task {
            let d = q.duration
            if q.isHandAction {
                withAnimation(.easeInOut(duration: d * 0.2)) { quirky = q }
                await playHandAction(q)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: d * 0.2)) { quirky = nil }
            } else {
                withAnimation(.easeInOut(duration: d * 0.4)) { quirky = q }
                try? await Task.sleep(for: .seconds(d * 0.6))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: d * 0.4)) { quirky = nil }
            }
        }
    }

    /// v3.9.85：微动作循环——8~16s 随机播一个，每个动作「出去 + 回来」两段动画
    /// v4.0.6：池子 = 用户勾选的那几个（enabledQuirks）；全关时**彻底不播**（不是硬塞一个默认动作）。
    private func quirkyLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 6...14)))
            guard animate, !Task.isCancelled, state == .idle, !patting else { continue }
            // ⚠️ 每轮重算：勾选可能在本轮等待期间被改（设置页或 task id 重挂都会走到这）
            let pool = Quirk.pool.filter { enabledQuirks.contains($0) }
            guard let q = pool.randomElement() else { continue }
            let d = q.duration
            if q.isStroll {
                await playStroll(q, duration: d)
            } else if q.isHandAction {
                // v4.0.26：用手表达的动作 —— 身体层只设 quirky（供 scale/bob/angle 配合），
                // 主要看点在两只手上，交给 playHandAction 逐段编排姿势。
                withAnimation(.easeInOut(duration: d * 0.2)) { quirky = q }
                await playHandAction(q)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: d * 0.2)) { quirky = nil }
            } else {
                withAnimation(.easeInOut(duration: d * 0.4)) { quirky = q }
                try? await Task.sleep(for: .seconds(d * 0.6))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: d * 0.4)) { quirky = nil }
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
        withAnimation(.easeInOut(duration: d * 0.3)) { quirky = nil }
    }

    // MARK: v4.0.26 手部动作编排
    //
    // 每个动作 = 一段「抬起来 → 做动作 → 放下」的姿势时间线，逐段 withAnimation 写入
    // `quirkyHands`。PetHandPose 已 conform `VectorArithmetic` → SwiftUI 在段间逐帧插值，
    // 所以手是连贯摆动而不是瞬移。
    // ⚠️ 每段之后必须 `guard animate, !Task.isCancelled else { return }`：动作播到一半被关掉
    //    动画（切后台、用户关开关、宿主重挂）时要立刻退出，否则手会僵在半空。
    // ⚠️ 关键帧姿势值要与 `representativePose` 对齐，否则设置页缩略图与真机播放对不上。
    private func playHandAction(_ q: Quirk) async {
        switch q {
        case .waveHello:  await playWave()
        case .clap:       await playClap()
        case .heartHands: await playHeartHands()
        case .cheer:      await playCheer()
        case .chinRest:   await playChinRest()
        default:          break
        }
    }

    /// 挥手：抬起 → 左右摆 3 次 → 放下
    private func playWave() async {
        let target = Self.representativePose(.waveHello)
        withAnimation(.easeInOut(duration: 0.28)) { quirkyHands = target }
        try? await Task.sleep(for: .seconds(0.30))
        for angle in [CGFloat(-18), 18, -18] {
            guard animate, !Task.isCancelled else { return }
            var p = target
            p.right.swing = angle
            withAnimation(.easeInOut(duration: 0.20)) { quirkyHands = p }
            try? await Task.sleep(for: .seconds(0.22))
        }
        guard animate, !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.26)) { quirkyHands = .rest }
        try? await Task.sleep(for: .seconds(0.30))
    }

    /// 鼓掌：两手合到胸前 → 拍 3 下（合更拢再分开）→ 放下
    private func playClap() async {
        withAnimation(.easeInOut(duration: 0.24)) { quirkyHands = Self.representativePose(.clap) }
        try? await Task.sleep(for: .seconds(0.26))
        for _ in 0..<3 {
            guard animate, !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.09)) { quirkyHands = .both(lift: 0.20, fold: 1.0) }
            try? await Task.sleep(for: .seconds(0.11))
            guard animate, !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.09)) { quirkyHands = .both(lift: 0.20, fold: 0.72) }
            try? await Task.sleep(for: .seconds(0.13))
        }
        guard animate, !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.24)) { quirkyHands = .rest }
        try? await Task.sleep(for: .seconds(0.28))
    }

    /// 比心：两手合到胸前 → 停住（再往前推一点点）→ 放下
    private func playHeartHands() async {
        withAnimation(.easeInOut(duration: 0.34)) { quirkyHands = Self.representativePose(.heartHands) }
        try? await Task.sleep(for: .seconds(0.40))
        guard animate, !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.22)) { quirkyHands = .both(lift: 0.26, fold: 0.98) }
        try? await Task.sleep(for: .seconds(1.0))
        guard animate, !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.32)) { quirkyHands = .rest }
        try? await Task.sleep(for: .seconds(0.36))
    }

    /// 欢呼：双手高举 + 蹦两下 → 放下
    private func playCheer() async {
        withAnimation(.easeInOut(duration: 0.26)) { quirkyHands = Self.representativePose(.cheer) }
        try? await Task.sleep(for: .seconds(0.24))
        for on in [true, false, true, false] {
            guard animate, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.11)) { strollPhase = on }
            try? await Task.sleep(for: .seconds(0.13))
        }
        guard animate, !Task.isCancelled else { return }
        strollPhase = false
        withAnimation(.easeInOut(duration: 0.28)) { quirkyHands = .rest }
        try? await Task.sleep(for: .seconds(0.32))
    }

    /// 托腮：单手抬到脸侧 → 托着发呆一会儿 → 放下
    private func playChinRest() async {
        withAnimation(.easeInOut(duration: 0.38)) { quirkyHands = Self.representativePose(.chinRest) }
        try? await Task.sleep(for: .seconds(1.6))
        guard animate, !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.36)) { quirkyHands = .rest }
        try? await Task.sleep(for: .seconds(0.40))
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
        // ⚠️ 同 ChatView.TypingIndicator：`.animation(_:value:)` 只在 pulse 变化时施加动画，
        // 循环脉冲必须有 false→true 边沿才启动。视图被复用（宠物状态 thinking→idle→thinking、
        // 列表回收）时 @State 还是 true → 无变化 → 动画不重启，三点静止（概率性看起来「没动画」）。
        // 消隐时复位 → 下次出现必定是边沿。两行成对，删掉 onDisappear 就复发。
        .onAppear { if animated { pulse = true } }
        .onDisappear { pulse = false }
    }
}
