import SwiftUI
import UIKit

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
    // v3.4.x 任务中心：收件箱非 reply 任务汇总入口
    @State private var showTaskCenter = false
    @State private var taskStore = TaskCenterStore.shared

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
            // v3.4.x 任务中心：右上角悬浮入口（钟形图标 + 未读红点），点击弹全屏任务列表。
            // 仅当有任务（非 reply 收件）时显示；无任务隐藏，不打扰。
            .overlay(alignment: .topTrailing) {
                if taskStore.uncompleted > 0 {
                    Button {
                        showTaskCenter = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell.badge")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.primary)
                                .padding(11)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                            if taskStore.uncompleted > 0 {
                                Text("\(min(taskStore.uncompleted, 99))")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.red)
                                    .clipShape(Capsule())
                                    .offset(x: 2, y: -2)
                            }
                        }
                    }
                    .padding(.trailing, 14)
                    .padding(.top, 6)
                }
            }
            .fullScreenCover(isPresented: $showTaskCenter) {
                TaskCenterView()
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
            // v3.4.14 系统分享接入口：捕获从其他 App 分享进来的内容 → 入 ShareRouter + 通知 ChatView
            .onOpenURL { url in
                handleShareURL(url)
            }
        }
    }

    // MARK: - v3.4.14 系统分享接入口
    /// 解析系统分享的 URL（文件/图片/文本/链接）→ 生成 SharedPayload 入 ShareRouter，切到聊天页并广播。
    private func handleShareURL(_ url: URL) {
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
            payload = SharedPayload(text: url.absoluteString, image: nil, sourceName: nil)
        } else if let text = try? String(contentsOf: url, encoding: .utf8) {
            payload = SharedPayload(text: text, image: nil, sourceName: url.lastPathComponent)
        }
        guard let payload else { return }
        ShareRouter.shared.enqueue(payload)
        selected = .chat
        NotificationCenter.default.post(name: .qingliaoShareIncoming, object: nil)
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
