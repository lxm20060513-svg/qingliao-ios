// MARK: - v3.7.0 生活页「备忘录」栏目
// v3.9.14：体验升级——便签化卡片 / 置顶 / 相对时间 / 来源图标 / 折叠 / 可编辑 / 一键发给 AI
// v3.9.17：按用户选定的方案 A 改版——
//   ① 「备忘录」+「添加」胶囊搬到卡片外，做页级标题行（与 LifeCardsSection 的「生活数据」同款：
//      粗体 15pt 标题 + Spacer + 淡色胶囊，卡片里只装内容）
//   ② 卡片只显示 1 条（置顶优先、其次最后修改时间倒序），后面压 2 层错位卡片边
//   ③ 点整块 → 弹「全部备忘」列表（半屏，可拖到全屏）；原卡片内的「全部 N 条」折叠行随之删除
import SwiftUI

struct MemoSection: View {
    @State private var store = MemoStore.shared
    @State private var showAdd = false
    @State private var showAll = false
    /// v3.9.20：卡片 → 「全部备忘」列表的原生 zoom 转场（同看板卡片 / 资讯→大爆炸那套）
    @Namespace private var memoZoomNS
    @State private var draft = ""
    @State private var detail: MemoItem?
    @State private var pendingDelete: MemoItem?

