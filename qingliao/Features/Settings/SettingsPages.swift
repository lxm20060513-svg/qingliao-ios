import SwiftUI
import UniformTypeIdentifiers

// MARK: - 文件管理页（浏览 NAS 文件 / 下载分享 / 上传）



// MARK: - 定时任务页

struct CronTask: Identifiable {
    let id: String
    let name: String
    let cron: String
    let prompt: String
    let enabled: Bool
    let nextRunAt: String?

    var nextRunText: String {
        guard let nextRunAt, !nextRunAt.isEmpty else { return "待定" }
        return nextRunAt
    }
}

struct TasksView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var tasks: [CronTask] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if loading {
                    // v3.9.42：首屏改骨架（列表结构可预测，行式与下方真列表同形）
                    LoadingStateView(shape: .rows(4))
                } else if tasks.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Text("暂无定时任务")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.tertiary)
                    if let loadError {
                        Text(loadError)
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                        Button("重试") {
                            Task { await load() }
                        }
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    } else {
                        Text("下拉可刷新")
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(tasks) { t in
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                        .fill(Color.indigo.opacity(Tint.soft))
                                    Image(systemName: "clock.badge.fill")
                                        .font(.system(size: Typography.body))
                                        .foregroundStyle(Color.indigo)
                                }
                                .frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(t.name)
                                        .font(.system(size: Typography.subhead, weight: .semibold))
                                        .lineLimit(1)
                                    Text(t.cron)
                                        .font(.system(size: Typography.tiny, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    if t.enabled {
                                        Text("运行中 · \(t.nextRunText)")
                                            .font(.system(size: Typography.tiny))
                                            .foregroundStyle(Color.green)
                                    } else {
                                        Text("已停用")
                                            .font(.system(size: Typography.tiny))
                                            .foregroundStyle(Color.secondary)
                                    }
                                }
                                Spacer()
                                // 启用/禁用切换
                                Button {
                                    toggleTask(t)
                                } label: {
                                    Image(systemName: t.enabled ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: Typography.headline))
                                        .foregroundStyle(t.enabled ? Color.orange : Color.green)
                                }
                                .buttonStyle(.plain)
                                // 立即运行
                                Button {
                                    runTask(t)
                                } label: {
                                    Image(systemName: "bolt.circle.fill")
                                        .font(.system(size: Typography.headline))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, Spacing.xxl)
                            .padding(.vertical, Spacing.lg)
                            // 长按：编辑 / 删除
                            .contextMenu {
                                // v3.9.40（#17）：编辑任务名/Cron/提示词（PATCH 依赖 unified_router
                                // 补上的 do_PATCH，之前 501）
                                Button {
                                    editingTask = t
                                } label: {
                                    Label("编辑任务", systemImage: "square.and.pencil")
                                }
                                Button(role: .destructive) {
                                    deleteTask(t)
                                } label: {
                                    Label("删除任务", systemImage: "trash")
                                }
                            }
                            Divider().padding(.leading, Spacing.rowDividerInsetWide)
                        }
                    }
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.bottom, 20)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("定时任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewTask = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .task { await load() }
        // 关闭后重载：新建/编辑原先都要手动下拉刷新才看得到结果
        .sheet(isPresented: $showNewTask, onDismiss: { Task { await load() } }) {
            NewTaskSheet()
                .presentationDetents([.medium])
        }
        // v3.9.40（#17）：编辑既有任务
        .sheet(item: $editingTask, onDismiss: { Task { await load() } }) { t in
            NewTaskSheet(editing: t)
                .presentationDetents([.medium])
        }
        }
    }

    @State private var showNewTask = false
    @State private var editingTask: CronTask?   // v3.9.40（#17）：非空即打开编辑弹窗
    @State private var loadError: String?

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let arr = try await auth.jsonArray("/api/cron/tasks")
            tasks = arr.compactMap { d in
                guard let d = d as? [String: Any], let id = d["id"] as? String else { return nil }
                return CronTask(id: id,
                                name: d["name"] as? String ?? "未命名",
                                cron: d["cron"] as? String ?? "",
                                prompt: d["prompt"] as? String ?? "",
                                enabled: (d["enabled"] as? Bool) ?? true,
                                nextRunAt: d["next_run_at"] as? String)
            }
            loadError = nil
        } catch {
            tasks = []
            loadError = "加载失败：\(error.localizedDescription)"
        }
    }

    /// 立即运行任务（POST /api/cron/tasks/{id}/run）
    private func runTask(_ t: CronTask) {
        Task {
            _ = try? await auth.request("/api/cron/tasks/\(t.id)/run", method: "POST", body: nil)
            await load()
        }
    }

    /// 启用/禁用任务（PATCH /api/cron/tasks/{id}）
    private func toggleTask(_ t: CronTask) {
        Task {
            _ = try? await auth.request("/api/cron/tasks/\(t.id)", method: "PATCH",
                                        body: ["enabled": !t.enabled])
            await load()
        }
    }

    /// 删除任务（DELETE /api/cron/tasks/{id}）
    private func deleteTask(_ t: CronTask) {
        Task {
            _ = try? await auth.request("/api/cron/tasks/\(t.id)", method: "DELETE", body: nil)
            await load()
        }
    }
}

