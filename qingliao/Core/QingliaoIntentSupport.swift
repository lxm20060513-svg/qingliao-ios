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
/// tab 路由的 `Route.rawValue` **就是** `DockTab` 的 rawValue（chat/sessions/dashboard/life/settings）——
/// App 侧只做一次 `DockTab(rawValue:)` 映射，不再维护第二张「host → 页面」表
/// （维护两张表的下场是加一个 tab 忘改一张，深链静默失效）。
/// v4.0.x：「不是某一页」的入口（智慧球快捷动作菜单）复用同一条投递链，见 `nonTabRoutes`。
enum QingliaoDeepLink {
    static let scheme = "qingliao"

    enum Route: String, CaseIterable {
        // tab 页：必须与 DockTab 的 case 一字不差
        case chat, sessions, dashboard, life, settings

        /// 非 tab 路由：打开智慧球快捷动作菜单（8 颗胶囊），**不切页**。
        /// 🚨 加这个 case 会让 `applyRoute` 里的 `DockTab(rawValue:)` 落空（静默返回）——
        ///    必须同步在 `applyRoute` 给它分支，否则用户看到的是「点了没反应」。
        case quickActions
    }

    /// 不落在 tab 上的路由白名单（唯一真源）。
    /// 护栏（`scripts/ql_intents/truth_table_intents.swift`）靠它把「Route ↔ DockTab 不许漂移」
    /// 从「集合相等」收紧成「减去白名单后相等」；不这么做就只能把比较放宽成 ⊆，
    /// 那样「加了 tab 忘改表」这种真漂移反而没人拦。
    static let nonTabRoutes: Set<Route> = [.quickActions]

    // 🔒 这里**故意不再提供**「造一条 qingliao:// 串」的助手（原 `url(_:)` / `openURL(_:)` 已删）。
    //    iOS 26 上任何「请系统 launch 本 App 自定义 scheme」的路径都会被拒 —— 用户真机在快捷指令
    //    自动化里实测到 `The provided URL scheme 'qingliao' is unsupported; launch is prohibited`。
    //    App 内跳页一律走 `QingliaoRouteHandoff`（进程内投递）；本 scheme 只留给「系统自己开自己」的
    //    场合：灵动岛 `widgetURL` 回跳、`.onOpenURL` 收系统分享与外部深链。

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


/// intent 的**应用内投递**（v4.0.x）——把「打开某页」从系统深链改成进程内路由。
///
/// 为什么不再走 `OpenURLIntent` + `qingliao://<tab>`：iOS 26 上让系统去开**自己的**自定义 scheme
/// 会当场被拒 —— 快捷指令自动化里报
/// `The provided URL scheme `qingliao` is unsupported; launch is prohibited`（用户在
/// 「打开轻聊看板」自动化上实测到，intent 侧 `.result(opensIntent:)` 那一版）。
/// 正路是 intent 声明**前台模式** `supportedModes`：系统先把 App 带到前台，
/// intent 代码在 App 进程里跑 → 「打开哪一页」不必再过系统 launch 这一关，
/// 直接投递给已经在跑的 `DockTabView`。
///
/// 两条腿缺一不可：App 已在跑时广播即时生效；App 是被这条 intent 冷启动时观察者还没注册、
/// 广播会丢 → 落一个带时间戳的兜底值，等根视图起来补读一次。
/// （与 `LiveActivityActionBridge` 同一姿势 —— 那里已经踩过「通知丢了就静默失效」。）
///
/// `qingliao://` scheme 本身**保留**：灵动岛 `widgetURL`、分享扩展回跳、`onOpenURL` 深链都还用它。
enum QingliaoRouteHandoff {

    /// 主 App 侧监听这条通知（进程内即时生效）
    static let notification = Notification.Name("qingliao.openRoute")

    /// 兜底存储 key：App 冷启动时读一次（进程刚起来时观察者还没注册，通知会丢）
    static let defaultsKey = "qingliao_pending_route"

    /// 兜底路由的有效期：超过这个时长就丢弃。
    /// 理由同 `LiveActivityActionBridge.staleAfter`：flag 万一没被消费会留到下次冷启动，
    /// 届时把用户莫名切到某个 tab。写入带时间戳，读取过期即丢。
    private static let staleAfter: TimeInterval = 60

    /// 投递目标页（intent 侧调用，已在 App 进程里）
    static func request(_ route: QingliaoDeepLink.Route) {
        UserDefaults.standard.set("\(route.rawValue)|\(Date().timeIntervalSince1970)", forKey: defaultsKey)
        NotificationCenter.default.post(name: notification, object: route.rawValue)
    }

    /// 取出并清空待处理路由；没有 / 已过期 / 格式不对都返回 nil（幂等，可重复调用）
    static func consume() -> QingliaoDeepLink.Route? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let parts = raw.split(separator: "|", maxSplits: 1)
        guard let name = parts.first.map(String.init),
              let route = QingliaoDeepLink.Route(rawValue: name) else { return nil }
        if parts.count > 1, let stamped = TimeInterval(parts[1]),
           Date().timeIntervalSince1970 - stamped > staleAfter {
            return nil
        }
        return route
    }

    /// `DockTab.rawValue` ↔ `Route.rawValue` 一一对应的唯一映射点。
    /// intent 侧只投 route 名（String），App 侧不必再认识第二种表示。
    static func route(named name: String) -> QingliaoDeepLink.Route? { QingliaoDeepLink.Route(rawValue: name) }
}
