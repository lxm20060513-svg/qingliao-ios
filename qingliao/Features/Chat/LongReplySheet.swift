// MARK: - v3.9.86 长回复阅读 sheet（功能 4 · B 方案：半屏 sheet 放大，沿用现有 detent）
//
// 为什么是 sheet 不是全屏：现有全屏宿主是「大爆炸」(`fullScreenCover`)，复用它就得和
// zoom 转场源 id 体系耦合，风险高；半屏 sheet 直接挂在 ChatView 的 `.sheet` 修饰符上，
// 与 Hermes 捷径/章节列表/模型快选同档 `[.medium, .large]`，**不新增宿主、不动任何互斥关系**。
// 代价：长文最高只有 large 档（约屏高 92%），但比气泡（369pt 宽 + 头像列）宽得多，通栏读感差别明显。
//
// 复用（刻意不新建渲染链路，避免两套 markdown/行距口径漂移）：
//   · 正文逐章走 `SelectableTextLabel`（与气泡同一套 UITextView 渲染 + 设置里的字号行距 + 高度缓存）
//   · 章节切分走 `MarkdownRenderer.extractHeaders`（与「章节列表」同一真源）
//   · 朗读走 `SpeechManager.shared`；存便签走 `MemoStore.shared`；分享走现成 ActivityShareSheet
import SwiftUI

/// 长回复阅读载荷（`.sheet(item:)` 需要 Identifiable）
struct LongReplyPayload: Identifiable {
    let id: String
    let text: String
    let title: String
}

/// 阅读区的一章
private struct ReadSection: Identifiable {
    let id: String
    let title: String
    let level: Int
    let body: String
}

struct LongReplySheet: View {
    let payload: LongReplyPayload
    @Environment(\.dismiss) private var dismiss

    // 字号/行距与聊天气泡同源（设置页滑条实时生效）
    @AppStorage("qingliao_font_size") private var fontSize = 15.0

    @State private var showTOC = false
    @State private var memoSaved = false
    @State private var shareItems: [Any] = []

