// 本文件由 2026-09-27 工程治理「Settings 物理合并」生成：多份同域设置页文件合并为一，
// UI 入口与行为零改动，仅文件边界变化。合并前各文件的来源见下方 MARK 分段。

import Combine
import Foundation
import LocalAuthentication
import PDFKit
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: ===== 以下原为 Features/Settings/SettingsSheets.swift =====

// MARK: - 设置二级 Sheet（v3.0.80 自 SettingsView.swift 拆出，纯搬家无逻辑改动）
// 内容：服务器地址 / 钉一钉路径 / 修改密码 / 通用行组件 / 会话存储位置


// MARK: - 服务器地址修改

struct ServerSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var server = ""
    @State private var saved = false
    @State private var validationError: String?

    /// 校验服务器地址格式（host:port 或 URL；端口 1-65535）
    private func validate(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "请输入服务器地址" }
        let stripped = s.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        let parts = stripped.split(separator: ":")
        if parts.count > 2 {
            // v-review fix：冒号多于 1 段 → IPv6 字面量地址（fe80::1 / fe80::1:8123 等），
            // 不再按 host:port 拆分拒绝；仅做基本的非空/无空白与路径校验
            let ipv6 = stripped.trimmingCharacters(in: .whitespaces)
            guard !ipv6.isEmpty else { return "主机名不能为空" }
            if ipv6.contains(" ") || ipv6.contains("/") {
                return "IPv6 地址格式非法"
            }
            return nil
        }
        let host = String(parts[0]).trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return "主机名不能为空" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        if host.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "主机名含非法字符"
        }
        if parts.count == 2 {
            let portStr = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard let port = Int(portStr), port >= 1, port <= 65535 else {
                return "端口号须为 1-65535"
            }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("修改后需重新登录")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.sheetInset)
                    .padding(.top, Spacing.xs)

                TextField("server.example.com:8080", text: $server)
                    .font(.system(size: Typography.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(Spacing.xl)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    .padding(.horizontal, Spacing.sheetInset)
                    .padding(.top, Spacing.xxl)
                    .onChange(of: server) { _, _ in validationError = nil }

                if let err = validationError {
                    Text(err)
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, Spacing.xs)
                }

                Button {
                    if let err = validate(server) {
                        validationError = err
                        return
                    }
                    // SR9：统一走 AuthStore 的规范化口径（原来这里补 http://，
                    // 而 SafariRelay/上传/后台刷新补 https://，同一裸地址两种协议）
                    let s = AuthStore.normalizedServerURL(server)
                    auth.serverURL = s
                    UserDefaults.standard.set(s, forKey: "qingliao_server")
                    saved = true
                    Task { try? await Task.sleep(for: .seconds(0.8)); auth.logout() }
                } label: {
                    Text("保存并重新登录")
                    .font(.system(size: Typography.body, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .pill(.primary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.sheetInset)
            .padding(.top, Spacing.xl)

            if saved {
                Text("已保存，正在返回登录...")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.green)
                    .padding(.top, Spacing.md)
            }

            Spacer()
        }
        .navigationTitle("服务器地址")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        .onAppear {
            server = auth.serverURL.replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: "")
        }
        }
    }
}


// MARK: - 钉一钉存储路径（v3.0.77：由系统 .alert 改为 App 统一底部 sheet，对齐 PasswordSheet 风格）

