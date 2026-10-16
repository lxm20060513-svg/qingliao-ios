import Foundation

// MARK: - ③ 后台唤醒台账（把「及时性」变成可测数字的那一半）
//
// 为什么需要它：iOS 的后台唤醒时机**完全由系统决定**（legacy background fetch 与
// BGAppRefreshTask 都没有频率承诺，"earliestBeginDate = 15 分钟" 只是**不早于**）。
// 于是"推送慢"不能靠感觉调参 —— 先有数据才能回答：
//   ① 系统实际多久叫一次？（实测分布，而不是文档上的"应该 15 分钟"）
//   ② 叫醒后取到东西没有？（newData 次数 vs 空转次数）
//   ③ 哪条腿在起作用（流式任务 / 收件箱）？
//
// ⚠️ 只记**时刻 + 来源 + 结果计数**，不记通知正文、不记会话 id、不记账号 ——
//    这个文件是要拿给用户看/导出的（Documents 目录，文件 App 可见）。

/// 一次唤醒的来源
enum BackgroundWakeKind: String, CaseIterable, Sendable {
    case fetch          // 老式 background fetch 回调（performFetchWithCompletionHandler）
    case refreshTask    // BGAppRefreshTask（iOS 13+ 那条更可控的路）
    case entering       // 进后台（提交下一次请求的时刻）
    case foreground     // 回前台
    case launch         // 冷启动

    /// 日志里的中文标签（给用户看的，不是给机器看的）
    var label: String {
        switch self {
        case .fetch:       return "后台刷新"
        case .refreshTask: return "后台任务"
        case .entering:    return "进后台"
        case .foreground:  return "回前台"
        case .launch:      return "冷启动"
        }
    }
}

enum BackgroundWakeLog {

    /// UserDefaults 键（台账是环形缓冲，最多 `limit` 条）
    static let key = "qingliao_bg_wake_log"
    static let limit = 200
    static let fileName = "background_wake.log"

    // MARK: 纯函数（真值表钉着）

    /// 一行台账文本：`2026-10-16T14:03:11+0800 | 后台刷新 | newData inbox:2/9`
    ///
    /// `outcome` 的约定（`summary` 靠它统计，改格式 = 统计静默失真）：
    ///   **首词**必须是 `newData` / `noData` / `failed` 之一，后面可跟计数等细节（空格分隔）。
    ///   ⚠️ 不写正文、不写会话 id —— 台账是要拿给用户看/导出的。
    static func line(at date: Date, kind: BackgroundWakeKind, outcome: String) -> String {
        let ts = formatter().string(from: date)
        let o = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(ts) | \(kind.label) | \(o.isEmpty ? "-" : o)"
    }

    /// 从一行里取时刻（解析失败返回 nil —— 台账要能容忍手改/截断的行）
    static func dateOf(_ line: String) -> Date? {
        guard let head = line.split(separator: "|").first else { return nil }
        return formatter().date(from: head.trimmingCharacters(in: .whitespaces))
    }

    /// 从一行里取来源标签（反查枚举 label；认不出的返回 nil）
    static func kindOf(_ line: String) -> BackgroundWakeKind? {
        let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        return BackgroundWakeKind.allCases.first { $0.label == parts[1] }
    }

    /// 从一行里取结果列（第三列起；给「取到新数据/空转」的统计用）
    static func outcomeOf(_ line: String) -> String {
        let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count >= 3 ? parts[2...].joined(separator: "|") : ""
    }

