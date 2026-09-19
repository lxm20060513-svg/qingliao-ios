import SwiftUI

// MARK: - 看板页（智能家居 2x3 可控制 + NAS 2x3 + 磁盘弹出式）

// v3.9.25：新增 weather（天气弹窗）——注意 switch 穷尽性由 ql.py ios check 把关
enum DashboardSheet: String, Identifiable {
    case lights, climate, service, serviceHermes, disks, docker, weather
    var id: String { rawValue }
}

struct DashboardView: View {
    // v3.4.26：看板是否激活（DockTabView 直传 selected == .dashboard）——替代 Leave/Refresh 通知
    // 激活才跑 30s 轮询/切回立即刷新；去通知隐式耦合，生命周期收进自身
    var isActive: Bool = true
    @Environment(AuthStore.self) private var auth
    @Environment(\.colorScheme) private var scheme   // v3.0.9：背景毛玻璃化深浅适配
    // v3.4.28：横屏限宽
    @Environment(\.horizontalSizeClass) private var hSizeBoard

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
    // v3.9.40（#15）：看板栏目卡片自定义——顺序与显隐各自持久化（逗号分隔 BoardCard.rawValue）
    @AppStorage("dashboard_card_order") private var cardOrderRaw = ""
    @AppStorage("dashboard_hidden_cards") private var hiddenCardsRaw = ""
    @State private var showCardEditor = false

    /// 已存顺序在前；串里没出现的（首次使用 / 之后新增的栏目 / 未知键）按默认顺序补在后面
    private var orderedCards: [BoardCard] {
        let saved = cardOrderRaw.split(separator: ",").compactMap { BoardCard(rawValue: String($0)) }
        return saved + BoardCard.allCases.filter { !saved.contains($0) }
    }
    private var hiddenCards: Set<BoardCard> {
        Set(hiddenCardsRaw.split(separator: ",").compactMap { BoardCard(rawValue: String($0)) })
    }
    private var visibleCards: [BoardCard] {
        let h = hiddenCards
        return orderedCards.filter { !h.contains($0) }
    }
    @State private var haEntities: [HAEntity] = []
    @State private var router = RouterStatus()
    @State private var scrollPos = ScrollPosition()

