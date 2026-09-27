import AppIntents
import Foundation

// MARK: - 快捷指令 / Siri 动作面（v3.9.32）
//
// 为什么要有这一层：AutomationRules.swift 里的 `ReportEventIntent` 曾是**唯一**一个 App Intent，
// 而且全仓零引用、没有 AppShortcutsProvider —— 结果就是"写好了但用户看不见"：
// 快捷指令 App 里没有轻聊的条目，Siri 也不会把条件事件交给轻聊的自动规则。
// 本文件把动作面补齐：每个 intent 都有 title/description/parameterSummary，
// 文件末尾用 `QingliaoAppShortcuts` 登记 Siri 短语（App Shortcuts 才是真正的"零点击"入口）。
//
// 纯逻辑（深链、返回体取值、文案截断）在 QingliaoIntentSupport.swift —— 那里没有 AppIntents 依赖，
// 本机没有 iOS SDK 也能编译并跑真值表。**能验证的别写在只有真机能验的文件里。**
//
// 三条硬约束（想不清楚就会写出"能编译、真机没反应"的东西）：
//  1. **App Intent 拿不到 SwiftUI 环境注入**。`@Environment(AuthStore.self)` 那套在这里不存在，
//     所以统一走 `QingliaoIntentClient.auth()`：新建一个 AuthStore —— 它 init 里就是读
//     UserDefaults 的服务器地址 + Keychain 的 token，与 App 内**同一套存储**，不新造第二份凭据。
//  2. **不能有 UI**。App Intent 可能在没有界面的进程里跑（App 被系统在后台拉起），
//     所以「问轻聊」走后端 `/api/stream/chat`（一次性、非流式），不挂 App 内那套 StreamClient 轮询。
//  3. **回 App 到某页**：intent 声明前台模式（`supportedModes`）+ 进程内投递给 `DockTabView`。
//     ⚠️ **别退回 `OpenURLIntent` + `qingliao://`**：iOS 26 上让系统去开自己的自定义 scheme 会当场被拒，
//     快捷指令里报「The provided URL scheme `qingliao` is unsupported; launch is prohibited」
//     （用户「打开轻聊看板」自动化实测）。`qingliao://` 深链仍归灵动岛 `widgetURL` / 分享回跳 /
//     `onOpenURL` 用 —— 两个入口各管一段，不是二选一，也别互相顶替。
//
// ⚠️ App Shortcuts **每个 App 最多 10 条**，超了是**构建期**失败（appintentsmetadataprocessor 报
//    "Found N App Shortcuts, but each app may have at most 10"）。本文件现在 9 条 —— 加速捷前先数。

// MARK: - 无 UI 客户端（与 App 内同一套 token / 服务器地址 / 后端接口）

enum QingliaoIntentClient {

    /// 取一个已就绪的 AuthStore（与 App 内**同一份** UserDefaults + Keychain，不新造存储）。
    /// AppIntent 由系统在独立场景执行，拿不到环境注入 —— 只能自己 new 一个。
    @MainActor
    static func auth() throws -> AuthStore {
        let a = AuthStore()
        guard a.isLoggedIn, !a.token.isEmpty else {
            throw QingliaoIntentError(message: "轻聊还没登录：先打开 App 登录一次，再回来用快捷指令")
        }
        return a
    }

