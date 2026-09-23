import Foundation

// MARK: - v3.9.71 记录容器（RecordKit）
//
// 定位：意图管道里「金额 / 读数」这类数字内容的落点。生活页新增一个「记录」分区，
//      与待办并列；写入走的是**已验证过的双写路径**（本地 UserDefaults + NAS JSON，
//      零后端改动，v3.9.35 待办清单就是这条）。
//
// 为什么拆成两个文件（照本仓分层，别合并回去）：
//   · 本文件 = 数据模型 + 合计/文案纯逻辑，**纯 Foundation 零 SwiftUI** →
//     scripts/test_intent_pipeline.swift 第 7 节能在没有 iOS SDK 的本机逐条断言。
//     合计口径错一个数、文案串了单位，用户在生活页看到的就是假数字。
//   · RecordStore.swift = 状态读写（@Observable，import SwiftUI），只能真机验。
//     所以**任何能写成纯函数的逻辑都别放 Store 里**。
//
// 合计口径（刻意保守，避免长成账本体系）：
//   · 只把 `unit == "元"` 的条目算进「本月合计」——度/kWh 是读数不是钱，混着加是无意义的数字。
//   · 读数单独走 latestMeter()，"最近读数"一行显示。
//   · 不按类别分组（第一版刻意不做类别字段，真需要了再加）。

/// 一条记录
struct RecordItem: Identifiable, Codable, Equatable, Sendable {
    var id: String
    /// amount（金额）/ meter（表读数）/ note（纯文字记录，缺 amount 时的兜底形态）
    var kind: String
    var title: String
    var amount: Double?
    var unit: String
    var note: String
    /// intent（意图管道写入）/ manual（生活页手写）/ chat（聊天气泡）
    var source: String
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, kind: String, title: String, amount: Double? = nil,
         unit: String = "", note: String = "", source: String = "manual",
         createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.amount = amount
        self.unit = unit
        self.note = note
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// 手写解码（坑 1，与 TodoItem 同款）：**新增字段一律 decodeIfPresent + 默认值**，
    /// 否则旧数据解不出来 → 整份记录在用户眼里"凭空消失"。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "note"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, amount, unit, note, source, createdAt, updatedAt
    }

    var sortDate: Date { updatedAt }

    /// 显示文案：有数值走数值文案；没有就退回 title/note（旧数据只有标题，不能显示空白）
    var amountText: String {
        if let a = amount, !unit.isEmpty { return RecordKit.amountText(a, unit: unit) }
        return note.isEmpty ? title : note
    }
}

enum RecordKit {

    /// "2026-09"（跨年靠年月组合，别用"第几月"糊过去）
    static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// 本月合计：**只算单位是「元」的**（读数混进来会算出毫无意义的和）
    static func monthTotal(_ items: [RecordItem], now: Date = Date(),
                           calendar: Calendar = .current) -> (amount: Double, count: Int) {
        let key = monthKey(now, calendar: calendar)
        var sum = 0.0
        var n = 0
        for i in items where i.unit == "元" {
            guard let a = i.amount else { continue }
            guard monthKey(i.createdAt, calendar: calendar) == key else { continue }
            sum += a
            n += 1
        }
        return (sum, n)
    }

    /// 最近一条读数（非「元」的数值条目）
    static func latestMeter(_ items: [RecordItem]) -> RecordItem? {
        items.filter { $0.unit != "元" && $0.amount != nil }
            .max { $0.createdAt < $1.createdAt }
    }

    /// 最新在前
    static func sorted(_ items: [RecordItem]) -> [RecordItem] {
        items.sorted { $0.sortDate > $1.sortDate }
    }

    /// 金额文案：元固定两位小数（钱要有分）；读数去掉无意义的尾零（1234 度，不是 1234.00 度）
    static func amountText(_ value: Double, unit: String) -> String {
        if unit == "元" { return String(format: "%.2f 元", value) }
        let s = String(format: "%.2f", value)
        let trimmed = s.contains(".") ? s.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression) : s
        return trimmed + " " + unit
    }
}
