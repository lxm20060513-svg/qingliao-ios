import SwiftUI
import WidgetKit

/// 轻聊挂件 Extension 入口（v3.8.0）。
/// 目前只包含一个实时活动（灵动岛 / 锁屏「AI 正在回复」）。
@main
struct QingliaoWidgetBundle: WidgetBundle {
    var body: some Widget {
        QingliaoLiveActivityWidget()
    }
}
