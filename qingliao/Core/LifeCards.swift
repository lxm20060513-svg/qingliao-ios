import Foundation

// MARK: - v3.5.x 看板「生活数据」卡片模型（后端 GET /api/life/cards）
//
// 后端返回统一结构 {"ok":bool,"ts":Int,"cards":[{kind:"stock"|"rss"|"express"|"price",…}]}，
// 这里只做纯解析（无网络、无 AuthStore 依赖）——请求走 DashboardView 的 auth.jsonOrLog，
// 避免在 Core 层引入 @MainActor 隔离/并发上的额外风险。
//
// 覆盖范围：stock（LifeStock）/ rss（LifeRssEntry + LifeRssSource）/
//          express（LifeExpressCard + LifeExpressParcel）/ price（LifePriceCard + LifePriceWatchItem）
//          —— v3.9.32 起快递 / 价格监控已从占位小字升级为真卡片；
//          packages / items 为空时仍落 LifePlaceholderItem（引导文案，不建空卡）。

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

    /// JSONSerialization 字符串容错（String / NSNumber）——后端状态码偶发数字型
    static func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
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

// MARK: - v3.9.32 快递卡（后端 GET /api/life/cards "kind":"express"）
//
// 字段以 NAS 后端源码 life_api.py（_fetch_package / _collect_express）为准（2026-09-17 核对）：
//   卡级 {"kind":"express","id":"express","title":"快递","ok":bool,"packages":[…],"error":str[, "hint":str]}
//     未添加快递单号时 packages=[] + error="未添加快递单号" + hint="设置 → 生活卡片 → 快递"
//   条目 {"no":"YT…","carrier":"yuantong","carrierName":"圆通速递","name":"我的快递",
//         "ok":bool,"error":str,"state":"3","stateText":"已签收",
//         "latest":{"time":"2026-09-17 13:28:46","context":"…"} | null}
//   ⚠️ 单号查无结果时 ok=false 但仍带 latest（context="查无结果"）与 error 文案；
//      stateText 只在查出状态时非空（后端 STATE_TEXT 映射）——UI 必须给兜底文案，不能渲染空行。
//   ⚠️ 类型名刻意用「Parcel」而非「Package」：Core/LifeConfig.swift 已有配置侧 LifeExpressPackage，
//      同模块重名 = 编译失败（而 check_swift.sh 只做语法解析，查不出重名）。

/// 单件快递（后端 packages[]）
struct LifeExpressParcel: Identifiable {
    let id: String          // 列表 id：运单号（后端按 no 去重）；异常数据无单号时回退「名称#序号」
    let no: String
    let carrier: String     // 编码（yuantong / shunfeng / 自定义源原值）
    let carrierName: String // 展示名（后端映射；自定义源可能回落成编码）
    let name: String        // 用户备注（后端默认填单号）
    let state: String       // 快递100 状态码（"3" = 已签收）
    let stateText: String   // 状态文案（"已揽收" / "已签收"…，未查到为空）
    let traceTime: String   // 最新轨迹时间（上游本地时间串，如 "2026-09-17 13:28:46"）
    let trace: String       // 最新轨迹上下文
    let ok: Bool
    let error: String

    /// 快递公司展示名：carrierName 为空才回落编码（自定义源可能两者都空）
    var carrierLabel: String { carrierName.isEmpty ? carrier : carrierName }

    /// 标题：用户备注优先；未起名时用单号（后端两者都可能为空 → 兜底「快递」）
    var title: String {
        if !name.isEmpty, name != no { return name }
        return no.isEmpty ? "快递" : no
    }

    /// 运单号只露后 4 位（截图/转述场景不暴露完整单号）
    var maskedNo: String {
        no.count > 4 ? "尾号 " + String(no.suffix(4)) : no
    }

    /// 状态胶囊文案：后端 stateText 为空时按 ok 兜底（后端默认「已查询」）
    var statusText: String {
        guard ok else { return "" }
        return stateText.isEmpty ? "已查询" : stateText
    }

    /// 已签收（后端 STATE_TEXT["3"]）——已签收的行弱化显示
    var isDelivered: Bool { state == "3" }

    /// 主体文案：成功给最新轨迹，失败给后端 error（两边都有内容，不留空行）
    var detailText: String {
        if ok { return trace.isEmpty ? "暂无轨迹详情" : trace }
        return error.isEmpty ? "查询失败" : error
    }

    /// 相对时间：后端给的是北京时间串，解析不出就原样显示（不显示空白）
    var timeText: String { LifeCardsData.relativeTimeText(traceTime) }

    static func parse(_ j: [String: Any], index: Int) -> LifeExpressParcel? {
        let no = LifeStock.str(j["no"])
        let name = LifeStock.str(j["name"])
        guard !no.isEmpty || !name.isEmpty else { return nil }
        let latest = j["latest"] as? [String: Any] ?? [:]
        return LifeExpressParcel(id: no.isEmpty ? "\(name)#\(index)" : no,
                                 no: no,
                                 carrier: LifeStock.str(j["carrier"]),
                                 carrierName: LifeStock.str(j["carrierName"]),
                                 name: name,
                                 state: LifeStock.str(j["state"]),
                                 stateText: LifeStock.str(j["stateText"]),
                                 traceTime: LifeStock.str(latest["time"]),
                                 trace: LifeStock.str(latest["context"]),
                                 ok: (j["ok"] as? Bool) ?? false,
                                 error: LifeStock.str(j["error"]))
    }
}

