// MARK: - v4.0.x 邮件接入设置页 · 真值表（安全边界 + 后端契约 + 接线）
//
// 背景：邮件账号走后端 mail_api（IMAP/SMTP），App 端只做账号管理界面。
// 这张表盯三类「本地预检查不出、出了就是安全事故/功能全废」的东西：
//   ① 安全边界：授权码明文绝不落 App、列表绝不回显、后端密文不反解
//   ② 后端契约：路径/方法/字段名与 mail_api.py 严格对齐（写错 = 静默失败，200+ok:false）
//   ③ 接线：设置页入口行、sheet 挂载、nginx/relay 三处已在后端侧就绪（这里钉 App 侧）
//
// 口径提醒（v3.9.87 实锤）：切片锚点必须取**代码行**，不能取 // MARK: 注释行
// —— stripComments 会先剥掉整行注释，锚在注释上会让下面全部变空真恒绿。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 子串出现次数（本表要用"恰好 2 个新增入口"这类断言，contains 分不出 1 个和 2 个）。
func occurrences(_ s: String, _ needle: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var n = 0, idx = s.startIndex
    while let r = s.range(of: needle, range: idx..<s.endIndex) {
        n += 1
        idx = r.upperBound
        if idx >= s.endIndex { break }
    }
    return n
}

/// v4.0.0：去掉 `//` 与 `/* */` 注释，只留代码文本。
func stripComments(_ s: String) -> String {
    var out = ""
    var inLine = false, inBlock = false
    var prev: Character = " "
    for ch in s {
        if inLine {
            if ch == "\n" { inLine = false; out.append(ch) }
            continue
        }
        if inBlock {
            if ch == "*" && prev == "/" { inBlock = false }
            prev = ch == "*" ? "*" : " "
            continue
        }
        if ch == "/" && prev == "/" { inLine = true; prev = " "; continue }
        if ch == "/" , let n = out.last, n == "*" { inBlock = true; prev = " "; continue }
        out.append(ch)
        prev = ch
    }
    return out.replacingOccurrences(of: "*/", with: " ")
}

/// 取 a 之后、b 之前的一段源码（先断言切片非空，否则下面断言等于空真）
func slice(_ s: String, _ a: String, _ b: String) -> String {
    guard let ra = s.range(of: a),
          let rb = s.range(of: b, range: ra.upperBound..<s.endIndex) else { return "" }
    return String(s[ra.upperBound..<rb.lowerBound])
}

let mailSrc = src("qingliao/Features/Settings/MailSettingsSheet.swift")
let mailCode = stripComments(mailSrc)
let coreSrc = stripComments(src("qingliao/Features/Settings/SettingsCore.swift"))

// ── 1. 源可读（空了后面全是空真） ─────────────────────────────
check("MailSettingsSheet.swift 源可读", !mailSrc.isEmpty)
check("SettingsCore.swift 源可读", !coreSrc.isEmpty)

// ── 2. 安全边界：授权码明文不落 App、不回显、不反解 ──────────────
check("没有 @AppStorage 存授权码", !mailCode.contains("@AppStorage"))
check("没有 UserDefaults 落盘授权码",
      !mailCode.contains("UserDefaults") && !mailCode.contains("KeychainHelper"))
check("没有把授权码写进本地文件",
      !mailCode.contains("FileManager") && !mailCode.contains(".write(to:"))
check("没有解密/反解后端密文（reveal 之类）",
      !mailCode.contains("reveal") && !mailCode.contains("decrypt"))
// 列表行的副标题只能用后端给的 last_test 结论，绝不能拼 secret
let listRow = slice(mailCode, "private func row(", "private func subtitle(")
check("列表行切片非空（防空真）", !listRow.isEmpty)
check("列表行不出现 secret 字段", !listRow.contains("secret"))
let subtitleFn = slice(mailCode, "private func subtitle(", "private func subtitleColor(")
check("副标题切片非空（防空真）", !subtitleFn.isEmpty)
check("副标题只读 lastTestOK/lastTestError，不碰 secret",
      subtitleFn.contains("a.lastTestOK") && !subtitleFn.contains("secret"))
