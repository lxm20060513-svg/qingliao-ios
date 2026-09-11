import SwiftUI
import CoreLocation
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
    // v3.4.26：看板轮询 Leave/Refresh 通知已移除——改 DockTabView → DashboardView(isActive:) 参数直传，
    // 生命周期收进 DashboardView 自身（见 DashboardView.onChange/.task(id:)）；通知名定义随引用清除
    // v3.4.14：系统分享收件通知（DockTabView.onOpenURL 捕获分享后广播，ChatView 消费发送）
    static let qingliaoShareIncoming = Notification.Name("qingliao_share_incoming")
    // v3.4.x：任务中心「发送到当前会话」通知（TaskCenterView 广播，ChatView 消费发送）
    static let qingliaoTaskSend = Notification.Name("qingliao_task_send")
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
                // v3.4.26：正文取回复首句（后端 GET /api/stream/{taskId} 返回 content）
                NotificationHelper.notifyReply((j["content"] as? String) ?? "", sessionId: sid)
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

/// v2.0.88：排队待发消息（AI 回答中发送，当前回答结束后自动逐条发送）
/// v3.4.x：Codable —— 排队队列落盘持久化，杀 App/断网重启后自动恢复补发（不丢消息）。
struct PendingSend: Codable, Equatable {
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
    // v3.7.0：剪贴板地图链接兜底入口（地图分享面板里没有轻聊 → 「拷贝」后在聊天页一键发送）
    @State var showClipboardBanner = false
    // 已处理过的剪贴板版本号（UIPasteboard.changeCount）：同一份内容只提示一次，
    // 用户「忽略」或「已发送」后不再复现；拷贝了新内容才会再提示
    @State var clipboardChangeCount = -1
    @Environment(\.scenePhase) var scenePhase

