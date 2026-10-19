// 工作台「Hermes 插件」页 —— 已安装（含手动装 + 桌面端） / 官方插件库浏览 / 一键安装 / 启停。
//
// 口径：
//  ① 数据真源 = 后端 `/api/agent/plugins/*`（与 Hermes 桌面端/CLI 同一份 plugins 目录 + config.yaml +
//     官方 catalog）。本页**不拼域名、不读 token**——把 `auth.request` 作为传输注入 PluginsClient。
//  ② 两类来源必须一眼可分：「手动安装」= 直接拷进 ~/.hermes/plugins 的；「插件库」= 从 catalog 装的；
//     「桌面端」= 只有 desktop/plugin.js、由桌面 App 加载的（开关不归轻聊管）。
//  ③ 安装是后台任务（官方 CLI 要 clone + 拉依赖，30~120 秒）→ 发起后轮询状态，完成再回读列表；
//     **不做假进度条**，状态文案直接用后端返回的 log 尾行。
//  ④ 启停写的是 config.yaml 的 plugins.enabled，后端会重启网关（约 30 秒）——提示要说清楚，
//     别让用户以为「点了没反应」。
//  ⑤ 二次确认统一走 AnchorMenuOverlay（仓内已废弃 confirmationDialog）；本页只有「停用」需确认。

import SwiftUI

