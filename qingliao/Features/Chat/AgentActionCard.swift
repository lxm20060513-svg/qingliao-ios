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

struct AgentActionCard: View {
    let action: AgentAction

    /// 登录态：`mail.send` 这类「必须走后端」的动作要它。根视图已 `.environment(auth)` 全树注入
    /// （同 ChatView / IntentActionBar 的取法），别再往卡片里显式传参。
    @Environment(AuthStore.self) private var auth

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
            resultArea
        }
        .padding(Spacing.lg)
        .glassListCard()
        .task {
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
        case .doneNoUndo(let msg):
            if loud { Haptics.success() }
            phase = .done(msg)
        case .failed(let msg):
            if loud { Haptics.error() }
            phase = .failed(msg)
        }
    }
}
