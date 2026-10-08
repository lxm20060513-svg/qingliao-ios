// P0-2 启动分流 / P0-3 命名消歧 / P0-4 生活模式基线 真值表 —— Linux 本地预检用
//
// 编译运行（仓库根目录，权威入口是 check_swift.sh 第 91 段）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_uimode_root \
//       scripts/ql_uimode_root/truth_table_uimode_root.swift qingliao/Core/UIMode.swift
//
// 为什么需要这张表（三条都是「编译不报、真机才炸 / 只有肉眼看得见」）：
//   ① **唯一分流点**：`UIModeRoot` 是全 App 仅有的按界面模式分流的地方。一旦有人在
//      某个页面里顺手再来一个模式判断，两套 UI 的差异点就散了 —— 回归时无从核对、回退时无从下手。
//      所以断言**扫全仓**（不是只看两个文件）；
//   ② **生活模式零变更**（用户红线：修复不得误伤在用功能）：life 分支必须是裸 DockTabView，
//      且 DockTabView.swift 全篇不许出现模式枚举（生活模式那份代码不许知道模式的存在）；
//   ③ **生活模式基线**：首页 17 卡顺序 / 生活页 7 板块 / dock 5 槽（智慧球固定第 3 槽）。
//      这些数字写在清单里、也写在代码里，两边一旦漂移，工作模式的改造就会**悄悄**改到生活模式。
//
// 口径：断言只看**代码**（`code()` 先剥掉整行注释）——注释里为了讲清道理举的例子字面量
// 不该被当成违规；反过来，代码里真出现就是真违规。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉**整行注释**后的源码（注释里举例用的字面量不算违规；代码里的才算）
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

/// 枚举体的 case 名列表（按声明序；`case a, b, c` 一行多值也拆开；行尾注释丢弃）
func caseNames(_ src: String, _ enumFrom: String, _ enumTo: String) -> [String] {
    let body = slice(src, enumFrom, enumTo)
    var out: [String] = []
    for raw in body.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("case ") else { continue }
        for token in line.dropFirst(5).split(separator: ",") {
            let name = token.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { out.append(name) }
        }
    }
    return out
}

/// 全仓 Swift 源（App + 两个扩展）——「唯一分流点」这类断言必须扫全仓才对得上口径
func repoSources() -> [(String, String)] {
    let fm = FileManager.default
    var out: [(String, String)] = []
    for root in ["qingliao", "qingliaoWidget", "qingliaoShare"] {
        guard let en = fm.enumerator(atPath: root) else { continue }
        for case let rel as String in en where rel.hasSuffix(".swift") {
            let path = root + "/" + rel
            out.append((path, code(read(path))))
        }
    }
    return out.sorted { $0.0 < $1.0 }
}

@main
struct UIModeRootTruthTable {

    static let rootSrc = read("qingliao/Core/UIModeRoot.swift")
    static let rootCode = code(rootSrc)
    static let appSrc = read("qingliao/QingliaoApp.swift")
    static let appCode = code(appSrc)
    static let aboutSrc = read("qingliao/Features/Settings/SettingsModelProvider.swift")
    static let aboutCode = code(aboutSrc)
    static let dockSrc = read("qingliao/Features/DockTabView.swift")
    static let dockCode = code(dockSrc)
    static let cardSrc = read("qingliao/Core/HomeCardOrder.swift")
    static let lifeSrc = read("qingliao/Features/Life/LifeSection.swift")
    static let sheetSrc = read("qingliao/Features/Settings/UIModeSheet.swift")
    static let sheetCode = code(sheetSrc)
    static let indexSrc = read("qingliao/Core/SettingsSearchIndex.swift")

    static let repo = repoSources()

    /// 出现某串的文件清单（仓内相对路径）
    static func files(containing needle: String) -> [String] {
        repo.filter { $0.1.contains(needle) }.map(\.0)
    }

