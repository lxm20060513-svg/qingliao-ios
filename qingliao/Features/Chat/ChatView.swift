import SwiftUI
import PhotosUI
import PDFKit
import UniformTypeIdentifiers
import AVFoundation
import Speech
import UIKit
import UserNotifications

// MARK: - v2.0.65 发送完成通知（Dock 轻跳）

extension Notification.Name {
    static let qingliaoSent = Notification.Name("qingliao_sent")
    // v2.0.102c：切回看板刷新通知（TabView 切 tab 在 iOS 27 不触发子页 onAppear 的兜底）
    static let qingliaoDashboardRefresh = Notification.Name("qingliao_dashboard_refresh")
    // v2.0.133f：离开看板通知——看板 30s 轮询在隐藏页也跑，切页时抢帧；隐藏时暂停轮询
    static let qingliaoDashboardLeave = Notification.Name("qingliao_dashboard_leave")
}

// MARK: - v2.0.60 通知点击直达会话（AppDelegate 捕获通知点击 → 存 sessionId）

// v2.0.64：@preconcurrency 抑制 Swift 6 的 delegate 跨 MainActor Sendable 检查
final class QingliaoAppDelegate: NSObject, UIApplicationDelegate,
                                 @preconcurrency UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // v2.0.110：后台刷新（方案2推送）——iOS 定期唤醒 App，检查流式任务是否完成 →
    // 完成则发本地通知（侧载无 entitlement 也能用；唤醒间隔由系统决定，非实时）
    func application(_ application: UIApplication,
                     performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let server = UserDefaults.standard.string(forKey: "qingliao_server") ?? ""
        // v3.0.84fix：token 迁 Keychain，后台刷新从 Keychain 读（原 UserDefaults 明文已弃）
        let token = AuthStore.keychainReadToken() ?? ""
        guard let d = UserDefaults.standard.dictionary(forKey: "qingliao_stream_pending"),
              let taskId = d["taskId"] as? String, !taskId.isEmpty,
              !server.isEmpty, !token.isEmpty else {
            completionHandler(.noData)
            return
        }
        var base = server
        if !base.hasPrefix("http") { base = "https://" + base }
        guard let url = URL(string: base + "/api/stream/" + taskId) else {
            completionHandler(.failed)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completionHandler(.failed)
                return
            }
            let status = j["status"] as? String ?? ""
            if status == "done" || status == "error" {
                // 回复完成 → 本地通知 + 清理持久化任务
                let sid = d["sessionId"] as? String
                NotificationHelper.notify(title: "轻聊", body: "AI 回复完成，点击查看", sessionId: sid)
                UserDefaults.standard.removeObject(forKey: "qingliao_stream_pending")
                completionHandler(.newData)
            } else {
                completionHandler(.noData)   // 未完成，等下次系统唤醒再查
            }
        }.resume()
    }

    // v2.0.63：用 completionHandler 版（async 版在 Swift 6 下 non-Sendable 参数报错）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let sid = response.notification.request.content.userInfo["qingliao_session"] as? String {
            UserDefaults.standard.set(sid, forKey: "qingliao_open_session")
        }
        completionHandler()
    }
}

// MARK: - v2.0.50 滚动位置检测（替代 .scrollPosition）
// .scrollPosition 在 TabView 隐藏页内容清空时是已知崩溃点（SIGTRAP），
// 换 GeometryReader + PreferenceKey：滚动时上报内容区 minY，取负后语义同 scrollPos.y

/// v2.0.88：排队待发消息（AI 回答中发送，当前回答结束后自动逐条发送）
struct PendingSend {
    let text: String
    let imageData: String?
}

// MARK: - v3.0.18 云端工具调用 UI 数据

/// v3.0.18：工具循环 escaping 闭包内的文本累积器（Swift 6 并发：闭包不能改捕获的局部 var）
@MainActor
final class CloudTextAccumulator {
    var text = ""
}

/// v3.0.18：工具确认弹窗状态门（@Observable @MainActor——pending 变化驱动 confirmationDialog 出现；60s 超时 @Sendable 闭包只捕获它）
@MainActor
@Observable
final class ToolConfirmGate {
    var pending: PendingToolConfirm?
    var onConfirm: ((Bool) -> Void)?
}

/// v3.0.18 fix：云端流式 UI 状态——提取为 @Observable 引用类型，
/// 闭包捕获此对象而非 ChatView struct（struct 值捕获 → Task 内 self 旧副本 → 后续更新丢失）
@Observable @MainActor
final class CloudStreamUIState {
    var toolCards: [ToolCardItem] = []
    var lastStreamFlush: Date? = nil
}

/// 工具执行结果卡片（显示在消息区，AI 气泡上方）
struct ToolCardItem: Identifiable {
    let id = UUID()
    let title: String
    let ok: Bool
}

/// 工具卡片视图（绿勾/红叉 + 标题）
struct ToolCardView: View {
    let item: ToolCardItem
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(item.ok ? .green : .red)
            Text(item.title)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
    }
}

struct ChatView: View {
    @Environment(AuthStore.self) var auth
    @Environment(ChatStore.self) var chat
    @Environment(StreamClient.self) var stream
    @Environment(InboxStore.self) var inbox   // v3.4.0：底部上拉手动拉取收件箱
    @Environment(KeyboardObserver.self) var kb
    @State var pinStore = PinStore.shared   // v3.0.74：钉一钉

    @State var inputText = ""
    @FocusState var inputFocus: Bool
    @State var sentOK = false
    @State var serverOnline: Bool?   // 服务器连接状态（真实绿点）
    // v2.0.36：引用回复 / 图片查看器 / 导出
    @State var quotedMessage: ChatMessage?
    @State var viewerPayload: ImageViewPayload?
    @State var showMoreMenu = false
    @State var showExporter = false
    @State var showMarkdownExporter = false
    @State var showPDFExporter = false
    @State var exportText = ""
    @State var exportMarkdown = ""
    @State var exportPDFData: Data?
    @State var clearing = false          // v2.0.40 清空会话两步走标志
    // v2.0.43：快捷指令 / 搜索定位高亮
    @State var showQuickPrompts = false
    @State var highlightMessageID: String?
    @State var showLongContextAlert = false
    @State var showCompressingAlert = false  // v3.0.81：AI 摘要压缩中
    @State var pendingSend: (text: String, imageData: String?)?
    @State var showModelSheet = false   // 模型快速切换
    @State var showAttachmentMenu = false
    // v2.0.96：Hermes 捷径面板（官方斜杠命令）
    @State var showHermesShortcut = false
    // 大爆炸（BigBang）文本炸开
    @State var bigBangPayload: BigBangPayload?
    @State var showPhotoPicker = false
    @State var showFileImporter = false
    @State var showCameraPicker = false   // v2.0.38 拍照输入
    @State var photoItem: PhotosPickerItem?
    @State var pendingImage: UIImage?
    @State var pendingImageData: String?
    // v2.0.96：语音转文字（长按发送按钮；v2.0.96c 改服务器 ASR——录音上传转写，侧载全兼容）
    @StateObject var voiceRecorder = VoiceRecorder()
    @State var voiceMode = false
    @State var transcribing = false   // v2.0.100：语音转文字转换中（动画）
    @State var transcribeToken = 0   // v2.0.101：转写代次（停止/新转写递增，旧 Task 结果作废）
    @State var voiceAuthFailed = false
    @State var sendingLock = false   // v2.0.102：发送锁（防双击双流竞态）
    @State private var lastSentSignature: (sessionId: String, text: String, ts: TimeInterval)?  // 同内容 60s 幂等
    @State var fileSendBlocked = false   // v2.0.102：流式中发文件提示
    @State var voiceTooShort = false   // v2.0.102：录音太短提示
    @State var voiceDiag = ""   // v3.0.78 诊断：录音链路诊断信息
    // v2.0.88：AI 回答中发送的消息队列（回答结束后自动逐条发送）
    @State var pendingQueue: [PendingSend] = []
    // v2.0.132：智能球点击全屏粒子爆发（满屏散开特效层）
    @State var showFullBurst = false
    // v3.0.18：云端工具调用——执行卡片 + 写操作确认弹窗（gate 类持有，超时闭包只捕获它）
    // v3.0.18 fix：toolCards/lastStreamFlush 提取到 CloudStreamUIState（@Observable 引用类型，
    // 闭包捕获引用而非 struct 值拷贝，避免 Task 内 self 旧副本 → 状态更新丢失）
    @State var toolGate = ToolConfirmGate()
    @State var cloudStreamUI = CloudStreamUIState()
    // v3.4.0：底部上拉拉取收件箱状态（@Observable 引用——拖动高频写不重建 ChatView body）
    @State var inboxPull = InboxPullState()
    // v3.0.27：长文目录
    @State var showTOCSheet = false
    // v3.0.51 A2：极长会话分页懒加载——初始只渲染尾部最近 N 条，顶部可"加载更早"
    @State var displayLimit = 300
    private static let loadMoreStep = 300
    // v3.3.0：多选合并发送——选择模式开关 + 选中消息 id 集合
    @State var selectMode = false
    @State var selectedMsgIDs: Set<String> = []
    @State var selectBlocked = false      // 流式中尝试进入多选 → 提示
    @State var mergeTooMany = false       // 合并超过 99 条 → 提示
    static let maxMergeCount = 99
    // v3.0.51 A2 fix：缓存可见消息数组——仅在消息数量/显示上限变化时重建，
    // 避免每帧 stream.delta 触发 body 重建 O(visible) 数组
    @State private var visibleMessagesCache: [MessageRowItem] = []
    private var visibleMessageCount: Int { min(chat.messages.count, displayLimit) }
    /// 可见窗口起始绝对索引（用于日期分隔线的 prevTs 取真实前一条）
    private var visibleStartIndex: Int { chat.messages.count - visibleMessageCount }
    /// v3.0.51 A2：预计算可见窗口（拆出 ForEach 内联切片，避免 type-check 超时）
    private struct MessageRowItem: Identifiable {
        let index: Int
        let msg: ChatMessage
        /// v3.4.2：前一条消息快照（渲染期分隔线判定用）。渲染路径禁止再索引可变
        /// chat.messages——原 chat.messages[idx-1] 在消息增删/清空竞态下越界 →
        /// SIGTRAP（2026-09-04 崩溃栈 atos 实证 ChatView.swift:669）
        let prevMsg: ChatMessage?
        var id: String { msg.id }
    }
    // v3.0.51 A2 fix：缓存可见消息数组——仅在消息数量/显示上限变化时重建，
    // 避免每帧 stream.delta 触发 body 重建 O(visible) 数组
    private func refreshVisibleMessages() {
        let msgs = chat.messages
        let start = visibleStartIndex
        visibleMessagesCache = (start..<msgs.count).map {
            MessageRowItem(index: $0, msg: msgs[$0], prevMsg: $0 > 0 ? msgs[$0 - 1] : nil)
        }
    }

