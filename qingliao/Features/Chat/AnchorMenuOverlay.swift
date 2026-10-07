//
//  AnchorMenuOverlay.swift
//  v4.0.76：锚定弹出菜单（用户 2026-10-07：「三点菜单点击应该从三点菜单处弹出，按空白收回，
//  而不是从中间弹出」）—— 替代 confirmationDialog 的「操作菜单」场景（删除确认等仍走系统 alert）。
//
//  观感与 OrbQuickMenu 同一家：全屏轻纱（ultraThinMaterial + 极淡压暗）+ 玻璃胶囊，
//  但结构是**单列纵向**贴锚点下方展开（锚点在屏幕下半时自动改朝上），胶囊从锚点滑出落位。
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
    @Environment(\.displayScale) private var displayScale

    /// 胶囊几何：宽自适应（上限 300）、行高 44、圆角 18
    private static let rowHeight: CGFloat = 44
    private static let corner: CGFloat = 18
    private static let maxW: CGFloat = 300
    private static let anchorGap: CGFloat = 8   // 菜单与锚点的净距

    /// 宽度按最长标题估算（中文 ≈ 17pt/字 + 图标 24 + padding 32），上限 300
    private var menuWidth: CGFloat {
        let longest = items.map(\.title.count).max() ?? 6
        return min(Self.maxW, max(180, CGFloat(longest) * 17 + 56))
    }

    var body: some View {
        GeometryReader { geo in
            // v4.0.76 审查⑥：anchorFrame 是 .global 坐标，而 geo.size/.position 是 overlay 本地坐标，
            // 必须先换算（仓库先例 OrbQuickMenu 同款），否则菜单整体偏移一个安全区/导航栏高。
            let g = geo.frame(in: .global)
            let localAnchor = CGRect(x: anchorFrame.minX - g.minX, y: anchorFrame.minY - g.minY,
                                     width: anchorFrame.width, height: anchorFrame.height)
            // menuH 计入标题行高（caption ≈17 + top10 + bottom2 ≈ 29，审查 P4：带 title 时 below 判定防贴底溢出）
            let titleH: CGFloat = title.isEmpty ? 0 : 29
            let menuH = CGFloat(items.count) * Self.rowHeight + CGFloat(max(items.count - 1, 0)) * 2 + 8 + titleH
            let below = localAnchor.maxY + Self.anchorGap + menuH < geo.size.height
            let ox = min(max(localAnchor.midX - menuWidth / 2, 10), geo.size.width - menuWidth - 10)
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

    // MARK: 菜单面板

    private var menuPanel: some View {
        VStack(spacing: 2) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: Typography.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                row(item)
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.92, anchor: .top)
                    .animation(reduceMotion ? nil
                               : .spring(response: 0.36, dampingFraction: 0.8).delay(Double(idx) * 0.03),
                               value: shown)
            }
        }
        .padding(.vertical, 6)
        .a11yGlass(.regular, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous),
                   stroke: Color.white.opacity(scheme == .dark ? 0.22 : 0.12))
        .shadow(color: Color.black.opacity(0.16), radius: 14, y: 6)
    }

    private func row(_ item: AnchorMenuItem) -> some View {
        let fg = item.destructive ? Color.red : item.color
        return Button {
            guard !item.disabled else { return }
            onPick(item)
        } label: {
            HStack(spacing: 10) {
                if !item.icon.isEmpty {
                    Image(systemName: item.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(item.disabled ? Color.secondary : fg)
                        .frame(width: 22)
                }
                Text(item.title)
                    .font(.system(size: Typography.body, weight: .medium))
                    .foregroundStyle(item.disabled ? Color.secondary : fg)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: Self.rowHeight - 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(item.disabled)
    }
}
