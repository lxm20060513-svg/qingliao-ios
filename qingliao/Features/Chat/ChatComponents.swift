import SwiftUI
import UIKit
import AVFoundation

// MARK: - 聊天 UI 组件（从 ChatView.swift 拆出，减小主文件体积）

// MARK: - v2.0.65 气泡小尾巴（iMessage 式：AI 左下 / 用户右下）
// v2.0.66：单 Shape 一体化（圆角矩形 + 尾巴同路径，之前的 ZStack overlay 方案尾巴被挤进气泡内不显示）

struct BubbleShape: Shape {
    let tailLeft: Bool   // 尾巴朝左（AI 消息）
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = radius
        let tailW: CGFloat = 8   // 尾巴凸出宽度
        let tailH: CGFloat = 16  // 尾巴高度
        var p = Path()
        // 圆角矩形主体
        p.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r))
        // 尾巴：底部角落朝外凸出（与主体同填充色，天然一体）
        if tailLeft {
            p.move(to: CGPoint(x: rect.minX + r, y: rect.maxY - tailH))
            p.addLine(to: CGPoint(x: rect.minX - tailW, y: rect.maxY - tailH / 2))
            p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.maxX - r, y: rect.maxY - tailH))
            p.addLine(to: CGPoint(x: rect.maxX + tailW, y: rect.maxY - tailH / 2))
            p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}


struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0   // v2.0.51：static let 不可变即并发安全（协议 get-only）
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// BigBang 全屏炸开载荷（fullScreenCover(item:) 需要 Identifiable）
struct BigBangPayload: Identifiable {
    let id = UUID()
    let text: String
}

/// AI 消息内容分段（代码块 / markdown 段）

struct MessageContentBlock: Identifiable {
    let id = UUID()
    enum Kind {
        case markdown(String)
        case code(String)
        case table([[String]])   // v2.0.87d：markdown 表格（表头+数据行）
    }
    let kind: Kind
}

/// AI 消息分段渲染：markdown（容错解析，保留部分排版） / 代码块（等宽深色）
/// v2.0.122：markdown 段改用 SelectableTextLabel（UITextView）——长按菜单含「选取文字」，
///           点选后文字从手按位置选中、出现原生拖动手柄可自由拖动；代码块/表格保留 SwiftUI 菜单。
struct MessageBlockView: View {
    let block: MessageContentBlock
    // v2.0.38：聊天字体大小（与 MessageBubble 同源）
    @AppStorage("qingliao_font_size") private var fontSize = 15.0   // v2.0.87r：默认15号
    // v2.0.122：长按菜单回调（markdown 段 → UITextView 原生编辑菜单；代码块/表格 → SwiftUI 菜单）
    var onCopy: () -> Void = {}
    var onQuote: () -> Void = {}
    var onShare: () -> Void = {}
    var onBigBang: () -> Void = {}
    var onDelete: () -> Void = {}
    var onRegenerate: (() -> Void)? = nil
    var onWithdraw: (() -> Void)? = nil