// MARK: - 日志页

struct LogsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var logs: [String] = []
    @State private var loading = true
    @State private var exportText = ""
    @State private var showExporter = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if loading {
                    // v3.9.42：日志是整宽纯文本行，用头像骨架会骗人 → 收口转圈
                    LoadingStateView(shape: .spinner(text: "正在读取日志…"))
                } else if logs.isEmpty {
                Spacer()
                Text("暂无日志")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: Typography.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Spacing.xl)
                                .padding(.vertical, Spacing.xs)
                        }
                    }
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.bottom, 20)
                }
            }
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 16) {
                    Button {
                        UIPasteboard.general.string = logs.joined(separator: "\n")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(Color.accentColor)
                    }
                    Button {
                        exportText = logs.joined(separator: "\n")
                        showExporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Color.accentColor)
                    }
                    // v3.9.35：刷新改回系统裸按钮——与「完成」同款系统玻璃胶囊
                    Button("刷新") { Task { await load() } }
                }
            }
        }
        .task { await load() }
        .fileExporter(isPresented: $showExporter,
                      document: LogDocument(text: exportText),
                      contentType: .plainText,
                      defaultFilename: "qingliao-logs") { _ in }
        }
    }

    /// 日志导出文档
    struct LogDocument: FileDocument {
        var text: String
        static var readableContentTypes: [UTType] { [.plainText] }
        init(text: String) { self.text = text }
        init(configuration: ReadConfiguration) throws {
            text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
        }
        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
            FileWrapper(regularFileWithContents: Data(text.utf8))
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let j = try await auth.json("/api/logs/sys")
            if let arr = j["logs"] as? [String] {
                logs = arr
            } else if let arr = j["logs"] as? [[String: Any]] {
                logs = arr.compactMap { $0["msg"] as? String ?? $0["message"] as? String ?? $0["line"] as? String }
            }
        } catch {
            logs = []
        }
    }
}

// MARK: - 新建 / 编辑定时任务

struct NewTaskSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    /// v3.9.40（#17）：nil = 新建（POST），非 nil = 编辑（PATCH 该任务）
    let editing: CronTask?
    @State private var name = ""
    @State private var cron = "0 9 * * *"
    @State private var prompt = ""
    @State private var saving = false
    @State private var errorText: String?

    init(editing: CronTask? = nil) {
        self.editing = editing
        let c = editing?.cron ?? ""
        _name = State(initialValue: editing?.name ?? "")
        _cron = State(initialValue: c.isEmpty ? "0 9 * * *" : c)
        _prompt = State(initialValue: editing?.prompt ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(editing == nil ? "新建定时任务" : "编辑定时任务")
                    .font(.system(size: Typography.title, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.titleXL)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }

            TextField("任务名称（如：每日早报）", text: $name)
                .font(.system(size: Typography.body))
                .textFieldStyle(.roundedBorder)
            TextField("Cron 表达式（如 0 9 * * *）", text: $cron)
                .font(.system(size: Typography.subhead, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $prompt)
                .font(.system(size: Typography.subhead))
                .frame(height: 110)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.icon)
                        .strokeBorder(Color.secondary.opacity(Tint.strong), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("任务提示词（发给 AI 的执行指令）")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.tertiary)
                            .padding(Spacing.md)
                    }
                }
            if let errorText {
                Text(errorText).font(.system(size: Typography.subhead)).foregroundStyle(.red)
            }
            Button {
                save()
            } label: {
                HStack {
                    Spacer()
                    if saving { ProgressView() } else { Text("保存任务") }
                    Spacer()
                }
                .font(.system(size: Typography.body, weight: .semibold))
                .frame(maxWidth: .infinity)
                .pill(.primary)
            }
            .buttonStyle(.plain)
            .disabled(saving || name.isEmpty || cron.isEmpty || prompt.isEmpty)
            Spacer()
        }
        .padding(18)
    }

    private func save() {
        saving = true
        errorText = nil
        Task {
            defer { saving = false }
            do {
                if let t = editing {
                    // PATCH 由 cron_api 原样转发 Hermes 的响应，没有统一 ok 字段 → 不带 error 即成功
                    let j = try await auth.json("/api/cron/tasks/\(t.id)", method: "PATCH",
                                                body: ["name": name, "cron": cron, "prompt": prompt])
                    if let err = j["error"] as? String {
                        errorText = err
                    } else {
                        dismiss()
                    }
                } else {
                    let j = try await auth.json("/api/cron/tasks", method: "POST", body: [
                        "name": name, "cron": cron, "prompt": prompt
                    ])
                    if (j["ok"] as? Bool) == true {
                        dismiss()
                    } else {
                        errorText = (j["error"] as? String) ?? "保存失败"
                    }
                }
            } catch {
                errorText = "请求失败：\(error.localizedDescription)"
            }
        }
    }
}
