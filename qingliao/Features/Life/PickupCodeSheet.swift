//
//  PickupCodeSheet.swift
//  轻聊
//
//  v4.0.93：聊天首页「取件码」卡的弹窗 —— 站在快递柜前要一眼看清的一屏。
//
//  口径（用户原话：「点开弹窗取件码」+「卡片美化设计按取件码卡片优化」）：
//   · 大号**等宽**取件码（44pt，柜前光线差也看得清）+ 详情（快递公司 · 地点）+ 原文兜底；
//   · 「复制取件码」= 写剪贴板（柜机扫不了码时要手输 / 转发给家人）；
//   · 「已取件」= 勾掉那一条待办（走 TodoStore.toggleDone，落盘 + 既有同步通道）——
//     勾掉后卡面自动少一条，全取完就回到空态（不留假占位）。
//   · 数据源 = 本地 TodoStore，解析口径复用 PickupCodeKit（卡面与弹窗是同一份，绝不各写一套）。
//   · 一条都没有时不硬塞假的：给「怎么让取件码进来」的一句引导（快捷指令自动化链路）。
//
//  ⚠️ 卡面那套「恒单行 + 84pt 卡高」的约束不适用于这里（弹窗是滚动页，允许折行）；
//     但**号码恒单行**（.lineLimit(1) + minimumScaleFactor，长码缩字不折行）。
//

import SwiftUI
import UIKit

struct PickupCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    /// 刚复制过的那条（1.6s 后复位 → 胶囊文案变「已复制 ✓」）
    @State private var copiedId: String?

    /// 取件码清单 —— 读本地待办（未完成 + 能解出码的），与首页卡面同源
    private var items: [PickupCode] {
        // 顺序 = TodoStore.sorted（与卡面主码的「最新一条」同一口径；裸 todos 改过老待办后不重排）
        PickupCodeKit.list(TodoStore.shared.sorted.filter { !$0.done }
            .map { (id: $0.id, content: $0.content) })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.md) {
                    if items.isEmpty {
                        emptyCard
                    } else {
                        ForEach(items) { item in
                            codeCard(item)
                        }
                    }
                }
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.vertical, Spacing.lg)
            }
            .background(EnvironmentGradient.pageBase(scheme).ignoresSafeArea())
            .navigationTitle("取件码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 全仓口径（设置页间距真值表）：弹窗顶栏的「完成」一律放**左**（cancellationAction）
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - 单条取件码

    private func codeCard(_ item: PickupCode) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // 卡面同款「圆角多彩图标 + 小标」——跨页同一张脸（色值取单一真源 HomeCardLabels）
            HStack(spacing: Spacing.md) {
                Image(systemName: HomeCardLabels.icon(.pickup))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(HomeCardLabels.tint(.pickup),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("取件码")
                    .font(.system(size: Typography.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            // 号码是这一屏的主角：等宽 + 加字距，恒单行（放不下缩字号，不折行）
            Text(item.code)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)

            if !item.subLine.isEmpty {
                Text(item.subLine)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: Spacing.lg) {
                Button { copy(item) } label: {
                    Text(copiedId == item.id ? "已复制 ✓" : "复制取件码")
                        .frame(maxWidth: .infinity)
                        .pill(.primary)
                }
                .buttonStyle(PressStyle())

                Button { markPicked(item) } label: {
                    Text("已取件")
                        .frame(maxWidth: .infinity)
                        .pill(.primary, tone: .neutral)
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(Spacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedCard(cornerRadius: Radius.card)
    }

    // MARK: - 空态

    /// 没有取件码时不硬塞假的：说清怎么让取件码进来（v4.0.92 打通的自动化链路）。
    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("还没有取件码")
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.primary)
            Text("收到含「取件码」的短信会自动进来：在「快捷指令」里建一条自动化（收到短信 · 短信包含「取件码」）→ 动作选轻聊的「记到轻聊待办」。也可以直接对我说「记一下取件码 A1234」。")
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedCard(cornerRadius: Radius.card)
    }

    // MARK: - 动作

    private func copy(_ item: PickupCode) {
        UIPasteboard.general.string = item.code
        Haptics.success()
        withAnimation(Motion.snap) { copiedId = item.id }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard copiedId == item.id else { return }
            withAnimation(Motion.snap) { copiedId = nil }
        }
    }

    /// 已取件 = 勾掉来源待办（待办是唯一真源，卡面/清单都跟着它走）
    private func markPicked(_ item: PickupCode) {
        guard let todo = TodoStore.shared.todos.first(where: { $0.id == item.todoId }) else {
            Haptics.error()
            return
        }
        TodoStore.shared.toggleDone(todo)
        Haptics.success()
    }
}
