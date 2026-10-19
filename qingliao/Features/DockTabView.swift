import SwiftUI
import CoreLocation
import UIKit

enum DockTab: String, CaseIterable, Identifiable {
    // v4.0.82（用户 2026-10-09：「设置里面增加 dock 栏设置，聊天、生活、看板、设置页可以调整顺序，
    // 可以隐藏某一页，唯独设置页不能隐藏」）：dock 顺序与显隐改为**用户可配** ——
    // 真源 = `Core/DockLayoutKit.swift`（纯逻辑）+ UserDefaults 两个串（UserDefaultsKey.dockOrder / dockHidden）。
    //   · 顺序：4 档任意排列（出厂序 chat,life,dashboard,settings）；
    //   · 隐藏：除设置页外都可隐藏（`DockLayoutKit.canHide`，唯一闸门）；
    //   · 本文件**不再写死档序**：渲染走 `dockRenderTabs`（= DockLayoutKit.visible 的结论）。
    // ⚠️ 历史：v4.0.70 做过一版「Dock 顺序自定义」，那是 **5 槽时代**（智慧球恒居中、几何按 slotIndex: 2 硬编码），
    //    整批随 v4.0.72 回退；v4.0.81 起球已移出 dock（只由长按宠物调用）→ 已无「球必须居中」的约束，
    //    当初那套「球不许离开 index 2」的限制**不要照搬**（v4.0.82 起 4 档可真正任意排）。
    // v4.0.x：dock 图标换 B 组（用户选定）：看板 chart.pie / 生活 heart / 设置 gearshape（空心）；
    // 会话 clock 保留。语义直白风，每个图标一眼看出页面用途；智慧球槽位（chat）不受影响。
    // v4.0.108（用户 2026-10-14「在 dock 加一个 tab 叫工作区」）：新增 `workspace` 档
    // —— 第 5 档（出厂序里排第 3：chat,life,workspace,dashboard,settings，见 DockLayoutKit.allRaw）。
    // 图标选定 = 公文包 `briefcase`（用户从 4 组候选里拍的第 1 组，语义直白：AI 替我干的活）。
    case sessions, life, chat, workspace, dashboard, settings

    // ⚠️ v4.0.82：原来的 `slotIndex`（写死 0..3）已删除 —— 顺序与显隐可配后槽位不再是常量，
    //    槽位序号唯一真源 = `DockLayoutKit.slotIndex(of:in:)`（视图侧由 `dockRenderTabs` 派生）。

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: "会话"
        case .dashboard: "看板"
        case .chat: "聊天"
        case .life: "生活"
        case .workspace: "工作台"   // v4.0.x 用户改名（原「工作区」，icon briefcase 不变）
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .sessions: "clock"
        case .dashboard: "chart.pie"
        case .chat: "message.fill"
        case .life: "heart"
        case .workspace: "briefcase"
        case .settings: "gearshape"
        }
    }

}

struct DockTabView: View {
    @State private var selected: DockTab = .chat

    // v4.0.120：`revealCenter`（切页圆形扩散圆心）随底栏换页改**定向滑入**一并退役 —— 新形态不需要圆心。
    // v3.6.2：dock 智能球点击 → 全屏粒子爆发（原由聊天页智能球展开触发，球迁到 dock 后跟随迁移）
    @State private var showDockBurst = false
    /// v4.0.7：烟花粒子特效开关（设置 → 外观 → 交互；与「输入框流光」同一排）。默认开，关掉后点球不放烟花。
    @AppStorage("qingliao_dock_burst") private var dockBurstOn = true
    /// v3.6.2：分享/深链等「程序化切到聊天页」跳过烟花（烟花的语义是「点了 dock 智能球」）
    @State private var skipNextBurst = false
    /// v4.0.81：聊天 tab 内「会话首页 ↔ 对话页」双态。
    /// true = 首页（机器人 + 一言 + ≤8 卡片 + 会话列表，即原会话页那套），false = 对话页。
    @State private var showSessionHome = true
    /// v4.0.116（用户 2026-10-13「聊天页滑动返回聊天主页采用圆形扩散转场特效：新页面就从手指滑动位置
    /// 向外扩散直到铺满整个屏幕」）：返回聊天首页时**圆形扩散**的圆心（window 坐标）。
    /// 🚨 v4.0.122：左缘手势改**跟手位移**后，写它的**只剩页头返回按钮**（无手指可依 → 兜底屏幕中心）；
    /// 跟手那条压根不写 → 保持 nil，首页的 modifier 直接不播扩散（它就是「被滑开露出来」的那一下）。
    /// **取走即清空**：首页侧的 modifier 在自己 `onAppear` 里消费一次并置回 nil ——
    /// 于是只有「点页头返回按钮」这一条路径播扩散；冷启动 / 切 tab / 深链落首页时它是 nil，
    /// 保持不播（那条路的外层 `chatZoomEntry` 已经在播定向滑入，两层叠着播会互相切）。
    @State private var homeRevealCenter: CGPoint? = nil
    // MARK: - v4.0.122 左缘右滑**跟手**返回（用户 2026-10-18 对着参考截图拍板「要这种跟手滑动返回」）
    //
    // 口径：手指在左缘往右拖 → 对话页**贴着手指**整页右移、会话首页从左侧同步露出来（微信同款）；
    //   松手：位移过半（或甩动预测终点过半）→ 收敛到返回，否则回弹归位。
    // 为什么是两个状态位（而不是只用一个 offset）：跟手要的就是「两页同框」那一帧 ——
    //   `backFollowLive` 管首页作为**垫底页**在不在场，`backFollowOffset` 管对话页被推走多远。
    /// 对话页的跟手横移（pt）。0 = 常态；>0 = 跟手/收敛中。
    /// ⚠️ 跟手帧必须**裸赋值**（不许进动画事务），只有收敛 / 回弹才走 `Motion.page`。
    @State private var backFollowOffset: CGFloat = 0
    /// 跟手/收敛期间首页要作为**垫底页**在场（滑开对话页露出来的就是它）。
    /// 与 `showSessionHome` 分开：回弹收敛跑完之前不能卸，否则位移中途底下会空一下（露渐变垫底）。
    @State private var backFollowLive = false
    /// 收敛代次（与 `chatZoomEntry` 同款 seq 手法）：0.34s 窗口内再起手势 / 连甩不许互踩收尾。
    @State private var backFollowSeq = 0
    /// v4.0.82：dock 顺序串（4 档 rawValue 的排列）—— 设置 → 通用 →「Dock 栏」写，这里读。
    /// 坏值净化在 DockLayoutKit.sanitizedOrder（渲染期只读结论，不在这里做校验）。
    @AppStorage(UserDefaultsKey.dockOrder) private var dockOrderRaw = DockLayoutKit.defaultOrderRaw
    /// v4.0.82：被隐藏的档（rawValue 逗号串）。设置页**永远不在其中**（DockLayoutKit.canHide 是唯一闸门）。
    @AppStorage(UserDefaultsKey.dockHidden) private var dockHiddenRaw = ""
    /// v4.0.82：被隐藏的档被深链/首页卡片点到时**临时插回**渲染（不写回配置）——
    /// 「隐藏」只是不在 dock 上常驻，不丢功能；用户切到任一常驻档即自动清空（见 DockTabChrome1）。
    @State private var forcedTabs: Set<DockTab> = []
    /// dock bar 高度（菜单/识别浮层定位用）。v4.0.81 起球没了 → 不再有实测回写，
    /// 始终走 DockOrbOverlay.fallbackBarHeight 这个常量（菜单锚点精度由它兜底）。
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

