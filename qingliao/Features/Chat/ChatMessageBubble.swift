// MARK: - MessageBubble + AIImageView（从 ChatComponents.swift 拆出）
import SwiftUI

// MARK: - 聊天页（微信风格：AI 灰气泡左侧 / 用户深蓝气泡右侧，头像在气泡外）

// MARK: - 流式气泡（v3.9.40 #3：从 ChatView 的计算属性拆出）
//
// 为什么必须独立成 View：@Observable 的依赖是按「哪个 body 读了哪个属性」记录的。
// 原来 `stream.displayContent` 写在 ChatView 的计算属性里，这笔读记到了 **ChatView.body** 上，
// 而平滑层每 48ms 就写一次 smoothedContent（StreamClient.startSmooth）→ 整个 LazyVStack 消息列表
// 跟着重画 20 次/秒。读收到本子 View 后，每 tick 的失效范围只剩这一条气泡。
struct StreamingBubbleView: View {
    @Environment(StreamClient.self) private var stream
    var onAIImageTap: (String) -> Void = { _ in }
    var onFileTap: (String, String) -> Void = { _, _ in }
    /// v4.0.39：首帧浮现用的一次性开关。为什么不靠 .transition：
    /// 这条气泡的插入由 `stream.isStreaming` 翻转驱动，而那个写入发生在 StreamClient 的网络
    /// 回调里、**没有 withAnimation 事务**（本仓的插入动画事务只包在 ChatStore.append /
    /// upsertAssistant 里），transition 在无事务时不会播放 → 必须自己带动画上下文。
    @State private var born = false
    /// v4.0.39：开「降低动态效果」时首帧直接落终态，不播浮现（与 TypingIndicator 同口径）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MessageBubble(
            // v3.4.20：读 displayContent（打字机平滑层）——本地/云端流式观感从"整段跳变"变"逐字流"
            message: ChatMessage(role: "assistant", content: stream.displayContent, timestamp: nil, agent: stream.isAgent),
            onAIImageTap: onAIImageTap,   // v2.0.128：流式中 AI 图片可点
            onFileTap: onFileTap,         // v3.9.17：流式中 AI 生成物可点
            streamingAvatar: true,   // v3.0.15：AI 输出中头像 = 粒子球
            streamingText: true,   // v3.0.17：流式长文用 SwiftUI Text 渲染（根治 UITextView 锁窄缩小）
            streamingSweep: true   // v4.0.39：流式期间气泡内 3.5% 极淡下扫光带（声明序在 streamingText 之后）
        )
        // v4.0.39：①首帧淡入 + 上浮 8pt（「长出来」，比用户发送气泡克制；Motion.enter 的过冲
        // 让它不显生硬）。挂在 MessageBubble 之外，内部排版/几何一概不动。
        .opacity(born ? 1 : 0)
        .offset(y: born ? 0 : 8)
        .onAppear {
            if reduceMotion { born = true } else { withAnimation(Motion.streamBorn) { born = true } }
        }
        // v4.0.39（审查建议⑥）：逐轮复位。answer 中途重连/recover 时 StreamClient.start 会把
        // content 清空 → 三点行 ↔ 流式气泡互换 → 本视图重建；不按轮次复位就会出现「回答中途冒一次淡入」。
        // startSeq 每轮必变，是这仓认定的「开跑语义」唯一可靠信号（与 typingBorn 同款复位点）。
        .onChange(of: stream.startSeq) {
            if reduceMotion { born = true } else { withAnimation(Motion.streamBorn) { born = false } }
        }
        // v3.9.30：流式增量落进同一气泡 → 高度/排版变化走 settle 平滑生长（原瞬跳）
        .animation(Motion.settle, value: stream.displayContent)
    }
}

// MARK: - v4.0.39 流式下扫光带
//
// 一道 3.5% 不透明度的柔光带，1.2s 单程在气泡内自上而下循环扫过（v4.0.39 用户要求「流式输出气泡动画」）。
// 三个刻意的取舍：
//  ① 驱动用 .offset + repeatForever（不是 TimelineView）：offset 改 transform、走 Core Animation，
//     不引第二套墙钟；光带被系统判定「无动画活动」而冻结的风险已由 Motion.streamSweepOpacity
//     压到 3.5% 可无视（同本仓三点动画 v4.0.12/v4.0.19 三次翻车的同源坑，本轮不复现）。
//  ② 不用 .ultraThinMaterial（反光过强、像蒙了一层玻璃）→ 改用三段白渐变硬边淡出。
//  ③ 只在单气泡模式挂：多气泡段落时每段自带圆角底，一条横贯的光带会把段落割成条纹（挂载点见 MessageBubble）。
struct StreamSweepBand: View {
    /// 光带宽（pt）：窄到只读作「一道扫过」，不至于像进度条。
    private let bandWidth: CGFloat = 56
    /// 单程位移的**下限**（pt）。绝大多数 AI 气泡高度 < 300pt，实测值取几何实测高度再加一个带宽：
    /// 硬编码 320 的问题是带代码块/表格的长回复轻易超过 320pt —— 那时首帧 +320 仍落在可视区内，
    /// 光带会从气泡中部凭空开始扫（v4.0.39 审查建议③）。
    /// 用 GeometryReader 已有的 geo.size.height 取实高，不额外读一次布局。
    private let travelFloor: CGFloat = 320

    @State private var sweeping = false

