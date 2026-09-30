import SwiftUI

// MARK: - v4.0.10 开关（Toggle）唯一口径

/// 用户真机反馈：「设置里面桌面快捷方式弹窗的开关胶囊和系统的大小不一样，别的地方看哪里不一样
/// 的一起改过来」。
///
/// 成因：全仓 21 处开关各写各的 —— 设置里 6 处挂了 `.scaleEffect(0.8)` 缩过版（于是「设置页的开关」
/// 比「桌面快捷方式弹窗/首页卡片弹窗」里的系统原生开关小一圈），配色还混了绿 / 蓝 / 橙三种。
///
/// 口径（**唯一写法，别在调用点手写 .labelsHidden() / .tint() / .scaleEffect**）：
///   • 尺寸：系统原生 `UISwitch`（51×31pt）——**一律不许叠加 `scaleEffect`**（缩了就是用户报的
///     「和系统大小不一样」）。
///   • 配色：默认系统绿 `Color.green`；只有语义配套的场景（例：仪表盘自动规则行，旁边是橙色闪电
///     图标）才显式传 `color:`，并在注释里说明为什么。
///   • 标签：行尾无文字开关走 `qingliaoSwitch()`（内部 `labelsHidden()`）；带标题/带 `Label` 的
///     `Toggle` 走 `qingliaoSwitch(hideLabel: false)`。
///
/// 护栏：`scripts/ql_settings_ui/truth_table_settings_ui.swift` 会扫全仓每个 `Toggle(`，要求它后面
/// 紧跟 `qingliaoSwitch(`、且不许出现 `scaleEffect`。改了这里 = 改了全 App 的开关。
extension View {
    /// 开关统一口径。`hideLabel: true`（默认）= 行尾无文字开关；`false` = 保留 Toggle 自带标签。
    @ViewBuilder
    func qingliaoSwitch(hideLabel: Bool = true, color: Color = .green) -> some View {
        if hideLabel {
            self.labelsHidden().tint(color)
        } else {
            self.tint(color)
        }
    }
}
