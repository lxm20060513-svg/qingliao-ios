// MARK: - 备忘录 / 待办清单图标美化真值表（v4.0.65 · 用户 2026-10-06 看对比稿拍板「待办走 B / 备忘走 A」）
//
// 口径（用户从渲染对比稿拍板，图在 /opt/data/scripts/ql_memo_todo/mock/out/memo_todo_icons.png）：
//   · **待办走 B**：列表行行首 15pt 完成圈 → **36pt 完成色块**（未完成浅灰底白圈 / 完成绿底白勾），
//     且元信息行的**来源图标 + 来源名染来源色**（时间仍灰）。页级单卡保留原来的 15pt 圈。
//   · **备忘走 A**：列表行行首加 **36pt 来源色块**（来源色底 + 白符号）；元信息行**保持灰**
//     （图钉 + 来源图标 + 时间一行不动）。页级单卡**完全不加**。
//   · 几何与记录分类卡 CategoryBadge 同族：36 / 圆角 0.305×边长 / 符号 0.5×边长 / 白符号 / a11yHidden。
//
// ⚠️ 最容易踩的两条（都是静默错，不报错）：
//   ① 来源配色**只有 SourceStyle 一个出口**。谁在别的文件再写一份来源→颜色 switch，
//      同一个「聊天」就会在待办页和备忘页长出两种蓝。
//   ② **页级单卡不许跟着放大**：用户 v3.9.37 明确要求备忘单卡「连图标也不要」（时间胶囊也删过一次），
//      待办同理不跟着换色块——首页卡行首突然变大很突兀，且等于替用户改设计。
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

/// 剥掉 `//` 行注释：注释里刻意写了「不要改回去」的警示，直接 grep 原文会被自己的注释判红
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

func slice(_ text: String, _ start: String, _ end: String? = nil) -> String {
    guard let a = text.range(of: start) else { return "" }
    let tail = text[a.lowerBound...]
    guard let e = end, let b = tail.range(of: e) else { return String(tail) }
    return String(tail[..<b.lowerBound])
}

func listSwift(_ dir: String) -> [String] {
    var out: [String] = []
    let e = FileManager.default.enumerator(atPath: dir)
    while let f = e?.nextObject() as? String {
        if f.hasSuffix(".swift") { out.append(dir + "/" + f) }
    }
    return out
}

let root = "qingliao/"
let style = src(root + "Core/SourceStyle.swift")
let styleCode = code(style)
let badges = src(root + "Features/Life/LifeBadges.swift")
let badgesCode = code(badges)
let ts = src(root + "Features/Life/TodoSection.swift")
let tsCode = code(ts)
let ms = src(root + "Features/Life/MemoSection.swift")
let msCode = code(ms)
let todoRow = slice(tsCode, "private struct TodoRowCard", "// MARK:")
let memoRow = slice(msCode, "private struct MemoNoteCard", "private struct MemoDetailSheet")

// ── ① 来源配色真源 SourceStyle ───────────────────────────────────────────
check("① 真源存在：enum SourceStyle", styleCode.contains("enum SourceStyle"))
check("① 单一入口：static func tint(_ source: String) -> Color",
      styleCode.contains("static func tint(_ source: String) -> Color"))
check("① chat → .blue", styleCode.contains("case \"chat\":            return .blue")
      || styleCode.contains("case \"chat\": return .blue"))
check("① ai 与 intent 同色（识别产出也是 AI 内容）",
      styleCode.contains("case \"ai\", \"intent\":    return .purple") || styleCode.contains("case \"ai\", \"intent\": return .purple"))
check("① orb → .teal", styleCode.contains("\"orb\"") && styleCode.contains(".teal"))
check("① bigbang → .indigo", styleCode.contains("\"bigbang\"") && styleCode.contains(".indigo"))
check("① meeting → .orange", styleCode.contains("\"meeting\"") && styleCode.contains(".orange"))
check("① 兜底 → .gray（手记/手动/未知）", styleCode.contains("default:") && styleCode.contains("return .gray"))
check("① 走系统语义色（深色模式自适应，同 RecordCategoryColor.palette 口径）——不得硬编码 hex",
      !styleCode.contains("Color(red:") && !styleCode.contains("#"))

// 唯一出口：来源色 switch 只许在 SourceStyle；其它文件不许直接写来源→色
let srcColors = [".blue", ".purple", ".teal", ".indigo", ".orange"]
var colorOffenders: [String] = []
for f in listSwift("qingliao") where !f.hasSuffix("Core/SourceStyle.swift") {
    let c = code(src(f))
    for sc in srcColors where c.contains("case \"chat\": return \(sc)") || c.contains("case \"bigbang\": return \(sc)") {
        colorOffenders.append(f + ":" + sc)
    }
}
check("🚫 反向①：来源→颜色映射只许在 SourceStyle（越界 \(colorOffenders.count) 处）", colorOffenders.isEmpty)

// ── ② 两个色块组件的几何（与记录分类卡同族） ────────────────────────────
check("② 组件存在：SourceBadge / TodoStatusBadge",
      badgesCode.contains("struct SourceBadge") && badgesCode.contains("struct TodoStatusBadge"))
