import Foundation

// MARK: - v3.5.x 生活卡片配置模型（纯解析 / 序列化）
//
// 与后端 life_api.normalize_config（v2）的权威 schema 完全一致，字段名不做任何改写：
//   {"version":2,
//    "stocks":[{"market":"1","code":"601138"}],
//    "rss":[{"name":"少数派","url":"https://sspai.com/feed"}],
//    "express":{"source":{"type":"free"|"custom","url_template":"","headers":{},
//                         "key":"","list_path":"data","time_key":"time",
//                         "context_key":"context","state_path":"state"},
//               "packages":[{"no":"单号","carrier":"sf","name":"顺丰速运"}]},
//    "price":{"source":{"headers":{},"timeout":8},
//             "items":[{"name":"","url":"","extract":"regex"|"json","pattern":"","path":"",
//                       "group":1,"currency":"CNY","target":null}]}}
//
// 本文件只做纯数据（不依赖网络、不依赖 AuthStore）：请求由视图层走 auth.jsonOrLog，
// 与 LifeCards.swift 的定位一致。缺失字段一律给默认值；超限（股票/资讯/快递/价格 ≤20）
// 由后端 normalize_config 截断，App 侧不做二次裁剪以免与后端不一致。

// MARK: - 底层取值容错（JSONSerialization 的 NSNumber 桥接）

