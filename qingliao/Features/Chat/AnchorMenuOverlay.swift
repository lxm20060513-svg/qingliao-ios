//
//  AnchorMenuOverlay.swift
//  v4.0.76：锚定弹出菜单（用户 2026-10-07：「三点菜单点击应该从三点菜单处弹出，按空白收回，
//  而不是从中间弹出」）—— 替代 confirmationDialog 的「操作菜单」场景（删除确认等仍走系统 alert）。
//
//  🚨 v4.0.77（用户实报「4.0.76 全是问题」）两处收口，全仓四个调用点共用本组件 → 改这里即全对齐：
//   ① **每一项 = 一颗玻璃胶囊**（与 OrbQuickMenu 同款：Capsule + a11yGlass(.regular.interactive())
//      + 统一宽度 + 彩色 SF Symbol），菜单本体不再是「一块大圆角面板 + 行分隔」。
//      用户口径：「弹出菜单样式还是采用上一版的胶囊样式，所有的都是用回胶囊样式，同步检查所有的，都要对齐」。
//      宽度统一（按最长标题估一次，全体同宽）＝ 视觉上的「对齐」；不再逐行自适应宽窄不一。
//   ② **浮层必须挂页面根**：4.0.76 把浮层挂在 chatHeaderBar 上，而 header 是 VStack 第一行，
//      `.overlay` 的层序落在同级兄弟（消息列表 / 输入栏）之下 → 菜单被压在聊天内容页下面
//      （用户实报「三点菜单弹出落到聊天内容页下面去了」）。调用点一律挂到该页最外层 chrome。
//
//  🚨 v4.0.106（用户装包真机拍板）：**v4.0.105 的「抬起预览」整体移除** ——
//  原文：「这不是我想要的效果，还是把背景模糊化，只保留胶囊菜单」。
//  长按后内容原位不动，只留整屏轻纱（`.ultraThinMaterial` + 压暗）+ 胶囊菜单。
//  别再给本组件加 `preview:` 形参或微缩/抬起/投影演出。
//

import SwiftUI

/// 一项菜单动作（图标 + 标题 + 语义色；role 决定删除类的红字红图标）
struct AnchorMenuItem: Identifiable {
    let id: String
    let title: String
    var icon: String = ""
    var color: Color = .primary
    var destructive: Bool = false
    var disabled: Bool = false
}

/// 锚定弹出菜单浮层。几何：锚点矩形（全局坐标）由触发方用 onGeometryChange 量好传进来。
struct AnchorMenuOverlay: View {
    /// 锚点在**全局坐标系**的矩形（触发按钮的 frame）
    let anchorFrame: CGRect
    let items: [AnchorMenuItem]
    var title: String = ""
    /// v4.0.102：可选**说明文字**（多行 caption，渲染在标题下方）。
    /// 由来：危险动作确认（布防/撤防、执行危险场景、重置用量）原走系统 confirmationDialog 的
    /// `message:` 承载「明示后果」；改用锚定浮层后这段说明同样必须在场，所以给浮层补这一档。
    /// 默认空串 —— 现有调用点（聊天页三点菜单/思考档位/长按气泡、任务中心行菜单、看板恢复菜单）观感零变化。
    /// ⚠️ 实参序 = 声明序：新调用点写 (anchorFrame:items:title:message:onPick:onClose:)。
    var message: String = ""
    var onPick: (AnchorMenuItem) -> Void
    var onClose: () -> Void

    /// 🚨 v4.0.106：v4.0.105 的「抬起预览」（`preview: AnyView?` 形参 + 微缩/抬起/投影演出）
    /// **整体移除** —— 用户装包真机看到后拍板：「这不是我想要的效果，还是把背景模糊化，只保留胶囊菜单」。
    /// 现行口径（不要再加回来）：长按后内容**原位不动**，只留整屏轻纱（模糊 + 压暗）+ 胶囊菜单；
    /// 没有微缩、没有抬起、没有投影、没有菜单落位延后。
    /// 连带移除：`ChatView.bubbleLiftPreview` / `ChatBubbleMenuTarget.preview` /
    /// `AnchorMenuPresenter.Request.preview` / `Motion.menuLift·pressDown·pressScale·liftScale·liftRise`。

