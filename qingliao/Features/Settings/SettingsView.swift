import SwiftUI
import LocalAuthentication

// MARK: - 设置页（iOS 设置风格分组列表，全部功能行可用）

struct SettingsView: View {
    @Environment(AuthStore.self) private var auth
    @AppStorage("qingliao_appearance") private var appearance = "system"   // dark/light/system（默认跟随系统）

    // v2.0.83c：连接设置二级页（服务器地址/测试连接/会话存储位置收进二级）
    @State private var showConnSettings = false
    @State private var showPasswordSheet = false
    @State private var showSecrets = false
    // v2.0.81：知识库页面
    @State private var showKB = false
    // v2.0.87：AI 记忆
    @State private var showMemory = false
    @State private var memoryCount = 0
    @State private var showTasks = false
    @State private var showLogs = false
    @State private var showAppearanceOptions = false
    @State private var scrollPos = ScrollPosition()
    @State private var showModelSheet = false
    @State private var showAbout = false
    @State private var secretCount = 0
    @State private var showHASettings = false
    @State private var haAddress = ""
    // v2.0.38：聊天字体大小（12-20，默认 14；Double 供 Slider 绑定）
    @AppStorage("qingliao_font_size") private var fontSize = 15.0   // v2.0.87r：默认15号
    // v2.0.87am：天气城市（手动输入）
    @AppStorage("qingliao_weather_city") private var weatherCity = ""
    @State private var showWeatherCity = false
    // v2.0.101：Agent 使用说明内联展开
    @State private var showAgentHelp = false
    // v2.0.105：Agent 关键词管理弹窗
    @State private var showAgentKeywords = false
    // v2.0.113：Agent 记忆弹窗 + 计数
    @State private var showAgentMemory = false
    @State private var agentRuleCount = 0
    // v2.0.116：执行历史弹窗
    @State private var showHistory = false
    // v2.0.117：本地模型（Ollama 断网兜底）
    @AppStorage("qingliao_local_model") private var localModelOn = false
    @State private var localStatusText = "未开启"
    @State private var localUpdateText = "断网兜底用本地模型"
    @State private var localChecking = false
    // v2.0.118：本地模型管理弹窗
    @State private var showLocalModels = false
    // v2.0.113：微信推送开关（同步后端 push_settings.json）
    @AppStorage("qingliao_push_weixin") private var pushWeixin = true
    // v2.0.87ax：输入框流光光效开关
    @AppStorage("qingliao_input_glow") private var glowOn = true
    // v2.0.87bb：Siri 边框发光开关
    @AppStorage("qingliao_siri_glow") private var siriGlowOn = true
    // v2.0.90a：Siri 动效自定义参数（默认 = v2.0.87bn 定稿效果）
    @AppStorage("qingliao_siri_glow_brightness") private var glowBrightness = 1.0
    @AppStorage("qingliao_siri_glow_freq") private var glowFreq = 2.2
    @AppStorage("qingliao_siri_glow_amp") private var glowAmp = 0.18
    @AppStorage("qingliao_siri_glow_width") private var glowWidth = 22.0
    // v2.0.88：Face ID 登录开关（关闭后删除 Keychain 凭据，登录页不再显示快捷按钮）
    @AppStorage("qingliao_faceid_login") private var faceIDLogin = true
    @State private var faceIDAuthFailed = false   // v2.0.89f：开关打开时系统授权失败提示
    // v2.0.92：App 锁开关（启动时 Face ID 验证）
    @AppStorage("qingliao_app_lock") private var appLockOn = false
    @State private var appLockAuthFailed = false
    @State private var showFontOptions = false
    // v2.0.45：隐藏 Dock 栏开关
    @AppStorage("qingliao_hide_dock") private var hideDock = false
    // v2.0.98：Agent 智能回复开关（关闭后请求不带 agent 能力，走普通 LLM 回复）
    @AppStorage("qingliao_agent_enabled") private var agentOn = true

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "设置")
            ScrollView {
                VStack(spacing: 0) {
                    // 账号与安全
                    SectionHeader("账号与安全")
                    VStack(spacing: 0) {
                        SettingRow(icon: "person.crop.circle.fill", iconColor: .blue, title: auth.username, value: "已登录")
                        Divider().padding(.leading, 52)
                        SettingRow(icon: "key.horizontal.fill", iconColor: .gray, title: "修改密码", chevron: true)
                            .onTapGesture { showPasswordSheet = true }
                        // Face ID 登录（登录页快捷登录开关；关闭即删除已存凭据）
                        Divider().padding(.leading, 52)
                        HStack(spacing: 12) {
                            Image(systemName: "faceid")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.blue, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text("Face ID 登录")
                                .font(.system(size: 15))
                                .foregroundStyle(.primary)
                            Spacer()
                            Toggle("", isOn: $faceIDLogin)
                                .labelsHidden()
                                .scaleEffect(0.8)
                                .tint(.green)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .onChange(of: faceIDLogin) { _, on in
                            if on {
                                requestFaceIDAuth()
                            } else {
                                FaceIDStore.clear()
                            }
                        }
                        .alert("Face ID 未授权", isPresented: $faceIDAuthFailed) {
                            Button("好的", role: .cancel) {}
                        } message: {
                            Text("未通过系统 Face ID 验证，登录页快捷登录不可用。可稍后在系统设置中允许轻聊使用 Face ID 后重新打开此开关。")
                        }
                        // App 锁（启动时 Face ID 验证；与 Face ID 登录相互独立）
                        Divider().padding(.leading, 52)
                        HStack(spacing: 12) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.green, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text("App 锁")
                                .font(.system(size: 15))
                                .foregroundStyle(.primary)
                            Spacer()
                            Toggle("", isOn: $appLockOn)
                                .labelsHidden()
                                .scaleEffect(0.8)
                                .tint(.green)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .onChange(of: appLockOn) { _, on in
                            if on {
                                requestAppLockAuth()
                            }
                        }
                        .alert("Face ID 未授权", isPresented: $appLockAuthFailed) {
                            Button("好的", role: .cancel) {}
                        } message: {
                            Text("未通过系统 Face ID 验证，App 锁不可用。可稍后在系统设置中允许轻聊使用 Face ID 后重新打开此开关。")
                        }
                    }
                    .glassListCard()

                    // 连接与模型
                    SectionHeader("连接与模型")
                    VStack(spacing: 0) {
                        // v2.0.83c：服务器地址收进二级「连接设置」（v2.0.83f：不显示地址，只留标题）
                        SettingRow(icon: "globe.asia.australia.fill", iconColor: .green, title: "连接设置", value: nil, chevron: true)
                            .onTapGesture { showConnSettings = true }
                        Divider().padding(.leading, 52)
                        SettingRow(icon: "cpu.fill", iconColor: .orange, title: "模型管理", value: currentModel, chevron: true)
                            .onTapGesture { showModelSheet = true }
                        Divider().padding(.leading, 52)
                        SettingRow(icon: "house.fill", iconColor: .purple, title: "HA 设置", value: nil, chevron: true)
                            .onTapGesture { showHASettings = true }
                        // v2.0.117：本地模型（Ollama 断网兜底）——开关控制容器 + 状态 + 检查更新
                        Divider().padding(.leading, 52)
                        HStack(spacing: 12) {
                            Image(systemName: "cpu")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.indigo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("本地模型")
                                    .font(.system(size: 14, weight: .medium))
                                Text(localStatusText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: $localModelOn)
                                .labelsHidden()
                                .scaleEffect(0.8)
                                .tint(.green)
                                .onChange(of: localModelOn) { _, new in
                                    Task {
                                        _ = try? await auth.json("/api/local/toggle", method: "POST",
                                                                 body: ["on": new])
                                        await loadLocalStatus()
                                    }
                                }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        if localModelOn {
                            Divider().padding(.leading, 52)
                            // v2.0.118：管理模型（已装列表 + 自主拉取）
                            SettingRow(icon: "shippingbox.fill", iconColor: .indigo, title: "管理模型",
                                       value: "已装列表 / 拉取新模型", chevron: true)
                                .onTapGesture { showLocalModels = true }
                            Divider().padding(.leading, 52)
                            Button {
                                Task { await checkLocalUpdate() }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 28, height: 28)
                                        .background(Color.teal, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("检查模型更新")
                                            .font(.system(size: 14, weight: .medium))
                                        Text(localUpdateText)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    if localChecking {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                        }
                    }
                    .glassListCard()

                    // AI 智能
                    SectionHeader("AI 智能")
                    VStack(spacing: 0) {
                        // v2.0.81：知识库（文档上传 → @知识库 检索问答）
                        SettingRow(icon: "books.vertical.fill", iconColor: .green, title: "知识库", value: "文档检索问答", chevron: true)
                            .onTapGesture { showKB = true }
                        Divider().padding(.leading, 52)
                        // v2.0.87：AI 记忆（记住用户偏好 → 对话自动参考）
                        SettingRow(icon: "brain.head.profile", iconColor: .pink, title: "AI 记忆", value: "\(memoryCount) 条", chevron: true)
                            .onTapGesture { showMemory = true }
                        // v2.0.113：微信推送开关（自动化执行结果 → 微信消息）
                        Divider().padding(.leading, 52)
                        HStack(spacing: 12) {
                            Image(systemName: "message.badge.filled.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.green, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("微信推送")
                                    .font(.system(size: 14, weight: .medium))
                                Text("自动化执行结果推送到微信")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Toggle("", isOn: $pushWeixin)
                                .labelsHidden()
                                .scaleEffect(0.8)
                                .tint(.green)
                                .onChange(of: pushWeixin) { _, new in
                                    Task {
                                        _ = try? await auth.json("/api/push/settings", method: "POST",
                                                                 body: ["pushWeixin": new])
                                    }
                                }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                    }
                    .glassListCard()

                    // 数据与自动化
                    SectionHeader("数据与自动化")
                    VStack(spacing: 0) {
                        SettingRow(icon: "key.fill", iconColor: .teal, title: "密码管理", value: "\(secretCount) 条凭据", chevron: true)
                            .onTapGesture { showSecrets = true }
                        Divider().padding(.leading, 52)
                        SettingRow(icon: "clock.badge.fill", iconColor: .red, title: "定时任务", chevron: true)
                            .onTapGesture { showTasks = true }
                        // v2.0.116：执行历史（自动化 + 场景执行记录）
                        Divider().padding(.leading, 52)
                        SettingRow(icon: "clock.arrow.circlepath", iconColor: .orange, title: "执行历史",
                                   value: "自动化/场景执行记录", chevron: true)
                            .onTapGesture { showHistory = true }
                        Divider().padding(.leading, 52)
                        SettingRow(icon: "doc.text.fill", iconColor: .orange, title: "日志", chevron: true)
                            .onTapGesture { showLogs = true }
                    }
                    .glassListCard()

                    // Agent 设置（v2.0.100：Agent 智能回复 + 使用说明 + 关键词 + Agent 记忆）
                    SectionHeader("Agent 设置")
                    VStack(spacing: 0) {
                        // Agent 智能回复开关
                        HStack(spacing: 12) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(LinearGradient(colors: [.blue, .indigo, .pink],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Agent 智能回复")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.primary)
                                Text(agentOn ? "已开启：查磁盘/内存/控制设备等直接调用工具" : "已关闭：所有对话走普通 AI 回复")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $agentOn)
                                .labelsHidden()
                                .scaleEffect(0.8)
                                .tint(.green)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        // v2.0.101：使用说明（内联展开）
                        Divider().padding(.leading, 52)
                        HStack(spacing: 12) {
                            Image(systemName: "questionmark.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.gray, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text("使用说明")
                                .font(.system(size: 15))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(showAgentHelp ? 180 : 0))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
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
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                        }
                        // v2.0.105：Agent 分流关键词管理（查看内置 + 添加/删除自定义）
                        Divider().padding(.leading, 52)
                        SettingRow(icon: "text.badge.plus", iconColor: .orange, title: "Agent 关键词", value: "分流匹配词管理", chevron: true)
                            .onTapGesture { showAgentKeywords = true }
                        // v2.0.113：Agent 记忆（"以后XX都用agent"规则，弹窗管理删除）
                        Divider().padding(.leading, 52)
                        SettingRow(icon: "brain.head.profile", iconColor: .purple, title: "Agent 记忆",
                                   value: agentRuleCount > 0 ? "\(agentRuleCount) 条规则" : "暂无",
                                   chevron: true)
                            .onTapGesture { showAgentMemory = true }
                    }
                    .glassListCard()

                    // 外观与显示
                    SectionHeader("外观与显示")
                    VStack(spacing: 0) {
                        SettingRow(icon: "circle.lefthalf.filled", iconColor: .purple, title: "外观", value: appearanceName, chevron: true)
                            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showAppearanceOptions.toggle() } }
                        if showAppearanceOptions {
                            // 内联三选（非弹窗）
                            HStack(spacing: 8) {
                                appearanceOption("深色", value: "dark")
                                appearanceOption("浅色", value: "light")
                                appearanceOption("跟随系统", value: "system")
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                            // v2.0.46：Dock 栏设置（外观二级菜单内，图标对齐 SettingRow 风格）
                            Divider().padding(.leading, 52)
                            HStack(spacing: 12) {
                                Image(systemName: "rectangle.bottomthird.inset.filled")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Color.teal, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                Text("Dock 栏设置")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Toggle("", isOn: $hideDock)
                                    .labelsHidden()
                                    .scaleEffect(0.8)
                                    .tint(.green)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onChange(of: hideDock) { _, on in
                                if on {
                                    DockVisibility.shared.forceHidden = true
                                    DockVisibility.shared.hidden = true
                                } else {
                                    DockVisibility.shared.forceHidden = false
                                    DockVisibility.shared.reset()
                                }
                            }
                            .padding(.bottom, 4)
                            // v2.0.87ax/ba：输入框流光光效开关（外观二级菜单内，Dock 栏设置同风格）
                            Divider().padding(.leading, 52)
                            HStack(spacing: 12) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Color.purple, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                Text("输入框流光光效")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Toggle("", isOn: $glowOn)
                                    .labelsHidden()
                                    .scaleEffect(0.8)
                                    .tint(.green)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            // v2.0.87bb：AI 回答 Siri 边框发光
                            Divider().padding(.leading, 52)
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles.rectangle.stack")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Color.indigo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                Text("Siri 边框发光")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Toggle("", isOn: $siriGlowOn)
                                    .labelsHidden()
                                    .scaleEffect(0.8)
                                    .tint(.green)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            // v2.0.90a：Siri 动效自定义（开关开启时内联展开，实时生效）
                            if siriGlowOn {
                                Divider().padding(.leading, 52)
                                HStack(spacing: 10) {
                                    Text("亮度").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                                    Slider(value: $glowBrightness, in: 0.2...1.5).tint(Color.accentColor)
                                    Text(String(format: "%.0f%%", glowBrightness * 100)).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 4)
                                HStack(spacing: 10) {
                                    Text("呼吸频率").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                                    Slider(value: $glowFreq, in: 0.5...6.0).tint(Color.accentColor)
                                    Text(String(format: "%.1f", glowFreq)).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 4)
                                HStack(spacing: 10) {
                                    Text("呼吸幅度").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                                    Slider(value: $glowAmp, in: 0...0.4).tint(Color.accentColor)
                                    Text(String(format: "%.2f", glowAmp)).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 4)
                                HStack(spacing: 10) {
                                    Text("光带范围").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                                    Slider(value: $glowWidth, in: 10...44).tint(Color.accentColor)
                                    Text(String(format: "%.0fpt", glowWidth)).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 4)
                                .padding(.bottom, 6)
                            }
                        }
                        // v2.0.87am：天气城市（手动输入，看板右上角天气）
                        SettingRow(icon: "location.fill", iconColor: .teal, title: "天气城市", value: weatherCity.isEmpty ? "未设置" : weatherCity, chevron: false)
                            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showWeatherCity.toggle() } }
                        if showWeatherCity {
                            HStack(spacing: 10) {
                                TextField("如：上海 / 北京", text: $weatherCity)
                                    .font(.system(size: 13))
                                    .textInputAutocapitalization(.never)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .onSubmit {
                                        UserDefaults.standard.set(weatherCity.trimmingCharacters(in: .whitespaces), forKey: "qingliao_weather_city")
                                        withAnimation { showWeatherCity = false }
                                    }
                                Button("保存") {
                                    UserDefaults.standard.set(weatherCity.trimmingCharacters(in: .whitespaces), forKey: "qingliao_weather_city")
                                    withAnimation { showWeatherCity = false }
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                        }
                        // v2.0.38：聊天字体大小（内联滑条，外观同款交互）
                        SettingRow(icon: "textformat.size", iconColor: .blue, title: "聊天字体大小", value: "\(Int(fontSize))", chevron: false)
                            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showFontOptions.toggle() } }
                        if showFontOptions {
                            HStack(spacing: 10) {
                                Text("小").font(.system(size: 12)).foregroundStyle(.secondary)
                                Slider(value: $fontSize, in: 12...20, step: 1)
                                    .tint(Color.accentColor)
                                Text("大").font(.system(size: 16)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                        }
                        Divider().padding(.leading, 52)
                        SettingRow(icon: "info.circle.fill", iconColor: .gray, title: "关于轻聊", value: "2.0", chevron: true)
                            .onTapGesture { showAbout = true }
                        Divider().padding(.leading, 52)
                        Button {
                            auth.logout()
                        } label: {
                            HStack {
                                Spacer()
                                Text("退出登录")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.red)
                                Spacer()
                            }
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .glassListCard()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 100)
            }
            .scrollPosition($scrollPos)
            // v2.0.86h：Dock 滑动隐藏已删除（从未生效，手动开关替代）
        }
        .sheet(isPresented: $showPasswordSheet) {
            PasswordSheet()
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showTasks) {
            TasksView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showLogs) {
            LogsView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showConnSettings) {
            ConnSettingsView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showModelSheet) {
            ModelSheet(current: currentModel)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSecrets) {
            SecretsView()
                .presentationDetents([.medium, .large])
        }
        // v2.0.81：知识库
        .sheet(isPresented: $showKB) {
            KBView()
                .presentationDetents([.medium, .large])
        }
        // v2.0.87：AI 记忆
        .sheet(isPresented: $showMemory) {
            MemoryView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showHASettings) {
            HASettingsSheet()
                .presentationDetents([.medium])
        }
        // v2.0.105：Agent 关键词管理
        .sheet(isPresented: $showAgentKeywords) {
            AgentKeywordsSheet()
        }
        // v2.0.113：Agent 记忆弹窗（同 AI 记忆样式）
        .sheet(isPresented: $showAgentMemory) {
            AgentMemorySheet()
        }
        // v2.0.116：执行历史弹窗
        .sheet(isPresented: $showHistory) {
            HistorySheet()
        }
        // v2.0.118：本地模型管理弹窗
        .sheet(isPresented: $showLocalModels) {
            LocalModelsSheet()
        }
        // v2.0.102：切回设置页刷新计数（密码管理/记忆增删后行尾数字即时更新，原只有 .task 首刷）
        .onAppear { Task { await loadCounts() } }
        .task { await loadCounts() }
    }

    /// v2.0.117：加载本地模型状态（容器 + 已装模型）
    private func loadLocalStatus() async {
        if let j = try? await auth.json("/api/local/status") {
            let up = (j["container"] as? String) == "up"
            let models = (j["models"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "" }
            if up {
                localStatusText = "运行中" + (models.isEmpty ? "" : " · " + models.prefix(2).joined(separator: " / "))
            } else {
                localStatusText = "已停止（点开关开启）"
            }
        }
    }

    /// v2.0.117：检查模型更新
    private func checkLocalUpdate() async {
        guard !localChecking else { return }
        localChecking = true
        defer { localChecking = false }
        if let j = try? await auth.json("/api/local/check-update") {
            localUpdateText = (j["message"] as? String) ?? "检查完成"
        } else {
            localUpdateText = "检查失败，请稍后重试"
        }
    }

    /// v2.0.102：加载凭据/记忆计数（设置页行尾显示）
    private func loadCounts() async {
        if let j = try? await auth.json("/api/secrets") {
            secretCount = (j["secrets"] as? [Any])?.count ?? 0
        }
        if let j = try? await auth.json("/api/memory/list") {
            memoryCount = (j["entries"] as? [String] ?? []).count
        }
        // v2.0.113：同步微信推送开关（后端为准）
        if let j = try? await auth.json("/api/push/settings"),
           let v = j["pushWeixin"] as? Bool {
            pushWeixin = v
        }
        // v2.0.113：Agent 记忆条数（行尾数字）
        if let j = try? await auth.json("/api/agent/rules") {
            agentRuleCount = (j["rules"] as? [Any] ?? []).count
        }
    }

    private func appearanceOption(_ name: String, value: String) -> some View {
        Button {
            appearance = value
            withAnimation(.easeOut(duration: 0.2)) { showAppearanceOptions = false }
        } label: {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(appearance == value ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(appearance == value ? Color.accentColor : Color(uiColor: .systemGray5))
                )
        }
        .buttonStyle(.plain)
    }

    private var appearanceName: String {
        switch appearance {
        case "light": return "浅色"
        case "system": return "跟随系统"
        default: return "深色"
        }
    }

    /// 当前默认模型（UserDefaults）
    private var currentModel: String {
        UserDefaults.standard.string(forKey: "qingliao_model") ?? "deepseek-v4-flash"
    }

    /// v2.0.89f：打开 Face ID 开关时立即申请系统权限（用户实测"点开关没有权限申请"）
    private func requestFaceIDAuth() {
        let context = LAContext()
        var err: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            faceIDLogin = false   // 设备不支持/已被拒绝 → 回滚开关
            faceIDAuthFailed = true
            return
        }
        context.localizedReason = "用于登录页一键登录轻聊"
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "用于登录页一键登录轻聊") { success, error in
            DispatchQueue.main.async {
                if success { return }
                // v2.0.102：用户主动取消（userCancel）不算失败——保留开关不弹提示
                if let la = error as? LAError, la.code == .userCancel { return }
                // 拒绝/系统错误 → 回滚开关，提示去系统设置开启
                faceIDLogin = false
                faceIDAuthFailed = true
            }
        }
    }

    /// v2.0.92：打开 App 锁开关时申请权限（逻辑同 Face ID 登录）
    private func requestAppLockAuth() {
        let context = LAContext()
        var err: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            appLockOn = false
            appLockAuthFailed = true
            return
        }
        context.localizedReason = "用于启动时解锁轻聊"
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "用于启动时解锁轻聊") { success, error in
            DispatchQueue.main.async {
                if success { return }
                // v2.0.102：用户主动取消不算失败——保留开关不弹提示
                if let la = error as? LAError, la.code == .userCancel { return }
                appLockOn = false
                appLockAuthFailed = true
            }
        }
    }
}

// MARK: - 服务器地址修改

struct ServerSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var server = ""
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("服务器地址")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)

            Text("修改后需重新登录")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 4)

            TextField("server.example.com:8080", text: $server)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.top, 14)

            Button {
                var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.hasPrefix("http") { s = "http://" + s }
                auth.serverURL = s
                UserDefaults.standard.set(s, forKey: "qingliao_server")
                saved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    auth.logout()
                }
            } label: {
                Text("保存并重新登录")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.top, 12)

            if saved {
                Text("已保存，正在返回登录...")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            server = auth.serverURL.replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: "")
        }
    }
}

