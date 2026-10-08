//
//  WorkbenchScope.swift
//  轻聊
//
//  P2 入口收敛：「工作模式下各页该收哪些、该放哪些」的**唯一口径文件**（纯逻辑，无 SwiftUI 依赖）。
//
//  为什么需要它：P2 的改动（首页 17 卡收敛到 4 张快捷 / 生活页板块移出到看板 / 看板收进）
//  全部**只对工作模式生效**，而生活模式必须一行行为都不变（用户红线：修复不得误伤在用功能）。
//  差异点若散在各地（首页一处 if、生活页一处 if、看板一处 if），回归时无从核对、回退时无从下手 ——
//  所以口径全部收在本文件：视图层只问「这个页在工作模式下的目录是什么」，不自己写 if。
//
//  口径取值怎么传（**为什么不用 SwiftUI Environment**）：
//    · 首页卡片网格 `HomeCardsGrid` 的渲染列表是 `@State` 初值（`HomeCardStore.off` / `fullOrder`），
//      @State 初值在 init 期求值 —— **拿不到 Environment**（Environment 在 body 期才可用）。
//      若改成 body 期再回填，工作模式首帧会先画一版生活模式的卡再跳变（闪一下），
//      正是本仓反复踩过的「先白后切」那一类。
//    · 所以模式取「**进程启动一次**」的常量 `WorkbenchScope.launched`（与 `UIMode.launchedWith`
//      同口径：界面模式本就是重启生效）—— init 期、body 期、纯逻辑函数里读到的都是同一个值。
//  ⚠️ 写入点**全 App 只有一处**：`WorkbenchRoot.init`（工作模式壳构造时声明自己的口径）。
//     生活模式那条路径不构造 `WorkbenchRoot`，所以读到的永远是默认 `.life` —— 这就是
//     「生活模式零变更」在代码层面成立的原因（真值表正反两面都钉着）。
//
//  ⚠️ 本文件是**纯 Foundation**（真值表直接编译它，Linux 上没有 SwiftUI）：
//     不许 import SwiftUI、不许引用 `enum LifeSection` / `struct BoardCard` 之外的 SwiftUI 类型。
//     生活页板块那两个 rawValue 因此以**字符串常量**形式放在这里（见下方注释）。
//

import Foundation

/// 工作台口径 —— 与 `Core/UIMode.swift` 的界面模式一一对应，但**是两件事**：
/// 界面模式管「启动哪套根壳」，本枚举管「这套壳里各页的目录口径」。
/// 分开命名是为了让生活模式那份代码**看不出模式的存在**（`DockTabView.swift` 全篇不许出现任一个）。
enum WorkbenchScope: String, CaseIterable {
    case life
    case work

    /// 启动常量：默认 `.life`（没被声明过 = 生活模式那条路）。只在 `adopt` 里被改。
    nonisolated(unsafe) private static var _launched: WorkbenchScope = .life

    /// 本进程的口径（启动一次，进程内不再变）
    static var launched: WorkbenchScope { _launched }

    /// 声明口径。**唯一合法调用点 = `WorkbenchRoot.init`**（真值表钉住调用点数量）。
    /// 幂等：SwiftUI 可能多次构造根壳，重复声明同值无副作用。
    static func adopt(_ scope: WorkbenchScope) { _launched = scope }

    /// 回到未声明状态。**只给真值表用**（用例之间隔离），生产代码不许调（真值表钉住）。
    static func resetForTesting() { _launched = .life }
}

/// P2 各页的目录口径（纯函数，全部按 scope 分流；`switch` 只出现在本文件里）。
enum WorkbenchLayout {

    // MARK: - 首页方块卡（P2 条目 10 / 11 / 12）

    /// 工作模式首屏默认展开的**快捷四张**（改这里 = 改工作模式首屏，别处不许再写一份）。
    static let workShortcutKinds: [HomeCardKind] = [.resume, .todo, .weather, .expense]

    /// 工作模式默认收起的卡 = 全部可拖拽卡 − 快捷四张。
    /// 语义是「**默认收起**」而不是「删掉」：其余卡仍留在卡片库里，用户随时能开
    /// （老用户已经存过 `qingliao_home_card_off` 的，一律听用户的，见 `HomeCardStore.off`）。
    static var workDefaultOff: [HomeCardKind] {
        HomeCardKind.draggable.filter { !workShortcutKinds.contains($0) }
    }

    /// 首页卡片目录。工作模式**不含「空槽位」**（P2 条目 12：删掉首页末尾空槽位卡，
    /// 添加入口由页头「自定义」胶囊承担，冷启动引导交给 P4）；
    /// 生活模式 = `allCases`（历史口径，一个都不许少）。
    static func homeCardCatalog(_ scope: WorkbenchScope) -> [HomeCardKind] {
        switch scope {
        case .life: return HomeCardKind.allCases
        case .work: return HomeCardKind.allCases.filter { $0 != .custom }
        }
    }

    /// 首页卡片的默认收起档（键没存过时的兜底）。工作模式 = 快捷四张之外全收；
    /// 生活模式 = 历史默认档（`HomeCardStore.defaultOff`，逐字不变）。
    static func homeCardDefaultOff(_ scope: WorkbenchScope) -> [HomeCardKind] {
        switch scope {
        case .life: return HomeCardStore.defaultOff
        case .work: return workDefaultOff
        }
    }

