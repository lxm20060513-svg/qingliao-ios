// MARK: - v3.9.59（攒版）智慧球长按快捷菜单
//
// 交互：长按 dock 智慧球（≥0.45s）→ 弹出 8 颗功能胶囊：新建会话 / AI 速记 / 今日待办（下排）
//        + AI 识别 / 语音对话 / 语音输入（中排 = v3.9.76 的「上排」，位置一颗未动）
//        + 会话纪要 / 拍照识别（最上排 2 颗**居中**，v4.0.x 方案 A 新增）。
// 动效 = 方案 A+C 混合（用户拍板）：A 绽放（胶囊从球心弹簧弹射、错峰入场，落点几何见 OrbQuickMenuLayout）
//        + C 的球心光晕扩散（常驻柔光 + 一圈扩散环），**不做**全屏磨砂。
// v3.9.60：落点由「弧线散开」改为「两排两列」——弧线在 393pt 屏宽下四颗胶囊必然重叠（用户实测），
//        几何根因与算式写在 OrbQuickMenuLayout 上方。
// v4.0.x：6 颗 → 8 颗（方案 A，用户拍板对比稿）。**原 6 颗落点一颗不动**，只在更上方加第三排
//        2 颗居中（dy = 216，列 ∓0.5 → x = 球心 ∓59）→ 三排 dy 104 / 160 / 216、行间隙恒 20pt。
//        最窄 375pt 屏校验与「不撞灵动岛」的算式写在 OrbQuickMenuLayout.center 上方。
//
// 复用既有入口（不新造状态/后端）：
//   新建会话 → ChatStore.requestNewSession()（ChatView 的 pendingNewSession 两步走清屏）
//   AI 速记  → MemoStore.add(content:source:"orb")
//   语音输入 → 切聊天页 + 进程内通知 → ChatView.toggleVoiceMode（与输入框长按同一条路径）
//   今日待办 → TodoStore.add(content:source:"orb")
//   会话纪要 → DockTabView.fullScreenCover 呈现 MeetingMinutesView()（v4.0.x 新增，页内自带 dismiss）
//   拍照识别 → CameraPicker 拍一张 → **就地**进「AI 识别」浮层看图回答（形态与 AI 识别同款：
//              球上浮层卡 + 背景虚化 + 球心扫描环，关掉即走）。
//              ⚠️ 2026-09-27 改口径（旧口径作废）：原来是 ShareRouter.enqueue(SharedPayload(...)) +
//                 .qingliaoShareIncoming 走「系统分享接收」同一条管道发进**当前会话**；用户实测后要的是
//                 「不发送当前对话框，直接在当页做」→ 已撤（详见 DockTabView.handleCameraShot 的注释）。
//
// 手势口径（本仓已验证的模式）：
//   · 轻点 + 长按并存必须用 ExclusiveGesture（分开挂会在长按后补认一次 tap，v2.0.107 实踩）；
//   · 长按触发在手指未抬起时就会回调（LongPressGesture.onEnded 语义），菜单随按压弹出即预期；
//   · 菜单层是**模态**的——轻纱要拦触摸（点空白收起），与 v3.0.72「纯视觉 overlay 必须
//     allowsHitTesting(false)」的场景相反：那是对讲浮层不想抢事件，这里恰恰要吃掉空白点击。

import SwiftUI

// MARK: - 菜单项定义

struct OrbQuickAction: Identifiable {
    let id: Int
    let title: String
    let icon: String
    let color: Color

    /// v3.9.76：4 颗 → 6 颗；v4.0.x：6 颗 → 8 颗。**数组顺序 = 落点索引**
    /// （下排 0/1/2 贴球、中排 3/4/5 更远、最上排 6/7 居中，见 OrbQuickMenuLayout.center）；
    /// `id` 是**语义标识**（DockTabView.handleOrbAction 按它分发），与顺序解耦 ——
    /// 以后重排只动这个数组，不要动 id（动了就是悄悄换功能）。
    static let all: [OrbQuickAction] = [
        // 下排（离球近、拇指最顺手 → 高频：新建 / 速记 / 待办）
        OrbQuickAction(id: 0, title: "新建会话", icon: "plus.bubble.fill", color: .blue),
        OrbQuickAction(id: 1, title: "AI 速记", icon: "brain.head.profile", color: .purple),
        OrbQuickAction(id: 3, title: "今日待办", icon: "checklist", color: .orange),
        // 中排（v3.9.76 的「上排」——抬视线才用 → 「看」与「说」两个入口 + 原语音输入）
        OrbQuickAction(id: 4, title: "AI 识别", icon: "text.viewfinder", color: .teal),
        OrbQuickAction(id: 5, title: "语音对话", icon: "waveform.circle.fill", color: .indigo),
        OrbQuickAction(id: 2, title: "语音输入", icon: "mic.fill", color: .pink),
        // 最上排（v4.0.x 新增，2 颗**居中**：列 ∓0.5 → x = 球心 ∓59）
        // 图标取 SF Symbols 里既有的「清单卡」与「取景器」形态，与上两排同一套细线风格
        OrbQuickAction(id: 6, title: "会话纪要", icon: "list.bullet.rectangle", color: .brown),
        OrbQuickAction(id: 7, title: "拍照识别", icon: "camera.viewfinder", color: .cyan),
    ]
}

