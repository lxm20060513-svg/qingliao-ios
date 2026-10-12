// v4.0.101 生活页三张卡拆分真值表 —— Linux 本地预检用（纯 Foundation，只读源码）
//
// 用户 2026-10-12 原话：「把股票，博客/资讯，快递单独拆开」——
// 拆前这三样挤在同一个 `LifeCardsSection` 里（一个页级标题行「股票」+ 一颗折叠键），
// 拆后各成一个**平级板块**（LifeSection 各占一个 case），各自有标题行 / 折叠键 / 刷新胶囊，
// 能在「自定义板块」里单独排序、单独隐藏。
//
// 本表钉的正是「拆开了没」以及**拆的时候没拆坏什么**：
//   ① 三个 case / 三个 struct / 三处接线；
//   ② 数据源仍是一份（拆的是渲染，不是请求）；
//   ③ 折叠键：股票/资讯沿用旧键（老用户折叠态不丢）、快递新增独立键；
//   ④ 老用户的顺序串迁移：新增 case 贴着 .lifeCards 补位（不许跑到页面最末）；
//   ⑤ 反向：旧的单块结构（LifeCardsSection / rssSection 包裹层）不许还魂。
//
// ⚠️ 全部断言走**剥注释**后的代码文本：本仓老坑「注释里写了就假绿」。

import Foundation

var passCount = 0
var failCount = 0

