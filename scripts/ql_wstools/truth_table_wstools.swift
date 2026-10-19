// MARK: - v4.0.113 工作台·工具格真值表（入口搬迁：设置页 → 工作台工具格）
//
// 背景：用户 2026-10-15「把定时提醒和文件管理从设置移动到工作台的工具里」。
// 这类「入口搬迁」的坏法全是**编译不报、手点才现**：
//   ① 只搬入口不搬 sheet / 不搬 @State → 格子在、点下去毫无反应（sheet 永远弹不出来）；
//   ② 搬了工作台忘撤设置页 → 两处入口并存，以后改一处忘一处（旧入口迟早点进空页/旧逻辑）；
//   ③ 撤了行忘撤搜索索引 → 搜得到、点下去设置页没这行（比「搜不到」更坏）；
//   ④ 数错格数 / 写错标题 → 格子在、点了是别的东西；
//   ⑤ 顺手把功能本体删掉 → 聊天页长按「提醒我」的 QuickReminderSheet 一起废。
// 本表盯这五类，并把「9 格」钉死（加格减格都要显式改这里，防静默多/少一格）。
// v4.0.115 追加：第 9 格「会议纪要」（用户「会议纪要功能加入工作台的工具栏」）——
//   🚨 它**不在本页 present**：纪要卡唯一接收方是 ChatView 的 onReceive，而 ChatView 只在聊天页
//   那一支里 —— 工作台自己挂 fullScreenCover 的话，录完音整理好的卡 post 无人接、静默丢失，
//   页内却照旧显示「已放进会话」（v4.0.115 发包前审查抓到的 P1）。
//   本条格必须交给宿主回调 onOpenMinutes（= 长按球 case 6 同一条路）。
//   坏法 = 只加格子没接线 → 点了毫无反应；或自己挂全屏页 → 卡静默丢失。
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

/// 子串出现次数（本表要钉「恰好 8 格」这类断言，contains 分不出 7 个和 8 个）。
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

/// 去掉 `//` 与 `/* */` 注释，只留代码文本（注释里的标题字面量不许充当证据）。
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

/// 取 a 之后、b 之前的一段源码（切不出 = 返回空串，调用处先断言非空）
func slice(_ s: String, _ a: String, _ b: String) -> String {
    guard let ra = s.range(of: a),
          let rb = s.range(of: b, range: ra.upperBound..<s.endIndex) else { return "" }
    return String(s[ra.upperBound..<rb.lowerBound])
}

let wsCode = stripComments(src("qingliao/Features/Workspace/WorkspaceView.swift"))
let coreCode = stripComments(src("qingliao/Features/Settings/SettingsCore.swift"))
let indexCode = stripComments(src("qingliao/Core/SettingsSearchIndex.swift"))

check("工作台页源可读（空了下面全是空真）", !wsCode.isEmpty)
check("设置页源可读", !coreCode.isEmpty)
check("搜索索引源可读", !indexCode.isEmpty)

// ── ① 工具格：恰好 9 格，标题逐个钉死 ──
let grid = slice(wsCode, "private var toolsBoard", "private func toolCell")
check("切得出工具格区（切不出=下面几条在空转）", !grid.isEmpty)

let cellTitles = ["知识库", "网盘文件", "MCP 工具", "技能库", "定时任务", "邮件接入",
                  "定时提醒", "文件管理", "会议纪要", "Hermes 插件"]
