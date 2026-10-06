import SwiftUI

// MARK: - v4.0.45 待做池④：生活数据可视化报表
//
// 定位：记录页「全部记录」右上角「报表」入口 → 独立半屏页
// （不进首页卡：首页卡是 84pt 恒高口径，塞图表会撞它）。
//
// 两块图：① 近 14 天逐日支出折线 ② 本月分类占比环图。
//
// 「同源」是这一页的核心护栏：折线数字来自 `RecordKit.dailySeries`、环图来自
// `RecordKit.categoryTotals`、汇总来自 `RecordKit.monthProjection` —— 与账本列表
// 用的是同一套只算「元」的支出口径，**视图里一行业务聚合都不写**（否则图和列表会对不上，
// 而且是那种"看着都合理"的错）。
//
// 为什么手绘 Path 而不引 Swift Charts：本机无 iOS SDK，只有 `swiftc -parse`（纯语法、不做
// 类型检查），Charts 的 API 形态错只有 CI Archive 才炸（本仓反复踩过）。手绘只用最稳的
// Path / GeometryReader 原语，把「本地查不出类型错」的风险压到最低。两块图都用 RecordKit
// 的纯函数喂数，所以图本身逻辑也进了真值表（scripts/ql_report）。

struct RecordReportSheet: View {
    @State private var store = RecordStore.shared
    @Environment(\.dismiss) private var dismiss