    /// 一问一答（**非流式**）。
    ///
    /// 为什么不用 `/api/stream/start` + 轮询：无界面 intent 里没有 StreamClient 的轮询循环，
    /// 而且那条链路的回答只活在流式任务里（会话落库是 App 自己调 `/api/sessions/merge` 完成的），
    /// 所以这里选一次性接口，把回答直接交给 Siri / 快捷指令的下一步。
    @MainActor
    static func ask(_ question: String, style: AskStyle) async throws -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw QingliaoIntentError(message: "问题是空的") }
        // 用 Self.auth() 显式限定：避免 `let auth = try auth()` 这种「变量与函数同名」的写法
        let auth = try Self.auth()
        return try await oneShot(style.instructionPrefix + q, auth: auth)
    }

    /// 一问一答（**非流式**）的通用入口 —— 调用方自带完整提示词、自带 auth。
    ///
    /// v3.9.79 从 `ask` 里抽出来：App 内的「AI 翻译」浮层也要「一次调用拿一段文本」，
    /// 而模型/provider 只认 `CloudConfig.mainModelAndProvider`（各处自己读 UserDefaults 会各说各话）。
    /// timeout 120：这条链路后端要跑 Hermes agent 的工具循环（查 NAS / 查天气…），默认 30s 会把长回答掐断。
    @MainActor
    static func oneShot(_ prompt: String, auth: AuthStore, timeout: TimeInterval = 120) async throws -> String {
        try await oneShot(prompt, auth: auth, imageDataURL: nil, timeout: timeout)
    }

    /// 一问一答（**非流式**）· **带图**版 —— v4.0.x「拍照识别」全屏看图页用。
    ///
    /// 与上面那条**除 messages[0].content 形态外一字不差**（同一个 `/api/stream/chat` 端点、同一套模型取源），
    /// 所以文本那条只是它 `imageDataURL: nil` 的分支 —— 别在这条旁边再写第二份 payload 拼装。
    ///
    /// `imageDataURL` 必须是 `data:` base64 串：自家图片 URL 只有 AAAA，交给 IPv4 上游必 400
    /// （见 `ImageBlocks` 文件头）。图块构造统一走 `ImageBlocks.content`（全仓唯一构造点，ql_imgsend 真值表钉着）。
    @MainActor
    static func oneShot(_ prompt: String, auth: AuthStore, imageDataURL: String?,
                        timeout: TimeInterval = 120) async throws -> String {
        // 模型取源分两条，**别合并**：
        //   · 带图 → `modelForImage`（视觉模型 > Agent 模型 > 主模型，与 ChatView.resolveModel 同规则）
        //   · 纯文本（AI 翻译 / 问轻聊 / 纪要）→ 只认 `CloudConfig.mainModelAndProvider`
        //     （v3.9.79 口径：翻译浮层是按主模型配的 30s 超时，切到 Agent 档位会成片掐断）
        let (model, provider) = imageDataURL == nil
            ? CloudConfig.mainModelAndProvider
            : modelForImage(true)
        // 逐分支直赋 `[[String: Any]]`：不要写成 `Any` 与 `??` 混推（本机 `swiftc -parse` 查不出这类，
        // 只有 CI Archive 才炸）。下面两条分支与 Models.swift 的图块分支同一写法。
        let messages: [[String: Any]]
        if let img = imageDataURL {
            messages = [["role": "user", "content": ImageBlocks.content(text: prompt, img: img)]]
        } else {
            messages = [["role": "user", "content": prompt]]
        }
        let payload: [String: Any] = [
            "model": model,
            "provider": provider,
            "messages": messages,
            "stream": false,
        ]
        let j = try await auth.json("/api/stream/chat", method: "POST", body: payload, timeout: timeout)
        let text = QingliaoAIReply.text(from: j)
        guard !text.isEmpty else {
            throw QingliaoIntentError(message: "轻聊没有返回内容（后端 200 但正文为空）")
        }
        return text
    }

    /// 「带图时用哪个模型」的取源 —— 必须与 `ChatView.resolveModel` 同规则（视觉模型 > Agent 模型 > 主模型）。
    /// 为什么不能直接调它：那是 ChatView 的实例方法（读视图 @AppStorage 状态），这一层（无界面客户端）拿不到。
    /// ⚠️ 改口径时两处一起看 —— 别让「拍照识别用哪个模型」和「聊天页发图用哪个模型」分叉。
    /// ⚠️ 纯文本链路（AI 翻译 / 问轻聊 / 纪要）**刻意不走这里** —— 那几条按 `CloudConfig.mainModelAndProvider`
    ///   取源（见 `oneShot` 里那段注释），别顺手合并成一条：翻译浮层的 30s 超时是配主模型的。
    @MainActor
    static func modelForImage(_ hasImage: Bool) -> (model: String, provider: String) {
        if hasImage, let vision = CloudConfig.effectiveVisionModel() {
            return (vision.model, vision.provider)
        }
        let agentModel = UserDefaults.standard.string(forKey: UserDefaultsKey.agentModel) ?? ""
        let agentProvider = UserDefaults.standard.string(forKey: UserDefaultsKey.agentProvider) ?? ""
        if !agentModel.isEmpty { return (agentModel, agentProvider) }
        return CloudConfig.mainModelAndProvider
    }

    /// 收件箱待处理条目文本。
    /// **只读**：不调 `/api/inbox/{id}/done` —— "看一眼收件箱"不该把消息标成已处理，
    /// 标记动作留在 App 里由用户决定。
    @MainActor
    static func inboxTexts() async throws -> [String] {
        let auth = try Self.auth()
        let j = try await auth.json("/api/inbox", method: "GET")
        let items = (j["items"] as? [[String: Any]]) ?? []
        return items.compactMap { d in
            let t = (d["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }
    }
}

// MARK: - 对话框取值

/// 运行时文本（AI 回答、收件箱摘要）→ `IntentDialog`。
///
/// `dialog:` 的类型是 `IntentDialog`，字符串字面量靠 `ExpressibleByStringLiteral` 隐式转换；
/// 运行时 String 必须显式构造：`LocalizedStringResource.init(stringLiteral:)`
/// → `IntentDialog.init(LocalizedStringResource)`（两个 init 都在 Apple 文档里核过）。
private func qlDialog(_ text: String) -> IntentDialog {
    IntentDialog(LocalizedStringResource(stringLiteral: text))
}

// MARK: - 参数枚举

/// 回答风格（快捷指令里的下拉选项；同时决定拼给后端的指令前缀）
enum AskStyle: String, AppEnum {
    case concise
    case detailed
    case bullets

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "回答风格")
    }

    /// ⚠️ 新增 case 必须在这里补一条：协议要的是字典，漏了**不会编译报错**，
    /// 只会在系统 UI 里显示成裸 rawValue。所以下面 `instructionPrefix` 特意用穷尽 switch 兜住。
    static var caseDisplayRepresentations: [AskStyle: DisplayRepresentation] {
        [
            .concise: DisplayRepresentation(title: "一句话", subtitle: "只要结论"),
            .detailed: DisplayRepresentation(title: "详细", subtitle: "展开说明原因与步骤"),
            .bullets: DisplayRepresentation(title: "要点", subtitle: "分条列出"),
        ]
    }

    /// 后端不认"风格"字段，所以在问题前拼一句要求（与 App 内自定义指令同口径）
    var instructionPrefix: String {
        switch self {
        case .concise: return "请用一句话直接回答，不要展开："
        case .detailed: return "请详细回答，说明原因和步骤："
        case .bullets: return "请用简洁的分条要点回答："
        }
    }
}

