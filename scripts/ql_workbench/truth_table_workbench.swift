// P2 入口收敛（工作模式各页目录口径）真值表 —— Linux 本地预检用
//
// 编译运行（仓库根目录，权威入口是 check_swift.sh 第 93 段）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_workbench \
//       scripts/ql_workbench/truth_table_workbench.swift \
//       qingliao/Core/WorkbenchScope.swift qingliao/Core/HomeCardOrder.swift
//   ⚠️ 多文件编译只有 main.swift 允许顶层代码 → 段 93 会先把它复制成 main.swift。
//
// 为什么需要这张表（P2 的改动全是「编译不报、真机才看得见」的形态）：
//   ① **工作模式首屏必须是 4 张快捷**（条目 10）：卡片目录有 17 项，多显示一张不会报错，
//      但「一屏看尽、其余进卡片库」这个口径就散了。
//   ② **其余卡不是被删，是被默认收起**（条目 10 后半）：收起集合 ∪ 快捷四张 必须逐字等于
//      全部可拖拽卡（16 张）——少一张就是「用户再也开不出来」，这类漏项肉眼根本查不出。
//   ③ **工作模式没有空槽位**（条目 12）：目录里去掉 custom 之后，「缺失 kind 自动补尾」
//      会把它补回首屏（`resolve` 的补尾是按目录走的）——不钉住这条，空槽位会自己长回来。
//   ④ **老用户配置不许丢**（条目 11）：`off` 的默认档换了口径，但**用户存过就听用户的**
//      （哨兵语义）。改坏了的表现是「老用户升级后首页卡片全变」，比崩溃更难回滚。
//   ⑤ **生活模式零变更**（用户红线）：口径取 `WorkbenchScope.launched`（启动常量，默认 .life），
//      全 App 只有 `WorkbenchRoot.init` 一处写入 —— 生活模式那条路径不构造它，读到的永远是 .life。
//      护栏要正反两面钉：默认值、目录、默认档、渲染列表逐字等于历史口径。
//   ⑥ **口径不许散落**：差异必须集中在 WorkbenchScope.swift（唯一 switch）；视图层只许问
//      「本口径的目录是什么」，不许自己写 `if 工作模式`。
//
// 口径：断言只看**代码**（`code()` 先剥掉整行注释）——注释里为了讲清道理举的例子字面量
// 不该被当成违规；反过来，代码里真出现就是真违规。

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

