import SwiftUI

// MARK: - v2.0.113 Agent 记忆管理（弹窗，同 AI 记忆样式）

struct AgentMemorySheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [AgentRuleItem] = []

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
                                    Button {
                                        Task { await remove(r) }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: Typography.title))
                                            .foregroundStyle(.red.opacity(0.8))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 2)
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
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        if let j = try? await auth.json("/api/agent/rules") {
            rules = (j["rules"] as? [[String: Any]] ?? []).map { AgentRuleItem($0) }
        }
    }

    private func remove(_ r: AgentRuleItem) async {
        let enc = r.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? r.id
        if let j = try? await auth.json("/api/agent/rules?id=\(enc)", method: "DELETE", body: nil) {
            rules = (j["rules"] as? [[String: Any]] ?? []).map { AgentRuleItem($0) }
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