    // MARK: - v4.0.125 转场优先（用户 2026-10-19：tab 切换仍掉帧 / 返回首页仍掉帧）
    //
    // 根因（代码取证）：各页的 `.task(id: isActive)` 在**被切到的那一刻**就 `await load()` + 起轮询，
    // 而这一刻正好是切页/返回动画的头几帧 —— 网络回调的 JSON 解码 + 列表 diff + 卡片重建全部挤在
    // 同一个主线程帧预算里，转场自然掉帧。`isActive` 直传 `selected` 等于「动画与数据刷新同步开跑」。
    //
    // 治法：把「页面成为活跃」拆成两层 —— `selected` 管**渲染**（立即，保证转场有内容），
    // `settledTab` 管**数据**（转场落定后才等于 selected）。延迟取 340ms：切页位移 Motion.pageEnterSlide
    // 是 0.28s，留 60ms 余量；返回扩散虽 1.1s，但列表在 0.34s 后刷已经不砸动画头几帧了。
    // 🚨 别把 isActive 改回 selected —— 那就是把动画和网络重新绑回同一帧。
    @State private var settledTab: DockTab?
    /// 返回首页专用：`showSessionHome` 一翻真 → 先置 false（SessionsView 当 backdrop 不刷），
    /// 340ms 后置真才允许 `load()`（否则列表 diff 正好砸在圆扩散的前半段）。
    @State private var homeSettled = true

    // v4.0.81：槽位的智能球连同 `orbInDock` 判据整块移除（用户口径 Q1=3：球的入口只留长按宠物）。
    // 菜单/识别/录音三个浮层的**兜底锚点**仍按 dock 槽位几何算，故保留槽位数与聊天槽位序号。
    // MARK: - v4.0.82 dock 档位（数据驱动：顺序 / 隐藏都可配）

    /// 实际渲染的档位 = 顺序 − 隐藏（+ 临时插回的），顺序即渲染序。
    /// ⚠️ TabView 与所有槽位几何都读它 —— **不许**再出现写死的档数/档序（v4.0.70 那版翻车就是硬编码几何）。
    private var dockRenderTabs: [DockTab] {
        DockLayoutKit.visible(order: DockLayoutKit.sanitizedOrder(dockOrderRaw),
                              hidden: DockLayoutKit.sanitizedHidden(dockHiddenRaw),
                              forcing: forcedTabs.map(\.rawValue))
            .compactMap { DockTab(rawValue: $0) }
    }

    /// v4.0.82：渲染档位的组合串（顺序 + 显隐的指纹）—— 供 TabView 的 `.id` 与「配置变更后兜底切页」共用
    private var dockRenderKey: String { dockRenderTabs.map(\.rawValue).joined(separator: ",") }

    /// dock 槽位数 = 实际渲染的档数（隐藏/换序后自动收窄；不再是常量 4）
    private var dockSlotCount: Int { dockRenderTabs.count }
    /// 聊天槽位序号（浮层锚点 / 烟花原点按它算）。聊天页被隐藏时退 0（锚到第一格，不会锚到屏外）。
    private var chatSlotIndex: Int {
        DockLayoutKit.slotIndex(of: DockTab.chat.rawValue, in: dockRenderTabs.map(\.rawValue))
    }
    /// v3.9.33：这页的回复是否正摆在用户眼前 = 聊天 tab **且**当前会话就是刚收尾的那条流。
    /// 只看 `selected == .chat` 会漏报——人在聊天页看会话 B 时，会话 A 的回复落地也该提示。
    private var chatVisible: Bool {
        selected == .chat && auth.currentStreamSessionId == chat.sessionId
    }