// MARK: - v3.9.78 菜单锚点：dock 智慧球 / 聊天页宠物（v3.9.82 起画法只留宠物）
//
// 用户：「长按宠物改成和长按智慧球一样的效果」→ 唯一正解是**同一套菜单层**换个锚点，
// 而不是在聊天页再搭一套（动作分发 handleOrbAction 全在 DockTabView，复制一份必然漂移）。
// 菜单层本来就吃 `ballCenter`（胶囊从它绽放、轻纱之上重画它），所以这里只把「锚点是什么」
// 变成参数。
//
// 🚨 v3.9.82（用户 2026-09-27）：「长按智慧球跳转画面改为长按卡通宠物跳转画面，只保留一个跳转画面」
//    —— 锚点**画法只留宠物一套**（球版那套重画已整段删；dock 入口也画宠物，尺寸仍按位置走）。
//    本条原来写的是「dock 分支口径一字未改（仍是那颗球）」—— 那句话已作废，别再照它回改。

/// 从聊天页宠物发起长按时的锚点（**全局坐标** + 尺寸；由 ChatView 量好传来）
struct OrbPetAnchor: Equatable {
    var center: CGPoint
    var size: CGFloat

    /// 跨视图信号本仓统一走 NotificationCenter（与 .qingliaoOrbVoiceInput / .qingliaoTaskSend 同风格），
    /// 不为这一次点击新造共享状态。NSValue 负责打包 CGPoint。
    var userInfo: [String: Any] { ["center": NSValue(cgPoint: center), "size": size] }

    init(center: CGPoint, size: CGFloat) {
        self.center = center
        self.size = size
    }

    init?(userInfo: [AnyHashable: Any]?) {
        guard let v = userInfo?["center"] as? NSValue, let s = userInfo?["size"] as? CGFloat else { return nil }
        center = v.cgPointValue
        size = s
    }
}

/// 欢迎页宠物锚点的**外部开菜单握手**（供「打开轻聊快捷菜单」那条 App 外的入口复用长按宠物那套画面）。
///
/// 为什么需要它：长按宠物那条路是 ChatView 直接把锚点打包进 `.qingliaoOrbMenuFromPet` 通知，
/// dock 侧白拿；而快捷指令 / Siri 的「打开轻聊快捷菜单」是**从 App 外面**进来的 —— 它没有手势，
/// 也不知道宠物现在在哪。于是走一次**请求 / 应答**，两条可能路径都汇到 dock 那条既有通知
/// （动作分发、互斥收口、锚点刷新仍全在原处，**一份入口都不复制**）：
///   ① 宠物**已经在屏**（欢迎页已挂树）→ dock 发 `.qingliaoRequestPetAnchor`，`petHero` 立刻应答；
///   ② 宠物**刚要挂树**（刚切到聊天页）→ 那次请求没人听；随后 `onChange(of: petGlobalCenter)` 上报，
///      `publish` 消费掉 pending 并补发同一条应答通知；
///   ③ 两者都不来（会话已有消息、欢迎页压根不渲染）→ dock 侧超时兜底退回槽位锚点弹。
///
/// ⚠️ 别改回「靠坐标时间戳判宠物在不在屏」：用户停在欢迎页不动时宠物不动 → 不再上报 →
/// 会被误判成「不在屏」，菜单锚到 dock 而不是宠物。
@MainActor
enum OrbPetAnchorRegistry {
    /// 有一张菜单等着「宠物锚点就位后再弹」
    private static var pendingOpen = false

    /// 请求序号：每次请求自增。超时兜底只在「序号仍是我」时才动手 ——
    /// 否则两次请求（用户连按两下快捷指令）时，第一个的 1.2s 到点会看到**第二个**的 pending 为真，
    /// 把它 cancel 掉并弹 dock 槽位，把本该锚在宠物上的菜单拉回球位。
    private static var requestSeq = 0

    /// 发起一次请求，返回本次的序号（超时兜底凭它识别「自己那次」）。
    static func beginRequest() -> Int {
        requestSeq += 1
        return requestSeq
    }

    /// 序号是否仍指向最后一次请求（= 我就是最新的那次，没人抢）
    static func isLatest(_ seq: Int) -> Bool { seq == requestSeq }

    /// 宠物中心上报（`petHero.onChange` 路径）：pending 被消费掉时返回 true → 请补发那条应答通知。
    @discardableResult
    static func publish() -> Bool {
        let wasPending = pendingOpen
        pendingOpen = false
        return wasPending
    }

    /// 请求「等宠物应答锚点后弹菜单」：置 pending + 喊一声已挂树的宠物。
    /// @return 本地 pending 是否还挂着（false = 已被消费 / 此前无人请求）。
    @discardableResult
    static func requestMenuOnPetAnchor() -> Bool {
        pendingOpen = true
        NotificationCenter.default.post(name: .qingliaoRequestPetAnchor, object: nil)
        return pendingOpen
    }

