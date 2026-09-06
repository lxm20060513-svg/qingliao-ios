import Foundation
import UIKit
import EventKit
import UserNotifications

// MARK: - v3.0.18 云端模式本地工具集（function calling）
// 模型返回 tool_calls → LocalToolRunner 执行手机本地工具 → 结果回传模型继续对话。
// 与 NAS 后端无关（纯 App 内闭环），所有工具运行在主线程（EventKit/UIPasteboard 主线程安全）。

/// 解析后的工具调用（非流式响应 / 流式合并后的完整形态）
struct ParsedToolCall {
    var id: String
    var name: String
    var arguments: String      // JSON 字符串（对象）
}

/// 工具执行结果
struct ToolResult {
    var success: Bool
    var summary: String        // 展示用简短文本（工具卡片）
    var detail: String = ""    // 回传给模型的完整 JSON 文本（已是 JSON 字符串）
}

/// 工具定义（OpenAI function schema）
struct LocalToolDef {
    let name: String
    let description: String
    let parameters: [String: Any]
    let needsConfirm: Bool     // true = 写操作，执行前弹确认框
    let run: ([String: Any]) -> ToolResult
}

/// 本地工具集：注册表 + 执行
/// v3.0.18：@MainActor——工具都涉及 UIKit/EventKit/UserNotifications，须主线程
/// v3.0.19：control_ha/control_docker 需要后端 API → 经注入的 AuthStore 发请求（App 启动/登录后注入）
@MainActor
enum LocalToolRunner {
    /// v3.0.19：后端 API 访问器（HA/Docker 工具用）。App 启动时注入（QingliaoApp 或 RootView）
    static weak var authStore: AuthStore?

    /// 所有工具定义（OpenAI tools 数组格式；改为 var 以支持动态注册/插件追加）
    static var allDefs: [LocalToolDef] = [
        createReminderDef,
        createCalendarEventDef,
        startTimerDef,
        getWeatherDef,
        setClipboardDef,
        calculateDef,
        sendNotificationDef,
        controlHADef,
        controlDockerDef,
        // v3.0.98: NAS 桥接工具（经 /api/agent/tool 调 NAS 后端执行）
        webExtractDef,
        patchFileDef,
        todoDef,
        imageGenerateDef,
        textToSpeechDef,
        terminalDef,
        processDef,
        cronjobDef,
        videoGenerateDef,
        videoAnalyzeDef,
    ]

    /// OpenAI 协议 tools 数组（传给 /chat/completions）
    static var openAITools: [[String: Any]] {
        allDefs.map { def in
            [
                "type": "function",
                "function": [
                    "name": def.name,
                    "description": def.description,
                    "parameters": def.parameters,
                ],
            ]
        }
    }

    /// 按名字执行工具（找不到 → 失败结果）
    static func run(name: String, argumentsJSON: String) -> ToolResult {
        guard let def = allDefs.first(where: { $0.name == name }) else {
            return ToolResult(success: false, summary: "未知工具：\(name)", detail: #"{"error": "unknown tool"}"#)
        }
        // 解析 arguments JSON（容错：空串/非法 → 空字典）
        var args: [String: Any] = [:]
        if !argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let data = argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = obj
        }
        return def.run(args)
    }

