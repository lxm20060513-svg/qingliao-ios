import Foundation
import UIKit
import Vision

// MARK: - v3.9.71 端侧 OCR（拍照即执行的第一层）
//
// 用 Vision 的 VNRecognizeTextRequest 在**本机**把图里的字取出来，再交给 IntentPipeline 判类型。
// 为什么不用云端 OCR：拍照即执行要"点完就有结果"，走网络必然是 1~3 秒的空窗；
// 而且照片常含单号/金额/地址这类隐私内容，能不出设备就不出（端侧识别不出来才降级上云）。
//
// 坑（真机实踩 + v3.9.71 审查打回）：
//   · perform() 是同步阻塞的，**绝不能放主线程**——大图会卡住界面（与语音那次同源）。
//     本文件因此刻意**只提供同步 API**，由调用方（IntentExtractor.scanImage）统一放到后台执行器上跑。
//   · 原来这里自己 `DispatchQueue.global().async { handler.perform(...) }`：那个闭包是 @Sendable，
//     而 VNImageRequestHandler / VNRecognizeTextRequest 都不是 Sendable → Swift 6 下捕获即报错
//     （本机 `swiftc -parse` 查不出，只有 CI Archive 会挂）。perform 本来就是同步的、回调也是同步触发，
//     包一层 async 除了多一个"双 resume 会 crash"的风险外没有任何收益，所以直接删掉。
//   · 方向必须显式映射：不传 orientation 时横拍/倒拍的照片会识别失败。

enum IntentOCRExtractor {

    /// 同步取字。取不到（模糊/纯风景/失败）返回 nil，调用方静默降级。
    /// - Important: 调用方负责放到后台（本函数会阻塞当前线程，主线程调用 = 卡界面）
    static func recognizeText(in image: UIImage) -> String? {
        guard let cg = image.cgImage else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // 中文场景优先；中英混排（快递单号、型号）都能认
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cg,
                                           orientation: cgOrientation(image.imageOrientation),
                                           options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil   // 识别失败：别抛给用户，静默降级到云端兜底
        }

        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// UIImage.Orientation → CGImagePropertyOrientation（不映射 = 横拍照片识别不出）
    private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
