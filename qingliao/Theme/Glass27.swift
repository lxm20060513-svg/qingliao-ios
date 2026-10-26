import SwiftUI

// MARK: - iOS 27 液态玻璃口径（自绘面的**唯一**调参面板 · v4.0.161 P0）
//
// 依据（WWDC26 / iOS 27 三公开变化，非猜测）：
//   ① 玻璃改用**更明确的边线**起形，不再靠投影 → 边加实、影减薄、影半径收小；
//   ② **深色玻璃明显更亮**（系统深色玻璃整体提亮，tab 选中底反而变深）→ 深色卡面基色提亮、
//      顶部内高光加强、内侧暗边减弱（卡面亮了就不必再压暗收边）；
//   ③ 系统新增玻璃强度滑条（超清 ↔ 全着色）对全 App 生效，**自绘玻璃也要两端都成立** →
//      取值不许走"极淡叠层取巧"那一档（滑到全着色端会像没有玻璃）。
//
// 分工（别把参数散回调用点）：
//   · 本文件 = **数值**（浅深两套、边/高光/内暗边/影各一档）
//   · `EnvironmentGradient` = **语义出口**（cardGlassFill / cardEdgeGradient / …… 只做转发）
//   · `LiquidGlass` = **组件**（GlassEdgeSurface 等按语义出口组装，调用点只选修饰符）
//
// ⚠️ 四要素缺一条就不像玻璃（v4.0.153 实测）：① 半透明叠层够薄 ② 外圈渐变厚边
//   ③ 内侧暗边（外亮内暗才有厚度）④ 顶部内高光带（衰减点 30% 才是漫反射，22% 只是描边）。
// ⚠️ 只动"浊度"（fill）不会掉玻璃感；掉玻璃感的头号成因是把 ②④ 一起压低 —— 本面板的边与高光
//    只允许**跟着系统一起变亮**，不许为了"更通透"往回压。
// ⚠️ 改这里任何一个数都要同批改 `scripts/ql_themegrad/truth_table_themegrad.swift` 的 ⑤ 断言
//    （它钉的是真值，不是注释），否则预检当场红。

enum Glass27 {

    // MARK: - ① 卡面叠层（铺在 .ultraThinMaterial 之上）

    /// 常规卡：浅色白 0.38（v4.0.153 已定，勿再调薄）/ 深色 (44,44,58)@0.50。
    /// 深色基色 30,30,40 → 44,44,58：27 的深色玻璃更亮，自绘卡不提亮就跟系统控件不是一套语言
    /// （落在 #12121A 页底上由 #181822 提到约 #1F1F26）。
    static func fill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 44 / 255, green: 44 / 255, blue: 58 / 255).opacity(0.50)
            : Color.white.opacity(0.38)
    }

    /// 实一档：AI 气泡本体 / 渲染在气泡内的卡（与承载它的玻璃必须拉开差，否则融成一片）
    static func denseFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 44 / 255, green: 44 / 255, blue: 58 / 255).opacity(0.58)
            : Color.white.opacity(0.55)
    }

    // MARK: - ② 外圈渐变厚边（135° 左上高光 → 右下渐隐）

    /// 27 边线更明确：浅色起点 0.98 → 1.00、下缘黑 0.10 → 0.12；深色 0.40 → 0.50。
    static func edge(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [Color.white.opacity(0.50), Color.white.opacity(0.04)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color.white.opacity(1.00), Color.black.opacity(0.12)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 边宽：27 用"明确"而不是"更粗"，维持 1.2pt（26 那版刚定的值，不再加粗）
    static let edgeWidth: CGFloat = 1.2

    // MARK: - ③ 内侧暗边（贴外亮边往内 1.2pt）

    /// 深色 0.30 → 0.26：卡面提亮后不需要那么重地压暗，否则又把 27 的亮度吃掉
    static func innerShade(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.26) : Color.black.opacity(0.08)
    }

    // MARK: - ④ 顶部内高光（纵向 30% 处归零）

    /// 深色 0.14 → 0.20：跟深色玻璃一起变亮；浅色 0.72 保持（27 边线已够明确，不再压高光）
    static func topHighlight(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.20 : 0.72), .clear],
                       startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.30))
    }

    // MARK: - ⑤ 柔影（27 靠边线起形，影只负责"离页底一点"）

    /// 浅色 0.10/r22/y8 → 0.07/r18/y6；深色 0.60/r22/y8 → 0.48/r18/y6。
    /// 半径收小是关键：大半径柔影是 iOS 26 的形，27 的卡更像"薄薄浮起一层"。
    static func shadow(_ scheme: ColorScheme) -> (color: Color, radius: CGFloat, y: CGFloat) {
        scheme == .dark
            ? (Color.black.opacity(0.48), 18, 6)
            : (Color.black.opacity(0.07), 18, 6)
    }

    // MARK: - ⑥ 条状件（dock 条 / 输入栏）

    /// 条比卡片更贴：半径收到 8、y 3。27 靠边线起形，条状件再挂 r18 会糊成一团雾。
    static func barShadow(_ scheme: ColorScheme) -> (color: Color, radius: CGFloat, y: CGFloat) {
        scheme == .dark
            ? (Color.black.opacity(0.50), 8, 3)
            : (Color.black.opacity(0.13), 8, 3)
    }

    /// tab / dock 选中底：27 起**选中底变深**（浅 0.12 → 0.28 / 深 0.22 → 0.40），
    /// 再补 0.8pt 同色细线定形 —— 只靠淡底在 27 的明确边线旁边会读作「没选中」。
    static func tabSelectionFill(_ scheme: ColorScheme) -> Color {
        Color.accentColor.opacity(scheme == .dark ? 0.40 : 0.28)
    }

    static func tabSelectionStroke(_ scheme: ColorScheme) -> Color {
        Color.accentColor.opacity(scheme == .dark ? 0.42 : 0.26)
    }

    // MARK: - ⑦ 页头滚动收窄

    /// 滚动过阈值后标题 24 → 20、副标题让位（对应系统 toolbarMinimizeBehavior 的观感）。
    static let compactTitleSize: CGFloat = 20

    /// 进/出双阈值（滞回）：60 以上收、8 以下才放，中间 8~60 保持现状。
    /// 🚨 不能只用一个阈值：收窄会把页头变矮、滚动区 inset 跟着缩，单阈值会在
    ///    「收起 → offset 回落 → 又展开」之间自激（滚动停下时标题来回跳）。
    static let compactEnterOffset: CGFloat = 60
    static let compactExitOffset: CGFloat = 8
}
