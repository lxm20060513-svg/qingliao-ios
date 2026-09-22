// MARK: - v3.9.60 图片下采样（蜂窝直连口径，单一实现）
//
// 背景：蜂窝下 `stream/start` 的 body 走 CFStream 直连，失败再降级 relay（把**整个 body** 编码进
// Location 头）——大 base64 图必然载不动 → 后端 `bad json` 400（v3.0.52 / v3.0.53 实踩，
// 压到 480px/0.45 ≈ 20KB 才稳过）。
//
// 过去只有「当前这条消息的图」经过压缩（`ChatView.compressForCellular`，在 sendCore 里对入参做）。
// v3.9.60 起 payload 里的图改走**本地 base64**（见 `ChatStore.sendableImageURL`：自家 URL 只有
// AAAA，上游 IPv4 云下不到），于是「历史里那张图」也会进 body —— 发送链的每一环都得能压。
// 所以抽成这里一份实现：两处各写一份必然漂移（改了一处另一处还是大 body）。
//
// ⚠️ 只在**蜂窝**调用（WiFi 直连不受 body 限制，别白白降画质）。

import UIKit

enum ImageDownscale {
    /// `data:image/...` → 下采样后的 data URL。
    /// 非 data 图串 / base64 解不开 / 不是图片字节 / 编码失败 → 返回 nil（调用方沿用原串，绝不空手而归）。
    static func dataURL(_ s: String?, maxSide: CGFloat, quality: CGFloat) -> String? {
        guard let img = s, let comma = img.firstIndex(of: ","),
              img[..<comma].hasPrefix("data:image/"),
              let bytes = Data(base64Encoded: String(img[img.index(after: comma)...])),
              let ui = UIImage(data: bytes) else { return nil }
        var w = ui.size.width
        var h = ui.size.height
        // 已小于档位就不放大小图（放大只会变糊 + 浪费字节）
        if max(w, h) > maxSide {
            let scale = maxSide / max(w, h)
            w *= scale
            h *= scale
        }
        guard w > 0, h > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let resized = renderer.image { _ in
            ui.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        guard let d = resized.jpegData(compressionQuality: quality) else { return nil }
        return "data:image/jpeg;base64," + d.base64EncodedString()
    }

    /// 蜂窝直连档位（与 v3.0.53 定稿一致：480px / 0.45 ≈ 20KB）——统一从这里取，别各写各的数
    static let cellularMaxSide: CGFloat = 480
    static let cellularQuality: CGFloat = 0.45
}
