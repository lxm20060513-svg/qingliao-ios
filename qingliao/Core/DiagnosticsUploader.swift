import Foundation
import UIKit

// MARK: - v3.6.0 诊断上报（离线队列 → POST /api/diag/report）
//
// 失败策略：上报失败不丢数据——事件留在本机 diag_pending.json，下次启动 / 手动上报时补传。
// 全程不阻塞启动：调用方一律 Task 后台触发（见 RootView.task / HangWatchdog / 诊断页手动按钮）。

/// 一次上报的结果（供诊断页做「结果反馈」）
struct DiagUploadResult: Sendable {
    var ok: Bool
    var sent: Int
    var message: String
    var latencyMs: Int
}

@MainActor
enum DiagnosticsUploader {
    /// 上报用的 AuthStore（登录后 attach；未登录时只在本地攒着，不丢）
    private static var authStore: AuthStore?
    /// 防重入（避免启动补传与卡顿上报并发重复发同一批）
    private static var flushing = false
    private static var lastMessage = ""

    static func attach(auth: AuthStore) {
        authStore = auth
    }

    static var lastResultText: String { lastMessage }

    /// 把本机待上报队列分批 POST /api/diag/report；每批成功后立即出队。
    ///
    /// 为什么要分批：蜂窝下 URLSession 直连失败会走 Safari relay，而 relay 是把请求塞进
    /// URL 的（实测 ~3KB body → 4073 字符，接近 4096 上限）。整包 50 条会超限直接失败，
    /// 因此按「≤5 条且 ≤1.5KB」切块，逐块上报；某块失败即停，余下留在队列等下次补传。
    @discardableResult
    static func flushPending() async -> DiagUploadResult {
        guard let auth = authStore else {
            return note(DiagUploadResult(ok: false, sent: 0,
                                         message: "未登录：已本地缓存，登录后自动补传",
                                         latencyMs: 0))
        }
        if flushing {
            return DiagUploadResult(ok: false, sent: 0, message: "正在上报…", latencyMs: 0)
        }
        DiagnosticsEnv.refresh()
        let pending = DiagnosticsStore.pendingEvents()
        guard !pending.isEmpty else {
            return note(DiagUploadResult(ok: true, sent: 0, message: "无待上报记录", latencyMs: 0))
        }
        flushing = true
        defer { flushing = false }

        let t0 = DispatchTime.now().uptimeNanoseconds
        var sent = 0
        var failure: String?
        for batch in chunk(pending) {
            do {
                let j = try await auth.json("/api/diag/report", method: "POST",
                                            body: DiagnosticsPayload.batchBody(batch))
                guard (j["ok"] as? Bool) == true else {
                    failure = "后端返回失败"
                    break
                }
                DiagnosticsStore.removePending(ids: batch.map { $0.id })
                sent += (j["stored"] as? Int) ?? batch.count
            } catch {
                failure = error.localizedDescription
                break
            }
        }
        let ms = elapsedMs(since: t0)
        if let failure {
            if sent > 0 {
                NSLog("[DIAG] 已上报 \(sent)/\(pending.count) 条，余下已缓存（\(failure)）")
                return note(DiagUploadResult(ok: true, sent: sent,
                                             message: "已上报 \(sent)/\(pending.count) 条，余下已缓存",
                                             latencyMs: ms))
            }
            NSLog("[DIAG] 上报失败：\(failure)（已本地缓存，下次启动补传）")
            return note(DiagUploadResult(ok: false, sent: 0,
                                         message: "上报失败（已缓存，下次启动补传）", latencyMs: ms))
        }
        NSLog("[DIAG] 已上报 \(sent) 条诊断事件（\(ms)ms）")
        return note(DiagUploadResult(ok: true, sent: sent,
                                     message: "已上报 \(sent) 条（\(ms)ms）", latencyMs: ms))
    }

    /// 按条数 + 字节数切块（relay 通道 URL 长度受限）
    private static func chunk(_ events: [DiagEvent],
                              maxCount: Int = 5,
                              maxBytes: Int = 1500) -> [[DiagEvent]] {
        var out: [[DiagEvent]] = []
        var cur: [DiagEvent] = []
        var curBytes = 0
        for e in events {
            let n = DiagnosticsPayload.encode([e]).count
            if !cur.isEmpty && (cur.count >= maxCount || curBytes + n > maxBytes) {
                out.append(cur)
                cur = []
                curBytes = 0
            }
            cur.append(e)
            curBytes += n
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 后端连通性与延迟（诊断页「后端连通性」）
    static func ping() async -> DiagUploadResult {
        guard let auth = authStore else {
            return DiagUploadResult(ok: false, sent: 0, message: "未登录", latencyMs: 0)
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            let j = try await auth.json("/api/diag/ping")
            let ms = elapsedMs(since: t0)
            if (j["ok"] as? Bool) == true {
                return DiagUploadResult(ok: true, sent: 0, message: "正常（\(ms)ms）", latencyMs: ms)
            }
            return DiagUploadResult(ok: false, sent: 0, message: "响应异常", latencyMs: ms)
        } catch {
            return DiagUploadResult(ok: false, sent: 0,
                                    message: "不可达：\(error.localizedDescription)",
                                    latencyMs: elapsedMs(since: t0))
        }
    }

    // MARK: 内部

    private static func elapsedMs(since t0: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000)
    }

    private static func note(_ r: DiagUploadResult) -> DiagUploadResult {
        lastMessage = r.message
        return r
    }
}
