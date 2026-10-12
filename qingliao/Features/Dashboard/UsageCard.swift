import SwiftUI

/// v3.0.36 模型使用量卡片（与 MeterCard/ServiceCard 同款 HomeKit 卡片风格）
/// 每 provider 一张：图标 + 名 + 余额/用量 + 副文本 + 状态；plan 模式加用量进度条
/// v3.9.82：token 用量卡 —— 今日 / 本月两栏，主数字 M（百万），下排小字拆输入/输出/缓存命中。
/// 「含缓存命中」是有意的口径：缓存读也是真实消耗的 token（计费打折但不为 0），
/// 拆出来是为了让用户看得见大头在哪，而不是把 3 亿藏起来。
struct TokenUsageCard: View {
    let usage: TokenUsage
    /// v3.9.85：长按重置（nil=不启用）
    /// v4.0.102：回调带上**卡片自身的全局 frame** —— 重置确认的浮层从这张卡的位置长出
    /// （原走 confirmationDialog，iPhone 上系统固定从屏幕底部升起，用户 2026-10-12 报「没跟着卡片位置弹出」）。
    /// 锚点必须报给**宿主页最外层**去挂浮层：挂在本卡片的 overlay 上会被滚动里后面的卡片盖住（v4.0.77 教训）。
    var onReset: ((CGRect) -> Void)? = nil
    @State private var cardFrame: CGRect = .zero

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            column(title: "今日", icon: "calendar", window: usage.today, color: .blue)
            column(title: "本月", icon: "calendar.badge.clock", window: usage.month, color: .indigo)
        }
        // v4.0.102：锚点采集 —— 重置确认浮层从**这张卡**的位置长出（浮层由宿主页最外层挂）
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cardFrame = $0 }
        .onLongPressGesture(minimumDuration: 0.5) {
            guard onReset != nil else { return }
            Haptics.medium()
            onReset?(cardFrame)
        }
        // v4.0.102：原 `.confirmationDialog("重置 token 用量统计？…")` 已删 —— 改由宿主
        // （DashboardView.dashboardAnchorMenuLayer）挂锚定浮层，从卡片位置长出。
    }

    @ViewBuilder
    private func column(title: String, icon: String, window: TokenUsage.Window, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: Typography.tiny, weight: .medium))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: Typography.tiny, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(window.totalM)
                .font(.system(size: Typography.title, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("输入 \(window.inputM) · 输出 \(window.outputM)")
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("缓存 \(window.cacheM)" + (window.sessions > 0 ? " · \(window.sessions) 会话" : ""))
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.xl)
        .dashboardCard()
    }
}

struct UsageCard: View {
    let usage: ProviderUsage

    private var statusColor: Color {
        if usage.unsupported { return .gray }
        if !usage.available { return .red }
        if usage.mode == "plan" {
            if let m = usage.usagePercent["monthly"] {
                return m >= 90 ? .red : (m >= 60 ? .orange : .green)
            }
            return .green
        }
        if usage.total <= 10 { return .orange }   // 余额低于 10 元预警
        return .green
    }

    private var icon: String {
        switch usage.provider {
        case "deepseek": return "d.circle.fill"
        case "stepfun": return "s.circle.fill"
        case "xiaomi": return "x.circle.fill"
        case "opencode-apple", "opencode": return "o.circle.fill"
        case "sensenova": return "s.square.fill"
        case "zai": return "z.circle.fill"
        case "zai-coding": return "z.circle.fill"
        default: return "terminal.fill"
        }
    }

    /// plan 模式月用量进度（0-100；无数据返回 nil 不显示条）
    private var planPercent: Double? {
        guard usage.mode == "plan" else { return nil }
        return usage.usagePercent["monthly"]
    }

    /// v3.4.18：智谱双窗口主进度（5小时窗口已用百分比；无数据 nil）
    private var windowPercent: Double? {
        guard let w5 = usage.windows.first else { return nil }
        if let p = w5["used_pct"] as? Int { return Double(p) }
        if let p = w5["used_pct"] as? Double { return p }
        if let used = w5["used"] as? Int, let total = w5["total"] as? Int, total > 0 {
            return Double(used) / Double(total) * 100
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.icon, style: .continuous)
                        .fill(statusColor.opacity(0.15))
                    Image(systemName: icon)
                        .font(.system(size: Typography.subhead, weight: .medium))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 28, height: 28)
                Text(usage.name)
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
            }
            Text(usage.balanceText)
                .font(.system(size: Typography.title, weight: .bold))
                .foregroundStyle(usage.unsupported ? Color.secondary : statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // v3.0.36 plan（opencode）：月用量进度条
            if let pct = planPercent, usage.mode == "plan" {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(uiColor: .systemGray5))
                        Capsule()
                            .fill(pct >= 90 ? Color.red : (pct >= 60 ? Color.orange : Color.green))
                            .frame(width: geo.size.width * min(max(pct / 100.0, 0), 1))
                    }
                }
                .frame(height: 4)
            }
            // v3.4.18 智谱双窗口：5小时窗口用量进度条
            else if let pct = windowPercent {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(uiColor: .systemGray5))
                        Capsule()
                            .fill(pct >= 90 ? Color.red : (pct >= 60 ? Color.orange : Color.green))
                            .frame(width: geo.size.width * min(max(pct / 100.0, 0), 1))
                    }
                }
                .frame(height: 4)
            }
            Text(usage.detailText)
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(Spacing.xl)
        .dashboardCard()
    }
}