    /// v3.9.17：堆叠几何——两层卡边的水平内缩 / 下移量（真机微调只改这四个数）
    private let layerInset1: CGFloat = 12
    private let layerInset2: CGFloat = 24
    private let layerDrop1: CGFloat = 6
    private let layerDrop2: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // v3.9.17：标题行在卡片外（原来是卡片内的图标 + 灰字 + 计数胶囊）
            pageHeader
            if store.memos.isEmpty {
                emptyTap
            } else {
                memoStack
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // v3.7.0：进入生活页即拉 NAS 上的备忘（本地已有则远端为空时不清本地）
        .task { await store.loadFromServer() }
        .sheet(isPresented: $showAdd) { addSheet }
        // v3.9.17：点卡片 → 全部备忘列表
        .sheet(isPresented: $showAll) { allSheet }
        // v3.9.17：onDismiss 复位——若某次 present 被别的 sheet 挡掉，detail 会一直非 nil，
        // 之后「换一条」就不再触发 .sheet(item:)，详情再也打不开
        .sheet(item: $detail, onDismiss: { detail = nil }) { m in
            MemoDetailSheet(item: m, onDelete: { item in
                detail = nil
                // 等 detail sheet 完全 dismiss 再弹确认框（同一帧里同时 present 会丢弹窗）
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    pendingDelete = item
                }
            })
            .presentationDetents([.medium, .large])
        }
        .alert("删除这条备忘？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let item = pendingDelete { store.delete(item) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.content.prefix(40).description ?? "")
        }
    }

    // MARK: 页级标题行（v3.9.17：与「生活数据」同款——标题在卡片外，右侧放宽/实心胶囊）

    private var pageHeader: some View {
        HStack(spacing: 8) {
            Text("备忘录")
                .font(.system(size: Typography.body, weight: .bold))
            if !store.memos.isEmpty {
                Text("\(store.memos.count) 条")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                draft = ""
                showAdd = true
            } label: {
                // v3.9.4：只留文字 + 胶囊（去图标）；v3.9.19：尺寸走 .pill(.page) 口径
                Text("添加").pill(.page)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("添加备忘录")
        }
        .padding(.top, Spacing.sm)
    }

    /// v3.9.14：空态改成"可点的引导卡"——原来那句话是说明书腔，现在点了就能写
    private var emptyTap: some View {
        Button {
            draft = ""
            showAdd = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("记点什么")
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.primary)
                    Text("聊天里长按消息、大爆炸选词，都能存进来")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                .fill(Color.secondary.opacity(Tint.faint)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    // MARK: 堆叠卡（v3.9.17：主卡 1 条 + 后面 2 层错位卡边，点整块弹全部）

    /// 后面露几层：1 条 = 不露；2 条 = 露 1 层；≥3 条 = 露 2 层
    private var stackLayerCount: Int {
        min(2, max(0, store.sorted.count - 1))
    }

    private var stackBottomSpace: CGFloat {
        switch stackLayerCount {
        // v3.9.17：比 offset 多留 3pt——两者相等时零余量，圆角/高度一调就会被下一块内容压住
        case 0: return 0
        case 1: return layerDrop1 + 3
        default: return layerDrop2 + 3
        }
    }

    @ViewBuilder
    private var memoStack: some View {
        if let top = store.sorted.first {
            Button {
                showAll = true
            } label: {
                MemoNoteCard(item: top)
            }
            .buttonStyle(PressStyle())
            .contextMenu { memoMenuItems(top, onDelete: { pendingDelete = $0 }) }
            // v3.9.17：层挂在主卡的 background 上——与主卡同尺寸再内缩 + 下移，主卡多高它就多高
            .background(alignment: .top) { stackedLayers }
            // v3.9.20：卡片即 zoom 源（挂在留白之前，源矩形取主卡本体）
            .matchedTransitionSource(id: "memo-all", in: memoZoomNS)
            // 给露出的卡边留位置（offset 不改变布局尺寸，不留就会被下一块内容压住）
            .padding(.bottom, stackBottomSpace)
            .animation(Motion.snap, value: stackLayerCount)
            .accessibilityLabel("备忘录，共 \(store.sorted.count) 条，点开查看全部")
        }
    }

    private var stackedLayers: some View {
        ZStack {
            if stackLayerCount >= 2 {
                stackedLayerShape(inset: layerInset2, drop: layerDrop2, tone: 0.12)
            }
            if stackLayerCount >= 1 {
                stackedLayerShape(inset: layerInset1, drop: layerDrop1, tone: 0.09)
            }
        }
    }

    /// 单层卡边：不透明底（半透明会透出下面那张，看着发脏）+ 0.8pt 描边（与全站口径一致）
    private func stackedLayerShape(inset: CGFloat, drop: CGFloat, tone: Double) -> some View {
        RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
            .overlay(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                .fill(Color.secondary.opacity(tone)))
            .overlay(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                .stroke(Color.secondary.opacity(Tint.soft), lineWidth: 0.8))
            .padding(.horizontal, inset)
            .offset(y: drop)
    }

    // MARK: 全部备忘列表（v3.9.17，半屏 sheet）

    private var allSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // v3.9.18：顶栏同样自绘（系统那版「完成」胶囊偏大）
                HStack(spacing: 8) {
                    // v3.9.19：13pt → 17pt（原来偏小）；v3.9.22 详情页标题单独加到 20pt，
                    // 列表这里保持 17pt —— 列表是密集行，标题再大反而压迫内容
                    Text("全部备忘")
                        .font(.system(size: Typography.title, weight: .semibold))
                    Text("\(store.sorted.count) 条")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    MiniCapsule(title: "完成", accent: true) { showAll = false }
                }
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.md)
                ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.sorted) { m in
                        Button {
                            openDetailFromAll(m)
                        } label: {
                            MemoNoteCard(item: m)
                        }
                        .buttonStyle(PressStyle())
                        .contextMenu {
                            memoMenuItems(m,
                                          onDelete: { item in afterAllDismissed { pendingDelete = item } },
                                          onSend: { item in afterAllDismissed { sendToAI(item) } })
                        }
                    }
                    // v3.9.17：列表打开期间备忘被删空（远端合并等）不会只剩一个空面板
                    if store.sorted.isEmpty {
                        Text("还没有备忘")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 20)
                    }
                }
                .padding(Spacing.section)
            }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .navigationTransition(.zoom(sourceID: "memo-all", in: memoZoomNS))   // v3.9.20：从备忘录卡片放大展开
    }

    /// v3.9.17：先收掉「全部备忘」列表，等它 dismiss 完再执行动作
    /// （列表里的详情/删除/发消息都在 sheet 之上触发，同帧 present 会丢弹窗）
    private func afterAllDismissed(_ action: @escaping () -> Void) {
        showAll = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !showAll else { return }   // 期间用户又点开了列表 → 放弃这次动作
            action()
        }
    }

    /// 从列表点一条 → **先收列表，再开详情**（v3.9.21 真机回归后确认必须这样，勿再改）
    ///
    /// 🚨 真正原因（比原注释说的"同帧 present 丢弹窗"更根本）：MemoSection 上**链式挂了三个 `.sheet`**
    /// （showAdd / showAll / detail），它们共用同一个宿主视图；两个同时为真时 **只有一个会生效**，
    /// 于是"列表还开着就 present 详情"= 详情被吞掉 → 真机表现为**点一条打不开详情**。
    /// v3.9.20 曾为了保留"列表行→详情"的 zoom 转场（zoom 要求源行在呈现时仍在屏上）把这里改成直接
    /// `detail = m`，真机回归即挂 —— zoom 再好看也不能拿功能换。
    /// 若日后仍想要那个转场，正确做法是把 detail 这个 sheet **挂到 allSheet 的内容视图内部**（分层宿主），
    /// 而不是让两个 sheet 共用一个宿主。
    private func openDetailFromAll(_ m: MemoItem) {
        afterAllDismissed { detail = m }
    }

    // MARK: 长按菜单（卡片 / 列表两处共用）

    /// v3.9.17：带回调——「全部备忘」列表里触发的删除/发消息必须先收掉 sheet（同帧 present 会丢），
    /// 卡片上的长按则直接执行
    @ViewBuilder
    private func memoMenuItems(_ m: MemoItem,
                               onDelete: @escaping (MemoItem) -> Void,
                               onSend: ((MemoItem) -> Void)? = nil) -> some View {
        Button {
            store.togglePin(m)
            Haptics.success()
        } label: {
            Label(m.pinned ? "取消置顶" : "置顶", systemImage: m.pinned ? "pin.slash" : "pin")
        }
        Button {
            if let onSend { onSend(m) } else { sendToAI(m) }
        } label: {
            Label("发给 AI", systemImage: "paperplane")
        }
        Button {
            UIPasteboard.general.string = m.content
            Haptics.success()
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        Button(role: .destructive) {
            onDelete(m)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    /// v3.9.14：把备忘内容作为一条用户消息发给 AI，并切回聊天页。
    /// 备忘存下来只能复制粘贴没意义——能直接接着办才是轻聊备忘录区别于系统备忘录的地方。
    private func sendToAI(_ m: MemoItem) {
        NotificationCenter.default.post(name: .qingliaoMemoSend, object: m.content)
        Haptics.success()
    }

    // MARK: 新增

    private var addSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $draft)
                    .font(.system(size: Typography.title))
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("写点什么…")
                                .font(.system(size: Typography.title))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, Spacing.section)
                                .padding(.vertical, 20)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, Spacing.section)
                    .padding(.top, Spacing.md)
            }
            .navigationTitle("新建备忘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAdd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if store.add(content: draft, source: "manual") {
                            Haptics.success()
                        }
                        showAdd = false
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - v3.9.18 自绘顶栏用的小胶囊
// 为什么不用系统 toolbar：iOS 26 会把导航栏按钮渲染成玻璃胶囊，尺寸由系统定（字号/controlSize 都压不小），
// 用户反馈「关闭/编辑/复制胶囊太大」→ 自绘顶栏 + `.toolbar(.hidden, for: .navigationBar)`，尺寸完全可控。
// 口径：tiny 字号 + h10/v5（比页级标题行的 h10/v4 略高一点，因为它是顶部主操作区）。

