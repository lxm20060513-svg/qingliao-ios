// MARK: - 记录页卡真值表（v4.0.98 · 用户 2026-10-11 两条要求）
//
// 口径（用户原话：「记录卡片也改为点击向下展开内部卡片」「记录卡片也改成 22 的圆角」
//       后来追加「记录详情浮层里的行卡、月度统计卡一起改 22」）：
//   · 点页卡 = **就地向下展开**（`withAnimation(Motion.settle) { recordExpanded.toggle() }`），
//     不再直接开全屏「全部记录」浮层；浮层入口不丢 —— 挪到展开态底部那行「全部记录」
//     （`glass.showAll = true`，三层浮层互斥的收口一并保留）。
//   · 展开态的内部行卡**复用「全部记录」浮层同一张 `RecordRowCard`**。谁在这里另写一套行样式，
//     同一条记录就会在「页卡展开」与「全部记录」两处长得不一样（静默漂移，不报错）。
//   · 圆角：页卡 + 详情浮层行卡 + 月度统计卡**三处都 22**。`Radius.card`(16) 是**全局默认**，
//     顺手改它会连带设置页/会话页所有卡 → 反向断言钉死它仍是 16。
//   · 展开态一次画 `RecordCardExpand.maxRows` 条（写死数字散在几处，改上限只动这个常量）。
//
// 为什么值得钉：这几条都会**静默**错 —— 点卡又变回弹全屏（多一步）、行样式两处漂移、
// 圆角悄悄回退 16、展开条数改一处漏一处，都不报错，只等用户下次装包再吐槽一轮。
// 改这张卡时本表与第 86 段（记录分类图标）要一起看。
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

func countOf(_ needle: String, in hay: String) -> Int {
    hay.components(separatedBy: needle).count - 1
}

let root = "qingliao/"
let rs = src(root + "Features/Life/RecordSection.swift")
let rsCode = code(rs)
// ⚠️ 切片的**边界标记必须能在 `code()` 之后存在**（`// MARK:` / `///` 都是注释，被剥掉后切不到边，
//    slice() 会一路吃到文件末 —— 反向断言随即假红/假绿。踩过一次，别再写成注释当边界。）
let topCardSlice = slice(rsCode, "private var topCard", "private var recordCardExpandList")
let expandSlice = slice(rsCode, "private var recordCardExpandList", "private var categoryBreakdown")
let rootSlice = slice(rsCode, "private var root: some View", "private func deleteConfirm")

// ── ⓪ 切片自身收边正常（否则下面所有基于切片的断言都是假的） ──────────────
check("⓪ 切片收边正常：topCard / 展开态两段都取到了边界（不是一路吃到文件末）",
      !topCardSlice.isEmpty && topCardSlice.count < 5000
      && !expandSlice.isEmpty && expandSlice.count < 5000)
check("⓪ root 切片收边正常", !rootSlice.isEmpty && rootSlice.count < 2000)

// ── ① 点卡 = 就地向下展开（不再弹全屏浮层） ────────────────────────────────
check("① 页卡存在展开态 @State（recordExpanded）",
      rsCode.contains("@State private var recordExpanded = false"))
check("① 点卡 = 就地展开/收起（withAnimation(Motion.settle) + toggle）",
      topCardSlice.contains("withAnimation(Motion.settle) { recordExpanded.toggle() }"))
check("🚫 反向①：页卡按钮里不许再直接开「全部记录」浮层（点卡弹全屏 = 用户点名改掉的那一步）",
      !topCardSlice.contains("glass.showAll = true"))

// ── ② 展开态视图 + 挂在页卡正下方 ─────────────────────────────────────────
check("② 展开态视图存在（private var recordCardExpandList）",
      rsCode.contains("private var recordCardExpandList"))
check("② 展开态挂在页卡下方（root 里 if recordExpanded { recordCardExpandList }）",
      rootSlice.contains("if recordExpanded { recordCardExpandList }"))
check("② 收起态那一截（最近 1 条 +「还有 N 条」）只在未展开时画（否则第一条出现两次）",
      rsCode.contains("if !recordExpanded {"))

// ── ③ 内部行卡复用浮层同一张（不许第二套行样式） ──────────────────────────
check("③ 展开态内部行卡 = RecordRowCard(item: r)（与「全部记录」浮层同一张）",
      expandSlice.contains("RecordRowCard(item: r)"))
check("🚫 反向③：展开态不许自己重画行（CategoryBadge / 分类图标只该出现在 RecordRowCard 里）",
      !expandSlice.contains("CategoryBadge("))
check("③ 点内部卡 = 编辑这一笔（先自增会话号再上详情，与浮层行卡同语义）",
      expandSlice.contains("glass.editSession += 1") && expandSlice.contains("glass.detail = r"))

// ── ④ 浮层入口不丢 ────────────────────────────────────────────────────────
check("④ 展开态底部保留「全部记录」入口（glass.showAll = true）",
      expandSlice.contains("glass.showAll = true"))
check("④ 展开条数上限走常量 RecordCardExpand.maxRows（不散写数字）",
      expandSlice.contains("RecordCardExpand.maxRows") && rsCode.contains("enum RecordCardExpand"))

// ── ④′ 状态复位 + 展开行卡的按压/读屏（v4.0.98 审查两条 P2） ────────────────
check("④′ 记录被删空时复位展开态（否则下次新增第一条以「已展开」形态凭空出现）",
      rsCode.contains(".onChange(of: store.records.isEmpty)")
      && rsCode.contains("if empty { recordExpanded = false }"))
check("④′ 展开态行卡包 Button + PressStyle（这里不在 List 里：裸 onTapGesture 没有按压反馈、读屏不当按钮）",
      expandSlice.contains("RecordRowCard(item: r)") && expandSlice.contains(".buttonStyle(PressStyle())"))
check("🚫 反向④′：展开态行卡不许回到裸 onTapGesture",
      !expandSlice.contains("onTapGesture"))

// ── ⑤ 圆角 22（三处）+ 全局默认 16 不许动 ─────────────────────────────────
check("⑤ 记录页卡 + 详情行卡 + 月度统计卡三处圆角都 22（实得 \(countOf(".pastelCard(cornerRadius: 22)", in: rsCode)) 处）",
      countOf(".pastelCard(cornerRadius: 22)", in: rsCode) >= 3)
check("🚫 反向⑤：记录三张卡不许回退成默认 .pastelCard()（= 16，本轮用户点名的就是它）",
      !rsCode.contains(".pastelCard()"))
check("🚫 反向⑤′：Radius.card 全局默认仍是 16（改它=连带设置页/会话页所有卡）",
      code(src(root + "Theme/Radius.swift")).contains("static let card: CGFloat = 16"))

// ── ⑥ a11y 跟着状态变 ────────────────────────────────────────────────────
check("⑥ 读屏文案随展开态切换",
      rsCode.contains("recordExpanded ? \"点一下收起\" : \"点一下展开明细\""))

print("记录页卡真值表：\(passCount) 通过 / \(failCount) 失败")
exit(failCount == 0 ? 0 : 1)
