import UIKit
import ImageIO

// MARK: - v2.0.87c 图片解码缓存（历史消息图片重复解码 → NSCache，滑动/重看不卡）

// v2.0.87f：NSCache 非 Sendable → @MainActor 隔离（视图均在主线程调用，安全且满足 Swift 6 并发检查）
@MainActor
private let imageCache = NSCache<NSString, UIImage>()

// v3.4.x code review fix（低）：注释与实现对齐——本文件有两个入口：
//  dataURLImage（同步）：小图（<100KB）主线程直解；大图也同步解码保证首帧立即可见（单帧卡顿代价）
//  asyncDataURLImage（异步）：大图 base64 在后台队列解码、主线程回调（滚动场景请走此入口）
// 后台解码队列只服务 asyncDataURLImage，不存在"所有图片都后台解码"。
// v3.4.25：两个入口均支持按显示尺寸下采样解码（ImageIO 缩略图），详见下方 imageDecodeTier 注释。
private let _imageDecodeQueue = DispatchQueue(label: "qingliao.image.decode", qos: .userInitiated)

/// 初始化缓存限制（App 启动时调用一次；避免首次使用前 0 限制 → 无上限缓存）
@MainActor
func initImageCacheLimit() {
    imageCache.totalCostLimit = 40 * 1024 * 1024  // 40MB
}

// MARK: - v3.4.25 按显示尺寸下采样解码（ImageIO）+ 尺寸档位缓存 key

/// v3.4.25：解码档位——解码像素上限只取 512/1024 两档。
/// 同一张大图在不同宽度气泡/查看器里显示时共享同一档缓存，避免同图多尺寸重复解码。
private let imageDecodeTiers: [Int] = [512, 1024]

/// v3.4.25：气泡显示宽度(pt) → 解码档位（按 3x 屏幕上限放大后取能容纳目标的最小档位）。
/// scale 取 3 上限而非 UIScreen.main——档位本身粗粒度，2x 屏多解一点可接受，且规避 mainScreen 弃用风险。
/// 纯函数（非隔离），后台解码线程也可安全调用。
func imageDecodeTier(displayWidthPT: CGFloat, scale: CGFloat = 3) -> Int {
    let target = Int((displayWidthPT * scale).rounded(.up))
    for tier in imageDecodeTiers where target <= tier {
        return tier
    }
    return imageDecodeTiers.last!
}

/// v3.4.25：大图的档位化缓存 key（原始 key + 档位后缀）；小图(<100KB)仍用原始 key，路径保持不变
private func tieredCacheKey(_ urlStr: String, tier: Int) -> NSString {
    (urlStr + "|v3425px" + String(tier)) as NSString
}

