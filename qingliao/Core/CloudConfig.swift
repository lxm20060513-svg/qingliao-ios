import Foundation

// MARK: - 模型能力配置（v3.9.28：云端模式已整体移除，本文件只留本地模式依赖的四块）
//
// 历史：这里曾是 v3.0 云端模式（直连大模型 API）的配置中心（QingliaoMode/厂商预设/Keychain）。
// 云端移除后保留的都是**本地模式仍在用**的功能：
//   1) 视觉能力判定（modelSupportsVision / providerDeniesVision / effectiveVisionModel）
//   2) 视觉模型自动切换配置（qingliao_vision_* 键）
//   3) TTS 引擎配置（走 NAS 后端 /api/tts，非云端直连）
//   4) 防复读强模型表（isStrongModel，与后端 _is_strong_model 同规则）
//
// 保留 `CloudConfig` 命名（enum 静态命名空间），让 40+ 处调用方（视觉闸门/设置页/SpeechManager）
// 零改动——只删实现，不动接口。

enum CloudConfig {
    // MARK: - 视觉能力判定

    /// 按模型名 + provider 判断是否视觉模型。
    /// v3.9.26：provider 已纳入判定 —— 通用表只认模型名，同名模型在不同 provider 下能力可能不同，
    ///   反例收敛在 `visionDeniedPairs`。
    static func modelSupportsVision(_ model: String, provider: String? = nil) -> Bool {
        let m = model.lowercased()
        // provider 级反例优先：同名不同能力（实测该 provider 下无视觉）→ 强制 false，不再看通用表
        if let p = provider?.lowercased(), !p.isEmpty, visionDeniedPairs.contains("\(p)/\(m)") {
            return false
        }
        return modelSupportsVisionByName(m)
    }

    /// 已知「同名但该 provider 下无视觉」的精确反例表。
    ///
    /// 依据 = 2026-09-15 逐个 provider 实测（带 64x64 上红下蓝素图，直连该 provider 的 base_url）：
    ///   · sensenova/deepseek-v4-flash → 带图 HTTP 200 但 content 为空（finish=length），**图被静默丢弃**
    ///   · sensenova/glm-5.2           → 模型回「您未提供图片」，**静默丢图**
    ///   · sensenova/sensenova-6.8-flash-lite → 识图正确 ✅（故不列入）
    ///   · deepseek/deepseek-flash、deepseek/deepseek-v4-flash → 识图正确 ✅（官方通路，不列入）
    ///
    /// 命中即判「无视觉」→ 图降级为 [图片] 文本（保持既有行为，不会静默丢图）。
    /// 新增条目必须**实测过**该 provider 下的同名模型，别照官方文档推断。
    private static let visionDeniedPairs: Set<String> = [
        "sensenova/deepseek-v4-flash",
        "sensenova/glm-5.2",
    ]

    /// provider 反例命中即判「无视觉」。
    ///
    /// 单独暴露的原因：发送闸门**必须先查它、再读其他持久化判据**。
    /// 存量落盘的判据可能是旧逻辑写下的错误值，若先被它短路，反例永远修不到。
    static func providerDeniesVision(model: String, provider: String?) -> Bool {
        guard let p = provider?.lowercased(), !p.isEmpty else { return false }
        return visionDeniedPairs.contains("\(p)/\(model.lowercased())")
    }

    /// 主模型 + provider 的**统一取源**。
    ///
    /// 视觉的判定与展示都必须从这里取，禁止各处自己读 UserDefaults（会各说各话）。
    /// 默认值必须与 ChatView 的 @AppStorage("qingliao_model") 一致（"deepseek-v4-flash"）：
    /// 从没在模型管理里挑过模型的用户也按真实默认模型判视觉（v3.9.26 fix）。
    static var mainModelAndProvider: (model: String, provider: String) {
        let d = UserDefaults.standard
        return (d.string(forKey: "qingliao_model") ?? "deepseek-v4-flash",
                d.string(forKey: "qingliao_provider") ?? "opencode")
    }

    /// 纯模型名判定（通用表）。
    /// ⚠️ 新代码请优先用 `modelSupportsVision(_:provider:)` —— 只看模型名会漏掉同名不同能力的 provider。
    /// 保留为独立函数是为了让真值表能分别验证「通用表」与「provider 反例」两层。
    /// 命中特征：gpt-4o / gpt-5 / -vision / omni / multimodal / minimax 全系 / glm-4v / glm-5 全系 /
    /// mimo 全系（V2.5 原生多模态）/ u1 / flash-lite(部分) / step 系 / DeepSeek flash 系。
    static func modelSupportsVisionByName(_ model: String) -> Bool {
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
        // DeepSeek flash 系（官方 api.deepseek.com 实测支持 image_url）
        if m == "deepseek-flash" || m == "deepseek-v4-flash" {
            return true
        }
        return false
    }