    // MARK: - 生活页板块（P2 条目 8：移出「定时任务 / 生活数据」）

    /// 移出板块的 rawValue 常量（**单一真源**，别处不许再写这两个字面量）。
    ///
    /// ⚠️ 为什么是字符串而不是 `LifeSection` 枚举：
    ///   1) 本文件是纯 Foundation（真值表编译它），而 `enum LifeSection` 住在
    ///      `Features/Life/LifeSection.swift`（那个文件 import SwiftUI 且带编辑器视图）——
    ///      引用它 = 第 49/93 段编不过；
    ///   2) `LifeSection` 的自己那份串还牵着三条既有护栏（ql_uimode_root / ql_habit 读该文件文本、
    ///      check_swift 第 72 段 grep `case habit`）—— 为省一次字符串比对搬动枚举不值当。
    ///   字面量一致性由 ql_workbench 真值表**源码断言**钉住（该文件里必须真有这两个 case、
    ///   逐字相同、且 case 总数 == 7 —— 偷偷加板块而不更新口径必红）。
    static let automationsRaw = "automations"   // 定时任务
    static let lifeCardsRaw = "lifeCards"       // 生活数据（行情 / 资讯 / 快递 / 价格）

    /// 工作模式下从生活页**移出**的板块（条目 8：生活页只留「我的东西」）。
    static let workMovedLifeSectionRaws: [String] = [automationsRaw, lifeCardsRaw]

    /// 生活页的板块目录（rawValue）。生活模式 = 传入的全量**原样返回**（历史口径，一个都不少）；
    /// 工作模式 = 去掉移出的两个。
    /// ⚠️ 传 `allRaws` 而不是在这里内建一份全量表：全量真源永远是 `LifeSection.allCases`，
    ///    在本文件再抄一份 = 第二个真源（本仓「同一份事实写两处」的老坑）。
    static func lifeSectionCatalogRaws(_ scope: WorkbenchScope, allRaws: [String]) -> [String] {
        switch scope {
        case .life: return allRaws
        case .work: return allRaws.filter { !workMovedLifeSectionRaws.contains($0) }
        }
    }

    /// 逗号分隔串 → rawValue 数组（丢空项 + 保序去重）。顺序串与隐藏串共用（原 parse 口径）。
    static func parseRaws(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 生活页板块顺序归一化：已存顺序在前（丢未知键 + 保序去重）→ 目录里没出现的按目录序补到末尾。
    /// 与移出前 `LifeView.orderedSections` 逐字同口径，只是把「全量」换成「本口径目录」。
    static func resolveLifeSectionOrder(order raw: String, catalog: [String]) -> [String] {
        let saved = parseRaws(raw).filter { catalog.contains($0) }
        return saved + catalog.filter { !saved.contains($0) }
    }

    /// 板块编辑器写回（**老配置不丢**，与 P2 条目 11 同一口径）：
    /// 目录外的老条目（工作模式里的「定时任务 / 生活数据」，以及老版本删过的板块）**原样留串** ——
    /// 否则在工作模式里只动一下排序，切回生活模式就发现那两个板块的位置/显隐配置被抹掉了。
    /// （返回顺序串 / 隐藏串，都是逗号分隔 rawValue；口径对标 BoardCardEditorSheet.persist：顺序串写全量。）
    static func mergeLifeSectionPersist(catalog: [String],
                                        shown: [String],
                                        hidden: [String],
                                        prevOrder: [String],
                                        prevHidden: [String]) -> (order: String, hidden: String) {
        let outsideOrder = prevOrder.filter { !catalog.contains($0) }
        let outsideHidden = prevHidden.filter { !catalog.contains($0) }
        let order = parseRaws((shown + hidden + outsideOrder).joined(separator: ","))
        let keptHidden = parseRaws((hidden + outsideHidden).joined(separator: ","))
        return (order.joined(separator: ","), keptHidden.joined(separator: ","))
    }

    // MARK: - 看板收进（P2 条目 9）

    /// 移出后**不需要**在看板再收一份的板块：定时任务。
    /// 理由：看板的「自动化」卡读的就是同一个端点 `/api/automations/list`、同一实体
    /// （同样带倒计时、同样长按可取消）—— 再收一份 = 同一屏两份重复列表，
    /// 正是条目 9 后半「删掉与生活页重复的板块」要避免的。真值表源码断言两个文件都在调这个端点。
    static let workMovedAlreadyOnDashboard: [String] = [automationsRaw]

    /// 工作模式下**看板要多渲染**的生活页板块（按渲染顺序）。生活模式 = 空（看板一个都不多）。
    static func dashboardHostedLifeSectionRaws(_ scope: WorkbenchScope) -> [String] {
        switch scope {
        case .life: return []
        case .work: return workMovedLifeSectionRaws.filter { !workMovedAlreadyOnDashboard.contains($0) }
        }
    }

    /// 看板该不该就地挂载某个生活页板块（视图层问这个，不许自己写 `== .work` 判断）。
    static func dashboardHostsLifeSection(_ raw: String, scope: WorkbenchScope) -> Bool {
        dashboardHostedLifeSectionRaws(scope).contains(raw)
    }
}
