import SwiftUI

/// 待做池⑥：聊天页输入区上方的「队列总览」条 —— 排队消息逐条带序号（在等什么、排第几）。
///
/// 口径（台账）：此前排队消息只在气泡上顶一枚「排队中」角标，看不到队列全貌。
/// 本视图挂在 `ChatView.chatRecordBarSlot`（与记账条 / 去重条 / 记忆条**同一槽位、互斥**），
/// 承载：顶部摘要 + 逐条序号清单 + 一键全清。
struct SendQueueBar: View {
    let rows: [SendQueueOverview.Row]
    /// 宿主实现：清空排队队列（与输入栏「停止」同口径）
    var onClearAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "clock.badge")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(Color.accentColor)
                Text(SendQueueOverview.summary(rows.count) ?? "")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onClearAll) {
                    Text("全部清空").pill(.topBar, tone: .danger)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("清空全部排队消息")
            }
            ForEach(rows) { r in
                HStack(spacing: Spacing.sm) {
                    Text("\(r.position).")
                        .font(.system(size: Typography.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(r.text)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if r.hasImage {
                        Image(systemName: "photo")
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 玻璃口径：与记账条/记忆条/意图动作条同档（dashboardCard）
        .dashboardCard()
        .padding(.horizontal, Spacing.section)
        .transition(.opacity)
    }
}
