import SwiftUI

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
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                        in: Capsule())
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func chunked(_ arr: [String], maxPerRow: Int) -> [[String]] {
        stride(from: 0, to: arr.count, by: maxPerRow).map {
            Array(arr[$0..<min($0 + maxPerRow, arr.count)])
        }
    }
}
