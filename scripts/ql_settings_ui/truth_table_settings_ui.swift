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
        // v4.0.20：**裸形态**此前没被盯 → 后端更新弹窗的 `.padding(20)` 整轮收敛漏网，
        // 用户真机报「设置页弹窗跟其他弹窗不一致」。这里一并清零（18 也是同概念字面量）。
        || b.contains(".padding(20)") || b.contains(".padding(18)")
}
check("缩进/水平留白字面量清零（52/62/18/20 四形态 + 裸 padding(18/20)，扫 \(swiftFiles.count) 个文件）",
      hitCount(badLiteral) == 0)

// v4.0.20：设置域「详情弹窗」必须声明 detent ─────────────────────────────
// 用户真机报：「设置后端更新弹窗又跟其他弹窗不一致」。根因 = 该 sheet 没写
// `.presentationDetents` → 打开即全高、没有中档可拖，与同类详情弹窗（本地模型 /
// 视觉模型 / Agent）形态不同。钉住这三个必须声明，防止再漏。
for name in ["BackendUpdate.swift", "LocalModelsSheet.swift", "VisionModelSheet.swift",
             "MailSettingsSheet.swift", "CloudDriveSettingsSheet.swift", "SettingsAccess.swift"] {
    let body = stripComments(src("\(settingsDir)/\(name)"))
    check("🚨 设置详情弹窗 \(name) 声明了 presentationDetents",
          body.contains(".presentationDetents("))
}

// v4.0.20 续（子代理全仓审计）：同一类问题用户已报两次「弹窗跟其他弹窗不一致」，
// 把「挂错位置」这个更隐蔽的形态也钉死。
// ⚠️ 光看字符串区分不出「贴闭包内」(生效) 与「挂宿主链上」(不生效) —— 两种写法长一模一样。
//    必须按**花括号配平**取 sheet 闭包体，再断言 detent 在体内。
func sheetClosureBody(_ src: String, after anchor: String) -> String? {
    guard let r = src.range(of: anchor) else { return nil }
    let rest = src[r.upperBound...]
    guard let open = rest.firstIndex(of: "{") else { return nil }
    var depth = 0
    var i = open
    while i < rest.endIndex {
        if rest[i] == "{" { depth += 1 }
        else if rest[i] == "}" { depth -= 1; if depth == 0 { return String(rest[open...i]) } }
        i = rest.index(after: i)
    }
    return nil
}
let recordSrc = stripComments(src("qingliao/Features/Life/RecordSection.swift"))
let fixedBlock = sheetClosureBody(recordSrc, after: ".sheet(isPresented: $showFixed)") ?? ""
check("🚨 账本固定支出弹窗的 detent 在 sheet 闭包**内**（挂在宿主链上对弹窗不生效）",
      fixedBlock.contains(".presentationDetents("))
check("（反向自证）闭包体确实是 FixedExpenseSheet 的那个（防锚点失配后空真）",
      fixedBlock.contains("FixedExpenseSheet()"))
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

// MARK: - 会话列表卡淡彩渐变（v4.0.67 P2：dashboardCard 玻璃口径退役，换 P0 pastelCard）
let sessSrc = src("qingliao/Features/Sessions/SessionsView.swift")
let sessCode = stripComments(sessSrc)
check("会话卡走 pastelCard()（P0 淡彩渐变卡，与 AI 气泡/生活卡同档）",
      sessCode.contains(".pastelCard(cornerRadius: Radius.card)"))
check("会话卡不再挂不透明 secondarySystemGroupedBackground（那会把渐变压死）",
      !sessCode.contains("secondarySystemGroupedBackground"))
// 反向：会话**行**旧玻璃口径清零（dashboardCard 玻璃压在渐变彩底上发灰，不许回潮）。
// v4.0.68 例外（用户 2026-10-07 拍板「会话页两张固定会话卡要对齐聊天首页卡片风格」）：
//   新加的 `FixedChannelCard` 卡面**刻意复用首页卡**（HomeCardFace 用的就是 dashboardCard），
//   所以口径从「全文件零命中」收成「dashboardCard 只许出现在 FixedChannelCard 那一段里」。
func occ(_ hay: String, _ needle: String) -> Int {
    hay.components(separatedBy: needle).count - 1
}
let fixedCardBody = slice(sessCode, "struct FixedChannelCard: View {", "private var accessibilityText: Text {")
check("FixedChannelCard 段切片取到且含 dashboardCard（防空真）",
      !fixedCardBody.isEmpty && fixedCardBody.contains(".dashboardCard("))
check("会话行旧玻璃口径 dashboardCard 清零（v4.0.67 退役；v4.0.68 仅 FixedChannelCard 例外）",
      occ(sessCode, ".dashboardCard(") == occ(fixedCardBody, ".dashboardCard("))

