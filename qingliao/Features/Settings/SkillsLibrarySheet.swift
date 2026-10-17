// #24 技能库设置页 —— 列表 / 本地搜索 / 查看（SKILL.md 正文）/ 启停 / 软删（可撤销）/ 沉淀入口。
//
// 口径：
//  ① 数据真源 = 后端 `GET /api/agent/skills`（经 Core/SkillsClient.swift，走别名前缀 /api/agent/skills）。
//     本页**不拼 URL、不读 token**——把现成请求封装 `auth.request` 作为传输注入 SkillsClient。
//  ② 「查看」用仓内现有 **MarkdownRenderer** 渲染正文（与 AI 消息气泡同一套），不自写渲染。
//  ③ 二次确认一律走 **AnchorMenuOverlay**（锚定浮层），**不用 confirmationDialog**
//     （iPhone 上从底部升起、锚不到触发按钮，仓内已统一废弃——见退出登录/清空剪贴板）。
//  ④ 停用 / 删除都有**用户可感知的轻提示**且操作后**回读刷新**；删除是软删（_trash 可恢复），
//     提示条带「撤销」调 `POST /api/agent/skills/restore`。
//  ⑤ 「沉淀为技能」：选一个会话（会话 id 取后端认识的 `ChatSession.id`，与 ChatStore 同一读路径
//     `/api/sessions/list`）→ distill（只返草稿）→ 草稿编辑页（name 本地校验 `^[a-z0-9-]{2,48}$`）
//     → save。save 前 SkillsClient 会把草稿 frontmatter 的 `name:` 对齐到保存名（后端强校验）。

import SwiftUI

