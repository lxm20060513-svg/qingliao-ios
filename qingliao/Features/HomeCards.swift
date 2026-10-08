//
//  HomeCards.swift
//  轻聊
//
//  v4.0.8：聊天首页「方块卡片」组件（2 列等宽网格 + 长按拖拽排序 + 自定义开关）。
//  版式 = 用户 2026-09-29 拍板的 B3 稿；纯逻辑全在 Core/HomeCardOrder.swift（那里有真值表）。
//
//  v4.0.10 真机两条坏形修正（用户配图 + 原话报修）：
//   · **卡高恒定**：副标题恒单行（`lineLimit(1)`，且**禁** `.fixedSize(horizontal:false, vertical:true)`）。
//     真机坏形：记忆里第一条是 20+ 字的「AI 行为规则」，旧写法前缀 16 字后折成两行 →
//     内容 ~94pt 顶在 84pt 的槽位里，ZStack 居中溢出 → 看就是「第 4 张卡比同排那三张高一块」
//     （像素量：该卡 283px vs 同排 254px @3x）。截断/筛选口径全在 HomeCardTipKit。
//   · **长按拖动真成立**：卡片是 Button，`Button 内置手势会拦住挂在父级的长按`（本仓 v2.0.96b
//     在发送键上踩过同一个坑）→ 长按永远不成立、拖不动。正解 = `.simultaneousGesture`，
//     并让 `tap(_:)` 首行读 suppressTapUntil 挡掉松手后的误触轻点（拖动中还有描边 + 放大提示）。
//   · **慢点击照样能点**（二修真机报「agent 主动推荐卡片点了没反应」）：门闩只在**真位移 ≥ 6pt**
//     时上（`HomeCardDragKit.isRealDrag`）——「按住不动再松手」不算拖动，轻点照常执行。
//   · **栏目头「自定义」胶囊变矮**：原先借用聊天页顶栏那档 `chatHeaderPill()`（15 + 2×6 = 27pt），
//     摆在只有 11pt 文字的栏目头旁边又高又重（用户：「太大，矮一点」）→ 换 `sectionHeaderPill()`
//     （15 + 2×4 = 23pt，只压高度，字号/横内距/描边/玻璃同参）。两档都在 Theme/Pill.swift，真值表两侧都钉。
//
//  四条口径，改前先读：
//  1. **拖拽落位不自算**：位移 → 目标槽一律调 HomeCardOrder.dragTarget，UI 只负责量尺寸。
//     2 列网格里「跨一行 = 2 格」，这层换算自算必错（真值表已钉死）。
//  2. **长按才拖**，轻点仍是「执行这张卡」—— 首页卡片是主入口，不能被拖拽手势吃掉。
//  3. **写回必须走 HomeCardOrder.mergeVisible**：被关掉的卡要留在原槽，
//     直接把可见列表写回去会让「关一次 → 重开就排到最后」。
//  4. **不自己造跳转通道**：切 tab / 开天气弹窗 / 续会话 / 发问全由 ChatView 用闭包注入。
//     首页卡片是唯一调用方，它手里才有 ChatStore 与 sheet 态；自造 Notification 会出现
//     「通知发出去了但没人监听」的哑火路径。
//

import SwiftUI
import UIKit   // v4.0.29：剪贴板卡读 UIPasteboard（轻点那一刻才读）

// MARK: - 取数（一屏只打这几趟，全部走既有后端，零新接口）

/// 首页卡片的数据源。单独一个 @Observable：卡片区自己管生命周期，
/// 切 tab / 退后台不牵连聊天页重建，也不把取数逻辑塞进 ChatView（那边已经 3800 行）。
@MainActor
@Observable
final class HomeCardData {
    var mailUnread: Int?
    var mailLatest: String = ""          // "1 小时前"（后端倒序 → 是**最新**一封）
                                          // 2026-09-30 审查：原名 mailOldest 与数据口径相反，UI 标「最早」实为最新
    var weatherTemp: Double?
    var weatherCode: Int?
    var weatherText: String = ""
    var weatherCity: String = ""
    var todoOpen: Int = 0
    var monthAmount: Double = 0
    var monthCount: Int = 0
    /// v4.0.19 候选池⑬：近 7 天支出（首页卡副标题升级成「本月 + 本周」）
    var weekAmount: Double = 0
    /// v4.0.19 候选池⑦⑬：月预算（>0 = 已设，超支/接近时副标题优先报水位）
    var monthBudget: Double = 0
    var tip: HomeCardTip = .idle
    var loaded = false

