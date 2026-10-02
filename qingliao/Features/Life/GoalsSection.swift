// MARK: - v4.0.7 生活页「长期目标」栏目
//
// 闭环链路（AI 主动建 → cron 每天推进 → 回写卡片）：
//   你在聊天里说「我在筹备 XX」
//     → 后端 agent 判定为长期目标，回一张「建目标卡」（ql-card）
//     → 你点「建目标」→ POST /api/life/goal（后端 goals_api）→ 落 goals.json + 建 cron job
//     → 每天早 morningHour 推「今天推进哪一步 + 需要你做什么」
//     → 每天晚 eveningHour 推「今天做了什么、还剩多少、明天计划」
//     → 两段汇报都回写 goals.json → 本卡片显示 lastReport + 进度条
//     → 手动建的目标（不经 AI）也能用：直接在本卡片「添加」
//
// 风格与「待办清单」栏目同源（TodoSection）：
//   · 页级标题行（粗体 + 计数 + 右侧胶囊）在卡片外
//   · 页面只放一张卡（.dashboardCard() 16 圆角 + 同高 83pt）
//   · 1 个目标直达详情，≥2 个弹「全部目标」列表（半屏 sheet）
//   · 空态 = 可点引导卡（同几何，空 ↔ 有内容不跳变）
//
// 🚨 铁律：
// · 确认框/清空二次确认必须挂在**弹窗内那棵树上**（宿主级 alert 在 sheet 之上呈现不出来）。
// · sheet(item:) 的 onDismiss 必须复位 item，否则详情再也打不开。
// · 同宿主多 sheet 互斥：先关前者，等 500ms 再开后者。
// · MiniCapsule 是跨文件单一来源（LifeCapsule.swift），别在本文件另抄一份 private 版。

import SwiftUI

struct GoalsSection: View {
    @State private var store = GoalStore.shared
    @State private var showAdd = false
    @State private var showAll = false
    /// v4.0.7：卡片 → 「全部目标」列表的原生 zoom 转场（与待办卡片同款）
    @Namespace private var goalZoomNS
    @State private var draft = ""
    @State private var detail: GoalItem?
    /// SR34 同款坑：detail 只驱动呈现，实际渲染用副本，写库后回灌
    @State private var detailCurrent: GoalItem?
    @State private var pendingDelete: GoalItem?
    /// 「全部目标」弹窗顶栏「清空」胶囊的二次确认
    @State private var confirmClearAll = false

    var body: some View {
        root
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { await store.loadFromServer() }
            .sheet(isPresented: $showAdd) { addSheet }
            // 🚨 确认框必须挂在弹窗自己这棵树上（SR35）
            .sheet(isPresented: $showAll) { deleteConfirm(on: allSheet) }
            .sheet(item: $detail, onDismiss: { detail = nil; detailCurrent = nil }) { g in
                detailSheet(detailCurrent ?? g)
            }
    }

    /// 页面主体：确认框挂在这——页卡长按删除时生效的就是这一份
    private var root: some View {
        deleteConfirm(on:
            VStack(alignment: .leading, spacing: 8) {
                pageHeader
                if store.goals.isEmpty {
                    emptyTap
                } else {
                    topCard
                }
            }
        )
    }

    /// 删除确认框本体已收进 LifeDeleteConfirm（工作线 B：待办/记录/备忘弹窗内那份同款）
    private func deleteConfirm<V: View>(on view: V) -> some View {
        view.modifier(LifeDeleteConfirm(
            title: "删除这个目标？",
            pending: pendingDelete,
            onCancel: { pendingDelete = nil },
            onDelete: { g in
                store.remove(g.id)
                // 🚨 同步删后端目标 —— 后端会连带删掉它的 cron job，
                //    否则明天早上还会推一个用户已经删掉的目标。
                Task { await store.deleteOnBackend(goalID: g.id) }
            },
            message: { $0.title.prefix(40).description }
        ))
    }

    // MARK: 页级标题行

