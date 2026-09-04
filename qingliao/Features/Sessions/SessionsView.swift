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
    // v2.0.78：搜索框焦点（键盘收回）
    @FocusState private var focused: Bool
    @State private var searchResults: [[String: Any]] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
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
    @State private var addCategoryForSession: String?
    @State private var newCategoryName = ""
    // v3.0.51 B7：会话标签
    @State private var tagTarget: ChatSession?
    @State private var showNewTag = false
    @State private var newTagName = ""
    var onOpenSession: (() -> Void)? = nil   // 切到聊天 tab

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // v2.0.87ad：多选编辑入口（非空会话时显示）
            PageHeader(title: "会话", trailing: AnyView(HStack(spacing: 14) {
                if !sessions.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            editing.toggle()
                            if !editing { selectedIds.removeAll() }
                        }
                    } label: {
                        Image(systemName: editing ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(editing ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                addButton
            }))
            // v2.0.36：会话搜索框（v2.0.78：放大镜可点收起 + 键盘完成）
            HStack(spacing: 8) {
                Image(systemName: isSearching ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(isSearching ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                    .onTapGesture {
                        if isSearching {
                            // 搜索中点击放大镜 = 清空并收起（含键盘）
                            searchText = ""
                            searchResults = []
                            focused = false
                        } else {
                            focused = true
                        }
                    }
                TextField("搜索会话与消息", text: $searchText)
                    .font(.system(size: 14))
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .onSubmit { focused = false }   // 键盘「搜索」= 收起
                    .onChange(of: searchText) { _, new in
                        searchTask?.cancel()
                        guard !new.trimmingCharacters(in: .whitespaces).isEmpty else {
                            searchResults = []
                            return
                        }
                        let q = new
                        searchTask = Task {
                            try? await Task.sleep(for: .milliseconds(450))
                            guard !Task.isCancelled else { return }
                            await search(q)
                        }
                    }
                if isSearching {
                    Button {
                        searchText = ""
                        searchResults = []
                        focused = false   // v2.0.78：清空同时收键盘
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            if isLoading && sessions.isEmpty {
                Spacer()
                ProgressView()
                    .tint(.secondary)
                Spacer()
            } else if let err = errorText, sessions.isEmpty {
                Spacer()
                Text(err)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button("重试") { Task { await load() } }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 8)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        if isSearching {
                            // v2.0.36：搜索结果
                            if searching {
                                ProgressView().tint(.secondary).padding(.top, 30)
                            } else if searchResults.isEmpty {
                                // v2.0.65：空状态插画
                                VStack(spacing: 10) {
                                    ZStack {
                                        Circle()
                                            .fill(LinearGradient(colors: [Color.teal.opacity(0.25), Color.blue.opacity(0.15)],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                                            .frame(width: 64, height: 64)
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 24))
                                            .foregroundStyle(Color.teal.opacity(0.7))
                                    }
                                    Text("未找到相关内容")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                    Text("换个关键词试试，可搜索消息内容")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.top, 40)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(Array(searchResults.enumerated()), id: \.offset) { _, r in
                                        SearchResultRow(result: r) {
                                            openSearchResult(r)
                                        }
                                    }
                                }
                            }
                        } else {
                            BotCard()
                            if sessions.isEmpty {
                                // v2.0.65：空状态插画
                                VStack(spacing: 10) {
                                    ZStack {
                                        Circle()
                                            .fill(LinearGradient(colors: [Color.blue.opacity(0.25), Color.indigo.opacity(0.15)],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                                            .frame(width: 64, height: 64)
                                        Image(systemName: "bubble.left.and.bubble.right")
                                            .font(.system(size: 24))
                                            .foregroundStyle(Color.blue.opacity(0.7))
                                    }
                                    Text("暂无会话记录")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                    Text("点击右上角 + 开始和 AI 对话")
                                        .font(.system(size: 11))
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
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 90)
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
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("\(selectedIds.count) 条")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Button {
                        deleteSelected()
                    } label: {
                        Label("删除", systemImage: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(selectedIds.isEmpty ? Color.red.opacity(0.4) : Color.red,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedIds.isEmpty)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
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
            onOpenSession?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                chat.requestNewSession()
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
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

    /// v3.0.51：会话 cell（SessionRow + 长按菜单）——拆辅助函数，防嵌套 ForEach type-check 超时
    @ViewBuilder
    private func sessionCell(_ s: ChatSession) -> some View {
        SessionRow(session: s,
                   pinned: pinnedIDs.contains(s.id),
                   faved: favIDs.contains(s.id),
                   tags: tagStore.tags(for: s.id),
                   showCheck: editing,
                   checked: selectedIds.contains(s.id)) {
            if editing {
                toggleSelect(s.id)
            } else {
                chat.load(s)
                onOpenSession?()
            }
        }
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
        }
    }

    private func search(_ q: String) async {
        searching = true
        defer { searching = false }
        guard let j = try? await auth.json("/api/sessions/search", method: "POST", body: ["q": q]),
              let arr = j["results"] as? [[String: Any]] else {
            // v2.0.102：失败时仅当查询词未变才清空（防旧请求晚到覆盖新结果）
            if q == searchText { searchResults = [] }
            return
        }
        // v2.0.102：竞态防护——旧查询响应晚到时不覆盖新查询结果
        if q == searchText {
            searchResults = arr
        }
    }

    /// 搜索结果 → 打开对应会话（按 id 从完整列表找到并加载），并定位命中消息
    private func openSearchResult(_ r: [String: Any]) {
        let sid = r["id"] as? String ?? ""
        if let s = sessions.first(where: { $0.id == sid }) {
            chat.load(s)
            chat.markRead(s.id)   // v2.0.65 打开即读
            // v2.0.43：设置定位目标（ChatView 滚动+高亮命中消息）
            if let hits = r["hits"] as? [[String: Any]], let first = hits.first {
                chat.highlightTarget = (role: first["role"] as? String ?? "assistant",
                                        content: first["content"] as? String ?? "")
            } else {
                chat.highlightTarget = nil
            }
            searchText = ""
            searchResults = []
            onOpenSession?()
        }
    }

    // MARK: - 数据

    private func load() async {
        // 3 秒内不重复加载（快速滑动切 Tab 时避免 isLoading 翻转蹭卡）
        if let last = lastLoadAt, Date().timeIntervalSince(last) < 3 { return }
        isLoading = true
        errorText = nil
        lastLoadAt = Date()
        // v3.0 云端模式：会话历史存 App 本地（CloudSessionStore），不走后端
        if CloudConfig.shared.isCloudMode {
            CloudSessionStore.shared.load()
            sessions = CloudSessionStore.shared.sessions
            chat.syncUnread(from: sessions, currentId: chat.sessionId)
            isLoading = false
            return
        }
        do {
            let j = try await auth.json("/api/sessions/list")
            let raw = (j["sessions"] as? [Any] ?? [])
            // 最新 → 最旧
            sessions = raw.compactMap { ChatSession.parse($0 as? [String: Any] ?? [:]) }
                .sorted { ($0.lastTime ?? 0) > ($1.lastTime ?? 0) }
            // v2.0.65：同步未读红点
            chat.syncUnread(from: sessions, currentId: chat.sessionId)
        } catch {
            errorText = "加载失败，请检查连接"
        }
        isLoading = false
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
            // v3.0 云端模式：本地删除
            if CloudConfig.shared.isCloudMode {
                for id in idsCopy {
                    CloudSessionStore.shared.delete(id: id)
                }
                await load()
                return
            }
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
            // v3.0 云端模式：本地删除
            if CloudConfig.shared.isCloudMode {
                CloudSessionStore.shared.delete(id: s.id)
                await load()
                if chat.sessionId == deletingId {
                    onOpenSession?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        chat.requestNewSession()
                    }
                }
                return
            }
            do {
                let j = try await auth.json("/api/sessions/merge", method: "POST", body: [
                    "sessions": [] as [Any],
                    "deleted": [s.id]
                ])
                let ok = (j["ok"] as? Bool) == true
                let deletedCount = (j["deleted"] as? Int) ?? -1
                if ok && deletedCount >= 0 {
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
    // v3.0.2 fix：云端 AI 会话头像模型应显示「设置→模型管理」选的模型（存 CloudConfig，非 qingliao_model）
    @State private var cloudConfig = CloudConfig.shared

    // 按模式取当前模型：云端读 CloudConfig.activeConfig，本地读 qingliao_model
    // v3.0.20：Agent 模型自定义——agent 开启且配置了独立模型时显示 agent 模型
    private var displayModel: String {
        if CloudConfig.shared.isCloudMode {
            let c = CloudConfig.shared.activeConfig
            return "\(c?.name ?? "云端")/\(c?.model ?? "未选")"
        }
        let agentOn = UserDefaults.standard.bool(forKey: UserDefaultsKey.agentEnabled)
        let agentModel = UserDefaults.standard.string(forKey: UserDefaultsKey.agentModel) ?? ""
        if agentOn && !agentModel.isEmpty {
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
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("轻聊 agent")
                    .font(.system(size: 15, weight: .semibold))
                // v2.0.50：模型名动态显示（之前硬编码，设置切模型不刷新）
                // v3.0.2：云端模式显示 CloudConfig 选中模型
                Text(displayModel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(online == true ? Color.green : (online == false ? Color.red : Color.gray))
                    .frame(width: 6, height: 6)
                Text(online == true ? "在线" : (online == false ? "离线" : "检测中"))
                    .font(.system(size: 10))
                    .foregroundStyle(online == true ? Color.green : (online == false ? Color.red : Color.secondary))
            }
        }
        .padding(13)
        .background(
            LinearGradient(colors: [Color.blue.opacity(0.14), Color.indigo.opacity(0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.25), lineWidth: 0.8)
        )
        .task {
            // 真实连接状态
            let r = await auth.testConnection(server: auth.serverURL)
            online = r.hasPrefix("✅")
        }
    }
}

// MARK: - v2.0.36 搜索结果行（会话标题 + 命中片段）

struct SearchResultRow: View {
    let result: [String: Any]
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color.green.opacity(0.18), Color.teal.opacity(0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.green.opacity(0.8))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(result["title"] as? String ?? "新对话")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let hits = result["hits"] as? [[String: Any]], let first = hits.first {
                    Text((first["snippet"] as? String) ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { action() }
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
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color.blue.opacity(0.18), Color.indigo.opacity(0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.blue.opacity(0.8))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.orange)
                    }
                    // v2.0.60：收藏星标
                    if faved {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.yellow)
                    }
                    Text(session.title.isEmpty ? "新对话" : session.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                // v3.0.51 B7：会话标签小胶囊（彩色，最多 3 个）
                                if !tags.isEmpty {
                                    SessionTagCapsules(tags: tags)
                                        .padding(.top, 1)
                                }
                                Text(session.lastMessageText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(session.relativeTime)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                // v2.0.87ad：多选勾选圈（编辑模式替代 chevron）
                if showCheck {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(checked ? Color.accentColor : Color.secondary.opacity(0.4))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        // 会话条目边框（深浅色通用细描边）
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tagColor(t))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(tagColor(t).opacity(0.14), in: Capsule())
            }
        }
    }
}
