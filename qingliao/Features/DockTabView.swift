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
    @Environment(AuthStore.self) private var auth
    @Environment(ChatStore.self) private var chat
    @Environment(StreamClient.self) private var stream
    @Environment(\.horizontalSizeClass) private var hSize

    private var isCloud: Bool { CloudConfig.shared.isCloudMode }
    /// v3.6.2：聊天槽位用智能球替身——仅本地模式 + iPhone（云端模式与 iPad 保持系统图标原样）
    private var orbInDock: Bool { !isCloud && hSize != .regular }
    /// dock 槽位数（本地 5：会话/看板/聊天/生活/设置；云端 4，不加生活页）
    private var dockSlotCount: Int { isCloud ? 4 : 5 }

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
                if isCloud {
                    CloudDashboardView()
                        .tabTransition(for: .dashboard, selected: $selected)
                } else {
                    // v3.4.26：isActive 参数直传（selected==.dashboard），替代 qingliaoDashboardLeave/Refresh 通知——
                    // 轮询暂停/恢复收进 DashboardView 自身生命周期，去隐式耦合
                    DashboardView(isActive: selected == .dashboard)
                        .tabTransition(for: .dashboard, selected: $selected)
                }
                chatTab
                // v3.6.2：生活页（原看板「生活数据」栏目迁入）——仅本地模式；云端模式不做改动
                if !isCloud {
                    LifeView(isActive: selected == .life)
                        .tabTransition(for: .life, selected: $selected)
                }
                if isCloud {
                    CloudSettingsView()
                        .tabTransition(for: .settings, selected: $selected)
                } else {
                    SettingsView()
                        .tabTransition(for: .settings, selected: $selected)
                }
            }
            // v3.4.30：装机实测后按用户要求关闭自动收缩——tab bar 常驻不缩，滚动时不再变窄
            // （v3.4.29 曾设为 .onScrollDown：向下滚动缩到角落只剩图标，用户不需要）
            .tabBarMinimizeBehavior(.never)
            // v3.4.29：切 tab 触感——挂在一处（TabView），别挂进每个 tab 的 modifier（会响 4 次）
            .onChange(of: selected) { _, newVal in
                Haptics.tap()
                // v3.6.2：点 dock 智能球（= 切到聊天页）→ 放烟花，保留原智能球的点击特效
                if orbInDock, newVal == .chat {
                    if skipNextBurst { skipNextBurst = false } else { fireDockBurst() }
                }
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
                                   thinking: stream.isStreaming)
                        .allowsHitTesting(false)
                }
            }
            // v3.0.60 回顾：系统 tab bar 自行处理滚动边缘玻璃；此处不再加纯色背景掐死折射
            // v3.4.26：切页暂停/恢复看板轮询已改参数直传（DashboardView(isActive:)），通知已移除
            // v3.4.24：任务中心悬浮入口已移除——迁入聊天页 header（三个点旁常驻小图标），
            // 见 ChatView.headerTrailingItems。此处不再挂全局 overlay（避免遮挡各页右上角按钮）。
            // v3.6.2：全屏粒子爆发（点 dock 智能球触发；纯视觉，不挡交互）
            .overlay {
                if showDockBurst {
                    FullScreenBurst(originFromBottom: DockOrbOverlay.ballCenterFromBottom)
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
                if CloudConfig.shared.isCloudMode {
                    // v-review fix：云端会话存本地 CloudSessionStore——不再向 NAS /api/sessions/list 发无谓请求，
                    // 否则 sid 必然找不到、通知深链无法直达会话
                    let store = CloudSessionStore.shared
                    store.load()
                    if let s = store.sessions.first(where: { $0.id == sid }) {
                        chat.load(s)
                        skipBurstOnce()
                        selected = .chat
                    }
                } else if let arr = try? await auth.jsonArray("/api/sessions/list") {
                    let sessions = arr.compactMap { ChatSession.parse($0 as? [String: Any] ?? [:]) }
                    if let s = sessions.first(where: { $0.id == sid }) {
                        chat.load(s)
                        skipBurstOnce()
                        selected = .chat
                    }
                }
            }
            // v3.4.14 系统分享接入口：捕获从其他 App 分享进来的内容 → 入 ShareRouter + 通知 ChatView
            .onOpenURL { url in
                handleShareURL(url)
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

    // MARK: - v3.6.2 聊天 tab（三态）

    /// 聊天槽位：
    ///   · iPad 宽屏：会话 + 聊天双栏，系统 message 图标（原样保留）
    ///   · 本地 iPhone：item 置空、无文字，整颗智能球由 DockOrbOverlay 居中绘制
    ///   · 云端模式：保持原样（系统 message 图标 + 「聊天」文字，不做改动）
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
        } else if orbInDock {
            ChatView()
                .tag(DockTab.chat)
                // 槽位视觉为空（球由 DockOrbOverlay 绘制）→ 补无障碍标签，VoiceOver 仍读得出「聊天」
                .tabItem { Text("").accessibilityLabel("聊天") }
        } else {
            ChatView()
                .tag(DockTab.chat)
                .tabItem { Label(DockTab.chat.title, systemImage: DockTab.chat.icon) }
        }
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

    // MARK: - v3.4.14 系统分享接入口
    /// 解析系统分享的 URL（文件/图片/文本/链接）→ 生成 SharedPayload 入 ShareRouter，切到聊天页并广播。
    /// v3.4.24：地图 App 分享的定位链接 → 解析经纬度入 SharedPayload.location（AI 推荐周边）。
    private func handleShareURL(_ url: URL) {
        // v3.9.7：实时活动（灵动岛 / 锁屏横幅）点按深链——`widgetURL` 传进来的「回到会话」
        if url.scheme?.lowercased() == "qingliao", url.host?.lowercased() == "chat" {
            skipBurstOnce()
            selected = .chat
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
