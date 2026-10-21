import SwiftUI

// v4.0.143 · 工作台栏目自定义（排序 + 隐藏）
//
// 口径**逐条对齐生活页**（LifeSection / LifeSectionEditorSheet，v3.9.85，用户 2026-09-26 拍板）：
//   · 顺序/显隐各自持久化（逗号分隔 rawValue），串里没出现的按 allCases 补后面
//   · 编辑器用 ↑↓ 调序 + eye.slash 隐藏 + 「显示」恢复；**顺序串写全量**（shown + 隐藏项），
//     只写 shown 会让隐藏项被补到末尾，用户排好的位置就丢了（生活页 SR13 的坑）
//   · 入口放页底，低调 pastelCard + tertiary 文字
//
// 与生活页的唯一差别：工作台有两块是「有数据才出现」（待你处理 / 进行项目），
// 它们的空态由各自的 @ViewBuilder 分支吞掉，不占位、也不影响其余栏目的排序。

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case pending     // 待你处理（跨会话未答问题卡）
    case active      // 进行中（会话任务流，2s 轮询）
    case projects    // v4.0.143 进行项目（项目维度台账）
    case goals       // 长期目标
    case artifacts   // 产物库
    case tools       // 工具格

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending: return "待你处理"
        case .active: return "进行中"
        case .projects: return "进行项目"
        case .goals: return "长期目标"
        case .artifacts: return "产物库"
        case .tools: return "工具格"
        }
    }
}

// v4.0.143：工作台栏目编辑器 —— 与 LifeSectionEditorSheet 同款交互
struct WorkspaceSectionEditorSheet: View {
    @AppStorage("workspace_section_order") private var orderRaw = ""
    @AppStorage("workspace_section_hidden") private var hiddenRaw = ""
    @Environment(\.dismiss) private var dismiss
    @State private var shown: [WorkspaceSection] = []
    @State private var hiddenList: [WorkspaceSection] = []

    init(visible: [WorkspaceSection], hidden: [WorkspaceSection]) {
        var seen = Set<WorkspaceSection>()
        _shown = State(initialValue: visible.filter { seen.insert($0).inserted })
        _hiddenList = State(initialValue: hidden.filter { seen.insert($0).inserted })
    }

    var body: some View {
        NavigationStack {
            List {
                Section("显示中（↑↓ 调整顺序）") {
                    ForEach(Array(shown.enumerated()), id: \.element) { idx, s in
                        HStack {
                            Text(s.title)
                            Spacer()
                            Button { move(idx, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(idx == 0)
                                .accessibilityLabel("上移 \(s.title)")
                            Button { move(idx, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(idx == shown.count - 1)
                                .accessibilityLabel("下移 \(s.title)")
                            Button { hide(s, at: idx) } label: { Image(systemName: "eye.slash") }
                                .accessibilityLabel("隐藏 \(s.title)")
                        }
                        .buttonStyle(.borderless)   // List 内按钮防整行抢点
                    }
                }
                if !hiddenList.isEmpty {
                    Section("已隐藏") {
                        ForEach(hiddenList) { s in
                            HStack {
                                Text(s.title).foregroundStyle(.secondary)
                                Spacer()
                                Button("显示") { restore(s) }
                                    .accessibilityLabel("显示 \(s.title)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("自定义栏目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func move(_ idx: Int, by delta: Int) {
        let j = idx + delta
        guard shown.indices.contains(j) else { return }
        shown.swapAt(idx, j)
        persist()
    }

    private func hide(_ s: WorkspaceSection, at idx: Int) {
        guard shown.indices.contains(idx) else { return }
        shown.remove(at: idx)
        if !hiddenList.contains(s) { hiddenList.append(s) }
        persist()
    }

    private func restore(_ s: WorkspaceSection) {
        hiddenList.removeAll { $0 == s }
        shown.append(s)
        persist()
    }

    private func persist() {
        // 顺序串写全量（shown + 隐藏项）—— 只写 shown 会让隐藏项排好的位置丢失
        let full = (shown + hiddenList).reduce(into: [WorkspaceSection]()) { acc, s in
            if !acc.contains(s) { acc.append(s) }
        }
        orderRaw = full.map(\.rawValue).joined(separator: ",")
        hiddenRaw = hiddenList.map(\.rawValue).joined(separator: ",")
    }
}
