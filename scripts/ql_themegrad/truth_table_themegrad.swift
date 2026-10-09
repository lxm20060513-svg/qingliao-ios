// MARK: - v4.0.67 主题淡彩迁移真值表（A+C 定稿：页底环境渐变铺全站 + 卡片口径统一 pastelCard）
//
// 背景：用户从三方向对比稿拍板「A+C 组合」后，按 P1→P5 分批落地：
//   · P1（v4.0.66 已发）聊天页：用户气泡/发送键/添加胶囊换蓝紫渐变，AI 气泡换淡彩渐变卡，页底接环境渐变；
//   · P2 会话列表：列表卡换 pastelCard，页底接环境渐变；
//   · P3 生活页：各 section 卡换 pastelCard（统一走 LifeSectionScaffold 一处），页底接环境渐变；
//   · P4 设置页：列表行批量换 pastelCard，页底接环境渐变；
//   · P5 零散浮层：大爆炸/语音对话换底成主题环境渐变，分享扩展主色对齐主题蓝紫。
//
// 本表钉四件事（每件都是「改一处漏一处」型漂移）：
//   ① 页底单源：全站页底只走 `EnvironmentGlowLayers` 一层，浅深色各一套取值在 Theme/EnvironmentGradient.swift。
//      谁再手刷 `Color(.systemBackground)` / 实色白底，光晕就被盖死 → 负断言。
//   ② 卡口径单源：彩底上的卡一律 `pastelCard()`（Theme/LiquidGlass.swift 一处定义），
//      旧玻璃口径 `dashboardCard()` / `glassListCard()` 在生活页/设置页目录里清零（玻璃压在彩底上发灰）。
//   ③ P5 换底不误伤：大爆炸/语音页底色换掉，但语音页 accent 柔光（v3.9.77 拍板「科幻感」）必须留着。
//   ④ 分享扩展主色与主题主色同值（扩展编不到 Theme，只能字面写 → 最容易漂移的一处）。
//
// 反向自证（2026-10-06 在本版实跑，每次只动一处、跑完即还原并校验 sha256 一致）：
//   ① 生活页页底行 `EnvironmentGlowLayers` → 改名 → **48/2 红**（页底挂渐变 + 只铺一层，两处相互独立）；
//   ② 设置页有一处 `.pastelCard(` → 改回 `.dashboardCard(` → **49/1 红**（目录旧玻璃口径清零）；
//   ③ 大爆炸在渐变底前加回 `.ultraThinMaterial` 一行 → **49/1 红**（旧磨砂底清零）；
//   ④ 分享扩展 accent 改回 `0.36, 0.62, 1.0` → **48/2 红**（主色对齐 + 旧散装蓝清零）；
//   ⑤ 生活数据卡里**代码处**（注释里那句不算，注释被剥）一处 `.pastelCard()` 改回 `.dashboardCard()`
//      → **58/1 红**（③b 旧玻璃口径清零）；
//   ⑥ 发送键 `userBubbleColors(scheme)` 改回 `[.blue, .indigo]` → ③c 两条判红。
//   （四条都实测「只红本项」，无空真、无连带假红。）

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
/// 去注释行：负断言必须走它 —— 本仓注释习惯「写清旧形态」，不剥必然假红（已踩多次）
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}
func occ(_ s: String, _ needle: String) -> Int {
    s.components(separatedBy: needle).count - 1
}

