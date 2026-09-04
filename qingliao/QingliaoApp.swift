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
                    NotificationHelper.requestAuth()
                    // v3.0.x：初始化图片缓存限制（避免首次使用前无上限缓存）
                    initImageCacheLimit()
                    // v3.0.x：注入 AuthStore 到本地工具执行器（云端 HA/Docker 工具用）
                    LocalToolRunner.authStore = auth
                    // v3.0.x：注入 AuthStore 到朗读管理（语音引擎 TTS 经 /api/tts 需带 token）
                    SpeechManager.shared.attach(auth: auth)
                    // v3.0.74：注入 AuthStore 到钉一钉存储
                    PinStore.shared.attach(auth: auth)
                    // v3.0.82：注入收件箱依赖 + 启动推送轮询（Hermes 主动推消息到 App）
                    InboxStore.shared.attach(auth: auth, chat: chat, stream: stream)
                    InboxStore.shared.startPolling()
                    // v3.1.5：启动自动加载上次会话消息（解决 App 重启后"忘记上下文"）
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
        // v3.2.1 双保险：注册 UserDefaults 默认值。
        // 病根：@AppStorage(...) 的默认值（如 agentEnabled=true）只在视图层生效、不写盘；
        // 而 UserDefaults.standard.bool(forKey:) 在 key 从不曾写入时返回 false → 设置页显示"开"但
        // AuthStore 读 agentEnabled 却发出 false → 后端 agent_on=False 走普通 LLM。
        // register(defaults:) 在"key 不存在"时兜底返回默认值，保证 UI 与真实存储一致。
        UserDefaults.standard.register(defaults: [
            UserDefaultsKey.agentEnabled: true,
        ])
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
    }
}