    /// 应答侧消费（`petHero` 的请求监听器）：置 pending 时返回 true → 立刻弹。
    @discardableResult
    static func consumePendingRequest() -> Bool {
        let wasPending = pendingOpen
        pendingOpen = false
        return wasPending
    }

    /// 超时兜底前先复查：pending 已被消费（宠物应答过了）就别再顶一层菜单
    static var hasPendingMenu: Bool { pendingOpen }

    /// 放弃等待（超时兜底：改走 dock 槽位锚点那条路）
    static func cancelPendingMenu() { pendingOpen = false }
}

extension Notification.Name {
    /// 聊天页宠物长按 → 请求 dock 层弹出「长按快捷菜单」（与长按智慧球同一套菜单与动作分发）
    static let qingliaoOrbMenuFromPet = Notification.Name("qingliaoOrbMenuFromPet")
    /// v3.9.79：宠物在屏幕上的真实中心变了 → **只刷新菜单锚点**（不弹菜单）。
    /// 为什么必须与上面那条分开：菜单弹出会顺手收键盘，宠物随之下移（Spacer 回弹 ≥56pt），
    /// 而锚点是「长按那一刻的快照」→ 菜单层会在旧位置再画一只宠物（真机观感＝两只宠物 + 胶囊挂在上方那只身上）。
    /// 复用「打开菜单」那条通知做不到这件事：宠物任何位移都会把菜单重新弹出来。
    static let qingliaoPetAnchorMoved = Notification.Name("qingliao_pet_anchor_moved")
    /// v4.0.x：dock 层要弹菜单、但需要**欢迎页宠物的锚点** → 问一声（欢迎页在场就应答）。
    /// 只有「App 外的快捷指令入口」会发这条；长按那条路自己带锚点，不走这里。
    static let qingliaoRequestPetAnchor = Notification.Name("qingliao_request_pet_anchor")
    /// v4.0.x：欢迎页宠物对上面那条请求的**应答**（带锚点）—— dock 侧与长按那条合流到同一段消费逻辑。
    /// ⚠️ 为什么不直接复用 `.qingliaoOrbMenuFromPet`：ql_orbmenu 护栏钉着那条通知在 ChatView 里
    /// 只出现一次（长按手势那处），复用会让「同一件事两个发声点」那条护栏打红。
    static let qingliaoOpenOrbMenuAtPet = Notification.Name("qingliao_open_orb_menu_at_pet")
}

/// 菜单锚点画什么：dock 智慧球（默认）/ 聊天页宠物
enum OrbQuickMenuAnchor: Equatable {
    case dockOrb
    case pet(size: CGFloat)
}

// MARK: - 球命中层（轻点切聊天页 + 长按弹菜单）
//
// DockOrbOverlay 整层 allowsHitTesting(false)（触摸穿透给系统 tab item）；本层只盖住球体
// 一小块（68pt 圆），轻点 = 手动 `selected = .chat`（DockTabView.onChange 里的触感/烟花照旧
// 触发，与「点系统 tab item」同语义），长按 = 弹快捷菜单。

struct OrbHitLayer: View {
    var barHeight: CGFloat
    var slotIndex: Int = 2
    var slotCount: Int = 5
    var onTap: () -> Void
    var onLongPress: () -> Void

    var body: some View {
        GeometryReader { geo in
            let g = geo.frame(in: .global)
            let barH = barHeight > 1 ? barHeight : DockOrbOverlay.fallbackBarHeight
            // v3.9.59：球心**必须**走 DockOrbOverlay.orbCenterGlobal（与可见球同源）。
            // 命中圈自己算一份等分几何会错位：DockOrbOverlay 的 x 优先取真实槽位按钮中心
            // （iOS 26 玻璃 tab bar 内容有内缩，等分估算与真实中心不重合）→ 圈偏了 = 按球没反应。
            let c = DockOrbOverlay.orbCenterGlobal(slotIndex: slotIndex,
                                                   slotCount: slotCount,
                                                   barHeight: barH)
            Color.clear
                .frame(width: 68, height: 68)
                .contentShape(Circle())
                .gesture(
                    ExclusiveGesture(
                        LongPressGesture(minimumDuration: 0.45).onEnded { _ in onLongPress() },
                        TapGesture().onEnded { onTap() }
                    )
                )
                .position(x: c.x - g.minX, y: c.y - g.minY)
        }
    }
}

// MARK: - 菜单浮层宿主（几何定位 + 菜单层）

struct OrbQuickMenuOverlay: View {
    var barHeight: CGFloat
    var slotIndex: Int = 2
    var slotCount: Int = 5
    /// v3.9.78：菜单层要在材质模糊**之上**重画一颗「锚点球」，状态与 dock 那颗同源
    ///（流式转动 / 未读亮点 / 失败压暗）—— 不传就永远是一颗「空闲」球，与背后真实状态打架。
    var thinking: Bool = false
    var unseen: Bool = false
    var failed: Bool = false
    /// v3.9.78：「长按宠物 = 长按智慧球同一套菜单」→ 宠物发起时传它的**全局中心与尺寸**；
    /// nil = dock 智慧球（原口径一字未改，dock 那条路仍走 DockOrbOverlay.orbCenterGlobal）。
    var petAnchor: OrbPetAnchor? = nil
    var onAction: (OrbQuickAction) -> Void
    var onClose: () -> Void

