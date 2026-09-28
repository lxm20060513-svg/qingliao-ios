// v4.0.x 网盘接入设置（设置 → 网盘接入）
//
// 位置口径：用户明确要求「网盘接入放在设置里，不放在连接器卡片」——连接器面板只做
// MCP / 智能家居 / 生活卡片三类总览，网盘不进那里，避免把「装 skill + 授权」这种重动作
// 混进只读状态面板。
//
// 交互照 MailSettingsSheet（列表 + 右上 + 新增表单 + 二次确认删除 + 顶部回执行），
// 数据走既有 /api/clouddrive/drives|add|remove（后端 clouddrive_api.py 已上线，
// nginx server.d/qingliao_http.conf(16668) 与 webui_443.conf 两处 location 均已放通，
// stream_api ALLOWED_RELAY 含 /api/clouddrive）。
//
// 安全口径：技能地址 + 授权码只 POST 给后端，App 侧不落盘任何明文；列表只回显昵称/状态。

import SwiftUI

// MARK: - 数据模型

struct CloudDriveItem: Identifiable {
    let id: String
    let name: String
    let nickname: String
    let status: String          // ready / error
    let error: String
    let addedAt: TimeInterval

    var isReady: Bool { status == "ready" }

    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? ""
        name = d["name"] as? String ?? ""
        nickname = d["nickname"] as? String ?? ""
        status = d["status"] as? String ?? "ready"
        error = d["error"] as? String ?? ""
        addedAt = TimeInterval((d["added_at"] as? Int) ?? 0)
    }
}

// MARK: - 列表页

