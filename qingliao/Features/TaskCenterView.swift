import SwiftUI
import UIKit

// MARK: - v3.4.x 任务中心：收件箱从"推送气泡"升级为"任务列表"
/// 展示 TaskCenterStore 里的非 reply 任务（定时/后台/系统事件），支持分类过滤、标记完成、清理已完成。
/// 点击任务 → 底部操作单：复制内容 / 发送到当前会话 / 标记完成。
struct TaskCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatStore.self) private var chat
    @Environment(AuthStore.self) private var auth
    @State private var store = TaskCenterStore.shared
    @State private var filter: TaskFilter = .all
    @State private var actionItem: TaskCenterItem?
    /// v4.0.76：每行实时 frame 字典（List 复用行，锚点按任务 id 取）。
    /// v4.0.76 审查⑧：行 frame 未量到时兜底屏幕中下方，不弹左上角（原死状态 actionAnchor 已删）
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var detailItem: TaskCenterItem?   // v3.9.32：任务详情（原「查看详情」是个空按钮）
    @State private var sending = false
    // v3.4.23：进行中任务（后端 /api/agent/tasks/active——AI 干活中的流式任务 + 后台作业；v3.4.25 改别名路径过 lucky 反代）
    @State private var activeTasks: [AuthStore.ActiveTask] = []
    @State private var activeTimer: Timer?
    // v4.0.86（任务中心③）：历史任务（后端 /api/tasks/history —— done/error 的后台作业，bgjobs.json 真源）
    @State private var historyTasks: [AuthStore.ActiveTask] = []
    // v4.0.86（任务中心①）：停止确认弹窗（避免误触杀任务）
    @State private var stopTarget: AuthStore.ActiveTask?

    enum TaskFilter: String, CaseIterable, Identifiable {
        case all = "全部", active = "进行中", cron = "任务", system = "通知", history = "历史"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 分类过滤
                Picker("分类", selection: $filter) {
                    ForEach(TaskFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, Spacing.md)

                // v3.4.23：显示条件 = 进行中任务非空 或 未完成任务非空（v4.0.86：历史页除外——历史空也给空态）
                if filter == .history {
                    historyList
                } else if activeTasks.isEmpty && activeOnlyTasks.isEmpty {
                    emptyState
                } else {
                    List {
                        // v3.4.23：进行中分区（仅"全部/进行中"页显示；running 置顶实时刷新）
                        if filter == .all || filter == .active {
                            if !activeTasks.isEmpty {
                                Section("⏳ 进行中") {
                                    ForEach(activeTasks) { t in
                                        ActiveTaskRow(task: t)
                                            // v4.0.86（任务中心①）：行点击 → 停止确认（仅 kind=stream；
                                            // bg 作业后端无 cancel 端点，不提供停止）
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                if t.kind == "stream", t.status == "running" {
                                                    stopTarget = t
                                                }
                                            }
                                    }
                                }
                            }
                        }
                        if !activeOnlyTasks.isEmpty {
                            Section {
                                ForEach(activeOnlyTasks) { item in
                                    TaskRow(item: item)
                                        .contentShape(Rectangle())
                                        // v4.0.76：每行实时上报全局 frame（锚定菜单从被点行位置弹出）
                                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) }
                                            action: { rowFrames[item.id] = $0 }
                                        .onTapGesture { actionItem = item }
                                }
                                .onDelete { idx in
                                    for i in idx { store.setCompleted(activeOnlyTasks[i].id, true) }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("任务中心")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { startActivePolling() }
            .onDisappear {
                activeTimer?.invalidate()
                activeTimer = nil
            }
            // v4.0.86（任务中心①）：停止确认 —— 确认后才真打 /api/stream/{id}/stop
            .alert("停止这个任务？", isPresented: Binding(get: { stopTarget != nil },
                                                      set: { if !$0 { stopTarget = nil } })) {
                Button("停止", role: .destructive) {
                    if let t = stopTarget { stopTask(t) }
                    stopTarget = nil
                }
                Button("取消", role: .cancel) { stopTarget = nil }
            } message: {
                if let t = stopTarget { Text("「\(t.title)」将被中断，已生成的部分内容会保留。") }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                // v3.9.46：修「没有任务时右上角一枚空玻璃胶囊」。
                // 原来两个按钮写在同一个 ToolbarItem 的空 HStack 里 —— 两个 if 都不成立时
                // ToolbarItem 仍然挂着，iOS 26 会给它套一层液态玻璃底，于是出现零文字的空胶囊。
                // 口径：条件判定提到 ToolbarItem 外层，没有按钮就根本不产生 toolbar item。
                if store.uncompleted > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        // v3.9.30：全部已读——未完成任务一次全标完成（此前只能逐条点）
                        Button("全部已读") { store.markAllCompleted() }
                    }
                }
                if store.tasks.contains(where: { $0.completed }) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清理已完成") { store.clearCompleted() }
                    }
                }
            }
            // 🚨 v4.0.77：任务操作浮层**挪到 NavigationStack 之外**（原挂在内容 VStack 上：轻纱只罩住
            // 内容区、导航栏在罩外，与聊天/看板两处锚定菜单口径不一致）。见 taskActionMenuLayer。
            // v3.9.32：任务详情
            .alert("任务详情", isPresented: Binding(get: { detailItem != nil }, set: { if !$0 { detailItem = nil } })) {
                Button("复制内容") {
                    UIPasteboard.general.string = detailItem?.text
                    detailItem = nil
                }
                Button("好", role: .cancel) { detailItem = nil }
            } message: {
                if let it = detailItem {
                    Text(taskDetailText(it))
                }
            }
        }
        // 🚨 v4.0.77：锚定菜单浮层挂 NavigationStack **之外**（整页最外层）——轻纱盖住导航栏，四个调用点同口径。
        .overlay { taskActionMenuLayer }
    }

    /// v4.0.77：任务操作锚定菜单（胶囊规格见 AnchorMenuOverlay；挂载点见 body 最外层）。
    @ViewBuilder
    private var taskActionMenuLayer: some View {
        if let item = actionItem {
            // 兜底：行 frame 未量到（极端滚动时序）时弹屏幕中下，不弹左上角
            let fallback = CGRect(x: UIScreen.main.bounds.midX - 90, y: UIScreen.main.bounds.height * 0.55,
                                  width: 180, height: 44)
            AnchorMenuOverlay(anchorFrame: rowFrames[item.id] ?? fallback,
                              items: [
                                  AnchorMenuItem(id: "copy", title: "复制内容", icon: "doc.on.doc", color: .blue),
                                  AnchorMenuItem(id: "toggle", title: item.completed ? "标记为未完成" : "标记完成",
                                                 icon: item.completed ? "circle" : "checkmark.circle", color: .orange),
                                  AnchorMenuItem(id: "send", title: "发送到当前会话", icon: "paperplane.fill", color: .indigo),
                                  AnchorMenuItem(id: "detail", title: "查看详情", icon: "info.circle", color: .teal),
                              ] + (item.sessionId.flatMap { $0.isEmpty ? nil : [AnchorMenuItem(id: "open", title: "打开来源会话", icon: "bubble.left.and.bubble.right.fill", color: .green)] } ?? []),
                              title: "任务操作",
                              onPick: { m in
                                  actionItem = nil
                                  switch m.id {
                                  case "copy":
                                      UIPasteboard.general.string = item.text
                                  case "toggle":
                                      store.setCompleted(item.id, !item.completed)
                                  case "send":
                                      sendToCurrentSession(item)
                                  case "detail":
                                      // v3.9.32：先收菜单再开 alert（同帧 present 会被吞，0.3s 错峰沿用）
                                      Task {
                                          try? await Task.sleep(for: .seconds(0.3))
                                          detailItem = item
                                      }
                                  case "open":
                                      // v4.0.86（任务中心②）：跳回这条推送归属的会话。
                                      // 复用通知点开同一条深链（DockTabView .task 消费 qingliao_open_session →
                                      // loadById → 切聊天 tab）；先 dismiss 本页，深链才轮得到处理。
                                      if let sid = item.sessionId, !sid.isEmpty {
                                          UserDefaults.standard.set(sid, forKey: "qingliao_open_session")
                                          dismiss()
                                      }
                                  default:
                                      break
                                  }
                              },
                              onClose: { actionItem = nil })
        }
    }

    /// v3.9.32：任务详情文案（类型 / 状态 / 时间 / 来源 / 内容）
    private func taskDetailText(_ it: TaskCenterItem) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let when = df.string(from: Date(timeIntervalSince1970: it.createdAt))
        let kind = it.taskType == "cron" ? "定时任务" : "系统通知"
        var lines = ["类型：\(kind)", "状态：\(it.completed ? "已完成" : "未完成")", "时间：\(when)"]
        if let src = it.sourceTaskId, !src.isEmpty { lines.append("来源：\(src)") }
        lines.append("")
        lines.append(it.text)
        return lines.joined(separator: "\n")
    }

    private var filteredTasks: [TaskCenterItem] {
        switch filter {
        case .cron: store.tasks.filter { $0.taskType == "cron" }.sorted { $0.createdAt > $1.createdAt }
        case .system: store.tasks.filter { $0.taskType == "system" }.sorted { $0.createdAt > $1.createdAt }
        default:
            // all / active：未完成在前；同完成态按时间从新到旧
            store.tasks.sorted { a, b in
                if a.completed != b.completed { return !a.completed }
                return a.createdAt > b.createdAt
            }
        }
    }

    private var activeOnlyTasks: [TaskCenterItem] {
        if filter == .active {
            // 「进行中」页 = 进行中任务 + 未完成任务列表
            return store.tasks.filter { !$0.completed }.sorted { $0.createdAt > $1.createdAt }
        }
        return filteredTasks
    }

    /// v3.4.23：拉取进行中任务 + 定时刷新（页面存活期间每 2s 一轮，dismiss 时停）
    private func startActivePolling() {
        activeTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                activeTasks = await auth.fetchActiveTasks()
            }
        }
        activeTimer = t
        Task { @MainActor in
            activeTasks = await auth.fetchActiveTasks()
        }
        // v4.0.86（任务中心③）：历史只进页时拉一次（历史是静态结果，不必轮询）
        Task { @MainActor in
            historyTasks = await auth.fetchTaskHistory()
        }
    }

    // MARK: - v4.0.86（任务中心③）：历史分区
    @ViewBuilder
    private var historyList: some View {
        if historyTasks.isEmpty {
            emptyState
        } else {
            List {
                Section {
                    ForEach(historyTasks) { t in
                        VStack(alignment: .leading, spacing: 4) {
                            ActiveTaskRow(task: t)
                            // ③：失败原因 / 结果摘要（后端 result 截 2000 字，这里再限 4 行）
                            if !t.result.isEmpty {
                                Text(t.result)
                                    .font(.caption)
                                    .foregroundStyle(t.status == "error" ? Color.red : Color.secondary)
                                    .lineLimit(4)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable {
                historyTasks = await auth.fetchTaskHistory()
            }
        }
    }

    // MARK: - v4.0.86（任务中心①）：停止进行中的流式任务（复用聊天页同一条 stop 链路）
    private func stopTask(_ t: AuthStore.ActiveTask) {
        Task { @MainActor in
            await auth.streamStop(taskId: t.id)
            // 停完立刻刷新，别等下一轮 2s
            activeTasks = await auth.fetchActiveTasks()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("暂无任务")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func sendToCurrentSession(_ item: TaskCenterItem) {
        guard !sending else { return }
        sending = true
        Task {
            defer { sending = false }
            // 通过通知让 ChatView 接管：把任务内容作为用户消息发送到当前会话
            NotificationCenter.default.post(name: .qingliaoTaskSend, object: item.text)
            dismiss()
        }
    }
}

// MARK: - v3.4.23 进行中任务行（AI 回复中 / 后台作业）
private struct ActiveTaskRow: View {
    let task: AuthStore.ActiveTask

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: Typography.body, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.green.opacity(Tint.subtle)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8))
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title.isEmpty ? "正在处理" : task.title)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if !task.detail.isEmpty {
                        Text(task.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(elapsed)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                // 🚨 v4.0.54（用户 2026-10-05 报障 + 截图）：「任务中心不需要显示这些细化信息」——
                // 逐步清单（每步工具名 + 耗时 + 绿勾）整块撤掉，只留上面那行摘要：
                // `task.detail`（第 N 步 xxx · 字数 · 静默时长）+ `elapsed`（总耗时）。
                // 逐步明细只在**聊天页工具卡**里看（那边可展开，见 ChatView 的 ToolStepsSummaryRow）。
                // 后端 plan / planSeq 照旧下发、AuthStore 照旧解析（Core/ActiveTaskPlan.swift 保留），
                // 只是任务中心不再渲染 —— 要恢复就把 PlanStepList 那段拿回来（见 git 历史 v4.0.54 前）。
            }
            Spacer()
            // v4.0.86（任务中心③）：只有 running 才转圈；历史行（done/error）出状态图标
            if task.status == "running" {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: task.status == "error" ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(task.status == "error" ? Color.orange : Color.green)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private var elapsed: String {
        guard task.createdAt > 0 else { return "" }
        let secs = Int(Date().timeIntervalSince1970 - task.createdAt)
        if secs < 60 { return "\(max(secs, 0))s" }
        return "\(secs / 60)m\(secs % 60)s"
    }
}

// MARK: - 单条任务行
private struct TaskRow: View {
    let item: TaskCenterItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // v3.4.23：图标玻璃小圆片（类型色 tint + 极淡底色），对齐全站卡片规范
            Image(systemName: iconName)
                .font(.system(size: Typography.body, weight: .semibold))
                .foregroundStyle(item.completed ? Color.secondary : iconColor)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(iconColor.opacity(item.completed ? 0.06 : 0.14))
                )
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(displayText)
                    .font(.subheadline)
                    .strikethrough(item.completed, color: .secondary)
                    .foregroundStyle(item.completed ? .secondary : .primary)
                    .lineLimit(3)
                // v4.0.20（#11）：后台自主推进任务 → 标出「跑到第几步了」。
                // 后端 goal cron 首行被强制输出【目标推进 k/N】，这里解析成角标 + 细进度条；
                // 用户原话：「任务中心的任务那里加通知，表明当前后台自主推进任务进行到哪一步了」
                if let p = progress {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: Typography.caption, weight: .semibold))
                            Text(GoalProgressMark.label(step: p.step, total: p.total))
                                .font(.system(size: Typography.caption, weight: .semibold))
                        }
                        .foregroundStyle(Color.blue)
                        ProgressView(value: GoalProgressMark.ratio(step: p.step, total: p.total))
                            .progressViewStyle(.linear)
                            .tint(.blue)
                    }
                }
                HStack(spacing: 6) {
                    Text(typeLabel)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.xxs)
                        .background(Capsule().fill(typeColor.opacity(0.13)))
                        .overlay(Capsule().strokeBorder(typeColor.opacity(0.22), lineWidth: 0.7))
                        .foregroundStyle(typeColor)
                    Text(relativeTime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.completed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Circle()
                    .stroke(Color(uiColor: .separator), lineWidth: 1.2)
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    /// v4.0.20（#11）：正文里去掉进度标记（角标已经表达过，不重复）
    private var displayText: String { GoalProgressMark.stripped(item.text) }

    /// v4.0.20（#11）：这条是不是「后台自主推进」的第几步
    private var progress: (step: Int, total: Int)? { GoalProgressMark.parse(item.text) }

    private var iconName: String {
        switch item.taskType {
        case "cron": "clock.badge.checkmark"
        case "system": "bell.badge"
        default: "tray"
        }
    }
    private var iconColor: Color {
        switch item.taskType {
        case "cron": .blue
        case "system": .orange
        default: .gray
        }
    }
    private var typeLabel: String {
        switch item.taskType {
        case "cron": "定时任务"
        case "system": "系统通知"
        default: "任务"
        }
    }
    private var typeColor: Color {
        switch item.taskType {
        case "cron": .blue
        case "system": .orange
        default: .gray
        }
    }
    private var relativeTime: String {
        let t = Date(timeIntervalSince1970: item.createdAt)
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: t, relativeTo: Date())
    }
}
