import Foundation

// MARK: - v3.9.56 TypeSafe「智能路由」设置项（开关 + 就地展开参数）
//
// 后端真源：GET/POST /api/agent/typesafe/routing
//   {"ok":true,
//    "routing":{"enabled":true,"mode":"smart","threshold":0.6,"timeout_ms":1200,
//               "max_chars":120,"breaker_fails":3,"breaker_cooldown_s":300},
//    "breaker":{"open":false,"remain_s":0,"fails":0,"trips":0,"since_s":0,"last_error":""},
//    "restart_needed":false}
//
// 分层（刻意的）：
//   · 本文件 = 模型 + 文案，**纯 Foundation**（无 SwiftUI/UIKit）→ scripts/test_typesafe_routing.swift
//     能直接编译它跑真值表，把「熔断倒计时算错」「关掉开关文案还写已开启」这类必错项钉在本机；
//     类型/并发仍只能靠 CI，真机观感（胶囊深浅 / 红字）也仍需真机看。
//   · App 侧**不在 UserDefaults 里存这些参数**：后端才是唯一真源，否则两台设备各记一份会互相打架
//     （本文件只做「读回来显示 + 改完回写」）。
//   · 关掉开关 = 完全不判定（全走原关键词规则 = 上线前的行为）；判定失败/超时/熔断期间一律回退现状，
//     不影响正常回复，也与 Hermes 的模型 key 完全无关。

/// 路由配置（对应后端 `routing` 段）
struct TypesafeRouting: Equatable {
    var enabled: Bool
    var mode: String              // smart / force_agent / off
    var threshold: Double
    var timeoutMs: Int
    var maxChars: Int
    var breakerFails: Int
    var breakerCooldownS: Int
    /// 判定后端：typesafe=云端 Jev / custom=自填 OpenAI 兼容模型（用户自带 key）/ local=本机模型
    var backend: String

    /// 后端字段缺失时的兜底值（与后端 ROUTING_DEFAULT 同参）
    static let fallback = TypesafeRouting(enabled: true, mode: "smart", threshold: 0.6,
                                          timeoutMs: 1200, maxChars: 120,
                                          breakerFails: 3, breakerCooldownS: 300,
                                          backend: "typesafe")

    /// 展开区底部说明（与后端契约一致：任何异常都回退现状）
    static let footerText = "判定失败/超时一律回退现状，不影响正常回复；改动免重启即时生效"
    /// 后端 mode=off（判定关闭，只在后端 CLI 里设得出来）时的提示
    static let modeOffHint = "后端 mode=off：判定已关闭，点上面任一模式可恢复"

    init(enabled: Bool, mode: String, threshold: Double, timeoutMs: Int,
         maxChars: Int, breakerFails: Int, breakerCooldownS: Int,
         backend: String = "typesafe") {
        self.backend = backend
        self.enabled = enabled
        self.mode = mode
        self.threshold = threshold
        self.timeoutMs = timeoutMs
        self.maxChars = maxChars
        self.breakerFails = breakerFails
        self.breakerCooldownS = breakerCooldownS
    }

    /// 解析后端 JSON。`enabled` 是唯一必需字段（后端永远会带）：缺失即解析失败返回 nil →
    /// 调用方保留上一次的值并提示，**绝不拿兜底值冒充后端现状**（那会让开关和后端脱钩）。
    /// 其余字段缺失/类型不对 → 用 fallback 同参，不因一个字段把整块状态判死。
    init?(json: [String: Any]) {
        guard let enabled = json["enabled"] as? Bool else { return nil }
        let f = Self.fallback
        self.init(enabled: enabled,
                  mode: (json["mode"] as? String) ?? f.mode,
                  threshold: tsDouble(json["threshold"]).map { min(max($0, 0), 1) } ?? f.threshold,
                  timeoutMs: tsInt(json["timeout_ms"]) ?? f.timeoutMs,
                  maxChars: tsInt(json["max_chars"]) ?? f.maxChars,
                  breakerFails: tsInt(json["breaker_fails"]) ?? f.breakerFails,
                  breakerCooldownS: tsInt(json["breaker_cooldown_s"]) ?? f.breakerCooldownS,
                  backend: Self.normBackend(json["backend"] as? String))
    }

