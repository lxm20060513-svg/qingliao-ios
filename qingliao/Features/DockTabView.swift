import SwiftUI
import CoreLocation
import UIKit

enum DockTab: String, CaseIterable, Identifiable {
    // v3.6.2：dock 顺序重排 = 会话 → 看板 → 聊天 → 生活 → 设置
    // （enum 声明序与 TabView 内声明序一致，便于对照；TabView 顺序由视图插入序决定）
    case sessions, dashboard, chat, life, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: "会话"
        case .dashboard: "看板"
        case .chat: "聊天"
        case .life: "生活"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .sessions: "clock"
        case .dashboard: "square.grid.2x2.fill"
        case .chat: "message.fill"
        case .life: "sparkles"
        case .settings: "gearshape.fill"
        }
    }
}

struct DockTabView: View {
    @State private var selected: DockTab = .chat
    // v3.6.2：dock 智能球点击 → 全屏粒子爆发（原由聊天页智能球展开触发，球迁到 dock 后跟随迁移）
    @State private var showDockBurst = false
    /// v3.6.2：分享/深链等「程序化切到聊天页」跳过烟花（烟花的语义是「点了 dock 智能球」）
    @State private var skipNextBurst = false
    /// v3.9.33：球第三态「刚答完未查看」——AI 收尾时用户不在这页
    @State private var orbUnseen = false
    /// v3.9.33：球错误态——上一次请求真失败（用户主动停止不算），进聊天页即清
    @State private var orbFailed = false
    /// v3.9.33：实测 dock bar 高度（DockOrbOverlay 回写）——烟花原点与球心同源，别各算一套
    @State private var dockBarHeight: CGFloat = DockOrbOverlay.fallbackBarHeight
    /// v3.9.59（攒版）：长按智慧球 → 快捷菜单（新建会话 / AI 速记 / 语音输入 / 今日待办）
    @State private var showOrbMenu = false
    /// v3.9.59：速记弹窗（AI 速记 → 备忘录；今日待办 → 待办清单）
    @State private var quickCapture: QuickCaptureMode?
    @Environment(AuthStore.self) private var auth
    @Environment(ChatStore.self) private var chat
    @Environment(StreamClient.self) private var stream
    @Environment(\.horizontalSizeClass) private var hSize

    /// v3.6.2：聊天槽位用智能球替身——仅 iPhone（iPad 保持系统图标原样）
    private var orbInDock: Bool { hSize != .regular }
    /// dock 槽位数（5：会话/看板/聊天/生活/设置）
    private var dockSlotCount: Int { 5 }
    /// v3.9.33：这页的回复是否正摆在用户眼前 = 聊天 tab **且**当前会话就是刚收尾的那条流。
    /// 只看 `selected == .chat` 会漏报——人在聊天页看会话 B 时，会话 A 的回复落地也该提示。
    private var chatVisible: Bool {
        selected == .chat && auth.currentStreamSessionId == chat.sessionId
    }

