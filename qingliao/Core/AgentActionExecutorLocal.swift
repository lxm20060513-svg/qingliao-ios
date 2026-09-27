import Foundation
import UIKit
import EventKit
import Contacts
import CoreLocation

// MARK: - v4.0.x AI 本地动作执行器（第二批：提醒事项 / 通讯录 / 定位 / 剪贴板 / 文件）
//
// 与 AgentActionExecutor.swift 同一套三条口径（用户 v3.9.95 定的，一个字没改）：
//   ① 所有写/删必须过 `AppPermissionKit.mutationGuard`（后台保护 + 双闸门）；
//   ② 只读动作可以免确认，但**仍要过状态检查**（未授权要说清"去设置里开"，不许静默返回空）；
//   ③ 失败必须出声：一切异常路径返回 .failed(msg)，绝不静默失败。
//
// 为什么单独成文件：原文件 240 行，再塞 5 类能力会到 700+。**入口仍然只有一个** ——
// AgentActionExecutor.run(_:) 里的那个 switch，本文件只做二级分派（runLocal）。
// 千万不要在这里另起一条进入路径：双入口必然分叉，两条口径会各改各的。
//
// 🚨 2026-09-27 说明「提醒事项为什么能做」：此前 AppPermissionKit 与后端 QLACTION_PROMPT
//    都写着"提醒事项 Apple 未提供 API"——**那是错的**。EventKit 自 iOS 6 起就有
//    `EKReminder` / `predicateForIncompleteReminders` / `requestFullAccessToReminders()`，
//    与日历同一个 EKEventStore。侧载也不影响（走普通 TCC，不需要 entitlement）。

extension AgentActionExecutor {

    /// 二级分派。**只由 AgentActionExecutor.run(_:) 调用。**
    static func runLocal(_ action: AgentAction) async -> Outcome {
        switch action.kind {
        case .reminderCreate:  return await createReminder(action)
        case .reminderList:    return await listReminders(action)
        case .reminderDelete:  return await deleteReminder(action)
        case .contactsSearch:  return await searchContacts(action)
        case .contactsCreate:  return await createContact(action)
        case .locationCurrent: return await currentLocation()
        case .clipboardRead:   return await readClipboard()
        case .clipboardWrite:  return await writeClipboard(action)
        case .fileList:        return await listFiles(action)
        case .fileRead:        return await readFile(action)
        case .fileWrite:       return await writeFile(action)
        // 其余动作不走这条路（编译期就能发现漏接：这里只列本地那 11 个）
        case .calendarCreate, .calendarUpdate, .calendarDelete, .calendarFree, .calendarToday,
             .photoSave, .photoDelete, .notify:
            return .failed("内部错误：这个动作不该走本地分派")
        }
    }

    // MARK: - 提醒事项（EventKit .reminder）

    private static func createReminder(_ action: AgentAction) async -> Outcome {
        // mutationGuard 返回 nil = 放行；非 nil = 拒绝原因（直接给用户看）
        if let reason = await AppPermissionKit.mutationGuard(.reminders) {
            return .failed(reason)
        }
        guard let title = action.param("title") ?? action.param("body") else {
            return .failed("没给提醒内容")
        }
        let store = EKEventStore()
        guard let list = store.defaultCalendarForNewReminders() else {
            return .failed("读不到默认提醒列表")
        }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = list
        if let notes = action.param("notes") { r.notes = notes }
        var dueText = ""
        if let raw = action.param("due") ?? action.param("start"), let due = AgentAction.isoDate(raw) {
            // 用当前时区的年月日时分落库（跨时区时按设备本地时间显示，与日历口径一致）
            r.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            // 到点就响：默认闹钟没有 relativeOffset，必须显式给绝对时间
            r.addAlarm(EKAlarm(absoluteDate: due))
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M月d日 HH:mm"
            dueText = "（" + f.string(from: due) + " 到点提醒）"
        }
        do {
            try store.save(r, commit: true)
        } catch {
            NSLog("[QLACTION] save reminder failed: \(error)")
            return .failed("写入提醒事项失败：\(error.localizedDescription)")
        }
        // 撤销 = 删掉刚建的那条（提醒事项同样没有回滚，只能反向删）
        return .done(message: "已新建提醒「\(title)」\(dueText)",
                      undo: { try? store.remove(r, commit: true) })
    }

