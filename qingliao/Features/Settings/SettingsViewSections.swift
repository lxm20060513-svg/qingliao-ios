import SwiftUI

// MARK: - Section 计算属性（body 瘦身：500 行 → 8 个独立段，SwiftUI diff 只遍历变化段）

extension SettingsView {

    @ViewBuilder var accountSection: some View {
        SectionHeader("账号与安全")
        VStack(spacing: 0) {
            SettingRow(icon: "person.crop.circle.fill", iconColor: .blue, title: auth.username, value: "已登录")
            Divider().padding(.leading, 52)
            SettingRow(icon: "key.horizontal.fill", iconColor: .gray, title: "修改密码", chevron: true)
                .onTapGesture { showPasswordSheet = true }
            Divider().padding(.leading, 52)
            toggleRow(icon: "faceid", iconColor: .blue, title: "Face ID 登录", isOn: $faceIDLogin)
                .onChange(of: faceIDLogin) { _, on in
                    if on { requestFaceIDAuth() } else { FaceIDStore.clear() }
                }
                .alert("Face ID 未授权", isPresented: $faceIDAuthFailed) {
                    Button("好的", role: .cancel) {}
                } message: {
                    Text("未通过系统 Face ID 验证，登录页快捷登录不可用。")
                }
            Divider().padding(.leading, 52)
            toggleRow(icon: "lock.fill", iconColor: .green, title: "App 锁", isOn: $appLockOn)
                .onChange(of: appLockOn) { _, on in
                    if on { requestAppLockAuth() }
                }
                .alert("Face ID 未授权", isPresented: $appLockAuthFailed) {
                    Button("好的", role: .cancel) {}
                } message: {
                    Text("未通过系统 Face ID 验证，App 锁不可用。")
                }
        }
        .glassListCard()
    }

    @ViewBuilder var connectionSection: some View {
        SectionHeader("连接与模型")
        VStack(spacing: 0) {
            SettingRow(icon: "globe.asia.australia.fill", iconColor: .green, title: "连接设置", chevron: true)
                .onTapGesture { showConnSettings = true }
            Divider().padding(.leading, 52)
            SettingRow(icon: "cpu.fill", iconColor: .orange, title: "模型管理", value: currentModel, chevron: true)
                .onTapGesture { showModelSheet = true }
            Divider().padding(.leading, 52)
            SettingRow(icon: "bubble.left.and.bubble.right.fill", iconColor: .blue,
                       title: "微信通道模型", value: wechatChannelModel, chevron: true)
                .onTapGesture { showWechatChannel = true }
            Divider().padding(.leading, 52)
            SettingRow(icon: "house.fill", iconColor: .purple, title: "HA 设置", chevron: true)
                .onTapGesture { showHASettings = true }
            Divider().padding(.leading, 52)
            localModelToggle
        }
        .glassListCard()
    }

