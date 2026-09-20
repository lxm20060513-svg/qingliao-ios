import SwiftUI

// MARK: - v2.0.118 本地模型管理（自主选择/拉取）

struct LocalModelsSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var models: [LocalModelInfo] = []
    @State private var pullName = ""
    @State private var pulling = false
    @State private var pullResult = ""
    // v3.9.41（SR48）：删除是破坏性且不可逆（模型要重新拉几百 MB），原先侧滑点一下就立刻下发；
    // 且删除「当前正在用的那个本地模型」后 provider=local + 已不存在的模型名会一直留着 → 之后每条
    // AI 请求都失败。改成先确认，删成功后把选择回落到 App 默认 provider。
    @State private var deleteTarget: String?
    @State private var deleting = false
    @State private var loadFailed = false

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
                        // v3.9.41（SR48）：拉取失败与真的没模型分得开（原先一律显示「暂无模型」）
                        Text(loadFailed ? "模型列表获取失败（网络或后端不可用），可点右上角「刷新」重试"
                                        : "暂无模型——下方输入模型名拉取，如 qwen3:1.7b")
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
                            .padding(.vertical, Spacing.xxs)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // 选为当前模型（provider=local）
                                UserDefaults.standard.set(m.name, forKey: "qingliao_model")
                                UserDefaults.standard.set("local", forKey: "qingliao_provider")
                                dismiss()
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleteTarget = m.name
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
                    // v3.9.35：刷新改回系统裸按钮——与「完成」同款系统玻璃胶囊
                    Button("刷新") { Task { await load() } }
                }
            }
            .task { await load() }
        }
        // v3.9.41（SR48）：删除前确认；当前正在使用的模型额外提示会切回默认 provider
        .alert("删除模型", isPresented: Binding(get: { deleteTarget != nil },
                                                set: { if !$0 { deleteTarget = nil } })) {
            Button("删除", role: .destructive) {
                if let name = deleteTarget { Task { await deleteModel(name) } }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget == currentLocal
                 ? "确定删除 \(deleteTarget ?? "")？删除后需重新拉取。它正是当前使用的模型，删除后会自动切回默认服务商。"
                 : "确定删除 \(deleteTarget ?? "")？删除后需重新拉取。")
        }
        .presentationDetents([.medium, .large])
    }

    private func deleteModel(_ name: String) async {
        // v3.9.41（SR48）：删除在飞的闸门（确认弹窗关闭后仍可连点侧滑）
        guard !deleting else { return }
        deleting = true
        defer { deleting = false }
        do {
            let j = try await auth.json("/api/local/delete", method: "POST", body: ["model": name])
            let ok = (j["ok"] as? Bool) ?? false
            pullResult = (ok ? "✅ " : "❌ ") + ((j["message"] as? String) ?? "")
            if ok, name == currentLocal {
                // 当前选中的就是它 → 清掉失效选择，否则 provider=local + 已删模型名会一直留着
                UserDefaults.standard.removeObject(forKey: "qingliao_model")
                UserDefaults.standard.set("opencode", forKey: "qingliao_provider")
                pullResult = "✅ 已删除 \(name)，并已切回默认服务商"
            }
        } catch {
            pullResult = "❌ 删除失败：\(error.localizedDescription)"
        }
        await load()
    }

    private func load() async {
        // v3.9.41（SR48）：原来 try? 吞掉所有错误 → 列表空还显示「暂无模型」，看不出是没拉到
        do {
            let j = try await auth.json("/api/local/models")
            models = (j["models"] as? [[String: Any]] ?? []).map { LocalModelInfo($0) }
            loadFailed = false
        } catch {
            loadFailed = true
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
