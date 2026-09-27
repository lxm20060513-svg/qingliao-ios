import SwiftUI

// MARK: - v2.0.96c 发牌弹出附件按钮（onAppear stagger：依次从底部弹出 + 回弹）

struct DealAttachmentButton: View {
    let icon: String
    let name: String
    let color: Color
    let idx: Int
    let onPick: () -> Void
    @State var appeared = false

    var body: some View {
        Button(action: onPick) {
            VStack(spacing: Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: Typography.headline))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                Text(name)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 34)
        .rotationEffect(.degrees(appeared ? 0 : -10))
        .scaleEffect(appeared ? 1 : 0.5)
        .onAppear {
            // v2.0.98：插入帧 withAnimation 的 .delay 会被父级 transition 动画吞掉（实测发牌不生效）
            //          → 改 Task.sleep 真延迟逐张弹出
            Task {
                try? await Task.sleep(for: .seconds(Double(idx) * 0.07))
                // v3.9.19：**有意不入 Motion 令牌**——发牌要明显回弹（bounce 0.35 强于 emerge 的 0.08），
                // 映射过去会削掉发牌手感（用户 2026-09-14 确认保留原值，勿按统一口径回改）
                withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
                    appeared = true
                }
            }
        }
    }
}
