import SwiftUI
import CoreLocation
import UIKit

enum DockTab: String, CaseIterable, Identifiable {
    // v4.0.69（用户 2026-10-07 拍板）：dock 顺序 = 会话 → 生活 → 智慧球 → 看板 → 设置。
    // ⚠️ 智慧球必须留在第 3 槽：DockOrbOverlay / 烟花原点按 slotIndex: 2 硬编码算几何
    //    （行号会漂移，直接按 slotIndex: 2 全文搜），球心取真实槽位按钮中心。
    //    （v4.0.70 曾加过「Dock 顺序自定义」，用户 2026-10-07 拍板整体回退到 4.0.69 形态，勿再接回。）
    // （enum 声明序与 TabView 内声明序一致，便于对照；TabView 顺序由视图插入序决定）
    // v4.0.x：dock 图标换 B 组（用户选定）：看板 chart.pie / 生活 heart / 设置 gearshape（空心）；
    // 会话 clock 保留。语义直白风，每个图标一眼看出页面用途；智慧球槽位（chat）不受影响。
    case sessions, life, chat, dashboard, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: "会话"
        case .dashboard: "看板"
        case .chat: "聊天"
        case .life: "生活"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .sessions: "clock"
        case .dashboard: "chart.pie"
        case .chat: "message.fill"
        case .life: "heart"
        case .settings: "gearshape"
        }
    }

}

