import Foundation

// MARK: - v4.0.1 系统分享接收扩展 ↔ 主 App 的唯一协议
//
// 目的：从别的 App（照片 / Safari / 备忘录…）把**文本、链接、图片**分享进轻聊**当前会话**。
// （口径 1a：分享入口只留这三类，`project.yml` 的 activation rule 已删 File —— 本协议本身仍只认
//  文本/链接/图片三形态，`Payload.sourceName` 只做「空正文时的来源兜底」。）
//
// ## 为什么是「URL scheme + 系统剪贴板」，不是 App Groups
// 1. 侧载走**免费签名**，拿不到 App Groups entitlement（project.yml 里已登记同一结论）→
//    扩展与主 App **没有共享容器**：共享文件、`UserDefaults(suiteName:)`、共享数据库全都不可用；
// 2. 于是只用两条系统级通道，二者互补、各带一半载荷：
//      · **短内容（文本 / 链接）走 `qingliao://share?...` 的 query** —— 扩展尽力唤起主 App
//        （`NSExtensionContext.open`），主 App 用既有 `.onOpenURL` 深链路径接住，零新增机制；
//      · **图片 / 超长文本走系统剪贴板**（自定义类型，见 `pasteboardType`）—— 扩展写入，
//        主 App 在回前台 / 冷启动时读。跨 App 读剪贴板系统会弹一次「允许粘贴」，这是既定行为。
// 3. ⚠️ **iOS 18 起系统明令禁止 App 扩展拉起宿主 App**（`extensionContext.open` 抛
//    `LSApplicationWorkspaceErrorDomain 115`）。所以「唤起」只能当**尽力而为**，不能当唯一路径：
//    兜底流程是「内容已放进剪贴板 + 用户自己打开轻聊 → 主 App 自动接住」。扩展的可见 UI 必须
//    如实说清这一点（用户拍板：可见入口必须可用，不接受占位）。
//
// ## 去重
// 两条通道共用**同一个 `id` 令牌**：`open` 成功时 URL 与剪贴板会**同时**到达主 App，按令牌只处理一次
// （见 `ShareIntake.handledTokens`）。载荷自带版本号，认不出格式就整条丢弃 —— 宁可不发，
// 也不要把半条内容拼成一条错消息发进会话。
//
// 本文件是**纯 Foundation**（不 import UIKit / SwiftUI）：主 App 与分享扩展两个 target 编**同一份**源码，
// 且本机 Linux 预检环境也能直接编起来跑断言（编码规则不靠肉眼审）。
enum ShareLinkCodec {

    // MARK: - 通道常量

    /// 与主 App 同一个 URL scheme（project.yml 的 CFBundleURLTypes 已注册 `qingliao`）
    static let scheme = "qingliao"
    /// host 段：`qingliao://share`。
    /// ⚠️ **故意不并入 `QingliaoDeepLink.Route`**：那是「切页深链」（chat / sessions / …），
    /// 本协议是「带载荷的分享」。混进 Route 会被 DockTabView 当切页处理并丢掉载荷。
    static let host = "share"

    /// 剪贴板自定义类型。**只挂这一种类型**，不挂 `public.utf8-plain-text` / `public.image`：
    /// 挂了的话 ChatView 既有的「剪贴板里有链接，发给 AI？」提示条（`ClipboardIntentDetector` /
    /// `MapClipboardDetector`，走 detection API 认的是标准类型）会把同一份内容再认一遍 ——
    /// 同一份内容两条入口，用户点一次可能发两条。自定义类型不参与那套识别，两个功能互不干扰。
    static let pasteboardType = "com.qingliao.app2.share.payload"

    /// 载荷版本。升版 = 结构变了；主 App 认不出就整条丢弃（见文件头「去重」一节）。
    static let payloadVersion = 1

    // MARK: - 档位（都取名字，不写魔法值）

    /// 文本能塞进 URL 的上限（UTF-8 字节数）。超出就改走剪贴板。
    /// 取值理由：URL 要经 `extensionContext.open` / scene 传递，各版本对超长 URL 的行为不一致
    /// （可能被截断且**静默**），4000 字节足够装下「一段话 / 一个长链接」，且留足余量。
    static let maxInlineTextBytes = 4_000

    /// 图片长边上限（pt/px）。剪贴板里只放这一档：原图动辄几十 MB，塞进剪贴板既慢、
    /// 又有被系统拒掉的风险；1600 长边在聊天里看已经足够（与 v3.9.60 图片链的口径同量级）。
    static let imageMaxSide: CGFloat = 1_600

