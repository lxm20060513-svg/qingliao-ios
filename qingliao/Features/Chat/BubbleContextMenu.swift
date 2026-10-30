//
//  BubbleContextMenu.swift
//  v4.0.168：聊天页长按菜单改回**系统原生菜单**（iOS 27 玻璃菜单 + 内容抬起预览）。
//
//  由来（用户 2026-10-30）：「聊天页长按菜单改回 iOS27 原生菜单弹窗」。
//  v4.0.81 曾把 6 处 `.contextMenu { bubbleMenu }` 整块换成自绘锚定胶囊
//  （AnchorMenuOverlay + 整屏轻纱），现在长按气泡回到系统 `.contextMenu` ——
//  菜单的玻璃材质、分组、出现/退场动效、无障碍与触感全部交还系统。
//
//  ⚠️ 菜单项仍由 `ChatView.bubbleMenuItems(for:text:)` **单一真源**生成
//  （顺序 / 守卫 / 文案一律不动），本文件只负责把 [AnchorMenuItem] 渲染成系统菜单项。
//  别再在这里另写一套菜单内容，否则守卫（撤回 10 秒 / 只对 AI 给重新生成）会两处漂。
//

import SwiftUI

/// [AnchorMenuItem] → 系统 `.contextMenu` 菜单项。
/// 图标沿用 v4.0.77 的缩小版彩色圆角块（用户口径：菜单图标要多彩，不收敛成单色）。
struct BubbleMenuContent: View {
    let items: [AnchorMenuItem]
    let onPick: (AnchorMenuItem) -> Void

    var body: some View {
        ForEach(items) { item in
            Button(role: item.destructive ? ButtonRole.destructive : nil) {
                onPick(item)
            } label: {
                Label {
                    Text(item.title)
                } icon: {
                    Image(uiImage: MenuIconTile.small(item.icon, Self.tint(of: item.color)))
                }
                // iOS 27：菜单标签必须显式 titleAndIcon，否则系统只显示标题、彩色图标整列消失
                //（挂**菜单内容**上，不是宿主视图上 —— 见技能 qingliao-ios-native「iOS 27 菜单图标」）
                .labelStyle(.titleAndIcon)
            }
            .disabled(item.disabled)
        }
    }

    /// AnchorMenuItem 存的是 SwiftUI Color，图标工厂吃 MenuIconTint 枚举。
    /// 全仓调用点只用这 6 个语义色（见 ChatView.bubbleMenuItems）；未命中（含默认 `.primary`）
    /// 一律回落蓝色 —— 彩色圆角块是本仓菜单图标口径，别在这里引入灰/单色档。
    private static func tint(of color: Color) -> MenuIconTint {
        if color == .teal { return .teal }
        if color == .purple { return .purple }
        if color == .orange { return .orange }
        if color == .indigo { return .indigo }
        if color == .red { return .red }
        return .blue
    }
}

extension View {
    /// 长按 → 系统原生菜单。items / onPick 任一为 nil 时不挂菜单（动作卡等刻意无菜单的段落）。
    @ViewBuilder
    func bubbleContextMenu(items: ((String) -> [AnchorMenuItem])?,
                           text: String,
                           onPick: ((AnchorMenuItem, String) -> Void)?) -> some View {
        if let items, let onPick {
            self.contextMenu {
                BubbleMenuContent(items: items(text)) { onPick($0, text) }
            }
        } else {
            self
        }
    }
}
