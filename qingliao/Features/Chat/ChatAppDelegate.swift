import SwiftUI
import UIKit
import UserNotifications
// v4.0.118：③ 后台刷新任务（BGTaskScheduler/BGAppRefreshTask/BGAppRefreshTaskRequest）在这个框架里。
// 🚨 漏这个 import 本地 `swiftc -parse`（只查语法）**照样绿**，CI Archive 才报
//    「cannot find type 'BGTaskScheduler' in scope」—— 又是一轮 20 分钟。
import BackgroundTasks

// MARK: - v2.0.65 发送完成通知（Dock 轻跳）

// MARK: - v2.0.60 通知点击直达会话（AppDelegate 捕获通知点击 → 存 sessionId）

extension Notification.Name {
    static let qingliaoSent = Notification.Name("qingliao_sent")
    // v3.4.26：看板轮询 Leave/Refresh 通知已移除——改 DockTabView → DashboardView(isActive:) 参数直传，
    // 生命周期收进 DashboardView 自身（见 DashboardView.onChange/.task(id:)）；通知名定义随引用清除
    // v3.4.14：系统分享收件通知（DockTabView.onOpenURL 捕获分享后广播，ChatView 消费发送）
    static let qingliaoShareIncoming = Notification.Name("qingliao_share_incoming")
    // v3.4.x：任务中心「发送到当前会话」通知（TaskCenterView 广播，ChatView 消费发送）
    static let qingliaoTaskSend = Notification.Name("qingliao_task_send")
    // v3.9.14：备忘录「发给 AI」——生活页发通知，这里发送 + DockTabView 切回聊天页
    static let qingliaoMemoSend = Notification.Name("qingliao_memo_send")
    // v3.9.79：长按快捷菜单弹出 → 收键盘（DockTabView 广播，ChatView 消费）
    // （用户 2026-09-25：「这个界面自动收回键盘」——键盘开着时长按球/宠物，六颗胶囊被键盘挤在上半屏）
    static let qingliaoDismissKeyboard = Notification.Name("qingliao_dismiss_keyboard")
    // v3.9.59：长按 dock 智慧球 →「语音输入」胶囊——DockTabView 切聊天页后广播，ChatView 消费进语音模式
    static let qingliaoOrbVoiceInput = Notification.Name("qingliao_orb_voice_input")
    // v4.0.x：会话纪要页整理完 → 把纪要卡放进当前会话（MeetingMinutesView 广播，object = 卡片文本）
    static let qingliaoMinutesCard = Notification.Name("qingliao_minutes_card")
    // v4.0.1：分享接收（ShareIntake，在 Core 层摸不到 DockTabView 的 selected）投递前，
    // 先请宿主把聊天页切进视图树 —— 载荷的落点全是 ChatView 挂的 onReceive，人不在就落空。
    static let qingliaoOpenChat = Notification.Name("qingliao_open_chat")
}

// MARK: - v2.0.60 通知点击直达会话（AppDelegate 捕获通知点击 → 存 sessionId）

