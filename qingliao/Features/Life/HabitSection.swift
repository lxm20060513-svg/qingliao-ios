// MARK: - v4.0.46 待做池⑤ 生活页「习惯」栏目
// 风格与「待办清单」栏目完全同源（LifeSectionHeader / LifeEmptyStateCard / LifeDeleteConfirm /
// LifeNoteComposeSheet / MemoCardMetrics 全部复用同一份单一来源，不另造第二套几何）：
//   · 页级标题行在卡片外；页面只放一张卡（`.pastelCard()` 16 圆角 + MemoCardMetrics.minHeight 恒高）
//   · 点卡片：1 个习惯直达详情，≥2 个弹「全部习惯」列表
//   · 空态 = 可点引导卡（与备忘/待办空态同几何，空 ↔ 有内容不跳变）
// 功能：手动建习惯 / 每日打卡（幂等，同一天只记一次）/ 取消当天打卡 / 连续天数 /
//       近 14 天打卡曲线 / 编辑 / 删除。
// 口径（用户 2026-10-04 拍板，见 Core/HabitKit.swift）：**每天一次 + 不可补签**，漏一天归零。
//
// MARK: - v4.0.78 三张系统 sheet → 毛玻璃全屏浮层（用户 2026-10-08 原话：
//   「习惯卡片也改成跟备忘录一样的全屏弹出」）
//
// 为什么（与备忘录 v4.0.77 同一件事故，先例见 MemoSection.swift 底部 MemoGlassPresenter /
// MemoGlassLayerHost 顶部注释）：浮层若挂在 **section 内**（section = 生活页 LazyVStack 的一行），
// 几何会被这一行限制 → 轻纱只罩住卡片那一条、面板贴着卡片边缘长出、列表一滚浮层跟着跑。要「全屏」
// 就必须把浮层挂到**页面根**、滚动区之外：开关提到页级单例 HabitGlassPresenter，浮层本体由
// HabitGlassLayerHost 渲染（挂载点 = LifeView body 最外层，由主会话统一挂）。
//
// ⚠️ 本次只改**呈现层**：字号 / 几何 / 文案一律不动 —— 三张弹窗的主体内容逐字平移进文件级 struct，
//    原来读 section @State 的（detailEditing / detailCurrent / editDraft / pendingDelete 等）
//    搬进各自 struct 自己的 @State；打卡圆、连续天数、今天日期(today) 这些时间逻辑照原样在新
//    struct 内重新表达（宿主 section 自己的 dayTicker / onChange(scenePhase) 仍然保留，供页卡用）。

import SwiftUI
import Observation   // v4.0.78：浮层状态提到页级单例（@Observable，同 MemoSection）

struct HabitSection: View {
    @State private var store = HabitStore.shared
    /// v4.0.78：三个浮层的开关（全部习惯 / 新建 / 详情）**提到页级单例**——
    /// 浮层本体不再挂在本 section 里（本 section 只是生活页滚动区的一行，浮层会被限制在卡片那一行的几何里）。
    /// 详见文件底部 HabitGlassPresenter / HabitGlassLayerHost 顶部注释。
    private var glass = HabitGlassPresenter.shared
    /// v4.0.78：`@Namespace habitZoomNS` 与页卡上的 `.matchedTransitionSource(id: "habit-all")` 一并删除 ——
    /// zoom 转场依赖**系统 sheet** 的呈现链（navigationTransition 挂在弹窗目标上），改成页级毛玻璃浮层后
    /// 这条链不存在，留着就是死代码（备忘录 4.0.77 改浮层时漏删的就是这两行，本次一起清）。

