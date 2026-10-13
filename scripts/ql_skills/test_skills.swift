import Foundation

// 轻聊技能库 · 行为真值表（#24）—— Linux 真跑生产源码 qingliao/Core/SkillsClient.swift。
//
// 为什么必须真跑：这条链路退化**全静默** —— 缺字段解码崩（整页白屏）、HTTP 200 但 ok:false 被当成功
//   （UI 显示空/假成功）、非 2xx 不分类（一律「失败了」用户不知所以）、name 没本地校验（发到后端才拒）。
//
// 编译运行（仓库根目录）：
//   $SWIFT/swiftc -swift-version 6 -parse-as-library -o /tmp/test_skills \
//       qingliao/Core/SkillsClient.swift scripts/ql_skills/test_skills.swift
// ⚠️ -parse-as-library：本表用 @main，避免与“main.swift 顶层代码”口径冲突。

import Foundation

nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0
func ck(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { pass += 1; print("✅ \(name)") }
    else { fail += 1; print("❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

func data(_ s: String) -> Data { Data(s.utf8) }

/// 造一个假传输：固定返回 (body, code)，并记下收到的 (method, path, body)
@MainActor func fake(_ body: String, _ code: Int = 200) -> SkillsClient {
    SkillsClient { _, _, _ in (data(body), code) }
}

@main
struct SkillsBehaviorTests {
    static func main() async {
        // ── 1. 正常列表 ──
        let listJSON = """
        {"ok":true,"skills":[
          {"name":"weather-query","category":"research","title":"查天气","description":"查天气实况","size":123,"mtime":1.5,"enabled":true,"path":"/x/weather-query"},
          {"name":"nas-root","category":"devops","title":"NAS root","description":"","size":9,"mtime":2,"enabled":false,"path":"/x/nas-root"}
        ]}
        """
        do {
            let items = try await fake(listJSON).list()
            ck("正常列表：2 条", items.count == 2)
            ck("正常列表：字段解析正确", items[0].name == "weather-query" && items[0].enabled && items[1].enabled == false)
        } catch { ck("正常列表不该抛", false, "\(error)") }

        // ── 2. 空列表 ──
        do {
            let items = try await fake("{\"ok\":true,\"skills\":[]}").list()
            ck("空列表：返回空数组不崩", items.isEmpty)
        } catch { ck("空列表不该抛", false, "\(error)") }

        // ── 2b. skills 字段整体缺失 → 视作空（不崩）──
        do {
            let items = try await fake("{\"ok\":true}").list()
            ck("缺 skills 字段：视作空列表不崩", items.isEmpty)
        } catch { ck("缺 skills 字段不该抛", false, "\(error)") }

        // ── 3. 缺字段的单条不崩（只给 name）──
        do {
            let items = try await fake("{\"ok\":true,\"skills\":[{\"name\":\"only-name\"}]}").list()
            ck("缺字段条目不崩", items.count == 1 && items[0].name == "only-name")
            ck("缺字段给默认值（enabled=false / size=0 / category=''）",
               items[0].size == 0 && items[0].category == "" && items[0].enabled == false)
        } catch { ck("缺字段条目不该抛", false, "\(error)") }

        // ── 4. ok:false 带 error → 把后端文案带出 ──
        do {
            _ = try await fake("{\"ok\":false,\"error\":\"技能名已存在\"}").list()
            ck("ok:false 必须抛错", false)
        } catch let e as SkillsError {
            ck("ok:false → backend，文案带出", e == .backend("技能名已存在") && e.message == "技能名已存在")
        } catch { ck("ok:false 抛 SkillsError", false, "\(error)") }

        // ── 5. HTTP 500 → 归类 http(500) ──
        do {
            _ = try await fake("{\"error\":\"boom\"}", 500).list()
            ck("HTTP 500 必须抛错", false)
        } catch let e as SkillsError {
            ck("HTTP 500 → http(500) 且文案含 500", e == .http(500) && e.message.contains("500"))
        } catch { ck("HTTP 500 抛 SkillsError", false, "\(error)") }

        // ── 5b. 401 → 未登录 ──
        do {
            _ = try await fake("{}", 401).list()
            ck("HTTP 401 必须抛错", false)
        } catch let e as SkillsError {
            ck("HTTP 401 → unauthorized", e == .unauthorized)
        } catch { ck("HTTP 401 抛 SkillsError", false, "\(error)") }

        // ── 6. 超时 / 网络失败 → network ──
        let mktimeout = SkillsClient { _, _, _ in throw URLError(.timedOut) }
        do {
            _ = try await mktimeout.list()
            ck("超时必须抛错", false)
        } catch let e as SkillsError {
            ck("网络异常 → network，文案可读", e == .network && !e.message.isEmpty)
        } catch { ck("网络异常抛 SkillsError", false, "\(error)") }

        // ── 6b. 非 JSON 响应 → decode ──
        do {
            _ = try await fake("<html>500</html>").list()
            ck("非 JSON 必须抛错", false)
        } catch let e as SkillsError {
            ck("非 JSON → decode", e == .decode)
        } catch { ck("非 JSON 抛 SkillsError", false, "\(error)") }

        // ── 7. name 校验 ──
        ck("name 校验：合法 weather-query", SkillsClient.isValidName("weather-query"))
        ck("name 校验：合法 ab", SkillsClient.isValidName("ab"))
        ck("name 校验：非法（1 位）a", !SkillsClient.isValidName("a"))
        ck("name 校验：非法（49 位）", !SkillsClient.isValidName(String(repeating: "a", count: 49)))
        ck("name 校验：非法（大写）Weather", !SkillsClient.isValidName("Weather"))
        ck("name 校验：非法（下划线）wea_ther", !SkillsClient.isValidName("wea_ther"))
        ck("name 校验：非法（中文）天气", !SkillsClient.isValidName("天气"))
        ck("name 校验：非法（含空格）we ther", !SkillsClient.isValidName("we ther"))

        // ── 7b. save 本地拦截非法 name（不发请求）──
        do {
            _ = try await fake("{\"ok\":true}").save(name: "Bad Name", content: "x")
            ck("save 非法 name 必须本地拒", false)
        } catch let e as SkillsError {
            if case .backend = e { ck("save 非法 name 本地拒（backend 文案）", true) }
            else { ck("save 非法 name 本地拒（backend 文案）", false, "\(e)") }
        } catch { ck("save 非法 name 本地拒", false, "\(error)") }

        // ── 7c. save 合法 name 成功 ──
        do {
            let r = try await fake("{\"ok\":true,\"name\":\"my-skill\",\"category\":\"distilled\",\"enabled\":true,\"path\":\"/x/my-skill\"}")
                .save(name: "my-skill", content: "---\nname: my-skill\n---\n正文")
            ck("save 成功解析", r.name == "my-skill" && r.category == "distilled" && r.enabled)
        } catch { ck("save 合法不该抛", false, "\(error)") }

        // ── 8. 详情解析 ──
        do {
            let d = try await fake("{\"ok\":true,\"name\":\"weather-query\",\"enabled\":true,\"size\":42,\"content\":\"# 标题\",\"content_len\":4}").detail(name: "weather-query")
            ck("详情解析（content/size/content_len）", d.content == "# 标题" && d.size == 42 && d.contentLen == 4)
        } catch { ck("详情不该抛", false, "\(error)") }

        // ── 8b. 蒸馏草稿 ──
        do {
            let d = try await fake("{\"ok\":true,\"name\":\"draft-x\",\"draft\":\"正文\",\"draft_len\":2}").distill(sessionId: "sid-1")
            ck("蒸馏草稿解析", d.name == "draft-x" && d.draft == "正文" && d.draftLen == 2)
        } catch { ck("蒸馏不该抛", false, "\(error)") }

        // ── 8c. 蒸馏 400（会话不存在）→ backend 文案 ──
        do {
            _ = try await fake("{\"ok\":false,\"error\":\"会话不存在\"}").distill(sessionId: "nope")
            ck("蒸馏 400 会话不存在必须抛", false)
        } catch let e as SkillsError {
            ck("蒸馏会话不存在 → backend 文案", e.message == "会话不存在")
        } catch { ck("蒸馏会话不存在抛 SkillsError", false, "\(error)") }

        // ── 9. 启停 ──
        do {
            let r = try await fake("{\"ok\":true,\"name\":\"x\",\"enabled\":false,\"path\":\"/x/x\"}").toggle(name: "x", enabled: false)
            ck("启停解析", r.name == "x" && r.enabled == false && r.path == "/x/x")
        } catch { ck("启停不该抛", false, "\(error)") }

        // ── 10. 软删 ──
        do {
            let r = try await fake("{\"ok\":true,\"trash_path\":\"/_trash/x\",\"recoverable\":true}").delete(name: "x")
            ck("软删解析（trash_path/recoverable）", r.trashPath == "/_trash/x" && r.recoverable)
        } catch { ck("软删不该抛", false, "\(error)") }

        // ── 10b. 恢复（撤销软删）──
        do {
            let r = try await fake("{\"ok\":true,\"name\":\"x\",\"path\":\"/x/x\"}").restore(name: "x")
            ck("恢复解析（name/path）", r.name == "x" && r.path == "/x/x")
        } catch { ck("恢复不该抛", false, "\(error)") }

        // ── 10c. frontmatter name 改写（后端 save 一致性强校验的兜底）──
        let fm = "---\nname: old-name\ndescription: hi\n---\n正文"
        let rewritten = SkillsClient.rewriteFrontmatterName(fm, to: "new-name")
        ck("frontmatter name 改写：name 行被替换",
           rewritten.contains("name: new-name") && !rewritten.contains("name: old-name"))
        ck("frontmatter name 改写：只改 name 行，其余不动",
           rewritten.contains("description: hi") && rewritten.hasSuffix("正文"))
        ck("frontmatter name 改写：无 frontmatter → 原样返回",
           SkillsClient.rewriteFrontmatterName("正文无头", to: "x") == "正文无头")
        ck("frontmatter name 改写：无 name 行 → 原样返回",
           SkillsClient.rewriteFrontmatterName("---\ndescription: d\n---\n正文", to: "x")
             == "---\ndescription: d\n---\n正文")
        // save 发送时 body 里的 content 必须已对齐 name
        do {
            nonisolated(unsafe) var sent = ""
            let c = SkillsClient { _, _, b in
                sent = b.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return (data("{\"ok\":true,\"name\":\"new-name\"}"), 200)
            }
            _ = try await c.save(name: "new-name", content: fm)
            ck("save 发送前把 frontmatter name 对齐到保存名",
               sent.contains("name: new-name") && !sent.contains("name: old-name"))
        } catch { ck("save 对齐不该抛", false, "\(error)") }

        // ── 11. 请求形态：方法/路径/body 正确 ──
        nonisolated(unsafe) var seen: [(String, String, String)] = []
        let rec = SkillsClient { m, p, b in
            seen.append((m, p, b.flatMap { String(data: $0, encoding: .utf8) } ?? ""))
            return (data("{\"ok\":true}"), 200)
        }
        _ = try? await rec.toggle(name: "x", enabled: true)
        _ = try? await rec.delete(name: "my name")   // 含空格 → 应被百分号编码
        ck("toggle 走 POST /api/agent/skills/toggle 且 body 含 name/enabled",
           seen.contains { $0.0 == "POST" && $0.1 == "/api/agent/skills/toggle" && $0.2.contains("\"name\":\"x\"") && $0.2.contains("\"enabled\":true") })
        ck("delete 走 DELETE /api/agent/skills?name=… 且 name 被编码",
           seen.contains { $0.0 == "DELETE" && $0.1.hasPrefix("/api/agent/skills?name=") && $0.1.contains("my%20name") })

        // ── 12. v4.0.105 来源分组 + 纠错入口 ──
        //    退化全静默：source 缺字段不许崩、认不出的不许瞎归类、分组顺序错=用户看到的分类就乱。
        let srcJSON = """
        {"ok":true,"skills":[
          {"name":"a-gen","title":"甲","source":"generated"},
          {"name":"b-ins","title":"乙","source":"installed"},
          {"name":"c-sys","title":"丙","source":"system"},
          {"name":"d-unk","title":"丁","source":"unknown"},
          {"name":"e-missing","title":"戊"},
          {"name":"f-weird","title":"己","source":"GENERATED-ish"}
        ]}
        """
        do {
            let items = try await fake(srcJSON).list()
            ck("来源：source 缺席 → unknown（不崩也不瞎归类）",
               items.first { $0.name == "e-missing" }?.source == "unknown")
            ck("来源：认不出的取值落 unknown",
               items.first { $0.name == "f-weird" }.map { SkillSourceKind.of($0) } == .unknown)
            ck("来源：正常取值原样保留",
               items.first { $0.name == "b-ins" }?.source == "installed")
            let groups = SkillGroup.group(items)
            ck("分组：四段齐 + 顺序 = 我生成的→我安装的→系统→未定（未定垫底）",
               groups.map { $0.kind } == [.generated, .installed, .system, .unknown])
            ck("分组：每条只落一段（无重复无丢失）",
               groups.reduce(0) { $0 + $1.items.count } == items.count)
            ck("分组：未定段 = 显式 unknown + 缺席 + 认不出（三条）",
               groups.last?.items.map { $0.name }.sorted() == ["d-unk", "e-missing", "f-weird"])
        } catch { ck("来源列表解码不该抛", false, "\(error)") }

        nonisolated(unsafe) var srcSeen: [(String, String, String)] = []
        let srcClient = SkillsClient { m, p, b in
            srcSeen.append((m, p, b.flatMap { String(data: $0, encoding: .utf8) } ?? ""))
            return (data("{\"ok\":true,\"name\":\"a-gen\",\"source\":\"system\",\"cleared\":false}"), 200)
        }
        do {
            let r = try await srcClient.setSource(name: "a-gen", source: "system")
            ck("纠错：走 POST /api/agent/skills/source 且 body 带 name/source",
               srcSeen.contains { $0.0 == "POST" && $0.1 == "/api/agent/skills/source"
                   && $0.2.contains("\"name\":\"a-gen\"") && $0.2.contains("\"source\":\"system\"") })
            ck("纠错：回执解析 name/source/cleared",
               r.name == "a-gen" && r.source == "system" && r.cleared == false)
            _ = try await srcClient.setSource(name: "a-gen", source: nil)
            ck("撤销纠正：source 传空串（后端据此删覆盖键 → 回落自动判定）",
               srcSeen.last?.2.contains("\"source\":\"\"") == true)
        } catch { ck("纠错不该抛", false, "\(error)") }

        print("—— 行为表：\(pass) 通过 / \(fail) 失败 ——")
        if fail > 0 { exit(1) }
    }
}