    /// v4.0.117：首页各块次第上浮的放行开关（由 `QingliaoApp.RootView` 在**启动页圆形遮罩铺满后**置 true）。
    /// 默认 true = 「已就位」——非启动路径（热启动、iPad 双栏、预览）直接显示，本开关等于不存在。
    /// 两处消费者：① 透传给 `SessionsView.launchRise` ② 决定冷启动首帧要不要跳过 chatZoomEntry 的整页扩散。
    var launchRise: Bool = true

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
                // v4.0.82：dock 档位改为**数据驱动**（顺序可调 + 可隐藏；设置 → 通用 →「Dock 栏」）。
                // 原来静态四块（聊天/生活/看板/设置）一字未改地搬进了 `dockPage(_:)`，只是改成按
                // `dockRenderTabs` 渲染 —— 档序与显隐由 DockLayoutKit 定，本文件不再写死。
                // 🚨 生活页仍在这条链路上（v4.0.81 它被误删过一次 → 真机少一页；护栏：ql_dock 表「四档渲染齐」）。
                ForEach(dockRenderTabs, id: \.self) { tab in
                    dockPage(tab)
                }
            }
            // v4.0.82：顺序/显隐变更 → `.id` 变化触发一次重建，系统 tab bar 才会立即重排
            //（iOS 26 上仅靠 ForEach 的增量变化，tab bar 的格子不会即时刷新）
            .id(dockRenderKey)
            // v4.0.120：原先这里两条 `revealCenter` 初始化/刷新随圆扩散一起删除（切页改内容层定向滑入）。
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

    /// 聊天槽位（v4.0.81 起两态合一：iPhone 上是「首页 ↔ 对话页」双态宿主，iPad 宽屏仍是会话+聊天双栏）：
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
            // v4.0.81：合并「聊天」tab —— 一页两态（会话首页 ↔ 对话页）。
            // 首页 = 会话页那套能力面原样复用（搜索/归档箱/分类/标签/多选批量删/远端全史搜索一字未改），
            // 顶部多出「机器人 + 每日一言 + ≤8 张自定义卡片」的首页头（showHero: true）。
            // 🚨 v4.0.122（用户 2026-10-18 拍板「要参考图这种跟手滑动返回」）：两态从 `if/else` 改成
            // **ZStack 双页同框** —— 跟手必须有「两页同时在屏上」那一帧（对话页贴着手指右移、
            // 会话首页从左侧同步露出来）；旧结构的 `if/else` 只留一页，位移一开底下就是空的（露垫底）。
            // 两页的在场条件各自独立：首页 = `showSessionHome`（常态）**或** `backFollowLive`（跟手垫底页），
            // 对话页 = `!showSessionHome`（跟手中它就在场，只是被位移推出屏外）。
            ZStack {
                if showSessionHome || backFollowLive {
                    // 实参序 = 声明序（onOpenSession → showHero → onAskAI），CI 参数序检查才过
                    // 🚨 v4.0.122：进对话页**必须**先 `resetBackFollow()` —— 跟手/回弹窗口里首页是垫底页、
                    // 完全可点：这一下点击若不清跟手状态，0.4s 后那个收尾任务会把 `showSessionHome` 翻回 true
                    // （用户看着像点了没反应，会话却已被 load + 标已读）；且残留位移会让对话页以非 0 位移插入。
                    SessionsView(onOpenSession: { withAnimation(Motion.page) { resetBackFollow(); showSessionHome = false } },
                                 showHero: true,
                                 onAskAI: { askAI($0) },
                                 launchRise: launchRise,
                                 // v4.0.124：只有「跟手垫底」这一种在场不是正式首页 → 不触发 load 重活
                                 // v4.0.125：返回扩散未落定（!homeSettled）也不刷 —— 列表 diff 砸在扩散帧里是
                                 // 「返回首页掉帧」的另一半（前半是 clipShape 裁剪本身）。
                                 isBackdrop: (backFollowLive && !showSessionHome) || !homeSettled)
                        // v4.0.114（用户「聊天详情手势滑动返回过渡太生硬」）：返回时列表从**左边**滑回来
                        // （进入聊天时它反向滑向左边）—— 与下面聊天的移向凑成 push/pop 的观感。
                        // 此前两态都是默认的交叉淡化 + Motion.tap(0.12)，读作「啪一下闪过去」。
                        // v4.0.115（用户「**还是**动效生硬」）：**摘掉 `.opacity`** ——
                        // 「横移 + 淡入淡出」两页各淡各的，位移被稀释成「叠着闪一下」，
                        // v4.0.114 想给的方向感等于白给。纯 .move 才是 push/pop 的原生观感
                        // （两页正好左右拼满一屏，中途不留缝、不露底）。
                        //
                        // 🚨 v4.0.116（用户 2026-10-13「聊天页滑动返回聊天主页采用圆形扩散转场特效：新页面
                        // 就从手指滑动位置向外扩散直到铺满整个屏幕」）：**返回方向**整条换成圆形扩散 ——
                        // 形状 / 最大半径与 dock 切页（TabTransitionModifier、ChatZoomEntryModifier）同一套
                        //（`RevealCircleShape` + `Motion.pageRevealMaxRadius`）；**曲线 v4.0.117 起分家** ——
                        // 见下方 `SessionHomeRevealModifier` 头注。
                        // 入场因此改成**瞬时**（`.identity`）：扩散由 `sessionHomeReveal` 的可动画裁剪自己演
                        // （半径 0 → max）。若这里仍留 `.move(edge: .leading)` 当入场，整页横移会与扩散
                        // 同时演 → 位移把圆切碎，正是 v4.0.115 治过的病。
                        // 圆外露的是 TabView 底下那层常驻渐变垫底（回退⑰）= 与 dock 切页逐帧同款，
                        // 「先白一下」不会复发。
                        // 离场（进对话页）保持原样的左滑出，与 ChatView 的右滑入凑成 push 观感，一字未改。
                        .sessionHomeReveal(center: $homeRevealCenter)
                        .transition(.asymmetric(insertion: .identity, removal: .move(edge: .leading)))
                }
                // v4.0.116：返回方向改圆形扩散后，对话页**离场不再右滑**（`.identity` 瞬时移出）——
                // 否则「向右滑出 + 圆扩散」两套动作同时演，观感是两页各演各的。
                // 入场仍是从右边滑入（用户没提进入方向，别顺手改）。
                //
                // 🚨 v4.0.122：整页跟手位移挂在这里（`backFollowOffset`，含页头与输入栏 —— 微信那把也是整页走）。
                // 跟手帧由 `backFollow(_:)` **裸赋值**（不许过动画事务：过动画页面就落在手指后面）；
                // 收敛 / 回弹才走 `Motion.page`（与两态切换同一枚页面级令牌，时序不分家，见 ql_docklayout Ⓝ）。
                if !showSessionHome {
                    ChatView(onBackToHome: { backToSessionHome() },
                             onBackFollow: { backFollow($0) },
                             onBackFollowEnd: { backFollowEnd(complete: $0) })
                        // 🚨 v4.0.122：位移只在「跟手/收敛/回弹在途」（`backFollowLive`）时生效 ——
                        // 不跟手时恒 0，任何残留值（手势被打断那种）都不会落到别的路径上（结构护栏）。
                        .offset(x: backFollowLive ? backFollowOffset : 0)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .identity))
                }
            }
            // v4.0.117：冷启动（launchRise 还没放行 = 启动页正盖在上面）时本页**不播**入场 ——
            // 那一刻演入场的是启动页自己（SplashView），两层同演会各切各的。
            // v4.0.120：入场景由圆扩散改成**内容层定向滑入**（口径同 tabTransition，见 ChatZoomEntryModifier）。
            // v4.0.125：转场落定后再放数据刷新（见上方 settledTab / homeSettled 注释）
            .modifier(TransitionSettleModifier(selected: $selected,
                                               settled: $settledTab,
                                               showSessionHome: $showSessionHome,
                                               homeSettled: $homeSettled))
            .chatZoomEntry(selected: $selected, order: dockRenderTabs,
                           skipFirstEntry: !launchRise)
            // v4.0.124（用户 2026-10-19「聊天页详情页隐藏 dock」「滑动返回更顺」）：
            // 对话页整页无底栏；跟手一开始就让底栏回来 —— 首页正从左侧露出，底栏跟着出现才是微信观感。
            // 顺带治流畅性：tab bar 是液态玻璃层，页面位移时它每帧重采样背景，是跟手掉帧的大头，
            // 隐藏后这段合成开销直接消失。iPad 双栏不隐藏（会话与对话同屏）。
            .toolbar(showSessionHome || backFollowLive ? .visible : .hidden, for: .tabBar)
            .tag(DockTab.chat)
            .tabItem { Label(DockTab.chat.title, systemImage: DockTab.chat.icon) }
        }
    }

    // v4.0.81：原 clearOrbNotice()（清球上未查看/失败提示）随球一起删除 —— 球没了，两态无处显示。

    /// 程序化切页前调用：本次切到聊天页不放烟花（0.6s 内未消费则自动复位，避免标志残留吞掉下一次真点击）
    private func skipBurstOnce() {
        skipNextBurst = true
        Task { try? await Task.sleep(for: .seconds(0.6)); skipNextBurst = false }
    }

    /// v4.0.116：返回聊天首页的**页头按钮唯一出口**。
    /// 🚨 v4.0.122：左缘手势改**跟手位移**后不再走这里（那条由 `backFollow` / `backFollowEnd` 收口），
    /// 所以这里只剩页头返回按钮一个入口 —— 它没有手指可依，圆心**兜底屏幕中心**（圆形扩散照旧演）。
    /// 页面级令牌仍是 `Motion.page`（两态切换的时长真源，见 ql_docklayout 表 Ⓝ）。
    private func backToSessionHome() {
        // 🚨 v4.0.122：跟手 / 回弹在途时（首页已作为垫底页在屏上）走**同一条「完成」收敛**：
        // ① 直接切态会把位移与残留圆心留在原地 —— 残圆心会被下一轮跟手新建的首页 onAppear 消费掉，
        //    变成「位移 + 圆同时演」（切碎），正是 SessionHomeRevealModifier 头注声明要避免的病；
        // ② 首页此刻已在树上，onAppear 不会再来 → 写圆心也没人消费（这一下本来就没有圆扩散）；
        // ③ 直接硬切与其余路径割裂，收敛过去才是同一套时序。
        if backFollowLive {
            backFollowEnd(complete: true)
            return
        }
        homeRevealCenter = CGPoint(x: DockOrbOverlay.keyWindowWidth / 2,
                                   y: DockOrbOverlay.keyWindowHeight / 2)
        withAnimation(Motion.page) { showSessionHome = true }
    }

    // MARK: - v4.0.122 左缘右滑跟手返回的两个收口（手势壳在 ChatView.ChatEdgeBackModifier）

    /// 把跟手状态整个收掉：位移归 0 + 卸垫底页 + 作废在途的收尾任务（seq 递增）。
    /// 为什么必须有这条兜底：跟手状态原本只有「正常抬手」一个出口，手势被打断（`onEnded` 不来：
    /// 来电 / 通知 / 进后台 / 视图被摘下）时会残留 —— 残留 = 对话页停在半路 + 首页一直当垫底页；
    /// 且「点会话进对话页」这条路若不清，0.34s 收敛窗口里的那次点击会被收尾任务覆盖回去。
    /// 手势侧的对称兜底在 ChatEdgeBackModifier（换手势就重过门 + 收回上一轮）。
    private func resetBackFollow() {
        backFollowSeq &+= 1
        backFollowOffset = 0
        backFollowLive = false
    }

    /// 跟手一帧：位移**裸写**（零动画事务 —— 过动画页面就落在手指后面），并让首页作为垫底页在场
    /// （下一帧就是「两页同框」：对话页被推右、首页从左侧露出来）。
    /// ⚠️ 每次递增 `backFollowSeq`：新一轮跟手必须作废上一轮收敛的收尾任务
    ///（否则 0.34s 窗口内再甩一把，旧任务回来把位移/垫底页清掉 = 页面跳回原位）。
    private func backFollow(_ dx: CGFloat) {
        backFollowSeq &+= 1
        if !backFollowLive { backFollowLive = true }
        backFollowOffset = dx
    }

    /// 松手：`complete` = 越过阈值（位移过半 / 甩动预测过半）→ 收敛到返回；否则回弹归位。
    /// 两条都要**等动画跑完**再收尾：回弹要在位移归 0 之后才卸垫底页（否则中途露垫底），
    /// 完成要等对话页整个滑出屏才切态（否则切态那一帧会被看见）。
    /// 延迟取 0.4s（`Motion.page` 是 .smooth 0.34，留一点裕量；早了会切在半路上）。
    private func backFollowEnd(complete: Bool) {
        backFollowSeq &+= 1
        let mySeq = backFollowSeq
        let width = DockOrbOverlay.keyWindowWidth
        if complete {
            // 收敛：位移继续走完剩下的路（同 `Motion.page`，与两态切换同一时序口径）
            withAnimation(Motion.page) { backFollowOffset = width }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.4))
                guard mySeq == backFollowSeq else { return }
                // 首页此刻**已经在屏上**（跟手铺开的那一帧就是它）→ 只翻状态，不写圆心（= 不播扩散）
                showSessionHome = true
                // 位移归零与卸垫底页放到**切态之后**：这一拍对话页已从树上摘掉（removal = .identity），
                // 怎么改都看不见 —— 反过来的顺序会让它在归零那一帧闪回屏幕中央。
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.05))
                    guard mySeq == backFollowSeq else { return }
                    backFollowOffset = 0
                    backFollowLive = false
                }
            }
        } else {
            // 回弹：归位（同 `Motion.page`）
            withAnimation(Motion.page) { backFollowOffset = 0 }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.4))
                guard mySeq == backFollowSeq else { return }
                // 对话页此时已完全盖住首页 → 卸掉这层垫底页（不可见）
                backFollowLive = false
            }
        }
    }

    /// 点 dock 智能球 → 烟花（约 1.55s 后移除特效层，与原型一致）
    private func fireDockBurst() {
        // v4.0.7：开关关着就不放（skipBurstOnce 的去抖逻辑不受影响，语义仍是「程序化切页不放烟花」）
        guard dockBurstOn else { return }
        showDockBurst = true
        Task { try? await Task.sleep(for: .seconds(1.55)); showDockBurst = false }
    }

    // MARK: - v4.0.82 dock 档位页面（原 body 里的静态四块整块搬来，参数一字未改）

    /// 一档的页面内容。⚠️ `.tag` / `.tabItem` 由 `.tabTransition(...)` 内部挂（见 TabTransitionModifier）——
    /// 除 chatTab（它自带）外，每一档都**必须**套 `.tabTransition`，否则那一档在 dock 上没有图标。
    @ViewBuilder
    private func dockPage(_ tab: DockTab) -> some View {
        switch tab {
        case .chat:
            chatTab
        case .life:
            LifeView(isActive: settledTab == .life)
                .tabTransition(for: .life, selected: $selected, order: dockRenderTabs)
        case .dashboard:
            // v3.4.26：isActive 参数直传（selected==.dashboard），替代 qingliaoDashboardLeave/Refresh 通知 ——
            // 轮询暂停/恢复收进 DashboardView 自身生命周期，去隐式耦合
            DashboardView(isActive: settledTab == .dashboard)
                .tabTransition(for: .dashboard, selected: $selected, order: dockRenderTabs)
        case .workspace:
            // v4.0.108：工作区（「AI 替我干的活」聚合页）。
            // ⚠️ 与其余档同款必须套 .tabTransition —— 漏挂这一档在 dock 上就没图标（真值表口径）。
            // v4.0.109：「待你处理」点进会话的回调 —— 会话**已由工作区装进 ChatStore**（`chat.loadById`），
            // 这里只负责切到聊天 tab 并让它落到**对话页**（showSessionHome = false）——
            // 与 `SessionsView` 点会话卡同一收口：本仓唯一的「进对话页」判据就是这一个 bool。
            // 程序化切页照例 skipBurstOnce()（烟花语义是「点了 dock 智能球」，不该为跳转放）。
            WorkspaceView(isActive: settledTab == .workspace,
                          onOpenSession: {
                              skipBurstOnce()
                              // v4.0.115：与聊天页两态切换同款页面级令牌 —— 原先 Motion.tap（.snappy
                              // 0.12）是拿控件曲线驱动整页位移，读作「啪一下」，正是本轮动效修复的病根。
                              withAnimation(Motion.page) {
                                  showSessionHome = false
                                  selected = .chat
                              }
                          },
                          // v4.0.115：工作台工具格「会议纪要」—— 与长按球 case 6 同一条路。
                          onOpenMinutes: { openMinutesPage() })
                .tabTransition(for: .workspace, selected: $selected, order: dockRenderTabs)
        case .settings:
            // v4.0.0：设置页大类 → 明细的二级页需要 NavigationStack 才有返回栈
            //（TabView 里裸放 NavigationLink 点了不推、也不显示返回键）。只包设置 tab —— 其他 tab 的层级结构一行不动。
            NavigationStack {
                SettingsView()
                    // 🚨 审查 F7：iOS 26 的 NavigationStack 在无 navigationTitle 时仍保留导航栏占位
                    //   → 顶部多一段空白/空返回槽。本页用自绘 PageHeader（不占系统栏），故显式藏掉。
                    //   参考同仓同款：RecordSection:236 / MemoSection:235 / TodoSection:224。
                    //   二级页仍要系统侧滑返回，但它的 PageHeader 已自绘返回键，不靠系统栏。
                    .toolbar(.hidden, for: .navigationBar)
            }
                .tabTransition(for: .settings, selected: $selected, order: dockRenderTabs)
        case .sessions:
            // v4.0.81：会话页已并入「聊天」，enum 里留这一档只为深链兜底（不占 dock 槽位、永不进渲染列表）
            EmptyView()
        }
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
        // v4.0.81：合并 tab 后「问 AI」必须落在**对话页**（首页只是列表，进不去这条提问）
        showSessionHome = false
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
            // v4.0.86（bugfix）：**必须落在对话页**。v4.0.81 合并 tab 后，聊天 tag 有两态
            // （会话首页 ↔ 对话页）；v4.0.83 起快捷菜单的弹出位就在**会话首页**之上 ——
            // 此时 selected 已是 .chat、showSessionHome=true 渲染的是 SessionsView，
            // ChatView 不在视图树：requestNewSession 置的 pendingNewSession 没有任何
            // onChange 挂着消费 → 症状就是「点了没反应」（用户 2026-10-09 真机报障）。
            // 修复对齐 askAI 同款范式：先切进对话页（showSessionHome=false）；不在对话页
            // 时还要错开一拍（转场落定 ChatView 进树、onChange 挂上）再置位，否则照丢。
            if selected != .chat || showSessionHome {
                skipBurstOnce()
                selected = .chat
                showSessionHome = false
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.35))
                    chat.requestNewSession()
                }
            } else {
                // 已在对话页：同步走原路（v3.9.59：不切页不放烟花，也不延迟）
                chat.requestNewSession()
            }
        case 1:   // AI 速记
            quickCapture = .memo
        case 2:   // 语音输入
            // v4.0.86（bugfix）：与 case 0 同根 —— 从会话首页/其它 tab 进来时 ChatView
            // 不在树（或转场未落定），同步 post 的 .qingliaoOrbVoiceInput 没人收 → 失效。
            // 对齐 askAI 的 0.35s 闸：先切对话页，落定后再 post（ChatView 内部还有一层
            // 0.35s 才进语音模式，语义不变）。已在对话页则同步 post，原速不变。
            if selected != .chat || showSessionHome {
                skipBurstOnce()
                selected = .chat
                showSessionHome = false
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.35))
                    NotificationCenter.default.post(name: .qingliaoOrbVoiceInput, object: nil)
                }
            } else {
                NotificationCenter.default.post(name: .qingliaoOrbVoiceInput, object: nil)
            }
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
            if selected != .chat || showSessionHome { skipBurstOnce() }
            selected = .chat
            // v4.0.86：从会话首页进来也要切到对话页（showSessionHome=false）——
            // 全念/发送两条命脉都挂在 ChatView 上，停着首页=ChatView 不在树（同 case 0/2 根因）。
            showSessionHome = false
            showVoiceDialog = true
        case 6:   // 会话纪要（v4.0.x 新胶囊）
            // v4.0.115：口径与实现收进 openMinutesPage（工作台工具格是第二个入口，两个入口共用一份）。
            openMinutesPage()
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

    /// v4.0.115：进「会议纪要」的**唯一实现**（长按球菜单 case 6 与工作台工具格共用）。
    ///
    /// 🚨 必须先让聊天页进视图树（与 case 2/4/7 同款闸）：纪要整理完那张卡由 `MeetingMinutesView`
    /// post `.qingliaoMinutesCard`，**唯一接收方是 ChatView 的 onReceive** —— 用户在生活页/看板页/
    /// 工作台进纪要、录完音整理好，卡片会因为 ChatView 不在树里而静默消失（备忘存了、卡没了，
    /// 用户只看到「已放进会话」这句假话）。v4.0.115 审查实测：工作台工具格直接 present 就是这个坑。
    /// 顺带的好处：dismiss 纪要页出来就是聊天页，刚落的那张卡就在眼前。
    /// 全屏页而非 sheet：纪要正文要占满整屏读，页内自带 dismiss（与语音对话页同一口径）。
    private func openMinutesPage() {
        if selected != .chat || showSessionHome { skipBurstOnce() }
        selected = .chat
        // v4.0.86：从会话首页进来也切到对话页 —— 纪要卡唯一接收方 ChatView 才在树里。
        showSessionHome = false
        showMinutes = true
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
            // v4.0.83（用户 2026-10-09：「现版本轻聊快捷菜单布局偏出屏幕」「打开快捷菜单弹出的画面要
            // 等同于长按聊天首页卡通宠物触发弹出的画面」）：**落点 = 会话首页**（`.chat` tag 下的
            // `showSessionHome` 态 —— 就是「会话列表 + 机器人 + 每日一言 + 卡片」那一屏，本仓俗称聊天首页）。
            // 原来落对话页：会话已有消息时欢迎页压根不渲染 → 锚点拿不到 → 退回 `openOrbMenuAtDockSlot()`
            // （锚在底部栏、胶囊朝上冒），用户看到的就是那个「从屏幕底部弹出来」的错误画面。
            // 会话首页的宠物在首页头里**常驻**（与有没有消息无关）→ 锚点必得，画面与长按会话页宠物完全同一条。
            // 🚨 落点**不是** `selected = .sessions`：`.sessions` 不在 `dockRenderTabs` 里
            //    （`DockLayoutKit.allRaw` 只有 chat/life/dashboard/settings，见下方 :502-509 同款口径：
            //    会话路由一律折成 `.chat` + showSessionHome）→ 选中它会渲染**空白页**。
            let onChatHome = (selected == .chat && showSessionHome)
            // 🚨 切页与弹菜单**必须错开一轮**（原口径保留）：`selected` 的变更会在 `onChange(of: selected)` 里
            //    执行「if showOrbMenu { showOrbMenu = false }」，同一轮里先写 true 再写 false → SwiftUI 只渲染
            //    最终值 false → 菜单一次都不出现（症状：只跳页不弹菜单）。所以切过页的路径延到下一轮；
            //    本来就在会话首页的直接同步弹（没有这次写入）。
            if !onChatHome {
                skipBurstOnce()
                selected = .chat
                showSessionHome = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))   // 让切页与 onChange(of: selected) 先落定
                    requestOrbMenuAtPetAnchor()
                }
            } else {
                requestOrbMenuAtPetAnchor()
            }
            return
        }
        guard var tab = DockTab(rawValue: route.rawValue) else { return }
        // v4.0.81：会话 tab 已并入「聊天」→ 深链/快捷指令里的「会话」落到聊天**首页**（会话列表）；
        // 明确指定「聊天」则进**对话页**。两处口径必须成对改，别只改一边。
        if tab == .sessions {
            showSessionHome = true
            tab = .chat
        } else if tab == .chat {
            showSessionHome = false
        }
        if selected != tab { skipBurstOnce() }
        // v4.0.82：目标页被用户隐藏了 → **临时插回**渲染（不写回配置）。
        // 「隐藏」只意味着不在 dock 上常驻，不丢功能：深链 / 首页卡片（如生活页的待办卡）点到它仍能到达；
        // 用户切到任一常驻档时自动清掉（见 DockTabChrome1 的 onChange(of: selected)）。
        if !dockRenderTabs.contains(tab) { forcedTabs.insert(tab) }
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

