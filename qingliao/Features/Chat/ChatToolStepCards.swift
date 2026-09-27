import SwiftUI

struct ToolStepRow: View {
    let title: String
    let running: Bool
    /// v3.9.17：流被中止/报错时这些工具并没有确认跑完 → 用「未确认」图标而不是绿勾
    /// （否则用户点了停止，卡里每个工具都显示已完成，语义不实）
    var unresolved: Bool = false
    /// v3.9.58：completed 行的耗时秒数（nil=后端无数据/未收口，不显示）
    var duration: Double? = nil
    /// v3.9.58：running 行的已等待秒数（nil=不显示；由调用方每秒刷新驱动）
    var elapsed: Int? = nil
    /// v3.9.58b：重新生成回调（nil=不显示按钮；仅 unresolved 且是最后一步时传入）
    var onRetry: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 8) {
            if running {
                ProgressView().controlSize(.mini)
            } else if unresolved {
                Image(systemName: "circle.dashed")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.green)
            }
            Text(running ? "正在\(title)…" : title)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if running, let e = elapsed {
                Text("已等 \(e)s")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            } else if !running, let d = duration {
                Text(d < 10 ? String(format: "%.1fs", d) : "\(Int(d.rounded()))s")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if unresolved, let onRetry {
                Button(action: onRetry) {
                    Label("重新生成", systemImage: "arrow.clockwise")
                        .font(.system(size: Typography.caption, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.xxs)
                        .background(Color.accentColor.opacity(Tint.subtle), in: Capsule())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("重新生成回复")
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                .strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8)
        )
    }
}

/// v3.9.80：工具明细被裁时的提示行（「更早的 N 步未列出」）。
/// 单独抽成 struct 而不是内联在 toolStepCards 里：那处是本文件最深的 ViewBuilder
/// （TimelineView → VStack），内联插值 Text 在 CI 上踩过
/// 「Unable to type-check this expression in reasonable time」（同一处 224 行附近的同类抽法）。
struct ToolStepsTruncationNote: View {
    /// 被裁掉的步数（toolSteps − 明细条数）
    let hidden: Int
    /// 明细里保留的步数
    let shown: Int

    var body: some View {
        Text("更早的 \(hidden) 步未列出（只留最近 \(shown) 步）")
            .font(.system(size: Typography.caption))
            .foregroundStyle(.tertiary)
    }
}

/// v3.9.81：工具卡摘要行**下面**那行进度小字——与任务中心「进行中」卡片同一口径
/// （`第 N 步 工具 · N 字 · 静默 X · 最近：…`，文案与算式全在 `StreamProgressText`，这里只管样子）。
///
/// 用户 2026-09-27 真机要求：任务中心能看到「跑到哪了」，聊天页也要同步显示同一行小字（也是小字）。
/// 抽成独立 struct 而不是内联进 `toolStepCards`：那处 ViewBuilder 已经很深，内联插值在 CI 上踩过
/// 「Unable to type-check this expression in reasonable time」（本文件多处同类抽法）。
struct ToolProgressNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: Typography.caption))
            .foregroundStyle(.tertiary)
            // 允许两行：整行约 100 字（含「最近：」尾部 40 字），单行会把最有用的尾部截掉
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 左内嵌与摘要行卡内文字对齐（外层 toolStepCards 已有 44 的 AI 头像位）
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.xs)
            .accessibilityLabel("AI 进度：\(text)")
    }
}

/// v3.9.14：工具进度卡**答完后收起**成的那一行（用户反馈：这些别答完还一直摊在对话里）。
/// 生成中仍然逐条展开（能看到 AI 正在干什么），答完折叠成「N 步工具调用」，点开可看明细。
/// 抽成独立 struct 而不是塞进 toolStepCards —— 本仓 CI 反复踩过 body 过大导致的
/// 「Unable to type-check this expression in reasonable time」。
struct ToolStepsSummaryRow: View {
    let count: Int
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                Text("\(count) 步工具调用")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                    .strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}
