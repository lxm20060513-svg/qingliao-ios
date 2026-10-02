import Foundation
import UIKit
import EventKit
import Photos
import UserNotifications

// MARK: - v3.9.95 AI 本地动作执行器
//
// 三条口径（与 AppPermissionKit 文件头、用户 v3.9.95 对齐，**这是全链路上唯一的执行点**）：
//   ① **所有写/删必须过 `AppPermissionKit.mutationGuard`**（后台保护 + 双闸门）。
//      本文件里任何一个写动作都不得跳过它 —— 跳过 = 用户授权了却没同意 AI 动手 = 越权。
//   ② **只读动作（查空闲/看今日日程）可以免确认**，但**仍要过状态检查**
//      （未授权要明确告诉用户「去设置里开日历权限」，而不是静默返回空）。
//   ③ **失败必须出声**：一切异常路径都返回 .failed(msg) + 震动，
//      绝不静默失败 —— 静默失败会让用户以为 AI 干成了，实际没干。
//
// 关于「后台不写」：日历写操作在 App 切后台时，EventKit 给的 store 句柄可能已失效
// （系统会收回授权），此时写进去的结果不可预期（可能写进默认容器、可能直接丢）。
// 宁可明确拒绝让用户回前台重试，也不要「看着成功其实没成」。

@MainActor
enum AgentActionExecutor {

    enum Outcome {
        /// 成功。undo 非空 → 卡片给 5 秒撤销（沿用动作条既有口径）
        case done(message: String, undo: (() async -> Void)?)
        /// 成功但不可撤销（如发了系统通知）
        case doneNoUndo(message: String)
        /// 失败（文案直接给用户看，勿技术化）
        case failed(String)
    }

    /// 统一入口。**卡片点「执行」→ 这里；只读动作自动执行 → 也这里。**
    static func run(_ action: AgentAction, auth: AuthStore? = nil) async -> Outcome {
        let cap = action.kind.capability

        // ①② 前置：能力不可用 / 未授权 —— 读动作也要查，否则用户面对「静默空结果」
        guard cap.aiControllable else {
            return .failed("\(cap.displayName)在当前安装方式下不可用")
        }
        let state = await AppPermissionKit.status(of: cap)
        guard state == .granted else {
            let hint = state.canRequestInApp ? "去「设置 → 权限与 AI 操控」开启" : "去系统设置里允许"
            return .failed("\(cap.displayName)未授权（当前：\(state.label)，\(hint)）")
        }

        switch action.kind {
        case .calendarFree:   return await freeSlots(action)
        case .calendarToday:  return await todayEvents(action)
        case .calendarCreate: return await createEvent(action)
        case .calendarUpdate: return await updateEvent(action)
        case .calendarDelete: return await deleteEvent(action)
        case .photoSave:      return await savePhoto(action)
        case .photoDelete:    return await deletePhoto(action)
        case .notify:         return await notify(action)
        // v4.0.x 邮件代发：需要登录态走后端，由 run(_:auth:) 直接分派（不走 runLocal）
        case .mailSend:       return await sendMail(action, auth: auth)
        // v4.0.7 长期目标：AI 判定「我在筹备XX」→ 用户点确认 → 建目标 + 拆步骤进待办
        case .goalCreate:     return await createGoal(action, auth: auth)
        case .goalStepDone:   return await markGoalStep(action, auth: auth)
        // v4.0.x 第二批能力（提醒事项/通讯录/定位/剪贴板/文件）。
        // ⚠️ 它们**只经由这里**进二级分派（AgentActionExecutorLocal.runLocal）——
        //    不要在那个文件里另起入口，双入口必然分叉。
        case .reminderCreate, .reminderList, .reminderDelete,
             .contactsSearch, .contactsCreate,
             .locationCurrent,
             .clipboardRead, .clipboardWrite,
             .fileList, .fileRead, .fileWrite:
            return await runLocal(action)
        }
    }

    // MARK: - 日历

