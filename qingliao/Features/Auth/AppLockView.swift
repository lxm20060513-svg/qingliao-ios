import SwiftUI
import LocalAuthentication

// MARK: - v2.0.92 App 锁（启动时 Face ID 验证遮罩，复用 Face ID 登录的验证模式）

struct AppLockView: View {
    let onUnlock: () -> Void
    @State private var verifying = false
    @State private var failed = false

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
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(verifying)

                if failed {
                    Text("验证失败，请重试")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.red)
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
        guard !verifying else { return }
        verifying = true
        failed = false
        let context = LAContext()
        context.localizedReason = "解锁轻聊"
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
