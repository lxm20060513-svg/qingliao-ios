import Darwin
import Foundation
import UIKit

// MARK: - v2.0.43 崩溃上报：本地捕获 → 下次启动 POST 到 NAS /api/logs/crash
// 注意：signal/NSException handler 是 C 函数指针，闭包不能捕获上下文，
// 因此 handler 全部用顶层函数 + 固定路径 POSIX 直写。

/// 崩溃文件路径（全局函数，handler 与 flushPending 共用，避免捕获）
/// v2.0.44：用 getenv("HOME")（async-signal-safe）替代 NSSearchPathForDirectoriesInDomains
/// （后者非 signal-safe，崩溃 handler 里调用可能死锁卡死导致文件写不成）
func qlCrashFilePath() -> String {
    if let home = getenv("HOME") {
        return String(cString: home) + "/Documents/crash_pending.json"
    }
    return NSTemporaryDirectory() + "crash_pending.json"
}

/// v3.9.10 fix：**信号 handler 专用**崩溃文件。原来异常 handler 与信号 handler 都 O_TRUNC 写
/// crash_pending.json —— NSException handler 写完返回后运行时 abort() → SIGABRT → 信号 handler
/// 把整份 NSException 记录（type/reason/栈）覆盖成 `{"type":"Signal(6)"}`，异常名与 reason 永久丢失。
/// 现在两份分开写，flush 时都读、都不丢。同目录（同样用 getenv("HOME")，async-signal-safe）。
func qlCrashSigFilePath() -> String {
    if let home = getenv("HOME") {
        return String(cString: home) + "/Documents/crash_pending_sig.json"
    }
    return NSTemporaryDirectory() + "crash_pending_sig.json"
}

/// 同目录调用栈文件路径（v3.4.1 起由信号 handler 写）
func qlCrashStackPath() -> String {
    let p = qlCrashFilePath()
    return ((p as NSString).deletingLastPathComponent) + "/crash_stack.txt"
}

/// POSIX 直写崩溃信息（v2.0.47：路径用 C 数组 strcpy/strcat 拼接，全程无 Swift 分配，
/// 纯 async-signal-safe——String(cString:) 等 Swift 字符串构造会分配内存，handler 里可能死锁）
func qlWriteCrashFile(type: String, detail: String) {
    let escaped = detail
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .prefix(3000)
    // v3.9.10：时间戳走 time(2)（POSIX，不触发 Foundation 的日期格式化与额外分配）
    let entry = "{\"type\":\"\(type)\",\"detail\":\"\(escaped)\",\"ts\":\(Int(time(nil)))}\n"
    let home = getenv("HOME")
    // v3.9.10：路径缓冲也从 Swift Array（= malloc 堆分配）改成栈分配。NSException 常抛在
    // 分配/释放路径上，若崩溃线程正持有 malloc 锁，handler 里的堆分配会自死锁 → 一条都写不出。
    // （entry 本身的 escape/插值仍需分配，属残留风险，见任务台账。）
    withUnsafeTemporaryAllocation(of: CChar.self, capacity: 1024) { buf in
        _ = buf.initialize(repeating: 0)
        let path = buf.baseAddress!
        if let h = home {
            _ = strcpy(path, h)
        } else {
            _ = strcpy(path, "/tmp")
        }
        _ = strcat(path, "/Documents/crash_pending.json")
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        _ = entry.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr))
        }
        close(fd)
    }
}

