// MARK: - 横屏/宽屏自适应布局（v3.4.28）
// 集中管理横屏布局取值，避免各视图散落魔法数。
// 用法：@Environment(\.horizontalSizeClass) var hSize → AdaptiveLayout.bubbleMaxWidth(hSize)

import SwiftUI

enum AdaptiveLayout {
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
