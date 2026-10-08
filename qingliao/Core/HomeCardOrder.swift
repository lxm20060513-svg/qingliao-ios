//
//  HomeCardOrder.swift
//  轻聊
//
//  v4.0.8：聊天首页「方块卡片」的**纯逻辑**（无 SwiftUI / UIKit 依赖）
//  —— 排序归一化、拖拽落位几何、启用开关、2 列分行。
//
//  为什么单独一个文件：本仓规矩「任何新写的纯计算函数先落真值表编译跑一遍再推 CI」
//  （scripts/ql_chat_home/truth_table_homecards.swift），而真值表只能用 swiftc 编译单文件，
//  混进 SwiftUI 依赖就编不过。
//
//  版式口径（= 用户 2026-09-29 拍板的 B3 稿）：**2 列等宽方块**，默认在末尾带 1 个
//  「空槽位」引导卡（点它打开卡片库添加）。不做宽卡特例 —— 有宽卡会让行高与命中区
//  分叉、拖拽几何要多算一套，还与定稿不一致。
//  ⚠️ v4.0.9（用户拍板）：**空槽位不再是「固定项」，可以关**——关掉后首页不渲染它；
//  「添加卡片」的入口仍由页头「自定义」胶囊承担（它始终在），所以关掉不会让用户失去添加路径。
//
//  持久化口径（UserDefaults，由视图层写入，这里只做纯函数）：
//  · "qingliao_home_card_order" = 逗号分隔的 kind 串（用户拖拽后的顺序）
//  · "qingliao_home_card_off"  = 逗号分隔的 kind 串（被关掉的卡片；空串 = 一个都没关）
//  ⚠️ 顺序串里的未知 kind 一律丢弃（老版本删卡/改名不会让老用户首页崩掉）；
//     缺失的 kind 自动补到末尾并保持 catalog 默认先后 —— 升级加新卡不必重置用户排序。
//

import Foundation

/// 首页卡片种类（唯一定义处；UI 标题/图标/取数都按这个 id 分发）
enum HomeCardKind: String, CaseIterable {
    case mail         // 查询新邮件
    case resume       // 继续上次会话
    case todo         // 今日待办
    case weather      // 天气
    case expense      // 记一笔（本月账目）
    case agentTip     // agent 主动推荐
    // v4.0.29 候选池批次：十张新卡（数据全部走既有 Store/后端，零新接口）
    case nextReminder // 下一提醒（本地 QuickReminderStore）
    case memo         // 备忘速记（MemoStore）
    case express      // 快递在途（/api/life/cards）
    case stock        // 关注行情（/api/life/cards）
    case kb           // 知识库问答（/api/kb/list）
    case scene        // 家庭场景（/api/scenes/list）
    case device       // 设备状态（/api/hw/status）
    case cloud        // 云盘（/api/agent/clouddrive/drives）
    case goal         // 今日目标（GoalStore）
    case clipboard    // 剪贴板（轻点那一刻才读，不在渲染期读 —— 避免首页弹系统粘贴提示）
    case custom       // 空槽位 → 打开卡片库添加（钉在末尾、不参与拖拽；可关，关掉即不渲染）

    /// 默认展示顺序（= 目录顺序，拖拽前 / 新用户口径）
    static var catalogOrder: [HomeCardKind] { allCases }

    /// 参与拖拽的卡片（空槽位不进拖拽流）
    static var draggable: [HomeCardKind] { allCases.filter { $0 != .custom } }
}

/// 纯逻辑入口（一律 static，无实例状态）
enum HomeCardOrder {

    // MARK: - 归一化

    /// 把「用户存的顺序串 + 关掉的串」归一化成最终渲染用的 kind 列表。
    /// - Parameters:
    ///   - rawOrder: 逗号分隔的 kind 串（可空 / 可含未知项 / 可重复）
    ///   - rawOff:   逗号分隔的「关掉」kind 串（空串 = 没关任何一张；v4.0.9 起 `custom` 也可在里面）
    static func resolve(order rawOrder: String, off rawOff: String) -> [HomeCardKind] {
        let off = parse(rawOff)
        let seen = parse(rawOrder)
        var out: [HomeCardKind] = []
        for k in seen where !out.contains(k) { out.append(k) }                     // 去重 + 丢未知
        for k in HomeCardKind.catalogOrder where !out.contains(k) { out.append(k) } // 补全新卡
        return atLeastOne(out.filter { !off.contains($0) })
    }