    var body: some View {
        // v3.0.64：改用 iOS 26 系统原生 TabView tab bar —— 系统自动渲染液态玻璃 tab bar，
        // 自带按压放大/流动折射/边缘高光（即用户要的控制中心那种原生效果）。
        // 弃自定义 DockBar / DockVisibility / 手势（系统 tab bar 原生支持这些，无需自研）。
        ZStack {
            // v3.4.29：移除铺底纯色（原 Color(uiColor: .systemBackground).ignoresSafeArea()）——
            // 纯色铺在 TabView 下层会掐死系统 tab bar 的滚动边缘玻璃折射（"玻璃发灰"根因）。
            // 各页自带背景，tab bar 玻璃改为采样真实滚动内容。

            TabView(selection: $selected) {
                SessionsView(onOpenSession: { selected = .chat })
                    .tabTransition(for: .sessions, selected: $selected)
                // v3.4.26：isActive 参数直传（selected==.dashboard），替代 qingliaoDashboardLeave/Refresh 通知——
                // 轮询暂停/恢复收进 DashboardView 自身生命周期，去隐式耦合
                DashboardView(isActive: selected == .dashboard)
                    .tabTransition(for: .dashboard, selected: $selected)
                chatTab
                // v3.6.2：生活页（原看板「生活数据」栏目迁入）
                LifeView(isActive: selected == .life)
                    .tabTransition(for: .life, selected: $selected)
                SettingsView()
                    .tabTransition(for: .settings, selected: $selected)
            }
            // v3.4.30：装机实测后按用户要求关闭自动收缩——tab bar 常驻不缩，滚动时不再变窄
            // （v3.4.29 曾设为 .onScrollDown：向下滚动缩到角落只剩图标，用户不需要）
            .tabBarMinimizeBehavior(.never)
            // v3.9.47 方案 B（UIKit 侧改 UITabBar 外观）真机实测同样无效，已整块回退——
            // 这里**不要再挂任何东西**，理由见下方 chatTab 的注释与 README「iOS 26 系统玻璃的三条口径」。
            // v3.4.29：切 tab 触感——挂在一处（TabView），别挂进每个 tab 的 modifier（会响 4 次）
            .onChange(of: selected) { _, newVal in
                Haptics.tap()
                // v3.9.59：切页即收起长按菜单——手动切 tab 与程序化切页（深链 / 分享 / 备忘录「发给 AI」/
                // 灵动岛）都走这里；不收的话菜单会浮在新页面上（此时命中层已被 if !showOrbMenu 摘掉）。
                if showOrbMenu { showOrbMenu = false }
                // v3.9.33：切到聊天页 = 回复已在眼前 → 清掉球上的「未查看 / 失败」提示
                if newVal == .chat { clearOrbNotice() }
                // v3.6.2：点 dock 智能球（= 切到聊天页）→ 放烟花，保留原智能球的点击特效
                if orbInDock, newVal == .chat {
                    if skipNextBurst { skipNextBurst = false } else { fireDockBurst() }
                }
            }
            // v3.9.33：球第三态 + 错误态——AI 收尾时用户不在这页 =「刚答完未查看」；真失败则压暗。
            // 用户主动停止/取消不算失败（StreamClient.lastFailed 统一判定，见 finish(userInitiated:)）；
            // 在聊天页里收尾不置位：错误气泡/回复本身就在眼前，置位会让球一直暗着。
            // ⚠️ 收尾判定用 `finishSeq`（只增不减）观察，**不能观察 `isStreaming` 的变化**：
            // finish() 里 isStreaming=false 后同步回调 onFinished，排队续发（sendQueued → start()）会在
            // 同一帧把它设回 true → onChange 看到 old/new 都是 true，整轮收尾被静默跳过（失败不压暗、
            // 「未查看」也不亮）。序号只增，收尾一定被观察到一次。
            .onChange(of: stream.finishSeq) { _, _ in
                if stream.lastFinishFailed {
                    orbFailed = !chatVisible
                    orbUnseen = false
                } else {
                    orbUnseen = !chatVisible
                    orbFailed = false
                }
            }
            // 新流开跑 = 上一轮的失败提示收掉（否则球会一直暗着）；「未查看」保留（排队消息自动续发不该吞掉它）
            .onChange(of: stream.isStreaming) { _, now in
                if now { orbFailed = false }
            }
            // v3.6.2：dock 聊天槽位智能球——系统 tab item 只能放系统图标（iOS 26 无自定义视图 API），
            // 故该槽位 item 置为空（无图标无文字），球由本叠加层自绘并居中于槽位；
            // allowsHitTesting(false) 让触摸穿透给下层系统 tab item（点球 = 系统切页）。
            .overlay {
                if orbInDock {
                    // 聊天槽位序号 = 2（会话0 / 看板1 / 聊天2 / 生活3 / 设置4）
                    // thinking: AI 流式回答中球切 orbits 旋转——原聊天页智能球的行为在 dock 槽位保留
                    DockOrbOverlay(slotIndex: 2,
                                   slotCount: dockSlotCount,
                                   thinking: stream.isStreaming,
                                   unseen: orbUnseen,
                                   failed: orbFailed,
                                   measuredBarHeight: $dockBarHeight)
                        .allowsHitTesting(false)
                    // v3.9.59：球命中层——只盖住球体一小块（68pt 圆）：
                    //   轻点 = 手动切聊天页（onChange 的触感/清提示/烟花照旧走一遍），
                    //   长按 = 弹快捷菜单。菜单开着时本层不显示（菜单层自己接管全部交互）。
                    if !showOrbMenu {
                        OrbHitLayer(barHeight: dockBarHeight,
                                    slotIndex: 2,
                                    slotCount: dockSlotCount,
                                    // v3.9.59：轻点复用「点系统 tab item」的语义——已在聊天页时 selected 不变、
                                    // onChange 不触发，触感与清提示会整体丢失（原先这层是系统 tab item 的按压反馈）。
                                    onTap: {
                                        if selected == .chat { Haptics.tap(); clearOrbNotice() }
                                        else { selected = .chat }
                                    },
                                    onLongPress: {
                                        Haptics.press()
                                        showOrbMenu = true
                                    })
                    }
                }
            }
            // v3.9.59：长按球快捷菜单浮层（最顶层，模态——轻纱吃掉空白点击收起）
            .overlay {
                if showOrbMenu {
                    OrbQuickMenuOverlay(barHeight: dockBarHeight,
                                        slotIndex: 2,
                                        slotCount: dockSlotCount,
                                        onAction: { handleOrbAction($0) },
                                        onClose: { showOrbMenu = false })
                        .transition(.opacity)
                        .zIndex(40)
                }
            }
            .animation(Motion.snap, value: showOrbMenu)
            // v3.9.59：速记弹窗（AI 速记 / 今日待办共用一个输入弹窗）
            // v3.9.59：onDismiss 复位——若某次 present 被别的 sheet 挡掉，quickCapture 会一直非 nil，
            // 之后「AI 速记 / 今日待办」再也弹不出来（MemoSection v3.9.17 / TodoSection 同款坑，本仓踩过）。
            .sheet(item: $quickCapture, onDismiss: { quickCapture = nil }) { mode in
                QuickCaptureSheet(mode: mode)
            }
            // v3.0.60 回顾：系统 tab bar 自行处理滚动边缘玻璃；此处不再加纯色背景掐死折射
            // v3.4.26：切页暂停/恢复看板轮询已改参数直传（DashboardView(isActive:)），通知已移除
            // v3.4.24：任务中心悬浮入口已移除——迁入聊天页 header（三个点旁常驻小图标），
            // 见 ChatView.headerTrailingItems。此处不再挂全局 overlay（避免遮挡各页右上角按钮）。
            // v3.6.2：全屏粒子爆发（点 dock 智能球触发；纯视觉，不挡交互）
            .overlay {
                if showDockBurst {
                    FullScreenBurst(originFromBottom: DockOrbOverlay.ballCenterFromBottom(barHeight: dockBarHeight))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(30)
                }
            }
            .animation(Motion.tap, value: showDockBurst)
            .task {
                guard let sid = UserDefaults.standard.string(forKey: "qingliao_open_session") else { return }
                UserDefaults.standard.removeObject(forKey: "qingliao_open_session")
                // v3.9.39 A7：深链此前**从未生效过**。这里用 `jsonArray` 解 /api/sessions/list，
                // 而该接口返回的是对象 {ok, sessions, total}——`as? [Any]` 对字典恒 nil ⇒ 必抛
                // badJSON，又被外层 `try?` 吞成 nil ⇒ 整条 if 静默跳过：点通知、灵动岛长按选会话
                // 全部停在空白新会话。改成与同仓 ChatStore.loadLastSession / SessionsView.load
                // 同一口径（json + ["sessions"]）；失败也不再无痕迹，留一行日志说明是哪个会话。
                guard let j = try? await auth.json("/api/sessions/list"),
                      let raw = j["sessions"] as? [Any] else {
                    print("[deepLink] 会话列表拉取失败，无法打开会话 \(sid)")
                    return
                }
                let sessions = raw.compactMap { ChatSession.parse($0 as? [String: Any] ?? [:]) }
                guard let s = sessions.first(where: { $0.id == sid }) else {
                    print("[deepLink] 会话 \(sid) 不在服务器列表（可能已删除）")
                    return
                }
                chat.load(s)
                chat.markRead(s.id)   // v3.9.39：深链也算「打开会话」，与 SessionsView.open 同口径，否则红点永久挂着
                skipBurstOnce()
                selected = .chat
            }
            // v3.4.14 系统分享接入口：捕获从其他 App 分享进来的内容 → 入 ShareRouter + 通知 ChatView
            .onOpenURL { url in
                handleShareURL(url)
            }
            // v3.9.14：备忘录「发给 AI」——备忘录在生活页，不切回聊天页就看不到发出去的消息
            .onReceive(NotificationCenter.default.publisher(for: .qingliaoMemoSend)) { _ in
                // 程序化切页必须先跳过一次烟花（与深链/分享/灵动岛同款）——
                // 否则点「发给 AI」会误放全屏粒子（v3.6.2 修过的回归）
                skipBurstOnce()
                selected = .chat
            }
            // v3.9.7：灵动岛「停止生成」按钮——`LiveActivityIntent` 在**主 App 进程**执行，
            // 所以进程内通知能直达这里（挂件进程触不到 App 的流）
            .onReceive(NotificationCenter.default.publisher(for: LiveActivityActionBridge.notification)) { note in
                guard (note.userInfo?["action"] as? String) == LiveActivityAction.stopGeneration else { return }
                handleLiveActivityStop()
            }
            // 兜底：App 进程是刚被按钮拉起的（观察者还没注册、通知会丢）→ 启动时读一次待处理动作
            .task {
                guard LiveActivityActionBridge.consume() == LiveActivityAction.stopGeneration else { return }
                handleLiveActivityStop()
            }
        }
    }

