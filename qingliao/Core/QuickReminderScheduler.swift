import Foundation
import Observation
import UIKit
import UserNotifications

// MARK: - v3.9.32 一句话本地定时提醒（调度层）
//
// 这一层只做三件事：
//   1. **权限**：先问再用（未授权时绝不假装排上了——那是最坏的体验：用户以为定上了，到点什么都没有）；
//   2. **注册**：`UNCalendarNotificationTrigger` —— 由**系统**在指定时刻拉起通知，App 被杀 / 手机重启
//      / 断网 都能响（这是本功能与「后端 cron + 前台轮询」的本质区别）；
//   3. **对账（reconcile）**：把本地列表与系统挂起请求对齐——过期的一次性提醒标 fired 并撤销，
//      未过期的按**稳定 identifier** 重注册（`add` 同 identifier 是替换语义，天然不堆叠），
//      系统里的孤儿请求清掉。
//
// 存储：UserDefaults 单键 JSON（纯本地兜底，不需要后端；`.iso8601` 编解码与 MemoStore 同款口径）。
//
// ⚠️ 两条刻意的实现选择（别顺手"现代化"，会挂 CI）：
//   · 不放在 NotificationHelper：那个文件是全站「即时通知」的（trigger: nil），
//     本功能是「定时通知」+ 权限状态机 + 本地列表，混在一起会让两边都难改；
//   · 通知中心一律走**完成回调 + withCheckedContinuation**，不用 `async` 变体、
//     也不把 UNNotification*/UNNotificationSettings 这类**非 Sendable** 对象跨越隔离域——
//     只让 Bool / [String] / 自定义 enum 这些 Sendable 值穿过续体。
//     这样在 Swift 6 严格并发下（本机无 iOS SDK，类型错只有 CI 才暴露）没有发送风险。

/// 通知权限状态（UI 据此决定「能不能排」和要不要给「去设置」引导）
enum QuickReminderAuth: Equatable, Sendable {
    /// 还没问过（第一次点「创建提醒」时问）
    case unknown
    /// 用户允许（含 provisional / ephemeral）
    case authorized
    /// 被拒（只能引导去系统设置改，App 内无法再弹）
    case denied
}

@MainActor
@Observable
final class QuickReminderStore {
    static let shared = QuickReminderStore()

    /// 全部提醒（未触发 + 已触发，列表按 scheduled/finished 分开读）
    private(set) var items: [QuickReminder] = []
    private(set) var auth: QuickReminderAuth = .unknown
    /// 系统里当前登记的本功能通知条数（对账后刷新，UI 用来给「系统已登记 N 条」的实感）
    private(set) var pendingCount: Int = 0
    /// 最近一次登记失败的原因（v3.9.41 SR30：iOS 只允许 64 条 pending，满了必须让用户知道）
    private(set) var lastScheduleError: String?

    private let defaultsKey = "qingliao_quick_reminders"
    /// 已触发的历史最多留 20 条（防无限增长；用户可手动清）
    private let maxFinishedKept = 20
    /// 通知标识前缀 —— ⚠️ 必须与 `QuickReminder.notificationIdentifier` 里的前缀一致
    /// （那半边在纯 Foundation 文件里，刻意不依赖本文件：真值表只编译 QuickReminder.swift）
    static let identifierPrefix = "quick_reminder_"

    private init() {
        loadLocal()
        markExpiredLocally()
    }

    // MARK: - 读取

    /// 待触发（按时间升序 —— 最近要响的在最上面）
    var scheduled: [QuickReminder] {
        items.filter { !$0.fired }.sorted { $0.fireDate < $1.fireDate }
    }

    /// 已触发 / 已失效（按时间倒序）
    var finished: [QuickReminder] {
        items.filter { $0.fired }.sorted { $0.fireDate > $1.fireDate }
    }

    // MARK: - 权限

    /// 只读当前状态（进页面时调，不弹系统弹窗）
    func refreshAuth() async {
        auth = await fetchAuthState()
    }