// MARK: - Tab 切换过渡动画（v4.0.120：内容层按槽位方向定向滑入）
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
/// v4.0.97 引入；v4.0.120 起**只服务两处**：滑动返回（SessionHomeRevealModifier）与启动页（SplashView）。
/// 底栏切页已不再是扩散（改内容层定向滑入，见 TabTransitionModifier 头注），别把切页挂回来。
/// 常态半径 = Motion.pageRevealMaxRadius（圆大到盖住整屏，等同不裁剪）；入场那一拍 0 → max。
/// ⚠️ 圆心是 **window 坐标**，与页面坐标原点一致（TabView 铺满全屏）；这里故意忽略入参 rect。
/// v4.0.125：转场优先 —— 把「页面成为活跃」拆成渲染（selected，立即）与数据（settled，转场后）。
/// 头注在 DockTabView 的 `settledTab` / `homeSettled`。
/// 独立成类型的原因与 ChatZoomEntryModifier 同宗：DockTabView.body 那条修饰符链再挂带闭包的
/// `.onChange` 会把类型检查器撑爆（v4.0.108 CI 实测 `unable to type-check in reasonable time`）。
private struct TransitionSettleModifier: ViewModifier {
    @Binding var selected: DockTab
    @Binding var settled: DockTab?
    @Binding var showSessionHome: Bool
    @Binding var homeSettled: Bool
    /// 切页位移 Motion.pageEnterSlide 是 0.28s，留 60ms 余量
    private let settleDelay: Duration = .milliseconds(340)