    var body: some View {
        GeometryReader { geo in
            let g = geo.frame(in: .global)
            let barH = barHeight > 1 ? barHeight : DockOrbOverlay.fallbackBarHeight
            // 同 OrbHitLayer：球心走 DockOrbOverlay.orbCenterGlobal，与可见球严格同源
            let c = petAnchor?.center ?? DockOrbOverlay.orbCenterGlobal(slotIndex: slotIndex,
                                                                      slotCount: slotCount,
                                                                      barHeight: barH)
            OrbQuickMenuLayer(ballCenter: CGPoint(x: c.x - g.minX, y: c.y - g.minY),
                              anchor: petAnchor.map { OrbQuickMenuAnchor.pet(size: $0.size) } ?? .dockOrb,
                              thinking: thinking,
                              unseen: unseen,
                              failed: failed,
                              onAction: onAction, onClose: onClose)
        }
    }
}

// MARK: - v3.9.60 落点几何（纯函数，供真值表复用）
//
// 为什么改：v3.9.59 的「角度散开」在真机上四颗胶囊压在一起（用户实测报「弹出位置有重叠」）。
// 根因是**几何不够用**，不是动画问题：
//   · 内侧两颗 ±19°、r=116 → 中心距 = 2·sin19°·116 ≈ **75.5pt**，而单颗胶囊宽约 **101pt**
//     （水平内边距 2×(Spacing.xl+2)=28 + 图标 13pt SF≈15 + HStack 间距 Spacing.sm=6 + 中文 4 字×13pt=52）
//     → 中间两颗横向重叠约 **25pt**，右侧那颗直接盖在左侧那颗上；
//   · 外侧 ±57° 与内侧 ±19° 的纵向差只有 cos19°·116 − cos57°·136 ≈ **35.7pt**，而胶囊高约 **36pt**
//     （垂直内边距 2×Spacing.lg=20 + 13pt 行高≈15.5）→ 上下两颗贴合/微蹭。
//   · 393pt 屏宽下放 4 颗 101pt 宽的胶囊，靠「同弧散开」永远排不下（要内侧间距 ≥127pt 得把半径推到
//     ~195pt，外侧就会飞出屏幕）——所以落点改成**保持原「上下两排」观感、把间距拉开**，动画不动。
//
// 落点（以球心为原点）：
//   v3.9.76：两排各 3 颗（index 0 下左 · 1 下中 · 2 下右 · 3 上左 · 4 上中 · 5 上右）
//            同排中心距 236pt（101 + 17 间隙）；两排纵向差 56pt（36 + 20 间隙）
//   v4.0.x ：6 颗 → 8 颗（方案 A）—— **上面 6 颗一颗不动**，只在更上方加第三排：
//            index 6/7 = 最上排，2 颗**居中**（列 ∓0.5 → x = 球心 ∓59，两颗中心距 = 118pt）
//            三排 dy = 104 / 160 / 216，行间隙恒 20pt（36 + 20 = 56 步进）
enum OrbQuickMenuLayout {
    /// 胶囊尺寸估值（本机无 Xcode SDK 渲染不出，按令牌算式推；真机不齐只改这一处）
    static let pillSize = CGSize(width: 101, height: 36)
    /// 同排半间距（中心距 = 2×118 = 236；v3.9.76 一排 2 颗 → 3 颗，同步放宽）
    /// v4.0.x：最上排那 2 颗也吃这一个常量（列取 ∓0.5 → 中心距 = 118），不为它新起一个数字。
    static let columnDX: CGFloat = 118
    /// 中排抬升（= v3.9.76 的「上排」，8 颗后位置一颗未动）、下排抬升
    static let upperDY: CGFloat = 160
    static let lowerDY: CGFloat = 104
    /// v4.0.x 方案 A：最上排抬升 = upperDY 160 + 行间隙 20 + 胶囊高 36 = **216**
    static let topDY: CGFloat = 216
    /// 胶囊底到球心的最小间距（球半径约 34pt + 呼吸 40pt）
    static let minGapAboveBall: CGFloat = 74

