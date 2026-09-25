//
//  HomeShortcutSheet.swift
//  轻聊
//
//  v3.9.82：桌面图标长按快捷方式的选择弹窗（6 项候选里挑 4 项显示）
//  上限来自 iOS 本身（桌面长按菜单最多 4 项），不是我们的产品决定 —— 文案里对用户说清楚。
//

import SwiftUI

struct HomeShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [Int] = HomeShortcutStore.ids

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(HomeShortcut.candidates) { a in
                        row(a)
                    }
                } header: {
                    Text("已选 \(selected.count)/\(HomeShortcut.maxCount)")
                } footer: {
                    Text(selected.isEmpty
                         ? "一个都没选 —— 长按桌面图标不会出现快捷方式。"
                         : "顺序就是下面的排列顺序。长按桌面上的「轻聊」图标即可看到这几项，最多 \(HomeShortcut.maxCount) 个（iOS 系统上限）。")
                }
                // 常显：全关掉之后也得有路回来。
                // 判据用集合比较（不是 count）：选了 4 个但和默认不一样时，也得给「恢复默认」。
                if Set(selected) != Set(HomeShortcut.defaultIds) {
                    Section {
                        Button {
                            HomeShortcutStore.reset()
                            selected = HomeShortcutStore.ids
                        } label: {
                            Text("恢复默认").font(.system(size: Typography.body))
                        }
                    }
                }
            }
            .navigationTitle("桌面快捷方式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        // 打开弹窗时把系统菜单按当前设置重建一次：万一上一次同步发生在设置写坏之后，
        // 这里能自愈（用户看不到「设置里选了但桌面菜单没变」这种不一致）。
        .task { HomeShortcutManager.sync() }
    }

    @ViewBuilder
    private func row(_ a: OrbQuickAction) -> some View {
        let on = selected.contains(a.id)
        let full = selected.count >= HomeShortcut.maxCount
        Toggle(isOn: Binding(get: { on },
                             set: { newValue in
                                 if !HomeShortcutStore.set(a.id, on: newValue) { return }
                                 selected = HomeShortcutStore.ids
                             })) {
            Label {
                Text(a.title).font(.system(size: Typography.body))
            } icon: {
                Image(systemName: a.icon).foregroundStyle(a.color)
            }
        }
        // 选满 4 个后未选项置灰（点了也不会生效，所以灰掉比让它弹一下回弹更诚实）
        .disabled(!on && full)
        .accessibilityLabel("\(a.title) 桌面快捷方式")
    }
}
