import SwiftUI

// MARK: - 生活页（v3.6.2：原看板「生活数据」栏目整体迁入独立 tab）
//
// 内容 = 股票行情 + 博客/资讯 + 快递真卡片（v3.9.32；未配置时退化为引导小字），
// v4.0.101 起三者**各自成板块**（LifeStocksSection / LifeRssSection / LifeExpressSection，
// 见 Features/Dashboard/LifeCardsSection.swift），同吃一份后端 /api/life/cards
//（配置页 LifeCardsSettingsView）。看板不再承载这部分。
//
// 数据加载照看板同款约定：
//   · 独立异步 + 8s UI 兜底 + 失败降级为卡片内小字（不空白、不转圈卡住）
//   · 轮询收在本页生命周期内（isActive 直传，切走 = task 取消即停，隐藏页零轮询）

struct LifeView: View {
    /// 是否当前选中（由 DockTabView 直传 selected == .life）
    var isActive: Bool = true

    @Environment(AuthStore.self) private var auth
    @Environment(\.horizontalSizeClass) private var hSize
    // v4.0.67 P3 收尾：页底环境渐变取色用（浅深各一套）
    @Environment(\.colorScheme) private var colorSchemeEnv

    @State private var life = LifeCardsData()
    @State private var lifeLoading = false
    /// v4.0.69（用户报「博客资讯的刷新胶囊点击无法强制刷新」）：排队中的「用户点刷新」标记。
    /// 与 `loadLife(queued:)` 配套 —— 在途时点击不再被静默丢弃，而是排队补发；这个标记防重复排队叠请求。
    @State private var freshQueued = false
    /// v4.0.114（用户「股票栏位的刷新和博客资讯栏位的刷新分开」）：**定向刷新**中的板块。
    /// 空 = 无定向（首次加载 / 下拉刷新 / 全刷）→ 三块都按整页 loading 转；
    /// 非空 = 只转这里面的板块，其余板块照常显示旧数据、不跟着转圈。
    @State private var refreshTargets: Set<String> = []
    /// v4.0.114（审查 P2）：排队期间**累计**的目标板块 —— 原写法 `if freshQueued { return }`
    /// 会把后一次点击的 parts 直接丢掉（点股票 → 再点资讯，资讯那发被吞、胶囊也不转圈），
    /// 正是 `queued` 通道要消灭的「点了没反应」。补发时用它覆盖本次 parts。
    @State private var queuedParts: Set<String> = []
    /// v4.0.114（复核 P1）：**持久**的「这次是哪几块被定向刷新」——
    /// `refreshTargets` 与 `lifeLoading` 同生命周期释放（请求结束即清），等不到下一帧渲染，
    /// 所以拿它做 `partError` 判据等于没改（定向下失败时下一帧 refreshTargets 已空、
    /// 资讯/快递照样报同一条错）。这个在**请求结束时落定**，成功或整页回退时清空。
    @State private var errorParts: Set<String> = []
    @State private var lifeError = ""
    @State private var showLifeSettings = false
    // v3.9.85：板块自定义（排序 + 隐藏）——抄看板 dashboard_card_order 模式
    @AppStorage("life_section_order") private var sectionOrderRaw = ""
    @AppStorage("life_section_hidden") private var sectionHiddenRaw = ""
    /// v4.0.101 一次性迁移标记（见 migrateLifeSplitOnce）
    @AppStorage("life_section_split_migrated") private var lifeSplitMigrated = false
    @State private var showSectionEditor = false
    // v4.0.84 拍 1：入场开关。🚨 必须由本视图持有 —— 本视图不会被 LazyVStack 回收，
    // 行内 modifier 自己的 @State 会随行回收被重置 → 每次滚回来重放一遍入场（见 Theme/StaggerAppear.swift 头注）
    @State private var introReady = false

