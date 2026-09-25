import SwiftUI
import UIKit

// MARK: - v3.9.82 译文弹窗（用户 2026-09-25 拍板：「这个卡片改弹窗吧，跟 AI 速记弹窗一致」）
//
// 参照物 = `QuickCaptureSheet`（Features/OrbQuickMenu.swift）——本文件形态**照它抄**，逐条对齐（改前先对一眼那边）：
//   · 内容层级：标题行（彩色图标 + `Typography.headline` 粗体）→ 正文 → 沉底按钮行（左次操作 + 右主操作）
//   · 边距口径：`.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)` + `.padding(Spacing.section)`
//     —— 内容贴顶、`Spacer` 把按钮压到底；大 detent 下同样成立（内容撑满即可）
//   · 档位：`.presentationDetents([.medium, .large])`（与全站输入弹窗 MemoSection / TodoSection / QuickReminderSheet 同档）
//   · 背景：**不覆盖**，交给 iOS 26 系统默认玻璃底（全站口径）
//
// 被它取代的旧形态 = 浮在球上方的一张玻璃卡（原 `OrbIdentifyOverlay.translatedCard`：圆角 22 + 译文限高 220）：
//   用户反馈「太别扭」—— 卡小、四周一大片虚化留白、长译文只能卡内滚动。
//   译文所在的那套（限高 / 复制反馈 / 三颗按钮）随本文件搬走，**识别浮层里不再渲染译文**。

/// 「译文 · 翻成 X」弹窗的数据（`Identifiable` 供宿主 `.sheet(item:)` 用）
struct TranslateResult: Identifiable, Equatable {
    let id = UUID()
    let source: String
    let text: String
}

struct TranslateSheet: View {
    let result: TranslateResult
    /// 「发给 AI」交回宿主（宿主 post `.qingliaoTaskSend` + 切聊天页 —— 与识别动作条**同一条通道**）
    var onAskAI: (String) -> Void
    /// 「换一张」交回宿主（宿主关掉本弹窗后重开识别浮层，并以**翻译模式**起手）
    var onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// 「复制译文」的即时反馈（1.6s 后自动收回，不留假的「已复制」—— 沿用原浮层卡片那版口径）
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "character.book.closed")
                    .foregroundStyle(Color.accentColor)
                Text("译文 · 翻成\(TranslateKit.targetLabel(for: result.source))")
                    .font(.system(size: Typography.headline, weight: .bold))
                Spacer(minLength: 0)
            }
            // 原文留 2 行小字便于核对翻对没 —— 只有译文用户没法验（原卡留 3 行，弹窗里收成 2 行）
            Text(result.source)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            // 译文区：占满标题与按钮之间的全部高度（原卡是限高 220）。外套一张玻璃卡
            // （`Radius.card`(16)，与速记的输入卡同档）—— 长译文在卡内滚动。
            ScrollView {
                Text(result.text)
                    .font(.system(size: Typography.body))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .padding(Spacing.xl)
            .overlayGlassCard(cornerRadius: Radius.card)
            .frame(maxHeight: .infinity)
            HStack(spacing: Spacing.lg) {
                Button("关闭") { dismiss() }
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { copy() } label: {
                    Text(copied ? "已复制" : "复制").pill(.primary, tone: .accent)
                }
                // 先收弹窗再重开浮层（仓里的规则：开下一个 presentation 前先收上一个）
                Button { dismiss(); onRetry() } label: {
                    Text("换一张").pill(.primary, tone: .neutral)
                }
                Button { onAskAI(TranslateKit.prompt(for: result.source)); dismiss() } label: {
                    Text("发给 AI").pill(.primary, tone: .neutral)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(Spacing.section)
        .presentationDetents([.medium, .large])
    }

    private func copy() {
        UIPasteboard.general.string = result.text
        copied = true
        Haptics.success()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}
