import SwiftUI

/// 页头右上角图标胶囊的**统一入口**（会话页 / 聊天页）。
///
/// 沿革（都是用户真机复测后拍板的结论，别按旧结论改回去）：
///   · v4.0.61（用户 2026-10-05）：「会话页右上角三个图标风格各不一样」「聊天首页右上角图标也是一样」→「用统一的胶囊风格」。
///   · v4.0.62：胶囊「适当调小」+ 图标统一走**圆环家族**——归档 `archivebox.circle` ↔ `.fill`（描边↔实心）、
///     多选 `checkmark.circle` ↔ `xmark.circle`、新建 `plus.circle`；聊天页 `list.bullet.circle` / `ellipsis.circle`。
///     依据：这几个符号的位图画布实测**全 44px**（其余候选 39~53px 参差），光学方框最齐。
///     v4.0.61 的「外环图标 + 胶囊底 = 双圈」顾虑经用户看稿后作废（**不要再改回裸字形**）。
///   · v4.1.x（用户 2026-10-05 看对比稿拍板「方案 A + 图标 14」）：**多颗独立胶囊合并成一整颗**。
///     稿：/opt/data/scripts/ql_header_pill/mock/out/pill_iconsize.png（生成器同目录 gen_*_pill*.py）
///     用户给的参考图逐像素量测：胶囊药丸形（圆角 = 高/2）、图标高 ≈ 0.31×胶囊高、
///     图标中心距 ≈ 0.878×胶囊高、端部内边距 ≈ 0.355×胶囊高、图标纯黑、无描边无阴影。
///     ⚠️ 参考图那颗胶囊是**纯白底压浅灰页**（#FCFCFC on #F1F1F1，亮度差 11）；本仓页面底是**纯白**，
///     纯白胶囊压上去亮度差 = 0 → 边界直接消失。故**沿用全站玻璃底**（glassPillStroke），不照搬白底。
///
/// ⚠️ **本档不进 `PillSize` 三档口径**：那三档是"操作胶囊"（文字按钮），Pill.swift 头注释明令
/// 「不在口径内的不要硬套，各自合适即可」。页头**图标**胶囊按视觉需要单独定；
/// **玻璃/描边不另起一套**——一律走 `glassPillStroke()`（原生液态玻璃 + 同色 0.8pt 描边，Pill.swift 出口）。
///
/// 其余两条统一约束（原先各不相同，正是用户看到的问题）：
///   · 图标字号/字重一律走本档常量（不再 headline vs title、medium vs semibold 各写各的）
///   · 前景色一律 `Color.accentColor`（= `PillTone.accent.fg`；不走 pill 后必须自己带，否则静默变黑/白）
///
/// 状态靠**图标形态**区分、不靠色调（并排颜色一致才叫统一）：
///   归档箱 `archivebox.circle` ↔ `archivebox.circle.fill`；多选 `checkmark.circle` ↔ `xmark.circle`（编辑中）。
///
/// 用它的地方：会话页（归档箱 / 多选 / 新建）、聊天页（任务中心 / 更多）。
/// 新增页头图标一律走这里，别再写裸 `Image(systemName:)` + 自定义 buttonStyle。
struct HeaderPillGroup: View {
    /// 胶囊里的一颗图标
    struct Item {
        /// 稳定身份（列表 id）——**不能用下标**：会话页空态↔非空是在头部**前插**两枚
        /// （空态 `[plus]`、非空 `[archive, multi, plus]`），下标会把 archive 复用成原 plus 的身份，
        /// 而 `.symbolEffect(.bounce, value:)` 比的正是同一身份上的值 → 会误触发一次弹动。
        /// 也别用 systemName/a11y 当 id（编辑态会换符号名/文案）。
        let id: String
        let systemName: String
        let a11y: String
        /// 右上角红点（任务中心「有未完成任务」这类）——尺寸写死 7pt，与旧手写角标同档
        var badge: Bool = false
        /// 需要弹动反馈的入口（新建会话）传自增的 tick；不需要的保持 0
        var bounceTick: Int = 0
        let action: () -> Void
    }

    let items: [Item]

    // ── 尺寸单一真源（改口径只改这里；调用方别再各写 8/10/12）──
    /// 图标字号：12 → **14**（v4.1.x 用户在 13/14/15 三档对比稿里选 14）
    static let iconFont: CGFloat = 14
    /// 胶囊高：**34pt**（照参考图比例换算后定；与用户拍板过的「工具栏胶囊高 34」同档）
    static let height: CGFloat = 34
    /// 相邻图标**中心距** = 0.878 × 胶囊高 ≈ **30pt**（照参考图比例）。
    /// ⇒ 图标字号变大时**中心距不变**、净空自动收窄 → 整颗胶囊总宽几乎不变
    ///   （用户要的"图标更大"因此不占额外顶栏宽度）。
    static let centerGap: CGFloat = 30
    /// 胶囊两端内边距 = 0.355 × 胶囊高 ≈ **12pt**（照参考图比例）
    static let edgePad: CGFloat = 12
    /// 图标之间净空 = 中心距 − 图标字号（14 → 16pt）
    static var innerGap: CGFloat { centerGap - iconFont }
    /// 单颗图标的横向命中外扩：中心距 30 − 图标 14 → 每侧 8，两两**相接不重叠**。
    /// ⚠️ 合并的固有代价：横向命中区 30pt（合并前每颗独立胶囊可给到 44pt）；
    ///    纵向仍补满 44pt。若将来嫌小，只能把 centerGap 一并放大（胶囊会变宽）。
    static let hitH: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.innerGap) {
            // id 由调用方给稳定串（见 Item.id 注释：下标在头部前插下不稳定，会让弹动反馈误触发）
            ForEach(items, id: \.id) { item in
                itemView(item)
            }
        }
        .padding(.horizontal, Self.edgePad)
        .frame(height: Self.height)
        .glassPillStroke()
    }

    private func itemView(_ item: Item) -> some View {
        Button(action: item.action) {
            Image(systemName: item.systemName)
                .symbolEffect(.bounce, value: item.bounceTick)
                .font(.system(size: Self.iconFont, weight: .semibold))
                // v4.0.62 审查（阻断级，本批自伤）：`glassPillStroke()` 只加玻璃 + 描边、
                // **不设前景色** → 漏了这行图标会静默由蓝变黑/白。
                .foregroundStyle(Color.accentColor)
                // v4.0.65 审查（严重，本批自伤）：把 label 撑到**囊高**。
                // 第 71 行 HStack 的 `.frame(height:)` **不拉伸子视图** —— label 只有 Image 时
                // 自身高 ≈17pt（14pt 符号固有高），`.hitArea44(v: 5)` 只能补到 ≈27pt；
                // 而旧实现（padding 挂在按钮自身、按钮高 ≈27）能到 ≈49pt → 静默的点击目标回归。
                // 补满后：34 + 2×5 = 44（与下面 hitArea44 的注释一致）。
                .frame(height: Self.height)
                .overlay(alignment: .topTrailing) {
                    if item.badge {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1))
                            .offset(x: 5, y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 命中区：横向 14 + 2×8 = 30（= 中心距，与邻项相接不重叠）、
        // 纵向 34（上面 `.frame(height: Self.height)` 撑出来的 label 高）+ 2×5 = 44
        .hitArea44(h: Self.hitH, v: 5)
        .accessibilityLabel(item.a11y)
    }
}
