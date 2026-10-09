import SwiftUI
import UIKit

// MARK: - v3.5.x 看板「生活数据」卡片区（行情 + 资讯 + 快递）
//
// v3.9.37（用户要求）：**栏目标题「生活数据」改名为「股票」**——这一栏标题行下面紧跟的就是行情卡网格
//          （资讯有自己的页级标题行，快递卡自带卡面说明），旧名与内容对不上，故按用户口径更名；
//          同步改：空态文案去「生活数据」字样、折叠箭头无障碍标签。
//
// v3.9.32：快递从「占位小字」升级为真卡片（LifeExpressCardView，
//          同目录 LifeExpressPriceCards.swift）；后端 packages 为空时仍走占位小字，
//          **不渲染空卡**。
//
// 与 DeviceCard / MeterCard / ServiceCard / PinCard 同一套**几何**语言：默认圆角 16 + Capsule 胶囊 + 0.8pt 描边。
//   ⚠️ 圆角约定（v3.8.1 用户要求「生活栏目卡片圆角跟看板一致」）：
//      本文件所有卡片一律 16 圆角——真实卡片与空态/占位/提示条**都**是 16；
//      不要再传 cornerRadius（除非是有意的高亮 hero 卡）
//   ⚠️ 卡底口径（v4.0.67 P3 用户 A+C 定稿）：本 section 渲染在**生活页内**（LifeView 的 visibleSections），
//      必须跟同页备忘/待办/习惯/目标/记录各卡同底 → 全文件换 `.pastelCard()`（淡彩渐变底 + 紫调柔影）。
//      看板页已不再承载本 section（见 LifeView 文件头），所以换底不会牵动看板卡（那边仍是 dashboardCard 玻璃底）。
//   数值用 contentTransition(.numericText())，动效用 Motion 令牌，按压用 PressStyle()
// 可折叠（@AppStorage 持久化）+ 手动刷新；数据源不可用时显示小字，不空白、不转圈卡住。

struct LifeCardsSection: View {
    let data: LifeCardsData
    let loading: Bool
    var error: String = ""          // 传输层错误（网络/未接线）
    /// v3.9.0：zoom 转场命名空间（非闭包实参必须声明在闭包型属性**之前**，否则调用点实参序不合法）
    var zoomNS: Namespace.ID
    // v3.5.x：股票卡片长按增删（删除 → POST /api/life/config 去掉该股票；添加 → 打开设置页）
    var onDeleteStock: (LifeStock) -> Void = { _ in }
    var onAddStock: () -> Void = {}
    var onRefresh: () -> Void = {}
    // v4.0.61：资讯卡专用「刷新」胶囊被「下一批」取代（用户 2026-10-05 要求）——
    //   卡片改为每批 rssBatchSize 条 + 纯本地翻页
    // v4.0.x（用户 2026-10-06）：「更新于 14:32」时间文案撤下，该槽位改回「刷新」胶囊 ——
    //   「下一批」（本地翻页，零请求）与「刷新」（走 onRefresh = /api/life/cards?fresh=1 绕 900s 缓存）
    //   在标题行共存，两者互不替代；时间文案如要恢复：把那个 Button 换回 data.updatedText 的 Text 即可
    //   （模型层 updated / updatedText 仍在，未删）
    var articleStates: [String: LifeArticleState] = [:]
    var onOpenArticle: (LifeRssEntry) -> Void = { _ in }
    /// v3.6.2：当前展开的条目 id（单一真源——只渲染这一条的正文，收起时置 nil 即真正收起；
    /// articleStates 仅作内容缓存，不再决定是否渲染）
    var expandedArticleID: String? = nil
    // v3.7.0：资讯正文长按菜单（复制整段 / 大爆炸）——由 LifeView 提供大爆炸承载页
    var onBigBang: (String, String) -> Void = { _, _ in }   // v3.9.0：(正文, 源行 id) —— 源 id 供 zoom 用

    @AppStorage("dashboard_life_expanded") private var expanded = true
    /// v3.9.17：资讯卡独立折叠——标题行搬到卡片外后，它和「生活数据」一样有自己的收起箭头
    @AppStorage("dashboard_rss_expanded") private var rssExpanded = true

    // v4.0.61：资讯分页（用户要求「刷新胶囊换成下一批胶囊」）——一批 3 条，纯本地翻页不发请求
    private let rssBatchSize = 3
    @State private var rssBatch = 0

