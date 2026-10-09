import SwiftUI

/// v4.0.82（用户 2026-10-09）：「设置里面增加 dock 栏设置，聊天、生活、看板、设置页可以调整顺序，
/// 可以隐藏某一页，唯独设置页不能隐藏」。
///
/// 口径与落点：
///   · 落盘 = 两个 UserDefaults 串（`UserDefaultsKey.dockOrder` / `dockHidden`），形态定义在
///     `Core/DockLayoutKit.swift`（顺序串 = 4 档排列；隐藏串按出厂序，空集合 = 空串）。
///   · `DockTabView` 用 `@AppStorage` 读**同一对键** → 这里改完 dock 立即重排，
///     不需要任何通知 / 回调 / 环境对象（跨视图 @AppStorage 同键自动同步）。
///   · 升/降序用**箭头按钮**（与「首页快捷卡片」自定义同一套交互语言：同一个仓里同一个交互只有一种长相，
///     不做拖拽排序 —— 列表拖拽会与 Sci 的滚动/侧滑返回打架，箭头点得准）。
///   · 隐藏用行尾 Toggle；设置页那一行**禁用**并标「必显示」——闸门只有 `DockLayoutKit.canHide(raw:)` 一处，
///     这里不另写判断（视图里再写一份判断 = 迟早与逻辑分层不一致）。
///
/// ⚠️ 别在这里做「至少留一档可见」之类的额外限制：用户口径只说了「设置页不能隐藏」，
///    而设置页恰好就是那个保底档 —— 所以无论怎么关，渲染列表都不会空（DockLayoutKit.visible 兜底）。
struct DockLayoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UserDefaultsKey.dockOrder) private var orderRaw = DockLayoutKit.defaultOrderRaw
    @AppStorage(UserDefaultsKey.dockHidden) private var hiddenRaw = ""

    /// 当前顺序（净化后的 4 档；坏串会被 DockLayoutKit 拉回出厂序）
    private var order: [DockTab] {
        DockLayoutKit.sanitizedOrder(orderRaw).compactMap { DockTab(rawValue: $0) }
    }

    /// 当前隐藏集合（rawValue，按出厂序；设置页保证不在其中）
    private var hidden: [String] { DockLayoutKit.sanitizedHidden(hiddenRaw) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(order.enumerated()), id: \.element) { idx, tab in
                        row(tab: tab, idx: idx)
                    }
                } header: {
                    Text("顺序与显示")
                } footer: {
                    Text("用上下箭头调整位置；右侧开关控制是否出现在 Dock 栏。「设置」必须显示，不能隐藏。")
                }
            }
            .navigationTitle("Dock 栏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// v4.0.83（用户：「app 里面小图标统一圆角多彩」）：dock 各档行首色块的配色真源。
    /// 与底部栏语义对齐：会话=蓝 / 生活=粉 / 聊天=青 / 看板=橙 / 设置=灰。
    private func rowTint(_ tab: DockTab) -> Color {
        switch tab {
        case .sessions:  return .blue
        case .life:      return .pink
        case .chat:      return .teal
        case .dashboard: return .orange
        case .settings:  return .gray
        }
    }

    /// 一行：图标 + 名称 + 升降序箭头 + 显隐开关（设置页 = 「必显示」）
    @ViewBuilder
    private func row(tab: DockTab, idx: Int) -> some View {
        HStack(spacing: Spacing.md) {
            // v4.0.83（用户：「app 里面小图标统一圆角多彩」）：行首图标与全站列表行同款色块（28 + Radius.icon）
            Image(systemName: tab.icon)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(rowTint(tab), in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
            Text(tab.title)
                .font(.system(size: Typography.body))
            Spacer(minLength: Spacing.sm)
            // 升降序：到顶/到底禁用（与首页卡片自定义同款箭头交互）
            HStack(spacing: Spacing.sm) {
                Button {
                    move(tab, by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(idx == 0)

                Button {
                    move(tab, by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(idx >= order.count - 1)
            }
            // 显隐：设置页那行不给开关（用户口径「唯独设置页不能隐藏」）
            if DockLayoutKit.canHide(raw: tab.rawValue) {
                // v4.0.82：开关口径单源——走 qingliaoSwitch()，别手写 .labelsHidden()/.tint()
                // （设置页间距口径真值表会红：本仓所有开关只有这一种长相）
                Toggle("", isOn: visibleBinding(for: tab))
                    .qingliaoSwitch()
            } else {
                Text("必显示")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 显隐绑定：开 = 不在隐藏集合里；关 = 加入隐藏集合（写回走 DockLayoutKit.encodeHidden 的规范形态）
    private func visibleBinding(for tab: DockTab) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(tab.rawValue) },
            set: { on in
                var now = hidden
                if on {
                    now.removeAll { $0 == tab.rawValue }
                } else if !now.contains(tab.rawValue) {
                    now.append(tab.rawValue)
                }
                hiddenRaw = DockLayoutKit.encodeHidden(now)
            }
        )
    }

    /// 与相邻档换位（写回整串；越界不动）
    private func move(_ tab: DockTab, by delta: Int) {
        var now = order.map(\.rawValue)
        guard let i = now.firstIndex(of: tab.rawValue), now.indices.contains(i + delta) else { return }
        now.swapAt(i, i + delta)
        orderRaw = now.joined(separator: ",")
        Haptics.tap()
    }
}
