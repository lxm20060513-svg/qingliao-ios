// MARK: - v3.9.80 色彩令牌口径 · 真值表（tone 色淡底一律走 Tint，不留字面 opacity）
//
// 背景（improve-ui 只读审计发现 + 用户 2026-09-25 回「1」= 按计划落地）：
//   Agent 卡头部状态图标的**淡色胶囊底**写的是字面 `0.14`，而同文件另两处同类底
//   （状态胶囊 :100、清单项状态胶囊 :218）走令牌 `Tint.subtle`（0.12）。
//   后果不是「看着不一样」（0.12 与 0.14 肉眼几乎分不出），而是**改口径时这一处会被落下**：
//   以后调 Tint.subtle 或换深浅色策略，头部图标底还停在 0.14 → 又变成「每处各调一下」。
//   契约源：`qingliao/Theme/Tint.swift:3-16`（v3.9.19 把全库 37 个 opacity 字面量收敛成四档，
//   用户 2026-09-14 拍板；subtle 0.12 = 淡色胶囊底、淡色分组底，最常用）。
// 计划全文：`/opt/data/scripts/qingliao_docs/design-plans/agent-card-status-icon-tint.md`
//
// ⚠️ 本表**扫全仓**（`qingliao/Features` 逐文件）：v3.9.80 先把 Agent 卡头部图标底从字面 0.14 收成 `Tint.subtle`，
//   随后用户拍板「顺带收口」同 role 另两处（`SessionsView` 的 tag 胶囊底、`ConnectorPanelSheet` 的 tint 色块底），
//   于是负断言从「只扫一个文件」升级成「扫 Features 目录」。
//   唯一豁免：`ConnectorPanelSheet.swift` 的 `.white.opacity(0.14)` 是**深色描边**，
//   Tint.swift:15 明文「深浅色各自取值由调用点决定（浅色 0.08 / 深色 0.14~0.22）」→ 不算违规。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
/// 去注释行：负断言必须走它，否则「讲清旧形态」的注释会把断言染红（本仓已踩）
func stripCommentLines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

let cardSrc = src("qingliao/Features/Chat/AgentResultCard.swift")
let tintSrc = src("qingliao/Theme/Tint.swift")

// ── 1. 源可读 + Tint 契约在位（空了后面全是空真） ──────────────
check("AgentResultCard.swift 源可读", !cardSrc.isEmpty)
check("Tint.swift 源可读", !tintSrc.isEmpty)
check("Tint 四档语义在位（faint 0.08 / subtle 0.12 / soft 0.16 / strong 0.22）",
      tintSrc.contains("static let faint: CGFloat = 0.08")
      && tintSrc.contains("static let subtle: CGFloat = 0.12")
      && tintSrc.contains("static let soft: CGFloat = 0.16")
      && tintSrc.contains("static let strong: CGFloat = 0.22"))

// ── 2. 头部状态图标底走令牌（本次落地的那一处） ────────────────
check("Agent 卡头部状态图标底走 Tint.subtle（不再写字面 0.14）",
      cardSrc.contains(".background(toneColor(card.status?.tone).opacity(Tint.subtle), in: Capsule())"))
check("旧字面形态清零：本文件不再有 tone/tag 色底的字面 opacity(0.14)",
      !stripCommentLines(cardSrc).contains(".opacity(0.14)"))

// ── 2b. 同 role 另两处（v3.9.80 用户拍板「顺带收口」） ────────────
check("SessionsView 的 tag 胶囊底走 Tint.subtle（原先字面 0.14）",
      src("qingliao/Features/Sessions/SessionsView.swift")
        .contains(".background(tagColor(t).opacity(Tint.subtle), in: Capsule())"))
check("ConnectorPanelSheet 的 tint 色块底走 Tint.subtle（原先字面 0.14）",
      src("qingliao/Features/Dashboard/ConnectorPanelSheet.swift")
        .contains(".background(tint.opacity(Tint.subtle), in: RoundedRectangle(cornerRadius: 11))"))
check("深色描边保留 0.14（Tint.swift 明文允许调用点自定深浅取值，不属违规）",
      src("qingliao/Features/Dashboard/ConnectorPanelSheet.swift")
        .contains(".strokeBorder(.white.opacity(0.14), lineWidth: 0.8)"))

