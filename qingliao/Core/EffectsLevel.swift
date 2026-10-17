import Foundation

/// 第 12 项整改（用户 2026-10-18「加一档三选：关 / 标准 / 丰富」）。
///
/// 全站特效总档 —— **不新造第二套时钟**，只作用于既有的 Motion 令牌（那 14 枚，调用点 200+）：
///   · 关   —— 所有令牌退化为 **1ms 近零时长**（`.linear(duration: 0.001)`，不是 nil）：
///              内容照常出现，只是不再位移 / 缩放 / 淡入。刻意与各视图自带的
///              `accessibilityReduceMotion` 替代路径**分开**（那条管的是无障碍开关，两者互不替代）。
///   · 标准 —— 现行令牌（**默认档**，不改动任何既有观感）。
///   · 丰富 —— 只加长「底栏换页」那条曲线（`Motion.pageEnterSlide` 0.32 → 0.46），其余不动。
///
/// ⚠️ 宠物呼吸、烟花粒子、输入框流光**不并入本档**（用户口径：那几个仍是各自开关）。
/// ⚠️ 键名字面量只在 `EffectsLevel.storageKey` 一处（与仓内「持久化 key 单一真源」同纪律）。
enum EffectsLevel: String, CaseIterable, Identifiable {
    case off
    case standard
    case rich

    static let storageKey = "app.effectsLevel"
    /// 回落档：读不到 / 存了非法值时用标准档 = 零行为变化
    static let fallback: EffectsLevel = .standard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "关"
        case .standard: return "标准"
        case .rich: return "丰富"
        }
    }

    var detail: String {
        switch self {
        case .off: return "过渡曲线静止，元素直接到位（符号弹动与循环动效不受本档影响）"
        case .standard: return "现行节奏：切页滑入、卡片浮现、数字滚动"
        case .rich: return "切页过渡更慢更缓（其余与标准档相同）"
        }
    }

    /// 当前档（读不到 / 值非法 → 标准档）
    static var current: EffectsLevel {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let parsed = EffectsLevel(rawValue: raw) else { return fallback }
        return parsed
    }

    var isOff: Bool { self == .off }
    var isRich: Bool { self == .rich }
}
