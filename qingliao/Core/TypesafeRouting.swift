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

    /// 后端字段缺失时的兜底值（与后端 ROUTING_DEFAULT 同参）
    static let fallback = TypesafeRouting(enabled: true, mode: "smart", threshold: 0.6,
                                          timeoutMs: 1200, maxChars: 120,
                                          breakerFails: 3, breakerCooldownS: 300)

    /// 展开区底部说明（与后端契约一致：任何异常都回退现状）
    static let footerText = "判定失败/超时一律回退现状，不影响正常回复；改动免重启即时生效"
    /// 后端 mode=off（判定关闭，只在后端 CLI 里设得出来）时的提示
    static let modeOffHint = "后端 mode=off：判定已关闭，点上面任一模式可恢复"

    init(enabled: Bool, mode: String, threshold: Double, timeoutMs: Int,
         maxChars: Int, breakerFails: Int, breakerCooldownS: Int) {
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
                  breakerCooldownS: tsInt(json["breaker_cooldown_s"]) ?? f.breakerCooldownS)
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
