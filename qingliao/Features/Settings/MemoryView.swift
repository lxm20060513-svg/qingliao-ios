import SwiftUI

// MARK: - v2.0.87 AI 记忆管理（记住用户偏好 → 对话自动参考）

struct MemoryView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [String] = []
    @State private var newText = ""
    @State private var message: (ok: Bool, text: String)?
    @State private var busy = false
    @State private var confirmDelete: String?   // v2.0.102：删除确认（记忆不可恢复）

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 添加区
                HStack(spacing: 8) {
                    TextField("如：我经常用 5G 网络 / 回答要简洁", text: $newText)
                        .font(.system(size: Typography.subhead))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        add()
                    } label: {
                        Text("记住")
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color.accentColor,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                .padding(12)

                if let m = message {
                    Text(m.text)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(m.ok ? Color.green : Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                }

                // 列表
                ScrollView {
                    VStack(spacing: 8) {
                        if entries.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: Typography.display))
                                    .foregroundStyle(.tertiary)
                                Text("还没有记忆条目")
                                    .font(.system(size: Typography.subhead))
                                    .foregroundStyle(.secondary)
                                Text("聊天时说「记住…」会自动保存，或手动添加")
                                    .font(.system(size: Typography.caption))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.top, 60)
                        } else {
                            ForEach(entries, id: \.self) { e in
                                HStack(spacing: 10) {
                                    Image(systemName: "brain.head.profile")
                                        .font(.system(size: Typography.body))
                                        .foregroundStyle(Color.accentColor)
                                    Text(e)
                                        .font(.system(size: Typography.subhead))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button {
                                        confirmDelete = e   // v2.0.102：先确认再删（记忆不可恢复）
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: Typography.subhead))
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(uiColor: .secondarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }
            }
            .navigationTitle("AI 记忆")
            .navigationBarTitleDisplayMode(.inline)
            // v2.0.102：删除确认（记忆不可恢复）
            .confirmationDialog("删除这条记忆？", isPresented: Binding(get: { confirmDelete != nil },
                                                                      set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let e = confirmDelete {
                        Task { await remove(e) }
                    }
                    confirmDelete = nil
                }
                Button("取消", role: .cancel) { confirmDelete = nil }
            } message: {
                Text("将删除「\(confirmDelete ?? "")」，此操作不可恢复")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        if let j = try? await auth.json("/api/memory/list") {
            entries = j["entries"] as? [String] ?? []
        }
    }

    private func add() {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            if let j = try? await auth.json("/api/memory/add", method: "POST", body: ["text": t]) {
                let ok = (j["ok"] as? Bool) ?? false
                message = (ok, j["message"] as? String ?? (ok ? "已记住" : "保存失败"))
                entries = j["entries"] as? [String] ?? entries
                if ok { newText = "" }
            } else {
                message = (false, "请求失败")
            }
        }
    }

    private func remove(_ text: String) async {
        if let j = try? await auth.json("/api/memory/delete", method: "POST", body: ["text": text]) {
            entries = j["entries"] as? [String] ?? entries
        }
    }
}