struct PinPathSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("默认: /volume1/.../轻聊app", text: $path)
                    .font(.system(size: Typography.body))
                    .padding(Spacing.xl)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    .padding(.horizontal, Spacing.sheetInset)
                    .padding(.top, Spacing.xxl)

                Text("NAS 上的存储目录路径，pins.json 保存在此目录下")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.sheetInset)
                    .padding(.top, Spacing.lg)

                Button {
                    PinStore.shared.storagePath = path.trimmingCharacters(in: .whitespaces)
                    dismiss()
                } label: {
                    Text("确定")
                        .font(.system(size: Typography.body, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .pill(.primary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.top, Spacing.xl)

                Button {
                    PinStore.shared.storagePath = ""
                    dismiss()
                } label: {
                    Text("恢复默认")
                        .font(.system(size: Typography.body, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.xl)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.top, Spacing.lg)

                Spacer()
            }
            .navigationTitle("钉一钉存储路径")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear { path = PinStore.shared.storagePath }
    }
}

// MARK: - 修改密码

struct PasswordSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""   // v2.0.83c：新密码二次确认
    @State private var result: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SecureField("当前密码", text: $oldPassword)
                .font(.system(size: Typography.body))
                .padding(Spacing.xl)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.top, Spacing.xxl)

            SecureField("新密码", text: $newPassword)
                .font(.system(size: Typography.body))
                .padding(Spacing.xl)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.top, Spacing.lg)

            // v2.0.83c：新密码二次确认（两次一致才可提交）
            SecureField("确认新密码", text: $confirmPassword)
                .font(.system(size: Typography.body))
                .padding(Spacing.xl)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.top, Spacing.lg)
            if !confirmPassword.isEmpty && confirmPassword != newPassword {
                Text("两次输入的密码不一致")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.sheetInset)
                    .padding(.top, Spacing.xs)
            }

            Button {
                changePassword()
            } label: {
                Text(busy ? "提交中..." : "确认修改")
                    .font(.system(size: Typography.body, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .pill(.primary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.sheetInset)
            .padding(.top, Spacing.xl)

            if let r = result {
                Text(r)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(r.contains("成功") ? Color.green : Color.red)
                    .padding(.top, Spacing.md)
            }

            Spacer()
        }
        .navigationTitle("修改密码")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        }
    }

    private func changePassword() {
        // v2.0.83c：新密码二次确认校验
        guard !oldPassword.isEmpty, !newPassword.isEmpty, !busy else { return }
        guard newPassword == confirmPassword else {
            result = "两次输入的密码不一致"
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let j = try await auth.json("/api/auth/change-password", method: "POST", body: [
                    "old": oldPassword, "new": newPassword
                ])
                if (j["ok"] as? Bool) ?? false {
                    result = "✅ 修改成功，请重新登录"
                    Task { try? await Task.sleep(for: .seconds(1.2)); auth.logout() }
                } else {
                    result = "⚠️ " + ((j["error"] as? String) ?? "修改失败")
                }
            } catch {
                result = "❌ 修改失败，请检查当前密码"
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: Typography.subhead, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.sheetInset)
            .padding(.top, Spacing.xxl)
            .padding(.bottom, Spacing.xs)
    }
}

struct SettingRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var value: String? = nil
    var chevron: Bool = false
    // v2.0.87az：行尾开关（替代独立 Toggle 行，避免错位）
    var toggle: Binding<Bool>? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(iconColor, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
            Text(title)
                .font(.system(size: Typography.body))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)   // 与 SettingsModelSheets 的音色行同口径（显式留最小间距）
            if let value {
                // v3.9.80：行尾值钉单行——值折成两行时左标题会被垂直居中夹住 = 真机报过的
                // 「系统音色文字错位」同款（那一行已修；这里是共用的行组件，一处修覆盖设置页所有行）
                Text(value)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            // v2.0.87az：行尾开关
            if let toggle {
                Toggle("", isOn: toggle)
                    .labelsHidden()
                    .scaleEffect(0.8)
                    .tint(.green)
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .contentShape(Rectangle())
    }
}

// MARK: - 会话存储位置设置（NAS 目录，服务器持久化）

