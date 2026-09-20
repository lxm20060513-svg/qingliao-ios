import SwiftUI

// MARK: - v2.0.113 Agent 记忆管理（弹窗，同 AI 记忆样式）

struct AgentMemorySheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [AgentRuleItem] = []
    // v3.9.40（#19）：editing 非空即编辑弹窗打开（存的是被改的那条，用于比对与回传 id）
    @State private var editing: AgentRuleItem?
    @State private var editText = ""
    // v3.9.41（SR24）：整页原先没有任何错误出口——删除/编辑失败时列表不动，用户以为成功
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            Group {
                if rules.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                        Text("暂无 Agent 记忆")
                            .font(.system(size: Typography.title, weight: .semibold))
                        Text("聊天时说「以后查内存都用agent」\n会自动记住，同类请求直接走 Agent 处理")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(rules) { r in
                                HStack(spacing: 10) {
                                    Image(systemName: "brain.head.profile")
                                        .font(.system(size: Typography.body))
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("以后「\(r.pattern)」都用 Agent")
                                            .font(.system(size: Typography.body, weight: .medium))
                                        Text("记住于 \(r.created)")
                                            .font(.system(size: Typography.caption))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    // v3.9.40（#19）：就地编辑规则关键词（原只能删了重说）
                                    Button {
                                        editText = r.pattern
                                        editing = r
                                    } label: {
                                        Image(systemName: "pencil")
                                            .font(.system(size: Typography.body))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .accessibilityLabel("编辑这条记忆")
                                    .buttonStyle(.plain)
                                    Button {
                                        Task { await remove(r) }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: Typography.title))
                                            .foregroundStyle(.red.opacity(0.8))
                                    }
                                    .accessibilityLabel("删除这条记忆")
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, Spacing.xxs)
                            }
                        } header: {
                            Text("命中规则的请求将强制走 Agent 智能回复（工具调用）")
                        }
                    }
                }
            }
            .navigationTitle("Agent 记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
            // v3.9.40（#19）：就地编辑关键词
            .alert("编辑这条 Agent 记忆", isPresented: Binding(get: { editing != nil },
                                                              set: { if !$0 { editing = nil } })) {
                TextField("关键词（2-40 字）", text: $editText)
                Button("保存") {
                    if let r = editing { Task { await update(r) } }
                    editing = nil
                }
                Button("取消", role: .cancel) { editing = nil }
            } message: {
                Text("命中「\(editText)」的请求将强制走 Agent 处理")
            }
        }
        .presentationDetents([.medium, .large])
        // v3.9.41（SR24）：错误出口（挂在最外层，与 #19 的编辑 alert 不同层级不互斥）
        .alert("操作失败", isPresented: Binding(get: { errorMsg != nil },
                                                set: { if !$0 { errorMsg = nil } })) {
            Button("好", role: .cancel) { errorMsg = nil }
        } message: {
            Text(errorMsg ?? "")
        }
    }

    private func load() async {
        if let j = try? await auth.json("/api/agent/rules") {
            rules = (j["rules"] as? [[String: Any]] ?? []).map { AgentRuleItem($0) }
        }
    }

    private func remove(_ r: AgentRuleItem) async {
        let enc = r.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? r.id
        guard let j = try? await auth.json("/api/agent/rules?id=\(enc)", method: "DELETE", body: nil) else {
            errorMsg = "删除失败：网络异常或服务器报错"
            return
        }
        let ok = (j["ok"] as? Bool) ?? false
        guard ok else {
            errorMsg = j["message"] as? String ?? j["error"] as? String ?? "删除失败"
            return
        }
        // 只在响应真带 rules 时覆盖：出错响应（只有 error 键）会让列表假性清空
        if let arr = j["rules"] as? [[String: Any]] {
            rules = arr.map { AgentRuleItem($0) }
        }
    }

    /// v3.9.40（#19）：改关键词——POST 带 id 即更新（见 agent_api.py 同一分支）
    private func update(_ r: AgentRuleItem) async {
        let t = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t != r.pattern else { return }
        guard let j = try? await auth.json("/api/agent/rules", method: "POST",
                                           body: ["id": r.id, "pattern": t]) else {
            errorMsg = "保存失败：网络异常或服务器报错"
            return
        }
        let ok = (j["ok"] as? Bool) ?? false
        guard ok else {
            errorMsg = j["message"] as? String ?? j["error"] as? String ?? "保存失败"
            return
        }
        if let arr = j["rules"] as? [[String: Any]] {
            rules = arr.map { AgentRuleItem($0) }
        }
    }
}

struct AgentRuleItem: Identifiable {
    let id: String
    let pattern: String
    let created: String
    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? UUID().uuidString
        pattern = d["pattern"] as? String ?? ""
        created = d["created"] as? String ?? ""
    }
}