    /// v4.0.157：面板（含每颗胶囊）的**透明度相位**
    @State private var shown = false
    /// v4.0.157：整屏轻纱的独立相位（只透明度、短促淡入；不与面板同一条弹簧）
    @State private var scrimOn = false
    /// v4.0.157：胶囊的**入场**相位（只置 true、逐颗错峰；v4.0.158 起 30ms）。
    /// 与 `shown` 分开的理由：退场必须快且齐 —— 每颗胶囊若挂着自己的 0.38s+错峰 spring，
    /// 父层 0.18s 就卸载 → 淡到一半整块消失。现在退场只走面板 `shown` 的一次淡出。
    @State private var reveal = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 胶囊几何（v4.0.77：与 OrbQuickMenu 同一口径 —— 胶囊 + 玻璃 + 统一宽度）
    /// 高度 = 上下留白 Spacing.xl(12 ×2) + 文字行高(≈18) ≈ 42
    /// v4.0.105：36 → 42（用户口径「方案A，同时胶囊大一号」，字号同步 subhead 13 → body 15）。
    /// ⚠️ 本组件被全仓 27 个调用点共用 —— 改这一处即全体同宽同高（这正是用户要的「统一口径」）。
    private static let pillHeight: CGFloat = 42
    /// 胶囊间距（比原行间距 2 大一档：胶囊之间要留出各自的玻璃边）
    private static let pillGap: CGFloat = 8
    private static let maxW: CGFloat = 300
    /// v4.0.105：176 → 196（随胶囊大一号同步放宽，全体同宽仍是「对齐」口径）
    private static let minColW: CGFloat = 196
    /// v4.0.81：项数 **超过** 此值 → 两列（长按气泡菜单最多 16 项，单列 ≈ 590pt：
    /// 一屏占满还会顶到输入栏；≤8 项的旧调用点（三点菜单 / 思考档位）仍单列，观感零变化）
    private static let twoColThreshold = 8
    /// v4.0.105：8 → 6（确认稿几何：菜单顶边 = 抬起后内容底边 + 6pt）
    private static let anchorGap: CGFloat = 6   // 菜单与锚点的净距
    /// v4.0.105：轻纱压暗档临时提到 0.18（当时为「抬起预览」服务）。
    /// 🚨 v4.0.106（用户装包真机拍板）：抬起预览整体移除 + 「**调淡回 4.0.104 的观感**」⇒ 回到 **0.10**。
    /// 现行观感 = 整屏超薄材质模糊 + 轻压暗（0.10），内容原位不动，只有胶囊菜单。
    private static let scrimDim: Double = 0.10
    /// 标题行（caption + 上间距）占位高
    private static let titleH: CGFloat = 26

    /// 列数（见 twoColThreshold）
    private var columnCount: Int { items.count > Self.twoColThreshold ? 2 : 1 }

    /// 单列目标宽：按**全体**最长标题估算（中文 ≈ 17pt/字 + 图标 22 + padding 24），上限 300。
    /// **全体同宽**——统一宽度就是用户要的「对齐」。
    private var idealColWidth: CGFloat {
        let longest = items.map(\.title.count).max() ?? 6
        return min(Self.maxW, max(Self.minColW, CGFloat(longest) * 17 + 46))
    }

    /// 一列里放哪几项：**按行铺**（左 1/右 2、左 3/右 4 …）——视觉上每行两颗读起来顺，
    /// 项数落单时最后一项落在左列（重量感更稳）。
    private func columnItems(_ col: Int, cols: Int) -> [AnchorMenuItem] {
        let rowCount = rows(cols: cols)
        return (0..<rowCount).compactMap { r in
            let i = r * cols + col
            return i < items.count ? items[i] : nil
        }
    }

    private func rows(cols: Int) -> Int { (items.count + cols - 1) / cols }

    /// v4.0.102（审查修订）：说明文字**行高** —— 真值 = Typography.caption(11pt) × 1.35 中文行高 ≈ 15。
    /// ⚠️ 早先按「caption ≈13pt / 行高 17」估，可 13 是 `subhead`、不是 caption：系统性高估 ≈40%，
    ///    会把「其实装得下」的浮层误判成装不下而翻到按钮上方（长文案如退出登录、带记忆/文档正文的确认尤其明显）。
    private static let msgLineH: CGFloat = 15

    /// 说明文字占几行：按菜单实宽估（中文 caption 11pt/字，+1pt 字距留余量）
    private func messageLines(width: CGFloat) -> Int {
        guard !message.isEmpty else { return 0 }
        let perLine = max(6, Int(width / (Typography.caption + 1)))
        return max(1, (message.count + perLine - 1) / perLine)
    }

