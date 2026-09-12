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
        // v3.9.10 fix（审查抓到）：防重入置位必须**在 await 之前**。上一版把同步的 pendingEvents()
        // 换成 async 后，「检查 → 置位」之间多出一个挂起点：手动上报与看门狗自动上报可同时通过
        // 检查、各持同一份快照各发一遍 → 服务端重复、sent 与统计双计。
        flushing = true
        defer { flushing = false }
        DiagnosticsEnv.refresh()
        // v3.9.10：I/O 走 async（不在主线程同步读写磁盘，见 DiagnosticsStore 的说明）
        let pending = await DiagnosticsStore.pendingEventsAsync()
        guard !pending.isEmpty else {
            // v3.9.10：空队列也算一次「上报尝试」——诊断页据此显示「上次上报」时间与结果
            await DiagnosticsStore.recordUploadResultAsync(ok: true, sent: 0, message: "无待上报记录")
            return note(DiagUploadResult(ok: true, sent: 0, message: "无待上报记录", latencyMs: 0))
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        var sent = 0
        var failure: String?
        // v3.9.10 fix：上行前按通道裁剪（**只裁上行副本**，本地队列/历史仍留完整 4000 字栈）。
        // 原实现里「单条超限的事件」会独占一块并突破 relay 的 URL 长度上限 → 该块必然失败，
        // 又因为 capEvents 按 ts 升序保留、它是队头 → 之后每一轮 flush 都死在它身上，
        // 后面所有事件永久发不出去（队头阻塞，崩溃事件尤其容易命中）。
        // 裁剪 + 切块的 JSON 编码开销也移出主线程（每条事件会被编码多次）
        let budget = Self.perEventBudget
        let batches = await Task.detached(priority: .utility) { () -> [[DiagEvent]] in
            let wire = pending.map { wireClamp($0, budget: budget) }
            return chunk(wire)
        }.value
        for batch in batches {
            do {
                let j = try await auth.json("/api/diag/report", method: "POST",
                                            body: DiagnosticsPayload.batchBody(batch))
                guard (j["ok"] as? Bool) == true else {
                    failure = failure ?? "后端返回失败"
                    continue   // v3.9.10 fix：原来是 break —— 一块失败就停掉整轮，坏事件会永久堵住队列
                }
                await DiagnosticsStore.removePendingAsync(ids: batch.map { $0.id })
                sent += (j["stored"] as? Int) ?? batch.count
            } catch {
                failure = failure ?? error.localizedDescription
                continue
            }
        }
        let ms = elapsedMs(since: t0)
        if let failure {
            if sent > 0 {
                NSLog("[DIAG] 已上报 \(sent)/\(pending.count) 条，余下已缓存（\(failure)）")
                let msg = "已上报 \(sent)/\(pending.count) 条，余下已缓存"
                // v3.9.10：部分成功时返回值与统计口径统一（原来 stats 记 false、返回值 true，
                // 诊断页同一动作会一绿一橙自相矛盾）。语义统一为「是否还有残余未上报」。
                await DiagnosticsStore.recordUploadResultAsync(ok: false, sent: sent, message: msg)
                return note(DiagUploadResult(ok: false, sent: sent, message: msg, latencyMs: ms))
            }
            NSLog("[DIAG] 上报失败：\(failure)（已本地缓存，下次启动补传）")
            let msg = "上报失败（已缓存，下次启动补传）"
            await DiagnosticsStore.recordUploadResultAsync(ok: false, sent: 0, message: msg)
            return note(DiagUploadResult(ok: false, sent: 0, message: msg, latencyMs: ms))
        }
        NSLog("[DIAG] 已上报 \(sent) 条诊断事件（\(ms)ms）")
        let okMsg = "已上报 \(sent) 条（\(ms)ms）"
        await DiagnosticsStore.recordUploadResultAsync(ok: true, sent: sent, message: okMsg)
        return note(DiagUploadResult(ok: true, sent: sent, message: okMsg, latencyMs: ms))
    }

    /// 单条事件的上行体积预算（< 块上限，保证「首条无条件入块」不再突破块上限）
    private static let perEventBudget = 1200

    /// v3.9.10：上行前把单条事件裁进预算——只影响上行副本，本地队列与历史仍保留完整栈。
    /// 崩溃事件的 stack 原样可达 4KB（detail 3000 + crash_stack.txt 8000 经 clamp 到 4000），
    /// 而 relay 把 body 塞进 URL 时还会 base64 膨胀（~3KB body → 4073/4096 字符）。
    nonisolated private static func wireClamp(_ e: DiagEvent, budget: Int) -> DiagEvent {
        if DiagnosticsPayload.encode([e]).count <= budget { return e }
        var e2 = e
        var keep = e.stack.count
        while keep > 0 {
            keep /= 2
            e2.stack = keep > 0 ? String(e.stack.prefix(keep)) + "…(上行截断，本地留全量)" : ""
            if DiagnosticsPayload.encode([e2]).count <= budget { return e2 }
        }
        e2.stack = ""
        e2.summary = DiagnosticsPayload.clamp(e.summary, 120)
        return e2
    }

    /// 按条数 + 字节数切块（relay 通道 URL 长度受限）
    nonisolated private static func chunk(_ events: [DiagEvent],
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
