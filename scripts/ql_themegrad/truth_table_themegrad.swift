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

// MARK: - ① 页底单源：四个主页面各挂一层环境渐变
let pageFiles: [(String, String)] = [
    ("聊天页", "qingliao/Features/Chat/ChatView.swift"),
    ("会话页", "qingliao/Features/Sessions/SessionsView.swift"),
    ("生活页", "qingliao/Features/Life/LifeView.swift"),
    ("设置页", "qingliao/Features/Settings/SettingsCore.swift"),
]
for (name, path) in pageFiles {
    let raw = src(path)
    check("\(name)源可读（空了下面两条是空真）", !raw.isEmpty)
    let code = stripCommentLines(raw)
    check("① \(name)页底挂主题环境渐变",
          code.contains(".background(EnvironmentGlowLayers(scheme: colorSchemeEnv))"))
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

// MARK: - ⑤ 主题取值单源（页底光晕与淡彩卡底色值不许就地手改）
let themeSrc = src("qingliao/Theme/EnvironmentGradient.swift")
check("⑤ 主题源可读", !themeSrc.isEmpty)
check("⑤ 深色淡彩卡底走暗调版（不是简单调透明度）",
      themeSrc.contains("Color(red: 36 / 255, green: 31 / 255, blue: 51 / 255)"))
check("⑤ 页底三团光晕齐（桃粉/天蓝/薄荷各一团）",
      occ(themeSrc, "GlowBlob(tint:") == 3)
// 🚨 原写法 `!themeSrc.contains("opacity: 0.4")` 是弱断言（把 0.38 改成 0.42/0.55/0.9 照样绿）。
//    改成真的解析：扫**代码行**（剥注释）里所有含 opacity 的小数字面量（三团光晕写成
//    `opacity: scheme == .dark ? 0.35 : 0.38,`，一行两值），逐个判 ≤ 0.38。
// ⚠️ 只取「opacity」**之后**那段（不是整行）：`Color(red: 0.42, green: 0.36, blue: 0.72).opacity(0.10)`
//    整行取数会把配色分量 0.72 当成透明度（实测踩过：报「最大值 0.72」的假红）。
let glowOpacityVals: [Double] = stripCommentLines(themeSrc).split(separator: "\n")
    .flatMap { line -> [Double] in
        guard line.contains("opacity") else { return [] }
        let tail = line.components(separatedBy: "opacity").dropFirst().joined(separator: "")
        var vals: [Double] = []; var cur = ""
        for ch in tail {
            if ch.isNumber || ch == "." { cur.append(ch) }
            else { if let d = Double(cur) { vals.append(d) }; cur = "" }
        }
        if let d = Double(cur) { vals.append(d) }
        return vals
    }
check("⑤ 光晕/柔影透明度取值解析到了（空了下面就是空真）", !glowOpacityVals.isEmpty)
check("⑤ 每处透明度都不超 0.38（正文对比度红线；实测最大值 \(glowOpacityVals.max() ?? -1)）",
      (glowOpacityVals.max() ?? 1) <= 0.38)

print("通过 \(passCount) / 失败 \(failCount)")
if failCount > 0 { exit(1) }