    private func panelHeight(cols: Int, colW: CGFloat) -> CGFloat {
        let r = rows(cols: cols)
        let menuW = colW * CGFloat(cols) + Self.pillGap * CGFloat(cols - 1)
        let msgH = message.isEmpty
            ? 0
            : CGFloat(messageLines(width: menuW - Spacing.xl * 2)) * Self.msgLineH + 6
        return CGFloat(r) * Self.pillHeight
            + CGFloat(max(r - 1, 0)) * Self.pillGap
            + (title.isEmpty ? 0 : Self.titleH)
            + msgH
    }

    var body: some View {
        GeometryReader { geo in
            // v4.0.76 审查⑥：anchorFrame 是 .global 坐标，而 geo.size/.position 是 overlay 本地坐标，
            // 必须先换算（仓库先例 OrbQuickMenu 同款），否则菜单整体偏移一个安全区/导航栏高。
            let g = geo.frame(in: .global)
            let localAnchor = CGRect(x: anchorFrame.minX - g.minX, y: anchorFrame.minY - g.minY,
                                     width: anchorFrame.width, height: anchorFrame.height)
            // v4.0.81：两列支持（>8 项）——列宽按屏宽二次收窄（左右各留 10pt），保证不越界
            let cols = columnCount
            let raw = idealColWidth
            let colW = cols == 1
                ? raw
                : max(120, min(raw, (geo.size.width - 20 - Self.pillGap) / 2))
            let menuW = colW * CGFloat(cols) + Self.pillGap * CGFloat(cols - 1)
            let menuH = panelHeight(cols: cols, colW: colW)
            // v4.0.106：抬起预览移除后，菜单锚点恒为**内容原位**的矩形（不再有位移/缩放补偿）。
            let anchorTopY = localAnchor.minY
            let anchorBottomY = localAnchor.maxY
            let below = anchorBottomY + Self.anchorGap + menuH < geo.size.height
            let ox = min(max(localAnchor.midX - menuW / 2, 10), max(geo.size.width - menuW - 10, 10))
            let oy = below ? anchorBottomY + Self.anchorGap
                           : max(anchorTopY - Self.anchorGap - menuH, 10)
            ZStack(alignment: .topLeading) {
                // 轻纱：整屏模糊（点空白收回），与 OrbQuickMenu 同款双层
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Color.black.opacity(Self.scrimDim)
                }
                .ignoresSafeArea()
                .opacity(scrimOn ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)

                menuPanel(cols: cols, colWidth: colW)
                    // 退场相位：整块一起淡出（0.18s），胶囊不再各自 spring
                    .opacity(shown ? 1 : 0)
                    .frame(width: menuW)
                    // 🚨 v4.0.157：**位置恒定在落点**，不再从锚点滑过来 —— 面板里每颗都是真液态玻璃，
                    //    position 一动画 = 每帧重新采样背后整页（长会话直接掉帧，用户实报「弹出卡顿严重」）。
                    //    入场只走透明度，见 onAppear / pill 的 opacity 相位。
                    .position(x: ox + menuW / 2, y: oy + menuH / 2)
            }
            .onAppear {
                if reduceMotion {
                    // 减动效：直接落终态（菜单在屏），不播逐颗错峰
                    shown = true
                    scrimOn = true
                    reveal = true
                } else {
                    // 罩与面板拆两个相位（同 OrbQuickMenu / MemoGlassOverlay 的「罩先糊上、面板后到」）：
                    // 罩短促淡入，面板走令牌弹簧但**只动透明度**（几何恒在落点）。
                    withAnimation(Motion.menuScrim) { scrimOn = true }
                    withAnimation(Motion.anchorMenu) { shown = true }
                    // v4.0.158：`reveal` **必须晚一帧**再置 —— 在 onAppear 的同一事务里裸写会被
                    // 首帧合并，胶囊上的隐式 .animation 不播（现象＝「啪一下出现」）。
                    // 下一帧置位保证有前一个 reveal=false 的渲染帧，逐颗错峰才真的看得见。
                    DispatchQueue.main.async { reveal = true }   // 逐颗错峰由 pill 自己的 .animation(value: reveal) 带
                }
            }
        }
    }

    private func close() {
        // v4.0.106：只有菜单一层（抬起预览已移除），收起就是 shown / scrimOn 归零
        // v4.0.157：两个相位同一支短曲线（0.18s）——与下面 onClose 的卸载时机对齐，
        //   面板淡完正好撤掉；胶囊不再各自 spring（见 reveal 注释）。
        withAnimation(Motion.menuScrim) {
            shown = false
            scrimOn = false
        }
        // 等收场动画播完再卸载（视图卸载由父层 isPresented 控制，这里只报出去）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onClose() }
    }

    // MARK: 菜单面板（v4.0.77：正文 = 玻璃胶囊，本体不再垫底；v4.0.81：>8 项两列）

    private func menuPanel(cols: Int, colWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Self.pillGap) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: Typography.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    // v4.0.77 只读审查（低）：标题左缘与胶囊左缘对齐（原来 padding 4 比胶囊的 Spacing.xl
                    // 小 8pt，视觉上标题向左外挂 —— 用户本轮口径「同步检查所有的，都要对齐」）
                    .padding(.horizontal, Spacing.xl)
                    .frame(width: colWidth * CGFloat(cols) + Self.pillGap * CGFloat(cols - 1),
                           alignment: .leading)
                    .opacity(shown ? 1 : 0)
            }
            // v4.0.102：说明文字（危险动作的「明示后果」）—— 与标题同左缘、同宽，自动换行
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.xl)
                    .frame(width: colWidth * CGFloat(cols) + Self.pillGap * CGFloat(cols - 1),
                           alignment: .leading)
                    .opacity(shown ? 1 : 0)
            }
            HStack(alignment: .top, spacing: Self.pillGap) {
                ForEach(0..<cols, id: \.self) { c in
                    let column = columnItems(c, cols: cols)
                    VStack(alignment: .leading, spacing: Self.pillGap) {
                        ForEach(Array(column.enumerated()), id: \.element.id) { r, item in
                            pill(item, width: colWidth)
                                // v4.0.157：**原地淡入**（按行错峰保留「逐颗浮现」的节奏）。
                                // v4.0.158（用户 2026-10-25 选方案②）：玻璃仍然不动，改成**内容滑入**——
                                //    胶囊内的图标+文字从下方 8pt 升到位（见 pill 里的 .offset）。
                                // 🚨 不许给玻璃本体加 scaleEffect / offset / position 动画：玻璃几何一动
                                //    就每帧重新采样背后内容 = 用户实报的「三点菜单弹出卡顿严重」。
                                // 相位与 `shown` 分开（见 reveal 注释）：退场不能带这里的 spring+错峰。
                                .opacity(reveal ? 1 : 0)
                                .animation(reduceMotion ? nil
                                           : Motion.anchorMenu.delay(Double(r * cols + c) * 0.03),
                                           value: reveal)
                        }
                    }
                }
            }
        }
    }

    private func pill(_ item: AnchorMenuItem, width: CGFloat) -> some View {
        let fg = item.destructive ? Color.red : item.color
        return Button {
            guard !item.disabled else { return }
            onPick(item)
        } label: {
            HStack(spacing: Spacing.sm) {
                if !item.icon.isEmpty {
                    Image(systemName: item.icon)
                        .font(.system(size: Typography.body, weight: .semibold))
                        .foregroundStyle(item.disabled ? Color.secondary : fg)
                        .frame(width: 20)
                }
                Text(item.title)
                    // v4.0.105：13(subhead) → 15(body，随动态字体缩放，上限 17) —— 胶囊大一号的配套
                    .font(.system(size: Typography.body, weight: .semibold))
                    .foregroundStyle(item.disabled ? Color.secondary : fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            // v4.0.158（用户 2026-10-25 选方案②·内容滑入）：**只有图标+文字这一坨**从下方 8pt
            // 升到位；玻璃胶囊本体几何恒定（opacity 由外层 reveal 驱动）。
            // 胶囊高 42、内容行高 ≈18 → 垂直余量 12pt，8pt 位移不会露出胶囊边界。
            // 🚨 别把这个 offset 挪到 glassEffect 之后那层 —— 那就变成玻璃本体在动，长会话掉帧。
            .offset(y: reduceMotion || reveal ? 0 : 8)
            .padding(.horizontal, Spacing.xl)
            .frame(width: width, height: Self.pillHeight, alignment: .leading)
            // 玻璃挂在 padding 之后（OrbQuickMenu / dock 胶囊同口径）；可点元素必须 .regular.interactive()
            .a11yGlass(.regular.interactive(), in: Capsule(),
                       stroke: Color.white.opacity(scheme == .dark ? 0.22 : 0.12))
            .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .disabled(item.disabled)
    }
}
