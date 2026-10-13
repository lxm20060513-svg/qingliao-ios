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
    /// v4.0.105：**被长按内容的「抬起预览」**（可选）。传了它 → 落地用户口径「长按内容时先将所选
    /// 内容微缩再抬起」：
    ///   ① 微缩：预览初始态 = Motion.pressScale(0.96)（触发长按那一刻内容已被按下）；
    ///   ② 抬起：0.12s 后起跳 → Motion.liftScale(1.02) + 上移 Motion.liftRise(10pt) + 投影；
    ///      预览画在轻纱**之上**（轻纱只压住页面其余部分），菜单锚点随之改到**抬起后**的底边下方 6pt；
    ///   ③ 菜单落位：比抬起再晚一拍起跳，逐颗错峰（与既有口径同款）。
    /// 不传 → 观感回到 v4.0.104（内容原位、菜单锚在原锚点），27 个旧调用点零行为变化。
    /// ⚠️ 实参序 = 声明序：带预览的调用点写 (anchorFrame:items:title:message:onPick:onClose:preview:)。
    var preview: AnyView? = nil

    @State private var shown = false
    /// v4.0.105：抬起拍是否已落位（false = 微缩态，true = 抬起态）
    @State private var lifted = false
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
    /// v4.0.105：轻纱压暗档（0.10 → 0.18）—— 用户口径「背景高斯模糊变暗」，模糊沿用超薄材质。
    /// 压得更暗，抬起的内容才浮得出来（像素判据：抬起面亮度 vs 周围轻纱 ≈ +27 档）。
    private static let scrimDim: Double = 0.18
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
            // v4.0.105：抬起预览在场时，菜单锚到**抬起后**的矩形 —— 底边上移 liftRise，
            // 并加回 2% 缩放带来的半高增量（缩放以中心为轴，底边只涨一半）。
            let liftRise = preview == nil ? 0 : Motion.liftRise
            let liftGrow = preview == nil ? 0 : localAnchor.height * (Motion.liftScale - 1) / 2
            let anchorTopY = localAnchor.minY - liftRise
            let anchorBottomY = localAnchor.maxY - liftRise + liftGrow
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
                .opacity(shown ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)

                // v4.0.105：抬起预览 —— 画在轻纱之上（z 序 = 声明序，故置于轻纱之后、菜单之前），
                // 不接管触摸（点空白仍是收回菜单）。
                // 显式绑定（不用 if let 简写，避免成员简写在不同工具链版本上的歧义）
                if let liftPreview = preview {
                    liftPreview
                        .frame(width: localAnchor.width, height: localAnchor.height)
                        .scaleEffect(lifted ? Motion.liftScale : Motion.pressScale)
                        .offset(y: lifted ? -Motion.liftRise : 0)
                        .shadow(color: Color.black.opacity(lifted ? 0.28 : 0), radius: 30, y: 14)
                        .shadow(color: Color.black.opacity(lifted ? 0.14 : 0), radius: 8, y: 3)
                        .position(x: localAnchor.midX, y: localAnchor.midY)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(false)
                }

                menuPanel(cols: cols, colWidth: colW)
                    .frame(width: menuW)
                    .position(x: ox + menuW / 2,
                              y: reduceMotion ? oy + menuH / 2
                                              : (shown ? oy + menuH / 2
                                                       : anchorY(inBelow: below, lift: liftRise)))
            }
            .onAppear {
                if reduceMotion {
                    // 减动效：直接落终态（内容已在抬起位、菜单在屏），不播微缩/抬起/错峰
                    lifted = true
                    shown = true
                } else {
                    // ③ 菜单落位：带预览时比抬起晚一拍起跳（① 微缩 → ② 抬起 → ③ 落位）
                    withAnimation(preview == nil ? Motion.anchorMenu
                                                 : Motion.anchorMenu.delay(0.24)) { shown = true }
                    if preview != nil {
                        // ② 抬起拍：0.12s 后起跳（① 的微缩由预览初始态承接，见 preview 注释）
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            withAnimation(Motion.menuLift) { lifted = true }
                        }
                    }
                }
            }
        }
    }

    /// 收起方向：从锚点缩回（below 时回锚点下方点，朝上时回锚点上方点）
    /// 注意：本函数在 body 的 GeometryReader 闭包内被调用，用的 localAnchor 同一套换算——
    /// 这里收的是 global 原值，仅为动画起点误差 ±几 pt 可接受；如需精确可把 localAnchor 透传进来。
    private func anchorY(inBelow below: Bool, lift: CGFloat) -> CGFloat {
        below ? anchorFrame.maxY + 4 - lift : anchorFrame.minY - 4 - lift
    }

    private func close() {
        // v4.0.105：内容与菜单同时收（预览回落到微缩态 → 卸载时由父层消失）
        withAnimation(Motion.settle) {
            shown = false
            lifted = false
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
                                // 错峰绽放（与 OrbQuickMenu 同款观感：从锚点侧逐颗落位）
                                // 顺序按「行」数：同一行的左右两颗几乎同时落位
                                .opacity(shown ? 1 : 0)
                                .scaleEffect(shown ? 1 : 0.92, anchor: .top)
                                .animation(reduceMotion ? nil
                                           : .spring(response: 0.36, dampingFraction: 0.8)
                                                .delay(Double(r * cols + c) * 0.03),
                                           value: shown)
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
