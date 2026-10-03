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
    /// v4.0.6：常态表情（用户选「待机时用这张脸」；thinking/alert 仍由宿主驱动，不归这里管）
    static let face = "qingliao_pet_face"
    /// v4.0.6：行为动作勾选集（逗号分隔的 Quirk.rawValue）
    static let quirks = "qingliao_pet_quirks"
    /// 76pt 以下简化（消息头像 30/38pt 走这条路）
    static let simplifyBelow: CGFloat = 76

    /// 当前勾选的动作集合。**key 不存在 = 全开**（老用户升级后行为不变），
    /// key 存在但串为空 = 一个都不播（用户主动全关）——这两种语义必须区分开。
    static func enabledQuirks() -> Set<Quirk> {
        guard let raw = UserDefaults.standard.string(forKey: quirks) else { return Set(Quirk.pool) }
        let on = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return Set(Quirk.pool.filter { on.contains($0.rawValue) })
    }
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
        case .liquid: return "蓝紫玻璃圆，两只玻璃小手"
        case .beast: return "暖橙圆胖，两只圆爪带肉垫"
        case .robot: return "青绿金属圆，天线 + 两只金属钳手"
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

// MARK: 常态表情（v4.0.6：用户可在设置里挑「待机时用这张脸」）
//
// 口径：只管 **idle** 态的脸。thinking / alert 仍是宿主信号驱动（AI 在回、后端离线），
// 表情选择不能把它们盖掉——宠物是状态的**冗余**通道，语义必须真实。
// 所以映射是「选中的表情 → idle 态复用哪套五官」，不新增第四种状态枚举。

enum PetFace: String, CaseIterable, Identifiable {
    case calm     // 平静：默认 = 原 idle 脸
    case happy    // 开心：笑眼 + 弯嘴
    case sleepy   // 困倦：半闭眼 + 微微张嘴
    case playful  // 俏皮：wink + 歪嘴

    var id: String { rawValue }

    var name: String {
        switch self {
        case .calm: return "平静"
        case .happy: return "开心"
        case .sleepy: return "困倦"
        case .playful: return "俏皮"
        }
    }

    var blurb: String {
        switch self {
        case .calm: return "默认表情，眨眨眼"
        case .happy: return "笑眼弯嘴，一直开心"
        case .sleepy: return "半闭眼，慢悠悠"
        case .playful: return "眨单眼，歪嘴"
        }
    }

    /// v3.9.79 同款兜底：给挂件用（挂件读不到主 App 的 UserDefaults，只认下发的串）
    static func from(_ raw: String) -> PetFace {
        PetFace(rawValue: raw) ?? .calm
    }

    /// v4.0.6：当前选的脸（与 `@AppStorage(PetKeys.face)` 同一个 key）
    static var current: PetFace {
        PetFace(rawValue: UserDefaults.standard.string(forKey: PetKeys.face) ?? "") ?? .calm
    }
}

// MARK: 行为动作（v4.0.6 从 PetAvatar 内 private 提上来，成为可选集合）
//
// ⚠️ 提到 PetModel 的唯一理由：**设置页要给这六个动作做多选**，而设置页不能读
//    另一个文件里的 private 枚举（当年 MiniCapsule 就栽在这条上，见 LifeCapsule.swift 头注释）。
//    提上来后 PetAvatar 与设置页共用一份定义，不会两处漂。

enum Quirk: String, CaseIterable, Identifiable, Equatable {
    case headTilt      // 歪头好奇
    case lookAround    // 左右张望
    case happyWiggle   // 开心扭动
    case stretch       // 伸懒腰（拉长一下）
    // v4.0.0：真·位移，不是原地形变（横向挪 + 朝向翻转 + 上下颠步）
    case strollLeft
    case strollRight
    // v4.0.26：**用手表达**的动作（用户 2026-10-02 拍板「做123456」= 手势全要）。
    // 与上面几档的区别：这些动作的主要看点是**两只手的姿势编排**，身体变换只是配合。
    // 姿势随时间变化 → 会触发 Canvas 重绘（与眨眼同级，仅动作播放期间；见 PetAvatar 头注释）。
    case waveHello     // 挥手打招呼（单手举起左右摆）
    case clap          // 鼓掌（两手向中间合拍）
    case heartHands    // 比心（两手胸前合拢）
    case cheer         // 举手欢呼（双手高举 + 上跳）
    case chinRest      // 托腮（单手扶脸侧）

    var id: String { rawValue }

    var name: String {
        switch self {
        case .headTilt: return "歪头"
        case .lookAround: return "张望"
        case .happyWiggle: return "扭动"
        case .stretch: return "伸懒腰"
        case .strollLeft: return "向左踱"
        case .strollRight: return "向右踱"
        case .waveHello: return "挥手"
        case .clap: return "鼓掌"
        case .heartHands: return "比心"
        case .cheer: return "欢呼"
        case .chinRest: return "托腮"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .headTilt: return 1.4
        case .lookAround: return 1.6
        case .happyWiggle: return 0.9
        case .stretch: return 1.5
        case .strollLeft, .strollRight: return 2.2
        case .waveHello: return 1.8
        case .clap: return 1.4
        case .heartHands: return 1.9
        case .cheer: return 1.4
        case .chinRest: return 2.4
        }
    }

    static let pool: [Quirk] = [.headTilt, .lookAround, .happyWiggle, .stretch,
                                .strollLeft, .strollRight,
                                .waveHello, .clap, .heartHands, .cheer, .chinRest]

    /// 是否是「走动」类：需要按行进方向镜像朝向
    var isStroll: Bool { self == .strollLeft || self == .strollRight }

    /// v4.0.26：是否是「用手表达」的动作 —— 由 PetAvatar 交给手部姿势编排去播，
    /// 身体层只做轻微配合（不再走通用形变分支）。
    var isHandAction: Bool {
        switch self {
        case .waveHello, .clap, .heartHands, .cheer, .chinRest: return true
        default: return false
        }
    }
}

// MARK: 宠物待机动效时序（单一真源，v4.0.37）
//
// 待机微动作的触发间隔。v4.0.37 起用户拍板「2~5 秒随机触发」——比旧值（6~14s）密得多，
// 目的是让宠物明显「活」着。写成常量数组而非 `Double.random(in:)` 是为了：
// ①设置页文案、渲染稿脚本、护栏表都读同一处，不会各写一个数字；
// ②护栏可钉住「间隔集合 == [2,3,4,5]」，改值时逼红提醒同步文案。
enum PetMotionTiming {
    /// 待机微动作（歪头/张望/扭动/伸懒腰/眨眼之外的 quirk 动作）两次触发之间的随机间隔，单位秒。
    static let idleQuirkInterval: [Double] = [2, 3, 4, 5]
}

// MARK: 形象状态（只做冗余表达；宠物永远不是唯一的信息通道）

enum PetState: Equatable {
    case idle
    case patting        // 抚摸（单击后 1.1s 内）
    case thinking       // AI 正在回
    case alert          // 有新消息 / 上一次失败（形态已就绪，接线由宿主决定）
}