    /// v4.0.84 拍 4 的减动效出口（开「减弱动态效果」时骨架直接换内容，不留过程）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // v4.0.84 拍 4：骨架 → 内容不再硬切。套 Group 是为了能给「if」整体挂 animation
            //（修饰符不能直接接在 if 语句上）。
            // 🚨 驱动值必须同时覆盖 data.loaded 与 loading 两个边界：骨架的显隐判据其实是
            //    `!data.loaded && loading`（见 content 里那个 if），只拿 loading 当 value 时，
            //    若「数据到了」与「loading 归假」落在不同更新帧，骨架→内容就是硬切（无报错）。
            //    2026-10-09 发版前审查抓到。
            Group {
                if expanded { content.transition(.opacity) }
            }
            .animation(reduceMotion ? nil : Motion.settle, value: !data.loaded && loading)
        }
        // v4.0.61 审查 8：条目换了一批（刷新 / 轮询 / 换股票）就回到第 1 批——
        // 否则用户点过「下一批」后会永远停在上次页码、跳过新到的第 1 批
        .onChange(of: data.entries.map(\.title)) { rssBatch = 0 }
    }

    // MARK: 标题行（对齐 DashboardView.sectionTitle 的字号与上间距）

    private var header: some View {
        HStack(spacing: 8) {
            // v4.0.84 方案 B①：行首图标底（与生活页各板块标题行同款）。
            // 几何走 BadgeShell 同一处；符号/色取 LifeSection.lifeCards 的映射（本行就是该板块的内容）
            Image(systemName: LifeSection.lifeCards.icon)
                .font(.system(size: 20 * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .modifier(BadgeShell(size: 20, color: LifeSection.lifeCards.tint))
            // v3.9.37：栏目标题「生活数据」→「股票」（用户要求；本标题行下面紧跟的是行情卡网格）
            Text("股票")
                .font(.system(size: Typography.body, weight: .bold))
            Spacer(minLength: 0)
            if loading {
                ProgressView().controlSize(.small)
            }
            // v3.5.x：添加股票卡片入口（打开生活卡片设置页）
            Button {
                onAddStock()
            } label: {
                Text("添加股票").pill(.page)   // v3.9.19：页级胶囊口径
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("添加股票卡片")
            Button {
                onRefresh()
            } label: {
                // v4.0.69：在途时给可见反馈（原来只靠 .disabled 灰掉，用户不知道点击有没有生效）
                Text(loading ? "刷新中" : "刷新").pill(.page)   // v3.9.19：页级胶囊口径
            }
            .buttonStyle(PressStyle())
            // v4.0.69（用户报「博客资讯的刷新胶囊点击无法强制刷新」）：**去掉 `.disabled(loading)`**。
            // 配套 LifeView.loadLife(queued: true)：在途点击不再被丢弃，而是排队补发这一次 fresh 请求。
            // 原来 disabled + 闸门静默 return 两重叠加 = 点了完全没反应。

            Button {
                withAnimation(Motion.snap) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(PressStyle(scale: 0.9))
            .accessibilityLabel(expanded ? "收起股票" : "展开股票")
        }
        .padding(.top, Spacing.sm)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if !data.loaded {
            if loading {
                // v3.9.0：首屏加载骨架（行情 2 格 + 资讯长卡形状，与真实卡片同圆角同栅格）
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        SkeletonCard {
                            SkeletonBlock(width: 52, height: 10)
                            SkeletonBlock(width: 74, height: 20)
                            SkeletonBlock(width: 44, height: 9)
                        }
                        SkeletonCard {
                            SkeletonBlock(width: 52, height: 10)
                            SkeletonBlock(width: 74, height: 20)
                            SkeletonBlock(width: 44, height: 9)
                        }
                    }
                    SkeletonCard {
                        SkeletonBlock(width: 140, height: 11)
                        SkeletonBlock(height: 10)
                        SkeletonBlock(width: 200, height: 10)
                    }
                }
                // v4.0.84 拍 4：骨架淡出（驱动在 body 的 .animation(Motion.settle, value: loading)）
                .transition(.opacity)
            } else {
                noteCard(icon: "chart.line.uptrend.xyaxis", text: "暂无数据 · 点刷新")
                    .transition(.opacity)
            }
        } else if !data.hasContent {
            // v3.9.32：一条行情/资讯都没有时——快递有真数据就先渲染真卡（不空白），
            // 只有「连快递都没配」才保留原来的「未配置」提示卡
            if data.hasLifeCards {
                VStack(alignment: .leading, spacing: 10) {
                    expressBlock
                    placeholderCard
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    noteRow(icon: "exclamationmark.triangle", text: degradeText)
                    ForEach(data.placeholders) { p in placeholderRow(p) }
                }
                .padding(Spacing.section)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pastelCard()   // v4.0.67 P3：空态/占位块跟真卡同底（pastelCard 默认 Radius.card 16）
            }
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
            // 博客/资讯：v3.9.17 标题行搬到卡片外（页级标题），卡片里只放条目
            if !data.entries.isEmpty { rssSection }
            // 快递：v3.9.32 起渲染真卡片（后端已真采集）；未配置走占位小字
            expressBlock
            placeholderCard
            if !data.rssErrorText.isEmpty {
                noteRow(icon: "wifi.exclamationmark", text: data.rssErrorText)
                    .padding(.horizontal, Spacing.xs)
            }
            if !error.isEmpty {
                noteRow(icon: "exclamationmark.triangle", text: error)
                    .padding(.horizontal, Spacing.xs)
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

    // MARK: v3.9.32 快递（真卡片；空数据不渲染，避免空卡）

    /// 快递真卡片——后端 packages 为空时 parse 不建卡（见 LifeCardsData.parse），
    /// 所以这里只渲染「有数据」的类型
    @ViewBuilder
    private var expressBlock: some View {
        if let ex = data.express { LifeExpressCardView(card: ex) }
    }

    /// 未配置类型的占位小字（后端在 packages 为空时下发 error + hint）
    @ViewBuilder
    private var placeholderCard: some View {
        if !data.placeholders.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(data.placeholders) { p in placeholderRow(p) }
            }
            .padding(Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pastelCard()   // v4.0.67 P3：空态/占位块跟真卡同底（pastelCard 默认 Radius.card 16）
        }
    }

    // MARK: v3.9.17 博客/资讯（标题行搬到卡片外，与「股票」同款页级标题）

    private var rssSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            rssHeader
            if rssExpanded { rssCard }
        }
    }

    /// 与 header（「股票」）同款：粗体 15pt 标题 + Spacer + 淡色胶囊 + 折叠箭头
    private var rssHeader: some View {
        HStack(spacing: 8) {
            // v4.0.84 方案 B①：与「股票」行同款图标底。资讯不是 LifeSection，符号/色就地写死
            // （与各板块空态卡里 icon:/title: 就地写字面量同一惯例）
            Image(systemName: "newspaper")
                .font(.system(size: 20 * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .modifier(BadgeShell(size: 20, color: .indigo))
            Text("博客/资讯")
                .font(.system(size: Typography.body, weight: .bold))
            Spacer(minLength: 0)
            // v3.6.2：资讯专用刷新——后端 ?fresh=1 强制绕缓存（原整块刷新受 RSS 15 分钟缓存限制，
            // 点了 15 分钟内不出新内容）
            // v4.0.61：刷新胶囊 → 下一批胶囊（本地翻到下一批条目，不再重复当前这批）
            if rssPageCount > 1 {
                Button {
                    withAnimation(Motion.snap) { rssBatch = (rssBatch + 1) % rssPageCount }
                } label: {
                    Text("下一批").pill(.page)   // v3.9.19：页级胶囊口径
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("下一批资讯")
            }
            // v4.0.x（用户 2026-10-06）：「更新于 14:32」→「刷新」胶囊（原时间文案整块撤下）
            // v4.0.65 审查（建议）：**口径订正** —— 它触发的 onRefresh 是**整块生活数据**的强制刷新
            //（LifeView → loadLife(fresh: true) → /api/life/cards?fresh=1，含股票/资讯/快递），
            // 并非「资讯专用」；股票栏那颗刷新绑的是同一个 onRefresh → 同屏两颗等价入口（用户要求保留）。
            Button {
                onRefresh()
            } label: {
                // v4.0.69：在途时给可见反馈（与股票栏那颗同一口径）
                Text(loading ? "刷新中" : "刷新").pill(.page)   // v3.9.19：页级胶囊口径
            }
            .buttonStyle(PressStyle())
            // v4.0.69：同股票栏那颗 —— 去掉 `.disabled(loading)`，配套 loadLife(queued: true) 排队补发
            .accessibilityLabel("刷新生活数据")
            Button {
                withAnimation(Motion.snap) { rssExpanded.toggle() }
            } label: {
                Image(systemName: rssExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(PressStyle(scale: 0.9))
            .accessibilityLabel(rssExpanded ? "收起资讯" : "展开资讯")
        }
        .padding(.top, Spacing.sm)
    }

    // MARK: v4.0.61 资讯分页（纯本地，零请求）

    /// 把后端一次给的 entries 按 rssBatchSize 切批；空数组 = 零批
    private var rssPages: [[LifeRssEntry]] {
        stride(from: 0, to: data.entries.count, by: rssBatchSize).map {
            Array(data.entries[$0 ..< min($0 + rssBatchSize, data.entries.count)])
        }
    }

    /// 批数下限 1（entries 为空时按钮也不显示，见 rssHeader 的 rssPageCount > 1）
    private var rssPageCount: Int { max(1, rssPages.count) }

    /// 当前批（rssBatch 越界时钳回最后一批——刷新后条目变少不会空卡）
    private var rssPageEntries: [LifeRssEntry] {
        guard !rssPages.isEmpty else { return [] }
        return rssPages[min(max(rssBatch, 0), rssPages.count - 1)]
    }

    /// 卡片里只放条目（v3.9.17：原来卡内那行「广播图标 + 博客/资讯 + 刷新 + 时间」整行已搬出去）
    private var rssCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rssPageEntries) { e in
                rssRow(e)
                if e.id != rssPageEntries.last?.id {
                    Divider().opacity(0.4)
                }
            }
        }
        .padding(Spacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard()   // v4.0.67 P3：生活页真实卡换淡彩渐变底（Radius.card 16，几何不变）
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
        .matchedTransitionSource(id: e.id, in: zoomNS)   // v3.9.0：长按大爆炸时从这一行 zoom 展开
        // v3.7.0：长按弹出菜单（复制整段 / 大爆炸 / 发给 AI）——正文已加载则作用于正文，否则退化为标题
        .contextMenu {
            Button {
                UIPasteboard.general.string = articleMenuText(e)
                Haptics.success()
            } label: {
                Label("复制整段", systemImage: "doc.on.doc")
            }
            Button {
                onBigBang(articleMenuText(e), e.id)   // v3.9.0：带上资讯行 id
            } label: {
                Label("大爆炸", systemImage: "burst.fill")
            }
            // v3.9.30：对齐备忘录「发给 AI」体验——资讯内容直接作为用户消息发给 AI 并切回聊天页。
            // 复用 qingliaoMemoSend 通知链（DockTabView 切页 + ChatView sendCore 已就绪）；
            // 资讯行在生活页主体（非 sheet 之内）→ 无需 afterAllDismissed。
            Button {
                Haptics.success()
                NotificationCenter.default.post(name: .qingliaoMemoSend, object: articleMenuText(e))
            } label: {
                Label("发给 AI", systemImage: "paperplane")
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
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        case .loaded(let a):
            VStack(alignment: .leading, spacing: 6) {
                Text(a.content)
                    .font(.system(size: Typography.body))
                    .lineSpacing(LineSpacing.long)
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
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.tertiary)
                }
            }
        case .failed(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: Typography.caption))
                Text(msg)
                    .font(.system(size: Typography.subhead))
                Spacer(minLength: 0)
                Text("点击重试")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.tertiary)
        }
    }

    private func articleTag(_ t: String) -> some View {
        Text(t)
            .font(.system(size: Typography.tiny))
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background(Color.accentColor.opacity(Tint.faint), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }

    private func rssRowBody(_ e: LifeRssEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title)
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if !e.source.isEmpty {
                        Text(e.source)
                            .font(.system(size: Typography.caption))
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xxs)
                            .background(Color.accentColor.opacity(Tint.faint), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    if !e.timeText.isEmpty {
                        Text(e.timeText)
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: Typography.tiny, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, Spacing.xs)
        }
        .contentShape(Rectangle())
    }

    private func placeholderRow(_ p: LifePlaceholderItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: p.id == "express" ? "shippingbox" : "tag")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
            Text(p.title)
                .font(.system(size: Typography.subhead, weight: .medium))
                .foregroundStyle(.secondary)
            Text(p.note)
                .font(.system(size: Typography.tiny))
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
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard()   // v4.0.67 P3：单行提示条跟真卡同底（16）
    }

    private func noteRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: Typography.caption))
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
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.bounce, value: stock.detailText)   // v3.9.0：行情刷新弹一下
                Text(stock.name)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
            }
            Text(stock.priceText)
                .font(.system(size: Typography.headline, weight: .bold).monospacedDigit())   // v3.9.19：等宽数字
                .contentTransition(.numericText())            // 数值滚动而非硬跳
                .animation(Motion.snap, value: stock.priceText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, Spacing.sm)
            Text(stock.detailText)
                .font(.system(size: Typography.tiny, weight: .medium))
                .foregroundStyle(changeColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, Spacing.xxs)
        }
        .padding(Spacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard()   // v4.0.67 P3：行情卡换淡彩渐变底（与同页其它卡同底）
        .scrollDepth()     // v3.9.0：滚动层次感
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

// v3.9.59：股票走势线已按用户要求移除（卡面回到 v3.9.57 前的纯行情展示）。
// 历史实现见 git log（StockSparkline + /api/life/stock/history 拉取，v3.9.58 引入）。
