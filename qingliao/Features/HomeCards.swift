//
//  HomeCards.swift
//  轻聊
//
//  v4.0.8：聊天首页「方块卡片」组件（2 列等宽网格 + 长按拖拽排序 + 自定义开关）。
//  版式 = 用户 2026-09-29 拍板的 B3 稿；纯逻辑全在 Core/HomeCardOrder.swift（那里有真值表）。
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
    var tip: HomeCardTip = .idle
    var loaded = false

    private var mailFetched = false
    private var weatherFetched = false

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
    }

    /// 待办 / 账目：本地 Store 已同步过，直接读，不打后端
    private func loadLocal() {
        todoOpen = TodoStore.shared.todos.filter { !$0.done }.count
        let t = RecordStore.shared.monthTotal
        monthAmount = t.amount
        monthCount = t.count
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
        var tip = HomeCardTip(title: base.title, subtitle: base.sub, prompt: base.prompt)
        // 记忆里有明确偏好时，副标题带上它（「主动学习」的最小可见形态）
        if let e = entries.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let short = e.count > 16 ? String(e.prefix(16)) + "…" : e
            tip.subtitle = "记得：\(short)"
        }
        return tip
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

    /// 完整顺序（catalog 全量，含被关掉的）—— 写回的唯一真源。
    /// ⚠️ 必须用 fullOrder（全量）而不是 kinds（渲染列表）：否则新开的卡不在 full 里 → 开了看不见。
    @State private var full: [HomeCardKind] = HomeCardStore.fullOrder
    /// 被关掉的集合。⚠️ 必须与读取路径同源（HomeCardStore.off）：键不存在时是**默认档**，
    /// 若这里直接 parse 空串 → 面板显示「三张默认关掉的卡是开的」，与首页实际渲染不一致。
    @State private var off: [HomeCardKind] = HomeCardStore.off
    @State private var data = HomeCardData()
    @State private var dragFrom: Int?
    @State private var dragOffset: CGSize = .zero
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
                    .chatHeaderPill()
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
        .scaleEffect(dragging ? 1.04 : 1)
        .shadow(color: .black.opacity(dragging ? 0.18 : 0), radius: 12, y: 6)
        .zIndex(dragging ? 1 : 0)
        .offset(dragging ? dragOffset : .zero)
        .gesture(dragGesture(index: index))
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
        LongPressGesture(minimumDuration: 0.28)
            .sequenced(before: DragGesture(minimumDistance: 2))
            .onChanged { value in
                guard let index else { return }
                switch value {
                case .second(true, let drag):
                    if dragFrom != index {
                        withAnimation(Motion.snap) { dragFrom = index; dragOffset = .zero }
                        Haptics.tap()
                    }
                    dragOffset = drag?.translation ?? .zero
                default:
                    break
                }
            }
            .onEnded { value in
                guard let from = dragFrom else { return }
                dragFrom = nil
                dragOffset = .zero
                guard case .second(true, let drag?) = value else { return }
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
        case .custom:
            showEditor = true
        }
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
            Text(subtitle)
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        case .custom: return "空槽位"
        }
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
            return data.monthCount == 0
                ? "本月还没有记录"
                : "¥\(String(format: "%.0f", data.monthAmount)) · \(data.monthCount) 笔"
        case .agentTip:
            return data.tip.subtitle
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
                        .disabled(k == .custom)
                    }
                } header: {
                    Text("首页显示哪些卡片")
                } footer: {
                    Text("关掉的卡片不留空位；重新打开会回到原来的位置。在首页长按卡片可拖动排序。")
                }
            }
            .navigationTitle("自定义首页卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
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
        case .custom: return "空槽位（固定）"
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
        case .custom: return "plus"
        }
    }
}