    /// v4.0.47：打卡显示的「今天」。卡片里「今日已打卡 · 连续 N 天」全是渲染时现算的，
    /// 而 `Date()` 不是被观察的依赖 → App 常驻跨午夜会一直显示昨天的状态（数据没错、显示骗人）。
    /// 把「今天」提成 @State 并让渲染读它（下面的 isDone/currentStreak/lastNDays 都传它），
    /// 跨天或回前台时更新 → 强制 body 重算。
    /// v4.0.78：这是**宿主 section 自己**那份（供页卡用）；三张浮层内容各自持一份（见各 struct），
    /// 语义一致、互不干扰 —— 宿主 section 的 ticker / onChange 逻辑原样保留在这里。
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
            // 🚨 v4.0.78：原来挂在这里的三条 `.sheet`（新建 / 全部列表 / 详情）已删除。
            // 三个浮层改由页级宿主 HabitGlassLayerHost 渲染（挂 LifeView 根 → 全屏）。
            // 删除类二次确认框也随之搬去页级宿主（原来挂在下面 root 上 / 列表里那份由列表自带），
            // 理由见 LifeSectionScaffold 里 LifeDeleteConfirm 的注释 + HabitGlassLayerHost。
    }

    private var root: some View {
        VStack(alignment: .leading, spacing: 8) {
            pageHeader
            if store.habits.isEmpty {
                emptyTap
            } else {
                topCard
            }
        }
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

    /// v4.0.78：开关状态提到 presenter（原 section @State.showAdd / addSession）
    private func startAdd() {
        // v4.0.78：开新建前先把其它浮层收干净（三层浮层互斥）
        glass.showAll = false
        glass.detail = nil
        glass.addSession += 1
        glass.showAdd = true
    }

    // MARK: 页面单卡（显示列表最上的一条）

    @ViewBuilder
    private var topCard: some View {
        if let top = store.sorted.first {
            // v4.0.78：行卡渲染抽成文件级 HabitRowCard（页卡 / 全部列表两处共用一份几何，同 MemoNoteCard），
            // 打卡圆的值走本 section 自己的 today（宿主那份）。
            HabitRowCard(h: top, today: today, compact: true)
                .onTapGesture { openTop(top) }
                .contextMenu {
                    HabitMenuItems(h: top, today: today,
                                   onView: { openDetailFromCard($0) },
                                   onDelete: { glass.pendingDelete = $0 })
                }
                .accessibilityLabel("习惯 \(top.title)，\(habitStreakText(top, today: today))，点开查看")
        }
    }

    /// 点页卡：只有 1 个时「全部习惯」列表是多余的一跳 → 直接进详情（原 openTop 语义不变）。
    /// v4.0.78：原 fromList:false 分支把 detailCurrent 设为 store 里的**当前**副本再开详情；
    /// 现在 presenter.detail 直接承载这个「当前副本」（不再需要单独的 detailCurrent 渲染快照）。
    private func openTop(_ h: HabitItem) {
        if store.sorted.count == 1 {
            openDetailFromCard(h)
        } else {
            glass.showAdd = false
            glass.detail = nil
            glass.showAll = true
        }
    }

    /// 从页卡/页卡菜单开详情（原 openDetail(fromList: false) 的等价物）：直接置 presenter.detail。
    private func openDetailFromCard(_ h: HabitItem) {
        glass.showAll = false
        glass.showAdd = false
        glass.detail = store.habits.first { $0.id == h.id } ?? h
    }

    // MARK: 长按菜单（页卡 / 列表共用）
    //
    // v4.0.78：菜单项内容提到文件级 HabitMenuItems 小 struct（页卡与页级浮层列表共用同一套）；
    // 这里只做转发。打卡/查看/删除的**行为差异**由调用方闭包注入（页卡 → 直接置 presenter 状态；
    // 列表 → 先收列表再开详情 / 走列表内部的删除确认）。

    // MARK: 新建 / 全部列表 / 详情
    //
    // v4.0.78：原 addSheet / allSheet / detailSheet 三张系统 sheet 的内容已搬到文件级
    // HabitAddBody / HabitAllListBody / HabitDetailSheet（见文件底部），由页级宿主渲染。
}

// MARK: - v4.0.78 习惯浮层的「页级宿主」
//
// 🚨 为什么单开一个宿主（用户 2026-10-08 原话「习惯卡片也改成跟备忘录一样的全屏弹出」）：
// 先例 = v4.0.77 备忘录（MemoSection.swift 底部 MemoGlassPresenter / MemoGlassLayerHost，已上线真机验收）：
// v4.0.76 把备忘录三个毛玻璃浮层挂在 MemoSection 自己的 ZStack 里，而 MemoSection 只是生活页滚动区
// 里的一行 → 浮层几何被限制在这一行：轻纱只罩住卡片那一条、面板从卡片边缘长出、随列表滚走。
// 浮层要「全屏」就必须挂在**页面根**、滚动区之外。
//
// 做法（与备忘录 1:1 同形）：三个开关（showAll / detail / showAdd）提到页级单例 HabitGlassPresenter，
// HabitSection 只改状态；浮层本体由本 struct 渲染，挂载点 = LifeView body 最外层的 `.overlay`（全屏层，
// 由主会话统一挂）。视图树内顺序仍是：全部列表 < 详情 < 新建（后开的盖在前面）。