    /// v3.9.86：同宿主互斥铁律——本 sheet 已在屏上时再 present 分享面板会被静默吞掉
    /// （链式 `.sheet` 两个同时为真只生效一个）。改走「先收阅读 sheet、下一轮 present 分享」。
    /// 大纲抽屉是本 sheet **内部**的一层（不是第二个 sheet），所以不参与互斥。
    private func presentShare() {
        shareItems = [payload.text]
        Task { @MainActor in
            dismiss()
            try? await Task.sleep(for: .milliseconds(450))
            guard let root = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first?.windows.first?.rootViewController else { return }
            let av = UIActivityViewController(activityItems: shareItems, applicationActivities: nil)
            if let pop = av.popoverPresentationController {
                pop.sourceView = root.view
                pop.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 1, height: 1)
            }
            root.present(av, animated: true)
        }
    }

    /// 章节切分：按 markdown 标题逐条切（与「章节列表」同源）；无标题时整条作为一章，
    /// 保证纯段落长回复也能进阅读模式。
    private static func sections(of text: String) -> [ReadSection] {
        let headers = MarkdownRenderer.extractHeaders(text)
        let lines = text.components(separatedBy: "\n")
        if headers.isEmpty {
            return [ReadSection(id: "sec-0", title: "全文", level: 1, body: text)]
        }
        var out: [ReadSection] = []
        // 第一个标题之前的前言段（常见于「先说结论」开场）
        if let first = headers.first, first.lineIndex > 0 {
            let pre = lines[0..<first.lineIndex].joined(separator: "\n")
            if !pre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(ReadSection(id: "sec-pre", title: "前言", level: 1, body: pre))
            }
        }
        for (i, h) in headers.enumerated() {
            let end = i + 1 < headers.count ? headers[i + 1].lineIndex : lines.count
            let start = h.lineIndex + 1
            let body = start < end ? lines[start..<end].joined(separator: "\n") : ""
            out.append(ReadSection(id: "sec-\(h.lineIndex)", title: h.title, level: h.level, body: body))
        }
        return out
    }

    private var sections: [ReadSection] { Self.sections(of: payload.text) }
    private var speaking: Bool { SpeechManager.shared.speakingID == payload.id }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    header
                    Divider()
                    content
                    Divider()
                    bottomBar
                }
                // 大纲抽屉：覆盖在正文上方的一层（不是新 sheet —— 同宿主多 sheet 会互斥打架）
                if showTOC { tocOverlay(scrollTo: { proxy.scrollTo($0, anchor: .top) }) }
            }
        }
        // ⚠️ 根容器不刷 systemBackground —— 刷了就把 iOS 26 给 sheet 的系统材质整块盖住、
        //    弹窗变回实底（与 Hermes 捷径/模型快选等全站 sheet 不一致）。见 swiftui-sheet-presentation 铁律。
    }

    // MARK: 正文

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.section) {
                ForEach(sections) { sec in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sec.title)
                            .font(.system(size: sec.level <= 1 ? 19 : 16,
                                          weight: sec.level <= 2 ? .bold : .semibold))
                            .foregroundStyle(.primary)
                            .id(sec.id)
                        if !sec.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            // 与气泡同一条渲染路径（markdown 解析 / 行距 / 长按菜单 / 高度缓存全同源）
                            SelectableTextLabel(
                                attributedText: MarkdownRenderer.renderCached(sec.body,
                                                                             baseSize: CGFloat(fontSize)),
                                fallbackColor: .label,
                                lineSpacingFromSettings: true,
                                fillWidth: true,
                                onCopy: {
                                    UIPasteboard.general.string = sec.body
                                    Haptics.success()
                                })
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.section)
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Typography.titleXL))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            Text(payload.title)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Button {
                withAnimation(Motion.snap) { showTOC.toggle() }
            } label: {
                Label(sections.count > 1 ? "章节 \(sections.count)" : "章节",
                      systemImage: "list.bullet.indent")
                    .font(.system(size: Typography.caption, weight: .medium))
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(Tint.subtle), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(sections.count <= 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, Spacing.section)
    }

    // MARK: 大纲抽屉

    private func tocOverlay(scrollTo: @escaping (String) -> Void) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("章节")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                Spacer()
                Button { withAnimation(Motion.snap) { showTOC = false } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.title))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { sec in
                        Button {
                            withAnimation(Motion.snap) { showTOC = false }
                            scrollTo(sec.id)
                        } label: {
                            HStack(spacing: 8) {
                                ForEach(0..<max(sec.level - 1, 0), id: \.self) { _ in
                                    Color.clear.frame(width: 10)
                                }
                                Circle().fill(Color.accentColor.opacity(0.6))
                                    .frame(width: 6, height: 6)
                                Text(sec.title)
                                    .font(.system(size: sec.level <= 1 ? 15 : 13,
                                                  weight: sec.level <= 1 ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }
        }
        // 大纲层用 ultraThinMaterial（不是 secondarySystemBackground——那是不透明实底，
        // 会把系统材质盖掉；薄材质还能透出一点正文，层次感靠这个）
        .background(.ultraThinMaterial)
    }

    // MARK: 底部操作栏（复制 / 分享 / 朗读 / 存便签）

    private var bottomBar: some View {
        HStack(spacing: 8) {
            actionPill("复制", "doc.on.doc") {
                UIPasteboard.general.string = payload.text
                Haptics.success()
            }
            actionPill("分享", "square.and.arrow.up") { presentShare() }
            actionPill(speaking ? "停止" : "朗读", speaking ? "stop.fill" : "speaker.wave.2.fill") {
                if speaking {
                    SpeechManager.shared.stop()
                } else {
                    SpeechManager.shared.speak(payload.text, id: payload.id)
                }
            }
            actionPill(memoSaved ? "已存" : "存便签", memoSaved ? "checkmark" : "note.text") {
                if MemoStore.shared.add(content: payload.text, source: "chat_reader") {
                    withAnimation(Motion.snap) { memoSaved = true }
                    Haptics.success()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func actionPill(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .fixedSize()          // 文字不许被压没（v3.9.72 胶囊空字根因：压缩时字被吃成 0 宽）
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(Tint.subtle), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
