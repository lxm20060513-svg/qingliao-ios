import SwiftUI

// MARK: - 会话页（真实会话列表 + 滑动删除 + 点击进入聊天）

struct SessionsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(ChatStore.self) private var chat
    @Environment(CategoryStore.self) private var categoryStore   // v3.0.27：会话分类
    @Environment(SessionTagStore.self) private var tagStore     // v3.0.51 B7：会话标签
    // v4.0.x：会话列表「进行中」标识的流真源（用户 2026-09-27 拍板）。
    // 只在这里读 isStreaming / isDone 两个布尔；**不许**读 stream.content —— 那是每 token 都变的量，
    // 一旦被 body 读到，整张会话列表会跟着每个 token 重算一次。
    @Environment(StreamClient.self) private var stream

    @State private var sessions: [ChatSession] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var scrollPos = ScrollPosition()
    @State private var deleteError: String?
    // v2.0.36：搜索 + 置顶
    @State private var searchText = ""
    // v3.9.33：远端全史搜索——冷启动缓存只有最近 100 会话 × 每会话 50 条消息，
    // 两个月前的会话本地搜不到，本地零命中时补一次 POST /api/sessions/search
    @State private var remoteHits: [SessionSearchHit] = []
    @State private var remoteSearching = false
    @State private var remoteFailed = false
    @State private var remoteNotice: String?
    @State private var remoteSearchTask: Task<Void, Never>?
    // v2.0.78：搜索框焦点（键盘收回）
    @FocusState private var focused: Bool
    // v3.4.25：本地实时搜索——直接过滤内存 sessions（标题+消息内容），不再走后端接口
    @State private var pinnedIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "qingliao_pinned_sessions") ?? [])
    // v2.0.60：会话收藏（⭐）
    @State private var favIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "qingliao_fav_sessions") ?? [])
    // v2.0.43：会话重命名
    @State private var renameTarget: ChatSession?
    @State private var renameText = ""
    // v3.9.39：改名同步失败提示（镜像 deleteError；errorText 只在列表为空时才会渲染，承载不了）
    @State private var renameError: String?
    // v3.9.39：列表当前是否反映**网络**拉取结果（而非冷启动缓存）。
    // 缓存每会话截断到最近 50 条，而后端 merge 是整会话覆盖——用缓存快照去改名会永久截断历史。
    @State private var sessionsFromNetwork = false
    // v2.0.57：删除确认（contextMenu 关闭瞬间不改数据）
    @State private var confirmDelete: ChatSession?
    // v2.0.87ad：多选删除
    @State private var editing = false
    @State private var selectedIds = Set<String>()
    // v4.1.x：长按菜单「清空会话内容」——清消息、**保留会话本身与标题**。
    // 与「删除会话」是两件事：删除走 merge 的 deleted 键（整条会话消失），
    // 清空走 merge 的 sessions 键 + 空 messages 数组（会话仍在，标题沿用当前值）。
    @State private var confirmClear: ChatSession?
    // 清空失败提示（沿用 renameError/deleteError 的口径：errorText 只在列表为空时才渲染，承载不了）
    @State private var clearError: String?
    // v3.9.39：批量删除确认（镜像 confirmDelete：先确认再动数据）。条数单独存一份，
    // 不用可空值同时当弹窗驱动——那样弹窗退场时计数已被清成 nil，文案会跳成「0 个会话」
    @State private var confirmBatchDelete = false
    @State private var batchDeleteCount = 0
    // v3.0.7：会话列表加载节流（3s 内不重复拉，防快速滑动切 Tab 重复触发 isLoading 翻转）
    @State private var lastLoadAt: Date?
    // v3.0.27：会话分类
    @State private var showAddCategory = false
    @State private var deleteCategoryTarget: SessionCategory?   // v3.9.32：删除分类确认
    @State private var addCategoryForSession: String?
    @State private var newCategoryName = ""
    // v3.0.51 B7：会话标签
    @State private var tagTarget: ChatSession?
    @State private var showNewTag = false
    @State private var newTagName = ""
    // v3.4.29：新建会话图标弹一下
    @State private var plusBounceTick = 0
    var onOpenSession: (() -> Void)? = nil   // 切到聊天 tab

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            sessionsHeaderBar
            if isLoading && sessions.isEmpty {
                sessionsLoadingSkeleton
            } else if let err = errorText, sessions.isEmpty {
                sessionsErrorState
            } else {
                // v3.9.41（SR47）：拉取失败但列表已有数据时，原先整条错误信息都不渲染
                // （错误态判据是 sessions.isEmpty）→ 冷启动缓存秒显后遇网络失败，
                // 用户以为看到的是最新数据。补顶部横幅，列表仍可操作。
                if errorText != nil { sessionsStaleBanner }
                sessionsListBody
            }
        }
        .task { await load() }
        // v2.0.102：切回会话列表立即刷新（聊天里新建/重命名后列表即时更新，原只有 .task 首刷）
        .onAppear {
            Task { await load() }
        }
        // v3.9.33：关键词变化 → 本地过滤即刻生效（无网络），远端全史搜索走 450ms 防抖
        .onChange(of: searchText) { _, newValue in
            scheduleRemoteSearch(newValue)
        }
        // v2.0.78：搜索键盘完成按钮
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focused = false }
            }
        }
        .alert("删除失败", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("好", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        // v3.9.39：改名同步失败/被拦（本地标题已回滚）
        .alert("改名未保存", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("好", role: .cancel) { renameError = nil }
        } message: {
            Text(renameError ?? "")
        }
        // v2.0.43：会话重命名
        .alert("重命名会话", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("新名称", text: $renameText)
            Button("确定") { rename() }
            Button("取消", role: .cancel) {}
        }
        // v2.0.87ad：多选底部删除栏 → 已提取为 batchEditBottomBar（v4.0.16 降载，语义等价）
        .safeAreaInset(edge: .bottom) { batchEditBottomBar }
        .alert("删除会话", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let s = confirmDelete {
                    confirmDelete = nil
                    Task { try? await Task.sleep(for: .seconds(0.3)); delete(s) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除「\(confirmDelete?.title ?? "")」及其全部消息，此操作不可恢复")
        }
        // v3.9.39：批量删除确认（此前底部红按钮一点就直接对服务器发 merge，零确认；单条删除一直有框）
        .alert("批量删除会话", isPresented: $confirmBatchDelete) {
            Button("删除", role: .destructive) {
                // 弹窗完全关闭再动数据（v2.0.57 同源经验：删除会撤掉整个多选栏，动画期改状态易炸）
                Task { try? await Task.sleep(for: .seconds(0.3)); deleteSelected() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(batchDeleteCount) 个会话及其全部消息，此操作不可恢复")
        }
        // v3.0.27：新建分类
        .alert("新建分类", isPresented: $showAddCategory) {
            TextField("分类名称", text: $newCategoryName)
            Button("创建") {
                let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let cat = SessionCategory(id: UUID().uuidString.prefix(8).description,
                                          name: name, icon: "folder.fill", color: "#007AFF")
                categoryStore.addCategory(cat)
                if let sid = addCategoryForSession {
                    categoryStore.assignSession(sid, to: cat.id)
                }
            }
            Button("取消", role: .cancel) {}
        }
        // v3.9.32：删除分类确认（连带解除该分类下所有会话的归属）
        .alert("删除分类", isPresented: Binding(get: { deleteCategoryTarget != nil }, set: { if !$0 { deleteCategoryTarget = nil } })) {
            Button("删除", role: .destructive) {
                if let cat = deleteCategoryTarget {
                    categoryStore.removeCategory(cat.id)
                }
                deleteCategoryTarget = nil
            }
            Button("取消", role: .cancel) { deleteCategoryTarget = nil }
        } message: {
            Text("将删除分类「\(deleteCategoryTarget?.name ?? "")」，其中的会话会回到「无分类」（会话本身不会删）")
        }
        // v3.0.51 B7：新建标签
        .alert("新建标签", isPresented: $showNewTag) {
            TextField("标签名称（≤6字）", text: $newTagName)
            Button("创建") {
                let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                tagStore.addCustomTag(name)
                if let sid = tagTarget?.id {
                    tagStore.toggle(name, on: sid)
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 巨型 body 拆分（纯搬运）
    //
    // 由头：此 body 单块 242 行，是本仓已踩过两次的「Unable to type-check this
    // expression in reasonable time」高危形态（一次漏检 = 20 分钟 CI 循环）。
    // 这里按原注释分段把视图块原样搬成独立 @ViewBuilder 属性 —— **纯搬运**：视图顺序、
    // 层级、条件分支、闭包、修饰符逐字未变，渲染结果与拆分前一致，只为把类型检查表达式打小。

    /// 页头（多选入口 + 新建）+ 会话搜索框
    @ViewBuilder
    private var sessionsHeaderBar: some View {
        // v2.0.87ad：多选编辑入口（非空会话时显示）
        PageHeader(title: "会话", trailing: AnyView(HStack(spacing: 14) {
            if !sessions.isEmpty {
                Button {
                    withAnimation(Motion.tap) {
                        editing.toggle()
                        if !editing { selectedIds.removeAll() }
                    }
                } label: {
                    Image(systemName: editing ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: Typography.headline, weight: .medium))
                        .foregroundStyle(editing ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
            }
            addButton
        }))
        // v3.4.25：会话搜索框（毛玻璃风格 glassListCard 与 App 列表卡一致；输入即本地过滤）
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
            TextField("搜索会话与消息", text: $searchText)
                .font(.system(size: Typography.body))
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { focused = false }   // 键盘「搜索」= 收起
            if isSearching {
                Button {
                    searchText = ""   // v3.4.25：清空搜索即恢复全量列表
                    focused = false   // 清空同时收键盘
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.tertiary)
                }
                .accessibilityLabel("清空搜索")
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .glassListCard()   // v3.4.25：毛玻璃风格（Theme/LiquidGlass.swift GlassListCard）
        .padding(.horizontal, Spacing.xxl)
        .padding(.bottom, Spacing.md)

        // v4.1.x：清空会话内容确认（先确认再动数据，同 delete 的两处保险口径）
        .alert("清空会话内容", isPresented: Binding(get: { confirmClear != nil }, set: { if !$0 { confirmClear = nil } })) {
            Button("清空", role: .destructive) {
                if let s = confirmClear {
                    confirmClear = nil
                    Task { try? await Task.sleep(for: .seconds(0.3)); clearContent(s) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            // 不带条数：列表可能来自 50 条冷启动缓存（loadFromSessionCache），
            // 显示的条数与服务器真实条数不符，用户会以为只清了一部分。
            Text("将清空「\(confirmClear?.title ?? "")」的全部消息，会话与标题保留，此操作不可恢复")
        }
        // v4.1.x：清空失败提示（列表非空时 errorText 不渲染，失败会完全静默）
        .alert("清空失败", isPresented: Binding(get: { clearError != nil }, set: { if !$0 { clearError = nil } })) {
            Button("好", role: .cancel) { clearError = nil }
        } message: {
            Text(clearError ?? "")
        }
    }


    /// v4.0.16：多选底部删除栏（原挂在 body 主链上）
    ///
    /// 为什么搬出来：body 主修饰链在本版加了 2 条 alert 后类型检查超时（CI #631
    /// `SessionsView.swift:225 unable to type-check`）。alert 已迁 2 条到 headerBar，
    /// 剩下这条 safeAreaInset 内含大 HStack（3 个 Button + Text + 背景）同样占预算 ——
    /// 一次搬完，别等下一轮 CI 在别的行再报同一个错。
    /// 语义等价：safeAreaInset 是视图级 modifier，挂在 headerBar 上仍作用于同一屏。
    @ViewBuilder
    private var batchEditBottomBar: some View {
            if editing {
                HStack(spacing: 14) {
                    Button {
                        // v3.9.39：全选只覆盖**当前可见**的会话。搜索态列表渲染的是 filteredSessions，
                        // 原来取 sortedSessions 的全部 id → 搜到 3 行、全选、删除 = 对全部会话发 merge。
                        if allVisibleSelected {
                            selectedIds.subtract(visibleSessionIDs)
                        } else {
                            selectedIds.formUnion(visibleSessionIDs)
                        }
                    } label: {
                        Text(allVisibleSelected ? "取消全选" : "全选")
                            .font(.system(size: Typography.subhead, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                    Spacer()
                    Text("\(selectedIds.count) 条")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.secondary)
                    Button {
                        // v3.9.39：批量删除先确认（此前一点就直接对服务器发 merge）
                        batchDeleteCount = selectedIds.count
                        confirmBatchDelete = true
                    } label: {
                        Label("删除", systemImage: "trash")
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, Spacing.md)
                            .background(selectedIds.isEmpty ? Color.red.opacity(0.4) : Color.red,
                                        in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    }
                    .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                    .disabled(selectedIds.isEmpty)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, Spacing.lg)
                .padding(.bottom, 78)   // v2.0.87af：避开 Dock 栏高度
                .background(.ultraThinMaterial)
            }
    }

    /// 首屏骨架屏
    @ViewBuilder
    private var sessionsLoadingSkeleton: some View {
        // v3.9.0：首屏加载改骨架屏（比转圈更能预示"内容马上出现在这里"，且不白屏）
        // v3.9.42：参数收口进 LoadingStateView.rows（行距/左右留白与本处原值一致，观感不变）
        LoadingStateView(shape: .rows(3))
        Spacer()
    }

    /// 加载失败 + 重试
    @ViewBuilder
    private var sessionsErrorState: some View {
        Spacer()
        // v3.9.42：收口到 ErrorStateView。注意 title 是固定「加载失败」，后端返回的原文放 detail
        //（v3.9.32 的教训仍成立：这里必须走 errorText，裸 err 会被解析成 Darwin 的 err() 函数）
        ErrorStateView(title: "加载失败", detail: errorText) {
            Task { await load() }
        }
        Spacer()
    }

    /// v3.9.41（SR47）：拉取失败但已有缓存列表 —— 顶部提示「当前是上次成功的数据」+ 原地重试。
    /// 与 sessionsErrorState 互斥（那条只在列表为空时整屏替换）。
    @ViewBuilder
    private var sessionsStaleBanner: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            Text("\(errorText ?? "加载失败")，当前显示的是上次成功的数据")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.sm)
            Button("重试") { Task { await load(force: true) } }
                .font(.system(size: Typography.subhead, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.md)
        .background(Color.primary.opacity(0.05))
    }

    /// v4.0.20（#9）：后台推进浮条（有后台跑流才出现；点一下跳到那条会话）
    @ViewBuilder
    private var backgroundRunningBar: some View {
        let ids = backgroundRunningIDs
        if !ids.isEmpty {
            let names = ids.compactMap { id in sessions.first { $0.id == id }?.title }
            Button {
                Haptics.tap()
                if let first = ids.sorted().first, let s = sessions.first(where: { $0.id == first }) {
                    open(s)
                }
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "hourglass")
                        .font(.system(size: Typography.caption, weight: .semibold))
                    Text(names.isEmpty
                         ? "后台正在推进 \(ids.count) 个任务"
                         : "后台正在推进：\(names.prefix(2).joined(separator: "、"))\(names.count > 2 ? " 等" : "")")
                        .font(.system(size: Typography.caption, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("查看")
                        .font(.system(size: Typography.caption, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(Tint.subtle), in: Capsule())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("后台正在推进，点按查看")
        }
    }

    /// 会话列表（搜索区 / 空态 / 卡片列表）
    ///
    /// v4.0.21：容器 **ScrollView + LazyVStack → List**（用户拍板「换 List 让左滑真能用」）。
    /// 根因：`.swipeActions` 的官方语义是**只对 List 行生效**（"Adds swipe actions to a view
    /// that is presented in a list."）—— 此前它挂在 LazyVStack 的行上，修饰符**静默无效**，
    /// 左滑删除在真机上一直没有反应（编译器、预检、编译期全都不报，只有手指能发现）。
    /// 观感靠逐行抹平 List 自带样式，数值与改造前**逐值对齐**（改前：外层 spacing 10、
    /// 会话行 spacing 8、左右 padding `Spacing.xxl`=14、底部留白 90），口径收在
    /// `.sessionListRow(vHalfGap:)` 单一处（见文件尾 SessionListRowChrome）。
    /// 惰性渲染仍由 List 自身保证（原 LazyVStack 的省内存目的不变，见 v3.9.48 记录）。
    @ViewBuilder
    private var sessionsListBody: some View {
        List {
            if isSearching {
                // v3.9.33：搜索结果区（本地优先，本地零命中再补远端全史搜索）
                searchResultsArea
            } else {
                BotCard()
                    .sessionListRow(vHalfGap: 5)   // 5×2 = 10pt（= 原外层 LazyVStack(spacing: 10)）
                // v4.0.20（#9）：后台推进常驻浮条 —— 退出聊天页后仍能看到「后台还在跑」，
                // 点一下直接跳回那条会话（此前一离开聊天页就完全失去线索）
                backgroundRunningBar
                    .sessionListRow(vHalfGap: 5)
                if sessions.isEmpty {
                    sessionsEmptyState
                        .sessionListRow(vHalfGap: 5)
                } else {
                    sessionsListStack
                }
            }
        }
        .listStyle(.plain)                                  // 去掉分组灰底与分组头悬浮行为
        .scrollContentBackground(.hidden)                    // 透出页面底（原本是 ScrollView 的透明底）
        .environment(\.defaultMinListRowHeight, 0)          // List 默认给行兜底 44pt 最小高，会把卡片间距撑变形
        .contentMargins(.bottom, 90, for: .scrollContent)    // = 原 `.padding(.bottom, 90)`
        // v3.9.30：空态/列表切换过渡动画（emerge 浮现；reduceMotion 时系统自动忽略带动画的过渡）
        .animation(Motion.emerge, value: filteredSessions.isEmpty)
        // v3.9.30：删除/刷新后列表项淡出与位置移动过渡（数组替换不再生硬跳变）
        .animation(Motion.settle, value: sortedSessions.map(\.id))
        .scrollPosition($scrollPos)
        // v2.0.86h：Dock 滑动隐藏已删除（从未生效，手动开关替代）
        .refreshable {
            if !isSearching { await load() }
        }
    }

    /// 空态插画
    @ViewBuilder
    private var sessionsEmptyState: some View {
        // v2.0.65：空状态插画
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.blue.opacity(Tint.strong), Color.indigo.opacity(Tint.soft)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 64)
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: Typography.titleXL))
                    .foregroundStyle(Color.blue.opacity(0.7))
            }
            Text("暂无会话记录")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            Text("点击右上角 + 开始和 AI 对话")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 20)
    }

    /// 会话卡片行（List 行）
    ///
    /// v4.0.21：外层 `LazyVStack(spacing: 8)` 去掉 —— 行必须**直接**落在 List 里，
    /// `.swipeActions` 才生效（根因见 sessionsListBody 注释）；惰性由 List 承担。
    @ViewBuilder
    private var sessionsListStack: some View {
        // v3.3.0：bot 模式已移除，会话列表不再按 bot 分组，直接平铺
        ForEach(sortedSessions) { s in
            sessionCell(s)
                .sessionListRow(vHalfGap: 4)   // 4×2 = 8pt（= 原 LazyVStack(spacing: 8)）
        }
    }

    private var addButton: some View {
        Button {
            // v2.0.58：两步走新建——ChatView 观察到 pendingNewSession 后
            // 先卸载列表再清数据（v2.0.44 的切tab+延迟在过渡期仍崩）
            Haptics.tap()          // v3.4.29：触感补齐
            plusBounceTick += 1
            onOpenSession?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                // v3.4.29：加号 = 等同 /new——本地新建后补发 /new，让 gateway 上下文一起重置
                chat.requestNewSession(sendReset: true)
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: Typography.title, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.bounce, value: plusBounceTick)   // v3.4.29：新建图标弹动
        }
        .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
    }

    // MARK: - v2.0.36 搜索 / 置顶

    /// 置顶优先，收藏次之，其余按最新→最旧（v2.0.60 加收藏）
    private var sortedSessions: [ChatSession] {
        sessions.sorted {
            let a = rank($0.id), b = rank($1.id)
            if a != b { return a > b }
            return ($0.lastTime ?? 0) > ($1.lastTime ?? 0)
        }
    }

    /// v3.4.25：本地实时过滤——匹配标题或任一消息内容（大小写不敏感）；
    /// 复用 sortedSessions 排序（置顶 > 收藏 > 时间），清空搜索词即恢复全量
    private var filteredSessions: [ChatSession] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sortedSessions }
        return sortedSessions.filter { s in
            if s.title.localizedCaseInsensitiveContains(q) { return true }
            return s.messages.contains { $0.content.localizedCaseInsensitiveContains(q) }
        }
    }

    /// v3.9.39：**屏幕上真正渲染出来、能被勾选**的会话——与 sessionsListBody 的分支严格同源
    /// （非搜索态 = sortedSessions；搜索态本地命中 = filteredSessions；本地零命中时的远端命中
    /// 只有能对回本地列表的那批会画成 sessionCell，RemoteHitRow 没有勾选框）。
    /// 多选栏的全选/取消全选必须走这里，不能用 sortedSessions。
    private var visibleSessions: [ChatSession] {
        guard isSearching else { return sortedSessions }
        if !filteredSessions.isEmpty { return filteredSessions }
        return remoteHits.compactMap { localSession(id: $0.id) }
    }

    private var visibleSessionIDs: Set<String> { Set(visibleSessions.map(\.id)) }

    private var allVisibleSelected: Bool {
        let ids = visibleSessionIDs
        return !ids.isEmpty && selectedIds.isSuperset(of: ids)
    }

    // MARK: - v3.9.33 搜索结果区（本地优先 + 远端全史兜底）

    /// 搜索结果区：本地命中（实时、无网络）优先；本地一条都没有时才用远端全史搜索兜底，
    /// 把冷启动缓存（最近 100 会话 × 每会话 50 条消息）之外的旧会话也捞出来。
    @ViewBuilder
    private var searchResultsArea: some View {
        if !filteredSessions.isEmpty {
            // v4.0.21：LazyVStack(spacing: 8) → 直接铺成 List 行（左滑删除要求行落在 List 里，
            // 套一层容器就等于又失效了）；惰性由 List 承担。
            ForEach(filteredSessions) { s in
                sessionCell(s)
                    .sessionListRow(vHalfGap: 4)
            }
        } else {
            if remoteSearching {
                HStack(spacing: Spacing.md) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在搜索全部历史消息…")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)
                .sessionListRow(vHalfGap: 5)
            } else if !remoteHits.isEmpty {
                remoteHitsList
            } else {
                // v3.4.25：无匹配空态 → 统一 EmptyStateView 场景插画
                EmptyStateView(icon: "magnifyingglass",
                               title: "未找到相关会话",
                               subtitle: "标题与全部历史消息都已搜索",
                               iconColors: [.teal, .blue])
                    .padding(.top, 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))   // v3.9.30：空态浮现过渡（配 Motion.emerge）
                    .sessionListRow(vHalfGap: 5)
            }
            // 失败不静默（本仓刚因静默 return 被用户报「功能坏了」）：远端搜索/打开失败留一行小字
            if let note = remoteNoticeText {
                Text(note)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                    .padding(.top, Spacing.sm)
                    .sessionListRow(vHalfGap: 5)
            }
        }
    }

    /// 远端命中列表：会话仍能对上本地列表 → 走普通会话行（同本地搜索结果）；
    /// 只在服务器上的旧会话 → 轻量命中行（标题 + 命中片段），点击后先拉全量列表再进会话。
    private var remoteHitsList: some View {
        // v4.0.21：外层 VStack(alignment:.leading)/LazyVStack 去掉 —— 逐行铺进 List
        // （同上：行不在 List 里，`.swipeActions` 静默失效）
        Group {
            Text("全部历史")
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xs)
                .sessionListRow(vHalfGap: 5)
            ForEach(remoteHits) { hit in
                if let s = localSession(id: hit.id) {
                    sessionCell(s)
                        .sessionListRow(vHalfGap: 4)
                } else {
                    RemoteHitRow(hit: hit) { openRemote(id: hit.id) }
                        .sessionListRow(vHalfGap: 4)
                }
            }
        }
    }

    /// 提示文案：远端搜索失败优先（那是本轮结果不完整的原因）
    private var remoteNoticeText: String? {
        if remoteFailed { return "远端搜索失败，请检查网络（以上仅本地结果）" }
        return remoteNotice
    }

    private func localSession(id: String) -> ChatSession? {
        sessions.first { $0.id == id }
    }

    /// v3.9.33：关键词变化 → 450ms 防抖后请求 `POST /api/sessions/search {q}`
    /// （后端匹配标题 + 全部消息内容）。本地已有命中就不打扰网络（本地优先）；
    /// 防抖写法沿用仓内 StockSearchSheet：`searchTask?.cancel()` + `Task.sleep` + perform。
    private func scheduleRemoteSearch(_ raw: String) {
        remoteSearchTask?.cancel()
        remoteHits = []
        remoteFailed = false
        remoteNotice = nil
        remoteSearching = false
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, filteredSessions.isEmpty else { return }
        remoteSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(450))   // 防抖：连续输入只发最后一次
            if Task.isCancelled { return }
            await performRemoteSearch(q)
        }
    }

    private func performRemoteSearch(_ q: String) async {
        remoteSearching = true
        defer { remoteSearching = false }
        do {
            let j = try await auth.json("/api/sessions/search", method: "POST", body: ["q": q])
            if Task.isCancelled { return }
            remoteHits = (j["results"] as? [[String: Any]] ?? []).compactMap { SessionSearchHit($0) }
            remoteFailed = false
        } catch {
            if Task.isCancelled { return }
            remoteHits = []
            remoteFailed = true   // 失败不静默：空态下方一行小字说明
            print("[sessions] 远端搜索失败：\(error)")
        }
    }

    /// 打开远端命中的会话：本地列表里没有（冷启动缓存只留最近 100 会话）→
    /// 先无节流拉一次全量会话列表，拿到后再进（找不到则如实提示，不装作没事）。
    private func openRemote(id: String) {
        remoteNotice = nil
        if let s = localSession(id: id) {
            open(s)
            return
        }
        Task {
            await load(force: true)
            if let s = localSession(id: id) {
                open(s)
            } else {
                remoteNotice = "该会话已不在服务器（可能已删除）"
            }
        }
    }

    /// 进会话（本地搜索结果行与远端命中行共用同一入口——markRead 只在这里调）
    private func open(_ s: ChatSession) {
        // v3.9.76：这里**不许**再按会话标题做特殊分流。「轻聊投递」（qingliao_delivery）也是
        // 一条普通会话，点它就该进会话内容看投递详情；v3.9.75 曾把它特判成开任务中心，
        // 用户实测直接否掉了（「点进去应该看到投递信息详情，不是跳任务中心」）。
        // 任务中心有自己的常驻入口，在聊天页 header 那一排（见 ChatView showTaskCenter）。
        chat.markRead(s.id, upTo: s.lastTime)   // v4.0.15：带上会话最后消息时间做基线，防时钟差导致角标复亮；v3.9.32：打开会话即已读（此前 markRead 全仓零调用，红点会永久挂着）
        chat.load(s)
        Haptics.tap()         // v3.4.29：进入会话触感
        onOpenSession?()
    }

    /// v4.0.x：**哪个会话算「进行中」**（用户拍板口径：本机这条流没结束就算 —— 切到别的会话看别的行、
    /// App 切后台都照显）。真源 = 流归属会话 `auth.currentStreamSessionId`（StreamClient 启动时写入）。
    /// ⚠️ 它**结束后不清空**（全仓只有 StreamClient 三处赋值，没有复位），所以必须同时判 isStreaming / isDone：
    /// 只看 id 会把「上一次跑过的那个会话」永久标成进行中。
    /// v4.1.x 多会话并行：后台跑流器里在跑的会话集合（多个可同时「进行中」）
    private var backgroundRunningIDs: Set<String> {
        Set(BackgroundStreamRunner.shared.running.keys)
    }

    /// ⚠️ 2026-09-30（发布前审查拦下）：它原先写成 `runningSessionID: String?` 计算属性，却引用了
    /// sessionCell 的形参 `s`（属 SessionsView 层，无 `s` 成员）→ `cannot find 's' in scope`：
    /// `swiftc -parse` 盲区，只有 CI Archive 才炸。改成按会话判定的方法。
    private func isRunning(_ s: ChatSession) -> Bool {
        isForegroundRunning(s) || isBackgroundRunning(s)
    }

    /// v4.0.20（#8）：把「进行中」拆成两态 —— 前台流（你正在看的这条）与
    /// **后台跑流**（退出聊天页 / 切别的会话也在推进）。原先合并成一枚呼吸点，
    /// 用户读不出「是我在问，还是后台自己在跑」。
    private func isForegroundRunning(_ s: ChatSession) -> Bool {
        guard stream.isStreaming, !stream.isDone else { return false }
        return auth.currentStreamSessionId == s.id
    }

    private func isBackgroundRunning(_ s: ChatSession) -> Bool {
        backgroundRunningIDs.contains(s.id)
    }

    /// v4.0.20（#4）：固定会话（轻聊投递 / 轻聊主动）恒置顶 —— 它们是后端锁定 id 的功能壳，
    /// 掉到列表中间等于把「cron 详情」和「AI 主动开口」埋起来。
    private func isFixedSession(_ id: String) -> Bool {
        id == ChatStore.deliverySessionId || id == ChatStore.proactiveSessionId
    }

    /// v3.0.51：会话 cell（SessionRow + 长按菜单）——拆辅助函数，防嵌套 ForEach type-check 超时
    @ViewBuilder
    private func sessionCell(_ s: ChatSession) -> some View {
        SessionRow(session: s,
                   pinned: pinnedIDs.contains(s.id),
                   faved: favIDs.contains(s.id),
                   tags: tagStore.tags(for: s.id),
                   showCheck: editing,
                   checked: selectedIds.contains(s.id),
                   unread: chat.unread[s.id] ?? 0,
                   categoryName: categoryStore.categoryForSession(s.id)?.name,
                   running: isRunning(s),
                   runningForeground: isForegroundRunning(s),
                   runningBackground: isBackgroundRunning(s),
                   isFixed: isFixedSession(s.id)) {
            if editing {
                toggleSelect(s.id)
            } else {
                open(s)   // v3.9.33：进会话统一入口（含 v3.9.32 markRead）——远端命中行复用同一路径
            }
        }
        // v3.4.29：滚动层次感——行进出视口时轻微缩放 + 淡出（须在 LazyVStack 内）
        // v3.9.0：改为统一修饰器 .scrollDepth()（数值与看板/生活卡片同源）
        .scrollDepth()
        .contextMenu {
            // v4.0.20（#4）：固定会话恒置顶（rank 写死 3）→ 不给「置顶/取消置顶」，
            // 免得用户点了没反应（或以为置顶失效）
            if !isFixedSession(s.id) {
                Button {
                    togglePin(s)
                } label: {
                    Label(pinnedIDs.contains(s.id) ? "取消置顶" : "置顶", systemImage: pinnedIDs.contains(s.id) ? "pin.slash" : "pin")
                }
            }
            Button {
                toggleFav(s)
            } label: {
                Label(favIDs.contains(s.id) ? "取消收藏" : "收藏", systemImage: favIDs.contains(s.id) ? "star.slash" : "star")
            }
            // v4.0.x：固定会话（投递壳 / 轻聊主动）标题锁定 → 不给「重命名」入口。
            // 后端只锁自动命名（SessionAutoName 闸门），用户手动改名是另一条路，
            // 不护住就会把「轻聊投递」「轻聊主动」改名成别的，固定会话就找不到了。
            if s.id != ChatStore.deliverySessionId && s.id != ChatStore.proactiveSessionId {
                Button {
                    renameTarget = s
                    renameText = s.title
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
            }
            Menu("移动到…") {
                Button("无分类") {
                    categoryStore.assignSession(s.id, to: nil)
                }
                ForEach(categoryStore.categories) { cat in
                    Button {
                        categoryStore.assignSession(s.id, to: cat.id)
                    } label: {
                        Label(cat.name, systemImage: cat.icon)
                    }
                }
                Divider()
                Button("新建分类…") {
                    addCategoryForSession = s.id
                    newCategoryName = ""
                    showAddCategory = true
                }
                // v3.9.32：能建也得能删（此前 removeCategory 零调用 = 分类只进不出）
                if !categoryStore.categories.isEmpty {
                    Menu("删除分类") {
                        ForEach(categoryStore.categories) { cat in
                            Button(role: .destructive) {
                                deleteCategoryTarget = cat
                            } label: {
                                Label(cat.name, systemImage: "trash")
                            }
                        }
                    }
                }
            }
            Menu("标签") {
                ForEach(tagStore.allTags, id: \.self) { t in
                    Button {
                        tagStore.toggle(t, on: s.id)
                    } label: {
                        let has = tagStore.tags(for: s.id).contains(t)
                        Label(has ? "\(t)  ✓" : t, systemImage: has ? "checkmark.circle.fill" : "circle")
                    }
                }
                Divider()
                Button {
                    tagTarget = s
                    newTagName = ""
                    showNewTag = true
                } label: {
                    Label("新建标签", systemImage: "plus")
                }
            }
            // v4.1.x：清空会话内容（清消息、留会话与标题）——放在「删除会话」之前，
            // 两项都是 destructive，删除仍排最后（视觉与操作风险递增）。
            // v4.0.18：固定会话（投递壳 / 轻聊主动）**也给入口**（用户拍板：这两个会话也要能清；
            // 删除仍不给——后端 _PROTECTED_IDS 拒删，入口必须可用）。
            Button(role: .destructive) {
                confirmClear = s
            } label: {
                Label("清空会话内容", systemImage: "eraser")
            }
            // v4.0.x：固定会话（投递壳 / 轻聊主动）不可删除 → 直接不给「删除会话」这个入口，
            // 而不是给一个点了会报错的按钮（所有可见 UI 入口都必须可用）。
            if s.id != ChatStore.deliverySessionId && s.id != ChatStore.proactiveSessionId {
                Button(role: .destructive) {
                    confirmDelete = s
                } label: {
                    Label("删除会话", systemImage: "trash")
                }
            }
        }
        // v4.1.x：单条左滑删除（trailing 边；滑到底 = allowsFullSwipe 默认 true → 直接触发）。
        // 与长按菜单**同一套删链**，不另写存储写逻辑：这里只把 confirmDelete 置上，
        // 由既有「删除会话」确认弹窗（二次确认）→ delete(_:)（内含 flushPendingWrites
        // 写链闸门 + merge 的 deleted 键）收尾，防「删了又活着回来」。
        // 固定会话（投递壳 / 轻聊主动）与长按菜单同一口径：**不给入口**
        // （后端 _PROTECTED_IDS 拒删，给了就是「点了会报错的按钮」）。
        .swipeActions(edge: .trailing) {
            if s.id != ChatStore.deliverySessionId && s.id != ChatStore.proactiveSessionId {
                Button(role: .destructive) {
                    confirmDelete = s
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private func rank(_ id: String) -> Int {
        if isFixedSession(id) { return 3 }   // v4.0.20（#4）：固定会话恒置顶，用户手动置顶的排它之下
        if pinnedIDs.contains(id) { return 2 }
        if favIDs.contains(id) { return 1 }
        return 0
    }

    private func toggleFav(_ s: ChatSession) {
        if favIDs.contains(s.id) {
            favIDs.remove(s.id)
        } else {
            favIDs.insert(s.id)
        }
        UserDefaults.standard.set(Array(favIDs), forKey: "qingliao_fav_sessions")
    }

    private func togglePin(_ s: ChatSession) {
        if pinnedIDs.contains(s.id) {
            pinnedIDs.remove(s.id)
        } else {
            pinnedIDs.insert(s.id)
        }
        UserDefaults.standard.set(Array(pinnedIDs), forKey: "qingliao_pinned_sessions")
    }

    /// v2.0.43：重命名会话（本地列表 + 当前打开会话 + 后端 merge 同步）
    ///
    /// v3.9.39 数据损毁修复：
    /// ① 删掉重复的第一次 merge。v3.9.32 补字段时是**追加**了新请求而没有替换旧的，
    ///    于是改名会连发两次整会话覆盖写；而后端 merge 对同 id 会话是整体覆盖
    ///    （App 不发 updatedAt → 恒 `0 >= 0` → incoming 全量替换），
    ///    第一次那请求只带 role/content/timestamp/isPush/agent，图片/uid/引用原文当场被抹掉。
    /// ② 序列化统一走 ChatStore.messagesPayload（原先三份互相漂移的副本都漏了 audioPath → [语音]）。
    /// ③ 只同步**完整**的消息集：优先当前打开会话的内存 messages（列表项是上一次 /list 的快照，可能已少几条）；
    ///    列表仍来自冷启动缓存时不同步——缓存每会话截断 50 条，覆盖上去等于永久截断真实历史。
    /// ④ 失败回滚本地标题并提示。原 `try?` 静默吞失败：界面显示已改名，下次拉取又跳回旧名。
    private func rename() {
        guard let t = renameTarget else { return }
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        renameTarget = nil
        let oldTitle = t.title
        applyTitle(newName, to: t.id)

        // 待同步的消息集：当前打开会话以内存为准，其余用列表项
        let usingLiveChat = chat.sessionId == t.id && !chat.messages.isEmpty
        let msgs = usingLiveChat ? chat.messages : t.messages
        guard !msgs.isEmpty else { return }
        guard usingLiveChat || sessionsFromNetwork else {
            renameError = "会话列表还没从服务器加载到完整内容（本机缓存每会话只留最近 50 条），已暂停同步改名以免截断历史。请联网刷新列表后重新改名。"
            return
        }
        // 序列化在 Task 内做，但只往闭包里带 Sendable 值（t / msgs），字典不进捕获列表
        Task {
            do {
                // v4.0.15：直发 merge 之前先排空在途写链（与 clearContent 同一闸门）。
                // 否则链里压着的旧快照写会在改名写之后落地，把新标题整会话盖回旧名。
                await chat.flushPendingWrites()
                let j = try await auth.json("/api/sessions/merge", method: "POST", body: [
                    "sessions": [["id": t.id, "title": newName,
                                  "messages": ChatStore.messagesPayload(msgs)] as [String: Any]],
                    "deleted": [] as [Any]
                ])
                if (j["ok"] as? Bool) != true {
                    applyTitle(oldTitle, to: t.id)
                    renameError = "改名未同步到服务器（服务器返回异常），请检查网络后重试"
                }
            } catch {
                applyTitle(oldTitle, to: t.id)
                renameError = "改名未同步到服务器：\(error.localizedDescription)"
            }
        }
    }

    /// 改名落地：列表项 + 当前打开会话的标题同步（回滚也走同一处，口径一致）
    private func applyTitle(_ title: String, to id: String) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            var updated = sessions[idx]
            updated.title = title
            sessions[idx] = updated
        }
        if chat.sessionId == id {
            chat.title = title
        }
    }

    // MARK: - 数据

    /// - Parameter force: true = 跳过 3 秒节流（v3.9.33：远端命中要打开缓存外的旧会话时用）
    private func load(force: Bool = false) async {
        // 3 秒内不重复加载（快速滑动切 Tab 时避免 isLoading 翻转蹭卡）
        if !force, let last = lastLoadAt, Date().timeIntervalSince(last) < 3 { return }
        isLoading = true
        errorText = nil
        lastLoadAt = Date()
        // v3.4.x：冷启动缓存先显——联网前先读本地缓存会话列表（上次成功拉取的快照），
        // 秒显不白屏；联网成功后再刷新覆盖。UI 已有 `isLoading && sessions.isEmpty` 判空才转圈，
        // 因此先填缓存（sessions 非空）不会触发 loading 占位，直接展示列表。
        loadFromSessionCache()
        do {
            let j = try await auth.json("/api/sessions/list")
            let raw = (j["sessions"] as? [Any] ?? [])
            // 最新 → 最旧
            sessions = raw.compactMap { ChatSession.parse($0 as? [String: Any] ?? [:]) }
                .sorted { ($0.lastTime ?? 0) > ($1.lastTime ?? 0) }
            sessionsFromNetwork = true
            // v3.4.x：联网成功写缓存（下次冷启动秒显）
            saveToSessionCache(raw)
            // v2.0.65：同步未读红点
            chat.syncUnread(from: sessions, currentId: chat.sessionId)
        } catch {
            errorText = "加载失败，请检查连接"
        }
        isLoading = false
    }

    // MARK: - v3.4.x 会话列表冷启动缓存（秒显 + 限容防 4MB 超限）

    private static let sessionCacheKey = "qingliao_sessions_cache"

    /// 读本地缓存：从上次成功拉取的原始 JSON 还原会话列表。
    /// 失败/无缓存一律静默返回，不影响正常联网加载。（v3.9.28：云端模式已移除）
    private func loadFromSessionCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.sessionCacheKey),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return }
        sessions = raw.compactMap { ChatSession.parse($0 as? [String: Any] ?? [:]) }
            .sorted { ($0.lastTime ?? 0) > ($1.lastTime ?? 0) }
        // v3.9.39：缓存每会话只留最近 50 条，而 merge 是整会话覆盖 → 标记列表非完整远端数据，
        // 改名等写路径据此暂不上传（无缓存时不走到这里，保留上一次网络结果的 true）。
        sessionsFromNetwork = false
        chat.syncUnread(from: sessions, currentId: chat.sessionId)
    }

    /// 写缓存：限制最近 100 个会话、每个会话消息截断最近 50 条，控制 UserDefaults 体积。
    private func saveToSessionCache(_ raw: [Any]) {
        let limited: [Any] = Array(raw.prefix(100)).map { s -> Any in
            guard var d = s as? [String: Any] else { return s }
            if var msgs = d["messages"] as? [Any], msgs.count > 50 {
                d["messages"] = Array(msgs.suffix(50))
            }
            return d
        }
        if let data = try? JSONSerialization.data(withJSONObject: limited) {
            UserDefaults.standard.set(data, forKey: Self.sessionCacheKey)
        }
    }

    // v2.0.87ad：多选切换 / 批量删除
    private func toggleSelect(_ id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    private func deleteSelected() {
        // v4.0.x：批量删除要把两个固定会话过滤掉（同 delete() 的理由）。
        // 否则整批请求被后端 _PROTECTED_IDS 部分拒绝 → deleted 数对不上 → 走失败分支。
        let fixed: Set<String> = [ChatStore.deliverySessionId, ChatStore.proactiveSessionId]
        let ids = Array(selectedIds).filter { !fixed.contains($0) }
        guard !ids.isEmpty else {
            editing = false
            selectedIds.removeAll()
            deleteError = "固定会话不能删除"
            return
        }
        let idsCopy = ids
        selectedIds.removeAll()
        editing = false
        Task {
            do {
                // v4.0.15：删之前排空在途写链 —— 否则压着的旧快照写会在删除写之后落地，
                // 把刚删掉的会话整会话 merge 回来（用户报「删了又活着回来」）。
                await chat.flushPendingWrites()
                let j = try await auth.json("/api/sessions/merge", method: "POST", body: [
                    "sessions": [] as [Any], "deleted": idsCopy
                ])
                if (j["ok"] as? Bool) == true {
                    await load()
                    // v3.9.39：删掉的这批里含**当前正打开**的会话 → 走单条删除同一套两步新建。
                    // 少这一步 = chat 内存里仍留着该会话和全部消息，下一次 saveToServer 把它整体
                    // merge 回服务器，用户看到「删了又活着回来」。
                    if idsCopy.contains(chat.sessionId) {
                        onOpenSession?()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            chat.requestNewSession()
                        }
                    }
                } else {
                    // v2.0.102：失败恢复选择与编辑态（原清空后失败无恢复）
                    selectedIds = Set(idsCopy)
                    editing = true
                    // v3.9.39：原来写 errorText，而它只在 sessions 为空时才渲染（删除后列表必然非空）
                    // → 失败完全静默。改走 deleteError，与单条删除同一口径。
                    deleteError = "删除未同步到服务器（服务器返回异常），请检查网络后重试"
                }
            } catch {
                // v2.0.102：失败恢复选择与编辑态
                selectedIds = Set(idsCopy)
                editing = true
                deleteError = "删除未同步到服务器：\(error.localizedDescription)"
            }
        }
    }

    /// v4.1.x：清空会话内容（清消息、**保留会话本身与标题**）
    ///
    /// 与「删除会话」/「改名」的本质差别（一句话说清为什么可以更简单）：
    /// 两者都要把**完整消息集**原样发回后端（整会话覆盖），所以必须防「拿截断快照去写」；
    /// 清空发的是**空数组**，后端 merge 对同 id 直接采用 incoming
    /// （sessions_api.merge_sessions：`incoming 带 messages（含空数组）→ 采用`），
    /// 空数组无论来自完整数据还是 50 条缓存，落到线上的结果都是「没有消息」——
    /// **不存在截断风险**，因此不需要 rename() 那道 sessionsFromNetwork 闸门。
    /// 反过来说：这道闸门若照抄过来，只会让冷启动缓存的用户永远清不掉（点了没反应）。
    ///
    /// 不传 updatedAt：App 恒发 0，后端条件是 `incoming >= cur`，恒成立 → 覆盖生效。
    private func clearContent(_ s: ChatSession) {
        // v4.0.18：固定会话（投递壳 / 轻聊主动）**允许**清空（用户拍板：这两个会话也要能清）。
        // 后端配套：投递壳走 _CLIENT_WINS_IDS（内容以客户端为准，v3.9.72）；
        // 主动会话由 merge_sessions 空数组特判采纳（显式清空意图，非空快照仍以 NAS 为准）。
        // 该会话有后台流在跑 → 先撤：跑完的答案会把刚清空的会话又写满。
        BackgroundStreamRunner.shared.cancelForDeletedSession(sessionId: s.id, auth: auth)
        let sid = s.id
        let ttl = s.title
        let isCurrent = chat.sessionId == sid
        Task {
            // ① 先写服务器：会话与标题都带上，只把 messages 换成空数组。
            //    放在切 tab 之前——请求慢也不该让用户对着旧界面等。
            // ② 失败必须提示：merge 返回 ok=true 后服务器仍可能拒收（如固定会话），
            //    静默 return 会让用户以为清空了，刷新后内容原样回来。
            var synced = false
            do {
                // v4.0.15：发空写之前先把链排空 —— 否则在途旧快照写会在空写之后落地，
                // 把刚清掉的消息整会话盖回来（用户报「清空了又全回来」）。
                await chat.flushPendingWrites()
                let j = try await auth.json("/api/sessions/merge", method: "POST", body: [
                    "sessions": [["id": sid, "title": ttl, "messages": [Any]()] as [String: Any]],
                    "deleted": [] as [Any]
                ])
                synced = (j["ok"] as? Bool) == true
                if !synced { clearError = "清空未同步到服务器（服务器返回异常），请联网后重试" }
            } catch {
                clearError = "清空未同步到服务器：\(error.localizedDescription)"
            }
            guard synced else { await load(); return }

            await MainActor.run { Haptics.success() }
            // ③ 正在看的就是它 → 内存也得清，否则**下一次任何 saveToServer** 会把内存里的
            //    旧消息整会话写回去（用户看到「清空了又全回来」）。
            //    顺序＝先让聊天页可见、完成转场，再清数据：隐藏的 TabView 页与数据清空
            //    同帧是本仓历史崩溃组合（README「列表崩溃三连排查」②，v2.0.44/2.0.54/2.0.56）。
            //    与 delete() 的「删当前会话」同一套路（那边换成 requestNewSession）。
            if isCurrent {
                onOpenSession?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(nil) { chat.clearMessages() }
                }
            }
            await load()
        }
    }

    private func delete(_ s: ChatSession) {
        // v4.0.x：固定会话（投递壳 / 轻聊主动）不可删除 —— 后端 _PROTECTED_IDS 会拒绝，
        // 这里先拦在前端，不让用户点完才看到一个失败的报错。
        if s.id == ChatStore.deliverySessionId || s.id == ChatStore.proactiveSessionId {
            deleteError = "「\(s.title)」是固定会话，不能删除"
            return
        }
        // v4.1.x 多会话并行：该会话若有后台流在跑 → 撤轮询 + 停服务端任务（不往已删会话写库）
        BackgroundStreamRunner.shared.cancelForDeletedSession(sessionId: s.id, auth: auth)
        // v2.0.57：三保险——①contextMenu 关闭瞬间不改数据（先弹确认再删）
        // ②后端删除成功才 load() 整体刷新（不就地改 sessions）
        // ③删当前会话：切聊天 tab 后在屏 newSession（v2.0.44 已验证路径），
        //    不再隐藏页清空（v2.0.54/56 的延迟只是推迟崩溃，隐藏页清空才是 SIGTRAP 根因）
        let deletingId = s.id
        Task {
            do {
                // v4.0.15：删之前排空在途写链（同上，防「删了又活着回来」）。
                await chat.flushPendingWrites()
                let j = try await auth.json("/api/sessions/merge", method: "POST", body: [
                    "sessions": [] as [Any],
                    "deleted": [s.id]
                ])
                let ok = (j["ok"] as? Bool) == true
                let deletedCount = (j["deleted"] as? Int) ?? -1
                if ok && deletedCount >= 0 {
                    await MainActor.run { Haptics.success() }   // v3.4.29：删除结果触感
                    await load()
                    if chat.sessionId == deletingId {
                        // v2.0.58：两步走新建（切 tab + requestNewSession，ChatView 先卸载列表再清数据）
                        onOpenSession?()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            chat.requestNewSession()
                        }
                    }
                } else {
                    deleteError = "删除未同步到服务器（服务器返回异常），请检查网络后重试"
                    await load()
                }
            } catch {
                deleteError = "删除未同步到服务器：\(error.localizedDescription)"
                await load()
            }
        }
    }

}

// MARK: - 机器人卡

struct BotCard: View {
    @Environment(AuthStore.self) private var auth
    @State private var online: Bool?
    // v2.0.50：模型/提供商动态读取（设置切换后实时刷新）
    @AppStorage("qingliao_model") private var modelName = "deepseek-v4-flash"
    @AppStorage("qingliao_provider") private var provider = "opencode"
    // 当前模型显示
    // v3.0.20：Agent 模型自定义——配置了独立模型时显示 agent 模型（v3.4.12：开关已移除，恒开启）
    private var displayModel: String {
        // v3.4.12：Agent 开关已移除（后端恒走 Hermes agent），配置了独立模型即显示
        let agentModel = UserDefaults.standard.string(forKey: UserDefaultsKey.agentModel) ?? ""
        if !agentModel.isEmpty {
            return "\(provider)/\(agentModel)"
        }
        return "\(provider)/\(modelName)"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "brain.head.profile")
                    .font(.system(size: Typography.title, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("轻聊 agent")
                    .font(.system(size: Typography.body, weight: .semibold))
                // v2.0.50：模型名动态显示（之前硬编码，设置切模型不刷新）
                Text(displayModel)
                    .font(.system(size: Typography.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(online == true ? Color.green : (online == false ? Color.red : Color.gray))
                    .frame(width: 6, height: 6)
                Text(online == true ? "在线" : (online == false ? "离线" : "检测中"))
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(online == true ? Color.green : (online == false ? Color.red : Color.secondary))
            }
        }
        .padding(Spacing.xl)
        .background(
            LinearGradient(colors: [Color.blue.opacity(Tint.subtle), Color.indigo.opacity(Tint.faint)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.blue.opacity(Tint.strong), lineWidth: 0.8)
        )
        .task {
            // 真实连接状态
            let r = await auth.testConnection(server: auth.serverURL)
            online = r.hasPrefix("✅")
        }
    }
}

// MARK: - 会话行

struct SessionRow: View {
    let session: ChatSession
    var pinned: Bool = false
    var faved: Bool = false   // v2.0.60 收藏
    var tags: [String] = []   // v3.0.51 B7：会话标签
    var showCheck = false   // v2.0.87ad：多选模式
    var checked = false
    var unread = 0          // v3.9.85：未读**条数**（原 Bool 红点，改实心红色数字角标，对标微信）
    var categoryName: String? = nil   // v3.9.32：所属分类（长按「移动到…」设过才显示）
    /// v4.0.x：该会话本机正在生成（流在跑且流归属就是它）——真源与口径见 SessionsView.isRunning(_:)
    var running = false
    /// v4.0.20（#8）：进行中来源两态 —— 前台流（你正在看的这条）/ 后台跑流（退出聊天页也在推进）。
    /// 原先共用一枚呼吸点，用户读不出「是我在问，还是后台自己在跑」。
    var runningForeground = false
    var runningBackground = false
    /// v4.0.20（#4）：固定会话（轻聊投递 / 轻聊主动）——恒置顶 + 锁形图标 + 用途胶囊
    var isFixed = false
    var action: () -> Void = {}

    /// v4.0.20（#4）：固定会话用途一句话 —— 「轻聊投递」只装 cron/system 详情、
    /// 「轻聊主动」是 AI 主动开口且可回复（后端两个固定会话语义不同，用户在列表里看不出）
    private var fixedSessionHint: String? {
        guard isFixed else { return nil }
        return session.id == ChatStore.deliverySessionId ? "只装不答" : "可回复"
    }

    // MARK: - v3.4.25 会话头像个性化（id hash → 稳定的色系×图标组合）

    /// 8 组柔和渐变色系（深浅色都保证白图标可读：主色 0.75 + 辅色 0.55 透明度）
    private var avatarColors: [Color] {
        let palettes: [[Color]] = [
            [.blue, .indigo], [.orange, .pink], [.green, .mint], [.purple, .indigo],
            [.cyan, .blue], [.pink, .red], [.yellow, .orange], [.teal, .green]
        ]
        let idx = abs(avatarHash) % palettes.count
        return [palettes[idx][0].opacity(0.75), palettes[idx][1].opacity(0.55)]
    }

    /// 6 个语义图标（纯视觉映射，非关键词解析——hash 稳定即可）
    private var avatarIcon: String {
        let icons = ["bubble.left.fill", "text.bubble.fill", "chevron.left.forwardslash.chevron.right",
                     "sparkles", "lightbulb.fill", "book.fill"]
        return icons[abs(avatarHash >> 3) % icons.count]
    }

    private var avatarHash: Int {
        var h = 0
        for b in session.id.utf8 { h = (h &* 31 &+ Int(b)) & 0xFFFFFFF }
        return h
    }

    var body: some View {
        HStack(spacing: 12) {
            // v3.4.25：会话头像个性化——按会话 id hash 稳定映射到 8 色系 × 6 图标组合，
            // 不同类型会话一眼可辨（微信式视觉锚点）；hash 稳定 = 同一会话永远同一头像
            ZStack {
                RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                    .fill(LinearGradient(colors: avatarColors,
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: avatarIcon)
                    .font(.system(size: Typography.body, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.xs) {
                    // v4.0.20（#4）：固定会话锁形图标 —— 一眼看出「这是系统会话，删不掉、改不了名」
                    if isFixed {
                        Image(systemName: "lock.fill")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("固定会话")
                    }
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(Color.orange)
                    }
                    // v2.0.60：收藏星标
                    if faved {
                        Image(systemName: "star.fill")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(Color.yellow)
                    }
                    Text(session.title.isEmpty ? "新对话" : session.title)
                        .font(.system(size: Typography.body, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    // v4.0.20（#4）：固定会话用途胶囊 —— 两个常驻置顶的会话原来不说自己是干嘛的
                    if let hint = fixedSessionHint {
                        Text(hint)
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(Tint.soft), in: Capsule())
                            .lineLimit(1)
                    }
                    // v3.9.32：分类小胶囊（此前分类只在长按菜单里能设，设完看不见）
                    if let cat = categoryName, !cat.isEmpty {
                        Text(cat)
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(Tint.soft), in: Capsule())
                            .lineLimit(1)
                    }
                }
                // v3.0.51 B7：会话标签小胶囊（彩色，最多 3 个）
                                if !tags.isEmpty {
                                    SessionTagCapsules(tags: tags)
                                        .padding(.top, Spacing.xxs)
                                }
                                Text(session.lastMessageText)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                // v3.9.85：实心红色数字角标（原 v3.9.32 红点）——对标微信：≥100 显示 99+
                if unread > 0 && !showCheck {
                    Text(unread >= 100 ? "99+" : "\(unread)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Capsule().fill(Color.red))
                        .accessibilityLabel("\(unread) 条未读消息")
                }
                // v2.0.87ad：多选勾选圈（编辑模式替代 chevron）
                if showCheck {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: Typography.headline))
                        .foregroundStyle(checked ? Color.accentColor : Color.secondary.opacity(0.4))
                } else if runningForeground {
                    // v4.0.20（#8）：前台流 = 你正在看的这条 → 蓝点呼吸（原形态）
                    RunningDot()
                } else if runningBackground {
                    // v4.0.20（#8）：后台跑流 = 退出聊天页也在推进 → 灰点 + 「后台」小字。
                    // 原先两者共用一枚蓝点，用户读不出「谁在跑」——这正是本次要修的病灶。
                    HStack(spacing: 3) {
                        Circle().fill(Color.secondary.opacity(0.65)).frame(width: 7, height: 7)
                        Text("后台")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("后台正在推进")
                } else if running {
                    // 兜底：调用方只给了 running（未拆两态）时保持旧观感
                    RunningDot()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: Typography.caption, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                // v3.9.88（用户拍板）：时间移到 chevron 下面 —— 右列自上而下读作
                // 「未读数 → 进入箭头 → 时间」，时间跟着「>」这条视觉轴，不再飘在卡片最上方。
                Text(session.relativeTime)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        // v4.0.0（用户拍板）：会话卡玻璃化，**复用 dashboardCard()** ——
        //   与意图动作卡 / 门锁卡完全同档（.glassEffect(.regular) + 白亮边 0.12/0.22 + 柔影 10/4，
        //   圆角 16）。不新增第三套玻璃样式。
        //
        // ⚠️ 关键（v4.0.0 踩过的坑 F2）：**不要**写成
        //     `.background(折射源).background(玻璃)` 两层 —— SwiftUI 里先挂的 background 画得更靠前，
        //     不透明底色会把玻璃完全压死，页面观感与实色无差别。
        //   dashboardCard() 内部是「内容 + 玻璃 + 描边 + 影」单链，玻璃在内容之下、内容之上无遮挡，
        //   不存在这个次序问题，故直接套用即可。
        .dashboardCard(cornerRadius: Radius.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contentShape(Rectangle())
        // 用 tap 手势而非 Button 包裹（Button 会与 swipeActions 滑动手势冲突，导致滑动删除失效）
        .onTapGesture { action() }
    }
}

// MARK: - v4.0.x 会话「进行中」标识（用户 2026-09-27 拍板：位置=替换右列箭头，形态=呼吸脉冲圆点）
//
// 语义：**只有本机这条流没结束**才出现（切到别的会话、App 切后台都算；App 被杀/重启不还原 ——
//   服务端没有「会话运行中」字段，本机 StreamClient 是唯一真源，见 SessionsView.isRunning(_:)）。
// 动效：opacity 循环（GPU 合成、无每帧布局，同 SkeletonBlock）；开了「减弱动态效果」即静止常亮。
private struct RunningDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 9, height: 9)
            .opacity(reduceMotion ? 1 : (dim ? 0.35 : 1))
            .frame(width: Typography.caption, height: Typography.caption)   // 占位与 chevron 同宽，行高不跳
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                       value: dim)
            .onAppear { if !reduceMotion { dim = true } }
            // v4.1.x 发布前同族审查（2026-09-30）：列表行被滚动回收时 @State 停在 true，
            // 再出现没有 false→true 边沿 = 呼吸动画消失（本仓「动画概率消失」的同族第 2 处）。
            .onDisappear { dim = false }
            .accessibilityLabel("正在生成回复")
    }
}


// v3.0.51 B7：会话标签胶囊行（独立小结构，减轻 SessionRow body type-check 负担）
private struct SessionTagCapsules: View {
    let tags: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { t in
                Text(t)
                    .font(.system(size: Typography.tiny, weight: .semibold))
                    .foregroundStyle(tagColor(t))
                    .lineLimit(1)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .background(tagColor(t).opacity(Tint.subtle), in: Capsule())
            }
        }
    }
}

// MARK: - v3.9.33 远端全史搜索（POST /api/sessions/search）
//
// 后端契约（NAS sessions_api.py，2026-09-17 只读核实；需鉴权 → 401 走 AuthStore 统一收敛点）：
//   POST /api/sessions/search {"q":"…"}
//     → {"ok":true,"results":[{"id","title","lastTime",
//          "hits":[{"role","snippet","content"}],"hitCount"}],"total":N}
//   后端匹配「标题 + 每条消息 content」；hits 最多 3 条，snippet 已截好上下文并带省略号。
// 拆成独立 struct（不在 SessionsView 里内联）：命中行与解析各一处，减轻 ViewBuilder 类型推断负担。

private struct SessionSearchHit: Identifiable {
    let id: String
    let title: String
    let role: String?
    let snippet: String?
    let hitCount: Int
    let lastTime: TimeInterval?

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        self.title = d["title"] as? String ?? ""
        let hits = d["hits"] as? [[String: Any]] ?? []
        var role: String?
        var snippet: String?
        if let h0 = hits.first {
            role = h0["role"] as? String
            let s = h0["snippet"] as? String ?? ""
            if !s.isEmpty { snippet = s }
        }
        self.role = role
        self.snippet = snippet
        self.hitCount = d["hitCount"] as? Int ?? hits.count
        self.lastTime = d["lastTime"] as? TimeInterval
    }

    /// 命中来源前缀（让用户一眼看出命中的是提问还是回答）
    var snippetText: String {
        guard let snippet, !snippet.isEmpty else { return "" }
        return "\(role == "user" ? "我" : "AI")：\(snippet)"
    }

    /// 命中时间（后端 lastTime 与会话同源：毫秒时间戳；兼容秒，避免旧数据算成 1970 年）
    var relativeText: String {
        guard let ts = lastTime, ts > 0 else { return "" }
        let secs = ts > 100_000_000_000 ? ts / 1000 : ts
        let diff = Date().timeIntervalSince1970 - secs
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60)) 分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600)) 小时前" }
        if diff < 86400 * 30 { return "\(Int(diff / 86400)) 天前" }
        return "\(max(1, Int(diff / (86400 * 30)))) 个月前"
    }
}

