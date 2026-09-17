import SwiftUI
import QuickLook
import UIKit

// MARK: - v3.9.32 文件管理弹窗（设置 → 文件管理）
//
// 背景：App 此前只有「上传」（ChatViewExport 的 /api/files/upload、ChatStore 的分片 /api/files/upload_chunk）
// 与「上传目录配置」（ConnSettingsView 的 /api/files/config）——传上去的文件在 App 内**没有任何地方能看到**。
// 本弹窗补上「看 / 预览 / 分享 / 重命名 / 删除」这条闭环。
//
// ── 后端契约（NAS files_api.py 只读核实 2026-09-17；/api/files 经 unified_router 9127 转发）──
//   GET  /api/files/config               → {"ok":true,"upload_dir":"<绝对路径>"}        （需鉴权）
//   GET  /api/files/list?path=<相对路径>  → {"cwd":"…","entries":[{"name","is_dir","size","mtime"}],
//                                           "dir_count":N,"file_count":M}                （需鉴权）
//   GET  /api/files/download?path=<相对>  → 原始字节（上传目录内文件匿名可读；隐藏/密钥类 403）
//   POST /api/files/delete  {path}        → {"ok":true} / {"error":"…"}（**目录会递归删除**）
//   POST /api/files/rename  {path,new_name} → {"ok":true} / {"error":"同名文件已存在"}
// path 一律相对上传目录（空串 = 上传目录根）。解析/排序/格式化等纯逻辑在 Core/FilesManagerKit.swift
// （那里有本机可跑的真值表），本文件只管渲染与请求。
//
// ── 本仓硬约束（踩过坑，别改回去）──
//   · 失败**绝不静默**（本仓刚因静默 return 被用户报「功能坏了」）：列表失败给错误态 + 重试，
//     下载/删除/重命名失败一律弹可见 alert，并带上后端返回的 error 原文。
//   · 蜂窝网络下大文件不硬试（relay 受限会「点了没反应」）→ 超 4MB 直接给明确提示让用户连 WiFi。
//   · QuickLook 只吃本地文件 → 先下载落盘（文件名净化）再预览。
//   · 下载/落盘都在 async 路径里，主线程不做同步 IO。

