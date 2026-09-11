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
    @State private var sending = false
    // v3.4.23：进行中任务（后端 /api/agent/tasks/active——AI 干活中的流式任务 + 后台作业；v3.4.25 改别名路径过 lucky 反代）
    @State private var activeTasks: [AuthStore.ActiveTask] = []
    @State private var activeTimer: Timer?

    enum TaskFilter: String, CaseIterable, Identifiable {
        case all = "全部", active = "进行中", cron = "任务", system = "通知"
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
                .padding(.top, 8)

                // v3.4.23：显示条件 = 进行中任务非空 或 未完成任务非空
                if activeTasks.isEmpty && activeOnlyTasks.isEmpty {
                    emptyState
                } else {
                    List {
                        // v3.4.23：进行中分区（仅"全部/进行中"页显示；running 置顶实时刷新）
                        if filter == .all || filter == .active {
                            if !activeTasks.isEmpty {
                                Section("⏳ 进行中") {
                                    ForEach(activeTasks) { t in
                                        ActiveTaskRow(task: t)
                                    }
                                }
                            }
                        }
                        if !activeOnlyTasks.isEmpty {
                            Section {
                                ForEach(activeOnlyTasks) { item in
                                    TaskRow(item: item)
                                        .contentShape(Rectangle())
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if store.tasks.contains(where: { $0.completed }) {
                        Button("清理已完成") { store.clearCompleted() }
                    }
                }
            }
            .confirmationDialog(
                "任务操作",
                isPresented: Binding(get: { actionItem != nil }, set: { if !$0 { actionItem = nil } }),
                titleVisibility: .visible
            ) {
                if let item = actionItem {
                    Button("复制内容") {
                        UIPasteboard.general.string = item.text
                        actionItem = nil
                    }
                    Button(item.completed ? "标记为未完成" : "标记完成") {
                        store.setCompleted(item.id, !item.completed)
                        actionItem = nil
                    }
                    Button("发送到当前会话") {
                        sendToCurrentSession(item)
                        actionItem = nil
                    }
                    Button("查看详情", role: .destructive) {}
                    Button("取消", role: .cancel) { actionItem = nil }
                }
            }
        }
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
                .background(Circle().fill(Color.green.opacity(0.14)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
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
            }
            Spacer()
            ProgressView()
                .controlSize(.small)
        }
        .padding(.vertical, 4)
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
                    Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.subheadline)
                    .strikethrough(item.completed, color: .secondary)
                    .foregroundStyle(item.completed ? .secondary : .primary)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Text(typeLabel)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
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
        .padding(.vertical, 4)
    }

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