    /// 判定后端白名单。后端只允许 typesafe / custom / local；未知值按 typesafe 显示
    /// （真出现未知值说明后端加了档，UI 需同步），不给用户看原始英文串。
    static func normBackend(_ raw: String?) -> String {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "custom": return "custom"
        case "local": return "local"
        default: return "typesafe"
        }
    }

    /// 判定模型中文名（设置页胶囊标题旁 / 状态行用）
    var backendText: String {
        switch backend {
        case "custom": return "自定义模型"
        case "local": return "本机模型"
        default: return "TypeSafe 云端"
        }
    }

    /// 模式中文名。后端只允许 smart / off / force_agent；未知值兜底按「智能分流」显示
    /// （真出现未知值说明后端加了档，UI 需同步），不给用户看原始英文串。
    var modeText: String {
        switch mode {
        case "force_agent": return "强制 Agent"
        case "off": return "关闭"
        default: return "智能分流"
        }
    }

    /// 开关行副标题（模式在展开区里，行内只说开关状态）
    var subtitleText: String {
        enabled ? "判定是否要干活 · 已开启" : "已关闭 · 全走原关键词规则"
    }

    var timeoutText: String { "\(timeoutMs) ms" }
    var thresholdText: String { String(format: "%.2f", threshold) }
}

/// 熔断状态（对应后端 `breaker` 段）
struct TypesafeBreaker: Equatable {
    var open: Bool
    var remainS: Int
    var fails: Int
    var trips: Int
    var lastError: String

    static let closed = TypesafeBreaker(open: false, remainS: 0, fails: 0, trips: 0, lastError: "")

    init(open: Bool, remainS: Int, fails: Int, trips: Int, lastError: String) {
        self.open = open
        self.remainS = remainS
        self.fails = fails
        self.trips = trips
        self.lastError = lastError
    }

    /// `open` 缺失即解析失败（同 TypesafeRouting：不拿兜底冒充后端现状）
    init?(json: [String: Any]) {
        guard let open = json["open"] as? Bool else { return nil }
        self.init(open: open,
                  remainS: tsInt(json["remain_s"]) ?? 0,
                  fails: tsInt(json["fails"]) ?? 0,
                  trips: tsInt(json["trips"]) ?? 0,
                  lastError: (json["last_error"] as? String) ?? "")
    }

    /// mm:ss（负数按 0 处理；后端到点自恢复，不会长期停在 00:00）
    static func clock(_ s: Int) -> String {
        let v = max(0, s)
        return String(format: "%02d:%02d", v / 60, v % 60)
    }

    /// 冷却时长人话（300 → 「5 分钟」；90 → 「90 秒」；0 → 「关闭」）
    static func cooldownText(_ s: Int) -> String {
        if s <= 0 { return "关闭" }
        return s % 60 == 0 ? "\(s / 60) 分钟" : "\(s) 秒"
    }

    /// 展开区状态行（颜色由调用方按 `open` 决定：熔断红字 / 正常灰字）
    func statusText(_ cfg: TypesafeRouting) -> String {
        if open { return "熔断中 · 剩 \(Self.clock(remainS)) · 连续失败 \(fails) 次" }
        if cfg.breakerFails <= 0 { return "正常 · 连续失败 \(fails) 次（未启用自动熔断）" }
        return "正常 · 连续失败 \(fails) 次（连续 \(cfg.breakerFails) 次失败自动暂停 \(Self.cooldownText(cfg.breakerCooldownS))）"
    }
}

// MARK: - JSON 取值容错（后端数字可能是 Int / Double / 字符串）

private func tsInt(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let d = v as? Double { return Int(d.rounded()) }
    if let s = v as? String { return Int(s) }
    return nil
}

private func tsDouble(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let s = v as? String { return Double(s) }
    return nil
}

// MARK: - 自定义判定模型（后端 `custom` 段：GET/POST /api/agent/typesafe/model）
//
// 为什么它在 App 里可配：key 会失效、会换厂商，用户不该为换个判定模型等一次发版。
// 后端是唯一真源（key 存后端 600 权限文件、接口只回掩码），App 只做「读回显示 + 改完回写」。
//   GET  {"ok":true,"custom":{"base_url":"","model":"","api_key":"未配置","configured":false,"timeout_ms":4000}}
//   POST {"base_url":"…","model":"…","api_key":"…"}  省略 api_key = 不改，空串 = 清空
//   POST {"test":true}  真调用两条样例，回 {"ok":…,"test":[{"text":…,"ok":…,"needs_action":…,"ms":…}]}