    static func runAllTests() {

        // ── 0. 源可读 / 全仓扫描有效（读不到 = 后面全空串假绿，先兜住）──
        for (label, src) in [("UIModeRoot.swift", rootSrc), ("QingliaoApp.swift", appSrc),
                             ("SettingsModelProvider.swift", aboutSrc), ("DockTabView.swift", dockSrc),
                             ("HomeCardOrder.swift", cardSrc), ("LifeSection.swift", lifeSrc),
                             ("UIModeSheet.swift", sheetSrc), ("SettingsSearchIndex.swift", indexSrc)] {
            positives += 1
            check("源可读：\(label)", !src.isEmpty)
        }
        positives += 1
        check("全仓 Swift 源扫描有效（\(repo.count) 个文件，≥ 100）", repo.count >= 100)
        positives += 1
        check("根分流文件在扫描集内（否则「唯一」断言等于没扫）",
              repo.contains { $0.0 == "qingliao/Core/UIModeRoot.swift" })

        // ── 1. 唯一分流点（正向）──
        positives += 1
        check("UIModeRoot 按启动时值分流（用 launchedWith，不是运行期现值）",
              rootCode.contains("UIMode.launchedWith"))
        positives += 1
        check("分流是 switch 两个模式（不是散判）",
              rootCode.contains("switch mode") && rootCode.contains("case .life:") && rootCode.contains("case .work:"))
        positives += 1
        check("life 分支渲染 DockTabView（现有根视图）",
              slice(rootCode, "case .life:", "case .work:").contains("DockTabView()"))
        positives += 1
        check("work 分支渲染 WorkbenchRoot（工作模式独立根壳）",
              slice(rootCode, "case .work:", "\n}").contains("WorkbenchRoot()"))
        positives += 1
        check("分流点与工作模式壳各自独立成类型",
              rootCode.contains("struct UIModeRoot: View") && rootCode.contains("struct WorkbenchRoot: View"))
        positives += 1
        check("RootView 的根视图调用点已换成 UIModeRoot()", appCode.contains("UIModeRoot()"))
        positives += 1
        check("全仓只有 UIModeRoot.swift 读启动分流值（launchedWith 仅 1 处）",
              files(containing: "UIMode.launchedWith") == ["qingliao/Core/UIModeRoot.swift"])
        positives += 1
        check("全仓没有任何地方按运行期现值判模式分流（零命中）",
              files(containing: "UIMode.current ==").isEmpty)

        // ── 2. 生活模式零变更（红线：不许误伤在用功能）──
        let lifeBranch = slice(rootCode, "case .life:", "case .work:")
        positives += 1
        check("life 分支零包装：不套任何工作模式壳 / 不改参数",
              !lifeBranch.contains("Workbench") && !lifeBranch.contains("workMode"))
        negatives += 1
        check("反例：QingliaoApp.swift 不许再直接调 DockTabView()（分流已收口，绕过去 = 两处入口）",
              !appCode.contains("DockTabView()"))
        negatives += 1
        check("反例：DockTabView.swift 全篇不许出现 UIMode（生活模式代码不许知道模式存在）",
              !dockCode.contains("UIMode"))
        negatives += 1
        check("反例：UIModeRoot 不许用 @AppStorage（那是热切换；模式只在启动时读一次）",
              !rootCode.contains("@AppStorage"))
        negatives += 1
        check("反例：UIModeRoot 不许发通知 / 监听通知（不做热切换）",
              !rootCode.contains("NotificationCenter"))
        negatives += 1
        check("反例：UIModeRoot 不许读运行期现值（读它 = 半切状态）",
              !rootCode.contains("UIMode.current"))
        negatives += 1
        check("反例：UIModeRoot 不许 import UIKit（根视图分层里没它的事）",
              !rootCode.contains("import UIKit"))
        negatives += 1
        check("反例：UIModeRoot 不许自己落 UserDefaults（写盘只走 UIMode 一个口）",
              !rootCode.contains("UserDefaults"))
        negatives += 1
        check("反例：不许新增底部 tab（DockTab 保持 5 个）",
              caseNames(dockSrc, "enum DockTab: String", "var id: String").count == 5)
        // v4.0.72 回退护栏之外再补一条生活模式基线：启动链折叠修饰器不许动（改链 = 生活模式行为改变）
        negatives += 1
        check("反例：DockTabView 的 4 段启动链修饰器仍在（生活模式基线不许被动）",
              ["DockTabChrome1", "DockTabChrome2", "DockTabChrome3", "DockTabChrome4"]
                .allSatisfy { dockCode.contains("modifier(\($0)(host: self))") })

        // ── 3. 生活模式基线（P0-4 只读回归清单，钉在源码结构上）──
        positives += 1
        check("dock 槽位序 = 会话/生活/聊天/看板/设置（用户 2026-10-07 拍板）",
              caseNames(dockSrc, "enum DockTab: String", "var id: String")
                == ["sessions", "life", "chat", "dashboard", "settings"])
        positives += 1
        check("dock 槽位序第 3 项为 chat（切页微滑方向判据；几何已与槽位号无关）",
              caseNames(dockSrc, "enum DockTab: String", "var id: String")[2] == "chat")
        let cards = caseNames(cardSrc, "enum HomeCardKind: String", "/// 默认展示顺序")
        positives += 1
        check("首页卡 17 类且顺序不被本次改造打乱（实得 \(cards.count) 类）",
              cards == ["mail", "resume", "todo", "weather", "expense", "agentTip",
                        "nextReminder", "memo", "express", "stock", "kb", "scene",
                        "device", "cloud", "goal", "clipboard", "custom"])
        positives += 1
        check("首页默认顺序仍取 allCases（没被工作模式另接一套）",
              cardSrc.contains("static var catalogOrder: [HomeCardKind] { allCases }"))
        let sections = caseNames(lifeSrc, "enum LifeSection: String", "var id: String { rawValue }")
        positives += 1
        check("生活页 7 板块且顺序不变（实得 \(sections.count) 个）",
              sections == ["memo", "todo", "habit", "goals", "record", "automations", "lifeCards"])
        positives += 1
        check("关于页仍保留运行模式行（改名不许把行删了）", aboutCode.contains("appModeRow()"))

        // ── 4. P0-3 命名消歧（两个「模式」不许再同名）──
        positives += 1
        check("关于页已改名「AI 运行模式」", aboutCode.contains("aboutRow(\"AI 运行模式\""))
        positives += 1
        check("关于页文案里「当前模式」已清零（与界面模式不再撞名）",
              !aboutCode.contains("\"当前模式\""))
        positives += 1
        check("aboutRow 支持标题列宽（6 字标题不被压成折行）",
              aboutCode.contains("titleWidth: CGFloat = 44") && aboutCode.contains(".frame(width: titleWidth"))
        positives += 1
        check("「界面模式」入口仍在（改名动作不许牵连 P0-1 那一行）",
              aboutCode.contains("界面模式") == false && indexSrc.contains("route: \"uiMode\", title: \"界面模式\""))
        negatives += 1
        check("反例：关于页不许把界面模式当成自己的行（两处语义不许混）",
              !aboutCode.contains("aboutRow(\"界面模式\""))
        negatives += 1
        check("反例：界面模式弹窗不许被这次改名牵连（不许出现「AI 运行模式」）",
              !sheetCode.contains("AI 运行模式"))
        negatives += 1
        check("反例：P0-1 的「重启生效」提示不许被碰掉（UIModeSheet 仍含该文案）",
              sheetCode.contains("重启 App 后生效") && sheetCode.contains("showRestartHint"))

        // ── 收尾 ──
    }

    static func main() {
        runAllTests()
        let total = positives + negatives
        let ratio = total == 0 ? 0 : Double(negatives) / Double(total)
        check("反例 ≥ 四分之一（正例 \(positives) / 反例 \(negatives) / 占比 \(Int(ratio * 100))%）",
              ratio >= 1.0 / 4.0)
        print(failures == 0 ? "\n🎉 全部通过（0 失败）" : "\n❌ \(failures) 个失败")
        exit(failures == 0 ? 0 : 1)
    }
}
