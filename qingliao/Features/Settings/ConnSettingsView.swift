import SwiftUI

// MARK: - v2.0.83c 连接设置二级页（服务器地址 / 测试连接 / 会话存储位置——从主设置页收进二级）
// v2.0.83f：List 白底改毛玻璃卡片风格（与主设置页 glassListCard 一致）

struct ConnSettingsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

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
                        .padding(.leading, 4)
                    VStack(spacing: 0) {
                        SettingRow(icon: "globe.asia.australia.fill", iconColor: .green,
                                   title: "服务器地址", value: shortServer, chevron: true)
                            .onTapGesture { showServerSheet = true }
                        Divider().padding(.leading, 52)
                        SettingRow(icon: "network", iconColor: .blue,
                                   title: "测试连接", value: testing ? "检测中..." : nil,
                                   chevron: !testing)
                            .onTapGesture { testConnection() }
                        if let r = testResult {
                            Text(r)
                                .font(.system(size: Typography.caption))
                                .foregroundStyle(r.hasPrefix("✅") ? Color.green : Color.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 8)
                                .padding(.top, 2)
                        }
                    }
                    .glassListCard()

                    Text("存储")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                        .padding(.top, 6)
                    VStack(spacing: 0) {
                        SettingRow(icon: "tray.full.fill", iconColor: .teal,
                                   title: "会话存储位置", value: sessionLocShort, chevron: true)
                            .onTapGesture { showSessionLocSheet = true }
                        Divider().padding(.leading, 52)
                        // v2.0.85：文件上传位置（App 附件整份上传的落点，可自定义 NAS 目录）
                        SettingRow(icon: "arrow.up.doc.fill", iconColor: .indigo,
                                   title: "文件上传位置", value: uploadDirShort, chevron: true)
                            .onTapGesture { showUploadDirSheet = true }
                    }
                    .glassListCard()
                    Text("会话记录保存在 NAS 指定目录，Web 与 App 共用同一份")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                }
                .padding(14)
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
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
            // v2.0.85：文件上传位置修改
            .sheet(isPresented: $showUploadDirSheet) {
                UploadDirSheet(current: uploadDir) { newDir in
                    showUploadDirSheet = false
                    uploadDir = newDir
                }
                .presentationDetents([.medium])
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
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 20)

            if let r = result {
                Text(r.text)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(r.ok ? Color.green : Color.red)
                    .padding(.horizontal, 20)
            }

            Button {
                save()
            } label: {
                Text(saving ? "保存中..." : "保存")
                    .font(.system(size: Typography.body, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(saving || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 20)

            Button("取消") { dismiss() }
                .font(.system(size: Typography.body))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .background(Color(uiColor: .systemBackground))
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
