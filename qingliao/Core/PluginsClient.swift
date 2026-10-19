// Hermes 插件客户端（工作台「Hermes 插件」）· 纯 Foundation，Linux 可编。
//
// 口径（与 #24 技能库同构，别自创一套）：
//   ① 端点统一走**别名前缀 `/api/agent/plugins`** —— 蜂窝 relay 白名单只放行 `/api/agent`，
//      写死 `/api/plugins` 在 Wi-Fi 下能过、一到蜂窝就整片死。
//   ② 传输层抽成可注入闭包 `PluginsTransport`（默认由 PluginsSheet 注入 App 现成 `auth.request`）——
//      本文件不拼 URL、不读 token，自动继承 Wi-Fi/蜂窝分流与 `X-Auth-Token`。
//   ③ 全部响应容错解码：缺字段不崩；HTTP 200 但 `ok:false` 把后端 error 原样带出。
//   ④ 数据源与 Hermes 桌面端/CLI **同源**：已安装 = ~/.hermes/plugins 目录，开关 = config.yaml 的
//      plugins.enabled，插件库 = 官方 catalog（后端 6h 缓存）。
//
// 端点：
//   GET  /api/agent/plugins/list                    → {ok, plugins:[...], counts:{...}}
//   GET  /api/agent/plugins/detail?name=X           → {ok, plugin:{... readme, manifest}}
//   GET  /api/agent/plugins/catalog?q=&offset=&limit= → {ok, total, items:[...], categories:[...], source}
//   POST /api/agent/plugins/install {name}          → {ok, job, name}
//   GET  /api/agent/plugins/install_status?job=ID   → {ok, state, log, error?, plugin?}
//   POST /api/agent/plugins/toggle {name, enabled}  → {ok, name, enabled, restart}

import Foundation

/// 传输：给定 (method, path, bodyJSON) → (响应 Data, HTTP 状态码)。抛错 = 网络层失败。
typealias PluginsTransport = @MainActor (String, String, Data?) async throws -> (Data, Int)

/// 插件操作错误 —— 每类一句可读中文（不要一律「失败了」）
enum PluginsError: Error, Equatable {
    case network
    case unauthorized
    case http(Int)
    case backend(String)
    case decode

    var message: String {
        switch self {
        case .network: return "网络连接失败，请检查网络后重试"
        case .unauthorized: return "登录已过期，请重新登录后再试"
        case .http(let c): return "服务器错误（\(c)），请稍后重试"
        case .backend(let m): return m.isEmpty ? "后端返回了错误" : m
        case .decode: return "数据解析失败，请稍后重试"
        }
    }
}