// MARK: - ① 页底单源：五个主页面各挂一层环境渐变
//   v4.0.71：补**看板页**（用户 2026-10-07「各个 tab 的渐变背景渲染还有问题」——看板是唯一漏迁的 tab）。
//   第三列 = 该文件自己的 colorScheme 环境变量名：DashboardView 历史上用 `scheme`（v3.0.9 就有的同名量），
//   其余四页统一 `colorSchemeEnv` —— 别为了整齐去改 DashboardView 的量名（会连带 20+ 处调用点）。
let pageFiles: [(String, String, String)] = [
    ("聊天页", "qingliao/Features/Chat/ChatView.swift", "colorSchemeEnv"),
    ("会话页", "qingliao/Features/Sessions/SessionsView.swift", "colorSchemeEnv"),
    ("生活页", "qingliao/Features/Life/LifeView.swift", "colorSchemeEnv"),
    ("设置页", "qingliao/Features/Settings/SettingsCore.swift", "colorSchemeEnv"),
    ("看板页", "qingliao/Features/Dashboard/DashboardView.swift", "scheme"),
]
for (name, path, envVar) in pageFiles {
    let raw = src(path)
    check("\(name)源可读（空了下面两条是空真）", !raw.isEmpty)
    let code = stripCommentLines(raw)
    check("① \(name)页底挂主题环境渐变",
          code.contains(".background(EnvironmentGlowLayers(scheme: \(envVar)))"))
    // 负断言：旧「手刷系统底/白底」会把光晕压死（P1 铺底时同类坑）
    check("① \(name)不再手刷系统底/白底（会盖住光晕）",
          !code.contains("Color(.systemBackground)") && !code.contains(".background(Color.white"))
}
// 页底只铺一层：叠两层 = 光晕浓度翻倍（浅色下会发灰）
check("① 页底只挂一层（每页 EnvironmentGlowLayers 恰 1 处）",
      pageFiles.allSatisfy { occ(stripCommentLines(src($0.1)), "EnvironmentGlowLayers(scheme:") == 1 })

// MARK: - ② P5 全屏浮层换底（大爆炸 / 语音对话）
let bbRaw = src("qingliao/Features/BigBang/BigBangView.swift")
let bb = stripCommentLines(bbRaw)
check("② 大爆炸源可读", !bbRaw.isEmpty)
check("② 大爆炸全屏底 = 主题环境渐变", bb.contains("EnvironmentGlowLayers(scheme: scheme)"))
check("② 大爆炸旧磨砂底清零（v4.0.67 P5 换底，回潮即红）",
      !bb.contains("Rectangle().fill(.ultraThinMaterial)"))
// 换底不许误伤底部条口径（v3.9.77 拍板：5 颗胶囊同尺寸同色调）
check("② 大爆炸底部条仍是 5 颗同款胶囊（换底不误伤）",
      occ(stripCommentLines(bbRaw), ".pill(.topBar, tone: .neutral)") == 5)

let voiceRaw = src("qingliao/Features/VoiceDialogView.swift")
let voice = stripCommentLines(voiceRaw)
check("② 语音页源可读", !voiceRaw.isEmpty)
check("② 语音页底色 = 主题环境渐变", voice.contains("EnvironmentGlowLayers(scheme: colorScheme)"))
check("② 语音页旧系统底清零（v4.0.67 P5 换底）", !voice.contains("Color(.systemBackground)"))
check("② 语音页 accent 柔光保留（v3.9.77 拍板「科幻感」，换底不许带走）",
      voice.contains("Color.accentColor.opacity(isDark ? 0.22 : 0.14)"))
check("② 语音页仍按主题分档（不再写死深色环境）",
      !voice.contains(".environment(\\.colorScheme, .dark)"))

// MARK: - ③ 卡口径单源：彩底上的卡一律 pastelCard
let pastelClean = stripCommentLines(src("qingliao/Theme/LiquidGlass.swift"))
check("③ pastelCard 定义在 Theme/LiquidGlass.swift（单源）",
      pastelClean.contains("func pastelCard(cornerRadius: CGFloat = Radius.card)"))
// 🚨 原写法只扫 LifeView 一个文件（标题却写「Features 下」= 覆盖面被夸大）→ 真扫全目录。
var dupPastelCard = ""
if let en = FileManager.default.enumerator(atPath: "qingliao/Features") {
    for case let rel as String in en where rel.hasSuffix(".swift") {
        let code = stripCommentLines(src("qingliao/Features/\(rel)"))
        if code.contains("func pastelCard") { dupPastelCard += "\(rel) " }
    }
}
check("③ Features 下不许另立一套 pastelCard（单源扫描全目录；重定义处：\(dupPastelCard)）",
      dupPastelCard.isEmpty)

