import SwiftUI

// MARK: - 看板页（智能家居 2x3 可控制 + NAS 2x3 + 磁盘弹出式）

// v3.9.25：新增 weather（天气弹窗）——注意 switch 穷尽性由 ql.py ios check 把关
// v3.9.46：新增 lock/temps/doorbell/cpu/memory 五张详情弹窗（用户点名"卡片点击要看细节"）
//         + alarmArmAsk（布防/撤防确认）走 confirmationDialog，不占 sheet 通道
// v3.9.54：CPU / 内存两张详情弹窗**删除**（用户：「去掉CPU和内存卡片的弹窗，只显示卡片，
//         点击不再弹窗」）——enum 少两个 case，下面的 `.sheet(item:)` switch 同步少两个分支。
//         ⚠️ 新增/删除 case 时两处一起改，穷尽性才会被 CI 那道检查抓住。
enum DashboardSheet: String, Identifiable {
    case lights, climate, service, serviceHermes, disks, docker, weather, connectorPanel
    case lock, temps, doorbell
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
    // v3.9.82：token 用量卡（今日/本月，单位 M；后端读 Hermes state.db 的真实用量）
    @State private var tokenUsage: TokenUsage?
    @State private var tokenUsageError = ""
    // v3.4.2b：模型使用量卡隐藏集合——长按单卡只隐藏该 provider（逗号分隔 id 持久化）
    @AppStorage("dashboard_hidden_usage_providers") private var hiddenUsageRaw = ""
    @State private var showUsageRestore = false
    /// v4.0.76：「恢复已隐藏模型服务」锚定菜单——空态提示条的全局 frame
    @State private var usageRestoreAnchor: CGRect = .zero

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
    // v4.0.20：键字面量收进 BoardCardStore（单一真源），长按拖拽与编辑器共用同一对键。
    @AppStorage(BoardCardStore.orderKey) private var cardOrderRaw = ""
    @AppStorage(BoardCardStore.hiddenKey) private var hiddenCardsRaw = ""
    @State private var showCardEditor = false
    // v4.0.20：长按拖动排序的在途状态（落位几何全在 BoardCardOrder，这里只存 UI 状态）
    @State private var dragCard: BoardCard?                         // 正在被拖的栏目（nil = 没在拖）
    @State private var dragOffsetY: CGFloat = 0                     // 拖拽中的竖直位移（视觉反馈）
    @State private var sectionHeights: [BoardCard: CGFloat] = [:]   // 各栏目实测高度（落位几何要用）

