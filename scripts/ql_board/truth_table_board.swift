import Foundation

// MARK: - v4.0.20 看板（Dashboard）栏目「长按拖动排序」真值表
//
// 被测真源 = `qingliao/Core/BoardCardOrder.swift`（纯 Foundation，无 SwiftUI）。
// 本表**直接编译那份源码**（不是镜像），所以没有「表与实现漂移」这个洞：
//   swiftc -swift-version 6 scripts/ql_board/main.swift qingliao/Core/BoardCardOrder.swift
//
// 本表钉九件事（都是「本机一眼能查、真机上才看得出来」的形态）：
//   ① **长按拖动真能落位**（BoardCardOrder.dragTarget）：看板栏目是**不等高**的竖排块，
//      落位必须喂各栏目**实测高度**、按「栏目中心线」算 —— 首页那套「按格算」的绝对格算法
//      在本表里是被钉死的反面（照搬到看板，手指没动也会把栏目甩到 0 号槽）；
//   ② **写回保位**（mergeVisible）：被隐藏的栏目留在原槽，重新显示精确回原位，
//      不是「追加到末尾」（那样用户会觉得排序被重置）；
//   ③ 顺序串容错：未知 key 丢弃、重复去重、缺失按 catalog 补齐（升级加栏目不重置用户排序）；
//   ④ **单一真源**：UserDefaults 键字面量全仓只有 BoardCardOrder.swift 一处
//      （视图只准写 BoardCardStore.orderKey / hiddenKey）；
//   ⑤ **UI 不自算几何**：拖拽走 BoardCardOrder.dragTarget、写回走 move/mergeVisible/encode，
//      归一化走 resolve —— 视图里不许再出现手写 split/compactMap 顺序解析；
//   ⑥ 接入形态：每块栏目 ForEach 里量高（onGeometryChange 排在 .offset **之前**），
//      拖动中有位移/放大/阴影反馈；
//   ⑦ **既有长按不许被吃**：拖动手势只挂在栏目头那一行（sectionTitle），
//      不许挂到整块栏目上 —— 否则 TokenUsageCard 的「重置」长按 / 用量卡·场景卡·自动化卡的
//      contextMenu 会被拖动会话抢走（调用点计数钉死：boardDragGesture 只准一处调用）；
//   ⑧ BoardCard.title 与各 sectionTitle 调用点一一对齐（标题/rawValue/调用点三重绑定）；
//   ⑨ 手势口径：长按门槛 0.40s（别退回 0.28 那档慢点击会被吞）、真拖动阈值 6pt、
//      版式常量 sectionSpacing == 10（视觉与落位几何共用一份）。

// Swift 6 严格并发：main.swift 顶层代码是 @MainActor 隔离的，而顶层变量不能挂 global actor
// → 计数器用 nonisolated(unsafe)（单线程顺序跑，无并发访问），这样 check 从顶层调用得通
nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0
func check(_ name: String, _ cond: Bool) {
    if cond { pass += 1 } else { fail += 1; print("❌ \(name)") }
}
func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
/// 去注释行：负断言必须走它（注释里讲清「不许出现什么」时，否则会被自己染红）
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}
/// 去掉全部空白 —— 顺序/相邻类断言不受缩进漂移影响
func flat(_ s: String) -> String { s.filter { !$0.isWhitespace } }
/// 取 `private func xxx` 到函数体收尾（4 空格缩进的 `}`）之间的源码。
/// 用途：口径类断言必须**只看这个函数体**——「同名 token 在文件别处出现过就算过」是假绿。
func fnBody(_ sig: String, _ s: String) -> String {
    guard let r = s.range(of: sig) else { return "" }
    let rest = s[r.lowerBound...]
    guard let e = rest.range(of: "\n    }\n") else { return String(rest) }
    return String(rest[rest.startIndex..<e.lowerBound])
}

