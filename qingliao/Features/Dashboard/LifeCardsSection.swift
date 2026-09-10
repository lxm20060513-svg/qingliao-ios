import SwiftUI

// MARK: - v3.5.x 看板「生活数据」卡片区（股票行情 + RSS/博客更新）
//
// 与 DeviceCard / MeterCard / ServiceCard / PinCard 同一套卡片语言：
//   .dashboardCard(cornerRadius: 10) + Capsule 胶囊 + 0.8pt 描边（由 dashboardCard 提供）
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !data.updatedText.isEmpty {
                    Text(data.updatedText)
                        .font(.system(size: 10))
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
        .dashboardCard(cornerRadius: 10)
    }

    @ViewBuilder
    private func rssRow(_ e: LifeRssEntry) -> some View {
        if let url = URL(string: e.link), !e.link.isEmpty {
            Link(destination: url) { rssRowBody(e) }
                .buttonStyle(PressStyle())
        } else {
            rssRowBody(e)
        }
    }

    private func rssRowBody(_ e: LifeRssEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if !e.source.isEmpty {
                        Text(e.source)
                            .font(.system(size: 9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    if !e.timeText.isEmpty {
                        Text(e.timeText)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
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
        .dashboardCard(cornerRadius: 10)
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
