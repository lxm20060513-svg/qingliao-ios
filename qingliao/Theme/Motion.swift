// MARK: - v3.4.29 全站动效令牌（统一节奏，替代散落魔法数）
//
// 背景：改造前全工程动画时长散落 10 档（0.12/0.15/0.2/0.25/0.3/0.35/0.45/0.6/0.85/1.0），
// spring 还有两种写法混用（duration+bounce 与 response+dampingFraction）——
// 同一次交互里两处动画节奏不一致，观感就"黏"。
//
// 语义分层（越往下越重，不要跨层乱用）：
//   tap    → 按压 / 开关 / 小状态，几乎瞬时，只用来"去硬边"
//   snap   → tab 切换、气泡展开、行状态变化
//   settle → 卡片/面板进入、列表插入
//   emerge → 大块浮现（弹窗、浮层、空态），带轻微回弹
//   flow   → 持续型（呼吸/流光收尾），不加回弹
//
// 注意：键盘联动曲线（跟 kb.animationDuration）、启动动画（SplashView 0.85s）、
//       repeatForever 循环动效一律保持原值，不套令牌。
//
// 用 static var（计算属性）而非 static let：Swift 6 严格并发下 Animation 全局常量
// 易触发隔离告警；动画值每次构造开销可忽略。

import SwiftUI

enum Motion {
    /// 按压 / 开关 / 小状态：几乎瞬时
    static var tap: Animation { .snappy(duration: 0.12) }

    /// tab 切换、气泡展开、行状态变化
    static var snap: Animation { .snappy(duration: 0.20) }

    /// 卡片 / 面板进入、列表插入
    static var settle: Animation { .snappy(duration: 0.30) }

    /// 大块浮现（弹窗、浮层、空态），带轻微回弹
    static var emerge: Animation { .bouncy(duration: 0.42, extraBounce: 0.08) }

    /// 持续型（呼吸 / 流光收尾），不加回弹
    static var flow: Animation { .smooth(duration: 0.28) }
}