    /// 查未来 N 天的空闲时段（默认 8 小时工作时段内）
    private static func freeSlots(_ action: AgentAction) async -> Outcome {
        let days = Int(action.param("days") ?? "") ?? 3
        let store = EKEventStore()
        let cal = store.defaultCalendarForNewEvents
        guard let cal else { return .failed("读不到默认日历") }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: max(1, min(days, 14)), to: start) else {
            return .failed("时间范围算不出来")
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [cal])
        // 读操作也要兜后台：后台时系统可能已经收回 store 的读权限
        guard AppPermissionKit.foregroundActive else { return .failed("App 在后台，先回到轻聊再查") }

        var busy: [String] = []
        for e in store.events(matching: predicate).sorted(by: { $0.startDate < $1.startDate }) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M月d日 HH:mm"
            busy.append("\(f.string(from: e.startDate))–\(f.string(from: e.endDate)) \(e.title ?? "无标题")")
        }
        if busy.isEmpty {
            return .doneNoUndo(message: "未来 \(days) 天日历是空的，没有占用")
        }
        return .doneNoUndo(message: "已占用时段：\n" + busy.prefix(8).joined(separator: "\n")
                          + (busy.count > 8 ? "\n…共 \(busy.count) 条" : ""))
    }

    /// 今天的日程
    private static func todayEvents(_ action: AgentAction) async -> Outcome {
        guard AppPermissionKit.foregroundActive else { return .failed("App 在后台，先回到轻聊再看") }
        let store = EKEventStore()
        guard let cal = store.defaultCalendarForNewEvents else { return .failed("读不到默认日历") }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else {
            return .failed("今天算不出来")
        }
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [cal]))
            .sorted { $0.startDate < $1.startDate }
        if events.isEmpty { return .doneNoUndo(message: "今天没有日程") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        let lines = events.prefix(10).map { "\(f.string(from: $0.startDate)) \($0.title ?? "无标题")" }
        return .doneNoUndo(message: "今天 \(events.count) 项：\n" + lines.joined(separator: "\n"))
    }

    /// 新建事件。**写操作**：调用方（动作卡）只在用户点「执行」胶囊后才走到这里，
    /// 本函数不再重复确认一次；它只做权限闸门（双闸门 + 后台保护）。
    private static func createEvent(_ action: AgentAction) async -> Outcome {
        // mutationGuard 返回 nil = 放行；非 nil = 拒绝原因（直接给用户看）
        if let reason = await AppPermissionKit.mutationGuard(.calendar) {
            return .failed(reason)
        }
        guard let title = action.param("title") else { return .failed("没给事件标题") }
        guard let startRaw = action.param("start"), let start = AgentAction.isoDate(startRaw) else {
            return .failed("没认出行程开始时间（要 ISO8601，如 2026-09-28T15:00:00+08:00）")
        }
        // 默认 1 小时；end 缺失或早于 start 都按 1 小时兜底
        let dur: TimeInterval
        if let endRaw = action.param("end"), let end = AgentAction.isoDate(endRaw), end > start {
            dur = end.timeIntervalSince(start)
        } else {
            dur = 3600
        }
        let store = EKEventStore()
        guard let cal = store.defaultCalendarForNewEvents else { return .failed("读不到默认日历") }
        let ev = EKEvent(eventStore: store)
        ev.title = title
        ev.startDate = start
        ev.endDate = start.addingTimeInterval(dur)
        ev.calendar = cal
        if let loc = action.param("location") { ev.location = loc }
        if let notes = action.param("notes") { ev.notes = notes }
        do {
            try store.save(ev, span: .thisEvent, commit: true)
        } catch {
            NSLog("[QLACTION] save event failed: \(error)")
            return .failed("日历写入失败：\(error.localizedDescription)")
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        // 撤销 = 删掉刚建的这条（日历没有「回滚」，只能反向删）
        return .done(message: "已新建「\(title)」\(f.string(from: start))",
                      undo: { try? store.remove(ev, span: .thisEvent, commit: true) })
    }

    /// 删除事件。**删操作**：必须用户明确确认。参数用 eventIdentifier（AI 从日历读到的 ID）。
    private static func deleteEvent(_ action: AgentAction) async -> Outcome {
        // mutationGuard 返回 nil = 放行；非 nil = 拒绝原因（直接给用户看）
        if let reason = await AppPermissionKit.mutationGuard(.calendar) {
            return .failed(reason)
        }
        guard let ident = action.param("eventIdentifier") ?? action.param("id") else {
            return .failed("没给要删的事件 ID")
        }
        guard AppPermissionKit.foregroundActive else { return .failed("App 在后台，先回到轻聊再删") }
        let store = EKEventStore()
        guard let ev = store.event(withIdentifier: ident) else {
            return .failed("找不到这个事件（可能已被删或 ID 过期）")
        }
        let title = ev.title ?? "无标题"
        let keep = ev.copy() as! EKEvent      // 删前留一份用于撤销（EKEvent 本身不能复用）
        do {
            try store.remove(ev, span: .thisEvent, commit: true)
        } catch {
            NSLog("[QLACTION] delete event failed: \(error)")
            return .failed("删除失败：\(error.localizedDescription)")
        }
        return .done(message: "已删除「\(title)」",
                      undo: { try? store.save(keep, span: .thisEvent, commit: true) })
    }

    /// 修改事件（v4.0.x）。**写操作**：只改给到的字段，没给的保持原样。
    /// 时间口径：给了 start 就整体挪（end 没给 → 保持原时长）；单独给 end 才只改结束时间。
    private static func updateEvent(_ action: AgentAction) async -> Outcome {
        // mutationGuard 返回 nil = 放行；非 nil = 拒绝原因（直接给用户看）
        if let reason = await AppPermissionKit.mutationGuard(.calendar) {
            return .failed(reason)
        }
        guard let ident = action.param("eventIdentifier") ?? action.param("id") else {
            return .failed("没给要改的事件 ID")
        }
        guard AppPermissionKit.foregroundActive else { return .failed("App 在后台，先回到轻聊再改") }
        let store = EKEventStore()
        guard let ev = store.event(withIdentifier: ident) else {
            return .failed("找不到这个事件（可能已被删或 ID 过期）")
        }
        let before = ev.copy() as! EKEvent      // 改前留一份用于撤销

        var changed: [String] = []
        if let t = action.param("title") { ev.title = t; changed.append("标题") }
        if let loc = action.param("location") { ev.location = loc; changed.append("地点") }
        if let notes = action.param("notes") { ev.notes = notes; changed.append("备注") }
        let oldDur = ev.endDate.timeIntervalSince(ev.startDate)
        if let raw = action.param("start") {
            guard let s = AgentAction.isoDate(raw) else {
                return .failed("没认出行程开始时间（要 ISO8601，如 2026-09-28T15:00:00+08:00）")
            }
            ev.startDate = s
            ev.endDate = s.addingTimeInterval(oldDur > 0 ? oldDur : 3600)
            changed.append("开始时间")
        }
        if let raw = action.param("end") {
            guard let e = AgentAction.isoDate(raw) else {
                return .failed("没认出行程结束时间（要 ISO8601，如 2026-09-28T16:00:00+08:00）")
            }
            guard e > ev.startDate else { return .failed("结束时间早于开始时间，没改") }
            ev.endDate = e
            changed.append("结束时间")
        }
        guard !changed.isEmpty else {
            return .failed("没说改什么（title / start / end / location / notes 至少给一个）")
        }
        do {
            try store.save(ev, span: .thisEvent, commit: true)
        } catch {
            NSLog("[QLACTION] update event failed: \(error)")
            return .failed("修改失败：\(error.localizedDescription)")
        }
        return .done(message: "已改「\(ev.title ?? "无标题")」的" + changed.joined(separator: "、"),
                      undo: { try? store.save(before, span: .thisEvent, commit: true) })
    }

    // MARK: - 相册

    /// 存图到相册。写操作 → 需确认。dataURL 由后端给（base64 PNG/JPEG）。
    private static func savePhoto(_ action: AgentAction) async -> Outcome {
        // mutationGuard 返回 nil = 放行；非 nil = 拒绝原因（直接给用户看）
        if let reason = await AppPermissionKit.mutationGuard(.photos) {
            return .failed(reason)
        }
        guard let raw = action.param("dataURL") ?? action.param("data") else {
            return .failed("没给图片数据")
        }
        guard let data = decodeDataURL(raw) else {
            return .failed("图片数据解不开（应形如 data:image/png;base64,…）")
        }
        guard let image = UIImage(data: data) else { return .failed("图片解不开，可能已损坏") }
        var localID: String?
        do {
            // PHPhotoLibrary 写相册不需要读权限，但**必须有** .addOnly 授权
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: data, options: nil)
                localID = req.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            NSLog("[QLACTION] save photo failed: \(error)")
            return .failed("存相册失败：\(error.localizedDescription)")
        }
        // 撤销 = 删掉刚存的那张（只能删自己创建的，系统允许）
        return .done(message: "已存入相册", undo: {
            guard let id = localID else { return }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            guard assets.count > 0 else { return }
            try? await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
        })
    }

    /// 删相册照片（v4.0.x）。**删操作**：只有用户在卡片上点过「确认删除」才会到这。
    /// 定位目标：优先 identifier（AI 从相册读到的 localIdentifier），退化支持 latest=N（最近 N 张，N≤5）。
    /// ⚠️ **不提供 5 秒撤销**：删完原图数据就读不回来了，没法凭空重建 asset。
    ///    但照片会进相册「最近删除」并保留 30 天 —— 文案必须让用户知道这条退路，
    ///    否则「删了就没」的观感会让人不敢用。
    private static func deletePhoto(_ action: AgentAction) async -> Outcome {
        // mutationGuard 返回 nil = 放行；非 nil = 拒绝原因（直接给用户看）
        if let reason = await AppPermissionKit.mutationGuard(.photos) {
            return .failed(reason)
        }
        guard AppPermissionKit.foregroundActive else { return .failed("App 在后台，先回到轻聊再删") }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var assets: PHFetchResult<PHAsset>
        if let ident = action.param("identifier") ?? action.param("localIdentifier") {
            assets = PHAsset.fetchAssets(withLocalIdentifiers: [ident], options: nil)
            guard assets.count > 0 else { return .failed("找不到这张照片（可能已经被删了）") }
        } else {
            let n = max(1, min(Int(action.param("latest") ?? "1") ?? 1, 5))
            options.fetchLimit = n
            assets = PHAsset.fetchAssets(with: .image, options: options)
            guard assets.count > 0 else { return .failed("相册里没有可删的照片") }
        }
        let count = assets.count
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
        } catch {
            NSLog("[QLACTION] delete photo failed: \(error)")
            return .failed("删除失败：\(error.localizedDescription)")
        }
        return .doneNoUndo(message: "已删除 \(count) 张照片（30 天内在相册「最近删除」可恢复）")
    }

    private static func decodeDataURL(_ raw: String) -> Data? {
        if let comma = raw.firstIndex(of: ","), raw.hasPrefix("data:") {
            return Data(base64Encoded: String(raw[raw.index(after: comma)...]), options: .ignoreUnknownCharacters)
        }
        return Data(base64Encoded: raw, options: .ignoreUnknownCharacters)
    }

    // MARK: - 通知

    /// 发系统通知。写操作 → 需确认。不可撤销（通知已出去了）→ doneNoUndo。
    private static func notify(_ action: AgentAction) async -> Outcome {
        // mutationGuard 返回 nil = 放行；非 nil = 拒绝原因（直接给用户看）
        if let reason = await AppPermissionKit.mutationGuard(.notifications) {
            return .failed(reason)
        }
        let body = action.param("body") ?? action.param("message") ?? "（无内容）"
        let content = UNMutableNotificationContent()
        content.title = action.param("title") ?? "轻聊"
        content.body = body
        content.sound = .default
        // 用即时 trigger：1 秒后（UNTimeIntervalNotificationTrigger 最小 0.01）
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let id = "ql.action.\(UUID().uuidString)"
        let center = UNUserNotificationCenter.current()
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        } catch {
            NSLog("[QLACTION] notify failed: \(error)")
            return .failed("发通知失败：\(error.localizedDescription)")
        }
        return .doneNoUndo(message: "已发出通知")
    }

    // MARK: - 邮件（v4.0.x AI 代发）

    /// AI 代发邮件。**写动作**：只读动作免确认那条路走不到这里，只有卡片点「执行」才会调。
    ///
    /// 与其它写动作的关键区别：**发不发得出去**的真闸门在**后端账号配置**
    /// （设置 → 邮件 → 该账号「允许 AI 直接发送」），不在 iOS —— status(of: .mail) 恒 .granted
    /// （邮件没有任何 TCC 授权可请求，理由见 AppPermissionKit.status 里的注释）。
    /// ⚠️ **App 侧闸门照样要过**（v3.9.110 审查修）：权限页对每个 `aiControllable` 能力都渲染
    ///    「允许 AI 操作·X」开关，而 `status(of: .mail)` 恒 `.granted` ⇒ 若这里不走 mutationGuard，
    ///    用户把该开关（或总闸）关掉后 AI 照样能发信 —— 那个开关就成了摆设。故与其它写动作同口径，
    ///    先过 `mutationGuard(.mail)`（后台保护 + 总闸 + 单项开关 + 系统授权一起判）。
    ///    两道闸门各管一段：App 侧管「用户允不允许 AI 动这个能力」，后端账号配置
    ///    （「允许 AI 直接发信」）管「真发还是只存草稿」——**别把后者当前者的替代**。
    ///
    /// ⚠️ 最要紧的一条：**绝不把「只生成了草稿」说成「已发送」**。后端三种结果
    ///    （sent / draft / ok:false）分别对三句不同的话，draft 必须让用户知道「没发出去」。
    private static func sendMail(_ action: AgentAction, auth: AuthStore?) async -> Outcome {
        if let reason = await AppPermissionKit.mutationGuard(.mail) { return .failed(reason) }
        guard let to = action.param("to") else { return .failed("缺收件人") }
        guard let auth else { return .failed("登录状态不可用，请回到轻聊重试") }
        let subject = action.param("subject") ?? ""
        let body = action.param("body") ?? ""
        var payload: [String: Any] = ["to": to, "subject": subject, "body": body]
        // account 可选：不传 = 后端自己挑默认账号；传了 = 指定用哪个邮箱发（多账号时用）
        if let acc = action.param("account") { payload["account"] = acc }
        let res: [String: Any]
        do {
            res = try await auth.json("/api/mail/ai_send", method: "POST", body: payload)
        } catch {
            NSLog("[QLACTION] mail.send 请求失败: \(error)")
            return .failed("发送失败：\(error.localizedDescription)")
        }
        // 后端口径：出错时 HTTP 仍是 200，错误在 body 的 ok/error 里（跟该文件既有风格一致）
        if (res["ok"] as? Bool) == false {
            return .failed((res["error"] as? String) ?? "发送失败")
        }
        if (res["sent"] as? Bool) == true {
            let subj = subject.isEmpty ? "（无主题）" : "（主题：\(subject)）"
            return .doneNoUndo(message: "已发送邮件给 \(to)\(subj)")
        }
        if (res["draft"] as? Bool) == true {
            // note 由后端原样透传（说明为什么没真发、要用户去做什么）→ 优先念给用户听；
            // 后端没给才回落到本地兜底句。⚠️ 别自己另编一句盖掉它：后端知道的具体原因更多。
            let note = (res["note"] as? String) ?? "该账号未开启「允许 AI 直接发信」，去 设置 → 邮件 打开后再说一次"
            return .doneNoUndo(message: "未发送：\(note)")
        }
        // ok=true 但既没 sent 也没 draft：后端契约变了 —— 不猜、不报成功
        return .failed("发送结果不明确（后端未回 sent/draft）")
    }

    // MARK: - v4.0.7 长期目标
    //
    // 口径（用户 v4.0.7 定）：
    //   AI 只**提议**（ql-action 卡片），用户点「执行」才真建 —— 绝不自动建。
    //   建目标 = 写本地 GoalStore（卡片立刻可见）+ 问后端建每日 9:00 推进 job。
    //   两段 cron 已按用户口径收为**只早上 9:00 一条**。
    //
    // ⚠️ steps 走 JSON 字符串参数：AgentAction.params 是 [String: String] 标量字典，
    //    协议不收数组。AI 侧负责把步骤序列化成 JSON 字符串，这里只做**容错解析**——
    //    解析不出来就退回通用里程碑（与后端 _auto_split 同一口径），不静默丢步骤。

    /// AI 给的步骤列表：容错收 JSON 数组 / 换行分隔的纯文本
    private static func parseSteps(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        if let data = raw.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            let titles = arr.compactMap { item -> String? in
                if let s = item as? String { return s.trimmingCharacters(in: .whitespaces) }
                if let d = item as? [String: Any] {
                    if let t = d["title"] as? String { return t.trimmingCharacters(in: .whitespaces) }
                    if let t = d["text"] as? String { return t.trimmingCharacters(in: .whitespaces) }
                }
                return nil
            }
            let ok = titles.filter { !$0.isEmpty }
            if !ok.isEmpty { return ok }
        }
        // 非 JSON → 按换行/顿号切（AI 常直接写「1. 选题 2. 备货」）
        return raw
            .components(separatedBy: CharacterSet(charactersIn: "\n、;；"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func createGoal(_ action: AgentAction, auth: AuthStore?) async -> Outcome {
        if let reason = await AppPermissionKit.mutationGuard(.reminders) { return .failed(reason) }
        guard let title = action.param("title") else { return .failed("缺目标标题") }
        let steps = parseSteps(action.param("steps"))
        let hour = action.param("morningHour").flatMap { Int($0) } ?? 9

        // 用户 v4.0.7 口径：只早上 9:00 一条，晚间复盘段默认关掉
        let g = GoalItem(title: title,
                         steps: steps.map { GoalStep(title: $0) },
                         morningEnabled: true, eveningEnabled: false,
                         morningHour: hour)
        let gid = g.id

        // 1) 先落本地：卡片立刻出现在生活页，不等网络
        await MainActor.run { GoalStore.shared.add(g) }
        // 1b) 步骤灌进待办清单（用户口径：打通，拆出的步骤直接进待办）
        await MainActor.run { GoalTodoBridge.pushStepsToTodo(g) }  // 同一 target，桥可见

        // 2) 再让后端把每日 9:00 的 cron job 建上（复用 store 既有封装，回灌 cronJobID）
        let merged = await GoalStore.shared.createOnBackend(g)
        if let merged, !merged.cronJobID.isEmpty {
            await MainActor.run { GoalStore.shared.update(merged) }
            return .done(message: "已在后台运行 · 每天 \(hour):00 推进 · 共 \(steps.count) 步（已进待办）",
                          undo: {
                              await MainActor.run { GoalStore.shared.remove(gid) }
                              await GoalStore.shared.deleteOnBackend(goalID: gid)
                          })
        }
        // 口径 ③：失败必须出声。目标已建但没建上每日推送 = 半成品，如实说，不假装成功。
        // 不可撤销：目标已落库，撤销它等于静默删用户数据 → 用 doneNoUndo（语义也更准）
        return .doneNoUndo(message: "已建目标「\(title)」并进了待办，但每日自动推进没建上（目标卡片详情里可重试）")
    }

    private static func markGoalStep(_ action: AgentAction, auth: AuthStore?) async -> Outcome {
        if let reason = await AppPermissionKit.mutationGuard(.reminders) { return .failed(reason) }
        guard let gid = action.param("goalId") else { return .failed("缺目标 ID") }
        guard let sid = action.param("stepId") else { return .failed("缺步骤 ID") }
        let done = (action.param("done") ?? "true") != "false"
        // 直接写目标态（不是 toggle）—— toggle 在「想勾成未勾」时会反向
        await MainActor.run {
            GoalStore.shared.mutate(gid) { g in
                guard let j = g.steps.firstIndex(where: { $0.id == sid }) else { return }
                g.steps[j].done = done
                g.steps[j].doneAt = done ? Date() : nil
            }
        }
        // 步骤同步进待办清单：勾了就在待办里划掉
        await MainActor.run { GoalTodoBridge.syncStepDone(goalID: gid, stepID: sid) }
        // 后端只暴露 PATCH /api/life/goal（已实测），步骤态随目标一起带回去
        if let auth {
            _ = try? await auth.json("/api/life/goal", method: "PATCH",
                                     body: ["id": gid, "stepId": sid, "stepDone": done])
        }
        return .doneNoUndo(message: done ? "已勾掉这一步" : "已恢复这一步")
    }
}
