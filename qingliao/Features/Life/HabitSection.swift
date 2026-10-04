// MARK: - v4.0.46 待做池⑤ 生活页「习惯」栏目
// 风格与「待办清单」栏目完全同源（LifeSectionHeader / LifeEmptyStateCard / LifeDeleteConfirm /
// LifeNoteComposeSheet / MemoCardMetrics 全部复用同一份单一来源，不另造第二套几何）：
//   · 页级标题行在卡片外；页面只放一张卡（`.dashboardCard()` 16 圆角 + MemoCardMetrics.minHeight 恒高）
//   · 点卡片：1 个习惯直达详情，≥2 个弹「全部习惯」列表（半屏 sheet）
//   · 空态 = 可点引导卡（与备忘/待办空态同几何，空 ↔ 有内容不跳变）
// 功能：手动建习惯 / 每日打卡（幂等，同一天只记一次）/ 取消当天打卡 / 连续天数 /
//       近 14 天打卡曲线 / 编辑 / 删除。
// 口径（用户 2026-10-04 拍板，见 Core/HabitKit.swift）：**每天一次 + 不可补签**，漏一天归零。

import SwiftUI

struct HabitSection: View {
    @State private var store = HabitStore.shared
    @State private var showAdd = false
    @State private var showAll = false
    /// 卡片 → 「全部习惯」列表的原生 zoom 转场（与备忘/待办卡片同款弹窗动画）
    @Namespace private var habitZoomNS
    /// 新建弹窗会话序号：每次打开自增，配合 `.id(addSession)` 强制换新实例（同 TodoSection）
    @State private var addSession = 0
    @State private var detail: HabitItem?
    /// 详情页**实际渲染**用的副本（呈现驱动与渲染快照分离，理由同 TodoSection 的 detailCurrent）
    @State private var detailCurrent: HabitItem?
    @State private var pendingDelete: HabitItem?
    @State private var editDraft = ""
    @State private var detailEditing = false

