// MARK: - 改口面板（v4.0.44 待做池 3：编辑已发消息 → 基于新原文重答）
//
// 用户拍板（2026-10-04 卡片）：
//   ① 被取代的旧回答 → 复用现有灰气泡（与「撤回」同款，最省事）
//   ② 只允许改**最后一条** user 消息（改动面最小）
// 本面板只负责「改原文」这一件事：判定与折叠/重答全在 MessageEditKit + ChatStore + ChatView.editMessage。
// 刻意不做「就地编辑气泡」：气泡正文是 UITextView（SelectableTextLabel），就地变可编辑会把
// 选区/长按菜单/自动滚动那一整套交互拖进来；面板改法与之等价且不碰在用链路。
import SwiftUI

struct MessageEditSheet: View {
    /// 原文（打开时预填，用户可改）
    var originalText: String
    /// 「保存并重答」回调（回传改后的原文；空/无变化由面板侧先挡住，宿主再兜一层）
    var onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 与原文一致 = 没什么可重答的 → 按钮置灰（改了个空格也算没改）
    private var canSubmit: Bool {
        !trimmed.isEmpty && trimmed != originalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    SectionHeader("改口重答")
                    card
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, Spacing.section)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)   // 不盖系统玻璃弹窗底（见 LiquidGlass.swift 决策）
            .navigationTitle("编辑消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 弹窗胶囊统一左位（与设置页口径一致）
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                if text.isEmpty { text = originalText }
                focused = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            TextField("消息内容", text: $text, axis: .vertical)
                .font(.system(size: Typography.body))
                .lineLimit(3...12)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
            Divider()
            // 说明白会发生什么（用户拍板的两条都在这一行里）
            Text("保存后会基于新内容重新回答；原回答折叠成「已修改」，不再参与对话上下文。")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
            HStack(spacing: Spacing.lg) {
                Button {
                    onSubmit(trimmed)
                    dismiss()
                } label: {
                    Text("保存并重答").pill(.primary, tone: .accent)
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.45)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.xxl)
        .glassListCard()
    }
}