/// v3.4.25：ImageIO 下采样解码——CGImageSourceCreateThumbnailAtIndex 直接解出 ≤maxPixelSize 的位图，
/// 解码内存峰值 ≈ 目标尺寸，而 UIImage(data:) 全量解码峰值 ≈ 原图全像素（一张 4000px 图 ≈ 60MB）。
/// 纯函数（非隔离），后台解码线程调用安全。
private func downsampledImage(_ imgData: Data, maxPixelSize: Int) -> UIImage? {
    guard let src = CGImageSourceCreateWithData(imgData as CFData, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
}

/// v3.4.25：下采样后位图的实际内存估算（bytesPerRow*height），比压缩数据大小更贴近真实占用；
/// 拿不到 cgImage 时回退压缩数据大小
private func decodedImageCost(_ img: UIImage, fallback: Int) -> Int {
    if let cg = img.cgImage {
        return cg.bytesPerRow * cg.height
    }
    return fallback
}

/// 解码 dataURL 图片（base64），带 NSCache 缓存（主线程调用）
/// v3.0.x fix：大图片解码移到后台队列（NSCache 读写仍在主线程）
/// v3.4.25：可选 displayWidthPT——传入气泡显示宽度且数据 ≥100KB 时，按 512/1024 档位下采样解码
/// （ImageIO 缩略图）并以档位 key 缓存；小图(<100KB)与未传宽度的调用（导出/分享/大图查看等需全分辨率）
/// 路径保持不变：全尺寸解码 + 原始 key。
@MainActor
func dataURLImage(_ urlStr: String, displayWidthPT: CGFloat? = nil) -> UIImage? {
    guard !urlStr.isEmpty else { return nil }
    // v2.0.102：动态匹配 data URL 前缀（png/heic 等非 jpeg 也被正确截断；纯 base64 原样解码）
    var b64 = urlStr
    if let comma = urlStr.firstIndex(of: ","),
       urlStr[..<comma].hasPrefix("data:image/") {
        b64 = String(urlStr[urlStr.index(after: comma)...])
    }
    guard let imgData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
    // v3.4.25：小图(<100KB)与未指定显示宽度的调用 → 走原路径（全尺寸解码、原始 key，与旧缓存条目共享）
    let width = displayWidthPT
    let useTier: Bool
    let tier: Int
    if let w = width, imgData.count >= 100 * 1024 {
        tier = imageDecodeTier(displayWidthPT: w)
        useTier = true
    } else {
        tier = 0
        useTier = false
    }
    let key: NSString = useTier ? tieredCacheKey(urlStr, tier: tier) : (urlStr as NSString)
    // 缓存命中直接返回（零开销）
    if let img = imageCache.object(forKey: key) {
        return img
    }
    let decoded: UIImage?
    if useTier {
        decoded = downsampledImage(imgData, maxPixelSize: tier)
    } else {
        // v3.4.x code review fix（低）：本入口为同步解码——小图主线程直解（dispatch 开销 > 解码开销）；
        // ≥100KB 大图也在此同步解码以保证首帧立即显示，代价是单帧主线程卡顿；滚动场景大图应走
        // asyncDataURLImage。totalCostLimit 已由 initImageCacheLimit(App 启动时)初始化，移除判 0 冗余设置。
        decoded = UIImage(data: imgData)
    }
    guard let img = decoded else { return nil }
    imageCache.setObject(img, forKey: key, cost: decodedImageCost(img, fallback: imgData.count))
    return img
}

/// v3.0.x fix：异步版——大图片 base64 解码在后台线程完成，不阻塞 UI
/// v3.4.25：可选 displayWidthPT——传入时 ≥100KB 的大图在后台按下采样（ImageIO 缩略图，512/1024 档）
/// 解码，解码内存峰值 ≈ 档位尺寸；档位化 key 缓存。未传时行为与旧版一致（全尺寸后台解码）。
/// 调用方在 view.task 中调用，decoded 回调在主线程执行
@MainActor
func asyncDataURLImage(_ urlStr: String, displayWidthPT: CGFloat? = nil,
                       decoded: @escaping @MainActor (UIImage) -> Void) {
    guard !urlStr.isEmpty else { return }
    var b64 = urlStr
    if let comma = urlStr.firstIndex(of: ","),
       urlStr[..<comma].hasPrefix("data:image/") {
        b64 = String(urlStr[urlStr.index(after: comma)...])
    }
    guard let imgData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return }
    let width = displayWidthPT
    let useTier: Bool
    let tier: Int
    if let w = width, imgData.count >= 100 * 1024 {
        tier = imageDecodeTier(displayWidthPT: w)
        useTier = true
    } else {
        tier = 0
        useTier = false
    }
    let key: NSString = useTier ? tieredCacheKey(urlStr, tier: tier) : (urlStr as NSString)
    if let img = imageCache.object(forKey: key) {
        decoded(img)
        return
    }
    // v3.4.25 CI fix：key 跨并发域传给后台闭包 → 先拷贝为本地 Sendable 值（Swift 6 sending 检查）
    let capturedKey = key
    _imageDecodeQueue.async {
        // v3.4.25：后台下采样解码（ImageIO），峰值内存 ≈ 档位尺寸而非原图全像素
        let img = useTier ? downsampledImage(imgData, maxPixelSize: tier) : UIImage(data: imgData)
        guard let img = img else { return }
        let cost = decodedImageCost(img, fallback: imgData.count)
        DispatchQueue.main.async {
            // imageCache.totalCostLimit 已由 initImageCacheLimit 初始化（v3.4.x code review fix）
            imageCache.setObject(img, forKey: capturedKey, cost: cost)
            decoded(img)
        }
    }
}