/// 备忘优先级（普通 / 置顶）
enum MemoPriority: String, AppEnum {
    case normal
    case pinned

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "备忘优先级")
    }

    /// ⚠️ 同 AskStyle：新增 case 要在这里补一条
    static var caseDisplayRepresentations: [MemoPriority: DisplayRepresentation] {
        [
            .normal: DisplayRepresentation(title: "普通", subtitle: "按时间排在列表里"),
            .pinned: DisplayRepresentation(title: "置顶", subtitle: "固定在列表最上"),
        ]
    }
}

// MARK: - 动作 1：问轻聊（把一句话发给 AI，取回回答）

struct AskQingliaoIntent: AppIntent {

    static var title: LocalizedStringResource { "问轻聊" }

    static var description: IntentDescription {
        IntentDescription("把一句话发给轻聊的 AI，直接取回回答（可让 Siri 念出来，也可以在快捷指令里接下一步）")
    }

    @Parameter(title: "问题", description: "要问轻聊的话，例如「今天 NAS 内存占用怎么样」")
    var question: String

    @Parameter(title: "回答风格", description: "留空按「一句话」处理")
    var style: AskStyle?

    @Parameter(title: "朗读回答", description: "关掉则只回一句提示，不在这里念正文", default: true)
    var readAloud: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("问轻聊 \(\.$question)")
    }

    /// `@MainActor`：AuthStore 是 `@MainActor` 隔离的（LiveActivityActions.swift 同因，
    /// 不标隔离等于"可能从后台线程碰主线程状态"）。
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = try await QingliaoIntentClient.ask(question, style: style ?? .concise)
        guard readAloud else {
            // 只回提示：完整回答仍然走 value，需要时在快捷指令里接「显示结果」之类的动作
            return .result(value: answer, dialog: "轻聊已回答")
        }
        return .result(value: answer, dialog: qlDialog(QingliaoAIReply.shorten(answer)))
    }
}

// MARK: - 动作 2：记到备忘录（文本 + 枚举参数）

struct AddMemoIntent: AppIntent {

    static var title: LocalizedStringResource { "记到轻聊备忘录" }

    static var description: IntentDescription {
        IntentDescription("把一句话记进轻聊的备忘录（生活页），可选择置顶")
    }

    @Parameter(title: "内容", description: "要记下来的话")
    var content: String

    @Parameter(title: "优先级", description: "留空按「普通」处理")
    var priority: MemoPriority?

