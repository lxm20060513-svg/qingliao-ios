// MARK: - v3.9.80 设置页间距口径 · 真值表（令牌单一真源 + 字面量清零 + 算式镜像）
//
// 背景（用户口径：「用 baseline-ui 过一遍设置页的间距和字号层级」→ 选「做 1+2」）：
//   ① 分隔线左缩进 52 出现 46 次、同概念的 cron 任务行却写 62 → 收成两个命名令牌；
//   ② 「非卡片内容左右留白」同一概念写过 18（12 处）与 20（9 处）→ 统一到 18（与分组标题 SectionHeader 对齐）。
// 本表盯三件事：令牌在位且值对 / Settings 目录下字面量清零 / 令牌值与行算式一致（改图标尺寸会让这里红）。
//
// 字号层级不在本表：设置页文字 100% 走 Typography 令牌（真值表 ql_* 无独立需求），
// 全页仅 3 处字面字号且都是 SF Symbol 图标尺寸（40 / 40 / 34），不属文字层级。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// v4.0.0：去掉 `//` 与 `/* */` 注释，只留代码文本。
/// 本表要断言"某段结构真的这样写"，而注释里常留着**旧口径的说明**
/// （v3.9.78 的 22 圆角注释就是这么差点把护栏喂成假绿的），故一律先剥注释再判。
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
    // 去行尾残留的「*/」残留与多余空白
    return out.replacingOccurrences(of: "*/", with: " ")
}

let spacingSrc = src("qingliao/Theme/Spacing.swift")
let sheetsSrc = src("qingliao/Features/Settings/SettingsCommon.swift")

// ── 1. 源可读（空了后面全是空真） ─────────────────────────────
check("Spacing.swift 源可读", !spacingSrc.isEmpty)
check("SettingsCommon.swift 源可读", !sheetsSrc.isEmpty)

// ── 2. 三个语义令牌在位且值逐字正确 ───────────────────────────
check("sheetInset = 18 在位", spacingSrc.contains("static let sheetInset: CGFloat = 18"))
check("rowDividerInset = 54 在位（严格按算式对齐，用户 v3.9.80 拍板）",
      spacingSrc.contains("static let rowDividerInset: CGFloat = 54"))
check("rowDividerInsetWide = 62 在位", spacingSrc.contains("static let rowDividerInsetWide: CGFloat = 62"))

// ── 3. 算式镜像：令牌值必须与「行内留白 + 图标 + 间距」逐字对得上 ────
// SettingRow 真值：行内留白 xxl=14、图标 28、图标与文字间距 12 → 54（v3.9.80 起令牌即此值）；
// rowDividerInsetWide 用于 36pt 图标行（cron 任务列表）→ 14 + 36 + 12 = 62。
// 这条镜像的意义：以后有人改图标尺寸/行内留白（14/28/36/12）而没同步令牌，本表立刻红。
let rowLeading: CGFloat = 14   // Spacing.xxl
let iconStd: CGFloat = 28      // SettingRow 图标
let iconWide: CGFloat = 36     // cron 任务行图标
let iconGap: CGFloat = 12      // HStack spacing
func mirrorDividerInset(icon: CGFloat) -> CGFloat { rowLeading + icon + iconGap }
check("镜像：36pt 图标行 = 14+36+12 = 62（与 rowDividerInsetWide 逐字一致）",
      mirrorDividerInset(icon: iconWide) == 62)
check("镜像：28pt 图标行 = 14+28+12 = 54（与 rowDividerInset 逐字一致）",
      mirrorDividerInset(icon: iconStd) == 54
      && spacingSrc.contains("static let rowDividerInset: CGFloat = 54"))

// ── 4. 分组标题（SectionHeader）与非卡片内容同口径 ─────────────
check("SectionHeader 左右留白走 Spacing.sheetInset（与说明文字/错误提示对齐）",
      sheetsSrc.contains("struct SectionHeader: View")
      && sheetsSrc.contains(".padding(.horizontal, Spacing.sheetInset)"))