    /// 已存顺序在前；串里没出现的（新增板块）按默认顺序补后面
    private var orderedSections: [LifeSection] {
        var seen = Set<LifeSection>()
        let saved = sectionOrderRaw.split(separator: ",")
            .compactMap { LifeSection(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
        // v4.0.101：股票/资讯/快递是**同一次拆出来的三张卡**。老用户存的顺序串里只有拆前的
        // rawValue（lifeCards），按 allCases 顺序把新 case 补到最末的话，资讯/快递会跑到
        // 「定时任务」后面 —— 用户会以为「资讯和快递没了」。所以补位时贴着它们的同族邻居
        // .lifeCards 放（rss → 其后一位，express → 再后一位），拆出来的三张始终相邻。
        // 没存过顺序串（新装）走的就是 allCases 顺序，本来就连着，无需插入。
        var merged = saved
        for s in LifeSection.allCases where !seen.contains(s) {
            guard let anchor = merged.firstIndex(of: .lifeCards) else {
                merged.append(s)   // 连股票都没排进来（异常串）→ 退回原来的「补到末尾」
                continue
            }
            switch s {
            case .rss: merged.insert(s, at: anchor + 1)
            case .express: merged.insert(s, at: min(anchor + 2, merged.count))
            default: merged.append(s)
            }
        }
        return merged
    }
    private var hiddenSections: Set<LifeSection> {
        Set(sectionHiddenRaw.split(separator: ",").compactMap { LifeSection(rawValue: String($0)) })
    }
    private var visibleSections: [LifeSection] {
        let h = hiddenSections
        return orderedSections.filter { !h.contains($0) }
    }

    // v4.0.101（审查发现）：拆卡前 `.lifeCards` 一个 case = **整块「生活数据」**（行情+资讯+快递）。
    // 老用户把它隐藏时 `life_section_hidden` 里只有 "lifeCards"；拆开后 .lifeCards 只代表股票，
    // 于是「三样都不想看」的老意图只剩股票生效，资讯/快递升级后重新冒出来。
    // 顺序串做了补位兜底（见 orderedSections），隐藏串这里补上同一件事。
    // ⚠️ 用**一次性标记**而不是「读到 lifeCards 就补」：否则用户日后单独取消隐藏资讯/快递、
    //    却仍留着股票隐藏时，每次冷启动又会被重新藏回去（这坑正是审查点出来的）。
    // 折叠态**不迁移**：新板块默认展开属其自身默认状态，用户收一次即可（不是数据丢失）。
    private func migrateLifeSplitOnce() {
        guard !lifeSplitMigrated else { return }
        lifeSplitMigrated = true
        let hidden = Set(sectionHiddenRaw.split(separator: ",").map(String.init))
        guard hidden.contains(LifeSection.lifeCards.rawValue) else { return }
        let merged = hidden.union([LifeSection.rss.rawValue, LifeSection.express.rawValue])
        // 按 allCases 顺序写回，保持串的可读性与既有的稳定排序口径
        sectionHiddenRaw = LifeSection.allCases.map(\.rawValue).filter { merged.contains($0) }
            .joined(separator: ",")
    }
    // v3.6.2：资讯展开态（同时只展开一条）+ 正文状态缓存
    @State private var expandedEntryID: String?
    @State private var articles: [String: LifeArticleState] = [:]
    // v3.7.0：资讯正文长按「大爆炸」全屏炸开载荷
    @State private var bigBangPayload: BigBangPayload?
    @Namespace private var zoomNS   // v3.9.0：资讯行 → 大爆炸 的 zoom 转场

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // v4.0.114：板块间距 10 → 16（= Spacing.section）。原先 10 比卡内留白（16–20）还窄，
                // 8 个板块糊成一条、没有分组感；16 与卡内留白同档，板块之间才读得出「一块一块」。
                LazyVStack(alignment: .leading, spacing: 16) {
                    // v3.9.85：按用户自定义顺序渲染，隐藏的板块不出现
                    // v4.0.84：本行要挂入场错峰与滚动层次 → switch 提成 sectionBody（见下）；
                    // 内联 switch 上加不了修饰符，也别整段塞回 body（本页属「启动链 demangler」事故家族）
                    ForEach(Array(visibleSections.enumerated()), id: \.element) { idx, section in
                        sectionRow(section, index: idx)   // 拍 1 + 拍 2（见下方 sectionRow）
                    }
                    // v3.9.85：底部「自定义板块」入口（与看板 cardEditorEntry 同款低调样式，用户 2026-09-26 拍板）
                    sectionEditorEntry
                        .staggerAppear(visibleSections.count, ready: introReady)
                        .scrollDepth()
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, 100)
                .frame(maxWidth: .infinity)
                .frame(maxWidth: AdaptiveLayout.contentMaxWidth(hSize))
            }
            // v4.0.69（审查）：下拉的语义本来就是「用户显式要最新」，走 queued 通道 ——
            // 原来 `await loadLife()` 是 queued=false，撞上 30s 轮询在途时直接 return，spin 一下什么也没发生。
            // v4.0.84 拍 1：一次性置真入场开关（本视图不被回收，所以只播一次；
            // 之后滚进视口才建出来的板块直接落终态，不重放、不延迟）
            .onAppear {
                introReady = true
                migrateLifeSplitOnce()   // v4.0.101：老用户隐藏串语义迁移（一次性，见该函数注释）
            }
            // v4.0.x：系统 .refreshable → 自绘液体杯子下拉刷新（用户定案）
            .pullRefreshCup { await loadLife(fresh: true, queued: true) }
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
        // ⚠️ v4.0.109：**长期目标**整块搬进工作区（用户「长期目标从生活页搬进工作区」），
        //    它的 `GoalsGlassLayerHost` 随 `GoalsSection` 一起迁到 `WorkspaceView` 页根挂载（本页已无该栏目）。
        //    本页只剩**待办 / 习惯 / 记录**三张。
        .overlay { AnyView(TodoGlassLayerHost()) }
        .overlay { AnyView(HabitGlassLayerHost()) }
        .overlay { AnyView(RecordGlassLayerHost()) }
        // v3.5.x：生活卡片设置页（股票 / 资讯 / 快递）
        .background(lifeCold1())
        .background(lifeCold2())
        // v4.0.67 P3 收尾：页底接主题环境渐变（三团弥散光晕，浅深各一套）——与聊天/会话/设置页同底
        .background(EnvironmentGlowLayers(scheme: colorSchemeEnv))
    }

