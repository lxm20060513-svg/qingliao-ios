import Foundation
import SwiftUI

// MARK: - UserDefaults key 常量（v3.0.81：消除魔法字符串）

/// App 全局 UserDefaults key 集中管理，防止拼写错误导致静默失效
enum UserDefaultsKey {
    static let agentEnabled = "qingliao_agent_enabled"
    static let agentModel   = "qingliao_agent_model"
    static let agentProvider = "qingliao_agent_provider"
    static let freeModel     = "qingliao_free_model"
    static let freeModelName = "qingliao_free_model_name"
}

// MARK: - 聊天消息（content 可能是纯文本或数组，手动解析最稳）

struct ChatMessage: Identifiable, Equatable {
    let role: String        // user / assistant / system
    let content: String     // 纯文本形态（数组 content 取 text 部分）
    let timestamp: TimeInterval?   // 毫秒
    var imageDataURL: String?      // data:image/jpeg;base64,...（本地发送的图片）
    var failed: Bool = false       // v2.0.59：发送失败标记（显示重试按钮）
    var audioPath: String?         // v2.0.61：本地语音消息文件路径（m4a）
    var queued: Bool = false       // v2.0.88：AI 回答中发送，排队等待自动处理
    var withdrawn: Bool = false    // v2.0.92：已撤回（显示"[已撤回]"占位）
    var agent: Bool = false        // v2.0.96b：Agent 回复标记（工具调用回复，显示标签）
    var voiceCommand: Bool = false   // v3.0.19：语音指令触发（长按智能球，显示 🎤 标记）
    var isPush: Bool = false         // v3.0.82：Hermes 主动推送消息（本地收件箱注入，显示"推送"标签）

    /// v3.1.12：错误占位识别——App 失败提示（⚠️/HTTP Error/连接中断等）被 upsert 成 assistant
    /// 混入历史是复读污染源之一：此类消息只用于 UI 展示，绝不允许进入模型上下文。
    var isErrorPlaceholder: Bool {
        guard role == "assistant" else { return false }
        let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.hasPrefix("⚠️") { return true }
        let markers = ["HTTP Error", "连接中断", "请重试", "请求失败", "网络错误", "Unauthorized", "无返回内容"]
        return markers.contains { c.contains($0) }
    }

    /// v3.0.x fix：Equatable 基于 id（SwiftUI diff 效率提升——不逐字段比较）
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }

    /// v3.0.50 聊天稳定性：稳定 id——用 djb2 哈希替代 String.hashValue（后者带进程随机种子，
    /// 跨启动漂移，导致会话重开后消息去重/ForEach id/删除定位错乱）
    private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 5381
        for b in s.utf8 { h = h &* 33 &+ UInt64(b) }
        return h
    }
    var id: String {
        "\(role)-\(Self.stableHash(content))-\(Self.stableHash(imageDataURL ?? ""))-\(timestamp ?? 0)"
    }
    var isUser: Bool { role == "user" }

    /// 解析 messages 数组里的条目：content 可能是 String 或 [{type,text}...]
    static func parse(_ raw: Any) -> ChatMessage? {
        guard let d = raw as? [String: Any] else { return nil }
        let role = d["role"] as? String ?? ""
        let ts = d["timestamp"] as? TimeInterval
        var text = ""
        if let s = d["content"] as? String {
            text = s
        } else if let arr = d["content"] as? [[String: Any]] {
            // 多模态块：拼接 text 字段，图片记为 [图片]（历史消息不带 data URL，防超大 JSON）
            text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let hasImage = arr.contains { ($0["type"] as? String) == "image_url" }
            if hasImage {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = t.isEmpty ? "[图片]" : t + "\n[图片]"
            }
        }
        let isPush = d["isPush"] as? Bool ?? false
        let isAgent = d["agent"] as? Bool ?? false
        var msg = ChatMessage(role: role, content: text, timestamp: ts)
        msg.isPush = isPush
        msg.agent = isAgent
        return msg
    }

    /// 本地新消息（无时间戳）
    static func local(role: String, content: String, imageDataURL: String? = nil) -> ChatMessage {
        ChatMessage(role: role, content: content, timestamp: Date().timeIntervalSince1970 * 1000,
                    imageDataURL: imageDataURL)
    }

    /// 请求体形态（发往 stream/start 的 messages）：带图时用 content 数组
    func asPayload() -> [String: Any] {
        var p: [String: Any] = ["role": role]
        if let img = imageDataURL {
            var blocks: [[String: Any]] = []
            if !content.isEmpty {
                blocks.append(["type": "text", "text": content])
            }
            blocks.append(["type": "image_url", "image_url": ["url": img]])
            p["content"] = blocks
        } else {
            p["content"] = content
        }
        if let ts = timestamp { p["timestamp"] = ts }
        return p
    }
}