struct FilesManagerSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [RemoteFileEntry] = []
    @State private var cwd = ""                                   // 相对上传目录（"" = 根）
    @State private var uploadDir = ""
    @State private var countText = ""
    @State private var loading = true                             // 首屏/重试加载态（列表空时才占据内容区）
    @State private var errorText: String?                         // 列表加载失败（可见 + 可重试）
    @State private var alertText: String?                         // 操作失败/受限提示
    @State private var busyText: String?                          // 下载中 / 准备分享中
    @State private var quickLookURL: URL?
    @State private var viewerPayload: ImageViewPayload?
    @State private var renameTarget: RemoteFileEntry?
    @State private var deleteTarget: RemoteFileEntry?
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    // MARK: body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    headerCard
                    if let busy = busyText { busyCard(busy) }
                    content
                }
                .padding(Spacing.xxl)
            }
            .refreshable { await load() }
            .navigationTitle("文件管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            // 删除二次确认（目录会被后端递归删除，文案必须说清）
            .confirmationDialog("删除？", isPresented: deleteDialogOn, presenting: deleteTarget) { e in
                Button("删除", role: .destructive) {
                    let target = e
                    deleteTarget = nil
                    Haptics.press()
                    Task { await performDelete(target) }
                }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: { e in
                Text(e.isDir
                     ? "将删除文件夹「\(e.name)」及其中全部内容，删除后不可恢复。"
                     : "将删除「\(e.name)」，删除后不可恢复。")
            }
            .alert("操作未完成", isPresented: alertOn) {
                Button("好的", role: .cancel) { alertText = nil }
            } message: {
                Text(alertText ?? "")
            }
        }
        .quickLookPreview($quickLookURL)
        .sheet(item: $renameTarget) { e in
            FileRenameSheet(entry: e, existingNames: siblingNames)
                .presentationDetents([.height(320)])
        }
        // 重命名弹窗关闭后刷新（成功改名 / 取消都刷一次，代价只是一次 list）
        .onChange(of: renameTarget) { _, newValue in
            if newValue == nil { Task { await load() } }
        }
        .sheet(isPresented: $showShare, onDismiss: { shareItems = [] }) {
            ActivityShareSheet(items: shareItems)
        }
        .fullScreenCover(item: $viewerPayload) { p in
            ImageViewer(images: p.images, index: p.index)
        }
        .task { await load() }
    }

    // MARK: 卡片

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.xl) {
                Image(systemName: "folder.fill")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.indigo, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("上传目录").font(.system(size: Typography.body, weight: .medium))
                    Text(shortDir).font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: Spacing.xs)
                if !cwd.isEmpty {
                    Button {
                        Haptics.tap()
                        cwd = RemoteFiles.parentPath(cwd)
                        Task { await load() }
                    } label: {
                        Text("返回上级").pill(.page, tone: .accent)
                    }
                    .buttonStyle(PressStyle(scale: 0.9))
                }
            }
            HStack(spacing: Spacing.md) {
                if !cwd.isEmpty {
                    Text("当前：/\(cwd)")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: Spacing.xs)
                if !countText.isEmpty {
                    Text(countText).font(.system(size: Typography.tiny))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .glassListCard()
    }

    private func busyCard(_ text: String) -> some View {
        HStack(spacing: Spacing.md) {
            ProgressView().tint(.secondary)
            Text(text).font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .glassListCard()
    }

    @ViewBuilder
    private var content: some View {
        if loading && entries.isEmpty {
            loadingView
        } else if let err = errorText {
            errorView(err)
        } else if entries.isEmpty {
            emptyView
        } else {
            entryList
        }
    }

    private var loadingView: some View {
        HStack(spacing: Spacing.md) {
            ProgressView().tint(.secondary)
            Text("加载中…").font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Typography.headline))
                .foregroundStyle(.orange)
            Text("加载失败").font(.system(size: Typography.body, weight: .semibold))
            Text(message)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Haptics.tap()
                Task { await load() }
            } label: {
                Text("重试").pill(.primary, tone: .accent)
            }
            .buttonStyle(PressStyle(scale: 0.96))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, Spacing.xxl)
        .glassListCard()
    }

    private var emptyView: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "tray")
                .font(.system(size: Typography.display))
                .foregroundStyle(.tertiary)
            Text("这里还没有文件")
                .font(.system(size: Typography.body, weight: .medium))
            Text("聊天里发送的图片/文档会上传到这里\n下拉可刷新")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, Spacing.xxl)
        .glassListCard()
    }

    /// 列表（拆成独立属性：行内含 4 个闭包，塞进上方 ViewBuilder 易触发 CI 类型检查超时）
    private var entryList: some View {
        VStack(spacing: 0) {
            ForEach(entries) { e in
                VStack(spacing: 0) {
                    if e.id != entries.first?.id { Divider().padding(.leading, 52) }
                    FilesManagerRow(entry: e,
                                    onOpen: { open(e) },
                                    onShare: { share(e) },
                                    onRename: { rename(e) },
                                    onDelete: { deleteTarget = e })
                }
            }
        }
        .glassListCard()
    }

    // MARK: 派生

    /// 当前目录已有的文件名（重命名弹窗用它先查同名，省一次必然失败的请求）
    private var siblingNames: Set<String> {
        Set(entries.map { $0.name })
    }

    private var shortDir: String {
        let parts = uploadDir.split(separator: "/").filter { !$0.isEmpty }
        if parts.count >= 2 { return "…/" + parts.suffix(2).joined(separator: "/") }
        return uploadDir.isEmpty ? "读取中…" : uploadDir
    }

    private var deleteDialogOn: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var alertOn: Binding<Bool> {
        Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })
    }

    // MARK: 列表

    @MainActor
    private func load() async {
        loading = true
        errorText = nil
        // 上传目录只在首次/路径为空时读（失败不影响列表，header 显示"读取中…"）
        if uploadDir.isEmpty, let j = try? await auth.json("/api/files/config") {
            uploadDir = (j["upload_dir"] as? String) ?? ""
        }
        let q = cwd.isEmpty
            ? "/api/files/list"
            : "/api/files/list?path=" + RemoteFiles.queryEncoded(cwd)
        do {
            let j = try await auth.json(q)
            // 响应必须是 {"entries":[…]}; 形状不对按失败提示（不静默退化成"空目录"）
            // 用 `as?` 绑定数组（`obj["entries"]` 是 Any?，条件绑定直接拿到底层 [[String: Any]]）
            guard let rawEntries = j["entries"] as? [[String: Any]] else {
                errorText = "目录数据格式异常，请稍后重试"
                loading = false
                return
            }
            entries = RemoteFiles.parseEntries(rawEntries, parent: cwd)
            countText = RemoteFiles.countText(
                dir: RemoteFiles.intValue(j["dir_count"]),
                file: RemoteFiles.intValue(j["file_count"])
            )
            loading = false
        } catch {
            errorText = filesFailureReason(error)
            loading = false
        }
    }

    // MARK: 打开 / 预览

    private func open(_ e: RemoteFileEntry) {
        Haptics.tap()
        if e.isDir {
            cwd = e.path
            Task { await load() }
            return
        }
        let kind = RemoteFiles.previewKind(forName: e.name)
        guard kind != .unsupported else {
            Haptics.error()
            alertText = "「.\(RemoteFiles.ext(e.name))」暂不支持 App 内预览，可用右侧「…」里的分享发给其他 App 打开"
            return
        }
        guard RemoteFiles.cellularDownloadAllowed(bytes: e.size) else {
            Haptics.error()
            alertText = "蜂窝网络下大文件下载受限（\(RemoteFiles.humanSize(e.size))），请连接 WiFi 后重试"
            return
        }
        busyText = "下载中… \(RemoteFiles.humanSize(e.size))"
        Task { await openFile(e, kind: kind) }
    }

    @MainActor
    private func openFile(_ e: RemoteFileEntry, kind: FilePreviewKind) async {
        defer { busyText = nil }
        guard let data = await download(e) else { return }
        if kind == .image {
            guard let img = UIImage(data: data) else {
                await MainActor.run { Haptics.error() }
                alertText = "图片解码失败，文件可能已损坏"
                return
            }
            viewerPayload = ImageViewPayload(images: [img], index: 0)
            return
        }
        guard let url = writeTemp(data, name: e.name) else {
            await MainActor.run { Haptics.error() }
            alertText = "本地临时文件写入失败，无法预览（可尝试分享）"
            return
        }
        quickLookURL = url
    }

    // MARK: 分享

    private func share(_ e: RemoteFileEntry) {
        Haptics.tap()
        if e.isDir {
            Haptics.error()
            alertText = "文件夹暂不支持分享，进入文件夹后逐个分享文件"
            return
        }
        guard RemoteFiles.cellularDownloadAllowed(bytes: e.size) else {
            Haptics.error()
            alertText = "蜂窝网络下大文件下载受限（\(RemoteFiles.humanSize(e.size))），请连接 WiFi 后重试"
            return
        }
        busyText = "准备分享… \(RemoteFiles.humanSize(e.size))"
        Task { await prepareShare(e) }
    }

    @MainActor
    private func prepareShare(_ e: RemoteFileEntry) async {
        defer { busyText = nil }
        guard let data = await download(e) else { return }
        guard let url = writeTemp(data, name: e.name) else {
            await MainActor.run { Haptics.error() }
            alertText = "本地临时文件写入失败，无法分享"
            return
        }
        shareItems = [url]
        showShare = true
    }

    // MARK: 重命名 / 删除

    private func rename(_ e: RemoteFileEntry) {
        Haptics.tap()
        renameTarget = e
    }

    @MainActor
    private func performDelete(_ e: RemoteFileEntry) async {
        busyText = e.isDir ? "删除文件夹…" : "删除中…"
        defer { busyText = nil }
        do {
            let j = try await auth.json("/api/files/delete", method: "POST", body: ["path": e.path])
            if (j["ok"] as? Bool) == true {
                await MainActor.run { Haptics.success() }
                await load()
            } else {
                await MainActor.run { Haptics.error() }
                alertText = "删除失败：" + ((j["error"] as? String) ?? "服务端未确认成功")
            }
        } catch {
            await MainActor.run { Haptics.error() }
            alertText = "删除失败：" + filesFailureReason(error)
        }
    }

    // MARK: 下载 / 落盘

    /// 下载一个条目（上传目录内的文件匿名可读，但走 auth.downloadFile 统一分流：
    /// WiFi 直连 URLSession / 蜂窝 relay，并带上 X-Auth-Token）
    @MainActor
    private func download(_ e: RemoteFileEntry) async -> Data? {
        let q = "/api/files/download?path=" + RemoteFiles.queryEncoded(e.path)
        let cellular = NetworkMonitor.shared.isCellular
        do {
            let (data, code) = try await auth.downloadFile(q)
            if (200..<300).contains(code), !data.isEmpty { return data }
            await MainActor.run { Haptics.error() }
            if code == 404 {
                alertText = "文件不存在，可能已被删除" + (cellular ? "（当前为蜂窝网络）" : "")
            } else if code == 403 {
                alertText = "该文件不允许下载"
            } else {
                alertText = "下载失败（HTTP \(code)）"
                    + (cellular ? "，蜂窝网络受限，建议连 WiFi 重试" : "")
            }
            return nil
        } catch {
            await MainActor.run { Haptics.error() }
            alertText = "下载失败：" + filesFailureReason(error)
                + (cellular ? "（蜂窝网络受限，建议连 WiFi 重试）" : "")
            return nil
        }
    }

    /// 数据落本地临时目录（文件名净化：防后端下发的名字带路径分隔符写到别处）
    private func writeTemp(_ data: Data, name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("files_manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(RemoteFiles.safeLocalName(name))
        try? FileManager.default.removeItem(at: dst)   // 覆盖同名旧临时文件，防临时目录堆积
        do {
            try data.write(to: dst, options: .atomic)
            return dst
        } catch {
            return nil
        }
    }

}

