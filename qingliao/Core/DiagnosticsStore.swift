import Foundation

// MARK: - v3.6.0 诊断本地存储：离线队列 + 本地历史
//
// 同样是纯 Foundation（无 UIKit / 无 Security）——与 DiagnosticsPayload.swift 一起被
// scripts/test_diag.swift 编译成 Linux 可执行文件跑单测（注入临时目录 + 假环境）。
//
// 两份文件（均在 App 沙盒 Documents/）：
//   diag_pending.json —— 待上报队列（上报成功即移除；失败保留，下次启动补传）
//   diag_history.json —— 本地历史（最近 maxHistoryEvents 条，供诊断页离线展示）
//
// 线程安全：所有磁盘操作用串行队列序列化；跨线程只共享 Sendable 值类型。

enum DiagnosticsStore {
    // MARK: 可注入状态（单测覆盖）

    /// 测试注入的基准目录（nil = 用 HOME/Documents）
    nonisolated(unsafe) private static var baseDirOverride: String?
    /// 当前环境快照（由 DiagnosticsEnv 在启动/前台时刷新）
    // v3.9.10 fix（审查抓到）：currentEnv 由主线程（DiagnosticsEnv.refresh）写、却被**任意线程**读
    // （看门狗监控线程的死锁兜底会直接调 recordHang）。值类型 ≠ 线程安全：多字段结构体并发读写是
    // UB（TSan 必报），还可能读到「设备型号来自一次 refresh、网络来自另一次」的撕裂快照。
    private static let envLock = NSLock()
    nonisolated(unsafe) private static var currentEnvStorage: DiagEnv = .unknown

    private static let ioQueue = DispatchQueue(label: "qingliao.diag.io")

    // MARK: 路径

    static func setBaseDir(_ dir: String?) { baseDirOverride = dir }

    static func baseDir() -> String {
        if let d = baseDirOverride { return d }
        // 与 CrashReporter 同目录：handler 上下文用 getenv("HOME")（async-signal-safe）
        if let home = getenv("HOME") { return String(cString: home) + "/Documents" }
        return NSTemporaryDirectory()
    }

    static func pendingPath() -> String { baseDir() + "/diag_pending.json" }
    static func historyPath() -> String { baseDir() + "/diag_history.json" }
    static func statsPath() -> String { baseDir() + "/diag_stats.json" }

    // MARK: 环境快照

    static func setEnv(_ env: DiagEnv) {
        envLock.lock(); currentEnvStorage = env; envLock.unlock()
    }

    static func env() -> DiagEnv {
        envLock.lock(); defer { envLock.unlock() }
        return currentEnvStorage
    }

    // MARK: 读写

    /// 必须已在 ioQueue 临界区内调用（内部不再加锁）
    private static func readUnlocked(_ path: String) -> [DiagEvent] {
        // 文件不存在 = 空队列（正常）；解码失败 ≠ 空队列
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        guard let events = DiagnosticsPayload.decodeStrict(data) else {
            // v3.9.10 fix：坏文件（截断/跨版本字段不兼容）原来被当成 [] → 用户看到「待上报 0 条」，
            // 而且随后任意一次 enqueue 会把积压原子覆盖、再无恢复可能。这里隔离留证再返回空。
            let stamp = String(Int(Date().timeIntervalSince1970))
            let quarantine = path + ".corrupt-" + stamp
            try? FileManager.default.moveItem(atPath: path, toPath: quarantine)
            NSLog("[DIAG] 诊断文件解码失败，已隔离为 %@（%d 字节）", quarantine, data.count)
            return []
        }
        return events
    }

    private static func read(_ path: String) -> [DiagEvent] {
        ioQueue.sync { readUnlocked(path) }
    }