    /// 单串解析：空字段 / 未知项 / 重复项全部在这里被吃掉
    static func parse(_ raw: String) -> [HomeCardKind] {
        raw.split(separator: ",")
            .compactMap { HomeCardKind(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
    }

    /// 序列化成 UserDefaults 串（空列表写空串，不写哨兵 —— 「顺序」没有全关语义）
    static func encode(_ kinds: [HomeCardKind]) -> String {
        kinds.map(\.rawValue).joined(separator: ",")
    }

    // MARK: - 编辑操作（拖拽换位 / 开关）

    /// 拖拽落位：把 `kind` 从原位移到 `target` 下标（夹紧到合法范围，out-of-range 不崩）
    static func move(_ kinds: [HomeCardKind], kind: HomeCardKind, to target: Int) -> [HomeCardKind] {
        guard let from = kinds.firstIndex(of: kind) else { return kinds }
        let dest = min(max(target, 0), kinds.count - 1)
        guard from != dest else { return kinds }
        var out = kinds
        let item = out.remove(at: from)
        out.insert(item, at: dest)
        return out
    }

    /// 开关落位。⚠️ 入参与返回值都是**被关掉的卡列表（off）**，不是「启用列表」——
    /// 调用点（HomeCardEditorSheet）的绑定口径是 `get: !off.contains(k)` / `set: 传 newVal`，
    /// 所以 `on == true` 表示「用户要把这张卡打开」→ 必须从 off 里**移除**。
    /// （反着写会让开关完全反向：想开卡结果关掉、想关卡没反应 —— 真机开关一测就露，
    ///   但真值表不钉住就没人拦；见本表「开关方向不许反」。）
    /// 关闭后卡不参与渲染，但仍**留在顺序串里**（重开时回原位，不排到最后 ——
    /// 用户排序的心智不能因为关一次就被打乱）。
    /// ⚠️ 至少留一张**真卡**：`custom` 空槽位不算卡（关掉它也不救场），全关会让首页只剩一个
    /// 「空槽位」，用户会当成 App 坏了（真值表钉住）→ 关到只剩最后一张真卡时直接拒关（返回原值）。
    /// v4.0.9：`custom` 自己**可关**（用户拍板「固定的空槽位可以关掉」）—— 它不再走特殊分支，
    /// 与其余 6 张卡共用同一套「关掉就进 off」的流程。
    static func setEnabled(_ off: [HomeCardKind], _ kind: HomeCardKind, on: Bool) -> [HomeCardKind] {
        if on {
            return off.filter { $0 != kind }        // 打开 = 从 off 移除（不在里面也幂等）
        }
        guard !off.contains(kind) else { return off }
        // ⚠️ 这里**不再**给 `custom` 开小灶（v4.0.9 之前有一道「空槽位直接原样返回」的守卫）：
        // 用户要求空槽位也能关。下面这道「至少留一张真卡」的守卫不含 `custom`（draggable 已排除它），
        // 所以「关掉空槽位 + 关掉 5 张真卡」仍会被拦下，首页不会变成一张卡都没有。
        let next = off + [kind]
        guard HomeCardKind.draggable.contains(where: { !next.contains($0) }) else { return off }
        return next
    }

    /// 全部关掉时的兜底：至少留「继续上次会话」一张（否则首页空了，用户以为 App 坏了）
    static func atLeastOne(_ kinds: [HomeCardKind]) -> [HomeCardKind] {
        kinds.isEmpty ? [.resume] : kinds
    }

    // MARK: - 排版（2 列方块网格）

    /// 每行两张；末尾落单的补 nil 占位（UI 侧渲染透明块撑满第二列）。
    static func rows(_ kinds: [HomeCardKind], columns: Int = 2) -> [[HomeCardKind?]] {
        guard !kinds.isEmpty, columns > 0 else { return [] }
        var out: [[HomeCardKind?]] = []
        var rest = kinds
        while rest.count >= columns {
            out.append(Array(rest.prefix(columns)))
            rest.removeFirst(columns)
        }
        if !rest.isEmpty {
            var last: [HomeCardKind?] = rest
            while last.count < columns { last.append(nil) }
            out.append(last)
        }
        return out
    }

    // MARK: - 拖拽落位几何（UI 侧唯一算法源）

    /// 手指从某张卡拖出后，实时算出「松手它该落到第几号槽」。
    /// 2 列等宽网格：横向跨 1 列 = 半个卡宽；纵向跨 1 行 = 一个行高（= 2 个槽）。
    /// 口径是**相对位移**（从 from 出发偏几格），不是绝对格 —— 绝对格会让「点 3 号卡微抖一下
    /// 就变成落到 0 号」这种手感崩掉（真值表抓过）。
    /// @param from: 被拖卡片当前下标（0 起，落在可拖拽列表里）
    /// @param dx:  累计水平位移（pt）
    /// @param dy:  累计垂直位移（pt）
    /// @param cellWidth: 单格等效宽（含 gap 摊平，pt）
    /// @param rowHeight: 行高等效高（含 gap 摊平，pt）
    /// @param count: 可拖拽卡片总数
    static func dragTarget(from: Int, dx: Double, dy: Double,
                           cellWidth: Double, rowHeight: Double, count: Int) -> Int {
        guard count > 0, from >= 0, from < count, cellWidth > 0, rowHeight > 0 else { return from }
        // 纵向：半行阈值 → 偏几行（0 起）
        var row = 0
        if dy >= rowHeight / 2 { row = Int((dy + rowHeight / 2) / rowHeight) }
        else if dy <= -rowHeight / 2 { row = Int((dy - rowHeight / 2) / rowHeight) }
        // 横向：半列阈值 → 偏几列（左右各允许偏一列）
        var col = 0
        if dx >= cellWidth / 2 { col = 1 }
        else if dx <= -cellWidth / 2 { col = -1 }
        return min(max(from + row * 2 + col, 0), count - 1)
    }

    // MARK: - 写回（保位：被关掉的卡必须留在原槽位）

    /// 把「新的可见顺序」合回「完整顺序」（含被关掉的卡）。
    /// 做法：按**旧完整顺序**的槽位逐格走，可见槽取新顺序的下一项、隐藏槽原样保留 ——
    /// 这样关掉的卡重开时精确回到原来的位置（追加到末尾是错的做法，用户会感到「位置被重置」）。
    /// - Parameters:
    ///   - oldFull: 写回前的完整顺序（catalog 全量，含被关的）
    ///   - newVisible: 拖拽后的可见顺序
    ///   - off: 被关掉的卡
    static func mergeVisible(oldFull: [HomeCardKind],
                             newVisible: [HomeCardKind],
                             off: [HomeCardKind]) -> [HomeCardKind] {
        var pool = newVisible.filter { !off.contains($0) }
        var out: [HomeCardKind] = []
        out.reserveCapacity(oldFull.count)
        for k in oldFull {
            if off.contains(k) {
                out.append(k)          // 隐藏槽：原位不动
            } else if !pool.isEmpty {
                out.append(pool.removeFirst())
            } else {
                out.append(k)          // 可见卡比槽位少（理论上不会发生）→ 兜底留原值
            }
        }
        // oldFull 之外新增的卡（版本升级加的新卡）补到末尾
        for k in newVisible where !out.contains(k) { out.append(k) }
        return out
    }
}

// MARK: - agentTip 副标题口径（纯 Foundation，真值表直接编译这份）

/// v4.0.10 真机坏形修复：**卡片副标题恒单行**。
///
/// 坏形长这样：记忆里第一条是「AI 生成输出回复时不要回复…」这类 20+ 字的行为规则，
/// 旧写法无脑 `prefix(16)` 后折成两行 → 卡内容 ~94pt 顶在 84pt 的槽位里，
/// ZStack 居中溢出，真机看就是「这张卡比同排那三张高一块」。
///
/// 所以这里定死口径（视图层只管渲染，不再各写一份截断）：
///   · 只挑**短且单行**的条目当语境 —— 超长 / 含换行 / 空条目一律不配；
///   · 命中的条目再截到 `memoryMaxChars`，加上前缀一行放得下（156pt 宽、11pt 字号 ≈ 14 汉字）；
///   · 一条都不合规 → 返回 nil，调用方退回建议池短句（卡面永不空着）。
enum HomeCardTipKit {
    static let memoryPrefix = "记得："
    /// 语境正文最多几个字（连同前缀 3 字 + 可能的省略号 1 字 = 12 字上限）
    static let memoryMaxChars = 8
    /// 整条超过这个长度就不配当卡面副标题（行为规则类条目动辄 20+ 字）
    static let memoryAcceptLimit = 12

    /// 挑一条「能一行放下」的记忆当语境；nil = 没有合规条目
    static func memoryLine(entries: [String]) -> String? {
        let picked = entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.contains("\n") && $0.count <= memoryAcceptLimit }
        guard let t = picked else { return nil }
        return t.count > memoryMaxChars ? String(t.prefix(memoryMaxChars)) + "…" : t
    }

    /// 卡面副标题：合规记忆 → 「记得：xxx」，否则池内短句
    static func subtitle(memory: String?, pool: String) -> String {
        guard let m = memory else { return pool }
        return memoryPrefix + m
    }
}

// MARK: - 持久化键（单一真源，视图与真值表共用同一份字符串）

enum HomeCardStore {
    static let orderKey = "qingliao_home_card_order"
    static let offKey = "qingliao_home_card_off"