    static var parameterSummary: some ParameterSummary {
        Summary("记到轻聊备忘录 \(\.$content)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .result(dialog: "内容是空的，没记") }

        // v3.9.41（SR33）：`MemoStore.auth` 已从 weak 改强引用——原注释说「局部常量活到函数结束
        // 就够」并不成立：写 NAS 是 save() 里的 Task.detached，perform() 一返回就没有任何强引用
        // 活着，detached 任务里的 `guard let auth` 会静默 return（Siri 已念「已记到」而 NAS 没落）。
        // 现在每次都用最新的这个：改过服务器地址/token 后，旧的那份不该继续被单例用下去。
        let auth = try? QingliaoIntentClient.auth()
        if let auth {
            MemoStore.shared.attach(auth: auth)
        }

        let store = MemoStore.shared
        // source 用默认的 "manual"：MemoStore 的 sourceLabel/sourceIcon 里没有 shortcut 分支，
        // 传新值只会显示成「手记」（改 MemoStore 不在本次改动范围内）—— 与其塞一个渲染不出来的
        // 新来源值，不如沿用既有口径。
        guard store.add(content: text) else {
            return .result(dialog: "没记成功")   // 空内容 / 同内容 5 分钟内重复
        }
        // 置顶：只在队首确实是自己刚写的那条时才动它
        //（add() 撞到去重分支时不会新增，别把用户上一条旧备忘误置顶）
        if priority == .pinned, let first = store.memos.first, first.content == text {
            store.togglePin(first)
        }
        return .result(dialog: priority == .pinned ? "已记到轻聊备忘录并置顶" : "已记到轻聊备忘录")
    }
}

// MARK: - 动作 3：检查收件箱（零参数、只读）

struct CheckInboxIntent: AppIntent {

    static var title: LocalizedStringResource { "检查轻聊收件箱" }

    static var description: IntentDescription {
        IntentDescription("看一眼轻聊收件箱里还没处理的消息（只读，不改变已处理状态）")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let texts = try await QingliaoIntentClient.inboxTexts()
        guard !texts.isEmpty else { return .result(dialog: "轻聊收件箱是空的") }
        let head = texts.prefix(3).map { QingliaoAIReply.shorten($0, limit: 40) }.joined(separator: "；")
        return .result(dialog: qlDialog("轻聊收件箱 \(texts.count) 条：\(head)"))
    }
}

// MARK: - 动作 4~7：打开 App 到指定页（零参数）
//
// 口径（v4.0.x，用户实测踩出来的）：
// · 旧写法 `OpenURLIntent` + `.result(opensIntent:)` 在 iOS 26 上**当场报错**——
//   「The provided URL scheme `qingliao` is unsupported; launch is prohibited」，
//   即系统拒绝从 intent 里 launch 自己的自定义 scheme（快捷指令自动化里必现）。
// · 改用 `supportedModes = .foreground(.immediate)`（`.foreground` 的文档口径：系统把 App 带到前台后
//   才跑动作），intent 代码于是就在 **App 进程**里执行 → 目标页直接用 `QingliaoRouteHandoff` 投递给
//   `DockTabView`，不再过系统 launch 这一关。
// · `openAppWhenRun` 仍不用：iOS 16–26 已标 Deprecated，扩展里置 true 还会直接编译报错。

struct OpenChatIntent: AppIntent {
    static var title: LocalizedStringResource { "打开轻聊聊天" }
    static var description: IntentDescription { IntentDescription("打开轻聊并回到聊天页") }
    /// 计算属性而非 `static let`：与 `title` 同一理由——Swift 6 严格并发下静态存储属性会报
    /// nonisolated global shared mutable state，CI Archive 直接失败。
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        QingliaoRouteHandoff.request(.chat)
        return .result()
    }
}

struct OpenSessionsIntent: AppIntent {
    static var title: LocalizedStringResource { "打开轻聊会话列表" }
    static var description: IntentDescription { IntentDescription("打开轻聊并切到会话列表") }
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        QingliaoRouteHandoff.request(.sessions)
        return .result()
    }
}

struct OpenDashboardIntent: AppIntent {
    static var title: LocalizedStringResource { "打开轻聊看板" }
    static var description: IntentDescription { IntentDescription("打开轻聊并切到看板页") }
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        QingliaoRouteHandoff.request(.dashboard)
        return .result()
    }
}

struct OpenLifeIntent: AppIntent {
    static var title: LocalizedStringResource { "打开轻聊生活页" }
    static var description: IntentDescription { IntentDescription("打开轻聊并切到生活页（备忘 / 待办 / 股票 · 资讯 / 快递）") }
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        QingliaoRouteHandoff.request(.life)
        return .result()
    }
}

