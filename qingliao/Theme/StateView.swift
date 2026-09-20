// MARK: - v3.9.42 首屏三态统一（loading / error）
//
// 背景：同一件"这一屏还没内容"的事，仓内有两套方言且各写一遍：
//   · 转圈派 —— 9 处首屏 `ProgressView().tint(.secondary)`（任务/日志/凭据/MCP/模型/设备）
//   · 骨架派 —— 5 处手写 `ForEach(0..<n) { SkeletonRow() }`（DockerSheet、SessionsView…）
// 错误态更散：SettingsModelSheets 里同一段"加载失败 + 重试"抄了两份，FilesManagerSheet 又是第三种写法。
//
// 口径：
//   · **列表结构可预测 → 骨架**（预示"内容马上出现在这里"，且插入真内容不跳版）
//   · **结构不可预测（网格/分组/混合）→ 收口转圈**，别硬编骨架骗人
//   · 只统一**首屏/分区加载**。27 处"操作进行中"的行内转圈（保存按钮、ping、刷新）不套本组件——
//     那类要的是"原地 14pt 小转圈"，换成骨架会把按钮撑跑。
//   · 空态一律用既有 `EmptyStateView`，本文件不重复实现。
//   · 呼吸/动态由 `SkeletonBlock` 内部尊重「减弱动态效果」，此处不再判。

import SwiftUI

// MARK: - 加载态

/// 首屏/分区加载占位。用法：`if loading { LoadingStateView(shape: .rows(3)) }`
struct LoadingStateView: View {
    /// 占位形态（命名不叫 Shape：避免遮蔽 SwiftUI.Shape 协议）
    enum LoadingShape {
        /// 列表：n 行「头像 + 两行文字」骨架（与 SkeletonRow 同形）
        case rows(Int)
        /// 结构不可预测（网格 / 分组 / 混合）→ 居中转圈，可选文案
        case spinner(text: String? = nil)
    }

    var shape: LoadingShape = .spinner()
    /// 骨架行左右留白：Form/List 内传 0（系统已缩进），裸 VStack 里用 Spacing.xxl
    var horizontalPadding: CGFloat = Spacing.xxl

    // 显式 @ViewBuilder：body 里有 switch 分支（协议默认已是 @ViewBuilder，这里不省略，
    // 免得 CI 端 Swift 6 类型检查在 builder 推断上出意外）
    @ViewBuilder
    var body: some View {
        switch shape {
        case .rows(let count):
            // 行距 14 / 左右 14 = SessionsView 首屏骨架（v3.9.0）的既有观感，收口为默认档
            VStack(spacing: Spacing.xxl) {
                ForEach(0..<max(count, 1), id: \.self) { _ in SkeletonRow() }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .spinner(let text):
            VStack(spacing: Spacing.md) {
                ProgressView().tint(.secondary)
                if let text {
                    Text(text)
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.section)
        }
    }
}

// MARK: - 错误态

/// 整块加载失败 + 重试。与 FilesManagerSheet 既有形态同参数（图标 headline 橙 / 标题 body semibold / 详情 caption）。
///
/// 不含背景：需要卡片观感时由调用方加 `.glassListCard()`（Form/List 里加卡会双重容器）。
struct ErrorStateView: View {
    var icon: String = "exclamationmark.triangle.fill"
    let title: String
    var detail: String? = nil
    /// 重试动作；传 nil 则只显示文案（后端未配置那类"重试无用"的场景）
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: Typography.headline))
                .foregroundStyle(retry == nil ? Color.secondary : Color.orange)
            Text(title)
                .font(.system(size: Typography.body, weight: .semibold))
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let retry {
                Button {
                    Haptics.tap()
                    retry()
                } label: {
                    Text("重试").pill(.primary, tone: .accent)
                }
                .buttonStyle(PressStyle(scale: 0.96))
                .padding(.top, Spacing.xs)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        // 30 = 三处原实现（FilesManagerSheet / 两处模型列表）共同用的旧值，收口时保持观感不变
        .padding(.vertical, 30)
    }
}