// MARK: - 修改密码

struct PasswordSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""   // v2.0.83c：新密码二次确认
    @State private var result: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("修改密码")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)

            SecureField("当前密码", text: $oldPassword)
                .font(.system(size: 14))
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.top, 14)

            SecureField("新密码", text: $newPassword)
                .font(.system(size: 14))
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.top, 10)

            // v2.0.83c：新密码二次确认（两次一致才可提交）
            SecureField("确认新密码", text: $confirmPassword)
                .font(.system(size: 14))
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.top, 10)
            if !confirmPassword.isEmpty && confirmPassword != newPassword {
                Text("两次输入的密码不一致")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 5)
            }

            Button {
                changePassword()
            } label: {
                Text(busy ? "提交中..." : "确认修改")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.top, 12)

            if let r = result {
                Text(r)
                    .font(.system(size: 12))
                    .foregroundStyle(r.contains("成功") ? Color.green : Color.red)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func changePassword() {
        // v2.0.83c：新密码二次确认校验
        guard !oldPassword.isEmpty, !newPassword.isEmpty, !busy else { return }
        guard newPassword == confirmPassword else {
            result = "两次输入的密码不一致"
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let j = try await auth.json("/api/auth/change-password", method: "POST", body: [
                    "old": oldPassword, "new": newPassword
                ])
                if (j["ok"] as? Bool) ?? false {
                    result = "✅ 修改成功，请重新登录"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        auth.logout()
                    }
                } else {
                    result = "⚠️ " + ((j["error"] as? String) ?? "修改失败")
                }
            } catch {
                result = "❌ 修改失败，请检查当前密码"
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 5)
    }
}

