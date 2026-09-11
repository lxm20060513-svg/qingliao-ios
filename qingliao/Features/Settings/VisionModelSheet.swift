import SwiftUI

// MARK: - v3.0.28 视觉模型配置（统一：App 与微信通道共用同一份配置）
//
// v3.0.28 重构：原先「App 本地视觉模型」与「微信通道视觉模型」是两份独立配置，
// 现在统一为一份「共享视觉模型」——在下方模型列表点选打勾即同时写入：
//   1) App 本地（CloudConfig，App 内发图走 effectiveVisionModel）
//   2) 微信通道（后端 /api/channel/vision-model → wechat-profile auxiliary.vision，Hermes 微信通道用）
// 选择动作 = 直接在对应模型后面点选打勾（checkmark），无需额外按钮。

struct VisionModelSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var enabled = CloudConfig.visionFallbackEnabled
    /// 当前共享视觉模型（App 本地 + 微信通道共用的那份配置）
    @State private var selectedModel: String = CloudConfig.localVisionModel ?? ""
    @State private var selectedProvider: String = CloudConfig.localVisionProvider

    @State private var syncing = false
    @State private var syncResult: String?

    // 同步的模型列表（复用 ModelSheet 的数据源）
    @State private var allProviders: [(id: String, models: [String])] = []
    @State private var opencodeAppleModels: [String] = []
    @State private var deepseekModels: [String] = []
    @State private var stepfunModels: [String] = []
    @State private var sensenovaModels: [String] = []
    @State private var localInstalled: [String] = []

    // 当前主模型（判断是否支持视觉）
    @AppStorage("qingliao_model") private var mainModel = "deepseek-v4-flash"
    private var mainModelSupportsVision: Bool {
        CloudConfig.modelSupportsVision(mainModel)
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: - 开关 + 状态
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.purple, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("视觉模型自动切换").font(.system(size: Typography.body, weight: .medium))
                            Text(statusText)
                                .font(.system(size: Typography.caption)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                        Toggle("", isOn: $enabled).labelsHidden().scaleEffect(0.8).tint(.green)
                            .onChange(of: enabled) { _, new in
                                CloudConfig.setVisionFallbackEnabled(new)
                            }
                    }
                }

                if enabled {
                    // MARK: - 主模型状态
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: mainModelSupportsVision ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(mainModelSupportsVision ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("主模型：\(mainModel)")
                                    .font(.system(size: Typography.subhead, weight: .medium))
                                Text(mainModelSupportsVision
                                     ? "已支持视觉，无需配置备用模型"
                                     : "不支持视觉，发送图片时将使用下方点选的共享视觉模型")
                                    .font(.system(size: Typography.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // MARK: - 共享视觉模型（App + 微信通道共用）说明
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: Typography.subhead))
                                .foregroundStyle(.purple)
                            Text("共享视觉模型（App + 微信通道）")
                                .font(.system(size: Typography.subhead, weight: .medium))
                            Spacer()
                            if syncing {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        Text(sharedVisionDisplay)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                        Text("点选下方任一模型即设置：App 内发图 与 微信通道收图 共用的视觉模型（写入 wechat-profile，改完自动重启 gateway）。")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.tertiary)
                        if let syncResult {
                            Text(syncResult)
                                .font(.system(size: Typography.caption))
                                .foregroundStyle(syncResult.hasPrefix("✅") ? Color.green : Color.orange)
                        }
                        if !selectedModel.isEmpty {
                            HStack(spacing: 8) {
                                Button("清除配置") {
                                    clearSharedVision()
                                }
                                .font(.system(size: Typography.caption, weight: .medium))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.red.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("共享配置")
                }

                // MARK: - 模型列表选择（点选打勾 = 设为共享视觉模型）
                Section("选择视觉模型（点选打勾）") {
                    if deepseekModels.isEmpty && localInstalled.isEmpty && allProviders.isEmpty
                        && opencodeAppleModels.isEmpty && stepfunModels.isEmpty && sensenovaModels.isEmpty {
                        Text("暂无可用模型\n请先在「模型管理」中同步模型列表")
                            .font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                    } else {
                        // opencode（apple）模型
                        if !opencodeAppleModels.isEmpty {
                            modelGroup("opencode（apple）", provider: "opencode-apple", models: opencodeAppleModels)
                        }
                        if !deepseekModels.isEmpty {
                            modelGroup("deepseek（官方）", provider: "deepseek", models: deepseekModels)
                        }
                        if !stepfunModels.isEmpty {
                            modelGroup("stepfun", provider: "stepfun", models: stepfunModels)
                        }
                        if !sensenovaModels.isEmpty {
                            modelGroup("sensenova（商汤）", provider: "sensenova", models: sensenovaModels)
                        }
                        if !localInstalled.isEmpty {
                            modelGroup("本地模型", provider: "local", models: localInstalled)
                        }
                        // 通用 provider
                        let hardcoded = ["opencode", "opencode-apple", "deepseek", "stepfun", "sensenova", "local"]
                        ForEach(allProviders.filter { !hardcoded.contains($0.id) && !$0.models.isEmpty }, id: \.id) { p in
                            modelGroup(providerDisplayName(p.id), provider: p.id, models: p.models)
                        }
                    }
                }
            }
            .navigationTitle("视觉模型配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await syncModels() } } label: {
                        // v3.9.4：刷新统一为「文字 + 胶囊」（去图标）
                        Text("刷新")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
            }
            .task { await loadCachedModels() }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 模型行（点选打勾）

    private func modelGroup(_ group: String, provider: String, models: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group)
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.vertical, 4)
            ForEach(models, id: \.self) { model in
                let isSelected = selectedModel == model && selectedProvider == provider
                let name = modelDisplayName(provider: provider, model: model)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: Typography.subhead, weight: .medium))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        if model != name {
                            Text(model)
                                .font(.system(size: Typography.tiny))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    // 点选打勾：选中显示实心对勾，未选显示空心圈
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: Typography.headline))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectSharedVision(provider: provider, model: model)
                }
            }
        }
    }

    // MARK: - 状态文案

    private var statusText: String {
        if !enabled { return "已关闭" }
        if mainModelSupportsVision { return "主模型支持视觉，无需配置" }
        if selectedModel.isEmpty { return "未配置视觉模型" }
        return "已配置：\(selectedModel)"
    }

    /// 共享视觉模型显示文案
    private var sharedVisionDisplay: String {
        if selectedModel.isEmpty { return "未配置（主模型支持视觉时直接用主模型；主模型不支持时发图会降级为纯文本）" }
        return "\(selectedModel)（\(providerDisplayName(selectedProvider))）"
    }

    private func modelDisplayName(provider: String, model: String) -> String {
        switch provider {
        case "opencode", "opencode-apple":
            let names: [String: String] = [
                "deepseek-v4-flash": "DeepSeek V4 Flash",
                "deepseek-v4-flash-free": "DeepSeek V4 Flash Free",
                "deepseek-v4-pro": "DeepSeek V4 Pro",
                "kimi-k3": "Kimi K3", "kimi-k2.7-code": "Kimi K2.7 Code",
                "kimi-k2.6": "Kimi K2.6", "kimi-k2.5": "Kimi K2.5",
                "glm-5.3": "GLM 5.3", "glm-5.2": "GLM 5.2", "glm-5.1": "GLM 5.1", "glm-5": "GLM 5",
                "qwen3.8-max": "Qwen3.8 Max", "qwen3.7-max": "Qwen3.7 Max",
                "qwen3.7-plus": "Qwen3.7 Plus", "qwen3.6-plus": "Qwen3.6 Plus",
                "minimax-m3": "MiniMax M3", "minimax-m2.7": "MiniMax M2.7", "minimax-m2.5": "MiniMax M2.5",
                "mimo-v2.5-pro": "MiMo V2.5 Pro", "mimo-v2.5": "MiMo V2.5",
                "mimo-v2-pro": "MiMo V2 Pro", "mimo-v2-omni": "MiMo V2 Omni",
                "gpt-5.6-luna": "GPT-5.6 Luna", "grok-4.5": "Grok 4.5",
            ]
            return names[model] ?? model
        case "sensenova":
            let names: [String: String] = [
                "sensenova-6.8-flash-lite": "SenseNova 6.8 Flash Lite",
                "sensenova-6.7-flash-lite": "SenseNova 6.7 Flash Lite",
                "sensenova-u1-fast": "SenseNova U1 Fast",
            ]
            return names[model] ?? model
        default:
            return model
        }
    }

    private func providerDisplayName(_ id: String) -> String {
        switch id {
        case "opencode": return "opencode（google）"
        case "opencode-apple": return "opencode（apple）"
        case "deepseek": return "deepseek（官方）"
        case "stepfun": return "stepfun"
        case "sensenova": return "sensenova（商汤）"
        case "local": return "本地模型"
        default: return id
        }
    }

    // MARK: - 数据加载

    private func loadCachedModels() async {
        // 读取共享配置：微信通道为源（持久），App 本地镜像
        await loadSharedVision()
        // 从 UserDefaults 恢复缓存的模型列表
        if let s = UserDefaults.standard.array(forKey: "qingliao_models_stepfun") as? [String] { stepfunModels = s }
        if let d = UserDefaults.standard.array(forKey: "qingliao_models_deepseek") as? [String] { deepseekModels = d }
        if let a = UserDefaults.standard.array(forKey: "qingliao_models_opencode_apple") as? [String] { opencodeAppleModels = a }
        if let sn = UserDefaults.standard.array(forKey: "qingliao_models_sensenova") as? [String] { sensenovaModels = sn }
        // 本地 Ollama 模型
        if let j = try? await auth.json("/api/local/models") {
            localInstalled = (j["models"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "" }
        }
        // 通用 provider（v3.0.35：先展示缓存，网络成功写缓存，与其他入口共用）
        if allProviders.isEmpty {
            if !ModelProvidersCache.load().isEmpty {
                allProviders = ModelProvidersCache.load()
            }
            if let j = try? await auth.json("/api/stream/model-providers?with_models=1"),
               (j["ok"] as? Bool) == true,
               let plist = j["providers"] as? [[String: Any]] {
                var result: [(id: String, models: [String])] = []
                for p in plist {
                    guard let id = p["id"] as? String else { continue }
                    let models = (p["models"] as? [String]) ?? []
                    if !models.isEmpty { result.append((id: id, models: models)) }
                }
                allProviders = result
                ModelProvidersCache.save(result)
            }
        }
    }

    /// 读取共享视觉模型：后端为源（持久），回读后同步到 App 本地 CloudConfig
    /// 后端将 local 归一化为 ollama 存储，回读时还原为 local 以便与模型列表匹配
    private func loadSharedVision() async {
        var fromBackend = false
        if let j = try? await auth.json("/api/channel/vision-model") {
            if (j["ok"] as? Bool) == true {
                let prov = j["provider"] as? String
                let model = j["model"] as? String
                if let m = model, !m.isEmpty {
                    let p = prov == "ollama" ? "local" : prov
                    selectedProvider = p ?? "opencode"
                    selectedModel = m
                    fromBackend = true
                    // 同步到 App 本地：让 App 发图与微信通道共用同一份
                    CloudConfig.setVisionModel(m, provider: p ?? "opencode")
                }
            }
        }
        // 后端无配置 → 用 App 本地已配置的（保持一份配置的语义）
        if !fromBackend {
            selectedModel = CloudConfig.localVisionModel ?? ""
            selectedProvider = CloudConfig.localVisionProvider
            if !selectedModel.isEmpty {
                // 把本地配置推给微信通道，保证两边一致
                _ = await pushToBackendAsync(provider: selectedProvider, model: selectedModel)
            }
        }
    }

    /// 点选打勾 = 设置共享视觉模型（App 本地 + 微信通道）
    private func selectSharedVision(provider: String, model: String) {
        guard !syncing else { return }
        selectedModel = model
        selectedProvider = provider
        // 1) App 本地（立即生效）
        CloudConfig.setVisionModel(model, provider: provider)
        // 2) 微信通道（异步，自动重启 gateway）
        syncResult = "正在同步微信通道…"
        Task {
            let ok = await pushToBackendAsync(provider: provider, model: model)
            if ok {
                syncResult = "✅ 已共享：\(model)（App + 微信通道，gateway 重启后生效，约 10-30 秒）"
            } else {
                syncResult = "⚠️ 微信通道同步失败（App 本地已生效，可稍后重试）"
            }
        }
    }

    /// 清除共享视觉模型（App 本地 + 微信通道）
    private func clearSharedVision() {
        guard !syncing else { return }
        selectedModel = ""
        selectedProvider = "opencode"
        CloudConfig.clearVisionModel()
        syncResult = "正在清除微信通道…"
        Task {
            let ok = await pushDeleteBackendAsync()
            if ok {
                syncResult = "✅ 已清除共享视觉模型（gateway 重启后生效，约 10-30 秒）"
            } else {
                syncResult = "⚠️ 微信通道清除失败（App 本地已清除）"
            }
        }
    }

    /// POST 共享视觉模型到微信通道（返回是否成功）
    @discardableResult
    private func pushToBackendAsync(provider: String, model: String) async -> Bool {
        do {
            let j = try await auth.json("/api/channel/vision-model", method: "POST",
                                        body: ["provider": provider, "model": model])
            return (j["ok"] as? Bool) == true
        } catch {
            return false
        }
    }

    /// DELETE 微信通道视觉模型（返回是否成功）
    @discardableResult
    private func pushDeleteBackendAsync() async -> Bool {
        do {
            let j = try await auth.json("/api/channel/vision-model", method: "DELETE")
            return (j["ok"] as? Bool) == true
        } catch {
            return false
        }
    }

    private func syncModels() async {
        // 复用后端 sync-models 接口
        func fetch(_ provider: String) async -> [String]? {
            guard let j = try? await auth.json("/api/stream/sync-models?provider=\(provider)"),
                  (j["ok"] as? Bool) == true,
                  let list = j["models"] as? [String] else { return nil }
            return list
        }
        // v3.0.34：4 个 provider 并发同步（async let），避免串行转圈
        async let sf = fetch("stepfun")
        async let ds = fetch("deepseek")
        async let oa = fetch("opencode-apple")
        async let sn = fetch("sensenova")
        let (s, d, oaR, snR) = await (sf, ds, oa, sn)
        if let s {
            stepfunModels = s
            UserDefaults.standard.set(s, forKey: "qingliao_models_stepfun")
        }
        if let d {
            deepseekModels = d
            UserDefaults.standard.set(d, forKey: "qingliao_models_deepseek")
        }
        if let oaR {
            opencodeAppleModels = oaR
            UserDefaults.standard.set(oaR, forKey: "qingliao_models_opencode_apple")
        }
        if let snR {
            sensenovaModels = snR
            UserDefaults.standard.set(snR, forKey: "qingliao_models_sensenova")
        }
        // 通用 provider
        if let j = try? await auth.json("/api/stream/model-providers?with_models=1"),
           (j["ok"] as? Bool) == true,
           let plist = j["providers"] as? [[String: Any]] {
            var result: [(id: String, models: [String])] = []
            for p in plist {
                guard let id = p["id"] as? String else { continue }
                let models = (p["models"] as? [String]) ?? []
                if !models.isEmpty { result.append((id: id, models: models)) }
            }
            allProviders = result
            ModelProvidersCache.save(result)
        }
    }
}
