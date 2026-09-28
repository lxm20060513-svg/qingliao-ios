// MARK: - v4.0.x 网盘接入 · 真值表（位置口径 + 安全边界 + 后端契约 + 接线 + 护栏）
//
// 背景：网盘接入走后端 clouddrive_api（装官方 skill 包 + 授权码 → 调网盘 CLI），
// App 端只做「接入管理 + 文件浏览」两件事。
// 这张表盯四类「本地预检查不出、出了就功能全废或违背用户口径」的东西：
//   ① 位置口径：用户明确要求「网盘接入放设置里，不放连接器卡片」→ 连接器面板不得出现网盘
//   ② 安全边界：技能地址/授权码明文绝不落 App、列表绝不回显
//   ③ 后端契约：路径/方法/字段名与 clouddrive_api.py 严格对齐（写错 = 静默 200+ok:false）
//   ④ 浏览页护栏：fid 栈（网盘无路径概念）、蜂窝大文件闸、失败可见不静默
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

/// 去掉 `//` 与 `/* */` 注释，只留代码文本
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

let setSrc = src("qingliao/Features/Settings/CloudDriveSettingsSheet.swift")
let setCode = stripComments(setSrc)
let browSrc = src("qingliao/Features/Settings/CloudDriveBrowserSheet.swift")
let browCode = stripComments(browSrc)
let coreSrc = stripComments(src("qingliao/Features/Settings/SettingsCore.swift"))
let connSrc = stripComments(src("qingliao/Features/Dashboard/ConnectorPanelSheet.swift"))

// ── 1. 源可读（空了后面全是空真） ─────────────────────────────
check("CloudDriveSettingsSheet.swift 源可读", !setSrc.isEmpty)
check("CloudDriveBrowserSheet.swift 源可读", !browSrc.isEmpty)
check("SettingsCore.swift 源可读", !coreSrc.isEmpty)
check("ConnectorPanelSheet.swift 源可读", !connSrc.isEmpty)

// ── 2. 位置口径（用户明确要求）：网盘在设置，不在连接器卡片 ──────
check("设置里有「网盘接入」入口行",
      coreSrc.contains("title: \"网盘接入\"") && coreSrc.contains("showCloudDrive = true"))
check("入口图标与配色唯一（externaldrive.fill + .teal）",
      coreSrc.contains("icon: \"externaldrive.fill\", iconColor: .teal, title: \"网盘接入\""))
check("连接器面板不含网盘（用户纠正过位置，别塞回去）",
      !connSrc.contains("网盘") && !connSrc.contains("云盘") && !connSrc.contains("externaldrive"))
check("连接器面板仍只有三类（MCP / 智能家居 / 生活卡片）",
      connSrc.contains("mcpCard") && connSrc.contains("smartHomeCard") && connSrc.contains("lifeCardsCard"))

// ── 3. 安全边界：技能地址/授权码明文不落 App、不回显 ────────────
check("没有 @AppStorage 存授权码", !setCode.contains("@AppStorage"))
check("没有 UserDefaults / Keychain 落盘授权码",
      !setCode.contains("UserDefaults") && !setCode.contains("KeychainHelper"))
check("授权码输入用 SecureField（不是明文 TextField）",
      setCode.contains("SecureField(\"网盘授权码") && !setCode.contains("TextField(\"网盘授权码"))
// 列表行的副标题只能用 nickname/status/error，绝不能拼授权码
let rowFn = slice(setCode, "private func row(", "private func displayName(")
check("列表行切片非空（防空真）", !rowFn.isEmpty)
check("列表行不出现授权码变量", !rowFn.contains("authCode") && !rowFn.contains("skillURL"))
let subtitleFn = slice(setCode, "private func subtitle(", "private func subtitleColor(")
check("副标题切片非空（防空真）", !subtitleFn.isEmpty)
check("副标题只读 nickname/status/error",
      subtitleFn.contains("d.nickname") && subtitleFn.contains("d.isReady") && !subtitleFn.contains("authCode"))

