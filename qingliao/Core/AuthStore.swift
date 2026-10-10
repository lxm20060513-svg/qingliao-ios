import Foundation
import Observation
import Security

@MainActor
@Observable
final class AuthStore {
    var isLoggedIn = false          // 登录状态（UserDefaults 持久化）
    /// v3.9.33：登录已过期信号（非登录接口 401 → markSessionExpired() 置位；
    /// UI 侧 SessionExpiredBanner 观察它给「去登录」入口，流式层据此停止退避重试）
    var sessionExpired = false
    var username = ""
    var serverURL = ""
    private(set) var token = ""
    var errorMessage: String?
    var isLoading = false

    private let defaults = UserDefaults.standard
    private let serverKey = "qingliao_server"
    private let tokenKey = "qingliao_token"
    private let userKey = "qingliao_user"
    private let loggedKey = "qingliao_logged_in"

    /// Safari Relay 网络层（iOS 27 蜂窝上行挂起的最终方案）
    private let relay = SafariRelay.shared
    /// Wi-Fi 直连会话（蜂窝外使用，免 relay 弹窗）
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false   // 快速失败交给重试循环
        session = URLSession(configuration: cfg)
        username = defaults.string(forKey: userKey) ?? ""
        // SR9：读侧也过一遍规范化——老版本可能把「裸 host:port」或带尾斜杠的串写进了 defaults
        serverURL = Self.normalizedServerURL(defaults.string(forKey: serverKey) ?? "https://example.com:16666")
        isLoggedIn = defaults.bool(forKey: loggedKey)   // 先读登录布尔，供下方 token 兜底判断
        // v3.0.84fix：NAS token 迁 Keychain（原明文存 UserDefaults plist，可被备份/越狱读取）。
        // UserDefaults 只保留用户名/服务器/登录布尔，token 走 Keychain（genericPassword 模式）。
        // v3.0.86 fix：迁移兜底——v3.0.84 只从 Keychain 读，遗漏"升级用户"（token 仅存 UserDefaults 明文、
        // Keychain 为空，但登录布尔为 true）→ 升级后 token="" 假登录 → 业务接口（stream start 等）全 401。
        // 改为：Keychain 优先；空则回退 UserDefaults 旧 token 迁入 Keychain 并清明文残留；仍无则强制登出。
        if let kc = Self.keychainReadToken(), !kc.isEmpty {
            token = kc
        } else if let old = defaults.string(forKey: tokenKey), !old.isEmpty {
            token = old
            keychainSaveToken(old)
            defaults.removeObject(forKey: tokenKey)   // 迁移后清除明文残留
        } else {
            token = ""
            if isLoggedIn {
                // token 完全缺失却仍"已登录"（升级/清理残留）→ 强制回登录页，避免假登录 401
                isLoggedIn = false
                defaults.set(false, forKey: loggedKey)
            }
        }
    }

    // MARK: - v3.0.84fix：token 存 Keychain（弃用 UserDefaults 明文）
    private static let tokenService = "com.qingliao.app"
    private static let tokenAccount = "nas_auth_token"

    /// static internal：供后台刷新等无 AuthStore 实例处读 token
    static func keychainReadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainSaveToken(_ t: String) {
        guard !t.isEmpty else { return }
        let data = Data(t.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.tokenService,
            kSecAttrAccount as String: Self.tokenAccount,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func keychainDeleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.tokenService,
            kSecAttrAccount as String: Self.tokenAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// v2.0.55：保存服务器地址（内存 + UserDefaults 持久化）
    func saveServer(_ s: String) {
        // SR9：唯一规范化口径（补 scheme + 去尾斜杠），写进 defaults 的串永远带协议
        let clean = Self.normalizedServerURL(s)
        serverURL = clean.isEmpty ? serverURL : clean
        defaults.set(serverURL, forKey: serverKey)
        // v2.0.71：多地址记忆（去重置顶，上限 8 条）
        if !clean.isEmpty {
            var list = serverHistory.filter { $0 != clean }
            list.insert(clean, at: 0)
            defaults.set(Array(list.prefix(8)), forKey: serversKey)
        }
    }

    /// SR9：服务器地址规范化。原来登录页/服务器设置页各自补 `http://`，
    /// 而 SafariRelay / ChatStore 上传 / 后台刷新各自补 `https://` ——
    /// 同一个「裸 host:port」在不同代码路径指向不同协议：TLS-only 部署下
    /// 登录能用、图/后台通知静默失败（错误被归成"网络异常"）。
    /// 统一口径：缺协议按 https 补（与内置默认值同源），并去掉尾部斜杠
    /// （`base + "/api/..."` 拼接会产出 `//api/...`，后端 startswith 路由匹配不上）。
    static func normalizedServerURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            s = "https://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: - v2.0.71 多地址记忆（登录页快速切换）

    private let serversKey = "qingliao_servers"

    var serverHistory: [String] {
        defaults.array(forKey: serversKey) as? [String] ?? []
    }

    func removeServer(_ s: String) {
        defaults.set(serverHistory.filter { $0 != s }, forKey: serversKey)
    }

    // MARK: - 登录（POST /api/auth/login 验证账号密码；服务器 AUTO_LOGIN 免鉴权，登录页作为门禁）

    func login(username: String, password: String, remember: Bool = true) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let (data, resp) = try await request("/api/auth/login", method: "POST", body: [
                "username": username, "password": password, "remember": remember
            ])
            _ = resp.statusCode
            // request() 现在会把非 2xx 直接抛 APIError.server(code)；
            // 登录接口通常 200+body{ok:false} 表示失败，这里仍需校验 body 的 ok 字段
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (j["ok"] as? Bool) == true {
                self.username = username
                // v2.0.102：登录前清空旧 token——换服务器登录时防残留旧服务器凭据
                if let t = j["token"] as? String, !t.isEmpty {
                    token = t
                } else {
                    token = ""
                }
                defaults.set(username, forKey: userKey)
                // v3.0.84fix：token 迁 Keychain，UserDefaults 不再明文存 token
                if !token.isEmpty { keychainSaveToken(token) } else { keychainDeleteToken() }
                defaults.removeObject(forKey: tokenKey)   // 清掉历史明文残留
                isLoggedIn = true
                defaults.set(true, forKey: loggedKey)
                sessionExpired = false   // v3.9.33：重新登录成功 = 过期信号收敛（横幅消失）
                // v2.0.88：Face ID 登录开关开启（默认开）时保存凭据到 Keychain
                // v3.4.12fix：remember=false（用户关「记住我」）时不落凭据，并清掉历史凭据——密码存储不得违背用户意图
                let faceIDOn = defaults.object(forKey: "qingliao_faceid_login") as? Bool ?? true
                if faceIDOn && remember {
                    FaceIDStore.save(server: serverURL, username: username, password: password)
                } else if !remember {
                    FaceIDStore.clear()
                }
            } else {
                errorMessage = "用户名或密码错误"
            }
        } catch {
            errorMessage = "无法连接服务器（\(error.localizedDescription)）"
        }
    }

    func logout() {
        token = ""
        isLoggedIn = false
        sessionExpired = false   // v3.9.33：登出即进登录页，横幅没必要再挂（用户已在登录页）
        defaults.set(false, forKey: loggedKey)
        // v3.0.84fix：token 迁 Keychain，登出清 Keychain + 清 UserDefaults 残留
        keychainDeleteToken()
        defaults.removeObject(forKey: tokenKey)
    }

    // MARK: - v3.9.33：401 统一收敛点（全局唯一入口，别再让各调用点自己 catch）
    ///
    /// 背景：token 过期/被吊销后，非登录接口 401 只会抛 `APIError.unauthorized`，
    /// 而全仓此前**没有任何 catch** —— 流式层把它当普通失败指数退避重试 15 次，
    /// 最后只显示「连接中断，请重试」，用户永远等不到「重新登录」。
    ///
    /// 现在：凡从非登录接口判定 401 的地方（`request` / `streamStart` / `streamPoll`）
    /// 都先调用这里置位，再抛 `APIError.unauthorized`；UI 由 SessionExpiredBanner 统一提示，
    /// 流式层（StreamClient）见 `APIError.unauthorized` 直接收尾、不再退避。
    ///
    /// **不清任何 token**（内存 / 存盘都不清）：清理的唯一实现是 `logout()`，用户点
    /// 「去登录」时走它。此前这里清内存 token 是纯有害的——`isLoggedIn` 是独立存储的布尔，
    /// 清 token 既不会把人送回登录页，又让 `request()` 的 `if !token.isEmpty` 从此不再带头：
    /// 反代偶发丢一次 `X-Auth-Token` 造成的假 401，会被放大成此后所有请求恒 401，
    /// 且全仓没有任何路径在 init 之后回读 Keychain 里的存盘 token，唯一出路只剩重输密码。
    /// 保留 token 才是自愈的：真过期会继续 401（横幅一直在，语义不变），假 401 下一轮自动恢复。
    /// 置位是幂等的，重复 401 不重复处理。
    func markSessionExpired() {
        guard !sessionExpired else { return }
        sessionExpired = true
        print("[AuthStore] 非登录接口 401 → 标记登录已过期（token 保留，交由 logout() 清理）")
    }

    // MARK: - 统一请求入口（新路由层）

    /// 统一 API 请求：网络分流
    /// - Wi-Fi/其他：URLSession 直连（免 relay 弹窗）
    /// - 蜂窝：CFStream 直连优先（纯 socket 绕 iOS 27 管控），失败降级 Safari relay
    /// 返回 (data, HTTPURLResponse)
    /// - Parameter timeout: 可选超时覆盖（秒）。nil = 沿用各路径默认值（蜂窝直连 10 / relay 30 / Wi‑Fi 30）。
    ///   v3.6.2：给「后端要抓网页 + 调模型」的长耗时接口（如 /api/life/article）放宽用。
    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                 timeout: TimeInterval? = nil) async throws -> (Data, HTTPURLResponse) {
        let bodyData: Data?
        var headers: [String: String] = [:]
        if let body {
            headers["Content-Type"] = "application/json"
            bodyData = JSONSerialization.isValidJSONObject(body)
                ? (try? JSONSerialization.data(withJSONObject: body)) : nil
        } else {
            bodyData = nil
        }
        // v2.0.34 fix：登录后所有请求携带 X-Auth-Token。
        // 此前 token 只存不发 → auth 端点（change-password/logout/status）硬校验 token，
        // 无论 AUTO_LOGIN 与否都返回 401「未登录」→ 修改密码功能失效。
        if !token.isEmpty {
            headers["X-Auth-Token"] = token
        }

        // v2.0.70：蜂窝下恢复 relay 兜底（v2.0.68 一刀切去掉后蜂窝无法登录——iOS 管控下
        // 直连 POST 必挂，relay 是唯一通道；代价是 ASWAS 弹 Safari 授权窗，但可用优先）。
        // WiFi 下不弹：NetworkMonitor 已收紧（有 WiFi 接口绝不判蜂窝）+ 登录强制直连仅限 WiFi。
        // v4.0.60（用户 2026-10-05 实报「频繁弹登录窗」+ 后端日志取证）：
        // relay 兜底**只留给写操作**。ASWAS 授权框是系统级、每次调用必弹且不可缓存（无「始终允许」），
        // 而只读 GET 全是自动刷新/轮询/切页触发（看板、天气、生活卡片、inbox、列表、任务中心…），
        // 它们直连失败也降级 relay = 「后台轮询失败也弹窗」——纯扰民，且实测只产弹窗不产结果
        // （约 37h nginx 日志里 relay 载荷请求 0 条：点「取消」时 Safari 根本不发请求，服务端无痕）。
        // 只读失败即失败：上层 jsonOrLog / 看板 / 列表各自降级为「显示上次数据或空」，下轮轮询 /
        // 切页 / 下拉自会重试；写操作（发送、上传、登录、保存）保留兜底，快照类写入另有
        // SyncedStore 的待补传队列兜底（Core/PendingPinWrites.swift）。
        var (data, code) = (Data(), 0)
        if NetworkMonitor.shared.isCellular {
            let allowRelay = (method != "GET")
            var directError: Error?
            do {
                (data, code) = try await relay.directRequest(method: method, path: path,
                                                             headers: headers, body: bodyData,
                                                             timeout: timeout ?? 10)
            } catch {
                directError = error
            }
            // v4.0.19（用户 2026-10-01 真机实报「生活卡片下拉必报网络错误」+ 后端探针实锤）：
            // iOS 27 蜂窝 CFStream 直连会**静默丢自定义头**——请求到达后端时 X-Auth-Token 为空 → 假 401。
            // v4.0.60：复验方式由 relay 改为**直连重试一次**（丢头是偶发的，重试一次即带完整头）——
            // relay 复验每次都弹授权窗，真 401（token 过期）时也会白弹一次，纯代价无收益。
            if directError == nil, code == 401, headers["X-Auth-Token"]?.isEmpty == false,
               !path.contains("/api/auth/"), !sessionExpired {
                do {
                    (data, code) = try await relay.directRequest(method: method, path: path,
                                                                 headers: headers, body: bodyData,
                                                                 timeout: timeout ?? 10)
                } catch {
                    (data, code) = (Data(), 401)
                }
            }
            if let e = directError {
                if allowRelay {
                    (data, code) = try await relay.relay(method: method, path: path,
                                                         headers: headers, body: bodyData,
                                                         timeout: timeout ?? 30)
                } else {
                    // 只读：不降级 relay（免授权弹窗），如实失败。
                    // ⚠️ 已知开放项（2026-10-05 审查）：跨设备读快照（Synced·Store 的 readRemote）走 GET + query
                    //    (/api/files/pin_read?path=…)，而 v2.0.5 实测过「标准端点带 query 在蜂窝下会挂 10s 超时」。
                    //    收窄前它靠 relay 兜底，现在蜂窝下可能读不到远端快照（表现为「换设备看不到新条目」）。
                    //    → 装 4.0.60 后在蜂窝下实测一次；若真读不到，再给读接口单独开一条不弹窗的通道（如改 POST 形态）。
                    throw e
                }
            }
        } else {
            // Wi-Fi/其他：URLSession 直连（免 relay 弹窗）
            (data, code) = try await directHTTP(method: method, path: path, headers: headers,
                                                body: bodyData, timeout: timeout ?? 30)
        }

        // v3.1.8 fix: 登录接口401正常抛错（触发重新登录），其余接口401静默转200
        // 原因：反代链路(Lucky)可能丢X-Auth-Token头，导致后端返回401；3.1.8前一直正常工作
        // v3.4.x code review fix（中）：不再把 401 全量伪装成 200 吞错——只对"无害 GET 状态/列表类
        // 白名单接口"降级为 200（兼容反代丢头的只读轮询/看板场景）；鉴权（/api/auth/）与写接口
        // 及其余 401 正常抛 APIError.unauthorized（恢复真实构造点），token 过期/吊销能真正触发重新登录，
        // 401 错误体也不再被当成功 JSON 交给上层解析（缺键静默 no-op/误报 badJSON）。
        if code == 401 && !path.contains("/api/auth/") && method == "GET" && isHarmlessStatusRead(path) {
            guard let url = URL(string: serverURL + path) else { throw APIError.badURL }
            guard let fakeResp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw APIError.badResponse
            }
            return (data, fakeResp)
        }
        guard (200..<300).contains(code) else {
            // 登录接口 401 保持 server(401)（旧语义：错误提示归 login 的 catch）；其余 401 → 重新登录
            // v3.9.33：置位统一收敛点后再抛（此前只抛不置位 → 无人 catch → 用户永远等不到重新登录）
            if code == 401 && !path.contains("/api/auth/login") {
                markSessionExpired()
                throw APIError.unauthorized
            }
            throw APIError.server(code)
        }
        guard let url = URL(string: serverURL + path) else { throw APIError.badURL }
        guard let http = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil) else {
            throw APIError.badResponse
        }
        // v3.9.41（SR41）：带 token 的请求拿到 2xx = 服务器仍然认这个 token → 自愈收起过期横幅。
        // 此前 sessionExpired 只在登录成功/登出两处复位，反代偶发丢头造成的假 401 会让横幅永久挂顶，
        // 唯一出路是点「去登录」→ logout() 把本来可用的 Keychain token 清掉、被迫重输密码。
        if sessionExpired, !token.isEmpty, !path.contains("/api/auth/") {
            sessionExpired = false
            print("[AuthStore] 带 token 的请求已恢复 2xx → 收起登录过期横幅（假 401 自愈）")
        }
        return (data, http)
    }

    /// 无害 GET 状态/列表白名单：仅这些接口的 401 降级为 200（纯只读轮询/看板/列表刷新，
    /// 响应失败无副作用）；鉴权、写接口与敏感读（/api/secrets、/api/files/pin_read、/api/auth/* 等）
    /// 不在白名单 → 401 抛 APIError.unauthorized。
    private func isHarmlessStatusRead(_ path: String) -> Bool {
        let prefixes = [
            "/api/nas/", "/api/hw/", "/api/ha/", "/api/router/", "/api/weather",
            "/api/sessions/", "/api/docker/", "/api/scenes/", "/api/automations/",
            "/api/agent/", "/api/memory/", "/api/push/", "/api/kb/", "/api/history",
            "/api/cron/", "/api/logs/", "/api/channel/", "/api/stream/",
            "/api/local/", "/api/inbox", "/api/files/config", "/api/tasks",
        ]
        return prefixes.contains { path.hasPrefix($0) }
    }

    /// Wi-Fi 直连：URLSession（ephemeral，瞬断重试 3 次）——蜂窝外免 relay 弹窗
    private func directHTTP(method: String, path: String, headers: [String: String], body: Data?,
                            timeout: TimeInterval = 30) async throws -> (Data, Int) {
        guard let url = URL(string: serverURL + path) else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = body }
        var lastErr: Error?
        for attempt in 0..<3 {
            do {
                let (d, r) = try await session.data(for: req)
                let code = (r as? HTTPURLResponse)?.statusCode ?? 0
                return (d, code)
            } catch {
                lastErr = error
                let ns = error as NSError
                // 瞬断类错误（连接丢失/超时/断网/DNS失败/连接失败）重试；其余直接抛
                if attempt < 2, [-1005, -1001, -1009, -1021, -1003, -1004].contains(ns.code) {
                    try? await Task.sleep(for: .seconds(Double(attempt + 1)))
                    continue
                }
                throw error
            }
        }
        throw lastErr ?? APIError.badResponse
    }

    /// 文件下载：Wi-Fi → URLSession 直连（二进制）；蜂窝 → Safari relay（带 query 直连挂，relay 可传小文件）
    /// v2.0.116 fix：带 X-Auth-Token（files_api 鉴权）
    func downloadFile(_ path: String) async throws -> (Data, Int) {
        if NetworkMonitor.shared.isCellular {
            return try await relay.relay(method: "GET", path: path,
                                         headers: ["X-Auth-Token": token], body: nil, timeout: 30)
        } else {
            return try await directHTTP(method: "GET", path: path,
                                        headers: ["X-Auth-Token": token], body: nil)
        }
    }

    /// v4.0.60：把一份快照推 NAS（`/api/files/pin_write`）——**只直连、不降级 relay**
    /// （写快照是后台/自动动作，绝不能弹 ASWAS 授权窗）。true = 落库成功。
    /// 供 SyncedStore 写链与 PendingPinWrites 补传共用；失败如实返回 false，由调用方入待补传队列。
    /// 写快照到 NAS。**只直连、不降级 relay**（自动写不该弹 ASWAS 授权窗，v4.0.60）。
    /// 但保留「假 401 直连重试一次」：蜂窝下 CFStream 偶发静默丢自定义头 → 后端看到空 X-Auth-Token
    /// → 假 401（v4.0.19 实的坑）。少了这一步，蜂窝写快照会恒失败入队、补传又同样失败 ——
    /// 用户报的「待办没创建」就会以延迟补传的形式复现（2026-10-05 审查抓）。
    /// 重试后仍 401 = 真过期 → markSessionExpired()（否则队列永不排空且毫无提示）。
    func pushSnapshot(path: String, data: Data) async -> Bool {
        let body: [String: Any] = ["path": path, "data": data.base64EncodedString()]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return false }
        let headers = ["Content-Type": "application/json", "X-Auth-Token": token]
        do {
            var code = 0
            if NetworkMonitor.shared.isCellular {
                let r = try await relay.directRequest(method: "POST", path: "/api/files/pin_write",
                                                      headers: headers, body: bodyData, timeout: 15)
                code = r.1
                if code == 401, headers["X-Auth-Token"]?.isEmpty == false, !sessionExpired {
                    let again = try? await relay.directRequest(method: "POST", path: "/api/files/pin_write",
                                                               headers: headers, body: bodyData, timeout: 15)
                    code = again?.1 ?? 401
                    if code == 401 { markSessionExpired() }
                }
            } else {
                let r = try await directHTTP(method: "POST", path: "/api/files/pin_write",
                                             headers: headers, body: bodyData, timeout: 20)
                code = r.1
                if code == 401, headers["X-Auth-Token"]?.isEmpty == false, !sessionExpired {
                    let again = try? await directHTTP(method: "POST", path: "/api/files/pin_write",
                                                      headers: headers, body: bodyData, timeout: 20)
                    code = again?.1 ?? 401
                    if code == 401 { markSessionExpired() }
                }
            }
            return (200..<300).contains(code)
        } catch {
            print("[AuthStore] pushSnapshot 失败 \(path): \(error)")
            return false
        }
    }

    /// 便捷：JSON 请求 → 字典
    func json(_ path: String, method: String = "GET", body: [String: Any]? = nil,
              timeout: TimeInterval? = nil) async throws -> [String: Any] {
        let (data, _) = try await request(path, method: method, body: body, timeout: timeout)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badJSON
        }
        return json
    }

    /// 便捷：JSON 请求 → 数组
    func jsonArray(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [Any] {
        let (data, _) = try await request(path, method: method, body: body)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw APIError.badJSON
        }
        return arr
    }

    /// v3.0.x：便捷：JSON 请求 → 字典，失败静默返回 nil 并打日志（替代 `try? await auth.json(...)` 模式）
    /// 用途：Dashboard/Settings 等非关键加载路径，失败不弹错只 log，避免 `try?` 吞掉错误信息
    func jsonOrLog(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                   timeout: TimeInterval? = nil) async -> [String: Any]? {
        do {
            return try await json(path, method: method, body: body, timeout: timeout)
        } catch {
            print("[jsonOrLog] \(method) \(path) failed: \(error)")
            return nil
        }
    }

    // MARK: - v3.9.21 条件自动化规则（后端 rules_engine；延时型仍走 /api/automations/list）

    /// 规则列表（条件触发型）
    func loadRules() async -> [RuleItem] {
        guard let d = await jsonOrLog("/api/automations/rules"),
              let arr = d["rules"] as? [[String: Any]] else { return [] }
        return arr.map { RuleItem($0) }
    }

    /// 启停：后端会顺带清掉边沿状态，避免"启用瞬间补一刀"
    func toggleRule(id: String, enabled: Bool) async -> Bool {
        guard let d = await jsonOrLog("/api/automations/rule", method: "POST",
                                      body: ["id": id, "enabled": enabled]) else { return false }
        return (d["ok"] as? Bool) ?? false
    }

    func deleteRule(id: String) async -> Bool {
        guard let d = await jsonOrLog("/api/automations/rule/\(id)", method: "DELETE") else { return false }
        return (d["ok"] as? Bool) ?? false
    }

    /// v3.0.x：便捷：JSON 数组请求 → 数组，失败静默返回 nil 并打日志
    func jsonArrayOrLog(_ path: String, method: String = "GET", body: [String: Any]? = nil) async -> [Any]? {
        do {
            return try await jsonArray(path, method: method, body: body)
        } catch {
            print("[jsonArrayOrLog] \(method) \(path) failed: \(error)")
            return nil
        }
    }

    /// multipart 文件上传：Wi-Fi → URLSession 直传（无大小限制）；蜂窝 → relay 中转（限 2KB 小文件）
    /// SR1：三条分支都必须带 X-Auth-Token。此前只发 Content-Type——同端点的传图路径
    /// （ChatStore.uploadImage）一直是带头的，而后端 QL_AUTO_LOGIN 默认 0，
    /// 于是「发文件」在鉴权收紧后恒 401（错误还被上层归成"网络失败"）。
    func uploadMultipart(_ path: String, fileName: String, data: Data) async throws -> [String: Any] {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let formHeaders = ["Content-Type": "multipart/form-data; boundary=\(boundary)",
                           "X-Auth-Token": token]

        let (respData, code): (Data, Int)
        if NetworkMonitor.shared.isCellular {
            // 蜂窝：CFStream 直连上传（socket 层无 URL 4KB 限制，免弹窗），失败降级 relay（限 2KB 小文件）
            do {
                (respData, code) = try await relay.directRequest(
                    method: "POST", path: path,
                    headers: formHeaders,
                    body: body, timeout: 20
                )
            } catch {
                guard data.count < 2000 else {
                    throw APIError.badResponseDetail("文件过大（蜂窝下 relay 限 2KB，请用 PWA 上传）")
                }
                // v2.0.102：multipart body 含二进制（图片等）无法经 relay 文本通道——提前失败，不静默丢 body
                guard String(data: body, encoding: .utf8) != nil else {
                    throw APIError.badResponseDetail("二进制文件蜂窝下无法 relay 上传，请用 Wi-Fi")
                }
                (respData, code) = try await relay.relay(
                    method: "POST", path: path,
                    headers: formHeaders,
                    body: body, timeout: 30
                )
            }
        } else {
            (respData, code) = try await directHTTP(
                method: "POST", path: path,
                headers: formHeaders,
                body: body
            )
        }
        guard (200..<300).contains(code) else { throw APIError.server(code) }
        guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            throw APIError.badJSON
        }
        return json
    }

    // MARK: - 流式专用（relay 路径参数版）

    /// 流式启动：蜂窝 → relay POST /r/stream/start/{uid}；Wi-Fi → 直连 POST /api/stream/start
    func streamStart(sessionId: String, model: String, provider: String,
                     messages: [[String: Any]]) async throws -> String {
        // v2.0.98：Agent 能力随 streamStart 上报（默认开）
        // v3.2.1 双保险：key 缺失时 bool(forKey:) 返回 false 会误发 false 到后端（设置页显示"开"却请求不带 Agent）。
        // v3.4.12：设置页「Agent 智能回复」开关已移除——后端主链路 v3.4.8 起所有聊天恒走 Hermes agent
        // 工具循环，开关本无实权；此处恒发 true，避免旧版残留的 false 键值继续误伤。
        var payload: [String: Any] = [
            "sessionId": sessionId,
            "model": model,
            "provider": provider,
            "messages": messages,
            "pushEnabled": false,
            "agentEnabled": true,
            // v3.6.5：模型思考档位（聊天页 header 胶囊可选 关闭/低/中/高，默认 low）
            // 后端译成 Hermes 按次思考配置 model_options.reasoning，只影响轻聊请求
            "reasoning": ReasoningLevel.current.payload
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        // v2.0.116 fix：流式请求必须带 X-Auth-Token（鉴权收紧后无 token 恒 401；
        // 原只带 Content-Type——AUTO_LOGIN 时代被免鉴权掩盖）
        let authHeaders = ["Content-Type": "application/json", "X-Auth-Token": token]
        var data: Data = Data()
        var code: Int = 0
        if NetworkMonitor.shared.isCellular {
            // 蜂窝：CFStream 直连 POST 标准端点（免弹窗），失败降级 relay 路径参数版
            // v2.0.131 fix：iOS 27 蜂窝下 CFStream body 可能丢失 → 后端收到空 body 返回 400
            // （messages required）。原实现只在抛异常时降级，400 响应不降级 → 报"启动失败"。
            // 改为：直连非 2xx（含 400）同样降级 relay（relay 走 Safari 进程，body 编码进 URL 不丢）
            do {
                (data, code) = try await relay.directRequest(
                    method: "POST", path: "/api/stream/start",
                    headers: authHeaders, body: bodyData, timeout: 25
                )
            } catch {
                code = 0
            }
            if !(200..<300).contains(code) {
                let uid = RelayIdentity.uid(for: sessionId)
                (data, code) = try await relay.relay(
                    method: "POST", path: "/r/stream/start/\(uid)",
                    headers: authHeaders,
                    body: bodyData, timeout: 30
                )
            }
        } else {
            (data, code) = try await directHTTP(
                method: "POST", path: "/api/stream/start",
                headers: authHeaders, body: bodyData
            )
        }
        guard (200..<300).contains(code),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tid = json["taskId"] as? String else {
            // v3.9.33：流式启动 401 = token 过期/被吊销 → 统一收敛点置位 + 抛 unauthorized，
            // 让 StreamClient 直接以「登录已过期，请重新登录」收尾（此前被当普通启动失败）
            if code == 401 {
                markSessionExpired()
                throw APIError.unauthorized
            }
            // v3.0.52：暴露后端真实 400 原因（如 bad json / messages required），勿再只报通用码
            var errDetail = ""
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = obj["error"] as? String {
                errDetail = " — " + msg
            }
            throw APIError.badResponseDetail("stream start fail (\(code))\(errDetail)")
        }
        return tid
    }

    /// 流式轮询：蜂窝 → 直连 GET /r/stream/poll/{uid}/{taskId}/{offset}（路径参数）；Wi-Fi → 直连 GET /api/stream/{taskId}?offset=N

    /// v3.4.23 任务中心：进行中任务
    /// v3.4.25：路径改用 /api/agent/tasks/active——16666(lucky) 反代只放行 /api/agent 前缀，
    /// 原 /api/tasks 前缀被 lucky 404，App 主链路（https://域名:16666）拉不到任务中心
    struct ActiveTask: Identifiable {
        let id: String          // jobId
        let kind: String        // stream / bg
        let title: String
        let detail: String
        let status: String      // running / done / error
        let createdAt: TimeInterval
        /// v4.0.37：结构化步骤（后端 `plan[]`，见 ActiveTaskPlan）。老后端=空数组 → 任务中心不渲染步骤清单。
        let plan: [ActiveTaskPlan.Step]
        /// v4.0.37：后端全量步数（`planSeq`）。比 `plan.count` 大 → 任务中心出「更早的 N 步未列出」。
        let planSeq: Int
        /// v4.0.86（任务中心③）：历史任务的收尾结果 / 失败原因（active 任务恒空串）
        var result: String = ""
    }

    /// v4.0.86（任务中心③）：历史任务列表 —— done/error 的后台作业（bgjobs.json 真源，重启不丢）。
    /// 老后端无此端点 → 404/解析失败 → 空数组，任务中心历史页显示空态，不报错。
    func fetchTaskHistory() async -> [ActiveTask] {
        guard !token.isEmpty else { return [] }
        do {
            let json = try await self.json("/api/tasks/history?limit=100", method: "GET")
            guard let arr = json["tasks"] as? [[String: Any]] else { return [] }
            return arr.compactMap { d in
                guard let jid = d["jobId"] as? String, !jid.isEmpty else { return nil }
                return ActiveTask(
                    id: jid,
                    kind: d["kind"] as? String ?? "bg",
                    title: d["title"] as? String ?? "",
                    detail: d["detail"] as? String ?? "",
                    status: d["status"] as? String ?? "done",
                    createdAt: (d["createdAt"] as? Double) ?? (d["createdAt"] as? TimeInterval) ?? 0,
                    plan: [],
                    planSeq: 0,
                    result: d["result"] as? String ?? "")
            }
        } catch {
            return []
        }
    }

    func fetchActiveTasks() async -> [ActiveTask] {
        guard !token.isEmpty else { return [] }
        do {
            let json = try await self.json("/api/agent/tasks/active", method: "GET")
            guard let arr = json["tasks"] as? [[String: Any]] else { return [] }
            return arr.compactMap { d in
                guard let jid = d["jobId"] as? String, !jid.isEmpty else { return nil }
                return ActiveTask(
                    id: jid,
                    kind: d["kind"] as? String ?? "stream",
                    title: d["title"] as? String ?? "",
                    detail: d["detail"] as? String ?? "",
                    status: d["status"] as? String ?? "running",
                    createdAt: (d["createdAt"] as? Double) ?? (d["createdAt"] as? TimeInterval) ?? 0,
                    // v4.0.37：结构化步骤（解析语义与脏数据兜底全在 Core/ActiveTaskPlan.swift，
                    // 有真值表盯着）。老后端无这两个键 → 空数组 / 0，任务中心优雅退化。
                    plan: ActiveTaskPlan.parse(d["plan"]),
                    planSeq: (d["planSeq"] as? Int) ?? (d["planSeq"] as? Double).map(Int.init) ?? 0)
            }
        } catch {
            return []
        }
    }

    func streamPoll(taskId: String, offset: Int) async throws -> (String, Bool, String, String, Bool, [[String: Any]], [String], [[String: Any]], Double, Int, [String], String) {
        let (data, code): (Data, Int)
        // v2.0.116 fix：轮询也带 X-Auth-Token（后端 do_GET 统一鉴权）
        if NetworkMonitor.shared.isCellular {
            // 蜂窝：必须用路径参数形态（/r/stream/poll/... 无 query）——CFStream 带 query 会挂起 10s 超时，
            // 标准端点带 query 在蜂窝不可用（v2.0.5 实踩：流式输出失效）
            let uid = RelayIdentity.uid(for: currentStreamSessionId)
            (data, code) = try await relay.directGET(path: "/r/stream/poll/\(uid)/\(taskId)/\(offset)",
                                                     headers: ["X-Auth-Token": token], timeout: 10)
        } else {
            (data, code) = try await directHTTP(method: "GET", path: "/api/stream/\(taskId)?offset=\(offset)",
                                                headers: ["X-Auth-Token": token], body: nil)
        }
        guard (200..<300).contains(code),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // v3.9.33：轮询 401 单独成信号——此前一律抛 server(401)，被 StreamClient 当普通失败
            // 指数退避重试 15 次（≈2 分钟）后才报「连接中断，请重试」，token 过期用户永远等不到重新登录。
            // 现在置位统一收敛点 + 抛 unauthorized，StreamClient 立即停止退避并如实收尾。
            if code == 401 {
                markSessionExpired()
                throw APIError.unauthorized
            }
            // v3.0.31：404 = 任务不存在（qingliao 重启/回收）→ 抛带码错误，StreamClient 据此走 recover
            throw APIError.server(code)
        }
        let content = j["content"] as? String ?? ""
        let done = j["done"] as? Bool ?? false
        let status = j["status"] as? String ?? ""
        let error = j["error"] as? String ?? ""
        let agent = j["agent"] as? Bool ?? false   // v2.0.96b：Agent 回复标记
        // v3.4.23：搭载的收件箱待推消息（后端 piggyback，老后端无此键=空数组）
        let inbox = j["inbox"] as? [[String: Any]] ?? []
        // v3.9.17：AI 后端（Hermes 路径）的工具进度——后端已把工具名翻成中文下发，
        // App 不维护第二份映射表（一处真相在后端 _TOOL_NAME_ZH）。老后端无此键=空数组。
        let toolNames = j["toolNames"] as? [String] ?? []
        // v3.9.58：已完成工具步骤的耗时 [{n:中文名, s:秒}]——老后端无此键=空数组（耗时显示整体退化为无秒数）
        let toolSpans: [[String: Any]] = j["toolSpans"] as? [[String: Any]] ?? []
        let lastToolAt = j["lastToolAt"] as? Double ?? (j["lastToolAt"] as? Int).map(Double.init) ?? 0
        // v3.9.80：**真实工具步数**（后端 `toolSeq`：每收到一个 function_call 事件 +1，全量计数）。
        // toolNames 只下发**最近 10 步**（后端防长任务把响应撑大）→ 摘要行的「N 步工具调用」必须用这个数，
        // 否则 10 步以上的任务一律显示成 10 步（用户 2026-09-25 真机反馈）。
        // 老后端无此键 = 0 → UI 回落 toolNames.count（优雅退化，不显示假步数）。
        let toolSeq = (j["toolSeq"] as? Int) ?? (j["toolSeq"] as? Double).map(Int.init) ?? 0
        // v4.0.120：本流**本次新记住**的条目（后端 memoAdded）。老后端无此键=空数组 → 不弹气泡。
        // 与 toolNames/toolSeq 同为「纯增量、整流只增不减」，幂等重发无害。
        let memoAdded = j["memoAdded"] as? [String] ?? []
        // v4.0.90：模型思考摘要流（后端 reasoning_summary 增量累积）。老后端无此键 = 空串 →
        // 思考气泡不渲染（优雅退化，与 v4.0.89 及之前行为完全一致）。
        let reasoning = j["reasoning"] as? String ?? ""
        return (content, done, status, error, agent, inbox, toolNames, toolSpans, lastToolAt, toolSeq, memoAdded, reasoning)
    }

    /// v3.0.31：流式任务恢复——qingliao 服务重启后内存任务丢失（poll 404），
    /// 调 /api/stream/recover 找回：内存优先（返回可继续轮询的 taskId），
    /// 磁盘兜底（streams/*.json 节流落盘，返回 done=true + 完整内容）。
    ///
    /// 待做池⑥：磁盘兜底分支还会带 `outcome`（中断标记）/ `plan` / `planSeq`（已完成步）——
    /// 这几个断点信息在此一并解出（口径见 `Core/ResumeInfo.swift`），供调用方如实外显
    /// 「已完成第 k 步 · 结果未知 · 未自动重放」。老后端无这些键 → 空值，零行为变化。
    struct RecoverResult {
        let taskId: String?
        let content: String
        let done: Bool
        let status: String
        let error: String
        let outcome: String
        let plan: [ActiveTaskPlan.Step]
        let planSeq: Int
    }

    func streamRecover(sessionId: String) async throws -> RecoverResult {
        let enc = sessionId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sessionId
        let (data, _) = try await request("/api/stream/recover?sessionId=" + enc)
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badJSON
        }
        let tid = j["taskId"] as? String
        let content = j["content"] as? String ?? ""
        let done = j["done"] as? Bool ?? true
        let status = j["status"] as? String ?? ""
        let error = j["error"] as? String ?? ""
        // 待做池⑥：中断任务的断点信息（老后端无键 → 空 / [] / 0，调用方按「非中断」处理）。
        let outcome = j["outcome"] as? String ?? ""
        let plan = ActiveTaskPlan.parse(j["plan"])
        let planSeq = (j["planSeq"] as? Int) ?? (j["planSeq"] as? Double).map(Int.init) ?? 0
        return RecoverResult(taskId: tid, content: content, done: done, status: status,
                             error: error, outcome: outcome, plan: plan, planSeq: planSeq)
    }

    /// 流式停止：蜂窝 → CFStream 直连 POST（免弹窗）；Wi-Fi → 直连
    /// v4.0.60：蜂窝下**不再降级 relay**——停流是收尾动作（服务端自身也会超时收尾），
    /// 为它弹一次 ASWAS 授权窗不值，且 relay 串行队列会插队堵住用户紧接着的请求。
    func streamStop(taskId: String) async {
        if NetworkMonitor.shared.isCellular {
            _ = try? await relay.directRequest(method: "POST", path: "/api/stream/\(taskId)/stop",
                                               headers: ["X-Auth-Token": token], timeout: 8)
        } else {
            _ = try? await directHTTP(method: "POST", path: "/api/stream/\(taskId)/stop",
                                      headers: ["X-Auth-Token": token], body: nil)
        }
    }

    /// 当前流式会话 id（StreamClient 启动时设置，用于 uid 推导）
    internal(set) var currentStreamSessionId: String = ""

    // MARK: - 连通性测试

    /// 测试连接：v2.0.102 改为直连传入的地址（原实现测的是已保存地址，误导排查）
    func testConnection(server: String) async -> String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s + "/api/auth/status"), url.host != nil else {
            return "❌ 服务器地址无效"
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.httpMethod = "GET"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 200 {
                return "✅ 连接正常（服务器已响应）"
            }
            return "⚠️ 服务器返回 \(code)"
        } catch {
            return "❌ 无法连接（\(error.localizedDescription)）"
        }
    }

    /// v2.0.87t：前台恢复自动重连（后台挂起蜂窝 IPv6 会话过期 → 恢复时重建连接）
    /// v2.0.87ar：蜂窝下只直连试探（不触发 relay 授权弹窗——弹窗只在用户实际操作时弹出）
    func refreshConnection() async {
        guard !serverURL.isEmpty else { return }
        // v4.0.60：前台恢复 = 网络大概率换过了 → 顺势补传蜂窝下写失败的快照
        // （空队列是空操作；补传只走直连、不弹授权窗。token 已判定过期时补传必失败，直接跳过）
        if !sessionExpired { await PendingPinWrites.flush(auth: self) }
        do {
            if NetworkMonitor.shared.isCellular {
                _ = try await relay.directRequest(method: "GET", path: "/api/auth/status", timeout: 8)
            } else {
                _ = try await directHTTP(method: "GET", path: "/api/auth/status", headers: [:], body: nil)
            }
        } catch {
            // 静默：失败不打扰（避免频繁弹窗），用户实际操作时再走完整 relay
        }
    }
}

enum APIError: Error, LocalizedError {
    case badURL, badResponse, badResponseDetail(String), badJSON, unauthorized, timeout, timeoutDetail(String), server(Int)
    case relayCancelled

    var errorDescription: String? {
        switch self {
        case .badURL: return "服务器地址无效"
        case .badResponse: return "服务器响应异常"
        case .badResponseDetail(let d): return "服务器响应异常（\(d)）"
        case .badJSON: return "数据解析失败"
        case .unauthorized: return "登录已过期，请重新登录"
        case .timeout: return "请求超时"
        case .timeoutDetail(let d): return "请求超时（\(d)）"
        case .server(let code): return "服务器错误（\(code)）"
        case .relayCancelled: return "已取消"
        }
    }
}
