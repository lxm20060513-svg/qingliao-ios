import SwiftUI

// MARK: - 看板页（智能家居 2x3 可控制 + NAS 2x3 + 磁盘弹出式）

enum DashboardSheet: String, Identifiable {
    case lights, climate, service, serviceHermes, disks, docker
    var id: String { rawValue }
}

struct DashboardView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.colorScheme) private var scheme   // v3.0.9：背景毛玻璃化深浅适配

    @State private var nas = NASStatus()
    // v3.0.36：模型使用量栏（/api/nas/providers-usage）
    @State private var providerUsages: [ProviderUsage] = []
    @State private var usageError = ""
    // v3.4.2b：模型使用量卡隐藏集合——长按单卡只隐藏该 provider（逗号分隔 id 持久化）
    @AppStorage("dashboard_hidden_usage_providers") private var hiddenUsageRaw = ""
    @State private var showUsageRestore = false

    private var hiddenUsageProviders: Set<String> {
        Set(hiddenUsageRaw.split(separator: ",").map(String.init))
    }
    private func hideUsageProvider(_ id: String) {
        var s = hiddenUsageProviders
        s.insert(id)
        hiddenUsageRaw = s.sorted().joined(separator: ",")
    }
    private func unhideUsageProvider(_ id: String) {
        var s = hiddenUsageProviders
        s.remove(id)
        hiddenUsageRaw = s.sorted().joined(separator: ",")
    }
    @State private var haEntities: [HAEntity] = []
    @State private var router = RouterStatus()
    @State private var scrollPos = ScrollPosition()

    @State private var activeSheet: DashboardSheet?
    // v2.0.72：Docker 容器数量（看板卡片状态）
    @State private var dockerContainerCount = 0
    @State private var sceneRunning = false   // v2.0.102：场景执行防抖
    // v2.0.96：场景（AI 生成动作组，一键执行）
    @State private var scenes: [SceneItem] = []
    // v2.0.104：定时自动化（AI 生成"X分钟后执行Y"，到点自动执行后消失）
    @State private var automations: [AutomationItem] = []
    // v2.0.113：场景执行确认（含危险动作时弹窗防误触）
    @State private var confirmSceneRun: SceneItem?
    @State private var sceneResult = ""
    @State private var showSceneResult = false
    // v2.0.116：智能建议（天气/NAS/设备 → Agent 生成）
    @State private var smartSuggestion = ""
    @State private var smartLoading = false
    // v3.0.18：设备一键体检（六维诊断：服务/磁盘/容器/负载/内存/温度）
    @State private var diagnoseItems: [DiagnoseItem] = []
    @State private var diagnoseLevel = ""
    @State private var diagnoseSummary = ""
    @State private var diagnoseError = ""
    @State private var diagnosing = false
    // v3.0.74：钉一钉
    @State private var pinStore = PinStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // v2.0.87u：右上角天气（小图标 + 温度）
            PageHeader(title: "看板", subtitle: "智能家居 · NAS 状态",
                       trailing: AnyView(WeatherBadge(temp: weatherTemp, code: weatherCode, city: weatherCity)))
            ScrollView {
                // v2.0.133f：VStack → LazyVStack——TabView 切页动画期间看板全量卡片一次性布局是切页卡顿主因，
                // 懒加载后只渲染可见卡片（与 v2.0.132 ChatView 消息列表同款方案；看板无批量移除路径，安全）
                LazyVStack(alignment: .leading, spacing: 10) {
                    // v2.0.116：智能建议（基于天气/NAS/设备状态，Agent 生成）
                    // v2.0.118：门锁卡同风格（普通圆角卡背景）+ 标题左上 + 内容靠左 + 重新生成右上
                    sectionTitle("智能建议")
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("今日建议")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !smartSuggestion.isEmpty {
                                Button {
                                    Task { await loadSmartSuggestion() }
                                } label: {
                                    Label("重新生成", systemImage: "arrow.clockwise")
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                        if smartLoading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在分析家庭状态…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        } else if !smartSuggestion.isEmpty {
                            Text(smartSuggestion)
                                .font(.system(size: 13))
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Button {
                                Task { await loadSmartSuggestion() }
                            } label: {
                                Text("生成智能建议")
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                    )

                    sectionTitle("智能家居")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        DeviceCard(name: "开关", icon: "lightbulb.fill", value: haLights, sub: "\(lightsOn) 盏开启 · 点击控制", status: lightsOn > 0 ? .on : .off)
                            .onTapGesture { activeSheet = .lights }
                        DeviceCard(name: "空调", icon: "air.conditioner.horizontal", value: haClimate, sub: "\(climateOn) 台运行中 · 点击控制", status: climateOn > 0 ? .on : .off)
                            .onTapGesture { activeSheet = .climate }
                        DeviceCard(name: "门锁", icon: "lock.fill", value: haLockBattery, sub: "智能门锁", status: .on)
                        DeviceCard(name: "猫眼", icon: "video.fill", value: haDoorbellBattery, sub: haDoorbellOnline ? "在线" : "离线", status: haDoorbellOnline ? .on : .off)
                        DeviceCard(name: "安防", icon: "shield.fill", value: haAlarm, sub: haAlarmArmed ? "已布防" : "未布防", status: haAlarmArmed ? .on : .warn)
                        DeviceCard(name: "温度", icon: "thermometer", value: haTemp, sub: "室内温度", status: .on)
                    }

                    // v2.0.96：场景（AI 对话生成动作组，点一下逐条执行）
                    // v2.0.96b：改「智慧场景」标题 + HomeKit 卡片风格（对齐 DeviceCard）
                    // v2.0.96c：空态可点击刷新（TabView 切 tab 不触发 onAppear 的 iOS 版本差异兜底）
                    sectionTitle("智慧场景")
                    if scenes.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Text("暂无场景")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button("刷新") { Task { await refresh() } }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .dashboardCard(cornerRadius: 10)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(scenes) { s in
                                DeviceCard(name: s.name,
                                           icon: "bolt.fill",
                                           value: "\(s.actionCount) 个动作",
                                           sub: "点击执行 · 长按删除",
                                           status: .on)
                                    .onTapGesture { runScene(s) }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            deleteScene(s)
                                        } label: {
                                            Label("删除场景", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }

                    // v2.0.104：自动化（AI 生成"X分钟后执行Y"，倒计时到点自动执行后消失）
                    sectionTitle("自动化")
                    if automations.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "timer")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Text("暂无自动化")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button("刷新") { Task { await refresh() } }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .dashboardCard(cornerRadius: 10)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(automations) { a in
                                // TimelineView 每秒驱动倒计时刷新
                                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                    // v2.0.104b：runAt 在未来，timeIntervalSince(a.runAt) 是负值——
                                    // 修正为 runAt.timeIntervalSince(now) 得剩余正秒数（原实现倒计时反向递增）
                                    let remain = max(Int(a.runAt.timeIntervalSince(ctx.date)), 0)
                                    DeviceCard(name: a.name,
                                               icon: "timer",
                                               value: remainText(remain),
                                               sub: "到点自动执行 · 长按取消",
                                               status: .on)
                                        .opacity(remain <= 0 ? 0.35 : 1)
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        cancelAutomation(a)
                                    } label: {
                                        Label("取消自动化", systemImage: "xmark.circle")
                                    }
                                }
                            }
                        }
                    }

                    sectionTitle("NAS 面板")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        MeterCard(name: "CPU", icon: "cpu.fill", value: nas.cpuText, sub: nil, ratio: nas.cpu / 100.0, color: .blue)
                        MeterCard(name: "内存", icon: "memorychip.fill", value: nas.memUsedText, sub: "/ \(nas.memTotalText)", ratio: nas.memPct, color: .green)
                        MeterCard(name: "磁盘", icon: "internaldrive.fill", value: nas.maxDiskPctText, sub: "\\(nas.disks.filter { $0.isSystem }.count) 系统盘 · \\(nas.disks.filter { !$0.isSystem }.count) 数据卷 · 点击查看", ratio: nas.maxDiskPct / 100.0, color: .orange)
                            .onTapGesture { activeSheet = .disks }
                        ServiceCard(name: "轻聊后端", icon: "server.rack", running: nas.qingliaoAlive, detail: nas.qingliaoMemText)
                            .onTapGesture { activeSheet = .service }
                        ServiceCard(name: "Hermes 网关", icon: "sparkles", running: nas.hermesAlive, detail: nas.hermesMemText)
                            .onTapGesture { activeSheet = .serviceHermes }
                        // v2.0.72：Docker 管理卡片（点击弹部署弹窗）
                        ServiceCard(name: "Docker", icon: "shippingbox.fill", running: dockerContainerCount > 0,
                                    detail: dockerContainerCount > 0 ? "\(dockerContainerCount) 个容器 · 点击管理" : "暂无容器 · 点击部署")
                            .onTapGesture { activeSheet = .docker }
                        ServiceCard(name: "运行时间", icon: "clock.fill", running: true, detail: nas.uptime)
                        // v2.0.86：硬件温度（CPU / NVMe）
                        ServiceCard(name: "温度", icon: "thermometer", running: true, detail: hwDetail)
                    }

                    // v3.0.36：模型使用量（DeepSeek/StepFun 官方余额；无接口 provider 降级显示）
                    // v3.4.2b：长按任意用量卡 → 只隐藏该 provider 卡（持久化）；
                    // 节底部显示"已隐藏 N 个 · 点击恢复"（弹菜单逐张恢复/全部恢复）
                    sectionTitle("模型使用量")
                    if usageError.isEmpty && providerUsages.isEmpty {
                        Text("加载中…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else if !usageError.isEmpty {
                        Text(usageError)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        let visible = providerUsages.filter { !hiddenUsageProviders.contains($0.id) }
                        if visible.isEmpty {
                            Text("已全部隐藏 · 点下方恢复")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 6)
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                ForEach(visible) { u in
                                    UsageCard(usage: u)
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                hideUsageProvider(u.id)
                                            } label: {
                                                Label("隐藏此卡片", systemImage: "eye.slash")
                                            }
                                        }
                                }
                            }
                        }
                    }
                    if !hiddenUsageProviders.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Text("已隐藏 \(hiddenUsageProviders.count) 个模型服务 · 点击恢复")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .dashboardCard(cornerRadius: 10)
                        .contentShape(Rectangle())
                        .onTapGesture { showUsageRestore = true }
                        .confirmationDialog("恢复已隐藏的模型服务", isPresented: $showUsageRestore, titleVisibility: .visible) {
                            ForEach(Array(hiddenUsageProviders).sorted()) { p in
                                Button(p) { unhideUsageProvider(p) }
                            }
                            Button("恢复全部") { hiddenUsageRaw = "" }
                            Button("取消", role: .cancel) {}
                        }
                    }

                    // v3.0.18：设备一键体检（六维诊断：服务/磁盘/容器/负载/内存/温度）
                    sectionTitle("设备体检")
                    DiagnoseCard(items: diagnoseItems, level: diagnoseLevel, summary: diagnoseSummary,
                                 error: diagnoseError, diagnosing: diagnosing) {
                        Task { await runDiagnose() }
                    }

                    sectionTitle("路由器")
                    RouterPanel(router: router,
                                onStart: { clashAction("start") },
                                onStop: { clashAction("stop") },
                                onRefresh: { Task { await loadRouter() } })
                        .onAppear { Task { await loadRouter() } }

                    // v3.0.74：钉一钉（聊天消息钉到看板）——始终显示
                    sectionTitle("钉一钉")
                    if pinStore.pins.isEmpty {
                        Text("长按聊天消息 → 钉一钉")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(pinStore.pins) { pin in
                            PinCard(pin: pin) {
                                pinStore.delete(pin)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pinStore.delete(pin)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 100)
            }
            .scrollPosition($scrollPos)
            // v2.0.86h：Dock 滑动隐藏已删除（从未生效，手动开关替代）
            .refreshable {
                await refresh()
            }
            .sheet(item: $activeSheet) { s in
                switch s {
                case .lights:
                    HADeviceSheet(title: "客厅灯", domain: "light")
                        .presentationDetents([.medium, .large])
                case .climate:
                    HADeviceSheet(title: "空调", domain: "climate")
                        .presentationDetents([.medium, .large])
                case .service:
                    ServiceControlSheet(service: .qingliao)
                        .presentationDetents([.medium])
                case .serviceHermes:
                    ServiceControlSheet(service: .hermes)
                        .presentationDetents([.medium])
                case .disks:
                    DisksSheet(disks: nas.disks)
                        .presentationDetents([.medium, .large])
                case .docker:
                    DockerSheet()
                        .presentationDetents([.medium, .large])
                }
            }
            // v2.0.96：场景执行结果提示
            .alert("场景执行结果", isPresented: $showSceneResult) {
                Button("好的", role: .cancel) {}
            } message: {
                Text(sceneResult)
            }
            // v2.0.113：危险场景执行确认（布防/离家/断电类防误触）
            .confirmationDialog("确认执行场景？",
                                isPresented: Binding(get: { confirmSceneRun != nil },
                                                     set: { if !$0 { confirmSceneRun = nil } }),
                                titleVisibility: .visible) {
                Button("执行") {
                    if let s = confirmSceneRun {
                        executeScene(s)
                    }
                    confirmSceneRun = nil
                }
                Button("取消", role: .cancel) { confirmSceneRun = nil }
            } message: {
                Text("场景「\(confirmSceneRun?.name ?? "")」包含安全相关动作（布防/离家/断电），执行后可能改变家庭安防状态。")
            }
        }
        // v2.0.96b：切回看板立即刷新（对话里生成场景后看板即时联动；TabView 切回触发 onAppear）
        // v2.0.102：单一刷新入口（onAppear 首刷+切回刷），.task 只跑 30s 轮询——修并发双刷/旧响应覆盖
        // v2.0.102c：onReceive 通知刷新（iOS 27 切 tab 不触发 onAppear 的兜底，DockTabView 切回时发通知）
        .onReceive(NotificationCenter.default.publisher(for: .qingliaoDashboardRefresh)) { _ in
            // v2.0.133f：回到看板 → 恢复轮询 + 立即刷新
            isDashboardVisible = true
            Task {
                await refresh()
                await loadDockerCount()
                await loadWeatherWithCity()
            }
        }
        // v2.0.133f：离开看板 → 暂停 30s 轮询（隐藏页刷新抢帧，切页卡顿源之一）
        .onReceive(NotificationCenter.default.publisher(for: .qingliaoDashboardLeave)) { _ in
            isDashboardVisible = false
        }
        .onAppear {
            isDashboardVisible = true
            Task {
                await refresh()
                await loadDockerCount()      // v2.0.102：切回也刷 Docker 数（部署后返回看板即时更新）
                await loadWeatherWithCity()  // v2.0.102：切回也刷天气（设置页改城市后即时生效）
            }
        }
        .task {
            // v2.0.86：硬件温度（CPU / NVMe）首屏加载
            await loadHw()
            // v3.0.74：从 NAS 加载钉一钉数据
            await pinStore.loadFromServer()
            // 30s 自动刷新（v2.0.87c：10→30s，省电省流量，看板数据变化不敏感）
            // v2.0.133f：仅看板可见时刷——隐藏页轮询会抢 TabView 切页动画帧
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard isDashboardVisible else { continue }
                await refresh()
                await loadHw()
            }
        }
    }

    // MARK: - 数据

    // v2.0.133g：看板是否可见（离开看板暂停 30s 轮询——隐藏页刷新抢 TabView 切页动画帧）
    @State private var isDashboardVisible = true
    // v2.0.86：硬件温度状态
    @State private var hwCpu: Double?
    @State private var hwSsd: Double?
    // v2.0.87u：天气
    @State private var weatherTemp: Double?
    @State private var weatherCode: Int?
    @State private var weatherCity = UserDefaults.standard.string(forKey: "qingliao_weather_city") ?? ""   // v2.0.87am：手动城市

    /// v3.0.22：硬件温度（保留 View 层因需 @State hwCpu/hwSsd 驱动刷新）
    private var hwDetail: String {
        let c = hwCpu.map { String(format: "CPU %.0f°C", $0) } ?? "CPU --"
        let s = hwSsd.map { String(format: "SSD %.0f°C", $0) } ?? "SSD --"
        return "\(c) · \(s)"
    }

    private func loadHw() async {
        if let j = await auth.jsonOrLog("/api/hw/status") {
            hwCpu = j["cpu_temp"] as? Double
            hwSsd = j["ssd_temp"] as? Double
        }
    }

    // v2.0.87u：天气加载（后端缓存 30 分钟）
    // v2.0.118 fix：带城市参数（原无 city 走 IP 定位——NAS 出口无公网 IP 定位失败 → temp null 不显示温度）
    private func loadWeather() async {
        let city = weatherCity.trimmingCharacters(in: .whitespaces)
        let q = city.isEmpty ? "" : "?city=" + (city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        if let j = await auth.jsonOrLog("/api/weather\(q)") {
            weatherTemp = j["temp"] as? Double
            weatherCode = j["code"] as? Int
        }
    }

    // v2.0.87am：手动城市名 → 天气（未设置城市不显示徽章）
    private func loadWeatherWithCity() async {
        weatherCity = UserDefaults.standard.string(forKey: "qingliao_weather_city") ?? ""
        guard !weatherCity.isEmpty else {
            weatherTemp = nil
            weatherCode = nil
            return
        }
        let enc = weatherCity.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? weatherCity
        if let j = await auth.jsonOrLog("/api/weather?city=\(enc)") {
            weatherTemp = j["temp"] as? Double
            weatherCode = j["code"] as? Int
            if let c = j["city"] as? String, !c.isEmpty { weatherCity = c }
        }
    }

    private func loadRouter() async {
        if let j = await auth.jsonOrLog("/api/router/status") {
            router = RouterStatus.parse(j)
        }
    }

    /// v3.0.36：模型使用量（DeepSeek/StepFun 余额 + unsupported 降级）
    /// v3.1.1 fix：合并 App 云端模式本地新增的 provider——新增 API 自动生成用量卡片
    private func loadProviderUsage() async {
        guard let j = await auth.jsonOrLog("/api/nas/providers-usage") else {
            usageError = "用量查询失败"
            return
        }
        if let ps = j["providers"] as? [[String: Any]] {
            var list = ps
            // v3.1.1：云端模式（App 本地 UserDefaults/Keychain）新增的 provider 后端无记录
            // → 补 unsupported 卡片（显示「控制台查看」），保证新增 API 必出卡片
            let backendIDs = Set(list.compactMap { $0["provider"] as? String })
            for p in CloudConfig.shared.providers where !backendIDs.contains(p.providerID) {
                list.append(["provider": p.providerID,
                             "name": p.name.isEmpty ? p.providerID : p.name,
                             "mode": "payg",
                             "available": false,
                             "unsupported": true,
                             "error": "官方无公开用量接口"])
            }
            providerUsages = list.map { ProviderUsage.parse($0) }
            usageError = ""
        } else if let e = j["error"] as? String {
            usageError = e
        }
    }

    /// 快捷指令：启动/关闭 Clash
    private func clashAction(_ action: String) {
        // v2.0.102：防抖——操作中再点直接忽略（原两个并发 Task 各自 defer 释放 busy 互相覆盖）
        guard !router.busy else { return }
        router.busy = true
        Task {
            defer { router.busy = false }
            if let j = await auth.jsonOrLog("/api/router/clash/\(action)", method: "POST", body: nil) {
                // v2.0.92：操作成功清空错误显示（失败原因由后端按"服务已启动"输出判断）
                if (j["ok"] as? Bool) == true {
                    router.error = ""
                }
                router = RouterStatus.merge(router, with: j)
            }
            await loadRouter()
        }
    }

    /// v3.0.18：设备一键体检——GET /api/nas/diagnose 六维诊断（服务/磁盘/容器/负载/内存/温度）
    private func runDiagnose() async {
        guard !diagnosing else { return }
        diagnosing = true
        diagnoseError = ""
        defer { diagnosing = false }
        if let j = await auth.jsonOrLog("/api/nas/diagnose") {
            if let items = j["items"] as? [[String: Any]] {
                diagnoseItems = items.map { d in
                    DiagnoseItem(id: d["id"] as? String ?? UUID().uuidString,
                                 name: d["name"] as? String ?? "?",
                                 status: d["status"] as? String ?? "warn",
                                 detail: d["detail"] as? String ?? "",
                                 advice: d["advice"] as? String ?? "")
                }
                diagnoseLevel = j["level"] as? String ?? ""
                diagnoseSummary = j["summary"] as? String ?? ""
            } else if let err = j["error"] as? String {
                diagnoseError = err
            }
        } else {
            diagnoseError = "体检请求失败"
        }
    }

    private func refresh() async {
        // v3.0.x：并行请求——7 个独立 API 并发（原串行，每个等前一个完成才发下一个）
        // v3.0.81c：不用 TaskGroup+addTask{@MainActor}——Xcode 26.6 Swift 6 区域隔离检查器对
        // 「闭包捕获 self」的这种写法直接报编译错误（checker bug）。
        // 改为 MainActor 方法 + async let（Void 返回值无 Sendable 问题），语义同样是 7 路并发。
        async let nasTask: Void = loadNAS()
        async let haTask: Void = loadHA()
        async let scenesTask: Void = loadScenes()
        async let autosTask: Void = loadAutomations()
        async let sugTask: Void = loadSuggestionIfNeeded()
        async let routerTask: Void = loadRouter()
        async let usageTask: Void = loadProviderUsage()
        _ = await (nasTask, haTask, scenesTask, autosTask, sugTask, routerTask, usageTask)
    }

    /// NAS 状态
    private func loadNAS() async {
        if let n = await auth.jsonOrLog("/api/nas/status") {
            nas = NASStatus.parse(n)
        }
    }

    /// HA 设备状态
    private func loadHA() async {
        if let h = await auth.jsonArrayOrLog("/api/ha/states") {
            haEntities = h.compactMap { HAEntity.parse($0 as? [String: Any] ?? [:]) }
        }
    }

    /// 场景列表
    private func loadScenes() async {
        if let j = await auth.jsonOrLog("/api/scenes/list") {
            scenes = (j["scenes"] as? [[String: Any]] ?? []).map { SceneItem($0) }
        }
    }

    /// 自动化列表
    private func loadAutomations() async {
        if let j = await auth.jsonOrLog("/api/automations/list") {
            automations = (j["automations"] as? [[String: Any]] ?? []).map { AutomationItem($0) }
        }
    }

    /// 智能建议（v2.0.116 后端建议 + v2.0.132 缓存兜底 + 过期自动生成）
    private func loadSuggestionIfNeeded() async {
        guard smartSuggestion.isEmpty else { return }
        if let j = await auth.jsonOrLog("/api/agent/last_suggestion"),
           let sug = j["suggestion"] as? [String: Any],
           let text = sug["text"] as? String, !text.isEmpty {
            smartSuggestion = text
        } else if let cached = cachedSuggestion {
            smartSuggestion = cached
        } else if shouldAutoGenerate {
            Task { await loadSmartSuggestion() }
        }
    }

    // v2.0.132：智能建议缓存（30 分钟有效，避免每次进看板/轮询重复生成费 token）
    private var cachedSuggestion: String? {
        guard let raw = UserDefaults.standard.string(forKey: "qingliao_suggestion_cache"),
              let ts = UserDefaults.standard.object(forKey: "qingliao_suggestion_cache_ts") as? Date,
              Date().timeIntervalSince(ts) < 1800 else { return nil }
        return raw
    }

    private var shouldAutoGenerate: Bool {
        cachedSuggestion == nil   // 无有效缓存 → 需要自动生成
    }

    /// v2.0.116：生成智能建议（天气 + NAS + 设备状态 → Agent）
    private func loadSmartSuggestion() async {
        guard !smartLoading else { return }
        smartLoading = true
        defer { smartLoading = false }
        var parts: [String] = []
        if let t = weatherTemp {
            parts.append("天气：\(weatherCity.isEmpty ? "当前城市" : weatherCity) \(Int(t))°C 码\(weatherCode ?? 0)")
        }
        parts.append("NAS：CPU \(Int(nas.cpu))% 内存 \(Int(nas.memUsed))G/\(Int(nas.memTotal))G 磁盘 \(Int(nas.maxDiskPct))%")
        if !haEntities.isEmpty {
            let lightsOn = haEntities.filter { $0.entityID.hasPrefix("light.") && $0.state == "on" }.count
            let acOn = haEntities.filter { $0.entityID.hasPrefix("climate.") && $0.state == "on" }.count
            parts.append("设备：\(lightsOn) 盏灯开 / \(acOn) 台空调开")
        }
        if let j = await auth.jsonOrLog("/api/agent/suggest", method: "POST",
                                        body: ["context": parts.joined(separator: "；")]),
           let text = j["text"] as? String, !text.isEmpty {
            smartSuggestion = text
            // v2.0.132：生成成功写缓存（30 分钟有效，轮询不重复生成）
            UserDefaults.standard.set(text, forKey: "qingliao_suggestion_cache")
            UserDefaults.standard.set(Date(), forKey: "qingliao_suggestion_cache_ts")
        } else {
            smartSuggestion = "建议生成失败，请重试"
        }
    }

    /// v2.0.104：剩余时间文案（倒计时显示）
    private func remainText(_ s: Int) -> String {
        if s >= 3600 { return String(format: "%d小时%02d分", s / 3600, (s % 3600) / 60) }
        if s >= 60 { return String(format: "%d分%02d秒", s / 60, s % 60) }
        return "\(s) 秒后执行"
    }

    /// v2.0.104：取消自动化（长按卡片）
    private func cancelAutomation(_ a: AutomationItem) {
        Task {
            _ = await auth.jsonOrLog("/api/automations/\(a.id)", method: "DELETE", body: nil)
            automations.removeAll { $0.id == a.id }
        }
    }

    /// v2.0.96：执行场景（v2.0.102：加防抖——连点不重复执行）
    /// v2.0.113：含危险动作（布防/开关类非灯设备）时先弹确认防误触
    private func runScene(_ s: SceneItem) {
        guard !sceneRunning else { return }
        if hasDangerousAction(s) {
            confirmSceneRun = s
        } else {
            executeScene(s)
        }
    }

    /// v2.0.113：危险动作判断（布防/离家/断电类场景名，误触代价高）
    private func hasDangerousAction(_ s: SceneItem) -> Bool {
        let name = s.name
        return name.contains("布防") || name.contains("离家") || name.contains("断电")
            || name.contains("关闭所有") || name.contains("总闸")
    }

    /// v2.0.113：实际执行（确认后或非危险场景）
    private func executeScene(_ s: SceneItem) {
        sceneRunning = true
        Task {
            defer { sceneRunning = false }
            if let j = await auth.jsonOrLog("/api/scenes/run", method: "POST", body: ["name": s.name]) {
                let ok = (j["ok"] as? Bool) ?? false
                let msg = (j["message"] as? String) ?? (ok ? "执行成功" : "执行失败")
                sceneResult = msg
                showSceneResult = true
                // v2.0.113：执行后刷新（结果推送微信后卡片状态同步）
                Task { await refresh() }
            } else {
                sceneResult = "执行失败（网络错误）"
                showSceneResult = true
            }
        }
    }

    /// v2.0.96：删除场景（v2.0.102：仅服务器确认成功才移除——失败保留并提示）
    private func deleteScene(_ s: SceneItem) {
        Task {
            if let j = await auth.jsonOrLog("/api/scenes/delete", method: "POST", body: ["name": s.name]),
               (j["ok"] as? Bool) == true {
                scenes.removeAll { $0.name == s.name }
            } else {
                sceneResult = "删除失败（网络或服务器错误）"
                showSceneResult = true
            }
        }
    }

    // MARK: - v2.0.72 Docker 容器数量

    private func loadDockerCount() async {
        if let j = await auth.jsonOrLog("/api/docker/ps") {
            dockerContainerCount = (j["containers"] as? [[String: Any]] ?? []).count
        }
    }

    // MARK: - HA 派生（与 PWA 相同挑选规则）

    private var lights: [HAEntity] {
        // 过滤指示灯（NAS 查询指示灯等不参与灯列表，改由 switch 开关实体控制）
        haEntities.filter {
            $0.entityID.hasPrefix("light.") && !$0.state.contains("unavailable")
                && !$0.entityID.contains("indicator_light")
        }
    }
    private var lightsOn: Int { lights.filter { $0.state != "off" }.count }
    private var haLights: String { "\(lightsOn)/\(lights.count) 盏" }

    private var climates: [HAEntity] {
        haEntities.filter { $0.entityID.hasPrefix("climate.") && !["unavailable", "offline", "unknown"].contains($0.state) }
    }
    private var climateOn: Int { climates.filter { $0.state != "off" }.count }
    private var haClimate: String { "\(climateOn)/\(climates.count) 台" }

    private var lockBattery: HAEntity? {
        haEntities.first { $0.entityID.contains("bacn01") && $0.entityID.contains("battery_level") }
    }
    private var haLockBattery: String {
        guard let e = lockBattery, let v = Double(e.state) else { return "--" }
        return "\(Int(v.rounded()))%"
    }

    private var doorbellBattery: HAEntity? {
        haEntities.first { $0.entityID.contains("chuangmi") && $0.entityID.contains("battery_level") }
    }
    private var haDoorbellBattery: String {
        guard let e = doorbellBattery, let v = Double(e.state) else { return "--" }
        return "\(Int(v.rounded()))%"
    }
    private var haDoorbellOnline: Bool {
        !(doorbellBattery?.state.contains("unavailable") ?? true)
    }

    private var alarm: HAEntity? {
        haEntities.first { $0.entityID.contains("alarmstatus") }
    }
    private var haAlarm: String { alarm?.state ?? "--" }
    private var haAlarmArmed: Bool {
        guard let st = alarm?.state else { return false }
        return ["布防", "armed", "armed_home", "armed_away", "on"].contains(st)
    }

    private var tempSensor: HAEntity? {
        // 优先室内温度计，其次任意 temperature sensor
        if let e = haEntities.first(where: { $0.entityID.contains("indoor_temperature") }) { return e }
        return haEntities.first {
            $0.entityID.hasPrefix("sensor.") && $0.entityID.contains("temperature")
                && !$0.state.contains("unavailable") && Double($0.state) != nil
        }
    }
    private var haTemp: String {
        guard let e = tempSensor, let v = Double(e.state) else { return "--" }
        return String(format: "%.1f°", v)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 15, weight: .bold))
            .padding(.top, 6)
    }
}