struct DockTabView: View {
    @State private var selected: DockTab = .chat
    // v3.6.2：dock 智能球点击 → 全屏粒子爆发（原由聊天页智能球展开触发，球迁到 dock 后跟随迁移）
    @State private var showDockBurst = false
    /// v4.0.7：烟花粒子特效开关（设置 → 外观 → 交互；与「输入框流光」同一排）。默认开，关掉后点球不放烟花。
    @AppStorage("qingliao_dock_burst") private var dockBurstOn = true
    /// v3.6.2：分享/深链等「程序化切到聊天页」跳过烟花（烟花的语义是「点了 dock 智能球」）
    @State private var skipNextBurst = false
    /// v3.9.33：球第三态「刚答完未查看」——AI 收尾时用户不在这页
    @State private var orbUnseen = false
    /// v3.9.33：球错误态——上一次请求真失败（用户主动停止不算），进聊天页即清
    @State private var orbFailed = false
    /// v3.9.33：实测 dock bar 高度（DockOrbOverlay 回写）——烟花原点与球心同源，别各算一套
    @State private var dockBarHeight: CGFloat = DockOrbOverlay.fallbackBarHeight
    /// v3.9.59（攒版）：长按智慧球 → 快捷菜单（新建会话 / AI 速记 / 语音输入 / 今日待办）
    @State private var showOrbMenu = false
    /// v3.9.78：本次菜单的锚点来自聊天页宠物（全局中心 + 尺寸）；nil = dock 智慧球。
    /// 菜单收起时清零（见 onChange），免得下次长按球时菜单锚在宠物位置。
    @State private var orbMenuPetAnchor: OrbPetAnchor?
    /// v3.9.76：智慧球「AI 识别」浮层（球上悬浮结果卡 + 扫描环 + 背景虚化）
    @State private var showIdentify = false
    /// v3.9.76：智慧球「语音对话」全屏页（说 → 自动发 → 自动念 → 自动续听）
    @State private var showVoiceDialog = false
    /// v3.9.59：速记弹窗（AI 速记 → 备忘录；今日待办 → 待办清单）
    @State private var quickCapture: QuickCaptureMode?
    /// v3.9.82：译文弹窗（用户「这个卡片改弹窗吧，跟 AI 速记弹窗一致」）——
    /// 识别浮层翻出译文后不再就地出卡，改成回宿主弹这一张（形态照 QuickCaptureSheet）。
    @State private var translateResult: TranslateResult?
    /// v4.0.x：长按菜单「会话纪要」全屏页（页内自带 dismiss；本页只负责呈现与收口）
    @State private var showMinutes = false
    /// v4.0.x：长按菜单「拍照识别」系统相机（拍一张 → **就地**进「AI 识别」浮层让 AI 看图回答）
    @State private var showCamera = false
    /// v4.0.x（2026-09-27 改口径）：拍完那张照片 → 交给「AI 识别」浮层**就地**看图回答
    ///（形态与 AI 识别同款：球上浮层卡 + 背景虚化 + 球心扫描环；**不进会话、不切聊天页**）。
    /// 旧口径是走 ShareRouter 分享管道发进当前对话，用户实测后否掉了「污染会话」。
    /// ⚠️ 它其实是「识别浮层」这个位态的**载荷**：`showIdentify = true` 时一起设，关浮层时必须一起清 ——
    ///   漏清 = 下一次点普通「AI 识别」会莫名对上一张老照片提问（本仓「状态没复位」那一类坑）。
    @State private var identifyPhoto: UIImage?
    /// v3.9.82：下一次进识别浮层时**直接以翻译模式起手**（只有译文弹窗的「换一张」会置真；
    /// 浮层每次 onAppear 都复位，所以事后必须清掉，否则下一次拍照会莫名出译文）。
    @State private var identifyStartTranslate = false
    @Environment(AuthStore.self) private var auth
    @Environment(ChatStore.self) private var chat
    @Environment(StreamClient.self) private var stream
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.colorScheme) private var colorScheme

    /// v3.6.2：聊天槽位用智能球替身——仅 iPhone（iPad 保持系统图标原样）
    private var orbInDock: Bool { hSize != .regular }
    /// dock 槽位数（5：会话/生活/聊天/看板/设置）
    private var dockSlotCount: Int { 5 }
    /// v3.9.33：这页的回复是否正摆在用户眼前 = 聊天 tab **且**当前会话就是刚收尾的那条流。
    /// 只看 `selected == .chat` 会漏报——人在聊天页看会话 B 时，会话 A 的回复落地也该提示。
    private var chatVisible: Bool {
        selected == .chat && auth.currentStreamSessionId == chat.sessionId
    }

    var body: some View {
        // v3.0.64：改用 iOS 26 系统原生 TabView tab bar —— 系统自动渲染液态玻璃 tab bar，
        // 自带按压放大/流动折射/边缘高光（即用户要的控制中心那种原生效果）。
        // 弃自定义 DockBar / DockVisibility / 手势（系统 tab bar 原生支持这些，无需自研）。
        ZStack {
            // v4.0.72：TabView 底下垫一层**静态**环境渐变底（不参与任何切页动画）。
            // 根因：切页入场 = 整页 scale 0.96 + 下移 10pt，页面连自带背景一起缩 →
            // 动画期间四周露出的环是**窗口白底**，右上电池区最扎眼（用户 2026-10-07 反馈
            // 「tap 页切换时渐变背景右上电池图标处先白一下才切」；v4.0.71 的页内过扫描画不到页面外，无效）。
            // 垫底后露出的环 = 同款渐变，肉眼无感。渐变是静态复制品不接收点击；
            // 不用纯色是 v3.4.29 红线（掐死 tab bar 玻璃采样）——光晕层与页面自铺的是同一视图，
            // tab bar 玻璃采样到的仍是真实滚动内容，不受影响。
            EnvironmentGlowLayers(scheme: colorScheme)
                .ignoresSafeArea()
                .allowsHitTesting(false)


            TabView(selection: $selected) {
                // v4.0.69（用户 2026-10-07 拍板 dock 顺序：会话 → 生活 → 智慧球 → 看板 → 设置）
                SessionsView(onOpenSession: {
                    if selected != .chat { skipBurstOnce() }
                    selected = .chat
                })
                    .tabTransition(for: .sessions, selected: $selected)
                // v3.6.2：生活页（原看板「生活数据」栏目迁入）
                LifeView(isActive: selected == .life)
                    .tabTransition(for: .life, selected: $selected)
                chatTab
                // v3.4.26：isActive 参数直传（selected==.dashboard），替代 qingliaoDashboardLeave/Refresh 通知——
                // 轮询暂停/恢复收进 DashboardView 自身生命周期，去隐式耦合
                DashboardView(isActive: selected == .dashboard)
                    .tabTransition(for: .dashboard, selected: $selected)
                // v4.0.0：设置页大类 → 明细的二级页需要 NavigationStack 才有返回栈
                // （TabView 里裸放 NavigationLink 点了不推、也不显示返回键）。
                // 只包设置 tab —— 其他 tab 的层级结构一行不动。
                NavigationStack {
                    SettingsView()
                        // 🚨 审查 F7：iOS 26 的 NavigationStack 在无 navigationTitle 时仍保留
                        //   导航栏占位 → 顶部多一段空白/空返回槽。本页用自绘 PageHeader（不占系统栏），
                        //   故显式藏掉。参考同仓同款：RecordSection:236 / MemoSection:235 / TodoSection:224。
                        //   二级页仍要系统侧滑返回，但它的 PageHeader 已自绘返回键，不靠系统栏。
                        .toolbar(.hidden, for: .navigationBar)
                }
                    .tabTransition(for: .settings, selected: $selected)
            }
            // v4.0.49x：启动链折叠（防 demangler 栈溢出）——原 24 条顶层修饰器按序折进 4 个具名分组，
            // body 这里只留 4 个 .modifier(…) 泛型调用。事故/手法同 ChatView.v4.0.49：
            // 巨型链把 body 编译后类型名撑到 2574 字符（全 App 最长），Swift 运行时按嵌套层数递归
            // demangle 类型名（每层约 5-6 帧、每帧约 9.3KB 栈），主线程 1MB 栈用尽即「一点开就闪退」。
            // 语义逐条守恒：修饰器种类/数量/顺序/参数一个未改，只把链搬进 applyDockTabChromeN。
            // 🚨 谁也不许把这些链再内联回 body —— 改链请改下方 private extension 的 applyDockTabChromeN。
            .modifier(DockTabChrome1(host: self))
            .modifier(DockTabChrome2(host: self))
            .modifier(DockTabChrome3(host: self))
            .modifier(DockTabChrome4(host: self))
        }
    }

    // MARK: - v3.6.2 聊天 tab（两态，见 chatTab）

    /// 聊天槽位（两态：`orbInDock` 就是 `hSize != .regular`，两者互补 → 原先的第三分支永不执行，已删）：
    ///   · iPad 宽屏：会话 + 聊天双栏，系统 message 图标
    ///   · iPhone：item 置空、无文字，整颗智能球由 DockOrbOverlay 居中绘制
    ///
    /// 聊天页要 tab bar **不铺那层液态玻璃**这件事，两条路都真机判过无效，**到此为止**：
    ///   · 方案 A（v3.9.46，SwiftUI `.toolbarBackground(.hidden, for: .tabBar)`）——iOS 26 只褪了
    ///     背景色、玻璃层照旧。
    ///   · 方案 B（v3.9.47，UIKit：把真实 `UITabBar` 的 standard/scrollEdgeAppearance 换成
    ///     `configureWithTransparentBackground()` 副本）——同样没褪掉，v3.9.48 用户判「回滚」，
    ///     `TabBarGlass.swift` 探针已整块删除。
    /// 第三条路也不要试（不再有公开出口的判断），更**不许**退回在 TabView 下层铺不透明色——
    /// 那会掐死所有页的滚动边缘折射（v3.4.29 红线）。
    @ViewBuilder
    private var chatTab: some View {
        if hSize == .regular {
            HStack(spacing: 0) {
                SessionsView(onOpenSession: nil)
                    .frame(width: 320)
                    .background(Color(uiColor: .systemBackground))
                Divider().opacity(0.3)
                ChatView()
            }
            .tag(DockTab.chat)
            .tabItem { Label(DockTab.chat.title, systemImage: DockTab.chat.icon) }
        } else {
            ChatView()
                // v4.0.72：与其它四页同款轻量入场（轻微放大 + 从下方浮起；「从会话卡展开」已整体移除）。
                .chatZoomEntry(selected: $selected)
                .tag(DockTab.chat)
                // 槽位视觉为空（球由 DockOrbOverlay 绘制）→ 补无障碍标签，VoiceOver 仍读得出「聊天」
                .tabItem { Text("").accessibilityLabel("聊天") }
        }
    }

    /// v3.9.33：清掉球上的「未查看 / 失败」提示（进聊天页 = 回复已在眼前）
    private func clearOrbNotice() {
        orbUnseen = false
        orbFailed = false
    }

    /// 程序化切页前调用：本次切到聊天页不放烟花（0.6s 内未消费则自动复位，避免标志残留吞掉下一次真点击）
    private func skipBurstOnce() {
        skipNextBurst = true
        Task { try? await Task.sleep(for: .seconds(0.6)); skipNextBurst = false }
    }

    /// 点 dock 智能球 → 烟花（约 1.55s 后移除特效层，与原型一致）
    private func fireDockBurst() {
        // v4.0.7：开关关着就不放（skipBurstOnce 的去抖逻辑不受影响，语义仍是「程序化切页不放烟花」）
        guard dockBurstOn else { return }
        showDockBurst = true
        Task { try? await Task.sleep(for: .seconds(1.55)); showDockBurst = false }
    }

    // MARK: - v3.9.59 长按智慧球快捷菜单

    /// v3.9.82：「发给 AI」的**唯一出口**（识别动作条 / 译文弹窗共用）——
    /// 切聊天页 + post `.qingliaoTaskSend`（与任务中心、备忘录「发给 AI」同一条通道），
    /// 0.35s 闸：转场还在跑时投递，聊天页可能还没进树，通知会落空。
    private func askAI(_ text: String) {
        showIdentify = false
        identifyStartTranslate = false
        identifyPhoto = nil
        if selected != .chat { skipBurstOnce() }
        selected = .chat
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.35))
            NotificationCenter.default.post(name: .qingliaoTaskSend, object: text)
        }
    }

    /// 四个胶囊动作分发——全部复用既有入口，不新造状态：
    ///   新建会话 → requestNewSession（ChatView 的 pendingNewSession 两步走清屏，勿直接清数据）
    ///   AI 速记  → 速记弹窗 → MemoStore（source "orb"）
    /// v4.0.x：弹菜单的**两个**落点（都在宿主里，petHero 侧拿不到这些私有状态）：
    ///   ① `openOrbMenuAtDockSlot` —— 锚在 dock 槽位（宠物不在屏时的兜底那张画面）；
    ///   ② `requestOrbMenuAtPetAnchor` —— 请求宠物应答锚点（真正的「长按宠物那套画面」）。
    ///
    /// ⚠️ 两条**都**必须带 `guard !showOrbMenu`：`OrbMenuFromPetModifier.openMenuAtPetAnchor` 也有这条互斥，
    /// 少了它就会把已经开着（宠物锚点）的菜单的锚点从宠物改回 dock 槽位 —— v3.9.79「两只宠物」同类回退。
    private func openOrbMenuAtDockSlot() {
        guard !showOrbMenu else { return }
        if showIdentify || showVoiceDialog { return }
        orbMenuPetAnchor = nil
        showOrbMenu = true
    }

    /// v4.0.x：请求「在宠物锚点弹菜单」。握手：置 pending → 喊一声已挂树的宠物（当场应答），
    /// 应答侧处理见 ChatView。应答迟迟不来（宠物不在屏 / 横向边缘态）→ 1.2s 后退回 dock 槽位。
    private func requestOrbMenuAtPetAnchor() {
        let seq = OrbPetAnchorRegistry.beginRequest()
        if OrbPetAnchorRegistry.requestMenuOnPetAnchor() {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                // 🚨 三道闸缺一不可：① 序号仍是最新（没被后来的请求抢）② pending 还挂着（宠物还没应答）
                //    ③ 菜单此刻没开着（别把已开着的宠物锚点菜单拽回 dock 槽位）。
                guard OrbPetAnchorRegistry.isLatest(seq),
                      OrbPetAnchorRegistry.hasPendingMenu else { return }
                OrbPetAnchorRegistry.cancelPendingMenu()
                openOrbMenuAtDockSlot()
            }
        }
    }

    /// 智慧球/宠物菜单的九颗胶囊动作分发（唯一真源：长按球、长按宠物、桌面快捷方式三条入口共用）。
    ///   语音输入 → 切聊天页 + 进程内通知（ChatView.toggleVoiceMode，与输入框长按同一条路径；
    ///              DockTabView 摸不到 ChatView 的 @State，通知是本仓既有的跨页触发模式）
    ///   今日待办 → 速记弹窗 → TodoStore（source "orb"）
    private func handleOrbAction(_ action: OrbQuickAction) {
        // v3.9.82（代码审查）：桌面快捷方式是**绕过菜单**的第二入口 —— 球命中层要求
        // `!showOrbMenu && !showIdentify && !showVoiceDialog` 才在，快捷方式不经过它，而且它能在任意时刻
        // 进来（含 App 在后台、识别浮层 / 速记弹窗 / 译文弹窗 / 语音对话还开着的时候）。所以这里统一把
        // 「瞬时 UI」收干净再走分支：原先的互斥只靠可达性成立，新入口一来就漏。
        // ⚠️ 本函数的全部呈现位态（9 个：菜单 / 速记 sheet / 识别浮层 / 换一张哨兵 / 语音对话 /
        //    译文 sheet / 会话纪要全屏页 / 拍照识别相机 / 拍照识别看图页）都必须在这里清掉一个不漏 ——
        //    漏一个就是「点了没反应」（sheet 压住新开的浮层）或同一宿主两个 sheet 同时为真
        //    （本文件 231 行记着那个坑）。新增位态时同步扩这里 + 真值表护栏。
        // 清标志与本分支的置位都在**同一次事务**里，最终值以分支为准（不会顺手关掉本分支要开的东西）；
        // 也顺带清掉「换一张」哨兵 —— 快捷方式进 AI 识别应正常起手，不该继承上次的翻译模式。
        showOrbMenu = false
        quickCapture = nil
        showIdentify = false
        identifyStartTranslate = false
        showVoiceDialog = false
        translateResult = nil
        showMinutes = false
        showCamera = false
        identifyPhoto = nil
        switch action.id {
        case 0:   // 新建会话
            // v3.9.59：已在聊天页 = selected 不变、不会放烟花，白置标志会吞掉紧接着的一次真点击烟花
            if selected != .chat { skipBurstOnce() }
            selected = .chat
            chat.requestNewSession()
        case 1:   // AI 速记
            quickCapture = .memo
        case 2:   // 语音输入
            if selected != .chat { skipBurstOnce() }
            selected = .chat
            NotificationCenter.default.post(name: .qingliaoOrbVoiceInput, object: nil)
        case 3:   // 今日待办
            quickCapture = .todo
        case 4:   // AI 识别（v3.9.76）
            // 菜单层与识别浮层同挂 dock overlay：不先收菜单就是两层同时吃触摸（收口已提到函数开头）
            showIdentify = true
        case 5:   // 语音对话（v3.9.76）
            // 与速记弹窗是两种 presentation：同时挂会互相顶掉（收口已提到函数开头）
            // 🚨 必须先让聊天页进视图树（与 case 2/4 同款闸）：本页的两条命脉都挂在 ChatView 上 ——
            //   「发送」走 `.qingliaoTaskSend`（ChatView.sendCore 是唯一接收方），
            //   「全念」走 ChatView 的 assistantLandedToken（自动朗读的触发点）。
            //   两者都只在 ChatView **在视图树里**才生效；而智慧球在任意 tab 都在，
            //   用户在会话/看板/生活页长按球进来说话，不切页就会「消息静默消失 + 一句也不念」。
            if selected != .chat { skipBurstOnce() }
            selected = .chat
            showVoiceDialog = true
        case 6:   // 会话纪要（v4.0.x 新胶囊）
            // 🚨 必须先让聊天页进视图树（与 case 2/4/7 同款闸）：纪要整理完那张卡由
            //    `MeetingMinutesView` post `.qingliaoMinutesCard`，**唯一接收方是 ChatView 的 onReceive**
            //    —— 用户在生活页/看板页长按球进纪要、录完音整理好，卡片会因为 ChatView 不在树里而
            //    静默消失（备忘存了、卡没了，用户只看到「整理完成」）。
            //    顺带的好处：dismiss 纪要页出来就是聊天页，刚落的那张卡就在眼前。
            // 全屏页而非 sheet：纪要正文要占满整屏读，页内自带 dismiss（与语音对话页同一口径）。
            if selected != .chat { skipBurstOnce() }
            selected = .chat
            showMinutes = true
        case 7:   // 拍照识别（v4.0.x 新胶囊）
            // 无摄像头设备（模拟器 / 部分无相机 iPad）present .camera 会抛 NSInvalidArgumentException
            // —— 与 OrbIdentifyOverlay.openCameraOrAlbum、ChatView 同一道闸，别在三处写出不同判据。
            // 兜底退回既有的「AI 识别」浮层（它自带相册入口），比静默无反应诚实。
            // ⚠️ 2026-09-27 改口径：拍完**就地**进「AI 识别」浮层让 AI 看图回答（球上浮层卡 + 背景虚化 +
            //   球心扫描环，与「AI 识别」同一形态）—— 不发进会话、不切聊天页、不落 ChatStore。
            //   旧口径的分享管道已撤，原因见 handleCameraShot 的注释。
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                showCamera = true
            } else {
                showIdentify = true
            }
        case 8:   // 记一笔（v3.9.96 新胶囊）：弹窗输入金额+用途 → 记账卡片（与聊天页/生活页同口径落库）
            quickCapture = .expense
        default:
            break
        }
    }

    // MARK: - v4.0.x 拍照识别（长按菜单新胶囊 id 7）

    /// 相机呈现内容。抽成属性是给 body 巨型链减负（不要在那条链上写字面量闭包 → CI 类型检查超时红线，
    /// run #571 那类）。`.ignoresSafeArea()` 不能省：只换 fullScreenCover 容器不够，内容默认仍受安全区
    /// 约束 → 顶部露宿主黑边（v3.9.75 用户实测报过）。
    private var cameraCover: some View {
        CameraPicker { image in handleCameraShot(image) }
            .ignoresSafeArea()
    }

    /// 拍完一张 → **就地**进「AI 识别」浮层，让 AI 看图回答（形态 = 球上浮层卡 + 背景虚化 + 球心扫描环）。
    ///
    /// ⚠️ 口径变更（2026-09-27，用户拍板）：**不要再退回分享管道**。旧口径（v3.9.93）是
    ///   `ShareRouter.enqueue(sourceName: "拍照识别")` → `selected = .chat` → 0.35s 后 post
    ///   `.qingliaoShareIncoming` → ChatView.drainShareInbox 自动压图并 sendCore，把
    ///   「帮我看看这张照片」+ 图发进**当前会话**。用户实测后要的是「不发送当前对话框，直接在当页做」：
    ///   拍照识别是「看一眼就走」的即时动作，不该往会话里堆消息、也不该把人从别的 tab 拽到聊天页。
    ///   （分享管道本身仍在，服系统分享 / 分享扩展；这里只是不再用它。）
    ///   形态也定过一版：曾短暂做成「全屏看图页」，用户随即改回**与「AI 识别」同一形态的球上浮层卡** ——
    ///   所以这套 UI 落在 `OrbIdentifyOverlay`（浮层新增三段：askingPhoto / photoAnswer / photoFailed），
    ///   **不要再另造一个整屏页**（两套形态并存就是这次返工的原因）。
    ///
    /// 0.35s 闸：相机与浮层是**同一宿主上的两种呈现**，相机 dismiss 与浮层出现同帧会被吞（本仓记过这个坑，
    ///   `askAI` 一字不差）。所以先关相机、错开一拍再把照片交给浮层。
    /// 不切页之后 `skipBurstOnce()` 也不需要了 —— 它只为「从别的 tab 跳聊天页」时的烟花去抖。
    private func handleCameraShot(_ image: UIImage) {
        showCamera = false                      // 关相机（菜单已在 handleOrbAction 的收口里关掉）
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.35))
            identifyPhoto = image               // 载荷：浮层起手就对着这张问 AI（关浮层时一起清）
            showIdentify = true
        }
    }

    // MARK: - v3.9.82 桌面图标长按快捷方式
    /// 快捷方式 id → 动作分发。**刻意只做一层转发**：真正的分发仍是 handleOrbAction，
    /// 避免「桌面快捷方式」和「长按智慧球菜单」各维护一套动作语义（必然漂移）。
    private func dispatchQuickAction(_ id: Int) {
        guard let action = HomeShortcut.action(id: id) else { return }
        handleOrbAction(action)
    }

    // v3.9.82：`dispatchPendingQuickAction()` 的定义已搬到 `OrbMenuFromPetModifier`（唯一的调用点在那里）。
    // 本类型别再放第二份：跨类型引用不到私有成员就是这么来的（本地 -parse 全绿、CI 才报 has no member）。

    // MARK: - v3.4.14 系统分享接入口
    /// v4.0.x：「某条深链 / 某个 intent 要开哪一页」的**唯一落地点**。
    ///
    /// 三条来源共用它，别再各写一份 tab 切换：`onOpenURL` 的 `qingliao://<tab>`、
    /// intent 的进程内广播、intent 冷启动兜底补读。
    /// 已在目标页时不 `skipBurstOnce()` —— 白置标志会吞掉紧接着的真点击烟花
    ///（与 `.qingliaoOpenChat` 那条同一理由）。
    private func applyRoute(_ route: QingliaoDeepLink.Route) {
        // v4.0.x：非 tab 路由（快捷动作菜单）—— 先切到聊天页，再在**宠物位置**弹菜单。
        // 与菜单互斥的两个浮层先关掉（口径同 onChange(of: selected)：新浮层不许与它们叠）。
        if QingliaoDeepLink.nonTabRoutes.contains(route) {
            // ⚠️ 瞬时 UI 要清**全部 9 个**呈现位态，口径与 `handleOrbAction` 的收口逐项对齐
            //（那份注释里记着原因：桌面快捷方式是绕过命中层的第二入口，漏一个就是「点了没反应」——
            //  sheet 压住新开的浮层）。这里原先只清了识别/语音两个，被速记 sheet、译文弹窗、
            //  纪要全屏页、相机盖住时菜单弹了但用户看不见。
            showOrbMenu = false
            quickCapture = nil
            showIdentify = false
            identifyStartTranslate = false
            showVoiceDialog = false
            translateResult = nil
            showMinutes = false
            showCamera = false
            identifyPhoto = nil
            // v4.0.x（用户：「快捷菜单改成跳转到长按卡通宠物那个界面」）：这条入口现在也走**长按宠物那套画面** ——
            // 胶囊在欢迎页卡通宠物下方绽放，锚点 = 宠物真实位置。锚点只有 ChatView 有（dock 拿不到几何），
            // 所以走一次握手：dock 请求 → `petHero` 应答，两条来路都汇到与长按**完全同一条**通知，
            // 动作分发/互斥收口/锚点刷新一处都不复制。
            //
            // 🚨 切过页之后**不能同轮就弹菜单**（详见下面 wasOnChat 处那几行）。
            //
            // 宠物**不在屏**时退回 dock 槽位锚点弹（那张画面里也画宠物，v3.9.82「只保留一个跳转画面」口径）：
            //   ① 会话已有消息 → 欢迎页压根不渲染，等下去也没用，直接弹；
            //   ② 空会话但欢迎页迟迟不上报（横屏/键盘等边缘态）→ 握手超时后兜底弹，不让用户看到「点了没反应」。
            let wasOnChat = selected == .chat
            // 🚨 切页与弹菜单**必须错开一轮**，与「会话有没有消息」正交：
            //    `selected` 的变更会在 `onChange(of: selected)` 里执行「if showOrbMenu { showOrbMenu = false }」，
            //    同一轮里先写 true 再写 false → SwiftUI 只渲染最终值 false → 菜单一次都不出现
            //    （症状：空会话/有消息两种情况都是「只跳页不弹菜单」）。
            //    所以：切过页的**全部**路径都延到下一轮；本来就在聊天页的同步弹（那里没有这次写入）。
            if !wasOnChat {
                skipBurstOnce()
                selected = .chat
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))   // 让切页与 onChange(of: selected) 先落定
                    if chat.messages.isEmpty {
                        requestOrbMenuAtPetAnchor()
                    } else {
                        openOrbMenuAtDockSlot()   // 宠物不在屏（欢迎页不渲染）→ 退回 dock 槽位
                    }
                }
            } else if !chat.messages.isEmpty {
                openOrbMenuAtDockSlot()
            } else {
                requestOrbMenuAtPetAnchor()
            }
            return
        }
        guard let tab = DockTab(rawValue: route.rawValue) else { return }
        if selected != tab { skipBurstOnce() }
        selected = tab
    }

    /// 解析系统分享的 URL（文件/图片/文本/链接）→ 生成 SharedPayload 入 ShareRouter，切到聊天页并广播。
    /// v3.4.24：地图 App 分享的定位链接 → 解析经纬度入 SharedPayload.location（AI 推荐周边）。
    private func handleShareURL(_ url: URL) {
        // v3.9.7：实时活动（灵动岛 / 锁屏横幅）点按深链——`widgetURL` 传进来的「回到会话」
        // v3.9.32：泛化为快捷指令 / Siri 的页面深链（qingliao://chat|sessions|dashboard|life|settings）。
        // Route.rawValue 与 DockTab.rawValue 一一对应；其余 URL 原样落到下面的分享分支。
        // （原「只认 host == chat」的窄分支已由这里覆盖——chat 也是 Route 的一个 case，别再写第二份判断。）
        if let route = QingliaoDeepLink.route(for: url) {
            applyRoute(route)
            return
        }
        var payload: SharedPayload?
        if url.isFileURL {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let image = UIImage(contentsOfFile: url.path) {
                payload = SharedPayload(text: nil, image: image, sourceName: url.lastPathComponent)
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                payload = SharedPayload(text: text, image: nil, sourceName: url.lastPathComponent)
            }
        } else if let scheme = url.scheme, scheme == "http" || scheme == "https" {
            // v3.4.24：先试地图定位链接解析（geo:/高德/百度/腾讯/苹果地图…）
            if let loc = MapLocationParser.parse(url) {
                let cl = CLLocation(latitude: loc.coord.latitude, longitude: loc.coord.longitude)
                payload = SharedPayload(text: url.absoluteString, image: nil,
                                        sourceName: loc.place, location: cl)
            } else {
                payload = SharedPayload(text: url.absoluteString, image: nil, sourceName: nil)
            }
        } else if url.scheme?.lowercased() == "geo" {
            // v3.4.24：geo: URI（部分地图 App 用非 http scheme 分享）
            if let loc = MapLocationParser.parse(url) {
                let cl = CLLocation(latitude: loc.coord.latitude, longitude: loc.coord.longitude)
                payload = SharedPayload(text: url.absoluteString, image: nil,
                                        sourceName: loc.place, location: cl)
            }
        } else if let text = try? String(contentsOf: url, encoding: .utf8) {
            payload = SharedPayload(text: text, image: nil, sourceName: url.lastPathComponent)
        }
        guard let payload else { return }
        ShareRouter.shared.enqueue(payload)
        skipBurstOnce()
        selected = .chat
        NotificationCenter.default.post(name: .qingliaoShareIncoming, object: nil)
    }

    // MARK: - v3.9.7 灵动岛按钮动作

    /// 灵动岛「停止生成」——两条入口（App 活着时的进程内通知 / 进程刚被拉起的兜底 flag）
    /// 汇到同一处，走的是聊天页「停止」按钮同一个 `StreamClient.stop`。
    /// v3.9.7 review 修复：输入栏停止其实是**两件事**（`clearPendingQueue()` + `stream.stop()`），
    /// 这里少了清队列会出现「点了停止，排在后面的消息又自己发出去」（v2.0.88：回答收尾自动发队列下一条）。
    /// `pendingQueue` 是 `ChatView` 的 `@State`，Dock 摸不到 → 用进程内通知请聊天页清。
    private func handleLiveActivityStop() {
        _ = LiveActivityActionBridge.consume()   // 清掉兜底 flag（两条路径都到这儿，幂等）
        // 🚨 发布前复核修正（2026-09-30）：①归属从 runner 自己取 —— `auth.currentStreamSessionId` 只表示
        // 「最后开跑/接回的流属于哪个会话」（detachLocal 不清它），会被后续开跑的流覆盖 → away 分支会在
        // runner 明明还在跑时莫名失效；②两条链路都要停，不用二选一（同时为真即同会话双轮询，
        // 用户点的这轮反而没停）。
        let awaySids = BackgroundStreamRunner.shared.runningSessionIds
        guard stream.isStreaming || !awaySids.isEmpty else { return }
        skipBurstOnce()
        selected = .chat
        NotificationCenter.default.post(name: LiveActivityActionBridge.clearPendingQueueNotification, object: nil)
        // v3.9.8 review 收口：ChatView 不在视图层级时（聊天 tab 从未打开 / 正在重建）上面这条通知会被丢弃，
        // 而排队消息是**持久化**的（下次进聊天页 restorePendingQueue 会恢复并自动发出）→ 这里补一次兜底清理，
        // 杜绝「点了停止，排队消息照样自己发出去」。
        UserDefaults.standard.removeObject(forKey: UserDefaultsKey.pendingQueue)
        if stream.isStreaming { stream.stop(auth: auth) }
        for sid in awaySids { BackgroundStreamRunner.shared.stop(sessionId: sid, auth: auth) }
    }
}

