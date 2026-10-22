import Foundation
import MetricKit

// MARK: - v4.0.149 MetricKit 桥（系统侧崩溃 / 卡顿诊断 → 现有诊断队列）
//
// 为什么要它：`CrashReporter`（437 行手写 signal/NSException handler）与
// `DiagnosticsHangWatchdog`（616 行 suspend 主线程 + 手走 frame pointer）是全仓最高危的两段代码，
// 但它们的栈**没有符号**（侧载包不带 dSYM 还原），且 handler 内还要维持 async-signal-safe 的约束。
// MetricKit 由系统在进程外采集并**符号化**，正好补上这两块的证据质量。
//
// 明确的边界（别指望它替代现有实现）：
//   · **不是实时的**：MXDiagnosticPayload 通常在次日、且 App 再次被启动时才投递；
//   · 依赖用户开启「共享 iPhone 分析」，且侧载包能否拿到 payload **待真机核实**；
//   · 因此这里是**新增一条通道**，自研崩溃捕获与看门狗保持不变（它们负责「当场复现」）。
//
// 落点：转成 DiagEvent（kind = metrickit_crash / metrickit_hang）进现有离线队列 ——
// 复用 DiagnosticsUploader 的补传与诊断页展示；用独立 kind 是为了不污染服务端的崩溃/卡顿统计
// （同 recordSelfTest 用 selftest 的理由）。

/// `@unchecked Sendable`：本类**无可变实例状态**（只有一个无状态的 static 单例 + 纯函数），
/// 系统在任意线程回调 `didReceive` 也安全（DiagnosticsStore.enqueue 自身带锁）。
/// 不标的话 Swift 6 会把 `static let shared` 判成「非 Sendable 类型共享可变状态」——CI 实测报过错。
final class MetricKitBridge: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitBridge()

    private static let maxStackChars = 6000

    /// 启动时挂载（幂等：add 同一实例不会重复投递）
    static func install() {
        MXMetricManager.shared.add(shared)
    }

    // 必需方法：性能指标（这里不采集，留空即可 —— 采集会显著增加体积与耗电，收益不高）
    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                record(kind: "metrickit_crash",
                       summary: Self.crashSummary(crash),
                       stack: Self.stackText(crash.callStackTree),
                       durationMs: 0)
            }
            for hang in payload.hangDiagnostics ?? [] {
                let ms = Int(hang.hangDuration.converted(to: .milliseconds).value)
                record(kind: "metrickit_hang",
                       summary: "MetricKit 卡顿 \(ms)ms（系统判定）",
                       stack: Self.stackText(hang.callStackTree),
                       durationMs: ms)
            }
        }
    }

    private func record(kind: String, summary: String, stack: String, durationMs: Int) {
        DiagnosticsStore.enqueue(DiagnosticsPayload.makeEvent(kind: kind,
                                                             env: DiagnosticsStore.env(),
                                                             summary: summary,
                                                             stack: stack,
                                                             durationMs: durationMs))
    }

    private static func crashSummary(_ c: MXCrashDiagnostic) -> String {
        var parts: [String] = ["MetricKit 崩溃"]
        if let t = c.exceptionType { parts.append("exception=\(t)") }
        if let s = c.signal { parts.append("signal=\(s)") }
        if let r = c.terminationReason { parts.append("reason=\(r)") }
        return parts.joined(separator: " · ")
    }

    /// 系统给的调用栈是 JSON（含二进制 UUID 与符号），原样进 stack 字段便于服务端事后还原
    private static func stackText(_ tree: MXCallStackTree) -> String {
        guard let data = try? tree.jsonRepresentation(),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return String(s.prefix(maxStackChars))
    }
}
