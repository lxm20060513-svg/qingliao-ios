// 本文件由 2026-09-27 工程治理「Settings 物理合并」生成：多份同域设置页文件合并为一，
// UI 入口与行为零改动，仅文件边界变化。合并前各文件的来源见下方 MARK 分段。

import Combine
import Foundation
import LocalAuthentication
import PDFKit
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: ===== 以下原为 Features/Settings/FilesManagerSheet.swift =====

// MARK: - v3.9.32 文件管理弹窗（设置 → 文件管理）
//
// 背景：App 此前只有「上传」（ChatViewExport 的 /api/files/upload、ChatStore 的分片 /api/files/upload_chunk）
// 与「上传目录配置」（ConnSettingsView 的 /api/files/config）——传上去的文件在 App 内**没有任何地方能看到**。
// 本弹窗补上「看 / 预览 / 分享 / 重命名 / 删除」这条闭环。
//
// ── 后端契约（NAS files_api.py 只读核实 2026-09-17；/api/files 经 unified_router 9127 转发）──
//   GET  /api/files/config               → {"ok":true,"upload_dir":"<绝对路径>"}        （需鉴权）
//   POST /api/files/list {path}           → 同上（v4.0.114 起 App 走这条：蜂窝下带 query 的 GET 会挂）
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
    /// v3.9.38：加载代际。下拉刷新 / 首载 / 返回上级 / 删除后回读会各自发起 load()，
    /// 用序号保证「只有最后一次的结论算数」——否则晚到的失败会把已到手的成功结果顶掉（用户看到假的「加载失败」）
    @State private var loadSeq = 0
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
    /// v4.0.102：被删那一行的全局 frame —— 删除确认从**行的位置**长出
    /// （原走 confirmationDialog，iPhone 上系统固定从屏幕底部升起，锚不到行）
    @State private var deleteAnchor: CGRect = .zero
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    /// v4.0.114（用户「文件管理增加批量删除」）：选择态 + 已勾集合。
    /// 存 `path` 而不是整条 entry —— 回读后条目对象会换新，path 仍能对上。
    @State private var selecting = false
    @State private var picked: Set<String> = []
    @State private var confirmBatchDelete = false

    // MARK: body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    headerCard
                    if let busy = busyText { RemoteBusyCard(text: busy) }
                    content
                }
                .padding(Spacing.xxl)
            }
            .refreshable { await load() }
            .navigationTitle("文件管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // v4.0.114（批量删除）：选择态下左边这颗让位给「取消」——
                    // 否则用户一点就把整个弹窗关掉，勾的全白勾。
                    if selecting {
                        Button("取消") { selectedExit() }
                    } else {
                        Button("完成") { dismiss() }
                    }
                }
                // 批量删除入口：非选择态露「选择」，选择态露「删除(N)」（一项没勾就禁用）
                ToolbarItem(placement: .topBarTrailing) {
                    if selecting {
                        Button(role: .destructive) {
                            confirmBatchDelete = true
                        } label: {
                            Text(picked.isEmpty ? "删除" : "删除(\(picked.count))")
                        }
                        .disabled(picked.isEmpty)
                    } else if !entries.isEmpty {
                        Button("选择") { selectedEnter() }
                    }
                }
            }
            // v4.0.102：删除二次确认（目录会被后端递归删除，文案必须说清）—— 从 confirmationDialog
            // **改为锚定浮层**：iPhone 上系统动作表固定从屏幕底部升起，锚不到被删那一行（用户 2026-10-12 报同款）。
            // 浮层挂在 sheet 内容层（这里就是本 sheet 的最外层），不会被列表行盖住。
            .overlay {
                if let e = deleteTarget {
                    AnchorMenuOverlay(
                        anchorFrame: deleteAnchor,
                        items: [
                            AnchorMenuItem(id: "del", title: "删除", icon: "trash",
                                           color: .red, destructive: true),
                            AnchorMenuItem(id: "cancel", title: "取消", icon: "xmark", color: .gray),
                        ],
                        title: "删除？",
                        message: e.isDir
                            ? "将删除文件夹「\(e.name)」及其中全部内容，删除后不可恢复。"
                            : "将删除「\(e.name)」，删除后不可恢复。",
                        onPick: { item in
                            let target = deleteTarget
                            deleteTarget = nil
                            if item.id == "del", let t = target {
                                Haptics.press()
                                Task { await performDelete(t) }
                            }
                        },
                        onClose: { deleteTarget = nil }
                    )
                }
            }
            // v4.0.114（审查 P1）：**单条 alert 承载两种来源** —— 错误提示 与 批量删除确认。
            // 同一视图挂两个 `.alert` 在旧系统上只有最后一个生效（与本批 WorkspaceView 的口径一致），
            // 而「操作未完成」排在前面 → 一旦只认最后一个，批量删部分失败时用户会**毫无提示**、
            // 以为全部删掉了（`alertText` 正是那条唯一可见反馈）。文案随来源动态切。
            .alert(confirmBatchDelete ? "删除 \(picked.count) 项？" : "操作未完成",
                   isPresented: alertPresented) {
                if confirmBatchDelete {
                    Button("取消", role: .cancel) {}
                    Button("删除", role: .destructive) {
                        Haptics.press()
                        Task { await performBatchDelete() }
                    }
                } else {
                    Button("好的", role: .cancel) { alertText = nil }
                }
            } message: {
                Text(confirmBatchDelete
                     ? "删除后不可恢复。选中的文件夹会连同里面的全部内容一起删掉。"
                     : (alertText ?? ""))
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
        .pastelCard()
    }

    @ViewBuilder
    private var content: some View {
        if loading && entries.isEmpty {
            RemoteLoadingView()
        } else if entries.isEmpty, let err = errorText {
            // 没有任何内容可显示 → 整块错误态（带重试）
            errorView(err)
        } else if entries.isEmpty {
            emptyView
        } else {
            // v3.9.38：列表已有内容时，刷新失败**不覆盖列表**（原来整块被错误态顶掉，
            // 用户看到的就是「一下拉刷新就提示加载失败」），只在列表上方挂一条可重试的提示
            if let err = errorText { RemoteRefreshFailedNotice(message: err) { Task { await load() } } }
            entryList
        }
    }

    private func errorView(_ message: String) -> some View {
        // v3.9.42：收口到 ErrorStateView（本函数即其原型，参数一字未改，只把卡片外壳留在调用侧）
        ErrorStateView(title: "加载失败", detail: message) {
            Task { await load() }
        }
        .padding(.horizontal, Spacing.xxl)
        .pastelCard()
    }

    private var emptyView: some View {
        RemoteEmptyView(title: "这里还没有文件",
                        subtitle: "聊天里发送的图片/文档会上传到这里\n下拉可刷新")
    }

    /// 列表（拆成独立属性：行内含 4 个闭包，塞进上方 ViewBuilder 易触发 CI 类型检查超时）
    private var entryList: some View {
        VStack(spacing: 0) {
            ForEach(entries) { e in
                VStack(spacing: 0) {
                    if e.id != entries.first?.id { Divider().padding(.leading, Spacing.rowDividerInset) }
                    FilesManagerRow(entry: e,
                                    onOpen: { open(e) },
                                    onShare: { share(e) },
                                    onRename: { rename(e) },
                                    onDelete: { rect in
                                        deleteAnchor = rect
                                        deleteTarget = e
                                    },
                                    selecting: selecting,
                                    isPicked: picked.contains(e.path),
                                    onTogglePick: { togglePick(e) })
                }
            }
        }
        .pastelCard()
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

    // v4.0.102：`deleteDialogOn`（confirmationDialog 的 isPresented Binding）已随锚定浮层改造删除 ——
    // 浮层的显隐由 `if let e = deleteTarget` 直接决定，不再需要 Bool 桥。

    /// v4.0.114（审查 P1）：单条 alert 的呈现开关 —— 错误提示 与 批量确认 共用一条（见上面 `.alert`）。
    /// 关闭时把两个来源都复位，避免残留导致下次误弹。
    /// v4.0.114（审查 P1）：同视图**只挂一条** `.alert` —— 旧系统上挂两条只有最后一条生效，
    /// 而「操作未完成」正是批量删失败时唯一的可见反馈，排在前面会被吞。这里按来源切文案与动作。
    /// v4.0.114（复核 P2）：关闭时**只清本次呈现的那个来源** ——
    /// 两个一起清会把弹窗期间并发的失败提示（打开/分享/下载失败）永久吞掉：用户点「取消」后
    /// 那条提示再也不会重新呈现。留另一个存活，下一帧 getter 恒真会自动重新呈现。
    private var alertPresented: Binding<Bool> {
        Binding(
            get: { alertText != nil || confirmBatchDelete },
            set: { if !$0 {
                if confirmBatchDelete { confirmBatchDelete = false } else { alertText = nil }
            } }
        )
    }

    // MARK: 列表

    @MainActor
    private func load() async {
        // v3.9.38：代际护栏（见 loadSeq 注释）。SwiftUI 在弹窗 dismiss / 回收刷新控件时会取消
        // 刷新那次 Task —— 取消不是加载失败，绝不能据此画「加载失败」错误态。
        loadSeq &+= 1
        let seq = loadSeq
        loading = true
        errorText = nil
        // 上传目录只在首次/路径为空时读（失败不影响列表，header 显示"读取中…"）
        if uploadDir.isEmpty, let j = try? await auth.json("/api/files/config") {
            uploadDir = (j["upload_dir"] as? String) ?? ""
        }
        // v4.0.114（用户「让弱网更稳」）：改 POST —— 后端 v4.0.110 就备好了 POST 分支
        //（原注释：iOS 蜂窝直连「带 query 的 GET」会静默挂 10s 超时），前端却一直还在用 GET ?path=。
        do {
            let j = try await auth.json("/api/files/list", method: "POST", body: ["path": cwd])
            guard seq == loadSeq else { return }      // 已有更新的一轮在跑/跑完 → 丢弃本次结果
            // 响应必须是 {"entries":[…]}; 形状不对按失败提示（不静默退化成"空目录"）
            // 用 `as?` 绑定数组（`obj["entries"]` 是 Any?，条件绑定直接拿到底层 [[String: Any]]）
            guard let rawEntries = j["entries"] as? [[String: Any]] else {
                errorText = "目录数据格式异常，请稍后重试"
                loading = false
                return
            }
            entries = RemoteFiles.parseEntries(rawEntries, parent: cwd)
            // v4.0.114（批量删除）：进目录 / 回读后丢掉已不在当前目录的勾选 —— 否则会把「上一层的选择」带下来删
            picked = picked.intersection(Set(entries.map { $0.path }))
            countText = RemoteFiles.countText(
                dir: RemoteFiles.intValue(j["dir_count"]),
                file: RemoteFiles.intValue(j["file_count"])
            )
            errorText = nil          // 成功即清账（原实现只在开头清 → 一次失败会一直盖着后来的成功结果）
            loading = false
        } catch {
            guard seq == loadSeq else { return }
            loading = false
            if Self.isCancellation(error) { return }   // 被取消（关弹窗/回收刷新控件）不是失败
            errorText = RemoteFiles.failureReason(error)
        }
    }

    /// 取消类错误判定：`CancellationError`（SwiftUI 取消 Task）与 `URLError.cancelled`(-999)
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let u = error as? URLError, u.code == .cancelled { return true }
        return false
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
        guard let url = RemoteFiles.writeTemp(data, name: e.name) else {
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
        guard let url = RemoteFiles.writeTemp(data, name: e.name) else {
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

    // MARK: 批量删除（v4.0.114 用户「文件管理增加批量删除」）

    private func selectedEnter() {
        Haptics.tap()
        selecting = true
        picked = []
    }

    private func selectedExit() {
        selecting = false
        picked = []
    }

    private func togglePick(_ e: RemoteFileEntry) {
        Haptics.tap()
        if picked.contains(e.path) {
            picked.remove(e.path)
        } else {
            picked.insert(e.path)
        }
    }

    /// 逐个走单删接口（后端 /api/files/delete 一次认一个）。中途失败**不中断**：
    /// 已删掉的算删掉，失败项收进提示 —— 比整体回滚更贴近用户预期（他不想「删了一半还全留着」）。
    @MainActor
    private func performBatchDelete() async {
        let targets = entries.filter { picked.contains($0.path) }
        guard !targets.isEmpty else { return }
        busyText = "删除 \(targets.count) 项…"
        defer { busyText = nil }
        var failed: [String] = []
        for e in targets {
            do {
                let j = try await auth.json("/api/files/delete", method: "POST", body: ["path": e.path])
                if (j["ok"] as? Bool) != true {
                    failed.append(e.name + "：" + ((j["error"] as? String) ?? "服务端未确认成功"))
                }
            } catch {
                failed.append(e.name + "：" + RemoteFiles.failureReason(error))
            }
        }
        if failed.isEmpty {
            Haptics.success()
        } else {
            Haptics.error()
            let head = failed.prefix(3).joined(separator: "\n")
            alertText = "有 \(failed.count) 项没删掉：\n" + head
                + (failed.count > 3 ? "\n…还有 \(failed.count - 3) 项" : "")
        }
        selecting = false
        picked = []
        await load()                                  // 成败都回读：删掉的不该还挂在列表上
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
            alertText = "删除失败：" + RemoteFiles.failureReason(error)
        }
    }

    // MARK: 下载 / 落盘

    /// 下载一个条目（上传目录内的文件匿名可读，但走 auth.downloadFile 统一分流：
    /// WiFi 直连 URLSession / 蜂窝 relay，并带上 X-Auth-Token）
    /// #17：网络 + 失败文案收归 `RemoteFiles.fetchData` 共享实现（设置页「文件」与聊天成品文件卡同一真源，
    /// 行为逐字不变：仍是 `alertText = 失败文案`）。
    @MainActor
    private func download(_ e: RemoteFileEntry) async -> Data? {
        switch await RemoteFiles.fetchData(auth, path: e.path, cellular: NetworkMonitor.shared.isCellular) {
        case .success(let data):
            return data
        case .failure(let reason):
            alertText = reason.message
            return nil
        }
    }

}

// MARK: - 错误文案（v4.0.104 #17 起收归共享实现 `RemoteFiles.failureReason`，此处不再自带一份）

// MARK: - 条目行（独立小 struct：不塞进上方 ViewBuilder，避免 CI 类型检查超时）

private struct FilesManagerRow: View {
    let entry: RemoteFileEntry
    var onOpen: () -> Void
    var onShare: () -> Void
    var onRename: () -> Void
    /// v4.0.102：回调带上**本行自身的全局 frame** —— 删除确认浮层从被删那一行的位置长出
    /// （原走 confirmationDialog，iPhone 上系统固定从屏幕底部升起，锚不到行）
    var onDelete: (CGRect) -> Void
    /// v4.0.114（批量删除）：选择态下整行点击 = 勾选；右侧「…」菜单收起（避免误触单项删除）
    var selecting: Bool
    var isPicked: Bool
    var onTogglePick: () -> Void
    @State private var rowFrame: CGRect = .zero

    var body: some View {
        HStack(spacing: Spacing.xl) {
            if selecting {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Typography.title))
                    .foregroundStyle(isPicked ? Color.accentColor : Color.secondary)
            }
            Button(action: selecting ? onTogglePick : onOpen) {
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

            if !selecting {
                Menu {
                    if !entry.isDir {
                        Button { onOpen() } label: { Label("预览", systemImage: "eye") }
                    }
                    Button { onShare() } label: { Label("分享", systemImage: "square.and.arrow.up") }
                    Button { onRename() } label: { Label("重命名", systemImage: "pencil") }
                    Button(role: .destructive) { onDelete(rowFrame) } label: { Label("删除", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: Typography.title))
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        // v4.0.102：锚点采集 —— 删除确认浮层从**这一行**的位置长出
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrame = $0 }
        // v4.0.68：这行原来是 Color(uiColor: .secondarySystemGroupedBackground)（纯白面），
        // 但本行是 pastelCard 列表里的一行 —— 自己再涂料只会把卡面盖白。行底交给外层卡片。
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
                .pastelFill(cornerRadius: Radius.inset)
                .padding(.horizontal, Spacing.sheetInset)

            if let err = errorText {
                Text(err)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.sheetInset)
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
                    .frame(maxWidth: .infinity)
                    .pill(.primary)
            }
            .buttonStyle(.plain)
            .disabled(saving || trimmed.isEmpty || unchanged || duplicated)
            .opacity(saving || trimmed.isEmpty || unchanged || duplicated ? 0.5 : 1)
            .padding(.horizontal, Spacing.sheetInset)

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
                errorText = "重命名失败：" + RemoteFiles.failureReason(error)
            }
        }
    }
}

