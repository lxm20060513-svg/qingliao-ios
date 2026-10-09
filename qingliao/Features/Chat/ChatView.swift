import SwiftUI
import QuickLook
import CoreLocation
import PhotosUI
import PDFKit
import UniformTypeIdentifiers
import AVFoundation
import Speech
import UIKit
import UserNotifications

/// v4.0.11：把「本会话落库」与「被移交任务落库」两条边沿合成一个可观察值，供 ChatView 的 `.onChange`
/// 使用 —— 该 view 的修饰符链已处在编译器类型检查超时的临界点（CI 报 2548 行 unable to type-check），
/// 合成后 modifier 数与出包前持平。Equatable 是 `.onChange(of:)` 的前提。
private struct LandedSignal: Equatable {
    let token: Int
    let away: Int
}

/// v4.0.36：滚动几何快照，供「贴底（pinned）」判定用。
/// 为什么不用 `Bool`：判定「用户是否离开底部」必须**同时**看 offset 与内容高度——
/// 流式 delta 只会让内容变高（offset 同帧不动），只拿一个 Bool 结果就会把
/// 「内容变高」误判成「用户上滑」（详见下方 onScrollGeometryChange 处的注释）。
private struct ChatScrollSnapshot: Equatable {
    let offset: CGFloat
    let contentH: CGFloat
    let containerH: CGFloat
}

struct ChatView: View {
    @Environment(AuthStore.self) var auth
    @Environment(ChatStore.self) var chat
    @Environment(StreamClient.self) var stream
    @Environment(InboxStore.self) var inbox   // v3.4.0：底部上拉手动拉取收件箱
    @Environment(KeyboardObserver.self) var kb
    /// v3.9.79：横屏判据 —— iPhone 横屏的 `horizontalSizeClass` 仍是 `.compact`（只有 Plus/Max 变 `.regular`），
    /// 所以「矮屏」只认 `verticalSizeClass == .compact`。见 `AdaptiveLayout.isShort`。
    @Environment(\.verticalSizeClass) private var vSize
    // v4.0.66 A+C：环境渐变页底需要感知深浅色（三团光晕各一套取值）
    @Environment(\.colorScheme) private var colorSchemeEnv
    @State var pinStore = PinStore.shared   // v3.0.74：钉一钉
    // v3.7.0：剪贴板地图链接兜底入口（地图分享面板里没有轻聊 → 「拷贝」后在聊天页一键发送）
    @State var showClipboardBanner = false
    // v3.9.71：输入收口——识别结果（动作条数据源）+ 剪贴板链接的「识别」提示
    @State var intentResult: RecognizedIntent?
    @State var showIntentClipboardBanner = false
    @State var recognizingImage = false        // 图片「识别」进行中（挡连点：连点会并发跑多次 OCR）
    @State var intentNoContentHint = false     // 图里没认出内容：给一次可见反馈（静默什么都不发生 = 像按钮坏了）
    /// v3.9.76：失败提示的文案（图片识别与剪贴板识别共用同一槽位，文案不同——原来写死"图里…"）
    @State var intentNoContentHintText = "图里没认出内容，可以直接发给 AI"
    /// v3.9.76：本次检测到的类别名（"链接 / 地址"…）——提示条文案用；空串 = 没检测到
    @State var clipboardIntentLabel = ""
    // v4.0.x 一句话记账（口径 1a）：刚在聊天框里记下的那一笔 → 驱动输入栏上方「已记账 + 撤销」动作条。
    // 只留**最近一笔**（这是个「刚做完的事」提示，不是账本列表；账本看生活页）。
    @State var chatRecordEntry: ChatRecordEntry?
    /// v4.0.x 一句话记账去重表（签名 → 上次记账时刻）。**为什么不能只靠 RecordStore 的 2 秒护栏**：
    /// 「重试」入口（retryMessage）会清掉 sendCore 的 60s 幂等签名并原样重发同一条文本，
    /// 只按 2 秒去重时「失败 → 一分钟后点重试」会凭空多记一笔。窗口见 ChatRecordKit.repeatWindow。
    @State var chatRecordSignatures: [String: TimeInterval] = [:]
    /// v4.0.x：记账去重提示的独立位（**不能**复用 intentNoContentHint —— 那个会被意图动作条盖住）
    @State var recordDedupNotice = false
    @State var dedupNoticeTask: Task<Void, Never>?
    /// v4.0.19 候选池⑯：被去重挡下的到底是哪一笔 —— 提示可点开看（原来只有一句死文字）
    @State var dedupItem: RecordItem?
    @State var dedupExpanded = false
    /// v4.0.19：签名 → 那一笔的 id。去重命中时要能反查「记的是哪一笔」，
    /// 光有 chatRecordSignatures 的**时刻**查不出条目。
    @State var chatRecordItems: [String: String] = [:]
    // 剪贴板的**单一真值源**（v3.9.72 收口）：上次进 App 时看到过的那一版 changeCount。
    // v3.8.1 的「已处理过的那一版」（handledClipChange + handledClipUptime 两个 @AppStorage）在
    // v3.9.72 换门后只写不读、已成为死代码，本轮删除——**别再恢复**，它有两个漏斗：
    //   ① 用户从没点过「忽略 / 发给 AI」→ 没有处理记录 → 每次进 App 重弹；
    //   ② 中途设备重启 → uptime 校验作废记录 → 同一份内容又弹一遍。
    // 现在进门只比"变没变"（ClipboardPromptGate.decide），不看"用户处没处理"。
    @AppStorage("qingliao_clip_last_seen_change") var lastSeenClipChange = -1
    /// 提示条自动收起任务（用户要求「一段时间没操作就自动隐藏」）
    @State var clipboardAutoHide: Task<Void, Never>?
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
    // v3.9.17：AI 生成物 QuickLook 预览的本地文件（下载落临时目录后交给 QuickLook）
    @State var quickLookURL: URL?
    @State var showMoreMenu = false
    /// v4.0.76：三点菜单锚定弹出——「更多」按钮的全局 frame（AnchorMenuOverlay 弹出位置）
    @State var moreMenuAnchor: CGRect = .zero
    /// v4.0.81：长按气泡/文字段的锚定菜单目标（锚点由 ChatBubbleAnchorStore 量好，见该类型注释）
    @State var bubbleMenuTarget: ChatBubbleMenuTarget?
    /// v4.0.81：返回「会话列表」（只有 iPhone 上「聊天」tab 的首页宿主会传 —— 那一 tab 现在
    /// 把会话列表与聊天页合成一页，需要有路回列表；iPad 双栏 / 其它入口不传即完全不渲染返回键）。
    var onBackToHome: (() -> Void)? = nil
    // v3.9.14：工具进度卡展开状态——生成中强制展开，答完默认收起（用户反馈这几行别一直摊着）
    @State var toolStepsExpanded = false
    // v3.4.24：任务中心全屏页（header 常驻小图标入口，原 DockTabView 全局 overlay 已移除）
    // v4.0.42 待做池 ①：提问推荐「猜你想问」
    /// 正在拉候选的 anchor（user 消息 id）——并发去重用，同一轮不重复打后端
    @State var suggestLoadingAnchor: String?
    /// 「换一批」的批号（同一 anchor 递增）——后端只当透传参数，App 侧靠它去重同一次点击
    @State var suggestBatch = 0
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
    /// v3.9.58c：ScrollViewReader proxy 引用（构造时写回，供引用块跳转等非 onChange 路径滚动定位）
    @State var scrollProxyRef: ScrollViewProxy?
    @State var showLongContextAlert = false
    // v3.9.58c：「上次任务未完」横幅——标记存在但不在当前会话（自动恢复被归属校验跳过）时显示
    @State var pendingResumeInfo: (sessionId: String, taskId: String, ageMinutes: Int)?
    @State var showCompressingAlert = false  // v3.0.81：AI 摘要压缩中
    @State var pendingSend: (text: String, imageData: String?)?
    @State var showAttachmentMenu = false
    // v2.0.96：Hermes 捷径面板（官方斜杠命令）
    @State var showHermesShortcut = false
    // v4.0.x：浏览器实时画面弹窗（watch 直播）
    @State var showBrowserLive = false
    @State var browserLiveSession: BrowserLiveSession?
    // 大爆炸（BigBang）文本炸开
    @State var bigBangPayload: BigBangPayload?
    @State var showPhotoPicker = false
    @State var showFileImporter = false
    @State var showCameraPicker = false   // v2.0.38 拍照输入
    @State var photoItem: PhotosPickerItem?
    @State var pendingImage: UIImage?
    @State var pendingImageData: String?
    @State var showAnnotate = false   // v4.0.50 待做池⑦：图片圈注面板
    // v3.9.3：语音转文字改**设备端实时转写**（SpeechAnalyzer/SpeechTranscriber）——
    // 边说边出字、音频不上传、本地/云端双模式都能用；后端 ASR 与 VoiceRecorder 整条链路已移除
    @StateObject var liveSpeech = LiveSpeechTranscriber()
    @State var voiceMode = false
    @State var transcribing = false   // v2.0.100：转写动画（v3.9.3 语义扩为「准备模型 / 定稿中」）
    @State var voiceAuthFailed = false
    @State var voiceError = ""        // v3.9.3：非权限类的启动/识别失败原因
    @State var voiceStartToken = 0    // v3.9.3：语音启动代次——首次可能要下载模型（数秒~数十秒），
                                      // 期间用户若已取消，start() 返回后必须作废，否则会卡在语音模式
    @State var sendingLock = false   // v2.0.102：发送锁（防双击双流竞态）
    /// v4.0.10：锁的置位时刻。**发送锁必须有窗口上限**——收尾回调不是必然发生的：
    /// 「新建会话」把在跑的流移交给 BackgroundStreamRunner 时会调 `StreamClient.detachLocally()`，
    /// 那条路径刻意把 onFinished 置 nil（落库归 runner），于是 startStream 的 completion 永不执行。
    /// 旧实现只靠 completion 里的 `sendingLock = false` 解锁 → 一次「回答中新建会话」就让发送锁
    /// 永久为真，此后**所有发送在 sendCore 第一道 guard 静默 return**（输入框已清空、消息不上屏、
    /// 后端零请求），用户看到的就是「发出去不上屏」。v4.0.9 实报复现。
    @State var sendingLockAt: TimeInterval = 0
    @State var autoRetryCount = 0    // v3.4.x：消息失败自动重试计数（网络类错误最多自动重试 2 次，防死循环）
    @State private var lastSentSignature: (sessionId: String, text: String, image: String?, ts: TimeInterval)?  // 同内容 60s 幂等（v3.4.27 fix：签名含图片指纹——纯图 text 恒空，无图指纹会把 60s 内第二张纯图误判重复丢弃）
    @State var fileSendBlocked = false   // v2.0.102：流式中发文件提示
    // v4.0.x：清空固定会话被拦时的提示（文案要带会话名，所以用 String? 而非 Bool）
    @State var clearBlockedHint: String?
    @State var voiceTooShort = false   // v2.0.102：录音太短提示
    @State var voiceDiag = ""   // v3.0.78 诊断：录音链路诊断信息
    // v2.0.88：AI 回答中发送的消息队列（回答结束后自动逐条发送）
    @State var pendingQueue: [PendingSend] = []
    // v3.4.0：底部上拉拉取收件箱状态（@Observable 引用——拖动高频写不重建 ChatView body）
    @State var inboxPull = InboxPullState()
    // v3.4.x 存储自洁：长会话超阈值提示手动归档（消息数超限显示提示条，点击导出）
    @State var showArchiveHint = false
    // v3.0.27：章节列表（纯静态展示，不做滚动导航）
    @State var showTOCSheet = false
    // v3.9.86：长回复阅读（长按气泡「全屏阅读」→ 半屏 sheet 放大阅读 + 章节大纲）
    @State var longReplyPayload: LongReplyPayload? = nil
    // v3.0.51 A2：极长会话分页懒加载——初始只渲染尾部最近 N 条，顶部可"加载更早"
    @State var displayLimit = 300
    private static let loadMoreStep = 300
    // v3.3.0：多选合并发送——选择模式开关 + 选中消息 id 集合
    @State var selectMode = false
    @State var selectedMsgIDs: Set<String> = []
    @State var selectBlocked = false      // 流式中尝试进入多选 → 提示
    // v4.0.44 待做池 3：改口（编辑已发消息）——待编辑的那条 + 重答失败提示
    @State var editingMessage: ChatMessage? = nil
    @State var editFailedAlert = false
    @State var editFailedNote = ""
    @State var fileGoneAlert = false      // v3.9.31：文件预览下载失败 → 文件已失效提示
    @State var mergeTooMany = false       // 合并超过 99 条 → 提示
    static let maxMergeCount = 99
    // v3.9.32：一句话定时提醒（气泡长按「提醒我」）
    @State var showQuickReminder = false
    @State var reminderSeedText = ""
    // v3.0.51 A2 fix：缓存可见消息数组——仅在消息数量/显示上限变化时重建，
    // 避免每帧 stream.delta 触发 body 重建 O(visible) 数组
    @State private var visibleMessagesCache: [MessageRowItem] = []
    // v3.0.86 fix：是否贴底（onScrollGeometryChange 实时维护）——流式自动滚底仅贴底时生效
    @State private var scrollPinState = ChatScrollPinState.pinnedAtBottom
    // v4.0.34：消息列表滚动容器的可视高度（GeometryReader 测量）——内容不满一屏时
    // 列表以它为 minHeight。
    // 🚨 v4.0.54：对齐口径由 `.bottom`（贴底）改为 **`.top`** —— 新会话第一条气泡在最上方，
    // 后面的往下堆、排满后往上翻（用户 2026-10-05 报障原话）。
    @State private var chatListViewportH: CGFloat = 0
    /// v3.9.78：欢迎页宠物的「抚摸」反应触发器（轻点自增 → PetAvatar 播一次 ≤1.2s 反应）
    @State private var petPat = 0
    /// v3.9.78：宠物在屏幕上的真实中心（长按弹菜单时当锚点用，胶囊从宠物身上绽放）
    @State private var petGlobalCenter: CGPoint = .zero

    /// v3.9.78：欢迎页宠物的状态——**只接既有信号，不新增状态源**。
    ///   · alert（耷拉）：后端离线（`serverOnline == false`，欢迎页本来就该有失败的冗余通道）
    ///     或本条生成失败（`generationFailed`，与灵动岛「生成失败」红态同一判定）
    ///   · thinking：AI 正在回（aiBusy）
    ///   · idle / patting 其余
    ///
    /// ⚠️ 为什么**不接**「新消息（unseen）」：`orbUnseen` 只在本页**不可见**时才为真
    ///   （DockTabView 用 `!chatVisible` 置位），而欢迎页只在 `chat.messages.isEmpty` 时渲染
    ///   —— 两者时间上互斥，接上去就是死代码（调研结论：不做只动画表达状态的假接线）。
    ///   要让它有意义，得先把宠物放到「有消息时也在场」的位置（那是 30/38pt 头像那一层）。
    private var petState: PetState {
        if serverOnline == false || generationFailed { return .alert }
        return aiBusy ? .thinking : .idle
    }

