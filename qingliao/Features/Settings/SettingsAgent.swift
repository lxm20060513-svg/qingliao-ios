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

// MARK: ===== 以下原为 Features/Settings/AgentKeywordsSheet.swift =====

// MARK: - v2.0.105 Agent 分流关键词管理（查看内置 + 添加/删除自定义）

struct AgentKeywordsSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var builtin: [String: [String]] = [:]
    @State private var custom: [String: [String]] = [:]
    @State private var activeList = "strong"
    @State private var newWord = ""
    @State private var msg: (ok: Bool, text: String)?

    private let groups: [(key: String, name: String)] = [
        ("strong", "强意图（命中即走 Agent）"),
        ("verbs", "查询动词"),
        ("topics", "查询主题"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("分组", selection: $activeList) {
                        ForEach(groups, id: \.key) { g in
                            Text(g.name).tag(g.key)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("内置关键词") {
                    FlowText(builtin[activeList] ?? [])
                }

                Section("自定义关键词") {
                    if (custom[activeList] ?? []).isEmpty {
                        Text("暂无自定义——在下方添加")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(custom[activeList] ?? [], id: \.self) { w in
                            HStack {
                                Text(w)
                                Spacer()
                                Button {
                                    Task { await remove(w) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除关键词 \(w)")
                            }
                        }
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        TextField("输入关键词（如：扫地机）", text: $newWord)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("添加") {
                            Task { await add() }
                        }
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let m = msg {
                        Text(m.text)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(m.ok ? .green : .red)
                    }
                } header: {
                    Text("添加关键词")
                } footer: {
                    Text("添加后立即生效：命中关键词的消息会走 Agent 智能回复（工具调用）。删除仅限自定义词。")
                }
            }
            .navigationTitle("Agent 关键词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        if let j = try? await auth.json("/api/agent/keywords") {
            builtin = (j["builtin"] as? [String: [String]]) ?? [:]
            custom = (j["custom"] as? [String: [String]]) ?? [:]
        }
    }

    private func add() async {
        let w = newWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        if let j = try? await auth.json("/api/agent/keywords", method: "POST",
                                        body: ["list": activeList, "word": w]) {
            msg = ((j["ok"] as? Bool) ?? false, j["message"] as? String ?? "")
            custom = (j["custom"] as? [String: [String]]) ?? custom
            if (j["ok"] as? Bool) == true { newWord = "" }
        } else {
            msg = (false, "网络错误，请重试")
        }
    }

    private func remove(_ w: String) async {
        let enc = w.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? w
        if let j = try? await auth.json("/api/agent/keywords?list=\(activeList)&word=\(enc)", method: "DELETE", body: nil) {
            msg = ((j["ok"] as? Bool) ?? false, j["message"] as? String ?? "")
            custom = (j["custom"] as? [String: [String]]) ?? custom
        } else {
            msg = (false, "网络错误，请重试")
        }
    }
}

/// 自动换行标签流（简单实现：按行分组显示）
private struct FlowText: View {
    let words: [String]
    init(_ words: [String]) { self.words = words }

    var body: some View {
        let rows = chunked(words, maxPerRow: 4)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { w in
                        Text(w)
                            .font(.system(size: Typography.subhead))
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.xs)
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                        in: Capsule())
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, Spacing.xxs)
    }

    private func chunked(_ arr: [String], maxPerRow: Int) -> [[String]] {
        stride(from: 0, to: arr.count, by: maxPerRow).map {
            Array(arr[$0..<min($0 + maxPerRow, arr.count)])
        }
    }
}

// MARK: ===== 以下原为 Features/Settings/AgentMemorySheet.swift =====

// MARK: - v2.0.113 Agent 记忆管理（弹窗，同 AI 记忆样式）

struct AgentMemorySheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [AgentRuleItem] = []
    // v3.9.40（#19）：editing 非空即编辑弹窗打开（存的是被改的那条，用于比对与回传 id）
    @State private var editing: AgentRuleItem?
    @State private var editText = ""
    // v3.9.41（SR24）：整页原先没有任何错误出口——删除/编辑失败时列表不动，用户以为成功
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            Group {
                if rules.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                        Text("暂无 Agent 记忆")
                            .font(.system(size: Typography.title, weight: .semibold))
                        Text("聊天时说「以后查内存都用agent」\n会自动记住，同类请求直接走 Agent 处理")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(rules) { r in
                                HStack(spacing: 10) {
                                    Image(systemName: "brain.head.profile")
                                        .font(.system(size: Typography.body))
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("以后「\(r.pattern)」都用 Agent")
                                            .font(.system(size: Typography.body, weight: .medium))
                                        Text("记住于 \(r.created)")
                                            .font(.system(size: Typography.caption))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    // v3.9.40（#19）：就地编辑规则关键词（原只能删了重说）
                                    Button {
                                        editText = r.pattern
                                        editing = r
                                    } label: {
                                        Image(systemName: "pencil")
                                            .font(.system(size: Typography.body))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .accessibilityLabel("编辑这条记忆")
                                    .buttonStyle(.plain)
                                    Button {
                                        Task { await remove(r) }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: Typography.title))
                                            .foregroundStyle(.red.opacity(0.8))
                                    }
                                    .accessibilityLabel("删除这条记忆")
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, Spacing.xxs)
                            }
                        } header: {
                            Text("命中规则的请求将强制走 Agent 智能回复（工具调用）")
                        }
                    }
                }
            }
            .navigationTitle("Agent 记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
            // v3.9.40（#19）：就地编辑关键词
            .alert("编辑这条 Agent 记忆", isPresented: Binding(get: { editing != nil },
                                                              set: { if !$0 { editing = nil } })) {
                TextField("关键词（2-40 字）", text: $editText)
                Button("保存") {
                    if let r = editing { Task { await update(r) } }
                    editing = nil
                }
                Button("取消", role: .cancel) { editing = nil }
            } message: {
                Text("命中「\(editText)」的请求将强制走 Agent 处理")
            }
        }
        .presentationDetents([.medium, .large])
        // v3.9.41（SR24）：错误出口（挂在最外层，与 #19 的编辑 alert 不同层级不互斥）
        .alert("操作失败", isPresented: Binding(get: { errorMsg != nil },
                                                set: { if !$0 { errorMsg = nil } })) {
            Button("好", role: .cancel) { errorMsg = nil }
        } message: {
            Text(errorMsg ?? "")
        }
    }

    private func load() async {
        if let j = try? await auth.json("/api/agent/rules") {
            rules = SettingsLoad.list(j, key: "rules", make: AgentRuleItem.init)
        }
    }

    private func remove(_ r: AgentRuleItem) async {
        let enc = r.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? r.id
        guard let j = try? await auth.json("/api/agent/rules?id=\(enc)", method: "DELETE", body: nil) else {
            errorMsg = "删除失败：网络异常或服务器报错"
            return
        }
        let ok = (j["ok"] as? Bool) ?? false
        guard ok else {
            errorMsg = j["message"] as? String ?? j["error"] as? String ?? "删除失败"
            return
        }
        // 只在响应真带 rules 时覆盖：出错响应（只有 error 键）会让列表假性清空
        if let arr = j["rules"] as? [[String: Any]] {
            rules = arr.map { AgentRuleItem($0) }
        }
    }

    /// v3.9.40（#19）：改关键词——POST 带 id 即更新（见 agent_api.py 同一分支）
    private func update(_ r: AgentRuleItem) async {
        let t = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t != r.pattern else { return }
        guard let j = try? await auth.json("/api/agent/rules", method: "POST",
                                           body: ["id": r.id, "pattern": t]) else {
            errorMsg = "保存失败：网络异常或服务器报错"
            return
        }
        let ok = (j["ok"] as? Bool) ?? false
        guard ok else {
            errorMsg = j["message"] as? String ?? j["error"] as? String ?? "保存失败"
            return
        }
        if let arr = j["rules"] as? [[String: Any]] {
            rules = arr.map { AgentRuleItem($0) }
        }
    }
}

