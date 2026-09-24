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
            if planInteractive { planFooter }
            if let table = card.table { AgentCardTable(rows: tableRows(table)) }
            if let footer = card.footer, !footer.isEmpty {
                Text(footer)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        // v3.9.28：拿掉 glassCard（glassEffect 默认 Capsule 形状 = 大弧度圆角玻璃蒙版罩在卡上）
        // 改用全站卡片统一底：纯色底 + 0.8pt 描边 + 16pt 圆角，与看板卡同款
        .dashboardCard()
        // 流式闭合后由文本替换为卡片：轻微浮现，不抢打字机节奏
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
        .animation(Motion.settle, value: card)
        .onAppear(perform: syncProgressOnAppear)
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
        case .plan:    return "list.clipboard.fill"   // v3.9.58：任务计划卡（步骤完成度语义）
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
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(toneColor(tone).opacity(Tint.subtle), in: Capsule())
    }

    // MARK: 指标（大号数值 + 单位）

    private var metricsSection: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(card.metrics.enumerated()), id: \.offset) { _, m in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(m.value)
                            // v3.9.19：等宽数字——数值滚动时宽度不抖
                            .font(.system(size: Typography.title, weight: .semibold, design: .rounded).monospacedDigit())
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
        VStack(alignment: .leading, spacing: Spacing.xs) {
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

    // v3.9.74 P2.6：plan 卡步骤可勾选——点行切换完成态，进度本地持久化（PlanProgressStore）。
    // 勾选是纯本地行为（不回传 AI）；只有「继续下一步」按钮会作为用户消息发回聊天。
    // 非 plan 卡 / 未接回调（卡片画廊预览）保持只读展示，零回归。

    /// v3.9.74 P2.6：「继续下一步」回调——把下一个未完成步骤作为用户消息发回聊天。nil = 只读（画廊预览）
    var onContinueStep: ((String) -> Void)? = nil

    /// 本卡步骤勾选进度（进度持久化按卡片指纹隔离；勾选本身不回传 AI）
    @State private var completedSteps: Set<Int> = []
    @State private var progressFP: UInt64 = 0

    /// plan 卡且已接「继续下一步」回调 → 步骤可交互；否则维持 v3.9.58 起的只读展示
    private var planInteractive: Bool { card.kind == .plan && onContinueStep != nil }

    private var planFingerprint: UInt64 {
        PlanProgressStore.fingerprint(title: card.title ?? "", stepTitles: card.items.map(\.title))
    }

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(card.items.enumerated()), id: \.offset) { idx, item in
                stepRow(idx: idx, item: item)
            }
        }
    }

    /// v3.9.74 P2.6：单行步骤——plan 交互卡渲染勾选圈（点行切换），其余维持状态点
    @ViewBuilder
    private func stepRow(idx: Int, item: AgentCard.Item) -> some View {
        let done = planInteractive && completedSteps.contains(idx)
        let row = HStack(alignment: .top, spacing: 7) {
            if planInteractive {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(done ? Color.green : Color.secondary.opacity(0.6))
                    .frame(width: 18, alignment: .leading)
                    .padding(.top, 1)
            } else {
                Circle()
                    .fill(toneColor(item.tone))
                    .frame(width: 6, height: 6)
                    .padding(.top, Spacing.xs)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(item.title)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(done ? Color.secondary : Color.primary)
                    .strikethrough(done, color: .secondary)
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
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xxs)
                    .background(toneColor(item.tone).opacity(Tint.subtle), in: Capsule())
            }
        }
        if planInteractive {
            Button {
                toggleStep(idx)
            } label: {
                row
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            row
        }
    }

    private func toggleStep(_ idx: Int) {
        guard planInteractive else { return }
        if progressFP != planFingerprint {   // 卡片内容被 AI 重发覆盖 → 以磁盘进度为准重挂
            progressFP = planFingerprint
            completedSteps = PlanProgressStore.shared.completedIndexes(for: planFingerprint)
        }
        if completedSteps.contains(idx) {
            completedSteps.remove(idx)
        } else {
            completedSteps.insert(idx)
            Haptics.tap()   // 勾选完成给轻触感；取消勾选不打扰
        }
        PlanProgressStore.shared.setCompleted(completedSteps, for: planFingerprint)
    }

    /// v3.9.74 P2.6：plan 交互卡底部——进度文字 +「继续下一步」玻璃胶囊（沿用 v3.9.36 accent 玻璃口径）
    @ViewBuilder
    private var planFooter: some View {
        if planInteractive, !card.items.isEmpty {
            let doneCount = completedSteps.count
            // v3.9.74c：单一数据源用 @State completedSteps 推导 nextIdx——同指纹多卡实例时
            // 其它卡的勾选只写 Store 不刷新本卡 @State，直接读 Store 会出现按钮已切、勾选圈没动的不同步
            let nextIdx = card.items.indices.first { !completedSteps.contains($0) }
            HStack(spacing: Spacing.md) {
                Text(PlanProgressStore.progressText(done: doneCount, total: card.items.count))
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if let next = nextIdx {
                    Button {
                        Haptics.tap()
                        onContinueStep?(card.items[next].title)
                    } label: {
                        Text("继续：\(card.items[next].title)")
                            .font(.system(size: Typography.tiny, weight: .semibold))
                            .lineLimit(1)
                    }
                    .glassPillStroke()
                }
            }
        }
    }

    private func syncProgressOnAppear() {
        progressFP = planFingerprint
        completedSteps = PlanProgressStore.shared.completedIndexes(for: planFingerprint)
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
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, Spacing.xs)
                                .frame(width: colWidths.indices.contains(c) ? colWidths[c] : 72, alignment: .leading)
                                .background(r == 0
                                            ? Color.accentColor.opacity(Tint.faint)
                                            : (r % 2 == 0 ? Color.primary.opacity(Tint.faint) : Color.clear))
                        }
                    }
                    if r < rows.count - 1 {
                        Divider().overlay(Color.primary.opacity(Tint.faint))
                    }
                }
            }
        }
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.icon, style: .continuous)
                .strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8)
        )
    }
}