// ── 2c. 全仓扫描：彩色淡底不许再有字面 0.14 ────────────────────────
let featDir = "qingliao/Features"
var scannedFiles = 0
var offenders: [String] = []
if let en = FileManager.default.enumerator(atPath: featDir) {
    for case let rel as String in en where rel.hasSuffix(".swift") {
        guard let body = try? String(contentsOfFile: featDir + "/" + rel, encoding: .utf8) else { continue }
        scannedFiles += 1
        for (n, line) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }   // 注释里讲历史不算
            if line.contains(".opacity(0.14)") && !line.contains(".white.opacity(0.14)") {
                offenders.append("\(rel):\(n + 1)")
            }
        }
    }
}
check("Features 目录扫到源码（扫到 \(scannedFiles) 个文件；扫 0 个说明路径口径变了，下面就是空真）",
      scannedFiles > 50)
check("彩色淡底字面 0.14 全仓清零（豁免只剩深色描边 .white.opacity(0.14)）—— 违规点：\(offenders)",
      offenders.isEmpty)

// ── 3. 同文件另两处同类底仍是令牌（防被误改回字面量） ─────────────
check("状态胶囊底（:100）仍走 Tint.subtle",
      cardSrc.components(separatedBy: "toneColor(tone).opacity(Tint.subtle)").count - 1 >= 1)
check("清单项状态胶囊底仍走 Tint.subtle",
      cardSrc.contains(".background(toneColor(item.tone).opacity(Tint.subtle), in: Capsule())"))

// ── 4. v4.0.84 生活页「方案 B + 四拍动效」跨文件口径 ─────────────────
// 背景：用户 2026-10-09 看对比稿拍板「B 加动效一起做一版」（方案 B 同型精修 + 四拍动效）。
// 这组断言守的是**跨文件口径**，不是像素 —— 新形态落地后不锁死，下次很容易各改一半。

/// 抹掉缩进：下面要断言「某个修饰符紧跟另一个修饰符」，缩进随文件而变，不能进字面量
func squashPad(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .joined(separator: "\n")
}
/// 取 needle 之后紧跟的数字。「数值 ≥ x」类断言必须先取数再比大小 ——
/// 写成子串匹配（`contains("= 0.7")`）时 0.8 反而判红，与断言名自相矛盾（2026-10-09 审查抓到）。
func numAfter(_ needle: String, in s: String) -> Double? {
    guard let r = s.range(of: needle) else { return nil }
    let digits = s[r.upperBound...].prefix { $0.isNumber || $0 == "." }
    return Double(String(digits))
}
/// 取 from 之后、to 之前的切片。取不到返回空串 —— 空串让下游断言判红，保险方向正确
///（属性被改名/删除时应当暴露，而不是静默变绿）。
func slice(_ s: String, from: String, to: String) -> String {
    guard let a = s.range(of: from), let b = s.range(of: to, range: a.upperBound..<s.endIndex)
    else { return "" }
    return String(s[a.upperBound..<b.lowerBound])
}

let stagger = src("qingliao/Theme/StaggerAppear.swift")
// 🚨 2026-10-09 发版前审查：入场态**不许**放在 modifier 自己的 @State 上 —— 本页是 LazyVStack，
//    行滚出视口被回收、重建时 @State 重置回初值 → 每次滚回来重放一遍入场（无报错，只有手感）。
//    ready 必须由不会被回收的宿主持有。原先这条是 `!stagger.isEmpty`（文件非空即绿 = 零鉴别力）。
check("拍 1 入场错峰只有一份实现（唯一实现 = Theme/StaggerAppear.swift 的 StaggerAppear）",
      stagger.components(separatedBy: "struct StaggerAppear: ViewModifier").count - 1 == 1
        && stagger.components(separatedBy: "func staggerAppear(").count - 1 == 1)
check("入场态由宿主持有：modifier 只收 ready，不许自持 @State + onAppear（行回收会重放）",
      stagger.contains("let ready: Bool")
        && !stagger.contains("@State private var shown")
        && !stagger.contains(".onAppear { shown = true }"))
check("宿主一次性置真 ready（LifeView 不被 LazyVStack 回收 → 只播一次）",
      src("qingliao/Features/Life/LifeView.swift").contains("@State private var introReady = false")
        && src("qingliao/Features/Life/LifeView.swift").contains(".onAppear { introReady = true }"))