    /// 必须已在 ioQueue 临界区内调用；返回是否真的落盘
    @discardableResult
    private static func writeUnlocked(_ events: [DiagEvent], to path: String) -> Bool {
        let data = DiagnosticsPayload.encode(events)
        do {
            try FileManager.default.createDirectory(atPath: baseDir(),
                                                   withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            // v3.9.10 fix：原来 createDirectory/write 全用 try? 吞错，写失败时界面照样显示
            // 「已写入一条测试记录（1 条待上报）」却立刻读成 0，全程无日志可查
            NSLog("[DIAG] 诊断文件写入失败 %@：%@", path, String(describing: error))
            return false
        }
    }

    private static func write(_ events: [DiagEvent], to path: String) {
        ioQueue.sync { _ = writeUnlocked(events, to: path) }
    }

    // MARK: 队列 / 历史

    static func pendingEvents() -> [DiagEvent] { read(pendingPath()) }

    // MARK: v3.9.10 异步 I/O（上报路径专用）
    //
    // 上报流程跑在 @MainActor 上，而 read/write 走的是 `ioQueue.sync` = **调用方阻塞**。
    // 批量补传时最多 10 批，每批都要同步读+写盘、还要对每条事件做整包 JSON 编码，
    // 叠在刚恢复的主线程上可能自己越过 400ms 阈值 → 被看门狗记成一次「真卡顿」（自证式假阳性）。
    // 这里提供 async 版本：I/O 丢到 ioQueue 上执行，主线程只 await。

    static func pendingEventsAsync() async -> [DiagEvent] {
        await withCheckedContinuation { cont in
            ioQueue.async { cont.resume(returning: readUnlocked(pendingPath())) }
        }
    }

    static func removePendingAsync(ids: [String]) async {
        guard !ids.isEmpty else { return }
        await withCheckedContinuation { cont in
            ioQueue.async {
                let set = Set(ids)
                let rest = readUnlocked(pendingPath()).filter { !set.contains($0.id) }
                _ = writeUnlocked(rest, to: pendingPath())
                cont.resume()
            }
        }
        notifyQueueChanged()
    }

    static func recordUploadResultAsync(ok: Bool, sent: Int, message: String) async {
        await withCheckedContinuation { cont in
            ioQueue.async {
                var s = readStatsUnlocked()
                s.totalUploaded += max(0, sent)
                s.lastOK = ok
                s.lastMessage = message
                s.lastAt = Date().timeIntervalSince1970
                do {
                    try FileManager.default.createDirectory(atPath: baseDir(),
                                                           withIntermediateDirectories: true)
                    let data = try JSONEncoder().encode(s)
                    try data.write(to: URL(fileURLWithPath: statsPath()), options: .atomic)
                } catch {
                    NSLog("[DIAG] 上报统计写入失败：%@", String(describing: error))
                }
                cont.resume()
            }
        }
        notifyQueueChanged()
    }

    static func pendingCount() -> Int { pendingEvents().count }

    static func historyEvents() -> [DiagEvent] {
        read(historyPath()).sorted { $0.ts > $1.ts }   // 最新在前
    }

    /// 入队（同时写本地历史）。同 id 去重；两端都做上限裁剪（丢最旧）。
    @discardableResult
    static func enqueue(_ event: DiagEvent) -> DiagEvent {
        // v3.9.10：读-改-写收进**同一个临界区**（原来 pending 的 read 与 write 分两次 ioQueue.sync，
        // 并发入队时后写者会覆盖前写者 → 丢事件）
        ioQueue.sync {
            var pending = readUnlocked(pendingPath()).filter { $0.id != event.id }
            pending.append(event)
            _ = writeUnlocked(capKeeping(event, in: pending,
                                         limit: DiagnosticsPayload.maxPendingEvents),
                              to: pendingPath())

            var history = readUnlocked(historyPath()).filter { $0.id != event.id }
            history.append(event)
            _ = writeUnlocked(capKeeping(event, in: history,
                                         limit: DiagnosticsPayload.maxHistoryEvents),
                              to: historyPath())
        }
        notifyQueueChanged()
        return event
    }

    /// v3.9.10：裁剪时**绝不丢掉刚入队的那条**——capEvents 按业务 ts 排序，而崩溃事件的 ts 是
    /// 崩溃发生时刻，可能比队列里最近几十条卡顿都早，队列满时会被当场裁掉（一条从未上报的崩溃静默丢失）。
    private static func capKeeping(_ event: DiagEvent, in events: [DiagEvent], limit: Int) -> [DiagEvent] {
        var capped = DiagnosticsPayload.capEvents(events, limit: limit)
        if !capped.contains(where: { $0.id == event.id }), capped.count >= limit {
            capped.removeFirst()
            capped.append(event)
        }
        return capped
    }

    /// 上报成功后出队
    static func removePending(ids: [String]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        ioQueue.sync {
            let rest = readUnlocked(pendingPath()).filter { !set.contains($0.id) }
            _ = writeUnlocked(rest, to: pendingPath())
        }
        notifyQueueChanged()
    }

    static func clearHistory() { write([], to: historyPath()) }

    // MARK: v3.9.10 上报统计 + 队列变化通知
    //
    // 为什么需要：卡顿记录后立刻上报、成功即出队 → 「待上报」长期是 0 条，用户看到 0 会以为
    // 「诊断没在工作」。所以补一份**累计/上次结果**统计，并把队列变化广播出去让诊断页实时刷新。

    struct UploadStats: Codable, Sendable, Equatable {
        var totalUploaded: Int = 0        // 累计成功上报条数
        var lastOK: Bool = false
        var lastMessage: String = ""
        var lastAt: Double = 0            // 上次上报时间（Unix 秒）
    }

    private static func readStatsUnlocked() -> UploadStats {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statsPath())),
              let s = try? JSONDecoder().decode(UploadStats.self, from: data) else {
            return UploadStats()
        }
        return s
    }

    static func stats() -> UploadStats {
        ioQueue.sync { readStatsUnlocked() }
    }

    /// 上报结束后记账（由 DiagnosticsUploader 调用）
    static func recordUploadResult(ok: Bool, sent: Int, message: String) {
        ioQueue.sync {
            var s = readStatsUnlocked()
            s.totalUploaded += max(0, sent)
            s.lastOK = ok
            s.lastMessage = message
            s.lastAt = Date().timeIntervalSince1970
            do {
                try FileManager.default.createDirectory(atPath: baseDir(),
                                                       withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(s)
                try data.write(to: URL(fileURLWithPath: statsPath()), options: .atomic)
            } catch {
                NSLog("[DIAG] 上报统计写入失败：%@", String(describing: error))
            }
        }
        notifyQueueChanged()
    }

    /// 队列变化通知（诊断页据此实时刷新「待上报 / 统计」两行）
    static let queueChangedNotification = Notification.Name("qingliao.diag.queueChanged")

    private static func notifyQueueChanged() {
        // 记录可能发生在后台线程（看门狗），统一回主线程广播，避免 UI 状态在主线程外更新
        if Thread.isMainThread {
            NotificationCenter.default.post(name: queueChangedNotification, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: queueChangedNotification, object: nil)
            }
        }
    }

    // MARK: 记录入口（崩溃 / 卡顿）

    /// 崩溃：type/detail 来自 CrashReporter 的 crash_pending.json
    @discardableResult
    static func recordCrash(type: String, detail: String, stack: String, ts: Double) -> DiagEvent {
        enqueue(DiagnosticsPayload.makeCrashEvent(type: type, detail: detail,
                                                  stack: stack, env: env(), ts: ts))
    }

    /// v3.9.10：自测记录（诊断页「写入一条测试记录」）用**独立 kind="selftest"**。
    /// 原来复刻成 kind="hang"、summary 与真实卡顿完全一致 → 服务端的卡顿统计会把测试记录也算进去。
    @discardableResult
    static func recordSelfTest(durationMs: Int, stack: String) -> DiagEvent {
        enqueue(DiagnosticsPayload.makeEvent(kind: "selftest", env: env(),
                                             summary: "自测记录（非真实卡顿）\(durationMs)ms",
                                             stack: stack, durationMs: durationMs))
    }

    /// 卡顿
    @discardableResult
    static func recordHang(durationMs: Int, stack: String) -> DiagEvent {
        enqueue(DiagnosticsPayload.makeHangEvent(durationMs: durationMs, stack: stack,
                                                 env: env()))
    }
}
