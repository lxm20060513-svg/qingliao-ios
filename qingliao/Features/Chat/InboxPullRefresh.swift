import SwiftUI
import Observation

// MARK: - v3.4.0 聊天页底部上拉 → 手动拉取收件箱（Inbox pull-to-refresh）
//
// 交互：消息列表滚到最底部后再上拉 → 底部浮起胶囊指示器（"上拉拉取推送"）
//       → 拉满阈值松手 → 调用 InboxStore.pollOnce() 立即拉取收件箱推送
//       → 注入当前会话（🔔推送气泡）+ 震动 + toast 反馈拉取结果。
// 设计：全程纯 SwiftUI。状态放 @Observable 引用类型（同 CloudStreamUIState 模式）——
//       拖动 onChanged / ScrollView preference 高频写引用属性，只有真正读它的
//       InboxPullLayer 子视图重绘，ChatView 大 body 不被拖动手势每帧重建。

/// 底部上拉拉取收件箱的全部状态（拖动进度 / 刷新中 / toast / 几何缓存）
@Observable @MainActor
final class InboxPullState {
    /// 上拉满格阈值（pt）
    static let threshold: CGFloat = 64
    /// 锚点与视口共用的命名坐标空间（挂在 messageList ZStack）
    static let spaceName = "inboxPullSpace"

    /// 当前上拉进度 0...1（拖动增量累计，跟手驱动指示器）
    var progress: CGFloat = 0
    /// 正在拉取收件箱（胶囊转 spinner）
    var refreshing = false
    /// 拉取结果 toast 文案（nil = 不显示）
    var toast: String?
    /// toast 代次——防连续两次拉取时旧 Task 的延时清空误删新 toast
    var toastGen = 0

    // MARK: 几何缓存（preference 高频写；仅拖动闭包读取 → 无视图依赖 → 不触发 UI 刷新）
    /// 内容末尾锚点 minY（in inboxPullSpace）。.infinity = 无锚点（欢迎页态）→ 不可拉
    var anchorY: CGFloat = .infinity
    /// 消息列表可视高度
    var viewportHeight: CGFloat = 0
    /// 上一次 DragGesture translation.height（增量法累计用；手势结束置 nil）
    var lastDy: CGFloat?

    /// 触底判定：内容末尾锚点已进入视口底（锚点 y ≤ 视口高 + 容差）。
    /// 覆盖两种情况：滚到底部（锚点刚好贴视口底）与内容不足一屏（锚点天然在视口内）。
    var atBottom: Bool { anchorY <= viewportHeight + 3 }
}

// MARK: - Preference keys

/// 内容末尾锚点的 minY（in .named(InboxPullState.spaceName)）
struct InboxPullAnchorKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 消息列表可视高度
struct InboxViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - 内容末尾锚点（插入 LazyVStack 最末）

/// 1pt 高的透明锚点，上报自身在命名空间坐标系的 minY。
/// 滚到底时锚点贴视口底（minY ≈ viewportHeight）；内容不足一屏时天然在视口内。
struct InboxPullAnchor: View {
    var body: some View {
        Color.clear
            .frame(height: 1)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: InboxPullAnchorKey.self,
                        value: geo.frame(in: .named(InboxPullState.spaceName)).minY
                    )
                }
            )
            .allowsHitTesting(false)
    }
}

// MARK: - 指示器 / toast 浮层（只读 state，自动订阅 → 拖动期间仅本层重绘）

/// 消息列表底部浮层：拖动胶囊指示器 + 拉取中 spinner + 结果 toast
struct InboxPullLayer: View {
    let state: InboxPullState

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: state.refreshing)
        .animation(.easeOut(duration: 0.25), value: state.toast)
    }

    @ViewBuilder
    private var content: some View {
        if state.refreshing {
            pullCapsule {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.accentColor)
                Text("正在拉取收件箱…")
                    .foregroundStyle(.secondary)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let t = state.toast {
            pullCapsule {
                Text(t)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if state.progress >= 0.03 {
            let ready = state.progress >= 1
            pullCapsule {
                Image(systemName: ready ? "arrow.up.circle.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ready ? Color.accentColor : Color.secondary)
                Text(ready ? "松手拉取推送" : "上拉拉取推送")
                    .foregroundStyle(ready ? Color.accentColor : Color.secondary)
            }
            // 跟手上浮（不放 .animation，拖动须即时）
            .offset(y: -state.progress * 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func pullCapsule<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c()
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 15)
            .padding(.vertical, 8.5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
            .padding(.bottom, 10)
    }
}

// MARK: - ChatView 手势接线（extension 放独立文件，避免撑大 ChatView body 的 type-check）

extension ChatView {
    /// 挂消息 ScrollView 的底部上拉手势（simultaneous：不吞正常滚动）
    var inboxPullDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in inboxPullDragChanged(value) }
            .onEnded { _ in inboxPullDragEnded() }
    }

    private func inboxPullDragChanged(_ value: DragGesture.Value) {
        let st = inboxPull
        // 刷新中 / AI 流式中（自动滚底，会误触） / 多选模式 → 不响应
        guard !st.refreshing, !stream.isStreaming, !selectMode else {
            st.lastDy = nil
            return
        }
        // 未触底（锚点在视口下方）→ 普通滚动，不累计
        guard st.atBottom else {
            st.lastDy = nil
            return
        }
        let dy = value.translation.height
        if let last = st.lastDy {
            let delta = dy - last          // 负 = 手指继续上推
            if delta < 0 {
                st.progress = min(1, st.progress + (-delta) / InboxPullState.threshold)
            } else if st.progress > 0 {
                st.progress = max(0, st.progress - delta / InboxPullState.threshold)
            }
        }
        st.lastDy = dy
    }

    private func inboxPullDragEnded() {
        let st = inboxPull
        st.lastDy = nil
        if st.refreshing { return }
        if st.progress >= 1 {
            triggerInboxPull()
        } else {
            withAnimation(.easeOut(duration: 0.18)) { st.progress = 0 }
        }
    }

    /// 上拉满格松手 → 立即拉取一次收件箱
    private func triggerInboxPull() {
        let st = inboxPull
        guard !st.refreshing else { return }
        st.refreshing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { @MainActor in
            await inbox.pollOnce()
            st.refreshing = false
            if inbox.lastError != nil {
                st.toast = "⚠️ 拉取失败，请重试"
            } else {
                let n = inbox.lastInjectedCount
                st.toast = n > 0 ? "🔔 已拉取 \(n) 条新推送" : "✅ 暂无新推送"
            }
            UINotificationFeedbackGenerator().notificationOccurred(
                inbox.lastError != nil ? .warning : .success
            )
            withAnimation(.easeOut(duration: 0.2)) { st.progress = 0 }
            // 延时清 toast（代次防竞态：期间若又触发一次拉取，不清新 toast）
            st.toastGen += 1
            let gen = st.toastGen
            try? await Task.sleep(for: .seconds(2.2))
            if st.toastGen == gen {
                withAnimation(.easeOut(duration: 0.3)) { st.toast = nil }
            }
        }
    }
}