    @State private var activeSheet: DashboardSheet?
    // v3.9.25：天气弹窗是否真的开过 —— 关灯/空调/磁盘/docker 弹窗时不该顺带重取天气
    @State private var weatherSheetShown = false
    @Namespace private var sheetZoomNS   // v3.9.0：看板卡片 → 详情弹窗 的 zoom 转场
    // v2.0.72：Docker 容器数量（看板卡片状态）
    @State private var dockerContainerCount = 0
    @State private var sceneRunning = false   // v2.0.102：场景执行防抖
    // v2.0.96：场景（AI 生成动作组，一键执行）
    @State private var scenes: [SceneItem] = []
    // v2.0.104：定时自动化（AI 生成"X分钟后执行Y"，到点自动执行后消失）
    @State private var automations: [AutomationItem] = []
    // v3.9.21：自动规则（条件触发；规则本体在后端 rules_engine 求值）
    @State private var rules: [RuleItem] = []
    @State private var pendingRuleDelete: RuleItem?
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
            // v3.9.25：本地模式此前点徽章**完全没反应**（纯展示），本次补入口 → 天气弹窗
            PageHeader(title: "看板", subtitle: "智能家居 · NAS 状态",
                       trailing: AnyView(
                        Button {
                            activeSheet = .weather
                        } label: {
                            WeatherBadge(temp: weatherTemp, code: weatherCode, city: weatherCity)
                        }
                        .buttonStyle(PressStyle(scale: 0.94))
                        .matchedTransitionSource(id: DashboardSheet.weather.id, in: sheetZoomNS)   // v3.9.25：徽章 → 天气弹窗 zoom
                        .accessibilityLabel("查看天气")
                       ))
            ScrollView {
                // v2.0.133f：VStack → LazyVStack——TabView 切页动画期间看板全量卡片一次性布局是切页卡顿主因，
                // 懒加载后只渲染可见卡片（与 v2.0.132 ChatView 消息列表同款方案；看板无批量移除路径，安全）
                LazyVStack(alignment: .leading, spacing: 10) {
                    // v3.9.40（#15）：10 个栏目由写死顺序改为按用户自定义顺序渲染（可隐藏）
                    ForEach(visibleCards) { card in
                        boardBlock(card)
                    }
                    cardEditorEntry
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, 100)
                // v3.4.28：横屏限宽居中
                .frame(maxWidth: .infinity)
                .frame(maxWidth: AdaptiveLayout.contentMaxWidth(hSizeBoard))
            }
            .scrollPosition($scrollPos)
            // v2.0.86h：Dock 滑动隐藏已删除（从未生效，手动开关替代）
            .refreshable {
                await refresh()
            }
            .sheet(item: $activeSheet, onDismiss: {
                // v3.9.25：只在**天气弹窗**关闭后刷新徽章（弹窗内换城市写 UserDefaults，此处重读）。
                // 早先无条件刷新 → 关灯/空调/磁盘/docker 弹窗也各多打一次 /api/weather，
                // 且 weatherCity 会先被重置回 UserDefaults 原值，城市名会闪一下。
                if weatherSheetShown {
                    weatherSheetShown = false
                    Task { await loadWeatherWithCity() }
                }
            }) { s in
                switch s {
                case .lights:
                    HADeviceSheet(title: "客厅灯", domain: "light")
                        .presentationDetents([.medium, .large])
                        .navigationTransition(.zoom(sourceID: DashboardSheet.lights.id, in: sheetZoomNS))   // v3.9.0
                case .climate:
                    HADeviceSheet(title: "空调", domain: "climate")
                        .presentationDetents([.medium, .large])
                        .navigationTransition(.zoom(sourceID: DashboardSheet.climate.id, in: sheetZoomNS))   // v3.9.0
                case .service:
                    ServiceControlSheet(service: .qingliao)
                        .presentationDetents([.medium])
                        .navigationTransition(.zoom(sourceID: DashboardSheet.service.id, in: sheetZoomNS))   // v3.9.0
                case .serviceHermes:
                    ServiceControlSheet(service: .hermes)
                        .presentationDetents([.medium])
                        .navigationTransition(.zoom(sourceID: DashboardSheet.serviceHermes.id, in: sheetZoomNS))   // v3.9.0
                case .disks:
                    DisksSheet(disks: nas.disks)
                        .presentationDetents([.medium, .large])
                        .navigationTransition(.zoom(sourceID: DashboardSheet.disks.id, in: sheetZoomNS))   // v3.9.0
                case .docker:
                    DockerSheet()
                        .presentationDetents([.medium, .large])
                        .navigationTransition(.zoom(sourceID: DashboardSheet.docker.id, in: sheetZoomNS))   // v3.9.0
                case .weather:
                    // v3.9.25：两页天气弹窗（今天 / 未来 5 天）。默认半屏 medium（用户定稿）；
                    // 保留 .large 作逃生口：第 2 页是纯 VStack（无 ScrollView），小屏若超出一行会被静默裁切。
                    WeatherSheet(mode: .local)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .onAppear { weatherSheetShown = true }
                        .navigationTransition(.zoom(sourceID: DashboardSheet.weather.id, in: sheetZoomNS))
                }
            }
            // v3.9.40（#15）：卡片编辑器（排序 / 隐藏）
            .sheet(isPresented: $showCardEditor) {
                BoardCardEditorSheet(all: orderedCards,
                                     hidden: orderedCards.filter { hiddenCards.contains($0) })
            }
            // v3.9.21：删除规则确认
            .alert("删除这条规则？", isPresented: Binding(
                get: { pendingRuleDelete != nil },
                set: { if !$0 { pendingRuleDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let r = pendingRuleDelete { Task { await removeRule(r) } }
                    pendingRuleDelete = nil
                }
                Button("取消", role: .cancel) { pendingRuleDelete = nil }
            } message: {
                Text(pendingRuleDelete?.name ?? "")
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
        // v2.0.96b：切回看板立即刷新（对话里生成场景后看板即时联动）
        // v2.0.102：单一刷新入口（.task 首刷+轮询）——修并发双刷/旧响应覆盖
        // v3.4.26：通知 → isActive 参数直传生命周期驱动——
        //   DockTabView 传 selected==.dashboard；task(id:) 激活即启：首刷全套 → 30s 轮询；
        //   离开 = task 取消（sleep 中断）→ 隐藏页零轮询不抢帧；切回 = task 重启自动首刷（等效原 Refresh 通知）
        .task(id: isActive) {
            guard isActive else { return }   // 隐藏态不启动（首次在非看板 tab 时无空转）
            // v2.0.86：硬件温度（CPU / NVMe）首屏加载
            await loadHw()
            // v3.0.74：从 NAS 加载钉一钉数据
            await pinStore.loadFromServer()
            // 首刷全套（首次进入 / 每次切回 task 重启都会执行——等效原 onAppear + Refresh 通知）
            await refresh()
            await loadDockerCount()
            await loadWeatherWithCity()
            // 30s 自动刷新（v2.0.87c：10→30s，省电省流量，看板数据变化不敏感）
            // v2.0.133f：仅看板可见时刷——隐藏页轮询会抢 TabView 切页动画帧（isActive 变 false → task 取消即停）
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await refresh()
                await loadHw()
            }
        }
    }

    // MARK: - v3.10.x 看板分区（巨型 body 拆分）
    //
    // 由头：此 body 单块 424 行，是本仓已踩过两次的「Unable to type-check this
    // expression in reasonable time」高危形态（一次漏检 = 20 分钟 CI 循环）。
    // 这里把每个栏目原样搬成独立 @ViewBuilder 属性 —— **纯搬运**：视图顺序、层级、
    // 条件分支、闭包、修饰符逐字未变，渲染结果与拆分前一致，只为把类型检查表达式打小。

    /// 智能建议
    @ViewBuilder
    private var smartSuggestionBlock: some View {
        // v2.0.116：智能建议（基于天气/NAS/设备状态，Agent 生成）
        // v2.0.118：门锁卡同风格（普通圆角卡背景）+ 标题左上 + 内容靠左 + 重新生成右上
        sectionTitle("智能建议")
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("今日建议")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !smartSuggestion.isEmpty {
                    Button {
                        Task { await loadSmartSuggestion() }
                    } label: {
                        // v3.9.4：只留文字 + 胶囊（去图标）
                        Text("重新生成")
                            .font(.system(size: Typography.tiny))
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, Spacing.xs)
                            .glassPillStroke()
                    }
                    .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                    .foregroundStyle(Color.accentColor)
                }
            }
            if smartLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在分析家庭状态…")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.secondary)
                }
            } else if !smartSuggestion.isEmpty {
                Text(smartSuggestion)
                    .font(.system(size: Typography.subhead))
                    .lineSpacing(LineSpacing.compact)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    Task { await loadSmartSuggestion() }
                } label: {
                    Text("生成智能建议")
                        .font(.system(size: Typography.subhead, weight: .medium))
                        .padding(.horizontal, Spacing.xxl)
                        .padding(.vertical, Spacing.sm)
                        .glassPillStroke()
                }
                .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        // v3.8.1：本来手写 background+描边、圆角 12 → 改用统一卡片样式（16），与看板/生活其它卡片对齐
        .dashboardCard()
    }

    /// 智能家居设备栅格
    @ViewBuilder
    private var homeDevicesBlock: some View {
        sectionTitle("智能家居")
    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            DeviceCard(name: "开关", icon: "lightbulb.fill", value: haLights, sub: "\(lightsOn) 盏开启 · 点击控制", status: lightsOn > 0 ? .on : .off)
                .tapButton { activeSheet = .lights }
                .matchedTransitionSource(id: DashboardSheet.lights.id, in: sheetZoomNS)   // v3.9.0：卡片→详情 zoom
            DeviceCard(name: "空调", icon: "air.conditioner.horizontal", value: haClimate, sub: "\(climateOn) 台运行中 · 点击控制", status: climateOn > 0 ? .on : .off)
                .tapButton { activeSheet = .climate }
                .matchedTransitionSource(id: DashboardSheet.climate.id, in: sheetZoomNS)   // v3.9.0：卡片→详情 zoom
            DeviceCard(name: "门锁", icon: "lock.fill", value: haLockBattery, sub: "智能门锁", status: .on)
            DeviceCard(name: "猫眼", icon: "video.fill", value: haDoorbellBattery, sub: haDoorbellOnline ? "在线" : "离线", status: haDoorbellOnline ? .on : .off)
            DeviceCard(name: "安防", icon: "shield.fill", value: haAlarm, sub: "网关警戒模式", status: haAlarmArmed ? .on : .warn)
            DeviceCard(name: "温度", icon: "thermometer", value: haTemp, sub: "室内温度", status: .on)
        }
    }

    /// 智慧场景
    @ViewBuilder
    private var scenesBlock: some View {
        // v2.0.96：场景（AI 对话生成动作组，点一下逐条执行）
        // v2.0.96b：改「智慧场景」标题 + HomeKit 卡片风格（对齐 DeviceCard）
        // v2.0.96c：空态可点击刷新（TabView 切 tab 不触发 onAppear 的 iOS 版本差异兜底）
        sectionTitle("智慧场景")
        if scenes.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                Text("暂无场景")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    // v3.9.4：刷新统一为「文字 + 胶囊」（去图标）
                    Text("刷新")
                        .font(.system(size: Typography.caption, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.xs)
                        .glassPillStroke()
                }
                .buttonStyle(PressStyle())
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
            .dashboardCard()   // v3.8.1：空态提示条统一 16
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(scenes) { s in
                    DeviceCard(name: s.name,
                               icon: "bolt.fill",
                               value: "\(s.actionCount) 个动作",
                               sub: "点击执行 · 长按删除",
                               status: .on)
                        .tapButton { runScene(s) }
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
    }

    /// 自动化
    @ViewBuilder
    private var automationsBlock: some View {
        // v2.0.104：自动化（AI 生成"X分钟后执行Y"，倒计时到点自动执行后消失）
        sectionTitle("自动化")
        if automations.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                Text("暂无自动化")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    // v3.9.4：刷新统一为「文字 + 胶囊」（去图标）
                    Text("刷新")
                        .font(.system(size: Typography.caption, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.xs)
                        .glassPillStroke()
                }
                .buttonStyle(PressStyle())
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
            .dashboardCard()   // v3.8.1：空态提示条统一 16
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
    }

    /// 自动规则
    @ViewBuilder
    private var rulesBlock: some View {
        // v3.9.21：自动规则（条件触发）——规则本体在后端 rules_engine：时间窗/HA 实体/上报事件
        // 命中且过冷却才执行；App 只负责列出、开关、删除（新建走对话/快捷指令，不在 App 里堆表单）
        if !rules.isEmpty {
            sectionTitle("自动规则")
            VStack(spacing: 10) {
                ForEach(rules) { r in
                    RuleRow(item: r,
                            onToggle: { on in
                                Task {
                                    _ = await auth.toggleRule(id: r.id, enabled: on)
                                    await loadRules()   // 无论成败都回读，避免开关显示与后端不一致
                                }
                            },
                            onDelete: { pendingRuleDelete = r })
                }
            }
            .padding(Spacing.xl)
            .dashboardCard()
        }
    }

    /// NAS 面板
    @ViewBuilder
    private var nasPanelBlock: some View {
        sectionTitle("NAS 面板")
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            MeterCard(name: "CPU", icon: "cpu.fill", value: nas.cpuText, sub: nil, ratio: nas.cpu / 100.0, color: .blue)
            MeterCard(name: "内存", icon: "memorychip.fill", value: nas.memUsedText, sub: "/ \(nas.memTotalText)", ratio: nas.memPct, color: .green)
            ServiceCard(name: "轻聊后端", icon: "server.rack", running: nas.qingliaoAlive, detail: "Docker 内存 \(nas.qingliaoDockerMemText)")
                .tapButton { activeSheet = .service }
                .matchedTransitionSource(id: DashboardSheet.service.id, in: sheetZoomNS)   // v3.9.0：卡片→详情 zoom
            ServiceCard(name: "Hermes 网关", icon: "sparkles", running: nas.hermesAlive, detail: nas.hermesMemText)
                .tapButton { activeSheet = .serviceHermes }
                .matchedTransitionSource(id: DashboardSheet.serviceHermes.id, in: sheetZoomNS)   // v3.9.0：卡片→详情 zoom
            // v2.0.72：Docker 管理卡片（点击弹部署弹窗）
            ServiceCard(name: "Docker", icon: "shippingbox.fill", running: dockerContainerCount > 0,
                        detail: dockerContainerCount > 0 ? "\(dockerContainerCount) 个容器 · 点击管理" : "暂无容器 · 点击部署")
                .tapButton { activeSheet = .docker }
                .matchedTransitionSource(id: DashboardSheet.docker.id, in: sheetZoomNS)   // v3.9.0：卡片→详情 zoom
            ServiceCard(name: "运行时间", icon: "clock.fill", running: true, detail: nas.uptime)
            // v2.0.86：硬件温度（CPU / NVMe）
            ServiceCard(name: "温度", icon: "thermometer", running: true, detail: hwDetail)
            // v3.4.13：磁盘汇总卡并入 NAS 面板网格（与温度卡等尺寸）；看板移除「系统盘」分区卡片栏目（分区已收进磁盘弹窗分组展示）
            MeterCard(name: "磁盘", icon: "internaldrive.fill", value: nas.maxDiskPctText, sub: "\(nas.disks.filter { $0.isSystem }.count) 系统盘 · \(nas.disks.filter { !$0.isSystem }.count) 数据卷 · 点击查看", ratio: nas.maxDiskPct / 100.0, color: .orange)
                .tapButton { activeSheet = .disks }
                .matchedTransitionSource(id: DashboardSheet.disks.id, in: sheetZoomNS)   // v3.9.0：卡片→详情 zoom
        }
    }

    /// 模型使用量
    @ViewBuilder
    private var usageBlock: some View {
        // v3.0.36：模型使用量（DeepSeek/StepFun 官方余额；无接口 provider 降级显示）
        // v3.4.2b：长按任意用量卡 → 只隐藏该 provider 卡（持久化）；
        // 节底部显示"已隐藏 N 个 · 点击恢复"（弹菜单逐张恢复/全部恢复）
        sectionTitle("模型使用量")
        if usageError.isEmpty && providerUsages.isEmpty {
            Text("加载中…")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .padding(.vertical, Spacing.sm)
        } else if !usageError.isEmpty {
            Text(usageError)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .padding(.vertical, Spacing.sm)
        } else {
            let visible = providerUsages.filter { !hiddenUsageProviders.contains($0.id) }
            if visible.isEmpty {
                Text("已全部隐藏 · 点下方恢复")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, Spacing.sm)
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
            usageRestoreRow()
        }
    }

    /// 设备体检
    @ViewBuilder
    private var diagnoseBlock: some View {
        // v3.0.18：设备一键体检（六维诊断：服务/磁盘/容器/负载/内存/温度）
        sectionTitle("设备体检")
        DiagnoseCard(items: diagnoseItems, level: diagnoseLevel, summary: diagnoseSummary,
                     error: diagnoseError, diagnosing: diagnosing) {
            Task { await runDiagnose() }
        }
    }

    /// 路由器
    @ViewBuilder
    private var routerBlock: some View {
        sectionTitle("路由器")
        RouterPanel(router: router,
                    onStart: { clashAction("start") },
                    onStop: { clashAction("stop") },
                    onRefresh: { Task { await loadRouter() } })
            .onAppear { Task { await loadRouter() } }
    }

    /// 钉一钉
    @ViewBuilder
    private var pinBlock: some View {
        // v3.0.74：钉一钉（聊天消息钉到看板）——始终显示
        sectionTitle("钉一钉")
        if pinStore.pins.isEmpty {
            Text("长按聊天消息 → 钉一钉")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.tertiary)
                .padding(.vertical, Spacing.md)
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

    // MARK: - 数据

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
    // v3.9.25：删掉原无参 loadWeather()——零调用点（死代码），且它是仓内第 3 份手写
    //   /api/weather 解析；解析统一走 WeatherService.parseBackend（见下方 loadWeatherWithCity）

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
            // v3.9.25：改走 WeatherService.parseBackend —— 消除仓内第 3 份手写解析，
            // 并顺带拿到 num/int 的 NaN/超范围护栏（字段语义与旧写法一致）
            let s = WeatherService.parseBackend(j)
            weatherTemp = s.temp
            weatherCode = s.code
            if !s.city.isEmpty { weatherCity = s.city }
        }
    }

    private func loadRouter() async {
        if let j = await auth.jsonOrLog("/api/router/status") {
            router = RouterStatus.parse(j)
        }
    }

    /// v3.0.36：模型使用量（DeepSeek/StepFun 余额 + unsupported 降级）
    private func loadProviderUsage() async {
        guard let j = await auth.jsonOrLog("/api/nas/providers-usage") else {
            usageError = "用量查询失败"
            return
        }
        if let ps = j["providers"] as? [[String: Any]] {
            let list = ps
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

    /// v3.9.21：自动规则（条件触发型；与上面"自动化"的延时型是两套）
    private func loadRules() async {
        rules = await auth.loadRules()
    }

    private func removeRule(_ r: RuleItem) async {
        if await auth.deleteRule(id: r.id) { await loadRules() }
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
        async let rulesTask: Void = loadRules()
        _ = await (nasTask, haTask, scenesTask, autosTask, sugTask, routerTask, usageTask, rulesTask)
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

    // v3.9.19：安防数据源改为 Aqara 网关「警戒模式」开关
    // （用户已移除萤石插件，原 sensor.she_xiang_tou_alarmstatus 不复存在；
    //   后端 ha_proxy._keep_entity 已同步放行 guard_mode，否则 App 收不到这个实体）
    private var alarm: HAEntity? {
        haEntities.first { $0.entityID.contains("guard_mode") }
    }
    private var haAlarmArmed: Bool {
        guard let st = alarm?.state else { return false }
        return ["on", "布防", "armed", "armed_home", "armed_away"].contains(st)
    }
    /// 开关的 on/off 映射成中文（原 alarmstatus 的 state 本身就是中文，可直接显示）
    private var haAlarm: String {
        guard let st = alarm?.state else { return "--" }
        if st.isEmpty || st.contains("unavailable") { return "离线" }
        return haAlarmArmed ? "布防" : "撤防"
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
            .font(.system(size: Typography.body, weight: .bold))
            .padding(.top, Spacing.sm)
    }

    /// v3.4.2b：已隐藏用量卡恢复行（点击弹菜单逐张恢复/全部恢复）——独立方法
    /// 防 confirmationDialog 动态按钮在 body 大表达式内 type-check 超时
    private func usageRestoreRow() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
            Text("已隐藏 \(hiddenUsageProviders.count) 个模型服务 · 点击恢复")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .dashboardCard()   // v3.8.1：空态提示条统一 16
        .contentShape(Rectangle())
        .tapButton { showUsageRestore = true }
        .confirmationDialog("恢复已隐藏的模型服务", isPresented: $showUsageRestore, titleVisibility: .visible) {
            ForEach(Array(hiddenUsageProviders).sorted(), id: \.self) { p in
                Button(p) { unhideUsageProvider(p) }
            }
            Button("恢复全部") { hiddenUsageRaw = "" }
            Button("取消", role: .cancel) {}
        }
    }

    /// v3.9.40（#15）：栏目 → 视图。
    /// ⚠️ 刻意返回 AnyView：10 个各异的 opaque 类型挤进同一个 @ViewBuilder switch，
    /// 表达式类型推导会超时（本仓 ChatView / ChatMessageBubble 的 body 拆分注释都是这条坑）。
    private func boardBlock(_ card: BoardCard) -> AnyView {
        switch card {
        case .suggestion:  return AnyView(smartSuggestionBlock)
        case .home:        return AnyView(homeDevicesBlock)
        case .scenes:      return AnyView(scenesBlock)
        case .automations: return AnyView(automationsBlock)
        case .rules:       return AnyView(rulesBlock)
        case .nas:         return AnyView(nasPanelBlock)
        case .usage:       return AnyView(usageBlock)
        case .diagnose:    return AnyView(diagnoseBlock)
        case .router:      return AnyView(routerBlock)
        case .pin:         return AnyView(pinBlock)
        }
    }

    /// v3.9.40（#15）：底部「自定义卡片」入口（与用量恢复行同款低调样式）
    private var cardEditorEntry: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
            Text(hiddenCards.isEmpty ? "自定义卡片（排序 / 隐藏）"
                                     : "自定义卡片 · 已隐藏 \(hiddenCards.count) 个栏目")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .dashboardCard()
        .contentShape(Rectangle())
        .tapButton { showCardEditor = true }
    }
}

