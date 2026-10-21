import SwiftUI

/// 产物库图片缩略图（v4.0.143）
///
/// 用户 2026-10-21：「顺便给产物库加图片缩略图（现在只有文件名）」。
///
/// 为什么不用系统那套纯 URL 图片加载：产物库下载口要 `X-Auth-Token`，它塞不进自定义 header。
/// 统一走 `auth.downloadFile`（WiFi 直连 / 蜂窝 relay 自适应、自动带 token、自签证书兜底）——
/// 和 FilesManagerKit 的预览、聊天气泡下载同一条通路，不再另开一套。
///
/// 三条口径（真值表钉死）：
/// 1. **只给图片**：调用方用 `RemoteFiles.imageExts` 判定，非图片仍走图标 `badge`；
/// 2. **下采样**：按显示尺寸 3x 解码，几十 MB 的原图不进内存（列表滚动会被系统杀）；
/// 3. **进程内缓存**：滚动/进出目录不重复下载（NSCache 自动回收）。
struct ArtifactThumbnail: View {
    /// 产物相对路径（形如 `artifacts/2026-10-21/xxx.png`）——与文件下载接口同口径
    let path: String
    /// 显示边长（pt）。默认 40：与行内两行文字（subhead + tiny）等高，不再把行撑高
    var size: CGFloat = 40

    @Environment(AuthStore.self) private var auth
    @State private var image: UIImage?
    @State private var failed = false

    @MainActor private static let cache = NSCache<NSString, UIImage>()

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
        do {
            let (data, code) = try await auth.downloadFile(path)
            guard (200..<300).contains(code), let full = UIImage(data: data) else {
                failed = true
                return
            }
            let thumb = downscale(full, to: size * 3)   // @3x：给足屏幕像素，不放大原图
            Self.cache.setObject(thumb, forKey: path as NSString)
            image = thumb
        } catch {
            failed = true
        }
    }

    /// 下采样到最长边 px（`UIGraphicsImageRenderer` 走 CoreGraphics，不额外持原图）
    private func downscale(_ img: UIImage, to px: CGFloat) -> UIImage {
        let longest = max(img.size.width, img.size.height)
        guard longest > px, longest > 0 else { return img }
        let scale = px / longest
        let newSize = CGSize(width: max(1, img.size.width * scale), height: max(1, img.size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
