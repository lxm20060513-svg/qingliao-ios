import SwiftUI

// MARK: - v3.9.71 记录分区（生活页，与「待办清单」并列）
//
// 定位：意图管道里数字类内容（金额 / 表读数）的落点，也是「随手记一笔」的手动入口。
// 视觉口径照抄 TodoSection：页级标题行（标题 + 副标题 + 添加 pill）+ 单张 dashboardCard 页卡 + 空态同几何。
// 生命周期照抄：`.task { await store.loadFromServer() }` —— 只跑一次，不做轮询（记录不需要 30s 刷新）。

struct RecordSection: View {
    @State private var store = RecordStore.shared
    @State private var showAdd = false
    @State private var showAll = false
    @State private var draftTitle = ""
    @State private var draftAmount = ""
    @State private var draftUnit = "元"
    @State private var pendingDelete: RecordItem?

    private let units = ["元", "度", "kWh"]

    var body: some View {
        root
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { await store.loadFromServer() }
            .sheet(isPresented: $showAdd) { addSheet }
            // 删除确认框必须挂在弹窗自己这棵树上（SR35：宿主级 alert 在弹窗之上呈现不出来）
            .sheet(isPresented: $showAll) { deleteConfirm(on: allSheet) }
    }

    private var root: some View {
        deleteConfirm(on:
            VStack(alignment: .leading, spacing: 8) {
                pageHeader
                if store.records.isEmpty {
                    emptyTap
                } else {
                    topCard
                }
            }
        )
    }

    private func deleteConfirm<V: View>(on view: V) -> some View {
        view.alert("删除这条记录？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let item = pendingDelete { store.delete(item) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.amountText ?? "")
        }
    }

    // MARK: 页级标题行（与备忘录/待办同款）

    private var pageHeader: some View {
        HStack(spacing: 8) {
            Text("记录")
                .font(.system(size: Typography.body, weight: .bold))
            if !store.records.isEmpty {
                Text(subtitleText)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                resetDraft()
                showAdd = true
            } label: {
                Text("添加").pill(.page)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("添加记录")
        }
        .padding(.top, Spacing.sm)
    }

    private var subtitleText: String {
        let t = store.monthTotal
        guard t.count > 0 else { return "\(store.records.count) 条" }
        return String(format: "本月 %.2f 元 · %d 条", t.amount, t.count)
    }

    // MARK: 空态引导卡（与待办空态同几何）

    private var emptyTap: some View {
        Button {
            resetDraft()
            showAdd = true
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "sum")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("随手记一笔")
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.primary)
                    Text("复制金额或电表读数，AI 会自动认出来并落到这里")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, minHeight: MemoCardMetrics.minHeight, alignment: .leading)
            .dashboardCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    // MARK: 单张页卡（本月合计 + 最近读数 + 最近 3 条）

    private var topCard: some View {
        Button {
            showAll = true
        } label: {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("本月合计")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(String(format: "%.2f 元", store.monthTotal.amount))
                        .font(.system(size: Typography.title, weight: .semibold))
                        .monospacedDigit()
                }
                if let meter = store.latestMeter, let v = meter.amount {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.tertiary)
                        Text("最近读数 \(RecordKit.amountText(v, unit: meter.unit))")
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                Divider().opacity(0.4)
                ForEach(Array(store.sorted.prefix(3))) { r in
                    HStack(spacing: 8) {
                        Text(r.title)
                            .font(.system(size: Typography.subhead))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(r.amountText)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if store.records.count > 3 {
                    Text("还有 \(store.records.count - 3) 条")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, minHeight: MemoCardMetrics.minHeight, alignment: .leading)
            .dashboardCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .contextMenu {
            if let top = store.sorted.first {
                Button(role: .destructive) { pendingDelete = top } label: {
                    Label("删除最新一条", systemImage: "trash")
                }
            }
            Button { resetDraft(); showAdd = true } label: {
                Label("添加记录", systemImage: "plus")
            }
        }
        .accessibilityLabel("记录，本月合计 \(String(format: "%.2f", store.monthTotal.amount)) 元，\(store.records.count) 条，点开查看全部")
    }

    // MARK: 全部记录（半屏 sheet，左滑删）

    private var allSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("全部记录")
                        .font(.system(size: Typography.title, weight: .semibold))
                    Text(subtitleText)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    MiniCapsule(title: "完成", accent: true) { showAll = false }
                }
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.md)
                List {
                    ForEach(store.sorted) { r in
                        RecordRowCard(item: r)
                            .contextMenu {
                                Button(role: .destructive) { pendingDelete = r } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.section,
                                                      bottom: 8, trailing: Spacing.section))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onDelete { offsets in
                        // 单行删走确认框；批量手势（极少见）直接删
                        guard offsets.count == 1, let idx = offsets.first else {
                            for r in offsets.map({ store.sorted[$0] }) { store.delete(r) }
                            return
                        }
                        pendingDelete = store.sorted[idx]
                    }
                    if store.sorted.isEmpty {
                        Text("还没有记录")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, Spacing.xxl)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 新建（外壳照抄待办新建：取消/保存 toolbar + medium/large）

    private var addSheet: some View {
        NavigationStack {
            VStack(spacing: Spacing.md) {
                TextField("名称（如 超市 / 电表）", text: $draftTitle)
                    .font(.system(size: Typography.title))
                    .padding(Spacing.xl)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))

                HStack(spacing: Spacing.md) {
                    TextField("数值", text: $draftAmount)
                        .font(.system(size: Typography.title))
                        .keyboardType(.decimalPad)
                        .padding(Spacing.xl)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    Picker("单位", selection: $draftUnit) {
                        ForEach(units, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.md)
            .navigationTitle("新建记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAdd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveDraft()
                    }
                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 动作

    private func resetDraft() {
        draftTitle = ""
        draftAmount = ""
        draftUnit = "元"
    }

    private func saveDraft() {
        let value = Double(draftAmount.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces))
        let item = store.add(kind: value == nil ? "note" : (draftUnit == "元" ? "amount" : "meter"),
                             title: draftTitle, amount: value, unit: value == nil ? "" : draftUnit,
                             source: "manual")
        if item != nil { Haptics.success() }
        showAdd = false
    }
}

/// 记录行卡（与 TodoRowCard 同款几何）
private struct RecordRowCard: View {
    let item: RecordItem

    var body: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(MemoItem.relativeTime(item.updatedAt))
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Text(item.amountText)
                .font(.system(size: Typography.body, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
        .contentShape(Rectangle())
    }
}
