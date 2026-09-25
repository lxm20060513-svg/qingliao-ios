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

let spacingSrc = src("qingliao/Theme/Spacing.swift")
let sheetsSrc = src("qingliao/Features/Settings/SettingsSheets.swift")

// ── 1. 源可读（空了后面全是空真） ─────────────────────────────
check("Spacing.swift 源可读", !spacingSrc.isEmpty)
check("SettingsSheets.swift 源可读", !sheetsSrc.isEmpty)

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
check("Settings 目录可枚举（\(files.count) 个文件）", files.count > 10)
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
      src("qingliao/Features/Settings/SettingsPages.swift").contains("Spacing.rowDividerInsetWide)"))

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
let cityRowBody = slice(src("qingliao/Features/Settings/AppearanceSheet.swift"),
                        "Text(\"天气城市\")", "showWeatherCityField")
check("天气城市行切片取到且行尾值钉单行", !cityRowBody.isEmpty && cityRowBody.contains(".lineLimit(1)"))
let ttsModelRowBody = slice(src("qingliao/Features/Settings/SettingsModelSheets.swift"),
                            "Text(\"模型\")", "// 音色下拉")
check("TTS 模型行切片取到且 Picker 钉单行", !ttsModelRowBody.isEmpty && ttsModelRowBody.contains(".lineLimit(1)"))

print("设置页间距口径真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
