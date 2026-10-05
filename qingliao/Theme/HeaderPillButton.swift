import SwiftUI

/// v4.0.61：页头右上角图标按钮的**统一胶囊**入口（用户 2026-10-05：
/// 「会话页右上角三个图标风格各不一样」「聊天首页右上角图标也是一样」→「用统一的胶囊风格」）。
///
/// v4.0.62（用户 2026-10-05 真机 4.0.61 复测）：胶囊「适当调小」+「里面的图标不协调」
///   · 尺寸：从 `PillSize.topBar`（subhead 13 + h14/v7 → 约 41×31pt）收到本档（icon 12 + h11/v5 → 约 34×25pt），
///     间距由调用方从 12 → 8（`HeaderPillIconButton.spacing`）。
///   · 图标：统一走**圆环家族**（用户 2026-10-05 在对比稿里选 B 组）——
///     归档 `archivebox.circle` ↔ `archivebox.circle.fill`、多选 `checkmark.circle` ↔ `xmark.circle`、
///     新建 `plus.circle`；聊天页 任务中心 `list.bullet.circle` / 更多 `ellipsis.circle`。
///     依据：这几个符号的位图画布实测**全 44px**（其余组合 39~53px 参差），光学方框最齐；
///     代价是圆环笔画偏多，12pt 下略碎 —— 用户已明确选择「要外环」，
///     故 v4.0.61 的「外环与胶囊底成双圈」顾虑就此作废（不要再按那条改回去）。
///
/// ⚠️ **本档不进 `PillSize` 三档口径**：那三档是"操作胶囊"（文字按钮），Pill.swift 头注释明令
/// 「不在口径内的不要硬套，各自合适即可」。页头**图标**胶囊按视觉需要单独定，
/// 与 `chatHeaderPill()` / `sectionHeaderPill()` 属同一类专用档；
/// **玻璃/描边不另起一套**——一律走 `glassPillStroke()`（原生液态玻璃 + 同色 0.8pt 描边，Pill.swift 出口）。
///
/// 其余两条统一约束（原先各不相同，正是用户看到的问题）：
///   · 图标字号/字重一律走本档常量（不再 headline vs title、medium vs semibold 各写各的）
///   · 前景色一律 `Color.accentColor`（= `PillTone.accent.fg`，与站内胶囊同色；不走 pill 后必须自己带）
///   · 命中区一律 ≥44pt（`.hitArea44(h: 5, v: 11)`：胶囊约 34×25，补到 44×46；hitArea44 净外扩为 0，不改布局）
///
/// 状态靠**图标形态**区分、不靠色调（三颗并排颜色一致才叫统一）：
///   归档箱 `archivebox.circle` ↔ `archivebox.circle.fill`（描边 ↔ 实心）；多选 `checkmark.circle` ↔ `xmark.circle`（编辑中）。
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

    // ── 尺寸单一真源（改口径只改这里；调用方排一排时用 spacing，别再各写 8/10/12）──
    /// 图标字号：13 → 12
    static let iconFont: CGFloat = 12
    /// 横向内边距：14 → 11
    static let hPad: CGFloat = 11
    /// 纵向内边距：7 → 5
    static let vPad: CGFloat = 5
    /// 同排多枚时的横向间距（原 12 → 8）
    static let spacing: CGFloat = 8

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .symbolEffect(.bounce, value: bounceTick)
                .font(.system(size: Self.iconFont, weight: .semibold))
                // v4.0.62 审查（阻断级，本批自伤）：原来 `.pill(.topBar)` 走 accent 分支会带
                // `.foregroundStyle(PillTone.accent.fg = Color.accentColor)`；本档不再走 pill，
                // 而 `glassPillStroke()` 只加玻璃 + 描边、**不设前景色** → 漏了这行图标会静默由蓝变黑/白。
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, Self.hPad)
                .padding(.vertical, Self.vPad)
                // 玻璃 + 同色描边的单一真源（Pill.swift 出口；不新造玻璃写法）
                .glassPillStroke()
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
        // 胶囊 34×25 → 命中区补到 44×46（h5/v11；净外扩 0）
        // v4.0.62 审查：v 从 10 收到 11 —— 图标行高约 14.3pt 时胶囊约 24.3，
        // v:10 只到 44.3 贴线，留一点余量（不改布局，只是把可点范围放大）
        .hitArea44(h: 5, v: 11)
        .accessibilityLabel(a11y)
    }
}
