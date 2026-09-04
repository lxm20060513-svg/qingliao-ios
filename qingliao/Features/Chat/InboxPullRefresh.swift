import SwiftUI
import Observation

// MARK: - v3.4.1 聊天页底部上拉 → 手动拉取收件箱（Inbox pull-to-refresh）
//
// 交互：消息列表滚到最底部后再上拉 → 底部浮起胶囊指示器（"上拉拉取推送"）
//       → 拉满阈值后松手（回弹）→ 调用 InboxStore.pollOnce() 立即拉取收件箱推送
//       → 注入当前会话（🔔推送气泡）+ 震动 + toast 反馈拉取结果。
//
// 实现（v3.4.1 重写，弃 preference 锚点法）：
// 第一版用「LazyVStack 尾部锚点 + PreferenceKey」检测触底——preference 只在 SwiftUI
// 布局 pass 更新，滚动/回弹过程不保证实时，LazyVStack 懒加载回收锚点后残留旧值，
// 触发一次后 atBottom 判定僵死 → 换 iOS 18+ 官方 `onScrollGeometryChange`：
// contentOffset/contentSize 每帧实时（含过拉 bounce），overscroll 纯几何派生，
// 无状态残留，ChatView 大 body 不受影响（只重绘读状态的 InboxPullLayer）。

/// 底部上拉拉取收件箱的全部状态
@Observable @MainActor
final class InboxPullState {
    /// 上拉满格阈值（pt）
    static let threshold: CGFloat = 60

    /// 当前过拉进度 0...1（每帧由滚动几何派生：overscroll/threshold，回弹自然回落）
    var progress: CGFloat = 0
    /// 已拉满格、等待松手回弹触发（防拉满即触发；回弹过半时触发并复位）
    var armed = false
    /// 正在拉取收件箱（胶囊转 spinner）
    var refreshing = false
    /// 拉取结果 toast 文案（nil = 不显示）
    var toast: String?
    /// toast 代次——防连续两次拉取时旧 Task 的延时清空误删新 toast
    var toastGen = 0
}

// MARK: - 指示器 / toast 浮层（只读 state，自动订阅 → 滚动期间仅本层重绘）

/// 消息列表底部浮层：上拉指示器 + 拉取中 spinner + 结果 toast
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
        } else if state.progress >= 0.04 {
            let ready = state.progress >= 1
            pullCapsule {
                Image(systemName: ready ? "arrow.up.circle.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ready ? Color.accentColor : Color.secondary)
                Text(ready ? "松手拉取推送" : "上拉拉取推送")
                    .foregroundStyle(ready ? Color.accentColor : Color.secondary)
            }
            // 跟手上浮（不放 .animation，过拉位移须即时）
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

// MARK: - ChatView 接线（extension 放独立文件，避免撑大 ChatView body 的 type-check）

extension ChatView {
    /// ScrollView.onScrollGeometryChange 回调：overscroll = 内容 offset 超出底部边界的量
    /// （>0 = 已滚到底并继续上拉/回弹中；内容不足一屏时底边界按 0 计）
    func inboxPullHandleScroll(overscroll: CGFloat) {
        let st = inboxPull
        // 刷新中 / AI 流式中（自动滚底，会误触） / 多选模式 → 不响应
        guard !st.refreshing, !stream.isStreaming, !selectMode else { return }
        let clamped = min(1, max(0, overscroll / InboxPullState.threshold))
        st.progress = clamped
        if clamped >= 1 {
            st.armed = true
        } else if st.armed, overscroll < InboxPullState.threshold * 0.5 {
            // 曾拉满、现明显回弹（松手/回推）→ 触发拉取一次
            st.armed = false
            triggerInboxPull()
        } else if clamped == 0 {
            st.armed = false
        }
    }

    /// 上拉满格后松手 → 立即拉取一次收件箱
    private func triggerInboxPull() {
        let st = inboxPull
        guard !st.refreshing else { return }
        st.refreshing = true
        st.armed = false
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