/// 自定义判定模型配置（对应后端 `custom` 段）
struct TypesafeModel: Equatable {
    var baseURL: String
    var model: String
    var apiKeyMasked: String     // 后端只回掩码（「未配置」/ abcd…wxyz），永远拿不到明文
    var configured: Bool
    var timeoutMs: Int

    static let empty = TypesafeModel(baseURL: "", model: "", apiKeyMasked: "未配置",
                                     configured: false, timeoutMs: 4000)

    init(baseURL: String, model: String, apiKeyMasked: String, configured: Bool, timeoutMs: Int) {
        self.baseURL = baseURL
        self.model = model
        self.apiKeyMasked = apiKeyMasked
        self.configured = configured
        self.timeoutMs = timeoutMs
    }

    /// 解析后端 JSON。`custom` 段缺失即解析失败返回 nil（保留上一次的值，不拿兜底冒充后端）
    init?(json: [String: Any]) {
        guard let raw = json["custom"] as? [String: Any] else { return nil }
        self.init(baseURL: (raw["base_url"] as? String) ?? "",
                  model: (raw["model"] as? String) ?? "",
                  apiKeyMasked: (raw["api_key"] as? String) ?? "未配置",
                  configured: (raw["configured"] as? Bool) ?? false,
                  timeoutMs: tsInt(raw["timeout_ms"]) ?? 4000)
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 差哪项就直说，别让用户点了保存不知道为什么没生效
    var statusText: String {
        if Self.clean(baseURL).isEmpty && Self.clean(model).isEmpty && !configured {
            return "未配置：填接口地址、模型名、API Key 三项后点保存"
        }
        if !configured { return "还缺 API Key（没有 key 判不了，会回退关键词规则）" }
        if Self.clean(baseURL).isEmpty { return "还缺接口地址" }
        if Self.clean(model).isEmpty { return "还缺模型名" }
        return "已配置 · \(Self.clean(model)) · Key \(apiKeyMasked)"
    }

    /// 三项齐全（决定状态行是否红字）
    var ready: Bool { configured && !Self.clean(baseURL).isEmpty && !Self.clean(model).isEmpty }

}

/// 本机判定模型（后端 `local` 段）—— NAS 上的 ollama 小模型，不联网、零成本。
/// 设置页只做「展示 + 切档 + 测试」，参数由后端 local 段决定（CLI 可改）。
struct TypesafeLocalModel: Equatable {
    var url: String
    var model: String

    static let empty = TypesafeLocalModel(url: "", model: "")

    init(url: String, model: String) {
        self.url = url
        self.model = model
    }

    init?(json: [String: Any]) {
        guard let raw = json["local"] as? [String: Any] else { return nil }
        self.init(url: (raw["url"] as? String) ?? "", model: (raw["model"] as? String) ?? "")
    }

    /// 状态行：让用户看得见当前跑的是哪个本机模型、连的哪个地址
    var statusText: String {
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "本机模型未配置" }
        return url.isEmpty ? "本机模型 · \(model)" : "本机模型 · \(model) · \(url)"
    }

    var ready: Bool { !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// 设置页「测试」结果（后端真调用两条样例：一条该干活、一条纯闲聊）
struct TypesafeProbe: Hashable {   // Hashable：设置页 ForEach(id: \.self) 要用；成员全是 String/Bool/Int，自动合成
    var text: String
    var ok: Bool
    var needsAction: Bool
    var ms: Int
    var error: String

    init(text: String, ok: Bool, needsAction: Bool, ms: Int, error: String) {
        self.text = text
        self.ok = ok
        self.needsAction = needsAction
        self.ms = ms
        self.error = error
    }

    init?(json: [String: Any]) {
        guard let text = json["text"] as? String, let ok = json["ok"] as? Bool else { return nil }
        self.init(text: text, ok: ok,
                  needsAction: (json["needs_action"] as? Bool) ?? false,
                  ms: tsInt(json["ms"]) ?? 0,
                  error: (json["error"] as? String) ?? "")
    }

    /// 解析整段 test 响应（结构不对 → 空数组，页面不显示假结果）
    static func list(_ j: [String: Any]) -> [TypesafeProbe] {
        (j["test"] as? [[String: Any]])?.compactMap { TypesafeProbe(json: $0) } ?? []
    }

    /// 一行结果文案
    var line: String {
        if !ok { return "❌ 「\(text)」失败：\(error.isEmpty ? "未知错误" : error)" }
        return "\(needsAction ? "✅ 判要干活" : "✅ 判纯聊天") · 「\(text)」 · \(ms)ms"
    }
}
