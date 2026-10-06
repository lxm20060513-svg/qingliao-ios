import SwiftUI

// MARK: - v3.9.71 记录分区（生活页，与「待办清单」并列）
//
// 定位：意图管道里数字类内容（金额 / 表读数）的落点，也是「随手记一笔」的手动入口。
// 视觉口径照抄 TodoSection：页级标题行（标题 + 副标题 + 添加 pill）+ 单张 pastelCard 页卡 + 空态同几何。
// 生命周期照抄：`.task { await store.loadFromServer() }` —— 只跑一次，不做轮询（记录不需要 30s 刷新）。

struct RecordSection: View {
    @State private var store = RecordStore.shared
    @State private var showAdd = false
    @State private var showAll = false
    @State private var draftTitle = ""
    @State private var draftAmount = ""
    @State private var draftUnit = "元"
    @State private var pendingDelete: RecordItem?
    /// v4.0.23：记录卡片 → 全部记录弹窗的 zoom 源命名空间（对齐备忘录/待办/目标：从卡片放大展开）
    @Namespace private var recordZoomNS
    /// v4.0.19 正在编辑的那一笔（候选池①：原来只能删了重记）
    @State private var editing: RecordItem?
    /// v4.0.19 候选池⑤：明细页的分类筛选（nil = 全部）
    @State private var filterCategory: String?
    /// v4.0.19 候选池⑦：设月预算的弹窗
    @State private var showBudget = false
    /// v4.0.19 候选池⑨：固定支出管理弹窗
    @State private var showFixed = false
    /// v4.0.19 候选池⑫：导出的 CSV 临时文件（nil = 还没生成/生成失败）
    @State private var csvURL: URL?
    @State private var showExport = false
    /// v4.0.22 候选池⑪ App 入口：扫账单（拍照/选图 → 识别 → 确认入账）
    @State private var showBillScan = false
    /// 扫账单弹窗的「会话号」：每次打开自增，配合 `.id(...)` 强制换新实例
    /// （SwiftUI 会保留已 present 过视图的 @State，不换实例会带回上一张图/上一次金额）
    @State private var billScanSession = 0
    /// v4.0.45 待做池④：生活数据可视化报表（折线趋势 + 分类环图，独立半屏页）
    @State private var showReport = false

    private let units = ["元", "度", "kWh"]