// MARK: - v3.0.68 语音对讲轮次（浮层对话，不落库主 session）

struct VoiceChatTurn: Identifiable {
    let id: UUID
    let role: String   // "user" / "assistant"
    let text: String
    init(role: String, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
    }
    var isUser: Bool { role == "user" }
}

// MARK: - 会话（/api/sessions/list）

struct ChatSession: Identifiable {
    let id: String
    var title: String   // v2.0.43 重命名（SessionsView 本地改）
    let messages: [ChatMessage]

    var lastMessageText: String { messages.last?.content ?? "" }
    var lastTime: TimeInterval? { messages.last?.timestamp }

    static func parse(_ d: [String: Any]) -> ChatSession? {
        guard let id = d["id"] as? String else { return nil }
        let title = d["title"] as? String ?? ""
        let msgs = (d["messages"] as? [Any] ?? []).compactMap { ChatMessage.parse($0) }
        return ChatSession(id: id, title: title, messages: msgs)
    }

    /// v3.0.x fix：缓存 DateFormatter（原每次调用创建新实例）
    private static let relativeTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()

    /// 列表页相对时间（分钟/小时/天）
    var relativeTime: String {
        guard let ts = lastTime else { return "" }
        let t = ts / 1000.0
        let diff = Date().timeIntervalSince1970 - t
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60)) 分钟" }
        if diff < 86400 { return "\(Int(diff / 3600)) 小时" }
        if diff < 86400 * 7 { return "\(Int(diff / 86400)) 天" }
        return Self.relativeTimeFormatter.string(from: Date(timeIntervalSince1970: t))
    }
}

// MARK: - 模型使用量（/api/nas/providers-usage，v3.0.36）

/// v3.0.36：看板「模型使用量」栏数据
/// 三种形态：payg 余额（DeepSeek/StepFun total/granted/topped_up）、
/// plan 百分比配额（OpenCode rolling/weekly/monthly percent）、unsupported（无公开接口）
struct ProviderUsage: Identifiable {
    let provider: String
    let name: String
    let mode: String          // payg=按量余额 / plan=订阅配额
    let available: Bool
    let unsupported: Bool     // 官方无公开用量接口
    let total: Double
    let granted: Double
    let toppedUp: Double
    let currency: String
    let error: String
    // plan 百分比配额（opencode /zen/go/v1/usage）
    let usagePercent: [String: Double]   // rolling/weekly/monthly → percent
    let usageReset: [String: String]     // rolling/weekly/monthly → resetsAt ISO

    var id: String { provider }

    /// 主文本：余额（payg）或当前用量百分比（plan）
    var balanceText: String {
        if unsupported { return "控制台查看" }
        if mode == "plan", let monthly = usagePercent["monthly"] {
            return String(format: "月用量 %.0f%%", monthly)
        }
        if total > 0 {
            let sym = currency == "USD" ? "$" : "¥"
            return String(format: "%@%.2f", sym, total)
        }
        return "—"
    }

    /// 副文本：plan → 周/滚动百分比；payg → 充值/赠金明细
    var detailText: String {
        if unsupported { return error.isEmpty ? "无公开接口" : error }
        if !available { return error.isEmpty ? "不可用" : error }
        if mode == "plan" {
            var parts: [String] = []
            if let w = usagePercent["weekly"] { parts.append(String(format: "周 %.0f%%", w)) }
            if let r = usagePercent["rolling"] { parts.append(String(format: "滚动 %.0f%%", r)) }
            return parts.isEmpty ? "订阅中" : parts.joined(separator: " · ")
        }
        var parts: [String] = []
        if toppedUp > 0 { parts.append(String(format: "充值 %.2f", toppedUp)) }
        if granted > 0 { parts.append(String(format: "赠金 %.2f", granted)) }
        return parts.isEmpty ? "可用" : parts.joined(separator: " · ")
    }