    // MARK: - 视觉模型自动切换配置

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

    /// 判断发送图片时应使用哪个模型
    /// - 如果主模型支持视觉 → 返回 nil（用主模型）
    /// - 如果主模型不支持视觉且配置了视觉模型 → 返回视觉模型
    /// - 否则 → 返回 nil（降级为文本，保持现有行为）
    static func effectiveVisionModel() -> (model: String, provider: String)? {
        guard visionFallbackEnabled else { return nil }
        guard let visionModel = localVisionModel, !visionModel.isEmpty else { return nil }
        // 如果主模型已支持视觉，无需切换
        let main = mainModelAndProvider
        if modelSupportsVision(main.model, provider: main.provider) { return nil }
        return (visionModel, localVisionProvider)
    }

    // MARK: - v3.0.68 语音引擎（TTS）配置 —— 总开关 + 模型 + 音色
    // 走 NAS 后端 /api/tts，与已移除的云端直连无关；本地模式核心功能，保留。

    private static let ttsEnabledKey = "qingliao_tts_enabled"
    private static let ttsProviderKey = "qingliao_tts_provider"
    private static let ttsModelKey = "qingliao_tts_model"
    private static let ttsVoiceKey = "qingliao_tts_voice"
    // 默认：小米 mimo-v2.5-tts
    private static let ttsDefaultProvider = "xiaomi"
    private static let ttsDefaultModel = "mimo-v2.5-tts"
    private static let ttsDefaultVoice = "mimo_default"

    /// TTS 总开关（默认开 = 用后端神经 TTS；关 = 用系统 AVSpeechSynthesizer）
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

    /// 支持 TTS 的模型列表（可扩展，新增 TTS 模型只需追加此数组）
    private static let _ttsSupported: [(provider: String, model: String, label: String)] = [
        ("xiaomi", "mimo-v2.5-tts", "小米 MiMo"),
        ("zai", "glm-tts", "智谱 GLM"),
        ("stepfun", "stepaudio-2.5-tts", "阶跃 StepAudio"),
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
    /// v3.5.x：阶跃 StepAudio 2.5 TTS 预置音色（voice id 已实测 200）
    static let stepfunTtsVoices: [(name: String, id: String)] = [
        ("磁性男声", "cixingnansheng"), ("温柔男声", "wenrounansheng"),
        ("气质温婉（女）", "elegantgentle-female"), ("活力轻快（女）", "livelybreezy-female"),
    ]

    /// 按模型返回音色列表
    static func ttsVoicesFor(provider: String, model: String) -> [(name: String, id: String)] {
        switch provider {
        case "zai": return zaiTtsVoices
        case "stepfun": return stepfunTtsVoices
        default: return xiaomiTtsVoices
        }
    }
    /// 按 provider/model 过滤支持 TTS 的模型（allProviders 传入）——只显示已同步到模型列表（=配置了 key）的，防选了但调用失败
    static func ttsModelOptions(from providers: [(id: String, models: [String])]) -> [(provider: String, model: String, label: String)] {
        let configured = providers.filter { !$0.models.isEmpty }
        return ttsSupported.filter { opt in
            configured.contains { $0.id == opt.provider && $0.models.contains(opt.model) }
        }
    }

    // MARK: - v3.9.15 防复读闸门：强模型豁免「断种子」占位

    /// **必须与后端 `stream_api._is_strong_model` 完全一致**——两侧规则不一致就是事故：
    /// 弱模型（如 mimo-v2.5）看到历史里的完整长回复会整段照抄，需要占位断掉续写种子；
    /// 强模型（deepseek/step-*/gpt-5/claude/glm-5）需要完整语义上下文才能把用户的**短追问**
    /// （「不用」「为什么回答两次」）对号入座，压掉它上一条回答＝失忆 → 重跑上一轮任务。
    /// 实证 2026-09-13：App 无条件压占位，用户一句「不用」被回了三份 NAS 内存诊断。
    static func isStrongModel(provider: String, model: String) -> Bool {
        let p = provider.lowercased()
        let m = model.lowercased()
        if p == "deepseek" || p == "stepfun" { return true }
        for pre in ["deepseek", "step", "gpt-5", "claude", "glm-5"] where m.hasPrefix(pre) { return true }
        return false
    }
}