    // MARK: - v3.6.2 聊天 tab（两态，见 chatTab）

    /// 聊天槽位（两态：`orbInDock` 就是 `hSize != .regular`，两者互补 → 原先的第三分支永不执行，已删）：
    ///   · iPad 宽屏：会话 + 聊天双栏，系统 message 图标
    ///   · iPhone：item 置空、无文字，整颗智能球由 DockOrbOverlay 居中绘制
    ///
    /// 聊天页要 tab bar **不铺那层液态玻璃**这件事，两条路都真机判过无效，**到此为止**：
    ///   · 方案 A（v3.9.46，SwiftUI `.toolbarBackground(.hidden, for: .tabBar)`）——iOS 26 只褪了
    ///     背景色、玻璃层照旧。
    ///   · 方案 B（v3.9.47，UIKit：把真实 `UITabBar` 的 standard/scrollEdgeAppearance 换成
    ///     `configureWithTransparentBackground()` 副本）——同样没褪掉，v3.9.48 用户判「回滚」，
    ///     `TabBarGlass.swift` 探针已整块删除。
    /// 第三条路也不要试（不再有公开出口的判断），更**不许**退回在 TabView 下层铺不透明色——
    /// 那会掐死所有页的滚动边缘折射（v3.4.29 红线）。
    @ViewBuilder
    private var chatTab: some View {
        if hSize == .regular {
            HStack(spacing: 0) {
                SessionsView(onOpenSession: nil)
                    .frame(width: 320)
                    .background(Color(uiColor: .systemBackground))
                Divider().opacity(0.3)
                ChatView()
            }
            .tag(DockTab.chat)
            .tabItem { Label(DockTab.chat.title, systemImage: DockTab.chat.icon) }
        } else {
            ChatView()
                .tag(DockTab.chat)
                // 槽位视觉为空（球由 DockOrbOverlay 绘制）→ 补无障碍标签，VoiceOver 仍读得出「聊天」
                .tabItem { Text("").accessibilityLabel("聊天") }
        }
    }

