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
    /// v3.9.37：卡片 → 「全部待办」列表的原生 zoom 转场（与备忘录卡片同款弹窗动画）
    @Namespace private var todoZoomNS
    @State private var draft = ""
    @State private var detail: TodoItem?
    /// v3.9.41（SR34）：详情页**实际渲染**用的副本；`detail` 只负责驱动呈现（一旦被 sheet 取用，
    /// 传进闭包的就是那一刻的快照，之后 store 改了它也不会跟着变 → 大勾选圆点了没反应）。
    /// 每次写库后由 `refreshDetail()` 回灌这一份，呈现期间不再动 `detail`（换值可能触发重呈现）。
    @State private var detailCurrent: TodoItem?
    @State private var pendingDelete: TodoItem?
    @State private var editDraft = ""
    /// v3.9.35b：详情页编辑态标志（查看=待办风格大卡；编辑=TextEditor）
    @State private var detailEditing = false

    var body: some View {
        root
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { await store.loadFromServer() }
            .sheet(isPresented: $showAdd) { addSheet }
            // SR35：「全部待办」弹窗里长按/左滑的删除确认，必须挂在弹窗自己这棵树上
            .sheet(isPresented: $showAll) { deleteConfirm(on: allSheet) }
            .sheet(item: $detail, onDismiss: { detail = nil; detailCurrent = nil }) { t in
                detailSheet(detailCurrent ?? t)
            }
    }

    /// 页面主体：确认框挂在这——页卡（无弹窗在前）长按删除时生效的就是这一份
    private var root: some View {
        deleteConfirm(on:
            VStack(alignment: .leading, spacing: 8) {
                pageHeader
                if store.todos.isEmpty {
                    emptyTap
                } else {
                    topCard
                }
            }
        )
    }

    /// v3.9.41（SR35）：删除确认框本体，宿主与「全部待办」弹窗各挂一次。
    /// 原先只有宿主那一份（旧 :40），而弹窗盖在宿主之上时宿主级 alert 呈现不出来 →
    /// 列表里长按「删除」= 点了没反应。备忘录的 MemoSection 早已把确认框搬进弹窗内，待办漏抄。
    @ViewBuilder
    private func deleteConfirm<V: View>(on view: V) -> some View {
        view.alert("删除这条待办？", isPresented: Binding(
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
            // v3.9.37：卡片即 zoom 源（≥2 项点开「全部待办」时从这张卡放大展开，对齐备忘录卡片）
            .matchedTransitionSource(id: "todo-all", in: todoZoomNS)
            .accessibilityLabel(store.sorted.count == 1
                                ? "待办清单，1 项，点开查看"
                                : "待办清单，共 \(store.sorted.count) 项，点开查看全部")
        }
    }

    private func openCard() {
        if store.sorted.count == 1, let only = store.sorted.first {
            editDraft = only.content
            detailEditing = false
            detailCurrent = only
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
                            detailEditing = false
                            showAll = false
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(500))
                                guard !showAll else { return }
                                // SR34：以 store 里的当前那条为准（这 500ms 内可能刚刷过一遍）
                                detailCurrent = store.todos.first { $0.id == t.id } ?? t
                                detail = t
                            }
                        } label: {
                            TodoRowCard(item: t)
                        }
                        .buttonStyle(PressStyle())
                        .contextMenu { todoMenuItems(t, onDelete: { pendingDelete = $0 }) }
                        // v3.9.38：行容器口径与「全部备忘」逐项一致（卡片几何 + 无分隔线 + 透明行底）——
                        // zoom 转场是「从卡片放大」，落点行必须与源卡片同宽同位，否则观感与备忘录弹窗不同
                        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.section,
                                                  bottom: 8, trailing: Spacing.section))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .onDelete { offsets in
                        // v3.9.41（SR35）：左滑原先零确认直接删 + 整档回写 NAS（长按那条路有确认，
                        // 左滑漏了）。单行走同一个确认框；一次多行（批量手势，极少见）逐条弹框
                        // 不现实，保持直接删。
                        guard offsets.count == 1, let idx = offsets.first else {
                            let targets = offsets.map { store.sorted[$0] }
                            for t in targets { store.delete(t) }
                            return
                        }
                        pendingDelete = store.sorted[idx]
                    }
                    // v3.9.38：与「全部备忘」同款空态占位（列表打开期间被删空不剩空白面板）
                    if store.sorted.isEmpty {
                        Text("还没有待办")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 20)
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
        .navigationTransition(.zoom(sourceID: "todo-all", in: todoZoomNS))   // v3.9.37：从待办卡片放大展开（对齐备忘录）
    }

    // MARK: 详情 / 编辑
    // v3.9.35b：详情用「待办」的 UI 风格（系统提醒事项式）——大勾选圆 + 完成态划线压灰 + 来源/时间
    // 元信息行；编辑态才切 TextEditor。顶栏沿用备忘录详情的自绘小胶囊口径。

    /// v3.9.41（SR34）：把 store 里最新的那条回灌给详情页副本（见 `detailCurrent`）。
    private func refreshDetail() {
        guard let cur = detailCurrent ?? detail,
              let idx = store.todos.firstIndex(where: { $0.id == cur.id }) else { return }
        detailCurrent = store.todos[idx]
    }

    private func detailSheet(_ t: TodoItem) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    MiniCapsule(title: "关闭") {
                        detailEditing = false
                        detail = nil
                    }
                    Spacer(minLength: 0)
                    if detailEditing {
                        MiniCapsule(title: "保存", accent: true) {
                            store.update(t, content: editDraft)
                            refreshDetail()   // SR34：正文改了要让本页立刻显示
                            detailEditing = false
                        }
                        .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        MiniCapsule(title: "编辑") {
                            editDraft = t.content
                            detailEditing = true
                        }
                    }
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

                if detailEditing {
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
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            // 大勾选圆 + 内容：整卡可点切换完成态（待办的核心交互前置到详情）
                            Button {
                                store.toggleDone(t)
                                refreshDetail()   // SR34：勾选态必须立刻反映在本页
                                Haptics.success()
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 26, weight: .medium))
                                        .foregroundStyle(t.done ? Color.green : Color.secondary.opacity(0.4))
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(t.content)
                                            .font(.system(size: Typography.headline))
                                            .lineSpacing(LineSpacing.long)
                                            .strikethrough(t.done, color: .secondary)
                                            .foregroundStyle(t.done ? Color.secondary : Color.primary)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        HStack(spacing: Spacing.xs) {
                                            Image(systemName: t.sourceIcon)
                                                .font(.system(size: Typography.tiny))
                                            Text(t.sourceLabel)
                                                .font(.system(size: Typography.tiny))
                                            Text("·")
                                            Text(t.timeText)
                                                .font(.system(size: Typography.tiny))
                                        }
                                        .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(Spacing.xl)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .dashboardCard()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressStyle())
                            // 完成态底部一句轻提示（未完成时占住同位置不显示）
                            if t.done {
                                Text("已完成 · 从列表长按或点这里可改回待办")
                                    .font(.system(size: Typography.caption))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // 编辑态禁止下滑关闭：不然手一滑草稿就没了（对齐备忘录详情同款护栏）
            .interactiveDismissDisabled(detailEditing)
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