    func body(content: Content) -> some View {
        content
            .onAppear {
                if settled == nil { settled = selected }
            }
            .onChange(of: selected) { _, newValue in
                // 先撤掉旧档的活跃态（它的轮询立刻停），再等转场落定
                settled = nil
                Task { @MainActor in
                    try? await Task.sleep(for: settleDelay)
                    // 这 340ms 内又切走了 → 不把旧档置回活跃（否则离场页在后台偷偷 load）
                    if selected == newValue { settled = newValue }
                }
            }
            .onChange(of: showSessionHome) { _, home in
                guard home else { return }
                homeSettled = false
                Task { @MainActor in
                    try? await Task.sleep(for: settleDelay)
                    // 直接赋值（别写成 `if showSessionHome { ... }` —— check_swift 的 ⑲g 护栏按行首匹配，会误判成退回 if/else 单页结构）
                    homeSettled = showSessionHome
                }
            }
    }
}

struct RevealCircleShape: Shape {
    var center: CGPoint
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = max(0, radius)
        return Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                      width: r * 2, height: r * 2))
    }
}

// v4.0.120（用户 2026-10-17：「底栏换页改成内容层按槽位方向定向滑入，圆扩散只留启动页」）：
// 入场 = **内容层按槽位方向定向滑入** —— 新页内容从「新槽所在的那一侧」位移进场（起点 ±28pt → 落位 0），
// 方向按**新旧槽位序号差**判（`order` 里 index 谁大），不写死左右。
//
// 为什么换掉圆扩散（v4.0.97~v4.0.119 那套）：切页是**有方向的横向移动**，用「从点击点扩散」表达不出
// 「往左还是往右翻了一页」。圆扩散现在只剩两处：**启动页**（SplashView）与**滑动返回**
//（SessionHomeRevealModifier，另一枚更慢的曲线，见其头注）。
//
// 为什么位移期间不露白：TabView 底下常驻一层同款 `EnvironmentGlowLayers` 垫底（v4.0.72 回退⑰）——
// 位移那 28pt 露出来的就是这层渐变 = 与页底逐帧一致 → 不存在 v4.0.73~0.85 反复治的「先白一下」。
//
// 历史沿革（都在这一条上改过，别回退）：
//   v4.0.73 方案 A：页底渐变彻底退出动画 → 整页缩放/上浮会掀开顶部安全区那一条（真机复测「先白一下」）。
//   v4.0.78：原地淡入起点 0（全透明）才是「太闪」的正源 → 起点抬到 0.6，并成**单条** withAnimation。
//   v4.0.85：幅度加重（起点 0.75 / 位移 60pt / 弹簧曲线）—— 历轮为躲「闪/露白」一路压到 ≈硬切。
//   v4.0.97：用户点名要圆形扩散 → 淡入与横向微滑**整条换掉**。
//   v4.0.120：用户改口径「圆扩散只留启动页」→ 扩散整条换掉，改**定向滑入**（本条）。
// 禁令仍然有效：整页缩放入场（0.96 那套）/ 整页 y 轴上浮 / 低起点整页淡入（0.35 起手）一概不许回来。
// 🚨 曲线（pageEnterSlide）、位移（pageEnterShift）、方向判据三处口径与 ChatZoomEntryModifier 必须逐字一致。
private struct TabTransitionModifier: ViewModifier {
    let tab: DockTab
    @Binding var selected: DockTab
    /// v4.0.120：渲染档序（= 宿主的 `dockRenderTabs`）—— 方向按新旧槽位在它里面的 index 差判，不写死左右。
    let order: [DockTab]
    /// 入场起点位移：常态 0（落位）；入场那一拍先**瞬变**到 ±Motion.pageEnterShift，再动画回 0。
    @State private var slideOffset: CGFloat = 0
    @State private var seq = 0

