import Foundation

// MARK: - v3.5.x 看板「生活数据」卡片模型（后端 GET /api/life/cards）
//
// 后端返回统一结构 {"ok":bool,"ts":Int,"cards":[{kind:"stock"|"rss"|"express"|"price",…}]}，
// 这里只做纯解析（无网络、无 AuthStore 依赖）——请求走 DashboardView 的 auth.jsonOrLog，
// 避免在 Core 层引入 @MainActor 隔离/并发上的额外风险。

/// 股票行情卡（parse 后端 "kind":"stock"）
struct LifeStock: Identifiable {
    let id: String          // "1.601138"（市场.代码）
    let name: String
    let code: String
    let currency: String    // CNY / HKD / USD
    let price: Double?
    let change: Double?
    let changePct: Double?
    let ok: Bool
    let error: String

    /// 主数值：2 位小数（A股/港股/美股统一显示口径）
    var priceText: String {
        guard let p = price, p > 0 else { return "--" }
        return String(format: "%.2f", p)
    }

    /// 涨跌幅：+1.16% / -2.04% / --（数据未就绪时提示"无行情"）
    var changeText: String {
        guard ok, let c = changePct else { return ok ? "--" : "无行情" }
        return String(format: "%@%.2f%%", c >= 0 ? "+" : "", c)
    }

    /// 副文本：涨跌幅 + 代码（代码便于对号，避免同名标的误读）
    var detailText: String {
        code.isEmpty ? changeText : "\(changeText) · \(code)"
    }

    /// 涨跌方向（true 为涨）
    var isUp: Bool { (changePct ?? 0) >= 0 }

    static func parse(_ j: [String: Any]) -> LifeStock? {
        guard let id = j["id"] as? String, !id.isEmpty else { return nil }
        let code = j["code"] as? String ?? ""
        return LifeStock(id: id,
                         name: j["name"] as? String ?? (code.isEmpty ? id : code),
                         code: code,
                         currency: j["currency"] as? String ?? "",
                         price: number(j["price"]),
                         change: number(j["change"]),
                         changePct: number(j["change_pct"]),
                         ok: (j["ok"] as? Bool) ?? false,
                         error: j["error"] as? String ?? "")
    }

    /// JSONSerialization 数值容错（Int / Double / NSNumber / 字符串）
    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

/// RSS / 博客条目（后端 "kind":"rss" 的 entries[]）
struct LifeRssEntry: Identifiable {
    let id: String
    let title: String
    let link: String
    let source: String
    let published: String   // UTC ISO8601

    var timeText: String { LifeCardsData.relativeTime(published) }

    static func parse(_ j: [String: Any]) -> LifeRssEntry? {
        guard let t = j["title"] as? String, !t.isEmpty else { return nil }
        let link = j["link"] as? String ?? ""
        return LifeRssEntry(id: link.isEmpty ? t : link,
                            title: t,
                            link: link,
                            source: j["source"] as? String ?? "",
                            published: j["published"] as? String ?? "")
    }
}

/// RSS 源健康状态（用于降级提示：哪个源挂了）
struct LifeRssSource: Identifiable {
    let id: String
    let name: String
    let ok: Bool
    let error: String
    let count: Int

    static func parse(_ j: [String: Any]) -> LifeRssSource? {
        guard let n = j["name"] as? String, !n.isEmpty else { return nil }
        return LifeRssSource(id: n, name: n,
                             ok: (j["ok"] as? Bool) ?? false,
                             error: j["error"] as? String ?? "",
                             count: (j["count"] as? Int) ?? 0)
    }
}

/// 未接入的占位卡（快递 / 价格监控）——后端给 kind + error 文案，UI 只显示小字，不空白
struct LifePlaceholderItem: Identifiable {
    let id: String
    let title: String
    let note: String
    let hint: String