@MainActor
@Observable
final class HabitGlassPresenter {
    static let shared = HabitGlassPresenter()

    /// 「全部习惯」列表浮层
    var showAll = false
    /// 「新建习惯」浮层
    var showAdd = false
    /// 详情浮层（nil = 不显示；承载的即 store 里的当前副本，取代旧 detailCurrent）
    var detail: HabitItem?
    /// 宿主（页卡）删除二次确认：页卡长按「删除」→ 置这里 → 由 HabitGlassLayerHost 的
    /// LifeDeleteConfirm 呈现（alert 是窗口级，盖在浮层之上）。
    var pendingDelete: HabitItem?
    /// 新建浮层的会话序号：每次打开自增，配合 `.id()` 强制换新实例（保证每次都是空编辑器）
    var addSession = 0

    private init() {}

    /// 宿主销毁时清状态 —— 单例不会随视图树消失，页面被系统回收后重建，开关还是 true →
    /// 回到生活页会「莫名又弹着上次那个浮层」。挂在 HabitGlassLayerHost 的 .onDisappear 上
    /// （宿主与生活页同生共死）。同 MemoGlassPresenter.reset()。
    func reset() {
        showAll = false
        showAdd = false
        detail = nil
        pendingDelete = nil
        addSession = 0
    }
}

/// 习惯浮层的页级宿主（挂 LifeView 根 → 全屏；轻纱盖住整页含页头）
struct HabitGlassLayerHost: View {
    private var glass = HabitGlassPresenter.shared
    private var store = HabitStore.shared

    var body: some View {
        ZStack {
            if glass.showAll {
                MemoGlassOverlay(isPresented: Binding(
                    get: { glass.showAll },
                    set: { if !$0 { glass.showAll = false } }
                )) {
                    HabitAllListBody(
                        onDone: { glass.showAll = false },
                        onOpenDetail: { openDetailFromAll($0) }
                    )
                }
            }
            if let h = glass.detail {
                MemoGlassOverlay(isPresented: Binding(
                    get: { glass.detail != nil },
                    set: { if !$0 { glass.detail = nil } }
                )) {
                    HabitDetailSheet(item: h, onDismiss: { glass.detail = nil })
                }
            }
            if glass.showAdd {
                MemoGlassOverlay(isPresented: Binding(
                    get: { glass.showAdd },
                    set: { if !$0 { glass.showAdd = false } }
                )) {
                    // 新建浮层内容（原 HabitSection.addSheet）：外壳收进 LifeNoteComposeSheet，
                    // formSheet:false = 毛玻璃浮层形态（自绘顶栏 取消/保存）；每次打开换新实例（.id）→ 打开即空白。
                    HabitAddBody(
                        onCancel: { glass.showAdd = false },
                        onSaved: { glass.showAdd = false }
                    )
                    .id(glass.addSession)
                }
            }
        }
        // 🚨 宿主销毁即清状态 —— 页面重建后不会「莫名又弹上次那个浮层」（见 HabitGlassPresenter.reset）
        .onDisappear { HabitGlassPresenter.shared.reset() }
        // 🚨 删除确认框**与浮层同宿主**：页卡那份原来挂在 HabitSection 的 root 上（生活页滚动区里的
        // LazyVStack 行），而行可能被 LazyVStack 回收 → 「点了删除没反应」。现在跟着浮层上收到本宿主
        // （页卡长按删除 → presenter.pendingDelete）。列表里那份由 HabitAllListBody 自带（见其内部
        // LifeDeleteConfirm），两处各管各的、不共用一个 pending。alert 是窗口级 → 盖在毛玻璃浮层之上。
        .modifier(LifeDeleteConfirm(
            title: "删除这个习惯？",
            pending: glass.pendingDelete,
            onCancel: { glass.pendingDelete = nil },
            onDelete: { store.delete($0) },
            message: { $0.title.prefix(40).description }
        ))
    }

