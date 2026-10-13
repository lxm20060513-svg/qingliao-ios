// v4.0.104 待做池 #11：剪贴板历史设置页（本地回看 / 复制 / 一键入待办 / 清空）
//
// ⚠️ 能力边界（本页的设计前提）：iOS **禁止**后台监听剪贴板；程序化读
// `UIPasteboard.general.string` 会弹一次系统「允许粘贴」提示。
// 所以本页只在**用户点「读取当前剪贴板」那一刻**读一次（会弹一次系统提示，属预期）；
// **绝不在 body / 渲染期读**，也绝不轮询。
//
// 脱敏口径：历史只存本机（UserDefaults）。注意「入待办」是例外 —— 它把内容并入待办账本，
// 而账本是「本机 → NAS 双写」（RecordStore → SyncedStore），所以顶部说明**必须**把这点讲清，
// 不能笼统宣称「数据不会离开本机」（v4.0.104 审查抓到：原话与事实不符）。
// 数据真源与唯一写入口 = Core/ClipboardHistoryStore.swift；本页不拼键名、不写 UserDefaults。

import SwiftUI
import UIKit

struct ClipboardHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ClipboardHistoryStore.Entry] = []
    @State private var toast = ""
    /// 清空二次确认（v4.0.102 口径：破坏性动作一律走锚定浮层 AnchorMenuOverlay，不用 confirmationDialog）
    @State private var showClearConfirm = false
    /// 「清空」按钮的全局 frame —— 确认浮层从被点那颗按钮的位置长出
    @State private var clearButtonFrame: CGRect = .zero

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // ⚠️ 文案必须与事实一致：历史确实只存本机，但「入待办」会把内容并入
                    // 待办账本，而账本是「本机 → NAS 双写」（RecordStore → SyncedStore）。
                    Text("只在你主动读取时记录，历史只留在这台手机上。「入待办」会把内容并入待办，待办账本会与你的 NAS 同步。")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                }

                Section {
                    Button {
                        readClipboard()
                    } label: {
                        Label("读取当前剪贴板", systemImage: "doc.on.clipboard")
                    }
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                        clearButtonFrame = rect
                    }
                }

                if !toast.isEmpty {
                    Section {
                        Text(toast)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                    }
                }

                if entries.isEmpty {
                    Section {
                        Text("还没有记录")
                            .font(.system(size: Typography.subhead))
                        Text("点上面「读取当前剪贴板」，或轻点首页的剪贴板卡，内容就会存到这里。")
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Section("记录（\(entries.count)）") {
                        ForEach(entries) { e in
                            row(e)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("剪贴板历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay {
                if showClearConfirm {
                    AnchorMenuOverlay(
                        anchorFrame: clearButtonFrame,
                        items: [
                            AnchorMenuItem(id: "clear", title: "清空", icon: "trash",
                                           color: .red, destructive: true),
                            AnchorMenuItem(id: "cancel", title: "取消", icon: "xmark", color: .gray),
                        ],
                        title: "清空全部记录？",
                        message: "清空后不可恢复（只影响本机记录）。",
                        onPick: { item in
                            showClearConfirm = false
                            if item.id == "clear" { clearAll() }
                        },
                        onClose: { showClearConfirm = false }
                    )
                }
            }
            .onAppear { reload() }
        }
    }

    /// 一行：正文首行摘要（最多 2 行）+ 相对时间；尾部滑动动作 = 复制 / 入待办 / 删除
    /// （滑动动作是本仓设置页既有口径，见 CloudDriveSettingsSheet / MailSettingsSheet）。
    private func row(_ e: ClipboardHistoryStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(e.text)
                .font(.system(size: Typography.body))
                .lineLimit(2)
                .truncationMode(.tail)
            Text(relativeTime(e.at))
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                ClipboardHistoryStore.shared.remove(id: e.id)
                reload()
            } label: { Label("删除", systemImage: "trash") }
            Button {
                copy(e)
            } label: { Label("复制", systemImage: "doc.on.doc") }
                .tint(.blue)
            Button {
                toTodo(e)
            } label: { Label("入待办", systemImage: "checklist") }
                .tint(.green)
        }
    }

    // MARK: - 动作

    /// 唯一读剪贴板处（用户主动点击 → 会弹一次系统「允许粘贴」提示，属预期）。
    /// **不要**把这段挪进 body 或任何渲染路径。
    private func readClipboard() {
        let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            Haptics.error()
            toast = "剪贴板是空的，没记录"
            return
        }
        guard text.count <= ClipboardHistoryStore.maxLength else {
            Haptics.error()
            toast = "内容太长，不记录"
            return
        }
        if ClipboardHistoryStore.shared.record(text, source: "手动") != nil {
            Haptics.success()
            toast = "已记录"
            reload()
        } else {
            // record 返回 nil：开关关掉了（长度/空串已在上面拦过）
            Haptics.error()
            toast = "剪贴板历史已关闭，未记录"
        }
    }

    private func copy(_ e: ClipboardHistoryStore.Entry) {
        UIPasteboard.general.string = e.text
        Haptics.success()
        toast = "已复制"
    }

    /// 入待办：走 RecordStore 公开入口（不自己拼 UserDefaults / 不另写一套落库）。
    /// kind 用 "todo"（RecordKit 无 todoKind 常量，既有 kind 只有 amount/meter/note/income）；
    /// source 用 "clipboard"，中文名「剪贴板」在 RecordKit.sourceLabel 登记。
    private func toTodo(_ e: ClipboardHistoryStore.Entry) {
        let title = firstLine(e.text)
        RecordStore.shared.add(kind: "todo", title: title, amount: nil, unit: "",
                               note: e.text, category: "", source: "clipboard")
        Haptics.success()
        toast = "已加入待办"
    }

    private func clearAll() {
        ClipboardHistoryStore.shared.clearAll()
        Haptics.tap()
        toast = "已清空"
        reload()
    }

    private func reload() {
        entries = ClipboardHistoryStore.shared.allEntries
    }

    // MARK: - 展示

    /// 首行摘要（去掉换行后的第一段），给待办标题用。
    private func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? text : String(trimmed.prefix(60))
    }

    /// 相对时间（刚刚 / N 分钟前 / N 小时前 / N 天前）。
    private func relativeTime(_ at: Double) -> String {
        let secs = Date().timeIntervalSince1970 - at
        if secs < 60 { return "刚刚" }
        if secs < 3600 { return "\(Int(secs / 60)) 分钟前" }
        if secs < 86400 { return "\(Int(secs / 3600)) 小时前" }
        return "\(Int(secs / 86400)) 天前"
    }
}
