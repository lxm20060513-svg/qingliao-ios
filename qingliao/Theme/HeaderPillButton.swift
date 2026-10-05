import SwiftUI

/// v4.0.61：页头右上角图标按钮的**统一胶囊**入口（用户 2026-10-05：
/// 「会话页右上角三个图标风格各不一样」「聊天首页右上角图标也是一样」→「用统一的胶囊风格」）。
///
/// 形态 = 全站既有胶囊口径里的 **topBar 档**（`PillSize.topBar`：subhead + h14/v7 +
/// `.glassEffect(.regular.interactive())` + 同色 0.8pt 描边）——Pill.swift 头注释写明这档就是
/// 「顶栏 / 工具条」（备忘录详情的 关闭 / 编辑 / 复制），页头图标正属此类，所以**不新造口径**：
/// 内容交给 `.pill(.topBar)`，尺寸/玻璃/描边与站内其它顶栏胶囊永远同参。
///
/// 三条统一约束（原先各不相同，正是用户看到的问题）：
///   · 图标字号一律走 pill(.topBar)（不再 headline vs title 各写各的）
///   · 底一律原生液态玻璃胶囊（`pill(.accent)` 分支；玻璃挂在**内容**上——
///     background 装饰层上 `interactive()` 无效，见 ios-liquid-glass-patterns）
///   · 命中区一律 44pt（`.hitArea44(h:4,v:4)`：胶囊约 41×31，补到 44 不改布局）
///
/// 状态靠**图标形态**区分、不靠色调（三个并排颜色一致才叫统一）：
///   归档箱 archivebox ↔ tray.full；多选 checkmark ↔ xmark（编辑中）.
///
/// 用它的地方：会话页（归档箱 / 多选 / 新建）、聊天页（任务中心 / 更多）。
/// 新增页头图标一律走这里，别再写裸 `Image(systemName:)` + `.buttonStyle(PressStyle())`。
struct HeaderPillIconButton: View {
    let systemName: String
    var a11y: String
    /// 右上角红点（任务中心「有未完成任务」这类）——尺寸写死 7pt，与旧手写角标同档
    var badge: Bool = false
    /// 需要弹动反馈的入口（新建会话）传自增的 tick；不需要的保持 0
    var bounceTick: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .symbolEffect(.bounce, value: bounceTick)
                .pill(.topBar)                               // ← 尺寸/玻璃/描边单一真源（Pill.swift）
                .fontWeight(.semibold)                       // v4.0.61 审查 6：必须在 pill **之后**——pill 内部 .font(...) 会覆盖前面的 fontWeight
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1))
                            .offset(x: 5, y: -3)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hitArea44(h: 4, v: 4)
        .accessibilityLabel(a11y)
    }
}
