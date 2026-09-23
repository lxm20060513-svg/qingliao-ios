import Foundation
import UIKit
import Vision

// MARK: - v3.9.71 端侧 OCR（拍照即执行的第一层）
//
// 用 Vision 的 VNRecognizeTextRequest 在**本机**把图里的字取出来，再交给 IntentPipeline 判类型。
// 为什么不用云端 OCR：拍照即执行要"点完就有结果"，走网络必然是 1~3 秒的空窗；
// 而且照片常含单号/金额/地址这类隐私内容，能不出设备就不出（端侧识别不出来才降级上云）。
//
// 坑（真机实踩）：
//   · perform() 是同步阻塞的，**绝不能放主线程**——大图会在主线程卡住界面（与语音那次同源）。
//   · 返回值只 resume 一次：perform 抛错和 completion 回调都可能触发，用锁保证只 resume 一次，
//     否则 crash（CheckedContinuation resumed twice）。
//   · 方向必须显式映射：不传 orientation 时横拍/倒拍的照片会识别失败或串行。

enum IntentOCRExtractor {

    /// 从图片里取文字。取不到（模糊/纯风景/失败）返回 nil，调用方静默降级。
    static func recognizeText(in image: UIImage) async -> String? {
        guard let cg = image.cgImage else { return nil }
        let orientation = cgOrientation(image.imageOrientation)

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = ResumeOnce(cont)
            let request = VNRecognizeTextRequest { req, _ in
                let text = (req.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                once.resume(text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // 中文场景优先；中英混排（快递单号、型号）都能认
            request.recognitionLanguages = ["zh-Hans", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    once.resume(nil)   // 抛错时 completion 不会被调用，这里兜底
                }
            }
        }
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

    /// 只 resume 一次（双 resume = crash）
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let cont: CheckedContinuation<String?, Never>

        init(_ cont: CheckedContinuation<String?, Never>) { self.cont = cont }

        func resume(_ value: String?) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { cont.resume(returning: value) }
        }
    }
}