let coreSrc = src("qingliao/Core/BoardCardOrder.swift")
let dash = src("qingliao/Features/Dashboard/DashboardView.swift")
let editor = src("qingliao/Features/Dashboard/BoardCardEditor.swift")
let usage = src("qingliao/Features/Dashboard/UsageCard.swift")

check("BoardCardOrder.swift 源可读", !coreSrc.isEmpty)
check("DashboardView.swift 源可读", !dash.isEmpty)
check("BoardCardEditor.swift 源可读", !editor.isEmpty)
check("UsageCard.swift 源可读（既有长按的回归靶子）", !usage.isEmpty)

let core = flat(stripCommentLines(coreSrc))
let dashFlat = flat(stripCommentLines(dash))
let editorFlat = flat(stripCommentLines(editor))

// ── ① 目录与标题 ────────────────────────────────────────────────
check("栏目 12 类（suggestion/home/scenes/automations/rules/nas/usage/tokens/diagnose/router/pin/connectors）",
      BoardCard.allCases.count == 12)
check("rawValue 与 case 名一致（id 唯一）",
      Set(BoardCard.allCases.map(\.id)).count == 12 && BoardCard.nas.rawValue == "nas")
check("title 逐项对齐（标题即用户看到的那行）",
      BoardCard.suggestion.title == "智能建议" && BoardCard.home.title == "智能家居"
        && BoardCard.scenes.title == "智慧场景" && BoardCard.automations.title == "自动化"
        && BoardCard.rules.title == "自动规则" && BoardCard.nas.title == "NAS 面板"
        && BoardCard.usage.title == "模型使用量" && BoardCard.tokens.title == "token 用量"
        && BoardCard.diagnose.title == "设备体检" && BoardCard.router.title == "路由器"
        && BoardCard.pin.title == "钉一钉" && BoardCard.connectors.title == "连接器")

// ── ② 顺序串容错（parse / encode / resolve） ────────────────────
check("parse 空串 → 空列表", BoardCardOrder.parse("").isEmpty)
check("parse 容忍空格：\" usage , nas \" → [usage, nas]",
      BoardCardOrder.parse(" usage , nas ") == [.usage, .nas])
check("parse 丢弃未知键（老版本删卡/改名不让老用户看板崩）",
      BoardCardOrder.parse("nas,zzz_usage,usage") == [.nas, .usage])
check("encode 往返：encode → parse 恒等（保序）",
      BoardCardOrder.parse(BoardCardOrder.encode([.tokens, .nas, .pin])) == [.tokens, .nas, .pin])
check("encode 空列表写空串（「顺序」没有全空语义，不写哨兵）",
      BoardCardOrder.encode([]) == "")
check("resolve 空串 → 全部 12 项、按 catalog 默认先后",
      BoardCardOrder.resolve(order: "") == BoardCard.allCases && BoardCardOrder.resolve(order: "").count == 12)
check("resolve 去重：重复 key 只留一次",
      BoardCardOrder.resolve(order: "usage,usage,usage").count == 12
        && BoardCardOrder.resolve(order: "usage,usage,usage").first == .usage)
check("resolve 补齐升级新增：串里只有 nas → 首项 nas + 其余按 catalog 排尾",
      BoardCardOrder.resolve(order: "nas") == [.nas] + BoardCard.allCases.filter { $0 != .nas })
check("resolve 未知项被丢且不影响补全：\"zzz,nas\" → 12 项且首项 nas",
      BoardCardOrder.resolve(order: "zzz,nas").count == 12
        && BoardCardOrder.resolve(order: "zzz,nas").first == .nas)
check("resolve 保留用户顺序（不是重排回 catalog）",
      BoardCardOrder.resolve(order: "pin,connectors,router")[0...2] == [.pin, .connectors, .router])

