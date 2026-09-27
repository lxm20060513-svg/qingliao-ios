import Foundation
import UIKit
import EventKit
import Photos
import UserNotifications
// ⚠️ 刻意**不** import HomeKit：本版不做任何 HomeKit 控制（侧载拿不到 entitlement，见文件头），
//    import 了只会让「以后想接」的人以为已经接上了。AppCapability.homekit 只保留状态行与说明。

// MARK: - v3.9.95 App 权限中枢（AI 操控本地数据的总闸门）
//
// 背景：用户要求「AI 直接操控本地 App 数据」。先把**能力边界写死在注释里**，
// 免得半年后有人照着想象去接不存在的 API：
//
//   ✅ 有公开 API（可读可写）：日历 EventKit / 相册 Photos / 通知 UNUserNotificationCenter
//   ⚠️ 侧载拿不到：HomeKit —— 需要 `com.apple.developer.homekit` entitlement，
//      侧载走免费签名，entitlement 与 App Groups 同级别拿不到。
//      故本文件**只给状态行 + 说明**，不 import 任何 HomeKit 控制代码（import 了也必然失败）。
//   ❌ Apple 从未提供 API（不是权限不给，是接口不存在）：
//      · 提醒事项 Reminders —— EventKit 只有 EKEventStore，没有任何 Reminder 类
//      · 任何第三方 App 的私有数据（微信/抖音/Strava…）—— 只能用 openURL 跳转让用户手点
//
// 三条安全口径（v3.9.95 与用户对齐，勿绕过）：
//   ① **双闸门**：系统授权 + 「允许 AI 操作」开关，两者都通才允许写/删。
//      系统授权只说明"用户允许这个 App"，不代表允许 AI 替用户决策；用户能只授权不让 AI 写。
//   ② **三级确认**：读 = 免确认直接执行；写 = 气泡里出胶囊让用户点一下；
//      删 = 必须明确确认（且 5 秒可撤销）。
//   ③ **后台不写**：App 切后台 / 锁屏时**一律不执行**写操作。
//      原因（实测级）：后台改 EventKit 会拿到已过期的授权句柄 → 静默失败或写进错误的容器；
//      HomeKit 在后台改更可能直接断连。用户点开 App 前看到的是一个"没生效"的结果，比不做更伤信任。
//
// 存储：AI 开关走 UserDefaults 单键（与 SettingsView 其它项同款，勿另立炉灶）。

// MARK: - 能力枚举

/// AI 可操控的本地能力。**新增一项要同时改四处**：
/// ① 本枚举 ② `AppPermissionKit.status(of:)` ③ `AgentAction` 的执行器 ④ 权限页 UI 一行
enum AppCapability: String, CaseIterable, Identifiable, Sendable {
    case calendar
    case photos
    case notifications
    case homekit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .calendar:      return "日历"
        case .photos:        return "相册"
        case .notifications: return "通知"
        case .homekit:       return "家庭"
        }
    }

    var sfSymbol: String {
        switch self {
        case .calendar:      return "calendar"
        case .photos:        return "photo"
        case .notifications: return "bell"
        case .homekit:       return "house"
        }
    }

    /// 权限页里的能力说明：写清**能做什么**和**做不到什么**，别让用户自己猜。
    var blurb: String {
        switch self {
        case .calendar:
            return "读你的日程、查空闲时段；经你确认后可新建、修改、删除日历事件。"
        case .photos:
            return "读取相册图片供你识别；经你确认后可把 AI 生成的图存入相册。"
        case .notifications:
            return "让 AI 用系统通知提醒你（提醒事项 App 本身 Apple 未开放接口，只能跳转打开）。"
        case .homekit:
            return "家庭（HomeKit）需要开发者证书授权，侧载安装无法使用。"
        }
    }

    /// 本版是否真的接了执行能力。HomeKit = false（见文件头 entitlement 说明）。
    var aiControllable: Bool { self != .homekit }
}

// MARK: - 授权状态

enum PermissionState: Equatable, Sendable {
    case notDetermined      // 还没问过
    case denied             // 用户拒绝过（要跳系统设置）
    case restricted         // 家长控制/设备策略，不允许再请求
    case granted            // 已授权
    case unavailable        // 本能力在当前安装方式下不可用（HomeKit 侧载）

    var label: String {
        switch self {
        case .notDetermined: return "未设置"
        case .denied:        return "已拒绝"
        case .restricted:    return "受系统限制"
        case .granted:       return "已授权"
        case .unavailable:   return "不可用"
        }
    }

    /// 能否直接调系统弹窗再请求一次（已拒绝/受限时不能，只能跳系统设置）。
    var canRequestInApp: Bool {
        self == .notDetermined || self == .granted
    }
}

// MARK: - 中枢

enum AppPermissionKit {

    // MARK: AI 授权开关（双闸门之二）

    /// 「允许 AI 操作」总闸（用户逐项授权之外的兜底总开关）。
    /// 默认 **false** —— 权限给了不等于同意让 AI 动手，必须显式开。
    private static let aiControlMasterKey = "qingliao_ai_control_master"

