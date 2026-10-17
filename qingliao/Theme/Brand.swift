import SwiftUI

/// 第 7 项整改（用户 2026-10-18「交互色（链接、选中、发送）收成一个品牌色」）。
///
/// 全站**交互色**单一真源：发送键 / 用户气泡 / 链接 / 选中态同源一处。
/// 改造前发送气泡是「蓝→紫」两支色相，而系统强调色是第三支 —— 同屏三种「被选中」的观感。
///
/// ⚠️ **只收交互色**：成功 / 失败 / 进行中的绿 / 红 / 橙、记录分类色、行首图标底的多彩
/// **一律不动** —— 用户取向是保留多彩，把多彩收成单色系会被当场否。
///
/// 同源做法：`qingliao/Assets.xcassets/AccentColor.colorset` 已置为本品牌色
/// （浅色 #2F6BFF / 深色 #5B8CFF）—— 全站 200+ 处 `.accentColor`（链接、选中态、开关、
/// 光标）因此**自动与发送键同源**，不必逐处改调用点。改这两个色值必须**两处一起改**
/// （本枚举 + colorset），check_swift.sh「第 105 组」有断言钉这份同源。
enum BrandColor {
    /// 品牌交互色（浅色 #2F6BFF / 深色 #5B8CFF —— 同色相提亮，不是换色相）
    static func interactive(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x5B / 255, green: 0x8C / 255, blue: 0xFF / 255)
            : Color(red: 0x2F / 255, green: 0x6B / 255, blue: 0xFF / 255)
    }

    /// 交互渐变的两端（发送键 / 用户气泡）：**同一品牌色相的两端**，
    /// 保留渐变质感但不跨色相 —— 这是「收成一支品牌色」的落地形态。
    /// 深色端不压到近黑：深色模式下实底要够亮才配得上白字。
    static func interactiveGradientColors(_ scheme: ColorScheme) -> [Color] {
        scheme == .dark
            ? [Color(red: 0x4A / 255, green: 0x7C / 255, blue: 0xF2 / 255),
               Color(red: 0x33 / 255, green: 0x57 / 255, blue: 0xC4 / 255)]
            : [interactive(scheme),
               Color(red: 0x1D / 255, green: 0x4F / 255, blue: 0xD0 / 255)]
    }
}
