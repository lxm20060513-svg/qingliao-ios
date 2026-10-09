import SwiftUI

// v3.9.85：生活页板块自定义（排序 + 隐藏）——抄看板 BoardCard 模式。
// 顺序/显隐各自持久化（逗号分隔 rawValue），串里没出现的按默认顺序补后面。
enum LifeSection: String, CaseIterable, Identifiable {
    case memo        // 备忘录
    case todo        // 待办清单
    case habit       // v4.0.46 习惯打卡
    case goals       // v4.0.7 长期目标（AI 建目标 + cron 每天推进）
    case record      // 记录
    case automations // 定时任务
    case lifeCards   // 生活数据（行情/资讯/快递/价格）

    var id: String { rawValue }

    var title: String {
        switch self {
        case .memo: return "备忘录"
        case .todo: return "待办清单"
        case .habit: return "习惯"
        case .goals: return "长期目标"
        case .record: return "记录"
        case .automations: return "定时任务"
        case .lifeCards: return "生活数据"
        }
    }

    /// 页级标题行行首图标（v4.0.84 方案 B①）—— 标题行不再是一行裸文字，一眼能分辨板块。
    /// 符号刻意复用各板块**空态卡**的同一个符号（备忘/待办/习惯/目标/记录五处同源），
    /// 免得同一板块在标题行与空态卡上长两个符号。
    var icon: String {
        switch self {
        case .memo: return "square.and.pencil"
        case .todo: return "checklist"
        case .habit: return "checkmark.seal"
        case .goals: return "target"
        case .record: return "sum"
        case .automations: return "clock.arrow.circlepath"
        case .lifeCards: return "chart.line.uptrend.xyaxis"
        }
    }

    /// 图标底色（与 icon 同处一份映射；取各板块语义色，深浅模式由系统色自适应）
    var tint: Color {
        switch self {
        case .memo: return .pink
        case .todo: return .blue
        case .habit: return .green
        case .goals: return .purple
        case .record: return .teal
        case .automations: return .indigo
        case .lifeCards: return .orange
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
        // ⚠️ 2026-09-30（同类风险审计）：顺序串必须写**全量**（shown + 隐藏项），
        // 只写 shown 会把隐藏项从顺序里彻底抹掉 → 之后「显示」恢复时它被 orderedSections
        // 补到列表最末，用户排好的位置被重置。口径对标 BoardCardEditorSheet.persist（SR13）。
        let full = (shown + hiddenList).reduce(into: [LifeSection]()) { acc, s in
            if !acc.contains(s) { acc.append(s) }
        }
        orderRaw = full.map(\.rawValue).joined(separator: ",")
        hiddenRaw = hiddenList.map(\.rawValue).joined(separator: ",")
    }
}
