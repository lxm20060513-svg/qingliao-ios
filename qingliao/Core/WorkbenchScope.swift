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
}
