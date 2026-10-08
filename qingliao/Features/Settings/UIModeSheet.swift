import SwiftUI

// MARK: - P0-1 界面模式选择弹窗（工作模式 / 生活模式）
//
// 依据：`design-plans/finesse-refactor-checklist.md` v2 第 26 项。
//
// 口径：
//   · 选中即写盘（键见 Core/UIMode.swift 的单一真源），并**当场提示「重启 App 后生效」**；
//   · 点当前那一项 = 不写盘、不提示（避免「点了一下以为切了」的假动作）；
//   · 说明文字说清两套形态各是什么 —— 用户不认识「工作模式」这四个字。

struct UIModeSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 本页状态，跟写盘结果同步（设置页那一行由 @AppStorage 负责显值，两处都读同一个键）
    @State private var current: UIMode = UIMode.current
    /// 切换后的「重启生效」提示
    @State private var showRestartHint = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(UIMode.allCases, id: \.self) { mode in
                        row(mode)
                    }
                } header: {
                    Text("界面模式")
                } footer: {
                    Text("切换后需**重启 App** 才生效（不做热切换）。生活模式 = 现在这套界面；工作模式 = 收敛后的工作台，P1 起逐步落地。")
                }
            }
            .navigationTitle("界面模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
        .alert("已切换为\(current.title)", isPresented: $showRestartHint) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("重启 App 后生效。")
        }
    }

    @ViewBuilder
    private func row(_ mode: UIMode) -> some View {
        Button {
            guard mode != current else { return }   // 点当前项：不写盘、不提示
            UIMode.current = mode
            current = mode
            Haptics.selection()
            showRestartHint = true
        } label: {
            HStack(spacing: Spacing.lg) {
                Image(systemName: mode.icon)
                    .font(.system(size: Typography.body, weight: .semibold))
                    .foregroundStyle(mode == current ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(mode.title)
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.primary)
                    Text(mode.subtitle)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.sm)
                if mode == current {
                    Image(systemName: "checkmark")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.title)：\(mode.subtitle)")
    }
}
