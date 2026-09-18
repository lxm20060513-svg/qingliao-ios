// MARK: - v3.9.35 生活页「待办清单」栏目
// 风格与「备忘录」栏目完全同源：
//   · 页级标题行（粗体 15pt + 计数 + 右侧「添加」淡色胶囊）在卡片外
//   · 页面只放一张卡（`.dashboardCard()` 16 圆角 + 同高 83pt + 铺满），显示最上的一条
//   · 点卡片：1 条直达详情，≥2 条弹「全部待办」列表（半屏 sheet）
//   · 空态 = 可点引导卡（与备忘录空态同几何，空 ↔ 有内容不跳变）
// 功能：聊天长按「加入待办」/ AI 回复勾选框自动收录 / 手动添加 / 勾选完成 / 编辑 / 删除（左滑+长按）

import SwiftUI

struct TodoSection: View {
    @State private var store = TodoStore.shared
    @State private var showAdd = false
    @State private var showAll = false
    @State private var draft = ""
    @State private var detail: TodoItem?
    @State private var pendingDelete: TodoItem?
    @State private var editDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            pageHeader
            if store.todos.isEmpty {
                emptyTap
            } else {
                topCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await store.loadFromServer() }
        .sheet(isPresented: $showAdd) { addSheet }
        .sheet(isPresented: $showAll) { allSheet }
        .sheet(item: $detail, onDismiss: { detail = nil }) { t in
            detailSheet(t)
        }
        .alert("删除这条待办？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let item = pendingDelete { store.delete(item) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.content.prefix(40).description ?? "")
        }
    }

    // MARK: 页级标题行（与备忘录同款）

    private var pageHeader: some View {
        HStack(spacing: 8) {
            Text("待办清单")
                .font(.system(size: Typography.body, weight: .bold))
            if !store.todos.isEmpty {
                let pending = store.pendingCount
                Text(pending > 0 ? "\(pending) 项待办" : "已完成")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                draft = ""
                showAdd = true
            } label: {
                Text("添加").pill(.page)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("添加待办")
        }
        .padding(.top, Spacing.sm)
    }

    /// 空态引导卡（与备忘录空态同几何：16 圆角 + 83pt 高）
    private var emptyTap: some View {
        Button {
            draft = ""
            showAdd = true
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "checklist")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("有什么要做的")
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.primary)
                    Text("聊天长按加入待办，AI 给出的清单会自动收进来")
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

    // MARK: 页面单卡（显示列表最上的一条 = 未完成优先、最新在前）

    @ViewBuilder
    private var topCard: some View {
        if let top = store.sorted.first {
            Button {
                openCard()
            } label: {
                TodoRowCard(item: top, compact: true)
            }
            .buttonStyle(PressStyle())
            .contextMenu { todoMenuItems(top, onDelete: { pendingDelete = $0 }) }
            .accessibilityLabel(store.sorted.count == 1
                                ? "待办清单，1 项，点开查看"
                                : "待办清单，共 \(store.sorted.count) 项，点开查看全部")
        }
    }

    private func openCard() {
        if store.sorted.count == 1, let only = store.sorted.first {
            editDraft = only.content
            detail = only
        } else {
            showAll = true
        }
    }

    // MARK: 全部待办列表（半屏 sheet，左滑删除）

    private var allSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("全部待办")
                        .font(.system(size: Typography.title, weight: .semibold))
                    Text("\(store.pendingCount) 项待办")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    MiniCapsule(title: "完成", accent: true) { showAll = false }
                }
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.md)
                List {
                    ForEach(store.sorted) { t in
                        Button {
                            editDraft = t.content
                            showAll = false
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(500))
                                guard !showAll else { return }
                                detail = t
                            }
                        } label: {
                            TodoRowCard(item: t)
                        }
                        .buttonStyle(PressStyle())
                        .contextMenu { todoMenuItems(t, onDelete: { pendingDelete = $0 }) }
                    }
                    .onDelete { offsets in
                        let targets = offsets.map { store.sorted[$0] }
                        for t in targets { store.delete(t) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 详情 / 编辑（弹窗内，复用备忘录详情的「自绘顶栏」口径）

    private func detailSheet(_ t: TodoItem) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    MiniCapsule(title: "关闭") { detail = nil }
                    Spacer(minLength: 0)
                    Button {
                        store.toggleDone(t)
                        Haptics.success()
                    } label: {
                        MiniCapsule(title: t.done ? "标为待办" : "完成", accent: !t.done)
                    }
                    .buttonStyle(PressStyle())
                    MiniCapsule(title: "保存", accent: true) {
                        store.update(t, content: editDraft)
                        detail = nil
                    }
                    .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.sm)
                .overlay {
                    Text("待办")
                        .font(.system(size: Typography.headline, weight: .semibold))
                        .foregroundStyle(.primary)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $editDraft)
                    .font(.system(size: Typography.title))
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if editDraft.isEmpty {
                            Text("待办内容…")
                                .font(.system(size: Typography.title))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, Spacing.section)
                                .padding(.vertical, 20)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, Spacing.section)
                    .padding(.top, Spacing.md)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 长按菜单（页卡 / 列表共用）

    @ViewBuilder
    private func todoMenuItems(_ t: TodoItem, onDelete: @escaping (TodoItem) -> Void) -> some View {
        Button {
            store.toggleDone(t)
            Haptics.success()
        } label: {
            Label(t.done ? "标为待办" : "完成", systemImage: t.done ? "circle" : "checkmark.circle.fill")
        }
        Button {
            UIPasteboard.general.string = t.content
            Haptics.success()
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        Button(role: .destructive) {
            onDelete(t)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: 新增（与备忘录添加弹窗同款）

    private var addSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $draft)
                    .font(.system(size: Typography.title))
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("要做什么…")
                                .font(.system(size: Typography.title))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, Spacing.section)
                                .padding(.vertical, 20)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, Spacing.section)
                    .padding(.top, Spacing.md)
            }
            .navigationTitle("新建待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAdd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if store.add(content: draft, source: "manual") {
                            Haptics.success()
                        }
                        showAdd = false
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 自绘顶栏小胶囊（与 MemoSection.swift 内同名组件同款口径；各自 private 不冲突）

private struct MiniCapsule: View {
    let title: String
    var accent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .pill(.topBar, tone: accent ? .accent : .neutral)
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - 待办行卡（页级单卡 / 列表行两处共用，参数化差异走 compact）

private struct TodoRowCard: View {
    let item: TodoItem
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: Typography.body))
                .foregroundStyle(item.done ? Color.green : Color.secondary.opacity(0.5))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.content)
                    .font(.system(size: Typography.body))
                    .strikethrough(item.done, color: .secondary)
                    .foregroundStyle(item.done ? Color.secondary : Color.primary)
                    .lineLimit(compact ? MemoCardMetrics.lineLimit : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !compact {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: item.sourceIcon)
                            .font(.system(size: Typography.tiny))
                        Text(item.sourceLabel)
                            .font(.system(size: Typography.tiny))
                        Text("·")
                        Text(item.timeText)
                            .font(.system(size: Typography.tiny))
                    }
                    .foregroundStyle(.tertiary)
                }
            }
            if compact { Spacer(minLength: 0) }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity,
               minHeight: compact ? MemoCardMetrics.minHeight : 0,
               alignment: .topLeading)
        .dashboardCard()
        .contentShape(Rectangle())
    }
}