    /// v4.0.84 拍 1 + 拍 2：板块行 = 入场错峰 + 滚动层次。
    ///
    /// ⚠️ 股票 / 博客·资讯 / 快递三个板块（v4.0.101 拆开，见 LifeSection.skipsOuterScrollDepth）
    /// 故意**跳过**外层 `.scrollDepth()`：它们内部逐卡已挂 scrollDepth
    ///（股票/资讯卡 LifeCardsSection、快递卡 LifeExpressPriceCards，与看板同款）。
    /// 同一滚动容器里叠两层 scrollTransition，缩放=0.965²≈0.931、不透明度=0.75²≈0.56 ——
    /// 比看板明显更缩更暗，恰好与「与看板对齐的滚动层次」的初衷相反（2026-10-09 发版前审查实测）。
    @ViewBuilder
    private func sectionRow(_ section: LifeSection, index: Int) -> some View {
        if section.skipsOuterScrollDepth {
            sectionBody(section)
                .staggerAppear(index, ready: introReady)
        } else {
            sectionBody(section)
                .staggerAppear(index, ready: introReady)
                .scrollDepth()
        }
    }

    /// 板块正文（v4.0.84：从 ForEach 内联 switch 提成独立方法 —— 每行要挂入场错峰与滚动层次，
    /// 内联 switch 上没法直接加修饰符）。
    /// ⚠️ 提出来顺手也治了本页的 body 深度：LifeView.body 是「VStack + ScrollView + LazyVStack +
    ///    7 个板块 switch + 5 层 .overlay」的重型 body，本页属「启动链 demangler」事故家族，
    ///    别再把这段塞回去。
    ///
    /// ⚠️ 这个 `@ViewBuilder` 必须**紧贴函数**：2026-10-09 CI 实踩 —— 中间夹进另一个声明时，
    ///    属性会挂到那个声明上，本函数丢掉 @ViewBuilder，7 个不同板块类型立刻报
    ///    「branches have mismatching types」（本机 `-parse` 全绿、只有 CI 能抓）。
    @ViewBuilder
    private func sectionBody(_ section: LifeSection) -> some View {
        switch section {
        case .memo: MemoSection()
        case .todo: TodoSection()
        case .habit: HabitSection()   // v4.0.46：习惯打卡
        // v4.0.109：`.goals`（长期目标）整块搬进工作区 —— 用户「长期目标从生活页搬进工作区」。
        // 该板块已不在生活页渲染，`LifeSection` 里对应 case 一并删除（含「自定义板块」列表项）。
        case .record: RecordSection()
        case .automations: AutomationsSection(isActive: isActive)
        case .lifeCards: LifeStocksSection(data: life,
                                           loading: partLoading("stock"),
                                           error: partError("stock"),
                                           onDeleteStock: { st in Task { await deleteStock(st) } },
                                           onAddStock: { showLifeSettings = true },
                                           // v4.0.69：queued: true = 在途也不丢点击（排队补发），
                                           // 见 LifeView.loadLife 注释（用户报「刷新胶囊点击无法强制刷新」）
                                           // v4.0.114：parts 定向 —— 只强刷股票，不再连资讯/快递一起重抓
                                           onRefresh: { Task { await loadLife(fresh: true, queued: true, parts: ["stock"]) } })
        // v4.0.101（用户 2026-10-12「把股票，博客/资讯，快递单独拆开」）：资讯独立成一板块
        case .rss: LifeRssSection(data: life,
                                  loading: partLoading("rss"),
                                  error: partError("rss"),
                                  zoomNS: zoomNS,   // v3.9.0：非闭包实参必须在闭包实参之前（实参序红线）
                                  expandedArticleID: expandedEntryID,
                                  articleStates: articles,
                                  // v4.0.114：parts 定向 —— 只强刷资讯源，不再连股票/快递一起重抓
                                  onRefresh: { Task { await loadLife(fresh: true, queued: true, parts: ["rss"]) } },
                                  onOpenArticle: { e in openArticle(e) },
                                  onBigBang: { text, sourceID in
                                      bigBangPayload = BigBangPayload(text: text, sourceID: sourceID)
                                  })
        // v4.0.101：快递独立成一板块（拆前跟着「股票」那颗折叠键一起收）
        case .express: LifeExpressSection(data: life,
                                          loading: partLoading("express"),
                                          error: partError("express"),
                                          // v4.0.114：parts 定向 —— 只强查快递单号
                                          onRefresh: { Task { await loadLife(fresh: true, queued: true, parts: ["express"]) } })
        }
    }

