import SwiftUI

// MARK: - v3.5.0 Agent 结果卡片视图（```ql-card 围栏渲染）
//
// 视觉语言（与全站一致）：单卡 glassEffect（LiquidGlass.GlassCard，自带 0.8pt 描边）
// + 二元控件/状态用 Capsule 胶囊 + 数值变化 contentTransition(.numericText())
// + 动效令牌 Motion（卡片进入 settle，数值 snap）。
//
// 只画「有内容的段」——title/subtitle/status/fields/metrics/list/table/footer，
// 空段不占位（最小可用集合，不堆花架子）。

struct AgentResultCard: View {
    let card: AgentCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !card.metrics.isEmpty { metricsSection }
            if !card.fields.isEmpty { fieldsSection }
            if !card.items.isEmpty { listSection }
            if let table = card.table { AgentCardTable(rows: tableRows(table)) }
            if let footer = card.footer, !footer.isEmpty {
                Text(footer)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14)
        // 流式闭合后由文本替换为卡片：轻微浮现，不抢打字机节奏
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
        .animation(Motion.settle, value: card)
    }

    // MARK: 头部（图标 + 标题/副标题 + 状态胶囊）

    @ViewBuilder
    private var header: some View {
        let title = card.title ?? ""
        let subtitle = card.subtitle ?? ""
        if !title.isEmpty || !subtitle.isEmpty || card.status != nil {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: headerIcon)
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .symbolEffect(.bounce, value: card.status?.text ?? "")   // v3.9.0：结果状态更新弹一下
                    .foregroundStyle(toneColor(card.status?.tone))
                    .frame(width: 22, height: 22)
                    .background(toneColor(card.status?.tone).opacity(0.14), in: Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    if !title.isEmpty {
                        Text(title)
                            .font(.system(size: Typography.body, weight: .semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if let status = card.status, !status.text.isEmpty {
                    statusPill(status.text, tone: status.tone)
                }
            }
        }
    }

    private var headerIcon: String {
        switch card.kind {
        case .result:  return "sparkles"
        case .metrics: return "chart.bar.fill"
        case .list:    return "checklist"
        case .table:   return "tablecells"
        case .status:  return "dot.radiowaves.left.and.right"
        }
    }

    /// 状态胶囊（二元/状态控件统一 Capsule）：状态点 + 文案
    private func statusPill(_ text: String, tone: AgentCard.Tone?) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(toneColor(tone))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: Typography.tiny, weight: .medium))
                .foregroundStyle(toneColor(tone))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(toneColor(tone).opacity(0.12), in: Capsule())
    }

    // MARK: 指标（大号数值 + 单位）

    private var metricsSection: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(card.metrics.enumerated()), id: \.offset) { _, m in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(m.value)
                            .font(.system(size: Typography.title, weight: .semibold, design: .rounded))
                            .foregroundStyle(toneColor(m.tone))
                            .contentTransition(.numericText())   // 数值滚动而非硬跳
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let unit = m.unit, !unit.isEmpty {
                            Text(unit)
                                .font(.system(size: Typography.tiny))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !m.label.isEmpty {
                        Text(m.label)
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 键值行

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(card.fields.enumerated()), id: \.offset) { _, f in
                HStack(alignment: .top, spacing: 8) {
                    Text(f.key)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Text(f.value)
                        .font(.system(size: Typography.caption, weight: f.tone == nil ? .regular : .medium))
                        .foregroundStyle(f.tone == nil ? Color.primary : toneColor(f.tone))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: 清单（状态点 + 标题 + 副标题）

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(toneColor(item.tone))
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let sub = item.subtitle, !sub.isEmpty {
                            Text(sub)
                                .font(.system(size: Typography.tiny))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 6)
                    if let st = item.status, !st.isEmpty {
                        Text(st)
                            .font(.system(size: Typography.tiny, weight: .medium))
                            .foregroundStyle(toneColor(item.tone))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(toneColor(item.tone).opacity(0.12), in: Capsule())
                    }
                }
            }
        }
    }

    // MARK: 表格（与 MarkdownTableView 同族观感：表头加重 + 斑马纹 + 横向滚动）

    private func tableRows(_ table: AgentCard.Table) -> [[String]] {
        table.columns.isEmpty ? table.rows : [table.columns] + table.rows
    }

    private func toneColor(_ tone: AgentCard.Tone?) -> Color {
        switch tone ?? .info {
        case .ok:    return .green
        case .warn:  return .orange
        case .error: return .red
        case .info:  return .accentColor
        }
    }
}

// MARK: - 卡片内表格（独立小 View：避免与其他段挤在一个 body 里触发 type-check 超时）

private struct AgentCardTable: View {
    let rows: [[String]]

    private var colWidths: [CGFloat] {
        guard let first = rows.first else { return [] }
        return first.indices.map { c in
            let maxLen = rows.map { $0.indices.contains(c) ? $0[c].count : 0 }.max() ?? 0
            return max(52, min(CGFloat(maxLen) * 12 + 18, 140))
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(rows[r].indices, id: \.self) { c in
                            Text(rows[r][c])
                                .font(.system(size: Typography.caption, weight: r == 0 ? .semibold : .regular))
                                .foregroundStyle(r == 0 ? Color.primary : Color.secondary)
                                .lineLimit(2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(width: colWidths.indices.contains(c) ? colWidths[c] : 72, alignment: .leading)
                                .background(r == 0
                                            ? Color.accentColor.opacity(0.08)
                                            : (r % 2 == 0 ? Color.primary.opacity(0.03) : Color.clear))
                        }
                    }
                    if r < rows.count - 1 {
                        Divider().overlay(Color.primary.opacity(0.07))
                    }
                }
            }
        }
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
    }
}