    /// 单颗胶囊的中心点。取模防越界（胶囊数量再变也不崩）。
    ///
    /// v3.9.76 排列 = **两排各 3 颗**：index 0/1/2 = 下排左/中/右，3/4/5 = 中排左/中/右。
    /// v4.0.x 方案 A = **三排 2/3/3**（用户拍板对比稿 /opt/data/scripts/ql_orbmenu/mock/eight_pills_compare.png）：
    ///   index 6/7 = 最上排 2 颗、**居中**（列 ∓0.5 → x = 球心 ∓59 = columnDX/2）。
    ///   前 6 颗的落点与 v3.9.76 **逐点相同**（老用户的手感不因扩到 8 颗而变）。
    /// 几何校验（最窄 375pt 屏也成立，球心 x = 187.5；pillW/H = 101/36）：
    ///   · 同排相邻间隙 = columnDX − pillW = 118 − 101 = **17pt** ≥ 12（不糊成一团）
    ///     （236 是**外沿两颗**的中心距，不是相邻间隙——v3.9.76 审查纠正；三颗总宽 337pt，
    ///      375pt 小屏最左仍留 19pt）
    ///   · 排间纵向间隙 = 160 − 104 − 36 = **20pt**；最上排 = 216 − 160 − 36 = **20pt** ≥ 12
    ///   · 最左胶囊左缘（下/中排）= 187.5 − 118 − 50.5 = **19pt** ≥ 8（不越界）
    ///   · 最上排 2 颗：中心距 = 2×59 = **118pt**（= columnDX），间隙 **17pt**；
    ///     最左胶囊左缘 = 187.5 − 59 − 50.5 = **78pt**（比那两排更靠内 → 更不可能越界）
    ///   · 下排胶囊底到球心 = 104 − 18 = **86pt** ≥ minGapAboveBall 74（仍留呼吸）
    ///   · 撞灵动岛/状态栏（向上绽放，最高那颗 = index 6/7）：顶边 = 球心 y − 216 − 18
    ///       · 375×667：球心 y = 667 − 34 − 24.5 = 608.5 → 顶边 **374.5pt**，
    ///         距状态栏下沿（20pt）**354.5pt**、距屏顶 374.5pt（隔着大半个屏，摸不到）
    ///       · 393×852 + 灵动岛（下沿 59pt）：球心 y = 852 − 34 − 24.5 = 793.5 → 顶边 **559.5pt**，
    ///         距灵动岛下沿 **500.5pt**
    /// v3.9.80：`below` = 整组镜像到**锚点下方**（锚点是欢迎页/聊天页宠物时用）。
    ///
    /// 为什么分方向：dock 智慧球贴在屏幕底部 → 八颗胶囊必须向上绽放（原口径，不动）；
    /// 而欢迎页宠物在上半屏，一律向上会让远排钻进状态栏/灵动岛、近排压在宠物脸上
    /// （用户 2026-09-25 截图：「这个界面胶囊弹出放在卡通宠物下方」）。
    /// 镜像后 index 0-2 仍是「离锚点更近的那一排」，观感只翻方向、不改排布。
    /// v4.0.x 下锚（宠物）方向校验：宠物球心 y = 59 + 120 + 48 = 227（933 高屏更靠下，表里按 852 算）
    ///   · 最远排（index 6/7）底边 = 227 + 216 + 18 = **461pt** ≤ 输入栏顶 698pt（852 − 34 − 120）
    ///   · 离状态栏最近的是近排（index 0-2）：顶边 = 227 + 104 − 18 = **313pt**，
    ///     距灵动岛下沿（59pt）**254pt** —— 两个方向都不进状态栏。
    static func center(index: Int, ballCenter: CGPoint, below: Bool = false) -> CGPoint {
        let i = ((index % 8) + 8) % 8
        // v4.0.x 方案 A：i ≥ 6 = 最上排 2 颗**居中**（列 ∓0.5）；前 6 颗仍是每排 3 列（∓1 / 0）
        let isTopRow = i >= 6
        let col: CGFloat = isTopRow ? (i == 6 ? -0.5 : 0.5) : CGFloat(i % 3) - 1
        let dy = isTopRow ? topDY : (i >= 3 ? upperDY : lowerDY)
        return CGPoint(x: ballCenter.x + col * columnDX,
                       y: below ? ballCenter.y + dy : ballCenter.y - dy)
    }
}

// MARK: - 菜单层（轻纱 + 光晕 + 三排胶囊）

struct OrbQuickMenuLayer: View {
    let ballCenter: CGPoint
    /// v3.9.78：锚点画什么（dock 智慧球 / 聊天页宠物）—— 只换「轻纱之上重画的那个东西」，
    /// 轻纱/光晕/胶囊落点与动画全部共用（几何仍以 ballCenter 为原点，与用户看到的锚点在同一点）
    var anchor: OrbQuickMenuAnchor = .dockOrb
    /// v3.9.78：锚点球的状态（与 dock 那颗同源传进来）
    var thinking: Bool = false
    var unseen: Bool = false
    var failed: Bool = false
    var onAction: (OrbQuickAction) -> Void
    var onClose: () -> Void

    @State private var shown = false
    /// v3.9.76（用户实测）：「点击胶囊有时候要点击好几次才跳转」。
    /// 一旦有一次点击真的被识别，就锁死——否则连点会起多个 0.16s 延迟任务，
    /// 动作互相打断（弹两次 sheet / 切两次页），观感就是"点了没反应"。
    @State private var activated = false
    @Environment(\.colorScheme) private var scheme
    /// v3.9.59：减弱动态效果（系统辅助功能）——弹簧散射/位移会加重不适感，退化为「原地淡入」。
    /// 全仓口径一致：LoginView、欢迎页宠物（PetAvatar）都读同一环境值，本层别自己发明开关。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 单颗胶囊入场动画：正常运行按 index 错峰 50ms；减弱动态效果下退化为瞬时节奏（只留透明度过渡）
    private func pillAnimation(index: Int) -> Animation {
        reduceMotion ? Motion.tap
                     : .spring(response: 0.45, dampingFraction: 0.68).delay(Double(index) * 0.05)
    }

