import SwiftUI
import UIKit

// MARK: - v3.7.0 生活页「备忘录」栏目
//
// 位置：生活页最上方（在「生活数据」之前）——随手记比行情资讯更高频。
// 交互：点 + 新增；点卡片放大看全文；长按卡片（或放大页内）删除。
// 数据：MemoStore（本地 + NAS 双写）。

struct MemoSection: View {
    @State private var store = MemoStore.shared
    @State private var showAdd = false
    @State private var draft = ""
    @State private var detail: MemoItem?
    @State private var pendingDelete: MemoItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if store.memos.isEmpty {
                emptyRow
            } else {
                ForEach(store.memos) { m in
                    memoRow(m)
                    if m.id != store.memos.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()   // v3.8.1：圆角与看板卡片统一（默认 16；原来这里是 10，生活页看着更"方"）
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
                Label("添加", systemImage: "plus")
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

    private var emptyRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: Typography.caption))
            Text("点右上角「添加」写一条备忘")
                .font(.system(size: Typography.subhead))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tertiary)
        .padding(.vertical, 2)
    }

    // MARK: 卡片

    @ViewBuilder
    private func memoRow(_ m: MemoItem) -> some View {
        Button {
            detail = m
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.content)
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(m.subtitle)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.quaternary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(PressStyle())
        .contextMenu {
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

// MARK: - 放大查看（点卡片进入）

private struct MemoDetailSheet: View {
    let item: MemoItem
    var onDelete: (MemoItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.content)
                        .font(.system(size: Typography.headline))
                        .lineSpacing(6)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.subtitle)
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.tertiary)
                }
                .padding(18)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("备忘录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        UIPasteboard.general.string = item.content
                        Haptics.success()
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel("复制内容")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(role: .destructive) {
                    onDelete(item)
                } label: {
                    Label("删除这条备忘", systemImage: "trash")
                        .font(.system(size: Typography.body))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.12), in: Capsule())
                }
                .buttonStyle(PressStyle())
                .foregroundStyle(.red)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }
        }
    }
}