    /// v4.0.10（用户：「在设置里增加可以关掉首页快捷卡片功能」）：首页快捷卡片**总开关**。
    ///
    /// 语义照抄 v4.0.9 的震动开关（Core/Haptics.swift `enabledKey`）：**键缺失 = 开**
    /// —— 老用户升级后行为不变，不写迁移、不落默认值。
    /// ⚠️ 别用 `UserDefaults.bool(forKey:)`：它把「没设过」和「设过且关」都当 false，
    /// 新装用户首页会莫名空白（同族坑见 ql_homeshortcuts 表 ④ 的 off 哨兵）。
    /// 读取一律走这个常量（`@AppStorage(HomeCardStore.enabledKey)`），
    /// 字面量全仓只保留在**本文件**（真值表钉住）。
    static let enabledKey = "qingliao_home_card_enabled"

    /// 默认值单一真源：设置页与聊天页两处 `@AppStorage` 都写 `= HomeCardStore.enabledDefault`
    /// —— 别各写一个 `true`，否则将来改默认会漏改一处（这类漂移本仓吃过亏）。
    static let enabledDefault = true

    /// 落位几何：2 列网格里单格高（pt）—— 视觉与拖拽命中区共用这一个值，别各写一份
    static let cardHeight: CGFloat = 84
    static let gap: CGFloat = 9