    @State var inputText = ""
    @FocusState var inputFocus: Bool
    @State var sentOK = false
    @State var serverOnline: Bool?   // 服务器连接状态（真实绿点）
    // v3.5.1：AI 正在输入 状态——服务器侧真相兜底（App 重开/离开聊天页后仍能显示）
    @State var remoteBusy = false
    @State var remoteBusyFails = 0   // 探针连续失败次数（v3.5.2：≥5 才收起状态，防弱网抖动误灭）
    @State var probing = false       // 探针循环单例守卫
    @State var probeTick = 0         // v3.5.2：无本机标记时每 2 拍问一次服务器（12s 降频）
    // v2.0.36：引用回复 / 图片查看器 / 导出
    // v3.4.29：图片 zoom 转场命名空间（气泡小图 → 全屏大图的生长关系）
    @Namespace private var zoomNS
    @State var quotedMessage: ChatMessage?
    @State var viewerPayload: ImageViewPayload?
    @State var showMoreMenu = false
    // v3.4.24：任务中心全屏页（header 常驻小图标入口，原 DockTabView 全局 overlay 已移除）
    @State var showTaskCenter = false
    @State private var taskStore = TaskCenterStore.shared
    @State var showExporter = false
    @State var showMarkdownExporter = false
    @State var showPDFExporter = false
    // v3.4.28：导出格式选择面板 + HTML 导出
    @State var showExportSheet = false
    @State var showHTMLExporter = false
    @State var exportText = ""
    @State var exportMarkdown = ""
    @State var exportPDFData: Data?
    @State var exportHTML = ""
    @State var clearing = false          // v2.0.40 清空会话两步走标志
    // v2.0.43：快捷指令 / 搜索定位高亮
    @State var showQuickPrompts = false
    @State var highlightMessageID: String?
    @State var showLongContextAlert = false
    @State var showCompressingAlert = false  // v3.0.81：AI 摘要压缩中
    @State var pendingSend: (text: String, imageData: String?)?
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
    @State var autoRetryCount = 0    // v3.4.x：消息失败自动重试计数（网络类错误最多自动重试 2 次，防死循环）
    @State private var lastSentSignature: (sessionId: String, text: String, image: String?, ts: TimeInterval)?  // 同内容 60s 幂等（v3.4.27 fix：签名含图片指纹——纯图 text 恒空，无图指纹会把 60s 内第二张纯图误判重复丢弃）
    @State var fileSendBlocked = false   // v2.0.102：流式中发文件提示
    @State var voiceTooShort = false   // v2.0.102：录音太短提示
    @State var voiceDiag = ""   // v3.0.78 诊断：录音链路诊断信息
    // v2.0.88：AI 回答中发送的消息队列（回答结束后自动逐条发送）
    @State var pendingQueue: [PendingSend] = []
    // v3.0.18：云端工具调用——执行卡片 + 写操作确认弹窗（gate 类持有，超时闭包只捕获它）
    // v3.0.18 fix：toolCards/lastStreamFlush 提取到 CloudStreamUIState（@Observable 引用类型，
    // 闭包捕获引用而非 struct 值拷贝，避免 Task 内 self 旧副本 → 状态更新丢失）
    @State var toolGate = ToolConfirmGate()
    @State var cloudStreamUI = CloudStreamUIState()
    // v3.4.0：底部上拉拉取收件箱状态（@Observable 引用——拖动高频写不重建 ChatView body）
    @State var inboxPull = InboxPullState()
    // v3.4.x 存储自洁：长会话超阈值提示手动归档（消息数超限显示提示条，点击导出）
    @State var showArchiveHint = false
    // v3.0.27：章节列表（纯静态展示，不做滚动导航）
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
    // v3.0.86 fix：是否贴底（onScrollGeometryChange 实时维护）——流式自动滚底仅贴底时生效
    @State private var isScrollPinned = true
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
    func refreshVisibleMessages() {
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
    /// v3.6.5：模型思考档位（header 胶囊，仅本地模式）——随流式请求下发给后端
    @AppStorage(ReasoningLevel.storageKey) private var reasoningLevelRaw = ReasoningLevel.low.rawValue
    @State private var showReasoningPicker = false

    /// v3.5.1：是否有 AI 在处理本会话——本地流 / 云端流 / 服务器兜底探测（三合一）。
    /// 本地流按会话收窄：stream 是全局单例，会话 A 在跑时切到 B 不该显示"AI 正在输入"。
    private var aiBusy: Bool {
        (stream.isStreaming && auth.currentStreamSessionId == chat.sessionId)
            || CloudBackend.shared.isStreaming || remoteBusy
    }
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
    /// v3.4.24：任务中心入口迁入 header（三个点旁）——原 DockTabView 全局 overlay 悬浮片
    /// 改为常驻小图标（不再依赖"有未完成任务"才出现），与三个点同尺寸同色对齐。
    private var reasoningLevel: ReasoningLevel {
        ReasoningLevel(rawValue: reasoningLevelRaw) ?? .low
    }

    /// v3.6.5：仅本地模式包一层（独立属性，避免 headerTrailingItems 表达式过复杂
    /// 触发 Xcode 26「unable to type-check in reasonable time」——v3.3.0 已因此抽离过一次）
    @ViewBuilder
    private var localReasoningPill: some View {
        if !CloudConfig.shared.isCloudMode {
            reasoningPill
        }
    }

    /// v3.6.5：模型思考档位胶囊（放在任务中心左侧）。点击弹出档位选择。
    /// 仅本地模式显示——云端由服务商决定思考策略（且云端侧暂不做改动）。
    private var reasoningPill: some View {
        Button {
            showReasoningPicker = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: reasoningLevel.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(reasoningLevel.title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)          // v3.6.5：触摸区抬到 ~46×24（贴近 HIG 44pt 下限）
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("模型思考档位，当前\(reasoningLevel.title)")
    }

    /// 档位选择内容抽离（避免 Xcode type-check 超时，与 chatActionDialogContent 同理）
    @ViewBuilder
    private var reasoningPickerContent: some View {
        ForEach(ReasoningLevel.allCases) { level in
            // v3.6.5：当前档位加 ✓ 前缀（弹窗里看不出哪个在生效）
            Button("\(level == reasoningLevel ? "✓ " : "")\(level.title) · \(level.detail)") {
                reasoningLevelRaw = level.rawValue
            }
        }
        Button("取消", role: .cancel) {}
    }

    @ViewBuilder
    private var headerTrailingItems: some View {
        HStack(spacing: 12) {
            localReasoningPill
            Button {
                showTaskCenter = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "checklist")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20, height: 20)
                    if taskStore.uncompleted > 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1))
                            .offset(x: 4, y: -3)
                    }
                }
            }
            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
            .accessibilityLabel("任务中心")

            Button {
                showMoreMenu = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
        }
    }

    /// v3.3.0：confirmationDialog 内容抽离（原内联 Menu+8个Button 过长致 Xcode26
    /// type-check 超时——508行报 "unable to type-check in reasonable time"）。
    /// 抽成独立 @ViewBuilder 属性给 type-checker 更小的表达式单元。
    @ViewBuilder
    private var chatActionDialogContent: some View {
        Button("导出会话记录") {
            showExportSheet = true
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
                withAnimation(Motion.snap) { selectMode = true }
            }
        }
        // v2.0.43：上下文信息并入 dialog message（不再是空 action 按钮）
        Button("压缩上下文（保留最近 20 条）") {
            if chat.compressContext() {
                Task { await chat.saveToServer(auth: auth) }
            }
        }
        // v2.0.116：AI 总结会话（走正常流式，AI 回复要点总结）
        Button("AI 总结会话") {
            summarizeSession()
        }
        // v3.0.27：章节列表（纯静态展示，不做滚动导航）
        Button("章节列表") {
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
                     onCamera: {
                        // v3.0.86 fix：模拟器/无摄像头 iPad 先查可用性——sourceType=.camera 在无相机
                        // 设备上 present 即抛 NSInvalidArgumentException；不可用改走相册（PhotosPicker）
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            showCameraPicker = true
                        } else {
                            showPhotoPicker = true
                        }
                    },
                     isRecording: voiceRecorder.isRecording,
                    // v2.0.96：语音转文字（长按发送按钮）
                    voiceMode: voiceMode,
                    onVoiceModeToggle: { toggleVoiceMode(keyboardWasUp: kb.isVisible) },
                    transcribing: transcribing,
                    onCancelTranscribe: { stopTranscribe() },
                    onLongPressInput: { keyboardWasUp in toggleVoiceMode(keyboardWasUp: keyboardWasUp) },
                    // v3.0.4：云端模式无后端 ASR → 关闭全部语音入口
                    voiceEnabled: !CloudConfig.shared.isCloudMode,
                    // v3.4.25：上下文使用率传入——超 80% 发送键变橙轻提醒
                    contextUsage: chat.contextUsage(maxTokens: 4000))
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
                       statusColor: headerColor,
                       busy: aiBusy)
            .confirmationDialog("模型思考档位", isPresented: $showReasoningPicker, titleVisibility: .visible) {
                reasoningPickerContent
            }
            .confirmationDialog("聊天操作", isPresented: $showMoreMenu, titleVisibility: .visible) {
                chatActionDialogContent
            } message: {
                Text("上下文：约 \(chat.contextInfo.tokens) tokens · \(chat.contextInfo.count) 条")
            }
            // v3.4.24：任务中心全屏页（header 三个点旁的常驻入口）
            .fullScreenCover(isPresented: $showTaskCenter) {
                TaskCenterView()
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
            // v3.7.0：剪贴板地图链接提示条（in-flow，不遮挡 header、不拦截消息区滚动）
            if showClipboardBanner {
                mapClipboardBanner()
            }
            // v3.4.26：续聊芯片条——有消息且非流式时显示在消息区上方（话题延续入口）
            continueChipsBar
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
            await resumePersistedStream()
            // v3.5.1：AI 正在输入 探针（仅当有遗留任务标记时才发请求；服务器说没了就清标记收起状态）
            await busyProbeLoop()
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
        // v3.0.27：章节列表（纯静态展示——TOCItem 行号关联具体消息的滚动实现不可靠，不做点击导航）
        .sheet(isPresented: $showTOCSheet) {
            TOCSheet(headers: MarkdownRenderer.extractHeaders(
                chat.messages.filter { $0.role == "assistant" }.map(\.content).joined(separator: "\n")
            ), onNavigate: { item in
                // v3.4.25：章节真导航——复用会话搜索的 highlightTarget 定位机制滚动+高亮
                let msgs = chat.messages
                if item.lineIndex < msgs.count {
                    let target = msgs[item.lineIndex]
                    chat.highlightTarget = (role: target.role, content: target.content)
                    showTOCSheet = false
                }
            })
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
        // v3.4.x 存储自洁：长会话超阈值 → 顶部滑出提示条，点击手动归档导出
        .overlay(alignment: .top) {
            if showArchiveHint {
                archiveBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .onChange(of: chat.messages.count) { _, newCount in
            // 超阈值（300 条）显示归档提示；回到阈值下自动隐藏
            withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                showArchiveHint = newCount >= Self.archiveThreshold && !chat.messages.isEmpty
            }
        }
        // v3.4.14 系统分享收件消费：广播或 onAppear 兜底时，把 ShareRouter 里待处理的内容逐条发送
        .onReceive(NotificationCenter.default.publisher(for: .qingliaoShareIncoming)) { _ in
            drainShareInbox()
        }
        // v3.4.x 任务中心：点击任务「发送到当前会话」→ 把任务文本作为用户消息发送
        .onReceive(NotificationCenter.default.publisher(for: .qingliaoTaskSend)) { note in
            if let text = note.object as? String, !text.isEmpty {
                sendCore(text: text, imageData: nil)
            }
        }
        .onAppear {
            drainShareInbox()
            // v3.4.x 发送可靠性：启动恢复上次未发出的排队消息（杀 App/断网重启不丢）→ 立即补发
            restorePendingQueue()
            if !pendingQueue.isEmpty, !stream.isStreaming {
                let next = pendingQueue.removeFirst()
                persistPendingQueue()
                if let idx = chat.messages.firstIndex(where: { $0.queued && $0.content == next.text }) {
                    let m = chat.messages[idx]
                    startStream(for: m)
                } else {
                    sendQueued(next)
                }
            }
        }
    }

    // MARK: - v3.7.0 剪贴板地图链接（地图分享兜底）
    /// 探测剪贴板是否有 URL → 顶部胶囊提示（detectPatterns 不读内容，无隐私弹窗）
    private func checkMapClipboard() async {
        guard !showClipboardBanner else { return }
        guard UIPasteboard.general.changeCount != clipboardChangeCount else { return }   // 同一份剪贴板内容不重复打扰
        guard await MapClipboardDetector.hasURL() else { return }
        withAnimation(Motion.settle) { showClipboardBanner = true }   // 只提示；真正内容等点按再读
    }

    /// 顶部胶囊：检测到剪贴板里有链接（多为地图分享的「拷贝」）
    @ViewBuilder
    private func mapClipboardBanner() -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("检测到剪贴板里的位置/链接")
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                sendClipboardLink()
            } label: {
                Text("发给 AI")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(Color.accentColor)
            Button {
                withAnimation(Motion.snap) {
                    clipboardChangeCount = UIPasteboard.general.changeCount   // 记住这一版，勿再打扰
                    showClipboardBanner = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("忽略")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 2)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// 真正读取剪贴板（此刻才可能弹系统「允许粘贴」）→ 地图链接拼定位消息，其他链接原样发送
    private func sendClipboardLink() {
        clipboardChangeCount = UIPasteboard.general.changeCount
        withAnimation(Motion.snap) { showClipboardBanner = false }
        guard let raw = MapClipboardDetector.readText() else { return }
        if let url = URL(string: raw), let loc = MapLocationParser.parse(url) {
            let cl = CLLocation(latitude: loc.coord.latitude, longitude: loc.coord.longitude)
            if cl.coordinate.isValid {
                sendCore(text: Self.locationMessage(cl, placeName: loc.place, originLink: raw), imageData: nil)
                return
            }
        }
        sendCore(text: raw, imageData: nil)
    }

    // MARK: - v3.4.14 系统分享收件
    /// 逐条消费 ShareRouter 待处理分享：图片压缩后走 sendCore(imageData:)，文本直接 sendCore(text:)。
    /// v3.4.24 定位分享：地图 App 分享的坐标 → 拼成带"周边推荐"指令的定位消息，AI 直接给周边推荐/资讯。
    private func drainShareInbox() {
        while let p = ShareRouter.shared.dequeue() {
            if let image = p.image, let data = compressImage(image) {
                sendCore(text: p.text ?? "", imageData: data)
            } else if let loc = p.location, loc.coordinate.isValid {
                // v3.4.25：短链无坐标时 isValid=false → 走降级分支，避免"坐标：nan,nan"落消息
                sendCore(text: Self.locationMessage(loc, placeName: p.sourceName, originLink: p.text), imageData: nil)
            } else if p.location != nil {
                // 地图短链未解析出坐标：只发地点名+原链，AI 端自行从链接解析位置
                let link = p.text ?? ""
                let name = p.sourceName ?? ""
                let fallback = name.isEmpty ? "📍 我分享了一个位置链接：\(link)" : "📍 我分享了一个位置：\(name)\n分享链接：\(link)"
                sendCore(text: fallback, imageData: nil)
            } else {
                sendCore(text: p.text ?? "", imageData: nil)
            }
        }
    }

    /// v3.4.24：定位消息组装（地点名 + 经纬度 + 分享原链 + 周边推荐指令）
    static func locationMessage(_ loc: CLLocation, placeName: String?, originLink: String?) -> String {
        let coordTxt = String(format: "%.6f,%.6f", loc.coordinate.latitude, loc.coordinate.longitude)
        var lines: [String] = []
        if let p = placeName, !p.isEmpty {
            lines.append("📍 我分享了一个位置：\(p)")
        } else {
            lines.append("📍 我分享了一个位置")
        }
        lines.append("坐标：\(coordTxt)（纬度,经度）")
        if let link = originLink, !link.isEmpty {
            lines.append("分享链接：\(link)")
        }
        lines.append("")
        lines.append("请根据这个定位推荐周边业态（美食/咖啡/超市/加油站等实用的去处），并介绍周边相关资讯。若链接里没有具体坐标，请先尝试从链接本身解析位置信息。")
        return lines.joined(separator: "\n")
    }

    // MARK: - 消息列表

    // v2.0.111：欢迎页独立于 ScrollView——不再受滚动容器背景/裁剪影响，logo 永远完整显示
    private var welcomeView: some View {
        VStack(spacing: 0) {
            // v3.4.29：顶部弹性留白（原写死在容器上的 padding(.top,120)）——小屏不再被挤压，大屏自然下移，最多 120pt
            Spacer(minLength: 56).frame(maxHeight: 120)

            ZStack {
                // v3.4.25：粒子球版 logo（复用 OrbEngine，与流式头像同语言）替代静态渐变圆
                Circle()
                    .fill(LinearGradient(colors: [.blue.opacity(0.10), .indigo.opacity(0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 96, height: 96)
                OrbCanvasView(mode: .orbits, size: 96)
                    .allowsHitTesting(false)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .shadow(color: .indigo.opacity(0.35), radius: 6, y: 2)
            }

            // v3.4.29：文案组与 logo 拉开距离（原整体 spacing 12 → 96pt 的球和文字贴在一起，头重脚轻）
            // 现改为分组：logo↔文案 18pt，问候↔副标题 6pt（同组紧、跨组松）
            VStack(spacing: 6) {
                // v3.4.25：问候语随时段变化
                Text(welcomeGreeting)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .purple],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text(welcomeSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 18)

            // v3.4.25：上下文感知建议芯片——新会话给开场模板，续聊会话给话题延续入口
            // v3.4.29：统一为全站玻璃淡雅风（原 accentColor 实色底+同色文字，与顶部续聊芯片条是两套观感；
            // 且高饱和蓝抢了问候语的视觉主角位）；水平内边距 24 → 16 与消息区/续聊条对齐
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(welcomeSuggestions) { s in
                        Button {
                            Haptics.tap()
                            if chat.messages.isEmpty {
                                inputText = s.prompt
                                inputFocus = true
                            } else {
                                // 续聊场景直接发送延续指令
                                sendCore(text: s.prompt, imageData: nil)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: s.icon)
                                    .font(.system(size: 11, weight: .medium))
                                Text(s.title)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
                        }
                        .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 18)

            // v3.4.29：继续上次会话——用户手动新建/清空会话后一键回到上一个会话，免切「会话」tab 再找
            // （启动自动 loadLastSession 只覆盖 App 重启场景，新建会话后原先没有任何回归路径）
            if let last = chat.lastLoadedSession, last.id != chat.sessionId, !clearing {
                Button {
                    Haptics.tap()
                    chat.load(last)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("继续上次")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(last.title.isEmpty ? "未命名会话" : last.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
                }
                .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
    }

    /// v3.4.25：时段问候语
    private var welcomeGreeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<11: return "早上好 ☀️"
        case 11..<13: return "中午好 🌤"
        case 13..<18: return "下午好 🌤"
        case 18..<23: return "晚上好 🌙"
        default: return "夜深了 🌌"
        }
    }

    private var welcomeSubtitle: String {
        chat.messages.isEmpty ? "我能帮你查资料、写代码、执行自动化任务" : "随时继续刚才的话题"
    }

    // v3.4.25：上下文感知建议芯片（icon/title/prompt 三元组，Identifiable 结构供 ForEach）
    // v3.4.26 修复：原「继续话题/总结对话」组写在非空分支，但欢迎页只在空会话渲染 → 永远不显示。
    // 现统一由 showContinueChips 控制：非空会话在 header 下方悬浮显示该组芯片（新会话仍走欢迎页）。
    private var welcomeSuggestions: [WelcomeSuggestion] {
        if chat.messages.isEmpty {
            return [
                WelcomeSuggestion(icon: "sparkles", title: "帮我写", prompt: "帮我写一份"),
                WelcomeSuggestion(icon: "character.bubble", title: "翻译", prompt: "请将以下内容翻译成英文：\n"),
                WelcomeSuggestion(icon: "brain", title: "头脑风暴", prompt: "请围绕以下主题给出 5 个有创意的点子：\n"),
                WelcomeSuggestion(icon: "list.bullet.rectangle", title: "待办整理", prompt: "请把以下内容整理成清晰的待办清单：\n")
            ]
        }
        // 续聊会话：话题延续 + 通用工具
        return [
            WelcomeSuggestion(icon: "arrow.uturn.forward", title: "继续话题", prompt: "我们刚才聊到哪里了？请简要回顾并继续。"),
            WelcomeSuggestion(icon: "summarize", title: "总结对话", prompt: "请用 3-5 条要点总结我们这段对话的关键内容。"),
            WelcomeSuggestion(icon: "questionmark.bubble", title: "有疑问", prompt: "关于刚才的内容，我还有几个问题想深入。")
        ]
    }

    /// v3.4.26：续聊芯片条（非空会话且非流式时显示在消息区顶部；点按直接发送延续指令）
    /// v3.4.x 美化：去高饱和纯蓝（用户反馈突兀）——改 Siri 淡雅低饱和风：
    /// 图标走柔和渐变（每芯片独立色系）、文字 secondary 中性、底 ultraThinMaterial 玻璃、0.8pt 淡描边，
    /// 与全站胶囊/玻璃卡片观感统一。
    @ViewBuilder
    private var continueChipsBar: some View {
        if !chat.messages.isEmpty && !stream.isStreaming {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(welcomeSuggestions) { s in
                        Button {
                            Haptics.tap()
                            sendCore(text: s.prompt, imageData: nil)
                        } label: {
                            Text(s.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
                        }
                        .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.vertical, 6)
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
            // 气泡出现动效（v3.4.20 分级）：用户消息从底部轻滑入（微信式方向感），
            // AI 消息淡入+微缩放；移除仍为纯淡入淡出。
            // v2.0.38：去掉 .animation(value: messages.count)——
            // 批量清空（清空会话/新建会话）时全 cell 同时移除的 spring 动画曾导致闪退
            .transition(.asymmetric(
                insertion: msg.role == "user"
                    ? .opacity.combined(with: .offset(y: 14))
                    : .opacity.combined(with: .scale(scale: 0.96)),
                removal: .opacity))
    }

    /// v3.0.51：单条消息气泡构造——拆独立方法（防消息列表 ForEach 内 type-check 超时）
    @ViewBuilder
    private func chatMessageBubble(_ msg: ChatMessage) -> some View {
        MessageBubble(message: msg,
                      isHighlighted: msg.id == highlightMessageID,
                      zoomNS: zoomNS) {   // v3.4.29：zoom 转场（非闭包实参须在 trailing closure 之前）
            regenerate(at: msg.id)
        } onBigBang: { text in
            bigBangPayload = BigBangPayload(text: text)
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
        } onMemo: { text in
            // v3.7.0：加入备忘录（整条气泡 / 选中片段）→ 生活页「备忘录」栏目
            if MemoStore.shared.add(content: text, source: "chat") {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } onAIImageTap: { url in
            openAIImage(url, sourceID: msg.id)   // v3.4.29：带转场源
        } onMultiSelect: {
            // v3.3.0：长按菜单「多选」——进入多选模式并预选本条
            if stream.isStreaming {
                selectBlocked = true
            } else {
                inputFocus = false
                selectedMsgIDs.removeAll()
                selectedMsgIDs.insert(msg.id)
                withAnimation(Motion.snap) { selectMode = true }
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
        withAnimation(Motion.snap) {
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
            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
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
            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
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
            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
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
            // v3.4.20：读 displayContent（打字机平滑层）——本地/云端流式观感从"整段跳变"变"逐字流"
            message: ChatMessage(role: "assistant", content: stream.displayContent, timestamp: nil, agent: stream.isAgent),
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
                    .id("welcome")   // v3.4.29：原 padding(.top,120) 已移入 welcomeView 顶部弹性留白（小屏不再挤）
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
                                                withAnimation(Motion.snap) {
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
                                            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
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
            // v2.0.111：消息区背景透明（ScrollView 默认白底遮住上方 logo/内容）
            .scrollContentBackground(.hidden)
            // v2.0.86h：Dock 滑动隐藏已删除（从未生效，手动开关替代）
            // v2.0.43：搜索定位——滚动到命中消息并高亮 2 秒
            .onChange(of: chat.highlightTarget?.content) { _, _ in
                guard let t = chat.highlightTarget,
                      let idx = chat.indexOfMessage(role: t.role, contentPrefix: t.content) else { return }
                let mid = chat.messages[idx].id
                highlightMessageID = mid
                withAnimation(Motion.settle) {
                    proxy.scrollTo(mid, anchor: .center)
                }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(Motion.settle) { highlightMessageID = nil }
                }
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
            // v3.0.86 fix：贴底检测（pinned）——内容不满屏或已滚到底（容差 8pt）视为贴底。
            // 流式自动滚底仅贴底时生效：用户上翻阅读历史时 pinned=false，不被 delta 拽回底部
            .onScrollGeometryChange(for: Bool.self) { geo in
                let maxY = geo.contentSize.height - geo.containerSize.height
                let bottomMax = max(0, maxY)
                return geo.contentSize.height <= geo.containerSize.height
                    || geo.contentOffset.y >= bottomMax - 8
            } action: { _, pinned in
                isScrollPinned = pinned
            }
            // v2.0.135：ScrollView 是 UIKit 桥接视图，其区域点击不冒泡到 ZStack 根手势
            // （v2.0.112b 把 onTapGesture 移到 ZStack 后，有消息时点空白收键盘失效，用户复报）
            // → ScrollView 自身也挂一个：点消息区空白收键盘（点气泡由 MessageBubble 手势优先消费，不受影响）
            .onTapGesture {
                inputFocus = false
            }
            // v3.0.86 fix：缓存刷新已上提 ZStack 层 onChange（ScrollView 卸载/欢迎态也生效），
            // 此处的 count 变化只负责贴底滚动（消息 append 场景）
            .onChange(of: chat.messages.count) {
                scrollBottom(proxy)
            }
            .onChange(of: displayLimit) { _, _ in
                refreshVisibleMessages()
            }
            // v3.0.86 fix：流式内容变化仅在用户贴底时自动滚底（isScrollPinned 由下方
            // onScrollGeometryChange 实时维护）——上翻阅读历史不再被 delta 拽回；无动画防高频打断
            .onChange(of: stream.content) { _, _ in
                guard isScrollPinned else { return }
                scrollBottom(proxy, animated: false)
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
        // v3.0.86 fix：以下 onChange 挂在 messageList 的 ZStack 层（不随欢迎页/清空态卸载的
        // ScrollView 走）——两步走清空/新建会话/整组替换消息（ChatStore.load 新旧条数相同）
        // 时可见缓存仍能重建，根治「空态后首条消息错显上一会话缓存行」
        .onChange(of: chat.sessionId) {
            clearPendingQueue()
            refreshVisibleMessages()
            cloudStreamUI.toolCards = []   // v3.0.18 fix：工具卡片跨会话残留清理（通过 @Observable 引用类型）
            // v3.0.51 A1：会话加载后重传残留 base64 图片（重启续传/失败重传）
            Task { await chat.retryPendingImageUploads(auth: auth) }
        }
        // v3.4.25：改双重触发——count（增删）+ lastID（整组替换/清空重建时 count 不变，仅靠
        // sessionId 兜底会漏渲染；lastID 变化补上「同条数内容替换」场景，且流式 tick 不改 lastID，
        // 不引入额外高频重建）
        .onChange(of: chat.messages.count) {
            refreshVisibleMessages()
        }
        .onChange(of: chat.messages.last?.id ?? "") { _, _ in
            refreshVisibleMessages()
        }
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
                // v3.4.29：加号 = 等同 /new——本地新建完成后补发 /new，触发 gateway 侧上下文重置。
                // sessionId 已换成新值，与 sendCore 的 60s 幂等签名（含 sessionId）不冲突
                if chat.pendingNewSessionReset {
                    chat.pendingNewSessionReset = false
                    silentGatewayReset()
                }
            }
        }
        .task {
            // v3.0.51 A2 fix：初始化可见消息缓存（首次渲染不为空）
            refreshVisibleMessages()
            // v3.4.29：先用上次结果填充状态点——首屏不再闪"检测中"灰点（后台校验回来再纠正）
            if let cached = UserDefaults.standard.object(forKey: "qingliao_server_online_cache") as? Bool {
                serverOnline = cached
            }
            // v3.7.0：进聊天页探一次剪贴板（地图分享「拷贝」后切回来即可见胶囊）
            await checkMapClipboard()
            // 服务器连接状态检测（真实绿点）
            let r = await auth.testConnection(server: auth.serverURL)
            let ok = r.hasPrefix("✅")
            serverOnline = ok
            UserDefaults.standard.set(ok, forKey: "qingliao_server_online_cache")   // v3.4.29：写缓存供下次首屏
        }
        .fullScreenCover(item: $bigBangPayload) { payload in
            BigBangView(text: payload.text)
        }
        // v3.7.0：回前台时重探一次（用户刚在地图里「拷贝」→ 切回轻聊即出现胶囊）
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await checkMapClipboard() } }
        }
        // v2.0.59：上下文过长提示（60+ 条建议压缩）
        .alert("上下文较长", isPresented: $showLongContextAlert) {
            Button("压缩后发送") {
                if let p = pendingSend {
                    chat.compressContext()
                    sendPendingNow(p)
                }
            }
            Button("直接发送") {
                if let p = pendingSend {
                    sendPendingNow(p)
                }
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
            // v3.4.29：zoom 转场——全屏大图从被点的小图"生长"出来（iOS 18+ 原生，支持 fullScreenCover）
            if p.sourceID.isEmpty {
                ImageViewer(images: p.images, index: p.index)
            } else {
                ImageViewer(images: p.images, index: p.index)
                    .navigationTransition(.zoom(sourceID: p.sourceID, in: zoomNS))
            }
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
        // v3.4.28：导出格式选择面板 + HTML 导出
        .sheet(isPresented: $showExportSheet) {
            ChatExportSheet(title: chat.title, messages: chat.messages) { format in
                handleExport(format)
            }
        }
        .fileExporter(isPresented: $showHTMLExporter,
                      document: ChatHTMLDocument(html: exportHTML),
                      contentType: .html,
                      defaultFilename: "轻聊会话") { _ in }
        // v2.0.36：录音权限被拒提示
    }

    /// 思考中动画（三点跳动）
    struct TypingIndicator: View {
        @State var animating = false
        var body: some View {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    // v3.4.20：三点跳动 → 蓝紫渐变脉冲圆（与发送按钮/Siri 流光同语言，"AI 活着"统一视觉）
                    Circle()
                        .fill(LinearGradient(colors: [.blue, .indigo, .pink],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 8, height: 8)
                        .scaleEffect(animating ? 1.0 : 0.55)
                        .opacity(animating ? 1.0 : 0.45)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(i) * 0.18), value: animating)
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

    /// v3.0.86 fix：滚底可关内层动画——流式高频 delta 下 withAnimation 每帧重启互相打断，
    /// 流式路径用 animated: false（贴底滚动瞬时完成）；消息 append（用户发送）保留轻动画
    private func scrollBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            if stream.isStreaming {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let last = chat.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
        if animated {
            withAnimation(Motion.tap) { action() }
        } else {
            action()
        }
    }

    // MARK: - 发送

    /// v2.0.116：AI 总结会话（菜单按钮 → 自动发总结请求走正常流式）
    func summarizeSession() {
        guard !chat.messages.isEmpty else { return }
        guard !stream.isStreaming else { return }
        sendCore(text: "请用简洁的要点总结我们这次对话（分点列出，突出结论和待办）", imageData: nil)
    }

    /// v3.0.86 fix：统一「确认发送」路径——pendingSend 解包 → 清输入框/图片 → 图片持久化 → sendCore。
    /// 原长上下文弹窗「压缩后发送/直接发送」与自动压缩完成后三份重复拷贝，抽此统一（后续改一处即可）
    private func sendPendingNow(_ p: (text: String, imageData: String?)) {
        pendingSend = nil
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
        // v3.4.x：quotedText 存原始引用文本，供气泡内可视化引用块渲染（与上方 markdown 注入并存）
        // v3.4.25：引用指令显式化——注入带定位提示的引用前缀，让模型明确「回答的是针对这条旧消息的新问题」，
        //          而非把引用原文又复述一遍（长会话里引用一条很久之前的消息时尤其重要）
        let quotedText = quotedMessage?.content
        if let q = quotedMessage, !text.isEmpty {
            let quoted = q.content.replacingOccurrences(of: "\n", with: "\n> ")
            let quoteHint = q.isUser
                ? "\n\n（我在引用我之前发的一条消息并向你提问，请针对这条消息的内容回答下方新问题，不要复述原文）"
                : "\n\n（我在引用你之前的一条回复并向你提问，请针对该回复的内容回答下方新问题，不要重复输出该回复）"
            text = "> " + quoted + quoteHint + "\n\n" + text
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
                    sendPendingNow(p)
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
                sendCore(text: text, imageData: persisted, quotedText: quotedText)
            }
        } else {
            sendCore(text: text, imageData: nil, quotedText: quotedText)
        }
    }

    /// v2.0.59：发送核心（send / 失败重试共用）
    /// v2.0.88：AI 回答中发送不再被拦截——消息上屏 + 入队，当前回答结束后自动逐条发送
    /// v3.4.x 存储自洁：长会话归档提示。
    /// 超阈值（300 条）时顶部显示提示条，点击后导出当前会话为文本（复用 chat.exportText）。
    static let archiveThreshold = 300

    @ViewBuilder
    private var archiveBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("会话内容较多")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(chat.messages.count) 条消息 · 建议归档导出以省存储")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("归档") { showExportSheet = true }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange)
                .clipShape(Capsule())
            Button {
                withAnimation { showArchiveHint = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(RoundedRectangle(cornerRadius: 0).stroke(Color.orange.opacity(0.3), lineWidth: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// v3.4.28：导出格式分发（导出面板/归档条共用）——按所选格式准备内容并弹对应 fileExporter
    @MainActor
    func handleExport(_ format: ChatExportFormat) {
        switch format {
        case .pdf:
            exportPDFData = ChatPDFDocument.generate(
                title: chat.title, messages: chat.messages)
            showPDFExporter = true
        case .html:
            exportHTML = ChatHTMLDocument.generate(
                title: chat.title, messages: chat.messages)
            showHTMLExporter = true
        case .markdown:
            exportMarkdown = chat.exportMarkdown()
            showMarkdownExporter = true
        case .plainText:
            exportText = chat.exportText()
            showExporter = true
        }
    }

    /// v2.0.102：sendingLock 同步置位——防极快双击时 isStreaming 尚未置位导致双流竞态
    /// v3.4.x：quotedText 参数——长按「引用」后把被引用的原文挂到消息上（气泡内可视化引用块）
    /// v3.4.29：静默重置 gateway 上下文（新建会话「加号」入口）
    /// 只向后端投一条 /new 触发 gateway 侧会话重置——不落本地消息、不接流式、不显示气泡，
    /// 用户看到的仍是干净的新会话 + 欢迎页（区别于手动发 /new：那条走 sendCore 是可见的普通消息）
    private func silentGatewayReset() {
        // 云端模式直连大模型 API，没有 gateway 会话上下文概念 → 无需重置
        guard !CloudConfig.shared.isCloudMode else { return }
        let (useModel, useProvider) = resolveModel(hasImage: false)
        let sid = chat.sessionId   // 已是新建后的新 sessionId
        // 只投单条 /new（不带历史）：gateway 收到命令即重置，带历史只是白传一遍上下文
        let payload: [[String: Any]] = [["role": "user", "content": "/new"]]
        Task { @MainActor in
            // fire-and-forget：结果不影响 UI；失败静默（下次点加号会再投一次）
            _ = try? await auth.streamStart(sessionId: sid, model: useModel,
                                            provider: useProvider, messages: payload)
        }
    }

    func sendCore(text: String, imageData: String?, quotedText: String? = nil) {
        // v3.4.x：同内容短时间幂等（60s 内相同文本+同会话只发一次，防抖动/重试/恢复重复投递）
        // v3.4.27 fix：比较须含 image 指纹——纯图 text 恒空，只比 text 会把 60s 内第二张纯图误判重复丢弃（拍照/相册连发纯图被吞）
        let now = Date().timeIntervalSince1970
        if let last = lastSentSignature, last.sessionId == chat.sessionId, last.text == text,
           last.image == imageData, now - last.ts < 60 {
            return
        }
        lastSentSignature = (chat.sessionId, text, imageData, now)
        // v3.0.52：蜂窝下 base64 图 body 过大 → 先超强压缩（uploadImage 蜂窝大概率失败退回 base64 大 body，
        // 导致 CFStream/relay 载不动 → 后端 bad json 400；压小后直连可过）
        let imageData = compressForCellular(imageData)
        guard !text.isEmpty || imageData != nil else { return }
        // v3.0.19 review fix #1：语音指令标志在此一次性消费——标记本消息 + 转播报意图 + 清空 sid

        // v2.0.126：蜂窝 relay 3.5KB 限制自动分段（粘贴长文本不丢内容）
        // relay payload = base64url(JSON{m,p,h,b}) 进 URL；限制 ~3.5KB；WiFi 直连无限制不走此分支
        if imageData == nil, NetworkMonitor.shared.isCellular, text.count > 200 {
            // v3.4.9 方案C：只传当前消息，relay 大小按单条消息估算（不再叠加全量历史）
            if relayPayloadLength(messages: [["role": "user", "content": text]]) > 3400 {
                let chunks = splitLongText(text)
                if chunks.count > 1 {
                    // 顺序：第一段先发（流式中走排队路径排最前），后续段再入队
                    sendCore(text: chunks[0], imageData: nil)
                    for c in chunks.dropFirst() {
                        var m = ChatMessage.local(role: "user", content: c, imageDataURL: nil)
                        m.quotedText = quotedText
                        m.queued = true
                        withAnimation(.spring(duration: 0.25, bounce: 0.15)) {
                            chat.append(m)
                        }
                        pendingQueue.append(PendingSend(text: c, imageData: nil))
                        persistPendingQueue()
                    }
                    Task { await chat.saveToServer(auth: auth) }
                    return
                }
            }
        }
        if stream.isStreaming {
            // 排队路径：消息立即显示（标记排队中），回答结束后自动发送
            var msg = ChatMessage.local(role: "user", content: text, imageDataURL: imageData)
            msg.quotedText = quotedText
            msg.queued = true
            withAnimation(.spring(duration: 0.25, bounce: 0.15)) {
                chat.append(msg)
            }
            pendingQueue.append(PendingSend(text: text, imageData: imageData))
            persistPendingQueue()
            Task { await chat.saveToServer(auth: auth) }
            return
        }
        guard !sendingLock else { return }   // 双击保护：第一次发送的流尚未置位时，第二次直接忽略
        sendingLock = true
        Haptics.tap()   // v3.4.25：统一触感
        // v2.0.65：发送通知 → Dock 聊天图标轻跳
        NotificationCenter.default.post(name: .qingliaoSent, object: nil)
        var msg = ChatMessage.local(role: "user", content: text, imageDataURL: imageData)
        msg.quotedText = quotedText
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
        // v3.4.10 X方案：发「断种子净化完整历史」给后端（不再只传当前消息）。
        // 后端 _build_hermes_messages 对完整历史再做 _sanitize_history/_compress_long_assistants/
        // _break_repeat_seed，并去掉 X-Hermes-Session-Id（不再让 Hermes 用 state.db 重建未净化会话）。
        // 上下文=净化历史 → 不复读；且保留 app 按会话选模型 + 图片 + 流式。
        let history: [[String: Any]] = chat.historyPayload()
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
                    // v3.4.x：网络类错误自动重试（连接中断/超时/无法连接），限流/用户停止/业务失败不重试
                    if self.isRetryableStreamError(error) {
                        chat.markFailed(id: msg.id)   // 先标记（失败态显示），重试成功会覆盖
                        self.autoRetryStream(for: msg)
                    } else {
                        chat.markFailed(id: msg.id)   // v2.0.59 失败标记 → 重试按钮
                        // v3.0.19：限流错误友好提示（sensenova 等免费额度 tpm 爆了 → 提示换路由）
                        let friendly = Self.friendlyStreamError(error)
                        chat.upsertAssistant(stream.content.isEmpty ? "⚠️ \(friendly)" : stream.content + "\n\n⚠️ \(friendly)", agent: stream.isAgent, afterUserID: msg.id)
                    }
                } else if stream.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // v3.5.1：空回复 → 重试一次 / 明确提示（原来静默"已送达"，用户以为没发出去）
                    self.handleEmptyReply(for: msg)
                } else {
                    chat.upsertAssistant(stream.content, agent: stream.isAgent, afterUserID: msg.id)
                    showSentOK()
                    // v3.1.9 fix：流式完成 → 快拉收件箱（后端 _maybe_push_app 已入队本次回复，
                    // 此刻 isStreaming=false 且回复已落库 → 去重命中、不重复注入）
                    InboxStore.shared.triggerFastPoll()
                    // v3.0.19：语音指令回复完成 → TTS 播报摘要

                    // v2.0.36：App 退后台时 AI 回复完成发本地通知（v2.0.60 携带会话 id）
                    // v3.4.26：正文取回复首句（notifyReply），不点亮屏幕可见答了什么
                    if UIApplication.shared.applicationState != .active {
                        NotificationHelper.notifyReply(stream.content, sessionId: chat.sessionId)
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
                    persistPendingQueue()
                    sendQueued(next)
                }
            }
        }
    }

    // MARK: - v3.5.1 AI 正在输入 状态（header 小字）

    /// 空回复提示文案：本地流正常结束但内容为空（典型=长任务跑满步数上限 / 上游未回吐最终文本）。
    /// ⚠️ 必须 ≤30 字：ChatStore.upsertAssistant 对 >30 字文本做全历史精确查重，超长文案在
    /// 同一会话第二次空回复时会被静默吞掉（又变成"没反应"）。
    static let emptyReplyNote = "⚠️ 本轮空回复：点上方「重新生成」（长任务易被截断）"

    /// v3.5.1：接回在途任务（杀后台/重启前的流）——抽成方法供 .task 与「AI 正在输入」探针共用，
    /// 保证两条路径落库回调一致（否则探针接回的回复没有 onFinished 收尾，答案会丢）。
    private func resumePersistedStream() async {
        await stream.restoreIfNeeded(auth: auth, sessionId: chat.sessionId) { success, err in
            // v3.3.3：恢复的旧回答锚定回发起 user 消息，不 append 到用户新消息后
            let anchor = stream.pendingUserMsgId
            if success {
                // v3.5.1：恢复回来的任务内容为空 → 明确提示（原来静默落一条空消息）
                if stream.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chat.upsertAssistant(Self.emptyReplyNote, agent: true, afterUserID: anchor)
                } else {
                    chat.upsertAssistant(stream.content, agent: stream.isAgent, afterUserID: anchor)
                }
            } else {
                chat.upsertAssistant(stream.content.isEmpty ? "⚠️ \(err)" : stream.content + "\n\n⚠️ \(err)", agent: stream.isAgent, afterUserID: anchor)
            }
            Task { await chat.saveToServer(auth: auth) }
        }
    }

    /// 空回复处理：只落提示气泡（文案含 ⚠️ → 气泡自带「重新生成」快捷入口，一键重试）。
    /// 不做两件曾考虑过的事：
    ///  ① 不 markFailed——那是"消息未发出"语义，且 failed 全仓库无复位点 → 用户消息会永久挂
    ///     红叹号，点击还会删掉该消息重发（实际已送达服务器）；
    ///  ② 不自动重试——autoRetryStream 延迟 1s 且入口 guard !isStreaming，紧随其后的队列发送
    ///     会抢跑把它静默丢弃（正好又是"没反应"），重试成功也可能与提示气泡并存造成双气泡。
    private func handleEmptyReply(for msg: ChatMessage) {
        autoRetryCount = 0
        chat.upsertAssistant(Self.emptyReplyNote, agent: true, afterUserID: msg.id)
    }

    /// 探针循环：每 6s 跑一次（v3.5.2：无本机标记时 probeRemoteBusy 内部自行降频到 12s）。
    /// `probing` 守卫防视图重复创建出两个并发循环。
    private func busyProbeLoop() async {
        guard !probing else { return }
        probing = true
        defer { probing = false }
        while !Task.isCancelled {
            await probeRemoteBusy()
            try? await Task.sleep(for: .seconds(6))
        }
    }

    /// 服务器侧真相（v3.5.2 重写）：**服务器才是唯一真相来源**，本机标记只用于"抢先显示"。
    ///
    /// 旧逻辑以「本机还有持久化标记」为前提：没有标记就直接收起状态，连服务器都不问。
    /// 但 finish()（弱网连败 / 收尾）会清掉标记，而服务器侧任务仍在跑 → 前台一点提示都没有，
    /// 用户以为 AI 停了、答案也回不来（2026-09-11 实报）。现在无条件问服务器，再按结论决定接回。
    private func probeRemoteBusy() async {
        if stream.isStreaming { remoteBusy = false; return }
        if CloudConfig.shared.isCloudMode { remoteBusy = CloudBackend.shared.isStreaming; return }
        let sid = chat.sessionId
        guard !sid.isEmpty, auth.isLoggedIn else { remoteBusy = false; return }
        let pending = UserDefaults.standard.dictionary(forKey: "qingliao_stream_pending")
        let pendingSame = (pending?["sessionId"] as? String) == sid
        let pendingFresh: Bool = {
            guard pendingSame, let ts = pending?["ts"] as? TimeInterval else { return false }
            return Date().timeIntervalSince1970 - ts <= 1800
        }()
        if pendingFresh { remoteBusy = true }   // 有新鲜标记 → 先显示，服务器结论回来再纠正
        // 无本机标记（纯服务器探测）时降频到 12s（省电/省流量）；有标记保持 6s 快速纠正
        if pendingFresh {
            probeTick = 0
        } else {
            probeTick += 1
            if probeTick % 2 != 0 { return }
        }
        do {
            let (tid, rContent, done, status, _) = try await auth.streamRecover(sessionId: sid)
            let alive = (tid?.isEmpty == false) && !done && status == "streaming"
            remoteBusy = alive
            remoteBusyFails = 0
            guard alive, !stream.isStreaming, let tid, !tid.isEmpty else { return }
            // 服务器侧确有在途任务而本机没在收 → 接回
            if pendingFresh, ((pending?["taskId"] as? String) ?? "") == tid {
                await resumePersistedStream()          // 标记就是这条 → 走原路（锚点能对回原 user 消息）
            } else {
                await adoptRemoteStream(taskId: tid, content: rContent)
            }
            // 注：!alive 不清理持久化标记——服务端历史任务可能是 done，误清会把仍在途的答案永久丢弃；
            // 标记由 finish()/30 分钟规则回收。
        } catch {
            // 网络失败：连续 5 次（≈30s）拿不到服务器结论才收起（弱网抖动不再瞬间熄灭提示）
            remoteBusyFails += 1
            if remoteBusyFails >= 5 { remoteBusy = false }
        }
    }

    /// v3.5.2：接回服务器侧在途任务（本机无标记 / 标记与服务器不一致时用）。
    /// 只会在 recover 回「未完成（status=streaming）」时被调用 → 内容必然是本轮生成的，
    /// 不会复活旧答案（复读事故护栏）。落库回调与 resumePersistedStream 对齐（答案不丢）。
    private func adoptRemoteStream(taskId tid: String, content: String) async {
        guard !stream.isStreaming else { return }
        let anchor = chat.messages.last(where: { $0.role == "user" })?.id
        stream.adoptRemote(taskId: tid, content: content, sessionId: chat.sessionId, auth: auth) { success, err in
            if success {
                if stream.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chat.upsertAssistant(Self.emptyReplyNote, agent: true, afterUserID: anchor)
                } else {
                    chat.upsertAssistant(stream.content, agent: stream.isAgent, afterUserID: anchor)
                }
            } else {
                chat.upsertAssistant(stream.content.isEmpty ? "⚠️ " + err : stream.content + "\n\n⚠️ " + err,
                                     agent: stream.isAgent, afterUserID: anchor)
            }
            Task { await chat.saveToServer(auth: auth) }
        }
    }

    // MARK: - v3.4.x 消息失败自动重试（网络类错误自动重试 2 次指数退避）

    /// 判断流式错误是否"值得自动重试"——网络瞬时故障/超时类可重试；
    /// 用户主动停止/取消/限流(429)/业务失败(401/400)不重试（重试也无效或违背用户意图）。
    private func isRetryableStreamError(_ error: String) -> Bool {
        let low = error.lowercased()
        // 用户主动动作：停止/取消 → 不重试
        if low.contains("已停止") || low.contains("已取消") { return false }
        // 业务失败：权限/4xx/5xx 服务端明确拒绝 → 不重试
        if low.contains("401") || low.contains("400") || low.contains("403")
            || low.contains("404") || low.contains("429") || low.contains("500")
            || low.contains("rate limit") || low.contains("tpm") || low.contains("exhausted") { return false }
        // 其余（连接中断/超时/无法连接/网络/未返回内容 等）视为可重试
        return true
    }

    /// v3.4.x 自动重试：沿用原消息（用户消息已在 messages，只重发 assistant 请求），
    /// 不新增 user 消息、不触发 lastSentSignature 幂等（那是 sendCore 的护栏，重发需绕过）。
    /// 指数退避：1s → 2s；弱网断网时先等网络恢复再重试（v3.4.x 弱网重连 ④）。
    private func autoRetryStream(for msg: ChatMessage) {
        guard autoRetryCount < 2 else {
            autoRetryCount = 0   // 重试耗尽 → 复位，等手动按钮
            return
        }
        autoRetryCount += 1
        let history = chat.historyPayload()
        let startSid = chat.sessionId
        let (useModel, useProvider) = resolveModel(hasImage: msg.imageDataURL != nil)
        let delay = autoRetryCount == 1 ? 1.0 : 2.0
        Task {
            try? await Task.sleep(for: .seconds(delay))
            // 断网状态（电梯/地库/切网）：不出无效请求，等网络恢复（最多 60s）再重试
            var waited = 0
            while waited < 60, !NetworkMonitor.shared.isSatisfied {
                try? await Task.sleep(for: .seconds(2))
                waited += 2
            }
            guard chat.sessionId == startSid, !stream.isStreaming else { return }
            stream.pendingUserMsgId = msg.id
            await stream.start(auth: auth, sessionId: chat.sessionId, model: useModel,
                               provider: useProvider, messages: history) { success, error in
                sendingLock = false
                guard chat.sessionId == startSid else { return }
                if !success {
                    // 仍失败：继续重试或最终标记失败（不吞用户消息）
                    if self.isRetryableStreamError(error), self.autoRetryCount < 2 {
                        self.autoRetryStream(for: msg)
                    } else {
                        chat.markFailed(id: msg.id)
                        let friendly = Self.friendlyStreamError(error)
                        chat.upsertAssistant(stream.content.isEmpty ? "⚠️ \(friendly)" : stream.content + "\n\n⚠️ \(friendly)", agent: stream.isAgent, afterUserID: msg.id)
                    }
                } else if stream.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // v3.5.1：重试仍是空回复 → 明确提示
                    self.handleEmptyReply(for: msg)
                } else {
                    chat.upsertAssistant(stream.content, agent: stream.isAgent, afterUserID: msg.id)
                    showSentOK()
                    InboxStore.shared.triggerFastPoll()
                }
                Task { await chat.saveToServer(auth: auth) }
            }
        }
    }

    /// v3.0 云端流式直连（SSE 增量拼接，UI 与本地模式一致）

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
        stream.startSmoothPublic()   // v3.4.20：云端流式同样启用打字机平滑释放
        CloudBackend.shared.isStreaming = true   // v3.0.2：标记云端流式进行中（驱动 Siri 发光）
        // v3.0.18 fix：Task 显式捕获引用对象（chat/stream @Environment 类引用），
        // 避免隐式捕获 struct 值副本导致 Task 内 self 旧副本 → 后续更新丢失
        Task { [chat = self.chat, stream = self.stream] in
            defer {
                sendingLock = false
                stream.isStreaming = false
                stream.isDone = true
                stream.stopSmoothPublic()   // v3.4.20：云端路径平滑层收尾
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
                        NotificationHelper.notifyReply(finalText, sessionId: chat.sessionId)
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

    /// 云端模式回答完成 → 自动发送队列下一条
    private func finishCloudQueue() {
        if !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            persistPendingQueue()
            sendQueued(next)
        }
    }

    // MARK: - v2.0.126 蜂窝 relay 3.5KB 限制（粘贴长文本自动分段）

    /// 估算 relay 最终 URL 长度：payload={m,p,b} → base64url → /r?r=<b64>
    /// 用于发送前预判是否超限（限制 ~3.5KB = 3584，保守取 3400）
    /// v3.4.9 fix：原实现用 `JSONSerialization.data(withJSONObject:)` 序列化整个 body 估长——
    ///           ① splitLongText 每轮二分都全量序列化（O(n²)）；② JSONSerialization 对
    ///           部分超长/结构输入会抛 **NSException**（ObjC 异常），Swift 的 `try?`/do-catch
    ///           接不住，直接穿透到 `objc_exception_throw` → SIGABRT（蜂窝+贴超长文本点发送必现）。
    ///           改为纯字节估算（UTF-8 字节 + base64url 膨胀 + JSON 结构开销），**完全不调用
    ///           JSONSerialization**，既去崩溃源又去 O(n²)。
    private func relayPayloadLength(messages: [[String: Any]]) -> Int {
        // body JSON 字节数（保守偏大 +12%：payload 里 bodyStr 作为字符串再辗转义，裕量）
        let bodyBytes = Self.estimateBodyBytes(messages: messages,
                                               sessionId: chat.sessionId,
                                               model: modelName,
                                               provider: provider)
        // payload = {"m":"POST","p":"/api/stream/start","b":<bodyStr>}——结构开销 + 转义裕量
        let payloadBytes = Int(Double(bodyBytes) * 1.12) + 40
        let b64Len = Int(ceil(Double(payloadBytes) * 4 / 3))   // base64url ≈ 4/3 膨胀
        return auth.serverURL.count + 8 + b64Len               // https://host:port/r?r=
    }

    /// body JSON 字节数估（保守偏大）：字符串按 UTF-8 字节，键值加引号/冒号/逗号/括号结构开销
    private static func estimateBodyBytes(messages: [[String: Any]], sessionId: String, model: String, provider: String) -> Int {
        var n = 0
        n += utf8Len(sessionId) + 14      // "sessionId":""
        n += utf8Len(model) + 9           // "model":""
        n += utf8Len(provider) + 12       // "provider":""
        n += utf8Len("messages") + 7      // "messages":
        for m in messages {
            n += 2                        // {}
            for (k, v) in m {
                n += utf8Len(k) + 4       // "k":
                n += jsonValueApproxBytes(v)
            }
        }
        n += 2                            // ]
        n += utf8Len("pushEnabled") + 16  // "pushEnabled":false,
        n += utf8Len("agentEnabled") + 15 // "agentEnabled":true
        n += utf8Len("reasoning") + 16    // v3.6.5 "reasoning":"medium",
        return n
    }

    private static func jsonValueApproxBytes(_ v: Any) -> Int {
        if let s = v as? String {
            return utf8Len(s) + 2         // 两个引号
        }
        if let b = v as? Bool {
            return b ? 4 : 5              // true/false
        }
        if let a = v as? [Any] {
            var n = 2                     // []
            for e in a { n += jsonValueApproxBytes(e) }
            return n
        }
        if let d = v as? [String: Any] {
            var n = 2                     // {}
            for (k, vv) in d {
                n += utf8Len(k) + 4
                n += jsonValueApproxBytes(vv)
            }
            return n
        }
        return 16                         // 数字/其它，保守
    }

    private static func utf8Len(_ s: String) -> Int { s.utf8.count }

    /// 长文本拆段：每段使「历史 + 该段」payload ≤ 3400（二分最大前缀，至少 1 字符防死循环）
    private func splitLongText(_ text: String) -> [String] {
        let limit = 3400
        let baseHistory: [[String: Any]] = []   // v3.4.9 方案C：只传当前消息，无历史叠加
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
            // v3.0.86 fix：就地改 queued（count 不变）→ 显式重建缓存，即时去掉「排队中」角标
            refreshVisibleMessages()
            startStream(for: chat.messages[idx])
        }
        // v2.0.102：排队消息已不在列表（被删除/清空/切换）→ 直接丢弃，不重发（修复"删除后复活"）
    }

    /// v3.4.x 发送可靠性：队列落盘持久化 + 启动恢复补发（杀 App/断网重启不丢排队消息）
    private static let pendingQueueKey = "qingliao_pending_queue"

    func persistPendingQueue() {
        if let d = try? JSONEncoder().encode(pendingQueue) {
            UserDefaults.standard.set(d, forKey: Self.pendingQueueKey)
        }
    }

    func restorePendingQueue() {
        guard pendingQueue.isEmpty,
              let d = UserDefaults.standard.data(forKey: Self.pendingQueueKey),
              let arr = try? JSONDecoder().decode([PendingSend].self, from: d),
              !arr.isEmpty else { return }
        pendingQueue = arr
        UserDefaults.standard.removeObject(forKey: Self.pendingQueueKey)
    }

    /// v2.0.88：取消排队（停止按钮/切换会话）——清队列 + 消息恢复"已送达"状态
    func clearPendingQueue() {
        pendingQueue.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.pendingQueueKey)
        for i in chat.messages.indices where chat.messages[i].queued {
            chat.messages[i].queued = false
        }
        // v3.0.86 fix：queued 就地复位（count 不变）→ 显式重建缓存，「排队中」角标即时消失
        refreshVisibleMessages()
    }

    /// v2.0.62：打开图片查看器（收集会话内全部图片消息 → 相册翻页）
    /// v2.0.102：索引钳制——解码失败导致 images 比 imgMsgs 短时防越界
    func openImageViewer(for msg: ChatMessage) {
        let imgMsgs = chat.messages.enumerated().filter { $0.element.imageDataURL != nil }
        let images = imgMsgs.compactMap { dataURLImage($0.element.imageDataURL ?? "") }
        guard !images.isEmpty,
              let rawIdx = imgMsgs.firstIndex(where: { $0.element.id == msg.id }) else { return }
        let idx = min(rawIdx, images.count - 1)   // v2.0.102：坏图跳过导致偏移时钳制
        viewerPayload = ImageViewPayload(images: images, index: idx, sourceID: msg.id)   // v3.4.29：转场源
    }

    /// v2.0.128：AI 消息内图片点击 → 打开大图查看器（单张）
    /// data URL 直接解码进查看器；http(s) URL 双通道下载（URLSession → 自签证书降级 CFStream）
    func openAIImage(_ url: String, sourceID: String = "") {
        if url.hasPrefix("data:image/") {
            if let img = dataURLImage(url) {
                viewerPayload = ImageViewPayload(images: [img], index: 0, sourceID: sourceID)
            }
            return
        }
        guard let u = URL(string: url), url.hasPrefix("http") else { return }
        Task {
            let img = await Self.downloadImage(url: url, u: u)
            guard let img else { return }
            await MainActor.run {
                viewerPayload = ImageViewPayload(images: [img], index: 0, sourceID: sourceID)
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
        guard !stream.isStreaming else {
            Haptics.error()   // v3.4.25：流式中重试被拒 → 错误触感
            return
        }
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
            let startSid = chat.sessionId   // v3.5.2：会话切换后本次结果丢弃（与 startStream 一致）
            await stream.start(auth: auth, sessionId: chat.sessionId, model: useModel,
                               provider: useProvider, messages: history) { success, error in
                guard chat.sessionId == startSid else { return }   // 已切换会话 → 本次结果丢弃
                if !success {
                    chat.upsertAssistant(stream.content.isEmpty ? "⚠️ \(error)" : stream.content + "\n\n⚠️ \(error)", agent: stream.isAgent, afterUserID: anchorUserID)
                } else if stream.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // v3.5.1：空回复 → 明确提示（不用 markFailed，见 handleEmptyReply 注释）
                    chat.upsertAssistant(Self.emptyReplyNote, agent: true, afterUserID: anchorUserID)
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
        // Agent 模型：已配置独立模型即优先（v3.4.12：开关已移除，恒开启）
        let agentModelName = UserDefaults.standard.string(forKey: UserDefaultsKey.agentModel) ?? ""
        let agentProviderName = UserDefaults.standard.string(forKey: UserDefaultsKey.agentProvider) ?? ""
        if !agentModelName.isEmpty {
            return (agentModelName, agentProviderName)
        }
        return (modelName, provider)
    }

    /// ✅送达提示条（仅成功时显示，2.5s 后消失）
    func showSentOK() {
        withAnimation(Motion.settle) { sentOK = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { sentOK = false }
        }
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


// MARK: - v3.0.27 章节列表弹窗（纯静态章节标题展示，不做大纲导航）

/// v3.4.25：欢迎页建议芯片数据模型（Identifiable 供 ForEach 直接迭代）
struct WelcomeSuggestion: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let prompt: String
}

struct TOCSheet: View {
    let headers: [MarkdownRenderer.TOCItem]
    // v3.4.25：章节点击导航回调——传入后行可点，滚动到对应消息并高亮（复用 highlightTarget 机制）
    var onNavigate: ((MarkdownRenderer.TOCItem) -> Void)? = nil

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
                        if onNavigate != nil {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // v3.4.25：真导航（此前注释自认"点击导航不可靠"，highlightTarget 机制已稳定后启用）
                        onNavigate?(item)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("章节列表")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.plain)
        }
    }
}