    /// 单项 AI 开关：key = "qingliao_ai_control.<capability>"
    private static func aiKey(_ c: AppCapability) -> String { "qingliao_ai_control.\(c.rawValue)" }

    static var aiControlMasterEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: aiControlMasterKey) }
        set { UserDefaults.standard.set(newValue, forKey: aiControlMasterKey) }
    }

    static func aiControlEnabled(_ c: AppCapability) -> Bool {
        get {
            // 总闸关 → 任何能力都不许 AI 动手（比逐项开关优先）
            guard aiControlMasterEnabled else { return false }
            guard c.aiControllable else { return false }
            return UserDefaults.standard.bool(forKey: aiKey(c))
        }
    }

    static func setAIControlEnabled(_ on: Bool, for c: AppCapability) {
        UserDefaults.standard.set(on, forKey: aiKey(c))
    }

    /// 某个能力能否被 AI 写入/删除（**双闸门**：总闸 + 单项 + 系统授权都通）。
    /// 任何写/删动作执行前**必须**过这一关，不得内联判断。
    static func canAIMutate(_ c: AppCapability) async -> Bool {
        guard aiControlEnabled(c) else { return false }
        return await status(of: c) == .granted
    }

    // MARK: 状态查询

    static func status(of c: AppCapability) async -> PermissionState {
        switch c {
        case .calendar:
            let s = EKEventStore.authorizationStatus(for: .event)
            switch s {
            case .fullAccess:          return .granted
            case .writeOnly:           return .granted      // 有写权限已够用
            case .denied:              return .denied
            case .restricted:          return .restricted
            case .notDetermined:       return .notDetermined
            @unknown default:          return .notDetermined
            }
        case .photos:
            // iOS 14+ 的四态。⚠️ 不能只看 `PHPhotoLibrary.authorizationStatus()`
            //   —— 它对「已授权」和「部分授权」都返回 .authorized，只有
            //   `authorizationStatus(for: .readWrite)` 才区分 limited。
            let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            switch s {
            case .authorized:    return .granted
            case .limited:       return .granted      // 选中了部分照片：写（存图）够用
            case .denied:        return .denied
            case .restricted:    return .restricted
            case .notDetermined: return .notDetermined
            @unknown default:    return .notDetermined
            }
        case .notifications:
            let s = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            switch s {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied:          return .denied
            case .notDetermined:   return .notDetermined
            @unknown default:      return .notDetermined
            }
        case .homekit:
            // 侧载（免费签名）拿不到 com.apple.developer.homekit entitlement，
            // import HomeKit 后的任何列表请求都会失败。直接标不可用，别弹无意义的授权框。
            return .unavailable
        }
    }

    // MARK: 请求授权

    /// 弹系统授权框。**必须 MainActor**（EventKit/Photos 的 API 都要主线程）。
    /// 返回请求后的新状态；`.unavailable`（HomeKit）原样返回，不弹框。
    @MainActor
    static func request(_ c: AppCapability) async -> PermissionState {
        switch c {
        case .calendar:
            // iOS 17+ 走 full access。⚠️ 仓库 deploymentTarget=26.0，
            //   所以**只有** full access 一条路；`requestAccess(to:)` 已废弃，不要用。
            let store = EKEventStore()
            do {
                let granted = try await store.requestFullAccessToEvents()
                return granted ? .granted : .denied
            } catch {
                NSLog("[PERM] calendar request failed: \(error)")
                return await status(of: .calendar)
            }
        case .photos:
            let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return AppPermissionKit.state(ofPhoto: s)
        case .notifications:
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            return granted ? .granted : .denied
        case .homekit:
            return .unavailable
        }
    }

    static func state(ofPhoto s: PHAuthorizationStatus) -> PermissionState {
        switch s {
        case .authorized:    return .granted
        case .limited:       return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    // MARK: 后台保护（口径 ③）

    /// 当前是否允许执行写/删。App 在后台/非活跃一律 false。
    /// 用 `UIApplication.shared.applicationState` 判 —— 注意 Swift 6 下
    /// 必须 `@MainActor` 读这个属性（SDK 标注了 MainActor 隔离）。
    @MainActor
    static var foregroundActive: Bool {
        UIApplication.shared.applicationState == .active
    }

    /// 写/删的统一入口守卫。返回 nil = 可以执行；返回字符串 = 拒绝原因（直接给用户看）。
    ///
    /// 三道检查缺一不可，**每条写/删路径都必须走这个函数**，别在调用点自己判：
    ///   1. 后台/非活跃 → 拒绝（否则授权句柄过期 → 静默失败）
    ///   2. 能力不可用（HomeKit）→ 拒绝
    ///   3. 双闸门（AI 开关 + 系统授权）→ 拒绝
    @MainActor
    static func mutationGuard(_ c: AppCapability) async -> String? {
        guard foregroundActive else { return "App 在后台，已拒绝执行（请回到轻聊后再试）" }
        guard c.aiControllable else { return "\(c.displayName) 在当前安装方式下不可用" }
        let st = await status(of: c)
        guard st == .granted else { return "\(c.displayName)未授权（当前：\(st.label)）" }
        guard aiControlEnabled(c) else { return "「允许 AI 操作·\(c.displayName)」未开启" }
        return nil
    }
}