// v2.0.64：@preconcurrency 抑制 Swift 6 的 delegate 跨 MainActor Sendable 检查
final class QingliaoAppDelegate: NSObject, UIApplicationDelegate,
                                 @preconcurrency UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // v3.9.83：非 scene 进程的冷启动路径（App 未采用 scene 时，系统把快捷方式塞进 launchOptions）。
        // scene 化进程（SwiftUI 生命周期）走 QingliaoSceneDelegate —— 两条互补，互不干扰。
        if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            HomeShortcutManager.handle(item)
        }
        // v3.9.82：桌面图标长按快捷方式 —— 按用户设置重建系统菜单（动态 shortcutItems；
        // 桌面长按菜单系统上限 4 项，所以 6 个候选里只挂选中的那几个）
        HomeShortcutManager.sync()
        // v4.0.118：③ 注册后台刷新任务。BGTaskScheduler.register 必须在启动完成前调用，
        // 且 identifier 要在 project.yml 的 BGTaskSchedulerPermittedIdentifiers 白名单里。
        registerBackgroundRefresh()
        return true
    }

    /// v3.9.83：注册自己的 scene delegate —— SwiftUI 生命周期下快捷方式事件**只发给 scene delegate**，
    /// 不注册 = AppDelegate 的 performActionFor 永远不会被调用（v3.9.82 真机「点了不跳转」的根因）。
    /// 只借它收快捷方式事件，窗口仍归 SwiftUI 的 WindowGroup 管（delegate 里不建窗口）。
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = QingliaoSceneDelegate.self
        return config
    }

    /// v3.9.82 起保留、v3.9.83 起降为**兜底**：只有非 scene 进程会走这条（scene 进程走 QingliaoSceneDelegate）。
    /// 留着零成本 —— 哪天进程不再是 scene-based，链路照样通。
    /// 返回 false = 不是本 App 的快捷方式类型，交回系统默认行为。
    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(HomeShortcutManager.handle(shortcutItem))
    }

    // v2.0.110：后台刷新（方案2推送）——iOS 定期唤醒 App，检查流式任务是否完成 →
    // 完成则发本地通知（侧载无 entitlement 也能用；唤醒间隔由系统决定，非实时）
    //
    // v4.0.118（用户口径「提高本地推送的及时性和后台保活」）：**原来这里只查流式任务**
    // （UserDefaults 里有 qingliao_stream_pending 才动），Hermes 推进收件箱的消息
    // （任务中心 / 告警 / 目标日报 / AI 追问）在挂起期间一条也弹不出来 —— 用户不开 App
    // 就等于没收到。现在拆成**两条腿并行**（流式任务 + 收件箱），聚合器保证只回调系统一次；
    // 每次唤醒另记一笔台账（BackgroundWakeLog）：唤醒时机由系统决定，"及不及时"只能靠
    // 实测分布判断，不能靠感觉。
    func application(_ application: UIApplication,
                     performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let ep = Self.endpoint() else {
            // 未登录/无 token：也要记一笔 —— 否则「近 N 小时叫醒几次」里这几次有来源没结果
            BackgroundWakeLog.record(.fetch, outcome: "noData no-endpoint")
            completionHandler(.noData)
            return
        }
        BackgroundWakeLog.record(.fetch)
        let agg = BackgroundFetchAggregator(legs: 2, completion: completionHandler)
        Self.checkStream(kind: .fetch, base: ep.base, token: ep.token, agg: agg)
        Self.checkInbox(kind: .fetch, base: ep.base, token: ep.token, agg: agg)
    }

    // MARK: - v4.0.118 ③ 后台刷新任务（BGAppRefreshTask）+ 唤醒台账

    /// 后台刷新任务 id。🚨 必须与 project.yml 的 `BGTaskSchedulerPermittedIdentifiers` 逐字一致：
    /// identifier 不在 Info.plist 白名单里，`BGTaskScheduler.register` 会**抛异常** —— 真机才崩，
    /// `swiftc -parse` 与 CI archive 都查不出（同「缺权限串只在用户真点一次时崩」那类教训）。
    static let refreshTaskId = "com.qingliao.app2.refresh"

    /// 启动时注册（必须在 launch 结束前）。顺带记一笔「冷启动」台账。
    func registerBackgroundRefresh() {
        BackgroundWakeLog.record(.launch)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleAppRefresh(refresh)
        }
        // 老 fetch（UIBackgroundModes: fetch）也报一个最小间隔：不报 = 系统按最懒的档排。
        // ⚠️ 已废弃的 API，但侧载 App 上它仍是**第二条**被叫醒的路，与 BGAppRefreshTask 互补。
        UIApplication.shared.setMinimumBackgroundFetchInterval(15 * 60)
    }

    /// 排下一次后台刷新。⚠️ 系统同时只保留**一个**未完成的请求 ⇒ 每次唤醒/进后台都重排，
    /// 否则只响一次就断供。`earliestBeginDate` 是「**不早于**」而不是「准时」。
    static func scheduleAppRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(req)
        } catch {
            NSLog("[BG] 排下一次后台刷新失败：\(error)")
        }
    }

    /// 系统给的刷新窗口：跑与 legacy fetch **完全相同**的那两条腿（别各写一套检查）。
    /// ⚠️ 必须是 nonisolated：本方法由 BGTaskScheduler 在后台队列回调，
    /// 进 MainActor 隔离的方法体 = 隔离断言 SIGTRAP（与 v3.9.4 通知回调同源）。
    /// 需要读 Keychain/UserDefaults 的那一步放进 `Task { @MainActor in … }`，只送 String 过去。
    nonisolated static func handleAppRefresh(_ task: BGAppRefreshTask) {
        BackgroundWakeLog.record(.refreshTask)
        scheduleAppRefresh()                        // 先排下一次：本窗口随时可能被收回
        let agg = BackgroundFetchAggregator(legs: 2) { r in
            // 收尾时顺手摘掉过期回调：`expirationHandler` 强引用 agg、completion 强引用 task
            // ⇒ 不摘就是一对互引（系统放掉 task 后这对对象仍不释放，每次唤醒漏一对）。
            task.expirationHandler = nil
            // ⚠️ 聚合器给的是 `UIBackgroundFetchResult`，而 `setTaskCompleted(success:)` **只认 Bool**
            //    —— 直接传结果是 `cannot convert value of type 'UIBackgroundFetchResult' to expected
            //    argument type 'Bool'`（本地 `-parse` 查不出、CI Archive 才炸，v4.0.118 实踩一轮）。
            //    映射：有数据/空转都算成功，只有 failed 算失败（否则系统按失败降权调度，唤醒间隔越拉越长）。
            task.setTaskCompleted(success: r != .failed)
        }
        task.expirationHandler = { agg.expire() }   // 收回窗口 → 立刻收尾（聚合器保证只回调一次）
        Task { @MainActor in
            guard let ep = Self.endpoint() else {
                // 🚨 必须用 abandon（force 收尾）：这里另一条腿也不可能跑了，而 `finish` 只把
                //    remaining 减 1（legs=2）→ `setTaskCompleted` 永不触发 ⇒ 每次唤醒都白等满窗口、
                //    由系统按超时处理（无日志、无异常，只有台账看得出「叫醒了但没收尾」）。
                BackgroundWakeLog.record(.refreshTask, outcome: "noData no-endpoint")
                agg.abandon(.noData)
                return
            }
            Self.checkStream(kind: .refreshTask, base: ep.base, token: ep.token, agg: agg)
            Self.checkInbox(kind: .refreshTask, base: ep.base, token: ep.token, agg: agg)
        }
    }

    /// 进后台。⚠️ 本 App 是 **scene 化**进程：`applicationDidEnterBackground` **永不被调用**，
    /// 真入口是 `QingliaoSceneDelegate.sceneDidEnterBackground`（HomeShortcuts.swift 里转发到这儿）。
    @MainActor static func didEnterBackground() {
        BackgroundWakeLog.record(.entering)
        scheduleAppRefresh()
    }

    /// 回前台（同样走 scene delegate 转发）
    @MainActor static func willEnterForeground() {
        BackgroundWakeLog.record(.foreground)
        // v4.0.118 ①：回前台顺手把「已知时刻」的时刻表重排一次（拉清单 → 登记系统通知 → 清孤儿）。
        // 清单窗口 48h，用户只要两天内开过一次 App，预排通知就不会断供。
        Task { await ScheduleStore.shared.refreshAndReconcile() }
    }

    // MARK: - v4.0.118 后台检查的两条腿

    /// 腿①：流式任务跑完没（v2.0.110 原逻辑，只改成往聚合器记账）
    /// `kind` 只用于台账：legacy fetch 与 BGAppRefreshTask 是**两条不同的唤醒来源**，
    /// 混记一处就看不出"哪条路在起作用"（也就没法判断值不值得继续维护老 fetch）。
    nonisolated static func checkStream(kind: BackgroundWakeKind, base: String, token: String,
                                        agg: BackgroundFetchAggregator) {
        guard let d = UserDefaults.standard.dictionary(forKey: "qingliao_stream_pending"),
              let taskId = d["taskId"] as? String, !taskId.isEmpty,
              let url = URL(string: base + "/api/stream/" + taskId) else {
            BackgroundWakeLog.record(kind, outcome: "noData stream:none")
            agg.finish(.noData)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                BackgroundWakeLog.record(kind, outcome: "failed stream:http")
                agg.finish(.failed)
                return
            }
            let status = j["status"] as? String ?? ""
            guard status == "done" || status == "error" else {
                BackgroundWakeLog.record(kind, outcome: "noData stream:\(status)")
                agg.finish(.noData)   // 未完成，等下次系统唤醒再查
                return
            }
            // 回复完成 → 本地通知 + 清理持久化任务
            let sid = d["sessionId"] as? String
            // v3.4.26：正文取回复首句（后端 GET /api/stream/{taskId} 返回 content）
            NotificationHelper.notifyReply((j["content"] as? String) ?? "", sessionId: sid)
            UserDefaults.standard.removeObject(forKey: "qingliao_stream_pending")
            BackgroundWakeLog.record(kind, outcome: "newData stream:\(status)")
            // v3.9.54：修「后台跑完灵动岛不收尾」。上面这条通知说明**这个回调就是本进程
            // 在后台唯一知道「任务已结束」的时刻**——但原来它从不碰实时活动，于是活动一直
            // 停在「AI 正在回复」，直到用户回前台才被收敛/兜底收掉（用户报的现象逐字一致）。
            // ⚠️ 本闭包由 URLSession 在任意线程回调，`LiveActivityManager` 是 @MainActor，
            // 且这里只能送 Sendable 值（sid / failed），所以走 `Task { @MainActor in … }`。
            let failed = (status == "error")
            Task { @MainActor in
                await LiveActivityManager.shared.reconcileAfterBackgroundCheck(sessionId: sid,
                                                                              failed: failed)
            }
            agg.finish(.newData)
        }.resume()
    }

    /// 腿②（v4.0.118 新增）：收件箱里有没有该弹的新推送。
    /// 判据全在纯函数 `InboxBackgroundPlan.plan`（本机真值表钉着），这里只管网络与弹通知。
    /// **不 markDone、不注入会话气泡** —— 条目留在队列里等前台 InboxStore 拉取；前台随后会用
    /// **同内容**再弹一次，靠 `NotificationHelper` 的稳定 identifier（正文哈希）就地替换，不堆叠。
    nonisolated static func checkInbox(kind: BackgroundWakeKind, base: String, token: String,
                                       agg: BackgroundFetchAggregator) {
        guard let url = URL(string: base + "/api/inbox") else {
            BackgroundWakeLog.record(kind, outcome: "failed inbox:url")
            agg.finish(.failed)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = j["items"] as? [[String: Any]] else {
                BackgroundWakeLog.record(kind, outcome: "failed inbox:http")
                agg.finish(.failed)
                return
            }
            let consumed = Set((UserDefaults.standard.array(forKey: InboxKeys.consumedIds) as? [String]) ?? [])
            let todo = InboxBackgroundPlan.plan(items: items, consumedIds: consumed)
            for it in todo {
                NotificationHelper.notify(kind: QingliaoNotifyKind.fromTaskType(it.kind),
                                          body: it.body, detail: it.detail, sessionId: it.sessionId)
            }
            BackgroundWakeLog.record(kind, outcome: (todo.isEmpty ? "noData" : "newData")
                                     + " inbox:\(todo.count)/\(items.count)")
            agg.finish(todo.isEmpty ? .noData : .newData)
        }.resume()
    }

    // MARK: - v4.0.118 后台请求要的两个值

    /// ⚠️ 读 Keychain/UserDefaults 这步必须在 **MainActor** 上：`AuthStore` 是 @MainActor 类，
    /// 其 static 成员同样被隔离 —— 从 nonisolated 上下文（BGTask 回调线程）直接读会编译不过。
    @MainActor static func endpoint() -> (base: String, token: String)? {
        let server = UserDefaults.standard.string(forKey: "qingliao_server") ?? ""
        // v3.0.84fix：token 迁 Keychain，后台刷新从 Keychain 读（原 UserDefaults 明文已弃）
        let token = AuthStore.keychainReadToken() ?? ""
        guard !server.isEmpty, !token.isEmpty else { return nil }
        var base = server
        if !base.hasPrefix("http") { base = "https://" + base }
        return (base, token)
    }

    // v2.0.63：用 completionHandler 版（async 版在 Swift 6 下 non-Sendable 参数报错）
    // v3.9.4 加固：本类因 `UIApplicationDelegate`（SDK 里是 @MainActor 协议）被推断为 MainActor 隔离，
    // 而 `UNUserNotificationCenterDelegate` **不是** @MainActor（Apple 文档声明仅 NSObjectProtocol，
    // 对回调线程无任何承诺）⇒ 上面的 @preconcurrency 只是把隔离检查**推迟到运行时**：
    // 一旦系统在后台线程回调「点通知」，进方法体即触发隔离断言 = SIGTRAP（与 v3.9.3 语音那次同源）。
    // 方法体只读写 UserDefaults（线程安全、非隔离）并转调 completionHandler，本就不需要主 actor
    // ⇒ 标 nonisolated 即消除该断言，行为零变化（当前线上恰好都在主线程，故一直没暴露）。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let sid = response.notification.request.content.userInfo["qingliao_session"] as? String {
            UserDefaults.standard.set(sid, forKey: "qingliao_open_session")
        }
        completionHandler()
    }

    /// v3.9.39 A6：**前台到点不响**的根治。Apple 的规则是「设了 delegate 但没实现 willPresent
    /// ⇒ 前台来的通知不弹横幅、不出声、也不进通知中心（直接丢弃）」。本类自 v2.0.60 起就是全仓
    /// 唯一的 UNUserNotificationCenterDelegate（:33 赋值），所以所有本地通知在 App 前台时被静默吃掉：
    /// · 一句话定时提醒（典型用法就是「聊天里长按消息 → 5 分钟后提醒」，用户 100% 停在 App 里）
    ///   ——到点无声，下次冷启动 `markExpiredLocally()` 还把它标成「已提醒」，等于凭空消失；
    /// · 收件箱推送 / AI 回复完成通知——InboxStore 注释里写的「App 前台也弹」一直没成立过。
    /// 不给 `.badge`：图标角标由 `NotificationHelper.setBadge` 按任务中心未读数**整体对账**设置
    /// （v3.4.23），再让系统 +1 会变成双重计数、且没有清零路径。
    /// 与 `didReceive` 同样标 `nonisolated`：理由见上面那段 v3.9.4 说明（后台线程回调进 MainActor 体 = SIGTRAP）。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}


