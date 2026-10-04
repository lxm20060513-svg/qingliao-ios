import Foundation

// MARK: - v4.0.20 长期目标的「后台状态」纯逻辑（#5 状态条 / #6 推进时间线 / #7 留痕展示）
//
// 背景（用户 2026-10 原话）：「长期目标触发不明显，我不知道当前任务是前台任务还是
//   触发了后台自主推进任务」。目标建成后交给后端 cron（默认早 9:00 推进），但卡片上
//   只有一句 `lastReport` —— 看不出**它到底在不在跑、下一次什么时候跑、跑过几次**。
//
// 本文件只放纯逻辑（不 import SwiftUI），供真值表镜像。

/// 一次后台推进的留痕（#6 推进时间线 / #7 自动动作留痕）
struct GoalReport: Codable, Equatable, Sendable, Identifiable {
    var at: Date
    var text: String
    /// #7：这类留痕不是「推进汇报」而是**主动 Agent 自己做的动作**
    /// （自动补建 cron、停滞提醒等）—— 界面上要与推进汇报分开标注
    var kind: String

    init(at: Date, text: String, kind: String = "report") {
        self.at = at
        self.text = text
        self.kind = kind
    }

    /// v4.0.20：指纹用**全文**而非前 16 字——同一秒内两条不同正文的留痕不再撞 id
    /// （重复 id 会让 ForEach 漏渲染 / 错位动画）。同秒同 kind 同正文 = 真重复，撞了反而对。
    var id: String { "\(at.timeIntervalSince1970)-\(kind)-\(text)" }

    var isAgentAction: Bool { kind == "agent_action" }
}

enum GoalSchedule {

    /// #5 状态胶囊文案（纯逻辑，UI 只上色）
    static func healthLabel(_ h: Health) -> String {
        switch h {
        case .running:  return "后台运行中"
        case .paused:   return "暂停"
        case .detached: return "未接上后台"
        }
    }

    /// 后台健康三态
    enum Health: String, Equatable {
        case running    // 已接上 cron 且未暂停 —— 后台会自己动
        case paused     // 用户手动暂停
        case detached   // 没建上 cron（半成品，详情页可重试）
    }

    static func health(hasJob: Bool, paused: Bool) -> Health {
        if paused { return .paused }
        return hasJob ? .running : .detached
    }

    /// 下一次推进时刻（本地时区）。口径：
    ///   · paused / 未接上后台 / 两段都关 → nil（后台不会自己动）
    ///   · 当天该时刻还没过 → 今天；过了 → 明天；早段与晚段取**最近的**
    static func nextRun(now: Date, morningHour: Int, eveningHour: Int,
                        morningEnabled: Bool, eveningEnabled: Bool,
                        health: Health,
                        calendar: Calendar = .current) -> Date? {
        guard health == .running, morningEnabled || eveningEnabled else { return nil }
        let start = calendar.startOfDay(for: now)
        var candidates: [Date] = []
        if morningEnabled, let d = calendar.date(byAdding: .hour, value: morningHour, to: start) {
            candidates.append(d)
        }
        if eveningEnabled, let d = calendar.date(byAdding: .hour, value: eveningHour, to: start) {
            candidates.append(d)
        }
        guard !candidates.isEmpty else { return nil }
        if let today = candidates.filter({ $0 > now }).min() { return today }
        return candidates.compactMap { calendar.date(byAdding: .day, value: 1, to: $0) }.min()
    }

