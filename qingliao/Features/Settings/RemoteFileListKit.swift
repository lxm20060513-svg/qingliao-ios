import SwiftUI

// MARK: - 远端文件列表的公共 UI 件（v4.0.86 瘦身③：单一真源）
//
// 背景（瘦身盘点 2026-10-09）：SettingsData.swift（云盘上传目录页）与
// CloudDriveBrowserSheet.swift（网盘浏览页）是同一代「远端文件列表」的两份实现，
// 其中以下四个小组件**逐字同构**（只差文案），共 ~90 行重复：
//   · busyCard        ← 「ProgressView + 文本」横向小卡
//   · loadingView     ← 「加载中…」整块加载态
//   · refreshFailedNotice ← 列表已有内容时顶部「刷新失败 + 重试」提示条
//   · emptyView 骨架  ← tray 图标 + 主副文案空态（文案不同 → 参数化 title/subtitle）
//
// 口径（沿用 LifeSectionScaffold）：只收「去掉标识符后逐字相同」的部分；
// headerCard / entryList / entryRow 各页差异大，不收。
// errorView 两边都已收口到 ErrorStateView，无需再动。

/// 「进行中」横向小卡：转圈 + 文本（`busyText != nil` 时挂在列表上方）
struct RemoteBusyCard: View {
    let text: String
    var body: some View {
        HStack(spacing: Spacing.md) {
            ProgressView().tint(.secondary)
            Text(text).font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .pastelCard()
    }
}

/// 整块加载态：转圈 + 「加载中…」（列表尚无内容时）
struct RemoteLoadingView: View {
    var text: String = "加载中…"
    var body: some View {
        HStack(spacing: Spacing.md) {
            ProgressView().tint(.secondary)
            Text(text).font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// 刷新失败轻提示：列表已有内容时的降级形态，不吞掉已加载的列表（v3.9.38 口径）
struct RemoteRefreshFailedNotice: View {
    let message: String
    var title: String = "刷新失败"
    let onRetry: () -> Void
    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title).font(.system(size: Typography.subhead, weight: .semibold))
                Text(message)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Spacing.xs)
            Button {
                Haptics.tap()
                onRetry()
            } label: {
                Text("重试").pill(.primary, tone: .accent)
            }
            .buttonStyle(PressStyle(scale: 0.96))
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .pastelCard()
    }
}

/// 空态：tray 图标 + 主/副文案（`subtitle` 可带 \n，居中）
struct RemoteEmptyView: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "tray")
                .font(.system(size: Typography.display))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: Typography.body, weight: .medium))
            Text(subtitle)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, Spacing.xxl)
        .pastelCard()
    }
}