    /// v3.0.18：异步执行入口——EventKit/通知类工具先请求系统权限再执行；天气走异步网络（避免主线程阻塞）
    static func execute(name: String, argumentsJSON: String) async -> ToolResult {
        // 天气：异步网络请求（不用 run 闭包里的 DispatchSemaphore——@MainActor 下会卡死主线程）
        if name == "get_weather" {
            var args: [String: Any] = [:]
            if let data = argumentsJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                args = obj
            }
            let city = (args["city"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return await fetchWeatherAsync(city: city)
        }
        // v3.0.19：HA/Docker 控制——经 AuthStore 调后端 API（async 网络）
        if name == "control_ha" || name == "control_docker" {
            var args: [String: Any] = [:]
            if let data = argumentsJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                args = obj
            }
            if name == "control_ha" {
                return await executeHA(args)
            }
            return await executeDocker(args)
        }
        // 权限预检（iOS 17+ API；部署目标 26 无兼容问题）
        switch name {
        case "create_calendar_event":
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let store = EKEventStore()
                store.requestFullAccessToEvents { ok, _ in cont.resume(returning: ok) }
            }
            guard granted else {
                return ToolResult(success: false, summary: "日历权限被拒绝（设置 → 隐私 → 日历 开启）",
                                  detail: #"{"error": "calendar permission denied"}"#)
            }
        case "create_reminder":
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let store = EKEventStore()
                store.requestFullAccessToReminders { ok, _ in cont.resume(returning: ok) }
            }
            guard granted else {
                return ToolResult(success: false, summary: "提醒权限被拒绝（设置 → 隐私 → 提醒事项 开启）",
                                  detail: #"{"error": "reminder permission denied"}"#)
            }
        case "start_timer", "send_notification":
            // v3.0.18 review fix #4：通知权限预检——denied 直接返回失败，不静默丢通知
            let center = UNUserNotificationCenter.current()
            let status = await withCheckedContinuation { (cont: CheckedContinuation<UNAuthorizationStatus, Never>) in
                center.getNotificationSettings { settings in
                    cont.resume(returning: settings.authorizationStatus)
                }
            }
            guard status == .authorized || status == .provisional else {
                return ToolResult(success: false, summary: "通知权限被拒绝（设置 → 轻聊 → 通知 开启）",
                                  detail: #"{"error": "notification permission denied"}"#)
            }
        default:
            // v3.0.98: NAS 桥接工具——非本地工具走后端 /api/agent/tool
            let nasBridgeTools: Set<String> = [
                "web_extract", "patch_file", "todo", "image_generate", "text_to_speech",
                "terminal", "process", "cronjob", "video_generate", "video_analyze"
            ]
            if nasBridgeTools.contains(name) {
                return await executeNASTool(name: name, argumentsJSON: argumentsJSON)
            }
            break
        }
        return run(name: name, argumentsJSON: argumentsJSON)
    }

    /// v3.0.18：天气异步查询（async/await 版，替代 run 闭包里的同步 semaphore）
    static func fetchWeatherAsync(city: String) async -> ToolResult {
        var lat = 22.54, lon = 114.06, cityName = "深圳"
        if !city.isEmpty {
            // geocoding 拿经纬度
            let enc = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            guard let gurl = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(enc)&count=1&language=zh&format=json") else {
                return ToolResult(success: false, summary: "天气服务地址无效", detail: #"{"error": "bad url"}"#)
            }
            do {
                let (gdata, _) = try await URLSession.shared.data(from: gurl)
                if let obj = try? JSONSerialization.jsonObject(with: gdata) as? [String: Any],
                   let results = obj["results"] as? [[String: Any]],
                   let first = results.first,
                   let glat = first["latitude"] as? Double,
                   let glon = first["longitude"] as? Double {
                    lat = glat
                    lon = glon
                    cityName = first["name"] as? String ?? city
                } else {
                    return ToolResult(success: false, summary: "未找到城市「\(city)」", detail: #"{"error": "city not found"}"#)
                }
            } catch {
                return ToolResult(success: false, summary: "天气查询失败", detail: #"{"error": "geocoding network"}"#)
            }
        }
        let fstr = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min,weather_code&timezone=Asia%2FShanghai&forecast_days=1"
        guard let furl = URL(string: fstr) else {
            return ToolResult(success: false, summary: "天气服务地址无效", detail: #"{"error": "bad url"}"#)
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: furl)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cur = obj["current"] as? [String: Any],
                  let temp = cur["temperature_2m"] as? Double else {
                return ToolResult(success: false, summary: "天气解析失败", detail: #"{"error": "parse"}"#)
            }
            let code = cur["weather_code"] as? Int ?? 0
            let daily = obj["daily"] as? [String: Any]
            let maxT = (daily?["temperature_2m_max"] as? [Double])?.first
            let minT = (daily?["temperature_2m_min"] as? [Double])?.first
            var parts = ["当前 \(Int(temp))°C", weatherText(code)]
            if let maxT, let minT {
                parts.append("今日 \(Int(minT))°~\(Int(maxT))°")
            }
            return ToolResult(success: true,
                              summary: "\(cityName)天气：\(parts.joined(separator: " · "))",
                              detail: #"{"ok": true, "temp": \#(temp), "code": \#(code)}"#)
        } catch {
            return ToolResult(success: false, summary: "天气查询失败", detail: #"{"error": "network"}"#)
        }
    }

    static func needsConfirm(name: String) -> Bool {
        allDefs.first(where: { $0.name == name })?.needsConfirm ?? false
    }

    // MARK: - 工具实现

    // v3.0.x fix：缓存 Date/ISO8601 Formatter（避免每次工具调用重复创建 → 主线程卡顿）
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        // v3.2.x review fix：ISO8601DateFormatter 默认 timeZone = GMT——而 schema 注释声明
        // start/end/due 为「本地时间，无时区」（如 2026-08-21T15:00:00），按 GMT 解释会整体偏移
        // N 小时（东八区 = 晚 8 小时）。显式 .current，与 parseFlexibleDate(flexibleDateFmt) 的
        // timeZone = .current 保持一致。
        f.timeZone = .current
        return f
    }()
    private static let displayDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    /// 📅 日历建事件
    static let createCalendarEventDef = LocalToolDef(
        name: "create_calendar_event",
        description: "在系统日历中创建一条日程事件。用户说「X号X点做某事」且明确是日程时使用。返回创建结果。",
        parameters: [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "事件标题，如：开会"],
                "start": ["type": "string", "description": "开始时间，格式如 2026-08-21T15:00:00 或 2026-08-21 15:00（本地时间，无时区）"],
                "end": ["type": "string", "description": "结束时间，格式同上；可省略默认 1 小时"],
                "notes": ["type": "string", "description": "备注，可选"],
            ],
            "required": ["title", "start"],
        ],
        needsConfirm: true,
        run: { args in
            guard let title = args["title"] as? String, !title.isEmpty,
                  let startStr = args["start"] as? String,
                  let start = Self.iso8601.date(from: startStr) ?? Self.parseFlexibleDate(startStr) else {
                return ToolResult(success: false, summary: "日历事件缺少标题或时间",
                                  detail: #"{"error": "missing title or start"}"#)
            }
            let store = EKEventStore()
            let end: Date
            if let endStr = args["end"] as? String,
               let e = Self.iso8601.date(from: endStr) ?? Self.parseFlexibleDate(endStr) {
                end = e
            } else {
                end = start.addingTimeInterval(3600)
            }
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = end
            event.calendar = store.defaultCalendarForNewEvents
            if let notes = args["notes"] as? String, !notes.isEmpty { event.notes = notes }
            do {
                try store.save(event, span: .thisEvent)
                return ToolResult(success: true,
                                  summary: "已创建日程：\(title)（\(Self.displayDateFmt.string(from: start))）",
                                  detail: #"{"ok": true, "title": "\#(title)", "start": "\#(startStr)"}"#)
            } catch {
                return ToolResult(success: false, summary: "日历创建失败：\(error.localizedDescription)",
                                  detail: #"{"error": "\#(error.localizedDescription)"}"#)
            }
        }
    )

    /// ⏰ 提醒
    static let createReminderDef = LocalToolDef(
        name: "create_reminder",
        description: "创建一条提醒事项（系统提醒，到时间通知）。用户说「提醒我X点做某事」时使用。",
        parameters: [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "提醒内容，如：开会"],
                "due": ["type": "string", "description": "提醒时间，格式如 2026-08-21T15:00:00 或 2026-08-21 15:00（本地时间，无时区）"],
                "minutes": ["type": "integer", "description": "相对当前时间的分钟数（如 10 = 10分钟后）；与 due 二选一"],
            ],
            "required": ["title"],
        ],
        needsConfirm: true,
        run: { args in
            guard let title = args["title"] as? String, !title.isEmpty else {
                return ToolResult(success: false, summary: "提醒缺少内容",
                                  detail: #"{"error": "missing title"}"#)
            }
            var due: Date?
            if let dueStr = args["due"] as? String {
                due = Self.iso8601.date(from: dueStr) ?? Self.parseFlexibleDate(dueStr)
            } else if let mins = args["minutes"] as? Int {
                due = Date().addingTimeInterval(TimeInterval(mins * 60))
            }
            let store = EKEventStore()
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = store.defaultCalendarForNewReminders()
            if let due {
                let alarm = EKAlarm(absoluteDate: due)
                reminder.addAlarm(alarm)
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: due)
            }
            do {
                try store.save(reminder, commit: true)
                let whenText = due.map { Self.displayDateFmt.string(from: $0) } ?? "尽快"
                return ToolResult(success: true,
                                  summary: "已创建提醒：\(title)（\(whenText)）",
                                  detail: #"{"ok": true, "title": "\#(title)", "due": "\#(due?.timeIntervalSince1970 ?? 0)}"#)
            } catch {
                return ToolResult(success: false, summary: "提醒创建失败：\(error.localizedDescription)",
                                  detail: #"{"error": "\#(error.localizedDescription)"}"#)
            }
        }
    )

    /// ⏱️ 计时器（本地通知）
    static let startTimerDef = LocalToolDef(
        name: "start_timer",
        description: "启动一个倒计时计时器，到时间发本地通知。用户说「X分钟后提醒我/计时X分钟」时使用。",
        parameters: [
            "type": "object",
            "properties": [
                "seconds": ["type": "integer", "description": "倒计时秒数（如 300 = 5分钟）"],
                "label": ["type": "string", "description": "计时器名称，可选，如：煮面"],
            ],
            "required": ["seconds"],
        ],
        needsConfirm: true,
        run: { args in
            guard let secs = args["seconds"] as? Int, secs > 0 else {
                return ToolResult(success: false, summary: "计时器需要有效秒数",
                                  detail: #"{"error": "invalid seconds"}"#)
            }
            let label = (args["label"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let content = UNMutableNotificationContent()
            content.title = "⏱️ 计时器"
            content.body = label.isEmpty ? "倒计时 \(secs) 秒结束" : "「\(label)」倒计时结束"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(secs), repeats: false)
            let req = UNNotificationRequest(identifier: "timer_\(Int(Date().timeIntervalSince1970))",
                                            content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(req)
            let minutes = secs / 60
            let secsLeft = secs % 60
            let whenText = minutes > 0 ? "\(minutes)分\(secsLeft)秒" : "\(secsLeft)秒"
            return ToolResult(success: true,
                              summary: "计时器已启动：\(label.isEmpty ? "\(whenText)倒计时" : label)（\(whenText)后通知）",
                              detail: #"{"ok": true, "seconds": \#(secs), "label": "\#(label)"}"#)
        }
    )

    /// 🌤️ 天气（异步实现见 fetchWeatherAsync；run 闭包仅占位——execute 拦截 get_weather 走异步）
    static let getWeatherDef = LocalToolDef(
        name: "get_weather",
        description: "查询天气（当前温度 + 今日天气）。用户问天气、冷不冷、要不要带伞时使用。城市可选：给中文城市名（如 北京、深圳）；省略默认深圳（用户所在城市）。",
        parameters: [
            "type": "object",
            "properties": [
                "city": ["type": "string", "description": "城市名（中文，如 北京、深圳）；省略则用定位城市"],
            ],
        ],
        needsConfirm: false,
        run: { _ in
            // 实际由 execute() 的 fetchWeatherAsync 分支处理（@MainActor 下同步网络会卡死）
            ToolResult(success: false, summary: "天气查询中…", detail: #"{"ok": false, "async": true}"#)
        }
    )

    /// 📋 剪贴板
    static let setClipboardDef = LocalToolDef(
        name: "set_clipboard",
        description: "把文本写入系统剪贴板。用户说「复制XX」「把XX复制下来」时使用。",
        parameters: [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "要复制的文本"],
            ],
            "required": ["text"],
        ],
        needsConfirm: false,
        run: { args in
            guard let text = args["text"] as? String else {
                return ToolResult(success: false, summary: "剪贴板内容为空",
                                  detail: #"{"error": "empty text"}"#)
            }
            UIPasteboard.general.string = text
            let preview = text.count > 20 ? String(text.prefix(20)) + "…" : text
            return ToolResult(success: true,
                              summary: "已复制：\(preview)",
                              detail: #"{"ok": true, "chars": \#(text.count)}"#)
        }
    )

    /// 🧮 计算器（安全求值：仅数字/四则/括号/小数点，防注入）
    static let calculateDef = LocalToolDef(
        name: "calculate",
        description: "执行数学计算（四则运算、括号、小数、百分比）。用户问算术、换算、折扣时使用。",
        parameters: [
            "type": "object",
            "properties": [
                "expression": ["type": "string", "description": "数学表达式，如 (120*0.85)+10"],
            ],
            "required": ["expression"],
        ],
        needsConfirm: false,
        run: { args in
            guard let expr = args["expression"] as? String else {
                return ToolResult(success: false, summary: "缺少表达式", detail: #"{"error": "missing expression"}"#)
            }
            let cleaned = expr.replacingOccurrences(of: "×", with: "*")
                .replacingOccurrences(of: "÷", with: "/")
                .replacingOccurrences(of: "＋", with: "+")
                .replacingOccurrences(of: "－", with: "-")
                .replacingOccurrences(of: " ", with: "")
            // 白名单字符检查（数字 0-9 . + - * / ( ) %）
            let allowed = CharacterSet(charactersIn: "0123456789.+-*/()%")
            guard cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                return ToolResult(success: false, summary: "表达式包含非法字符",
                                  detail: #"{"error": "invalid characters"}"#)
            }
            // 防 NSExpression 注入：长度限制 + 嵌套深度检查（防超长/深层表达式导致栈溢出）
            guard cleaned.count <= 200 else {
                return ToolResult(success: false, summary: "表达式过长",
                                  detail: #"{"error": "expression too long"}"#)
            }
            let depth = cleaned.reduce(0) { $0 + ($1 == "(" ? 1 : $1 == ")" ? -1 : 0) }
            guard depth >= 0, depth <= 20 else {
                return ToolResult(success: false, summary: "表达式括号嵌套过深",
                                  detail: #"{"error": "expression too deeply nested"}"#)
            }

            // v3.1.8 fix: 替换 NSExpression 为安全的递归下降解析器
            // NSExpression 内部可能有未公开格式化指令导致崩溃，纯数学解析器更安全
            func _parseCalc(_ expr: String) -> Double? {
                var pos = expr.startIndex
                func peek() -> Character? { pos < expr.endIndex ? expr[pos] : nil }
                func advance() { pos = expr.index(after: pos) }
                func skipSpaces() { while peek() == " " { advance() } }

                func parseNumber() -> Double? {
                    skipSpaces()
                    var numStr = ""
                    while let c = peek(), c.isNumber || c == "." {
                        numStr.append(c); advance()
                    }
                    return Double(numStr)
                }

                func parsePrimary() -> Double? {
                    skipSpaces()
                    if peek() == "(" {
                        advance() // skip (
                        guard let val = parseAddSub() else { return nil }
                        skipSpaces()
                        guard peek() == ")" else { return nil }
                        advance() // skip )
                        return val
                    }
                    if peek() == "-" {
                        advance()
                        guard let val = parsePrimary() else { return nil }
                        return -val
                    }
                    return parseNumber()
                }

                func parseMulDiv() -> Double? {
                    guard var left = parsePrimary() else { return nil }
                    while true {
                        skipSpaces()
                        if peek() == "*" {
                            advance()
                            guard let right = parsePrimary() else { return nil }
                            left *= right
                        } else if peek() == "/" {
                            advance()
                            guard let right = parsePrimary(), right != 0 else { return nil }
                            left /= right
                        } else if peek() == "%" {
                            advance()
                            guard let right = parsePrimary(), right != 0 else { return nil }
                            left = left.truncatingRemainder(dividingBy: right)
                        } else { break }
                    }
                    return left
                }

                func parseAddSub() -> Double? {
                    guard var left = parseMulDiv() else { return nil }
                    while true {
                        skipSpaces()
                        if peek() == "+" {
                            advance()
                            guard let right = parseMulDiv() else { return nil }
                            left += right
                        } else if peek() == "-" {
                            advance()
                            guard let right = parseMulDiv() else { return nil }
                            left -= right
                        } else { break }
                    }
                    return left
                }

                let result = parseAddSub()
                skipSpaces()
                guard pos == expr.endIndex else { return nil }
                return result
            }

            guard let v = _parseCalc(cleaned) else {
                return ToolResult(success: false, summary: "无法计算该表达式",
                                  detail: #"{"error": "cannot evaluate"}"#)
            }
            // v3.0.18：整数直接显示；小数保留 4 位去尾零（用 (?<!\\d) 防把整数的尾零删掉，如 100→"1"）
            let text: String
            if v == v.rounded() {
                text = String(Int(v))
            } else {
                let trimmed = String(format: "%.4f", v).replacingOccurrences(of: "(\\.\\d*?)0+$", with: "$1", options: .regularExpression)
                    .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
                text = trimmed
            }
            return ToolResult(success: true,
                              summary: "\(expr) = \(text)",
                              detail: #"{"ok": true, "expression": "\#(expr)", "result": "\#(v)"}"#)
        }
    )

    /// 🔔 本地通知（立即通知）
    static let sendNotificationDef = LocalToolDef(
        name: "send_notification",
        description: "立即发送一条本地通知（App 内弹通知）。用户说「通知我/提醒我」且无具体时间时使用。",
        parameters: [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "通知标题，可选"],
                "body": ["type": "string", "description": "通知内容"],
            ],
            "required": ["body"],
        ],
        needsConfirm: false,
        run: { args in
            guard let body = args["body"] as? String, !body.isEmpty else {
                return ToolResult(success: false, summary: "通知内容为空", detail: #"{"error": "empty body"}"#)
            }
            let title = (args["title"] as? String) ?? "轻聊"
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let req = UNNotificationRequest(identifier: "local_\(Int(Date().timeIntervalSince1970))",
                                            content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
            return ToolResult(success: true,
                              summary: "已发送通知：\(body)",
                              detail: #"{"ok": true, "body": "\#(body)"}"#)
        }
    )

    /// 🏠 HA 设备控制（灯/空调/开关等）——实际执行在 executeHA（async 走 AuthStore 后端 API）
    static let controlHADef = LocalToolDef(
        name: "control_ha",
        description: "控制智能家居设备（Home Assistant）。用户说「打开/关闭客厅灯」「空调调到26度」「打开空调制热」时使用。"
            + "action 支持 toggle（开关）/turn_on（开）/turn_off（关）/set_temperature（空调设温度）/set_hvac_mode（空调模式 cool/heat/dry/fan_only/auto）。"
            + "entity 用设备名称（如 客厅灯/主卧空调），或直接给 entity_id（如 light.living_room）。"
            + "操作前会确认。",
        parameters: [
            "type": "object",
            "properties": [
                "entity": ["type": "string", "description": "设备名称或 entity_id，如 客厅灯 / light.living_room"],
                "action": ["type": "string", "description": "操作：toggle / turn_on / turn_off / set_temperature / set_hvac_mode"],
                "temperature": ["type": "number", "description": "set_temperature 时的目标温度（摄氏度）"],
                "hvac_mode": ["type": "string", "description": "set_hvac_mode 时的模式：cool/heat/dry/fan_only/auto"],
            ],
            "required": ["entity", "action"],
        ],
        needsConfirm: true,
        run: { _ in
            // 实际由 execute() 的 executeHA 分支处理（async 后端请求）
            ToolResult(success: false, summary: "执行中…", detail: #"{"ok": false, "async": true}"#)
        }
    )

    /// 🐳 Docker 容器控制——实际执行在 executeDocker（async 走 AuthStore 后端 API）
    static let controlDockerDef = LocalToolDef(
        name: "control_docker",
        description: "控制 NAS 上的 Docker 容器。用户说「启动XX容器」「停止XX」「重启XX」时使用。"
            + "action 支持 start/stop/restart。name 用容器名（如 ollama、qingliao 相关容器）。操作前会确认。",
        parameters: [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "容器名，如 ollama"],
                "action": ["type": "string", "description": "操作：start / stop / restart"],
            ],
            "required": ["name", "action"],
        ],
        needsConfirm: true,
        run: { _ in
            // 实际由 execute() 的 executeDocker 分支处理（async 后端请求）
            ToolResult(success: false, summary: "执行中…", detail: #"{"ok": false, "async": true}"#)
        }
    )


    // MARK: - v3.0.98 NAS 桥接工具定义

    static let webExtractDef = LocalToolDef(
        name: "web_extract",
        description: "从网页URL提取内容为Markdown文本。适合获取文章、文档等网页的正文内容。",
        parameters: ["type": "object", "properties": ["url": ["type": "string", "description": "要提取内容的网页URL"]], "required": ["url"]],
        needsConfirm: false,
        run: { _ in ToolResult(success: false, summary: "提取中…", detail: #"{"async": true}"#) }
    )

    static let patchFileDef = LocalToolDef(
        name: "patch_file",
        description: "精确替换文件中的指定字符串。适合对已有文件做小范围修改。",
        parameters: ["type": "object", "properties": [
            "path": ["type": "string", "description": "文件路径"],
            "old_string": ["type": "string", "description": "要替换的字符串"],
            "new_string": ["type": "string", "description": "替换后的新字符串"]
        ], "required": ["path", "old_string", "new_string"]],
        needsConfirm: true,
        run: { _ in ToolResult(success: false, summary: "修补中…", detail: #"{"async": true}"#) }
    )

    static let todoDef = LocalToolDef(
        name: "todo",
        description: "任务规划与追踪。创建待办事项列表，跟踪任务进度。",
        parameters: ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["create", "list", "update", "complete"]],
            "task_id": ["type": "string"],
            "content": ["type": "string"],
            "status": ["type": "string", "enum": ["pending", "in_progress", "completed", "cancelled"]]
        ], "required": ["action"]],
        needsConfirm: false,
        run: { _ in ToolResult(success: false, summary: "查询中…", detail: #"{"async": true}"#) }
    )

    static let imageGenerateDef = LocalToolDef(
        name: "image_generate",
        description: "AI图片生成。根据文字描述生成图片。",
        parameters: ["type": "object", "properties": [
            "prompt": ["type": "string", "description": "图片描述"],
            "aspect_ratio": ["type": "string", "enum": ["1:1", "16:9", "9:16", "4:3", "3:4"]]
        ], "required": ["prompt"]],
        needsConfirm: false,
        run: { _ in ToolResult(success: false, summary: "生成中…", detail: #"{"async": true}"#) }
    )

    static let textToSpeechDef = LocalToolDef(
        name: "text_to_speech",
        description: "文字转语音。将文本转为语音音频。",
        parameters: ["type": "object", "properties": [
            "text": ["type": "string", "description": "要转为语音的文本"],
            "voice": ["type": "string", "description": "语音类型"]
        ], "required": ["text"]],
        needsConfirm: false,
        run: { _ in ToolResult(success: false, summary: "合成中…", detail: #"{"async": true}"#) }
    )

    static let terminalDef = LocalToolDef(
        name: "terminal",
        description: "执行Shell命令并返回输出。可用于系统管理、文件操作等。",
        parameters: ["type": "object", "properties": [
            "command": ["type": "string", "description": "要执行的Shell命令"],
            "timeout": ["type": "integer", "description": "超时秒数，默认30"]
        ], "required": ["command"]],
        needsConfirm: true,
        run: { _ in ToolResult(success: false, summary: "执行中…", detail: #"{"async": true}"#) }
    )

    static let processDef = LocalToolDef(
        name: "process",
        description: "管理后台进程。查看、轮询、终止后台运行的进程。",
        parameters: ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["list", "poll", "log", "kill"]],
            "session_id": ["type": "string"]
        ], "required": ["action"]],
        needsConfirm: false,
        run: { _ in ToolResult(success: false, summary: "查询中…", detail: #"{"async": true}"#) }
    )

    static let cronjobDef = LocalToolDef(
        name: "cronjob",
        description: "管理定时任务。创建、查看、更新、暂停、恢复、删除定时任务。",
        parameters: ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["create", "list", "update", "pause", "resume", "run", "remove"]],
            "job_id": ["type": "string"],
            "schedule": ["type": "string", "description": "调度时间，如 every 2h, 0 9 * * *"],
            "prompt": ["type": "string", "description": "任务内容"],
            "name": ["type": "string"]
        ], "required": ["action"]],
        needsConfirm: true,
        run: { _ in ToolResult(success: false, summary: "定时任务中…", detail: #"{"async": true}"#) }
    )

    static let videoGenerateDef = LocalToolDef(
        name: "video_generate",
        description: "AI视频生成。根据文字描述或图片生成视频。",
        parameters: ["type": "object", "properties": [
            "prompt": ["type": "string"],
            "image_url": ["type": "string", "description": "参考图片URL（可选）"]
        ], "required": ["prompt"]],
        needsConfirm: false,
        run: { _ in ToolResult(success: false, summary: "生成视频中…", detail: #"{"async": true}"#) }
    )

    static let videoAnalyzeDef = LocalToolDef(
        name: "video_analyze",
        description: "视频分析。分析视频内容，提取关键信息。",
        parameters: ["type": "object", "properties": [
            "video_path": ["type": "string"],
            "question": ["type": "string"]
        ], "required": ["video_path"]],
        needsConfirm: false,
        run: { _ in ToolResult(success: false, summary: "分析视频中…", detail: #"{"async": true}"#) }
    )

    // MARK: - 辅助

    /// 宽松时间解析（支持 "2026-08-21 15:00:00" / "2026-08-21T15:00:00" / "2026-08-21 15:00" /
    /// "2026-08-21T15:00" / "MM-dd HH:mm" / "HH:mm"（已过则明天））
    private static let flexibleDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = .current
        return f
    }()

    /// 宽松时间解析（支持 "2026-08-21 15:00:00" / "2026-08-21T15:00:00" / "2026-08-21 15:00" /
    /// "2026-08-21T15:00" / "MM-dd HH:mm" / "HH:mm"（已过则明天））
    static func parseFlexibleDate(_ s: String) -> Date? {
        let f = Self.flexibleDateFmt
        // v3.0.18 review fix：带秒模式必须在前（模型按 schema 示例输出 "2026-08-21T15:00:00"，
        // 无秒模式 "yyyy-MM-dd'T'HH:mm" 吞不下尾部 ":00" → 解析失败）
        let patterns = [
            "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm",
            "yyyy/MM/dd HH:mm", "MM-dd HH:mm", "HH:mm",
        ]
        for p in patterns {
            f.dateFormat = p
            if let d = f.date(from: s) { return d }
        }
        // 纯 HH:mm → 今天（若已过则明天）
        f.dateFormat = "HH:mm"
        if let d = f.date(from: s) {
            let cal = Calendar.current
            var comps = cal.dateComponents([.hour, .minute], from: d)
            let now = Date()
            comps.year = cal.component(.year, from: now)
            comps.month = cal.component(.month, from: now)
            comps.day = cal.component(.day, from: now)
            var target = cal.date(from: comps) ?? now
            if target < now { target = cal.date(byAdding: .day, value: 1, to: target) ?? now }
            return target
        }
        return nil
    }

    /// WMO 天气码 → 中文描述
    static func weatherText(_ code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1, 2: return "多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51, 53, 55, 56, 57: return "毛毛雨"
        case 61, 63, 65, 66, 67: return "雨"
        case 71, 73, 75, 77: return "雪"
        case 80, 81, 82: return "阵雨"
        case 85, 86: return "阵雪"
        case 95: return "雷暴"
        case 96, 99: return "雷暴+冰雹"
        default: return ""
        }
    }

    // MARK: - v3.0.98 NAS 桥接工具执行

    /// 执行 NAS 后端工具：POST /api/agent/tool
    static func executeNASTool(name: String, argumentsJSON: String) async -> ToolResult {
        guard let auth = authStore else {
            return ToolResult(success: false, summary: "未连接后端（请先登录）", detail: #"{"error": "no auth"}"#)
        }
        var args: [String: Any] = [:]
        if let data = argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = obj
        }
        let body: [String: Any] = ["name": name, "args": args]
        do {
            let j = try await auth.json("/api/agent/tool", method: "POST", body: body)
            let ok = (j["ok"] as? Bool) ?? false
            let result = j["result"] as? String ?? ""
            let error = j["error"] as? String ?? ""
            if ok {
                // 截断过长结果（给模型的 detail 限制 4000 字符）
                // 确保截断后 detail 始终是合法 JSON（原生 result 可能是 JSON 对象，截断会破坏结构）
                let detail: String
                if result.count > 4000 {
                    let short = String(result.prefix(4000))
                    let escaped = short.replacingOccurrences(of: "\\", with: "\\\\")
                                      .replacingOccurrences(of: "\"", with: "\\\"")
                                      .replacingOccurrences(of: "\n", with: "\\n")
                    detail = #"{"truncated": true, "content": ""# + escaped + "\"}"
                } else {
                    detail = result
                }
                return ToolResult(success: true,
                                  summary: toolNASPreview(name: name, args: args),
                                  detail: detail)
            }
            return ToolResult(success: false, summary: "NAS工具失败: \(error)",
                              detail: #"{"error": "\#(error)"}"#)
        } catch {
            return ToolResult(success: false, summary: "NAS请求失败: \(error.localizedDescription)",
                              detail: #"{"error": "\#(error.localizedDescription)"}"#)
        }
    }

    /// NAS 桥接工具的卡片标题预览
    static func toolNASPreview(name: String, args: [String: Any]) -> String {
        switch name {
        case "web_extract":
            let url = args["url"] as? String ?? ""
            let short = url.count > 40 ? String(url.prefix(40)) + "…" : url
            return "🌐 提取网页: \(short)"
        case "patch_file":
            let path = args["path"] as? String ?? ""
            return "📝 修补文件: \(path)"
        case "todo":
            let action = args["action"] as? String ?? "list"
            let content = args["content"] as? String ?? ""
            switch action {
            case "create": return "📋 新建任务: \(content.count > 20 ? String(content.prefix(20)) + "…" : content)"
            case "complete": return "✅ 完成任务: \(args["task_id"] as? String ?? "")"
            default: return "📋 查看任务列表"
            }
        case "image_generate":
            let prompt = args["prompt"] as? String ?? ""
            return "🎨 生成图片: \(prompt.count > 20 ? String(prompt.prefix(20)) + "…" : prompt)"
        case "text_to_speech":
            let text = args["text"] as? String ?? ""
            return "🔊 语音合成: \(text.count > 20 ? String(text.prefix(20)) + "…" : text)"
        case "terminal":
            let cmd = args["command"] as? String ?? ""
            return "💻 执行命令: \(cmd.count > 30 ? String(cmd.prefix(30)) + "…" : cmd)"
        case "process":
            let action = args["action"] as? String ?? "list"
            return "⚙️ 进程管理: \(action)"
        case "cronjob":
            let action = args["action"] as? String ?? "list"
            let jobName = args["name"] as? String ?? ""
            if action == "create" { return "⏰ 创建定时: \(jobName)" }
            return "⏰ 定时任务: \(action)"
        case "video_generate":
            let prompt = args["prompt"] as? String ?? ""
            return "🎬 生成视频: \(prompt.count > 20 ? String(prompt.prefix(20)) + "…" : prompt)"
        case "video_analyze":
            return "🎬 分析视频"
        default:
            return "🔧 \(name)"
        }
    }

    // MARK: - v3.0.19 HA / Docker 控制（经 AuthStore 调后端 API）

    /// 🏠 执行 HA 设备控制：POST /api/ha/services/{domain}/{service}
    static func executeHA(_ args: [String: Any]) async -> ToolResult {
        guard let auth = authStore else {
            return ToolResult(success: false, summary: "未连接后端（请先登录）", detail: #"{"error": "no auth"}"#)
        }
        guard let entity = args["entity"] as? String, !entity.isEmpty,
              let action = args["action"] as? String else {
            return ToolResult(success: false, summary: "缺少设备或操作", detail: #"{"error": "missing entity/action"}"#)
        }
        // 设备名 → entity_id：先拉 /api/ha/states 匹配 friendly_name 或直接当 entity_id 用
        var entityID = entity
        var nameMatched = entity.contains(".")
        if !entity.contains(".") {
            // 按名称匹配 HA 实体
            if let states = try? await auth.jsonArray("/api/ha/states") {
                for s in states {
                    guard let d = s as? [String: Any],
                          let eid = d["entity_id"] as? String else { continue }
                    let fn = (d["attributes"] as? [String: Any])?["friendly_name"] as? String ?? ""
                    if fn == entity || fn.hasPrefix(entity) {
                        entityID = eid
                        nameMatched = true
                        break
                    }
                }
            }
            // v3.0.19 review fix #6：名称匹配失败 → 友好提示（防裸 HA 404 用户看不懂）
            if !nameMatched {
                return ToolResult(success: false,
                                  summary: "未找到设备「\(entity)」（支持灯/空调/指定插座，试试完整名称）",
                                  detail: #"{"error": "entity not found"}"#)
            }
        }
        // action → domain/service
        let (domain, service, extra): (String, String, [String: Any]?)
        switch action {
        case "toggle": (domain, service, extra) = ("homeassistant", "toggle", nil)
        case "turn_on": (domain, service, extra) = ("homeassistant", "turn_on", nil)
        case "turn_off": (domain, service, extra) = ("homeassistant", "turn_off", nil)
        case "set_temperature":
            guard let t = args["temperature"] as? Double else {
                return ToolResult(success: false, summary: "缺少目标温度", detail: #"{"error": "missing temperature"}"#)
            }
            // v3.0.19 review fix #4：set_temperature 仅 climate/water_heater 域支持
            // （homeassistant 域无 set_temperature 服务，旧 fallback 必 404）
            guard entityID.hasPrefix("climate.") || entityID.hasPrefix("water_heater.") else {
                return ToolResult(success: false,
                                  summary: "该设备不支持设置温度（仅空调/热水器等温控设备可用）",
                                  detail: #"{"error": "entity not temperature-controllable"}"#)
            }
            let dom = entityID.hasPrefix("water_heater.") ? "water_heater" : "climate"
            (domain, service, extra) = (dom, "set_temperature", ["temperature": t])
        case "set_hvac_mode":
            guard let m = args["hvac_mode"] as? String else {
                return ToolResult(success: false, summary: "缺少空调模式", detail: #"{"error": "missing hvac_mode"}"#)
            }
            (domain, service, extra) = ("climate", "set_hvac_mode", ["hvac_mode": m])
        default:
            return ToolResult(success: false, summary: "不支持的操作：\(action)", detail: #"{"error": "unsupported action"}"#)
        }
        var body: [String: Any] = ["entity_id": entityID]
        if let extra { body.merge(extra) { _, new in new } }
        do {
            let j = try await auth.json("/api/ha/services/\(domain)/\(service)", method: "POST", body: body)
            // HA 服务调用成功一般返回空对象或 ok
            if let err = j["error"] as? String, !err.isEmpty {
                return ToolResult(success: false, summary: "HA 操作失败：\(err)", detail: #"{"error": "\#(err)"}"#)
            }
            return ToolResult(success: true,
                              summary: "已执行：\(action) \(entity)",
                              detail: #"{"ok": true, "entity": "\#(entityID)", "action": "\#(action)"}"#)
        } catch {
            return ToolResult(success: false, summary: "HA 请求失败：\(error.localizedDescription)",
                              detail: #"{"error": "\#(error.localizedDescription)"}"#)
        }
    }

    /// 🐳 执行 Docker 容器控制：POST /api/docker/{action} {name}
    static func executeDocker(_ args: [String: Any]) async -> ToolResult {
        guard let auth = authStore else {
            return ToolResult(success: false, summary: "未连接后端（请先登录）", detail: #"{"error": "no auth"}"#)
        }
        guard let name = args["name"] as? String, !name.isEmpty,
              let action = args["action"] as? String,
              ["start", "stop", "restart"].contains(action) else {
            return ToolResult(success: false, summary: "缺少容器名或操作（start/stop/restart）",
                              detail: #"{"error": "missing name/action"}"#)
        }
        do {
            let j = try await auth.json("/api/docker/\(action)", method: "POST", body: ["name": name])
            let ok = (j["ok"] as? Bool) ?? false
            let msg = j["message"] as? String ?? ""
            if ok {
                return ToolResult(success: true,
                                  summary: "已\(actionName(action))容器：\(name)",
                                  detail: #"{"ok": true, "name": "\#(name)", "action": "\#(action)"}"#)
            }
            return ToolResult(success: false, summary: "Docker \(action) 失败：\(msg)",
                              detail: #"{"error": "\#(msg)"}"#)
        } catch {
            return ToolResult(success: false, summary: "Docker 请求失败：\(error.localizedDescription)",
                              detail: #"{"error": "\#(error.localizedDescription)"}"#)
        }
    }

    /// action 英文 → 中文（播报/卡片用）
    static func actionName(_ a: String) -> String {
        switch a {
        case "start": return "启动"
        case "stop": return "停止"
        case "restart": return "重启"
        default: return a
        }
    }
}
