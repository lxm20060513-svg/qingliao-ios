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
//   · 页面只放一张卡（.pastelCard() 16 圆角 + 同高 83pt）
//   · 1 个目标直达详情，≥2 个弹「全部目标」列表
//   · 空态 = 可点引导卡（同几何，空 ↔ 有内容不跳变）
//
// 🚨 铁律：
// · 三张弹窗（新建 / 全部目标 / 详情）v4.0.78 起是**页级毛玻璃浮层**（与备忘录 v4.0.77 同款），
//   不再挂在本 section 的 `.sheet` 上 —— 见文末 GoalsGlassPresenter / GoalsGlassLayerHost。
//   用户原话（2026-10-08）：「待办清单、记录、长期目标、习惯卡片「也改为跟备忘录一样的全屏弹出」」
// · 删除二次确认（LifeDeleteConfirm）必须与**它所在的浮层内容同宿主**：
//   浮层内容里那份自带（GoalsAllListBody / GoalsDetailSheet 各一份），
//   宿主页那份（页卡长按删除）保留在 GoalsSection.root —— 宿主级 alert 会被浮层压住看不见。
// · 浮层内容顶栏照备忘录口径：自绘 MiniCapsule（不用系统 toolbar）。
// · MiniCapsule 是跨文件单一来源（LifeCapsule.swift），别在本文件另抄一份 private 版。
//
// ⚠️ 本次只改**呈现层**（系统 sheet → 页级毛玻璃浮层）：字号 / 几何 / 文案一律不动，
//    三张弹窗的正文视图树逐字平移进下面的文件级 struct。

import SwiftUI
import Observation   // v4.0.78：浮层状态提到页级单例（@Observable）

struct GoalsSection: View {
    @State private var store = GoalStore.shared
    /// v4.0.78：三个浮层的开关**提到页级单例** —— 浮层本体不再挂在本 section 自己的树上。
    /// 原因（与备忘录 v4.0.77 同款坑）：本 section 只是生活页滚动区（LifeView 的 LazyVStack）
    /// 里的**一行**，浮层挂在这里 → 几何被这一行限制：轻纱只盖住卡片那一条、面板贴着卡片边缘长出、
    /// 列表一滚浮层跟着跑。全屏浮层必须挂在**页面根**、滚动区之外 → 见 GoalsGlassLayerHost。
    private var glass = GoalsGlassPresenter.shared
    /// v4.0.40（#4）：已完成目标折叠行是否展开
    @State private var showFinished = false

    var body: some View {
        root
            .modifier(GoalsSectionBodyChrome(host: self))
    }

    /// 页面主体：确认框挂在这——页卡长按删除时生效的就是这一份
    /// （宿主页那份保留；浮层内容里的删除确认各自自带，见下方三个文件级 struct）
    private var root: some View {
        deleteConfirm(on:
            VStack(alignment: .leading, spacing: 8) {
                pageHeader
                if store.goals.isEmpty {
                    emptyTap
                } else {
                    // v4.0.40（#4）：主卡只显示**未完成**的那个；已完成的收进下方折叠行
                    topCard
                    if !store.finishedGoals.isEmpty {
                        finishedFold
                    }
                }
            }
        )
    }