    /// 当前「被关掉」的集合 —— **读取路径的单一真源**（视图侧别再各写一份 parse）。
    /// · 键不存在 = 用户从没动过开关 → 走默认档（首屏 4 张）；否则 7 张 2 列 = 4 行约 370pt，
    ///   竖屏首页塞不下，会把宠物与问候语挤没
    /// · v4.0.9：空槽位 `custom` **也可关**（用户拍板）→ 不再从 off 里强制剔掉它；
    ///   「添加卡片」入口由页头「自定义」胶囊兜底（那个胶囊恒在），不会失联
    /// · 6 张真卡被全关（老数据 / 手改）→ 兜底放回 resume，否则首页只剩一个空槽位，
    ///   用户会当成 App 坏了（与 setEnabled 的「拒关最后一张」同一口径）
    static var off: [HomeCardKind] {
        // ⚠️ 必须区分「键不存在」与「键存在但为空串」：前者 = 从没动过开关 → 默认档；
        // 后者 = 用户把卡片全开了 → 听用户的（哨兵口径，丢了这两行的区别就是首屏口径错乱）。
        let stored = UserDefaults.standard.string(forKey: offKey)
        let raw = HomeCardOrder.parse(stored ?? HomeCardOrder.encode(defaultOff))
        let kept = HomeCardKind.draggable.filter { !raw.contains($0) }
        return kept.isEmpty ? raw.filter { $0 != .resume } : raw
    }