    /// 代码块/表格共用的 SwiftUI 长按菜单（与原气泡级菜单项一致）
    @ViewBuilder
    private var bubbleMenu: some View {
        Button {
            onCopy()
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        Button {
            onQuote()
        } label: {
            Label("引用", systemImage: "quote.opening")
        }
        Button {
            onShare()
        } label: {
            Label("分享", systemImage: "square.and.arrow.up")
        }
        Button {
            onBigBang()
        } label: {
            Label("大爆炸", systemImage: "burst.fill")
        }
        if let onRegenerate {
            Button {
                onRegenerate()
            } label: {
                Label("重新生成", systemImage: "arrow.clockwise")
            }
        }
        if let onWithdraw {
            Button {
                onWithdraw()
            } label: {
                Label("撤回", systemImage: "arrow.uturn.backward")
            }
        }
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    var body: some View {
        switch block.kind {
        case .markdown(let text):
            // v2.0.122：UITextView 渲染 —— 长按文字弹菜单，点「选取文字」从手按位置选中可拖动
            SelectableTextLabel(
                attributedText: NSAttributedString(MarkdownRenderer.render(text, baseSize: CGFloat(fontSize))),
                fallbackColor: .label,
                onCopy: onCopy,
                onQuote: onQuote,
                onShare: onShare,
                onBigBang: onBigBang,
                onDelete: onDelete,
                onRegenerate: onRegenerate,
                onWithdraw: onWithdraw
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let text):
            // v2.0.36：代码块加复制按钮（右上角）
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("代码")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(.system(size: max(10, CGFloat(fontSize) - 2), design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.bottom, 4)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contextMenu { bubbleMenu }
        case .table(let rows):
            // v2.0.87d：markdown 表格渲染（表头加粗 + 斑马纹 + 横向滚动）
            MarkdownTableView(rows: rows)
                .contextMenu { bubbleMenu }
        }
    }
}

// MARK: - 聊天页（微信风格：AI 灰气泡左侧 / 用户深蓝气泡右侧，头像在气泡外）

struct MessageBubble: View {
    let message: ChatMessage
    var isHighlighted: Bool = false   // v2.0.43 搜索定位高亮
    var onRegenerate: () -> Void = {}
    var onBigBang: () -> Void = {}
    var onQuote: () -> Void = {}      // v2.0.36 引用回复
    var onDelete: () -> Void = {}     // v2.0.36 单条删除
    var onShare: () -> Void = {}      // v2.0.36 分享文本
    var onImageTap: () -> Void = {}   // v2.0.36 图片点击查看大图
    var onRetry: () -> Void = {}      // v2.0.59 发送失败重试
    var onWithdraw: () -> Void = {}   // v2.0.92 消息撤回（10 秒内）
    // v2.0.38：聊天字体大小（设置页可调，实时生效）
    @AppStorage("qingliao_font_size") private var fontSize = 15.0   // v2.0.87r：默认15号
    // v2.0.65：深浅色气泡双色值 / 超长消息折叠
    @Environment(\.colorScheme) private var scheme
    @State private var expanded = false
    // v2.0.81：AI 回复朗读状态（全局单例）
    @ObservedObject private var speech = SpeechManager.shared

    /// v2.0.92：撤回条件（自己的消息 + 10 秒内 + 未撤回 + 未失败），菜单项按此显隐
    private var canWithdraw: Bool {
        if message.isUser, !message.withdrawn, !message.failed,
           let ts = message.timestamp {
            return Date().timeIntervalSince1970 - ts / 1000 < 10
        }
        return false
    }

    /// 用户气泡蓝：深色用深蓝，浅色用亮蓝（对比度适配）
    private var userBubbleColor: Color {
        isHighlighted
            ? (scheme == .dark ? Color(red: 0.20, green: 0.32, blue: 0.62) : Color(red: 0.38, green: 0.55, blue: 0.92))
            : (scheme == .dark ? Color(red: 0.13, green: 0.22, blue: 0.45) : Color(red: 0.27, green: 0.47, blue: 0.88))
    }
    /// AI 气泡灰：浅色模式更浅
    private var aiBubbleColor: Color {
        isHighlighted ? Color.accentColor.opacity(0.14)
            : (scheme == .dark ? Color(uiColor: .systemGray5) : Color(uiColor: .systemGray6))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isUser {
                // v2.0.41：左侧留白 48→24，用户气泡更宽（右缘贴边）
                Spacer(minLength: 24)
            } else {
                // AI 头像（气泡外左侧）
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)
            }

            // v2.0.66：气泡主体（单 Shape 背景带尾巴，不再用 ZStack overlay）
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                    // v2.0.92：撤回消息 → 灰色"已撤回"占位（内容不再显示）
                    if message.withdrawn {
                        Text("已撤回")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    } else if let img = message.imageDataURL, let uiImg = dataURLImage(img) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: 200, maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            // v2.0.36：点击查看大图
                            .onTapGesture { onImageTap() }
                    }
                    if !message.content.isEmpty {
                        if message.isUser {
                            // v2.0.87q：文件消息微信风格卡片（图标+文件名+状态）
                            if let file = parseFileMessage(message.content) {
                                FileMessageCard(file: file)
                            } else {
                                // v2.0.122：UITextView 渲染 —— 长按弹菜单（复制/选取文字/引用/分享/大爆炸/撤回/删除）
                                SelectableTextLabel(
                                    attributedText: NSAttributedString(string: message.content, attributes: [
                                        .font: UIFont.systemFont(ofSize: CGFloat(fontSize)),
                                        .foregroundColor: UIColor.white
                                    ]),
                                    fallbackColor: .white,
                                    onCopy: { UIPasteboard.general.string = message.content },
                                    onQuote: onQuote,
                                    onShare: onShare,
                                    onBigBang: onBigBang,
                                    onDelete: onDelete,
                                    onRegenerate: nil,
                                    onWithdraw: canWithdraw ? onWithdraw : nil
                                )
                            }
                        } else {
                            // v2.0.65：AI 超长消息折叠（>800 字收成展开全文）
                            if message.content.count > 800 && !expanded {
                                SelectableTextLabel(
                                    attributedText: NSAttributedString(string: String(message.content.prefix(800)) + "…", attributes: [
                                        .font: UIFont.systemFont(ofSize: CGFloat(fontSize)),
                                        .foregroundColor: UIColor.label
                                    ]),
                                    fallbackColor: .label,
                                    onCopy: { UIPasteboard.general.string = message.content },
                                    onQuote: onQuote,
                                    onShare: onShare,
                                    onBigBang: onBigBang,
                                    onDelete: onDelete,
                                    onRegenerate: onRegenerate,
                                    onWithdraw: nil
                                )
                                Button {
                                    withAnimation(.easeOut(duration: 0.2)) { expanded = true }
                                } label: {
                                    Text("展开全文（剩余 \(message.content.count - 800) 字）")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 2)
                            } else {
                                // AI 消息：代码块分段渲染（等宽 + 深色背景），其余 markdown
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(0..<contentBlocks.count, id: \.self) { i in
                                        MessageBlockView(block: contentBlocks[i],
                                                        onCopy: { UIPasteboard.general.string = message.content },
                                                        onQuote: onQuote,
                                                        onShare: onShare,
                                                        onBigBang: onBigBang,
                                                        onDelete: onDelete,
                                                        onRegenerate: onRegenerate,
                                                        onWithdraw: nil)
                                    }
                                }
                            }
                        }
                    }
                    // v2.0.59：发送失败 → 重试按钮（红色，点击按原内容重发）
                    if message.isUser && message.failed {
                        Button {
                            onRetry()
                        } label: {
                            Label("发送失败，点击重试", systemImage: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                    // v2.0.65：已送达小字（用户消息、非失败、非语音、未撤回）
                    // v2.0.87q：加 ✓ 图标（微信式送达状态）
                    // v2.0.88：排队中的消息显示 ⏳ 排队中（AI 回答完自动发送）
                    if message.isUser && !message.failed && !message.withdrawn {
                        HStack(spacing: 2.5) {
                            Image(systemName: message.queued ? "hourglass" : "checkmark")
                                .font(.system(size: 7.5, weight: .bold))
                            Text(message.queued ? "排队中" : "已送达")
                                .font(.system(size: 9.5))
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                    }
                    // v2.0.81：AI 消息朗读（点击播放/停止，中文 TTS）
                    if !message.isUser && !message.content.isEmpty {
                        Button {
                            SpeechManager.shared.toggle(message.content, id: message.id)
                        } label: {
                            Image(systemName: speech.speakingID == message.id
                                  ? "speaker.wave.2.fill" : "speaker.wave.2")
                                .font(.system(size: 11))
                                .foregroundStyle(speech.speakingID == message.id
                                                 ? Color.accentColor : .secondary)
                                .padding(.top, 1)
                        }
                        .buttonStyle(.plain)
                    }
                    // v2.0.96b：Agent 回复标记（工具调用回复小标签）
                    if message.agent {
                        Text("Agent 回复")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LinearGradient(colors: [.blue, .indigo, .pink],
                                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .padding(.top, 1)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                // v2.0.68：用户反馈拿掉气泡尾巴（试了两版效果都不理想），回归纯圆角
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(message.withdrawn ? aiBubbleColor : (message.isUser ? userBubbleColor : aiBubbleColor))   // v2.0.92：撤回统一灰
                )
                // v2.0.43 搜索定位高亮边框
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(isHighlighted ? Color.accentColor : .clear, lineWidth: 2)
                )
            .frame(maxWidth: 366, alignment: message.isUser ? .trailing : .leading)   // v2.0.41 气泡加宽 350→366（贴红线/近满宽）
            // v2.0.85c：气泡出现微动画（缩放 + 淡入，单条插入安全）
            .transition(.scale(scale: 0.94, anchor: message.isUser ? .trailing : .leading)
                .combined(with: .opacity))

            if message.isUser {
                // v2.0.65：用户头像（渐变圆 + 首字母，与 AI 头像对称）
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("Q")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)
            } else {
                // v2.0.41：AI 气泡右侧留白 48→10，气泡右缘贴红线（约距屏幕右 22pt）
                Spacer(minLength: 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        // 长按：复制 / 引用 / 分享 / 大爆炸 / 重新生成（AI 消息）/ 撤回 / 删除
        // v2.0.122：「选取文字」已移入 UITextView 原生编辑菜单（SelectableTextLabel），
        //           点选后从手按位置选中文字、出现拖动手柄可自由拖动；此处保留其余菜单项
        .contextMenu {
            Button {
                UIPasteboard.general.string = message.content
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button {
                onQuote()
            } label: {
                Label("引用", systemImage: "quote.opening")
            }
            Button {
                onShare()
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            Button {
                onBigBang()
            } label: {
                Label("大爆炸", systemImage: "burst.fill")
            }
            if !message.isUser {
                Button {
                    onRegenerate()
                } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                }
            }
            // v2.0.92：撤回（仅自己的消息 + 10 秒内 + 未撤回 + 未失败）
            if canWithdraw {
                Button {
                    onWithdraw()
                } label: {
                    Label("撤回", systemImage: "arrow.uturn.backward")
                }
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 消息内容分段：``` 代码块 → 等宽深色块；其余 → markdown
    private var contentBlocks: [MessageContentBlock] {
        let parts = message.content.components(separatedBy: "```")
        var blocks: [MessageContentBlock] = []
        for (i, p) in parts.enumerated() {
            if i % 2 == 1 {
                // 代码块：去掉语言标记行
                let lines = p.split(separator: "\n", maxSplits: 1).map(String.init)
                let body = lines.count > 1 ? lines[1] : p
                blocks.append(.init(kind: .code(body.trimmingCharacters(in: .whitespacesAndNewlines))))
            } else if !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // v2.0.87d：markdown 段内拆出表格块（| a | b | + 分隔行）
                for k in Self.splitMarkdownTable(p) {
                    blocks.append(.init(kind: k))
                }
            }
        }
        return blocks.isEmpty ? [.init(kind: .markdown(message.content))] : blocks
    }

    /// v2.0.87d：markdown 表格检测拆分（连续 | 行 → 表格块，其余保持 markdown）
    private static func splitMarkdownTable(_ text: String) -> [MessageContentBlock.Kind] {
        let lines = text.components(separatedBy: "\n")
        var result: [MessageContentBlock.Kind] = []
        var table: [String] = []
        func flush() {
            if !table.isEmpty {
                if let rows = parseTable(table) {
                    result.append(.table(rows))
                } else {
                    result.append(.markdown(table.joined(separator: "\n")))
                }
                table = []
            }
        }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") && t.hasSuffix("|") {
                table.append(line)
            } else {
                flush()
                result.append(.markdown(line))
            }
        }
        flush()
        return result
    }

    /// v2.0.87d：表格行解析（首行表头，第二行 |---| 分隔则跳过）
    private static func parseTable(_ lines: [String]) -> [[String]]? {
        let rows = lines.map { line -> [String] in
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") { s.removeFirst() }
            if s.hasSuffix("|") { s.removeLast() }
            return s.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard rows.count >= 2 else { return nil }
        let sep = rows[1]
        let isSep = sep.allSatisfy { $0.isEmpty || $0.allSatisfy { $0 == "-" || $0 == ":" } }
        let data = isSep ? Array(rows.dropFirst(2)) : Array(rows.dropFirst(1))
        let header = rows[0]
        return data.isEmpty ? [header] : [header] + data
    }

}

// MARK: - 液态玻璃输入栏

struct ChatInputBar: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    var streaming: Bool
    var onSend: () -> Void
    var onStop: () -> Void = {}
    var onPickAttachment: () -> Void = {}
    var onCamera: () -> Void = {}   // v2.0.38 拍照输入
    // 语音输入（按住说话）
    var isRecording: Bool = false
    var onVoiceStart: () -> Void = {}
    var onVoiceEnd: () -> Void = {}
    // v2.0.96：语音转文字模式（长按发送按钮进入；Siri 彩色图标 + 输入框流光）
    var voiceMode: Bool = false
    var onVoiceModeToggle: () -> Void = {}
    // v2.0.100：转写中动画（输入框「语音转换中…」+ 按钮转圈）
    var transcribing: Bool = false
    // v2.0.101：转写停止按钮回调
    var onCancelTranscribe: () -> Void = {}
    // v2.0.106：长按输入框触发语音转文字（效果与长按发送键一致，不弹键盘）
    // v2.0.109b：onChanged 记录按下瞬间键盘可见状态（down 时键盘未弹/已弹，比时间戳推断可靠）
    var onLongPressInput: (Bool) -> Void = { _ in }
    @Environment(KeyboardObserver.self) private var kbEnv
    @State private var pressKeyboardUp = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPickAttachment) {
                Image(systemName: "paperclip")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)

            // v2.0.38：拍照输入
            Button(action: onCamera) {
                Image(systemName: "camera")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)

            if isRecording {
                // 录音中：红点 + 提示
                HStack(spacing: 5) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text("松开结束")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.red)
                }
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.08), in: Capsule())
            } else {
                // v2.0.34：placeholder 用 overlay 自定义（vertical axis 的 TextField 自带
                // placeholder 在 lineLimit(2...6) 多行高下顶部对齐，视觉不居中）
                TextField("", text: $text, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(1...6)   // v2.0.35：1行起（原来2...6最小2行高→单行光标/文字偏上不居中）
                    .padding(.vertical, 12)   // v2.0.93f：9→12 输入框加高（用户反馈太窄）
                    .padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)   // 文字超宽自动增高输入框，旧文字始终可见
                    .focused($focused)
                    // v2.0.106：长按输入框 = 进入语音转文字（与长按发送键同效；收键盘由 ChatView 处理）
                    // v2.0.106b：onLongPressGesture 被 UITextField 内置长按(放大镜/选择)拦截不触发
                    //           → 改 simultaneousGesture 与系统手势共存触发
                    // v2.0.109b：onChanged（down 瞬间）记录键盘可见状态——键盘开=true 保持，关=false 收回
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.4)
                            .onChanged { _ in
                                pressKeyboardUp = kbEnv.isVisible
                            }
                            .onEnded { _ in
                                onLongPressInput(pressKeyboardUp)
                            }
                    )
                    .overlay {
                        if text.isEmpty {
                            if transcribing {
                                // v2.0.100：转写中动画（waveform 图标 + 文字脉冲）
                                HStack(spacing: 6) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 12))
                                        .symbolEffect(.pulse)
                                    Text("语音转换中…")
                                        .font(.system(size: 15))
                                }
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .allowsHitTesting(false)
                            } else {
                                Text("输入消息...")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
            }

            // v2.0.88：AI 回答中也可继续发送（消息排队，答完自动逐条回）；
            // 停止按钮独立保留（取消当前回答 + 清空队列）
            if streaming {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.red.opacity(0.8), in: Circle())
                }
                .buttonStyle(.plain)
            }

            // v2.0.96：发送按钮——普通发送；语音模式下点击=退出；长按=进入语音转文字（Siri 彩色图标）
            // v2.0.96b：Button 内置手势会拦截 onLongPressGesture → 改自定义视图 + 显式 Tap/LongPress
            // v2.0.98：onTapGesture+onLongPressGesture 叠加 = 两个独立手势系统在手势激活中改
            //          视图树（voiceMode 切换重建按钮）→ 实测 SIGTRAP 闪退（crash_reports 4 次）。
            //          改用 ExclusiveGesture（长按优先、互斥），onEnded 时手势已结束，视图重建安全。
            // v2.0.100：transcribing 时按钮显示转圈（转换中动画）
            // v2.0.101：转圈旁加红色停止按钮（随时中断转换）；手势只在非转写时挂载（停止按钮独立可点）
            Group {
                if transcribing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .tint(.white)
                            .frame(width: 32, height: 32)
                        Button(action: onCancelTranscribe) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Color.red.opacity(0.85), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Image(systemName: voiceMode ? "waveform" : "arrow.up")
                        .font(.system(size: voiceMode ? 15 : 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                        .gesture(
                            LongPressGesture(minimumDuration: 0.4)
                                .exclusively(before: TapGesture())
                                .onEnded { value in
                                    // .first = 长按成功（语音模式开关）；.second = 轻点（发送/退出）
                                    switch value {
                                    case .first:
                                        onVoiceModeToggle()
                                    case .second:
                                        if voiceMode {
                                            onVoiceModeToggle()
                                        } else {
                                            onSend()
                                        }
                                    }
                                }
                        )
                }
            }
            .background(
                LinearGradient(colors: voiceMode ? [.blue, .indigo, .pink] : [.blue, .indigo],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Capsule()
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // v2.0.87e：原生液态玻璃输入栏（iOS 26+）
        .background { Capsule().glassEffect() }
        // v2.0.87s：等待回复特效（v2.0.87ay：改回 87 版效果——内部旋转流光，Siri 淡雅）
        // v2.0.96：语音转文字模式同样开启 Siri 流光
        .overlay {
            if (streaming || voiceMode) && UserDefaults.standard.bool(forKey: "qingliao_input_glow") {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let angle = (t * 70).truncatingRemainder(dividingBy: 360)
                    // 内部流光：Siri 淡雅蓝紫粉红旋转（87 版效果）
                    Capsule().fill(
                        AngularGradient(
                            colors: [.blue.opacity(0.22), .indigo.opacity(0.22),
                                     .pink.opacity(0.22), .red.opacity(0.16), .blue.opacity(0.22)],
                            center: .center, angle: .degrees(angle)
                        )
                    )
                    .shadow(color: .indigo.opacity(0.30), radius: 6)
                    .allowsHitTesting(false)   // v2.0.87al：不拦截点击（停止按钮可点）
                }
            } else {
                Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.8)
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
        .padding(.horizontal, 18)   // v2.0.87aw：输入框宽度收窄（12→18）
    }
}

// MARK: - v2.0.96 Hermes 捷径面板（官方斜杠命令 + 功能注释，点击填充输入框）

struct HermesShortcutSheet: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    // 官方命令（hermes-agent 文档）：命令 + 中文功能注释
    private let items: [(cmd: String, desc: String)] = [
        ("/help", "查看全部可用命令"),
        ("/new", "开启全新会话（清空上下文）"),
        ("/model deepseek-v4-flash", "切换模型（如 deepseek-v4-flash）"),
        ("/compress", "压缩当前上下文，节省 token"),
        ("/memory", "查看与管理 AI 记忆"),
        ("/skills", "浏览、搜索、安装技能"),
        ("/skill <名称>", "加载指定技能到当前会话"),
        ("/cron", "定时任务管理（查看/创建/暂停）"),
        ("/voice on", "开启语音对话模式"),
        ("/voice off", "关闭语音模式"),
        ("/undo", "撤销上一轮对话"),
        ("/title <名称>", "给当前会话命名"),
        ("/usage", "查看 Token 用量统计"),
        ("/status", "查看会话与系统状态"),
        ("/personality <名称>", "切换 AI 人格"),
        ("/reasoning high", "设置思考深度（none/low/medium/high）"),
        ("/background <任务>", "后台运行长任务（不阻塞对话）"),
        ("/queue <任务>", "排队等待下一轮处理"),
        ("/fast", "切换优先快速处理"),
        ("/resume <名称>", "恢复历史会话"),
        ("/sethome", "把当前聊天设为默认投递位置"),
        ("/update", "更新 Hermes 到最新版"),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(items, id: \.cmd) { item in
                    Button {
                        onPick(item.cmd)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Text(item.cmd)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                            Text(item.desc)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("Hermes 捷径")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                }
            }
        }
    }
}

