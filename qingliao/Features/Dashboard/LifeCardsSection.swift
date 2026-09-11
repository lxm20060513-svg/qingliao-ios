import SwiftUI
import UIKit

// MARK: - v3.5.x 看板「生活数据」卡片区（股票行情 + RSS/博客更新）
//
// 与 DeviceCard / MeterCard / ServiceCard / PinCard 同一套卡片语言：
//   .dashboardCard()（默认 圆角 16）+ Capsule 胶囊 + 0.8pt 描边（由 dashboardCard 提供）
//   ⚠️ 圆角约定（v3.8.1 用户要求「生活栏目卡片圆角跟看板一致」）：
//      · 承载真实数据的卡片 → .dashboardCard()（16），看板与生活**必须同值**
//      · 单行提示/空态/占位条（noteCard、placeholder 块）→ .dashboardCard(cornerRadius: 10)
//        看板同类提示条也是 10，两边一起变才叫一致；不要单独改一侧
//   数值用 contentTransition(.numericText())，动效用 Motion 令牌，按压用 PressStyle()
// 可折叠（@AppStorage 持久化）+ 手动刷新；数据源不可用时显示小字，不空白、不转圈卡住。

struct LifeCardsSection: View {
    let data: LifeCardsData
    let loading: Bool
    var error: String = ""          // 传输层错误（网络/未接线）
    // v3.5.x：股票卡片长按增删（删除 → POST /api/life/config 去掉该股票；添加 → 打开设置页）
    var onDeleteStock: (LifeStock) -> Void = { _ in }
    var onAddStock: () -> Void = {}
    var onRefresh: () -> Void = {}
    // v3.6.2：资讯卡片专用刷新（只刷资讯、局部转圈）+ 点击展开正文（后端 AI 拉取，不跳浏览器）
    var feedsRefreshing: Bool = false
    var onRefreshFeeds: () -> Void = {}
    var articleStates: [String: LifeArticleState] = [:]
    var onOpenArticle: (LifeRssEntry) -> Void = { _ in }
    /// v3.6.2：当前展开的条目 id（单一真源——只渲染这一条的正文，收起时置 nil 即真正收起；
    /// articleStates 仅作内容缓存，不再决定是否渲染）
    var expandedArticleID: String? = nil
    // v3.7.0：资讯正文长按菜单（复制整段 / 大爆炸）——由 LifeView 提供大爆炸承载页
    var onBigBang: (String) -> Void = { _ in }

