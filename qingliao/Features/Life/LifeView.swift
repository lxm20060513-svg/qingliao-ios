import SwiftUI

// MARK: - 生活页（v3.6.2：原看板「生活数据」栏目整体迁入独立 tab）
//
// 内容 = 我的东西（备忘 / 待办 / 习惯 / 长期目标 / 记录）+ 行情资讯快递
// （LifeCardsSection，后端 /api/life/cards，配置页 LifeCardsSettingsView）。
//
// v4.0.80（P2 条目 8「生活页移出」）：**工作模式下本页只留「我的东西」** ——
//   「定时任务」与「生活数据」这两个板块被移出，落点在看板（条目 9「看板收进」：挂载点见
//   DashboardView 里按 `WorkbenchLayout.dashboardHostedLifeSectionRaws` 渲染的那一块）。
//   · 目录口径全在 `Core/WorkbenchScope.swift`，本页**不写任何模式判断**；
//   · 生活模式读到的目录 = 全量，逐字等于历史行为（真值表正反两面钉着）；
//   · 两个板块的**渲染分支一行没删**（下面 switch 里还在）——工作模式只是目录里没有它们，
//     所以切回生活模式不需要任何「恢复」动作；
//   · 数据加载（/api/life/cards 拉取与排队刷新、资讯正文、删股票、30s 轮询）随视图一起下沉到
//     `LifeCardsBlock`（生活页与工作模式看板共用同一份实现，理由见该文件头），
//     本页只保留板块顺序 / 编辑器入口 / 页级毛玻璃宿主。

struct LifeView: View {
    /// 是否当前选中（由 DockTabView 直传 selected == .life）
    var isActive: Bool = true

    @Environment(AuthStore.self) private var auth
    @Environment(\.horizontalSizeClass) private var hSize
    // v4.0.67 P3 收尾：页底环境渐变取色用（浅深各一套）
    @Environment(\.colorScheme) private var colorSchemeEnv

    /// 生活数据（行情/资讯/快递）的加载与展开态 —— 组件化宿主，本页与工作模式看板共用一份实现
    @State private var lifeCards = LifeCardsStore()
    // v3.9.85：板块自定义（排序 + 隐藏）——抄看板 dashboard_card_order 模式
    @AppStorage("life_section_order") private var sectionOrderRaw = ""
    @AppStorage("life_section_hidden") private var sectionHiddenRaw = ""
    @State private var showSectionEditor = false

    /// 本口径下的板块目录（工作模式不含移出的两个，见文件头）。全量真源永远是 LifeSection.allCases。
    private var catalogRaws: [String] {
        WorkbenchLayout.lifeSectionCatalogRaws(WorkbenchScope.launched,
                                               allRaws: LifeSection.allCases.map { $0.rawValue })
    }