    /// 从列表点一条 → **同帧**换成详情浮层（v4.0.78：浮层是外层 if 门控的硬切、没有退场动画，
    /// 原来那 500ms 缓冲只剩「点了半秒没反应」，还带来 in-flight Task 窗口 → 删）。
    /// ⚠️ 备忘录 `MemoSection.afterAllDismissed` 仍是 4.0.77 的 500ms 形态（本轮未动，避免误伤已验收行为）。
    private func openDetailFromAll(_ h: HabitItem) {
        // v4.0.78：同帧换状态（原 500ms 错峰为等系统 sheet 退场动画；浮层硬切无退场 →
        // 延迟+in-flight Task 窗口一起删，理由同 TodoSection.openDetailFromAll）
        glass.showAll = false
        glass.showAdd = false
        glass.detail = store.habits.first { $0.id == h.id } ?? h
    }
}

// MARK: - v4.0.78 长按菜单项（页卡 / 全部列表两处共用）
//
// ⚠️ 文件级函数默认非 MainActor 隔离（只有 View 的成员才是）→ 本体里调 Haptics / HabitStore
// 这类 MainActor API 必须显式 `@MainActor`；否则只有 CI Archive 会报
// `call to main actor-isolated ... in a synchronous nonisolated context`（本机 `-parse` 查不出；
// 仓内先例：MemoSection.memoCardMenuItems、ImageCache.swift 的全局函数都带 `@MainActor`）。
// today 由调用方（页卡用宿主那份 / 列表用列表自己那份）注入，保证与各自渲染口径一致。

/// 习惯行菜单（页卡 / 全部列表两处共用一份）。
/// v4.0.78：从**自由函数**改成小 struct —— 护栏「裸函数调用都有定义」（scripts/ql_membercheck）
/// 的定义集只收 func/let/struct/var 形态，自由函数里的**闭包形参**（onView / onDelete）会被判成
/// 「疑似未定义调用」。按本仓约定正解是改写成类型（别去放宽那条护栏）。渲染逐字不变。
private struct HabitMenuItems: View {
    let h: HabitItem
    let today: Date
    let onView: (HabitItem) -> Void
    let onDelete: (HabitItem) -> Void

    var body: some View {
        Button {
            toggleHabit(h, today: today)
        } label: {
            Label(HabitStore.shared.isDone(h, on: today) ? "取消今日打卡" : "今日打卡",
                  systemImage: HabitStore.shared.isDone(h, on: today) ? "arrow.uturn.backward" : "checkmark.circle.fill")
        }
        Button {
            onView(h)
        } label: {
            Label("查看", systemImage: "eye")
        }
        Button(role: .destructive) {
            onDelete(h)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }
}
/// 打卡/取消打卡（幂等；原 HabitSection.toggle 逐字平移）。
/// 打卡走 store 的默认 day（= Date()），展示用 today 判断——与原实现一致（口径不动）。
@MainActor
private func toggleHabit(_ h: HabitItem, today: Date) {
    if HabitStore.shared.isDone(h, on: today) {
        HabitStore.shared.undo(h)
    } else if HabitStore.shared.checkIn(h) {
        Haptics.success()
    }
}

/// 「连续 N 天 · 今日已打卡 / 今天还没打卡」文案（原 HabitSection.streakText 逐字平移，文案不动）。
/// 页卡（宿主 today 一份）与行卡（各自 today 一份）共用。
@MainActor
private func habitStreakText(_ h: HabitItem, today: Date) -> String {
    let s = HabitKit.currentStreak(h, today: today)
    if HabitStore.shared.isDone(h, on: today) { return "连续 \(s) 天 · 今日已打卡" }
    return s > 0 ? "连续 \(s) 天 · 今天还没打卡" : "今天还没打卡"
}

// MARK: - v4.0.78 习惯行卡（页级单卡 / 全部列表行共用；原 HabitSection.habitCard 逐字平移）
//
// 差异走 compact（与旧实现一致）：
//   compact = true   页级单卡：标题 2 行 + 卡高兜底到「生活数据」行情卡同高（MemoCardMetrics）
//   compact = false  全部列表行：标题 3 行 + 自然高度
// 时间逻辑：today 由调用方注入（页卡 = 宿主 today；列表 = HabitAllListBody 自己的 today）。

struct HabitRowCard: View {
    let h: HabitItem
    let today: Date
    var compact: Bool = false

