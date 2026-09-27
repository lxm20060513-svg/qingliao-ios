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
    static func run(_ action: AgentAction) async -> Outcome {
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
        case .calendarDelete: return await deleteEvent(action)
        case .photoSave:      return await savePhoto(action)
        case .notify:         return await notify(action)
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
}
