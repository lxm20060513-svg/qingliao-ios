// #24 技能库客户端（七端封装：列表/详情/distill/save/toggle/delete/restore）· 纯 Foundation，Linux 可编真跑。
//
// 设计要点（钉死不动的口径）：
//   ① 端点统一走 **别名前缀 `/api/agent/skills`** —— 蜂窝 relay 白名单只放行 `/api/agent`，
//      写死 `/api/skills` 在 Wi-Fi 下看着能过、一到蜂窝就整片死（后端 404 / relay 拒发）。
//   ② 传输层抽成可注入闭包 `SkillsTransport`（默认由 SkillsLibrarySheet 注入 App 现成请求封装
//      `auth.request`）—— 自动处理 Wi-Fi/蜂窝分流与 `X-Auth-Token`。**本文件不拼 URL、不读 token**，
//      所以能脱离 UIKit/SwiftUI 在 Linux 真跑行为测试（注入假传输，不出网）。
//   ③ 全部响应走 Codable **容错解码**：缺字段不崩（`decodeIfPresent` / `try?`），
//      HTTP 200 但 `ok:false` 时把后端 error 文案原样带出，错误文案**分类**可读
//      （网络失败 / 未登录 / 后端 error / 解码失败各自一句中文，不是一律「失败了」）。
//
// 七端（实际解码的字段；后端多返的字段不解码也不报错 —— 容错解码，v4.0.104 只读审查 S3
// 指出「逐字对应」的说法不实，这里改成只列**真解**的）：
//   GET    /api/agent/skills                → {ok, skills:[{name,category,title,description,size,mtime,enabled,path}]}
//   GET    /api/agent/skills/detail?name=X  → {ok, name, enabled, size, content}
//   POST   /api/agent/skills/distill        {session_id, name_hint?} → {ok, name, draft}（只返草稿不落盘）
//   POST   /api/agent/skills/save           {name, content, category?, overwrite?} → {ok, name, category, enabled, path}
//   POST   /api/agent/skills/toggle         {name, enabled} → {ok, name, enabled, path}
//   DELETE /api/agent/skills?name=X         → {ok, trash_path, recoverable}（软删，进 _trash 可恢复）
//   POST   /api/agent/skills/restore        {name} → {ok, name, path, enabled}（撤销软删，还原原区/原分类）

import Foundation

/// 传输：给定 (method, path, bodyJSON) → (响应 Data, HTTP 状态码)。抛错 = 网络层失败。
/// `@MainActor`：默认实现要复用 `@MainActor` 的 `auth.request`（避免非 Sendable 值跨隔离域）。
/// 参数全为 Sendable（String / Data），测试注入的假传输同样满足。
typealias SkillsTransport = @MainActor (String, String, Data?) async throws -> (Data, Int)

/// 技能库错误 —— 每类都有**可读中文文案**（不要一律「失败了」）。
enum SkillsError: Error, Equatable {
    case network            // 连接失败 / 超时 / 断网
    case unauthorized       // 未登录 / 401 / 403
    case http(Int)          // 其余非 2xx 状态码
    case backend(String)    // 后端 ok:false 的 error 文案（原样带出）
    case decode             // 响应体解不出

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

/// 技能库列表项（容错：任一字段缺失都不崩，取默认值）
struct SkillItem: Codable, Equatable, Identifiable {
    let name: String
    let category: String
    let title: String
    let description: String
    let size: Int
    let mtime: Double
    let enabled: Bool
    let path: String

    var id: String { name }

    private enum C: String, CodingKey {
        case name, category, title, description, size, mtime, enabled, path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: C.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        category = (try? c.decode(String.self, forKey: .category)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        // size / mtime 可能是数字或字符串 → 两种都认，认不出给 0
        size = (try? c.decode(Int.self, forKey: .size))
            ?? (try? c.decode(String.self, forKey: .size)).flatMap(Int.init) ?? 0
        mtime = (try? c.decode(Double.self, forKey: .mtime))
            ?? (try? c.decode(String.self, forKey: .mtime)).flatMap(Double.init) ?? 0
        enabled = (try? c.decode(Bool.self, forKey: .enabled))
            ?? ((try? c.decode(Int.self, forKey: .enabled)).map { $0 != 0 } ?? false)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
    }