    @ViewBuilder var localModelToggle: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.indigo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("本地模型").font(.system(size: 14, weight: .medium))
                Text(localStatusText).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: $localModelOn).labelsHidden().scaleEffect(0.8).tint(.green)
                .onChange(of: localModelOn) { _, new in
                    Task {
                        _ = try? await auth.json("/api/local/toggle", method: "POST", body: ["on": new])
                        await loadLocalStatus()
                    }
                }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        if localModelOn {
            Divider().padding(.leading, 52)
            SettingRow(icon: "shippingbox.fill", iconColor: .indigo, title: "管理模型",
                       value: "已装列表 / 拉取新模型", chevron: true)
                .onTapGesture { showLocalModels = true }
            Divider().padding(.leading, 52)
            Button { Task { await checkLocalUpdate() } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.teal, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("检查模型更新").font(.system(size: 14, weight: .medium))
                        Text(localUpdateText).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if localChecking { ProgressView().controlSize(.small) }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
    }

    @ViewBuilder var aiSection: some View {
        SectionHeader("AI 智能")
        VStack(spacing: 0) {
            SettingRow(icon: "books.vertical.fill", iconColor: .green, title: "知识库", value: "文档检索问答", chevron: true)
                .onTapGesture { showKB = true }
            Divider().padding(.leading, 52)
            SettingRow(icon: "brain.head.profile", iconColor: .pink, title: "AI 记忆", value: "\(memoryCount) 条", chevron: true)
                .onTapGesture { showMemory = true }
            Divider().padding(.leading, 52)
            // v3.0.81：上下文自动管理
            toggleRow(icon: "arrow.down.circle.fill", iconColor: .purple,
                      title: "上下文自动压缩", subtitle: "token超限时AI摘要压缩历史消息", isOn: $contextAutoCompress)
                .onChange(of: contextAutoCompress) { _, new in
                    UserDefaults.standard.set(new, forKey: "qingliao_context_auto_compress")
                }
            if contextAutoCompress {
                Divider().padding(.leading, 52)
                HStack {
                    Text("压缩阈值")
                        .font(.system(size: 15))
                    Spacer()
                    Text("\(contextThreshold) tokens")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Stepper("", value: $contextThreshold, in: 1000...16000, step: 500)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .onChange(of: contextThreshold) { _, new in
                    UserDefaults.standard.set(new, forKey: "qingliao_context_threshold")
                }
            }
            Divider().padding(.leading, 52)
            toggleRow(icon: "message.badge.filled.fill", iconColor: .green,
                      title: "微信推送", subtitle: "自动化执行结果推送到微信", isOn: $pushWeixin)
                .onChange(of: pushWeixin) { _, new in
                    Task { _ = try? await auth.json("/api/push/settings", method: "POST", body: ["pushWeixin": new]) }
                }
        }
        .glassListCard()
    }

    @ViewBuilder var dataSection: some View {
        SectionHeader("数据与自动化")
        VStack(spacing: 0) {
            SettingRow(icon: "key.fill", iconColor: .teal, title: "密码管理", value: "\(secretCount) 条凭据", chevron: true)
                .onTapGesture { showSecrets = true }
            Divider().padding(.leading, 52)
            SettingRow(icon: "clock.badge.fill", iconColor: .red, title: "定时任务", chevron: true)
                .onTapGesture { showTasks = true }
            Divider().padding(.leading, 52)
            SettingRow(icon: "clock.arrow.circlepath", iconColor: .orange, title: "执行历史",
                       value: "自动化/场景执行记录", chevron: true)
                .onTapGesture { showHistory = true }
            Divider().padding(.leading, 52)
            SettingRow(icon: "doc.text.fill", iconColor: .orange, title: "日志", chevron: true)
                .onTapGesture { showLogs = true }
            // v3.0.74：钉一钉存储路径
            Divider().padding(.leading, 52)
            SettingRow(icon: "pin.fill", iconColor: .indigo, title: "钉一钉存储",
                       value: pinPathDisplay, chevron: true)
                .onTapGesture { showPinPath = true }
        }
        .glassListCard()
        .sheet(isPresented: $showPinPath) {
            PinPathSheet()
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder var agentSection: some View {
        SectionHeader("Agent 设置")
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(LinearGradient(colors: [.blue, .indigo, .pink],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent 智能回复").font(.system(size: 15)).foregroundStyle(.primary)
                    Text(agentOn ? "已开启：查磁盘/内存/控制设备等直接调用工具" : "已关闭：所有对话走普通 AI 回复")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $agentOn).labelsHidden().scaleEffect(0.8).tint(.green)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            // v3.0.20：Agent 模型自定义（可单独指定 Agent 使用的模型，不依赖主模型）
            Divider().padding(.leading, 52)
            SettingRow(icon: "cpu.fill", iconColor: .indigo, title: "Agent 模型",
                       value: agentModel.isEmpty ? "跟随主模型" : agentModel, chevron: true)
                .onTapGesture { showAgentModelSheet = true }
            Divider().padding(.leading, 52)
            SettingRow(icon: "questionmark.circle.fill", iconColor: .gray, title: "使用说明", chevron: false)
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showAgentHelp.toggle() } }
            if showAgentHelp {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent 回复 = 直连模型 + NAS 本地工具，不经 Hermes。")
                    Text("▸ 直接问：查磁盘/内存/温度、控制设备、执行场景，自动调用工具回复")
                    Text("▸ 记忆规则：说「以后XX都用agent」，下次同类问题直接 Agent 处理")
                    Text("▸ 复杂任务（联网搜索/写脚本/操作文件）自动转交 Hermes 执行")
                    Text("▸ 普通聊天走 Hermes（带 AI 记忆）；Agent 只参考轻聊记忆与规则")
                    Text("▸ 关闭开关后：所有对话走普通 AI 回复")
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
            Divider().padding(.leading, 52)
            SettingRow(icon: "text.badge.plus", iconColor: .orange, title: "Agent 关键词", value: "分流匹配词管理", chevron: true)
                .onTapGesture { showAgentKeywords = true }
            Divider().padding(.leading, 52)
            SettingRow(icon: "brain.head.profile", iconColor: .purple, title: "Agent 记忆",
                       value: agentRuleCount > 0 ? "\(agentRuleCount) 条规则" : "暂无", chevron: true)
                .onTapGesture { showAgentMemory = true }
        }
        .glassListCard()
    }

    @ViewBuilder var appearanceSection: some View {
        SectionHeader("外观与显示")
        VStack(spacing: 0) {
            SettingRow(icon: "circle.lefthalf.filled", iconColor: .purple, title: "外观", value: appearanceName, chevron: true)
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showAppearance = true } }
            if showAppearanceOptions {
                HStack(spacing: 8) {
                    appearanceOption("深色", value: "dark")
                    appearanceOption("浅色", value: "light")
                    appearanceOption("跟随系统", value: "system")
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
                Divider().padding(.leading, 52)
                toggleRow(icon: "waveform", iconColor: .purple, title: "输入框流光光效", isOn: $glowOn)
                Divider().padding(.leading, 52)
                toggleRow(icon: "sparkles.rectangle.stack", iconColor: .indigo, title: "Siri 边框发光", isOn: $siriGlowOn)
                if siriGlowOn {
                    siriGlowSliders
                }
                Divider().padding(.leading, 52)
                SettingRow(icon: "text.line.first.and.arrowtriangle.forward", iconColor: .indigo,
                           title: "AI 输出行高", value: String(format: "%.1f", aiLineSpacing))
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showLineSpacingOptions.toggle() } }
                if showLineSpacingOptions {
                    HStack(spacing: 10) {
                        Text("紧凑").font(.system(size: 12)).foregroundStyle(.secondary)
                        Slider(value: $aiLineSpacing, in: 0...6, step: 0.5).tint(Color.accentColor)
                        Text("宽松").font(.system(size: 16)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.bottom, 10)
                }
                Divider().padding(.leading, 52)
                toggleRow(icon: "circle.circle.fill", iconColor: .accentColor, title: "智能球", isOn: $ballInput)
            }
        }
        .glassListCard()
    }

    @ViewBuilder var siriGlowSliders: some View {
        Divider().padding(.leading, 52)
        glowSlider("亮度", value: $glowBrightness, range: 0.2...1.5, format: "%.0f%%")
        glowSlider("呼吸频率", value: $glowFreq, range: 0.5...6.0, format: "%.1f")
        glowSlider("呼吸幅度", value: $glowAmp, range: 0...0.4, format: "%.2f")
        glowSlider("光带范围", value: $glowWidth, range: 10...44, format: "%.0fpt")
            .padding(.bottom, 6)
    }

    @ViewBuilder var aboutSection: some View {
        SectionHeader("关于")
        VStack(spacing: 0) {
            SettingRow(icon: "info.circle.fill", iconColor: .gray, title: "关于轻聊", chevron: true)
                .onTapGesture { showAbout = true }
        }
        .glassListCard()
    }

    @ViewBuilder var logoutButton: some View {
        SectionHeader("")
        Button {
            confirmLogout = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                Text("退出登录")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 40).padding(.vertical, 13)
            .background(Color.red.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .confirmationDialog("退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { auth.logout() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后回到登录页，可切换本地 AI / 云端 AI 模式。云端配置（API Key）仍保留在手机本地。")
        }
        .padding(.top, 2)
    }
}
