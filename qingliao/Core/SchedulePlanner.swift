import Foundation

// MARK: - 日程预排：纯逻辑（v4.0.118 · 推送及时性 ①）
//
// 为什么要有这一层
// --------------
// 后台唤醒（BGAppRefreshTask / background fetch）的**时刻由系统决定**，所以「定时任务到点」
// 靠"唤醒后补拉"永远会迟到。而 `UNCalendarNotificationTrigger` 是**系统级闹钟**：请求一登记，
// 到点必响 —— App 被杀、手机重启、用户从没打开过都照样响。
//
// 分工：后端（`schedule_api.py`）+ Hermes 脚本（`push_schedule.py`）负责"算准时刻"
// （只有 Hermes 懂 cron 表达式），本文件负责"App 侧怎么排"的**全部判据**，
// `ScheduleStore` 只做网络与 UNUserNotificationCenter 的搬运。
//
// ⚠️ 本文件**不 import** UserNotifications / UIKit —— 纯 Foundation，本机（Linux + swiftc，
//    没有 iOS SDK）能编译并跑真值表（scripts/ql_schedule）。能验证的别写在只有真机能验的文件里。
//
// 关键判据（每一处都对应一类静默失效，真值表逐个钉住）
//   · **稳定 identifier**（`ql_sched_<id>`）→ 同一时刻重排是**替换**语义，notify 不堆叠
//   · **必须清孤儿**：清单里删掉的任务/改过时间的旧请求，不清就永远留在系统里继续响
//   · **未来才排**（now + minLead 之后）→ 过期的排进去就是一条永远不响的"哑通知"，白占配额
//   · **必须限量**：iOS 每个 App 最多 64 条挂起通知，排满会连用户自建提醒一起挤掉
//   · **前缀必须与用户自建提醒不同**（`quick_reminder_`）：否则两边互相当成孤儿清掉

/// 后端 `/api/agent/schedule` 下发的一条"已知时刻"
struct ScheduledNotice: Equatable, Sendable, Identifiable {
    let id: String        // 后端给的稳定 id：<jobId>_<时刻epoch>
    let title: String     // 任务名（通知正文里的主语）
    let fireAt: TimeInterval   // epoch 秒
    let note: String?     // 备注（当前是「定时任务」）
}

enum SchedulePlanner {

    /// App 拉时刻表的路径。走 `/api/agent` 前缀（lucky 白名单 / 蜂窝 relay / nginx 三处已覆盖，
    /// 实测 9127 / 16668 / 8080 三入口均 401=已路由）；规范路径 `/api/schedule` 是给服务间脚本用的。
    static let path = "/api/agent/schedule"

    /// 系统挂起通知的 identifier 前缀。**必须**与用户自建提醒（`quick_reminder_`）区分开，
    /// 否则两边对账时会把对方当成孤儿清掉。
    static let identifierPrefix = "ql_sched_"

    /// 单次最多预排多少条（iOS 每 App 上限 64 条挂起通知；给用户自建提醒留足余量）
    static let maxPending = 24

    /// 距现在太近不排（拉起 App 到登记完成可能就过去了 → 系统直接丢掉，白占配额）
    static let minLead: TimeInterval = 60

    /// 只认未来 48h 内的（后端窗口同宽；更远的条目 App 存下来也没意义）
    static let horizon: TimeInterval = 48 * 3600

    // MARK: - 解析

    /// 解析后端响应体（`{"ok":true,"items":[...]}`）。坏条目逐条丢，不整批失败。
    /// ⚠️ `items` 必须按 `[Any]` 收再逐条转字典：写成 `as? [[String: Any]]` 时，只要数组里
    /// 混进一条非字典（后端 bug / 中间层篡改），**整个数组都转不过去** → 时刻表全空，
    /// 而 App 只会静默不排 —— 与"逐条丢弃"的承诺正好相反（真值表钉住这条）。
    static func parse(_ json: [String: Any]) -> [ScheduledNotice] {
        guard let arr = json["items"] as? [Any] else { return [] }
        var seen = Set<String>()
        return arr.compactMap { raw -> ScheduledNotice? in
            guard let d = raw as? [String: Any] else { return nil }
            guard let id = (d["id"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !id.isEmpty,
                  let title = (d["title"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !title.isEmpty,
                  let fire = (d["fireAt"] as? NSNumber)?.doubleValue,
                  fire > 0 else { return nil }
            guard seen.insert(id).inserted else { return nil }
            let note = (d["note"] as? String)?.trimmingCharacters(in: .whitespaces)
            return ScheduledNotice(id: id, title: title, fireAt: fire,
                                   note: (note?.isEmpty ?? true) ? nil : note)
        }
    }

    // MARK: - 排期判据

    /// 真正要登记的清单：未来窗口内、去重、按时刻升序、截断到上限。
    static func plan(items: [ScheduledNotice], now: Date,
                     limit: Int = SchedulePlanner.maxPending) -> [ScheduledNotice] {
        guard limit > 0 else { return [] }
        let t0 = now.timeIntervalSince1970
        var seen = Set<String>()
        let upcoming = items
            .filter { $0.fireAt > t0 + minLead && $0.fireAt <= t0 + horizon }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.fireAt < $1.fireAt }
        return Array(upcoming.prefix(limit))
    }

    /// 系统里带本前缀、却不在本次清单中的挂起请求 → 必须撤掉（改名/删任务/改时间的残留）。
    static func orphans(pending: [String], known: Set<String>) -> [String] {
        pending.filter { $0.hasPrefix(identifierPrefix) && !known.contains($0) }
    }

    static func identifier(for item: ScheduledNotice) -> String {
        identifierPrefix + item.id
    }

    // MARK: - 文案（纯函数，可本机验证）

    nonisolated(unsafe) private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    nonisolated(unsafe) private static let mdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd"
        return f
    }()

    /// 副标题：今天/明天说人话，再远给日期（预排通知必须让人一眼知道"这是几点的事"）
    static func timeText(for item: ScheduledNotice, now: Date = Date()) -> String {
        let d = Date(timeIntervalSince1970: item.fireAt)
        let hm = hmFormatter.string(from: d)
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "今天 " + hm }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(d, inSameDayAs: tomorrow) { return "明天 " + hm }
        return mdFormatter.string(from: d) + " " + hm
    }

    /// 正文：说明"这是**预告**不是结果"，免得用户以为内容已经生成了
    static func bodyText(for item: ScheduledNotice) -> String {
        "到「\(item.title)」时间了，打开轻聊查看"
    }

    /// 通知 userInfo 的键名（只带 id，够后续跳转/去重）
    static let userInfoKey = "qingliao_schedule"
}