    /// 摘要（用户/我们看的那一句话）：近 N 小时的唤醒次数、来源分布、取到新数据次数、最近一次距今多久。
    /// - `entries`：按时间正序（旧→新），与 `record` 的追加顺序一致。
    static func summary(entries: [String], now: Date = Date(), hours: Int = 24) -> String {
        let window = TimeInterval(hours) * 3600
        let parsed = entries.compactMap { line -> (Date, BackgroundWakeKind, String)? in
            guard let d = dateOf(line), let k = kindOf(line) else { return nil }
            return (d, k, outcomeOf(line))
        }
        guard let last = parsed.last else { return "还没有记录（App 装好后到自己进过一次后台/被系统叫醒才会开始记）" }

        // ⚠️ 判定要带下界：时钟回拨 / 台账里的未来行（手改、跨时区）不该算进「近 N 小时」，
        //    否则那些行会被算成负时长、把统计口径弄反。
        let recent = parsed.filter {
            let d = now.timeIntervalSince($0.0)
            return d <= window && d >= 0
        }
        // 「被系统叫醒」= 后台刷新 / 后台任务两条来源；进后台、回前台、冷启动只是台账上下文，
        // 不计入"唤醒了多少次"，否则空转率会被这些记账冲淡（统计失真比没有统计更坏）
        let wakeOnly = recent.filter { $0.1 == .fetch || $0.1 == .refreshTask }
        // 「取到新数据」判据 = 结果列**首词**为 newData（约定见 line(at:kind:outcome:)）
        let newData = wakeOnly.filter { $0.2.hasPrefix("newData") }.count
        let idle = wakeOnly.count - newData

        var parts: [String] = []
        for k in BackgroundWakeKind.allCases {
            let n = recent.filter { $0.1 == k }.count
            if n > 0 { parts.append("\(k.label) \(n)") }
        }
        // 🚨 「最近一次**唤醒**」只能取系统叫醒那两类（fetch / refreshTask）的最后一条。
        //    取 parsed.last 的话：用户刚从桌面点开 App（记了一笔「回前台」）就会显示
        //    「最近一次唤醒 3 秒前」，而真实的上一次系统唤醒可能是几小时前 —— 这个数字正是
        //    这份台账唯一要回答的东西（真值表钉住；同函数另一分支的措辞本来就是「最近一次记录」）。
        let lastWake = parsed.last { $0.1 == .fetch || $0.1 == .refreshTask }
        let lastRef = lastWake ?? last
        let ago = max(0, now.timeIntervalSince(lastRef.0))
        let agoText = ago < 60 ? "\(Int(ago)) 秒前"
            : ago < 3600 ? "\(Int(ago / 60)) 分钟前"
            : "\(Int(ago / 3600)) 小时前"

        if wakeOnly.isEmpty {
            return "近 \(hours)h 系统一次都没叫醒过（\(parts.joined(separator: " · "))）；"
                 + "最近一次记录是 \(lastRef.1.label) \(agoText)"
        }
        return "近 \(hours)h 系统叫醒 \(wakeOnly.count) 次（\(parts.joined(separator: " · "))），"
             + "其中取到新数据 \(newData) 次、空转 \(idle) 次；最近一次唤醒 \(agoText)"
    }

    // MARK: 落盘（线程安全；URLSession 回调可在任意线程调）

    private static let queue = DispatchQueue(label: "com.qingliao.bgwakelog")

    /// ISO8601 带时区（用户在中国 = +0800）。**每次现建**，不做全局共享实例：
    /// 后台唤醒来自任意线程、`DateFormatter` 系类型不承诺跨线程安全，
    /// 而这里一次唤醒最多格式化/解析 200 行 —— 现建的开销远小于一处竞态的代价。
    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        // ⚠️ 默认 timeZone 是 **GMT**：不设的话写进台账/导出文件的是 `…T06:03:11Z`，
        //    而本文件是要给用户看/导出的（Documents，文件 App 可见）⇒ 所有时刻凭空早 8 小时。
        f.timeZone = TimeZone.current
        return f
    }

    /// 记一笔：UserDefaults 环形缓冲 + Documents/background_wake.log 追加一行
    static func record(_ kind: BackgroundWakeKind, outcome: String = "-", at date: Date = Date()) {
        let text = line(at: date, kind: kind, outcome: outcome)
        queue.async {
            var arr = (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
            arr.append(text)
            if arr.count > limit { arr = Array(arr.suffix(limit)) }
            UserDefaults.standard.set(arr, forKey: key)
            rewriteFile(arr)
        }
    }

    /// 台账（旧→新）
    static func entries() -> [String] {
        (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
    }

    /// 台账文件路径（文件 App 可见：设置 → 文件 → 我的 iPhone → 轻聊）
    static func fileURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }

    /// 台账文件与内存环形缓冲**同源**：每次重写最近 `limit` 行（不是只 append）。
    /// 🚨 只 append 的话文件会无限增长，而 `limit` 只裁内存那份 —— 与「台账是环形缓冲、
    ///    最多 limit 条」的文档不符（这份文件是给用户看/导出的，长期会变成一份越滚越大的日志）。
    ///    重写是原子写（`.atomic`），代价只有几十 KB，而唤醒频率是小时级。
    private static func rewriteFile(_ lines: [String]) {
        guard let url = fileURL() else { return }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        try? data.write(to: url, options: .atomic)
    }

    /// 清空（设置页给用户一个重置入口；也方便我们做一次"干净样本"实测）
    static func reset() {
        queue.async {
            UserDefaults.standard.removeObject(forKey: key)
            if let url = fileURL() { try? FileManager.default.removeItem(at: url) }
        }
    }
}

// MARK: - 跨层共享的 UserDefaults 键（唯一真源）
//
// 🚨 为什么单独拎出来：后台补拉收件箱（AppDelegate，**非 MainActor** 上下文）必须知道
//    "前台已经消费过哪些推送"，这个集合由 `InboxStore` 维护。键名各写一份 = 两处漂移后
//    **静默**重复弹通知（编译过、无日志、要用户报"同一条推了两次"才发现）。
//    `InboxStore` 是 @MainActor 类，它的 static 常量在非隔离上下文读不到 ⇒ 常量落在这里。
enum InboxKeys {
    /// 前台已注入并弹过通知的收件箱条目 id（InboxStore 维护，环形 200）
    static let consumedIds = "qingliao_inbox_consumed_ids"
}