// MARK: - v3.9.40（#15）看板栏目卡片身份 + 编辑器

/// rawValue 会写进 UserDefaults 的顺序串，**改名即让老用户的自定义顺序失效**——只增不改不删。
enum BoardCard: String, CaseIterable, Identifiable {
    case suggestion, home, scenes, automations, rules, nas, usage, diagnose, router, pin

    var id: String { rawValue }

    /// 与各 block 的 sectionTitle 保持一致
    var title: String {
        switch self {
        case .suggestion: return "智能建议"
        case .home: return "智能家居"
        case .scenes: return "智慧场景"
        case .automations: return "自动化"
        case .rules: return "自动规则"
        case .nas: return "NAS 面板"
        case .usage: return "模型使用量"
        case .diagnose: return "设备体检"
        case .router: return "路由器"
        case .pin: return "钉一钉"
        }
    }
}

/// ⚠️ 排序用「上移/下移」按钮而不是 List 拖动手柄：拖动要常驻 editMode，
/// 而 editMode 激活时行内按钮的点击由系统接管，这行为没法在没真机构建前验证，宁可用最朴素的按钮。
struct BoardCardEditorSheet: View {
    @AppStorage("dashboard_card_order") private var orderRaw = ""
    @AppStorage("dashboard_hidden_cards") private var hiddenRaw = ""
    @Environment(\.dismiss) private var dismiss
    @State private var shown: [BoardCard] = []
    @State private var hiddenList: [BoardCard] = []

