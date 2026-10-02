//
//  BoardCardOrder.swift
//  轻聊
//
//  v4.0.20：看板（Dashboard）栏目卡片「长按拖动排序」的**纯逻辑**
//  （无 SwiftUI / UIKit 依赖）—— 顺序串归一化、垂直拖拽落位几何、写回保位。
//
//  为什么单独一个文件：本仓规矩「任何新写的纯计算函数先落真值表编译跑一遍再推 CI」
//  （scripts/ql_board/truth_table_board.swift），而真值表只能用 swiftc 编译单文件，
//  混进 SwiftUI 依赖就编不过。`BoardCard` 枚举也一并搬到这里
//  —— 它原本在 Features/Dashboard/BoardCardEditor.swift（那个文件 import SwiftUI），
//  真值表没法编它。枚举本身是纯的（Foundation 的 Identifiable 即可），搬过来零副作用。
//
//  持久化口径（UserDefaults，由视图层写入，这里只做纯函数）：
//  · "dashboard_card_order"  = 逗号分隔的 BoardCard.rawValue（用户拖拽后的顺序）
//  · "dashboard_hidden_cards"= 逗号分隔的 BoardCard.rawValue（被隐藏的栏目；空串 = 一个都没隐藏）
//  ⚠️ 这两个键是 v3.9.40（#15）起 `BoardCardEditorSheet` 就在用的**同一对键** ——
//     本文件只是把它们收成单一真源常量（同 HomeCardStore 的做法），**不新造键**。
//  ⚠️ 顺序串里的未知键一律丢弃（老版本删卡/改名不会让老用户看板崩掉）；
//     缺失的 key 自动补到末尾并保持 catalog 默认先后 —— 升级加新栏目不必重置用户排序。
//

import Foundation

/// 看板栏目（唯一定义处；标题/取数/排序都按这个 id 分发）
enum BoardCard: String, CaseIterable, Identifiable {
    case suggestion, home, scenes, automations, rules, nas, usage, tokens, diagnose, router, pin, connectors

    var id: String { rawValue }

    /// 与各 block 的 sectionTitle 保持一致（新增 case 时两处一起改）
    var title: String {
        switch self {
        case .suggestion: return "智能建议"
        case .home: return "智能家居"
        case .scenes: return "智慧场景"
        case .automations: return "自动化"
        case .rules: return "自动规则"
        case .nas: return "NAS 面板"
        case .usage: return "模型使用量"
        case .tokens: return "token 用量"
        case .diagnose: return "设备体检"
        case .router: return "路由器"
        case .pin: return "钉一钉"
        case .connectors: return "连接器"
        }
    }
}

/// 纯逻辑入口（一律 static，无实例状态）
enum BoardCardOrder {

    // MARK: - 归一化