struct SessionLocSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let currentPath: String
    @State private var path = ""
    @State private var result: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("设置 NAS 上存储会话记录的目录（需为服务器可写路径）")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            TextField("如 /volume1/docker/轻聊数据/sessions", text: $path)
                .font(.system(size: Typography.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(Spacing.xl)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
            if let result {
                Text(result)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(result.hasPrefix("✅") ? Color.green : Color.red)
            }
            Button {
                save()
            } label: {
                HStack {
                    Spacer()
                    if saving { ProgressView() } else { Text("保存") }
                    Spacer()
                }
                .font(.system(size: Typography.body, weight: .semibold))
                .frame(maxWidth: .infinity)
                .pill(.primary)
            }
            .buttonStyle(.plain)
            .disabled(saving)
            Spacer()
        }
        .padding(20)
        .navigationTitle("会话存储位置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        .onAppear { path = currentPath }
        }
    }

    private func save() {
        saving = true
        result = nil
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { saving = false }
            do {
                let j = try await auth.json("/api/sessions/location", method: "POST", body: ["path": p])
                if (j["ok"] as? Bool) == true {
                    result = "✅ 已保存：" + (j["path"] as? String ?? p)
                } else {
                    result = "❌ " + ((j["error"] as? String) ?? "保存失败")
                }
            } catch {
                result = "❌ 请求失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: ===== 以下原为 Features/Settings/SettingsPages.swift =====

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

// MARK: ===== 以下原为 Features/Settings/AppearanceSheet.swift =====

// v3.9.28：外观设置弹窗——从 CloudSettingsView 拆出独立文件（云端模式移除时误删，
// 但设置页「外观」入口仍在引用 → 灵动岛/流光/字体/行高/天气城市开关全丢了）。
struct AppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    // v3.0.2：全部用本地真实 key + 本地交互（主题用 qingliao_appearance，字体用 qingliao_font_size）
    @AppStorage("qingliao_appearance") private var appearance = "system"   // dark/light/system（对齐本地主题）
    @AppStorage("qingliao_font_size") private var fontSize = 15.0          // 12-20 聊天字体（对齐本地）
    @AppStorage("qingliao_ai_line_spacing") private var aiLineSpacing = 1.0  // AI 输出行高
    @AppStorage("qingliao_siri_glow") private var siriGlow = false
    // v3.0.36：灵动岛发光（独立开关，复用 Siri 发光 4 参数）
    @AppStorage("qingliao_island_glow") private var islandGlow = false
    // v3.8.0：灵动岛/锁屏实时活动（AI 回复中显示进度）——与 LiveActivityManager 共用同一 key（默认开）
    @AppStorage(LiveActivityManager.enabledKey) private var liveActivityOn = true
    @AppStorage("qingliao_siri_glow_brightness") private var glowBrightness = 1.0
    @AppStorage("qingliao_siri_glow_freq") private var glowFreq = 2.2
    @AppStorage("qingliao_siri_glow_amp") private var glowAmp = 0.18
    @AppStorage("qingliao_siri_glow_width") private var glowWidth = 22.0
    // v3.0.4：补全本地外观独有项（输入框流光 / 天气城市）
    @AppStorage("qingliao_input_glow") private var glowOn = true
    // v4.0.7：烟花粒子特效开关（DockTabView.fireDockBurst 读同一 key）
    @AppStorage("qingliao_dock_burst") private var dockBurstOn = true
    // v4.0.6：聊天页形象/表情/动作/动画档四组 key 已搬去 PetStudioSheet（外观页不再重复持有，
    // 否则两处 @AppStorage 同 key 也能跑，但「外观页改动不刷新预览」这类半联动问题会很难查）。
    @State private var weatherCity = UserDefaults.standard.string(forKey: "qingliao_weather_city") ?? ""
    @State private var showWeatherCityField = false
    // v3.9.94：启动会话（逻辑早已接好，见 LaunchSession.swift / ChatStore.swift:158-165，
    // 但外观页一直没给入口 → 用户根本设不了，永远吃默认值 .auto + 15 分钟）。
    // ⚠️ 必须用 @AppStorage 直接绑 UserDefaultsKey.*，不要自己在 onChange 里写回去：
    //    ChatStore 读的就是这两个 key，绕一层就可能与真值表/预检断言脱钩。
    @AppStorage(UserDefaultsKey.launchSessionMode) private var launchSessionMode = LaunchSessionMode.auto.rawValue
    @AppStorage(UserDefaultsKey.launchSessionMins) private var launchSessionMins = Double(LaunchSessionMode.defaultIdleMinutes)

    var body: some View {
        NavigationStack {
            Form {
                // 主题模式（对齐本地 appearanceOption 三段选择）
                Section("主题") {
                    HStack(spacing: 10) {
                        appearanceOption("浅色", value: "light")
                        appearanceOption("深色", value: "dark")
                        appearanceOption("跟随系统", value: "system")
                    }
                    .padding(.vertical, Spacing.xs)
                }
                // v3.9.78 的「聊天页形象」段（形象三选一 + 动画三档）**已于 v4.0.6 搬去 PetStudioSheet**
                // （用户：「外观里面的聊天页选项就可以移动到卡通宠物头像的设置里」）。
                // 搬走而非复制：两处都能改迟早会不一致，且外观页那个 petOption/motionOption 已无调用点。
                // 聊天页顶部仍是同一只宠物（共用 PetKeys.style/.motion/.quirks/.face 四个 key）。
                // 交互
                Section("交互") {
                    Toggle("输入框流光光效", isOn: $glowOn)   // v3.0.4：补全本地独有项
                    // v4.0.7：点 dock 智慧球的烟花粒子特效（用户：烟花也做个开关放设置里）
                    Toggle("烟花粒子特效", isOn: $dockBurstOn)
                    // v3.8.0：灵动岛/锁屏实时活动——AI 回复中亮起、结束收起；关掉立即收起正在显示的活动
                    Toggle("灵动岛实时活动", isOn: $liveActivityOn)
                        .onChange(of: liveActivityOn) { _, on in
                            if !on { Task { @MainActor in await LiveActivityManager.shared.end() } }
                        }
                }
                // v3.9.94：启动会话（用户拍板「设置里面增加启动会话设置……放在外观设置里」）
                // ⚠️ 这段 UI 是**补的入口**，不是新功能：判定逻辑在 LaunchSession.swift 早就有，
                //    ChatStore.swift:158-165 也一直在读这两个 key，只是外观页没给入口，
                //    所以用户一直只能吃默认的「自动 + 15 分钟」。
                Section("启动会话") {
                    HStack(spacing: 10) {
                        // ⚠️ case 名是 .last / .new（不是 .lastSession/.newSession）——
                        //    凭空造成员本机 -parse 查不出，CI Archive 才挂。
                        // 标题取 mode.title（单一真源），别在这里另写一份中文。
                        ForEach(LaunchSessionMode.allCases) { mode in
                            launchSessionOption(mode.title, value: mode)
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                    // 只有「自动」模式下阈值才有意义，另外两选一是恒定行为（跟随 / 强制新开）
                    if LaunchSessionMode(rawValue: launchSessionMode) == .auto {
                        // 档位跟 LaunchSessionMode.idleOptions 走（5/10/15/30/60/120），
                        // 不用随手写的 Slider 5...60 step 5：那样 UI 会漏掉 120 档，
                        // 而且以后加档位得改两处，容易漂。
                        HStack(spacing: 10) {
                            Text("闲置超时").font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(launchSessionMins)) 分钟")
                                .font(.system(size: Typography.subhead))
                                .foregroundStyle(.secondary)
                        }
                        // 6 档用两行网格，别挤在一行（外放页左右余量只有 ~60pt/档，标签会压缩到认不出）
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 3), spacing: Spacing.sm) {
                            ForEach(LaunchSessionMode.idleOptions, id: \.self) { m in
                                idleOption(m)
                            }
                        }
                        Text("上次打开 App 距今超过 \(Int(launchSessionMins)) 分钟，就自动开一个新对话；不足则接着上次那个聊。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                // AI 回答发光（对齐本地 Siri 发光 4 参数）
                Section("AI 回答发光") {
                    Toggle("边框光晕", isOn: $siriGlow)
                    // v3.0.36：灵动岛光晕（独立开关）
                    Toggle("灵动岛光晕", isOn: $islandGlow)
                    if siriGlow || islandGlow {
                        sliderRow("亮度", value: $glowBrightness, range: 0.2...1.5, suffix: { String(format: "%.0f%%", $0 * 100) })
                        sliderRow("呼吸频率", value: $glowFreq, range: 0.5...6.0, suffix: { String(format: "%.1f", $0) })
                        sliderRow("呼吸幅度", value: $glowAmp, range: 0...0.4, suffix: { String(format: "%.2f", $0) })
                        sliderRow("光带范围", value: $glowWidth, range: 10...44, suffix: { String(format: "%.0fpt", $0) })
                    }
                }
                // 文本（对齐本地：字体大小滑条 + AI 行高滑条）
                Section("文本") {
                    HStack {
                        Text("聊天字体大小")
                            .font(.system(size: Typography.body))
                        Spacer()
                        Text("\(Int(fontSize))")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Text("小").font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                        Slider(value: $fontSize, in: 12...20, step: 1)
                            .tint(Color.accentColor)
                        Text("大").font(.system(size: Typography.title)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("AI 输出行高")
                            .font(.system(size: Typography.body))
                        Spacer()
                        Text(String(format: "%.1f", aiLineSpacing))
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Text("紧凑").font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                        Slider(value: $aiLineSpacing, in: 0...6, step: 0.5)
                            .tint(Color.accentColor)
                        Text("宽松").font(.system(size: Typography.title)).foregroundStyle(.secondary)
                    }
                }
                // 天气（v3.0.4：补全本地外观独有项）
                Section("天气") {
                    HStack {
                        Text("天气城市")
                            .font(.system(size: Typography.body))
                        Spacer(minLength: 8)
                        Text(weatherCity.isEmpty ? "未设置" : weatherCity)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                            // v3.9.80：钉单行（城市名长时折行会把左标题夹成垂直居中，与设置页行口径一致）
                            .lineLimit(1)
                    }
                    if showWeatherCityField {
                        HStack(spacing: 10) {
                            TextField("如：上海 / 北京", text: $weatherCity)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never)
                            Button("保存") {
                                UserDefaults.standard.set(weatherCity.trimmingCharacters(in: .whitespaces), forKey: "qingliao_weather_city")
                                showWeatherCityField = false
                            }
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        }
                    } else {
                        Button("设置城市") {
                            withAnimation(Motion.snap) { showWeatherCityField = true }
                        }
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .navigationTitle("外观设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 主题选项（对齐本地 appearanceOption：选中高亮段）
    private func appearanceOption(_ name: String, value: String) -> some View {
        Button {
            appearance = value
        } label: {
            Text(name)
                .font(.system(size: Typography.subhead, weight: .medium))
                .foregroundStyle(appearance == value ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(appearance == value ? Color.accentColor : Color(uiColor: .systemGray5))
                )
        }
        .buttonStyle(.plain)
    }

    /// v3.9.94：启动会话选项（三选一）——与 appearanceOption 同一 idiom（选中高亮段），
    /// 实参序＝声明序（name: String, value: LaunchSessionMode），错位只有 CI Archive 报得出
    private func launchSessionOption(_ name: String, value: LaunchSessionMode) -> some View {
        let selected = launchSessionMode == value.rawValue
        return Button {
            launchSessionMode = value.rawValue
        } label: {
            Text(name)
                .font(.system(size: Typography.subhead, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(selected ? Color.accentColor : Color(uiColor: .systemGray5))
                )
        }
        .buttonStyle(.plain)
    }

    /// v3.9.94：闲置超时档位按钮（5/10/15/30/60/120，档位表来自 LaunchSessionMode.idleOptions）
    /// 实参序＝声明序（minutes: Int）
    private func idleOption(_ minutes: Int) -> some View {
        let selected = Int(launchSessionMins) == minutes
        return Button {
            launchSessionMins = Double(minutes)
        } label: {
            Text("\(minutes)")
                .font(.system(size: Typography.subhead, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(selected ? Color.accentColor : Color(uiColor: .systemGray5))
                )
        }
        .buttonStyle(.plain)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           suffix: @escaping (Double) -> String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: Typography.subhead)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range).tint(Color.accentColor)
            Text(suffix(value.wrappedValue)).font(.system(size: Typography.subhead)).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, Spacing.xxs)
    }
}