// v3.4.x 存储自洁：远程图磁盘缓存——重启复用省流量，带大小上限 LRU 清理（防磁盘无限膨胀）。
// 远程 AI 图/图床图下载后写 Caches/RemoteImages/<key>.jpg，内存 NSCache 命中前先查磁盘。
private enum RemoteDiskCache {
    static let dirName = "RemoteImages"
    static let maxBytes = 150 * 1024 * 1024   // 150MB 上限，超出按最后访问时间清理
    static var dirURL: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent(dirName, isDirectory: true)
    }
    static func fileURL(_ key: NSString) -> URL? {
        guard let dir = dirURL else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // key 可能含路径分隔符/`?`→ 哈希成安全文件名
        let safe = String(format: "%x", key.hash)
        return dir.appendingPathComponent(safe + ".jpg")
    }

    /// 写磁盘（写成功后若超限，清理最久未访问的缓存）
    static func write(_ key: NSString, _ data: Data) {
        guard let url = fileURL(key) else { return }
        try? data.write(to: url, options: .atomic)
        _ = touch(url)
        enforceLimit()
    }

    /// 读磁盘（命中则 touch 更新访问时间）
    static func read(_ key: NSString) -> Data? {
        guard let url = fileURL(key) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        _ = touch(url)
        return try? Data(contentsOf: url)
    }

    /// 更新访问时间（LSUtility 无，用 FileManager contentModificationDate——touch 后记内存表）
    /// v3.4.x fix：Swift 6 严格并发——静态可变属性须标注 nonisolated(unsafe)，否则报非并发安全
    nonisolated(unsafe) private static var touchTimes: [String: Date] = [:]
    @discardableResult
    private static func touch(_ url: URL) -> Bool {
        touchTimes[url.lastPathComponent] = Date()
        return true
    }

    /// 读文件大小（把 try? ... ?? 0 抽成简单函数，规避 Swift 诊断 bug）
    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    /// 读最后访问时间（touchTimes 优先，无记录回退 contentModificationDate）
    private static func lastAccess(_ url: URL) -> Date {
        touchTimes[url.lastPathComponent] ??
            ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
    }

    /// LRU 清理：磁盘总大小超上限 → 按访问时间从旧到新删除，直到低于上限的 80%
    static func enforceLimit() {
        guard let dir = dirURL else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let total = files.reduce(0) { $0 + fileSize($1) }
        guard total > maxBytes else { return }
        let sorted = files.sorted { lastAccess($0) < lastAccess($1) }
        var toDelete = total
        for f in sorted {
            let sz = fileSize(f)
            try? FileManager.default.removeItem(at: f)
            touchTimes.removeValue(forKey: f.lastPathComponent)
            toDelete -= sz
            if toDelete <= Int(Double(maxBytes) * 0.8) { break }
        }
    }
}

// MARK: - 远程图缓存（内存 + 磁盘双层）

/// v2.0.128：已下载的远程图片缓存（AI 发图 / 大图查看器共用，滚动复用不重复下载）
@MainActor
private let remoteImageCache = NSCache<NSString, UIImage>()

@MainActor
func cachedRemoteImage(_ urlStr: String) -> UIImage? {
    let key = remoteCacheKey(urlStr)
    if let img = remoteImageCache.object(forKey: key) {
        return img
    }
    // v3.4.x：内存未命中 → 查磁盘，命中则解码回写内存（重启复用省流量）
    if let data = RemoteDiskCache.read(key), let img = UIImage(data: data) {
        remoteImageCache.setObject(img, forKey: key, cost: data.count)
        return img
    }
    return nil
}

@MainActor
func setRemoteImageCache(_ urlStr: String, _ img: UIImage, cost: Int) {
    let key = remoteCacheKey(urlStr)
    if remoteImageCache.totalCostLimit == 0 {
        remoteImageCache.totalCostLimit = 40 * 1024 * 1024   // 40MB
    }
    remoteImageCache.setObject(img, forKey: key, cost: cost)
    // v3.4.x：顺手写磁盘（远程图持久化，重启可复用）
    if let data = img.jpegData(compressionQuality: 0.9) {
        RemoteDiskCache.write(key, data)
    }
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
