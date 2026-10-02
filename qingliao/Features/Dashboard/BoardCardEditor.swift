import SwiftUI

// ⚠️ v4.0.20：`enum BoardCard` 已搬到 qingliao/Core/BoardCardOrder.swift
// （纯 Foundation 的排序逻辑所在，真值表要直接编译它 → 枚举不能留在 import SwiftUI 的文件里）。
// 本文件只管编辑器界面。

/// ⚠️ 排序用「上移/下移」按钮而不是 List 拖动手柄：拖动要常驻 editMode，
/// 而 editMode 激活时行内按钮的点击由系统接管，这行为没法在没真机构建前验证，宁可用最朴素的按钮。
/// v4.0.20：看板上也能**长按栏目标题拖动**排序（DashboardView.sectionTitle 的手势），
/// 这个弹窗仍是「隐藏 / 恢复」与「点按微调」的入口，两种方式共用同一对持久化键。
struct BoardCardEditorSheet: View {
    @AppStorage(BoardCardStore.orderKey) private var orderRaw = ""
    @AppStorage(BoardCardStore.hiddenKey) private var hiddenRaw = ""
    @Environment(\.dismiss) private var dismiss
    @State private var shown: [BoardCard] = []
    @State private var hiddenList: [BoardCard] = []

    init(all: [BoardCard], hidden: [BoardCard]) {
        // SR13：防御性去重（调用方已改传可见卡片，这里再兜一层，避免任何路径把同一卡片
        // 同时塞进两栏 → 重复 id / orderRaw 重复键）
        var seen = Set<BoardCard>()
        _shown = State(initialValue: all.filter { seen.insert($0).inserted })
        _hiddenList = State(initialValue: hidden.filter { seen.insert($0).inserted })
    }

    var body: some View {
        NavigationStack {
            List {
                Section("显示中（↑↓ 调整顺序）") {
                    ForEach(Array(shown.enumerated()), id: \.element) { idx, card in
                        shownRow(card: card, idx: idx)
                    }
                } footer: {
                    Text("也可以直接在看板上长按任意栏目标题后拖动排序，两种方式同步。")
                }
                if !hiddenList.isEmpty {
                    Section("已隐藏") {
                        ForEach(hiddenList) { card in
                            HStack {
                                Text(card.title).foregroundStyle(.secondary)
                                Spacer()
                                Button("显示") { restore(card) }
                                    .accessibilityLabel("显示 \(card.title)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("自定义卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func shownRow(card: BoardCard, idx: Int) -> some View {
        HStack {
            Text(card.title)
            Spacer()
            Button { move(idx, by: -1) } label: { Image(systemName: "arrow.up") }
                .disabled(idx == 0)
                .accessibilityLabel("上移 \(card.title)")
            Button { move(idx, by: 1) } label: { Image(systemName: "arrow.down") }
                .disabled(idx == shown.count - 1)
                .accessibilityLabel("下移 \(card.title)")
            Button { hide(card, at: idx) } label: { Image(systemName: "eye.slash") }
                .accessibilityLabel("隐藏 \(card.title)")
        }
        .buttonStyle(.borderless)   // List 内按钮默认会被染色并抢走整行点击
    }

    private func move(_ idx: Int, by delta: Int) {
        let j = idx + delta
        guard shown.indices.contains(j) else { return }
        shown.swapAt(idx, j)
        persist()
    }

    private func hide(_ card: BoardCard, at idx: Int) {
        guard shown.indices.contains(idx) else { return }
        shown.remove(at: idx)
        if !hiddenList.contains(card) { hiddenList.append(card) }   // SR13：防重复入隐藏栏
        persist()
    }

    private func restore(_ card: BoardCard) {
        hiddenList.removeAll { $0 == card }
        if !shown.contains(card) { shown.append(card) }             // SR13：防重复入显示栏
        persist()
    }

    private func persist() {
        // 隐藏项也留在顺序串里：否则恢复时它会被 orderedCards 补到末尾，丢掉用户原本排的位置
        // SR13：写串前去重——orderRaw 里的重复键会原样流回 orderedCards（saved 不做去重），
        // 造成看板重复渲染同一张卡片。
        var seen = Set<BoardCard>()
        let uniq = (shown + hiddenList).filter { seen.insert($0).inserted }
        orderRaw = uniq.map(\.rawValue).joined(separator: ",")
        seen = []
        hiddenRaw = hiddenList.filter { seen.insert($0).inserted }.map(\.rawValue).joined(separator: ",")
    }
}

// MARK: - 服务控制 sheet（HomeKit 卡片式：信息卡 + 重试卡 + 停止卡）

/// v3.0.36：服务类型（轻聊后端 / Hermes 网关）
