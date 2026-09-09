import SwiftUI

// MARK: - v3.4.25 空态场景插画（会话搜索无结果 / 任务中心空态等复用）
// 轻量 SF Symbol 组合 + 主题渐变光晕，替代纯文字空态；不带动画守渲染红线。

struct EmptyStateView: View {
    let icon: String            // 主图标（如 magnifyingglass）
    let title: String           // 主文案（如 未找到相关会话）
    var subtitle: String? = nil // 次文案
    var iconColors: [Color] = [.blue, .indigo]   // 渐变配色（可按页面微调）

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                // 底部光晕（与 Splash/欢迎页同语言）
                Circle()
                    .fill(LinearGradient(colors: iconColors.map { $0.opacity(0.16) },
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 110, height: 110)
                    .blur(radius: 18)
                // 主图标
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(
                        LinearGradient(colors: iconColors,
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
