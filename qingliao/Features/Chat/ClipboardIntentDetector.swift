import Foundation
import UIKit

// MARK: - v3.9.71 剪贴板「有可处理内容」探测（自动检测入口的第一道闸）
//
// 为什么单独一个探测器、而且只认链接：
//   · iOS 主动读剪贴板会弹系统「允许粘贴」——只能先用 **detection API**（不读内容、不弹窗）
//     问一句"这里面像是有链接吗"，认出后才在**用户点按**时读内容走意图管道。
//   · 只认 `.probableWebURL`（与 MapClipboardDetector 同一套已验证调用）：它是**宽松分类**，
//     官方明确不是语义保证——所以这里只当"值得问用户一句"的信号，真正的类型判定仍交给 IntentPipeline。
//     刻意**不**用数字类 pattern 自动弹条：一串数字（验证码/工号/金额）误报率太高，主动打扰不划算。
//
// ⚠️ CI 实证（run 34613376991）：Xcode 26 SDK 里 `DetectedValues.probableWebURL` 是**非可选 String**，
//    不能写 `guard let`（会报 "initializer for conditional binding must have Optional type"）。

enum ClipboardIntentDetector {

    /// 剪贴板里像是有链接吗。
    /// - Returns: `true` 有 / `false` 明确没有 / **`nil` 探测失败**（调用方保持"未处理"，下次再探）
    static func hasWebLink() async -> Bool? {
        let pasteboard = UIPasteboard.general
        // 类型门控：连字符串/URL 都没有就不必调 detection（主线程同步、零并发风险）
        guard pasteboard.hasStrings || pasteboard.hasURLs else { return false }
        do {
            let values = try await pasteboard.detectedValues(for: [\.probableWebURL])
            return !values.probableWebURL.isEmpty
        } catch {
            return nil
        }
    }
}
