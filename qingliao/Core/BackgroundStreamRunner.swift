import Foundation
import Observation
import UIKit

// MARK: - v4.1.x 多会话并行（方案2）：后台跑流注册表
//
// 根因（2026-09-29 实据）：「新建会话」路径（ChatView pendingNewSession onChange）对全局单例
// stream.stop(auth:)——它调服务端 /api/stream/{taskId}/stop 把**正在跑的任务真杀掉**。
// 这是 v3.0.11 时代「单例只有一条流」的防串话旧防线，后端已实测真并行、按 sessionId 隔离，
// 防线已过时 = 误伤。
//
// 方案：把被新建/顶替的流**移交**到这里继续轮询（完全复用 AuthStore.streamPoll 同一管线、
// 同一蜂窝 CFStream 路径），跑完按发起时快照落库（landAwayReply 同族口径），答案不丢；
// 会话列表从 runningSessions 读「生成中」角标（多会话同时可见，替代原单会话 runningSessionID）。
//
// 边界与既定口径：
// - 前台仍单流（StreamClient 单例不动）：正在看的会话保持打字机/工具卡/灵动岛全体验。
// - 同一会话重复进入 runner 去重：进前台（stream.start 覆盖单例）前先把 runner 里同 sid 的条目撤销。
// - 删除会话：runner 条目一并撤销 + 停服务端任务（不往已删会话写库）。
// - 未读/通知：完成时回补 ChatStore.unread + 本地通知（后台期间完成，前台通知同口径静默）。

@MainActor
@Observable
final class BackgroundStreamRunner {
    static let shared = BackgroundStreamRunner()

    struct Entry {
        let sessionId: String
        let taskId: String
        let title: String                      // 通知/角标文案用（发起时快照）
        let userMsgId: String?                 // 落库锚点（pendingUserMsgId 同源）
        let snapshot: [ChatMessage]            // 发起时会话快照（落库基底）
        /// 2026-09-30（发布前审查）：同会话「撤销后重新移交」时会建新 entry，而旧 loop 的
        /// 在途回包（await 返回后）只判过 `running[sid] != nil` → 会写进新条目（offset/content
        /// 串任务，旧 loop 拿到 done 还会把新条目 finish 掉）。每次 adopt 发一个代次令牌，回包落笔前校验。
        let gen: String = UUID().uuidString
        var offset: Int = 0
        var content: String = ""
        var startedAt: TimeInterval = Date().timeIntervalSince1970
    }

