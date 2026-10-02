// v4.0.x 邮件接入设置（App 配 IMAP/SMTP → 后端 mail_api → AI 可收发邮件）
//
// 交互照 MCPSettingsSheet（列表 + 右上 + 新增表单 + 二次确认删除 + 顶部回执行），
// 数据走既有 /api/mail/accounts|test|send（后端 mail_api.py 已在跑，nginx 三处已接）。
// 授权码 Fernet 加密落在后端，App 侧永远不存明文、列表也不回显。

import SwiftUI

// MARK: - 数据模型

struct MailAccountItem: Identifiable {
    let id: String
    let email: String
    let nickname: String
    let imapHost: String
    let imapPort: Int
    let imapSecurity: String
    let smtpHost: String
    let smtpPort: Int
    let smtpSecurity: String
    let allowDirectSend: Bool
    let hasSecret: Bool
    let isDefault: Bool
    let lastTestOK: Bool?      // nil = 从没测过
    let lastTestError: String

    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? ""
        email = d["email"] as? String ?? ""
        nickname = d["nickname"] as? String ?? ""
        imapHost = d["imap_host"] as? String ?? ""
        imapPort = (d["imap_port"] as? Int) ?? 993
        imapSecurity = d["imap_security"] as? String ?? "ssl"
        smtpHost = d["smtp_host"] as? String ?? ""
        smtpPort = (d["smtp_port"] as? Int) ?? 465
        smtpSecurity = d["smtp_security"] as? String ?? "ssl"
        allowDirectSend = (d["allow_direct_send"] as? Bool) ?? false
        hasSecret = (d["has_secret"] as? Bool) ?? false
        isDefault = (d["default"] as? Bool) ?? false
        if let t = d["last_test"] as? [String: Any] {
            if t["ok"] is Bool { lastTestOK = t["ok"] as? Bool } else { lastTestOK = nil }
            lastTestError = t["error"] as? String ?? ""
        } else {
            lastTestOK = nil
            lastTestError = ""
        }
    }
}

// MARK: - 列表页

/// 邮件表单的呈现目标：.add = 新增，.edit(acc) = 编辑某账号。
/// 用它（而不是两个独立状态）是因为同宿主链式挂多条 .sheet 只有最后一条生效，
/// 新增/编辑必须共用一个 sheet 宿主；nil 表示不呈现。
enum MailEditTarget: Identifiable {
    case add
    case edit(MailAccountItem)

    var account: MailAccountItem? {
        if case .edit(let a) = self { return a }
        return nil
    }

    var id: String {
        if case .edit(let a) = self { return a.id }
        return "__add__"
    }
}

