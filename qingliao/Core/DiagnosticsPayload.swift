import Foundation

// MARK: - v3.6.0 诊断事件载荷（崩溃 / 卡顿自上报）
//
// 本文件刻意只依赖 Foundation（不 import UIKit）——scripts/test_diag.swift 直接与它一起
// 编译成 Linux 可执行文件跑单测，验证「上报数据组装 + 字段白名单 + 离线队列编解码」。
// 设备型号 / 系统版本 / 网络类型由调用方（DiagnosticsEnv）采集后传入。
//
// 隐私红线：只允许 allowedKeys 里的字段上行；blockedKeys 命中即剔除（只回传字段名用于审计）。
// 绝不上传用户聊天内容、凭据、token、请求/响应体。

/// 单条诊断事件（崩溃 / 卡顿）
struct DiagEvent: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: String          // "crash" | "hang"
    var ts: Double            // Unix 秒
    var app: String
    var version: String       // CFBundleShortVersionString
    var build: String         // CFBundleVersion
    var device: String        // UIDevice.model（硬件型号，不含用户信息）
    var os: String            // UIDevice.systemVersion
    var network: String       // wifi / cellular / offline
    var summary: String       // 错误摘要（单行）
    var stack: String         // 调用栈（截断）
    var durationMs: Int       // 卡顿时长（崩溃恒 0）
}

/// 采集到的环境快照（由 UIKit 侧 DiagnosticsEnv 填充）
struct DiagEnv: Sendable, Equatable {
    var version: String
    var build: String
    var device: String
    var os: String
    var network: String

    static let unknown = DiagEnv(version: "", build: "", device: "", os: "", network: "unknown")
}

enum DiagnosticsPayload {
    // MARK: 常量

    static let appName = "qingliao-ios"

    /// 上报字段白名单（与后端 src/diag_api.py 的 _ALLOWED 双端一致）
    static let allowedKeys: Set<String> = [
        "id", "kind", "ts", "app", "version", "build",
        "device", "os", "network", "summary", "stack", "durationMs",
    ]

    /// 隐私黑名单：任何情况下都不上行；命中即剔除（只记字段名，不记值）
    static let blockedKeys: Set<String> = [
        "token", "password", "passwd", "secret", "apikey", "api_key", "authorization",
        "auth", "cookie", "content", "message", "messages", "text", "prompt", "chat",
        "username", "user", "body", "request", "response", "image", "file", "audio",
    ]

    static let maxStackChars = 4000
    static let maxSummaryChars = 200
    /// 离线队列上限（超出丢最旧，防磁盘无限增长）
    static let maxPendingEvents = 50
    /// 本地历史（诊断页展示）上限
    static let maxHistoryEvents = 30

    // MARK: 组装