check("入场动效走 Motion 令牌，不裸写时长曲线",
      stagger.contains("Motion.emerge") && !stagger.contains(".easeOut(") && !stagger.contains(".spring("))
check("入场有减动效出口（reduceMotion → animation(nil)：状态变化瞬间到位 = composed still）",
      stagger.contains("reduceMotion ? nil : Motion.emerge"))
// ⚠️ 本批最容易回退错的一条 —— 生活页整页被 DockTabView 切页入场包着（.opacity(phase)，phase 0.6→1，
//    Motion.flow 0.28s），两层不透明度是**相乘**的：from 取 0.55 时合成 0.55×0.6=0.33，
//    比切页自身的 0.6 还暗一大截 → 复现用户报过的「dock 栏 tap 切换太闪了」。
check("入场起点 from ≥ 0.7（合成后与切页 0.6 同量级；不许回退 0.55）",
      (numAfter("var from: Double = ", in: stagger) ?? 0) >= 0.7)

let lifeView = src("qingliao/Features/Life/LifeView.swift")
check("生活页板块行挂了入场错峰 + 滚动层次（此前生活页 .scrollDepth() 为 0 处）",
      lifeView.contains(".staggerAppear(index, ready: introReady)") && lifeView.contains(".scrollDepth()"))
// 2026-10-09 审查：lifeCards 板块内部逐卡已挂 scrollDepth（与看板同款），外层再挂一层会叠两次
// scrollTransition → 缩放 0.965²≈0.931、不透明度 0.75²≈0.56，比看板更缩更暗（与初衷相反）
check("lifeCards 板块不叠两层 scrollDepth（外层跳过）",
      squashPad(lifeView).contains("if section == .lifeCards {"))
check("板块 switch 已提成 sectionBody（内联 switch 上面挂不了修饰符）",
      lifeView.contains("private func sectionBody(_ section: LifeSection)"))

check("滚动层次补了减动效出口（开「减弱动态效果」→ 不挂 scrollTransition，卡片停终态）",
      squashPad(src("qingliao/Theme/LiquidGlass.swift"))
        .contains("if reduceMotion {\ncontent\n} else {\ncontent.scrollTransition"))

// 图标底几何只有一处：标题行 20pt 也必须走 BadgeShell
let scaffold = src("qingliao/Features/Life/LifeSectionScaffold.swift")
check("板块标题行图标底走 BadgeShell 20pt",
      scaffold.contains(".modifier(BadgeShell(size: 20, color: sectionIconTint))"))
// 名字里一直写着「不手写 cornerRadius」，但原来没有对应断言 → 切片限定到图标底那一段再钉
// ⚠️ 必须过 stripCommentLines：那段代码上方的注释里就写着「别在这里手写 cornerRadius」，
//    直接切片会把注释里的词算进来 → 断言恒红（本表 2026-10-09 落地时踩过第二次）
let iconSlice = slice(stripCommentLines(scaffold), from: "if let sectionIcon, let sectionIconTint {", to: "Text(title)")
check("标题行图标底不手写 cornerRadius（几何只此一处 = BadgeShell）",
      !iconSlice.isEmpty && !iconSlice.contains("cornerRadius"))
// 原写法用 `!scaffold.contains("Button(action: { })")` 当负断言：那个字面量全仓不存在，
// 任何输入下都成立 = 零鉴别力（2026-10-09 审查抓到）。改成**切片**断言，空切片判红。
let ctaSlice = slice(scaffold, from: "if let ctaTitle {", to: ".padding(Spacing.section)")
check("空态卡 CTA 是纯文本胶囊、不是卡内第二个 Button（整卡已是 Button：抢点 + VoiceOver 双读）",
      ctaSlice.contains("Text(ctaTitle).pill(.page)") && !ctaSlice.contains("Button"))
check("空态卡 CTA 在行内右侧（下移会撑高空态、破掉「与页级单卡同几何」的 v3.9.33 口径）",
      squashPad(scaffold).contains("Spacer(minLength: 0)\nif let ctaTitle {"))

