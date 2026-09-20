import SwiftUI
import LocalAuthentication

// MARK: - v2.0.92 App 锁（启动时 Face ID 验证遮罩，复用 Face ID 登录的验证模式）

struct AppLockView: View {
    let onUnlock: () -> Void
    @State private var verifying = false
    @State private var failed = false
    // v3.9.41（SR43）：兜底出口。设备没设锁屏密码（或被恢复到无面容的新设备）时
    // evaluatePolicy 恒失败，而「App 锁」开关在锁内改不到 → 原先只能删 App 重装丢本地数据。
    @State private var policyUnavailable = false
    @AppStorage("qingliao_app_lock") private var appLockOn = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("轻聊已锁定")
                    .font(.system(size: Typography.headline, weight: .bold))
                Text("验证 Face ID 后进入")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)

                Button {
                    verify()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "faceid")
                            .font(.system(size: Typography.title))
                        Text(verifying ? "验证中..." : "Face ID 解锁")
                            .font(.system(size: Typography.body, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: 220)
                    .padding(.vertical, Spacing.xl)
                    .background(
                        LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(verifying)

                if failed {
                    Text("验证失败，请重试")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.red)
                }
                if policyUnavailable {
                    Text("本机未设置锁屏密码，系统无法进行身份验证。\n点「继续」将关闭 App 锁进入。")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                    Button {
                        appLockOn = false
                        onUnlock()
                    } label: {
                        Text("继续（关闭 App 锁）")
                            .font(.system(size: Typography.body, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, Spacing.xxl)
                            .padding(.vertical, Spacing.lg)
                            .background(Color.orange,
                                        in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(28)
        }
        .onAppear {
            // 进入锁屏自动发起验证（免点按钮）
            Task { try? await Task.sleep(for: .seconds(0.4)); verify() }
        }
    }

    private func verify() {
        guard !verifying, !policyUnavailable else { return }
        verifying = true
        failed = false
        let context = LAContext()
        context.localizedReason = "解锁轻聊"
        // v3.9.41（SR43）：先探测可用性——不可用（无锁屏密码等）时给出出口，而不是恒失败把用户锁死
        var policyError: NSError?
        if !context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) {
            verifying = false
            policyUnavailable = true
            NSLog("[APPLOCK] 生物/密码验证不可用：%@", policyError?.localizedDescription ?? "-")
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "解锁轻聊") { success, _ in
            DispatchQueue.main.async {
                verifying = false
                if success {
                    onUnlock()
                } else {
                    failed = true
                }
            }
        }
    }
}
