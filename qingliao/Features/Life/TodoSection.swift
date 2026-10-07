// MARK: - v3.9.35 生活页「待办清单」栏目
// 风格与「备忘录」栏目完全同源：
//   · 页级标题行（粗体 15pt + 计数 + 右侧「添加」淡色胶囊）在卡片外
//   · 页面只放一张卡（`.pastelCard()` 16 圆角 + 同高 83pt + 铺满），显示最上的一条
//   · 点卡片：1 条直达详情，≥2 条弹「全部待办」列表
//   · 空态 = 可点引导卡（与备忘录空态同几何，空 ↔ 有内容不跳变）
// 功能：聊天长按「加入待办」/ AI 回复勾选框自动收录 / 手动添加 / 勾选完成 / 编辑 / 删除（左滑+长按）
//
// v4.0.78（用户 2026-10-08 原话「把待办清单、记录、长期目标、习惯卡片也改为跟备忘录一样的全屏弹出」）：
//   三张系统 `.sheet`（新建 / 全部待办 / 详情）整体改成「毛玻璃浮层」，与 4.0.77 已上线、用户真机
//   验收通过的**备忘录**同款（备忘录先例见 MemoSection.swift 底部 MemoGlassPresenter / MemoGlassLayerHost）。
//   为什么必须上收：本 section 只是生活页 LazyVStack 里的**一行**，浮层挂在这里 → 轻纱只罩住那条卡、
//   面板从卡片边缘长出、随列表滚走（4.0.76 备忘录就是这么翻的车）。开关提到页级单例
//   TodoGlassPresenter，浮层本体由 TodoGlassLayerHost 渲染、挂在 LifeView 根（真正的全屏层）。
//   ⚠️ 只改**呈现层**：字号 / 几何 / 文案 / 排序一律逐字不动。

import SwiftUI
import Observation   // v4.0.78：浮层状态提到页级单例（@Observable），与 MemoSection 同口径

struct TodoSection: View {
    @State private var store = TodoStore.shared
    /// v4.0.78：三个浮层的开关（全部列表 / 详情 / 新建）**提到页级单例**——
    /// 浮层本体不再挂在本 section 自己的视图树上（本 section 只是生活页滚动区的一行，
    /// 浮层会被限制在卡片那一行的几何里）。详见文件底部 TodoGlassPresenter / TodoGlassLayerHost。
    private var glass = TodoGlassPresenter.shared
    // v4.0.78：@Namespace todoZoomNS 随 .sheet / .navigationTransition(.zoom) 一并删除
    //（zoom 依赖 sheet / fullScreenCover 容器，浮层没有那个容器可挂；备忘录改浮层时同样移除）。
    // v4.0.78：原 addSession / detail / detailCurrent / pendingDelete / confirmClearAll /
    //     confirmClearCompleted / editDraft / detailEditing / showAdd / showAll 这些 @State
    //   —— 开关与待删项搬进 TodoGlassPresenter，弹窗内部态搬进各自的文件级内容 struct。

    var body: some View {
        root
            .modifier(TodoSectionBodyChrome(host: self))
    }

    /// 页面主体：确认框挂在这——页卡（无弹窗在前）长按删除时生效的就是这一份
    private var root: some View {
        deleteConfirm(on:
            VStack(alignment: .leading, spacing: 8) {
                pageHeader
                if store.todos.isEmpty {
                    emptyTap
                } else {
                    topCard
                }
            }
        )
    }

    /// v3.9.41（SR35）：删除确认框本体，宿主与「全部待办」浮层各挂一次。
    /// 原先只有宿主那一份（旧 :40），而弹窗盖在宿主之上时宿主级 alert 呈现不出来 →
    /// 列表里长按「删除」= 点了没反应。备忘录的 MemoSection 早已把确认框搬进弹窗内，待办漏抄。
    /// 确认框本体已收进 LifeDeleteConfirm（工作线 B：目标/记录/备忘弹窗内那份同款）。
    ///
    /// v4.0.78：页卡（宿主）这一份**保留**，待删项改读页级单例 glass.pendingDelete；
    /// 浮层内容（列表/详情）里那份由 TodoAllListBody 自带（见 LifeDeleteConfirm 顶部注释：
    /// 「必须挂在自己那棵视图树上」——浮层那份不能借宿主，否则浮层盖住时点了没反应）。
    private func deleteConfirm<V: View>(on view: V) -> some View {
        view.modifier(LifeDeleteConfirm(
            title: "删除这条待办？",
            pending: glass.pendingDelete,
            onCancel: { glass.pendingDelete = nil },
            onDelete: { store.delete($0) },
            message: { $0.content.prefix(40).description }
        ))
    }