// MARK: - Tab 切换过渡动画（原地淡入，页底渐变常驻不动）
//
// v4.0.69（用户 2026-10-07：「dock 上各个 tap 的切换过渡很生硬，加入全局转场动画」）：
// 原来只有 `scaleEffect(0.985)` 这一档 —— 1.5% 的幅度真机上几乎看不出来，观感 ≈ 硬切。
// 曾用「4% 放大 + 从下方 10pt 浮起」。
// 仍然**不接管 tab 切换本身**（换页还是 TabView 原生），只做新页入场 —— 手势、tab bar 玻璃、
// 无障碍、系统返回全都不动。
// 相位（phase）而不是布尔 appeared 的原因（v4.0.69 审查）：`appeared = (newVal == tab)` 会让**离场**
// 那页也跟着播一遍「缩回 + 下沉」的反向动画（换页没有过渡叠加窗口 = 白算一帧），而且下次切回来时
// 起点态已经被消耗掉、没有入场可演。这里离场不动相位，只在「刚被选中」时把相位瞬归 0 再动画到 1。
// `seq` 防 0.01s 窗口内的连点 / 快速切换：早先那次的归零 Task 醒来会把新一次的起点态提前抹掉。
// v4.0.72（用户 2026-10-07 拍板「dock 恢复 4.0.69」）：撤掉 v4.0.70 的回弹曲线与整页淡入。
// v4.0.73（用户 2026-10-07 真机复测：4.0.72 垫底后顶部安全区仍先白一下）：缩放/上浮**整页**动 =
// 页面连页底一起动，顶部安全区那一条在动画期间露缝（垫底层与页底两层渐变叠加在缝边缘仍可辨）。
// 拍板方案 A：**页底渐变彻底退出动画、常驻不动**——垫底层本来就是静态渐变，页面淡入时
// 透出的是同款渐变，机制上不可能再露白。切页 = 内容原地淡入（Motion.snap 0.20s，用户选 A）。
private struct TabTransitionModifier: ViewModifier {
    let tab: DockTab
    @Binding var selected: DockTab
    /// 1 = 常态；0 = 全透明起点。赋值不加动画 → 起点态是瞬变的。
    /// 淡入的是**页面内容**；页面自身的页底渐变淡入时透出 ZStack 里那层静态垫底渐变（同款），肉眼无感。
    @State private var phase: CGFloat = 1
    @State private var seq = 0

