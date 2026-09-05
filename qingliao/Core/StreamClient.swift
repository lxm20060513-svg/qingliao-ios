import Foundation
import Observation
import UIKit   // v3.0.81：beginBackgroundTask 延长后台存活

// MARK: - 流式客户端：Safari Relay 版
// 上行：POST /r/stream/start/{uid}（relay 中转，Safari 进程发请求）
// 下行：GET  /r/stream/poll/{uid}/{taskId}/{offset}（路径参数无 query → CFStream 直连）
// 停止：POST /r/stream/stop/{uid}/{taskId}（relay 中转）
// 轮询间隔自适应：0.8s 起 -> 有内容 0.5s -> 连续 3 次空 2.0s；连续失败 10 次停止
// v3.0.57：首 token 思考期空轮从 0.8 分级改为统一 0.25s——首 token 落地后最快 0.25s 拉回渲染
//（原最坏 0.8s），同一模型 TTFT 下首字附加延迟从 ~0.8s 压到 ~0.25s，逼近推送式体验

@MainActor
@Observable
final class StreamClient {
    var content = ""          // 累计全文
    var isStreaming = false
    var isDone = false
    var status = ""
    var errorMessage = ""
    var isAgent = false        // v2.0.96b：Agent 回复标记（工具调用）

    var taskId = ""
    private var offset = 0
    private var failCount = 0
    private var idleStreak = 0
    private var recoverTried = false   // v3.0.31：poll 404（任务丢失）时只尝试 recover 一次
    private var recoverFailTried = false   // v3.0.80：普通失败（网络会话失效）也允许 recover 一次
    private var interval: TimeInterval = 0.25
    private var pollTask: Task<Void, Never>?
    private var onFinished: ((Bool, String) -> Void)?   // (success, errorMessage)
    // v3.0.50 稳定性：代际计数——停止/重启后旧轮询 resume 时丢弃结果，防污染新流
    private var generation = 0
    // v3.0.81：后台任务标识——iOS 挂起前最多续 ~30s，让轮询/recover 有机会完成
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    // v3.3.3：当前流的"发起 user 消息 id"——落库锚点（跨杀后台恢复时也由此传递）。
    // 防延迟完成回调/恢复把旧答 append 到用户新消息之后（错位复读根因，2026-09-04 实据）。
    var pendingUserMsgId: String?

    /// 启动流式请求
    func start(auth: AuthStore, sessionId: String, model: String, provider: String,
               messages: [[String: Any]],
               onFinished: ((Bool, String) -> Void)? = nil) async {
        stopPolling()
        generation += 1   // v3.0.50：废除在途旧轮询代
        content = ""
        offset = 0
        failCount = 0
        idleStreak = 0
        recoverTried = false
        interval = 0.25
        isStreaming = true
        isDone = false
        status = ""
        errorMessage = ""
        isAgent = false
        self.onFinished = onFinished

        // 记录当前流式会话（relay uid 推导用）
        auth.currentStreamSessionId = sessionId

        do {
            let tid = try await auth.streamStart(sessionId: sessionId, model: model,
                                                 provider: provider, messages: messages)
            taskId = tid
            startPolling(auth: auth)
            // v3.0.81：注册后台任务，延长 iOS 挂起前的存活时间（最多 ~30s）
            beginBgTask()
        } catch APIError.relayCancelled {
            finish(success: false, error: "已取消")
        } catch {
            finish(success: false, error: "启动失败：\(error.localizedDescription)")
        }
    }

    /// 主动停止
    func stop(auth: AuthStore) {
        stopPolling()
        generation += 1   // v3.0.50：停止后旧 pollOnce resume 不再写状态
        if !taskId.isEmpty, !isDone {
            Task { await auth.streamStop(taskId: taskId) }
        }
        if isStreaming, !isDone {
            finish(success: false, error: "已停止")
        }
    }

    // MARK: - 轮询（直连路径参数版）