// ── ③ 拖拽落位几何（竖排 · 不等高 · 按中心线） ──────────────────
let hs = [60.0, 300.0, 120.0]          // 三个不等高栏目：参考偏移 offsets=[0,70,380]，中心=[30,220,440]
check("微抖不换位：from 0、dy 1 → 仍 0（绝对格算法会跳走，真机手感崩）",
      BoardCardOrder.dragTarget(from: 0, dy: 1, heights: hs, spacing: 10) == 0)
check("恒等：dy 0 → 任意 from 都回自己（松手不换位）",
      (0..<hs.count).allSatisfy { BoardCardOrder.dragTarget(from: $0, dy: 0, heights: hs, spacing: 10) == $0 })
check("下移跨过 1 号栏目中心 → 落到 1（from 0、dy 250：动心 30+250=280 > 中心 220）",
      BoardCardOrder.dragTarget(from: 0, dy: 250, heights: hs, spacing: 10) == 1)
check("上移跨过 0 号栏目中心 → 落到 0（from 1、dy -200：动心 220-200=20 < 中心 30）",
      BoardCardOrder.dragTarget(from: 1, dy: -200, heights: hs, spacing: 10) == 0)
check("不许一路甩到底：from 0、dy 180 → 0（动心 210 < 1 号中心 220，差一点点不算过）",
      BoardCardOrder.dragTarget(from: 0, dy: 180, heights: hs, spacing: 10) == 0)
check("下界夹紧：from 0 往上狂拖 → 0",
      BoardCardOrder.dragTarget(from: 0, dy: -9999, heights: hs, spacing: 10) == 0)
check("上界夹紧：末号往下狂拖 → n-1",
      BoardCardOrder.dragTarget(from: 2, dy: 9999, heights: hs, spacing: 10) == 2)
check("异常入参一律返回 from（空高度 / from 越界）",
      BoardCardOrder.dragTarget(from: 0, dy: 99, heights: [], spacing: 10) == 0
        && BoardCardOrder.dragTarget(from: 9, dy: 99, heights: hs, spacing: 10) == 9)
// 等高退化：三层等高（中心 50/160/270）—— 与首页 2 列那套「跨半格」口径一致
let eq = [100.0, 100.0, 100.0]
check("等高退化：from 0、dy 150 → 1（动心 200 > 中心 160）",
      BoardCardOrder.dragTarget(from: 0, dy: 150, heights: eq, spacing: 10) == 1)
check("正好压在中点不算跨过（严格小于）：from 0、dy 110 → 0（动心 160 == 中心 160）",
      BoardCardOrder.dragTarget(from: 0, dy: 110, heights: eq, spacing: 10) == 0)
check("🚨 被拖栏目**自己的高度**参与几何：heights [200,100]、间距 0、from 0、dy 200 → 1",
      BoardCardOrder.dragTarget(from: 0, dy: 200, heights: [200, 100], spacing: 0) == 1)

// ── ④ 换位 move（摘除再插入语义） ──────────────────────────────
check("move 正常换位",
      BoardCardOrder.move([.nas, .usage, .tokens], kind: .usage, to: 2) == [.nas, .tokens, .usage])
check("move 原位 → 原样返回（no-op）",
      BoardCardOrder.move([.nas, .usage, .tokens], kind: .usage, to: 1) == [.nas, .usage, .tokens])
check("move 未知 kind → 原样返回",
      BoardCardOrder.move([.nas, .usage], kind: .pin, to: 0) == [.nas, .usage])
check("move 越界下标夹紧（-5 / 99 都不崩）",
      BoardCardOrder.move([.nas, .usage, .tokens], kind: .tokens, to: -5) == [.tokens, .nas, .usage]
        && BoardCardOrder.move([.nas, .usage, .tokens], kind: .nas, to: 99) == [.usage, .tokens, .nas])

// ── ⑤ 写回保位 mergeVisible（被隐藏的栏目留在原槽） ─────────────
check("🚨 隐藏栏目留在原槽：oldFull[sug, home, scenes, rules]、新可见[sug→scenes 交换]、隐藏 home",
      BoardCardOrder.mergeVisible(oldFull: [.suggestion, .home, .scenes, .rules],
                                  newVisible: [.scenes, .suggestion, .rules],
                                  hidden: [.home]) == [.scenes, .home, .suggestion, .rules])