    func body(content: Content) -> some View {
        content
            .tag(tab)
            .tabItem { Label(tab.title, systemImage: tab.icon) }
            .opacity(phase)                                      // v4.0.73：原地淡入（方案 A），不再缩放/位移
            .onAppear { enter() }
            .onChange(of: selected) { _, newVal in
                guard newVal == tab else { return }              // 离场不反向播（见头注）
                enter()
            }
    }

    /// 相位瞬归 0（不加动画）→ 下一拍 withAnimation 到 1。seq 防 0.01s 窗口内连点/快切互踩。
    private func enter() {
        seq &+= 1
        let mySeq = seq
        phase = 0
        Task {
            try? await Task.sleep(for: .seconds(0.01))
            guard mySeq == seq else { return }
            withAnimation(Motion.snap) { phase = 1 }
        }
    }
}

extension View {
    func chatZoomEntry(selected: Binding<DockTab>) -> some View {
        modifier(ChatZoomEntryModifier(selected: selected))
    }
}

extension View {
    func tabTransition(for tab: DockTab, selected: Binding<DockTab>) -> some View {
        modifier(TabTransitionModifier(tab: tab, selected: selected))
    }
}

// v4.0.72：聊天页入场 = 与其它四个 tab 同款的轻量入场。「从会话卡展开」已整体移除（勿再接回）；
// 用户 2026-10-07 真机拍板「转场太 low」→ 整体移除该机制。
// v4.0.73（方案 A 拍板）：与 TabTransitionModifier 同步改**原地淡入**——缩放/上浮整页动会掀开
// 顶部安全区那一条（4.0.72 真机复测仍先白一下）。两处口径一致，别只改一边。
// 相位/seq 手法与 TabTransitionModifier 完全同款。
private struct ChatZoomEntryModifier: ViewModifier {
    @Binding var selected: DockTab
    @State private var phase: CGFloat = 1
    @State private var seq = 0