    // MARK: 页级标题行（与备忘录同款）

    /// 外壳已收进 LifeSectionHeader（工作线 B：备忘/目标/记录三份同款）
    private var pageHeader: some View {
        LifeSectionHeader(
            title: "待办清单",
            subtitle: store.todos.isEmpty ? nil : pendingSubtitle,
            subtitleLineLimit: nil,
            addAccessibilityLabel: "添加待办",
            onAdd: startAdd
        )
    }

    private var pendingSubtitle: String {
        let pending = store.pendingCount
        return pending > 0 ? "\(pending) 项待办" : "已完成"
    }

    /// 空态引导卡（与备忘录空态同几何：16 圆角 + 83pt 高）
    private var emptyTap: some View {
        LifeEmptyStateCard(
            icon: "checklist",
            title: "有什么要做的",
            subtitle: "聊天长按加入待办，AI 给出的清单会自动收进来",
            onTap: startAdd
        )
    }

    /// 页级标题行与空态引导卡共用这一个入口（正文改由 LifeNoteComposeSheet 自己的 @State 持有，
    /// 靠 addSession 换实例保证每次空白）
    private func startAdd() {
        // v4.0.78：开新建前先把其它浮层收干净（三层浮层互斥）——否则「列表开着时点 +」会两层同屏叠
        glass.showAll = false
        glass.detail = nil
        glass.addSession += 1
        glass.showAdd = true
    }

    // MARK: 页面单卡（显示列表最上的一条 = 未完成优先、最新在前）

    @ViewBuilder
    private var topCard: some View {
        if let top = store.sorted.first {
            Button {
                openCard()
            } label: {
                TodoRowCard(item: top, compact: true)
            }
            .buttonStyle(PressStyle())
            .contextMenu { todoCardMenuItems(top, onDelete: { glass.pendingDelete = $0 }) }
            // v4.0.78：原 v3.9.37 的 `.matchedTransitionSource(id: "todo-all", in: todoZoomNS)`（zoom 源）
            // 随三张 sheet 一并删除——zoom 转场依赖 sheet / fullScreenCover 容器，浮层没有该容器；
            // 备忘录 4.0.77 改浮层时同样移除了 zoom。
            .accessibilityLabel(store.sorted.count == 1
                                ? "待办清单，1 项，点开查看"
                                : "待办清单，共 \(store.sorted.count) 项，点开查看全部")
        }
    }

    /// 点卡片：只有 1 条时「全部待办」列表是多余的一跳 → 直接进详情；
    /// ≥2 条才开「全部待办」列表。原先是写 editDraft / detailEditing / detailCurrent / detail
    /// 四个 @State，现在只改页级单例的两个开关：详情 struct 自己从 item 派生副本与编辑态。
    private func openCard() {
        if store.sorted.count == 1, let only = store.sorted.first {
            glass.showAdd = false
            glass.detail = only
        } else {
            glass.detail = nil
            glass.showAll = true
        }
    }

    // MARK: 全部待办列表 / 详情 / 新增
    // v4.0.78：三张弹窗的内容（原 allSheet / detailSheet / addSheet）已提到**文件级 struct**——
    //   · TodoAllListBody（列表主体，自带列表内删除确认与两个清空确认）
    //   · TodoDetailSheet（详情/编辑，自带「写库后回灌本页副本」机制）
    //   · 新增直接复用 LifeNoteComposeSheet(formSheet: false)（与备忘录一致，不另抄一份）
    // 见文件底部 TodoGlassLayerHost。

    // MARK: 长按菜单（页卡 / 列表两处共用）
    // v4.0.78：菜单项内容提到**文件级**（todoCardMenuItems）——页卡与浮层内的列表行共用同一套。
}