check("② 几何单出口：BadgeShell（v4.0.65 审查后**真**只此一处：CategoryBadge 也改走它了）",
      badgesCode.contains("struct BadgeShell: ViewModifier"))
check("② 用 ViewModifier 而非顶层裸函数（泛型裸函数会被 v3.9.113 成员存在性表误判未定义）",
      !badgesCode.contains("func badgeShell"))
check("② 圆角 = 0.305×边长（36 → 11，同记录分类卡；走 size 参数）",
      badgesCode.contains("cornerRadius: size * 0.305"))
check("② 尺寸参数化 size（默认 36；记录分类卡传自己的档）",
      badgesCode.contains("var size: CGFloat = 36") && badgesCode.contains("frame(width: size, height: size)"))
check("② 符号字号 = 0.5×边长（36 → 18）", badgesCode.contains("size: 36 * 0.5"))
check("② 白符号（色块底上），且两处都设", badgesCode.components(separatedBy: ".foregroundStyle(.white)").count - 1 == 2)
check("② 状态色：完成 = .green；未完成 = **不透明** systemGray",
      badgesCode.contains("done ? .green") && badgesCode.contains("Color(uiColor: .systemGray)"))
check("🚫 反向②′：未完成态不得退回「半透明描边色当填充」（Color.secondary.opacity，白圈叠灰 ≈2.7:1 不达标）",
      !badgesCode.contains("Color.secondary.opacity"))
check("② 符号名由调用方传入（符号归数据域，组件不维护第二份映射）",
      badgesCode.contains("let symbol: String") && !badgesCode.contains("\"bubble.left.fill\""))
check("② a11y：色块隐藏（状态/来源在行内有文字或独立语义，不重复播报）",
      badgesCode.contains(".accessibilityHidden(true)"))
check("② 色真源：走 SourceStyle.tint（不自己写色）",
      badgesCode.contains("SourceStyle.tint(source)"))

// ── ③ 待办列表行（方案 B） ───────────────────────────────────────────────
check("③ 待办列表行行首用完成色块：TodoStatusBadge(done: item.done)",
      todoRow.contains("TodoStatusBadge(done: item.done)"))
check("③ 页级单卡（compact）保留原来的 15pt 圈（不跟着放大）",
      todoRow.contains("if compact {") && todoRow.contains("checkmark.circle.fill\" : \"circle\""))
check("🚫 反向③：compact 分支不得用色块（首页卡行首突然变大 = 替用户改设计）",
      !todoRow.contains("if compact {\n                TodoStatusBadge"))
check("③ 元信息：来源图标染来源色", todoRow.contains(".foregroundStyle(SourceStyle.tint(item.source))"))
check("③ 元信息：来源名也染来源色（图标+文字同色）",
      (todoRow.components(separatedBy: ".foregroundStyle(SourceStyle.tint(item.source))").count - 1) >= 2)
check("③ 时间为灰色基线（时间不跟着上色，不抢视觉）", todoRow.contains(".foregroundStyle(.tertiary)"))

// ── ④ 备忘列表行（方案 A） ───────────────────────────────────────────────
check("④ 备忘列表行行首加来源色块：SourceBadge(source: item.source, symbol: item.sourceIcon)",
      msCode.contains("SourceBadge(source: item.source, symbol: item.sourceIcon)"))
check("④ 色块挂在 if !compact 里（页级单卡不画）",
      memoRow.contains("if !compact {\n                SourceBadge(source: item.source, symbol: item.sourceIcon)\n            }"))
check("🚫 反向④：备忘行首色块只画一处（重复画 = 单卡也跟着长出色块）",
      memoRow.components(separatedBy: "SourceBadge(").count - 1 == 1)
// v4.0.65 审查（严重）：行首色块已表达来源，同在 MemoNoteCard 内的 metaRow 不得再画一枚灰来源图标
check("🚫 反向④′：备忘行内 item.sourceIcon 只出现一次（行首色块用掉；metaRow 不许再画）",
      memoRow.components(separatedBy: "item.sourceIcon").count - 1 == 1)

// 方案 A 的「元信息保持灰」：备忘元信息行不得出现来源色
check("🚫 反向⑤：备忘元信息行保持灰（方案 A 不动它，不许顺手染来源色）",
      !slice(msCode, "private var metaRow", "private struct").contains("SourceStyle.tint"))

// ── ⑤ 三处列表视觉同族 ──────────────────────────────────────────────────
check("⑤ 记录分类卡与来源色块**共用同一几何出口**（CategoryBadge 走 BadgeShell，不再各写一份）",
      code(src(root + "Features/Life/RecordSection.swift")).contains(".modifier(BadgeShell(size: size, color: RecordCategoryColor.tint(category)))")
      && badgesCode.contains("cornerRadius: size * 0.305") && badgesCode.contains("size: 36 * 0.5"))
check("🚫 反向⑤′：RecordSection 不得自带第二份色块几何（cornerRadius 各写一份 = 漂移源）",
      !code(src(root + "Features/Life/RecordSection.swift")).contains("cornerRadius: size * 0.305"))

print("备忘/待办图标真值表：\(passCount) 通过 / \(failCount) 失败")
exit(failCount == 0 ? 0 : 1)