// 生活页 / 设置页：旧玻璃卡口径清零（玻璃压在彩底上发灰 = 用户当初让换 A 卡的原因）
for dir in ["qingliao/Features/Life", "qingliao/Features/Settings"] {
    var old = ""
    let fm = FileManager.default
    let files = (try? fm.contentsOfDirectory(atPath: dir))?.filter { $0.hasSuffix(".swift") } ?? []
    for f in files {
        let code = stripCommentLines(src("\(dir)/\(f)"))
        if code.contains(".dashboardCard(") || code.contains(".glassListCard(") { old += "\(f) " }
    }
    let label = dir.contains("Life") ? "生活页" : "设置页"
    check("③ \(label)目录旧玻璃卡口径清零（残留：\(old)）", old.isEmpty)
}

// 本批迁移的 section / 行文件各自确实走了 pastelCard（防「只改 scaffold、各 section 漏」）
let pastelCallers = [
    "qingliao/Features/Life/LifeSectionScaffold.swift",
    "qingliao/Features/Life/LifeView.swift",
    "qingliao/Features/Life/GoalsSection.swift",
    "qingliao/Features/Life/HabitSection.swift",
    "qingliao/Features/Life/MemoSection.swift",
    "qingliao/Features/Life/TodoSection.swift",
    "qingliao/Features/Life/RecordSection.swift",
    "qingliao/Features/Life/RecordReportSheet.swift",
    "qingliao/Features/Settings/SettingsCore.swift",
    "qingliao/Features/Settings/SettingsData.swift",
    "qingliao/Features/Settings/SettingsSystem.swift",
    "qingliao/Features/Settings/SettingsSearch.swift",
    "qingliao/Features/Settings/SettingsAccess.swift",
    "qingliao/Features/Settings/SettingsLifeCards.swift",
    "qingliao/Features/Settings/SettingsProactive.swift",
    "qingliao/Features/Settings/BackendUpdate.swift",
    "qingliao/Features/Settings/CloudDriveBrowserSheet.swift",
]
for path in pastelCallers {
    let raw = src(path)
    check("③ \(path.split(separator: "/").last!) 走 pastelCard",
          !raw.isEmpty && stripCommentLines(raw).contains(".pastelCard("))
}

// MARK: - ③b 生活数据 / 快递价格卡（同一页的生活卡，别落下）
// 生活页里除了各 section，还渲染「生活数据」股票·资讯·快递 section（Features/Dashboard/LifeCardsSection.swift）
// 与快递价格卡（LifeExpressPriceCards.swift）——用户口径「生活卡换淡彩渐变底」覆盖它们；
// 漏掉就会出现「同一页一半淡彩卡、一半玻璃卡」（2026-10-06 只读审查发现，同批已补）。
for (name, path) in [("生活数据卡", "qingliao/Features/Dashboard/LifeCardsSection.swift"),
                     ("快递价格卡", "qingliao/Features/Dashboard/LifeExpressPriceCards.swift")] {
    let raw = src(path)
    check("③b \(name)源可读", !raw.isEmpty)
    let code = stripCommentLines(raw)
    check("③b \(name)走 pastelCard（与同页其它生活卡同底）", code.contains(".pastelCard("))
    check("③b \(name)旧玻璃口径清零（dashboardCard / glassListCard）",
          !code.contains(".dashboardCard(") && !code.contains(".glassListCard("))
}

// MARK: - ③c 发送键有字态主交互色（全站主色单出口）
// 发送键三态里「有字」那态必须取 userBubbleColors（与用户气泡同源）；写回字面 .blue/.indigo 即漂移。
let inputBarCode = stripCommentLines(src("qingliao/Features/Chat/ChatInputBar.swift"))
check("③c 发送键有字态 = EnvironmentGradient.userBubbleColors(scheme)",
      inputBarCode.contains("return EnvironmentGradient.userBubbleColors(scheme)"))
check("③c 发送键不再写回字面蓝（[.blue, .indigo]）",
      !inputBarCode.contains("[.blue, .indigo]"))

// MARK: - ④ 分享扩展主色对齐主题（扩展 target 编不到 Theme，颜色只能字面写 → 最易漂移）
let shareSrc = src("qingliaoShare/ShareComposeView.swift")
check("④ 分享页源可读", !shareSrc.isEmpty)
check("④ 分享扩展主色 = 主题蓝紫亮色首档 #4DA3FF（与 userBubbleColors(.light) 首色同值）",
      shareSrc.contains("Color(red: 0x4D / 255, green: 0xA3 / 255, blue: 0xFF / 255)"))