// MARK: - v2.0.43 快捷指令面板（常用 prompt 模板，点击填充输入框）

struct QuickPromptSheet: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let prompts: [(icon: String, name: String, prompt: String)] = [
        ("character.bubble", "翻译", "请将以下内容翻译成英文（保留原意）：\n"),
        ("list.bullet.rectangle", "总结", "请用 3-5 条要点总结以下内容：\n"),
        ("pencil.and.outline", "润色", "请润色以下文字，使其更通顺、专业、简洁：\n"),
        ("doc.text", "写周报", "请根据以下工作内容生成一份结构化周报：\n"),
        ("chevron.left.forwardslash.chevron.right", "写代码", "请实现以下功能，给出完整代码并简要解释：\n"),
        ("curlybraces", "解释代码", "请逐段解释以下代码的作用和逻辑：\n"),
        ("lightbulb", "头脑风暴", "请围绕以下主题给出 5 个有创意的点子：\n"),
        ("checklist", "待办清单", "请把以下内容整理成清晰的待办清单：\n"),
        ("textformat", "取标题", "请为以下内容取 3 个简洁贴切的标题：\n"),
        ("person.2", "角色扮演", "请扮演一个资深嵌入式硬件工程师，回答以下问题：\n"),
        // v2.0.104b：知识库快捷指令（@知识库 前缀触发知识库检索问答）
        ("books.vertical.fill", "知识库", "@知识库 "),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("快捷指令")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(prompts, id: \.name) { p in
                        Button {
                            onPick(p.prompt)
                            dismiss()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: p.icon)
                                    .font(.system(size: 18))
                                    .foregroundStyle(Color.accentColor)
                                Text(p.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }
}

// MARK: - v2.0.36 图片大图查看器（双击/捏合缩放 + 保存相册）

struct ImageViewPayload: Identifiable {
    let id = UUID()
    let images: [UIImage]   // v2.0.62：全部图片消息（相册翻页）
    var index: Int
}

// v2.0.62：相册式查看器——横向滑动翻页 + 每页双击/捏合缩放 + 保存
struct ImageViewer: View {
    let images: [UIImage]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(0..<images.count, id: \.self) { i in
                    ImageViewerPage(image: images[i])
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            VStack {
                HStack {
                    if images.count > 1 {
                        Text("\(index + 1) / \(images.count)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.leading, 16)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
                Spacer()
                Button {
                    UIImageWriteToSavedPhotosAlbum(images[index], nil, nil, nil)
                } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 44)
            }
        }
    }
}

// 单图页：双击/捏合缩放
struct ImageViewerPage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .animation(.spring(duration: 0.25), value: scale)
            .gesture(MagnificationGesture()
                .onChanged { scale = max(1, min($0, 4)) })
            .onTapGesture(count: 2) {
                scale = scale == 1 ? 2.2 : 1
            }
    }
}