    init(name: String, category: String = "", title: String = "", description: String = "",
         size: Int = 0, mtime: Double = 0, enabled: Bool = true, path: String = "") {
        self.name = name; self.category = category; self.title = title
        self.description = description; self.size = size; self.mtime = mtime
        self.enabled = enabled; self.path = path
    }
}

/// 技能详情（SKILL.md 正文）
struct SkillDetail: Equatable {
    let name: String
    let enabled: Bool
    let size: Int
    let content: String
    let contentLen: Int
}

/// 蒸馏草稿（**只返草稿不落盘**）
struct SkillDraft: Equatable {
    let name: String
    let draft: String
    let draftLen: Int
}

/// 保存结果
struct SkillSaveResult: Equatable {
    let name: String
    let category: String
    let enabled: Bool
    let path: String
}

/// 启停结果
struct SkillToggleResult: Equatable {
    let name: String
    let enabled: Bool
    let path: String
}

/// 软删结果（进 _trash，可恢复）
struct SkillDeleteResult: Equatable {
    let trashPath: String
    let recoverable: Bool
}

/// 恢复结果（从 _trash 取回）
struct SkillRestoreResult: Equatable {
    let name: String
    let path: String
}

struct SkillsClient {
    /// 端点字面量单一真源（见文件头 ①）
    static let basePath = "/api/agent/skills"
    static let detailPath = "/api/agent/skills/detail"
    static let distillPath = "/api/agent/skills/distill"
    static let savePath = "/api/agent/skills/save"
    static let togglePath = "/api/agent/skills/toggle"
    static let restorePath = "/api/agent/skills/restore"

    let transport: SkillsTransport

    init(transport: @escaping SkillsTransport) { self.transport = transport }

    // MARK: - name 校验（保存前本地校验，与后端同一正则）

    /// `^[a-z0-9-]{2,48}$`
    static func isValidName(_ n: String) -> Bool {
        guard (2...48).contains(n.count) else { return false }
        return n.allSatisfy { ch in
            if ch == "-" { return true }
            guard ch.isASCII else { return false }
            return ch.isLowercase || ch.isNumber
        }
    }

