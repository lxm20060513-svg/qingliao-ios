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

// MARK: ===== 以下原为 Features/Settings/ConnSettingsView.swift =====

// MARK: - v2.0.83c 连接设置二级页（服务器地址 / 测试连接 / 会话存储位置——从主设置页收进二级）
// v2.0.83f：List 白底改毛玻璃卡片风格（与主设置页 glassListCard 一致）

struct ConnSettingsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    // v4.0.61：钉一钉存储路径（用户 2026-10-05 要求：从主设置页搬到「连接设置」的「存储」下面）
    @State private var showPinPath = false
    /// v4.0.61 审查 7：搜索「钉一钉存储」直达只认**首次呈现**那一次，关掉后本页再出现不再自动弹
    @State private var didAutoOpenPinPath = false
    /// 搜索「钉一钉存储」直达：主设置页以 true 呈现本页时，进页即弹出该 sheet（免得再点一次）
    var initiallyShowPinPath: Bool = false
    @State private var showServerSheet = false
    @State private var showSessionLocSheet = false
    @State private var showUploadDirSheet = false   // v2.0.85 文件上传位置
    @State private var sessionLoc = ""
    @State private var uploadDir = ""
    @State private var testResult: String?
    @State private var testing = false

    private var shortServer: String {
        auth.serverURL
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    private var sessionLocShort: String {
        let parts = sessionLoc.split(separator: "/").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return "…/" + parts.suffix(2).joined(separator: "/")
        }
        return sessionLoc.isEmpty ? "默认" : sessionLoc
    }

    /// v4.0.61：钉一钉存储路径短显（与主设置页原样同款；PinStore 单例 = App 内单一真源）
    private var pinPathDisplay: String {
        let p = PinStore.shared.storagePath
        return p.isEmpty ? "默认路径" : (p.count > 20 ? "..." + p.suffix(17) : p)
    }

    /// v2.0.85：上传目录短显（取路径后两段）
    private var uploadDirShort: String {
        let parts = uploadDir.split(separator: "/").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return "…/" + parts.suffix(2).joined(separator: "/")
        }
        return uploadDir.isEmpty ? "默认" : uploadDir
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("服务器")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, Spacing.xs)
                    VStack(spacing: 0) {
                        SettingRow(icon: "globe.asia.australia.fill", iconColor: .green,
                                   title: "服务器地址", value: shortServer, chevron: true)
                            .onTapGesture { showServerSheet = true }
                        Divider().padding(.leading, Spacing.rowDividerInset)
                        SettingRow(icon: "network", iconColor: .blue,
                                   title: "测试连接", value: testing ? "检测中..." : nil,
                                   chevron: !testing)
                            .onTapGesture { testConnection() }
                        if let r = testResult {
                            Text(r)
                                .font(.system(size: Typography.caption))
                                .foregroundStyle(r.hasPrefix("✅") ? Color.green : Color.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Spacing.xxl)
                                .padding(.bottom, Spacing.md)
                                .padding(.top, Spacing.xxs)
                        }
                    }
                    .glassListCard()

                    Text("存储")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, Spacing.xs)
                        .padding(.top, Spacing.sm)
                    VStack(spacing: 0) {
                        SettingRow(icon: "tray.full.fill", iconColor: .teal,
                                   title: "会话存储位置", value: sessionLocShort, chevron: true)
                            .onTapGesture { showSessionLocSheet = true }
                        Divider().padding(.leading, Spacing.rowDividerInset)
                        // v2.0.85：文件上传位置（App 附件整份上传的落点，可自定义 NAS 目录）
                        SettingRow(icon: "arrow.up.doc.fill", iconColor: .indigo,
                                   title: "文件上传位置", value: uploadDirShort, chevron: true)
                            .onTapGesture { showUploadDirSheet = true }
                        Divider().padding(.leading, Spacing.rowDividerInset)
                        // v4.0.61：钉一钉存储（用户 2026-10-05：由主设置页搬到「存储」下面）
                        SettingRow(icon: "pin.fill", iconColor: .indigo,
                                   title: "钉一钉存储", value: pinPathDisplay, chevron: true)
                            .onTapGesture { showPinPath = true }
                    }
                    .glassListCard()
                    Text("会话记录保存在 NAS 指定目录，Web 与 App 共用同一份")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, Spacing.xs)
                }
                .padding(Spacing.xxl)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("连接设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showServerSheet) {
                ServerSheet()
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showSessionLocSheet) {
                SessionLocSheet(currentPath: sessionLoc)
                    .presentationDetents([.medium])
            }
            // v4.0.61：钉一钉存储路径（自带的统一底部 sheet，形态与原主设置页一致）
            .sheet(isPresented: $showPinPath) {
                PinPathSheet()
                    .presentationDetents([.medium, .large])
            }
            // v2.0.85：文件上传位置修改
            .sheet(isPresented: $showUploadDirSheet) {
                UploadDirSheet(current: uploadDir) { newDir in
                    showUploadDirSheet = false
                    uploadDir = newDir
                }
                .presentationDetents([.medium])
            }
            .onAppear {
                // v4.0.61：搜索「钉一钉存储」直达（只认呈现时那一次，关掉不复发）
                if initiallyShowPinPath && !didAutoOpenPinPath {
                    didAutoOpenPinPath = true
                    showPinPath = true
                }
            }
            .task {
                // 拉取服务器端会话存储位置 + 文件上传位置
                if let j = try? await auth.json("/api/sessions/location") {
                    sessionLoc = j["path"] as? String ?? ""
                }
                if let j = try? await auth.json("/api/files/config") {
                    uploadDir = j["upload_dir"] as? String ?? ""
                }
            }
        }
    }

    private func testConnection() {
        guard !testing else { return }
        testing = true
        Task {
            defer { testing = false }
            do {
                let j = try await auth.json("/api/auth/status")
                let ok = (j["ok"] as? Bool) ?? false
                testResult = ok ? "✅ 连接正常，服务器：\(shortServer)" : "⚠️ 服务器响应异常"
            } catch {
                testResult = "❌ 无法连接：\(shortServer)"
            }
        }
    }
}