// MARK: - v2.0.36 会话导出文档（.txt）

struct ChatLogDocument: FileDocument {
    var text: String
    static var readableContentTypes: [UTType] { [.plainText] }
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - v2.0.87d markdown 表格视图（表头加粗 + 斑马纹 + 横向滚动）
// v2.0.87m：统一列宽（按每列最大内容宽度，列对齐不再错位）

private struct MarkdownTableView: View {
    let rows: [[String]]

    /// 每列统一宽度（按该列最长内容估宽，中文 12pt 约 13px/字）
    private var colWidths: [CGFloat] {
        guard let first = rows.first else { return [] }
        return first.indices.map { c in
            let maxLen = rows.map { $0.indices.contains(c) ? $0[c].count : 0 }.max() ?? 0
            return max(56, min(CGFloat(maxLen) * 13 + 22, 160))
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(rows[r].indices, id: \.self) { c in
                            Text(rows[r][c])
                                .font(.system(size: 12, weight: r == 0 ? .semibold : .regular))
                                .foregroundStyle(r == 0 ? Color.primary : Color.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(width: colWidths.indices.contains(c) ? colWidths[c] : 80, alignment: .leading)
                                .background(r == 0
                                            ? Color.accentColor.opacity(0.08)
                                            : (r % 2 == 0 ? Color.primary.opacity(0.03) : Color.clear))
                        }
                    }
                    Divider().overlay(Color.primary.opacity(0.07))
                }
            }
            .padding(8)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.vertical, 2)
        }
        .textSelection(.enabled)
    }
}