/// signal handler（顶层函数，无捕获；v2.0.48：纯 C 极简写——signal 上下文禁用一切
/// Swift 字符串构造/分配，只写固定格式；完整栈由 NSException handler 负责）
/// v3.4.1：新增同目录 crash_stack.txt——backtrace_symbols_fd 是 async-signal-safe，
/// 信号上下文可直接调用，把含函数名的调用栈写入独立文件（侧载包未 strip，栈可读）。
/// 崩溃定位缺陷根治：此前只记信号号，几十次 Signal(5) 崩溃全部无栈无法定位。
func qlCrashSignalHandler(_ sig: Int32) {
    let home = getenv("HOME")
    // v3.9.10 fix ①：**信号 handler 不再写 crash_pending.json**，改写到 crash_pending_sig.json。
    // 原来它与 NSException handler O_TRUNC 同一文件 → abort() 产生的 SIGABRT 会把刚写好的
    // NSException 记录（异常名/reason/栈）覆盖成 `{"type":"Signal(6)"}`，定位信息永久丢失。
    //
    // v3.9.10 fix ②：所有缓冲区改用 `withUnsafeTemporaryAllocation`（**真·栈分配**）。
    // 原来写的 `[CChar](repeating:count:)` 是 Swift Array —— 缓冲区由 malloc 堆分配，
    // 在 signal 上下文里不是 async-signal-safe：崩溃线程若正持有 malloc/zone 锁
    // （SIGSEGV/SIGABRT 恰恰常发生在分配/释放路径上），handler 会与自己的进程抢锁自死锁，
    // open/write 一条都执行不到 → 崩溃记录写不出来（注释里「栈上数组，无堆分配」并不成立）。
    withUnsafeTemporaryAllocation(of: CChar.self, capacity: 1024) { path in
        _ = path.initialize(repeating: 0)
        if let h = home {
            _ = strcpy(path.baseAddress!, h)
        } else {
            _ = strcpy(path.baseAddress!, "/tmp")
        }
        _ = strcat(path.baseAddress!, "/Documents/crash_pending_sig.json")

        // v2.0.49：写具体信号号（SIGABRT=6/SIGSEGV=11/SIGBUS=10/SIGILL=4/SIGFPE=8/SIGTRAP=5）。
        // snprintf 是 variadic C 函数 Swift 不导入 → 手动十进制拼接（strcpy/strcat/strlen 全 POSIX signal-safe）
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 128) { buf in
            _ = buf.initialize(repeating: 0)
            let b = buf.baseAddress!
            _ = strcpy(b, "{\"type\":\"Signal(")
            var idx = strlen(b)
            var n = sig
            var d = 0
            withUnsafeTemporaryAllocation(of: CChar.self, capacity: 12) { digits in
                _ = digits.initialize(repeating: 0)
                let dg = digits.baseAddress!
                if n == 0 { dg[0] = 48; d = 1 }
                while n > 0 {
                    dg[d] = CChar(48 + n % 10); d += 1; n /= 10
                }
                while d > 0 {
                    d -= 1; b[idx] = dg[d]; idx += 1
                }
            }
            b[idx] = 41     // )
            b[idx + 1] = 34 // "
            idx += 2
            // v3.9.10 fix ④：补 ts（time(2) 是 async-signal-safe，无需分配）。
            // 崩溃事件的 id 由 (type, ts) 派生（确定性去重）：原来信号文件里没有 ts，
            // persistCrashFiles 只能回落到「当前时间」→ 每次冷启动算出不同 id，
            // 同一条 Signal(11) 崩溃反复入队/重复上报——恰恰是最需要去重的那一类。
            _ = strcpy(b + idx, ",\"ts\":")
            idx += strlen(b + idx)
            var tt = time(nil)
            withUnsafeTemporaryAllocation(of: CChar.self, capacity: 24) { digits in
                _ = digits.initialize(repeating: 0)
                let dg = digits.baseAddress!
                var d = 0
                if tt == 0 { dg[0] = 48; d = 1 }
                while tt > 0 { dg[d] = CChar(48 + tt % 10); d += 1; tt /= 10 }
                while d > 0 { d -= 1; b[idx] = dg[d]; idx += 1 }
            }
            b[idx] = 125     // }
            b[idx + 1] = 10  // \n
            idx += 2
            b[idx] = 0       // 终止
            let fd = open(path.baseAddress!, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd >= 0 {
                Darwin.write(fd, b, idx)
                close(fd)
            }
        }
    }
    // v3.4.1：写调用栈文件（backtrace/backtrace_symbols_fd 均 async-signal-safe）
    withUnsafeTemporaryAllocation(of: CChar.self, capacity: 1024) { stackPath in
        _ = stackPath.initialize(repeating: 0)
        if let h = home {
            _ = strcpy(stackPath.baseAddress!, h)
        } else {
            _ = strcpy(stackPath.baseAddress!, "/tmp")
        }
        _ = strcat(stackPath.baseAddress!, "/Documents/crash_stack.txt")
        let sfd = open(stackPath.baseAddress!, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if sfd >= 0 {
            withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 128) { callstack in
                let frames = backtrace(callstack.baseAddress!, 128)
                backtrace_symbols_fd(callstack.baseAddress!, frames, sfd)
            }
            close(sfd)
        }
    }
    // v3.9.10 fix ③：原来是 `exit(sig)` —— exit() 不在 async-signal-safe 列表（要跑 atexit、
    // flush stdio），若崩在 stdio/atexit 锁上 handler 会卡死（App 不退出也不崩、还吞掉系统 Crash Report）。
    // 正解：恢复默认处置再重新 raise 同一信号 → 进程按原信号真正死亡，系统仍能生成崩溃报告。
    signal(sig, SIG_DFL)
    raise(sig)
}

