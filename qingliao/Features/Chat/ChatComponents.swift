import SwiftUI
import UIKit
import AVFoundation

// MARK: - 聊天 UI 组件（从 ChatView.swift 拆出，减小主文件体积）

// MARK: - v2.0.65 气泡小尾巴（iMessage 式：AI 左下 / 用户右下）
// v2.0.66：单 Shape 一体化（圆角矩形 + 尾巴同路径，之前的 ZStack overlay 方案尾巴被挤进气泡内不显示）
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
        case code(String, String?)     // v3.4.x：代码块带语言标记（```lang → lang，用于语法高亮）
        case table([[String]])   // v2.0.87d：markdown 表格（表头+数据行）
        case image(String)       // v2.0.128：AI 回复中的图片（URL 或 data URL）
    }
    let kind: Kind
}

/// AI 消息分段渲染：markdown（容错解析，保留部分排版） / 代码块（等宽深色）
/// v2.0.125：markdown 段改用 SelectableTextLabel（UITextView）——长按菜单含「选择文本」，
///           点选后文字从手按位置选中、出现原生拖动手柄可自由拖动；代码块/表格保留 SwiftUI 菜单。
struct MessageBlockView: View {
    let block: MessageContentBlock
    // v2.0.38：聊天字体大小（与 MessageBubble 同源）
    @AppStorage("qingliao_font_size") private var fontSize = 15.0   // v2.0.87r：默认15号
    // v2.0.128：AI 输出行高（设置页滑条控制，0-6；默认 1.0 紧凑）
    @AppStorage("qingliao_ai_line_spacing") private var aiLineSpacing = 1.0
    // v2.0.125：长按菜单回调（markdown 段 → UITextView 原生编辑菜单；代码块/表格 → SwiftUI 菜单）
    var onCopy: () -> Void = {}
    var onQuote: () -> Void = {}
    var onShare: () -> Void = {}
    var onBigBang: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onRegenerate: (() -> Void)? = nil
    var onWithdraw: (() -> Void)? = nil
    // v3.0.74：钉一钉（长按菜单钉到看板）——传当前段落/选中文字
    var onPin: ((String) -> Void)? = nil
    // v2.0.128：AI 图片点击打开大图（传图片 URL/data URL）
    var onImageTap: (String) -> Void = { _ in }
    // v3.3.0：多选合并转发入口（AI 消息段落长按菜单）
    var onMultiSelect: () -> Void = {}
    // v3.0.17：流式输出中用 SwiftUI Text 渲染（UITextView 在流式高频更新下有锁旧窄布局/字体缩放 bug 家族，
    // 见 references/ui-textview-layout-shrink.md；流式中无需长按菜单，落库后恢复 SelectableTextLabel）
    var useSwiftUIText = false
    // v3.0.41 性能：流式输出中超长文本渲染优化——纯 Text 渲染（跳过 markdown 解析/AttributedString 转换）
    var streaming: Bool = false

    // v3.0.2 性能：缓存 markdown 渲染结果——流式每段更新 parent.messages 会触发子视图重算，
    // 若每次 body 都 MarkdownRenderer.render() 重新解析，长文本/流式下是滚动+更新卡顿主因。
    // 用 @State 缓存 + 内容指纹：文本/字号未变 → 复用已渲染的 NSAttributedString。
    @State private var cachedKey = ""
    @State private var cachedAttr: NSAttributedString? = nil
    // v3.0.41 性能：缓存 AttributedString 本体（NSAttributedString→AttributedString 对超长文本也是 O(n) 转换，
    // 滚动时每次 body 重算都转一次 = 长文本滑动卡顿主因之一）
    @State private var cachedAttrStr: AttributedString? = nil

    /// 渲染并缓存 markdown（内容指纹：文本+字号）
    /// v3.0.43：改走 MarkdownRenderer.renderCached 全局缓存（跨 cell 生命周期——LazyVStack
    /// 滚动离屏销毁 cell 后 @State 丢失，若重新全量解析超长文本=主线程卡死；全局缓存命中即免）
    private func cachedRender(_ text: String) -> NSAttributedString {
        let key = "\(text.hashValue)|\(fontSize)"
        if key != cachedKey || cachedAttr == nil {
            cachedKey = key
            cachedAttr = MarkdownRenderer.renderCached(text, baseSize: CGFloat(fontSize))
            cachedAttrStr = nil   // 重新解析后重建 AttributedString 缓存
        }
        return cachedAttr ?? NSAttributedString(string: text)
    }

