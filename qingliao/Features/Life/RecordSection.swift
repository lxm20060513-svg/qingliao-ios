import SwiftUI

// MARK: - v3.9.71 记录分区（生活页，与「待办清单」并列）
//
// 定位：意图管道里数字类内容（金额 / 表读数）的落点，也是「随手记一笔」的手动入口。
// 视觉口径照抄 TodoSection：页级标题行（标题 + 副标题 + 添加 pill）+ 单张 dashboardCard 页卡 + 空态同几何。
// 生命周期照抄：`.task { await store.loadFromServer() }` —— 只跑一次，不做轮询（记录不需要 30s 刷新）。

struct RecordSection: View {
    @State private var store = RecordStore.shared
    @State private var showAdd = false
    @State private var showAll = false
    @State private var draftTitle = ""
    @State private var draftAmount = ""
    @State private var draftUnit = "元"
    @State private var pendingDelete: RecordItem?
    /// v4.0.19 正在编辑的那一笔（候选池①：原来只能删了重记）
    @State private var editing: RecordItem?
    /// v4.0.19 候选池⑤：明细页的分类筛选（nil = 全部）
    @State private var filterCategory: String?

    private let units = ["元", "度", "kWh"]

    var body: some View {
        root
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { await store.loadFromServer() }
            .sheet(isPresented: $showAdd) { addSheet }
            // 删除确认框必须挂在弹窗自己这棵树上（SR35：宿主级 alert 在弹窗之上呈现不出来）
            .sheet(isPresented: $showAll) { deleteConfirm(on: allSheet) }
    }

    private var root: some View {
        deleteConfirm(on:
            VStack(alignment: .leading, spacing: 8) {
                pageHeader
                if store.records.isEmpty {
                    emptyTap
                } else {
                    topCard
                }
            }
        )
    }

    /// 删除确认框本体已收进 LifeDeleteConfirm（工作线 B：待办/目标/备忘弹窗内那份同款）
    private func deleteConfirm<V: View>(on view: V) -> some View {
        view.modifier(LifeDeleteConfirm(
            title: "删除这条记录？",
            pending: pendingDelete,
            onCancel: { pendingDelete = nil },
            onDelete: { store.delete($0) },
            message: { $0.amountText }
        ))
    }

    // MARK: 页级标题行（与备忘录/待办同款）

    /// 外壳已收进 LifeSectionHeader（工作线 B：备忘/待办/目标三份同款）。
    /// lineLimit(1) 只记录这一处需要（副标题是「本月 x 元 · n 条」，可能偏长）→ 走可选参数。
    private var pageHeader: some View {
        LifeSectionHeader(
            title: "记录",
            subtitle: store.records.isEmpty ? nil : subtitleText,
            subtitleLineLimit: 1,
            addAccessibilityLabel: "添加记录",
            onAdd: startAdd
        )
    }

    private var subtitleText: String {
        let t = store.monthTotal
        guard t.count > 0 else { return "\(store.records.count) 条" }
        return String(format: "本月 %.2f 元 · %d 条", t.amount, t.count)
    }

    // MARK: 空态引导卡（与待办空态同几何）

    private var emptyTap: some View {
        LifeEmptyStateCard(
            icon: "sum",
            title: "随手记一笔",
            // v3.9.71 审查：原文案承诺"复制金额会自动认出来"，但剪贴板探测器**只认链接**
            // （数字类 pattern 误报率太高，刻意不做），所以那句话是空头承诺。改成可达路径。
            subtitle: "截图里的金额/读数可在聊天页点「识别」后记到这里",
            onTap: startAdd
        )
    }

    /// 页级标题行、空态引导卡、卡片长按菜单三处共用这一个入口
    private func startAdd() {
        resetDraft()
        showAdd = true
    }

    // MARK: 单张页卡（本月合计 + 最近读数 + 最近 3 条）

