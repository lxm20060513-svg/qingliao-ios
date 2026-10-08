import SwiftUI

// MARK: - P0-2 启动分流（工作模式 / 生活模式）
//
// 依据：`design-plans/finesse-refactor-checklist.md` v2 第 27 项（P0-2 启动分流）。
//
// 口径（用户拍板 + 清单红线）：
//   · **全 App 只有这一处**按界面模式分流 —— 禁止散落 `if UIMode.current == .work`：
//     散落分支等于「两套 UI 的差异点没有清单」，回归时无从核对、也最难回退；
//   · 分流值取 `UIMode.launchedWith`（**进程启动时**读一次），不是 `UIMode.current`：
//     模式本就是「重启生效」口径，读当前值等于把「运行中半切」这种状态引回来；
//   · **生活模式走现有代码原路径、零包装**（life 分支 = 裸 `DockTabView()`）——
//     这是本次改造的红线（不误伤在用功能），护栏 `ql_uimode_root` 正反两面都钉着；
//   · 工作模式（`WorkbenchRoot`）在 P0-2 阶段**与生活模式同形**：界面差异从 P1（首屏结论条）
//     才开始。本步只把「工作模式有自己的根壳」这件事落地，P1–P4 一律只改这个壳内部。
//
// ⚠️ 别把分流写进 `DockTabView` 内部：生活模式那份代码**不许知道模式的存在**
//    （护栏反向断言 `Features/DockTabView.swift` 全篇不出现 `UIMode`）。

/// 根分流点：全 App 唯一决定「用哪套界面」的地方。
struct UIModeRoot: View {
    /// 进程启动时读一次（`launchedWith` 是 static let，懒加载后进程内不再变）
    private let mode: UIMode = UIMode.launchedWith

    var body: some View {
        switch mode {
        case .life:
            // 生活模式 = 冻结基线：现有根视图原样，零包装、零条件、零参数
            DockTabView()
        case .work:
            // 工作模式 = 工作台壳（P1 起逐步长内容；本步与生活模式同形）
            WorkbenchRoot()
        }
    }
}

/// 工作模式根壳。
///
/// P0-2 阶段**故意与生活模式同形**（同样一个 `DockTabView`）：P1 的首屏结论条、P2 的入口收敛、
/// P3 的深度四项、P4 的冷启动引导全部挂进这里，生活模式那条路径一行都不动。
/// 单独立成类型（而不是在 `UIModeRoot` 里传参数）是为了让「工作模式到底改了什么」
/// 在 `git diff` 里落成**一个文件**，评审与回退都好做。
struct WorkbenchRoot: View {
    /// P2：工作模式壳在**构造时**声明自己的口径（全 App 唯一写入点，真值表钉住）。
    /// 放在 init 而不是 body：`HomeCardsGrid` 等视图的渲染列表是 `@State` 初值（init 期求值），
    /// 那时 body 还没跑、Environment 还读不到 —— 见 Core/WorkbenchScope.swift 文件头。
    init() {
        WorkbenchScope.adopt(.work)
    }

    var body: some View {
        DockTabView()
            // P1 首屏结论条：挂在工作模式壳的顶部（`safeAreaInset` 把页面内容整体下移，不盖住任何页头）。
            // 只在**这里**出现 —— 生活模式那条路径不经过 WorkbenchRoot，所以生活模式一行都没变。
            .safeAreaInset(edge: .top, spacing: 0) {
                VerdictBar()
            }
    }
}