    /// v3.0.17：流式 SwiftUI Text 用 —— 复用同一缓存转 AttributedString
    /// v3.0.41：AttributedString 本体缓存（key 未变直接复用，跳过转换）
    /// v3.0.43：走 renderCachedAttr 全局双缓存（跨 cell 生命周期，滚动重建不重复转换）
    private func cachedRenderText(_ text: String) -> AttributedString {
        let key = "\(text.hashValue)|\(fontSize)"
        if key != cachedKey || cachedAttrStr == nil {
            cachedKey = key
            cachedAttrStr = MarkdownRenderer.renderCachedAttr(text, baseSize: CGFloat(fontSize))
        }
        return cachedAttrStr ?? AttributedString(text)
    }

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
        // v3.3.0：多选合并转发入口
        Button {
            onMultiSelect()
        } label: {
            Label("多选", systemImage: "checkmark.circle")
        }
        Button {
            let text: String
            switch block.kind {
            case .markdown(let s): text = s
            case .code(let s, _): text = s
            case .table(let rows): text = rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
            case .image(let url): text = url
            }
            onBigBang(text)
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
        // v3.0.74：钉一钉（钉到看板）——传当前段落文字
        if let onPin {
            Button {
                let text: String
                switch block.kind {
                case .markdown(let s): text = s
                case .code(let s, _): text = s
                case .table(let rows): text = rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
                case .image(let url): text = url
                }
                onPin(text)
            } label: {
                Label("钉一钉", systemImage: "pin.fill")
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
            if streaming {
                // v3.0.86 fix：流式输出用纯 SwiftUI Text，跳过 markdown 解析/AttributedString 转换——
                // （对齐 65 行 streaming 语义注释）。cachedRenderText 按 text.hashValue 判键，流式每帧
                // 文本不同 → 全量 MarkdownRenderer 解析整段已输出文本 = O(n²)（长回复尾部卡顿主因）。
                // 纯文本渲染零解析；落库后的静态消息仍走下方完整 markdown 渲染路径
                // v3.4.25：尾部窗口渲染——超长回复（>3000字）流式中只渲染末尾 3000 字。
                // Text 每帧全量排版 O(n)，几万字时打字后期每帧排版成本线性涨 = 长回答越打越卡；
                // 窗口化后每帧排版成本恒定，头部已滚出屏幕的内容流式完成后由落库渲染补全
                if text.count > 3000 {
                    let tail = String(text.suffix(3000))
                    // 从字符边界对齐到最近换行，避免窗口起点切断 Markdown 语法/中文词
                    let aligned = tail.firstIndex(of: "\n").map { String(tail[$0...]) } ?? tail
                    Text(aligned)
                        .font(.system(size: CGFloat(fontSize)))
                        .lineSpacing(aiLineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(text)
                        .font(.system(size: CGFloat(fontSize)))
                        .lineSpacing(aiLineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if useSwiftUIText && text.count <= 6000 {
                // v3.0.17：流式输出中的 AI 长文 —— SwiftUI Text 原生渲染，无 UITextView 布局锁/字体缩放问题
                // v3.0.18：AI 消息落库后也保持 SwiftUI Text（不再切回 UITextView）——根治"字挤小框"
                // 长按菜单用 contextMenu 提供（复制/引用/分享/大爆炸/重新生成/撤回/删除，与 UITextView 编辑菜单一致）
                // v3.4.28：environment openURL 接管链接点击 → 直接开浏览器（.link 属性文字可点）
                Text(cachedRenderText(text))
                    .font(.system(size: CGFloat(fontSize)))
                    .lineSpacing(aiLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu { bubbleMenu }
                    .environment(\.openURL, OpenURLAction { url in
                        UIApplication.shared.open(url)
                        return .handled
                    })
            } else {
                // v3.0.41 fix：超长静态文本（>6000 字）改回 UITextView 渲染——
                // SwiftUI 大 Text 在 LazyVStack 滚动时每次布局都全量 CoreText 排版（几万字），
                // 生成后上下滑动直接卡死；UITextView 布局一次后高度缓存，滚动流畅。
                // 流式/普通长度消息仍走上面的 SwiftUI Text（v3.0.17-18 布局 bug 只在流式高频更新时出现，
                // 静态长文本无此问题）。
                // v2.0.125：UITextView 渲染 —— 长按文字弹菜单，点「选择文本」从手按位置选中可拖动
                // v3.0.2 性能：用 cachedRender 缓存 markdown 渲染结果（避免流式/滚动反复重解析）
                SelectableTextLabel(
                    attributedText: cachedRender(text),
                    fallbackColor: .label,
                    lineSpacingFromSettings: true,   // v2.0.130：AI 消息行距实时读设置
                    fillWidth: true,   // v3.0.11 fix：AI 消息满容器宽（流式不跳变）
                    onCopy: onCopy,
                    onQuote: onQuote,
                    onShare: onShare,
                    onBigBang: onBigBang,
                    onDelete: onDelete,
                    onRegenerate: onRegenerate,
                    onWithdraw: onWithdraw,
                    onMultiSelect: onMultiSelect
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image(let url):
            // v2.0.128：AI 直接发图 —— URL 用 AsyncImage，data URL 本地解码；点击打开大图
            AIImageView(url: url)
                .onTapGesture { onImageTap(url) }
                .contextMenu { bubbleMenu }
        case .code(let text, let lang):
            // v2.0.36：代码块加复制按钮（右上角）；v3.4.x 语法高亮（已知语言按 token 着色）
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(lang.map { $0.uppercased() } ?? "代码")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    // v3.4.25：代码块复制按钮重做——低调半透明 doc.on.doc 图标（无文字），点击复制
                    // 代码正文（fence 围栏已在 blocks(for:) 拆段时剥离，text 本就不含 ```），
                    // 短暂显示 checkmark 反馈 1.5s 后还原；按压有 opacity 缩放反馈。
                    // 拆成独立小 View：深层嵌套大视图里加子视图易触发 SwiftUI type-check 超时（类级坑）
                    CodeCopyButton(codeText: text)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    // v3.4.x：有语言标记 → 语法高亮；无 → 纯等宽字（原行为）
                    if let lang, SyntaxHighlighter.supports(lang) {
                        Text(AttributedString(SyntaxHighlighter.highlight(text, language: lang,
                                                                         baseSize: max(12, CGFloat(fontSize)))))
                            .textSelection(.enabled)
                            .padding(.bottom, 4)
                    } else {
                        Text(text)
                            .font(.system(size: max(12, CGFloat(fontSize)), design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.bottom, 4)
                    }
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

// MARK: - v3.4.25 代码块复制按钮（独立小 View：避免大 body 嵌套 type-check 超时）

/// v3.4.25：低调半透明按钮样式——常态 opacity 0.55，按压时高亮 + 微缩放（isPressed 驱动，
/// 不用手势叠加：DragGesture 挂 Button 上与 tap 手势有互相干扰风险）
private struct CodeCopyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 1.0 : 0.55)
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(Motion.tap, value: configuration.isPressed)
    }
}

/// 低调半透明的复制按钮：SF Symbol doc.on.doc，点击复制代码正文（不含 ``` 围栏），
/// 短暂显示 checkmark 反馈 1.5s 后还原；hover（iPad 指针悬停）高亮，按压有反馈。
private struct CodeCopyButton: View {
    let codeText: String
    // v3.4.25：复制成功反馈（true = 显示 checkmark）
    @State private var copied = false
    // v3.4.25：还原定时任务（重复点击先取消旧任务，避免 checkmark 提前消失）
    @State private var resetTask: Task<Void, Never>? = nil
    // v3.4.25：hover 状态（iPad 指针悬停高亮）
    @State private var hovered = false

    var body: some View {
        Button {
            UIPasteboard.general.string = codeText
            // UISelectionFeedbackGenerator：轻触感反馈（低成本，点击有实感）
            UISelectionFeedbackGenerator().selectionChanged()
            copied = true
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .symbolEffect(.bounce, value: copied)   // v3.4.29：复制成功图标弹一下
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(CodeCopyButtonStyle())
        // v3.4.25：hover（iPad 指针/悬停）反馈——半透明 → 完全不透明
        .opacity(hovered ? 1.0 : 0.55)
        .animation(Motion.tap, value: hovered)
        .onHover { hovered = $0 }
        .accessibilityLabel(copied ? "已复制" : "复制代码")
    }
}


// MARK: - v2.0.36+v3.0.81 会话导出文档（统一 .txt/.md 纯文本导出）

struct ChatTextDocument: FileDocument {
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

// 向后兼容别名（v3.0.81 合并 ChatLogDocument + ChatMarkdownDocument）
typealias ChatLogDocument = ChatTextDocument
typealias ChatMarkdownDocument = ChatTextDocument

// MARK: - v3.0.22 会话导出文档（.pdf）

struct ChatPDFDocument: FileDocument {
    var data: Data
    static var readableContentTypes: [UTType] { [.pdf] }
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    /// 从消息列表生成 PDF（UIKit 排版 A4）
    /// v3.4.28：图片消息真图嵌入（按比例缩放进版心，放不下先换页；解码失败降级占位文字）
    static func generate(title: String, messages: [ChatMessage]) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842) // A4
        let margin: CGFloat = 50
        let contentWidth = pageRect.width - margin * 2
        let titleFont = UIFont.systemFont(ofSize: 18, weight: .bold)
        let bodyFont = UIFont.systemFont(ofSize: 12)
        let metaFont = UIFont.systemFont(ofSize: 10)
        let imageMaxHeight: CGFloat = 560   // 单图高度上限（超出裁剪，防单图占满整页）

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { ctx in
            var y: CGFloat = margin
            func newPage() {
                ctx.beginPage()
                y = margin
            }
            func checkSpace(_ h: CGFloat) {
                if y + h > pageRect.height - margin { newPage() }
            }

            newPage()

            // 标题
            let titleStr = title.isEmpty ? "轻聊会话导出" : title
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont, .foregroundColor: UIColor.label
            ]
            let titleSize = (titleStr as NSString).boundingRect(
                with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: .usesLineFragmentOrigin, attributes: titleAttrs, context: nil
            )
            checkSpace(titleSize.height + 10)
            (titleStr as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: titleSize.height), withAttributes: titleAttrs)
            y += titleSize.height + 16

            for m in messages {
                let who = m.isUser ? "我" : "AI"
                let t = m.timestamp.map { ts -> String in
                    let d = Date(timeIntervalSince1970: ts / 1000)
                    let f = DateFormatter()
                    f.dateFormat = "MM-dd HH:mm"
                    return f.string(from: d)
                } ?? ""
                let metaStr = "[\(who) \(t)]"
                let metaAttrs: [NSAttributedString.Key: Any] = [
                    .font: metaFont, .foregroundColor: UIColor.secondaryLabel
                ]
                let metaSize = (metaStr as NSString).boundingRect(
                    with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    options: .usesLineFragmentOrigin, attributes: metaAttrs, context: nil
                )
                checkSpace(metaSize.height + 4)
                (metaStr as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: metaSize.height), withAttributes: metaAttrs)
                y += metaSize.height + 4

                var content = m.content
                let hasImage = m.imageDataURL != nil && !(m.imageDataURL ?? "").isEmpty
                if hasImage {
                    let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    content = c.isEmpty ? "[图片]" : c
                }
                let bodyAttrs: [NSAttributedString.Key: Any] = [
                    .font: bodyFont, .foregroundColor: UIColor.label
                ]
                if !content.isEmpty {
                    let bodySize = (content as NSString).boundingRect(
                        with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                        options: .usesLineFragmentOrigin, attributes: bodyAttrs, context: nil
                    )
                    checkSpace(bodySize.height + 12)
                    (content as NSString).draw(in: CGRect(x: margin, y: y, width: contentWidth, height: bodySize.height), withAttributes: bodyAttrs)
                    y += bodySize.height + 8
                }

                // v3.4.28：真图嵌入（dataURL 解码 → 等比缩放进版心；页尾放不下先换页）
                if hasImage, let img = dataURLImage(m.imageDataURL ?? "") {
                    let ratio = img.size.width > 0 ? img.size.height / img.size.width : 1
                    var drawW = contentWidth
                    var drawH = drawW * ratio
                    if drawH > imageMaxHeight {
                        drawH = imageMaxHeight
                        drawW = drawH / ratio
                    }
                    checkSpace(drawH + 14)
                    let imgRect = CGRect(x: margin + (contentWidth - drawW) / 2, y: y,
                                         width: drawW, height: drawH)
                    UIColor.secondarySystemBackground.setFill()
                    ctx.cgContext.fill(imgRect)
                    img.draw(in: imgRect)
                    y += drawH + 12
                } else if hasImage {
                    // 解码失败降级：占位文字（原行为）
                    checkSpace(20)
                    let ph = "[图片]" as NSString
                    ph.draw(at: CGPoint(x: margin, y: y), withAttributes: bodyAttrs)
                    y += 20
                }
                y += 4
            }
        }
    }
}

// MARK: - v3.4.28 会话导出文档（.html）——图片 base64 内嵌，浏览器打开即看

struct ChatHTMLDocument: FileDocument {
    var html: String
    static var readableContentTypes: [UTType] { [.html] }
    init(html: String) { self.html = html }
    init(configuration: ReadConfiguration) throws {
        html = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(html.utf8))
    }

    /// 从消息列表生成单文件 HTML（图片走原 dataURL 直接内嵌，零解码零转码）
    static func generate(title: String, messages: [ChatMessage]) -> String {
        var body: [String] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }
        for m in messages {
            let who = m.isUser ? "我" : "AI"
            let t = m.timestamp.map { df.string(from: Date(timeIntervalSince1970: $0 / 1000)) } ?? ""
            let cls = m.isUser ? "msg user" : "msg ai"
            var inner = ""
            if let img = m.imageDataURL, !img.isEmpty, img.hasPrefix("data:image/") {
                inner += "<img src=\"\(img)\" alt=\"图片\">"
            }
            let text = m.withdrawn ? "已撤回"
                : (m.audioPath != nil ? "[语音]" : m.content)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // AI 内容按 markdown 轻渲染（换行保底），防长段落挤成一坨
                let htmlText = esc(text)
                    .replacingOccurrences(of: "\n", with: "<br>")
                inner += "<p>\(htmlText)</p>"
            }
            body.append("<div class=\"\(cls)\"><div class=\"meta\">\(esc(who)) · \(esc(t))</div><div class=\"bubble\">\(inner)</div></div>")
        }
        return """
        <!DOCTYPE html>
        <html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(title.isEmpty ? "轻聊会话导出" : title))</title>
        <style>
        body{font-family:-apple-system,'PingFang SC',sans-serif;background:#f5f5f7;margin:0;padding:16px;max-width:680px;margin:0 auto;}
        h1{font-size:18px;color:#1d1d1f;}
        .msg{margin:12px 0;display:flex;flex-direction:column;}
        .meta{font-size:11px;color:#86868b;margin:0 4px 4px;}
        .bubble{background:#fff;border-radius:12px;padding:10px 14px;box-shadow:0 1px 2px rgba(0,0,0,.06);}
        .msg.user{align-items:flex-end;}
        .msg.user .bubble{background:#d6f5d6;}
        .bubble p{margin:0;font-size:14px;line-height:1.6;color:#1d1d1f;word-break:break-word;}
        .bubble img{max-width:100%;border-radius:8px;margin-top:6px;}
        </style></head><body>
        <h1>\(esc(title.isEmpty ? "轻聊会话导出" : title))</h1>
        \(body.joined(separator: "\n"))
        </body></html>
        """
    }
}

// MARK: - v2.0.87d markdown 表格视图（表头加粗 + 斑马纹 + 横向滚动）
// v2.0.87m：统一列宽（按每列最大内容宽度，列对齐不再错位）

private struct MarkdownTableView: View {
    let rows: [[String]]
    // v3.5.0：表格分享（CSV → 系统分享面板，Numbers/WPS/Excel 可直接导入）
    @State private var showShare = false
    @State private var csvURL: URL?

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
                HStack(alignment: .top, spacing: 0) {
                    // v3.5.0：分享按钮（低调半透明，与 CodeCopyButton 同款视觉语言）
                    Button {
                        csvURL = Self.makeCSV(rows: rows)
                        showShare = csvURL != nil
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.secondary)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CodeCopyButtonStyle())
                    .accessibilityLabel("导出表格")
                    tableGrid
                }
            }
            .padding(8)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.vertical, 2)
        }
        .textSelection(.enabled)
        .sheet(isPresented: $showShare) {
            if let csvURL {
                ActivityShareSheet(items: [csvURL])
            }
        }
    }

    /// 表格本体（拆出独立计算属性：分享按钮加入后避免 body 嵌套超 type-check 阈值）
    private var tableGrid: some View {
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
    }

    /// rows → CSV 临时文件（RFC 4180 转义：含逗号/引号/换行的字段加引号，引号翻倍）
    private static func makeCSV(rows: [[String]]) -> URL? {
        func esc(_ s: String) -> String {
            if s.contains(",") || s.contains("\"") || s.contains("\n") {
                return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return s
        }
        let csv = rows.map { $0.map(esc).joined(separator: ",") }.joined(separator: "\r\n")
        let dir = FileManager.default.temporaryDirectory
        let stamp = Int(Date().timeIntervalSince1970)
        let url = dir.appendingPathComponent("qingliao_table_\(stamp).csv")
        do {
            // BOM 头：Excel/WPS 直接打开 UTF-8 中文不乱码
            var data = Data([0xEF, 0xBB, 0xBF])
            data.append(Data(csv.utf8))
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
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
    func parseFileMessage(_ content: String) -> FileMessageInfo? {
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
    var title: String = "轻聊 AI 会话"   // v3.3.0：合并发送时自定义标题

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(title)
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
