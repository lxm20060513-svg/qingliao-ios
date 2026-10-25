import SwiftUI
import Combine
import AVFoundation

// MARK: - v3.9.76 语音对话全屏页（用户拍板：方案 C 涟漪玻璃 · 深色科幻 · 全念）
//
// 与「语音输入」的区别（别把两者做成一个东西）：
//   语音输入 = 说一句 → 转文字 → **停下等你点发送**，一轮就结束（输入栏长按那套）；
//   语音对话 = **闭环**：说 → 停顿 2 秒自动发（也可手动点发送）→ AI 回 → 自动念 → 念完自动续听。
//
// 三处刻意的复用（本文件不重造）：
//   · 判断：轮次推进全在 VoiceDialogEngine（纯逻辑、本机可测）。本页**只执行它给的动作**，
//     不自己判"该不该发"——判断散在 UI 里就再也测不了了。
//   · 发送：post `.qingliaoTaskSend` → ChatView.sendCore，与任务中心 / 备忘录「发给 AI」同一条通道，
//     落库、上下文、排队、失败重试全部沿用，不存在"语音发出去的消息跟键盘发的不是一回事"。
//   · 朗读：**借 ChatView 的自动朗读**（它念全文、剥进度行、会跳过推送气泡与错误占位）。
//     进入本页时临时打开该开关、退出还原原值——用户要的「全念」就是这条既有口径，
//     本页不另写一份摘要朗读（两份口径必然分叉）。
//
// 半双工：AI 念的时候关麦（判断在 engine，本页照做）。想打断 → 点「打断」，
//   SpeechManager 停止 → speakingID 归 nil → engine 收到 speechEnded → 自动续听，无需额外分支。
//
// v4.1.x 通话态（用户要「打电话给 Hermes」）：
//   · **不是 PSTN 电话**：Hermes 原生 telephony 底层是 Twilio/Vapi，官方不支持呼出中国大陆；
//     这里做的是 App 内通话页 —— 大脑仍是 Hermes 本体（sendCore），复用 ASR/TTS，零外部通话费。
//   · 全双工会话由 CallAudioSession 独占（.playAndRecord + .voiceChat）；本页是全仓唯一
//     允许 engine.fullDuplex = true 的调用方，其余语音路径保持半双工。
//   · 插话 = 停朗读 + 停流 + 把用户那截设为草稿（回声闸门在 engine，UI 不自己判）。
//   · 收起 = 结束通话（本版没有后台通话条 / 锁屏通话，挂断与收起同一条退出路径）。
//
// 本机没有 Xcode/模拟器 → 这一页的手感（涟漪节奏、收音启停时机）**只能装机看**，
// 本机能保证的只有状态机（scripts/test_voice_dialog.swift）与形态护栏（ql_orbmenu 真值表）。