/// NSException handler（顶层函数，无捕获）
func qlCrashExceptionHandler(_ ex: NSException) {
    let stack = ex.callStackSymbols.prefix(30).joined(separator: "\n")
    qlWriteCrashFile(type: "NSException", detail: "\(ex.name.rawValue): \(ex.reason ?? "")\n\(stack)")
}

enum CrashReporter {
    private static let sigs: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    /// App 启动时安装（必须在 main 早期调用）
    /// v3.6.0：一并启动主线程卡顿看门狗（RunLoop observer，空闲零开销）
    /// v3.9.10：备用信号栈（64KB，进程内常驻不释放）
    nonisolated(unsafe) private static var altStack: UnsafeMutableRawPointer?

    static func install() {
        NSSetUncaughtExceptionHandler(qlCrashExceptionHandler)

        // v3.9.10 fix：**备用信号栈**。栈溢出类崩溃（深层递归）时信号是在**已经耗尽的那条栈**上
        // 送达的，handler 一执行就二次崩 → crash_pending.json / crash_stack.txt 一个都写不出。
        // sigaltstack + SA_ONSTACK 把 handler 搬到独立栈上跑，这类崩溃才采得到。
        if altStack == nil {
            let size = 64 * 1024
            if let mem = malloc(size) {
                altStack = mem
                var ss = stack_t()
                ss.ss_sp = mem
                ss.ss_size = size
                ss.ss_flags = 0
                if sigaltstack(&ss, nil) != 0 {
                    NSLog("[CRASH] sigaltstack 失败，栈溢出类崩溃可能仍采不到栈")
                }
            }
        }

        // v3.9.10 fix：`signal()` 无法指定 SA_ONSTACK，改用 sigaction；取不到就退回 signal 兜底。
        var action = sigaction()
        action.__sigaction_u.__sa_handler = qlCrashSignalHandler
        action.sa_flags = SA_ONSTACK | SA_RESTART
        sigemptyset(&action.sa_mask)
        for s in sigs {
            if sigaction(s, &action, nil) != 0 {
                signal(s, qlCrashSignalHandler)
            }
        }
        HangWatchdog.shared.refreshSettings()
    }

