//
//  MessageInsertAnim.swift
//  轻聊
//
//  v4.0.40：判定「这一次可见消息缓存的重建是不是纯追加一条」——只有纯追加才配气泡插入动画。
//
//  🚨 为什么需要这个判定（2026-10-04 用户实报「气泡动画没生效」+「流式气泡沉到输入框下面」）：
//     气泡插入动画自 v3.9.31 起一直靠 ChatStore.append/upsertAssistant 里的
//     `withAnimation(Motion.enter)` 驱动，但那个事务**只包住 chat.messages 这一处写入**。
//     ChatView 真正喂给列表的不是 chat.messages，而是 @State visibleMessagesCache，
//     它由 refreshVisibleMessages() 重建 —— 而那个函数只在 onChange 回调里被调。
//     onChange 的 action 跑在**新一轮更新**里、不带任何动画上下文 → ForEach 的新行
//     直接落终态，transition 没有可插值起点，动画静默不播（无报错、无日志）。
//     本仓对同一条规律早就有过共识：流式气泡（StreamingBubbleView.born）与思考三点行
//     （thinkingIndicatorRow）都因为「没有事务 → transition 不播」而改用 @State + 自带
//     withAnimation；唯独消息气泡还在指望 ChatStore 的事务传下来。
//
//  ⚠️ 为什么不能无脑给整段重建加动画（v3.9.31 的批量移除闪退）：
//     整组替换 / 清空 / 切会话也都会走到 refreshVisibleMessages，那些路径**绝不能**播
//     spring 插入动画（当年「全 cell 同时移除」触发过 SIGTRAP 闪退）。
//     所以动画只在「旧 id 序列是新的严格前缀、且恰好多一条」这一种形态下开，
//     其余（等长替换、变短、换会话整组替换）一律不播。
//
//  ✅ 首条消息（prev 为空）**要播**（v4.0.40 定档）：
//     用户实报「气泡动画没生效」时，第一句新消息恰好走 prev=[] → next=[一条]，
//     若按「换会话从 0 条到 1 条不播」处理，用户第一次发消息看到的仍是「毫无动画」，
//     观感上等于没修。这里返回 true，让首条与后续每一条同口径。
//     安全边界不变：v3.9.31 那次闪退是「**全 cell 同时移除**」，与「新增一条」不同构。
//
//  为什么单独抽一个文件：本仓规矩「新写的纯计算函数先落真值表编译跑一遍再推 CI」，
//  真值表只能用 swiftc 编译纯源码（混进 SwiftUI 就编不过）。
//  单测：scripts/ql_bubbleanim/truth_table_bubbleanim.swift 的 B6c 段（同表共用 ChatView 源）。
//
//

import Foundation

enum MessageInsertAnim {

    /// 纯追加判定：传入重建前后的可见消息 id 序列，返回这次重建是否**只**新增了一条、
    /// 且既有条目顺序与身份完全没动。
    ///
    /// - Parameters:
    ///   - prev: 重建前可见窗口的 id 序列（旧会话/旧筛选结果，顺序即渲染顺序）
    ///   - next: 重建后可见窗口的 id 序列
    /// - Returns: true = 纯追加一条，可以播插入动画；false = 其它形态，一律不播。
    static func isSingleAppend(prev: [String], next: [String]) -> Bool {
        // 形态 ①（窗口未饱和）：长度恰好多一条，且旧序列是新序列的严格前缀。
        if next.count == prev.count + 1 {
            for (i, id) in prev.enumerated() where next[i] != id { return false }
            return true
        }
        // 形态 ②（窗口已饱和，v4.0.41 修）：可见窗口上限是 displayLimit=300（ChatView.visibleMessageCount），
        // 会话超过 300 条后 start 会随 count 前移 —— 每追加一条，窗口同时「左移一格 + 末尾多一条」，
        // 于是 next.count == prev.count == 300。只认形态 ① 的话，**第 301 条起插入动画恒不播**，
        // 而长会话恰恰是用户发消息最频繁的场景（真机观感 = 「修复没生效」）。
        // 放宽口径：等长时，唯一合法形态 = prev 去掉首条 == next 去掉末条（即只新增末尾一条、
        // 无任何移除、无重排）。这条不含移除 → v3.9.31「全 cell 同时移除 SIGTRAP」的闸门不受影响。
        guard next.count == prev.count, !next.isEmpty else { return false }
        for i in 0..<(next.count - 1) where next[i] != prev[i + 1] { return false }
        return true
    }
}
