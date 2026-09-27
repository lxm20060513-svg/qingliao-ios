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
    /// v3.9.78：聊天页形象（与聊天页 PetAvatar 共用同一组 key —— 本地/云端同一份设置，双模式 UI 必须一致）
    @AppStorage(PetKeys.style) private var petStyle: PetStyle = .liquid
    @AppStorage(PetKeys.motion) private var petMotion: PetMotion = .system
    @State private var weatherCity = UserDefaults.standard.string(forKey: "qingliao_weather_city") ?? ""
    @State private var showWeatherCityField = false
    // v3.9.94：启动会话（逻辑早已接好，见 LaunchSession.swift / ChatStore.swift:158-165，
    // 但外观页一直没给入口 → 用户根本设不了，永远吃默认值 .auto + 15 分钟）。
    // ⚠️ 必须用 @AppStorage 直接绑 UserDefaultsKey.*，不要自己在 onChange 里写回去：
    //    ChatStore 读的就是这两个 key，绕一层就可能与真值表/预检断言脱钩。
    @AppStorage(UserDefaultsKey.launchSessionMode) private var launchSessionMode = LaunchSessionMode.auto.rawValue
    @AppStorage(UserDefaultsKey.launchSessionMins) private var launchSessionMins = Double(LaunchSessionMode.defaultIdleMinutes)

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
                // v3.9.78：聊天页形象（用户拍板「三种都要 + 在设置里增加卡通宠物选择，放在外观设置项里」）
                // 与「主题」同款三选一 idiom（缩略图 + 名称 + 选中蓝框）；缩略图**按显示尺寸 52pt 直接画**
                // 并用 keepDetail 绕过 PetAvatar 的 76pt 简化阈值（细节不丢、尺寸又不会被撑爆）。
                // ⚠️ v3.9.78 真机报修：原来写「PetAvatar(size: 96) + .frame(52,52)」——frame 只改布局槽位、
                //    **不缩放画面**，96pt 画布会从 52pt 槽位四周各溢出 22pt：形象顶到卡片上边框、下沿压住名称文字。
                //    要改尺寸就改 size，永远不要用 frame 去"缩"它。
                Section("聊天页形象") {
                    HStack(spacing: 10) {
                        ForEach(PetStyle.allCases) { style in
                            petOption(style)
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                    HStack(spacing: 10) {
                        ForEach(PetMotion.allCases) { motion in
                            motionOption(motion)
                        }
                    }
                    Text("选中的形象出现在聊天页顶部：轻点＝摸一下（长按仍是语音）。宠物动画「减弱 / 关闭」可省电，关掉后形象静止显示，状态仍由文案承担。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                // v3.9.94：启动会话（用户拍板「设置里面增加启动会话设置……放在外观设置里」）
                // ⚠️ 这段 UI 是**补的入口**，不是新功能：判定逻辑在 LaunchSession.swift 早就有，
                //    ChatStore.swift:158-165 也一直在读这两个 key，只是外观页没给入口，
                //    所以用户一直只能吃默认的「自动 + 15 分钟」。
                Section("启动会话") {
                    HStack(spacing: 10) {
                        // ⚠️ case 名是 .last / .new（不是 .lastSession/.newSession）——
                        //    凭空造成员本机 -parse 查不出，CI Archive 才挂。
                        // 标题取 mode.title（单一真源），别在这里另写一份中文。
                        ForEach(LaunchSessionMode.allCases) { mode in
                            launchSessionOption(mode.title, value: mode)
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                    // 只有「自动」模式下阈值才有意义，另外两选一是恒定行为（跟随 / 强制新开）
                    if LaunchSessionMode(rawValue: launchSessionMode) == .auto {
                        // 档位跟 LaunchSessionMode.idleOptions 走（5/10/15/30/60/120），
                        // 不用随手写的 Slider 5...60 step 5：那样 UI 会漏掉 120 档，
                        // 而且以后加档位得改两处，容易漂。
                        HStack(spacing: 10) {
                            Text("闲置超时").font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(launchSessionMins)) 分钟")
                                .font(.system(size: Typography.subhead))
                                .foregroundStyle(.secondary)
                        }
                        // 6 档用两行网格，别挤在一行（外放页左右余量只有 ~60pt/档，标签会压缩到认不出）
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 3), spacing: Spacing.sm) {
                            ForEach(LaunchSessionMode.idleOptions, id: \.self) { m in
                                idleOption(m)
                            }
                        }
                        Text("上次打开 App 距今超过 \(Int(launchSessionMins)) 分钟，就自动开一个新对话；不足则接着上次那个聊。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                        Spacer(minLength: 8)
                        Text(weatherCity.isEmpty ? "未设置" : weatherCity)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                            // v3.9.80：钉单行（城市名长时折行会把左标题夹成垂直居中，与设置页行口径一致）
                            .lineLimit(1)
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

    /// v3.9.94：启动会话选项（三选一）——与 appearanceOption 同一 idiom（选中高亮段），
    /// 实参序＝声明序（name: String, value: LaunchSessionMode），错位只有 CI Archive 报得出
    private func launchSessionOption(_ name: String, value: LaunchSessionMode) -> some View {
        let selected = launchSessionMode == value.rawValue
        return Button {
            launchSessionMode = value.rawValue
        } label: {
            Text(name)
                .font(.system(size: Typography.subhead, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(selected ? Color.accentColor : Color(uiColor: .systemGray5))
                )
        }
        .buttonStyle(.plain)
    }

    /// v3.9.94：闲置超时档位按钮（5/10/15/30/60/120，档位表来自 LaunchSessionMode.idleOptions）
    /// 实参序＝声明序（minutes: Int）
    private func idleOption(_ minutes: Int) -> some View {
        let selected = Int(launchSessionMins) == minutes
        return Button {
            launchSessionMins = Double(minutes)
        } label: {
            Text("\(minutes)")
                .font(.system(size: Typography.subhead, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(selected ? Color.accentColor : Color(uiColor: .systemGray5))
                )
        }
        .buttonStyle(.plain)
    }

    /// v3.9.78：形象选项（三选一）——按显示尺寸 52pt 直接画（矢量，任意尺寸都清晰），
    /// 细节靠 keepDetail 保住，而不是靠「96 画 + frame 52 塞」（那套会溢出卡片：v3.9.78 真机报修）
    private func petOption(_ style: PetStyle) -> some View {
        let selected = petStyle == style
        return Button {
            petStyle = style
        } label: {
            VStack(spacing: Spacing.xs) {
                PetAvatar(size: 52, state: .idle, styleOverride: style, keepDetail: true)
                Text(style.name)
                    .font(.system(size: Typography.caption, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color(uiColor: .systemGray6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("聊天页形象：\(style.name)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// v3.9.78：宠物动画三档（无障碍硬要求：默认跟随系统；「减弱/关闭」可省电）
    private func motionOption(_ motion: PetMotion) -> some View {
        let selected = petMotion == motion
        return Button {
            petMotion = motion
        } label: {
            Text(motion.name)
                .font(.system(size: Typography.subhead, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(selected ? Color.accentColor : Color(uiColor: .systemGray5))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("宠物动画：\(motion.name)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