    static func newId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16).description
    }

    /// 组装一条事件。summary / stack 自动收敛长度；env 里的字段全部来自白名单。
    static func makeEvent(kind: String,
                          env: DiagEnv,
                          summary: String,
                          stack: String = "",
                          durationMs: Int = 0,
                          ts: Double = Date().timeIntervalSince1970,
                          id: String = DiagnosticsPayload.newId()) -> DiagEvent {
        DiagEvent(id: id,
                  kind: kind,
                  ts: ts,
                  app: appName,
                  version: env.version,
                  build: env.build,
                  device: env.device,
                  os: env.os,
                  network: env.network,
                  summary: clamp(summary, maxSummaryChars),
                  stack: clamp(stack, maxStackChars),
                  durationMs: max(0, durationMs))
    }

    /// 崩溃事件：type/detail 来自 CrashReporter 写的 crash_pending.json
    static func makeCrashEvent(type: String,
                               detail: String,
                               stack: String,
                               env: DiagEnv,
                               ts: Double) -> DiagEvent {
        let head = detail.isEmpty ? type : "\(type): \(detail)"
        let summary = clamp(head.split(separator: "\n").first.map(String.init) ?? type,
                            maxSummaryChars)
        let full = stack.isEmpty ? detail : (detail.isEmpty ? stack : detail + "\n" + stack)
        return makeEvent(kind: "crash", env: env, summary: summary,
                         stack: full, durationMs: 0, ts: ts)
    }

    /// 卡顿事件
    static func makeHangEvent(durationMs: Int,
                              stack: String,
                              env: DiagEnv,
                              ts: Double = Date().timeIntervalSince1970) -> DiagEvent {
        makeEvent(kind: "hang", env: env,
                  summary: "主线程卡顿 \(durationMs)ms",
                  stack: stack, durationMs: durationMs, ts: ts)
    }

    // MARK: 清洗 / 校验

    /// 白名单 + 黑名单过滤。返回 (干净字典, 被剔除的黑名单字段名)。
    static func sanitize(_ raw: [String: Any]) -> (clean: [String: Any], dropped: [String]) {
        var dropped: [String] = []
        for k in raw.keys where isBlockedKey(k) { dropped.append(k) }
        var clean: [String: Any] = [:]
        for (k, v) in raw where allowedKeys.contains(k) && !isBlockedKey(k) {
            clean[k] = v
        }
        return (clean, dropped.sorted())
    }

    /// 命中隐私黑名单（大小写 / 连字符 / 下划线 / 驼峰无关；`X-Auth-Token`、`auth_token` 均命中）
    static func isBlockedKey(_ key: String) -> Bool {
        let k = key.lowercased()
        if k.isEmpty { return false }
        if blockedKeys.contains(k) { return true }
        // 按非字母数字边界切分：X-Auth-Token → [x, auth, token]
        let parts = k.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if parts.contains(where: { blockedKeys.contains($0) }) { return true }
        // 连写形式：authToken / authtoken
        for a in blockedKeys {
            for b in blockedKeys where a + b == k { return true }
        }
        return false
    }

    /// 上行 body（键名与 DiagEvent 编码完全一致，无多余字段）
    static func reportBody(_ event: DiagEvent) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(event),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        let (clean, _) = sanitize(obj)
        return clean
    }

    /// 批量上行 body（离线队列补传）
    static func batchBody(_ events: [DiagEvent]) -> [String: Any] {
        ["events": events.map { reportBody($0) }]
    }

    /// 断言：body 里不含任何黑名单键（用于单测与上线前自检）
    static func blockedKeysIn(_ body: [String: Any]) -> [String] {
        body.keys.filter { isBlockedKey($0) }.sorted()
    }

    // MARK: 离线队列编解码

    static func encode(_ events: [DiagEvent]) -> Data {
        (try? JSONEncoder().encode(events)) ?? Data("[]".utf8)
    }

    static func decode(_ data: Data) -> [DiagEvent] {
        (try? JSONDecoder().decode([DiagEvent].self, from: data)) ?? []
    }

    /// 只保留最新的 limit 条（按 ts 升序返回，便于顺时针追加）
    static func capEvents(_ events: [DiagEvent], limit: Int) -> [DiagEvent] {
        let sorted = events.sorted { $0.ts < $1.ts }
        guard sorted.count > limit else { return sorted }
        return Array(sorted.suffix(limit))
    }

    // MARK: 展示辅助

    static func clamp(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…(截断)"
    }

    static func networkLabel(isCellular: Bool, isSatisfied: Bool) -> String {
        if !isSatisfied { return "offline" }
        return isCellular ? "cellular" : "wifi"
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "crash": return "崩溃"
        case "hang": return "卡顿"
        default: return kind
        }
    }

    static func timeText(_ ts: Double) -> String {
        guard ts > 0 else { return "未知时间" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    /// 单条事件的纯文本详情（诊断页「展开详情」/ 一键复制用）
    static func detailText(_ e: DiagEvent) -> String {
        var lines: [String] = [
            "类型: \(kindLabel(e.kind))",
            "时间: \(timeText(e.ts))",
            "ID: \(e.id)",
            "版本: \(e.version) (\(e.build))",
            "设备: \(e.device)",
            "系统: \(e.os)",
            "网络: \(e.network)",
            "摘要: \(e.summary)",
        ]
        if e.durationMs > 0 { lines.append("时长: \(e.durationMs)ms") }
        if !e.stack.isEmpty { lines.append("调用栈:\n\(e.stack)") }
        return lines.joined(separator: "\n")
    }

    /// 整包诊断文本（一键复制 / 导出）
    static func bundleText(env: DiagEnv, events: [DiagEvent],
                           backend: String, pendingCount: Int) -> String {
        var out = [
            "轻聊诊断报告",
            "生成时间: \(timeText(Date().timeIntervalSince1970))",
            "App 版本: \(env.version) (\(env.build))",
            "设备: \(env.device)",
            "系统: \(env.os)",
            "网络: \(env.network)",
            "后端连通性: \(backend)",
            "待上报: \(pendingCount) 条",
            "记录数: \(events.count) 条",
            String(repeating: "-", count: 30),
        ]
        if events.isEmpty {
            out.append("(暂无崩溃 / 卡顿记录)")
        } else {
            for e in events { out.append(detailText(e)); out.append("") }
        }
        out.append("说明：本报告仅含版本/构建号/设备型号/系统版本/网络类型/时间/错误摘要与调用栈，不含聊天内容与凭据。")
        return out.joined(separator: "\n")
    }
}
