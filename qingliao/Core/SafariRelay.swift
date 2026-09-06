import Foundation
import AuthenticationServices

/// Safari Relay 网络层（iOS 27 蜂窝 IPv6 上行挂起的最终方案）
/// 背景：App 进程内所有网络栈（URLSession/NWConnection/CFStream/WKWebView）在 iOS 27 蜂窝 IPv6 下
///       "无参 GET 通、带 query/body/header 全挂"（后端日志铁证：请求从未到达）；
///       Safari 进程（PWA）同网络完全正常 → 借 Safari 进程发请求。
/// 原理：ASWebAuthenticationSession 在 Safari 进程中加载 relay URL（payload base64url 进 query），
///       服务器 nginx /r 中转执行真实请求，302 回跳 qingliao://relay?r=<base64url(JSON)>，
///       ASWAS 拦截自定义 scheme 回调拿到响应。
/// 特点：下行 GET（轮询/列表）自动判定——无参走直连（快），带参走 relay；
///       上行 POST（stream/start、sessions/merge、HA 控制）全部走 relay。
/// 限制：payload ≤ ~3.5KB（URL 长度限制，nginx proxy_buffer_size 已调 16k）；
///       ASWAS 串行（多并发会闪 sheet）；用户下滑取消会按取消重试。
@MainActor
final class SafariRelay: NSObject {
    static let shared = SafariRelay()

    /// 当前正在跑的 ASWAS（串行锁：一次只能一个 sheet）
    private var activeSession: ASWebAuthenticationSession?
    /// 回调 scheme（Info.plist 已注册 qingliao URL Type）
    private let callbackScheme = "qingliao"

    /// v3.4.x code review fix（高）：runASWAS 终态共享状态（ASWAS 串行 → 单实例足够；全在 MainActor 访问）。
    /// 完成回调 / start() 失败 / 超时定时器 / Task 取消 四条路径只允许一个赢家（pendingASWASDone 闸门），
    /// 保证 continuation 恰好 resume 一次、relayQueue 排队请求不被永久堵死。
    private var pendingASWASCont: CheckedContinuation<URL, Error>?
    private var pendingTimeoutTimer: DispatchSourceTimer?
    private var pendingASWASDone = false

    /// 上下文提供方（iOS 13+ ASWAS 必需）
    private let contextProvider = RelayContextProvider()

    /// 总超时（含 sheet 弹出 + 服务器执行 + 302 回跳）
    private let relayTimeout: TimeInterval = 45

    // MARK: - 公开 API