    /// v4.0.40（#4）：已完成折叠行 —— 默认只占一行，点开才展开看是哪几个
    private var finishedFold: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { showFinished.toggle() }
                Haptics.light()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                    Text(showFinished ? "已完成 \(store.finishedGoals.count) 个 · 收起" : "已完成 \(store.finishedGoals.count) 个")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: showFinished ? "chevron.up" : "chevron.down")
                        .font(.system(size: Typography.tiny, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())

            if showFinished {
                ForEach(store.finishedGoals) { g in
                    Button {
                        // v4.0.78：详情开启由页级单例驱动（副本回灌在 GoalsDetailSheet 内部）
                        glass.detail = g
                    } label: {
                        GoalRowCard(goal: g, compact: true)
                    }
                    .buttonStyle(PressStyle())
                    .contextMenu { goalMenuItems(g) }
                }
            }
        }
    }

    /// 删除确认框本体已收进 LifeDeleteConfirm（浮层/宿主各挂自己那份，同款）
    private func deleteConfirm<V: View>(on view: V) -> some View {
        view.modifier(LifeDeleteConfirm(
            title: "删除这个目标？",
            pending: glass.pendingDelete,
            onCancel: { glass.pendingDelete = nil },
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
        // v4.0.40（#4）：已完成数也报出来 —— 用户要一眼看到「哪些已经被划掉了」
        let a = store.activeCount, f = store.finishedCount
        if a > 0 && f > 0 { return "\(a) 个进行中 · \(f) 个已完成" }
        if a > 0 { return "\(a) 个进行中" }
        return f > 0 ? "全部完成（\(f) 个）" : "还没有目标"
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

    /// 页级标题行与空态引导卡共用这一个入口。
    /// 正文由 GoalsAddBody 自己的 @State 持有，靠 addSession 换实例保证每次空白
    ///（沿用备忘/待办「startAdd 自增会话序号」的惯例）。
    private func startAdd() {
        // v4.0.78：开新建前先把其它浮层收干净（三层浮层互斥）
        glass.showAll = false
        glass.detail = nil
        glass.addSession += 1
        glass.showAdd = true
    }

    // MARK: 页面单卡（显示最上的一个**未完成**目标 = 未完成优先、最新在前）

    /// v4.0.40（#4）：主卡数据源 = 未完成目标。全完成时退回用最新的那个（否则空卡）
    private var mainList: [GoalItem] {
        store.activeGoals.isEmpty ? Array(store.sorted.prefix(1)) : store.activeGoals
    }

    @ViewBuilder
    private var topCard: some View {
        if let top = mainList.first {
            // 🚨 用 onTapGesture 而不是 Button 包裹（**这一条保持不动**）：当年是因为卡内自带
            //    「现在开始推进」胶囊，Button 套 Button 时内层点击不可靠。胶囊已在 v4.0.47
            //    搬进详情弹窗，但这条链路不回退、不改动 —— 少一处回归面（真值表也钉着它）。
            GoalRowCard(goal: top, compact: true)
            .contentShape(Rectangle())
            .onTapGesture { openCard() }
            .contextMenu { goalMenuItems(top) }
            // v4.0.78：原 `matchedTransitionSource(id: "goal-all", in: goalZoomNS)` 已删 —— 它服务的是
            //   卡片 → 「全部目标」**系统 sheet** 的原生 zoom 转场；改毛玻璃浮层后两处不再是独立呈现
            //   （浮层是同 ZStack 层序），zoom 的源/目标配对不再成立（且备忘录 v4.0.77 同款改造也一并移除）。
            //   同步删掉的还有 allSheet 上的 `.navigationTransition(.zoom(...))` 与 `goalZoomNS` 命名空间。
            .accessibilityLabel(store.goals.count == 1
                                ? "长期目标，1 个，点开查看"
                                : "长期目标，共 \(store.goals.count) 个，点开查看全部")
        }
    }

    private func openCard() {
        if store.goals.count == 1, let only = store.sorted.first {
            glass.showAdd = false
            glass.detail = only
        } else {
            glass.detail = nil
            glass.showAll = true
        }
    }

    // MARK: 卡片行

    /// v4.0.78：菜单项内容提到**文件级**（goalCardMenuItems）—— 页级浮层里的「全部目标」也要用
    /// 同一套，这里只做转发（宿主页那份 → 写 presenter.pendingDelete）。
    /// ⚠️ 名字与文件级那个不同（与备忘 Section 的 memoMenuItems 同一防递归口径）。
    @ViewBuilder
    private func goalMenuItems(_ g: GoalItem) -> some View {
        goalCardMenuItems(g) { glass.pendingDelete = $0 }
    }
}

// MARK: - v4.0.78 长期目标浮层的「页级宿主」
//
// 🚨 为什么单开一个宿主（用户 2026-10-08 原话：「待办清单、记录、长期目标、习惯卡片
//    「也改为跟备忘录一样的全屏弹出」」）：
//   v4.0.77 备忘录先例（已上线、真机验收通过）把三个毛玻璃浮层从 MemoSection 那一行搬到**页根** ——
//   因为 section 只是生活页滚动区（LifeView 的 LazyVStack）里的一行，浮层挂在行内 → 几何被这一行
//   限制：轻纱只罩住卡片那一条、面板从卡片边缘长出、随列表滚走。本栏目此前同款坑：三张弹窗
//   还是 `.sheet`（挂在本 section 的修饰器链里），本次一并上收成页级浮层。
//
// 做法（与 MemoGlassPresenter / MemoGlassLayerHost 同形态）：三个开关提到页级单例，GoalsSection 只改状态；
// 浮层本体由 GoalsGlassLayerHost 渲染，挂载点 = LifeView body 最外层（全屏层，由主会话统一挂）。
// 视图树内顺序仍是：全部目标 < 详情 < 新建（后开的盖在前面）。
//
// ⚠️ 只改呈现层：字号 / 几何 / 文案一律不动（原 sheet 内容逐字平移进下面三个文件级 struct）。

@MainActor
@Observable
final class GoalsGlassPresenter {
    static let shared = GoalsGlassPresenter()

    /// 「全部目标」列表浮层
    var showAll = false
    /// 「新建目标」浮层
    var showAdd = false
    /// 详情浮层（nil = 不显示）
    var detail: GoalItem?
    /// 宿主页删除二次确认（页卡 / 已完成折叠行长按删除走这条；与浮层内容里那两份各自独立）
    var pendingDelete: GoalItem?
    /// 新建浮层的会话序号：每次打开自增，配合 `.id()` 强制换新实例（保证每次都是空白表单）
    var addSession = 0

    private init() {}

    /// 🚨 宿主销毁时清状态 —— 单例不会随视图树消失，页面被系统回收后重建，
    /// 开关还是 true → 回到生活页会「莫名又弹着上次那个浮层」。挂在 GoalsGlassLayerHost 的 .onDisappear。
    func reset() {
        showAll = false
        showAdd = false
        detail = nil
        pendingDelete = nil
        addSession = 0
    }
}

/// 长期目标浮层的页级宿主（挂 LifeView 根 → 全屏；轻纱盖住整页含页头）
struct GoalsGlassLayerHost: View {
    private var glass = GoalsGlassPresenter.shared
    private var store = GoalStore.shared

    var body: some View {
        ZStack {
            if glass.showAll {
                MemoGlassOverlay(isPresented: Binding(
                    get: { glass.showAll },
                    set: { if !$0 { glass.showAll = false } }
                )) {
                    GoalsAllListBody(
                        store: store,
                        onDone: { glass.showAll = false },
                        onOpenDetail: { openDetailFromAll($0) }
                    )
                }
            }
            if let g = glass.detail {
                MemoGlassOverlay(isPresented: Binding(
                    get: { glass.detail != nil },
                    set: { if !$0 { glass.detail = nil } }
                )) {
                    detailSheet(g)
                }
            }
            if glass.showAdd {
                MemoGlassOverlay(isPresented: Binding(
                    get: { glass.showAdd },
                    set: { if !$0 { glass.showAdd = false } }
                )) {
                    GoalsAddBody(
                        store: store,
                        onCancel: { glass.showAdd = false },
                        onSaved: { glass.showAdd = false }
                    )
                    // 每次打开换新实例（.id）→ 打开即空白
                    .id(glass.addSession)
                }
            }
        }
        // 🚨 宿主销毁即清状态 —— 页面重建后不会「莫名又弹上次那个浮层」
        //（单例状态不随视图树消失；见 GoalsGlassPresenter.reset）
        .onDisappear { GoalsGlassPresenter.shared.reset() }
    }

    /// ⚠️ 保留 `detailSheet` 这个名字（不改叫别的）：ql_goal_pushnow 真值表按
    /// `private func detailSheet` → `func stepTimeText` 切片来做「推进胶囊搬进详情」的分片断言，
    /// 改名会让切片为空 → 该表红（本表显式设计成「锚点改名就必须同步」）。浮层内容本体是下方 GoalsDetailSheet。
    private func detailSheet(_ g: GoalItem) -> some View {
        GoalsDetailSheet(item: g, onDismiss: { glass.detail = nil })
    }

    /// 从列表点一条 → **同帧**换成详情浮层（v4.0.78：浮层硬切、无退场动画，原 500ms 缓冲只剩延迟，已删；
    /// 旧注释「同帧切换会丢弹窗」是**系统 sheet 时代**的约束，浮层同 ZStack 层序不存在该问题）。
    private func openDetailFromAll(_ g: GoalItem) {
        // v4.0.78：同帧换状态（原 500ms 错峰为等系统 sheet 退场动画；浮层硬切无退场 →
        // 延迟 + in-flight Task 窗口一起删，理由同 TodoSection.openDetailFromAll）
        glass.showAll = false
        glass.showAdd = false
        glass.detail = g
    }
}

// MARK: - v4.0.78 长按菜单项（宿主页卡 / 全部目标列表两处共用）

/// ⚠️ 名字必须与 `GoalsSection.goalMenuItems` 区分（那个只是转发到本函数），否则会自己调自己。
/// 🚨 **文件级函数默认非 MainActor 隔离**（只有 View 的成员才是）→ 本体里调 `Haptics` / `GoalStore`
/// 这类 MainActor API 必须显式 `@MainActor`；否则只有 CI Archive 会报 `call to main actor-isolated
/// static method 'success()' in a synchronous nonisolated context`（本机 `-parse` 查不出；仓内先例
/// 见 MemoSection.swift 的 memoCardMenuItems）。
@MainActor
@ViewBuilder
private func goalCardMenuItems(_ g: GoalItem,
                               onDelete: @escaping (GoalItem) -> Void) -> some View {
    Button {
        let now = !g.paused
        GoalStore.shared.mutate(g.id) { $0.paused = now }
        Task { await GoalStore.shared.setPausedOnBackend(goalID: g.id, paused: now) }
        Haptics.success()
    } label: {
        Label(g.paused ? "恢复每日推进" : "暂停每日推进", systemImage: g.paused ? "play.circle" : "pause.circle")
    }
    Button(role: .destructive) {
        onDelete(g)
    } label: {
        Label("删除", systemImage: "trash")
    }
}

// MARK: - v4.0.78 「全部目标」浮层内容（原 allSheet 的 NavigationStack 内主体，逐字平移）
//
// 回调全部由宿主注入（浮层收起、开详情）：浮层是同 ZStack 层序，不再有 sheet present 竞争；
// 清空确认 / 删除确认仍挂本主体内部（浮层盖在生活页上，宿主层 alert 会被浮层压住看不见 —— 与原 sheet 时代同理由）。

struct GoalsAllListBody: View {
    let store: GoalStore
    let onDone: () -> Void
    let onOpenDetail: (GoalItem) -> Void

    /// 列表内长按删除的二次确认（挂浮层内容自己这棵树上）
    @State private var pendingDeleteInList: GoalItem?
    /// 「清空」二次确认（同上）
    @State private var confirmClearAll = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏照备忘录浮层口径：自绘 MiniCapsule（不用系统 toolbar）；
            // 按钮文案按「只改呈现层」一律不动（保留原「清空」/「完成」，不改成 取消/保存）。
            HStack {
                if !store.goals.isEmpty {
                    MiniCapsule(title: "清空") { confirmClearAll = true }
                }
                Spacer()
                MiniCapsule(title: "完成", accent: true) { onDone() }
            }
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.xs)

            List {
                // v4.0.40（#4）：未完成优先，已完成沉底（用户要「已完成自己划掉」）
                ForEach(store.sortedActiveFirst) { g in
                    // 🚨 同上：不 Button 包 Button（卡内胶囊 v4.0.47 已撤进详情弹窗，链路保持不动）
                    GoalRowCard(goal: g, compact: false)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // 🚨 先收列表、等它收起再开详情：交由宿主 openDetailFromAll 做 500ms 错峰
                        onOpenDetail(g)
                    }
                    .contextMenu { goalCardMenuItems(g) { pendingDeleteInList = $0 } }
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.section, bottom: 8, trailing: Spacing.section))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // 🚨 清空二次确认必须挂 List 上（宿主级 alert 被浮层盖住）
            .alert("清空全部目标？", isPresented: $confirmClearAll) {
                Button("清空", role: .destructive) {
                    // 🚨 清空前先把 id 收齐：removeAll 之后本地已空，
                    //    再想通知后端删 job 就拿不到 id 了（会留下每天还在推的孤儿 job）。
                    let ids = store.goals.map { $0.id }
                    _ = store.removeAll()
                    onDone()
                    Task { for id in ids { await store.deleteOnBackend(goalID: id) } }
                    Haptics.success()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("已删除的目标不会恢复，AI 也不会再每天推送它。")
            }
        }
        // 浮层内容自带的删除二次确认（与浮层同宿主 —— 宿主级 alert 会被浮层压住）
        .modifier(LifeDeleteConfirm(
            title: "删除这个目标？",
            pending: pendingDeleteInList,
            onCancel: { pendingDeleteInList = nil },
            onDelete: { g in
                store.remove(g.id)
                // 🚨 同步删后端目标 —— 后端会连带删掉它的 cron job，
                //    否则明天早上还会推一个用户已经删掉的目标。
                Task { await store.deleteOnBackend(goalID: g.id) }
            },
            message: { $0.title.prefix(40).description }
        ))
    }
}

