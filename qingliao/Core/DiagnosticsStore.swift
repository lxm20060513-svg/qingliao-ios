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
    nonisolated(unsafe) private static var currentEnv: DiagEnv = .unknown

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

    // MARK: 环境快照

    static func setEnv(_ env: DiagEnv) { currentEnv = env }
    static func env() -> DiagEnv { currentEnv }

    // MARK: 读写

    private static func read(_ path: String) -> [DiagEvent] {
        ioQueue.sync {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
            return DiagnosticsPayload.decode(data)
        }
    }

    private static func write(_ events: [DiagEvent], to path: String) {
        ioQueue.sync {
            let data = DiagnosticsPayload.encode(events)
            try? FileManager.default.createDirectory(atPath: baseDir(),
                                                    withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    // MARK: 队列 / 历史

    static func pendingEvents() -> [DiagEvent] { read(pendingPath()) }

    static func pendingCount() -> Int { pendingEvents().count }

    static func historyEvents() -> [DiagEvent] {
        read(historyPath()).sorted { $0.ts > $1.ts }   // 最新在前
    }

    /// 入队（同时写本地历史）。同 id 去重；两端都做上限裁剪（丢最旧）。
    @discardableResult
    static func enqueue(_ event: DiagEvent) -> DiagEvent {
        var pending = read(pendingPath()).filter { $0.id != event.id }
        pending.append(event)
        write(DiagnosticsPayload.capEvents(pending, limit: DiagnosticsPayload.maxPendingEvents),
              to: pendingPath())

        var history = read(historyPath()).filter { $0.id != event.id }
        history.append(event)
        write(DiagnosticsPayload.capEvents(history, limit: DiagnosticsPayload.maxHistoryEvents),
              to: historyPath())
        return event
    }

    /// 上报成功后出队
    static func removePending(ids: [String]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        let rest = read(pendingPath()).filter { !set.contains($0.id) }
        write(rest, to: pendingPath())
    }

    static func clearHistory() { write([], to: historyPath()) }

    // MARK: 记录入口（崩溃 / 卡顿）

    /// 崩溃：type/detail 来自 CrashReporter 的 crash_pending.json
    @discardableResult
    static func recordCrash(type: String, detail: String, stack: String, ts: Double) -> DiagEvent {
        enqueue(DiagnosticsPayload.makeCrashEvent(type: type, detail: detail,
                                                  stack: stack, env: currentEnv, ts: ts))
    }

    /// 卡顿
    @discardableResult
    static func recordHang(durationMs: Int, stack: String) -> DiagEvent {
        enqueue(DiagnosticsPayload.makeHangEvent(durationMs: durationMs, stack: stack,
                                                 env: currentEnv))
    }
}