    func body(content: Content) -> some View {
        content
            .tag(tab)
            .tabItem { Label(tab.title, systemImage: tab.icon) }
            // v4.0.120：只位移**内容层**（不碰整页透明度 —— 低起点淡入是老病，见头注禁令）。
            .offset(x: slideOffset)
            .onChange(of: selected) { oldVal, newVal in
                guard newVal == tab else { return }              // 离场不反向播（见头注）
                enter(from: oldVal)
            }
    }

    /// 新槽在右（index 更大）→ 从右进（起点 +shift）；反向 -shift。order 缺项时退「从右进」。
    private func direction(from oldVal: DockTab) -> CGFloat {
        guard let ni = order.firstIndex(of: tab), let oi = order.firstIndex(of: oldVal), ni != oi else { return 1 }
        return ni > oi ? 1 : -1
    }

    /// 起点瞬归 ±shift（**不加动画**）→ 下一拍 withAnimation 回 0。seq 防 0.01s 窗口内连点/快切互踩。
    private func enter(from oldVal: DockTab) {
        seq &+= 1
        let mySeq = seq
        withAnimation(nil) { slideOffset = direction(from: oldVal) * Motion.pageEnterShift }
        Task {
            try? await Task.sleep(for: .seconds(0.01))
            guard mySeq == seq else { return }
            withAnimation(Motion.pageEnterSlide) { slideOffset = 0 }
        }
    }
}

