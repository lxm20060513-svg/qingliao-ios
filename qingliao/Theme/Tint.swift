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

    /// 卡片描边色（浅色 faint / 深色 strong），配合既有 0.8pt 线宽
    static func line(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? strong : faint)
    }
}
