// MARK: - 设置：模型管理相关 Sheet（v3.0.80 自 SettingsView.swift 拆出，纯搬家无逻辑改动）
// 内容：provider 缓存 / 自定义模型组 / ModelSheet / CustomProviderEditSheet / AboutView / WechatChannelSheet / AgentModelSheet

import SwiftUI

// MARK: - v3.0.35 provider 模型列表缓存（微信通道 / Agent / 模型管理共用同一份）
//
// 问题背景：WechatChannelSheet / AgentModelSheet 每次打开都从后端拉
// /api/stream/model-providers，失败时 try? 静默吞错 → 列表永远显示"正在加载模型列表…"。
// 方案：成功拉取结果写入 UserDefaults，打开时先显示缓存（免转圈），后台刷新成功后替换。

enum ModelProvidersCache {
    static let key = "qingliao_providers_cache"

    /// 读取缓存（无缓存或解析失败返回空）
    static func load() -> [(id: String, models: [String])] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            return (id, (d["models"] as? [String]) ?? [])
        }
    }

    /// 写缓存（空列表不覆盖旧缓存——防止后端临时故障把缓存刷空）
    static func save(_ providers: [(id: String, models: [String])]) {
        guard !providers.isEmpty else { return }
        let arr: [[String: Any]] = providers.map { ["id": $0.id, "models": $0.models] }
        if let data = try? JSONSerialization.data(withJSONObject: arr) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - v3.0.74 自定义 provider 模型组（用户自主添加 BASE_URL/API Key，后端 custom_providers.json 存储，免更新 App）
struct CustomProviderItem: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let models: [String]
}

// MARK: - 模型管理（复刻 PWA/OpenCode Go 面板：分组 + 设为当前 + 同步列表）