private struct MiniCapsule: View {
    let title: String
    var accent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // v3.9.19：走 .pill(.topBar) 口径；原 accent 分支是实色底，改为口径内的淡底（与全站一致）
            // v3.9.22：.topBar 档字号 tiny(10) → subhead(13)，用户反馈这些小胶囊文字偏小
            Text(title)
                .pill(.topBar, tone: accent ? .accent : .neutral)
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - 便签卡视觉（v3.9.17：抽成独立 struct——卡片 / 全部列表两处共用；
// 底色改「不透明底 + 淡色调」，原来纯半透明底会透出后面的堆叠层，看着发脏）
//
// ⚠️ 圆角登记：本卡与两层卡边**有意**用 12（v3.9.14 起便签形态 + 用户选定的堆叠方案稿），
//    与全站卡片 16 的约定（LiquidGlass.swift 圆角约定注释）并存——别按约定回改，
//    改回 16 之后「主卡 + 露出的卡边」层次会糊在一起

private struct MemoNoteCard: View {
    let item: MemoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.content)
                .font(.system(size: Typography.body))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            metaRow
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(noteBackground)
        .overlay(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
            .stroke(item.pinned ? Color.accentColor.opacity(Tint.strong) : Color.secondary.opacity(Tint.soft),
                    lineWidth: 0.8))
        .contentShape(Rectangle())
    }

    /// 与全站卡片同底（secondarySystemGroupedBackground）再叠一层淡色调 → 完全不透明
    private var noteBackground: some View {
        RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
            .overlay(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                .fill(item.pinned ? Color.accentColor.opacity(Tint.faint) : Color.secondary.opacity(Tint.faint)))
    }

    private var metaRow: some View {
        HStack(spacing: 5) {
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(Color.accentColor)
            }
            // v3.9.14：来源用图标代替文字（省一行宽度，一眼看出从哪来的）
            Image(systemName: item.sourceIcon)
                .font(.system(size: Typography.tiny))
            Text(item.timeText)
                .font(.system(size: Typography.caption))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tertiary)
    }
}