// MARK: - 错误文案（REST 非 2xx 时 auth.request/json 会抛 APIError，后端的 error 原文拿不到 → 按状态码给原因）

private func filesFailureReason(_ error: Error) -> String {
    guard let api = error as? APIError else { return error.localizedDescription }
    switch api {
    case .unauthorized: return "登录已过期，请重新登录后重试"
    case .badURL: return "服务器地址无效"
    case .badResponse, .badResponseDetail: return "服务器响应异常"
    case .badJSON: return "服务器响应无法解析"
    case .timeout, .timeoutDetail: return "请求超时，请检查网络"
    case .relayCancelled: return "请求已取消"
    case .server(403): return "没有权限操作该文件（路径超出允许范围）"
    case .server(404): return "文件不存在，可能已被删除"
    case .server(500): return "服务器处理失败，请稍后重试"
    case .server(let code): return "服务器返回 \(code)"
    }
}

// MARK: - 条目行（独立小 struct：不塞进上方 ViewBuilder，避免 CI 类型检查超时）

private struct FilesManagerRow: View {
    let entry: RemoteFileEntry
    var onOpen: () -> Void
    var onShare: () -> Void
    var onRename: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xl) {
            Button(action: onOpen) {
                HStack(spacing: Spacing.xl) {
                    iconBlock
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(entry.name)
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(subtitle)
                            .font(.system(size: Typography.tiny))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.98))

            Menu {
                if !entry.isDir {
                    Button { onOpen() } label: { Label("预览", systemImage: "eye") }
                }
                Button { onShare() } label: { Label("分享", systemImage: "square.and.arrow.up") }
                Button { onRename() } label: { Label("重命名", systemImage: "pencil") }
                Button(role: .destructive) { onDelete() } label: { Label("删除", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: Typography.title))
                    .foregroundStyle(.tertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var subtitle: String {
        if entry.isDir { return "文件夹 · " + RemoteFiles.modifiedText(entry.mtime) }
        return RemoteFiles.humanSize(entry.size) + " · " + RemoteFiles.modifiedText(entry.mtime)
    }

    private var iconBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.icon, style: .continuous)
                .fill(color.opacity(Tint.soft))
            Image(systemName: icon)
                .font(.system(size: Typography.title))
                .foregroundStyle(color)
        }
        .frame(width: 38, height: 38)
    }

    private var icon: String {
        if entry.isDir { return "folder.fill" }
        switch RemoteFiles.ext(entry.name) {
        case "pdf": return "doc.richtext.fill"
        case "csv", "xlsx": return "tablecells.fill"
        case "md", "txt", "log": return "doc.plaintext.fill"
        case "json": return "curlybraces"
        case "jpg", "jpeg", "png", "gif", "webp", "heic": return "photo.fill"
        default: return "doc.fill"
        }
    }

    private var color: Color {
        if entry.isDir { return .indigo }
        switch RemoteFiles.ext(entry.name) {
        case "pdf": return .red
        case "csv", "xlsx": return .green
        case "md", "txt", "log": return .gray
        case "json": return .orange
        case "jpg", "jpeg", "png", "gif", "webp", "heic": return .blue
        default: return .blue
        }
    }
}

