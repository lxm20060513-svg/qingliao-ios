import SwiftUI

// MARK: - BigBang 大爆炸视图（复刻锤子交互：文字炸开成词块，点选复制）

/// 词块流式换行布局（SwiftUI 无内置 FlowLayout，自实现 iOS16+ Layout）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct BigBangView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme   // v2.0.86q：主题磨砂玻璃背景
    @Environment(AuthStore.self) private var auth
    let text: String
    // v3.9.71 输入收口：识别结果里「问 AI」的出口。
    // 聊天页承载时传真实发送回调；生活页没有聊天上下文，不传 → 退化为「复制 + 提示去聊天页粘贴」。
    var onAskAI: ((String) -> Void)? = nil
    @State private var words: [BigBangWord] = []
    @State private var selected = Set<Int>()
    @State private var copied = false
    // v3.7.0：存备忘录反馈
    @State private var memoSaved = false
    // v3.9.71：识别结果（动作条数据源）+ 无聊天上下文时的兜底提示
    @State private var intent: RecognizedIntent?
    @State private var askAIFallbackHint = false

    /// v2.0.86q：前景色跟随主题（亮玻璃用深字，深玻璃用白字）
    private var fg: Color { scheme == .dark ? .white : Color.black.opacity(0.8) }
    private var fgDim: Color { scheme == .dark ? .white.opacity(0.5) : Color.black.opacity(0.45) }

    var body: some View {
        ZStack {
            // v2.0.86q：磨砂玻璃背景跟随主题（白天亮磨砂 / 晚上深色磨砂）
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

            VStack(spacing: 0) {
                // 头部
                HStack(spacing: 10) {
                    Text("💥")
                        .font(.system(size: Typography.headline))
                    Text("大爆炸")
                        .font(.system(size: Typography.title, weight: .bold))
                        .foregroundStyle(fg)
                    Text("\(words.count) 个词块")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(fgDim)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: Typography.titleXL))
                            .foregroundStyle(fgDim)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, Spacing.section)
                .padding(.bottom, Spacing.xl)

                Divider().overlay((scheme == .dark ? Color.white : Color.black).opacity(Tint.soft))

                // 词块区域（滚动）
                ScrollView {
                    FlowLayout(spacing: 8) {
                        ForEach(words) { w in
                            wordChip(w)
                        }
                    }
                    .padding(Spacing.section)
                }

                // 底部操作栏
                VStack(spacing: 8) {
                    // v3.9.71：识别结果动作条（有结果才占位）
                    if let result = intent {
                        IntentActionBar(intent: result,
                                        onAskAI: { t in
                                            if let onAskAI {
                                                onAskAI(t)
                                                dismiss()
                                            } else {
                                                // 生活页没有聊天上下文：复制 + 明说下一步去哪
                                                UIPasteboard.general.string = t
                                                withAnimation { askAIFallbackHint = true }
                                            }
                                        },
                                        onClose: { withAnimation { intent = nil } })
                            .padding(.horizontal, 12)
                    }
                    if askAIFallbackHint {
                        Text("已复制，回聊天页粘贴即可提问")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(fgDim)
                            .padding(.top, Spacing.xs)
                    }
                    Divider().overlay((scheme == .dark ? Color.white : Color.black).opacity(Tint.soft))
                    HStack(spacing: 12) {
                        Button {
                            selected = Set(words.map(\.id))
                        } label: {
                            Text("全选")
                                .font(.system(size: Typography.body, weight: .semibold))
                                .foregroundStyle(fg)
                                .padding(.horizontal, 18).padding(.vertical, Spacing.md)
                                .background((scheme == .dark ? Color.white : Color.black).opacity(Tint.soft), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button {
                            selected.removeAll()
                        } label: {
                            Text("清除")
                                .font(.system(size: Typography.body, weight: .semibold))
                                .foregroundStyle(fg.opacity(0.7))
                                .padding(.horizontal, 18).padding(.vertical, Spacing.md)
                                .background((scheme == .dark ? Color.white : Color.black).opacity(Tint.faint), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        // v3.9.71：选中词块 → 识别类型 → 一键执行（记一笔/加待办/建提醒/存知识库…）
                        Button {
                            recognizeSelected()
                        } label: {
                            Image(systemName: intent == nil ? "sparkles" : "sparkles.rectangle.stack")
                                .font(.system(size: Typography.body, weight: .semibold))
                                .foregroundStyle(fg)
                                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.md)
                                .background((scheme == .dark ? Color.white : Color.black).opacity(Tint.soft), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(selected.isEmpty)
                        .opacity(selected.isEmpty ? 0.5 : 1)
                        .accessibilityLabel("识别选中内容")
                        // v3.7.0：选中词块 → 存为一条备忘录（生活页「备忘录」栏目）
                        Button {
                            memoSelected()
                        } label: {
                            // v3.7.0：纯图标（底部条已有「全选/清除/复制(N)」，再加文字按钮在 SE 等窄屏会挤爆）
                            Image(systemName: memoSaved ? "checkmark" : "note.text")
                                .font(.system(size: Typography.body, weight: .semibold))
                                .foregroundStyle(fg)
                                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.md)
                                .background((scheme == .dark ? Color.white : Color.black).opacity(Tint.soft), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(selected.isEmpty)
                        .opacity(selected.isEmpty ? 0.5 : 1)
                        .accessibilityLabel("存备忘录")
                        Button {
                            copySelected()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "已复制" : "复制 (\(selected.count))")
                            }
                            .font(.system(size: Typography.body, weight: .semibold))
                            .frame(minWidth: 120)
                            .pill(.primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(selected.isEmpty)
                        .opacity(selected.isEmpty ? 0.5 : 1)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, Spacing.lg)
                }
            }
        }
        .onAppear {
            words = BigBangParser.tokenize(text)
        }
    }

    /// 词块：点选切换选中（蓝色高亮 + 缩放动效）
    private func wordChip(_ w: BigBangWord) -> some View {
        let isOn = selected.contains(w.id)
        return Button {
            withAnimation(Motion.snap) {   // v3.9.0：动效令牌收口（原 spring 0.25/0.3）
                if isOn { selected.remove(w.id) } else { selected.insert(w.id) }
            }
        } label: {
            Text(w.text)
                .font(.system(size: Typography.body, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? .white : fg)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Radius.icon, style: .continuous)
                        .fill(isOn ? Color.accentColor : (scheme == .dark ? Color.white : Color.black).opacity(Tint.subtle))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.icon, style: .continuous)
                        .strokeBorder(isOn ? Color.white.opacity(0.4) : (scheme == .dark ? Color.white : Color.black).opacity(Tint.faint), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
    }

    /// v3.9.71：选中的词块拼回文本（与复制/存备忘录同口径：按词块顺序拼）
    private var selectedText: String {
        words.filter { selected.contains($0.id) }.sorted { $0.id < $1.id }.map(\.text).joined()
    }

    /// v3.9.71：选中内容 → 意图管道（本机规则优先，再端侧/云端）→ 动作条
    private func recognizeSelected() {
        let t = selectedText
        guard !t.isEmpty else { return }
        Task {
            // 先把结果 await 出来，再进 withAnimation（同步闭包，里面不能有 await——Swift 6 编译错误）
            let r = await IntentExtractor.extract(text: t, auth: auth)
            withAnimation(Motion.settle) { intent = r }
        }
    }

    /// v3.7.0：把选中的词块拼成一条备忘录（生活页「备忘录」栏目）
    private func memoSelected() {
        let sorted = words.filter { selected.contains($0.id) }.sorted { $0.id < $1.id }
        let joined = sorted.map { $0.text }.joined()
        guard !joined.isEmpty else { return }
        if MemoStore.shared.add(content: joined, source: "bigbang") {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation { memoSaved = true }
        }
    }

    private func copySelected() {
        let sorted = words.filter { selected.contains($0.id) }.sorted { $0.id < $1.id }
        let joined = sorted.map(\.text).joined()
        guard !joined.isEmpty else { return }
        UIPasteboard.general.string = joined
        withAnimation { copied = true }
        Task { try? await Task.sleep(for: .seconds(1.2)); dismiss() }
    }
}
