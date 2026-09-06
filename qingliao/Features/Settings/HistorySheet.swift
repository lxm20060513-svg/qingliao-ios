import SwiftUI

// MARK: - v2.0.116 执行历史（自动化 + 场景，设置页入口）
// v2.0.132：加管理功能——滑动单条删除 + 编辑模式多选删除 + 全部清除

struct HistorySheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var items: [HistoryItem] = []
    @State private var loaded = false
    @State private var editMode = EditMode.inactive
    @State private var selected = Set<String>()   // 多选删除（按 id）
    @State private var showClearConfirm = false   // 全部清除确认
    @State private var deleteError: String?   // v-review fix：滑动删除失败提示

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                        Text(loaded ? "暂无执行记录" : "加载中…")
                            .font(.system(size: 16, weight: .semibold))
                        if loaded {
                            Text("自动化或场景执行后会在这里留痕")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selected) {
                        ForEach(items) { h in
                            HStack(spacing: 12) {
                                Image(systemName: h.type == "自动化" ? "timer" : "sparkles")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(h.type == "自动化" ? Color.orange : Color.purple,
                                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(h.type)「\(h.name)」")
                                        .font(.system(size: 14, weight: .medium))
                                        .lineLimit(1)
                                    if !h.detail.isEmpty {
                                        Text(h.detail)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Text(h.ts)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.quaternary)
                                }
                                Spacer()
                                Image(systemName: h.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(h.ok ? .green : .red)
                            }
                            .padding(.vertical, 2)
                        }
                        // 编辑模式下不显示滑动删除（避免手势冲突）；非编辑模式每行左滑删除
                        .onDelete { offsets in
                            deleteRows(offsets)
                        }
                    }
                    .environment(\.editMode, $editMode)
                }
            }
            .navigationTitle("执行历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editMode == .active ? "完成" : "编辑") {
                        withAnimation {
                            if editMode == .active {
                                selected.removeAll()
                                editMode = .inactive
                            } else {
                                editMode = .active
                            }
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if editMode == .active {
                        // 编辑模式：全选 / 删除所选 / 全部清除
                        Menu {
                            Button {
                                selected = Set(items.map { $0.id })
                            } label: {
                                Label("全选", systemImage: "checkmark.circle")
                            }
                            Button(role: .destructive) {
                                deleteSelected()
                            } label: {
                                Label("删除所选（\(selected.count)）", systemImage: "trash")
                            }
                            .disabled(selected.isEmpty)
                            Button(role: .destructive) {
                                showClearConfirm = true
                            } label: {
                                Label("全部清除", systemImage: "trash.slash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    } else {
                        Button {
                            Task { await load() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .confirmationDialog("全部清除执行历史？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("全部清除", role: .destructive) {
                    Task {
                        if let j = try? await auth.json("/api/history", method: "DELETE"),
                           let list = j["history"] as? [[String: Any]] {
                            items = list.map { HistoryItem($0) }
                        }
                        selected.removeAll()
                        editMode = .inactive
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作不可恢复，确定删除全部执行记录？")
            }
            .task { await load() }
            // v-review fix：滑动删除失败提示
            .alert("删除失败", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("好的", role: .cancel) { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
        }
        .presentationDetents([.large])
    }

    private func load() async {
        if let j = try? await auth.json("/api/history") {
            items = (j["history"] as? [[String: Any]] ?? []).map { HistoryItem($0) }
        }
        loaded = true
    }

    /// 滑动单条删除（非编辑模式）——v-review fix：失败回滚（本地快照恢复）+ 提示，
    /// 与其余后端列表驱动的删除保持一致，不再静默吞错
    private func deleteRows(_ offsets: IndexSet) {
        let ids = offsets.map { items[$0].id }
        let snapshot = items
        items.remove(atOffsets: offsets)
        Task {
            do {
                let j = try await auth.json("/api/history?ids=\(ids.joined(separator: ","))", method: "DELETE")
                if let list = j["history"] as? [[String: Any]] {
                    items = list.map { HistoryItem($0) }
                }
            } catch {
                items = snapshot
                deleteError = "删除失败，已恢复列表"
            }
        }
    }

    /// 编辑模式批量删除所选
    private func deleteSelected() {
        let ids = Array(selected)
        items.removeAll { ids.contains($0.id) }
        selected.removeAll()
        Task {
            _ = try? await auth.json("/api/history?ids=\(ids.joined(separator: ","))", method: "DELETE")
        }
        if items.isEmpty { editMode = .inactive }
    }
}

struct HistoryItem: Identifiable {
    let id: String
    let ts: String
    let type: String
    let name: String
    let ok: Bool
    let detail: String
    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? UUID().uuidString
        ts = d["ts"] as? String ?? ""
        type = d["type"] as? String ?? ""
        name = d["name"] as? String ?? ""
        ok = (d["ok"] as? Bool) ?? false
        detail = d["detail"] as? String ?? ""
    }
}