// MARK: - v4.0.78 待办浮层的「页级宿主」
//
// 🚨 为什么单开一个宿主（用户 2026-10-08 原话：「把待办清单、记录、长期目标、习惯卡片也改为跟
//    备忘录一样的全屏弹出」）：
//   4.0.76 的备忘录浮层曾挂在 section 自己的 ZStack 里，而 section 只是生活页 LazyVStack 里的
//   **一行** → 轻纱只罩住那条卡、面板从卡片边缘长出、随列表滚走；4.0.77 把开关提到页级单例 +
//   内容搬到页根宿主才真正全屏（用户真机验收通过）。同款坑现在存在于本文件的三张弹窗。
//
// 做法（与 MemoGlassPresenter / MemoGlassLayerHost 逐条对齐）：
//   三个开关（showAll / detail / showAdd）提到页级单例 TodoGlassPresenter，TodoSection 只改状态；
//   浮层本体由本 struct 渲染，挂载点 = LifeView body 最外层的 `.overlay`（全屏层，由主会话统一挂）。
//   视图树内顺序仍是：全部列表 < 详情 < 新建（后开的盖在前面）。

@MainActor
@Observable
final class TodoGlassPresenter {
    static let shared = TodoGlassPresenter()

    /// 「全部待办」列表浮层
    var showAll = false
    /// 「新建待办」浮层
    var showAdd = false
    /// 详情浮层（nil = 不显示）
    var detail: TodoItem?
    /// 宿主（页卡）删除二次确认：页卡长按「删除」置这里 → 由 TodoSection 的 LifeDeleteConfirm 呈现。
    /// ⚠️ 浮层内列表的删除不走这里（浮层盖住时宿主 alert 看不见），由 TodoAllListBody 自带的一份管。
    var pendingDelete: TodoItem?
    /// 新建浮层的会话序号：每次打开自增，配合 `.id()` 强制换新实例（保证每次都是空编辑器）
    var addSession = 0

    private init() {}

    /// 宿主销毁时清状态 —— 单例不会随视图树消失，页面被系统回收后重建、开关还是 true →
    /// 回到生活页会「莫名又弹着上次那个浮层」。挂在 TodoGlassLayerHost 的 .onDisappear 上
    /// （宿主与生活页同生共死）。（与 MemoGlassPresenter.reset 同款护栏）
    func reset() {
        showAll = false
        showAdd = false
        detail = nil
        pendingDelete = nil
        addSession = 0
    }
}

/// 待办浮层的页级宿主（挂 LifeView 根 → 全屏；轻纱盖住整页含页头）
struct TodoGlassLayerHost: View {
    private var glass = TodoGlassPresenter.shared
    private var store = TodoStore.shared

    var body: some View {
        ZStack {
            if glass.showAll {
                MemoGlassOverlay(isPresented: Binding(
                    get: { glass.showAll },
                    set: { if !$0 { glass.showAll = false } }
                )) {
                    TodoAllListBody(
                        store: store,
                        onDone: { glass.showAll = false },
                        onOpenDetail: { openDetailFromAll($0) },
                        // 原 allSheet 的「清空」确认动作：删光 + 收起浮层 + 震动（口径逐字保留）
                        onConfirmClear: {
                            store.removeAll()
                            glass.showAll = false
                            Haptics.success()
                        },
                        // 原 allSheet 的「清理已完成」确认动作：只删已完成、不收起浮层
                        onConfirmClearCompleted: {
                            store.clearCompleted()
                            Haptics.success()
                        }
                    )
                }
            }
            if let t = glass.detail {
                MemoGlassOverlay(isPresented: Binding(
                    get: { glass.detail != nil },
                    set: { if !$0 { glass.detail = nil } }
                )) {
                    TodoDetailSheet(item: t, onDismiss: { glass.detail = nil })
                }
            }
            if glass.showAdd {
                MemoGlassOverlay(isPresented: Binding(
                    get: { glass.showAdd },
                    set: { if !$0 { glass.showAdd = false } }
                )) {
                    // 新建浮层内容（原 TodoSection.addSheet）：外壳已收进 LifeNoteComposeSheet，
                    // 这里只差占位符与标题；每次打开换新实例（.id）→ 打开即空白。
                    // v4.0.78：formSheet: false = 毛玻璃浮层形态（自绘顶栏「取消/保存」小胶囊），
                    // 与备忘录 MemoGlassLayerHost 里的用法逐字一致。
                    LifeNoteComposeSheet(
                        title: "新建待办",
                        placeholder: "要做什么…",
                        onSave: { text in
                            if store.add(content: text, source: "manual") {
                                Haptics.success()
                            }
                            glass.showAdd = false
                        },
                        onCancel: { glass.showAdd = false },
                        formSheet: false
                    )
                    .id(glass.addSession)
                }
            }
        }
        // 宿主销毁即清状态 —— 页面重建后不会「莫名又弹上次那个浮层」（见 TodoGlassPresenter.reset）
        .onDisappear { TodoGlassPresenter.shared.reset() }
    }

