import SwiftUI
import UniformTypeIdentifiers
import PDFKit

// MARK: - v2.0.81 知识库管理（文档上传/列表/删除；聊天输入 @知识库 自动检索注入）

struct KBView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var docs: [KBDoc] = []
    @State private var showImporter = false
    @State private var showPasteSheet = false   // v2.0.83 粘贴文本上传
    @State private var message: (ok: Bool, text: String)?
    @State private var busy = false
    @State private var confirmDelete: String?   // v2.0.102：删除确认（文档不可恢复）

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.accentColor)
                            Text("上传文档（txt / md / PDF）")
                                .foregroundStyle(.primary)
                        }
                    }
                    // v2.0.83：粘贴文本上传（LiveContainer 环境文件选择器可能无反应）
                    Button {
                        showPasteSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "doc.plaintext")
                                .foregroundStyle(Color.teal)
                            Text("粘贴文本上传")
                                .foregroundStyle(.primary)
                        }
                    }
                    Text("聊天时输入「@知识库 你的问题」，AI 会自动检索这些文档回答")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                }

                Section("文档（\(docs.count) 个）") {
                    if docs.isEmpty {
                        Text("暂无文档")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(docs) { doc in
                        KBRow(name: doc.name,
                              chunks: doc.chunks,
                              size: doc.size,
                              onDelete: { name in confirmDelete = name })   // v2.0.102：先确认再删
                    }
                }

                if let m = message {
                    Section {
                        Text(m.text)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(m.ok ? .green : .red)
                    }
                }
            }
            .navigationTitle("知识库")
            .navigationBarTitleDisplayMode(.inline)
            // v2.0.102：删除确认（文档不可恢复）
            .confirmationDialog("删除文档？", isPresented: Binding(get: { confirmDelete != nil },
                                                                   set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let name = confirmDelete {
                        Task { await deleteDoc(name) }
                    }
                    confirmDelete = nil
                }
                Button("取消", role: .cancel) { confirmDelete = nil }
            } message: {
                Text("将删除「\(confirmDelete ?? "")」，此操作不可恢复")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
            // v2.0.83：粘贴文本上传 sheet
            .sheet(isPresented: $showPasteSheet) {
                PasteKBSheet { name, content in
                    showPasteSheet = false
                    Task { await uploadContent(name, content) }
                }
                .presentationDetents([.medium, .large])
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.plainText, .pdf,
                                                UTType(filenameExtension: "md") ?? .data,
                                                UTType(filenameExtension: "txt") ?? .data],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    Task { await uploadFiles(urls) }
                case .failure:
                    break
                }
            }
        }
    }

    private func load() async {
        if let j = try? await auth.json("/api/kb/list") {
            let arr = j["docs"] as? [[String: Any]] ?? []
            // v2.0.82：解析为具体类型 KBDoc（字典索引在 ViewBuilder 里类型检查爆炸）
            docs = arr.compactMap { d in
                guard let n = d["name"] as? String else { return nil }
                return KBDoc(name: n,
                             chunks: (d["chunks"] as? Int) ?? 0,
                             size: (d["size"] as? Int) ?? 0)
            }
        }
    }

    private func uploadFiles(_ urls: [URL]) async {
        busy = true
        defer { busy = false }
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.lowercased()
            var content = ""
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if ext == "pdf" {
                // PDF 用 PDFKit 提取文本（与发送 PDF 同款）
                content = extractPDFText(from: url) ?? ""
            } else {
                content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
            guard !content.isEmpty else {
                message = (false, "\(name)：无法读取内容（扫描件 PDF 无文字层）")
                continue
            }
            if let j = try? await auth.json("/api/kb/upload", method: "POST",
                                            body: ["name": name, "content": content]) {
                let ok = (j["ok"] as? Bool) ?? false
                message = (ok, (j["message"] as? String) ?? (ok ? "已保存" : "上传失败"))
            } else {
                message = (false, "\(name)：请求失败")
            }
        }
        await load()
    }

    private func deleteDoc(_ name: String) async {
        if let j = try? await auth.json("/api/kb/delete", method: "POST", body: ["name": name]) {
            message = ((j["ok"] as? Bool) ?? false, j["message"] as? String ?? "")
        }
        await load()
    }

    /// v2.0.83：直接上传文本内容（粘贴上传用）
    private func uploadContent(_ name: String, _ content: String) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !trimmed.isEmpty else {
            message = (false, "名称和内容不能为空")
            return
        }
        if let j = try? await auth.json("/api/kb/upload", method: "POST",
                                        body: ["name": name, "content": trimmed]) {
            let ok = (j["ok"] as? Bool) ?? false
            message = (ok, j["message"] as? String ?? (ok ? "已保存" : "上传失败"))
        } else {
            message = (false, "请求失败")
        }
        await load()
    }

    /// PDFKit 提取文本（文本型 PDF 才有内容）
    private func extractPDFText(from url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var out = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let s = page.string {
                out += s + "\n"
            }
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - v2.0.81b 文档行（拆独立子视图，规避 Swift 6 类型检查超时）

private struct KBRow: View {
    let name: String
    let chunks: Int
    let size: Int
    var onDelete: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: Typography.headline))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: Typography.body, weight: .medium))
                Text("\(chunks) 个片段 · \(size) 字节")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onDelete(name)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - v2.0.82 知识库文档（具体类型，规避字典索引类型检查爆炸）

struct KBDoc: Identifiable {
    let name: String
    let chunks: Int
    let size: Int
    var id: String { name }
}

// MARK: - v2.0.83 粘贴文本上传（LiveContainer 文件选择器无反应的备用通道）

private struct PasteKBSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var content = ""
    var onSave: (String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("文档名称") {
                    TextField("如：TPS6594 手册笔记", text: $name)
                }
                Section("内容（粘贴文本）") {
                    TextEditor(text: $content)
                        .frame(minHeight: 180)
                        .font(.system(size: Typography.subhead))
                }
            }
            .navigationTitle("粘贴文本上传")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines),
                               content)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