// MARK: - v4.0.78 「新建目标」浮层内容（原 addSheet 的 NavigationStack 内主体，逐字平移）
//（AI 建的走聊天里的「建目标卡」，这里只负责手动建）

struct GoalsAddBody: View {
    let store: GoalStore
    let onCancel: () -> Void
    /// 保存成功（本地已落库）→ 收起浮层
    let onSaved: () -> Void

    @State private var draft = ""
    @State private var addMorning = true
    @State private var addEvening = true
    @State private var addMorningHour = 9
    @State private var addEveningHour = 21

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏照备忘录浮层口径：自绘 MiniCapsule（不用系统 toolbar）；
            // 按钮文案按「只改呈现层」一律不动（保留原「取消」/「创建」）。
            HStack {
                MiniCapsule(title: "取消") { onCancel() }
                Spacer()
                MiniCapsule(title: "创建", accent: true) { confirmAdd() }
            }
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.xs)

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
        }
    }

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
        GoalTodoBridge.pushStepsToTodo(g)
        Haptics.success()
        onSaved()
        Task { @MainActor in
            guard let remote = await store.createOnBackend(g) else {
                store.mutate(g.id) { $0.lastReport = "⚠️ 每日推送没建上（后端没响应），可以稍后在详情里重建。" }
                return
            }
            store.update(remote)
        }
    }
}