    /// 从「全部待办」列表点一条 → 先收列表、等收起动画播完再开详情。
    /// v4.0.78：原 allSheet 内那套 `showAll = false` + 500ms 缓冲 + `guard !showAll` 逐字保留，
    /// 只是改成页级单例的开关。原来那句 `detailCurrent = store.todos.first { $0.id == t.id } ?? t`
    /// 的「取 store 里最新那条」语义，现在由这里直接喂给 glass.detail（详情 struct 以此建立副本）。
    private func openDetailFromAll(_ t: TodoItem) {
        // v4.0.78：列表 → 详情**同帧**换状态。原 500ms 错峰是为「等系统 sheet 退场动画播完」，
        // 浮层是外层 if 门控的硬切（没有退场动画），这半秒只剩「点了没反应」的延迟，还制造了
        // in-flight Task 窗口（期间切页 → reset 后 Task 到点又把 detail 置真 = 跨页残留；
        // 期间点「+」→ 与新建两层同屏叠）。删掉任务、直接换状态，把窗口和延迟一起消灭。
        glass.showAll = false
        glass.showAdd = false
        glass.detail = store.todos.first { $0.id == t.id } ?? t
    }
}

// MARK: - v4.0.78 长按菜单项（页卡 / 浮层内列表行两处共用）
//
// 🚨 **文件级函数默认非 MainActor 隔离**（只有 View 的成员才是）→ 本体里调 `Haptics` / `TodoStore`
// 这类 MainActor API 必须显式 `@MainActor`（仓内先例：MemoSection 的 memoCardMenuItems、
// ImageCache.swift 的全局函数）。内容与旧 TodoSection.todoMenuItems **逐字相同**，只把 store 收成单例。
@MainActor
@ViewBuilder
private func todoCardMenuItems(_ t: TodoItem, onDelete: @escaping (TodoItem) -> Void) -> some View {
    Button {
        TodoStore.shared.toggleDone(t)
        Haptics.success()
    } label: {
        Label(t.done ? "标为待办" : "完成", systemImage: t.done ? "circle" : "checkmark.circle.fill")
    }
    Button {
        UIPasteboard.general.string = t.content
        Haptics.success()
    } label: {
        Label("复制", systemImage: "doc.on.doc")
    }
    Button(role: .destructive) {
        onDelete(t)
    } label: {
        Label("删除", systemImage: "trash")
    }
}

// MARK: - v4.0.78 「全部待办」浮层内容（原 allSheet 的 NavigationStack 内主体，逐字平移）
//
// 外壳由 MemoGlassOverlay 替代（去 NavigationStack / presentationDetents / navigationTransition）。
// 回调由页级宿主注入：浮层是同 ZStack 层序，不再有 sheet present 竞争；删除确认 / 两个清空确认
// 仍挂本主体内部（浮层盖在生活页上，宿主层的 alert 会被浮层压住看不见——与原 sheet 时代同理由）。

struct TodoAllListBody: View {
    let store: TodoStore
    /// 顶栏「完成」胶囊 → 收起浮层（宿主置 glass.showAll = false）
    let onDone: () -> Void
    /// 点一条 → 宿主先收列表、错峰再开详情（原 500ms 缓冲语义在宿主里）
    let onOpenDetail: (TodoItem) -> Void
    /// 「清空」确认动作（宿主注入：removeAll + 收浮层 + Haptics）
    let onConfirmClear: () -> Void
    /// 「清理已完成」确认动作（宿主注入：clearCompleted + Haptics）
    let onConfirmClearCompleted: () -> Void

