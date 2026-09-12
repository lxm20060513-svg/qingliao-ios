import ActivityKit
import Foundation

/// 「AI 正在回复」实时活动管理器（v3.8.0，v3.9.7 加三态、完成态展示与「停止生成」）。
///
/// 设计边界（刻意为之，别随手扩）：
/// - **只做本地驱动**：`Activity.request/update/end`，不依赖 APNs。侧载免费签名拿不到 Push 能力，
///   远程更新/push-to-start 必须付费开发者账号，所以不做，也不留半成品接口。
/// - **不长期持有 `Activity` 本体**（Swift 6 硬约束，CI #34599892145 实测踩到）：
///   `Activity` 非 Sendable，而 `update/end` 是 nonisolated async——把它存进 `@MainActor` 隔离存储后
///   再 `await activity.update(...)`，编译器报 `sending 'activity' risks causing data races`（三处）。
///   改为：只存 Sendable 状态（sessionId/时间/标题/模型/阶段），每次从 `Activity.activities`
///   现取新鲜值再用，这样送进 nonisolated async 方法的是「新值/无隔离归属的值」。
/// - **状态推进只由主 App 进程驱动**：灵动岛里的球体/旋转弧动画由挂件自己用 `TimelineView` 自走，
///   不依赖 update；App 被系统挂起后状态行停在最后一次广播，只有系统计时钟继续走。
@MainActor
final class LiveActivityManager {

    static let shared = LiveActivityManager()

    /// 用户开关的存储 key（设置 → 外观 → 交互）。**默认开**：
    /// `UserDefaults` 无值即视为开启；设置页与这里共用同一 key，避免两套真相。
    static let enabledKey = "qingliao_live_activity"

    /// 开关当前是否开启
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    // MARK: - 本进程状态（只放 Sendable 值）

    /// 当前活动对应的会话（nil = 本进程没有在跟的活动）
    private var currentSessionId: String?
    /// 本轮开始时间——同会话续更时保留，保证灵动岛计时不重启
    private var startedAt: Date?
    /// v3.9.7：最近一次广播的标题/模型/阶段/状态行/可停标记
    /// ——`finish()` 收尾时要复用，且用于「内容没变不重复 update」
    private var lastTitle = ""
    private var lastModel = ""
    private var lastPhase = ""
    private var lastAction = ""
    private var lastCanStop = false
    /// v3.9.7：刚调过 `Activity.request` 的时刻。
    /// `Activity.activities` 是**最终一致**的（本仓 end() 早就为此加了 600ms 重查）：
    /// 刚建的活动可能还没进列表，若此时直接按 pending 逻辑再 request 一次，同一会话会出现两条活动。
    private var justRequestedAt: Date?
    /// v3.9.7：上一轮已进入「完成态、正被系统按时收起」。
    /// 这期间同一会话又发新消息时，必须先收掉将死的活动再重建，否则 update 打到一个马上消失的活动上。
    private var pendingDismissal = false
    /// v3.9.7：代际令牌——用于作废「上一轮遗留的收尾动作」
    private var generation = 0
    /// v3.9.10：本轮推进度（见 `ContentState.progress`）与它的推手
    private var lastProgress: Double = 0.18
    private var progressTicker: Task<Void, Never>?
    /// 推手句柄归属的代际（用于「任务自我退出时清句柄」——见 startProgressTicker）
    private var tickerToken = 0

    private init() {}

