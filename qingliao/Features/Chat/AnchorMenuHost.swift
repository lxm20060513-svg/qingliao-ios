import SwiftUI

// MARK: - v4.0.105 锚定长按菜单的**全局宿主**（用户口径：覆盖到 app 全局相同行为）

/// 全局锚定菜单宿主（单例）。
///
/// 用户口径（2026-10-13）：「长按出**胶囊式菜单**、背景**模糊变暗**，并覆盖到 app 全局相同行为」。
/// ⚠️ 同轮里那句「长按内容先把所选内容微缩再抬起」**已被用户装包真机推翻**（v4.0.106：
/// 「这不是我想要的效果，还是把背景模糊化，只保留胶囊菜单」）—— 内容现在**原位不动**，
/// 不再有抬起预览（`AnchorMenuOverlay` 的 `preview:` 形参已整体删除，别再加回来）。
/// 演出本身在 `AnchorMenuOverlay`，本文件负责**把长按入口统一收成一条出口**。
///
/// 🚨 为什么必须是「单例 + 根视图渲染」，而不是行内 `.overlay`：
///   浮层要铺在**整屏**上 —— ① 要判「内容下方放不放得下」（否则菜单会被顶到屏幕外）；
///   ② 要盖住底部 dock / 输入栏。行内视图自己 `.overlay` 的话容器就是那一行，高度不足以判落点、
///   也盖不住别处。所以行内只做两件事：**量自己的全局 rect** + **长按 → present**。
///
/// 🚨 为什么宿主层要「最内层优先」注册（v4.0.105 实抓）：**sheet 是独立呈现层**，根视图的浮层
///   （zIndex 4）画不到 sheet 内容之上 —— sheet 里挂 `.anchorLongPressMenu` 的行会表现为「长按没反应」。
///   故 sheet 根也要挂一层宿主（见 `anchorMenuHost()`），且**只有最内层那一层负责渲染**，否则同一请求
///   会被根层与 sheet 层各画一份。注册顺序天然满足：根层先挂、sheet 后挂。
///
/// 与既有页面级调用点（27 处，各页自持 `@State` + 自渲染）的关系：那些是历史写法，行为不变（同一个
/// `AnchorMenuOverlay` 组件）；**新写入的长按入口一律走本宿主**（一行接入，见 `anchorLongPressMenu`）。
@MainActor
final class AnchorMenuPresenter: ObservableObject {
    static let shared = AnchorMenuPresenter()

    /// 一次呈现请求（锚点全局 rect + 项 + 文案 + 选中回调）
    struct Request: Identifiable {
        let id = UUID()
        /// 锚点在**全局坐标系**的矩形（触发行的 frame）
        let anchor: CGRect
        let items: [AnchorMenuItem]
        var title: String = ""
        var message: String = ""
        let onPick: (AnchorMenuItem) -> Void
    }

    @Published var request: Request?

    /// 已挂载的宿主层（后注册 = 更内层 = 负责渲染）
    @Published private(set) var hosts: [UUID] = []

    /// 当前负责渲染的宿主层（nil = 还没有任何宿主挂载）
    var activeHost: UUID? { hosts.last }

    private init() {}   // 单例：全局只允许一条出口

    func present(_ req: Request) { request = req }
    func dismiss() { request = nil }

    /// 长按刚出过菜单的抑制窗口（用户 2026-10-14 真机报「长期目标任务卡片无法编辑」那批）。
    /// 根因：目标卡本体就是个 `Button`（`GoalProgressCard` 内部、展开区行卡同样是 Button），
    /// 挂在它**外层**的长按手势被 Button 内置手势吃掉 ⇒ 长按毫无反应，编译/预检全绿、只有手指能发现。
    /// 修法：手势升为 `.highPriorityGesture`（长按赢过 Button 的 tap）。代价是松手那一瞬 Button
    /// 仍可能补送一次轻点 ⇒「菜单刚弹出、详情/展开也顺手打开」把菜单顶掉。故出菜单时打一个短窗口，
    /// 由被长按的卡片在自己的 tap **首行**读 `shouldDropTap()` 丢弃。
    private(set) var suppressTapUntil: Date = .distantPast
    func markLongPressFired() { suppressTapUntil = Date().addingTimeInterval(0.5) }
    /// v4.0.112（审查收口）：**一次性消费** —— 命中即复位。
    /// 原实现是全局 0.5s 窗口且读不清除：A 卡长按出菜单后 0.5s 内去点 B 卡会被静默吞掉
    ///（「长按一张卡 → 紧接着点另一张」是极常见动作）。窗口本意只是吃掉**长按那一拍补送的 tap**，
    /// 消费掉就该失效。
    func shouldDropTap() -> Bool {
        guard Date() < suppressTapUntil else { return false }
        suppressTapUntil = .distantPast
        return true
    }

    func mount(_ token: UUID) {
        guard !hosts.contains(token) else { return }
        hosts.append(token)
    }

    /// 卸载（sheet 关掉时）：若它正持有请求，连请求一起收掉，避免菜单留在已消失的层里
    func unmount(_ token: UUID) {
        let wasActive = (activeHost == token)
        hosts.removeAll { $0 == token }
        if wasActive { request = nil }
    }
}

/// 一行式长按菜单修饰器。
///
/// 挂在任意行 / 卡片上即可获得与聊天页气泡**同款**的「微缩 → 抬起 → 轻纱模糊变暗 → 弹簧胶囊菜单」
/// （抬起预览 = 该视图自身，不挂量测 / 手势钩子，故不会二次量测、也不抢按）。
struct AnchorLongPressMenuModifier: ViewModifier {
    let items: [AnchorMenuItem]
    var title: String = ""
    var message: String = ""
    let onPick: (AnchorMenuItem) -> Void