    func body(content: Content) -> some View {
        content
            .opacity(phase)                                      // 与 TabTransitionModifier 同款：原地淡入
            .onAppear { enter() }
            .onChange(of: selected) { _, newVal in
                guard newVal == .chat else {
                    phase = 1   // 离场不反向播：起点态留给下次入场
                    seq &+= 1
                    return
                }
                enter()
            }
    }

    /// 相位瞬归 0（不加动画）→ 下一拍 withAnimation 到 1。seq 防 0.01s 窗口内连点/快切互踩。
    private func enter() {
        seq &+= 1
        let mySeq = seq
        phase = 0
        Task {
            try? await Task.sleep(for: .seconds(0.01))
            guard mySeq == seq else { return }
            withAnimation(Motion.snap) { phase = 1 }
        }
    }
}

// MARK: - v3.9.78 宠物长按 → 智慧球那套快捷菜单（独立 ViewModifier）
// v3.9.82：本类型**一并承担桌面图标长按快捷方式的接收**（见 onQuickAction / dispatchPendingQuickAction），
//          理由就是它在 body 上只占一个 `.modifier(…)` 调用 —— 新开一个修饰符正是护栏要拦的事。
//
// 为什么单独立一个类型：DockTabView.body 是一条极长的修饰符链，往上再挂带闭包的 .onChange/.onReceive
// 会让 Swift 类型检查器超时（CI run #571 实测：`unable to type-check this expression in reasonable time`
// → Archive 失败）。把闭包搬进这里的 body，等于给编译器一个新的、很小的检查单元。
private struct OrbMenuFromPetModifier: ViewModifier {
    @Binding var showOrbMenu: Bool
    @Binding var petAnchor: OrbPetAnchor?
    /// 识别浮层 / 语音页开着时为真 —— 与 dock 命中层同一互斥口径，此时不弹菜单
    let blocked: Bool
    /// v3.9.82：桌面图标长按快捷方式（传 OrbQuickAction.id）→ 调用方交给 handleOrbAction 分发。
    /// ⚠️ 名字里没有「快捷方式」是**故意不改名**：`ql ios check` 的源护栏（truth_table_orb.swift）
    /// 与反向自证（pet_guard_mutation.py ㊵）都以 `OrbMenuFromPetModifier` 这个类型名做锚点，
    /// 改名等于让三条护栏集体变红，而它们防的是同一件事（body 巨型链不许再挂泛型调用）。
    /// 传方法引用（dispatchQuickAction）而不是闭包字面量，也是为省那点类型推导负担。
    let onQuickAction: (Int) -> Void

    /// v3.9.82：取走待处理的桌面快捷方式动作并分发（取走即清空）；false = 当前没有待处理动作。
    /// ⚠️ 本类型**看不到** DockTabView 的私有成员（`private` 作用域 = 声明自身 + 同文件扩展，
    ///   跨类型不可见）—— 必须走上面注入的 `onQuickAction` 方法引用。首版直接在这里写
    ///   `dispatchPendingQuickAction()`（定义留在宿主里）→ check_swift.sh 第 1 步只做 `swiftc -parse`
    ///   （纯语法、不做名字解析）全绿，只有 CI Archive 报 `has no member`。
    @discardableResult
    private func dispatchPendingQuickAction() -> Bool {
        guard let id = HomeShortcutManager.consumePending() else { return false }
        onQuickAction(id)
        return true
    }

    /// 「从宠物锚点弹菜单」的**唯一**消费点（长按通知 / 快捷指令握手应答两条来路共用，见上面两个 onReceive）。
    private func openMenuAtPetAnchor(_ note: Notification) {
        guard !showOrbMenu, !blocked else { return }
        guard let anchor = OrbPetAnchor(userInfo: note.userInfo) else { return }
        petAnchor = anchor
        showOrbMenu = true
    }

