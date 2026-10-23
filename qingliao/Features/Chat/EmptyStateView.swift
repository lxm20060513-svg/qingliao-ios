import SwiftUI

// MARK: - v3.4.25 空态场景插画（会话搜索无结果 / 任务中心空态等复用）
// 轻量 SF Symbol 组合 + 主题渐变光晕，替代纯文字空态；不带动画守渲染红线。
//
// v4.0.150（用户 2026-10-23 拍板「空态换 ContentUnavailableView」）：
// 外壳改由系统 `ContentUnavailableView` 承载 —— 白拿系统排版（标题/描述/操作三段的
// 间距与对齐）、Dynamic Type 的 text style、VoiceOver 的「空状态」分组语义、深色与
// 大字体自适应。**插画与配色原样保留**（渐变光晕是本 App 的品牌语言，系统件只做布局，
// 不接管美术）。调用点零改动：对外 API（icon/title/subtitle/iconColors）未变。

struct EmptyStateView: View {
    let icon: String            // 主图标（如 magnifyingglass）
    let title: String           // 主文案（如 未找到相关会话）
    var subtitle: String? = nil // 次文案
    var iconColors: [Color] = [.blue, .indigo]   // 渐变配色（可按页面微调）

    private var gradient: LinearGradient {
        LinearGradient(colors: iconColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
                    .font(.system(size: Typography.body, weight: .semibold))
                    .foregroundStyle(.primary)
            } icon: {
                // 尺寸按系统空态图标的视觉重量收（原 110/40 → 88/38），
                // 否则自定义视图会把系统给 icon 的那一行撑高，整块空态下沉。
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: iconColors.map { $0.opacity(0.16) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 88, height: 88)
                        .blur(radius: 16)
                    Image(systemName: icon)
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(gradient)
                }
            }
        } description: {
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
