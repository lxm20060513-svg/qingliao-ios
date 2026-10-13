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

    /// v4.0.99（用户 2026-10-12「习惯卡片点击不弹窗，改成跟待办清单一样的卡片展开显示」）：
    /// 页卡点开 = **就地向下展开全部习惯行卡**（点行 = 打卡），不再开「全部习惯」浮层。
    /// 浮层入口不丢 —— 挪到展开区底部那行「全部习惯」（`glass.showAll = true`）。
    /// 与待办卡同一套交互（`todoExpanded` 同构）；**长期目标卡 v4.0.100 已改为点卡直接开浮层**，
    /// 不再与习惯同构 —— 别拿习惯去「对齐」目标（这一处分叉是用户 2026-10-12 点名要的）。
    @State private var habitExpanded = false

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
            // v4.0.99：习惯被删空时复位展开态（与记录 / 目标两张卡同款）—— 否则删光后再新建第一个
            // 习惯，它以「已展开」形态凭空出现（用户没点过任何东西）。
            .onChange(of: store.habits.isEmpty) { _, empty in
                if empty { habitExpanded = false }
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
            onAdd: startAdd,
            sectionIcon: LifeSection.habit.icon,
            sectionIconTint: LifeSection.habit.tint
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
        let stats = HabitKit.cardStats(store.sorted, today: today)
        return Group {
            if let top = store.sorted.first {
                // v4.0.97（用户 2026-10-11「习惯卡片做成上图的样式」）：页卡由**行卡**换成
                // **圆环 + 三行指标**的统计卡。原 HabitRowCard(compact: true) 口径作废；
                // 列表行 HabitRowCard(compact: false) 不受影响，仍是原来的行卡。
                //
                // v4.0.99（用户 2026-10-12「习惯卡片点击不弹窗，改成跟待办一样的卡片展开显示」）：
                // 点卡从「开全部习惯浮层 / 单条直接进详情」改成**就地向下展开**（Button + PressStyle，
                // 与待办/目标卡同一套按压反馈与读屏口径 —— 原来是裸 onTapGesture）。
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        toggleExpand()
                    } label: {
                        HabitProgressCard(stats: stats)
                    }
                    .buttonStyle(PressStyle())
                    .contextMenu {
                        HabitMenuItems(h: top, today: today,
                                       onView: { openDetailFromCard($0) },
                                       onDelete: { glass.pendingDelete = $0 },
                                       // v4.0.97（用户 2026-10-11 选 1:1）：卡面是聚合指标、菜单作用在
                                       // 「最近更新那条」，两者不同一条 → 页卡不挂「删除」（详情页里仍可删）
                                       showsDelete: false)
                    }
                    .accessibilityLabel(habitExpanded
                                        ? "习惯统计，已展开，点一下收起"
                                        : "习惯统计，近 7 天完成 \(stats.done) / \(stats.total)，点一下展开")

                    if habitExpanded {
                        habitExpandList(store.sorted)
                    }
                }
            }
        }
    }

    /// 点页卡：展开 / 收起 —— 逐条错峰弹出见 habitExpandList（与待办卡同口径）
    /// v4.0.100：曲线 `settle` → `cardExpand`（用户「点击弹开动画再丝滑一点」）。
    private func toggleExpand() {
        withAnimation(Motion.cardExpand) { habitExpanded.toggle() }
        Haptics.tap()
    }

    // MARK: v4.0.99 页卡「点击向下展开」的习惯行列表（与 TodoExpandList 同几何）

    /// 展开区：全部习惯逐条弹出（每条错峰 55ms），**点行 = 打卡/取消打卡**（与待办同理，
    /// 行的主操作就是打勾）；行卡复用「全部习惯」浮层那张 `HabitRowCard`（`checkAsButton: false`
    /// —— 整行已是 Button，内层再套一枚会抢点击），长按菜单补「查看 / 打卡」。
    /// 底部「全部习惯 N 个 ›」= 原「点卡直接开」的那个浮层入口（不丢）。
    private func habitExpandList(_ habits: [HabitItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(habits.enumerated()), id: \.element.id) { idx, h in
                Button {
                    tapHabit(h, today: today)
                } label: {
                    HabitRowCard(h: h, today: today, checkAsButton: false,
                                 onOpenFocus: { FocusGlassPresenter.shared.open(habitId: h.id) })
                }
                .buttonStyle(PressStyle())
                .contextMenu {
                    HabitMenuItems(h: h, today: today,
                                   onView: { openDetailFromCard($0) },
                                   onDelete: { glass.pendingDelete = $0 })
                }
                .transition(.asymmetric(
                    insertion: .offset(y: -14).combined(with: .opacity)
                        .combined(with: .scale(scale: 0.97, anchor: .top)),
                    removal: .opacity
                ).animation(Motion.cardExpand.delay(Double(idx) * 0.055)))
            }

            // 只有一条时「全部习惯」是多余的一跳（展开区里已经把它画全了）→ 不显示这行。
            if habits.count > 1 {
                Button {
                    openAllHabits()
                } label: {
                    HStack(spacing: 6) {
                        Text("全部习惯")
                            .font(.system(size: Typography.subhead, weight: .medium))
                        Spacer(minLength: 0)
                        Text("\(habits.count) 个")
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: Typography.caption, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .pastelCard(cornerRadius: 18)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    /// 开「全部习惯」浮层（展开区底部那行入口走这里；三层浮层互斥口径同其它入口）
    private func openAllHabits() {
        glass.showAdd = false
        glass.detail = nil
        glass.showAll = true
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
final class HabitGlassPresenter: LifeGlassPresenterBase<HabitItem> {
    static let shared = HabitGlassPresenter()
    override private init() {}
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
            // v4.0.104：专注计时浮层（第四层；与本文件其它三层同形 → 全屏毛玻璃）。
            // 状态在 FocusGlassPresenter（本文件自己的页级单例），没去动共享的 LifeGlassPresenterBase。
            if let fid = FocusGlassPresenter.shared.habitId {
                MemoGlassOverlay(isPresented: Binding(
                    get: { FocusGlassPresenter.shared.habitId != nil },
                    set: { if !$0 { FocusGlassPresenter.shared.habitId = nil } }
                )) {
                    FocusTimerBody(habitId: fid, onClose: { FocusGlassPresenter.shared.close() })
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
        .onDisappear {
            HabitGlassPresenter.shared.reset()
            FocusGlassPresenter.shared.reset()   // v4.0.104：专注计时浮层同理，别在页面重建后弹回来
        }
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
    /// v4.0.97（用户 2026-10-11 选「1:1」）：页卡卡面是**聚合**指标（近 7 天完成率 / 最长连续 /
    /// 「XX 最多」），而本菜单作用于 `store.sorted.first`「最近更新那条」—— 两个目标不是同一条，
    /// 用户看到卡面写着「愉悦最多」、长按删除却删掉了另一条。**所以页卡不挂「删除」**
    ///（删除仍可从「查看」进的详情页里做，入口不丢）；列表行是逐条渲染的，照常显示。
    var showsDelete: Bool = true

    var body: some View {
        if h.isMetric {
            // v4.0.104：计量习惯走打卡是**空操作**（checkingIn 有 !isMetric 守卫）→ 菜单里换成加一笔，
            // 否则菜单项点了毫无反馈、文案与行为不符。
            Button {
                if HabitStore.shared.addAmount(HabitKit.metricStep(h), to: h) { Haptics.light() }
            } label: {
                Label("加一笔（+\(HabitKit.numberText(HabitKit.metricStep(h)))\(h.unitText)）",
                      systemImage: "plus.circle.fill")
            }
        } else {
            Button {
                toggleHabit(h, today: today)
            } label: {
                Label(HabitStore.shared.isDone(h, on: today) ? "取消今日打卡" : "今日打卡",
                      systemImage: HabitStore.shared.isDone(h, on: today) ? "arrow.uturn.backward" : "checkmark.circle.fill")
            }
        }
        Button {
            onView(h)
        } label: {
            Label("查看", systemImage: "eye")
        }
        if showsDelete {
            Button(role: .destructive) {
                onDelete(h)
            } label: {
                Label("删除", systemImage: "trash")
            }
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

/// v4.0.104：点一行的**分流** —— 二值 = 打卡/取消（逐字不变）；计量 = 加一个步长（点一下记一笔，
/// 与待办同构）；正在为它专注 = 回到计时器（否则展开区点「专注中」的行会把量又加一笔，人会懵）。
@MainActor
private func tapHabit(_ h: HabitItem, today: Date) {
    if FocusTimerStore.shared.session?.habitId == h.id {
        FocusGlassPresenter.shared.open(habitId: h.id)
        return
    }
    if h.isMetric {
        if HabitStore.shared.addAmount(HabitKit.metricStep(h), to: h, on: today) {
            Haptics.light()
        }
        return
    }
    toggleHabit(h, today: today)
}

/// 「连续 N 天 · 今日已打卡 / 今天还没打卡」文案（原 HabitSection.streakText 逐字平移，文案不动）。
/// 页卡（宿主 today 一份）与行卡（各自 today 一份）共用。
@MainActor
private func habitStreakText(_ h: HabitItem, today: Date) -> String {
    let s = HabitKit.currentStreak(h, today: today)
    if HabitStore.shared.isDone(h, on: today) { return "连续 \(s) 天 · 今日已打卡" }
    return s > 0 ? "连续 \(s) 天 · 今天还没打卡" : "今天还没打卡"
}

// MARK: - v4.0.97 习惯页卡：圆环 + 三行指标（用户 2026-10-11「习惯卡片做成上图的样式」）
//
// 参考图口径：左「粗圆环 + 环内百分比」，右三行「小圆底图标 + 主值 + 副标」。
// 数据全部来自已有模型（HabitItem.days），零后端改动；**归日与窗口计算收在 HabitKit.cardStats**
//（视图层自己不碰 days、不碰 Calendar —— 第 72 段源级护栏）。口径：
//   环   = 近 7 天完成率 = done / (习惯数 × 7)
//   行① = 当前最长连续天数（所有习惯取 max；口径 HabitKit.currentStreak，「漏一天归零」）
//   行② = 近 7 天完成次数 / 应完成次数 —— **与环同源**（36/42 → 86%，两个数字必须自洽）
//   行③ = 累计打卡次数最多的习惯（≈ 参考图「愉悦最多」那一格的位置）
//
// ⚠️ 行②与环同源是刻意的：参考图里 36/42 = 85.7% ≈ 86%，两个数字对得上才不会显假。
// ⚠️ 打卡入口不在这张卡上（参考图也没有）—— 点卡仍走原 openTop（全部习惯 / 直接进详情），
//    打卡在行卡（HabitRowCard）与详情页里做。

/// 页卡圆环：弧长 = 近 7 天完成率，环内百分比
/// v4.0.98 尺寸口径（用户 2026-10-11「长期目标，待办事项，习惯卡尺寸改为一样大小」）：
/// 环 **70 / 线宽 8**（与 TodoProgressRing / GoalProgressRing 同款）、环内 18pt；
/// 卡内边距 h18 / top17 / bottom15、HStack 间距 17、圆角 26 —— 与另两张进度卡**逐项相同**，
/// 三张卡外框因此等高（内容 78pt + 内边距 32pt = 110pt）。
/// ⚠️ 三行指标走**单行制**（图标 + 主值 + 副标 同行，行高 22 / 行距 6 → 3×22 + 2×6 = 78）：
///    两行制（主值压副标）三行要 85pt 以上，卡会比另两张高一截 —— 用户点名的就是「一样大」。
private struct HabitProgressRing: View {
    let progress: Double
    var size: CGFloat = 70
    var lineWidth: CGFloat = 8

    private var percentText: String {
        "\(Int((min(1, max(0, progress)) * 100).rounded()))%"
    }

    var body: some View {
        ZStack {
            // v4.0.98：底环 0.10 → 0.12、零进度不吃 .round 线帽 —— 与待办/目标环逐字同口径
            //（原来 0% 时环顶会留一颗 lineWidth 直径的假点）
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth,
                                                              lineCap: progress > 0 ? .round : .butt))
                .rotationEffect(.degrees(-90))
            Text(percentText)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText(value: min(1, max(0, progress)) * 100))
        }
        .frame(width: size, height: size)
        .animation(Motion.settle, value: progress)
        .accessibilityHidden(true)
    }
}

/// 页卡右侧的一行：小圆底图标 + 主值 + 副标（参考图那一列）
///
/// v4.0.102（用户 2026-10-12 真机截图圈定「这三行的图标改成彩色」）：
/// 圆底由 `Color.primary.opacity(0.08)` 灰底 + `.secondary` 灰符号 → **语义实色底 + 白符号**，
/// 与看板栏目头（`BoardCardStyle`）、设置页行首色块、列表行 `BadgeShell` 同一口径
/// （那几处都是「实色底 + 白符号」，不再新造第二种彩色写法）。
/// ⚠️ `tint` 由**调用方**给，不在这里按 icon 再建一份映射 —— 三行是同一种语义的三种指标，
///    配色归页卡（`HabitProgressCard`），组件只管画。
private struct HabitMetricRow: View {
    let icon: String
    /// 圆底实色（v4.0.102；深浅模式由系统色自适应）
    let tint: Color
    let value: String
    let caption: String

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(tint)
                    .frame(width: 22, height: 22)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(caption)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 习惯页卡：左环 + 右三行（用户 2026-10-11 给的样式）
private struct HabitProgressCard: View {
    let stats: HabitCardStats

    private var streakValue: String {
        stats.streak > 0 ? "\(stats.streak) 天" : "还没开始"
    }
    private var topValue: String {
        stats.topTitle.isEmpty ? "还没有习惯" : "\(stats.topTitle) 最多"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 17) {
            HabitProgressRing(progress: stats.rate)
            VStack(alignment: .leading, spacing: 6) {
                // v4.0.102：三行各取语义色（火焰橙 / 日历蓝 / 统计绿），且**三色互不相同** ——
                // 三行同色等于又退回一片同色，白改（同 `BoardCard.tint` 的注释口径）。
                HabitMetricRow(icon: "flame.fill", tint: .orange, value: streakValue, caption: "连续记录")
                HabitMetricRow(icon: "calendar", tint: .blue, value: "\(stats.done) / \(stats.total)", caption: "近 7 天完成")
                HabitMetricRow(icon: "chart.bar.fill", tint: .green, value: topValue, caption: "打卡次数最多")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.top, 17)
        .padding(.bottom, 15)
        // v4.0.98：三张进度卡同挂 MemoCardMetrics.progressCardMinHeight（「一样大」的构造性保证）
        .frame(maxWidth: .infinity, minHeight: MemoCardMetrics.progressCardMinHeight, alignment: .leading)
        .pastelCard(cornerRadius: 26)
        .contentShape(Rectangle())
    }
}

// MARK: - v4.0.78 习惯行卡（页级单卡 / 全部列表行共用；原 HabitSection.habitCard 逐字平移）
//
// v4.0.97：页级单卡已换成 HabitProgressCard（圆环 + 三行指标），行卡只剩「全部列表」一处消费者 →
// 原先区分页级/列表的 `compact` 形参连同它那两个分支（标题行数 / 卡高兜底到行情卡同高）一并撤掉。
// 时间逻辑：today 由调用方注入（页卡 = 宿主 today；列表 = HabitAllListBody 自己的 today）。

struct HabitRowCard: View {
    let h: HabitItem
    let today: Date
    /// v4.0.99：整行被外层包成 Button 时（页卡展开区 —— 点行 = 打卡），内层这枚 Button 会与外层
    /// 抢点击/读屏重复；那边传 `false` → 勾选圈退成纯图形，动作由外层行 Button 承接。
    /// ⚠️ 新形参一律追加在尾部 + 给默认值（SwiftUI 实参序 = 声明序，仓内有 CI 护栏）。
    var checkAsButton: Bool = true
    /// v4.0.104：点「专注中」胶囊 → 打开计时器浮层（行卡不自己持 presenter，由调用方给）。
    /// ⚠️ 形参一律追加在尾部 + 给默认值（SwiftUI 实参序 = 声明序，仓内有 CI 护栏）。
    var onOpenFocus: (() -> Void)? = nil

    /// 计算属性（非存储属性）→ 不进 memberwise init，也不触发「私有存储属性降级 init 访问级别」那条规则
    private var store: HabitStore { HabitStore.shared }
    /// v4.0.104：专注计时（读它就能每秒刷新剩余时间的胶囊）
    private var focus: FocusTimerStore { FocusTimerStore.shared }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leftSlot
            VStack(alignment: .leading, spacing: 5) {
                Text(h.title)
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if h.isMetric { metricLine } else { streakLine }
                if focus.session?.habitId == h.id { focusChip }
            }
        }
        .padding(Spacing.section)
        .frame(maxWidth: .infinity,
               minHeight: 0,
               alignment: .leading)
        // v4.0.102（用户 2026-10-12 真机截图圈定「回国倒计时」行卡）：圆角 16(默认 Radius.card) → 22。
        // 取 `Radius.hero`（= 22）而不是写字面量 —— 用户给的是精确值，而它正好落在既有令牌档上。
        .pastelCard(cornerRadius: Radius.hero)
        .contentShape(Rectangle())
    }

    /// v4.0.104：二值习惯 = 原勾选圈（行为逐字不变）；计量习惯 = 进度环（点行/点它都加一个步长）
    @ViewBuilder
    private var leftSlot: some View {
        if h.isMetric { metricRing } else { checkCircle }
    }

    /// 计量进度环（小号；百分比取整，环内显示）。与页卡那只大环同语言，不再自造第二套形状语言。
    private var metricRing: some View {
        let frac = HabitKit.progressFraction(h, on: today)
        let done = store.isDone(h, on: today)
        return ZStack {
            Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 3)
            if frac > 0 {
                Circle()
                    .trim(from: 0, to: min(1, frac))
                    .stroke(done ? Color.green : Color.green.opacity(0.75),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text("\(Int((min(1, frac) * 100).rounded()))")
                .font(.system(size: Typography.tiny, weight: .semibold))
                .foregroundStyle(done ? Color.green : Color.secondary)
        }
        .frame(width: 30, height: 30)
        .accessibilityLabel(HabitKit.progressText(h, on: today))
    }

    /// 计量行：进度文案 + 连续天数 + 细进度条；右侧加减只在「本行没被外层包成 Button」时给
    /// （包成 Button 的那处，整行点击已经是「加一笔」，再塞内层按钮会和外层抢点击 —— 仓内既有口径）
    private var metricLine: some View {
        let done = store.isDone(h, on: today)
        let s = HabitKit.currentStreak(h, today: today)
        let text = s > 0
            ? "\(HabitKit.progressText(h, on: today)) · 连续 \(s) 天"
            : HabitKit.progressText(h, on: today)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: Typography.tiny))
                Text(text)
                    .font(.system(size: Typography.tiny))
                Spacer(minLength: 0)
                if checkAsButton { stepButtons }
            }
            .foregroundStyle(done ? Color.orange : Color.secondary)
            MetricProgressBar(fraction: HabitKit.progressFraction(h, on: today))
        }
    }

    private var stepButtons: some View {
        HStack(spacing: 12) {
            Button {
                adjust(-1)
            } label: {
                Image(systemName: "minus.circle").font(.system(size: 17))
            }
            .buttonStyle(.borderless)
            .disabled(store.progress(h, on: today) <= 0)
            .accessibilityLabel("减少")

            Button {
                adjust(1)
            } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 17))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("加一笔")
        }
        .foregroundStyle(Color.green)
    }

    private func adjust(_ sign: Double) {
        if store.addAmount(HabitKit.metricStep(h) * sign, to: h, on: today) {
            Haptics.light()
        }
    }

    /// 正在专注的提示胶囊（每秒跟着 FocusTimerStore 现算的剩余时间刷新）
    private var focusChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "timer").font(.system(size: Typography.tiny))
            Text("专注中 \(HabitKit.focusClock(focus.remaining))")
                .font(.system(size: Typography.tiny, weight: .medium))
        }
        .foregroundStyle(Color.green)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.green.opacity(0.12), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { onOpenFocus?() }
        .accessibilityLabel("专注中，点击打开计时器")
    }

    @ViewBuilder
    private var checkCircle: some View {
        let done = store.isDone(h, on: today)
        if checkAsButton {
            Button {
                toggleHabit(h, today: today)
            } label: {
                mark(done)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(done ? "取消今日打卡" : "今日打卡")
        } else {
            mark(done)
                .accessibilityHidden(true)
        }
    }

    /// v4.0.99（用户 2026-10-12「app 整体做视觉对齐」）：勾选圈统一走跨文件单一来源
    /// `LifeCheckCircle`（与待办 / 长期目标展开区同一枚），不再各画各的 SF Symbol。
    private func mark(_ done: Bool) -> some View {
        // v4.0.100：不传 size —— 尺寸真源收在 LifeCheckCircle.defaultSize（20）。
        LifeCheckCircle(done: done, tint: .green)
            .contentShape(Rectangle())
    }

    private var streakLine: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "flame.fill")
                .font(.system(size: Typography.tiny))
            Text(habitStreakText(h, today: today))
                .font(.system(size: Typography.tiny))
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
                    HabitRowCard(h: h, today: today,
                                 onOpenFocus: { FocusGlassPresenter.shared.open(habitId: h.id) })
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
    /// v4.0.104 计量设置的内联编辑器（不另开浮层：详情页里就地改，与「编辑标题」同款就地形态）
    @State private var metricEditing = false
    @State private var metricDraftKind: HabitMetric = .amount
    @State private var metricDraftTarget = ""
    @State private var metricDraftUnit = ""

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
                        // v4.0.104：计量习惯不走打卡按钮（点圈对它是空操作）→ 换成进度卡（含加减 / 专注入口）
                        if current.isMetric {
                            metricDetailCard
                        } else {
                        Button {
                            toggleHabit(current, today: today)
                            refreshCurrent()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                // v4.0.99：与 HabitRowCard 的勾选圈同一枚，不再自绘 SF Symbol。
                                // v4.0.100：不传 size —— 尺寸真源收在 LifeCheckCircle.defaultSize（20）。
                                LifeCheckCircle(done: store.isDone(current, on: today), tint: .green)
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
                        }
                        metricSettingsBlock
                        if !current.isMetric { binaryFocusEntry }
                        dayCurve(current)
                        if !current.isMetric && !store.isDone(current, on: today) {
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
        // v4.0.104：专注浮层是从详情页开的，关掉后必须刷新详情快照 —— 详情读的是 @State `current`，
        // 不刷就会继续显示「专注前」的进度与连续天数（审查实测出的过期数据）。
        .onChange(of: FocusGlassPresenter.shared.habitId) { _, fid in
            if fid == nil { refreshCurrent() }
        }
    }

    // MARK: v4.0.104 计量（量 / 时长）—— 详情页的进度卡 + 设置区

    /// 计量习惯的详情进度卡（替掉打卡大按钮那一块；点一下 = 加一个步长）
    private var metricDetailCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(current.title)
                .font(.system(size: Typography.headline))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(detailStreakText(current))
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Text(HabitKit.progressText(current, on: today))
                    .font(.system(size: Typography.subhead, weight: .medium))
                MetricProgressBar(fraction: HabitKit.progressFraction(current, on: today))
            }
            HStack(spacing: 10) {
                stepButton(sign: -1, icon: "minus.circle", label: "减少")
                stepButton(sign: 1, icon: "plus.circle.fill", label: "加一笔")
                Spacer(minLength: 0)
                // v4.0.104：**量维度也能开专注**（原先把入口卡在 .duration 上，量维度摸不到番茄钟，
                // 浮层里那段「自动升级为时长」也就成了死代码）。二值习惯的入口见 binaryFocusEntry。
                Button {
                    FocusGlassPresenter.shared.open(habitId: current.id)
                } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "timer").font(.system(size: Typography.tiny))
                            Text("专注").font(.system(size: Typography.caption, weight: .medium))
                        }
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.green.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("开始专注计时")
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .pastelCard()
    }

    /// v4.0.104：二值习惯的专注入口（计量习惯走进度卡里那个按钮）。
    /// 任何习惯都能开番茄钟；二值/量维度开始前，浮层里已明示「开始后会把该习惯设成时长习惯」。
    private var binaryFocusEntry: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.system(size: Typography.caption))
                .foregroundStyle(Color.green)
            Text("用番茄钟专注（开始后该习惯会设为时长习惯）")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                FocusGlassPresenter.shared.open(habitId: current.id)
            } label: {
                Text("专注")
                    .font(.system(size: Typography.caption, weight: .medium))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.green.opacity(Tint.subtle), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("开始专注计时")
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard()
    }

    private func stepButton(sign: Double, icon: String, label: String) -> some View {
        Button {
            if store.addAmount(HabitKit.metricStep(current) * sign, to: current, on: today) {
                Haptics.light()
                refreshCurrent()
            }
        } label: {
            Image(systemName: icon).font(.system(size: 20))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.green)
        .disabled(sign < 0 && store.progress(current, on: today) <= 0)
        .accessibilityLabel(label)
    }

    /// 计量设置区：显示当前维度与目标；可改目标 / 退回二值。二值习惯从这里的「设为可计量」升级。
    private var metricSettingsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("计量")
                    .font(.system(size: Typography.subhead, weight: .medium))
                Spacer(minLength: 0)
                Text(current.isMetric
                     ? "\(current.metric == .duration ? "时长" : "量") · 目标 \(HabitKit.numberText(current.target ?? 0))\(current.unitText)"
                     : "二值（只记打卡）")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            if metricEditing {
                metricEditor
            } else {
                HStack(spacing: 10) {
                    Button {
                        beginMetricEditing()
                    } label: {
                        Text(current.metric == nil ? "设为可计量" : "改目标")
                            .font(.system(size: Typography.caption, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                    if current.metric != nil {
                        Button {
                            store.clearMetric(current)
                            refreshCurrent()
                            Haptics.light()
                        } label: {
                            Text("退回二值")
                                .font(.system(size: Typography.caption))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color.secondary.opacity(Tint.subtle), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if current.metric != nil {
                    Text("换维度后，按另一种口径记过的历史不计入连续天数（数据不删，改回去就回来）。")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard()
    }

    private var metricEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("维度", selection: $metricDraftKind) {
                Text("量（杯/页/次…）").tag(HabitMetric.amount)
                Text("时长（分钟）").tag(HabitMetric.duration)
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                Text("目标")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                TextField("8", text: $metricDraftTarget)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 90)
                if metricDraftKind == .amount {
                    TextField("单位（如 杯）", text: $metricDraftUnit)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Text(metricDraftKind == .duration
                 ? "时长维度的单位固定「分钟」，可在详情页点「专注」用番茄钟自动累计。"
                 : "到「目标」才算当天达标（达标才计入连续天数）。")
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                Button {
                    saveMetric()
                } label: {
                    Text("保存")
                        .font(.system(size: Typography.caption, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(metricDraftValid ? Color.green : Color.gray, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
                .disabled(!metricDraftValid)
                Button {
                    metricEditing = false
                } label: {
                    Text("取消")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Color.secondary.opacity(Tint.subtle), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.top, 4)
    }

    private var metricDraftValid: Bool {
        (Double(metricDraftTarget.replacingOccurrences(of: ",", with: ".")) ?? 0) > 0
    }

    private func beginMetricEditing() {
        metricDraftKind = current.metric ?? .amount
        if let t = current.target, t > 0 {
            metricDraftTarget = HabitKit.numberText(t)
        } else {
            metricDraftTarget = current.metric == .duration ? "25" : "8"
        }
        metricDraftUnit = current.unit ?? ""
        metricEditing = true
    }

    private func saveMetric() {
        guard let v = Double(metricDraftTarget.replacingOccurrences(of: ",", with: ".")), v > 0 else { return }
        store.updateMetric(current, metric: metricDraftKind, target: v, unit: metricDraftUnit)
        refreshCurrent()
        metricEditing = false
        Haptics.success()
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
