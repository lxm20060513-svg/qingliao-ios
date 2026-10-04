import SwiftUI
import UIKit

/// 待做池第 8 项：链接预览卡片（微信式）。
///
/// 挂在消息行下方（`ChatView.linkPreviewRow`）。职责单一：把 `LinkPreviewKit.LinkPreview`
/// 画成一张卡 —— 标题 / 摘要 / 站点名 +（有则）右侧缩略图。
///
/// 口径：
///  · 缩略图用 `AsyncImage` **按 URL 自行加载**（后端不做压缩：容器无 PIL）；加载不到就**静默无图**
///    （卡片仍显示标题 + 摘要 = 无图降级形态，对应台账护栏）；
///  · 点卡片 = 打开链接；右上「×」= 关闭（用户手动关，之后不再抓）；
///  · 长按卡 = 上下文菜单「重新抓取预览」（单独重抓）；抓取失败时**整张行不渲染**，故这里只管成功态。
struct LinkPreviewCard: View {
    let preview: LinkPreviewKit.LinkPreview
    let onDismiss: () -> Void
    let onRelink: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                cardBody
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(2)
            .accessibilityLabel("关闭链接预览")
        }
        .contextMenu {
            Button { onRelink() } label: {
                Label("重新抓取预览", systemImage: "arrow.triangle.2.circlepath")
            }
            Button(role: .destructive) { onDismiss() } label: {
                Label("关闭预览", systemImage: "xmark")
            }
        }
    }

    private var cardBody: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(preview.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !preview.desc.isEmpty {
                    Text(preview.desc)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if !siteLabel.isEmpty {
                    Text(siteLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if preview.hasImage, let u = URL(string: preview.image) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        // 加载中/失败 → 无图降级（不占位、不显示破图）
                        Color.clear
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(10)
        .frame(maxWidth: 300, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var siteLabel: String { LinkPreviewKit.hostLabel(of: preview) }

    private func open() {
        if let u = URL(string: preview.url), !preview.url.isEmpty {
            UIApplication.shared.open(u)
        }
    }
}
