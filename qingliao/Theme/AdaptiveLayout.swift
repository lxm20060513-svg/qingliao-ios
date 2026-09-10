// MARK: - 横屏/宽屏自适应布局（v3.4.28）
// 集中管理横屏布局取值，避免各视图散落魔法数。
// 用法：@Environment(\.horizontalSizeClass) var hSize → AdaptiveLayout.bubbleMaxWidth(hSize)

import SwiftUI

enum AdaptiveLayout {
    /// 气泡最大宽度：竖屏保持 366（v2.0.41 定稿红线），横屏/宽屏 ~60% 屏宽、上限 560
    static func bubbleMaxWidth(_ hSize: UserInterfaceSizeClass?) -> CGFloat {
        hSize == .regular ? 560 : 366
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
