import SwiftUI

// v3.9.28：外观设置弹窗——从 CloudSettingsView 拆出独立文件（云端模式移除时误删，
// 但设置页「外观」入口仍在引用 → 灵动岛/流光/字体/行高/天气城市开关全丢了）。
struct AppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    // v3.0.2：全部用本地真实 key + 本地交互（主题用 qingliao_appearance，字体用 qingliao_font_size）
    @AppStorage("qingliao_appearance") private var appearance = "system"   // dark/light/system（对齐本地主题）
    @AppStorage("qingliao_font_size") private var fontSize = 15.0          // 12-20 聊天字体（对齐本地）
    @AppStorage("qingliao_ai_line_spacing") private var aiLineSpacing = 1.0  // AI 输出行高
    @AppStorage("qingliao_siri_glow") private var siriGlow = false
    // v3.0.36：灵动岛发光（独立开关，复用 Siri 发光 4 参数）
    @AppStorage("qingliao_island_glow") private var islandGlow = false
    // v3.8.0：灵动岛/锁屏实时活动（AI 回复中显示进度）——与 LiveActivityManager 共用同一 key（默认开）
    @AppStorage(LiveActivityManager.enabledKey) private var liveActivityOn = true
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
                    .padding(.vertical, Spacing.xs)
                }
                // 交互
                Section("交互") {
                    Toggle("输入框流光光效", isOn: $glowOn)   // v3.0.4：补全本地独有项
                    // v3.8.0：灵动岛/锁屏实时活动——AI 回复中亮起、结束收起；关掉立即收起正在显示的活动
                    Toggle("灵动岛实时活动", isOn: $liveActivityOn)
                        .onChange(of: liveActivityOn) { _, on in
                            if !on { Task { @MainActor in await LiveActivityManager.shared.end() } }
                        }
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
                            .font(.system(size: Typography.body))
                        Spacer()
                        Text("\(Int(fontSize))")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Text("小").font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                        Slider(value: $fontSize, in: 12...20, step: 1)
                            .tint(Color.accentColor)
                        Text("大").font(.system(size: Typography.title)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("AI 输出行高")
                            .font(.system(size: Typography.body))
                        Spacer()
                        Text(String(format: "%.1f", aiLineSpacing))
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Text("紧凑").font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                        Slider(value: $aiLineSpacing, in: 0...6, step: 0.5)
                            .tint(Color.accentColor)
                        Text("宽松").font(.system(size: Typography.title)).foregroundStyle(.secondary)
                    }
                }
                // 天气（v3.0.4：补全本地外观独有项）
                Section("天气") {
                    HStack {
                        Text("天气城市")
                            .font(.system(size: Typography.body))
                        Spacer()
                        Text(weatherCity.isEmpty ? "未设置" : weatherCity)
                            .font(.system(size: Typography.subhead))
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
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        }
                    } else {
                        Button("设置城市") {
                            withAnimation(Motion.snap) { showWeatherCityField = true }
                        }
                        .font(.system(size: Typography.subhead, weight: .semibold))
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
                .font(.system(size: Typography.subhead, weight: .medium))
                .foregroundStyle(appearance == value ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(appearance == value ? Color.accentColor : Color(uiColor: .systemGray5))
                )
        }
        .buttonStyle(.plain)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           suffix: @escaping (Double) -> String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: Typography.subhead)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range).tint(Color.accentColor)
            Text(suffix(value.wrappedValue)).font(.system(size: Typography.subhead)).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, Spacing.xxs)
    }
}