// MARK: - 服务控制 sheet（HomeKit 卡片式：信息卡 + 重试卡 + 停止卡）

/// v3.0.36：服务类型（轻聊后端 / Hermes 网关）
enum QLServiceKind: String {
    case qingliao, hermes

    var title: String {
        switch self {
        case .qingliao: return "轻聊后端"
        case .hermes: return "Hermes 网关"
        }
    }

    var icon: String {
        switch self {
        case .qingliao: return "server.rack"
        case .hermes: return "sparkles"
        }
    }

    var subtitle: String {
        switch self {
        case .qingliao: return "轻聊后端服务"
        case .hermes: return "Hermes 网关服务"
        }
    }

    var restartBody: [String: Any] { ["service": rawValue] }
}

struct ServiceControlSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    let service: QLServiceKind

    @State private var busy = false
    @State private var info: String
    @State private var running: Bool?   // 真实运行状态
    @State private var showStopConfirm = false

    init(service: QLServiceKind) {
        self.service = service
        _info = State(initialValue: service == .qingliao ? "管理轻聊后端服务" : "管理 Hermes 网关服务")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(service.title)
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // 服务信息卡
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.blue.opacity(0.15))
                    Image(systemName: service.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(service.subtitle)
                        .font(.system(size: 14, weight: .semibold))
                    Text(info)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(running == true ? Color.green : (running == false ? Color.red : Color.gray))
                        .frame(width: 7, height: 7)
                    Text(running == true ? "运行中" : (running == false ? "已停止" : "检测中"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(running == true ? Color.green : (running == false ? Color.red : Color.secondary))
                }
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground))  // v2.0.87h：弹窗玻璃下扁平化
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
            .task {
                // 真实运行状态
                if let n = await auth.jsonOrLog("/api/nas/status") {
                    let st = NASStatus.parse(n)
                    running = service == .qingliao ? st.qingliaoAlive : st.hermesAlive
                }
            }

            // 重试卡
            Button {
                restart()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.accentColor)
                        if busy {
                            ProgressView().tint(.white).scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("重试服务")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(service == .qingliao ? "重启轻聊后端进程" : "重启 Hermes 网关进程")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground))  // v2.0.87h：弹窗玻璃下扁平化
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 10)

            // 停止卡（Hermes 网关不支持停止，隐藏）
            if service == .qingliao {
                Button {
                    showStopConfirm = true
                } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.red.opacity(0.15))
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("停止服务")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.red)
                        Text("停止后轻聊将不可用")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color.red.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .confirmationDialog("停止后轻聊将完全不可用，需在 NAS 上手动启动", isPresented: $showStopConfirm, titleVisibility: .visible) {
                Button("停止服务", role: .destructive) {
                    stopService()
                }
                Button("取消", role: .cancel) {}
            }
            }

            Spacer()
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func restart() {
        guard !busy else { return }
        busy = true
        info = "正在重启服务..."
        Task {
            defer { busy = false }
            do {
                _ = try await auth.request("/api/nas/service/restart", method: "POST",
                                           body: service.restartBody)
                info = "重试指令已发送，服务即将重启"
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled { dismiss() }
                }
            } catch {
                info = "发送失败，请检查连接"
            }
        }
    }

    private func stopService() {
        guard !busy else { return }
        busy = true
        info = "正在停止服务..."
        Task {
            defer { busy = false }
            do {
                _ = try await auth.request("/api/nas/service/stop", method: "POST",
                                           body: service.restartBody)
                info = "停止指令已发送"
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if !Task.isCancelled { dismiss() }
                }
            } catch {
                info = "发送失败，请检查连接"
            }
        }
    }
}