struct MailSettingsSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var accounts: [MailAccountItem] = []
    @State private var loading = false
    @State private var errMsg: String?
    @State private var feedback: String?
    // v4.0.x：新增/编辑共用**一个** sheet 宿主。
    // 原先是 showAdd(isPresented:) + editing(item:) 两条 .sheet 挂在同一视图上 ——
    // 同宿主链式挂多个 .sheet 时只有最后一条生效，另一个会被静默吞掉（真机表现为"点了没反应"），
    // 而且本地 -parse 与真值表都查不出。现统一用 editTarget 枚举：nil = 无表单，.add = 新增。
    @State private var editTarget: MailEditTarget?
    @State private var pendingDelete: MailAccountItem?

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
            .navigationTitle("邮件接入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { editTarget = .add } label: { Image(systemName: "plus") }
                }
            }
            // 新增/编辑共用一条 .sheet(item:)：MailEditTarget.add = 新增，.edit(acc) = 编辑。
            // 别再加回 .sheet(isPresented:) —— 同宿主两条 sheet 只有最后一条生效（见上方状态注释）。
            .sheet(item: $editTarget, onDismiss: { editTarget = nil }) { t in
                MailAccountEditSheet(account: t.account) { ok in
                    if ok { await load() }
                    return ok
                }
                // v4.0.20：设置域统一口径 [.medium, .large]（此前漏声明 → 打开即全高，与同类弹窗不一致）
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
            }
            .confirmationDialog("删除 \(pendingDelete?.email ?? "")？该邮箱的授权码会一并删除",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let a = pendingDelete { Task { await delete(a) } }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            }
            .task { await load() }
        }
    }

    @ViewBuilder private var listSection: some View {
        Section("已接入（\(accounts.count)）") {
            if accounts.isEmpty {
                Text("暂无——点右上角 + 添加，如 QQ / 163 / Gmail")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.tertiary)
            }
            ForEach(accounts) { a in
                row(a)
            }
        }
    }

    private func row(_ a: MailAccountItem) -> some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: "envelope.fill")
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Text(a.nickname.isEmpty ? a.email : a.nickname)
                        .font(.system(size: Typography.body, weight: .medium))
                        .lineLimit(1)
                    if a.isDefault {
                        Text("默认")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.blue)
                    }
                }
                Text(subtitle(a))
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(subtitleColor(a))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { editTarget = .edit(a) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { pendingDelete = a } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func subtitle(_ a: MailAccountItem) -> String {
        switch a.lastTestOK {
        case .some(true):  return a.allowDirectSend ? "收发正常 · AI 可直接发信" : "收发正常 · AI 只生成草稿"
        case .some(false): return "连接失败：\(a.lastTestError)"
        case nil:          return "未测试 · \(a.email)"
        }
    }

    private func subtitleColor(_ a: MailAccountItem) -> Color {
        switch a.lastTestOK {
        case .some(true):  return .green
        case .some(false): return .red
        case nil:          return .secondary
        }
    }

    @ViewBuilder private var addSection: some View {
        Section("添加") {
            Button { editTarget = .add } label: {
                Label("添加邮箱账号（推荐）", systemImage: "plus.circle.fill")
            }
        }
    }

    @ViewBuilder private var hintSection: some View {
        Section {
            Text("保存后在「聊天」里说\"帮我看下未读邮件\"或\"给张三写封说明并发出去\"，AI 会自动调用。授权码只存后端且已加密，App 不保存明文。")
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
            let d = try await auth.json("/api/mail/accounts")
            // mail_api 的响应约定：异常包在 200 里 → 必须查 ok（真值表 ql_mail 钉的就是这一行）
            guard let ok = d["ok"] as? Bool, ok else {
                errMsg = "加载失败"
                return
            }
            accounts = SettingsLoad.list(d, key: "accounts", make: MailAccountItem.init)
        } catch {
            errMsg = "加载失败：\(error.localizedDescription)"
        }
    }

    /// 200 + ok:false 也是失败（后端异常都包在 200 里），必须查 ok
    private func delete(_ a: MailAccountItem) async {
        do {
            let d = try await auth.json("/api/mail/accounts?id=\(a.id)", method: "DELETE")
            guard (d["ok"] as? Bool) ?? false else {
                feedback = "❌ 删除失败：\(d["error"] as? String ?? "服务器拒绝")"
                return
            }
            feedback = "✅ 已删除 \(a.email)"
            await load()
        } catch {
            feedback = "❌ 删除失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 新增 / 编辑表单

struct MailAccountEditSheet: View {
    /// nil = 新增
    let account: MailAccountItem?
    /// 返回 true = 已落盘，父层需刷新
    let onDone: (Bool) async -> Bool

    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var nickname = ""
    @State private var secret = ""
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var imapSecurity = "ssl"
    @State private var smtpHost = ""
    @State private var smtpPort = "465"
    @State private var smtpSecurity = "ssl"
    @State private var allowDirectSend = false
    @State private var isDefault = false
    @State private var showAdvanced = false
    @State private var saving = false
    @State private var testing = false
    @State private var feedback: String?

    var isEditing: Bool { account != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    TextField("邮箱地址（如 me@qq.com）", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    TextField("备注名（可选，如「工作」）", text: $nickname)
                }

                Section("授权码 / 密码") {
                    SecureField(isEditing ? "已加密存储（留空不修改）" : "邮箱的 IMAP 授权码", text: $secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(secretHint)
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("允许 AI 直接发信", isOn: $allowDirectSend).qingliaoSwitch(hideLabel: false)
                    Text(allowDirectSend
                         ? "开启后 AI 可调用 SMTP 直接发送（你自己确认收件人后才会发）。"
                         : "关闭（推荐）：AI 只把邮件内容生成到聊天里，由你确认后自行发送。")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.secondary)
                }

                if isEditing {
                    Section {
                        Toggle("设为默认邮箱", isOn: $isDefault).qingliaoSwitch(hideLabel: false)
                    }
                }

                Section {
                    DisclosureGroup("高级（服务器地址）", isExpanded: $showAdvanced) {
                        LabeledContent("收 IMAP") {
                            TextField("主机", text: $imapHost)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("端口") {
                            TextField("993", text: $imapPort)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        Picker("加密", selection: $imapSecurity) {
                            Text("SSL").tag("ssl")
                            Text("STARTTLS").tag("starttls")
                            Text("不加密").tag("none")
                        }
                        LabeledContent("发 SMTP") {
                            TextField("主机", text: $smtpHost)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("端口") {
                            TextField("465", text: $smtpPort)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        Picker("加密", selection: $smtpSecurity) {
                            Text("SSL").tag("ssl")
                            Text("STARTTLS").tag("starttls")
                            Text("不加密").tag("none")
                        }
                    }
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
                        Task { await test() }
                    } label: {
                        HStack {
                            Spacer()
                            if testing { ProgressView() } else { Text("测试连接") }
                            Spacer()
                        }
                        .font(.system(size: Typography.body, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .pill(.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(testing || !canTest)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(isEditing ? "编辑邮箱" : "添加邮箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        guard !saving else { return }
                        Task { saving = true; _ = await save(); saving = false }
                    }
                    .disabled(!canSave || saving)
                }
            }
            .task { fillFromAccount() }
        }
    }

    private var secretHint: String {
        isEditing
            ? "留空表示保持原授权码不变。QQ / 163 需先在邮箱设置里开启 IMAP 并生成授权码；Gmail 需用应用专用密码。"
            : "QQ / 163 需先在邮箱设置里开启 IMAP 并生成授权码；Gmail 需用应用专用密码。"
    }

    private var canSave: Bool {
        guard email.contains("@") else { return false }
        return !isEditing || !secret.isEmpty || (account?.hasSecret ?? false)
    }

    // 后端 /api/mail/test 传空 secret 时会用账号里已存的密文（mail_api.py: `pwd=(body.get("secret") or "").strip() or None`），
    // 所以编辑态本来就有密文时不该逼用户重填——否则「已存的授权码到底通不通」这条最常用的自检反而没法做。
    private var canTest: Bool {
        email.contains("@") && (!secret.isEmpty || (isEditing && (account?.hasSecret ?? false)))
    }

    private func fillFromAccount() {
        guard let a = account else { return }
        email = a.email
        nickname = a.nickname
        imapHost = a.imapHost
        imapPort = String(a.imapPort)
        imapSecurity = a.imapSecurity
        smtpHost = a.smtpHost
        smtpPort = String(a.smtpPort)
        smtpSecurity = a.smtpSecurity
        allowDirectSend = a.allowDirectSend
        isDefault = a.isDefault
    }

    // MARK: 请求体

    private func body(includeSecret: Bool) -> [String: Any] {
        var b: [String: Any] = [
            "email": email,
            "nickname": nickname,
            "allow_direct_send": allowDirectSend,
            "default": isDefault,
        ]
        if let a = account { b["id"] = a.id }
        if includeSecret || !secret.isEmpty { b["secret"] = secret }
        // 高级项只在用户自己填了才下发，留空让后端按邮箱后缀猜
        if showAdvanced {
            if !imapHost.isEmpty { b["imap_host"] = imapHost }
            if let p = Int(imapPort) { b["imap_port"] = p }
            b["imap_security"] = imapSecurity
            if !smtpHost.isEmpty { b["smtp_host"] = smtpHost }
            if let p = Int(smtpPort) { b["smtp_port"] = p }
            b["smtp_security"] = smtpSecurity
        }
        return b
    }

    private func save() async -> Bool {
        do {
            let d = try await auth.json("/api/mail/accounts", method: "POST", body: body(includeSecret: true))
            guard (d["ok"] as? Bool) ?? false else {
                feedback = "❌ \(d["error"] as? String ?? "保存失败")"
                return false
            }
            // 保存成功必须关掉本表单：父层 onDone 只刷新列表，不关 sheet。
            // 不关 = 用户点完保存原地不动、无任何反馈，会当成没生效反复点
            // （v3.9.41 SR25 在 SettingsAccess 就定过「保存改成等结果再关」这条口径）。
            let ok = await onDone(true)
            if ok { dismiss() }
            return ok
        } catch {
            feedback = "❌ \(error.localizedDescription)"
            return false
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            // 草稿参数直测，不落盘；联网要 8~15s，放宽超时
            let d = try await auth.json("/api/mail/test", method: "POST",
                                        body: body(includeSecret: true), timeout: 45)
            let ok = (d["ok"] as? Bool) ?? false
            feedback = ok ? "✅ 连接正常" : "❌ \(d["error"] as? String ?? "连接失败")"
        } catch {
            feedback = "❌ \(error.localizedDescription)"
        }
    }
}
