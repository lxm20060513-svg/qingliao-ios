import SwiftUI
import LocalAuthentication

// MARK: - 密码管理（NAS SSH / 路由器 / 其他凭据，服务器端 Fernet 加密存储）

struct SecretEntry: Identifiable {
    let id: String
    var name: String
    var type: String      // nas / router / other
    var address: String
    var username: String
    var hasPassword: Bool
    var password: String = ""   // 明文（仅 reveal 后填充）
}

struct SecretsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [SecretEntry] = []
    @State private var loading = true
    @State private var showEdit = false
    @State private var editing: SecretEntry?
    @State private var toast = ""
    // Face ID / 生物识别解锁
    @State private var locked = true
    @State private var authFailed = false

    var body: some View {
        VStack(spacing: 0) {
            if locked {
                // 生物识别锁屏：验证通过才显示内容
                VStack(spacing: 16) {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 76, height: 76)
                        Image(systemName: "faceid")
                            .font(.system(size: 34))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text("密码管理已锁定")
                        .font(.system(size: 15, weight: .semibold))
                    Text("使用 Face ID / 面容验证解锁")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if authFailed {
                        Text("验证失败，请重试")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                    Button {
                        authenticate()
                    } label: {
                        Text("解锁")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 44).padding(.vertical, 11)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .systemBackground))
            } else {
                content
            }
        }
        .task {
            if locked { authenticate() }
        }
    }

    private var content: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if loading {
                Spacer()
                ProgressView().tint(.secondary)
                Spacer()
            } else if entries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text("暂无凭据")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    Text("点击右上角 + 添加 NAS SSH / 路由器密码")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(entries) { e in
                            SecretRow(entry: e, onReveal: { reveal(e) }, onEdit: { edit(e) }, onDelete: { delete(e) })
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .task { await load() }
        .sheet(isPresented: $showEdit) {
            SecretEditSheet(entry: editing, onSave: { newEntry in
                Task { await save(newEntry) }
            })
            .presentationDetents([.medium])
        }
        .overlay(alignment: .bottom) {
            if !toast.isEmpty {
                Text(toast)
                    .font(.system(size: 12))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .navigationTitle("密码管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = SecretEntry(id: "", name: "", type: "nas", address: "", username: "", hasPassword: false)
                    showEdit = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        }
    }

    /// Face ID / 面容验证（失败可重试）
    /// v2.0.102：无生物识别设备直接放行（原恒 locked 只能关闭页面）
    private func authenticate() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            locked = false   // 设备无生物识别 → 不锁（个人自用 App 降级为明文可见）
            authFailed = false
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: "验证后查看已加密保存的 NAS / 路由器密码") { success, _ in
            DispatchQueue.main.async {
                if success {
                    locked = false
                    authFailed = false
                } else {
                    authFailed = true
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let j = try await auth.json("/api/secrets")
            entries = (j["secrets"] as? [[String: Any]] ?? []).compactMap { d in
                guard let id = d["id"] as? String else { return nil }
                return SecretEntry(id: id,
                                   name: d["name"] as? String ?? "",
                                   type: d["type"] as? String ?? "other",
                                   address: d["address"] as? String ?? "",
                                   username: d["username"] as? String ?? "",
                                   hasPassword: (d["has_password"] as? Bool) ?? false)
            }
        } catch {
            toast = "加载失败：\(error.localizedDescription)"
        }
    }

    private func reveal(_ e: SecretEntry) {
        Task {
            do {
                let j = try await auth.json("/api/secrets/\(e.id)?reveal=true")
                let pw = j["password"] as? String ?? ""
                if let idx = entries.firstIndex(where: { $0.id == e.id }) {
                    entries[idx].password = pw
                }
            } catch {
                toast = "获取失败"
            }
        }
    }

    private func edit(_ e: SecretEntry) {
        editing = e
        showEdit = true
    }

    private func delete(_ e: SecretEntry) {
        Task {
            // v2.0.102：仅服务器确认成功才移除（失败保留，重进不"复活"）
            if let j = try? await auth.json("/api/secrets/\(e.id)", method: "DELETE", body: nil),
               (j["ok"] as? Bool) == true {
                entries.removeAll { $0.id == e.id }
            } else {
                toast = "删除失败，请重试"
            }
        }
    }

    private func save(_ e: SecretEntry) async {
        do {
            var body: [String: Any] = [
                "name": e.name, "type": e.type, "address": e.address, "username": e.username
            ]
            if !e.id.isEmpty { body["id"] = e.id }
            if !e.password.isEmpty { body["password"] = e.password }
            let j = try await auth.json("/api/secrets", method: "POST", body: body)
            if (j["ok"] as? Bool) == true {
                toast = "已保存"
                await load()
            } else {
                toast = (j["error"] as? String) ?? "保存失败"
            }
        } catch {
            toast = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 单条凭据行（眼睛查看 / 复制 / 编辑 / 删除）

struct SecretRow: View {
    let entry: SecretEntry
    let onReveal: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var typeIcon: String {
        switch entry.type {
        case "nas": return "🖥"
        case "router": return "📡"
        default: return "🔑"
        }
    }
    private var typeName: String {
        switch entry.type {
        case "nas": return "NAS"
        case "router": return "路由器"
        default: return "其他"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(typeIcon).font(.system(size: 16))
                Text(entry.name)
                    .font(.system(size: 14, weight: .semibold))
                Text(typeName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                Spacer()
                // 复制完整连接串
                Button {
                    UIPasteboard.general.string = "\(entry.username)@\(entry.address)"
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                Button { onEdit() } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                Button { onDelete() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                Text("地址：\(entry.address)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text("用户：\(entry.username)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            // 密码：默认掩码，点击眼睛显示明文
            HStack(spacing: 8) {
                Text(entry.password.isEmpty ? "密码：••••••••" : "密码：\(entry.password)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(entry.password.isEmpty ? .secondary : .primary)
                if entry.password.isEmpty {
                    Button {
                        onReveal()
                    } label: {
                        Image(systemName: "eye")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        UIPasteboard.general.string = entry.password
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

// MARK: - 新增/编辑表单

struct SecretEditSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let entry: SecretEntry?
    let onSave: (SecretEntry) -> Void

    @State private var name = ""
    @State private var type = "nas"
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(entry?.id.isEmpty == false ? "编辑凭据" : "新增凭据")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Picker("类型", selection: $type) {
                Text("NAS").tag("nas")
                Text("路由器").tag("router")
                Text("其他").tag("other")
            }
            .pickerStyle(.segmented)
            TextField("名称（如：NAS SSH）", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("地址（IP 或 域名:端口）", text: $address)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
            TextField("用户名", text: $username)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
            SecureField(entry?.hasPassword == true ? "新密码（留空保持不变）" : "密码", text: $password)
                .textFieldStyle(.roundedBorder)
            Button {
                var e = entry ?? SecretEntry(id: "", name: "", type: "nas", address: "", username: "", hasPassword: false)
                e.name = name; e.type = type; e.address = address; e.username = username
                if !password.isEmpty { e.password = password }
                onSave(e)
                dismiss()
            } label: {
                HStack {
                    Spacer()
                    Text("保存")
                    Spacer()
                }
                .padding(.vertical, 11)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
                .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(name.isEmpty || address.isEmpty || username.isEmpty)
            Spacer()
        }
        .padding(18)
        .onAppear {
            if let entry {
                name = entry.name
                type = entry.type
                address = entry.address
                username = entry.username
            }
        }
    }
}
