import SwiftUI
import UIKit

// MARK: - v3.7.0 剪贴板地图链接探测（地图分享兜底入口）
//
// 背景（为什么需要它）：iOS 分享面板里出现第三方 App 的前提是 App 内打包
// **Share Extension / Action Extension**（.appex）。轻聊是 SideStore 侧载安装，
// 侧载不支持 App Extension（安装直接报 0xe8008017）——所以 iPhone 自带地图 →
// 分享地点 的面板里永远找不到轻聊（不是配置缺 UTI 的问题，CFBundleDocumentTypes
// 只影响"用其他 App 打开文件"，不影响分享面板）。
//
// 兜底路径：地图分享面板选「拷贝」→ 回到轻聊聊天页 → 顶部出现胶囊「检测到位置链接」
// → 一键交给 AI（复用 v3.4.24 的地图链接解析 → 周边推荐）。
//
// 实现要点：用 iOS 16+ 的 `detectPatterns` 探测剪贴板是否为 URL —— 它**不读取内容**，
// 因此不会触发系统的「允许粘贴？」隐私弹窗；只有用户主动点「发给 AI」时才真正读内容。

@MainActor
enum MapClipboardDetector {

    /// 剪贴板里是否有 URL（不读内容、不弹「允许粘贴」）
    static func hasURL() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            UIPasteboard.general.detectPatterns(for: [\.probableWebURL]) { result in
                switch result {
                case .success(let patterns):
                    cont.resume(returning: patterns.contains(\.probableWebURL))
                case .failure:
                    cont.resume(returning: false)
                }
            }
        }
    }

    /// 真正读取剪贴板文本（会触发系统粘贴确认，只在用户点按后调用）
    static func readText() -> String? {
        let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