    // 模型/提供商可从模型管理面板选择（UserDefaults 持久化）
    // v2.0.48：改 @AppStorage——computed property 无观察机制，
    // 设置页切换模型后聊天页头部不刷新（模型实际生效但显示旧名）
    @AppStorage("qingliao_model") private var modelName = "deepseek-v4-flash"
    @AppStorage("qingliao_provider") private var provider = "opencode"

    /// 头部状态文案/颜色（独立计算属性，避免 body 内嵌套三元）
    private var headerSubtitle: String {
        serverOnline == nil ? "检测中" : (serverOnline == true ? "在线" : "离线")
    }
    private var headerColor: Color {
        serverOnline == true ? .green : (serverOnline == false ? .red : .gray)
    }

    /// v3.3.0：header 右侧 trailing 组件抽离（PageHeader 的 AnyView(HStack{...}) 内联在 body
    /// 里过复杂，Xcode 26 type-check 超时——469-472行报 "unable to type-check in reasonable time"）。
    /// 抽成独立计算属性给 type-checker 更小的表达式单元。
    @ViewBuilder
    private var headerTrailingItems: some View {
        HStack(spacing: 10) {
            Button {
                showMoreMenu = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    /// v3.3.0：confirmationDialog 内容抽离（原内联 Menu+8个Button 过长致 Xcode26
    /// type-check 超时——508行报 "unable to type-check in reasonable time"）。
    /// 抽成独立 @ViewBuilder 属性给 type-checker 更小的表达式单元。
    @ViewBuilder
    private var chatActionDialogContent: some View {
        Menu("导出会话记录") {
            Button("纯文本 (.txt)") {
                exportText = chat.exportText()
                showExporter = true
            }
            Button("Markdown (.md)") {
                exportMarkdown = chat.exportMarkdown()
                showMarkdownExporter = true
            }
            Button("PDF (.pdf)") {
                exportPDFData = ChatPDFDocument.generate(
                    title: chat.title, messages: chat.messages)
                showPDFExporter = true
            }
        }
        // v2.0.92：会话分享卡片（渲染精美图片 → 系统分享/微信）
        Button("分享会话卡片") {
            shareSessionCard()
        }
        // v3.3.0：多选合并发送（勾选多条 → 合并成一张卡片图片 → 系统分享/微信）
        Button("多选合并发送") {
            if stream.isStreaming {
                selectBlocked = true
            } else {
                inputFocus = false
                selectedMsgIDs.removeAll()
                withAnimation(.easeOut(duration: 0.2)) { selectMode = true }
            }
        }
        // v2.0.43：上下文信息 + 一键压缩
        Button("上下文：约 \(chat.contextInfo.tokens) tokens · \(chat.contextInfo.count) 条") {}
        Button("压缩上下文（保留最近 20 条）") {
            if chat.compressContext() {
                Task { await chat.saveToServer(auth: auth) }
            }
        }
        // v2.0.116：AI 总结会话（走正常流式，AI 回复要点总结）
        Button("AI 总结会话") {
            summarizeSession()
        }
        // v3.0.27：长文目录
        Button("长文目录") {
            showTOCSheet = true
        }
        Button("清空本会话消息", role: .destructive) {
            // v2.0.40：两步走清空——先切欢迎页分支（列表立即卸载，数据未动），
            // 下一帧再清数据。列表销毁与数据清空完全错开，杜绝同帧崩溃。
            clearing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(nil) { chat.clearMessages() }
                clearing = false
            }
            Task { await chat.saveToServer(auth: auth) }
        }
        Button("取消", role: .cancel) {}
    }

    /// v3.3.0：输入区抽离——原 body 内 if selectMode/else(ChatInputBar 17参+多closure) 内联
    /// 过长是压垮 Xcode26 type-check 的"最后一根稻草"（v3.2.4 能过因 body 没这么重）。
    /// 抽成独立属性给 type-checker 更小的表达式单元。
    @ViewBuilder
    private var inputArea: some View {
        if selectMode {
            mergeSelectBar
        } else {
            ChatInputBar(text: $inputText,
                     focused: $inputFocus,
                     streaming: stream.isStreaming,
                     onSend: { send() },
                     onStop: {
                         // v2.0.88：点停止 = 取消当前回答 + 清空排队消息（不再自动发）
                         clearPendingQueue()
                         stream.stop(auth: auth)
                     },
                     onPickAttachment: {
                         withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                             showAttachmentMenu.toggle()
                         }
                     },
                     onCamera: { showCameraPicker = true },
                     isRecording: voiceRecorder.isRecording,
                    // v2.0.96：语音转文字（长按发送按钮）
                    voiceMode: voiceMode,
                    onVoiceModeToggle: { toggleVoiceMode(keyboardWasUp: kb.isVisible) },
                    transcribing: transcribing,
                    onCancelTranscribe: { stopTranscribe() },
                    onLongPressInput: { keyboardWasUp in toggleVoiceMode(keyboardWasUp: keyboardWasUp) },
                    // v3.0.4：云端模式无后端 ASR → 关闭全部语音入口
                    voiceEnabled: !CloudConfig.shared.isCloudMode,
                    // v2.0.132：点击智能球 → 全屏粒子爆发
                    onFullBurst: {
                        showFullBurst = true
                        Task { try? await Task.sleep(for: .seconds(1.55)); showFullBurst = false }
                    })
                    // v2.0.129：球态输入框 —— 绑定会话 id，切会话重建复位（展开态在切会话后回球态）
                    .id(chat.sessionId)
                    // v2.0.135：消费输入栏区域的点击，防冒泡到消息区 ZStack 根手势误收键盘
                    // （TextField/按钮自身优先消费，此手势只兜底输入栏空白处）
                    .onTapGesture {}
        }
    }

    // MARK: - v3.0.7 fix：输入栏上方三个小条拆独立 property（body 瘦身，防 type-check 超时）

    /// 图片预览条（选图后显示）
    @ViewBuilder
    private var pendingImageBar: some View {
        if let img = pendingImage {
            HStack(spacing: 10) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("图片已选择，发送后 AI 可识别")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    pendingImage = nil
                    pendingImageData = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
    }

    /// 内联附件面板（类微信 + 面板：点击回形针展开）
    /// v2.0.96b：发牌弹出效果（每个按钮依次从底部弹出 + 回弹）
    @ViewBuilder
    private var attachmentMenuBar: some View {
        if showAttachmentMenu {
            HStack(spacing: 26) {
                menuButton("photo.on.rectangle", "图片", Color.blue, idx: 0) { showPhotoPicker = true }
                menuButton("doc.fill", "文件", Color.indigo, idx: 1) { showFileImporter = true }
                // v2.0.43：快捷指令（常用 prompt 模板）
                menuButton("bolt.fill", "指令", Color.orange, idx: 2) { showQuickPrompts = true }
                // v3.0.6 fix：Hermes 捷径仅本地 AI 显示（云端无，遵循「本地有/云端无」）
                if !CloudConfig.shared.isCloudMode {
                    menuButton("sparkles", "Hermes 捷径", Color.purple, idx: 3) { showHermesShortcut = true }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 引用回复条（发送后自动清除）
    @ViewBuilder
    private var quotedReplyBar: some View {
        if let q = quotedMessage {
            HStack(spacing: 8) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                Text(String(q.content.prefix(60)))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    quotedMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    var body: some View {
        // v2.0.140：禁用系统键盘避让——ChatInputBar 已手动按 kb.topY 精确计算 bottom padding，
        // 系统默认避让叠加会双重上抬 → 输入框与键盘间留空隙（用户红线标注）。
        // 只保留手动控制，输入框精确贴键盘。
        VStack(spacing: 0) {
            PageHeader(title: "聊天",
                       subtitle: headerSubtitle,
                       trailing: AnyView(headerTrailingItems),
                       showStatus: true,
                       statusColor: headerColor)
            .confirmationDialog("聊天操作", isPresented: $showMoreMenu, titleVisibility: .visible) {
                chatActionDialogContent
            }
            if sentOK {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    Text("已送达 · 消息已发出")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .transition(.opacity)
            }
            messageList
                .overlay {
                    // v3.0.79：点按空白处停止录音（exitVoiceMode 注释原本就写"按钮/空白点击共用"，此处补上空白点击）
                    if voiceMode && voiceRecorder.isRecording {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { exitVoiceMode() }
                    }
                }
                .overlay(alignment: .bottom) {
                    // v3.4.0：底部上拉拉取收件箱——拖动指示器 / 拉取中 spinner / 结果 toast
                    InboxPullLayer(state: inboxPull)
                }
            // v3.0.77：移除 v3.0.36 分段流式（边说边出字实时显示）——改回整段录音一次转写
            // 图片预览条（选图后显示）
            pendingImageBar
            // 内联附件面板（类微信 + 面板：点击回形针展开）
            // v2.0.96b：发牌弹出效果（每个按钮依次从底部弹出 + 回弹）
            attachmentMenuBar
            // v2.0.36：引用回复条（发送后自动清除）
            quotedReplyBar
            // v3.0.7 beautify：Bot 选择器已移到 header（本地模式），此处不再单独占一行
            // v3.0.81：上下文使用率指示器
            contextUsageBar
            // v3.3.0：多选合并模式 → 输入栏替换为合并操作条（全选/计数/合并发送/取消）
            inputArea
            // v3.0.64：改用 iOS 26 系统原生 TabView tab bar 后，键盘避让交由系统安全区 + 原生键盘避让。
            // 旧手动 offset（kb 高度 / 76）是为自定义 DockBar（内容铺到屏幕底再叠 dock）设计，原生 tab bar 下会双重叠加冒高，故移除。
            // v3.0.67：输入框与 dock / 键盘均留 10pt 呼吸（Round-1「贴键盘 0」已改主意为也要留隙）。
            .padding(.bottom, 10)   // v3.0.67：输入框与 dock / 键盘均留 10pt 呼吸——收起贴 dock、弹键盘也留隙（Round-1「贴键盘 0」已被用户改主意为也要留隙）
        }
        .animation(.easeOut(duration: kb.animationDuration), value: kb.height)
        // v2.0.96：语音授权/转写失败提示（服务器 ASR：麦克风权限或转写无结果）
        .alert("语音转文字不可用", isPresented: $voiceAuthFailed) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("请检查麦克风权限（设置 → 轻聊 → 麦克风），或稍后重试。")
        }
        // v2.0.102：录音太短提示
        .alert("录音太短", isPresented: $voiceTooShort) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("说话时间太短，请按住说话至少 1 秒再松手。\n[诊断 v3.0.78] \(voiceDiag)")
        }
        // v2.0.102：AI 回答中发文件提示
        .alert("AI 回答中", isPresented: $fileSendBlocked) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("AI 正在回答，稍等片刻再发送文件。")
        }
        // v3.3.0：流式中进入多选提示
        .alert("AI 回答中", isPresented: $selectBlocked) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("AI 正在回答，回答完成后再多选合并。")
        }
        // v3.3.0：合并条数超限提示
        .alert("合并条数超限", isPresented: $mergeTooMany) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("最多合并 \(Self.maxMergeCount) 条，请减少勾选后再合并。")
        }
        // v3.0.18：云端工具写操作确认（日历/提醒/计时器）
        .confirmationDialog("确认执行？", isPresented: Binding(
            get: { toolGate.pending != nil },
            set: { if !$0 { toolGate.onConfirm?(false) } }
        ), titleVisibility: .visible) {
            Button("执行") { toolGate.onConfirm?(true) }
            Button("取消", role: .cancel) { toolGate.onConfirm?(false) }
        } message: {
            Text(toolGate.pending?.summary ?? "")
        }
        // v2.0.61：杀后台流式恢复（幂等——无持久化任务时静默返回）
        .task {
            await stream.restoreIfNeeded(auth: auth) { success, err in
                // v3.3.3：恢复的旧回答锚定回发起 user 消息，不 append 到用户新消息后
                let anchor = stream.pendingUserMsgId
                if success {
                    chat.upsertAssistant(stream.content, agent: stream.isAgent, afterUserID: anchor)
                } else {
                    chat.upsertAssistant(stream.content.isEmpty ? "⚠️ \(err)" : stream.content + "\n\n⚠️ \(err)", agent: stream.isAgent, afterUserID: anchor)
                }
                Task { await chat.saveToServer(auth: auth) }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        // v2.0.38：拍照输入（拍完进图片预览条，确认后发送）
        .sheet(isPresented: $showCameraPicker) {
            CameraPicker { img in
                pendingImage = img
                pendingImageData = compressImage(img)
            }
        }
        // v2.0.43：快捷指令面板（点击填充输入框）
        .sheet(isPresented: $showQuickPrompts) {
            QuickPromptSheet(onPick: { prompt in
                inputText = prompt
                showAttachmentMenu = false
            }, includeKB: !CloudConfig.shared.isCloudMode)   // v3.0.6：知识库仅本地
            .presentationDetents([.medium, .large])
        }
        // v2.0.96：Hermes 捷径面板（官方斜杠命令，点击填充输入框）
        .sheet(isPresented: $showHermesShortcut) {
            HermesShortcutSheet { cmd in
                inputText = cmd
                showAttachmentMenu = false
            }
            .presentationDetents([.medium, .large])
        }
        // v3.0.27：长文目录/大纲导航
        .sheet(isPresented: $showTOCSheet) {
            TOCSheet(headers: MarkdownRenderer.extractHeaders(
                chat.messages.filter { $0.role == "assistant" }.map(\.content).joined(separator: "\n")
            ))
            .presentationDetents([.medium])
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.data]) { result in
            if case .success(let url) = result {
                sendFile(url)
            }
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    pendingImage = img
                    pendingImageData = compressImage(img)
                }
                photoItem = nil
            }
        }
        // v2.0.132：智能球点击 → 全屏粒子爆发（满屏散开，纯视觉不挡交互）
        .overlay {
            if showFullBurst {
                FullScreenBurst()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showFullBurst)
    }

    // MARK: - 消息列表

    // v2.0.111：欢迎页独立于 ScrollView——不再受滚动容器背景/裁剪影响，logo 永远完整显示
    private var welcomeView: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.blue, .indigo, .purple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                    .shadow(color: .indigo.opacity(0.25), radius: 12, y: 4)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
            }
            Text("你好，我是轻聊")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .purple],
                                   startPoint: .leading, endPoint: .trailing)
                )
            Text("输入消息与 AI 对话")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    /// v3.0.51：单条消息整行（日期分隔 + 时间分隔 + 气泡）——拆独立方法防 ForEach type-check 超时
    /// v3.4.2：改吃 entry 快照（prevMsg），渲染不再索引可变 chat.messages（越界 SIGTRAP 根治）
    @ViewBuilder
    private func messageRow(entry: MessageRowItem) -> some View {
        let msg = entry.msg
        // v2.0.60：跨天 → 日期分隔线（微信式：昨天/M月d日）
        if let prevTs = entry.prevMsg?.timestamp,
           let curTs = msg.timestamp,
           !Calendar.current.isDate(Date(timeIntervalSince1970: curTs / 1000),
                                   inSameDayAs: Date(timeIntervalSince1970: prevTs / 1000)) {
            dateDivider(curTs)
        }
        // 相邻消息间隔 >5 分钟：插入居中时间分隔（微信式）
        if let prevTs = entry.prevMsg?.timestamp,
           let curTs = msg.timestamp,
           curTs - prevTs > 300_000 {
            timeDivider(curTs)
        }
        chatMessageBubble(msg)
            .id(msg.id)
            // v3.3.0：多选模式 → 全行可点勾选 + 右上角选中圆圈
            .overlay {
                if selectMode {
                    selectOverlay(for: msg)
                }
            }
            // 气泡出现动效：淡入 + 轻微上移（灵动）
            // v2.0.38：去掉 .animation(value: messages.count)——
            // 批量清空（清空会话/新建会话）时全 cell 同时移除的 spring 动画曾导致闪退
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)),
                                    removal: .opacity))
    }

    /// v3.0.51：单条消息气泡构造——拆独立方法（防消息列表 ForEach 内 type-check 超时）
    @ViewBuilder
    private func chatMessageBubble(_ msg: ChatMessage) -> some View {
        MessageBubble(message: msg,
                      isHighlighted: msg.id == highlightMessageID) {
            regenerate(at: msg.id)
        } onBigBang: {
            bigBangPayload = BigBangPayload(text: msg.content)
        } onQuote: {
            quotedMessage = msg
            inputFocus = true
        } onDelete: {
            deleteMessage(msg)
        } onShare: {
            shareMessage(msg)
        } onImageTap: {
            openImageViewer(for: msg)
        } onRetry: {
            retryMessage(msg)
        } onWithdraw: {
            withdrawMessage(msg)
        } onPin: { text in
            pinStore.add(content: text, sourceSessionId: chat.sessionId, sourceRole: msg.role)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } onAIImageTap: { url in
            openAIImage(url)
        } onMultiSelect: {
            // v3.3.0：长按菜单「多选」——进入多选模式并预选本条
            if stream.isStreaming {
                selectBlocked = true
            } else {
                inputFocus = false
                selectedMsgIDs.removeAll()
                selectedMsgIDs.insert(msg.id)
                withAnimation(.easeOut(duration: 0.2)) { selectMode = true }
            }
        }
    }

    /// v3.0.81：上下文使用率指示器（独立计算属性——含嵌套三元+插值，抽离防 body type-check 超时）
    private var contextUsageBar: some View {
        Group {
            if chat.contextInfo.count > 10 {
                let usage = chat.contextUsage(maxTokens: 4000)
                let percent = Int(usage * 100)
                let levelColor: Color = percent > 80 ? .red : (percent > 50 ? .orange : .green)
                HStack(spacing: 4) {
                    Spacer()
                    Circle()
                        .fill(levelColor)
                        .frame(width: 6, height: 6)
                    Text("\(percent)%")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("\(chat.contextInfo.tokens) tokens")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 2)
            }
        }
    }

    // MARK: - v3.3.0 多选合并发送（勾选消息 → 合并卡片图片 → 系统分享）

    /// 消息气泡右上角选择覆盖层：全行点击勾选 + 选中圆圈指示
    private func selectOverlay(for msg: ChatMessage) -> some View {
        let sel = selectedMsgIDs.contains(msg.id)
        return ZStack(alignment: .topTrailing) {
            // 全行点击捕获层——选择模式拦截下层手势（长按菜单/文本选择不误触），点击即勾选
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleSelect(msg) }
            Image(systemName: sel ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(sel ? Color.blue : Color.secondary.opacity(0.55))
                .background(Circle().fill(Color(uiColor: .systemBackground)).padding(-1.5))
                .padding(.trailing, 6)
                .padding(.top, 2)
                .allowsHitTesting(false)
        }
    }

    /// 勾选/取消勾选
    private func toggleSelect(_ msg: ChatMessage) {
        if selectedMsgIDs.contains(msg.id) {
            selectedMsgIDs.remove(msg.id)
        } else {
            selectedMsgIDs.insert(msg.id)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// 全选/取消全选
    private func toggleSelectAll() {
        if selectedMsgIDs.count >= chat.messages.count {
            selectedMsgIDs.removeAll()
        } else {
            selectedMsgIDs = Set(chat.messages.map(\.id))
        }
    }

    /// 退出选择模式（ChatViewExport.mergeAndShare 跨文件调用，故 internal）
    func exitSelectMode() {
        inputFocus = false
        withAnimation(.easeOut(duration: 0.2)) {
            selectMode = false
            selectedMsgIDs.removeAll()
        }
    }

    /// 选择模式底部操作条（替代输入栏）：全选 + 已选计数 + 取消 + 合并发送
    private var mergeSelectBar: some View {
        HStack(spacing: 14) {
            Button {
                toggleSelectAll()
            } label: {
                Text(selectedMsgIDs.count >= chat.messages.count && !chat.messages.isEmpty ? "取消全选" : "全选")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            Text("已选 \(selectedMsgIDs.count) 条")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button {
                exitSelectMode()
            } label: {
                Text("取消")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Button {
                mergeAndShare()
            } label: {
                Text("合并发送")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        selectedMsgIDs.isEmpty
                            ? AnyShapeStyle(Color.secondary.opacity(0.35))
                            : AnyShapeStyle(LinearGradient(colors: [.blue, .indigo],
                                             startPoint: .leading, endPoint: .trailing)),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(selectedMsgIDs.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// v3.0.15：流式输出气泡——拆独立计算属性（防 messageList 巨型 body type-check 超时）
    @ViewBuilder
    private var streamingBubble: some View {
        MessageBubble(
            message: ChatMessage(role: "assistant", content: stream.content, timestamp: nil, agent: stream.isAgent),
            onAIImageTap: { url in openAIImage(url) },   // v2.0.128：流式中 AI 图片可点（参数须在 streamingAvatar 前）
            streamingAvatar: true,   // v3.0.15：AI 输出中头像 = 粒子球
            streamingText: true   // v3.0.17：流式长文用 SwiftUI Text 渲染（根治 UITextView 锁窄缩小）
        )
        .id("streaming")
    }

    private var messageList: some View {
        ZStack {
            // v2.0.40：clearing 期间直接显示欢迎页（列表已卸载，数据稍后清空）
            if (chat.messages.isEmpty || clearing) && !stream.isStreaming {
                welcomeView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 120)
                    .id("welcome")
            } else {
            ScrollViewReader { proxy in
            ScrollView {
                // v2.0.40：LazyVStack → VStack（懒加载在批量移除时有复用状态残留，
                // 普通 VStack 全量渲染，移除只是简单数组变化，彻底绕开崩溃）
                // v2.0.132：VStack → LazyVStack——清空/新建已走两步走（先切欢迎页卸载
                // 列表再清数据），批量移除崩溃路径不复存在；长聊天记录仅渲染可见气泡，
                // 修复长文本滑动/左右切页卡顿
                LazyVStack(spacing: 10) {
                                        // v3.0.51 A2：顶部"加载更早"按钮（会话长于可见窗口时显示）
                                        if visibleStartIndex > 0 {
                                            Button {
                                                withAnimation(.easeOut(duration: 0.25)) {
                                                    displayLimit += Self.loadMoreStep
                                                }
                                            } label: {
                                                HStack(spacing: 5) {
                                                    Image(systemName: "chevron.up")
                                                        .font(.system(size: 10, weight: .semibold))
                                                    Text("加载更早 \(min(visibleStartIndex, Self.loadMoreStep)) 条")
                                                        .font(.system(size: 12, weight: .medium))
                                                }
                                                .foregroundStyle(.secondary)
                                                .padding(.vertical, 8)
                                                .padding(.horizontal, 14)
                                                .background(Color.secondary.opacity(0.08), in: Capsule())
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.bottom, 2)
                                        }
                                        ForEach(visibleMessagesCache) { entry in
                                                                    // v3.0.51：整行（日期分隔 + 时间分隔 + 气泡）拆辅助函数，ForEach 内只留薄调用
                                                                    // v3.4.2：吃 entry 快照（含 prevMsg），渲染不触碰可变 chat.messages
                                                                    messageRow(entry: entry)
                                                                }
                        // v3.0.18：云端工具执行卡片（显示在流式气泡上方）
                        // v3.0.18 fix：改用 @Observable cloudStreamUI.toolCards（引用类型，闭包安全）
                        if !cloudStreamUI.toolCards.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(cloudStreamUI.toolCards) { card in
                                    ToolCardView(item: card)
                                }
                            }
                            .padding(.horizontal, 44)   // 左侧留出 AI 头像位
                            .transition(.opacity)
                        }
                        if stream.isStreaming {
                            if stream.content.isEmpty {
                                // 思考中动画（三点跳动，气泡加大版）
                                // v3.0.15：恢复 v3.0.12 之前的原始三点动画（思考球 orbits 粒子已移除，改由输出头像承担粒子球）
                                // v3.0.18：思考期头像也改为粒子球（38pt，用户要求全程粒子球头像）
                                HStack(alignment: .top, spacing: 10) {
                                    ZStack {
                                        Circle()
                                            .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        OrbCanvasView(mode: .orbits, size: 38,
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
                                    }
                                    .frame(width: 38, height: 38)
                                    // v2.0.35：去掉"思考中"文字（用户要求），保留三点跳动动画
                                    TypingIndicator()
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 15)
                                        .background(Color(uiColor: .systemGray5))
                                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                        .frame(minHeight: 44)
                                    Spacer(minLength: 48)
                                }
                                .id("streaming")
                                .transition(.opacity)
                            } else {
                                streamingBubble
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .id("messages")   // v2.0.39：与欢迎页分支区分身份
                }
            // v2.0.50：.scrollPosition 在隐藏页内容清空时是已知崩溃点（新建会话=TabView
            // 隐藏页清空→scrollPos 更新异常→SIGTRAP）→ 换 GeometryReader + PreferenceKey 检测滚动
            // v2.0.111：消息区背景透明（ScrollView 默认白底遮住上方 logo/内容）
            .scrollContentBackground(.hidden)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ScrollOffsetKey.self,
                                            value: geo.frame(in: .named("scrollspace")).minY)
                }
            )
            // v2.0.86h：Dock 滑动隐藏已删除（从未生效，手动开关替代）
            // v2.0.43：搜索定位——滚动到命中消息并高亮 2 秒
            .onChange(of: chat.highlightTarget?.content) { _, _ in
                guard let t = chat.highlightTarget,
                      let idx = chat.indexOfMessage(role: t.role, contentPrefix: t.content) else { return }
                let mid = chat.messages[idx].id
                highlightMessageID = mid
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(mid, anchor: .center)
                }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.easeOut(duration: 0.3)) { highlightMessageID = nil }
                }
            }
            // v2.0.58：两步走新建会话——先切欢迎页（列表卸载），下一帧再清数据
            // （v2.0.44 的切tab+延迟清空在 tab 过渡期仍崩，清空按钮的两步走才是稳定模式）
            .onChange(of: chat.pendingNewSession) { _, pending in
                guard pending else { return }
                clearing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    // v3.0.11 fix：新建会话前先清队列+停流——原实现旧流仍在跑，
                    // 回答内容会持续显示/落进新会话（同 bot 串话根因族）
                    clearPendingQueue()
                    if stream.isStreaming { stream.stop(auth: auth) }
                    withAnimation(nil) { chat.newSession() }
                    chat.pendingNewSession = false
                    clearing = false
                }
            }
            // v2.0.88：切换/新建会话 → 清空待发队列（避免排队消息发到别的会话）
            .onChange(of: chat.sessionId) {
                clearPendingQueue()
                cloudStreamUI.toolCards = []   // v3.0.18 fix：工具卡片跨会话残留清理（通过 @Observable 引用类型）
                // v3.0.51 A1：会话加载后重传残留 base64 图片（重启续传/失败重传）
                Task { await chat.retryPendingImageUploads(auth: auth) }
            }
            // 滚动消息区即收起键盘（微信式）
            .scrollDismissesKeyboard(.immediately)
            // v3.4.1：底部上拉拉取收件箱——官方滚动几何回调（每帧实时含过拉 bounce）。
            // overscroll = offset 超底部边界量；触底再上拉为正。详见 InboxPullRefresh.swift
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                let maxY = geo.contentSize.height - geo.containerSize.height
                return geo.contentOffset.y - max(0, maxY)
            } action: { _, overscroll in
                inboxPullHandleScroll(overscroll: overscroll)
            }
            // v2.0.135：ScrollView 是 UIKit 桥接视图，其区域点击不冒泡到 ZStack 根手势
            // （v2.0.112b 把 onTapGesture 移到 ZStack 后，有消息时点空白收键盘失效，用户复报）
            // → ScrollView 自身也挂一个：点消息区空白收键盘（点气泡由 MessageBubble 手势优先消费，不受影响）
            .onTapGesture {
                inputFocus = false
            }
            .onChange(of: chat.messages.count) {
                refreshVisibleMessages()
                scrollBottom(proxy)
            }
            .onChange(of: displayLimit) { _, _ in
                refreshVisibleMessages()
            }
            .onChange(of: stream.content) {
                scrollBottom(proxy)
            }

        }
        }
        }
        // v2.0.112b：点消息区空白收键盘——原 onTapGesture 只挂 ScrollView（有消息才显示），
        // 欢迎页（无消息）状态点空白无法收键盘 → 移到 ZStack 根统一生效
        // v2.0.135：ZStack 无 contentShape 时透明空白不可命中（此前只有点 logo/气泡才触发收键盘）
        // → 补 contentShape(Rectangle()) 让整片区域可命中；有消息场景由 ScrollView 自身手势兜底
        .contentShape(Rectangle())
        .background(Color.clear)
        .onTapGesture {
            inputFocus = false
        }
        .task {
            // v3.0.51 A2 fix：初始化可见消息缓存（首次渲染不为空）
            refreshVisibleMessages()
            // 服务器连接状态检测（真实绿点）
            let r = await auth.testConnection(server: auth.serverURL)
            serverOnline = r.hasPrefix("✅")
            // v3.0.7：Bot 列表加载（节流版：5min 缓存内不重复请求，免切页触发网络+状态翻转）
            if !CloudConfig.shared.isCloudMode {
            }
        }
        .sheet(isPresented: $showModelSheet) {
            ModelSheet(current: modelName)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $bigBangPayload) { payload in
            BigBangView(text: payload.text)
        }
        // v2.0.59：上下文过长提示（60+ 条建议压缩）
        .alert("上下文较长", isPresented: $showLongContextAlert) {
            Button("压缩后发送") {
                if let p = pendingSend {
                    chat.compressContext()
                    inputText = ""   // v2.0.102：确认发送才清空（取消保留草稿）
                    pendingImage = nil
                    pendingImageData = nil
                    if p.imageData != nil {
                        // v3.0.37：图片持久化
                        Task {
                            let persisted = await persistImageIfNeeded(p.imageData)
                            sendCore(text: p.text, imageData: persisted)
                        }
                    } else {
                        sendCore(text: p.text, imageData: nil)
                    }
                }
                pendingSend = nil
            }
            Button("直接发送") {
                if let p = pendingSend {
                    inputText = ""   // v2.0.102：确认发送才清空（取消保留草稿）
                    pendingImage = nil
                    pendingImageData = nil
                    if p.imageData != nil {
                        // v3.0.37：图片持久化
                        Task {
                            let persisted = await persistImageIfNeeded(p.imageData)
                            sendCore(text: p.text, imageData: persisted)
                        }
                    } else {
                        sendCore(text: p.text, imageData: nil)
                    }
                }
                pendingSend = nil
            }
            Button("取消", role: .cancel) { pendingSend = nil }
        } message: {
            Text("当前会话已 \(chat.messages.count) 条消息，继续发送可能接近模型上下文上限。压缩后仅保留最近 20 条（早期内容替换为摘要标记）。")
        }
        // v3.0.81：AI 摘要压缩中提示
        .alert("正在压缩上下文", isPresented: $showCompressingAlert) {
            // 无按钮，自动消失
        } message: {
            Text("AI 正在总结历史消息，请稍候...")
        }
        // v2.0.36：图片大图查看器（v2.0.62 相册翻页）
        .fullScreenCover(item: $viewerPayload) { p in
            ImageViewer(images: p.images, index: p.index)
        }
        // v2.0.36：导出会话记录
        .fileExporter(isPresented: $showExporter,
                      document: ChatLogDocument(text: exportText),
                      contentType: .plainText,
                      defaultFilename: "轻聊会话") { _ in }
        .fileExporter(isPresented: $showMarkdownExporter,
                      document: ChatMarkdownDocument(text: exportMarkdown),
                      contentType: .plainText,
                      defaultFilename: "轻聊会话") { _ in }
        .fileExporter(isPresented: $showPDFExporter,
                      document: ChatPDFDocument(data: exportPDFData ?? Data()),
                      contentType: .pdf,
                      defaultFilename: "轻聊会话") { _ in }
        // v2.0.36：录音权限被拒提示
    }

    /// 思考中动画（三点跳动）
    struct TypingIndicator: View {
        @State var animating = false
        var body: some View {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 8, height: 8)
                        .offset(y: animating ? -4 : 4)
                        .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.15), value: animating)
                }
            }
            .onAppear { animating = true }
        }
    }

    /// 相邻消息间隔 >5 分钟的居中时间分隔
    private func timeDivider(_ ts: Double) -> some View {
        let d = Date(timeIntervalSince1970: ts / 1000)
        let text: String
        if Calendar.current.isDateInToday(d) {
            text = d.formatted(date: .omitted, time: .shortened)
        } else if Calendar.current.isDateInYesterday(d) {
            text = "昨天 " + d.formatted(date: .omitted, time: .shortened)
        } else {
            text = d.formatted(date: .abbreviated, time: .shortened)
        }
        return Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    /// v2.0.60：跨天日期分隔线（灰色胶囊，微信式）
    private func dateDivider(_ ts: Double) -> some View {
        let d = Date(timeIntervalSince1970: ts / 1000)
        let text: String
        if Calendar.current.isDateInToday(d) {
            text = "今天"
        } else if Calendar.current.isDateInYesterday(d) {
            text = "昨天"
        } else {
            text = d.formatted(date: .abbreviated, time: .omitted)
        }
        return Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }

    private func scrollBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            if stream.isStreaming {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let last = chat.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - 发送

    /// v2.0.116：AI 总结会话（菜单按钮 → 自动发总结请求走正常流式）
    func summarizeSession() {
        guard !chat.messages.isEmpty else { return }
        guard !stream.isStreaming else { return }
        sendCore(text: "请用简洁的要点总结我们这次对话（分点列出，突出结论和待办）", imageData: nil)
    }

    /// v3.0.37：图片持久化——base64 图片上传 NAS 换 URL（节省内存/跨设备可见/重启不丢）
    /// 已是 http 或非数据 URL 原样返回；上传失败降级回 base64（保证发送不中断）
    func persistImageIfNeeded(_ imageDataURL: String?) async -> String? {
        guard let img = imageDataURL, !img.hasPrefix("http") else { return imageDataURL }
        // v3.0.55：蜂窝不再 await URL 上传——v3.0.54 阻塞路径卡在分片末屏响应导致图不上屏/不发。
        // 蜂窝直接短路返回，交给 sendCore 的 compressForCellular（压缩 base64）立即上屏发送，不挂起。
        if NetworkMonitor.shared.isCellular { return img }
        var b64 = img
        if let comma = img.firstIndex(of: ","), img[..<comma].hasPrefix("data:image/") {
            b64 = String(img[img.index(after: comma)...])
        }
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return img }
        return await chat.uploadImage(data, auth: auth) ?? img
    }

    func send() {
        var text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let img = pendingImageData
        // v2.0.88f：去掉 isStreaming 拦截——AI 回答中发送走 sendCore 排队路径
        guard !text.isEmpty || img != nil else { return }
        // v2.0.36：引用回复（markdown 引用块注入，AI 可见上下文）
        if let q = quotedMessage, !text.isEmpty {
            let quoted = q.content.replacingOccurrences(of: "\n", with: "\n> ")
            text = "> " + quoted + "\n\n" + text
        }
        // v2.0.102：清空输入框移到发送确认之后——长上下文弹窗点"取消"时草稿保留（修复草稿丢失）
        quotedMessage = nil

        // v3.0.81：上下文自动管理
        let autoCompress = UserDefaults.standard.bool(forKey: "qingliao_context_auto_compress")
        let threshold = UserDefaults.standard.integer(forKey: "qingliao_context_threshold")
        let effectiveThreshold = threshold > 0 ? threshold : 4000

        if autoCompress && chat.needsCompress(threshold: effectiveThreshold) {
            // 自动压缩：先显示提示，后台执行 AI 摘要
            pendingSend = (text, img)
            showCompressingAlert = true
            Task {
                let success = await chat.compressContextWithAI(auth: auth)
                showCompressingAlert = false
                if success {
                    await chat.saveToServer(auth: auth)
                }
                // 压缩完成后发送
                if let p = pendingSend {
                    inputText = ""
                    pendingImage = nil
                    pendingImageData = nil
                    if p.imageData != nil {
                        let persisted = await persistImageIfNeeded(p.imageData)
                        sendCore(text: p.text, imageData: persisted)
                    } else {
                        sendCore(text: p.text, imageData: nil)
                    }
                    pendingSend = nil
                }
            }
            return
        }

        // 原有逻辑：消息数>60 时提示
        if chat.messages.count > 60 {
            pendingSend = (text, img)
            showLongContextAlert = true
            return
        }
        inputText = ""
        pendingImage = nil
        pendingImageData = nil
        if img != nil {
            // v3.0.37：图片持久化——base64 先上传 NAS 换 URL 再发送（旧消息/失败仍走 base64）
            Task {
                let persisted = await persistImageIfNeeded(img)
                sendCore(text: text, imageData: persisted)
            }
        } else {
            sendCore(text: text, imageData: nil)
        }
    }

    /// v2.0.59：发送核心（send / 失败重试共用）
    /// v2.0.88：AI 回答中发送不再被拦截——消息上屏 + 入队，当前回答结束后自动逐条发送
    /// v2.0.102：sendingLock 同步置位——防极快双击时 isStreaming 尚未置位导致双流竞态
    func sendCore(text: String, imageData: String?) {
        // v3.4.x：同内容短时间幂等（60s 内相同文本+同会话只发一次，防抖动/重试/恢复重复投递）
        let now = Date().timeIntervalSince1970
        if let last = lastSentSignature, last.sessionId == chat.sessionId, last.text == text, now - last.ts < 60 {
            return
        }
        lastSentSignature = (chat.sessionId, text, now)
        // v3.0.52：蜂窝下 base64 图 body 过大 → 先超强压缩（uploadImage 蜂窝大概率失败退回 base64 大 body，
        // 导致 CFStream/relay 载不动 → 后端 bad json 400；压小后直连可过）
        let imageData = compressForCellular(imageData)
        guard !text.isEmpty || imageData != nil else { return }
        // v3.0.19 review fix #1：语音指令标志在此一次性消费——标记本消息 + 转播报意图 + 清空 sid

        // v2.0.126：蜂窝 relay 3.5KB 限制自动分段（粘贴长文本不丢内容）
        // relay payload = base64url(JSON{m,p,h,b}) 进 URL；限制 ~3.5KB；WiFi 直连无限制不走此分支
        if imageData == nil, NetworkMonitor.shared.isCellular, text.count > 200 {
            let hist = chat.historyPayload()
            if relayPayloadLength(messages: hist + [["role": "user", "content": text]]) > 3400 {
                let chunks = splitLongText(text)
                if chunks.count > 1 {
                    // 顺序：第一段先发（流式中走排队路径排最前），后续段再入队
                    sendCore(text: chunks[0], imageData: nil)
                    for c in chunks.dropFirst() {
                        var m = ChatMessage.local(role: "user", content: c, imageDataURL: nil)
                        m.queued = true
                        withAnimation(.spring(duration: 0.25, bounce: 0.15)) {
                            chat.append(m)
                        }
                        pendingQueue.append(PendingSend(text: c, imageData: nil))
                    }
                    Task { await chat.saveToServer(auth: auth) }
                    return
                }
            }
        }
        if stream.isStreaming {
            // 排队路径：消息立即显示（标记排队中），回答结束后自动发送
            var msg = ChatMessage.local(role: "user", content: text, imageDataURL: imageData)
            msg.queued = true
            withAnimation(.spring(duration: 0.25, bounce: 0.15)) {
                chat.append(msg)
            }
            pendingQueue.append(PendingSend(text: text, imageData: imageData))
            Task { await chat.saveToServer(auth: auth) }
            return
        }
        guard !sendingLock else { return }   // 双击保护：第一次发送的流尚未置位时，第二次直接忽略
        sendingLock = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // v2.0.65：发送通知 → Dock 聊天图标轻跳
        NotificationCenter.default.post(name: .qingliaoSent, object: nil)
        var msg = ChatMessage.local(role: "user", content: text, imageDataURL: imageData)
        // v2.0.59：单条插入动效（批量移除才崩，插入安全）
        withAnimation(.spring(duration: 0.25, bounce: 0.15)) {
            chat.append(msg)
        }
        // v3.3.0 fix：消息落盘必须在 append 后立即执行（不能依赖流式回答后才 saveToServer）。
        // 否则 App 被杀/网络断开/流式失败时，用户刚发的消息只存在内存里，丢了。
        Task { await chat.saveToServer(auth: auth) }
        startStream(for: msg)
    }

    /// v2.0.88：启动流式回答（消息已在列表；失败标记/回复完成/队列联动统一在这里）
    /// v2.0.102：记录发起会话——回答期间切换会话则丢弃结果（防跨会话污染）；完成回调释放 sendingLock
    /// v3.0：云端模式走 CloudBackend 直连 SSE（不经过 NAS 后端）
    func startStream(for msg: ChatMessage) {
        // v3.0 云端模式：直连大模型 API
        if CloudConfig.shared.isCloudMode {
            startCloudStream(for: msg)
            return
        }
        // v2.0.126：蜂窝 relay 3.5KB 限制——历史从后往前保留直到 payload 达标（只影响蜂窝兜底路径）
        var history = chat.historyPayload()
        if NetworkMonitor.shared.isCellular {
            history = relaySafeHistory(history)
        }
        let startSid = chat.sessionId

        // v3.0.81：统一模型优先级链（免费 > 视觉 > Agent > 主模型）
        let (useModel, useProvider) = resolveModel(hasImage: msg.imageDataURL != nil)

        Task {
            stream.pendingUserMsgId = msg.id   // v3.3.3：记录发起 user 消息，恢复/延迟回调落库锚点
            await stream.start(
                auth: auth,
                sessionId: chat.sessionId,
                model: useModel,
                provider: useProvider,
                messages: history
            ) { success, error in
                sendingLock = false   // 无论结果，先释放发送锁
                guard chat.sessionId == startSid else { return }   // 已切换会话 → 本次结果丢弃
                if !success {
                    chat.markFailed(id: msg.id)   // v2.0.59 失败标记 → 重试按钮
                    // v3.0.19：限流错误友好提示（sensenova 等免费额度 tpm 爆了 → 提示换路由）
                    let friendly = Self.friendlyStreamError(error)
                    chat.upsertAssistant(stream.content.isEmpty ? "⚠️ \(friendly)" : stream.content + "\n\n⚠️ \(friendly)", agent: stream.isAgent, afterUserID: msg.id)
                } else {
                    chat.upsertAssistant(stream.content, agent: stream.isAgent, afterUserID: msg.id)
                    showSentOK()
                    // v3.1.9 fix：流式完成 → 快拉收件箱（后端 _maybe_push_app 已入队本次回复，
                    // 此刻 isStreaming=false 且回复已落库 → 去重命中、不重复注入）
                    InboxStore.shared.triggerFastPoll()
                    // v3.0.19：语音指令回复完成 → TTS 播报摘要

                    // v2.0.36：App 退后台时 AI 回复完成发本地通知（v2.0.60 携带会话 id）
                    if UIApplication.shared.applicationState != .active {
                        NotificationHelper.notify(title: "轻聊", body: "AI 回复完成，点击查看",
                                                  sessionId: chat.sessionId)
                    }
                }
                // 保存会话到后端（会话记录同步）
                // v3.0.11 fix：快照参数化——同步捕获 sid/messages/title，防止 Task 延迟执行时
                // 读到切换后的新会话（空/新 bot 消息）而把内容存错会话
                let saveSid = chat.sessionId
                let saveMsgs = chat.messages
                let saveTitle = chat.title
                Task { await chat.saveToServer(auth: auth, sessionId: saveSid, messages: saveMsgs, title: saveTitle) }
                // v2.0.88：回答完成（成功/失败/停止）→ 自动发送队列中的下一条
                if !pendingQueue.isEmpty {
                    let next = pendingQueue.removeFirst()
                    sendQueued(next)
                }
            }
        }
    }

    // MARK: - v3.0 云端流式直连（SSE 增量拼接，UI 与本地模式一致）

    /// 云端模式回答：直连 OpenAI 兼容端点，逐段追加 assistant 内容
    /// v3.0.18：改用 stream.content 驱动 streamingBubble（粒子头像 + SwiftUI Text 渲染），结束落库；
    ///         接入 CloudToolLoop 本地工具调用（function calling：日历/提醒/计时器/天气/剪贴板/计算器/通知）
    /// v3.0.84fix：private→internal（让 ChatViewExport 的 sendFile 云端分支也能调用）
    func startCloudStream(for msg: ChatMessage) {
        let startSid = chat.sessionId
        // v3.0.18：启用流式气泡（三点 / 粒子头像 / Text 渲染）
        stream.isStreaming = true
        stream.isDone = false
        stream.content = ""
        stream.isAgent = false
        cloudStreamUI.toolCards = []  // v3.0.18 fix：通过 @Observable 引用类型重置
        CloudBackend.shared.isStreaming = true   // v3.0.2：标记云端流式进行中（驱动 Siri 发光）
        // v3.0.18 fix：Task 显式捕获引用对象（chat/stream @Environment 类引用），
        // 避免隐式捕获 struct 值副本导致 Task 内 self 旧副本 → 后续更新丢失
        Task { [chat = self.chat, stream = self.stream] in
            defer {
                sendingLock = false
                stream.isStreaming = false
                stream.isDone = true
                CloudBackend.shared.isStreaming = false
            }
            do {
                let history = chat.historyPayload()
                // v3.0.18：工具循环内 escaping 闭包修改局部 var 触发 Swift 6 并发错误 → 用 @MainActor 容器
                let acc = CloudTextAccumulator()
                // v3.0.18 fix：闭包不再捕获 [self]（struct 值拷贝 → Task 内 self 旧副本 → 更新丢失），
                // 改为捕获具体引用对象：chat/stream 是 @Environment 类引用，cloudStreamUI 是 @Observable 类引用
                let finalText = await CloudToolLoop.shared.run(
                    messages: history,
                    confirmHandler: { [chat = self.chat, toolGate = self.toolGate] pending in
                        // v3.0.18 review：确认弹窗期间切了会话 → 拒绝执行（防日历/提醒建到别的会话场景）
                        guard chat.sessionId == startSid else { return false }
                        return await self.confirmToolRun(pending, toolGate: toolGate)
                    },
                    events: { [chat = self.chat, stream = self.stream, ui = self.cloudStreamUI, acc] event in
                        guard chat.sessionId == startSid else { return }
                        switch event {
                        case .text(let delta):
                            acc.text += delta
                            // v3.0.41 性能：流式节流——每 delta 更新 stream.content 触发全树重建，
                            // 超长文本高频重建=卡死主因；限 50ms 合并一次（视觉仍连贯）
                            let now = Date()
                            if ui.lastStreamFlush == nil || now.timeIntervalSince(ui.lastStreamFlush!) >= 0.05 {
                                ui.lastStreamFlush = now
                                stream.content = acc.text
                            }
                        case .toolCard(let title, let ok):
                            ui.toolCards.append(ToolCardItem(title: title, ok: ok))
                        case .done(let full):
                            acc.text = full
                            stream.content = full
                        case .error(let err):
                            // v3.0.18 review fix #3：错误同时拼入 acc——run 返回 nil 后落库走 acc.text 路径，真实错误不丢失
                            // v3.0.19：限流错误友好提示（与本地模式一致）
                            let friendly = Self.friendlyStreamError(err)
                            let errText = acc.text.isEmpty ? "⚠️ " + friendly : acc.text + "\n\n⚠️ " + friendly
                            acc.text = errText
                            stream.content = errText
                        }
                    }
                )
                guard chat.sessionId == startSid else { return }
                if let finalText, !finalText.isEmpty {
                    // 落库 assistant 消息（替换掉 streamingBubble）
                    chat.upsertAssistant(finalText, afterUserID: msg.id)
                    showSentOK()
                    // v3.0.19：语音指令回复完成 → TTS 播报摘要

                    if UIApplication.shared.applicationState != .active {
                        NotificationHelper.notify(title: "轻聊", body: "AI 回复完成，点击查看",
                                                  sessionId: chat.sessionId)
                    }
                } else if acc.text.isEmpty {
                    chat.markFailed(id: msg.id)
                    chat.upsertAssistant("⚠️ 云端未返回内容", afterUserID: msg.id)
                } else {
                    chat.upsertAssistant(acc.text, afterUserID: msg.id)
                }
                CloudSessionStore.shared.saveChat(store: chat)
                finishCloudQueue()
            } catch {
                guard chat.sessionId == startSid else { return }
                chat.markFailed(id: msg.id)
                chat.upsertAssistant("⚠️ \(error.localizedDescription)", afterUserID: msg.id)
                CloudSessionStore.shared.saveChat(store: chat)
                finishCloudQueue()
            }
        }
    }

    /// v3.0.18：工具写操作确认弹窗（await 用户点确认/取消；60s 无响应自动取消防挂死）
    /// v3.0.18 fix：toolGate 改为参数传入（不捕获 self struct），闭包仅操作 @Observable 类引用
    private func confirmToolRun(_ pending: PendingToolConfirm, toolGate: ToolConfirmGate) async -> Bool {
        await withCheckedContinuation { cont in
            toolGate.pending = pending
            toolGate.onConfirm = { ok in
                cont.resume(returning: ok)
                toolGate.pending = nil
                toolGate.onConfirm = nil
            }
            // 兜底：60s 用户无操作 → 自动取消（防 continuation 永不 resume 挂死工具循环）
            let gate = toolGate
            Task {
                try? await Task.sleep(for: .seconds(60))
                guard gate.onConfirm != nil else { return }
                gate.onConfirm?(false)
            }
        }
    }

    /// 云端流式增量：更新最后一条 assistant 消息内容（流式过程中不追加新消息，只更新）
    private func cloudUpsertDelta(_ text: String) {
        if let idx = chat.messages.indices.last,
           chat.messages[idx].role == "assistant" {
            // 更新最后一条 assistant（重建 struct，保留时间戳）
            let old = chat.messages[idx]
            chat.messages[idx] = ChatMessage(role: "assistant", content: text,
                                             timestamp: old.timestamp ?? Date().timeIntervalSince1970 * 1000)
        } else {
            // 无 assistant 尾巴 → 新建（首段）
            chat.upsertAssistant(text)
        }
    }

    /// 云端模式回答完成 → 自动发送队列下一条
    private func finishCloudQueue() {
        if !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            sendQueued(next)
        }
    }

    // MARK: - v2.0.126 蜂窝 relay 3.5KB 限制（粘贴长文本自动分段）

    /// 模拟 SafariRelay.relay 的最终 URL 长度：payload={m,p,h,b} → base64url → /r?r=<b64>
    /// 用于发送前预判是否超限（限制 ~3.5KB = 3584，保守取 3400）
    /// v3.0.7：bot 字段同步进估算（与 streamStart payload 一致，否则低估长度导致 relay 超限）
    private func relayPayloadLength(messages: [[String: Any]]) -> Int {
        var body: [String: Any] = ["sessionId": chat.sessionId,
                                   "model": modelName,
                                   "provider": provider,
                                   "messages": messages,
                                   "pushEnabled": false,
                                   "agentEnabled": true]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let bodyStr = String(data: bodyData, encoding: .utf8) else { return Int.max }
        let payload: [String: Any] = ["m": "POST", "p": "/api/stream/start", "b": bodyStr]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return Int.max }
        let b64Len = Int(ceil(Double(jsonData.count) * 4 / 3))   // base64url ≈ 4/3 膨胀
        return auth.serverURL.count + 8 + b64Len                 // https://host:port/r?r=
    }

    /// 蜂窝下历史从后往前保留，直到 payload ≤ 3400（AI 至少看到最近上下文 + 新消息）
    /// v3.0.53 fix：带图消息绝不能因 3400 relay 上限被裁成空数组（否则蜂窝发图 → messages 空 → 后端 400 messages required）。
    /// 带图消息走 CFStream 直连（不受 relay 3400 限制），必须保留图片本身；此函数仅作 relay 兜底的历史裁剪。
    private func relaySafeHistory(_ history: [[String: Any]]) -> [[String: Any]] {
        let limit = 3400
        if relayPayloadLength(messages: history) <= limit { return history }
        var kept: [[String: Any]] = []
        for m in history.reversed() {
            let hasImage = (m["content"] as? [[String: Any]])?.contains { ($0["type"] as? String) == "image_url" } ?? false
            let test = [m] + kept
            let within = relayPayloadLength(messages: test) <= limit
            if within || hasImage {
                kept = test
            }
            if !within && !hasImage { break }
        }
        return kept
    }

    /// 长文本拆段：每段使「历史 + 该段」payload ≤ 3400（二分最大前缀，至少 1 字符防死循环）
    private func splitLongText(_ text: String) -> [String] {
        let limit = 3400
        let baseHistory = chat.historyPayload()
        var chunks: [String] = []
        var rest = text
        while !rest.isEmpty {
            var lo = 1, hi = rest.count
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                let prefix = String(rest.prefix(mid))
                let len = relayPayloadLength(messages: baseHistory + [["role": "user", "content": prefix]])
                if len <= limit - 100 { lo = mid } else { hi = mid - 1 }
            }
            let take = max(1, lo)
            chunks.append(String(rest.prefix(take)))
            rest = String(rest.dropFirst(take))
        }
        return chunks
    }

    /// v2.0.88：发送排队消息（消息已上屏——去掉排队标记复用该消息启动流式，不重复插入）
    func sendQueued(_ item: PendingSend) {
        guard !stream.isStreaming else { return }
        // firstIndex = FIFO：先入队的先发（内容相同也会按入队顺序）
        if let idx = chat.messages.firstIndex(where: {
            $0.queued && $0.content == item.text && $0.imageDataURL == item.imageData
        }) {
            chat.messages[idx].queued = false
            startStream(for: chat.messages[idx])
        }
        // v2.0.102：排队消息已不在列表（被删除/清空/切换）→ 直接丢弃，不重发（修复"删除后复活"）
    }

    /// v2.0.88：取消排队（停止按钮/切换会话）——清队列 + 消息恢复"已送达"状态
    func clearPendingQueue() {
        pendingQueue.removeAll()
        for i in chat.messages.indices where chat.messages[i].queued {
            chat.messages[i].queued = false
        }
    }

    /// v2.0.62：打开图片查看器（收集会话内全部图片消息 → 相册翻页）
    /// v2.0.102：索引钳制——解码失败导致 images 比 imgMsgs 短时防越界
    func openImageViewer(for msg: ChatMessage) {
        let imgMsgs = chat.messages.enumerated().filter { $0.element.imageDataURL != nil }
        let images = imgMsgs.compactMap { dataURLImage($0.element.imageDataURL ?? "") }
        guard !images.isEmpty,
              let rawIdx = imgMsgs.firstIndex(where: { $0.element.id == msg.id }) else { return }
        let idx = min(rawIdx, images.count - 1)   // v2.0.102：坏图跳过导致偏移时钳制
        viewerPayload = ImageViewPayload(images: images, index: idx)
    }

    /// v2.0.128：AI 消息内图片点击 → 打开大图查看器（单张）
    /// data URL 直接解码进查看器；http(s) URL 双通道下载（URLSession → 自签证书降级 CFStream）
    func openAIImage(_ url: String) {
        if url.hasPrefix("data:image/") {
            if let img = dataURLImage(url) {
                viewerPayload = ImageViewPayload(images: [img], index: 0)
            }
            return
        }
        guard let u = URL(string: url), url.hasPrefix("http") else { return }
        Task {
            let img = await Self.downloadImage(url: url, u: u)
            guard let img else { return }
            await MainActor.run {
                viewerPayload = ImageViewPayload(images: [img], index: 0)
            }
        }
    }

    /// 双通道下载：URLSession（外部图）→ 失败降级 StreamHTTPClient（自签证书服务器）
    @MainActor
    private static func downloadImage(url: String, u: URL) async -> UIImage? {
        if let cached = cachedRemoteImage(url) { return cached }
        if let (data, _) = try? await URLSession.shared.data(from: u),
           let img = UIImage(data: data) {
            setRemoteImageCache(url, img, cost: data.count)
            return img
        }
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
                return img
            }
        }
        return nil
    }

    /// v2.0.59：失败消息重试（移除失败标记后按原内容重发）
    func retryMessage(_ msg: ChatMessage) {
        guard !stream.isStreaming else { return }
        if let idx = chat.messages.firstIndex(where: { $0.id == msg.id }) {
            chat.messages.remove(at: idx)
        }
        sendCore(text: msg.content, imageData: msg.imageDataURL)
    }

    /// v2.0.96：退出语音转文字模式（按钮/空白点击共用）
    /// v2.0.96c：停止录音 → 上传转写 → 文字回填输入框
    /// v3.0.19：语音指令模式退出 → 停止录音 → 转写 → 自动发送（uploadAndTranscribe 内分支）
    func regenerate(at id: String) {
        guard !stream.isStreaming,
              let idx = chat.messages.firstIndex(where: { $0.id == id }) else { return }
        // 截断到该消息前（含该消息），重新生成它之后的内容
        chat.messages.removeSubrange(idx...)
        // v3.3.3：截断后的最后 user = 本轮回话锚点（回答必须落在其后，防错位复读）
        let anchorUserID = chat.messages.last(where: { $0.isUser })?.id
        // v3.0.84fix：云端模式走 startCloudStream（原直接 stream.start 打本地 NAS，云端 regenerate 全废）
        if CloudConfig.shared.isCloudMode {
            let lastUser = chat.messages.last(where: { $0.isUser })?.content ?? ""
            var m = ChatMessage.local(role: "user", content: lastUser)
            chat.append(m)
            startCloudStream(for: m)
            return
        }
        let history = chat.historyPayload()
        let lastUserHasImage = chat.messages.last(where: { $0.isUser })?.imageDataURL != nil
        // v3.0.81：统一模型优先级链（免费 > 视觉 > Agent > 主模型）
        let (useModel, useProvider) = resolveModel(hasImage: lastUserHasImage)
        Task {
            stream.pendingUserMsgId = anchorUserID   // v3.3.3：regenerate 锚点（杀后台恢复也用）
            await stream.start(auth: auth, sessionId: chat.sessionId, model: useModel,
                               provider: useProvider, messages: history) { success, error in
                if !success {
                    chat.upsertAssistant(stream.content.isEmpty ? "⚠️ \(error)" : stream.content + "\n\n⚠️ \(error)", agent: stream.isAgent, afterUserID: anchorUserID)
                } else {
                    chat.upsertAssistant(stream.content, agent: stream.isAgent, afterUserID: anchorUserID)
                    showSentOK()
                    // v3.1.9 fix：云端模式流式完成同样触发快拉（与本地模式一致）
                    InboxStore.shared.triggerFastPoll()
                }
                Task { await chat.saveToServer(auth: auth) }
            }
        }
    }

    // MARK: - v3.0.81 模型优先级链（统一供 startStream / regenerate / sendFile 使用）

    /// 模型优先级：免费模型 > 视觉模型 > Agent 模型 > 主模型
    /// - Parameter hasImage: 当前消息是否包含图片（触发视觉模型优先）
    func resolveModel(hasImage: Bool = false) -> (String, String) {
        // v3.0.57：免费模型开关——优先级最高
        if UserDefaults.standard.bool(forKey: UserDefaultsKey.freeModel) {
            let freeName = UserDefaults.standard.string(forKey: UserDefaultsKey.freeModelName) ?? "nemotron-3.5-lightning-free"
            return (freeName, "opencode-free")
        }
        // 视觉模型：含图片消息时优先
        if hasImage, let vision = CloudConfig.effectiveVisionModel() {
            return (vision.model, vision.provider)
        }
        // Agent 模型：agent 开启 + 已配置独立模型
        let agentOn = UserDefaults.standard.bool(forKey: UserDefaultsKey.agentEnabled)
        let agentModelName = UserDefaults.standard.string(forKey: UserDefaultsKey.agentModel) ?? ""
        let agentProviderName = UserDefaults.standard.string(forKey: UserDefaultsKey.agentProvider) ?? ""
        if agentOn && !agentModelName.isEmpty {
            return (agentModelName, agentProviderName)
        }
        return (modelName, provider)
    }

    /// ✅送达提示条（仅成功时显示，2.5s 后消失）
    func showSentOK() {
        withAnimation(.easeOut(duration: 0.3)) { sentOK = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { sentOK = false }
        }
    }

    /// 内联附件面板按钮（类微信 + 面板样式）
    func attachButton(_ icon: String, _ name: String, _ color: Color,
                              action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { showAttachmentMenu = false }
            action()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// v2.0.96b：发牌弹出附件按钮（idx 控制延迟，依次从底部弹出 + 回弹）
    /// v2.0.96c：onAppear 驱动（if 包裹下按钮创建即终态，值动画无效 → 子视图内部 appeared 状态）
    func menuButton(_ icon: String, _ name: String, _ color: Color, idx: Int,
                            action: @escaping () -> Void) -> some View {
        DealAttachmentButton(icon: icon, name: name, color: color, idx: idx,
                             onPick: {
                                 withAnimation(.spring(duration: 0.3, bounce: 0.2)) { showAttachmentMenu = false }
                                 action()
                             })
    }

    /// 图片压缩（PWA 同款：最长边 1280 / JPEG 0.72，超 900KB 降质）
    func compressImage(_ image: UIImage) -> String? {
        let maxSide: CGFloat = 1280
        var w = image.size.width
        var h = image.size.height
        if max(w, h) > maxSide {
            let scale = maxSide / max(w, h)
            w *= scale
            h *= scale
        }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let resized = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var quality: CGFloat = 0.72
        var data = resized.jpegData(compressionQuality: quality)
        while let d = data, d.count > 900_000, quality > 0.25 {
            quality -= 0.15
            data = resized.jpegData(compressionQuality: quality)
        }
        guard let d = data else { return nil }
        return "data:image/jpeg;base64," + d.base64EncodedString()
    }

    /// v3.0.52：蜂窝下把 base64 图压到极小，使 stream/start 的 body 能通过 CFStream 直连传输
    /// （蜂窝下 uploadImage(URLSession) 大概率失败 → 图片退回 base64 大 body → 后端 bad json 400；压小后直连可过）
    /// v3.0.53：再压狠一点 (480px/0.45) → body ~20KB，提高 CFStream 蜂窝直连通过率
    func compressForCellular(_ imageDataURL: String?) -> String? {
        guard let img = imageDataURL,
              NetworkMonitor.shared.isCellular,
              let comma = img.firstIndex(of: ","),
              img[..<comma].hasPrefix("data:image/"),
              let b64 = String(img[img.index(after: comma)...]).data(using: .ascii),
              let data = Data(base64Encoded: b64),
              let ui = UIImage(data: data)
        else { return imageDataURL }
        let maxSide: CGFloat = 480
        var w = ui.size.width
        var h = ui.size.height
        if max(w, h) > maxSide {
            let scale = maxSide / max(w, h)
            w *= scale
            h *= scale
        }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let resized = renderer.image { _ in
            ui.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        guard let d = resized.jpegData(compressionQuality: 0.45) else { return imageDataURL }
        return "data:image/jpeg;base64," + d.base64EncodedString()
    }
}   // v3.0.50：扫码球移除后 ChatView struct 闭合

// MARK: - v2.0.96c 发牌弹出附件按钮（onAppear stagger：依次从底部弹出 + 回弹）

struct DealAttachmentButton: View {
    let icon: String
    let name: String
    let color: Color
    let idx: Int
    let onPick: () -> Void
    @State var appeared = false

    var body: some View {
        Button(action: onPick) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 34)
        .rotationEffect(.degrees(appeared ? 0 : -10))
        .scaleEffect(appeared ? 1 : 0.5)
        .onAppear {
            // v2.0.98：插入帧 withAnimation 的 .delay 会被父级 transition 动画吞掉（实测发牌不生效）
            //          → 改 Task.sleep 真延迟逐张弹出
            Task {
                try? await Task.sleep(for: .seconds(Double(idx) * 0.07))
                withAnimation(.spring(duration: 0.45, bounce: 0.35)) {
                    appeared = true
                }
            }
        }
    }
}

// MARK: - 消息气泡


// MARK: - v3.0.27 长文目录弹窗

struct TOCSheet: View {
    let headers: [MarkdownRenderer.TOCItem]

    var body: some View {
        NavigationStack {
            List {
                ForEach(headers) { item in
                    HStack(spacing: 8) {
                        ForEach(0..<item.level, id: \.self) { _ in
                            Color.clear.frame(width: 8)
                        }
                        Circle()
                            .fill(Color.accentColor.opacity(0.6))
                            .frame(width: 6, height: 6)
                        Text(item.title)
                            .font(.system(size: item.level == 1 ? 16 : (item.level == 2 ? 14 : 13),
                                          weight: item.level == 1 ? .bold : .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.plain)
        }
    }
}

