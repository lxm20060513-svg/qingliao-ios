// MARK: - v3.7.0 生活页「备忘录」栏目
// v3.9.14：体验升级——便签化卡片 / 置顶 / 相对时间 / 来源图标 / 折叠 / 可编辑 / 一键发给 AI
import SwiftUI

struct MemoSection: View {
    @State private var store = MemoStore.shared
    @State private var showAdd = false
    @State private var draft = ""
    @State private var detail: MemoItem?
    @State private var pendingDelete: MemoItem?
    /// v3.9.14：折叠——这张卡在生活页里，备忘一多会把别的栏目整屏挤下去
    @State private var expanded = false

    private let collapsedCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // v3.9.16：标题从卡片里搬出来做页级大标题——卡片内只剩条目，更像一张纸
            bigHeader
            if store.memos.isEmpty {
                emptyTap
            } else {
                VStack(spacing: 0) {
                    ForEach(visibleMemos) { m in
                        memoRow(m)
                    }
                    if store.sorted.count > collapsedCount {
                        expandToggle
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // v3.9.16：横线笔记本底（暖白纸 + 27pt 横线 + 左侧红边线）
                .background(MemoPaper())
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
                // v3.9.16：不给卡片加阴影——全站 dashboardCard 一律平（LiquidGlass.swift:77-89），
                // 只有 GlassCard 有阴影；单卡浮起来会和相邻卡片不是一套层次
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // v3.7.0：进入生活页即拉 NAS 上的备忘（本地已有则远端为空时不清本地）
        .task { await store.loadFromServer() }
        .sheet(isPresented: $showAdd) { addSheet }
        .sheet(item: $detail) { m in
            MemoDetailSheet(item: m, onDelete: { item in
                detail = nil
                // 等 detail sheet 完全 dismiss 再弹确认框（同一帧里同时 present 会丢弹窗）
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    pendingDelete = item
                }
            })
            .presentationDetents([.medium, .large])
        }
        .alert("删除这条备忘？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let item = pendingDelete { store.delete(item) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.content.prefix(40).description ?? "")
        }
    }

    /// v3.9.14：列表顺序 = 置顶优先、再按最后修改时间倒序（读 store.sorted，不是 memos 的插入序）
    private var visibleMemos: [MemoItem] {
        let all = store.sorted
        return expanded ? all : Array(all.prefix(collapsedCount))
    }

    // MARK: 页级大标题（v3.9.16：从卡片里搬出来，做成页级标题）

    private var bigHeader: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("备忘录")
                    .font(.system(size: Typography.titleXL, weight: .bold))
                if !store.memos.isEmpty {
                    Text("\(store.memos.count) 条")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button {
                draft = ""
                showAdd = true
            } label: {
                // v3.9.16：实色胶囊（原来是 accentColor.opacity(0.12)，压在卡片上几乎看不清）
                Text("添加")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 30)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("添加备忘录")
        }
    }



