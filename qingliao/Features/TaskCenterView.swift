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

    enum TaskFilter: String, CaseIterable, Identifiable {
        case all = "全部", cron = "任务", system = "通知"
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

                let filtered = filteredTasks
                if filtered.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(filtered) { item in
                                TaskRow(item: item)
                                    .contentShape(Rectangle())
                                    .onTapGesture { actionItem = item }
                            }
                            .onDelete { idx in
                                for i in idx { store.setCompleted(filtered[i].id, true) }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("任务中心")
            .navigationBarTitleDisplayMode(.inline)
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
        case .all: store.tasks.sorted { a, b in
            // 未完成在前；同完成态按时间从新到旧
            if a.completed != b.completed { return !a.completed }
            return a.createdAt > b.createdAt
        }
        case .cron: store.tasks.filter { $0.taskType == "cron" }.sorted { $0.createdAt > $1.createdAt }
        case .system: store.tasks.filter { $0.taskType == "system" }.sorted { $0.createdAt > $1.createdAt }
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

// MARK: - 单条任务行
private struct TaskRow: View {
    let item: TaskCenterItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 15))
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.subheadline)
                    .strikethrough(item.completed, color: .secondary)
                    .foregroundStyle(item.completed ? .secondary : .primary)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Text(typeLabel)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(typeColor.opacity(0.14))
                        .foregroundStyle(typeColor)
                        .clipShape(Capsule())
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
