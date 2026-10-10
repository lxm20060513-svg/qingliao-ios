// 本文件原为 Features/Settings/SettingsModels.swift 的物理拆分（纯搬运，UI 与行为零改动）。
// 上游文件保留 ModelSheet / provider 缓存 / 自定义模型组；本文件承载 Hermes 主模型设置 + provider key 自检提示行。

import Foundation
import SwiftUI

// MARK: - Hermes 主模型写入口（原「微信通道模型」页）
// 2026-10-10 语义更正：wechat-profile 已于 2026-09-09 删除，本页写的其实是 Hermes 全局主模型
// （微信通道/定时任务/后台任务共用）—— 不再是「只影响微信通道」。

struct WechatChannelSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var currentModel = "读取中…"
    @State private var currentProvider = ""
    @State private var allProviders: [(id: String, models: [String])] = []
    @State private var saving = false
    @State private var saveResult: String?
    @State private var loaded = false
    // v3.0.35：模型列表加载失败（区别于"加载中"——失败时不再无限转圈）
    @State private var loadFailed = false
    // v3.0.35：当前展示的是缓存数据（顶部提示，避免误以为未刷新）
    @State private var usingCache = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                // 当前模型 + 说明
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(loaded ? Color.green : Color.orange).frame(width: 7, height: 7)
                        Text("当前 Hermes 主模型")
                            .font(.system(size: Typography.caption)).foregroundStyle(.secondary)
                    }
                    Text(currentModel)
                        .font(.system(size: Typography.body, weight: .semibold))
                    Text("这是 Hermes 全局主模型：微信、定时任务、后台任务都用它；轻聊 App 对话用的是「模型管理」里选的模型。保存后重启 Hermes 生效（约 10-30 秒）。")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.tertiary)
                }
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pastelFill(cornerRadius: Radius.inset)

            if let saveResult {
                Text(saveResult)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(saveResult.hasPrefix("✅") ? Color.green : Color.orange)
            }

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    if allProviders.isEmpty {
                        if loadFailed {
                            // v3.0.35：加载失败态 + 重试（不再无限转圈）
                            // v3.9.42：错误态收口到 ErrorStateView（此处原为手抄版，另一处 1640 行同一段）
                            ErrorStateView(title: "模型列表加载失败",
                                           detail: "请检查网络或后端服务后重试") {
                                loadFailed = false
                                Task { await loadProviders() }
                            }
                        } else {
                            // v3.9.42：模型列表按 provider 分组、行数不可预测 → 转圈不出假骨架
                            LoadingStateView(shape: .spinner(text: "正在加载模型列表…"))
                        }
                    } else {
                        // v3.0.35：缓存数据展示提示（后台刷新成功后自动消失）
                        if usingCache {
                            HStack(spacing: 4) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: Typography.tiny))
                                Text("显示上次加载的列表，正在刷新…")
                                    .font(.system(size: Typography.tiny))
                            }
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Spacing.xs)
                        }
                        // v3.0.19 review：全部 provider 模型为空 → 空态提示（防白屏）
                        let hasAnyModel = allProviders.contains { !$0.models.isEmpty }
                        if !hasAnyModel {
                            VStack(spacing: 8) {
                                Image(systemName: "tray")
                                    .font(.system(size: Typography.display))
                                    .foregroundStyle(.tertiary)
                                Text("暂无可用模型\n（后端未配置 provider key，请到「模型管理」检查）")
                                    .font(.system(size: Typography.subhead))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.top, 40)
                        }
                        ForEach(allProviders, id: \.id) { p in
                            if !p.models.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(providerName(p.id))
                                        .font(.system(size: Typography.subhead, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, Spacing.xs)
                                    ForEach(p.models, id: \.self) { m in
                                        Button {
                                            saveModel(provider: p.id, model: m)
                                        } label: {
                                            HStack {
                                                Text(m)
                                                    .font(.system(size: Typography.subhead))
                                                    .foregroundStyle(.primary)
                                                Spacer()
                                                // 当前选中标记（model+provider 都匹配）
                                                if m == currentModel && p.id == currentProvider {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .font(.system(size: Typography.subhead))
                                                        .foregroundStyle(Color.accentColor)
                                                } else {
                                                    Image(systemName: "chevron.right")
                                                        .font(.system(size: Typography.tiny))
                                                        .foregroundStyle(.tertiary)
                                                }
                                            }
                                            .padding(.horizontal, Spacing.xl)
                                            .padding(.vertical, Spacing.md)
                                            .pastelFill(cornerRadius: Radius.icon)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(Spacing.xxl)
        .navigationTitle("Hermes 主模型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
            // v3.0.35：手动刷新（缓存过期/刷新失败后重拉）
            ToolbarItem(placement: .primaryAction) {
                // v3.9.35：刷新改回系统裸按钮——与「完成」同款系统玻璃胶囊
                Button("刷新") { Task { await load() } }
            }
        }
        .task { await load() }
        }
    }

    /// 拉当前 Hermes 主模型 + 全部 provider 模型列表
    /// v3.0.35：①缓存优先（打开即有列表，不转圈）②两个请求 async let 并发（原串行，channel/model 挂起会拖死 providers）
    private func load() async {
        // 1) 立即展示缓存
        if allProviders.isEmpty, !ModelProvidersCache.load().isEmpty {
            allProviders = ModelProvidersCache.load()
            usingCache = true
        }
        // 2) 并发刷新（互不阻塞）
        async let cm: Void = loadChannelModel()
        async let pl: Void = loadProviders()
        _ = await (cm, pl)
    }

    /// 拉当前 Hermes 主模型（独立失败不影响模型列表）
    private func loadChannelModel() async {
        if let j = try? await auth.json("/api/channel/model") {
            currentModel = (j["model"] as? String) ?? "未设置"
            currentProvider = (j["provider"] as? String) ?? ""
            loaded = true
        } else {
            currentModel = "读取失败（后端需 v3.0.19）"
        }
    }

    /// 拉 provider 模型列表（成功写缓存；失败置 loadFailed，有缓存则保留缓存展示）
    private func loadProviders() async {
        do {
            let j = try await auth.json("/api/stream/model-providers?with_models=1")
            guard (j["ok"] as? Bool) == true, let plist = j["providers"] as? [[String: Any]] else {
                throw APIError.badJSON
            }
            var result: [(id: String, models: [String])] = []
            for p in plist {
                guard let id = p["id"] as? String else { continue }
                let models = (p["models"] as? [String]) ?? []
                result.append((id: id, models: models))
            }
            allProviders = result
            ModelProvidersCache.save(result)
            usingCache = false
            loadFailed = false
        } catch {
            // 有缓存则保留缓存展示；无缓存时 UI 显示失败态+重试
            if allProviders.isEmpty {
                loadFailed = true
            }
        }
    }

    /// 保存 Hermes 主模型（POST /api/channel/model → 后端改主 config.yaml 的 model 段 + 重启 gateway）
    private func saveModel(provider: String, model: String) {
        guard !saving else { return }
        saving = true
        saveResult = nil
        Task {
            defer { saving = false }
            do {
                let j = try await auth.json("/api/channel/model", method: "POST",
                                            body: ["model": model, "provider": provider])
                if (j["ok"] as? Bool) == true {
                    currentModel = model
                    currentProvider = provider
                    UserDefaults.standard.set(model, forKey: "qingliao_wechat_channel_model")
                    saveResult = "✅ 已设置：\(model)（Hermes 全局主模型 · gateway 重启后生效，约 10-30 秒）"
                } else {
                    saveResult = "⚠️ 设置失败：\(j["error"] as? String ?? "未知错误")"
                }
            } catch {
                saveResult = "⚠️ 设置失败：\(error.localizedDescription)"
            }
        }
    }

    /// provider 显示名
    private func providerName(_ id: String) -> String {
        switch id {
        case "opencode": return "opencode（google）"
        case "opencode-apple": return "opencode（apple）"
        case "deepseek": return "deepseek（官方）"
        case "stepfun": return "stepfun"
        case "sensenova": return "sensenova（商汤）"
        case "xiaomi": return "xiaomi"
        case "ollama": return "本地模型（Ollama）"
        default: return id
        }
    }
}

// MARK: - v3.4.x key 健康自检提示行（空 models 的 provider = key 无效/未配置，主动提示而非静默消失）

struct ProviderKeyIssueRow: View {
    let name: String
    // v3.9.35：按 key 重新拉取该组模型列表（重试入口）
    var onRetry: (() -> Void)? = nil
    var retrying: Bool = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: Typography.subhead, weight: .medium))
                Text("API Key 无效或未配置，未拉取到模型（可点右侧重试，或检查 key）")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onRetry {
                Button {
                    onRetry()
                } label: {
                    if retrying {
                        ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.lg)
        .background(Color.orange.opacity(Tint.faint), in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
    }
}