/// 剥掉**整行注释**后的源码
func code(_ src: String) -> String {
    src.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

/// 取 from…to 之间的切片（取不到返回空串 → 相关断言会红，不会假绿）
func slice(_ src: String, _ from: String, _ to: String) -> String {
    guard let a = src.range(of: from) else { return "" }
    let rest = String(src[a.upperBound...])
    guard let b = rest.range(of: to) else { return rest }
    return String(rest[..<b.lowerBound])
}

/// 仓库内所有 .swift（相对路径），用于「唯一写入点 / 口径不许散落」这类全仓断言
func swiftFiles() -> [String] {
    var out: [String] = []
    let root = "qingliao"
    guard let en = FileManager.default.enumerator(atPath: root) else { return out }
    for case let p as String in en where p.hasSuffix(".swift") {
        out.append("\(root)/\(p)")
    }
    return out.sorted()
}

// MARK: - 现场准备（UserDefaults 只在用例内摆状态，跑完必须还原）

// ⚠️ main.swift 里的顶层全局是 @MainActor 孤立的（同第 92 段的坑）：nonisolated 的辅助函数
// 碰不到 `ud` —— 所以下面三个用了 UserDefaults 的辅助函数显式标 @MainActor。
let ud = UserDefaults.standard
let savedOrder = ud.string(forKey: HomeCardStore.orderKey)
let savedOff = ud.string(forKey: HomeCardStore.offKey)
let hadOrder = ud.object(forKey: HomeCardStore.orderKey) != nil
let hadOff = ud.object(forKey: HomeCardStore.offKey) != nil

@MainActor func clearKeys() {
    ud.removeObject(forKey: HomeCardStore.orderKey)
    ud.removeObject(forKey: HomeCardStore.offKey)
}
@MainActor func restoreKeys() {
    if hadOrder, let v = savedOrder { ud.set(v, forKey: HomeCardStore.orderKey) }
    else { ud.removeObject(forKey: HomeCardStore.orderKey) }
    if hadOff, let v = savedOff { ud.set(v, forKey: HomeCardStore.offKey) }
    else { ud.removeObject(forKey: HomeCardStore.offKey) }
}
/// 本口径下「首页实际会渲染的卡」（= resolve(顺序, 收起, 目录) 再按口径补空槽位）
@MainActor func rendered(_ scope: WorkbenchScope) -> [HomeCardKind] {
    let catalog = WorkbenchLayout.homeCardCatalog(scope)
    let base = HomeCardOrder.resolve(order: ud.string(forKey: HomeCardStore.orderKey) ?? "",
                                     off: HomeCardOrder.encode(HomeCardStore.off),
                                     catalog: catalog)
    guard catalog.contains(.custom), !HomeCardStore.off.contains(.custom) else { return base }
    return base.contains(.custom) ? base : base + [.custom]
}

print("=== A. 口径默认与目录（生活模式 = 历史口径，逐字不许动）===")
check("A1 恰好两个口径 life / work", WorkbenchScope.allCases == [.life, .work])
check("A2 没被声明过时默认 .life（= 生活模式那条路的地基）", {
    WorkbenchScope.resetForTesting()
    return WorkbenchScope.launched == .life
}())
check("A3 生活目录 = 全量 17 类且含空槽位（历史口径）",
      WorkbenchLayout.homeCardCatalog(.life) == HomeCardKind.allCases
        && WorkbenchLayout.homeCardCatalog(.life).contains(.custom))
check("A4 生活默认档逐字 = 历史 13 项",
      WorkbenchLayout.homeCardDefaultOff(.life) == HomeCardStore.defaultOff
        && HomeCardStore.defaultOff == [.todo, .weather, .expense, .nextReminder, .memo,
                                        .express, .stock, .kb, .scene, .device, .cloud, .goal, .clipboard])
check("A5 默认档单一真源（WorkbenchLayout 直接复用 HomeCardStore.defaultOff，不许抄一份）",
      HomeCardStore.defaultOff.count == 13)

print("=== B. 工作模式首屏：4 张快捷（条目 10 / 12）===")
WorkbenchScope.adopt(.work)
clearKeys()
check("B1 快捷四张逐字 = 继续上次会话 / 今日待办 / 天气 / 记一笔",
      WorkbenchLayout.workShortcutKinds == [.resume, .todo, .weather, .expense])
check("B2 工作目录 = 16 类且**不含空槽位**（条目 12）",
      WorkbenchLayout.homeCardCatalog(.work).count == 16
        && !WorkbenchLayout.homeCardCatalog(.work).contains(.custom))
check("B3 收起 ∪ 快捷 = 全部可拖拽卡（16 张一张不少，其余都在卡片库里）", {
    let offSet = Set(WorkbenchLayout.workDefaultOff)
    let quick = Set(WorkbenchLayout.workShortcutKinds)
    return offSet.count == 12 && offSet.union(quick) == Set(HomeCardKind.draggable)
        && offSet.isDisjoint(with: quick)
}())
check("B4 工作模式首屏渲染 = 那 4 张（顺序 = 目录序）",
      rendered(.work) == [.resume, .todo, .weather, .expense])
check("B5 首屏渲染不再补空槽位、fullOrder 里也没有它",
      !rendered(.work).contains(.custom) && !HomeCardStore.fullOrder.contains(.custom))
check("B6 反例：两套口径必须不同（工作首屏 != 生活首屏），否则 P2 等于没做", {
    let work = rendered(.work)
    WorkbenchScope.resetForTesting()
    clearKeys()
    let life = rendered(.life)
    WorkbenchScope.adopt(.work)
    return work != life && life.contains(.custom)
}())

print("=== C. 老用户配置不丢 / 生活模式零变更（条目 11 + 红线）===")
WorkbenchScope.resetForTesting()
clearKeys()
check("C1 生活模式：off = 历史默认档（键缺失走默认档，语义没变）",
      HomeCardStore.off == HomeCardStore.defaultOff)
check("C2 生活模式：渲染列表 = 历史三张 + 空槽位（与 ql_chat_home 同口径）",
      rendered(.life) == [.mail, .resume, .agentTip, .custom])
check("C3 生活模式：fullOrder 仍含空槽位",
      HomeCardStore.fullOrder.contains(.custom))

WorkbenchScope.adopt(.work)
ud.set("todo,weather", forKey: HomeCardStore.offKey)
check("C4 用户存过 off → 工作模式读出来仍是用户那份（默认档不许覆盖老用户）",
      HomeCardStore.off == [.todo, .weather])
check("C5 用户存过 off → 工作模式可见卡按用户的口径（16 - 2 = 14 张）",
      rendered(.work).count == 14)

ud.set("weather,resume,todo,expense,mail,custom", forKey: HomeCardStore.orderKey)
ud.set(HomeCardOrder.encode(WorkbenchLayout.workDefaultOff), forKey: HomeCardStore.offKey)
check("C6 用户存过顺序 → 工作模式按用户顺序出可见卡（空槽位被口径滤掉）", {
    let got = rendered(.work)
    // 用户的顺序串里 weather 排在 resume 前 → 首屏第一张必须是天气（不是目录序的「继续上次会话」）
    return got == [.weather, .resume, .todo, .expense] && !got.contains(.custom)
}())

ud.set("custom", forKey: HomeCardStore.offKey)
check("C7 用户存过「空槽位关掉」→ 工作模式读出来仍是 [custom]（不因目录里没有它就丢配置）",
      HomeCardStore.off == [.custom])

clearKeys()
ud.set("weather,resume,todo,expense", forKey: HomeCardStore.orderKey)
HomeCardStore.persist(order: HomeCardStore.fullOrder, off: HomeCardStore.off)
check("C8 写回不污染：工作模式 persist 后顺序串里没有空槽位",
      !(ud.string(forKey: HomeCardStore.orderKey) ?? "").contains("custom"))
WorkbenchScope.resetForTesting()
check("C9 切回生活模式：空槽位自动补回末尾（老用户配置不丢）",
      rendered(.life).last == .custom)

WorkbenchScope.adopt(.work)
clearKeys()
ud.set(HomeCardOrder.encode(HomeCardKind.draggable), forKey: HomeCardStore.offKey)
check("C10 全关兜底仍在：只回落「继续上次会话」一张（首页不会空）",
      rendered(.work) == [.resume])

print("=== D. 口径不许散落（源码断言）===")
let scopeSrc = read("qingliao/Core/WorkbenchScope.swift")
let rootSrc = read("qingliao/Core/UIModeRoot.swift")
let dockSrc = read("qingliao/Features/DockTabView.swift")
let homeSrc = read("qingliao/Features/HomeCards.swift")
let cardSrc = read("qingliao/Core/HomeCardOrder.swift")

check("D1 口径声明写入点全 App 只有一处（WorkbenchRoot.init）",
      swiftFiles().filter { code(read($0)).contains("WorkbenchScope.adopt(") } == ["qingliao/Core/UIModeRoot.swift"])
check("D2 adopt(.work) 就在 WorkbenchRoot 的 init 里（不是 body、不是某页面）",
      slice(code(rootSrc), "struct WorkbenchRoot: View {", "var body: some View")
        .contains("WorkbenchScope.adopt(.work)"))
check("D3 resetForTesting 生产代码 0 处调用（它是给本表隔离用例用的）",
      swiftFiles().filter {
          $0 != "qingliao/Core/WorkbenchScope.swift" && code(read($0)).contains("resetForTesting()")
      }.isEmpty)
check("D4 口径读取集中在六处（首页卡两条路径 + 生活页目录 + 看板挂载点 + P3 深度口径文件 + P4 冷启动口径文件），别处 0 处", {
    let allowed: Set<String> = ["qingliao/Core/HomeCardOrder.swift",
                                "qingliao/Features/HomeCards.swift",
                                "qingliao/Features/Life/LifeView.swift",
                                "qingliao/Features/Dashboard/DashboardView.swift",
                                "qingliao/Core/WorkbenchInsight.swift",
                                "qingliao/Core/WorkbenchOnboard.swift"]
    let hits = Set(swiftFiles().filter { code(read($0)).contains("WorkbenchScope.launched") })
    return hits == allowed
}())
check("D5 生活模式那份代码不知道模式存在（DockTabView.swift 全篇无 UIMode / WorkbenchScope）",
      !code(dockSrc).contains("UIMode") && !code(dockSrc).contains("WorkbenchScope"))
check("D6 life 分支仍是裸 DockTabView()（红线：零包装）",
      slice(code(rootSrc), "case .life:", "case .work:").contains("DockTabView()"))
check("D7 卡片编辑器列表按本口径目录出（不许再用 catalogOrder 列全量）",
      !slice(code(homeSrc), "struct HomeCardEditorSheet: View {", "var body: some View")
        .contains("catalogOrder")
        && slice(code(homeSrc), "struct HomeCardEditorSheet: View {", "var body: some View")
        .contains("WorkbenchLayout.homeCardCatalog(WorkbenchScope.launched)"))
check("D8 空槽位的渲染路径仍在（生活模式照旧可用，没被顺手删掉）",
      code(homeSrc).contains("private var emptySlot: some View")
        && code(homeSrc).contains("kind == .custom"))
check("D9 卡片默认档的键字面量仍只在 HomeCardOrder.swift（单一真源没被搬走）",
      swiftFiles().filter { code(read($0)).contains("\"qingliao_home_card_off\"") }
        == ["qingliao/Core/HomeCardOrder.swift"])
check("D10 默认档按口径分流这件事只写在 WorkbenchLayout（HomeCardStore 不自己写默认档）",
      code(cardSrc).contains("WorkbenchLayout.homeCardDefaultOff(WorkbenchScope.launched)")
        && code(scopeSrc).contains("case .work: return workDefaultOff"))

// ─────────────────────────────────────────────────────────────────────────────
// 第 2 批（P2 条目 8 + 9）新增：生活页移出 / 看板收进。两件事必须**同批**落地 ——
// 只移出而不收进，工作模式下「定时任务 / 生活数据」两个入口就失联了（清单第 2 批的红线）。
// ─────────────────────────────────────────────────────────────────────────────

let lifeViewSrc = code(read("qingliao/Features/Life/LifeView.swift"))
let boardSrc = code(read("qingliao/Features/Dashboard/DashboardView.swift"))

check("D11 生活页目录走口径函数（移出前的内联 LifeSection.allCases 实现不许留）",
      lifeViewSrc.contains("WorkbenchLayout.lifeSectionCatalogRaws(WorkbenchScope.launched")
        && lifeViewSrc.contains("WorkbenchLayout.resolveLifeSectionOrder(order: sectionOrderRaw")
        && !lifeViewSrc.contains("return saved + LifeSection.allCases"))
check("D12 看板挂载点只问口径函数（看板里不许自己判模式）",
      boardSrc.contains("WorkbenchLayout.dashboardHostsLifeSection(")
        && !boardSrc.contains("WorkbenchScope.launched == .work")
        && !boardSrc.contains("UIMode.current"))
check("D13 看板收进没动 BoardCard 卡片库（加卡 = 生活模式的看板也多一张）",
      !code(read("qingliao/Core/BoardCardOrder.swift")).contains("lifeCards")
        && !code(read("qingliao/Core/BoardCardOrder.swift")).contains("生活数据"))
check("D14 两个移出板块的渲染分支还在（切回生活模式不需要任何恢复动作）",
      lifeViewSrc.contains("case .automations: AutomationsSection(isActive: isActive)")
        && lifeViewSrc.contains("case .lifeCards: LifeCardsBlock(store: lifeCards, isActive: isActive)"))
check("D15 板块编辑器按本口径目录出 + 写回走合并口径（不再无条件写全量）", {
    let sheet = code(read("qingliao/Features/Life/LifeSection.swift"))
    return sheet.contains("init(visible: [LifeSection], hidden: [LifeSection], catalog: [String])")
        && sheet.contains("WorkbenchLayout.mergeLifeSectionPersist(")
        && !sheet.contains("orderRaw = full.map")
}())

print("=== E. 生活页板块口径（P2 条目 8：定时任务 / 生活数据 移出生活页）===")
// 板块 rawValue 的**真源 = LifeSection.swift 源码本身**（直接解析，不在这里抄一份 7 项清单 ——
// 抄一份就是第二个真源，将来给生活页加板块会悄悄漏出目录）。解析不到 → allRaws 空 → 下面全红。
let allRaws: [String] = {
    let body = slice(code(read("qingliao/Features/Life/LifeSection.swift")),
                     "enum LifeSection: String", "\n}")
    return body.split(separator: "\n").compactMap { line in
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("case "), !t.hasPrefix("case .") else { return nil }
        let name = String(t.dropFirst("case ".count))
        let cut = name.firstIndex { $0 == " " || $0 == "\t" || $0 == "/" } ?? name.endIndex
        let v = String(name[..<cut])
        return v.isEmpty ? nil : v
    }
}()
let workCatalog = WorkbenchLayout.lifeSectionCatalogRaws(.work, allRaws: allRaws)
let lifeCatalog = WorkbenchLayout.lifeSectionCatalogRaws(.life, allRaws: allRaws)

check("E1 源码解析出 7 个板块（解析不到=空数组，与 E2 一起兜住假绿）",
      allRaws == ["memo", "todo", "habit", "goals", "record", "automations", "lifeCards"])
check("E2 移出常量与源码逐字对齐（枚举改名/加板块而口径没跟 = 红）",
      WorkbenchLayout.automationsRaw == "automations" && WorkbenchLayout.lifeCardsRaw == "lifeCards"
        && allRaws.contains(WorkbenchLayout.automationsRaw) && allRaws.contains(WorkbenchLayout.lifeCardsRaw)
        && WorkbenchLayout.workMovedLifeSectionRaws == ["automations", "lifeCards"])
check("E3 工作口径目录 = 全量 − 移出两个（5 项，顺序 = 目录序）",
      workCatalog == ["memo", "todo", "habit", "goals", "record"]
        && !workCatalog.contains(WorkbenchLayout.automationsRaw)
        && !workCatalog.contains(WorkbenchLayout.lifeCardsRaw))
check("E4 生活口径目录 = 全量原样（历史口径，一个都不少）",
      lifeCatalog == allRaws && lifeCatalog.count == 7)
check("E5 反例：两套目录必须不同（差集恰好 = 移出那两个），否则条目 8 等于没做",
      Set(workCatalog) != Set(lifeCatalog)
        && Set(lifeCatalog).subtracting(Set(workCatalog)) == Set(WorkbenchLayout.workMovedLifeSectionRaws))
check("E6 工作口径顺序归一化：目录外的键被丢、缺的按目录序补尾", {
    let got = WorkbenchLayout.resolveLifeSectionOrder(order: "lifeCards,goals,habit", catalog: workCatalog)
    return got == ["goals", "habit"] + ["memo", "todo", "record"]
}())
check("E7 生活口径顺序归一化逐字 = 移出前旧实现（已存顺序在前 + 全量补尾 + 保序去重）", {
    let raw = "habit,todo,unknown,habit"
    let got = WorkbenchLayout.resolveLifeSectionOrder(order: raw, catalog: lifeCatalog)
    var seen = Set<String>()
    let saved = raw.split(separator: ",").map(String.init).filter { allRaws.contains($0) }
        .filter { seen.insert($0).inserted }
    return got == saved + allRaws.filter { !seen.contains($0) } && got.count == 7
}())
check("E8 两个移出板块在生活口径目录里必须还在（切回生活模式照样出现）",
      lifeCatalog.contains("automations") && lifeCatalog.contains("lifeCards"))

print("=== F. 看板收进（P2 条目 9：移出的板块在工作模式看板有落点）===")
check("F1 生活模式的看板一个都不多收（生活模式零变更）",
      WorkbenchLayout.dashboardHostedLifeSectionRaws(.life).isEmpty)
check("F2 工作模式看板收进「生活数据」",
      WorkbenchLayout.dashboardHostedLifeSectionRaws(.work) == ["lifeCards"])
check("F3 移出集合 = 看板收进 ∪ 已在看板（定时任务由看板「自动化」卡承载），两集合不相交且都非空", {
    let moved = Set(WorkbenchLayout.workMovedLifeSectionRaws)
    let hosted = Set(WorkbenchLayout.dashboardHostedLifeSectionRaws(.work))
    let already = Set(WorkbenchLayout.workMovedAlreadyOnDashboard)
    return hosted.isDisjoint(with: already) && !hosted.isEmpty && !already.isEmpty
        && hosted.union(already) == moved
}())
check("F4 挂载判定按口径走（life=false / work=true）",
      !WorkbenchLayout.dashboardHostsLifeSection("lifeCards", scope: .life)
        && WorkbenchLayout.dashboardHostsLifeSection("lifeCards", scope: .work))
check("F5 定时任务只有一个口：看板「自动化」卡与生活页「定时任务」卡读同一端点",
      boardSrc.contains("/api/automations/list")
        && code(read("qingliao/Features/Life/AutomationsSection.swift")).contains("/api/automations/list"))
check("F6 生活数据只有一个实现：LifeCardsSection 只在 LifeCardsBlock 里被实例化", {
    Set(swiftFiles().filter { code(read($0)).contains("LifeCardsSection(") })
        == ["qingliao/Features/Life/LifeCardsBlock.swift"]
}())
check("F7 同一个 LifeCardsBlock 被生活页与看板各挂一次（复用，不是第二套界面）", {
    Set(swiftFiles().filter { code(read($0)).contains("LifeCardsBlock(") })
        == ["qingliao/Features/Life/LifeView.swift", "qingliao/Features/Dashboard/DashboardView.swift"]
}())

print("=== G. 板块配置不丢（条目 11 同款口径：工作模式动过排序/显隐，切回生活模式老配置仍在）===")
let prevOrderFull = ["memo", "todo", "habit", "goals", "record", "automations", "lifeCards"]
let workShown = ["record", "memo", "todo", "habit"]

check("G1 工作模式写回：目录外的老条目原样留在顺序串里", {
    let m = WorkbenchLayout.mergeLifeSectionPersist(catalog: workCatalog, shown: workShown,
                                                    hidden: [], prevOrder: prevOrderFull, prevHidden: [])
    let order = WorkbenchLayout.parseRaws(m.order)
    return order.contains("automations") && order.contains("lifeCards")
        && Array(order.prefix(4)) == ["record", "memo", "todo", "habit"]
}())
check("G2 老用户隐藏过的移出板块不许被工作模式写回抹掉", {
    let m = WorkbenchLayout.mergeLifeSectionPersist(catalog: workCatalog, shown: workShown,
                                                    hidden: [], prevOrder: prevOrderFull,
                                                    prevHidden: ["lifeCards"])
    return WorkbenchLayout.parseRaws(m.hidden) == ["lifeCards"]
}())
check("G3 幂等：同一份状态连写两次串不变（编辑器每按一次都会写回）", {
    let m1 = WorkbenchLayout.mergeLifeSectionPersist(catalog: workCatalog, shown: workShown,
                                                     hidden: ["goals"], prevOrder: prevOrderFull,
                                                     prevHidden: ["lifeCards"])
    let m2 = WorkbenchLayout.mergeLifeSectionPersist(catalog: workCatalog, shown: workShown,
                                                     hidden: ["goals"],
                                                     prevOrder: WorkbenchLayout.parseRaws(m1.order),
                                                     prevHidden: WorkbenchLayout.parseRaws(m1.hidden))
    return m1.order == m2.order && m1.hidden == m2.hidden
}())
check("G4 目录内的排序 / 隐藏照常生效（写回串 = shown + hidden 在前）", {
    let m = WorkbenchLayout.mergeLifeSectionPersist(catalog: workCatalog, shown: ["record", "memo"],
                                                    hidden: ["todo"], prevOrder: [], prevHidden: [])
    let order = WorkbenchLayout.parseRaws(m.order)
    return Array(order.prefix(3)) == ["record", "memo", "todo"]
        && WorkbenchLayout.parseRaws(m.hidden) == ["todo"]
}())
check("G5 切回生活模式：那两个板块仍在（老配置不丢的最终表现）", {
    let m = WorkbenchLayout.mergeLifeSectionPersist(catalog: workCatalog, shown: workShown,
                                                    hidden: [], prevOrder: prevOrderFull, prevHidden: [])
    let lifeOrder = WorkbenchLayout.resolveLifeSectionOrder(order: m.order, catalog: lifeCatalog)
    return lifeOrder.contains("automations") && lifeOrder.contains("lifeCards") && lifeOrder.count == 7
}())
check("G6 目录外条目的**相对顺序**也保住了（串里没被丢 = 不是靠 resolve 补尾救命）", {
    // 老用户把两个移出板块排在中间：写回串的尾部必须按它们的原相对顺序留着，
    // 而不是干脆消失（消失后靠 resolve 补尾也能"出现"，但那是假象 —— 顺序信息已经没了）
    let prev = ["memo", "lifeCards", "todo", "automations", "habit", "goals", "record"]
    let m = WorkbenchLayout.mergeLifeSectionPersist(catalog: workCatalog, shown: workShown,
                                                    hidden: [], prevOrder: prev, prevHidden: [])
    let tail = Array(WorkbenchLayout.parseRaws(m.order).suffix(2))
    return tail == ["lifeCards", "automations"]
}())

print("\n——— 汇总 ———")
print("共 \(total) 条断言 · \(failures) 失败")
restoreKeys()
WorkbenchScope.resetForTesting()
exit(failures == 0 ? 0 : 1)
