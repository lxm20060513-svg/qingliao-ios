import Foundation

// 轻聊技能库 · 源码契约真值表（#24）—— Linux 本地预检用，纯 Foundation（剥注释做源级断言）。
// 与 scripts/ql_skills/test_skills.swift 分工：那边**真跑** SkillsClient 行为（假传输：正常/空/缺字段/
//   ok:false/HTTP500/超时/name 校验）；这边钉**接线形态**——端点前缀、走现成封装、不读 token、
//   列表页不在 body 发请求、删除二次确认走 AnchorMenuOverlay、设置页入口+挂 sheet+搜索索引、§102 注册。
//
// 为什么必须钉（全是静默退化）：
//   ① 端点写死 `/api/skills` → Wi-Fi 下看着能过，一到蜂窝 relay 白名单（只放行 /api/agent）整片死。
//   ② 自己拼 URL / 自己读 token → 绕过 auth 的 Wi-Fi/蜂窝分流与假 401 自愈，蜂窝下 100% 挂。
//   ③ 列表页在 body 里发请求 → 每次渲染都打一次后端（列表闪烁/重复请求）。
//   ④ 用 confirmationDialog 做二次确认 → iPhone 上从底部升起、锚不到触发按钮（仓内已统一废弃）。
//   ⑤ 设置页入口或 .sheet 被删 → 功能静默消失（编译过、点不开）；搜索索引漏一条 = 肉眼可见却搜不到。
//
// 片段连续性写法：closureBody / codeOnly；每个切片先断言**非空哨兵**，防锚点漂移后读空串全绿。
nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0
func ck(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { pass += 1; print("✅ \(name)") }
    else { fail += 1; print("❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

let repo = (ProcessInfo.processInfo.environment["QL_REPO"]).flatMap { p -> String? in
    FileManager.default.fileExists(atPath: p + "/qingliao") ? p : nil
} ?? FileManager.default.currentDirectoryPath
if !FileManager.default.fileExists(atPath: repo + "/qingliao/Core/SkillsClient.swift") {
    print("❌ 仓库根定位失败（cwd=\(FileManager.default.currentDirectoryPath)，QL_REPO=\(ProcessInfo.processInfo.environment["QL_REPO"] ?? "nil")）")
    exit(1)
}
func read(_ rel: String) -> String {
    (try? String(contentsOfFile: repo + "/" + rel, encoding: .utf8)) ?? ""
}
/// 只留代码行（注释里提到端点/`confirmationDialog` 是说明，不该被计数）
func codeOnly(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { let t = $0.trimmingCharacters(in: .whitespaces); return !t.hasPrefix("//") && !t.hasPrefix("*") }
        .joined(separator: "\n")
}
func hits(_ hay: String, _ needle: String) -> Int { hay.components(separatedBy: needle).count - 1 }

/// 取某声明后的 `{ … }` 花括号体（跳过注释/字符串里的花括号）。取不到返回 ""（调用方用非空哨兵兜）。
func closureBody(_ src: String, _ decl: String) -> String {
    guard let r = src.range(of: decl) else { return "" }
    let after = src[r.upperBound...]
    guard let open = after.firstIndex(of: "{") else { return "" }
    var depth = 0, i = open, inStr = false, esc = false
    var out = ""
    while i < src.endIndex {
        let ch = src[i]
        if inStr {
            if esc { esc = false } else if ch == "\\" { esc = true } else if ch == "\"" { inStr = false }
            out.append(ch)
        } else if ch == "\"" { inStr = true; out.append(ch) }
        else if ch == "/", src.index(after: i) < src.endIndex, src[src.index(after: i)] == "/" {
            while i < src.endIndex, src[i] != "\n" { i = src.index(after: i) }
            continue
        } else if ch == "{" {
            depth += 1; if depth == 1 { i = src.index(after: i); continue }
            out.append(ch)
        } else if ch == "}" {
            depth -= 1; if depth == 0 { return out }; out.append(ch)
        } else { out.append(ch) }
        i = src.index(after: i)
    }
    return out
}

let clientSrc = read("qingliao/Core/SkillsClient.swift")
let sheetSrc = read("qingliao/Features/Settings/SkillsLibrarySheet.swift")
let coreSrc = read("qingliao/Features/Settings/SettingsCore.swift")
let wsSrc = read("qingliao/Features/Workspace/WorkspaceView.swift")
let indexSrc = read("qingliao/Core/SettingsSearchIndex.swift")
let authSrc = read("qingliao/Core/AuthStore.swift")
let checkSrc = read("check_swift.sh")
let covSrc = read("scripts/check_guard_coverage.py")

// 哨兵：文件读不到 → 后面全在空真上跑，直接红
ck("哨兵：SkillsClient.swift 非空", clientSrc.count > 1000)
ck("哨兵：SkillsLibrarySheet.swift 非空", sheetSrc.count > 1000)
ck("哨兵：SettingsCore.swift 非空", coreSrc.count > 1000)

let clientCode = codeOnly(clientSrc)
let sheetCode = codeOnly(sheetSrc)

// ── 1. 端点前缀（蜂窝生死线）──
ck("端点带 /api/agent/ 前缀（SkillsClient 声明 basePath）",
   clientCode.contains("static let basePath = \"/api/agent/skills\""))
ck("六端齐全：list/detail/distill/save/toggle/restore 字面量都在",
   ["/api/agent/skills/detail", "/api/agent/skills/distill", "/api/agent/skills/save",
    "/api/agent/skills/toggle", "/api/agent/skills/restore"].allSatisfy { clientCode.contains($0) })
// 反例：绝不能出现「裸」/api/skills（不带 /agent/）——蜂窝 relay 白名单会整片拒发
let bare = hits(clientCode, "\"/api/skills")
ck("反例：SkillsClient 里没有裸 /api/skills（写死会蜂窝死）", bare == 0, "命中 \(bare) 次")
ck("反例：SkillsLibrarySheet 里没有裸 /api/skills", hits(sheetCode, "\"/api/skills") == 0)
ck("反例：SkillsLibrarySheet 里没有裸 /api/agent/skills 自拼端点（端点只在 SkillsClient）",
   hits(sheetCode, "\"/api/agent/skills") == 0)

// ── 2. 请求必走现成封装（不自拼 URL）──
ck("SkillsClient 不自己拼 URL（无 http:// / URL(string: \"http）",
   !clientCode.contains("http://") && !clientCode.contains("URL(string: \"http")
     && !clientCode.contains("https://"))
ck("SkillsLibrarySheet 不自己拼 URL", !sheetCode.contains("http://") && !sheetCode.contains("URL(string: \"http"))
ck("SkillsLibrarySheet 请求走现成封装 auth.request", sheetCode.contains("auth.request("))
// v4.0.104 审查**阻断项**：调用写成 `auth.request(method:path:body:)` 而真实声明是
// `request(_ path:method:body:timeout:)` —— 首参无标签。本机预检只有 -parse（不类型检查），
// 这种错**本地全绿、CI Archive 才炸**（真踩过）。所以把声明与调用两侧都钉住，任一漂移即红。
ck("哨兵：AuthStore.swift 可读（路径变了会静默假绿）", !authSrc.isEmpty)
ck("AuthStore.request 声明形态（首参无标签 path；method/body/timeout 带默认值）",
   authSrc.contains("func request(_ path: String, method: String = \"GET\", body: [String: Any]? = nil,"))
ck("SkillsLibrarySheet 调 auth.request 用无标签首参（标签写错 = CI 编译失败）",
   sheetCode.contains("auth.request(path, method:"))
ck("反例：没有 auth.request(method:（本批真实踩过的错标签）", !sheetCode.contains("auth.request(method:"))

// ── 3. 不自己读 token ──
for (label, src) in [("SkillsClient", clientCode), ("SkillsLibrarySheet", sheetCode)] {
    ck("\(label) 不读 token（无 UserDefaults / qingliao_token 读取）",
       !src.contains("UserDefaults") && !src.contains("qingliao_token"))
}

// ── 4. 列表页不在 body 里发请求 ──
ck("哨兵：切得出 SkillsLibrarySheet 的 body 体", { let b = closureBody(sheetSrc, "var body: some View"); return !b.isEmpty }())
let bodySrc = closureBody(sheetSrc, "var body: some View")
ck("反例：body 体内不发请求（无 auth.request / client. 请求）",
   !bodySrc.contains("auth.request") && !bodySrc.contains("client.list")
     && !bodySrc.contains("client.detail"))
ck("列表加载走 .task（不是渲染期）", sheetCode.contains(".task {"))

// ── 5. 二次确认走 AnchorMenuOverlay，不用 confirmationDialog ──
ck("SkillsLibrarySheet 用了 AnchorMenuOverlay", sheetCode.contains("AnchorMenuOverlay("))
ck("反例：SkillsLibrarySheet 不用 confirmationDialog", !sheetCode.contains("confirmationDialog"))

// ── 6. 详情复用仓内 MarkdownRenderer ──
ck("详情复用 MarkdownRenderer（与消息气泡同一套）", sheetCode.contains("MarkdownRenderer."))

// ── 7. 入口位置（v4.1.x 用户要求，旧口径「设置页入口」已作废）：只在工作区页 ──
ck("设置页已无技能库入口（状态/入口行/路由/索引全清）",
   !coreSrc.contains("showSkillsLibrary") && !coreSrc.contains("技能库"))
ck("工作区有「技能库」入口行（toolCell → showSkills）",
   wsSrc.contains("toolCell(\"技能库\"") && wsSrc.contains("showSkills = true"))
ck("工作区挂了 .sheet(isPresented: $showSkills) + SkillsLibrarySheet（只定义不挂 = 点了没反应）",
   wsSrc.contains(".sheet(isPresented: $showSkills)") && wsSrc.contains("SkillsLibrarySheet()"))
ck("哨兵：工作区源可读（空了上面两条就是空真）", !wsSrc.isEmpty)
// 删除提示不得无条件承诺「可撤销」（后端 recoverable:false 时是假承诺）。
// ⚠️ 只钉「体内出现过 recoverable」是**半条命**：写反成 `if !res.recoverable` 照样绿
// （v4.0.104 修复复查独立变异 M7 实测假绿）→ 必须把**两支各自钉住**（本会话既有教训）。
let deleteBody = closureBody(sheetSrc, "private func delete(")
ck("哨兵：切得出 delete() 函数体", !deleteBody.isEmpty)
ck("删除走软删并取回结果 res（recoverable 不许被丢弃）", deleteBody.contains("let res = try await client.delete("))
ck("分支① recoverable 为真 → 才承诺可撤销 + 记下撤销目标",
   deleteBody.contains("if res.recoverable {") && deleteBody.contains("（可撤销）") && deleteBody.contains("undoTarget = item"))
ck("分支② 无副本 → 明说不可撤销 + 清掉撤销目标",
   deleteBody.contains("不可撤销") && deleteBody.contains("undoTarget = nil"))
ck("反例：不许把条件写反成 !res.recoverable（写反 = 真承诺假、假承诺真）",
   !deleteBody.contains("if !res.recoverable"))
ck("搜索索引已无 skillsLibrary 路由（设置搜索不出「技能库」）",
   !indexSrc.contains("route: \"skillsLibrary\""))

// ── 8. frontmatter name 对齐（后端强校验兜底）──
ck("SkillsClient 提供 rewriteFrontmatterName", clientCode.contains("func rewriteFrontmatterName"))
ck("save 发送前调用 rewriteFrontmatterName 对齐 name",
   closureBody(clientSrc, "func save(").contains("rewriteFrontmatterName"))

// ── 9. §102 注册 + 护栏覆盖率守卫可认 ──
ck("check_swift.sh 引用了 scripts/ql_skills/", checkSrc.contains("scripts/ql_skills/"))
ck("check_swift.sh 有 §102 段标题", checkSrc.contains("102.") && checkSrc.contains("技能库"))
ck("check_guard_coverage.py 会认 scripts/ql_*/ 目录（ql_skills 会被扫）",
   covSrc.contains("startswith(\"ql_\")") && covSrc.contains("scripts/%s/"))

print("—— 源级表：\(pass) 通过 / \(fail) 失败 ——")
if fail > 0 { exit(1) }