    init(all: [BoardCard], hidden: [BoardCard]) {
        _shown = State(initialValue: all)
        _hiddenList = State(initialValue: hidden)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("显示中（↑↓ 调整顺序）") {
                    ForEach(Array(shown.enumerated()), id: \.element) { idx, card in
                        shownRow(card: card, idx: idx)
                    }
                }
                if !hiddenList.isEmpty {
                    Section("已隐藏") {
                        ForEach(hiddenList) { card in
                            HStack {
                                Text(card.title).foregroundStyle(.secondary)
                                Spacer()
                                Button("显示") { restore(card) }
                                    .accessibilityLabel("显示 \(card.title)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("自定义卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func shownRow(card: BoardCard, idx: Int) -> some View {
        HStack {
            Text(card.title)
            Spacer()
            Button { move(idx, by: -1) } label: { Image(systemName: "arrow.up") }
                .disabled(idx == 0)
                .accessibilityLabel("上移 \(card.title)")
            Button { move(idx, by: 1) } label: { Image(systemName: "arrow.down") }
                .disabled(idx == shown.count - 1)
                .accessibilityLabel("下移 \(card.title)")
            Button { hide(card, at: idx) } label: { Image(systemName: "eye.slash") }
                .accessibilityLabel("隐藏 \(card.title)")
        }
        .buttonStyle(.borderless)   // List 内按钮默认会被染色并抢走整行点击
    }

    private func move(_ idx: Int, by delta: Int) {
        let j = idx + delta
        guard shown.indices.contains(j) else { return }
        shown.swapAt(idx, j)
        persist()
    }

    private func hide(_ card: BoardCard, at idx: Int) {
        guard shown.indices.contains(idx) else { return }
        shown.remove(at: idx)
        hiddenList.append(card)
        persist()
    }

    private func restore(_ card: BoardCard) {
        hiddenList.removeAll { $0 == card }
        shown.append(card)
        persist()
    }

    private func persist() {
        // 隐藏项也留在顺序串里：否则恢复时它会被 orderedCards 补到末尾，丢掉用户原本排的位置
        orderRaw = (shown + hiddenList).map(\.rawValue).joined(separator: ",")
        hiddenRaw = hiddenList.map(\.rawValue).joined(separator: ",")
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
                    .font(.system(size: Typography.title, weight: .bold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.titleXL))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, Spacing.xl)

            // 服务信息卡
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                        .fill(Color.blue.opacity(Tint.soft))
                    Image(systemName: service.icon)
                        .font(.system(size: Typography.headline, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(service.subtitle)
                        .font(.system(size: Typography.body, weight: .semibold))
                    Text(info)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                HStack(spacing: Spacing.xs) {
                    Circle()
                        .fill(running == true ? Color.green : (running == false ? Color.red : Color.gray))
                        .frame(width: 7, height: 7)
                    Text(running == true ? "运行中" : (running == false ? "已停止" : "检测中"))
                        .font(.system(size: Typography.tiny, weight: .semibold))
                        .foregroundStyle(running == true ? Color.green : (running == false ? Color.red : Color.secondary))
                }
            }
            .padding(Spacing.xxl)
            .background(Color(uiColor: .secondarySystemGroupedBackground))  // v2.0.87h：弹窗玻璃下扁平化
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .padding(.horizontal, Spacing.section)
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
                                .font(.system(size: Typography.body, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("重试服务")
                            .font(.system(size: Typography.body, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(service == .qingliao ? "重启轻聊后端进程" : "重启 Hermes 网关进程")
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(Spacing.xxl)
                .background(Color(uiColor: .secondarySystemGroupedBackground))  // v2.0.87h：弹窗玻璃下扁平化
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }
            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.lg)

            // 停止卡（Hermes 网关不支持停止，隐藏）
            if service == .qingliao {
                Button {
                    showStopConfirm = true
                } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.red.opacity(Tint.soft))
                        Image(systemName: "stop.fill")
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("停止服务")
                            .font(.system(size: Typography.body, weight: .semibold))
                            .foregroundStyle(.red)
                        Text("停止后轻聊将不可用")
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(Spacing.xxl)
                .background(Color.red.opacity(Tint.faint))
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Color.red.opacity(Tint.strong), lineWidth: 1)
                )
            }
            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.lg)
            .confirmationDialog("停止后轻聊将完全不可用，需在 NAS 上手动启动", isPresented: $showStopConfirm, titleVisibility: .visible) {
                Button("停止服务", role: .destructive) {
                    stopService()
                }
                Button("取消", role: .cancel) {}
            }
            }

            Spacer()
        }
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
    /// v3.9.41：设备控制失败提示（此前 catch 是空的，失败只剩「转圈→开关弹回」）
    @State private var controlError = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: Typography.title, weight: .bold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.titleXL))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, Spacing.md)