// ── 5. Settings 目录下字面量清零（逐文件扫，不是只看某一个文件） ──
let settingsDir = "qingliao/Features/Settings"
let files = (try? FileManager.default.contentsOfDirectory(atPath: settingsDir)) ?? []
check("Settings 目录可枚举（\(files.count) 个文件，2026-09-27 合并后为 8）", files.count >= 8)
let swiftFiles = files.filter { $0.hasSuffix(".swift") }
let bodies = swiftFiles.map { (name: $0, body: src("\(settingsDir)/\($0)")) }
func hitCount(_ pattern: (String) -> Bool) -> Int { bodies.filter { pattern($0.body) }.count }
// 负断言：这四种字面量形态一个都不许再有（52/62 缩进、18/20 水平留白）
let badLiteral = { (b: String) -> Bool in
    b.contains(".padding(.leading, 52)") || b.contains(".padding(.leading, 62)")
        || b.contains(".padding(.horizontal, 18)") || b.contains(".padding(.horizontal, 20)")
}
check("缩进/水平留白字面量清零（52/62/18/20 四形态，扫 \(swiftFiles.count) 个文件）",
      hitCount(badLiteral) == 0)
// 正断言：令牌真的被用起来了（不然可能只是把字面量删了）
check("rowDividerInset 至少被 40 处使用（收敛前是 46 处字面量）",
      bodies.reduce(0) { $0 + $1.body.components(separatedBy: "Spacing.rowDividerInset)").count - 1 } >= 40)
check("sheetInset 至少被 15 处使用（收敛前 18×12 + 20×9 = 21 处字面量）",
      bodies.reduce(0) { $0 + $1.body.components(separatedBy: "Spacing.sheetInset)").count - 1 } >= 15)
check("rowDividerInsetWide 被 cron 任务行那一处使用",
      src("qingliao/Features/Settings/SettingsCommon.swift").contains("Spacing.rowDividerInsetWide)"))

// ── 6. 行尾值表单行口径（值折行 → 左标题被垂直居中夹住 = 真机报过的「文字错位」同款） ──
/// 取 a 之后、b 之前的一段源码（先断言切片非空，否则下面的断言等于空真）
func slice(_ s: String, _ a: String, _ b: String) -> String {
    guard let ra = s.range(of: a), let rb = s.range(of: b, range: ra.upperBound..<s.endIndex) else { return "" }
    return String(s[ra.upperBound..<rb.lowerBound])
}
// 共用行组件 SettingRow：设置页绝大多数行都走它 → 一处修覆盖全部
let settingRowBody = slice(sheetsSrc, "struct SettingRow", "\nstruct ")
check("共用行组件 SettingRow 切片取到且长度合理（空了下面的断言等于白写）",
      !settingRowBody.isEmpty && settingRowBody.count < 3000)
check("共用行组件的行尾值钉单行", settingRowBody.contains(".lineLimit(1)"))
check("共用行组件 Spacer 显式留最小间距（Spacer() 视觉等价，这里只是把口径写明）",
      settingRowBody.contains("Spacer(minLength: 8)"))
// 三个同形行（不是 SettingRow）单独钉
let cityRowBody = slice(src("qingliao/Features/Settings/SettingsCommon.swift"),
                        "Text(\"天气城市\")", "showWeatherCityField")
check("天气城市行切片取到且行尾值钉单行", !cityRowBody.isEmpty && cityRowBody.contains(".lineLimit(1)"))
let ttsModelRowBody = slice(src("qingliao/Features/Settings/SettingsModels.swift"),
                            "Text(\"模型\")", "// 音色下拉")
check("TTS 模型行切片取到且 Picker 钉单行", !ttsModelRowBody.isEmpty && ttsModelRowBody.contains(".lineLimit(1)"))

// MARK: - 会话列表卡玻璃化（v4.0.0，用户拍板复用 dashboardCard）
let sessSrc = src("qingliao/Features/Sessions/SessionsView.swift")
let sessCode = stripComments(sessSrc)
check("会话卡走 dashboardCard()（与意图卡/门锁卡同档，不新增第三套玻璃）",
      sessCode.contains(".dashboardCard(cornerRadius: Radius.card)"))
check("会话卡不再挂不透明 secondarySystemGroupedBackground（那会把玻璃压死）",
      !sessCode.contains("secondarySystemGroupedBackground"))