    var body: some View {
        ZStack {
            // 🚨 v3.9.77：**全屏半透明模糊**遮罩（用户：「这个背景上下白，中间灰，改全半模糊效果」）。
            // 两个真因都在原来这一层：
            //   ① `Color.black.opacity(0.12)` **没铺安全区** → 上下露出原页面（观感「上下白」），
            //      中间只剩一条 12% 黑纱（观感「中间灰」）；
            //   ② 纯色遮罩**不带背景模糊**（原注释写的就是「不做全屏磨砂，方案 C 只取光晕」——本轮用户推翻）。
            // 现在 = 整屏材质模糊（`.ultraThinMaterial` 自带背后内容模糊，深浅色自动适配）+ 一层极淡压暗提对比。
            // ⚠️ `.ignoresSafeArea()` 必须留：去掉就回到「上下白、中间灰」那条带。
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.10)      // 压暗一档，让胶囊与文字在模糊底上更立得住
            }
            .ignoresSafeArea()
            .opacity(shown ? 1 : 0)            // 与菜单同节奏淡入淡出（沿用 shown，不新增状态源）
            .contentShape(Rectangle())
            .onTapGesture(perform: dismissAnimated)

            halo

            anchorObject

            ForEach(Array(OrbQuickAction.all.enumerated()), id: \.element.id) { idx, action in
                orbPill(action, index: idx)
            }
        }
        .onAppear {
            if reduceMotion { shown = true }   // 减弱动态效果：不做弹簧入场，直接落位淡入
            else { withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { shown = true } }
        }
    }

    /// C 元素：球心光晕——常驻柔光 + 一圈扩散环
    private var halo: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.blue.opacity(0.32), Color.clear],
                                     center: .center, startRadius: 0, endRadius: 95))
                .frame(width: 190, height: 190)
                .scaleEffect(shown ? 1 : 0.2)
                .opacity(shown ? 1 : 0)
            // 扩散环是纯装饰动效 → 减弱动态效果下整环不渲染（省电也省心）
            if !reduceMotion {
                Circle()
                    .stroke(Color.blue.opacity(shown ? 0 : 0.5), lineWidth: 2)
                    .frame(width: 70, height: 70)
                    .scaleEffect(shown ? 3.4 : 0.6)
            }
        }
        .position(ballCenter)
        .allowsHitTesting(false)
    }

    /// 锚点形象（v3.9.78 用户：「这个界面需要把底部的智慧球显示出来」；v3.9.82 改成**只画宠物**）
    ///
    /// 为什么要在菜单层重画一个：遮罩改成整屏 `.ultraThinMaterial` 后，锚点被压在
    /// **磨砂层下面**（dock 那条整条一起糊掉，球只剩一团浅蓝光斑）。而八颗胶囊恰恰是**从锚点
    /// 弹射**出来的——锚点看不见，绽放就没了起点，观感上像凭空冒出来的。
    ///
    /// 🚨 v3.9.82 口径（用户 2026-09-27：「长按智慧球跳转画面改为长按卡通宠物跳转画面，
    ///    只保留一个跳转画面」）：**球版画法整段删掉**，不管从 dock 智慧球还是聊天页宠物进来，
    ///    这里画的一律是 `PetAvatar`（宠物那套）。别再按锚点类型分两种画法——「长按球弹出一颗球、
    ///    长按宠物弹出一只宠物」就是用户要去掉的那两套画面。
    ///    中心仍严格同源：`ballCenter`（= `DockOrbOverlay.orbCenterGlobal`，菜单/命中层/可见球共用）；
    ///    状态直传 thinking（流式时表情跟着变）。
    /// 它盖在材质**之上**，所以背后那块糊掉的只是同一位置的重影，不会看出两层。
    ///
    /// ⚠️ 不吃事件：`allowsHitTesting(false)` 后点它 = 点空白 = 收起菜单（与轻纱同语义），
    ///    别给它挂手势 —— 菜单层是模态的，多一个命中面就多一处抢触摸的雷。
    /// 尺寸按**位置**走，不按入口改画法（v3.9.82）：dock 槽位沿用那颗球的口径
    /// `DockOrbOverlay.defaultBallSize`（单一真源，改尺寸与 dock 一起变）—— 这里换成 96 的宠物
    /// 会盖住两侧 tab 图标；聊天页/欢迎页宠物用它自己的尺寸（96）。
    private var anchorSize: CGFloat {
        if case .pet(let size) = anchor { return size }
        return DockOrbOverlay.defaultBallSize
    }

    /// 唯一一种画法：宠物（球版分支已删，见上面的口径注释）
    @ViewBuilder
    private var anchorObject: some View {
        PetAvatar(size: anchorSize, state: thinking ? .thinking : .idle)
            .frame(width: anchorSize, height: anchorSize)
            .position(ballCenter)
            .opacity(shown ? 1 : 0)          // 与轻纱同节奏淡入（onAppear 的 withAnimation 一并驱动）
            .allowsHitTesting(false)
    }

    /// 胶囊相对锚点的落点（两排各三颗，几何见 OrbQuickMenuLayout）
    ///
    /// v3.9.80：dock 智慧球贴屏底 → **向上**绽放（原口径）；欢迎页/聊天页宠物在上半屏 →
    /// 整组落在**宠物下方**（用户 2026-09-25 截图口径：「这个界面胶囊弹出放在卡通宠物下方」）。
    ///
    /// 🚨 v3.9.82：方向判据从「锚点**类型**」改成「锚点在屏幕上的**高度**」—— 画法统一成宠物后，
    ///    类型不再区分方向：锚点在下半屏（dock 那颗，球心 y≈800 / 屏高 852）必须**朝上**，
    ///    否则整排胶囊落到屏幕外、看得见点不到；锚点在上半屏（聊天页/欢迎页宠物）朝下。
    ///    方向只在这一处判定，几何仍走单一真源；高度真值走 `DockOrbOverlay.keyWindowHeight`
    ///    （与球定位同一处真源，不另取 UIScreen，避免两处口径打架）。
    private var pillsBelow: Bool {
        ballCenter.y < DockOrbOverlay.keyWindowHeight * 0.5
    }

    private func pillOffset(index: Int) -> CGPoint {
        OrbQuickMenuLayout.center(index: index, ballCenter: ballCenter, below: pillsBelow)
    }

    private func orbPill(_ action: OrbQuickAction, index: Int) -> some View {
        let p = pillOffset(index: index)
        // 🚨 v3.9.76 修复「点击胶囊有时候要点击好几次才跳转」：视觉层与**命中层必须分开**。
        // 原来 onTapGesture 挂在与位移动画同一个视图上 —— 入场弹簧还在飞（错峰后约 0.6s 才落定）时，
        // SwiftUI 的命中测试跟着布局动画走，用户点到的是"途中的位置"：前几次点击必然落空
        //（点空落在轻纱上还会顺手把菜单收起）。现在视觉层 allowsHitTesting(false)，
        // 命中交给一个**位置固定在终态、完全不参与动画**的透明层 —— 长按一弹出来就能点中。
        // 代价（有意取舍）：入场动画那零点几秒里，胶囊没有 glassEffect 的按下形变反馈（透明层收不到玻璃手势）；
        // 点击后 0.16s 就跳转，反馈感来自目标页面本身。
        // 顺带绕开第二个隐患：.glassEffect(.regular.interactive()) 自带交互识别器，
        // 与 onTapGesture 挂同一视图时也可能吃掉第一次点击。
        return ZStack {
            pillVisual(action, index: index, center: p)
            pillHitArea(action, center: p)
        }
    }

    /// 视觉层：参与入场动画（从球心弹射落位 + 缩放淡入），**不挂点击手势、不吃事件**
    private func pillVisual(_ action: OrbQuickAction, index: Int, center p: CGPoint) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: action.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(action.color)
            Text(action.title)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.primary)
                // v3.9.77 复审修：视觉层钉了固定宽度（pillSize.width = 101，是按令牌算式**估**的，
                // 图标 advance 有波动）→ 给文字一个软兜底：宁可略缩，也别被固定宽压成省略号。
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        // 🚨 v3.9.77 用户：「这个截图的 6 个胶囊也大小统一一下」。
        // 原来视觉层**没有固定宽度** —— 宽度随「图标 + 文字 + padding」自适应，而六颗图标各不同
        // （plus.bubble.fill / brain.head.profile / checklist / text.viewfinder / waveform.circle.fill / mic.fill），
        // 各自的 natural width 不一样 → 六颗宽度各不相同。命中层早就在用统一的 `pillSize`，两边一直不一致。
        // 现在视觉层钉到同一个 `pillSize.width`，与命中层、与 OrbQuickMenuLayout 的几何算式**三处同源**。
        // ⚠️ 水平 padding 同步由 14（`Spacing.xl + 2`）收到 12（`Spacing.xl`）：给「统一宽度」腾空间。
        //    实测令牌真值（Spacing.swift）：xl=12 / lg=10 / md=8 —— 复核时别按记忆当 md=12。
        //    最长内容「新建会话」= 图标≈15 + 间距 6 + 四字 52 + padding 12×2 = 97pt ≤ 101，留 4pt 余量。
        //    **别把 padding 加回去**（14 时 = 101pt 顶满、再宽一点就会被固定宽度挤压截字）。
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
        .frame(width: OrbQuickMenuLayout.pillSize.width)
        // 玻璃挂在 padding 之后（dock pill 同口径）；胶囊本身就是 Capsule，glassEffect 默认形状正合适。
        // v3.9.59：可点元素必须走 .regular.interactive()（Pill.swift 定版）——裸 glassEffect 是静态卡口径，
        // 按下去没有玻璃反馈，与同屏 dock 胶囊观感不一致。
        .glassEffect(.regular.interactive())
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(scheme == .dark ? 0.22 : 0.12), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
        // 减弱动态效果：不做「从球心弹射落位」，原地淡入（位置/缩放都取终态）
        .scaleEffect(reduceMotion ? 1 : (shown ? 1 : 0.3))
        .opacity(shown ? 1 : 0)
        .position(reduceMotion ? p : (shown ? p : ballCenter))
        // 错峰绽放：按 index 延迟 50ms（0 下左 → 1 上左 → 2 上右 → 3 下右，落点见 OrbQuickMenuLayout）；
        // reduceMotion 下走 pillAnimation 的退化分支
        .animation(pillAnimation(index: index), value: shown)
        .allowsHitTesting(false)   // 🚨 v3.9.76：视觉层不许吃事件（命中全交给下面的固定层）
    }

    /// 命中层（v3.9.76）：**位置固定在终态、不参与任何位移动画** + 首次点击即锁定
    private func pillHitArea(_ action: OrbQuickAction, center p: CGPoint) -> some View {
        Color.clear
            .frame(width: OrbQuickMenuLayout.pillSize.width,
                   height: OrbQuickMenuLayout.pillSize.height)
            .contentShape(Rectangle())
            .position(p)
            .onTapGesture {
                guard !activated else { return }   // 防连点：动作只执行一次
                activated = true
                Haptics.tap()
                dismissAnimated()
                // 先播收场动画（0.16s）再执行动作，切页/弹窗不抢动画帧
                Task { try? await Task.sleep(for: .seconds(0.16)); onAction(action) }
            }
            // v3.9.59：无障碍——自定义手势视图默认既读不到也点不动，合成一个元素 + 按钮 trait（双击即触发）
            .accessibilityElement(children: .combine)
            .accessibilityLabel(action.title)
            .accessibilityAddTraits(.isButton)
    }

    private func dismissAnimated() {
        withAnimation(Motion.snap) { shown = false }
        Task { try? await Task.sleep(for: .seconds(0.16)); onClose() }
    }
}

