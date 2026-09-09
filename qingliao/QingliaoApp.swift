import SwiftUI

@main
struct QingliaoApp: App {
    // v2.0.60：通知点击直达会话（AppDelegate 捕获）
    @UIApplicationDelegateAdaptor(QingliaoAppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase   // v2.0.61 流式持久化
    @State private var auth = AuthStore()
    @State private var chat = ChatStore()
    @State private var stream = StreamClient()
    @State private var keyboard = KeyboardObserver()
    @State private var inbox = InboxStore.shared
    // v3.0.27：会话分类
    @State private var categoryStore = CategoryStore()
    @AppStorage("qingliao_appearance") private var appearance = "system"   // dark / light / system（v2.0.42 默认跟随系统，与 SettingsView 默认值一致）

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(chat)
                .environment(stream)
                .environment(keyboard)
                .environment(inbox)
                .environment(categoryStore)
                .environment(SessionTagStore.shared)   // v3.0.51 B7：会话标签
                .preferredColorScheme(colorScheme)
                // v3.0.22：主题切换过渡动画（深色/浅色切换平滑过渡）
                .animation(.easeInOut(duration: 0.3), value: appearance)
                .task {
                    // v2.0.36：请求本地通知权限（AI 回复完成提醒）
                    // v3.4.25：启动初始化并行化——原串行逐个 await（图片缓存/工具器/朗读/钉一钉/收件箱注入
                    // 均为同步赋值类轻操作，会话加载是重 IO）；轻操作打包一组、重 IO 一组，组内并行，缩短启动耗时
                    NotificationHelper.requestAuth()
                    initImageCacheLimit()
                    LocalToolRunner.authStore = auth
                    SpeechManager.shared.attach(auth: auth)
                    PinStore.shared.attach(auth: auth)
                    InboxStore.shared.attach(auth: auth, chat: chat, stream: stream)
                    InboxStore.shared.startPolling()
                    // v3.1.5：启动自动加载上次会话消息（解决 App 重启后"忘记上下文"）
                    // v3.4.25：与上方轻初始化解耦后仍 await 收尾（根视图依赖会话内容渲染）
                    if auth.isLoggedIn {
                        await chat.loadLastSession(auth: auth)
                    }
                }
                // v2.0.61：App 进后台时持久化流式状态（杀后台可恢复）
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        stream.persistState(sessionId: chat.sessionId)
                    }
                    // v2.0.87t：前台恢复自动重连（蜂窝 IPv6 会话后台过期 → 重建，免手动飞行模式）
                    // v3.0.81：串行恢复——先刷新网络会话，再恢复流式（原并发导致 restartPolling 用旧连接）
                    if phase == .active {
                        Task {
                            await auth.refreshConnection()
                            // v3.0.73/81：后台回来时恢复流式轮询（restartPolling 内部已含 refreshConnection + 二次 recover）
                            if stream.isStreaming, !stream.isDone {
                                await stream.restartPolling(auth: auth)
                            }
                            // v3.0.82：前台恢复立即拉取收件箱并重启推送轮询
                            InboxStore.shared.refreshOnActive()
                        }
                    }
                }
        }
    }

    init() {
        // v2.0.43：崩溃捕获（写本地文件），登录后由 RootView 上报
        CrashReporter.install()
        // v3.4.12：移除 register(defaults: [agentEnabled: true])——设置页「Agent 智能回复」开关已删，
        // AuthStore.streamStart 恒发 agentEnabled=true，不再读该 UserDefaults 键，兜底注册已无意义。
    }

    /// 外观：跟随用户选择（深色 #000 / 白天 #FFF / 跟随系统）
    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "system": return nil
        default: return .dark
        }
    }
}