// MARK: - HA 设备控制 sheet（HomeKit 风格：灯=卡片网格 / 空调=模式控制卡）

struct HADeviceSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let title: String
    let domain: String

    @State private var entities: [HAEntity] = []
    @State private var loading = true
    @State private var busyID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 8)

            if loading {
                Spacer()
                ProgressView().tint(.secondary)
                Spacer()
            } else if entities.isEmpty {
                Spacer()
                Text("暂无可用设备")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                Spacer()
            } else if domain == "light" {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(entities) { e in
                            lightCard(e)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            } else {
                // 空调：模式控制卡
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(entities) { e in
                            climateCard(e)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
        }
        // v2.0.87l：弹窗玻璃罩效果不佳（用户反馈）→ 全部回退普通背景
        .background(Color(uiColor: .systemBackground))
        .task { await load() }
    }

    // MARK: - 灯卡（PWA HomeKit 复刻：渐变图标容器 + 圆形小开关）

    private func lightCard(_ e: HAEntity) -> some View {
        let isOn = e.state == "on"
        // 拆成 AnyShapeStyle 单一类型（三元 LinearGradient vs Color 会让编译器类型检查超时）
        let iconBG: AnyShapeStyle = isOn
            ? AnyShapeStyle(LinearGradient(colors: [Color.yellow.opacity(0.30), Color.orange.opacity(0.18)],
                                           startPoint: .top, endPoint: .bottom))
            : AnyShapeStyle(Color(uiColor: .systemGray6))
        return Button {
            toggle(e)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // 图标容器：点亮=黄色渐变光晕 / 熄灭=灰底
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(iconBG)
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(isOn ? Color.yellow : Color.gray.opacity(0.5))
                            .shadow(color: isOn ? Color.yellow.opacity(0.8) : .clear, radius: 8)
                    }
                    .frame(width: 46, height: 46)
                    Spacer()
                    // 圆形小开关（PWA .ha-toggle 同款）
                    ZStack {
                        Circle()
                            .fill(isOn ? Color.accentColor : Color(uiColor: .systemGray5))
                        if busyID == e.entityID {
                            ProgressView().tint(.white).scaleEffect(0.65)
                        } else {
                            Image(systemName: "power")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isOn ? .white : Color.secondary)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .shadow(color: isOn ? Color.accentColor.opacity(0.45) : .clear, radius: 4)
                }
                Text(displayName(e))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(isOn ? "已开启" : "已关闭")
                    .font(.system(size: 10.5))
                    .fontWeight(isOn ? .semibold : .regular)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            }
            .padding(12)
            .frame(minHeight: 92)
            // v2.0.87h：弹窗液态玻璃下卡片扁平化（去白圆角底，仅极轻底区分）
            // v3.0.6 fix：卡片补描边（用户要求每个开关卡都描框）
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isOn ? 0.28 : 0.10), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 空调卡（PWA climate-card 复刻：跨行渐变卡 + 电源圆钮 + 模式胶囊）

    private func climateCard(_ e: HAEntity) -> some View {
        let attrs = e.attributes
        let cur = (attrs["current_temperature"] as? Double) ?? 0
        let target = (attrs["temperature"] as? Double) ?? 24
        let step = (attrs["target_temp_step"] as? Double) ?? 1
        let modes = (attrs["hvac_modes"] as? [String]) ?? ["off", "auto", "cool", "dry", "heat", "fan_only"]
        // 关闭模式统一置顶（所有空调卡片一致）
        let orderedModes = ["off"] + modes.filter { $0 != "off" }
        let isOn = e.state != "off" && e.state != "unavailable"

        return VStack(alignment: .leading, spacing: 10) {
            // 顶部：图标 + 名称/状态 + 电源（关闭按钮统一在最右）
            HStack(spacing: 10) {
                Image(systemName: "snowflake")
                    .font(.system(size: 24))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName(e))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(isOn ? modeName(e.state) : "已关闭")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                }
                Spacer()
                // 电源圆钮（统一贴最右）
                Button {
                    toggle(e)
                } label: {
                    ZStack {
                        Circle()
                            .fill(isOn ? Color.accentColor : Color(uiColor: .systemGray5))
                        Image(systemName: "power")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(isOn ? .white : Color.secondary)
                    }
                    .frame(width: 32, height: 32)
                    .shadow(color: isOn ? Color.accentColor.opacity(0.5) : .clear, radius: 6)
                }
                .buttonStyle(.plain)
            }

            // 温度：目标大字 + 室温 + 步进
            HStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.0f", target))
                        .font(.system(size: 32, weight: .bold))
                    Text("°")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                Text("室温 \(String(format: "%.0f", cur))°")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    setTemp(e, value: target - step)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Color(uiColor: .systemGray5), in: Circle())
                }
                .buttonStyle(.plain)
                Button {
                    setTemp(e, value: target + step)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Color(uiColor: .systemGray5), in: Circle())
                }
                .buttonStyle(.plain)
            }

            // 模式按钮行
            HStack(spacing: 8) {
                ForEach(orderedModes, id: \.self) { m in
                    Button {
                        setMode(e, mode: m)
                    } label: {
                        // v2.0.87k：判定 lowercased（HA 部分实体返回 "Off" 大写导致选中态不匹配）
                        let active = e.state.lowercased() == m
                        Text(modeName(m))
                            .font(.system(size: 11, weight: active ? .bold : .medium))
                            .foregroundStyle(active ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(active ? Color.accentColor : Color(uiColor: .systemGray5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(active ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // v2.0.96：风速调节行（auto/低/中/高；关闭时禁用）
            if isOn {
                let fanModes = (attrs["fan_modes"] as? [String]) ?? []
                if !fanModes.isEmpty {
                    let curFan = (attrs["fan_mode"] as? String) ?? ""
                    HStack(spacing: 8) {
                        ForEach(fanModes, id: \.self) { f in
                            Button {
                                setFanMode(e, mode: f)
                            } label: {
                                let active = curFan.lowercased() == f.lowercased()
                                Text(fanModeName(f))
                                    .font(.system(size: 11, weight: active ? .bold : .medium))
                                    .foregroundStyle(active ? Color.white : Color.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(active ? Color.indigo : Color(uiColor: .systemGray5))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            // v2.0.87j：弹窗玻璃下扁平化（渐变末端白底 → 轻透明）
            LinearGradient(colors: [isOn ? Color.blue.opacity(0.20) : Color.blue.opacity(0.08), Color(uiColor: .secondarySystemGroupedBackground)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isOn ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: isOn ? Color.accentColor.opacity(0.15) : .clear, radius: 10, y: 3)
    }

    /// 模式显示名
    private func modeName(_ m: String) -> String {
        switch m {
        case "off": "关闭"
        case "auto": "自动"
        case "cool": "制冷"
        case "heat": "制热"
        case "dry": "除湿"
        case "fan_only": "送风"
        default: m
        }
    }

    /// v2.0.96：风速显示名
    private func fanModeName(_ f: String) -> String {
        switch f.lowercased() {
        case "auto": "自动"
        case "low": "低"
        case "medium", "mid": "中"
        case "high": "高"
        case "sleep": "睡眠"
        default: f
        }
    }

    /// v2.0.96：风速调节
    private func setFanMode(_ e: HAEntity, mode: String) {
        callService(domain: "climate", service: "set_fan_mode", entityID: e.entityID,
                    extra: ["fan_mode": mode])
    }

    // MARK: - 服务调用（Task 内只捕获 Sendable 值）

    private func toggle(_ e: HAEntity) {
        // switch 域实体（NAS 插座/消毒柜追加进灯列表）用 switch 服务域
        if e.entityID.hasPrefix("switch.") {
            callService(domain: "switch", service: "toggle", entityID: e.entityID, extra: nil)
        } else if domain == "climate" {
            // v2.0.102：climate 域无 toggle 服务——开=auto，关=off（原调 climate.toggle 永远无效）
            callService(domain: "climate", service: "set_hvac_mode", entityID: e.entityID,
                        extra: ["hvac_mode": e.state == "off" ? "auto" : "off"])
        } else {
            callService(domain: domain, service: "toggle", entityID: e.entityID, extra: nil)
        }
    }

    private func setMode(_ e: HAEntity, mode: String) {
        callService(domain: "climate", service: "set_hvac_mode", entityID: e.entityID,
                    extra: ["hvac_mode": mode])
    }

    private func setTemp(_ e: HAEntity, value: Double) {
        callService(domain: "climate", service: "set_temperature", entityID: e.entityID,
                    extra: ["temperature": value])
    }

    private func callService(domain: String, service: String, entityID: String, extra: [String: Any]?) {
        guard busyID == nil else { return }
        busyID = entityID
        let id = entityID
        let path = "/api/ha/services/\(domain)/\(service)"
        var body: [String: Any] = ["entity_id": id]
        if let extra { body.merge(extra) { _, new in new } }
        Task {
            defer { busyID = nil }
            do {
                _ = try await auth.request(path, method: "POST", body: body)
            } catch {
                // 控制失败静默
            }
            await load()
        }
    }

    private func load() async {
        if let arr = try? await auth.jsonArray("/api/ha/states") {
            let all = arr.compactMap { HAEntity.parse($0 as? [String: Any] ?? [:]) }
            var list = all.filter {
                $0.entityID.hasPrefix(domain + ".") && !$0.state.contains("unavailable")
            }
            if domain == "light" {
                // 灯列表过滤指示灯（NAS 查询指示灯等不参与），追加 NAS 插座/消毒柜 switch 实体（可控制）
                list = list.filter { !$0.entityID.contains("indicator_light") }
                let extraSwitches = all.filter {
                    ["switch.chuangmi_cn_237985068_m3_on_p_2_1",
                     "switch.lumi_cn_lumi_158d00039bca0b_v1_on_p_2_1"].contains($0.entityID)
                }
                list.append(contentsOf: extraSwitches)
            }
            entities = list
        }
        loading = false
    }

    /// 设备显示名：friendly_name 太长时取第一段
    private func displayName(_ e: HAEntity) -> String {
        var name = e.friendlyName
        if name.isEmpty {
            name = e.entityID
        } else {
            // 小米设备 friendly_name 常含重复（"客厅灯  客厅灯 开关"）→ 去重保留第一段
            let parts = name.split(separator: " ").filter { !$0.isEmpty }
            if parts.count >= 2 && parts[0] == parts[1] {
                name = String(parts[0])
            }
        }
        return name
    }
}

// MARK: - 磁盘弹窗（点看板"磁盘"卡弹出，2 列卡片）

struct DisksSheet: View {
    @Environment(\.dismiss) private var dismiss
    let disks: [NASDisk]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("全部磁盘")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Text("\(disks.count) 个分区")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView {
                // v3.0.36：按 kind 分组显示（系统盘分区 / 数据卷）
                let system = disks.filter { $0.isSystem }
                let data = disks.filter { !$0.isSystem }
                VStack(alignment: .leading, spacing: 14) {
                    if !system.isEmpty {
                        Text("系统盘分区")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(system) { d in
                                DiskTile(disk: d)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    if !data.isEmpty {
                        Text("数据卷")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(data) { d in
                                DiskTile(disk: d)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }
}

// MARK: - v2.0.96 场景项

struct SceneItem: Identifiable {
    let id: String
    let name: String
    let actionCount: Int
    init(_ d: [String: Any]) {
        name = d["name"] as? String ?? ""
        id = name
        actionCount = (d["actions"] as? [[String: Any]])?.count ?? 0
    }
}

// MARK: - v2.0.104 定时自动化（倒计时卡片）

struct AutomationItem: Identifiable {
    let id: String
    let name: String
    let remaining: Int
    let runAt: Date
    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? UUID().uuidString
        name = d["name"] as? String ?? "自动化"
        remaining = (d["remaining"] as? Int) ?? 0
        runAt = Date(timeIntervalSince1970: ((d["run_at"] as? Double) ?? 0))
    }
}

// MARK: - 磁盘磁贴（与 DeviceCard/MeterCard 同款 HomeKit 卡片风格）

struct DiskTile: View {
    let disk: NASDisk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(shortName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(disk.pctText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(disk.pct > 90 ? .red : (disk.pct > 75 ? .orange : .primary))
            }
            Text(disk.pctText)
                .font(.system(size: 18, weight: .bold))
                .padding(.top, 6)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: .systemGray5))
                    Capsule()
                        .fill(disk.pct > 90 ? Color.red : (disk.pct > 75 ? Color.orange : Color.green))
                        .frame(width: geo.size.width * min(max(disk.pct / 100.0, 0), 1))
                }
            }
            .frame(height: 4)
            .padding(.top, 7)
            Text("\(disk.usedText) / \(disk.totalText)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .padding(12)
        .dashboardCard()
    }

    /// 挂载点短名（/dev/mapper/... → volume1）
    private var shortName: String {
        let parts = disk.mnt.split(separator: "/").filter { !$0.isEmpty }
        return parts.last.map(String.init) ?? disk.mnt
    }
}

/// v3.0.36 模型使用量卡片（与 MeterCard/ServiceCard 同款 HomeKit 卡片风格）

/// 每 provider 一张：图标 + 名 + 余额/用量 + 副文本 + 状态；plan 模式加用量进度条
struct UsageCard: View {
    let usage: ProviderUsage

    private var statusColor: Color {
        if usage.unsupported { return .gray }
        if !usage.available { return .red }
        if usage.mode == "plan" {
            if let m = usage.usagePercent["monthly"] {
                return m >= 90 ? .red : (m >= 60 ? .orange : .green)
            }
            return .green
        }
        if usage.total <= 10 { return .orange }   // 余额低于 10 元预警
        return .green
    }

    private var icon: String {
        switch usage.provider {
        case "deepseek": return "d.circle.fill"
        case "stepfun": return "s.circle.fill"
        case "xiaomi": return "x.circle.fill"
        case "opencode-apple", "opencode": return "o.circle.fill"
        case "sensenova": return "s.square.fill"
        case "zai": return "z.circle.fill"
        default: return "terminal.fill"
        }
    }

    /// plan 模式月用量进度（0-100；无数据返回 nil 不显示条）
    private var planPercent: Double? {
        guard usage.mode == "plan" else { return nil }
        return usage.usagePercent["monthly"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(statusColor.opacity(0.15))
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 28, height: 28)
                Text(usage.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
            }
            Text(usage.balanceText)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(usage.unsupported ? Color.secondary : statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // v3.0.36 plan（opencode）：月用量进度条
            if let pct = planPercent, usage.mode == "plan" {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(uiColor: .systemGray5))
                        Capsule()
                            .fill(pct >= 90 ? Color.red : (pct >= 60 ? Color.orange : Color.green))
                            .frame(width: geo.size.width * min(max(pct / 100.0, 0), 1))
                    }
                }
                .frame(height: 4)
            }
            Text(usage.detailText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .dashboardCard()
    }
}

enum DeviceStatus { case on, off, warn }

struct DeviceCard: View {
    let name: String
    let icon: String   // v2.0.85e 图标
    let value: String
    let sub: String
    let status: DeviceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status == .on ? Color.accentColor : Color.secondary)
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.6), radius: 4)
            }
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .padding(.top, 6)
            Text(sub)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(12)
        .dashboardCard()
    }

    private var color: Color {
        switch status {
        case .on: .green
        case .off: .gray
        case .warn: .orange
        }
    }
}

struct MeterCard: View {
    let name: String
    let icon: String   // v2.0.85c 图标
    let value: String
    let sub: String?
    let ratio: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text(name).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                // 真实状态点：按使用率阈值（<75% 绿 / 75-90% 橙 / >90% 红）
                Circle()
                    .fill(ratio > 0.9 ? Color.red : (ratio > 0.75 ? Color.orange : Color.green))
                    .frame(width: 8, height: 8)
            }
            Text(value).font(.system(size: 18, weight: .bold)).padding(.top, 6)
            if let sub {
                Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: .systemGray5))
                    Capsule().fill(color).frame(width: geo.size.width * min(max(ratio, 0), 1))
                }
            }
            .frame(height: 4)
            .padding(.top, 7)
        }
        .padding(12)
        // v2.0.83：NAS 面板卡片等高（与 ServiceCard 同高，进度条自适应剩余空间）
        // v2.0.86b：卡片统一再矮一点
        .frame(height: 88, alignment: .top)
        .dashboardCard()
    }
}

struct ServiceCard: View {
    let name: String
    let icon: String   // v2.0.85c 图标
    let running: Bool
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(running ? Color.green : Color.red)
                Text(name).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(running ? Color.green : Color.red).frame(width: 8, height: 8)
            }
            Text(running ? "运行中" : "已停止")
                .font(.system(size: 14, weight: .bold))
                .padding(.top, 6)
            Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 1)
        }
        .padding(12)
        // v2.0.83：NAS 面板卡片等高（与 MeterCard 同高）
        // v2.0.86b：卡片统一再矮一点
        .frame(height: 88, alignment: .top)
        .dashboardCard()
    }
}

// MARK: - v2.0.87u 天气徽章（右上角小图标 + 温度）

struct WeatherBadge: View {
    let temp: Double?
    let code: Int?
    var city = ""   // v2.0.87ag：具体地点

    /// WMO 天气码 → SF Symbol 图标
    private var icon: String {
        guard let c = code else { return "cloud.fill" }
        switch c {
        case 0: return "sun.max.fill"
        case 1: return "sun.min.fill"
        case 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...67: return "cloud.rain.fill"
        case 71...77: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    private var iconColor: Color {
        guard let c = code else { return .secondary }
        switch c {
        case 0, 1: return .orange
        case 2: return .yellow
        case 3: return .secondary
        case 45, 48: return .gray
        case 51...82: return .blue
        case 71...77: return .cyan
        case 95...99: return .purple
        default: return .secondary
        }
    }

    var body: some View {
        // v2.0.87x：胶囊下方标注"当前定位"（v2.0.87ab：去掉胶囊内定位图标，更简洁）
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(iconColor)
                if let t = temp {
                    Text(String(format: "%.0f°", t))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                } else {
                    Text("--°")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.6))
            // v2.0.87aj：只显示城市名（去掉"当前定位"前缀）
            if !city.isEmpty {
                Text(city)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
