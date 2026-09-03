// MARK: - ChatInputBar（从 ChatComponents.swift 拆出）
import SwiftUI


struct ChatInputBar: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    var streaming: Bool
    var onSend: () -> Void
    var onStop: () -> Void = {}
    var onPickAttachment: () -> Void = {}
    var onCamera: () -> Void = {}   // v2.0.38 拍照输入
    // 语音输入（按住说话）
    var isRecording: Bool = false
    var onVoiceStart: () -> Void = {}
    var onVoiceEnd: () -> Void = {}
    // v2.0.96：语音转文字模式（长按发送按钮进入；Siri 彩色图标 + 输入框流光）
    var voiceMode: Bool = false
    var onVoiceModeToggle: () -> Void = {}
    // v2.0.100：转写中动画（输入框「语音转换中…」+ 按钮转圈）
    var transcribing: Bool = false
    // v2.0.101：转写停止按钮回调
    var onCancelTranscribe: () -> Void = {}
    // v2.0.106：长按输入框触发语音转文字（效果与长按发送键一致，不弹键盘）
    // v2.0.109b：onChanged 记录按下瞬间键盘可见状态（down 时键盘未弹/已弹，比时间戳推断可靠）
    var onLongPressInput: (Bool) -> Void = { _ in }
    // v3.0.4：语音功能启用开关——云端模式无后端 ASR，关闭全部语音入口（长按/按钮）
    var voiceEnabled: Bool = true
    @Environment(KeyboardObserver.self) private var kbEnv
    @State private var pressKeyboardUp = false
    // v2.0.129：Siri 圆球输入（设置开关，默认开）——默认状态是圆球，单击展开输入框，长按语音转文字
    @AppStorage("qingliao_ball_input") private var ballInput = true
    @State private var ballExpanded = false   // 球 → 输入框展开态（切会话由外层 .id() 重建复位）
    // v2.0.132：点击球触发全屏粒子爆发（满屏散开）——由外层 ChatView 挂全屏特效层（局部 BurstEffect 已删，视觉重叠且双 TimelineView 掉帧）
    var onFullBurst: () -> Void = {}

    var body: some View {
        Group {
            if ballInput && !ballExpanded && !voiceMode {
                // v3.0.76：语音转文字/指令激活时保持输入框（不显示球）——原 v3.0.68 收球逻辑会在语音转文字期间收成球，
                // 用户反馈"触发语音转文字跳到智能球"，此处排除 voiceMode，语音转文字全程保持输入框形态。
                // 🟣 v2.0.129 球态：Siri 多彩光晕圆球居中（单击展开输入框 / 长按语音转文字）
                // 语音转文字/转写过程中球保持特效，转写完成自动展开（onChange 处理）
                // v2.0.129 球态：智能球单球居中（v3.0.50 移除扫码球）
                VStack(spacing: 8) {
                    HStack(spacing: 34) {
                    // v2.0.129 智能球：单击展开输入框 / 长按语音转文字
                    SiriBallView(thinking: streaming,
                                 onTap: {
                                     onFullBurst()
                                     withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                                         ballExpanded = true
                                     }
                                     Task { try? await Task.sleep(for: .seconds(0.4)); focused = true }
                                 },
                                 onLongPress: { onVoiceModeToggle() },
                                 voiceEnabled: voiceEnabled)
                    }
                }
                .padding(.bottom, 0)   // v3.0.66：球态间隙由外层 ChatInputBar 统一留（键盘收起时与 Dock 约 10pt 呼吸）
                // v2.0.130：球移除过渡——v2.0.132 优化：去掉 blurReplace（每帧离屏模糊最吃 GPU），只留缩放+淡出
                .transition(.scale(1.35).combined(with: .opacity))
            } else {
                fullInputBar
                    // v2.0.130：输入框从球心缩放展开——v2.0.132 优化：同样去掉 blurReplace
                    .transition(.scale(0.5).combined(with: .opacity))
            }
        }
        // v3.0.68 第6条：智能球开关下默认显示球——键盘收起且输入框为空 → 自动收回成球
        //（有文字则保留输入框，防误伤正在编辑的内容）
        // v3.0.76：语音转文字/指令激活期间（voiceMode）不收球——否则语音转文字→收键盘会触发此处收球，
        //          导致"触发语音转文字跳到智能球"。语音模式结束后（voiceMode=false）恢复正常收球。
        .onChange(of: kbEnv.isVisible) { _, visible in
            if ballInput, ballExpanded, !visible, text.isEmpty, !voiceMode {
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                    ballExpanded = false
                }
            }
        }
    }

    /// 完整输入栏（原 ChatInputBar 内容）
    private var fullInputBar: some View {
        HStack(spacing: 8) {
            Button(action: onPickAttachment) {
                Image(systemName: "paperclip")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)

            // v2.0.38：拍照输入
            Button(action: onCamera) {
                Image(systemName: "camera")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)

            if isRecording {
                // v3.2.4：录音中 UI 回归最原始静态样式（v3.0.85 前基线）——红点 + 松开上屏，
                // 无 1Hz 红点闪烁 / 无 0.1s TimelineView 计时器（v3.0.85 加的"录音计时器"）。
                // 触发语音时输入栏零动态视图，杜绝任何每帧重绘/动画叠加。
                HStack(spacing: 5) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text("松开上屏")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.red)
                }
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.08), in: Capsule())
            } else {
                // v3.0.40：回滚富文本输入（UITextView 桥接体验不佳）→ 恢复原 TextField(axis:.vertical)
                // v2.0.34：placeholder 用 overlay 自定义（vertical axis 的 TextField 自带
                // placeholder 在 lineLimit(2...6) 多行高下顶部对齐，视觉不居中）
                TextField("", text: $text, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(1...6)   // v2.0.35：1行起（原来2...6最小2行高→单行光标/文字偏上不居中）
                    .padding(.vertical, 12)   // v2.0.93f：9→12 输入框加高（用户反馈太窄）
                    .padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)   // 文字超宽自动增高输入框，旧文字始终可见
                    .focused($focused)
                    // v2.0.106：长按输入框 = 进入语音转文字（与长按发送键同效；收键盘由 ChatView 处理）
                    // v2.0.106b：onLongPressGesture 被 UITextField 内置长按(放大镜/选择)拦截不触发
                    //           → 改 simultaneousGesture 与系统手势共存触发
                    // v2.0.109b：onChanged（down 瞬间）记录键盘可见状态——键盘开=true 保持，关=false 收回
                    // v3.0.4 fix：云端无语音 → 输入框长按不触发语音转文字（保留系统默认长按）
                    //           （用 .simultaneousGesture 里 if/else 各自挂同类型 LongPressGesture，规避泛型不一致）
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: voiceEnabled ? 0.4 : 3600)
                            .onChanged { _ in
                                pressKeyboardUp = kbEnv.isVisible
                            }
                            .onEnded { _ in
                                guard voiceEnabled else { return }
                                onLongPressInput(pressKeyboardUp)
                            }
                    )
                    .overlay {
                        if text.isEmpty {
                            if transcribing {
                                // v2.0.100：转写中动画（waveform 图标 + 文字脉冲）
                                HStack(spacing: 6) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 12))
                                        .symbolEffect(.pulse)
                                    Text("语音转换中…")
                                        .font(.system(size: 15))
                                }
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .allowsHitTesting(false)
                            } else {
                                Text("输入消息...")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
            }

            // v2.0.88：AI 回答中也可继续发送（消息排队，答完自动逐条回）；
            // 停止按钮独立保留（取消当前回答 + 清空队列）
            if streaming {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.red.opacity(0.8), in: Circle())
                }
                .buttonStyle(.plain)
            }

            // v2.0.96：发送按钮——普通发送；语音模式下点击=退出；长按=进入语音转文字（Siri 彩色图标）
            // v2.0.96b：Button 内置手势会拦截 onLongPressGesture → 改自定义视图 + 显式 Tap/LongPress
            // v2.0.98：onTapGesture+onLongPressGesture 叠加 = 两个独立手势系统在手势激活中改
            //          视图树（voiceMode 切换重建按钮）→ 实测 SIGTRAP 闪退（crash_reports 4 次）。
            //          改用 ExclusiveGesture（长按优先、互斥），onEnded 时手势已结束，视图重建安全。
            // v2.0.100：transcribing 时按钮显示转圈（转换中动画）
            // v2.0.101：转圈旁加红色停止按钮（随时中断转换）；手势只在非转写时挂载（停止按钮独立可点）
            Group {
                if transcribing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .tint(.white)
                            .frame(width: 32, height: 32)
                        Button(action: onCancelTranscribe) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Color.red.opacity(0.85), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Image(systemName: voiceMode ? "waveform" : "arrow.up")
                        .font(.system(size: voiceMode ? 15 : 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                        .gesture(
                            LongPressGesture(minimumDuration: 0.4)
                                .exclusively(before: TapGesture())
                                .onEnded { value in
                                    // .first = 长按成功（语音模式开关）；.second = 轻点（发送/退出）
                                    switch value {
                                    case .first:
                                        // v3.0.4：云端无语音 → 长按等同轻点发送
                                        if voiceEnabled {
                                            onVoiceModeToggle()
                                        } else {
                                            onSend()
                                        }
                                    case .second:
                                        if voiceMode {
                                            onVoiceModeToggle()
                                        } else {
                                            onSend()
                                        }
                                    }
                                }
                        )
                }
            }
            .background(
                LinearGradient(colors: voiceMode ? [.blue, .indigo, .pink] : [.blue, .indigo],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Capsule()
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // v2.0.87e：原生液态玻璃输入栏（iOS 26+）
        .background { Capsule().glassEffect() }
        // v3.2.3 渲染卡死根治：外层阴影移到流光 overlay **之前**——阴影只对静态背景/内容生效，
        // 不再因流光每帧变化触发阴影 CGPath 重算（.ips 8BADF00D 主线程栈铁证：
        // ShapeLayerShadowHelper.updateShadow → Path.cgPath → RenderBox CG::stroker 病态递归卡死）
        .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
        // v2.0.87s：等待回复特效（v2.0.87ay：改回 87 版效果——内部旋转流光，Siri 淡雅）
        // v2.0.96：语音转文字模式同样开启 Siri 流光
        .overlay {
            // v3.2.4：流光在 streaming / voiceMode 均启用（用户拍板：语音模式保留流光视觉）。
            // 卡死防护靠 v3.2.3 三件套（流光无 shadow + 15fps + 外层阴影静态化在 overlay 前），
            // voiceMode 期间唯一动态视图即此流光，无 shadow 不触发 stroker 病态路径。
            if (streaming || voiceMode) && UserDefaults.standard.bool(forKey: "qingliao_input_glow") {
                // v2.0.139 性能：流光 60→30fps（旋转渐变肉眼无差，重绘开销减半）
                // v3.2.3：30→15fps + **去掉 .shadow**——每帧变化的渐变+阴影=每帧送 stroker 算圆角
                // 阴影路径（iOS 27 RenderBox 卡死源）。旋转渐变无锐边，15fps 肉眼无差，观感不变。
                let schedule: AnimationTimelineSchedule = .animation(minimumInterval: 1.0 / 15.0)
                TimelineView(schedule) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let angle = (t * 70).truncatingRemainder(dividingBy: 360)
                    // 内部流光：Siri 淡雅蓝紫粉红旋转（87 版效果）
                    Capsule().fill(
                        AngularGradient(
                            colors: [.blue.opacity(0.22), .indigo.opacity(0.22),
                                     .pink.opacity(0.22), .red.opacity(0.16), .blue.opacity(0.22)],
                            center: .center, angle: .degrees(angle)
                        )
                    )
                    .allowsHitTesting(false)   // v2.0.87al：不拦截点击（停止按钮可点）
                }
            } else {
                Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.8)
            }
        }
        .padding(.horizontal, 18)   // v2.0.87aw：输入框宽度收窄（12→18）
    }
}

