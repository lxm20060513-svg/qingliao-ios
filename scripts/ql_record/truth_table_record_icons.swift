// MARK: - 记录分类图标真值表（v4.0.65 · 用户 2026-10-05 看对比稿拍板「方案 B」）
//
// 口径（用户从渲染对比稿拍板，图在 /opt/data/scripts/ql_record/mock/out/record_icons.png）：
//   · 形态 = **方案 B**：行首**彩色圆角方块（36pt，圆角 = 0.305×边长 → 11）+ 白色分类符号
//     （字号 = 0.5×边长 → 18）**，且**保留分类名文字**（C 方案「去掉分类名」被否）；
//   · 淡色圆底 + 彩色符号（D 方案）被否；
//   · **配色不改**：底仍走 RecordCategoryColor.tint（按分类名 hash 取色）。本次只加图标，
//     把色板钉成语义色是另一件事——不要在同一批里顺手改（会牵动占比条/报告/环图）。
//   · 图标映射 = **全站唯一出口** RecordKit.categoryIcon：明细行 / 分类筛选胶囊 / 分类选择器共用。
//     谁「顺手」在别处再写一份 symbol 名，同一分类就会在不同位置长出不同图标（静默错，不报错）。
//   · 词表两套（ChatRecordKit.categoryTable 9 类 + BillScanKit.categories 含「居住/通讯/其他」变体名）
//     → 别名必须一并覆盖；未知/自定义分类兜底托盘（与「其它」同形），不要给自定义分类瞎猜图标。
//
// 为什么值得钉：这几处都会**静默**错——图标缺失 / 两处不一致 / 「全部」胶囊配错图标，
// 都不报错，只等用户下次装包再吐槽一轮。
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

/// 剥掉 `//` 行注释：注释里刻意写了「不要改回去」的警示，直接 grep 原文会被自己的注释判红。
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

/// 取 `start` 到 `end` 之间的源码切片（end 缺省 = 文件末）
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
let kit = src(root + "Core/RecordKit.swift")
let kitCode = code(kit)
let rs = src(root + "Features/Life/RecordSection.swift")
let rsCode = code(rs)
let rowSlice = slice(rsCode, "struct RecordRowCard", "struct RecordEditSheet")
let chipSlice = slice(rsCode, "private func chip(")

// ── ① 真源单一出口 ───────────────────────────────────────────────────────
check("① 真源存在：RecordKit.categoryIcon（全站分类图标唯一出口）",
      kitCode.contains("static func categoryIcon(_ raw: String) -> String"))
check("① 复用归一化：走 categoryLabel（不自己 trim 一套）",
      kitCode.contains("switch categoryLabel(raw)"))
check("① 映射：餐饮 → cup.and.saucer.fill", kitCode.contains("\"cup.and.saucer.fill\""))
check("① 映射：交通 → ticket.fill（用户点名的「车票」）", kitCode.contains("\"ticket.fill\""))
for (cat, sym) in [("购物", "bag.fill"), ("医疗", "cross.case.fill"), ("娱乐", "gamecontroller.fill"),
                   ("学习", "book.fill"), ("人情", "gift.fill"), ("日用", "basket.fill"),
                   ("通讯", "phone.fill")] {
    check("① 映射：\(cat) → \(sym)", kitCode.contains("\"\(sym)\""))
}
check("① 别名：居家 与 居住 同形（BillScanKit 词表用的是「居住」）",
      kitCode.contains("case \"居家\", \"居住\": return \"house.fill\""))
check("① 兜底：未知/自定义分类 → tray.fill（不给自定义分类瞎猜）",
      kitCode.contains("\"tray.fill\""))
check("① 兜底在 default 分支（不是某个具体分类的 case）",
      kitCode.contains("default:") && kitCode.contains("return \"tray.fill\""))

// 唯一出口：分类特有符号只许在 RecordKit 出现（其余文件越界 = 两份映射会漂移）
let specSymbols = ["cup.and.saucer.fill", "ticket.fill", "basket.fill",
                   "cross.case.fill", "gamecontroller.fill", "gift.fill"]