    /// 图片 JPEG 编码质量（与主 App 各处压缩同档，不另立标准）
    static let imageJPEGQuality: CGFloat = 0.8

    /// 剪贴板载荷有效期（秒）：到点由**系统**清掉，不长期占着用户的剪贴板（同 SecretsView 的用法）
    static let pasteboardTTLSeconds: TimeInterval = 600

    // MARK: - 载荷

    /// 内容类别：决定主 App 去哪条通道取正文
    enum Kind: String {
        /// 正文全在 URL 里（文本 / 链接；`text` 必非空）
        case inline
        /// 正文在系统剪贴板里（图片 / 超长文本）
        case clipboard
    }

    /// 一次分享的完整载荷（两条通道合起来才拼得出）
    struct Payload: Equatable {
        /// 去重令牌（两条通道共用同一个值）
        var id: String
        var kind: Kind
        /// 正文：分享过来的文本 / 链接
        var text: String
        /// 用户补充说明（扩展 UI 的输入框，可空）——「先说话再贴内容」的常见用法
        var note: String
        /// 来源名（网页标题等，可空）——仅用于空正文时的兜底文案
        var sourceName: String?
        /// 是否带图（图**只在剪贴板通道**里，见 `clipboardItem`）
        var hasImage: Bool
    }

    /// 新建去重令牌。两条通道各建一次就废了，所以由扩展**先建一次**、两处共用。
    static func newID() -> String { UUID().uuidString }

    /// 该走哪条通道：带图、或文本超过 URL 上限 → 剪贴板
    static func kind(text: String, hasImage: Bool) -> Kind {
        (hasImage || text.utf8.count > maxInlineTextBytes) ? .clipboard : .inline
    }

    // MARK: - 通道① URL（短内容）