check("④ 旧的散装蓝已清零（0.36/0.62/1.0）",
      !stripCommentLines(shareSrc).contains("green: 0.62, blue: 1.0"))

// MARK: - ⑤ 主题取值单源（页底光晕与卡面底色值不许就地手改）
let themeSrc = src("qingliao/Theme/EnvironmentGradient.swift")
check("⑤ 主题源可读", !themeSrc.isEmpty)
// v4.0.81 方案3：卡底口径整块换玻璃面（cardGlassFill）。断言**意图不变** —— 深色卡面必须是
// 「专门调过的暗调色」，不是把浅色白面掉透明度糊上去；只把取值跟到新真源（dark = 30/30/40 @0.62）。
check("⑤ 深色卡面走专门暗调（不是简单调透明度；cardGlassFill dark = 30/30/40 @0.62）",
      themeSrc.contains("Color(red: 30 / 255, green: 30 / 255, blue: 40 / 255).opacity(0.62)"))
check("⑤ 页底三团光晕齐（桃粉/天蓝/薄荷各一团）",
      occ(themeSrc, "GlowBlob(tint:") == 3)
// 🚨 原写法 `!themeSrc.contains("opacity: 0.4")` 是弱断言（把 0.38 改成 0.42/0.55/0.9 照样绿）。
//    改成真的解析：扫**代码行**（剥注释）里所有含 opacity 的小数字面量（三团光晕写成
//    `opacity: scheme == .dark ? 0.35 : 0.38,`，一行两值），逐个判 ≤ 0.38。
//    ⚠️ 只取「opacity」**之后**那段（不是整行）：`Color(red: 0.42, green: 0.36, blue: 0.72).opacity(0.10)`
//    整行取数会把配色分量 0.72 当成透明度（实测踩过：报「最大值 0.72」的假红）。
// 🚨 v4.0.81 方案3 再修一次**范围**：红线本意只管**页底光晕**（它直接压在正文底下，浓了毁对比度）。
//    卡面叠层/顶部高光/柔影是压在**卡内**的（30/30/40@0.62、白@0.95、黑@0.60），不归这条管；
//    旧全文件扫描会把它们连同 `(Color.black.opacity(0.60), 22, 8)` 里的 radius 22 一起当成透明度
//    → 报「实测最大值 22.0」的假红。口径：只取 `opacity: scheme == .dark ? X : Y` 形态的行（= 三团光晕）。
let glowLines = stripCommentLines(themeSrc).split(separator: "\n")
    .filter { $0.contains("opacity:") && $0.contains("scheme == .dark") }
    .map(String.init)
check("⑤ 光晕透明度行恰好 3 条（空了=空真，多捞=把卡面/影算进来了）", glowLines.count == 3)
let glowOpacityVals: [Double] = glowLines.flatMap { line -> [Double] in
    let tail = line.components(separatedBy: "opacity:").dropFirst().joined(separator: "")
    var vals: [Double] = []; var cur = ""
    for ch in tail {
        if ch.isNumber || ch == "." { cur.append(ch) }
        else { if let d = Double(cur) { vals.append(d) }; cur = "" }
    }
    if let d = Double(cur) { vals.append(d) }
    return vals
}
check("⑤ 光晕透明度取值解析到了（空了下面就是空真）", !glowOpacityVals.isEmpty)
check("⑤ 每处光晕透明度都不超 0.38（正文对比度红线；实测最大值 \(glowOpacityVals.max() ?? -1)）",
      (glowOpacityVals.max() ?? 1) <= 0.38)