    // ── v4.0.29 十张新卡的取数槽 ──
    /// 下一提醒（本地 QuickReminderStore，最近一条待触发）
    var nextReminderText: String = ""
    var nextReminderTime: Date?
    /// 备忘速记（MemoStore 最新一条）
    var memoLatest: String = ""
    /// 快递在途（/api/life/cards → LifeExpressCard）
    var expressCount: Int = -1        // -1 = 未加载/未配置
    var expressLine: String = ""
    /// 关注行情（/api/life/cards → 首只自选股）
    var stockName: String = ""
    var stockLine: String = ""        // "23.40 +2.1%"
    /// 知识库问答（/api/kb/list 文档数）
    var kbCount: Int = -1
    /// 家庭场景（/api/scenes/list 首个场景名）
    var sceneName: String = ""
    var sceneCount: Int = -1
    /// 设备状态（/api/hw/status）
    var deviceLine: String = ""
    /// 云盘（/api/agent/clouddrive/drives 就绪数）
    var cloudCount: Int = -1
    var cloudName: String = ""
    /// 今日目标（GoalStore 本地）
    var goalTotal: Int = -1
    var goalDoneToday: Int = 0
    var goalNextTitle: String = ""

    private var mailFetched = false
    private var weatherFetched = false
    private var lifeFetched = false   // 快递 + 行情同源，一趟请求
    private var kbFetched = false
    private var sceneFetched = false
    private var deviceFetched = false
    private var cloudFetched = false

    /// 卡片区出现时调一次；各自内部去重（拖拽排序会反复重画视图，别重复打后端）
    func load(auth: AuthStore) async {
        if !loaded { loaded = true; loadLocal() }
        if !mailFetched {
            mailFetched = true
            await loadMail(auth: auth)
        }
        if !weatherFetched {
            weatherFetched = true
            await loadWeather(auth: auth)
        }
        if tip == .idle { tip = await Self.loadTip(auth: auth) }
        // v4.0.29：十张新卡（按需取数，未打开的卡不打无谓请求 —— 各卡在「开」时才补拉）
        loadGoalLocal()
        loadReminderLocal()
        loadMemoLocal()
        if anyVisible(.express, .stock), !lifeFetched {
            lifeFetched = true
            await loadLifeCards(auth: auth)
        }
        if anyVisible(.kb), !kbFetched {
            kbFetched = true
            await loadKB(auth: auth)
        }
        if anyVisible(.scene), !sceneFetched {
            sceneFetched = true
            await loadScenes(auth: auth)
        }
        if anyVisible(.device), !deviceFetched {
            deviceFetched = true
            await loadDevice(auth: auth)
        }
        if anyVisible(.cloud), !cloudFetched {
            cloudFetched = true
            await loadCloud(auth: auth)
        }
    }

    /// 当前可见卡片里是否包含任一目标 kind（editor 开关变化后由 loadOnDemand 补拉）
    private var visibleKinds: Set<HomeCardKind> {
        Set(HomeCardStore.fullOrder.filter { !HomeCardStore.off.contains($0) })
    }
    private func anyVisible(_ kinds: HomeCardKind...) -> Bool {
        let vis = visibleKinds
        return kinds.contains { vis.contains($0) }
    }

    /// 「自定义」面板关掉后重开卡片区 → 补拉新开卡的数（HomeCardsGrid.task 每次出现都会调 load）
    func loadOnDemand(auth: AuthStore) async {
        if anyVisible(.express, .stock), !lifeFetched {
            lifeFetched = true
            await loadLifeCards(auth: auth)
        }
        if anyVisible(.kb), !kbFetched {
            kbFetched = true
            await loadKB(auth: auth)
        }
        if anyVisible(.scene), !sceneFetched {
            sceneFetched = true
            await loadScenes(auth: auth)
        }
        if anyVisible(.device), !deviceFetched {
            deviceFetched = true
            await loadDevice(auth: auth)
        }
        if anyVisible(.cloud), !cloudFetched {
            cloudFetched = true
            await loadCloud(auth: auth)
        }
    }

    // MARK: v4.0.29 新卡取数（全部走既有后端/Store，零新接口）

    /// 今日目标：本地 GoalStore 已同步，直接读（不打后端）
    private func loadGoalLocal() {
        let goals = GoalStore.shared.goals.filter { !$0.paused }
        guard !goals.isEmpty else { goalTotal = 0; return }
        goalTotal = goals.count
        // 「今日完成数」= 所有未暂停目标的步骤里 done=true 的条数；下一件 = 第一条未完成步骤
        var done = 0
        for g in goals {
            for s in g.steps where s.done { done += 1 }
        }
        goalDoneToday = done
        for g in goals {
            if let next = g.steps.first(where: { !$0.done }) {
                goalNextTitle = next.title
                break
            }
        }
    }

    /// 下一提醒：本地 QuickReminderStore（scheduled 已按时间升序，first = 最近要响的）
    private func loadReminderLocal() {
        guard let next = QuickReminderStore.shared.scheduled.first else { return }
        nextReminderText = next.text
        nextReminderTime = next.fireDate
    }

