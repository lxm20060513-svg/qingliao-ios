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

// MARK: - v2.0.65 发送完成通知（Dock 轻跳）

extension Notification.Name {
    static let qingliaoSent = Notification.Name("qingliao_sent")
    // v3.4.26：看板轮询 Leave/Refresh 通知已移除——改 DockTabView → DashboardView(isActive:) 参数直传，
    // 生命周期收进 DashboardView 自身（见 DashboardView.onChange/.task(id:)）；通知名定义随引用清除
    // v3.4.14：系统分享收件通知（DockTabView.onOpenURL 捕获分享后广播，ChatView 消费发送）
    static let qingliaoShareIncoming = Notification.Name("qingliao_share_incoming")
    // v3.4.x：任务中心「发送到当前会话」通知（TaskCenterView 广播，ChatView 消费发送）
    static let qingliaoTaskSend = Notification.Name("qingliao_task_send")
    // v3.9.14：备忘录「发给 AI」——生活页发通知，这里发送 + DockTabView 切回聊天页
    static let qingliaoMemoSend = Notification.Name("qingliao_memo_send")
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
                // v3.9.54：修「后台跑完灵动岛不收尾」。上面这条通知说明**这个回调就是本进程
                // 在后台唯一知道「任务已结束」的时刻**——但原来它从不碰实时活动，于是活动一直
                // 停在「AI 正在回复」，直到用户回前台才被收敛/兜底收掉（用户报的现象逐字一致）。
                // ⚠️ 本闭包由 URLSession 在任意线程回调，`LiveActivityManager` 是 @MainActor，
                // 且这里只能送 Sendable 值（sid / failed），所以走 `Task { @MainActor in … }`。
                // 口径同 v2.0.60 注释：唤醒时机由系统决定，非实时（见 reconcile 的能力边界说明）。
                let failed = (status == "error")
                Task { @MainActor in
                    await LiveActivityManager.shared.reconcileAfterBackgroundCheck(sessionId: sid,
                                                                                  failed: failed)
                }
                completionHandler(.newData)
            } else {
                completionHandler(.noData)   // 未完成，等下次系统唤醒再查
            }
        }.resume()
    }

    // v2.0.63：用 completionHandler 版（async 版在 Swift 6 下 non-Sendable 参数报错）
    // v3.9.4 加固：本类因 `UIApplicationDelegate`（SDK 里是 @MainActor 协议）被推断为 MainActor 隔离，
    // 而 `UNUserNotificationCenterDelegate` **不是** @MainActor（Apple 文档声明仅 NSObjectProtocol，
    // 对回调线程无任何承诺）⇒ 上面的 @preconcurrency 只是把隔离检查**推迟到运行时**：
    // 一旦系统在后台线程回调「点通知」，进方法体即触发隔离断言 = SIGTRAP（与 v3.9.3 语音那次同源）。
    // 方法体只读写 UserDefaults（线程安全、非隔离）并转调 completionHandler，本就不需要主 actor
    // ⇒ 标 nonisolated 即消除该断言，行为零变化（当前线上恰好都在主线程，故一直没暴露）。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let sid = response.notification.request.content.userInfo["qingliao_session"] as? String {
            UserDefaults.standard.set(sid, forKey: "qingliao_open_session")
        }
        completionHandler()
    }

    /// v3.9.39 A6：**前台到点不响**的根治。Apple 的规则是「设了 delegate 但没实现 willPresent
    /// ⇒ 前台来的通知不弹横幅、不出声、也不进通知中心（直接丢弃）」。本类自 v2.0.60 起就是全仓
    /// 唯一的 UNUserNotificationCenterDelegate（:33 赋值），所以所有本地通知在 App 前台时被静默吃掉：
    /// · 一句话定时提醒（典型用法就是「聊天里长按消息 → 5 分钟后提醒」，用户 100% 停在 App 里）
    ///   ——到点无声，下次冷启动 `markExpiredLocally()` 还把它标成「已提醒」，等于凭空消失；
    /// · 收件箱推送 / AI 回复完成通知——InboxStore 注释里写的「App 前台也弹」一直没成立过。
    /// 不给 `.badge`：图标角标由 `NotificationHelper.setBadge` 按任务中心未读数**整体对账**设置
    /// （v3.4.23），再让系统 +1 会变成双重计数、且没有清零路径。
    /// 与 `didReceive` 同样标 `nonisolated`：理由见上面那段 v3.9.4 说明（后台线程回调进 MainActor 体 = SIGTRAP）。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// v2.0.88：排队待发消息（AI 回答中发送，当前回答结束后自动逐条发送）