    /// v3.9.78：生成失败判定提成**单一真源**（原来只写在 pushLiveActivity 里）——宠物与灵动岛共用。
    private var generationFailed: Bool {
        stream.status == "error" && !stream.errorMessage.isEmpty
            && !isRetryableStreamError(stream.errorMessage)
    }
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
        // v4.0.40：可见窗口重建前先取旧 id 序列——判定这次是不是「纯追加一条」，
        // 是才给插入动画开事务（原因见 Core/MessageInsertAnim.swift 文件头）。
        // 注意旧序列必须取**真实可见窗口**（而不是 chat.messages 全量）：visibleMessagesCache
        // 装的就是它，两者窗口一致才能让「前缀相同」真正等价于「这一条是新插进来的」。
        let prevIDs = visibleMessagesCache.map(\.id)
        let next = (start..<msgs.count).map {
            MessageRowItem(index: $0, msg: msgs[$0], prevMsg: $0 > 0 ? msgs[$0 - 1] : nil)
        }
        let pureAppend = MessageInsertAnim.isSingleAppend(prev: prevIDs, next: next.map(\.id))
        if pureAppend {
            // 🚨 只有纯追加才播气泡插入动画。整组替换 / 清空 / 切会话不播（v3.9.31 批量移除闪退）。
            withAnimation(Motion.enter) { visibleMessagesCache = next }
        } else {
            visibleMessagesCache = next
        }
    }

    // 模型/提供商可从模型管理面板选择（UserDefaults 持久化）
    // v2.0.48：改 @AppStorage——computed property 无观察机制，
    // 设置页切换模型后聊天页头部不刷新（模型实际生效但显示旧名）
    @AppStorage("qingliao_model") private var modelName = "deepseek-v4-flash"
    @AppStorage("qingliao_provider") private var provider = "opencode"
    /// v3.6.5：模型思考档位（header 胶囊，仅本地模式）——随流式请求下发给后端
    @AppStorage(ReasoningLevel.storageKey) private var reasoningLevelRaw = ReasoningLevel.low.rawValue
    // v3.9.8：AI 回复自动朗读（header 胶囊开关）。默认关（不被动出声）。
    // v3.9.9 起：自动朗读**跟随设置里的「AI 语音朗读」开关**（开着=神经音色，关=系统语音），
    // 不把每轮回复全文 POST 到后端神经 TTS；想要神经音色就手动点气泡上的朗读。
    // 注意区别：设置页的「AI 语音朗读」管的是**引擎**（CloudConfig.ttsEnabled 默认 true → 手动朗读默认走后端
    // 神经音色），这里的胶囊管的是**要不要自动念**，两者各管一段、互不覆盖。
    @AppStorage("qingliao_auto_read_reply") private var autoReadReply = false
    /// v4.0.68（用户 2026-10-07）：聊天页 header 正中那只宠物（设置页同名开关，key 单一真源在 `PetKeys`）。
    /// 关掉 = 那一格**不渲染**，header 回到「没有 centerView」的原样（与空会话态同一形态，不留空占位）。
    @AppStorage(PetKeys.headerVisible) private var petHeaderOn = true
    /// v3.9.9 收口：自动朗读去重（同一条只自动念一次，手动点气泡不受限）
    /// v3.9.9：去重键**非可选**（`msg.uid ?? msg.id`）——uid 对老数据是 nil，
    /// 可选比较会遇到 nil == nil 伪去重：第一次朗读被吞掉、之后带 nil uid 的回答永远不念
    @State private var lastAutoReadKey = ""
    /// v3.9.9 收口：用户主动「停止生成」（输入栏 / 灵动岛）→ 本轮不自动朗读（别把残句念一遍）
    @State private var suppressAutoReadOnce = false
    @State private var showReasoningPicker = false
    /// v4.0.76：思考档位菜单锚定弹出——输入栏「思考档位」胶囊的全局 frame
    @State private var reasoningAnchor: CGRect = .zero
    /// v4.0.31：header 中央宠物的「回答完成」庆祝触发器（本会话流结束那一刻 +1，v4.0.27 口径回归）
    @State private var petCelebrate = 0
    /// v3.9.48：输入栏展开态右下角的模型快选面板
    @State private var showComposerModel = false

    /// v3.9.41（A1 遗留收口）：本机这条流**是不是正在给当前会话干活**——`stream` 是 App 级单例，
    /// 会话 A 在跑时 `stream.isStreaming` 在 B 会话里同样是 true，于是 B 的输入栏长出「停止」按钮
    /// （点了会掐掉 A 的回答）、欢迎页/续聊芯片/多选/上拉刷新全被 A 挡住。
    /// 口径与 v3.9.39 A1 已收窄的那几处完全一致（`aiBusy` / `liveActivityCanStop` / `toolStepCards` / 流式气泡）。
    ///
    /// ⚠️ 反过来，凡是「**单例是否被占用**」的护栏必须继续用全局 `stream.isStreaming`，绝不能换成这里：
    /// `sendCore` 的排队分支、`sendQueued`、`retryMessage`、`regenerate`、`adoptRemoteStream`、
    /// `probeRemoteBusy` 里的接回判定、`ChatViewExport.sendFile`，以及「新建会话先停旧流」。
    /// 其中 `regenerate` / `sendFile` / `adoptRemote` 直接 `stream.start(...)`，不经排队；
    /// `StreamClient.start()` 内部又无任何
    /// 「已在跑就拒绝」的守卫（它直接 stopPolling + 复位状态 + 覆盖 `auth.currentStreamSessionId`），
    /// 一旦在别的会话里放行就会静默掐断正在跑的流、并把答案落错会话。
    var thisSessionStreaming: Bool {
        stream.isStreaming && auth.currentStreamSessionId == chat.sessionId
    }

    /// v3.9.41：章节列表数据源——**逐条** assistant 正文各抽各的标题，并把所属消息下标打进 TOCItem。
    /// 旧写法是把全部正文 join 成一整篇再抽，`lineIndex` 是那次拼接文本的行号，跟 `chat.messages`
    /// （全角色数组）的下标毫无对应关系，拿去索引必然跳错（行号 ≥ 消息数时干脆点了没反应）。
    /// 跳转只需要到**消息**粒度（滚动与高亮本来就以 message.id 为单位），消息内的行号是多余信息。
    private func tocHeaders() -> [MarkdownRenderer.TOCItem] {
        var out: [MarkdownRenderer.TOCItem] = []
        for (i, m) in chat.messages.enumerated() where m.role == "assistant" {
            for h in MarkdownRenderer.extractHeaders(m.content) {
                var tagged = h
                tagged.msgIndex = i
                out.append(tagged)
            }
        }
        return out
    }

    /// v3.5.1：是否有 AI 在处理本会话——本地流 / 服务器兜底探测（v3.9.28：云端流已移除）。
    /// 本地流按会话收窄：stream 是全局单例，会话 A 在跑时切到 B 不该显示"AI 正在输入"。
    /// v4.0.x：放开 `private` 供 InboxPullRefresh 读——上拉拉取推送必须与「AI 忙」共用同一真值源，
    /// 各写一份 `thisSessionStreaming || remoteBusy` 迟早漂移（用户实测：思考阶段胶囊仍浮出）。
    var aiBusy: Bool {
        thisSessionStreaming || remoteBusy
    }
    /// v3.8.0：实时活动（灵动岛/锁屏）展开态展示的模型名——**复用发送路径同一套选型**（视觉/Agent/主模型），
    /// 口径对齐 SessionsView.displayModel；否则会出现「灵动岛写着主模型、实际回的是 Agent/视觉模型」的错报
    private var liveActivityModelName: String {
        resolveModel(hasImage: false).0
    }

    /// v3.9.48：输入栏展开态的模型胶囊显示名——**复用发送路径同一套选型**（视觉/Agent/主模型），
    /// 与上面灵动岛同口径：只读 `qingliao_model` 会在 Agent/视觉模型生效时报错模型（v3.8.0 实踩）。
    /// v3.9.49（真机：「不用显示 provider，只显示模型即可」）：去掉 `provider/` 前缀——
    /// 胶囊本来就窄，加了前缀只装得下 `opencode/d…eek-v4-flash` 这种没法读的截断串。
    private var composerModelLabel: String {
        resolveModel(hasImage: false).0
    }

    /// v3.9.7：实时活动阶段——驱动灵动岛三态（思考中 / 输出中 / 已完成）。
    ///
    /// 本地流可精确到「输出中」：`stream.content` 在本轮开始时被清空（StreamClient.start 里 `content = ""`），
    /// 有内容即说明首 token 已到。注意**不能**用 `stream.status == "streaming"` 判断——那个值只在
    /// `adoptRemote`（后台 recover 接管服务端在途任务）时被置上，正常发送路径全程是空串。
    /// 云端流 / 服务器兜底探针只有「忙 / 闲」两态 → 一律按「思考中」展示，不假装精确。
    private var liveActivityPhase: String {
        guard aiBusy else { return QingliaoActivityAttributes.Phase.done.rawValue }
        let localStreaming = thisSessionStreaming && !stream.content.isEmpty
        return localStreaming ? QingliaoActivityAttributes.Phase.streaming.rawValue
                              : QingliaoActivityAttributes.Phase.thinking.rawValue
    }

    /// v3.9.7：灵动岛状态行文案。只说能确证的阶段，**不虚构「联网搜索 / 写代码」这类没有数据源的措辞**
    private var liveActivityActionText: String {
        switch liveActivityPhase {
        case QingliaoActivityAttributes.Phase.streaming.rawValue:
            return "正在生成回答"
        case QingliaoActivityAttributes.Phase.thinking.rawValue:
            return "正在理解你的问题"
        default:
            return ""
        }
    }

    /// v3.9.7：灵动岛「停止生成」是否可用——**只有本地流能被停**（云端流没有停止接口，
    /// 与聊天页输入栏「停止」按钮同口径：那个按钮也只在**本会话**有本地流时才出现）。
    /// 不可停就干脆不显示按钮，别放一个点了没反应的入口。
    private var liveActivityCanStop: Bool {
        thisSessionStreaming
    }

    /// v3.9.7：把当前状态推给实时活动管理器。busy=false 走「先落完成态、系统 2s 后收起」。
    /// 先取成本地 Sendable 值再进 Task（Task 闭包是 @Sendable，不能捕获 View/Store）
    private func pushLiveActivity(busy: Bool) {
        let sessionId = chat.sessionId
        let title = chat.title
        let model = liveActivityModelName
        let phase = liveActivityPhase
        let action = liveActivityActionText
        let canStop = liveActivityCanStop
        // v3.9.30：失败感知——本地流已以 error 收尾（且不是自动重试中）→ 灵动岛落「生成失败」红态。
        // 提前取本地值再进 Task（Task 闭包 @Sendable 不能捕获 View/Store）
        // v3.9.78：判定提成 `generationFailed`（单真源），与欢迎页宠物的 alert 态共用
        let streamFailed = generationFailed
        Task { @MainActor in
            if busy {
                await LiveActivityManager.shared.sync(isBusy: true,
                                                      sessionId: sessionId,
                                                      sessionTitle: title,
                                                      modelName: model,
                                                      phase: phase,
                                                      actionText: action,
                                                      canStop: canStop)
            } else {
                // 带会话 id：切到别的会话时 aiBusy 也会变 false，不能据此收掉仍在跑的那条活动
                await LiveActivityManager.shared.finish(sessionId: sessionId, failed: streamFailed)
            }
        }
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

    /// v3.9.8：自动朗读开关（开 = AI 每轮回复结束自动念一遍；关 = 不自动念，
    /// 气泡上的朗读按钮仍可手动念，互不影响）。
    /// v4.0.36（用户要求）：胶囊本体**从 header 迁入输入栏工具层**——挂在模型思考档位旁、
    /// 图标风格跟着思考档位胶囊同档；header 不再挂它。
    /// 这里只留「状态 + 动作」：显隐/样式由 ChatInputBar 的 `autoReadIcon` / `autoReadOn` 决定，
    /// 本页只把展示值与回调传下去（输入栏不认识 TTS 概念，与思考档位同一套传参口径）。
    /// v3.9.37（用户要求）：两态共用同一枚喇叭图标、只靠颜色区分——启用蓝(accent) / 禁用灰(secondary)。
    private func toggleAutoRead() {
        autoReadReply.toggle()
        if !autoReadReply { SpeechManager.shared.stop() }   // 关掉立刻闭嘴，不留半句
        Haptics.tap()
    }

    /// v4.0.11：从 body 的 `.task` 里提出来的启动期逻辑（见 body 处注释：编译器类型检查超时）。
    /// 纯等价搬移，逐行顺序与原先一致，零行为变化。
    private func bootstrapChat() async {
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

    /// v3.9.8：自动朗读最新一条 AI 回复。
    /// 只念真正的「AI 回答」——跳过推送气泡（🔔 收件箱/进度，isPush）与错误占位（isErrorPlaceholder），
    /// 那些念出来只会莫名其妙。
    private func autoReadLatestReply() {
        // 抑制标记**只在真正要念时才消费**：原来无条件清掉，生成期来一个 🔔 进度气泡（isPush）
        // 就把标记吃掉，用户停止后落库的残句又会被念出来（只读审查抓到的回归）。
        guard autoReadReply, !suppressAutoReadOnce else { return }
        // v4.0.x 流式分段朗读：本条已在流式期间由分段队列逐段朗读 → 落库边沿整段朗读跳过
        //（guard 后置：suppressAutoReadOnce 的消费语义不受影响）。
        if stream.hasStreamingSpeech { return }
        // v3.9.9：念**刚落库的那条**，不用 `chat.messages.last`——AI 回答中用户又发消息时
        // 本轮回复 insert 在数组中段，末条是排队 user 消息（见 ChatStore.lastLandedAssistantUID）
        guard let landedUID = chat.lastLandedAssistantUID,
              let msg = chat.message(withUID: landedUID) else { return }
        guard !msg.isUser, !msg.isPush, !msg.isErrorPlaceholder else { return }
        // 注：不再需要 last(where:) 这类回溯——触发源已精确到"哪一条回复落库"，不会念到旧答案
        // 与气泡朗读同口径：剥掉后端注入的 🔧/💭 进度行再念
        // （类型名是 MessageBubble —— 文件名虽叫 ChatMessageBubble.swift，里面声明的却是 MessageBubble）
        let text = MessageBubble.strippingProgressLines(msg.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 去重键取**非可选**值 `uid ?? id`：uid 对老数据是 nil，可选比较会遇到 nil == nil 伪去重
        // （第一次朗读被吞掉、之后带 nil uid 的回答永远不念）。msg.id 本身已含 timestamp + uid，
        // 拿它兜底不会与"连续两条相同回答"误撞。
        let key = msg.uid ?? msg.id
        guard key != lastAutoReadKey else { return }
        lastAutoReadKey = key
        suppressAutoReadOnce = false          // 走到这里才消费抑制标记（本轮确实要念了）
        // v3.9.9（用户反馈「TTS 语音太生硬」）：**不再固定系统语音**，改为跟随设置里的
        // 「AI 语音朗读」开关 —— 开着就用所选模型的神经音色（设置里可选音色：磁性男声/温柔男声/
        // 气质温婉/活力轻快…），关掉才用系统语音（免费离线、不上传全文）。
        // 原来这里硬写 preferSystem: true，把神经音色整个跳过了；而系统默认是 compact 音质
        // （没装"增强/优质"语音包时格外机械）→ 听感生硬。
        // id 传 msg.id：与气泡朗读按钮同一标识，否则自动朗读时气泡上的音柱不亮
        SpeechManager.shared.speak(text, id: msg.id)
    }

    // v4.0.76：原 reasoningPickerContent（档位 dialog 内容）已随 confirmationDialog 一并移除——
    // 档位菜单改锚定浮层，数据直接在 overlay 处从 ReasoningLevel.allCases 映射。

    @ViewBuilder
    private var headerTrailingItems: some View {
        // v4.0.27：思考档位胶囊迁入输入栏工具层（附件/相机旁）
        // v4.0.36：朗读胶囊同样迁入工具层（紧挨思考档位）
        // ⇒ header 右侧那两枚胶囊都已不在，只剩这两颗图标；
        // v4.1.x（用户 2026-10-05 看对比稿拍板方案 A）：两颗**合并成一整颗胶囊**
        // ——图标 14 / 囊高 34 / 中心距 30 / 端部内边距 12、玻璃与命中区全在 HeaderPillGroup 里定义
        HeaderPillGroup(items: chatHeaderItems)
    }

    /// v4.1.x：聊天页页头图标项（合并成一颗胶囊用）——任务中心（有未完成任务时带红点）+ 更多
    private var chatHeaderItems: [HeaderPillGroup.Item] {
        [
            HeaderPillGroup.Item(id: "tasks",
                                 systemName: "list.bullet.circle",
                                 a11y: "任务中心",
                                 badge: taskStore.uncompleted > 0) {
                showTaskCenter = true
            },
            HeaderPillGroup.Item(id: "more", systemName: "ellipsis.circle", a11y: "更多",
                                 anchorOut: { moreMenuAnchor = $0 }) {
                // v4.0.76：菜单从三点按钮处弹出（锚定浮层替代居中 confirmationDialog）
                showMoreMenu = true
            },
        ]
    }

    /// v3.3.0：confirmationDialog 内容抽离（原内联 Menu+8个Button 过长致 Xcode26
    /// type-check 超时——508行报 "unable to type-check in reasonable time"）。
    /// 抽成独立 @ViewBuilder 属性给 type-checker 更小的表达式单元。
    /// v4.0.76：改**数据驱动**（AnchorMenuOverlay 吃 [AnchorMenuItem]）——顺序/文案与原
    /// dialog 一一对应；「取消」由浮层「点空白收回」取代，不再单列。
    private var chatActionMenuItems: [AnchorMenuItem] {
        [
            AnchorMenuItem(id: "export", title: "导出会话记录", icon: "square.and.arrow.up.on.square", color: .blue),
            AnchorMenuItem(id: "shareCard", title: "分享会话卡片", icon: "photo.on.rectangle", color: .blue),
            AnchorMenuItem(id: "multiSelect", title: "多选合并发送", icon: "checkmark.circle", color: .teal),
            AnchorMenuItem(id: "compress", title: "压缩上下文（保留最近 20 条）", icon: "arrow.down.right.and.arrow.up.left", color: .orange),
            AnchorMenuItem(id: "summarize", title: "AI 总结会话", icon: "text.badge.starlight", color: .indigo),
            AnchorMenuItem(id: "toc", title: "章节列表", icon: "list.bullet", color: .teal),
            AnchorMenuItem(id: "clear", title: "清空本会话消息", icon: "trash", destructive: true),
        ]
    }

    /// v4.0.76：锚定菜单动作分发（与原 chatActionDialogContent 各 Button 体逐条等价搬运）
    private func handleChatActionMenuPick(_ item: AnchorMenuItem) {
        showMoreMenu = false
        switch item.id {
        case "export":
            showExportSheet = true
        case "shareCard":
            shareSessionCard()
        case "multiSelect":
            // v3.3.0：多选合并发送（勾选多条 → 合并成一张卡片图片 → 系统分享/微信）
            if thisSessionStreaming {   // v3.9.41：本会话在收流才拦（A 在跑不该让 B 不能多选）
                selectBlocked = true
            } else {
                inputFocus = false
                selectedMsgIDs.removeAll()
                withAnimation(Motion.snap) { selectMode = true }
            }
        case "compress":
            // v2.0.43：上下文信息并入 dialog message（不再是空 action 按钮）
            if chat.compressContext() {
                Task { await chat.saveToServer(auth: auth) }
            }
        case "summarize":
            // v2.0.116：AI 总结会话（走正常流式，AI 回复要点总结）
            summarizeSession()
        case "toc":
            // v3.0.27：章节列表（纯静态展示，不做滚动导航）
            showTOCSheet = true
        case "clear":
            clearMessagesFromMenu()
        default:
            break
        }
    }

    /// v4.0.76：「清空本会话消息」动作体（原 chatActionDialogContent 里 destructive Button 的 body）
    private func clearMessagesFromMenu() {
        // v4.0.18：固定会话（投递壳 / 轻聊主动）**允许**清空（用户拍板：这两个会话也要能清）。
        // 后端配套：投递壳本就走 _CLIENT_WINS_IDS（v3.9.72 内容以客户端为准）；
        // 主动会话由 merge_sessions 空数组特判采纳（显式清空意图，非空快照仍以 NAS 为准防丢回复）。
        // 本会话正在收流 → 拦（流式回复结束后的落库写会把刚清空的会话又写满）。
        if thisSessionStreaming {
            clearBlockedHint = "AI 正在回复，等回复结束后再清空"
            return
        }
        // v2.0.40：两步走清空——先切欢迎页分支（列表立即卸载，数据未动），下一帧再清数据。
        // 列表销毁与数据清空完全错开，杜绝同帧崩溃。
        clearing = true
        // SR5：原实现在 clearMessages **之前**就 Task{saveToServer}，写的是清空前的全量快照
        // （后端同 id 整会话覆盖 → 白写），而清空后的空数组又被 writeSessionSnapshot 的
        // 「空即跳过」护栏挡掉 → NAS 上历史原封不动，重启/换设备后「清空的消息又复活」。
        // v4.0.15：发空写之前先排空在途写链（防旧快照在空写之后落地盖回）。
        let sid = chat.sessionId
        let ttl = chat.title
        Task {
            await chat.flushPendingWrites()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(nil) { chat.clearMessages() }
                clearing = false
                Task { await chat.saveToServer(auth: auth, sessionId: sid, messages: [],
                                               title: ttl, allowEmpty: true) }
            }
        }
    }

    /// v3.3.0：输入区抽离——原 body 内 if selectMode/else(ChatInputBar 17参+多closure) 内联
    /// 过长是压垮 Xcode26 type-check 的"最后一根稻草"（v3.2.4 能过因 body 没这么重）。
    /// 抽成独立属性给 type-checker 更小的表达式单元。
    @ViewBuilder
    private var inputArea: some View {
        if selectMode {
            // v4.0.76：合并操作条**优先于**投递只读提示——多选合并是只读操作（渲染成图分享，
            // 不往会话写），投递会话里长按「多选」也能正常进（原顺序下进了勾选态却没有
            // 操作条，卡死无法退出 = 用户报的「无法多选」）。消息列表写入另有 guard 拦着。
            mergeSelectBar
        } else if chat.isDeliverySession {
            // v3.9.85：投递会话只读——cron/system 投递详情只收不发（此前输入栏照常可打字，发了也白发）。
            // 不给输入框只压一条提示：用户不会误以为能回复；高度与输入栏对齐(50)避免底部跳动。
            HStack(spacing: 8) {
                Image(systemName: "tray.full")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                Text("投递会话 · 仅接收，不支持回复")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(height: 50)
            .padding(.horizontal, Spacing.md)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, Spacing.md)
        } else {
            ChatInputBar(text: $inputText,
                     focused: $inputFocus,
                     streaming: thisSessionStreaming,   // v3.9.41：按会话收窄（原来 B 会话会因 A 在跑而长出红色「停止」，一点就掐掉 A 的回答）
                     onSend: { send() },
                     onStop: {
                         // v2.0.88：点停止 = 取消当前回答 + 清空排队消息（不再自动发）
                         clearPendingQueue()
                         suppressAutoReadOnce = true   // v3.9.9 收口：主动停止 → 残句不念
                         stream.stop(auth: auth)
                     },
                     onPickAttachment: {
                         // v3.9.30：面板=大块浮现 → 展开走 emerge（带轻微回弹）；收起保持 settle 不带回弹
                         if showAttachmentMenu {
                             withAnimation(Motion.settle) { showAttachmentMenu = false }
                         } else {
                             withAnimation(Motion.emerge) { showAttachmentMenu = true }
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
                     isRecording: liveSpeech.isRunning,
                    // v2.0.96：语音转文字（长按发送按钮）
                    voiceMode: voiceMode,
                    onVoiceModeToggle: { toggleVoiceMode(keyboardWasUp: kb.isVisible) },
                    transcribing: transcribing || liveSpeech.isPreparing,
                    onCancelTranscribe: { cancelTranscribe() },
                    onLongPressInput: { keyboardWasUp in toggleVoiceMode(keyboardWasUp: keyboardWasUp) },
                    // v3.9.3：设备端识别，不依赖后端 —— 云端模式同样开放语音入口（v3.0.4 的屏蔽已撤）
                    voiceEnabled: true,
                    // v3.9.6：录音态实时文本 + 诊断串（声明序在 voiceEnabled 之后，实参必须同序）
                    // v3.9.9：文本源不再只看 voiceMode —— 只要识别器在跑就上屏
                    // （voiceMode 是"进入语音模式"的 UI 旗标，与"是否正在收音"是两件事，耦合在一起
                    //   会出现"红点在、却没文字"这种自相矛盾的中间态）
                    recordingText: (voiceMode || liveSpeech.isRunning) ? liveSpeech.liveText : "",
                    // v3.9.9：诊断串改为录音期间**始终**显示——V/F 是识别计数，T/D/Y 是音频三级计数
                    // （T=麦克风回调/D=丢弃/Y=投递 analyzer）。原来只在"3s 无结果"时才显示，
                    // 恰好把"有回调但一个都没投出去"这类静默失败藏了起来。
                    recordingDiag: liveSpeech.pipeStats.isEmpty ? ""
                        : liveSpeech.resultStats + " " + liveSpeech.pipeStats,
                    // v3.9.14：3s 无结果才把诊断串显示出来（正常录音时输入框只显示识别文本）
                    recordingStalled: liveSpeech.liveStalled,
                    // v3.4.25：上下文使用率传入——超 80% 发送键变橙轻提醒
                    // v3.0.81 / v4.0.x：使用率分母与压缩阈值同源（ContextTuning.threshold），
                    // 不再写死 4000——否则"阈值 6000 / 进度条按 4000 算"，到 3200 就变红。
                    contextUsage: chat.contextUsage(maxTokens: ContextTuning.threshold),
                    // v3.9.48：聚焦展开时右下角浮出的模型快选胶囊
                    modelLabel: composerModelLabel,
                    onPickModel: { showComposerModel = true },
                    // v4.0.x：录音点接实时电平（voice-glow 位点）。传**闭包**不传值——
                    // currentInputLevel() 是 nonisolated 快照，每帧由录音点自己读一次；
                    // 若在这里取值传下去，ChatView 这个超大 body 会被电平更新连坐重绘。
                    // ⚠️ 实参序必须 = ChatInputBar 存储属性声明序（recordingLevel 声明在最前）
                    recordingLevel: { liveSpeech.currentInputLevel() },
                    // v4.0.27：模型思考档位胶囊迁入工具层（附件/相机旁）——传展示值不传枚举
                    reasoningLevelIcon: reasoningLevel.symbol,
                    reasoningLevelTitle: reasoningLevel.title,
                    onPickReasoning: { showReasoningPicker = true },
                    onReasoningAnchor: { reasoningAnchor = $0 },   // v4.0.76：锚定菜单锚点
                    // v4.0.36：朗读胶囊同样迁入工具层（紧挨思考档位）——同一套「传展示值 + 回调」
                    // ⚠️ 实参序必须 = ChatInputBar 存储属性声明序（autoReadIcon 声明在 onPickReasoning 之后）
                    autoReadIcon: "speaker.wave.2.fill",
                    autoReadOn: autoReadReply,
                    onToggleAutoRead: { toggleAutoRead() })
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
                    .clipShape(RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                Text("图片已选：点识别直接处理，或发送给 AI")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                // v3.9.71 图片入口：本机 OCR 认内容 → 直接给可执行动作（不用先发出去）
                Button {
                    recognizePendingImage(img)
                } label: {
                    HStack(spacing: 4) {
                        if recognizingImage {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(recognizingImage ? "识别中" : "识别")
                    }
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.xs)
                    .glassPillStroke()
                }
                .buttonStyle(PressStyle())
                .disabled(recognizingImage)
                .accessibilityLabel("识别图片内容")
                // v4.0.50 待做池⑦：圈注入口——在图上画圈/划重点/箭头，完成后与原图一起发给 AI
                Button {
                    showAnnotate = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil.tip.crop.circle")
                        Text("圈注")
                    }
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.xs)
                    .glassPillStroke()
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("圈注图片")
                Button {
                    pendingImage = nil
                    pendingImageData = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.headline))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, Spacing.sm)
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
                // v3.9.28：云端模式移除，Hermes 捷径恒显示（v3.0.6 的按模式隐藏随之作废）
                menuButton("sparkles", "Hermes 捷径", Color.purple, idx: 3) { showHermesShortcut = true }
                // v4.0.x：浏览器实时画面（watch 模式直播弹窗；手动输入站点即时观看）
                menuButton("desktopcomputer", "浏览器", Color.teal, idx: 4) { showBrowserLive = true }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xl)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(Tint.subtle), lineWidth: 0.8))
            .padding(.horizontal, Spacing.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 引用回复条（发送后自动清除）
    @ViewBuilder
    private var quotedReplyBar: some View {
        if let q = quotedMessage {
            HStack(spacing: 8) {
                Image(systemName: "quote.opening")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(Color.accentColor)
                Text(String(q.content.prefix(60)))
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    quotedMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.md)
            .background(Color.accentColor.opacity(Tint.faint), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .padding(.horizontal, Spacing.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
    /// v3.9.17：AI 后端（Hermes）路径的工具进度卡（工具名由后端下发中文，App 不维护第二份映射表）。
    ///
    /// 为什么抽成独立 @ViewBuilder：messageList 那个 ViewBuilder 已经很深（ForEach + 滚动 + 长 if 链），
    /// 直接往里塞一个 ForEach 正是 v3.0.51 反复踩的「Unable to type-check this expression in
    /// reasonable time」形态 —— 本机 -parse 查不出，只在 CI Archive 报，一轮 ≈20 分钟。
    ///
    /// 会话门控：StreamClient 是 App 级单例（QingliaoApp 里 .environment(stream)），会话 A 在跑时
    /// 切到 B 不该显示 A 的工具卡 —— 与本仓本地流「按 currentStreamSessionId 收窄」的既定口径一致。
    @ViewBuilder
    private var toolStepCards: some View {
        // v3.9.80：门控改用 `toolSteps`（= max(toolSeq, toolNames.count)）——摘要行读的就是这个值，
        // 原先门控只认 toolNames，与显示口径脱节（toolSeq>0 但明细为空时整卡不渲染）。
        if stream.toolSteps > 0, auth.currentStreamSessionId == chat.sessionId {
            // 🚨 v4.0.48（启动闪退根治 ②）：这团工具卡（内嵌两层 TimelineView）是 LazyVStack 元组里
            //   第二深的元素（~9 层），同样做类型擦除；`.transition(.opacity)` 留在 AnyView **外面**，
            //   工具卡出现/收起时的淡入淡出语义不变（只让类型名变浅）。
            AnyView(VStack(alignment: .leading, spacing: 6) {
                // v3.9.27：生成中也可随时收起（用户反馈「不必等输出完才能收」）——
                // 统一走「摘要行 + expanded 控制明细」，不再按 isStreaming 强制展开。
                // v3.9.80：摘要行显示**实际步数**（后端 toolSeq 全量计数；toolNames 只下发最近 10 步，
                // 直接用它的 count 会把 10 步以上的任务一律显示成「10 步工具调用」——用户 2026-09-25 真机反馈）
                ToolStepsSummaryRow(count: stream.toolSteps,
                                    expanded: toolStepsExpanded) {
                    withAnimation(Motion.snap) { toolStepsExpanded.toggle() }   // v3.9.19：裸动画收口到令牌（原 .easeOut(0.18)）
                }
                // v3.9.81：摘要行下面固定一行进度小字（用户 2026-09-27 要求：任务中心的进度口径同步到聊天页）。
                // 收起/展开都显示——它才是"跑到哪了"的那一行。包在 TimelineView 里走秒：「静默 N 秒」
                // 不刷新会像卡死；只包这一行（摘要行与明细不受 1s tick 影响）。文案口径见 StreamProgressText。
                if stream.isStreaming {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        if let note = stream.progressNote {
                            ToolProgressNote(text: note)
                        }
                    }
                }
                if toolStepsExpanded {
                    // v3.9.58：TimelineView 每 1s 重算——running 行的「已等 Ns」需要走秒，
                    // 轮询 tick（0.15-0.8s 不定）驱动会让秒数跳变；只在展开明细时包住这一小段，
                    // collapsed 摘要行不受影响（零额外重建）。
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            // v3.9.80：明细若被裁（老后端只下发最近 10 步 / toolSeq 已计到尚未命名的步），
                            // 先明说「更早的没列出来」，否则摘要行写 17 步、明细只有 10 行，看着像丢了几步。
                            // 必须带 `!toolNames.isEmpty`：全空时这条会输出「只留最近 0 步」这种自相矛盾的文案。
                            if !stream.toolNames.isEmpty, stream.toolSteps > stream.toolNames.count {
                                ToolStepsTruncationNote(hidden: stream.toolSteps - stream.toolNames.count,
                                                        shown: stream.toolNames.count)
                            }
                            ForEach(Array(stream.toolNames.enumerated()), id: \.offset) { idx, name in
                                let isLast = idx == stream.toolNames.count - 1
                                ToolStepRow(title: name,
                                            running: stream.isStreaming && isLast,
                                            unresolved: !stream.isStreaming && !stream.errorMessage.isEmpty,
                                            duration: stream.stepDuration(at: idx),
                                            elapsed: (stream.isStreaming && isLast)
                                                ? stream.runningElapsed() : nil,
                                            // v3.9.58b：失败收尾的最后一步 → 带「重试」（重新生成该回复）
                                            onRetry: (!stream.isStreaming && isLast && !stream.errorMessage.isEmpty)
                                                ? { retryLastGeneration() } : nil)
                            }
                        }
                    }
                }
            })
            // v4.0.38：原此处是 `.padding(.horizontal, Spacing.xl)`（v4.0.31 注释「容器 6 + 12 = 18，
            // 与 AI 气泡左缘对齐」）—— 气泡内容侧贴边后外缘只剩列表左右 6pt，本块若继续自留 12
            // 就会比它所属的 AI 气泡多缩进一档（真机可见错位）。故不再自留白，工具卡外缘与气泡左缘齐平。
            .transition(.opacity)
        }
    }


    var body: some View {
        chatBodyChrome7(
        chatBodyChrome6(
        chatBodyChrome5(
        chatBodyChrome4(
        chatBodyChrome3(
        chatBodyChrome2(
        chatBodyChrome1(
            // v2.0.140：禁用系统键盘避让——ChatInputBar 已手动按 kb.topY 精确计算 bottom padding，
            // 系统默认避让叠加会双重上抬 → 输入框与键盘间留空隙（用户红线标注）。
            // 只保留手动控制，输入框精确贴键盘。
            VStack(spacing: 0) {
                chatHeaderBar
                chatStatusBannerStrip
                chatTranscriptArea
                // 🚨 v3.9.71 修复（用户截图报「输入法会遮住输入框」）：空态（欢迎页）在键盘弹起时把输入栏挤没了。
                //   算法：欢迎页是不可滚动的定高内容（顶部留白 56 + 智能球 96 + 文案 + 4 芯片 + 快捷卡片网格；
                //   v4.0.9 已删掉页脚那条「继续上次」长条卡 ≈ -64pt），
                //   九宫格键盘 + 候选栏 ≈ 340pt，屏幕 852 − 键盘 340 − 头部 110 − 输入栏 58 ≈ **只剩 344pt**。
                //   344 < 380 → VStack 压不动欢迎页，就只能把**输入栏挤到键盘后面**（截图即此）。
                //   layoutPriority(1)：空间不足时**先挤上面的内容区**，输入栏必须完整可见。
                //   配套：welcomeView 自己在键盘弹起时收缩（见那里的注释），否则会看到被截断的欢迎页。
                chatComposerArea
            }
        )))))))
    }

    /// v4.0.51：body 修饰器链第 1/7 段（顶层 6 个，纯搬运、顺序不变）。
    /// 拆段原因：链式修饰器 = 泛型嵌套层数；37 层会让运行时 demangle 递归
    /// 撞爆主线程 1MB 栈（实测 Crash 173 帧 + Stack Guard 命中）。
    private func chatBodyChrome1<V: View>(_ content: V) -> some View {
        content
        .animation(.easeOut(duration: kb.animationDuration), value: kb.height)
        // v2.0.96：语音授权/转写失败提示（v3.9.3：设备端识别——麦克风权限 / 机型不支持 / 识别中断）
        .background(chatColdChrome1())
        .background(chatColdChrome2())
    }

    /// v4.0.51：body 修饰器链第 2/7 段（顶层 5 个，纯搬运、顺序不变）。
    /// 拆段原因：链式修饰器 = 泛型嵌套层数；37 层会让运行时 demangle 递归
    /// 撞爆主线程 1MB 栈（实测 Crash 173 帧 + Stack Guard 命中）。
    private func chatBodyChrome2<V: View>(_ content: V) -> some View {
        content
        .background(chatColdChrome3())
        .background(chatColdChrome4())
    }

    /// v4.0.51：body 修饰器链第 3/7 段（顶层 5 个，纯搬运、顺序不变）。
    /// 拆段原因：链式修饰器 = 泛型嵌套层数；37 层会让运行时 demangle 递归
    /// 撞爆主线程 1MB 栈（实测 Crash 173 帧 + Stack Guard 命中）。
    private func chatBodyChrome3<V: View>(_ content: V) -> some View {
        content
        .background(chatColdChrome5())
        .background(chatColdChrome6())
    }

    /// v4.0.51：body 修饰器链第 4/7 段（顶层 5 个，纯搬运、顺序不变）。
    /// 拆段原因：链式修饰器 = 泛型嵌套层数；37 层会让运行时 demangle 递归
    /// 撞爆主线程 1MB 栈（实测 Crash 173 帧 + Stack Guard 命中）。
    private func chatBodyChrome4<V: View>(_ content: V) -> some View {
        content
        .background(chatColdChrome7())
        .background(chatColdChrome8())
    }

    /// v4.0.51：body 修饰器链第 5/7 段（顶层 5 个，纯搬运、顺序不变）。
    /// 拆段原因：链式修饰器 = 泛型嵌套层数；37 层会让运行时 demangle 递归
    /// 撞爆主线程 1MB 栈（实测 Crash 173 帧 + Stack Guard 命中）。
    private func chatBodyChrome5<V: View>(_ content: V) -> some View {
        content
        .background(chatColdChrome9())
        .background(chatColdChrome10())
    }

    /// v4.0.51：body 修饰器链第 6/7 段（顶层 5 个，纯搬运、顺序不变）。
    /// 拆段原因：链式修饰器 = 泛型嵌套层数；37 层会让运行时 demangle 递归
    /// 撞爆主线程 1MB 栈（实测 Crash 173 帧 + Stack Guard 命中）。
    private func chatBodyChrome6<V: View>(_ content: V) -> some View {
        content
        .overlay(alignment: .top) {
            if showArchiveHint {
            AnyView(archiveBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(20)
            )
            }
        }
        .background(chatColdChrome11())
    }

    /// v4.0.51：body 修饰器链第 7/7 段（顶层 6 个，纯搬运、顺序不变）。
    /// 拆段原因：链式修饰器 = 泛型嵌套层数；37 层会让运行时 demangle 递归
    /// 撞爆主线程 1MB 栈（实测 Crash 173 帧 + Stack Guard 命中）。
    private func chatBodyChrome7<V: View>(_ content: V) -> some View {
        content
        .background(chatColdChrome12())
        .background(chatColdChrome13())
        .background(chatColdChrome14())
        // v4.0.66 A+C 定稿：环境渐变页底——白/黑底上三团弥散光晕（桃粉右上/天蓝左侧/薄荷底部），
        // 挂在整页最底层（垫在所有 coldChrome 之下，消息区/输入区都透出彩底）；
        // 纯视觉层：不改布局、不拦手势（GlowBlob 全部 allowsHitTesting(false)）。
        .background(EnvironmentGlowLayers(scheme: colorSchemeEnv))
        // 🚨 v4.0.77：锚定弹出菜单挂在**整页最外层**（用户实报「三点菜单落到聊天内容页下面去了」）。
        // 这里是最外圈 —— 浮层压在消息列表/输入栏之上；锚点坐标是 .global，浮层自身满屏 → 换算即恒等。
        .overlay { chatAnchorMenuLayer }
    }

    /// v4.0.77：聊天页的两个锚定菜单浮层（三点操作菜单 / 思考档位）。
    /// 两者互斥（各自按钮点开时另一个必已被收起），同挂一处便于与其它页「对齐」——四个调用点
    /// 都用同一个 AnchorMenuOverlay（胶囊规格见该文件），这里只管挂载层级。
    @ViewBuilder
    private var chatAnchorMenuLayer: some View {
        // 思考档位：从输入栏档位胶囊处弹出、点空白收回
        if showReasoningPicker {
            AnchorMenuOverlay(anchorFrame: reasoningAnchor,
                              items: ReasoningLevel.allCases.map { lv in
                                  AnchorMenuItem(id: lv.rawValue,
                                                 title: "\(lv == reasoningLevel ? "✓ " : "")\(lv.title) · \(lv.detail)",
                                                 icon: lv.symbol,
                                                 color: lv == reasoningLevel ? .accentColor : .primary)
                              },
                              title: "模型思考档位",
                              onPick: { item in
                                  reasoningLevelRaw = item.id
                                  showReasoningPicker = false
                              },
                              onClose: { showReasoningPicker = false })
        }
        // 聊天操作菜单：从三点按钮处弹出、点空白收回
        if showMoreMenu {
            AnchorMenuOverlay(anchorFrame: moreMenuAnchor,
                              items: chatActionMenuItems,
                              title: "上下文：约 \(chat.contextInfo.tokens) tokens · \(chat.contextInfo.count) 条",
                              onPick: { handleChatActionMenuPick($0) },
                              onClose: { showMoreMenu = false })
        }
        // v4.0.81：长按气泡 → 锚定胶囊菜单（与三点菜单同一浮层组件、同一挂载点）
        if let t = bubbleMenuTarget {
            AnchorMenuOverlay(anchorFrame: t.anchor,
                              items: bubbleMenuItems(for: t.message, text: t.text),
                              title: t.message.isUser ? "你的消息" : "AI 回复",
                              onPick: { handleBubbleMenuPick($0, message: t.message, text: t.text) },
                              onClose: { bubbleMenuTarget = nil })
        }
    }

    /// v4.0.51c：行为型深层修饰器下沉背景层（.background 不影响布局）
    private func chatColdChrome1() -> some View {
        Color.clear
        .alert("语音转文字不可用", isPresented: $voiceAuthFailed) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("好的", role: .cancel) {}
        } message: {
            Text("需要麦克风权限才能语音转文字（设备端识别，录音不会上传）。\n请在「设置 → 轻聊 → 麦克风」里允许。")
        }
        // v3.9.3：非权限类的失败（语音模型下载失败 / 系统未给可用格式 / 识别中断）
        .alert("语音识别启动失败", isPresented: Binding(
            get: { !voiceError.isEmpty },
            set: { if !$0 { voiceError = "" } }
        )) {
            Button("好的", role: .cancel) { voiceError = "" }
        } message: {
            Text("\(voiceError)\n[诊断] \(voiceDiag)")
        }
        // v2.0.102：录音太短提示
        .alert("没有识别到内容", isPresented: $voiceTooShort) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("没有识别到内容，请靠近麦克风、按住说完一整句再松手。\n[诊断] \(voiceDiag)")
        }
        // v4.0.x：固定会话清空被拦提示
        .alert("无法清空", isPresented: Binding(
            get: { clearBlockedHint != nil },
            set: { if !$0 { clearBlockedHint = nil } })) {
            Button("好的", role: .cancel) { clearBlockedHint = nil }
        } message: {
            Text(clearBlockedHint ?? "")
        }
        // v2.0.102：AI 回答中发文件提示
    }

    /// v4.0.51c：行为型深层修饰器下沉背景层（.background 不影响布局）
    private func chatColdChrome2() -> some View {
        Color.clear
        .alert("AI 回答中", isPresented: $fileSendBlocked) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("AI 正在回答，稍等片刻再发送文件。")
        }
        // v3.3.0：流式中进入多选提示
    }

    /// v4.0.51c：行为型深层修饰器下沉背景层（.background 不影响布局）
    private func chatColdChrome3() -> some View {
        Color.clear
        .alert("AI 回答中", isPresented: $selectBlocked) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("AI 正在回答，回答完成后再多选合并。")
        }
        // v4.0.44 待做池 3：改口重答失败 → 明说「已还原」（用户刚改完就等新回答，不能静默）
        .alert("改口重答失败", isPresented: $editFailedAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("已把原来的回答还原回去（不留白）。原因：\(editFailedNote)")
        }
        // v3.9.31：文件预览下载失败提示——MEDIA: 指向的生成物多已被服务器清理，点卡片要有反馈
        .alert("文件已失效", isPresented: $fileGoneAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("该文件已不存在或无法下载（生成物可能已被服务器清理）。")
        }
        // v3.3.0：合并条数超限提示
        .alert("合并条数超限", isPresented: $mergeTooMany) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("最多合并 \(Self.maxMergeCount) 条，请减少勾选后再合并。")
        }
        // v2.0.61：杀后台流式恢复（幂等——无持久化任务时静默返回）
    }

    /// v4.0.51c：行为型深层修饰器下沉背景层（.background 不影响布局）
    private func chatColdChrome4() -> some View {
        Color.clear
        .task {
            await resumePersistedStream()
            // v3.9.58c：探测未完任务标记——标记归属**其他**会话时显示「继续上次任务」横幅
            // （归属当前会话的情形 resumePersistedStream 已直接自动接回，无需横幅）
            if !stream.isStreaming, pendingResumeInfo == nil {
                pendingResumeInfo = StreamClient.persistedTaskInfo()
            }
            // v3.5.1：AI 正在输入 探针（仅当有遗留任务标记时才发请求；服务器说没了就清标记收起状态）
            await busyProbeLoop()
        }
        // v3.9.6：实时转写同步进输入框 —— 不依赖「启动时存下来的闭包写 @State」，
        // 改用 SwiftUI 原生更新周期里写（liveSpeech.liveText 变化 → 必然走这里），松手定稿后框内即最终文本
    }

    /// v4.0.51c：行为型深层修饰器下沉背景层（.background 不影响布局）
    private func chatColdChrome5() -> some View {
        Color.clear
        .onChange(of: liveSpeech.liveText) { _, newValue in
            // v3.9.9：守卫与录音行同口径（voiceMode 或识别器在跑），否则会出现
            // "红点行有字、输入框里没字"的分裂状态
            guard voiceMode || liveSpeech.isRunning else { return }
            inputText = newValue
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        // v2.0.38：拍照输入（拍完进图片预览条，确认后发送）
        // v3.9.75：.sheet → .fullScreenCover。UIImagePickerController 的取景界面按「全屏」画自己的
        // 布局，落在 page-sheet 容器里顶部会露出一条不属于它的黑底。
        // v3.9.76：**还要 ignoresSafeArea**——只换呈现方式不够：fullScreenCover 的内容视图默认
        // 被约束在安全区内，取景层只铺满这个内缩矩形，顶部状态栏高度（≈59pt）露出的仍是黑底，
        // 就是用户报的「系统相机顶部有黑边」。相机 App 本身就是全屏取景，这里对齐它。
        // CameraPicker 的 Coordinator 自己 dismiss，换呈现方式不需要改回调。
        .fullScreenCover(isPresented: $showCameraPicker) {
            AnyView(CameraPicker { img in
                pendingImage = img
                pendingImageData = compressImage(img)
            }
            .ignoresSafeArea()
            )
        }
        // v2.0.43：快捷指令面板（点击填充输入框）
        .sheet(isPresented: $showQuickPrompts) {
            AnyView(QuickPromptSheet(onPick: { prompt in
                inputText = prompt
                showAttachmentMenu = false
            }, includeKB: true)   // v3.9.28：知识库恒显示（原按云端/本地分流，云端已移除）
            .presentationDetents([.medium, .large])
            )
        }
        // v2.0.96：Hermes 捷径面板（官方斜杠命令，点击填充输入框）
    }

    /// v4.0.51c：行为型深层修饰器下沉背景层（.background 不影响布局）
    /// v4.0.75：直播窗从 sheet 改成**消息流内嵌卡**（用户拍板「Muse 那种」选项 2）——
    /// 这里只剩发起面板（手动入口）一个 sheet；直播卡的呈现/收起都在 messageList 里，
    /// 由 browserLiveSession 驱动（点 × 置 nil 即收起，轮询随视图销毁自动停）。
    private func chatColdChrome14() -> some View {
        Color.clear
        // 发起面板（手动入口）
        .sheet(isPresented: $showBrowserLive) {
            AnyView(BrowserLivePromptView { site, url in
                showBrowserLive = false
                browserLiveSession = BrowserLiveSession(site: site, url: url, ts: Date())
            }
            .presentationDetents([.medium])
            )
        }
        // AI 报直播标记 / 手动发起 → 消息流里的直播卡出现（Center 是源、这里是镜像）。
        // 收起时只清本地镜像，Center 源由宿主 onClose 回调统一清（防重建重弹）。
        .onReceive(BrowserLiveCenter.shared.$activeSession) { s in
            if let s { browserLiveSession = s }
        }
        // 🚨 v4.0.77：首帧**补一次同步** —— 直播卡可能在聊天页不在前台时激活（移交后台的回复落地、
        // 推消息注入），那次发布本页可能没收到（或收到后视图重建又清掉）→ 回到聊天页只见正文不见卡。
        // 读一次 Center 源即可；源与镜像是同一份，不会覆盖刚手动发起的会话。
        .onAppear {
            if let s = BrowserLiveCenter.shared.activeSession { browserLiveSession = s }
        }
    }

    /// v4.0.75：收起消息流里的直播卡（点 ×）。镜像与 Center 源一起清，
    /// 同帧只动状态、不碰轮询——轮询挂在卡视图的 .task 上，视图移除自动取消。
    private func closeBrowserLive() {
        browserLiveSession = nil
        BrowserLiveCenter.shared.activeSession = nil
    }

    /// v4.0.51c：行为型深层修饰器下沉背景层（.background 不影响布局）
    private func chatColdChrome6() -> some View {
        Color.clear
        .sheet(isPresented: $showHermesShortcut) {
            AnyView(HermesShortcutSheet { cmd in
                inputText = cmd
                showAttachmentMenu = false
            }
            .presentationDetents([.medium, .large])
            .scrollContentBackground(.hidden)
            )
        }
        // v3.0.27：章节列表
    }

    /// v4.0.51c：行为型深层修饰器下沉背景层（.background 不影响布局）
    private func chatColdChrome7() -> some View {
        Color.clear
        .sheet(isPresented: $showTOCSheet) {
            AnyView(TOCSheet(headers: tocHeaders(), onNavigate: { item in
                // v3.9.41：按 TOCItem.msgIndex 定位（数据源已逐条抽取并打标，见 tocHeaders()）
                // —— 复用会话搜索的 highlightTarget 机制滚动 + 高亮
                guard item.msgIndex >= 0, item.msgIndex < chat.messages.count else { return }
                let target = chat.messages[item.msgIndex]
                chat.highlightTarget = (role: target.role, content: target.content)
                showTOCSheet = false
            })
            .presentationDetents([.medium])
            .scrollContentBackground(.hidden)
            )
        }
        // v3.9.32：定时提醒面板（长按气泡「提醒我」/ 设置页入口共用）
        .sheet(isPresented: $showQuickReminder) {
            AnyView(QuickReminderSheet(presetText: reminderSeedText)
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
            )
        }
        // v4.0.29：首页「备忘速记」卡 → 备忘卡片（复用生活页 MemoSection，弹窗里直接看/记）
        .sheet(isPresented: $showHomeMemoBrowser) {
            AnyView(NavigationStack {
                ScrollView {
                    MemoSection()
                        .padding(.horizontal, Spacing.section)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { showHomeMemoBrowser = false }
                    }
                }
            }
            .presentationDetents([.large])
            )
        }
        // v4.0.29：首页「云盘」卡 → 云盘浏览（复用设置页 CloudDriveSettingsSheet 的列表 + 浏览器）
        .sheet(isPresented: $showHomeCloudDrive) {
            AnyView(CloudDriveSettingsSheet()
                .presentationDetents([.large])
            )
        }
        // v3.9.48：输入栏展开态的模型快选（右下角胶囊）。detents 与 Hermes 捷径/章节列表同档
    }

    /// v4.0.51c：行为型深层修饰器下沉背景层（.background 不影响布局）
    private func chatColdChrome8() -> some View {
        Color.clear
        .sheet(isPresented: $showComposerModel) {
            AnyView(ComposerModelSheet()
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
            )
        }
        // v3.9.86：长回复阅读（长按气泡「全屏阅读」）。detents 与全站输入弹窗同档（medium/large）——
        // 沿用现有档位不新增宿主，大爆炸的 fullScreenCover 不动，避免 zoom 转场源 id 打架。
    }

    /// v4.0.51c：行为型深层修饰器下沉背景层（.background 不影响布局）
    private func chatColdChrome9() -> some View {
        Color.clear
        .sheet(item: $longReplyPayload) {
            payload in
            AnyView(LongReplySheet(payload: payload)
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
            )
        }
        // v4.0.44 待做池 3：改口面板（长按自己的最后一条消息「编辑」）。detents 与全站输入弹窗同档。
        .sheet(item: $editingMessage) {
            m in
            AnyView(MessageEditSheet(originalText: m.content) { newText in
                editMessage(m, newText: newText)
            }
            .presentationDetents([.medium, .large])
            .scrollContentBackground(.hidden)
            )
        }
        // v4.0.50 待做池⑦：图片圈注面板（选图 → 圈注 → 完成后烘焙进原图，再由既有图片链路发出）
        .sheet(isPresented: $showAnnotate) {
            if let img = pendingImage {
            AnyView(ImageAnnotateSheet(source: img, onDone: { out in
                    pendingImage = out
                    pendingImageData = compressImage(out)
                })
            )
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.data]) { result in
            if case .success(let url) = result {
                sendFile(url)
            }
        }
    }

    /// v4.0.51c：行为型深层修饰器下沉背景层（.background 不影响布局）
    private func chatColdChrome10() -> some View {
        Color.clear
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
    }

    /// v4.0.51c：行为型深层修饰器下沉背景层（.background 不影响布局）
    private func chatColdChrome11() -> some View {
        Color.clear
        .onChange(of: chat.messages.count) { _, newCount in
            // 超阈值（300 条）显示归档提示；回到阈值下自动隐藏
            withAnimation(Motion.settle) {   // v3.9.0：动效令牌收口（原 spring 0.3/0.1）
                showArchiveHint = newCount >= Self.archiveThreshold && !chat.messages.isEmpty
            }
        }
        // v3.4.14 系统分享收件消费：广播或 onAppear 兜底时，把 ShareRouter 里待处理的内容逐条发送
        .onReceive(NotificationCenter.default.publisher(for: .qingliaoShareIncoming)) { _ in
            drainShareInbox()
        }
        // v3.9.7 review 修复：灵动岛「停止生成」时，聊天页负责与输入栏停止**同一套**的清队列动作
        // （pendingQueue 是本视图的 @State，DockTabView 摸不到 → 由它发通知、这里清）
        .onReceive(NotificationCenter.default.publisher(for: LiveActivityActionBridge.clearPendingQueueNotification)) { _ in
            clearPendingQueue()
            // v3.9.9 收口：这条通知只由灵动岛「停止生成」发出 → 本轮残句不要自动朗读
            suppressAutoReadOnce = true
        }
        // v3.4.x 任务中心：点击任务「发送到当前会话」→ 把任务文本作为用户消息发送
        .onReceive(NotificationCenter.default.publisher(for: .qingliaoTaskSend)) { note in
            if let text = note.object as? String, !text.isEmpty {
                sendCore(text: text, imageData: nil)
            }
        }
        // v3.9.14：生活页备忘录「发给 AI」→ 同样作为用户消息发出（备忘立刻能变成行动）
        // v3.9.14：新一轮开始 → 工具卡回到默认收起态（否则上一轮手动展开会带到下一轮）
        // v4.0.x：观察只增的 `startSeq` 而不是 `isStreaming`——finish() 同帧续发会把 false→true 吞掉，
        // 上一轮展开的工具卡会带进新一轮（与 DockTabView 失败态清不掉是同型问题）。
    }

    /// v4.0.51c：行为型深层修饰器下沉背景层（.background 不影响布局）
    private func chatColdChrome12() -> some View {
        Color.clear
        .onChange(of: stream.startSeq) { _, _ in
            // v3.9.41：会话归属判定——A 起流不该把 B 里手动展开的工具卡收起来（该卡本来就按会话显示）
            if thisSessionStreaming { toolStepsExpanded = false }
            // v4.0.x（审查 TASK2 ②）：抑制标记复位也是**开跑语义**，与工具卡收起合并在同一处观察。
            // 它原来挂在 `aiBusy` 闭包里：排队自动续发时 aiBusy 走 true →（同帧 finish→start）→ true，
            // 边沿被吞、标记复位不了，会把续发那一轮的正常回答一起吞掉（正是 v3.9.9 想修的那个病，换了条路径）。
            // ⚠️ 不许再为它单独挂一个 `.onChange`：这条 body 修饰符链已经贴着 Swift 类型检查的阈值，
            // 多一个带闭包的成员就会 Archive 失败（`unable to type-check in reasonable time`，CI #608 实测）。
            suppressAutoReadOnce = false
            // v4.0.39：思考三点的浮现开关复位。**必须挂 startSeq 而不是 thisSessionStreaming**：
            // 排队自动续发时 finish()→start() 同帧（见上面注释），false→true 的边沿会被吞掉 →
            // 挂在 busy 翻转上的复位不执行 → 那一轮三点直接凭空显示（只有第一轮有上浮动画）。
            // startSeq 只增、每轮必变，是这仓认定的「开跑语义」唯一可靠信号。
            typingBorn = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .qingliaoMemoSend)) { note in
            if let text = note.object as? String, !text.isEmpty {
                // 与输入栏 send() 同口径：用户真的发起新一轮 → 先掐掉上一轮朗读，
                // 否则 AI 正念上一条时点「发给 AI」，旧朗读会一直念到新答案出完
                SpeechManager.shared.stop()
                sendCore(text: text, imageData: nil)
            }
        }
        // v3.9.59：长按 dock 智慧球「语音输入」——切页动画落定后进语音转文字（与输入框长按同一条
        // toggleVoiceMode 路径）。已在语音模式 → 视为再按一次 = 退出（toggle 自带该语义）；
        // 键盘多半没开 → keyboardWasUp: false 走「收键盘」分支，语义正确。
        // 延迟 0.35s：切页转场（Motion.snap 0.2s + 系统动画）还在跑时切 voiceMode，语音 UI 会被转场打断。
        .onReceive(NotificationCenter.default.publisher(for: .qingliaoOrbVoiceInput)) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.35))
                toggleVoiceMode(keyboardWasUp: kb.isVisible)
            }
        }
        // v3.9.79：长按快捷菜单弹出即收键盘（用户 2026-09-25：「这个界面自动收回键盘」）。
        // 收法与语音模式**同一口径**（见 ChatViewVoice.toggleVoiceMode）：先清 FocusState 让输入栏缩回第一层，
        // 再延迟 60ms 用 UIKit 强制 resignFirstResponder 兜底 —— iOS 27 在触摸聚焦动画中可能覆盖 FocusState 的修改。
        // 菜单关闭后**不自动弹回**（用户点输入框才回来）：菜单是模态层，弹回键盘会和胶囊抢下半屏。
        .onReceive(NotificationCenter.default.publisher(for: .qingliaoDismissKeyboard)) { _ in
            inputFocus = false
            Task {
                try? await Task.sleep(for: .seconds(0.06))
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
            }
        }
        // v4.0.x 会话纪要：纪要页整理完把卡片文本发过来 → 按记账卡同一路径插一张本地卡
        // （object = 卡片文本；卡已由 MinutesKit 组装好，这里只负责落进当前会话）
    }

    /// v4.0.51c：行为型深层修饰器下沉背景层（.background 不影响布局）
    private func chatColdChrome13() -> some View {
        Color.clear
        .onReceive(NotificationCenter.default.publisher(for: .qingliaoMinutesCard)) { note in
            if let card = note.object as? String, !card.isEmpty {
                insertMinutesCard(card)
            }
        }
        .onAppear {
            drainShareInbox()
            // v3.4.x 发送可靠性：启动恢复上次未发出的排队消息（杀 App/断网重启不丢）→ 立即补发
            // v3.9.41（SR60）：这段收进 restorePendingQueue() + pumpPendingQueue()。原实现三处都会吃消息：
            // ①无脑拿队首——队首属于别的会话时，在当前会话里找不到那一行 → 静默丢；
            // ②restore 读完立刻删盘上的键——第 2..n 条只剩内存一份，之后任何一次切会话都没了；
            // ③匹配条件写死 `queued`，而 queued 从不落盘 → 重启后历史里没有任何 queued 行，永远匹配不上。
            restorePendingQueue()
            pumpPendingQueue()
        }
    }

    // MARK: - 巨型 body 拆分（纯搬运）
    //
    // 由头：此 body 单块 263 行，是本仓已踩过两次的「Unable to type-check this
    // expression in reasonable time」高危形态（一次漏检 = 20 分钟 CI 循环）。
    // v4.0.51 追加：链式修饰符 = SwiftUI 泛型嵌套层数，运行时 demangle 需按层递归；
    //   37 层链实测把主线程 1MB 栈撞爆（IPS：Stack Guard 命中 + 173 帧全在 decodeMangledType）。
    //   那 188 行链已按 ≤6 个/段搬进上方 chatBodyChrome1…7 —— **纯搬运**：顺序逐字未变。
    // 这里按原注释分段把视图块原样搬成独立 @ViewBuilder 属性 —— **纯搬运**：视图顺序、
    // 层级、条件分支、闭包、修饰符逐字未变，渲染结果与拆分前一致，只为把类型检查表达式打小。

    /// v4.0.31：聊天页 header 正中的宠物（v4.0.28 删除后按新规格回归；用户拍板 2A）——
    ///   **AI 忙** = `.thinking` + 困倦脸 + 托腮（方案 A：thinkingFaceOverride=.sleepy，托腮由 PetAvatar 内 onChange 驱动）
    ///   **空闲** = `.idle`（呼吸、眨眼、随机微动作）
    ///   **回答完成** = `celebrateTrigger` +1 → 庆祝动作（欢呼/比心/鼓掌/挥手随机）+ 开心脸（方案 A：celebrateFace=.happy，播完回落）
    ///   **出错** = `.alert` + 默认脸 + 张望一次（方案 A：alertFaceOverride=.calm，张望由 PetAvatar 内驱动）
    /// 60pt（v4.0.36 用户改规格，此前 62pt 是当年三档对比选定值）；v4.0.32 起加 keepDetail
    /// 旁路简化阈值——60 < 76 本会被画成「头+眼+嘴」（真机报修「header 宠物没有手」），现在完整细节照常画，
    /// 省电靠 state 映射（idle 只呼吸+眨眼+偶发微动作，无逐帧常驻）。
    /// 交互与欢迎页那只完全同款（拍板 2A）：轻点抚摸+聚焦输入框 / 长按快捷菜单（手势挂 overlay 命中层）。
    private var petHeaderBadge: some View {
        PetAvatar(size: 60,
                  state: aiBusy ? .thinking : (headerPetError ? .alert : .idle),
                  patTrigger: petPat,
                  celebrateTrigger: petCelebrate,
                  keepDetail: true,
                  thinkingFaceOverride: .sleepy,
                  alertFaceOverride: .calm,
                  celebrateFace: .happy)
    }

    /// v4.0.31：header 宠物的出错信号 —— 本会话这轮生成失败（非可重试错误），与欢迎页 alert 同源判定
    private var headerPetError: Bool {
        !aiBusy && generationFailed
    }

    /// v4.0.81：返回「会话列表」的圆形玻璃按钮（与 header 里其它胶囊同材质；只在合并首页宿主里出现）
    private var chatBackButton: some View {
        Button {
            Haptics.tap()
            onBackToHome?()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: Typography.body, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("返回会话列表")
    }

    /// 页头 + 思考档位/聊天操作弹窗 + 任务中心全屏页
    @ViewBuilder
    private var chatHeaderBar: some View {
        PageHeader(title: "聊天",
                   subtitle: headerSubtitle,
                   trailing: AnyView(headerTrailingItems),
                   // v4.0.81：返回会话列表（合并「聊天」tab 后从对话回首页的唯一入口；nil 即不渲染）
                   leading: onBackToHome == nil ? nil : AnyView(chatBackButton),
                   // v4.0.68：设置里可整体关掉（`petHeaderOn`）—— 关掉 = 这一格不渲染、
                   // header 回到「没有 centerView」的原样（与空会话态同一形态，不留空占位）。
                   centerView: (petHeaderOn && !chat.messages.isEmpty) ? AnyView(chatHeaderPet) : nil,
                   showStatus: true,
                   statusColor: headerColor,
                   busy: aiBusy)
        // v4.0.31：本会话这轮回答结束（忙→闲）→ 庆祝动作（v4.0.27 口径回归）。
        // 用 thisSessionStreaming 而不是 aiBusy：别会话跑完不该庆祝（原注释同）。
        .onChange(of: thisSessionStreaming) { was, now in
            if was && !now { petCelebrate += 1 }
        }
        // 🚨 v4.0.77（用户实报「三点菜单弹出落到聊天内容页下面去了」）：两个锚定浮层**从 header 挪走**。
        // 原来挂在本 header 上 —— header 是 body 那个 VStack 的**第一行**，`.overlay` 的层序跟同级兄弟一致：
        // 后画的兄弟（消息列表 / 输入栏）压在上面 → 菜单被聊天内容盖住。
        // 现在统一挂到整页最外层（chatBodyChrome7 的 .overlay，见 chatAnchorMenuLayer）。
        // v3.4.24：任务中心全屏页（header 三个点旁的常驻入口）
        .fullScreenCover(isPresented: $showTaskCenter) {
            TaskCenterView()
        }
    }

    /// 已送达提示 + 剪贴板地图提示条
    @ViewBuilder
    private var chatStatusBannerStrip: some View {
        if sentOK {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.green)
                Text("已送达 · 消息已发出")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.green)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xs)
            .transition(.opacity)
        }
        // v3.7.0：剪贴板地图链接提示条（in-flow，不遮挡 header、不拦截消息区滚动）
        if showClipboardBanner {
            mapClipboardBanner()
        }
        // v3.9.71：剪贴板里的普通链接 → 「识别」提示（点按才读内容，避免系统「允许粘贴」打扰）
        if showIntentClipboardBanner {
            intentClipboardBanner()
        }
        // v3.9.58：流式健康度提示——弱网退避/断网等恢复不再静默（之前用户只觉得"卡住了"）。
        // 只在本会话正在流式时显示；随相位出现/消失带透明过渡。
        if stream.isStreaming, auth.currentStreamSessionId == chat.sessionId,
           stream.phase != .normal {
            HStack(spacing: Spacing.xs) {
                Image(systemName: stream.phase == .waitingNetwork ? "wifi.slash" : "arrow.triangle.2.circlepath")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.orange)
                Text(stream.phase == .waitingNetwork ? "网络断开 · 恢复后继续" : "网络不稳 · 自动重试中")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xxs)
            .transition(.opacity)
        }
        // v3.9.58c：「继续上次任务」横幅——有未完任务标记但归属别的会话（自动恢复跳过）时出现。
        // 点「切换过去」跳到那个会话（切会话后自动恢复链路自然会接上）；点「放弃」清标记。
        if let info = pendingResumeInfo, info.sessionId != chat.sessionId, !stream.isStreaming {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.orange)
                Text("上次有任务没跑完（\(info.ageMinutes) 分钟前）")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    // v3.9.58c：按 id 拉会话并切换；切过去后恢复链路自动接上在途任务
                    let sid = info.sessionId
                    pendingResumeInfo = nil
                    Task {
                        let ok = await chat.loadById(sid, auth: auth)
                        // v4.0.15：切进会话即视为已读 —— syncUnread 的循环 guard s.id != currentId
                        // 会跳过当前会话，红点只能靠 markRead 熄灭；漏调就是永久红点。
                        // 用 lastLoadedSession 而不是重拉列表：ChatStore 不持有 sessions 列表
                        // （那是 SessionsView 的 @State），loadById→load 已把它写好。
                        if ok, let lt = chat.lastLoadedSession?.lastTime {
                            chat.markRead(sid, upTo: lt)
                        }
                        if !ok {
                            // 会话已删/拉不到 → 标记已无意义，清掉并提示
                            StreamClient.discardPersistedTask()
                            Haptics.error()
                        }
                    }
                } label: {
                    // v3.9.73：补回全站口径——本行是 v3.9.58 新加时漏走口径的回归（唯独这里还是实色 accent 胶囊，
                    // 而 v3.9.36 已把全站 accent 操作胶囊统一成玻璃底 + accent 0.28/0.8pt 描边 `glassPillStroke()`）。
                    // ⚠️ 别把它标成 v3.9.72：那一版当时已出包（源里已有同号包，重发同号用户端收不到更新）。
                    Text("继续")
                        .font(.system(size: Typography.caption, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.xxs)
                        .glassPillStroke()
                }
                .buttonStyle(PressStyle())
                Button {
                    StreamClient.discardPersistedTask()
                    pendingResumeInfo = nil
                } label: {
                    Text("放弃")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, Spacing.xxs)
            .transition(.opacity)
        }
    }

    /// v3.4.26 续聊芯片条 + 消息区（含停止录音/收件箱覆盖层）
    ///
    /// v3.9.95（用户拍板）：**去掉「继续话题 / 总结对话 / 有疑问」三颗续聊胶囊**。
    /// 原来它在 header 下方常驻（非空会话+非流式即显示），属于历史包袱：
    /// 三颗都是**万能话术**，点一下就发一条没信息量的指令，AI 只能机械回「回顾/总结/请提问」，
    /// 还占掉消息区顶部一行、并让流式开始/结束时整条跳一下（插拔视图）。
    /// 现在话题延续交给长按球的「AI 识别 + 语音对话胶囊」和空会话的欢迎芯片。
    /// `welcomeSuggestions` 里的续聊分支、`continueChipsBar` 视图与调用点一并删除（无残留死代码）。
    @ViewBuilder
    private var chatTranscriptArea: some View {
        messageList
            // v4.0.64（用户 2026-10-05 真机复测第 2 条「聊天页的滚边玻璃也取消」）：
            // iOS 26 起 ScrollView / List 会自动带「滚动边缘效果」（内容滚到边缘被**模糊 + 变暗**，
            // 见 Apple `scrollEdgeEffectHidden(_:for:)` 文档原文 "content to be blurred and dimmed
            // so that it works better next to surrounding UI controls such as the status bar or a
            // tab bar"）—— 这正是用户在聊天页看到的「滚边玻璃」。本页消息区关掉它。
            // 会话页同类处理见 SessionsView.sessionsListBody（同一批、同一口径）。
            // ⚠️ 只关会话页 + 聊天页（用户口径）；看板 / 生活两页的页头 safeAreaBar 原样保留。
            .scrollEdgeEffectHidden(true)
            .overlay {
                // v3.0.79：点按空白处停止录音（exitVoiceMode 注释原本就写"按钮/空白点击共用"，此处补上空白点击）
                // v3.9.6：整个消息区（含底部空白）都是停止面；输入栏区域不拦（不是"空白处"）
                if voiceMode && liveSpeech.isRunning {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { exitVoiceMode() }
                }
            }
            .overlay(alignment: .bottom) {
                // v3.4.0：底部上拉拉取收件箱——拖动指示器 / 拉取中 spinner / 结果 toast
                InboxPullLayer(state: inboxPull)
            }
    }

    /// 图片预览条/附件面板/引用条/上下文条 + 输入区
    @ViewBuilder
    private var chatComposerArea: some View {
        // v3.0.77：移除 v3.0.36 分段流式（边说边出字实时显示）——改回整段录音一次转写
        // 图片预览条（选图后显示）
        pendingImageBar
        // v3.9.71：识别结果动作条（挂在输入栏**之外**，输入栏那套两层结构一律不碰）
        intentActionBarSlot
        // v4.0.x：一句话记账的「已记账 + 撤销」条（同一套定位口径，见 ChatRecordBar 头注释：
        // 撤销按钮放不进卡片里，所以它落在卡片下方这一条上；卡片 footer 只指路）
        chatRecordBarSlot
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
        // v3.9.68：用户原话「发送键上下到输入框都等高，所以底部要再往上收一点」——底部呼吸
        // 由 Spacing.lg(10) 收到 **Spacing.xs(4)**（收起贴 dock / 弹键盘都收紧 6pt）。
        // ⚠️ 只动这一个数：输入栏自身高度（v3.9.67 起 50）、水平 padding 都不动。
        .padding(.bottom, Spacing.xs)   // v3.0.67 起留隙口径不变，仅收紧数值；见上一行 v3.9.68 记录
        // 🚨 v3.9.72（审查修正）：`layoutPriority(1)` 只挂**输入栏这一层**，不挂整个 chatComposerArea。
        // 整组里还有选图条/动作条/附件面板/引用条/上下文条（各自定高，合计 ≈380pt）：把整组抬到最高
        // 优先 = 键盘与动作条同开时输入栏本身仍会被顶出可见区，且空态欢迎页（非 ScrollView）被压到
        // 溢出盖住输入栏。要保护的是「输入栏必须完整可见」，不是那些浮条。
        .layoutPriority(1)
    }

    // MARK: - v3.7.0 剪贴板地图链接（地图分享兜底）
    /// 探测剪贴板是否有**位置链接** → 顶部胶囊提示（detection API 不读内容、无系统粘贴弹窗）
    /// v3.8.1 修复：① 只认「能被 MapLocationParser 认成位置」的链接，不再"有内容就提示"；
    ///             ② 已处理版本号跨启动保留，同一份内容不再每次进 App 都提示。


    private func checkMapClipboard() async {
        guard !showClipboardBanner, !showIntentClipboardBanner else { return }
        // v3.9.1：先取本版号——探测是 await（有窗口期），期间用户换了剪贴板内容时不能把"新内容"记成已处理
        let cc = UIPasteboard.general.changeCount
        // 🚨 v3.9.72 修复（用户：剪切板有内容不要每次进 App 都提示）：门换成 `decide`——比的是
        // "和上次进 App 时看到的那一版"，不是"和上次处理过的那一版"。旧门有两个漏斗：
        //   ① 用户从没点过「忽略/发给 AI」→ 没有处理记录 → 每次进 App 都重弹；
        //   ② 中途设备重启 → isHandled 的 uptime 校验作废记录 → 同一份内容又弹一遍。
        // 现在：内容没变 → 直接静默返回，一次都不打扰；内容真变了（在别的 App 拷了东西再切回来，
        // 也就是地图分享兜底那套流程）→ 才往下探。
        guard ClipboardPromptGate.decide(changeCount: cc, lastSeenChange: lastSeenClipChange) == .probe else { return }
        // 🚨 v3.9.76 修复（用户：「剪贴板内容识别现在连第一次都不弹窗了」）：两个探测器**必须彼此独立**。
        // 旧写法是「guard let isLocation = await MapClipboardDetector.hasLocationLink() else { return }」——
        // 位置探测**一失败（nil）就整条链放弃**，于是位置那一层在真机抛错时，会把后面「普通链接」
        // 的提示也一起吞掉，表现就是"永远不弹"（而且因为连探都没探到链接层，用户完全看不出原因）。
        // 现在：位置探测失败只当"不是位置链接"，继续往下走链接探测。
        let isLocation = await MapClipboardDetector.hasLocationLink()
        if isLocation == true {
            lastSeenClipChange = cc       // v3.9.72：这一版"看过了"（唯一真值源）
            withAnimation(Motion.settle) { showClipboardBanner = true }   // 只提示；真正内容等点按再读
            scheduleClipboardAutoHide()   // v3.9.72：一段时间没操作自动收起
            return
        }
        // v3.9.76（用户拍板「1」放开）：不是位置链接 → 再看本地能识别的**结构化类型**
        // （链接 / 地址 / 联系方式 / 金额 / 快递单号 / 时间），任一类命中就弹条问一句。
        // 仍然只用 detection API：不读内容、不弹系统「允许粘贴」。
        // 探测是**三态**（命中集合 / 空集 / nil=失败）——失败**不记账**（保持"下次进前台再探"），
        // 别退回 `== true` 那种把 nil 和 false 一起吞掉的写法（v3.9.71 审查踩过一次）。
        guard let hits = await ClipboardIntentDetector.recognizableHits() else { return }   // 失败不记账
        // v3.9.72：不管认没认出来，这一版都记成"看过了"——没有可识别内容的剪贴板不再每次进 App 重探
        lastSeenClipChange = cc
        guard hits.any else { return }
        clipboardIntentLabel = hits.label
        withAnimation(Motion.settle) { showIntentClipboardBanner = true }
        scheduleClipboardAutoHide()   // v3.9.72：一段时间没操作自动收起
    }

    /// v3.9.72（用户：提示一段时间没操作就自动隐藏）：弹出后挂一个定时，到点自动收起。
    /// 任何交互（点识别 / 点忽略）都会 cancel 它 —— 用户接管后就不该再由定时器抢着关。
    private func scheduleClipboardAutoHide() {
        clipboardAutoHide?.cancel()
        clipboardAutoHide = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(ClipboardBanner.autoHideSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.snap) {
                showClipboardBanner = false
                showIntentClipboardBanner = false
            }
        }
    }

    /// 用户有交互 → 取销自动收起（提示条归用户控制）
    private func cancelClipboardAutoHide() { clipboardAutoHide?.cancel() }

    /// 顶部胶囊：检测到剪贴板里有链接（多为地图分享的「拷贝」）
    @ViewBuilder
    private func mapClipboardBanner() -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("检测到剪贴板里的位置/链接")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                cancelClipboardAutoHide()
                sendClipboardLink()
            } label: {
                Text("发给 AI")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.xs)
                    .glassPillStroke()
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(Color.accentColor)
            // v3.9.86：忽略改成文字胶囊（与「识别」同款 pill，次级色；与识别版提示统一口径）
            Button {
                cancelClipboardAutoHide()
                // v3.9.72：这一版在探测时已记成"看过"，点忽略只需收起
                withAnimation(Motion.snap) { showClipboardBanner = false }
            } label: {
                Text("忽略")
                    .font(.system(size: Typography.subhead))
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.xs)
                    .glassPillStroke()
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        // v4.0.61：悬浮提示条改走原生玻璃出口（原描边逐字搬进出口参数）
        .a11yGlass(.regular, in: Capsule(), stroke: Color.primary.opacity(Tint.faint))
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xxs)
        .padding(.bottom, Spacing.xxs)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// v3.9.71：剪贴板里有链接 → 一键识别（几何口径与 mapClipboardBanner 逐项一致）
    @ViewBuilder
    private func intentClipboardBanner() -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            // v3.9.76：口径放开后文案不能写死"链接"（现在也可能是地址/金额/快递单号/时间…）
            Text(clipboardIntentLabel.isEmpty ? "检测到剪贴板里可识别的内容"
                                              : "检测到剪贴板里的" + clipboardIntentLabel)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                cancelClipboardAutoHide()
                runIntentFromClipboard()
            } label: {
                Text("识别")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.xs)
                    .glassPillStroke()
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(Color.accentColor)
            // v3.9.86：忽略改成文字胶囊（原 xmark 太小不好点，用户 2026-09-26 拍板）
            Button {
                cancelClipboardAutoHide()
                // v3.9.72：同上，记账已在探测时完成
                withAnimation(Motion.snap) { showIntentClipboardBanner = false }
            } label: {
                Text("忽略")
                    .font(.system(size: Typography.subhead))
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.xs)
                    .glassPillStroke()
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        // v4.0.61：悬浮提示条改走原生玻璃出口（原描边逐字搬进出口参数）
        .a11yGlass(.regular, in: Capsule(), stroke: Color.primary.opacity(Tint.faint))
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xxs)
        .padding(.bottom, Spacing.xxs)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// v3.9.71：识别结果动作条槽位（无结果时整块不占位）
    @ViewBuilder
    private var intentActionBarSlot: some View {
        if let result = intentResult {
            IntentActionBar(intent: result,
                            onAskAI: { text in
                                intentResult = nil
                                sendCore(text: text, imageData: nil)
                            },
                            onClose: { intentResult = nil })
                .padding(.horizontal, Spacing.xs)
                .padding(.bottom, Spacing.xs)
        } else if intentNoContentHint {
            // 图里没认出内容：必须出声（本批自己定的口径「失败必出声」，静默=用户以为按钮坏了）
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: Typography.subhead))
                Text(intentNoContentHintText)
                    .font(.system(size: Typography.subhead))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xs)
            .transition(.opacity)
        }
    }

    /// v4.0.x：一句话记账动作条槽位（没记过账时整块不占位）
    ///
    /// 位置口径与 intentActionBarSlot 完全一致（挂在输入栏之外、同一组内外边距）——
    /// 两条同时出现时上下叠着，视觉上是同一类「刚发生的事，可以撤」条。
    ///
    /// 🚨 v4.0.x 修：「这句 10 分钟内已记过」的提示原来也走 `flashNoContent`（复用
    /// intentNoContentHint），而渲染它的槽位是 `if intentResult … else if intentNoContentHint …`
    /// → 只要意图动作条还挂着，这条提示**一个字都不显示**，用户看到的是
    /// 「说了两遍，第二遍既没记账也没提示」。所以去重提示单独走 recordDedupNotice，
    /// 与 intentResult 平级，谁也盖不住谁。
    @ViewBuilder
    private var chatRecordBarSlot: some View {
        if let entry = chatRecordEntry {
            ChatRecordBar(item: entry.item,
                          category: entry.category,
                          batchCount: entry.extraItems.count + 1,
                          batchTotal: ([entry.item] + entry.extraItems).reduce(0) { $0 + ($1.amount ?? 0) },
                          onRecategorize: { recategorizeLanded(entry, $0) },
                          onUndo: { undoLandedExpense(entry) },
                          onClose: { withAnimation(Motion.settle) { chatRecordEntry = nil } })
                .padding(.horizontal, Spacing.xs)
                .padding(.bottom, Spacing.xs)
        } else if recordDedupNotice {
            // 候选池⑯：这条提示从「死文字」升级为**可点** —— 点开摊出被挡下的那一笔。
            // 为什么要能点：用户看到「已记过」第一反应是「哪一笔？」，指不到就只好去生活页翻。
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Button(action: toggleDedupDetail) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: Typography.subhead))
                        Text("这句 \(Int(ChatRecordKit.repeatWindow / 60)) 分钟内已记过，没重复记账")
                            .font(.system(size: Typography.subhead))
                        Spacer(minLength: 0)
                        if dedupItem != nil {
                            Text(dedupExpanded ? "收起" : "看这一笔")
                                .font(.system(size: Typography.caption))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dedupItem == nil ? "已记过提示"
                                                     : (dedupExpanded ? "收起那一笔的详情" : "查看被去重挡下的那一笔"))
                if let d = dedupItem, dedupExpanded {
                    dedupDetailRow(d)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Spacing.xs)
            .transition(.opacity)
        } else if !stream.memoAdded.isEmpty {
            // v4.0.120：AI「记住瞬间」提示条。判据直接读 stream.memoAdded（@Observable，
            // 写入自动触发刷新）——**不另挂 .onChange**：本 body 修饰符链已贴着 Swift 类型检查
            // 阈值，多一个带闭包的成员就会 Archive 失败（CI #608 实测，见 startSeq 处注释）。
            // 12 秒自动收尾放在 ChatMemoBar 自己的 .task 里，不占宿主的链。
            ChatMemoBar(texts: stream.memoAdded,
                        onUndo: { undoMemo(stream.memoAdded) },
                        onClose: { stream.forgetMemo(stream.memoAdded) })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if !pendingQueueRows.isEmpty {
            // 待做池⑥：弱网/多会话「队列总览」——排队消息逐条带序号（在等什么、排第几）。
            // 与上面几条**同一槽位、互斥**（记账条 / 去重条 / 记忆条 / 队列条只显示一个）。
            SendQueueBar(rows: pendingQueueRows, onClearAll: { clearPendingQueue() })
                // v4.0.69（用户 2026-10-07：「待发弹窗卡片贴到输入框顶了，留点间距」）：
                // 同槽的记账条（见本枚举上面 ChatRecordBar 调用点）带 `.padding(.bottom, Spacing.xs)`，
                // 队列条漏了 → 卡底直接贴输入框。补齐同一档间距（口径单源：与记账条一致，别各写各的值）。
                .padding(.bottom, Spacing.xs)
        }
    }

    /// 待做池⑥：当前会话的排队消息 → 带序号的展示行（口径在 `Core/SendQueueOverview.swift`）。
    private var pendingQueueRows: [SendQueueOverview.Row] {
        SendQueueOverview.rows(pendingQueue, sessionId: chat.sessionId)
    }

    /// v4.0.120：一键撤销 = 真删。调 /api/memory/delete 删掉刚记住的条目。
    /// 🚨 删除失败必须可见（v3.9.41 同款教训：try? 吞错 → 记忆「看着删了」重开又回来），
    /// 失败时保留提示条（不清 memoAdded）并震动，不假装撤销成功。
    private func undoMemo(_ texts: [String]) {
        Task {
            // v4.0.15：逐条删中途失败时，**已删成功的那几条必须先从提示条里摘掉**。
            // 否则用户再点「撤销」会对早就不存在的条目再发一次 delete，失败点永远停在
            // 同一条上 → 提示条再也撤不掉（每点一次都失败）。
            var deleted: [String] = []
            for t in texts {
                guard let j = try? await auth.json("/api/memory/delete", method: "POST",
                                                   body: ["text": t]),
                      (j["ok"] as? Bool) == true else {
                    Haptics.error()
                    if !deleted.isEmpty { stream.forgetMemo(deleted) }   // 已生效的先摘
                    return   // 剩余条目保留提示条，请用户到记忆页手动删——不静默吞掉
                }
                deleted.append(t)
            }
            // 全部删成功才摘掉提示条（forgetMemo 同时清本流列表，避免同一流后续重弹）
            Haptics.success()
            stream.forgetMemo(texts)
        }
    }

    /// 一句话记账的「已记过」去重提示（与意图动作条平级的独立位，2.4 秒后自动收）
    private func flashRecordDedup(itemID: String? = nil) {
        // 候选池⑯：能查到就是「哪一笔」，查不到（条目已被删掉）就退回纯提示，不假装能点
        dedupItem = itemID.flatMap { id in
            RecordStore.shared.records.first { $0.id == id }
        }
        dedupExpanded = false
        Haptics.error()
        withAnimation(Motion.settle) { recordDedupNotice = true }
        dedupNoticeTask?.cancel()
        dedupNoticeTask = Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.settle) { recordDedupNotice = false }
        }
    }

    /// v4.0.x 一句话记账：把「买菜 86」这类短句记成一笔 + 在会话里插一张记账卡（口径 1a）。
    ///
    /// 为什么挂在 sendCore：它是全 App **唯一的发送收口**（发送 / 排队 / 问 AI / 继续下一步都走它），
    /// 挂这一个点就能覆盖各条发送分支，不必在每个入口各抄一遍识别。
    ///
    /// 三件事的落点：
    ///   ① 写入 → RecordStore.addExpense（source=chat，生活页「本月合计 / 最近记录」立刻能看到）
    ///   ② 卡片 → 会话里的 assistant + **isPush** 消息，内容是 ```ql-card 围栏，由既有
    ///      AgentCardParser → AgentResultCard 渲染（**不新造第二套渲染体系**）。
    ///      isPush 的两个作用都必要：留在会话展示、但 ChatStore.historyPayload 会滤掉它
    ///      → 卡片 JSON **不进模型上下文**（不会污染对话、不会被复读），跨重启也保留
    ///      （messagesPayload 写 isPush、ChatMessage.parse 读回）。代价：气泡上会带「🔔 推送」角标
    ///      （bubblePushTag 只看 isPush，不区分来源）——要改得动 ChatMessageBubble.swift，不在本轮范围。
    ///   ③ 确认 → 用户那句话**照旧发给 AI**（这里不拦发送），AI 的回话就是对话层面的确认；
    ///      卡片本身是「账已落库」的权威确认。
    private func noteChatExpenseIfMatched(text: String, imageData: String?) {
        guard imageData == nil else { return }              // 带图/纯图不记账
        guard !chat.isDeliverySession else { return }       // 投递会话是只读视图：不许往里写卡、记账号
        let sig = ChatRecordKit.signature(sessionId: chat.sessionId, text: text)
        let now = Date().timeIntervalSince1970
        if let last = chatRecordSignatures[sig], now - last < ChatRecordKit.repeatWindow {
            // ❌ 不能静默 return：用户看到的是「同一句话说了两遍，第二遍没记账」——像功能坏了。
            // 出声说明「已记过、没重复记」，并指路撤销入口（账本在生活页）。
            flashRecordDedup(itemID: chatRecordItems[sig])
            return
        }
        let drafts = ChatRecordKit.batchDrafts(from: text)
        guard !drafts.isEmpty else { return }
        var added: [(item: RecordItem, inserted: Bool)] = []
        for d in drafts {
            if let a = RecordStore.shared.addExpense(d) { added.append(a) }
        }
        guard let first = added.first else { return }
        chatRecordSignatures[sig] = now
        chatRecordItems[sig] = first.item.id
        // 表别无限长（一页聊天里可能记很多笔）：顺手清掉过窗口的老条目
        if chatRecordSignatures.count > 40 {
            chatRecordSignatures = chatRecordSignatures.filter { now - $0.value < ChatRecordKit.repeatWindow }
            chatRecordItems = chatRecordItems.filter { chatRecordSignatures[$0.key] != nil }
        }
        // Store 的 2 秒连点护栏命中时返回的是**已存在**那条（inserted=false）→ 不再插第二张卡、
        // 也不撤旧条（撤了会把几分钟前那笔的提示顶掉）
        guard first.inserted else {
            // 2 秒连点护栏命中：已存在那一笔、没插新卡 —— 静默 = 用户以为没记上
            flashRecordDedup(itemID: first.item.id)
            return
        }
        // 单笔走原卡（口径不变）；多笔走批量卡（一张卡列全，撤销仍是一次全撤）
        let card: String
        if drafts.count == 1 {
            card = ChatRecordKit.cardText(title: first.item.title,
                                          amount: first.item.amount ?? drafts[0].amount,
                                          unit: drafts[0].unit,
                                          category: drafts[0].category,
                                          raw: drafts[0].raw,
                                          isIncome: drafts[0].isIncome)
        } else {
            card = ChatRecordKit.batchCardText(drafts)
        }
        var msg = ChatMessage.local(role: "assistant", content: card)
        msg.isPush = true
        chat.append(msg)      // append 内部带 Motion.enter；count/lastID 变化会触发 refreshVisibleMessages
        withAnimation(Motion.settle) {
            chatRecordEntry = ChatRecordEntry(item: first.item, category: drafts[0].category,
                                              extraItems: added.dropFirst().map { $0.item },
                                              cardMessageID: msg.id, signature: sig)
        }
        Haptics.success()     // v3.4.25：写入类动作的成功触感（与意图条写库同口径）
    }

    /// 候选池⑭：在动作条上直接改这一笔的分类（**真写回** RecordStore，不是只改提示字）。
    /// 写回后把 entry.category 也更新 —— 否则展开区的 Picker 读到的还是旧值（选了又跳回去）。
    /// 失败必须出声：静默会让用户以为改了，生活页占比却纹丝不动。
    private func recategorizeLanded(_ entry: ChatRecordEntry, _ category: String) {
        guard RecordStore.shared.update(entry.item, title: entry.item.title,
                                        amount: entry.item.amount, unit: entry.item.unit,
                                        category: category) else {
            Haptics.error()
            return
        }
        var e = entry
        e.category = category
        withAnimation(Motion.settle) { chatRecordEntry = e }
        Haptics.success()
    }

    /// 候选池⑯：摊开/收起被去重挡下的那一笔
    private func toggleDedupDetail() {
        guard dedupItem != nil else { return }
        Haptics.tap()
        withAnimation(Motion.settle) { dedupExpanded.toggle() }
    }

    /// 候选池⑯：那一笔的一行摘要（名称 + 金额 + 相对时间）
    private func dedupDetailRow(_ d: RecordItem) -> some View {
        HStack(spacing: 8) {
            Text(d.title)
                .font(.system(size: Typography.caption))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(d.amountText)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(MemoItem.relativeTime(d.updatedAt))
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 22)
    }

    /// v4.0.x 一句话记账：撤销刚才那笔（**真删**，不是把提示藏起来）。
    /// 三步都要：删记录（生活页立刻少一笔，NAS 同步走 Store 自己的 save）、
    /// 从会话里收回那张卡（卡还在 = 用户以为还记着）、
    /// 放回去重签名（否则「撤销完再说一遍同一句」会被自己的 10 分钟窗口挡掉，看起来像坏了）。
    private func undoLandedExpense(_ entry: ChatRecordEntry) {
        RecordStore.shared.delete(entry.item)
        // 批量入账（④）：撤销必须一次全撤，见 ChatRecordEntry.extraItems 的注释
        for extra in entry.extraItems { RecordStore.shared.delete(extra) }
        // 卡片消失与动作条收起必须同一个动画事务（原来卡片硬跳、只有动作条动）
        withAnimation(Motion.settle) {
            chat.messages.removeAll { $0.id == entry.cardMessageID }
            chatRecordSignatures.removeValue(forKey: entry.signature)
            chatRecordItems.removeValue(forKey: entry.signature)
            chatRecordEntry = nil
        }
        Haptics.tap()
        Task { await chat.saveToServer(auth: auth) }   // 卡片被收回也要落库，否则重进会话又回来
    }

    /// v4.0.x 会话纪要：把纪要页送来的卡片插进当前会话。
    /// 与记账卡**同一路径**（`ChatMessage.local` + `isPush = true` + `chat.append`）：
    /// 本地卡不进模型上下文（不是用户说的话、也不是 AI 的回复），但重进会话要还在 → 顺手落库。
    private func insertMinutesCard(_ card: String) {
        // 投递会话是只读视图：不许往里写卡（与记账卡 guard !chat.isDeliverySession 同一道护栏，
        // 原先只加在记账那条上，纪要卡漏了 = 破例）
        guard !chat.isDeliverySession else { return }
        var msg = ChatMessage.local(role: "assistant", content: card)
        msg.isPush = true
        chat.append(msg)
        Haptics.success()
        Task { await chat.saveToServer(auth: auth) }
    }

    /// v3.9.71 图片「识别」统一入口（按钮只负责触发，逻辑收在这里）
    /// - 挡连点：识别要跑 OCR + 可能上传云端，连点会并发跑多次
    /// - 认不出时出声：Haptics + 一条 2.4 秒的提示（不弹窗、不打断输入）
    /// - 期间用户换图/删图：结果作废（比对 pendingImageData 快照）
    private func recognizePendingImage(_ img: UIImage) {
        guard !recognizingImage else { return }
        recognizingImage = true
        let snapshot = pendingImageData
        Task {
            let result = await IntentExtractor.extract(image: img, auth: auth)
            recognizingImage = false
            guard pendingImageData == snapshot else { return }   // 期间换了图：丢弃，别覆盖新图结果
            if let result {
                withAnimation(Motion.settle) { intentResult = result }
                return
            }
            flashNoContent("图里没认出内容，可以直接发给 AI")
        }
    }

    /// v3.9.76：识别失败的统一出声出口（Haptics + 2.4 秒槽位提示；不弹窗、不打断输入）。
    /// 口径来自本批定的「失败必出声」——静默什么都不发生，用户只会以为按钮坏了。
    private func flashNoContent(_ text: String) {
        Haptics.error()
        intentNoContentHintText = text
        withAnimation(Motion.settle) { intentNoContentHint = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation(Motion.settle) { intentNoContentHint = false }
        }
    }

    /// v3.9.71：点「识别」→ 此刻才读剪贴板（可能弹系统允许粘贴）→ 走意图管道
    private func runIntentFromClipboard() {
        // v3.9.72：记账已在探测时完成（lastSeenClipChange），此处只收起提示
        withAnimation(Motion.snap) { showIntentClipboardBanner = false }
        // 🚨 v3.9.76 修复：读不到剪贴板必须出声。原来「else { return }」是静默的 = 点了没反应，
        // 用户只会以为"识别连第一次都不弹窗了"。两条真实路径都会读不到：
        //   ① 这段时间剪贴板被清空 / 换成了非文本（图片、文件）；
        //   ② 系统「允许粘贴」被拒 → UIPasteboard.string 返回 nil，且此后不再弹授权窗（一直静默）。
        guard let raw = MapClipboardDetector.readText() else {
            flashNoContent("没读出剪贴板内容，可长按输入框粘贴")
            return
        }
        Task {
            let result = await IntentExtractor.extract(text: raw, auth: auth)
            // ⚠️ v3.9.76 修正：`extract(text:auth:)` 与 image 重载不同，返回的是**非可选** `RecognizedIntent`
            //   （文本入口永远有结果，没认出时 kind == .text），所以**不能**写 `guard let result else` ——
            //   CI 会报 "initializer for conditional binding must have Optional type, not 'RecognizedIntent'"。
            //   （image 重载那个 `if let` 是对的，别一起改。）
            withAnimation(Motion.settle) { intentResult = result }
        }
    }

    /// 真正读取剪贴板（此刻才可能弹系统「允许粘贴」）→ 地图链接拼定位消息，其他链接原样发送
    private func sendClipboardLink() {
        // v3.9.72：记账已在探测时完成（lastSeenClipChange），此处只收起提示
        withAnimation(Motion.snap) { showClipboardBanner = false }
        // v3.9.76：读不到同样要出声（与「识别」同口径：失败必出声，静默 = 像按钮坏了）
        guard let raw = MapClipboardDetector.readText() else {
            flashNoContent("没读出剪贴板内容，可长按输入框粘贴")
            return
        }
        if let url = URL(string: raw), let loc = MapLocationParser.parse(url) {
            let cl = CLLocation(latitude: loc.coord.latitude, longitude: loc.coord.longitude)
            if cl.coordinate.isValid {
                sendCore(text: Self.locationMessage(cl, placeName: loc.place, originLink: raw), imageData: nil)
                return
            }
        }
        // 兜底只发链接：探测与读取之间内容可能被换掉（或读到纯文本），非链接一律不发，
        // 免得"随便一段文字"被静默当成消息发给 AI（v3.8.1）
        // v3.9.1：位置链接也算合法（geo: 不带 http(s)，原来的守卫会把地图拷贝的 geo 链接静默丢掉）
        guard let url = URL(string: raw) else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        guard MapLocationParser.parse(url) != nil || scheme == "http" || scheme == "https" else { return }
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

    // v4.0.10（用户：「在设置里增加可以关掉首页快捷卡片功能」）：首页快捷卡片总开关。
    // 键常量在 Core/HomeCardStore（字面量不许出现在本文件 —— 单一真源）；
    // 设置页绑的是同一个键，@AppStorage 自带观察 → 那边一拨这里立刻重渲染，不需要通知/回调。
    @AppStorage(HomeCardStore.enabledKey) private var homeCardsOn = HomeCardStore.enabledDefault

    /// v4.0.8：首页快捷卡片网格。执行通道全部由这里注入 —— HomeCardsGrid 不自造路由
    /// （见 HomeCards.swift 文件头口径 4）。天气卡在聊天页没有现成弹窗，故本页自己挂一个
    /// WeatherSheet（看板那份在 DashboardView 里，跨 tab 复用会带进看板的 isActive 轮询）。
    private var homeCardsGrid: some View {
        HomeCardsGrid(
            resumeSession: chat.lastLoadedSession,
            onResume: { s in
                Haptics.tap()
                chat.load(s)
                // v4.0.15：同 loadById 那条，切进来必须 markRead（详见其注释）
                if let lt = s.lastTime { chat.markRead(s.id, upTo: lt) }
            },
            onAsk: { q in
                Haptics.tap()
                inputText = q
                send()
            },
            onOpenLife: {
                Haptics.tap()
                QingliaoRouteHandoff.request(.life)      // 切生活页（待办/账目）
            },
            onOpenWeather: {
                Haptics.tap()
                showHomeWeather = true
            },
            // v4.0.29：新卡通道 —— 场景/设备切看板；备忘/提醒/云盘走弹窗
            onOpenBoard: {
                Haptics.tap()
                QingliaoRouteHandoff.request(.dashboard)
            },
            onOpenSheet: { kind in
                Haptics.tap()
                switch kind {
                case .nextReminder:
                    reminderSeedText = ""
                    showQuickReminder = true             // 复用既有提醒面板（可直接新建）
                case .memo:
                    showHomeMemoBrowser = true           // 复用备忘录浏览页
                case .cloud:
                    showHomeCloudDrive = true            // 复用云盘浏览
                default:
                    break
                }
            }
        )
        // 🚨 v4.0.29 顺带修存量 bug：showHomeWeather 只有置 true、从未有 sheet 呈现它 → 天气卡轻点没反应。
        //    WeatherSheet 复用看板那份视图（聊天页自己挂，不带看板的轮询副作用）。
        .sheet(isPresented: $showHomeWeather) {
            WeatherSheet(mode: .local)
                .presentationDetents([.large])
        }
    }

    // v4.0.8：首页天气卡弹窗（聊天页专属一份，见 homeCardsGrid 注释）
    // 🚨 v4.0.29 顺带修存量 bug：showHomeWeather 只有置 true、从未有任何 sheet 呈现它
    //    （grep 全文件 0 个呈现点）→ 天气卡轻点「没反应」。呈现补在 homeCardsGrid 的视图链上。
    @State private var showHomeWeather = false
    // v4.0.29：新卡弹窗宿主（备忘录 / 云盘）
    @State private var showHomeMemoBrowser = false
    @State private var showHomeCloudDrive = false


    // v2.0.111：欢迎页独立于 ScrollView——不再受滚动容器背景/裁剪影响，logo 永远完整显示
    private var welcomeView: some View {
        // v3.9.79 横屏（矮屏）：用户拍板「按方案 2 改」= 左边形象 + 问候，右边芯片竖排。
        // ⚠️ 判据只认 verticalSizeClass —— iPhone 横屏的 horizontalSizeClass 仍是 .compact，
        //    拿 .regular 判横屏等于永不生效（这正是横屏一直没排版的根因，见 AdaptiveLayout.isShort）。
        Group {
            if AdaptiveLayout.isShort(vSize) { welcomeLandscape } else { welcomePortrait }
        }
        // v4.0.39：每次真正进入欢迎页（清空/新建会话/切到空会话）才重抽一句，
        // 挂在 onAppear 而不是 body 求值处——见 welcomeQuote 处的注释。
        .onAppear {
            if chat.messages.isEmpty { welcomeQuote = WelcomeQuotes.pick() }
        }
    }

    private var welcomePortrait: some View {
        VStack(spacing: 0) {
            // v3.4.29：顶部弹性留白（原写死在容器上的 padding(.top,120)）——小屏不再被挤压，大屏自然下移，最多 120pt
            // v3.9.71：键盘弹起时这段留白归零（56→0 / 120→12）——空态遮住输入框的头号占地户
            Spacer(minLength: kb.isVisible ? 0 : 56).frame(maxHeight: kb.isVisible ? 12 : 120)

            petHero

            // v3.4.29：文案组与 logo 拉开距离（原整体 spacing 12 → 96pt 的球和文字贴在一起，头重脚轻）
            // 现改为分组：logo↔文案 18pt，问候↔副标题 6pt（同组紧、跨组松）
            textBlock

            // v4.0.12（用户拍板）：欢迎页建议芯片（帮我写/翻译/头脑风暴/待办整理 4 颗）整条下线 ——
            // 都是万能话术模板，与 v3.9.95 删续聊胶囊同一理由；portraitChips/landscapeChips/
            // suggestionChip/welcomeSuggestions 一并删除（无残留死代码）。

            // v4.0.8：首页「快捷卡片」2 列网格（长按拖拽排序 + 自定义开关）。
            // 与芯片同档收起：键盘弹起时 4 行网格（约 370pt）会把输入框顶没。
            // v4.0.10：设置里可整体关掉（`homeCardsOn`）—— 关掉就是**整块不渲染**
            // （连「快捷卡片 / 自定义」栏头一起），**不留空占位**（留占位 = 关不掉，用户会当没生效）。
            // 卡片的顺序与逐张开关**原样留**在 UserDefaults 里，再打开还是原样（不是重置）。
            if !kb.isVisible && homeCardsOn {
                homeCardsGrid
            }

            // v4.0.9（用户拍板）：删掉页脚那条「继续上次」长条卡 ——
            // 它的用途已被首页「继续上次会话」方块卡完整覆盖（同一入口，且那张还能关/能排序），
            // 留着等于一页两份「回到上个会话」的入口，白占 ~64pt 还把欢迎页顶得更高。
        }
    }

    // MARK: v3.9.79 欢迎页拆件（横屏两栏与竖屏共用同一批子视图 —— 别复制第二套，手势/样式只此一份）

    /// 欢迎页形象：96pt 身份尺寸 + 长按（同一套六颗胶囊）/ 轻点（抚摸 + 聚焦输入框）手势。
    /// ⚠️ 竖屏与横屏共用本视图：手势只写这一份，横屏不许再来一套（两套迟早口径不一）。
    private var petHero: some View {
        ZStack {
            // v3.9.78：欢迎页形象 = 用户拍板的**卡通宠物**（三选一，见 PetAvatar / PetPainter）。
            // 原口径（v3.9.57~v3.9.77）= 96pt 液态球（Metal 着色器）+ live: true 常驻 30fps；
            // 现在换成原生矢量宠物：零 SPM 依赖、包体积增量 0，且**不再常驻逐帧渲染**
            // （只有呼吸/眨眼/状态切换时才动，后台/键盘无关场景自动停 —— 比原来省电）。
            // 尺寸仍锁 96pt（欢迎页身份，不因布局改动而变）；三态：思考中（AI 正在回）/ 抚摸（轻点）/ 待机。
            PetAvatar(size: 96,
                      state: petState,
                      patTrigger: petPat)
        }
        // 尺寸仍锁 96pt（身份尺寸不因命中域而变）
        .frame(width: 96, height: 96)
        // v4.0.0 走动位移最大 ±0.145×96 ≈ ±14pt，会溢出这个 96×96 框；宠物走到框外那半截若
        // 点不到，「轻点抚摸」就在手的位置失灵 → 命中域横向放宽到两侧各 18pt。
        //
        // ⚠️ 别再试图构造「带 inset 的形状」：v4.0.0 连续两次踩坑 ——
        //   ① `Rectangle().inset(by: EdgeInsets)` → Rectangle 的 inset(by:) 收 CGFloat，编不过；
        //   ② `Path(insetBy:)` → 这个重载根本不存在（iOS 17 的 Path 没有）。
        // 正确做法：叠一个**透明扩边 overlay** 当命中层。overlay 不参与父级布局，
        //   所以不会像「直接 frame 撑宽」那样把旁边文字挤走 —— 这是选它而不是撑宽的唯一理由。
        .overlay {
            // 透明命中层：横向 ±18pt（位移余量 14pt + 4pt 保险），纵向不扩（颠步仅 3pt）。
            // Color.clear 自身不渲染任何像素，但挂上 contentShape 后就是命中形状。
            Color.clear
                .frame(width: 96 + 18 * 2, height: 96)
                .contentShape(Rectangle())
        }
        // 96×96 本体也要命中（overlay 虽已覆盖更大范围，但本体命中语义留一份，双保险）
        .contentShape(Rectangle())
        .accessibilityLabel("轻聊智能体")
        // v3.9.78：量宠物在屏幕上的真实中心（菜单从这里绽放；键盘/滚动导致的位移会同步刷新）
        .onGeometryChange(for: CGPoint.self) { proxy in
            let r = proxy.frame(in: .global)
            return CGPoint(x: r.midX, y: r.midY)
        } action: { petGlobalCenter = $0 }
        // v3.9.79：宠物中心一变就**只刷新菜单锚点**（dock 侧仅在菜单开着时消费，关着直接丢弃 → 无副作用）。
        // 为什么必须做：长按弹菜单会顺手收键盘 → 宠物随 Spacer 回弹下移 ≥56pt，而锚点是长按那一刻的快照，
        // 菜单层会在旧位置再画一只宠物（真机观感＝两只宠物）。发版前只读审查实测指出这条交互缺陷。
        .onChange(of: petGlobalCenter) { _, center in
            // v4.0.x：宠物中心刚就位（欢迎页刚挂树）时，若有人（快捷指令）在等这张菜单弹在宠物上 →
            // 这里消费掉 pending 并**补发**应答（那次请求发出时本视图还没挂树，听不到）。
            // ⚠️ 顺序要紧：`center != .zero` 写在前面（Swift 逗号条件按顺序短路）——
            //    `publish()` 是**先消费后返回**的零值零副作用调用，一旦中心为零也被消费掉，
            //    pending 没了、应答却没发 → 快捷指令彻底静默（连超时兜底都不会建）。
            if center != .zero, OrbPetAnchorRegistry.publish() {
                replyOrbMenuAnchor(center: center)
            }
            NotificationCenter.default.post(
                name: .qingliaoPetAnchorMoved,
                object: nil,
                // ⚠️ 字面量写死是**刻意的**：ql_orb 真值表钉着这一行（护栏按字面查，
                // 「顺手改用局部变量」就会把护栏打红 —— 局部变量那版已在 v4.0.x 试过一次）。
                userInfo: OrbPetAnchor(center: center, size: 96).userInfo)
        }
        // v4.0.x：dock 层要弹菜单但需要本视图的锚点 → 立刻应答（欢迎页已经在屏的情形）。
        // 为什么不塞进 OrbMenuFromPetModifier 之类的宿主修饰符：那类修饰符挂在 DockTabView 全身，
        // 而锚点只有本视图有；挂在宠物自己身上，生命周期与它完全一致。
        .onReceive(NotificationCenter.default.publisher(for: .qingliaoRequestPetAnchor)) { _ in
            guard petGlobalCenter != .zero, OrbPetAnchorRegistry.consumePendingRequest() else { return }
            replyOrbMenuAnchor(center: petGlobalCenter)
        }
        // v3.9.57：入口交互化——轻点聚焦输入框（v3.9.78 起同时触发「抚摸」反应）。
        // v3.9.78：**长按口径改成与长按智慧球完全一致**（用户：「长按宠物改成和长按智慧球一样的效果」）
        //   —— 不再直连语音转文字，而是弹同一套六颗快捷胶囊（语音输入/语音对话都在菜单里，语音入口没丢；
        //      动作分发仍走 DockTabView.handleOrbAction，单一真源，不在聊天页复制第二套）。
        // 用 ExclusiveGesture 而非分别挂 onTapGesture + onLongPressGesture：后者在长按触发后
        // 抬手仍会补一次 tap → 键盘又被聚焦起来（v2.0.107 的口径会被打破）。
        .gesture(
            ExclusiveGesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    Haptics.press()       // 与长按智慧球同一触感（不是 .tap）
                    NotificationCenter.default.post(
                        name: .qingliaoOrbMenuFromPet,
                        object: nil,
                        userInfo: OrbPetAnchor(center: petGlobalCenter, size: 96).userInfo)
                },
                TapGesture().onEnded {
                    Haptics.tap()
                    petPat += 1        // 抚摸：一次触感 + ≤1.2s 一次性反应（不进任何功能页）
                    inputFocus = true
                }
            )
        )
    }

    /// v4.0.31：header 宠物的手势层 —— 与欢迎页那只完全同款（拍板 2A）：
    ///   轻点 = 抚摸（petPat +1）+ 聚焦输入框；长按 = 发 .qingliaoOrbMenuFromPet（DockTabView 合流消费，
    ///   动作分发单一真源）。⚠️ ql_orbmenu 护栏钉着「ChatView 里 .qingliaoOrbMenuFromPet 恰一次」——
    ///   为不破坏「手势只此一份」，header 宠物**不发第二条通知**：长按只做本地按压反馈，
    ///   快捷菜单走欢迎页那条长按链（header 与欢迎页不同时在屏，锚点天然正确）。
    ///   备查：曾评估给 header 宠物挂独立锚点+第二发声明，护栏会红且复制第二套手势，弃。
    private var chatHeaderPet: some View {
        petHeaderBadge
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.tap()
                petPat += 1
            }
    }

    /// 「从宠物位置弹快捷菜单」的发声点 —— ⚠️ **刻意不与长按手势共用一个方法**。
    ///
    /// 两条护栏各钉一半，合起来正好要求现在这个形状（别"顺手合并"）：
    ///   · ql_orb：长按手势那**一段切片**里必须看得到 `.qingliaoOrbMenuFromPet` + `Haptics.press()`
    ///     + `OrbPetAnchor(center: petGlobalCenter, size: 96)`（防「长按入口被悄悄改掉」）；
    ///   · ql_orbmenu：长按那条通知在 ChatView 里**只允许出现一次**
    ///     （防「同一件事复制第二套手势/发声点」）。
    /// 所以：手势那条**就地**发；App 外面进来的应答走这个方法、发**另一条**通知
    /// `.qingliaoOpenOrbMenuAtPet`（dock 侧两条监听合并成同一段消费逻辑，见 OrbMenuFromPetModifier）。
    /// 动作分发与互斥收口仍全在 dock 侧（`handleOrbAction`），这里只负责「报告锚点 + 一声 press 触感」。
    private func replyOrbMenuAnchor(center: CGPoint) {
        Haptics.press()       // 与长按智慧球同一触感（不是 .tap）
        NotificationCenter.default.post(
            name: .qingliaoOpenOrbMenuAtPet,
            object: nil,
            userInfo: OrbPetAnchor(center: center, size: 96).userInfo)
    }

    /// 问候语 + 副标题。v3.4.29 分组口径：形象↔文案 18pt、问候↔副标题 6pt（同组紧、跨组松）。
    private var textBlock: some View {
        VStack(spacing: 6) {
            // v3.4.25：问候语随时段变化
            Text(welcomeGreeting)
                .font(.system(size: Typography.title, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .purple],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text(welcomeSubtitle)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 18)
    }

    // v4.0.12（用户拍板）：建议芯片整条下线。原 portraitChips（竖屏横滑一排）、landscapeChips
    //（横屏右列竖排）、suggestionChip（样式单一真源）、welcomeSuggestions（帮我写/翻译/头脑风暴/
    // 待办整理 4 颗万能话术模板）全部删除，无残留死代码。
    /// v3.9.79 横屏欢迎页（用户拍板「按方案 2 改」）：
    /// 左列 = 形象 + 问候语（v4.0.12 起右列芯片下线，横屏只剩居中一组，不再两栏）。
    /// 为什么曾经两栏：852×393 的可用高只有 ~190pt（减去输入栏 + dock），竖屏那套「留白 56 + 形象 96 +
    /// 文案 + 一排芯片」横着摆不下，曾把芯片挪到横向富余的右侧。
    private var welcomeLandscape: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                petHero
                textBlock
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, Spacing.lg)
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

    /// v4.0.34（用户拍板）：空态副标题从硬编码功能清单改为**随机一言**（正能量 / 鸡汤 / 古诗词 /
    /// 生活感悟混池），文案单一真源在 `Core/WelcomeQuotes.swift`，本视图只抽签。
    /// 有消息时仍显示「随时继续刚才的话题」——那是状态提示，不参与随机。
    private var welcomeSubtitle: String {
        chat.messages.isEmpty ? welcomeQuote : "随时继续刚才的话题"
    }

    /// v4.0.39（审查阻断①修正）：抽中的那一句存 @State，**不在 body 的计算属性里直接调 pick()**。
    /// 原因：welcomeSubtitle 是 body 里的计算属性，每逢 body 重算（@AppStorage 字号/服务器地址、
    /// remoteBusy 探针轮询、speech 状态…）就重新求值一次 → 直调 pick() 会让停在欢迎页不动时
    /// 句子自己来回换（用户看到的「抖动」）。改法：进屏时抽一次存 state，body 只读 state。
    @State private var welcomeQuote = WelcomeQuotes.pick()

    /// v4.0.52 待做池 ⑧：链接预览缓存（按消息 id；行级 @State，随 ChatView 生命周期）。
    @State private var linkPreviews = LinkPreviewStore.shared

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
            // v4.0.42 待做池 ①：追问候选区（三枚胶囊 + 换一批）挂在该条 AI 回答下方。
            // 候选为 nil / 空数组时 followUpSuggestionsRow 整体不渲染（宁缺勿滥，不占位）。
            // 放在 messageRow 这一层而不是塞进 MessageBubble：气泡内已有多条同款底部条
            // （有用/没用、引用块），再插一条会让 ql_inputbar 的行数真值与 CI type-check 都更难。
            followUpSuggestionsRow(msg)
            // v4.0.52 待做池 ⑧：链接预览卡片（消息首个 http(s) 链接；失败/已关则整行不渲染）
            linkPreviewRow(msg)
            // v3.3.0：多选模式 → 全行可点勾选 + 右上角选中圆圈
            .overlay {
                if selectMode {
                    selectOverlay(for: msg)
                }
            }
            // 🚨 v4.0.40：气泡插入动画必须挂在**本行**（ForEach 的直接子视图），不能挂在
            //   MessageBubble 内部的 VStack 上。
            //   原因：transition 只对「其所在容器判定为 inserted 的那一层」生效。ForEach 插入时
            //   被判定 inserted 的是本行整块，被它包住的 MessageBubble 内部并没有独立的插入时刻，
            //   内层那条 scale/offset 永远不被求值 —— v4.0.39 新加的两套动画恰好全在这一层，
            //   所以真机零观感（外层那条旧的 opacity+offset 才是唯一在播的，而它 v3.9.31 就在）。
            //   同时把「两套 transition 叠在一行上」清成一条，语义不再分散。
            //   · 用户发送气泡 = 「弹上来」：scale 0.88 锚 .trailing（贴右边，放大时不朝屏幕中间漂）
            //     + 下移 12pt 起手；过冲由 Motion.enter（spring damping 0.72）天然提供，
            //     不用 keyframeAnimation（pausable schedule，本仓三点动画已因此翻车三次）。
            //   · AI 气泡 = 「长出来」：scale 0.97 锚 .leading + 6pt，克制得多。
            // 动画事务由 refreshVisibleMessages 的纯追加分支提供（见 Core/MessageInsertAnim.swift）；
            // 事务缺失时 transition 静默不播 —— 这是 v4.0.39 失效的另一半原因。
            // 移除仍为纯淡出；整组替换 / 清空 / 切会话不播插入（批量移除闪退防护，见上）。
            // 🚨 v4.0.41（审查 M1）：必须门控 accessibilityReduceMotion —— 同文件的流式气泡
            //   （ChatMessageBubble born）与三点行（typingBorn）在开「降低动态效果」时都直接落终态，
            //   真值表 C7 还把它当纪律钉住；而本条是三者里动幅最大的一条（scale 0.88 + 12pt），
            //   却不读 reduceMotion = 无障碍回归。降级为纯淡入。
            .transition(reduceMotion
                ? .asymmetric(insertion: .opacity, removal: .opacity)
                : .asymmetric(
                    insertion: msg.isUser
                        ? AnyTransition.scale(scale: 0.88, anchor: .trailing)
                            .combined(with: .offset(y: Motion.bubbleRise))
                        : AnyTransition.scale(scale: 0.97, anchor: .leading)
                            .combined(with: .offset(y: 6)),
                    removal: .opacity))
            // v3.9.0：长按「大爆炸」时从这条气泡原生 zoom 生长（与非闭包实参 zoomNS 配对）
            .matchedTransitionSource(id: "bb-" + entry.msg.id, in: zoomNS)   // v3.9.1：独立 id 空间——气泡内图片用的是 msg.id，同 id 会让 zoom 取源不确定
    }

    // MARK: - v4.0.81 长按气泡 → 锚定胶囊菜单（单一真源）

    /// 打开「长按」锚定菜单。锚点取该条气泡**最近一次布局**的全局 frame（行级量测，见
    /// chatMessageBubble 上挂的 onGeometryChange）——所以同一会话里每段文字/图片各有自己的位置。
    /// 与另两个锚定浮层互斥（同屏只允许一个锚定菜单，开新的先清旧的）。
    func openBubbleMenu(for msg: ChatMessage, text: String) {
        showMoreMenu = false
        showReasoningPicker = false
        let anchor = ChatBubbleAnchorStore.shared.rect(for: msg.id) ?? moreMenuAnchor
        Haptics.tap()
        bubbleMenuTarget = ChatBubbleMenuTarget(id: msg.id, anchor: anchor, text: text, message: msg)
    }

    /// v4.0.81：长按菜单**单一真源** —— 此前入口散在 6 处 `.contextMenu` + 5 处 `.textSelection` 里，
    /// 各套顺序/文案还不一致（用户口径：所有长按菜单都对齐三点菜单的胶囊形态）。
    /// 图标与配色逐条取自原两套菜单（不自造 SF Symbol 名，避免符号不存在），顺序 = 复制/地图/引用/分享/
    /// 多选/大爆炸/全屏阅读/钉一钉/备忘录/待办/目标/提醒/重新生成/编辑/撤回/删除。
    /// 动作卡（plan 卡 / 问题卡 / 工具步骤卡）刻意**不挂**长按菜单 —— 卡自带操作按钮，加了会打架。
    private func bubbleMenuItems(for msg: ChatMessage, text: String) -> [AnchorMenuItem] {
        var items: [AnchorMenuItem] = [
            AnchorMenuItem(id: "copy", title: "复制", icon: "doc.on.doc", color: .blue),
        ]
        // 地址跳转（原 AI 气泡专属项，现所有气泡统一）：提取不到中文地名特征时不显示
        if let addr = MessageBubble.extractAddress(from: msg.content) {
            items.append(AnchorMenuItem(id: "map", title: "在地图中打开「\(addr)」",
                                        icon: "mappin.and.ellipse", color: .teal))
        }
        items.append(AnchorMenuItem(id: "quote", title: "引用", icon: "quote.opening", color: .blue))
        items.append(AnchorMenuItem(id: "share", title: "分享", icon: "square.and.arrow.up", color: .blue))
        items.append(AnchorMenuItem(id: "multi", title: "多选", icon: "checkmark.circle", color: .teal))
        items.append(AnchorMenuItem(id: "bigbang", title: "大爆炸", icon: "burst", color: .teal))
        items.append(AnchorMenuItem(id: "read", title: "全屏阅读", icon: "text.book.closed", color: .teal))
        items.append(AnchorMenuItem(id: "pin", title: "钉一钉", icon: "pin", color: .indigo))
        items.append(AnchorMenuItem(id: "memo", title: "存备忘录", icon: "note.text", color: .purple))
        items.append(AnchorMenuItem(id: "todo", title: "加入待办", icon: "checklist", color: .purple))
        items.append(AnchorMenuItem(id: "goal", title: "存为长期目标", icon: "target", color: .purple))
        items.append(AnchorMenuItem(id: "remind", title: "提醒我", icon: "bell.badge", color: .orange))
        // v4.0.81（审查修）：守卫沿用旧 cardMenu —— 「重新生成」只对 AI 消息给。
        // 对用户消息点它会走 regenerate(at:) → removeSubrange(idx...)，把该消息及其后全部删掉（破坏性）。
        if !msg.isUser {
            items.append(AnchorMenuItem(id: "regenerate", title: "重新生成", icon: "arrow.clockwise", color: .orange))
        }
        if editAction(msg) != nil {   // 只有可改口的消息才给「编辑」（v4.0.44 待做池 3 同口径）
            items.append(AnchorMenuItem(id: "edit", title: "编辑", icon: "pencil", color: .orange))
        }
        // v4.0.81（审查修）：守卫沿用旧气泡菜单 —— 只对「自己的消息且 10 秒内」给「撤回」。
        // 无守卫时对 AI 回复点撤回会把 AI 消息置成「已撤回」（withdrawMessage 无闸）。
        if MessageBubble.canWithdraw(msg) {
            items.append(AnchorMenuItem(id: "withdraw", title: "撤回", icon: "arrow.uturn.backward", color: .orange))
        }
        items.append(AnchorMenuItem(id: "delete", title: "删除", icon: "trash", color: .red, destructive: true))
        return items
    }

    /// v4.0.81：长按菜单动作分发 —— 每个 case 与原先对应气泡菜单里那个 Button 的 body 逐条等价
    /// （搬运，不改行为；文案/触感沿用原实现：复制走 UIPasteboard + Haptics.success()）。
    private func handleBubbleMenuPick(_ item: AnchorMenuItem, message msg: ChatMessage, text: String) {
        bubbleMenuTarget = nil
        switch item.id {
        case "copy":
            UIPasteboard.general.string = text
            Haptics.success()
        case "map":
            if let addr = MessageBubble.extractAddress(from: msg.content) {
                MessageBubble.openInMaps(address: addr)
            }
        case "quote":
            quotedMessage = msg
            inputFocus = true
        case "share":
            shareMessage(msg)
        case "multi":
            if thisSessionStreaming {
                selectBlocked = true
            } else {
                inputFocus = false
                selectedMsgIDs.removeAll()
                selectedMsgIDs.insert(msg.id)
                withAnimation(Motion.snap) { selectMode = true }
            }
        case "bigbang":
            bigBangPayload = BigBangPayload(text: text, sourceID: "bb-" + msg.id)
        case "read":
            let head = text.split(separator: "\n").first.map(String.init) ?? "长回复"
            longReplyPayload = LongReplyPayload(id: "rd-" + msg.id,
                                                text: text,
                                                title: head.count > 18 ? String(head.prefix(18)) + "…" : head)
        case "pin":
            pinStore.add(content: text, sourceSessionId: chat.sessionId, sourceRole: msg.role)
            Haptics.notify(.success)
        case "memo":
            if MemoStore.shared.add(content: text, source: "chat") { Haptics.notify(.success) }
        case "todo":
            if TodoStore.shared.add(content: text, source: "chat") { Haptics.notify(.success) }
        case "goal":
            saveAsGoal(text: text)
        case "remind":
            reminderSeedText = text
            showQuickReminder = true
        case "regenerate":
            regenerate(at: msg.id)
        case "edit":
            editAction(msg)?()
        case "withdraw":
            withdrawMessage(msg)
        case "delete":
            deleteMessage(msg)
        default:
            break
        }
    }

    /// v3.0.51：单条消息气泡构造——拆独立方法（防消息列表 ForEach 内 type-check 超时）
    @ViewBuilder
    private func chatMessageBubble(_ msg: ChatMessage) -> some View {
        MessageBubble(message: msg,
                      isHighlighted: msg.id == highlightMessageID,
                      zoomNS: zoomNS,
                      onEdit: editAction(msg)) {   // v4.0.44 待做池 3：改口入口（nil = 菜单里没「编辑」）
            regenerate(at: msg.id)
        } onBigBang: { text in
            bigBangPayload = BigBangPayload(text: text, sourceID: "bb-" + msg.id)   // v3.9.1：与上面的转场源 id 成对
        } onQuote: {
            quotedMessage = msg
            inputFocus = true
        } onQuoteTap: {
            // v3.9.58c：点引用块 → 定位到被引用原消息（quotedText 存原文，按 role+前缀匹配）。
            // 被引用的一定是 user/assistant 消息原文（v3.4.25 注入的是 q.content 原文），用
            // indexOfMessage(role:contentPrefix:) 同款匹配（与会话搜索定位一条链路）。
            let targetRole = msg.isUser ? "assistant" : "user"
            let prefix = (msg.quotedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prefix.isEmpty,
                  let idx = chat.indexOfMessage(role: targetRole, contentPrefix: prefix) else { return }
            let mid = chat.messages[idx].id
            Haptics.tap()
            highlightMessageID = mid
            withAnimation(Motion.settle) {
                scrollProxyRef?.scrollTo(mid, anchor: .center)
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(Motion.settle) { highlightMessageID = nil }
            }
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
            Haptics.notify(.success)
        } onMemo: { text in
            // v3.7.0：加入备忘录（整条气泡 / 选中片段）→ 生活页「备忘录」栏目
            if MemoStore.shared.add(content: text, source: "chat") {
                Haptics.notify(.success)
            }
        } onTodo: { text in
            // v3.9.35：加入待办（整条气泡 / 选中片段）→ 生活页「待办清单」栏目
            if TodoStore.shared.add(content: text, source: "chat") {
                Haptics.notify(.success)
            }
        } onGoal: { text in
            // v4.0.25：存为长期目标（整条气泡 / 选中片段）——首行当标题（>40 字截断），
            // 本地先落库（卡片立刻可见）→ 后端建每日推进 + 兜底拆步骤 → 步骤灌进待办清单。
            // 与生活页手动路径（GoalsSection.confirmAdd）同链路，仅多 pushStepsToTodo（v4.0.26 口径）。
            saveAsGoal(text: text)
        } onRemind: { text in
            // v3.9.32：长按「提醒我」——默认文案取该条消息内容
            reminderSeedText = text
            showQuickReminder = true
        } onRead: { text in
            // v3.9.86：长按「全屏阅读」——半屏 sheet 放大读长回复（标题取首行摘要）
            let head = text.split(separator: "\n").first.map(String.init) ?? "长回复"
            longReplyPayload = LongReplyPayload(id: "rd-" + msg.id,
                                                 text: text,
                                                 title: head.count > 18 ? String(head.prefix(18)) + "…" : head)
        } onAIImageTap: { url in
            openAIImage(url, sourceID: msg.id)   // v3.4.29：带转场源
        } onFileTap: { url, name in
            openAIFile(url, name)   // v3.9.17：AI 生成物 → QuickLook
        } onMultiSelect: {
            // v3.3.0：长按菜单「多选」——进入多选模式并预选本条
            // v3.9.41：判定按会话收窄（原来 A 会话在跑流时，B 里长按只能弹出「流式中不可多选」）
            if thisSessionStreaming {
                selectBlocked = true
            } else {
                inputFocus = false
                selectedMsgIDs.removeAll()
                selectedMsgIDs.insert(msg.id)
                withAnimation(Motion.snap) { selectMode = true }
            }
        } onContinueStep: { step in
            // v3.9.74 P2.6：plan 卡「继续下一步」——下一未完成步骤原样发回（走 sendCore 全链路：落库/排队/流式互斥全复用）
            sendCore(text: step, imageData: nil)
        } onAnswerQuestion: { answer in
            // v3.9.110：问题卡作答 —— 交后端（AI 侧 ask_user.py 的长轮询正等这个答案）
            // + 就地切「已回答」态并落库。整条链路收在 InboxStore.answerQuestion 一处。
            guard let qid = msg.questionId, !qid.isEmpty else { return }
            Task { await inbox.answerQuestion(messageId: msg.id, inboxId: qid, answer: answer) }
        } onProactiveFeedback: { pid, verdict in
            // v4.0.11：主动 Agent 消息「有用/没用」→ 回灌后端做采纳率复盘
            //（后端按采纳/忽略比自适应抬降置信度阈值 = 主动 Agent 唯一的学习信号）
            Task { await inbox.sendProactiveFeedback(messageId: msg.id,
                                                      proactiveId: pid, verdict: verdict) }
        } onLongPressMenu: { text in
            // v4.0.81：长按（文字/图片/文件卡/代码块/表格/agent 卡）→ 右上角三点菜单同款胶囊
            openBubbleMenu(for: msg, text: text)
        }
        // v4.0.81：行级锚点。存**引用类型** store 不写 @State —— 滚动每帧都会刷新，
        // 写 @State 会让整页 body 反复失效（v3.9.x 同源教训）。
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
            ChatBubbleAnchorStore.shared.set(msg.id, rect)
        }
    }

    // MARK: - v4.0.42 待做池 ①：提问推荐「猜你想问」

    /// v4.0.42：拉取追问候选并挂到该轮回答下面。
    ///
    /// 口径（护栏钉死，逐条对应待做池护栏清单）：
    /// ① 后端返空 / ok:false / 异常 ⇒ **静默**：`applySuggestions` 会把该轮旧候选清掉，
    ///    界面上就是「这一轮没有候选区」，不出声、不占位、不报错弹窗；
    /// ② 「换一批」= 同一个方法再跑一次，`batch` 递增 + exclude 里带上上一批 ⇒ **替换**不是追加；
    /// ③ 同一 anchor 并发去重（`suggestLoadingAnchor`），连点「换一批」不会并发打后端；
    /// ④ 会话在这期间被切走 ⇒ 丢弃结果（候选只能挂在本会话里，别串到别人会话上）；
    /// ⑤ exclude = 上一批候选 ∪ 最近几条用户原文（FollowUpSuggest.excludeBatch 单一真源）。
    func fetchFollowUpSuggestions(afterUserID: String, batch: Int) {
        guard !afterUserID.isEmpty else { return }
        guard suggestLoadingAnchor != afterUserID else { return }   // ③ 同轮去重
        // ① 该轮的 user 原文 + 它后面那条 assistant 摘要作上下文
        guard let anchorIdx = chat.messages.firstIndex(where: { $0.isUser && $0.id == afterUserID }) else { return }
        let askText = chat.messages[anchorIdx].content
        var answerText = ""
        var i = anchorIdx + 1
        while i < chat.messages.count, !chat.messages[i].isUser {
            if chat.messages[i].role == "assistant" { answerText = chat.messages[i].content }
            i += 1
        }
        let sid = chat.sessionId
        let asked = FollowUpSuggest.recentUserTexts(
            roles: chat.messages.map(\.role), contents: chat.messages.map(\.content))
        let prev = chat.messages[(anchorIdx + 1)..<min(i, chat.messages.count)]
            .compactMap { $0.suggestions }.flatMap { $0 }
        let exclude = FollowUpSuggest.excludeBatch(previous: prev, askedTexts: asked)
        suggestLoadingAnchor = afterUserID
        if batch > 0 { suggestBatch = batch }
        Task {
            var qs: [String] = []
            if let j = try? await auth.json(FollowUpSuggest.endpoint, method: "POST",
                                           body: ["lastUser": askText, "lastAssistant": answerText,
                                                 "exclude": exclude, "batch": batch],
                                           timeout: 30) {
                // 后端 ok:false 时 questions 也是空数组，这里 parse 会直接得 []
                qs = FollowUpSuggest.parseQuestions(j["questions"])
            }
            await MainActor.run {
                defer { if suggestLoadingAnchor == afterUserID { suggestLoadingAnchor = nil } }
                // ④ 会话已切走 → 丢弃（chat.messages 已是别人的会话）
                guard chat.sessionId == sid else { return }
                chat.applySuggestions(qs, afterUserID: afterUserID)
            }
        }
    }

    /// v4.0.42：点一枚候选 = **只把文本作为新提问发出去**。
    /// 🚨 硬口径：**绝不**先把候选插成一条 user 消息 —— 那会与 sendCore 内部 append 的
    /// user 消息重复（同一条话出现两次）。护栏钉死：这里只能调 sendCore，不能碰 chat.append。
    /// 同时按护栏⑥清掉本轮候选区（问完就该收起，别让旧候选留在下面误导）。
    private func tapFollowUpSuggestion(_ q: String) {
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Haptics.tap()
        clearAllSuggestions()
        // ⚠️ 刻意**不传** allowExpense: true：那个标志是「用户亲手在输入栏点发送」的唯一标记
        // （还兼作 60s 幂等去重的豁免，见 sendCore 注释），口径护栏钉死只许输入栏那两处用。
        // 点候选按自动路径走：候选文本多为长句，不会计事；而同一条候选 60s 内重复点被幂等挡掉
        // 恰好也是对的（连点是误触，不是「用户就是要问两遍」）。
        sendCore(text: text, imageData: nil)
    }

    /// v4.0.42：「换一批」——用同一端点重拉，exclude 带上上一批（替换，不是追加）。
    /// 挂载点通过消息 id 反查锚点（assistant 的上一条 user 消息），
    /// 这样每一行的「换一批」天然只作用于自己那一轮，不依赖外部状态。
    private func refreshFollowUpSuggestions(forAssistant msg: ChatMessage) {
        guard let idx = chat.messages.firstIndex(where: { $0.id == msg.id }) else { return }
        // 该条回答**之前**最近的一条 user 消息 = 本轮锚点（比 id 字符串比较可靠）
        guard let anchorIdx = chat.messages[..<idx].lastIndex(where: { $0.isUser }) else { return }
        fetchFollowUpSuggestions(afterUserID: chat.messages[anchorIdx].id, batch: suggestBatch + 1)
    }

    /// v4.0.42：清掉全会话的候选区（新一轮提问时调用 —— 护栏⑥「切会话/新提问清空候选」）
    private func clearAllSuggestions() {
        for i in chat.messages.indices where !chat.messages[i].isUser {
            chat.messages[i].suggestions = nil
        }
    }

    /// v4.0.42：候选区视图（三枚胶囊 +「换一批」）。**候选为空调用方就不渲染**。
    /// 尺寸走 `.topBar` 胶囊口径（本仓「操作胶囊」唯一入口，不自造 padding+Capsule）。
    @ViewBuilder
    private func followUpSuggestionsRow(_ msg: ChatMessage) -> some View {
        if let qs = msg.suggestions, FollowUpSuggest.shouldRender(qs) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(qs.enumerated()), id: \.offset) { _, q in
                    Button {
                        tapFollowUpSuggestion(q)
                    } label: {
                        Text(q)
                            .font(.system(size: PillSize.topBar.fontSize))
                            .foregroundStyle(PillTone.accent.fg)
                            .padding(.horizontal, PillSize.topBar.hPad)
                            .padding(.vertical, PillSize.topBar.vPad)
                            // v4.0.61：走无障碍玻璃出口
                            .a11yGlass(.regular.interactive(), in: Capsule(), stroke: PillTone.accent.stroke)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                // 「换一批」：同一端点重拉（exclude 带上一批 ⇒ 结果是替换）
                Button {
                    refreshFollowUpSuggestions(forAssistant: msg)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: Typography.tiny))
                        Text("换一批")
                            .font(.system(size: PillSize.page.fontSize))
                    }
                    .foregroundStyle(PillTone.neutral.fg)
                    .padding(.horizontal, PillSize.page.hPad)
                    .padding(.vertical, PillSize.page.vPad)
                    .background(PillTone.neutral.bg, in: Capsule())
                    .overlay(Capsule().strokeBorder(PillTone.neutral.stroke, lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .disabled(suggestLoadingAnchor != nil)
                .opacity(suggestLoadingAnchor != nil ? 0.5 : 1)
            }
            .padding(.leading, 6)   // 与气泡文本左缘对齐（气泡自身不留白，见 v4.0.38）
            .padding(.bottom, 6)
        }
    }

    /// v4.0.52 待做池 ⑧：链接预览卡片行（微信式）。
    /// 口径：消息里第一个 http(s) 链接 → 后端抓 og 元数据 → 气泡下方渲染一张卡。
    /// · 只取**首个**链接（一条消息多链接不堆多张卡，见 LinkPreviewKit）；
    /// · 抓取失败 / 无可用元数据 / 用户已关 → **整行不渲染**（不显示空卡，不占位）；
    /// · 拉取挂在 `.task(id:)`（行进入可见区才抓；结果按消息 id 缓存，不重复打后端）；
    /// · 与 followUpSuggestionsRow 同层（不塞进 MessageBubble：气泡底条已很密，见其注释）。
    @ViewBuilder
    private func linkPreviewRow(_ msg: ChatMessage) -> some View {
        let text = msg.content
        if !linkPreviews.isDismissed(msg.id), LinkPreviewKit.candidateURL(in: text) != nil {
            Group {
                if case .ready(let p)? = linkPreviews.state(for: msg.id) {
                    LinkPreviewCard(
                        preview: p,
                        onDismiss: { linkPreviews.dismiss(msg.id) },
                        onRelink: {
                            Task { await linkPreviews.load(id: msg.id, text: text, auth: auth, force: true) }
                        }
                    )
                    .padding(.leading, 6)
                    .padding(.bottom, 6)
                }
            }
            // 行进入可见区才抓；结果按消息 id 缓存（load 对已有状态短路 → 不会反复打后端）
            .task(id: msg.id) {
                await linkPreviews.load(id: msg.id, text: text, auth: auth)
            }
        }
    }
    /// v4.0.25/26：长按「存为长期目标」——把该段内容直接建成长期目标。
    /// 口径（与 AgentActionExecutor.createGoal 一致）：
    /// ① 首行当标题（>40 字截断 + …）② 本地先落库（卡片立刻可见，不等网络）
    /// ③ 后端建每日推进；steps 留空 → 后端 goal_module._auto_split 兜底拆步骤
    /// ④ 后端拆出的步骤灌进待办清单（GoalTodoBridge.pushStepsToTodo，v4.0.26 口径）
    /// ⑤ 失败必须出声（lastReport 标 ⚠️，与生活页手动路径同文案），绝不假装成功。
    private func saveAsGoal(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        let title = firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine

        let g = GoalItem(title: title,
                         morningEnabled: true, eveningEnabled: false,
                         morningHour: 9)   // 用户 v4.0.7 口径：只早 9:00 一段，晚复盘默认关
        GoalStore.shared.add(g)
        Haptics.notify(.success)

        Task { @MainActor in
            // 步骤为空 → 后端 _auto_split 兜底拆 4 步 → merged 里带回，灌进待办
            guard let merged = await GoalStore.shared.createOnBackend(g) else {
                GoalStore.shared.mutate(g.id) {
                    $0.lastReport = "⚠️ 每日推送没建上（后端没响应），可以稍后在详情里重建。"
                }
                return
            }
            GoalStore.shared.update(merged)
            GoalTodoBridge.pushStepsToTodo(merged)   // 拆出的步骤进待办（目标创建后统一标记 todoLinked）
        }
    }

    /// v3.0.81：上下文使用率指示器（独立计算属性——含嵌套三元+插值，抽离防 body type-check 超时）
    private var contextUsageBar: some View {
        Group {
            if chat.contextInfo.count > 10 {
                let usage = chat.contextUsage(maxTokens: ContextTuning.threshold)
                let percent = Int(usage * 100)
                let levelColor: Color = percent > 80 ? .red : (percent > 50 ? .orange : .green)
                HStack(spacing: 4) {
                    Spacer()
                    Circle()
                        .fill(levelColor)
                        .frame(width: 6, height: 6)
                    Text("\(percent)%")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                    Text("\(chat.contextInfo.tokens) tokens")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, Spacing.xxs)
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
                .font(.system(size: Typography.headline, weight: .semibold))
                .foregroundStyle(sel ? Color.blue : Color.secondary.opacity(0.55))
                .background(Circle().fill(Color(uiColor: .systemBackground)).padding(-1.5))
                .padding(.trailing, Spacing.sm)
                .padding(.top, Spacing.xxs)
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
        Haptics.selection()
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
                    .font(.system(size: Typography.body, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
            Text("已选 \(selectedMsgIDs.count) 条")
                .font(.system(size: Typography.subhead, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button {
                exitSelectMode()
            } label: {
                Text("取消")
                    .font(.system(size: Typography.body, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
            Button {
                mergeAndShare()
            } label: {
                Text("合并发送")
                    .font(.system(size: Typography.body, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, Spacing.md)
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
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.md)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8)
        )
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// v4.0.39：思考三点那一行（思考/等待期显示，思考气泡本体保留，v4.0.31 口径）。
    /// 几何逐字沿用原 inline 写法（灰底、圆角 Radius.card、minHeight 44、左对齐钉边），
    /// 只在外面多挂一层**浮现包装**：opacity 0→1 + 下移 8pt→0。
    /// 为什么不用 .transition/.move：三点这行的出现由 `thisSessionStreaming || remoteBusy` 翻转驱动，
    /// 那两个写入发生在 StreamClient 网络回调与 onChange 里、**不带 withAnimation 事务**，
    /// transition 在无事务时不会播放（流式气泡首帧同理，见 StreamingBubbleView.born）。
    /// reduceMotion 时 onAppear 直接落终态，不播浮现。
    private var thinkingIndicatorRow: some View {
        // 🚨 v4.0.48（真机启动闪退根治）：这串修饰器链原先整条内联进 messageList 的 LazyVStack 类型，
        //   使该类型静态嵌套达 21 层。启动首帧构建该类型时，Swift 运行时按 mangled name 解析类型，
        //   demangler（decodeMangledType↔decodeGenericArgs）递归 ~112 帧把 1MB 主线程栈吃干 →
        //   撞栈保护页 → SIGSEGV（真机 .ips 实证：EXC_BAD_ACCESS + "stack guard region"）。
        //   修法 = **类型擦除**：AnyView 把这串链从外层类型名里摘掉（21 层 → ~11 层），
        //   视图树、修饰器、动画、身份全部不变 —— 只让类型名变浅。
        // ⚠️ `.transition` / `.id` 必须留在 AnyView **外面**（前者管三点行↔流式气泡互换的退场，
        //   后者是流式区身份真源）；搬进去会改语义。
        AnyView(
            TypingIndicator()
                .padding(.horizontal, Spacing.section)
                .padding(.vertical, Spacing.xxl)
                .background(Color(uiColor: .systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(typingBorn ? 1 : 0)
                .offset(y: typingBorn ? 0 : 8)
                .onAppear {
                    if reduceMotion { typingBorn = true }
                    else { withAnimation(Motion.streamBorn) { typingBorn = true } }
                }
        )
            // 保留原 inline 块上的 .transition(.opacity)（v4.0.39 未删）：它管的是
            // 「三点行 ↔ streamingBubble」在同一 if/else 里互换时的退场淡出。
            // 浮现进场由上面的 born 包装负责，两者分工不重叠。
            .transition(.opacity)
            // 🚨 v4.0.39（审查阻断②修正）：身份必须**逐轮变**。原 `.id("streaming")` 恒定，
            // 而纯 remoteBusy 时三点行常驻屏上（探针在途/续接态，仓库自己注释说这是常见态）：
            // 此刻 startSeq 递增但行没被卸载 → onAppear 不再触发 → 上一轮点亮后又被复位成
            // opacity 0 的那一次，整轮思考期三点静默不可见（无报错、无日志，纯 UI 少一块）。
            // 改成带 startSeq 的复合身份：每轮身份变 → 强制重建 → onAppear 必触发 → 浮现必播。
            .id(streamingAnchorID)
    }

    /// v4.0.39：思考三点浮现开关（配 thinkingIndicatorRow）
    @State private var typingBorn = false
    /// v4.0.39：开「降低动态效果」时不播浮现（与 TypingIndicator 内部同口径）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// v4.0.39：流式区（思考三点行 / 流式气泡）滚动锚点 id 的**单一真源**。
    ///
    /// 为什么带 startSeq：身份逐轮变 → 每轮强制重建该行 → onAppear 必触发 → 浮现动画必播
    /// （恒定 id 在纯 remoteBusy 常驻屏时会吞掉 onAppear，见 thinkingIndicatorRow 处的阻断②注释）。
    /// 为什么必须是单一真源：本轮之前 id 字符串在**三处**各写一份（`.id` ×2 + `scrollTo` ×1），
    /// 改一处忘另两处 → scrollTo 找不到锚点 → 贴底静默失效（v4.0.37 刚修过这个病）。
    private var streamingAnchorID: String { "streaming-\(stream.startSeq)" }

    /// v3.0.15：流式输出气泡——拆独立计算属性（防 messageList 巨型 body type-check 超时）
    /// v3.9.40（#3）：真正渲染交给 StreamingBubbleView——displayContent 每 48ms 的写入只失效那条气泡，
    /// 不再让 ChatView.body（连同整份 LazyVStack 消息列表）跟着逐 tick 重画。
    @ViewBuilder
    private var streamingBubble: some View {
        StreamingBubbleView(
            onAIImageTap: { url in openAIImage(url) },   // v2.0.128：流式中 AI 图片可点（参数须在 streamingAvatar 前）
            onFileTap: { url, name in openAIFile(url, name) }   // v3.9.17：流式中 AI 生成物可点
        )
        .id(streamingAnchorID)   // v4.0.39：与三点行同一身份真源（scrollBottom 也滚它）
    }

    /// 顶部「加载更早」按钮（v4.0.49：从 LazyVStack 内容里抽成不透明属性 —— 原来这条
    /// Button/HStack/Image/Text/background(Capsule) 链**内联**在 messageList 的类型名里，
    /// 给启动期 demangler 递归多塞 ~350 字符，抽出来名字里只剩一个 Qo 引用）
    private var loadEarlierButton: some View {
        Button {
            withAnimation(Motion.snap) {
                displayLimit += Self.loadMoreStep
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "chevron.up")
                    .font(.system(size: Typography.tiny, weight: .semibold))
                Text("加载更早 \(min(visibleStartIndex, Self.loadMoreStep)) 条")
                    .font(.system(size: Typography.subhead, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, Spacing.md)
            .padding(.horizontal, Spacing.xxl)
            .background(Color.secondary.opacity(Tint.faint), in: Capsule())
        }
        .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
        .padding(.bottom, Spacing.xxs)
    }

    private var messageList: some View {
        ZStack {
            // v2.0.40：clearing 期间直接显示欢迎页（列表已卸载，数据稍后清空）
            // v3.9.30：容器挂 settle —— 驱动 welcome/列表 if 切换的浮现过渡（transition 需同帧动画）
            if (chat.messages.isEmpty || clearing) && !thisSessionStreaming {
                welcomeView
                    // v4.0.49：frame/id/transition 折进具名 ViewModifier —— 这三条原来内联在
                    // messageList 的类型名里（~210 字符）；折后名字里只剩组名。id/transition 仍作用在
                    // 同一个 welcomeView 上（身份真源与浮现过渡语义不变）。
                    .modifier(WelcomeBranchChrome(host: self))
                    // v4.0.75：空会话（欢迎页态）手动发起直播 → 卡也贴在欢迎页下方，否则「点了没反应」
                    if let s = browserLiveSession {
                        BrowserLiveView(session: s, auth: auth, onClose: closeBrowserLive)
                            .padding(.horizontal, 6)
                    }
            } else {
            ScrollViewReader { proxy in
                // v3.9.58c：把 proxy 挂到 @State，供引用块跳转等非 onChange 路径滚动定位。
                // onAppear 一次性写回（body 重算不重复触发写 State 循环——赋同一值无副作用）。
                ScrollView {
                // v2.0.40：LazyVStack → VStack（懒加载在批量移除时有复用状态残留，
                // 普通 VStack 全量渲染，移除只是简单数组变化，彻底绕开崩溃）
                // v2.0.132：VStack → LazyVStack——清空/新建已走两步走（先切欢迎页卸载
                // 列表再清数据），批量移除崩溃路径不复存在；长聊天记录仅渲染可见气泡，
                // 修复长文本滑动/左右切页卡顿
                LazyVStack(spacing: 10) {
                                        // v3.0.51 A2：顶部"加载更早"按钮（会话长于可见窗口时显示）；v4.0.49 抽出到 loadEarlierButton
                                        if visibleStartIndex > 0 {
                                            loadEarlierButton
                                        }
                                        ForEach(visibleMessagesCache) { entry in
                                                                    // v3.0.51：整行（日期分隔 + 时间分隔 + 气泡）拆辅助函数，ForEach 内只留薄调用
                                                                    // v3.4.2：吃 entry 快照（含 prevMsg），渲染不触碰可变 chat.messages
                                                                    messageRow(entry: entry)
                                                                }
                        toolStepCards
                        // v3.9.39 A1：按会话收窄——stream 是 App 级单例，本仓另四处
                        // （aiBusy / liveActivityCanStop / toolStepCards / DockTabView:chatVisible）
                        // 都带 `currentStreamSessionId == chat.sessionId`，只这一处漏了 →
                        // 切到 B 会话后 A 的回答在 B 底下逐字长出来（串话实报的第一现场）。
                        // v3.9.41：这四处统一走 `thisSessionStreaming`（此处判定与之完全等价）。
                        // 轮询不受影响：切回 A 时条件重新成立，气泡与打字机原样接回。
                        // v4.1.x（2026-09-30 真机实报「整个气泡压根不出现」）：条件与 `aiBusy` 对齐。
                        // 只认本地流会漏掉「服务器有在途任务、本地被 `!stream.isStreaming`（3253 行）
                        // 挡着没接回」这一态：胶囊/灵动岛按 aiBusy 显示「AI 正在输入」，聊天流里却一个气泡都没有。
                        // remoteBusy 由**本会话**探针写入、切会话时已复位 → 不会串会话。
                        if thisSessionStreaming || remoteBusy {
                            // ⚠️ 纯 remoteBusy 时**必须**显示思考气泡：此刻 stream.content 可能是别的会话/
                            // 上一轮的残留，拿去渲染就是串话（本仓实报过）。
                            // 🚨 发布前审查拦下（2026-09-30）：这两条分支**写反过一次**——条件原先写成
                            // `thisSessionStreaming && !stream.content.isEmpty`，而该分支体里是三点，
                            // 于是「本地流式且有内容」时全程只显示三点、整段回答到收尾才蹦出来；
                            // 首帧（content 为空）与纯 remoteBusy 反而去渲染 streamingBubble（拿残留内容当本轮 = 串话）。
                            // 口径：**有真内容才渲染内容**；无内容（首帧）与纯 remoteBusy 一律三点。
                            if !thisSessionStreaming || stream.content.isEmpty {
                                // 思考中动画（三点跳动，气泡加大版）
                                // v3.0.15：恢复 v3.0.12 之前的原始三点动画（思考球 orbits 粒子已移除，改由输出头像承担粒子球）
                                // v3.0.18：思考期头像也改为粒子球（38pt，用户要求全程粒子球头像）
                                // v4.0.32：思考期头像也删（用户复看截图拍板「AI头像还在」= 三点气泡旁 38pt 宠物一并删；
                                // 原 v3.9.78 思考宠物、v4.0.31「思考气泡保留」口径中的气泡=三点本体，头像不留）
                                // v4.0.33：左对齐钉回——LazyVStack 默认 center 对齐，删掉头像/宠物后本行没有
                                // maxWidth 无穷的 frame 拉满（普通气泡靠这个贴边），三点气泡被居中挂在中轴
                                //（真机截图实报）。与 messageRow 同款 `.frame(maxWidth: .infinity, alignment: .leading)`。
                                thinkingIndicatorRow
                            } else {
                                streamingBubble
                            }
                        }
                    }
                    // v4.0.75：浏览器直播卡（Muse 式）——画面嵌在消息流末尾，聊天照常可打字指挥；
                    // 点 × 走 closeBrowserLive()（镜像 + Center 源一起清，防 onReceive 重建重弹）。
                    // v4.0.76 CI 实抓：直播卡的 if 与下面的 .padding 之间隔了 LazyVStack 其它成员，
                    // .padding 落不到 if 表达式上（instance member 'padding' cannot be used on type 'View'）→ 括回 Group。
                    Group {
                        if let s = browserLiveSession {
                            BrowserLiveView(session: s, auth: auth, onClose: closeBrowserLive)
                        }
                    }
                    // v3.9.27：气泡变长——消息区左右 padding 12→6（气泡 maxWidth 369 联动）
                    // v4.0.48：三条 padding（水平 6 / 上 md / 下 md）合并成一条 —— 类型名少两层，
                    // 给启动期类型解析留栈余量；视觉完全等价（同边同值）。
                    .padding(EdgeInsets(top: Spacing.md, leading: 6, bottom: Spacing.md, trailing: 6))
                    // v4.0.34：内容不满一屏时的对齐口径。原为 `.bottom`（微信式贴底：不足的高度
                    // 全留在列表顶部，最新气泡紧贴输入框上方）。
                    // 🚨 v4.0.54（用户 2026-10-05：「第一条气泡就是在最上，后面的气泡不断往上挤」）：
                    // 翻成 **`.top`** —— 新会话第一条气泡出现在**屏幕最上方**，后面的依次往下堆；
                    // 排满一屏后自然上翻（旧气泡被往上挤）。frame 高度仍取滚动容器测量值
                    // （GeometryReader 只读布局，不撑高 ScrollView 自身），minHeight 语义 =
                    // 「不满屏时占满、超屏时自然增长」；满屏后行为与改前完全一致
                    // （不影响上翻历史/加载更早/贴底检测）。
                    // 别再改回 .bottom —— ql_scrollpin 真值表已把 `.top` 钉住（其余「贴底」指的是
                    // 滚动贴底判定，与这里的对齐无关）。
                    .frame(minHeight: chatListViewportH, alignment: .top)
                    .id("messages")   // v2.0.39：与欢迎页分支区分身份
                }
            .modifier(MessageListScroll1(host: self, proxy: proxy))
            .modifier(MessageListScroll2(host: self, proxy: proxy))
            .modifier(MessageListScroll3(host: self, proxy: proxy))

        }
        }
        }
        .modifier(MessageListChrome1(host: self))
        .modifier(MessageListChrome2(host: self))
        .modifier(MessageListChrome3(host: self))
        .modifier(MessageListChrome4(host: self))
        .modifier(MessageListChrome5(host: self))
        .modifier(MessageListChrome6(host: self))
        // v2.0.36：录音权限被拒提示
    }

    /// 思考中动画（三点跳动）
    struct TypingIndicator: View {
        // v3.9.19：无障碍——「降低动态效果」时不做循环脉冲
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            // v4.0.12 根治「圆点脉冲自己消失」（用户 2026-09-30 真机实报）：改 TimelineView 驱动。
            // v4.0.14（再报）：抬强度下限 + 切祖先动画事务继承。
            //
            // v4.0.19（用户 2026-10-01 三报「动画动一段时间就会消失」）：前两版都没根治，真根因在
            // **调度本身**——`.animation` 是官方文档定义的「pausable schedule」（可暂停调度）：
            // 只在系统判定「有动画内容在跑」时全速 tick，子树没有 Core Animation 活动时会被
            // 降频甚至暂停（OpenSwiftUI 实现注释「Respects system animation settings」）。
            // 而这三颗点是 TimelineView 自己驱动的——系统看「没有活动动画」→ 停时钟 →
            // 三点凝在某一帧 → 肉眼「动一会儿就停了/消失」。根治：换 `.periodic` 墙钟调度，
            // 官方契约「updates at regular intervals」永不暂停，与系统动画状态无关。
            // 相位仍由时间戳直接算出（丢帧后下一帧相位自动正确，v4.0.12 的核心优点保留）；
            // 周期/错相与旧版一致（1.2s 全周期 + 每颗错相 0.18s）；强度下限 0.62 保留
            //（主线程抢占丢帧时那一帧仍看得见）；reduceMotion 直接渲染静止满点（periodic 无 paused 参数）。
            if reduceMotion {
                dotRow(timeline: nil)
            } else {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                    dotRow(timeline: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }

        /// 三颗点一行。timeline = 当前墙钟秒数；传 nil = reduceMotion 静止满点。
        private func dotRow(timeline: Double?) -> some View {
            HStack(spacing: Spacing.xs) {
                ForEach(0..<3, id: \.self) { i in
                    // v3.4.20：三点跳动 → 蓝紫渐变脉冲圆（与发送按钮/Siri 流光同语言，"AI 活着"统一视觉）
                    // 波形：|sin| 三角化成 0→1→0 脉冲，周期 1.2s（= 旧版 0.6s easeInOut 往返），
                    // 每颗相位错开 0.18s；上限 1.0 = 旧版高点（不动），下限 v4.0.14 由 0.45 抬到 0.62。
                    let pulse = timeline.map { t in
                        abs(2.0 * ((t + Double(i) * 0.18)
                            .truncatingRemainder(dividingBy: 1.2) / 1.2) - 1.0)   // 1→0→1
                    }
                    let strength = pulse.map { 0.62 + 0.38 * (1.0 - $0) } ?? 1.0
                    Circle()
                        .fill(LinearGradient(colors: [.blue, .indigo, .pink],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 8, height: 8)
                        .scaleEffect(0.55 + 0.45 * strength)
                        .opacity(strength)
                }
            }
            // v4.0.14：切断祖先动画事务的继承。宿主的 withAnimation / .animation(_:value:) 都在
            // 更上层，逐帧新值可能被上一事务插值/跳过 → 帧在走、画面不动。只清本子树隐式动画，
            // periodic 逐帧直接给值，动画观感不受影响。
            .transaction { $0.animation = nil }
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
            .font(.system(size: Typography.caption))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
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
            .font(.system(size: Typography.caption, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.xs)
            .background(Color.primary.opacity(Tint.faint), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xs)
    }

    /// v3.0.86 fix：滚底可关内层动画——流式高频 delta 下 withAnimation 每帧重启互相打断，
    /// 流式路径用 animated: false（贴底滚动瞬时完成）；消息 append（用户发送）保留轻动画
    private func scrollBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            // v3.9.41：`.id("streaming")` 那条气泡只在**本会话**有流时才存在（messageList 已按会话收窄）→
            // 判定必须同源，否则 A 在跑时 B 里滚底会 scrollTo 一个不存在的 id（停在半空、不落最后一条）。
            // v4.0.37（2026-10-03 真机「贴底没效果」复查）：这条判据原先只认 thisSessionStreaming，
            // 但 `.id("streaming")` 那行**存在**的条件是 `thisSessionStreaming || remoteBusy`（2564 行）——
            // 纯 remoteBusy（服务器在途、本地尚未接回）时那行就是三点气泡，旧写法却回落去滚
            // `chat.messages.last`（用户自己那条，位置在三点**上方**）→ 气泡一路沉到输入栏下面。
            // 与渲染条件同源：行在就滚行。
            if thisSessionStreaming || remoteBusy {
                // v4.0.39：id 与三点行/流式气泡的 .id 保持**逐字一致**（含 startSeq 后缀）。
                // ⚠️ 两处曾经不一致的代价：三点行身份改成 "streaming-<seq>" 而这里还滚 "streaming"
                // → scrollTo 找不到锚点 → 贴底静默失效（v4.0.37 刚修好过一次）。
                // 抽成单一真源，别再各写一份字符串。
                proxy.scrollTo(streamingAnchorID, anchor: .bottom)
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
        // v3.9.41：改为只被**本会话**自己的流挡住。原来 A 在跑时这里静默 return，
        // B 里点「AI 总结会话」毫无反应（连排队都不排）；收窄后走 sendCore，单例被占用时正常入队。
        guard !thisSessionStreaming else { return }
        sendCore(text: "请用简洁的要点总结我们这次对话（分点列出，突出结论和待办）", imageData: nil)
    }

    /// v3.0.86 fix：统一「确认发送」路径——pendingSend 解包 → 清输入框/图片 → 图片持久化 → sendCore。
    /// 原长上下文弹窗「压缩后发送/直接发送」与自动压缩完成后三份重复拷贝，抽此统一（后续改一处即可）
    /// - Parameter allowExpense: v4.0.x 复核补：这条路径是「用户亲手点发送」的**后半程**
    ///   （长上下文弹窗「压缩后发送 / 直接发送」+ 自动压缩完成后自动发），却没往下传闸 →
    ///   同一句话在弹窗/压缩路径上不记账、在直发路径上记账，用户会以为记账时好时坏。
    ///   调用方（send()）传 true；预检有计数断言钉住「全仓只允许那 2 处传 true」。
    private func sendPendingNow(_ p: (text: String, imageData: String?), allowExpense: Bool = true) {
        pendingSend = nil
        inputText = ""   // v2.0.102：确认发送才清空（取消保留草稿）
        pendingImage = nil
        pendingImageData = nil
        if p.imageData != nil {
            // v3.0.37：图片持久化
            Task {
                let persisted = await persistImageIfNeeded(p.imageData)
                sendCore(text: p.text, imageData: persisted, allowExpense: allowExpense)
            }
        } else {
            sendCore(text: p.text, imageData: nil, allowExpense: allowExpense)
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
        // v3.9.9 收口：新的一轮开始 → 先停掉上一轮朗读（v3.9.8 原有行为，上一版被我删掉了）。
        // 注意**不能**挂到 `aiBusy` 变 true 上无脑停：aiBusy = 本机流 ‖ 云端流 ‖ 服务器探针，
        // 切会话/探针抖动都会跳变，会把用户手动点的朗读掐断；挂在"用户真的发起新一轮"这个点最准。
        SpeechManager.shared.stop()
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

        // v3.0.81：上下文自动管理（v4.0.x：阈值真源 = ContextTuning，别再在本文件写死 6000）
        let autoCompress = UserDefaults.standard.bool(forKey: "qingliao_context_auto_compress")
        let effectiveThreshold = ContextTuning.threshold

        if autoCompress && chat.needsCompress(threshold: effectiveThreshold) {
            // 自动压缩：先显示提示，后台执行 AI 摘要
            pendingSend = (text, img)
            showCompressingAlert = true
            let sidAtCompress = chat.sessionId
            Task {
                let success = await chat.compressContextWithAI(auth: auth)
                showCompressingAlert = false
                if success {
                    await chat.saveToServer(auth: auth)
                }
                // 压缩完成后发送
                if let p = pendingSend {
                    // SR3：压缩期间用户可能已切到别的会话——不能把 A 的草稿发进 B。
                    // 这条分支里 inputText 从未清空，撤回自动发送即可：草稿还在输入框，由用户重发。
                    if chat.sessionId == sidAtCompress {
                        sendPendingNow(p)
                    } else {
                        pendingSend = nil
                    }
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
                sendCore(text: text, imageData: persisted, quotedText: quotedText, allowExpense: true)
            }
        } else {
            sendCore(text: text, imageData: nil, quotedText: quotedText, allowExpense: true)
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
                .font(.system(size: Typography.body))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("会话内容较多")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                Text("\(chat.messages.count) 条消息 · 建议归档导出以省存储")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("归档") { showExportSheet = true }
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.sm)
                .background(Color.orange)
                .clipShape(Capsule())
            Button {
                withAnimation { showArchiveHint = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Typography.caption, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .background(.ultraThinMaterial)
        .overlay(RoundedRectangle(cornerRadius: 0).stroke(Color.orange.opacity(Tint.strong), lineWidth: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .shadow(color: .black.opacity(Tint.faint), radius: 8, y: 3)
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.md)
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

    /// v4.0.x 一句话记账全 App **唯一的发送收口**，但**默认不记账**（`allowExpense = false`）。
    ///
    /// 🚨 v4.0.x 修：原来记账无条件挂在 sendCore 上，而 sendCore 同时是分享收件（`drainShareInbox`）、
    /// 任务中心文本（`.qingliaoTaskSend`）、备忘正文「发给 AI」（`.qingliaoMemoSend`）的收口。
    /// ChatRecordKit 的门挡得住「订单/快递/体重」，却挡不住**纯金额句** ——
    /// 分享一段预算文档里的「预算 5000」、备忘里的「房租 2000」会被静默写进账本，
    /// 而且用户压根没提「记账」→ 错账 + 零提示。
    /// 正解：只有**用户亲手在输入栏点发送**的那条路径传 `allowExpense: true`；
    /// 重试（:3902）与所有转发/收件路径保持默认 false（转发用户已说过的话不是新的消费意图）。
    func sendCore(text: String, imageData: String?, quotedText: String? = nil, allowExpense: Bool = false) {
        // v3.4.x：同内容短时间幂等（60s 内相同文本+同会话只发一次，防抖动/重试/恢复重复投递）
        // v3.4.27 fix：比较须含 image 指纹——纯图 text 恒空，只比 text 会把 60s 内第二张纯图误判重复丢弃（拍照/相册连发纯图被吞）
        let now = Date().timeIntervalSince1970
        // v4.0.10：幂等只对**自动路径**（重试/分享收件/恢复投递）生效——`allowExpense` 已是
        // 「用户亲手在输入栏点发送」的唯一标记（见上方口径）。用户亲手发的永不去重：60s 内重复
        // 发同一句是正当行为，旧实现把它静默丢掉（零提示、不上屏）＝「点了发送没反应」。
        if let last = lastSentSignature, last.sessionId == chat.sessionId, last.text == text,
           last.image == imageData, now - last.ts < 60, !allowExpense {
            NSLog("[SEND] 幂等丢弃（自动路径，60s 内同内容）")
            return
        }
        lastSentSignature = (chat.sessionId, text, imageData, now)
        // v3.0.52：蜂窝下 base64 图 body 过大 → 先超强压缩（uploadImage 蜂窝大概率失败退回 base64 大 body，
        // 导致 CFStream/relay 载不动 → 后端 bad json 400；压小后直连可过）
        let imageData = compressForCellular(imageData)
        guard !text.isEmpty || imageData != nil else {
            NSLog("[SEND] 空内容丢弃")
            return
        }
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
                        withAnimation(Motion.settle) {   // v3.9.0：动效令牌收口（原 spring 0.25/0.15）
                            chat.append(m)
                        }
                        pendingQueue.append(PendingSend(text: c, imageData: nil, sessionId: chat.sessionId))
                        persistPendingQueue()
                    }
                    Task { await chat.saveToServer(auth: auth) }
                    return
                }
            }
        }
        // v4.1.x 多会话并行（2026-09-30 用户实报修正）：单例在跑、但跑的是**别的会话**的流时不再排队——
        // 把那条流移交后台跑流器继续轮询（服务端任务不停），本条立即开跑。
        // 实报现象：两个会话同时跑时，第二条上屏后顶着「排队中」，要等前面整轮跑完才轮到它。
        // 这条口径在「新建会话」路径早已落地，发送路径漏了同一口（后端实测真并行、按 sessionId 隔离）。
        if stream.isStreaming {
            // 移交不出去（异常态：无 taskId/无归属会话）或流就属于本会话（同一会话连发，并发会串上下文与落库）
            // → 退回排队老路
            if !handoffRunningStreamToBackground() {
                // ⚠️ 这里的 isStreaming 刻意是**全局**的（不是 thisSessionStreaming）：单例只有一条流。
                // 排队消息由 `pumpPendingQueue()` 在**任意一条**流收尾时接走，包括收尾时用户已在别的会话。
                // 排队路径：消息立即显示（标记排队中），回答结束后自动发送
                var msg = ChatMessage.local(role: "user", content: text, imageDataURL: imageData)
                msg.quotedText = quotedText
                msg.queued = true
                withAnimation(Motion.settle) {   // v3.9.0：动效令牌收口（原 spring 0.25/0.15）
                    chat.append(msg)
                }
                // v4.0.x 一句话记账：排队路径也要记（用户在别的会话等回答时发的这句照样得进账本），
                // 卡片插在用户气泡之后、AI 回话之前 —— 顺序 = 用户话 → 记账卡 → AI 确认
                if allowExpense { noteChatExpenseIfMatched(text: text, imageData: imageData) }
                pendingQueue.append(PendingSend(text: text, imageData: imageData, sessionId: chat.sessionId))
                persistPendingQueue()
                Task { await chat.saveToServer(auth: auth) }
                return
            }
        }
        // 双击保护：第一次发送的流尚未置位时，第二次直接忽略。
        // ⚠️ v4.0.10：不许写成「无窗口上限的硬锁」——锁可能等不到解锁回调（见 sendingLockAt 注释），
        // 一旦泄漏就是「发出去不上屏 + 后端零请求」的永久故障。窗口 0.8s：够挡双击，又短到不误伤连发。
        if sendingLock {
            if now - sendingLockAt < 0.8 {
                NSLog("[SEND] 双击拦截（锁龄 \(String(format: "%.2f", now - sendingLockAt))s）")
                return
            }
            NSLog("[SEND] 发送锁超窗自动解锁（锁龄 \(String(format: "%.2f", now - sendingLockAt))s）")
            sendingLock = false
        }
        // v4.0.42 待做池 ①：新一轮提问前清掉旧候选区（护栏⑥：新提问清空候选，
//     别让上一轮的候选留在老回答下面误导点）。
        clearAllSuggestions()
        sendingLock = true
        sendingLockAt = now
        Haptics.tap()   // v3.4.25：统一触感
        // v2.0.65 原注释写「发送通知 → Dock 聊天图标轻跳」，但全仓**没有任何 onReceive 收这条通知**
        //（v4.0.x 复核核实：只有这里发、0 处收）——即这条通知自 v2.0.65 起就是空发，图标轻跳从未生效。
        // 保留 post 是为了不破坏潜在外部观察者；注释改成如实口径，别再把它当已有功能。
        NotificationCenter.default.post(name: .qingliaoSent, object: nil)
        var msg = ChatMessage.local(role: "user", content: text, imageDataURL: imageData)
        msg.quotedText = quotedText
        // v2.0.59：单条插入动效（批量移除才崩，插入安全）
        withAnimation(Motion.settle) {   // v3.9.0：动效令牌收口（原 spring 0.25/0.15）
            chat.append(msg)
        }
        // v4.0.x 一句话记账（口径 1a）：卡插在用户气泡之后（顺序 = 用户话 → 记账卡 → AI 回话）。
        // 放在 append 之后是为了会话里的先后顺序；放在 saveToServer 之前是为了同一份快照把卡一起落库。
        // ⚠️ 上面的「长文本 relay 分段」分支不需要另挂：记账只认 ≤24 字的短句，永远进不到那一段。
        if allowExpense { noteChatExpenseIfMatched(text: text, imageData: imageData) }
        // v3.3.0 fix：消息落盘必须在 append 后立即执行（不能依赖流式回答后才 saveToServer）。
        // 否则 App 被杀/网络断开/流式失败时，用户刚发的消息只存在内存里，丢了。
        Task { await chat.saveToServer(auth: auth) }
        startStream(for: msg)
    }

    /// v2.0.88：启动流式回答（消息已在列表；失败标记/回复完成/队列联动统一在这里）
    /// v2.0.102：记录发起会话——回答期间切换会话则丢弃结果（防跨会话污染）；完成回调释放 sendingLock
    func startStream(for msg: ChatMessage) {
        // v3.9.41（SR58）：接上看门狗面包屑（原先 HangWatchdog.breadcrumb 零调用点 → 上报里
        // 「卡顿前主线程干过什么」永远只有前后台切换两条）。只记动作名，不记内容/凭据。
        // 选这里：下面 historyPayload 会在主线程同步跑完整历史的净化与压缩，长会话最容易卡。
        HangWatchdog.breadcrumb("发起生成（历史 \(chat.messages.count) 条）")
        // v3.4.10 X方案：发「断种子净化完整历史」给后端（不再只传当前消息）。
        // 后端 _build_hermes_messages 对完整历史再做 _sanitize_history/_compress_long_assistants/
        // _break_repeat_seed，并去掉 X-Hermes-Session-Id（不再让 Hermes 用 state.db 重建未净化会话）。
        // 上下文=净化历史 → 不复读；且保留 app 按会话选模型 + 图片 + 流式。
        // v3.0.81：统一模型优先级链（视觉 > Agent > 主模型）
        let (useModel, useProvider) = resolveModel(hasImage: msg.imageDataURL != nil)
        // v3.9.15：把真实请求模型交给历史净化——断种子占位的闸门必须与实际请求同源
        let history: [[String: Any]] = chat.historyPayload(model: useModel, provider: useProvider)
        let startSid = chat.sessionId
        // v3.9.39 A1：发起时的会话快照。用户在回答期间切走时，chat.messages 已是别的会话的，
        // 收尾的答案既不能 upsert 进当前会话（串会话），也不该直接丢弃（「答案消失」）——
        // 拿这份快照落回**它自己的**会话。
        let startMsgs = chat.messages
        let startTitle = chat.title

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
                // v3.9.39 A1：原 `guard chat.sessionId == startSid else { return }` 一刀切丢弃，
                // 切走期间完成的答案两头不落（A 里没有、B 里不该有）＝「答案消失」实报。
                // 改成落回发起时的会话：不碰 chat.messages（那是别人的会话），走参数化串行写链。
                // 刻意不做：不自动重试（要不要重来由用户回到该会话自己决定）、不 bump
                // assistantLandedToken（朗读只念当前会话刚落库的回复）。
                if chat.sessionId != startSid {
                    // v3.9.41（A1 遗留 · 「切到 B 就发不出消息」的根因）：队列在这条分支里也必须排空。
                    // 单例刚被 A 占着，B 的消息当时只能进队列；原来这个 return 跳过了下面唯一的排空点
                    // → B 的消息顶着「排队中」一直挂着，要等退出再进聊天页（onAppear 那条）才会发出去。
                    // 放在收尾这一帧同步做，不观察 isStreaming：DockTabView 有明文教训——续发会在
                    // 同一帧把它设回 true，onChange 看到 true→true 会整轮跳过。
                    // v3.9.41（SR60）附带修正：这里的排空现在按会话归属过滤（只发 B 的），
                    // 不再依赖「切会话必然清空队列」这个旧前提——A 自己没发完的条目留在队列里等回到 A。
                    defer { pumpPendingQueue() }
                    let body = stream.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if success {
                        guard !body.isEmpty else { return }   // 空回复不落（提示语要落在眼前才有效）
                        landAwayReply(body, agent: stream.isAgent,
                                      snapshot: startMsgs, sid: startSid, title: startTitle)
                    } else {
                        let note = "⚠️ " + Self.friendlyStreamError(error)
                        landAwayReply(body.isEmpty ? note : body + "\n\n" + note, agent: stream.isAgent,
                                      snapshot: startMsgs, sid: startSid, title: startTitle)
                    }
                    return
                }
                if !success {
                    // v3.4.x：网络类错误自动重试（连接中断/超时/无法连接），限流/用户停止/业务失败不重试
                    if self.isRetryableStreamError(error) {
                        chat.markFailed(id: msg.id)   // 先标记（失败态显示），SR20：重试成功后 clearFailed 撤掉
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
                    // v4.0.42 待做池 ①：回答已落地 → **异步**拉追问候选（后端 0~3 条，空数组合法）。
                    // 必须在这之后（候选挂在刚落库的回答下面）；必须异步：多一次模型调用，
                    // 同步做会把气泡上屏拖慢。失败/没候选一律静默，不出声不占位。
                    fetchFollowUpSuggestions(afterUserID: msg.id, batch: 0)
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
                pumpPendingQueue()
            }
        }
    }

    /// v3.9.39 A1：把迟到的回复落回**发起时**的会话（用户已切走，chat.messages 是别的会话的）。
    /// 快照末条就是这轮的 user 消息（sendCore 先 append 再 startStream），追加一条 assistant
    /// 等价于 upsertAssistant 的「插到该轮回复区末尾」。写库经 ChatStore 的 FIFO 串行链，
    /// 一定排在切走前那次快照写之后 → 不会被旧数组盖掉。
    /// 失败态（failed）不落库：`writeSessionSnapshot` 本就不持久化 failed，重进会话时也会从服务器
    /// 重取，标了也只是切回去那一瞬可见，反而误导「重试按钮在别处能用」。
    /// SR12：改 internal —— ChatViewExport.swift 的 regenerate/sendFile 同族路径也要用（extension 跨文件够不到 private）。
    /// 🚨 v4.0.57（同族收口）：落库改走链内 `appendMessageToOwnedSession` —— **不再拿发起时快照整会话覆盖**。
    /// 旧写法（`snapshot + 回复` 整份写）在「切走 → 这条回复落地」的间隙里，会把期间落进该会话的
    /// 其他写者内容（收件箱推送 / 其他端）一起抹掉。`snapshot` 参数降级为**回落兜底**：
    /// 只有链内发现「服务端查不到该会话」时才用它（口径同 v4.0.21 注释：宁可回落，绝不丢消息）。
    func landAwayReply(_ text: String, agent: Bool, snapshot: [ChatMessage],
                       sid: String, title: String) {
        var m = ChatMessage(role: "assistant", content: text,
                            timestamp: Date().timeIntervalSince1970 * 1000)
        m.agent = agent
        chat.noteAwayLandedReply(sessionId: sid, text: text)
        Task {
            // `dedup: .authoritativeReply` = 权威原文口径（见 ChatStore.OwnedAppendDedup）：
            // 只认「规范化后相等 / 新文本是已有文本的前缀」，不用推送侧宽口径 ——
            // 宽口径的 `core.contains(cm)` 会把「新回答包含旧回答」判成重复 → 这条迟到回复不落库、只活在内存。
            let outcome = await chat.appendMessageToOwnedSession(m, sessionId: sid, auth: auth,
                                                                dedup: .authoritativeReply,
                                                                fallbackTitle: title)
            if case .targetMissing = outcome, !snapshot.isEmpty {
                // 回落兜底前**正向确认**服务端真没有这条会话（列表读失败 ≠ 不存在，见 ChatStore
                // `writeBackSnapshotIfSessionAbsent`）：网络抽风时整份写会把期间的推送内容盖掉。
                var msgs = snapshot
                msgs.append(m)
                await chat.writeBackSnapshotIfSessionAbsent(sessionId: sid, messages: msgs,
                                                           title: title, auth: auth)
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
        // SR2：接回路径也会「在 await 期间被切会话追上」。原来回调无条件写 chat.messages
        // 并用无参 saveToServer（= 当下会话快照）→ A 的答案整会话覆盖掉 B 的历史。
        // 与 startStream 的 A1 分支同口径：切走了就落回发起时的会话，绝不写进眼前的会话。
        let startSid = chat.sessionId
        let startMsgs = chat.messages
        let startTitle = chat.title
        await stream.restoreIfNeeded(auth: auth, sessionId: chat.sessionId) { success, err in
            // v3.3.3：恢复的旧回答锚定回发起 user 消息，不 append 到用户新消息后
            let anchor = stream.pendingUserMsgId
            let body: String
            if success {
                // v3.5.1：恢复回来的任务内容为空 → 明确提示（原来静默落一条空消息）
                body = stream.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? Self.emptyReplyNote : stream.content
            } else {
                body = stream.content.isEmpty ? "⚠️ \(err)" : stream.content + "\n\n⚠️ \(err)"
            }
            if chat.sessionId == startSid {
                chat.upsertAssistant(body, agent: stream.isAgent, afterUserID: anchor)
                Task { await chat.saveToServer(auth: auth) }
            } else {
                landAwayReply(body, agent: stream.isAgent,
                              snapshot: startMsgs, sid: startSid, title: startTitle)
            }
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
            // v3.9.1：App 进后台时跳过本轮探针——`.task` 只在视图销毁时取消（后台不销毁视图），
            //          此前后台仍每 6s 发一次请求：既耗电，又是一次大概率超时的无效调用。
            //          回前台后自动恢复（scenePhase 变 active，循环下一轮继续探测）。
            if scenePhase == .active {
                await probeRemoteBusy()
            }
            try? await Task.sleep(for: .seconds(6))
        }
    }

    /// 服务器侧真相（v3.5.2 重写）：**服务器才是唯一真相来源**，本机标记只用于"抢先显示"。
    ///
    /// 旧逻辑以「本机还有持久化标记」为前提：没有标记就直接收起状态，连服务器都不问。
    /// 但 finish()（弱网连败 / 收尾）会清掉标记，而服务器侧任务仍在跑 → 前台一点提示都没有，
    /// 用户以为 AI 停了、答案也回不来（2026-09-11 实报）。现在无条件问服务器，再按结论决定接回。
    private func probeRemoteBusy() async {
        // v3.9.41：只有**本会话**在收本地流时才不必问服务器（并把 remoteBusy 强归 false）。
        // 原来是全局判定 → A 在跑时 B 的探针整个被短路，B 若在别的设备上还有在途任务，
        // 「AI 正在输入」提示和答案接回全都不会发生。
        if thisSessionStreaming { remoteBusy = false; return }
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
            let r = try await auth.streamRecover(sessionId: sid)
            let tid = r.taskId
            let rContent = r.content
            let done = r.done
            let status = r.status
            let alive = (tid?.isEmpty == false) && !done && status == "streaming"
            remoteBusy = alive
            remoteBusyFails = 0
            // ⚠️ 这里**保持**全局 `stream.isStreaming`：接回要把单例 `stream` 整个占走，
            // A 正在收流时接回 B 的远端任务 = 直接掐死 A（v3.9.41 的收窄只针对 UI 判定）。
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
        // SR2：同 resumePersistedStream——落库回调必须认会话。
        let startSid = chat.sessionId
        let startMsgs = chat.messages
        let startTitle = chat.title
        let anchor = chat.messages.last(where: { $0.role == "user" })?.id
        stream.adoptRemote(taskId: tid, content: content, sessionId: chat.sessionId, auth: auth) { success, err in
            let body: String
            if success {
                body = stream.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? Self.emptyReplyNote : stream.content
            } else {
                body = stream.content.isEmpty ? "⚠️ " + err : stream.content + "\n\n⚠️ " + err
            }
            if chat.sessionId == startSid {
                chat.upsertAssistant(body, agent: stream.isAgent, afterUserID: anchor)
                Task { await chat.saveToServer(auth: auth) }
            } else {
                landAwayReply(body, agent: stream.isAgent,
                              snapshot: startMsgs, sid: startSid, title: startTitle)
            }
        }
    }

    // MARK: - v3.4.x 消息失败自动重试（网络类错误自动重试 2 次指数退避）

    /// 判断流式错误是否"值得自动重试"——网络瞬时故障/超时类可重试；
    /// 用户主动停止/取消/限流(429)/业务失败(401/400)不重试（重试也无效或违背用户意图）。
    private func isRetryableStreamError(_ error: String) -> Bool {
        let low = error.lowercased()
        // 用户主动动作：停止/取消 → 不重试
        if low.contains("已停止") || low.contains("已取消") { return false }
        // v3.9.32：登录过期 → 不是「可重试」的网络抖动，重试只会白跑（且会拖慢正确文案出现）
        if low.contains("登录已过期") { return false }
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
        // v3.9.96 方案2：Agent 任务不自动重试。SSE 断开 ≠ 任务失败——后端 Agent 可能已在跑工具，
        // 自动重发会在服务端再起一个重复任务（用户取消时只能停掉其中一个，
        // 表象即「已取消但 AI 还在执行工具」）。Agent 模式的失败一律交给用户手动重试按钮。
        if stream.isAgent {
            autoRetryCount = 0
            chat.markFailed(id: msg.id)   // 失败态 → 显示重试按钮，由用户决定
            return
        }
        guard autoRetryCount < 2 else {
            autoRetryCount = 0   // 重试耗尽 → 复位，等手动按钮
            return
        }
        autoRetryCount += 1
        let (useModel, useProvider) = resolveModel(hasImage: msg.imageDataURL != nil)
        // v3.9.15：闸门与实际请求同源
        let history = chat.historyPayload(model: useModel, provider: useProvider)
        let startSid = chat.sessionId
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
            // SR12：回调写的必须还是**发起时**的那个会话
            let startMsgs = chat.messages
            let startTitle = chat.title
            stream.pendingUserMsgId = msg.id
            await stream.start(auth: auth, sessionId: chat.sessionId, model: useModel,
                               provider: useProvider, messages: history) { success, error in
                sendingLock = false
                // SR12：重试期间切走会话 → 眼前的会话不是发起会话，markFailed/upsert/再重试都会写错人
                //（`history` 也是按发起会话算的，递归重试等于拿 A 的上下文去请求却落进 B）。
                // 成功的回复落回 A；失败不再重试，回原会话由用户自己点重试。
                if chat.sessionId != startSid {
                    autoRetryCount = 0
                    if success,
                       !stream.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        landAwayReply(stream.content, agent: stream.isAgent,
                                      snapshot: startMsgs, sid: startSid, title: startTitle)
                    }
                    return
                }
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
                    chat.clearFailed(id: msg.id)   // SR20：请求已送达（只是答空）→ 撤 ❗
                    self.handleEmptyReply(for: msg)
                } else {
                    // SR20：自动重试复用同一条 user 消息（id 不变、不删除），成功时必须撤掉
                    // 标记失败那一帧挂上的 ❗——否则已送达的消息永久挂着「重试」，再点就是重发一遍。
                    chat.clearFailed(id: msg.id)
                    chat.upsertAssistant(stream.content, agent: stream.isAgent, afterUserID: msg.id)
                    showSentOK()
                    InboxStore.shared.triggerFastPoll()
                }
                Task { await chat.saveToServer(auth: auth) }
            }
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

    /// v4.1.x 多会话并行（发送路径接入 · 2026-09-30 用户实报修正）：
    /// 单例里正跑着的流属于**别的会话**时，把它移交 BackgroundStreamRunner（服务端任务继续跑），
    /// 本地单例腾出来给当前会话立即开跑——取代「一律排队、等前面那轮整个跑完才轮到它」。
    ///
    /// 为什么能这么干：后端实测真并行、按 sessionId 隔离（见 BackgroundStreamRunner 头注），
    /// 「新建会话」路径早已按这条口径移交，**发送路径漏了同一口** → 实报现象就是
    /// 「两个会话同时跑时，第二条上屏后显示排队中」。
    ///
    /// 不移交的两种情况（返回 false，调用方退回排队老路）：
    /// ① 流就属于本会话——同一会话并发会串上下文与落库（那正是排队该管的场景）；
    /// ② 异常态：没有 taskId / 拿不到流归属会话（无主流的移交给谁都可能写错会话）。
    @discardableResult
    func handoffRunningStreamToBackground() -> Bool {
        guard stream.isStreaming, !stream.isDone, !stream.taskId.isEmpty else { return false }
        let sid = auth.currentStreamSessionId
        guard !sid.isEmpty, sid != chat.sessionId else { return false }
        // 🚨 发布前审查拦下（2026-09-30）：该会话若**已有在跑的移交任务**，adopt 里的
        // `cancelLocal(sessionId:)` 会把那条健康任务掐掉（running 条目被移除、轮询 Task 被 cancel），
        // 本端从此等不到它的落库/通知（服务端任务仍在跑，只能靠后端推送兜底）。
        // 已在跑就按排队口径处理（返回 false，调用方退回排队老路）。
        guard !BackgroundStreamRunner.shared.isRunning(sessionId: sid) else { return false }
        // 快照口径：流属于别的会话，本端拿不到它的历史 → 传空。BackgroundStreamRunner.finish 对
        // 空快照有明文的护栏（不覆盖服务端会话，回复走 noteAwayLandedReply 迟到补回），
        // 与「切走后那轮才完成」的既有口径一致。
        BackgroundStreamRunner.shared.adopt(taskId: stream.taskId, sessionId: sid,
                                            title: "", userMsgId: stream.pendingUserMsgId,
                                            snapshot: [],
                                            offset: stream.handoffOffset,
                                            content: stream.handoffContent,
                                            auth: auth, chat: chat)
        stream.detachLocally()   // 只停本地轮询，服务端任务继续跑；落库归 runner
        // 移交后那条流的收尾回调被吞（detachLocally 把 onFinished 置 nil）→ 它的发送锁永不释放。
        // 本次发送的锁紧接着由 sendCore 重新置位，这里显式解锁防上一次的锁残留（与新建路径同口径）。
        sendingLock = false
        return true
    }

    /// v3.9.41：回答收尾 → 自动发出队列里的下一条（从 startStream 的收尾回调里抽出来复用）。
    /// 两个调用点：①本会话自己的流收尾；②**别的会话**的流收尾（用户已切走那条分支）——
    /// 那条原先直接 return，把队列留在原地，见那里的注释。
    func pumpPendingQueue() {
        // ⚠️ 闸门必须在「取出」之前：单例被别的会话占着时，原先先 removeFirst 再进 sendQueued，
        // sendQueued 的护栏只是 return（不重发）→ 这条已经从队列里没了 = 静默丢一条。
        // v3.9.41（SR60）：只派发**属于当前会话**的条目（旧数据 sessionId==nil 按当前会话对待），
        // 别的会话的留在队列/磁盘里，等用户回到那个会话或下次启动再补发。
        guard !stream.isStreaming else { return }
        guard let idx = pendingQueue.firstIndex(where: { $0.belongs(to: chat.sessionId) }) else { return }
        let next = pendingQueue.remove(at: idx)
        if sendQueued(next, resyncFromHistory: next.fromRestore) {
            persistPendingQueue()
        } else if next.fromRestore {
            // 启动恢复：这一刻服务端历史可能还没回来 → 没派发成就放回原位、也不写盘，
            // 留给下一个派发点（流收尾 / 重进聊天页）。会话内的老行为（找不到即丢）保持不变。
            pendingQueue.insert(next, at: idx)
        }
    }

    /// v2.0.88：发送排队消息（消息已上屏——去掉排队标记复用该消息启动流式，不重复插入）
    /// - Parameter resyncFromHistory: 启动恢复补发专用（SR60）。`queued` 是纯本地标记、
    ///   从不落盘（Models.swift:29 / 服务端 payload 里没这个字段），所以重启后恢复出来的条目
    ///   在历史里**永远匹配不到** queued 行 → 原实现一律走「找不到就丢弃」，
    ///   等于「杀 App/断网重启不丢排队消息」这条承诺从来没生效过。
    ///   打开后允许按内容+图片匹配一条**后面没有 assistant 回复**的 user 行（= 这条确实没被回答过），
    ///   匹配不到仍按原样丢弃（避免把已回答/已删除的消息再发一遍）。
    @discardableResult
    func sendQueued(_ item: PendingSend, resyncFromHistory: Bool = false) -> Bool {
        guard !stream.isStreaming else { return false }   // ⚠️ 必须全局：这里要抢的是单例，别的会话在跑就不能抢
        // firstIndex = FIFO：先入队的先发（内容相同也会按入队顺序）
        if let idx = chat.messages.firstIndex(where: {
            $0.queued && $0.content == item.text && $0.imageDataURL == item.imageData
        }) {
            chat.messages[idx].queued = false
            // v3.0.86 fix：就地改 queued（count 不变）→ 显式重建缓存，即时去掉「排队中」角标
            refreshVisibleMessages()
            startStream(for: chat.messages[idx])
            return true
        }
        if resyncFromHistory,
           let hit = chat.messages.enumerated().first(where: { i, m in
               m.role == "user" && m.content == item.text && m.imageDataURL == item.imageData
               && !hasAssistantReply(after: i)
           }) {
            startStream(for: chat.messages[hit.offset])
            return true
        }
        // v2.0.102：排队消息已不在列表（被删除/清空/切换）→ 直接丢弃，不重发（修复"删除后复活"）
        return false
    }

    /// v3.9.41（SR60）：第 i 条之后是否已有真正的 assistant 回复（错误占位不算，Models.swift 的 isErrorPlaceholder）
    private func hasAssistantReply(after i: Int) -> Bool {
        guard i + 1 < chat.messages.count else { return false }
        return chat.messages[(i + 1)...].contains { $0.role == "assistant" && !$0.isErrorPlaceholder }
    }

    /// v3.4.x 发送可靠性：队列落盘持久化 + 启动恢复补发（杀 App/断网重启不丢排队消息）
    private static let pendingQueueKey = UserDefaultsKey.pendingQueue

    func persistPendingQueue() {
        // v3.9.41（SR60）：空队列直接清键（原样写回 [] 也能工作，但启动时会白解一次）
        guard !pendingQueue.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.pendingQueueKey)
            return
        }
        if let d = try? JSONEncoder().encode(pendingQueue) {
            UserDefaults.standard.set(d, forKey: Self.pendingQueueKey)
        }
    }

    func restorePendingQueue() {
        guard pendingQueue.isEmpty,
              let d = UserDefaults.standard.data(forKey: Self.pendingQueueKey),
              let arr = try? JSONDecoder().decode([PendingSend].self, from: d),
              !arr.isEmpty else { return }
        // v3.9.41（SR60）：打上「恢复来的」标记——派发时按内容回捞历史行（见 sendQueued 的说明）
        pendingQueue = arr.map { var it = $0; it.fromRestore = true; return it }
        // v3.9.41（SR60）：**不**在这里删盘上的键。原实现读上来就 removeObject，
        // 而派发点一次只发一条 → 第 2..n 条只存在于内存，切一次会话（clearPendingQueue）
        // 或被系统回收就永久没了，和「杀 App/断网重启不丢排队消息」的设计意图正好相反。
        // 现在盘上那份由 persistPendingQueue 逐条收口（发一条擦一条、清空即删键）。
    }

    /// v2.0.88：取消排队（停止按钮/新建会话）——用户明确表达「不要了」→ 内存 + 盘一起清
    func clearPendingQueue() {
        pendingQueue.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.pendingQueueKey)
        resetQueuedRows()
    }

    /// v3.9.41（SR60）：切会话专用——只丢「刚离开的那个会话」的排队项，其余留在盘上等回那个会话再发。
    /// 与 clearPendingQueue 的区别有两处：①切会话不是「取消发送」，原来一把清会把别的会话的待发吞掉；
    /// ②刻意不去翻 messages 的 queued 标记——这一帧列表正处于「旧会话已换下/新会话可能还没加载完」，
    /// 按当前内容复位很容易把**目标会话**自己的排队角标擦掉（sendQueued 就再也匹配不到那条行了）。
    func dropPendingQueue(dropping sid: String) {
        // 只按 sessionId 精确丢；nil 是老版本落盘的无主条目，交给派发点按当前会话对待
        pendingQueue.removeAll { $0.sessionId == sid }
        persistPendingQueue()
    }

    /// 上屏消息里的「排队中」标记复位（行还在列表里，只是不再排队）
    private func resetQueuedRows() {
        for i in chat.messages.indices where chat.messages[i].queued {
            chat.messages[i].queued = false
        }
        // v3.0.86 fix：queued 就地复位（count 不变）→ 显式重建缓存，「排队中」角标即时消失
        refreshVisibleMessages()
    }

    /// v2.0.62：打开图片查看器（收集会话内全部图片消息 → 相册翻页）
    /// v2.0.102：索引钳制——解码失败导致 images 比 imgMsgs 短时防越界
    func openImageViewer(for msg: ChatMessage) {
        // ⚠️ v3.9.41（SR45 · 刻意未改）：这里是「一次同步解出整个会话的全部图片」，且刻意不传
        // displayWidthPT（dataURLImage 的注释写明：查看器/导出/分享要全分辨率，缩放看不糊）。
        // 图多的会话点一下图片可能卡住主线程几百毫秒起。
        // 不在这轮动它的原因：改成「只解当前页 + 左右各一屏、其余划到再解」要连带重做 ChatImageViewer
        // 的数据源（ImageViewPayload 现在收的是 [UIImage]），属于需要真机验交互的重构；
        // 而改成下采样解码（传 displayWidthPT）会把大图查看器直接变糊——是产品取舍，不是 bug 修复。
        let imgMsgs = chat.messages.enumerated().filter { $0.element.imageDataURL != nil }
        // v3.9.41（SR58）：全量解码前留一条面包屑（下面这行是主线程同步解全会话的图，
        // 图多的会话可能卡几百毫秒起——真卡住了，上报里就能看出是这里干的）
        HangWatchdog.breadcrumb("打开大图查看器（\(imgMsgs.count) 张全量解码）")
        let images = imgMsgs.compactMap { dataURLImage($0.element.imageDataURL ?? "") }
        guard !images.isEmpty,
              let rawIdx = imgMsgs.firstIndex(where: { $0.element.id == msg.id }) else { return }
        let idx = min(rawIdx, images.count - 1)   // v2.0.102：坏图跳过导致偏移时钳制
        viewerPayload = ImageViewPayload(images: images, index: idx, sourceID: msg.id)   // v3.4.29：转场源
    }

    /// v2.0.128：AI 消息内图片点击 → 打开大图查看器（单张）
    /// data URL 直接解码进查看器；http(s) URL 双通道下载（URLSession → 自签证书降级 CFStream）
    /// v3.9.17：AI 生成物预览 —— QuickLook 只吃本地文件，所以先下载到临时目录再打开。
    /// 复用 downloadImage 的双通道（URLSession → 失败降级 StreamHTTPClient 忽略自签证书）。
    /// v3.9.31：下载失败不再静默 return（用户点文件卡毫无反馈＝「功能坏了」）→ 弹「文件已失效」提示。
    func openAIFile(_ url: String, _ name: String) {
        guard let u = URL(string: url), url.hasPrefix("http") else { return }
        Task {
            var data: Data? = try? await URLSession.shared.data(from: u).0
            if data == nil { data = await Self.downloadRawData(u: u) }
            guard let d = data, !d.isEmpty else {
                await MainActor.run { fileGoneAlert = true }   // v3.9.31：文件失效提示（多为生成物已被服务器清理）
                return
            }
            // 显示名来自后端下发的文件名——防它带路径分隔符/冒号写到别处
            let safe = name.replacingOccurrences(of: "/", with: "_")
                           .replacingOccurrences(of: ":", with: "_")
                           .trimmingCharacters(in: .whitespaces)
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent(safe.isEmpty ? "qingliao_preview.dat" : safe)
            try? FileManager.default.removeItem(at: dst)   // 覆盖同名旧临时文件，避免临时目录堆积
            do { try d.write(to: dst) } catch {
                await MainActor.run { fileGoneAlert = true }   // v3.9.31：写盘失败也明确提示
                return
            }
            await MainActor.run { quickLookURL = dst }
        }
    }

    /// 自签证书通道取原始字节（与 downloadImage 的降级通道同型）
    @MainActor
    private static func downloadRawData(u: URL) async -> Data? {
        guard let host = u.host, let scheme = u.scheme else { return nil }
        let port = UInt16(u.port ?? (scheme == "https" ? 443 : 80))
        let path = u.path + (u.query.map { "?" + $0 } ?? "")
        let client = StreamHTTPClient()
        let result = await Task.detached(priority: .userInitiated) {
            try? client.request(host: host, port: port, isTLS: scheme == "https",
                                method: "GET", path: path, headers: [:], body: nil, timeout: 20)
        }.value
        if let (data, code) = result, (200..<300).contains(code) { return data }
        return nil
    }

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
            setRemoteImageCache(url, img, cost: data.count, sourceData: data)
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
                setRemoteImageCache(url, img, cost: data.count, sourceData: data)
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
        // v3.9.41：手动重试必须绕过 sendCore 的 60s 同内容幂等闸门。
        // 这条消息的签名正是它刚才那次**失败**的发送写下的，不清的话失败后 60 秒内
        // 点「重试」= 气泡已被移除、sendCore 直接 return = 消息凭空消失且什么都没发。
        // （`autoRetryStream` 从一开始就不走 sendCore，也就没踩到这个坑。）
        lastSentSignature = nil
        sendCore(text: msg.content, imageData: msg.imageDataURL)
    }

    /// v3.9.58b：工具卡「重试」入口——对最后一条 assistant 消息触发 regenerate。
    /// 语义与长按「重新生成」完全一致（复用 regenerate 的截断+锚点+落库链路），
    /// 只是入口从气泡菜单挪到工具卡，方便「工具跑一半挂了」的场景一键重来。
    func retryLastGeneration() {
        guard !stream.isStreaming,
              let lastAssistant = chat.messages.last(where: { !$0.isUser }) else { return }
        Haptics.tap()
        regenerate(at: lastAssistant.id)
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
        let lastUserHasImage = chat.messages.last(where: { $0.isUser })?.imageDataURL != nil
        // v3.0.81：统一模型优先级链（视觉 > Agent > 主模型）
        let (useModel, useProvider) = resolveModel(hasImage: lastUserHasImage)
        // v3.9.15：闸门与实际请求同源
        let history = chat.historyPayload(model: useModel, provider: useProvider)
        // SR12：原来切走会话只 `return`——A 会话已被 removeSubrange 截断（原文没了），
        // 新答案又被丢掉 → A 这轮永久空白。与 startStream/SR2 同口径：落回发起时的会话。
        // 快照必须在截断**之后**取（截断前的快照落回会把旧的那条回复也一起写回去）。
        let startSid = chat.sessionId
        let startMsgs = chat.messages
        let startTitle = chat.title
        Task {
            stream.pendingUserMsgId = anchorUserID   // v3.3.3：regenerate 锚点（杀后台恢复也用）
            await stream.start(auth: auth, sessionId: chat.sessionId, model: useModel,
                               provider: useProvider, messages: history) { success, error in
                let body: String
                if !success {
                    body = stream.content.isEmpty ? "⚠️ \(error)" : stream.content + "\n\n⚠️ \(error)"
                } else if stream.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // v3.5.1：空回复 → 明确提示（不用 markFailed，见 handleEmptyReply 注释）
                    body = Self.emptyReplyNote
                } else {
                    body = stream.content
                }
                if chat.sessionId == startSid {
                    chat.upsertAssistant(body, agent: stream.isAgent, afterUserID: anchorUserID)
                    if success,
                       !stream.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        showSentOK()
                        // v3.1.9 fix：云端模式流式完成同样触发快拉（与本地模式一致）
                        InboxStore.shared.triggerFastPoll()
                    }
                    Task { await chat.saveToServer(auth: auth) }
                } else {
                    landAwayReply(body, agent: stream.isAgent,
                                  snapshot: startMsgs, sid: startSid, title: startTitle)
                }
            }
        }
    }

    // MARK: - v4.0.44 待做池 3：改口重答（编辑已发消息 → 旧回答折叠「已修改」+ 基于新原文重答）

    /// 这条消息此刻能不能改口（nil = 长按菜单里不显示「编辑」）。
    /// 条件：**全局**没在跑流（stream.start 会掐断在跑的流）+ 它就是最后一条 user 消息。
    /// ⚠️ 判据必须是全局 `stream.isStreaming`，不能收窄成 `thisSessionStreaming`：
    /// 入口按会话收窄、执行端（editMessage 的 guard）按全局 → 多会话并行时别的会话在跑流，
    /// 本会话菜单仍显示「编辑」，点完 editMessage 静默 return = 用户消息没改也没提示。
    /// 「单例是否被占用」的护栏一律用全局判据，见本文件 286-292 的铁律。
    func editAction(_ msg: ChatMessage) -> (() -> Void)? {
        guard !stream.isStreaming, chat.editableUserMessageID == msg.id else { return nil }
        return {
            inputFocus = false
            editingMessage = msg
        }
    }

    /// 改口重答：换掉用户原文 → 该轮旧回答折叠为「已修改」→ 基于新原文重答。
    /// 用户拍板（2026-10-04 卡）：折叠态复用现有灰气泡；只允许改最后一条 user 消息。
    /// 重答失败/空回复 → 还原折叠的旧回答（宁可回到旧回答，也不留白）+ 出提示。
    func editMessage(_ msg: ChatMessage, newText: String) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stream.isStreaming else { return }   // 入口 editAction 已按**全局** stream.isStreaming 隐藏（勿改回收窄的 thisSessionStreaming：多会话并行时会「菜单显示编辑、点完静默 return」）
        // 只允许最后一条 user 消息（面板之外再兜一层）
        guard let idx = chat.messages.firstIndex(where: { $0.id == msg.id }),
              MessageEditKit.editableIndex(chat.editRows) == idx else { return }
        guard !text.isEmpty, text != chat.messages[idx].content else { return }
        // 换原文 —— content 参与 id 计算，改完 id 就变了，锚点必须重取
        // v4.0.47：原文/原 id 先留底 —— 失败要连**用户原文**一起还原，否则落成「新文 + 旧答」（答非所问）
        let originalText = chat.messages[idx].content
        let originalID = msg.id
        guard chat.updateUserText(id: msg.id, newText: text) else { return }
        let anchorID = chat.messages[idx].id
        let folded = chat.foldRepliesAfterUser(anchorID)   // 折叠旧回答（快照留着失败回退）
        refreshVisibleMessages()
        // v4.0.47：编辑**立刻落盘**再起流。否则杀后台窗口内编辑丢失（服务端还是旧文），
        // 而恢复锚点已换成新 id → 锚点失配、旧文配新答。与 sendCore「追加后即时保存」同口径。
        Task { await chat.saveToServer(auth: auth) }
        let lastUserHasImage = chat.messages[idx].imageDataURL != nil
        let (useModel, useProvider) = resolveModel(hasImage: lastUserHasImage)
        let history = chat.historyPayload(model: useModel, provider: useProvider)
        // 与 regenerate 同口径：快照在改动**之后**取，切走会话时落回发起时的会话
        let startSid = chat.sessionId
        let startMsgs = chat.messages
        let startTitle = chat.title
        Task {
            stream.pendingUserMsgId = anchorID   // 杀后台恢复的锚点
            await stream.start(auth: auth, sessionId: chat.sessionId, model: useModel,
                               provider: useProvider, messages: history) { success, error in
                let content = stream.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let ok = success && !content.isEmpty
                let body: String
                if ok {
                    body = stream.content
                } else if success {
                    body = Self.emptyReplyNote
                } else {
                    body = stream.content.isEmpty ? "⚠️ \(error)" : stream.content + "\n\n⚠️ \(error)"
                }
                if chat.sessionId == startSid {
                    if ok {
                        chat.upsertAssistant(body, agent: stream.isAgent, afterUserID: anchorID)
                        showSentOK()
                        InboxStore.shared.triggerFastPoll()
                    } else {
                        // 重答没成 → 原样还原被折叠的旧回答（否则这轮只剩「已修改」、新回答又没有）
                        chat.unfoldReplies(folded)
                        // v4.0.47：连**用户原文**一起还原。只还原旧答会落成「新文 + 旧答」——
                        // 用新问题配旧答案，正是用户口径「失败自动还原、内容与气泡状态一致」要挡的。
                        if chat.updateUserText(id: anchorID, newText: originalText) {
                            stream.pendingUserMsgId = originalID   // 锚点跟着回到旧 id
                        }
                        Haptics.notify(.error)
                        editFailedNote = success ? Self.emptyReplyNote : (error.isEmpty ? "网络异常" : error)
                        editFailedAlert = true
                    }
                    refreshVisibleMessages()
                    Task { await chat.saveToServer(auth: auth) }
                } else {
                    // 切走会话：落回发起时的会话（同 regenerate）。失败时快照里的折叠态也要还原，
                    // 否则那个会话永久留一条「已修改」而没有任何新回答。
                    var snap = startMsgs
                    if !ok {
                        for f in folded {
                            if let i = snap.firstIndex(where: { $0.id == f.id }) { snap[i] = f }
                        }
                        // v4.0.47：用户原文同口径回滚——只还原旧答会落成「新文 + 旧答」（答非所问）
                        if let i = snap.firstIndex(where: { $0.id == anchorID }) { snap[i] = msg }
                    }
                    landAwayReply(body, agent: stream.isAgent, snapshot: snap,
                                  sid: startSid, title: startTitle)
                }
            }
        }
    }

    // MARK: - v3.0.81 模型优先级链（统一供 startStream / regenerate / sendFile 使用）

    /// 模型优先级：视觉模型 > Agent 模型 > 主模型
    /// - Parameter hasImage: 当前消息是否包含图片（触发视觉模型优先）
    /// - v3.10.x：「免费模型（免 Key）」档已移除——实测 opencode zen 免费档对非 OpenCode 客户端恒 403
    ///   （FreeTierError: free tier can only be used from within OpenCode），开启即每次回复都是错误文案。
    func resolveModel(hasImage: Bool = false) -> (String, String) {
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
                                 withAnimation(Motion.settle) { showAttachmentMenu = false }   // v3.9.0：令牌收口
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
    /// v3.9.60：实现抽到 `ImageDownscale`（历史图也会进 body，发送链每一环要用同一档位，别各写一份）
    func compressForCellular(_ imageDataURL: String?) -> String? {
        guard NetworkMonitor.shared.isCellular else { return imageDataURL }
        return ImageDownscale.dataURL(imageDataURL,
                                      maxSide: ImageDownscale.cellularMaxSide,
                                      quality: ImageDownscale.cellularQuality) ?? imageDataURL
    }
}   // v3.0.50：扫码球移除后 ChatView struct 闭合


// MARK: - v4.0.49 启动链类型折叠（防启动期 demangler 递归爆主线程 1MB 栈）
// 事故：v4.0.47 / v4.0.48 侧载装完「一点开就闪退」。设备 .ips 实证 = 主线程栈溢出，
// demangler 在 messageList.getter 里递归 102 帧；定量对得上该类型的 mangled 名 **1951 字符**
// （≈19 字符/帧 × 每帧 ~9.3KB）。4.0.48 的 AnyView 擦除只动到了内联子链，
// 真正的开销是**外层链本身**（16 条 ScrollView 修饰器 + 22 条 ZStack 修饰器全内联在类型名里）。
//
// 修法：折成具名 ViewModifier 分组 —— 父类型名只留组名（~35 字符），组内链在各组自己的一次调用里
// 解析（各自 1MB 栈预算）。⚠️ 不透明属性（some View）做不到这一点：解析不透明类型时仍要解析其
// 底层类型名，长度照样算进同一次递归 —— 这是 4.0.48 修了但没修到点上的原因。
//
// 视图树、修饰器顺序与语义一律不动（等价重构）：.id("messages") / .transition 等身份与动画真源
// 仍作用在同一个视图上，只是类型结构从「一条 40 层的链」变成「几个具名组」。
extension ChatView {
    // MARK: - v4.0.49 启动链折叠（防 demangler 栈溢出；护栏 = ql_typestack ③′）
    // 事故：类型名 1951 字符 ↔ demangler 递归 102 帧 ↔ 主线程 1MB 栈吃干 → 一点开就闪退。
    // 规则：谁也不许把这些链再内联回 messageList —— 改链请改这里的 applyXxx，别动调用点。

    /// 启动链折叠第 1 组（4 条修饰器）：名字里只出现本组具名类型，不再内联整条链
    @MainActor
    private func applyMessageListScroll1<C: View>(to content: C, proxy: ScrollViewProxy) -> some View {
        content
                .animation(Motion.settle, value: chat.messages.isEmpty)   // v3.9.30：驱动欢迎页/列表切换过渡
            // v2.0.111：消息区背景透明（ScrollView 默认白底遮住上方 logo/内容）
            .scrollContentBackground(.hidden)
            // v2.0.86h：Dock 滑动隐藏已删除（从未生效，手动开关替代）
            // v2.0.43：搜索定位——滚动到命中消息并高亮 2 秒
            // v3.9.58c：proxy 写回 @State（引用块跳转用）；onAppear 只跑一次，不参与 body 重算
            .onAppear { scrollProxyRef = proxy }
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
    }

    /// 启动链折叠第 2 组（4 条修饰器）：名字里只出现本组具名类型，不再内联整条链
    @MainActor
    private func applyMessageListScroll2<C: View>(to content: C, proxy: ScrollViewProxy) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                let maxY = geo.contentSize.height - geo.containerSize.height
                // v3.9.48 性能：投影**先夹 0 再取整**。onScrollGeometryChange 只在投影值变化时
                // 回调 action，原先未过拉时返回的是逐帧变化的负数 → 整个正常滚动过程每帧回调一次、
                // 每帧写一次 @Observable progress（Observation 不做等值比较，写同值也标脏
                // InboxPullLayer——那层里还挂着一颗 ultraThinMaterial 胶囊）。
                // 夹 0 后正常滚动期投影恒为 0，一次回调都不发；过拉本身只有 0...60pt 有意义，
                // 取整到 1pt 拉满过程最多 60 次失效，指示器跟手位移看不出差别。
                let overscroll = geo.contentOffset.y - max(0, maxY)
                return overscroll <= 0 ? 0 : overscroll.rounded()
            } action: { _, overscroll in
                inboxPullHandleScroll(overscroll: overscroll)
            }
            // v3.0.86 fix：贴底检测（pinned）——内容不满屏或已滚到底（容差 8pt）视为贴底。
            // 流式自动滚底仅贴底时生效：用户上翻阅读历史时 pinned=false，不被 delta 拽回底部。
            // 🚨 v4.0.36 修（用户实报「流式最新文字一路沉到输入框下面、气泡不往上顶」）：
            //   原写法 `isScrollPinned = pinned` 无法区分「谁让内容不在底部」——流式每来一段 delta
            //   内容就长高几十 pt，而**同一帧里 offset 还没动**（滚底挂在 stream.content 的 onChange、
            //   onScrollGeometryChange 可能先跑），于是第一段 delta 就把 pinned 判成 false
            //   → 之后每段都被 `guard isScrollPinned` 挡掉、自动滚底当场熄火，气泡只能在输入栏下面继续长。
            //   现在只有「用户真的把内容往回滚」才解除贴底；内容变高不参与判定，
            //   处于/回到底部即恢复贴底。用户上翻阅读时 delta 依旧不会把人拽回底部（语义不变）。
            //   ⚠️ 本轮补丁（审查实踩）：解除贴底判的是**累计**回滚量而不是单帧增量——
            //   单帧阈值（<prev-1）会让「每帧不足 1pt 的慢速上滑」永远解除不了，照样被 delta 拽回。
            //   状态因此从一个 Bool 变成 ChatScrollPinState（pinned + 贴底基准 offset）。
            //   判定本体已抽成纯函数 ChatScrollPin.next（Core/ChatScrollPin.swift）——
            //   原来内联在这条闭包里，linux swiftc 编不进真值表，等于这段最容易错的逻辑没有单测。
            //   单测：scripts/ql_scrollpin/truth_table_scrollpin.swift（check_swift.sh 第 63 段）。
            .onScrollGeometryChange(for: ChatScrollSnapshot.self) { geo in
                ChatScrollSnapshot(offset: geo.contentOffset.y,
                                   contentH: geo.contentSize.height,
                                   containerH: geo.containerSize.height)
            } action: { _, new in
                scrollPinState = ChatScrollPin.next(state: scrollPinState,
                                                    offset: new.offset,
                                                    contentH: new.contentH,
                                                    containerH: new.containerH)
            }
            // v4.0.34：测量滚动容器可视高度——列表 minHeight 用它实现「不满屏也贴底」
            //（onScrollGeometryChange 首次挂载即回调一次初始值；键盘弹出容器变矮也自动更新）
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.containerSize.height
            } action: { _, h in
                chatListViewportH = h
            }
            // v2.0.135：ScrollView 是 UIKit 桥接视图，其区域点击不冒泡到 ZStack 根手势
            // （v2.0.112b 把 onTapGesture 移到 ZStack 后，有消息时点空白收键盘失效，用户复报）
            // → ScrollView 自身也挂一个：点消息区空白收键盘（点气泡由 MessageBubble 手势优先消费，不受影响）
            .onTapGesture {
                inputFocus = false
            }
            // v3.0.86 fix：缓存刷新已上提 ZStack 层 onChange（ScrollView 卸载/欢迎态也生效），
            // 此处的 count 变化只负责贴底滚动（消息 append 场景）
    }

    /// 启动链折叠第 3 组（3 条修饰器）：名字里只出现本组具名类型，不再内联整条链
    @MainActor
    private func applyMessageListScroll3<C: View>(to content: C, proxy: ScrollViewProxy) -> some View {
        content
            .onChange(of: chat.messages.count) {
                // v4.0.37：append（自己发出 / 回答落库）本来就意味着「要跟着看」——把贴底态一并复位。
                // 否则上一轮遗留的 unpinned 会让随后整段流式的自动滚底全部熄火（真机「贴底没效果」的一支）。
                // 不加新行为：此处原本就无条件滚底，复位只是让随后的 delta 不再被旧态挡住。
                scrollPinState = .pinnedAtBottom
                scrollBottom(proxy)
            }
            .onChange(of: displayLimit) { _, _ in
                refreshVisibleMessages()
            }
            // v3.0.86 fix：流式内容变化仅在用户贴底时自动滚底（scrollPinState 由下方
            // onScrollGeometryChange 实时维护）——上翻阅读历史不再被 delta 拽回；无动画防高频打断
            // 🚨 v4.0.40（2026-10-04 用户再报「流式时最新气泡始终沉在输入框下面」）——本次改的是
            // **信号源**，不是时序：
            //   · 渲染（气泡高度）由打字机平滑层 stream.displayContent 驱动，每 48ms 一 tick；
            //   · 旧写法滚底挂在 stream.content 上，那只在 poll 落字时变（约 0.15s 一次）→ 两个信号源
            //     不同源：每滚一次底，随后 48~150ms 内气泡又长高 1~3 行，逐 tick 累加出来的观感就是
            //     「最新几行永远差一截、沉到输入栏下面」。v4.0.36/37/38 三版都在调时序/判定
            //     （累计回滚量、延后一拍），没碰过「滚底信号 ≠ 渲染信号」这个根。
            // 现在滚底与渲染同源：displayContent 每变一次就滚一次，两者节拍一致。
            // 同理别退回 stream.content —— 源级护栏 ql_scrollpin B14 钉住这条。
            .onChange(of: stream.displayContent) { _, _ in
                guard scrollPinState.pinned else { return }
                // v4.0.37：延到下一拍、几何更新后再滚（同一帧内容刚长高、布局尚未落地）。
                // 延迟窗口内用户若上翻，第二道 pinned 判定会把这次滚动放掉，不把人拽回去。
                DispatchQueue.main.async {
                    guard scrollPinState.pinned else { return }
                    scrollBottom(proxy, animated: false)
                }
            }
    }

    /// 启动链折叠第 1 组（4 条修饰器）：名字里只出现本组具名类型，不再内联整条链
    @MainActor
    private func applyMessageListChrome1<C: View>(to content: C) -> some View {
        content
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
            .onChange(of: chat.sessionId) { prior, _ in
                // v3.9.41（SR60）：切会话 ≠ 取消发送。原来这里走 clearPendingQueue()（内存 + 盘一起清），
                // 于是「A 会话里排队、切去 B」= 无条件把 A 的待发吞掉，且盘上那份也一起没了。
                // 现在只丢「刚离开的这个会话」的排队项；其余留在盘上，回到那个会话或下次启动再补发。
                dropPendingQueue(dropping: prior)
                // v4.1.x：忙态结论属于**上一个**会话，必须作废重探——否则新会话会继承上一会话的
                // 「AI 正在输入」（胶囊/灵动岛）甚至思考气泡（气泡条件已含 remoteBusy）。
                // 探针 6s 内自己纠正；目标会话本机有 pending 标记时 probeRemoteBusy 会立刻置 true，不闪。
                remoteBusy = false
                remoteBusyFails = 0
                // v4.1.x 多会话并行：进入新会话前，若它有后台流在跑 → 撤后台轮询，
                // 前台由既有 probeRemoteBusy（6s 内）→ adoptRemote 无缝接回显示。不撤会双轮询抢流。
                BackgroundStreamRunner.shared.retractIfRunning(sessionId: chat.sessionId)
                refreshVisibleMessages()
                // v3.9.80：工具进度四件套走单一入口复位（原先这里手写三行，漏了 v3.9.80 新增的 toolSeq
                // → 摘要行会把上一会话的步数当成本会话的「实际步数」；详见 StreamClient.resetToolProgress）
                stream.resetToolProgress()
                // v3.0.51 A1：会话加载后重传残留 base64 图片（重启续传/失败重传）
                // SR4：走 ChatStore 的单飞入口——旧会话那条重传链会先被 cancel，不会跨会话争写 messages
                chat.startImageRetryUploads(auth: auth)
                // v4.0.x 一句话记账：「已记账 + 撤销」条是「这段对话里刚做的事」，换会话即复位
                // （记录本体是全局账本、撤销仍能删掉它，但把别处那条提示挂到新会话上看着像 bug）
                chatRecordEntry = nil
            }
            // v3.4.25：改双重触发——count（增删）+ lastID（整组替换/清空重建时 count 不变，仅靠
            // sessionId 兜底会漏渲染；lastID 变化补上「同条数内容替换」场景，且流式 tick 不改 lastID，
            // 不引入额外高频重建）
    }

    /// 启动链折叠第 2 组（4 条修饰器）：名字里只出现本组具名类型，不再内联整条链
    @MainActor
    private func applyMessageListChrome2<C: View>(to content: C) -> some View {
        content
            .onChange(of: chat.messages.count) {
                refreshVisibleMessages()
            }
            .onChange(of: chat.messages.last?.id ?? "") { _, _ in
                refreshVisibleMessages()
            }
            // v4.0.71：**就地改字段**的变更（作答 / 失败回退 / 回执 / 过期 / 主动反馈 / 追问候选）
            // 不改 count、也不改 last?.id，上面两条判据扫不到 → 界面停在旧快照上不动。
            // 用户 2026-10-07 真机反馈：「选了某个答案后选择框不会变，必须切到其他 tab 再切回」
            // —— 切页会把列表重建一遍，所以才「追上」了。计数由 ChatStore 的就地写入口自增
            // （见 ChatStore.messageRev 注释），这里只负责重建一次可见窗口。
            .onChange(of: chat.messageRev) { _, _ in
                refreshVisibleMessages()
            }
            .onChange(of: chat.pendingNewSession) { _, pending in
                guard pending else { return }
                clearing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    // v3.0.11 fix：新建会话前先清队列+停流——原实现旧流仍在跑，
                    // 回答内容会持续显示/落进新会话（同 bot 串话根因族）
                    // v3.9.41（SR60）：只清本会话的排队项（+ 下面紧接的停流），
                    // 别的目标会话的待发不该被「点了一下加号」顺带吞掉
                    dropPendingQueue(dropping: chat.sessionId)
                    // v4.1.x 多会话并行：新建会话**不再杀旧流**——旧流移交后台跑流器继续轮询，
                    // 跑完按发起时快照落库（答案不丢）；v3.0.11 的「先停旧流防串话」已过时
                    //（后端实测真并行、按 sessionId 隔离），且 stream.start 本就会复位单例接管前台。
                    // 移交失败（单例空闲/异常态）才走原 stop 兜底。
                    if stream.isStreaming, !stream.isDone, !stream.taskId.isEmpty,
                       !auth.currentStreamSessionId.isEmpty {
                        let sid = auth.currentStreamSessionId
                        let tid = stream.taskId
                        let anchor = stream.pendingUserMsgId
                        let startMsgs = chat.sessionId == sid ? chat.messages : []
                        let startTitle = chat.sessionId == sid ? chat.title : ""
                        BackgroundStreamRunner.shared.adopt(taskId: tid, sessionId: sid,
                                                            title: startTitle, userMsgId: anchor,
                                                            snapshot: startMsgs,
                                                            offset: stream.handoffOffset,
                                                            content: stream.handoffContent,
                                                            auth: auth, chat: chat)
                        stream.detachLocally()   // 只停本地轮询，服务端任务继续跑；落库归 runner
                        // v4.0.10：移交后收尾回调被吞（onFinished = nil），startStream 里的
                        // `sendingLock = false` 永不执行 → 必须在这里显式解锁，否则整页发送永久失效
                        sendingLock = false
                    } else if stream.isStreaming {
                        stream.stop(auth: auth)   // 兜底：缺 taskId/会话 id 的异常态按旧路停掉
                    }
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
            // v4.0.11：启动期逻辑从 body 修饰符链里**提出来**（纯等价重构，零行为变化）。
            // 根因：CI 报 `ChatView.swift:2548: the compiler is unable to type-check this expression
            // in reasonable time` —— 巨型 view 链内再塞大闭包，编译器类型检查超时（本地 `-parse`
            // 只查语法，查不出这类问题，只有 Archive 才挂）。
            .task { await bootstrapChat() }
    }

    /// 启动链折叠第 3 组（4 条修饰器）：名字里只出现本组具名类型，不再内联整条链
    @MainActor
    private func applyMessageListChrome3<C: View>(to content: C) -> some View {
        content
            .fullScreenCover(item: $bigBangPayload) { payload in
                // v3.9.0：zoom 转场——从被长按的气泡"生长"出来（与图片查看器同一机制）
                if payload.sourceID.isEmpty {
                    BigBangView(text: payload.text, onAskAI: { t in sendCore(text: t, imageData: nil) })
                } else {
                    BigBangView(text: payload.text, onAskAI: { t in sendCore(text: t, imageData: nil) })
                        .navigationTransition(.zoom(sourceID: payload.sourceID, in: zoomNS))
                }
            }
            // v3.7.0：回前台时重探一次（用户刚在地图里「拷贝」→ 切回轻聊即出现胶囊）
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await checkMapClipboard() } }
            }
            // v3.8.0：灵动岛 / 锁屏实时活动——AI 开始时亮起、结束时收起（本地驱动，侧载免费签名可用）
            // initial: true：冷启动时先结算一次（服务端还在回复的场景由 remoteBusy 探针随后触发 true）
            // v3.9.7：busy=false 走「完成态 → 2s 后收起」，让「已完成」看得见
            .onChange(of: aiBusy, initial: true) { _, busy in
                pushLiveActivity(busy: busy)
                // v3.9.9 fix：抑制标记的复位已挪到上面那处 `startSeq` 观察（与工具卡收起合并在同一处，
                // 别再单独挂——链长一超阈值 CI 就挂）。
                if busy { inboxPullReset() }
            }
            // v4.0.x（审查 TASK2 ②）：抑制标记复位已与工具卡收起合并到上面那处 `.onChange(of: stream.startSeq)`。
            // 合并而非新增的理由：这条 body 链已贴着类型检查阈值，多挂一个带闭包的修饰符即 Archive 失败（CI #608）。
            // v3.9.9 收口（两位只读审查都指出上一版信号不干净）：触发改为 `chat.assistantLandedToken`——
            // ChatStore 在**真正 append/insert 了一条 assistant 回复**时自增。原来监听「末条消息 id 变化」：
            //   ① 切会话 / 冷启动加载（load 整组替换 messages）也会变 → 念出刚打开会话的历史旧答案；
            //   ② AI 回答中用户又发一条（排队）时，本轮回复 insert 在中段、末条仍是 user 消息 → 信号不变，
            //      这一轮永远不朗读。
            // 为什么不用 `aiBusy`（历史教训，别改回去）：aiBusy = (本机流 && 会话匹配) || 云端流 ||
            // 服务器探针 的并集，切会话 / 探针抖动 / 失败自动重试的空窗 / 用户点停止都会 true→false，
            // 据此朗读会念到上一条旧答案、半截答案，甚至切过去那个会话的内容；
            // 流式中的内容活在 streamingBubble（不落 chat.messages），所以"落库事件"才是本轮结束的可靠信号。
            // v4.0.11：两条「落库」边沿合成**一个**观察值 —— 本 view 的修饰符链已处在编译器类型检查超时的
            // 临界点（CI 报 ChatView.swift:2548 unable to type-check），能不加 modifier 就不加。
            // token：本会话落库（驱动自动朗读）；away：被移交的后台任务落库（驱动排队排空）。
            // away 不能用 token 代替：assistantLandedToken 只在 noteAssistantLanded 自增，移交落库走的是
            // noteAwayLandedReply → 挂在 token 上是空操作、缺口照旧（A 里第二条一直「排队中」，要重进聊天页
            // 才补发）。pumpPendingQueue 幂等：只派发属于当前会话的条目、且被 !stream.isStreaming 挡着。
            .onChange(of: LandedSignal(token: chat.assistantLandedToken, away: chat.awayLandedTick)) { old, new in
                if new.token != old.token { autoReadLatestReply() }
                if new.away != old.away { pumpPendingQueue() }
            }
            // v3.9.7：阶段变化（思考中 → 输出中）也要推一次，否则灵动岛会一直停在「思考中」
            // （内容没变的重复调用会被管理器挡掉，不会造成 update 风暴）
    }

    /// 启动链折叠第 4 组（4 条修饰器）：名字里只出现本组具名类型，不再内联整条链
    @MainActor
    private func applyMessageListChrome4<C: View>(to content: C) -> some View {
        content
            .onChange(of: liveActivityPhase) { _, _ in
                guard aiBusy else { return }
                pushLiveActivity(busy: true)
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
            .quickLookPreview($quickLookURL)   // v3.9.17：AI 生成物（PDF/表格/文本）预览
    }

    /// 启动链折叠第 5 组（4 条修饰器）：名字里只出现本组具名类型，不再内联整条链
    @MainActor
    private func applyMessageListChrome5<C: View>(to content: C) -> some View {
        content
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
                          contentType: ChatMarkdownDocument.markdownType,
                          defaultFilename: "轻聊会话") { _ in }
            .fileExporter(isPresented: $showPDFExporter,
                          document: ChatPDFDocument(data: exportPDFData ?? Data()),
                          contentType: .pdf,
                          defaultFilename: "轻聊会话") { _ in }
            // v3.4.28：导出格式选择面板 + HTML 导出
    }

    /// 启动链折叠第 6 组（2 条修饰器）：名字里只出现本组具名类型，不再内联整条链
    @MainActor
    private func applyMessageListChrome6<C: View>(to content: C) -> some View {
        content
            .sheet(isPresented: $showExportSheet) {
                ChatExportSheet(title: chat.title, messages: chat.messages) { format in
                    handleExport(format)
                }
                .scrollContentBackground(.hidden)
            }
            .fileExporter(isPresented: $showHTMLExporter,
                          document: ChatHTMLDocument(html: exportHTML),
                          contentType: .html,
                          defaultFilename: "轻聊会话") { _ in }
    }

    @MainActor
    private struct MessageListScroll1: ViewModifier {
        let host: ChatView
        let proxy: ScrollViewProxy

        func body(content: Content) -> some View { host.applyMessageListScroll1(to: content, proxy: proxy) }
    }

    @MainActor
    private struct MessageListScroll2: ViewModifier {
        let host: ChatView
        let proxy: ScrollViewProxy

        func body(content: Content) -> some View { host.applyMessageListScroll2(to: content, proxy: proxy) }
    }

    @MainActor
    private struct MessageListScroll3: ViewModifier {
        let host: ChatView
        let proxy: ScrollViewProxy

        func body(content: Content) -> some View { host.applyMessageListScroll3(to: content, proxy: proxy) }
    }

    @MainActor
    private struct MessageListChrome1: ViewModifier {
        let host: ChatView

        func body(content: Content) -> some View { host.applyMessageListChrome1(to: content) }
    }

    @MainActor
    private struct MessageListChrome2: ViewModifier {
        let host: ChatView

        func body(content: Content) -> some View { host.applyMessageListChrome2(to: content) }
    }

    @MainActor
    private struct MessageListChrome3: ViewModifier {
        let host: ChatView

        func body(content: Content) -> some View { host.applyMessageListChrome3(to: content) }
    }

    @MainActor
    private struct MessageListChrome4: ViewModifier {
        let host: ChatView

        func body(content: Content) -> some View { host.applyMessageListChrome4(to: content) }
    }

    @MainActor
    private struct MessageListChrome5: ViewModifier {
        let host: ChatView

        func body(content: Content) -> some View { host.applyMessageListChrome5(to: content) }
    }

    @MainActor
    private struct MessageListChrome6: ViewModifier {
        let host: ChatView

        func body(content: Content) -> some View { host.applyMessageListChrome6(to: content) }
    }

    /// 欢迎页分支（frame/id/transition）——v4.0.49 折叠组
    @MainActor
    private struct WelcomeBranchChrome: ViewModifier {
        let host: ChatView

        func body(content: Content) -> some View { host.applyWelcomeBranchChrome(to: content) }
    }

    @MainActor
    private func applyWelcomeBranchChrome<C: View>(to content: C) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id("welcome")   // v3.4.29：原 padding(.top,120) 已移入 welcomeView 顶部弹性留白（小屏不再挤）
            .transition(.opacity.combined(with: .scale(scale: 0.97)))   // v3.9.30：欢迎页浮现过渡
    }

}

// MARK: - v4.0.81 长按菜单的锚定目标与锚点台账

/// 长按某个气泡行时弹出的锚定菜单目标（值类型，塞进 @State 触发一次重绘即可）。
struct ChatBubbleMenuTarget {
    let id: String
    /// 该气泡行的全局 frame（菜单按它定位；取不到时回落到三点菜单锚点）
    let anchor: CGRect
    /// 该行要操作的文本（整条气泡 / 选中那一段 / 代码正文，由气泡侧传入）
    let text: String
    let message: ChatMessage
}

/// 气泡行级锚点台账。**故意不是 ObservableObject**：滚动时每帧都会刷新 frame，
/// 写进 @State 会让整页 body 反复失效（同源教训见 ChatView「滚动容器可视高度」注释）。
final class ChatBubbleAnchorStore {
    static let shared = ChatBubbleAnchorStore()
    private var frames: [String: CGRect] = [:]
    private init() {}
    func set(_ id: String, _ rect: CGRect) { frames[id] = rect }
    func rect(for id: String) -> CGRect? { frames[id] }
}
