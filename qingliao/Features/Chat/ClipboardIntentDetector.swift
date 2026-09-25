import Foundation
import UIKit

// MARK: - v3.9.71 剪贴板「有可处理内容」探测（自动检测入口的第一道闸）
//
// 铁律（别动）：iOS 主动读剪贴板会弹系统「允许粘贴」——所以这里只能用 **detection API**
// （不读内容、不弹窗）问一句"这里面像是有可处理的东西吗"，认出后才在**用户点按**时读内容走意图管道。
//
// 🚨 v3.9.76 口径放开（用户拍板，原话「1」）：不再只认链接 —— 本地意图管道能认出的**结构化类型**都提示：
//   链接 / 地址 / 联系方式 / 金额 / 快递单号 / 日程。范围**受系统 detection 能力限制**（下面 patterns 那一段）
//   ⚠️ 边界（必须诚实，别在汇报里含糊）：**纯文字不提示**。检测 API 没有"这是一段普通文字"的 pattern，
//   要判断只能真读内容，而主动读会弹系统「允许粘贴」——正是本文件开头那条铁律要避免的打扰。
//   ⚠️ 探测结果只当"值得问用户一句"的信号（官方明确 probableWebURL 只是宽松分类、不是语义保证），
//      真正的类型判定仍交给点按后的 IntentPipeline。
//
// 🚨🚨 v3.9.76 实踩（CI 前审查抓到，**本机无 iOS SDK 查不出**）：
//    ① `UIPasteboard.DetectionPattern` 这个 struct **只有三个成员**：`.number` / `.probableWebSearch` / `.probableWebURL`
//       （Apple 文档 detectionpattern 页，2026-09 核对）。它**没有** `.postalAddress` / `.phoneNumber` /
//       `.emailAddress` / `.money` / `.shipmentTrackingNumber` / `.dateTime` —— 按"类目名"顺手写出来必挂编译。
//    ② `detectedValues(for:)` 收的参数是 **`Set<PartialKeyPath<UIPasteboard.DetectedValues>>`**，
//       也就是 **key-path 形式**（`[\.probableWebURL]`，与 `MapClipboardDetector` 同款、有 CI 实证），
//       不是 `Set<DetectionPattern>`。
//    ③ `DetectedValues` 的字段是**复数数组**：`postalAddresses` / `phoneNumbers` / `emailAddresses` /
//       `moneyAmounts` / `shipmentTrackingNumbers` / `calendarEvents` / `links`；只有 `probableWebURL` /
//       `probableWebSearch` 是 String，`number` 是 `Double?`。**没有** `dateTime` 字段。
//    → 因此判命中一律用 `!values.xxx.isEmpty`；`hit(_ s: String?)` 只留给那两个 String 字段（它们在 Xcode 26 SDK 里
//      是**非可选 String**，见 run 34613376991 的 CI 实证，所以兼容两种可选性）。
// ⚠️ 本机没有 iOS SDK，**这个文件无法本地编译验证**（只能装机/CI 见真章）。

enum ClipboardIntentDetector {

    /// 剪贴板里有哪些「本地能识别」的结构化类型。
    /// - Returns: 命中集合；**`nil` = 探测失败**（调用方保持"未处理"，下次进前台再探）
    static func recognizableHits() async -> ClipboardIntentHits? {
        let pasteboard = UIPasteboard.general
        // 类型门控：连字符串/URL 都没有就不必调 detection（主线程同步、零并发风险）
        guard pasteboard.hasStrings || pasteboard.hasURLs else { return ClipboardIntentHits() }
        do {
            let values = try await pasteboard.detectedValues(for: patterns)
            return ClipboardIntentHits(
                link: hit(values.probableWebURL) || hit(values.probableWebSearch) || !values.links.isEmpty,
                address: !values.postalAddresses.isEmpty,
                contact: !values.phoneNumbers.isEmpty || !values.emailAddresses.isEmpty,
                amount: !values.moneyAmounts.isEmpty,
                express: !values.shipmentTrackingNumbers.isEmpty,
                datetime: !values.calendarEvents.isEmpty
            )
        } catch {
            return nil
        }
    }

    /// 探测范围（与 `ClipboardIntentHits` 的六个类别一一对应）。
    ///
    /// 形态必须是 key-path 集合（原因见文件头 ②）；**只列下面这些**，别按类目名猜 `.xxx`：
    /// `\.links`（链接）/ `\.postalAddresses`（地址）/ `\.phoneNumbers` `\.emailAddresses`（联系方式）/
    /// `\.moneyAmounts`（金额）/ `\.shipmentTrackingNumbers`（快递单号）/ `\.calendarEvents`（日程）。
    /// 刻意**不含** `\.number`，也不请求 `\.flightNumbers`：前者一串数字（验证码/工号）误报率太高，
    /// 且两者在意图管道里都没有对应类目。
    static let patterns: Set<PartialKeyPath<UIPasteboard.DetectedValues>> = [
        \.probableWebURL, \.probableWebSearch, \.links,
        \.postalAddresses, \.phoneNumbers, \.emailAddresses,
        \.moneyAmounts, \.shipmentTrackingNumbers, \.calendarEvents,
    ]

    private static func hit(_ s: String?) -> Bool { !(s ?? "").isEmpty }
}