// 授权码输入框必须是 SecureField，不能是 TextField 明文
let secretSection = slice(mailCode, "Section(\"授权码", "Section {\n                    Toggle(\"允许 AI")
check("授权码切片取到（防空真）", !secretSection.isEmpty)
check("授权码输入用 SecureField（不是明文 TextField）",
      secretSection.contains("SecureField") && !secretSection.contains("TextField(\"邮箱的 IMAP"))

// ── 3. 后端契约：路径/方法/字段名与 mail_api.py 对齐 ────────────
check("读账号列表走 GET /api/mail/accounts", mailCode.contains("\"/api/mail/accounts\""))
check("删除走 DELETE /api/mail/accounts?id=", mailCode.contains("\"/api/mail/accounts?id="))
check("保存走 POST /api/mail/accounts", mailCode.contains("method: \"POST\", body: body(includeSecret: true)"))
check("连通测试走 POST /api/mail/test", mailCode.contains("\"/api/mail/test\""))
check("测试走 POST 且带 45s 超时（IMAP 硬超时 8s+15s，别用默认 10s 掐死）",
      mailCode.contains("timeout: 45"))
// mail_api 的响应约定：异常包在 200 里 → 必须查 ok，不能只看有没有抛错
check("删除查 ok 字段（200+ok:false 是失败）",
      mailCode.contains("guard (d[\"ok\"] as? Bool) ?? false else"))
check("保存查 ok 字段", mailCode.contains("guard (d[\"ok\"] as? Bool) ?? false else"))
check("加载查 ok 字段", mailCode.contains("guard let ok = d[\"ok\"] as? Bool, ok else"))
// 请求体字段名（后端 normalize() 读的键）
for k in ["\"email\"", "\"nickname\"", "\"allow_direct_send\"", "\"default\"", "\"secret\"",
          "\"imap_host\"", "\"imap_port\"", "\"smtp_host\"", "\"smtp_port\""] {
    check("请求体含后端键 \(k)", mailCode.contains(k))
}
// 编辑态必须带 id（后端按 id 判新增/更新）
check("编辑态请求体带 id", mailCode.contains("if let a = account { b[\"id\"] = a.id }"))
// 解析字段名（后端 _public() 的键）
for k in ["imap_host", "imap_port", "imap_security", "smtp_host", "smtp_port",
          "smtp_security", "allow_direct_send", "has_secret", "last_test"] {
    check("解析字段含后端键 \(k)", mailCode.contains(k))
}

// ── 4. 可移除 + 可新增：三条路径都在 ────────────────────────────
check("列表提供删除（swipeActions + 二次确认）",
      mailCode.contains("swipeActions(edge: .trailing)") && mailCode.contains("confirmationDialog"))
check("删除动作调 DELETE", mailCode.contains("method: \"DELETE\""))
check("列表提供新增（右上角 + 按钮）",
      mailCode.contains("Button { editTarget = .add } label: { Image(systemName: \"plus\") }")
      && mailCode.contains("Label(\"添加邮箱账号（推荐）\""))
check("新增/编辑共用一个表单（account: nil = 新增）",
      mailCode.contains("struct MailAccountEditSheet") && mailCode.contains("let account: MailAccountItem?"))

// ── 5. 同一宿主单 sheet 出口（item sheet 必须带 onDismiss 清空） ──
check("编辑/新增 sheet 用 .sheet(item: $editTarget) 且带 onDismiss 清空（否则重开打不开）",
      mailCode.contains(".sheet(item: $editTarget, onDismiss: { editTarget = nil })"))
check("新增/删除都触发刷新", mailCode.contains("if ok { await load() }"))

