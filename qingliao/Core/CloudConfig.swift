import Foundation
import Security

// MARK: - v3.0 云端模式配置（无本地服务器用户）

/// 模式：本地 AI（走自家 NAS 后端）/ 云端 AI（直连大模型 API）
enum QingliaoMode: String {
    case local = "local"     // 2.0 现有模式：连 NAS 后端
    case cloud = "cloud"     // 3.0 新模式：直连 OpenAI 兼容端点
}

/// 云端模型厂商预设（OpenAI 兼容端点）
struct CloudProviderPreset: Identifiable {
    let id: String           // 内部 id（也作 UserDefaults key 后缀）
    let name: String         // 显示名
    let baseURL: String      // 默认 base_url
    let defaultModel: String // 默认模型
    let apiKeyHint: String   // key 格式提示
    var supportsVision: Bool = false   // v3.0.4：默认模型是否支持视觉
    var keyless: Bool = false           // v3.0.57：keyless 免费档（无需 apiKey）

    /// 预置厂商列表（可扩展：插件/未来版本可追加自定义 preset）
    static let presets: [CloudProviderPreset] = [
        CloudProviderPreset(id: "deepseek", name: "DeepSeek",
                            baseURL: "https://api.deepseek.com/v1",
                            defaultModel: "deepseek-chat",
                            apiKeyHint: "sk-..."),
        CloudProviderPreset(id: "kimi", name: "Kimi (Moonshot)",
                            baseURL: "https://api.moonshot.cn/v1",
                            defaultModel: "moonshot-v1-8k",
                            apiKeyHint: "sk-..."),
        CloudProviderPreset(id: "glm", name: "智谱 GLM",
                            baseURL: "https://open.bigmodel.cn/api/paas/v4",
                            defaultModel: "glm-4-flash",
                            apiKeyHint: "从智谱开放平台获取"),
        CloudProviderPreset(id: "minimax", name: "MiniMax",
                            baseURL: "https://api.minimax.chat/v1",
                            defaultModel: "MiniMax-Text-01",
                            apiKeyHint: "从 MiniMax 开放平台获取"),
        CloudProviderPreset(id: "openai", name: "OpenAI",
                            baseURL: "https://api.openai.com/v1",
                            defaultModel: "gpt-4o-mini",
                            apiKeyHint: "sk-...",
                            supportsVision: true),   // v3.0.4：gpt-4o 系列支持视觉
        // v3.0.4：商汤日日新 SenseNova（Token Plan 免费，OpenAI 兼容）
        // 模型列表（fetchModels 动态拉）：sensenova-6.7-flash-lite / deepseek-v4-flash /
        // glm-5.2 / sensenova-u1-fast / sensenova-6.8-flash-lite
        CloudProviderPreset(id: "sensenova", name: "SenseNova(商汤)",
                            baseURL: "https://token.sensenova.cn/v1",
                            defaultModel: "deepseek-v4-flash",
                            apiKeyHint: "sensenova.cn 控制台获取"),
        // v3.0.44：小米 MiMo Token 计划（token-plan-cn.xiaomimimo.com）
        // ⚠️ 模型名必须是网关支持的（mimo-v2.5 系）；填 MiMo-7B-RL 这类会 401/400（已实踩）
        CloudProviderPreset(id: "mimo", name: "小米 MiMo",
                            baseURL: "https://token-plan-cn.xiaomimimo.com/v1",
                            defaultModel: "mimo-v2.5",
                            apiKeyHint: "米家/小米开放平台 Token 计划获取 (tp-...)"),
        // v3.0.57：OpenCode 免费档（keyless，免任何 Key）——Hermes 内置 opencode-free
        CloudProviderPreset(id: "opencode-free", name: "OpenCode 免费(免Key)",
                            baseURL: "https://opencode.ai/zen/v1", defaultModel: "nemotron-3.5-lightning-free",
                            apiKeyHint: "免 Key（Hermes keyless 免费档）", keyless: true),
        CloudProviderPreset(id: "custom", name: "自定义 (OpenAI 兼容)",
                            baseURL: "",
                            defaultModel: "",
                            apiKeyHint: "任意 OpenAI 兼容服务"),
    ]
}