    /// v3.9.33：清掉球上的「未查看 / 失败」提示（进聊天页 = 回复已在眼前）
    private func clearOrbNotice() {
        orbUnseen = false
        orbFailed = false
    }

    /// 程序化切页前调用：本次切到聊天页不放烟花（0.6s 内未消费则自动复位，避免标志残留吞掉下一次真点击）
    private func skipBurstOnce() {
        skipNextBurst = true
        Task { try? await Task.sleep(for: .seconds(0.6)); skipNextBurst = false }
    }

    /// 点 dock 智能球 → 烟花（约 1.55s 后移除特效层，与原型一致）
    private func fireDockBurst() {
        showDockBurst = true
        Task { try? await Task.sleep(for: .seconds(1.55)); showDockBurst = false }
    }

    // MARK: - v3.9.59 长按智慧球快捷菜单

    /// 四个胶囊动作分发——全部复用既有入口，不新造状态：
    ///   新建会话 → requestNewSession（ChatView 的 pendingNewSession 两步走清屏，勿直接清数据）
    ///   AI 速记  → 速记弹窗 → MemoStore（source "orb"）
    ///   语音输入 → 切聊天页 + 进程内通知（ChatView.toggleVoiceMode，与输入框长按同一条路径；
    ///              DockTabView 摸不到 ChatView 的 @State，通知是本仓既有的跨页触发模式）
    ///   今日待办 → 速记弹窗 → TodoStore（source "orb"）
    private func handleOrbAction(_ action: OrbQuickAction) {
        switch action.id {
        case 0:   // 新建会话
            // v3.9.59：已在聊天页 = selected 不变、不会放烟花，白置标志会吞掉紧接着的一次真点击烟花
            if selected != .chat { skipBurstOnce() }
            selected = .chat
            chat.requestNewSession()
        case 1:   // AI 速记
            quickCapture = .memo
        case 2:   // 语音输入
            if selected != .chat { skipBurstOnce() }
            selected = .chat
            NotificationCenter.default.post(name: .qingliaoOrbVoiceInput, object: nil)
        case 3:   // 今日待办
            quickCapture = .todo
        default:
            break
        }
    }