    /// 单串解析：空字段 / 未知键 / 重复键全在这里被吃掉，且**保序去重**。
    /// 视图层读 `dashboard_card_order` 只走它（别各写一份 parse）。
    static func parse(_ raw: String) -> [BoardCard] {
        var seen = Set<BoardCard>()
        return raw.split(separator: ",")
            .compactMap { BoardCard(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { seen.insert($0).inserted }
    }

    /// 序列化：`[BoardCard] -> 逗号分隔串`（空列表写空串，不写哨兵 —— 「顺序」没有全空语义）。
    /// `BoardCardEditorSheet.persist` 与拖拽写回共用这一份（别各拼一次 join）。
    static func encode(_ cards: [BoardCard]) -> String {
        cards.map(\.rawValue).joined(separator: ",")
    }

    /// 完整顺序：已存顺序在前（去重 + 丢未知键），串里没出现的按 catalog 默认先后补到末尾。
    /// 口径 = v3.9.40 起 DashboardView.orderedCards 的原实现（SR13 那层「脏值自愈」也一并搬来）。
    /// ⚠️ 返回的是**完整**顺序（含被隐藏的栏目）—— 拖拽写回拿它当 oldFull，
    ///    隐藏的栏目才能留在原槽、重新显示时回原位。
    static func resolve(order raw: String) -> [BoardCard] {
        let seen = parse(raw)
        return seen + BoardCard.allCases.filter { !seen.contains($0) }
    }

    // MARK: - 编辑操作（拖拽换位）

    /// 拖拽落位：把 `card` 从原位移到 `target` 下标（夹紧到合法范围，越界不崩）。
    /// 语义 = 「先摘除再插入」—— 与 `dragTarget` 返回的下标口径一致（那正是「除自己外、
    /// 中心在我上方」的计数 = 摘除后的插入下标）。
    static func move(_ cards: [BoardCard], kind: BoardCard, to target: Int) -> [BoardCard] {
        guard let from = cards.firstIndex(of: kind) else { return cards }
        let dest = min(max(target, 0), cards.count - 1)
        guard from != dest else { return cards }
        var out = cards
        let item = out.remove(at: from)
        out.insert(item, at: dest)
        return out
    }

    // MARK: - 垂直拖拽落位几何（UI 侧唯一算法源）

    /// 看板栏目是**不等高**的竖排块（「钉一钉」空态才几十 pt，「NAS 面板」几百 pt），
    /// 所以落位**不能**照搬首页 2 列网格那套「按格算」—— 必须喂各栏目的**实测高度**。
    ///
    /// 算法：先在静止布局里算出每个栏目的竖直中心（顶边 offset + 自身高的一半），
    /// 被拖栏目的中心随手指下移 `dy`；落位下标 = **除自己外、中心落在它上方**的栏目个数
    /// （= 在「摘除自己」后的列表里应插入的下标）。
    ///
    /// - Parameters:
    ///   - from:    被拖栏目当前下标（落在可见列表里，0 起）
    ///   - dy:      累计垂直位移（pt，向下为正）
    ///   - heights: 各可见栏目的实测高度（与可见顺序同序）
    ///   - spacing: 栏目间距（LazyVStack spacing）
    static func dragTarget(from: Int, dy: Double, heights: [Double], spacing: Double) -> Int {
        let n = heights.count
        guard n > 0, from >= 0, from < n else { return from }
        // 静止布局：offsets[i] = 第 i 个栏目顶边 y；中心 = offset + 高度/2
        var offsets: [Double] = []
        offsets.reserveCapacity(n)
        var acc = 0.0
        for h in heights {
            offsets.append(acc)
            acc += h + spacing
        }
        let dragCenter = offsets[from] + heights[from] / 2 + dy
        var target = 0
        for i in 0..<n where i != from {
            if offsets[i] + heights[i] / 2 < dragCenter { target += 1 }
        }
        return min(max(target, 0), n - 1)
    }

    // MARK: - 写回（保位：被隐藏的栏目必须留在原槽）

    /// 把「新的可见顺序」合回「完整顺序」（含被隐藏的栏目）。
    /// 做法：按**旧完整顺序**的槽位逐格走，可见槽取新顺序的下一项、隐藏槽原样保留 ——
    /// 这样隐藏的栏目重新显示时精确回到原来的位置（追加到末尾是错的做法，用户会感到「位置被重置」）。
    /// - Parameters:
    ///   - oldFull:    写回前的完整顺序（含被隐藏的；= `resolve(order:)` 的结果）
    ///   - newVisible: 拖拽后的可见顺序
    ///   - hidden:     被隐藏的栏目
    static func mergeVisible(oldFull: [BoardCard],
                             newVisible: [BoardCard],
                             hidden: Set<BoardCard>) -> [BoardCard] {
        var pool = newVisible.filter { !hidden.contains($0) }
        var out: [BoardCard] = []
        out.reserveCapacity(oldFull.count)
        for c in oldFull {
            if hidden.contains(c) {
                out.append(c)          // 隐藏槽：原位不动
            } else if !pool.isEmpty {
                out.append(pool.removeFirst())
            } else {
                out.append(c)          // 可见卡比槽位少（理论上不会发生）→ 兜底留原值
            }
        }
        // oldFull 之外新增的栏目（版本升级加的新卡）补到末尾
        for c in newVisible where !out.contains(c) { out.append(c) }
        return out
    }

    // MARK: - 手势口径（长按门槛 + 真拖动阈值）

    /// 长按成立门槛（秒）。太短会把「按久一点的慢点击」算进拖动会话
    /// （本仓 v4.0.10 在首页卡片上踩过：真的长按门槛 0.28 秒让慢点击被吞）。
    /// 0.40 贴近 iOS 惯例。
    static let longPressSeconds: Double = 0.40

    /// 「真拖动」位移阈值（pt，任一方向）。小于它 = 手指只是按住没动 → **不算拖动**：
    /// 松手不该换位（与首页卡片同一口径）。
    static let moveThreshold: Double = 6

    /// 这一点位移算不算「真的在拖」
    static func isRealDrag(dx: Double, dy: Double) -> Bool {
        max(abs(dx), abs(dy)) >= moveThreshold
    }

    // MARK: - 版式常量

    /// 看板栏目间距（LazyVStack spacing）—— 视觉与拖拽落位几何共用这一份，别各写一个 10
    static let sectionSpacing: CGFloat = 10
}

// MARK: - 持久化键（单一真源，视图与真值表共用同一份字符串）

enum BoardCardStore {
    /// v3.9.40（#15）起沿用至今的键 —— 本文件是**唯一**出现字面量的地方（真值表钉住）
    static let orderKey = "dashboard_card_order"
    static let hiddenKey = "dashboard_hidden_cards"
}
