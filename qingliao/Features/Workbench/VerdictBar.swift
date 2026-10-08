import SwiftUI

// MARK: - P1 首屏结论条
//
// 位置：挂在工作模式壳 `WorkbenchRoot` 的顶部（`.safeAreaInset(edge: .top)`）。
// 为什么挂在壳上而不是某个页面里：P2 之前「工作模式到底改了什么」只该落在一个文件里
// （`Core/UIModeRoot.swift`），回退是一行的事；P2 做「一页一职」时再把这条搬进会话页顶部。
// 生活模式那条路径一个字都不动 —— 本文件只在工作模式壳里被引用。
//
// 一条三格 + 一句附件说明：待你处理 · 目标今日步 · 昨夜任务。
// 数字怎么算、什么时候该说人话而不是数字，全在纯逻辑 `Core/WorkbenchVerdict.swift`（有真值表盯着）；
// 本文件只负责画和点。

struct VerdictBar: View {
    @Environment(AuthStore.self) private var auth
    @State private var store = WorkbenchVerdictStore.shared
    @State private var drill: WorkbenchVerdict.Drill?

    var body: some View {
        VStack(spacing: Spacing.sm) {
            chipsRow
            hintRow
            stallRow
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(Tint.faint))
                .frame(height: 0.5)
        }
        .task { await store.refresh(auth: auth) }
        .onChange(of: drill) { _, target in
            // 从下钻页回来时重取一次：用户可能刚在里面把待办清了 / 勾了步骤
            if target == nil { Task { await store.refresh(auth: auth) } }
        }
        .sheet(item: $drill) { target in
            drillSheet(target)
        }
    }

    // MARK: - 三格

    private var chips: [WorkbenchVerdict.Chip] { WorkbenchVerdict.chips(store.state) }

    @ViewBuilder private var chipsRow: some View {
        if !chips.isEmpty {
            HStack(spacing: Spacing.sm) {
                ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(Tint.faint))
                            .frame(width: 0.5, height: 20)
                    }
                    chipButton(chip)
                }
            }
        }
    }

    private func chipButton(_ chip: WorkbenchVerdict.Chip) -> some View {
        Button {
            drill = WorkbenchVerdict.drill(chip.slot)
        } label: {
            VStack(spacing: 2) {
                Text(chip.value)
                    .font(.subheadline.weight(chip.hasNumber ? .semibold : .regular))
                    .foregroundStyle(chip.warn ? Color.orange
                                               : (chip.hasNumber ? Color.primary : Color.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(chip.slot.label)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(chip.slot.label) \(chip.value)")
    }

    // MARK: - 附件说明（加载中 / 空态 / 断网态都靠它，绝不出现「0」或「--」）

    @ViewBuilder private var hintRow: some View {
        if let hint = WorkbenchVerdict.hint(store.state) {
            HStack(spacing: Spacing.sm) {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.sm)
                if let title = WorkbenchVerdict.actionTitle(store.state) {
                    Button(title) { runAction(title) }
                        .font(.footnote.weight(.medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    /// P3-13：目标停滞告警 —— 只在真有停滞目标时多出这一行（没有时整行不存在，首屏与 P1 逐字一致）。
    /// 文案/阈值都在 `WorkbenchInsight`，生活模式它回 nil；点一下去生活页处理。
    @ViewBuilder private var stallRow: some View {
        if let text = WorkbenchInsight.stallHint(store.stalledGoalCount) {
            Button {
                QingliaoRouteHandoff.request(.life)
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.sm)
                    Text("去看看")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func runAction(_ title: String) {
        if title == WorkbenchVerdict.retryAction {
            Task { await store.refresh(auth: auth) }
        } else {
            // 「说一句话就能开始」= 切到会话页（进程内投递，和灵岛/快捷指令同一条通道）
            QingliaoRouteHandoff.request(.chat)
        }
    }

    // MARK: - 下钻

    @ViewBuilder private func drillSheet(_ target: WorkbenchVerdict.Drill) -> some View {
        switch target {
        case .pendingList:
            TaskCenterView()
        case .todayStepList:
            VerdictStepsSheet(steps: store.todaySteps)
        case .nightList:
            VerdictNightSheet(items: store.nightItems,
                              offline: WorkbenchVerdict.isOffline(store.state))
        }
    }
}

// MARK: - 下钻① 今日推进（今天勾掉的步骤）

struct VerdictStepsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let steps: [WorkbenchVerdictStore.TodayStep]

    var body: some View {
        NavigationStack {
            Group {
                if steps.isEmpty {
                    VerdictEmptyNote(text: "今天还没有勾掉的步骤。目标推进到哪一步，这里就会多一条。")
                } else {
                    List(steps) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.step).font(.subheadline)
                            Text("\(s.goal) · \(VerdictBarFormat.time(s.at))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(WorkbenchVerdict.Drill.todayStepList.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 下钻③ 昨夜任务

struct VerdictNightSheet: View {
    @Environment(\.dismiss) private var dismiss
    let items: [WorkbenchVerdict.NightTask]
    let offline: Bool

    var body: some View {
        NavigationStack {
            Group {
                if offline {
                    VerdictEmptyNote(text: WorkbenchVerdict.offlineHint)
                } else if items.isEmpty {
                    VerdictEmptyNote(text: "昨晚后台没有跑过任务。")
                } else {
                    List(items) { t in
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: t.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(t.failed ? Color.orange : Color.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.subheadline).lineLimit(2)
                                Text(VerdictBarFormat.time(t.at))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                // P3-15：失败原因下钻 —— 后端把留档 `## Error` 段洗成一行随明细下发；
                                // 老后端/留档里没有 Error 段 → nil，这行整体不存在（不写「未知错误」充数）。
                                if let why = WorkbenchInsight.failureReason(t.reason) {
                                    Text(why)
                                        .font(.caption)
                                        .foregroundStyle(Color.orange)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(WorkbenchVerdict.Drill.nightList.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 空态一句话（三个下钻共用的兜底样式）

struct VerdictEmptyNote: View {
    let text: String

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 时间显示（只给时分；跨天信息由所在分区标题承担）

enum VerdictBarFormat {
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