    // MARK: - v3.4.14 系统分享接入口
    /// 解析系统分享的 URL（文件/图片/文本/链接）→ 生成 SharedPayload 入 ShareRouter，切到聊天页并广播。
    /// v3.4.24：地图 App 分享的定位链接 → 解析经纬度入 SharedPayload.location（AI 推荐周边）。
    private func handleShareURL(_ url: URL) {
        // v3.9.7：实时活动（灵动岛 / 锁屏横幅）点按深链——`widgetURL` 传进来的「回到会话」
        // v3.9.32：泛化为快捷指令 / Siri 的页面深链（qingliao://chat|sessions|dashboard|life|settings）。
        // Route.rawValue 与 DockTab.rawValue 一一对应；其余 URL 原样落到下面的分享分支。
        // （原「只认 host == chat」的窄分支已由这里覆盖——chat 也是 Route 的一个 case，别再写第二份判断。）
        if let route = QingliaoDeepLink.route(for: url), let tab = DockTab(rawValue: route.rawValue) {
            skipBurstOnce()
            selected = tab
            return
        }
        var payload: SharedPayload?
        if url.isFileURL {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let image = UIImage(contentsOfFile: url.path) {
                payload = SharedPayload(text: nil, image: image, sourceName: url.lastPathComponent)
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                payload = SharedPayload(text: text, image: nil, sourceName: url.lastPathComponent)
            }
        } else if let scheme = url.scheme, scheme == "http" || scheme == "https" {
            // v3.4.24：先试地图定位链接解析（geo:/高德/百度/腾讯/苹果地图…）
            if let loc = MapLocationParser.parse(url) {
                let cl = CLLocation(latitude: loc.coord.latitude, longitude: loc.coord.longitude)
                payload = SharedPayload(text: url.absoluteString, image: nil,
                                        sourceName: loc.place, location: cl)
            } else {
                payload = SharedPayload(text: url.absoluteString, image: nil, sourceName: nil)
            }
        } else if url.scheme?.lowercased() == "geo" {
            // v3.4.24：geo: URI（部分地图 App 用非 http scheme 分享）
            if let loc = MapLocationParser.parse(url) {
                let cl = CLLocation(latitude: loc.coord.latitude, longitude: loc.coord.longitude)
                payload = SharedPayload(text: url.absoluteString, image: nil,
                                        sourceName: loc.place, location: cl)
            }
        } else if let text = try? String(contentsOf: url, encoding: .utf8) {
            payload = SharedPayload(text: text, image: nil, sourceName: url.lastPathComponent)
        }
        guard let payload else { return }
        ShareRouter.shared.enqueue(payload)
        skipBurstOnce()
        selected = .chat
        NotificationCenter.default.post(name: .qingliaoShareIncoming, object: nil)
    }