// MARK: - ⑥ v4.0.68 设置区「纯白面」清零（用户 2026-10-07：「设置页又有白底又有渐变底，不协调」）
//   口径：设置页（Features/Settings 全目录）不许再有**纯白填充面**——
//   `secondarySystemGroupedBackground`（分组白：搜索框/形象卡/输入框/列表行底）与
//   `Color(uiColor: .systemBackground)`（系统白：页内块底）一并清零。
//   统一出口：`pastelFill(cornerRadius:)`（v4.0.81 方案3 起 = 同一份玻璃真源 `GlassEdgeSurface`
//   + 1pt 渐变厚边、不带投影；见 LiquidGlass）。
//   ⚠️ 不误伤 `Color.white`：那是**前景色**（图标/文字画在彩色底上），本表按 token 判。
let settingsDir = "qingliao/Features/Settings/"
let settingsNames = (try? FileManager.default.contentsOfDirectory(atPath: settingsDir)) ?? []
check("⑥ 设置目录可枚举（空了下面就是空真）", settingsNames.count >= 5)
var whiteFills: [String] = []
var pastelFillCalls = 0
for name in settingsNames where name.hasSuffix(".swift") {
    let code = stripCommentLines(src(settingsDir + name))
    if code.contains("secondarySystemGroupedBackground") { whiteFills.append(name + " · 分组白") }
    if code.contains("Color(uiColor: .systemBackground)") { whiteFills.append(name + " · 系统白") }
    pastelFillCalls += occ(code, ".pastelFill(")
}
check("⑥ 设置区纯白填充面清零（实得 \(whiteFills.count) 处：\(whiteFills.isEmpty ? "0" : whiteFills.joined(separator: "、"))）",
      whiteFills.isEmpty)

// 正向：统一出口在位 + 真有调用点（否则「清零」可以靠删功能达成）
let lg68 = src("qingliao/Theme/LiquidGlass.swift")
check("⑥ pastelFill 出口在 Theme（淡彩填充·不带投影）",
      lg68.contains("func pastelFill(cornerRadius: CGFloat, stroke: Bool = true)"))
check("⑥ PastelFill 实现带描边开关（压在同色卡面上，只换底不描边会糊掉边界）",
      lg68.contains("struct PastelFill: ViewModifier")
      && lg68.contains("fill: true, edge: stroke, shadow: false")
      && lg68.contains("if edge {"))
check("⑥ 设置区 pastelFill 调用点 ≥ 20（实得 \(pastelFillCalls)）", pastelFillCalls >= 20)

// 反向：SettingRow（共用行组件）自己不再涂料——外层已是 pastelCard，行再涂白就是那块「白底」。
//   ⚠️ 不能笼统断言「SettingRow 体内无 .background(」：行内图标片/toggle 有自己的**彩色**底，
//   那是前景装饰、不是行底。所以这里钉两件事：① 行底那层分组白在 SettingRow 段内零命中；
//   ② 正向——行容器（Section 卡）确实还是 pastelCard 在供底。
let srCode = stripCommentLines(src(settingsDir + "SettingsCommon.swift"))
if let r = srCode.range(of: "struct SettingRow") {
    let body = String(srCode[r.lowerBound...]).components(separatedBy: "\nstruct ").first ?? ""
    check("⑥ SettingRow 切片取到（防空真）", body.contains("var body: some View"))
    check("⑥ SettingRow 段内不再有分组白（行底交给外层 pastelCard）",
          !body.contains("secondarySystemGroupedBackground") && !body.contains("Color(uiColor: .systemBackground)"))
} else {
    check("⑥ SettingRow 切片取到（防空真）", false)
}
let sysCode = stripCommentLines(src(settingsDir + "SettingsSystem.swift"))
check("⑥ 行容器（设备与版本 Section）仍由 pastelCard 供底", sysCode.contains(".pastelCard()"))

