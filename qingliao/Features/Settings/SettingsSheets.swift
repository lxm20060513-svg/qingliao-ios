// MARK: - 设置二级 Sheet（v3.0.80 自 SettingsView.swift 拆出，纯搬家无逻辑改动）
// 内容：服务器地址 / 钉一钉路径 / 修改密码 / 通用行组件 / 会话存储位置

import SwiftUI

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

