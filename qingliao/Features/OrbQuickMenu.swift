// MARK: - v3.9.59（攒版）智慧球长按快捷菜单
//
// 交互：长按 dock 智慧球（≥0.45s）→ 弹出 4 颗功能胶囊：新建会话 / AI 速记 / 语音输入 / 今日待办。
// 动效 = 方案 A+C 混合（用户拍板）：A 绽放（胶囊从球心弹簧弹射、错峰入场，落点几何见 OrbQuickMenuLayout）
//        + C 的球心光晕扩散（常驻柔光 + 一圈扩散环），**不做**全屏磨砂。
// v3.9.60：落点由「弧线散开」改为「两排两列」——弧线在 393pt 屏宽下四颗胶囊必然重叠（用户实测），
//        几何根因与算式写在 OrbQuickMenuLayout 上方。
//
// 复用既有入口（不新造状态/后端）：
//   新建会话 → ChatStore.requestNewSession()（ChatView 的 pendingNewSession 两步走清屏）
//   AI 速记  → MemoStore.add(content:source:"orb")
//   语音输入 → 切聊天页 + 进程内通知 → ChatView.toggleVoiceMode（与输入框长按同一条路径）
//   今日待办 → TodoStore.add(content:source:"orb")
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

    static let all: [OrbQuickAction] = [
        OrbQuickAction(id: 0, title: "新建会话", icon: "plus.bubble.fill", color: .blue),
        OrbQuickAction(id: 1, title: "AI 速记", icon: "brain.head.profile", color: .purple),
        OrbQuickAction(id: 2, title: "语音输入", icon: "mic.fill", color: .pink),
        OrbQuickAction(id: 3, title: "今日待办", icon: "checklist", color: .orange),
    ]
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
    var onAction: (OrbQuickAction) -> Void
    var onClose: () -> Void

    var body: some View {
        GeometryReader { geo in
            let g = geo.frame(in: .global)
            let barH = barHeight > 1 ? barHeight : DockOrbOverlay.fallbackBarHeight
            // 同 OrbHitLayer：球心走 DockOrbOverlay.orbCenterGlobal，与可见球严格同源
            let c = DockOrbOverlay.orbCenterGlobal(slotIndex: slotIndex,
                                                   slotCount: slotCount,
                                                   barHeight: barH)
            OrbQuickMenuLayer(ballCenter: CGPoint(x: c.x - g.minX, y: c.y - g.minY),
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
// 落点（以球心为原点，与 v3.9.59 截图里看到的排布一致）：
//   index 0 下左 · 1 上左 · 2 上右 · 3 下右
//   同排中心距 128pt（101 + 27 间隙）；两排纵向差 56pt（36 + 20 间隙）
enum OrbQuickMenuLayout {
    /// 胶囊尺寸估值（本机无 Xcode SDK 渲染不出，按令牌算式推；真机不齐只改这一处）
    static let pillSize = CGSize(width: 101, height: 36)
    /// 同排半间距（中心距 = 2×64 = 128）
    static let columnDX: CGFloat = 64
    /// 上排抬升（离球心更远）、下排抬升
    static let upperDY: CGFloat = 160
    static let lowerDY: CGFloat = 104
    /// 胶囊底到球心的最小间距（球半径约 34pt + 呼吸 40pt）
    static let minGapAboveBall: CGFloat = 74

    /// 单颗胶囊的中心点。取模防越界（加第 5 颗胶囊不崩）。
    static func center(index: Int, ballCenter: CGPoint) -> CGPoint {
        let i = ((index % 4) + 4) % 4
        let isLeft = (i == 0 || i == 1)
        let isUpper = (i == 1 || i == 2)
        return CGPoint(x: ballCenter.x + (isLeft ? -columnDX : columnDX),
                       y: ballCenter.y - (isUpper ? upperDY : lowerDY))
    }
}

// MARK: - 菜单层（轻纱 + 光晕 + 两排胶囊）

struct OrbQuickMenuLayer: View {
    let ballCenter: CGPoint
    var onAction: (OrbQuickAction) -> Void
    var onClose: () -> Void

    @State private var shown = false
    @Environment(\.colorScheme) private var scheme
    /// v3.9.59：减弱动态效果（系统辅助功能）——弹簧散射/位移会加重不适感，退化为「原地淡入」。
    /// 全仓口径一致：LoginView、LiquidOrbAvatar 都读同一环境值，本层别自己发明开关。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 单颗胶囊入场动画：正常运行按 index 错峰 50ms；减弱动态效果下退化为瞬时节奏（只留透明度过渡）
    private func pillAnimation(index: Int) -> Animation {
        reduceMotion ? Motion.tap
                     : .spring(response: 0.45, dampingFraction: 0.68).delay(Double(index) * 0.05)
    }

    var body: some View {
        ZStack {
            // 轻纱聚焦（不做全屏磨砂——方案 C 只取光晕）+ 点空白收起。
            // 这层是模态菜单，必须吃掉空白点击；球体被胶囊环围住，长按手势此时不可达，无冲突。
            Color.black.opacity(shown ? 0.12 : 0)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismissAnimated)

            halo

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

    /// 胶囊相对球心的落点（两排两列，几何见 OrbQuickMenuLayout）
    private func pillOffset(index: Int) -> CGPoint {
        OrbQuickMenuLayout.center(index: index, ballCenter: ballCenter)
    }

    private func orbPill(_ action: OrbQuickAction, index: Int) -> some View {
        let p = pillOffset(index: index)
        return HStack(spacing: Spacing.sm) {
            Image(systemName: action.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(action.color)
            Text(action.title)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, Spacing.xl + 2)
        .padding(.vertical, Spacing.lg)
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
        .onTapGesture {
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
                .background(.quaternary,
                            in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
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
