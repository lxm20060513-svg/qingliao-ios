import SwiftUI

/// v3.0.74：钉一钉长卡片组件 —— 对齐看板卡片风格（门锁卡同款：标题左上 + 内容靠左 + 右上小胶囊）
struct PinCard: View {
    let pin: PinItem
    var onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题行：时间 + 来源标签 + 删除按钮
            HStack {
                Text(pin.timeText)
                    .font(.system(size: Typography.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                if !pin.sourceLabel.isEmpty {
                    Text(pin.sourceLabel)
                        .font(.system(size: Typography.tiny))
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxs)
                        .background(Color.accentColor.opacity(Tint.faint), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                if let onDelete {
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: Typography.body))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 内容
            Text(pin.preview)
                .font(.system(size: Typography.subhead))
                .lineSpacing(LineSpacing.compact)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()   // v3.9.34 收口：原手搓 inset(12) 卡底并入全站卡口径（16 + Tint.line + 柔影）
        .contextMenu {
            Button {
                UIPasteboard.general.string = pin.content
            } label: {
                Label("复制内容", systemImage: "doc.on.doc")
            }
            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }
}