    /// CFStream 直连任意请求（GET/POST，带 query/body）——纯 socket 层，蜂窝下也走这条路径
    /// （directGET 已验证蜂窝通；method/body 只是同一实现的参数，管控在 URLSession 高层，socket 不受影响）
    /// 返回 (data, statusCode)
    func directRequest(method: String, path: String, headers: [String: String] = [:],
                       body: Data? = nil, timeout: TimeInterval = 15) async throws -> (Data, Int) {
        guard let server = Self.currentServer(),
              let url = URL(string: server + path),
              let host = url.host else {
            throw APIError.badURL
        }
        let port = UInt16(url.port ?? (url.scheme == "https" ? 443 : 80))
        let isTLS = url.scheme == "https"
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                do {
                    let client = StreamHTTPClient()
                    let r = try client.request(host: host, port: port, isTLS: isTLS,
                                               method: method, path: path,
                                               headers: headers, body: body, timeout: timeout)
                    cont.resume(returning: r)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// 直连 GET（CFStream 无参栈）：下行读操作用这个（已验证唯一通的形态）
    /// 返回 (data, statusCode)
    func directGET(path: String, headers: [String: String] = [:], timeout: TimeInterval = 10) async throws -> (Data, Int) {
        try await directRequest(method: "GET", path: path, headers: headers, body: nil, timeout: timeout)
    }

    /// Relay 请求：经 Safari 进程发任意请求（GET/POST，带 query/body/header）
    /// payload 结构：{m: method, p: path, h: headers, b: body(utf8 string 或 nil)}
    /// 返回 (data, statusCode)
    func relay(method: String, path: String,
               headers: [String: String] = [:], body: Data? = nil,
               timeout: TimeInterval = 30) async throws -> (Data, Int) {
        guard let server = Self.currentServer(),
              let serverURL = URL(string: server) else {
            throw APIError.badURL
        }
        // 构造 relay URL：https://host:port/r?r=<base64url(payload)>
        var payload: [String: Any] = ["m": method, "p": path]
        if !headers.isEmpty { payload["h"] = headers }
        if let body, let s = String(data: body, encoding: .utf8) {
            payload["b"] = s
        }
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        let b64 = Self.base64urlEncode(jsonData)

        var comp = URLComponents()
        comp.scheme = serverURL.scheme
        comp.host = serverURL.host
        comp.port = serverURL.port ?? (serverURL.scheme == "https" ? 443 : 80)
        comp.path = "/r"
        comp.queryItems = [URLQueryItem(name: "r", value: b64)]
        guard let relayURL = comp.url else {
            throw APIError.badURL
        }

        // ASWAS 弹 sheet → Safari 进程加载 relayURL → 服务器 302 → 回调拿响应
        let callbackURL = try await runASWAS(url: relayURL, timeout: timeout)
        // 解析回调：qingliao://relay?r=<base64url({s: status, b: body})>
        guard let cbComp = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let rParam = cbComp.queryItems?.first(where: { $0.name == "r" })?.value,
              let respData = Self.base64urlDecode(rParam),
              let respJSON = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let status = respJSON["s"] as? Int,
              let bodyStr = respJSON["b"] as? String else {
            throw APIError.badResponseDetail("relay response parse fail")
        }
        return (Data(bodyStr.utf8), status)
    }

    // MARK: - 私有

    /// 串行队列：替代 while 轮询忙等待（actor 模型：排队等候 activeSession 释放）
    private var relayQueue: [CheckedContinuation<Void, Never>] = []
    
    private func acquireRelaySlot() async {
        // 无活跃 session → 直接通过
        guard activeSession != nil else { return }
        // 有活跃 session → 挂起当前 Task 直到被释放
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            relayQueue.append(cont)
        }
    }
    
    private func releaseRelaySlot() {
        activeSession = nil
        // 唤醒排队中的下一个请求
        if !relayQueue.isEmpty {
            let next = relayQueue.removeFirst()
            next.resume()
        }
    }

    private func runASWAS(url: URL, timeout: TimeInterval) async throws -> URL {
        // 串行：若已有 sheet 在跑，异步等待（不忙等，挂起到队列）
        await acquireRelaySlot()
        // v3.4.x code review fix（高）：排队等待期间 Task 已被取消 → 释放队列立即抛错，
        // 防排队请求随取消永久挂起
        if Task.isCancelled {
            releaseRelaySlot()
            throw CancellationError()
        }
        pendingASWASDone = false
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                pendingASWASCont = cont
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme
                ) { callbackURL, error in
                    // 完成回调（成功/用户取消/系统错误）——唯一正常终态入口
                    self.finishASWAS(callbackURL: callbackURL, error: error)
                }
                session.presentationContextProvider = contextProvider
                // 共享 Safari cookie/session（用户已在 Safari 信任过证书、可能登录过）
                session.prefersEphemeralWebBrowserSession = false
                // v3.4.x code review fix（高）：先置 activeSession 再 start()——若 start() 同步
                // 触发完成回调（极端竞态），releaseRelaySlot 仍能正确清位，防残留 session 永久堵死队列
                activeSession = session
                // v3.4.x code review fix（高）：start() 返回 false（无可用 presentation anchor/
                // 系统拒绝）→ 立即 resume 错误并释放队列——否则回调永不触发、continuation 永不
                // resume，后续所有排队请求（relayQueue）被永久堵死（网络层停摆）
                guard session.start() else {
                    abortASWAS(error: APIError.badResponseDetail("aswas: session.start() 失败"))
                    return
                }
                // v3.4.x code review fix（高）：timeout 参数真正生效——此前从未被使用，
                // 请求可永久挂起。超时强制 cancel session + resume 错误，防 sheet 永久悬挂
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + timeout, leeway: .milliseconds(100))
                timer.setEventHandler { [weak self] in
                    Task { @MainActor in
                        guard let self, !self.pendingASWASDone else { return }
                        self.abortASWAS(error: APIError.timeout)
                    }
                }
                timer.resume()
                pendingTimeoutTimer = timer
            }
        } onCancel: {
            // v3.4.x code review fix（高）：Task 取消传播（原实现无任何取消钩子）——
            // 终止 ASWAS sheet、释放队列并 resume，防 continuation 泄漏
            Task { @MainActor in
                guard !self.pendingASWASDone else { return }
                self.abortASWAS(error: CancellationError())
            }
        }
    }

    /// ASWAS 正常终态（回调成功/用户取消/系统错误）：清理定时器与状态后释放队列。
    /// 只允许第一个到达的终态路径执行（pendingASWASDone 闸门）。
    private func finishASWAS(callbackURL: URL?, error: Error?) {
        guard !pendingASWASDone else { return }
        pendingASWASDone = true
        pendingTimeoutTimer?.cancel()
        pendingTimeoutTimer = nil
        let cont = pendingASWASCont
        pendingASWASCont = nil
        // 先释放队列再 resume：若下一个排队请求被同步唤醒（重入），它能看到干净的 pending 状态
        releaseRelaySlot()
        if let error = error as? ASWebAuthenticationSessionError {
            if error.code == .canceledLogin {
                cont?.resume(throwing: APIError.relayCancelled)
            } else {
                cont?.resume(throwing: APIError.badResponseDetail("aswas: \(error.localizedDescription)"))
            }
            return
        }
        guard let callbackURL else {
            cont?.resume(throwing: APIError.badResponseDetail("aswas: no callback url"))
            return
        }
        cont?.resume(returning: callbackURL)
    }

    /// ASWAS 异常终态（start() 失败 / 超时 / Task 取消）：cancel session、释放队列并 resume 错误
    private func abortASWAS(error: Error) {
        guard !pendingASWASDone else { return }
        pendingASWASDone = true
        pendingTimeoutTimer?.cancel()
        pendingTimeoutTimer = nil
        let cont = pendingASWASCont
        pendingASWASCont = nil
        activeSession?.cancel()   // 终止 Safari sheet；其完成回调到达时被 pendingASWASDone 闸门挡住
        releaseRelaySlot()
        cont?.resume(throwing: error)
    }

    /// base64url 编码（URL 安全）
    private static func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// base64url 解码
    private static func base64urlDecode(_ s: String) -> Data? {
        var b64 = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // 补 padding
        let rem = b64.count % 4
        if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: b64)
    }

    /// 当前服务器地址（从 UserDefaults 读，与 AuthStore 同步）
    private static func currentServer() -> String? {
        var s = UserDefaults.standard.string(forKey: "qingliao_server")
            ?? "https://example.com:16666"
        if !s.hasPrefix("http") { s = "https://" + s }
        // 去掉尾斜杠
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// ASWAS presentation context（iOS 13+ 必需）
private final class RelayContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first }
            .first ?? ASPresentationAnchor()
    }
}

/// 会话隔离：按 App 侧 sessionId 映射固定 relay 身份 uid，relay 服务器按 uid 隔离存储
enum RelayIdentity {
    /// 当前会话的 relay uid（短 hash，固定映射）
    static func uid(for sessionId: String) -> String {
        // FNV-1a 32bit hash，纯 Foundation 无 CryptoKit
        var h: UInt32 = 2166136261
        for b in sessionId.utf8 {
            h ^= UInt32(b)
            h = h &* 16777619
        }
        return "u" + String(h, radix: 16)
    }
}
