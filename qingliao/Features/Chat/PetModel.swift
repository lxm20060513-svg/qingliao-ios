import Foundation

// MARK: - v3.9.79 形象模型（从 PetAvatar.swift 抽出，供主 App 与实时活动挂件共用）
//
// 为什么抽成独立文件：**实时活动挂件 target 要画同一只形象**（用户 2026-09-25：
// 「加改一条，灵动岛球图标跟随卡通形象动态图」），而挂件 target 只编 `qingliaoWidget/` + 白名单源码。
// 形象 View（PetAvatar）里有 `@AppStorage`/动画等主 App 侧的东西，没必要塞进扩展；
// 所以把「形象枚举」与「矢量绘制（PetPainter）」分成两个干净文件，挂件只引这两份：
//   project.yml → QingliaoWidget.sources: PetModel.swift + PetPainter.swift
// ⚠️ 三个 target 的源码清单必须同步：漏了任何一个文件挂件会编译失败（CI Archive 才暴露）。

enum PetKeys {
    static let style = "qingliao_pet_style"
    static let motion = "qingliao_pet_motion"
    /// 76pt 以下简化（消息头像 30/38pt 走这条路）
    static let simplifyBelow: CGFloat = 76
}

// MARK: 形象（三选一，设置项写在「外观设置 → 聊天页形象」）

enum PetStyle: String, CaseIterable, Identifiable {
    // v4.0.1（用户 2026-09-27 拍板圆形基形稿）：三只 = 圆 + 各自附件。
    // ⚠️ rawValue **故意沿用旧的 cat / seal**：这两个串是「第 2 格 / 第 3 格」的槽位号，
    //    不是造型名。改名会让老用户的 `UserDefaults` 与在跑的实时活动 `ContentState.petStyle`
    //    一起认不出来 → 静默回落第一格。造型换了，槽位号不变。
    case liquid      // 液态小生物：蓝紫玻璃圆 + 两只小手
    case beast = "cat"   // 圆胖小兽：暖橙圆 + 两只圆耳（辨识度最高）
    case robot = "seal"  // 圆头小机器人：青绿金属圆 + 头顶天线

    var id: String { rawValue }

    var name: String {
        switch self {
        case .liquid: return "液态小生物"
        case .beast: return "圆胖小兽"
        case .robot: return "圆头小机器人"
        }
    }

    var blurb: String {
        switch self {
        case .liquid: return "蓝紫玻璃圆，带两只小手"
        case .beast: return "暖橙圆胖，辨识度最高"
        case .robot: return "青绿金属圆，头顶一根天线"
        }
    }

    /// v3.9.79：当前用户选了哪只（`UserDefaults` 单一真源，与 `@AppStorage(PetKeys.style)` 同一个 key）。
    /// 实时活动管理器在启动/续更时读它，把风格随 `ContentState` 下发给挂件——
    /// **不能用共享容器读**：侧载免费签名拿不到 App Groups（见挂件文件头注释），
    /// 主 App 的 `UserDefaults.standard` 与扩展进程不是同一个域。
    static var current: PetStyle {
        PetStyle(rawValue: UserDefaults.standard.string(forKey: PetKeys.style) ?? "") ?? .liquid
    }

    /// 给挂件用：字符串 → 形象（认不出的旧值一律落回液态小生物，绝不空白）
    static func from(_ raw: String) -> PetStyle {
        PetStyle(rawValue: raw) ?? .liquid
    }
}

// MARK: 宠物动画三档（无障碍硬要求：默认跟随系统）

enum PetMotion: String, CaseIterable, Identifiable {
    case system      // 跟随系统（系统开了「减弱动态效果」就自动减弱）
    case reduced     // 减弱：只留瞬时切换，不做位移/缩放
    case off         // 关闭：完全静止（仍可点击，状态变化靠文案/角标）

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: return "跟随系统"
        case .reduced: return "减弱"
        case .off: return "关闭"
        }
    }
}

// MARK: 形象状态（只做冗余表达；宠物永远不是唯一的信息通道）

enum PetState: Equatable {
    case idle
    case patting        // 抚摸（单击后 1.1s 内）
    case thinking       // AI 正在回
    case alert          // 有新消息 / 上一次失败（形态已就绪，接线由宿主决定）
}