    private func startPolling(auth: AuthStore) {
        let gen = generation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isDone else { break }
                await self.pollOnce(auth: auth, generation: gen)
                if self.isDone { break }
                if gen != self.generation { break }   // v3.0.50：已是新代 → 退出
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce(auth: AuthStore, generation: Int) async {
        do {
            let (c, done, st, err, agent) = try await auth.streamPoll(taskId: taskId, offset: offset)
            guard generation == self.generation else { return }   // v3.0.50：旧代轮询丢弃
            if agent { isAgent = true }   // v2.0.96b：Agent 回复标记
            failCount = 0
            if !c.isEmpty {
                offset += c.count
                content += c
                idleStreak = 0
                if interval != 0.15 { interval = 0.15 }   // 有内容时 0.15s 高频轮询（接近逐字）
            } else if !done {
                idleStreak += 1
                // v3.0.57：首 token 思考期高频空轮 0.25s——首 token 落地后最快 0.25s 拉到
                //（原 0.8s 分级，最坏要多等 0.8s 才见首字）；NAS 本机查询瞬时，空轮 0.25s 可接受
                if interval != 0.25 { interval = 0.25 }
            }
            if done {
                finish(success: st != "error", error: err)
            }
        } catch APIError.server(404) {
            guard generation == self.generation else { return }
            // v3.0.31：任务丢失（qingliao 重启/内存回收）→ 尝试 recover 续上，避免长任务白等
            if !recoverTried {
                recoverTried = true
                if await tryRecover(auth: auth) { return }
            }
            failCount += 1
            if failCount >= 10 {
                finish(success: false, error: "连接中断，请重试")
            }
        } catch {
            guard generation == self.generation else { return }
            failCount += 1
            // v3.0.80：后台回来网络会话失效（非 404 的普通失败）也走 recover 续流，
            // 原来只有 404 才触发 → 前台恢复场景 10 连败直接终结，生成内容被截断
            if failCount == 3, !recoverFailTried {
                recoverFailTried = true
                if await tryRecover(auth: auth) { return }
            }
            if failCount >= 10 {
                finish(success: false, error: "连接中断，请重试")
            }
        }
    }

    /// v3.0.31：poll 404 恢复——调 /api/stream/recover 找回任务（内存优先、磁盘 streams/*.json 兜底）。
    /// 返回 true 表示已接管（继续轮询或已收尾），false = recover 请求本身失败（走 failCount）。
    private func tryRecover(auth: AuthStore) async -> Bool {
        do {
            let (tid, rContent, done, st, err) = try await auth.streamRecover(sessionId: auth.currentStreamSessionId)
            if let tid, !tid.isEmpty {
                // 找回成功：换新 taskId；磁盘兜底内容可能比本地多最后一段（节流写盘延迟），取较长者续上
                taskId = tid
                if rContent.count > content.count {
                    content = rContent
                    offset = rContent.count
                }
                if done {
                    finish(success: st != "error", error: err)
                }
                return true
            }
            // 服务器明确无此任务 → 立即收尾报错，不必等 10 次连败
            finish(success: false, error: "连接中断，请重试")
            return true
        } catch {
            return false
        }
    }

    private func finish(success: Bool, error: String) {
        guard !isDone else { return }   // v3.1.2：防重入——poll done + recover done 竞态导致 onFinished 重复触发队列发送
        isStreaming = false
        isDone = true
        status = success ? "done" : "error"
        errorMessage = error
        stopPolling()
        clearPersisted()
        endBgTask()   // v3.0.81：结束后台任务
        onFinished?(success, error)
        onFinished = nil
    }

    // MARK: - v3.0.81 后台任务管理

    /// 注册后台任务：iOS 挂起前最多续 ~30s，让轮询/recover 有机会完成
    private func beginBgTask() {
        guard bgTaskId == .invalid else { return }
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "QingliaoStreamPoll") { [weak self] in
            // 超时被系统回收：强制结束
            self?.endBgTask()
        }
    }

    /// 结束后台任务
    private func endBgTask() {
        guard bgTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
    }