    func body(content: Content) -> some View {
        content
            // 菜单收起时清锚点：否则下一次长按球的菜单会锚在上次的宠物位置；
            // 菜单**弹出**时顺手收键盘（用户 2026-09-25：「这个界面自动收回键盘」）。
            // 收在 showOrbMenu 这一处：长按球（OrbHitLayer）与长按宠物（.qingliaoOrbMenuFromPet）
            // 两条路都经过这个状态位 → 不会漏掉某一条。
            // 键盘「怎么收」在 ChatView 侧（清 FocusState + 60ms UIKit 兜底，与语音模式同口径），dock 这层只广播。
            // ⚠️ v3.9.79 审查后合并：原来另挂一个 `OrbMenuKeyboardDismissModifier`，等于 body 巨型链上
            //    又多一个泛型 .modifier 调用 —— 那正是 CI run #571「type-check 超时」的同类风险；
            //    这里本就有同一个 onChange(of: showOrbMenu)，合进来，链上保持只有 1 个修饰符。
            .onChange(of: showOrbMenu) { _, shown in
                if !shown {
                    petAnchor = nil
                } else {
                    NotificationCenter.default.post(name: .qingliaoDismissKeyboard, object: nil)
                }
            }
            // 聊天页宠物长按 ＝ 长按智慧球**同一套**菜单（用户：「长按宠物改成和长按智慧球一样的效果」）。
            // 只换锚点，动作分发仍走 handleOrbAction（单一真源，不在聊天页复制第二套）。
            // v4.0.x：第二条 `.qingliaoOpenOrbMenuAtPet` 是**同一件事**的第二条来路 ——
            // 「打开轻聊快捷菜单」快捷指令从 App 外面进来，需要宠物锚点，走「dock 请求 → 宠物应答」握手
            // （应答方在 ChatView，见 OrbPetAnchorRegistry）。两条合流到下面这一个消费点，
            // 别给应答那条再写第二份 showOrbMenu 逻辑（那才是真的复制第二套）。
            .onReceive(NotificationCenter.default.publisher(for: .qingliaoOrbMenuFromPet)) { (note: Notification) in
                openMenuAtPetAnchor(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .qingliaoOpenOrbMenuAtPet)) { (note: Notification) in
                openMenuAtPetAnchor(note)
            }
            // v3.9.79：菜单**开着**时宠物真实中心变了 → 只更新锚点，不重开菜单（见 Notification.Name 处的事故说明：
            // 收键盘让宠物下移 ≥56pt，锚点不跟着走就会「两只宠物」）。菜单关着时这条通知直接丢弃。
            .onReceive(NotificationCenter.default.publisher(for: .qingliaoPetAnchorMoved)) { (note: Notification) in
                guard showOrbMenu, !blocked else { return }
                guard let anchor = OrbPetAnchor(userInfo: note.userInfo) else { return }
                petAnchor = anchor
            }
            // v3.9.82：桌面图标长按快捷方式 —— 两路（与 v3.9.7 灵动岛按钮同款）：
            //   ① 进程在跑：通知直达（观察者已注册）
            //   ② App 刚被图标长按拉起：performActionFor 早于本视图挂树、通知会丢 → 启动后取一次待处理动作
            // ⚠️ 动作分发不在这一层做：只把 id 交给 DockTabView.dispatchQuickAction → handleOrbAction（单一真源）。
            .onReceive(NotificationCenter.default.publisher(for: .qingliaoQuickAction)) { _ in
                dispatchPendingQuickAction()
            }
            .task {
                // 补一次；仍为空则 0.8s 再补（覆盖「通知发出时观察者刚注册、body 还没跑完」的窄窗口）
                if !dispatchPendingQuickAction() {
                    try? await Task.sleep(for: .seconds(0.8))
                    _ = dispatchPendingQuickAction()
                }
            }
    }
}

/// v4.0.x：快捷指令 / Siri「打开轻聊某页」的投递落地（`.modifier(IntentRouteModifier(onRoute:))`）。
///
/// 两条腿缺一条就是「点快捷指令没反应」：
///   · 广播 —— App 已经在跑：进程内通知直达
///   · 兜底 —— App 是被这条 intent 拉起来的：观察者注册前广播会丢，起来时补读一次落盘值
/// ⚠️ 广播这条**必须顺手清兜底 flag**（幂等）：不清的话同一条路由会被应用两次 —— App 在 60s 内
///    重建再 appear，人会被从当前页莫名拽回那一页（与灵动岛那条 `LiveActivityActionBridge.consume()`
///    同一姿势）。
/// ⚠️ 本类型**看不到** `DockTabView` 的私有成员（跨类型不可见）—— 切页逻辑由宿主注入 `onRoute`
///    （传方法引用 `applyRoute` 而不是闭包字面量，也是为省那点类型推导负担）。
private struct IntentRouteModifier: ViewModifier {
    /// 由宿主注入 —— `DockTabView.applyRoute(_:)`（`qingliao://` 深链 / 广播 / 冷启动三条来源共用）
    let onRoute: (QingliaoDeepLink.Route) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: QingliaoRouteHandoff.notification)) { note in
                guard let raw = note.object as? String else { return }
                _ = QingliaoRouteHandoff.consume()   // 清兜底（幂等，理由见上）
                guard let route = QingliaoRouteHandoff.route(named: raw) else { return }
                onRoute(route)
            }
            .task {
                guard let route = QingliaoRouteHandoff.consume() else { return }
                onRoute(route)
            }
    }
}

// MARK: - v3.9.78：长按快捷菜单浮层（独立计算属性）
//
// 同样是为了不把 body 那条修饰符链撑到类型检查超时（CI run #571 实测）——浮层本身是 8 个参数 + 两个闭包，
// 留在 body 里等于又一层嵌套表达式。参数与语义一字未改，只是搬了个地方。
private extension DockTabView {
    @ViewBuilder
    var orbMenuOverlay: some View {
        OrbQuickMenuOverlay(barHeight: dockBarHeight,
                            slotIndex: 2,
                            slotCount: dockSlotCount,
                            // v3.9.78：锚点球与 dock 那颗同状态（菜单开着时球仍在原位可见）
                            thinking: stream.isStreaming,
                            unseen: orbUnseen,
                            failed: orbFailed,
                            petAnchor: orbMenuPetAnchor,
                            onAction: { handleOrbAction($0) },
                            onClose: { showOrbMenu = false })
            .transition(.opacity)
            .zIndex(40)
    }
}

