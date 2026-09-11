import SwiftUI
import LocalAuthentication

// MARK: - v3.0 云端模式登录页：厂商选择 + API Key 配置 + 测试连接 + Face ID 一键登录
// 数据全部存 App 本地（配置 UserDefaults + key Keychain），不依赖任何服务器

struct CloudLoginView: View {
    @Environment(AuthStore.self) private var auth
    @State private var config = CloudConfig.shared
    @State private var testing = false
    @State private var testResult: String?
    @State private var showAddSheet = false
    @State private var selectedID = CloudConfig.shared.activeProviderID
    // v3.0.2：Face ID 一键登录
    @State private var faceIDEnabled = UserDefaults.standard.object(forKey: "qingliao_faceid_login") as? Bool ?? true

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 20) {
                // v3.0：模式切换器（本地 AI / 云端 AI）
                ModeSwitchBar()
                Spacer()

                // Logo
                VStack(spacing: 10) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("轻聊 · 云端")
                        .font(.system(size: Typography.display, weight: .bold))
                    Text("直连大模型 API，无需本地服务器")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.secondary)
                }

                // 已配置厂商列表
                VStack(spacing: 10) {
                    ForEach(config.providers) { p in
                        Button {
                            config.activeProviderID = p.providerID
                            selectedID = p.providerID
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "cube.fill")
                                    .font(.system(size: Typography.body))
                                    .foregroundStyle(config.activeProviderID == p.providerID ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name)
                                        .font(.system(size: Typography.body, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Text("\(p.model) · \(displayURL(p.baseURL))")
                                        .font(.system(size: Typography.caption))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if config.activeProviderID == p.providerID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: Typography.body))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                config.activeProviderID == p.providerID
                                    ? Color.accentColor.opacity(0.10)
                                    : Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(config.activeProviderID == p.providerID ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)

                // 添加厂商
                Button {
                    showAddSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: Typography.body))
                        Text("添加模型厂商")
                            .font(.system(size: Typography.body, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
                .padding(.top, 4)

                // 测试连接
                Button {
                    guard let c = config.activeConfig else { return }
                    testing = true
                    testResult = nil
                    Task {
                        let (ok, msg) = await CloudBackend.shared.testConnection(config: c)
                        testResult = msg
                        testing = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: testing ? "arrow.trianglehead.2.clockwise.rotate.90" : "network")
                            .font(.system(size: Typography.subhead))
                        Text(testing ? "测试中..." : "测试连接")
                            .font(.system(size: Typography.body, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
                .padding(.top, 6)
                .disabled(testing || config.activeConfig == nil)

                if let tr = testResult {
                    Text(tr)
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(tr.hasPrefix("✅") ? Color.green : (tr.hasPrefix("⚠️") ? Color.orange : Color.red))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 4)
                }

                // 进入
                Button {
                    if config.isConfigured {
                        auth.isLoggedIn = true
                        UserDefaults.standard.set(true, forKey: "qingliao_logged_in")
                    }
                } label: {
                    Text(config.isConfigured ? "开始使用" : "请先配置 API Key")
                        .font(.system(size: Typography.title, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            LinearGradient(colors: config.isConfigured ? [.blue, .indigo] : [.gray, .gray],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .disabled(!config.isConfigured)

                // v3.0.2：Face ID 一键登录（配置已在手机本地 → 验证通过直接进入）
                if faceIDEnabled && config.isConfigured {
                    Button {
                        authenticateWithFaceID()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "faceid")
                                .font(.system(size: Typography.body))
                            Text("Face ID 登录")
                                .font(.system(size: Typography.body, weight: .medium))
                        }
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
                }

                Spacer()
                Spacer()
            }
        }
        .sheet(isPresented: $showAddSheet) {
            CloudProviderSheet { newConfig in
                config.saveProvider(newConfig)
                config.activeProviderID = newConfig.providerID
                selectedID = newConfig.providerID
            }
        }
        .onAppear {
            selectedID = config.activeProviderID
        }
    }

    private func displayURL(_ s: String) -> String {
        s.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "/v1", with: "")
    }

    /// v3.0.2：Face ID 验证 → 通过直接进入（云端配置已在手机本地 Keychain，无需重输）
    private func authenticateWithFaceID() {
        let context = LAContext()
        context.localizedReason = "验证身份以登录轻聊云端"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // 无 Face ID/Touch ID → 提示走手动
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "验证身份以登录轻聊云端") { success, _ in
            DispatchQueue.main.async {
                if success {
                    auth.isLoggedIn = true
                    UserDefaults.standard.set(true, forKey: "qingliao_logged_in")
                }
            }
        }
    }
}

// MARK: - 添加厂商表单

struct CloudProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (CloudProviderConfig) -> Void

    @State private var presetID = "deepseek"
    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var custom = false

    var body: some View {
        NavigationStack {
            Form {
                Section("选择厂商") {
                    Picker("厂商", selection: $presetID) {
                        ForEach(CloudProviderPreset.presets) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: presetID) { _, newID in
                        guard let p = CloudProviderPreset.presets.first(where: { $0.id == newID }) else { return }
                        name = p.name
                        baseURL = p.baseURL
                        model = p.defaultModel
                        custom = (newID == "custom")
                    }
                }

                Section("连接信息") {
                    TextField("名称", text: $name)
                    TextField("Base URL", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("模型名", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Button("保存") {
                        let id = custom ? "custom-\(UUID().uuidString.prefix(6))" : presetID
                        // v3.0.4：从预设继承视觉支持（OpenAI 默认模型支持视觉，其余 false）
                        let presetVision = CloudProviderPreset.presets.first(where: { $0.id == presetID })?.supportsVision ?? false
                        onSave(CloudProviderConfig(providerID: id, name: name.isEmpty ? "自定义" : name,
                                                   baseURL: baseURL, apiKey: apiKey, model: model,
                                                   supportsVision: presetVision))
                        dismiss()
                    }
                    .disabled(name.isEmpty || baseURL.isEmpty || model.isEmpty || apiKey.isEmpty)
                }
            }
            .navigationTitle("添加模型厂商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                let p = CloudProviderPreset.presets[0]
                name = p.name
                baseURL = p.baseURL
                model = p.defaultModel
            }
        }
        .presentationDetents([.medium, .large])
    }
}