    /// v3.9.41（SR35）：列表内左滑/长按删除的二次确认（挂浮层内部，宿主那份被浮层盖住）
    @State private var pendingDeleteInList: TodoItem?
    /// v3.9.110：「清空」二次确认（挂在浮层内 List 上——宿主级 alert 会被浮层盖住）
    @State private var confirmClearAll = false
    /// v4.0.25：「清理已完成」二次确认（同上）
    @State private var confirmClearCompleted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("全部待办")
                    .font(.system(size: Typography.title, weight: .semibold))
                Text("\(store.pendingCount) 项待办")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // v4.0.25：「清理已完成」胶囊（批量删已勾选，与「清空」并存；有已完成条目才出）
                if store.todos.contains(where: { $0.done }) {
                    MiniCapsule(title: "清理已完成") { confirmClearCompleted = true }
                }
                // v3.9.110：清空胶囊（与「完成」同排、左侧）——确认框挂在下面 List 上，
                // 不能挂宿主：宿主那个 alert 在浮层之上会被盖住（同 pendingDelete 的坑）
                if !store.sorted.isEmpty {
                    MiniCapsule(title: "清空") { confirmClearAll = true }
                }
                MiniCapsule(title: "完成", accent: true) { onDone() }
            }
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.md)
            List {
                ForEach(store.sorted) { t in
                    Button {
                        // 原 allSheet 的「点一条」：先收列表、错峰 500ms、以 store 最新那条为准再开详情
                        // ——整套时序挪到宿主 openDetailFromAll（此处只转发），语义等价。
                        onOpenDetail(t)
                    } label: {
                        TodoRowCard(item: t)
                    }
                    .buttonStyle(PressStyle())
                    .contextMenu { todoCardMenuItems(t, onDelete: { pendingDeleteInList = $0 }) }
                    // v3.9.38：行容器口径与「全部备忘」逐项一致（卡片几何 + 无分隔线 + 透明行底）
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.section,
                                              bottom: 8, trailing: Spacing.section))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onDelete { offsets in
                    // v3.9.41（SR35）：左滑原先零确认直接删 + 整档回写 NAS（长按那条路有确认，
                    // 左滑漏了）。单行走同一个确认框；一次多行（批量手势，极少见）逐条弹框
                    // 不现实，保持直接删。
                    guard offsets.count == 1, let idx = offsets.first else {
                        let targets = offsets.map { store.sorted[$0] }
                        for t in targets { store.delete(t) }
                        return
                    }
                    pendingDeleteInList = store.sorted[idx]
                }
                // v3.9.38：与「全部备忘」同款空态占位（列表打开期间被删空不剩空白面板）
                if store.sorted.isEmpty {
                    Text("还没有待办")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 20)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // v3.9.110：「清空」二次确认（挂在浮层内，同 pendingDeleteInList 的道理）
            .alert("清空全部待办？", isPresented: $confirmClearAll) {
                Button("清空 \(store.sorted.count) 条", role: .destructive) {
                    onConfirmClear()          // 宿主：removeAll + 收起浮层 + Haptics.success()
                }
                Button("取消", role: .cancel) { confirmClearAll = false }
            } message: {
                Text("将删除全部 \(store.sorted.count) 条待办（含已完成），删除后不可恢复。")
            }
            // v4.0.25：「清理已完成」二次确认（口径同「清空」，但保留未完成项、不收起浮层）
            .alert("清理已完成？", isPresented: $confirmClearCompleted) {
                Button("清理 \(store.todos.filter { $0.done }.count) 条", role: .destructive) {
                    onConfirmClearCompleted() // 宿主：clearCompleted + Haptics.success()
                }
                Button("取消", role: .cancel) { confirmClearCompleted = false }
            } message: {
                Text("将删除 \(store.todos.filter { $0.done }.count) 条已完成待办，未完成的不受影响。")
            }
        }
        // 浮层内容里那份自带（见 LifeDeleteConfirm 顶部注释：宿主那一份被浮层盖住）
        .modifier(LifeDeleteConfirm(
            title: "删除这条待办？",
            pending: pendingDeleteInList,
            onCancel: { pendingDeleteInList = nil },
            onDelete: { store.delete($0) },
            message: { $0.content.prefix(40).description }
        ))
    }
}