extension View {
    /// v4.0.82：多一个 `order`（同 tabTransition）
    func chatZoomEntry(selected: Binding<DockTab>,
                       order: [DockTab],
                       skipFirstEntry: Bool) -> some View {
        modifier(ChatZoomEntryModifier(selected: selected,
                                       order: order,
                                       skipFirstEntry: skipFirstEntry))
    }

    /// v4.0.116：聊天首页入场 = 从**手指位置**圆形扩散铺满（**滑动返回这条扩散 v4.0.120 起是唯一剩下的页内扩散**
    /// ——底栏切页已改定向滑入；形状/最大半径仍与启动页同一套，见 SessionHomeRevealModifier）。
    /// 传的是 Binding 而不是 `CGPoint?`：圆心「取走即清空」的语义在 modifier 的 onAppear 里完成。
    func sessionHomeReveal(center: Binding<CGPoint?>) -> some View {
        modifier(SessionHomeRevealModifier(pendingCenter: center))
    }
}

extension View {
    /// v4.0.82：多一个 `order`（当前渲染档序）—— 方向性滑入按它判左右，别再用写死的槽位序号。
    func tabTransition(for tab: DockTab, selected: Binding<DockTab>,
                       order: [DockTab]) -> some View {
        modifier(TabTransitionModifier(tab: tab, selected: selected, order: order))
    }
}

// v4.0.72：聊天页入场 —— 与 TabTransitionModifier 同宗（v4.0.120 起同改**定向滑入**）。当年独立成型的理由：
// 聊天页是 NavigationStack，push 进来的详情页会把它**整页**带走（`.navigationDestination` 之外的呈现），
// 用同一个 modifier 会给「详情返回」也播一遍入场 —— 所以这里的触发条件只认 `.chat`。
//
// v4.0.120：曲线（pageEnterSlide）、位移（pageEnterShift）、方向判据三处与 TabTransitionModifier 逐字一致
// —— 这是本仓护栏成对钉的口径，别只改一边。
private struct ChatZoomEntryModifier: ViewModifier {
    @Binding var selected: DockTab
    /// v4.0.120：渲染档序（方向判据，同 TabTransitionModifier）
    let order: [DockTab]
    /// v4.0.117：**冷启动首帧**不播入场（那一拍的入场交给启动页 SplashView 自己演，见 onAppear）
    let skipFirstEntry: Bool
    /// v4.0.117：onAppear 只认第一帧 —— 切页那条路走 onChange，不走这里（此前只挂 onAppear 也在切页时重跑过）
    @State private var didAppear = false
    /// 同 TabTransitionModifier：常态 0（落位）；入场那一拍先瞬变到 ±shift，再动画回 0
    @State private var slideOffset: CGFloat = 0
    @State private var seq = 0

    func body(content: Content) -> some View {
        content
            // v4.0.120：只位移内容层（同 TabTransitionModifier；不碰整页透明度）。
            .offset(x: slideOffset)
            // v4.0.117：冷启动首帧的入场**让给启动页** —— 那一刻本页还盖在 SplashView 底下，用户看不到；
            // 若这里照旧 enter()，两层入场同时在跑（v4.0.116 注释里点过名的病）。直接落终态，
            // 等用户切页时再按原口径正常播。
            .onAppear {
                guard !didAppear else { return }
                didAppear = true
                if skipFirstEntry {
                    seq &+= 1
                    withAnimation(nil) { slideOffset = 0 }
                } else {
                    // 无「旧槽」可比（不是切页触发的）→ direction 退「从右进」
                    enter(from: .chat)
                }
            }
            .onChange(of: selected) { oldVal, newVal in
                guard newVal == .chat else {
                    // 离场不反向播：位移直接归位（瞬变），下次入场再从 ±shift 起
                    seq &+= 1
                    withAnimation(nil) { slideOffset = 0 }
                    return
                }
                enter(from: oldVal)
            }
    }

    /// 新槽在右（index 更大）→ 从右进（起点 +shift）；反向 -shift。order 缺项时退「从右进」。
    private func direction(from oldVal: DockTab) -> CGFloat {
        guard let ni = order.firstIndex(of: .chat), let oi = order.firstIndex(of: oldVal), ni != oi else { return 1 }
        return ni > oi ? 1 : -1
    }

    /// 同 TabTransitionModifier：起点瞬归 ±shift → 下一拍 withAnimation 回 0
    private func enter(from oldVal: DockTab) {
        seq &+= 1
        let mySeq = seq
        withAnimation(nil) { slideOffset = direction(from: oldVal) * Motion.pageEnterShift }
        Task {
            try? await Task.sleep(for: .seconds(0.01))
            guard mySeq == seq else { return }
            withAnimation(Motion.pageEnterSlide) { slideOffset = 0 }
        }
    }
}