    /// 完整顺序（catalog 全量，**含被关掉的卡**）—— 拖拽写回的 oldFull 必须用它：
    /// 关掉的卡才能留在原槽、重开回原位。⚠️ 若拿「已过滤的渲染列表」当 oldFull，
    /// 用户新开一张卡后它不在 full 里 → 开了却看不见（真值表钉住）。
    static var fullOrder: [HomeCardKind] {
        HomeCardOrder.resolve(order: UserDefaults.standard.string(forKey: orderKey) ?? "", off: "")
    }

    /// 当前渲染列表（= 完整顺序 - 被关掉的；空槽位可见时钉在末尾）
    /// ⚠️ v4.0.9：空槽位被关掉时**不再补回**（旧实现无条件 `base + [.custom]`，等于把 off 里的
    /// custom 无视掉 —— 那正是「固定的空槽位关不掉」的真正根因）。
    static var kinds: [HomeCardKind] {
        let base = HomeCardOrder.resolve(
            order: UserDefaults.standard.string(forKey: orderKey) ?? "",
            off: HomeCardOrder.encode(off))
        if off.contains(.custom) { return base }
        return base.contains(.custom) ? base : base + [.custom]
    }

    /// 默认关掉的卡（= 收起进「自定义」里的）
    /// 为什么不全开：全量 2 列行数太多，竖屏首页塞不下，会把宠物与问候语挤没。
    /// 首屏（继续上次 / 新邮件 / agent 推荐）覆盖 80% 的开屏意图，其余按需打开。
    /// v4.0.29：十张新卡**默认全关**（卡片目录到 17 项，新卡不挤占老用户首屏；
    /// resolve 的「缺失 kind 自动补尾」保证老用户升级后排序不重置，想要哪张自己来「自定义」开）。
    static let defaultOff: [HomeCardKind] = [
        .todo, .weather, .expense,
        .nextReminder, .memo, .express, .stock, .kb, .scene, .device, .cloud, .goal, .clipboard,
    ]

    /// 写回（order 必须含被关掉的卡，否则重开后位置会漂）
    static func persist(order: [HomeCardKind], off: [HomeCardKind]) {
        UserDefaults.standard.set(HomeCardOrder.encode(order), forKey: orderKey)
        UserDefaults.standard.set(HomeCardOrder.encode(off), forKey: offKey)
    }
}


// MARK: - 卡片上「轻点执行」与「长按拖动」的争抢判定（纯逻辑，真值表直接测）

/// v4.0.10 二修（用户真机报「agent 主动推荐卡片点了没反应」）：
/// 卡片上「轻点干活」和「长按拖动」抢的是**同一次按压**。判定口径收在这里，
/// 视图只喂数据 —— 别再靠手感调 `minimumDuration`/阈值，那些值真机一改就翻车。
enum HomeCardDragKit {
    /// 长按成立门槛（秒）。0.28 太短：用户「按久一点再松手」的慢点击会被算进拖动会话、
    /// 轻点被吞 → 真机表现就是「点了没反应」。提到 0.40（贴近 iOS 惯例），
    /// 让慢点击留在轻点域、真正的长按仍能拖动。
    static let longPressSeconds: Double = 0.40

    /// 「真拖动」位移阈值（pt，任一方向）。小于它 = 手指只是按住没动 → **不算拖动**：
    /// 松手必须照常执行轻点。这是「点了没反应」的根治点
    /// （旧实现「长按一成立就上闩」，等于把所有慢点击都吞掉）。
    static let moveThreshold: Double = 6

    /// 拖完之后的闩窗（秒）：挡住 Button 松手补送的那次轻点，避免「拖一次跳一次」。
    static let latchWindow: TimeInterval = 0.8

    /// 这一点位移算不算「真的在拖」
    static func isRealDrag(dx: Double, dy: Double) -> Bool {
        max(abs(dx), abs(dy)) >= moveThreshold
    }
}
