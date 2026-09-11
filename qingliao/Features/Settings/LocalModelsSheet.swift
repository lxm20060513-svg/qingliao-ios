import SwiftUI

// MARK: - v2.0.118 本地模型管理（自主选择/拉取）

struct LocalModelsSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var models: [LocalModelInfo] = []
    @State private var pullName = ""
    @State private var pulling = false
    @State private var pullResult = ""

    /// v2.0.118：当前选用的本地模型（provider=local 时显示勾选）
    private var currentLocal: String? {
        let p = UserDefaults.standard.string(forKey: "qingliao_provider")
        let m = UserDefaults.standard.string(forKey: "qingliao_model")
        return p == "local" ? m : nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section("已安装模型（点选使用）") {
                    if models.isEmpty {
                        Text("暂无模型——下方输入模型名拉取，如 qwen3:1.7b")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(models) { m in
                            HStack {
                                Image(systemName: "cpu")
                                    .font(.system(size: Typography.subhead))
                                    .foregroundStyle(Color.indigo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name)
                                        .font(.system(size: Typography.body, weight: .medium))
                                    Text("\(m.size) · \(m.modified)")
                                        .font(.system(size: Typography.caption))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                // v2.0.118：当前选用的本地模型显示勾选
                                if currentLocal == m.name {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: Typography.body))
                                        .foregroundStyle(Color.green)
                                }
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // 选为当前模型（provider=local）
                                UserDefaults.standard.set(m.name, forKey: "qingliao_model")
                                UserDefaults.standard.set("local", forKey: "qingliao_provider")
                                dismiss()
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await deleteModel(m.name) }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                Section("拉取新模型（断网兜底自主扩充）") {
                    HStack(spacing: 8) {
                        TextField("如 qwen3:1.7b / qwen2.5:0.5b", text: $pullName)
                            .font(.system(size: Typography.subhead))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            Task { await pullModel() }
                        } label: {
                            if pulling {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("拉取")
                                    .font(.system(size: Typography.subhead, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(pulling || pullName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !pullResult.isEmpty {
                        Text(pullResult)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(pullResult.hasPrefix("✅") ? Color.green : Color.orange)
                    }
                    Text("模型名格式：<名称>:<版本>，Ollama 库里的都行（qwen3 / qwen2.5 / llama3.2 等）")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("本地模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func deleteModel(_ name: String) async {
        if let j = try? await auth.json("/api/local/delete", method: "POST", body: ["model": name]) {
            pullResult = (((j["ok"] as? Bool) ?? false) ? "✅ " : "❌ ") + ((j["message"] as? String) ?? "")
        }
        await load()
    }

    private func load() async {
        if let j = try? await auth.json("/api/local/models") {
            models = (j["models"] as? [[String: Any]] ?? []).map { LocalModelInfo($0) }
        }
    }

    private func pullModel() async {
        let name = pullName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        pulling = true
        defer { pulling = false }
        if let j = try? await auth.json("/api/local/update", method: "POST", body: ["model": name]) {
            let ok = (j["ok"] as? Bool) ?? false
            pullResult = (ok ? "✅ " : "❌ ") + ((j["message"] as? String) ?? "")
            if ok { pullName = ""; await load() }
        } else {
            pullResult = "❌ 拉取失败（请确认本地模型开关已开启）"
        }
    }
}

struct LocalModelInfo: Identifiable {
    let id = UUID()
    let name: String
    let size: String
    let modified: String
    init(_ d: [String: Any]) {
        name = d["name"] as? String ?? ""
        size = d["size"] as? String ?? ""
        modified = d["modified"] as? String ?? ""
    }
}