    static func parse(_ d: [String: Any]) -> ProviderUsage {
        let b = d["balance"] as? [String: Any] ?? [:]
        var pct: [String: Double] = [:]
        var reset: [String: String] = [:]
        if let u = d["usage"] as? [String: Any] {
            for k in ["rolling", "weekly", "monthly"] {
                if let v = u[k] as? [String: Any] {
                    if let p = v["percent"] as? Double { pct[k] = p }
                    else if let p = v["percent"] as? String { pct[k] = Double(p) ?? 0 }
                    if let r = v["resetsAt"] as? String { reset[k] = r }
                }
            }
        }
        return ProviderUsage(
            provider: d["provider"] as? String ?? "",
            name: d["name"] as? String ?? d["provider"] as? String ?? "",
            mode: d["mode"] as? String ?? "payg",
            available: (d["available"] as? Bool) ?? false,
            unsupported: (d["unsupported"] as? Bool) ?? false,
            total: (b["total"] as? Double) ?? 0,
            granted: (b["granted"] as? Double) ?? 0,
            toppedUp: (b["topped_up"] as? Double) ?? 0,
            currency: b["currency"] as? String ?? "CNY",
            error: d["error"] as? String ?? "",
            usagePercent: pct,
            usageReset: reset
        )
    }
}

// MARK: - NAS 状态（/api/nas/status）

struct NASStatus {
    var hostname = ""
    var uptime = ""
    var cpu: Double = 0
    var memTotal: Double = 0
    var memUsed: Double = 0
    var disks: [NASDisk] = []
    var qingliaoAlive = false
    var qingliaoMem = 0.0
    var hermesAlive = false
    var hermesMem = 0.0
    var hermesVersion = ""   // v3.0.8：Hermes 容器版本（docker exec 实时读）

    /// 最大磁盘使用率（PWA 概览语义）
    var maxDiskPct: Double {
        disks.map(\.pct).max() ?? 0
    }

    static func parse(_ j: [String: Any]) -> NASStatus {
        var s = NASStatus()
        s.hostname = j["hostname"] as? String ?? ""
        s.uptime = j["uptime"] as? String ?? ""
        s.cpu = (j["cpu"] as? Double) ?? 0
        if let mem = j["mem"] as? [String: Any] {
            s.memTotal = (mem["total"] as? Double) ?? 0
            s.memUsed = (mem["used"] as? Double) ?? 0
        }
        if let disks = j["disks"] as? [[String: Any]] {
            s.disks = disks.compactMap { NASDisk.parse($0) }
        }
        if let svc = j["services"] as? [String: Any] {
            s.qingliaoAlive = (svc["qingliao"] as? Bool) ?? false
            s.qingliaoMem = (svc["qingliao_mem"] as? Double) ?? 0
            s.hermesAlive = (svc["hermes"] as? Bool) ?? false
            s.hermesMem = (svc["hermes_mem"] as? Double) ?? 0
            s.hermesVersion = (svc["hermes_version"] as? String) ?? ""
        }
        return s
    }

    var memPct: Double { memTotal > 0 ? memUsed / memTotal : 0 }
    var memUsedText: String { memUsed.byteText }
    var memTotalText: String { memTotal.byteText }
    var qingliaoMemText: String { qingliaoMem.byteText }
    var hermesMemText: String { hermesMem.byteText }
    var cpuText: String { String(format: "%.1f%%", cpu) }
    var maxDiskPctText: String { String(format: "%.0f%%", maxDiskPct) }
    /// v3.0.22：硬件温度预格式化（DashboardView hwDetail 内联格式化搬到模型层）
    var hwCpuText: String { "" }
    var hwSsdText: String { "" }
}

// MARK: - NAS 磁盘

struct NASDisk: Identifiable {
    let mnt: String
    let fs: String
    let used: Double
    let total: Double
    let pct: Double
    let kind: String  // v3.0.36：system=系统盘分区 / data=数据卷（/volume*）

    var id: String { mnt }
    var isSystem: Bool { kind == "system" }
    var usedText: String { used.byteText }
    var totalText: String { total.byteText }
    var pctText: String { String(format: "%.0f%%", pct) }

    static func parse(_ d: [String: Any]) -> NASDisk? {
        guard let mnt = d["mnt"] as? String else { return nil }
        let fs = d["fs"] as? String ?? ""
        let used = (d["used"] as? Double) ?? 0
        let total = (d["total"] as? Double) ?? 0
        let pct = Double(d["pct"] as? String ?? "0") ?? 0
        let kind = d["kind"] as? String ?? (mnt.hasPrefix("/volume") || mnt.hasPrefix("/data") ? "data" : "system")
        return NASDisk(mnt: mnt, fs: fs, used: used, total: total, pct: pct, kind: kind)
    }
}

// MARK: - HA 实体（/api/ha/states）

struct HAEntity: Identifiable {
    let entityID: String
    let state: String
    let friendlyName: String
    let attributes: [String: Any]

    var id: String { entityID }

