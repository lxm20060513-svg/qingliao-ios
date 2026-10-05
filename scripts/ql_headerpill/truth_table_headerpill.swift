// MARK: - 页头图标胶囊真值表（v4.0.62 · 2026-10-05 用户 4.0.61 真机复测拍板）
//
// 口径（用户从渲染对比稿里拍板，图在 /opt/data/scripts/ql_header_pill/mock/out/）：
//   尺寸 = **小二档**：图标 12pt + 横 11 / 纵 5 → 胶囊约 34×25pt（原 topBar 档：13 + 14/7 → 约 41×31）；
//        同排间距 12 → 8。
//   图标 = **圆环家族**（稿里的 B 组）：会话页 archivebox.circle / checkmark.circle / xmark.circle / plus.circle，
//        聊天页 list.bullet.circle / ellipsis.circle。
//        依据：这几个符号的位图画布实测**全 44px**，其余候选 39~53px 参差（archivebox 46 / checkmark 43 /
//        plus 40 / checklist 53 / tray 52 / list.bullet 48）——「光学方框不齐」正是用户说的"不协调"。
//   ⚠️ v4.0.61 曾以「外环图标 + 胶囊底 = 双圈」为由把外环去掉（ellipsis.circle → ellipsis）；
//      用户看过对比稿后**明确选了带外环的 B 组** → 该顾虑作废，**不要再按那条改回裸字形**（本表第 5 组反向钉死）。
//
// 为什么值得钉（这三处都会**静默**错，不报错，只让用户下次装包再吐槽一轮）：
//   ① 尺寸只有一个真源 HeaderPillIconButton.iconFont/hPad/vPad/spacing —— 谁"顺手"改回 .pill(.topBar)
//      或自己写 HStack(spacing: 12)，胶囊立刻回到 41×31，用户要的"调小一档"无声消失；
//   ② 三颗图标必须同族：混排（裸字形 + 带框）就是从 v4.0.61 一路被吐槽到 v4.0.62 的病根，肉眼不易复核；
//   ③ 会话页页头挂进滚动视图（滚边玻璃）只有**列表支**该挂：骨架/错误态/失败横幅是非滚动分支，
//      挂上去只是多一层没意义的玻璃 —— 有人"统一一下"把它挪到 VStack 层，页头玻璃就整页失效。
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
check("① 尺寸真源：iconFont 12", pillCode.contains("static let iconFont: CGFloat = 12"))
check("① 尺寸真源：hPad 11", pillCode.contains("static let hPad: CGFloat = 11"))
check("① 尺寸真源：vPad 5", pillCode.contains("static let vPad: CGFloat = 5"))
check("① 尺寸真源：spacing 8", pillCode.contains("static let spacing: CGFloat = 8"))
check("① 玻璃/描边走同一出口 glassPillStroke()（不新造玻璃写法）",
      pillCode.contains(".glassPillStroke()"))
check("① 命中区 ≥44pt（34×25 → hitArea44(h: 5, v: 11) = 44×46，净外扩 0）",
      pillCode.contains(".hitArea44(h: 5, v: 11)"))
check("① 图标前景色 = Color.accentColor（原由 pill(.accent) 提供；不走 pill 后必须自己带，否则由蓝变黑/白）",
      pillCode.contains(".foregroundStyle(Color.accentColor)"))
check("🚫 反向①：组件里又出现 .pill( 调用 → 判红（回退 = 胶囊涨回 41×31 大档）",
      !pillCode.contains(".pill(") && !pillCode.contains("PillSize."))

// ── 2. 会话页三颗：同族 + 同间距 ────────────────────────────────
let headerSlice = { () -> String in
    guard let a = sessionsCode.range(of: "private var sessionsHeaderBar"),
          let b = sessionsCode.range(of: "private var addButton") else { return "" }
    return String(sessionsCode[a.lowerBound..<b.lowerBound])
}()

check("② 会话页右上三颗（归档 + 多选 + 新建）都走 HeaderPillIconButton",
      sessionsCode.components(separatedBy: "HeaderPillIconButton(").count - 1 == 3)
check("② 同排间距走单一真源（不再各写 12）",
      sessionsCode.contains("HStack(spacing: HeaderPillIconButton.spacing)"))
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

// ── 3. 会话页页头：滚边玻璃只挂列表支 ───────────────────────────
check("③ 列表支页头挂进滚动视图（safeAreaBar → sessionsHeaderBar）",
      sessionsCode.contains(".safeAreaBar(edge: .top) { sessionsHeaderBar }"))
check("🚫 反向③：safeAreaBar 只许 1 处（骨架/错误态/失败横幅是非滚动分支，挂上只是白加一层玻璃）",
      sessionsCode.components(separatedBy: ".safeAreaBar(").count - 1 == 1)
check("🚫 反向③′：页头不许再回到 VStack 第一行（回退 = 列表内容从页头下面直接穿过、没有滚边模糊）",
      !sessionsCode.contains("VStack(spacing: 0) {\n            sessionsHeaderBar"))
check("③ 三条非滚动分支仍各自保留固定页头（骨架 / 错误态 / 失败横幅）",
      sessionsCode.components(separatedBy: "                sessionsHeaderBar\n").count - 1 >= 3)

// ── 4. 聊天页两颗：同族 + 同间距 ────────────────────────────────
check("④ 聊天页任务中心：checklist → list.bullet.circle",
      chatCode.contains("\"list.bullet.circle\"") && !chatCode.contains("\"checklist\""))
check("④ 聊天页更多：ellipsis → ellipsis.circle",
      chatCode.contains("\"ellipsis.circle\"") && !chatCode.contains("\"ellipsis\", a11y"))
check("④ 聊天页页头两颗同排间距走单一真源",
      chatCode.contains("HStack(spacing: HeaderPillIconButton.spacing)"))
check("④ 聊天页页头两颗都走 HeaderPillIconButton",
      chatCode.components(separatedBy: "HeaderPillIconButton(").count - 1 >= 2)

// ── 5. 滚边玻璃三页口径（生活试点 / 看板推广 / 会话页推广）──────
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

// ── 7. 结果 ──────────────────────────────────────────────────
print("页头图标胶囊真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