// ── 4. 后端契约：路径/方法/字段名与 clouddrive_api.py 对齐 ───────
check("列表走 GET /api/clouddrive/drives", setCode.contains("\"/api/clouddrive/drives\""))
check("解绑走 POST /api/clouddrive/remove",
      setCode.contains("\"/api/clouddrive/remove\", method: \"POST\", body: [\"id\": d.id]"))
check("接入走 POST /api/clouddrive/add",
      setCode.contains("\"/api/clouddrive/add\", method: \"POST\""))
check("浏览列表走 /api/clouddrive/list 且带 drive+fid",
      browCode.contains("\"/api/clouddrive/list?drive=") && browCode.contains("&fid="))
check("下载走 /api/clouddrive/download 且带 drive+fid+name",
      browCode.contains("\"/api/clouddrive/download?drive=")
      && browCode.contains("&fid=") && browCode.contains("&name="))
// 后端 _do_add 读的键
check("请求体含后端键 skill_url", setCode.contains("\"skill_url\""))
check("请求体含后端键 auth_code", setCode.contains("\"auth_code\""))
// 后端 _drives_payload 的键
for k in ["\"drives\"", "\"nickname\"", "\"status\"", "\"error\"", "\"added_at\""] {
    check("解析含后端键 \(k)", setCode.contains(k))
}
// 后端 _do_list 的键
for k in ["\"entries\"", "\"is_dir\"", "\"mtime\"", "\"fid\""] {
    check("浏览页解析含后端键 \(k)", browCode.contains(k))
}
// 后端异常都包在 200 里 → 必须查 ok，不能只看有没有抛错
check("加载查 ok 字段（200+ok:false 是失败）",
      setCode.contains("guard let ok = d[\"ok\"] as? Bool, ok else"))
check("解绑查 ok 字段", setCode.contains("guard (j[\"ok\"] as? Bool) ?? false else"))
check("接入查 ok 字段", setCode.contains("if (j[\"ok\"] as? Bool) == true"))
check("浏览页列表查 ok 字段", browCode.contains("guard let ok = d[\"ok\"] as? Bool, ok else"))

// ── 5. 技能地址校验（错地址会让后端白跑一次安装） ──────────────
// 注意：stripComments 会把 "https://" 里的 // 当行注释起点，把后半行整段吃掉
// → 含 https:// 的断言必须查**原始源**，且与 hasSuffix 同处一行时要查原始源
check("技能地址校验 https + .zip",
      setSrc.contains("hasPrefix(\"https://\") && u.hasSuffix(\".zip\")"))
check("地址非法时给可见提示",
      setCode.contains("技能地址必须是 https 开头的 .zip 链接"))
check("空地址/空授权码不允许提交（canSave）",
      setCode.contains("private var canSave: Bool") && setCode.contains("!saving"))

// ── 6. 可解绑 + 可新增：三条路径都在 ───────────────────────────
check("列表提供解绑（swipeActions + 二次确认）",
      setCode.contains("swipeActions(edge: .trailing)") && setCode.contains("confirmationDialog"))
check("解绑文案说清是解绑不是删文件", setCode.contains("解绑网盘？"))
check("列表提供新增（右上角 + 与底部按钮两处）",
      setCode.contains("Button { showAdd = true } label: { Image(systemName: \"plus\") }")
      && setCode.contains("Label(\"接入网盘（推荐）\""))
// 接入是长耗时动作：必须给进行中态，别让用户以为点了没反应
check("接入有进行中态（saving + ProgressView）",
      setCode.contains("@State private var saving = false")
      && setCode.contains("ProgressView()") && setCode.contains("if saving {")
      && setCode.contains(".disabled(!canSave)"))
check("接入表单文案写明耗时", setCode.contains("可能需要 10～60 秒"))

// ── 7. 浏览页护栏：fid 栈（网盘只有 fid，不能拼路径） ───────────
check("浏览页用 fid 栈而非路径串",
      browCode.contains("@State private var stack: [String] = [\"0\"]")
      && browCode.contains("stack.append(e.fid)") && browCode.contains("stack.removeLast()"))