struct VoiceDialogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatStore.self) private var chat
    /// 插话要真的停掉在跑的回复（只停朗读 = 旧答案继续写进会话，用户会以为没打断）
    @Environment(StreamClient.self) private var stream
    @Environment(AuthStore.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// v3.9.77：跟随系统明暗（用户要求「界面对应系统 UI」）。只用来调柔光/涟漪强度，
    /// 文字一律走语义色（.primary/.secondary），所以浅色下也不会出现白字看不见。
    private var isDark: Bool { colorScheme == .dark }
    /// 球体渐变分档（v3.9.77 复审修）：浅色底就是 `systemBackground`（近白），白心 0.92 的球贴上去
    /// 等于「白球贴白底」——半径 43 处只剩 ≈22% accent，球体轮廓基本消失（那套参数只有深色稿成立）。
    /// 浅色档压白心、让主题色主导，两套主题下球都立得住。
    private var ballColors: [Color] {
        isDark ? [.white.opacity(0.92), Color.accentColor.opacity(0.45), .clear]
               : [.white.opacity(0.42), Color.accentColor.opacity(0.86), .clear]
    }
    @StateObject private var liveSpeech = LiveSpeechTranscriber()
    @ObservedObject private var speech = SpeechManager.shared
    /// 逐字进度的**独立**观察对象（v3.9.77 复审修）：不观察 SpeechManager 自身的高频 @Published，
    /// 那会把整片聊天列表按 12.5Hz 连坐重绘（见 `SpokenProgress` 注释）。
    @ObservedObject private var spokenProgress = SpeechManager.shared.progress

    @State private var engine = VoiceDialogEngine()
    @State private var ripple = false
    @State private var voiceError: String?

    // MARK: v4.1.x 通话态
    /// 通话计时（秒）。只在通话页本地，不进全局。
    @State private var callSeconds = 0
    /// 麦克风静音（只影响本页，停止收音但保留通话）
    @State private var muted = false
    /// 免提（扬声器）开关；会话不可用时由 CallAudioSession 兜底
    @State private var speakerOn = true
    /// 本机是否成功激活了全双工会话（false = 自动降级半双工）
    @State private var duplexAvailable = true
    /// 切换全双工时的互斥锁：切会话要先停麦再开麦，连点会抢音频会话
    @State private var duplexSwitching = false
    /// 全双工偏好：默认开、页内可关、跨通话保留
    @AppStorage("qingliao_call_full_duplex") private var fullDuplexPref = true
    /// 本页激活的通话会话 token；退出时只关自己那份，不能误关用户刚重进的新通话
    @State private var pageID = UUID()
    /// 本轮发送时的收尾序号基准：`stream.finishSeq > base` = 这一轮已经收尾。
    /// 不用 `isStreaming` 判收尾 —— 本仓 StreamClient 明确写了同帧续发会吞掉它的边沿。
    @State private var turnBaseFinishSeq = 0
    /// 麦克风操作串行链：open/close/restart 各自起 Task 会互相取消，
    /// 短回复时「念完重开」与「开始念重开」叠在一起 → openMic 被 isRunning 挡掉 → 死麦。
    @State private var micTask: Task<Void, Never>?
    /// 「念完了」去抖：流式分段朗读的段间 speakingID 会短暂归 nil，
    /// 不能当成整轮结束（否则剩余段朗读时麦克风开着，AI 会把自己的话录成用户输入）。
    @State private var speechEndTask: Task<Void, Never>?
    /// 收音看门狗：listening 状态下麦没开超过 1.2s 就补一次 openMic（死麦自愈）。
    @State private var micDownSince: Date?
    /// 正在退出：挡住排队中的 openMic，避免页面消失后麦克风才打开（残余收音）。
    @State private var isClosing = false
    /// 通话秒表（与 0.25s 判停 ticker 分开：一个走引擎、一个只画 UI）
    @State private var callTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// ⚠️ 必须放 @State：宿主 DockTabView 的 body 会因 dockBarHeight / stream 等状态不断重绘，
    /// 而 View 是值类型——写成 `private let` 的话每次重建都换一个新 publisher，`onReceive` 跟着重新订阅，
    /// 0.25s 的判停定时器被反复重启 → 症状是「说完不自动发、只能手点」。@State 保证 publisher 只建一次。
    @State private var ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // v3.9.77：**跟随系统明暗**（原实现按深色稿写死了深底 + .environment(.colorScheme, .dark)，
            // 浅色模式下整页仍是黑的）。现在是：一片 accent 柔光（深色 0.22 / 浅色 0.14），
            // 两套主题都保住「科幻感 · 轻盈」，对比度各自调过。
            // v4.0.67 P5：底色由「系统底」换成主题环境渐变页底（EnvironmentGlowLayers 自带白/黑兜底
            // + 三团光晕，明暗自适应），accent 柔光/涟漪按原口径叠在它上面 —— 观感与全站其它页同底。
            EnvironmentGlowLayers(scheme: colorScheme)
            RadialGradient(colors: [Color.accentColor.opacity(isDark ? 0.22 : 0.14), .clear],
                           center: .center, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                core
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, Spacing.section)
            .padding(.bottom, Spacing.xxl)
        }
        .onAppear {
            // 「全念」用进程内开关，不写 UserDefaults（进程被杀也不会把用户设置永久改开）。
            SpeechManager.shared.callForceRead = true
            pageID = UUID()
            turnBaseFinishSeq = stream.finishSeq
            if !reduceMotion { ripple = true }
            callSeconds = 0
            muted = false
            voiceError = nil
            isClosing = false
            startCallAudio()
            perform(engine.handle(.start))
        }
        .onDisappear {
            // 同步交还「全念」开关，聊天页立刻按用户原设置走。
            SpeechManager.shared.callForceRead = false
            // 退出时必须停朗读：用户点退出时 AI 可能正在念。
            SpeechManager.shared.stop()
            isClosing = true
            speechEndTask?.cancel()
            speechEndTask = nil
            micTask?.cancel()
            micTask = nil
            let owner = pageID
            // 先停麦收尾，再交还会话：顺序反了会让录音引擎在已切走的会话上收尾。
            Task { @MainActor in
                _ = engine.handle(.stop)
                await closeMic()
                // 只关自己这通电话：用户快速重进时 owner 已换，旧收尾不能关掉新会话。
                if CallAudioSession.shared.owner == owner {
                    SpeechManager.shared.callAudioActive = false
                    CallAudioSession.shared.deactivate(owner: owner)
                }
            }
        }
        .onReceive(ticker) { _ in
            perform(engine.handle(.tick(Date())))
            recoverMicIfNeeded()
        }
        .onReceive(callTimer) { _ in
            guard engine.phase != .ended else { return }
            callSeconds += 1
        }
        .onChange(of: liveSpeech.liveText) { _, text in
            // 全双工：朗读期间也要吃转写，先过引擎的回声闸门再决定是不是插话。
            if engine.phase == .speaking {
                let spoken = String(spokenProgress.text.prefix(spokenProgress.charCount))
                perform(engine.handle(.heardDuringSpeech(text, spoken: spoken)))
            } else if engine.fullDuplex, spokenProgress.charCount > 0 {
                // 插话后继续收音：带**当前**已念全文，剥掉停止朗读前残余的那点回声。
                let spoken = String(spokenProgress.text.prefix(spokenProgress.charCount))
                perform(engine.handle(.heardWithSpoken(text, spoken: spoken)))
            } else {
                perform(engine.handle(.heard(text)))
            }
        }
        .onChange(of: speech.speakingID) { _, id in
            if id == nil {
                scheduleSpeechEnd()
            } else {
                speechEndTask?.cancel()
                // 分段朗读的下一段：只有「这一轮还在生成」才按续段处理，
                // 手动点气泡/推送朗读仍走普通 speechStarted（会被 waiting 挡掉）。
                if engine.fullDuplex, engine.phase == .listening,
                   stream.finishSeq == turnBaseFinishSeq {
                    perform(engine.handle(.speechSegmentStarted))
                } else {
                    perform(engine.handle(.speechStarted))
                }
            }
        }
        .onChange(of: stream.finishSeq) { _, _ in
            // 收尾序号只增，不会像 isStreaming 那样被同帧续发吞掉。
            if speech.speakingID == nil { scheduleSpeechEnd() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .ended else { return }
            // 来电/Siri 结束后把通话会话与麦克风接回来（否则页面看着在通话、其实全哑）。
            Task { @MainActor in
                guard !isClosing else { return }
                // 正在念的时候被打断：先把这一轮收尾；TTS 已恢复（speakingID 非空）就保持 speaking，
                // 半双工下绝不能在这时开麦。
                if engine.phase == .speaking {
                    guard speech.speakingID == nil else { return }
                    perform(engine.handle(.speechEnded))
                }
                guard engine.phase == .listening else { return }
                guard engine.fullDuplex else {
                    // 半双工没有 CallAudioSession，直接重开麦即可
                    enqueueMic { await restartMic() }
                    return
                }
                guard CallAudioSession.shared.activate(owner: pageID) else {
                    // 恢复不了全双工就降级，别让整通电话静音
                    engine.fullDuplex = false
                    SpeechManager.shared.callAudioActive = false
                    duplexAvailable = false
                    voiceError = "通话被系统打断后未能恢复免打断，已用半双工"
                    enqueueMic { await restartMic() }
                    return
                }
                SpeechManager.shared.callAudioActive = true
                enqueueMic { await restartMic() }
            }
        }
    }

    /// 「一轮念完」去抖：分段朗读的段间 speakingID 会归 nil，但 LLM 还在生成下一段。
    /// 350ms 内没有新段、且流已结束，才算整轮结束（回到 listening 并重开麦）。
    private func scheduleSpeechEnd() {
        speechEndTask?.cancel()
        guard speech.speakingID == nil, stream.finishSeq > turnBaseFinishSeq else { return }
        speechEndTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, speech.speakingID == nil,
                  stream.finishSeq > turnBaseFinishSeq else { return }
            perform(engine.handle(.speechEnded))
        }
    }

    // MARK: 顶栏（收起 / 通话对象 / 免打断）

    private var header: some View {
        ZStack {
            VStack(spacing: 2) {
                Text("Hermes")
                    .font(.system(size: Typography.headline, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 5) {
                    Circle()
                        .fill(engine.phase == .ended ? Color.secondary : Color.green)
                        .frame(width: 6, height: 6)
                    Text(timerText)
                        .font(.system(size: Typography.caption, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("· 正在通话")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)          // 吃满屏宽 → 标题恒在屏幕中线（不随两侧胶囊宽窄漂移）
            HStack {
                Button { close() } label: {
                    Text("收起").pill(.topBar, tone: .accent)
                }
                Spacer(minLength: 0)
                Button { toggleFullDuplex() } label: {
                    Text(duplexLabel).pill(.topBar, tone: engine.fullDuplex ? .accent : .neutral)
                }
                .disabled(engine.phase == .speaking || engine.phase == .sending
                          || !duplexAvailable || duplexSwitching)
                .accessibilityLabel(engine.fullDuplex ? "免打断已开启，可以直接说话打断" : "免打断已关闭，点「打断」才能插话")
            }
        }
        .padding(.top, Spacing.lg)
    }

    private var timerText: String {
        String(format: "%02d:%02d", callSeconds / 60, callSeconds % 60)
    }

    private var duplexLabel: String {
        if !duplexAvailable { return "半双工" }
        return engine.fullDuplex ? "免打断 · 开" : "免打断 · 关"
    }

    // MARK: 核心视觉（方案 C：中心柔光 + 三层扩散涟漪）

    private var core: some View {
        VStack(spacing: Spacing.xxl) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.accentColor.opacity(isDark ? 0.34 : 0.22), .clear],
                                         center: .center, startRadius: 0, endRadius: 112))
                    .frame(width: 224, height: 224)
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(Color.accentColor.opacity(ripple ? 0 : 0.30), lineWidth: 1)
                        .frame(width: 128 + CGFloat(i) * 46, height: 128 + CGFloat(i) * 46)
                        .scaleEffect(ripple ? 1.20 : 0.86)
                        .animation(reduceMotion ? nil
                                   : .easeOut(duration: 2.4)
                                       .repeatForever(autoreverses: false)
                                       .delay(Double(i) * 0.8),
                                   value: ripple)
                }
                Circle()
                    .fill(RadialGradient(colors: ballColors,
                                         // 🚨 v3.9.77：高光点必须**接近球心**。原来写 (0.36, 0.32)（明显偏左上），
                                         // 人眼会把最亮处当球心 → 看着球「没居中在涟漪里」（用户 2026-09-25 报）。
                                         // 几何上三圈涟漪与球本来就同心（ZStack 中心对齐），偏心是**视觉**造成的。
                                         // 保留一点点左上偏移（0.44/0.40）留立体感，但视觉重心回到中心。
                                         center: UnitPoint(x: 0.44, y: 0.40),
                                         startRadius: 2, endRadius: 56))
                    .frame(width: 86, height: 86)
                    .shadow(color: Color.accentColor.opacity(0.55), radius: 28)
            }
            .frame(height: 240)
            .allowsHitTesting(false)          // 纯视觉，不吃触摸

            VStack(spacing: Spacing.md) {
                Text(phaseLabel)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                replyText
                if let voiceError {
                    Text(voiceError)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    // MARK: 底部（声波 + 通话控件）

    private var bottomBar: some View {
        VStack(spacing: Spacing.xl) {
            waveBars
            Text(bottomHint)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 26) {
                callButton(icon: muted ? "mic.slash.fill" : "mic.fill",
                           label: muted ? "已静音" : "静音",
                           active: muted) { toggleMute() }
                callButton(icon: speakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                           label: speakerOn ? "免提" : "听筒",
                           active: speakerOn, enabled: engine.fullDuplex) { toggleSpeaker() }
                callButton(icon: "phone.down.fill", label: "挂断", danger: true) { close() }
            }
            HStack(spacing: Spacing.lg) {
                Button { toggleMode() } label: {
                    Text(engine.mode == .auto ? "自动发送 · 开" : "自动发送 · 关")
                        .pill(.topBar, tone: .neutral)
                }
                .accessibilityLabel(engine.mode == .auto ? "自动发送已开启，停顿两秒自动发出" : "自动发送已关闭，说完点发送")
                if engine.phase == .speaking {
                    Button { interruptReply() } label: {
                        Text("打断").pill(.topBar, tone: .accent)
                    }
                } else {
                    Button { perform(engine.handle(.send)) } label: {
                        Text("发送").pill(.topBar, tone: .accent)
                    }
                    .disabled(engine.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// 通话圆键：静音 / 免提 / 挂断。玻璃圆底 + 图标 + 11pt 说明。
    @ViewBuilder
    private func callButton(icon: String, label: String,
                            active: Bool = false, danger: Bool = false,
                            enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        VStack(spacing: Spacing.sm) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(danger ? Color.white : (active ? Color.accentColor : Color.primary))
                    .frame(width: 62, height: 62)
                    .background {
                        if danger {
                            Circle().fill(Color.red)
                        } else {
                            Circle().fill(.ultraThinMaterial)
                        }
                    }
                    .overlay {
                        Circle().strokeBorder(danger ? Color.clear : Color.primary.opacity(0.10),
                                              lineWidth: 0.8)
                    }
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.38)
            .accessibilityLabel(label)
            Text(label)
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.secondary)
        }
    }

    private var bottomHint: String {
        if liveSpeech.isPreparing { return "正在准备语音模型…" }
        switch engine.phase {
        case .listening:
            return engine.draft.isEmpty ? "请说话，停顿 2 秒自动发送" : "说完停顿 2 秒，或点「发送」"
        case .sending:
            return "Hermes 正在想…"
        case .speaking:
            return engine.fullDuplex ? "可以直接说话打断" : "点「打断」可随时插话"
        case .idle:
            return "正在接通…"
        case .ended:
            return "通话已结束"
        }
    }

    /// v3.9.77（用户定稿：**方案 2**）：波形 = **一条横向渐变（蓝→紫→青）的细波浪线 + 一条淡副波**，
    /// 取代原来的 11 根竖柱。灵动感来自两处：振幅跟麦克风实时电平、**相位随时间推进**（线在流动）。
    /// 数据源仍是 `liveSpeech.currentInputLevel()` 每帧自读 —— **不走 @Published 广播**，
    /// 否则共用的聊天页（按住说话）会被连坐重绘（复审实测问题）。
    /// 原来是写死的固定高度数组 = 不管你说不说话都一个样（用户报「波浪应跟着音频高低波动」）。
    /// 现在每根条按自身形状系数缩放：安静时收到 8pt 最低，说话时按电平长高。
    private var waveBars: some View {
        // v3.9.77：波条**每帧自己读电平**（`TimelineView` 只重绘这一小块子树）。
        // 不走 @Published 广播 —— 那会让共用的聊天页跟着 14Hz 重绘（审查实测问题）。
        // 周期取 0.06s（≈16fps，跟手且省电）；「减弱动态效果」降到 0.25s，只保必要的音量反馈。
        // ⚠️ schedule 用 `.periodic(from:by:)` 同一类型 + 参数分档：写成三元选 `.animation`/`.periodic`
        // 会因两个 schedule 类型不等价而编译失败（本仓踩过，别改成那种写法）。
        TimelineView(.periodic(from: .now, by: reduceMotion ? 0.25 : 0.06)) { ctx in
            Canvas { context, size in
                let lv = CGFloat(isListening ? liveSpeech.currentInputLevel() : 0)
                let amp = 2.4 + 32 * lv                 // 安静仍留 2.4pt 呼吸（死直线比微微起伏更"卡住"）
                let phase = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate * 2.2
                let strong = isListening ? 0.95 : 0.40 // 深浅两套主题共用，靠不透明度分档
                let mid = size.height / 2
                let mainColors = [Color.accentColor.opacity(strong),
                                  Color.purple.opacity(strong * 0.9),
                                  Color.teal.opacity(strong * 0.85)]
                let subColors = [Color.accentColor.opacity(strong * 0.40),
                                 Color.teal.opacity(strong * 0.32)]
                context.stroke(
                    Self.wavePath(in: size, amp: amp, phase: phase, wavelength: 66),
                    with: .linearGradient(Gradient(colors: mainColors),
                                          startPoint: CGPoint(x: 0, y: mid),
                                          endPoint: CGPoint(x: size.width, y: mid)),
                    lineWidth: 2.1)
                context.stroke(
                    Self.wavePath(in: size, amp: amp * 0.58, phase: phase * 0.8 + 1.6, wavelength: 82),
                    with: .linearGradient(Gradient(colors: subColors),
                                          startPoint: CGPoint(x: 0, y: mid),
                                          endPoint: CGPoint(x: size.width, y: mid)),
                    lineWidth: 1.3)
            }
        }
        .frame(height: 76)
        .allowsHitTesting(false)
    }

    private var isListening: Bool { engine.phase == .listening }

    /// 正弦波路径：两端按 `sin(πt)^0.55` 收口（细线自然收尾，比硬裁好看）。
    /// 纯函数、不碰状态 → 抽成 static，日后可进真值表按采样点断言。
    static func wavePath(in size: CGSize, amp: CGFloat, phase: Double, wavelength: CGFloat) -> Path {
        var p = Path()
        let steps = 96
        let mid = size.height / 2
        for i in 0...steps {
            let x = size.width * CGFloat(i) / CGFloat(steps)
            let t = Double(i) / Double(steps)
            let envelope = pow(sin(Double.pi * t), 0.55)
            let y = mid + amp * CGFloat(envelope * sin(2 * Double.pi * Double(x) / Double(wavelength) + phase))
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }

    // MARK: 文案

    private var phaseLabel: String {
        // 准备期优先：首次使用要先弹权限框 + 下语音模型（数秒~数十秒），
        // 这段时间显示「聆听中」会让用户对着没开的麦克风说话 → 静默失败。
        if liveSpeech.isPreparing { return "正在准备语音模型…" }
        switch engine.phase {
        case .listening: return "正在通话 · 第 " + String(engine.rounds + 1) + " 轮"
        case .sending:   return "Hermes 正在想…"
        case .speaking:  return "Hermes 正在说…"
        case .idle:      return "正在接通…"
        case .ended:     return "已挂断"
        }
    }

    private var displayText: String {
        switch engine.phase {
        case .listening:
            return engine.draft.isEmpty ? "我在听…" : engine.draft
        case .sending:
            return "已发出，等 Hermes 回复"
        case .speaking:
            // v3.9.77：文字跟着语音**逐字**吐出来（系统引擎精确回调 / 云端按播放位置估算，
            // 数据源见 SpeechManager 的独立发布箱 `progress`：text + charCount）。已念部分为空时先给摘要占位。
            let spoken = String(spokenProgress.text.prefix(spokenProgress.charCount))
            return spoken.isEmpty ? (latestReplyExcerpt ?? "Hermes 正在组织答案") : spoken
        case .idle, .ended:
            return latestReplyExcerpt ?? "Hermes 正在组织答案"
        }
    }

    /// v3.9.78：回复正文改**可滚动 + 自动跟读**（用户：「这个模式后面的文字显示不出来」）
    ///
    /// 真因：原来这里是 `.lineLimit(4)`（17pt 正文、宽 ≈361pt ≈ 每行 21 字）——
    /// 4 行不到 90 字就被裁成「…」（装机截图实测：正文**正好 4 行**、末行断在句中 + 省略号）。
    /// 而朗读态的文字是**逐字**增长的（v3.9.77 口径）：念到第 5 行以后，新吐出来的字全部落在
    /// 被裁掉的那一段里 → 屏幕上永远看不到，观感就是「后面的文字显示不出来」。
    /// 现在 = `ScrollView`（不再限行）+ 定高上限 `replyMaxHeight`（≈8 行；长文不会把底栏挤走，
    /// 小屏上由 ScrollView 自己收缩）+ 逐字文本变化时**自动贴底** → 新念出来的字始终在眼前，
    /// 想回看前文直接手滑即可。
    /// ⚠️ 别再退回 `lineLimit`：那等于把「后面的文字」重新关掉（真值表有护栏钉住）。
    ///
    /// v3.9.82：改成**两稿**（与译文卡 `OrbIdentifyOverlay`、崩溃日志预览 `QingliaoApp` 同口径）——
    /// 上面那版仍是「贪婪 `ScrollView` + `.frame(maxHeight:)`」：`ScrollView` 会吃掉提案给它的
    /// **全部**高度 → 只想说两三句的短回复也占满 220pt，正文区白一大块、把波形往下挤。
    /// 稿 1 = 内容自然高度（短回复按实际行数收缩）；稿 2 = 内容超上限时才用可滚动一稿
    /// （吃满上限 + 逐字变化贴底）。两稿**共用同一 `replyTextBody`**，防两稿内容漂移。
    /// ⚠️ 两条红线：别退回 `lineLimit`；**别把两稿调换**（调换 = 短回复又白撑）。真值表都钉住了。
    private var replyText: some View {
        ScrollViewReader { proxy in
            ViewThatFits(in: .vertical) {
                replyTextBody
                ScrollView(.vertical, showsIndicators: false) {
                    replyTextBody
                }
            }
            // ⚠️ v3.9.82（代码审查）：上限必须钳在**外层（提案）**上。ViewThatFits 的取舍判据是
            //   「这一稿放不放得进它收到的提案」—— 只把 maxHeight 挂在稿 2 上，稿 1 的「放得下」就变成
            //   「不超过本页剩余的全部高度」（≈400pt）→ 中长回复（≈8~14 行）走稿 1、不滚动也不受上限
            //   约束，把波形与底栏的呼吸位吃掉；小屏再往下压就是裁切且无法滚动（稿 1 不是 ScrollView）。
            //   口径与被删掉的译文卡同一套，那里写着：「① 的『放得下』= 不超过 220」。
            .frame(maxHeight: Self.replyMaxHeight)
            .onChange(of: displayText) { _, _ in
                // 逐字增长（≈12.5Hz）：**不做动画**直接贴底 —— 带动画会一顿一顿
                proxy.scrollTo(Self.replyBottomAnchor, anchor: .bottom)
            }
        }
    }

    /// 正文本体（两稿共用：稿 1 直接放、稿 2 塞进 `ScrollView`）
    private var replyTextBody: some View {
        Text(displayText)
            .font(.system(size: Typography.title, weight: .medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            // 长文阅读走全站行距令牌（v3.9.19 口径：≥15pt 连续阅读文本用 LineSpacing.long）
            .lineSpacing(LineSpacing.long)
            .frame(maxWidth: .infinity)
            .id(Self.replyBottomAnchor)
            .animation(Motion.snap, value: displayText)
    }

    /// 正文区高度上限（≈8 行 @17pt + 行距 6）：852 屏上 260 波形 + 顶栏 + 底栏之后仍有富余；
    /// 更小的屏幕上 ScrollView 会自己收缩，不挤走底栏。
    private static let replyMaxHeight: CGFloat = 160
    /// 自动贴底用的锚点 id（正文整块一个 id：内容在末尾增长，锚到它的底边即「最新一行」）
    private static let replyBottomAnchor = "voice_reply_bottom"

    /// 最后一条真正的 AI 回答（剥掉进度行，跳过推送与错误占位——与自动朗读同一口径）
    private var latestReplyExcerpt: String? {
        guard let msg = chat.messages.last(where: { !$0.isUser && !$0.isPush && !$0.isErrorPlaceholder })
        else { return nil }
        let text = MessageBubble.strippingProgressLines(msg.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // v3.9.78：不再截 120 字。截断的理由是「正文区撑不下」（旧 .lineLimit(4)），
        // 现在正文区是定高 ScrollView（replyText），正文本身可以完整交给它 ——
        // 否则朗读结束后切回这一段时，长回答又只剩开头 120 字（用户报的同一个症状）。
        return text
    }

    // MARK: 动作执行（引擎给什么就做什么）

    private func perform(_ action: VoiceDialogEngine.Action) {
        switch action {
        case .none:
            break
        case .sendNow(let text):
            Haptics.success()
            // 复用既有「从别处发到聊天流」通道（ChatView.sendCore），落库/上下文/排队全沿用。
            // ⚠️ 发送的同时**立刻停麦**（`Action.sendNow` 的语义就是「发出 + 停麦」）：
            //   发送到朗读开始之间（最长 25 秒）开着麦没意义，而且停麦的音频会话收尾
            //   `setActive(false)` 会和朗读起播抢时序，把刚开口的念读掐掉。
            enqueueMic { await closeMic() }
            turnBaseFinishSeq = stream.finishSeq   // 本轮收尾基准（finishSeq 只增）
            NotificationCenter.default.post(name: .qingliaoTaskSend, object: text)
        case .openMic:
            enqueueMic { await openMic() }
        case .closeMic:
            enqueueMic { await closeMic() }
        case .restartMic:
            enqueueMic { await restartMic() }
        case .interruptAndListen:
            // 全双工插话：停朗读 + 停掉在跑的回复，麦克风保持开着
            // （引擎已把 phase 切回 listening、草稿已就位）。
            Haptics.press()
            interruptReply()
        }
    }

    /// 麦克风操作串行链：同一时刻只允许一个 open/close/restart 在跑。
    /// 直接给每个 action 起独立 Task 时，短回复的「开始念重开」与「念完重开」会互相
    /// cancel；被挡掉的 openMic 会让麦克风永久关着（UI 还显示在通话）。
    private func enqueueMic(_ op: @escaping @MainActor () async -> Void) {
        let prev = micTask
        micTask = Task { @MainActor in
            await prev?.value
            guard !Task.isCancelled else { return }
            await op()
        }
    }

    /// 死麦自愈：listening 状态下麦没开超过 1.2s 就补一次。
    /// 只在没有真实错误（权限/机型不支持）时重试，避免每 1.2s 弹一次错。
    private func recoverMicIfNeeded() {
        guard engine.phase == .listening, !muted, !isClosing, liveSpeech.lastError == nil,
              !liveSpeech.isRunning, !liveSpeech.isPreparing else {
            micDownSince = nil
            return
        }
        if micDownSince == nil {
            micDownSince = Date()
            return
        }
        guard let since = micDownSince, Date().timeIntervalSince(since) > 1.2 else { return }
        micDownSince = nil
        enqueueMic { await openMic() }
    }

    private func openMic() async {
        // 静音期间任何 openMic 都不得开麦（引擎在换轮时会持续发 openMic）
        guard !muted, !isClosing else { return }
        guard !liveSpeech.isRunning, !liveSpeech.isPreparing else { return }
        let started = await liveSpeech.start(baseline: "",
                                             policy: SpeechManager.shared.callAudioActive ? .call : .standard)
        if started {
            voiceError = nil
        } else {
            // 没权限 / 被占用 / 机型不支持设备端识别：必须出声，且**带上真实原因**——
            // 只说「没打开」会让不支持该能力的机型反复「退出重进」永远不成功。
            voiceError = liveSpeech.lastError ?? "麦克风没打开（检查权限后点「收起」重进）"
            Haptics.error()
        }
    }

    /// 全双工换轮：先停麦再立刻开麦，清空上一轮混进来的 AI 朗读缓冲。
    private func restartMic() async {
        guard !muted else { return }
        await closeMic()
        await openMic()
    }

    /// 进入通话：优先激活全双工会话；失败（老机型/路由占用）自动降级半双工。
    private func startCallAudio() {
        engine.fullDuplex = false
        duplexAvailable = true
        guard fullDuplexPref else {
            SpeechManager.shared.callAudioActive = false
            CallAudioSession.shared.deactivate(owner: pageID)
            return
        }
        guard CallAudioSession.shared.activate(owner: pageID) else {
            duplexAvailable = false
            SpeechManager.shared.callAudioActive = false
            speakerOn = true
            voiceError = "本机未启用免打断，已用半双工通话"
            return
        }
        SpeechManager.shared.callAudioActive = true
        engine.fullDuplex = true
        speakerOn = CallAudioSession.shared.speakerOn
    }

    private func toggleMute() {
        Haptics.tap()
        muted.toggle()
        let nowMuted = muted
        enqueueMic {
            if nowMuted {
                await closeMic()
            } else {
                await restartMic()
            }
        }
    }

    private func toggleSpeaker() {
        Haptics.tap()
        CallAudioSession.shared.setSpeaker(!speakerOn)
        speakerOn = CallAudioSession.shared.speakerOn
    }

    /// 免打断开/关：只在收音态可切（朗读/等待态切换会抢音频会话，稳定优先）。
    /// ⚠️ 顺序不能反：先按**当前**策略停麦收尾，再换会话，最后按**新**策略开麦。
    /// 反过来（先 activate 再 restartMic）会让 `.standard` 的 teardown 把刚激活的通话会话停掉。
    private func toggleFullDuplex() {
        guard duplexAvailable, !duplexSwitching else { return }
        Haptics.tap()
        duplexSwitching = true
        enqueueMic {
            defer { duplexSwitching = false }
            if engine.fullDuplex {
                await closeMic()                       // .call 收尾：不动会话
                engine.fullDuplex = false
                fullDuplexPref = false
                SpeechManager.shared.callAudioActive = false
                CallAudioSession.shared.deactivate(owner: pageID)
                await openMic()                        // .standard 重新起麦
            } else {
                await closeMic()                       // .standard 收尾：会停会话
                guard CallAudioSession.shared.activate(owner: pageID) else {
                    duplexAvailable = false
                    Haptics.error()
                    voiceError = "本机未启用免打断，继续用半双工"
                    await openMic()                    // 退回半双工也要能说
                    return
                }
                fullDuplexPref = true
                SpeechManager.shared.callAudioActive = true
                engine.fullDuplex = true
                speakerOn = CallAudioSession.shared.speakerOn
                await openMic()                        // .call 重新起麦
            }
        }
    }

    private func closeMic() async {
        // ⚠️ 判据必须含 `isPreparing`：`isRunning` 直到起麦那一刻才为 true，
        //   而准备期（首次要弹权限框、首次要下语音模型）用户完全可能点「退出」——
        //   只看 isRunning 会直接 return，随后 start() 继续跑完并在**页面已消失之后**开麦，
        //   这一页又是全仓唯一的停麦调用点 → 残余收音 + 状态栏橙点直到进程结束。
        guard liveSpeech.isRunning || liveSpeech.isPreparing else { return }
        // 用 cancel()：它先置 cancelRequested，start() 会在每个 await 之后自行中止（stop() 没有这条路）。
        await liveSpeech.cancel()
    }

    private func toggleMode() {
        engine.mode = engine.mode == .auto ? .manual : .auto
        Haptics.tap()
    }

    /// 打断当前这一轮：停朗读 + 停掉在跑的回复 + 清排队消息。
    /// 复用灵动岛「停止生成」那条通知的语义（ChatView 在接收端会置 suppressAutoReadOnce 并清队列），
    /// 否则停流后残句还会被自动朗读一遍。
    private func interruptReply() {
        SpeechManager.shared.stop()
        NotificationCenter.default.post(name: LiveActivityActionBridge.clearPendingQueueNotification, object: nil)
        stream.stop(auth: auth)
    }

    private func close() {
        // 只改状态，收尾统一交给 onDisappear 单路执行（避免 close + onDisappear 双路 closeMic）。
        isClosing = true
        _ = engine.handle(.stop)
        dismiss()
    }
}