// 六处卡族内边距统一 Spacing.section（16）；回退成 Spacing.xl（12）即红
let cardPads: [(String, String)] = [
    ("qingliao/Features/Life/MemoSection.swift", "MemoNoteCard"),
    ("qingliao/Features/Life/TodoSection.swift", "TodoRowCard"),
    ("qingliao/Features/Life/HabitSection.swift", "HabitCard"),
    ("qingliao/Features/Life/GoalsSection.swift", "GoalRowCard"),
    ("qingliao/Features/Life/RecordSection.swift", "记录页卡"),
    ("qingliao/Features/Life/LifeSectionScaffold.swift", "空态卡"),
    // 2026-10-09 审查：这两张卡也只在生活页渲染、同为 .pastelCard() 卡族，漏改会在同页混排 16/12
    ("qingliao/Features/Dashboard/LifeCardsSection.swift", "生活数据卡（股票/资讯/占位）"),
    ("qingliao/Features/Dashboard/LifeExpressPriceCards.swift", "快递卡"),
]
// ⚠️ 用 squashPad（去缩进、留换行）而不是 squash（去空格）：这两个修饰符在源码里是**两行**，
//    写成单行拼接的字面量永远匹配不上 → 断言恒红（本表 2026-10-09 落地时自己踩过）。
let padReverted = cardPads.filter {
    !squashPad(src($0.0)).contains(".padding(Spacing.section)\n.frame(maxWidth: .infinity")
}.map { $0.1 }
check("六处卡族内边距统一 Spacing.section（回退的：\(padReverted)）", padReverted.isEmpty)

// 板块图标 / 色映射单一真源
let secSrc = src("qingliao/Features/Life/LifeSection.swift")
let needIcons = ["case .memo: return \"square.and.pencil\"", "case .todo: return \"checklist\"",
                 "case .habit: return \"checkmark.seal\"", "case .goals: return \"target\"",
                 "case .record: return \"sum\"", "case .automations: return \"clock.arrow.circlepath\"",
                 "case .lifeCards: return \"chart.line.uptrend.xyaxis\""]
check("LifeSection 七个板块 icon 映射齐全（标题行图标的单一真源）",
      needIcons.allSatisfy { secSrc.contains($0) })
check("LifeSection tint 映射只有一处（不许在调用点各写各的色）",
      secSrc.components(separatedBy: "var tint: Color").count - 1 == 1)
// 上面那条只数 LifeSection.swift 本文件，防不住「调用点各写各的色」→ 逐调用点扫
let iconCallSites = ["qingliao/Features/Life/MemoSection.swift", "qingliao/Features/Life/TodoSection.swift",
                     "qingliao/Features/Life/HabitSection.swift", "qingliao/Features/Life/GoalsSection.swift",
                     "qingliao/Features/Life/RecordSection.swift"]
let tintDrifted = iconCallSites.filter { !src($0).contains("sectionIconTint: LifeSection.") }
check("五个板块的图标底色一律取 LifeSection 映射（漂移的：\(tintDrifted)）", tintDrifted.isEmpty)
// 定义好却没人消费 = 死映射（2026-10-09 审查抓到 automations 就是这么漏的）
check("七个板块映射都至少被一处引用（automations 标题行已接上 icon/tint）",
      src("qingliao/Features/Life/AutomationsSection.swift").contains("LifeSection.automations.icon")
        && src("qingliao/Features/Life/AutomationsSection.swift").contains("LifeSection.automations.tint"))

// 拍 3：勾选态过渡（行状态变化口径）
let todoSrc = src("qingliao/Features/Life/TodoSection.swift")
check("待办勾选两处都走 Motion.snap（原来硬切）",
      todoSrc.components(separatedBy: "withAnimation(Motion.snap) { TodoStore.shared.toggleDone").count - 1 >= 1
        && todoSrc.components(separatedBy: "withAnimation(Motion.snap) { store.toggleDone(current)").count - 1 >= 1)

// ── 5. 拍 4：骨架 → 内容不再硬切
let lifeCards = src("qingliao/Features/Dashboard/LifeCardsSection.swift")
// 🚨 2026-10-09 审查：骨架的显隐判据是 `!data.loaded && loading`（见 content 里的 if），
//    只拿 loading 当 value 时，若「数据到了」与「loading 归假」落在不同更新帧 → 骨架→内容硬切（无报错）
check("拍 4 骨架淡出 + 减动效出口（Motion.settle；驱动值覆盖 data.loaded 与 loading 两个边界）",
      lifeCards.contains(".animation(reduceMotion ? nil : Motion.settle, value: !data.loaded && loading)"))

print("色彩令牌口径真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
