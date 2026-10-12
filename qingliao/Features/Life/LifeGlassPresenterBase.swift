import SwiftUI

// MARK: - v4.0.86（瘦身①）：生活页五 Section 浮层 Presenter 的泛型基类
//
// 背景（瘦身盘点 2026-10-09，报告 cache/scratch/slimming-audit-20261009.md）：
//   HabitSection / TodoSection / MemoSection / GoalsSection / RecordSection 各自持有
//   一份 XxxGlassPresenter，字段与 reset() 逐字同构（只差 Item 类型；Record 多
//   editSession / filterCategory 两个字段）——五份 × 28~36 行 ≈ 148 行重复。
//
// 设计约束（沿用 LifeSectionScaffold 头注释的口径）：
//   · 只收「去掉标识符后逐字相同」的部分；差异字段（editSession / filterCategory）
//     留在 RecordGlassPresenter 自己身上，不为收拢硬塞基类。
//   · 基类 @MainActor @Observable；子类仅剩 `static let shared` + 专属字段，
//     外部调用点（glass.showAll 等）一个字都不用改。
//   · 泛型参数只用于 `detail: Item?` 的类型，不引入任何行为。

/// v4.0.102：生活页栏目内「危险动作」确认的种类（各 Section 自己解释语义并执行动作）。
/// 与 `LifeGlassPresenterBase.confirmKind` 配套 —— 由页级 GlassLayerHost 渲染成锚定浮层。
enum LifeConfirmKind: Sendable {
    /// 清理已完成（仅待办）
    case clearCompleted
    /// 清空全部（待办 / 长期目标）
    case clearAll
}

@MainActor
@Observable
class LifeGlassPresenterBase<Item: Sendable> {
    /// 「全部 ××」列表浮层
    var showAll = false
    /// 「新建 ××」浮层
    var showAdd = false
    /// 详情浮层（nil = 不显示）
    var detail: Item?
    /// 宿主（页卡）删除二次确认：页卡长按「删除」置这里 → 由各 Section 的 LifeDeleteConfirm 呈现。
    /// ⚠️ 浮层内列表的删除多数不走这里（浮层盖住时宿主 alert 看不见），由各 AllListBody 自带的一份管。
    var pendingDelete: Item?
    /// 新建浮层的会话序号：每次打开自增，配合 `.id()` 强制换新实例（保证每次都是空编辑器）
    var addSession = 0

    /// v4.0.102：栏目内「危险动作」的**锚定确认浮层**（nil = 不显示）。
    /// 由头：待办的「清理已完成 / 清空全部」原来是 confirmationDialog —— iPhone 上系统动作表
    /// 固定从屏幕底部升起、锚不到被点的胶囊；而栏目自己挂浮层会被后面的 Section 盖住
    /// （v4.0.77 教训）→ 状态提到页级单例，浮层由各 GlassLayerHost（挂在生活页根）呈现。
    var confirmKind: LifeConfirmKind?
    /// 上面那个确认浮层的锚点（被点的胶囊按钮的全局 frame）
    var confirmAnchor: CGRect = .zero

    init() {}

    /// 宿主销毁时清状态 —— 单例不会随视图树消失，页面被系统回收后重建、开关还是 true →
    /// 回到生活页会「莫名又弹着上次那个浮层」。挂在各 GlassLayerHost 的 .onDisappear 上
    /// （宿主与生活页同生共死）。子类重写时必须 super.reset()。
    func reset() {
        showAll = false
        showAdd = false
        detail = nil
        pendingDelete = nil
        addSession = 0
        confirmKind = nil
        confirmAnchor = .zero
    }
}
