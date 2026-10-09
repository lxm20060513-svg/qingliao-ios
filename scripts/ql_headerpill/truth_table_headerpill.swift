// MARK: - 页头图标胶囊真值表（v4.1.x 合并胶囊 · 2026-10-05 用户看三档对比稿拍板「方案 A + 图标 14」）
//
// 口径（用户从渲染对比稿里拍板，图在 /opt/data/scripts/ql_header_pill/mock/out/：
//   merged_pill.png = 形状方案，pill_iconsize.png = 图标尺寸档）：
//   · **多颗独立胶囊合并成一整颗**（v4.0.62 的两/三颗独立胶囊 → 一颗 HeaderPillGroup）；
//   · 尺寸 = 图标 14pt（用户在 13/14/15 里选 14）+ 囊高 34pt + 图标中心距 30pt + 端部内边距 12pt
//     （后三者按用户参考图逐像素量测的比例换算：0.878 / 0.355 × 胶囊高）；
//   · ⚠️ 参考图那颗胶囊是纯白底压浅灰页（亮度差 11）；本仓页面底是纯白，白胶囊差 0 会隐形
//     → **沿用玻璃底**（glassPillStroke），不要照搬白底（这条是照搬时的翻车点）。
//   图标 = **圆环家族**（稿里的 B 组）：会话页 archivebox.circle / checkmark.circle / xmark.circle / plus.circle，
//        聊天页 list.bullet.circle / ellipsis.circle。
//        依据：这几个符号的位图画布实测**全 44px**，其余候选 39~53px 参差（archivebox 46 / checkmark 43 /
//        plus 40 / checklist 53 / tray 52 / list.bullet 48）——「光学方框不齐」正是用户说的"不协调"。
//   ⚠️ v4.0.61 曾以「外环图标 + 胶囊底 = 双圈」为由把外环去掉（ellipsis.circle → ellipsis）；
//      用户看过对比稿后**明确选了带外环的 B 组** → 该顾虑作废，**不要再按那条改回裸字形**（本表第 2 组反向钉死）。
//
// 为什么值得钉（这三处都会**静默**错，不报错，只让用户下次装包再吐槽一轮）：
//   ① 尺寸只有一个真源 HeaderPillIconButton.iconFont/hPad/vPad/spacing —— 谁"顺手"改回 .pill(.topBar)
//      或自己写 HStack(spacing: 12)，胶囊立刻回到 41×31，用户要的"调小一档"无声消失；
//   ② 三颗图标必须同族：混排（裸字形 + 带框）就是从 v4.0.61 一路被吐槽到 v4.0.62 的病根，肉眼不易复核；
//   ③ 会话页页头**不再**挂滚动视图（v4.0.62 的滚边玻璃已被用户 v4.0.63 真机复测撤销）：页头必须留在
//      VStack 第一行、全页 `.safeAreaBar` 计数为 0 —— 有人"统一一下"把 `.safeAreaBar` 加回来，本表第 3 组判红。
//
// 单文件（读源文件做护栏，不 import 项目代码）→ run_unit 直接编跑。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉 `//` 行注释：注释里刻意写了「不要改回去」的警示与回退说明，
/// 直接用原文 grep 会被自己的注释判红（与第 84 段同一手法）。
func code(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            // 行内 `//` 前面若有引号（如 URL "https://…"）不算注释起点
            let head = line[line.startIndex..<r.lowerBound]
            if head.filter({ $0 == "\"" }).count % 2 == 1 { return String(line) }
            return String(head)
        }
        .joined(separator: "\n")
}

let root = "qingliao/"
let pill = src(root + "Theme/HeaderPillButton.swift")
let pillCode = code(pill)
let sessions = src(root + "Features/Sessions/SessionsView.swift")
let sessionsCode = code(sessions)
let chat = src(root + "Features/Chat/ChatView.swift")
let chatCode = code(chat)
let dashboard = src(root + "Features/Dashboard/DashboardView.swift")
let life = src(root + "Features/Life/LifeView.swift")
let record = src(root + "Features/Life/RecordSection.swift")
let recordCode = code(record)

check("① 组件在位（会话页/聊天页页头图标只有它一个入口）",
      !pill.isEmpty && !pillCode.isEmpty)

// ── 1. 尺寸：小二档真源 ─────────────────────────────────────────
check("① 尺寸真源：iconFont 14（v4.1.x 用户在三档稿里选 14；回退成 12 = 无声变小）",
      pillCode.contains("static let iconFont: CGFloat = 14"))