// v4.0.124：第 10 格「Hermes 插件」（用户「工作台工具里增加 hermes 插件功能」）。
// 10 格 = 4 + 4 + 2，LazyVGrid 固定 4 列天然左对齐，布局口径不变。
check("工具格恰好 10 个 toolCell（当前 \(occurrences(grid, "toolCell("))）",
      occurrences(grid, "toolCell(") == 10)
check("「Hermes 插件」格图标/色钉死（shippingbox.fill + mint，前 9 格未用色）",
      grid.contains("toolCell(\"Hermes 插件\", symbol: \"shippingbox.fill\", tint: .mint)"))
for title in cellTitles {
    check("工具格有「\(title)」", grid.contains("toolCell(\"\(title)\""))
}
// 新增两格的图标与色沿用设置页原样（用户认色不认位置：pink=提醒、indigo=文件）
check("「定时提醒」沿用设置页原色/图标（bell.badge.fill + pink）",
      grid.contains("toolCell(\"定时提醒\", symbol: \"bell.badge.fill\", tint: .pink)"))
check("「文件管理」沿用设置页原色/图标（folder.fill + indigo）",
      grid.contains("toolCell(\"文件管理\", symbol: \"folder.fill\", tint: .indigo)"))
let mailIdx = grid.range(of: "toolCell(\"邮件接入\"")?.lowerBound ?? grid.endIndex
let remIdx = grid.range(of: "toolCell(\"定时提醒\"")?.lowerBound ?? grid.startIndex
check("两格排在末尾（用户可见顺序：新迁入的在最右）", mailIdx < remIdx)
check("4 列 LazyVGrid（v4.0.x 口径；别改回两行 HStack 各 3 格 = 每格被挤到 8.8pt）",
      grid.contains("count: 4") && !grid.contains("HStack") && !grid.contains("GridItem(.fixed"))

// ── ② 接线：每格都要有「@State + 呈现挂载」（少了就是「点了没反应」）──
//    前 8 格走 sheet；第 9 格「会议纪要」走 fullScreenCover（正文要占满整屏读）。
let flags = ["showKB", "showCloud", "showMCP", "showSkills", "showTasks", "showMail",
             "showReminder", "showFiles"]
for flag in flags {
    check("\(flag)：@State 与 sheet 挂载都在",
          wsCode.contains("@State private var \(flag) = false")
          && wsCode.contains(".sheet(isPresented: $\(flag))"))
}
check("8 个工具体的 sheet 总数 = 8（多挂/漏挂都要显式改）",
      flags.reduce(0) { $0 + occurrences(wsCode, ".sheet(isPresented: $\($1))") } == 8)
check("「会议纪要」格：走宿主回调 onOpenMinutes（声明 + 调用都在）",
      wsCode.contains("var onOpenMinutes: (() -> Void)? = nil")
      && wsCode.contains("{ onOpenMinutes?() }"))
check("🚫 工作台不许自己挂纪要全屏页 / 自己存 showMinutes（ChatView 不在树 → 卡静默丢失 + 假「已放进会话」）",
      !wsCode.contains(".fullScreenCover(isPresented: $showMinutes)")
      && !wsCode.contains("private var showMinutes"))

// ── ③ 新迁入两格挂在 workspaceCold1，且 detents 与设置页时代逐字同口径 ──
let cold1 = slice(wsCode, "private func workspaceCold1", "private func workspaceCold2")
check("切得出 workspaceCold1（切不出=下面冷组断言在空转）", !cold1.isEmpty)
check("「定时提醒」sheet 挂在 workspaceCold1（QuickReminderSheet）",
      cold1.contains(".sheet(isPresented: $showReminder)") && cold1.contains("QuickReminderSheet()"))
check("「文件管理」sheet 挂在 workspaceCold1（FilesManagerSheet）",
      cold1.contains(".sheet(isPresented: $showFiles)") && cold1.contains("FilesManagerSheet()"))
check("两格 sheet 都是 [.medium, .large] 两档（设置页时代口径；锁死 .large 会被用户当全屏弹窗挑）",
      occurrences(cold1, ".presentationDetents([.medium, .large])") >= 4)
check("提醒 sheet 内长按站点仍带 anchorMenuHost（v4.0.105 口径，根层 zIndex 画不到 sheet 之上）",
      cold1.contains("QuickReminderSheet()") && cold1.contains(".anchorMenuHost()"))
// §77 类型栈深度护栏：冷组顶层修饰器 >4 会让类型推断膨胀（4.0.47 真机启动闪退就是这个）
let cold2 = slice(wsCode, "private func workspaceCold2", "private func ")
check("workspaceCold1 顶层 ≤4 条（当前 \(occurrences(cold1, ".sheet("))）",
      !cold1.isEmpty && occurrences(cold1, ".sheet(") <= 4)
check("workspaceCold2 顶层 ≤4 条（当前 \(occurrences(cold2, ".sheet("))）",
      !cold2.isEmpty && occurrences(cold2, ".sheet(") <= 4)
// v4.0.124：第 10 格新增「Hermes 插件」→ 允许第 3 组冷层，但**只准装工具格 sheet**：
// 纪要页呈现仍只有一个真源（DockTabView.openMinutesPage），cold3 里出现 Minutes 一律判红。
// 🚫 再加第 11 格时请合并 sheet 槽位，不许开 cold4（body 泛型层次继续涨就是 §77 的形态）。
let cold3 = slice(wsCode, "private func workspaceCold3", "private func ")
check("workspaceCold3 只承载工具格 sheet（≤4 条，且不得出现纪要页）",
      !cold3.isEmpty && occurrences(cold3, ".sheet(") <= 4
      && cold3.contains("PluginsSheet()") && !cold3.contains("Minutes"))
check("🚫 工作台最多 3 组冷层（当前 \(occurrences(wsCode, "private func workspaceCold")) 组）",
      occurrences(wsCode, "private func workspaceCold") == 3)
// v4.0.115 审查⑤：body 顶层的冷组挂载点原先没人数上限 —— 一路 background(workspaceColdN()) 加下去
// 又会撞 §77 类型栈深度（4.0.47 真机启动闪退的形态）。钉住：body 顶层就这 2 组，别再加。
check("body 顶层 background(workspaceCold…) 挂载点 == 3（v4.0.124 加第 3 组；再多就撞 §77）",
      occurrences(wsCode, ".background(workspaceCold") == 3)

// ── ④ 设置页零残留（入口、sheet、@State、搜索 case 四面一处不留）──
check("反例：设置页不再引用 showQuickReminder / showFilesManager（含 @State 与 case）",
      !coreCode.contains("showQuickReminder") && !coreCode.contains("showFilesManager"))
check("反例：设置页不再有「定时提醒」「文件管理」入口行",
      !coreCode.contains("title: \"定时提醒\"") && !coreCode.contains("title: \"文件管理\""))
check("反例：设置页不再挂 QuickReminderSheet / FilesManagerSheet",
      !coreCode.contains("QuickReminderSheet(") && !coreCode.contains("FilesManagerSheet("))
check("反例：搜索索引里不再有 quickReminder / filesManager 两条目（搜得到=点进去没这行）",
      !indexCode.contains("\"quickReminder\"") && !indexCode.contains("\"filesManager\""))

// ── ⑤ 功能本体仍在（搬迁只搬入口，别把本体一起删）──
check("本体仍在：QuickReminderSheet 定义 + 聊天页「提醒我」/ 会话页复用同一 sheet",
      src("qingliao/Features/Settings/SettingsLifeCards.swift").contains("struct QuickReminderSheet: View")
      && src("qingliao/Features/Chat/ChatView.swift").contains("QuickReminderSheet(presetText:")
      && src("qingliao/Features/Sessions/SessionsView.swift").contains("QuickReminderSheet(presetText:"))
check("本体仍在：FilesManagerSheet 定义（上传目录浏览 / 预览 / 分享 / 重命名 / 删除）",
      src("qingliao/Features/Settings/SettingsData.swift").contains("struct FilesManagerSheet: View"))
check("本体仍在：定时提醒仍走本地通知调度器（QuickReminderStore 纯本地，App 不在也响）",
      occurrences(src("qingliao/Core/NotificationHelper.swift"), "QuickReminderStore.shared.reconcile()") >= 1
      && src("qingliao/Features/Settings/SettingsLifeCards.swift").contains("QuickReminderStore.openSystemNotificationSettings()"))

check("工具格间距：左右 Spacing.lg(10) / 上下 Spacing.xl(12)（v4.0.114 用户「都拉开点，保持视觉平衡」；退回 sm/md=6/8 就是又挤回去了）",
      grid.contains("GridItem(.flexible(), spacing: Spacing.lg), count: 4)")
        && grid.contains("spacing: Spacing.xl) {"))

// ── v4.0.114（用户「文件管理增加批量删除」）──────────────────────────────────
// 事故形态：只有单项删除 → 用户清一屏截图/旧包只能一个个点；加批量后又容易踩两个坑：
// ① 选择态下左边还是「完成」（一点把弹窗关上，勾的全白勾）② 进子目录不清勾选（把上一层选中的东西删掉）。
let dataSrc = src("qingliao/Features/Settings/SettingsData.swift")
check("批量删除：选择态 + 已勾集合 + 「删除(N)」入口",
      dataSrc.contains("@State private var selecting = false")
        && dataSrc.contains("@State private var picked: Set<String> = []")
        && dataSrc.contains("Text(picked.isEmpty ? \"删除\" : \"删除(\\(picked.count))\")"))
check("批量删除：选择态下左键让位「取消」（别一点就关掉整个弹窗）",
      dataSrc.contains("Button(\"取消\") { selectedExit() }"))
check("批量删除：逐项调单删接口 + 失败不中断（收进提示，不整批回滚）",
      dataSrc.contains("private func performBatchDelete() async")
        && dataSrc.contains("for e in targets {")
        && dataSrc.contains("failed.append(e.name"))
check("批量删除：回读后丢弃不在当前目录的勾选（防把上一层选择带下来删）",
      dataSrc.contains("picked = picked.intersection(Set(entries.map { $0.path }))"))
check("v4.0.114（审查 P1）：批量确认与错误提示**共用一条 alert**（同视图挂两条 .alert 只有最后一条生效）",
      dataSrc.contains("confirmBatchDelete ? \"删除 \\(picked.count) 项？\" : \"操作未完成\"")
        && dataSrc.contains("isPresented: alertPresented)")
        && dataSrc.contains("get: { alertText != nil || confirmBatchDelete }"))
check("🚫 不许退回两条 .alert 分挂（「操作未完成」排在前面会被吞，批量删失败用户毫无提示）",
      !dataSrc.contains("isPresented: $confirmBatchDelete)"))
check("选择态下行的点击 = 勾选（不是打开），且「…」菜单收起",
      dataSrc.contains("Button(action: selecting ? onTogglePick : onOpen)")
        && dataSrc.contains("if !selecting {\n                Menu {"))

// ── v4.0.114（用户「AI 生产的其他产物也要加到产物里」）──────────────────────
// 事故形态：产物库只列 office 根（office-mcp 写的文档），AI 出的图/代码/数据全看不到。
// 改双根后要防两件事：① 有人图省事写回单根；② 把 parent 换回 currentPath
// （parseEntries 拼出的 path 少了根前缀 → 下载口 404「文件不存在」，v4.0.108 真机才暴露过的坑）。
let wsSrc = src("qingliao/Features/Workspace/WorkspaceView.swift")
check("产物库双根：office（AI 文档）+ artifacts（AI 其它产物）",
      wsSrc.contains("private static let artifactRoots = [\"office\", \"artifacts\"]"))
check("🚫 不许退回单根 artifactRoot（写回单根 = AI 其它产物又看不见了）",
      !wsSrc.contains("private static let artifactRoot ="))
check("产物库根层 = 两根合并，且**一个根挂了不拖垮另一个**",
      wsSrc.contains("for root in Self.artifactRoots {")
        && wsSrc.contains("case .ok(let list): okCount += 1; merged += list")
        && wsSrc.contains("if okCount == 0 {"))
check("v4.0.114（审查 P2）：按根计数判失败 —— 某根正常返回**空目录**不算失败，只有全挂才报错",
      wsSrc.contains("var okCount = 0")
        && wsSrc.contains("if !keepOnFailure {\n                    failureText = firstErr"))
check("🚫 不许退回 merged.isEmpty 判失败（空目录会被误判成失败）",
      !wsSrc.contains("if merged.isEmpty && !firstErr.isEmpty {"))
check("产物库：进目录时从 entry.path 拆「根 + 层」（合并后光靠名字不知道进的是哪个根）",
      wsSrc.contains("currentRoot = comps.first ?? \"\"")
        && wsSrc.contains("dirStack = Array(comps.dropFirst())"))
check("产物库：合并列表有稳定顺序（目录在前、按名）——否则刷新一次顺序就跳",
      wsSrc.contains("private static func stableOrder")
        && wsSrc.contains("if a.isDir != b.isDir { return a.isDir }"))
check("产物库分类覆盖非文档产物（代码/数据/压缩包/音频/其他）",
      wsSrc.contains("case code = \"代码\"") && wsSrc.contains("case data = \"数据\"")
        && wsSrc.contains("case archive = \"压缩包\"") && wsSrc.contains("case audio = \"音频\"")
        && wsSrc.contains("case other = \"其他\""))
check("🚫 根层（两根合并）下不显示「返回上一级」（那层没有上级）",
      wsSrc.contains("if !atRootLevel { backRow }"))

print(failCount == 0 ? "\n🎉 工作台工具格真值表全部通过（\(passCount) 条）" : "\n❌ \(failCount) 个失败 / 共 \(passCount + failCount) 条")
exit(failCount == 0 ? 0 : 1)
