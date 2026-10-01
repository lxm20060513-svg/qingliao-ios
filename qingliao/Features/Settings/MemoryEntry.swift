import Foundation
import SwiftUI

// MARK: - v4.0.x 第 4 项「记忆条目结构化」：一条记忆的结构化视图
//
// 🚨 为什么不直接把后端 entries 改成 dict 就完事：
//   entries 是全仓最热的共享结构（App 三处、WebUI qllm.js、prompt_block 注入、
//   proactive 偏好块全按**字符串**读它）。一旦换结构，那些地方会**静默渲染成空白**
//   ——用户看着像"记忆全丢了"，而且不报任何错。
//   所以后端保留 `entries`（纯字符串，老读者零感知），另开 `items`（本文件的来源）。
//   本文件是它的 App 侧解析：**items 缺失时从 entries 兜底**，
//   所以老后端 / 灰度期间 App 也不会白屏。

struct MemoryEntry: Identifiable, Equatable {
    /// 正文即 id —— 后端 meta 就是按正文做键的，重复正文本就被 add_entry 去重挡掉
    var id: String { text }
    let text: String
    let status: String        // active / pending / stale
    let created: Date?        // nil = 未知（老条目无 created，App 不编一个假日期）
    let updated: Date?
    let source: String        // "" / chat / manual
    let sessionId: String

    static let statusActive = "active"
    static let statusPending = "pending"
    static let statusStale = "stale"

    /// 后端 META 状态取值口径（后端 memory_store.STATUSES 的 App 侧镜像）
    static let allStatuses = [statusActive, statusPending, statusStale]

    /// 非法/缺失状态一律回落 active —— 与后端 _normalize_meta 同一口径。
    /// 两边不一致的话，App 会给一个后端根本不认的状态打上"已生效"的绿标。
    var normalizedStatus: String { MemoryEntry.allStatuses.contains(status) ? status : Self.statusActive }

    var statusTitle: String {
        MemoryEntry.statusTitle(status)
    }

    var statusIcon: String {
        MemoryEntry.statusIcon(status)
    }

    /// 按状态取值取标题（菜单渲染用，非法值同样归 active）。
    /// 与实例版同源 —— 两份各写一份 switch 的话，后端加一个状态就会有一边显示空白胶囊。
    static func statusTitle(_ s: String) -> String {
        switch s {
        case statusPending: return "待确认"
        case statusStale: return "可能过时"
        default: return "生效中"
        }
    }

    static func statusIcon(_ s: String) -> String {
        switch s {
        case statusPending: return "questionmark.circle"
        case statusStale: return "clock.arrow.circlepath"
        default: return "checkmark.circle"
        }
    }

    var statusColor: Color {
        switch normalizedStatus {
        case Self.statusPending: return .orange
        case Self.statusStale: return .secondary
        default: return .green
        }
    }

    /// 标灰只给 stale：过时条目仍会注入 prompt（只是提醒可能不准），
    /// 全灰会让用户以为它不生效、直接删掉 —— 那才是真损失。
    var isDimmed: Bool { normalizedStatus == Self.statusStale }

    var sourceTitle: String {
        switch source {
        case "chat": return "聊天中自动记住"
        case "manual": return "手动添加"
        default: return ""
        }
    }

    var sourceIcon: String {
        source == "chat" ? "bubble.left.and.bubble.right" : "hand.tap"
    }

    var hasSource: Bool { !sourceTitle.isEmpty }

    /// 有来源会话才给"看来源"入口 —— 没有 sessionId 时点进去只会打开一个空会话。
    var canOpenSource: Bool { !sessionId.isEmpty }

    /// 展示用日期：优先更新时间（用户关心"我上次改它是什么时候"），没有才回落到创建时间。
    var displayDate: Date? { updated ?? created }

    /// 从后端 JSON 解析。**单条失败不影响整页**（返回 nil 让调用方跳过那条），
    /// 绝不因为一条脏数据把整个记忆页清空。
    static func from(_ any: Any) -> MemoryEntry? {
        guard let d = any as? [String: Any] else { return nil }
        let text = (d["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        return MemoryEntry(
            text: text,
            status: d["status"] as? String ?? statusActive,
            created: MemoryEntry.date(d["created"]),
            updated: MemoryEntry.date(d["updated"]),
            source: d["source"] as? String ?? "",
            sessionId: d["sessionId"] as? String ?? ""
        )
    }

    /// 兜底构造：老后端只给 entries 字符串时用（状态 active、无日期、无来源）。
    static func legacy(_ text: String) -> MemoryEntry {
        MemoryEntry(text: text, status: statusActive, created: nil, updated: nil,
                 source: "", sessionId: "")
    }

    /// 解析整份响应：**优先 items，缺失/全空则回落 entries**。
    static func parse(_ json: [String: Any]) -> [MemoryEntry] {
        if let arr = json["items"] as? [Any] {
            let out = arr.compactMap { MemoryEntry.from($0) }
            if !out.isEmpty { return out }
        }
        return ((json["entries"] as? [String]) ?? []).map { MemoryEntry.legacy($0) }
    }

    /// 响应体里**是否带了列表字段**（用于区分「解析失败」与「后端真的空了」）。
    ///
    /// v4.0.15 修的坑：调用方一律写 `if !p.isEmpty { items = p }` 时，
    /// 用户删光最后一条记忆 → 后端 `entries`/`items` 都是 `[]`（合法且正确）→
    /// 解析出空数组 → 赋值被跳过 → 界面保留旧列表，条目看着删不掉。
    /// 所以要问的是「字段在不在」，不是「解析出东西没有」。
    static func hasListField(_ json: [String: Any]) -> Bool {
        json["items"] is [Any] || json["entries"] is [Any]
    }

    /// created/updated 是**秒级** Unix 时间戳。
    /// 写成毫秒（或 0/负数）就乘 1000 兜一下，避免 Date 远到"2093 年"这种一眼假的值。
    private static func date(_ any: Any?) -> Date? {
        guard let v = any as? NSNumber, v.doubleValue > 0 else { return nil }
        let s = v.doubleValue
        return Date(timeIntervalSince1970: s > 1_000_000_000_000 ? s / 1000 : s)
    }
}

// MARK: - 状态胶囊（第 4 项）

struct MemoStatusChip: View {
    let item: MemoryEntry

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: item.statusIcon)
                .font(.system(size: 9))
            Text(item.statusTitle)
                .font(.system(size: Typography.caption, weight: .medium))
        }
        .foregroundStyle(item.statusColor)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 2)
        .background(item.statusColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Radius.chip))
    }
}