// v4.0.72 回退时从 v4.0.69 原样搬回：启动链折叠（防 demangler 栈溢出，勿内联回 body）。
extension DockTabView {
    /// 折叠第 1 组（6 条）：tab bar 行为 + 全局信号（切页 / 流收尾 / 流开跑）+ 智能球与长按菜单两个浮层。
    @MainActor
    private func applyDockTabChrome1<C: View>(to content: C) -> some View {
        content
            // v3.4.30：装机实测后按用户要求关闭自动收缩——tab bar 常驻不缩，滚动时不再变窄
            // （v3.4.29 曾设为 .onScrollDown：向下滚动缩到角落只剩图标，用户不需要）
            .tabBarMinimizeBehavior(.never)
            // v3.9.47 方案 B（UIKit 侧改 UITabBar 外观）真机实测同样无效，已整块回退——
            // 这里**不要再挂任何东西**，理由见下方 chatTab 的注释与 README「iOS 26 系统玻璃的三条口径」。
            // v3.4.29：切 tab 触感——挂在一处（TabView），别挂进每个 tab 的 modifier（会响 4 次）
            .onChange(of: selected) { _, newVal in
                Haptics.tap()
                // v3.9.59：切页即收起长按菜单——手动切 tab 与程序化切页（深链 / 分享 / 备忘录「发给 AI」/
                // 灵动岛）都走这里；不收的话菜单会浮在新页面上（此时命中层已被 if !showOrbMenu 摘掉）。
                if showOrbMenu { showOrbMenu = false }
                // v3.9.76：识别浮层与语音对话页同样要跟着收——深链 / 分享 / 通知切页时
                // 留着它们会浮在新页面上（此时球命中层已被条件摘掉，收不起来就成死层）
                if showIdentify { showIdentify = false; identifyPhoto = nil }
                if showVoiceDialog { showVoiceDialog = false }
                // v3.9.33：切到聊天页 = 回复已在眼前 → 清掉球上的「未查看 / 失败」提示
                if newVal == .chat { clearOrbNotice() }
                // v3.6.2：点 dock 智能球（= 切到聊天页）→ 放烟花，保留原智能球的点击特效
                if orbInDock, newVal == .chat {
                    if skipNextBurst { skipNextBurst = false } else { fireDockBurst() }
                }
            }
            // v3.9.33：球第三态 + 错误态——AI 收尾时用户不在这页 =「刚答完未查看」；真失败则压暗。
            // 用户主动停止/取消不算失败（StreamClient.lastFailed 统一判定，见 finish(userInitiated:)）；
            // 在聊天页里收尾不置位：错误气泡/回复本身就在眼前，置位会让球一直暗着。
            // ⚠️ 收尾判定用 `finishSeq`（只增不减）观察，**不能观察 `isStreaming` 的变化**：
            // finish() 里 isStreaming=false 后同步回调 onFinished，排队续发（sendQueued → start()）会在
            // 同一帧把它设回 true → onChange 看到 old/new 都是 true，整轮收尾被静默跳过（失败不压暗、
            // 「未查看」也不亮）。序号只增，收尾一定被观察到一次。
            .onChange(of: stream.finishSeq) { _, _ in
                // v4.0.x（审查指出的顺序依赖，必修）：`finishSeq` 与 `startSeq` 可能落在**同一次视图更新**里
                // （开跑即失败、或失败后同帧排队续发），两个闭包都会跑，最终 `orbFailed` 就取决于派发顺序。
                // 判据改成看 `isStreaming` 的**最终值**，与顺序无关：
                //   同帧已续发（isStreaming 已回到 true）→ 本轮在跑，别为上一轮压暗；
                //   同帧开跑即失败（isStreaming 停在 false）→ 照常压暗。
                if stream.lastFinishFailed, !stream.isStreaming {
                    orbFailed = !chatVisible
                    orbUnseen = false
                } else if stream.lastFinishFailed {
                    orbFailed = false
                } else {
                    orbUnseen = !chatVisible
                    orbFailed = false
                }
            }
            // 新流开跑 = 上一轮的失败提示收掉（否则球会一直暗着）；「未查看」保留（排队消息自动续发不该吞掉它）
            // v4.0.x：这里原来观察 `isStreaming`，撞的正是上面注释写的那个缝——上一轮失败后的
            // **排队自动续发**（finish 同帧 start）把 false→true 吞掉，onChange 看到 old/new 都是 true，
            // 失败态清不掉 → 球在整轮新回答期间一直压暗。改成只增的 `startSeq`，每次开跑必被观察到一次。
            .onChange(of: stream.startSeq) { _, _ in
                orbFailed = false
            }
            // v3.6.2：dock 聊天槽位智能球——系统 tab item 只能放系统图标（iOS 26 无自定义视图 API），
            // 故该槽位 item 置为空（无图标无文字），球由本叠加层自绘并居中于槽位；
            // allowsHitTesting(false) 让触摸穿透给下层系统 tab item（点球 = 系统切页）。
            .overlay {
                if orbInDock {
                    // 聊天槽位序号 = 2（会话0 / 生活1 / 聊天2 / 看板3 / 设置4）
                    // thinking: AI 流式回答中球切 orbits 旋转——原聊天页智能球的行为在 dock 槽位保留
                    DockOrbOverlay(slotIndex: 2,
                                   slotCount: dockSlotCount,
                                   thinking: stream.isStreaming,
                                   unseen: orbUnseen,
                                   failed: orbFailed,
                                   measuredBarHeight: $dockBarHeight)
                        .allowsHitTesting(false)
                    // v3.9.59：球命中层——只盖住球体一小块（68pt 圆）：
                    //   轻点 = 手动切聊天页（onChange 的触感/清提示/烟花照旧走一遍），
                    //   长按 = 弹快捷菜单。菜单开着时本层不显示（菜单层自己接管全部交互）。
                    if !showOrbMenu && !showIdentify && !showVoiceDialog {
                        OrbHitLayer(barHeight: dockBarHeight,
                                    slotIndex: 2,
                                    slotCount: dockSlotCount,
                                    // v3.9.59：轻点复用「点系统 tab item」的语义——已在聊天页时 selected 不变、
                                    // onChange 不触发，触感与清提示会整体丢失（原先这层是系统 tab item 的按压反馈）。
                                    // 🚨 v4.0.54（用户 2026-10-05）：**回退 v4.0.47 的「轻点 = 回聊天首页（新建会话）」** ——
                                    //   用户实报「每次点击智慧球就打开新会话」，正在看的会话被顶掉 → 要回退到原口径：
                                    //   轻点只切到聊天页、**保留当前会话**；已在聊天页时只补触感 + 清提示。
                                    //   新建会话仍留在长按菜单 case 0（`chat.requestNewSession()`，两步走清屏），
                                    //   以及「会话 tab 的 + 号」，本层不再自己新建。
                                    onTap: {
                                        // 触感分工：切页那一支的 Haptics.tap() 由 onChange(of: selected)
                                        // 统一给（同现状），别在这里再响一次
                                        if selected == .chat { Haptics.tap(); clearOrbNotice() }
                                        else { selected = .chat }
                                    },
                                    onLongPress: {
                                        Haptics.press()
                                        showOrbMenu = true
                                    })
                    }
                }
            }
            // v3.9.59：长按球快捷菜单浮层（最顶层，模态——轻纱吃掉空白点击收起）
            .overlay {
                if showOrbMenu { orbMenuOverlay }
            }
    }

    /// 折叠第 2 组（6 条）：菜单/识别浮层的动画 + 宠物菜单修饰符 + 识别浮层 + 语音对话/会话纪要两个全屏页。
    @MainActor
    private func applyDockTabChrome2<C: View>(to content: C) -> some View {
        content
            .animation(Motion.snap, value: showOrbMenu)
            // v3.9.78：宠物长按 → 同一套菜单（含收起时清锚点）。
            // 🚨 这段**必须**是独立 ViewModifier，不能在 body 的巨型表达式上直接再挂两个带闭包的修饰符：
            //    实测（CI run #571）整条链当场 "the compiler is unable to type-check this expression
            //    in reasonable time"，Archive 阶段直接失败。抽出去后 body 上只剩一个 .modifier(…) 泛型调用。
            .modifier(OrbMenuFromPetModifier(showOrbMenu: $showOrbMenu,
                                             petAnchor: $orbMenuPetAnchor,
                                             blocked: showIdentify || showVoiceDialog,
                                             onQuickAction: dispatchQuickAction))
            // v3.9.79：菜单弹出即收键盘（用户 2026-09-25：「这个界面自动收回键盘」）——
            // 广播点合在 OrbMenuFromPetModifier 里的 onChange(of: showOrbMenu)（长按球 + 长按宠物两条路都覆盖），
            // **刻意不在链上再挂第二个 .modifier**：body 巨型链多一个泛型调用就是 CI run #571 那类超时风险。
            // v3.9.76：智慧球「AI 识别」浮层（球上悬浮卡 + 扫描环 + 背景虚化）。
            // 与长按菜单互斥（菜单先收起才进这里）。「问 AI」复用既有 .qingliaoTaskSend 通道
            // —— 与任务中心、备忘录「发给 AI」完全同一条路，不新造通道。
            .overlay {
                if showIdentify {
                    OrbIdentifyOverlay(barHeight: dockBarHeight,
                                       slotIndex: 2,
                                       slotCount: dockSlotCount,
                                       onAskAI: { askAI($0) },
                                       // v3.9.82：译文交回宿主弹 TranslateSheet（形态照 AI 速记弹窗）。
                                       // 同帧收浮层 + present：浮层是 overlay（不是 presentation），
                                       // 两者不互斥；真机若被吞再按仓里规则加 0.35s 闸。
                                       onTranslated: { source, text in
                                           showIdentify = false
                                           identifyStartTranslate = false
                                           identifyPhoto = nil          // 关浮层必须连载荷一起清
                                           translateResult = TranslateResult(source: source, text: text)
                                       },
                                       startInTranslateMode: identifyStartTranslate,
                                       // v4.0.x：宿主拍完的那张照片（「拍照识别」就地看图）。
                                       // 非 nil 时浮层起手就对着它问 AI；nil = 原「AI 识别」流程不受影响。
                                       photoAskImage: identifyPhoto,
                                       onClose: {
                                           showIdentify = false
                                           identifyStartTranslate = false
                                           identifyPhoto = nil          // 关浮层必须连载荷一起清（漏 = 下次误用老照片）
                                       })
                        .transition(.opacity)
                        .zIndex(45)
                }
            }
            .animation(Motion.snap, value: showIdentify)
            // v3.9.76：语音对话全屏页（长按智慧球「语音对话」胶囊）。
            // 全屏而非 sheet：这一页要盖住 dock 与 tab bar 做沉浸式收音，sheet 会留出下层。
            .fullScreenCover(isPresented: $showVoiceDialog) {
                VoiceDialogView()
            }
            // v4.0.x：长按菜单「会话纪要」全屏页（新胶囊 id 6）。
            // 全屏而非 sheet：纪要正文要占满整屏读，页内自带 dismiss（与语音对话页同一口径）。
            .fullScreenCover(isPresented: $showMinutes) {
                MeetingMinutesView()
            }
    }

