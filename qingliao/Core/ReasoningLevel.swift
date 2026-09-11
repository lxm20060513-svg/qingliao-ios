import Foundation

/// v3.6.5：模型思考档位 —— 聊天页 header「思考胶囊」可选，随流式请求下发给后端。
///
/// 后端把档位转成 Hermes 的按次思考配置（`model_options.reasoning`），只作用于轻聊发出的
/// 请求，不改 Hermes 全局配置。同一问题实测两轮（正文首字）：
///   medium 3.4~3.8s / low 1.6~2.2s / 关闭（reasoning.enabled=false）0.9~1.7s。
enum ReasoningLevel: String, CaseIterable, Identifiable {
    case off
    case low
    case medium
    case high

    var id: String { rawValue }

    /// UserDefaults 键（跨启动保留用户选择）
    static let storageKey = "qingliao_reasoning_level"

    /// 当前选择；从未设置过则默认 low —— 兼顾速度与推理深度
    static var current: ReasoningLevel {
        ReasoningLevel(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .low
    }

    /// 下发给后端的值（off → none，后端译成 reasoning.enabled=false）
    var payload: String { self == .off ? "none" : rawValue }

    var title: String {
        switch self {
        case .off: return "不思考"        // v3.6.5：原「关闭」易与弹窗「取消」混淆
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    /// 选择菜单里的说明（带实测首字耗时，便于按需取舍速度与推理）
    var detail: String {
        switch self {
        case .off: return "不思考，最快（首字约1秒）"
        case .low: return "轻度思考，较快（首字约2秒）"
        case .medium: return "默认推理（首字约3.5秒）"
        case .high: return "深度推理，较慢"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "bolt.fill"
        case .low: return "brain"
        case .medium: return "brain.head.profile"
        case .high: return "sparkles"
        }
    }
}
