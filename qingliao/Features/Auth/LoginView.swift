import SwiftUI
import LocalAuthentication

// MARK: - 登录页（服务器地址 + 账号密码 + 记住登录 + Face ID 快捷登录）

struct LoginView: View {
    @Environment(AuthStore.self) private var auth
    @State private var username = "qingliao"
    @State private var password = ""   // 不预填默认密码（防泄漏默认值）
    // v2.0.55：预填已保存的服务器地址（之前每次登录都要重输）
    @State private var server = UserDefaults.standard.string(forKey: "qingliao_server") ?? ""
    // v2.0.72：历史地址抽屉展开
    @State private var showHistory = false
    @State private var remember = true
    @State private var testing = false
    @State private var testResult: String?
    // v2.0.88：Face ID 快捷登录（开关开启即显示按钮；无凭据时点击提示先手动登录）
    @State private var faceIDReady = false
    @State private var showFaceIDHint = false
    @State private var showServerMismatch = false   // v2.0.102：Face ID 凭据服务器与输入不一致提示

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                loginLogoBlock

                loginFormCard

                loginRememberToggle

                loginErrorText

                loginSubmitButton

                loginFaceIDButton

                loginTestButton

                loginTestResultText

                Spacer()
                Spacer()
            }
        }
        .onAppear {
            if server.isEmpty {
                server = auth.serverURL
            }
            refreshFaceID()
        }
        .onChange(of: server) { _, _ in
            refreshFaceID()
        }
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            if !loggedIn {
                refreshFaceID()   // 登出回到登录页时刷新（可能凭据已更新）
            }
        }
    }

    // MARK: - 巨型 body 拆分（纯搬运）
    //
    // 由头：此 body 单块 233 行，是本仓已踩过两次的「Unable to type-check this
    // expression in reasonable time」高危形态（一次漏检 = 20 分钟 CI 循环）。
    // 这里按原注释分段把视图块原样搬成独立 @ViewBuilder 属性 —— **纯搬运**：视图顺序、
    // 层级、条件分支、闭包、修饰符逐字未变，渲染结果与拆分前一致，只为把类型检查表达式打小。

    /// Logo + 应用名 + 副标题
    @ViewBuilder
    private var loginLogoBlock: some View {
        // Logo
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 52))
                .foregroundStyle(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("轻聊")
                .font(.system(size: Typography.display, weight: .bold))
            Text("家庭 NAS 上的 AI 助手")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
        }
    }

    /// 服务器 / 用户名 / 密码表单（含 .padding 链）
    @ViewBuilder
    private var loginFormCard: some View {
        // 表单
        VStack(spacing: 12) {
            loginServerField
            if showHistory {
                loginServerHistoryDropdown
            }
            GlassField(icon: "person", placeholder: "用户名", text: $username)
            GlassField(icon: "lock", placeholder: "密码", text: $password, isSecure: true)
        }
        .padding(.horizontal, 28)
    }

    /// 服务器地址输入框 + 历史下拉按钮
    @ViewBuilder
    private var loginServerField: some View {
        // v2.0.72：服务器地址输入框 + 抽屉式历史记录（点击展开）
        GlassField(icon: "globe", placeholder: "服务器地址", text: $server)
            .overlay(alignment: .trailing) {
                if !auth.serverHistory.isEmpty {
                    Button {
                        withAnimation(Motion.settle) {
                            showHistory.toggle()
                        }
                    } label: {
                        Image(systemName: showHistory ? "chevron.up" : "chevron.down")
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                            .padding(.trailing, Spacing.xxl)
                    }
                    .buttonStyle(.plain)
                }
            }
    }

    /// 服务器历史记录下拉
    @ViewBuilder
    private var loginServerHistoryDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(auth.serverHistory, id: \.self) { addr in
                HStack {
                    Button {
                        server = addr
                        withAnimation(Motion.settle) { showHistory = false }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: Typography.caption))
                                .foregroundStyle(.tertiary)
                            Text(addr)
                                .font(.system(size: Typography.subhead))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    Button {
                        auth.removeServer(addr)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityLabel("删除该服务器")
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.vertical, Spacing.md)
                Divider().padding(.leading, Spacing.xxl)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// 记住登录开关
    @ViewBuilder
    private var loginRememberToggle: some View {
        // 记住登录
        Toggle(isOn: $remember) {
            Text("记住登录（7 天免登录）")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
        }
        .tint(.blue)
        .padding(.horizontal, 28)
    }

    /// 登录错误提示
    @ViewBuilder
    private var loginErrorText: some View {
        if let err = auth.errorMessage {
            Text(err)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    /// 登录按钮
    @ViewBuilder
    private var loginSubmitButton: some View {
        // 登录按钮
        Button {
            // 先提交服务器地址（登录页可修改），再登录
            // v2.0.55：必须持久化到 UserDefaults——只改内存的话 App 重启/ASWAS
            // 流程读默认值 example.com 导致登录弹窗异常（用户实测）
            let s = server.trimmingCharacters(in: .whitespacesAndNewlines)
            auth.saveServer(s)
            Task {
                await auth.login(username: username, password: password, remember: remember)
            }
        } label: {
            Text(auth.isLoading ? "登录中..." : "登 录")
                .font(.system(size: Typography.title, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xl)
                .background(
                    LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28)
        .disabled(auth.isLoading)
    }

    /// Face ID 快捷登录（含两个提示弹窗）
    @ViewBuilder
    private var loginFaceIDButton: some View {
        // v2.0.88：Face ID 快捷登录（开关开启即显示；v2.0.88f 放宽——无凭据时提示先登录）
        if faceIDReady {
            Button {
                guard let cred = FaceIDStore.load() else {
                    // 还没有保存的凭据（首次使用/开关刚打开）：引导先手动登录一次
                    showFaceIDHint = true
                    return
                }
                let context = LAContext()
                context.localizedReason = "验证后自动登录轻聊"
                context.evaluatePolicy(.deviceOwnerAuthentication,
                                       localizedReason: "验证后自动登录轻聊") { success, _ in
                    DispatchQueue.main.async {
                        guard success, let cred = FaceIDStore.load() else { return }
                        // v2.0.102：Face ID 凭据服务器与当前输入不一致时提示（防静默登录到旧服务器）
                        // v-review fix：归一化（补默认 scheme / 小写 / 去尾斜杠）后再比对，
                        // 避免格式略异（大小写、http 前缀、尾斜杠）误报「不一致」阻断一键登录
                        let input = server.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !input.isEmpty && normalizeServerAddress(input) != normalizeServerAddress(cred.server) {
                            showServerMismatch = true
                            return
                        }
                        // 用保存的服务器/账号/密码自动登录（失败会显示错误，可重试/手动登录）
                        auth.saveServer(cred.server)
                        Task { await auth.login(username: cred.username, password: cred.password, remember: true) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "faceid")
                        .font(.system(size: Typography.body))
                    Text(auth.isLoading ? "登录中..." : "Face ID 登录")
                        .font(.system(size: Typography.body, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.lg)
                .background(Color.accentColor.opacity(Tint.subtle), in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)
            .padding(.top, Spacing.lg)
            .disabled(auth.isLoading)
            .alert("尚未保存登录凭据", isPresented: $showFaceIDHint) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("请先手动登录一次，登录后会自动保存凭据，下次即可使用 Face ID 一键登录。")
            }
            .alert("服务器地址不一致", isPresented: $showServerMismatch) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("Face ID 保存的服务器与当前输入不一致，已取消自动登录。请确认地址后手动登录。")
            }
        }
    }

    /// 测试连接按钮
    @ViewBuilder
    private var loginTestButton: some View {
        // 测试连接按钮
        Button {
            testing = true
            testResult = nil
            Task {
                let r = await auth.testConnection(server: server)
                testResult = r
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
            .padding(.vertical, Spacing.lg)
            .background(Color.accentColor.opacity(Tint.subtle), in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28)
        .padding(.top, Spacing.lg)
        .disabled(testing || auth.isLoading)
    }

    /// 测试连接结果
    @ViewBuilder
    private var loginTestResultText: some View {
        if let tr = testResult {
            Text(tr)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(tr.hasPrefix("✅") ? Color.green : (tr.hasPrefix("⚠️") ? Color.orange : Color.red))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, Spacing.sm)
        }
    }

    /// v2.0.88：Face ID 按钮显示条件 = 开关开启（v2.0.88f：不再要求已有凭据/服务器匹配，
    /// 无凭据时点击会提示先手动登录一次）
    private func refreshFaceID() {
        let on = UserDefaults.standard.object(forKey: "qingliao_faceid_login") as? Bool ?? true
        faceIDReady = on
    }

    /// v-review fix：服务器地址归一化——补默认 scheme、转小写（host/port 不区分大小写）、去尾斜杠；
    /// 供 Face ID 凭据与当前输入比对使用（两端同规则）
    private func normalizeServerAddress(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
            s = "http://" + s
        }
        s = s.lowercased()
        while s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }
}

struct GlassField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: Typography.body))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .font(.system(size: Typography.body))
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.xl)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(Tint.subtle), lineWidth: 0.8)
        )
    }
}