    /// sessionId -> 在跑条目（会话列表角标真源）
    private(set) var running: [String: Entry] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]

    var isRunning: Bool { !running.isEmpty }

    /// 指定会话是否在后台跑流
    func isRunning(sessionId: String) -> Bool { running[sessionId] != nil }

    // MARK: - 移交入口（由 ChatView 新建会话路径调用，替代 stream.stop）

    /// 直接带参移交：taskId/快照由调用方从单例捕获（先捕获再 detach，防双轮询/双落库）。
    /// offset/content 传 0/"" 时从服务器续（poll 口径按码点 offset，缺段会由 recover 兜）——
    /// 实际上新建路径在 detach 前单例已带最新 content，这里直接取用，避免丢已收到的前缀。
    func adopt(taskId: String, sessionId sid: String, title: String,
               userMsgId: String?, snapshot: [ChatMessage],
               offset: Int, content: String,
               auth: AuthStore, chat: ChatStore) {
        cancelLocal(sessionId: sid)   // 同会话重复移交去重
        var e = Entry(sessionId: sid, taskId: taskId, title: title,
                      userMsgId: userMsgId, snapshot: snapshot)
        e.offset = offset
        e.content = content
        running[sid] = e
        startPollLoop(sessionId: sid, auth: auth, chat: chat)
    }

    /// 切到某会话进入前台前：若该会话有后台流在跑，撤销后台轮询（前台单例会从服务器接回它，
    /// 走既有 probeRemoteBusy → adoptRemote 路径，内容/offset 无缝续上）。
    func retractIfRunning(sessionId: String) {
        cancelLocal(sessionId: sessionId)
    }

    /// 删除会话时连带：撤轮询 + 停服务端任务（删了还会话写库 = 复活事故族）
    func cancelForDeletedSession(sessionId sid: String, auth: AuthStore) {
        guard let e = running.removeValue(forKey: sid) else { return }
        tasks[sid]?.cancel()
        tasks.removeValue(forKey: sid)
        Task { await auth.streamStop(taskId: e.taskId) }
    }

    // MARK: - 轮询循环（口径对齐 StreamClient.pollOnce：码点 offset / 退避 / 401 立即退出）

    private func startPollLoop(sessionId sid: String, auth: AuthStore, chat: ChatStore) {
        let task = Task { [weak self] in
            var failCount = 0
            var backoff: TimeInterval = 0.8
            var interval: TimeInterval = 0.25
            var idleStreak = 0
            while !Task.isCancelled {
                guard let self, let entry = self.running[sid] else { return }
                let myGen = entry.gen
                do {
                    let (c, done, st, err, agent, piggyback, _, _, _, _) =
                        try await auth.streamPoll(taskId: entry.taskId, offset: entry.offset)
                    // 2026-09-30 审查：撤销后重新移交会建**新** entry，此时 sid 仍存在但已是别人，
                    // 在途回包不得落笔（否则 offset/content 串任务，旧 loop 还会把新条目 finish 掉）
                    guard self.running[sid]?.gen == myGen else { return }
                    failCount = 0
                    if !piggyback.isEmpty {
                        InboxStore.shared.ingestPiggyback(piggyback)   // 与前台 pollOnce 同口径
                    }
                    if !c.isEmpty {
                        self.running[sid]?.offset += StreamClient.codePointCount(c)   // 码点口径（服务端 len()），勿改 c.count（UTF-16 差 emoji 就错位）
                        self.running[sid]?.content += c
                        idleStreak = 0
                        interval = 0.15
                    } else if !done {
                        idleStreak += 1
                        interval = idleStreak <= 12 ? 0.25 : 0.8
                    }
                    if done {
                        guard self.running[sid]?.gen == myGen else { return }
                        await self.finish(sessionId: sid, success: st != "error", error: err,
                                          agent: agent, auth: auth, chat: chat)
                        return
                    }
                } catch APIError.unauthorized {
                    guard self.running[sid]?.gen == myGen else { return }
                    await self.finish(sessionId: sid, success: false,
                                      error: APIError.unauthorized.localizedDescription,
                                      agent: false, auth: auth, chat: chat)
                    return
                } catch {
                    guard self.running[sid]?.gen == myGen else { return }
                    failCount += 1
                    // 弱网退避（8s 封顶）；404 = 服务端任务没了（qingliao 重启）→ 立即收尾，
                    // 不重试（runner 没有单例的 recover 管线，重试也拿不回任务）
                    if case let APIError.server(code) = error, code == 404 {
                        await self.finish(sessionId: sid, success: false,
                                          error: "连接中断，请重试", agent: false, auth: auth, chat: chat)
                        return
                    }
                    backoff = min(backoff * 2, 8)
                    interval = backoff
                    if failCount >= 15 {
                        await self.finish(sessionId: sid, success: false,
                                          error: "连接中断，请重试", agent: false, auth: auth, chat: chat)
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        tasks[sid] = task
    }

    // MARK: - 收尾：落库 + 未读 + 通知

    private func finish(sessionId sid: String, success: Bool, error: String, agent: Bool,
                        auth: AuthStore, chat: ChatStore) async {
        guard let entry = running.removeValue(forKey: sid) else { return }
        tasks.removeValue(forKey: sid)

        var body = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !success {
            let note = error.isEmpty ? "连接中断，请重试" : error
            body = body.isEmpty ? "⚠️ \(note)" : body + "\n\n⚠️ \(note)"
        }
        if body.isEmpty { body = "⚠️ 本轮空回复" }

        // 落库基底：发起时快照。若期间服务器侧会话已有新消息（其他端/收件箱写入），
        // 以发起快照为准追加——快照缺迟到的其他端消息属于既有 landAwayReply 同族边界，不放大。
        var msgs = entry.snapshot
        var m2 = ChatMessage.local(role: "assistant", content: body)
        m2.agent = agent
        msgs.append(m2)
        // ⚠️ 2026-09-30（发布前审查拦下，真数据破坏）：快照为空 = 拿不到被移交会话的历史
        // （流在 A 跑、用户切到 B 后在 B 点「+新建会话」→ ChatView 侧 startMsgs 为 []）。
        // 此时若照旧 saveToServer，等于用「仅 1 条 assistant」整会话覆盖（后端 merge 是整覆盖，
        // 而 writeSessionSnapshot 的护栏只拦空数组）→ 被移交会话的历史全被抹掉。
        // 空快照一律不覆盖服务端会话：只记「迟到回复」，进该会话时补回（同既有 landAwayReply 口径）。
        if !entry.snapshot.isEmpty {
            await chat.saveToServer(auth: auth, sessionId: sid, messages: msgs, title: entry.title)
        }
        chat.noteAwayLandedReply(sessionId: sid, text: body)   // 列表旧快照 load 进内存时补回

        // 未读 +1（用户不在该会话/前台时才记，避免正在看时红点闪现）
        if chat.sessionId != sid || UIApplication.shared.applicationState != .active {
            chat.unread[sid, default: 0] += 1
        }
        // 完成通知：后台期间完成才发（前台发通知骚扰，与 ChatView 收尾同口径）
        if UIApplication.shared.applicationState != .active {
            NotificationHelper.notifyReply(body, sessionId: sid)
        }
        InboxStore.shared.triggerFastPoll()   // 与前台收尾同口径：快拉收件箱去重
    }

    // MARK: - 内部

    /// 只撤本地轮询（不动服务端任务）——移交/前台接回场景用
    private func cancelLocal(sessionId sid: String) {
        running.removeValue(forKey: sid)
        tasks[sid]?.cancel()
        tasks.removeValue(forKey: sid)
    }
}