struct PluginsSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var installed: [PluginItem] = []
    @State private var catalogItems: [PluginCatalogItem] = []
    @State private var catalogTotal = 0
    @State private var catalogSource = ""
    @State private var categories: [String] = []
    @State private var categoryFilter = ""

    @State private var loading = true
    @State private var loadError: String?
    @State private var query = ""
    @State private var loadingMore = false

    @State private var toast = ""
    @State private var toastTask: Task<Void, Never>?

    // 安装
    @State private var installingName = ""
    @State private var installJob = ""
    @State private var installNote = ""
    @State private var polling: Task<Void, Never>?

    // 详情
    @State private var detailItem: PluginItem?

    private var client: PluginsClient {
        PluginsClient { method, path, bodyData in
            let body = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            do {
                // ⚠️ 实参序必须逐字对上 AuthStore.request(_:method:body:timeout:)：首参无标签
                let (data, resp) = try await auth.request(path, method: method, body: body)
                return (data, resp.statusCode)
            } catch let e as APIError {
                switch e {
                case .unauthorized: throw PluginsError.unauthorized
                case .server(let code): return (Data(), code)
                default: throw PluginsError.network
                }
            } catch {
                throw PluginsError.network
            }
        }
    }

    private var filteredInstalled: [PluginItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return installed }
        return installed.filter { [$0.name, $0.description, $0.sourceLabel].contains { $0.lowercased().contains(q) } }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !toast.isEmpty {
                    Section {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                            Text(toast).font(.system(size: Typography.caption))
                        }
                    }
                }

                installedSection
                catalogSection
                footerSection
            }
            .navigationTitle("Hermes 插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜索已安装插件")
            .refreshable { await reload() }
            .task { await reload() }
            .onDisappear { polling?.cancel() }
            .sheet(item: $detailItem) { item in
                PluginDetailSheet(item: item)
            }
        }
    }

    // MARK: - 已安装

    private var installedSection: some View {
        Section {
            if loading {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                    Text("正在读取插件目录…").font(.system(size: Typography.caption)).foregroundStyle(.secondary)
                }
            } else if let e = loadError {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(e).font(.system(size: Typography.caption)).foregroundStyle(.red)
                    Button("重试") { Task { await reload() } }.font(.system(size: Typography.caption))
                }
            } else if filteredInstalled.isEmpty {
                Text(query.isEmpty ? "还没有安装任何插件" : "没有匹配的已安装插件")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredInstalled) { item in
                    installedRow(item)
                }
            }
        } header: {
            HStack {
                Text("已安装 \(installed.count) 个")
                Spacer()
                if !installed.isEmpty {
                    Text("\(installed.filter(\.enabled).count) 个已启用")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("「手动安装」= 直接放进 ~/.hermes/plugins 的插件；「插件库」= 从这里装的。两类都在这里统一显示与启停。")
                .font(.system(size: Typography.tiny))
        }
    }

    private func installedRow(_ item: PluginItem) -> some View {
        HStack(spacing: Spacing.sm) {
            badgeIcon(item)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: Typography.caption, weight: .semibold))
                        .lineLimit(1)
                    if !item.version.isEmpty {
                        Text("v\(item.version)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.description.isEmpty ? item.sourceLabel : item.description)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    chip(item.sourceLabel, tint: sourceTint(item))
                    if item.desktop {
                        chip("含桌面面板", tint: .indigo)
                    }
                    if item.skills > 0 {
                        chip("\(item.skills) 个技能", tint: .gray)
                    }
                }
            }
            Spacer(minLength: 4)
            if item.manageable {
                Toggle("", isOn: Binding(
                    get: { item.enabled },
                    set: { want in setEnabled(item, want) }))
                    // 开关口径单源：qingliaoSwitch()（内部 labelsHidden），别手写 .labelsHidden()/.tint()
                    .qingliaoSwitch()
                    .disabled(!installingName.isEmpty)
            } else {
                Text("桌面端")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { detailItem = item }
    }

    private func badgeIcon(_ item: PluginItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(sourceTint(item).opacity(0.15))
                .frame(width: 34, height: 34)
            Image(systemName: item.desktopOnly ? "desktopcomputer" : "puzzlepiece.extension.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(sourceTint(item))
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }

    private func sourceTint(_ item: PluginItem) -> Color {
        switch item.source {
        case "manual": return .orange
        case "catalog": return .purple
        case "git": return .teal
        default: return .gray
        }
    }

    // MARK: - 插件库

    private var catalogSection: some View {
        Section {
            if !categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        categoryChip("全部", value: "")
                        ForEach(categories, id: \.self) { c in categoryChip(c, value: c) }
                    }
                    .padding(.vertical, 2)
                }
            }
            if catalogItems.isEmpty && loading {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                    Text("正在读取插件库…").font(.system(size: Typography.caption)).foregroundStyle(.secondary)
                }
            } else if catalogItems.isEmpty {
                Text("没有匹配的插件").font(.system(size: Typography.caption)).foregroundStyle(.secondary)
            } else {
                ForEach(catalogItems) { item in
                    catalogRow(item)
                }
                if catalogItems.count < catalogTotal {
                    Button {
                        Task { await loadMoreCatalog() }
                    } label: {
                        HStack {
                            if loadingMore { ProgressView().controlSize(.small) }
                            Text(loadingMore ? "加载中…" : "加载更多（\(catalogItems.count)/\(catalogTotal)）")
                                .font(.system(size: Typography.caption))
                        }
                    }
                    .disabled(loadingMore || !installingName.isEmpty)
                }
            }
        } header: {
            HStack {
                Text("插件库")
                Spacer()
                Text(catalogSource == "live" ? "\(catalogTotal) 个 · 已联网更新"
                     : catalogSource == "stale" ? "\(catalogTotal) 个 · 离线缓存"
                     : "\(catalogTotal) 个")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("与 Hermes 桌面端同一个官方插件库；安装后写入本机 ~/.hermes/plugins，桌面端与 App 都能看到。")
                .font(.system(size: Typography.tiny))
        }
    }

    private func categoryChip(_ title: String, value: String) -> some View {
        Button {
            guard categoryFilter != value else { return }
            categoryFilter = value
            Task { await reloadCatalog(reset: true) }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(categoryFilter == value ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.12),
                            in: Capsule())
                .foregroundStyle(categoryFilter == value ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func catalogRow(_ item: PluginCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(item.name).font(.system(size: Typography.caption, weight: .semibold))
                    .lineLimit(1)
                chip(item.tierLabel, tint: item.tier == "official" ? .blue : item.tier == "verified" ? .green : .gray)
                if !item.version.isEmpty {
                    Text("v\(item.version)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                installControl(item)
            }
            if !item.description.isEmpty {
                Text(item.description)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if !item.maintainer.isEmpty {
                    Text(item.maintainer).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
                if item.installed && item.installedEnabled {
                    Text("已启用").font(.system(size: 10)).foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func installControl(_ item: PluginCatalogItem) -> some View {
        if installingName == item.name {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(installNote.isEmpty ? "安装中…" : installNote)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if item.installed {
            Text("已安装")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
        } else {
            Button {
                startInstall(item)
            } label: {
                Text("安装")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!installingName.isEmpty)
        }
    }

    private var footerSection: some View {
        Section {
            NavigationLink {
                PluginInstallHelpView()
            } label: {
                Label("手动安装 / 目录位置", systemImage: "terminal")
                    .font(.system(size: Typography.caption))
            }
        }
    }

    // MARK: - 动作

    private func reload() async {
        loading = installed.isEmpty
        loadError = nil
        do {
            installed = try await client.list()
        } catch let e as PluginsError {
            loadError = e.message
        } catch {
            loadError = "加载失败，请稍后重试"
        }
        loading = false
        await reloadCatalog(reset: true)
    }

    private func reloadCatalog(reset: Bool) async {
        let offset = reset ? 0 : catalogItems.count
        do {
            let r = try await client.catalog(query: "", offset: offset, limit: 30)
            if reset {
                catalogItems = r.items
            } else {
                catalogItems.append(contentsOf: r.items.filter { new in !catalogItems.contains { $0.name == new.name } })
            }
            catalogTotal = r.total
            categories = r.categories
            catalogSource = r.source
        } catch {
            if reset && catalogItems.isEmpty { catalogSource = "" }
        }
    }

    private func loadMoreCatalog() async {
        loadingMore = true
        await reloadCatalog(reset: false)
        loadingMore = false
    }

    private func startInstall(_ item: PluginCatalogItem) {
        guard installingName.isEmpty else { return }
        installingName = item.name
        installNote = "安装中…"
        polling?.cancel()
        polling = Task {
            do {
                let job = try await client.install(name: item.name)
                installJob = job
                for _ in 0..<90 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }
                    let st = try await client.installStatus(job: job)
                    if st.isRunning {
                        installNote = "下载中…"
                        continue
                    }
                    if st.isDone {
                        showToast(st.hint.isEmpty ? "「\(item.name)」已安装并启用" : st.hint)
                        installingName = ""
                        await reload()
                        return
                    }
                    if st.isError {
                        showToast(st.error.isEmpty ? "安装失败，请查看日志" : st.error)
                        installingName = ""
                        return
                    }
                }
                showToast("安装超时，请稍后到已安装列表确认")
                installingName = ""
            } catch let e as PluginsError {
                showToast(e.message)
                installingName = ""
            } catch {
                showToast("安装失败，请稍后重试")
                installingName = ""
            }
        }
    }

    private func setEnabled(_ item: PluginItem, _ want: Bool) {
        Task {
            do {
                let got = try await client.toggle(name: item.name, enabled: want)
                if let i = installed.firstIndex(where: { $0.id == item.id }) {
                    installed[i] = PluginItem(name: item.name, dir: item.dir, version: item.version,
                                              description: item.description, author: item.author,
                                              category: item.category, enabled: got, source: item.source,
                                              desktop: item.desktop, desktopOnly: item.desktopOnly,
                                              manageable: item.manageable, skills: item.skills, path: item.path)
                }
                showToast(want ? "已启用，网关重启后生效（约 30 秒）" : "已停用，网关重启后生效（约 30 秒）")
            } catch let e as PluginsError {
                showToast(e.message)
            } catch {
                showToast("操作失败，请稍后重试")
            }
        }
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { toast = "" }
        }
    }
}

// MARK: - 详情

struct PluginDetailSheet: View {
    let item: PluginItem
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var detail: PluginDetail?
    // ⚠️ 不能叫 `error`：`catch { }` 的隐式绑定就叫 error（let），赋值会报
    // 「cannot assign to value: 'error' is immutable」（CI 实踩 4.0.124 首包）
    @State private var errorText: String?
    @State private var loading = true

    private var client: PluginsClient {
        PluginsClient { method, path, bodyData in
            let body = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let (data, resp) = try await auth.request(path, method: method, body: body)
            return (data, resp.statusCode)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("概况") {
                    kv("名称", item.name)
                    if !item.version.isEmpty { kv("版本", item.version) }
                    kv("来源", item.sourceLabel)
                    kv("状态", item.enabled ? "已启用" : "未启用")
                    if let d = detail, !d.path.isEmpty { kv("目录", d.path) }
                }
                Section("能力") {
                    kv("技能", "\(detail?.skills ?? item.skills) 个")
                    if item.desktop { kv("桌面面板", "有") }
                    if let d = detail, !d.hooks.isEmpty { kv("钩子", d.hooks.joined(separator: "、")) }
                    if let d = detail, !d.deps.isEmpty { kv("依赖", d.deps.joined(separator: "、")) }
                }
                if loading {
                    Section { ProgressView() }
                } else if let e = errorText {
                    Section { Text(e).foregroundStyle(.red).font(.system(size: Typography.caption)) }
                } else if let d = detail, !d.readme.isEmpty {
                    Section("README") {
                        Text(d.readme)
                            .font(.system(size: Typography.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if let d = detail, !d.readme.isEmpty, !item.description.isEmpty {
                    Section("简介") {
                        Text(item.description).font(.system(size: Typography.caption))
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .task {
                do { detail = try await client.detail(name: item.name) }
                catch let e as PluginsError { errorText = e.message }
                catch { errorText = "详情加载失败" }
                loading = false
            }
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(k).font(.system(size: Typography.caption)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(v).font(.system(size: Typography.caption)).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 手动安装说明

struct PluginInstallHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("手动安装（已有插件）") {
                    Text("把插件目录直接拷进：")
                        .font(.system(size: Typography.caption))
                    Text("~/.hermes/plugins/<插件名>/")
                        .font(.system(size: Typography.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("只要目录里有 plugin.yaml（或 plugin.json）就会被识别；回到上一页下拉刷新即可看到。")
                        .font(.system(size: Typography.tiny)).foregroundStyle(.secondary)
                }
                Section("为什么这里显示「手动安装」") {
                    Text("从插件库安装会写一条安装记录（.install-metadata.json）；手动拷贝没有这条记录，所以单独标成「手动安装」——两者的启停方式完全一样。")
                        .font(.system(size: Typography.caption))
                }
                Section("启停与生效") {
                    Text("开关写的是 Hermes 的 config.yaml（plugins.enabled）。改动后网关会自动重启，约 30 秒生效；正在进行的对话会被打断。")
                        .font(.system(size: Typography.caption))
                }
            }
            .navigationTitle("手动安装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
    }
}
