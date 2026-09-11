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
    let text: String
    @State private var words: [BigBangWord] = []
    @State private var selected = Set<Int>()
    @State private var copied = false
    // v3.7.0：存备忘录反馈
    @State private var memoSaved = false

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
                        .font(.system(size: 20))
                    Text("大爆炸")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(fg)
                    Text("\(words.count) 个词块")
                        .font(.system(size: 12))
                        .foregroundStyle(fgDim)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(fgDim)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider().overlay((scheme == .dark ? Color.white : Color.black).opacity(0.15))

                // 词块区域（滚动）
                ScrollView {
                    FlowLayout(spacing: 8) {
                        ForEach(words) { w in
                            wordChip(w)
                        }
                    }
                    .padding(16)
                }

                // 底部操作栏
                VStack(spacing: 8) {
                    Divider().overlay((scheme == .dark ? Color.white : Color.black).opacity(0.15))
                    HStack(spacing: 12) {
                        Button {
                            selected = Set(words.map(\.id))
                        } label: {
                            Text("全选")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(fg)
                                .padding(.horizontal, 18).padding(.vertical, 9)
                                .background((scheme == .dark ? Color.white : Color.black).opacity(0.15), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button {
                            selected.removeAll()
                        } label: {
                            Text("清除")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(fg.opacity(0.7))
                                .padding(.horizontal, 18).padding(.vertical, 9)
                                .background((scheme == .dark ? Color.white : Color.black).opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        // v3.7.0：选中词块 → 存为一条备忘录（生活页「备忘录」栏目）
                        Button {
                            memoSelected()
                        } label: {
                            // v3.7.0：纯图标（底部条已有「全选/清除/复制(N)」，再加文字按钮在 SE 等窄屏会挤爆）
                            Image(systemName: memoSaved ? "checkmark" : "note.text")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(fg)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background((scheme == .dark ? Color.white : Color.black).opacity(0.15), in: Capsule())
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
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(fg)
                            .padding(.horizontal, 20).padding(.vertical, 9)
                            .background(Color.accentColor, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(selected.isEmpty)
                        .opacity(selected.isEmpty ? 0.5 : 1)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
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
            withAnimation(.spring(duration: 0.25, bounce: 0.3)) {
                if isOn { selected.remove(w.id) } else { selected.insert(w.id) }
            }
        } label: {
            Text(w.text)
                .font(.system(size: 15, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? .white : fg)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isOn ? Color.accentColor : (scheme == .dark ? Color.white : Color.black).opacity(0.13))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isOn ? Color.white.opacity(0.4) : (scheme == .dark ? Color.white : Color.black).opacity(0.08), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
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