            if loading {
                Spacer()
                ProgressView().tint(.secondary)
                Spacer()
            } else if entities.isEmpty {
                Spacer()
                Text("暂无可用设备")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.tertiary)
                Spacer()
            } else if domain == "light" {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(entities) { e in
                            lightCard(e)
                        }
                    }
                    .padding(.horizontal, Spacing.section)
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
                    .padding(.horizontal, Spacing.section)
                    .padding(.bottom, 20)
                }
            }
        }
        // v3.9.24：此处原有 systemBackground 实底 → 会盖住弹窗的系统材质（用户要求所有弹窗与「关于轻聊」一致 = 系统默认）→ 已删。
        // 注：v2.0.87l 那句"弹窗玻璃罩效果不佳"说的是当年的**自绘**玻璃，与 iOS 26 系统材质不是一回事，别据此回退
        .task { await load() }
        // v3.9.41：控制失败要有反馈（对齐场景卡的「场景执行结果」提示口径）
        .alert("设备控制失败", isPresented: Binding(
            get: { !controlError.isEmpty },
            set: { if !$0 { controlError = "" } }
        )) {
            Button("好的", role: .cancel) { controlError = "" }
        } message: {
            Text(controlError)
        }
    }

    // MARK: - 灯卡（PWA HomeKit 复刻：渐变图标容器 + 圆形小开关）

    private func lightCard(_ e: HAEntity) -> some View {
        let isOn = e.state == "on"
        // 拆成 AnyShapeStyle 单一类型（三元 LinearGradient vs Color 会让编译器类型检查超时）
        let iconBG: AnyShapeStyle = isOn
            ? AnyShapeStyle(LinearGradient(colors: [Color.yellow.opacity(Tint.strong), Color.orange.opacity(Tint.soft)],
                                           startPoint: .top, endPoint: .bottom))
            : AnyShapeStyle(Color(uiColor: .systemGray6))
        return Button {
            toggle(e)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // 图标容器：点亮=黄色渐变光晕 / 熄灭=灰底
                    ZStack {
                        RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                            .fill(iconBG)
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: Typography.titleXL, weight: .medium))
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
                                .font(.system(size: Typography.tiny, weight: .bold))
                                .foregroundStyle(isOn ? .white : Color.secondary)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .shadow(color: isOn ? Color.accentColor.opacity(0.45) : .clear, radius: 4)
                }
                Text(displayName(e))
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(isOn ? "已开启" : "已关闭")
                    .font(.system(size: Typography.tiny))
                    .fontWeight(isOn ? .semibold : .regular)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            }
            .padding(Spacing.xl)
            .frame(minHeight: 92)
            // v2.0.87h：弹窗液态玻璃下卡片扁平化（去白圆角底，仅极轻底区分）
            // v3.0.6 fix：卡片补描边（用户要求每个开关卡都描框）
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(Tint.subtle) : Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isOn ? 0.28 : 0.10), lineWidth: 0.8)
            )
        }
        .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
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
                    .font(.system(size: Typography.titleXL))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName(e))
                        .font(.system(size: Typography.subhead, weight: .medium))
                        .lineLimit(1)
                    Text(isOn ? modeName(e.state) : "已关闭")
                        .font(.system(size: Typography.caption, weight: .semibold))
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
                            .font(.system(size: Typography.subhead, weight: .bold))
                            .foregroundStyle(isOn ? .white : Color.secondary)
                    }
                    .frame(width: 32, height: 32)
                    .shadow(color: isOn ? Color.accentColor.opacity(0.5) : .clear, radius: 6)
                }
                .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
            }

            // 温度：目标大字 + 室温 + 步进
            HStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.0f", target))
                        .font(.system(size: 32, weight: .bold))
                        .contentTransition(.numericText(value: target))   // v3.4.29：调温数字滚动
                        .animation(Motion.snap, value: target)
                    Text("°")
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.secondary)
                }
                Text("室温 \(String(format: "%.0f", cur))°")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    setTemp(e, value: target - step)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: Typography.subhead, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Color(uiColor: .systemGray5), in: Circle())
                }
                .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                Button {
                    setTemp(e, value: target + step)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: Typography.subhead, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Color(uiColor: .systemGray5), in: Circle())
                }
                .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
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
                            .font(.system(size: Typography.caption, weight: active ? .bold : .medium))
                            .foregroundStyle(active ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                    .fill(active ? Color.accentColor : Color(uiColor: .systemGray5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                    .strokeBorder(active ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.2)
                            )
                    }
                    .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
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
                                    .font(.system(size: Typography.caption, weight: active ? .bold : .medium))
                                    .foregroundStyle(active ? Color.white : Color.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, Spacing.md)
                                    .background(
                                        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                            .fill(active ? Color.indigo : Color(uiColor: .systemGray5))
                                    )
                            }
                            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                        }
                    }
                }
            }
        }
        .padding(Spacing.xxl)
        .background(
            // v2.0.87j：弹窗玻璃下扁平化（渐变末端白底 → 轻透明）
            LinearGradient(colors: [isOn ? Color.blue.opacity(Tint.soft) : Color.blue.opacity(Tint.faint), Color(uiColor: .secondarySystemGroupedBackground)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                .strokeBorder(isOn ? Color.accentColor.opacity(0.35) : Color.white.opacity(Tint.faint), lineWidth: 1)
        )
        .shadow(color: isOn ? Color.accentColor.opacity(Tint.soft) : .clear, radius: 10, y: 3)
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
                // v3.9.41：原来这里是空的 `catch {}` —— ha_proxy 是原样透传 Home Assistant 的
                // 状态码（`_proxy` 里 `send_response(status)`），而 `AuthStore.request` 对非 2xx
                // 一定抛错，所以失败其实拿得到，只是被吞了：用户只看得到转圈→开关弹回，
                // 分不清是「HA 拒绝」还是「网断了」。下面紧接的 load() 会把状态纠正回真值（保留）。
                controlError = "「\(id)」控制失败：\(error.localizedDescription)"
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
                    .font(.system(size: Typography.title, weight: .bold))
                Spacer()
                Text("\(disks.count) 个分区")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.titleXL))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, Spacing.lg)

            ScrollView {
                // v3.0.36：按 kind 分组显示（系统盘分区 / 数据卷）
                let system = disks.filter { $0.isSystem }
                let data = disks.filter { !$0.isSystem }
                VStack(alignment: .leading, spacing: 14) {
                    if !system.isEmpty {
                        Text("系统盘分区")
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Spacing.section)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(system) { d in
                                DiskTile(disk: d)
                            }
                        }
                        .padding(.horizontal, Spacing.section)
                    }
                    if !data.isEmpty {
                        Text("数据卷")
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Spacing.section)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(data) { d in
                                DiskTile(disk: d)
                            }
                        }
                        .padding(.horizontal, Spacing.section)
                    }
                }
                .padding(.top, Spacing.md)
                .padding(.bottom, 20)
            }
        }
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

