import Foundation
import SwiftUI
import UIKit

// MARK: - v3.4.14 系统分享接入口
//
// 从其他 App（照片/文件/Safari/备忘录…）通过系统分享把内容交给轻聊。
// 原理：Info.plist 声明 CFBundleDocumentTypes（能打开的文件类型/UTI）后，
// 侧载 App 也能出现在系统分享/打开方式列表（LiveContainer 接 IPA 即此原理）。
// 数据流：DockTabView.onOpenURL 捕获分享的 URL → 解析成 SharedPayload →
//        入 ShareRouter 单例 + 广播 .qingliaoShareIncoming → ChatView 消费 →
//        复用 sendCore 作为一条消息发送给 AI。

/// 一条待处理的系统分享内容
struct SharedPayload {
    /// 文本内容（文本文件 / 链接 / 文件名提示）
    var text: String?
    /// 图片（在 ChatView 里压缩成 base64 后送 sendCore）
    var image: UIImage?
    /// 来源文件名（供提示）
    var sourceName: String?
}

/// 全局分享收件匣：DockTabView 写入，ChatView 消费（@MainActor 单例）
@MainActor
@Observable
final class ShareRouter {
    static let shared = ShareRouter()
    private(set) var pending: [SharedPayload] = []

    func enqueue(_ p: SharedPayload) {
        pending.append(p)
    }

    /// 弹出队首待处理分享；无则返回 nil
    func dequeue() -> SharedPayload? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    func hasPending() -> Bool { !pending.isEmpty }
}