    var body: some View {
        root
            .modifier(RecordSectionBodyChrome(host: self))
            .modifier(RecordSectionBodySheets(host: self))
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
            onAdd: startAdd,
            // v4.0.22：扫账单入口恒在（空态也要能扫，别逼用户先手记一笔再看见入口）
            // 先自增会话号再 present：配合上面的 `.id(...)` 保证每次打开都是全新实例
            secondaryAction: (title: "扫账单", action: {
                billScanSession += 1
                showBillScan = true
            })
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

    // MARK: 单张页卡（本月合计 + 最近读数 + 最近 1 条）
    // v4.0.62（用户 2026-10-05 真机）：3→2 后再收成 1 条，其余仍进「全部记录」弹窗

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
                ForEach(Array(store.sorted.prefix(1))) { r in
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
                if store.records.count > 1 {
                    Text("还有 \(store.records.count - 1) 条")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, minHeight: MemoCardMetrics.minHeight, alignment: .leading)
            .pastelCard()
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
        // v4.0.23：卡片即 zoom 源（点开「全部记录」时从这张卡放大展开，对齐备忘录/待办/目标卡片）
        .matchedTransitionSource(id: "record-all", in: recordZoomNS)
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
        // v4.0.23：与备忘录/待办/目标对齐 —— 半屏 detents + 从卡片放大展开（原来这里是全屏升起）
        .presentationDetents([.medium, .large])
        .navigationTransition(.zoom(sourceID: "record-all", in: recordZoomNS))
        .sheet(item: $editing, onDismiss: { editing = nil }) { item in
            RecordEditSheet(item: item) { title, amount, unit, category in
                if store.update(item, title: title, amount: amount, unit: unit, category: category) {
                    Haptics.success()
                }
            }
        }
        // 预算弹窗必须挂在这个 sheet 自己这棵树上（SR35：宿主级 sheet 在弹窗之上呈现不出来）
        .sheet(isPresented: $showBudget) {
            RecordBudgetSheet(current: store.monthBudget) { store.setBudget($0) }
        }
        .sheet(isPresented: $showExport) {
            if let csvURL { ActivityShareSheet(items: [csvURL]) }
        }
        // v4.0.45 待做池④：数据报表（独立页；detents 由 RecordReportSheet 自带）
        .sheet(isPresented: $showReport) { RecordReportSheet() }
        .sheet(isPresented: $showFixed) {
            FixedExpenseSheet()
                // v4.0.20：原来挂在宿主链上（对弹窗不生效）→ 移进 sheet 内容
                .presentationDetents([.medium, .large])
        }
    }

    /// 候选池⑫：导出账本 CSV（复用手势同款 ChatComponents.TableCSVExport：RFC 4180 转义 + UTF-8 BOM，
    /// 中文用 Excel/WPS 直接打开不乱码；行构造在 RecordKit.csvRows，真值表钉着）
    private func exportCSV() {
        csvURL = TableCSVExport.makeCSV(rows: RecordKit.csvRows(store.records), name: "账本")
        showExport = csvURL != nil
        if showExport { Haptics.success() } else { Haptics.error() }
    }

    private var sheetHeader: some View {
        HStack(spacing: 8) {
            Text("全部记录")
                .font(.system(size: Typography.title, weight: .semibold))
            Text(subtitleText)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            // v4.0.45 待做池④：数据报表入口（折线趋势 + 分类环图）
            Button { showReport = true } label: {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .padding(Spacing.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("数据报表")
            // 候选池⑫：导出账本 CSV（导**全部**账目，不受上面的分类筛选影响 —— 导出是备份，不是视图截图）
            Button(action: exportCSV) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .padding(Spacing.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("导出账本 CSV")
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
            week: RecordKit.recentDays(store.records, days: 7, now: now),
            budget: store.monthBudget,
            onSetBudget: { showBudget = true },
            fixed: store.fixedExpenses.filter { $0.enabled },
            onManageFixed: { showFixed = true }
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
            HStack(spacing: 4) {
                // v4.0.65：胶囊配图标（与明细行同一张映射表）；「全部」没有分类，不配图标
                if let v = value {
                    Image(systemName: RecordKit.categoryIcon(v))
                        .font(.system(size: Typography.tiny, weight: .medium))
                }
                Text(title)
            }
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
            // v4.0.65（方案 B）：行首分类色块 + 白色符号
            CategoryBadge(category: item.category)
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
        .pastelCard()
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
                        Label(RecordKit.uncategorized, systemImage: RecordKit.categoryIcon("")).tag("")
                        ForEach(catOptions, id: \.self) { c in
                            Label(c, systemImage: RecordKit.categoryIcon(c)).tag(c)
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

/// 分类色标（只服务占比条与图例，以及报表环图）。用系统色而不是新增主题令牌：这几支颜色只此几处用，
/// 进主题反而让「令牌 == 全站语义」的口径变浑浊。哈希自算（djb2）保证同一分类每次同色。
/// v4.0.45 待做池④：报表环图复用同一调色板 → 从 `private` 放开到模块内可见（单一来源，别在报表里再抄一份）。
/// v4.0.65（用户 2026-10-05 出稿拍板「方案 B」）：分类色块 = 彩色圆角方块 + 白色分类符号。
/// 几何照出稿：边长 36、圆角 = 0.305×边长（36→11）、符号字号 = 0.5×边长（36→18）。
/// 空分类也画（兜底托盘、灰底）——否则有图标/无图标的行左边缘参差。
/// 稿：/opt/data/scripts/ql_record/mock/out/record_icons.png
struct CategoryBadge: View {
    let category: String
    var size: CGFloat = 36

    var body: some View {
        // v4.0.65 审查（严重）：几何（边长 / 圆角 0.305×边长 / 符号 0.5×边长 / 白符号 / a11yHidden）
        // **单出口走 BadgeShell**，与备忘·待办行首色块共用一份 —— 原先这里逐字抄了第二份，
        // 改一处必漏一处（BadgeShell 头注却自称「只此一处」）。
        Image(systemName: RecordKit.categoryIcon(category))
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.white)
            // 分类名在行内已有文字（方案 B 保留分类名）→ 图标不重复播报
            .modifier(BadgeShell(size: size, color: RecordCategoryColor.tint(category)))
    }
}

enum RecordCategoryColor {
    static let palette: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .indigo, .brown]

    static func tint(_ category: String) -> Color {
        // v4.0.65 审查（一般）：图标侧已把「居住/居家」「其他/其它」当**同一分类**
        //（见 RecordKit.categoryIcon 的别名 case），配色侧必须**归一后再 hash** —— 否则同一概念
        // 会取到两种颜色（账单扫描落「居住」、记账/聊天落「居家」，同屏并见时肉眼可辨）。
        var name = RecordKit.categoryLabel(category)
        switch name {
        case "居住": name = "居家"
        case "其他": name = "其它"
        default: break
        }
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
    /// 候选池⑦：月预算（0 = 没设）
    let budget: Double
    var onSetBudget: () -> Void = {}
    /// 候选池⑨：已启用的固定支出（显示条数与每月合计）
    var fixed: [FixedExpense] = []
    var onManageFixed: () -> Void = {}

    /// 固定支出摘要文案（抽出来：插值里塞 reduce 闭包会让这个 View 的类型检查变慢，本仓踩过）
    private var fixedSummary: String {
        guard !fixed.isEmpty else { return "还没设" }
        var sum = 0.0
        for f in fixed { sum += f.amount }
        return "\(fixed.count) 项 · 每月 \(String(format: "%.0f", sum)) 元"
    }

    /// 固定支出一行：条数 + 每月合计（金额是"每月固定要出"的钱，和本月已花的进度无关）
    private var fixedRow: some View {
        HStack(spacing: 8) {
            Text("固定支出")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text(fixedSummary)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(action: onManageFixed) {
                Text("管理")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("管理固定支出")
        }
    }

    private var level: BudgetLevel {
        RecordKit.budgetLevel(spent: projection.spent, budget: budget)
    }

    private var levelColor: Color {
        switch level {
        case .over: return .red
        case .near: return .orange
        default: return Color.secondary
        }
    }

    /// 超支/接近时才染色的进度条：封顶 100%（超了条就满，"超了多少"由文案说）
    private var budgetBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(levelColor)
                    .frame(width: max(3, geo.size.width
                        * CGFloat(min(RecordKit.budgetRatio(spent: projection.spent, budget: budget), 1))))
            }
        }
        .frame(height: 6)
    }

    private var budgetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("月预算")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text(RecordKit.budgetText(spent: projection.spent, budget: budget))
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(levelColor)
                    .monospacedDigit()
                Button(action: onSetBudget) {
                    Text(budget > 0 ? "改" : "设置")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(budget > 0 ? "修改月预算" : "设置月预算")
            }
            if budget > 0 { budgetBar }
        }
    }

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
            budgetRow
            fixedRow
            if stats.contains(where: { $0.expense > 0 }) {
                RecordTrendBars(stats: stats)
            }
            Text("月末预估 = 日均 × 当月 " + String(projection.daysInMonth) + " 天，只作参考")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard()
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

/// v4.0.19 候选池⑦：设月预算（留空 / 0 = 不设预算）。
/// 几何照抄同文件的新建/编辑 sheet，差别是只有一个金额输入 + 「0 = 清除」的口径写在副标题里。
private struct RecordBudgetSheet: View {
    let current: Double
    let onSave: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(current: Double, onSave: @escaping (Double) -> Void) {
        self.current = current
        self.onSave = onSave
        _text = State(initialValue: current > 0 ? RecordEditSheet.numberText(current) : "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.md) {
                TextField("月预算（元）", text: $text)
                    .font(.system(size: Typography.title))
                    .keyboardType(.decimalPad)
                    .padding(Spacing.xl)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                Text("留空或填 0 = 不设预算。预算只统计「元」支出：收入与电表读数都不计入。")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.md)
            .navigationTitle("月预算")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(parsed)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// 非法 / 空 / ≤0 → 0（= 清除预算），与「留空就是不设」的口径一致
    private var parsed: Double {
        let raw = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Double(raw), v.isFinite, v > 0 else { return 0 }
        return v
    }
}

/// v4.0.19 候选池⑨：固定支出管理（房租 / 宽带 / 订阅 —— 到日子自动记一笔）
/// 直接读 store（@Observable）：增删/开关后列表要立刻刷新，走闭包传值的话 sheet 里那份副本不会更新。
private struct FixedExpenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = RecordStore.shared

    @State private var title = ""
    @State private var amountText = ""
    @State private var category = ""
    @State private var day = 1

    private var parsedAmount: Double {
        let raw = amountText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Double(raw), v.isFinite, v > 0 else { return 0 }
        return v
    }

    private var canAdd: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedAmount > 0
    }

    private var catOptions: [String] {
        var list = ChatRecordKit.allCategories
        if !category.isEmpty && !list.contains(category) { list.insert(category, at: 0) }
        return list
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("事项（房租 / 宽带 / 订阅…）", text: $title)
                    TextField("金额（元）", text: $amountText)
                        .keyboardType(.decimalPad)
                    Picker("分类", selection: $category) {
                        Label(RecordKit.uncategorized, systemImage: RecordKit.categoryIcon("")).tag("")
                        ForEach(catOptions, id: \.self) { c in
                            Label(c, systemImage: RecordKit.categoryIcon(c)).tag(c)
                        }
                    }
                    Stepper("每月 \(day) 日", value: $day, in: 1...28)
                    Button("添加") {
                        store.addFixed(title: title, amount: parsedAmount, category: category, day: day)
                        Haptics.success()
                        title = ""
                        amountText = ""
                        category = ""
                        day = 1
                    }
                    .disabled(!canAdd)
                } header: {
                    Text("新增")
                } footer: {
                    Text("到日子自动记一笔（来源标「固定支出」）。日期上限 28 号：29-31 号在小月不存在，宁晚不误。")
                }

                Section {
                    if store.fixedExpenses.isEmpty {
                        Text("还没有固定支出")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(store.fixedExpenses) { f in
                        HStack(spacing: 10) {
                            // 全仓开关口径：一律走 qingliaoSwitch()（尺寸/配色/标签三件事一处定）
                            Toggle("", isOn: Binding(get: { f.enabled },
                                                     set: { store.setFixedEnabled(f.id, $0) }))
                                .qingliaoSwitch()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.title)
                                    .font(.system(size: Typography.subhead))
                                Text("每月 \(f.day) 日 · \(String(format: "%.2f", f.amount)) 元"
                                     + (f.lastApplied.isEmpty ? "" : " · 本月已记"))
                                    .font(.system(size: Typography.caption))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets where i < store.fixedExpenses.count {
                            store.removeFixed(store.fixedExpenses[i].id)
                        }
                    }
                } header: {
                    Text("已设 \(store.fixedExpenses.count) 项")
                }
            }
            .navigationTitle("固定支出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 设置页弹窗口径：顶栏「完成」一律放左（cancellationAction）
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - v4.0.50 启动链类型折叠（防启动期 demangler 递归爆主线程 1MB 栈）
//
// 事故与 ChatView（v4.0.49）/ DashboardView（v4.0.50）同源：本文件 body 返回类型名里
// **内联**了每条 .sheet 内容闭包的完整类型（各 sheet 的正文视图树），dSYM 实测 body 的
// mangled 类型名 1236 字符。危险量是**名字的字符数**（≈19 字符 = 1 帧 demangler 递归，
// 每帧 ~9.3KB 主线程栈），TabView 启动即渲染本页，与其它视图叠加可吃干 1MB 栈 → 一点开就闪退。
//
// 修法 = 把 body 的修饰器链折成具名 ViewModifier 分组：父类型名里只剩组名，链在各组自己的
// applyXxx 调用里解析（各自一次 1MB 栈预算）。⚠️ 修饰器**种类/数量/顺序/参数**逐字未变
// （等价重构，视图树与身份/动画真源不动）；谁也不许把这些链再内联回 body ——
// 改链请改这里的 applyXxx，别动调用点。
extension RecordSection {
    /// 折叠组 1（2 条修饰器）：页壳（宽度对齐 + 进页面拉一次数据）
    @MainActor
    private func applyRecordSectionBodyChrome<C: View>(to content: C) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .task {
                await store.loadFromServer()
                // 候选池⑨：进记录区就补记本月该自动入账的固定支出（打开 App 即补，不依赖后台调度）
                store.applyFixedExpenses()
            }
    }

    /// 折叠组 2（3 条修饰器）：三张弹窗（新建 / 全部记录 / 扫账单）
    @MainActor
    private func applyRecordSectionBodySheets<C: View>(to content: C) -> some View {
        content
            .sheet(isPresented: $showAdd) { addSheet }
            // 删除确认框必须挂在弹窗自己这棵树上（SR35：宿主级 alert 在弹窗之上呈现不出来）
            .sheet(isPresented: $showAll) { deleteConfirm(on: allSheet) }
            // v4.0.22 候选池⑪：扫账单（自身带 detents，内容不含实色底 —— 与全站弹窗口径一致）
            // ⚠️ `.id(billScanSession)` 是刚需：SwiftUI 会**保留已 present 过视图的状态**，
            // 不换实例的话「扫一次 → 关掉 → 再扫」会带着上一张图/上一次金额回来（与 Memo/Todo 同源坑）。
            .sheet(isPresented: $showBillScan) { BillScanSheet().id(billScanSession) }
    }

    @MainActor
    private struct RecordSectionBodyChrome: ViewModifier {
        let host: RecordSection

        func body(content: Content) -> some View { host.applyRecordSectionBodyChrome(to: content) }
    }

    @MainActor
    private struct RecordSectionBodySheets: ViewModifier {
        let host: RecordSection

        func body(content: Content) -> some View { host.applyRecordSectionBodySheets(to: content) }
    }
}
