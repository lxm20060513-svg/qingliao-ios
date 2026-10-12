import SwiftUI

// MARK: - v3.9.95 AI 动作卡（渲染 ```ql-action 围栏）
//
// 用户交互按「三级确认」口径（见 AppPermissionKit 文件头）落到 UI：
//   · 读（查空闲/看今日日程）→ 进页面就**自动跑**，结果就地显示，用户什么都不用点
//   · 写（建事件/存图/通知）→ 出「执行」胶囊，**必须点一下**才动手
//   · 删（删事件）→ 出「确认删除」胶囊（红），执行后给 5 秒撤销
//
// 三条 UI 铁律：
//   ① 执行中禁用重复点击（用户狂点会建出三个事件 —— 这真会发生）
//   ② 失败必须出声：写/删失败红字+震动；**只读失败不震动**（多半是"没授权"，读数据时突然震很惊悚）
//   ③ 状态**就地回填同一张卡**，不另起消息（否则动作卡会把聊天流刷屏）
//   ④ v4.0.100：终态**必须落库**（`ChatMessage.actionOutcomes`，键 = `AgentAction.stateKey`）。
//      用户报「已经执行完的动作卡，下次打开还是显示未执行的状态」—— 原先 phase 只是视图级 @State，
//      重启 / 切会话 / 消息重建全丢，写删动作的「执行」胶囊重新长出来，再点一次就是第二个日程。
//      两条配套口径（v4.0.100 审查补的，别再翻）：
//        · **只读卡不落回执** —— 回执 =「副作用已经发生过了」的凭证，只读卡没有副作用；
//          而它的结果常带时效（「今天 14:00 有空」），冻住会让隔天翻到还写着「今天」。
//        · **流式临时气泡里的卡不给可点胶囊** —— 那条消息不在 `store.messages` 里，回执无处可落，
//          点下去静默失败、落地后胶囊重生（同一个 bug 的流式版本）。

struct AgentActionCard: View {
    let action: AgentAction
    /// v4.0.100：回执落点 —— 这张卡所属消息的 id（读写 `ChatStore.actionOutcomes`）。
    /// 空串 = 无宿主（预览 / 单测渲染），行为退化成改动前：状态只在内存里。
    var messageId: String = ""
    /// v4.0.100：这张卡渲染在**流式临时气泡**里（每帧新建的 ChatMessage，不在 `store.messages` 里）。
    /// 它没有「归宿」——回执要写回的那条消息根本不存在，于是流式期间点「执行」= 回执静默写不进 →
    /// 回复落地后卡片重建、「执行」胶囊重生 → 用户再点一次就是第二个日程（正是本批要根治的那条报障）。
    /// 故流式期间**不给可点胶囊、也不自动跑**，等这条回复真正落库后卡片再按正常路径执行。
    var streamingHost = false

    /// 登录态：`mail.send` 这类「必须走后端」的动作要它。根视图已 `.environment(auth)` 全树注入
    /// （同 ChatView / IntentActionBar 的取法），别再往卡片里显式传参。
    @Environment(AuthStore.self) private var auth
    /// v4.0.100：执行回执的**真源在会话里**，不在卡片自己的生命周期里。
    /// 视图级 @State 一重启就没了 —— 那正是用户报的「执行完了下次打开还是未执行」。
    @Environment(ChatStore.self) private var store

    private enum Phase: Equatable {
        case idle
        case running
        case done(String)
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var undo: (() async -> Void)?
    @State private var undoDeadline: Date?
    @State private var now = Date()