struct CloudDriveSettingsSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var drives: [CloudDriveItem] = []
    @State private var loading = false
    @State private var errMsg: String?
    @State private var feedback: String?
    @State private var showAdd = false
    @State private var pendingDelete: CloudDriveItem?
    /// 点行进网盘文件浏览（设置 → 文件管理 之外的第二个浏览入口）
    @State private var browsingDrive: CloudDriveItem?

    var body: some View {
        NavigationStack {
            Form {
                if let f = feedback {
                    Section {
                        Text(f)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(f.hasPrefix("❌") ? Color.red : Color.green)
                    }
                }
                if loading {
                    Section { LoadingStateView(shape: .rows(2), horizontalPadding: 0) }
                } else if let errMsg {
                    Section {
                        Text("⚠️ \(errMsg)")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.orange)
                    }
                } else {
                    listSection
                    addSection
                    hintSection
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("网盘接入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            // 同一宿主多 sheet 互斥：新增表单开之前先清掉删除确认态
            .sheet(isPresented: $showAdd, onDismiss: { Task { await load() } }) {
                CloudDriveAddSheet()
                    .scrollContentBackground(.hidden)
            }
            .confirmationDialog(removeDialogTitle,
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("解绑", role: .destructive) {
                    if let d = pendingDelete { Task { await remove(d) } }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            }
            // 点行进网盘文件浏览（与新增表单入口互斥可达才安全；onDismiss 必须复位 item，
            // 否则某次 present 被别的弹层吞掉后 item 卡非 nil → 之后点行再也打不开浏览页）
            .sheet(item: $browsingDrive, onDismiss: { browsingDrive = nil }) { d in
                CloudDriveBrowserSheet(drive: d)
            }
            .task { await load() }
        }
    }

    private var removeDialogTitle: String {
        guard let d = pendingDelete else { return "解绑网盘？" }
        return "解绑 \(displayName(d))？"
    }

    @ViewBuilder private var listSection: some View {
        Section("已接入（\(drives.count)）") {
            if drives.isEmpty {
                Text("暂无——点右上角 + 接入，如夸克网盘")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.tertiary)
            }
            ForEach(drives) { d in
                row(d)
            }
        }
    }

    private func row(_ d: CloudDriveItem) -> some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.teal, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(displayName(d))
                    .font(.system(size: Typography.body, weight: .medium))
                    .lineLimit(1)
                Text(subtitle(d))
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(subtitleColor(d))
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { browsingDrive = d }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { pendingDelete = d } label: { Label("解绑", systemImage: "trash") }
        }
    }

    private func displayName(_ d: CloudDriveItem) -> String {
        d.name.isEmpty ? d.id : d.name
    }

    private func subtitle(_ d: CloudDriveItem) -> String {
        if !d.isReady {
            return d.error.isEmpty ? "授权异常 · 重新接入可修复" : d.error
        }
        return d.nickname.isEmpty ? "已授权" : "已授权 · \(d.nickname)"
    }

    private func subtitleColor(_ d: CloudDriveItem) -> Color {
        d.isReady ? .green : .red
    }

    @ViewBuilder private var addSection: some View {
        Section("添加") {
            Button { showAdd = true } label: {
                Label("接入网盘（推荐）", systemImage: "plus.circle.fill")
            }
        }
    }

    @ViewBuilder private var hintSection: some View {
        Section {
            Text("从网盘官方 App 申请技能地址 + 授权码，粘贴进来由后端完成安装与授权。授权码只提交给后端，App 不保存明文。")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: 网络

    private func load() async {
        loading = true
        errMsg = nil
        defer { loading = false }
        do {
            // v4.0.x: 走 /api/agent/clouddrive 别名——lucky(16666) 白名单只放 /api/agent 前缀，
            // 原 /api/clouddrive 路径在 App 主链路上被 lucky 404（真机反馈「加载失败 服务器 错误404」）
            let d = try await auth.json("/api/agent/clouddrive/drives")
            guard let ok = d["ok"] as? Bool, ok else {
                errMsg = d["error"] as? String ?? "加载失败"
                return
            }
            var arr: [CloudDriveItem] = []
            if let list = d["drives"] as? [[String: Any]] {
                for x in list { arr.append(CloudDriveItem(x)) }
            }
            drives = arr
        } catch {
            errMsg = "加载失败：\(error.localizedDescription)"
        }
    }

    /// 200 + ok:false 也是失败（后端异常都包在 200 里），必须查 ok
    private func remove(_ d: CloudDriveItem) async {
        do {
            let j = try await auth.json("/api/agent/clouddrive/remove", method: "POST", body: ["id": d.id])
            guard (j["ok"] as? Bool) ?? false else {
                feedback = "❌ 解绑失败：\(j["error"] as? String ?? "服务器拒绝")"
                return
            }
            feedback = "✅ 已解绑 \(displayName(d))"
            await load()
        } catch {
            feedback = "❌ 解绑失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 新增表单

struct CloudDriveAddSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var skillURL = ""
    @State private var authCode = ""
    @State private var saving = false
    @State private var feedback: String?

    /// 必须是 https 且以 .zip 结尾——后端 install_skill 会下载解压，错地址会白跑一次安装
    private var urlLooksValid: Bool {
        let u = skillURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return u.hasPrefix("https://") && u.hasSuffix(".zip")
    }

    private var canSave: Bool {
        urlLooksValid && !authCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("网盘技能包") {
                    TextField("技能地址（https://….zip）", text: $skillURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if !skillURL.isEmpty && !urlLooksValid {
                        Text("技能地址必须是 https 开头的 .zip 链接")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.orange)
                    }
                }

                Section("授权码") {
                    SecureField("网盘授权码（CAC-…）", text: $authCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("在网盘官方 App 内申请「授权」，会得到技能地址和授权码两项。")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.secondary)
                }

                if let f = feedback {
                    Section {
                        Text(f)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(f.hasPrefix("❌") ? Color.red : Color.green)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Spacer()
                            if saving {
                                ProgressView()
                            } else {
                                Text("安装并授权")
                            }
                            Spacer()
                        }
                        .font(.system(size: Typography.body, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .pill(.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                }

                Section {
                    Text("安装由后端执行，可能需要 10～60 秒。授权码只 POST 给后端，App 不保存明文。")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("接入网盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let j = try await auth.json("/api/agent/clouddrive/add", method: "POST",
                                        body: ["skill_url": skillURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                               "auth_code": authCode.trimmingCharacters(in: .whitespacesAndNewlines)])
            if (j["ok"] as? Bool) == true {
                await MainActor.run {
                    Haptics.success()
                    dismiss()
                }
            } else {
                await MainActor.run { Haptics.error() }
                feedback = "❌ " + ((j["error"] as? String) ?? "服务器未确认成功")
            }
        } catch {
            await MainActor.run { Haptics.error() }
            feedback = "❌ 接入失败：\(error.localizedDescription)"
        }
    }
}