    /// 外壳已收进 LifeSectionHeader（工作线 B：备忘/待办/记录三份同款）
    private var pageHeader: some View {
        LifeSectionHeader(
            title: "长期目标",
            subtitle: store.goals.isEmpty ? nil : activeSubtitle,
            subtitleLineLimit: nil,
            addAccessibilityLabel: "添加长期目标",
            onAdd: startAdd
        )
    }

    private var activeSubtitle: String {
        let n = store.activeCount
        return n > 0 ? "\(n) 个进行中" : "全部完成"
    }

    /// 空态引导卡（与待办空态同几何：16 圆角 + 83pt 高）
    private var emptyTap: some View {
        LifeEmptyStateCard(
            icon: "target",
            title: "有个想长期推进的事",
            subtitle: "跟 AI 说「我在筹备 XX」，它会拆成步骤并每天推你一步",
            onTap: startAdd
        )
    }

    /// 页级标题行与空态引导卡共用这一个入口
    private func startAdd() {
        draft = ""
        showAdd = true
    }

    // MARK: 页面单卡（显示最上的一个 = 未完成优先、最新在前）

    @ViewBuilder
    private var topCard: some View {
        if let top = store.sorted.first {
            Button {
                openCard()
            } label: {
                GoalRowCard(goal: top, compact: true)
            }
            .buttonStyle(PressStyle())
            .contextMenu { goalMenuItems(top) }
            .matchedTransitionSource(id: "goal-all", in: goalZoomNS)
            .accessibilityLabel(store.sorted.count == 1
                                ? "长期目标，1 个，点开查看"
                                : "长期目标，共 \(store.sorted.count) 个，点开查看全部")
        }
    }

    private func openCard() {
        if store.sorted.count == 1, let only = store.sorted.first {
            detailCurrent = only
            detail = only
        } else {
            showAll = true
        }
    }

    // MARK: 卡片行

