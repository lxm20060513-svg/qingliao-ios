import Foundation
import Darwin
import Dispatch
import UIKit

// MARK: - 主线程卡顿看门狗（v3.6.1：RunLoop 计时 + 独立线程抓真实栈 + 前台门控）
//
// v3.6.0 的问题（上线后实测，日志见后端 data/diag/reports.jsonl）：
//  ① 栈没用：原来只在「主线程 RunLoop 恢复点」调 Thread.callStackSymbols()，取到的必然是
//     observer 回调 → handle → checkStall 这条「上报链」自己的栈。铁证：先后 6 条上报
//     （跨 3.5.1/3.5.2 两个包、耗时 404ms ~ 118685ms 差别巨大）堆栈逐字节相同，
//     且同包内所有事件的 4 个 App 帧偏移完全一致 —— 卡顿点不可能恒定，只有上报链恒定。
//  ② 假阳性：App 退后台 / 被系统挂起期间主 RunLoop 不跑，恢复后 observer 会把整段挂起时长
//     算成「主线程连续繁忙」（实测 118685ms / 51136ms 这类值，用户当时并无 2 分钟冻结体感）。
//
// 本版改法：
//  ① 计时不变（observer 只在「睡醒 / 要睡」两个边界记时间，空闲不唤醒主线程）；
//  ② 新增独立监控线程：发现主线程「繁忙」超过阈值 → thread_suspend 主线程 → thread_get_state
//     取 pc/fp/lr → 手工沿 frame pointer 链抓真实栈 → thread_resume，连采 3 次取多条样本。
//     采集窗口内不做任何堆分配（地址缓冲在挂起前预分配、逐地址 dladdr 不分配），
//     避免与被挂起线程抢分配器锁造成死锁；所有解引用都先校验落在主线程栈区间内，不会野指针崩溃。
//  ③ 前台门控：只有「前台活跃且 applicationState == .active」的繁忙段才记为卡顿，
//     退到后台即清零繁忙起点，后台/挂起时长一律不计。
//
// 局限（如实说明）：
//  · Release 包内没有本地符号，上报里是「镜像 + 偏移」（如 Qingliao +1674404），
//    要还原函数名需要构建产物里的 dSYM / 符号文件（调试包可直接 atos 符号化）。
//  · 同一繁忙段只采样一轮（去抖 5s），完全死锁（主线程永不回到 RunLoop）仍无法上报，只保证不误报。
//  · 前台有 250ms 心跳（后台不跑）：常驻 Timer 的取舍 —— 不心跳就无法发现「卡死期间」的主线程，
//    4 次/秒的原子读取开销可忽略，且仅在启用开关且前台时运行。