    /// 保存前把草稿 frontmatter 顶层的 `name:` 行改写成用户确认的名字。
    /// 后端 #24 新校验：save 的 name 必须与草稿 frontmatter 里的 `name:` 一致，不一致 400
    /// （文案「草稿里的 name 与保存名不一致」）——所以调用方在保存前必须先过这一步。
    /// 规则：只认**文件首个 `---` 开头的 frontmatter 块**；改其中缩进为 0 的首条 `name:` 行；
    /// 没有 frontmatter / 块内没有 name 行 → **原样返回**（不无中生有地插入，避免破坏用户草稿）。
    static func rewriteFrontmatterName(_ content: String, to name: String) -> String {
        let lines = content.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return content
        }
        // 从第 1 行起找闭合 `---`
        var close = -1
        var i = 1
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" { close = i; break }
            i += 1
        }
        guard close > 1 else { return content }
        var out = lines
        for j in 1..<close {
            let t = lines[j]
            // 顶层键（无缩进）且为 name:
            if !t.hasPrefix(" ") && !t.hasPrefix("\t"),
               t.hasPrefix("name:") {
                out[j] = "name: \(name)"
                break
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - 统一发送 + 状态码归类

    /// 发请求并返回响应体 Data；非 2xx 按 401/403→未登录、其余→http(code) 归类。
    private func send(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Data {
        let bodyData: Data? = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let data: Data
        let code: Int
        do {
            (data, code) = try await transport(method, path, bodyData)
        } catch let e as SkillsError {
            throw e
        } catch {
            throw SkillsError.network
        }
        if code == 401 || code == 403 { throw SkillsError.unauthorized }
        guard (200..<300).contains(code) else { throw SkillsError.http(code) }
        return data
    }

    /// 解码“带 ok 信封”的响应：容错解字段，`ok != true` → 抛后端 error 文案。
    private func decodeEnvelope<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        guard let env = try? JSONDecoder().decode(OkEnvelope<T>.self, from: data) else {
            throw SkillsError.decode
        }
        guard env.ok else { throw SkillsError.backend(env.error ?? "") }
        guard let value = env.value else { throw SkillsError.decode }
        return value
    }

    // MARK: - 六端

    /// 列表
    func list() async throws -> [SkillItem] {
        let data = try await send("GET", Self.basePath, nil)
        // 列表的信封 `skills` 可能整体缺失 → 视作空列表（不崩）
        let env = try decodeList(data)
        return env
    }

    private func decodeList(_ data: Data) throws -> [SkillItem] {
        guard let env = try? JSONDecoder().decode(ListEnvelope.self, from: data) else {
            throw SkillsError.decode
        }
        guard env.ok else { throw SkillsError.backend(env.error ?? "") }
        return env.skills ?? []
    }

    /// 详情
    func detail(name: String) async throws -> SkillDetail {
        let path = Self.detailPath + "?name=" + Self.q(name)
        let data = try await send("GET", path, nil)
        guard let env = try? JSONDecoder().decode(DetailEnvelope.self, from: data) else {
            throw SkillsError.decode
        }
        guard env.ok else { throw SkillsError.backend(env.error ?? "") }
        return SkillDetail(name: env.name ?? name, enabled: env.enabled ?? true,
                           size: env.size ?? 0, content: env.content ?? "",
                           contentLen: env.contentLen ?? (env.content ?? "").count)
    }

    /// 蒸馏：从一段会话生成草稿（只返草稿不落盘）
    func distill(sessionId: String, nameHint: String? = nil) async throws -> SkillDraft {
        var body: [String: Any] = ["session_id": sessionId]
        if let h = nameHint, !h.isEmpty { body["name_hint"] = h }
        let data = try await send("POST", Self.distillPath, body)
        guard let env = try? JSONDecoder().decode(DistillEnvelope.self, from: data) else {
            throw SkillsError.decode
        }
        guard env.ok else { throw SkillsError.backend(env.error ?? "") }
        return SkillDraft(name: env.name ?? (nameHint ?? ""), draft: env.draft ?? "",
                          draftLen: env.draftLen ?? (env.draft ?? "").count)
    }

    /// 保存（name 非法时本地直接拒，不发请求）。
    /// ⚠️ 后端 #24 要求 save 的 name 与草稿 frontmatter 的 `name:` **一致** → 这里统一改写后再发，
    /// 保证单一真源，调用方忘了改也不会 400。
    func save(name: String, content: String, category: String? = nil,
              overwrite: Bool = false) async throws -> SkillSaveResult {
        guard Self.isValidName(name) else {
            throw SkillsError.backend("技能名不合法（只允许小写字母、数字、连字符，2–48 位）")
        }
        let aligned = Self.rewriteFrontmatterName(content, to: name)
        var body: [String: Any] = ["name": name, "content": aligned, "overwrite": overwrite]
        if let c = category, !c.isEmpty { body["category"] = c }
        let data = try await send("POST", Self.savePath, body)
        guard let env = try? JSONDecoder().decode(SaveEnvelope.self, from: data) else {
            throw SkillsError.decode
        }
        guard env.ok else { throw SkillsError.backend(env.error ?? "") }
        return SkillSaveResult(name: env.name ?? name, category: env.category ?? "",
                               enabled: env.enabled ?? true, path: env.path ?? "")
    }

    /// 启停
    func toggle(name: String, enabled: Bool) async throws -> SkillToggleResult {
        let data = try await send("POST", Self.togglePath, ["name": name, "enabled": enabled])
        guard let env = try? JSONDecoder().decode(ToggleEnvelope.self, from: data) else {
            throw SkillsError.decode
        }
        guard env.ok else { throw SkillsError.backend(env.error ?? "") }
        return SkillToggleResult(name: env.name ?? name, enabled: env.enabled ?? enabled,
                                 path: env.path ?? "")
    }

    /// 软删（进 _trash，可恢复）
    func delete(name: String) async throws -> SkillDeleteResult {
        let path = Self.basePath + "?name=" + Self.q(name)
        let data = try await send("DELETE", path, nil)
        guard let env = try? JSONDecoder().decode(DeleteEnvelope.self, from: data) else {
            throw SkillsError.decode
        }
        guard env.ok else { throw SkillsError.backend(env.error ?? "") }
        return SkillDeleteResult(trashPath: env.trashPath ?? "", recoverable: env.recoverable ?? true)
    }

    /// 恢复（从 _trash 取回，配合软删的「撤销」）
    func restore(name: String) async throws -> SkillRestoreResult {
        let data = try await send("POST", Self.restorePath, ["name": name])
        guard let env = try? JSONDecoder().decode(RestoreEnvelope.self, from: data) else {
            throw SkillsError.decode
        }
        guard env.ok else { throw SkillsError.backend(env.error ?? "") }
        return SkillRestoreResult(name: env.name ?? name, path: env.path ?? "")
    }

    // MARK: - 内部

    private static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}

// MARK: - 信封（全部容错：ok 认 bool 或 int；其余字段 decodeIfPresent）

private struct ListEnvelope: Decodable {
    let ok: Bool
    let error: String?
    let skills: [SkillItem]?
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        ok = K.flexBool(c, .ok); error = K.flexString(c, .error)
        skills = try? c.decodeIfPresent([SkillItem].self, forKey: .skills)
    }
}

private struct OkEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let error: String?
    let value: T?
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        ok = K.flexBool(c, .ok); error = K.flexString(c, .error)
        value = try? T(from: d)
    }
}