    /// 近 14 天逐日支出（折线）
    private var series: [RecordKit.DayPoint] { RecordKit.dailySeries(store.records, days: 14) }
    /// 本月分类占比（环图）—— 与记录页顶卡「本月分类占比」同一个函数
    private var totals: [CategoryTotal] { RecordKit.categoryTotals(store.records) }
    /// 本月汇总（复用时序口径与明细页汇总卡一致）
    private var projection: MonthProjection { RecordKit.monthProjection(store.records) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        summaryCard
                        trendCard
                        categoryCard
                    }
                    .padding(.horizontal, Spacing.section)
                    .padding(.bottom, Spacing.xxl)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
    }

    // MARK: 顶栏（与「全部记录」弹窗同款：标题 + 右位完成胶囊）

    private var header: some View {
        HStack(spacing: 8) {
            Text("数据报表")
                .font(.system(size: Typography.title, weight: .semibold))
            Spacer(minLength: 0)
            MiniCapsule(title: "完成", accent: true) { dismiss() }
        }
        .padding(.horizontal, Spacing.section)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.md)
    }

    // MARK: 本月汇总

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("本月已花")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(String(format: "%.2f 元", projection.spent))
                    .font(.system(size: Typography.title, weight: .semibold))
                    .monospacedDigit()
            }
            HStack(alignment: .top, spacing: 18) {
                metric("日均", String(format: "%.0f", projection.dailyAvg))
                metric("本月收入", String(format: "%.0f", projection.income))
                metric("月末预估", String(format: "%.0f", projection.projected))
                Spacer(minLength: 0)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard()
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: Typography.subhead, weight: .medium))
                .monospacedDigit()
        }
    }

    // MARK: 支出趋势（折线）

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: 8) {
                Text("支出趋势")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                Spacer(minLength: 0)
                Text("近 14 天")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
            if RecordKit.trendReady(series) {
                ExpenseLineChart(series: series)
            } else {
                ReportHintCard(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "再记几天就能出趋势图",
                    subtitle: "已记 \(RecordKit.daysWithExpense(series)) 天，满 \(RecordKit.reportMinDays) 天自动出图"
                )
            }
            Text("只统计「元」支出；电表读数与收入不进趋势线。")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard()
    }

    // MARK: 分类占比（环图）

    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: 8) {
                Text("分类占比")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                Spacer(minLength: 0)
                Text("本月")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
            // v4.0.47：判据从「totals 为空」改成「有没有 >0 的金额」——amount == 0 的「元」条目
            // 也会进 totals（固定支出照抄 f.amount，不过滤 0），只判 isEmpty 会画出灰圈空图，
            // 与口径「数据不足出引导卡、不生成空图」相悖。
            if !totals.contains(where: { $0.amount > 0 }) {
                ReportHintCard(
                    icon: "chart.pie",
                    title: "还没有可分类的支出",
                    subtitle: "记一笔带分类的账，这里会按占比分出来"
                )
            } else {
                HStack(alignment: .top, spacing: Spacing.lg) {
                    // 环图/图例的「总额」直接用本月已花（RecordKit.monthProjection.spent），
                    // 不在视图里对 totals 再求和一次 —— 护栏：图中数字必须与汇总卡同源（禁二次聚合）。
                    CategoryDonut(totals: totals, total: projection.spent)
                    CategoryLegend(totals: totals, total: projection.spent)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard()
    }
}

// MARK: - 折线趋势图（纯 Path 手绘）

/// 近 N 天逐日支出折线 + 面积渐变。数据由 `RecordKit.dailySeries` 给出（升序、缺天补 0）。
/// 调用点已用 `RecordKit.trendReady` 挡掉「数据不足」，这里仍对 0 / 单点做防御
/// （护栏：零值/单点不得崩、不得画成一条假的水平线）。
private struct ExpenseLineChart: View {
    let series: [RecordKit.DayPoint]

    private let chartHeight: CGFloat = 120
    private let pad: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                chart(in: geo.size)
            }
            .frame(height: chartHeight)
            HStack {
                if let first = series.first { Text(first.label) }
                Spacer()
                if series.count > 2 { Text(series[series.count / 2].label) }
                Spacer()
                if let last = series.last { Text(last.label) }
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
    }

    @ViewBuilder
    private func chart(in size: CGSize) -> some View {
        let peak = RecordKit.seriesPeak(series)
        let n = series.count
        let stepX = n > 1 ? size.width / CGFloat(n - 1) : 0
        let h = size.height
        ZStack {
            if n > 1 {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    for i in series.indices {
                        p.addLine(to: CGPoint(x: CGFloat(i) * stepX, y: yPos(series[i].expense, peak: peak, height: h)))
                    }
                    p.addLine(to: CGPoint(x: CGFloat(n - 1) * stepX, y: h))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.26),
                                              Color.accentColor.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
                Path { p in
                    p.move(to: CGPoint(x: 0, y: yPos(series[0].expense, peak: peak, height: h)))
                    for i in series.indices.dropFirst() {
                        p.addLine(to: CGPoint(x: CGFloat(i) * stepX, y: yPos(series[i].expense, peak: peak, height: h)))
                    }
                }
                .stroke(Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            ForEach(series.indices, id: \.self) { i in
                if series[i].expense > 0 {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .position(x: CGFloat(i) * stepX, y: yPos(series[i].expense, peak: peak, height: h))
                }
            }
        }
    }

    /// 值 → Y 坐标（峰值归一，顶部留 pad）。peak == 0 时贴底，**绝不做除数**。
    private func yPos(_ value: Double, peak: Double, height: CGFloat) -> CGFloat {
        let usable = max(height - pad * 2, 1)
        guard peak > 0 else { return height }
        let ratio = min(max(value, 0) / peak, 1)
        return pad + usable * CGFloat(1 - ratio)
    }
}

// MARK: - 分类环图（纯 Path 手绘）

/// 一个扇段（先算好角度，视图里只管画；角度口径收在一处）
private struct DonutSector: Identifiable {
    let id: String
    let category: String
    let start: Double   // 度，-90 = 12 点方向
    let end: Double
}

private struct CategoryDonut: View {
    let totals: [CategoryTotal]
    /// 总额 = 本月已花（由调用方从 RecordKit.monthProjection 传入，视图内不再求和）
    let total: Double

    private let size: CGFloat = 118
    private let lineWidth: CGFloat = 14
    private var radius: CGFloat { size / 2 - lineWidth / 2 - 2 }

    private var sectors: [DonutSector] {
        var out: [DonutSector] = []
        var acc = -90.0
        for t in totals where t.amount > 0 {
            let span = t.amount / max(total, 0.0001) * 360
            out.append(DonutSector(id: t.id, category: t.category, start: acc, end: acc + span))
            acc += span
        }
        return out
    }

    var body: some View {
        ZStack {
            if sectors.isEmpty {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: lineWidth)
                    .frame(width: radius * 2, height: radius * 2)
            } else {
                ForEach(sectors) { s in
                    Path { p in
                        p.addArc(center: CGPoint(x: size / 2, y: size / 2),
                                 radius: radius,
                                 startAngle: .degrees(s.start),
                                 endAngle: .degrees(s.end),
                                 clockwise: false)
                    }
                    .stroke(RecordCategoryColor.tint(s.category),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                }
            }
            VStack(spacing: 2) {
                Text("本月")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(String(format: "%.0f", total))
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .frame(width: size, height: size)
    }
}

/// 环图图例：前 6 类 + 「还有 N 类」。颜色复用 RecordCategoryColor（与记录页占比条同源）。
private struct CategoryLegend: View {
    let totals: [CategoryTotal]
    /// 总额 = 本月已花（调用方从 RecordKit.monthProjection 传入）
    let total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(totals.prefix(6)) { t in
                HStack(spacing: 6) {
                    Circle()
                        .fill(RecordCategoryColor.tint(t.category))
                        .frame(width: 7, height: 7)
                    Text(RecordKit.categoryLabel(t.category))
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(String(format: "%.0f%%", t.amount / max(total, 0.0001) * 100))
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            if totals.count > 6 {
                Text("还有 \(totals.count - 6) 类")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - 数据不足引导卡（不出空图）

/// 「数据不足」时替代图表的引导卡（护栏：宁可给引导，不给一张会被当成坏了的空图）。
private struct ReportHintCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: Typography.body))
                .foregroundStyle(Color.accentColor.opacity(0.8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Typography.subhead))
                Text(subtitle)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
    }
}
