import SwiftUI

// MARK: - v3.9.32 生活页「快递 / 价格监控」真卡片
//
// 数据来自后端 /api/life/cards（真采集：快递100 / 自定义源、商品页面抓价），
// 解析在 Core/LifeCards.swift（LifeExpressCard / LifePriceCard），这里只做渲染。
//
// 视觉口径（与 LifeCardsSection / LifeStockCard 同一套，别另立）：
//   · 容器 .dashboardCard()（默认 16pt 圆角 + 0.8pt 描边），滚动层次用 .scrollDepth()
//   · 胶囊一律走 Theme/Pill 的 .pill(.page)（不自己拼 Capsule + padding）
//   · 内边距 Spacing / 字号 Typography / 浓淡 Tint / 行距 LineSpacing / 圆角 Radius / 动效 Motion；
//     ⚠️ 栈间距（VStack/HStack spacing:）按全仓口径仍写字面值，不套 Spacing（见 Spacing.swift 第 4 条）
//   · 价格用等宽数字 + contentTransition(.numericText())：刷新是滚动而不是硬跳
//
// ⚠️ 视图刻意拆成小 struct（卡头 / 卡内提示 / 单行）：本仓曾因深层 ViewBuilder
//    表达式触发 CI type-check 超时。

// MARK: 快递卡

struct LifeExpressCardView: View {
    let card: LifeExpressCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LifeCardHeaderRow(icon: "shippingbox",
                              title: card.title.isEmpty ? "快递" : card.title,
                              countText: card.countText,
                              flagText: flagText,
                              flagColor: flagColor)
            ForEach(card.packages) { p in
                LifeExpressRow(pkg: p)
                if p.id != card.packages.last?.id { Divider().opacity(0.4) }
            }
            // 部分单号查不到时后端给卡级 error（如 "查询失败: YT…"）；有单号才走到这里
            if !card.ok, !card.error.isEmpty {
                LifeCardNoteRow(icon: "wifi.exclamationmark", text: card.error)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
        .scrollDepth()
    }

    /// 卡头右侧状态小字（全部正常时不占位）
    /// 卡级 ok = 任一单号查询成功，所以 !ok 就是「全部未查到」（后端 error 也会在卡内另起一行）
    private var flagText: String {
        if !card.ok { return "全部未查到" }
        if card.deliveredCount == card.packages.count { return "全部已签收" }
        let failed = card.packages.filter { !$0.ok }.count
        return failed > 0 ? "\(failed) 件未查到" : ""
    }

    private var flagColor: Color { card.ok ? .green : .orange }
}

/// 单件快递：公司名 + 单号后 4 位 / 最新轨迹 / 状态 + 相对时间
struct LifeExpressRow: View {
    let pkg: LifeExpressParcel   // ⚠️ 是渲染侧 Parcel（LifeCards.swift），不是配置侧 Package（LifeConfig.swift）

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            topLine
            Text(pkg.detailText)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .lineSpacing(LineSpacing.compact)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            footLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(pkg.isDelivered ? 0.7 : 1)   // 已签收的行弱化，视线留给在途件
        .accessibilityElement(children: .combine)
    }

    private var topLine: some View {
        HStack(spacing: 6) {
            Text(pkg.title)
                .font(.system(size: Typography.body, weight: .medium))
                .lineLimit(1)
            if !pkg.carrierLabel.isEmpty {
                Text(pkg.carrierLabel)
                    .pill(.page, tone: .neutral)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !pkg.maskedNo.isEmpty {
                Text(pkg.maskedNo)
                    .font(.system(size: Typography.tiny).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var footLine: some View {
        HStack(spacing: 6) {
            if !pkg.statusText.isEmpty {
                Text(pkg.statusText)
                    .pill(.page, tone: pkg.isDelivered ? .accent : .neutral)
            }
            if !pkg.timeText.isEmpty {
                Text(pkg.timeText)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: 价格监控卡

struct LifePriceCardView: View {
    let card: LifePriceCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LifeCardHeaderRow(icon: "tag",
                              title: card.title.isEmpty ? "价格监控" : card.title,
                              countText: card.countText,
                              flagText: flagText,
                              flagColor: flagColor)
            ForEach(card.items) { it in
                LifePriceRow(item: it)
                if it.id != card.items.last?.id { Divider().opacity(0.4) }
            }
            if !card.ok, !card.error.isEmpty {
                LifeCardNoteRow(icon: "wifi.exclamationmark", text: card.error)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
        .scrollDepth()
    }

    /// 到价是有用信号，优先报；没有到价也没有失败时不占位
    private var flagText: String {
        if card.reachedCount > 0 { return "到价 \(card.reachedCount) 项" }
        let failed = card.items.filter { !$0.ok }.count
        return failed > 0 ? "\(failed) 项未取到" : ""
    }

    private var flagColor: Color { card.reachedCount > 0 ? .red : .orange }
}

/// 单个商品：名称 + 现价（货币符号）+ 目标价；到价时整行淡红底 + 胶囊高亮
struct LifePriceRow: View {
    let item: LifePriceWatchItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            nameLine
            priceLine
            if !item.ok {
                Text(item.failureText)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 内边距恒定（只有底色随到价切换）——避免到价瞬间整行抖版
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(item.isReached ? Color.red.opacity(Tint.subtle) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .animation(Motion.snap, value: item.isReached)
        .accessibilityElement(children: .combine)
    }

    private var nameLine: some View {
        HStack(spacing: 6) {
            Text(item.displayName)
                .font(.system(size: Typography.body))
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.isReached {
                Text("已到价").pill(.page, tone: .danger)
            }
        }
    }

    private var priceLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.priceText)
                .font(.system(size: Typography.title, weight: .bold).monospacedDigit())
                .foregroundStyle(item.isReached ? Color.red : Color.primary)
                .contentTransition(.numericText())
                .animation(Motion.snap, value: item.priceText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !item.targetText.isEmpty {
                Text(item.targetText)
                    .font(.system(size: Typography.tiny).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: 共用小件（快递 / 价格两卡口径一致）

/// 卡片首行：图标 + 标题 + 计数胶囊 + 右侧状态小字
struct LifeCardHeaderRow: View {
    let icon: String
    let title: String
    let countText: String
    var flagText: String = ""
    var flagColor: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: Typography.body, weight: .bold))
                .lineLimit(1)
            if !countText.isEmpty {
                Text(countText).pill(.page, tone: .neutral)
            }
            Spacer(minLength: 0)
            if !flagText.isEmpty {
                Text(flagText)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(flagColor)
                    .lineLimit(1)
            }
        }
    }
}

/// 卡内提示行（源失败 / 部分失败）——与 LifeCardsSection.noteRow 同口径
struct LifeCardNoteRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}