var offenders: [String] = []
for f in listSwift("qingliao") where !f.hasSuffix("Core/RecordKit.swift") {
    let c = code(src(f))
    for s in specSymbols where c.contains("\"\(s)\"") { offenders.append(f + ":" + s) }
}
check("🚫 反向①：分类符号名只许出现在 RecordKit（越界 \(offenders.count) 处：\(offenders.prefix(3).joined(separator: " / "))）",
      offenders.isEmpty)

// ── ② 色块组件 CategoryBadge 几何（照出稿） ──────────────────────────────
check("② 色块存在：struct CategoryBadge", rsCode.contains("struct CategoryBadge"))
check("② 默认 36pt（方案 B 定稿尺寸；不改行高：36 ≤ 两行文字高 37）",
      rsCode.contains("var size: CGFloat = 36"))
check("② 几何走共用出口 BadgeShell（v4.0.65 审查：原先这里逐字抄了 LifeBadges 的第二份）",
      rsCode.contains(".modifier(BadgeShell(size: size, color: RecordCategoryColor.tint(category)))")
      && !rsCode.contains("cornerRadius: size * 0.305"))
check("② 符号字号 = 0.5×边长（36 → 18，照出稿）",
      rsCode.contains("font(.system(size: size * 0.5"))
check("② 底 = 分类色 tint（作为 BadgeShell 的 color 传入，配色体系未动）",
      rsCode.contains("color: RecordCategoryColor.tint(category)"))
check("② 白符号（彩色符号 + 淡底 = D 方案，用户已否）",
      rsCode.contains(".foregroundStyle(.white)"))
check("② 走真源取符号：RecordKit.categoryIcon(category)",
      rsCode.contains("Image(systemName: RecordKit.categoryIcon(category))"))
check("② a11y：色块图标隐藏 —— 已随几何并入 BadgeShell 单出口（本文件不再自写）",
      rsCode.contains(".modifier(BadgeShell(size: size,"))

// ── ③ 明细行接入 ─────────────────────────────────────────────────────────
check("③ 明细行行首接入色块：CategoryBadge(category: item.category)",
      rowSlice.contains("CategoryBadge(category: item.category)"))
check("③ 空分类也画色块（不挂在 if 里，否则有/无图标行左边缘参差）",
      !rowSlice.contains("if !item.category.isEmpty {\n                CategoryBadge"))
check("③ 方案 B 保留分类名文字（C 方案已否）",
      rowSlice.contains("Text(RecordKit.categoryLabel(item.category))"))

// ── ④ 分类筛选胶囊 ───────────────────────────────────────────────────────
check("④ 胶囊配图标且走同一张表：Image(systemName: RecordKit.categoryIcon(v))",
      rsCode.contains("Image(systemName: RecordKit.categoryIcon(v))"))
check("④ 「全部」不配图标（value 为 nil 时跳过）", chipSlice.contains("if let v = value"))
check("④ 图标档位 tiny（胶囊 11pt 文字配 10pt 图标，不撑大胶囊）",
      rsCode.contains("font(.system(size: Typography.tiny, weight: .medium))"))

// ── ⑤ 两处分类 Picker ────────────────────────────────────────────────────
check("⑤ 两处分类 Picker 选项带图标 Label（编辑弹窗 + 固定支出弹窗）",
      rsCode.components(separatedBy: "Label(c, systemImage: RecordKit.categoryIcon(c)).tag(c)").count - 1 == 2)
check("⑤ 「未分类」项也带图标（兜底托盘）",
      rsCode.contains("Label(RecordKit.uncategorized, systemImage: RecordKit.categoryIcon(\"\")).tag(\"\")"))
check("🚫 反向⑤：分类 Picker 不得回退成裸 Text(c).tag(c)",
      !rsCode.contains("Text(c).tag(c)"))

print("记录分类图标真值表：\(passCount) 通过 / \(failCount) 失败")
exit(failCount == 0 ? 0 : 1)