// MARK: - 放大查看 / 编辑（点卡片进入）

private struct MemoDetailSheet: View {
    let item: MemoItem
    var onDelete: (MemoItem) -> Void

    @Environment(\.dismiss) private var dismiss
    /// v3.9.14：本地副本——编辑/置顶后要立刻反映在本页（item 是传值进来的）
    @State private var current: MemoItem
    @State private var editing = false
    @State private var editText = ""
    @State private var copied = false

    init(item: MemoItem, onDelete: @escaping (MemoItem) -> Void) {
        self.item = item
        self.onDelete = onDelete
        _current = State(initialValue: item)
    }

    private var store = MemoStore.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // v3.9.18：顶栏自绘——iOS 26 系统导航栏渲染的玻璃胶囊偏大（用户反馈「关闭/编辑/复制
                // 胶囊太大，小一点更协调」），改成与全站一致的小胶囊（tiny 字号 + h10/v5），尺寸可控
                topBar
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if editing {
                        // v3.9.14：补上编辑（MemoStore.update 早就写好了，一直没入口）
                        TextEditor(text: $editText)
                            .font(.system(size: Typography.body))
                            .lineSpacing(LineSpacing.long)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220, alignment: .topLeading)
                            .padding(Spacing.lg)
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    } else {
                        Text(current.content)
                            .font(.system(size: Typography.headline))
                            .lineSpacing(LineSpacing.long)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 6) {
                        if current.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: Typography.tiny))
                                .foregroundStyle(Color.accentColor)
                        }
                        Image(systemName: current.sourceIcon)
                            .font(.system(size: Typography.tiny))
                        // subtitle 本身已含来源（"手记 · 刚刚"），别再叠一次 sourceLabel
                        Text(current.subtitle)
                            .font(.system(size: Typography.subhead))
                    }
                    .foregroundStyle(.tertiary)
                }
                .padding(18)
            }
            }
            // v3.9.18：系统导航栏已由自绘 topBar 取代（iOS 26 的玻璃胶囊偏大）
            .toolbar(.hidden, for: .navigationBar)
            // 编辑态禁止下滑关闭：不然手一滑草稿就没了，且没有任何提示
            .interactiveDismissDisabled(editing)
            // 编辑态下藏底部操作条，免得"删除"和"保存"挨着误触
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
    }

    // MARK: v3.9.18 顶栏（自绘，替掉 iOS 26 系统导航栏那套偏大的玻璃胶囊）

    private var topBar: some View {
        HStack(spacing: 8) {
            if editing {
                MiniCapsule(title: "取消") { editing = false }
                Spacer(minLength: 0)
                MiniCapsule(title: "保存", accent: true) { saveEdit() }
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                MiniCapsule(title: "关闭") { dismiss() }
                Spacer(minLength: 0)
                MiniCapsule(title: "编辑") {
                    editText = current.content
                    editing = true
                }
                MiniCapsule(title: copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = current.content
                    Haptics.success()
                    copied = true
                }
            }
        }
        .padding(.horizontal, Spacing.section)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.sm)
        .overlay {
            if !editing {
                // v3.9.22：17pt → 20pt（Typography.headline）。用户两次反馈"太小"：
                // v3.9.18 自绘顶栏误用 subhead(13) → v3.9.19 回到 17pt（系统 inline 标题档）→ 仍嫌小，
                // 定稿 20pt。字号档位：tiny 10 / caption 11 / subhead 13 / body 15 / title 17 / headline 20 / titleXL 24
                Text("备忘录")
                    .font(.system(size: Typography.headline, weight: .semibold))
                    .foregroundStyle(.primary)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: v3.9.18 底部操作条
    // 用户反馈「胶囊是半透明的，字体在胶囊下面看得见，很乱」——根因是 ① 操作条本身没有底、
    // ② 胶囊用 accentColor/red 的 12% 半透明填充，滚动的正文从按钮下面透出来。
    // 改法：操作条铺不透明底 + 顶边 0.8pt 分割线；胶囊改实色（主操作=主题色实底白字，危险=实心红底白字）

    @ViewBuilder
    private var bottomBar: some View {
        if !editing {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        store.togglePin(current)
                        current.pinned.toggle()
                        Haptics.success()
                    } label: {
                        actionLabel(current.pinned ? "取消置顶" : "置顶",
                                    systemImage: current.pinned ? "pin.slash" : "pin",
                                    tone: .accent)
                    }
                    .buttonStyle(PressStyle())

                    Button {
                        NotificationCenter.default.post(name: .qingliaoMemoSend, object: current.content)
                        Haptics.success()
                        dismiss()
                    } label: {
                        actionLabel("发给 AI", systemImage: "paperplane", tone: .accent)
                    }
                    .buttonStyle(PressStyle())
                }
                Button(role: .destructive) {
                    onDelete(current)
                } label: {
                    actionLabel("删除这条备忘", systemImage: "trash", tone: .danger)
                }
                .buttonStyle(PressStyle())
            }
            .padding(.horizontal, 18)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.lg)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.primary.opacity(Tint.faint))
                    .frame(height: 0.8)
            }
        }
    }

    /// 淡色胶囊动作按钮（用户指定：胶囊保持淡色底，靠**操作条的不透明底**挡住正文，
    /// 不要改成实色——v3.9.18 曾试实色被否）
    private func actionLabel(_ title: String, systemImage: String, tone: PillTone) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity)          // 先撑满，再上胶囊底（背景才不会只包住文字）
            .pill(.primary, tone: tone)          // v3.9.19：主操作口径 body + h14/v12
            .contentShape(Capsule())
    }

    private func saveEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.update(current, content: text)
        // 只有内容真变了才动本地副本的时间：store.update 在内容未变时什么都不做，
        // 这里若无条件改，详情页会显示"刚刚"而存储里没变（两处时间分叉）
        if current.content != text {
            current.content = text
            current.updatedAt = Date()
        }
        editing = false
        Haptics.success()
    }
}
