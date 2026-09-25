// MARK: - 横屏/宽屏自适应布局（v3.4.28）
// 集中管理横屏布局取值，避免各视图散落魔法数。
// 用法：@Environment(\.horizontalSizeClass) var hSize → AdaptiveLayout.bubbleMaxWidth(hSize)

import SwiftUI

enum AdaptiveLayout {
    /// v3.9.79：**横屏（矮屏）判据的唯一真源**。
    ///
    /// 不要再拿 `horizontalSizeClass == .regular` 判横屏：iPhone 普通机型横屏仍然是 `.compact`
    /// （只有 Plus/Max 才升到 `.regular`）—— 原来 `AdaptiveLayout` 那几个 `hSize == .regular` 分支
    /// 在用户机上**从来没生效过**，横屏一直按竖屏尺寸硬排（用户 2026-09-25 报「横屏需要重新排版」的根因）。
    /// iPhone 横屏 = 竖屏高度类 compact（iPad 全屏/分屏各档不受影响，走 regular 分支）。
    static func isShort(_ vSize: UserInterfaceSizeClass?) -> Bool {
        vSize == .compact
    }

    /// 气泡最大宽度：v3.9.27 用户要求「气泡变长显示更多文字」——竖屏 366 → 369（近满宽：
    /// 393 屏 − 消息区左右各 12 padding − AI 头像列余量， Spacer minLength 已同步放宽），
    /// 横屏/宽屏 ~60% 屏宽、上限 560 不变
    static func bubbleMaxWidth(_ hSize: UserInterfaceSizeClass?) -> CGFloat {
        hSize == .regular ? 560 : 369
    }

    /// 输入栏/设置页等内容限宽：横屏下限宽居中，避免一行拉满 800pt
    static func contentMaxWidth(_ hSize: UserInterfaceSizeClass?) -> CGFloat {
        hSize == .regular ? 700 : .infinity
    }

    /// 聊天图片消息显示上限：横屏放宽到 280（竖屏 200 不变）
    static func chatImageMax(_ hSize: UserInterfaceSizeClass?) -> CGFloat {
        hSize == .regular ? 280 : 200
    }
}