    /// 完整顺序（含被隐藏的栏目）。归一化口径收在 BoardCardOrder.resolve（真值表直接编它）。
    /// SR13：去重——旧版本的编辑器把隐藏项重复写进了 dashboard_card_order，
    /// 这些脏值会一直流到这里 → 看板同一张卡片渲染两遍。parse 就地清掉，老数据自愈。
    private var orderedCards: [BoardCard] {
        BoardCardOrder.resolve(order: cardOrderRaw)
    }
    private var hiddenCards: Set<BoardCard> {
        Set(BoardCardOrder.parse(hiddenCardsRaw))   // v4.0.20：收进单一真源，别在视图里再写一份 parse
    }
    private var visibleCards: [BoardCard] {
        let h = hiddenCards
        return orderedCards.filter { !h.contains($0) }
    }
    @State private var haEntities: [HAEntity] = []
    @State private var router = RouterStatus()
    /// v3.9.41（SR36）：Clash 起停的在途闸门。原先放在 `RouterStatus.busy` 里，
    /// 而 loadRouter() 每轮整体替换 `router`（parse 出来的 busy 恒 false）→ 闸门被并发刷新解掉。
    @State private var clashBusy = false
    /// v3.9.41（SR39）：refresh() 的在途闸门（见该方法内注释）
    @State private var refreshing = false
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
    /// v3.9.41（SR38）：取消自动化的失败回执（原先 DELETE 返回值整个丢弃）
    @State private var automationError = ""
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
    // v3.9.46：安防卡点击布防/撤防。confirmArmTarget 走 confirmationDialog（危险动作既有方言，
    // 同「执行场景」「停止服务」）；alarmBusy 是下发在途闸门；alarmError 是失败回执。
    @State private var confirmArmTarget: Bool?
    @State private var alarmBusy = false
    @State private var alarmError = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // v2.0.133f：VStack → LazyVStack——TabView 切页动画期间看板全量卡片一次性布局是切页卡顿主因，
                // 懒加载后只渲染可见卡片（与 v2.0.132 ChatView 消息列表同款方案；看板无批量移除路径，安全）
                LazyVStack(alignment: .leading, spacing: BoardCardOrder.sectionSpacing) {
                    // v3.9.40（#15）：10 个栏目由写死顺序改为按用户自定义顺序渲染（可隐藏）
                    // v4.0.20：每个栏目量高（列高不等 → 落位几何必须喂实测高度）+ 拖动中的
                    //          位移/放大/阴影反馈。
                    // ⚠️ onGeometryChange 必须排在 .offset 之前 —— 它量的是栏目**自然高度**，
                    //    拖动位移不该污染高度（否则落位会拿自己算自己）。
                    ForEach(visibleCards) { card in
                        boardBlock(card)
                            // v4.0.50：量高→位移→放大→阴影→层级 5 条链折成具名组（见本文件末 applyDashboardCardChrome）
                            .modifier(DashboardCardChrome(host: self, card: card))
                    }
                    cardEditorEntry
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, 100)
                // v3.4.28：横屏限宽居中
                .frame(maxWidth: .infinity)
                .frame(maxWidth: AdaptiveLayout.contentMaxWidth(hSizeBoard))
            }
            // v4.0.50 启动链折叠：ScrollView 上 10 条修饰器折成两个具名组。
            // 滚动定位/下拉刷新/三张 sheet → DashboardScrollChrome；
            // 三条 alert + 两条 confirmationDialog → DashboardDialogChrome。
            // 视图树与语义逐条守恒，链在本文件末的 applyXxx 里解析。
            // v4.0.62：滚边玻璃（`safeAreaBar`）推广 —— 页头从 VStack 第一行改挂在滚动视图上，
            // 滚动时内容在页头下沿走系统级模糊/渐隐（同生活页 v4.0.61 试点形态，逐字同款）。
            // 回退：删掉本块、在 VStack 第一行恢复 PageHeader(...) 即可。
            .safeAreaBar(edge: .top) {
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
            }
            .modifier(DashboardScrollChrome(host: self))
            .modifier(DashboardDialogChrome(host: self))
        }
        // v4.0.71：页底接主题环境渐变（与聊天/会话/生活/设置四页同源同法）——
        //   看板是唯一没接页底的 tab（`EnvironmentGlowLayers` 此前全仓 6 处都不含 Dashboard），
        //   用户 2026-10-07 真机反馈「各个 tab 的渐变背景渲染还有问题」。
        //   纯视觉层：垫在整页最底层，卡片/毛玻璃透出彩底；不改布局、不拦手势。
        .background(EnvironmentGlowLayers(scheme: scheme))
        // 🚨 v4.0.77：锚定菜单浮层挂**整页最外层**（原挂在「已隐藏 N 个模型服务」行上，层序被后续卡片盖住）。
        .overlay { dashboardAnchorMenuLayer }
        // v2.0.96b：切回看板立即刷新（对话里生成场景后看板即时联动）
        // v2.0.102：单一刷新入口（.task 首刷+轮询）——修并发双刷/旧响应覆盖
        // v3.4.26：通知 → isActive 参数直传生命周期驱动——
        //   DockTabView 传 selected==.dashboard；task(id:) 激活即启：首刷全套 → 30s 轮询；
        //   离开 = task 取消（sleep 中断）→ 隐藏页零轮询不抢帧；切回 = task 重启自动首刷（等效原 Refresh 通知）
        .task(id: isActive) {
            await dashboardTask()
        }
    }

    // MARK: - v4.0.77 锚定菜单浮层（挂整页最外层）

    /// 恢复已隐藏模型服务 → 锚定浮层（从「已隐藏 N 个模型服务」条处弹出、点空白收回）。
    /// 由 body 最外层的 `.overlay` 挂载（不能挂在被点那一行上 —— 层序会被后面的卡片盖住）。
    @ViewBuilder
    private var dashboardAnchorMenuLayer: some View {
        if showUsageRestore {
            AnchorMenuOverlay(
                anchorFrame: usageRestoreAnchor,
                items: Array(hiddenUsageProviders).sorted().map { p in
                    AnchorMenuItem(id: p, title: p, icon: "eye", color: .blue)
                } + [AnchorMenuItem(id: "__all", title: "恢复全部", icon: "arrow.counterclockwise", color: .orange)],
                title: "恢复已隐藏的模型服务",
                onPick: { item in
                    showUsageRestore = false
                    if item.id == "__all" { hiddenUsageRaw = "" }
                    else { unhideUsageProvider(item.id) }
                },
                onClose: { showUsageRestore = false }
            )
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
        sectionTitle("智能建议", card: .suggestion)
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
        sectionTitle("智能家居", card: .home)
    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            DeviceCard(name: "开关", icon: "lightbulb.fill", value: haLights, sub: "\(lightsOn) 盏开启 · 点击控制", status: lightsOn > 0 ? .on : .off)
                .tapButton { activeSheet = .lights }
                .matchedTransitionSource(id: DashboardSheet.lights.id, in: sheetZoomNS)   // v3.9.0：卡片→详情 zoom
            DeviceCard(name: "空调", icon: "air.conditioner.horizontal", value: haClimate, sub: "\(climateOn) 台运行中 · 点击控制", status: climateOn > 0 ? .on : .off)
                .tapButton { activeSheet = .climate }
                .matchedTransitionSource(id: DashboardSheet.climate.id, in: sheetZoomNS)   // v3.9.0：卡片→详情 zoom
            // v3.9.46：门锁/猫眼/温度三张只读卡接上详情弹窗；安防卡接上布防/撤防
            // （sub 文案同时当"可点"的提示，样式与既有 灯/空调 卡一致：tapButton + zoom 转场）
            DeviceCard(name: "门锁", icon: "lock.fill", value: haLockBattery,
                       sub: "点击看锁体状态", status: .on)
                .tapButton { activeSheet = .lock }
                .matchedTransitionSource(id: DashboardSheet.lock.id, in: sheetZoomNS)
            DeviceCard(name: "猫眼", icon: "video.fill", value: haDoorbellBattery,
                       sub: (haDoorbellOnline ? "在线" : "离线") + " · 点击详情",
                       status: haDoorbellOnline ? .on : .off)
                .tapButton { activeSheet = .doorbell }
                .matchedTransitionSource(id: DashboardSheet.doorbell.id, in: sheetZoomNS)
            DeviceCard(name: "安防", icon: "shield.fill", value: haAlarm,
                       sub: alarmSub, status: haAlarmArmed ? .on : .warn)
                .tapButton { requestArm(!haAlarmArmed) }
            DeviceCard(name: "温度", icon: "thermometer", value: haTemp,
                       sub: "室内温度 · 点击看各房间", status: .on)
                .tapButton { activeSheet = .temps }
                .matchedTransitionSource(id: DashboardSheet.temps.id, in: sheetZoomNS)
        }
    }

    /// 智慧场景
    @ViewBuilder
    private var scenesBlock: some View {
        // v2.0.96：场景（AI 对话生成动作组，点一下逐条执行）
        // v2.0.96b：改「智慧场景」标题 + HomeKit 卡片风格（对齐 DeviceCard）
        // v2.0.96c：空态可点击刷新（TabView 切 tab 不触发 onAppear 的 iOS 版本差异兜底）
        sectionTitle("智慧场景", card: .scenes)
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
        sectionTitle("自动化", card: .automations)
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
        // v3.9.41（SR38）：取消失败的可见回执
        if !automationError.isEmpty {
            Text("⚠️ \(automationError)")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.orange)
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.xs)
        }
    }

    /// 自动规则
    @ViewBuilder
    private var rulesBlock: some View {
        // v3.9.21：自动规则（条件触发）——规则本体在后端 rules_engine：时间窗/HA 实体/上报事件
        // 命中且过冷却才执行；App 只负责列出、开关、删除（新建走对话/快捷指令，不在 App 里堆表单）
        if !rules.isEmpty {
            sectionTitle("自动规则", card: .rules)
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
        sectionTitle("NAS 面板", card: .nas)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            // v3.9.46：CPU / 内存卡曾接详情弹窗；**v3.9.54 用户判掉**：「去掉CPU和内存卡片的弹窗，
            // 只显示卡片，点击不再弹窗」→ 摘掉 tapButton 与 zoom 源，sub 里那句"点击查看"一并改实话。
            MeterCard(name: "CPU", icon: "cpu.fill", value: nas.cpuText,
                      sub: "整机占用", ratio: nas.cpu / 100.0, color: .blue)
            MeterCard(name: "内存", icon: "memorychip.fill", value: nas.memUsedText,
                      sub: "/ \(nas.memTotalText)", ratio: nas.memPct, color: .green)
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
        sectionTitle("模型使用量", card: .usage)
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

    /// token 用量（v3.9.82：今日/本月，单位 M）
    @ViewBuilder
    private var tokenUsageBlock: some View {
        sectionTitle("token 用量", card: .tokens)
        if let u = tokenUsage {
            TokenUsageCard(usage: u, onReset: { Task { await resetTokenUsage() } })
        } else if !tokenUsageError.isEmpty {
            Text(tokenUsageError)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .padding(.vertical, Spacing.sm)
        } else {
            Text("加载中…")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .padding(.vertical, Spacing.sm)
        }
    }

    /// 设备体检
    @ViewBuilder
    private var diagnoseBlock: some View {
        // v3.0.18：设备一键体检（六维诊断：服务/磁盘/容器/负载/内存/温度）
        sectionTitle("设备体检", card: .diagnose)
        DiagnoseCard(items: diagnoseItems, level: diagnoseLevel, summary: diagnoseSummary,
                     error: diagnoseError, diagnosing: diagnosing) {
            Task { await runDiagnose() }
        }
    }

    /// 路由器
    @ViewBuilder
    private var routerBlock: some View {
        sectionTitle("路由器", card: .router)
        RouterPanel(router: router,
                    busy: clashBusy,
                    onStart: { clashAction("start") },
                    onStop: { clashAction("stop") },
                    onRefresh: { Task { await loadRouter() } })
            .onAppear { Task { await loadRouter() } }
    }

    /// 钉一钉
    @ViewBuilder
    private var pinBlock: some View {
        // v3.0.74：钉一钉（聊天消息钉到看板）——始终显示
        sectionTitle("钉一钉", card: .pin)
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
    // v3.9.46：先查进程内天气缓存——看板每次切回、弹窗每次关闭都不再重打 /api/weather
    private func loadWeatherWithCity() async {
        weatherCity = UserDefaults.standard.string(forKey: "qingliao_weather_city") ?? ""
        guard !weatherCity.isEmpty else {
            weatherTemp = nil
            weatherCode = nil
            return
        }
        let key = weatherCity          // 缓存键固定用用户存的城市原名（下面会把 weatherCity 换成后端回的名字）
        if let hit = WeatherCache.value(city: key) {
            weatherTemp = hit.temp
            weatherCode = hit.code
            if !hit.city.isEmpty { weatherCity = hit.city }
            return
        }
        let enc = weatherCity.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? weatherCity
        if let j = await auth.jsonOrLog("/api/weather?city=\(enc)") {
            // v3.9.25：改走 WeatherService.parseBackend —— 消除仓内第 3 份手写解析，
            // 并顺带拿到 num/int 的 NaN/超范围护栏（字段语义与旧写法一致）
            let s = WeatherService.parseBackend(j)
            WeatherCache.put(city: key, snap: s)
            weatherTemp = s.temp
            weatherCode = s.code
            if !s.city.isEmpty { weatherCity = s.city }
        }
    }

    private func loadRouter() async {
        if let j = await auth.jsonOrLog("/api/router/status") {
            router = RouterStatus.parse(j)
        } else {
            // v3.9.41（SR36）：原先 nil 就什么都不写 → 路由器连不上时卡片静默挂着上一轮的旧数字，
            // 用户以为还是实时值。失败要落到卡片下方那行红字上。
            router.error = "路由器状态获取失败"
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

    /// v3.9.82：token 用量（今日/本月，单位 M）——后端 /api/nas/token-usage 读 Hermes state.db
    private func loadTokenUsage() async {
        guard let j = await auth.jsonOrLog("/api/nas/token-usage") else {
            tokenUsageError = "token 用量查询失败"
            return
        }
        if let u = TokenUsage.parse(j) {
            tokenUsage = u
            tokenUsageError = ""
        } else if let e = j["error"] as? String, !e.isEmpty {
            tokenUsageError = e
        } else {
            tokenUsageError = "token 用量暂不可用"
        }
    }

    /// v3.9.85：长按 token 卡 → 重置统计（后端记重置起点，今日/本月旧账不再计入）
    private func resetTokenUsage() async {
        do {
            let (data, resp) = try await auth.request("/api/nas/token-usage-reset", method: "POST", body: [:])
            let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard resp.statusCode == 200, (j?["ok"] as? Bool) == true else {
                tokenUsageError = "重置失败，请重试"
                return
            }
            Haptics.notify(.success)
            await loadTokenUsage()
        } catch {
            tokenUsageError = "重置失败，请重试"
        }
    }

    /// 快捷指令：启动/关闭 Clash
    private func clashAction(_ action: String) {
        // v2.0.102：防抖——操作中再点直接忽略（原两个并发 Task 各自 defer 释放 busy 互相覆盖）
        // SR36：闸门挪到 @State clashBusy。原先存 `router.busy`，而本方法结尾必然 `await loadRouter()`
        // 整体替换 router（parse 出来的 busy 恒 false）、30s 轮询也会替换 → 闸门形同虚设，连点即并发下发。
        guard !clashBusy else { return }
        clashBusy = true
        Task {
            defer { clashBusy = false }
            var reqFailed = false
            if let j = await auth.jsonOrLog("/api/router/clash/\(action)", method: "POST", body: nil) {
                // v2.0.92：操作成功清空错误显示（失败原因由后端按"服务已启动"输出判断）
                if (j["ok"] as? Bool) == true {
                    router.error = ""
                }
                router = RouterStatus.merge(router, with: j)
            } else {
                reqFailed = true
            }
            await loadRouter()
            if reqFailed {
                // SR36：请求整个失败（非 2xx/超时）原先连一行提示都不留 → 「点了没反应」
                router.error = "Clash \(action == "start" ? "启动" : "关闭")请求失败"
            }
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
        // v3.9.41（SR39）：在途闸门。下拉刷新、30s 轮询、空态「刷新」按钮、执行场景后的补刷
        // 都调这里，原先无闸门 → 多份「8 路并发」同时在飞：蜂窝下成倍流量，且晚到的旧响应会把
        // 新值写回去（@State 逐个覆盖，没有序号判定）。重入直接返回——那一轮本来就会拿到新数据。
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
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
        // v3.9.82：token 用量与其余 8 路并发（同一个在途闸门覆盖）
        async let tokenTask: Void = loadTokenUsage()
        _ = await (nasTask, haTask, scenesTask, autosTask, sugTask, routerTask, usageTask, rulesTask, tokenTask)
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

    // MARK: v3.9.46 安防布防 / 撤防

    /// 点击安防卡：先确认再下发（布防/撤防是会改变家庭安防状态的动作，误触代价高）
    private func requestArm(_ armed: Bool) {
        guard alarm != nil else {
            alarmError = "没找到网关警戒开关（guard_mode），无法布防/撤防"
            Haptics.error()
            return
        }
        guard !alarmBusy else { return }        // 在途连点直接吞（同 clashAction 的防抖口径）
        confirmArmTarget = armed
    }

    /// 真正下发：Aqara 网关警戒模式是个 switch 实体 ⇒ 走 HA 通用服务口
    /// POST /api/ha/services/switch/turn_on|turn_off（与 HADeviceSheet 控制灯/空调同一条通道）。
    /// 失败一定要出声（v3.9.41 在 HADeviceSheet 修过一次同样的"静默吞错"），
    /// 成功后立刻回读 /api/ha/states 让卡片显示真值，不做乐观更新。
    private func applyArm(_ armed: Bool) {
        guard let e = alarm else { return }
        alarmBusy = true
        let path = armed ? "/api/ha/services/switch/turn_on" : "/api/ha/services/switch/turn_off"
        Task {
            defer { alarmBusy = false }
            do {
                _ = try await auth.request(path, method: "POST", body: ["entity_id": e.entityID])
                Haptics.success()
            } catch {
                alarmError = "\(armed ? "布防" : "撤防")失败：\(error.localizedDescription)"
                Haptics.error()
            }
            await loadHA()
        }
    }

    /// confirmationDialog 的按钮单独抽出来：动态按钮塞进 body 大表达式里撞过类型检查超时
    /// （见 usageRestoreRow / ChatView.chatActionDialogContent 的同款处理）
    @ViewBuilder
    private var armDialogButtons: some View {
        Button(confirmArmTarget == true ? "确认布防" : "确认撤防",
               role: confirmArmTarget == true ? nil : .destructive) {
            if let t = confirmArmTarget { applyArm(t) }
            confirmArmTarget = nil
        }
        Button("取消", role: .cancel) { confirmArmTarget = nil }
    }

    private var armDialogMessage: String {
        confirmArmTarget == true
            ? "网关进入警戒模式后，门窗被打开会立即告警。"
            : "撤防后家中不再告警，请确认不是误触。"
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
    /// v3.9.41（SR38）：原先 `_ = await jsonOrLog(...)` 丢弃返回值就本地摘除——后端没删成时
    /// 30s 轮询把它原样拉回，用户以为已取消、到点照样执行场景。现按响应走：成功用后端列表覆盖。
    private func cancelAutomation(_ a: AutomationItem) {
        automationError = ""
        Task {
            do {
                let j = try await auth.json("/api/automations/\(a.id)", method: "DELETE", body: nil)
                guard (j["ok"] as? Bool) ?? false else {
                    automationError = "取消失败：\(j["message"] as? String ?? "服务器未删除")"
                    return
                }
                if let list = j["automations"] as? [[String: Any]] {
                    automations = list.map { AutomationItem($0) }
                } else {
                    automations.removeAll { $0.id == a.id }
                }
            } catch {
                automationError = "取消失败：\(error.localizedDescription)"
            }
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

    // MARK: v3.9.46 卡片详情弹窗的数据切片（都在已轮询的 haEntities 里挑，零新接口）

    /// 实体是否"可用"（v3.9.54 收口，用户：「只保留可用卡片，离线卡片不显示」）：
    /// 三张设备弹窗（门锁/猫眼/温度）共用这一条判定。HA 的离线是**状态串**而不是独立标记，
    /// 常见三种写法都要认（`unavailable` / `offline` / `unknown`），口径同既有 `climates` 过滤。
    private func isAvailable(_ e: HAEntity) -> Bool {
        let st = e.state
        return !st.isEmpty && !st.contains("unavailable")
            && !["offline", "unknown"].contains(st)
    }

    /// v3.9.74 P1.5 连接器面板：可用实体总数（与 isAvailable 同口径，只读已轮询数据零新请求）
    private var haAvailableCount: Int {
        haEntities.filter(isAvailable).count
    }

    /// v3.9.74 P1.5：连接器面板关闭后要接着弹的设置页（防 sheet 叠 sheet，dismiss 后再弹）
    @State private var pendingSheetAfterPanel: AfterPanelSheet?
    // v3.9.74c：面板关闭后真正呈现在弹的设置页（与 pending 意图分开，防 dismiss/present 同帧抖动）
    @State private var presentedAfterPanel: AfterPanelSheet?
    enum AfterPanelSheet: String, Identifiable {
        case mcp, lifeCards, mail, cloudDrive
        var id: String { rawValue }
    }

    /// v3.9.74 P1.5 连接器面板（Muse 借鉴）：MCP 工具 + 智能家居 + 生活卡片 收拢总览。
    /// 不重复实现功能，状态总览 + 直达入口：点卡片 → 面板关闭 → 再弹对应设置页。
    @ViewBuilder
    private var connectorsBlock: some View {
        sectionTitle("连接器", card: .connectors)
        // 与钉一钉同款「始终显示 + 低调提示」形态
        Button {
            activeSheet = .connectorPanel
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "rectangle.connected.to.line.2")
                    .font(.system(size: Typography.title))
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP 工具 · 智能家居 · 生活卡片")
                        .font(.system(size: Typography.body, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("AI 已接入的数字生活总览与入口")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, Spacing.md)
        }
        .buttonStyle(.plain)
    }

    /// 门锁相关实体：门锁本体（bacn01）+ lock 域 + 门磁一类含 door_lock 的实体。
    /// v3.9.54：再叠一层 `isAvailable` —— 离线的实体不进弹窗（用户点名）。
    /// ⚠️ 实际能到这里的不多：后端 `ha_proxy._keep_entity` 只放行 `(bacn01|chuangmi) + battery_level`
    ///    这类少数实体，`lock.*` 域根本没下发，所以这张弹窗目前基本只有"门锁电量"一枚卡。
    ///    要弹窗里出现锁体开关量，得先放宽后端白名单（那是后端改动，不在本轮）。
    private var lockEntities: [HAEntity] {
        haEntities.filter {
            ($0.entityID.contains("bacn01")
                || $0.entityID.hasPrefix("lock.")
                || $0.entityID.contains("door_lock"))
                && isAvailable($0)
        }
        .sorted { $0.entityID < $1.entityID }
    }

    /// 猫眼 / 门铃：**只保留「小白智能猫眼」这台设备自己的实体**（v3.9.54 用户点名）。
    /// 原来写的是 `contains("chuangmi") || contains("doorbell")` —— 创米（chuangmi）是品牌名，
    /// 家里那枚**创米小白智能插座** `switch.chuangmi_cn_237985068_m3_on_p_2_1`
    /// 也是 chuangmi，于是被一起拽进弹窗，看着就是"猫眼弹窗里有个不相干的东西"。
    /// 现在：品牌命中后还要过两道排除（开关域、插座型号 `_m3_` / `on_p_2_1` / `plug`），
    /// 并滤掉离线实体。
    private var doorbellEntities: [HAEntity] {
        haEntities.filter {
            ($0.entityID.contains("chuangmi") || $0.entityID.contains("doorbell")
                || $0.friendlyName.contains("猫眼"))
                && !isDoorbellPlug($0.entityID)
                && isAvailable($0)
        }
        .sorted { $0.entityID < $1.entityID }
    }

    /// 创米小白**插座**（不是猫眼）：开关域本体 + 它的子通道/电量传感器一律算插座。
    /// 插座实体名里带 `_m3_`（型号 M3）或 `on_p_2_1`（miio 通道），据此识别。
    private func isDoorbellPlug(_ id: String) -> Bool {
        id.hasPrefix("switch.") || id.contains("_m3_") || id.contains("on_p_2_") || id.contains("_plug")
    }

    /// 全部可用的温度计（卡片只显室内那一个，弹窗列各房间）
    private var roomTempEntities: [HAEntity] {
        haEntities.filter {
            $0.entityID.hasPrefix("sensor.")
                && $0.entityID.contains("temperature")
                && Double($0.state) != nil
                && isAvailable($0)
        }
        .sorted { $0.friendlyName < $1.friendlyName }
    }

    /// 安防卡副标题：没有 guard_mode 实体时要说实话，别写"点击布防"骗人
    private var alarmSub: String {
        if alarm == nil { return "未找到网关警戒开关" }
        if alarmBusy { return "正在下发…" }
        return haAlarmArmed ? "布防中 · 点击撤防" : "已撤防 · 点击布防"
    }

    /// v4.0.20：栏目头 = 标题 + 尾部「拖动把手」图标，并挂**长按拖动排序**手势。
    /// ⚠️ 手势只落在栏目头这一行（纯 Text/Image，没有别的交互子视图）——
    ///    看板里不少栏目内容自带长按（UsageCard / 场景卡 / 自动化卡的 contextMenu、
    ///    TokenUsageCard 的「重置」长按），若把拖动挂在整块栏目上，那些既有长按会被拖动会话吃掉。
    private func sectionTitle(_ s: String, card: BoardCard) -> some View {
        HStack(spacing: Spacing.sm) {
            // v4.0.85：行首图标底（与生活页板块头 v4.0.84 方案 B① 同款：20pt BadgeShell + 白符号）。
            // 符号 / 配色只读 BoardCardStyle.swift 那一份（card.icon / card.tint），别在这里内联；
            // 几何走 BadgeShell —— 别手写 cornerRadius（LifeBadges.swift 头注：「迟早漂移」）。
            Image(systemName: card.icon)
                .font(.system(size: 20 * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .modifier(BadgeShell(size: 20, color: card.tint))
            Text(s)
                .font(.system(size: Typography.body, weight: .bold))
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(dragCard == card ? Color.accentColor : Color.secondary.opacity(0.5))
        }
        .padding(.top, Spacing.sm)
        .contentShape(Rectangle())   // 整行都可长按（不只盯着那两个字）
        .accessibilityLabel("\(s)，长按可拖动调整顺序")
        .simultaneousGesture(boardDragGesture(card))
    }

    /// v4.0.20：长按栏目头进入拖动 → 松手按落位几何换位并落盘。
    /// 手法与首页卡片一致（Core/HomeCardOrder.swift 那套）：长按 + 拖动序列手势。
    /// 栏目头没有 Button，理论上 `.gesture` 也够，但沿用 simultaneousGesture 以防将来栏目头加按钮时被抢。
    private func boardDragGesture(_ card: BoardCard) -> some Gesture {
        LongPressGesture(minimumDuration: BoardCardOrder.longPressSeconds)
            .sequenced(before: DragGesture(minimumDistance: 2))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if dragCard != card {
                    withAnimation(Motion.snap) { dragCard = card; dragOffsetY = 0 }
                    Haptics.tap()
                }
                dragOffsetY = drag?.translation.height ?? 0
            }
            .onEnded { value in
                guard dragCard == card else { dragCard = nil; dragOffsetY = 0; return }
                var dy: CGFloat = 0
                if case .second(true, let drag?) = value { dy = drag.translation.height }
                dragCard = nil
                dragOffsetY = 0
                // 手指按住没动（位移 < 阈值）→ 不算拖动，松手不换位
                guard BoardCardOrder.isRealDrag(dx: 0, dy: Double(dy)),
                      let from = visibleCards.firstIndex(of: card) else { return }
                let heights = visibleCards.map { Double(sectionHeights[$0] ?? 0) }
                let target = BoardCardOrder.dragTarget(from: from, dy: Double(dy),
                                                       heights: heights,
                                                       spacing: Double(BoardCardOrder.sectionSpacing))
                guard target != from else { return }
                withAnimation(Motion.settle) { applyBoardMove(card, to: target) }
                Haptics.success()
            }
    }

    /// v4.0.20：换位后写回**完整**顺序（被隐藏的栏目留在原槽）+ 落盘到既有键。
    /// 落位/写回几何全在 BoardCardOrder（UI 只负责量尺寸与调它，不自拼顺序）。
    private func applyBoardMove(_ card: BoardCard, to target: Int) {
        let moved = BoardCardOrder.move(visibleCards, kind: card, to: target)
        let full = BoardCardOrder.mergeVisible(oldFull: orderedCards,
                                               newVisible: moved,
                                               hidden: hiddenCards)
        cardOrderRaw = BoardCardOrder.encode(full)
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
        // v4.0.76：锚点采集——空态提示条全局 frame（恢复菜单从条位置弹出；原居中 confirmationDialog）
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            usageRestoreAnchor = $0
        }
        // 🚨 v4.0.77：恢复菜单浮层**从这里挪到整页最外层**（与聊天页三点菜单同族问题）——
        // 挂在「已隐藏 N 个模型服务」这一行上时，`.overlay` 的层序跟同级兄弟一致：后面的看板卡片
        // 压在上面 → 菜单被卡片盖住，轻纱也只罩住一行。见 dashboardAnchorMenuLayer + body 最外层 .overlay。
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
        case .tokens:      return AnyView(tokenUsageBlock)
        case .diagnose:    return AnyView(diagnoseBlock)
        case .router:      return AnyView(routerBlock)
        case .pin:         return AnyView(pinBlock)
        case .connectors:  return AnyView(connectorsBlock)
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
    // MARK: - v3.9.100+ 弹窗与刷新逻辑（巨型 body 拆分）
    //
    // 由头：L118..L344 的 227 行 body 是本仓已踩过两次的「Unable to type-check this
    // expression in reasonable time」高危形态（一次漏检 = 20 分钟 CI 循环）。
    // sheet 的 switch 尤其致命：13 个 case 各带 detent + zoom 转场，合成一个大表达式。
    // 这里原样搬成下面三个成员 —— 视图顺序、层级、闭包、修饰符逐字未变。

    /// activeSheet 弹窗内容（原 body 内 `.sheet(item:onDismiss:)` 的 switch）
    @ViewBuilder
    private func sheetContent(for s: DashboardSheet) -> some View {
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
        // v3.9.46：三张设备详情弹窗（统一 BoardSheetHeader 头部、统一 medium/large detents、
        // 统一 zoom 转场 —— 用户要求"弹窗样式统一"）
        // v3.9.54：卡形换成抄磁盘分区卡（两列网格），**离线实体不再列进来**，
        // 所以计数文案改成"可用"（口径见 DashboardView.isAvailable）
        case .lock:
            HADeviceDetailSheet(title: "门锁",
                                detail: "\(lockEntities.count) 个可用实体",
                                entities: lockEntities,
                                emptyTitle: "门锁现在没有可用实体",
                                emptySubtitle: "离线实体不列（v3.9.54）；门锁电量来自 "
                                    + "/api/ha/states（看板 30s 轮询），若刚换过电池或重新配网，"
                                    + "下拉看板重取一次")
                .presentationDetents([.medium, .large])
                .navigationTransition(.zoom(sourceID: DashboardSheet.lock.id, in: sheetZoomNS))
        case .temps:
            HADeviceDetailSheet(title: "各房间温度",
                                detail: "\(roomTempEntities.count) 个温度计",
                                entities: roomTempEntities,
                                emptyTitle: "没有读到温度传感器",
                                emptySubtitle: "看板卡片只取一个室内温度，这里列全所有 temperature 实体")
                .presentationDetents([.medium, .large])
                .navigationTransition(.zoom(sourceID: DashboardSheet.temps.id, in: sheetZoomNS))
        case .doorbell:
            HADeviceDetailSheet(title: "猫眼",
                                detail: "\(doorbellEntities.count) 个可用实体",
                                entities: doorbellEntities,
                                emptyTitle: "没有读到猫眼的实体",
                                emptySubtitle: "这里只列小白智能猫眼自己的实体（创米插座已排除）；"
                                    + "画面快照后端未透出，离线实体也不列")
                .presentationDetents([.medium, .large])
                .navigationTransition(.zoom(sourceID: DashboardSheet.doorbell.id, in: sheetZoomNS))
        // v3.9.54：CPU / 内存弹窗已删（用户：只显示卡片，点击不再弹窗）
        case .weather:
            // v3.9.25：两页天气弹窗（今天 / 未来 5 天）。默认半屏 medium（用户定稿）；
            // 保留 .large 作逃生口：第 2 页是纯 VStack（无 ScrollView），小屏若超出一行会被静默裁切。
            WeatherSheet(mode: .local)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .onAppear { weatherSheetShown = true }
                .navigationTransition(.zoom(sourceID: DashboardSheet.weather.id, in: sheetZoomNS))
        case .connectorPanel:
            // v3.9.74 P1.5 连接器面板：MCP + 智能家居 + 生活卡 收拢总览（Muse 借鉴）。
            // 面板内跳转走本页已有 sheet 机制；MCP/生活卡设置弹窗在面板 dismiss 后弹出（防 sheet 叠 sheet）。
            ConnectorPanelSheet(
                onOpenMCP: { activeSheet = nil; pendingSheetAfterPanel = .mcp },
                onOpenLifeCards: { activeSheet = nil; pendingSheetAfterPanel = .lifeCards },
                onOpenMail: { activeSheet = nil; pendingSheetAfterPanel = .mail },
                onOpenCloudDrive: { activeSheet = nil; pendingSheetAfterPanel = .cloudDrive },
                haCount: haAvailableCount,
                sceneCount: scenes.count,
                automationCount: automations.count,
                ruleCount: rules.count)
                .presentationDetents([.medium, .large])
                .navigationTransition(.zoom(sourceID: DashboardSheet.connectorPanel.id, in: sheetZoomNS))
        }
    }

    /// 看板 sheet 关闭后的收尾：刷新天气徽章 / 消费面板跳转意图
    private func dashboardSheetDismiss() {
        // v3.9.25：只在**天气弹窗**关闭后刷新徽章（弹窗内换城市写 UserDefaults，此处重读）。
        // 早先无条件刷新 → 关灯/空调/磁盘/docker 弹窗也各多打一次 /api/weather，
        // 且 weatherCity 会先被重置回 UserDefaults 原值，城市名会闪一下。
        if weatherSheetShown {
            weatherSheetShown = false
            Task { await loadWeatherWithCity() }
        }
        // v3.9.74c P1.5：连接器面板关闭（dismiss 已完成）后再弹 MCP/生活卡设置页。
        // 回调只关面板+记意图；这里消费意图，async 一帧错开 dismiss 收尾，防 present 请求被静默吞。
        if let p = pendingSheetAfterPanel {
            pendingSheetAfterPanel = nil
            DispatchQueue.main.async { presentedAfterPanel = p }
        }
    }

    /// 看板生命周期：首刷全套 + 30s 轮询（隐藏页 task 取消即停）
    private func dashboardTask() async {
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


// MARK: - v4.0.50 启动链类型折叠（防启动期 demangler 递归爆主线程 1MB 栈）
//
// 事故与 ChatView 同源（见 ChatView.swift 末段 v4.0.49 复盘）：本页 body 的 mangled 类型名
// 实测 2033 字符（dSYM 符号表量出）≈ 1.0MB 主线程栈，正好压在崩线附近。危险量是**名字的字符数**，
// 不是元组嵌套层数 —— body 里内联的每条修饰器（尤其 sheet 的 switch、alert 的按钮闭包）
// 都会把整棵闭包类型压进父类型名。
//
// 修法 = 把 body 里过长的修饰器链折成具名 ViewModifier 分组：父类型名里只剩组名，链在各组
// 自己的 applyXxx 调用里解析（各自一次 1MB 栈预算）。
// ⚠️ 视图树、修饰器**种类/数量/顺序/参数**一律逐字未变（等价重构）；谁也不许把这些链再内联回
//    body —— 改链请改这里的 applyXxx，别动调用点。
extension DashboardView {

    /// 折叠组 1（5 条修饰器）：滚动定位 / 下拉刷新 / 三张 sheet 通道
    @MainActor
    private func applyDashboardScrollChrome<C: View>(to content: C) -> some View {
        content
            .scrollPosition($scrollPos)
            // v2.0.86h：Dock 滑动隐藏已删除（从未生效，手动开关替代）
            .refreshable {
                await refresh()
            }
            .sheet(item: $activeSheet, onDismiss: dashboardSheetDismiss) { s in
                sheetContent(for: s)
            }
            // v3.9.40（#15）：卡片编辑器（排序 / 隐藏）
            .sheet(isPresented: $showCardEditor) {
                // SR13：`all` 必须传**可见**卡片。原来传 orderedCards（含隐藏项），
                // 而 init 把 all 整个塞进 `shown` → 隐藏卡片同时出现在「显示中」和「已隐藏」两栏；
                // 在「显示中」再点一次隐藏，hiddenList 就多一份重复，persist 写出的
                // orderRaw = shown + hiddenList 也带重复键 → orderedCards 返回重复元素 →
                // 看板同一张卡片渲染两遍，且 ForEach(id: \.element) 重复 id（SwiftUI 直接告警/错位）。
                BoardCardEditorSheet(all: visibleCards,
                                     hidden: orderedCards.filter { hiddenCards.contains($0) })
            }
            // v3.9.74 P1.5：连接器面板里点「MCP 工具服务」「生活卡片」→ 面板关闭后再弹对应设置页
            // （呈现由上面 onDismiss 消费 pendingSheetAfterPanel 驱动；sheet(item:) 随置 nil 关闭）
            .sheet(item: $presentedAfterPanel) { target in
                switch target {
                case .mcp:
                    MCPSettingsSheet()
                        .presentationDetents([.medium, .large])
                case .lifeCards:
                    LifeCardsSettingsView()
                        .presentationDetents([.medium, .large])
                // v4.0.x 第 3 项：接入中心一页新增两个直达口（邮件 / 网盘）。
                // 复用设置页里那同一份 sheet，**不新做一套 UI**（用户口径：
                // 同一个功能只能有一个界面，双模式/双入口各做一套=埋雷）。
                case .mail:
                    MailSettingsSheet()
                        .presentationDetents([.medium, .large])
                case .cloudDrive:
                    CloudDriveSettingsSheet()
                        .presentationDetents([.medium, .large])
                }
            }
    }

    /// 折叠组 2（5 条修饰器）：3 条 alert + 2 条 confirmationDialog（危险动作方言）
    @MainActor
    private func applyDashboardDialogChrome<C: View>(to content: C) -> some View {
        content
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
            // v3.9.46：安防卡点击布防/撤防的确认（同一套危险动作方言：confirmationDialog + 明示后果）
            .confirmationDialog("确认变更安防状态？",
                                isPresented: Binding(get: { confirmArmTarget != nil },
                                                     set: { if !$0 { confirmArmTarget = nil } }),
                                titleVisibility: .visible) {
                armDialogButtons
            } message: {
                Text(armDialogMessage)
            }
            // v3.9.46：布防/撤防的失败回执（原来这类写操作失败只会被 catch 吞掉）
            .alert("安防操作", isPresented: Binding(get: { !alarmError.isEmpty },
                                                    set: { if !$0 { alarmError = "" } })) {
                Button("知道了", role: .cancel) { alarmError = "" }
            } message: {
                Text(alarmError)
            }
    }

    /// 折叠组 3（5 条修饰器）：栏目卡片拖动反馈链（量高 → 位移 → 放大 → 阴影 → 层级）
    @MainActor
    private func applyDashboardCardChrome<C: View>(to content: C, card: BoardCard) -> some View {
        content
            // ⚠️ onGeometryChange 必须排在 .offset 之前 —— 它量的是栏目**自然高度**，
            //    拖动位移不该污染高度（否则落位会拿自己算自己）。
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                sectionHeights[card] = h
            }
            .offset(y: dragCard == card ? dragOffsetY : 0)
            .scaleEffect(dragCard == card ? 1.01 : 1)
            .shadow(color: .black.opacity(dragCard == card ? 0.16 : 0), radius: 14, y: 6)
            .zIndex(dragCard == card ? 1 : 0)
    }

    @MainActor
    private struct DashboardScrollChrome: ViewModifier {
        let host: DashboardView

        func body(content: Content) -> some View { host.applyDashboardScrollChrome(to: content) }
    }

    @MainActor
    private struct DashboardDialogChrome: ViewModifier {
        let host: DashboardView

        func body(content: Content) -> some View { host.applyDashboardDialogChrome(to: content) }
    }

    @MainActor
    private struct DashboardCardChrome: ViewModifier {
        let host: DashboardView
        let card: BoardCard

        func body(content: Content) -> some View { host.applyDashboardCardChrome(to: content, card: card) }
    }
}