check("① 尺寸真源：囊高 height 34", pillCode.contains("static let height: CGFloat = 34"))
check("① 尺寸真源：图标中心距 centerGap 30（= 0.878×囊高，照参考图比例）",
      pillCode.contains("static let centerGap: CGFloat = 30"))
check("① 尺寸真源：端部内边距 edgePad 12（= 0.355×囊高）",
      pillCode.contains("static let edgePad: CGFloat = 12"))
check("① 旧组件已废除：文件里不再有 struct HeaderPillIconButton（合并后单入口）",
      !pillCode.contains("struct HeaderPillIconButton"))
check("① 玻璃/描边走同一出口 glassPillStroke()（不新造玻璃写法）",
      pillCode.contains(".glassPillStroke()"))
check("① 命中区：横向 = 中心距 30（h:8，与邻项相接不重叠）；纵向补满 44",
      pillCode.contains(".hitArea44(h: Self.hitH, v: 5)")
        && pillCode.contains("static let hitH: CGFloat = 8"))
// v4.0.65 审查（严重）：纵向 44 的前提是 label 真的 34 高 —— HStack 的 .frame(height:)
// **不拉伸子视图**，label 只有 Image 时仅 ≈17pt，v:5 只能补到 ≈27pt（旧实现 ≈49pt）。
// 断言必须限定在 itemView 切片内，否则 .frame(height: Self.height) 会命中 HStack 那处 = 恒真。
let itemViewSlice = { () -> String in
    guard let a = pillCode.range(of: "private func itemView"),
          let b = pillCode.range(of: ".accessibilityLabel(item.a11y)") else { return "" }
    return String(pillCode[a.lowerBound..<b.lowerBound])
}()
check("① 命中区纵向真到 44：itemView 里 label 必须被 .frame(height: Self.height) 撑到囊高",
      itemViewSlice.contains(".frame(height: Self.height)"))
check("① 图标前景色 = Color.accentColor（原由 pill(.accent) 提供；不走 pill 后必须自己带，否则由蓝变黑/白）",
      pillCode.contains(".foregroundStyle(Color.accentColor)"))
check("🚫 反向①：组件里又出现 .pill( 调用 → 判红（回退 = 胶囊涨回 41×31 大档）",
      !pillCode.contains(".pill(") && !pillCode.contains("PillSize."))

// ── 2. 会话页三颗：同族 + 同间距 ────────────────────────────────
let headerSlice = { () -> String in
    guard let a = sessionsCode.range(of: "private var sessionsHeaderItems"),
          let b = sessionsCode.range(of: "private var sessionsHeaderBar") else { return "" }
    return String(sessionsCode[a.lowerBound..<b.lowerBound])
}()

check("② 会话页三颗（归档 + 多选 + 新建）都走 HeaderPillGroup.Item",
      sessionsCode.components(separatedBy: "HeaderPillGroup.Item(").count - 1 == 3)
check("② 合并成一颗：页头只调一次 HeaderPillGroup（回退 = 又变回多颗独立胶囊）",
      sessionsCode.components(separatedBy: "HeaderPillGroup(items:").count - 1 == 1
        && sessionsCode.contains("HeaderPillGroup(items: sessionsHeaderItems)"))
check("🚫 反向②′：会话页不得再引用旧组件 HeaderPillIconButton", !sessionsCode.contains("HeaderPillIconButton"))
check("② 归档两态：archivebox.circle ↔ archivebox.circle.fill（描边 ↔ 实心）",
      sessionsCode.contains("\"archivebox.circle.fill\"") && sessionsCode.contains("\"archivebox.circle\""))
check("② 多选两态：checkmark.circle ↔ xmark.circle",
      sessionsCode.contains("\"checkmark.circle\"") && sessionsCode.contains("\"xmark.circle\""))
check("② 新建：plus.circle", sessionsCode.contains("\"plus.circle\""))
check("② 页头段里三颗都是圆环家族（archivebox.circle / checkmark.circle / xmark.circle 三串都在同一段）",
      headerSlice.contains("archivebox.circle") && headerSlice.contains("checkmark.circle")
        && headerSlice.contains("xmark.circle"))
check("🚫 反向②：会话页又出现裸字形图标（archivebox / tray.full / 裸 xmark·checkmark / 裸 plus）→ 判红",
      !sessionsCode.contains("systemName: \"archivebox\"")
        && !sessionsCode.contains("systemName: \"tray.full\"")
        && !sessionsCode.contains("systemName: \"plus\"")
        && !sessionsCode.contains("? \"xmark\" : \"checkmark\""))