    /// 备忘速记：MemoStore 最新一条（memos 未排序，这里取 createdAt 最大）
    private func loadMemoLocal() {
        guard let latest = MemoStore.shared.memos.max(by: { $0.createdAt < $1.createdAt }) else { return }
        memoLatest = latest.content
    }

    /// 快递 + 行情：同源 /api/life/cards，一趟请求两张卡
    private func loadLifeCards(auth: AuthStore) async {
        guard let j = try? await auth.json("/api/life/cards") else { return }
        let d = LifeCardsData.parse(j)
        if let ex = d.express, ex.hasPackages {
            expressCount = ex.packages.count
            let undelivered = ex.packages.filter { !$0.isDelivered }
            if let first = undelivered.first {
                expressLine = "\(first.title) · \(first.statusText.isEmpty ? "在途" : first.statusText)"
            } else if let any = ex.packages.first {
                expressLine = "\(any.title) · \(any.statusText.isEmpty ? "已查询" : any.statusText)"
            }
        } else {
            expressCount = 0
        }
        if let s = d.stocks.first(where: { $0.ok }) {
            stockName = s.name
            stockLine = "\(s.priceText) \(s.changeText)"
        }
    }

    /// 知识库问答：文档数
    private func loadKB(auth: AuthStore) async {
        guard let j = try? await auth.json("/api/kb/list") else { return }
        kbCount = (j["docs"] as? [[String: Any]] ?? []).count
    }

    /// 家庭场景：首个场景名 + 总数
    private func loadScenes(auth: AuthStore) async {
        guard let j = try? await auth.json("/api/scenes/list") else { return }
        let arr = j["scenes"] as? [[String: Any]] ?? []
        sceneCount = arr.count
        sceneName = arr.first?["name"] as? String ?? ""
    }

    /// 设备状态：CPU/SSD 温度（看板同源 /api/hw/status）
    private func loadDevice(auth: AuthStore) async {
        guard let j = try? await auth.json("/api/hw/status") else { return }
        var parts: [String] = []
        if let c = j["cpu_temp"] as? Double { parts.append(String(format: "CPU %.0f°C", c)) }
        if let s = j["ssd_temp"] as? Double { parts.append(String(format: "SSD %.0f°C", s)) }
        deviceLine = parts.joined(separator: " · ")
    }

    /// 云盘：就绪盘数 + 首个昵称
    private func loadCloud(auth: AuthStore) async {
        guard let j = try? await auth.json("/api/agent/clouddrive/drives"),
              let ok = j["ok"] as? Bool, ok else { return }
        let raw = j["drives"] as? [[String: Any]] ?? []
        let items = raw.map { CloudDriveItem($0) }
        let ready = items.filter { $0.isReady }
        cloudCount = ready.count
        cloudName = ready.first?.nickname ?? ready.first?.name ?? ""
    }

    /// 待办 / 账目：本地 Store 已同步过，直接读，不打后端
    private func loadLocal() {
        todoOpen = TodoStore.shared.todos.filter { !$0.done }.count
        let t = RecordStore.shared.monthTotal
        monthAmount = t.amount
        monthCount = t.count
        weekAmount = RecordKit.recentDays(RecordStore.shared.records, days: 7).expense
        monthBudget = RecordStore.shared.monthBudget
    }

    /// 未读数 + 最新一封的相对时间（后端 list_messages 按时间**倒序**返回，first 即最新）
    /// ⚠️ 2026-09-30 审查：原 limit=5 让角标恒显「5」（未读多于 5 时失真），提到 50；
    ///    上限 99+ 由 badge() 兜底。
    private func loadMail(auth: AuthStore) async {
        guard let j = try? await auth.json("/api/mail/messages?unread=1&limit=50") else { return }
        let msgs = j["messages"] as? [[String: Any]] ?? []
        mailUnread = msgs.count
        guard let first = msgs.first,
              let dateStr = first["date"] as? String,
              let d = HomeCardData.parseMailDate(dateStr) else { return }
        mailLatest = HomeCardData.relative(d)
    }

    /// 天气：城市未设置就不显示（与看板同口径），有进程内缓存直接用
    private func loadWeather(auth: AuthStore) async {
        let city = (UserDefaults.standard.string(forKey: "qingliao_weather_city") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty else { return }
        if let hit = WeatherCache.value(city: city) {
            apply(hit)
            return
        }
        let enc = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? city
        guard let j = try? await auth.json("/api/weather?city=\(enc)") else { return }
        let s = WeatherService.parseBackend(j)
        WeatherCache.put(city: city, snap: s)
        apply(s)
    }

    private func apply(_ s: WeatherSnapshot) {
        weatherTemp = s.temp
        weatherCode = s.code
        weatherText = WeatherCode.text(s.code)
        weatherCity = s.city
    }

    /// agent 主动推荐：本地建议池打底 + 记忆里的偏好当上下文。
    /// 为什么不让模型在线生成这张卡：首页是「打开就能用」的地方，出一张空卡/转圈卡比朴素建议更糟。
    private static func loadTip(auth: AuthStore) async -> HomeCardTip {
        var entries: [String] = []
        if let j = try? await auth.json("/api/memory/list") {
            entries = j["entries"] as? [String] ?? []
        }
        return HomeCardTip.suggested(entries: entries, now: Date())
    }

    /// 后端日期是 "%Y-%m-%d %H:%M"（本地时区，见 mail_api.py list_messages）
    static func parseMailDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }

