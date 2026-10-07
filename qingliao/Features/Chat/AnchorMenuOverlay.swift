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
    var onPick: (AnchorMenuItem) -> Void
    var onClose: () -> Void

    @State private var shown = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 胶囊几何（v4.0.77：与 OrbQuickMenu 同一口径 —— 胶囊 + 玻璃 + 统一宽度）
    /// 高度 = 上下 padding(Spacing.lg 10 ×2) + 文字行高(≈16) ≈ 36
    private static let pillHeight: CGFloat = 36
    /// 胶囊间距（比原行间距 2 大一档：胶囊之间要留出各自的玻璃边）
    private static let pillGap: CGFloat = 8
    private static let maxW: CGFloat = 300
    private static let anchorGap: CGFloat = 8   // 菜单与锚点的净距
    /// 标题行（caption + 上间距）占位高
    private static let titleH: CGFloat = 26

    /// 宽度按最长标题估算（中文 ≈ 17pt/字 + 图标 22 + padding 24），上限 300。
    /// **全体同宽**——统一宽度就是用户要的「对齐」。
    private var menuWidth: CGFloat {
        let longest = items.map(\.title.count).max() ?? 6
        return min(Self.maxW, max(176, CGFloat(longest) * 17 + 46))
    }

    private var menuHeight: CGFloat {
        CGFloat(items.count) * Self.pillHeight
            + CGFloat(max(items.count - 1, 0)) * Self.pillGap
            + (title.isEmpty ? 0 : Self.titleH)
    }

    var body: some View {
        GeometryReader { geo in
            // v4.0.76 审查⑥：anchorFrame 是 .global 坐标，而 geo.size/.position 是 overlay 本地坐标，
            // 必须先换算（仓库先例 OrbQuickMenu 同款），否则菜单整体偏移一个安全区/导航栏高。
            let g = geo.frame(in: .global)
            let localAnchor = CGRect(x: anchorFrame.minX - g.minX, y: anchorFrame.minY - g.minY,
                                     width: anchorFrame.width, height: anchorFrame.height)
            let menuH = menuHeight
            let below = localAnchor.maxY + Self.anchorGap + menuH < geo.size.height
            let ox = min(max(localAnchor.midX - menuWidth / 2, 10), max(geo.size.width - menuWidth - 10, 10))
            let oy = below ? localAnchor.maxY + Self.anchorGap
                           : max(localAnchor.minY - Self.anchorGap - menuH, 10)
            ZStack(alignment: .topLeading) {
                // 轻纱：整屏模糊（点空白收回），与 OrbQuickMenu 同款双层
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Color.black.opacity(0.10)
                }
                .ignoresSafeArea()
                .opacity(shown ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)

                menuPanel
                    .frame(width: menuWidth)
                    .position(x: ox + menuWidth / 2,
                              y: reduceMotion ? oy + menuH / 2
                                              : (shown ? oy + menuH / 2 : anchorY(inBelow: below)))
            }
            .onAppear {
                if reduceMotion { shown = true }
                else { withAnimation(Motion.anchorMenu) { shown = true } }
            }
        }
    }

    /// 收起方向：从锚点缩回（below 时回锚点下方点，朝上时回锚点上方点）
    /// 注意：本函数在 body 的 GeometryReader 闭包内被调用，用的 localAnchor 同一套换算——
    /// 这里收的是 global 原值，仅为动画起点误差 ±几 pt 可接受；如需精确可把 localAnchor 透传进来。
    private func anchorY(inBelow below: Bool) -> CGFloat {
        below ? anchorFrame.maxY + 4 : anchorFrame.minY - 4
    }

    private func close() {
        withAnimation(Motion.settle) { shown = false }
        // 等收场动画播完再卸载（视图卸载由父层 isPresented 控制，这里只报出去）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onClose() }
    }

    // MARK: 菜单面板（v4.0.77：正文 = 一列玻璃胶囊，本体不再垫底）

    private var menuPanel: some View {
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
                    .frame(width: menuWidth, alignment: .leading)
                    .opacity(shown ? 1 : 0)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                pill(item)
                    // 错峰绽放（与 OrbQuickMenu 同款观感：从锚点侧逐颗落位）
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.92, anchor: .top)
                    .animation(reduceMotion ? nil
                               : .spring(response: 0.36, dampingFraction: 0.8).delay(Double(idx) * 0.03),
                               value: shown)
            }
        }
    }

    private func pill(_ item: AnchorMenuItem) -> some View {
        let fg = item.destructive ? Color.red : item.color
        return Button {
            guard !item.disabled else { return }
            onPick(item)
        } label: {
            HStack(spacing: Spacing.sm) {
                if !item.icon.isEmpty {
                    Image(systemName: item.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.disabled ? Color.secondary : fg)
                        .frame(width: 18)
                }
                Text(item.title)
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(item.disabled ? Color.secondary : fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.xl)
            .frame(width: menuWidth, height: Self.pillHeight, alignment: .leading)
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