@MainActor
func check(_ name: String, _ cond: Bool) {
    print((cond ? "  PASS  " : "  FAIL  ") + name)
    if cond { passCount += 1 } else { failCount += 1 }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 去掉行注释与块注释（本仓同类表的既有一口径）
func stripComments(_ s: String) -> String {
    var out = ""
    var inBlock = false
    for raw in s.components(separatedBy: "\n") {
        var line = raw
        if inBlock {
            guard let end = line.range(of: "*/") else { continue }
            line = String(line[end.upperBound...])
            inBlock = false
        }
        // 行内块注释（极少数，循环剥）
        while let b = line.range(of: "/*") {
            if let e = line.range(of: "*/", range: b.upperBound..<line.endIndex) {
                line = String(line[line.startIndex..<b.lowerBound]) + String(line[e.upperBound...])
            } else {
                line = String(line[line.startIndex..<b.lowerBound])
                inBlock = true
                break
            }
        }
        if let r = line.range(of: "//") { line = String(line[line.startIndex..<r.lowerBound]) }
        out += line + "\n"
    }
    return out
}

/// 去空白与换行（修饰符跨行时字面量拼不上，必须 squash 后再匹配）
func squash(_ s: String) -> String {
    s.components(separatedBy: .whitespacesAndNewlines).joined()
}

let sec = stripComments(src("qingliao/Features/Life/LifeSection.swift"))
let view = stripComments(src("qingliao/Features/Life/LifeView.swift"))
let cardsRaw = src("qingliao/Features/Dashboard/LifeCardsSection.swift")
let cards = stripComments(cardsRaw)
let sqCards = squash(cards)
let sqView = squash(view)

// ── ① 三个平级板块（LifeSection）
check("① LifeSection 新增 .rss / .express 两个 case",
      sec.contains("case rss") && sec.contains("case express"))
check("① .lifeCards 的 rawValue 未改名（改名会让老用户的顺序/隐藏串失效）",
      !sec.contains("case lifeCards ="))
check("① 三个板块的 title 映射齐全（股票 / 博客·资讯 / 快递）",
      sec.contains("case .lifeCards: return \"股票\"")
        && sec.contains("case .rss: return \"博客/资讯\"")
        && sec.contains("case .express: return \"快递\""))
check("① 跳过外层 scrollDepth 的判断收敛到 skipsOuterScrollDepth（三个板块，不散在多处）",
      sqView.contains("ifsection.skipsOuterScrollDepth{")
        && squash(sec).contains("self==.lifeCards||self==.rss||self==.express"))

// ── ② 三个 struct + 三处接线
check("② LifeCardsSection.swift 里三个 struct 都在（股票 / 资讯 / 快递）",
      cards.contains("struct LifeStocksSection: View {")
        && cards.contains("struct LifeRssSection: View {")
        && cards.contains("struct LifeExpressSection: View {"))
check("② LifeView.sectionBody 三个 case 各自接线（拆前只有一个 .lifeCards → LifeCardsSection）",
      view.contains("case .lifeCards: LifeStocksSection(data: life,")
        && view.contains("case .rss: LifeRssSection(data: life,")
        && view.contains("case .express: LifeExpressSection(data: life,"))
check("② 三张卡共用同一份数据源（拆的是渲染不是请求：三处都吃 LifeView 的 life 状态）",
      view.contains("LifeStocksSection(data: life,") && view.contains("LifeRssSection(data: life,")
        && view.contains("LifeExpressSection(data: life,"))
check("②🚫 三张卡不许各自发请求（LifeCardsSection.swift 里不得出现网络调用）",
      !cards.contains("URLSession") && !cards.contains("apiFetch") && !cards.contains("await api"))
check("② 三处刷新胶囊都走同一颗 loadLife(fresh: true, queued: true)（整块强制刷新）",
      view.components(separatedBy: "await loadLife(fresh: true, queued: true)").count - 1 >= 3)

// ── ③ 折叠键：两颗沿用旧键，快递新增
check("③ 股票沿用旧折叠键 dashboard_life_expanded（老用户折叠态不丢）",
      cards.contains("@AppStorage(\"dashboard_life_expanded\")"))
check("③ 资讯沿用旧折叠键 dashboard_rss_expanded（老用户折叠态不丢）",
      cards.contains("@AppStorage(\"dashboard_rss_expanded\")"))
check("③ 快递新增独立折叠键 dashboard_express_expanded",
      cards.contains("@AppStorage(\"dashboard_express_expanded\")"))
check("③ 三个板块各有一颗折叠箭头（不会只有一颗控制三张卡）",
      sqCards.components(separatedBy: ".accessibilityLabel(").count - 1 >= 3
        && cards.contains("expressExpanded ? \"收起快递\" : \"展开快递\"")
        && cards.contains("rssExpanded ? \"收起资讯\" : \"展开资讯\""))

// ── ③b 三张卡各自的页级标题行（拆开的**可见证据**：三种标题文案，不许一个「股票」通吃）
check("③b 三种页级标题文案并存（股票 / 博客·资讯 / 快递）",
      sqCards.contains("Text(\"股票\")") && sqCards.contains("Text(\"博客/资讯\")")
        && sqCards.contains("Text(\"快递\")"))
check("③b 三个板块各有一份 header（不会共用一条标题行）",
      cards.components(separatedBy: "private var header: some View").count - 1 == 3)
check("③b 快递标题行的图标/底色取 LifeSection 映射（不就地另写一套色）",
      sqCards.contains("LifeSection.express.icon") && sqCards.contains("LifeSection.express.tint"))

// ── ③c 快递卡内不再重复页级标题（用户 2026-10-12 选 **2️⃣**：
//       「卡内那行『快递』撤掉，只留页级标题行」）
//     撤的是**重复的图标 + 标题**；件数胶囊与右侧状态小字是页级没有的信息，必须留着
//     （否则等于顺手丢状态）。两样都空时整行不渲染，免得卡顶留一条空行。
let expressCard = stripComments(src("qingliao/Features/Dashboard/LifeExpressPriceCards.swift"))
// 哨兵：切片取空/取歪时下游断言会变「空真」（路径写错实测过一次），这里先自报
check("③c 快递卡源码切片非空（防路径写错导致的空真）", expressCard.count > 500)
check("③c 快递卡内不再重复页级图标+标题（icon/title 传空串走不渲染分支）",
      expressCard.contains("LifeCardHeaderRow(icon: \"\",") && expressCard.contains("title: \"\","))
check("③c 标题为空时图标+标题一起不渲染（不留 Image(systemName: \"\") 的空档）",
      expressCard.contains("if !title.isEmpty {"))
check("③c 件数胶囊与状态小字仍渲染（撤的是重复标题，不是整行信息）",
      expressCard.contains("countText: card.countText") && expressCard.contains("flagText: flagText"))
check("③c 两样都空时整行不渲染（不在卡顶留空行撑高）",
      expressCard.contains("if !card.countText.isEmpty || !flagText.isEmpty {"))
check("③c🚫 卡内旧写法（shippingbox + card.title 回退「快递」）不许还魂",
      !expressCard.contains("title: card.title.isEmpty ? \"快递\" : card.title"))

// ── ④ 老用户顺序串迁移：新 case 贴着 .lifeCards 补位
check("④ 新增 case 补位时贴着 .lifeCards（否则资讯/快递会跑到页面最末，像「消失了」）",
      squash(view).contains("merged.firstIndex(of:.lifeCards)")
        && view.contains("case .rss: merged.insert(s, at: anchor + 1)")
        && view.contains("case .express: merged.insert(s, at: min(anchor + 2, merged.count))"))

// ── ⑤ 反向断言：旧的单块结构不许还魂
check("⑤🚫 旧的单块 LifeCardsSection 不许还魂", !cards.contains("struct LifeCardsSection: View"))
check("⑤🚫 旧的内联包裹层 rssSection 不许还魂（资讯已是独立板块）",
      !cards.contains("private var rssSection: some View"))
check("⑤🚫 旧的私有提示条方法 noteCard/noteRow 不许还魂（已提成文件级 LifeCardsNote）",
      !cards.contains("private func noteCard(") && !cards.contains("private func noteRow("))

// ── ⑥ 视觉口径未动（拆板块 ≠ 换皮）
check("⑥ 三张卡仍是 .pastelCard() 淡彩底（与同页其它生活卡同底）", cards.contains(".pastelCard()"))
check("⑥ 三处刷新/翻批胶囊仍是页级胶囊 .pill(.page)",
      cards.components(separatedBy: ".pill(.page)").count - 1 >= 3)
check("⑥ 骨架淡出仍是 Motion.settle + 覆盖 data.loaded 与 loading 两个边界",
      cards.contains(".animation(reduceMotion ? nil : Motion.settle, value: !data.loaded && loading)"))

// ── ④b 老用户**隐藏串**迁移（2026-10-12 双路只读审查都点出：顺序串兜了，隐藏串没兜）
//     拆前 .lifeCards = 整块「生活数据」（行情+资讯+快递），用户隐藏它时串里只有 "lifeCards"
check("④b 隐藏串迁移函数存在，且由一次性标记把门（冷启动只跑一次）",
      view.contains("private func migrateLifeSplitOnce()")
        && view.contains("guard !lifeSplitMigrated else { return }"))
check("④b 迁移标记是独立持久键（不与 order/hidden 串共键，免得互相覆盖）",
      view.contains("@AppStorage(\"life_section_split_migrated\") private var lifeSplitMigrated = false"))
check("④b 只在隐藏集含 lifeCards 时才补 rss/express（没隐藏过的人不受影响）",
      view.contains("guard hidden.contains(LifeSection.lifeCards.rawValue) else { return }")
        && sqView.contains("hidden.union([LifeSection.rss.rawValue,LifeSection.express.rawValue])"))
check("④b 补完按 allCases 顺序写回（串保持可读 + 稳定排序口径）",
      view.contains("sectionHiddenRaw = LifeSection.allCases.map(")
        && view.contains("merged.contains($0)"))
check("④b 迁移挂在 onAppear（本视图不被 LazyVStack 回收，等价「每次冷启动一次」）",
      view.contains(".onAppear {\n                introReady = true\n                migrateLifeSplitOnce()"))
check("④b🚫 不许在 hiddenSections 里「无条件补 rss/express」——那会让用户日后单独取消隐藏后每次启动又被藏回去",
      !sqView.contains("h.insert(.rss)") && !sqView.contains("h.insert(.express)"))

// ── ④c 编辑器「显示」恢复走同一条锚点规则（同一诉求不许两套口径：恢复后掉到页面最末）
check("④c 恢复 rss/express 时贴着 .lifeCards 插回",
      sec.contains("if let i = shown.firstIndex(of: .lifeCards), s == .rss || s == .express {")
        && sec.contains("shown.insert(s, at: min(i + (s == .express ? 2 : 1), shown.count))"))
check("④c 其它板块恢复仍是 append（别把这条特例扩散到全部板块）",
      sec.contains("shown.append(s)"))

// ── ⑦ 三张卡对「同一次断网」必须一个说法（审查补：拆后传输层错误只喂了股票一张）
check("⑦ LifeView 把传输层错误喂给三张卡（error: lifeError 出现 3 次）",
      sqView.components(separatedBy: "error:lifeError").count - 1 >= 3)
check("⑦ 快递降级不再写死空串（否则断网被说成「数据源未配置」）",
      cards.contains("lifeDegradeText(data, error: error, loading: loading)")
        && !cards.contains("lifeDegradeText(data, error: \"\", loading: loading)"))
check("⑦ 资讯空态也优先报真因（有 error 时不只说「资讯未获取」）",
      cards.contains("!error.isEmpty ? \"wifi.exclamationmark\" : \"newspaper\"")
        && cards.contains("text: !error.isEmpty"))
check("⑦ 两个新板块的 error 参数都排在闭包实参之前（实参序红线，CI 才查得出来）",
      cards.contains("var error: String = \"\"\n    var onRefresh: () -> Void = {}")
        && cardsRaw.contains("var error: String = \"\"\n    /// v3.9.0：zoom 转场命名空间"))
check("⑦ 资讯长卡确**无**内部 scrollDepth（与 LifeSection 注释口径核对过：注释不当真源）",
      cards.components(separatedBy: ".scrollDepth()").count - 1 == 1)

print("生活页三张卡拆分真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