// MARK: - 快记弹窗（AI 速记 → 备忘录 / 今日待办 → 待办清单）

enum QuickCaptureMode: String, Identifiable {
    case memo, todo

    var id: String { rawValue }
    var title: String { self == .memo ? "AI 速记" : "记待办" }
    var placeholder: String { self == .memo ? "想到什么记什么…" : "要做的什么事…" }
}

struct QuickCaptureSheet: View {
    let mode: QuickCaptureMode
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: mode == .memo ? "brain.head.profile" : "checklist")
                    .foregroundStyle(mode == .memo ? Color.purple : Color.orange)
                Text(mode.title)
                    .font(.system(size: Typography.headline, weight: .bold))
            }
            TextField(mode.placeholder, text: $text, axis: .vertical)
                .lineLimit(1...4)
                .padding(Spacing.xl)
                // v3.9.78（用户「同口径也推到其它弹窗」）：输入卡也走浮层玻璃口径 —— 原来是 `.quaternary`
                // 实灰底 + `Radius.field`(14)，在系统毛玻璃弹窗底上是一块「实心灰板」。
                // 圆角取 `Radius.card`(16) 而不是卡片那档 `Radius.hero`(22)：这是高约 66pt 的多行输入框，
                // 22 会接近胶囊形；要跟卡片完全一样圆，改这一个参数即可。
                .overlayGlassCard(cornerRadius: Radius.card)
            // 用户反馈「输入框上移让观感更协调」：原来整个内容块在 detent 里垂直居中，
            // 输入框悬在卡片正中、与标题脱节（标题上方留白按算式约 175pt，见下）。
            // 改为全站输入弹窗同口径——输入区贴顶、操作区沉底（MemoSection addSheet /
            // QuickReminderSheet 都是内容撑满 detent），输入框紧跟标题，按钮留在卡片底部。
            Spacer()
            HStack(spacing: Spacing.lg) {
                Spacer()
                Button("取消") { dismiss() }
                    .foregroundStyle(.secondary)
                Button { save() } label: {
                    // v3.9.59：主操作胶囊走全站统一出口（Pill.swift：accent 底 = 原生液态玻璃）
                    Text("保存").pill(.primary, tone: .accent)
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        // 输入框上移的几何算式（393pt 宽 / medium detent）：
        //   旧：内容高 ≈ 标题 30 + 间距 10 + 输入框 66 + 10 + 按钮 34 = 150pt，
        //       detent 可用 ≈ 524pt → 垂直居中后输入框中心落在距卡顶 ≈ 235pt（卡片正中）；
        //   新：输入框中心 = padding 16 + 标题 30 + 间距 10 + 33 ≈ 距卡顶 89pt（上移约 146pt）。
        // 大 detent 下同样成立（内容撑满即可，Spacer 自动压缩到 0 不会溢出）。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(Spacing.section)
        // v3.9.59：与全站输入弹窗同档（MemoSection / TodoSection / QuickReminderSheet 都是 medium + large）
        .presentationDetents([.medium, .large])
        // 弹窗背景不覆盖：交给 iOS 26 系统默认玻璃底（全站口径）
    }

    private func save() {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        switch mode {
        case .memo: _ = MemoStore.shared.add(content: content, source: "orb")
        case .todo: _ = TodoStore.shared.add(content: content, source: "orb")
        }
        Haptics.success()
        dismiss()
    }
}
