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
/// - **状态推进只由主 App 进程驱动**（v3.9.13 更新口径）：实时活动**没有连续帧源**，所以
///   球上/环上的「在动」全部靠这里按节拍 `update`（起步档 / 慢档见 `OrbBeat.fast` / `OrbBeat.slow`，
///   同一份数也下发给挂件），挂件侧只用 `ContentState.spin` 驱动旋转/脉冲 + 按本拍间隔算的过渡动画。**不要再往挂件里塞
///   `TimelineView(.animation)` 这类自走帧源**——它在实时活动里不成立。
///   App 被系统挂起后拍不动（免费签名无 APNs，无法远程续推），画面会停在最后一拍，
///   这是框架边界，不是缺陷；真机复测请在 App 前台观察。
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
    /// v3.9.13：不确定态相位（见 `ContentState.spin`）——每拍 +0.125 **累计不回绕**，
    /// 与 progress 同时推进。progress 到 0.86 封顶后靠它继续给画面「在动」的变化。
    /// 不回绕的原因（子代理静态审查抓到的观感缺陷）：若取模回绕，弧角度会从 315° 插值回 0°
    /// ＝每轮循环（约 9.6s）倒着急扫一圈，与「一直在转」完全相反。累计值 ≤ 10 分钟 ≈ 500 拍
    /// ＝ 22500°，Double 精度与 SwiftUI 角度插值都毫无压力。
    private var lastSpin: Double = 0
    /// 推手句柄归属令牌（单调递增）：只用于回答「谁有权清句柄」——见 startProgressTicker
    private var tickerToken = 0
    /// v3.9.27：活动列表滞后的连续拍数（见 ticker 内宽限窗逻辑；≥3 拍仍无活动才退出）
    private var missingActivityTicks = 0
    /// v3.9.37：**当前拍间隔**——随每次 update 一并下发（见 `ContentState.beatSeconds`）。
    /// 挂件的过渡时长要「略短于拍间隔」，两侧必须用同一个数；只在推手换档（30 拍后）时变。
    private var lastBeat: Double = LiveActivityManager.fastBeat

    /// v3.9.37：推手节奏——**数值真源在共享的 `OrbBeat`**（`LiveActivityAttributes.swift`，
    /// 挂件也编同一份文件），这里只是给它起推手侧的名字，别再往本文件写数字。
    /// - `fastBeat`：起步节奏（`OrbBeat.fast`，挂件过渡 1.12s，两拍之间只留 0.08s 缝）。
    /// - `slowBeat`：长回答（>30 拍 ≈36s）后放慢省电（`OrbBeat.slow` = 2.0s。别再回 2.5s：
    ///   2.5 超出挂件过渡上限 1.95s → 每拍必然留 0.55s 静止段）。
    static let fastBeat: Double = OrbBeat.fast
    static let slowBeat: Double = OrbBeat.slow
    /// 用多少拍走快速档（30 × 1.2s ≈ 36s，与旧实现的换档点一致，别顺手改）
    static let fastBeatCount = 30

    private init() {}

    /// 收敛**孤儿活动**：清掉本进程不认的活动。启动时调一次，**每次回前台再调一次**（v3.9.42）。
    /// 新进程里我们不认任何活动，而实时活动在 App 被杀/闪退后由系统保留数小时 →
    /// 不收敛就会留下「锁屏一直挂着 AI 正在回复、计时还在跑」的僵尸活动。
    /// 开关关着也走这里：清完不会再新建，新建由 `sync` 的 isEnabled 闸门把关。
    ///
    /// v3.9.42 为什么要改成「回前台也扫」：原来只在冷启动 `.task` 里跑一次，而**强杀 App 时没有任何
    /// 代码会执行**，用户不重开就永远不收；重开后如果那条已经转 `.stale`（>15 分钟没更新），
    /// 旧的 `== .active` 过滤同样放过它 → 表现即用户报的「杀掉 App 也不退出」。
    /// 判定依据是不变量「`currentSessionId == nil` ⇒ 本进程没有在跟任何一轮」⇒ 系统里那条一定是孤儿。
    /// 流式途中回前台时 `currentSessionId` 有值 → 直接返回，不会误杀正在显示的活动。
    func convergeOrphanActivities() async {
        // 本进程已在跟活动 → 不是孤儿场景（防 .task / scenePhase 重跑误杀正在显示的实时活动）
        guard currentSessionId == nil else { return }
        clearState()
        generation += 1
        // ⚠️ 必须**直接用 `Activity.activities`**（Apple 那个 getter 是「非隔离来源」，
        // 值才能被送进 nonisolated async 的 `activity.end`）。包一层静态计算属性就会把它变成
        // @MainActor 隔离值 → `sending 'activity' risks causing data races`（v3.9.9 CI 实踩）。
        for activity in Activity<QingliaoActivityAttributes>.activities
        where Self.isCollectible(activity.activityState) {
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
        var hasActive = Self.hasLiveActivity
        if !hasActive, justRequestedRecently {
            // 刚 request 的活动可能还没进列表（最终一致）→ 等一拍再确认，绝不重复建第二条
            try? await Task.sleep(for: .milliseconds(600))
            hasActive = Self.hasLiveActivity
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
                || lastPhase == QingliaoActivityAttributes.Phase.streaming.rawValue
                || lastPhase == QingliaoActivityAttributes.Phase.failed.rawValue)   // v3.9.30：失败收尾后新一轮也要重置基线
        let freshRound = newSession || pendingDismissal || newRound
        let newProgress = Self.baseProgress(phase: phase, previous: freshRound ? 0 : lastProgress)
        if !freshRound, hasActive,
           title == lastTitle, model == lastModel,
           phase == lastPhase, actionText == lastAction, canStop == lastCanStop,
           newProgress == lastProgress {
            // ⚠️ v3.9.13（第二轮静态审查抓到）：早返回前**必须补一次幂等起表**。
            // 场景：会话 A 流式中切到 B → `finish(B)` 走「会话不匹配」分支 `stopProgressTicker()`；
            // 用户切回 A → `sync(A)` 被调用，但 title/phase/action/newProgress 与上次全同 →
            // 命中原样早返回 → 推手再也不会被起起来，画面永久冻在切走那一刻，直到本轮结束才跳一下。
            // 同根因还有：推手因 10 分钟安全阀 / 活动被系统清掉而自我退出后，只要下一次 sync 内容未变也永远不重起。
            // 起表本身幂等（`startProgressTicker` 内部「活着就复用」），所以这里无副作用。
            if phase == QingliaoActivityAttributes.Phase.thinking.rawValue
                || phase == QingliaoActivityAttributes.Phase.streaming.rawValue {
                startProgressTicker()
            }
            return
        }
        // 新的一轮回复 → 作废可能还挂着的上一轮收尾
        generation += 1

        if newSession || pendingDismissal {
            await end()   // 换会话 / 上一轮刚收尾：先清干净再重建
            // end() 之后列表未必立刻刷新（最终一致）→ 再确认一次，否则又会在已结束的活动上 update
            hasActive = Self.hasLiveActivity
            if hasActive {
                try? await Task.sleep(for: .milliseconds(600))
                hasActive = Self.hasLiveActivity
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
                                                           progress: newProgress,
                                                           spin: lastSpin,
                                                           beatSeconds: lastBeat)
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
            where Self.isCollectible(activity.activityState) {
                await activity.update(content)
            }
        }
        // v3.9.10 / v3.9.13：**思考与生成两个阶段都跑推手**。
        // 原来只在生成阶段跑，于是思考期（首 token 前常 10-20s）环停在 0.18、球上的弧一动不动——
        // 用户看到的「动几下就不动了」有一半来自这里。收尾态（done）才停。
        if phase == QingliaoActivityAttributes.Phase.streaming.rawValue
            || phase == QingliaoActivityAttributes.Phase.thinking.rawValue {
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
    func finish(sessionId: String, failed: Bool = false) async {
        guard Self.isEnabled, let active = currentSessionId, sessionId == active else {
            // v3.9.10：切到别的会话时也会落到这里（`aiBusy` 按会话收窄 → 传进来的是**新**会话 id）。
            // 活动本体按原设计留给仍在跑的那一轮，但**进度推手必须停**，否则它会一路空转到饱和、
            // 每 4s 醒一次（审查抓到的新泄漏面：v3.9.9 之前这里只挂一条静止活动，没有推手）。
            stopProgressTicker()
            return
        }
        let token = generation

        var hasActive = Self.hasLiveActivity
        if !hasActive, justRequestedRecently {
            try? await Task.sleep(for: .milliseconds(600))
            hasActive = Self.hasLiveActivity
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

        // v3.9.30：失败走红球+「生成失败」，同样 2s 后收起（此前失败时岛上无感知）
        let endPhase = failed ? QingliaoActivityAttributes.Phase.failed.rawValue
                              : QingliaoActivityAttributes.Phase.done.rawValue
        let state = QingliaoActivityAttributes.ContentState(sessionTitle: lastTitle,
                                                           modelName: lastModel,
                                                           startedAt: startedAt ?? Date(),
                                                           isAnswering: false,
                                                           phase: endPhase,
                                                           actionText: "",
                                                           canStop: false,
                                                           progress: 1.0,
                                                           // v3.9.37b：收尾帧也按真实节奏下发——
                                                           // 不传就落 init 默认（起步档），慢档轮次收尾时
                                                           // 与「两侧永远同一口径」相悖（当前完成态无 beat 消费者，
                                                           // 属口径/健壮性收口）
                                                           beatSeconds: lastBeat)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(60))

        // 这期间又开始了新一轮 → 新活动不能被这一轮收尾碰到
        guard token == generation else { return }

        for activity in Activity<QingliaoActivityAttributes>.activities
        where Self.isCollectible(activity.activityState) {
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(2)))
        }
        lastPhase = state.phase
        lastAction = ""
        lastCanStop = false
        pendingDismissal = true
    }

    /// v3.9.42 **兜底收尾**（用户实报「任务完成后灵动岛一直不退出」的主因）：
    /// 本机流已经为**我们还在跟的那一轮**收尾了，但没人把 busy=false 送过来 → 由这里补上这一刀。
    ///
    /// 为什么原来会漏：`finish()` 唯一的驱动是 `ChatView.onChange(of: aiBusy)`，而 v3.9.41 把
    /// `aiBusy` 按会话收窄（`thisSessionStreaming`）之后，**离开那个会话的 ChatView 就再也看不到它的
    /// 完成信号**——切到会话 B（A 的 ChatView 被换掉、`.task` 一并取消）时只有 B 的 `finish(B)` 会跑，
    /// 而它因 `sessionId != currentSessionId` 直接返回；A 那条活动于是永远停在「AI 正在回复」，
    /// 15 分钟后转 `.stale`，重开 App 也收不掉（配合本次一并修的 `isCollectible` 口径）。
    /// 挂 `RootView` 是因为它常驻不销毁，且 `stream` / `auth` 都在环境里。
    ///
    /// - Parameter streamSessionId: `auth.currentStreamSessionId`（这条本机流归属的会话，
    ///   口径同 v3.9.39 A1 的 `persistState`），`streamIsRunning`: `stream.isStreaming`（全局占用，不收窄）。
    ///   只处理「管理器跟的这一轮 == 本机流刚结束的这一轮」：跟的是别的会话（例如靠服务器探针在跑的
    ///   远端任务）时不插手，那一条仍由它自己的 ChatView 负责。
    func finishOrphanedRound(streamSessionId: String, streamIsRunning: Bool, failed: Bool) async {
        guard let tracked = currentSessionId, !streamIsRunning,
              tracked == streamSessionId, !streamSessionId.isEmpty else { return }
        await finish(sessionId: tracked, failed: failed)
    }

    /// 结束当前活动（用户离开会话 / 开关关闭）。幂等：没有活动时是空操作。
    func end() async {
        let hadSession = currentSessionId != nil
        clearState()
        var hasActive = Self.hasLiveActivity
        if !hasActive, hadSession {
            // Activity.activities 是「最终一致」的：刚 request 出来的活动可能还没出现在列表里，
            // 等一拍再收一次，免得留下收不掉的残留（Apple 侧行为，Pocket Casts 亦有同样注释）
            try? await Task.sleep(for: .milliseconds(600))
            hasActive = Self.hasLiveActivity
        }
        for activity in Activity<QingliaoActivityAttributes>.activities
        where Self.isCollectible(activity.activityState) {
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

    /// 各阶段的**推进上限**与**每拍步长**（v3.9.13）。
    ///
    /// 步长必须让眼睛看得见：环直径 20pt（紧凑态）周长约 63pt，原来 `max(0.006, …)` 的保底步长
    /// 只有 ≈0.4pt/拍，指数收敛后肉眼完全看不出在动——这就是「动几下就不动了」的直接原因。
    /// 现在改成**线性 + 可见步长**：思考 0.03/拍（≈1.9pt），生成 0.02/拍（≈1.3pt）。
    private static func tickStep(phase: String) -> (cap: Double, step: Double) {
        if phase == QingliaoActivityAttributes.Phase.streaming.rawValue {
            return (0.86, 0.02)
        }
        // 思考档不越过 0.35：进入生成阶段时还有明显的前进空间
        return (0.35, 0.03)
    }

    /// 生成阶段按节奏推进进度环 + 不确定态相位。
    ///
    /// 为什么放在管理器里而不是每来一个 token 就 update：
    ///   ① 实时活动的视图**只在 update 时重绘**（Apple 明文），所以「一直在动」必须靠持续 update；
    ///   ② 但每次 token 都 update 就是 update 风暴（系统会限流、也白耗电）→ 1.2s 一拍；
    ///   ③ 长回答（>36s）后放慢到 **2.0s** 一拍（v3.9.37：原 2.5s 与挂件 1.95s 的过渡上限对不上，
    ///      每拍会留 0.55s 静止段＝用户报的「动画还是会断」），避免长时间对话里的无意义唤醒；
    ///   ④ progress 到顶（0.86）后**不再收工**——每拍仍推进 `spin`，球/环上的弧继续转。
    ///      旧版到顶就 return，画面彻底静止（这是用户报的「动几下就不动了」的第二半原因）。
    private func startProgressTicker() {
        // v3.9.13：**活着的推手直接复用，不按代际重建**。两个坑都要绕开：
        // ① 旧写法 `guard progressTicker == nil else { return }`：sync 每次走到 update 路径都会
        //    `generation += 1`，而思考期的推手此刻多半正挂在 `Task.sleep` 上（还没执行 defer 清句柄）→
        //    新推手被挡下、旧推手醒来又因代际不符自我退出 → **场上再无推手**，画面从首 token 起彻底静止。
        //    （子代理静态审查抓到的必现缺陷，症状与用户投诉「动几下就不动了」逐字相同。）
        // ② 若改成「代际变了就重建」，则流式期间每次 sync 都会 cancel + 重起——sync 一密，
        //    推手就永远跑不满一拍，等于不动（修一个坑引入另一个坑）。
        // 结论：循环体每拍读的都是**最新**的 `lastPhase`/`lastProgress`，本来就不需要换代；
        // 「本轮结束 / 新一轮 / 切会话」一律由 sync 的 done 分支、`finish()`、`clearState()` 显式 stop。
        if let t = progressTicker, !t.isCancelled { return }
        progressTicker = nil          // 清掉「已取消但还没走 defer」的旧句柄
        // 句柄令牌单调递增：只用于回答「谁有权清句柄」，避免退场中的旧推手误清新推手
        tickerToken += 1
        let handleToken = tickerToken
        progressTicker = Task { @MainActor [weak self] in
            defer {
                if let s = self, s.tickerToken == handleToken { s.progressTicker = nil }
            }
            var ticks = 0
            var startedTicking = Date()
            while !Task.isCancelled {
                // v3.9.37：睡眠节奏与**下发给挂件**的节奏是两个数，别混：
                //   · `beat`：本拍睡多久（换档恒在 30 拍那一次，与旧实现逐字一致）。
                //   · `nextBeat`：这一拍 update 之后、下一次 update 到来之前的间隔 ——
                //     挂件的过渡要撑到下一次 update 为止，所以必须下发**它**。
                // v3.9.37b（发版前审查抓到）：原来下发 `beat`（刚睡过的那一拍）→ 第 30 拍
                //   （ticks=29）下发 1.2 而实际间隔已是 2.0 → 每轮约 36s 处仍静止 0.88s，
                //   「动画还是会断」残留一次。真值表钉住：ticks=29 必须下发慢档。
                let beat = ticks < Self.fastBeatCount ? Self.fastBeat : Self.slowBeat
                let nextBeat = (ticks + 1) < Self.fastBeatCount ? Self.fastBeat : Self.slowBeat
                try? await Task.sleep(for: .seconds(beat))
                guard !Task.isCancelled, let self else { return }
                self.lastBeat = nextBeat
                guard self.currentSessionId != nil else { return }
                if !Self.isEnabled { return }
                // 兜底（正常路径由上面几处显式 stop 收）：阶段已不在忙碌就自行退出
                let livePhase = self.lastPhase
                guard livePhase == QingliaoActivityAttributes.Phase.thinking.rawValue
                    || livePhase == QingliaoActivityAttributes.Phase.streaming.rawValue else { return }
                // v3.9.27：系统列表滞后的宽限窗——`Activity.activities` 是最终一致的，刚 request 的活动
                // 可能还没进列表；旧写法 `guard hasLiveActivity else { return }` 会在这一窗里把推手
                // 静默杀掉，之后只能靠「内容变化触发 sync」的幂等起表救回（长任务中内容常不变 →
                // 环/球停在某拍不动 = 用户报的「动一段时间就不动了」）。现在：没有可见活动时先等 3 拍
                // 再放弃，等出期间只跳过 update，不退出循环。
                if !Self.hasLiveActivity {
                    self.missingActivityTicks += 1
                    if self.missingActivityTicks <= 3 { continue }
                    return
                }
                self.missingActivityTicks = 0
                // 安全阀：任何漏停场景（例如 App 长期不结束这一轮）最多推 10 分钟
                // v3.9.27：安全阀触发时**主动调一次 sync 幂等起表**，并重置计时——旧写法直接 return，
                // 10 分钟后长任务里的灵动岛就永久冻住（用户报的停摆另一来源）。
                if Date().timeIntervalSince(startedTicking) > 10 * 60 {
                    await self.sync(isBusy: true,
                                    sessionId: self.currentSessionId ?? "",
                                    sessionTitle: self.lastTitle,
                                    modelName: self.lastModel,
                                    phase: livePhase,
                                    actionText: self.lastAction,
                                    canStop: self.lastCanStop)
                    startedTicking = Date()
                    continue
                }
                let cfg = Self.tickStep(phase: self.lastPhase)
                let nextProgress = min(cfg.cap, self.lastProgress + cfg.step)
                // 累计相位，**不回绕**（回绕会让弧角度从 315° 倒插回 0°，每 9.6s 反向急扫一次）
                let nextSpin = self.lastSpin + 0.125
                ticks += 1
                // 单调不倒退；到顶后 progress 不变，靠 spin 产生可见变化（所以这里不再 return）
                self.lastProgress = max(self.lastProgress, nextProgress)
                self.lastSpin = nextSpin
                let content = ActivityContent(state: self.currentState(progress: self.lastProgress,
                                                                      spin: nextSpin),
                                              staleDate: Self.staleDate())
                for activity in Activity<QingliaoActivityAttributes>.activities
                where Self.isCollectible(activity.activityState) {
                    await activity.update(content)
                }
            }
        }
    }

    private func stopProgressTicker() {
        progressTicker?.cancel()
        progressTicker = nil
    }

    /// 用最近一次广播的字段拼一份新的动态数据（只换 progress / spin）——ticker 用
    private func currentState(progress: Double, spin: Double) -> QingliaoActivityAttributes.ContentState {
        QingliaoActivityAttributes.ContentState(sessionTitle: lastTitle,
                                               modelName: lastModel,
                                               startedAt: startedAt ?? Date(),
                                               isAnswering: true,
                                               phase: lastPhase,
                                               actionText: lastAction,
                                               canStop: lastCanStop,
                                               progress: progress,
                                               spin: spin,
                                               beatSeconds: lastBeat)
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
        // v3.9.27：滞后计数一并归零
        missingActivityTicks = 0
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
        // v3.9.37：拍间隔也复位（不清的话上一轮长回答的 2.0s 慢档会被下一轮首帧继承）
        lastBeat = Self.fastBeat
        // v3.9.13：spin 是**累计相位**，不清就会把上一轮/上一次的相位带进新一轮（首帧弧位置随机）
        lastSpin = 0
    }

    // MARK: - 活动状态口径（v3.9.42 收口）

    /// **「还没消失、还能被收尾/更新」的状态集合**。原来五处判定全写死 `== .active`，是
    /// v3.9.42 用户实报「任务完成后灵动岛一直不退出、杀掉 App 重开也不退出」的直接成因之一。
    ///
    /// `ActivityState` 一共五档（Apple 文档核过，**没有** `.inactive`）：
    /// `pending` / `active` / `stale` / `ended` / `dismissed`。只认 `.active` 会漏掉两档**画面还在屏上**的：
    /// - `.stale`：本仓 `staleDate` 是 +15 分钟。App 被挂起/强杀期间推手停摆，超过 15 分钟这一条就转
    ///   `.stale`——锁屏那行、灵动球**都还显示着**，只是系统标了「内容过期」。旧的 `.active` 过滤对它是盲的：
    ///   `finish()` 收不到它、启动收敛也收不到它，于是僵尸活动**永久留在屏上**（每次判定都跳过它）。
    ///   且 `hasLiveActivity` 也认不出它 → `sync()` 会再 `request` 一条 → 锁屏同时挂两行。
    ///   `.stale` 恰恰是「需要一次 update」的状态，所以它同时进 update 与 end 两个集合。
    /// - `.pending`：预约启动（`startActivity`）才会有，本仓不用；列进来纯属不再另立一套口径。
    /// `.ended` / `.dismissed` 才是真「已经没了」，必须继续排除：
    /// `.ended` 是已 end、正按 `dismissalPolicy` 等着消失，再 end 一次会把既定的收起时机打断
    /// （完成态那 2s 就白给了）；`.dismissed` 是 `Activity.activities` 最终一致窗口里的闪现残留
    /// （v3.9.9 就是为它加的过滤，别把它一起放进来）。
    ///
    /// 声明成 `nonisolated`：它不碰任何隔离状态，而调用点全在「从 `Activity.activities` 现取的值」上，
    /// 少一层 @MainActor 隔离就少一处 Swift 6 并发推断的意外（v3.9.9 CI 实踩那一类）。
    private nonisolated static func isCollectible(_ state: ActivityState) -> Bool {
        state == .active || state == .stale || state == .pending
    }

    /// 屏上还有「没消失」的活动吗——决定 `sync()` 走 update 还是 request、推手要不要继续拍。
    ///
    /// 只有「系统里真正还在显示」的活动才算数（v3.9.9 真机反馈修复的核心；v3.9.42 把口径换成 `isCollectible`）。
    ///
    /// `Activity.activities` 在 `end()` 之后的一小段时间里**仍可能列出那条活动**（`.dismissed` 状态，
    /// 列表最终一致）。不按 `activityState` 过滤就会把已结束的活动当成在显示的，
    /// 于是新活动永远建不出来 —— 症状是「灵动岛只在开关切换那次生效，之后同一会话再聊就不亮」。
    /// 返回 **Bool**而不是 `[Activity]`：`Activity` 非 Sendable，从 @MainActor 隔离的静态上下文
    /// 传出数组 → 值变成隔离的 → 送进 nonisolated async 的 `activity.update/end` 就是
    /// `sending 'activity' risks causing data races`（v3.9.9 CI 实踩，4 处一起报）。
    /// 真正要用 Activity 本体时，必须在**使用点直接** `Activity.activities` 取值 + `where` 过滤，
    /// 保持「非隔离来源」这个身份（Apple 的 `activities` getter 是 nonisolated 的）。
    private static var hasLiveActivity: Bool {
        Activity<QingliaoActivityAttributes>.activities.contains { isCollectible($0.activityState) }
    }

    /// 过期时间：进程意外消失后（强杀/闪退）系统能把活动标记为过期，而不是无限计时
    private static func staleDate() -> Date {
        Date().addingTimeInterval(15 * 60)
    }
}