// MARK: - 动作 8：打开快捷动作菜单（零参数，**非 tab**）
//
// 用户 2026-09-27 提的：「快捷指令能增加打开到这个界面吗」——「这个界面」是智慧球长按菜单
// （8 颗胶囊：新建会话 / AI 速记 / 今日待办 / AI 识别 / 语音对话 / 语音输入 / 会话纪要 / 拍照识别）。
// 它不是某一页（`DockTab` 里没有它），所以投的是**非 tab 路由** `.quickActions`；
// 落地点仍是 `DockTabView.applyRoute`（非 tab 分支：开菜单覆盖层，不切页）。
// 前台模式与上面四条同一理由：iOS 26 不许 intent 里让系统 launch 自己的 scheme。

struct OpenQuickActionsIntent: AppIntent {
    static var title: LocalizedStringResource { "打开轻聊快捷菜单" }
    static var description: IntentDescription { IntentDescription("打开轻聊并弹出智慧球快捷菜单（8 个常用动作）") }
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        QingliaoRouteHandoff.request(.quickActions)
        return .result()
    }
}

// MARK: - App Shortcuts（Siri 短语）
//
// 没有这一段，动作只出现在快捷指令 App 里；有了它才能"嘿 Siri，问轻聊"。
// 规则（Apple 文档 + 构建期/运行时校验，逐条对过）：
//  · 每条短语**必须**含 `\(.applicationName)`：构建期给告警，运行时索引直接丢弃该条短语，
//    用户喊了永远没反应 —— 而且短语是"已发布的契约"，改词会破坏用户已有的口令记忆；
//  · `shortTitle` / `systemImageName` 必须给：省略会绑到 iOS 17 起废弃的那个重载，
//    磁贴在快捷指令/Spotlight 里空白；
//  · 短语里**不要**引用自由文本参数：String / 数字 / 日期没有有限取值集，Siri 无法匹配
//    （只有 AppEnum / AppEntity / 带 displayName 的 Bool 可以）。所以下面的短语都不带参数 ——
//    Siri 会按参数标题追问「问题是什么？」，这正是"不打开 App 也能用"的关键一步。

struct QingliaoAppShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
            AppShortcut(
                intent: AskQingliaoIntent(),
                phrases: [
                    "问\(.applicationName)",
                    "问一下\(.applicationName)",
                    "\(.applicationName)问答",
                ],
                shortTitle: "问轻聊",
                systemImageName: "bubble.left.and.bubble.right"
            )
            AppShortcut(
                intent: AddMemoIntent(),
                phrases: [
                    "记到\(.applicationName)",
                    "\(.applicationName)记一笔",
                ],
                shortTitle: "记到备忘录",
                systemImageName: "square.and.pencil"
            )
            AppShortcut(
                intent: CheckInboxIntent(),
                phrases: [
                    "\(.applicationName)收件箱",
                    "看看\(.applicationName)收件箱",
                ],
                shortTitle: "检查收件箱",
                systemImageName: "tray.full"
            )
            AppShortcut(
                intent: ReportEventIntent(),
                phrases: [
                    "给\(.applicationName)发事件",
                ],
                shortTitle: "发送事件",
                systemImageName: "bell.badge"
            )
            AppShortcut(
                intent: OpenChatIntent(),
                phrases: [
                    "回到\(.applicationName)聊天",
                    "\(.applicationName)聊天",
                ],
                shortTitle: "打开聊天",
                systemImageName: "message"
            )
            AppShortcut(
                intent: OpenSessionsIntent(),
                phrases: [
                    "\(.applicationName)会话列表",
                    "看\(.applicationName)的历史会话",
                ],
                shortTitle: "会话列表",
                systemImageName: "clock"
            )
            AppShortcut(
                intent: OpenDashboardIntent(),
                phrases: [
                    "打开\(.applicationName)看板",
                    "\(.applicationName)看板",
                ],
                shortTitle: "打开看板",
                systemImageName: "square.grid.2x2"
            )
            AppShortcut(
                intent: OpenLifeIntent(),
                phrases: [
                    "打开\(.applicationName)生活页",
                    "看\(.applicationName)的备忘录",
                ],
                shortTitle: "生活页",
                systemImageName: "sparkles"
            )
            AppShortcut(
                intent: OpenQuickActionsIntent(),
                phrases: [
                    "打开\(.applicationName)快捷菜单",
                    "\(.applicationName)快捷动作",
                ],
                shortTitle: "快捷菜单",
                systemImageName: "hand.tap"
            )
    }
}
