//
//  ChatAnchorMenuLayer.swift
//  v4.0.157：聊天页三个锚定菜单（三点操作 / 思考档位 / 长按气泡）的**呈现状态 + 挂载层**
//  从 ChatView 搬出来，单独成 View。
//
//  为什么（用户 2026-10-24 实报「聊天页右上角三点菜单弹出动效卡顿严重」）：
//  原先三个开合状态是 ChatView 的 `@State`（showMoreMenu / showReasoningPicker / bubbleMenuTarget），
//  而锚定浮层挂在**整页最外圈** `.overlay`。⇒ 点一下三点菜单 = 6k 行 ChatView.body 全量重算
//  （LazyVStack 300 行 + 全部浮层跟着 diff）→ 真机体感「点下去先顿一下才开始动」。
//  同源教训见 ChatView 尾部 `StreamScrollFollower` 注释（打字机每秒写 20 次把整页拖垮）与
//  `InboxPullState`（拖动每帧写 @State）。
//
//  收口方式与本仓既有两例**逐字同构**（别再退回 @State）：
//    · 状态装进 `@Observable`（`InboxPullState` 同款），ChatView 只持引用、**body 不读属性**；
//    · 浮层本体是本文件的 `ChatAnchorMenuLayer`，它读状态 → 失效范围只剩这一个浮层节点。
//  ⚠️ 判断「有没有退回」：`grep -n 'showMoreMenu\\|showReasoningPicker\\|bubbleMenuTarget' ChatView.swift`
//     在 body 里命中即复发（写入点除外 —— 写入不产生依赖）。
//

import SwiftUI
import Observation

/// 聊天页三个锚定菜单的开合 / 锚点（三者互斥：开一个前先清其余）
@Observable @MainActor
final class ChatMenuState {
    /// 三点「更多」菜单（锚点 = 页头更多按钮的全局 frame）
    var showMore = false
    var moreAnchor: CGRect = .zero
    /// 输入栏「思考档位」菜单（锚点 = 档位胶囊的全局 frame）
    var showReasoning = false
    var reasoningAnchor: CGRect = .zero
    /// 长按气泡 / 文字段的菜单目标（锚点由 ChatBubbleAnchorStore 量好）
    var bubble: ChatBubbleMenuTarget?

    // MARK: 互斥入口（**唯一真源**）
    //
    // 为什么不能只靠层里的 if-else：那只是「渲染兜底」——两个标志同时为真时它只画一个，
    // 但另一个并没有被清零；高优先级那条一关（onClose/onPick 置 false），被遮的那条会重新
    // onAppear 弹回来（「菜单关了又自己淡入」）。所以每个开菜单入口都先清其余两个，再置位。

    func openMore(at anchor: CGRect) {
        showReasoning = false
        bubble = nil
        moreAnchor = anchor
        showMore = true
    }

    func openReasoning(at anchor: CGRect) {
        showMore = false
        bubble = nil
        reasoningAnchor = anchor
        showReasoning = true
    }

    func openBubble(_ target: ChatBubbleMenuTarget) {
        showMore = false
        showReasoning = false
        bubble = target
    }

    /// 关掉全部（长按新气泡前先清场用；比逐个置 false 少漏一处）
    func closeAll() {
        showMore = false
        showReasoning = false
        bubble = nil
    }
}

/// 聊天页锚定菜单挂载层（挂在 ChatView.body 最外圈 `.overlay` 上）
///
/// 只读 `menu` → 菜单开合只重建本节点，不再连坐 ChatView 的整页 body。
/// 菜单项/标题/动作全部由宿主以闭包传入（本层不碰 chat store，避免把依赖又拉回 ChatView）。
struct ChatAnchorMenuLayer: View {
    let menu: ChatMenuState
    /// 三点菜单项（**闭包**：静态 7 条也不在宿主体里求值——那把数组每次 body 都重建一遍，
    /// 与「把菜单开销搬出 body」的方向相反）
    let moreItems: () -> [AnchorMenuItem]
    /// 三点菜单标题（**闭包**：会话上下文数字只在菜单真开着时才读，别在宿主体里求值）
    let moreTitle: () -> String
    /// 思考档位项（**闭包**：模型列表 + 当前档位只在菜单真开着时才算）
    let reasoningItems: () -> [AnchorMenuItem]
    /// 长按菜单项（依赖被长按的那条消息 → 开菜单时才算）
    let bubbleItems: (ChatMessage, String) -> [AnchorMenuItem]
    let onMorePick: (AnchorMenuItem) -> Void
    let onReasoningPick: (AnchorMenuItem) -> Void
    let onBubblePick: (AnchorMenuItem, ChatMessage, String) -> Void

    var body: some View {
        // 渲染兜底：同屏只画一个（互斥的**真源**在 ChatMenuState 的 open* 入口，那里会清零其余两个）
        if menu.showReasoning {
            AnchorMenuOverlay(anchorFrame: menu.reasoningAnchor,
                              items: reasoningItems(),
                              title: "模型思考档位",
                              onPick: onReasoningPick,
                              onClose: { menu.showReasoning = false })
        } else if menu.showMore {
            AnchorMenuOverlay(anchorFrame: menu.moreAnchor,
                              items: moreItems(),
                              title: moreTitle(),
                              onPick: onMorePick,
                              onClose: { menu.showMore = false })
        } else if let t = menu.bubble {
            AnchorMenuOverlay(anchorFrame: t.anchor,
                              items: bubbleItems(t.message, t.text),
                              title: t.message.isUser ? "你的消息" : "AI 回复",
                              onPick: { onBubblePick($0, t.message, t.text) },
                              onClose: { menu.bubble = nil })
        }
    }
}