// MARK: - ⑦ v4.0.68（审查教训）：**变量作用域**级断言
//   本批真出过 2 处阻断级编译错误：`EnvironmentGradient.pastelCardStyle(scheme)` 用了 scheme，
//   但所在 struct（SettingsSearchBar / FlowText）**没有** `@Environment(\.colorScheme)` 声明
//   —— 而本机预检只有 `-parse`，88 张表照旧全绿，结果会把编不过的包放行到 CI。
//   口径：**谁用 scheme，谁那一段（最近的 struct 声明起）里就得声明它**（兄弟 struct 不算，
//   函数形参不算——形参会把 scheme 写进签名，本表按 `(scheme)` 用法扫，故不受影响）。
var scopeMiss: [String] = []
var scopeFiles: [(String, String)] = settingsNames.filter { $0.hasSuffix(".swift") }.map { ($0, settingsDir + $0) }
scopeFiles.append(("SessionsView.swift", "qingliao/Features/Sessions/SessionsView.swift"))
for (name, path) in scopeFiles {
    let code = stripCommentLines(src(path))
    var curStruct = "<顶层>"
    var declared = false
    for line in code.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("struct ") || t.hasPrefix("private struct ") || t.hasPrefix("public struct ") {
            curStruct = String(t.split(separator: "{")[0]).trimmingCharacters(in: .whitespaces)
            declared = false
        }
        if line.contains("@Environment(\\.colorScheme)") { declared = true }
        if line.contains("(scheme)") && !declared { scopeMiss.append("\(name)#\(curStruct)") }
    }
}
check("⑦ 用 (scheme) 的每个 struct 都自己声明了 @Environment(\\.colorScheme)（实得：\(scopeMiss.isEmpty ? "0 处" : scopeMiss.joined(separator: ", "))）",
      scopeMiss.isEmpty)
check("⑦ 本表真的扫到了用法（防空真：以上断言不能因为一条都没扫到而恒绿）",
      scopeFiles.count >= 8 && src(settingsDir + "SettingsAgent.swift").contains("(scheme)"))

// MARK: - ⑧ v4.0.71：页底「铺满屏幕」三条护栏
//   用户 2026-10-07 真机反馈「各个 tab 的渐变背景渲染还有问题」= 三个独立成因，各配一条负断言：
//   a) 聊天页入场裁剪把**半径 0 的圆角矩形**当「不裁」用，其实照样按页框裁 → 页底溢出安全区那
//      59pt/34pt 被切掉 = 顶部常驻白条（其余四页没这层裁剪，同款页底能铺满）；
//   b) 页底与屏幕严格同大 → 任何「整页缩放/位移」的过渡（切页 scale 0.96 + 下移 10pt）都会掀开
//      边角露出窗口白底 = 「先白底再填渐变」的几何部分；
//   c) 整页淡入起手过透（0.35 / 0.12）→ 页底跟着一起透明，等于把白底透出来 = 同症状的浓淡部分。
//   三条都只钉「形态」，不钉具体数值（8% / 0.9 这类可调参不进断言，调参不该报红）。
let dockSrc = stripCommentLines(src("qingliao/Features/DockTabView.swift"))
check("⑧a 聊天页「从会话卡展开」机制已整体移除（v4.0.72 拍板；裁剪壳会切掉页底溢出安全区那段）",
      !dockSrc.contains("ZoomEntryClip") && !dockSrc.contains("clipShape(radius:"))
// ⑧b 三条**必须成组看**（v4.0.71 首版只有「放大 + 平移」两条 → 把「画布没重新居中」的错实现判成绿：
//     实测那样三团光团整体偏移 ≈2×overscan ≈16% 屏宽、右上桃粉直接出屏。发版前审查抓到，补第 2 条。
//     归一化：剥注释 + 去掉空白，免得被缩进/换行/说明性注释喂饱（同文件别处用的 themeSrc 没剥注释）。
let themeFlat = stripCommentLines(themeSrc)
    .replacingOccurrences(of: " ", with: "")
    .replacingOccurrences(of: "\n", with: "")
check("⑧b 页底画布真的放大了（frame 用 W/H，不再与屏幕严格等大）",
      themeFlat.contains(".frame(width:W,height:H)")
      && !themeFlat.contains(".frame(width:w,height:h)"))
check("⑧b 放大后的画布**重新居中**到窗口（漏它 = 三团光团整体偏移 ≈16% 屏宽）",
      themeFlat.contains(".offset(x:-ox,y:-oy)") || themeFlat.contains(".position(x:w/2,y:h/2)"))
check("⑧b 光团几何仍锚在屏幕坐标（3 团各带一次 ox/oy 平移；须与上一条成对才成立）",
      occ(themeFlat, "+ox") == 3 && occ(themeFlat, "+oy") == 3)