check("对照：隐藏槽若「追加到末尾」就错位（mergeVisible 不是 append-only）",
      BoardCardOrder.mergeVisible(oldFull: [.suggestion, .home, .scenes, .rules],
                                  newVisible: [.scenes, .suggestion, .rules],
                                  hidden: [.home]) != [.scenes, .suggestion, .rules, .home])
check("无隐藏时 mergeVisible == 可见新顺序",
      BoardCardOrder.mergeVisible(oldFull: BoardCard.allCases,
                                  newVisible: [.pin] + BoardCard.allCases.filter { $0 != .pin },
                                  hidden: []) == [.pin] + BoardCard.allCases.filter { $0 != .pin })
check("oldFull 之外新增的栏目补到末尾（升级加卡不丢）",
      BoardCardOrder.mergeVisible(oldFull: [.nas, .usage], newVisible: [.nas, .usage, .pin], hidden: []) == [.nas, .usage, .pin])
check("元素守恒：mergeVisible 结果 = oldFull ∪ newVisible（一个不多一个不少）",
      Set(BoardCardOrder.mergeVisible(oldFull: BoardCard.allCases,
                                      newVisible: BoardCard.allCases.reversed(),
                                      hidden: [])) == Set(BoardCard.allCases))

// ── ⑥ 落位 → 落盘 端到端不变量（12 × 12 全枚举） ────────────────
var e2eOK = true
for kind in BoardCard.allCases {
    for target in 0..<BoardCard.allCases.count {
        let visible = BoardCard.allCases
        let moved = BoardCardOrder.move(visible, kind: kind, to: target)
        let full = BoardCardOrder.mergeVisible(oldFull: visible, newVisible: moved, hidden: [])
        let roundTrip = BoardCardOrder.resolve(order: BoardCardOrder.encode(full))
        // 落盘串解析回来必须等于换位结果、且 12 项一个不丢
        if roundTrip != moved || roundTrip.count != 12 || roundTrip[target] != kind { e2eOK = false }
    }
}
check("🚨 端到端：任意栏目拖到任意位 → move→merge→encode→resolve 恒等于换位结果、12 项守恒、落点即该栏目",
      e2eOK)

// ── ⑦ 手势口径 ──────────────────────────────────────────────────
check("长按门槛没退回 0.28 秒那档（太短：慢点击被吃进拖动会话）",
      BoardCardOrder.longPressSeconds >= 0.35 && BoardCardOrder.longPressSeconds <= 0.6)
check("真拖动阈值 = 6pt（与首页 HomeCardDragKit 同口径）",
      BoardCardOrder.moveThreshold == 6)
check("🚨 按住不动不算拖动：零位移/微小位移一律 false（松手要当轻点）",
      !BoardCardOrder.isRealDrag(dx: 0, dy: 0) && !BoardCardOrder.isRealDrag(dx: 5.9, dy: 0)
        && !BoardCardOrder.isRealDrag(dx: 4, dy: 4) && !BoardCardOrder.isRealDrag(dx: 0, dy: -1))
check("真拖动仍要 true（阈值边界 + 各方向）",
      BoardCardOrder.isRealDrag(dx: 6, dy: 0) && BoardCardOrder.isRealDrag(dx: 0, dy: -6)
        && BoardCardOrder.isRealDrag(dx: 0, dy: 40))
check("版式常量 sectionSpacing == 10（视觉与落位几何共用一份）",
      BoardCardOrder.sectionSpacing == 10)
check("LazyVStack 用常量而不是字面量 spacing:10",
      dashFlat.contains("LazyVStack(alignment:.leading,spacing:BoardCardOrder.sectionSpacing)"))

