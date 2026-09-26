import Foundation
import UIKit

/// 分享扩展侧的**图片下采样 + JPEG 编码**（扩展到主 App 之间只传字节，不传 `UIImage`）。
///
/// 为什么不复用主 App 的 `ImageDownscale`：那个函数的入参/出参都是 `data:image/...` 字符串
/// （蜂窝降级链的既定口径），而这里要的是**原始 JPEG 字节**（要塞进剪贴板载荷的 JSON）；
/// 口径不同，为一个用途把那份 UIKit 实现搬进扩展 target 也不划算。
/// 档位取 `ShareLinkCodec.imageMaxSide / imageJPEGQuality` —— 与主 App 同一份常量，不写第二处字面量。
enum ShareImageEncoder {

    /// 长边超过档位就等比缩到档位，再编成 JPEG。编不出返回 nil
    /// （调用方走「只有文本」的降级，不做静默兜底图）。
    static func jpeg(_ image: UIImage) -> Data? {
        var w = image.size.width
        var h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let maxSide = ShareLinkCodec.imageMaxSide
        if max(w, h) > maxSide {
            let scale = maxSide / max(w, h)
            w *= scale
            h *= scale
        }
        // 与主 App 同款渲染器（不是 UIGraphicsBeginImageContext —— 那个在 3x 设备上会按 1x 画）
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let resized = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return resized.jpegData(compressionQuality: ShareLinkCodec.imageJPEGQuality)
    }
}
