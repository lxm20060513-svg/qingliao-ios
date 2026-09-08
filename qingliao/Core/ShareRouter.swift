import Foundation
import SwiftUI
import UIKit
import CoreLocation

// MARK: - v3.4.14 系统分享接入口
//
// 从其他 App（照片/文件/Safari/备忘录…）通过系统分享把内容交给轻聊。
// 原理：Info.plist 声明 CFBundleDocumentTypes（能打开的文件类型/UTI）后，
// 侧载 App 也能出现在系统分享/打开方式列表（LiveContainer 接 IPA 即此原理）。
// 数据流：DockTabView.onOpenURL 捕获分享的 URL → 解析成 SharedPayload →
//        入 ShareRouter 单例 + 广播 .qingliaoShareIncoming → ChatView 消费 →
//        复用 sendCore 作为一条消息发送给 AI。
//
// v3.4.24 定位分享：地图 App（高德/百度/腾讯/苹果地图/Google Maps）分享的
// geo: / http(s) 链接在这里解析出经纬度 → SharedPayload.location，
// ChatView 端拼成带"周边推荐"指令的定位消息发给 AI。

/// 一条待处理的系统分享内容
struct SharedPayload {
    /// 文本内容（文本文件 / 链接 / 文件名提示）
    var text: String?
    /// 图片（在 ChatView 里压缩成 base64 后送 sendCore）
    var image: UIImage?
    /// 来源文件名（供提示）
    var sourceName: String?
    /// v3.4.24：定位分享（地图 App 分享链接解析出的坐标）
    var location: CLLocation?

    init(text: String? = nil, image: UIImage? = nil, sourceName: String? = nil,
         location: CLLocation? = nil) {
        self.text = text; self.image = image; self.sourceName = sourceName
        self.location = location
    }
}

/// v3.4.24：地图分享链接经纬度解析（纯函数，无 IO）
enum MapLocationParser {
    /// 已知地图链接里常见的经纬度参数名（按出现顺序取第一对齐全的）
    private static let latKeys = ["lat", "latitude", "y"]
    private static let lonKeys = ["lon", "lng", "long", "longitude", "x"]

    /// 解析地图分享链接 → (坐标, 地点名?)。不认识的链接返回 nil。
    static func parse(_ url: URL) -> (coord: CLLocationCoordinate2D, place: String?)? {
        let abs = url.absoluteString
        // ① 标准 geo: URI（iOS 地图 / 部分安卓向分享）："geo:39.9042,116.4074" 或带 "?q=...&z="
        if url.scheme?.lowercased() == "geo" {
            let body = abs.dropFirst(4)   // 去掉 "geo:"
            let coords = body.split(separator: "?").first.map(String.init) ?? String(body)
            let parts = coords.split(separator: ",")
            if parts.count >= 2,
               let lat = Double(parts[0]), let lon = Double(parts[1]) {
                let q = queryItems(of: url).first { $0.0 == "q" }?.1
                let place = q.map { decodePercent($0) }
                return (CLLocationCoordinate2D(latitude: lat, longitude: lon), place)
            }
            return nil
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        let host = url.host?.lowercased() ?? ""

        // ② 各家地图 App 分享链接（amap:// 不经 http，被上游过滤；这里收 http 形态）
        let mapHosts = ["amap.com", "gaode.com", "map.baidu.com", "api.map.baidu.com",
                        "pan.baidu.com", "maps.apple.com", "maps.google.com", "goo.gl",
                        "map.qq.com", "url.cn", "surl.li", "dwz.cn", "v.dit.cn", "j.map.baidu.com"]
        let isMapHost = mapHosts.contains { host == $0 || host.hasSuffix("." + $0) }

        // ③ 先试 query / path 里的参数
        if let c = coordsFromQueryOrPath(url) {
            let place = placeGuess(of: url)
            return (c, place)
        }
        // ④ 短链/不认识但来自地图域名：交给 AI 端（消息里带原链）
        if isMapHost {
            return (CLLocationCoordinate2D(latitude: .nan, longitude: .nan), nil)
        }
        return nil
    }

    /// 从 query 或 path 段里挖经纬度（高德 path 形态 /regeo?x=..&y=..；百度 query 形态 ?lat=..&lng=..）
    private static func coordsFromQueryOrPath(_ url: URL) -> CLLocationCoordinate2D? {
        let items = queryItems(of: url)
        var dict: [String: String] = [:]
        for (k, v) in items { dict[k.lowercased()] = v }
        // query 之外再看 path 段（有的分享把数字对放 path 里）
        var lat: Double? = nil, lon: Double? = nil
        for lk in latKeys { if let s = dict[lk], let d = Double(s) { lat = d; break } }
        for lk in lonKeys { if let s = dict[lk], let d = Double(s) { lon = d; break } }
        // path 兜底：/from/to 或 /lat,lon 形态的最后两段数字
        if lat == nil || lon == nil {
            let segs = url.path.split(separator: "/").compactMap { Double($0) }
            if segs.count >= 2 {
                let a = segs[segs.count - 2], b = segs[segs.count - 1]
                // 高德系 path 顺序常为 lng,lat；百度为 lat,lng——按量级猜：|v|>90 视为经度
                if abs(a) > 90 { lon = a; lat = b } else { lat = a; lon = b }
            }
        }
        guard let la = lat, let lo = lon else { return nil }
        // 经纬度合理性：纬度 ∈ [-90,90]，经度 ∈ [-180,180]，且不全为 0
        guard abs(la) <= 90, abs(lo) <= 180, !(la == 0 && lo == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: la, longitude: lo)
    }

    private static func queryItems(of url: URL) -> [(String, String)] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let q = comps.queryItems else { return [] }
        return q.compactMap { i in
            guard let name = i.name.isEmpty ? nil : i.name else { return nil }
            return (name, i.value ?? "")
        }
    }

    /// 从 query/path 里猜地点名（面包屑 / marker 名 / title）
    private static func placeGuess(of url: URL) -> String? {
        for k in ["q", "name", "title", "marker", "addr", "address", "keyword", "poiname"] {
            for (key, v) in queryItems(of: url) where key.lowercased() == k {
                let d = decodePercent(v)
                if !d.isEmpty { return d }
            }
        }
        return nil
    }

    private static func decodePercent(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }
}

extension CLLocationCoordinate2D {
    /// v3.4.24：地图短链未带坐标时 isFinite 为 false——调用方按需降级为"看链接"消息
    var isValid: Bool {
        !(latitude.isNaN || longitude.isNaN || latitude.isInfinite || longitude.isInfinite)
    }
}

/// 全局分享收件匣：DockTabView 写入，ChatView 消费（@MainActor 单例）
@MainActor
@Observable
final class ShareRouter {
    static let shared = ShareRouter()
    private(set) var pending: [SharedPayload] = []

    func enqueue(_ p: SharedPayload) {
        pending.append(p)
    }

    /// 弹出队首待处理分享；无则返回 nil
    func dequeue() -> SharedPayload? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    func hasPending() -> Bool { !pending.isEmpty }
}
