import SwiftUI

// MARK: - v3.9.0 轻量骨架屏（首屏加载占位）
//
// 为什么加：原来首次加载只有「转圈」或空白，观感是"还没开始"，骨架屏能预示"内容马上出现在这里"。
//
// 设计约束（贴合本 App 既有约定）：
//   · **只用于首次加载**（`loading && 内容为空`）；失败/未接线仍走原来的小字降级——"不空白、不转圈卡住"不变
//   · 呼吸用 opacity 循环（GPU 合成，无每帧布局）；**不用 TimelineView(.animation)**，避免吃帧预算
//   · 尊重「减弱动态效果」辅助功能：开启时静态灰块（不做呼吸）
//   · 卡片圆角/描边复用 `.dashboardCard()`（16），与真实卡片同形，插入真内容时不跳版

/// 骨架屏基础块：占位灰块 + 呼吸
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 10
    var cornerRadius: CGFloat = 5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(dim ? 0.11 : 0.05))
            .frame(width: width, height: height)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                       value: dim)
            .onAppear { if !reduceMotion { dim = true } }
    }
}

/// 卡片骨架容器：内容放若干 `SkeletonBlock`，外观与 `.dashboardCard()` 一致（圆角 16 + 0.8pt 描边）
struct SkeletonCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }
}

/// 列表行骨架（会话列表 / 容器列表这类「头像 + 两行文字」的行）
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 10) {
            SkeletonBlock(width: 30, height: 30, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(width: 116, height: 11)
                SkeletonBlock(width: 188, height: 10)
            }
            Spacer(minLength: 0)
        }
    }
}
