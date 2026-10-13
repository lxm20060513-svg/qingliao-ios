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
        // v4.0.105：系统 .contextMenu → 全局同款锚定胶囊菜单（微缩抬起 + 轻纱模糊变暗 + 弹簧错峰）
        .anchorLongPressMenu(items: pinCardMenuList(canDelete: onDelete != nil), title: "钉一钉") { item in
            switch item.id {
            case "copy":
                UIPasteboard.general.string = pin.content
            case "delete":
                if let onDelete { onDelete() }
            default:
                break
            }
        }
    }
}

// MARK: - v4.0.105 钉一钉卡长按菜单项（系统 .contextMenu → 全局锚定胶囊菜单）
//
// 项与图标语义逐条对齐原 `Button`：`复制内容` 常在；`删除` 只在宿主传了 onDelete 时出现
// （原 `if let onDelete` 条件项语义逐字对齐）。动作仍由调用点的 onPick 分发。
// 文件级函数默认非 MainActor 隔离 —— 这里只构造纯值，无需显式标注。

private func pinCardMenuList(canDelete: Bool) -> [AnchorMenuItem] {
    var items: [AnchorMenuItem] = [
        AnchorMenuItem(id: "copy", title: "复制内容", icon: "doc.on.doc"),
    ]
    if canDelete {
        items.append(AnchorMenuItem(id: "delete", title: "删除", icon: "trash", destructive: true))
    }
    return items
}
