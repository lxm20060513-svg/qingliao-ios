import SwiftUI

// MARK: - 会话页（真实会话列表 + 滑动删除 + 点击进入聊天）

struct SessionsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(ChatStore.self) private var chat
    @Environment(CategoryStore.self) private var categoryStore   // v3.0.27：会话分类
    @Environment(SessionTagStore.self) private var tagStore     // v3.0.51 B7：会话标签

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
    // v2.0.57：删除确认（contextMenu 关闭瞬间不改数据）
    @State private var confirmDelete: ChatSession?
    // v2.0.87ad：多选删除
    @State private var editing = false
    @State private var selectedIds = Set<String>()
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
            if isLoading && sessions.isEmpty {
                // v3.9.0：首屏加载改骨架屏（比转圈更能预示"内容马上出现在这里"，且不白屏）
                VStack(spacing: 14) {
                    ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.sm)
                Spacer()
            } else if let err = errorText, sessions.isEmpty {
                Spacer()
                Text(err)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                Button("重试") { Task { await load() } }
                    .font(.system(size: Typography.body, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, Spacing.md)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        if isSearching {
                            // v3.9.33：搜索结果区（本地优先，本地零命中再补远端全史搜索）
                            searchResultsArea
                        } else {
                            BotCard()
                            if sessions.isEmpty {
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
                            } else {
                                // 每条会话独立卡片 + 间隔（会话条目间距）
                                // v2.0.133g：VStack → LazyVStack——会话多时全量渲染拖慢 TabView 切页；
                                // 删除已改后端驱动+load() 整体刷新（v2.0.56 根治），无就地 diff 崩溃路径，安全
                                LazyVStack(spacing: 8) {
                                    // v3.3.0：bot 模式已移除，会话列表不再按 bot 分组，直接平铺
                                    ForEach(sortedSessions) { s in
                                        // v3.0.51：会话 cell（SessionRow+长按菜单）拆辅助函数，避免嵌套 ForEach type-check 超时
                                        sessionCell(s)
                                    }
                                }
                                // v3.9.30：删除/刷新后列表项淡出与位置移动过渡（数组替换不再生硬跳变）
                                .animation(Motion.settle, value: sortedSessions.map(\.id))
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.bottom, 90)
                    // v3.9.30：空态/列表切换过渡动画（emerge 浮现；reduceMotion 时系统自动忽略带动画的过渡）
                    .animation(Motion.emerge, value: filteredSessions.isEmpty)
                }
                .scrollPosition($scrollPos)
                // v2.0.86h：Dock 滑动隐藏已删除（从未生效，手动开关替代）
                .refreshable {
                    if !isSearching { await load() }
                }
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
        // v2.0.43：会话重命名
        .alert("重命名会话", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("新名称", text: $renameText)
            Button("确定") { rename() }
            Button("取消", role: .cancel) {}
        }
        // v2.0.57：删除确认（弹窗完全关闭后再执行删除，绕开 contextMenu 动画期数据变更）
        // v2.0.87ad：多选底部删除栏
        .safeAreaInset(edge: .bottom) {
            if editing {
                HStack(spacing: 14) {
                    Button {
                        if selectedIds.count == sessions.count {
                            selectedIds.removeAll()
                        } else {
                            selectedIds = Set(sortedSessions.map(\.id))
                        }
                    } label: {
                        Text(selectedIds.count == sessions.count ? "取消全选" : "全选")
                            .font(.system(size: Typography.subhead, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                    Spacer()
                    Text("\(selectedIds.count) 条")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.secondary)
                    Button {
                        deleteSelected()
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

    // MARK: - v3.9.33 搜索结果区（本地优先 + 远端全史兜底）

    /// 搜索结果区：本地命中（实时、无网络）优先；本地一条都没有时才用远端全史搜索兜底，
    /// 把冷启动缓存（最近 100 会话 × 每会话 50 条消息）之外的旧会话也捞出来。
    @ViewBuilder
    private var searchResultsArea: some View {
        if !filteredSessions.isEmpty {
            LazyVStack(spacing: 8) {
                ForEach(filteredSessions) { s in
                    sessionCell(s)
                }
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
            }
            // 失败不静默（本仓刚因静默 return 被用户报「功能坏了」）：远端搜索/打开失败留一行小字
            if let note = remoteNoticeText {
                Text(note)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                    .padding(.top, Spacing.sm)
            }
        }
    }

    /// 远端命中列表：会话仍能对上本地列表 → 走普通会话行（同本地搜索结果）；
    /// 只在服务器上的旧会话 → 轻量命中行（标题 + 命中片段），点击后先拉全量列表再进会话。
    private var remoteHitsList: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("全部历史")
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xs)
            LazyVStack(spacing: 8) {
                ForEach(remoteHits) { hit in
                    if let s = localSession(id: hit.id) {
                        sessionCell(s)
                    } else {
                        RemoteHitRow(hit: hit) { openRemote(id: hit.id) }
                    }
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
        chat.load(s)
        chat.markRead(s.id)   // v3.9.32：打开会话即已读（此前 markRead 全仓零调用，红点会永久挂着）
        Haptics.tap()         // v3.4.29：进入会话触感
        onOpenSession?()
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
                   unread: chat.unread[s.id] ?? false,
                   categoryName: categoryStore.categoryForSession(s.id)?.name) {
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
            Button {
                togglePin(s)
            } label: {
                Label(pinnedIDs.contains(s.id) ? "取消置顶" : "置顶", systemImage: pinnedIDs.contains(s.id) ? "pin.slash" : "pin")
            }
            Button {
                toggleFav(s)
            } label: {
                Label(favIDs.contains(s.id) ? "取消收藏" : "收藏", systemImage: favIDs.contains(s.id) ? "star.slash" : "star")
            }
            Button {
                renameTarget = s
                renameText = s.title
            } label: {
                Label("重命名", systemImage: "pencil")
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
            Button(role: .destructive) {
                confirmDelete = s
            } label: {
                Label("删除会话", systemImage: "trash")
            }
        }
    }

    private func rank(_ id: String) -> Int {
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
    private func rename() {
        guard let t = renameTarget else { return }
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        if let idx = sessions.firstIndex(where: { $0.id == t.id }) {
            var updated = sessions[idx]
            updated.title = newName
            sessions[idx] = updated
        }
        if chat.sessionId == t.id {
            chat.title = newName
        }
        renameTarget = nil
        Task {
            _ = try? await auth.request("/api/sessions/merge", method: "POST", body: [
                "sessions": [[ "id": t.id, "title": newName, "messages": t.messages.map { m -> [String: Any] in
                    var p: [String: Any] = ["role": m.role, "content": m.content]
                    if let ts = m.timestamp { p["timestamp"] = ts }
                    if m.isPush { p["isPush"] = true }    // v3.0.83fix：rename 同步补 isPush（防改名后推送标记丢失）
                    if m.agent { p["agent"] = true }
                    return p
                }]],
                "deleted": [] as [Any]
            ])
            _ = try? await auth.request("/api/sessions/merge", method: "POST", body: [
                "sessions": [[ "id": t.id, "title": newName, "messages": t.messages.map { m -> [String: Any] in
                    // v3.9.32 fix：改名必须带全字段——此前只带 role/content/timestamp/isPush/agent，
                    // 而后端 merge 对同 id 消息是**整条覆盖**，于是给含图会话改个名，
                    // 图片气泡当场退化成 [图片]、引用原文与跨重启 uid 锚点一并丢失（不可逆）。
                    // 口径与 ChatStore.writeSessionSnapshot 保持一致，别再各写一份。
                    var p: [String: Any] = ["role": m.role, "content": m.content]
                    if let ts = m.timestamp { p["timestamp"] = ts }
                    if let img = m.imageDataURL, !img.isEmpty { p["imageDataURL"] = img }
                    if let u = m.uid, !u.isEmpty { p["uid"] = u }
                    if m.isPush { p["isPush"] = true }    // v3.0.83fix：rename 同步补 isPush（防改名后推送标记丢失）
                    if m.agent { p["agent"] = true }
                    if m.suspectedRepeat { p["suspectedRepeat"] = true }
                    if let q = m.quotedText, !q.isEmpty { p["quotedText"] = q }
                    return p
                }]],
                "deleted": [] as [Any]
            ])
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
        let ids = Array(selectedIds)
        guard !ids.isEmpty else { return }
        let idsCopy = ids
        selectedIds.removeAll()
        editing = false
        Task {
            do {
                let j = try await auth.json("/api/sessions/merge", method: "POST", body: [
                    "sessions": [] as [Any], "deleted": idsCopy
                ])
                if (j["ok"] as? Bool) == true {
                    await load()
                } else {
                    // v2.0.102：失败恢复选择与编辑态（原清空后失败无恢复）
                    selectedIds = Set(idsCopy)
                    editing = true
                    errorText = "删除失败，请重试"
                }
            } catch {
                // v2.0.102：失败恢复选择与编辑态
                selectedIds = Set(idsCopy)
                editing = true
                errorText = "删除失败，请重试"
            }
        }
    }

    private func delete(_ s: ChatSession) {
        // v2.0.57：三保险——①contextMenu 关闭瞬间不改数据（先弹确认再删）
        // ②后端删除成功才 load() 整体刷新（不就地改 sessions）
        // ③删当前会话：切聊天 tab 后在屏 newSession（v2.0.44 已验证路径），
        //    不再隐藏页清空（v2.0.54/56 的延迟只是推迟崩溃，隐藏页清空才是 SIGTRAP 根因）
        let deletingId = s.id
        Task {
            do {
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
    var unread = false      // v3.9.32：未读红点（列表外产生的新消息）
    var categoryName: String? = nil   // v3.9.32：所属分类（长按「移动到…」设过才显示）
    var action: () -> Void = {}

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
                Text(session.relativeTime)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                // v3.9.32：未读红点——此前 unread/markRead 只有存储层、全仓零渲染
                if unread && !showCheck {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("有未读消息")
                }
                // v2.0.87ad：多选勾选圈（编辑模式替代 chevron）
                if showCheck {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: Typography.headline))
                        .foregroundStyle(checked ? Color.accentColor : Color.secondary.opacity(0.4))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: Typography.caption, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        // 会话条目边框（深浅色通用细描边）
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contentShape(Rectangle())
        // 用 tap 手势而非 Button 包裹（Button 会与 swipeActions 滑动手势冲突，导致滑动删除失效）
        .onTapGesture { action() }
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
                    .background(tagColor(t).opacity(0.14), in: Capsule())
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
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contentShape(Rectangle())
        // 与 SessionRow 一致用 tap 手势（Button 会与 swipeActions 冲突）
        .onTapGesture { onTap() }
    }
}
