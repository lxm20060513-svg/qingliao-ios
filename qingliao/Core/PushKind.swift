import Foundation

// MARK: - v4.0.20 推送来源 → 气泡角标（用户 2026-10 口径 1a：三色区分前台 / 定时 / 主动）
//
// 存在的理由：气泡角标原先是**单一蓝色「🔔 推送」**（`bubblePushTag` 只看 `isPush`），
// 用户读不出「这条是我问出来的、还是后台自己跑出来的」——定时推进、主动提醒、
// 系统通知在界面上长得一模一样。
//
// 后端早在 `inbox_api.push` / `sessions_api.append_fixed_message` 里就带了 `task_type`
// （reply/cron/system/progress/question/agent），只是注入气泡时被丢掉了。本文件只做
// **纯映射**（不 import SwiftUI），好让真值表把生产源直接编进来钉住口径。
//
// 口径（用户拍板）：
//   🟢 你问的      —— reply / 老数据（nil）
//   🔵 定时推进    —— cron（含系统通知 system）
//   🟠 主动提醒    —— agent（AI 主动开口）
//   ⚪ 进度        —— progress（灰，运行时快照，不是「一次交代」）
enum PushKind {

    /// 角标样式：颜色用字符串表达（UI 层映射成 Color），方便纯逻辑真值表断言
    struct Style: Equatable {
        let label: String     // 角标文案
        let colorKey: String  // orange / blue / green / gray
    }

    /// task_type → 角标样式。未知 / nil 一律按「你问的」（老数据 = 回复推送，语义最接近）
    static func style(for kind: String?) -> Style {
        switch kind {
        case "agent":    return Style(label: "主动提醒", colorKey: "orange")
        case "cron":     return Style(label: "定时推进", colorKey: "blue")
        case "system":   return Style(label: "系统通知", colorKey: "blue")
        case "progress": return Style(label: "进度",     colorKey: "gray")
        default:         return Style(label: "你问的",   colorKey: "green")
        }
    }

    /// 是否需要在气泡上出角标：问题卡自带卡面、普通用户消息不出。
    static func showsTag(role: String, isPush: Bool, questionId: String?) -> Bool {
        guard isPush, role == "assistant" else { return false }
        return questionId == nil || questionId!.isEmpty
    }
}