    // MARK: - v2.0.61 杀后台流式恢复

    /// App 进后台时持久化流式状态（taskId/offset/content），重开后恢复轮询
    /// v3.0.80：后台回来先强制 recover 对齐服务器内容再续轮询——
    /// 后台期间轮询已死但服务器任务还在跑，旧 taskId/offset 可能失效，
    /// 原地 restartPolling 会连败终结流；recover 从服务器拿最新 taskId/content 无缝续上
    func restartPolling(auth: AuthStore) async {
        guard isStreaming, !isDone, !taskId.isEmpty else { return }
        stopPolling()
        recoverTried = false
        recoverFailTried = false
        failCount = 0
        // v3.0.81：后台回来先刷新网络会话（蜂窝/IPv6 连接可能已过期），再做 recover
        await auth.refreshConnection()
        let recovered = await tryRecover(auth: auth)
        if recovered {
            if isStreaming, !isDone { startPolling(auth: auth) }
        } else {
            // recover 失败（可能网络刚恢复还没就绪）：等 1 秒后重试一次 recover
            try? await Task.sleep(for: .seconds(1))
            await auth.refreshConnection()
            let retried = await tryRecover(auth: auth)
            if retried {
                if isStreaming, !isDone { startPolling(auth: auth) }
            } else {
                // 两次 recover 都失败：原地续轮询，靠 failCount/recover 兜底
                startPolling(auth: auth)
            }
        }
        // v3.0.81：restartPolling 时也注册后台任务
        beginBgTask()
    }

    func persistState(sessionId: String) {
        guard isStreaming, !taskId.isEmpty else { return }
        // 截断过长内容，避免超 UserDefaults 4MB 限制导致崩溃
        let persistedContent = content.count > 4096 ? String(content.prefix(4096)) : content
        let d: [String: Any] = [
            "taskId": taskId, "sessionId": sessionId,
            "offset": offset, "content": persistedContent,
            "userMsgId": pendingUserMsgId ?? "",   // v3.3.3：恢复落库锚点
            "ts": Date().timeIntervalSince1970
        ]
        UserDefaults.standard.set(d, forKey: "qingliao_stream_pending")
    }

    /// App 重开后恢复：有未完成任务 → 回填内容并继续轮询（无任务时静默返回）
    /// v2.0.102：先停旧轮询再恢复——防 .task 重复触发/恢复与手动 start 重叠导致双轮询
    func restoreIfNeeded(auth: AuthStore, onFinished: ((Bool, String) -> Void)? = nil) async {
        guard !isStreaming else { return }
        stopPolling()
        generation += 1   // v3.0.50：恢复时同样废除在途旧轮询代
        pendingUserMsgId = nil   // v3.3.3：先清残留，再从持久化读回真实锚点

        guard let d = UserDefaults.standard.dictionary(forKey: "qingliao_stream_pending") else { return }
        // 超过 30 分钟的任务视为失效（服务器端流可能已回收）
        if let ts = d["ts"] as? TimeInterval, Date().timeIntervalSince1970 - ts > 1800 {
            UserDefaults.standard.removeObject(forKey: "qingliao_stream_pending")
            return
        }
        guard let tid = d["taskId"] as? String, !tid.isEmpty else {
            UserDefaults.standard.removeObject(forKey: "qingliao_stream_pending")
            return
        }
        taskId = tid
        offset = (d["offset"] as? Int) ?? 0
        content = (d["content"] as? String) ?? ""
        recoverTried = false
        if let uid = d["userMsgId"] as? String, !uid.isEmpty {
            pendingUserMsgId = uid   // v3.3.3：恢复旧任务 → 落库锚定回原 user 消息
        }
        if let sid = d["sessionId"] as? String {
            auth.currentStreamSessionId = sid
        }
        isStreaming = true
        isDone = false
        self.onFinished = onFinished
        startPolling(auth: auth)
    }

    private func clearPersisted() {
        UserDefaults.standard.removeObject(forKey: "qingliao_stream_pending")
    }
}