// MARK: - v4.0.78 详情 / 编辑浮层内容（点卡片 / 列表进入）
// v3.9.35b：详情用「待办」的 UI 风格（系统提醒事项式）——大勾选圆 + 完成态划线压灰 + 来源/时间
// 元信息行；编辑态才切 TextEditor。顶栏沿用备忘录详情的自绘小胶囊口径。
// v4.0.78：原 NavigationStack + sheet 外壳由 MemoGlassOverlay 替代；原 `detailCurrent` 那套
// 「写库后回灌副本、让本页立刻反映勾选/正文改动」机制在本 struct 内以 `current` + refreshDetail()
// 等价保留（item 是传值进来的快照，store 改了它不会跟着变 → 大勾选圆点了没反应，见下）。

struct TodoDetailSheet: View {
    let item: TodoItem
    /// v4.0.78：浮层收起（原 sheet 的 dismiss——浮层里没有系统 dismiss 环境，宿主注入）
    var onDismiss: () -> Void

    /// v3.9.41（SR34）：详情页**实际渲染**用的副本；`item` 只负责驱动呈现（一旦被浮层取用，
    /// 传进来的就是那一刻的快照，之后 store 改了它也不会跟着变 → 大勾选圆点了没反应）。
    /// 每次写库后由 `refreshDetail()` 回灌这一份。
    @State private var current: TodoItem
    /// v3.9.35b：详情页编辑态标志（查看=待办风格大卡；编辑=TextEditor）
    @State private var editing = false
    @State private var editDraft = ""

    init(item: TodoItem, onDismiss: @escaping () -> Void) {
        self.item = item
        self.onDismiss = onDismiss
        _current = State(initialValue: item)
    }

    private var store = TodoStore.shared

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
                            Text("待办内容…")
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
                        // 大勾选圆 + 内容：整卡可点切换完成态（待办的核心交互前置到详情）
                        Button {
                            store.toggleDone(current)
                            refreshDetail()   // SR34：勾选态必须立刻反映在本页
                            Haptics.success()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: current.done ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 26, weight: .medium))
                                    .foregroundStyle(current.done ? Color.green : Color.secondary.opacity(0.4))
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(current.content)
                                        .font(.system(size: Typography.headline))
                                        .lineSpacing(LineSpacing.long)
                                        .strikethrough(current.done, color: .secondary)
                                        .foregroundStyle(current.done ? Color.secondary : Color.primary)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    HStack(spacing: Spacing.xs) {
                                        Image(systemName: current.sourceIcon)
                                            .font(.system(size: Typography.tiny))
                                        Text(current.sourceLabel)
                                            .font(.system(size: Typography.tiny))
                                        Text("·")
                                        Text(current.timeText)
                                            .font(.system(size: Typography.tiny))
                                    }
                                    .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(Spacing.xl)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .pastelCard()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle())
                        // 完成态底部一句轻提示（未完成时占住同位置不显示）
                        if current.done {
                            Text("已完成 · 从列表长按或点这里可改回待办")
                                .font(.system(size: Typography.caption))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(18)
                }
            }
            // v4.0.78：原 `.interactiveDismissDisabled(detailEditing)` 随 sheet 一并移除——
            // 浮层没有系统下滑手势，编辑态草稿天然安全。
        }
    }

    // MARK: 顶栏（自绘小胶囊；「关闭」走宿主 onDismiss → detail = nil → 浮层收起）

    private var topBar: some View {
        HStack(spacing: 8) {
            MiniCapsule(title: "关闭") {
                editing = false
                onDismiss()
            }
            Spacer(minLength: 0)
            if editing {
                MiniCapsule(title: "保存", accent: true) {
                    store.update(current, content: editDraft)
                    refreshDetail()   // SR34：正文改了要让本页立刻显示
                    editing = false
                }
                .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                MiniCapsule(title: "编辑") {
                    editDraft = current.content
                    editing = true
                }
            }
        }
        .padding(.horizontal, Spacing.section)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.sm)
        .overlay {
            Text("待办")
                .font(.system(size: Typography.headline, weight: .semibold))
                .foregroundStyle(.primary)
                .allowsHitTesting(false)
        }
    }

    /// v3.9.41（SR34）：把 store 里最新的那条回灌给详情页副本（见 `current`）。
    /// 写库后调用 → 本页立刻反映勾选 / 正文改动。
    private func refreshDetail() {
        guard let idx = store.todos.firstIndex(where: { $0.id == current.id }) else { return }
        current = store.todos[idx]
    }
}