// MARK: - v4.0.118 后台检查「两条腿」的完成聚合器

/// 后台检查有两条腿（流式任务 / 收件箱），而系统只接受**一次** completion 回调。
/// 两条腿都回来才回调；并且**保证只回调一次** —— 迟到的腿、或系统收回窗口后的收尾，
/// 都不会触发第二次（重复调 `completionHandler` / `setTaskCompleted` 是未定义行为）。
/// 状态全在锁内 ⇒ 标 `@unchecked Sendable`（完成回调来自 URLSession 的任意线程）。
final class BackgroundFetchAggregator: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var result: UIBackgroundFetchResult = .noData
    private var fired = false
    private let completion: (UIBackgroundFetchResult) -> Void

    init(legs: Int, completion: @escaping (UIBackgroundFetchResult) -> Void) {
        self.remaining = max(1, legs)
        self.completion = completion
    }

    /// 一条腿跑完（.newData / .noData / .failed）
    func finish(_ r: UIBackgroundFetchResult) {
        settle(r, force: false)
    }

    /// 一条腿**根本不会来**（例：未登录 / 无 endpoint，另一条腿同样跑不了）→ 立刻以该结果收尾，
    /// 别让系统白等满窗口。
    /// 🚨 不能拿 `finish` 顶替：`finish` 只把 `remaining` 减 1，`legs=2` 时永远到不了 0，
    /// `setTaskCompleted` 不触发（真值表钉住这条调用点）。
    func abandon(_ r: UIBackgroundFetchResult) {
        settle(r, force: true)
    }

    /// 系统把时间收回 / 任务到期：立刻收尾（已取到的结果照算，之后不再等另一条腿）
    func expire() {
        settle(.failed, force: true)
    }

    /// 结果合成规则：任一条腿拿到新数据 ⇒ .newData；都没拿到但有一条失败 ⇒ .failed；否则 .noData。
    private func settle(_ r: UIBackgroundFetchResult, force: Bool) {
        lock.lock()
        if fired {
            lock.unlock()
            return
        }
        switch r {
        case .newData: result = .newData
        case .failed:  if result == .noData { result = .failed }
        default:       break
        }
        remaining -= 1
        if force || remaining <= 0 { fired = true }
        let fire = fired
        let final = result
        lock.unlock()
        if fire { completion(final) }
    }
}