    private var topCard: some View {
        Button {
            showAll = true
        } label: {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("本月合计")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(String(format: "%.2f 元", store.monthTotal.amount))
                        .font(.system(size: Typography.title, weight: .semibold))
                        .monospacedDigit()
                }
                if let meter = store.latestMeter, let v = meter.amount {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.tertiary)
                        Text("最近读数 \(RecordKit.amountText(v, unit: meter.unit))")
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                if !store.monthByCategory.isEmpty {
                    categoryBreakdown
                }
                Divider().opacity(0.4)
                ForEach(Array(store.sorted.prefix(3))) { r in
                    HStack(spacing: 8) {
                        Text(r.title)
                            .font(.system(size: Typography.subhead))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(r.amountText)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if store.records.count > 3 {
                    Text("还有 \(store.records.count - 3) 条")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, minHeight: MemoCardMetrics.minHeight, alignment: .leading)
            .dashboardCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .contextMenu {
            if let top = store.sorted.first {
                Button(role: .destructive) { pendingDelete = top } label: {
                    Label("删除最新一条", systemImage: "trash")
                }
            }
            Button { startAdd() } label: {
                Label("添加记录", systemImage: "plus")
            }
        }
        .accessibilityLabel("记录，本月合计 \(String(format: "%.2f", store.monthTotal.amount)) 元，\(store.records.count) 条，点开查看全部")
    }

    /// v4.0.19 本月分类占比（候选池②的可视部分）。
    /// 本体拆成独立 struct：顶卡已经是 Button label 里的一长串 ViewBuilder，
    /// 再内联一个 GeometryReader 有 type-check 超时风险（本仓踩过，只有 CI 报）。
    private var categoryBreakdown: some View {
        RecordCategoryBar(rows: Array(store.monthByCategory.prefix(3)),
                          total: store.monthTotal.amount)
    }

    // MARK: 全部记录（半屏 sheet，左滑删）

    // MARK: 全部记录（半屏 sheet = 账本明细）

    /// v4.0.19 候选池⑤⑥：明细页 = 顶部「本月进度 + 近 3 月趋势 + 近 7 天」+ 按日分组的账目。
    /// 为什么要分组：一长串平铺的记录看不出「哪天花了多少」，而账本的心智本来就是按天翻。
    /// 分组/小计口径全在 RecordKit.dayGroups（纯逻辑，本机真值表钉着），这里只摆位。
    private var allSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sheetHeader
                List {
                    summaryRow
                    if !categoryChips.isEmpty { chipsRow }
                    ForEach(dayGroups) { g in
                        Section {
                            ForEach(g.items) { r in
                                recordRow(r)
                            }
                            .onDelete { offsets in deleteInGroup(g, offsets) }
                        } header: {
                            dayHeader(g)
                        }
                    }
                    if dayGroups.isEmpty { emptyListRow }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(item: $editing, onDismiss: { editing = nil }) { item in
            RecordEditSheet(item: item) { title, amount, unit, category in
                if store.update(item, title: title, amount: amount, unit: unit, category: category) {
                    Haptics.success()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var sheetHeader: some View {
        HStack(spacing: 8) {
            Text("全部记录")
                .font(.system(size: Typography.title, weight: .semibold))
            Text(subtitleText)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            MiniCapsule(title: "完成", accent: true) { showAll = false }
        }
        .padding(.horizontal, Spacing.section)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.md)
    }

    /// 顶部汇总卡（本月进度 / 趋势 / 近 7 天）—— 本体在 RecordMonthSummary
    private var summaryRow: some View {
        let now = Date()
        return RecordMonthSummary(
            projection: RecordKit.monthProjection(store.records, now: now),
            stats: RecordKit.monthStats(store.records, months: 3, now: now),
            week: RecordKit.recentDays(store.records, days: 7, now: now)
        )
        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.section,
                                  bottom: Spacing.md, trailing: Spacing.section))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// 分类筛选（只有存在分类数据时才出现）：账目一多，平铺列表定位不了「餐饮这个月花了多少」
    private var categoryChips: [String] {
        var set = Set<String>()
        for r in store.records where !r.category.isEmpty { set.insert(r.category) }
        return set.sorted()
    }

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, "全部")
                ForEach(categoryChips, id: \.self) { c in
                    chip(c, RecordKit.categoryLabel(c))
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.section,
                                  bottom: Spacing.md, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func chip(_ value: String?, _ title: String) -> some View {
        let on = filterCategory == value
        return Button {
            filterCategory = value
            Haptics.selection()
        } label: {
            Text(title)
                .font(.system(size: Typography.caption, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(on ? Color.accentColor
                                               : Color(uiColor: .secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    /// 明细页的行集合：按筛选条件过滤后交给 RecordKit 分组（分组内部会重排，顺序不依赖这里）
    private var dayGroups: [DayGroup] {
        let list: [RecordItem]
        if let c = filterCategory {
            list = store.records.filter { $0.category == c }
        } else {
            list = store.records
        }
        return RecordKit.dayGroups(list)
    }

    /// 日组头：日期 + 当日收入（绿）/当日支出小计（灰）。两个小计都为 0 时不摆数字，保持干净。
    private func dayHeader(_ g: DayGroup) -> some View {
        HStack(spacing: 8) {
            Text(g.label)
                .font(.system(size: Typography.subhead, weight: .semibold))
            Spacer(minLength: 0)
            if g.income > 0 {
                Text(String(format: "+%.2f", g.income))
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.green)
                    .monospacedDigit()
            }
            if g.expense > 0 {
                Text(String(format: "支出 %.2f", g.expense))
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Spacing.section)
        .padding(.top, Spacing.md)
        .padding(.bottom, 4)
        .textCase(nil)
        .listRowBackground(Color.clear)
    }

    private func recordRow(_ r: RecordItem) -> some View {
        RecordRowCard(item: r)
            .contentShape(Rectangle())
            // 点按 = 编辑这一笔（用 onTapGesture 而不是包 Button：Button 会跟 List 的左滑删抢手势）
            .onTapGesture { editing = r }
            .contextMenu {
                Button { editing = r } label: {
                    Label("编辑", systemImage: "pencil")
                }
                Button(role: .destructive) { pendingDelete = r } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.section,
                                      bottom: 8, trailing: Spacing.section))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// 左滑删：单行走确认框；批量手势（极少见）直接删。
    /// 分组后 offsets 是**组内**下标 —— 必须映射回该组的 items，不能再去索引全局列表（那是上一版的形态）。
    private func deleteInGroup(_ g: DayGroup, _ offsets: IndexSet) {
        guard offsets.count == 1, let idx = offsets.first, idx < g.items.count else {
            for i in offsets where i < g.items.count { store.delete(g.items[i]) }
            return
        }
        pendingDelete = g.items[idx]
    }

    private var emptyListRow: some View {
        Text(filterCategory == nil ? "还没有记录" : "这个分类还没有记录")
            .font(.system(size: Typography.subhead))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, Spacing.xxl)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    // MARK: 新建（外壳照抄待办新建：取消/保存 toolbar + medium/large）

    private var addSheet: some View {
        NavigationStack {
            VStack(spacing: Spacing.md) {
                TextField("名称（如 超市 / 电表）", text: $draftTitle)
                    .font(.system(size: Typography.title))
                    .padding(Spacing.xl)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))

                HStack(spacing: Spacing.md) {
                    TextField("数值", text: $draftAmount)
                        .font(.system(size: Typography.title))
                        .keyboardType(.decimalPad)
                        .padding(Spacing.xl)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    Picker("单位", selection: $draftUnit) {
                        ForEach(units, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.md)
            .navigationTitle("新建记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAdd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveDraft()
                    }
                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 动作

    private func resetDraft() {
        draftTitle = ""
        draftAmount = ""
        draftUnit = "元"
    }

    private func saveDraft() {
        let value = Double(draftAmount.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces))
        let item = store.add(kind: value == nil ? "note" : (draftUnit == "元" ? "amount" : "meter"),
                             title: draftTitle, amount: value, unit: value == nil ? "" : draftUnit,
                             source: "manual")
        if item != nil { Haptics.success() }
        showAdd = false
    }
}

/// 记录行卡（与 TodoRowCard 同款几何）
private struct RecordRowCard: View {
    let item: RecordItem

    var body: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(MemoItem.relativeTime(item.updatedAt))
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                    if !item.category.isEmpty {
                        Text(RecordKit.categoryLabel(item.category))
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(RecordCategoryColor.tint(item.category))
                    }
                }
            }
            Spacer(minLength: 0)
            Text(item.amountText)
                .font(.system(size: Typography.body, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
        .contentShape(Rectangle())
    }
}

/// v4.0.19 编辑已记的一笔（候选池①）：金额 / 事项 / 单位 / 分类。
/// 几何照抄同文件的新建 sheet（同一批 TextField 样式），差别只有预填 + 保存走 store.update。
/// 「删除」不在这里 —— 它仍在列表的长按菜单上，编辑弹窗只负责改。
private struct RecordEditSheet: View {
    let item: RecordItem
    let onSave: (_ title: String, _ amount: Double?, _ unit: String, _ category: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var amount: String
    @State private var unit: String
    @State private var category: String

    private let units = ["元", "度", "kWh"]

    init(item: RecordItem, onSave: @escaping (String, Double?, String, String) -> Void) {
        self.item = item
        self.onSave = onSave
        _title = State(initialValue: item.title)
        _amount = State(initialValue: item.amount.map { RecordEditSheet.numberText($0) } ?? "")
        _unit = State(initialValue: item.unit.isEmpty ? "元" : item.unit)
        _category = State(initialValue: item.category)
    }

    /// 金额回填去掉无意义尾零：86 → 86、86.5 → 86.5（不能用 %g：大额会变科学计数法）
    static func numberText(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        if s.contains(".") {
            s = s.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        }
        return s
    }

    private var catOptions: [String] {
        var list = ChatRecordKit.allCategories
        // 老数据/将来新增的自定义分类不在词表里时，也要能保住原值（否则一打开就被改成词表首项）
        if !category.isEmpty && !list.contains(category) { list.insert(category, at: 0) }
        return list
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.md) {
                TextField("名称（如 超市 / 电表）", text: $title)
                    .font(.system(size: Typography.title))
                    .padding(Spacing.xl)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))

                HStack(spacing: Spacing.md) {
                    TextField("数值", text: $amount)
                        .font(.system(size: Typography.title))
                        .keyboardType(.decimalPad)
                        .padding(Spacing.xl)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    Picker("单位", selection: $unit) {
                        ForEach(units, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                }

                HStack(spacing: Spacing.md) {
                    Text("分类")
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Picker("分类", selection: $category) {
                        Text(RecordKit.uncategorized).tag("")
                        ForEach(catOptions, id: \.self) { c in
                            Text(c).tag(c)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.md)
            .navigationTitle("编辑记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(title, parsedAmount, unit, category)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// 空 / 非法 → nil（= 这条本来就没有金额，回到「纯文字记录」形态，与新建口径一致）
    private var parsedAmount: Double? {
        let raw = amount.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, let v = Double(raw), v.isFinite else { return nil }
        return v
    }
}

/// 分类色标（只服务占比条与图例）。用系统色而不是新增主题令牌：这几支颜色只此一处用，
/// 进主题反而让「令牌 == 全站语义」的口径变浑浊。哈希自算（djb2）保证同一分类每次同色。
private enum RecordCategoryColor {
    static let palette: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .indigo, .brown]

    static func tint(_ category: String) -> Color {
        let name = RecordKit.categoryLabel(category)
        guard name != RecordKit.uncategorized else { return .gray }
        var h = 5381
        for u in name.unicodeScalars { h = (h &* 33) &+ Int(u.value) }
        return palette[abs(h) % palette.count]
    }
}

/// 分类占比条 + 前三名图例（口径与「本月合计」同源：RecordKit.categoryTotals）
private struct RecordCategoryBar: View {
    let rows: [CategoryTotal]
    let total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(rows) { r in
                        Capsule()
                            .fill(RecordCategoryColor.tint(r.category))
                            .frame(width: max(3, geo.size.width * CGFloat(r.amount / max(total, 0.0001))))
                    }
                }
            }
            .frame(height: 6)
            HStack(spacing: 10) {
                ForEach(rows) { r in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(RecordCategoryColor.tint(r.category))
                            .frame(width: 6, height: 6)
                        Text(r.category)
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", r.amount / max(total, 0.0001) * 100))
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// v4.0.19 候选池⑥：明细页顶部汇总（本月已花 / 日均 / 月末预估 / 近 7 天 / 近 3 月柱状）。
/// 拆成独立 struct 的理由同 RecordCategoryBar：宿主 ViewBuilder 里再堆计算 + 多层 HStack，
/// type-check 会超时（本仓踩过，而且只有 CI 报，本地 -parse 查不出）。
private struct RecordMonthSummary: View {
    let projection: MonthProjection
    let stats: [MonthStat]
    let week: (expense: Double, income: Double, count: Int)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("本月已花")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(String(format: "%.2f 元", projection.spent))
                    .font(.system(size: Typography.title, weight: .semibold))
                    .monospacedDigit()
            }
            HStack(alignment: .top, spacing: 18) {
                metric("日均", String(format: "%.0f", projection.dailyAvg))
                metric("月末预估", String(format: "%.0f", projection.projected))
                metric("近 7 天", String(format: "%.0f", week.expense))
                Spacer(minLength: 0)
            }
            if stats.contains(where: { $0.expense > 0 }) {
                RecordTrendBars(stats: stats)
            }
            Text("月末预估 = 日均 × 当月 " + String(projection.daysInMonth) + " 天，只作参考")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: Typography.subhead, weight: .medium))
                .monospacedDigit()
        }
    }
}

/// 近 N 月迷你柱状（高度按最大值归一；本月那根用实色强调）。
/// 全 0 时调用方不渲染它 —— 零高柱子看上去像 bug。
private struct RecordTrendBars: View {
    let stats: [MonthStat]

    private var peak: Double {
        let m = stats.map { max($0.expense, 0) }.max() ?? 0
        return max(m, 0.0001)
    }

    var body: some View {
        let lastKey = stats.last?.key
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(stats) { s in
                VStack(spacing: 4) {
                    Text(String(format: "%.0f", s.expense))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(s.key == lastKey ? Color.accentColor : Color.accentColor.opacity(0.35))
                        .frame(height: max(3, 44 * CGFloat(s.expense / peak)))
                    Text(s.label)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 78, alignment: .bottom)
    }
}
