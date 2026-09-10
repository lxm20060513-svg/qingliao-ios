import Foundation
import Dispatch
import UIKit

// MARK: - v3.6.0 主线程卡顿看门狗（RunLoop observer 版，空闲零开销）
//
// 为什么不用定时器：常驻高频 Timer / 后台线程轮询会一直唤醒主线程，本身就成了耗电与卡顿源。
// 这里用 CFRunLoopObserver 观察主 RunLoop 的休眠边界：
//   afterWaiting（刚睡醒 = 开始处理） → beforeWaiting（要睡了 = 本轮处理结束）
// 两者的时间差 = 主线程「连续工作」时长；超过阈值即记一条 hang。
// App 空闲时 RunLoop 不醒来 → observer 回调根本不触发 → 零开销（无 Timer、无后台线程）。
//
// 局限（如实说明）：RunLoop 长时间卡死不返回时，observer 无法在卡死期间上报，
// 只能等主线程恢复后记录「这一段工作了多久」，因此栈是恢复点的 RunLoop 栈而非卡死帧。
// 对「启动慢 / 列表掉帧 / 大循环阻塞」这类可恢复卡顿定位有效，对完全死锁场景只能记录时长。

final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    /// 默认卡顿阈值（ms）
    static let defaultThresholdMs = 400
    /// 开关（UserDefaults，默认开）
    static let keyEnabled = "qingliao_hang_watchdog"
    /// 阈值（UserDefaults，默认 400ms）
    static let keyThreshold = "qingliao_hang_threshold_ms"

    nonisolated(unsafe) private var observer: CFRunLoopObserver?
    nonisolated(unsafe) private var burstStartNs: UInt64 = 0
    nonisolated(unsafe) private var lastReportNs: UInt64 = 0
    nonisolated(unsafe) private var thresholdMs: Int = HangWatchdog.defaultThresholdMs

    private init() {}

    // MARK: 设置

    static func isEnabled() -> Bool {
        let d = UserDefaults.standard
        if d.object(forKey: keyEnabled) == nil { return true }   // 默认开
        return d.bool(forKey: keyEnabled)
    }

    static func currentThresholdMs() -> Int {
        let v = UserDefaults.standard.integer(forKey: keyThreshold)
        return v > 0 ? v : defaultThresholdMs
    }

    /// 按当前设置启停（设置页改开关/阈值后调用）
    func refreshSettings() {
        thresholdMs = HangWatchdog.currentThresholdMs()
        if HangWatchdog.isEnabled() { start() } else { stop() }
    }

    // MARK: 生命周期（必须在主线程调用）

    func start() {
        guard observer == nil else { return }
        burstStartNs = nowNs()
        let activities: CFRunLoopActivity = [.beforeTimers, .beforeSources, .afterWaiting, .beforeWaiting]
        let obs = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
                                                     activities.rawValue,
                                                     true,     // repeats
                                                     0) { [weak self] _, activity in
            self?.handle(activity)
        }
        guard let obs else { return }
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, CFRunLoopMode.commonModes)
        NSLog("[DIAG] 卡顿看门狗已启动，阈值 \(thresholdMs)ms")
    }

    func stop() {
        if let obs = observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), obs, CFRunLoopMode.commonModes)
        }
        observer = nil
    }

    // MARK: 核心

    private func handle(_ activity: CFRunLoopActivity) {
        let now = nowNs()
        switch activity {
        case .afterWaiting:
            // 主线程刚睡醒 → 从这里开始计一段「连续工作」
            burstStartNs = now
        case .beforeWaiting:
            // 主线程要睡了 → 本段工作时长 = now - 醒来时刻
            let busy = now &- burstStartNs
            checkStall(busy, now: now)
            burstStartNs = now
        default:
            if burstStartNs == 0 { burstStartNs = now }
        }
    }

    private func checkStall(_ busyNs: UInt64, now: UInt64) {
        let ms = Int(busyNs / 1_000_000)
        guard ms >= thresholdMs else { return }
        // 去抖：5s 内只记一条（避免连续卡顿刷爆队列/磁盘）
        guard now &- lastReportNs > 5_000_000_000 else { return }
        lastReportNs = now
        let stack = Thread.callStackSymbols.prefix(24).joined(separator: "\n")
        let duration = ms
        // 记录 + 机会性上报（未登录则只在本地攒着）
        Task { @MainActor in
            DiagnosticsEnv.refresh()
            DiagnosticsStore.recordHang(durationMs: duration, stack: stack)
            NSLog("[DIAG] 检测到主线程卡顿 \(duration)ms，已记录")
            await DiagnosticsUploader.flushPending()
        }
    }

    private func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}