struct ModelSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let current: String
    @State private var selected = ""
    @State private var syncing = false
    @State private var syncResult: String?
    // v3.9.35：每个 key（provider 分组）单独「重新拉取模型列表」——进行中集合（防重复点）
    @State private var refreshingProviders: Set<String> = []
    // 服务器同步的模型（分组展示）
    @State private var stepfunModels: [String] = []
    @State private var deepseekModels: [String] = []
    // v2.0.140：opencode-apple 第二组订阅（同步拉取）
    @State private var opencodeAppleModels: [String] = []
    // v3.0.4：SenseNova（商汤）订阅模型（同步拉取）
    @State private var sensenovaModels: [String] = []
    // v3.0.4：通用 provider 列表（后端 model-providers 聚合——新增 provider 免改版）
    @State private var allProviders: [(id: String, models: [String])] = []
    // v3.0.74：自定义 provider 模型组（后端 custom_providers.json——用户自主增删，免更新 App）
    @State private var customProviders: [CustomProviderItem] = []
    @State private var showAddCustomProvider = false
    // v3.0.4：用户手动隐藏的 provider（存 UserDefaults，可恢复）
    @State private var hiddenProviders: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "qingliao_hidden_providers") ?? [])
    // v3.0.82：内置 provider 真删确认弹窗（非 nil 时弹窗确认，确认后调后端删 config.yaml providers 段）
    @State private var confirmDeleteProvider: String?
    @State private var deletingProvider = false
    @State private var deleteResultMsg: String?
    // v3.0.4：用户手动隐藏的单个模型（"provider:model" 形式）
    @State private var hiddenModels: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "qingliao_hidden_models") ?? [])
    // v2.0.83：当前 provider（区分 opencode 的 deepseek 与官方 deepseek——同名模型不能同时勾）
    @AppStorage("qingliao_provider") private var currentProvider = "opencode"
    // v3.0.33：Agent 模型覆盖提示（配置了 agent 模型时，聊天实际走 agent 模型）
    @AppStorage(UserDefaultsKey.agentModel) private var agentModel = ""
    // v3.0.18：本地模型（Ollama 已安装，自主选择——动态拉取 /api/local/models）
    @State private var localInstalled: [String] = []
    // v3.0.10：视觉模型配置弹窗（模型管理内导航）
    @State private var showVisionModelSheet = false
    // v3.0.68：语音引擎（TTS）设置（总开关 + 模型 + 音色）—— 同步回 CloudConfig 静态配置
    @State private var ttsOn = CloudConfig.ttsEnabled
    @State private var ttsProvider = CloudConfig.ttsProvider
    @State private var ttsModel = CloudConfig.ttsModel
    @State private var ttsVoice = CloudConfig.ttsVoice
    // v3.9.9（用户反馈「TTS 语音太生硬」）：系统语音（关掉神经 TTS 时用）的音色 + 语速开放可调
    @State private var sysVoiceID = SpeechManager.systemVoiceID
    @State private var sysRateIndex = SpeechManager.systemRateIndex

    /// TTS 状态文案
    private var ttsStatusText: String {
        ttsOn ? "已开启：\(CloudConfig.ttsVoicesFor(provider: ttsProvider, model: ttsModel).first { $0.id == ttsVoice }?.name ?? ttsVoice)" : "关闭（使用系统语音）"
    }
    /// TTS 模型下拉选项（从用户模型列表筛支持 TTS 的；未同步则显示已知模型保底）
    private var ttsModelOptions: [(provider: String, model: String, label: String)] {
        CloudConfig.ttsModelOptions(from: allProviders)
    }
    /// 当前模型音色列表
    private var ttsVoiceOptions: [(name: String, id: String)] {
        CloudConfig.ttsVoicesFor(provider: ttsProvider, model: ttsModel)
    }
    /// v3.9.10 hotfix：系统音色列表改为 **@State 快照**，body 里绝不再枚举音色。
    /// v3.9.9 把它写成计算属性 → 每次 body 求值都调 `AVSpeechSynthesisVoice.speechVoices()`，
    /// 真机卡 3~7 秒（dSYM 符号化已确证到本文件）。现在只在 onAppear 里异步取一次。
    @State private var voiceOptions: [SpeechVoiceOption] = []
    @State private var voiceHintText = ""

    /// v2.0.131：opencode 同步模型显示名映射（无映射的用 id 本身）
    private let opencodeNames: [String: String] = [
        "deepseek-v4-flash": "DeepSeek V4 Flash",
        "deepseek-v4-pro": "DeepSeek V4 Pro",
        "kimi-k3": "Kimi K3",
        "kimi-k2.7-code": "Kimi K2.7 Code",
        "kimi-k2.6": "Kimi K2.6",
        "kimi-k2.5": "Kimi K2.5",
        "glm-5.3": "GLM 5.3",
        "glm-5.2": "GLM 5.2",
        "glm-5.1": "GLM 5.1",
        "glm-5": "GLM 5",
        "qwen3.8-max": "Qwen3.8 Max",
        "qwen3.7-max": "Qwen3.7 Max",
        "qwen3.7-plus": "Qwen3.7 Plus",
        "qwen3.6-plus": "Qwen3.6 Plus",
        "qwen3.5-plus": "Qwen3.5 Plus",
        "minimax-m3": "MiniMax M3",
        "minimax-m2.7": "MiniMax M2.7",
        "minimax-m2.5": "MiniMax M2.5",
        "mimo-v2.5-pro": "MiMo V2.5 Pro",
        "mimo-v2.5": "MiMo V2.5",
        "mimo-v2-pro": "MiMo V2 Pro",
        "mimo-v2-omni": "MiMo V2 Omni",
        "gpt-5.6-luna": "GPT-5.6 Luna",
        "grok-4.5": "Grok 4.5",
    ]

    /// v3.0.4：SenseNova（商汤）模型显示名映射
    private let sensenovaNames: [String: String] = [
        "sensenova-6.8-flash-lite": "SenseNova 6.8 Flash Lite",
        "sensenova-6.7-flash-lite": "SenseNova 6.7 Flash Lite",
        "sensenova-u1-fast": "SenseNova U1 Fast",
        "deepseek-v4-flash": "DeepSeek V4 Flash",
        "glm-5.2": "GLM 5.2",
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
            modelsStatusStrip
            agentModelNotice
            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    builtinProviderGroups
                    dynamicProviderGroups
                    hiddenProviderRestore
                    customProviderEntry
                    visionModelSection
                    ttsSection
                }
                .padding(.bottom, Spacing.md)
            }
        }
        .padding(18)
        .navigationTitle("模型管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                // v3.9.35：刷新改回系统裸按钮——与「完成」同款系统玻璃胶囊
                Button("刷新") { syncList() }
            }
        }
        .onAppear {
            selected = current
            // v3.9.10：音色目录异步取一次（枚举在后台线程；body 里不再有任何 AVFoundation 调用）
            Task {
                voiceOptions = await SpeechManager.voiceCatalog()
                voiceHintText = SpeechManager.systemVoiceHint
            }
            // v2.0.118：动态拉取本地已装模型（自主选择）
            Task {
                if let j = try? await auth.json("/api/local/models") {
                    localInstalled = (j["models"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "" }
                }
            }
            // 恢复上次同步的模型（UserDefaults 持久化，无需每次点同步）
            if let s = UserDefaults.standard.array(forKey: "qingliao_models_stepfun") as? [String] {
                stepfunModels = s
            }
            if let d = UserDefaults.standard.array(forKey: "qingliao_models_deepseek") as? [String] {
                deepseekModels = d
            }
            // v2.0.140：恢复第二组 opencode（apple）同步结果
            if let a = UserDefaults.standard.array(forKey: "qingliao_models_opencode_apple") as? [String] {
                opencodeAppleModels = a
            }
            // v3.0.4：恢复 SenseNova（商汤）同步结果
            if let sn = UserDefaults.standard.array(forKey: "qingliao_models_sensenova") as? [String] {
                sensenovaModels = sn
            }
            // v3.0.4：恢复已隐藏 provider/模型
            hiddenProviders = Set(UserDefaults.standard.stringArray(forKey: "qingliao_hidden_providers") ?? [])
            hiddenModels = Set(UserDefaults.standard.stringArray(forKey: "qingliao_hidden_models") ?? [])
            // v3.0.4：首次打开自动拉取通用 provider 列表（免手动同步）
            if allProviders.isEmpty {
                // v3.0.35：先展示缓存（有则免转圈/免空白），后台刷新替换
                let cached = ModelProvidersCache.load()   // v-review fix：缓存到局部变量，避免同一数据重复反序列化
                if !cached.isEmpty {
                    allProviders = cached
                }
                Task { await loadAllProviders() }
            }
            // v3.0.74：拉取自定义 provider（含 name/base_url/models，用于「自定义模型」管理区块渲染）
            Task { await loadCustomProviders() }
        }
        // v3.0.10：视觉模型配置弹窗（模型管理内导航）
        .sheet(isPresented: $showVisionModelSheet) {
            VisionModelSheet()
                .scrollContentBackground(.hidden)
        }
        // v3.0.74：添加自定义模型组表单弹窗（保存成功后刷新自定义区块）
        .sheet(isPresented: $showAddCustomProvider) {
            CustomProviderEditSheet {
                Task { await loadCustomProviders() }
            }
            .scrollContentBackground(.hidden)
        }
        // v3.0.82：内置 provider 删除确认弹窗（真删 Hermes config.yaml providers 段，被引用时后端拒绝）
        .alert("删除模型组", isPresented: Binding(
            get: { confirmDeleteProvider != nil },
            set: { if !$0 { confirmDeleteProvider = nil } }
        )) {
            Button("取消", role: .cancel) { confirmDeleteProvider = nil }
            Button("删除", role: .destructive) {
                if let pid = confirmDeleteProvider { deleteBuiltinProvider(pid) }
                confirmDeleteProvider = nil
            }
        } message: {
            Text("将从服务器配置中彻底删除「\(providerDisplayName(confirmDeleteProvider ?? ""))」及其全部模型。\n\n若该 provider 正被主模型/微信通道/Agent 引用，删除会被拒绝。\n用量看板对应卡片将同步消失，此操作不可撤销。")
        }
        }
    }

    // MARK: - 巨型 body 拆分（纯搬运）
    //
    // 由头：此 body 单块 351 行，是本仓已踩过两次的「Unable to type-check this
    // expression in reasonable time」高危形态（一次漏检 = 20 分钟 CI 循环）。
    // 这里按原注释分段把视图块原样搬成独立 @ViewBuilder 属性 —— **纯搬运**：视图顺序、
    // 层级、条件分支、闭包、修饰符逐字未变，渲染结果与拆分前一致，只为把类型检查表达式打小。

    /// 在线状态 + 同步结果 + 删除结果提示
    @ViewBuilder
    private var modelsStatusStrip: some View {
            // 在线状态 + 同步结果
            HStack(spacing: Spacing.xs) {
            Circle().fill(syncing ? Color.orange : Color.green).frame(width: 7, height: 7)
            Text(syncing ? "同步中..." : "模型服务在线")
                .font(.system(size: Typography.caption)).foregroundStyle(.secondary)
        }
        if let syncResult {
            Text(syncResult)
                .font(.system(size: Typography.caption))
                .foregroundStyle(syncResult.hasPrefix("✅") ? Color.green : Color.orange)
        }
        // v3.0.82：内置 provider 删除结果提示
        if let deleteResultMsg {
            Text(deleteResultMsg)
                .font(.system(size: Typography.caption))
                .foregroundStyle(deleteResultMsg.hasPrefix("✅") ? Color.green : Color.orange)
        }
    }

    /// Agent 模型覆盖提示
    @ViewBuilder
    private var agentModelNotice: some View {
        // v3.0.33：Agent 模型覆盖提示——配置了 agent 模型时，
        // 聊天实际走 agent 模型（视觉模型 > Agent 模型 > 主模型），此处选主模型不会生效
        if !agentModel.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("聊天实际使用 Agent 模型：\(agentModel)")
                        .font(.system(size: Typography.subhead, weight: .medium))
                    Text("配置了 Agent 模型时优先使用，这里设置主模型不生效；可在设置页「Agent 模型」改为跟随主模型")
                        .font(.system(size: Typography.tiny)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(Spacing.lg)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.8)
            )
        }
    }

    /// 内置 provider 分组（opencode / deepseek / stepfun / sensenova / 本地）
    @ViewBuilder
    private var builtinProviderGroups: some View {
        if !opencodeAppleModels.isEmpty {
            // v2.0.140：第二组 opencode 订阅（apple），同名模型按 provider 区分勾选
            groupSection("opencode（apple）", models: opencodeAppleModels.map { ($0, opencodeNames[$0] ?? $0, "opencode-apple") },
                         onRefresh: { refreshSingleProvider("opencode-apple") },
                         refreshing: refreshingProviders.contains("opencode-apple"))
        }
        if !deepseekModels.isEmpty {
            // v2.0.83：官方 API 分组标注（与 opencode 的 deepseek 区分）
            groupSection("deepseek（官方）", models: deepseekModels.map { ($0, $0, "deepseek") },
                         onRefresh: { refreshSingleProvider("deepseek") },
                         refreshing: refreshingProviders.contains("deepseek"))
        }
        if !stepfunModels.isEmpty {
            groupSection("stepfun", models: stepfunModels.map { ($0, $0, "stepfun") },
                         onRefresh: { refreshSingleProvider("stepfun") },
                         refreshing: refreshingProviders.contains("stepfun"))
        }
        // v3.0.4：SenseNova（商汤）订阅模型分组
        if !sensenovaModels.isEmpty {
            groupSection("sensenova（商汤）", models: sensenovaModels.map { ($0, sensenovaNames[$0] ?? $0, "sensenova") },
                         onRefresh: { refreshSingleProvider("sensenova") },
                         refreshing: refreshingProviders.contains("sensenova"))
        }
        // v2.0.118：本地模型（动态显示 Ollama 已安装模型——自主选择）
        if !localInstalled.isEmpty {
            groupSection("本地模型（断网兜底）", models: localInstalled.map { ($0, $0 + " · 本地", "local") })
        }
    }

    /// 通用 provider 分组（后端聚合，新增 provider 免改版）
    @ViewBuilder
    private var dynamicProviderGroups: some View {
        // v3.0.4：通用 provider 分组（后端聚合——新增 provider 免改版，自动出现）
        // 跳过已在上面硬编码渲染的 provider（避免重复），只渲染新增/未知的（如 xiaomi）
        ForEach(allProviders, id: \.id) { p in
            let hardcoded = ["opencode", "opencode-apple", "deepseek", "stepfun", "sensenova", "local"]
            // v3.0.74：自定义 provider 单独渲染（见 customProvidersSection），此处跳过避免重复
            let customIDs = Set(customProviders.map { $0.id })
            if !hardcoded.contains(p.id) && !customIDs.contains(p.id) && !hiddenProviders.contains(p.id) {
                if p.models.isEmpty {
                    // v3.4.x：key 健康自检——空 models 的 provider 主动提示 key 无效/未配置，而非静默消失
                    ProviderKeyIssueRow(name: providerDisplayName(p.id),
                                        onRetry: { refreshSingleProvider(p.id) },
                                        retrying: refreshingProviders.contains(p.id))
                        .padding(.bottom, Spacing.xs)
                } else {
                    groupSection(providerDisplayName(p.id),
                                 models: p.models.filter { !hiddenModels.contains("\(p.id):\($0)") }.map {
                                 ($0, providerModelDisplayName(p.id, $0), p.id) },
                                 onRefresh: { refreshSingleProvider(p.id) },
                                 refreshing: refreshingProviders.contains(p.id),
                                 onHideProvider: { toggleHideProvider(p.id) },
                                 onDeleteProvider: { confirmDeleteProvider = p.id })
                }
            }
        }
    }

    /// 隐藏 provider 恢复入口
    @ViewBuilder
    private var hiddenProviderRestore: some View {
        // 管理隐藏的 provider（恢复入口）
        if !hiddenProviders.isEmpty {
            Button {
                hiddenProviders.removeAll()
                UserDefaults.standard.set(Array(hiddenProviders), forKey: "qingliao_hidden_providers")
            } label: {
                Text("恢复全部隐藏的模型组")
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .padding(.top, Spacing.xs)
        }
    }

    /// 自定义模型组入口（分隔线 + customProvidersSection）
    @ViewBuilder
    private var customProviderEntry: some View {
        // v3.0.74：自定义模型组（用户自主添加 BASE_URL/API Key 模型组，存后端，免更新 App）
        Divider()
            .padding(.vertical, Spacing.xs)
        customProvidersSection
    }

    /// 视觉模型配置入口
    @ViewBuilder
    private var visionModelSection: some View {
        // v3.0.10：视觉模型配置（模型管理内导航）
        Divider()
            .padding(.vertical, Spacing.xs)
        VStack(alignment: .leading, spacing: 6) {
            Text("视觉模型")
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, Spacing.xs)
            HStack(spacing: 10) {
                Image(systemName: "eye.fill")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(visionModelDisplay)
                        .font(.system(size: Typography.subhead, weight: .medium))
                    Text("主模型不支持视觉时自动切换")
                        .font(.system(size: Typography.tiny)).foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(Spacing.lg)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                    .strokeBorder(Color.purple.opacity(Tint.strong), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
            .onTapGesture { showVisionModelSheet = true }
        }
    }

    /// 语音引擎 · TTS（总开关 + 音色下拉）
    @ViewBuilder
    private var ttsSection: some View {
        // v3.0.x：语音引擎（TTS）—— 总开关 + 音色下拉
        Divider()
            .padding(.vertical, Spacing.xs)
        VStack(alignment: .leading, spacing: 6) {
            Text("语音引擎 · TTS")
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, Spacing.xs)
            VStack(alignment: .leading, spacing: 8) {
                ttsVoiceHeaderRow
                if ttsOn {
                    ttsNeuralVoiceControls
                } else {
                    ttsSystemVoiceControls
                }
            }
            .padding(Spacing.lg)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                    .strokeBorder(ttsOn ? Color.indigo.opacity(0.35) : Color.primary.opacity(Tint.faint), lineWidth: 0.8)
            )
        }
    }

    /// TTS 总开关行
    @ViewBuilder
    private var ttsVoiceHeaderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 语音朗读")
                    .font(.system(size: Typography.subhead, weight: .medium))
                Text(ttsStatusText)
                    .font(.system(size: Typography.tiny)).foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: $ttsOn).labelsHidden().scaleEffect(0.8).tint(.green)
                .onChange(of: ttsOn) { _, new in
                    CloudConfig.setTTsEnabled(new)
                }
        }
    }

    /// 神经语音：模型下拉 + 音色下拉 + 说明
    @ViewBuilder
    private var ttsNeuralVoiceControls: some View {
        // 模型下拉（从用户模型列表筛支持 TTS 的）
        HStack(spacing: 8) {
            Text("模型")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: Binding(
                get: { "\(ttsProvider)|\(ttsModel)" },
                set: { raw in
                    let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
                    let pp = parts.count > 0 ? parts[0] : ttsProvider
                    let mm = parts.count > 1 ? parts[1] : ttsModel
                    ttsProvider = pp; ttsModel = mm
                    CloudConfig.setTTs(provider: pp, model: mm)
                    // 切模型 → 重置为该模型默认音色
                    let def = CloudConfig.ttsVoicesFor(provider: pp, model: mm).first?.id ?? ""
                    ttsVoice = def
                    CloudConfig.setTTsVoice(def)
                }
            )) {
                ForEach(ttsModelOptions.indices, id: \.self) { idx in
                    let opt = ttsModelOptions[idx]
                    Text(opt.label).tag("\(opt.provider)|\(opt.model)")
                }
            }
            .pickerStyle(.menu)
            .tint(.indigo)
        }
        // 音色下拉（随模型联动）
        HStack(spacing: 8) {
            Text("音色")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $ttsVoice) {
                ForEach(ttsVoiceOptions, id: \.id) { v in
                    Text(v.name).tag(v.id)
                }
            }
            .pickerStyle(.menu)
            .tint(.indigo)
            .onChange(of: ttsVoice) { _, new in
                CloudConfig.setTTsVoice(new)
            }
        }
        Text("开启后 AI 回复、语音指令将对讲朗读使用所选模型的神经语音；关闭则用系统语音。")
            .font(.system(size: Typography.tiny)).foregroundStyle(.tertiary)
    }

    /// 系统语音：音色 + 语速 + 说明
    @ViewBuilder
    private var ttsSystemVoiceControls: some View {
        // v3.9.9（用户反馈「TTS 语音太生硬」）：关掉神经语音时走系统语音，
        // 这里把**音色 + 语速**开放出来，并说清"系统语音怎么才能更自然"——
        // 「增强 / 优质」语音包只能在 iOS 设置里下载，App 不能代下。
        HStack(spacing: 8) {
            Text("系统音色")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $sysVoiceID) {
                Text("自动（最自然可用）").tag("")
                ForEach(voiceOptions) { opt in
                    Text(opt.label).tag(opt.id)
                }
            }
            .pickerStyle(.menu)
            .tint(.indigo)
            .onChange(of: sysVoiceID) { _, new in
                SpeechManager.setSystemVoiceID(new)
            }
        }
        HStack(spacing: 8) {
            Text("语速")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $sysRateIndex) {
                Text("慢").tag(0)
                Text("标准").tag(1)
                Text("快").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .onChange(of: sysRateIndex) { _, new in
                SpeechManager.setSystemRateIndex(new)
            }
        }
        Text(voiceHintText.isEmpty ? SpeechManager.systemVoiceHint : voiceHintText)
            .font(.system(size: Typography.tiny)).foregroundStyle(.tertiary)
    }

    /// v3.0.82：真删内置 provider（后端删 config.yaml providers 段；被引用时返回 error 提示）
    private func deleteBuiltinProvider(_ pid: String) {
        deletingProvider = true
        Task {
            defer { deletingProvider = false }
            do {
                let j = try await auth.json("/api/stream/builtin-providers", method: "POST",
                                           body: ["action": "delete", "id": pid])
                if (j["ok"] as? Bool) == true {
                    // 本地同步清理：清模型缓存 + 从当前列表移除
                    UserDefaults.standard.removeObject(forKey: "qingliao_models_\(pid)")
                    allProviders.removeAll { $0.id == pid }
                    ModelProvidersCache.save(allProviders)
                    deleteResultMsg = "✅ 已删除 \(providerDisplayName(pid))"
                } else {
                    deleteResultMsg = "⚠️ \(j["error"] as? String ?? "删除失败")"
                }
            } catch {
                deleteResultMsg = "⚠️ 删除失败：\(error.localizedDescription)"
            }
            await loadAllProviders()
        }
    }

    /// 分组标题 + 模型行（v3.0.4：可选 onHideProvider 显示分组隐藏按钮）
    private func groupSection(_ group: String, models: [(String, String, String)],
                              onRefresh: (() -> Void)? = nil,
                              refreshing: Bool = false,
                              onHideProvider: (() -> Void)? = nil,
                              onDeleteProvider: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(group)
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                // v3.9.35：按 key 重新拉取该组模型列表
                if let onRefresh {
                    Button {
                        onRefresh()
                    } label: {
                        if refreshing {
                            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: Typography.tiny))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if let onHideProvider {
                    Button {
                        onHideProvider()
                    } label: {
                        Image(systemName: "eye.slash")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                if let onDeleteProvider {
                    Button {
                        onDeleteProvider()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, Spacing.xs)
            ForEach(models, id: \.0) { m in
                modelRow(id: m.0, name: m.1, provider: m.2)
            }
        }
    }

    /// v3.0.4：provider 显示名（已知映射用中文名，未知用 id）
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

    /// v3.0.4：provider 内模型显示名（复用现有映射，未知用 id）
    private func providerModelDisplayName(_ pid: String, _ model: String) -> String {
        switch pid {
        case "opencode", "opencode-apple": return opencodeNames[model] ?? model
        case "sensenova": return sensenovaNames[model] ?? model
        default: return model
        }
    }

    /// v3.0.4：隐藏一个 provider 分组（存 UserDefaults，可"恢复全部"）
    private func toggleHideProvider(_ id: String) {
        hiddenProviders.insert(id)
        UserDefaults.standard.set(Array(hiddenProviders), forKey: "qingliao_hidden_providers")
    }

    private func modelRow(id: String, name: String, provider: String) -> some View {
        // v2.0.83：当前判定 = 模型 id + provider 双重匹配（opencode 与官方的 deepseek 同名不同源，不能同时勾）
        let isCur = selected == id && currentProvider == provider
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
                    setModel(id, provider: provider)
                } label: {
                    Text("设为当前")
                        .font(.system(size: Typography.caption, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.xs)
                        .glassPillStroke()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.lg)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                .strokeBorder(selected == id ? Color.accentColor.opacity(0.5) : Color.primary.opacity(Tint.faint),
                              lineWidth: 0.8)
        )
    }

    private func setModel(_ id: String, provider: String) {
        selected = id
        UserDefaults.standard.set(id, forKey: "qingliao_model")
        UserDefaults.standard.set(provider, forKey: "qingliao_provider")
    }

    /// 同步模型列表：stepfun/deepseek 官方端点可同步，opencode 保持本地预置
    private func syncList() {
        guard !syncing else { return }
        syncing = true
        syncResult = nil
        Task {
            // v3.0.34：4 个 provider 并发同步（async let），最坏 40s → ~10s（失效 key 快速失败）
            async let stepfun = fetchModels("stepfun")
            async let deepseek = fetchModels("deepseek")
            // v2.0.140：同步 opencode（apple）订阅
            async let opencodeApple = fetchModels("opencode-apple")
            // v3.0.4：同步 SenseNova（商汤）订阅模型
            async let sensenova = fetchModels("sensenova")
            let (s, d, oa, sn) = await (stepfun, deepseek, opencodeApple, sensenova)
            if let s {
                stepfunModels = s
                UserDefaults.standard.set(s, forKey: "qingliao_models_stepfun")
            }
            if let d {
                deepseekModels = d
                UserDefaults.standard.set(d, forKey: "qingliao_models_deepseek")
            }
            if let oa {
                opencodeAppleModels = oa
                UserDefaults.standard.set(oa, forKey: "qingliao_models_opencode_apple")
            }
            if let sn {
                sensenovaModels = sn
                UserDefaults.standard.set(sn, forKey: "qingliao_models_sensenova")
            }
            // v3.0.4：通用拉取全部 provider（含新增，免改版）
            await loadAllProviders()
            // v3.0.4 fix：syncResult 放在所有赋值之后，计数才准确（原在 sn 赋值前显示=旧值0）
            syncResult = "✅ 已同步（apple \(opencodeAppleModels.count) / stepfun \(stepfunModels.count) / deepseek \(deepseekModels.count) / sensenova \(sensenovaModels.count)）"
            syncing = false
        }
    }

    /// v3.9.35：按 key（单个 provider）重新拉取模型列表——内置组写回对应 @State + UserDefaults，聚合组写回 allProviders
    private func refreshSingleProvider(_ pid: String) {
        guard !refreshingProviders.contains(pid) else { return }
        refreshingProviders.insert(pid)
        Task {
            defer { refreshingProviders.remove(pid) }
            guard let j = try? await auth.json("/api/stream/sync-models?provider=\(pid)"),
                  (j["ok"] as? Bool) == true,
                  let list = j["models"] as? [String] else {
                syncResult = "⚠️ \(providerDisplayName(pid))：拉取失败（key 无效或网络异常）"
                return
            }
            switch pid {
            case "opencode-apple":
                opencodeAppleModels = list
                UserDefaults.standard.set(list, forKey: "qingliao_models_opencode_apple")
            case "deepseek":
                deepseekModels = list
                UserDefaults.standard.set(list, forKey: "qingliao_models_deepseek")
            case "stepfun":
                stepfunModels = list
                UserDefaults.standard.set(list, forKey: "qingliao_models_stepfun")
            case "sensenova":
                sensenovaModels = list
                UserDefaults.standard.set(list, forKey: "qingliao_models_sensenova")
            default:
                // 聚合 provider（xiaomi 等）：更新 allProviders 对应项
                if let idx = allProviders.firstIndex(where: { $0.id == pid }) {
                    allProviders[idx] = (id: pid, models: list)
                } else {
                    allProviders.append((id: pid, models: list))
                }
                ModelProvidersCache.save(allProviders)
            }
            syncResult = "✅ \(providerDisplayName(pid))：已拉取 \(list.count) 个模型"
        }
    }

    /// v3.9.35：自定义模型组按 key 重新拉取（后端 refresh 动作：用存好的 base_url+api_key 调 /models 并写回）
    private func refreshCustomProvider(_ id: String) {
        guard !refreshingProviders.contains(id) else { return }
        refreshingProviders.insert(id)
        Task {
            defer { refreshingProviders.remove(id) }
            guard let j = try? await auth.json("/api/stream/custom-providers", method: "POST",
                                               body: ["action": "refresh", "id": id]),
                  (j["ok"] as? Bool) == true else {
                syncResult = "⚠️ 自定义模型组：拉取失败（key 无效或网络异常）"
                return
            }
            await loadCustomProviders()
            syncResult = "✅ 自定义模型组：已重新拉取"
        }
    }


    private func fetchModels(_ provider: String) async -> [String]? {
        guard let j = try? await auth.json("/api/stream/sync-models?provider=\(provider)"),
              (j["ok"] as? Bool) == true,
              let list = j["models"] as? [String] else { return nil }
        return list
    }

    /// v3.0.4：通用拉取所有 provider + 模型（后端聚合接口——新 provider 免改版，自动出现）
    private func loadAllProviders() async {
        guard let j = try? await auth.json("/api/stream/model-providers?with_models=1"),
              (j["ok"] as? Bool) == true,
              let plist = j["providers"] as? [[String: Any]] else { return }
        var result: [(id: String, models: [String])] = []
        for p in plist {
            guard let id = p["id"] as? String else { continue }
            // v3.0.34：不再对空 models 逐个补拉 sync-models（N+1）——聚合接口已并发+缓存，
            // 失效 key 的 provider 补拉也是空/401，纯拖慢同步；直接采用聚合结果
            let models = (p["models"] as? [String]) ?? []
            result.append((id: id, models: models))
        }
        allProviders = result
        // v3.0.35：写缓存（微信通道/Agent/视觉模型共用），下次打开任何入口先显示缓存
        ModelProvidersCache.save(result)
    }


    /// v3.0.74：拉取自定义 provider 列表（后端定制 JSON，含 name/base_url/models）
    private func loadCustomProviders() async {
        guard let j = try? await auth.json("/api/stream/custom-providers"),
              let list = j["providers"] as? [[String: Any]] else { return }
        var arr: [CustomProviderItem] = []
        for p in list {
            guard let id = p["id"] as? String else { continue }
            let n = (p["name"] as? String) ?? ""
            let b = (p["base_url"] as? String) ?? ""
            let m = (p["models"] as? [String]) ?? []
            arr.append(CustomProviderItem(id: id, name: n, baseURL: b, models: m))
        }
        customProviders = arr
        // 同步刷新聚合 provider 列表（保证模型加载一致）
        await loadAllProviders()
    }

    /// v3.0.74：删除一个自定义 provider（后端删除 + 刷新）
    private func deleteCustomProvider(_ id: String) {
        Task {
            guard let j = try? await auth.json("/api/stream/custom-providers", method: "POST",
                                               body: ["action": "delete", "id": id]),
                  (j["ok"] as? Bool) == true else { return }
            await loadCustomProviders()
        }
    }

    /// v3.0.74：自定义模型管理区块（列表 + 添加入口）
    private var customProvidersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("自定义模型")
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showAddCustomProvider = true
                } label: {
                    // v3.9.4：只留文字 + 胶囊（去图标）
                    Text("添加")
                        .font(.system(size: Typography.caption, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.xs)
                        .glassPillStroke()
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, Spacing.xs)
            if customProviders.isEmpty {
                Text("添加你自己的模型组（Base URL + API Key），自定义厂商/模型免更新 App 即用")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, Spacing.xs)
            } else {
                ForEach(customProviders) { cp in
                    customProviderGroup(cp)
                }
            }
        }
    }

    /// v3.0.74：单个自定义模型组（复用 groupSection，组头带删除按钮）
    private func customProviderGroup(_ cp: CustomProviderItem) -> some View {
        groupSection(cp.name.isEmpty ? cp.id : cp.name,
                     models: cp.models.map { ($0, $0, cp.id) },
                     onRefresh: { refreshCustomProvider(cp.id) },
                     refreshing: refreshingProviders.contains(cp.id),
                     onDeleteProvider: { deleteCustomProvider(cp.id) })
    }

    /// v3.0.10：视觉模型显示文案（模型管理内导航行）
    private var visionModelDisplay: String {
        // v3.9.26：主模型 + provider 统一取源（云端走 activeConfig，本地走 UserDefaults）
        let main = CloudConfig.mainModelAndProvider
        guard CloudConfig.visionFallbackEnabled else { return "视觉模型 · 已关闭" }
        if CloudConfig.modelSupportsVision(main.model, provider: main.provider) { return "视觉模型 · 主模型支持" }
        guard let vm = CloudConfig.localVisionModel, !vm.isEmpty else { return "视觉模型 · 未配置" }
        return "视觉模型 · \(vm)"
    }
}



