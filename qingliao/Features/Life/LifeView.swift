import SwiftUI

// MARK: - 生活页（v3.6.2：原看板「生活数据」栏目整体迁入独立 tab）
//
// 内容 = 股票行情 + 博客/资讯 + 快递真卡片（v3.9.32；未配置时退化为引导小字），
// 全部来自 LifeCardsSection（后端 /api/life/cards，配置页 LifeCardsSettingsView）。看板不再承载这部分。
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
    @State private var lifeError = ""
    @State private var showLifeSettings = false
    // v3.9.85：板块自定义（排序 + 隐藏）——抄看板 dashboard_card_order 模式
    @AppStorage("life_section_order") private var sectionOrderRaw = ""
    @AppStorage("life_section_hidden") private var sectionHiddenRaw = ""
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
        return saved + LifeSection.allCases.filter { !seen.contains($0) }
    }
    private var hiddenSections: Set<LifeSection> {
        Set(sectionHiddenRaw.split(separator: ",").compactMap { LifeSection(rawValue: String($0)) })
    }
    private var visibleSections: [LifeSection] {
        let h = hiddenSections
        return orderedSections.filter { !h.contains($0) }
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
                LazyVStack(alignment: .leading, spacing: 10) {
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
            .onAppear { introReady = true }
            .refreshable { await loadLife(fresh: true, queued: true) }
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
        // v3.5.x：生活卡片设置页（股票 / 资讯 / 快递）
        .background(lifeCold1())
        .background(lifeCold2())
        // v4.0.67 P3 收尾：页底接主题环境渐变（三团弥散光晕，浅深各一套）——与聊天/会话/设置页同底
        .background(EnvironmentGlowLayers(scheme: colorSchemeEnv))
    }

    /// 板块正文（v4.0.84：从 ForEach 内联 switch 提成独立方法 —— 每行要挂入场错峰与滚动层次，
    /// 内联 switch 上没法直接加修饰符）。
    /// ⚠️ 提出来顺手也治了本页的 body 深度：LifeView.body 是「VStack + ScrollView + LazyVStack +
    ///    7 个板块 switch + 5 层 .overlay」的重型 body，本页属「启动链 demangler」事故家族，
    ///    别再把这段塞回去。
    @ViewBuilder
    /// v4.0.84 拍 1 + 拍 2：板块行 = 入场错峰 + 滚动层次。
    ///
    /// ⚠️ `.lifeCards` 故意**跳过**外层 `.scrollDepth()`：该板块内部逐卡已挂 scrollDepth
    ///（股票/资讯卡 LifeCardsSection、快递卡 LifeExpressPriceCards，与看板同款）。
    /// 同一滚动容器里叠两层 scrollTransition，缩放=0.965²≈0.931、不透明度=0.75²≈0.56 ——
    /// 比看板明显更缩更暗，恰好与「与看板对齐的滚动层次」的初衷相反（2026-10-09 发版前审查实测）。
    @ViewBuilder
    private func sectionRow(_ section: LifeSection, index: Int) -> some View {
        if section == .lifeCards {
            sectionBody(section)
                .staggerAppear(index, ready: introReady)
        } else {
            sectionBody(section)
                .staggerAppear(index, ready: introReady)
                .scrollDepth()
        }
    }

    private func sectionBody(_ section: LifeSection) -> some View {
        switch section {
        case .memo: MemoSection()
        case .todo: TodoSection()
        case .habit: HabitSection()   // v4.0.46：习惯打卡
        case .goals: GoalsSection()   // v4.0.7：长期目标
        case .record: RecordSection()
        case .automations: AutomationsSection(isActive: isActive)
        case .lifeCards: LifeCardsSection(data: life,
                                          loading: lifeLoading,
                                          error: lifeError,
                                          zoomNS: zoomNS,   // v3.9.0：非闭包实参必须在闭包实参之前（实参序红线）
                                          onDeleteStock: { st in Task { await deleteStock(st) } },
                                          onAddStock: { showLifeSettings = true },
                                          // v4.0.69：queued: true = 在途也不丢点击（排队补发），
                                          // 见 LifeView.loadLife 注释（用户报「刷新胶囊点击无法强制刷新」）
                                          onRefresh: { Task { await loadLife(fresh: true, queued: true) } },
                                          articleStates: articles,
                                          onOpenArticle: { e in openArticle(e) },
                                          expandedArticleID: expandedEntryID,
                                          onBigBang: { text, sourceID in
                                              bigBangPayload = BigBangPayload(text: text, sourceID: sourceID)
                                          })
        }
    }

    /// 深度治理：行为型深层修饰器下沉背景层（.background 不影响布局，语义等价）
    private func lifeCold1() -> some View {
        Color.clear
        .sheet(isPresented: $showLifeSettings) {
            LifeCardsSettingsView()
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
    private func loadLife(fresh: Bool = false, queued: Bool = false) async {
        // v4.0.69（审查）：本次调用是不是「排队后补发的那一发」—— 决定结束时要不要放开 freshQueued
        var queuedFresh = false
        if lifeLoading {
            guard queued else { return }
            if freshQueued { return }        // 已经欠着一发补发 → 合并，不叠加
            freshQueued = true
            var waited: Double = 0
            while lifeLoading && waited < 10 {
                try? await Task.sleep(for: .seconds(0.2))
                waited += 0.2
            }
            if lifeLoading { freshQueued = false; lifeError = "正在刷新，请稍后再试"; return }
            queuedFresh = true
        }
        // 复位必须落在**函数级**作用域：原先写在 if 块里，而 defer 在所属花括号退出时就执行了，
        // 等于只覆盖「等待在途结束」这一段 —— 补发的那次请求在途时再点刷新又会排一个（点几次发几次）。
        // 只在本次是补发者时复位，免得别人的排队被这次提前返回顺手清掉。
        defer { if queuedFresh { freshQueued = false } }
        lifeLoading = true
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
        }
        if let j = await auth.jsonOrLog(fresh ? "/api/life/cards?fresh=1" : "/api/life/cards") {
            life = LifeCardsData.parse(j)
            lifeError = life.error
        } else {
            lifeError = "获取失败（后端未接线或网络不可用）"
        }
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
