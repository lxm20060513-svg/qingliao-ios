import SwiftUI

// MARK: - v3.9.26 全站圆角令牌（Radius）
//
// 背景：改造前 `cornerRadius:` 的静态值散落 **13 档 / 161 处**
//（7×13 / 8×11 / 9×5 / 10×24 / 12×39 / 13×17 / 14×9 / 15×6 / 16×33 / 18×5 / 22×7 / 24×3 / 0×1），
// 其中 12 与 13（差 1pt）、16 与 18（差 2pt）大量同屏 —— 肉眼分不出层级，
// 与改造前的字号乱象（11/12/13 三档共 424 处）属同一类问题。
//
// 目标：**圆角收敛为 6 档语义层级**，每处移动幅度 ≤2pt。
// 与 Typography 同一条纪律：本机无 Xcode SDK 无法目视验证，不搞大步长重排；
// 需要更大改动时应在真机逐屏确认后单独进行。
//
// 语义分层（越往下越大，不要跨层乱用）：
//   icon    图标底板 / 代码块 / 表格 / 缩略图（原 7–9）
//   chip    内嵌小条 / chip / 小按钮（原 10）
//   inset   卡内小块 / 模型行 / 便签卡（原 12–13；便签 12 为 v3.9.14 用户选定形态）
//   field   输入框 / 附件卡 / 内嵌面板（原 14–15）
//   card    全站卡片（原 16–18，v3.9.0 起已定稿统一）
//   hero    hero 卡 / 大面板 / 登录页大块（原 22–24；看板空调高亮卡既定例外）
//
// ⚠️ **不在此体系内的两种圆角**（别硬套）：
//   1. `cornerRadius: C` / `c` / `cornerRadius` 这类**由调用方传入的参数**（LiquidGlass / Skeleton
//      的修饰符与卡片函数）——它们是「可传参的默认值」，不是散落魔法数，保持参数传递不变。
//   2. 胶囊/圆形状的 `Capsule()` 与 `cornerRadius: 0` 覆写（必须方角时）——语义不是圆角尺度。
//
// 用 static let（CGFloat 是值类型，Swift 6 严格并发无全局状态告警问题；与 Typography 同）。
// 件数基线（收口前实测，用于回归断言）：icon 29 · chip 16 · inset 56 · field 15 · card 38 · hero 10
// ⚠️ 调整档位或做新一轮替换后，必须同步更新这组基线（断言脚本属本机运维工具，不随仓库分发）。

enum Radius {
    /// 图标底板 / 代码块 / 表格 / 缩略图
    static let icon: CGFloat = 8
    /// 内嵌小条 / chip / 小按钮
    static let chip: CGFloat = 10
    /// 卡内小块 / 模型行 / 便签卡
    static let inset: CGFloat = 12
    /// 输入框 / 附件卡 / 内嵌面板
    static let field: CGFloat = 14
    /// 全站卡片
    static let card: CGFloat = 16
    /// hero 卡 / 大面板 / 登录页大块
    static let hero: CGFloat = 22
}