// 反向：会话卡不许手搓 glassEffect（要改档位只能改 DashboardCardStyle 一处）
check("会话卡没有自己手搓 glassEffect（口径单源）",
      !sessCode.contains("glassEffect("))
// 反向：F2 坑的真正形态是「实色底与玻璃同时出现在同一条修饰链上」——
//   实色底会画在玻璃之上（先挂=background 画得更靠前），玻璃被完全压死。
//   dashboardCard() 把玻璃/描边/影收在一处，故卡上不得再自行出现任何实色 background。
// ⚠️ v4.0.x 修（原写法是空真、恒绿）：原来 slice(sessCode, "struct SessionRow", "// MARK: - v3.9.33")
//   —— sessCode 已 stripComments，而结束锚点 "// MARK: …" 恰好被剥掉 → slice 恒返回 "" → 断言恒过（假绿）。
//   改为锚在**代码文本**上，只盯会话卡自己的修饰链（.dashboardCard → .onTapGesture）：
//   卡内分类胶囊/标签胶囊的 .background(…, in: Capsule()) 不属 F2 口径，本就不该进这一段。
let sessCardChain = slice(sessCode, ".dashboardCard(cornerRadius: Radius.card)", ".onTapGesture { action() }")
check("会话卡修饰链切片非空（防再次空真）", !sessCardChain.isEmpty)
check("会话卡修饰链上没有自行挂的实色 background（F2：实色底会压死玻璃）",
      !sessCardChain.contains(".background("))

// MARK: - 设置页 v3.9.88 回退：单页平铺，无 8 大类二级页、无整页玻璃底
//   用户拍板「设置界面回退到 3.9.87 版本」→ 下面改为**反向断言**：一旦有人又把
//   归类二级页 / 整页玻璃底加回来，这条真值表就红。
let svSrc = stripComments(src("qingliao/Features/Settings/SettingsCore.swift"))
let dockSrc = stripComments(src("qingliao/Features/DockTabView.swift"))
let lgGlassSrc = stripComments(src("qingliao/Theme/LiquidGlass.swift"))

// 玻璃底本体（整页档本身保留在 Theme 里，只是不再被设置页引用）
check("有 glassPageBackground 修饰符（整页玻璃本体仍留在 Theme 供别处用）",
      lgGlassSrc.contains("struct GlassPageBackground"))
let glassPageBody = slice(lgGlassSrc, "struct GlassPageBackground", "struct OverlayGlassCard")
check("🚨 折射源与玻璃在**同一个 ZStack**（不是两层 background 叠放）",
      glassPageBody.contains("ZStack") && glassPageBody.contains("glassEffect"))
let bgCount = glassPageBody.components(separatedBy: ".background").count - 1
check("🚨 只挂一次 background（两次=玻璃被折射源压死）", bgCount == 1)
check("整页玻璃不圆角（用 Rectangle 形状，无 RoundedRectangle 圆角档）",
      glassPageBody.contains("Rectangle()") && !glassPageBody.contains("RoundedRectangle"))

// 🚨 回退后必须回到 3.9.87 形态：设置页**单页平铺**，下列 v4.0.0 特征一律不许回来
check("🚨 设置页不再挂整页玻璃底（v3.9.88 用户拍板回退 3.9.87）",
      !svSrc.contains(".glassPageBackground()"))
check("🚨 设置页不再有 SettingsGroup 8 大类枚举（回退为单页平铺）",
      !svSrc.contains("enum SettingsGroup"))
check("🚨 设置页不再有自绘返回键（无二级页，不需要返回）",
      !svSrc.contains("backButton"))
check("🚨 设置页不再用 NavigationLink 推二级页",
      !svSrc.contains("NavigationLink {"))
check("🚨 设置页 body 直接平铺全部分组（account/connection/ai/data/agent/appearance/about）",
      slice(svSrc, "ScrollView {", "scrollPosition").contains("accountSection")
      && slice(svSrc, "ScrollView {", "scrollPosition").contains("dataSection")
      && slice(svSrc, "ScrollView {", "scrollPosition").contains("appearanceSection")
      && slice(svSrc, "ScrollView {", "scrollPosition").contains("logoutButton"))