private struct DetailEnvelope: Decodable {
    let ok: Bool
    let error: String?
    let name: String?
    let enabled: Bool?
    let size: Int?
    let content: String?
    let contentLen: Int?
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        ok = K.flexBool(c, .ok); error = K.flexString(c, .error)
        name = K.flexString(c, .name); content = K.flexString(c, .content)
        enabled = K.flexBoolOpt(c, .enabled)
        size = (try? c.decodeIfPresent(Int.self, forKey: .size)) ?? nil
        contentLen = (try? c.decodeIfPresent(Int.self, forKey: .content_len)) ?? nil
    }
}

private struct DistillEnvelope: Decodable {
    let ok: Bool
    let error: String?
    let name: String?
    let draft: String?
    let draftLen: Int?
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        ok = K.flexBool(c, .ok); error = K.flexString(c, .error)
        name = K.flexString(c, .name); draft = K.flexString(c, .draft)
        draftLen = (try? c.decodeIfPresent(Int.self, forKey: .draft_len)) ?? nil
    }
}

private struct SaveEnvelope: Decodable {
    let ok: Bool
    let error: String?
    let name: String?
    let category: String?
    let enabled: Bool?
    let path: String?
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        ok = K.flexBool(c, .ok); error = K.flexString(c, .error)
        name = K.flexString(c, .name); category = K.flexString(c, .category)
        path = K.flexString(c, .path); enabled = K.flexBoolOpt(c, .enabled)
    }
}

private struct ToggleEnvelope: Decodable {
    let ok: Bool
    let error: String?
    let name: String?
    let enabled: Bool?
    let path: String?
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        ok = K.flexBool(c, .ok); error = K.flexString(c, .error)
        name = K.flexString(c, .name); path = K.flexString(c, .path)
        enabled = K.flexBoolOpt(c, .enabled)
    }
}

private struct DeleteEnvelope: Decodable {
    let ok: Bool
    let error: String?
    let trashPath: String?
    let recoverable: Bool?
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        ok = K.flexBool(c, .ok); error = K.flexString(c, .error)
        trashPath = K.flexString(c, .trash_path)
        recoverable = K.flexBoolOpt(c, .recoverable)
    }
}

private struct RestoreEnvelope: Decodable {
    let ok: Bool
    let error: String?
    let name: String?
    let path: String?
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        ok = K.flexBool(c, .ok); error = K.flexString(c, .error)
        name = K.flexString(c, .name); path = K.flexString(c, .path)
    }
}

private enum K: String, CodingKey {
    case ok, error, skills, name, enabled, size, content, content_len
    case draft, draft_len, category, path, trash_path, recoverable
}

private extension K {
    /// ok：认 bool("true") 或 int(1)；认不出当 false（→ 走 backend(error) 兜底，绝不假绿）
    static func flexBool(_ c: KeyedDecodingContainer<K>, _ k: K) -> Bool {
        if let b = try? c.decode(Bool.self, forKey: k) { return b }
        if let i = try? c.decode(Int.self, forKey: k) { return i != 0 }
        if let s = try? c.decode(String.self, forKey: k), let i = Int(s) { return i != 0 }
        return false
    }

    static func flexBoolOpt(_ c: KeyedDecodingContainer<K>, _ k: K) -> Bool? {
        if let b = try? c.decodeIfPresent(Bool.self, forKey: k) { return b }
        if let i = try? c.decodeIfPresent(Int.self, forKey: k) { return i != 0 }
        return nil
    }

    static func flexString(_ c: KeyedDecodingContainer<K>, _ k: K) -> String? {
        (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil
    }
}