    /// 本行最近一次的全局 rect。**存本地 @State 而不是全局 store**：行级量测滚动时每帧都刷，
    /// 写全局 store 会让整页 body 反复失效（v3.9.x 同源教训，见 ChatView 的 ChatBubbleAnchorStore 注释）。
    @State private var rect: CGRect = .zero

    /// 长按最短时长：0.42s（**与聊天页气泡已无耦合** —— v4.0.168 起聊天页走系统 `.contextMenu`，
    /// 这里只是本组件的自有手感；全 app 各入口观感一致仍是目标）
    /// （用户口径「覆盖到 app 全局相同行为」，手感也在其中；系统 `.contextMenu` 约 0.42~0.5s）。
    private let minimumDuration: Double = 0.42

    /// 手指可漂移上限 22pt：**离手超过就不算长按**。这条不是凑数 —— 它是「长按菜单」与
    /// 「长按拖动」（看板卡片 `boardDragGesture`）/ 滚动 能共存的关键：按住不动 → 出菜单；
    /// 按住就拖 → 距离一超过 22 手势自行取消，拖动照旧。缺了它会把拖动吃掉。
    private let maximumDistance: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect = $0 }
            // 🚨 必须是 `.highPriorityGesture`，**不得退回 `.onLongPressGesture`**：
            //    后者等价 `.gesture(...)` = 普通优先级，挂在 Button（长期目标卡 / 展开区行卡 /
            //    待办行…）外层时会被 Button 内置手势整个吃掉 —— 长按全无反应，而编译、预检、
            //    文档全绿，只有真机手指能发现（2026-10-14 用户报「长期目标任务卡片无法编辑」，
            //    追问后答「长按卡片根本不出菜单」＝ 就是这条）。高优先级长按识别后 Button 的 tap
            //    不再触发；轻点（<0.42s）时长按自行失败，Button 照常工作。
            .highPriorityGesture(
                LongPressGesture(minimumDuration: minimumDuration, maximumDistance: maximumDistance)
                    .onEnded { _ in
                        // items 为空不弹（宁缺勿滥）：有些行是按状态动态给项的
                        guard !items.isEmpty else { return }
                        Haptics.tap()   // 触感补齐（与聊天页长按 / 系统菜单同款）
                        AnchorMenuPresenter.shared.markLongPressFired()
                        AnchorMenuPresenter.shared.present(
                            .init(anchor: rect,
                                  items: items,
                                  title: title,
                                  message: message,
                                  onPick: onPick)
                        )
                    }
            )
    }
}

extension View {
    /// **一行式长按菜单**（全局同款演出）。取代系统 `.contextMenu`：
    /// ```swift
    /// .anchorLongPressMenu(items: todoCardMenuList(t), title: "待办") { item in
    ///     switch item.id { ... }
    /// }
    /// ```
    /// - Important: 实参序 = 声明序：`items:title:message:onPick:`（swiftui-param-order 铁律）。
    /// - Note: 项要**逐条列全**（标题 / 图标 / destructive / disabled 语义等价于原来的 `Button`），
    ///   因为胶囊菜单不像系统菜单那样接管 Button 语义 —— 换成同名同图标的项，动作仍由 onPick 分发。
    func anchorLongPressMenu(items: [AnchorMenuItem],
                             title: String = "",
                             message: String = "",
                             onPick: @escaping (AnchorMenuItem) -> Void) -> some View {
        modifier(AnchorLongPressMenuModifier(items: items,
                                             title: title,
                                             message: message,
                                             onPick: onPick))
    }

    /// 在当前呈现层里挂一层锚定菜单落点。
    ///
    /// - 根视图（`RootView` 的 ZStack，zIndex 4）已挂一层，覆盖**普通页面**上的所有站点。
    /// - **sheet 内**有 `.anchorLongPressMenu` 站点时必须再挂一层（sheet 之上的浮层，根层画不到）：
    ///   在呈现点写 `TasksView().anchorMenuHost()` 即可。
    /// - 多层同时挂载时**只有最内层渲染**（sheet 挂载晚 → 天然更内层），不会重复画。
    func anchorMenuHost() -> some View {
        overlay { AnchorMenuHostLayer() }
    }
}

/// 锚定菜单的渲染落点：挂在根视图与「内有长按站点的 sheet」上；**只由最内层那一层负责画**。
/// （zIndex 由根视图处给：压在页面之上、App 锁/启动动画之下。）
struct AnchorMenuHostLayer: View {
    @ObservedObject private var presenter = AnchorMenuPresenter.shared
    /// 本层身份（用于「最内层优先」判定；同一层多次 body 求值保持不变）
    @State private var token = UUID()

    var body: some View {
        ZStack {
            if presenter.activeHost == token, let req = presenter.request {
                AnchorMenuOverlay(anchorFrame: req.anchor,
                                  items: req.items,
                                  title: req.title,
                                  message: req.message,
                                  onPick: { item in
                                      // 先收浮层再派发动作：动作里可能再开别的浮层/弹窗（同聊天页口径）
                                      presenter.dismiss()
                                      req.onPick(item)
                                  },
                                  onClose: { presenter.dismiss() })
            }
        }
        .onAppear { presenter.mount(token) }
        .onDisappear { presenter.unmount(token) }
    }
}
