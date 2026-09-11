import SwiftUI
import UIKit

// MARK: - v3.7.0 剪贴板地图链接探测（地图分享兜底入口）
//
// 背景（为什么需要它）：iOS 分享面板里出现第三方 App 的前提是 App 内打包
// **Share Extension / Action Extension**（.appex）。轻聊是 SideStore 侧载安装，
// 侧载不支持 App Extension（安装直接报 0xe8008017）——所以 iPhone 自带地图 → 分享地点
// 的面板里永远找不到轻聊（不是配置缺 UTI 的问题，CFBundleDocumentTypes 只影响
// "用其他 App 打开文件"，不影响分享面板）。
//
// 兜底路径：地图分享面板选「拷贝」→ 回到轻聊聊天页 → 顶部出现胶囊「检测到剪贴板里的位置/链接」
// → 一键交给 AI（复用 v3.4.24 的地图链接解析 → 周边推荐）。
//
// 🚨🚨 v3.7.1 修复「打开 App 即闪退」（v3.7.0 上线即挂的 P0，类级坑）：
//   原实现手写 `withCheckedContinuation { cont in UIPasteboard.general.detectPatterns(for:completionHandler:) { result in ... } }`。
//   `detectPatterns` 的 completionHandler **不是 @Sendable 参数**（UIKit 在**后台队列**回调它），
//   而写在 @MainActor 方法体里的闭包字面量**继承 MainActor 隔离** → 后台线程一进入该闭包就触发
//   Swift 6 并发隔离断言（libswift_Concurrency → dispatch_assert_queue_not）→ SIGTRAP。
//   **崩溃栈铁证（dSYM 符号化）**：崩溃帧 = `MapClipboardDetector.hasURL() 的 completion closure`，
//   且运行在 dispatch worker 线程（栈底 pthread_wqthread），上一层是 UIKitCore。
//   因为 ChatView 一进 App 就调 checkMapClipboard()，所以表现为**冷启动必崩、根本进不去**。
//
// ✅ 现在改成 UIKit 官方 **async 桥接版本** `detectedPatterns(for:)`（iOS 15+，`async throws`）：
//   线程跳转由编译器生成的 @Sendable 包装闭包负责，resume 后自动回到 MainActor，
//   不再出现"MainActor 闭包被后台线程调用"。另加**主线程同步的 `hasStrings`** 门控：
//   只查类型、不读内容、不弹「允许粘贴」，也顺带减少跨线程调用次数。
//
// 📌 类级铁律（同族坑排查用）：**UIKit/EventKit/UserNotifications 等带 completionHandler 的
//    ObjC API，只要该参数未标 @Sendable，就不能在 @MainActor 上下文里直接写闭包体**——
//    要么改用官方 async 桥接版本（首选），要么显式把它标成 `@Sendable`（并保证闭包体不碰 MainActor 状态）。
//    这类错**编译期不报、本地 swiftc -parse 查不出，只在真机崩溃**，且崩溃点会在 App 刚启动就出现。

@MainActor
enum MapClipboardDetector {

    /// 剪贴板里是否有 URL（不读内容、不弹「允许粘贴」）
    /// - 先 `hasStrings` 门控（主线程同步、零并发风险），再走 async 桥接做精确探测
    static func hasURL() async -> Bool {
        guard UIPasteboard.general.hasStrings else { return false }
        do {
            let patterns = try await UIPasteboard.general.detectedPatterns(for: [\.probableWebURL])
            return patterns.contains(\.probableWebURL)
        } catch {
            return false
        }
    }

    /// 真正读取剪贴板文本（会触发系统粘贴确认，只在用户点按后调用）
    static func readText() -> String? {
        let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