    // v4.0.20：缓存 DateFormatter（ICU 初始化开销大；nextRunText 在目标列表每行每次 body 求值都会调用）。
    // 写法对齐 MemoStore：nonisolated(unsafe) 逃逸 Swift 6 对「非 Sendable 类型的 static let」的隔离检查。
    nonisolated(unsafe) private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "H:mm"
        return f
    }()
    nonisolated(unsafe) private static let dayHmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 H:mm"
        return f
    }()

    /// v4.0.44（用户第⑤条）：下一次推进的**时刻短语**（「今天 9:00」/「明天 9:00」/「10月6日 9:00」）。
    /// 与 nextRunText 同源（同一个 nextRun 口径）——卡片上「下一步 · 预计 X 开始」要的只是时刻，
    /// 不能把「后台 … 推进」整句拿来拼（会变成两句拼一起的怪句子）。
    static func nextRunMomentText(now: Date, morningHour: Int, eveningHour: Int,
                                  morningEnabled: Bool, eveningEnabled: Bool,
                                  health: Health,
                                  calendar: Calendar = .current) -> String? {
        guard let next = nextRun(now: now, morningHour: morningHour, eveningHour: eveningHour,
                                 morningEnabled: morningEnabled, eveningEnabled: eveningEnabled,
                                 health: health, calendar: calendar) else {
            return nil
        }
        let hm = Self.hmFormatter.string(from: next)
        if calendar.isDate(next, inSameDayAs: now) { return "今天 \(hm)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(next, inSameDayAs: tomorrow) { return "明天 \(hm)" }
        return Self.dayHmFormatter.string(from: next)
    }

    /// 状态条主文案（健康点由 UI 按 health 上色）
    static func nextRunText(now: Date, morningHour: Int, eveningHour: Int,
                            morningEnabled: Bool, eveningEnabled: Bool,
                            health: Health,
                            calendar: Calendar = .current) -> String {
        switch health {
        case .paused:   return "已暂停 · 后台不会自动推进"
        case .detached: return "未接上后台 · 详情里可重试"
        case .running:
            guard let moment = nextRunMomentText(now: now, morningHour: morningHour,
                                                 eveningHour: eveningHour,
                                                 morningEnabled: morningEnabled,
                                                 eveningEnabled: eveningEnabled,
                                                 health: health, calendar: calendar) else {
                return "没有开启推进时段"
            }
            return "后台 \(moment) 推进"
        }
    }
}

// MARK: - GoalItem 的后台状态便捷口径（视图层唯一取法）
extension GoalItem {
    /// #5：后台健康三态（cron 接没接上 / 是否暂停）
    var scheduleHealth: GoalSchedule.Health {
        GoalSchedule.health(hasJob: !cronJobID.isEmpty, paused: paused)
    }

    /// #5：状态条文案（「后台 明天 9:00 推进」这类）
    func scheduleText(now: Date) -> String {
        GoalSchedule.nextRunText(now: now,
                                 morningHour: morningHour,
                                 eveningHour: eveningHour,
                                 morningEnabled: morningEnabled,
                                 eveningEnabled: eveningEnabled,
                                 health: scheduleHealth)
    }

    /// v4.0.44（用户第⑤条）：下一步「预计 X 开始」里的时刻短语；后台不会自己动 → nil。
    func nextRunMoment(now: Date) -> String? {
        GoalSchedule.nextRunMomentText(now: now,
                                       morningHour: morningHour,
                                       eveningHour: eveningHour,
                                       morningEnabled: morningEnabled,
                                       eveningEnabled: eveningEnabled,
                                       health: scheduleHealth)
    }
}

// MARK: - #11 后台推进「第几步」解析（任务中心进度标注）

/// 后端 goal cron 被要求**首行原样输出** `【目标推进 3/5】`（见 goal_module._goal_morning_prompt）。
/// App 端把它解析成进度角标 —— 用户原话：「任务中心的任务那里加通知，表明当前后台自主
/// 推进任务进行到哪一步了」。
enum GoalProgressMark {

    /// 解析首行进度标记；不是目标推进消息 → nil
    static func parse(_ text: String) -> (step: Int, total: Int)? {
        guard let r = text.range(of: "【目标推进 ") else { return nil }
        let rest = text[r.upperBound...]
        guard let end = rest.firstIndex(of: "】") else { return nil }
        let parts = rest[rest.startIndex..<end].split(separator: "/")
        guard parts.count == 2,
              let step = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let total = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              total > 0 else { return nil }
        return (min(max(step, 0), total), total)
    }

    /// 角标文案
    static func label(step: Int, total: Int) -> String { "后台推进 \(step)/\(total)" }

    /// 进度比例（给细进度条用）
    static func ratio(step: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(step) / Double(total), 0), 1)
    }

    /// 去掉标记后的正文（角标已经表达过，正文里不再重复）
    static func stripped(_ text: String) -> String {
        guard let r = text.range(of: "【目标推进 "),
              let end = text[r.upperBound...].firstIndex(of: "】") else { return text }
        let after = text.index(after: end)
        return String(text[after...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