// MARK: - v4.0.78 「详情」浮层内容（原 detailSheet 的 NavigationStack 内主体，逐字平移）
//
// 副本回灌：传值进来的 item 只当「呈现目标」，实际渲染用本地副本 current；
// 勾步骤 / 暂停推进写库后立刻 refreshDetail() 回灌本页（否则界面没反应）——
// 等价于原 GoalsSection 的 detailCurrent + refreshDetail 机制，只是搬进本 struct。

struct GoalsDetailSheet: View {
    let item: GoalItem
    let onDismiss: () -> Void

    private var store = GoalStore.shared

    /// SR34 同款坑：详情只驱动呈现，实际渲染用副本，写库后回灌
    @State private var current: GoalItem
    /// v4.0.40（#1）：正在「手动推进中」（按钮转圈 + 禁用，防连点）
    @State private var pushingIDs: Set<String> = []
    /// 详情页删除二次确认（浮层内容自带的 LifeDeleteConfirm / alert，与浮层同宿主）
    @State private var pendingDelete: GoalItem?

    init(item: GoalItem, onDismiss: @escaping () -> Void) {
        self.item = item
        self.onDismiss = onDismiss
        _current = State(initialValue: item)
    }

    var body: some View {
        let g = current
        return VStack(spacing: 0) {
            // 顶栏照备忘录浮层口径：自绘 MiniCapsule（不用系统 toolbar）；
            // 按钮文案按「只改呈现层」一律不动（保留原「删除」/「完成」）。
            HStack {
                MiniCapsule(title: "删除") { pendingDelete = current }
                Spacer()
                MiniCapsule(title: "完成", accent: true) { onDismiss() }
            }
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.xs)

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
                            Text("已完成").pill(.page, tone: .accent)
                        } else {
                            // v4.0.20（#5）：详情页同口径 —— 不再只报「每天 9:00/21:00」，
                            // 而是说清后台到底在不在跑。
                            // v4.0.47（用户 2026-10-04）：「现在开始推进」从**卡片底部**搬进这里，
                            // 紧挨「后台运行中」；状态胶囊同时降档 `.pill(.page)`（与卡片一侧同口径）。
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(g.scheduleHealth == .running ? Color.green
                                          : (g.scheduleHealth == .paused ? Color.secondary : Color.orange))
                                    .frame(width: 6, height: 6)
                                Text(GoalSchedule.healthLabel(g.scheduleHealth)).pill(.page)
                                if pushingIDs.contains(g.id) {
                                    // 推进中：转圈 + 文案占位（不再点，防连点跑两遍）
                                    ProgressView().controlSize(.mini)
                                    Text("推进中…")
                                        .font(.system(size: Typography.tiny))
                                        .foregroundStyle(.secondary)
                                } else {
                                    MiniCapsule(title: "现在开始推进", accent: true, size: .page) { pushNow(g) }
                                }
                            }
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
                        Text("最近更新 \(GoalRowCard.stamp(at))")
                    } else {
                        Text("还没有推送记录")
                    }
                }

                if !g.steps.isEmpty {
                    Section("步骤") {
                        // v4.0.44（用户第⑥条）：显式序号 —— 原话「步骤清单带完成顺序」。
                        // enumerated 后 id 仍取 element.id：步骤身份不变，勾选/动画不错位。
                        ForEach(Array(g.steps.enumerated()), id: \.element.id) { idx, s in
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
                                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                                            // v4.0.44（用户第⑥条）：显式「第N步」，一眼看出完成顺序
                                            Text("第\(idx + 1)步")
                                                .font(.system(size: Typography.tiny, weight: .semibold))
                                                .foregroundStyle(.tertiary)
                                                .monospacedDigit()
                                            Text(s.title)
                                                .font(.system(size: Typography.body))
                                                .foregroundStyle(s.done ? .secondary : .primary)
                                                .strikethrough(s.done)
                                        }
                                        // v4.0.40（#5）：每个步骤的开始 / 完成时间。
                                        // nil = 老数据还没打上时间戳 → 整行不渲染，不显示「未开始」噪声。
                                        if let t = stepTimeText(s) {
                                            Text(t)
                                                .font(.system(size: Typography.tiny))
                                                .foregroundStyle(.tertiary)
                                        }
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
                                    Text(GoalRowCard.stamp(r.at))
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
        }
        // 浮层内容自带的删除二次确认（与原 sheet 时代同理由：宿主级 alert 会被浮层压住）
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
                onDismiss()
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.title.prefix(40).description ?? "")
        }
    }

    // MARK: v4.0.78 详情内动作（原 GoalsSection 的方法，随详情内容一起搬进来）

    /// v4.0.40（#1）现在开始推进：点胶囊 → 后端后台跑一次推进 → 回写卡片 + 推送。
    /// 这里只负责发请求 + 转圈态；真正内容由后端产出（任务中心可见进度）。
    private func pushNow(_ g: GoalItem) {
        guard !pushingIDs.contains(g.id) else { return }
        pushingIDs.insert(g.id)
        Haptics.light()
        Task { @MainActor in
            let ok = await store.pushNowOnBackend(goalID: g.id)
            pushingIDs.remove(g.id)
            guard !ok else {
                Haptics.success()
                // 卡片立刻回读一次：手动推进的时刻 / 步骤开始时间已由后端写入
                await store.loadFromServer()
                refreshDetail()
                return
            }
            Haptics.error()
            store.mutate(g.id) { $0.lastReport = "⚠️ 手动推进没发出去（连不上后端），稍后再试一次。" }
        }
    }

    /// SR34：写库后回灌详情副本（否则勾了步骤界面没反应）
    private func refreshDetail() {
        if let fresh = store.goals.first(where: { $0.id == current.id }) {
            current = fresh
        }
    }

    /// 勾上步骤 → 同步在待办里对应的条目划掉；取消勾 → 待办恢复
    private func syncTodo(step: GoalStep, goal: GoalItem) {
        GoalTodoBridge.syncStepDone(step: step, goal: goal)
    }

    /// v4.0.40（#5）：步骤时间文案。「已开始 X」/「已完成 X」/「X 开始 · Y 完成」。
    /// 返回 nil = 一个时间都没有（老数据还没打戳）→ 调用方整行不渲染。
    private func stepTimeText(_ s: GoalStep) -> String? {
        let started = s.startedAt.map { "已开始 " + GoalRowCard.stamp($0) }
        let done = s.doneAt.map { "已完成 " + GoalRowCard.stamp($0) }
        switch (started, done) {
        case let (a?, b?): return "\(a) · \(b)"
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
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

// MARK: - P3-13：目标 → 停滞判定的输入（唯一映射点）
//
// 判定逻辑在 `WorkbenchInsight`（纯逻辑、可 Linux 编跑），它只收**值**；
// `GoalItem` 是带 SwiftUI 的文件里的类型，所以「字段 → 输入」这层翻译**只在这里写一次**
// —— 卡片、结论条都调这一处，别处再抄一份字段名，改口径时必漏。
extension GoalItem {
    var insightProgress: WorkbenchInsight.GoalProgress {
        WorkbenchInsight.GoalProgress(
            createdAt: createdAt,
            // 完成判定必须与全 App 同一口径（`GoalStore.isFinished` = 步骤全勾）：
            // 后端 `finishedAt` 只是辅助展示、不参与判定 —— 用它会让结论条报「停滞」而目标卡
            // 上没有任何徽标，两处自相矛盾（谎报）。
            finished: isFinished,
            paused: paused,
            manualPushAt: manualPushAt,
            stepStartedAt: steps.compactMap(\.startedAt),
            stepDoneAt: steps.compactMap(\.doneAt))
    }
}

// MARK: - 目标行卡片

struct GoalRowCard: View {
    let goal: GoalItem
    var compact: Bool = false
    // ⚠️ v4.0.78：推进胶囊的调用点随「详情」浮层内容一起搬进 GoalsDetailSheet
    //（`GoalsDetailSheet.pushNow`），卡片侧依旧不挂任何动作入口。

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
                    Text("已完成").pill(.page)
                } else {
                    // v4.0.20（#5）：后台健康点 —— 一眼看出「它到底在不在跑」
                    //（绿=已接上 cron 在跑 / 灰=用户暂停 / 橙=没建上 cron 的半成品）
                    Circle()
                        .fill(healthColor(goal.scheduleHealth))
                        .frame(width: 6, height: 6)
                    // v4.0.47（用户 2026-10-04）：状态胶囊降档到 `.pill(.page)`（10pt，与生活页栏目头
                    // 「添加」同一档小胶囊）。原 `.topBar` 是 13pt 玻璃底，摆在卡片标题行、又紧挨下面
                    // 10pt 的步骤状态标，又大又重、两枚口径也不一致。同位置的「已完成」一起降档。
                    Text(GoalSchedule.healthLabel(goal.scheduleHealth)).pill(.page)
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

            // v4.0.79（P3-13 深度）：停滞告警 —— 「在跑」不等于「在推进」：cron 天天汇报、
            // 目标却 N 天没真动过时，这里出一行橙字。阈值/文案在 `WorkbenchInsight`（工作模式专属；
            // 生活模式下它直接回 nil → 本行整体不存在，生活页一字不动）。
            if !compact, !goal.isFinished,
               let stall = WorkbenchInsight.stallBadge(goal.insightProgress, now: Date()) {
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(Color.orange)
                    Text(stall)
                        .font(.system(size: Typography.caption, weight: .medium))
                        .foregroundStyle(Color.orange)
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

            // v4.0.45 → v4.0.46（用户 2026-10-04）：首页/列表卡**只显示当前进行中的那一步**，
            // 已完成的步骤不在卡片上列 —— 列出来会把卡片撑大（8/9 完成时尤甚，用户明确要求）。
            // 「完成了多少」由上面的进度条 + `doneCount/total` 表达，不再重复成文字行；
            // 全量步骤清单（含已完成、带序号）在详情页，卡片这边保持矮。
            if compact, !goal.isFinished, let s = goal.nextStep {
                HStack(spacing: 5) {
                    Image(systemName: "circle")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.secondary)
                    // 序号 = 已完成数 + 1（与详情页「第N步」同口径）
                    Text("第\(goal.doneCount + 1)步 \(s.title)")
                        .font(.system(size: Typography.caption, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    nextStepStatusMark(goal, s)
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
                    // v4.0.44（用户第⑤条）：下一步到底「在进行中」还是「还没到点」——
                    // 已开始 → 进行中；未开始 → 预计 <后台下次推进时刻> 开始
                    nextStepStatusMark(goal, s)
                }
            }

            // v4.0.40（#5）：开始时间 —— 用户原话「明确备注好每一个任务的开始时间」
            HStack(spacing: 4) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                Text("开始于 \(GoalRowCard.stamp(goal.startedAt))")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let at = goal.manualPushAt {
                    Text("· 手动推进 \(GoalRowCard.stamp(at))")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            // v4.0.40（#1）→ v4.0.47（用户 2026-10-04）：「现在开始推进」胶囊已从卡片
            // **搬进详情弹窗顶栏**（紧挨「后台运行中」，见 GoalsDetailSheet）。
            // 卡片只留状态、动作收进弹窗 —— 两处都挂等于重复入口（用户口径是「搬」不是「复制」）。
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity,
               minHeight: compact ? MemoCardMetrics.minHeight : nil,
               alignment: .leading)
        .pastelCard()
    }

    // MARK: v4.0.46：卡片步骤区只显示「当前进行中的那一步」
    // （v4.0.45 这里列最近 3 条已完成 + 折叠计数 → 卡片被撑大，用户 2026-10-04 明确要求撤掉；
    //   已完成步骤在详情页的完整清单里看）

    /// v4.0.20（#5）：健康点配色
    private func healthColor(_ h: GoalSchedule.Health) -> Color {
        switch h {
        case .running:  return .green
        case .paused:   return .secondary
        case .detached: return .orange
        }
    }

    /// 时间戳文案（与 GoalsDetailSheet.stepTimeText 同一口径，跨 view 复用一份）
    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }

    /// v4.0.44（用户第⑤条）：下一步状态标 —— 卡内小标签（tiny + h6/v1，走「文章内小标签」口径）。
    /// 不套 PillSize 那三档**操作胶囊**：那是按钮口径，塞进行内会变大变笨（见 Pill.swift 头注）。
    /// 已开始 → 「进行中」；未开始 → 「预计 <后台下次推进时刻> 开始」；
    /// 编不出时刻（后台没接上/两段都关）→ 只说「待开始」，不编时间。
    /// 🚨 必须留在 GoalRowCard 内：它是本 struct 的实例方法，唯一调用点在下面 nextStep 行。
    ///    放进平级的 GoalsSection 会变成跨类型裸调用 —— 本机 `swiftc -parse` 全绿、CI Archive 必炸
    ///    （同类事故：v4.0.43 的 GoalsSection.stamp 跨类型调用）。真值表钉了「同 struct」这条。
    @ViewBuilder
    func nextStepStatusMark(_ goal: GoalItem, _ s: GoalStep) -> some View {
        let started = s.startedAt != nil
        let text: String = started
            ? "进行中"
            : (goal.nextRunMoment(now: Date()).map { "预计 \($0) 开始" } ?? "待开始")
        Text(text)
            .font(.system(size: Typography.tiny))
            .foregroundStyle(started ? Color.accentColor : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(
                (started ? Color.accentColor : Color.secondary).opacity(0.28), lineWidth: 0.8))
    }
}

// MARK: - v4.0.50 启动链类型折叠（防启动期 demangler 递归爆主线程 1MB 栈）
//
// 事故与 ChatView（v4.0.49）/ DashboardView（v4.0.50）同源：本文件 body 返回类型名里
// **内联**了每条 .sheet 内容闭包的完整类型（各 sheet 的正文视图树），dSYM 实测 body 的
// mangled 类型名 1196 字符。危险量是**名字的字符数**（≈19 字符 = 1 帧 demangler 递归，
// 每帧 ~9.3KB 主线程栈），TabView 启动即渲染本页，与其它视图叠加可吃干 1MB 栈 → 一点开就闪退。
//
// 修法 = 把 body 的修饰器链折成具名 ViewModifier 分组：父类型名里只剩组名，链在各组自己的
// applyXxx 调用里解析（各自一次 1MB 栈预算）。⚠️ 修饰器**种类/数量/顺序/参数**逐字未变
// （等价重构，视图树与身份/动画真源不动）；谁也不许把这些链再内联回 body ——
// 改链请改这里的 applyXxx，别动调用点。
//
// v4.0.78：原「折叠组 2（三张弹窗 .sheet）」整组删除 —— 三条 .sheet 已随浮层上收搬进
// GoalsGlassLayerHost（其内容都是**具名 struct**，类型名短、不进本 section body）。
// 本 section body 现在只剩折叠组 1（页壳）。
extension GoalsSection {
    /// 折叠组 1（2 条修饰器）：页壳（宽度对齐 + 进页面拉一次数据）
    @MainActor
    private func applyGoalsSectionBodyChrome<C: View>(to content: C) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { await store.loadFromServer() }
    }

    @MainActor
    private struct GoalsSectionBodyChrome: ViewModifier {
        let host: GoalsSection

        func body(content: Content) -> some View { host.applyGoalsSectionBodyChrome(to: content) }
    }
}
