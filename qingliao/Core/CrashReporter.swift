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

/// POSIX 直写崩溃信息（v2.0.47：路径用 C 数组 strcpy/strcat 拼接，全程无 Swift 分配，
/// 纯 async-signal-safe——String(cString:) 等 Swift 字符串构造会分配内存，handler 里可能死锁）
func qlWriteCrashFile(type: String, detail: String) {
    let escaped = detail
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .prefix(3000)
    let entry = "{\"type\":\"\(type)\",\"detail\":\"\(escaped)\",\"ts\":\(Int(Date().timeIntervalSince1970))}\n"
    let home = getenv("HOME")
    let suffix = "/Documents/crash_pending.json"
    var path = [CChar](repeating: 0, count: 1024)
    if let h = home {
        _ = strcpy(&path, h)
    } else {
        _ = strcpy(&path, "/tmp")
    }
    _ = strcat(&path, suffix)
    let fd = open(&path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    entry.withCString { ptr in
        Darwin.write(fd, ptr, strlen(ptr))
    }
    close(fd)
}

/// signal handler（顶层函数，无捕获；v2.0.48：纯 C 极简写——signal 上下文禁用一切
/// Swift 字符串构造/分配，只写固定格式；完整栈由 NSException handler 负责）
/// v3.4.1：新增同目录 crash_stack.txt——backtrace_symbols_fd 是 async-signal-safe，
/// 信号上下文可直接调用，把含函数名的调用栈写入独立文件（侧载包未 strip，栈可读）。
/// 崩溃定位缺陷根治：此前只记信号号，几十次 Signal(5) 崩溃全部无栈无法定位。
func qlCrashSignalHandler(_ sig: Int32) {
    let home = getenv("HOME")
    var path = [CChar](repeating: 0, count: 1024)   // 栈上数组，无堆分配
    if let h = home {
        _ = strcpy(&path, h)
    } else {
        _ = strcpy(&path, "/tmp")
    }
    _ = strcat(&path, "/Documents/crash_pending.json")
    let fd = open(&path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd >= 0 {
        // v2.0.49：写具体信号号（SIGABRT=6/SIGSEGV=11/SIGBUS=10/SIGILL=4/SIGFPE=8/SIGTRAP=5）。
        // snprintf 是 variadic C 函数 Swift 不导入 → 手动十进制拼接（strcpy/strcat/strlen 全 POSIX signal-safe）
        var buf = [CChar](repeating: 0, count: 128)   // 栈上，无堆分配
        strcpy(&buf, "{\"type\":\"Signal(")
        var idx = strlen(&buf)
        var n = sig
        var digits = [CChar](repeating: 0, count: 12)
        var d = 0
        if n == 0 { digits[d] = 48; d += 1 }
        while n > 0 {
            digits[d] = CChar(48 + n % 10); d += 1; n /= 10
        }
        while d > 0 {
            d -= 1; buf[idx] = digits[d]; idx += 1
        }
        buf[idx] = 41   // )
        buf[idx + 1] = 34   // "
        buf[idx + 2] = 125  // }
        buf[idx + 3] = 10   // \n
        buf[idx + 4] = 0    // 终止
        Darwin.write(fd, buf, idx + 4)
        close(fd)
    }
    // v3.4.1：写调用栈文件（backtrace/backtrace_symbols_fd 均 async-signal-safe）
    var stackPath = [CChar](repeating: 0, count: 1024)
    if let h = home {
        _ = strcpy(&stackPath, h)
    } else {
        _ = strcpy(&stackPath, "/tmp")
    }
    _ = strcat(&stackPath, "/Documents/crash_stack.txt")
    let sfd = open(&stackPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if sfd >= 0 {
        var callstack = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let frames = backtrace(&callstack, 128)
        backtrace_symbols_fd(callstack, frames, sfd)
        close(sfd)
    }
    exit(sig)
}

/// NSException handler（顶层函数，无捕获）
func qlCrashExceptionHandler(_ ex: NSException) {
    let stack = ex.callStackSymbols.prefix(30).joined(separator: "\n")
    qlWriteCrashFile(type: "NSException", detail: "\(ex.name.rawValue): \(ex.reason ?? "")\n\(stack)")
}

enum CrashReporter {
    private static let sigs: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    /// App 启动时安装（必须在 main 早期调用）
    static func install() {
        NSSetUncaughtExceptionHandler(qlCrashExceptionHandler)
        for s in sigs {
            signal(s, qlCrashSignalHandler)
        }
    }

    /// 启动时若有未上报崩溃 → 异步 POST，成功删除本地文件
    /// v3.1.8 fix: 恢复 @MainActor（async 函数不会阻塞启动线程），
    /// 解决 [String:Any] 跨 actor Sendable 不兼容问题
    @MainActor
    static func flushPending(auth: AuthStore) async {
        let path = qlCrashFilePath()
        guard FileManager.default.fileExists(atPath: path) else { return }
        // v2.0.102：崩溃文件含数字 ts 字段，原 [String: String] 强转失败导致 NSException 上报永远丢失
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        var body: [String: Any] = obj
        body["app"] = "qingliao-ios"
        body["platform"] = "iOS"
        body["os"] = UIDevice.current.systemVersion
        body["device"] = UIDevice.current.model
        if let info = Bundle.main.infoDictionary {
            body["version"] = (info["CFBundleShortVersionString"] as? String) ?? ""
        }
        // v3.4.1：后端只落 stack 字段（detail 字段被丢弃）→ 把 NSException detail 并入 stack；
        // 并附带 signal handler 用 backtrace_symbols_fd 写的 crash_stack.txt（含函数名的调用栈）
        var stack = (body["detail"] as? String) ?? ""
        let stackPath = ((path as NSString).deletingLastPathComponent) + "/crash_stack.txt"
        if FileManager.default.fileExists(atPath: stackPath),
           let s = try? String(contentsOfFile: stackPath, encoding: .utf8) {
            stack = stack.isEmpty ? s : stack + "\n" + s
        }
        if !stack.isEmpty {
            body["stack"] = String(stack.prefix(8000))
        }
        let ok = (try? await auth.json("/api/logs/crash", method: "POST", body: body))?["ok"] as? Bool ?? false
        if ok {
            try? FileManager.default.removeItem(atPath: path)
            if FileManager.default.fileExists(atPath: stackPath) {
                try? FileManager.default.removeItem(atPath: stackPath)
            }
        }
    }
}