final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    /// 默认卡顿阈值（ms）
    static let defaultThresholdMs = 400
    /// 开关（UserDefaults，默认开）
    static let keyEnabled = "qingliao_hang_watchdog"
    /// 阈值（UserDefaults，默认 400ms）
    static let keyThreshold = "qingliao_hang_threshold_ms"

    // MARK: 参数

    /// 上报栈总长上限：蜂窝 relay 走 URL（≤4096 字符），必须留余量
    private static let maxReportChars = 1800
    /// 单次卡顿采样轮数 / 采样间隔
    private static let sampleRounds = 3
    private static let sampleGapMs = 150
    /// 单条样本最多帧数（从栈顶往下取）
    private static let maxFramesPerSample = 12
    /// 监控线程心跳间隔
    private static let tickMs = 250
    /// 同一繁忙段的采样冷却（跑一次够用，别持续抓栈）
    private static let reportCooldownNs: UInt64 = 5_000_000_000
    /// 面包屑条数上限
    private static let maxBreadcrumbs = 16

    // MARK: 状态（observer = 主线程写；监控线程读；均由 lock 保护，临界区只有几条赋值）

    private let lock = NSLock()
    private var observer: CFRunLoopObserver?
    private var ticker: DispatchSourceTimer?
    private let monitorQueue = DispatchQueue(label: "qingliao.diag.hang.monitor", qos: .utility)
    private var notes: [NSObjectProtocol] = []

    private var thresholdMs = HangWatchdog.defaultThresholdMs
    private var busySinceNs: UInt64 = 0
    private var startedNs: UInt64 = 0
    private var inForeground = true
    private var lastReportNs: UInt64 = 0
    private var sampledThisBurst = false
    private var sampling = false
    private var samples: [String] = []
    /// v3.9.10：采样归属代次。监控线程采完 ~300ms 才写回，而主线程可能在写回前就结束了这一段
    /// （甚至进入下一条卡顿）→ 旧样本会挂到新的卡顿上。样本带上采样时的代次，只认同一代。
    private var burstId: UInt64 = 0
    private var samplesBurstId: UInt64 = 0
    /// v3.9.10：完全死锁兜底是否已上报（一段繁忙只报一次；繁忙段结束时复位）
    private var deadlockReported = false
    /// v3.9.10：连续繁忙超过该时长仍未恢复 → 判定「主线程不会回来了」，由监控线程直接入队
    private static let hardStallNs: UInt64 = 2_000_000_000
    private var breadcrumbs: [String] = []

    /// 主线程 mach port 与栈区间（采样合法性校验用）
    private var mainPort: mach_port_t = 0
    private var stackLow: UInt64 = 0
    private var stackHigh: UInt64 = 0

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

    /// 按当前设置启停（设置页改开关/阈值后调用，须在主线程）
    func refreshSettings() {
        lock.lock()
        thresholdMs = HangWatchdog.currentThresholdMs()
        lock.unlock()
        if HangWatchdog.isEnabled() { start() } else { stop() }
    }

    /// 主线程面包屑（O(1)，只写内存环形缓冲）
    /// 用途：卡顿上报时带上「卡顿前主线程干过什么」。
    /// 红线：这里只写动作名，禁止写聊天内容 / 凭据 / 用户输入。
    static func breadcrumb(_ text: String) {
        shared.appendBreadcrumb(text)
    }

    // MARK: 生命周期（必须在主线程调用）

    func start() {
        guard observer == nil else { return }
        captureMainThreadInfo()
        watchForegroundState()
        let active = (UIApplication.shared.applicationState == .active)
        lock.lock()
        thresholdMs = HangWatchdog.currentThresholdMs()
        startedNs = DispatchTime.now().uptimeNanoseconds
        busySinceNs = nowNs()
        inForeground = active
        sampledThisBurst = false
        lock.unlock()

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
        startTicking()
        appendBreadcrumb("看门狗启动 阈值\(thresholdMs)ms")
        NSLog("[DIAG] 卡顿看门狗已启动，阈值 \(thresholdMs)ms（真实栈采样）")
    }

    func stop() {
        if let obs = observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), obs, CFRunLoopMode.commonModes)
        }
        observer = nil
        ticker?.cancel()
        ticker = nil
        if !notes.isEmpty {
            notes.forEach { NotificationCenter.default.removeObserver($0) }
            notes = []
        }
        lock.lock()
        busySinceNs = 0
        samples = []
        sampledThisBurst = false
        lock.unlock()
    }

    // MARK: 主线程边界（observer 回调，主线程）

    private func handle(_ activity: CFRunLoopActivity) {
        let now = nowNs()
        switch activity {
        case .afterWaiting:
            // 主线程刚睡醒 → 从这里开始计一段「连续工作」
            lock.lock()
            busySinceNs = now
            sampledThisBurst = false
            samples = []
            burstId &+= 1          // 新一段开始（旧样本即便后到也不会被认领）
            deadlockReported = false
            lock.unlock()
        case .beforeWaiting:
            // v3.9.10：影子状态自愈——inForeground 靠 4 个通知维护，一旦错过一次
            // didBecomeActive/willEnterForeground（例如注册时机不当），它会永久停在「非前台」，
            // 之后 tick 永不采样、checkStall 永不执行，而 UI 开关仍显示「已开启」→ 静默漏报。
            // applicationState 只能在主线程读（本回调即在主线程），用它兜底校正一次。
            if UIApplication.shared.applicationState == .active {
                lock.lock()
                inForeground = true
                lock.unlock()
            }
            // 主线程要睡了 → 本段工作时长 = now - 醒来时刻；只有前台活跃才记账
            lock.lock()
            // v3.9.10 fix（真机假阳性根因）：busySinceNs == 0 是「当前没有繁忙段」的**哨兵**，
            // 不是时间戳。前台状态通知回调（见 watchForegroundState）会把它清 0，若那一拍紧接着
            // 走到 beforeWaiting，`now &- 0` 会算出「开机至今」→ 上报一条时长以小时计的假卡顿
            //（历史上 118685ms / 51136ms 就是这一类）。所以必须先判哨兵。
            let hasBurst = (busySinceNs != 0)
            let busy = hasBurst ? (now &- busySinceNs) : 0
            let fg = inForeground
            let thr = thresholdMs
            busySinceNs = 0
            sampledThisBurst = false
            // v3.9.10 fix：先把「这段是否已由死锁兜底上报过」取出来再清零。
            // 否则主流路径会在恢复后又补一条（真死锁常十几秒，早过了 5s 冷却）→ 同源卡顿两条。
            let wasReportedByDeadlock = deadlockReported
            deadlockReported = false
            lock.unlock()
            // applicationState 必须主线程读（observer 回调即在主线程）
            let active = fg && (UIApplication.shared.applicationState == .active)
            if active && hasBurst && !wasReportedByDeadlock {
                checkStall(busy, threshold: thr, now: now)
            }
        default:
            lock.lock()
            if busySinceNs == 0 { busySinceNs = now }
            lock.unlock()
        }
    }

    private func checkStall(_ busyNs: UInt64, threshold: Int, now: UInt64) {
        let ms = Int(busyNs / 1_000_000)
        guard ms >= threshold else { return }
        // v3.9.10：冷却判定与写入一并放进锁（监控线程的兜底路径也会写 lastReportNs，
        // 锁外读写在 TSan 下是 race，且可能读到旧值导致多报/漏报一条）
        lock.lock()
        let cooldownPassed = (now &- lastReportNs) > Self.reportCooldownNs
        if cooldownPassed { lastReportNs = now }
        lock.unlock()
        guard cooldownPassed else { return }

        lock.lock()
        // v3.9.10：只认「本段」的样本（代次匹配）。监控线程采完写回时这段可能已结束，
        // 那些样本属于上一段（往往已是空闲 mach_msg_trap），挂到本条卡顿上就是假栈。
        let got = (samplesBurstId == burstId) ? samples : []
        let crumbs = breadcrumbs
        samples = []
        lock.unlock()

        let stack = renderReport(durationMs: ms, samples: got, crumbs: crumbs)
        Task { @MainActor in
            DiagnosticsEnv.refresh()
            DiagnosticsStore.recordHang(durationMs: ms, stack: stack)
            NSLog("[DIAG] 检测到主线程卡顿 \(ms)ms（采样 \(got.count) 条）已记录")
            await DiagnosticsUploader.flushPending()
        }
    }

    // MARK: 监控线程（发现卡死 → 抓主线程真实栈）

    private func startTicking() {
        guard ticker == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: monitorQueue)
        let interval = DispatchTimeInterval.milliseconds(Self.tickMs)
        t.schedule(deadline: .now() + interval, repeating: interval,
                   leeway: .milliseconds(Self.tickMs / 2))
        t.setEventHandler { [weak self] in self?.tick() }
        ticker = t
        t.resume()
    }

    private func tick() {
        let now = nowNs()
        lock.lock()
        let busy = busySinceNs
        let thr = UInt64(max(50, thresholdMs)) * 1_000_000
        let due = busy != 0 && inForeground && !sampling && !sampledThisBurst && (now &- busy) >= thr
        if due {
            sampling = true
            sampledThisBurst = true
        }
        let sampledBurst = burstId
        // v3.9.10 fix（审查抓到的自伤）：死锁兜底**不能挂在 due 后面**——due 要求
        // !sampledThisBurst，而 sampledThisBurst 只在主线程的 afterWaiting/beforeWaiting 复位；
        // 「完全死锁」的定义就是主线程再也不回 RunLoop → 一轮采样后 sampledThisBurst 恒为 true，
        // 兜底分支永远到不了（等于没修）。这里改成独立门控：只要「繁忙够久 + 还没报过」就判定。
        let stuckDue = (busy != 0 && inForeground && !sampling && !deadlockReported
                        && (now &- busy) >= Self.hardStallNs)
        lock.unlock()
        guard due || stuckDue else { return }

        var out: [String] = []
        if due {
            for i in 0..<Self.sampleRounds {
                out.append(sampleMainThread())
                if i < Self.sampleRounds - 1 { usleep(UInt32(Self.sampleGapMs) * 1000) }
            }
        }
        lock.lock()
        // v3.9.10：写回前必须仍是「同一段且仍然繁忙」——采样耗时 ~300ms，这期间主线程可能已经
        // 结束这一段（甚至进入下一段）。旧样本（往往已是空闲 mach_msg_trap）挂到新卡顿上就是假栈。
        let sameBurst = (busySinceNs != 0 && burstId == sampledBurst)
        if sameBurst && !out.isEmpty {
            if samples.isEmpty { samples = out } else { samples.append(contentsOf: out) }
            samplesBurstId = sampledBurst
        }
        sampling = false
        lock.unlock()
        // due 路径要求同一段仍繁忙；stuckDue 路径（主线程已不回来）自然允许段未结束
        guard sameBurst || (stuckDue && busy != 0) else { return }

        // v3.9.10：**完全死锁兜底**。主线程若永不回到 RunLoop，observer 的 beforeWaiting 永不触发，
        // checkStall 也就永远不会执行（即 v3.6.x 的「完全死锁无法上报」）。可此刻监控线程手里已经
        // 握着「持续了多久 + 真实栈」，于是由它**自己**把证据落进离线队列（DiagnosticsStore 走 ioQueue
        // 串行队列，不依赖主线程），下次启动 flushPending 补传。只入队不联网——主线程卡着也发不出去。
        let now2 = nowNs()
        lock.lock()
        let busyStart = busySinceNs
        let stuck = busyStart != 0 && !deadlockReported && (now2 &- busyStart) >= Self.hardStallNs
        var got: [String] = []
        var crumbs: [String] = []
        if stuck {
            deadlockReported = true
            // 与主线程路径共用冷却，避免主线程恢复后 checkStall 再补一条重复的
            lastReportNs = now2
            got = samples
            crumbs = breadcrumbs
            samples = []
        }
        lock.unlock()
        guard stuck else { return }

        let ms = Int((now2 &- busyStart) / 1_000_000)
        let stack = renderReport(durationMs: ms, samples: got, crumbs: crumbs)
        DiagnosticsStore.recordHang(durationMs: ms, stack: stack)
        NSLog("[DIAG] 主线程疑似完全死锁 \(ms)ms（采样 \(got.count) 条）已入离线队列，下次启动补传")
    }

    /// 抓一次主线程栈：suspend → thread_get_state → 手工 FP 链 → resume
    private func sampleMainThread() -> String {
        #if arch(arm64)
        guard mainPort != 0, stackHigh > stackLow else { return "(无主线程栈信息)" }
        // 地址缓冲必须在挂起之前分配：挂起窗口内一律不做堆分配
        var addrs = [UInt64](repeating: 0, count: Self.maxFramesPerSample)
        var n = 0
        if thread_suspend(mainPort) == KERN_SUCCESS {
            var st = arm_thread_state64_t()
            var cnt = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<Int32>.size)
            let ok = withUnsafeMutablePointer(to: &st) { p -> Bool in
                p.withMemoryRebound(to: natural_t.self, capacity: Int(cnt)) { np in
                    // thread_state_flavor_t 是 Int32（ARM_THREAD_STATE64 是 UInt32 常量），必须显式转换
                    thread_get_state(mainPort, thread_state_flavor_t(ARM_THREAD_STATE64), np, &cnt) == KERN_SUCCESS
                }
            }
            if ok {
                let pc = UInt64(st.__pc)
                let lr = UInt64(st.__lr)
                let fp0 = UInt64(st.__fp)
                if pc != 0 { addrs[n] = pc; n += 1 }
                if lr != 0 && lr != pc && n < addrs.count { addrs[n] = lr; n += 1 }
                var fp = fp0
                var steps = 0
                // FP 链：*(fp) = 上一层 fp，*(fp+8) = 返回地址；只读主线程栈区间内的地址
                while n < addrs.count && steps < 64 && fp >= stackLow && fp < stackHigh {
                    let next = readU64(fp)
                    let ret = readU64(fp &+ 8)
                    if ret == 0 || next <= fp { break }
                    addrs[n] = ret; n += 1
                    fp = next
                    steps += 1
                }
            }
            thread_resume(mainPort)
        }
        guard n > 0 else { return "(采样失败)" }
        return (0..<n).map { frameText(addrs[$0]) }.joined(separator: "\n")
        #else
        return "(仅 arm64 支持真实栈采样)"
        #endif
    }

    /// 只读对齐且落在主线程栈区间内的地址（越界一律返回 0 → 终止走链）
    private func readU64(_ addr: UInt64) -> UInt64 {
        guard addr % 8 == 0, addr >= stackLow, addr &+ 8 <= stackHigh else { return 0 }
        guard let p = UnsafeRawPointer(bitPattern: UInt(addr)) else { return 0 }
        return p.load(as: UInt64.self)
    }

    /// 地址 → 「镜像 + 偏移」。Release 包内无本地符号，偏移即定位依据（配 dSYM 可还原函数名）。
    private func frameText(_ addr: UInt64) -> String {
        guard let raw = UnsafeRawPointer(bitPattern: UInt(addr)) else {
            return String(format: "0x%llx", addr)
        }
        var info = Dl_info()
        guard dladdr(raw, &info) != 0, let fname = info.dli_fname else {
            return String(format: "0x%llx (未映射)", addr)
        }
        let image = (String(cString: fname) as NSString).lastPathComponent
        let base = UInt64(UInt(bitPattern: info.dli_fbase))
        let off = base != 0 ? (addr &- base) : addr
        if let sname = info.dli_sname {
            return "\(image) +\(off) \(String(cString: sname))"
        }
        return "\(image) +\(off)"
    }

    /// 一次性抓主线程 port 与栈区间（必须在主线程调用）
    /// 有效栈地址区间 = [栈顶 - 栈大小, 栈顶]（栈自高向低增长）
    private func captureMainThreadInfo() {
        let pt = pthread_self()
        mainPort = pthread_mach_thread_np(pt)
        // pthread_get_stackaddr_np 返回非可选指针（栈顶）；拿不到栈大小就整体置 0 = 不采样
        let sp = pthread_get_stackaddr_np(pt)
        let top = UInt64(UInt(bitPattern: sp))
        let size = UInt64(pthread_get_stacksize_np(pt))
        guard top > size else {
            stackLow = 0
            stackHigh = 0
            return
        }
        stackHigh = top
        stackLow = top - size
    }

    // MARK: 前台门控

    private func watchForegroundState() {
        guard notes.isEmpty else { return }
        let nc = NotificationCenter.default
        let pairs: [(Notification.Name, Bool)] = [
            (UIApplication.didEnterBackgroundNotification, false),
            (UIApplication.willResignActiveNotification, false),
            (UIApplication.didBecomeActiveNotification, true),
            (UIApplication.willEnterForegroundNotification, true),
        ]
        for (name, fg) in pairs {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.inForeground = fg
                // 状态切换即清零：挂起/转场时长绝不记成「主线程繁忙」
                self.busySinceNs = 0
                self.sampledThisBurst = false
                self.samples = []
                self.lock.unlock()
                self.appendBreadcrumb(fg ? "进入前台" : "退到后台/非活跃")
            }
            notes.append(token)
        }
    }

    private func appendBreadcrumb(_ text: String) {
        lock.lock()
        // v3.9.10：startedNs == 0 是「看门狗未启动」的哨兵，不能当时间戳算
        // （否则面包屑会显示「开机至今」如 12345s —— 与已修的 busySinceNs 同型错误）
        let sec = startedNs == 0 ? -1 : Int((nowNs() &- startedNs) / 1_000_000_000)
        breadcrumbs.append(sec < 0 ? "-- \(text.prefix(60))" : "\(sec)s \(text.prefix(60))")
        if breadcrumbs.count > Self.maxBreadcrumbs {
            breadcrumbs.removeFirst(breadcrumbs.count - Self.maxBreadcrumbs)
        }
        lock.unlock()
    }

    // MARK: 上报文本

    private func renderReport(durationMs: Int, samples: [String], crumbs: [String]) -> String {
        // v3.9.10 fix：samples 为空时下面会退化成 Thread.callStackSymbols（= observer→handle→checkStall
        // 这条**上报链自己**的栈），标成 mainThreadSample 会把行号噪声当卡顿点（v3.6.0 曾因此误读整批日志）
        var lines: [String] = [
            samples.isEmpty
                ? "stackSource=runloopRecovery rounds=0（兜底：这是恢复点栈，不是卡死帧，不能用于定位卡顿点）"
                : "stackSource=mainThreadSample rounds=\(samples.count)",
            "state=active threshold=\(thresholdMs)ms duration=\(durationMs)ms",
        ]
        if !crumbs.isEmpty {
            lines.append("--- crumbs ---")
            lines.append(contentsOf: crumbs)
        }
        if samples.isEmpty {
            // 采样失败时的兜底：说清这是「恢复点的 RunLoop 栈」，不能当卡死点用
            lines.append("--- 采样失败：以下为恢复点 RunLoop 栈，仅用于确认看门狗工作正常 ---")
            lines.append(Thread.callStackSymbols.prefix(24).joined(separator: "\n"))
        } else {
            for (i, s) in samples.enumerated() {
                lines.append("--- sample \(i + 1) ---")
                lines.append(s)
            }
        }
        var out = lines.joined(separator: "\n")
        if out.count > Self.maxReportChars {
            out = String(out.prefix(Self.maxReportChars)) + "…(截断)"
        }
        return out
    }

    private func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}