    /// 启动时若有未上报崩溃 → 异步 POST，成功删除本地文件
    /// v3.1.8 fix: 恢复 @MainActor（async 函数不会阻塞启动线程），
    /// 解决 [String:Any] 跨 actor Sendable 不兼容问题
    /// v3.6.0：统一走新诊断口 POST /api/diag/report（src/diag_api.py）；
    ///         崩溃事件进诊断离线队列 → 失败保留本地文件 + 队列，下次启动补传；
    ///         新口不可用时回退旧口 /api/logs/crash（老后端兜底，不出现「升级后崩溃上报全丢」）。
    @MainActor
    static func flushPending(auth: AuthStore) async {
        // v3.9.10 fix ①：**先落盘，再联网**。原来顺序是「await 联网补传（可能数秒）→ 再读文件入队」，
        // 这个窗口期里若又崩一次：新崩溃覆盖 crash_pending.json，而上一条既没进队列也没留在磁盘
        // → 启动即崩的崩溃循环里，每一条崩溃都会这样丢掉（服务端永远收不到，正是历史遗留的疑点）。
        // v3.9.10 fix ⑤（审查抓到）：崩溃文件的读盘/解析/入队整体移出主线程——原来每次冷启动
        // 带积压时，主线程要串行做 3~5 次同步读盘 + JSON 解码（pending ≤50 条 × 4000 字栈），
        // 栈越大启动越白屏。“先落盘再联网”的顺序不受影响。
        let events = await Task.detached(priority: .utility) { persistCrashFiles() }.value
        DiagnosticsUploader.attach(auth: auth)
        DiagnosticsEnv.refresh()
        // v3.9.10 fix ⑥（审查抓到）：判「已上报」必须基于「确实进过队列的 id」。
        // 原判据只看「现在队列里没有这些 id」——但磁盘写失败、或队列文件被判坏隔离时，
        // id 根本进不去，队列同样「没有」→ 误判成上报成功 → 删掉本地崩溃文件（本地与队列双失）。
        let queuedIDs = Set(await DiagnosticsStore.pendingEventsAsync().map { $0.id })
        let notQueuedCount = events.filter { !queuedIDs.contains($0.id) }.count
        // v3.6.0：再把离线队列（含刚入队的崩溃）补传
        _ = await DiagnosticsUploader.flushPending()
        guard !events.isEmpty else { return }

        // v3.9.10 fix ②：本地文件只在「**这条事件**确实已出队」时才删。
        // 原来判 `first.sent > 0` —— 那可能只是队列里别的 hang 事件发成功了，而本崩溃所在批次失败
        // （见 uploader 的队头阻塞问题）→ 本地原始证据被误删，只剩队列里那份上传不出去的副本。
        // 注意：不能写 `(cond) && await f()` —— await 不能出现在非赋值运算符右侧（CI run 491 实踩）
        let uploadedAfterFlush = await allUploaded(events)
        var uploaded = (notQueuedCount == 0) && uploadedAfterFlush
        if !uploaded {
            NSLog("[CRASH] 诊断口上报失败（或 %d 条未成功落队列），2s 后重试一次；本地上报文件与队列均保留。", notQueuedCount)
            try? await Task.sleep(for: .seconds(2))
            _ = await DiagnosticsUploader.flushPending()
            let retried = await allUploaded(events)
            uploaded = (notQueuedCount == 0) && retried
        }
        if uploaded {
            removeLocalCrashFiles()
            return
        }
        // v3.6.0 兜底：旧口 /api/logs/crash（老后端仍在线时至少落一份）
        if let body = legacyCrashBody(),
           ((try? await auth.json("/api/logs/crash", method: "POST", body: body))?["ok"] as? Bool ?? false) {
            DiagnosticsStore.removePending(ids: events.map { $0.id })   // 防下次补传重复
            removeLocalCrashFiles()
            NSLog("[CRASH] 已回退旧口 /api/logs/crash 上报成功。")
            return
        }
        NSLog("[CRASH] 新旧口均失败，文件与队列保留待下次启动重试（不丢栈）。")
    }

    /// 这些事件是否都已不在待上报队列里（= 确实上报出去了）
    /// v3.9.10：改 async 读（不再在主线程 ioQueue.sync 整包解码），且**必须**配合调用方的
    /// 「确实进过队列」判定一起用（否则会把从未入队的事件误判成已上报）。
    nonisolated private static func allUploaded(_ events: [DiagEvent]) async -> Bool {
        let ids = Set(events.map { $0.id })
        let pending = await DiagnosticsStore.pendingEventsAsync()
        return !pending.contains { ids.contains($0.id) }
    }