// ── 6. 危险默认值：默认不允许 AI 直发 ───────────────────────────
let toggleSec = slice(mailCode, "Toggle(\"允许 AI 直接发信\"", "if isEditing {\n                    Section {\n                        Toggle(\"设为默认邮箱\"")
check("直发开关切片取到（防空真）", !toggleSec.isEmpty)
check("直发开关文案写明默认关闭是推荐", toggleSec.contains("关闭（推荐）"))
check("@State allowDirectSend 初值为 false（不预授权）",
      mailCode.contains("@State private var allowDirectSend = false"))

// ── 7. 设置页接线：入口行 + sheet 挂载 ─────────────────────────
check("设置页有「邮件接入」入口行",
      coreSrc.contains("title: \"邮件接入\"") && coreSrc.contains("showMailSettings = true"))
check("入口图标与配色唯一（envelope.fill + .blue，不再造第二个）",
      coreSrc.contains("icon: \"envelope.fill\", iconColor: .blue, title: \"邮件接入\""))
check("sheet 已挂载 MailSettingsSheet", coreSrc.contains("MailSettingsSheet()"))
check("入口行后有分隔线（glassListCard 内行间分隔口径）",
      slice(coreSrc, "title: \"邮件接入\"", "title: \"权限与 AI 操控\"").contains("Divider()"))

// ── 8. 令牌口径：字号走 Typography、间距走 Spacing，不写字面量 ──
check("不写字面字号", !mailCode.contains("font(.system(size: 1") && !mailCode.contains("font(.system(size: 9"))
check("行内间距用 Spacing.lg 而非字面 10", mailCode.contains("HStack(spacing: Spacing.lg)"))
check("圆角用 Radius 令牌", mailCode.contains("cornerRadius: Radius.icon"))

// ── 9. 加载骨架与回执行可见（不静默失败） ──────────────────────
check("有加载骨架", mailCode.contains("LoadingStateView(shape: .rows(2), horizontalPadding: 0)"))
check("有可见回执行行（feedback 被渲染，非只写不读）",
      mailCode.contains("if let f = feedback") && mailCode.contains("Text(f)"))

// ── 10. 单 sheet 宿主护栏（v4.0.x 实锤修复后新增） ────────────────
let mailStrips = stripComments(mailCode)
// 反向变异：把 MailEditTarget 口径回退成两条独立状态 + .sheet(isPresented:)，
// 本节每一条 check 都必须变红，否则护栏是假的。
check("列表页不并存第二条 .sheet(isPresented:)（同宿主只有最后一条 sheet 生效）",
      mailStrips.components(separatedBy: ".sheet(isPresented:").count <= 2)  // 1 = 0 次出现
check("新增/编辑共用一个 sheet 宿主：editTarget 存在且绑定 .sheet(item: $editTarget",
      mailCode.contains("@State private var editTarget: MailEditTarget?")
        && mailCode.contains(".sheet(item: $editTarget, onDismiss:"))
check("新增入口 = .add（不是已删除的 showAdd）",
      occurrences(mailCode, "editTarget = .add") == 2
        && !mailStrips.contains("showAdd"))
check("MailEditTarget 提供 account 访问器供表单取原值",
      mailCode.contains("enum MailEditTarget: Identifiable")
        && mailCode.contains("var account: MailAccountItem?"))

// ── 11. 编辑态自检：已存密文时不该逼用户重填授权码 ──────────────
check("canTest 允许编辑态用已存密文测连接（后端空 secret 回落已存值）",
      mailCode.contains("(!secret.isEmpty || (isEditing && (account?.hasSecret ?? false)))"))
check("保存成功后关闭表单（父层 onDone 只刷列表，不关 sheet）",
      mailCode.contains("if ok { dismiss() }"))

// ── 结果 ───────────────────────────────────────────────────────
print("pass=\(passCount) fail=\(failCount)")
if failCount > 0 { exit(1) }
print("✅ 邮件接入设置页真值表全绿")