// MARK: ===== 以下原为 Features/Settings/HistorySheet.swift =====

// MARK: - v2.0.116 执行历史（自动化 + 场景，设置页入口）
// v2.0.132：加管理功能——滑动单条删除 + 编辑模式多选删除 + 全部清除

struct HistorySheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var items: [HistoryItem] = []
    @State private var loaded = false
    @State private var editMode = EditMode.inactive
    @State private var selected = Set<String>()   // 多选删除（按 id）
    @State private var showClearConfirm = false   // 全部清除确认
    /// v4.0.102：清除确认浮层的锚点（工具栏「⋯」菜单按钮的 frame）—— 从被点的按钮位置长出，
    /// 原走 confirmationDialog，iPhone 上系统固定从屏幕底部升起
    @State private var clearAnchor: CGRect = .zero
    @State private var deleteError: String?   // v-review fix：滑动删除失败提示

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                        Text(loaded ? "暂无执行记录" : "加载中…")
                            .font(.system(size: Typography.title, weight: .semibold))
                        if loaded {
                            Text("自动化或场景执行后会在这里留痕")
                                .font(.system(size: Typography.subhead))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selected) {
                        ForEach(items) { h in
                            HStack(spacing: 12) {
                                Image(systemName: h.type == "自动化" ? "timer" : "sparkles")
                                    .font(.system(size: Typography.subhead, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(h.type == "自动化" ? Color.orange : Color.purple,
                                                in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(h.type)「\(h.name)」")
                                        .font(.system(size: Typography.body, weight: .medium))
                                        .lineLimit(1)
                                    if !h.detail.isEmpty {
                                        Text(h.detail)
                                            .font(.system(size: Typography.caption))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Text(h.ts)
                                        .font(.system(size: Typography.tiny))
                                        .foregroundStyle(.quaternary)
                                }
                                Spacer()
                                Image(systemName: h.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: Typography.body))
                                    .foregroundStyle(h.ok ? .green : .red)
                                    .symbolEffect(.bounce, value: h.ok)   // v4.0.61：结果落定弹一下
                            }
                            .padding(.vertical, Spacing.xxs)
                        }
                        // 编辑模式下不显示滑动删除（避免手势冲突）；非编辑模式每行左滑删除
                        .onDelete { offsets in
                            deleteRows(offsets)
                        }
                    }
                    .environment(\.editMode, $editMode)
                    // v3.9.35：清掉 List 自带白底，透出系统玻璃弹窗底（v3.9.22 只挂在 sheet
                    // 外壳上，对 NavigationStack 内的 List 不生效 → 全站就这弹窗白底）
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("执行历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editMode == .active ? "完成" : "编辑") {
                        withAnimation {
                            if editMode == .active {
                                selected.removeAll()
                                editMode = .inactive
                            } else {
                                editMode = .active
                            }
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if editMode == .active {
                        // 编辑模式：全选 / 删除所选 / 全部清除
                        Menu {
                            Button {
                                selected = Set(items.map { $0.id })
                            } label: {
                                Label("全选", systemImage: "checkmark.circle")
                            }
                            Button(role: .destructive) {
                                deleteSelected()
                            } label: {
                                Label("删除所选（\(selected.count)）", systemImage: "trash")
                            }
                            .disabled(selected.isEmpty)
                            Button(role: .destructive) {
                                showClearConfirm = true
                            } label: {
                                Label("全部清除", systemImage: "trash.slash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                // v4.0.102：锚点采集 —— 全部清除的确认浮层从这个「⋯」按钮的位置长出
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { clearAnchor = $0 }
                        }
                    } else {
                        // v3.9.35：刷新改回系统裸按钮——与「完成」同款系统玻璃胶囊
                        Button("刷新") { Task { await load() } }
                    }
                }
            }
            // v4.0.102：全部清除的二次确认 —— 从 confirmationDialog 改为**锚定浮层**（锚在工具栏「⋯」按钮上）。
            // 由头同看板批次：iPhone 上系统动作表固定从屏幕底部升起，锚不到被点的元素。
            .overlay {
                if showClearConfirm {
                    AnchorMenuOverlay(
                        anchorFrame: clearAnchor,
                        items: [
                            AnchorMenuItem(id: "clear", title: "全部清除", icon: "trash.slash",
                                           color: .red, destructive: true),
                            AnchorMenuItem(id: "cancel", title: "取消", icon: "xmark", color: .gray),
                        ],
                        title: "全部清除执行历史？",
                        message: "此操作不可恢复，确定删除全部执行记录？",
                        onPick: { item in
                            showClearConfirm = false
                            guard item.id == "clear" else { return }
                            Task {
                                if let j = try? await auth.json("/api/history", method: "DELETE"),
                                   let list = j["history"] as? [[String: Any]] {
                                    items = list.map { HistoryItem($0) }
                                }
                                selected.removeAll()
                                editMode = .inactive
                            }
                        },
                        onClose: { showClearConfirm = false }
                    )
                }
            }
            .task { await load() }
            // v-review fix：滑动删除失败提示
            .alert("删除失败", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("好的", role: .cancel) { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
        }
        .presentationDetents([.large])
    }

    private func load() async {
        if let j = try? await auth.json("/api/history") {
            items = SettingsLoad.list(j, key: "history", make: HistoryItem.init)
        }
        loaded = true
    }

    /// 滑动单条删除（非编辑模式）——v-review fix：失败回滚（本地快照恢复）+ 提示，
    /// 与其余后端列表驱动的删除保持一致，不再静默吞错
    private func deleteRows(_ offsets: IndexSet) {
        let ids = offsets.map { items[$0].id }
        let snapshot = items
        items.remove(atOffsets: offsets)
        Task {
            do {
                let j = try await auth.json("/api/history?ids=\(ids.joined(separator: ","))", method: "DELETE")
                if let list = j["history"] as? [[String: Any]] {
                    items = list.map { HistoryItem($0) }
                }
            } catch {
                items = snapshot
                deleteError = "删除失败，已恢复列表"
            }
        }
    }

    /// 编辑模式批量删除所选
    /// v3.9.41（SR24）：原先 `try?` 整个吞错，本地立刻消失、服务器没删 → 重开原样回来；
    /// 改成与 :157 `deleteRows` 同一套「快照 + 失败回滚 + 提示」。
    private func deleteSelected() {
        let ids = Array(selected)
        let snapshot = items
        items.removeAll { ids.contains($0.id) }
        selected.removeAll()
        Task {
            do {
                let j = try await auth.json("/api/history?ids=\(ids.joined(separator: ","))", method: "DELETE")
                if let list = j["history"] as? [[String: Any]] {
                    items = list.map { HistoryItem($0) }
                }
            } catch {
                items = snapshot
                deleteError = "删除失败，已恢复列表"
            }
        }
        if items.isEmpty { editMode = .inactive }
    }
}

struct HistoryItem: Identifiable {
    let id: String
    let ts: String
    let type: String
    let name: String
    let ok: Bool
    let detail: String
    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? UUID().uuidString
        ts = d["ts"] as? String ?? ""
        type = d["type"] as? String ?? ""
        name = d["name"] as? String ?? ""
        ok = (d["ok"] as? Bool) ?? false
        detail = d["detail"] as? String ?? ""
    }
}

// MARK: ===== 以下原为 Features/Settings/HomeShortcutSheet.swift =====

//
//  HomeShortcutSheet.swift
//  轻聊
//
//  v3.9.82：桌面图标长按快捷方式的选择弹窗（候选清单里挑 4 项显示，v4.0.x 候选 8 项）
//  上限来自 iOS 本身（桌面长按菜单最多 4 项），不是我们的产品决定 —— 文案里对用户说清楚。
//


struct HomeShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [Int] = HomeShortcutStore.ids

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(HomeShortcut.candidates) { a in
                        row(a)
                    }
                } header: {
                    Text("已选 \(selected.count)/\(HomeShortcut.maxCount)")
                } footer: {
                    Text(selected.isEmpty
                         ? "一个都没选 —— 长按桌面图标不会出现快捷方式。"
                         : "顺序就是下面的排列顺序。长按桌面上的「轻聊」图标即可看到这几项，最多 \(HomeShortcut.maxCount) 个（iOS 系统上限）。")
                }
                // 常显：全关掉之后也得有路回来。
                // 判据用集合比较（不是 count）：选了 4 个但和默认不一样时，也得给「恢复默认」。
                if Set(selected) != Set(HomeShortcut.defaultIds) {
                    Section {
                        Button {
                            HomeShortcutStore.reset()
                            selected = HomeShortcutStore.ids
                        } label: {
                            Text("恢复默认").font(.system(size: Typography.body))
                        }
                    }
                }
            }
            .navigationTitle("桌面快捷方式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        // 打开弹窗时把系统菜单按当前设置重建一次：万一上一次同步发生在设置写坏之后，
        // 这里能自愈（用户看不到「设置里选了但桌面菜单没变」这种不一致）。
        .task { HomeShortcutManager.sync() }
    }

    @ViewBuilder
    private func row(_ a: OrbQuickAction) -> some View {
        let on = selected.contains(a.id)
        let full = selected.count >= HomeShortcut.maxCount
        Toggle(isOn: Binding(get: { on },
                             set: { newValue in
                                 if !HomeShortcutStore.set(a.id, on: newValue) { return }
                                 selected = HomeShortcutStore.ids
                             })) {
            Label {
                Text(a.title).font(.system(size: Typography.body))
            } icon: {
                // v4.0.83 追加（用户真机反馈：「设置页桌面快捷方式设置里面的图标没有白色圆角化」）：
                // 行首图标统一「28pt 圆角色块 + 白符号」，与设置页其余行（SettingsSystem :158/:199/:245/:323
                // 以及「允许 AI 操作我的数据」总闸卡片头）同款。原来只给符号 tint（裸符号），风格不一致。
                Image(systemName: a.icon)
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(a.color, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
            }
        }
        .qingliaoSwitch(hideLabel: false)
        // 选满 4 个后未选项置灰（点了也不会生效，所以灰掉比让它弹一下回弹更诚实）
        .disabled(!on && full)
        .accessibilityLabel("\(a.title) 桌面快捷方式")
    }
}