    /// v3.9.14：空态改成"可点的引导卡"——原来那句话是说明书腔，现在点了就能写
    private var emptyTap: some View {
        Button {
            draft = ""
            showAdd = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("记点什么")
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.primary)
                    Text("聊天里长按消息、大爆炸选词，都能存进来")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            // v3.9.16：空态也排在纸的版心内——原来左右各 10，文字横跨左侧红边线（审查发现）
            .padding(.leading, 46)
            .padding(.trailing, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MemoPaper())
            // v3.9.16：圆角跟列表纸卡一致（12 是全站唯一的第二档卡片圆角）
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    // MARK: 便签卡

    @ViewBuilder
    private func memoRow(_ m: MemoItem) -> some View {
        Button {
            detail = m
        } label: {
            HStack(spacing: 0) {
                // v3.9.16：置顶 = 左侧蓝书签条（贴在红边线内侧）
                if m.pinned {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, 11)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(m.content)
                        .font(.system(size: Typography.body))
                        // v3.9.16：行距凑成纸的 27pt 网格（字号 15 行高≈18 + 9 ≈ 27），
                        // 这样同一条备忘内的多行文字落在横线上；条与条之间因行高不是网格整数倍仍有累积错位
                        .lineSpacing(9)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        if m.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: Typography.tiny))
                                .foregroundStyle(Color.accentColor)
                        }
                        // v3.9.14：来源用图标代替文字（省一行宽度，一眼看出从哪来的）
                        Image(systemName: m.sourceIcon)
                            .font(.system(size: Typography.tiny))
                        Text(m.timeText)
                            .font(.system(size: Typography.caption))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.tertiary)
                }
                .padding(.leading, m.pinned ? 9 : 12)
                .padding(.trailing, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // v3.9.16：整行让出左侧红边线（43pt），文字就像写在横线本上
            // v3.9.14 的独立白/灰小卡片底已去掉——现在卡片本身就是纸，条目之间靠纸的横线分隔
            .padding(.leading, 46)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .contextMenu {
            Button {
                store.togglePin(m)
                Haptics.success()
            } label: {
                Label(m.pinned ? "取消置顶" : "置顶", systemImage: m.pinned ? "pin.slash" : "pin")
            }
            Button {
                sendToAI(m)
            } label: {
                Label("发给 AI", systemImage: "paperplane")
            }
            Button {
                UIPasteboard.general.string = m.content
                Haptics.success()
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                pendingDelete = m
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var expandToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.22)) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(expanded ? "收起" : "全部 \(store.sorted.count) 条")
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
            }
            .font(.system(size: Typography.subhead, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    /// v3.9.14：把备忘内容作为一条用户消息发给 AI，并切回聊天页。
    /// 备忘存下来只能复制粘贴没意义——能直接接着办才是轻聊备忘录区别于系统备忘录的地方。
    private func sendToAI(_ m: MemoItem) {
        NotificationCenter.default.post(name: .qingliaoMemoSend, object: m.content)
        Haptics.success()
    }

    // MARK: 新增

    private var addSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $draft)
                    .font(.system(size: Typography.title))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("写点什么…")
                                .font(.system(size: Typography.title))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 17)
                                .padding(.vertical, 20)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("新建备忘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAdd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if store.add(content: draft, source: "manual") {
                            Haptics.success()
                        }
                        showAdd = false
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 放大查看 / 编辑（点卡片进入）

private struct MemoDetailSheet: View {
    let item: MemoItem
    var onDelete: (MemoItem) -> Void

    @Environment(\.dismiss) private var dismiss
    /// v3.9.14：本地副本——编辑/置顶后要立刻反映在本页（item 是传值进来的）
    @State private var current: MemoItem
    @State private var editing = false
    @State private var editText = ""
    @State private var copied = false

    init(item: MemoItem, onDelete: @escaping (MemoItem) -> Void) {
        self.item = item
        self.onDelete = onDelete
        _current = State(initialValue: item)
    }