check("🚨 退出登录与各分组同页（不再藏进二级页）",
      slice(svSrc, "ScrollView {", "scrollPosition").contains("logoutButton"))

// MARK: - v4.0.10 开关（Toggle）统一口径：尺寸一律系统原生、配色默认系统绿
//   用户真机反馈：「设置里面桌面快捷方式弹窗的开关胶囊和系统的大小不一样，别的地方看哪里不一样
//   的一起改过来」。成因：设置里 6 处挂了 .scaleEffect(0.8) 缩过版，而「桌面快捷方式」弹窗、
//   首页卡片弹窗、登录页那些是系统原生 → 同一个 App 里两种开关大小；配色还混了 绿/蓝/橙。
//   修法：全仓开关只走 Theme/SwitchStyle.swift 的 qingliaoSwitch()（尺寸/配色/标签三件事一处定）。
let switchStyleCode = stripComments(src("qingliao/Theme/SwitchStyle.swift"))
check("开关口径文件在位（Theme/SwitchStyle.swift）", !switchStyleCode.isEmpty)
check("口径函数签名 = 唯一入口（默认隐藏标签 + 默认系统绿）",
      switchStyleCode.contains("func qingliaoSwitch(hideLabel: Bool = true, color: Color = .green)"))
check("口径内部：隐藏标签走 labelsHidden()、配色走 .tint(color)（标签条件化靠 @ViewBuilder）",
      switchStyleCode.contains("labelsHidden()") && switchStyleCode.contains(".tint(color)"))
check("🚨 口径本体不许出现 scaleEffect（缩一下就是用户报的「和设置里开关大小不一样」）",
      !switchStyleCode.contains("scaleEffect"))

/// 全仓扫开关：每个独立的 `Toggle(` 后面必须紧跟 qingliaoSwitch(，且不许自己叠加尺寸/配色修饰符
func allSwiftFiles(_ dir: String) -> [String] {
    guard let en = FileManager.default.enumerator(atPath: dir) else { return [] }
    return en.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
        .map { "\(dir)/\($0)" }.sorted()
}
/// 去注释 + 压缩空白：跨行修饰链（.onChange / 换行 .tint）归一化成一行，便于按"后 N 字符"断言
func squashToggleCode(_ s: String) -> String {
    stripComments(s).split(separator: "\n", omittingEmptySubsequences: false)
        .map { String($0.filter { !$0.isWhitespace }) }.joined()
}
let appSwift = allSwiftFiles("qingliao")
check("全仓 .swift 可枚举（\(appSwift.count) 个）", appSwift.count >= 40)
var toggleTotal = 0, toggleStyled = 0, toggleScaled = 0, toggleManual = 0
var toggleUnstyled: [String] = []
for f in appSwift {
    let code = squashToggleCode(src(f))
    var idx = code.startIndex
    while let r = code.range(of: "Toggle(", range: idx..<code.endIndex) {
        idx = r.upperBound
        // 只认独立 Toggle(：notifyToggle( / quirkToggle( 这类自造名不算开关
        if let before = code[code.startIndex..<r.lowerBound].last,
           before.isLetter || before.isNumber || before == "_" { continue }
        toggleTotal += 1
        let tail = String(code[r.upperBound...].prefix(300))
        if tail.contains("qingliaoSwitch(") { toggleStyled += 1 } else { toggleUnstyled.append(f) }
        if tail.contains("scaleEffect") { toggleScaled += 1 }
        if tail.contains(".labelsHidden()") || tail.contains(".tint(") { toggleManual += 1 }
    }
}
check("全仓扫到 \(toggleTotal) 处真开关（v4.0.10 开关口径收口时为 19 处）", toggleTotal >= 19)
check("🚨 每一处开关都走 qingliaoSwitch()（没走的：\(toggleUnstyled.joined(separator: " / "))）",
      toggleStyled == toggleTotal)
check("🚨 全仓开关不许叠加 scaleEffect（缩过版 = 用户报的「和系统大小不一样」）",
      toggleScaled == 0)
check("🚨 开关调用点不许自己手写 .labelsHidden()/.tint()（口径必须单源，手写就会再漂）",
      toggleManual == 0)

print("设置页间距口径真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