// MARK: - v2.0.87q 文件消息微信风格卡片（类型图标 + 文件名 + 状态）

struct FileMessageInfo {
    let name: String
    let type: String      // pdf / doc / xlsx / txt / img / other
    let status: String
    let failed: Bool
}

extension MessageBubble {
    /// 解析文件消息文本（[文件: name]（状态）/[PDF: name]（状态）…）
    private func parseFileMessage(_ content: String) -> FileMessageInfo? {
        guard content.hasPrefix("[文件:") || content.hasPrefix("[PDF:") || content.hasPrefix("[图片:") else { return nil }
        // 提取方括号内文件名（v2.0.102：按实际前缀长度截断——[文件:/[图片: 4 字符，[PDF: 5 字符，原 drop 3 会把冒号带进文件名）
        let drop: Int = content.hasPrefix("[PDF:") ? 5 : 4
        let rest = content.dropFirst(drop)
        guard let end = rest.firstIndex(of: "]") else { return nil }
        let name = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        // 提取括号内状态
        var status = ""
        var failed = false
        if let s = content.firstIndex(of: "（"), let e = content.lastIndex(of: "）") {
            status = String(content[content.index(after: s)..<e])
            failed = status.contains("失败")
        }
        let lower = name.lowercased()
        let type: String
        if lower.hasSuffix(".pdf") { type = "pdf" }
        else if lower.hasSuffix(".xlsx") || lower.hasSuffix(".xls") || lower.hasSuffix(".csv") { type = "xlsx" }
        else if lower.hasSuffix(".doc") || lower.hasSuffix(".docx") { type = "doc" }
        else if lower.hasSuffix(".txt") || lower.hasSuffix(".md") || lower.hasSuffix(".log") || lower.hasSuffix(".json") { type = "txt" }
        else { type = "other" }
        return FileMessageInfo(name: name, type: type,
                               status: status.isEmpty ? (failed ? "上传失败" : "已上传") : status,
                               failed: failed)
    }
}

