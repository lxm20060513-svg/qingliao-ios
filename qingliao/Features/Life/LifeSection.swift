import SwiftUI

// v3.9.85：生活页板块自定义（排序 + 隐藏）——抄看板 BoardCard 模式。
// 顺序/显隐各自持久化（逗号分隔 rawValue），串里没出现的按默认顺序补后面。
enum LifeSection: String, CaseIterable, Identifiable {
    case memo        // 备忘录
    case todo        // 待办清单
    case record      // 记录
    case automations // 定时任务
    case lifeCards   // 生活数据（行情/资讯/快递/价格）

    var id: String { rawValue }

    var title: String {
        switch self {
        case .memo: return "备忘录"
        case .todo: return "待办清单"
        case .record: return "记录"
        case .automations: return "定时任务"
        case .lifeCards: return "生活数据"
        }
    }
}

// v3.9.85：生活页板块编辑器——与看板 BoardCardEditorSheet 同款交互（↑↓ 调序 / 隐藏 / 恢复）
struct LifeSectionEditorSheet: View {
    @AppStorage("life_section_order") private var orderRaw = ""
    @AppStorage("life_section_hidden") private var hiddenRaw = ""
    @Environment(\.dismiss) private var dismiss
    @State private var shown: [LifeSection] = []
    @State private var hiddenList: [LifeSection] = []

    init(visible: [LifeSection], hidden: [LifeSection]) {
        var seen = Set<LifeSection>()
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
            .navigationTitle("自定义板块")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
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

    private func hide(_ s: LifeSection, at idx: Int) {
        guard shown.indices.contains(idx) else { return }
        shown.remove(at: idx)
        if !hiddenList.contains(s) { hiddenList.append(s) }
        persist()
    }

    private func restore(_ s: LifeSection) {
        hiddenList.removeAll { $0 == s }
        shown.append(s)
        persist()
    }

    private func persist() {
        orderRaw = shown.map(\.rawValue).joined(separator: ",")
        hiddenRaw = hiddenList.map(\.rawValue).joined(separator: ",")
    }
}