    static func relative(_ d: Date, now: Date = Date()) -> String {
        let min = Int(now.timeIntervalSince(d) / 60)
        if min < 1 { return "刚刚" }
        if min < 60 { return "\(min) 分钟前" }
        let h = min / 60
        if h < 24 { return "\(h) 小时前" }
        return "\(h / 24) 天前"
    }
}

// MARK: - agent 建议卡的内容

struct HomeCardTip: Equatable {
    var title: String
    var subtitle: String
    var prompt: String
    static let idle = HomeCardTip(title: "今天想先做什么", subtitle: "点一下直接开工",
                                  prompt: pool[0].prompt)

    /// 本地建议池（不调模型也能给出像样的默认）
    private static let pool: [(title: String, sub: String, prompt: String)] = [
        ("整理今日待办", "零散想法理成清单", "请帮我把下面的事情整理成待办清单，按优先级排序：\n"),
        ("起草今日邮件", "写好草稿我来查", "帮我起草一封今天的邮件，主题和要点我来补：\n"),
        ("复盘昨天进展", "一句话 + 下一步", "请复盘我昨天做的事，输出一句话总结和今天最该做的一件事。\n"),
        ("挑要紧的未读邮件", "只说重要的", "帮我看看最近有哪些未读邮件，挑出要紧的总结给我。\n"),
        ("本周开支小结", "看看钱花在哪", "请汇总我本周的记录支出，按类别给我一个小结和一条省钱建议。\n"),
        ("安排下周计划", "拆成可执行步骤", "请把下周要做的事拆成可执行步骤，并标出依赖关系。\n"),
    ]

    /// 按时段轮换（同一天内不变，避免用户看着卡片内容反复跳）
    static func suggested(entries: [String], now: Date) -> HomeCardTip {
        let slot = Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0
        let base = pool[abs(slot) % pool.count]
        // 记忆里有「一行放得下的短条」时，副标题带上它（「主动学习」的最小可见形态）。
        // ⚠️ v4.0.10：截断/筛选口径统一在 HomeCardTipKit —— 旧的前缀 16 字写法碰上
        //    规则型长记忆会折成两行，把这张卡撑得比同排高 10pt（真机报「大小不一样」）。
        let line = HomeCardTipKit.memoryLine(entries: entries)
        return HomeCardTip(title: base.title,
                           subtitle: HomeCardTipKit.subtitle(memory: line, pool: base.sub),
                           prompt: base.prompt)
    }
}

// MARK: - 网格主体

struct HomeCardsGrid: View {
    @Environment(AuthStore.self) private var auth

    // ↓ ChatView 注入的执行通道（本组件不自造路由，见文件头口径 4）
    /// 有可续的上一会话时给出来，轻点「继续上次会话」用
    var resumeSession: ChatSession?
    /// 打开那个会话（由 ChatView 走 chat.load，顺带该有的收口全在那边）
    var onResume: (ChatSession) -> Void
    /// 问 AI 一句话（发新消息）
    var onAsk: (String) -> Void
    /// 切到生活页（待办 / 账目）
    var onOpenLife: () -> Void
    /// 打开天气弹窗
    var onOpenWeather: () -> Void
    /// v4.0.29：切到看板（场景 / 设备状态卡的落点）
    var onOpenBoard: () -> Void
    /// v4.0.29：打开弹窗的通用通道（备忘录 / 提醒面板 / 云盘浏览等由 ChatView 挂 sheet）
    var onOpenSheet: (HomeCardKind) -> Void

    /// 完整顺序（catalog 全量，含被关掉的）—— 写回的唯一真源。
    /// ⚠️ 必须用 fullOrder（全量）而不是 kinds（渲染列表）：否则新开的卡不在 full 里 → 开了看不见。
    @State private var full: [HomeCardKind] = HomeCardStore.fullOrder
    /// 被关掉的集合。⚠️ 必须与读取路径同源（HomeCardStore.off）：键不存在时是**默认档**，
    /// 若这里直接 parse 空串 → 面板显示「三张默认关掉的卡是开的」，与首页实际渲染不一致。
    @State private var off: [HomeCardKind] = HomeCardStore.off
    @State private var data = HomeCardData()
    @State private var dragFrom: Int?
    @State private var dragOffset: CGSize = .zero
    /// v4.0.10：长按拖动成立后，Button 松手时仍会送一次「轻点」→ 用这个时间戳把它挡掉。
    /// 没有它，用户拖完卡片会顺手跳进那个会话/生活页（拖一次跳一次，比拖不动更烦）。
    @State private var suppressTapUntil: Date = .distantPast
    @State private var showEditor = false
    @State private var cellSize: CGSize = .zero

