import SwiftUI

// MARK: - 「生活数据」板块的可复用宿主 + 数据源（P2 条目 8/9 的共用体）
//
// 为什么要有这个文件：P2 把「生活数据」从生活页**移出**到看板（工作模式）。如果两边各写一份
//   「拉 /api/life/cards + 展开资讯 + 大爆炸 + 删股票 + 30s 轮询」，就等于同一个功能两套实现 ——
//   以后修 bug 要修两处、真机验收也要验两处（本仓「一个功能一个界面」的口径）。
//   所以把**数据层（LifeCardsStore）+ 宿主接线（LifeCardsBlock）**收成一份：
//     · 生活模式：生活页的 `.lifeCards` 分支渲染 `LifeCardsBlock`（原样，行为不变）；
//     · 工作模式：生活页目录里没有该板块（条目 8），看板按
//       `WorkbenchLayout.dashboardHostedLifeSectionRaws` **就地挂载同一个 `LifeCardsBlock`**（条目 9）。
//   视觉（卡片/几何/圆角/底/折叠）仍然全部在 `Dashboard/LifeCardsSection.swift` 里，本文件不碰。
//
// 数据加载照看板同款约定（自 LifeView 原样迁入，逻辑未改一字）：
//   · 独立异步 + 8s UI 兜底 + 失败降级为卡片内小字（不空白、不转圈卡住）
//   · 轮询收在 `LifeCardsBlock` 的生命周期内（isActive 直传，切走 = task 取消即停，隐藏页零轮询）

@MainActor
@Observable
final class LifeCardsStore {
    /// /api/life/cards 的解析结果
    var data = LifeCardsData()
    var loading = false
    /// 传输层错误（网络/未接线）/ 后端整体错误（parse 里带出来）
    var error = ""
    /// v4.0.69：排队中的「用户点刷新」标记。与 `load(queued:)` 配套 ——
    /// 在途时点击不再被静默丢弃，而是排队补发；这个标记防重复排队叠请求。
    private var freshQueued = false
    // v3.6.2：资讯展开态（同时只展开一条）+ 正文状态缓存
    var expandedEntryID: String?
    var articles: [String: LifeArticleState] = [:]

    /// 生活数据（/api/life/cards）
    /// 独立异步路径：失败/超时只降级为卡片内小字，不阻塞页面其它内容；
    /// 8 秒 UI 兜底（后端已把上游收口在 ~7s 内）避免转圈卡住。
    /// - Parameter fresh: true = 带 ?fresh=1 强制绕过后端缓存（股票 60s / RSS 900s TTL）
    /// - Parameter queued: true = 「用户显式点刷新」通道。v4.0.69（用户报「博客资讯的刷新胶囊点击无法强制刷新」）：
    ///   闸门期间原来是 `guard ... else { return }` —— **静默丢弃**。30s 轮询 + 最长 8s 请求意味着点刷新
    ///   有相当概率撞上在途窗口，用户看到的就是「点了没反应」。现在在途时**不丢点击**：等在途结束后
    ///   自动补发这一次 fresh 请求（最多等 10s，`freshQueued` 防重复排队）。
    func load(auth: AuthStore, fresh: Bool = false, queued: Bool = false) async {
        // v4.0.69（审查）：本次调用是不是「排队后补发的那一发」—— 决定结束时要不要放开 freshQueued
        var queuedFresh = false
        if loading {
            guard queued else { return }
            if freshQueued { return }        // 已经欠着一发补发 → 合并，不叠加
            freshQueued = true
            var waited: Double = 0
            while loading && waited < 10 {
                try? await Task.sleep(for: .seconds(0.2))
                waited += 0.2
            }
            if loading { freshQueued = false; error = "正在刷新，请稍后再试"; return }
            queuedFresh = true
        }
        // 复位必须落在**函数级**作用域：原先写在 if 块里，而 defer 在所属花括号退出时就执行了，
        // 等于只覆盖「等待在途结束」这一段 —— 补发的那次请求在途时再点刷新又会排一个（点几次发几次）。
        // 只在本次是补发者时复位，免得别人的排队被这次提前返回顺手清掉。
        defer { if queuedFresh { freshQueued = false } }
        loading = true
        let guardTask = Task {
            try? await Task.sleep(for: .seconds(8))
            // v3.9.41（SR39）：兜底只做「显示超时」，**不能**顺手把 loading 置回 false——
            // 那等于在请求还在飞的时候自己解掉了在途闸门：下一轮 30s 轮询立刻与之并发，
            // 两份响应先后覆盖 data / error（晚回来的旧那份反而赢）。闸门只由下面的 defer 释放。
            if !Task.isCancelled {
                error = "获取超时"
            }
        }
        defer {
            guardTask.cancel()
            loading = false
        }
        if let j = await auth.jsonOrLog(fresh ? "/api/life/cards?fresh=1" : "/api/life/cards") {
            data = LifeCardsData.parse(j)
            error = data.error
        } else {
            error = "获取失败（后端未接线或网络不可用）"
        }
    }

