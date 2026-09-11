import SwiftUI

// MARK: - v3.9.0 全站字号令牌（Typography）
//
// 背景：改造前 `.font(.system(size: …))` 散落 **22 个不同数值**（7.5 / 8.5 / 9 / 9.5 / 10 / 10.5 / 11 / 11.5 /
// 12 / 12.5 / 13 / 13.5 / 14 / 15 / 16 / 17 / 18 / 19 / 20 / 22 / 24 / 26 / 28 / 30 / 32 / 34 / 40 / 44 / 52 / 76），
// 其中 11 / 12 / 13 三档共 424 处、彼此只差 1pt —— 视觉层级糊，是"不够精致"的主因。
//
// 目标：**文字字号收敛为 8 档语义层级**（每处移动幅度刻意控制在 ≤2pt；本机无 SDK 无法目视验证，
// 大步长重排风险远大于收益，需要大改时应在真机逐屏确认后单独进行）。
//
// 语义分层（越往下越大，不要跨层乱用）：
//   tiny      角标 / 极小注释（原 7.5–10.5）
//   caption   次要说明文字（原 11–11.5）
//   subhead   列表次要文字 / 标签（原 12–13.5）
//   body      正文（原 14–15）
//   title     小标题 / 卡片数值（原 16–17）
//   headline  卡片 / 弹窗标题（原 18–20）
//   titleXL   大数字 / 突出标题（原 22–24）
//   display   空态插画 / 大标题（原 26–30）
//
// ⚠️ **装饰字号不在此体系内**：≥32 的（32 / 34 / 40 / 44 / 52 / 76）是启动页、登录页大图标、空态插画、
// 任务中心标题等一次性装饰尺寸，**保持原值不动**（SplashView 等属已定稿美术方向）。
//
// 用 static let（CGFloat 是值类型，Swift 6 严格并发无全局状态告警问题；Animation 才需要计算属性）。

enum Typography {
    /// 角标 / 极小注释
    static let tiny: CGFloat = 10
    /// 次要说明文字
    static let caption: CGFloat = 11
    /// 列表次要文字 / 标签
    static let subhead: CGFloat = 13
    /// 正文
    static let body: CGFloat = 15
    /// 小标题 / 卡片数值
    static let title: CGFloat = 17
    /// 卡片 / 弹窗标题
    static let headline: CGFloat = 20
    /// 大数字 / 突出标题
    static let titleXL: CGFloat = 24
    /// 空态插画 / 大标题
    static let display: CGFloat = 28
}