    static func parse(_ j: [String: Any]) -> LifePlaceholderItem? {
        guard let k = j["kind"] as? String, !k.isEmpty else { return nil }
        return LifePlaceholderItem(id: k,
                                   title: j["title"] as? String ?? k,
                                   note: j["error"] as? String ?? "未配置数据源",
                                   hint: j["hint"] as? String ?? "")
    }
}

/// 生活数据整体（看板一份状态）
struct LifeCardsData {
    var stocks: [LifeStock] = []
    var entries: [LifeRssEntry] = []
    var rssSources: [LifeRssSource] = []
    var placeholders: [LifePlaceholderItem] = []
    var updated: Date?
    var error: String = ""       // 后端整体错误（全源失败时非空）
    var loaded = false           // 是否已成功解析过一次响应

    /// 更新时刻："更新于 14:32"
    var updatedText: String {
        guard let d = updated else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "更新于 " + f.string(from: d)
    }

    /// 失败源的降级提示："IT之家 获取失败"；全源失败时用后端整体 error
    var rssErrorText: String {
        let bad = rssSources.filter { !$0.ok }.map(\.name)
        if !bad.isEmpty {
            return bad.joined(separator: "、") + " 获取失败"
        }
        return ""
    }

    /// 是否有可展示内容（都没有时显示降级小字）
    var hasContent: Bool {
        !stocks.isEmpty || !entries.isEmpty
    }

    static func parse(_ j: [String: Any]) -> LifeCardsData {
        var d = LifeCardsData()
        d.loaded = true
        for c in (j["cards"] as? [[String: Any]] ?? []) {
            switch c["kind"] as? String ?? "" {
            case "stock":
                if let s = LifeStock.parse(c) { d.stocks.append(s) }
            case "rss":
                d.entries = (c["entries"] as? [[String: Any]] ?? []).compactMap { LifeRssEntry.parse($0) }
                d.rssSources = (c["sources"] as? [[String: Any]] ?? []).compactMap { LifeRssSource.parse($0) }
                if let e = c["error"] as? String, !e.isEmpty, d.entries.isEmpty { d.error = e }
            case "express", "price":
                if let p = LifePlaceholderItem.parse(c) { d.placeholders.append(p) }
            default:
                break
            }
        }
        if let ts = LifeStock.number(j["ts"]) { d.updated = Date(timeIntervalSince1970: ts) }
        if let e = j["error"] as? String, !e.isEmpty { d.error = e }
        return d
    }

    /// UTC ISO8601 → 相对时间（刚刚 / N 分钟前 / N 小时前 / N 天前 / MM-dd）
    static func relativeTime(_ iso: String) -> String {
        guard !iso.isEmpty else { return "" }
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]
        guard let d = isoFmt.date(from: iso) else { return "" }
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "刚刚" }
        if secs < 3600 { return "\(secs / 60) 分钟前" }
        if secs < 86400 { return "\(secs / 3600) 小时前" }
        if secs < 86400 * 7 { return "\(secs / 86400) 天前" }
        let df = DateFormatter()
        df.dateFormat = "MM-dd"
        return df.string(from: d)
    }
}


// MARK: - v3.6.2 资讯正文（后端 POST /api/life/article：抓 HTML → 清洗 → 模型整理，按 URL 缓存 6h）

/// 单条资讯的正文
struct LifeArticle {
    let ok: Bool
    let title: String
    let content: String
    let source: String      // "ai" = 模型整理；"raw" = 模型不可用时的降级原文
    let error: String
    let cached: Bool
    let truncated: Bool

    static func parse(_ j: [String: Any]) -> LifeArticle {
        LifeArticle(ok: (j["ok"] as? Bool) ?? false,
                    title: j["title"] as? String ?? "",
                    content: j["content"] as? String ?? "",
                    source: j["source"] as? String ?? "",
                    error: j["error"] as? String ?? "",
                    cached: (j["cached"] as? Bool) ?? false,
                    truncated: (j["truncated"] as? Bool) ?? false)
    }
}

/// 资讯正文在界面上的状态（由 LifeView 持有，卡片只读渲染）
enum LifeArticleState {
    case loading
    case loaded(LifeArticle)
    case failed(String)
}