check("根目录 fid 固定 0", browCode.contains("private var currentFid: String { stack.last ?? \"0\" }"))
check("根目录不显示「返回上级」", browCode.contains("private var canGoUp: Bool { stack.count > 1 }"))
check("list 请求用 URL 编码（文件名/fid 可能含特殊字符）",
      browCode.contains("RemoteFiles.queryEncoded(drive.id)")
      && browCode.contains("RemoteFiles.queryEncoded(fid)")
      && browCode.contains("RemoteFiles.queryEncoded(e.name)"))

// ── 8. 蜂窝大文件闸（relay 受限会「点了没反应」） ───────────────
check("预览有蜂窝体积闸", browCode.contains("RemoteFiles.cellularDownloadAllowed(bytes: e.size)"))
check("分享有蜂窝体积闸", browCode.contains("alertText = \"蜂窝网络下大文件下载受限"))
check("下载失败带 HTTP 状态与网络类型",
      browCode.contains("下载失败（HTTP \\(code)）") && browCode.contains("蜂窝网络受限，建议连 WiFi 重试"))

// ── 9. 失败可见不静默（本仓刚因静默 return 被用户报「功能坏了」） ──
check("列表失败给整块错误态 + 重试",
      browCode.contains("ErrorStateView(title: \"加载失败\""))
check("刷新失败不覆盖已加载列表，只挂可重试提示",
      browCode.contains("refreshFailedNotice") && browCode.contains("加载中…"))
check("加载代际守卫（晚到的旧请求结论丢弃）",
      browCode.contains("let seq = loadSeq + 1") && browCode.contains("guard loadSeq == seq else { return }"))
check("下载失败弹可见 alert", browCode.contains("alertText = \"下载失败"))
check("有可见回执行行（feedback 被渲染，非只写不读）",
      setCode.contains("if let f = feedback") && setCode.contains("Text(f)"))

// ── 10. 落盘预览安全（QuickLook 只吃本地文件） ──────────────────
check("下载后写本地临时文件再预览", browCode.contains("writeTemp(data, name: e.name)"))
check("临时文件名走净化（防网盘下发名字带路径分隔符）",
      browCode.contains("RemoteFiles.safeLocalName(name)"))
check("不支持的格式给出可行动提示（只能分享），不静默返回",
      browCode.contains("暂不支持 App 内预览") && browCode.contains("RemoteFiles.ext(e.name)"))
check("图片走 App 内查看器，其余 QuickLook",
      browCode.contains("ImageViewPayload(images: [img], index: 0)")
      && browCode.contains("quickLookURL = url"))

// ── 11. 令牌口径：字号走 Typography、间距走 Spacing ────────────
check("不写字面字号",
      !setCode.contains("font(.system(size: 1") && !setCode.contains("font(.system(size: 9")
      && !browCode.contains("font(.system(size: 1") && !browCode.contains("font(.system(size: 9"))
check("圆角用 Radius 令牌",
      setCode.contains("cornerRadius: Radius.icon") && browCode.contains("cornerRadius: Radius.icon"))
check("列表分隔线缩进走令牌", browCode.contains("Spacing.rowDividerInset"))

// ── 12. 设置页接线完整性 ───────────────────────────────────────
check("状态声明存在", coreSrc.contains("@State var showCloudDrive = false"))
check("sheet 已挂载 CloudDriveSettingsSheet", coreSrc.contains("CloudDriveSettingsSheet()"))
check("入口行后有分隔线（glassListCard 内行间分隔口径）",
      slice(coreSrc, "title: \"网盘接入\"", "title: \"权限与 AI 操控\"").contains("Divider()"))
check("浏览页入口挂在网盘列表行上（点行进浏览）",
      setCode.contains(".onTapGesture { browsingDrive = d }")
      // 钉语义不钉字面：sheet(item:) 允许带 onDismiss 复位参数，关键是 item 挂载 + onDismiss 复位都在
      && setCode.contains(".sheet(item: $browsingDrive")
      && setCode.contains("onDismiss: { browsingDrive = nil }")
      && setCode.contains("CloudDriveBrowserSheet(drive: d)"))

// ── 结果 ───────────────────────────────────────────────────────
print("pass=\(passCount) fail=\(failCount)")
if failCount > 0 { exit(1) }
print("✅ 网盘接入真值表全绿")