    var body: some View {
        // ⚠️ 首帧 sweeping=false → 光带停在气泡下方（被 clip 裁掉，看不见）；
        //    onAppear 写 true 触发 repeatForever。没这一下它会从气泡中间凭空开始扫。
        GeometryReader { geo in
            // 实测高度 + 一个带宽：保证光带两端完全在气泡外（首帧与末帧都被 clip 裁掉），
            // 无论气泡多高 —— 高于 320 的长回复（代码块/表格）也不会从中间冒出来。
            // ⚠️ 用内联 max 表达式而非闭包内 `let travel`（少一个局部声明，避开 ViewBuilder
            // 里局部变量的解析歧义；swiftc -parse 本地验不出这类，得 CI 才知）。
            LinearGradient(
                colors: [.white.opacity(0), .white.opacity(1), .white.opacity(0)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: bandWidth)
            .rotationEffect(.degrees(18))   // 轻微斜切，像手扫过而非贴纸平移
            .offset(y: sweeping ? -max(travelFloor, geo.size.height + bandWidth)
                                : max(travelFloor, geo.size.height + bandWidth))
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .opacity(Motion.streamSweepOpacity)
        .animation(
            .easeInOut(duration: Motion.streamSweepDuration).repeatForever(autoreverses: true),
            value: sweeping
        )
        .onAppear { sweeping = true }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var isHighlighted: Bool = false   // v2.0.43 搜索定位高亮
    // v3.4.29：图片 zoom 转场命名空间（气泡小图 → 全屏大图生长）
    var zoomNS: Namespace.ID? = nil
    /// v4.0.44 待做池 3：编辑已发消息（改口重答）——nil = 长按菜单里没有「编辑」。
    /// ⚠️ 声明位置必须在**所有尾随闭包实参之前**：只有最后一条 user 消息才传非 nil，
    ///    「条件为 nil」只能出现在括号实参里（SE-0286 尾随闭包后不能再插非闭包实参），
    ///    所以 ChatView 把它传在 zoomNS 之后、trailing closures 之前。
    var onEdit: (() -> Void)? = nil
    var onRegenerate: () -> Void = {}
    var onBigBang: (String) -> Void = { _ in }
    var onQuote: () -> Void = {}      // v2.0.36 引用回复
    // v3.9.58c：点气泡内引用块 → 滚动定位到被引用的原消息并高亮（微信式）
    // ⚠️ 声明位置 = ChatView 调用点的闭包序（紧跟 onQuote）；Swift 要求带标签的尾随闭包按声明序传，
    //    挪到 onAIImageTap 之后会直接编译失败（本次 CI 首个真因之一）。
    var onQuoteTap: () -> Void = {}
    var onDelete: () -> Void = {}     // v2.0.36 单条删除
    var onShare: () -> Void = {}      // v2.0.36 分享文本
    var onImageTap: () -> Void = {}   // v2.0.36 图片点击查看大图
    var onRetry: () -> Void = {}      // v2.0.59 发送失败重试
    var onWithdraw: () -> Void = {}   // v2.0.92 消息撤回（10 秒内）
    // v3.0.74：钉一钉（长按菜单钉到看板）——传当前段落/选中文字
    var onPin: ((String) -> Void)? = nil
    // v3.7.0：加入备忘录（长按菜单 / 气泡菜单）——传当前段落/整条内容
    var onMemo: ((String) -> Void)? = nil
    // v3.9.35：加入待办（长按菜单）——传当前段落/整条内容
    var onTodo: ((String) -> Void)? = nil
    // v4.0.25：存为长期目标（长按菜单）——传当前段落/整条内容
    var onGoal: ((String) -> Void)? = nil
    // v3.9.32：定时提醒（长按菜单「提醒我」）——传当前段落/整条内容
    var onRemind: ((String) -> Void)? = nil
    // v3.9.86：长回复阅读（长按菜单「全屏阅读」→ LongReplySheet 半屏放大 + 章节大纲）
    var onRead: ((String) -> Void)? = nil
    // v2.0.128：AI 消息内图片点击（传 URL/data URL，打开大图）
    var onAIImageTap: (String) -> Void = { _ in }
    // v3.9.17：AI 生成物点击（传 URL + 显示名 → QuickLook 预览）
    var onFileTap: (String, String) -> Void = { _, _ in }
    // v3.3.0：多选合并转发——长按菜单「多选」入口（进入多选模式并预选本条）
    var onMultiSelect: () -> Void = {}
    // v3.9.74 P2.6：plan 卡「继续下一步」——下一未完成步骤作为用户消息发回（nil = 只读）
    var onContinueStep: ((String) -> Void)? = nil
    /// v3.9.110：问题卡作答回调（传用户答案原文）。nil = 只读渲染 —— 会话导出/预览等
    /// 没有宿主回调的路径自动退回只读（同 onContinueStep 的门控口径）。
    /// ⚠️ 声明位置必须紧跟 onContinueStep 且调用点也传在同一位（实参序 = 声明序，见技能 swiftui-param-order）。
    var onAnswerQuestion: ((String) -> Void)? = nil
    // v4.0.11：主动 Agent 消息的「有用/没用」反馈（传 verdict: adopted/ignored）。
    // nil = 只读渲染（无宿主回调的路径不显示反馈条）。
    var onProactiveFeedback: ((String, String) -> Void)? = nil
    // v3.0.15：AI 流式输出中——头像显示粒子球（orbits 流动），替代静态脑形标
    var streamingAvatar: Bool = false
    // v3.0.17：流式输出中 markdown 段用 SwiftUI Text 渲染（绕开 UITextView 流式锁窄布局 bug 家族）
    var streamingText: Bool = false
    /// v4.0.39：流式期间在气泡内走一道极淡的下扫光带（v4.0.39 用户要求「流式输出气泡动画」）。
    /// ⚠️ 声明序铁律：本参数必须排在 streamingText **之后** —— StreamingBubbleView 的调用点
    ///    是按声明序传标签实参（streamingAvatar: → streamingText: → 本参数），挪位即编译失败。
    var streamingSweep: Bool = false
    /// v4.0.81：长按气泡（文字 / 图片 / 文件卡 / 代码块 / 表格 / agent 卡）→ 交由宿主 ChatView
    /// 弹出**锚定胶囊菜单**（与右上角三点菜单同一组件、同一排布）。传整条消息文本。
    /// ⚠️ 声明序铁律：本参数排在最末，调用点也传在最末（见技能 swiftui-param-order）。
    var onLongPressMenu: ((String) -> Void)? = nil

    /// 卡片区的长按动作（nil = 不挂手势）。`displayContent` 与渲染一致（老消息不含进度行）。
    private var longPressAction: (() -> Void)? {
        guard let onLongPressMenu else { return nil }
        return { onLongPressMenu(displayContent) }
    }
    // v2.0.38：聊天字体大小（设置页可调，实时生效）
    @AppStorage("qingliao_font_size") private var fontSize = 15.0   // v2.0.87r：默认15号
    // v2.0.128：AI 输出行高（设置页滑条，实时生效）
    @AppStorage("qingliao_ai_line_spacing") private var aiLineSpacing = 1.0
    // v3.4.28：横屏自适应（气泡/图片宽度按宽屏放宽）
    @Environment(\.horizontalSizeClass) private var hSize
    // v4.0.39：开「降低动态效果」时不挂流式光带（与 TypingIndicator / AIImageView 同口径）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    private var canWithdraw: Bool { Self.canWithdraw(message) }

    /// v4.0.81（审查修）：撤回条件提成**静态判据** —— 长按菜单（ChatView.bubbleMenuItems）与气泡按钮
    /// 共用同一份口径，免得新菜单漏守卫（同一批就漏过一次：对 AI 回复也能点「撤回」）。
    static func canWithdraw(_ message: ChatMessage) -> Bool {
        if message.isUser, !message.withdrawn, !message.failed,
           let ts = message.timestamp {
            return Date().timeIntervalSince1970 - ts / 1000 < 10
        }
        return false
    }

    /// v2.0.125：图片/文件卡片的长按菜单（文字区由 UITextView 编辑菜单接管，不再走这里）
    /// v4.0.76：图标对齐用户气泡菜单（v4.0.70 方案 C 彩色圆角块 + 白符号）——原来这里
    /// 是裸 SF Symbol 黑白图标，与用户气泡/文字段的 tile 色块图标两副面孔。
    @ViewBuilder
    private var cardMenu: some View {
        Button {
            UIPasteboard.general.string = displayContent   // v3.7.0：与渲染一致（老消息不再复制到进度行）
            Haptics.success()   // v3.4.25：复制成功触感
        } label: {
            Label { Text("复制") } icon: { Image(uiImage: MenuIconTile.small("doc.on.doc", .blue)) }
        }
        // v3.4.25：AI 回复中的地点一键开地图——从消息文本提取地址/地名，跳苹果地图（通用）；
        // 装了高德则优先高德（国内 POI 更准）。提取不到地址（无中文地名特征）时不显示此项
        if let addr = Self.extractAddress(from: displayContent) {
            Button {
                Self.openInMaps(address: addr)
            } label: {
                Label { Text("在地图中打开「\(addr)」") } icon: { Image(uiImage: MenuIconTile.small("mappin.and.ellipse", .teal)) }
            }
        }
        Button {
            onQuote()
        } label: {
            Label { Text("引用") } icon: { Image(uiImage: MenuIconTile.small("quote.opening", .blue)) }
        }
        Button {
            onShare()
        } label: {
            Label { Text("分享") } icon: { Image(uiImage: MenuIconTile.small("square.and.arrow.up", .blue)) }
        }
        // v3.3.0：多选合并转发入口（图片/文件卡片长按菜单）
        Button {
            onMultiSelect()
        } label: {
            Label { Text("多选") } icon: { Image(uiImage: MenuIconTile.small("checkmark.circle", .teal)) }
        }
        Button {
            onBigBang(displayContent)
        } label: {
            Label { Text("大爆炸") } icon: { Image(uiImage: MenuIconTile.small("burst", .teal)) }
        }
        // v3.7.0：加入备忘录（整条气泡内容）
        if let onMemo {
            Button {
                onMemo(displayContent)
            } label: {
                Label { Text("存备忘录") } icon: { Image(uiImage: MenuIconTile.small("note.text", .purple)) }
            }
        }
        // v4.0.25：存为长期目标（整条气泡内容）
        if let onGoal {
            Button {
                onGoal(displayContent)
            } label: {
                Label { Text("存为长期目标") } icon: { Image(uiImage: MenuIconTile.small("target", .purple)) }
            }
        }
        // v3.9.35：加入待办（整条气泡内容）
        if let onTodo {
            Button {
                onTodo(displayContent)
            } label: {
                Label { Text("加入待办") } icon: { Image(uiImage: MenuIconTile.small("checklist", .purple)) }
            }
        }
        // v3.9.32：提醒我（整条气泡内容 → 本地定时提醒面板）
        if let onRemind {
            Button {
                onRemind(displayContent)
            } label: {
                Label { Text("提醒我") } icon: { Image(uiImage: MenuIconTile.small("bell.badge", .orange)) }
            }
        }
        if !message.isUser {
            Button {
                onRegenerate()
            } label: {
                Label { Text("重新生成") } icon: { Image(uiImage: MenuIconTile.small("arrow.clockwise", .orange)) }
            }
        }
        if canWithdraw {
            Button {
                onWithdraw()
            } label: {
                Label { Text("撤回") } icon: { Image(uiImage: MenuIconTile.small("arrow.uturn.backward", .orange)) }
            }
        }
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label { Text("删除") } icon: { Image(uiImage: MenuIconTile.small("trash", .red)) }
        }
    }

    // v4.0.31：AI 头像已删（用户拍板「取消 AI 头像和我的头像」，气泡近满宽）。
    // 历史口径备查：v3.9.2 AI 头像=液态球、v3.9.78 改卡通宠物 30pt；v4.0.31 起气泡行不再挂头像，
    // streamingAvatar 参数保留（流式渲染分支仍用它，不再驱动任何头像）。

    var body: some View {
        // v3.9.110：问题卡（AI 中途追问）走独立渲染；其余消息逐字走原链（normalBubbleBody）。
        // 只加一个早退分支，不动原链里的任何修饰符 —— ChatView.body 与这里的链都已贴近
        // Swift 类型检查阈值，别顺手往两边挂东西。
        if message.edited {
            // v4.0.44 待做池 3：被改口取代的旧回答 —— 折叠为「已修改」灰气泡
            editedBubbleBody
        } else if message.questionId != nil {
            questionCardBody
        } else {
            normalBubbleBody
        }
    }

    /// v4.0.44 待做池 3：折叠态气泡（用户拍板方案 1「复用现有灰气泡」）——
    /// 观感与「撤回」同款（同灰底、同内边距、同限宽），只靠文案区分语义：
    /// 撤回 = 内容不存在了；已修改 = 内容被基于新原文的新回答取代。
    /// 独立成一条早退分支（不塞进 normalBubbleBody）的原因：折叠态**不该**再挂正文/候选/待办确认卡/
    /// 朗读/送达行，逐个加 `!edited` 条件既啰嗦又容易漏（漏一个就把已被取代的旧内容漏出来）。
    @ViewBuilder
    private var editedBubbleBody: some View {
        HStack(alignment: .top, spacing: 8) {
            bubbleLeadingAccessory
            Text(MessageEditKit.editedLabel)
                .font(.system(size: CGFloat(fontSize)))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .frame(maxWidth: AdaptiveLayout.bubbleMaxWidth(hSize), alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                        .fill(aiBubbleColor)   // v2.0.92：与撤回统一灰（v4.0.66：撤回/已修改占位不改渐变，保持低调）
                )
            bubbleTrailingAccessory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// v3.9.110：问题卡本体 —— AI 头像 / 右侧留白 / 限宽全部复用与普通回复**同一套附件**
    ///（观感必须与 AI 气泡对齐：同一列、同一边距、同一头像），卡体本身在 ChatQuestionCard。
    @ViewBuilder
    private var questionCardBody: some View {
        HStack(alignment: .top, spacing: 8) {
            bubbleLeadingAccessory
            ChatQuestionCard(message: message, onAnswer: onAnswerQuestion, onDelete: onDelete)
                .frame(maxWidth: AdaptiveLayout.bubbleMaxWidth(hSize), alignment: .leading)
            bubbleTrailingAccessory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 普通气泡本体（v3.9.110：从 body 原样搬出，视图顺序/层级/条件/修饰符**逐字未变**，
    /// 只为给问题卡让出上面的早退分支）
    /// v4.0.25：改 @ViewBuilder——气泡行之外挂了待办确认卡（条件视图需要 builder）
    @ViewBuilder
    private var normalBubbleBody: some View {
        HStack(alignment: .top, spacing: 8) {
            bubbleLeadingAccessory

            // v2.0.66：气泡主体（单 Shape 背景带尾巴，不再用 ZStack overlay）
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                    bubbleQuotedBlock
                    bubbleMediaBlock
                    bubbleContentBody
                    bubbleRetryRow
                    bubbleRegenerateRow
                    bubbleDeliveryRow
                    bubbleSpeakButton
                    bubblePushTag
                    bubbleProactiveFeedback
                }
                .padding(.horizontal, isMultiBubbleAI ? 2 : 13)
                .padding(.vertical, isMultiBubbleAI ? 2 : 9)
                // v3.0.51：多气泡段落时外层不画整块气泡（每段各自带圆角底），否则段与段被外层包围成一大块
                .background(
                    Group {
                        if isMultiBubbleAI {
                            Color.clear
                        } else if message.withdrawn {
                            // v2.0.92：撤回统一灰（渐变化后仍走原 aiBubbleColor，不跟气泡主色变）
                            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                                .fill(aiBubbleColor)
                        } else if message.isUser {
                            // v4.0.66 A+C 定稿：用户气泡换蓝→紫渐变（EnvironmentGradient.userBubbleGradient，
                            // 浅色 #4DA3FF→#7A5CFF / 深色 #3B82E0→#6A4FD8）；高亮态保留原 userBubbleColor
                            // （搜索定位的语义色不动）。任意ShapeStyle 包装让两条分支同类型。
                            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                                .fill(isHighlighted
                                      ? AnyShapeStyle(userBubbleColor)
                                      : AnyShapeStyle(EnvironmentGradient.userBubbleGradient(scheme)))
                        } else {
                            // v4.0.81 方案3：AI 气泡换**玻璃厚边**（与全站卡片同一出口）——
                            // 材质底 + 半透明叠层 + 1pt 渐变厚边，色值全走 EnvironmentGradient 真源。
                            // 撤回/编辑占位仍走原灰；高亮态保留原 aiBubbleColor（搜索定位语义色不动）。
                            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                                .fill(isHighlighted
                                      ? AnyShapeStyle(aiBubbleColor)
                                      : AnyShapeStyle(Material.ultraThinMaterial))
                                .overlay {
                                    if !isHighlighted {
                                        RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                                            .fill(EnvironmentGradient.cardGlassFill(scheme))
                                    }
                                }
                                .overlay {
                                    if !isHighlighted {
                                        RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                                            .strokeBorder(EnvironmentGradient.cardEdgeGradient(scheme),
                                                          lineWidth: 1)
                                    }
                                }
                        }
                    }
                )
                // v4.0.81 方案3：柔影走全站单一真源（浅 黑 0.10/r22/y8 · 深 黑 0.60/r22/y8）。
                // 只挂 AI 气泡；用户气泡渐变自带饱和度，不加影保持轻量。纯视觉层。
                .glassCardShadow(scheme,
                                 enabled: !message.isUser && !message.withdrawn && !isMultiBubbleAI)
                // v2.0.43 搜索定位高亮边框
                // v3.4.25：错误占位 → 红描边分层（错误一眼可辨，不再与正常回复同观感）
                .overlay(
                    Group {
                        if isMultiBubbleAI {
                            Color.clear
                        } else if message.isErrorPlaceholder {
                            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                                .strokeBorder(Color.red.opacity(0.55), lineWidth: 1.2)
                        } else {
                            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                                .strokeBorder(isHighlighted ? Color.accentColor : .clear, lineWidth: 2)
                        }
                    }
                )
                // v4.0.39：流式期间的下扫光带。用 overlay（不是 background）→ 画在气泡底色之上、
                // 但仍在描边之下；clipShape 到同一个圆角矩形，绝不溢出到气泡外。
                // 多气泡段落模式（isMultiBubbleAI）不挂：那时每段自带圆角底，光带跨段会割裂。
                // 驱动用 .offset + repeatForever（不引第二套时钟）：见 Motion.streamSweepOpacity 的注释——
                // 即便系统判定「无动画活动」把这条 repeatForever 冻住，光带也只剩 3.5% 的一层淡影，
                // 肉眼读作静态质感而非「动画卡住」。reduceMotion 直接不挂。
                .overlay(
                    Group {
                        if streamingSweep && !isMultiBubbleAI && !reduceMotion {
                            StreamSweepBand()
                        }
                    }
                )
            .frame(maxWidth: AdaptiveLayout.bubbleMaxWidth(hSize), alignment: message.isUser ? .trailing : .leading)   // v3.4.28 横屏自适应（竖屏仍 366）
            // v4.0.40：原先挂在这里的那条分角色插入动画（用户 scale 0.88/.trailing + 12pt、
            //   AI scale 0.97/.leading + 6pt）已**移到 ChatView.messageRow**（ForEach 的直接
            //   子视图）—— transition 只对容器判定 inserted 的那一层生效，挂在气泡内部永远不播
            //   （v4.0.39 真机零观感的根因）。这里保留占位注释，防止有人再把动画挂回内部。
            // 事务侧：插入事务由 refreshVisibleMessages 的纯追加分支提供（Core/MessageInsertAnim.swift）。

            bubbleTrailingAccessory
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        // v4.0.25：待办候选确认卡（AI 提取确认制）——挂在气泡**之外**（本行底部），
        // 不嵌进灰气泡内层（审查建议④：内嵌会被气泡底色+内边距包成双层卡片）。
        // 流式中不出卡（stage 由落库口触发，流式期间本卡自然无候选）、撤回消息不出卡。
        if !message.isUser, !streamingText, !message.withdrawn {
            TodoConfirmCard(messageID: message.id)
        }
        // v2.0.125：长按菜单按区域分发 —— 文字区由 SelectableTextLabel 的 UITextView 编辑菜单接管
        //（复制/引用/分享/大爆炸/选择文本/重新生成/撤回/删除）；图片/文件卡片挂 cardMenu；
        // 代码块/表格走 MessageBlockView 内部 SwiftUI 菜单。
        // ⚠️ 气泡级 contextMenu 会抢占 UITextView 长按手势（v2.0.122 实测 bug），必须移除。
    }

    // MARK: - 巨型 body 拆分（纯搬运）
    //
    // 由头：此 body 单块 310 行，是本仓已踩过两次的「Unable to type-check this
    // expression in reasonable time」高危形态（一次漏检 = 20 分钟 CI 循环）。
    // 这里按原注释分段把视图块原样搬成独立 @ViewBuilder 属性 —— **纯搬运**：视图顺序、
    // 层级、条件分支、闭包、修饰符逐字未变，渲染结果与拆分前一致，只为把类型检查表达式打小。

    /// 气泡**内容侧不留白**（贴边）：AI 贴屏幕左、用户贴屏幕右（v4.0.37）。
    /// 留白只挂在对侧负责撑开 —— 原先两侧各一个 Spacer(12)，AI 左边距因此是 12 + 列表 6 = 18pt、
    /// 用户右边距同样 18pt，且这 12pt 反过来挤掉气泡可用宽度（用户实报「再往左贴到边，右边同理」）。
    @ViewBuilder
    private var bubbleLeadingAccessory: some View {
        // 用户的：左侧留白把气泡顶到右边；AI 的：左侧什么都不留 → 贴到边
        if message.isUser { Spacer(minLength: 12) }
    }

    /// 气泡内可视化引用块
    @ViewBuilder
    private var bubbleQuotedBlock: some View {
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
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.accentColor.opacity(Tint.faint), in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
            .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
            // v3.9.58c：整块可点 → 跳转原消息（回调为空时保持纯展示，向后兼容）
            .contentShape(Rectangle())
            .onTapGesture { onQuoteTap() }
        }
    }

    /// 撤回占位 / 图片（URL 与 data URL 两条渲染路径）
    @ViewBuilder
    private var bubbleMediaBlock: some View {
        // v2.0.92：撤回消息 → 灰色"已撤回"占位（内容不再显示）
        if message.withdrawn {
            Text("已撤回")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xxs)
        } else if let img = message.imageDataURL {
            if img.hasPrefix("http") {
                // v3.0.37：图片持久化 —— URL 图片（已上传 NAS）用 AsyncImage 加载
                // v3.4.25：data URL 图片按气泡显示宽度下采样解码（≥100KB 大图省内存）
                // v3.4.28：横屏放宽到 280
                AIImageView(url: img, displayWidthPT: AdaptiveLayout.chatImageMax(hSize))
                    .frame(maxWidth: AdaptiveLayout.chatImageMax(hSize), maxHeight: AdaptiveLayout.chatImageMax(hSize))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    .zoomSource(id: message.id, ns: zoomNS)   // v3.4.29：zoom 转场源
                    .onTapGesture { onImageTap() }
                    .bubbleLongPress(longPressAction)
            } else if let uiImg = dataURLImage(img, displayWidthPT: AdaptiveLayout.chatImageMax(hSize)) {
                // v3.4.25：传气泡显示宽度 → ≥100KB 大图按 512/1024 档位下采样解码（内存不随原图像素放大）
                Image(uiImage: uiImg)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: AdaptiveLayout.chatImageMax(hSize), maxHeight: AdaptiveLayout.chatImageMax(hSize))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    .zoomSource(id: message.id, ns: zoomNS)   // v3.4.29：zoom 转场源
                    // v2.0.36：点击查看大图
                    .onTapGesture { onImageTap() }
                    // v2.0.125：图片长按菜单（原气泡级菜单移到这里，不抢占文字长按）
                    .bubbleLongPress(longPressAction)
            }
        }
    }

    /// 正文（文件卡片 / 可选文本 / 段落流式）
    @ViewBuilder
    private var bubbleContentBody: some View {
        if !displayContent.isEmpty {
            if message.isUser {
                bubbleUserTextBody
            } else {
                bubbleAITextBody
                                    }
        }
    }

    /// 用户消息正文（文件卡片 or 可选文本）
    @ViewBuilder
    private var bubbleUserTextBody: some View {
        // v2.0.87q：文件消息微信风格卡片（图标+文件名+状态）
        if let file = parseFileMessage(message.content) {
            FileMessageCard(file: file)
                // v2.0.125：文件卡片长按菜单（原气泡级菜单移到这里）
                .bubbleLongPress(longPressAction)
        } else {
            // v2.0.125：UITextView 渲染 —— 长按弹菜单（复制/引用/分享/大爆炸/选择文本/撤回/删除）
            SelectableTextLabel(
                attributedText: NSAttributedString(string: message.content, attributes: [
                    .font: UIFont.systemFont(ofSize: CGFloat(fontSize)),
                    .foregroundColor: UIColor.white
                ]),
                fallbackColor: .white,
                lineSpacing: LineSpacing.compact,
                onCopy: { UIPasteboard.general.string = message.content; Haptics.success() },   // v3.9.30：复制触感
                onQuote: onQuote,
                onShare: onShare,
                onBigBang: onBigBang,
                onDelete: onDelete,
                onRegenerate: nil,
                onWithdraw: canWithdraw ? onWithdraw : nil,
                onEdit: onEdit,   // v4.0.44 待做池 3：编辑已发消息（声明序紧贴 onWithdraw）
                onMultiSelect: onMultiSelect,
                onMemo: onMemo,
                onGoal: onGoal,
                // v4.0.81：用户文字气泡也换「长按 → 锚定胶囊菜单」（弃 UITextView 原生编辑菜单 + 拖动选中）
                interactionEnabled: false
            )
            // v4.0.81：长按动作挂在表示层（interactionEnabled=false 已让触摸穿透到这一层）
            .bubbleLongPress(longPressAction)
        }
    }

    /// AI 消息正文（多气泡段落 / 整块渲染）
    @ViewBuilder
    private var bubbleAITextBody: some View {
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
                                        onCopy: { UIPasteboard.general.string = displayContent; Haptics.success() },   // v3.9.30：复制触感
                                        onQuote: onQuote,
                                        onShare: onShare,
                                        onBigBang: onBigBang,
                                        onDelete: onDelete,
                                        onRegenerate: onRegenerate,
                                        onWithdraw: nil,
                                        onRead: onRead,   // v3.9.86：长回复阅读入口
                                        onPin: onPin,
                                        onMemo: onMemo,
                                        onTodo: onTodo,
                                        onGoal: onGoal,
                                        onRemind: onRemind,
                                        onImageTap: { url in onAIImageTap(url) },   // v2.0.128：AI 图片点击打开大图
                                        onFileTap: { url, name in onFileTap(url, name) },   // v3.9.17：AI 生成物预览
                                        onMultiSelect: onMultiSelect,   // v3.3.0：多选合并转发
                                        onContinueStep: onContinueStep,   // v3.9.74 P2.6：plan 卡继续下一步
                                        useSwiftUIText: true,
                                        streaming: streamingText,   // v3.0.41 性能：流式中纯 Text 渲染（跳过 markdown 解析）
                                        onLongPressMenu: onLongPressMenu)   // v4.0.81：长按段 → 锚定胶囊菜单
                    }
                }
        }
    }

    /// 发送失败 → 重试入口
    @ViewBuilder
    private var bubbleRetryRow: some View {
        // v2.0.59：发送失败 → 重试入口
        // v3.4.25：微信式失败态——红色感叹号圆标 + 「消息未发出」+「点击重试」，整行可点
        if message.isUser && message.failed {
            Button {
                onRetry()
            } label: {
                HStack(spacing: Spacing.xs) {
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
            .padding(.top, Spacing.xxs)
        }
    }

    /// AI 错误占位 → 快捷重生成
    @ViewBuilder
    private var bubbleRegenerateRow: some View {
        // v3.4.25：AI 错误占位 → 快捷重试行（红描边气泡下「重新生成」，免翻长按菜单）
        if !message.isUser && message.isErrorPlaceholder {
            Button {
                onRegenerate()
            } label: {
                // v3.9.4：只留文字（去图标）
                Text("重新生成")
                    .font(.system(size: Typography.caption, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .padding(.top, Spacing.xxs)
        }
    }

    /// 已送达 / 排队中状态
    @ViewBuilder
    private var bubbleDeliveryRow: some View {
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
            .padding(.top, Spacing.xxs)
        }
    }

    /// AI 朗读按钮（音柱跳动动画）
    @ViewBuilder
    private var bubbleSpeakButton: some View {
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
                    .padding(.top, Spacing.xxs)
                } else {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                        .padding(.top, Spacing.xxs)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// v4.0.20 推送来源角标（用户 2026-10 口径 1a：三色区分前台 / 定时 / 主动）
    ///
    /// 原先是单一蓝色「🔔 推送」——用户读不出「这条是我问出来的、还是后台自己跑出来的」。
    /// 来源映射是纯逻辑 `PushKind.style(for:)`（真值表钉住）；问题卡自带卡面，不再重复出角标。
    @ViewBuilder
    private var bubblePushTag: some View {
        if PushKind.showsTag(role: message.role, isPush: message.isPush,
                             questionId: message.questionId) {
            let style = PushKind.style(for: message.pushKind)
            let tint = pushKindColor(style.colorKey)
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(style.label)
            }
                .font(.system(size: Typography.tiny, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs)
                .background(tint.opacity(Tint.faint), in: Capsule())
                .padding(.top, Spacing.xxs)
        }
    }

    /// colorKey → 色值（UI 层唯一映射点；`PushKind` 刻意不 import SwiftUI，好做纯逻辑真值表）
    private func pushKindColor(_ key: String) -> Color {
        switch key {
        case "orange": return .orange
        case "blue":   return .blue
        case "green":  return .green
        default:       return .secondary
        }
    }

    /// v4.0.11：主动 Agent 消息的「有用/没用」反馈条
    ///
    /// 存在的理由：主动 Agent 的**唯一学习信号**就是这个。阈值是后端按采纳率
    /// 自适应抬/降的（_adaptive_threshold），没有回灌就永远停在默认 0.55 = 不会变聪明。
    /// 因此反馈条**只在 proactiveId 非空时**出现（=后端主动投的那类），
    /// 普通回复/进度/提问卡一律不显示，避免变成需要点掉的噪音。
    @ViewBuilder
    private var bubbleProactiveFeedback: some View {
        if let pid = message.proactiveId, !pid.isEmpty, let cb = onProactiveFeedback {
            if let v = message.proactiveVerdict, !v.isEmpty {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: v == "adopted" ? "checkmark.circle.fill" : "hand.thumbsdown.fill")
                        .font(.system(size: Typography.tiny))
                    Text(v == "adopted" ? "已采纳 · 我会更主动" : "已忽略 · 我会少打扰")
                        .font(.system(size: Typography.tiny))
                }
                .foregroundStyle(v == "adopted" ? Color.green : Color.secondary)
                .padding(.top, Spacing.xxs)
            } else {
                HStack(spacing: Spacing.sm) {
                    Text("这条有用吗")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.secondary)
                    Button {
                        cb(pid, "adopted")
                        Haptics.success()
                    } label: {
                        Label("有用", systemImage: "hand.thumbsup")
                    }
                    .buttonStyle(PressStyle(scale: 0.9))
                    Button {
                        cb(pid, "ignored")
                        Haptics.success()
                    } label: {
                        Label("没用", systemImage: "hand.thumbsdown")
                    }
                    .buttonStyle(PressStyle(scale: 0.9))
                }
                .padding(.top, Spacing.xxs)
            }
        }
    }

    /// 气泡右侧留白（v4.0.37：只服务 AI —— 把气泡顶到左边；用户侧不留 → 贴到边）
    @ViewBuilder
    private var bubbleTrailingAccessory: some View {
        if !message.isUser { Spacer(minLength: 12) }
    }

    /// 消息内容分段：``` 代码块 → 等宽深色块；其余 → markdown
    /// v3.0.41 性能：流式输出中跳过分段（split/图片展开都是 O(n) 全量扫描），直接单块渲染
    /// v3.0.x：加 LRU 缓存——同一 content+serverURL+streaming 组合不重复解析
    /// v3.7.0：实际渲染用文本——AI 的**已落库消息**先剥掉历史遗留的「进度行」。
    /// 流式中不过滤：一是后端 stream_api v3.7.0 起已不再注入进度行，二是流式每帧求值（省一次 O(n) 扫描）。
    private var displayContent: String {
        if message.isUser || streamingText { return message.content }
        // v4.0.77：[[browser_live:…]] 标记的**显示期兜底**（与下面进度行同一个位置、同一个理由）——
        // 落库侧已归一化（ChatStore.normalizeBrowserLiveMarkers），这一层兜的是「服务端已经存着
        // 4.0.76 时期被写脏的正文」：标记绝不再以原文形态出现在气泡/复制/大爆炸里。
        return Self.strippingProgressLines(Self.strippingBrowserLiveMarker(message.content))
    }

    /// v4.0.77：直播标记的显示期剥除（定位逻辑与 ChatStore 共用，判据只有一份）
    static func strippingBrowserLiveMarker(_ text: String) -> String {
        ChatStore.strippingBrowserLiveMarker(text)
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
        // v3.9.95：AI 本地动作卡（```ql-action 围栏）
        // ⚠️ 必须排在 ql-card 判定**之前**：一条回复里两者可能同时出现，
        //   而 ql-action 的「回退纯文本」分支要交给 blocksPlain —— 它不认识动作围栏，
        //   会把 ```ql-action 当普通代码块画出来（用户看到一段 JSON 代码）。
        if AgentActionParser.containsActionMarker(text) {
            return blocksWithActions(text, serverURL: serverURL, streaming: streaming)
        }
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

    /// v3.9.95：含 ```ql-action 围栏的文本切分。
    ///
    /// 两条口径照抄 ql-card 的做法（别各写一套，那是两边走样的起点）：
    ///   · 流式：未闭合围栏**不出卡**（先出卡、下一帧又退回原文 = 用户看到卡闪一下）
    ///   · 解析失败/未知动作：整块退回 blocksPlain 走原路径，**但要先摘掉 ql-action 围栏标记**，
    ///     否则用户会看到一段 ```ql-action JSON 代码块 —— 那比"没执行"更让人困惑。
    private static func blocksWithActions(_ text: String, serverURL: String, streaming: Bool) -> [MessageContentBlock] {
        var out: [MessageContentBlock] = []
        for seg in AgentActionParser.parse(text) {
            switch seg {
            case .action(let a):
                out.append(.init(kind: .action(a)))
            case .text(let t):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if streaming {
                    out.append(.init(kind: .markdown(t)))
                } else {
                    out.append(contentsOf: blocksPlain(for: stripActionFenceMarks(t), serverURL: serverURL))
                }
            }
        }
        // 动作卡不该是唯一内容（AI 至少会写一句话交代）——空则整段回退
        return out.isEmpty
            ? blocksPlain(for: stripActionFenceMarks(text), serverURL: serverURL)
            : out
    }

    /// 把残留的 ```ql-action / ```ql_action 围栏标记降级为普通围栏（让 blocksPlain 当代码块或纯文本处理，
    /// 而不是一个 ql-action 卡片）。**只动围栏标记行，不动内容**。
    private static func stripActionFenceMarks(_ text: String) -> String {
        guard text.contains("ql-action") || text.contains("ql_action") || text.contains("qlaction") else {
            return text
        }
        return text.components(separatedBy: "\n").map { line -> String in
            if let lang = AgentActionParser.fenceLanguage(line), AgentActionParser.isActionFence(lang) {
                return "```"
            }
            return line
        }.joined(separator: "\n")
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
            // v3.9.41（SR44）：走缓存版——同文件 634 行的 blocksCached 就是为此存在的，
            // 这条段落级路径漏了它，于是每次 body 重建（流式 tick / 列表滚动回收）都对每段全文重跑分段。
            let pb = Self.blocksCached(for: para, serverURL: serverURL, streaming: false)
            ForEach(0..<pb.count, id: \.self) { i in
                MessageBlockView(block: pb[i],
                                onCopy: { UIPasteboard.general.string = para; Haptics.success() },   // v3.9.30：复制触感
                                onQuote: onQuote,
                                onShare: onShare,
                                onBigBang: { onBigBang($0) },
                                onDelete: onDelete,
                                onRegenerate: onRegenerate,
                                onWithdraw: nil,
                                onRead: onRead,       // v3.9.86：长回复阅读入口
                                onPin: onPin,
                                onMemo: onMemo,
                                onTodo: onTodo,
                                onGoal: onGoal,
                                onRemind: onRemind,
                                onImageTap: { url in onAIImageTap(url) },
                                onFileTap: { url, name in onFileTap(url, name) },   // v3.9.17：AI 生成物预览
                                onMultiSelect: onMultiSelect,   // v3.3.0：多选合并转发
                                onContinueStep: onContinueStep,   // v3.9.74 P2.6：plan 卡继续下一步
                                useSwiftUIText: true,
                                streaming: false,
                                onLongPressMenu: onLongPressMenu)   // v4.0.81：长按段 → 锚定胶囊菜单
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .background(
            // v4.0.81 方案3：多气泡段落的每段底同步换玻璃厚边（与主气泡同口径）
            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                .fill(isHighlighted
                      ? AnyShapeStyle(aiBubbleColor)
                      : AnyShapeStyle(Material.ultraThinMaterial))
                .overlay {
                    if !isHighlighted {
                        RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                            .fill(EnvironmentGradient.cardGlassFill(scheme))
                    }
                }
                .overlay {
                    if !isHighlighted {
                        RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                            .strokeBorder(EnvironmentGradient.cardEdgeGradient(scheme), lineWidth: 1)
                    }
                }
        )
        .glassCardShadow(scheme, enabled: !isHighlighted)
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
            // v3.9.17：按扩展名分流 —— 图片仍走图片块；文档/文本走「文件卡片」
            // （后端 /api/stream/media 已放开 pdf/md/csv/txt/json/log 且带 Content-Disposition，
            //  但塞进 <img> 只会渲染成一张空白）
            let ext = (rawPath as NSString).pathExtension.lowercased()
            let rawName = (rawPath as NSString).lastPathComponent.replacingOccurrences(of: "]", with: "")
            let isImage = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic"].contains(ext)
            let imgMarkdown = isImage
                ? "![图片](\(serverURL)/api/stream/media?p=\(b64))"
                : "![文件:\(rawName.isEmpty ? "附件" : rawName)](\(serverURL)/api/stream/media?p=\(b64))"
            let fullRange = NSRange(location: m.range.location + offset, length: m.range.length)
            result = (result as NSString).replacingCharacters(in: fullRange, with: imgMarkdown)
            // v3.9.41（SR46）：偏移必须用 UTF-16 长度——NSString 的 range 是 UTF-16 计数，
            // 而 imgMarkdown.count 是 Character 数；文件名含 emoji/CJK 代理对时两者不等，
            // 后续 MEDIA: 的替换位置会逐条错位（坏链 + 原文残留）。
            offset += (imgMarkdown as NSString).length - m.range.length
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
        // v3.9.17：多捕一个 alt —— 用它区分「图片块」与「文件卡片」（alt 前缀 "文件:"）
        guard let re = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#) else {
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
            let alt = ns.substring(with: m.range(at: 1))
            let url = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if alt.hasPrefix("文件:") {
                result.append(.file(url, String(alt.dropFirst("文件:".count))))
            } else {
                result.append(.image(url))
            }
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
    /// v4.0.71：**铺满可用宽 + 定比例**（问题卡里的「浏览器画面」用）。给了比例 → 盒子 = 可用宽 × (1/比例)，
    /// 窄屏自动收窄（写成定宽在 SE 上会溢出、被两端裁掉）；不给 = 历史行为（气泡图 240×240 上限）。
    var fillAspect: CGFloat? = nil
    /// v4.0.71：图就位时把 UIImage 回吐给宿主（问题卡「点图看大图」要拿它喂 ImageViewer）。
    /// 不给 = 无需回吐 → 历史调用方逐字不变。
    var onLoaded: ((UIImage) -> Void)? = nil
    @State private var image: UIImage?
    @State private var failed = false
    /// v4.0.x：图片就位时淡入（骨架换真图不硬跳）。「减弱动态效果」下直接落图。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if url.hasPrefix("data:image/") {
                // base64 data URL → 本地解码（复用 ImageCache）；v3.4.25：按显示宽度下采样
                if let img = dataURLImage(url, displayWidthPT: displayWidthPT) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            } else if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    // v4.0.x：骨架换真图走淡入（配合 revealImage 的 withAnimation），不硬跳
                    .transition(.opacity)
            } else if failed {
                placeholder
            } else {
                skeleton
            }
        }
        // v4.0.71：尺寸口径收进一个出口 —— 图/骨架/占位三支只能在「盒子」处定尺寸，
        // 各写一份的话换档时必漂移（改一处不改另一处 = 图换入时跳版）。
        .modifier(ImageBox(fillAspect: fillAspect))
    }

    /// 首次加载占位。v4.0.x：裸转圈（240×120 白块）→ 骨架屏 —— 转圈只说「在等」，
    /// 骨架还说「等来的东西长在这、有这么大」，正是 Theme/Skeleton.swift 建立时定下的用法。
    @ViewBuilder
    private var skeleton: some View {
        if fillAspect == nil {
            SkeletonBlock(width: 240, height: 120, cornerRadius: Radius.inset)
                .task { await loadRemote() }
        } else {
            // 铺满档：骨架与盒子同尺寸（否则真图换入时尺寸跳版）
            GeometryReader { g in
                SkeletonBlock(width: g.size.width, height: g.size.height, cornerRadius: Radius.inset)
            }
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
            revealImage(cached, animated: false)
            return
        }
        // 1) URLSession（外部公开图，Ats 允许 https）
        if let (data, _) = try? await URLSession.shared.data(from: u),
           let img = UIImage(data: data) {
            setRemoteImageCache(url, img, cost: data.count, sourceData: data)
            revealImage(img, animated: true)
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
                setRemoteImageCache(url, img, cost: data.count, sourceData: data)
                revealImage(img, animated: true)
                return
            }
        }
        failed = true
    }

    /// v4.0.x：图片就位（骨架 → 真图）。网络路径淡入，避免骨架被真图硬顶掉；
    /// 缓存命中是最快路径（骨架几乎没出现过），直接落图反而更稳，不给它加动画。
    @MainActor
    private func revealImage(_ img: UIImage, animated: Bool) {
        // v4.0.71：宿主可能要这张图（问题卡「点图开全屏」）——两条出口都回吐，
        // 漏掉缓存这条就是「缓存命中时点不开、冷启动才点得开」的偶发 bug。
        onLoaded?(img)
        guard animated, !reduceMotion else {
            image = img
            return
        }
        withAnimation(.easeOut(duration: 0.18)) { image = img }
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
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
    }
}

/// v4.0.71：AIImageView 的尺寸出口（「盒子」只在这里定义一处）。
/// - `fillAspect == nil` → 历史档：240×240 上限 + 圆角 12（气泡图，逐字保持原行为）。
/// - 给了比例 → 铺满档：`Color.clear` 撑出「可用宽 × (1/比例)」的盒子，图裁进盒子
///   （问题卡里的浏览器画面；窄屏自动收窄，不会溢出被裁）。
private struct ImageBox: ViewModifier {
    let fillAspect: CGFloat?

    func body(content: Content) -> some View {
        if let a = fillAspect {
            Color.clear
                .aspectRatio(a, contentMode: .fit)
                .overlay {
                    content.clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                }
        } else {
            content
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
        }
    }
}