/// v3.9.21：自动规则一行（名称 + 条件摘要 + 开关；长按删除）
private struct RuleRow: View {
    let item: RuleItem
    var onToggle: (Bool) -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.enabled ? "bolt.badge.clock.fill" : "bolt.slash")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(item.enabled ? Color.orange : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: Typography.subhead, weight: .medium))
                Text(subtitle)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Toggle("", isOn: Binding(get: { item.enabled }, set: { onToggle($0) }))
                .labelsHidden()
                .tint(.orange)
        }
        .padding(.vertical, Spacing.xxs)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) { onDelete() } label: { Label("删除规则", systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)，\(item.enabled ? "已启用" : "已停用")，条件 \(item.summary)")
    }

    private var subtitle: String {
        var s = item.summary
        if let lr = item.lastRun {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            s += " · 上次 " + f.string(from: lr)
        } else if item.runCount == 0 {
            s += " · 未触发过"
        }
        return s
    }
}

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
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(disk.pctText)
                    .font(.system(size: Typography.subhead, weight: .bold))
                    .foregroundStyle(disk.pct > 90 ? .red : (disk.pct > 75 ? .orange : .primary))
            }
            Text(disk.pctText)
                .font(.system(size: Typography.headline, weight: .bold))
                .padding(.top, Spacing.sm)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: .systemGray5))
                    Capsule()
                        .fill(disk.pct > 90 ? Color.red : (disk.pct > 75 ? Color.orange : Color.green))
                        .frame(width: geo.size.width * min(max(disk.pct / 100.0, 0), 1))
                }
            }
            .frame(height: 4)
            .padding(.top, Spacing.md)
            Text("\(disk.usedText) / \(disk.totalText)")
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.tertiary)
                .padding(.top, Spacing.xs)
        }
        .padding(Spacing.xl)
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
        case "zai-coding": return "z.circle.fill"
        default: return "terminal.fill"
        }
    }

    /// plan 模式月用量进度（0-100；无数据返回 nil 不显示条）
    private var planPercent: Double? {
        guard usage.mode == "plan" else { return nil }
        return usage.usagePercent["monthly"]
    }

    /// v3.4.18：智谱双窗口主进度（5小时窗口已用百分比；无数据 nil）
    private var windowPercent: Double? {
        guard let w5 = usage.windows.first else { return nil }
        if let p = w5["used_pct"] as? Int { return Double(p) }
        if let p = w5["used_pct"] as? Double { return p }
        if let used = w5["used"] as? Int, let total = w5["total"] as? Int, total > 0 {
            return Double(used) / Double(total) * 100
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.icon, style: .continuous)
                        .fill(statusColor.opacity(0.15))
                    Image(systemName: icon)
                        .font(.system(size: Typography.subhead, weight: .medium))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 28, height: 28)
                Text(usage.name)
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
            }
            Text(usage.balanceText)
                .font(.system(size: Typography.title, weight: .bold))
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
            // v3.4.18 智谱双窗口：5小时窗口用量进度条
            else if let pct = windowPercent {
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
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(Spacing.xl)
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
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(status == .on ? Color.accentColor : Color.secondary)
                    .symbolEffect(.bounce, value: status)   // v3.9.0：设备开关状态变化弹一下
                Text(name)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.6), radius: 4)
            }
            Text(value)
                .font(.system(size: Typography.headline, weight: .bold))
                .padding(.top, Spacing.sm)
            Text(sub)
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.tertiary)
                .padding(.top, Spacing.xxs)
        }
        .padding(Spacing.xl)
        .dashboardCard()
        .scrollDepth()   // v3.9.0：滚动层次感
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
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(color)
                Text(name).font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                Spacer()
                // 真实状态点：按使用率阈值（<75% 绿 / 75-90% 橙 / >90% 红）
                Circle()
                    .fill(ratio > 0.9 ? Color.red : (ratio > 0.75 ? Color.orange : Color.green))
                    .frame(width: 8, height: 8)
            }
            Text(value)
                .font(.system(size: Typography.headline, weight: .bold).monospacedDigit())   // v3.9.19：等宽数字
                .contentTransition(.numericText())            // v3.4.29：数值滚动而非硬跳
                .animation(Motion.snap, value: value)
                .padding(.top, Spacing.sm)
            if let sub {
                Text(sub)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                    .padding(.top, Spacing.xxs)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: .systemGray5))
                    Capsule().fill(color).frame(width: geo.size.width * min(max(ratio, 0), 1))
                }
            }
            .frame(height: 4)
            .padding(.top, Spacing.md)
        }
        .padding(Spacing.xl)
        // v2.0.83：NAS 面板卡片等高（与 ServiceCard 同高，进度条自适应剩余空间）
        // v2.0.86b：卡片统一再矮一点
        .frame(height: 88, alignment: .top)
        .dashboardCard()
        .scrollDepth()   // v3.9.0：滚动层次感
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
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(running ? Color.green : Color.red)
                    .symbolEffect(.bounce, value: running)   // v3.9.0：服务启停弹一下
                Text(name).font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(running ? Color.green : Color.red).frame(width: 8, height: 8)
            }
            Text(running ? "运行中" : "已停止")
                .font(.system(size: Typography.body, weight: .bold))
                .padding(.top, Spacing.sm)
            Text(detail).font(.system(size: Typography.tiny)).foregroundStyle(.tertiary).padding(.top, Spacing.xxs)
        }
        .padding(Spacing.xl)
        // v2.0.83：NAS 面板卡片等高（与 MeterCard 同高）
        // v2.0.86b：卡片统一再矮一点
        .frame(height: 88, alignment: .top)
        .dashboardCard()
        .scrollDepth()   // v3.9.0：滚动层次感
    }
}

// MARK: - v2.0.87u 天气徽章（右上角小图标 + 温度）

struct WeatherBadge: View {
    let temp: Double?
    let code: Int?
    var city = ""   // v2.0.87ag：具体地点

    // v3.9.25：WMO 映射统一到 WeatherService（原先图标/颜色只写在这里，中文描述写在
    // 原云端工具器，已移除）。除 85/86 阵雪由 default 的 cloud.fill 修正为
    // cloud.snow.fill（与「阵雪」描述对齐）外逐字照搬，颜色未动。
    private var icon: String { WeatherCode.symbol(code) }
    private var iconColor: Color { WeatherCode.color(code) }

    var body: some View {
        // v2.0.87x：胶囊下方标注"当前定位"（v2.0.87ab：去掉胶囊内定位图标，更简洁）
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(iconColor)
                if let t = temp {
                    Text(String(format: "%.0f°", t))
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.primary)
                } else {
                    Text("--°")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.6))
            // v2.0.87aj：只显示城市名（去掉"当前定位"前缀）
            if !city.isEmpty {
                Text(city)
                    .font(.system(size: Typography.tiny, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