    /// 已存顺序在前；串里没出现的（新增板块）按本口径目录补后面
    private var orderedSections: [LifeSection] {
        WorkbenchLayout.resolveLifeSectionOrder(order: sectionOrderRaw, catalog: catalogRaws)
            .compactMap { LifeSection(rawValue: $0) }
    }
    private var hiddenSections: Set<LifeSection> {
        Set(sectionHiddenRaw.split(separator: ",").compactMap { LifeSection(rawValue: String($0)) })
    }
    private var visibleSections: [LifeSection] {
        let h = hiddenSections
        return orderedSections.filter { !h.contains($0) }
    }
    /// 编辑器里的「已隐藏」列表：只列**本口径目录内**的板块（目录外的在本模式里根本不存在，
    /// 列出来等于暗示用户能在本模式把移出的板块调回来；它们的配置由 persist 的目录外保留逻辑兜住）
    private var hiddenEditableSections: [LifeSection] {
        let h = hiddenSections
        return orderedSections.filter { h.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // v3.9.85：按用户自定义顺序渲染，隐藏的板块不出现
                    ForEach(visibleSections) { section in
                        switch section {
                        case .memo: MemoSection()
                        case .todo: TodoSection()
                        case .habit: HabitSection()   // v4.0.46：习惯打卡
                        case .goals: GoalsSection()   // v4.0.7：长期目标
                        case .record: RecordSection()
                        case .automations: AutomationsSection(isActive: isActive)
                        // v4.0.80：数据/展开/大爆炸/设置页接线全部收在 LifeCardsBlock 内
                        // （工作模式下这个分支不会出现 —— 该板块已移出到看板，见文件头）
                        case .lifeCards: LifeCardsBlock(store: lifeCards, isActive: isActive)
                        }
                    }
                    // v3.9.85：底部「自定义板块」入口（与看板 cardEditorEntry 同款低调样式，用户 2026-09-26 拍板）
                    sectionEditorEntry
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, 100)
                .frame(maxWidth: .infinity)
                .frame(maxWidth: AdaptiveLayout.contentMaxWidth(hSize))
            }
            // v4.0.69（审查）：下拉的语义本来就是「用户显式要最新」，走 queued 通道 ——
            // 原来 `await loadLife()` 是 queued=false，撞上 30s 轮询在途时直接 return，spin 一下什么也没发生。
            // v4.0.80：数据加载随视图下沉到 LifeCardsBlock（store 由本页持有，所以这里还能 await 到真正结束）；
            // 该板块不在本口径目录里时（工作模式）不白跑一次请求。
            .refreshable {
                guard visibleSections.contains(.lifeCards) else { return }
                await lifeCards.load(auth: auth, fresh: true, queued: true)
            }
            // v4.0.61（试点页）：页头从 VStack 第一行改成挂在滚动视图上的系统 **safeAreaBar**（iOS 26 新 API：
            // 「把自定义栏交给系统按栏处理」）—— 滚动时内容在页头下沿走系统级模糊/渐隐，
            // 而不是「自绘头 + 内容在下面硬切」。系统会替它处理安全区与边缘效果。
            // ⚠️ 本页是**唯一试点**：会话/看板等页暂不动，真机看过观感合适再推广；
            //    不合适就整段回退 —— 删掉这个 .safeAreaBar 块、在 VStack 第一行恢复 PageHeader(...) 即可。
            .safeAreaBar(edge: .top) {
                PageHeader(title: "生活", subtitle: "行情 · 资讯 · 快递 · 价格")
            }
        }
        // 🚨 v4.0.77：备忘录三个毛玻璃浮层挂**整页最外层**（用户实报「点卡片只在现有卡片大小内弹，
        // 我要那种全屏弹出那种」）——浮层不能再挂在 MemoSection 那一行里（滚动区内，几何被行限制）。
        // 这里在滚动区之外、页头之上 → 轻纱盖住整页、面板从屏底长出。开关状态见 MemoGlassPresenter。
        // 用 AnyView 收类型名（本页与 MemoSection 同属「启动链 demangler」事故家族，别把宿主类型名内联进 body）
        .overlay { AnyView(MemoGlassLayerHost()) }
        // 🚨 v4.0.78：把**待办 / 习惯 / 长期目标 / 记录**四张卡片的弹窗（全部列表 · 详情 · 新建）也收编到
        // 页级毛玻璃浮层（用户 2026-10-08：「把待办清单，记录，长期目标也都改为跟备忘录一样的全屏弹出」
        // +「还有习惯卡片也改成一样的全屏弹出」）——口径与备忘录 4.0.77 完全一致：开关在各自的页级单例
        // （XxxGlassPresenter.shared），内容在各自 section 文件里提升出的文件级 struct，宿主只在这里挂一层。
        // ⚠️ 宿主必须挂在**整页最外层**（滚动区之外）。挂回 section 那一行里 = 几何被行限制，
        // 又变回「只在卡片大小内弹」（4.0.76 备忘录的原坑，勿回退）。
        // AnyView 收类型名：本页属「启动链 demangler」事故家族，别把宿主类型名内联进 body（见 ql_typestack 护栏）。
        .overlay { AnyView(TodoGlassLayerHost()) }
        .overlay { AnyView(HabitGlassLayerHost()) }
        .overlay { AnyView(GoalsGlassLayerHost()) }
        .overlay { AnyView(RecordGlassLayerHost()) }
        .background(lifeCold())
        // v4.0.67 P3 收尾：页底接主题环境渐变（三团弥散光晕，浅深各一套）——与聊天/会话/设置页同底
        .background(EnvironmentGlowLayers(scheme: colorSchemeEnv))
    }

    /// 深度治理：行为型深层修饰器下沉背景层（.background 不影响布局，语义等价）
    /// v4.0.80：生活卡片设置页 / 大爆炸全屏 / 数据轮询均已随视图下沉到 LifeCardsBlock，这里只剩板块编辑器。
    private func lifeCold() -> some View {
        Color.clear
        // v3.9.85：板块自定义（排序 + 隐藏）——工作模式下目录被收窄（条目 8）：编辑器只列本口径
        // 目录内的板块；目录外（移出的那两个）的老配置由 WorkbenchLayout.mergeLifeSectionPersist 保住
        .sheet(isPresented: $showSectionEditor) {
            LifeSectionEditorSheet(visible: visibleSections,
                                   hidden: hiddenEditableSections,
                                   catalog: catalogRaws)
        }
    }

    /// v3.9.85：底部「自定义板块」入口（与看板 cardEditorEntry 同款低调样式）
    private var sectionEditorEntry: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
            // v4.0.80：计数只算本口径目录内的隐藏项（工作模式里那两个移出板块不进目录，
            // 否则会出现「已隐藏 2 个板块」但列表里找不到的怪状态）
            Text(hiddenEditableSections.isEmpty
                 ? "自定义板块（排序 / 隐藏）"
                 : "自定义板块 · 已隐藏 " + String(hiddenEditableSections.count) + " 个板块")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .pastelCard()
        .contentShape(Rectangle())
        .tapButton { showSectionEditor = true }
    }
}