    // MARK: - v3.9.7 灵动岛按钮动作

    /// 灵动岛「停止生成」——两条入口（App 活着时的进程内通知 / 进程刚被拉起的兜底 flag）
    /// 汇到同一处，走的是聊天页「停止」按钮同一个 `StreamClient.stop`。
    /// v3.9.7 review 修复：输入栏停止其实是**两件事**（`clearPendingQueue()` + `stream.stop()`），
    /// 这里少了清队列会出现「点了停止，排在后面的消息又自己发出去」（v2.0.88：回答收尾自动发队列下一条）。
    /// `pendingQueue` 是 `ChatView` 的 `@State`，Dock 摸不到 → 用进程内通知请聊天页清。
    private func handleLiveActivityStop() {
        _ = LiveActivityActionBridge.consume()   // 清掉兜底 flag（两条路径都到这儿，幂等）
        guard stream.isStreaming else { return }
        skipBurstOnce()
        selected = .chat
        NotificationCenter.default.post(name: LiveActivityActionBridge.clearPendingQueueNotification, object: nil)
        // v3.9.8 review 收口：ChatView 不在视图层级时（聊天 tab 从未打开 / 正在重建）上面这条通知会被丢弃，
        // 而排队消息是**持久化**的（下次进聊天页 restorePendingQueue 会恢复并自动发出）→ 这里补一次兜底清理，
        // 杜绝「点了停止，排队消息照样自己发出去」。
        UserDefaults.standard.removeObject(forKey: UserDefaultsKey.pendingQueue)
        stream.stop(auth: auth)
    }
}

// MARK: - Tab 切换过渡动画（淡入 + 轻微缩放，保留原生玻璃 tab bar）
private struct TabTransitionModifier: ViewModifier {
    let tab: DockTab
    @Binding var selected: DockTab
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .tag(tab)
            .tabItem { Label(tab.title, systemImage: tab.icon) }
            .scaleEffect(appeared ? 1 : 0.985, anchor: .center)   // v3.4.29：0.97→0.985，入场更细腻
            .animation(Motion.snap, value: appeared)
            .onAppear {
                Task { try? await Task.sleep(for: .seconds(0.01)); appeared = true }
            }
            .onChange(of: selected) { _, newVal in
                withAnimation(Motion.snap) {
                    appeared = (newVal == tab)
                }
            }
    }
}

extension View {
    func tabTransition(for tab: DockTab, selected: Binding<DockTab>) -> some View {
        modifier(TabTransitionModifier(tab: tab, selected: selected))
    }
}
