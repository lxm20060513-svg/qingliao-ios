//
//  ChatEdgeBackKit.swift
//  轻聊
//
//  v4.0.82：聊天内容页「左缘右滑 → 返回会话列表」的手势判定（纯逻辑，无 SwiftUI 依赖）。
//
//  为什么单独抽文件：本仓规矩「新写的纯计算先落真值表编译跑一遍再推 CI」，
//  而真值表只能用 swiftc 编译**纯源码**（混进 SwiftUI 依赖就编不过）→
//  单测与源护栏见 scripts/ql_dock/truth_table_dock.swift。
//
//  用户口径（2026-10-09）：「在聊天内容页增加边缘手势返回会话页功能」。
//  页面层级背景：v4.0.81 起「会话页」已并入聊天 tab（一页两态：首页 ↔ 对话页），
//  所以这条手势**不是切 tab**、也不碰 NavigationStack —— 它与页头那颗返回按钮
//  **同一个动作**（`ChatView.onBackToHome`，由合并首页宿主注入）：
//  iPad 双栏 / 独立聊天页场景该闭包为 nil，手势自然不生效。
//
//  判定三件（缺一项就会误触）：
//    ① 起手在**左缘**（`edgeWidth`）—— 微信同款；手指从页面中部横向划动不该触发；
//    ② 水平位移足够（`minTranslation`）—— 太短当抖动/误碰；
//    ③ 方向够纯（`horizontalBias`）—— 纵向滚动、斜划不认。
//

import Foundation

/// 左缘右滑返回的判定与阈值（**唯一真源**：改阈值只改这里，别在视图里内联第二套）。
enum ChatEdgeBackKit {
    /// 起手区宽度：手指必须落在屏幕左缘这条带内（pt）
    static let edgeWidth: CGFloat = 24
    /// 触发位移：水平右移 ≥ 它才认（pt）
    static let minTranslation: CGFloat = 70
    /// 方向纯度：水平位移必须 ≥ 竖直位移 × 它（挡纵向滚动与斜划）
    static let horizontalBias: CGFloat = 1.8

    /// 是否触发「返回会话列表」。
    /// 参数取手势的**全局**起手 x 与位移（`DragGesture.Value.startLocation.x` / `translation`）。
    static func shouldGoBack(startX: CGFloat, dx: CGFloat, dy: CGFloat) -> Bool {
        guard startX <= edgeWidth else { return false }
        guard dx >= minTranslation else { return false }
        return dx >= abs(dy) * horizontalBias
    }
}