    @ViewBuilder
    private func goalMenuItems(_ g: GoalItem) -> some View {
        Button {
            let now = !g.paused
            store.mutate(g.id) { $0.paused = now }
            Task { await store.setPausedOnBackend(goalID: g.id, paused: now) }
            Haptics.success()
        } label: {
            Label(g.paused ? "恢复每日推进" : "暂停每日推进", systemImage: g.paused ? "play.circle" : "pause.circle")
        }
        Button(role: .destructive) {
            pendingDelete = g
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: 添加弹窗（手动建目标；AI 建的走聊天里的「建目标卡」）

    private var addSheet: some View {
        NavigationStack {
            List {
                Section("目标") {
                    TextField("想长期推进什么", text: $draft, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    Toggle("早间推进提醒", isOn: Binding(
                        get: { addMorning },
                        set: { addMorning = $0 }
                    )).qingliaoSwitch(hideLabel: false)
                    if addMorning {
                        Stepper("早上 \(addMorningHour):00", value: $addMorningHour, in: 6...12)
                    }
                    Toggle("晚间复盘", isOn: Binding(
                        get: { addEvening },
                        set: { addEvening = $0 }
                    )).qingliaoSwitch(hideLabel: false)
                    if addEvening {
                        Stepper("晚上 \(addEveningHour):00", value: $addEveningHour, in: 18...23)
                    }
                } header: {
                    Text("每日推进（AI 每天两段）")
                } footer: {
                    Text("早间告诉你今天推哪一步、需要你做什么；晚间复盘今天做了什么、还剩多少。")
                }
                Section {
                    Text("说明：跟 AI 说「我在筹备 XX」更快——它会直接把步骤拆好。")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top) {
                HStack {
                    MiniCapsule(title: "取消") { showAdd = false }
                    Spacer()
                    MiniCapsule(title: "创建", accent: true) { confirmAdd() }
                }
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.xs)
            }
        }
        .presentationDetents([.medium, .large])
    }

    @State private var addMorning = true
    @State private var addEvening = true
    @State private var addMorningHour = 9
    @State private var addEveningHour = 21

    private func confirmAdd() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let g = GoalItem(title: t,
                         morningEnabled: addMorning,
                         eveningEnabled: addEvening,
                         morningHour: addMorningHour,
                         eveningHour: addEveningHour)
        // 🚨 先本地落库（卡片立刻可见）+ 同步把步骤灌进待办清单（口径：打通）。
        //    再异步问后端建 cron job —— 建 job 失败不阻塞落库，后端失败会在卡片上显示出来。
        store.add(g)
        pushStepsToTodo(g)
        Haptics.success()
        showAdd = false
        Task { @MainActor in
            guard let remote = await store.createOnBackend(g) else {
                store.mutate(g.id) { $0.lastReport = "⚠️ 每日推送没建上（后端没响应），可以稍后在详情里重建。" }
                return
            }
            store.update(remote)
        }
    }

    // MARK: 「全部目标」列表弹窗

    private var allSheet: some View {
        NavigationStack {
            List {
                ForEach(store.sorted) { g in
                    Button {
                        // 🚨 同宿主多 sheet 互斥：先关列表，等它收起再开详情
                        showAll = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(500))
                            guard !showAll else { return }
                            detailCurrent = g
                            detail = g
                        }
                    } label: {
                        GoalRowCard(goal: g, compact: false)
                    }
                    .buttonStyle(PressStyle())
                    .contextMenu { goalMenuItems(g) }
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.section, bottom: 8, trailing: Spacing.section))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // 🚨 清空二次确认必须挂 List 上（宿主级 alert 被 sheet 盖住）
            .alert("清空全部目标？", isPresented: $confirmClearAll) {
                Button("清空", role: .destructive) {
                    // 🚨 清空前先把 id 收齐：removeAll 之后本地已空，
                    //    再想通知后端删 job 就拿不到 id 了（会留下每天还在推的孤儿 job）。
                    let ids = store.goals.map { $0.id }
                    store.removeAll()
                    showAll = false
                    Task { for id in ids { await store.deleteOnBackend(goalID: id) } }
                    Haptics.success()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("已删除的目标不会恢复，AI 也不会再每天推送它。")
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    if !store.goals.isEmpty {
                        MiniCapsule(title: "清空") { confirmClearAll = true }
                    }
                    Spacer()
                    MiniCapsule(title: "完成", accent: true) { showAll = false }
                }
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.xs)
            }
            .toolbar(.hidden, for: .navigationBar)
            .presentationDetents([.medium, .large])
            .navigationTransition(.zoom(sourceID: "goal-all", in: goalZoomNS))
        }
    }

    // MARK: 详情弹窗

    private func detailSheet(_ g0: GoalItem) -> some View {
        let g = detailCurrent ?? g0
        return NavigationStack {
            List {
                Section {
                    HStack(spacing: Spacing.md) {
                        Text("\(g.doneCount)/\(g.steps.count)")
                            .font(.system(size: Typography.title, weight: .bold))
                        if !g.steps.isEmpty {
                            Text("\(Int(g.progressRatio * 100))%")
                                .font(.system(size: Typography.subhead))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if g.isFinished {
                            Text("已完成").pill(.topBar, tone: .accent)
                        } else {
                            // v4.0.20（#5）：详情页同口径 —— 不再只报「每天 9:00/21:00」，
                            // 而是说清后台到底在不在跑
                            Circle()
                                .fill(g.scheduleHealth == .running ? Color.green
                                      : (g.scheduleHealth == .paused ? Color.secondary : Color.orange))
                                .frame(width: 6, height: 6)
                            Text(GoalSchedule.healthLabel(g.scheduleHealth)).pill(.topBar)
                        }
                    }
                    if !g.steps.isEmpty {
                        ProgressView(value: g.progressRatio)
                            .tint(Color.accentColor)
                    }
                } header: {
                    Text(g.title)
                } footer: {
                    if let at = g.lastPushedAt {
                        Text("最近更新 \(Self.stamp(at))")
                    } else {
                        Text("还没有推送记录")
                    }
                }

                if !g.steps.isEmpty {
                    Section("步骤") {
                        ForEach(g.steps) { s in
                            Button {
                                store.toggleStep(goalID: g.id, stepID: s.id)
                                refreshDetail()
                                syncTodo(step: s, goal: g)
                                Haptics.success()
                            } label: {
                                HStack(spacing: Spacing.sm) {
                                    Image(systemName: s.done ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: Typography.body))
                                        .foregroundStyle(s.done ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.title)
                                            .font(.system(size: Typography.body))
                                            .foregroundStyle(s.done ? .secondary : .primary)
                                            .strikethrough(s.done)
                                        if s.todoLinked {
                                            Text("已同步到待办")
                                                .font(.system(size: Typography.tiny))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressStyle())
                            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.section, bottom: 8, trailing: Spacing.section))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                }

                if !g.lastReport.isEmpty {
                    Section("最近一次推进汇报") {
                        Text(g.lastReport)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // v4.0.20（#6）：后台推进时间线 —— 用户要看到「后台到底跑过什么、跑了几次」
                //（此前只有一句 lastReport，被覆盖式写库，历史留不下）
                if !g.reports.isEmpty {
                    Section("后台推进记录") {
                        ForEach(g.reports.sorted { $0.at > $1.at }) { r in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    if r.isAgentAction {
                                        Image(systemName: "wand.and.stars")
                                            .font(.system(size: Typography.caption))
                                            .foregroundStyle(Color.orange)
                                    }
                                    Text(Self.stamp(r.at))
                                        .font(.system(size: Typography.caption))
                                        .foregroundStyle(.secondary)
                                    if r.isAgentAction {
                                        Text("AI 自动").pill(.topBar, tone: .accent)
                                    }
                                }
                                Text(r.text)
                                    .font(.system(size: Typography.caption))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        let now = !g.paused
                        store.mutate(g.id) { $0.paused = now }
                        refreshDetail()
                        Task { await store.setPausedOnBackend(goalID: g.id, paused: now) }
                        Haptics.success()
                    } label: {
                        Label(g.paused ? "恢复每日推进" : "暂停每日推进",
                              systemImage: g.paused ? "play.circle" : "pause.circle")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top) {
                HStack {
                    MiniCapsule(title: "删除") { pendingDelete = detailCurrent }
                    Spacer()
                    MiniCapsule(title: "完成", accent: true) { detail = nil }
                }
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.xs)
            }
            .alert("删除这个目标？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let t = pendingDelete {
                        store.remove(t.id)
                        Task { await store.deleteOnBackend(goalID: t.id) }
                    }
                    pendingDelete = nil
                    detail = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text(pendingDelete?.title.prefix(40).description ?? "")
            }
            .toolbar(.hidden, for: .navigationBar)
            .presentationDetents([.medium, .large])
        }
    }

    /// SR34：写库后回灌详情副本（否则勾了步骤界面没反应）
    private func refreshDetail() {
        guard let id = detail?.id else { return }
        detailCurrent = store.goals.first { $0.id == id }
    }

    /// 建目标时把 AI 拆的步骤灌进待办清单（用户口径：打通）。
    /// 标题带 ［目标·XX］ 标记，便于在待办里一眼认出归属、也便于日后反查。
    func pushStepsToTodo(_ g: GoalItem) {
        GoalTodoBridge.pushStepsToTodo(g)
    }

    /// 勾上步骤 → 同步在待办里对应的条目划掉；取消勾 → 待办恢复
    private func syncTodo(step: GoalStep, goal: GoalItem) {
        GoalTodoBridge.syncStepDone(step: step, goal: goal)
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 目标 → 待办 的桥（打通口径：拆出的步骤直接进待办清单）

/// ⚠️ 必须标 @MainActor：桥直接摸 `TodoStore.shared` / `GoalStore.shared`（都是
/// @MainActor @Observable 单例）。不标的话，即使调用方包了
/// `await MainActor.run { ... }`，编译器仍判定桥体本身是 nonisolated →
/// CI Archive 报 "main actor-isolated static property 'shared' can not be
/// referenced from a nonisolated context"。这类错误 -parse 查不出来。
@MainActor
enum GoalTodoBridge {
    /// 目标在待办里的识别标记
    static func marker(for goal: GoalItem) -> String { "［目标·\(goal.title)］" }

    /// 步骤进待办时的标题
    static func todoTitle(step: GoalStep, goal: GoalItem) -> String {
        "\(marker(for: goal))\(step.title)"
    }

    /// 建目标时把 AI 拆的步骤灌进待办清单（用户口径：打通）。
    /// 标记已同步，避免下次编辑目标时重复灌一遍。
    static func pushStepsToTodo(_ g: GoalItem) {
        let ts = TodoStore.shared
        for s in g.steps where !s.todoLinked {
            _ = ts.add(content: todoTitle(step: s, goal: g), source: "goal")
        }
        GoalStore.shared.mutate(g.id) { item in
            for i in item.steps.indices { item.steps[i].todoLinked = true }
        }
    }

    /// 步骤完成态 → 同步待办清单。
    /// ⚠️ 用 `step.done` 判方向，**不用 toggle** —— toggle 在「想勾成未勾」时会反向。
    /// 放在桥里（而非 GoalsSection 的 private 方法）是因为 AgentActionExecutor 也要用。
    static func syncStepDone(step: GoalStep, goal: GoalItem) {
        let m = marker(for: goal)
        let ts = TodoStore.shared
        for t in ts.todos where t.content.contains(m) && t.content.contains(step.title) {
            if t.done != step.done { ts.toggleDone(t) }
        }
    }

    /// 按 id 同步（执行器用：手上只有 goalID/stepID）
    static func syncStepDone(goalID: String, stepID: String) {
        guard let g = GoalStore.shared.goals.first(where: { $0.id == goalID }),
              let s = g.steps.first(where: { $0.id == stepID }) else { return }
        syncStepDone(step: s, goal: g)
    }
}

// MARK: - 目标行卡片

struct GoalRowCard: View {
    let goal: GoalItem
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: goal.isFinished ? "checkmark.seal.fill" : "target")
                    .font(.system(size: compact ? Typography.body : Typography.title))
                    .foregroundStyle(goal.isFinished ? Color.accentColor : Color.accentColor.opacity(0.9))
                Text(goal.title)
                    .font(.system(size: compact ? Typography.body : Typography.title, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if goal.isFinished {
                    Text("已完成").pill(.topBar)
                } else {
                    // v4.0.20（#5）：后台健康点 —— 一眼看出「它到底在不在跑」
                    //（绿=已接上 cron 在跑 / 灰=用户暂停 / 橙=没建上 cron 的半成品）
                    Circle()
                        .fill(healthColor(goal.scheduleHealth))
                        .frame(width: 6, height: 6)
                    Text(GoalSchedule.healthLabel(goal.scheduleHealth)).pill(.topBar)
                }
            }

            // v4.0.20（#5）：后台状态条 —— 下一次什么时候动（用户原话「不知道有没有触发后台」）
            if !compact, !goal.isFinished {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                    Text(goal.scheduleText(now: Date()))
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            if !goal.steps.isEmpty {
                HStack(spacing: 6) {
                    ProgressView(value: goal.progressRatio)
                        .tint(Color.accentColor)
                    Text("\(goal.doneCount)/\(goal.steps.count)")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if let s = goal.nextStep, !compact {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                    Text("下一步：\(s.title)")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity,
               minHeight: compact ? MemoCardMetrics.minHeight : nil,
               alignment: .leading)
        .dashboardCard()
    }

    /// v4.0.20（#5）：健康点配色
    private func healthColor(_ h: GoalSchedule.Health) -> Color {
        switch h {
        case .running:  return .green
        case .paused:   return .secondary
        case .detached: return .orange
        }
    }
}