// v4.0.73（方案 A）：切页入场改为**内容原地淡入** `.opacity(phase)`（页底渐变常驻不动 = 静态垫底渐变托底），
// 旧的低起点整页淡入（0.35/0.9/0.12）仍全部禁回——那才是「透白」根源；新淡入透出的是同款渐变。
let cntOpacity = dockSrc.components(separatedBy: ".opacity(phase)").count - 1
check("⑧c 切页/聊天页入场 = 原地淡入（.opacity(phase) 两处各一份）", cntOpacity >= 2)
// v4.0.78（用户 2026-10-08「4.0.77 dock 栏 tap 切换太闪了，改为平滑过渡切换效果」，二选一取「柔滑滑入」）：
// 旧形态两处病史：① 起点 phase = 0（全透明）→ 内容先整个消失再出现 = 「闪」的正源；
// ② opacity 走 snap(0.20)、位移走 flow(0.28) 两条曲线不同步，叠在同一帧像抖了一下。
// **v4.0.85（用户 2026-10-09「整个 app 各个页面切换还是太生硬了」「一点动画都没有」）**：0.78 那套
//（起点 0.6 / 位移 22pt / flow 0.28s）真机观感 ≈ 硬切 → 起点 **0.75**、位移 **60pt**（Motion.pageSlideShift）、
// 曲线换 **Motion.pageSlide**（0.38 弹簧轻过冲）。下面几条钉**现行**形态，并把 0.78 那套一并反向钉死
//（否则「悄悄退回旧口径」两头都不红）。shell 侧同一口径另有一份：check_swift.sh「回退⑯ / ⑯f / ⑯g / ⑯h」组。
check("⑧c 入场 = 单曲线柔滑（opacity 与位移同一个 Motion.pageSlide 事务，两处各一份）",
      dockSrc.components(separatedBy: "withAnimation(Motion.pageSlide) { phase = 1; dx = 0 }").count - 1 >= 2
      && !dockSrc.contains("withAnimation(Motion.snap) { phase = 1 }")
      && !dockSrc.contains("withAnimation(Motion.flow) { phase = 1; dx = 0 }")
      && !dockSrc.contains("withAnimation(Motion.flow) { dx = 0 }"))
check("⑧c 入场起点 0.75（不许回 0 全透明起跳，也不许退回 0.6），TabTransition 与聊天页两处一致",
      dockSrc.components(separatedBy: "phase = 0.75").count - 1 >= 2
      && !dockSrc.contains("phase = 0.6")
      && !dockSrc.contains("phase = 0\n"))
check("⑧c 位移走单一常量 Motion.pageSlideShift = 60（两处共用同一个，防只改一边 / 退回字面量 22）",
      dockSrc.components(separatedBy: "Motion.pageSlideShift").count - 1 >= 4
      && !dockSrc.contains("? 22 : -22")
      && src("qingliao/Theme/Motion.swift").contains("static let pageSlideShift: CGFloat = 60"))
check("⑧c 低起点整页淡入不许回来（0.35/0.9/0.12 起手的老病，v4.0.73 起淡入透出的是同款渐变垫底）",
      !dockSrc.contains("opacity(0.35 + 0.65 * phase)")
      && !dockSrc.contains("opacity(0.9 + 0.1 * phase)")
      && !dockSrc.contains("opacity(spec == nil ? 1 : 0.12)"))
// ⑧c 切片断言：allowsHitTesting 必须落在垫底层声明后 3 行窗口内（全文件存在性会被 OrbHitLayer 等喂饱=假绿）
if let r = dockSrc.range(of: "EnvironmentGlowLayers(scheme: colorScheme)") {
    let tail = dockSrc[r.lowerBound...].prefix(200)
    check("⑧c TabView 垫底渐变层且不吃点击（窗口内断言，防存在性假绿）",
          tail.contains(".ignoresSafeArea()") && tail.contains(".allowsHitTesting(false)"))
} else {
    check("⑧c TabView 垫底渐变层且不吃点击（窗口内断言，防存在性假绿）", false)
}

