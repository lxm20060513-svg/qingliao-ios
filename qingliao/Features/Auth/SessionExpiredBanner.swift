import SwiftUI

// MARK: - v3.9.33 登录已过期横幅（401 → 重新登录的全局一次性入口）
//
// 背景：token 过期/被吊销后，非登录接口一律 401 → `AuthStore.request / streamStart / streamPoll`
// 抛 `APIError.unauthorized`（文案「登录已过期，请重新登录」早就写好了），但**全仓此前没有任何
// catch**——流式层把它当普通失败指数退避重试 15 次（≈2 分钟），最后只显示「连接中断，请重试」，
// 用户因此永远等不到「重新登录」。
//
// 现在：401 在 `AuthStore.markSessionExpired()`（统一收敛点）置位 `sessionExpired`，
// 本视图是它的**唯一 UI 出口**；流式层见 `APIError.unauthorized` 立即停止退避并以真实原因收尾。
//
// ── 接线（仅一处，主视图独占文件，由主代理落）──
//   qingliao/QingliaoApp.swift → struct RootView.body → ZStack 内、App 锁遮罩之后加：
//       SessionExpiredBanner()
//           .zIndex(6)
//   不要塞进某个 Tab 里——过期是全局态（聊天页/会话页/看板都可能先撞上 401）。
//
// 布局：本视图自带「贴顶 + 下方透明」结构，覆盖层只拦截横幅自身的点击，
// 下方仍是原 UI 可点（Spacer 不参与命中测试）；自身高度铺满仅用于定位，无背景色块。
//
// 「去登录」复用仓内唯一登出入口 `auth.logout()`（清 Keychain + 清 UserDefaults 残留 +
// isLoggedIn=false），RootView 随即切到 `LoginView`——不新造第二套登录展示机制。
struct SessionExpiredBanner: View {
    @Environment(AuthStore.self) private var auth

    var body: some View {
        Group {
            if auth.sessionExpired {
                VStack(spacing: 0) {
                    card
                    Spacer(minLength: 0)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: auth.sessionExpired)
    }

    private var card: some View {
        HStack(spacing: Spacing.xl) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Typography.title))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("登录已过期，请重新登录")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("服务器已拒绝当前登录凭据，重新登录后可继续对话")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.md)
            Button {
                Haptics.tap()
                auth.logout()   // 仓内既有登出：清 token（Keychain+UserDefaults）→ RootView 切 LoginView
            } label: {
                Text("去登录")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("去登录")
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .glassListCard()   // 与列表卡同款（浅色白底 0.85 / 深色 ultraThinMaterial）
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.md)
    }
}