    /// 深度治理：行为型深层修饰器下沉背景层（.background 不影响布局，语义等价）
    private func lifeCold1() -> some View {
        Color.clear
        .sheet(isPresented: $showLifeSettings) {
            LifeCardsSettingsView()
                .anchorMenuHost()   // v4.0.105：sheet 内长按站点需要本层宿主（根层 zIndex 4 画不到 sheet 之上）
                .presentationDetents([.medium, .large])
        }
        // v3.9.85：板块自定义（排序 + 隐藏）
        .sheet(isPresented: $showSectionEditor) {
            LifeSectionEditorSheet(visible: visibleSections, hidden: Array(hiddenSections))
        }
        // v3.7.0：资讯正文长按「大爆炸」→ 全屏炸开选词
    }

    /// 深度治理：行为型深层修饰器下沉背景层（.background 不影响布局，语义等价）
    private func lifeCold2() -> some View {
        Color.clear
        .fullScreenCover(item: $bigBangPayload) { payload in
            // v3.9.0：zoom 转场——从被长按的资讯行"生长"出来
            if payload.sourceID.isEmpty {
                BigBangView(text: payload.text)
            } else {
                BigBangView(text: payload.text)
                    .navigationTransition(.zoom(sourceID: payload.sourceID, in: zoomNS))
            }
        }
        // v3.4.26 同款生命周期：选中即首刷 + 30s 轮询；离开 = task 取消即停
        .task(id: isActive) {
            guard isActive else { return }
            await loadLife()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }   // 切走（task 取消）后不再多发一次请求
                await loadLife()
            }
        }
    }

    /// v3.9.85：底部「自定义板块」入口（与看板 cardEditorEntry 同款低调样式）
    private var sectionEditorEntry: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
            Text(hiddenSections.isEmpty ? "自定义板块（排序 / 隐藏）"
                                    : "自定义板块 · 已隐藏 \(hiddenSections.count) 个板块")
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

    // MARK: - 数据（自 DashboardView 原样迁入）

    /// 生活数据（/api/life/cards）
    /// 独立异步路径：失败/超时只降级为卡片内小字，不阻塞页面其它内容；
    /// 8 秒 UI 兜底（后端已把上游收口在 ~7s 内）避免转圈卡住。
    /// - Parameter fresh: true = 带 ?fresh=1 强制绕过后端缓存（股票 60s / RSS 900s TTL）
    /// - Parameter queued: true = 「用户显式点刷新」通道。v4.0.69（用户报「博客资讯的刷新胶囊点击无法强制刷新」）：
    ///   闸门期间原来是 `guard ... else { return }` —— **静默丢弃**。30s 轮询 + 最长 8s 请求意味着点刷新
    ///   有相当概率撞上在途窗口，用户看到的就是「点了没反应」。现在在途时**不丢点击**：等在途结束后
    ///   自动补发这一次 fresh 请求（最多等 10s，`freshQueued` 防重复排队）。
    private func loadLife(fresh: Bool = false, queued: Bool = false, parts: [String] = []) async {
        // v4.0.69（审查）：本次调用是不是「排队后补发的那一发」—— 决定结束时要不要放开 freshQueued
        var queuedFresh = false
        if lifeLoading {
            guard queued else { return }
            // v4.0.114（审查 P2）：在途期间**累计**目标板块，别再直接 return。
            // 时序：30s 轮询在飞 → 点股票（parts=["stock"]）→ 再点资讯 → 原写法把第二发
            // 静默丢掉，资讯既不重抓、胶囊也不转圈，用户看到的就是「点了没反应」。
            queuedParts.formUnion(parts)
            if freshQueued { return }        // 已经欠着一发补发 → 合并，不叠加
            freshQueued = true
            var waited: Double = 0
            while lifeLoading && waited < 10 {
                try? await Task.sleep(for: .seconds(0.2))
                waited += 0.2
            }
            if lifeLoading { freshQueued = false; queuedParts = []; lifeError = "正在刷新，请稍后再试"; return }
            queuedFresh = true
        }
        // 复位必须落在**函数级**作用域：原先写在 if 块里，而 defer 在所属花括号退出时就执行了，
        // 等于只覆盖「等待在途结束」这一段 —— 补发的那次请求在途时再点刷新又会排一个（点几次发几次）。
        // 只在本次是补发者时复位，免得别人的排队被这次提前返回顺手清掉。
        defer { if queuedFresh { freshQueued = false } }
        lifeLoading = true
        // v4.0.114：定向刷新 —— 只让目标板块转圈（其余板块保持旧数据，不跟着转）
        // v4.0.114（复核 P2）：**只有补发者才消费队列** —— 原写法 `queuedParts.isEmpty ? Set(parts) : queuedParts`
        // 在任何走到函数体的调用上都执行，30s 轮询若落在补发者 `Task.sleep(0.2)` 的窗口里，
        // 会把这批目标「吃掉」并当成自己的定向集，补发者醒来发现队列已空 → 用户点的第二块
        // 既没强刷、胶囊也不转圈（正是本补丁要消灭的「点了没反应」）。`queuedFresh` 是现成判据。
        let effectiveParts: Set<String> = queuedFresh ? queuedParts : Set(parts)
        queuedParts = []
        if !effectiveParts.isEmpty { refreshTargets = effectiveParts }
        let guardTask = Task {
            try? await Task.sleep(for: .seconds(8))
            // v3.9.41（SR39）：兜底只做「显示超时」，**不能**顺手把 lifeLoading 置回 false——
            // 那等于在请求还在飞的时候自己解掉了在途闸门：下一轮 30s 轮询立刻与之并发，
            // 两份响应先后覆盖 life / lifeError（晚回来的旧那份反而赢）。闸门只由下面的 defer 释放。
            if !Task.isCancelled {
                lifeError = "获取超时"
            }
        }
        defer {
            guardTask.cancel()
            lifeLoading = false
            refreshTargets = []      // v4.0.114：与 lifeLoading 同生命周期释放
        }
        // v4.0.114：fresh 换成「板块名」口径，与后端 `_collect(parts=…)` 对齐 ——
        //   fresh=1 → 全刷（下拉刷新 / 整页）；fresh=stock,rss → 只强刷这些板块，其余走后端缓存。
        // 用 effectiveParts（排队补发时含累计目标），保证补发这一发真正打到用户点过的每个板块。
        let effectiveList = effectiveParts.sorted()
        let url = !fresh ? "/api/life/cards"
            : (effectiveList.isEmpty ? "/api/life/cards?fresh=1"
                                     : "/api/life/cards?fresh=" + effectiveList.joined(separator: ","))
        if let j = await auth.jsonOrLog(url) {
            life = LifeCardsData.parse(j)
            lifeError = life.error
        } else {
            lifeError = "获取失败（后端未接线或网络不可用）"
        }
        // v4.0.114（复核 P1）：请求结束时**落定**「这次是谁被定向」——
        // 成功（无错）或整页口径（effectiveParts 为空）都清空，让三块回到共享一条错。
        errorParts = (lifeError.isEmpty || effectiveParts.isEmpty) ? [] : effectiveParts
    }

    /// v4.0.114：板块级 loading —— 定向刷新时只有目标板块转圈；
    /// 整页口径（首次加载 / 下拉 / 全刷）三块一起转。
    private func partLoading(_ part: String) -> Bool {
        refreshTargets.isEmpty ? lifeLoading : refreshTargets.contains(part)
    }

    /// v4.0.114（审查 P2 / 复核 P1）：板块级错误 —— 与 `partLoading` 同款分派。
    /// loading 已按板块解耦而 error 没有：三张卡原来都吃同一条 `lifeError`，
    /// 于是「只刷股票失败」会让资讯/快递的空卡也报同一条错（注释里那句「三张卡对同一次断网
    /// 要一个说法」在拆块 + 定向刷新后已不成立）。非目标板块喂空串。
    /// ⚠️ 判据必须是**持久**的 `errorParts`，不能拿 `refreshTargets` ——
    /// 后者与 `lifeLoading` 同生命周期释放，请求一结束就空了，等不到下一帧渲染。
    private func partError(_ part: String) -> String {
        if errorParts.isEmpty { return lifeError }          // 整页口径：三块共享一条
        return errorParts.contains(part) ? lifeError : ""    // 定向：只有目标板块吃这条错
    }

    // MARK: - v3.6.2 资讯：点击展开正文（后端 AI 抓取整理）

    /// 点击某条资讯：展开（首次触发拉取）/ 收起；失败态再点一次 = 重试
    private func openArticle(_ e: LifeRssEntry) {
        if expandedEntryID == e.id {
            if case .some(.failed) = articles[e.id] {
                articles[e.id] = .loading
                Task { await loadArticle(e) }
            } else {
                expandedEntryID = nil
            }
            return
        }
        expandedEntryID = e.id
        if case .some(.loading) = articles[e.id] { return }
        if case .some(.loaded) = articles[e.id] { return }
        articles[e.id] = .loading
        Task { await loadArticle(e) }
    }

    /// 拉正文：POST /api/life/article（后端抓 HTML + 模型整理，按 URL 缓存 6h）
    private func loadArticle(_ e: LifeRssEntry) async {
        guard !e.link.isEmpty else {
            articles[e.id] = .failed("这条资讯没有链接")
            return
        }
        // 超时放宽到 45s：后端要抓网页 + 模型整理（实测冷缓存 ~7s，蜂窝直连默认 10s 会误报失败）
        let j = await auth.jsonOrLog("/api/life/article", method: "POST",
                                     body: ["url": e.link, "title": e.title], timeout: 45)
        guard let j, (j["ok"] as? Bool) == true else {
            let msg = (j?["error"] as? String) ?? "拉取失败（网络或后端不可用）"
            articles[e.id] = .failed(msg)
            return
        }
        articles[e.id] = .loaded(LifeArticle.parse(j))
    }

    /// 长按「删除这张卡片」——配置里去掉该股票后立即重拉 /api/life/cards
    private func deleteStock(_ s: LifeStock) async {
        guard let cfgJ = await auth.jsonOrLog("/api/life/config"),
              let cfgDict = cfgJ["config"] as? [String: Any] else {
            lifeError = "读取生活卡片配置失败"
            return
        }
        var cfg = LifeConfig.parse(cfgDict)
        let market = s.id.split(separator: ".").first.map { String($0) } ?? ""
        cfg.stocks.removeAll { $0.code == s.code && (market.isEmpty || $0.market == market) }
        guard let j = await auth.jsonOrLog("/api/life/config", method: "POST", body: ["config": cfg.json]) else {
            lifeError = "删除失败：网络或后端不可用"
            return
        }
        if (j["ok"] as? Bool) == false {
            lifeError = (j["error"] as? String) ?? "删除失败"
            return
        }
        lifeError = ""
        await loadLife()
    }
}
