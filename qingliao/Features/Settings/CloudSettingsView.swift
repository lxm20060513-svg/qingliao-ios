import SwiftUI

// MARK: - v3.0 云端模式设置页：只保留云端相关（模型厂商/外观/关于），数据存 App 本地
// v3.0.1：整体 UI 对齐本地 AI 设置页（SectionHeader + glassListCard + SettingRow 分组风格）

struct CloudSettingsView: View {
    @Environment(AuthStore.self) private var auth
    @State private var config = CloudConfig.shared
    @State private var showAddSheet = false
    @State private var showAppearance = false
    @State private var showAbout = false
    @State private var showCloudModels = false   // v3.0.2：云端模型管理列表
    @State private var confirmLogout = false
    // v3.0.57：免费模型开关（keyless opencode-free）——复用本地同一 key（双模式唯一开关，不各做一套）
    @AppStorage(UserDefaultsKey.freeModel) private var freeModelOn = false
    @State private var pendingDeleteID: String?   // v3.0.57：云端厂商删除确认
    // v-review fix（维度3）：外观摘要与消费方同源 @AppStorage 读取（勿用 UserDefaults 直读——
    // 直读缺省 false 与消费方默认 true 相悖，全新安装摘要与实际开关状态矛盾）
    @AppStorage("qingliao_siri_glow") private var siriGlowOn = false
    @AppStorage("qingliao_ball_input") private var ballInputOn = true

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "设置")
            ScrollView {
                VStack(spacing: 0) {
                    // 账号与安全（对齐本地分组）
                    SectionHeader("账号与安全")
                    VStack(spacing: 0) {
                        SettingRow(icon: "person.crop.circle.fill", iconColor: .blue,
                                   title: activeProviderName, value: "云端已连接")
                    }
                    .glassListCard()

                    // === 云端模型 ===
                    // v3.0.57：免费模型开关（keyless opencode-free）——开启切到 Hermes 免费档，关恢复付费
                    SectionHeader("免费模型")
                    VStack(spacing: 0) {
                        Toggle("使用免费模型（免 Key）", isOn: $freeModelOn)
                            .font(.system(size: 15, weight: .medium))
                            .tint(.green)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        Text(freeModelOn
                             ? "开启中——用 Hermes 内置免费模型（keyless，免任何 Key）"
                             : "开启后可一键切到免费档；关闭回到你自选的付费模型")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.bottom, 8)
                    }
                    .glassListCard()
                    .onChange(of: freeModelOn) { _, on in
                        // v3.0.57 review fix：与 ModelSheet 顶部开关共用同一实现（行为不许分叉）
                        config.enableFreeModel(on)
                    }
                    // 云端模型（对齐本地「连接与模型」卡片风格）
                    SectionHeader("云端模型")
                    VStack(spacing: 0) {
                        ForEach(config.providers) { p in
                            HStack(spacing: 12) {
                                Image(systemName: "cube.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name)
                                        .font(.system(size: 14, weight: .medium))
                                    Text("\(p.model) · \(shortURL(p.baseURL))")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if config.activeProviderID == p.providerID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.accentColor)
                                } else {
                                    Button {
                                        config.activeProviderID = p.providerID
                                    } label: {
                                        Text("选用")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 10).padding(.vertical, 4)
                                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    // v3.0.57：删除厂商（清掉无法使用的模型厂商）
                                    Button {
                                        pendingDeleteID = p.providerID
                                    } label: {
                                        Image(systemName: "trash.fill")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.red)
                                            .padding(.horizontal, 10).padding(.vertical, 4)
                                            .background(Color.red.opacity(0.12), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            if p.providerID != config.providers.last?.providerID {
                                Divider().padding(.leading, 52)
                            }
                        }
                        Divider().padding(.leading, 52)
                        SettingRow(icon: "plus.circle.fill", iconColor: .blue, title: "添加厂商", chevron: true)
                            .onTapGesture { showAddSheet = true }
                        Divider().padding(.leading, 52)
                        SettingRow(icon: "cpu.fill", iconColor: .orange, title: "模型管理", value: activeProviderModel, chevron: true)
                            .onTapGesture { showCloudModels = true }   // v3.0.2：列出当前 API 可用模型
                    }
                    .glassListCard()
                    .confirmationDialog("删除模型厂商？", isPresented: Binding(
                        get: { pendingDeleteID != nil },
                        set: { if !$0 { pendingDeleteID = nil } }
                    ), titleVisibility: .visible) {
                        Button("删除", role: .destructive) {
                            if let id = pendingDeleteID {
                                config.removeProvider(id: id)
                            }
                            pendingDeleteID = nil
                        }
                        Button("取消", role: .cancel) { pendingDeleteID = nil }
                    } message: {
                        Text("将从云端厂商列表移除该厂商（含其 API Key）。无法使用的厂商删除后可在「添加厂商」重新配置。")
                    }

                    // v3.0.18：本地工具（云端 function calling 手机工具集）
                    SectionHeader("本地工具")
                    VStack(spacing: 0) {
                        Toggle(isOn: Binding(
                            get: { UserDefaults.standard.object(forKey: "qingliao_cloud_tools") as? Bool ?? true },
                            set: { UserDefaults.standard.set($0, forKey: "qingliao_cloud_tools") }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("云端 AI 使用本地工具")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text("日历 / 提醒 / 计时器 / 天气 / 剪贴板 / 计算器 / 通知")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .glassListCard()

                    // 外观与显示（对齐本地分组名）
                    SectionHeader("外观与显示")
                    VStack(spacing: 0) {
                        SettingRow(icon: "paintbrush.fill", iconColor: .pink, title: "外观", value: appearanceSummary, chevron: true)
                            .onTapGesture { showAppearance = true }
                    }
                    .glassListCard()

                    // 关于
                    SectionHeader("关于")
                    VStack(spacing: 0) {
                        // v3.0.4：关于行不显示版本号（统一在弹窗内显示）
                        SettingRow(icon: "info.circle.fill", iconColor: .gray, title: "关于轻聊", value: nil, chevron: true)
                            .onTapGesture { showAbout = true }
                    }
                    .glassListCard()

                    // v3.0.4：退出登录胶囊图标（v3.0.44：样式与本地设置页统一——本地为准）
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
                        .background(Color.red.opacity(0.35), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
                        Button("退出登录", role: .destructive) {
                            auth.logout()
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("退出后回到登录页，可切换本地 AI / 云端 AI 模式。云端配置（API Key）仍保留在手机本地。")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 100)   // v3.0.44：底部避让 Dock（对齐本地设置页 100pt），否则退出登录按钮被 Dock 挡住
            }
        }
        .sheet(isPresented: $showAddSheet) {
            CloudProviderSheet { newConfig in
                config.saveProvider(newConfig)
                config.activeProviderID = newConfig.providerID
            }
        }
        .sheet(isPresented: $showAppearance) {
            AppearanceSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showCloudModels) {
            CloudModelsSheet()
        }
        .sheet(isPresented: $showAbout) {
            AboutView(isCloud: true)   // v3.0.1：云端文案
        }
    }

    /// 当前生效厂商名（账号行显示）
    private var activeProviderName: String {
        config.providers.first(where: { $0.providerID == config.activeProviderID })?.name ?? "云端 AI"
    }

    /// 当前生效厂商的默认模型（模型管理行 value 显示）
    private var activeProviderModel: String {
        config.providers.first(where: { $0.providerID == config.activeProviderID })?.model ?? ""
    }

    /// 外观摘要（对齐本地 SettingRow 的 value 显示）
    private var appearanceSummary: String {
        let siri = siriGlowOn ? "发光开" : "发光关"
        let ball = ballInputOn ? "智能球" : "输入框"
        return "\(siri) · \(ball)"
    }

    private func shortURL(_ s: String) -> String {
        s.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "/v1", with: "")
    }
}

// MARK: - 云端模式外观设置（v3.0.2 完全对齐本地 AI 外观：主题/字体大小/行高/Siri发光/Dock/智能球）

struct AppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    // v3.0.2：全部用本地真实 key + 本地交互（主题用 qingliao_appearance，字体用 qingliao_font_size）
    @AppStorage("qingliao_appearance") private var appearance = "system"   // dark/light/system（对齐本地主题）
    @AppStorage("qingliao_font_size") private var fontSize = 15.0          // 12-20 聊天字体（对齐本地）
    @AppStorage("qingliao_ai_line_spacing") private var aiLineSpacing = 1.0  // AI 输出行高
    @AppStorage("qingliao_siri_glow") private var siriGlow = false
    // v3.0.36：灵动岛发光（独立开关，复用 Siri 发光 4 参数）
    @AppStorage("qingliao_island_glow") private var islandGlow = false
    @AppStorage("qingliao_ball_input") private var ballInput = true
    @AppStorage("qingliao_siri_glow_brightness") private var glowBrightness = 1.0
    @AppStorage("qingliao_siri_glow_freq") private var glowFreq = 2.2
    @AppStorage("qingliao_siri_glow_amp") private var glowAmp = 0.18
    @AppStorage("qingliao_siri_glow_width") private var glowWidth = 22.0
    // v3.0.4：补全本地外观独有项（输入框流光 / 天气城市）
    @AppStorage("qingliao_input_glow") private var glowOn = true
    @State private var weatherCity = UserDefaults.standard.string(forKey: "qingliao_weather_city") ?? ""
    @State private var showWeatherCityField = false

    var body: some View {
        NavigationStack {
            Form {
                // 主题模式（对齐本地 appearanceOption 三段选择）
                Section("主题") {
                    HStack(spacing: 10) {
                        appearanceOption("浅色", value: "light")
                        appearanceOption("深色", value: "dark")
                        appearanceOption("跟随系统", value: "system")
                    }
                    .padding(.vertical, 4)
                }
                // 交互
                Section("交互") {
                    Toggle("智能球输入", isOn: $ballInput)
                    Toggle("输入框流光光效", isOn: $glowOn)   // v3.0.4：补全本地独有项
                }
                // AI 回答发光（对齐本地 Siri 发光 4 参数）
                Section("AI 回答发光") {
                    Toggle("Siri 边框发光", isOn: $siriGlow)
                    // v3.0.36：灵动岛发光（独立开关）
                    Toggle("灵动岛发光", isOn: $islandGlow)
                    if siriGlow || islandGlow {
                        sliderRow("亮度", value: $glowBrightness, range: 0.2...1.5, suffix: { String(format: "%.0f%%", $0 * 100) })
                        sliderRow("呼吸频率", value: $glowFreq, range: 0.5...6.0, suffix: { String(format: "%.1f", $0) })
                        sliderRow("呼吸幅度", value: $glowAmp, range: 0...0.4, suffix: { String(format: "%.2f", $0) })
                        sliderRow("光带范围", value: $glowWidth, range: 10...44, suffix: { String(format: "%.0fpt", $0) })
                    }
                }
                // 文本（对齐本地：字体大小滑条 + AI 行高滑条）
                Section("文本") {
                    HStack {
                        Text("聊天字体大小")
                            .font(.system(size: 15))
                        Spacer()
                        Text("\(Int(fontSize))")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Text("小").font(.system(size: 12)).foregroundStyle(.secondary)
                        Slider(value: $fontSize, in: 12...20, step: 1)
                            .tint(Color.accentColor)
                        Text("大").font(.system(size: 16)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("AI 输出行高")
                            .font(.system(size: 15))
                        Spacer()
                        Text(String(format: "%.1f", aiLineSpacing))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Text("紧凑").font(.system(size: 12)).foregroundStyle(.secondary)
                        Slider(value: $aiLineSpacing, in: 0...6, step: 0.5)
                            .tint(Color.accentColor)
                        Text("宽松").font(.system(size: 16)).foregroundStyle(.secondary)
                    }
                }
                // 天气（v3.0.4：补全本地外观独有项）
                Section("天气") {
                    HStack {
                        Text("天气城市")
                            .font(.system(size: 15))
                        Spacer()
                        Text(weatherCity.isEmpty ? "未设置" : weatherCity)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    if showWeatherCityField {
                        HStack(spacing: 10) {
                            TextField("如：上海 / 北京", text: $weatherCity)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never)
                            Button("保存") {
                                UserDefaults.standard.set(weatherCity.trimmingCharacters(in: .whitespaces), forKey: "qingliao_weather_city")
                                showWeatherCityField = false
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        }
                    } else {
                        Button("设置城市") {
                            withAnimation(.easeOut(duration: 0.2)) { showWeatherCityField = true }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .navigationTitle("外观设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 主题选项（对齐本地 appearanceOption：选中高亮段）
    private func appearanceOption(_ name: String, value: String) -> some View {
        Button {
            appearance = value
        } label: {
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(appearance == value ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(appearance == value ? Color.accentColor : Color(uiColor: .systemGray5))
                )
        }
        .buttonStyle(.plain)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           suffix: @escaping (Double) -> String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range).tint(Color.accentColor)
            Text(suffix(value.wrappedValue)).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - v3.0.2 云端模型管理（列出当前 API 可用模型，对齐本地模型管理面板）

struct CloudModelsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config = CloudConfig.shared
    @State private var models: [String] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var selectedModel = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 在线状态 + 厂商
                HStack(spacing: 5) {
                    Circle().fill(loading ? Color.orange : Color.green).frame(width: 7, height: 7)
                    Text(loading ? "加载中..." : "\(config.activeConfig?.name ?? "云端") 在线")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await load() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Divider().padding(.vertical, 8)

                if loading {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("获取模型列表…")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else if let e = errorText {
                    VStack(spacing: 10) {
                        Text("⚠️ \(e)")
                            .font(.system(size: 13))
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                        Button("重试") { Task { await load() } }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 60)
                } else {
                    // 模型列表
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(models, id: \.self) { m in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(m)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(selectedModel == m ? Color.accentColor : Color.primary)
                                        Text(m == config.activeConfig?.model ? "当前模型" : "可用")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    if selectedModel == m {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedModel = m
                                }
                                if m != models.last {
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
            .navigationTitle("模型管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        // 保存选中的模型到当前厂商配置
                        if !selectedModel.isEmpty, var c = config.activeConfig {
                            c.model = selectedModel
                            // v3.0.5 review fix：按所选模型实时判断视觉能力（预设默认模型可能被切走）
                            c.supportsVision = CloudConfig.modelSupportsVision(selectedModel)
                            config.saveProvider(c)
                        }
                        dismiss()
                    }
                    .disabled(selectedModel.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func load() async {
        loading = true
        errorText = nil
        selectedModel = config.activeConfig?.model ?? ""
        let (ids, err) = await CloudBackend.shared.fetchModels()
        if let err {
            errorText = err
        } else {
            models = ids
            // 若当前模型不在列表，取第一个
            if !models.contains(selectedModel), let first = models.first {
                selectedModel = first
            }
        }
        loading = false
    }
}