    /// 需要用权限时调：已授权直接过；没问过就问一次；被拒返回 false（由 UI 引导去系统设置）
    @discardableResult
    func ensureAuth() async -> Bool {
        let current = await fetchAuthState()
        auth = current
        switch current {
        case .authorized:
            return true
        case .denied:
            return false
        case .unknown:
            let granted = await requestAuthFromSystem()
            auth = granted ? .authorized : .denied
            if !granted { NSLog("[REMIND] ⚠️ 通知权限被拒，定时提醒无法注册") }
            return granted
        }
    }

    /// 跳到系统「通知」设置页（用户拒绝过权限后，App 内无法再弹系统弹窗）
    /// （UIApplication.shared 是 MainActor 隔离 → 这里不能标 nonisolated）
    static func openSystemNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - 通知中心桥接（只让 Sendable 值穿过续体）

    private func fetchAuthState() async -> QuickReminderAuth {
        await withCheckedContinuation { (cont: CheckedContinuation<QuickReminderAuth, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                cont.resume(returning: Self.mapAuth(settings.authorizationStatus))
            }
        }
    }

    private func requestAuthFromSystem() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error { NSLog("[REMIND] auth error: \(error)") }
                cont.resume(returning: granted)
            }
        }
    }

    /// 系统当前挂起的本功能通知标识（只回传 [String]，不回传 UNNotificationRequest）
    private func fetchPendingIdentifiers() async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                cont.resume(returning: requests.map { $0.identifier })
            }
        }
    }

    private nonisolated static func mapAuth(_ status: UNAuthorizationStatus) -> QuickReminderAuth {
        switch status {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        default: return .unknown
        }
    }

    // MARK: - 增删

    /// 新建：`parse` 由 QuickReminderParser 给出（含 fireDate 与重复规则）。
    /// 返回 false = 没排上（权限被拒 / 系统登记失败），**不要**把它当成成功。
    /// v3.9.41（SR30）：改成「系统登记成功才入库」——原先先 append+save、`add(request)` 失败只 NSLog，
    /// 于是系统 64 条 pending 上限之后「列表里有、到点没响」。失败原因写 `lastScheduleError` 供 UI 显示。
    @discardableResult
    func add(text: String, parse: QuickReminderParse) async -> Bool {
        guard await ensureAuth() else {
            // 权限被拒走 UI 的「去系统设置」引导文案，这里不覆盖成登记错误
            lastScheduleError = nil
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? parse.subjectHint : trimmed
        let item = QuickReminder(text: body.isEmpty ? "定时提醒" : body,
                                 fireDate: parse.fireDate,
                                 rule: parse.rule)
        if let reason = await schedule(item) {
            lastScheduleError = reason
            return false
        }
        lastScheduleError = nil
        items.append(item)
        save()
        await refreshPendingCount()
        return true
    }

    /// 删除：本地条目 + 系统挂起请求 + 已经弹出的那条通知
    func delete(_ item: QuickReminder) async {
        items.removeAll { $0.id == item.id }
        save()
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [item.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [item.notificationIdentifier])
        await refreshPendingCount()
    }

    /// 清空已提醒记录（不影响待触发的）
    func clearFinished() async {
        let gone = items.filter { $0.fired }.map { $0.notificationIdentifier }
        items.removeAll { $0.fired }
        save()
        if !gone.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: gone)
        }
        await refreshPendingCount()
    }

    // MARK: - 调度

    /// 注册一条系统级定时通知。
    /// · 一次性 → 年月日时分；重复 → 每天/每周的分量（见 QuickReminder.triggerComponents）
    /// · identifier 稳定 → 重复注册是**替换**，不会堆叠
    /// · 返回 nil = 成功；否则为可直接展示的失败原因（v3.9.41 SR30：失败必须能上屏，
    ///   文案在回调里就地转成 String 再跨续体，仍只让 Sendable 值穿过）
    @discardableResult
    private func schedule(_ item: QuickReminder) async -> String? {
        let content = UNMutableNotificationContent()
        content.title = "轻聊提醒"
        content.body = item.notificationBody
        content.sound = .default
        content.threadIdentifier = "qingliao_reminder"
        content.userInfo = ["qingliao_reminder": item.id]
        let trigger = UNCalendarNotificationTrigger(dateMatching: item.triggerComponents,
                                                    repeats: item.rule.repeats)
        let request = UNNotificationRequest(identifier: item.notificationIdentifier,
                                            content: content, trigger: trigger)
        let identifier = item.notificationIdentifier
        let label = item.text          // 只把 String 带进回调（避免让整个 struct 跨隔离域）
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    NSLog("[REMIND] ❌ 登记失败 \(identifier)：\(error)")
                    cont.resume(returning: "「\(label)」登记失败：\(error.localizedDescription)"
                        + "（系统每个 App 最多挂 64 条通知，可先删掉不用的）")
                } else {
                    NSLog("[REMIND] 已登记 \(identifier)")
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// 启动/进提醒页时对账（幂等，可反复调）：
    ///   1. 过期的一次性提醒 → 标 fired + 撤掉系统里那条（过期请求永远不响，还白占配额）
    ///   2. 未过期的 → 重新注册一次（App 重装/系统清理后自愈；同 identifier 替换不堆叠）
    ///   3. 系统里带本功能前缀、却不在本地列表的挂起请求 → 清掉（孤儿）
    func reconcile() async {
        markExpiredLocally()
        // 只**读**权限、不申请：申请权限的时机是「用户点了创建提醒」（add→ensureAuth）。
        // 若在启动对账时也去申请，会和 NotificationHelper.requestAuth() 抢同一次系统弹窗
        // （第一个还没被回答，第二个回调就带 false 回来 → auth 被误判成 denied）。
        await refreshAuth()
        guard auth == .authorized else {
            NSLog("[REMIND] 未授权，跳过重建（用户在提醒页创建时会再申请）")
            return
        }
        // v3.9.41（SR30）：重建时的登记失败也要让用户看见（否则「列表里有、到点没响」照样发生）
        var firstFailure: String?
        for item in items where !item.fired {
            if let reason = await schedule(item), firstFailure == nil { firstFailure = reason }
        }
        lastScheduleError = firstFailure
        let expiredIDs = items.filter { $0.fired }.map { $0.notificationIdentifier }
        let center = UNUserNotificationCenter.current()
        if !expiredIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: expiredIDs)
        }
        let pendingIDs = await fetchPendingIdentifiers()
        let known = Set(items.map { $0.notificationIdentifier })
        let orphans = pendingIDs.filter { $0.hasPrefix(Self.identifierPrefix) && !known.contains($0) }
        if !orphans.isEmpty {
            NSLog("[REMIND] 清理孤儿提醒请求 \(orphans.count) 条")
            center.removePendingNotificationRequests(withIdentifiers: orphans)
        }
        pendingCount = pendingIDs.filter { known.contains($0) }.count
    }

    /// 刷新「系统已登记 N 条」（删/增之后调）
    func refreshPendingCount() async {
        let pendingIDs = await fetchPendingIdentifiers()
        pendingCount = pendingIDs.filter { $0.hasPrefix(Self.identifierPrefix) }.count
    }

    // MARK: - 本地状态维护

    /// 过期的一次性提醒标 fired（纯本地判定，不碰通知中心；真机到点时系统已经响过）
    private func markExpiredLocally() {
        var changed = false
        for i in items.indices where items[i].isExpired() {
            items[i].fired = true
            changed = true
        }
        let expired = items.filter { $0.fired }.sorted { $0.fireDate > $1.fireDate }
        if expired.count > maxFinishedKept {
            let drop = Set(expired.dropFirst(maxFinishedKept).map { $0.id })
            items.removeAll { drop.contains($0.id) }
            changed = true
        }
        if changed { save() }
    }

    // MARK: - 持久化（UserDefaults 单键 JSON；编码/解码都用 .iso8601，策略必须对齐）

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func loadLocal() {
        // 解码策略必须与 save() 对齐，否则日期解不动 → 被 try? 吞掉 → 每次冷启动列表全空
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? decoder.decode([QuickReminder].self, from: data) else { return }
        items = decoded
    }
}