/// 已安装插件（容错解码：缺字段给默认值）
struct PluginItem: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    let dir: String
    let version: String
    let description: String
    let author: String
    let category: String
    let enabled: Bool
    /// manual（手动装/拷贝）· catalog（插件库）· git（Git/URL 装）· desktop（纯桌面插件）
    let source: String
    let desktop: Bool
    let desktopOnly: Bool
    let manageable: Bool
    let skills: Int
    let path: String

    var id: String { dir.isEmpty ? name : dir }

    /// 来源标签（用户口径：手动安装的也要能一眼看出）
    var sourceLabel: String {
        switch source {
        case "manual": return "手动安装"
        case "catalog": return "插件库"
        case "git": return "Git 安装"
        case "desktop": return "桌面端"
        default: return "已安装"
        }
    }

    var sourceSymbol: String {
        switch source {
        case "manual": return "hand.raised.fill"
        case "catalog": return "square.grid.2x2.fill"
        case "git": return "chevron.left.forwardslash.chevron.right"
        default: return "desktopcomputer"
        }
    }

    private enum C: String, CodingKey {
        case name, dir, version, description, author, category, enabled
        case source, desktop, desktop_only, manageable, skills, path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: C.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        dir = (try? c.decode(String.self, forKey: .dir)) ?? ""
        version = (try? c.decode(String.self, forKey: .version)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        category = (try? c.decode(String.self, forKey: .category)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        source = ((try? c.decode(String.self, forKey: .source)) ?? "").lowercased()
        desktop = (try? c.decode(Bool.self, forKey: .desktop)) ?? false
        desktopOnly = (try? c.decode(Bool.self, forKey: .desktop_only)) ?? false
        manageable = (try? c.decode(Bool.self, forKey: .manageable)) ?? true
        skills = (try? c.decode(Int.self, forKey: .skills)) ?? 0
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
    }

    init(name: String, dir: String = "", version: String = "", description: String = "",
         author: String = "", category: String = "", enabled: Bool = false, source: String = "manual",
         desktop: Bool = false, desktopOnly: Bool = false, manageable: Bool = true,
         skills: Int = 0, path: String = "") {
        self.name = name; self.dir = dir; self.version = version
        self.description = description; self.author = author; self.category = category
        self.enabled = enabled; self.source = source; self.desktop = desktop
        self.desktopOnly = desktopOnly; self.manageable = manageable
        self.skills = skills; self.path = path
    }
}

/// 插件库条目（官方 catalog）
struct PluginCatalogItem: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    let description: String
    let maintainer: String
    let tier: String
    let category: String
    let version: String
    let repo: String
    let installed: Bool
    let installedVersion: String
    let installedEnabled: Bool
    let tools: [String]

    var id: String { name }

    var tierLabel: String {
        switch tier {
        case "official": return "官方"
        case "verified": return "认证"
        default: return "社区"
        }
    }

    private enum C: String, CodingKey {
        case name, description, maintainer, tier, category, version, repo
        case installed, installed_version, installed_enabled, tools
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: C.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        maintainer = (try? c.decode(String.self, forKey: .maintainer)) ?? ""
        tier = ((try? c.decode(String.self, forKey: .tier)) ?? "community").lowercased()
        category = (try? c.decode(String.self, forKey: .category)) ?? ""
        version = (try? c.decode(String.self, forKey: .version)) ?? ""
        repo = (try? c.decode(String.self, forKey: .repo)) ?? ""
        installed = (try? c.decode(Bool.self, forKey: .installed)) ?? false
        installedVersion = (try? c.decode(String.self, forKey: .installed_version)) ?? ""
        installedEnabled = (try? c.decode(Bool.self, forKey: .installed_enabled)) ?? false
        tools = (try? c.decode([String].self, forKey: .tools)) ?? []
    }
}

/// 插件详情
struct PluginDetail: Equatable, Sendable {
    let name: String
    let readme: String
    let path: String
    let skills: Int
    let hooks: [String]
    let deps: [String]
}

/// 安装任务状态
struct PluginInstallStatus: Equatable, Sendable {
    let state: String        // running / done / error
    let log: String
    let error: String
    let hint: String

    var isRunning: Bool { state == "running" }
    var isDone: Bool { state == "done" }
    var isError: Bool { state == "error" }
}

struct PluginsClient {
    static let basePath = "/api/agent/plugins"
    static let listPath = "/api/agent/plugins/list"
    static let detailPath = "/api/agent/plugins/detail"
    static let catalogPath = "/api/agent/plugins/catalog"
    static let installPath = "/api/agent/plugins/install"
    static let statusPath = "/api/agent/plugins/install_status"
    static let togglePath = "/api/agent/plugins/toggle"
    static let uninstallPath = "/api/agent/plugins/uninstall"

    let transport: PluginsTransport
    init(transport: @escaping PluginsTransport) { self.transport = transport }

    // MARK: - 发送

    private func send(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Data {
        let bodyData: Data? = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let data: Data
        let code: Int
        do {
            (data, code) = try await transport(method, path, bodyData)
        } catch let e as PluginsError {
            throw e
        } catch {
            throw PluginsError.network
        }
        if code == 401 || code == 403 { throw PluginsError.unauthorized }
        guard (200..<300).contains(code) else { throw PluginsError.http(code) }
        return data
    }

    private func envelope(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginsError.decode
        }
        let ok = (obj["ok"] as? Bool) ?? ((obj["ok"] as? Int).map { $0 != 0 } ?? false)
        guard ok else { throw PluginsError.backend((obj["error"] as? String) ?? "") }
        return obj
    }