    /// 读本机崩溃文件（异常 handler 的 crash_pending.json + 信号 handler 的 crash_pending_sig.json）
    /// → 入离线队列并返回入队的事件。**必须无网络、无 await**（见 flushPending 注释）。
    nonisolated private static func persistCrashFiles() -> [DiagEvent] {
        var out: [DiagEvent] = []
        let stackText = readCrashStack()
        for path in [qlCrashFilePath(), qlCrashSigFilePath()] {
            guard FileManager.default.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // v3.9.10 fix ③：解析失败不再直接删文件（原来 removeItem → 崩溃静默丢失、原文也没了）。
                // 把原文当 stack 入队，并把坏文件改名留证。
                if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
                    // ts 取文件 mtime（跨启动稳定）——用 Date() 会让同一份坏文件每次启动算出新 id 反复入队
                    out.append(DiagnosticsStore.recordCrash(type: "Unparsed", detail: "",
                                                            stack: raw, ts: fileStamp(path)))
                }
                let quarantine = path + ".bad"
                try? FileManager.default.removeItem(atPath: quarantine)
                try? FileManager.default.moveItem(atPath: path, toPath: quarantine)
                NSLog("[CRASH] 崩溃文件解析失败，已按原文入队并隔离为 %@", quarantine)
                continue
            }
            let type = (obj["type"] as? String) ?? "Unknown"
            let detail = (obj["detail"] as? String) ?? ""
            let ts = (obj["ts"] as? Double) ?? fileStamp(path)
            out.append(DiagnosticsStore.recordCrash(type: type, detail: detail,
                                                    stack: stackText, ts: ts))
        }
        return out
    }

    /// 崩溃文件的写入时刻（mtime）。用于「文件里没带 ts」时的回落：mtime 跨启动恒定，
    /// 崩溃事件 id 才会稳定（否则每次冷启动都算成一条新崩溃，反复入队/重复上报）。
    nonisolated private static func fileStamp(_ path: String) -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return ((attrs?[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970
    }

    /// crash_stack.txt（信号 handler 用 backtrace_symbols_fd 写）——容错解码：
    /// 符号名含非 UTF-8 字节时 `String(contentsOfFile:encoding:.utf8)` 会抛错，被 try? 吞掉后整段栈静默丢弃。
    nonisolated private static func readCrashStack() -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: qlCrashStackPath())) else { return "" }
        let text = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
        return String(text.prefix(8000))
    }

    /// 旧口 /api/logs/crash 的 body（老后端兜底）
    private static func legacyCrashBody() -> [String: Any]? {
        var body: [String: Any] = [:]
        for path in [qlCrashFilePath(), qlCrashSigFilePath()] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                body = obj
                break
            }
        }
        guard !body.isEmpty else { return nil }
        body["app"] = "qingliao-ios"
        body["platform"] = "iOS"
        body["os"] = UIDevice.current.systemVersion
        body["device"] = DiagnosticsEnv.hardwareModel()
        if let info = Bundle.main.infoDictionary {
            body["version"] = (info["CFBundleShortVersionString"] as? String) ?? ""
        }
        var stack = (body["detail"] as? String) ?? ""
        let stackText = readCrashStack()
        if !stackText.isEmpty { stack = stack.isEmpty ? stackText : stack + "\n" + stackText }
        if !stack.isEmpty { body["stack"] = String(stack.prefix(8000)) }
        return body
    }

    /// v3.6.0：上报成功 → 清本地崩溃文件（下次启动不再提示）。
    /// v3.9.10：三个文件一起清（异常 json / 信号 json / 栈），否则残文件会让「上次异常退出」永远弹。
    private static func removeLocalCrashFiles() {
        for p in [qlCrashFilePath(), qlCrashSigFilePath(), qlCrashStackPath()] {
            try? FileManager.default.removeItem(atPath: p)
        }
    }
}

// MARK: - v3.4.25 本地崩溃日志：下次启动提示 + 设置页查看/导出

extension CrashReporter {
    /// v3.4.25：本地是否留有未读崩溃日志（三个文件任一存在）
    /// v3.9.10：补上信号 handler 写的 crash_pending_sig.json（否则信号类崩溃在读侧不可见）
    static func hasPendingLog() -> Bool {
        for p in [qlCrashFilePath(), qlCrashSigFilePath(), qlCrashStackPath()] where
            FileManager.default.fileExists(atPath: p) {
            return true
        }
        return false
    }

    /// v3.4.25：读取最近一次崩溃日志全文（类型/时间/detail + crash_stack.txt 调用栈）。
    /// 文件被 flushPending 上报成功后删除时，回退启动时留存的 UserDefaults 快照
    /// （qingliao_last_crash_log，RootView onAppear 写入），保证设置页随时可回查。
    static func latestLogText() -> String {
        var out = ""
        // v3.9.10：异常 json 优先，其次信号 json（两份都可能存在——abort 型崩溃会写两份）
        for path in [qlCrashFilePath(), qlCrashSigFilePath()] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = (obj["type"] as? String) ?? "Unknown"
            let detail = (obj["detail"] as? String) ?? ""
            let ts = (obj["ts"] as? Double) ?? 0
            var head = "类型: " + type
            if ts > 0 {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                head += "  时间: " + f.string(from: Date(timeIntervalSince1970: ts))
            }
            let block = head + "\n" + detail
            out = out.isEmpty ? block : out + "\n---\n" + block
        }
        let s = readCrashStack()
        if !s.isEmpty { out = out.isEmpty ? s : out + "\n" + s }
        if out.isEmpty {
            out = UserDefaults.standard.string(forKey: "qingliao_last_crash_log") ?? ""
        }
        return out
    }

    /// v3.4.25：标记已读（用户点「忽略」或已导出）→ 删除本地崩溃文件，下次启动不再弹窗
    static func markAsRead() {
        // v3.9.10：只清展示用文件。事件已由 persistCrashFiles 入离线队列（进程内即时、无网络），
        // 所以「点忽略」不会再像以前那样把一条还没入队/上报的崩溃直接删掉丢失。
        for p in [qlCrashFilePath(), qlCrashSigFilePath(), qlCrashStackPath()] {
            try? FileManager.default.removeItem(atPath: p)
        }
    }
}
