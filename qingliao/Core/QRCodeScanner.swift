import Vision
import UIKit

// MARK: - v4.0.86 图内二维码识别（单一真源）
//
// 由头（用户 2026-10-09）：AI 发来的图片里带二维码（收款码 / 群码 / 网页链接码）时，
// 看图器里只能看，识别不了 —— 用户在微信里养成的「长按识别」动作用不了。
//
// 交互形态（用户拍板 = 微信式）：
//   长按图片 → 检测到二维码 → 底部弹「识别图中二维码」提示条 → 点「识别」
//   → url Scheme 能跳对应 App 就跳（weixin://、alipay://、alipays:// 等），
//     跳不动（未安装对应 App / 纯文本码）落 Safari 打开。
//
// 技术选型：Vision `VNDetectBarcodesRequest`（系统框架、无需相机权限 —— 只分析内存里的
// UIImage，与相机扫码走 AVCapture 完全不同路径）。
//
// ⚠️ 并发口径（逐字沿用 IntentOCRExtractor 头注的实踩结论）：
//   perform() 是同步阻塞的，**绝不能放主线程**；但本文件刻意**只提供同步 API**，
//   由调用方（ChatImageViewer.scanQR）放进后台 Task 跑。
//   不在这里包 DispatchQueue/Task.detached：VNImageRequestHandler 非 Sendable，
//   Swift 6 下闭包捕获即报错（本机 -parse 查不出，只有 CI Archive 会挂）。
//   方向必须显式映射：不传 orientation 时横拍/倒拍的截图会识别失败。

enum QRCodeScanner {

    /// 识别结果。`payloadString` 为 nil = 检出码但内容不是文本（极少数二进制码）。
    struct Result: Equatable {
        var payloadString: String?
        /// 码的类型（qr / ean13 …）。目前 UI 只对二维码弹识别条，一维码不出入口。
        var isQR: Bool
    }

    /// 同步识别一张图里的条码。没找到 / 图解不出 → nil。
    /// - Important: 调用方负责放到后台（本函数会阻塞当前线程，主线程调用 = 卡界面）
    static func detect(in image: UIImage) -> Result? {
        guard let cg = image.cgImage else { return nil }

        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cg,
                                           orientation: cgOrientation(image.imageOrientation),
                                           options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let results = request.results, !results.isEmpty else { return nil }
        // v4.0.86（审查 P1-3）：同图混有一维码+二维码时 Vision 结果顺序不保证，
        // 先挑 QR，挑不到再兜底 first（一维码 → isQR=false → 调用方提示「未识别到二维码」）
        let obs = results.first(where: { $0.symbology == .qr }) ?? results[0]
        // symbology：QR = .qr；一维码（ean/code128 等）不出「识别」入口
        let isQR = obs.symbology == .qr
        return Result(payloadString: obs.payloadStringValue, isQR: isQR)
    }

    /// UIImage.Orientation → CGImagePropertyOrientation（不映射 = 横拍照片识别不出，同 OCR 先例）
    private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    /// 打开码内容：
    ///   · URL（http/https 或自定义 scheme）→ `UIApplication.open`。
    ///     ⚠️ 自定义 scheme（weixin:// → 微信、alipays:// → 支付宝…）能走通的前提是
    ///     **scheme 已配进 project.yml 的 `LSApplicationQueriesSchemes` 白名单**——
    ///     iOS 9 起 `canOpenURL` 只对白名单内 scheme 返回真值，缺了恒 false（审查实抓的 P0）。
    ///     https 等网页链接不走 canOpenURL，直接 open 落 Safari。
    ///     completionHandler 给「已打开」回执。
    ///   · 纯文本码（WiFi 配置 / 名片 / 裸字符串）→ 返回文本，由调用方弹复制面板。
    /// 返回值：.openedURL = 已交给系统跳转；.text = 纯文本内容。
    ///
    /// ⚠️ @MainActor：UIApplication.shared 只在主线程合法（Swift 6 隔离，-parse 查不出、CI 必挂）。
    /// 本函数是 async 且很快返回（只等系统回调），主线程 await 不卡界面。
    enum OpenOutcome {
        case openedURL
        case text(String)
    }

    @MainActor
    static func open(_ payload: String) async -> OpenOutcome {
        guard let url = URL(string: payload), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
                || UIApplication.shared.canOpenURL(url)   // 自定义 scheme：装了对应 App 才 true
        else {
            return .text(payload)
        }
        let opened = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            UIApplication.shared.open(url, options: [:]) { ok in
                cont.resume(returning: ok)
            }
        }
        // open 失败（极少数：scheme 声明了但对方拒接）→ 也按文本处理，别静默
        return opened ? .openedURL : .text(payload)
    }
}
