import Foundation

// MARK: - v4.0.22 候选池⑪ App 侧：账单截图识别入账（纯逻辑层）
//
// 后端契约（intent_api.extract_bill；`POST /api/agent/intent/bill`，与 `/api/intent/bill` 同体）：
//   入：{"image_b64": "…"}（**裸 base64**，不带 `data:` 前缀 —— 后端按图片魔数自己补 mime）
//   出：{"ok": true, "amount": 数字|null, "date": "YYYY-MM-DD"|"", "category": "餐饮/购物/…",
//       "item": "一句话摘要", "confidence": 0~1, "source": "cloud-vision"|"cloud-ocr"|"cloud"}
//   失败：{"ok": false, "error": "…"}，**HTTP 一律 200**（与 intent/extract 同口径）
//   → 判成败只能看 ok 字段，看状态码会把「图片过大」这种明确失败当成功。
//
// 为什么解析放这里（纯 Foundation、无 SwiftUI）：真值表能直接喂 JSON 字面量，把
// 「金额为 null」「分类不在白名单」「只有日期没有金额和摘要」这些分支钉死；视图里只剩 if let。
// 写入账本仍走 RecordStore.addDetailed（唯一落库口径），本文件**不碰存储、不碰网络**。

/// 识别出的账单草稿（用户确认前的中间态）
struct BillDraft: Equatable {
    /// 合计/实付金额；nil = 没认出来 → 必须用户手填
    /// （不拿 0 冒充：账本里 0 是一个真数字，会把「本月合计」算成有这笔）
    var amount: Double?
    /// "YYYY-MM-DD"；空串 = 没认出来
    var date: String
    /// 已收敛到 `BillScanKit.categories` 之一
    var category: String
    /// 一句话摘要；空串 = 没认出来（标题回退分类名）
    var item: String
    var confidence: Double

    /// 写进 RecordItem.source 的来源标记（账本行尾显示「扫账单」）
    static let source = "bill"
}

enum BillScanKit {

    /// 与后端 BILL_CATEGORIES **同一份白名单**（改这里 = 必须同时改 intent_api.py 的 BILL_CATEGORIES，
    /// 否则后端会把它眼里合法的分类收敛成「其他」，与 App 显示不一致）
    static let categories = ["餐饮", "购物", "交通", "医疗", "娱乐", "居住", "通讯", "其他"]

    /// 四舍五入到分：后端给的是 JSON 数字，21.400000000000002 这种浮点尾巴直接写进账本
    /// 会让「本月合计」看起来脏，CSV 导出也多出无意义小数位。
    static func money(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// `data:image/jpeg;base64,XXXX` → `XXXX`（后端只要裸 base64，前缀它自己补）
    static func base64(from dataURL: String) -> String? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let b64 = String(dataURL[dataURL.index(after: comma)...])
        return b64.isEmpty ? nil : b64
    }

    /// 出参 → 草稿。ok 不为真 / 没有任何可确认内容 → nil（调用方走 failText 显示原因）
    static func draft(from object: [String: Any]) -> BillDraft? {
        guard truthy(object["ok"]) else { return nil }
        let amount = number(object["amount"]).map(money)
        let item = text(object["item"])
        let rawCategory = text(object["category"])
        let category = categories.contains(rawCategory) ? rawCategory
            : (categories.last ?? "其他")
        // 反例（真值表钉着）：后端 _norm_bill 的判据是「amount/date/item 不是全空」——
        // 只有日期也能 ok:true，但那是一张没法入账的草稿（金额和摘要都空），
        // 弹出来只会让用户对着空表单发呆 → 这里当失败处理，让人重拍。
        if amount == nil && item.isEmpty { return nil }
        return BillDraft(amount: amount, date: text(object["date"]), category: category,
                         item: item, confidence: number(object["confidence"]) ?? 0)
    }

    /// 失败文案：后端 error 优先；它为空的时给人话（别把空字符串弹给用户）
    static func failText(from object: [String: Any]) -> String {
        let e = text(object["error"])
        return e.isEmpty ? "没认出账单内容，换一张清晰点的截图再试" : e
    }

    /// 入账标题：摘要为空时回退分类名。
    /// 为什么不就写空：addDetailed 第一行是 `guard !text.isEmpty else { return nil }`
    /// —— 空标题 = 点了「记入账本」却静默什么都没发生（最坏的那种 bug）。
    static func title(_ draft: BillDraft) -> String {
        draft.item.isEmpty ? draft.category : draft.item
    }

    /// 备注：来源 + 消费日期（账本里能回溯这条是扫出来的，同时不丢日期线索）
    static func note(_ draft: BillDraft) -> String {
        draft.date.isEmpty ? "扫账单" : "扫账单 · \(draft.date)"
    }

    /// 识别把握不大 → 让用户核对金额（confidence 是模型自评，只当提示，不做拦截：
    /// 拦下来 = 明明认对了也记不了账）
    static func needsReview(_ draft: BillDraft) -> Bool { draft.confidence < 0.5 }

    // MARK: JSON 取值（后端字段可能是 NSNull / String / NSNumber，三种都得吃下）

    private static func truthy(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return s == "true" || s == "1" }
        return false
    }

    static func number(_ v: Any?) -> Double? {
        // ⚠️ 两条分支都要挡 `isFinite`：`Double("inf")` / `Double("1e400")` 返回的是 inf 而不是 nil
        // （审查实测），漏了就会把 inf 带进账本 → 本月合计与 CSV 全变 inf。
        if let s = v as? String {
            guard let d = Double(s.trimmingCharacters(in: .whitespaces)) else { return nil }
            return d.isFinite ? d : nil
        }
        if let n = v as? NSNumber {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        return nil
    }

    static func text(_ v: Any?) -> String {
        guard let s = v as? String else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
