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
}

// v3.9.85：生活页板块编辑器——与看板 BoardCardEditorSheet 同款交互（↑↓ 调序 / 隐藏 / 恢复）
//
// v4.0.80（P2 条目 8）：编辑器只服务**本口径目录**里的板块（`catalog` 由调用方从
//   `WorkbenchLayout.lifeSectionCatalogRaws` 取，本视图不判模式）。工作模式目录里没有
//   「定时任务 / 生活数据」→ 不列出来（列出来等于暗示用户能在本模式把移出的板块调回来）。
//   但**目录外的老配置必须原样留串**（`WorkbenchLayout.mergeLifeSectionPersist`）——
//   否则在工作模式里动一下排序，切回生活模式就发现那两个板块的显隐/位置被抹了（条目 11 同款口径）。
struct LifeSectionEditorSheet: View {
    @AppStorage("life_section_order") private var orderRaw = ""
    @AppStorage("life_section_hidden") private var hiddenRaw = ""
    @Environment(\.dismiss) private var dismiss
    @State private var shown: [LifeSection] = []
    @State private var hiddenList: [LifeSection] = []
    /// 本口径下的板块目录（rawValue）；目录外的一律不进本编辑器
    private let catalog: [String]

    init(visible: [LifeSection], hidden: [LifeSection], catalog: [String]) {
        var seen = Set<LifeSection>()
        _shown = State(initialValue: visible.filter { seen.insert($0).inserted })
        _hiddenList = State(initialValue: hidden.filter { seen.insert($0).inserted })
        self.catalog = catalog
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
        // v4.0.80：写回统一走 WorkbenchLayout.mergeLifeSectionPersist —— 在上一句的基础上再补一条
        // **目录外老条目原样留串**（工作模式下「定时任务 / 生活数据」不在目录里，不许被顺手写掉）。
        let merged = WorkbenchLayout.mergeLifeSectionPersist(
            catalog: catalog,
            shown: shown.map(\.rawValue),
            hidden: hiddenList.map(\.rawValue),
            prevOrder: WorkbenchLayout.parseRaws(orderRaw),
            prevHidden: WorkbenchLayout.parseRaws(hiddenRaw))
        orderRaw = merged.order
        hiddenRaw = merged.hidden
    }
}