private func lifeNumber(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

private func lifeInt(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let n = v as? NSNumber { return n.intValue }
    if let s = v as? String { return Int(s) }
    return nil
}

private func lifeString(_ v: Any?) -> String {
    if let s = v as? String { return s }
    if let i = v as? Int { return String(i) }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

private func lifeBool(_ v: Any?) -> Bool {
    if let b = v as? Bool { return b }
    if let n = v as? NSNumber { return n.boolValue }
    return false
}

/// headers 对象 → 有序键值对（按 key 排序，保证每次渲染顺序稳定）
private func lifeHeaders(_ v: Any?) -> [LifeHeaderPair] {
    guard let d = v as? [String: Any] else { return [] }
    return d.keys.sorted().map { LifeHeaderPair(key: $0, value: lifeString(d[$0])) }
}

/// 有序键值对 → headers 对象（忽略空 key，同 key 后者覆盖）
private func lifeHeadersJSON(_ pairs: [LifeHeaderPair]) -> [String: String] {
    var d: [String: String] = [:]
    for p in pairs {
        let k = p.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { continue }
        d[k] = p.value
    }
    return d
}

// MARK: - 键值对（headers 的 UI 可编辑形态）

struct LifeHeaderPair: Equatable {
    var key: String = ""
    var value: String = ""
}

// MARK: - 股票

struct LifeStockRef: Identifiable, Equatable {
    var market: String = "1"
    var code: String = ""

    var id: String { market + "." + code }

    var json: [String: Any] { ["market": market, "code": code] }

    static func parse(_ j: [String: Any]) -> LifeStockRef? {
        let code = lifeString(j["code"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        let m = lifeString(j["market"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return LifeStockRef(market: m.isEmpty ? "1" : m, code: code)
    }
}

// MARK: - 资讯源

struct LifeRssSourceRef: Identifiable, Equatable {
    var name: String = ""
    var url: String = ""

    var id: String { url.isEmpty ? name : url }

    /// 展示用域名（去掉 scheme / 路径）
    var domain: String {
        var s = url
        for p in ["https://", "http://"] where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count))
        }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return s.isEmpty ? url : s
    }

    var json: [String: Any] { ["name": name, "url": url] }

    static func parse(_ j: [String: Any]) -> LifeRssSourceRef? {
        let name = lifeString(j["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = lifeString(j["url"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !url.isEmpty else { return nil }
        return LifeRssSourceRef(name: name.isEmpty ? url : name, url: url)
    }

    /// URL 必须 http(s)://（自定义资讯源的硬校验）
    static func isHTTPURL(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return false }
        guard let u = URL(string: s), let host = u.host, !host.isEmpty else { return false }
        return true
    }
}

// MARK: - 快递

struct LifeExpressPackage: Identifiable, Equatable {
    var no: String = ""
    var carrier: String = ""
    var name: String = ""

    var id: String { no + "#" + carrier }

    var json: [String: Any] { ["no": no, "carrier": carrier, "name": name] }

    static func parse(_ j: [String: Any]) -> LifeExpressPackage? {
        let no = lifeString(j["no"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !no.isEmpty else { return nil }
        return LifeExpressPackage(no: no,
                                  carrier: lifeString(j["carrier"]),
                                  name: lifeString(j["name"]))
    }
}

/// 快递数据源（免费接口 / 自定义聚合接口）
struct LifeExpressSource: Equatable {
    var type: String = "free"          // free | custom
    var urlTemplate: String = ""
    var headers: [LifeHeaderPair] = []
    var key: String = ""
    var listPath: String = "data"
    var timeKey: String = "time"
    var contextKey: String = "context"
    var statePath: String = "state"

    var isCustom: Bool { type == "custom" }

    var json: [String: Any] {
        ["type": type,
         "url_template": urlTemplate,
         "headers": lifeHeadersJSON(headers),
         "key": key,
         "list_path": listPath,
         "time_key": timeKey,
         "context_key": contextKey,
         "state_path": statePath]
    }

    static func parse(_ j: [String: Any]) -> LifeExpressSource {
        var s = LifeExpressSource()
        if let t = j["type"] as? String, t == "custom" || t == "free" { s.type = t }
        s.urlTemplate = lifeString(j["url_template"])
        s.headers = lifeHeaders(j["headers"])
        s.key = lifeString(j["key"])
        if let v = j["list_path"] as? String, !v.isEmpty { s.listPath = v }
        if let v = j["time_key"] as? String, !v.isEmpty { s.timeKey = v }
        if let v = j["context_key"] as? String, !v.isEmpty { s.contextKey = v }
        if let v = j["state_path"] as? String, !v.isEmpty { s.statePath = v }
        return s
    }
}

struct LifeExpress: Equatable {
    var source: LifeExpressSource = LifeExpressSource()
    var packages: [LifeExpressPackage] = []

    var json: [String: Any] {
        ["source": source.json, "packages": packages.map { $0.json }]
    }

    static func parse(_ j: [String: Any]) -> LifeExpress {
        var e = LifeExpress()
        if let s = j["source"] as? [String: Any] { e.source = LifeExpressSource.parse(s) }
        e.packages = (j["packages"] as? [[String: Any]] ?? []).compactMap { LifeExpressPackage.parse($0) }
        return e
    }
}

// MARK: - 价格监控

struct LifePriceItem: Identifiable {
    /// 仅用于 UI 身份（不参与序列化）——索引变化时行身份不漂移
    var uid: String = UUID().uuidString
    var name: String = ""
    var url: String = ""
    var extract: String = "regex"      // regex | json
    var pattern: String = ""           // extract == regex 时使用
    var path: String = ""              // extract == json 时使用
    var group: Int = 1
    var currency: String = "CNY"
    var target: Double? = nil

    var id: String { uid }

    /// 目标价的文本形态（空 = 不设目标价，序列化为 null）
    var targetText: String {
        guard let t = target else { return "" }
        return String(format: "%g", t)
    }

    var json: [String: Any] {
        var d: [String: Any] = ["name": name,
                                "url": url,
                                "extract": extract,
                                "pattern": pattern,
                                "path": path,
                                "group": group,
                                "currency": currency]
        d["target"] = target.map { $0 as Any } ?? NSNull()
        return d
    }

    static func parse(_ j: [String: Any]) -> LifePriceItem {
        var p = LifePriceItem()
        p.name = lifeString(j["name"])
        p.url = lifeString(j["url"])
        if let e = j["extract"] as? String, e == "json" || e == "regex" { p.extract = e }
        p.pattern = lifeString(j["pattern"])
        p.path = lifeString(j["path"])
        if let g = lifeInt(j["group"]) { p.group = g }
        if let c = j["currency"] as? String, !c.isEmpty { p.currency = c }
        p.target = lifeNumber(j["target"])
        return p
    }
}

struct LifePriceSource: Equatable {
    var headers: [LifeHeaderPair] = []
    var timeout: Int = 8               // 3~20

    var json: [String: Any] { ["headers": lifeHeadersJSON(headers), "timeout": timeout] }

    static func parse(_ j: [String: Any]) -> LifePriceSource {
        var s = LifePriceSource()
        s.headers = lifeHeaders(j["headers"])
        if let t = lifeInt(j["timeout"]) { s.timeout = min(20, max(3, t)) }
        return s
    }
}

struct LifePrice {
    var source: LifePriceSource = LifePriceSource()
    var items: [LifePriceItem] = []

    var json: [String: Any] {
        ["source": source.json, "items": items.map { $0.json }]
    }

    static func parse(_ j: [String: Any]) -> LifePrice {
        var p = LifePrice()
        if let s = j["source"] as? [String: Any] { p.source = LifePriceSource.parse(s) }
        p.items = (j["items"] as? [[String: Any]] ?? []).map { LifePriceItem.parse($0) }
        return p
    }
}

// MARK: - 配置整体

struct LifeConfig {
    var version: Int = 2
    var stocks: [LifeStockRef] = []
    var rss: [LifeRssSourceRef] = []
    var express: LifeExpress = LifeExpress()
    var price: LifePrice = LifePrice()

    /// POST /api/life/config 的 body["config"] 形态
    var json: [String: Any] {
        ["version": version,
         "stocks": stocks.map { $0.json },
         "rss": rss.map { $0.json },
         "express": express.json,
         "price": price.json]
    }

    static func parse(_ j: [String: Any]) -> LifeConfig {
        var c = LifeConfig()
        if let v = lifeInt(j["version"]) { c.version = v }
        c.stocks = (j["stocks"] as? [[String: Any]] ?? []).compactMap { LifeStockRef.parse($0) }
        c.rss = (j["rss"] as? [[String: Any]] ?? []).compactMap { LifeRssSourceRef.parse($0) }
        if let e = j["express"] as? [String: Any] { c.express = LifeExpress.parse(e) }
        if let p = j["price"] as? [String: Any] { c.price = LifePrice.parse(p) }
        return c
    }
}

// MARK: - 预设目录（GET /api/life/config 的 presets）

struct LifeStockPreset: Identifiable {
    let market: String
    let code: String
    let name: String

    var id: String { market + "." + code }

    static func parse(_ j: [String: Any]) -> LifeStockPreset? {
        let code = lifeString(j["code"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        return LifeStockPreset(market: lifeString(j["market"]),
                               code: code,
                               name: lifeString(j["name"]))
    }
}

struct LifeRssPreset: Identifiable {
    let name: String
    let url: String
    let builtin: Bool

    var id: String { url.isEmpty ? name : url }

    var domain: String { LifeRssSourceRef(name: name, url: url).domain }

    static func parse(_ j: [String: Any]) -> LifeRssPreset? {
        let name = lifeString(j["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = lifeString(j["url"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !url.isEmpty else { return nil }
        return LifeRssPreset(name: name.isEmpty ? url : name, url: url, builtin: lifeBool(j["builtin"]))
    }
}

struct LifeCarrier: Identifiable {
    let code: String
    let name: String

    var id: String { code }

    static func parse(_ j: [String: Any]) -> LifeCarrier? {
        let code = lifeString(j["code"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        return LifeCarrier(code: code, name: lifeString(j["name"]))
    }
}

struct LifeMarket: Identifiable {
    let code: String
    let name: String

    var id: String { code }

    static func parse(_ j: [String: Any]) -> LifeMarket? {
        let code = lifeString(j["code"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        return LifeMarket(code: code, name: lifeString(j["name"]))
    }
}

struct LifePresets {
    var stocks: [LifeStockPreset] = []
    var rss: [LifeRssPreset] = []
    var carriers: [LifeCarrier] = []
    var markets: [LifeMarket] = []

    static func parse(_ j: [String: Any]) -> LifePresets {
        var p = LifePresets()
        p.stocks = (j["stocks"] as? [[String: Any]] ?? []).compactMap { LifeStockPreset.parse($0) }
        p.rss = (j["rss"] as? [[String: Any]] ?? []).compactMap { LifeRssPreset.parse($0) }
        p.carriers = (j["carriers"] as? [[String: Any]] ?? []).compactMap { LifeCarrier.parse($0) }
        p.markets = (j["markets"] as? [[String: Any]] ?? []).compactMap { LifeMarket.parse($0) }
        return p
    }

    // MARK: 显示名映射

    /// 股票中文名：优先 market+code 精确匹配，再退化到 code 匹配，最后显示代码
    func stockName(_ s: LifeStockRef) -> String {
        if let m = stocks.first(where: { $0.code == s.code && $0.market == s.market }), !m.name.isEmpty {
            return m.name
        }
        if let m = stocks.first(where: { $0.code == s.code }), !m.name.isEmpty {
            return m.name
        }
        return s.code
    }

    func marketName(_ code: String) -> String {
        if let m = markets.first(where: { $0.code == code }), !m.name.isEmpty { return m.name }
        return code.isEmpty ? "A股" : code
    }

    /// 快递公司中文名（carrier code → 中文名），未知 code 原样显示
    func carrierName(_ code: String) -> String {
        if let c = carriers.first(where: { $0.code == code }), !c.name.isEmpty { return c.name }
        return code
    }
}