// MARK: - ⑨ v4.0.81 方案3「玻璃厚边」（用户 2026-10-09 从四列对比稿拍板）
//   口径：彩收进页底（页底带色 + 三团光晕降浓），卡面全站转玻璃 —— 材质底 + 半透明叠层 +
//   1pt 渐变厚边 + 顶部内高光 + 加重柔影。色值逐字取自对比稿 ql_uimock/gen_beautify.py 的
//   light.cols[3] / dark.cols[3]。
//   变异自证（本段任一条都能自证）：把 EnvironmentGradient 里 pageBase 换成 Color.white、
//   或把某团 opacity 改回 0.38、或把 GlassEdgeSurface 的 cardEdgeGradient 描边删掉、
//   或把任一调用点改回 pastelCardStyle → 本段对应条必红（实测已做）。
let envSrc = src("qingliao/Theme/EnvironmentGradient.swift")
let envClean = stripCommentLines(envSrc)
check("⑨ 页底兜底色 = pageBase（浅 #FAFAFC / 深 #12121A，不再是纯白/纯黑）",
      envClean.contains("EnvironmentGradient.pageBase(scheme)")
      && envSrc.contains("Color(red: 0xFA / 255, green: 0xFA / 255, blue: 0xFC / 255)")
      && envSrc.contains("Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x1A / 255)"))
check("⑨ 三团光晕降浓到方案3 值（浅 .26/.24/.22 · 深 .22/.24/.20）",
      envSrc.contains("opacity: scheme == .dark ? 0.22 : 0.26")
      && envSrc.contains("opacity: scheme == .dark ? 0.24 : 0.24")
      && envSrc.contains("opacity: scheme == .dark ? 0.20 : 0.22"))
check("⑨ 旧光晕浓度不许回潮（.35/.38、.35/.34、.30/.36 那三档老值）",
      !envSrc.contains("? 0.35 : 0.38") && !envSrc.contains("? 0.35 : 0.34")
      && !envSrc.contains("? 0.30 : 0.36"))
let lgSrc9 = src("qingliao/Theme/LiquidGlass.swift")
let lgClean9 = stripCommentLines(lgSrc9)
check("⑨ 卡面出口 = GlassEdgeSurface（材质 + 叠层 + 1pt 渐变厚边 + 顶部内高光）",
      lgClean9.contains("struct GlassEdgeSurface")
      && lgSrc9.contains("shape.fill(.ultraThinMaterial)")
      && lgSrc9.contains("strokeBorder(EnvironmentGradient.cardEdgeGradient(scheme), lineWidth: 1)")
      && lgSrc9.contains("strokeBorder(EnvironmentGradient.cardTopHighlight(scheme), lineWidth: 1)"))
check("⑨ 三个卡修饰符全走该出口（pastelCard / pastelFill / dashboardCard）",
      lgClean9.contains(".modifier(GlassEdgeSurface(cornerRadius: cornerRadius))")
      && lgClean9.contains("fill: true, edge: stroke, shadow: false")
      && lgClean9.contains("GlassEdgeSurface(cornerRadius: cornerRadius, fill: false)"))
check("⑨ 降低透明度时叠层转系统实底（无障碍护栏，不许只留材质）",
      lgSrc9.contains("accessibilityReduceTransparency")
      && lgSrc9.contains("Color(uiColor: .secondarySystemGroupedBackground)"))
// 旧淡彩真源整块退役：Features 全目录扫描（注释里的不算 —— 本仓注释习惯写清旧形态）
var oldPastel = ""
if let en = FileManager.default.enumerator(atPath: "qingliao/Features") {
    for case let rel as String in en where rel.hasSuffix(".swift") {
        let code = stripCommentLines(src("qingliao/Features/\(rel)"))
        if code.contains("pastelCardStyle") || code.contains("pastelShadow") { oldPastel += "\(rel) " }
    }
}
check("⑨ 旧淡彩真源清零（Features 下 pastelCardStyle / pastelShadow 零残留；残留：\(oldPastel)）",
      oldPastel.isEmpty
      && !envClean.contains("func pastelCardStyle") && !envClean.contains("func pastelShadow"))

print("通过 \(passCount) / 失败 \(failCount)")
if failCount > 0 { exit(1) }
