import UIKit

// MARK: - v2.0.87c 图片解码缓存（历史消息图片重复解码 → NSCache，滑动/重看不卡）

// v2.0.87f：NSCache 非 Sendable → @MainActor 隔离（视图均在主线程调用，安全且满足 Swift 6 并发检查）
@MainActor
private let imageCache = NSCache<NSString, UIImage>()

// v3.4.x code review fix（低）：注释与实现对齐——本文件有两个入口：
//  dataURLImage（同步）：小图（<100KB）主线程直解；大图也同步解码保证首帧立即可见（单帧卡顿代价）
//  asyncDataURLImage（异步）：大图 base64 在后台队列解码、主线程回调（滚动场景请走此入口）
// 后台解码队列只服务 asyncDataURLImage，不存在"所有图片都后台解码"。
private let _imageDecodeQueue = DispatchQueue(label: "qingliao.image.decode", qos: .userInitiated)

/// 初始化缓存限制（App 启动时调用一次；避免首次使用前 0 限制 → 无上限缓存）
@MainActor
func initImageCacheLimit() {
    imageCache.totalCostLimit = 40 * 1024 * 1024  // 40MB
}

/// 解码 dataURL 图片（base64），带 NSCache 缓存（主线程调用）
/// v3.0.x fix：大图片解码移到后台队列（NSCache 读写仍在主线程）
@MainActor
func dataURLImage(_ urlStr: String) -> UIImage? {
    guard !urlStr.isEmpty else { return nil }
    // 缓存命中直接返回（零开销）
    if let img = imageCache.object(forKey: urlStr as NSString) {
        return img
    }
    // v2.0.102：动态匹配 data URL 前缀（png/heic 等非 jpeg 也被正确截断；纯 base64 原样解码）
    var b64 = urlStr
    if let comma = urlStr.firstIndex(of: ","),
       urlStr[..<comma].hasPrefix("data:image/") {
        b64 = String(urlStr[urlStr.index(after: comma)...])
    }
    guard let imgData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
    // v3.4.x code review fix（低）：本入口为同步解码——小图主线程直解（dispatch 开销 > 解码开销）；
    // ≥100KB 大图也在此同步解码以保证首帧立即显示，代价是单帧主线程卡顿；滚动场景大图应走
    // asyncDataURLImage。totalCostLimit 已由 initImageCacheLimit(App 启动时)初始化，移除判 0 冗余设置。
    guard let img = UIImage(data: imgData) else { return nil }
    imageCache.setObject(img, forKey: urlStr as NSString, cost: imgData.count)
    return img
}

/// v3.0.x fix：异步版——大图片 base64 解码在后台线程完成，不阻塞 UI
/// 调用方在 view.task 中调用，decoded 回调在主线程执行
@MainActor
func asyncDataURLImage(_ urlStr: String, decoded: @escaping @MainActor (UIImage) -> Void) {
    guard !urlStr.isEmpty else { return }
    if let img = imageCache.object(forKey: urlStr as NSString) {
        decoded(img)
        return
    }
    var b64 = urlStr
    if let comma = urlStr.firstIndex(of: ","),
       urlStr[..<comma].hasPrefix("data:image/") {
        b64 = String(urlStr[urlStr.index(after: comma)...])
    }
    guard let imgData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return }
    _imageDecodeQueue.async {
        guard let img = UIImage(data: imgData) else { return }
        DispatchQueue.main.async {
            // imageCache.totalCostLimit 已由 initImageCacheLimit 初始化（v3.4.x code review fix）
            imageCache.setObject(img, forKey: urlStr as NSString, cost: imgData.count)
            decoded(img)
        }
    }
}

/// v2.0.128：已下载的远程图片缓存（AI 发图 / 大图查看器共用，滚动复用不重复下载）
@MainActor
private let remoteImageCache = NSCache<NSString, UIImage>()

@MainActor
func cachedRemoteImage(_ urlStr: String) -> UIImage? {
    remoteImageCache.object(forKey: remoteCacheKey(urlStr))
}

@MainActor
func setRemoteImageCache(_ urlStr: String, _ img: UIImage, cost: Int) {
    if remoteImageCache.totalCostLimit == 0 {
        remoteImageCache.totalCostLimit = 40 * 1024 * 1024   // 40MB
    }
    remoteImageCache.setObject(img, forKey: remoteCacheKey(urlStr), cost: cost)
}

/// v3.4.x code review fix（低）：缓存 key = host + path + 白名单 query（排序）。
/// 原实现只取 URL.path——不同 host（图床/多 NAS）或同 path 不同 query（缩略尺寸 ?w=100 vs ?w=800、
/// 版本参数）的资源会共用条目串图；同时保留去"易变签名参数"（token/时间戳类）共享缓存的原意。
@MainActor
private func remoteCacheKey(_ urlStr: String) -> NSString {
    guard let url = URL(string: urlStr) else { return urlStr as NSString }
    // 易变/不决定内容的参数剔除（签名/时间戳），其余 query 全部保留并排序，保证 key 稳定
    let volatile: Set<String> = ["token", "auth", "sign", "signature", "sig", "expires", "exp",
                                 "ts", "t", "_t", "timestamp", "rand", "random", "v", "updated"]
    var comp = URLComponents(url: url, resolvingAgainstBaseURL: false)
    if var items = comp?.queryItems {
        items = items.filter { !volatile.contains(($0.name.lowercased())) }
        items.sort { ($0.name.lowercased(), $0.value ?? "") < ($1.name.lowercased(), $1.value ?? "") }
        comp?.queryItems = items
    }
    let host = url.host ?? ""
    let path = url.path
    if let q = comp?.query, !q.isEmpty {
        return (host + path + "?" + q) as NSString
    }
    return (host + path) as NSString
}
