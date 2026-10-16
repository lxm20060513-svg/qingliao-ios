import Foundation
import Combine          // ObservableObject/@Published（Foundation 不 re-export，靠 AVFoundation 系的文件才碰巧能过）
import UserNotifications

// MARK: - 日程预排（v4.0.118 · 推送及时性 ①）
//
// 把 Hermes 侧「已知时刻」的定时任务，用**系统级** `UNCalendarNotificationTrigger` 提前排好。
// 为什么这是"及时性"的关键一手：后台唤醒时刻由 iOS 决定（见 BackgroundWake / InboxBackgroundPlan），
// 而预排通知是系统闹钟 —— 到点必响，App 被杀/手机重启/没打开过都照样响。
//
// 分工：后端 `schedule_api.py` 存时刻表（Hermes 的 `push_schedule.py` 每小时整体覆盖写入），
// 本类只做两件事：拉清单 + 按 SchedulePlanner 的判据登记系统通知。**判据全在 SchedulePlanner**
// （纯逻辑、本机真值表可验），这里不许再写一遍。
//
// 三个必须守住的点（真值表钉住）：
//   ① 网络失败**不撤**已有通知（拉不到就用上次清单，否则断网一次就把闹钟全拆了）
//   ② 未授权时**只跳过、不弹窗**（弹窗时机属于 QuickReminder/首条通知，不在这儿抢系统弹窗）
//   ③ 登记失败要能上屏（`lastError`）——「清单里有、到点没响」是这一类最常见的静默失效

@MainActor
final class ScheduleStore: ObservableObject {

    static let shared = ScheduleStore()

    /// 最近一次拉到的时刻表（网络失败时保留上次的）
    @Published private(set) var items: [ScheduledNotice] = []
    /// 本次已登记的系统通知条数
    @Published private(set) var scheduledCount = 0
    /// 最近一次登记失败原因（nil = 都成功）
    @Published private(set) var lastError: String?
    /// 最近一次成功拉到清单的时刻（0 = 从未）
    @Published private(set) var lastSyncAt: TimeInterval = 0

    private var auth: AuthStore?
    private var refreshing = false

    private init() {}

    func attach(_ auth: AuthStore) {
        self.auth = auth
    }

    /// 冷启动 / 回前台调（幂等，可反复调）：拉清单 → 重排系统通知 → 清孤儿。
    func refreshAndReconcile() async {
        guard let auth, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if let list = await fetch(auth) {
            items = list
            lastSyncAt = Date().timeIntervalSince1970
        }
        // 拉不到（nil）就沿用上次清单继续对账：断网不能把已排好的闹钟拆掉
        await reconcile()
    }

    // MARK: - 网络

    private func fetch(_ auth: AuthStore) async -> [ScheduledNotice]? {
        do {
            let json = try await auth.json(SchedulePlanner.path, method: "GET")
            guard (json["ok"] as? Bool) == true else {
                NSLog("[SCHED] 拉时刻表失败：ok=false")
                return nil
            }
            return SchedulePlanner.parse(json)
        } catch {
            NSLog("[SCHED] 拉时刻表异常：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 系统通知对账

    private func reconcile() async {
        let center = UNUserNotificationCenter.current()
        // 只**读**权限、不申请：申请时机属于「用户主动创建提醒 / 首条推送」，
        // 启动时抢同一次系统弹窗会让另一个回调拿到 false（v3.9.x 踩过，QuickReminder 同款注释）。
        let settings = await center.notificationSettings()
        let authorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        if !authorized {
            NSLog("[SCHED] 通知未授权，跳过预排（用户印象里「到点没响」多半是这个）")
        }
        // ⚠️ 未授权只跳过**登记**，不清扫也提前 return —— `removePendingNotificationRequests`
        //    根本不需要授权，提前 return 会让「任务已被删/时刻已被改」的旧挂起请求永远留在系统里
        //    （白占 iOS 每 App 64 条配额，重新授权后若时刻还没过就会照旧响）。
        let plan = authorized ? SchedulePlanner.plan(items: items, now: Date()) : []
        var firstFailure: String?
        var registered = 0
        for item in plan {
            if let reason = await schedule(item, center: center) {
                if firstFailure == nil { firstFailure = reason }
            } else {
                registered += 1     // 计数只认**真登记成功**的条数（报「打算排」的数 = 另一种静默失效）
            }
        }
        lastError = firstFailure
        // 清孤儿：系统里带本前缀、却不在**该保留集**里的挂起请求（任务被删 / 时刻被改 / 清单缩短）。
        // 🚨 保留集不能拿 `plan` 当：plan 还额外滤掉「60s 内即将到点」「超 48h」「超上限」的条目，
        //    拿它当保留集会把**已经登记好**的请求当孤儿删掉 —— 最典型：08:00 那条在 07:58:30 回前台时
        //    排上，用户 07:59:30 再回前台就从 plan 掉出 → 被删 → 08:00 静默不响（真值表 §106 钉住）。
        //    保留集只按「是否已过期」判：没过期就留着。
        let now = Date().timeIntervalSince1970
        let retain = Set(items.filter { $0.fireAt > now }.map { SchedulePlanner.identifier(for: $0) })
        let pending = await pendingIdentifiers(center)
        let gone = SchedulePlanner.orphans(pending: pending, known: retain)
        if !gone.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: gone)
            NSLog("[SCHED] 清孤儿预排通知 \(gone.count) 条")
        }
        scheduledCount = registered
        NSLog("[SCHED] 预排完成：清单 \(items.count) 条 → 登记 \(registered) 条 / 保留 \(retain.count) 条，清孤儿 \(gone.count) 条")
    }

    /// 登记一条。返回 nil = 成功，否则是可直接上屏的失败原因。
    private func schedule(_ item: ScheduledNotice, center: UNUserNotificationCenter) async -> String? {
        let copy = QingliaoNotifyCopy.compose(.scheduled,
                                             detail: SchedulePlanner.timeText(for: item),
                                             body: SchedulePlanner.bodyText(for: item))
        let content = UNMutableNotificationContent()
        content.title = copy.title
        if let sub = copy.subtitle { content.subtitle = sub }
        content.body = copy.body
        content.sound = .default
        content.threadIdentifier = "qingliao_schedule"
        content.userInfo = [SchedulePlanner.userInfoKey: item.id]
        // 只对「年月日时分」匹配：到点触发一次（repeats=false）。用绝对时刻而不是时分重复，
        // 是因为清单里的每一条都是"某次具体出现"，重复由后端逐次下发。
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: Date(timeIntervalSince1970: item.fireAt))
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let identifier = SchedulePlanner.identifier(for: item)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        let title = item.title   // 只把 String 带进回调（不送整个 struct 跨隔离域）
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            center.add(request) { error in
                if let error {
                    NSLog("[SCHED] ❌ 登记失败 \(identifier)：\(error)")
                    cont.resume(returning: "「\(title)」预排失败：\(error.localizedDescription)"
                        + "（系统每 App 最多 64 条挂起通知，可先删掉不用的提醒）")
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func pendingIdentifiers(_ center: UNUserNotificationCenter) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            center.getPendingNotificationRequests { requests in
                cont.resume(returning: requests.map { $0.identifier })
            }
        }
    }

    /// 手动清空（设置页/排障用）：撤掉全部本前缀的挂起与已投递通知
    func clearAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await pendingIdentifiers(center)
        let mine = pending.filter { $0.hasPrefix(SchedulePlanner.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: mine)
        center.removeDeliveredNotifications(withIdentifiers: mine)
        scheduledCount = 0
        NSLog("[SCHED] 已清空预排通知 \(mine.count) 条")
    }
}