// MARK: - v3.0.74 添加自定义模型组表单（对齐云端 CloudProviderSheet 风格）

struct CustomProviderEditSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void

    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelsText = ""
    @State private var saving = false
    @State private var errMsg: String?
    // v3.0.82：一键拉取 /models（OpenAI 兼容端点）→ 勾选保存
    @State private var fetching = false
    @State private var fetchedModels: [String] = []
    @State private var selectedModels: Set<String> = []
    @State private var fetchMsg: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("连接信息") {
                    TextField("名称（如 我的厂商）", text: $name)
                    TextField("Base URL（https://.../v1）", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    // v3.0.82：填完 base_url+key 一键拉取模型列表
                    Button {
                        Task { await fetchModels() }
                    } label: {
                        HStack {
                            Label(fetching ? "拉取中…" : "拉取模型列表", systemImage: "arrow.down.circle")
                            Spacer()
                            if fetching { ProgressView().scaleEffect(0.8) }
                        }
                    }
                    .disabled(baseURL.isEmpty || apiKey.isEmpty || fetching)
                    if let fetchMsg {
                        Text(fetchMsg)
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(fetchMsg.hasPrefix("✅") ? Color.green : Color.orange)
                    }
                }
                // v3.0.82：拉取成功 → 勾选列表（全选/清空快捷键）
                if !fetchedModels.isEmpty {
                    Section {
                        HStack {
                            Text("勾选要启用的模型（\(selectedModels.count)/\(fetchedModels.count)）")
                                .font(.system(size: Typography.subhead, weight: .medium))
                            Spacer()
                            Button(selectedModels.count == fetchedModels.count ? "清空" : "全选") {
                                if selectedModels.count == fetchedModels.count {
                                    selectedModels.removeAll()
                                } else {
                                    selectedModels = Set(fetchedModels)
                                }
                            }
                            .font(.system(size: Typography.subhead))
                            .buttonStyle(.borderless)
                        }
                        ForEach(fetchedModels, id: \.self) { m in
                            Button {
                                if selectedModels.contains(m) { selectedModels.remove(m) } else { selectedModels.insert(m) }
                            } label: {
                                HStack {
                                    Text(m)
                                        .font(.system(size: Typography.subhead))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if selectedModels.contains(m) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: Typography.subhead, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
                Section("模型名（每行一个）") {
                    TextEditor(text: $modelsText)
                        .frame(minHeight: fetchedModels.isEmpty ? 120 : 44)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .overlay(alignment: .topLeading) {
                            if modelsText.isEmpty && fetchedModels.isEmpty {
                                Text("deepseek-v4-flash\nglm-5.2\n…\n\n（或点上方「拉取模型列表」自动填充）")
                                    .font(.system(size: Typography.subhead))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, Spacing.md)
                                    .padding(.leading, Spacing.xs)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                if let errMsg {
                    Text(errMsg)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.red)
                }
                Section {
                    Button(saving ? "保存中…" : "保存") {
                        Task { await save() }
                    }
                    .disabled(name.isEmpty || baseURL.isEmpty || apiKey.isEmpty
                              || effectiveModels.isEmpty || saving)
                }
            }
            .navigationTitle("添加自定义模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// v3.0.82：生效模型 = 勾选结果（拉取过）∪ 手填行（兼容手动输入流程）
    private var effectiveModels: [String] {
        var models = selectedModels.sorted()
        let manual = modelsText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for m in manual where !models.contains(m) { models.append(m) }
        return models
    }

    /// v3.0.82：调后端拉取 OpenAI 兼容 /models（由后端请求避免 App 端 CORS/网络差异）
    private func fetchModels() async {
        fetching = true
        fetchMsg = nil
        defer { fetching = false }
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        do {
            let j = try await auth.json("/api/stream/fetch-models", method: "POST",
                                       body: ["base_url": base, "api_key": apiKey])
            if (j["ok"] as? Bool) == true, let list = j["models"] as? [String], !list.isEmpty {
                fetchedModels = list
                selectedModels = Set(list)   // 默认全选
                fetchMsg = "✅ 拉取到 \(list.count) 个模型，请勾选"
            } else {
                fetchMsg = "⚠️ \(j["error"] as? String ?? "未拉取到模型，可手动输入")"
            }
        } catch {
            fetchMsg = "⚠️ 拉取失败：\(error.localizedDescription)"
        }
    }

    private func save() async {
        saving = true
        errMsg = nil
        defer { saving = false }
        let models = effectiveModels
        let provider: [String: Any] = [
            "id": "custom-\(Int(Date().timeIntervalSince1970))",
            "name": name,
            "base_url": baseURL,
            "api_key": apiKey,
            "models": models
        ]
        do {
            let j = try await auth.json("/api/stream/custom-providers", method: "POST",
                                        body: ["action": "add", "provider": provider])
            if (j["ok"] as? Bool) == true {
                onSaved()
                dismiss()
            } else {
                errMsg = "保存失败：\(j["error"] as? String ?? "未知错误")"
            }
        } catch {
            errMsg = "保存失败：\(error.localizedDescription)"
        }
    }
}
// MARK: - 关于轻聊（软件介绍页）

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthStore.self) private var auth   // v3.0.8：拉 Hermes 版本
    // v3.0.1：云端模式文案区分（本地 AI = 连接自家 NAS；云端 AI = 直连大模型 API）
    var isCloud: Bool = false
    // v3.0.8：Hermes 容器版本（项目版本说明，从 NAS /api/nas/status 实时读）
    @State private var hermesVersion = "读取中…"

    var body: some View {
        VStack(spacing: 14) {
            // v2.0.34：关于页换新图标（淡青底微笑气泡，与 AppIcon 同款）
            Image("AboutLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)

            Text("轻聊")
                .font(.system(size: Typography.titleXL, weight: .bold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.0")")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)

            Divider().padding(.horizontal, 30)

            VStack(alignment: .leading, spacing: 10) {
                // v3.0.8：项目版本说明（iOS 客户端版本）
                aboutRow("项目版本", "轻聊 3.0 · iOS 客户端 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                // v3.0.3：统一介绍框架——顶部 App 概述（两端一致），下方「当前模式」针对云端/本地分别说明
                aboutRow("产品", "轻聊 —— 面向家庭的 AI 智能助手，SwiftUI 原生客户端，支持「本地 AI」与「云端 AI」两种形态，数据按模式本地保存。")
                appModeRow(isCloud)
                aboutRow("功能", isCloud
                          ? "流式对话 · 语音输入 · 会话本地保存 · 天气查询"
                          : "流式对话 · 语音对话 · 图片理解 · 知识库检索 · 会话同步 · NAS 面板 · Docker 管理 · 智能家居 · 定时任务")
                aboutRow("模型", isCloud
                          ? "DeepSeek / Kimi / GLM / MiniMax / OpenAI 等 OpenAI 兼容服务多厂商接入"
                          : "DeepSeek V4 / Kimi / StepFun 多模型聚合（OpenCode Go + 官方 API）")
                aboutRow("架构", isCloud
                          ? "SwiftUI 原生 · 轻聊 3.0 云端模式 · 直连云端 API（Wi-Fi / 蜂窝均可）"
                          : "SwiftUI 原生 · Hermes Agent · 自建 NAS 后端（连接自家 NAS）")
                // v3.0.8：Hermes Agent 版本号固定放在介绍最后一行（本地模式读容器实时版本）
                if !isCloud {
                    HStack(alignment: .top) {
                        Text("Hermes Agent")
                            .font(.system(size: Typography.subhead, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 68, alignment: .leading)
                        Text(hermesVersion)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: Typography.subhead))
            .padding(.horizontal, 24)

            Spacer()
            Text("Nous Research · Hermes Agent")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
                .padding(.bottom, Spacing.xl)
        }
        .padding(.top, 22)
        // v3.0.8：本地模式拉取 Hermes 版本
        .task {
            guard !isCloud else { return }
            if let j = try? await auth.json("/api/nas/status"),
               let svc = j["services"] as? [String: Any],
               let v = svc["hermes_version"] as? String, !v.isEmpty {
                hermesVersion = v
            } else {
                hermesVersion = "未获取到"
            }
        }
    }

    /// v3.0.3：当前模式行（云端/本地分别说明，含差异化介绍）
    @ViewBuilder
    private func appModeRow(_ cloud: Bool) -> some View {
        if cloud {
            aboutRow("当前模式", "云端 AI —— 无需本地服务器，直连主流大模型 API，配置即用，数据全部保存在手机本地。")
        } else {
            aboutRow("当前模式", "本地 AI —— 连接自家 NAS 上的 Hermes Agent，对话/读图/语音/知识库/智能家居全掌控。")
        }
    }

    private func aboutRow(_ title: String, _ content: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(content)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - v3.0.19 微信通道模型设置（方案B：读写 Hermes wechat-profile，微信通道专属模型）

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
                        Text("当前微信通道模型")
                            .font(.system(size: Typography.caption)).foregroundStyle(.secondary)
                    }
                    Text(currentModel)
                        .font(.system(size: Typography.body, weight: .semibold))
                    Text("设置后重启 Hermes 生效（约 10-30 秒），只影响微信通道，其他通道不受影响。")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.tertiary)
                }
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))

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
                            VStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: Typography.display))
                                    .foregroundStyle(.orange)
                                Text("模型列表加载失败")
                                    .font(.system(size: Typography.subhead, weight: .medium))
                                Text("请检查网络或后端服务后重试")
                                    .font(.system(size: Typography.caption)).foregroundStyle(.secondary)
                                Button {
                                    loadFailed = false
                                    Task { await loadProviders() }
                                } label: {
                                    Text("重试")
                                        .font(.system(size: Typography.subhead, weight: .medium))
                                        .padding(.horizontal, 18).padding(.vertical, Spacing.sm)
                                        .glassPillStroke()
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.top, 30)
                        } else {
                            ProgressView()
                                .padding(.top, 30)
                            Text("正在加载模型列表…")
                                .font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
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
                                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                                            .clipShape(RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
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
        .navigationTitle("微信通道模型")
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

    /// 拉当前微信通道模型 + 全部 provider 模型列表
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

    /// 拉当前微信通道模型（独立失败不影响模型列表）
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

    /// 保存微信通道模型（POST /api/channel/model → 后端改 wechat-profile + 重启 gateway）
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
                    saveResult = "✅ 已设置：\(model)（gateway 重启后生效，约 10-30 秒）"
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
    private let opencodeNames: [String: String] = [
        "deepseek-v4-flash": "DeepSeek V4 Flash",
        "deepseek-v4-flash-free": "DeepSeek V4 Flash Free",
        "deepseek-v4-pro": "DeepSeek V4 Pro",
        "kimi-k3": "Kimi K3",
        "kimi-k2.7-code": "Kimi K2.7 Code",
        "kimi-k2.6": "Kimi K2.6",
        "kimi-k2.5": "Kimi K2.5",
        "glm-5.3": "GLM 5.3",
        "glm-5.2": "GLM 5.2",
        "glm-5.1": "GLM 5.1",
        "glm-5": "GLM 5",
        "qwen3.8-max": "Qwen3.8 Max",
        "qwen3.7-max": "Qwen3.7 Max",
        "qwen3.7-plus": "Qwen3.7 Plus",
        "qwen3.6-plus": "Qwen3.6 Plus",
        "qwen3.5-plus": "Qwen3.5 Plus",
        "minimax-m3": "MiniMax M3",
        "minimax-m2.7": "MiniMax M2.7",
        "minimax-m2.5": "MiniMax M2.5",
        "mimo-v2.5-pro": "MiMo V2.5 Pro",
        "mimo-v2.5": "MiMo V2.5",
        "mimo-v2-pro": "MiMo V2 Pro",
        "mimo-v2-omni": "MiMo V2 Omni",
        "gpt-5.6-luna": "GPT-5.6 Luna",
        "grok-4.5": "Grok 4.5",
    ]

    private let sensenovaNames: [String: String] = [
        "sensenova-6.8-flash-lite": "SenseNova 6.8 Flash Lite",
        "sensenova-6.7-flash-lite": "SenseNova 6.7 Flash Lite",
        "sensenova-u1-fast": "SenseNova U1 Fast",
        "deepseek-v4-flash": "DeepSeek V4 Flash",
        "glm-5.2": "GLM 5.2",
    ]

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
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
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
                                VStack(spacing: 10) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.system(size: Typography.display))
                                        .foregroundStyle(.orange)
                                    Text("模型列表加载失败")
                                        .font(.system(size: Typography.subhead, weight: .medium))
                                    Text("请检查网络或后端服务后重试")
                                        .font(.system(size: Typography.caption)).foregroundStyle(.secondary)
                                    Button {
                                        loadFailed = false
                                        Task { await loadAllProviders() }
                                    } label: {
                                        Text("重试")
                                            .font(.system(size: Typography.subhead, weight: .medium))
                                            .padding(.horizontal, 18).padding(.vertical, Spacing.sm)
                                            .glassPillStroke()
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.top, 30)
                            } else {
                                ProgressView()
                                    .padding(.top, 30)
                                Text("正在加载模型列表…")
                                    .font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
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
            .padding(18)
            .navigationTitle("Agent 模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        agentModel = selected
                        agentProvider = selectedProvider
                        dismiss()
                    }
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
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
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
        case "opencode", "opencode-apple": return opencodeNames[model] ?? model
        case "sensenova": return sensenovaNames[model] ?? model
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