// MARK: - 重命名弹窗（独立小 struct；自带请求与错误显示，关闭后由父视图刷新列表）

private struct FileRenameSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    let entry: RemoteFileEntry
    /// 当前目录已有的文件名（本地先挡同名，省一次必然失败的请求）
    let existingNames: Set<String>

    @State private var name = ""
    @State private var saving = false
    @State private var errorText: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var unchanged: Bool { trimmed == entry.name }
    private var duplicated: Bool { !unchanged && existingNames.contains(trimmed) }

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Text("重命名")
                .font(.system(size: Typography.title, weight: .bold))
                .padding(.top, 20)
            Text(entry.isDir ? "文件夹「\(entry.name)」" : "文件「\(entry.name)」")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 30)

            TextField("新的名称", text: $name)
                .font(.system(size: Typography.body))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(Spacing.xl)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                .padding(.horizontal, 20)

            if let err = errorText {
                Text(err)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            } else if duplicated {
                Text("同名文件已存在，换个名字")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.orange)
            }

            Button {
                save()
            } label: {
                Text(saving ? "保存中…" : "保存")
                    .font(.system(size: Typography.body, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xl)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(saving || trimmed.isEmpty || unchanged || duplicated)
            .opacity(saving || trimmed.isEmpty || unchanged || duplicated ? 0.5 : 1)
            .padding(.horizontal, 20)

            Button("取消") { dismiss() }
                .font(.system(size: Typography.body))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .onAppear { name = entry.name }
    }

    private func save() {
        let newName = trimmed
        guard !newName.isEmpty, !saving else { return }
        if duplicated {
            Haptics.error()
            errorText = "同名文件已存在"
            return
        }
        saving = true
        errorText = nil
        Task {
            defer { saving = false }
            do {
                let j = try await auth.json("/api/files/rename", method: "POST",
                                            body: ["path": entry.path, "new_name": newName])
                if (j["ok"] as? Bool) == true {
                    await MainActor.run { Haptics.success() }
                    dismiss()
                } else {
                    await MainActor.run { Haptics.error() }
                    errorText = (j["error"] as? String) ?? "重命名失败"
                }
            } catch {
                await MainActor.run { Haptics.error() }
                errorText = "重命名失败：" + filesFailureReason(error)
            }
        }
    }
}