// MARK: - v2.0.85 文件上传位置修改（自定义 NAS 目录）

private struct UploadDirSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var saving = false
    @State private var result: (ok: Bool, text: String)?
    let current: String
    var onSaved: (String) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("文件上传位置")
                .font(.system(size: Typography.title, weight: .bold))
                .padding(.top, 20)
            Text("App 发送的附件（PDF/文档等）将整份保存到该 NAS 目录")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            TextField("NAS 绝对路径", text: $path)
                .font(.system(size: Typography.body))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(Spacing.xl)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                .padding(.horizontal, Spacing.sheetInset)

            if let r = result {
                Text(r.text)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(r.ok ? Color.green : Color.red)
                    .padding(.horizontal, Spacing.sheetInset)
            }

            Button {
                save()
            } label: {
                Text(saving ? "保存中..." : "保存")
                    .font(.system(size: Typography.body, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .pill(.primary)
            }
            .buttonStyle(.plain)
            .disabled(saving || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, Spacing.sheetInset)

            Button("取消") { dismiss() }
                .font(.system(size: Typography.body))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .onAppear { path = current }
    }

    private func save() {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            if let j = try? await auth.json("/api/files/config", method: "POST", body: ["upload_dir": p]) {
                let ok = (j["ok"] as? Bool) ?? false
                result = (ok, j["message"] as? String ?? (ok ? "已保存" : "保存失败"))
                if ok {
                    onSaved(j["upload_dir"] as? String ?? p)
                    dismiss()
                }
            } else {
                result = (false, "请求失败，请检查连接")
            }
        }
    }
}

// MARK: ===== 以下原为 Features/Settings/SecretsView.swift =====

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

