//
//  ChatScrollPin.swift
//  轻聊
//
//  v4.0.36：聊天页「贴底（pinned）」状态推进的纯函数——聊天页流式期间要不要跟着滚底，全看它。
//
//  为什么单独抽一个文件：本仓规矩「新写的纯计算先落真值表编译跑一遍再推 CI」，
//  而真值表只能用 swiftc 编译纯源码（混进 SwiftUI 依赖就编不过）→
//  单测见 scripts/ql_scrollpin/truth_table_scrollpin.swift，权威入口是 check_swift.sh 第 63 段。
//
//  🚨 它替掉的那个形态（2026-10-03 用户实报「流式最新文字一路沉到输入栏下面、气泡不往上顶」）：
//     原实现直接拿 GeometryProxy 算一个 Bool「现在在不在底部」就赋值给 pinned ——
//     分不清「谁让内容不在底部」。流式每来一段 delta，内容就长高几十 pt，而**同一帧里 offset 还没动**
//     （滚底挂在 stream.content 的 onChange 上，onScrollGeometryChange 可能先跑），
//     于是第一段 delta 就把 pinned 判成 false → 之后每段都被 `guard scrollPinState.pinned` 挡掉、
//     自动滚底当场熄火，气泡只能在输入栏下面继续长（越到后面越明显）。
//
//  ⚠️ 为什么状态不能只是一个 Bool（本版第二轮：审查实踩）：解除贴底若只比**单帧**增量
//     （`offset < prevOffset - 1`），用户以 <1pt/帧 慢速上滑时（60Hz ≈ 60pt/s 以内）
//     每一帧都够不到阈值 → 永远解除不了，流式 delta 一到照样把人拽回底部。
//     所以这里记**贴底基准 offset**，按「当前 offset 相对基准减少了多少」判**累计**回滚量：
//     内容变高（offset 同帧不动）差值为 0 → 保持贴底（修掉上面那个事故）；
//     用户往回滚（再慢也算）累计超过阈值 → 解除（不抢用户）。
//
//  用户上翻阅读历史时流式 delta 依旧不会把人拽回底部（v3.0.86 的口径不变）。
//

import Foundation

/// 贴底状态：不只是「在不在底部」，还要记住**贴底基准 offset**（见文件头「为什么要基准」）。
struct ChatScrollPinState: Equatable {
    /// 是否贴底（= 流式 delta 允许自动滚底）
    var pinned: Bool
    /// 贴底基准 offset：贴着底部那一刻的 contentOffset.y。
    /// 用户的回滚量 = 基准 − 当前 offset（累计口径，不看单帧增量）。
    /// `0` = 无基准（不满一屏 / 未贴底时重置；内容极短时基准本就是 0，语义自洽）。
    var baseline: CGFloat

    static let pinnedAtBottom = ChatScrollPinState(pinned: true, baseline: 0)
    static let unpinned = ChatScrollPinState(pinned: false, baseline: 0)
}

enum ChatScrollPin {

    /// 贴底判定容差（pt）。与 v3.0.86 以来的口径一致：差 8pt 以内都算到底。
    static let tolerance: CGFloat = 8

    /// 解除贴底所需的最小**累计**回滚量（pt）：
    /// 回弹/抖动常常只有零点几 pt，不能算「用户离开底部」。
    static let backScrollThreshold: CGFloat = 1

    /// 推进贴底状态。
    ///
    /// - Parameters:
    ///   - state: 当前状态（本函数的上一轮返回值）
    ///   - offset: 本次 contentOffset.y
    ///   - contentH: 内容高度（contentSize.height）
    ///   - containerH: 可视高度（containerSize.height）
    /// - Returns: 新的贴底状态
    static func next(state: ChatScrollPinState,
                     offset: CGFloat,
                     contentH: CGFloat,
                     containerH: CGFloat) -> ChatScrollPinState {
        // ① 内容不满一屏：永远算贴底（列表由 minHeight 底部对齐兜住，流式增长时气泡自然往上顶）
        if contentH <= containerH { return .pinnedAtBottom }
        let maxY = contentH - containerH
        // ② 已到（或越过）底部：容差内也算；顺手把基准挪到当前位置
        //    （「贴底那一帧」的 offset 就是后面算累计回滚量的起点）
        if offset >= maxY - tolerance { return ChatScrollPinState(pinned: true, baseline: offset) }
        // ③ 本来就没贴底：保持不贴底（用户在看历史，流式 delta 不许把人拽回来）
        if !state.pinned { return .unpinned }
        // ④ 贴底中、但已离开底部（内容变高 / 用户回滚都可能走到这）：
        //    按**累计**回滚量判定 ——
        //    · 内容变高：基准不动、offset 也不动 ⇒ 差值 0 ⇒ 保持贴底（原事故的修法）；
        //    · 用户回滚：含每帧不足 1pt 的慢速拖拽，累计超过阈值即解除。
        //    基准缺失（=0）说明状态是从「不满一屏」直接长过来的，以当前 offset 起算。
        let base = state.baseline > 0 ? state.baseline : offset
        if base > offset + backScrollThreshold { return .unpinned }
        // 基准只跟着「更靠下」的位置上移：回滚量从最高点起算，小幅来回抖动不会被反复原谅
        return ChatScrollPinState(pinned: true, baseline: max(base, offset))
    }
}