// ── 3. 会话页页头：滚边玻璃已取消（v4.0.63 · 用户 2026-10-05 真机复测拍板撤销）──
// 判据写「VStack → 空白 → 页头」而不是「页头行 + 紧邻 if 行」：前者真钉**第一行**（页头前再插 Spacer /
// 注释行都判红），且不依赖 12 空格缩进字面量（重排不误伤）。
check("③ 会话页页头是 VStack 第一行（两者之间只许空白；回退 = 页头下方再无滚动模糊）",
      sessionsCode.components(separatedBy: "VStack(spacing: 0) {").count - 1 == 1
        && sessionsCode.components(separatedBy: "VStack(spacing: 0) {")[1]
             .trimmingCharacters(in: .whitespacesAndNewlines)
             .hasPrefix("sessionsHeaderBar"))
check("🚫 反向③：会话页不得再挂 safeAreaBar（用户拍板取消滚边玻璃；看板/生活两页不受影响）",
      sessionsCode.components(separatedBy: ".safeAreaBar(").count - 1 == 0)
check("🚫 反向③′：页头只此一处（骨架/错误态/失败横幅不再各带一份；计数 >1 = 回退做成了半退）",
      sessionsCode.components(separatedBy: "            sessionsHeaderBar\n").count - 1 == 1)
check("🚫 反向③″：页头**载体**也只此一处（改个属性名重贴 PageHeader( 同样判红）",
      sessionsCode.components(separatedBy: "PageHeader(").count - 1 == 1)

// ── 4. 聊天页两颗：同族 + 同间距 ────────────────────────────────
// v4.0.81（审查修）：这两条的「不许出现 checklist」原来扫**整个 ChatView** —— 本批新增的
//   「加入待办」长按菜单项合法使用 `checklist`，会把它误判成回退 → 收窄到页头图标项本体
//   （chatHeaderItems）；切片取不到（属性被改名/删掉）时为空串 → 判红，保险方向正确。
let chatHeaderSlice: String = {
    guard let r = chatCode.range(of: "private var chatHeaderItems") else { return "" }
    return String(chatCode[r.lowerBound...].prefix(900))
}()
check("④ 聊天页任务中心：checklist → list.bullet.circle（只看页头项本体；菜单/卡片里的 checklist 不算）",
      chatHeaderSlice.contains("\"list.bullet.circle\"") && !chatHeaderSlice.contains("\"checklist\""))
check("④ 聊天页更多：ellipsis → ellipsis.circle",
      chatCode.contains("\"ellipsis.circle\"") && !chatCode.contains("\"ellipsis\", a11y"))
check("④ 聊天页两颗（任务中心 + 更多）都走 HeaderPillGroup.Item",
      chatCode.components(separatedBy: "HeaderPillGroup.Item(").count - 1 == 2)
check("④ 合并成一颗：页头只调一次 HeaderPillGroup",
      chatCode.components(separatedBy: "HeaderPillGroup(items:").count - 1 == 1
        && chatCode.contains("HeaderPillGroup(items: chatHeaderItems)"))
check("🚫 反向④′：聊天页不得再引用旧组件 HeaderPillIconButton", !chatCode.contains("HeaderPillIconButton"))

// ── 5. 滚边玻璃两页口径（生活试点 / 看板推广；会话页 v4.0.63 已退出）──
check("⑤ 生活页页头在滚动视图上（v4.0.61 试点）",
      code(life).components(separatedBy: ".safeAreaBar(edge: .top)").count - 1 == 1
        && life.contains("PageHeader(title: \"生活\""))
check("⑤ 看板页页头在滚动视图上（v4.0.62 推广）",
      code(dashboard).components(separatedBy: ".safeAreaBar(edge: .top)").count - 1 == 1
        && dashboard.contains("PageHeader(title: \"看板\""))
check("🚫 反向⑤：看板页不许把 PageHeader 挪回 VStack 第一行（回退 = 滚边玻璃整页失效）",
      !code(dashboard).contains("VStack(spacing: 0) {\n            PageHeader"))

// ── 6. 记录卡片首页只显示一条（用户第 4 条）────────────────────
check("⑥ 单张页卡只取最近 1 条（prefix(1)）",
      recordCode.contains("prefix(1)") && !recordCode.contains("prefix(2)"))
check("⑥ 「还有 N 条」计数同口径（count > 1 / count - 1）",
      recordCode.contains("store.records.count > 1")
        && recordCode.contains("store.records.count - 1")
        && !recordCode.contains("store.records.count - 2"))