// MARK: - 待办行卡（页级单卡 / 列表行两处共用，参数化差异走 compact）

private struct TodoRowCard: View {
    let item: TodoItem
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // v4.0.65（用户 2026-10-06 拍板「待办走 B」）：列表行行首升级成 36pt 完成色块；
            // **页级单卡（compact）保持原来的 15pt 圈**——首页卡行首突然放大显得突兀。
            if compact {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(item.done ? Color.green : Color.secondary.opacity(0.5))
            } else {
                TodoStatusBadge(done: item.done)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.content)
                    .font(.system(size: Typography.body))
                    .strikethrough(item.done, color: .secondary)
                    .foregroundStyle(item.done ? Color.secondary : Color.primary)
                    .lineLimit(compact ? MemoCardMetrics.lineLimit : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !compact {
                    HStack(spacing: Spacing.xs) {
                        // v4.0.65（待办方案 B）：来源图标 + 来源名染来源色（聊天蓝 / AI 紫 / 智能球青 /
                        // 手记灰）；时间保持灰色基线不抢视觉。颜色真源 = SourceStyle（全站唯一出口）
                        Image(systemName: item.sourceIcon)
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(SourceStyle.tint(item.source))
                        Text(item.sourceLabel)
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(SourceStyle.tint(item.source))
                        Text("·")
                        Text(item.timeText)
                            .font(.system(size: Typography.tiny))
                    }
                    // 时间底色基线；上面两处已单独着色（SwiftUI 局部修饰符优先于外层）
                    .foregroundStyle(.tertiary)
                }
            }
            if compact { Spacer(minLength: 0) }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity,
               minHeight: compact ? MemoCardMetrics.minHeight : 0,
               alignment: .topLeading)
        .pastelCard()
        .contentShape(Rectangle())
    }
}

// MARK: - v4.0.50 启动链类型折叠（防启动期 demangler 递归爆主线程 1MB 栈）
//
// 事故与 ChatView（v4.0.49）/ DashboardView（v4.0.50）同源：本文件 body 返回类型名里
// **内联**了每条 .sheet 内容闭包的完整类型（各 sheet 的正文视图树），dSYM 实测 body 的
// mangled 类型名 1340 字符。危险量是**名字的字符数**（≈19 字符 = 1 帧 demangler 递归，
// 每帧 ~9.3KB 主线程栈），TabView 启动即渲染本页，与其它视图叠加可吃干 1MB 栈 → 一点开就闪退。
//
// 修法 = 把 body 的修饰器链折成具名 ViewModifier 分组：父类型名里只剩组名，链在各组自己的
// applyXxx 调用里解析（各自一次 1MB 栈预算）。⚠️ 修饰器**种类/数量/顺序/参数**逐字未变
// （等价重构，视图树与身份/动画真源不动）；谁也不许把这些链再内联回 body ——
// 改链请改这里的 applyXxx，别动调用点。
//
// v4.0.78：三张 .sheet 已改为 MemoGlassOverlay 浮层（挂在 LifeView 根的 TodoGlassLayerHost），
// 本 section 的 body 类型名随之大幅缩短；「折叠组 2（三张弹窗）」+ TodoSectionBodySheets
// 一并删除（body 只剩页壳这一条链）。折叠组的护栏规矩保留。
extension TodoSection {
    /// 折叠组 1（2 条修饰器）：页壳（宽度对齐 + 进页面拉一次数据）
    @MainActor
    private func applyTodoSectionBodyChrome<C: View>(to content: C) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { await store.loadFromServer() }
    }

    @MainActor
    private struct TodoSectionBodyChrome: ViewModifier {
        let host: TodoSection

        func body(content: Content) -> some View { host.applyTodoSectionBodyChrome(to: content) }
    }
}
