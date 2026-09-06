import SwiftUI

enum DockTab: String, CaseIterable, Identifiable {
    case chat, sessions, dashboard, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "聊天"
        case .sessions: "会话"
        case .dashboard: "看板"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .chat: "message.fill"
        case .sessions: "clock"
        case .dashboard: "square.grid.2x2.fill"
        case .settings: "gearshape.fill"
        }
    }
}

struct DockTabView: View {
    @State private var selected: DockTab = .chat
    @Environment(AuthStore.self) private var auth
    @Environment(ChatStore.self) private var chat
    @Environment(StreamClient.self) private var stream
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        // v3.0.64：改用 iOS 26 系统原生 TabView tab bar —— 系统自动渲染液态玻璃 tab bar，
        // 自带按压放大/流动折射/边缘高光（即用户要的控制中心那种原生效果）。
        // 弃自定义 DockBar / DockVisibility / 手势（系统 tab bar 原生支持这些，无需自研）。
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            TabView(selection: $selected) {
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
                        .tabItem { Label(DockTab.chat.title, systemImage: DockTab.chat.icon) }
                }
                SessionsView(onOpenSession: { selected = .chat })
                    .tabTransition(for: .sessions, selected: $selected)
                if CloudConfig.shared.isCloudMode {
                    CloudDashboardView()
                        .tabTransition(for: .dashboard, selected: $selected)
                } else {
                    DashboardView()
                        .tabTransition(for: .dashboard, selected: $selected)
                }
                if CloudConfig.shared.isCloudMode {
                    CloudSettingsView()
                        .tabTransition(for: .settings, selected: $selected)
                } else {
                    SettingsView()
                        .tabTransition(for: .settings, selected: $selected)
                }
            }
            // v3.0.60 回顾：系统 tab bar 自行处理滚动边缘玻璃；此处不再加纯色背景掐死折射
            .onChange(of: selected) { _, new in
                if new != .dashboard {
                    NotificationCenter.default.post(name: .qingliaoDashboardLeave, object: nil)
                }
                if new == .dashboard {
                    NotificationCenter.default.post(name: .qingliaoDashboardRefresh, object: nil)
                }
            }
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
                        selected = .chat
                    }
                } else if let arr = try? await auth.jsonArray("/api/sessions/list") {
                    let sessions = arr.compactMap { ChatSession.parse($0 as? [String: Any] ?? [:]) }
                    if let s = sessions.first(where: { $0.id == sid }) {
                        chat.load(s)
                        selected = .chat
                    }
                }
            }
        }
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
            .scaleEffect(appeared ? 1 : 0.97, anchor: .center)
            .animation(.easeInOut(duration: 0.2), value: appeared)
            .onAppear {
                Task { try? await Task.sleep(for: .seconds(0.01)); appeared = true }
            }
            .onChange(of: selected) { _, newVal in
                withAnimation(.easeInOut(duration: 0.2)) {
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
