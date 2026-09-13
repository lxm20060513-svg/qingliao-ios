// MARK: - v3.7.0 生活页「备忘录」栏目
// v3.9.14：体验升级——便签化卡片 / 置顶 / 相对时间 / 来源图标 / 折叠 / 可编辑 / 一键发给 AI
import SwiftUI

struct MemoSection: View {
    @State private var store = MemoStore.shared
    @State private var showAdd = false
    @State private var draft = ""
    @State private var detail: MemoItem?
    @State private var pendingDelete: MemoItem?
    /// v3.9.14：折叠——这张卡在生活页里，备忘一多会把别的栏目整屏挤下去
    @State private var expanded = false

    private let collapsedCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if store.memos.isEmpty {
                emptyTap
            } else {
                ForEach(visibleMemos) { m in
                    memoRow(m)
                }
                if store.sorted.count > collapsedCount {
                    expandToggle
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()   // v3.8.1：圆角与看板卡片统一（默认 16）
        // v3.7.0：进入生活页即拉 NAS 上的备忘（本地已有则远端为空时不清本地）
        .task { await store.loadFromServer() }
        .sheet(isPresented: $showAdd) { addSheet }
        .sheet(item: $detail) { m in
            MemoDetailSheet(item: m, onDelete: { item in
                detail = nil
                // 等 detail sheet 完全 dismiss 再弹确认框（同一帧里同时 present 会丢弹窗）
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    pendingDelete = item
                }
            })
            .presentationDetents([.medium, .large])
        }
        .alert("删除这条备忘？", isPresented: Binding(
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

    /// v3.9.14：列表顺序 = 置顶优先、再按最后修改时间倒序（读 store.sorted，不是 memos 的插入序）
    private var visibleMemos: [MemoItem] {
        let all = store.sorted
        return expanded ? all : Array(all.prefix(collapsedCount))
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("备忘录")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            if !store.memos.isEmpty {
                Text("\(store.memos.count)")
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
            }
            Spacer(minLength: 0)
            Button {
                draft = ""
                showAdd = true
            } label: {
                // v3.9.4：只留文字 + 胶囊（去图标）
                Text("添加")
                    .font(.system(size: Typography.caption))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("添加备忘录")
        }
    }

    /// v3.9.14：空态改成"可点的引导卡"——原来那句话是说明书腔，现在点了就能写
    private var emptyTap: some View {
        Button {
            draft = ""
            showAdd = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("记点什么")
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.primary)
                    Text("聊天里长按消息、大爆炸选词，都能存进来")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    // MARK: 便签卡

    @ViewBuilder
    private func memoRow(_ m: MemoItem) -> some View {
        Button {
            detail = m
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(m.content)
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    if m.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(Color.accentColor)
                    }
                    // v3.9.14：来源用图标代替文字（省一行宽度，一眼看出从哪来的）
                    Image(systemName: m.sourceIcon)
                        .font(.system(size: Typography.tiny))
                    Text(m.timeText)
                        .font(.system(size: Typography.caption))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            // v3.9.14：便签化——圆角底 + 0.8pt 描边（与全站卡片口径一致），置顶的用主题色淡底区分
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(m.pinned ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(m.pinned ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.16),
                        lineWidth: 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .contextMenu {
            Button {
                store.togglePin(m)
                Haptics.success()
            } label: {
                Label(m.pinned ? "取消置顶" : "置顶", systemImage: m.pinned ? "pin.slash" : "pin")
            }
            Button {
                sendToAI(m)
            } label: {
                Label("发给 AI", systemImage: "paperplane")
            }
            Button {
                UIPasteboard.general.string = m.content
                Haptics.success()
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                pendingDelete = m
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var expandToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.22)) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(expanded ? "收起" : "全部 \(store.sorted.count) 条")
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
            }
            .font(.system(size: Typography.caption))
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    /// v3.9.14：把备忘内容作为一条用户消息发给 AI，并切回聊天页。
    /// 备忘存下来只能复制粘贴没意义——能直接接着办才是轻聊备忘录区别于系统备忘录的地方。
    private func sendToAI(_ m: MemoItem) {
        NotificationCenter.default.post(name: .qingliaoMemoSend, object: m.content)
        Haptics.success()
    }

    // MARK: 新增

    private var addSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $draft)
                    .font(.system(size: Typography.title))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("写点什么…")
                                .font(.system(size: Typography.title))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 17)
                                .padding(.vertical, 20)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("新建备忘")
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

// MARK: - 放大查看 / 编辑（点卡片进入）

private struct MemoDetailSheet: View {
    let item: MemoItem
    var onDelete: (MemoItem) -> Void

    @Environment(\.dismiss) private var dismiss
    /// v3.9.14：本地副本——编辑/置顶后要立刻反映在本页（item 是传值进来的）
    @State private var current: MemoItem
    @State private var editing = false
    @State private var editText = ""
    @State private var copied = false

    init(item: MemoItem, onDelete: @escaping (MemoItem) -> Void) {
        self.item = item
        self.onDelete = onDelete
        _current = State(initialValue: item)
    }

    private var store = MemoStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if editing {
                        // v3.9.14：补上编辑（MemoStore.update 早就写好了，一直没入口）
                        TextEditor(text: $editText)
                            .font(.system(size: Typography.body))
                            .lineSpacing(6)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220, alignment: .topLeading)
                            .padding(10)
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        Text(current.content)
                            .font(.system(size: Typography.headline))
                            .lineSpacing(6)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 6) {
                        if current.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: Typography.tiny))
                                .foregroundStyle(Color.accentColor)
                        }
                        Image(systemName: current.sourceIcon)
                            .font(.system(size: Typography.tiny))
                        Text("\(current.sourceLabel) · \(current.subtitle)")
                            .font(.system(size: Typography.subhead))
                    }
                    .foregroundStyle(.tertiary)
                }
                .padding(18)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(editing ? "编辑备忘" : "备忘录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if editing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { editing = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { saveEdit() }
                            .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .confirmationAction) {
                        Button {
                            editText = current.content
                            editing = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("编辑")
                        Button {
                            UIPasteboard.general.string = current.content
                            Haptics.success()
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .accessibilityLabel("复制内容")
                    }
                }
            }
            // 编辑态下藏底部操作条，免得"删除"和"保存"挨着误触
            .safeAreaInset(edge: .bottom) {
                if !editing {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Button {
                                store.togglePin(current)
                                current.pinned.toggle()
                                Haptics.success()
                            } label: {
                                Label(current.pinned ? "取消置顶" : "置顶",
                                      systemImage: current.pinned ? "pin.slash" : "pin")
                                    .font(.system(size: Typography.body))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(PressStyle())
                            .foregroundStyle(Color.accentColor)

                            Button {
                                NotificationCenter.default.post(name: .qingliaoMemoSend, object: current.content)
                                Haptics.success()
                                dismiss()
                            } label: {
                                Label("发给 AI", systemImage: "paperplane")
                                    .font(.system(size: Typography.body))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(PressStyle())
                            .foregroundStyle(Color.accentColor)
                        }
                        Button(role: .destructive) {
                            onDelete(current)
                        } label: {
                            Label("删除这条备忘", systemImage: "trash")
                                .font(.system(size: Typography.body))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.red.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(PressStyle())
                        .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private func saveEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.update(current, content: text)
        current.content = text
        current.updatedAt = Date()
        editing = false
        Haptics.success()
    }
}