    /// 快照类型：`fetchReminders` 的回调在任意线程跑，而 EKReminder 不是 Sendable ——
    /// 在回调里就地把要用的字段取成值类型再 resume，绝不把 EKReminder 递过隔离域。
    private struct ReminderSnapshot: Sendable {
        let identifier: String
        let title: String
        let due: Date?
    }

    private static func listReminders(_ action: AgentAction) async -> Outcome {
        guard AppPermissionKit.foregroundActive else { return .failed("App 在后台，先回到轻聊再看") }
        let days = max(1, min(Int(action.param("days") ?? "") ?? 7, 60))
        let store = EKEventStore()
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else {
            return .failed("时间范围算不出来")
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: start,
                                                             ending: end, calendars: nil)
        // fetchReminders 只有回调式 API（没有同步/async 版本），这里桥回 async。
        // 顺带把「没设到点时间的待办」也收进来：用户问"我有什么待办"时，无时间的也算。
        //
        // 🚨 闭包字面量必须显式写 `@Sendable`（2026-09-27 v3.9.97 真机 4 次 Signal(5) 定案）：
        //    EventKit 的 completion 参数**不是** @Sendable，而本类型是 `@MainActor enum AgentActionExecutor`
        //    → 字面量默认**继承 MainActor 隔离** → EventKit 在自己的后台队列回调它时做隔离检查 → SIGTRAP。
        //    符号化后的崩溃帧正是这里的 `closure #1 ([EKReminder]?) -> ()`（dSYM 零歧义）。
        //    `-parse`、CI archive、编译器告警**全程沉默**，只有真机崩；加 `@Sendable` 是唯一改法，
        //    别去掉这个属性、也别只把「捕获的对象」做成 Sendable（继承隔离的是字面量本身）。
        let rows: [ReminderSnapshot] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { @Sendable list in
                let snaps = (list ?? []).map { r in
                    ReminderSnapshot(identifier: r.calendarItemIdentifier,
                                     title: r.title ?? "无标题",
                                     due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) })
                }
                cont.resume(returning: snaps)
            }
        }
        guard !rows.isEmpty else { return .doneNoUndo(message: "未来 \(days) 天没有待办提醒") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        let sorted = rows.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        // 每条都带 id：删除动作只能从这里拿到 identifier（AI 没法凭空知道）
        let lines = sorted.prefix(15).map { s -> String in
            let when = s.due.map { f.string(from: $0) } ?? "（无时间）"
            return "\(when) \(s.title)｜id=\(s.identifier)"
        }
        let tail = rows.count > 15 ? "\n…等共 \(rows.count) 条" : ""
        return .doneNoUndo(message: "未来 \(days) 天 \(rows.count) 条待办：\n" + lines.joined(separator: "\n") + tail)
    }

    private static func deleteReminder(_ action: AgentAction) async -> Outcome {
        // mutationGuard 返回 nil = 放行；非 nil = 拒绝原因（直接给用户看）
        if let reason = await AppPermissionKit.mutationGuard(.reminders) {
            return .failed(reason)
        }
        guard let ident = action.param("identifier") ?? action.param("id") else {
            return .failed("没给要删的提醒 ID（先用「查看提醒事项」拿到）")
        }
        guard AppPermissionKit.foregroundActive else { return .failed("App 在后台，先回到轻聊再删") }
        let store = EKEventStore()
        guard let item = store.calendarItem(withIdentifier: ident) as? EKReminder else {
            return .failed("找不到这条提醒（可能已被删或 ID 过期）")
        }
        let title = item.title ?? "无标题"
        let keep = item.copy() as! EKReminder    // 删前留一份用于撤销
        do {
            try store.remove(item, commit: true)
        } catch {
            NSLog("[QLACTION] delete reminder failed: \(error)")
            return .failed("删除失败：\(error.localizedDescription)")
        }
        return .done(message: "已删除提醒「\(title)」",
                      undo: { try? store.save(keep, commit: true) })
    }

    // MARK: - 通讯录

    private static func contactKeys() -> [CNKeyDescriptor] {
        [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
         CNContactPhoneNumbersKey as CNKeyDescriptor,
         CNContactEmailAddressesKey as CNKeyDescriptor]
    }

    private static func searchContacts(_ action: AgentAction) async -> Outcome {
        let q = (action.param("query") ?? action.param("name") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let store = CNContactStore()
        // 空 query = 列前 20 个（用户问"我通讯录里都谁"时）。CNContact 不支持 SQL like，
        // 命中靠 predicate；predicateForContacts(matchingName:) 是前缀/包含匹配，够用。
        let predicate: NSPredicate = q.isEmpty
            ? CNContact.predicateForContactsInContainer(withIdentifier: store.defaultContainerIdentifier())
            : CNContact.predicateForContacts(matchingName: q)
        let found: [CNContact]
        do {
            found = try store.unifiedContacts(matching: predicate, keysToFetch: contactKeys())
        } catch {
            NSLog("[QLACTION] search contacts failed: \(error)")
            return .failed("读通讯录失败：\(error.localizedDescription)")
        }
        guard !found.isEmpty else {
            return .doneNoUndo(message: q.isEmpty ? "通讯录里没有联系人" : "没找到匹配「\(q)」的联系人")
        }
        let lines = found.prefix(20).map { c -> String in
            let name = CNContactFormatter.string(from: c, style: .fullName) ?? "（无姓名）"
            let tel = c.phoneNumbers.first.map { $0.value.stringValue } ?? ""
            let mail = c.emailAddresses.first.map { $0.value as String } ?? ""
            return [name, tel, mail].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let tail = found.count > 20 ? "\n…等共 \(found.count) 个" : ""
        return .doneNoUndo(message: "找到 \(found.count) 个联系人：\n" + lines.joined(separator: "\n") + tail)
    }

    private static func createContact(_ action: AgentAction) async -> Outcome {
        // mutationGuard 返回 nil = 放行；非 nil = 拒绝原因（直接给用户看）
        if let reason = await AppPermissionKit.mutationGuard(.contacts) {
            return .failed(reason)
        }
        guard let name = action.param("name") ?? action.param("fullName") else {
            return .failed("没给联系人姓名")
        }
        let store = CNContactStore()
        let contact = CNMutableContact()
        // 中文姓名一般不拆姓/名 → 整串放 familyName（姓名字段分开传时会各自成段，读出来照样拼接）
        if let family = action.param("familyName"), let given = action.param("givenName") {
            contact.familyName = family
            contact.givenName = given
        } else {
            contact.familyName = name
        }
        if let phone = action.param("phone") ?? action.param("tel"), !phone.isEmpty {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile,
                                                   value: CNPhoneNumber(stringValue: phone))]
        }
        if let mail = action.param("email"), !mail.isEmpty {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: mail as NSString)]
        }
        let req = CNSaveRequest()
        req.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(req)
        } catch {
            NSLog("[QLACTION] create contact failed: \(error)")
            return .failed("写入通讯录失败：\(error.localizedDescription)")
        }
        let ident = contact.identifier
        // 撤销 = 删掉刚建的那个（按 identifier 重新取一遍，不能复用已提交的 CNMutableContact）
        return .done(message: "已新建联系人「\(name)」", undo: {
            let s2 = CNContactStore()
            guard let got = try? s2.unifiedContact(withIdentifier: ident, keysToFetch: contactKeys()),
                  let m = got.mutableCopy() as? CNMutableContact else { return }
            let r2 = CNSaveRequest()
            r2.delete(m)
            try? s2.execute(r2)
        })
    }

    // MARK: - 定位（只读）

    private static func currentLocation() async -> Outcome {
        let fix = await OneShotLocationFetcher().fetch()
        guard let fix else {
            return .failed("拿不到位置（可能是没授权定位，或系统一时给不出定位）")
        }
        let lat = String(format: "%.5f", fix.latitude)
        let lon = String(format: "%.5f", fix.longitude)
        var place = ""
        if let marks = try? await CLGeocoder().reverseGeocodeLocation(fix.location), let p = marks.first {
            place = [p.name, p.locality, p.administrativeArea, p.country]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        let acc = Int(max(0, fix.accuracy))
        let msg = place.isEmpty
            ? "当前位置：\(lat), \(lon)（精度约 \(acc) 米）"
            : "当前位置：\(place)（\(lat), \(lon)，精度约 \(acc) 米）"
        return .doneNoUndo(message: msg)
    }

    // MARK: - 剪贴板

    private static func readClipboard() async -> Outcome {
        // 读剪贴板会弹 iOS 的「轻聊 粘贴自 …」系统提示 —— 这是系统行为，App 关不掉；
        // 只在用户真的要求读时才走到这（协议侧也规定 AI 不许无事乱读）。
        let text = UIPasteboard.general.string ?? ""
        guard !text.isEmpty else { return .doneNoUndo(message: "剪贴板是空的（或里面不是文字）") }
        let clipped = text.count > 2000 ? String(text.prefix(2000)) + "\n…（太长，已截断）" : text
        return .doneNoUndo(message: "剪贴板里是：\n\(clipped)")
    }

    private static func writeClipboard(_ action: AgentAction) async -> Outcome {
        // mutationGuard 返回 nil = 放行；非 nil = 拒绝原因（直接给用户看）
        if let reason = await AppPermissionKit.mutationGuard(.clipboard) {
            return .failed(reason)
        }
        guard let text = action.param("text") ?? action.param("content") else {
            return .failed("没给要复制的内容")
        }
        UIPasteboard.general.string = text
        return .doneNoUndo(message: "已复制到剪贴板（\(text.count) 字）")
    }

    // MARK: - 文件（轻聊自己的沙盒目录，不是任意路径）

    private static func listFiles(_ action: AgentAction) async -> Outcome {
        let fm = FileManager.default
        guard let dir = SandboxFiles.resolve(action.param("path")) else {
            return .failed("路径不合法（只能读写轻聊自己的目录，不许 .. 或绝对路径）")
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir) else {
            return .failed("这个路径不存在：\(SandboxFiles.display(dir))")
        }
        guard isDir.boolValue else { return await readFile(action) }   // 给的是文件 → 直接读
        let items: [URL]
        do {
            items = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys:
                [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch {
            NSLog("[QLACTION] list files failed: \(error)")
            return .failed("列目录失败：\(error.localizedDescription)")
        }
        guard !items.isEmpty else {
            return .doneNoUndo(message: "「\(SandboxFiles.display(dir))」是空的")
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        let lines = items.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(50).map { u -> String in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            let isDirNow = v?.isDirectory ?? false
            let size = isDirNow ? "目录" : SandboxFiles.humanSize(v?.fileSize ?? 0)
            let date = v?.contentModificationDate.map { f.string(from: $0) } ?? ""
            return "\(u.lastPathComponent)  [\(size)] \(date)"
        }
        let tail = items.count > 50 ? "\n…共 \(items.count) 项" : ""
        return .doneNoUndo(message: "「\(SandboxFiles.display(dir))」下 \(items.count) 项：\n"
                           + lines.joined(separator: "\n") + tail)
    }

    private static func readFile(_ action: AgentAction) async -> Outcome {
        guard let url = SandboxFiles.resolve(action.param("path") ?? action.param("file")) else {
            return .failed("路径不合法（只能读写轻聊自己的目录，不许 .. 或绝对路径）")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failed("文件不存在：\(SandboxFiles.display(url))")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            NSLog("[QLACTION] read file failed: \(error)")
            return .failed("读文件失败：\(error.localizedDescription)")
        }
        // 上限 200KB：再大就不该塞进聊天流（JSON 卡片/气泡都会卡）
        guard data.count <= 200 * 1024 else {
            return .failed("文件太大（\(SandboxFiles.humanSize(data.count))），超过 200KB 不读")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failed("这不是文本文件（UTF-8 解不开，\(SandboxFiles.humanSize(data.count))）")
        }
        let body = text.count > 4000 ? String(text.prefix(4000)) + "\n…（太长，已截断）" : text
        return .doneNoUndo(message: "「\(SandboxFiles.display(url))」内容：\n\(body)")
    }

    private static func writeFile(_ action: AgentAction) async -> Outcome {
        // mutationGuard 返回 nil = 放行；非 nil = 拒绝原因（直接给用户看）
        if let reason = await AppPermissionKit.mutationGuard(.files) {
            return .failed(reason)
        }
        guard let raw = action.param("path") ?? action.param("file") else {
            return .failed("没给文件名")
        }
        guard let url = SandboxFiles.resolve(raw) else {
            return .failed("路径不合法（只能读写轻聊自己的目录，不许 .. 或绝对路径）")
        }
        guard let content = action.param("content") ?? action.param("text") else {
            return .failed("没给要写的内容")
        }
        let data = Data(content.utf8)
        guard data.count <= 1024 * 1024 else {
            return .failed("内容太大（\(SandboxFiles.humanSize(data.count))），超过 1MB 不写")
        }
        let append = (action.param("append") ?? "").lowercased() == "true"
        let existedBefore = FileManager.default.fileExists(atPath: url.path)
        let old: Data? = existedBefore ? try? Data(contentsOf: url) : nil
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if append, existedBefore, let old {
                let h = try FileHandle(forWritingTo: url)
                try h.seekToEnd()
                try h.write(contentsOf: data)
                try h.close()
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            NSLog("[QLACTION] write file failed: \(error)")
            return .failed("写文件失败：\(error.localizedDescription)")
        }
        let op = append && existedBefore ? "追加" : "写入"
        let undo: (() async -> Void)? = existedBefore
            ? { if let old { try? old.write(to: url, options: .atomic) } }
            : { try? fm.removeItem(at: url) }      // 之前不存在 → 撤销 = 删掉
        return .done(message: "已\(op)「\(SandboxFiles.display(url))」（\(SandboxFiles.humanSize(data.count))）",
                      undo: undo)
    }
}

// MARK: - 沙盒路径解析

/// 轻聊的文件区：App 自己的 Documents 目录（project.yml 里开了 UIFileSharingEnabled，
/// 所以用户在「文件」App → 我的 iPhone → 轻聊 里也能看到、能自己放文件进去）。
///
/// 🚨 安全口径：**只允许相对路径**，且标准化后必须仍落在 Documents 内。
///    这是 AI 给路径的地方 —— `../../` 或绝对路径一律拒（否则等于把整个 App 容器
///    甚至系统目录暴露给模型）。符号链接也要挡：standardizedFileURL 之后再比前缀。
enum SandboxFiles {

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 解析用户/AI 给的路径。nil 或空 = 根目录。返回 nil = 路径非法（调用方必须报错，不能兜底成根）。
    static func resolve(_ raw: String?) -> URL? {
        let name = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "/" || name == "." { return root }
        // 绝对路径 / 上跳 / 隐藏的系统起点一律拒绝
        if name.hasPrefix("/") || name.hasPrefix("~") { return nil }
        if name.split(separator: "/").contains("..") { return nil }
        let url = root.appendingPathComponent(name)
        // 二次校验：标准化 + 解符号链接后仍须在 root 之下
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path == base || path.hasPrefix(base + "/") else { return nil }
        return url
    }

    /// 给用户看的路径（不带主机绝对路径，只说相对位置）
    static func display(_ url: URL) -> String {
        let base = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(base) else { return url.lastPathComponent }
        let rel = String(p.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rel.isEmpty ? "轻聊（根目录）" : rel
    }

    static func humanSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}

// MARK: - 一次性定位

/// 取一次当前坐标（`requestLocation()` 是 one-shot API，比开 startUpdatingLocation 省电，
/// 也不会留下常驻定位）。
///
/// 并发口径：`CLLocationManagerDelegate` 的回调是 `nonisolated`，而 `[CLLocation]` 不是
/// Sendable —— 所以回调里**只把 Double 标量**带过隔离域，CLLocation 在 MainActor 上再构造。
/// （直接捕获 manager 或 locs 会撞 Swift 6 的 sending 规则。）
/// 定位结果（值类型 + Sendable）。刻意不直接返回 CLLocation：
/// CLLocation 不是 Sendable，而且 `CLLocation(latitude:longitude:)` 造出来的实例
/// `horizontalAccuracy` 恒为 -1（读它会显示"精度约 0 米"），所以精度单独带着走。
struct LocationFix: Sendable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

@MainActor
final class OneShotLocationFetcher: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private var cont: CheckedContinuation<LocationFix?, Never>?
    private var finished = false

    func fetch() async -> LocationFix? {
        guard LocationPermission.state(of: manager.authorizationStatus) == .granted else { return nil }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        return await withCheckedContinuation { c in
            cont = c
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        let lat = l.coordinate.latitude
        let lon = l.coordinate.longitude
        let acc = l.horizontalAccuracy
        Task { @MainActor in self.finish(lat: lat, lon: lon, acc: acc) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(lat: nil, lon: nil, acc: 0) }
    }

    private func finish(lat: Double?, lon: Double?, acc: Double) {
        guard !finished else { return }
        finished = true
        let fix: LocationFix? = {
            guard let lat, let lon else { return nil }
            return LocationFix(latitude: lat, longitude: lon, accuracy: acc)
        }()
        cont?.resume(returning: fix)
        cont = nil
    }
}