    private let gap = HomeCardStore.gap
    private let cardHeight = HomeCardStore.cardHeight

    /// 渲染用列表 = 完整顺序去掉被关的
    private var visible: [HomeCardKind] { full.filter { !off.contains($0) } }

    /// 参与拖拽的（空槽位不参与）
    private var draggable: [HomeCardKind] { visible.filter { $0 != .custom } }

    private var rows: [[HomeCardKind?]] { HomeCardOrder.rows(visible) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            GeometryReader { g in
                let cellW = (g.size.width - gap) / 2
                VStack(spacing: gap) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: gap) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, kind in
                                slot(kind, cellWidth: cellW)
                            }
                        }
                    }
                }
                .frame(width: g.size.width, alignment: .leading)
                .onAppear { cellSize = CGSize(width: cellW, height: cardHeight + gap) }
                .onChange(of: g.size.width) { _, _ in
                    cellSize = CGSize(width: cellW, height: cardHeight + gap)
                }
            }
            .frame(height: rows.isEmpty ? 0 : CGFloat(rows.count) * (cardHeight + gap) - gap)
        }
        .padding(.horizontal, Spacing.section)
        .task { await data.load(auth: auth) }
        .task(id: off.count) { await data.loadOnDemand(auth: auth) }   // 开新卡 → 补拉它的数
        .sheet(isPresented: $showEditor) {
            HomeCardEditorSheet(off: $off) { HomeCardStore.persist(order: full, off: off) }
                .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Text("快捷卡片")
                .font(.system(size: Typography.caption, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Button {
                Haptics.tap()
                showEditor = true
            } label: {
                Text("自定义")
                    .sectionHeaderPill()
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: 单格

    @ViewBuilder
    private func slot(_ kind: HomeCardKind?, cellWidth: CGFloat) -> some View {
        if let kind {
            card(kind, index: kind == .custom ? nil : draggable.firstIndex(of: kind),
                 cellWidth: cellWidth)
        } else {
            Color.clear.frame(height: cardHeight)
        }
    }

    @ViewBuilder
    private func card(_ kind: HomeCardKind, index: Int?, cellWidth: CGFloat) -> some View {
        let dragging = index != nil && dragFrom == index
        ZStack(alignment: .topTrailing) {
            if kind == .custom {
                emptySlot
            } else {
                Button { Haptics.tap(); tap(kind) } label: {
                    HomeCardFace(kind: kind, data: data)
                }
                .buttonStyle(PressStyle())
            }
            if let badge = badge(kind) {
                Text(badge)
                    .font(.system(size: Typography.tiny, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
                    .offset(x: 6, y: -6)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
        // 拖动中有明确视觉信号（描边 + 放大 + 阴影）：用户报「长按没反应」时至少能看见手势已成立
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(dragging ? 0.55 : 0), lineWidth: 2)
        )
        .scaleEffect(dragging ? 1.04 : 1)
        .shadow(color: .black.opacity(dragging ? 0.18 : 0), radius: 12, y: 6)
        .zIndex(dragging ? 1 : 0)
        .offset(dragging ? dragOffset : .zero)
        // ⚠️ v4.0.10 真机 bug：卡片是 Button（PressStyle），`Button 内置手势会拦住挂在父级的
        // 长按/拖拽`（本仓 v2.0.96b 在发送键上踩过同一个坑）→ 长按永远不成立、拖不动。
        // 正解 = simultaneousGesture（与 Button 的按压手势并行识别），误触轻点由
        // suppressTapUntil 门闩在 `tap(_:)` 里挡掉，见那两处注释。
        .simultaneousGesture(dragGesture(index: index))
    }

    private var emptySlot: some View {
        Button { Haptics.tap(); showEditor = true } label: {
            VStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(Tint.faint), in: Circle())
                Text("空槽位")
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("点这里添加")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(Tint.subtle),
                                  style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
        }
        .buttonStyle(PressStyle())
    }

    private func badge(_ kind: HomeCardKind) -> String? {
        switch kind {
        case .mail:
            guard let n = data.mailUnread, n > 0 else { return nil }
            return n > 99 ? "99+" : "\(n)"
        case .todo:
            return data.todoOpen > 0 ? "\(data.todoOpen)" : nil
        default:
            return nil
        }
    }

    // MARK: 拖拽

    private func dragGesture(index: Int?) -> some Gesture {
        LongPressGesture(minimumDuration: HomeCardDragKit.longPressSeconds)
            .sequenced(before: DragGesture(minimumDistance: 2))
            .onChanged { value in
                guard let index else { return }
                switch value {
                case .second(true, let drag):
                    if dragFrom != index {
                        withAnimation(Motion.snap) { dragFrom = index; dragOffset = .zero }
                        Haptics.tap()
                    }
                    let moved = drag?.translation ?? .zero
                    dragOffset = moved
                    // 🚨 v4.0.10 二修：**只有真的移动了才上闩**。
                    //    旧写法「长按一成立就上闩」把「按久一点再松手」（手指没动）的轻点一起吞了
                    //    → 真机报「agent 主动推荐卡片点了没反应」。按住不动不算拖动，松手要照常干活。
                    if HomeCardDragKit.isRealDrag(dx: moved.width, dy: moved.height) {
                        suppressTapUntil = Date().addingTimeInterval(HomeCardDragKit.latchWindow)
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                // ⚠️ 只对「真的拖动过」上闩：普通轻点时 dragFrom 一直是 nil，
                // 若在这里无脑上闩，轻点会被自己挡掉（卡片全成死的）
                guard let from = dragFrom else { return }
                dragFrom = nil
                dragOffset = .zero
                // 🚨 v4.0.10 二修：长按成立但**手指没动** → 不算拖动：不上闩、不换位，
                //    让 Button 松手补送的那次轻点照常执行（用户按久一点再松手也当点了）。
                guard case .second(true, let drag?) = value,
                      HomeCardDragKit.isRealDrag(dx: drag.translation.width,
                                                 dy: drag.translation.height)
                else { return }
                suppressTapUntil = Date().addingTimeInterval(HomeCardDragKit.latchWindow)
                let target = HomeCardOrder.dragTarget(
                    from: from,
                    dx: Double(drag.translation.width),
                    dy: Double(drag.translation.height),
                    cellWidth: Double(cellSize.width),
                    rowHeight: Double(cellSize.height),
                    count: draggable.count)
                guard target != from, let k = draggable.indices.contains(from) ? draggable[from] : nil else { return }
                withAnimation(Motion.snap) { applyMove(k, to: target) }
                Haptics.success()
            }
    }

    /// 换位后写回完整顺序：隐藏卡留在原槽（mergeVisible，不自己拼）
    private func applyMove(_ k: HomeCardKind, to target: Int) {
        let movedVisible = HomeCardOrder.move(draggable, kind: k, to: target)
        full = HomeCardOrder.mergeVisible(oldFull: full, newVisible: movedVisible, off: off)
        HomeCardStore.persist(order: full, off: off)
    }

    // MARK: 轻点执行

    private func tap(_ kind: HomeCardKind) {
        // v4.0.10：**真拖动**之后的那一次松手不再当作轻点，否则「拖一次跳一次」。
        // 二修：门闩只在真位移时上（HomeCardDragKit）→ 慢点击/按住不动再松手照常执行。
        if Date() < suppressTapUntil { return }
        switch kind {
        case .mail:
            onAsk("查一下我的新邮件，挑出要紧的总结给我。")
        case .resume:
            if let s = resumeSession { onResume(s) }
        case .todo, .expense:
            onOpenLife()
        case .weather:
            onOpenWeather()
        case .agentTip:
            onAsk(data.tip.prompt)
        // ── v4.0.29 十张新卡 ──
        case .nextReminder:
            onOpenSheet(.nextReminder)          // 打开提醒面板（可直接新建）
        case .memo:
            onOpenSheet(.memo)                  // 打开备忘录页
        case .express:
            onOpenLife()                        // 快递详情在生活页
        case .stock:
            onOpenLife()                        // 行情详情在生活页
        case .kb:
            onAsk("@知识库 ")                    // 带前缀发问（输入框填充，用户补问题）
        case .scene, .device:
            onOpenBoard()                       // 场景一键执行 / 设备详情在看板
        case .cloud:
            onOpenSheet(.cloud)                 // 云盘浏览
        case .goal:
            onOpenLife()                        // 目标在生活页
        case .clipboard:
            tapClipboard()
        case .custom:
            showEditor = true
        }
    }

    /// 剪贴板卡：轻点那一刻才读 UIPasteboard（渲染期读 = 每次开首页弹系统「粘贴」提示）。
    /// 有内容 → 直接把内容发给 AI（识别/处理）；无内容 → 轻提示。
    private func tapClipboard() {
        let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, text.count <= 2000 else {
            Haptics.error()
            return
        }
        Haptics.tap()
        onAsk("帮我看看剪贴板里这段内容：\n\(text)")
    }
}

// MARK: - 卡片正面（纯展示，无业务逻辑）

struct HomeCardFace: View {
    let kind: HomeCardKind
    let data: HomeCardData

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            // v4.0.10：**恒单行**——双行副标题会把内容撑到 ~94pt，比 84pt 槽位高 10pt，
            // 而 ZStack 会把它居中 → 真机看就是「这张卡比同排那三张高一块」。别改回 lineLimit(2)，
            // 也**别加 .fixedSize(horizontal: false, vertical: true)**（那正是当年撑破卡高的写法）。
            Text(subtitle)
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 兜底：万一以后有更长的内容，也只许在卡内截断，不许画到卡外（卡高恒定是硬口径）
        .clipped()
        .dashboardCard(cornerRadius: Radius.card)
    }

    private var icon: String {
        switch kind {
        case .mail: return "envelope.fill"
        case .resume: return "arrow.uturn.backward.circle.fill"
        case .todo: return "checkmark.circle.fill"
        case .weather: return data.weatherTemp == nil ? "cloud.fill" : WeatherCode.symbol(data.weatherCode)
        case .expense: return "yensign.circle.fill"
        case .agentTip: return "sparkles"
        // v4.0.29 十张新卡
        case .nextReminder: return "bell.badge.fill"
        case .memo: return "note.text"
        case .express: return "shippingbox.fill"
        case .stock: return "chart.line.uptrend.xyaxis"
        case .kb: return "books.vertical.fill"
        case .scene: return "house.fill"
        case .device: return "cpu.fill"
        case .cloud: return "cloud.fill"
        case .goal: return "flag.checkered"
        case .clipboard: return "doc.on.clipboard.fill"
        case .custom: return "plus"
        }
    }

    private var tint: Color {
        switch kind {
        case .mail: return .blue
        case .resume: return .indigo
        case .todo: return .green
        case .weather: return .teal
        case .expense: return .orange
        case .agentTip: return .purple
        // v4.0.29 十张新卡
        case .nextReminder: return .red
        case .memo: return .yellow
        case .express: return .brown
        case .stock: return .mint
        case .kb: return .cyan
        case .scene: return .blue
        case .device: return .gray
        case .cloud: return .teal
        case .goal: return .orange
        case .clipboard: return .indigo
        case .custom: return .gray
        }
    }

    private var title: String {
        switch kind {
        case .mail: return "查询新邮件"
        case .resume: return "继续上次会话"
        case .todo: return "今日待办"
        case .weather: return "天气"
        case .expense: return "本月账目"
        case .agentTip: return data.tip.title
        // v4.0.29 十张新卡
        case .nextReminder: return "下一提醒"
        case .memo: return "备忘速记"
        case .express: return "快递在途"
        case .stock: return data.stockName.isEmpty ? "关注行情" : data.stockName
        case .kb: return "知识库问答"
        case .scene: return "家庭场景"
        case .device: return "设备状态"
        case .cloud: return "云盘"
        case .goal: return "今日目标"
        case .clipboard: return "剪贴板"
        case .custom: return "空槽位"
        }
    }

    /// 副标题口径（⚠️ 恒单行，见本文件顶部注释；相对时间/文案放不下会被截断）
    private func reminderTimeText(_ d: Date) -> String {
        let sameDay = Calendar.current.isDate(d, inSameDayAs: Date())
        let fmt = DateFormatter()
        fmt.dateFormat = sameDay ? "HH:mm" : "MM-dd HH:mm"
        return fmt.string(from: d)
    }

    private var subtitle: String {
        switch kind {
        case .mail:
            guard let n = data.mailUnread else { return "点一下让轻聊去查" }
            if n == 0 { return "没有未读 · 点一下复查" }
            return data.mailLatest.isEmpty ? "\(n) 封未读" : "\(n) 封未读 · 最新 \(data.mailLatest)"
        case .resume:
            return "回到上一个会话继续"
        case .todo:
            return data.todoOpen == 0 ? "今天没有待办" : "\(data.todoOpen) 项待办"
        case .weather:
            guard let t = data.weatherTemp else { return "设置城市后显示" }
            let city = data.weatherCity.isEmpty ? "" : " · \(data.weatherCity)"
            return "\(Int(t.rounded()))°\(data.weatherText)\(city)"
        case .expense:
            // 候选池⑬：有本周数据就报「本月 + 本周」，否则退回「本月 · N 笔」。
            // ⚠️ 副标题**恒单行**（卡高恒定，见本文件顶部注释）——加字必须算长度，别写成两行。
            guard data.monthCount > 0 else { return "本月还没有记录" }
            // 候选池⑦：设了预算就优先报水位（超支 > 接近 > 平常）
            if data.monthBudget > 0 {
                switch RecordKit.budgetLevel(spent: data.monthAmount, budget: data.monthBudget) {
                case .over:
                    return "已超预算 ¥\(String(format: "%.0f", data.monthAmount - data.monthBudget))"
                case .near:
                    return "¥\(String(format: "%.0f", data.monthAmount)) · 已用 \(Int((data.monthAmount / data.monthBudget * 100).rounded()))%"
                default:
                    break
                }
            }
            if data.weekAmount > 0 {
                return "¥\(String(format: "%.0f", data.monthAmount)) · 本周 ¥\(String(format: "%.0f", data.weekAmount))"
            }
            return "¥\(String(format: "%.0f", data.monthAmount)) · \(data.monthCount) 笔"
        case .agentTip:
            return data.tip.subtitle
        // ── v4.0.29 十张新卡 ──
        case .nextReminder:
            guard let t = data.nextReminderTime else { return "没有待响的提醒" }
            return "\(reminderTimeText(t)) · \(data.nextReminderText)"
        case .memo:
            return data.memoLatest.isEmpty ? "点一下去记一笔" : data.memoLatest
        case .express:
            guard data.expressCount > 0 else { return data.expressCount == 0 ? "没有在途快递" : "去生活页配置单号" }
            return "\(data.expressCount) 件 · \(data.expressLine)"
        case .stock:
            return data.stockLine.isEmpty ? "去生活页关注股票" : data.stockLine
        case .kb:
            guard data.kbCount >= 0 else { return "点一下问知识库" }
            return data.kbCount == 0 ? "还没有文档 · 去设置上传" : "\(data.kbCount) 份文档 · 点一下提问"
        case .scene:
            guard data.sceneCount > 0 else { return "没有可用场景" }
            return data.sceneName.isEmpty ? "\(data.sceneCount) 个场景" : "「\(data.sceneName)」等 \(data.sceneCount) 个"
        case .device:
            return data.deviceLine.isEmpty ? "点一下看看看板" : data.deviceLine
        case .cloud:
            guard data.cloudCount > 0 else { return data.cloudCount == 0 ? "还没接云盘" : "点一下去设置" }
            return data.cloudName.isEmpty ? "\(data.cloudCount) 个盘已就绪" : "\(data.cloudName) 等 \(data.cloudCount) 个盘"
        case .goal:
            guard data.goalTotal > 0 else { return "还没有长期目标" }
            if data.goalNextTitle.isEmpty { return "\(data.goalTotal) 个目标 · 步骤全完成" }
            return "\(data.goalTotal) 个目标 · 下一步 \(data.goalNextTitle)"
        case .clipboard:
            return "点一下发给 AI 处理"
        case .custom:
            return "点这里添加"
        }
    }
}

// MARK: - 自定义面板（开关）

struct HomeCardEditorSheet: View {
    @Binding var off: [HomeCardKind]
    var onChange: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(HomeCardKind.catalogOrder, id: \.self) { k in
                        Toggle(isOn: Binding(
                            get: { !off.contains(k) },
                            set: { newVal in
                                off = HomeCardOrder.setEnabled(off, k, on: newVal)
                                onChange()
                            })) {
                            Label(HomeCardLabels.name(k), systemImage: HomeCardLabels.icon(k))
                        }
                        .qingliaoSwitch(hideLabel: false)
                    }
                } header: {
                    Text("首页显示哪些卡片")
                } footer: {
                    Text("关掉的卡片不留空位；重新打开会回到原来的位置。在首页长按卡片可拖动排序。「空槽位」是添加快捷卡的入口，也可关掉，随时用这里重新打开。")
                }
            }
            .navigationTitle("自定义首页卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 标题/图标文案（单一真源，卡片与设置面板共用）

enum HomeCardLabels {
    static func name(_ k: HomeCardKind) -> String {
        switch k {
        case .mail: return "查询新邮件"
        case .resume: return "继续上次会话"
        case .todo: return "今日待办"
        case .weather: return "天气"
        case .expense: return "本月账目"
        case .agentTip: return "agent 主动推荐"
        // v4.0.29 十张新卡
        case .nextReminder: return "下一提醒"
        case .memo: return "备忘速记"
        case .express: return "快递在途"
        case .stock: return "关注行情"
        case .kb: return "知识库问答"
        case .scene: return "家庭场景"
        case .device: return "设备状态"
        case .cloud: return "云盘"
        case .goal: return "今日目标"
        case .clipboard: return "剪贴板"
        case .custom: return "空槽位"
        }
    }

    static func icon(_ k: HomeCardKind) -> String {
        switch k {
        case .mail: return "envelope.fill"
        case .resume: return "arrow.uturn.backward.circle.fill"
        case .todo: return "checkmark.circle.fill"
        case .weather: return "cloud.fill"
        case .expense: return "yensign.circle.fill"
        case .agentTip: return "sparkles"
        // v4.0.29 十张新卡
        case .nextReminder: return "bell.badge.fill"
        case .memo: return "note.text"
        case .express: return "shippingbox.fill"
        case .stock: return "chart.line.uptrend.xyaxis"
        case .kb: return "books.vertical.fill"
        case .scene: return "house.fill"
        case .device: return "cpu.fill"
        case .cloud: return "cloud.fill"
        case .goal: return "flag.checkered"
        case .clipboard: return "doc.on.clipboard.fill"
        case .custom: return "plus"
        }
    }
}