    /// 启动收敛：清掉上一进程遗留的活动。
    /// 新进程里我们不认任何活动，而实时活动在 App 被杀/闪退后由系统保留数小时 →
    /// 不收敛就会留下「锁屏一直挂着 AI 正在回复、计时还在跑」的僵尸活动。
    /// 开关关着也走这里：清完不会再新建，新建由 `sync` 的 isEnabled 闸门把关。
    func convergeOnLaunch() async {
        // 本进程已在跟活动 → 说明不是冷启动（防 .task 意外重跑误杀正在显示的实时活动）
        guard currentSessionId == nil else { return }
        clearState()
        generation += 1
        // ⚠️ 必须**直接用 `Activity.activities`**（Apple 那个 getter 是「非隔离来源」，
        // 值才能被送进 nonisolated async 的 `activity.end`）。包一层静态计算属性就会把它变成
        // @MainActor 隔离值 → `sending 'activity' risks causing data races`（v3.9.9 CI 实踩）。
        for activity in Activity<QingliaoActivityAttributes>.activities
        where activity.activityState == .active {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// 按「AI 是否在回复 + 处于哪个阶段」同步实时活动：busy=true 开始/更新，busy=false 走 `finish()`。
    ///
    /// v3.9.7：**同一份内容不重复 update**。流式生成期间文本每几百毫秒变一次，如果每次变化都 update
    /// 就是 update 风暴（系统侧也有限流）；阶段（thinking→streaming）变化才值得推一次。
    func sync(isBusy: Bool, sessionId: String, sessionTitle: String, modelName: String,
              phase: String = QingliaoActivityAttributes.Phase.thinking.rawValue,
              actionText: String = "", canStop: Bool = false) async {
        // 用户关掉开关 → 立即收起，且不再新建
        guard isBusy, Self.isEnabled else { await end(); return }
        guard !sessionId.isEmpty, ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let title = sessionTitle.isEmpty ? "轻聊" : sessionTitle
        let model = modelName.isEmpty ? "AI" : modelName
        let newSession = (currentSessionId != sessionId)

        // v3.9.9（真机反馈修复）：先把"系统里真正在显示的活动"取出来。
        // **不能**用 `Activity.activities` 原样判断：`end()` 之后那条活动还会在列表里闪现一会儿
        // （状态早就变成 `.dismissed`），按它判断就会走 `update` 分支去更新一条**已经结束**的活动，
        // 于是新活动永远建不出来 —— 表现出来正是"灵动岛只在开关切换那一次生效、之后同一会话
        // 再对话就不亮"。
        // 只看「是否真有在显示的活动」（Bool，Sendable）——**不能缓存 Activity 数组**，
        // 那会把非隔离来源的值变成 MainActor 隔离值，送进 nonisolated 的 update/end 就报并发错。
        var hasActive = Self.hasActiveActivity
        if !hasActive, justRequestedRecently {
            // 刚 request 的活动可能还没进列表（最终一致）→ 等一拍再确认，绝不重复建第二条
            try? await Task.sleep(for: .milliseconds(600))
            hasActive = Self.hasActiveActivity
            if !hasActive { return }
        }

        // 内容没变（同会话、同标题/模型/阶段/状态行/可停标记**且确实有一条在显示的活动**）→ 不做无谓 update。
        // 少了 `hasActive` 这个条件，就会在活动已被系统收掉后继续静默跳过 → 再也不新建。
        // v3.9.10：本轮推进度——思考 0.18 起步，进入生成 0.35，之后由 ticker 逐步逼近 0.86，
        // 只有真结束才落 1.0（**不假装知道总长**，见 ContentState.progress 注释）。
        //
        // ⚠️ 基线必须按「新一轮」重置（v3.9.10 审查抓到的 BLOCKER）：同会话第二轮时
        // lastProgress 还留着上一轮 finish() 落的 1.0。原写法只看 newSession，于是第二轮
        // newProgress 直接算成 1.0 → 环一上来就满格，且 ticker 的 next 恒 ≤0.86 < 1.0 永远推不动
        // （用户看到「第二轮起环满格且完全不动」）。且 141 行的写回发生在 end()→clearState()
        // 复位之后，会把 1.0 再度写回，复位等于白做。
        // 「新一轮」= 换会话 / 上一轮刚收尾(pendingDismissal) / 阶段从 done|streaming 回到 thinking。
        let newRound = phase == QingliaoActivityAttributes.Phase.thinking.rawValue
            && (lastPhase == QingliaoActivityAttributes.Phase.done.rawValue
                || lastPhase == QingliaoActivityAttributes.Phase.streaming.rawValue)
        let freshRound = newSession || pendingDismissal || newRound
        let newProgress = Self.baseProgress(phase: phase, previous: freshRound ? 0 : lastProgress)
        if !freshRound, hasActive,
           title == lastTitle, model == lastModel,
           phase == lastPhase, actionText == lastAction, canStop == lastCanStop,
           newProgress == lastProgress {
            return
        }
        // 新的一轮回复 → 作废可能还挂着的上一轮收尾
        generation += 1

        if newSession || pendingDismissal {
            await end()   // 换会话 / 上一轮刚收尾：先清干净再重建
            // end() 之后列表未必立刻刷新（最终一致）→ 再确认一次，否则又会在已结束的活动上 update
            hasActive = Self.hasActiveActivity
            if hasActive {
                try? await Task.sleep(for: .milliseconds(600))
                hasActive = Self.hasActiveActivity
            }
        }

        let now = Date()
        // 同一轮内继续回复 → 保留原起始时间；**新一轮**（换会话 / 上一轮收尾后 / 阶段回到思考）
        // 从零开始——否则 startedAt 会跨轮累计，字段语义（“本轮开始时间”）就不成立了。
        // （v3.9.9：挂件已按用户要求**不显示计时**，此字段保留给完成态与后续形态。）
        let start = freshRound ? now : (startedAt ?? now)
        currentSessionId = sessionId
        startedAt = start
        lastTitle = title
        lastModel = model
        lastPhase = phase
        lastAction = actionText
        lastCanStop = canStop
        lastProgress = newProgress

        let state = QingliaoActivityAttributes.ContentState(sessionTitle: title,
                                                           modelName: model,
                                                           startedAt: start,
                                                           isAnswering: true,
                                                           phase: phase,
                                                           actionText: actionText,
                                                           canStop: canStop,
                                                           progress: newProgress)
        let content = ActivityContent(state: state, staleDate: Self.staleDate())

        if !hasActive {
            do {
                _ = try Activity.request(attributes: QingliaoActivityAttributes(sessionId: sessionId),
                                         content: content,
                                         pushType: nil)
                justRequestedAt = Date()
            } catch {
                // 实时活动被系统拒绝（用户关了「实时活动」/ 数量上限）——静默降级，不影响聊天
                clearState()
            }
        } else {
            for activity in Activity<QingliaoActivityAttributes>.activities
            where activity.activityState == .active {
                await activity.update(content)
            }
        }
        // v3.9.10：生成阶段开始按节奏推进环（离开生成阶段就停）
        if phase == QingliaoActivityAttributes.Phase.streaming.rawValue {
            startProgressTicker()
        } else {
            stopProgressTicker()
        }
    }

    /// 回复结束（v3.9.7）：先落「已完成」态，并让**系统** 2s 后自行收起。
    ///
    /// - 旧实现一结束就 `end()`，用户看不到完成态；改成把完成态内容作为 `end` 的 content 传入 +
    ///   `dismissalPolicy: .after(2s)`——由系统按时移除，**不依赖本进程存活**。
    ///   （先 update 再 `Task.sleep(2s)` 再 end 的写法在 App 被杀/闪退时会留下一条收不掉的残留。）
    /// - **只收当前活动对应的会话**：`aiBusy` 是按会话收窄的，用户切到别的会话时也会变 false，
    ///   不能因此把仍在跑的那条活动标成完成并收掉。
    func finish(sessionId: String) async {
        guard Self.isEnabled, let active = currentSessionId, sessionId == active else {
            // v3.9.10：切到别的会话时也会落到这里（`aiBusy` 按会话收窄 → 传进来的是**新**会话 id）。
            // 活动本体按原设计留给仍在跑的那一轮，但**进度推手必须停**，否则它会一路空转到饱和、
            // 每 4s 醒一次（审查抓到的新泄漏面：v3.9.9 之前这里只挂一条静止活动，没有推手）。
            stopProgressTicker()
            return
        }
        let token = generation

        var hasActive = Self.hasActiveActivity
        if !hasActive, justRequestedRecently {
            try? await Task.sleep(for: .milliseconds(600))
            hasActive = Self.hasActiveActivity
            if !hasActive { clearState(); return }   // 列表滞后：等一拍仍无在显示的活动 → 清本地状态
        }
        // review 修复：代际校验必须在 clearState 之前——那 600ms 等待窗口里用户可能已经开始了新一轮，
        // 此时清状态会把新一轮刚建立的 currentSessionId/startedAt 抹掉，下一次 sync 当成新会话
        // （先 end 再 request，灵动岛闪断 + 计时重启）。
        // ⚠️ 停表与写 lastProgress 必须在代际校验**之后**（审查抓到的 HIGH）：那 600ms 等待窗口里
        // 用户可能已经开始新一轮，先改状态就会把新一轮的进度基线写坏（且 pendingDismissal 还没置位，
        // sync 的 end()/彻底重置路径兜不住）。
        guard token == generation else { return }
        stopProgressTicker()
        lastProgress = 1.0
        guard hasActive else {
            clearState()   // 列表里确实没有活动（用户关了实时活动/被系统清掉）→ 清本地状态即可
            return
        }

        let state = QingliaoActivityAttributes.ContentState(sessionTitle: lastTitle,
                                                           modelName: lastModel,
                                                           startedAt: startedAt ?? Date(),
                                                           isAnswering: false,
                                                           phase: QingliaoActivityAttributes.Phase.done.rawValue,
                                                           actionText: "",
                                                           canStop: false,
                                                           progress: 1.0)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(60))

        // 这期间又开始了新一轮 → 新活动不能被这一轮收尾碰到
        guard token == generation else { return }

        for activity in Activity<QingliaoActivityAttributes>.activities
        where activity.activityState == .active {
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(2)))
        }
        lastPhase = state.phase
        lastAction = ""
        lastCanStop = false
        pendingDismissal = true
    }

    /// 结束当前活动（用户离开会话 / 开关关闭）。幂等：没有活动时是空操作。
    func end() async {
        let hadSession = currentSessionId != nil
        clearState()
        var hasActive = Self.hasActiveActivity
        if !hasActive, hadSession {
            // Activity.activities 是「最终一致」的：刚 request 出来的活动可能还没出现在列表里，
            // 等一拍再收一次，免得留下收不掉的残留（Apple 侧行为，Pocket Casts 亦有同样注释）
            try? await Task.sleep(for: .milliseconds(600))
            hasActive = Self.hasActiveActivity
        }
        for activity in Activity<QingliaoActivityAttributes>.activities
        where activity.activityState == .active {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: - 本轮推进度（v3.9.10）

    /// 阶段对应的起步进度。`previous` 保证**单调不倒退**（同一轮里只会往前长）。
    private static func baseProgress(phase: String, previous: Double) -> Double {
        // 天花 0.86：ticker 的收敛目标就是它，1.0 只允许出现在 finish() 那份内容里。
        // 万一有残留值漏进来（例如未来新增了别的收尾路径忘了重置），也不会让新的一轮一上来就满格。
        if phase == QingliaoActivityAttributes.Phase.streaming.rawValue {
            return min(0.86, max(previous, 0.35))
        }
        // 思考态下限 0.18：新一轮时 previous 传 0，没有这条下限会让环一开始就空着（观感像没在做事）
        return min(0.86, max(previous, 0.18))
    }

    /// 生成阶段按节奏推进进度环。
    ///
    /// 为什么放在管理器里而不是每来一个 token 就 update：
    ///   ① 实时活动的视图**只在 update 时重绘**（Apple 明文），所以「环一直在长」必须靠持续 update；
    ///   ② 但每次 token 都 update 就是 update 风暴（系统会限流、也白耗电）→ 固定 1.5s 一拍；
    ///   ③ 长回答（>30s）后放慢到 4s 一拍，避免长时间对话里的无意义唤醒；
    ///   ④ 曲线是**指数逼近 0.86**（先快后慢），永远不假装 100% —— 真完成由 `finish()` 落 1.0。
    private func startProgressTicker() {
        guard progressTicker == nil else { return }
        let token = generation
        tickerToken = token
        progressTicker = Task { @MainActor [weak self] in
            // 退出时清句柄（审查抓到）：原来三条自我退出路径都是裸 return，句柄仍非 nil →
            // 本轮之后再调 startProgressTicker 会被 `guard progressTicker == nil` 永久挡下，
            // 环停在起始值一动不动且无日志可查。用 token 比对避免误杀新一轮刚起的推手。
            defer {
                if let s = self, s.tickerToken == token { s.progressTicker = nil }
            }
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(ticks < 20 ? 1.5 : 4))
                guard !Task.isCancelled, let self, self.generation == token else { return }
                guard self.currentSessionId != nil, Self.hasActiveActivity else { return }
                if !Self.isEnabled { return }
                // 到顶就收工（不再每 4s 空转），下一轮由 sync 重启
                if self.lastProgress >= 0.86 { return }
                let next = min(0.86, self.lastProgress + max(0.006, (0.86 - self.lastProgress) * 0.05))
                ticks += 1
                // 推不动就退出，而不是 continue —— 原来的 continue 在 next 恒 ≤ 0.86 < lastProgress 时
                // 会让循环永不退出（活死循环，每 1.5s/4s 醒一次主线程）。审查抓到。
                guard next > self.lastProgress else { return }
                self.lastProgress = next
                let content = ActivityContent(state: self.currentState(progress: next),
                                              staleDate: Self.staleDate())
                for activity in Activity<QingliaoActivityAttributes>.activities
                where activity.activityState == .active {
                    await activity.update(content)
                }
            }
        }
    }

    private func stopProgressTicker() {
        progressTicker?.cancel()
        progressTicker = nil
    }

    /// 用最近一次广播的字段拼一份新的动态数据（只换 progress）——ticker 用
    private func currentState(progress: Double) -> QingliaoActivityAttributes.ContentState {
        QingliaoActivityAttributes.ContentState(sessionTitle: lastTitle,
                                               modelName: lastModel,
                                               startedAt: startedAt ?? Date(),
                                               isAnswering: true,
                                               phase: lastPhase,
                                               actionText: lastAction,
                                               canStop: lastCanStop,
                                               progress: progress)
    }

    // MARK: - 私有

    /// 是否刚调过 request（1s 内）——用于识破 `Activity.activities` 的最终一致窗口
    private var justRequestedRecently: Bool {
        guard let at = justRequestedAt else { return false }
        return Date().timeIntervalSince(at) < 1.0
    }

    /// 清空本进程记录的活动状态（不动系统里的活动本体）
    private func clearState() {
        currentSessionId = nil
        startedAt = nil
        // v3.9.9：标题/模型也要一并清 —— 原来只清阶段类字段，残留的 lastTitle/lastModel
        // 会让下一轮的「内容没变」判定误命中（同一会话的第二轮回复与上一轮签名完全相同）
        lastTitle = ""
        lastModel = ""
        lastPhase = ""
        lastAction = ""
        lastCanStop = false
        justRequestedAt = nil
        pendingDismissal = false
        stopProgressTicker()
        lastProgress = 0.18
    }

    /// 只有「系统里真正在显示」的活动才算数（v3.9.9 真机反馈修复的核心）。
    ///
    /// `Activity.activities` 在 `end()` 之后的一小段时间里**仍可能列出那条活动**（`.dismissed` 状态，
    /// 列表最终一致）。不按 `activityState` 过滤就会把已结束的活动当成在显示的，
    /// 于是新活动永远建不出来 —— 症状是「灵动岛只在开关切换那次生效，之后同一会话再聊就不亮」。
    /// 返回 **Bool**而不是 `[Activity]`：`Activity` 非 Sendable，从 @MainActor 隔离的静态上下文
    /// 传出数组 → 值变成隔离的 → 送进 nonisolated async 的 `activity.update/end` 就是
    /// `sending 'activity' risks causing data races`（v3.9.9 CI 实踩，4 处一起报）。
    /// 真正要用 Activity 本体时，必须在**使用点直接** `Activity.activities` 取值 + `where` 过滤，
    /// 保持「非隔离来源」这个身份（Apple 的 `activities` getter 是 nonisolated 的）。
    private static var hasActiveActivity: Bool {
        Activity<QingliaoActivityAttributes>.activities.contains { $0.activityState == .active }
    }

    /// 过期时间：进程意外消失后（强杀/闪退）系统能把活动标记为过期，而不是无限计时
    private static func staleDate() -> Date {
        Date().addingTimeInterval(15 * 60)
    }
}