    static func parse(_ d: [String: Any]) -> HAEntity? {
        guard let eid = d["entity_id"] as? String else { return nil }
        let attrs = d["attributes"] as? [String: Any] ?? [:]
        let fn = attrs["friendly_name"] as? String ?? ""
        return HAEntity(entityID: eid, state: d["state"] as? String ?? "", friendlyName: fn, attributes: attrs)
    }
}

// MARK: - v3.0.27 会话文件夹/标签

/// 会话分类（本地存储，UserDefaults JSON）
struct SessionCategory: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var icon: String     // SF Symbol name
    var color: String    // hex color string
}

/// 会话分类管理（UserDefaults 持久化）
@MainActor
@Observable
final class CategoryStore {
    var categories: [SessionCategory] = []
    var sessionCategories: [String: String] = [:]  // sessionId → categoryId

    private let categoriesKey = "qingliao_categories"
    private let mappingKey = "qingliao_session_categories"

    init() {
        load()
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: categoriesKey),
           let cats = try? JSONDecoder().decode([SessionCategory].self, from: data) {
            categories = cats
        }
        if let data = UserDefaults.standard.data(forKey: mappingKey),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            sessionCategories = map
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(categories) {
            UserDefaults.standard.set(data, forKey: categoriesKey)
        }
        if let data = try? JSONEncoder().encode(sessionCategories) {
            UserDefaults.standard.set(data, forKey: mappingKey)
        }
    }

    func addCategory(_ cat: SessionCategory) {
        categories.append(cat)
        save()
    }

    func removeCategory(_ id: String) {
        categories.removeAll { $0.id == id }
        sessionCategories = sessionCategories.filter { $0.value != id }
        save()
    }

    func assignSession(_ sessionId: String, to categoryId: String?) {
        if let catId = categoryId {
            sessionCategories[sessionId] = catId
        } else {
            sessionCategories.removeValue(forKey: sessionId)
        }
        save()
    }

    func categoryForSession(_ sessionId: String) -> SessionCategory? {
        guard let catId = sessionCategories[sessionId] else { return nil }
        return categories.first { $0.id == catId }
    }
}

// MARK: - 钉一钉（v3.0.74：聊天消息钉到看板）

struct PinItem: Identifiable, Codable {
    let id: String
    let content: String
    let sourceSessionId: String?
    let sourceRole: String?   // user / assistant
    let createdAt: Date

    init(id: String = UUID().uuidString, content: String,
         sourceSessionId: String? = nil, sourceRole: String? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.content = content
        self.sourceSessionId = sourceSessionId
        self.sourceRole = sourceRole
        self.createdAt = createdAt
    }

    /// v3.0.x fix：缓存 DateFormatter（原每次调用创建新实例，列表滚动时大量浪费）
    private static let dateKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let timeTextFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 按天分组用 "2026-08-29"
    var dateKey: String {
        Self.dateKeyFormatter.string(from: createdAt)
    }

    /// 显示用时间 "14:30"
    var timeText: String {
        Self.timeTextFormatter.string(from: createdAt)
    }

    /// 内容截断（卡片用）
    var preview: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 120 { return trimmed }
        return String(trimmed.prefix(120)) + "…"
    }

    /// 来源标签
    var sourceLabel: String {
        switch sourceRole {
        case "user": return "👤 我说的"
        case "assistant": return "🤖 AI 说的"
        default: return ""
        }
    }
}

// MARK: - Double 扩展：字节文本格式化（消除 NASDisk/NASStatus 重复实现）

extension Double {
    /// 字节 → 可读文本（G/M/K）
    var byteText: String {
        if self >= 1_073_741_824 { return String(format: "%.1fG", self / 1_073_741_824) }
        if self >= 1_048_576 { return String(format: "%.0fM", self / 1_048_576) }
        return String(format: "%.0fK", self / 1024)
    }
}

// MARK: - [String: Any] 扩展：防御式类型提取（消除大量 `as? String ?? ""` 重复模式）

extension [String: Any] {
    /// 安全提取 String 字段
    func str(_ key: String, _ fallback: String = "") -> String {
        self[key] as? String ?? fallback
    }
    /// 安全提取 Double 字段
    func dbl(_ key: String, _ fallback: Double = 0) -> Double {
        (self[key] as? Double) ?? fallback
    }
    /// 安全提取 Bool 字段
    func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        (self[key] as? Bool) ?? fallback
    }
    /// 安全提取嵌套字典
    func dict(_ key: String) -> [String: Any] {
        self[key] as? [String: Any] ?? [:]
    }
    /// 安全提取嵌套数组
    func arr(_ key: String) -> [[String: Any]] {
        self[key] as? [[String: Any]] ?? []
    }
}
