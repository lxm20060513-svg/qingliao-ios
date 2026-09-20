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
                .animation(Motion.settle, value: appearance)
                .task {
                    // v2.0.36：请求本地通知权限（AI 回复完成提醒）
                    // v3.4.25：启动初始化并行化——原串行逐个 await（图片缓存/工具器/朗读/钉一钉/收件箱注入
                    // 均为同步赋值类轻操作，会话加载是重 IO）；轻操作打包一组、重 IO 一组，组内并行，缩短启动耗时
                    NotificationHelper.requestAuth()
                    initImageCacheLimit()
                    // v3.9.10：启动就采集一次环境快照（此前完全不采集 → 未登录启动后
                    // currentEnv 长期是 .unknown，语音零结果这类上报的环境字段全空、无法归因）
                    DiagnosticsEnv.refresh()
                    LiveSpeechTranscriber.cleanupLegacyRecordings()   // v3.9.3：清旧「录音上传」留下的 .m4a（新流程不落盘音频）
                    // v3.8.0：启动收敛——清掉上一进程遗留的实时活动（App 被杀/闪退后活动仍由系统保留数小时）
                    // v3.9.42：改名 convergeOrphanActivities，并且**每次回前台都再扫一次**（见 RootView 的
                    // onChange(scenePhase)）——强杀时不会执行任何代码，只在冷启动扫一次的口径下，
                    // 「不重开 App 就一直挂着」和「重开后那条已转 .stale 所以照样漏」两条都还在。
                    await LiveActivityManager.shared.convergeOrphanActivities()
                    SpeechManager.shared.attach(auth: auth)
                    // v3.9.10：预热系统音色目录（后台枚举一次，避免首次朗读/设置页在主线程枚举音色卡 3~7 秒）
                    Task { _ = await SpeechManager.voiceCatalog() }
                    PinStore.shared.attach(auth: auth)
                    MemoStore.shared.attach(auth: auth)   // v3.7.0：备忘录（NAS 双写）
                    TodoStore.shared.attach(auth: auth)   // v3.9.35：待办清单（NAS 双写）
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
                        // v3.9.39 A1：标记必须写**流归属**的会话，不是当前显示的会话。
                        // 切会话不停流（既定设计：切回原会话时接回），所以「在 B 页把 App 划掉」时
                        // chat.sessionId=B 而 taskId 属于 A —— 旧写法把标记标成 B，
                        // restoreIfNeeded 的 v3.5.2 归属校验（标记 sid != 当前 sid 就不接）被这一步骗过，
                        // A 的回复永久长进 B 的历史并进入 B 的模型上下文。
                        stream.persistState(sessionId: auth.currentStreamSessionId)
                        InboxStore.shared.stopPolling()   // v3.9.1：进后台停收件箱轮询（此前 stopPolling 全仓无人调用，后台全靠系统挂起兜底）
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
    @Environment(ChatStore.self) private var chat
    // v3.4.25：上次异常退出提示弹窗（检测到未读崩溃日志时弹出，一次性）
    @State private var showCrashAlert = false
    @State private var crashAlertText = ""
    // v3.4.25：崩溃日志查看/导出弹窗（AlertSheet 内含 UIActivityViewController）
    @State private var showCrashLogSheet = false
    @State private var showSplash = true
    // v2.0.92：App 锁（启动 Face ID 验证；与 Face ID 登录相互独立）
    @AppStorage("qingliao_app_lock") private var appLockOn = false
    @State private var appUnlocked = false
    // v3.9.41（SR21）：App 锁原先只挡冷启动——appUnlocked 置真后全仓无复位点，
    // 切后台再回来直进（与开关名和用户预期不符，且放大 Secrets 页明文的暴露面）。
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // 登录门禁（v3.9.28：云端模式已移除，仅剩本地 AI 登录页）
            if auth.isLoggedIn {
                DockTabView()
            } else {
                LoginView()
            }

            // v2.0.92：App 锁遮罩（已登录 + 开关开 + 未解锁时覆盖，splash 之下）
            if auth.isLoggedIn && appLockOn && !appUnlocked {
                AppLockView {
                    withAnimation(Motion.settle) { appUnlocked = true }
                }
                .zIndex(5)
                .transition(.opacity)
            }

            // v3.9.32：登录过期横幅（401 统一收敛点 AuthStore.sessionExpired 置位后显示）
            SessionExpiredBanner()
                .zIndex(6)

            // 启动动画：一次淡入后淡出
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(10)
            }

            // v2.0.87bh：AI 回答时 Siri 边框发光（回退顶层 zIndex——下层方案被 DockTabView 背景盖住）
            let streaming = stream.isStreaming
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
        // SR10：登出（logout() 的四个调用点：设置页/服务器地址改动/过期横幅「去登录」）
        // 统一在这里收敛——AuthStore 看不到 ChatStore，而后者是 App 级 @State、跨登录态存活。
        // 不清的话换账号登录后看到的仍是旧账号会话，且 loadLastSession 的 isEmpty 护栏让它不会被覆盖。
        .onChange(of: auth.isLoggedIn) { _, logged in
            if !logged { chat.resetForLogout() }
        }
        // v3.9.41（SR21）：每次退到后台都重新上锁（回前台即见锁屏，符合「App 锁」预期）。
        // 注意不能挂进 :57 那个 QingliaoApp 里的 onChange(scenePhase)——RootView 看不到那个属性。
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, appLockOn {
                appUnlocked = false
            }
            // v3.9.42：回前台收敛孤儿实时活动。实时活动**没有连续帧源**、本进程活着才推得动，
            // 而「在别的会话里跑完 / App 被挂起时跑完 / 直接强杀」这几条路径都没有任何人去调 `finish()`，
            // 于是灵动岛停在「AI 正在回复」上不出。这里靠不变量兜住：本进程没在跟任何一轮
            // （`currentSessionId == nil`）而系统里还挂着一条 ⇒ 它一定是孤儿 ⇒ 立即收掉。
            // 流式途中回前台：管理器认得这一轮 → 方法内部第一行就 return，不会误杀正在显示的活动。
            if phase == .active {
                Task { await LiveActivityManager.shared.convergeOrphanActivities() }
            }
        }
        // v3.9.42：本机流收尾的**跨会话兜底**（修「任务完成后灵动岛一直不退出」的主路径）。
        // `finish()` 原来只由 `ChatView.onChange(of: aiBusy)` 驱动，而 v3.9.41 把 aiBusy 按会话收窄后，
        // 用户切走/离开聊天页 → 那个 ChatView 连同 `.task` 一起没了，A 轮的完成信号没有任何接收者。
        // RootView 常驻不销毁，且这里拿的是**全局**流状态（不收窄），正好补这一刀。
        // ⚠️ 观察 `finishSeq` 而不是 `isStreaming`：口径同 DockTabView v3.9.33 那段注释——
        // finish() 里 isStreaming=false 后同步回调 onFinished，排队续发会在同一帧把它设回 true，
        // 观察 isStreaming 会 old/new 都是 true、整轮收尾被静默跳过。
        .onChange(of: stream.finishSeq) { _, _ in
            let sid = auth.currentStreamSessionId
            let running = stream.isStreaming
            let failed = stream.lastFinishFailed
            Task { await LiveActivityManager.shared.finishOrphanedRound(streamSessionId: sid,
                                                                       streamIsRunning: running,
                                                                       failed: failed) }
        }
        // v3.9.41（SR21）：设置页把锁打开后，当前这次会话也要立即生效（否则只挡下次冷启动）
        .onChange(of: appLockOn) { _, on in
            if on { appUnlocked = false }
        }
        // v3.9.28：模式切换已随云端模式移除，这里只剩崩溃日志快照
        .onAppear {
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
        .task {
            // v2.0.43：登录态下上报上次崩溃（不阻塞启动）
            // v3.4.29：改为真·后台——原 await 让「网络往返 + 1.6s」串行叠加，启动总时长被上报耗时拖长
            if auth.isLoggedIn {
                Task { await CrashReporter.flushPending(auth: auth) }
            }
            // v3.4.29：Splash 由固定 1.6s 空等 → 最短 0.6s（保留品牌节奏）。
            // 首屏内容全部来自本地数据（会话消息/AI 记忆），无需等网络
            try? await Task.sleep(for: .seconds(0.6))
            withAnimation(Motion.emerge) { showSplash = false }
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
                    .font(.system(size: Typography.title))
                    .foregroundStyle(.orange)
                Text("上次异常退出")
                    .font(.system(size: Typography.title, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.titleXL)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Text(allowDismiss
                 ? "检测到上次使用时 App 异常退出，已记录崩溃日志。可导出日志帮助定位问题。"
                 : "最近一次崩溃日志（上报成功后仍保留本地快照供回查）。")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            // 日志预览（最多展示前 12 行，完整内容走导出/复制）
            ScrollView {
                Text(String(logText.split(separator: "\n").prefix(12).joined(separator: "\n")))
                    .font(.system(size: Typography.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .padding(Spacing.lg)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
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
                    .padding(.vertical, Spacing.lg)
                    .background(Color.secondary.opacity(Tint.soft), in: Capsule())
                    .font(.system(size: Typography.body, weight: .semibold))
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
                    .font(.system(size: Typography.body, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .pill(.primary)
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
                        .padding(.vertical, Spacing.lg)
                        .background(Color.secondary.opacity(Tint.soft), in: Capsule())
                        .font(.system(size: Typography.body, weight: .semibold))
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
