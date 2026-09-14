import AppIntents
import Foundation

/// 条件自动化规则（v3.9.21）：后端 rules_engine 的客户端模型与事件入口。
///
/// 分工：**规则定义在后端**（`/api/automations/rules`），App 只做三件事 —— 列出规则、开关、删除；
/// 以及把**系统事件**（到达某地、开始充电、连上车载蓝牙…）上报给后端引擎求值。
/// 规则本体（条件 DSL、边沿触发、冷却、干跑）全在服务端，App 不重复实现一遍逻辑。

// MARK: - 列表模型

struct RuleItem: Identifiable, Equatable {
    let id: String
    let name: String
    let enabled: Bool
    let runCount: Int
    let lastRun: Date?
    let summary: String

    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? UUID().uuidString
        name = d["name"] as? String ?? "规则"
        enabled = (d["enabled"] as? Bool) ?? true
        runCount = (d["run_count"] as? Int) ?? 0
        let lr = (d["last_run"] as? Double) ?? 0
        lastRun = lr > 0 ? Date(timeIntervalSince1970: lr) : nil
        summary = RuleItem.summarize(d["trigger"] as? [String: Any] ?? [:])
    }

    /// 把 trigger 翻成人话，例如「周12345 23:30-23:59 · 客厅灯=on」
    static func summarize(_ trig: [String: Any]) -> String {
        var parts: [String] = []
        if let alls = trig["all"] as? [[String: Any]] {
            parts.append(contentsOf: alls.map(describe))
        }
        if let anys = trig["any"] as? [[String: Any]], !anys.isEmpty {
            let s = anys.map(describe).joined(separator: " 或 ")
            parts.append(anys.count > 1 ? "(\(s))" : s)
        }
        return parts.isEmpty ? "(无条件)" : parts.joined(separator: " · ")
    }

    private static func describe(_ c: [String: Any]) -> String {
        switch (c["type"] as? String) ?? "" {
        case "always":
            return "恒真"
        case "time":
            var s = "每天"
            if let wd = c["weekdays"] as? [Int], !wd.isEmpty {
                s = "周" + wd.map { String($0 + 1) }.joined()
            }
            let a = (c["after"] as? String) ?? "?"
            let b = (c["before"] as? String) ?? "?"
            return "\(s) \(a)-\(b)"
        case "state":
            let e = shortEntity((c["entity"] as? String) ?? "?")
            if let b = c["below"] { return "\(e)<\(b)" }
            if let a = c["above"] { return "\(e)>\(a)" }
            if let r = c["between"] as? [Any], r.count == 2 { return "\(e)在\(r[0])~\(r[1])" }
            if let ins = c["in"] as? [Any] { return "\(e)∈" + ins.map { "\($0)" }.joined(separator: "/") }
            return "\(e)=\(c["equals"] ?? "?")"
        case "event":
            let m = (c["match"] as? [String: Any]) ?? [:]
            let extra = m.isEmpty ? "" : "(" + m.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",") + ")"
            return "事件 \(c["event"] ?? "?")\(extra)"
        case "device":
            return "设备 \(c["prop"] ?? "?")=\(c["equals"] ?? "?")"
        default:
            return "条件"
        }
    }

    /// 实体 id 太长，只取末尾有意义的一段
    private static func shortEntity(_ id: String) -> String {
        let tail = id.split(separator: ".").last.map(String.init) ?? id
        return tail.count > 14 ? String(tail.suffix(14)) : tail
    }
}

// MARK: - 事件上报（AppIntent / App 内都能用）

enum RuleEventClient {
    /// 轻客户端：**AppIntent 在 App 未运行时也必须能上报**。
    ///
    /// 为什么不用注入进来的 `AuthStore`：AppIntent 由系统在独立场景里执行，拿不到 App 的
    /// `@Environment` 实例；而"到达某地"这类事件若延迟到下次打开 App 才上报，规则就失去意义。
    /// 所以这里自己读 UserDefaults 的服务器地址 + Keychain 的 token（与 AuthStore 同源、不新造存储）。
    @discardableResult
    static func report(event: String, extra: [String: Any] = [:]) async -> Bool {
        guard !event.isEmpty else { return false }
        let server = UserDefaults.standard.string(forKey: "qingliao_server") ?? ""
        guard !server.isEmpty, let url = URL(string: server + "/api/automations/event") else {
            print("[RuleEventClient] 未配置服务器地址")
            return false
        }
        let token = await MainActor.run { AuthStore.keychainReadToken() ?? "" }
        var body = extra
        body["event"] = event
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Auth-Token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                print("[RuleEventClient] 上报失败 HTTP \(code)")
                return false
            }
            let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (j?["ok"] as? Bool) ?? false
        } catch {
            print("[RuleEventClient] 上报异常 \(error)")
            return false
        }
    }
}

// MARK: - 快捷指令入口

/// 「发送事件给轻聊」——快捷指令里选这个动作，把系统事件交给轻聊的自动规则。
///
/// 为什么走快捷指令而不是 App 内常驻监听：iOS **不允许**后台 App 监听 WiFi SSID 与充电状态，
/// App 内地理围栏要 always 定位权限且冷启动唤醒不可靠；而快捷指令的触发器（到达/离开某地、
/// 开始/停止充电、连接车载蓝牙…）是**系统级、零权限、不耗电**的，是"设备侧条件"唯一可靠来源。
struct ReportEventIntent: AppIntent {

    static var title: LocalizedStringResource { "发送事件给轻聊" }

    // ⚠️ 与 LiveActivityActions.swift 同因：Swift 6 下 `static var description = …`（非计算属性）
    // 会报 static property 非并发安全，CI Archive 直接失败——必须写成计算属性。
    static var description: IntentDescription {
        IntentDescription("把系统事件（到达某地、开始充电、连上车载蓝牙…）交给轻聊的自动规则")
    }

    @Parameter(title: "事件名", description: "如 geofence.enter / geofence.exit / device.charging")
    var event: String

    @Parameter(title: "附加键值", description: "可选，形如 place=home，多个用空格分隔", default: "")
    var extra: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        var body: [String: Any] = [:]
        for kv in extra.split(separator: " ") {
            let p = kv.split(separator: "=", maxSplits: 1)
            if p.count == 2 { body[String(p[0])] = String(p[1]) }
        }
        let ok = await RuleEventClient.report(event: event, extra: body)
        return .result(dialog: ok ? "已交给轻聊自动规则" : "上报失败：检查轻聊是否已登录、网络是否可达")
    }
}