/// 快递卡（后端 "kind":"express" 整张卡）
struct LifeExpressCard: Identifiable {
    let id: String
    let title: String
    let ok: Bool
    let error: String
    let hint: String        // 未配置时的引导（"设置 → 生活卡片 → 快递"）
    let packages: [LifeExpressParcel]

    var hasPackages: Bool { !packages.isEmpty }
    var countText: String { "\(packages.count) 件" }

    /// 已签收件数（卡头弱化提示 + 行弱化用）
    var deliveredCount: Int { packages.filter { $0.isDelivered }.count }

    static func parse(_ j: [String: Any]) -> LifeExpressCard? {
        guard LifeStock.str(j["kind"]) == "express" else { return nil }
        // 用 as? [Any] 再逐个取字典：数组里混进一个非字典元素时，不会把整张卡的件数清零
        let raw = (j["packages"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        var pkgs: [LifeExpressParcel] = []
        for (i, r) in raw.enumerated() {
            if let p = LifeExpressParcel.parse(r, index: i) { pkgs.append(p) }
        }
        let cid = LifeStock.str(j["id"])
        let ctitle = LifeStock.str(j["title"])
        return LifeExpressCard(id: cid.isEmpty ? "express" : cid,
                               title: ctitle.isEmpty ? "快递" : ctitle,
                               ok: (j["ok"] as? Bool) ?? false,
                               error: LifeStock.str(j["error"]),
                               hint: LifeStock.str(j["hint"]),
                               packages: pkgs)
    }
}

// MARK: - v3.9.32 价格监控卡（后端 "kind":"price"）
//
// 字段以后端源码 life_api.py（_fetch_price / _collect_price）为准（2026-09-17 核对）：
//   卡级 {"kind":"price","id":"price","title":"价格监控","ok":bool,"items":[…],"error":str[, "hint":str]}
//     未添加监控商品时 items=[] + error="未添加监控商品" + hint="设置 → 生活卡片 → 价格监控"
//   条目 {"name":"…","url":"…","price":129.0|null,"currency":"CNY","target":100.0|null,
//         "hit":bool,"ok":bool,"error":str}
//   ⚠️ hit 只在「设了目标价且现价 ≤ 目标价」时为 true（后端仅 target 非空时才写 hit）
//      → 到价判定必须是 hit && target != nil，单看 hit 无法区分「未设目标价」。
//   ⚠️ 类型名用 LifePriceWatchItem：Core/LifeConfig.swift 已有配置侧 LifePriceItem（同模块不能重名）。

/// 单个监控商品（后端 items[]）
struct LifePriceWatchItem: Identifiable {
    let id: String
    let name: String
    let url: String
    let price: Double?
    let currency: String    // CNY / HKD / USD …（后端默认 CNY）
    let target: Double?     // 目标价（未设 = null）
    let hit: Bool           // 后端到价标记（仅设了目标价时可能为 true）
    let ok: Bool
    let error: String       // 失败原因（"未填写商品 URL" / "抓取失败: …" / "未配置提取规则"…）

    /// 商品名：后端已兜底成域名；两者都空时回落 URL / 占位文案
    var displayName: String {
        if !name.isEmpty { return name }
        if !host.isEmpty { return host }
        return url.isEmpty ? "未命名商品" : url
    }

    /// URL 主机名（未命名商品的兜底显示）
    var host: String { URL(string: url)?.host ?? "" }

    /// 货币符号（与 Models.swift 的币种显示口径一致，未知币种退化为编码前缀）
    var symbol: String { LifePriceWatchItem.currencySymbol(currency) }

    /// 现价：¥129.00（未取到 = "--"，与行情卡的数值口径一致）
    var priceText: String {
        guard ok, let p = price else { return "--" }
        return symbol + String(format: "%.2f", p)
    }

    /// 目标价：目标 ¥100.00（未设目标价 = 空串，UI 不渲染这一段）
    var targetText: String {
        guard let t = target else { return "" }
        return "目标 " + symbol + String(format: "%.2f", t)
    }

    /// 到价（现价 ≤ 目标价）：后端 hit 未设目标价时恒为 false，必须带 target 一起判定
    var isReached: Bool { ok && hit && target != nil }

    /// 失败说明（无法取价时展示，不留空行）
    var failureText: String { error.isEmpty ? "未取到价格" : error }

    static func currencySymbol(_ c: String) -> String {
        switch c.uppercased() {
        case "", "CNY", "RMB": return "¥"
        case "USD": return "$"
        case "HKD": return "HK$"
        case "JPY": return "¥"
        case "EUR": return "€"
        default: return c.uppercased() + " "
        }
    }

    static func parse(_ j: [String: Any], index: Int) -> LifePriceWatchItem? {
        let url = LifeStock.str(j["url"])
        let name = LifeStock.str(j["name"])
        guard !url.isEmpty || !name.isEmpty else { return nil }
        return LifePriceWatchItem(id: url.isEmpty ? "\(name)#\(index)" : url,
                             name: name,
                             url: url,
                             price: LifeStock.number(j["price"]),
                             currency: LifeStock.str(j["currency"]),
                             target: LifeStock.number(j["target"]),
                             hit: (j["hit"] as? Bool) ?? false,
                             ok: (j["ok"] as? Bool) ?? false,
                             error: LifeStock.str(j["error"]))
    }
}

/// 价格监控卡（后端 "kind":"price" 整张卡）
struct LifePriceCard: Identifiable {
    let id: String
    let title: String
    let ok: Bool
    let error: String
    let hint: String        // 未配置时的引导（"设置 → 生活卡片 → 价格监控"）
    let items: [LifePriceWatchItem]

    var hasItems: Bool { !items.isEmpty }
    var countText: String { "\(items.count) 项" }

    /// 到价项数（卡头高亮提示用）
    var reachedCount: Int { items.filter { $0.isReached }.count }

    static func parse(_ j: [String: Any]) -> LifePriceCard? {
        guard LifeStock.str(j["kind"]) == "price" else { return nil }
        // 同快递卡：逐元素取字典，单条脏数据不影响其余商品
        let raw = (j["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        var list: [LifePriceWatchItem] = []
        for (i, r) in raw.enumerated() {
            if let it = LifePriceWatchItem.parse(r, index: i) { list.append(it) }
        }
        let cid = LifeStock.str(j["id"])
        let ctitle = LifeStock.str(j["title"])
        return LifePriceCard(id: cid.isEmpty ? "price" : cid,
                             title: ctitle.isEmpty ? "价格监控" : ctitle,
                             ok: (j["ok"] as? Bool) ?? false,
                             error: LifeStock.str(j["error"]),
                             hint: LifeStock.str(j["hint"]),
                             items: list)
    }
}

/// 「未配置」占位小字（快递 / 价格监控在 packages / items 为空时落到这里）
/// ——后端给 kind + error（+ hint）文案，UI 只显示小字，不空白、也不显示空卡
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
    /// v3.9.32：快递卡（后端 packages 非空才存在；未配置单号时不建卡，避免空卡）
    var express: LifeExpressCard?
    /// v3.9.32：价格监控卡（后端 items 非空才存在）
    var price: LifePriceCard?
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

    /// 是否有行情 / 资讯内容（这两类为空时页面走「未配置」提示；快递/价格另判 hasLifeCards）
    var hasContent: Bool {
        !stocks.isEmpty || !entries.isEmpty
    }

    /// v3.9.32：是否有快递 / 价格监控真卡片（用于「一条生活卡片都没配」的判定）
    var hasLifeCards: Bool {
        (express?.hasPackages ?? false) || (price?.hasItems ?? false)
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
            case "express":
                // v3.9.32：有单号 = 真卡片；无单号（后端 packages:[] + hint）= 保留占位小字，不建空卡
                if let card = LifeExpressCard.parse(c), card.hasPackages {
                    d.express = card
                } else if let p = LifePlaceholderItem.parse(c) {
                    d.placeholders.append(p)
                }
            case "price":
                if let card = LifePriceCard.parse(c), card.hasItems {
                    d.price = card
                } else if let p = LifePlaceholderItem.parse(c) {
                    d.placeholders.append(p)
                }
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
        return relativeFrom(d)
    }

    /// v3.9.32：上游时间串 → 相对时间；**解析不出时原样返回**（宁可显示原始时间，也不留空白）
    /// 快递 100 等上游给的是北京时间串（"2026-09-17 13:28:46"，无时区标记），按东八区解释。
    static func relativeTimeText(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        guard let d = parseUpstreamTime(s) else { return s }
        return relativeFrom(d)
    }

    /// 相对时间正文（绝对值差 → 中文措辞；未来时间按「刚刚」处理）
    private static func relativeFrom(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "刚刚" }
        if secs < 3600 { return "\(secs / 60) 分钟前" }
        if secs < 86400 { return "\(secs / 3600) 小时前" }
        if secs < 86400 * 7 { return "\(secs / 86400) 天前" }
        let df = DateFormatter()
        df.dateFormat = "MM-dd"
        return df.string(from: d)
    }

    /// 上游时间串容错解析：ISO8601（含毫秒）→ 东八区常见格式 → 无年份的「MM-dd HH:mm」
    private static func parseUpstreamTime(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let cst = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd HH:mm",
                       "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"]
        for f in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = cst
            df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        // 无年份（自定义源可能给 "09-17 13:28"）→ 按当年补全
        for f in ["MM-dd HH:mm:ss", "MM-dd HH:mm"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = cst
            df.dateFormat = f
            guard let d = df.date(from: s) else { continue }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = cst
            return cal.date(bySetting: .year, value: cal.component(.year, from: Date()), of: d) ?? d
        }
        return nil
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