/// v3.9.41（SR22）：复制出去的凭据 60 秒后自动从系统剪贴板失效
/// （剪贴板会被其他 App 读到、iCloud 通用剪贴板还会上云，不能当保险箱）
enum SecretClipboard {
    static func copy(_ s: String) {
        // UIPasteboard 没有 expirationDate 属性（iOS 26 SDK 里它只是 OptionsKey 的一个键），
        // 过期只能走 setItems 的 options：系统级失效，App 被挂起后照样生效
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": s]],
            options: [.expirationDate: Date().addingTimeInterval(60)]
        )
    }
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
    // v3.9.41（SR22）：明文只在有限时间内停留——每条已显形的密码挂一个自动掩码任务，
    // 离开前台时也一并掩掉（此前 reveal 后直到重进页面都是明文，任务切换器快照也能拍到）
    @State private var maskTasks: [String: Task<Void, Never>] = [:]
    @Environment(\.scenePhase) private var scenePhase
    private static let revealSeconds: TimeInterval = 30

    var body: some View {
        VStack(spacing: 0) {
            if locked {
                // 生物识别锁屏：验证通过才显示内容
                VStack(spacing: 16) {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(Tint.subtle))
                            .frame(width: 76, height: 76)
                        Image(systemName: "faceid")
                            .font(.system(size: 34))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text("密码管理已锁定")
                        .font(.system(size: Typography.body, weight: .semibold))
                    Text("使用 Face ID / 面容验证解锁")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.secondary)
                    if authFailed {
                        Text("验证失败，请重试")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.red)
                    }
                    Button {
                        authenticate()
                    } label: {
                        Text("解锁")
                            .font(.system(size: Typography.body, weight: .semibold))
                            .frame(minWidth: 120)
                            .pill(.primary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                // v3.9.23 豁免：这不是弹窗根底，是生物解锁「验证失败」态那一行的行内底
                // （同行有 .pill(.primary) 主按钮作为视觉主体），去掉会失去分隔感。
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
                    // v3.9.42：首屏骨架（左右留白与下方真列表同为 Spacing.xxl）
                    LoadingStateView(shape: .rows(3))
                } else if entries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text("暂无凭据")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.tertiary)
                    Text("点击右上角 + 添加 NAS SSH / 路由器密码")
                        .font(.system(size: Typography.caption))
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
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.vertical, Spacing.lg)
                }
            }
        }
        // v3.9.23 决策：弹窗背景不覆盖，让系统默认玻璃生效（勿再挂实色底）。
        // 原来这里挂了一行 systemBackground 实色底 → 密钥页变实色页，与其它弹窗不统一。v4.0.x 移除。
        .task { await load() }
        // v3.9.41（SR22）：一离开前台就把已显形的密码全部掩回（任务切换器/切走再回来不再留明文）
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { maskAllPasswords() }
        }
        .sheet(isPresented: $showEdit) {
            SecretEditSheet(entry: editing, onSave: { newEntry in
                Task { await save(newEntry) }
            })
            .presentationDetents([.medium])
        }
        .overlay(alignment: .bottom) {
            if !toast.isEmpty {
                Text(toast)
                    .font(.system(size: Typography.subhead))
                    .padding(.horizontal, Spacing.section).padding(.vertical, Spacing.md)
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
                scheduleMask(e.id)
            } catch {
                toast = "获取失败"
            }
        }
    }

    /// v3.9.41（SR22）：显形倒计时（重复点击以最后一次为准）
    private func scheduleMask(_ id: String) {
        maskTasks[id]?.cancel()
        maskTasks[id] = Task {
            try? await Task.sleep(for: .seconds(SecretsView.revealSeconds))
            guard !Task.isCancelled else { return }
            maskTasks[id] = nil
            if let idx = entries.firstIndex(where: { $0.id == id }) {
                entries[idx].password = ""
            }
        }
    }

    /// 退后台/收起：全部掩掉，并撤掉未完成的倒计时
    private func maskAllPasswords() {
        for t in maskTasks.values { t.cancel() }
        maskTasks.removeAll()
        for idx in entries.indices where !entries[idx].password.isEmpty {
            entries[idx].password = ""
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
                Text(typeIcon).font(.system(size: Typography.title))
                Text(entry.name)
                    .font(.system(size: Typography.body, weight: .semibold))
                Text(typeName)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xxs)
                    .background(Color.secondary.opacity(Tint.subtle), in: Capsule())
                Spacer()
                // 复制完整连接串
                Button {
                    SecretClipboard.copy("\(entry.username)@\(entry.address)")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                Button { onEdit() } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                Button { onDelete() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                Text("地址：\(entry.address)")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                Text("用户：\(entry.username)")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            // 密码：默认掩码，点击眼睛显示明文
            HStack(spacing: 8) {
                Text(entry.password.isEmpty ? "密码：••••••••" : "密码：\(entry.password)")
                    .font(.system(size: Typography.caption, design: .monospaced))
                    .foregroundStyle(entry.password.isEmpty ? .secondary : .primary)
                if entry.password.isEmpty {
                    Button {
                        onReveal()
                    } label: {
                        Image(systemName: "eye")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        SecretClipboard.copy(entry.password)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
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
                    .font(.system(size: Typography.title, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.titleXL)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
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
                .font(.system(size: Typography.body, weight: .semibold))
                .frame(maxWidth: .infinity)
                .pill(.primary)
            }
            .buttonStyle(.plain)
            .disabled(name.isEmpty || address.isEmpty || username.isEmpty)
            Spacer()
        }
        .padding(Spacing.sheetInset)
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

// MARK: ===== 以下原为 Features/Settings/MCPSettingsSheet.swift =====

// MARK: - v3.5.0 MCP 工具服务管理
// App 配 key → 后端 /api/mcp/* → Hermes config.yaml → 本地模式聊天自动获得 MCP 工具
// 交互照 CustomProviderEditSheet（模板选择 + key 输入 + 列表管理）

struct MCPServerItem: Identifiable {
    let id: String          // name
    let url: String         // 已脱敏
    let hasKey: Bool
    let enabled: Bool
}

struct MCPTemplate: Identifiable {
    let id: String
    let name: String
    let desc: String
    let urlTemplate: String
    let keyHint: String
}

struct MCPSettingsSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var servers: [MCPServerItem] = []
    @State private var templates: [MCPTemplate] = []
    @State private var loading = false
    @State private var errMsg: String?

    // 新增表单
    @State private var showAdd = false
    @State private var customURL = ""
    @State private var key = ""
    @State private var saving = false
    // v3.9.41（SR25）：saveMsg 全仓无渲染点 → 保存成功/失败用户都看不到回执。
    // 改成列表顶部可见的 feedback 行（errMsg 会把整个列表换掉，不能拿来当回执）。
    @State private var feedback: String?
    // v3.5.0 review：删除走二次确认（服务删除会触发 hermes 重启，防误触）
    @State private var pendingDelete: MCPServerItem?

    var body: some View {
        NavigationStack {
            Form {
                // v3.9.41（SR25）：保存/删除回执（原来写进 saveMsg 却无人渲染）
                if let f = feedback {
                    Section {
                        Text(f).font(.system(size: Typography.subhead))
                            .foregroundStyle(f.hasPrefix("❌") ? Color.red : Color.green)
                    }
                }
                if loading {
                    // v3.9.42：首屏骨架；Form 已自带缩进，horizontalPadding 传 0 免得二次内缩
                    Section { LoadingStateView(shape: .rows(2), horizontalPadding: 0) }
                } else if let errMsg {
                    Section {
                        Text("⚠️ \(errMsg)").font(.system(size: Typography.subhead)).foregroundStyle(.orange)
                    }
                } else {
                    serverListSection
                    addSection
                    hintSection
                }
            }
            .navigationTitle("MCP 工具服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                // v3.9.41（SR25）：保存改成「等结果再关」——失败时表单留在屏上，输入不丢
                MCPAddSheet(templates: templates) { template, k, url in
                    await save(template: template, key: k, url: url)
                }
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
            }
            .confirmationDialog("删除 \(pendingDelete?.id ?? "")？将触发 Hermes 重启（约 30 秒）",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let s = pendingDelete { Task { await delete(s.id) } }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            }
            .task { await load() }
        }
    }

    // MARK: 已配置服务列表
    @ViewBuilder private var serverListSection: some View {
        Section("已启用（\(servers.count)）") {
            if servers.isEmpty {
                Text("暂无——点右上角 + 添加，如高德地图（天气/路线/导航）")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.tertiary)
            }
            ForEach(servers) { s in
                HStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.teal, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(s.id).font(.system(size: Typography.body, weight: .medium))
                        Text(s.enabled ? "已启用" : "已停用")
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(s.enabled ? Color.green : Color.secondary)
                    }
                    Spacer()
                    // 删除（二次确认走 confirmationDialog）
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = s
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
    }

    @ViewBuilder private var addSection: some View {
        Section("添加") {
            Button {
                showAdd = true
            } label: {
                Label("从模板添加（推荐）", systemImage: "plus.circle.fill")
            }
        }
    }

    @ViewBuilder private var hintSection: some View {
        Section {
            Text("保存后 Hermes 自动重启（约 30 秒），之后在「聊天」里直接说\"帮我查明天天气\"即可触发工具。删除同理。")
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
            let d = try await auth.json("/api/mcp/servers")
            guard let ok = d["ok"] as? Bool, ok else {
                errMsg = "加载失败"
                return
            }
            var arr: [MCPServerItem] = []
            if let sv = d["servers"] as? [String: Any] {
                for (name, e) in sv {
                    let url = e as? [String: Any] ?? [:]
                    arr.append(MCPServerItem(
                        id: name,
                        url: url["url"] as? String ?? "",
                        hasKey: url["has_key"] as? Bool ?? false,
                        enabled: url["enabled"] as? Bool ?? true))
                }
            }
            servers = arr.sorted { $0.id < $1.id }
            var tps: [MCPTemplate] = []
            if let ts = d["templates"] as? [[String: Any]] {
                for t in ts {
                    tps.append(MCPTemplate(
                        id: t["id"] as? String ?? "",
                        name: t["name"] as? String ?? "",
                        desc: t["desc"] as? String ?? "",
                        urlTemplate: t["url_template"] as? String ?? "",
                        keyHint: t["key_hint"] as? String ?? ""))
                }
            }
            templates = tps
        } catch {
            errMsg = "加载失败：\(error.localizedDescription)"
        }
    }

    /// v3.9.41（SR25）：返回是否保存成功，供添加表单决定「关窗」还是「留在屏上重试」
    private func save(template: MCPTemplate?, key k: String, url: String) async -> Bool {
        saving = true
        defer { saving = false }
        do {
            var body: [String: Any] = ["name": template?.id ?? "custom"]
            if let template {
                body["template"] = template.id
                body["key"] = k
            } else {
                body["url"] = url
            }
            let d = try await auth.json("/api/mcp/save", method: "POST", body: body)
            guard (d["ok"] as? Bool) ?? false else {
                feedback = "❌ \(d["error"] as? String ?? "保存失败")"
                return false
            }
            feedback = "✅ 已保存，约 30 秒后生效"
            await load()
            return true
        } catch {
            feedback = "❌ \(error.localizedDescription)"
            return false
        }
    }

    // v3.9.41（SR24）：删除成功只刷新、不校验 ok:false（400/404 走 catch，但 200+ok:false 被当成功）
    private func delete(_ name: String) async {
        do {
            let d = try await auth.json("/api/mcp/delete", method: "POST", body: ["name": name])
            guard (d["ok"] as? Bool) ?? false else {
                feedback = "❌ 删除失败：\(d["error"] as? String ?? "服务器拒绝")"
                return
            }
            feedback = "✅ 已删除 \(name)，约 30 秒后生效"
            await load()
        } catch {
            feedback = "❌ 删除失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 新增 sheet（模板选择 + key）
struct MCPAddSheet: View {
    let templates: [MCPTemplate]
    /// v3.9.41（SR25）：改为 async 并回传是否成功——失败时表单不关，Key/URL 不丢
    let onSaved: (MCPTemplate?, String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss

    @State private var picked: MCPTemplate?
    @State private var customURL = ""
    @State private var key = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("选择服务") {
                    ForEach(templates) { t in
                        Button {
                            picked = t
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name).font(.system(size: Typography.body, weight: .medium)).foregroundColor(.primary)
                                    Text(t.desc).font(.system(size: Typography.caption)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if picked?.id == t.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    // 高级：自定义 URL
                    Button {
                        picked = nil
                    } label: {
                        HStack {
                            Text("自定义 URL（高级）").font(.system(size: Typography.body)).foregroundColor(.primary)
                            Spacer()
                            if picked == nil && !customURL.isEmpty {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                    if picked == nil {
                        TextField("https://... (MCP HTTP 端点)", text: $customURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: Typography.subhead))
                    }
                }
                if let t = picked {
                    Section("Key") {
                        SecureField(t.keyHint, text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle("添加 MCP 服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        guard !saving else { return }
                        Task {
                            saving = true
                            let ok = await onSaved(picked, key, customURL)
                            saving = false
                            if ok { dismiss() }   // v3.9.41（SR25）：失败不关窗，父层列表已给回执
                        }
                    }
                    .disabled(!canSave || saving)
                }
            }
        }
    }

    private var canSave: Bool {
        if let t = picked { return !key.isEmpty }
        return customURL.hasPrefix("https://") || customURL.hasPrefix("http://")
    }
}

// MARK: ===== 以下原为 Features/Settings/HASettingsSheet.swift =====

// MARK: - HA 设置（Home Assistant 地址 + Token，联动看板智能家居卡片）

struct HASettingsSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var token = ""
    @State private var hasToken = false
    @State private var saving = false
    @State private var toast = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Home Assistant 连接配置，保存后看板「智能家居」卡片自动使用新配置")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("HA 地址")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                TextField("如 http://ha.example.com:8123", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("长期访问 Token")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                SecureField(hasToken ? "已配置（输入新值可替换）" : "粘贴 HA 长期访问令牌", text: $token)
                    .textFieldStyle(.roundedBorder)
                if hasToken && token.isEmpty {
                    Text("当前已有 Token，留空保持不变")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                save()
            } label: {
                HStack {
                    Spacer()
                    if saving { ProgressView() }
                    else { Text("保存") }
                    Spacer()
                }
                .font(.system(size: Typography.body, weight: .semibold))
                .frame(maxWidth: .infinity)
                .pill(.primary)
            }
            .buttonStyle(.plain)
            .disabled(saving || address.isEmpty)

            if !toast.isEmpty {
                Text(toast)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(toast.hasPrefix("✅") ? .green : .red)
            }

            Spacer()
        }
        .padding(Spacing.sheetInset)
        .navigationTitle("HA 设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        .task {
            if let j = try? await auth.json("/api/ha/config") {
                address = j["address"] as? String ?? ""
                hasToken = (j["has_token"] as? Bool) ?? false
            }
        }
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            var body: [String: Any] = ["address": address]
            if !token.isEmpty { body["token"] = token }
            do {
                let j = try await auth.json("/api/ha/config", method: "POST", body: body)
                if (j["ok"] as? Bool) == true {
                    toast = "✅ 已保存，看板智能家居卡片已联动"
                    if !token.isEmpty { token = ""; hasToken = true }
                } else {
                    toast = "保存失败：\((j["error"] as? String) ?? "未知错误")"
                }
            } catch {
                toast = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: ===== 以下原为 Features/Settings/KBView.swift =====

// MARK: - v2.0.81 知识库管理（文档上传/列表/删除；聊天输入 @知识库 自动检索注入）

struct KBView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var docs: [KBDoc] = []
    @State private var showImporter = false
    @State private var showPasteSheet = false   // v2.0.83 粘贴文本上传
    @State private var message: (ok: Bool, text: String)?
    @State private var busy = false
    @State private var confirmDelete: String?   // v2.0.102：删除确认（文档不可恢复）

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.accentColor)
                            Text("上传文档（txt / md / PDF）")
                                .foregroundStyle(.primary)
                        }
                    }
                    // v2.0.83：粘贴文本上传（LiveContainer 环境文件选择器可能无反应）
                    Button {
                        showPasteSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "doc.plaintext")
                                .foregroundStyle(Color.teal)
                            Text("粘贴文本上传")
                                .foregroundStyle(.primary)
                        }
                    }
                    Text("聊天时输入「@知识库 你的问题」，AI 会自动检索这些文档回答")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                }

                Section("文档（\(docs.count) 个）") {
                    if docs.isEmpty {
                        Text("暂无文档")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(docs) { doc in
                        KBRow(name: doc.name,
                              chunks: doc.chunks,
                              size: doc.size,
                              onDelete: { name in confirmDelete = name })   // v2.0.102：先确认再删
                    }
                }

                if let m = message {
                    Section {
                        Text(m.text)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(m.ok ? .green : .red)
                    }
                }
            }
            .navigationTitle("知识库")
            .navigationBarTitleDisplayMode(.inline)
            // v2.0.102：删除确认（文档不可恢复）
            .confirmationDialog("删除文档？", isPresented: Binding(get: { confirmDelete != nil },
                                                                   set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let name = confirmDelete {
                        Task { await deleteDoc(name) }
                    }
                    confirmDelete = nil
                }
                Button("取消", role: .cancel) { confirmDelete = nil }
            } message: {
                Text("将删除「\(confirmDelete ?? "")」，此操作不可恢复")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
            // v2.0.83：粘贴文本上传 sheet
            .sheet(isPresented: $showPasteSheet) {
                PasteKBSheet { name, content in
                    showPasteSheet = false
                    Task { await uploadContent(name, content) }
                }
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.plainText, .pdf,
                                                UTType(filenameExtension: "md") ?? .data,
                                                UTType(filenameExtension: "txt") ?? .data],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    Task { await uploadFiles(urls) }
                case .failure:
                    break
                }
            }
        }
    }

    private func load() async {
        if let j = try? await auth.json("/api/kb/list") {
            let arr = j["docs"] as? [[String: Any]] ?? []
            // v2.0.82：解析为具体类型 KBDoc（字典索引在 ViewBuilder 里类型检查爆炸）
            docs = arr.compactMap { d in
                guard let n = d["name"] as? String else { return nil }
                return KBDoc(name: n,
                             chunks: (d["chunks"] as? Int) ?? 0,
                             size: (d["size"] as? Int) ?? 0)
            }
        }
    }

    /// v3.9.41（SR23）：单文件字节闸门——原先选到什么传什么，整篇内容一次进 JSON body
    private static let maxUploadBytes = 8 * 1024 * 1024

    private func uploadFiles(_ urls: [URL]) async {
        busy = true
        defer { busy = false }
        // v3.9.41（SR23）：逐文件刷 message 时只有最后一个文件看得见结果，多文件选完等于没反馈
        var uploaded = 0
        var failures: [String] = []
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.lowercased()
            var content = ""
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size: Int = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            guard size <= Self.maxUploadBytes else {
                failures.append("\(name)：\(size / 1024 / 1024)MB 超过 8MB 上限")
                continue
            }
            if ext == "pdf" {
                // PDF 用 PDFKit 提取文本（与发送 PDF 同款）
                content = extractPDFText(from: url) ?? ""
            } else {
                content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
            guard !content.isEmpty else {
                failures.append("\(name)：无法读取内容（扫描件 PDF 无文字层）")
                continue
            }
            if let j = try? await auth.json("/api/kb/upload", method: "POST",
                                            body: ["name": name, "content": content]) {
                let ok = (j["ok"] as? Bool) ?? false
                if ok {
                    uploaded += 1
                } else {
                    failures.append("\(name)：\((j["message"] as? String) ?? "上传失败")")
                }
            } else {
                failures.append("\(name)：请求失败")
            }
        }
        let done = "已上传 \(uploaded) 个文档"
        if failures.isEmpty {
            message = (true, done)
        } else {
            let f = failures.joined(separator: "；")
            message = (uploaded == 0, uploaded == 0 ? f : "\(done)；失败：\(f)")
        }
        await load()
    }

    private func deleteDoc(_ name: String) async {
        // v3.9.41（SR24）：请求失败原先连 message 都不设，条目「看着删了」重开原样回来
        guard let j = try? await auth.json("/api/kb/delete", method: "POST", body: ["name": name]) else {
            message = (false, "\(name)：删除失败（请求未送达）")
            return
        }
        let ok = (j["ok"] as? Bool) ?? false
        message = (ok, j["message"] as? String ?? (ok ? "已删除" : "\(name)：删除失败"))
        await load()
    }

    /// v2.0.83：直接上传文本内容（粘贴上传用）
    private func uploadContent(_ name: String, _ content: String) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !trimmed.isEmpty else {
            message = (false, "名称和内容不能为空")
            return
        }
        if let j = try? await auth.json("/api/kb/upload", method: "POST",
                                        body: ["name": name, "content": trimmed]) {
            let ok = (j["ok"] as? Bool) ?? false
            message = (ok, j["message"] as? String ?? (ok ? "已保存" : "上传失败"))
        } else {
            message = (false, "请求失败")
        }
        await load()
    }

    /// PDFKit 提取文本（文本型 PDF 才有内容）
    private func extractPDFText(from url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var out = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let s = page.string {
                out += s + "\n"
            }
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - v2.0.81b 文档行（拆独立子视图，规避 Swift 6 类型检查超时）

private struct KBRow: View {
    let name: String
    let chunks: Int
    let size: Int
    var onDelete: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: Typography.headline))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: Typography.body, weight: .medium))
                Text("\(chunks) 个片段 · \(size) 字节")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onDelete(name)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - v2.0.82 知识库文档（具体类型，规避字典索引类型检查爆炸）

struct KBDoc: Identifiable {
    let name: String
    let chunks: Int
    let size: Int
    var id: String { name }
}

// MARK: - v2.0.83 粘贴文本上传（LiveContainer 文件选择器无反应的备用通道）

private struct PasteKBSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var content = ""
    var onSave: (String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("文档名称") {
                    TextField("如：TPS6594 手册笔记", text: $name)
                }
                Section("内容（粘贴文本）") {
                    TextEditor(text: $content)
                        .frame(minHeight: 180)
                        .font(.system(size: Typography.subhead))
                }
            }
            .navigationTitle("粘贴文本上传")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines),
                               content)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
