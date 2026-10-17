import SwiftUI

// MARK: - v3.9.19 透明度令牌（Tint）
//
// 背景：全库 opacity 字面量 37 个不同值（主力 0.12×55、0.08×37、0.10×17、0.15×14、0.14×8、0.06×7），
// 同一个「淡色胶囊底」至少有 0.06 / 0.07 / 0.08 / 0.09 / 0.10 / 0.12 六种写法 —— 同类元素浓淡不一，
// 看着就像"每处各调一下"。
//
// 收敛为四档（用户 2026-09-14 拍板）：
//   faint   0.08  描边 / 极淡分隔
//   subtle  0.12  淡色胶囊底、淡色分组底（最常用）
//   soft    0.16  需要更明显一点的状态底
//   strong  0.22  深色模式下的加粗描边
//
// ⚠️ 描边的**线宽口径不变**（0.8pt），Tint 只管颜色浓淡；深浅色各自的取值仍由调用点决定
//（既有约定：浅色 0.08 / 深色 0.14~0.22）。

enum Tint {
    /// 描边 / 极淡分隔
    static let faint: CGFloat = 0.08
    /// 淡色胶囊底 / 分组底（最常用）
    static let subtle: CGFloat = 0.12
    /// 需要更明显一点的状态底
    static let soft: CGFloat = 0.16
    /// 深色模式加粗描边
    static let strong: CGFloat = 0.22

    /// **彩色淡底**（非中性卡底，如状态胶囊 / 用量卡 / 分类淡底）的浓淡真源。
    ///
    /// 第 8 项整改（用户 2026-10-18「彩色淡底固定 0.15，深色下会糊 → 深色改用 0.22」）：
    /// 浅色保持 0.15（v3.9.19 定的「彩色淡底字面口径」，statusPill / UsageCard 同款，不属四档但已拍板）；
    /// 深色下同一个浓淡叠在深底上会糊成一片，故深色单独提到 strong(0.22)。
    /// **新写的彩色淡底一律走这里**，别再写裸 `opacity(0.15)`（同屏两种写法，下一轮 grep 只找得到一半）。
    static func coloredFill(_ scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? strong : 0.15
    }

    /// 卡片描边色（浅色 faint 0.08 / 深色 soft 0.16），配合既有 0.8pt 线宽
    /// —— 深色取 soft 而非 strong：全库实现里深色描边常用 0.14~0.16（strong 0.22 是白色高光描边的档）
    static func line(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? soft : faint)
    }
}
