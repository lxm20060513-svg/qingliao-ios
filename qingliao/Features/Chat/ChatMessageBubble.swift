// MARK: - MessageBubble + AIImageView（从 ChatComponents.swift 拆出）
import SwiftUI

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
    // v3.0.74：钉一钉（长按菜单钉到看板）——传当前段落/选中文字
    var onPin: ((String) -> Void)? = nil
    // v2.0.128：AI 消息内图片点击（传 URL/data URL，打开大图）
    var onAIImageTap: (String) -> Void = { _ in }
    // v3.3.0：多选合并转发——长按菜单「多选」入口（进入多选模式并预选本条）
    var onMultiSelect: () -> Void = {}
    // v3.0.15：AI 流式输出中——头像显示粒子球（orbits 流动），替代静态脑形标
    var streamingAvatar: Bool = false
    // v3.0.17：流式输出中 markdown 段用 SwiftUI Text 渲染（绕开 UITextView 流式锁窄布局 bug 家族）
    var streamingText: Bool = false
    // v2.0.38：聊天字体大小（设置页可调，实时生效）
    @AppStorage("qingliao_font_size") private var fontSize = 15.0   // v2.0.87r：默认15号
    // v2.0.128：AI 输出行高（设置页滑条，实时生效）
    @AppStorage("qingliao_ai_line_spacing") private var aiLineSpacing = 1.0
    // v2.0.65：深浅色气泡双色值 / 超长消息折叠
    @Environment(\.colorScheme) private var scheme
    // v2.0.130：AI 发图 MEDIA 路径 → 服务器图片 URL（读 App 配置的服务器地址）
    @AppStorage("qingliao_server") private var serverURL = ""
    // v2.0.81：AI 回复朗读状态（全局单例）
    @ObservedObject private var speech = SpeechManager.shared

    /// 用户气泡蓝：深色用深蓝，浅色用亮蓝（对比度适配）
    private var userBubbleColor: Color {
        BubbleTheme.userBubble(scheme: scheme, highlighted: isHighlighted)
    }
    /// AI 气泡灰：浅色模式更浅
    private var aiBubbleColor: Color {
        BubbleTheme.aiBubble(scheme: scheme, highlighted: isHighlighted)
    }

    /// v2.0.125：撤回条件（自己的消息 + 10 秒内 + 未撤回 + 未失败），菜单项按此显隐
    private var canWithdraw: Bool {
        if message.isUser, !message.withdrawn, !message.failed,
           let ts = message.timestamp {
            return Date().timeIntervalSince1970 - ts / 1000 < 10
        }
        return false
    }

    /// v2.0.125：图片/文件卡片的长按菜单（文字区由 UITextView 编辑菜单接管，不再走这里）
    @ViewBuilder
    private var cardMenu: some View {
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
        // v3.3.0：多选合并转发入口（图片/文件卡片长按菜单）
        Button {
            onMultiSelect()
        } label: {
            Label("多选", systemImage: "checkmark.circle")
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

    /// v3.0.15：AI 头像——流式输出中 = 粒子球（渐变底 + orbits 粒子流动），否则脑形标
    /// 拆独立计算属性：防止 body 巨型表达式 type-check 超时（v3.0.15 CI 实测）
    /// v3.0.16：头像粒子用定制大参数（默认参数按 300pt 基准缩放，30pt 下仅 ~0.2pt 不可见）
    @ViewBuilder
    private var aiAvatar: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
            if streamingAvatar {
                // v3.0.17：彩色粒子（亮蓝/紫/粉/白，深浅色模式都醒目），大参数保证 30pt 可见
                OrbCanvasView(mode: .orbits, size: 30,
                              opts: OrbOpts(orbitN: 8, ghostN: 26, ghostR: 2.8, ghostA: 0.9,
                                            particles: 4, partR: 3.4, partRDepth: 2.6,
                                            rsPow: 0.6, rMin: 0.9),
                              dotColors: [
                                Color(red: 0.55, green: 0.72, blue: 1.0),
                                Color(red: 0.65, green: 0.55, blue: 1.0),
                                Color(red: 1.0, green: 0.60, blue: 0.85),
                                .white
                              ])
                    .allowsHitTesting(false)
            } else {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 30, height: 30)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isUser {
                // v2.0.41：左侧留白 48→24，用户气泡更宽（右缘贴边）
                Spacer(minLength: 24)
            } else {
                aiAvatar
            }

            // v2.0.66：气泡主体（单 Shape 背景带尾巴，不再用 ZStack overlay）
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                    // v2.0.92：撤回消息 → 灰色"已撤回"占位（内容不再显示）
                    if message.withdrawn {
                        Text("已撤回")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    } else if let img = message.imageDataURL {
                        if img.hasPrefix("http") {
                            // v3.0.37：图片持久化 —— URL 图片（已上传 NAS）用 AsyncImage 加载
                            AIImageView(url: img)
                                .frame(maxWidth: 200, maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .onTapGesture { onImageTap() }
                                .contextMenu { cardMenu }
                        } else if let uiImg = dataURLImage(img) {
                            Image(uiImage: uiImg)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: 200, maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                // v2.0.36：点击查看大图
                                .onTapGesture { onImageTap() }
                                // v2.0.125：图片长按菜单（原气泡级菜单移到这里，不抢占文字长按）
                                .contextMenu { cardMenu }
                        }
                    }
                    if !message.content.isEmpty {
                        if message.isUser {
                            // v2.0.87q：文件消息微信风格卡片（图标+文件名+状态）
                            if let file = parseFileMessage(message.content) {
                                FileMessageCard(file: file)
                                    // v2.0.125：文件卡片长按菜单（原气泡级菜单移到这里）
                                    .contextMenu { cardMenu }
                            } else {
                                // v2.0.125：UITextView 渲染 —— 长按弹菜单（复制/引用/分享/大爆炸/选择文本/撤回/删除）
                                SelectableTextLabel(
                                    attributedText: NSAttributedString(string: message.content, attributes: [
                                        .font: UIFont.systemFont(ofSize: CGFloat(fontSize)),
                                        .foregroundColor: UIColor.white
                                    ]),
                                    fallbackColor: .white,
                                    lineSpacing: 3,
                                    onCopy: { UIPasteboard.general.string = message.content },
                                    onQuote: onQuote,
                                    onShare: onShare,
                                    onBigBang: onBigBang,
                                    onDelete: onDelete,
                                    onRegenerate: nil,
                                    onWithdraw: canWithdraw ? onWithdraw : nil,
                                    onMultiSelect: onMultiSelect
                                )
                            }
                        } else {
                                                    // v3.0.51：AI 长回复多气泡段落流式——按空行拆段，每段独立气泡，
                                                    // 完成段落稳定可读、末尾段落持续流式（用户感知持续在动）
                                                    // v4.0 fix：流式中跳过拆分（缓存全 miss → 白算 O(n)）
                                                    let paras = Self.splitParagraphs(message.content, streaming: streamingText)
                                                    if paras.count > 1 {
                                                        // 多气泡：每个段落一个独立气泡（贴左，头像在本气泡外右下角）
                                                        VStack(alignment: .leading, spacing: 6) {
                                                            ForEach(Array(paras.enumerated()), id: \.offset) { idx, para in
                                                                aiParagraphBubble(para,
                                                                                  isLast: idx == paras.count - 1,
                                                                                  streaming: streamingText)
                                                                    .transition(.opacity)
                                                            }
                                                        }
                                                    } else {
                                                        // 单段落 → 完整渲染（v3.1.1：去除超长回复折叠/省略号，全文可见）
                                                        VStack(alignment: .leading, spacing: 6) {
                                                                ForEach(0..<contentBlocks.count, id: \.self) { i in
                                                                    MessageBlockView(block: contentBlocks[i],
                                                                                    onCopy: { UIPasteboard.general.string = message.content },
                                                                                    onQuote: onQuote,
                                                                                    onShare: onShare,
                                                                                    onBigBang: onBigBang,
                                                                                    onDelete: onDelete,
                                                                                    onRegenerate: onRegenerate,
                                                                                    onWithdraw: nil,
                                                                                    onPin: onPin,
                                                                                    onImageTap: { url in onAIImageTap(url) },   // v2.0.128：AI 图片点击打开大图
                                                                                    onMultiSelect: onMultiSelect,   // v3.3.0：多选合并转发
                                                                                    useSwiftUIText: true,
                                                                                    streaming: streamingText)   // v3.0.41 性能：流式中纯 Text 渲染（跳过 markdown 解析）
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
                            // v3.0.19：语音指令触发的消息带 🎤 小标记
                            if message.voiceCommand {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 7.5))
                                    .foregroundStyle(.tertiary)
                            }
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
                    // v3.0.82：Hermes 主动推送标签（收件箱注入，蓝色系——区别于渐变 Agent 标签）
                    if message.isPush {
                        Text("🔔 推送")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.10), in: Capsule())
                            .padding(.top, 1)
                    }
                }
                .padding(.horizontal, isMultiBubbleAI ? 2 : 13)
                .padding(.vertical, isMultiBubbleAI ? 2 : 9)
                // v3.0.51：多气泡段落时外层不画整块气泡（每段各自带圆角底），否则段与段被外层包围成一大块
                .background(
                    Group {
                        if isMultiBubbleAI {
                            Color.clear
                        } else {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(message.withdrawn ? aiBubbleColor : (message.isUser ? userBubbleColor : aiBubbleColor))   // v2.0.92：撤回统一灰
                        }
                    }
                )
                // v2.0.43 搜索定位高亮边框
                .overlay(
                    Group {
                        if isMultiBubbleAI {
                            Color.clear
                        } else {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(isHighlighted ? Color.accentColor : .clear, lineWidth: 2)
                        }
                    }
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
        // v2.0.125：长按菜单按区域分发 —— 文字区由 SelectableTextLabel 的 UITextView 编辑菜单接管
        //（复制/引用/分享/大爆炸/选择文本/重新生成/撤回/删除）；图片/文件卡片挂 cardMenu；
        // 代码块/表格走 MessageBlockView 内部 SwiftUI 菜单。
        // ⚠️ 气泡级 contextMenu 会抢占 UITextView 长按手势（v2.0.122 实测 bug），必须移除。
    }

    /// 消息内容分段：``` 代码块 → 等宽深色块；其余 → markdown
    /// v3.0.41 性能：流式输出中跳过分段（split/图片展开都是 O(n) 全量扫描），直接单块渲染
    /// v3.0.x：加 LRU 缓存——同一 content+serverURL+streaming 组合不重复解析
    private var contentBlocks: [MessageContentBlock] {
        Self.blocksCached(for: message.content, serverURL: serverURL, streaming: streamingText)
    }

    /// 按段落(空行 \n\n)拆分——跳过 ``` 代码块内部空行，代码块整体不拆
    /// 供多气泡段落流式输出使用（v3.0.51）
    /// v3.0.x：加缓存——同一文本不重复拆分
    /// v4.0 fix：streaming 参数——流式中每帧文本不同，缓存全 miss → O(n) 白算；直接返回单段跳过
    private static func splitParagraphs(_ text: String, streaming: Bool = false) -> [String] {
        if streaming { return [text] }   // 流式中不做拆分（省 O(n) 全量扫描 + 缓存 miss）
        if let cached = _paraCache[text] { return cached }
        let lines = text.components(separatedBy: "\n")
        var paras: [String] = []
        var cur: [String] = []
        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if trimmed.isEmpty && !inFence {
                if !cur.isEmpty { paras.append(cur.joined(separator: "\n")); cur = [] }
            } else {
                cur.append(line)
            }
        }
        if !cur.isEmpty { paras.append(cur.joined(separator: "\n")) }
        let result = paras.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // 缓存：限制容量防内存膨胀（流式中同一 key 反复查，命中率极高）
        if _paraCache.count > 200 { _paraCache.removeAll() }
        _paraCache[text] = result
        return result
    }

    /// v3.0.x：blocks 缓存（key = content+serverURL+streaming 三元组哈希）
    private static func blocksCached(for text: String, serverURL: String, streaming: Bool) -> [MessageContentBlock] {
        let key = "\(text.hashValue)|\(serverURL)|\(streaming)"
        if let cached = _blocksCache[key] { return cached }
        let result = blocks(for: text, serverURL: serverURL, streaming: streaming)
        if _blocksCache.count > 200 { _blocksCache.removeAll() }
        _blocksCache[key] = result
        return result
    }

    // 静态缓存（View struct 每次 body 重建，static 持久化跨次评估）
    private static var _paraCache: [String: [String]] = [:]
    private static var _blocksCache: [String: [MessageContentBlock]] = [:]

    /// 指定文本的 markdown 分段渲染（v3.0.51：多气泡段落各自解析）
    private static func blocks(for text: String, serverURL: String, streaming: Bool) -> [MessageContentBlock] {
        if streaming {
            return [.init(kind: .markdown(text))]
        }
        let parts = Self.expandMediaMarks(text, serverURL: serverURL).components(separatedBy: "```")
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
        return blocks.isEmpty ? [.init(kind: .markdown(text))] : blocks
    }

    /// v3.0.51：AI 消息是否为「多气泡段落」渲染（>1 段且非图片消息）
    /// v3.0.x：复用缓存版 splitParagraphs
    /// v4.0 fix：流式中跳过拆分（splitParagraphs streaming 参数）
    private var isMultiBubbleAI: Bool {
        !message.isUser && message.imageDataURL == nil
            && Self.splitParagraphs(message.content, streaming: streamingText).count > 1
    }

    /// v3.0.51：多气泡的单个段落气泡——每段独立圆角底 + maxWidth 366（贴左）
    /// v3.0.59 fix：流式/非流式统一走 markdown 渲染（消除 SwiftUI Text 在流式气泡中截断显示 "…" 的 bug）
    @ViewBuilder
    private func aiParagraphBubble(_ para: String, isLast: Bool, streaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let pb = Self.blocks(for: para, serverURL: serverURL, streaming: false)
            ForEach(0..<pb.count, id: \.self) { i in
                MessageBlockView(block: pb[i],
                                onCopy: { UIPasteboard.general.string = para },
                                onQuote: onQuote,
                                onShare: onShare,
                                onBigBang: onBigBang,
                                onDelete: onDelete,
                                onRegenerate: onRegenerate,
                                onWithdraw: nil,
                                onPin: onPin,
                                onImageTap: { url in onAIImageTap(url) },
                                onMultiSelect: onMultiSelect,   // v3.3.0：多选合并转发
                                useSwiftUIText: true,
                                streaming: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(aiBubbleColor)
        )
        .frame(maxWidth: 366, alignment: .leading)
    }

    /// v2.0.130：AI 发图 —— Hermes 回复的 MEDIA:/路径 协议 → markdown 图片语法
    /// 转成 `![图片](<服务器>/api/stream/media?p=<base64url 容器路径>)`，
    /// 由 splitMarkdownImages 拆成图片块；服务器端该端点免鉴权只读图片。
    private static func expandMediaMarks(_ text: String, serverURL: String) -> String {
        guard text.contains("MEDIA:") else { return text }
        guard let re = try? NSRegularExpression(pattern: #"MEDIA:\s*([^\s\n]+)"#) else { return text }
        let ns = text as NSString
        var result = text
        var offset = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let rawPath = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !rawPath.isEmpty else { continue }
            // 容器路径 → base64url（服务器端映射 /opt/data → 宿主 hermes-data）
            let b64 = Data(rawPath.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let imgMarkdown = "![图片](\(serverURL)/api/stream/media?p=\(b64))"
            let fullRange = NSRange(location: m.range.location + offset, length: m.range.length)
            result = (result as NSString).replacingCharacters(in: fullRange, with: imgMarkdown)
            offset += imgMarkdown.count - m.range.length
        }
        return result
    }

    /// v2.0.87d：markdown 表格检测拆分（连续 | 行 → 表格块，其余保持 markdown）
    /// v2.0.128：非表格行内再拆出图片块（![alt](url)）——AI 直接发图
    private static func splitMarkdownTable(_ text: String) -> [MessageContentBlock.Kind] {
        let lines = text.components(separatedBy: "\n")
        var result: [MessageContentBlock.Kind] = []
        var table: [String] = []
        func flush() {
            if !table.isEmpty {
                if let rows = parseTable(table) {
                    result.append(.table(rows))
                } else {
                    result.append(contentsOf: splitMarkdownImages(table.joined(separator: "\n")))
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
                result.append(contentsOf: splitMarkdownImages(line))
            }
        }
        flush()
        return result
    }

    /// v2.0.128：行内拆出 markdown 图片语法 ![alt](url) → 图片块（URL 或 data URL），其余保持 markdown
    private static func splitMarkdownImages(_ line: String) -> [MessageContentBlock.Kind] {
        guard let re = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)\s]+)\)"#) else {
            return [.markdown(line)]
        }
        let ns = line as NSString
        let matches = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [.markdown(line)] }
        var result: [MessageContentBlock.Kind] = []
        var pos = 0
        for m in matches {
            if m.range.location > pos {
                let pre = ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
                if !pre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.markdown(pre))
                }
            }
            let url = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            result.append(.image(url))
            pos = m.range.location + m.range.length
        }
        if pos < ns.length {
            let tail = ns.substring(from: pos)
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(tail))
            }
        }
        return result.isEmpty ? [.markdown(line)] : result
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