struct RootView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(StreamClient.self) private var stream   // v2.0.87bd：Siri 发光读取流式状态
    @Environment(ChatStore.self) private var chat   // v3.0.2：模式切换时要复位会话语境
    // v3.0：@Observable 单例必须 @State 持有，body 才能观察 mode 变化（否则分支切换不响应）
    @State private var config = CloudConfig.shared
    // v3.0.2：登录页 TabView 页码（0=本地AI 1=云端AI），与 config.mode 双向同步
    @State private var loginPage: Int = 0
    // v3.4.25：上次异常退出提示弹窗（检测到未读崩溃日志时弹出，一次性）
    @State private var showCrashAlert = false
    @State private var crashAlertText = ""
    // v3.4.25：崩溃日志查看/导出弹窗（AlertSheet 内含 UIActivityViewController）
    @State private var showCrashLogSheet = false
    private var modeIndex: Binding<Int> {
        Binding(
            get: { config.isCloudMode ? 1 : 0 },
            set: { loginPage = $0 }
        )
    }
    @State private var showSplash = true
    // v2.0.92：App 锁（启动 Face ID 验证；与 Face ID 登录相互独立）
    @AppStorage("qingliao_app_lock") private var appLockOn = false
    @State private var appUnlocked = false

    var body: some View {
        ZStack {
            // v3.0.2 登录门禁：TabView paging——左右滑动切换本地/云端 AI 登录页
            if auth.isLoggedIn {
                DockTabView()
            } else {
                TabView(selection: $loginPage) {
                    LoginView()
                        .tag(0)
                    CloudLoginView()
                        .tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
                // 滑动到哪页 → 同步模式（loginPage 是真页码，滑动即改）
                .onChange(of: loginPage) { _, new in
                    if new == 0 && config.isCloudMode { config.setMode(.local) }
                    else if new == 1 && !config.isCloudMode { config.setMode(.cloud) }
                }
            }

            // v2.0.92：App 锁遮罩（已登录 + 开关开 + 未解锁时覆盖，splash 之下）
            if auth.isLoggedIn && appLockOn && !appUnlocked {
                AppLockView {
                    withAnimation(.easeOut(duration: 0.3)) { appUnlocked = true }
                }
                .zIndex(5)
                .transition(.opacity)
            }

            // 启动动画：一次淡入后淡出
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(10)
            }

            // v2.0.87bh：AI 回答时 Siri 边框发光（回退顶层 zIndex——下层方案被 DockTabView 背景盖住）
            // v3.0.2：云端模式也会触发（CloudBackend.isStreaming）；原只看 stream.isStreaming（云端永不 true → 发光失效）
            let streaming = stream.isStreaming || CloudBackend.shared.isStreaming
            if streaming && UserDefaults.standard.bool(forKey: "qingliao_siri_glow") {
                SiriGlowOverlay()
                    .zIndex(20)
            }
            // v3.0.36：灵动岛发光（同 streaming 条件，独立开关 qingliao_island_glow）
            if streaming && UserDefaults.standard.bool(forKey: "qingliao_island_glow") {
                IslandGlowOverlay()
                    .zIndex(21)
            }
        }
        // v3.0.1：模式切换驱动登录页过渡动画（ModeSwitchBar 点击 → mode 变化 → 平滑滑动淡入）
        .animation(.spring(duration: 0.35, bounce: 0.18), value: config.mode)
        // v3.0.3 fix：ModeSwitchBar 点「本地/云端」改 mode 后，同步登录 TabView 页码 + 复位会话语境
        // （原挂在 if/else 上导致 onChange 无法解析 → 移到 View 链末尾）
        .onChange(of: config.mode) { _, new in
            if !auth.isLoggedIn {
                loginPage = (new == .cloud) ? 1 : 0   // 同步登录 TabView 当前页
            }
            chat.switchToMode()   // 会话串位根治：切模式清空内存，从新模式 key 重读
        }
        // v3.0.5 review fix：冷启动/登出后 loginPage 与持久化 mode 同步（原恒为 0 → 云端模式登出后错位）
        .onAppear {
            if !auth.isLoggedIn {
                loginPage = config.isCloudMode ? 1 : 0
            }
            // v3.4.25：启动时留存最近一次崩溃日志快照（flushPending 上报成功会删原文件，
            // 快照保证设置页「崩溃日志」入口始终可回查），并检测未读崩溃 → 弹低调提示
            if CrashReporter.hasPendingLog() {
                let text = CrashReporter.latestLogText()
                if !text.isEmpty {
                    UserDefaults.standard.set(String(text.prefix(8000)),
                                              forKey: "qingliao_last_crash_log")
                }
                crashAlertText = text
                showCrashAlert = true
            }
        }
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            if !loggedIn {
                // 登出回门禁 → 登录页跟随当前模式（云端=1 本地=0）
                loginPage = config.isCloudMode ? 1 : 0
            }
        }
        .task {
            // v2.0.43：登录态下上报上次崩溃（不阻塞启动）
            if auth.isLoggedIn {
                await CrashReporter.flushPending(auth: auth)
            }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.45)) { showSplash = false }
        }
        // v3.4.25：上次异常退出提示（毛玻璃风格低调弹窗，导出/忽略两键）
        .sheet(isPresented: $showCrashAlert) {
            CrashAlertSheet(logText: crashAlertText)
                .presentationDetents([.medium])
        }
        // v3.4.25：设置页「崩溃日志」入口复用同一查看/导出弹窗（隐藏忽略按钮，防误删日志）
        .sheet(isPresented: $showCrashLogSheet) {
            CrashAlertSheet(logText: CrashReporter.latestLogText(), allowDismiss: false)
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - v3.4.25 上次异常退出提示 Sheet（毛玻璃风格，导出日志 / 忽略）

struct CrashAlertSheet: View {
    let logText: String
    // v3.4.25：false = 设置页复用形态（无「忽略」键，点完成不删日志，防误删可回查）
    var allowDismiss: Bool = true
    @Environment(\.dismiss) private var dismiss
    @State private var showExporter = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.orange)
                Text("上次异常退出")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Text(allowDismiss
                 ? "检测到上次使用时 App 异常退出，已记录崩溃日志。可导出日志帮助定位问题。"
                 : "最近一次崩溃日志（上报成功后仍保留本地快照供回查）。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            // 日志预览（最多展示前 12 行，完整内容走导出/复制）
            ScrollView {
                Text(String(logText.split(separator: "\n").prefix(12).joined(separator: "\n")))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .padding(10)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = logText
                    copied = true
                } label: {
                    HStack {
                        Spacer()
                        Text(copied ? "已复制" : "复制")
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                Button {
                    showExporter = true
                } label: {
                    HStack {
                        Spacer()
                        Label("导出日志", systemImage: "square.and.arrow.up")
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                    .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                if allowDismiss {
                    Button {
                        CrashReporter.markAsRead()   // v3.4.25：忽略 → 删本地崩溃文件，下次启动不再弹
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("忽略")
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(18)
        // v3.4.25：iOS 16+ 系统 UIActivityViewController 封装（AirDrop/备忘录/文件等全分享面板）
        .sheet(isPresented: $showExporter) {
            ActivityShareSheet(items: [logText])
        }
    }
}

// v3.4.25：UIActivityViewController 的 SwiftUI 封装（跳过 fileExporter，直接系统分享面板）
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