    /// 读动作自动执行；写/删等用户点。
    private var autoRuns: Bool { action.kind.impact == .read }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            header
            if let s = action.summary {
                Text(s).font(.system(size: Typography.caption)).foregroundStyle(.secondary)
            }
            controls
            handoffNote
            resultArea
        }
        .padding(Spacing.lg)
        .glassListCard()
        .task {
            // v4.0.100：流式临时气泡里的卡一律不动作 —— 回执无处可落（见 streamingHost）。
            // 不认回执、不自动跑，等回复落库后卡片重建再走正常路径。
            guard !streamingHost else { return }
            if let o = storedOutcome {
                applyStored(o)
                return
            }
            // v4.0.100：**先认回执再决定跑不跑**。
            //   ① 认到了 → 直接回到终态：执行过的卡不再回落成「未执行」。
            //   ② 没认到 → 老行为（只读自动跑）。
            // 只读卡不落回执（见 persist）→ 它们每次重进会话照旧重跑一次，结果永远新鲜；
            // 这条回执管的是**有副作用**的动作：别让它重生出可点胶囊、再点一次就是第二个日程。
            // ⚠️ 顺序不能反：反了就会「先跑一遍再把结果盖掉」——写/删卡更糟，胶囊已经重新长出来了。
            if autoRuns { await execute() }
        }
        .task(id: undoDeadline) {
            // 5 秒撤销倒计时（只有存在撤销时才起）
            guard let deadline = undoDeadline else { return }
            while Date() < deadline {
                now = Date()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            undo = nil
            undoDeadline = nil
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 22)
            Text(action.kind.capabilityLabel)
                .font(.system(size: Typography.subhead, weight: .semibold))
            Spacer()
            impactChip
        }
    }

    private var icon: String {
        switch action.kind {
        case .calendarCreate: return "calendar.badge.plus"
        case .calendarDelete: return "calendar.badge.minus"
        case .calendarUpdate: return "calendar.badge.clock"
        case .calendarFree:   return "calendar.day.timeline.left"
        case .calendarToday:  return "calendar"
        case .reminderCreate: return "checklist"
        case .todoAdd:        return "checkmark.circle.fill"
        case .reminderList:   return "checklist.checked"
        case .reminderDelete: return "checklist.unchecked"
        case .photoSave:      return "square.and.arrow.down"
        case .photoDelete:    return "trash"
        case .contactsSearch: return "person.crop.circle.badge.questionmark"
        case .contactsCreate: return "person.crop.circle.badge.plus"
        case .locationCurrent: return "location"
        case .clipboardRead:  return "doc.on.clipboard"
        case .clipboardWrite: return "doc.on.clipboard.fill"
        case .fileList:       return "folder"
        case .fileRead:       return "doc.text"
        case .fileWrite:      return "square.and.pencil"
        case .notify:         return "bell.badge"
        case .mailSend:       return "envelope.fill"
        case .goalCreate:     return "target"
        case .goalStepDone:   return "checkmark.seal.fill"
        case .healthQuery:    return "heart.text.square"
        }
    }

    private var impactChip: some View {
        let (label, color): (String, Color) = {
            switch action.kind.impact {
            case .read:   return ("只读", .secondary)
            case .write:  return ("需确认", .orange)
            case .delete: return ("删除", .red)
            }
        }()
        return Text(label)
            .font(.system(size: Typography.caption, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var tint: Color {
        switch phase {
        case .failed: return .red
        case .done:   return .green
        default:      return .accentColor
        }
    }

    // MARK: 操作区

    @ViewBuilder
    private var controls: some View {
        switch phase {
        case .idle where streamingHost:
            // v4.0.100：流式期间不给可点胶囊（回执写不进 = 落地后胶囊重生、再点就是第二个日程）
            Text("回复生成中…").font(.system(size: Typography.caption)).foregroundStyle(.secondary)
        case .idle where autoRuns:
            ProgressView().controlSize(.small)     // .task 正在自动跑
        case .idle:
            Button {
                Haptics.press()
                Task { await execute() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: action.kind.impact == .delete ? "trash" : "play.fill")
                    Text(action.kind.impact == .delete ? "确认删除" : "执行")
                }
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.xs)
                .background(action.kind.impact == .delete ? Color.red : Color.accentColor, in: Capsule())
            }
            .buttonStyle(PressStyle())
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("执行中…").font(.system(size: Typography.caption)).foregroundStyle(.secondary)
            }
        case .done, .failed:
            if let u = undo {
                Button {
                    Haptics.tap()
                    Task {
                        await u()
                        undo = nil; undoDeadline = nil
                        phase = .done("已撤销")
                        // v4.0.100：撤销 = 这件事**没有发生** → 回执抹掉。
                        // 留着会被一条「已执行」冻住，而用户按撤销往往正是想重来一次。
                        forgetOutcome()
                        Haptics.success()
                    }
                } label: {
                    Text("撤销（\(max(0, Int(undoDeadline?.timeIntervalSince(now) ?? 0)))s）")
                        .font(.system(size: Typography.caption, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(PressStyle())
            }
        }
    }

    /// v4.0.20（#1）：建目标卡 = **前台 → 后台的交接点**（用户 2026-10 口径 2a：原地变回执，不另起气泡）。
    /// 用户原来点完「执行」只看到一句「已建目标…」，读不出「这件事从此由后台接管了」。
    @ViewBuilder
    private var handoffNote: some View {
        if action.kind == .goalCreate {
            switch phase {
            case .idle:
                Label("确认后交给后台：每天早晚各自动推进一次（默认 9:09 / 21:21），结果会推到你微信，也回到这里和「生活 → 长期目标」",
                      systemImage: "arrow.turn.down.right")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            case .done:
                Label("已在后台运行 —— 不用守着，推进结果会推到你微信，也会回到这里和「生活 → 长期目标」",
                      systemImage: "checkmark.seal.fill")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(Color.green)
            case .running, .failed:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var resultArea: some View {
        switch phase {
        case .done(let m), .failed(let m):
            Text(m).font(.system(size: Typography.caption))
                .foregroundStyle(isFailed ? .red : .secondary)
        case .idle, .running:
            EmptyView()
        }
    }

    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    // MARK: 执行（读自动、写删由按钮触发，共用这一条路径）

    private func execute() async {
        // ① 防重复：只有 idle 能进
        guard case .idle = phase else { return }
        phase = .running
        let outcome = await AgentActionExecutor.run(action, auth: auth)
        let loud = action.kind.impact != .read
        switch outcome {
        case .done(let msg, let u):
            if loud { Haptics.success() }
            undo = u
            undoDeadline = u == nil ? nil : Date().addingTimeInterval(5)
            phase = .done(msg)
            persist(msg)
        case .doneNoUndo(let msg):
            if loud { Haptics.success() }
            phase = .done(msg)
            persist(msg)
        case .failed(let msg):
            if loud { Haptics.error() }
            phase = .failed(msg)
            // **失败刻意不落回执**：失败 = 「这次没成」，不是「这件事做过了」。
            // 冻住会让用户去系统里授权之后再回来，卡片变成一具点不动的尸体。
            // 重进会话回到「未执行」= 天然的重试入口，正是我们要的。
        }
    }

    // MARK: v4.0.100 回执读写

    /// 本卡已落库的回执（nil = 从未成功执行过）
    private var storedOutcome: AgentActionOutcome? {
        guard !messageId.isEmpty else { return nil }
        return store.actionOutcome(messageId: messageId, key: action.stateKey)
    }

    /// 把回执还原成卡上的终态
    private func applyStored(_ o: AgentActionOutcome) {
        phase = o.failed ? .failed(o.message) : .done(o.message)
    }

    /// 成功终态落库。**先同步写内存再落盘**：写回执会 bump messageRev 触发页面重建，
    /// 万一重建让这张卡重新走一遍 .task，此刻回执必须已经在 store 里了，
    /// 否则卡片会闪回「未执行」（甚至对只读卡再跑一次）。
    private func persist(_ msg: String) {
        guard !messageId.isEmpty else { return }
        // v4.0.100：**只读卡不落回执**。回执的语义是「这次副作用已经发生过了」——
        // 只读卡没有副作用，不需要凭证；而它的结果文案常带时效（「今天 14:00 有空」），
        // 冻住会让隔天再翻到这条消息时卡上还写着「今天」。只读卡保持每次重跑，结果永远新鲜。
        guard !autoRuns else { return }
        let o = AgentActionOutcome(failed: false, message: msg)
        guard store.markActionOutcome(messageId: messageId, key: action.stateKey, outcome: o) else { return }
        Task { await store.saveToServer(auth: auth) }
    }

    /// 撤销 → 抹掉回执（并落库，否则本地抹了、后端那份重启又回来）
    private func forgetOutcome() {
        guard !messageId.isEmpty else { return }
        guard store.clearActionOutcome(messageId: messageId, key: action.stateKey) else { return }
        Task { await store.saveToServer(auth: auth) }
    }
}