    /// 折叠第 3 组（6 条）：拍照识别全屏页 + 两张弹窗（速记/译文）+ 烟花浮层 + 深链兜底 task。
    @MainActor
    private func applyDockTabChrome3<C: View>(to content: C) -> some View {
        content
            // v4.0.x：长按菜单「拍照识别」系统相机（新胶囊 id 7）。
            // 内容视图必须 .ignoresSafeArea() —— 同 ql_entry 第 17 步的口径：只换 fullScreenCover
            // 容器不够，内容默认仍受安全区约束 → 顶部露宿主黑边（v3.9.75 用户实测报过）。
            // 内容抽成 cameraCover（不在 body 巨型链上写字面量闭包）：CI run #571 的 type-check 超时坑。
            .fullScreenCover(isPresented: $showCamera) {
                cameraCover
            }
            // v3.9.59：速记弹窗（AI 速记 / 今日待办共用一个输入弹窗）
            // v3.9.59：onDismiss 复位——若某次 present 被别的 sheet 挡掉，quickCapture 会一直非 nil，
            // 之后「AI 速记 / 今日待办」再也弹不出来（MemoSection v3.9.17 / TodoSection 同款坑，本仓踩过）。
            .sheet(item: $quickCapture, onDismiss: { quickCapture = nil }) { mode in
                QuickCaptureSheet(mode: mode)
            }
            // v3.9.82：译文弹窗（形态照上一张速记弹窗抄）。
            // ⚠️ 同一宿主上链式并存两个 .sheet —— 仓里的坑是「两个同时为真只有一个生效」；
            //    这两张**互斥**：速记从长按菜单进、译文从识别浮层进，任一条路都先收掉另一条。
            //    真机若出现「译文弹不出来」，按仓里规则给 present 加 0.35s 闸（先收浮层再弹）。
            .sheet(item: $translateResult, onDismiss: { translateResult = nil }) { r in
                TranslateSheet(result: r,
                               onAskAI: { askAI($0) },
                               onRetry: {
                                   // 换一张：重开识别浮层并以翻译模式起手（相册一颗按钮的事，不再自动弹相册）
                                   // ⚠️ 必须清载荷：浮层重建会跑 onAppear，`identifyPhoto` 非 nil 就被当成
                                   //   「拍照识别」去问上一张老照片（载荷成对设/清，别只设不清）。
                                   identifyPhoto = nil
                                   identifyStartTranslate = true
                                   showIdentify = true
                               })
            }
            // v3.0.60 回顾：系统 tab bar 自行处理滚动边缘玻璃；此处不再加纯色背景掐死折射
            // v3.4.26：切页暂停/恢复看板轮询已改参数直传（DashboardView(isActive:)），通知已移除
            // v3.4.24：任务中心悬浮入口已移除——迁入聊天页 header（三个点旁常驻小图标），
            // 见 ChatView.headerTrailingItems。此处不再挂全局 overlay（避免遮挡各页右上角按钮）。
            // v3.6.2：全屏粒子爆发（点 dock 智能球触发；纯视觉，不挡交互）
            .overlay {
                if showDockBurst {
                    FullScreenBurst(originFromBottom: DockOrbOverlay.ballCenterFromBottom(barHeight: dockBarHeight,
                                                                                        index: 2, count: dockSlotCount))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(30)
                }
            }
            .animation(Motion.tap, value: showDockBurst)
            .task {
                guard let sid = UserDefaults.standard.string(forKey: "qingliao_open_session") else { return }
                UserDefaults.standard.removeObject(forKey: "qingliao_open_session")
                // v3.9.39 A7：深链此前**从未生效过**。这里用 `jsonArray` 解 /api/sessions/list，
                // 而该接口返回的是对象 {ok, sessions, total}——`as? [Any]` 对字典恒 nil ⇒ 必抛
                // badJSON，又被外层 `try?` 吞成 nil ⇒ 整条 if 静默跳过：点通知、灵动岛长按选会话
                // 全部停在空白新会话。改成与同仓 ChatStore.loadLastSession / SessionsView.load
                // 同一口径（json + ["sessions"]）；失败也不再无痕迹，留一行日志说明是哪个会话。
                guard let j = try? await auth.json("/api/sessions/list"),
                      let raw = j["sessions"] as? [Any] else {
                    print("[deepLink] 会话列表拉取失败，无法打开会话 \(sid)")
                    return
                }
                let sessions = raw.compactMap { ChatSession.parse($0 as? [String: Any] ?? [:]) }
                guard let s = sessions.first(where: { $0.id == sid }) else {
                    print("[deepLink] 会话 \(sid) 不在服务器列表（可能已删除）")
                    return
                }
                chat.load(s)
                chat.markRead(s.id, upTo: s.lastTime)   // v4.0.15：同 SessionsView.open 口径（带基线）；v3.9.39：深链也算「打开会话」，否则红点永久挂着
                skipBurstOnce()
                selected = .chat
            }
    }

    /// 折叠第 4 组（6 条）：系统分享 onOpenURL + 备忘/分享两条 onReceive + 快捷指令路由 + 灵动岛停止 + 兜底 task。
    @MainActor
    private func applyDockTabChrome4<C: View>(to content: C) -> some View {
        content
            // v3.4.14 系统分享接入口：捕获从其他 App 分享进来的内容 → 入 ShareRouter + 通知 ChatView
            .onOpenURL { url in
                // 🚨 v4.0.x 加固：分享接收协议（`qingliao://share?...`）原来只挂在 QingliaoApp
                // （WindowGroup 的 content 上，离根最近）。但**已登录时本视图在树里、离根更近**，
                // 而 share host 对 QingliaoDeepLink.route / file / http / geo 分支全不命中 →
                // 落到 `String(contentsOf:)`（非文件 URL 必失败）→ guard return → 分享内容静默丢弃。
                // 「用户已登录时分享不进来、未登录时正常」正是这个布局的必然结果。
                // SwiftUI 对多个 onOpenURL 是「只调最深那一个」还是「逐个广播」各家说法不一，
                // 所以这里**两个位置都接、且 share 优先**（ShareIntake 只认 qingliao://share，
                // 不是自己的 URL 立刻 return false，对既有深链/分享零影响）——两种语义下都活。
                if ShareIntake.handle(url: url, loggedIn: auth.isLoggedIn, loggedInProvider: { auth.isLoggedIn }) { return }
                handleShareURL(url)
            }
            // v3.9.14：备忘录「发给 AI」——备忘录在生活页，不切回聊天页就看不到发出去的消息
            .onReceive(NotificationCenter.default.publisher(for: .qingliaoMemoSend)) { _ in
                // 程序化切页必须先跳过一次烟花（与深链/分享/灵动岛同款）——
                // 否则点「发给 AI」会误放全屏粒子（v3.6.2 修过的回归）
                skipBurstOnce()
                selected = .chat
            }
            // v4.0.1：分享接收（`ShareIntake`）投递前先请宿主切到聊天页 —— 与备忘录「发给 AI」同款。
            // 它拿不到 `selected`（Core 层），而载荷两条落点全挂在「ChatView 在视图树里」，
            // 用户从别的 App 分享过来时人可能停在生活页/看板页 → 不切页就是消息静默消失。
            .onReceive(NotificationCenter.default.publisher(for: .qingliaoOpenChat)) { _ in
                // 已在聊天页就别跳过烟花（与 case 0/2/4 同一条理由：白置标志会吞掉紧接着的真点击烟花）
                if selected != .chat { skipBurstOnce() }
                selected = .chat
            }
            // v4.0.x：快捷指令 / Siri 的「打开轻聊…」动作（intent 走前台模式 + 进程内投递到这一层）。
            // 🚨 这段**必须**是独立 ViewModifier，不能在 body 巨型链上直接挂两个带闭包的修饰符：
            //    与上面 `OrbMenuFromPetModifier` 同一条红线（CI run #571 那类 Archive 类型检查超时）。
            .modifier(IntentRouteModifier(onRoute: applyRoute))
            // v3.9.7：灵动岛「停止生成」按钮——`LiveActivityIntent` 在**主 App 进程**执行，
            // 所以进程内通知能直达这里（挂件进程触不到 App 的流）
            .onReceive(NotificationCenter.default.publisher(for: LiveActivityActionBridge.notification)) { note in
                guard (note.userInfo?["action"] as? String) == LiveActivityAction.stopGeneration else { return }
                handleLiveActivityStop()
            }
            // 兜底：App 进程是刚被按钮拉起的（观察者还没注册、通知会丢）→ 启动时读一次待处理动作
            .task {
                guard LiveActivityActionBridge.consume() == LiveActivityAction.stopGeneration else { return }
                handleLiveActivityStop()
            }
    }

    @MainActor
    private struct DockTabChrome1: ViewModifier {
        let host: DockTabView

        func body(content: Content) -> some View { host.applyDockTabChrome1(to: content) }
    }

    @MainActor
    private struct DockTabChrome2: ViewModifier {
        let host: DockTabView

        func body(content: Content) -> some View { host.applyDockTabChrome2(to: content) }
    }

    @MainActor
    private struct DockTabChrome3: ViewModifier {
        let host: DockTabView

        func body(content: Content) -> some View { host.applyDockTabChrome3(to: content) }
    }

    @MainActor
    private struct DockTabChrome4: ViewModifier {
        let host: DockTabView

        func body(content: Content) -> some View { host.applyDockTabChrome4(to: content) }
    }
}