/// v3.4.x：Codable —— 排队队列落盘持久化，杀 App/断网重启后自动恢复补发（不丢消息）。
struct PendingSend: Codable, Equatable {
    let text: String
    let imageData: String?
    /// v3.9.41（SR60）：入队时的会话。原队列是「无主」的，重启后恢复的第 2..n 条会等不到派发：
    /// 派发点要么在无脑拿队首（拿错会话 → 上屏找不到排队行 → 静默丢弃），
    /// 要么被切会话的 clearPendingQueue 一把清掉（盘上那份在恢复时已被删除）→ 消息永久消失。
    /// 可选类型：老版本落盘的 JSON 没这个键，`decodeIfPresent` 解成 nil，按「当前会话」处理。
    var sessionId: String? = nil
    /// v3.9.41（SR60）：由启动恢复读上来的条目标记。派发时用它区分两种匹配口径：
    /// 会话内新排队的条目一定能按 `queued` 行匹配上；恢复出来的条目不能（queued 不落盘），
    /// 需要按内容回捞历史行。只有恢复条目允许回捞，才不至于把「用户已删除的那条」也复活。
    var fromRestore: Bool = false

    /// 是否属于某个会话（nil = 旧数据，无从判断，按当前会话对待）
    func belongs(to sid: String?) -> Bool { sessionId == nil || sessionId == sid }

    /// v3.9.41（SR60）：显式列出键——①老版本（无 sessionId）落盘的 JSON 缺键必须仍能解出，
    /// 否则整份队列 `try?` 解失败 = 恢复直接归零；②fromRestore 只是本次运行内的标记，不参与持久化。
    enum CodingKeys: String, CodingKey {
        case text, imageData, sessionId
    }
}

/// v3.9.17：AI 后端（Hermes）路径的工具进度一行。
/// 数据来自 /api/stream/{taskId} 的 toolNames（后端已翻中文，App 不维护第二份映射表）；
/// 流未结束时最后一行视为「正在执行」，其余打勾——长任务里用户不必等结果才知道在干什么。
struct ToolStepRow: View {
    let title: String
    let running: Bool
    /// v3.9.17：流被中止/报错时这些工具并没有确认跑完 → 用「未确认」图标而不是绿勾
    /// （否则用户点了停止，卡里每个工具都显示已完成，语义不实）
    var unresolved: Bool = false
    var body: some View {
        HStack(spacing: 8) {
            if running {
                ProgressView().controlSize(.mini)
            } else if unresolved {
                Image(systemName: "circle.dashed")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.green)
            }
            Text(running ? "正在\(title)…" : title)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                .strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8)
        )
    }
}

