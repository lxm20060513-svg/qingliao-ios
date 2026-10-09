// v4.0.x 网盘文件浏览（设置 → 网盘接入 → 点已接入网盘行）
//
// 与 FilesManagerSheet（上传目录）并列的第二套浏览：数据走 /api/clouddrive/list|download，
// 后端 clouddrive_api.py 调网盘官方 CLI。目录用 fid 栈而不是路径串——网盘侧只有 fid
// 概念，返回上一级必须靠栈回退，不能像上传目录那样拼字符串。
//
// ── 本仓硬约束（与 FilesManagerSheet 同）──
//   · 失败绝不静默：列表失败给错误态 + 重试，下载失败弹可见 alert 并带后端 error 原文。
//   · 蜂窝网络下大文件不硬试：超 4MB 直接提示连 WiFi（relay 受限会「点了没反应」）。
//   · QuickLook 只吃本地文件 → 先下载落盘（文件名净化）再预览。
//   · 加载代际：下拉刷新 / 返回上级 / 首载会各自发起 load()，只有最后一次结论算数。

import SwiftUI
// ⚠️ .quickLookPreview 是 QuickLook 框架的 View 扩展，不 import 直接 Archive 编译失败（本仓其它使用点都带这一行）
import QuickLook

// MARK: - 数据模型

struct CloudDriveEntry: Identifiable, Hashable {
    let fid: String
    let name: String
    let isDir: Bool
    let size: Int
    let mtime: Int

    var id: String { "\(fid)|\(name)" }

    init(_ d: [String: Any]) {
        fid = d["fid"] as? String ?? ""
        name = d["name"] as? String ?? ""
        isDir = (d["is_dir"] as? Bool) ?? false
        size = (d["size"] as? Int) ?? 0
        mtime = (d["mtime"] as? Int) ?? 0
    }
}

// MARK: - 浏览页

struct CloudDriveBrowserSheet: View {
    let drive: CloudDriveItem

    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [CloudDriveEntry] = []
    /// 目录栈：根为 "0"，push 子目录 fid，pop 回上一级（网盘只有 fid，不能拼路径）
    @State private var stack: [String] = ["0"]
    @State private var loadSeq = 0
    @State private var countText = ""
    @State private var loading = true
    @State private var errorText: String?
    @State private var alertText: String?
    @State private var busyText: String?
    @State private var quickLookURL: URL?
    @State private var viewerPayload: ImageViewPayload?
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    /// 下载/预览/分享的在途 Task：关页必须取消，否则下载完还会去写 quickLookURL/viewerPayload
    /// → 表现是「浏览页已经关了，图片查看器又自己弹出来」
    @State private var fileTasks: [Task<Void, Never>] = []

