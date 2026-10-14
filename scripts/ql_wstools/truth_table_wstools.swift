// MARK: - v4.0.113 工作台·工具格真值表（入口搬迁：设置页 → 工作台工具格）
//
// 背景：用户 2026-10-15「把定时提醒和文件管理从设置移动到工作台的工具里」。
// 这类「入口搬迁」的坏法全是**编译不报、手点才现**：
//   ① 只搬入口不搬 sheet / 不搬 @State → 格子在、点下去毫无反应（sheet 永远弹不出来）；
//   ② 搬了工作台忘撤设置页 → 两处入口并存，以后改一处忘一处（旧入口迟早点进空页/旧逻辑）；
//   ③ 撤了行忘撤搜索索引 → 搜得到、点下去设置页没这行（比「搜不到」更坏）；
//   ④ 数错格数 / 写错标题 → 格子在、点了是别的东西；
//   ⑤ 顺手把功能本体删掉 → 聊天页长按「提醒我」的 QuickReminderSheet 一起废。
// 本表盯这五类，并把「8 格」钉死（加格减格都要显式改这里，防静默多/少一格）。
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

// ── ① 工具格：恰好 8 格，标题逐个钉死 ──
let grid = slice(wsCode, "private var toolsBoard", "private func toolCell")
check("切得出工具格区（切不出=下面几条在空转）", !grid.isEmpty)

let cellTitles = ["知识库", "网盘文件", "MCP 工具", "技能库", "定时任务", "邮件接入",
                  "定时提醒", "文件管理"]
check("工具格恰好 8 个 toolCell（当前 \(occurrences(grid, "toolCell("))）",
      occurrences(grid, "toolCell(") == 8)
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

// ── ② 接线：8 个格子各自都要有 sheet 挂载 + @State（少了就是「点了没反应」）──
let flags = ["showKB", "showCloud", "showMCP", "showSkills", "showTasks", "showMail",
             "showReminder", "showFiles"]
for flag in flags {
    check("\(flag)：@State 与 sheet 挂载都在",
          wsCode.contains("@State private var \(flag) = false")
          && wsCode.contains(".sheet(isPresented: $\(flag))"))
}
check("8 个工具体的 sheet 总数 = 8（多挂/漏挂都要显式改）",
      flags.reduce(0) { $0 + occurrences(wsCode, ".sheet(isPresented: $\($1))") } == 8)

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

print(failCount == 0 ? "\n🎉 工作台工具格真值表全部通过（\(passCount) 条）" : "\n❌ \(failCount) 个失败 / 共 \(passCount + failCount) 条")
exit(failCount == 0 ? 0 : 1)
