import SwiftUI

// MARK: - v3.5.0 MCP 工具服务管理
// App 配 key → 后端 /api/mcp/* → Hermes config.yaml → 本地模式聊天自动获得 MCP 工具
// 交互照 CustomProviderEditSheet（模板选择 + key 输入 + 列表管理）

struct MCPServerItem: Identifiable {
    let id: String          // name
    let url: String         // 已脱敏
    let hasKey: Bool
    let enabled: Bool
}

struct MCPTemplate: Identifiable {
    let id: String
    let name: String
    let desc: String
    let urlTemplate: String
    let keyHint: String
}

struct MCPSettingsSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var servers: [MCPServerItem] = []
    @State private var templates: [MCPTemplate] = []
    @State private var loading = false
    @State private var errMsg: String?

    // 新增表单
    @State private var showAdd = false
    @State private var selectedTemplate: MCPTemplate?
    @State private var customURL = ""
    @State private var key = ""
    @State private var saving = false
    @State private var saveMsg: String?
    // v3.5.0 review：删除走二次确认（服务删除会触发 hermes 重启，防误触）
    @State private var pendingDelete: MCPServerItem?

    var body: some View {
        NavigationStack {
            Form {
                if loading {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                } else if let errMsg {
                    Section {
                        Text("⚠️ \(errMsg)").font(.system(size: 13)).foregroundStyle(.orange)
                    }
                } else {
                    serverListSection
                    addSection
                    hintSection
                }
            }
            .navigationTitle("MCP 工具服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                MCPAddSheet(templates: templates) { template, k, url in
                    Task { await save(template: template, key: k, url: url) }
                }
            }
            .confirmationDialog("删除 \(pendingDelete?.id ?? "")？将触发 Hermes 重启（约 30 秒）",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let s = pendingDelete { Task { await delete(s.id) } }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            }
            .task { await load() }
        }
    }

    // MARK: 已配置服务列表
    @ViewBuilder private var serverListSection: some View {
        Section("已启用（\(servers.count)）") {
            if servers.isEmpty {
                Text("暂无——点右上角 + 添加，如高德地图（天气/路线/导航）")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            ForEach(servers) { s in
                HStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.teal, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.id).font(.system(size: 14, weight: .medium))
                        Text(s.enabled ? "已启用" : "已停用")
                            .font(.system(size: 11))
                            .foregroundStyle(s.enabled ? Color.green : Color.secondary)
                    }
                    Spacer()
                    // 删除（二次确认走 confirmationDialog）
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = s
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
    }

    @ViewBuilder private var addSection: some View {
        Section("添加") {
            Button {
                showAdd = true
            } label: {
                Label("从模板添加（推荐）", systemImage: "plus.circle.fill")
            }
        }
    }

    @ViewBuilder private var hintSection: some View {
        Section {
            Text("保存后 Hermes 自动重启（约 30 秒），之后在「聊天」里直接说\"帮我查明天天气\"即可触发工具。删除同理。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: 网络
    private func load() async {
        loading = true
        errMsg = nil
        defer { loading = false }
        do {
            let d = try await auth.json("/api/mcp/servers")
            guard let ok = d["ok"] as? Bool, ok else {
                errMsg = "加载失败"
                return
            }
            var arr: [MCPServerItem] = []
            if let sv = d["servers"] as? [String: Any] {
                for (name, e) in sv {
                    let url = e as? [String: Any] ?? [:]
                    arr.append(MCPServerItem(
                        id: name,
                        url: url["url"] as? String ?? "",
                        hasKey: url["has_key"] as? Bool ?? false,
                        enabled: url["enabled"] as? Bool ?? true))
                }
            }
            servers = arr.sorted { $0.id < $1.id }
            var tps: [MCPTemplate] = []
            if let ts = d["templates"] as? [[String: Any]] {
                for t in ts {
                    tps.append(MCPTemplate(
                        id: t["id"] as? String ?? "",
                        name: t["name"] as? String ?? "",
                        desc: t["desc"] as? String ?? "",
                        urlTemplate: t["url_template"] as? String ?? "",
                        keyHint: t["key_hint"] as? String ?? ""))
                }
            }
            templates = tps
        } catch {
            errMsg = "加载失败：\(error.localizedDescription)"
        }
    }

    private func save(template: MCPTemplate?, key k: String, url: String) async {
        saving = true
        defer { saving = false }
        do {
            var body: [String: Any] = ["name": template?.id ?? "custom"]
            if let template {
                body["template"] = template.id
                body["key"] = k
            } else {
                body["url"] = url
            }
            let d = try await auth.json("/api/mcp/save", method: "POST", body: body)
            if let ok = d["ok"] as? Bool, ok {
                saveMsg = "✅ 已保存，约 30 秒后生效"
                await load()
            } else {
                saveMsg = "❌ \(d["error"] as? String ?? "保存失败")"
            }
        } catch {
            saveMsg = "❌ \(error.localizedDescription)"
        }
    }

    private func delete(_ name: String) async {
        do {
            _ = try await auth.json("/api/mcp/delete", method: "POST", body: ["name": name])
            await load()
        } catch {
            errMsg = "删除失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 新增 sheet（模板选择 + key）
struct MCPAddSheet: View {
    let templates: [MCPTemplate]
    let onSaved: (MCPTemplate?, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var picked: MCPTemplate?
    @State private var customURL = ""
    @State private var key = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("选择服务") {
                    ForEach(templates) { t in
                        Button {
                            picked = t
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name).font(.system(size: 14, weight: .medium)).foregroundColor(.primary)
                                    Text(t.desc).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if picked?.id == t.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    // 高级：自定义 URL
                    Button {
                        picked = nil
                    } label: {
                        HStack {
                            Text("自定义 URL（高级）").font(.system(size: 14)).foregroundColor(.primary)
                            Spacer()
                            if picked == nil && !customURL.isEmpty {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                    if picked == nil {
                        TextField("https://... (MCP HTTP 端点)", text: $customURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 12))
                    }
                }
                if let t = picked {
                    Section("Key") {
                        SecureField(t.keyHint, text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle("添加 MCP 服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSaved(picked, key, customURL)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        if let t = picked { return !key.isEmpty }
        return customURL.hasPrefix("https://") || customURL.hasPrefix("http://")
    }
}