    /// v4.0.47：打卡显示的「今天」。卡片/详情里「今日已打卡 · 连续 N 天」全是渲染时现算的，
    /// 而 `Date()` 不是被观察的依赖 → App 常驻跨午夜会一直显示昨天的状态（数据没错、显示骗人）。
    /// 把「今天」提成 @State 并让渲染读它（下面的 isDone/currentStreak/lastNDays 都传它），
    /// 跨天或回前台时更新 → 强制 body 重算。
    @State private var today = Date()
    /// 每分钟探一次是否跨天（先例：VoiceDialogView 的 ticker 写法）
    @State private var dayTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        root
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { await store.loadFromServer() }
            .onReceive(dayTicker) { now in
                if !Calendar.current.isDate(now, inSameDayAs: today) { today = now }
            }
            // 回前台补一次：后台常驻跨夜再回来时，ticker 未必及时触发
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, !Calendar.current.isDateInToday(today) { today = Date() }
            }
            .sheet(isPresented: $showAdd) { addSheet.id(addSession) }
            // 删除确认框必须挂在弹窗自己那棵树上（宿主级 alert 会被 sheet 盖住 → 列表里点了没反应）
            .sheet(isPresented: $showAll) { deleteConfirm(on: allSheet) }
            .sheet(item: $detail, onDismiss: { detail = nil; detailCurrent = nil }) { h in
                detailSheet(detailCurrent ?? h)
            }
    }

    private var root: some View {
        deleteConfirm(on:
            VStack(alignment: .leading, spacing: 8) {
                pageHeader
                if store.habits.isEmpty {
                    emptyTap
                } else {
                    topCard
                }
            }
        )
    }

    private func deleteConfirm<V: View>(on view: V) -> some View {
        view.modifier(LifeDeleteConfirm(
            title: "删除这个习惯？",
            pending: pendingDelete,
            onCancel: { pendingDelete = nil },
            onDelete: { store.delete($0) },
            message: { $0.title.prefix(40).description }
        ))
    }

    // MARK: 页级标题行

    private var pageHeader: some View {
        LifeSectionHeader(
            title: "习惯",
            subtitle: store.habits.isEmpty ? nil : headerSubtitle,
            subtitleLineLimit: nil,
            addAccessibilityLabel: "添加习惯",
            onAdd: startAdd
        )
    }

    private var headerSubtitle: String {
        "\(store.habits.count) 个 · 今日已打卡 \(store.todayDoneCount)"
    }

    private var emptyTap: some View {
        LifeEmptyStateCard(
            icon: "checkmark.seal",
            title: "养成一个习惯",
            subtitle: "每天打卡，连续天数漏一天就归零",
            onTap: startAdd
        )
    }

    private func startAdd() {
        addSession += 1
        showAdd = true
    }

    // MARK: 页面单卡（显示列表最上的一条）

    @ViewBuilder
    private var topCard: some View {
        if let top = store.sorted.first {
            habitCard(top, compact: true)
                .onTapGesture { openTop(top) }
                .contextMenu { habitMenuItems(top) }
                .matchedTransitionSource(id: "habit-all", in: habitZoomNS)
                .accessibilityLabel("习惯 \(top.title)，\(streakText(top))，点开查看")
        }
    }

    /// 习惯行卡（页级单卡 / 列表行共用，差异走 compact）——视觉 + 打卡圆，点击行为由调用方挂
    private func habitCard(_ h: HabitItem, compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            checkCircle(h)
            VStack(alignment: .leading, spacing: 5) {
                Text(h.title)
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.primary)
                    .lineLimit(compact ? MemoCardMetrics.lineLimit : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                streakLine(h)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity,
               minHeight: compact ? MemoCardMetrics.minHeight : 0,
               alignment: .leading)
        .dashboardCard()
        .contentShape(Rectangle())
    }

    private func checkCircle(_ h: HabitItem) -> some View {
        let done = store.isDone(h, on: today)
        return Button {
            toggle(h)
        } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(done ? Color.green : Color.secondary.opacity(0.4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(done ? "取消今日打卡" : "今日打卡")
    }

    private func streakLine(_ h: HabitItem) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "flame.fill")
                .font(.system(size: Typography.tiny))
            Text(streakText(h))
                .font(.system(size: Typography.tiny))
        }
        .foregroundStyle(store.isDone(h, on: today) ? Color.orange : Color.secondary)
    }

    private func streakText(_ h: HabitItem) -> String {
        let s = HabitKit.currentStreak(h, today: today)
        if store.isDone(h, on: today) { return "连续 \(s) 天 · 今日已打卡" }
        return s > 0 ? "连续 \(s) 天 · 今天还没打卡" : "今天还没打卡"
    }

    private func toggle(_ h: HabitItem) {
        if store.isDone(h, on: today) {
            store.undo(h)
        } else if store.checkIn(h) {
            Haptics.success()
        }
    }

    private func openTop(_ h: HabitItem) {
        if store.sorted.count == 1 {
            openDetail(h, fromList: false)
        } else {
            showAll = true
        }
    }

    /// 打开详情。fromList=true 时先收列表再延迟呈现（同 TodoSection：同一宿主不能同时呈两个 sheet）
    private func openDetail(_ h: HabitItem, fromList: Bool) {
        editDraft = h.title
        detailEditing = false
        if fromList {
            showAll = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !showAll else { return }
                detailCurrent = store.habits.first { $0.id == h.id } ?? h
                detail = h
            }
        } else {
            detailCurrent = store.habits.first { $0.id == h.id } ?? h
            detail = h
        }
    }

    // MARK: 全部习惯列表（半屏 sheet，左滑删除）

    private var allSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("全部习惯")
                        .font(.system(size: Typography.title, weight: .semibold))
                    Text("今日已打卡 \(store.todayDoneCount)")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    MiniCapsule(title: "完成", accent: true) { showAll = false }
                }
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.md)
                List {
                    ForEach(store.sorted) { h in
                        habitCard(h, compact: false)
                            .onTapGesture { openDetail(h, fromList: true) }
                            .contextMenu { habitMenuItems(h) }
                            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.section,
                                                      bottom: 8, trailing: Spacing.section))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onDelete { offsets in
                        guard offsets.count == 1, let idx = offsets.first else {
                            for h in offsets.map({ store.sorted[$0] }) { store.delete(h) }
                            return
                        }
                        pendingDelete = store.sorted[idx]
                    }
                    if store.sorted.isEmpty {
                        Text("还没有习惯")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 20)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .navigationTransition(.zoom(sourceID: "habit-all", in: habitZoomNS))
    }

    // MARK: 详情 / 编辑

    private func refreshDetail() {
        guard let cur = detailCurrent ?? detail,
              let idx = store.habits.firstIndex(where: { $0.id == cur.id }) else { return }
        detailCurrent = store.habits[idx]
    }

    private func detailSheet(_ h: HabitItem) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    MiniCapsule(title: "关闭") {
                        detailEditing = false
                        detail = nil
                    }
                    Spacer(minLength: 0)
                    if detailEditing {
                        MiniCapsule(title: "保存", accent: true) {
                            store.update(h, title: editDraft)
                            refreshDetail()
                            detailEditing = false
                        }
                        .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        MiniCapsule(title: "编辑") {
                            editDraft = h.title
                            detailEditing = true
                        }
                    }
                }
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.sm)
                .overlay {
                    Text("习惯")
                        .font(.system(size: Typography.headline, weight: .semibold))
                        .foregroundStyle(.primary)
                        .allowsHitTesting(false)
                }

                if detailEditing {
                    TextEditor(text: $editDraft)
                        .font(.system(size: Typography.title))
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.xl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if editDraft.isEmpty {
                                Text("习惯名称…")
                                    .font(.system(size: Typography.title))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, Spacing.section)
                                    .padding(.vertical, 20)
                                    .allowsHitTesting(false)
                            }
                        }
                        .padding(.horizontal, Spacing.section)
                        .padding(.top, Spacing.md)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            // 打卡大按钮 + 标题 + 连续/最长（核心交互前置到详情）
                            Button {
                                toggle(h)
                                refreshDetail()
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: store.isDone(h, on: today) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 26, weight: .medium))
                                        .foregroundStyle(store.isDone(h, on: today) ? Color.green : Color.secondary.opacity(0.4))
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(h.title)
                                            .font(.system(size: Typography.headline))
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(detailStreakText(h))
                                            .font(.system(size: Typography.caption))
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(Spacing.xl)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .dashboardCard()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressStyle())
                            dayCurve(h)
                            if !store.isDone(h, on: today) {
                                Text("今天还没打卡 · 点上面的圆即可打卡")
                                    .font(.system(size: Typography.caption))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // 编辑态禁止下滑关闭：手一滑草稿就没了（对齐备忘/待办详情护栏）
            .interactiveDismissDisabled(detailEditing)
        }
        .presentationDetents([.medium, .large])
    }

    private func detailStreakText(_ h: HabitItem) -> String {
        let cur = HabitKit.currentStreak(h, today: today)
        let best = HabitKit.bestStreak(h)
        return "当前连续 \(cur) 天 · 最长 \(best) 天"
    }

    /// 近 14 天打卡曲线（日点圆 + 稀疏标签；缺天为空圆 —— 一眼看出断在哪天）
    private func dayCurve(_ h: HabitItem) -> some View {
        let pts = HabitKit.lastNDays(h, days: 14, today: today)
        return VStack(alignment: .leading, spacing: 8) {
            Text("近 14 天")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(Array(pts.enumerated()), id: \.element.key) { idx, p in
                    VStack(spacing: 4) {
                        Circle()
                            .fill(p.done ? Color.green : Color.secondary.opacity(0.18))
                            .frame(width: 14, height: 14)
                        Text(showDayLabel(idx, total: pts.count) ? p.label : " ")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    /// 14 个日期全标会挤 → 只在首/中/末三处标标签（其余留同高空白占位）
    private func showDayLabel(_ idx: Int, total: Int) -> Bool {
        idx == 0 || idx == total - 1 || idx == total / 2
    }

    // MARK: 长按菜单（页卡 / 列表共用）

    @ViewBuilder
    private func habitMenuItems(_ h: HabitItem) -> some View {
        Button {
            toggle(h)
        } label: {
            Label(store.isDone(h, on: today) ? "取消今日打卡" : "今日打卡",
                  systemImage: store.isDone(h, on: today) ? "arrow.uturn.backward" : "checkmark.circle.fill")
        }
        Button {
            openDetail(h, fromList: false)
        } label: {
            Label("查看", systemImage: "eye")
        }
        Button(role: .destructive) {
            pendingDelete = h
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: 新建（与备忘/待办添加弹窗同款）

    private var addSheet: some View {
        LifeNoteComposeSheet(
            title: "新建习惯",
            placeholder: "想坚持什么…",
            onSave: { text in
                if store.add(title: text) {
                    Haptics.success()
                }
                showAdd = false
            },
            onCancel: { showAdd = false }
        )
    }
}