    private var currentFid: String { stack.last ?? "0" }
    private var canGoUp: Bool { stack.count > 1 }

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
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("操作未完成", isPresented: alertOn) {
                Button("好的", role: .cancel) { alertText = nil }
            } message: {
                Text(alertText ?? "")
            }
            .quickLookPreview($quickLookURL)
            .sheet(isPresented: $showShare, onDismiss: { shareItems = [] }) {
                ActivityShareSheet(items: shareItems)
            }
            .fullScreenCover(item: $viewerPayload) { p in
                ImageViewer(images: p.images, index: p.index)
            }
            .task { await load() }
            .onDisappear {
                for t in fileTasks { t.cancel() }
                fileTasks.removeAll()
            }
        }
    }

    private var displayName: String {
        drive.name.isEmpty ? drive.id : drive.name
    }

    // MARK: 卡片

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.xl) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.teal, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(displayName).font(.system(size: Typography.body, weight: .medium))
                    Text(drive.nickname.isEmpty ? "已授权" : "已授权 · \(drive.nickname)")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: Spacing.xs)
                if canGoUp {
                    Button {
                        Haptics.tap()
                        stack.removeLast()
                        Task { await load() }
                    } label: {
                        Text("返回上级").pill(.page, tone: .accent)
                    }
                    .buttonStyle(PressStyle(scale: 0.9))
                }
            }
            if !countText.isEmpty {
                Text(countText)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .pastelCard()
    }

    private func busyCard(_ text: String) -> some View {
        HStack(spacing: Spacing.md) {
            ProgressView().tint(.secondary)
            Text(text).font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .pastelCard()
    }

    @ViewBuilder
    private var content: some View {
        if loading && entries.isEmpty {
            HStack(spacing: Spacing.md) {
                ProgressView().tint(.secondary)
                Text("加载中…").font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if entries.isEmpty, let err = errorText {
            ErrorStateView(title: "加载失败", detail: err) { Task { await load() } }
                .padding(.horizontal, Spacing.xxl)
                .pastelCard()
        } else if entries.isEmpty {
            emptyView
        } else {
            // 刷新失败不覆盖已加载列表，只挂一条可重试提示
            if let err = errorText { refreshFailedNotice(err) }
            entryList
        }
    }

    private func refreshFailedNotice(_ message: String) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("刷新失败").font(.system(size: Typography.subhead, weight: .semibold))
                Text(message)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Spacing.xs)
            Button {
                Haptics.tap()
                Task { await load() }
            } label: {
                Text("重试").pill(.primary, tone: .accent)
            }
            .buttonStyle(PressStyle(scale: 0.96))
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .pastelCard()
    }

    private var emptyView: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "tray")
                .font(.system(size: Typography.display))
                .foregroundStyle(.tertiary)
            Text("这个目录是空的")
                .font(.system(size: Typography.body, weight: .medium))
            Text("下拉可刷新")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, Spacing.xxl)
        .pastelCard()
    }

    private var entryList: some View {
        VStack(spacing: 0) {
            ForEach(entries) { e in
                entryRow(e)
                if e.id != entries.last?.id {
                    Divider().padding(.leading, Spacing.rowDividerInset)
                }
            }
        }
        .pastelCard()
    }

    private func entryRow(_ e: CloudDriveEntry) -> some View {
        HStack(spacing: Spacing.lg) {
            // v4.0.83（用户：「app 里面小图标请统一用圆角多彩图标统一风格」）：
            // 行首图标统一成「圆角色块 + 白符号」（与 SettingRow / 首页卡片同款：28pt + Radius.icon）。
            Image(systemName: e.isDir ? "folder.fill" : iconFor(e.name))
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(e.isDir ? Color.teal : Color.indigo,
                            in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(e.name)
                    .font(.system(size: Typography.body))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Spacing.xs) {
                    if !e.isDir { Text(RemoteFiles.humanSize(e.size)) }
                    if e.mtime > 0 { Text(timeText(e.mtime)) }
                }
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: Spacing.xs)
            Image(systemName: "chevron.right")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .contentShape(Rectangle())
        .onTapGesture { tap(e) }
        .contextMenu {
            if !e.isDir {
                Button { preview(e) } label: { Label("预览", systemImage: "eye") }
                Button { share(e) } label: { Label("分享", systemImage: "square.and.arrow.up") }
            }
        }
    }

    private func iconFor(_ name: String) -> String {
        let k = RemoteFiles.previewKind(forName: name)
        switch k {
        case .image:      return "photo"
        case .quickLook:  return "doc.text"
        case .unsupported: return "doc"
        }
    }

    private func timeText(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: 交互

    private func tap(_ e: CloudDriveEntry) {
        Haptics.tap()
        if e.isDir {
            stack.append(e.fid)
            Task { await load() }
        } else {
            preview(e)
        }
    }

    private func preview(_ e: CloudDriveEntry) {
        guard !e.isDir else { return }
        // 与上传目录同一口径：App 内不认识的格式直接说清「只能分享」，别让用户对着没反应的点击猜
        guard RemoteFiles.previewKind(forName: e.name) != .unsupported else {
            Haptics.error()
            alertText = "「.\(RemoteFiles.ext(e.name))」暂不支持 App 内预览，可长按后用「分享」发给其他 App 打开"
            return
        }
        guard RemoteFiles.cellularDownloadAllowed(bytes: e.size) else {
            Haptics.error()
            alertText = "蜂窝网络下大文件下载受限（\(RemoteFiles.humanSize(e.size))），请连接 WiFi 后重试"
            return
        }
        busyText = "下载中… \(RemoteFiles.humanSize(e.size))"
        // 同一时刻只留一个在途任务：连点两个文件时先完成的那个会提前清掉 busyText
        for t in fileTasks { t.cancel() }
        fileTasks = [Task { await openFile(e) }]
    }

    private func share(_ e: CloudDriveEntry) {
        guard !e.isDir else {
            Haptics.error()
            alertText = "文件夹暂不支持分享，进目录后逐个分享文件"
            return
        }
        guard RemoteFiles.cellularDownloadAllowed(bytes: e.size) else {
            Haptics.error()
            alertText = "蜂窝网络下大文件下载受限（\(RemoteFiles.humanSize(e.size))），请连接 WiFi 后重试"
            return
        }
        busyText = "准备分享… \(RemoteFiles.humanSize(e.size))"
        for t in fileTasks { t.cancel() }
        fileTasks = [Task { await prepareShare(e) }]
    }

    @MainActor
    private func openFile(_ e: CloudDriveEntry) async {
        defer { busyText = nil }
        guard !Task.isCancelled else { return }
        guard let data = await download(e) else { return }
        guard !Task.isCancelled else { return }
        if RemoteFiles.previewKind(forName: e.name) == .image {
            guard let img = UIImage(data: data) else {
                Haptics.error()
                alertText = "图片解码失败，文件可能已损坏"
                return
            }
            viewerPayload = ImageViewPayload(images: [img], index: 0)
            return
        }
        guard let url = writeTemp(data, name: e.name) else {
            Haptics.error()
            alertText = "本地临时文件写入失败，无法预览（可尝试分享）"
            return
        }
        quickLookURL = url
    }

    @MainActor
    private func prepareShare(_ e: CloudDriveEntry) async {
        defer { busyText = nil }
        guard !Task.isCancelled else { return }
        guard let data = await download(e) else { return }
        guard !Task.isCancelled else { return }
        guard let url = writeTemp(data, name: e.name) else {
            Haptics.error()
            alertText = "本地临时文件写入失败，无法分享"
            return
        }
        shareItems = [url]
        showShare = true
    }

    // MARK: 网络

    @MainActor
    private func load() async {
        let seq = loadSeq + 1
        loadSeq = seq
        loading = true
        defer { if loadSeq == seq { loading = false } }
        let fid = currentFid
        do {
            let d = try await auth.json("/api/agent/clouddrive/list?drive=\(RemoteFiles.queryEncoded(drive.id))&fid=\(RemoteFiles.queryEncoded(fid))")
            guard loadSeq == seq else { return }   // 晚到的旧代际结论丢弃
            guard let ok = d["ok"] as? Bool, ok else {
                // 已有列表时不覆盖（保留用户正在看的内容），错误只追加可见提示
                if entries.isEmpty {
                    errorText = d["error"] as? String ?? "读取网盘文件失败"
                } else {
                    errorText = (errorText.map { $0 + "\n" } ?? "") + (d["error"] as? String ?? "读取网盘文件失败")
                }
                return
            }
            var arr: [CloudDriveEntry] = []
            if let list = d["entries"] as? [[String: Any]] {
                for x in list { arr.append(CloudDriveEntry(x)) }
            }
            // 目录在前、文件在后，各自按名称排（后端顺序不定）
            arr.sort { a, b in
                if a.isDir != b.isDir { return a.isDir }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            entries = arr
            errorText = nil
            let dirs = arr.filter(\.isDir).count
            let files = arr.count - dirs
            countText = "\(dirs) 个文件夹 · \(files) 个文件"
        } catch {
            if loadSeq != seq { return }
            errorText = "加载失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func download(_ e: CloudDriveEntry) async -> Data? {
        var q = "/api/agent/clouddrive/download?drive=\(RemoteFiles.queryEncoded(drive.id))"
        q += "&fid=\(RemoteFiles.queryEncoded(e.fid))&name=\(RemoteFiles.queryEncoded(e.name))"
        let cellular = NetworkMonitor.shared.isCellular
        do {
            let (data, code) = try await auth.downloadFile(q)
            if (200..<300).contains(code), !data.isEmpty { return data }
            Haptics.error()
            if code == 404 {
                alertText = "文件不存在，可能已被删除" + (cellular ? "（当前为蜂窝网络）" : "")
            } else if code == 403 {
                alertText = "该文件不允许下载"
            } else {
                alertText = "下载失败（HTTP \(code)）" + (cellular ? "，蜂窝网络受限，建议连 WiFi 重试" : "")
            }
            return nil
        } catch {
            Haptics.error()
            alertText = "下载失败：\(error.localizedDescription)"
                + (cellular ? "（蜂窝网络受限，建议连 WiFi 重试）" : "")
            return nil
        }
    }

    /// 数据落本地临时目录（文件名净化：防网盘下发的名字带路径分隔符写到别处）
    private func writeTemp(_ data: Data, name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clouddrive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(RemoteFiles.safeLocalName(name))
        try? FileManager.default.removeItem(at: dst)
        do {
            try data.write(to: dst)
            return dst
        } catch {
            return nil
        }
    }

    private var alertOn: Binding<Bool> {
        Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })
    }
}