    /// 计算属性（非存储属性）→ 不进 memberwise init，也不触发「私有存储属性降级 init 访问级别」那条规则
    private var store: HabitStore { HabitStore.shared }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            checkCircle
            VStack(alignment: .leading, spacing: 5) {
                Text(h.title)
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.primary)
                    .lineLimit(compact ? MemoCardMetrics.lineLimit : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                streakLine
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity,
               minHeight: compact ? MemoCardMetrics.minHeight : 0,
               alignment: .leading)
        .pastelCard()
        .contentShape(Rectangle())
    }

    private var checkCircle: some View {
        let done = store.isDone(h, on: today)
        return Button {
            toggleHabit(h, today: today)
        } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(done ? Color.green : Color.secondary.opacity(0.4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(done ? "取消今日打卡" : "今日打卡")
    }

    private var streakLine: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "flame.fill")
                .font(.system(size: Typography.tiny))
            Text(habitStreakText(h, today: today))
                .font(.system(size: Typography.tiny))
            // v4.0.79（P3-14 深度）：断签提示 —— 打卡连续中断时才多这一段（口径：断满 ≥1 整天
            // 且历史最好连续 ≥2 天；今天还没结束不算「今天漏了」）。工作模式专属，生活模式回 nil。
            if let brk = WorkbenchInsight.habitBreakBadge(dayKeys: h.days, today: today) {
                Text("·")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                Text(brk)
                    .font(.system(size: Typography.tiny, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(store.isDone(h, on: today) ? Color.orange : Color.secondary)
    }
}

// MARK: - v4.0.78 新建浮层内容（原 HabitSection.addSheet 逐字平移）
//
// 系统 sheet 形态（formSheet 默认 true）→ 毛玻璃浮层形态（formSheet:false，自绘顶栏 取消/保存）。
// 正文由 LifeNoteComposeSheet 自己的 @State 持有；靠宿主 `.id(addSession)` 换实例保证每次空白。

struct HabitAddBody: View {
    let onCancel: () -> Void
    let onSaved: () -> Void

    /// 计算属性（见 HabitRowCard 同款理由）
    private var store: HabitStore { HabitStore.shared }

    var body: some View {
        LifeNoteComposeSheet(
            title: "新建习惯",
            placeholder: "想坚持什么…",
            onSave: { text in
                if store.add(title: text) {
                    Haptics.success()
                }
                onSaved()
            },
            onCancel: { onCancel() },
            formSheet: false
        )
    }
}

// MARK: - v4.0.78 「全部习惯」浮层内容（原 HabitSection.allSheet 的 NavigationStack 内主体，逐字平移）
//
// 外壳（NavigationStack / presentationDetents / navigationTransition.zoom）由 MemoGlassOverlay 替代；
// 顶栏照旧自绘（全部习惯 + 今日已打卡 N + 完成胶囊）。
// 删除二次确认：**本主体自带**（LifeDeleteConfirm）—— 页卡那份在页级宿主，两处各管各的。

struct HabitAllListBody: View {
    let onDone: () -> Void
    let onOpenDetail: (HabitItem) -> Void

    /// 计算属性（见 HabitRowCard 同款理由）
    private var store: HabitStore { HabitStore.shared }
    /// 列表内左滑/长按删除的二次确认（挂浮层内容内部；宿主那份管页卡）
    @State private var pendingDeleteInList: HabitItem?

    /// v4.0.78：列表行也显示「今日已打卡 / 连续 N 天」→ 需要自己的「今天」并跨天自刷新
    /// （原实现读的是宿主 section 的 today；搬进本 struct 后**按原样**在这里重新表达）。
    @State private var today = Date()
    @State private var dayTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("全部习惯")
                    .font(.system(size: Typography.title, weight: .semibold))
                Text("今日已打卡 \(store.todayDoneCount)")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                MiniCapsule(title: "完成", accent: true) { onDone() }
            }
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.md)
            List {
                ForEach(store.sorted) { h in
                    HabitRowCard(h: h, today: today, compact: false)
                        .onTapGesture { onOpenDetail(h) }
                        .contextMenu {
                            // 查看 → 走宿主 onOpenDetail（先收列表再开详情，与行点击同一条路）；
                            // 删除 → 走本列表自带的确认框（浮层还开着时宿主 alert 会被盖住）
                            HabitMenuItems(h: h, today: today,
                                           onView: { onOpenDetail($0) },
                                           onDelete: { pendingDeleteInList = $0 })
                        }
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
                    pendingDeleteInList = store.sorted[idx]
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
        // 本列表自己那份删除确认（与页级宿主那份**同宿主于浮层内容**，互补）
        .modifier(LifeDeleteConfirm(
            title: "删除这个习惯？",
            pending: pendingDeleteInList,
            onCancel: { pendingDeleteInList = nil },
            onDelete: { store.delete($0) },
            message: { $0.title.prefix(40).description }
        ))
        // 跨天自刷新（与宿主 section 同款写法；语义不被破坏）
        .onReceive(dayTicker) { now in
            if !Calendar.current.isDate(now, inSameDayAs: today) { today = now }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !Calendar.current.isDateInToday(today) { today = Date() }
        }
    }
}

// MARK: - v4.0.78 详情 / 编辑浮层内容（原 HabitSection.detailSheet 逐字平移）
//
// 原渲染快照 detailCurrent / 编辑态 detailEditing·editDraft 搬进本 struct 自己的 @State；
// 原 refreshDetail() → refreshCurrent()（同一逻辑：以 store 当前副本覆盖本地快照）。
// 时间逻辑：打卡圆 / detailStreakText / dayCurve 都读本 struct 自己的 today（按原样重新表达；
// 跨天 ticker + 回前台补一次，语义与宿主 section 一致）。
// 系统 sheet 的 presentationDetents / interactiveDismissDisabled 随外壳一并移除——浮层没有下滑手势，
// 编辑态草稿天然安全（同 MemoDetailSheet）。

private struct HabitDetailSheet: View {
    let onDismiss: () -> Void

    /// 本地副本：打卡/编辑后要立刻反映在本页（item 是值传进来的）
    @State private var current: HabitItem
    @State private var editing = false
    @State private var editDraft = ""
    @State private var today = Date()
    @State private var dayTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @Environment(\.scenePhase) private var scenePhase

    private var store = HabitStore.shared

    init(item: HabitItem, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        _current = State(initialValue: item)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if editing {
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
                            toggleHabit(current, today: today)
                            refreshCurrent()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: store.isDone(current, on: today) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 26, weight: .medium))
                                    .foregroundStyle(store.isDone(current, on: today) ? Color.green : Color.secondary.opacity(0.4))
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(current.title)
                                        .font(.system(size: Typography.headline))
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(detailStreakText(current))
                                        .font(.system(size: Typography.caption))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(Spacing.xl)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .pastelCard()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle())
                        dayCurve(current)
                        if !store.isDone(current, on: today) {
                            Text("今天还没打卡 · 点上面的圆即可打卡")
                                .font(.system(size: Typography.caption))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(18)
                }
            }
        }
        // 跨天自刷新（与宿主 section 同款写法；语义不被破坏）
        .onReceive(dayTicker) { now in
            if !Calendar.current.isDate(now, inSameDayAs: today) { today = now }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !Calendar.current.isDateInToday(today) { today = Date() }
        }
    }

    // MARK: 顶栏（自绘；口径照备忘录 MemoDetailSheet.topBar：小胶囊 + 居中标题）
    //
    // 左「关闭」（原「关闭」文案不动；编辑态下关闭=收起整个浮层，走 onDismiss）；
    // 右：编辑态「保存」accent（空草稿禁用），否则「编辑」。

    private var topBar: some View {
        HStack(spacing: 8) {
            MiniCapsule(title: "关闭") {
                onDismiss()
            }
            Spacer(minLength: 0)
            if editing {
                MiniCapsule(title: "保存", accent: true) {
                    store.update(current, title: editDraft)
                    refreshCurrent()
                    editing = false
                }
                .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                MiniCapsule(title: "编辑") {
                    editDraft = current.title
                    editing = true
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
    }

    /// 原 HabitSection.refreshDetail()：以 store 当前副本覆盖本地渲染快照
    private func refreshCurrent() {
        guard let idx = store.habits.firstIndex(where: { $0.id == current.id }) else { return }
        current = store.habits[idx]
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
        .pastelCard()
    }

    /// 14 个日期全标会挤 → 只在首/中/末三处标标签（其余留同高空白占位）
    private func showDayLabel(_ idx: Int, total: Int) -> Bool {
        idx == 0 || idx == total - 1 || idx == total / 2
    }
}