check("🚫 反向⑥：两处不得各改一处（> 1 与 - 1 必须同时，不然会显示「还有 0 条」）",
      recordCode.contains("count > 1") && recordCode.contains("count - 1"))

// ── 7. 滚边玻璃②：会话页 / 聊天页关闭**滚动边缘效果**（用户 2026-10-05 复测第 2 条）──
// 真源 = iOS 26 系统 `scrollEdgeEffectHidden(_:for:)`（内容滚到标签栏 / 状态栏旁被模糊 + 变暗）。
// ⚠️ 一律用 `code(...)`（已剥注释）—— 源码注释里出现 API 名不算调用。
check("⑦ 会话页 List 关闭滚动边缘效果（scrollEdgeEffectHidden(true)）",
      sessionsCode.contains(".scrollEdgeEffectHidden(true)"))
check("⑦ 聊天页消息区关闭滚动边缘效果（scrollEdgeEffectHidden(true)）",
      chatCode.contains(".scrollEdgeEffectHidden(true)"))
check("🚫 反向⑦：看板 / 生活两页不许跟着关（用户只点了会话 + 聊天；那两页页头玻璃口径原样保留）",
      !code(dashboard).contains("scrollEdgeEffectHidden")
        && !code(life).contains("scrollEdgeEffectHidden"))
check("🚫 反向⑦′：两页都不得改用 scrollEdgeEffectStyle（.automatic/.soft 会把模糊放回来；本仓口径是隐藏、不是换档）",
      !sessionsCode.contains("scrollEdgeEffectStyle") && !chatCode.contains("scrollEdgeEffectStyle"))

// ── 8. 页头红点（任务中心「有未完成任务」角标）────────────────────
// 用户 2026-10-06 真机报「右上角任务中心红点超出胶囊了」：badge overlay 挂在**图标槽位**上，
// 而槽位顶 == 囊顶（HStack 与子项同高 34、垂直居中）⇒ 偏移的 y 取负就是把红点顶出囊外（原值 -3）。
// 本组**从源码解析 badge 常量按算式判**，不钉字面串 —— 将来改尺寸档不误伤，只有真越界才红。
func number(after key: String, in text: String) -> Double? {
    guard let r = text.range(of: key) else { return nil }
    let tail = text[r.upperBound...].drop { $0 == " " }
    // 支持负号：负偏移是「真正要判红的形态」，不能因为解析失败而让哨兵断言顶包
    let neg = tail.hasPrefix("-")
    let body = neg ? tail.dropFirst() : tail
    let digits = body.prefix { $0.isNumber || $0 == "." }
    guard !digits.isEmpty else { return nil }
    return Double((neg ? "-" : "") + digits)
}
let badgeDot = number(after: "static let badgeDot: CGFloat =", in: pillCode)
let badgeOffsetLine = pillCode.split(separator: "\n")
    .first { $0.contains("static let badgeOffset") }.map(String.init) ?? ""
let badgeOffW = number(after: "width:", in: badgeOffsetLine)
let badgeOffH = number(after: "height:", in: badgeOffsetLine)
let pillHeightNum = number(after: "static let height: CGFloat =", in: pillCode)
let edgePadNum = number(after: "static let edgePad: CGFloat =", in: pillCode)

check("⑧ 红点几何真源在（badgeDot / badgeOffset 两常量都能解析出数值）",
      badgeDot != nil && badgeOffW != nil && badgeOffH != nil
        && pillHeightNum != nil && edgePadNum != nil)
check("⑧ 红点完整落在囊内：0 ≤ offset.height 且 offset.height + dot ≤ 囊高（负值 = 骑在囊外，正是本轮缺陷形态）",
      (badgeOffH ?? -1) >= 0
        && (badgeOffH ?? 999) + (badgeDot ?? 999) <= (pillHeightNum ?? 0))
check("⑧ 红点横向不越囊右缘：offset.width ≤ 端部内边距 edgePad",
      (badgeOffW ?? 999) <= (edgePadNum ?? 0))
check("⑧ 红点尺寸/偏移走真源常量（不再写裸 7 / 裸 offset 值）",
      pillCode.contains(".frame(width: Self.badgeDot, height: Self.badgeDot)")
        && pillCode.contains(".offset(x: Self.badgeOffset.width, y: Self.badgeOffset.height)"))

// ── 9. 结果 ──────────────────────────────────────────────────
print("页头图标胶囊真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