/// v3.9.14：工具进度卡**答完后收起**成的那一行（用户反馈：这些别答完还一直摊在对话里）。
/// 生成中仍然逐条展开（能看到 AI 正在干什么），答完折叠成「N 步工具调用」，点开可看明细。
/// 抽成独立 struct 而不是塞进 toolStepCards —— 本仓 CI 反复踩过 body 过大导致的
/// 「Unable to type-check this expression in reasonable time」。
struct ToolStepsSummaryRow: View {
    let count: Int
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                Text("\(count) 步工具调用")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                    .strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
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
    // 用户「忽略」或「已发送」后不再复现；拷贝了新内容才会再提示。
    // v3.8.1：从 @State 改成 @AppStorage **跨启动保留**——原来每次冷启动都归零，
    // 导致同一份剪贴板内容每次进 App 都重复提示（用户反馈）。uptime 一起存，用于作废重启前的记录。
    @AppStorage("qingliao_clip_handled_change") var handledClipChange = -1
    @AppStorage("qingliao_clip_handled_uptime") var handledClipUptime = 0.0
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
    // v3.9.14：工具进度卡展开状态——生成中强制展开，答完默认收起（用户反馈这几行别一直摊着）
    @State var toolStepsExpanded = false
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
    @State var autoRetryCount = 0    // v3.4.x：消息失败自动重试计数（网络类错误最多自动重试 2 次，防死循环）
    @State private var lastSentSignature: (sessionId: String, text: String, image: String?, ts: TimeInterval)?  // 同内容 60s 幂等（v3.4.27 fix：签名含图片指纹——纯图 text 恒空，无图指纹会把 60s 内第二张纯图误判重复丢弃）
    @State var fileSendBlocked = false   // v2.0.102：流式中发文件提示
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
    // v3.0.51 A2：极长会话分页懒加载——初始只渲染尾部最近 N 条，顶部可"加载更早"
    @State var displayLimit = 300
    private static let loadMoreStep = 300
    // v3.3.0：多选合并发送——选择模式开关 + 选中消息 id 集合
    @State var selectMode = false
    @State var selectedMsgIDs: Set<String> = []
    @State var selectBlocked = false      // 流式中尝试进入多选 → 提示
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
    // v3.9.8：AI 回复自动朗读（header 胶囊开关）。默认关（不被动出声）。
    // v3.9.9 起：自动朗读**跟随设置里的「AI 语音朗读」开关**（开着=神经音色，关=系统语音），
    // 不把每轮回复全文 POST 到后端神经 TTS；想要神经音色就手动点气泡上的朗读。
    // 注意区别：设置页的「AI 语音朗读」管的是**引擎**（CloudConfig.ttsEnabled 默认 true → 手动朗读默认走后端
    // 神经音色），这里的胶囊管的是**要不要自动念**，两者各管一段、互不覆盖。
    @AppStorage("qingliao_auto_read_reply") private var autoReadReply = false
    /// v3.9.9 收口：自动朗读去重（同一条只自动念一次，手动点气泡不受限）
    /// v3.9.9：去重键**非可选**（`msg.uid ?? msg.id`）——uid 对老数据是 nil，
    /// 可选比较会遇到 nil == nil 伪去重：第一次朗读被吞掉、之后带 nil uid 的回答永远不念
    @State private var lastAutoReadKey = ""
    /// v3.9.9 收口：用户主动「停止生成」（输入栏 / 灵动岛）→ 本轮不自动朗读（别把残句念一遍）
    @State private var suppressAutoReadOnce = false
    @State private var showReasoningPicker = false
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
    private var aiBusy: Bool {
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
        let streamFailed = stream.status == "error" && !stream.errorMessage.isEmpty
                          && !isRetryableStreamError(stream.errorMessage)
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

    /// v3.6.5：仅本地模式包一层（独立属性，避免 headerTrailingItems 表达式过复杂
    /// 触发 Xcode 26「unable to type-check in reasonable time」——v3.3.0 已因此抽离过一次）
    /// v3.9.28：云端模式移除后恒显示，保留独立属性防 type-check 超时的初衷不变
    @ViewBuilder
    private var localReasoningPill: some View {
        reasoningPill
    }

    /// v3.6.5：模型思考档位胶囊（放在任务中心左侧）。点击弹出档位选择。
    /// 仅本地模式显示——云端由服务商决定思考策略（且云端侧暂不做改动）。
    /// v3.9.46：尺寸统一走 `chatHeaderPill()`（与右侧朗读胶囊同一档，不再各自手写 padding）
    private var reasoningPill: some View {
        Button {
            showReasoningPicker = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: reasoningLevel.symbol)
                Text(reasoningLevel.title)
            }
            .foregroundStyle(Color.accentColor)
            .chatHeaderPill()
        }
        .buttonStyle(PressStyle())
        // v3.9.34：胶囊视觉 46×24 → 命中区 46×44（只纵向外扩，横向本就 >44）
        .hitArea44(h: 0, v: 10)
        .accessibilityLabel("模型思考档位，当前\(reasoningLevel.title)")
    }

    /// v3.9.8：header「朗读」胶囊开关（放思考档位胶囊右侧、任务中心左侧）。
    /// 开 = AI 每轮回复结束自动念一遍；关 = 不自动念（气泡上的朗读按钮仍可手动念，互不影响）。
    /// v3.9.43（用户要求）：样式与左侧思考档位胶囊**完全对齐**——同一枚原生液态玻璃
    /// （`glassPillStroke()` = `glassEffect(.regular.interactive())` + accent 0.28 / 0.8pt 描边）
    /// 与同一档内边距（h `Spacing.md` / v `Spacing.sm`），不再自绘「淡底 Capsule + 关态补描边」那套。
    /// ⚠️ 玻璃底两态共用、不做区分 ⇒ 「开 / 关」只剩**图标着色**这一个信号（accent / secondary），
    ///    别再指望远底色的深浅能读出状态；语义另有 accessibilityLabel 兜着。
    private var autoReadPill: some View {
        Button {
            autoReadReply.toggle()
            if !autoReadReply { SpeechManager.shared.stop() }   // 关掉立刻闭嘴，不留半句
            Haptics.tap()
        } label: {
            // v3.9.9（用户要求）：**只留图标、不要文字**——header 上多一个"朗读"两字太占宽
            // （与思考档位胶囊同处一行，窄屏会把标题挤掉）。语义靠图标 + accessibilityLabel 表达。
            // v3.9.37（用户要求）：两态共用同一枚喇叭图标，只靠颜色区分——启用蓝(accent) / 禁用灰(secondary)；
            // 原禁用态用的是 speaker.slash（带斜杠），用户要求改成「灰色喇叭」即可
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(autoReadReply ? Color.accentColor : Color.secondary)
                .chatHeaderPill()
        }
        .buttonStyle(PressStyle())
        // v3.9.34：命中区抬到 ≥44（外扩 8 小于同行 12pt 间距，不越界抢点）；
        // v3.9.43 视觉改薄一档（高 ~25）→ 纵向外扩跟着思考胶囊的 v:10
        .hitArea44(h: 8, v: 10)
        .accessibilityLabel(autoReadReply ? "自动朗读已开启" : "自动朗读已关闭")
    }

    /// v3.9.8：自动朗读最新一条 AI 回复。
    /// 只念真正的「AI 回答」——跳过推送气泡（🔔 收件箱/进度，isPush）与错误占位（isErrorPlaceholder），
    /// 那些念出来只会莫名其妙。
    private func autoReadLatestReply() {
        // 抑制标记**只在真正要念时才消费**：原来无条件清掉，生成期来一个 🔔 进度气泡（isPush）
        // 就把标记吃掉，用户停止后落库的残句又会被念出来（只读审查抓到的回归）。
        guard autoReadReply, !suppressAutoReadOnce else { return }
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
            autoReadPill
            Button {
                showTaskCenter = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "checklist")
                        .font(.system(size: Typography.body, weight: .semibold))
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
            // v3.9.34：命中区撑到 44×44（图标仍 20pt、间距零变化 —— 见 hitArea44 负 padding 说明）
            .hitArea44()
            .accessibilityLabel("任务中心")

            Button {
                showMoreMenu = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: Typography.title, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
            // v3.9.34：命中区撑到 44×44（图标仍 24pt、间距零变化）
            .hitArea44()
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
            if thisSessionStreaming {   // v3.9.41：本会话在收流才拦（A 在跑不该让 B 不能多选）
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
            // SR5：原实现在 clearMessages **之前**就 Task{saveToServer}，写的是清空前的全量快照
            // （后端同 id 整会话覆盖 → 白写），而清空后的空数组又被 writeSessionSnapshot 的
            // 「空即跳过」护栏挡掉 → NAS 上历史原封不动，重启/换设备后「清空的消息又复活」。
            let sid = chat.sessionId
            let ttl = chat.title
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(nil) { chat.clearMessages() }
                clearing = false
                Task { await chat.saveToServer(auth: auth, sessionId: sid, messages: [],
                                               title: ttl, allowEmpty: true) }
            }
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
                    contextUsage: chat.contextUsage(maxTokens: 4000),
                    // v3.9.48：聚焦展开时右下角浮出的模型快选胶囊
                    modelLabel: composerModelLabel,
                    onPickModel: { showComposerModel = true })
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
                Text("图片已选择，发送后 AI 可识别")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                Spacer()
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
        if !stream.toolNames.isEmpty, auth.currentStreamSessionId == chat.sessionId {
            VStack(alignment: .leading, spacing: 6) {
                // v3.9.27：生成中也可随时收起（用户反馈「不必等输出完才能收」）——
                // 统一走「摘要行 + expanded 控制明细」，不再按 isStreaming 强制展开。
                ToolStepsSummaryRow(count: stream.toolNames.count,
                                    expanded: toolStepsExpanded) {
                    withAnimation(Motion.snap) { toolStepsExpanded.toggle() }   // v3.9.19：裸动画收口到令牌（原 .easeOut(0.18)）
                }
                if toolStepsExpanded {
                    ForEach(Array(stream.toolNames.enumerated()), id: \.offset) { idx, name in
                        ToolStepRow(title: name,
                                    running: stream.isStreaming && idx == stream.toolNames.count - 1,
                                    unresolved: !stream.isStreaming && !stream.errorMessage.isEmpty)
                    }
                }
            }
            .padding(.horizontal, 44)   // 左侧留出 AI 头像位
            .transition(.opacity)
        }
    }


    var body: some View {
        // v2.0.140：禁用系统键盘避让——ChatInputBar 已手动按 kb.topY 精确计算 bottom padding，
        // 系统默认避让叠加会双重上抬 → 输入框与键盘间留空隙（用户红线标注）。
        // 只保留手动控制，输入框精确贴键盘。
        VStack(spacing: 0) {
            chatHeaderBar
            chatStatusBannerStrip
            chatTranscriptArea
            chatComposerArea
        }
        .animation(.easeOut(duration: kb.animationDuration), value: kb.height)
        // v2.0.96：语音授权/转写失败提示（v3.9.3：设备端识别——麦克风权限 / 机型不支持 / 识别中断）
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
        .task {
            await resumePersistedStream()
            // v3.5.1：AI 正在输入 探针（仅当有遗留任务标记时才发请求；服务器说没了就清标记收起状态）
            await busyProbeLoop()
        }
        // v3.9.6：实时转写同步进输入框 —— 不依赖「启动时存下来的闭包写 @State」，
        // 改用 SwiftUI 原生更新周期里写（liveSpeech.liveText 变化 → 必然走这里），松手定稿后框内即最终文本
        .onChange(of: liveSpeech.liveText) { _, newValue in
            // v3.9.9：守卫与录音行同口径（voiceMode 或识别器在跑），否则会出现
            // "红点行有字、输入框里没字"的分裂状态
            guard voiceMode || liveSpeech.isRunning else { return }
            inputText = newValue
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
            }, includeKB: true)   // v3.9.28：知识库恒显示（原按云端/本地分流，云端已移除）
            .presentationDetents([.medium, .large])
        }
        // v2.0.96：Hermes 捷径面板（官方斜杠命令，点击填充输入框）
        .sheet(isPresented: $showHermesShortcut) {
            HermesShortcutSheet { cmd in
                inputText = cmd
                showAttachmentMenu = false
            }
            .presentationDetents([.medium, .large])
            .scrollContentBackground(.hidden)
        }
        // v3.0.27：章节列表
        .sheet(isPresented: $showTOCSheet) {
            TOCSheet(headers: tocHeaders(), onNavigate: { item in
                // v3.9.41：按 TOCItem.msgIndex 定位（数据源已逐条抽取并打标，见 tocHeaders()）
                // —— 复用会话搜索的 highlightTarget 机制滚动 + 高亮
                guard item.msgIndex >= 0, item.msgIndex < chat.messages.count else { return }
                let target = chat.messages[item.msgIndex]
                chat.highlightTarget = (role: target.role, content: target.content)
                showTOCSheet = false
            })
            .presentationDetents([.medium])
            .scrollContentBackground(.hidden)
        }
        // v3.9.32：定时提醒面板（长按气泡「提醒我」/ 设置页入口共用）
        .sheet(isPresented: $showQuickReminder) {
            QuickReminderSheet(presetText: reminderSeedText)
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
        }
        // v3.9.48：输入栏展开态的模型快选（右下角胶囊）。detents 与 Hermes 捷径/章节列表同档
        .sheet(isPresented: $showComposerModel) {
            ComposerModelSheet()
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
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
        .onChange(of: stream.isStreaming) { _, streaming in
            // v3.9.41：加会话归属判定——A 起流不该把 B 里手动展开的工具卡收起来（该卡本来就按会话显示）
            if streaming, thisSessionStreaming { toolStepsExpanded = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qingliaoMemoSend)) { note in
            if let text = note.object as? String, !text.isEmpty {
                // 与输入栏 send() 同口径：用户真的发起新一轮 → 先掐掉上一轮朗读，
                // 否则 AI 正念上一条时点「发给 AI」，旧朗读会一直念到新答案出完
                SpeechManager.shared.stop()
                sendCore(text: text, imageData: nil)
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
    // 由头：此 body 单块 263 行（主体是 188 行链式修饰符，按约束 2 保留在 body），是本仓已踩过两次的「Unable to type-check this
    // expression in reasonable time」高危形态（一次漏检 = 20 分钟 CI 循环）。
    // 这里按原注释分段把视图块原样搬成独立 @ViewBuilder 属性 —— **纯搬运**：视图顺序、
    // 层级、条件分支、闭包、修饰符逐字未变，渲染结果与拆分前一致，只为把类型检查表达式打小。

    /// 页头 + 思考档位/聊天操作弹窗 + 任务中心全屏页
    @ViewBuilder
    private var chatHeaderBar: some View {
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
    }

    /// 续聊芯片条 + 消息区（含停止录音/收件箱覆盖层）
    @ViewBuilder
    private var chatTranscriptArea: some View {
        // v3.4.26：续聊芯片条——有消息且非流式时显示在消息区上方（话题延续入口）
        continueChipsBar
        messageList
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
        .padding(.bottom, Spacing.lg)   // v3.0.67：输入框与 dock / 键盘均留 10pt 呼吸——收起贴 dock、弹键盘也留隙（Round-1「贴键盘 0」已被用户改主意为也要留隙）
    }

    // MARK: - v3.7.0 剪贴板地图链接（地图分享兜底）
    /// 探测剪贴板是否有**位置链接** → 顶部胶囊提示（detection API 不读内容、无系统粘贴弹窗）
    /// v3.8.1 修复：① 只认「能被 MapLocationParser 认成位置」的链接，不再"有内容就提示"；
    ///             ② 已处理版本号跨启动保留，同一份内容不再每次进 App 都提示。


    private func checkMapClipboard() async {
        guard !showClipboardBanner else { return }
        // v3.9.1：先取本版号——探测是 await（有窗口期），期间用户换了剪贴板内容时不能把"新内容"记成已处理
        let cc = UIPasteboard.general.changeCount
        let handled = ClipboardPromptGate.isHandled(changeCount: cc,
                                                    lastHandledChange: handledClipChange,
                                                    lastHandledUptime: handledClipUptime,
                                                    currentUptime: ProcessInfo.processInfo.systemUptime)
        guard !handled else { return }   // 这份内容已经处理过（含上次启动处理的），别再打扰
        // v3.9.1：nil = 探测失败（与"不是位置链接"区分开）——失败不记账，留给下次进前台再探
        guard let isLocation = await MapClipboardDetector.hasLocationLink() else { return }
        markClipboardHandled(cc)         // 认没认出来都记账：同一份内容不再重复探测/提示
        guard isLocation else { return }
        withAnimation(Motion.settle) { showClipboardBanner = true }   // 只提示；真正内容等点按再读
    }

    /// 记账：这份剪贴板内容已评估过（已发送 / 用户忽略 / 不是位置链接）
    /// - Parameter changeCount: 显式传入"当时探测的那一版"；省略则取当前值
    private func markClipboardHandled(_ changeCount: Int? = nil) {
        handledClipChange = changeCount ?? UIPasteboard.general.changeCount
        handledClipUptime = ProcessInfo.processInfo.systemUptime
    }

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
            Button {
                markClipboardHandled()   // 记住这一版（跨启动持久化），勿再打扰
                withAnimation(Motion.snap) { showClipboardBanner = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(Spacing.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("忽略")
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8))
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xxs)
        .padding(.bottom, Spacing.xxs)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// 真正读取剪贴板（此刻才可能弹系统「允许粘贴」）→ 地图链接拼定位消息，其他链接原样发送
    private func sendClipboardLink() {
        markClipboardHandled()
        withAnimation(Motion.snap) { showClipboardBanner = false }
        guard let raw = MapClipboardDetector.readText() else { return }
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

    // v2.0.111：欢迎页独立于 ScrollView——不再受滚动容器背景/裁剪影响，logo 永远完整显示
    private var welcomeView: some View {
        VStack(spacing: 0) {
            // v3.4.29：顶部弹性留白（原写死在容器上的 padding(.top,120)）——小屏不再被挤压，大屏自然下移，最多 120pt
            Spacer(minLength: 56).frame(maxHeight: 120)

            ZStack {
                // v3.4.25：粒子球版 logo 替代静态渐变圆；v3.9.2 改为 siri 液态玻璃球静态帧
                Circle()
                    .fill(LinearGradient(colors: [.blue.opacity(0.10), .indigo.opacity(0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 96, height: 96)
                // v3.9.2：欢迎页 logo 也换成 siri 液态玻璃球（静态帧，不占 GPU）
                LiquidOrbAvatar(size: 96, thinking: false)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: Typography.display))
                    .foregroundStyle(.white)
                    .shadow(color: .indigo.opacity(0.35), radius: 6, y: 2)
            }

            // v3.4.29：文案组与 logo 拉开距离（原整体 spacing 12 → 96pt 的球和文字贴在一起，头重脚轻）
            // 现改为分组：logo↔文案 18pt，问候↔副标题 6pt（同组紧、跨组松）
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
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: s.icon)
                                    .font(.system(size: Typography.caption, weight: .medium))
                                Text(s.title)
                                    .font(.system(size: Typography.subhead, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Spacing.xl)
                            .padding(.vertical, Spacing.md)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8))
                        }
                        .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                    }
                }
                .padding(.horizontal, Spacing.section)
            }
            .padding(.top, 18)

            // v3.4.29：继续上次会话——用户手动新建/清空会话后一键回到上一个会话，免切「会话」tab 再找
            // （启动自动 loadLastSession 只覆盖 App 重启场景，新建会话后原先没有任何回归路径）
            if let last = chat.lastLoadedSession, last.id != chat.sessionId, !clearing {
                Button {
                    Haptics.tap()
                    chat.load(last)
                } label: {
                    HStack(spacing: Spacing.md) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: Typography.body, weight: .medium))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("继续上次")
                                .font(.system(size: Typography.caption, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(last.title.isEmpty ? "未命名会话" : last.title)
                                .font(.system(size: Typography.subhead, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: Typography.caption, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.vertical, Spacing.lg)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                        .strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8))
                }
                .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.section)
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
        if !chat.messages.isEmpty && !thisSessionStreaming {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(welcomeSuggestions) { s in
                        Button {
                            Haptics.tap()
                            sendCore(text: s.prompt, imageData: nil)
                        } label: {
                            Text(s.title)
                                .font(.system(size: Typography.subhead, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Spacing.xl)
                                .padding(.vertical, Spacing.md)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8))
                        }
                        .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                    }
                }
                .padding(.horizontal, Spacing.xxl)
            }
            .padding(.vertical, Spacing.sm)
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
            // 气泡出现动效（v3.9.31）：统一「上滑入位」y:8→0 + opacity 0→1（微信式方向感），
            // 动画事务由 ChatStore.append/upsertAssistant 的 withAnimation(Motion.enter) 驱动。
            // 移除仍为纯淡出。
            // v2.0.38：批量清空/切会话走 load/clearMessages 数组替换（不经过 append/insert），
            // 不会在此触发 spring 动画，避开当年全 cell 移除闪退
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 8)),
                removal: .opacity))
            // v3.9.0：长按「大爆炸」时从这条气泡原生 zoom 生长（与非闭包实参 zoomNS 配对）
            .matchedTransitionSource(id: "bb-" + entry.msg.id, in: zoomNS)   // v3.9.1：独立 id 空间——气泡内图片用的是 msg.id，同 id 会让 zoom 取源不确定
    }

    /// v3.0.51：单条消息气泡构造——拆独立方法（防消息列表 ForEach 内 type-check 超时）
    @ViewBuilder
    private func chatMessageBubble(_ msg: ChatMessage) -> some View {
        MessageBubble(message: msg,
                      isHighlighted: msg.id == highlightMessageID,
                      zoomNS: zoomNS) {   // v3.4.29：zoom 转场（非闭包实参须在 trailing closure 之前）
            regenerate(at: msg.id)
        } onBigBang: { text in
            bigBangPayload = BigBangPayload(text: text, sourceID: "bb-" + msg.id)   // v3.9.1：与上面的转场源 id 成对
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
        } onTodo: { text in
            // v3.9.35：加入待办（整条气泡 / 选中片段）→ 生活页「待办清单」栏目
            if TodoStore.shared.add(content: text, source: "chat") {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } onRemind: { text in
            // v3.9.32：长按「提醒我」——默认文案取该条消息内容
            reminderSeedText = text
            showQuickReminder = true
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

    /// v3.0.15：流式输出气泡——拆独立计算属性（防 messageList 巨型 body type-check 超时）
    /// v3.9.40（#3）：真正渲染交给 StreamingBubbleView——displayContent 每 48ms 的写入只失效那条气泡，
    /// 不再让 ChatView.body（连同整份 LazyVStack 消息列表）跟着逐 tick 重画。
    @ViewBuilder
    private var streamingBubble: some View {
        StreamingBubbleView(
            onAIImageTap: { url in openAIImage(url) },   // v2.0.128：流式中 AI 图片可点（参数须在 streamingAvatar 前）
            onFileTap: { url, name in openAIFile(url, name) }   // v3.9.17：流式中 AI 生成物可点
        )
        .id("streaming")
    }

    private var messageList: some View {
        ZStack {
            // v2.0.40：clearing 期间直接显示欢迎页（列表已卸载，数据稍后清空）
            // v3.9.30：容器挂 settle —— 驱动 welcome/列表 if 切换的浮现过渡（transition 需同帧动画）
            if (chat.messages.isEmpty || clearing) && !thisSessionStreaming {
                welcomeView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .id("welcome")   // v3.4.29：原 padding(.top,120) 已移入 welcomeView 顶部弹性留白（小屏不再挤）
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))   // v3.9.30：欢迎页浮现过渡
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
                        if thisSessionStreaming {
                            if stream.content.isEmpty {
                                // 思考中动画（三点跳动，气泡加大版）
                                // v3.0.15：恢复 v3.0.12 之前的原始三点动画（思考球 orbits 粒子已移除，改由输出头像承担粒子球）
                                // v3.0.18：思考期头像也改为粒子球（38pt，用户要求全程粒子球头像）
                                HStack(alignment: .top, spacing: 10) {
                                    // v3.9.2：思考中占位头像 = siri 液态玻璃球（恒 thinking 态）
                                    // v3.9.4：去掉蓝色底圆（用户要求）
                                    LiquidOrbAvatar(size: 38, thinking: true)
                                        .allowsHitTesting(false)
                                        .frame(width: 38, height: 38)
                                    // v2.0.35：去掉"思考中"文字（用户要求），保留三点跳动动画
                                    TypingIndicator()
                                        .padding(.horizontal, Spacing.section)
                                        .padding(.vertical, Spacing.xxl)
                                        .background(Color(uiColor: .systemGray5))
                                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
                    // v3.9.27：气泡变长——消息区左右 padding 12→6（气泡 maxWidth 369 联动）
                    .padding(.horizontal, 6)
                    .padding(.top, Spacing.md)
                    .padding(.bottom, Spacing.md)
                    .id("messages")   // v2.0.39：与欢迎页分支区分身份
                }
                .animation(Motion.settle, value: chat.messages.isEmpty)   // v3.9.30：驱动欢迎页/列表切换过渡
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
        .onChange(of: chat.sessionId) { prior, _ in
            // v3.9.41（SR60）：切会话 ≠ 取消发送。原来这里走 clearPendingQueue()（内存 + 盘一起清），
            // 于是「A 会话里排队、切去 B」= 无条件把 A 的待发吞掉，且盘上那份也一起没了。
            // 现在只丢「刚离开的这个会话」的排队项；其余留在盘上，回到那个会话或下次启动再补发。
            dropPendingQueue(dropping: prior)
            refreshVisibleMessages()
            stream.toolNames = []          // v3.9.17：工具进度卡同样会跨会话残留 → 一并清（否则 B 会话底部显示 A 跑过的工具）
            // v3.0.51 A1：会话加载后重传残留 base64 图片（重启续传/失败重传）
            // SR4：走 ChatStore 的单飞入口——旧会话那条重传链会先被 cancel，不会跨会话争写 messages
            chat.startImageRetryUploads(auth: auth)
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
                // v3.9.41（SR60）：只清本会话的排队项（+ 下面紧接的停流），
                // 别的目标会话的待发不该被「点了一下加号」顺带吞掉
                dropPendingQueue(dropping: chat.sessionId)
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
            // v3.9.0：zoom 转场——从被长按的气泡"生长"出来（与图片查看器同一机制）
            if payload.sourceID.isEmpty {
                BigBangView(text: payload.text)
            } else {
                BigBangView(text: payload.text)
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
            // v3.9.9 fix：抑制标记在「新一轮开始」就复位——若只在 autoReadLatestReply 里清，
            // 用户停止后那一轮若没有消息落库（例如流被取消、内容为空），标记会一直挂着，
            // 把**下一轮正常回答**也一起吞掉。
            if busy { suppressAutoReadOnce = false }
        }
        // v3.9.9 收口（两位只读审查都指出上一版信号不干净）：触发改为 `chat.assistantLandedToken`——
        // ChatStore 在**真正 append/insert 了一条 assistant 回复**时自增。原来监听「末条消息 id 变化」：
        //   ① 切会话 / 冷启动加载（load 整组替换 messages）也会变 → 念出刚打开会话的历史旧答案；
        //   ② AI 回答中用户又发一条（排队）时，本轮回复 insert 在中段、末条仍是 user 消息 → 信号不变，
        //      这一轮永远不朗读。
        // 为什么不用 `aiBusy`（历史教训，别改回去）：aiBusy = (本机流 && 会话匹配) || 云端流 ||
        // 服务器探针 的并集，切会话 / 探针抖动 / 失败自动重试的空窗 / 用户点停止都会 true→false，
        // 据此朗读会念到上一条旧答案、半截答案，甚至切过去那个会话的内容；
        // 流式中的内容活在 streamingBubble（不落 chat.messages），所以"落库事件"才是本轮结束的可靠信号。
        .onChange(of: chat.assistantLandedToken) { _, _ in
            autoReadLatestReply()
        }
        // v3.9.7：阶段变化（思考中 → 输出中）也要推一次，否则灵动岛会一直停在「思考中」
        // （内容没变的重复调用会被管理器挡掉，不会造成 update 风暴）
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
        // v2.0.36：录音权限被拒提示
    }

    /// 思考中动画（三点跳动）
    struct TypingIndicator: View {
        // v3.9.19：无障碍——「降低动态效果」时不做循环脉冲
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State var animating = false
        var body: some View {
            HStack(spacing: Spacing.xs) {
                ForEach(0..<3, id: \.self) { i in
                    // v3.4.20：三点跳动 → 蓝紫渐变脉冲圆（与发送按钮/Siri 流光同语言，"AI 活着"统一视觉）
                    Circle()
                        .fill(LinearGradient(colors: [.blue, .indigo, .pink],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 8, height: 8)
                        .scaleEffect(animating ? 1.0 : 0.55)
                        .opacity(animating ? 1.0 : 0.45)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(i) * 0.18), value: animating)
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
            if thisSessionStreaming {
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
        // v3.9.41：改为只被**本会话**自己的流挡住。原来 A 在跑时这里静默 return，
        // B 里点「AI 总结会话」毫无反应（连排队都不排）；收窄后走 sendCore，单例被占用时正常入队。
        guard !thisSessionStreaming else { return }
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

        // v3.0.81：上下文自动管理
        let autoCompress = UserDefaults.standard.bool(forKey: "qingliao_context_auto_compress")
        let threshold = UserDefaults.standard.integer(forKey: "qingliao_context_threshold")
        let effectiveThreshold = threshold > 0 ? threshold : 4000

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
        if stream.isStreaming {
            // ⚠️ 刻意用**全局**判定（不是 thisSessionStreaming）：单例只有一条流，别的会话在跑时
            // 在这里起流会静默掐断它（StreamClient.start 无「已在跑就拒绝」的守卫）。
            // 排队消息由 `pumpPendingQueue()` 在**任意一条**流收尾时接走，包括收尾时用户已在别的会话。
            // 排队路径：消息立即显示（标记排队中），回答结束后自动发送
            var msg = ChatMessage.local(role: "user", content: text, imageDataURL: imageData)
            msg.quotedText = quotedText
            msg.queued = true
            withAnimation(Motion.settle) {   // v3.9.0：动效令牌收口（原 spring 0.25/0.15）
                chat.append(msg)
            }
            pendingQueue.append(PendingSend(text: text, imageData: imageData, sessionId: chat.sessionId))
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
        withAnimation(Motion.settle) {   // v3.9.0：动效令牌收口（原 spring 0.25/0.15）
            chat.append(msg)
        }
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
    func landAwayReply(_ text: String, agent: Bool, snapshot: [ChatMessage],
                       sid: String, title: String) {
        var msgs = snapshot
        var m = ChatMessage(role: "assistant", content: text,
                            timestamp: Date().timeIntervalSince1970 * 1000)
        m.agent = agent
        msgs.append(m)
        chat.noteAwayLandedReply(sessionId: sid, text: text)
        Task { await chat.saveToServer(auth: auth, sessionId: sid, messages: msgs, title: title) }
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
            let (tid, rContent, done, status, _) = try await auth.streamRecover(sessionId: sid)
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
            VStack(spacing: Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: Typography.headline))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                Text(name)
                    .font(.system(size: Typography.caption))
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
                // v3.9.19：**有意不入 Motion 令牌**——发牌要明显回弹（bounce 0.35 强于 emerge 的 0.08），
                // 映射过去会削掉发牌手感（用户 2026-09-14 确认保留原值，勿按统一口径回改）
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
                                .font(.system(size: Typography.caption, weight: .semibold))
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

