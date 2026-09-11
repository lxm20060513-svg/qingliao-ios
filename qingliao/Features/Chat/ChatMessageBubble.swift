// MARK: - MessageBubble + AIImageView（从 ChatComponents.swift 拆出）
import SwiftUI

// MARK: - 聊天页（微信风格：AI 灰气泡左侧 / 用户深蓝气泡右侧，头像在气泡外）

struct MessageBubble: View {
    let message: ChatMessage
    var isHighlighted: Bool = false   // v2.0.43 搜索定位高亮
    // v3.4.29：图片 zoom 转场命名空间（气泡小图 → 全屏大图生长）
    var zoomNS: Namespace.ID? = nil
    var onRegenerate: () -> Void = {}
    var onBigBang: (String) -> Void = { _ in }
    var onQuote: () -> Void = {}      // v2.0.36 引用回复
    var onDelete: () -> Void = {}     // v2.0.36 单条删除
    var onShare: () -> Void = {}      // v2.0.36 分享文本
    var onImageTap: () -> Void = {}   // v2.0.36 图片点击查看大图
    var onRetry: () -> Void = {}      // v2.0.59 发送失败重试
    var onWithdraw: () -> Void = {}   // v2.0.92 消息撤回（10 秒内）
    // v3.0.74：钉一钉（长按菜单钉到看板）——传当前段落/选中文字
    var onPin: ((String) -> Void)? = nil
    // v3.7.0：加入备忘录（长按菜单 / 气泡菜单）——传当前段落/整条内容
    var onMemo: ((String) -> Void)? = nil
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
    // v3.4.28：横屏自适应（气泡/图片宽度按宽屏放宽）
    @Environment(\.horizontalSizeClass) private var hSize
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
            UIPasteboard.general.string = displayContent   // v3.7.0：与渲染一致（老消息不再复制到进度行）
            Haptics.success()   // v3.4.25：复制成功触感
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        // v3.4.25：AI 回复中的地点一键开地图——从消息文本提取地址/地名，跳苹果地图（通用）；
        // 装了高德则优先高德（国内 POI 更准）。提取不到地址（无中文地名特征）时不显示此项
        if let addr = Self.extractAddress(from: displayContent) {
            Button {
                Self.openInMaps(address: addr)
            } label: {
                Label("在地图中打开「\(addr)」", systemImage: "mappin.and.ellipse")
            }
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
            onBigBang(displayContent)
        } label: {
            Label("大爆炸", systemImage: "burst.fill")
        }
        // v3.7.0：加入备忘录（整条气泡内容）
        if let onMemo {
            Button {
                onMemo(displayContent)
            } label: {
                Label("存备忘录", systemImage: "note.text")
            }
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
                    .font(.system(size: Typography.subhead, weight: .medium))
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
                    // v3.4.x：气泡内可视化引用块——长按「引用」后，用户气泡顶部显示被引用原文（微信式）
                    if let q = message.quotedText, !q.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "quote.opening")
                                .font(.system(size: Typography.tiny))
                                .foregroundStyle(Color.accentColor)
                            Text(q)
                                .font(.system(size: Typography.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(message.isUser ? .trailing : .leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
                    }
                    // v2.0.92：撤回消息 → 灰色"已撤回"占位（内容不再显示）
                    if message.withdrawn {
                        Text("已撤回")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    } else if let img = message.imageDataURL {
                        if img.hasPrefix("http") {
                            // v3.0.37：图片持久化 —— URL 图片（已上传 NAS）用 AsyncImage 加载
                            // v3.4.25：data URL 图片按气泡显示宽度下采样解码（≥100KB 大图省内存）
                            // v3.4.28：横屏放宽到 280
                            AIImageView(url: img, displayWidthPT: AdaptiveLayout.chatImageMax(hSize))
                                .frame(maxWidth: AdaptiveLayout.chatImageMax(hSize), maxHeight: AdaptiveLayout.chatImageMax(hSize))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .zoomSource(id: message.id, ns: zoomNS)   // v3.4.29：zoom 转场源
                                .onTapGesture { onImageTap() }
                                .contextMenu { cardMenu }
                        } else if let uiImg = dataURLImage(img, displayWidthPT: AdaptiveLayout.chatImageMax(hSize)) {
                            // v3.4.25：传气泡显示宽度 → ≥100KB 大图按 512/1024 档位下采样解码（内存不随原图像素放大）
                            Image(uiImage: uiImg)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: AdaptiveLayout.chatImageMax(hSize), maxHeight: AdaptiveLayout.chatImageMax(hSize))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .zoomSource(id: message.id, ns: zoomNS)   // v3.4.29：zoom 转场源
                                // v2.0.36：点击查看大图
                                .onTapGesture { onImageTap() }
                                // v2.0.125：图片长按菜单（原气泡级菜单移到这里，不抢占文字长按）
                                .contextMenu { cardMenu }
                        }
                    }
                    if !displayContent.isEmpty {
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
                                    onMultiSelect: onMultiSelect,
                                    onMemo: onMemo
                                )
                            }
                        } else {
                                                    // v3.0.51：AI 长回复多气泡段落流式——按空行拆段，每段独立气泡，
                                                    // 完成段落稳定可读、末尾段落持续流式（用户感知持续在动）
                                                    // v4.0 fix：流式中跳过拆分（缓存全 miss → 白算 O(n)）
                                                    // v3.6.5：流式中按「换行」拆行级小气泡（💭心跳/🔧工具行各自独立蹦出）——
                                                    // splitParagraphs 新增 lineMode：流式中按单换行拆，代价 O(n) 但流式内容短（<10KB）
                                                    let paras = Self.splitParagraphs(displayContent, streaming: streamingText, lineMode: streamingText)
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
                                                                                    onCopy: { UIPasteboard.general.string = displayContent },
                                                                                    onQuote: onQuote,
                                                                                    onShare: onShare,
                                                                                    onBigBang: onBigBang,
                                                                                    onDelete: onDelete,
                                                                                    onRegenerate: onRegenerate,
                                                                                    onWithdraw: nil,
                                                                                    onPin: onPin,
                                                                                    onMemo: onMemo,
                                                                                    onImageTap: { url in onAIImageTap(url) },   // v2.0.128：AI 图片点击打开大图
                                                                                    onMultiSelect: onMultiSelect,   // v3.3.0：多选合并转发
                                                                                    useSwiftUIText: true,
                                                                                    streaming: streamingText)   // v3.0.41 性能：流式中纯 Text 渲染（跳过 markdown 解析）
                                                                }
                                                            }
                                                    }
                                                }
                    }
                    // v2.0.59：发送失败 → 重试入口
                    // v3.4.25：微信式失败态——红色感叹号圆标 + 「消息未发出」+「点击重试」，整行可点
                    if message.isUser && message.failed {
                        Button {
                            onRetry()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: Typography.subhead))
                                    .foregroundStyle(.red)
                                Text("消息未发出")
                                    .font(.system(size: Typography.caption))
                                    .foregroundStyle(.secondary)
                                Text("点击重试")
                                    .font(.system(size: Typography.caption, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                    // v3.4.25：AI 错误占位 → 快捷重试行（红描边气泡下「重新生成」，免翻长按菜单）
                    if !message.isUser && message.isErrorPlaceholder {
                        Button {
                            onRegenerate()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: Typography.tiny, weight: .semibold))
                                Text("重新生成")
                                    .font(.system(size: Typography.caption, weight: .medium))
                            }
                            .foregroundStyle(.red.opacity(0.85))
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
                                    .font(.system(size: Typography.tiny))
                                    .foregroundStyle(.tertiary)
                            }
                            Image(systemName: message.queued ? "hourglass" : "checkmark")
                                .font(.system(size: Typography.tiny, weight: .bold))
                            Text(message.queued ? "排队中" : "已送达")
                                .font(.system(size: Typography.tiny))
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                    }
                    // v2.0.81：AI 消息朗读（点击播放/停止，中文 TTS）
                    // v3.4.x：播放中显示声波跳动动画（3 音柱 TimelineView 驱动），播完自动复原
                    if !message.isUser && !message.content.isEmpty {
                        Button {
                            SpeechManager.shared.toggle(displayContent, id: message.id)
                        } label: {
                            if speech.speakingID == message.id {
                                // v3.5.x：云端 TTS 不可用（额度/网络）自动降级系统语音时显示来源小标，
                                // 避免用户以为是「朗读没反应/没声音」
                                HStack(spacing: 3) {
                                // 播放中：3 根音柱跳动（10fps，低耗不卡渲染）
                                TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                                    let t = ctx.date.timeIntervalSinceReferenceDate
                                    HStack(spacing: 1.5) {
                                        ForEach(0..<3, id: \.self) { i in
                                            // 三根音柱相位错开，正弦起伏 3..11pt
                                            Capsule()
                                                .fill(Color.accentColor)
                                                .frame(width: 2, height: max(3, 7 + 4 * sin(t * 6 + Double(i) * 1.3)))
                                        }
                                    }
                                    .frame(height: 12)   // 固定高度防行高抖动
                                }
                                if speech.cloudDegraded {
                                    Text("系统")
                                        .font(.system(size: Typography.tiny))
                                        .foregroundStyle(.tertiary)
                                }
                                }
                                .padding(.top, 1)
                            } else {
                                Image(systemName: "speaker.wave.2")
                                    .font(.system(size: Typography.caption))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    // v3.4.x：移除「Agent 回复」标签——v3.4.8 起所有回复恒走 Hermes agent，
                    // 标注已无信息量（用户确认移除）。agent 字段链路保留（落库/推送兼容不动）。
                    // v3.0.82：Hermes 主动推送标签（收件箱注入，蓝色系）
                    if message.isPush {
                        Text("🔔 推送")
                            .font(.system(size: Typography.tiny, weight: .semibold))
                            .foregroundStyle(Color.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.10), in: Capsule())
                            .padding(.top, 1)
                    }
                    // v3.4.x 复读兜底：AI 回复与旧回复高度相似（换表述复述旧模板，去重/净化拦不住）
                    // → 显示可点提示，让用户一键重新生成换角度；不删内容不误伤语义。
                    if message.suspectedRepeat && !streamingText {
                        Button {
                            onRegenerate()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: Typography.tiny, weight: .semibold))
                                Text("疑似重复回复，点此重新生成")
                                    .font(.system(size: Typography.tiny, weight: .medium))
                            }
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 3)
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
                // v3.4.25：错误占位 → 红描边分层（错误一眼可辨，不再与正常回复同观感）
                .overlay(
                    Group {
                        if isMultiBubbleAI {
                            Color.clear
                        } else if message.isErrorPlaceholder {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(Color.red.opacity(0.55), lineWidth: 1.2)
                        } else {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(isHighlighted ? Color.accentColor : .clear, lineWidth: 2)
                        }
                    }
                )
            .frame(maxWidth: AdaptiveLayout.bubbleMaxWidth(hSize), alignment: message.isUser ? .trailing : .leading)   // v3.4.28 横屏自适应（竖屏仍 366）
            // v2.0.85c：气泡出现微动画（缩放 + 淡入，单条插入安全）
            .transition(.scale(scale: 0.94, anchor: message.isUser ? .trailing : .leading)
                .combined(with: .opacity))

            if message.isUser {
                // v2.0.65：用户头像（渐变圆 + 首字母，与 AI 头像对称）
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("Q")
                        .font(.system(size: Typography.subhead, weight: .bold))
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
    /// v3.7.0：实际渲染用文本——AI 的**已落库消息**先剥掉历史遗留的「进度行」。
    /// 流式中不过滤：一是后端 stream_api v3.7.0 起已不再注入进度行，二是流式每帧求值（省一次 O(n) 扫描）。
    private var displayContent: String {
        if message.isUser || streamingText { return message.content }
        return Self.strippingProgressLines(message.content)
    }

    /// v3.7.0：剥掉后端 v3.6.1/v3.6.4 注入的进度行（「🔧 工具名…」完成时补「 ✅」「💭 处理中 Ns」）。
    /// 后端已下线注入；这里只对**已落库的旧消息**兜底，避免老会话里仍冒出工具/心跳进度行。
    /// 只认**进度行形状**（见 isProgressLine），正文里正常出现的 🔧/💭 行不动；全文被剥光时保留原文防空气泡。
    static func strippingProgressLines(_ text: String) -> String {
        guard text.contains("🔧") || text.contains("💭") else { return text }   // 廉价门控：绝大多数消息直接返回
        let kept = text.components(separatedBy: "\n").filter { !isProgressLine($0) }
        let out = kept.joined(separator: "\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : out
    }

    /// v3.7.0：进度行形状判定——`🔧 工具名…` / `🔧 工具名… ✅` / `💭 处理中 12s`。
    /// ⚠️ 不要放宽成「以 🔧/💭 开头就删」：正文里可能出现带这两个 emoji 的正常行。
    private static func isProgressLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if t.hasPrefix("🔧") {
            return t.hasSuffix("…") || t.hasSuffix("✅") || t.contains("… ✅")
        }
        if t.hasPrefix("💭") {
            return t.contains("处理中")
        }
        return false
    }

    private var contentBlocks: [MessageContentBlock] {
        Self.blocksCached(for: displayContent, serverURL: serverURL, streaming: streamingText)
    }

    /// 按段落(空行 \n\n)拆分——跳过 ``` 代码块内部空行，代码块整体不拆
    /// 供多气泡段落流式输出使用（v3.0.51）
    /// v3.0.x：加缓存——同一文本不重复拆分
    /// v4.0 fix：streaming 参数——流式中每帧文本不同，缓存全 miss → O(n) 白算；直接返回单段跳过
    private static func splitParagraphs(_ text: String, streaming: Bool = false, lineMode: Bool = false) -> [String] {
        if streaming && !lineMode { return [text] }   // 流式中不做拆分（省 O(n) 全量扫描 + 缓存 miss）
        // v3.6.5 lineMode：流式中按单换行拆行级小气泡（💭/🔧行各自独立蹦出）。
        // 只在尾部保留未完成的最后一行持续增长；已完成的行 = 独立小气泡即时呈现。
        if lineMode {
            var lines = text.components(separatedBy: "\n")
            // 过滤空行与未完成行（最后一行可能正在写入，仍保留——它是"正在输出"的气泡）
            lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.isEmpty ? [text] : lines
        }
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
    /// v3.0.86 fix：代码块 fence 改逐行状态计数（原 components(separatedBy: "```") + i%2 假设
    /// fence 严格成对——AI 输出含单个不配对 ```（或行内以 ``` 开头未闭合）时，其后的整段 markdown
    /// 会被整体当代码块渲染：丢排版、等宽黑底）。现按行扫描：配对 fence 成代码块，fence 自带语言
    /// 标记（```lang 同行），不额外吞代码正文；结尾仍开着 fence（不配对）则按原文 markdown 处理
    private static func blocks(for text: String, serverURL: String, streaming: Bool) -> [MessageContentBlock] {
        // v3.5.0：Agent 结果卡片（```ql-card 围栏）——先做廉价门控，无标记 → 老路径逐字不变（零回归）
        if streaming {
            guard AgentCardParser.containsCardMarker(text) else {
                return [.init(kind: .markdown(text))]
            }
            // 有卡片标记：卡片感知切分——已闭合围栏 → 卡片；未闭合 / JSON 非法 → 文本（打字机继续逐字流，不出半截卡片）
            var out: [MessageContentBlock] = []
            for seg in AgentCardParser.parse(text) {
                switch seg {
                case .card(let card):
                    out.append(.init(kind: .agentCard(card)))
                case .text(let t):
                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out.append(.init(kind: .markdown(t)))
                    }
                }
            }
            return out.isEmpty ? [.init(kind: .markdown(text))] : out
        }
        guard AgentCardParser.containsCardMarker(text) else {
            return blocksPlain(for: text, serverURL: serverURL)
        }
        // 静态：卡片段走卡片渲染，其余文本段仍走原分段（代码块/表格/图片全保留）
        var out: [MessageContentBlock] = []
        for seg in AgentCardParser.parse(text) {
            switch seg {
            case .card(let card):
                out.append(.init(kind: .agentCard(card)))
            case .text(let t):
                if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                out.append(contentsOf: blocksPlain(for: t, serverURL: serverURL))
            }
        }
        return out.isEmpty ? blocksPlain(for: text, serverURL: serverURL) : out
    }

    /// v3.5.0：原 blocks 主体（卡片切分抽出后保留原名语义）——不改任何既有分段逻辑
    private static func blocksPlain(for text: String, serverURL: String) -> [MessageContentBlock] {
        let lines = Self.expandMediaMarks(text, serverURL: serverURL).components(separatedBy: "\n")
        var blocks: [MessageContentBlock] = []
        var mdBuf: [String] = []        // 当前 markdown 段（未进 fence 的行）
        var codeBuf: [String] = []      // 当前代码块内容（fence 内的行）
        var codeLang: String? = nil     // v3.4.x：fence 语言标记（```lang）——语法高亮用
        var openFenceLine = ""          // 未配对兜底时恢复原文用
        var inFence = false

        func flushMarkdown() {
            let seg = mdBuf.joined(separator: "\n")
            mdBuf = []
            if !seg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // v2.0.87d：markdown 段内拆出表格块（| a | b | + 分隔行）
                for k in Self.splitMarkdownTable(seg) {
                    blocks.append(.init(kind: k))
                }
            }
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    // 关闭 fence：收集行成代码块
                    inFence = false
                    let body = codeBuf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    codeBuf = []
                    if !body.isEmpty {
                        blocks.append(.init(kind: .code(body, codeLang)))
                    }
                    codeLang = nil
                } else {
                    // 打开 fence：先落 markdown 段，记录 fence 行原文（未配对兜底）；提取语言标记
                    flushMarkdown()
                    inFence = true
                    openFenceLine = line
                    codeBuf = []
                    codeLang = Self.fenceLanguage(line)
                }
            } else if inFence {
                codeBuf.append(line)
            } else {
                mdBuf.append(line)
            }
        }
        if inFence {
            // 结尾仍开着 fence（不配对）→ 按原文处理，不当代码块渲染
            mdBuf = [openFenceLine] + codeBuf
            codeBuf = []
        }
        flushMarkdown()
        return blocks.isEmpty ? [.init(kind: .markdown(text))] : blocks
    }

    /// v3.4.x：提取 fence 行尾部的语言标记（```swift / ```python 等），规范化小写。
    /// 用于代码块语法高亮；无标记或非已知语言返回 nil（走纯等宽字渲染）。
    private static func fenceLanguage(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("```") else { return nil }
        let lang = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
        guard !lang.isEmpty else { return nil }
        return lang.lowercased()
    }

    /// v3.0.51：AI 消息是否为「多气泡段落」渲染（>1 段且非图片消息）
    /// v3.0.x：复用缓存版 splitParagraphs
    /// v4.0 fix：流式中跳过拆分（splitParagraphs streaming 参数）
    private var isMultiBubbleAI: Bool {
        !message.isUser && message.imageDataURL == nil
            // v3.7.0：与渲染同源（displayContent）——否则含历史进度行的消息会"按多气泡留白、却渲单气泡"
            && Self.splitParagraphs(displayContent, streaming: streamingText, lineMode: streamingText).count > 1
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
                                onBigBang: { onBigBang($0) },
                                onDelete: onDelete,
                                onRegenerate: onRegenerate,
                                onWithdraw: nil,
                                onPin: onPin,
                                onMemo: onMemo,
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
        .frame(maxWidth: AdaptiveLayout.bubbleMaxWidth(hSize), alignment: .leading)
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

    // MARK: - v3.4.25 AI 回复地点一键开地图

    /// 从消息文本提取地址/地名：优先取「地址/位于/坐标附近」等引导词后的片段，
    /// 兜底取第一条含「路|街|区|县|市|省|大厦|广场|中心|店|餐厅|咖啡」的行前 30 字。
    /// 提取不到（纯代码/闲聊）返回 nil，菜单不显示地图项。
    static func extractAddress(from text: String) -> String? {
        let leadWords = ["地址：", "地址:", "位于", "坐落在", "地图：", "位置：", "位置:"]
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            for w in leadWords {
                if let r = t.range(of: w) {
                    let seg = String(t[r.upperBound...]).prefix(30)
                    if seg.count >= 2 { return String(seg) }
                }
            }
        }
        let poiKeys = ["路", "街", "大道", "区", "县", "市", "省", "大厦", "广场", "购物中心", "门店", "餐厅", "咖啡"]
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count >= 3, t.count <= 60,
                  !t.hasPrefix("#"), !t.hasPrefix("|"), !t.contains("```") else { continue }
            if poiKeys.contains(where: { t.contains($0) }) {
                return String(t.prefix(30))
            }
        }
        return nil
    }

    /// 打开地图 App 查询地址：装了高德走高德（国内 POI 更准），否则苹果地图（系统自带必有）
    static func openInMaps(address: String) {
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? address
        // 高德 URL Scheme：iosamap://path?dname=xxx&mode=route&src=qingliao
        if let amap = URL(string: "iosamap://path?dname=\(encoded)&mode=route&src=qingliao"),
           UIApplication.shared.canOpenURL(amap) {
            UIApplication.shared.open(amap)
            return
        }
        // 苹果地图通用链接（无需 info.plist 白名单）
        if let apple = URL(string: "https://maps.apple.com/?q=\(encoded)"),
           UIApplication.shared.canOpenURL(apple) {
            UIApplication.shared.open(apple)
        }
    }

}

// MARK: - v2.0.128 AI 直接发图（消息内图片渲染）

/// AI 回复中的图片：data URL 本地解码；http(s) URL 异步加载。
/// ⚠️ 加载链路必须兼容自签证书服务器（用户 NAS 就是）：URLSession 对外部公开图正常，
///    失败时降级 StreamHTTPClient（忽略证书链校验）——不能用纯 AsyncImage（自签证书必失败）。
/// 尺寸：圆角 12、最大宽 240、最大高 240（与原用户图片消息一致），点击由外层 onTapGesture 处理。
struct AIImageView: View {
    let url: String
    // v3.4.25：显示宽度(pt)——≥100KB 大图 dataURL 按此宽度下采样解码（512/1024 档），默认 240（气泡图上限）
    var displayWidthPT: CGFloat = 240
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        if url.hasPrefix("data:image/") {
            // base64 data URL → 本地解码（复用 ImageCache）；v3.4.25：按显示宽度下采样
            if let img = dataURLImage(url, displayWidthPT: displayWidthPT) {
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
                .font(.system(size: Typography.titleXL))
                .foregroundStyle(.secondary)
            Text("图片加载失败")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 200, height: 100)
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

