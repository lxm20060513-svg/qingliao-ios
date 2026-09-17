import Foundation

// MARK: - 快捷指令 / Siri 动作面的**纯逻辑**（v3.9.32）
//
// 为什么单独放一个文件：这里的东西不依赖 AppIntents / SwiftUI / UIKit，所以
// **本机没有 iOS SDK 也能编译、能跑真值表**（与 scripts/test_*.swift 的做法一致）。
// AppIntents.swift 那一半（intent 定义 + 短语）没有 SDK 编译不了，只能靠 Apple 文档逐条核对签名，
// 于是把能验证的部分尽量往这个文件里挪 —— 可验证的代码多一行，靠人眼核对的就少一行。

/// intent 里抛出的可读错误。
/// 必须走 `LocalizedError`：快捷指令/Siri 把 `errorDescription` 直接当失败文案显示，
/// 裸 `Error` 在界面上只有一句 "操作无法完成"。
struct QingliaoIntentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 深链：`qingliao://<tab>`。
///
/// `Route.rawValue` **就是** `DockTab` 的 rawValue（chat/sessions/dashboard/life/settings）——
/// App 侧只做一次 `DockTab(rawValue:)` 映射，不再维护第二张「host → 页面」表
/// （维护两张表的下场是加一个 tab 忘改一张，深链静默失效）。
enum QingliaoDeepLink {
    static let scheme = "qingliao"

    enum Route: String, CaseIterable {
        case chat, sessions, dashboard, life, settings
    }

    /// 构造深链。scheme/host 都是常量，正常不会失败；**仍然不 force unwrap**——
    /// intent 里崩溃会把 App 进程一起带走，宁可返回 nil 让调用方抛一条可读错误。
    static func url(_ route: Route) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = route.rawValue
        return c.url
    }

    static func openURL(_ route: Route) throws -> URL {
        guard let u = url(route) else {
            throw QingliaoIntentError(message: "深链构造失败（\(scheme)://\(route.rawValue)）")
        }
        return u
    }

    /// 从深链解析目标页（App 侧 `.onOpenURL` 用）。
    /// 只认本 App 的 scheme，且 host 必须在 `Route` 白名单里；其余 URL（系统分享进来的
    /// http/file 链接等）返回 nil，交给 App 原有分支按「分享内容」处理。
    static func route(for url: URL) -> Route? {
        guard url.scheme?.lowercased() == scheme,
              let host = url.host?.lowercased() else { return nil }
        return Route(rawValue: host)
    }
}

/// AI 一次性回答（`/api/stream/chat`）的返回体取值与展示口径。
enum QingliaoAIReply {

    /// 后端两种形态：`{content: "..."}` 或 OpenAI 风格 `{choices:[{message:{content}}]}`。
    /// 取值口径与 `ChatStore.compressContextWithAI` 一致 —— 同一处真相，别各写一份。
    static func text(from json: [String: Any]) -> String {
        if let c = json["content"] as? String, !c.isEmpty { return c }
        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let c = message["content"] as? String, !c.isEmpty {
            return c
        }
        return ""
    }

    /// 对话框用的短文本：Siri 念不完长回答，也不该把整篇塞进对话（完整文本走 intent 的返回值）。
    /// 换行拍平成一空格，否则 Siri 会把 markdown 列表念成断续的单字。
    static func shorten(_ text: String, limit: Int = 240) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