/// 远端命中但本地列表里没有的会话行（冷启动缓存只留最近 100 会话）。
/// 点击 → 先拉全量列表再进会话；样式与 SessionRow 同一套令牌/描边，避免两张皮。
private struct RemoteHitRow: View {
    let hit: SessionSearchHit
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xl) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                    .fill(Color.accentColor.opacity(Tint.soft))
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.xs) {
                    Text(hit.title.isEmpty ? "新对话" : hit.title)
                        .font(.system(size: Typography.body, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    // 命中多处时给个胶囊（与 SessionRow 的分类胶囊同一套令牌）
                    if hit.hitCount > 1 {
                        Text("\(hit.hitCount) 处命中")
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xxs)
                            .background(Color.accentColor.opacity(Tint.soft), in: Capsule())
                            .lineLimit(1)
                    }
                }
                if !hit.snippetText.isEmpty {
                    Text(hit.snippetText)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Spacing.md)
            VStack(alignment: .trailing, spacing: 4) {
                Text(hit.relativeText)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        // v4.0.0：搜索命中行同样属会话列表的卡，与 SessionRow 走同一档玻璃（口径单源）。
        .dashboardCard(cornerRadius: Radius.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contentShape(Rectangle())
        // 与 SessionRow 一致用 tap 手势（Button 会与 swipeActions 冲突）
        .onTapGesture { onTap() }
    }
}

// MARK: - v4.0.21 会话列表改 List 后的「行样式抹平」

/// 逐行抹平 List 自带样式（系统分隔线 / 系统行底 / 行内边距），让每一行看起来仍是一张独立卡片。
///
/// `vHalfGap` = 单侧垂直留白，**相邻两行相贴 = 2×vHalfGap**：
///   · 会话行 4 → 8pt（与改造前 `LazyVStack(spacing: 8)` 同值）
///   · 非会话行 5 → 10pt（与改造前外层 `LazyVStack(spacing: 10)` 同值）
/// 左右取 `Spacing.xxl`(=14)，与改造前外层 `.padding(.horizontal, Spacing.xxl)` 同值。
/// 这三条是「换 List 但观感不变」的全部代价所在，收在此处单源，别在各调用点手写。
private struct SessionListRowChrome: ViewModifier {
    let vHalfGap: CGFloat

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: vHalfGap,
                                      leading: Spacing.xxl,
                                      bottom: vHalfGap,
                                      trailing: Spacing.xxl))
            .listRowSeparator(.hidden)          // 卡片自带玻璃底与描边，系统分隔线是多余的
            .listRowBackground(Color.clear)     // 不留系统行底，否则卡片后多一层底色
    }
}

private extension View {
    /// 会话列表的 List 行样式（口径单源，实现见 SessionListRowChrome）
    func sessionListRow(vHalfGap: CGFloat) -> some View {
        modifier(SessionListRowChrome(vHalfGap: vHalfGap))
    }
}
