import SwiftUI

// MARK: - 生活页（v3.6.2：原看板「生活数据」栏目整体迁入独立 tab）
//
// 内容 = 股票行情 + 博客/资讯 + 快递/价格监控占位，全部来自 LifeCardsSection
// （后端 /api/life/cards，配置页 LifeCardsSettingsView）。看板不再承载这部分。
//
// 数据加载照看板同款约定：
//   · 独立异步 + 8s UI 兜底 + 失败降级为卡片内小字（不空白、不转圈卡住）
//   · 轮询收在本页生命周期内（isActive 直传，切走 = task 取消即停，隐藏页零轮询）

struct LifeView: View {
    /// 是否当前选中（由 DockTabView 直传 selected == .life）
    var isActive: Bool = true

    @Environment(AuthStore.self) private var auth
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var life = LifeCardsData()
    @State private var lifeLoading = false
    @State private var lifeError = ""
    @State private var showLifeSettings = false
    // v3.6.2：资讯展开态（同时只展开一条）+ 正文状态缓存 + 资讯专用刷新转圈
    @State private var expandedEntryID: String?
    @State private var articles: [String: LifeArticleState] = [:]
    @State private var feedsRefreshing = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "生活", subtitle: "行情 · 资讯 · 快递 · 价格")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    LifeCardsSection(data: life,
                                     loading: lifeLoading,
                                     error: lifeError,
                                     onDeleteStock: { st in Task { await deleteStock(st) } },
                                     onAddStock: { showLifeSettings = true },
                                     onRefresh: { Task { await loadLife(fresh: true) } },
                                     feedsRefreshing: feedsRefreshing,
                                     onRefreshFeeds: { Task { await refreshFeeds() } },
                                     articleStates: articles,
                                     onOpenArticle: { e in openArticle(e) },
                                     expandedArticleID: expandedEntryID)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 100)
                .frame(maxWidth: .infinity)
                .frame(maxWidth: AdaptiveLayout.contentMaxWidth(hSize))
            }
            .refreshable { await loadLife() }
        }
        // v3.5.x：生活卡片设置页（股票 / 资讯 / 快递 / 价格监控）
        .sheet(isPresented: $showLifeSettings) {
            LifeCardsSettingsView()
                .presentationDetents([.medium, .large])
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

    // MARK: - 数据（自 DashboardView 原样迁入）

    /// 生活数据（/api/life/cards）
    /// 独立异步路径：失败/超时只降级为卡片内小字，不阻塞页面其它内容；
    /// 8 秒 UI 兜底（后端已把上游收口在 ~7s 内）避免转圈卡住。
    /// - Parameter fresh: true = 带 ?fresh=1 强制绕过后端缓存（股票 60s / RSS 900s TTL）
    private func loadLife(fresh: Bool = false) async {
        guard !lifeLoading else { return }
        lifeLoading = true
        let guardTask = Task {
            try? await Task.sleep(for: .seconds(8))
            if lifeLoading {
                lifeLoading = false
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

    // MARK: - v3.6.2 资讯：专用刷新 + 点击展开正文（后端 AI 抓取整理）

    /// 只刷资讯：强制绕缓存（?fresh=1），局部转圈；只更新资讯相关字段，股票/占位卡不闪动
    private func refreshFeeds() async {
        guard !feedsRefreshing else { return }
        feedsRefreshing = true
        defer { feedsRefreshing = false }
        guard let j = await auth.jsonOrLog("/api/life/cards?fresh=1") else {
            lifeError = "资讯刷新失败（网络或后端不可用）"
            return
        }
        let d = LifeCardsData.parse(j)
        life.entries = d.entries
        life.rssSources = d.rssSources
        life.updated = d.updated
        life.loaded = true
        lifeError = d.error
    }

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