// v4.0.116（用户 2026-10-13：「聊天页滑动返回聊天主页采用圆形扩散转场特效：新页面就从手指滑动位置
// 向外扩散直到铺满整个屏幕」）—— 形状与 dock 切页（TabTransitionModifier / ChatZoomEntryModifier）**同一套**：
// 同一个 `RevealCircleShape`、同一个最大半径 `Motion.pageRevealMaxRadius`。与切页有**两处**差别：
//   ① 圆心来源：切页取「被点的那一档 dock 槽位中心」，这里取「手势抬手位置」；
//   ② 🚨 曲线 v4.0.117 起**分家**：这里用 `Motion.sessionBackReveal`（.smooth 1.10），
//      切页仍是 `Motion.pageReveal`（.smooth 0.75）。分家理由（用户 2026-10-15 真机口径）：
//      返回的圆心被左缘 24pt 钉在屏幕左侧中部、到最远角的行程比切页长，共用 0.75 读作
//      「刷一下扫完 = 太快」；而 0.75 是用户为切页三轮拍板的，顺手改 = 误伤在用动效。
//
// 为什么不用 onChange 触发（不像 TabTransitionModifier 那样盯 selected）：
// 首页在宿主里是 **ZStack 的垫底一支** —— 进对话页时整只销毁（`!showSessionHome` 只留对话页），
// 返回时是**新建实例**，所以它只能靠 `onAppear` 播入场；而「切到聊天 tab / 冷启动落首页 / 深链落首页」同样会 onAppear
// （那几条路的外层 `chatZoomEntry` 已经在播整页扩散，这里再播一次 = 两层圆各切各的）→
// 圆心走 **Binding 取走即清空**：只有写进圆心的那一次（v4.0.122 起 = 只剩页头返回按钮）会播。
// 🚨 v4.0.122：左缘**跟手**那条也会走进这一支（拖动一开始就把首页挂上来当垫底页 → onAppear），
// 但它**不写圆心** → 下面 `guard let c = pendingCenter` 直接 return：首页就是「被滑开露出来」的那一下，
// 不播扩散（跟手 + 扩散同时演 = 位移把圆切碎，正是 v4.0.115 治过的病）。
private struct SessionHomeRevealModifier: ViewModifier {
    /// 待消费的圆心（宿主写、这里 onAppear 取走并置回 nil）
    @Binding var pendingCenter: CGPoint?
    /// 本次入场的圆心快照（消费后固定，之后宿主怎么改都不影响正在播的这一拍）
    @State private var revealCenter: CGPoint = .zero
    /// 常态 = 全屏半径（等同不裁剪）；入场那一拍 0 → max
    @State private var revealRadius: CGFloat = Motion.pageRevealMaxRadius
    /// 本页全局原点（圆心换算用，同 TabTransitionModifier）
    @State private var pageOrigin: CGPoint = .zero
    @State private var seq = 0

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { pageOrigin = proxy.frame(in: .global).origin }
                        .onChange(of: proxy.frame(in: .global).origin) { _, new in pageOrigin = new }
                }
            )
            .clipShape(RevealCircleShape(center: localCenter, radius: revealRadius))
            .onAppear {
                // 🚨 取走即清空：先绑局部变量再判 nil（别在 guard 里探一次、后面再取一次）
                guard let c = pendingCenter else { return }
                pendingCenter = nil
                revealCenter = c
                enter()
            }
    }

    /// window 坐标 → 本页局部坐标（与 TabTransitionModifier / ChatZoomEntryModifier 逐字一致）
    private var localCenter: CGPoint {
        CGPoint(x: revealCenter.x - pageOrigin.x, y: revealCenter.y - pageOrigin.y)
    }

    /// 半径瞬归 0（不加动画）→ 下一拍 withAnimation 到 max。seq 防 0.01s 窗口内连点/快切互踩。
    private func enter() {
        seq &+= 1
        let mySeq = seq
        // 🚨 必须显式关动画事务：本页的插入事务是**调用方**用 withAnimation(Motion.page) 开的
        // （滑动手势 / 页头按钮那两处 showSessionHome = true），onAppear 里继承到的就是动画事务 ——
        // 那样 revealRadius = 0 会被动画化，0.01s 后又被下面这句重定向到 max，展示值一路贴着 max，
        // 圆形扩散静默不播（代码在、行为不在）。同族的 TabTransition / ChatZoom 走的是裸 selected 赋值、
        // 无动画事务，所以只有本条暴露该风险 —— 别依赖「onAppear 不继承入场事务」这条未证实前提。
        withAnimation(nil) { revealRadius = 0 }
        Task {
            try? await Task.sleep(for: .seconds(0.01))
            guard mySeq == seq else { return }
            // v4.0.117：这条用**返回专用**曲线 `sessionBackReveal`（比切页的 pageReveal 慢）——
            // 别顺手改回 pageReveal，那样返回又会「刷一下扫完」（用户 2026-10-15 真机口径）。
            withAnimation(Motion.sessionBackReveal) { revealRadius = Motion.pageRevealMaxRadius }
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
                            slotIndex: chatSlotIndex,
                            slotCount: dockSlotCount,
                            // v4.0.81：dock 那颗球已移除 → 菜单锚点球不再同步「未查看 / 失败」两态
                            //（两态 state 已删，见 state 区注释）；流式转动保留。
                            thinking: stream.isStreaming,
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
                // v3.6.2：点 dock 聊天槽位（= 切到聊天页）→ 放烟花，保留原智能球的点击特效
                // v4.0.81：球没了，「清未查看/失败提示」那半句随之删除（提示态已不存在）；
                // 烟花保留（用户要的正是「点聊天 = 放一束花」这个反馈）
                if newVal == .chat {
                    if skipNextBurst { skipNextBurst = false } else { fireDockBurst() }
                }
                // v4.0.82：临时插回的隐藏档（forcedTabs）—— 用户切到任一**常驻**档即清空，
                // 配置（UserDefaults 的隐藏串）全程不被改动；目标页本身就是被插回的那档时保留（见 applyRoute）。
                if !forcedTabs.contains(newVal) { forcedTabs.removeAll() }
            }
            // v4.0.82：dock 顺序/隐藏变更后（组合串变即观察），若当前所在档已被摘掉（用户在设置里隐藏了当前页）
            // → 兜底切到第一个可见档：绝不让 selected 停在渲染列表里不存在的档上（那会渲染空白页）。
            .onChange(of: dockRenderKey) { _, _ in
                if !dockRenderTabs.contains(selected) { selected = dockRenderTabs.first ?? .settings }
            }
            // v4.0.81：原先这里挂两条 onChange 维护「球上未查看 / 失败」两态（v3.9.33 的球第三态）。
            // 球移除 → 两态无处可显示，整块删除（含 v4.0.x 那条「finishSeq 与 startSeq 同帧」的顺序
            // 依赖修复）。若日后要做「刚答完」提示，请改成 tab bar 徽标或通知，别再复活球。
            // v4.0.81（用户口径 Q1=3）：dock 槽位那颗**自绘智能球整块移除** —— 连同它的命中层
            // （OrbHitLayer：轻点切页 + 长按弹菜单）。球的 9 个快捷入口不再有 dock 入口，
            // 唯一入口 = **长按宠物**（聊天首页头的机器人 / 聊天页欢迎页的宠物，都发
            // `.qingliaoOrbMenuFromPet` 自带锚点）。菜单/识别/录音三个浮层本身全部保留。
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
                                       slotIndex: chatSlotIndex,
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
                    // v4.0.81：球已移除 → 烟花原点取**聊天槽位**中心（槽位数 4 档，见 chatSlotIndex）
                    FullScreenBurst(originFromBottom: DockOrbOverlay.ballCenterFromBottom(barHeight: dockBarHeight,
                                                                                        index: chatSlotIndex, count: dockSlotCount))
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