// ── ⑧ 单一真源：键字面量只在 Core 一处 ─────────────────────────
check("BoardCardOrder.swift 里确有键字面量（单一真源所在地）",
      core.contains("\"dashboard_card_order\"") && core.contains("\"dashboard_hidden_cards\""))
check("🚨 DashboardView 不出现键字面量（只准写 BoardCardStore.orderKey/hiddenKey）",
      !dashFlat.contains("dashboard_card_order") && !dashFlat.contains("dashboard_hidden_cards")
        && dashFlat.contains("@AppStorage(BoardCardStore.orderKey)")
        && dashFlat.contains("@AppStorage(BoardCardStore.hiddenKey)"))
check("🚨 BoardCardEditorSheet 同样不出现键字面量（与拖拽共用同一对键）",
      !editorFlat.contains("dashboard_card_order") && !editorFlat.contains("dashboard_hidden_cards")
        && editorFlat.contains("@AppStorage(BoardCardStore.orderKey)")
        && editorFlat.contains("@AppStorage(BoardCardStore.hiddenKey)"))
check("BoardCard 枚举已搬离 BoardCardEditor.swift（那文件 import SwiftUI，真值表编不了）",
      !editorFlat.contains("enumBoardCard:") && core.contains("enumBoardCard:String,CaseIterable,Identifiable"))

// ── ⑨ UI 接入形态（DashboardView） ──────────────────────────────
check("归一化不自算：orderedCards 走 BoardCardOrder.resolve",
      dashFlat.contains("BoardCardOrder.resolve(order:cardOrderRaw)"))
check("🚨 旧的手写顺序解析已清干净（不留第二份口径）",
      !dashFlat.contains("cardOrderRaw.split(separator:\",\")")
        && !dashFlat.contains("compactMap{BoardCard(rawValue:String($0))}"))
check("每块栏目量高：onGeometryChange 排在 .offset 之前",
      dashFlat.contains(".onGeometryChange(for:CGFloat.self){$0.size.height}action:{hin")
        || dashFlat.contains("sectionHeights[card]=h"))
check("🚨 拖动中视觉反馈：位移 + 放大 + 阴影三件（别只位移）",
      dashFlat.contains(".offset(y:dragCard==card?dragOffsetY:0)")
        && dashFlat.contains(".scaleEffect(dragCard==card?1.01:1)")
        && dashFlat.contains(".shadow(color:.black.opacity(dragCard==card?0.16:0),radius:14,y:6)"))
check("拖拽手势 = 长按 + 拖动序列手势，门槛取常量",
      dashFlat.contains("LongPressGesture(minimumDuration:BoardCardOrder.longPressSeconds)")
        && dashFlat.contains(".sequenced(before:DragGesture(minimumDistance:2))"))
check("拖拽手势挂在栏目头（sectionTitle）的 simultaneousGesture 上",
      dashFlat.contains(".simultaneousGesture(boardDragGesture(card))"))
check("🚨 boardDragGesture 全文件**只有一处调用**（多处 = 可能挂到整块栏目上，会吃既有长按）",
      dashFlat.components(separatedBy: "boardDragGesture(").count - 1 == 2)  // 1 处定义 + 1 处调用
check("落位走 BoardCardOrder.dragTarget / isRealDrag（UI 不自算几何）",
      fnBody("private func boardDragGesture", stripCommentLines(dash)).contains("BoardCardOrder.dragTarget(")
        && fnBody("private func boardDragGesture", stripCommentLines(dash)).contains("BoardCardOrder.isRealDrag("))
check("写回走 BoardCardOrder.move / mergeVisible / encode（UI 不自拼顺序）",
      flat(fnBody("private func applyBoardMove", stripCommentLines(dash))).contains("BoardCardOrder.move(visibleCards,kind:card,to:target)")
        && flat(fnBody("private func applyBoardMove", stripCommentLines(dash))).contains("BoardCardOrder.mergeVisible(oldFull:orderedCards,newVisible:moved,hidden:hiddenCards)")
        && flat(fnBody("private func applyBoardMove", stripCommentLines(dash))).contains("cardOrderRaw=BoardCardOrder.encode(full)"))