    @AppStorage("dashboard_life_expanded") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if expanded { content }
        }
    }

    // MARK: 标题行（对齐 DashboardView.sectionTitle 的字号与上间距）

    private var header: some View {
        HStack(spacing: 8) {
            Text("生活数据")
                .font(.system(size: 15, weight: .bold))
            Spacer(minLength: 0)
            if loading {
                ProgressView().controlSize(.small)
            }
            // v3.5.x：添加股票卡片入口（打开生活卡片设置页）
            Button {
                onAddStock()
            } label: {
                Label("添加股票", systemImage: "plus")
                    .font(.system(size: 10))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("添加股票卡片")
            Button {
                onRefresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
                    .font(.system(size: 10))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(Color.accentColor)
            .disabled(loading)

            Button {
                withAnimation(Motion.snap) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(PressStyle(scale: 0.9))
        }
        .padding(.top, 6)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if !data.loaded {
            noteCard(icon: "chart.line.uptrend.xyaxis",
                     text: loading ? "加载中…" : "暂无生活数据 · 点刷新")
        } else if !data.hasContent {
            VStack(alignment: .leading, spacing: 6) {
                noteRow(icon: "exclamationmark.triangle", text: degradeText)
                ForEach(data.placeholders) { p in placeholderRow(p) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardCard(cornerRadius: 10)
        } else {
            // 行情：2 列网格（与 NAS 面板/模型使用量的栅格一致）
            if data.stocks.isEmpty {
                noteCard(icon: "chart.line.downtrend.xyaxis", text: "行情未获取 · 点刷新")
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(data.stocks) { s in stockCell(s) }
                }
            }
            // 博客/资讯：整宽卡（对齐 PinCard 的长卡形态）
            if !data.entries.isEmpty { rssCard }
            // 未接入的占位项（快递/价格监控）
            if !data.placeholders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(data.placeholders) { p in placeholderRow(p) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dashboardCard(cornerRadius: 10)
            }
            if !data.rssErrorText.isEmpty {
                noteRow(icon: "wifi.exclamationmark", text: data.rssErrorText)
                    .padding(.horizontal, 4)
            }
            if !error.isEmpty {
                noteRow(icon: "exclamationmark.triangle", text: error)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// 行情卡 + 长按菜单（删除这张卡片 → 后端配置里去掉该股票 → 看板重拉）
    @ViewBuilder
    private func stockCell(_ s: LifeStock) -> some View {
        LifeStockCard(stock: s)
            .contentShape(Rectangle())
            .contextMenu {
                Button(role: .destructive) {
                    onDeleteStock(s)
                } label: {
                    Label("删除这张卡片", systemImage: "trash")
                }
            }
    }

    private var degradeText: String {
        if !error.isEmpty { return error }
        if !data.error.isEmpty { return data.error }
        return loading ? "加载中…" : "数据源未配置"
    }

    private var rssCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("博客/资讯")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // v3.6.2：资讯专用刷新——后端 ?fresh=1 强制绕缓存（原整块刷新受 RSS 15 分钟缓存限制，
                // 点了 15 分钟内不出新内容）
                if feedsRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    onRefreshFeeds()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(PressStyle())
                .foregroundStyle(Color.accentColor)
                .disabled(feedsRefreshing)
                .accessibilityLabel("刷新资讯")
                if !data.updatedText.isEmpty {
                    Text(data.updatedText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(data.entries) { e in
                rssRow(e)
                if e.id != data.entries.last?.id {
                    Divider().opacity(0.4)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()   // v3.8.1：真实卡片圆角与看板 DeviceCard/MeterCard/ServiceCard 统一（默认 16）
    }

    /// v3.6.2：点击该条 → 就地展开正文（后端 AI 抓取+整理），不再跳转浏览器；再点一次收起。
    /// 失败态再点一次 = 重试（失败不长期锁定）。
    @ViewBuilder
    private func rssRow(_ e: LifeRssEntry) -> some View {
        Button {
            onOpenArticle(e)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                rssRowBody(e)
                if e.id == expandedArticleID, let st = articleStates[e.id] { articleBody(st) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        // v3.7.0：长按弹出菜单（复制整段 / 大爆炸）——正文已加载则作用于正文，否则退化为标题
        .contextMenu {
            Button {
                UIPasteboard.general.string = articleMenuText(e)
                Haptics.success()
            } label: {
                Label("复制整段", systemImage: "doc.on.doc")
            }
            Button {
                onBigBang(articleMenuText(e))
            } label: {
                Label("大爆炸", systemImage: "burst.fill")
            }
        }
    }

    /// v3.7.0：长按菜单取用的文本——已展开且正文到位用正文，否则用标题（避免菜单点到空内容）
    private func articleMenuText(_ e: LifeRssEntry) -> String {
        if case .some(.loaded(let a)) = articleStates[e.id], !a.content.isEmpty {
            return a.content
        }
        return e.title
    }

    /// 展开区：加载中 / AI 正文 / 失败提示（三态）
    @ViewBuilder
    private func articleBody(_ st: LifeArticleState) -> some View {
        Divider().opacity(0.4)
        switch st {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("AI 正在读取这篇资讯…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        case .loaded(let a):
            VStack(alignment: .leading, spacing: 6) {
                Text(a.content)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if a.source != "ai" {
                        articleTag("原文未整理")
                    }
                    if a.cached {
                        articleTag("缓存")
                    }
                    if a.truncated {
                        articleTag("已截断")
                    }
                    Spacer(minLength: 0)
                    Text("点击收起")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        case .failed(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                Text(msg)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                Text("点击重试")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.tertiary)
        }
    }

    private func articleTag(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 10))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }

    private func rssRowBody(_ e: LifeRssEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if !e.source.isEmpty {
                        Text(e.source)
                            .font(.system(size: 11))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    if !e.timeText.isEmpty {
                        Text(e.timeText)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .contentShape(Rectangle())
    }

    private func placeholderRow(_ p: LifePlaceholderItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: p.id == "express" ? "shippingbox" : "tag")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(p.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(p.note)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func noteCard(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            noteRow(icon: icon, text: text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(cornerRadius: 10)
    }

    private func noteRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }
}

// MARK: - 行情卡（栅格单元，风格对齐 DeviceCard）

struct LifeStockCard: View {
    let stock: LifeStock

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(stock.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
            }
            Text(stock.priceText)
                .font(.system(size: 18, weight: .bold))
                .contentTransition(.numericText())            // 数值滚动而非硬跳
                .animation(Motion.snap, value: stock.priceText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 6)
            Text(stock.detailText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(changeColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()   // v3.8.1：真实卡片圆角与看板统一（默认 16）
    }

    /// A 股惯例：红涨绿跌（数据不可用 → 灰点 / 次色文字）
    private var changeColor: Color {
        guard stock.ok, stock.changePct != nil else { return Color.secondary }
        return stock.isUp ? .red : .green
    }

    private var dotColor: Color {
        guard stock.ok, stock.changePct != nil else { return .gray }
        return stock.isUp ? .red : .green
    }
}