/// 微信风格文件卡片（用户气泡内：图标块 + 文件名 + 状态）
struct FileMessageCard: View {
    let file: FileMessageInfo

    private var icon: String {
        switch file.type {
        case "pdf": return "doc.richtext.fill"
        case "xlsx": return "tablecells.fill"
        case "doc": return "doc.text.fill"
        case "txt": return "doc.plaintext.fill"
        case "img": return "photo.fill"
        default: return "doc.fill"
        }
    }

    private var color: Color {
        switch file.type {
        case "pdf": return .red
        case "xlsx": return .green
        case "doc": return .blue
        case "txt": return .gray
        default: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.22))
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(color)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if file.failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 9))
                    }
                    Text(file.status)
                        .font(.system(size: 10))
                        .foregroundStyle(file.failed ? Color.red.opacity(0.9) : Color.white.opacity(0.75))
                }
            }
            Spacer(minLength: 4)
            Image(systemName: file.failed ? "arrow.clockwise" : "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(file.failed ? Color.red.opacity(0.8) : Color.white.opacity(0.55))
        }
        .padding(10)
        .frame(maxWidth: 240)
        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - v2.0.92 会话分享卡片（ImageRenderer 渲染为图片，微信/系统分享）

struct SessionCardView: View {
    let rows: [(role: String, text: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("轻聊 AI 会话")
                    .font(.system(size: 17, weight: .bold))
            }
            Text(formattedDate)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            Divider()
                .padding(.vertical, 10)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.role == "user" ? "我" : "AI")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(row.role == "user" ? Color.blue : Color.indigo, in: Capsule())
                    Text(row.text)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08))
        )
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f.string(from: Date())
    }
}
