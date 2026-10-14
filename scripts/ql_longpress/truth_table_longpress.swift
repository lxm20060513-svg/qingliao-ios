// 长按锚定菜单的**手势优先级** —— 源级真值表（读源文件做护栏，不 import 项目代码）
//
// 为什么必须有这张表：**这是只有真机手指能发现的静默失效**。
//   `.onLongPressGesture` 等价于 `.gesture(...)`（普通优先级），挂在 `Button` 外层时会被
//   Button 内置手势整个吃掉 —— 长按毫无反应，而编译、`-parse`、其余护栏全绿。
//   2026-10-14 用户报「长期目标任务卡片无法编辑」，追问后答「长按卡片根本不出菜单」＝ 就是这条。
//
// 覆盖三条：① 手势必须高优先级（不得回退）② 出菜单时打 tap 抑制窗口 ③ 被长按卡片的 tap 首行读它。
// ⚠️ **必须 cwd = 仓库根**（下列路径是相对路径）。

import Foundation

var passCount = 0
var failCount = 0

func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉 `//` 行注释（注释里刻意复述了「原来那样是错的」，直接 grep 原文会被自己的注释判红）
func code(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            let head = line[line.startIndex..<r.lowerBound]
            if head.filter({ $0 == "\"" }).count % 2 == 1 { return String(line) }
            return String(head)
        }
        .joined(separator: "\n")
}

let hostSrc = src("qingliao/Features/Chat/AnchorMenuHost.swift")
let host = code(hostSrc)
let goals = code(src("qingliao/Features/Life/GoalsSection.swift"))

// ── ① 源可读（空了后面全是空真） ─────────────────────────────
check("① 宿主源可读（AnchorMenuHost.swift）", hostSrc.count > 3000)
check("① 一行式出口唯一（anchorLongPressMenu）", hostSrc.contains("func anchorLongPressMenu("))

// ── ② 手势优先级（本表的核心） ───────────────────────────────
check("② 长按走 .highPriorityGesture（普通优先级挂在 Button 外层 = 长按全无反应）",
      host.contains(".highPriorityGesture("))
check("② 反例：不得退回 .onLongPressGesture（它 = 普通优先级，Button 外层必失效）",
      !host.contains(".onLongPressGesture("))
check("② 长按门槛/漂移上限保持 0.42s / 22pt（与聊天页气泡同手感，且是「长按」与「按住就拖/滚动」共存的关键）",
      host.contains("minimumDuration: Double = 0.42") && host.contains("maximumDistance: CGFloat = 22"))

// ── ③ 出菜单后的 tap 抑制（高优先级下 Button 仍可能补送一次轻点） ──
check("③ 长按识别后打抑制窗口 markLongPressFired()",
      host.contains("AnchorMenuPresenter.shared.markLongPressFired()"))
check("③ 抑制三件套齐（suppressTapUntil / markLongPressFired / shouldDropTap）",
      host.contains("private(set) var suppressTapUntil: Date = .distantPast")
      && host.contains("func markLongPressFired()") && host.contains("func shouldDropTap() -> Bool"))

/// 取函数体（从签名到下一个 4 空格缩进的 `}`）
func body(_ text: String, from sig: String) -> String {
    guard let r = text.range(of: sig) else { return "" }
    let rest = String(text[r.upperBound...])
    let end = rest.range(of: "\n    }")?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
}

let toggleBody = body(goals, from: "private func toggleExpand() {")
let detailBody = body(goals, from: "private func openDetail(_ g: GoalItem) {")
check("③ 顶卡展开 toggleExpand 首 240 字符内读 shouldDropTap()（不读 = 菜单刚弹出又被展开区顶掉）",
      toggleBody.prefix(240).contains("AnchorMenuPresenter.shared.shouldDropTap()"))
check("③ 详情 openDetail 首 240 字符内读 shouldDropTap()（同上，别让详情浮层盖掉菜单）",
      detailBody.prefix(240).contains("AnchorMenuPresenter.shared.shouldDropTap()"))

print("长按锚定菜单手势优先级真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