    // MARK: - 六端

    /// 已安装插件（含手动安装 + 桌面端）
    func list() async throws -> [PluginItem] {
        let data = try await send("GET", Self.listPath)
        let obj = try envelope(data)
        guard let raw = obj["plugins"] as? [[String: Any]] else { return [] }
        // 逐条重编码再解码，避免 ObjectMapper 依赖；插件数很少（<30），开销可忽略
        var out: [PluginItem] = []
        for r in raw {
            if let d = try? JSONSerialization.data(withJSONObject: r),
               let item = try? JSONDecoder().decode(PluginItem.self, from: d) {
                out.append(item)
            }
        }
        return out
    }

    /// 插件库（分页 + 搜索）。返回 (items, total, categories, 数据来源)
    /// v4.0.126：补 category 参数 —— v4.0.124 只拼了 offset/limit/q，分类 chip 点了只是重拉全量首页，看起来「没生效」。
    func catalog(query: String = "", category: String = "", offset: Int = 0, limit: Int = 30)
        async throws -> (items: [PluginCatalogItem], total: Int, categories: [String], source: String) {
        var path = Self.catalogPath + "?offset=\(offset)&limit=\(limit)"
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { path += "&q=" + Self.q(q) }
        let cat = category.trimmingCharacters(in: .whitespaces)
        if !cat.isEmpty { path += "&category=" + Self.q(cat) }
        let data = try await send("GET", path)
        let obj = try envelope(data)
        let raw = (obj["items"] as? [[String: Any]]) ?? []
        var items: [PluginCatalogItem] = []
        for r in raw {
            if let d = try? JSONSerialization.data(withJSONObject: r),
               let item = try? JSONDecoder().decode(PluginCatalogItem.self, from: d) {
                items.append(item)
            }
        }
        return (items,
                (obj["total"] as? Int) ?? items.count,
                (obj["categories"] as? [String]) ?? [],
                (obj["source"] as? String) ?? "")
    }

    /// 详情（README 摘要 + 路径 + 依赖）
    func detail(name: String) async throws -> PluginDetail {
        let data = try await send("GET", Self.detailPath + "?name=" + Self.q(name))
        let obj = try envelope(data)
        let p = (obj["plugin"] as? [String: Any]) ?? [:]
        let hooks = (p["hooks"] as? [String]) ?? []
        let deps = (p["deps"] as? [String]) ?? []
        return PluginDetail(name: (p["name"] as? String) ?? name,
                            readme: (p["readme"] as? String) ?? "",
                            path: (p["path"] as? String) ?? "",
                            skills: (p["skills"] as? Int) ?? 0,
                            hooks: hooks, deps: deps)
    }

    /// 发起安装 → 返回任务 id（后台跑，App 轮询 status）
    func install(name: String) async throws -> String {
        let data = try await send("POST", Self.installPath, ["name": name])
        let obj = try envelope(data)
        return (obj["job"] as? String) ?? ""
    }

    /// 安装任务状态
    func installStatus(job: String) async throws -> PluginInstallStatus {
        let data = try await send("GET", Self.statusPath + "?job=" + Self.q(job))
        let obj = try envelope(data)
        return PluginInstallStatus(state: (obj["state"] as? String) ?? "",
                                   log: (obj["log"] as? String) ?? "",
                                   error: (obj["error"] as? String) ?? "",
                                   hint: (obj["hint"] as? String) ?? "")
    }

    /// 启用/停用（写 config.yaml 的 plugins.enabled，后端会重启网关）
    func toggle(name: String, enabled: Bool) async throws -> Bool {
        let data = try await send("POST", Self.togglePath, ["name": name, "enabled": enabled])
        let obj = try envelope(data)
        return (obj["enabled"] as? Bool) ?? enabled
    }

    /// v4.0.126：卸载 —— 后端摘 config 键 + `hermes plugins remove` + 重启网关（约 30 秒）
    func uninstall(name: String) async throws {
        let data = try await send("POST", Self.uninstallPath, ["name": name])
        _ = try envelope(data)
    }

    private static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}