struct SkillsLibrarySheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var items: [SkillItem] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var query = ""

    /// 操作后的轻提示（停用 / 删除 / 恢复 / 保存）
    @State private var toast = ""
    /// 删除后挂起的可撤销目标
    @State private var undoTarget: SkillItem?

    // 行尾菜单 / 删除确认的锚点
    @State private var menuItem: SkillItem?
    @State private var menuAnchor: CGRect = .zero
    @State private var confirmDelete: SkillItem?
    @State private var deleteAnchor: CGRect = .zero

    // 详情
    @State private var showDetail = false
    @State private var detailSkill: SkillDetail?
    @State private var detailLoading = false
    @State private var detailError: String?

    // 沉淀
    @State private var showSessionPicker = false
    @State private var sessions: [ChatSession] = []
    @State private var sessionsLoading = false
    @State private var sessionsError: String?
    @State private var showDraft = false
    @State private var draftName = ""
    @State private var draftBody = ""
    @State private var draftSaving = false
    @State private var draftError = ""

    /// 传输走 App 现成请求封装 `auth.request`（Wi-Fi/蜂窝分流 + X-Auth-Token 全由它处理）
    private var client: SkillsClient {
        SkillsClient { method, path, bodyData in
            let body = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            do {
                // ⚠️ 实参形态必须逐字对上 AuthStore.request(_ path:method:body:timeout:)：
                //    首参**无标签**。本机预检只有 -parse（不类型检查），标签写错要到 CI Archive 才炸
                //    （v4.0.104 只读审查抓到的阻断项）。§102 有断言把声明与调用一起钉住。
                let (data, resp) = try await auth.request(path, method: method, body: body)
                return (data, resp.statusCode)
            } catch let e as APIError {
                switch e {
                case .unauthorized: throw SkillsError.unauthorized
                case .server(let code): return (Data(), code)
                default: throw SkillsError.network
                }
            } catch {
                throw SkillsError.network
            }
        }
    }

    private var filtered: [SkillItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            [$0.name, $0.title, $0.description, $0.category]
                .contains { $0.lowercased().contains(q) }
        }
    }

    /// v4.0.105 四段分组（我生成的 → 我安装的 → 系统 → 未定垫底）
    private var grouped: [SkillGroup] { SkillGroup.group(filtered) }

    var body: some View {
        NavigationStack {
            Form {
                // ── 沉淀入口（v1 取巧版：先放技能库页顶部，不动 ChatView 的大文件）──
                Section {
                    Button {
                        openSessionPicker()
                    } label: {
                        Label("把一段对话沉淀成技能", systemImage: "sparkles")
                    }
                }

                // ── 搜索 ──
                Section {
                    TextField("搜索技能（名称 / 分类 / 说明）", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                // ── 轻提示（含撤销）──
                if !toast.isEmpty {
                    Section {
                        HStack(spacing: Spacing.md) {
                            Text(toast)
                                .font(.system(size: Typography.subhead))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if let u = undoTarget {
                                Button("撤销") { undoDelete(u) }
                                    .font(.system(size: Typography.subhead, weight: .semibold))
                            }
                        }
                    }
                }

                content
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("技能库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay { menuOverlay }
            .overlay { deleteOverlay }
            .sheet(isPresented: $showDetail) { detailSheet }
            .sheet(isPresented: $showSessionPicker) { sessionPickerSheet }
            .sheet(isPresented: $showDraft) { draftSheet }
            .task { await reload() }
        }
    }

    // MARK: - 列表 / 空态 / 加载态 / 失败态

    @ViewBuilder private var content: some View {
        if loading {
            Section {
                HStack(spacing: Spacing.md) {
                    ProgressView()
                    Text("加载中…").font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                }
            }
        } else if let err = loadError {
            Section {
                Text("加载失败：\(err)")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.red)
                Button("重试") { Task { await reload() } }
            }
        } else if items.isEmpty {
            Section {
                Text("还没有技能").font(.system(size: Typography.subhead))
                Text("可以用上面的「把一段对话沉淀成技能」，或去别处保存技能包。")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
        } else if filtered.isEmpty {
            Section {
                Text("没有匹配「\(query)」的技能")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
            }
        } else {
            // v4.0.105：按来源四段分开（用户口径）+ 未定段提示长按纠正；空组不渲染
            ForEach(grouped) { g in
                if !g.items.isEmpty {
                    Section {
                        ForEach(g.items) { item in
                            row(item)
                        }
                    } header: {
                        HStack(spacing: Spacing.sm) {
                            Text("\(g.kind.title)（\(g.items.count)）")
                            if g.kind == .unknown {
                                Spacer(minLength: 8)
                                Text("长按一行可纠正来源")
                            }
                        }
                    }
                }
            }
        }
    }

    /// 一行：名称 + 分类 + 描述单行截断 + 启用状态胶囊 + 行尾「…」菜单（滑动动作同款）
    private func row(_ item: SkillItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.md) {
                Text(item.title.isEmpty ? item.name : item.title)
                    .font(.system(size: Typography.body, weight: .medium))
                    .lineLimit(1)
                statusPill(item.enabled)
                Spacer(minLength: 8)
                sourceChip(SkillSourceKind.of(item))   // v4.0.105 来源标签（分组之外再给逐行反馈）
                Button {
                    menuItem = item
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: Typography.title))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                    if menuItem?.name == item.name { menuAnchor = rect }
                }
            }
            if !item.category.isEmpty {
                Text(item.category)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
            if !item.description.isEmpty {
                Text(item.description)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // v4.0.105：长按一行 → 复用**全局长按菜单**（同一套锚定胶囊）纠正来源；
        // 「…」菜单保持「查看 / 停用 / 删除」不变，两个入口各管一摊，互不抢。
        .anchorLongPressMenu(items: correctionItems(item),
                             title: item.title.isEmpty ? item.name : item.title,
                             message: "当前来源：\(SkillSourceKind.of(item).title) · 纠正只写覆盖清单（不动自动判定）",
                             onPick: { pick in Task { await correct(item, pick: pick.id) } })
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                askDelete(item, anchor: .zero)
            } label: { Label("删除", systemImage: "trash") }
            Button {
                Task { await toggle(item) }
            } label: {
                Label(item.enabled ? "停用" : "启用",
                      systemImage: item.enabled ? "pause.circle" : "play.circle")
            }
            .tint(.orange)
        }
    }

    private func statusPill(_ on: Bool) -> some View {
        Text(on ? "已启用" : "已停用")
            .font(.system(size: Typography.tiny, weight: .semibold))
            .foregroundStyle(on ? Color.green : Color.secondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background((on ? Color.green : Color.gray).opacity(Tint.coloredFill(scheme)),
                        in: Capsule(style: .continuous))
    }

    /// v4.0.105 来源色（放视图层：SkillsClient.swift 必须能被真值表独立编译，不能引 SwiftUI 的 Color）
    private func sourceTint(_ kind: SkillSourceKind) -> Color {
        switch kind {
        case .generated: return .blue
        case .installed: return .green
        case .system: return .gray
        case .unknown: return .orange
        }
    }

    /// v4.0.105 来源标签
    private func sourceChip(_ kind: SkillSourceKind) -> some View {
        Text(kind.title)
            .font(.system(size: Typography.tiny, weight: .semibold))
            .foregroundStyle(sourceTint(kind))
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            // 彩色淡底走 Tint.coloredFill（第 8 项：浅 0.15 / 深 0.22；护栏把裸 0.14 清零）
            .background(sourceTint(kind).opacity(Tint.coloredFill(scheme)), in: Capsule(style: .continuous))
            .lineLimit(1)
            .fixedSize()
    }

    /// v4.0.105 纠错菜单：三颗「标为…」+ 第 4 颗「撤销纠正」（拍板 2-1）
    private func correctionItems(_ item: SkillItem) -> [AnchorMenuItem] {
        let cur = SkillSourceKind.of(item)
        var out: [AnchorMenuItem] = []
        for k in [SkillSourceKind.generated, .installed, .system] {
            out.append(AnchorMenuItem(id: k.rawValue,
                                      title: "标为「\(k.title)」",
                                      icon: k == cur ? "checkmark.circle.fill" : "circle",
                                      color: sourceTint(k),
                                      disabled: k == cur))
        }
        out.append(AnchorMenuItem(id: "reset", title: "撤销纠正（恢复自动判定）",
                                  icon: "arrow.uturn.backward", color: .gray))
        return out
    }

    /// v4.0.105 提交纠正（pick=reset → 撤销）；成功后回读刷新，分组与标签同步变动
    private func correct(_ item: SkillItem, pick: String) async {
        do {
            let r = try await client.setSource(name: item.name, source: pick == "reset" ? nil : pick)
            let label = SkillSourceKind(rawValue: r.source)?.title ?? r.source
            toast = r.cleared ? "已撤销纠正：\(item.name)（自动判定为「\(label)」）"
                              : "已标为「\(label)」：\(item.name)"
            await reload()
        } catch let e as SkillsError {
            toast = "纠正失败：\(e.message)"
        } catch {
            toast = "纠正失败：\(error)"
        }
    }

    // MARK: - 浮层

    @ViewBuilder private var menuOverlay: some View {
        if let item = menuItem {
            AnchorMenuOverlay(
                anchorFrame: menuAnchor,
                items: [
                    AnchorMenuItem(id: "view", title: "查看", icon: "doc.text", color: .blue),
                    AnchorMenuItem(id: "toggle", title: item.enabled ? "停用" : "启用",
                                   icon: item.enabled ? "pause.circle" : "play.circle", color: .orange),
                    AnchorMenuItem(id: "delete", title: "删除", icon: "trash",
                                   color: .red, destructive: true),
                ],
                title: item.title.isEmpty ? item.name : item.title,
                onPick: { pick in
                    let it = item
                    menuItem = nil
                    switch pick.id {
                    case "view": openDetail(it)
                    case "toggle": Task { await toggle(it) }
                    case "delete": askDelete(it, anchor: menuAnchor)
                    default: break
                    }
                },
                onClose: { menuItem = nil }
            )
        }
    }

    @ViewBuilder private var deleteOverlay: some View {
        if let item = confirmDelete {
            AnchorMenuOverlay(
                anchorFrame: deleteAnchor,
                items: [
                    AnchorMenuItem(id: "del", title: "删除", icon: "trash",
                                   color: .red, destructive: true),
                    AnchorMenuItem(id: "cancel", title: "取消", icon: "xmark", color: .gray),
                ],
                title: "删除技能「\(item.title.isEmpty ? item.name : item.title)」？",
                message: "软删：进 _trash 可恢复，删除后可用提示条里的「撤销」找回。",
                onPick: { pick in
                    let it = item
                    confirmDelete = nil
                    if pick.id == "del" { Task { await delete(it) } }
                },
                onClose: { confirmDelete = nil }
            )
        }
    }

    private func askDelete(_ item: SkillItem, anchor: CGRect) {
        confirmDelete = item
        if anchor != .zero { deleteAnchor = anchor }
    }

    // MARK: - 详情

    private func openDetail(_ item: SkillItem) {
        detailSkill = nil
        detailError = nil
        detailLoading = true
        showDetail = true
        Task { await loadDetail(item.name) }
    }

    @ViewBuilder private var detailSheet: some View {
        NavigationStack {
            Group {
                if detailLoading {
                    VStack(spacing: Spacing.md) { ProgressView(); Text("加载中…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = detailError {
                    VStack(spacing: Spacing.md) {
                        Text("加载失败：\(err)").foregroundStyle(.red)
                        Button("重试") { Task { if let n = detailSkill?.name { await loadDetail(n) } } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let d = detailSkill {
                    ScrollView {
                        // 复用仓内消息气泡同一套 Markdown 渲染
                        Text(MarkdownRenderer.renderCachedAttr(d.content, baseSize: Typography.body))
                            .font(.system(size: Typography.body))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.xxl)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("技能详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { showDetail = false }
                }
            }
        }
    }

    // MARK: - 会话选择 → 蒸馏

    private func openSessionPicker() {
        sessions = []
        sessionsError = nil
        sessionsLoading = true
        showSessionPicker = true
        Task { await loadSessions() }
    }

    @ViewBuilder private var sessionPickerSheet: some View {
        NavigationStack {
            Group {
                if sessionsLoading {
                    ProgressView("加载会话…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = sessionsError {
                    VStack(spacing: Spacing.md) {
                        Text("加载失败：\(err)").foregroundStyle(.red)
                        Button("重试") { Task { await loadSessions() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sessions.isEmpty {
                    Text("还没有可选择的会话").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(sessions) { s in
                        Button {
                            showSessionPicker = false
                            Task { await distill(s) }
                        } label: {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(s.title.isEmpty ? "（无标题会话）" : s.title)
                                    .font(.system(size: Typography.body))
                                    .foregroundStyle(.primary)
                                Text(s.relativeTime)
                                    .font(.system(size: Typography.caption))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择一段对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showSessionPicker = false }
                }
            }
        }
    }

    @ViewBuilder private var draftSheet: some View {
        NavigationStack {
            Form {
                Section("技能名（只允许小写字母、数字、连字符，2–48 位）") {
                    TextField("skill-name", text: $draftName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !draftName.isEmpty && !SkillsClient.isValidName(draftName) {
                        Text("名字不合法：只允许小写字母、数字、连字符，2–48 位")
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.red)
                    }
                }
                Section("正文（SKILL.md，可编辑）") {
                    TextEditor(text: $draftBody)
                        .font(.system(size: Typography.subhead))
                        .frame(minHeight: 240)
                }
                if !draftError.isEmpty {
                    Section {
                        Text(draftError)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("编辑草稿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showDraft = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draftSaving ? "保存中…" : "保存") { Task { await saveDraft() } }
                        .disabled(draftSaving || !SkillsClient.isValidName(draftName))
                }
            }
        }
    }

    // MARK: - 动作（全部：先请求 → 轻提示 → 回读刷新）

    private func reload() async {
        loading = true
        loadError = nil
        do {
            items = try await client.list()
        } catch let e as SkillsError {
            loadError = e.message
        } catch {
            loadError = "未知错误"
        }
        loading = false
    }

    private func toggle(_ item: SkillItem) async {
        do {
            let r = try await client.toggle(name: item.name, enabled: !item.enabled)
            toast = r.enabled ? "已启用「\(r.name)」" : "已停用「\(r.name)」"
            await reload()   // 回读刷新
        } catch let e as SkillsError {
            toast = "操作失败：\(e.message)"
        } catch {
            toast = "操作失败"
        }
    }

    private func delete(_ item: SkillItem) async {
        do {
            let res = try await client.delete(name: item.name)
            // 只在后端**真留了回收副本**时才承诺「可撤销」（recoverable 之前被 `_ =` 丢掉 = 假承诺；
            // v4.0.104 只读审查 S2）。
            if res.recoverable {
                toast = "已删除「\(item.name)」（可撤销）"
                undoTarget = item
            } else {
                toast = "已删除「\(item.name)」（后端未留副本，不可撤销）"
                undoTarget = nil
            }
            await reload()   // 回读刷新
        } catch let e as SkillsError {
            toast = "删除失败：\(e.message)"
        } catch {
            toast = "删除失败"
        }
    }

    private func undoDelete(_ item: SkillItem) {
        Task {
            do {
                _ = try await client.restore(name: item.name)
                undoTarget = nil
                toast = "已恢复「\(item.name)」"
                await reload()
            } catch let e as SkillsError {
                toast = "恢复失败：\(e.message)"
            } catch {
                toast = "恢复失败"
            }
        }
    }

    private func loadDetail(_ name: String) async {
        detailLoading = true
        detailError = nil
        do {
            detailSkill = try await client.detail(name: name)
        } catch let e as SkillsError {
            detailError = e.message
        } catch {
            detailError = "未知错误"
        }
        detailLoading = false
    }

    private func loadSessions() async {
        sessionsLoading = true
        sessionsError = nil
        // 会话 id 与 ChatStore 同一读路径，取后端认识的 `ChatSession.id`
        guard let j = await auth.jsonOrLog("/api/sessions/list"),
              let raw = j["sessions"] as? [Any] else {
            sessionsError = "无法加载会话列表"
            sessionsLoading = false
            return
        }
        sessions = raw.compactMap { ChatSession.parse($0 as? [String: Any] ?? [:]) }
        sessionsLoading = false
    }

    private func distill(_ s: ChatSession) async {
        do {
            let d = try await client.distill(sessionId: s.id)
            draftName = SkillsClient.isValidName(d.name) ? d.name : ""
            draftBody = d.draft
            draftError = ""
            showDraft = true
        } catch let e as SkillsError {
            toast = "蒸馏失败：\(e.message)"
        } catch {
            toast = "蒸馏失败"
        }
    }

    private func saveDraft() async {
        draftSaving = true
        draftError = ""
        do {
            let r = try await client.save(name: draftName, content: draftBody)
            showDraft = false
            toast = "已保存「\(r.name)」"
            await reload()
        } catch let e as SkillsError {
            draftError = "保存失败：\(e.message)"
        } catch {
            draftError = "保存失败"
        }
        draftSaving = false
    }
}