    private var store = MemoStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if editing {
                        // v3.9.14：补上编辑（MemoStore.update 早就写好了，一直没入口）
                        TextEditor(text: $editText)
                            .font(.system(size: Typography.body))
                            .lineSpacing(6)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220, alignment: .topLeading)
                            .padding(10)
                            // v3.9.16：编辑框在纸上用半透明白 + 细描边（原来是不透明灰底，压在纸上像贴了块补丁）
                            .background(Color.primary.opacity(0.06),   // 自适应：浅色=淡黑、深色=淡白
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8))
                    } else {
                        Text(current.content)
                            .font(.system(size: Typography.headline))
                            .lineSpacing(6)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 6) {
                        if current.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: Typography.tiny))
                                .foregroundStyle(Color.accentColor)
                        }
                        Image(systemName: current.sourceIcon)
                            .font(.system(size: Typography.tiny))
                        // subtitle 本身已含来源（"手记 · 刚刚"），别再叠一次 sourceLabel
                        Text(current.subtitle)
                            .font(.system(size: Typography.subhead))
                    }
                    .foregroundStyle(.tertiary)
                }
                // v3.9.16：让出左侧红边线，内容排在纸上
                .padding(.leading, 46)
                .padding(.trailing, 20)
                .padding(.vertical, 18)
            }
            .background(MemoPaper())
            .navigationTitle(editing ? "编辑备忘" : "备忘录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if editing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { editing = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { saveEdit() }
                            .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .confirmationAction) {
                        Button {
                            editText = current.content
                            editing = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("编辑")
                        Button {
                            UIPasteboard.general.string = current.content
                            Haptics.success()
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .accessibilityLabel("复制内容")
                    }
                }
            }
            // 编辑态禁止下滑关闭：不然手一滑草稿就没了，且没有任何提示
            .interactiveDismissDisabled(editing)
            // 编辑态下藏底部操作条，免得"删除"和"保存"挨着误触
            .safeAreaInset(edge: .bottom) {
                if !editing {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Button {
                                store.togglePin(current)
                                current.pinned.toggle()
                                Haptics.success()
                            } label: {
                                Label(current.pinned ? "取消置顶" : "置顶",
                                      systemImage: current.pinned ? "pin.slash" : "pin")
                                    .font(.system(size: Typography.subhead, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 34)
                                    // v3.9.16：已置顶时「取消置顶」是次要动作 → 灰底；未置顶时「置顶」是主操作 → 实色
                                    .background(current.pinned ? AnyShapeStyle(Color.secondary.opacity(0.14))
                                                               : AnyShapeStyle(Color.accentColor),
                                                in: Capsule())
                                    .foregroundStyle(current.pinned ? Color.secondary : Color.white)
                            }
                            .buttonStyle(PressStyle())

                            Button {
                                NotificationCenter.default.post(name: .qingliaoMemoSend, object: current.content)
                                Haptics.success()
                                dismiss()
                            } label: {
                                Label("发给 AI", systemImage: "paperplane")
                                    .font(.system(size: Typography.subhead, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 34)
                                    .background(Color.accentColor, in: Capsule())
                                    .foregroundStyle(Color.white)
                            }
                            .buttonStyle(PressStyle())
                        }
                        Button(role: .destructive) {
                            onDelete(current)
                        } label: {
                            Label("删除这条备忘", systemImage: "trash")
                                .font(.system(size: Typography.subhead, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                // v3.9.16：实心红底白字（用户指定；半透明红看不清内容，描边又不醒目）
                                .background(Color.red, in: Capsule())
                                .foregroundStyle(Color.white)
                        }
                        .buttonStyle(PressStyle())
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                    // v3.9.16：条子也要有纸底——否则底部露出一条无纹理、红边线断开的系统底（审查发现）
                    .background(MemoPaper())
                }
            }
        }
    }

    private func saveEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.update(current, content: text)
        // 只有内容真变了才动本地副本的时间：store.update 在内容未变时什么都不做，
        // 这里若无条件改，详情页会显示"刚刚"而存储里没变（两处时间分叉）
        if current.content != text {
            current.content = text
            current.updatedAt = Date()
        }
        editing = false
        Haptics.success()
    }
}

/// v3.9.16：横线笔记本纸 = 暖白 #FDFCF8 + 27pt 横线 + 左侧红边线
/// 抽成文件级 View 让列表卡片和详情页共用同一张纸（原来挂在 MemoSection 里，详情页那个 struct 够不着）。
/// 用 Canvas 画线而不是叠图片：随高度自适应、深浅模式都不用换图。
private struct MemoPaper: View {
    /// v3.9.16：网格步长 / 起始相位留成参数——横线与文字的对齐要在真机上微调，从这里改不影响纸的实现
    var lineStep: CGFloat = 27
    var phase: CGFloat = 0
    /// v3.9.16：必须跟着深浅色走——App 有深色模式，写死暖白会在深色下刺眼
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // 颜色先在闭包外取成局部常量：Canvas 的 renderer 不碰 self，避开 Swift 6 并发检查
        let paper = scheme == .dark
            ? Color(red: 0.109, green: 0.105, blue: 0.102)   // 深色：暖调近黑
            : Color(red: 0.992, green: 0.988, blue: 0.973)   // 浅色：#FDFCF8 暖白
        let rule = scheme == .dark
            ? Color(red: 0.243, green: 0.267, blue: 0.310)
            : Color(red: 0.863, green: 0.902, blue: 0.949)
        let marginRule = scheme == .dark
            ? Color(red: 0.439, green: 0.267, blue: 0.267)
            : Color(red: 0.937, green: 0.706, blue: 0.706)

        ZStack(alignment: .topLeading) {
            paper
            Canvas { ctx, size in
                var lines = Path()
                var y: CGFloat = phase
                while y < size.height + lineStep {
                    lines.move(to: CGPoint(x: 0, y: y))
                    lines.addLine(to: CGPoint(x: size.width, y: y))
                    y += lineStep
                }
                ctx.stroke(lines, with: .color(rule), lineWidth: 1)
                var margin = Path()
                margin.move(to: CGPoint(x: 43, y: 0))
                margin.addLine(to: CGPoint(x: 43, y: size.height))
                ctx.stroke(margin, with: .color(marginRule), lineWidth: 1)
            }
        }
    }
}
