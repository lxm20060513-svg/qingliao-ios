import Foundation

// MARK: - 轻聊通知分类（v4.0.91 · 配合 iOS 27 快捷指令）
//
// 为什么要有这一层：通知标题原先各写各的 —— "轻聊" / "轻聊 · 推送" / "轻聊 · 主动" /
// "轻聊 · AI 需要你确认" / "轻聊 · 任务" / "轻聊提醒"。同一类通知标题还不完全一致
// （弹通知的 8 个点里有 4 个写法各异的"推送"），于是 iOS 快捷指令的「收到通知」触发器
// 只能靠**内容**猜这条通知是哪一类，条件根本写不出来。
//
// 现在统一成「固定前缀标题 + 关键值副标题」：
//   · 标题 = 【轻聊·<类别>】 —— 自动化里按「标题包含『轻聊·提醒』」判类型，前缀是**唯一**判据
//   · 副标题 = 关键值（提醒时间 / 来源），正文只放内容
//   · 类别与后端 `task_type` 一一对应（收件箱投递侧 8 个弹点全走 `fromTaskType`）
//
// ⚠️ 本文件**不 import** UserNotifications / UIKit —— 纯 Foundation，本机（Linux + swiftc，
//    没有 iOS SDK）能编译并跑真值表（scripts/ql_notifycopy）。能验证的别写在只有真机能验的文件里。
// ⚠️ 分类表**只有这一份**：加类别 → 改这里 + 真值表；别在调用点再写一遍映射（会漂移）。

/// 通知类别 —— 与后端 `task_type` 对齐（`reply` / `agent` / `question` / `cron` / `system`）
/// 外加两个 App 本地来源（定时提醒 / AI 主动弹的通知）。
enum QingliaoNotifyKind: String, CaseIterable, Sendable {
    /// 用户自己设的「一句话定时提醒」（QuickReminderScheduler）
    case reminder
    /// AI 回复完成（task_type=reply）
    case reply
    /// AI 主动开口（task_type=agent）
    case proactive
    /// AI 需要你确认（task_type=question）
    case confirm
    /// 定时 / 后台投递：周报、长期目标日报（task_type=cron）
    case inbox
    /// 系统事件：快递变动、股价到价、监控暂停（task_type=system）
    case alert

    /// 标题前缀（固定、可判别）。⚠️ 改这里就是改自动化条件的契约，别随手动。
    var prefix: String {
        switch self {
        case .reminder:  return "轻聊·提醒"
        case .reply:     return "轻聊·回复"
        case .proactive: return "轻聊·主动"
        case .confirm:   return "轻聊·待确认"
        case .inbox:     return "轻聊·投递"
        case .alert:     return "轻聊·告警"
        }
    }

    /// 通知标题（含全角方括号，肉眼与机器都好认）
    var title: String { "【\(prefix)】" }

    /// 后端 `task_type` → 类别。**唯一**映射点（InboxStore 的弹通知点全部走这里）。
    /// `progress` 不弹通知（进度是"回 App 时看"的信息），但留一条兜底免得新增类型时崩。
    static func fromTaskType(_ raw: String) -> QingliaoNotifyKind {
        switch raw {
        case "agent":    return .proactive
        case "question": return .confirm
        case "cron":     return .inbox
        case "system":   return .alert
        default:         return .reply   // reply / progress / 空串（老后端）
        }
    }
}

// MARK: - 文案组装（纯函数，全部可本机真值表验证）

enum QingliaoNotifyCopy {

    /// 副标题上限：iOS 通知副标题一行放得下的量级（超了系统自己截，但我们要先截得好看）
    static let subtitleLimit = 24

    /// 去掉 markdown 记号 + 全角空格归一（**不改内容**，只去记号）
    /// ⚠️ 顺序很重要：必须先整段去记号再取行 —— 原 notifyReply 就是这个顺序。
    /// 反过来（先取首行再去记号）会让「```\n正文」这种以围栏开头的回复取到空首行，
    /// 预览变成空串、通知里只剩一个「💬 」（v4.0.91 真值表实测抓到）。
    static func stripTokens(_ raw: String) -> String {
        var s = raw
        for token in ["```", "**", "*", "`", "##", "#", "> "] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        return s.replacingOccurrences(of: "\u{3000}", with: " ")
    }

    /// 收敛空白 + 去 markdown 记号（只给「单行展示」的场合用：副标题 / 回复预览）
    static func plain(_ raw: String) -> String {
        // 折叠连续空白（含换行）为单空格
        let s = stripTokens(raw)
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按**字符**截断（不是字节/UTF16 —— 中文按字数看起来才均匀），超长补省略号
    static func clamp(_ s: String, _ max: Int) -> String {
        guard max > 0 else { return "" }
        guard s.count > max else { return s }
        return String(s.prefix(max)) + "…"
    }

    /// 标题：固定前缀，无参数（前缀就是自动化条件的判据，不许被别的内容污染）
    static func title(_ kind: QingliaoNotifyKind) -> String { kind.title }

    /// 副标题：关键值（提醒时间 / 来源）。空 → nil（**不**塞空串，否则通知里会多一行空白）
    static func subtitle(_ detail: String?) -> String? {
        let s = clamp(plain(detail ?? ""), subtitleLimit)
        return s.isEmpty ? nil : s
    }

    /// 正文：只 trim，**不折叠换行、不截断** —— 原行为是多行正文照给 iOS 自己排版，
    /// 折叠成一行会变成「一堆话挤一条」（投递类推送正是多行）。
    static func body(_ raw: String, fallback: String = "点击查看详情") -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? fallback : s
    }

    /// AI 回复预览（原 NotificationHelper.notifyReply 的首句逻辑搬来，变可验证）
    /// 整段去记号 → 取第一个非空行 → 压空白 → 截断；空返回空（调用方回退默认文案）
    static func replyPreview(_ reply: String, limit: Int = 50) -> String {
        let firstLine = stripTokens(reply).components(separatedBy: .newlines).first {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return clamp(plain(firstLine ?? ""), limit)
    }

    /// 三件套一次给出（调用点只接一个元组，避免各处自己拼标题）
    static func compose(_ kind: QingliaoNotifyKind, detail: String? = nil,
                        body raw: String, fallback: String = "点击查看详情")
        -> (title: String, subtitle: String?, body: String) {
        (title(kind), subtitle(detail), body(raw, fallback: fallback))
    }
}
