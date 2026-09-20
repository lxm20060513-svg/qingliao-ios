import SwiftUI
import LocalAuthentication

// MARK: - 登录页（服务器地址 + 账号密码 + 记住登录 + Face ID 快捷登录）

struct LoginView: View {
    @Environment(AuthStore.self) private var auth
    // v3.9.45：进场递延由 Splash 淡出驱动（`revealed`）——本页在 SplashView 底下挂载，
    // 若从 onAppear 起算，整段递延会被 0.6s 的 Splash 盖掉，用户一个字都没看见。
    var revealed: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    // v3.9.45：焦点态（三个输入框共用一个单选 FocusState，GlassField 靠它画高亮）
    @FocusState private var focusField: LoginField?
    // v3.9.45：登录失败抖动的触发计数（keyframeAnimator 的 trigger）
    @State private var shakeTrigger = 0

    /// 登录成功后整页上浮淡出的「交接演出」——RootView 让本页在顶层多留一会儿（见 loginHandoff）
    private var handingOff: Bool { auth.isLoggedIn }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                loginLogoBlock
                    .stagedIn(0, shown: revealed, frozen: reduceMotion)

                loginFormCard
                    .stagedIn(1, shown: revealed, frozen: reduceMotion)

                loginRememberToggle
                    .stagedIn(2, shown: revealed, frozen: reduceMotion)

                loginErrorText
                    .stagedIn(3, shown: revealed, frozen: reduceMotion)

                loginSubmitButton
                    .stagedIn(4, shown: revealed, frozen: reduceMotion)

                loginFaceIDButton
                    .stagedIn(5, shown: revealed, frozen: reduceMotion)

                loginTestButton
                    .stagedIn(6, shown: revealed, frozen: reduceMotion)

                loginTestResultText
                    .stagedIn(7, shown: revealed, frozen: reduceMotion)

                Spacer()
                Spacer()
            }
            // v3.9.45：失败抖动一次（整列一起晃，背景色不动 = 不会有边缘漏白）
            .shakeOnce(reduceMotion ? 0 : shakeTrigger)
        }
        // v3.9.45：交接演出——绿勾先亮 0.2s，随后整页上浮淡出（0.45s）；
        // 减弱动态效果时不演，由 RootView 立刻摘掉本页（见 RootView.loginHandoff）
        .scaleEffect(handingOff ? 1.08 : 1)
        .offset(y: handingOff ? -52 : 0)
        .opacity(handingOff ? 0 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.2), value: handingOff)
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
            } else {
                Haptics.success()
            }
        }
        // v3.9.45：登录失败——震一下 + 触觉反馈（原来只有一行红字，静默到容易被忽略）
        .onChange(of: auth.errorMessage) { _, err in
            guard let err, !err.isEmpty else { return }
            Haptics.error()
            if !reduceMotion { shakeTrigger += 1 }
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
            GlassField(icon: "person", placeholder: "用户名", text: $username,
                       field: .user, focus: $focusField)
            GlassField(icon: "lock", placeholder: "密码", text: $password, isSecure: true,
                       field: .pass, focus: $focusField)
        }
        .padding(.horizontal, 28)
    }

    /// 服务器地址输入框 + 历史下拉按钮
    @ViewBuilder
    private var loginServerField: some View {
        // v2.0.72：服务器地址输入框 + 抽屉式历史记录（点击展开）
        GlassField(icon: "globe", placeholder: "服务器地址", text: $server,
                   field: .server, focus: $focusField)
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

    /// 登录按钮（v3.9.45：三态直出——空闲文案 / 登录中环形进度 / 成功绿勾，原来只有「登录中...」换字）
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
            ZStack {
                if auth.isLoggedIn {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: Typography.title, weight: .semibold))
                        .transition(.scale(scale: 0.55).combined(with: .opacity))
                } else if auth.isLoading {
                    ProgressView()
                        .tint(.white)
                        .transition(.opacity)
                } else {
                    Text("登 录")
                        .transition(.opacity)
                }
            }
            .font(.system(size: Typography.title, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 26)                 // 三态等高：换态时按钮不跳动
            .padding(.vertical, Spacing.xl)
            .background(
                LinearGradient(colors: auth.isLoggedIn ? [.green, .teal] : [.blue, .indigo],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
            )
            // 绿勾那一下轻微顶起来（和 Haptics.success 同一拍）
            .scaleEffect(auth.isLoggedIn ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28)
        .disabled(auth.isLoading)
        .animation(reduceMotion ? nil : Motion.snap, value: auth.isLoading)
        .animation(reduceMotion ? nil : Motion.emerge, value: auth.isLoggedIn)
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
        // SR9：scheme 补全改用 AuthStore 的统一口径（原来这里补 http://、保存链路补 https://，
        // 同一裸地址在两端算出不同串 → Face ID「服务器不一致」误报）。此处只多做一步转小写。
        AuthStore.normalizedServerURL(raw).lowercased()
    }
}

/// v3.9.45：登录页三个字段的焦点标识（GlassField 与 LoginView 共用）
enum LoginField: Hashable {
    case server, user, pass
}

struct GlassField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    // v3.9.45：焦点形变——聚焦时描边走主色、图标点亮、底色加一层极淡主色（原来四个框长一个样，
    // 眼睛跟不上光标在哪）
    let field: LoginField
    var focus: FocusState<LoginField?>.Binding

    private var focused: Bool { focus.wrappedValue == field }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: Typography.body))
                .foregroundStyle(focused ? Color.accentColor : Color.secondary)
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
            .focused(focus, equals: field)
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.xl)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .background(Color.accentColor.opacity(focused ? Tint.faint : 0),
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.8) : .white.opacity(Tint.subtle),
                              lineWidth: focused ? 1.4 : 0.8)
        )
        .scaleEffect(focused ? 1.012 : 1)
        .animation(Motion.snap, value: focused)
    }
}

// MARK: - v3.9.45 登录页动效辅助
//
// 与 ChatInputBar 的 sendPulse 同族口径：多轨/递延一律交给系统排（不靠 sleep 对齐节拍），
// 并且**必须留静态档**——「减弱动态效果」下 stagedIn 直出满位、shakeOnce 传 0 常量关掉。
// 拆成独立扩展而非内联进 body：本文件 body 曾以 233 行撞过两次 CI 类型检查超时。

/// 进场递延：Splash 淡出（`shown` 翻真）后按 index 逐档错开 45ms 上浮入位
private struct StagedIn: ViewModifier {
    let index: Int
    let shown: Bool
    let frozen: Bool

    func body(content: Content) -> some View {
        let on = shown || frozen
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 14)
            .animation(frozen ? nil : Motion.emerge.delay(Double(index) * 0.045), value: on)
    }
}

private struct ShakeX {
    var x: Double = 0
}

extension View {
    func stagedIn(_ index: Int, shown: Bool, frozen: Bool) -> some View {
        modifier(StagedIn(index: index, shown: shown, frozen: frozen))
    }

    /// 登录失败的一次性水平抖动；`trigger` 传 0 = 不播（静态档走这条路）
    func shakeOnce(_ trigger: Int) -> some View {
        keyframeAnimator(initialValue: ShakeX(), trigger: trigger) { content, v in
            content.offset(x: CGFloat(v.x))
        } keyframes: { _ in
            KeyframeTrack(\.x) {
                LinearKeyframe(-9, duration: 0.06)
                LinearKeyframe(8, duration: 0.08)
                LinearKeyframe(-6, duration: 0.08)
                LinearKeyframe(3, duration: 0.07)
                SpringKeyframe(0, duration: 0.18)
            }
        }
    }
}