/// 云端配置（单个厂商连接信息）
struct CloudProviderConfig: Codable, Identifiable {
    var providerID: String      // 对应 preset id 或 "custom"
    var name: String
    var baseURL: String
    var apiKey: String
    var model: String
    var supportsVision: Bool = false   // v3.0.4：是否支持视觉（图片降级判断）
    var keyless: Bool = false           // v3.0.57：keyless 免费档（无需 apiKey）

    var id: String { providerID }   // v3.0: ForEach 需要 Identifiable
}

/// 云端配置存储（UserDefaults + Keychain）
/// - 配置列表存 UserDefaults（不含 key）
/// - api_key 存 Keychain（勿落 UserDefaults，防明文泄露）
@MainActor
@Observable
final class CloudConfig {
    static let shared = CloudConfig()

    /// 当前模式（本地 AI / 云端 AI）
    var mode: QingliaoMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "qingliao_mode") }
    }

    /// 已保存的厂商配置（不含 key，key 在 Keychain）
    private(set) var providers: [CloudProviderConfig] = []

    /// 当前选中的厂商 id
    var activeProviderID: String {
        didSet { UserDefaults.standard.set(activeProviderID, forKey: "qingliao_cloud_provider") }
    }

    private let defaults = UserDefaults.standard
    private let providersKey = "qingliao_cloud_providers"
    private let keychainPrefix = "qingliao_cloud_key_"

    init() {
        mode = QingliaoMode(rawValue: UserDefaults.standard.string(forKey: "qingliao_mode") ?? "") ?? .local
        activeProviderID = UserDefaults.standard.string(forKey: "qingliao_cloud_provider") ?? ""
        loadProviders()
        // 无厂商时预置一个 DeepSeek 空配置，方便首次进入
        if providers.isEmpty {
            let p = CloudProviderPreset.presets[0]
            providers.append(CloudProviderConfig(providerID: p.id, name: p.name,
                                                 baseURL: p.baseURL, apiKey: "", model: p.defaultModel))
            saveProviders()
            activeProviderID = p.id
        }
    }

    var isCloudMode: Bool { mode == .cloud }

    /// 切换模式（云端→本地 或反之）
    func setMode(_ m: QingliaoMode) { mode = m }

    /// 当前生效的云端配置（含 Keychain key）
    var activeConfig: CloudProviderConfig? {
        guard let idx = providers.firstIndex(where: { $0.providerID == activeProviderID }) else { return nil }
        var c = providers[idx]
        c.apiKey = keychainRead(keychainPrefix + c.providerID)
        return c
    }

    // MARK: - 厂商配置 CRUD

    func saveProvider(_ c: CloudProviderConfig) {
        if let idx = providers.firstIndex(where: { $0.providerID == c.providerID }) {
            providers[idx] = c
        } else {
            providers.append(c)
        }
        if !c.apiKey.isEmpty {
            keychainWrite(keychainPrefix + c.providerID, c.apiKey)
        }
        saveProviders()
    }

    func removeProvider(id: String) {
        providers.removeAll { $0.providerID == id }
        keychainDelete(keychainPrefix + id)
        saveProviders()
        if activeProviderID == id {
            activeProviderID = providers.first?.providerID ?? ""
        }
    }
    /// v3.0.57：确保 opencode-free keyless 免费档已在 providers 并置为 active（无则从 preset 添加）
    @discardableResult
    func activateFreeProvider() -> CloudProviderConfig? {
        guard let pre = CloudProviderPreset.presets.first(where: { $0.keyless }) else { return nil }
        var cfg = providers.first(where: { $0.providerID == pre.id })
        if cfg == nil {
            cfg = CloudProviderConfig(providerID: pre.id, name: pre.name,
                                      baseURL: pre.baseURL, apiKey: "", model: pre.defaultModel,
                                      supportsVision: pre.supportsVision, keyless: true)
            providers.append(cfg!)
            saveProviders()
        }
        activeProviderID = pre.id
        return cfg
    }


    /// 校验云端配置是否可用（登录/聊天前）
    var isConfigured: Bool {
        guard let c = activeConfig, !c.baseURL.isEmpty, !c.model.isEmpty else { return false }
        // v3.0.57：keyless 免费档（opencode-free）无需 apiKey
        if c.keyless { return true }
        guard !c.apiKey.isEmpty else { return false }
        return true
    }

    // MARK: - 私有

    private func loadProviders() {
        if let data = defaults.data(forKey: providersKey),
           let list = try? JSONDecoder().decode([CloudProviderConfig].self, from: data) {
            // v3.0.5 review fix：从 UserDefaults 取出一律视为无 key（key 只在 Keychain），
            providers = list.map { var c = $0; c.apiKey = ""; return c }
        }
    }

    private func saveProviders() {
        // v3.0.5 review fix（安全）：落盘前清空 apiKey——key 只存 Keychain，UserDefaults 绝不落明文
        let sanitized = providers.map { var c = $0; c.apiKey = ""; return c }
        if let data = try? JSONEncoder().encode(sanitized) {
            defaults.set(data, forKey: providersKey)
        }
    }

    private func keychainWrite(_ key: String, _ value: String) {
        guard !value.isEmpty else { return }
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.qingliao.app.cloud",
            kSecAttrAccount as String: key,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func keychainRead(_ key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.qingliao.app.cloud",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func keychainDelete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.qingliao.app.cloud",
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// v3.0.5 review fix：按模型名判断是否视觉模型（切模型后实时更新，避免预设默认模型脱钩）
    /// v3.0.32 fix：minimax-m3 / glm-5.x 误判为不支持视觉 → 发图被视觉模型顶替
    /// （用户主模型选 M3/GLM-5 却生效视觉模型）——判定补全：minimax 全系 + glm-5 全系
    /// 命中特征：gpt-4o / gpt-5 / -vision / -o（omni）/ 多模态 / minimax（M 系列全系）/ glm-4v / glm-5.x / u1 / flash-lite(部分)
    static func modelSupportsVision(_ model: String) -> Bool {
        let m = model.lowercased()
        if m.contains("gpt-4o") || m.contains("gpt-5") || m.contains("vision")
            || m.contains("-omni") || m.contains("omni") || m.contains("multimodal")
            || m.contains("u1") || m.contains("glm-4v") || m.contains("flash-lite")
            || m.contains("step") || m.contains("stepfun") {
            return true
        }
        // MiniMax M 系列（M1/M2/M2.x/M3 等）全系支持多模态视觉
        if m.contains("minimax-") {
            return true
        }
        // GLM-5.x 全系支持视觉（glm-5 / 5.1 / 5.2 / 5.3）
        if m.contains("glm-5") {
            return true
        }
        // MiMo-V2.5 原生多模态（支持文本/图片/视频/音频）
        if m.contains("mimo") {
            return true
        }
        return false
    }

    // MARK: - v3.0.10 本地视觉模型配置

    /// 本地模式视觉模型 UserDefaults key
    private static let visionModelKey = "qingliao_vision_model"
    private static let visionProviderKey = "qingliao_vision_provider"
    private static let visionEnabledKey = "qingliao_vision_fallback"

    /// 当前配置的视觉模型名（nil = 未配置）
    static var localVisionModel: String? {
        UserDefaults.standard.string(forKey: visionModelKey)
    }
    /// 当前配置的视觉模型 provider
    static var localVisionProvider: String {
        UserDefaults.standard.string(forKey: visionProviderKey) ?? "opencode"
    }
    /// 视觉模型自动切换开关（默认开）
    static var visionFallbackEnabled: Bool {
        UserDefaults.standard.object(forKey: visionEnabledKey) as? Bool ?? true
    }

    /// 设置视觉模型
    static func setVisionModel(_ model: String, provider: String) {
        UserDefaults.standard.set(model, forKey: visionModelKey)
        UserDefaults.standard.set(provider, forKey: visionProviderKey)
    }

    /// 清除视觉模型配置
    static func clearVisionModel() {
        UserDefaults.standard.removeObject(forKey: visionModelKey)
        UserDefaults.standard.removeObject(forKey: visionProviderKey)
    }

    /// 设置视觉模型自动切换开关
    static func setVisionFallbackEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: visionEnabledKey)
    }

    /// v3.0.10：判断发送图片时应使用哪个模型
    /// - 如果主模型支持视觉 → 返回 nil（用主模型）
    /// - 如果主模型不支持视觉且配置了视觉模型 → 返回视觉模型
    /// - 否则 → 返回 nil（降级为文本，保持现有行为）
    static func effectiveVisionModel() -> (model: String, provider: String)? {
        guard visionFallbackEnabled else { return nil }
        guard let visionModel = localVisionModel, !visionModel.isEmpty else { return nil }
        // 如果主模型已支持视觉，无需切换
        let mainModel = UserDefaults.standard.string(forKey: "qingliao_model") ?? ""
        if modelSupportsVision(mainModel) { return nil }
        return (visionModel, localVisionProvider)
    }

    // MARK: - v3.0.68 语音引擎（TTS）配置 —— 总开关 + 模型 + 音色

    private static let ttsEnabledKey = "qingliao_tts_enabled"
    private static let ttsProviderKey = "qingliao_tts_provider"
    private static let ttsModelKey = "qingliao_tts_model"
    private static let ttsVoiceKey = "qingliao_tts_voice"
    // 默认：小米 mimo-v2.5-tts
    private static let ttsDefaultProvider = "xiaomi"
    private static let ttsDefaultModel = "mimo-v2.5-tts"
    private static let ttsDefaultVoice = "mimo_default"

    /// TTS 总开关（默认关 = 用系统 AVSpeechSynthesizer；开 = 用云端神经 TTS）
    static var ttsEnabled: Bool {
        UserDefaults.standard.object(forKey: ttsEnabledKey) as? Bool ?? true   // v3.0.78：默认开启大模型 TTS
    }
    static var ttsProvider: String {
        UserDefaults.standard.string(forKey: ttsProviderKey) ?? ttsDefaultProvider
    }
    static var ttsModel: String {
        UserDefaults.standard.string(forKey: ttsModelKey) ?? ttsDefaultModel
    }
    /// 当前音色名（默认随所选模型）
    static var ttsVoice: String {
        UserDefaults.standard.string(forKey: ttsVoiceKey) ?? ttsVoicesFor(provider: ttsProvider, model: ttsModel).first?.id ?? ttsDefaultVoice
    }

    static func setTTsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: ttsEnabledKey)
    }
    static func setTTs(provider: String, model: String) {
        UserDefaults.standard.set(provider, forKey: ttsProviderKey)
        UserDefaults.standard.set(model, forKey: ttsModelKey)
    }
    static func setTTsVoice(_ voice: String) {
        UserDefaults.standard.set(voice, forKey: ttsVoiceKey)
    }

    /// v3.0.68：支持 TTS 的模型列表（可扩展，新增 TTS 模型只需追加此数组）
    private static let _ttsSupported: [(provider: String, model: String, label: String)] = [
        ("xiaomi", "mimo-v2.5-tts", "小米 MiMo"),
        ("zai", "glm-tts", "智谱 GLM"),
    ]
    /// 公开访问器（供 UI 动态读取，未来支持插件追加）
    static var ttsSupported: [(provider: String, model: String, label: String)] {
        _ttsSupported
    }

    /// 小米 mimo-v2.5-tts 预置音色
    static let xiaomiTtsVoices: [(name: String, id: String)] = [
        ("MiMo-默认", "mimo_default"), ("冰糖（女）", "冰糖"), ("茉莉（女）", "茉莉"),
        ("苏打（男）", "苏打"), ("白桦（男）", "白桦"), ("Mia（英·女）", "Mia"),
        ("Chloe（英·女）", "Chloe"), ("Milo（英·男）", "Milo"), ("Dean（英·男）", "Dean"),
    ]
    /// 智谱 glm-tts 预置音色（官方合法 id：female/male）
    static let zaiTtsVoices: [(name: String, id: String)] = [
        ("女声", "female"), ("男声", "male"),
    ]

    /// 按模型返回音色列表
    static func ttsVoicesFor(provider: String, model: String) -> [(name: String, id: String)] {
        provider == "zai" ? zaiTtsVoices : xiaomiTtsVoices
    }
    /// 按 provider/model 过滤支持 TTS 的模型（allProviders 传入）——只显示已同步到模型列表（=配置了 key）的，防选了但调用失败
    static func ttsModelOptions(from providers: [(id: String, models: [String])]) -> [(provider: String, model: String, label: String)] {
        let configured = providers.filter { !$0.models.isEmpty }
        return ttsSupported.filter { opt in
            configured.contains { $0.id == opt.provider && $0.models.contains(opt.model) }
        }
    }
}
