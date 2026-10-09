// 本文件原为 Features/Settings/SettingsModels.swift 的物理拆分（纯搬运，UI 与行为零改动）。
// 上游文件保留 ModelSheet / provider 缓存 / 自定义模型组；本文件承载 Agent 模型选择。

import Foundation
import SwiftUI

// MARK: - v3.0.20 Agent 模型选择（独立于主模型，可单独指定 Agent 使用的模型）

struct AgentModelSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UserDefaultsKey.agentModel) private var agentModel = ""
    @AppStorage(UserDefaultsKey.agentProvider) private var agentProvider = ""
    @AppStorage("qingliao_model") private var mainModel = "deepseek-v4-flash"

    @State private var selected = ""
    @State private var selectedProvider = ""
    @State private var syncing = false
    @State private var syncResult: String?
    @State private var allProviders: [(id: String, models: [String])] = []
    @State private var localInstalled: [String] = []
    // v3.0.35：模型列表加载失败（不再无限转圈）
    @State private var loadFailed = false

    /// opencode 模型显示名映射
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                // 当前状态
                HStack(spacing: Spacing.xs) {
                    Circle().fill(syncing ? Color.orange : Color.green).frame(width: 7, height: 7)
                    Text(syncing ? "同步中..." : "Agent 模型设置")
                        .font(.system(size: Typography.caption)).foregroundStyle(.secondary)
                }
                if let syncResult {
                    Text(syncResult)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(syncResult.hasPrefix("✅") ? Color.green : Color.orange)
                }

                // 跟随主模型选项
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("跟随主模型")
                                .font(.system(size: Typography.subhead, weight: .medium))
                            Text("当前主模型：\(mainModel)")
                                .font(.system(size: Typography.tiny))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if selected.isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: Typography.body))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(Spacing.lg)
                    .pastelFill(cornerRadius: Radius.inset, stroke: false)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                            .strokeBorder(selected.isEmpty ? Color.accentColor.opacity(0.5) : Color.primary.opacity(Tint.faint),
                                          lineWidth: 0.8)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selected = ""
                        selectedProvider = ""
                    }
                }

                Divider()

                ScrollView {
                    VStack(spacing: 12) {
                        if allProviders.isEmpty && localInstalled.isEmpty {
                            if loadFailed {
                                // v3.0.35：加载失败态 + 重试（不再无限转圈）
                                // v3.9.42：错误态收口到 ErrorStateView
                                ErrorStateView(title: "模型列表加载失败",
                                               detail: "请检查网络或后端服务后重试") {
                                    loadFailed = false
                                    Task { await loadAllProviders() }
                                }
                            } else {
                                // v3.9.42：分组列表行数不可预测 → 转圈不出假骨架
                                LoadingStateView(shape: .spinner(text: "正在加载模型列表…"))
                            }
                        } else {
                            // 按 provider 分组显示（v3.0.29 fix：移除 hardcoded 过滤，所有 provider 均展示）
                            ForEach(allProviders, id: \.id) { p in
                                if !p.models.isEmpty {
                                    agentGroupSection(providerDisplayName(p.id),
                                                      models: p.models.map { ($0, providerModelDisplayName(p.id, $0), p.id) })
                                }
                            }
                            // 本地模型
                            if !localInstalled.isEmpty {
                                agentGroupSection("本地模型（断网兜底）",
                                                  models: localInstalled.map { ($0, $0 + " · 本地", "local") })
                            }
                        }
                    }
                    .padding(.bottom, Spacing.md)
                }
            }
            .padding(Spacing.sheetInset)
            .navigationTitle("Agent 模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        agentModel = selected
                        agentProvider = selectedProvider
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    // v3.9.35：刷新改回系统裸按钮——与「完成」同款系统玻璃胶囊
                    Button("刷新") { Task { await syncList() } }
                }
            }
            .onAppear {
                selected = agentModel
                selectedProvider = agentProvider
                // v3.0.35：先展示缓存（打开即有列表不转圈），后台刷新成功后替换
                if allProviders.isEmpty, !ModelProvidersCache.load().isEmpty {
                    allProviders = ModelProvidersCache.load()
                }
                Task { await loadAllProviders() }
            }
        }
    }

    /// 分组标题 + 模型行
    private func agentGroupSection(_ group: String, models: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group)
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, Spacing.xs)
            ForEach(models, id: \.0) { m in
                agentModelRow(id: m.0, name: m.1, provider: m.2)
            }
        }
    }

    private func agentModelRow(id: String, name: String, provider: String) -> some View {
        let isCur = selected == id && selectedProvider == provider
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(id)
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(isCur ? Color.accentColor : Color.primary)
                Text(name)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCur {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: Typography.body))
                    Text("当前").font(.system(size: Typography.caption, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
            } else {
                Button {
                    selected = id
                    selectedProvider = provider
                } label: {
                    Text("选用")
                        .font(.system(size: Typography.caption, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.xs)
                        .glassPillStroke()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.lg)
        .pastelFill(cornerRadius: Radius.inset, stroke: false)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                .strokeBorder(isCur ? Color.accentColor.opacity(0.5) : Color.primary.opacity(Tint.faint),
                              lineWidth: 0.8)
        )
    }

    private func providerDisplayName(_ id: String) -> String {
        switch id {
        case "opencode": return "opencode（google）"
        case "opencode-apple": return "opencode（apple）"
        case "stepfun": return "stepfun"
        case "deepseek": return "deepseek（官方）"
        case "sensenova": return "sensenova（商汤）"
        case "xiaomi": return "xiaomi（小米）"
        case "local": return "本地模型（断网兜底）"
        default: return id
        }
    }

    private func providerModelDisplayName(_ pid: String, _ model: String) -> String {
        switch pid {
        case "opencode", "opencode-apple": return opencodeModelNames[model] ?? model
        case "sensenova": return sensenovaModelNames[model] ?? model
        default: return model
        }
    }

    /// 拉取所有 provider 的模型列表（v3.0.35：成功写缓存，失败置 loadFailed，有缓存则保留缓存展示）
    private func loadAllProviders() async {
        do {
            let j = try await auth.json("/api/stream/model-providers?with_models=1")
            let plist = (j["providers"] as? [[String: Any]]) ?? []
            var result: [(id: String, models: [String])] = []
            for p in plist {
                guard let id = p["id"] as? String,
                      let models = p["models"] as? [String] else { continue }
                result.append((id: id, models: models))
            }
            allProviders = result
            ModelProvidersCache.save(result)
            loadFailed = false
        } catch {
            // 有缓存则保留缓存展示；无缓存时 UI 显示失败态+重试
            if allProviders.isEmpty && localInstalled.isEmpty {
                loadFailed = true
            }
        }
    }

    /// 同步模型列表
    private func syncList() async {
        guard !syncing else { return }
        syncing = true
        syncResult = nil
        await loadAllProviders()
        // 本地模型
        if let j = try? await auth.json("/api/local/models") {
            localInstalled = (j["models"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "" }
        }
        syncing = false
        syncResult = "✅ 已刷新"
    }
}