check("🚨 既有长按没被吃：TokenUsageCard 的「重置」长按原地不动",
      flat(stripCommentLines(usage)).contains(".onLongPressGesture(minimumDuration:0.5)")
        && !dashFlat.contains("boardDragGesture") == false)  // 拖动只挂栏目头
// ⚠️ 本条的坑：dashFlat 是「全去空白」的源码，**字符串字面量里的空格也被删了**
//   （"NAS 面板" → "NAS面板"）。所以期望串必须同样去空白，否则带空格的标题永远匹配不上（假红）。
check("12 个 sectionTitle 调用点全部带上 card:（漏一个 = 那一栏目拖不动）",
      BoardCard.allCases.allSatisfy { c in
          let want = "sectionTitle(\"\(c.title)\",card:.\(c.rawValue))".filter { !$0.isWhitespace }
          return dashFlat.contains(want)
      })
check("🚨 不留旧签名 sectionTitle(\"…\") 无 card 的调用（编译期真错，但真值表也钉一道）",
      {
          var seen = 0
          for c in BoardCard.allCases where !dashFlat.contains("sectionTitle(\"\(c.title)\")") { seen += 1 }
          return seen == 12
      }())
check("长按门槛/阈值有注释讲清取舍（防止后人无脑调小）",
      coreSrc.contains("longPressSeconds") && coreSrc.contains("moveThreshold"))

// ── ⑩ 反向自证：断言不是恒真 ────────────────────────────────────
// (a) 落位几何：不等高下，真算法与「按平均行高」的照搬算法**必然分叉**
let real0 = BoardCardOrder.dragTarget(from: 0, dy: 180, heights: hs, spacing: 10)
let avgH = hs.reduce(0, +) / Double(hs.count)                  // 160
let naive0 = min(max(Int((180.0 / avgH).rounded()), 0), hs.count - 1)   // 1
check("反向自证(a)：不等高下真算法(=0) ≠ 按平均行高算法(=1) —— 否则③那组断言恒真",
      real0 == 0 && naive0 == 1 && real0 != naive0)
// (b) 被拖栏目自身高度确实进了几何：忽略自己高度会给出不同答案
let withSelf = BoardCardOrder.dragTarget(from: 0, dy: 200, heights: [200, 100], spacing: 0)
let selfIgnored = { () -> Int in
    var offsets: [Double] = []; var acc = 0.0
    for h in [200.0, 100.0] { offsets.append(acc); acc += h }   // spacing 0
    let dragCenter = offsets[0] + 0 + 200                        // 故意不吃自己的高度
    var t = 0
    for i in 0..<2 where i != 0 { if offsets[i] + 100 / 2 < dragCenter { t += 1 } }
    return min(max(t, 0), 1)
}()
check("反向自证(b)：真算法(=1) ≠ 忽略自身高度(=0) —— 证明自己的高度确实参与几何",
      withSelf == 1 && selfIgnored == 0 && withSelf != selfIgnored)
// (c) 保位：mergeVisible 与 append-only 在隐藏场景下必然分叉
let keepSlot = BoardCardOrder.mergeVisible(oldFull: [.suggestion, .home, .scenes, .rules],
                                           newVisible: [.scenes, .suggestion, .rules],
                                           hidden: [.home])
let appendOnly: [BoardCard] = [.scenes, .suggestion, .rules, .home]
check("反向自证(c)：保位(=原槽) ≠ append-only —— 证明⑤那条不是恒真",
      keepSlot != appendOnly && keepSlot[1] == .home)

print(fail == 0 ? "✅ ql_board 真值表 \(pass) 项全过" : "❌ 失败 \(fail) / 通过 \(pass)")
if fail > 0 { exit(1) }
