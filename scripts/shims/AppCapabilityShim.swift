// Linux 单测替身：**只声明 AppCapability 的枚举外壳**（真实定义在
// qingliao/Core/AppPermissionKit.swift，那份 import EventKit/Photos/UIKit，Linux 编不过）。
//
// ⚠️ 唯一用途：让 scripts/test_agent_action.swift 能在 Linux 上跑。
//    改了 AppPermissionKit 里的 displayName/sfSymbol/aiControllable，
//    这里的副本不会自动跟着变 —— 真值以 AppPermissionKit.swift 为准，
//    check_swift.sh 的「权限表同步」护栏会比对两处并提醒。
import Foundation

enum AppCapability: String, CaseIterable, Sendable {
    // ⚠️ 必须与 AppPermissionKit.swift 的枚举逐字对齐（顺序也要一致）——
    //    本文件只是让 Linux 单测能编过，真值以 AppPermissionKit.swift 为准，
    //    scripts/check_action_capabilities.py 会比对两处，漏同步直接红。
    case calendar, reminders, photos, contacts, location, clipboard, files, notifications, homekit

    var aiControllable: Bool { self != .homekit }
}