    /// 组装 `qingliao://share?...`。
    /// · `.inline`：正文 / 说明 / 来源名都塞进 query（主 App 侧一次 `open` 就拿到全部内容，不读剪贴板）；
    /// · `.clipboard`：query 里**只放元信息**（令牌 + 类别 + 是否带图）—— 正文在图/超长文本那条
    ///   通道里，塞进 URL 会把它撑爆（这恰恰是当初判它走剪贴板的原因），主 App 看到 `k=clipboard`
    ///   就知道该去剪贴板取。
    static func url(for p: Payload) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        var items: [URLQueryItem] = [
            URLQueryItem(name: Key.version, value: String(payloadVersion)),
            URLQueryItem(name: Key.id, value: p.id),
            URLQueryItem(name: Key.kind, value: p.kind.rawValue),
        ]
        if p.kind == .inline {
            if !p.text.isEmpty { items.append(URLQueryItem(name: Key.text, value: base64url(p.text))) }
            if !p.note.isEmpty { items.append(URLQueryItem(name: Key.note, value: base64url(p.note))) }
            if let n = p.sourceName, !n.isEmpty { items.append(URLQueryItem(name: Key.name, value: base64url(n))) }
        }
        if p.hasImage { items.append(URLQueryItem(name: Key.image, value: "1")) }
        c.queryItems = items
        return c.url
    }

    /// 解析 URL → 载荷。**不是本协议的 URL（或认不出）返回 nil**，调用方直接放行给别的处理器。
    static func payload(from url: URL) -> Payload? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var dict: [String: String] = [:]
        for i in query where !i.name.isEmpty { dict[i.name] = i.value ?? "" }
        guard let id = dict[Key.id], !id.isEmpty,
              dict[Key.version] == String(payloadVersion),
              let kindRaw = dict[Key.kind], let kind = Kind(rawValue: kindRaw) else { return nil }
        let text = dict[Key.text].flatMap(decodeBase64url) ?? ""
        // inline 通道必须真有正文：缺了就是残载荷 → 当没收到（别往会话里发一条空消息）
        if kind == .inline && text.isEmpty { return nil }
        let name = dict[Key.name].flatMap(decodeBase64url)
        return Payload(id: id,
                       kind: kind,
                       text: text,
                       note: dict[Key.note].flatMap(decodeBase64url) ?? "",
                       sourceName: (name?.isEmpty == false) ? name : nil,
                       hasImage: dict[Key.image] == "1")
    }

    /// query 参数键名 = 剪贴板 JSON 的键名（**同一个协议的两种编码**，所以共用一套短名）。
    /// 短名是刻意的：URL 要走系统通道，越短越稳；键名只在本文件里出现。
    private enum Key {
        static let version = "v"
        static let id = "id"
        static let kind = "k"
        static let text = "t"
        static let note = "n"
        static let name = "s"
        static let image = "img"
    }

    // MARK: - 通道② 剪贴板（图片 / 超长文本）

    /// 写进剪贴板的条目（`UIPasteboard.setItems` 的入参形态）：
    /// JSON → Data，键在自定义类型下。图片以 base64 塞在 JSON 里（一个条目比两个条目省事，
    /// 也不会被别的 App 当成图片类型捡走）。
    static func clipboardItem(_ p: Payload, imageJPEG: Data?) -> [String: Any] {
        var dict: [String: Any] = [
            Key.version: payloadVersion,
            Key.id: p.id,
            Key.kind: p.kind.rawValue,
            Key.text: p.text,
            Key.note: p.note,
        ]
        if let n = p.sourceName, !n.isEmpty { dict[Key.name] = n }
        if let d = imageJPEG { dict[Key.image] = d.base64EncodedString() }
        return [pasteboardType: (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()]
    }

    /// 从剪贴板条目解出载荷（主 App 侧读 `UIPasteboard.items` 后用）。
    /// 解不出 / 版本不符 → nil（主 App 侧记为「这一版剪贴板不是我们的」）。
    static func payload(fromClipboardItem item: [String: Any]) -> (payload: Payload, imageJPEG: Data?)? {
        guard let data = item[pasteboardType] as? Data,
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              intValue(dict[Key.version]) == payloadVersion,   // JSONSerialization 回来的是 NSNumber
              let id = dict[Key.id] as? String, !id.isEmpty,
              let kindRaw = dict[Key.kind] as? String, let kind = Kind(rawValue: kindRaw) else { return nil }
        let text = dict[Key.text] as? String ?? ""
        let image = (dict[Key.image] as? String).flatMap { Data(base64Encoded: $0) }
        // 剪贴板通道必须真的带东西（正文或图）：都没有 = 残载荷
        if text.isEmpty && image == nil { return nil }
        return (Payload(id: id,
                        kind: kind,
                        text: text,
                        note: dict[Key.note] as? String ?? "",
                        sourceName: (dict[Key.name] as? String).flatMap { $0.isEmpty ? nil : $0 },
                        hasImage: image != nil),
                image)
    }

    /// JSON 里的数字经 JSONSerialization 是 `NSNumber`，直接 `as? Int` 在部分平台会失败
    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        return any as? Int
    }

    // MARK: - 落成一条用户消息的文案（主 App 发送与扩展预览共用同一份口径）

    /// 口径（**必须两边共用**：扩展预览与主 App 实际发出的必须是同一句话，各写一份必然漂移）：
    ///   · 有补充说明 → 说明在前、空行分隔（符合「先说话再贴内容」的直觉）；
    ///   · 正文非空 → 原样跟在后面（**不加任何前缀**：链接/文本原样发给 AI 才有用）；
    ///   · 正文为空（典型：只分享了一张图）→ 只剩说明；说明也空 → 返回空串，
    ///     主 App 侧走「纯图片消息」通道（`sendCore(text:imageData:)` 本来就接受空文本）；
    ///   · 正文与说明都空、但有来源名 → 「（分享自 X）」兜底，至少让会话里看得出这次分享发生过。
    static func message(for p: Payload) -> String {
        var parts: [String] = []
        let note = p.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { parts.append(note) }
        let body = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { parts.append(body) }
        if parts.isEmpty, let n = p.sourceName, !n.isEmpty { parts.append("（分享自 \(n)）") }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - base64url（URL-safe，无 padding）

    /// 正文进 URL 前先做 base64url：中文 / emoji / 换行 / `&` `#` `+` 这些字符直接进 query
    /// 极易被系统通道或百分号编码规则吃掉一节，编码后只剩 `[A-Za-z0-9-_]`，全程无忧。
    private static func base64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")   // padding 去掉：URL 里没它更干净
    }

    private static func decodeBase64url(_ s: String) -> String? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - t.count % 4) % 4
        t += String(repeating: "=", count: pad)        // 补回上面剥掉的 padding
        guard let d = Data(base64Encoded: t) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