struct SettingRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var value: String? = nil
    var chevron: Bool = false
    // v2.0.87az：行尾开关（替代独立 Toggle 行，避免错位）
    var toggle: Binding<Bool>? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(iconColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
            Spacer()
            if let value {
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            // v2.0.87az：行尾开关
            if let toggle {
                Toggle("", isOn: toggle)
                    .labelsHidden()
                    .scaleEffect(0.8)
                    .tint(.green)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .contentShape(Rectangle())
    }
}

// MARK: - 会话存储位置设置（NAS 目录，服务器持久化）

struct SessionLocSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let currentPath: String
    @State private var path = ""
    @State private var result: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("会话存储位置")
                .font(.system(size: 17, weight: .bold))
            Text("设置 NAS 上存储会话记录的目录（需为服务器可写路径）")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("如 /volume1/docker/轻聊数据/sessions", text: $path)
                .font(.system(size: 14, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let result {
                Text(result)
                    .font(.system(size: 12))
                    .foregroundStyle(result.hasPrefix("✅") ? Color.green : Color.red)
            }
            Button {
                save()
            } label: {
                HStack {
                    Spacer()
                    if saving { ProgressView().tint(.white) } else { Text("保存") }
                    Spacer()
                }
                .padding(.vertical, 12)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
                .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(saving)
            Spacer()
        }
        .padding(20)
        .onAppear { path = currentPath }
    }

    private func save() {
        saving = true
        result = nil
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { saving = false }
            do {
                let j = try await auth.json("/api/sessions/location", method: "POST", body: ["path": p])
                if (j["ok"] as? Bool) == true {
                    result = "✅ 已保存：" + (j["path"] as? String ?? p)
                } else {
                    result = "❌ " + ((j["error"] as? String) ?? "保存失败")
                }
            } catch {
                result = "❌ 请求失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 模型管理（复刻 PWA/OpenCode Go 面板：分组 + 设为当前 + 同步列表）

struct ModelSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let current: String
    @State private var selected = ""
    @State private var syncing = false
    @State private var syncResult: String?
    // 服务器同步的模型（分组展示）
    @State private var stepfunModels: [String] = []
    @State private var deepseekModels: [String] = []
    // v2.0.83：当前 provider（区分 opencode 的 deepseek 与官方 deepseek——同名模型不能同时勾）
    @AppStorage("qingliao_provider") private var currentProvider = "opencode"
    // v2.0.118：本地模型（Ollama 已安装，自主选择——动态拉取 /api/local/models）
    @State private var localInstalled: [String] = []

    /// opencode 本地预置（官方 /v1/models 端点 403 不开放，本地维护）
    private let localModels: [(String, String)] = [
        ("deepseek-v4-flash", "DeepSeek V4 Flash"),
        ("deepseek-v4-flash-free", "DeepSeek V4 Flash Free"),
        ("deepseek-v4-pro", "DeepSeek V4 Pro"),
        ("kimi-k3", "Kimi K3"),
        ("kimi-k2.7-code", "Kimi K2.7 Code"),
        ("kimi-k2.6", "Kimi K2.6"),
        ("kimi-k2.5", "Kimi K2.5"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头部：🧠 模型管理 + 刷新 + 同步列表 + 在线状态
            HStack(spacing: 8) {
                Text("🧠").font(.system(size: 18))
                Text("模型管理").font(.system(size: 17, weight: .bold))
                Spacer()
                Button { syncList() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                Button { syncList() } label: {
                    Text("同步列表")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            // 在线状态 + 同步结果
            HStack(spacing: 5) {
                Circle().fill(syncing ? Color.orange : Color.green).frame(width: 7, height: 7)
                Text(syncing ? "同步中..." : "OpenCode Go 在线")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let syncResult {
                Text(syncResult)
                    .font(.system(size: 11))
                    .foregroundStyle(syncResult.hasPrefix("✅") ? Color.green : Color.orange)
            }
            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    groupSection("opencode", models: localModels.map { ($0.0, $0.1, "opencode") })
                    if !deepseekModels.isEmpty {
                        // v2.0.83：官方 API 分组标注（与 opencode 的 deepseek 区分）
                        groupSection("deepseek（官方）", models: deepseekModels.map { ($0, $0, "deepseek") })
                    }
                    if !stepfunModels.isEmpty {
                        groupSection("stepfun", models: stepfunModels.map { ($0, $0, "stepfun") })
                    }
                    // v2.0.118：本地模型（动态显示 Ollama 已安装模型——自主选择）
                    if !localInstalled.isEmpty {
                        groupSection("本地模型（断网兜底）", models: localInstalled.map { ($0, $0 + " · 本地", "local") })
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(18)
        .onAppear {
            selected = current
            // v2.0.118：动态拉取本地已装模型（自主选择）
            Task {
                if let j = try? await auth.json("/api/local/models") {
                    localInstalled = (j["models"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "" }
                }
            }
            // 恢复上次同步的模型（UserDefaults 持久化，无需每次点同步）
            if let s = UserDefaults.standard.array(forKey: "qingliao_models_stepfun") as? [String] {
                stepfunModels = s
            }
            if let d = UserDefaults.standard.array(forKey: "qingliao_models_deepseek") as? [String] {
                deepseekModels = d
            }
        }
    }

    /// 分组标题 + 模型行
    private func groupSection(_ group: String, models: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            ForEach(models, id: \.0) { m in
                modelRow(id: m.0, name: m.1, provider: m.2)
            }
        }
    }

    private func modelRow(id: String, name: String, provider: String) -> some View {
        // v2.0.83：当前判定 = 模型 id + provider 双重匹配（opencode 与官方的 deepseek 同名不同源，不能同时勾）
        let isCur = selected == id && currentProvider == provider
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(id)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isCur ? Color.accentColor : Color.primary)
                Text(name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCur {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                    Text("当前").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
            } else {
                Button {
                    setModel(id, provider: provider)
                } label: {
                    Text("设为当前")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(11)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(selected == id ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                              lineWidth: 0.8)
        )
    }

    private func setModel(_ id: String, provider: String) {
        selected = id
        UserDefaults.standard.set(id, forKey: "qingliao_model")
        UserDefaults.standard.set(provider, forKey: "qingliao_provider")
    }

    /// 同步模型列表：stepfun/deepseek 官方端点可同步，opencode 保持本地预置
    private func syncList() {
        guard !syncing else { return }
        syncing = true
        syncResult = nil
        Task {
            let s = await fetchModels("stepfun")
            let d = await fetchModels("deepseek")
            if let s {
                stepfunModels = s
                UserDefaults.standard.set(s, forKey: "qingliao_models_stepfun")
            }
            if let d {
                deepseekModels = d
                UserDefaults.standard.set(d, forKey: "qingliao_models_deepseek")
            }
            syncResult = "✅ 已同步（stepfun \(stepfunModels.count) / deepseek \(deepseekModels.count)）"
            syncing = false
        }
    }

    private func fetchModels(_ provider: String) async -> [String]? {
        guard let j = try? await auth.json("/api/stream/sync-models?provider=\(provider)"),
              (j["ok"] as? Bool) == true,
              let list = j["models"] as? [String] else { return nil }
        return list
    }
}

// MARK: - 关于轻聊（软件介绍页）

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            // v2.0.34：关于页换新图标（淡青底微笑气泡，与 AppIcon 同款）
            Image("AboutLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)

            Text("轻聊")
                .font(.system(size: 22, weight: .bold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider().padding(.horizontal, 30)

            VStack(alignment: .leading, spacing: 8) {
                aboutRow("简介", "连接自家 NAS 上 Hermes Agent 的 AI 智能助手——对话、读图、语音、知识库问答、Docker 部署与智能家居全掌控。")
                aboutRow("模型", "DeepSeek V4 / Kimi / StepFun 多模型聚合（OpenCode Go + 官方 API）")
                aboutRow("功能", "流式对话 · 语音对话（语音输入 + AI 朗读）· 图片理解 · 知识库检索 · 会话同步 · NAS 面板 · Docker 管理 · 智能家居 · 定时任务")
                aboutRow("网络", "iOS 27 蜂窝直连优化 + Safari Relay 兜底 · 公网 IPv6")
                aboutRow("架构", "SwiftUI 原生 · Hermes Agent · 自建 NAS 后端（轻聊）")
            }
            .font(.system(size: 13))
            .padding(.horizontal, 24)

            Spacer()
            Text("Nous Research · Hermes Agent")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .padding(.top, 22)
    }

    private func aboutRow(_ title: String, _ content: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(content)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
        }
    }
}