    // MARK: - v3.6.2 资讯：点击展开正文（后端 AI 抓取整理）

    /// 点击某条资讯：展开（首次触发拉取）/ 收起；失败态再点一次 = 重试
    func openArticle(_ e: LifeRssEntry, auth: AuthStore) {
        if expandedEntryID == e.id {
            if case .some(.failed) = articles[e.id] {
                articles[e.id] = .loading
                Task { await loadArticle(e, auth: auth) }
            } else {
                expandedEntryID = nil
            }
            return
        }
        expandedEntryID = e.id
        if case .some(.loading) = articles[e.id] { return }
        if case .some(.loaded) = articles[e.id] { return }
        articles[e.id] = .loading
        Task { await loadArticle(e, auth: auth) }
    }

    /// 拉正文：POST /api/life/article（后端抓 HTML + 模型整理，按 URL 缓存 6h）
    func loadArticle(_ e: LifeRssEntry, auth: AuthStore) async {
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
    func deleteStock(_ s: LifeStock, auth: AuthStore) async {
        guard let cfgJ = await auth.jsonOrLog("/api/life/config"),
              let cfgDict = cfgJ["config"] as? [String: Any] else {
            error = "读取生活卡片配置失败"
            return
        }
        var cfg = LifeConfig.parse(cfgDict)
        let market = s.id.split(separator: ".").first.map { String($0) } ?? ""
        cfg.stocks.removeAll { $0.code == s.code && (market.isEmpty || $0.market == market) }
        guard let j = await auth.jsonOrLog("/api/life/config", method: "POST", body: ["config": cfg.json]) else {
            error = "删除失败：网络或后端不可用"
            return
        }
        if (j["ok"] as? Bool) == false {
            error = (j["error"] as? String) ?? "删除失败"
            return
        }
        error = ""
        await load(auth: auth)
    }
}

/// 「生活数据」板块的宿主视图：数据/展开/大爆炸/设置页接线都在这里，视觉交给 `LifeCardsSection`。
/// 生活页与工作模式看板**共用这一个**（PV 口径：一个功能一个界面）。
struct LifeCardsBlock: View {
    /// 数据源（由宿主持有：生活页一个实例、工作模式看板一个实例 —— 两个 tab 不会同时在渲染）
    let store: LifeCardsStore
    /// 是否当前选中（决定首刷 + 30s 轮询启停，口径同 LifeView/看板原实现）
    var isActive: Bool = true

    @Environment(AuthStore.self) private var auth
    // v3.5.x：生活卡片设置页（股票 / 资讯 / 快递）
    @State private var showSettings = false
    // v3.7.0：资讯正文长按「大爆炸」全屏炸开载荷
    @State private var bigBangPayload: BigBangPayload?
    @Namespace private var zoomNS   // v3.9.0：资讯行 → 大爆炸 的 zoom 转场

    var body: some View {
        LifeCardsSection(data: store.data,
                         loading: store.loading,
                         error: store.error,
                         zoomNS: zoomNS,   // v3.9.0：非闭包实参必须在闭包实参之前（实参序红线）
                         onDeleteStock: { st in Task { await store.deleteStock(st, auth: auth) } },
                         onAddStock: { showSettings = true },
                         // v4.0.69：queued: true = 在途也不丢点击（排队补发），见 LifeCardsStore.load 注释
                         onRefresh: { Task { await store.load(auth: auth, fresh: true, queued: true) } },
                         articleStates: store.articles,
                         onOpenArticle: { e in store.openArticle(e, auth: auth) },
                         expandedArticleID: store.expandedEntryID,
                         onBigBang: { text, sourceID in
                             bigBangPayload = BigBangPayload(text: text, sourceID: sourceID)
                         })
        // v3.4.26 同款生命周期：选中即首刷 + 30s 轮询；离开 = task 取消即停
        .task(id: isActive) {
            guard isActive else { return }
            await store.load(auth: auth)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }   // 切走（task 取消）后不再多发一次请求
                await store.load(auth: auth)
            }
        }
        .sheet(isPresented: $showSettings) {
            LifeCardsSettingsView()
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $bigBangPayload) { payload in
            // v3.9.0：zoom 转场——从被长按的资讯行"生长"出来
            if payload.sourceID.isEmpty {
                BigBangView(text: payload.text)
            } else {
                BigBangView(text: payload.text)
                    .navigationTransition(.zoom(sourceID: payload.sourceID, in: zoomNS))
            }
        }
    }
}
