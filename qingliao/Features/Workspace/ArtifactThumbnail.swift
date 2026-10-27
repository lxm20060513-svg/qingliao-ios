import SwiftUI
import ImageIO

/// 产物库图片缩略图（v4.0.143）
///
/// 用户 2026-10-21：「顺便给产物库加图片缩略图（现在只有文件名）」。
///
/// 为什么不用系统那套纯 URL 图片加载：产物库下载口要 `X-Auth-Token`，它塞不进自定义 header。
/// 统一走 `auth.downloadFile(allowRelay: false)`（WiFi 直连 / 蜂窝 CFStream 直连、自动带 token、自签证书兜底）——
/// 和 FilesManagerKit / 云盘浏览器的「用户主动点开」下载同一条底层通路，但**网络策略不同**：
/// 那两处缺省 `allowRelay: true`（点了就值得弹一次窗），本组件是自动路径，必须关掉。
/// 🚨 **必须 allowRelay: false**（v4.0.162）：缩略图是「页面一出现就自己跑」的自动路径，
/// 蜂窝下直连不通时若降级 relay = 每张图弹一次系统授权窗（用户实报「每次切到工作台都弹登录框」）。
/// 自动路径失败就显示占位图，等连 WiFi / 重进页面再取。
///
/// 三条口径（真值表钉死）：
/// 1. **只给图片**：调用方用 `RemoteFiles.imageExts` 判定，非图片仍走图标 `badge`；
/// 2. **下采样**：用 ImageIO 直接解出「显示尺寸 3x」的缩略图（`CGImageSourceCreateThumbnailAtIndex`），
///    原图**不解码**——v4.0.149 修：此前写的是 `UIImage(data:)` 全量解码再缩，注释说「不进内存」与事实相反，
///    产物库里几十 MB 的图一多就会把 App 撑爆；
/// 3. **进程内缓存**：滚动/进出目录不重复下载（NSCache 自动回收）。
/// 4. **失败负缓存**（v4.0.165）：同一路径在 TTL（60s）内不再重试。蜂窝下直连不通时，
///    每次进工作台/翻目录都会对这一批图重跑超时，滚动发涩还费电（4.0.162 审查遗留）；
///    TTL 到期自动重试，所以连上 WiFi / 过一会儿回来仍会补图，不是永久放弃。
struct ArtifactThumbnail: View {
    /// 产物相对路径（形如 `artifacts/2026-10-21/xxx.png`）——与文件下载接口同口径
    let path: String
    /// 显示边长（pt）。默认 40：与行内两行文字（subhead + tiny）等高，不再把行撑高
    var size: CGFloat = 40

    @Environment(AuthStore.self) private var auth
    @State private var image: UIImage?
    @State private var failed = false

    @MainActor private static let cache = NSCache<NSString, UIImage>()
    /// 失败负缓存：path → 失败时刻（unix 秒）。NSCache 自动回收，不占长期内存
    @MainActor private static let failureCache = NSCache<NSString, NSNumber>()
    /// 失败后多久允许重试（秒）。太短等于没缓存，太长会让「连上 WiFi 回来」迟迟不补图
    @MainActor private static let failureTTL: TimeInterval = 60

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                        .fill(Color.secondary.opacity(Tint.faint))
                    Image(systemName: "photo")
                        .font(.system(size: size * 0.38, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                .strokeBorder(Color.primary.opacity(Tint.subtle), lineWidth: 0.5)
        )
        .task(id: path) { await load() }
        .accessibilityLabel("图片缩略图")
    }

    private func load() async {
        if let hit = Self.cache.object(forKey: path as NSString) {
            image = hit
            return
        }
        guard !path.isEmpty else { failed = true; return }
        // 负缓存命中：TTL 内不再发起下载（失败态已由占位图表达）
        if Self.recentlyFailed(path) {
            failed = true
            return
        }
        do {
            let (data, code) = try await auth.downloadFile(path, allowRelay: false)
            guard (200..<300).contains(code), let thumb = Self.downsample(data, to: size * 3) else {
                Self.markFailed(path)
                failed = true
                return
            }
            Self.cache.setObject(thumb, forKey: path as NSString)
            Self.failureCache.removeObject(forKey: path as NSString)
            image = thumb
        } catch {
            Self.markFailed(path)
            failed = true
        }
    }

    /// TTL 内是否刚失败过（失败可能是网络瞬断，到期必须允许重试）
    @MainActor private static func recentlyFailed(_ path: String) -> Bool {
        guard let ts = failureCache.object(forKey: path as NSString)?.doubleValue else { return false }
        return Date().timeIntervalSince1970 - ts < failureTTL
    }

    @MainActor private static func markFailed(_ path: String) {
        failureCache.setObject(NSNumber(value: Date().timeIntervalSince1970), forKey: path as NSString)
    }

    /// 从**原始字节**直接解出缩略图（最长边 px）。走 ImageIO 增量解码：不产生全尺寸位图，
    /// 峰值内存 ≈ 缩略图本身，而不是原图（4000px 原图 ≈ 60MB）。与 `ImageCache` 的缩略图口径一致。
    private static func downsample(_ data: Data, to px: CGFloat) -> UIImage? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOptions) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 尊重 EXIF 方向
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, px),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