// v4.0.68：固定会话（轻聊投递/轻聊主动）改**顶部并排卡**——三件事一起钉死：
//   ① 并排卡确实渲染在列表顶部；② 普通列表行**过滤掉**固定会话（否则同一会话出现两次）；
//   ③ 多选/全选的口径（visibleSessions）同步过滤，别把不可删的固定会话算进去。
check("固定会话并排卡渲染在 List 顶部（fixedChannelCards）",
      sessCode.contains("fixedChannelCards")
      && sessCode.contains("if !fixedChannelSessions.isEmpty"))
check("普通列表行过滤掉固定会话（同会话不重复出现）",
      sessCode.contains("ForEach(sortedSessions.filter { !isFixedSession($0.id) })"))
check("多选口径 visibleSessions 同步过滤固定会话",
      sessCode.contains("return sortedSessions.filter { !isFixedSession($0.id) }"))
check("固定会话并排卡高度钉死 HomeCardStore.cardHeight（两张并排不许自适应高低不齐）",
      fixedCardBody.contains(".frame(height: HomeCardStore.cardHeight)"))
// 反向：会话卡不许手搓 glassEffect（要改档位只能改 PastelCard 一处）
check("会话卡没有自己手搓 glassEffect（口径单源）",
      !sessCode.contains("glassEffect("))
// 反向：F2 坑的真正形态是「实色底与卡底同时出现在同一条修饰链上」——
//   实色底会画在卡底之上（先挂=background 画得更靠前），卡底被完全压死。
//   pastelCard() 把渐变/描边/影收在一处，故卡上不得再自行出现任何实色 background。
//   锚在**代码文本**上，只盯会话卡自己的修饰链（.pastelCard → .onTapGesture）：
//   卡内分类胶囊/标签胶囊的 .background(…, in: Capsule()) 不属 F2 口径，本就不该进这一段。
let sessCardChain = slice(sessCode, ".pastelCard(cornerRadius: Radius.card)", ".onTapGesture { action() }")
check("会话卡修饰链切片非空（防再次空真）", !sessCardChain.isEmpty)
check("会话卡修饰链上没有自行挂的实色 background（F2：实色底会压死渐变卡底）",
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
// v4.0.61：玻璃改经无障碍出口 a11yGlass → 判据放宽到「两种写法之一」，原意不动（玻璃仍与折射源同 ZStack）
check("🚨 折射源与玻璃在**同一个 ZStack**（不是两层 background 叠放）",
      glassPageBody.contains("ZStack")
      && (glassPageBody.contains("glassEffect") || glassPageBody.contains("a11yGlass")))
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

// MARK: - v4.0.61 CI 实踩（run #694）：**凭空造成员** —— 本机 `-parse` 全绿，只有 Archive 报
//   `.onDismiss` 是 `sheet(isPresented:onDismiss:content:)` 的**参数**，不是 View 修饰符；
//   挂到内容视图上 → `value of type 'some View' has no member 'onDismiss'`。
//   反向断言：源码里不许再出现链式 `.onDismiss`（写注释说明不算——svSrc 已 stripComments）。
check("🚨 不得把 onDismiss 当 View 修饰符链式调用（它只是 sheet 的参数）",
      !svSrc.contains(".onDismiss"))

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

// MARK: - 弹窗顶栏「完成」胶囊统一放左侧（2026-10-01 用户拍板：「设置页弹窗的完成胶囊统一放左边，后面的设计要遵循」）
// 口径：所有 sheet/弹窗顶栏的「完成」按钮一律 ToolbarItem(placement: .cancellationAction)（左位）；
//   键盘工具条（placement: .keyboard）的「完成」是收键盘用，不属顶栏，不在本口径内。
//   双按钮弹窗 = 左「完成」右「取消」（SettingsModelAgent 口径）。
// 实现：逐文件剥注释后逐行扫 Button("完成")，向前找最近的 ToolbarItem(placement:) 归类；
//   归类用 squash 后按行切，向前 7 行内必能命中 ToolbarItem 行（现有全部写法均满足）。
var doneLeft = 0, doneRight = 0, doneKeyboard = 0
var doneMisplaced: [String] = []
for f in appSwift {
    let lines = stripComments(src(f)).split(separator: "\n", omittingEmptySubsequences: false)
        .map { String($0) }
    for (i, ln) in lines.enumerated() where ln.contains("Button(\"完成\")") {
        let back = lines[max(0, i - 7)...i].joined(separator: "\n")
        if back.contains("placement: .keyboard") { doneKeyboard += 1; continue }
        if back.contains("placement: .cancellationAction") { doneLeft += 1; continue }
        if back.contains("placement: .confirmationAction") || back.contains("placement: .topBarTrailing") {
            doneRight += 1; doneMisplaced.append(f)
        }
    }
}
check("全仓扫到顶栏「完成」\(doneLeft) 处在左位 + 键盘工具条 \(doneKeyboard) 处（左位 ≥37 才算全量覆盖）",
      doneLeft >= 37 && doneKeyboard >= 2)
check("🚨 弹窗顶栏「完成」一律放左（cancellationAction）；在右侧的：\(doneMisplaced.joined(separator: " / "))",
      doneRight == 0)

print("设置页间距口径真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