struct AgentRuleItem: Identifiable {
    let id: String
    let pattern: String
    let created: String
    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? UUID().uuidString
        pattern = d["pattern"] as? String ?? ""
        created = d["created"] as? String ?? ""
    }
}

// MARK: ===== 以下原为 Features/Settings/MemoryView.swift =====

// MARK: - v2.0.87 AI 记忆管理（记住用户偏好 → 对话自动参考）

struct MemoryView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    // v4.0.x 第 4 项：entries（纯字符串）→ items（带 status/日期/来源）。
    // 只存 items 一份真源：并行存两个数组必然会出现"列表和状态对不上"的中间态。
    @State private var items: [MemoryEntry] = []
    @State private var newText = ""
    @State private var message: (ok: Bool, text: String)? = nil
    @State private var busy = false
    @State private var confirmDelete: String?   // v2.0.102：删除确认（记忆不可恢复）
    // v3.9.40（#19）：就地编辑——editing 存**原条目**（非空即弹窗打开），editText 是输入框内容
    @State private var editing: String?
    @State private var editText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 添加区
                HStack(spacing: 8) {
                    TextField("如：我经常用 5G 网络 / 回答要简洁", text: $newText)
                        .font(.system(size: Typography.subhead))
                        .padding(.horizontal, Spacing.xl)
                        .padding(.vertical, Spacing.md)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: Radius.chip))
                    Button {
                        add()
                    } label: {
                        Text("记住")
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, Spacing.section)
                            .padding(.vertical, Spacing.md)
                            .background(Color.accentColor,
                                        in: RoundedRectangle(cornerRadius: Radius.chip))
                    }
                    .buttonStyle(.plain)
                    .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                .padding(Spacing.xl)

                if let m = message {
                    Text(m.text)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(m.ok ? Color.green : Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.xxl)
                }

                // 列表
                ScrollView {
                    VStack(spacing: 8) {
                        if items.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: Typography.display))
                                    .foregroundStyle(.tertiary)
                                Text("还没有记忆条目")
                                    .font(.system(size: Typography.subhead))
                                    .foregroundStyle(.secondary)
                                Text("聊天时说「记住…」会自动保存，或手动添加")
                                    .font(.system(size: Typography.caption))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.top, 60)
                        } else {
                            ForEach(items) { item in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "brain.head.profile")
                                        .font(.system(size: Typography.body))
                                        .foregroundStyle(item.isDimmed ? Color.secondary : Color.accentColor)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.text)
                                            .font(.system(size: Typography.subhead))
                                            .foregroundStyle(item.isDimmed ? Color.secondary : Color.primary)
                                            .textSelection(.enabled)
                                        // v4.0.x 第 4 项：状态 + 日期 + 来源三枚元信息
                                        HStack(spacing: 6) {
                                            MemoStatusChip(item: item)
                                            if let d = item.displayDate {
                                                Label {
                                                    Text(d, format: .dateTime.year().month().day())
                                                } icon: {
                                                    Image(systemName: "calendar")
                                                }
                                                .font(.system(size: Typography.caption))
                                                .foregroundStyle(.tertiary)
                                            }
                                            if item.hasSource {
                                                Label(item.sourceTitle, systemImage: item.sourceIcon)
                                                    .font(.system(size: Typography.caption))
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    // v4.0.x 第 4 项：改状态（不改正文）
                                    Menu {
                                        ForEach(MemoryEntry.allStatuses, id: \.self) { s in
                                            Button {
                                                Task { await setStatus(item, s) }
                                            } label: {
                                                Label(MemoryEntry.statusTitle(s), systemImage: MemoryEntry.statusIcon(s))
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                            .font(.system(size: Typography.subhead))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .accessibilityLabel("修改这条记忆的状态")
                                    // v3.9.40（#19）：就地编辑（原只能删了再加，会掉到列表末尾）
                                    Button {
                                        editText = item.text
                                        editing = item.text
                                    } label: {
                                        Image(systemName: "pencil")
                                            .font(.system(size: Typography.subhead))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("编辑这条记忆")
                                    Button {
                                        confirmDelete = item.text   // v2.0.102：先确认再删（记忆不可恢复）
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: Typography.subhead))
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("删除这条记忆")
                                }
                                .padding(.horizontal, Spacing.xl)
                                .padding(.vertical, Spacing.lg)
                                .background(Color(uiColor: .secondarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: Radius.inset))
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.xs)
                }
            }
            .navigationTitle("AI 记忆")
            .navigationBarTitleDisplayMode(.inline)
            // v2.0.102：删除确认（记忆不可恢复）
            .confirmationDialog("删除这条记忆？", isPresented: Binding(get: { confirmDelete != nil },
                                                                      set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let e = confirmDelete {
                        Task { await remove(e) }
                    }
                    confirmDelete = nil
                }
                Button("取消", role: .cancel) { confirmDelete = nil }
            } message: {
                Text("将删除「\(confirmDelete ?? "")」，此操作不可恢复")
            }
            // v3.9.40（#19）：就地编辑记忆
            .alert("编辑这条记忆", isPresented: Binding(get: { editing != nil },
                                                        set: { if !$0 { editing = nil } })) {
                TextField("记忆内容", text: $editText)
                Button("保存") {
                    if let o = editing { Task { await update(old: o) } }
                    editing = nil
                }
                Button("取消", role: .cancel) { editing = nil }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let j = try? await auth.json("/api/memory/list") else { return }
        // 第 4 项：解析失败保持**原列表不动**（沿用 v3.9.41 定的口径）——
        // 一次网络抖动就把用户的记忆页清空，用户会以为记忆全没了。
        let parsed = MemoryEntry.parse(j)
        // 「保持原列表不动」只适用于**解析不出东西**的场合；后端真的返回了空列表
        // （用户删光了）必须照它清空，否则界面留着一条永远删不掉的幽灵条目。
        if parsed.isEmpty && !items.isEmpty && !MemoryEntry.hasListField(j) { return }
        items = parsed
    }

    private func add() {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            if let j = try? await auth.json("/api/memory/add", method: "POST", body: ["text": t]) {
                let ok = (j["ok"] as? Bool) ?? false
                message = (ok, j["message"] as? String ?? (ok ? "已记住" : "保存失败"))
                if ok && MemoryEntry.hasListField(j) { items = MemoryEntry.parse(j) }
                if ok { newText = "" }
            } else {
                message = (false, "请求失败")
            }
        }
    }

    // v3.9.41（SR24）：删除失败必须可见——原先 try? 吞错、且不读 ok，条目「看着删了」，
    // 重开原样回来。失败时保持列表不动（与服务器一致），只报错。
    private func remove(_ text: String) async {
        guard let j = try? await auth.json("/api/memory/delete", method: "POST", body: ["text": text]) else {
            message = (false, "删除失败：请求失败")
            return
        }
        let ok = (j["ok"] as? Bool) ?? false
        guard ok else {
            message = (false, j["message"] as? String ?? "删除失败")
            return
        }
        message = (true, "已删除")
        // v4.0.15：按「字段在不在」判定，不是「解析出东西没有」——
        // 删光最后一条时后端合法返回空列表，跳过赋值会让条目看着删不掉。
        if MemoryEntry.hasListField(j) { items = MemoryEntry.parse(j) }
    }

    /// v3.9.40（#19）：就地编辑一条记忆（后端 /api/memory/update 保位置改写）
    private func update(old: String) async {
        let t = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else {
            message = (false, "内容至少 2 个字")
            return
        }
        guard t != old else { return }   // 没改动就不打接口
        busy = true
        defer { busy = false }
        if let j = try? await auth.json("/api/memory/update", method: "POST",
                                        body: ["old": old, "text": t]) {
            let ok = (j["ok"] as? Bool) ?? false
            message = (ok, j["message"] as? String ?? (ok ? "已更新" : "更新失败"))
            if ok && MemoryEntry.hasListField(j) { items = MemoryEntry.parse(j) }
        } else {
            message = (false, "请求失败")
        }
    }

    /// v4.0.x 第 4 项：只翻状态，不动正文（后端 /api/memory/status 独立端点）。
    /// 失败时**保持原状态不动**并报错 —— 静默失败会让用户以为标成功了，回头发现
    /// 记忆还在生效，白白去改一遍别的设置。
    private func setStatus(_ item: MemoryEntry, _ status: String) async {
        guard status != item.normalizedStatus else { return }   // 没变就不打接口
        guard let j = try? await auth.json("/api/memory/status", method: "POST",
                                        body: ["text": item.text, "status": status]) else {
            message = (false, "状态更新失败：请求失败")
            return
        }
        let ok = (j["ok"] as? Bool) ?? false
        guard ok else {
            message = (false, j["message"] as? String ?? "状态更新失败")
            return
        }
        message = (true, "已标记为「\(MemoryEntry.statusTitle(status))」")
        if MemoryEntry.hasListField(j) { items = MemoryEntry.parse(j) }
    }
}
