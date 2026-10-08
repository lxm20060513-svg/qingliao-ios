// P4 冷启动（工作模式 · 条目 17 / 18）真值表 —— Linux 本地预检用
//
// 编译运行（仓库根目录，权威入口是 check_swift.sh 第 95 段）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_onboard \
//       scripts/ql_onboard/truth_table_onboard.swift \
//       qingliao/Core/WorkbenchOnboard.swift qingliao/Core/WorkbenchScope.swift \
//       qingliao/Core/HomeCardOrder.swift
//   ⚠️ HomeCardOrder.swift 必须有：WorkbenchScope 的快捷卡清单用它定义的 HomeCardKind。
//   ⚠️ 多文件编译只有 main.swift 允许顶层代码 → 段 95 会先把它复制成 main.swift。
//   ⚠️ 多行断言块写成**具名函数**再由 `check("名字", fn())` 调用：顶层代码里「多行闭包当普通实参」
//      与「多行闭包尾随」在 Swift 6.0.3 上都有解析/推断坑，具名函数最稳。
//
// 这张表盯什么（P4 全靠文案与闸门，编译器一个错都不会报）：
//   ① **每页都必须有**：三页少一页 = 某页冷启动还是空白（条目 17 未落地）；
//   ② **说清围着什么事转**：不许用「暂无数据」「--」「0」这种无信息量占位（条目 18 + P1 铁律）；
//   ③ **一个动作要真能开始**：动作落点是「把示例指令投进输入框」，不是装饰按钮；跨页时切到会话页；
//      **绝不自动聚焦键盘**（键盘已开保持、未开不弹）；
//   ④ **生活模式零变更**（用户红线）：生活模式下三页一个字都不许多；
//   ⑤ **文案只此一处**：视图里出现第二份字面量 = 迟早漏改。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var total = 0
func check(_ name: String, _ cond: Bool) {
    total += 1
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉**整行注释**后的源码（注释里举的例子不该被当成违规；代码里真出现就是真违规）
func code(_ src: String) -> String {
    src.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

/// 仓库内所有 .swift（相对路径），用于「文案单一真源 / 接线不许散落」这类全仓断言
func swiftFiles() -> [String] {
    var out: [String] = []
    guard let en = FileManager.default.enumerator(atPath: "qingliao") else { return out }
    for case let p as String in en where p.hasSuffix(".swift") { out.append("qingliao/\(p)") }
    return out.sorted()
}

let ONBOARD = "qingliao/Core/WorkbenchOnboard.swift"
let CARD = "qingliao/Features/OnboardGuideCard.swift"
let SEEDBOX = "qingliao/Core/ComposerSeedBox.swift"
let CHATVIEW = "qingliao/Features/Chat/ChatView.swift"
let LIFEVIEW = "qingliao/Features/Life/LifeView.swift"
let BOARDVIEW = "qingliao/Features/Dashboard/DashboardView.swift"

let onboardSrc = code(read(ONBOARD))
let cardSrc = code(read(CARD))
let seedSrc = code(read(SEEDBOX))
let chatSrc = code(read(CHATVIEW))
let lifeSrc = code(read(LIFEVIEW))
let boardSrc = code(read(BOARDVIEW))

let pages = OnboardPage.allCases

// ─────────────────────────────────────────────────────────────────────────────
// A. 口径：三页各有且只有一张卡（条目 17）
// ─────────────────────────────────────────────────────────────────────────────

func t1() -> Bool {
    WorkbenchScope.adopt(.work)
    defer { WorkbenchScope.resetForTesting() }
    let cards = pages.map { WorkbenchOnboard.guide(for: $0, empty: true) }
    return cards.allSatisfy { $0 != nil } && Set(WorkbenchOnboard.table.keys) == Set(pages)
}
check("A1 工作模式 + 该页还空着 → 三页各给一张卡（少一页 = 那页仍是空白）", t1())

func t2() -> Bool {
    WorkbenchScope.resetForTesting()
    return pages.allSatisfy { WorkbenchOnboard.guide(for: $0, empty: true) == nil }
        && WorkbenchOnboard.active == false
}
check("A2 生活模式：三页一张都不出（生活页观感零变更 —— 用户红线）", t2())

func t3() -> Bool {
    WorkbenchScope.adopt(.work)
    defer { WorkbenchScope.resetForTesting() }
    return pages.allSatisfy { WorkbenchOnboard.guide(for: $0, empty: false) == nil }
}
check("A3 该页已经有内容 → 全部收起（引导只在空态出现，不长期占地方）", t3())

func t4() -> Bool {
    WorkbenchScope.adopt(.work)
    defer { WorkbenchScope.resetForTesting() }
    return pages.allSatisfy { page in
        let g = WorkbenchOnboard.table[page]
        return g != nil
    }
}
check("A4 三页文案在 `table` 里齐备（视图拿不到 nil 才能接线）", t4())

// ─────────────────────────────────────────────────────────────────────────────
// B. 条目 18：一句话要说清「这台子围着什么事转」
// ─────────────────────────────────────────────────────────────────────────────

func t5() -> Bool {
    let banned = ["暂无", "没有", "--", "0", "空"]
    return pages.allSatisfy { page in
        guard let g = WorkbenchOnboard.table[page] else { return false }
        return !banned.contains(where: { g.title.contains($0) || g.line.contains($0) })
    }
}
check("B1 文案里不出现「暂无 / 没有 / -- / 0 / 空」这类无信息量占位（P1 铁律延伸）", t5())

func t6() -> Bool {
    pages.allSatisfy { page in
        guard let g = WorkbenchOnboard.table[page] else { return false }
        return (2...12).contains(g.title.count) && g.line.count >= 10 && g.line != g.title
    }
}
check("B2 标题是一句「这页在管什么」（2–12 字），补句另有内容且不重复标题", t6())

func t7() -> Bool {
    let pagesWord = ["会话": "干活", "life": "你自己的东西", "board": "家里"]
    guard let chat = WorkbenchOnboard.table[.chat],
          let life = WorkbenchOnboard.table[.life],
          let board = WorkbenchOnboard.table[.board] else { return false }
    return chat.title.contains(pagesWord["会话"]!)
        && life.title.contains(pagesWord["life"]!)
        && board.title.contains(pagesWord["board"]!)
}
check("B3 三页说清各自围着什么转（会话=干活 / 生活=你自己的东西 / 看板=家里）", t7())

func t8() -> Bool {
    let titles = pages.compactMap { WorkbenchOnboard.table[$0]?.title }
    let seeds = pages.compactMap { WorkbenchOnboard.table[$0]?.seed }
    return Set(titles).count == 3 && Set(seeds).count == 3
}
check("B4 三页文案两两不重复（防复制粘贴出一致的「万金油」句子）", t8())

func t9() -> Bool {
    pages.allSatisfy { page in
        guard let g = WorkbenchOnboard.table[page] else { return false }
        let t = g.seed
        return !t.isEmpty && !t.contains("--") && t.count >= 6 && t.count <= 40
    }
}
check("B5 每页示例指令都非空、不含占位符、长度收在可编辑范围（6–40 字）", t9())

// ─────────────────────────────────────────────────────────────────────────────
// C. 条目 17：一个动作 —— 落点与跨页跳转
// ─────────────────────────────────────────────────────────────────────────────

func t10() -> Bool {
    guard let chat = WorkbenchOnboard.table[.chat],
          let life = WorkbenchOnboard.table[.life],
          let board = WorkbenchOnboard.table[.board] else { return false }
    // 三页落点都是会话页；**每张卡还必须知道自己在哪一页** —— 卡片靠它判「要不要顺手切页」。
    // 曾经写成 `guide.target != .chat`：三页 target 都 .chat → 条件恒 false → 跨页点动作页面不动
    // （观感＝按钮没反应）。这条断言把「page 必须与所在页一致」钉死。
    return chat.target == .chat && life.target == .chat && board.target == .chat
        && chat.page == .chat && life.page == .life && board.page == .board
}
check("C1 落点：会话页原地（不跳），生活 / 看板都切到会话页（动作要能接着往下说）", t10())

func t11() -> Bool {
    pages.allSatisfy { page in
        guard let g = WorkbenchOnboard.table[page] else { return false }
        return !g.action.isEmpty && g.action.count <= 8
    }
}
check("C2 动作按钮文案短而具体（≤8 字，能一眼看懂点下去干什么）", t11())

func t12() -> Bool {
    cardSrc.contains("if guide.page != .chat { QingliaoRouteHandoff.request(route(guide.target)) }")
        && cardSrc.contains("ComposerSeedBox.shared.put(guide.seed)")
        && !cardSrc.contains("if guide.target != .chat")
}
check("C3 引导卡：不在会话页时先切到会话页再投示例指令（判定用本卡所在页 `page`，不是死分支 `target`）", t12())

func t13() -> Bool {
    // 只查「取走示例指令」这条路径：别的交互（用户主动点输入框等）本来就会设焦点，不在本项范围
    guard let r = chatSrc.range(of: ".onChange(of: seedBox.text)") else { return false }
    let seg = String(chatSrc[r.lowerBound...].prefix(600))
    return !seg.contains("inputFocus") && !cardSrc.contains("inputFocus")
}
check("C4 🚨 灌示例指令这条路径绝不自动聚焦键盘（键盘已开保持、未开不弹 —— 用户口径）", t13())

func t14() -> Bool {
    let hits = swiftFiles().filter { code(read($0)).contains("case .board: return .dashboard") }
    return hits == [CARD] && cardSrc.contains("private func route(_ page: OnboardPage)")
}
check("C5 页 → 路由的映射只此一处（口径层不依赖 UI 类型，映射留在卡里）", t14())

func t15() -> Bool {
    seedSrc.contains("defer { text = nil }") && seedSrc.contains("private(set) var text: String?")
        && seedSrc.contains("func put(_ seed: String)")
}
check("C6 投递位取走即清（不因 body 重算重复灌、不残留上一次的句子）", t15())

func t16() -> Bool {
    let putters = swiftFiles().filter { code(read($0)).contains("ComposerSeedBox.shared.put(") }
    let takers = swiftFiles().filter { code(read($0)).contains("seedBox.take()") }
    return putters == [CARD] && takers == [CHATVIEW]
}
check("C7 投递位只有一个投手（引导卡）与一个取手（会话页），别处 0 处", t16())

func t17() -> Bool {
    guard let r = chatSrc.range(of: "private func chatColdChrome15()") else { return false }
    let seg = String(chatSrc[r.lowerBound...].prefix(900))
    return seg.contains(".onChange(of: seedBox.text)")
        && seg.contains(".onAppear {")            // 落树兜底：跨页投递时会话页可能还没进树
        && seg.contains("guard let seed = seedBox.take() else { return }")
        && seg.contains("inputText = seed")
        && chatSrc.contains("@State var seedBox = ComposerSeedBox.shared")
}
check("C8 会话页取走即填进输入框（不替用户发送：填完还能改），且落树时兜底再取一次", t17())

// ─────────────────────────────────────────────────────────────────────────────
// D. 三页接线（各页自己给「空不空」，口径文件不读数据）
// ─────────────────────────────────────────────────────────────────────────────

func t18() -> Bool {
    chatSrc.contains("WorkbenchOnboard.guide(for: .chat, empty: chat.messages.isEmpty)")
}
check("D1 会话页：没消息 → 引导（判定输入 = 消息为空）", t18())

func t19() -> Bool {
    lifeSrc.contains("WorkbenchOnboard.guide(for: .life, empty: lifeIsEmpty)")
        && lifeSrc.contains("MemoStore.shared.memos.isEmpty")
        && lifeSrc.contains("TodoStore.shared.todos.isEmpty")
        && lifeSrc.contains("HabitStore.shared.habits.isEmpty")
        && lifeSrc.contains("GoalStore.shared.goals.isEmpty")
        && lifeSrc.contains("RecordStore.shared.records.isEmpty")
}
check("D2 生活页：我的东西五类都空 → 引导（只读既有 store）", t19())

func t20() -> Bool {
    boardSrc.contains("WorkbenchOnboard.guide(for: .board,")
        && boardSrc.contains("empty: scenes.isEmpty && automations.isEmpty)")
}
check("D3 看板页：场景与自动化都空 → 引导（不新增任何请求）", t20())

func t21() -> Bool {
    !lifeSrc.contains("URLSession") && !boardSrc.contains("OnboardGuideCard(guide: guide)\n                .task")
        && !lifeSrc.contains("lifeIsEmpty =")
}
check("D4 冷启动判定是**只读**的：生活/看板都不为它新增请求，也没有可写状态", t21())

// ─────────────────────────────────────────────────────────────────────────────
// E. 单一真源 / 闸门 / 纯逻辑
// ─────────────────────────────────────────────────────────────────────────────

func t22() -> Bool {
    let titles = pages.compactMap { WorkbenchOnboard.table[$0]?.title }
    let leaked = swiftFiles().filter { path in
        let src = code(read(path))
        return path != ONBOARD && titles.contains(where: { src.contains("\"\($0)\"") })
    }
    return leaked.isEmpty
}
check("E1 三页文案只此一处（视图里再抄一份 = 迟早漏改，全仓扫字面量）", t22())

func t23() -> Bool {
    onboardSrc.contains("guard active else { return nil }")
        && onboardSrc.contains("guard empty else { return nil }")
        && onboardSrc.contains("WorkbenchScope.launched == .work")
}
check("E2 两道闸门都在口径文件里（生活模式 / 有内容），视图不许再判断一次", t23())

func t24() -> Bool {
    // 口径层两个文件各有一份 `active`（P3 深度 / P4 冷启动），视图层一处都不许有
    let judges = swiftFiles().filter { code(read($0)).contains("WorkbenchScope.launched == .work") }
    return Set(judges) == Set([ONBOARD, "qingliao/Core/WorkbenchInsight.swift"])
}
check("E3 模式判断不许散到视图层（`== .work` 只见于两个口径文件）", t24())

func t25() -> Bool {
    !onboardSrc.contains("import SwiftUI") && onboardSrc.contains("import Foundation")
        && !onboardSrc.contains("URLSession") && !onboardSrc.contains("await ")
}
check("E4 口径文件是纯 Foundation / 纯计算（Linux 上能直接编，表才能编它）", t25())

func t26() -> Bool {
    let a = WorkbenchOnboard.table
    _ = WorkbenchOnboard.guide(for: .chat, empty: true)
    let b = WorkbenchOnboard.table
    return a == b
}
check("E5 口径是常量表、无副作用（连查两次结果一致，不随调用次数漂移）", t26())

func t27() -> Bool {
    !cardSrc.contains("Text(\"") || cardSrc.contains("Text(guide.title)")
}
check("E6 引导卡里的文字全部来自口径结构体（视图不写死任何一句）", t27())

print("\n——— 汇总 ———")
print("共 \(total) 条断言 · \(failures) 失败")
WorkbenchScope.resetForTesting()
exit(failures == 0 ? 0 : 1)