// MARK: - v2.0.128 AI 直接发图（消息内图片渲染）

/// AI 回复中的图片：data URL 本地解码；http(s) URL 异步加载。
/// ⚠️ 加载链路必须兼容自签证书服务器（用户 NAS 就是）：URLSession 对外部公开图正常，
///    失败时降级 StreamHTTPClient（忽略证书链校验）——不能用纯 AsyncImage（自签证书必失败）。
/// 尺寸：圆角 12、最大宽 240、最大高 240（与原用户图片消息一致），点击由外层 onTapGesture 处理。
struct AIImageView: View {
    let url: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        if url.hasPrefix("data:image/") {
            // base64 data URL → 本地解码（复用 ImageCache）
            if let img = dataURLImage(url) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                placeholder
            }
        } else if let img = image {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if failed {
            placeholder
        } else {
            ProgressView()
                .frame(width: 240, height: 120)
                .task { await loadRemote() }
        }
    }

    /// 远程加载：URLSession 优先 → 失败降级 StreamHTTPClient（自签证书）
    @MainActor
    private func loadRemote() async {
        guard let u = URL(string: url), url.hasPrefix("http") else {
            failed = true
            return
        }
        // 0) 缓存命中直接显示
        if let cached = cachedRemoteImage(url) {
            image = cached
            return
        }
        // 1) URLSession（外部公开图，Ats 允许 https）
        if let (data, _) = try? await URLSession.shared.data(from: u),
           let img = UIImage(data: data) {
            setRemoteImageCache(url, img, cost: data.count)
            image = img
            return
        }
        // 2) 降级 CFStream 直连（自签证书服务器：忽略证书链校验）
        if let host = u.host, let scheme = u.scheme {
            let port = UInt16(u.port ?? (scheme == "https" ? 443 : 80))
            let path = u.path + (u.query.map { "?" + $0 } ?? "")
            let client = StreamHTTPClient()
            let result = await Task.detached(priority: .userInitiated) {
                try? client.request(host: host, port: port, isTLS: scheme == "https",
                                    method: "GET", path: path, headers: [:], body: nil, timeout: 15)
            }.value
            if let (data, code) = result, (200..<300).contains(code),
               let img = UIImage(data: data) {
                setRemoteImageCache(url, img, cost: data.count)
                image = img
                return
            }
        }
        failed = true
    }

    private var placeholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "photo")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("图片加载失败")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 200, height: 100)
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

