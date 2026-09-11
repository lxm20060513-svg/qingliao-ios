import SwiftUI
import Foundation

// MARK: - 生活卡片设置页（v3.5.x）
//
// 看板「生活数据」的配置入口：股票卡片 / 资讯源 / 快递 / 价格监控 四组，全部落
// 后端 GET|POST /api/life/config（v2 schema，见 Core/LifeConfig.swift）。
//
// 约定：
//   · 每次改动立即整体保存；保存成功后用返回值刷新本地状态（presets 同步刷新）
//   · 失败显示红色小字，绝不静默吞掉
//   · 视觉沿用设置页定稿：SectionHeader 分组 + glassListCard 容器 + 0.8pt 描边 +
//     Capsule 胶囊按钮 + tertiary 次要文字（不引入新风格/新配色）
//   · 网络一律走 AuthStore（自动带 X-Auth-Token，蜂窝/中继分流由它负责）

struct LifeCardsSettingsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var config = LifeConfig()
    @State private var presets = LifePresets()
    @State private var loading = true
    @State private var saving = false
    @State private var pendingSave = false
    @State private var error = ""
    @State private var toast = ""

    // 股票搜索
    @State private var showStockSearch = false

    // 资讯源
    @State private var showRssCatalog = false
    @State private var newRssName = ""
    @State private var newRssURL = ""
    @State private var rssError = ""

    // 快递
    @State private var newPackageNo = ""
    @State private var newPackageCarrier = ""

    // 价格监控
    @State private var priceTesting: Set<String> = []
    @State private var priceResults: [String: String] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    noteRow
                    statusRow
                    stockSection
                    rssSection
                    expressSection
                    priceSection
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 60)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("生活卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving || loading { ProgressView().controlSize(.small) }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showStockSearch) {
            StockSearchSheet(presets: presets, existing: config.stocks) { pick in
                showStockSearch = false
                addStock(pick)
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: 顶部说明 / 状态

    private var noteRow: some View {
        Text("改动立即生效，看板下一轮刷新即生效")
            .font(.system(size: Typography.caption))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 10)
    }

    @ViewBuilder
    private var statusRow: some View {
        if !error.isEmpty {
            Text(error)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 6)
        } else if !toast.isEmpty {
            Text(toast)
                .font(.system(size: Typography.caption))
                .foregroundStyle(Color.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 6)
        }
    }

    // MARK: ① 股票卡片

    @ViewBuilder
    private var stockSection: some View {
        SectionHeader("股票卡片")
        VStack(spacing: 0) {
            if config.stocks.isEmpty {
                emptyRow("暂无股票卡片，点下方「添加股票」")
            } else {
                ForEach(config.stocks.indices, id: \.self) { i in
                    stockRow(i)
                    if i < config.stocks.count - 1 { rowDivider }
                }
            }
            footerButton("添加股票", icon: "plus.circle.fill") { showStockSearch = true }
        }
        .glassListCard()
    }

    private func stockRow(_ i: Int) -> some View {
        HStack(spacing: 10) {
            iconBadge("chart.line.uptrend.xyaxis", color: .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(presets.stockName(config.stocks[i]))
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(presets.marketName(config.stocks[i].market) + " · " + config.stocks[i].code)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            deleteCircle { removeStock(i) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) { removeStock(i) } label: {
                Label("删除这张卡片", systemImage: "trash")
            }
        }
    }

    // MARK: ② 资讯源

    @ViewBuilder
    private var rssSection: some View {
        SectionHeader("资讯源")
        VStack(spacing: 0) {
            if config.rss.isEmpty {
                emptyRow("暂无资讯源，可在下方添加")
            } else {
                ForEach(config.rss.indices, id: \.self) { i in
                    rssRow(i)
                    if i < config.rss.count - 1 { rowDivider }
                }
            }
            footerButton(showRssCatalog ? "收起源目录" : "添加资讯源",
                         icon: showRssCatalog ? "chevron.up.circle.fill" : "plus.circle.fill") {
                withAnimation(Motion.snap) { showRssCatalog.toggle() }
            }
            if showRssCatalog { rssAddArea }
        }
        .glassListCard()
    }

    private func rssRow(_ i: Int) -> some View {
        HStack(spacing: 10) {
            iconBadge("dot.radiowaves.left.and.right", color: .indigo)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.rss[i].name)
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(config.rss[i].domain)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            deleteCircle { removeRss(i) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) { removeRss(i) } label: {
                Label("删除这个源", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var rssAddArea: some View {
        if !presets.rss.isEmpty {
            subLabel("内置资讯源目录").padding(.horizontal, 14)
            ForEach(presets.rss.indices, id: \.self) { i in
                rssCatalogRow(presets.rss[i])
                if i < presets.rss.count - 1 { rowDivider }
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            subLabel("自定义资讯源")
            labeledField("名称", placeholder: "如 我的博客", text: $newRssName)
            labeledField("URL", placeholder: "https://example.com/feed", text: $newRssURL)
            if !rssError.isEmpty {
                Text(rssError)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            addCapsule("添加资讯源") { addCustomRss() }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private func rssCatalogRow(_ p: LifeRssPreset) -> some View {
        let added = config.rss.contains(where: { $0.url == p.url || $0.name == p.name })
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(p.name)
                        .font(.system(size: Typography.subhead, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if p.builtin {
                        Text("内置")
                            .font(.system(size: Typography.tiny))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(p.domain)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                addPresetRss(p)
            } label: {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: Typography.title))
                    .foregroundStyle(added ? Color.green : Color.accentColor)
            }
            .buttonStyle(PressStyle())
            .disabled(added)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    // MARK: ③ 快递

    @ViewBuilder
    private var expressSection: some View {
        SectionHeader("快递")
        VStack(spacing: 0) {
            if config.express.packages.isEmpty {
                emptyRow("暂无快递单号")
            } else {
                ForEach(config.express.packages.indices, id: \.self) { i in
                    packageRow(i)
                    if i < config.express.packages.count - 1 { rowDivider }
                }
            }
            addPackageArea
        }
        .glassListCard()

        SectionHeader("快递数据源")
        VStack(alignment: .leading, spacing: 10) {
            typePicker
            if config.express.source.isCustom { expressCustomFields }
            LifeHeaderEditor(title: "自定义请求头", headers: $config.express.source.headers)
                .padding(.horizontal, 14)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassListCard()
    }

    private func packageRow(_ i: Int) -> some View {
        HStack(spacing: 10) {
            iconBadge("shippingbox.fill", color: .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.express.packages[i].no)
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(presets.carrierName(config.express.packages[i].carrier))
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            carrierPicker($config.express.packages[i].carrier)
            deleteCircle { removePackage(i) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) { removePackage(i) } label: {
                Label("删除这个单号", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func carrierPicker(_ selection: Binding<String>) -> some View {
        if presets.carriers.isEmpty {
            EmptyView()
        } else {
            Picker("", selection: selection) {
                ForEach(presets.carriers) { c in
                    Text(c.name).tag(c.code)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(.system(size: Typography.caption))
        }
    }

    private var addPackageArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            subLabel("添加快递单号")
            smallField("快递单号", text: $newPackageNo)
            if !presets.carriers.isEmpty {
                HStack(spacing: 8) {
                    Text("快递公司")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.secondary)
                    carrierPicker($newPackageCarrier)
                    Spacer(minLength: 0)
                }
            }
            addCapsule("添加单号") { addPackage() }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private var typePicker: some View {
        HStack(spacing: 8) {
            Text("数据源")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            capsuleToggle("免费接口", on: !config.express.source.isCustom) {
                setExpressType("free")
            }
            capsuleToggle("自定义接口", on: config.express.source.isCustom) {
                setExpressType("custom")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private var expressCustomFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledField("URL 模板",
                         placeholder: "https://api.example.com/track?no={no}",
                         text: $config.express.source.urlTemplate)
            Text("支持占位符 {no} 单号 / {carrier} 快递公司编码 / {key} 密钥 / {phone} 手机号后四位")
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            labeledField("密钥 key", placeholder: "接口密钥（可选）", text: $config.express.source.key)
            labeledField("列表路径 list_path", placeholder: "data", text: $config.express.source.listPath)
            labeledField("时间字段 time_key", placeholder: "time", text: $config.express.source.timeKey)
            labeledField("上下文字段 context_key", placeholder: "context", text: $config.express.source.contextKey)
            labeledField("状态字段 state_path", placeholder: "state", text: $config.express.source.statePath)
        }
        .padding(.horizontal, 14)
    }

    // MARK: ④ 价格监控

    @ViewBuilder
    private var priceSection: some View {
        SectionHeader("价格监控")
        VStack(spacing: 0) {
            if config.price.items.isEmpty {
                emptyRow("暂无价格监控项")
            } else {
                ForEach(config.price.items.indices, id: \.self) { i in
                    priceItemCard(i)
                    if i < config.price.items.count - 1 { rowDivider }
                }
            }
            footerButton("添加价格监控", icon: "plus.circle.fill") { addPriceItem() }
        }
        .glassListCard()

        SectionHeader("价格数据源")
        VStack(alignment: .leading, spacing: 10) {
            priceTimeoutRow
            LifeHeaderEditor(title: "自定义请求头", headers: $config.price.source.headers)
                .padding(.horizontal, 14)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassListCard()
    }

    private var priceTimeoutRow: some View {
        HStack(spacing: 8) {
            Text("请求超时")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            Stepper("", value: $config.price.source.timeout, in: 3...20)
                .labelsHidden()
                .onChange(of: config.price.source.timeout) { _, _ in
                    Task { await persist() }
                }
            Text("\(config.price.source.timeout) 秒")
                .font(.system(size: Typography.subhead, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }

    private func priceItemCard(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                iconBadge("tag.fill", color: .pink)
                Text(config.price.items[i].name.isEmpty ? "未命名价格项" : config.price.items[i].name)
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                testButton(i)
                deleteCircle { removePriceItem(i) }
            }
            labeledField("名称", placeholder: "商品名称", text: $config.price.items[i].name)
            labeledField("商品 URL", placeholder: "https://…", text: $config.price.items[i].url)
            extractPicker(i)
            priceExtractField(i)
            HStack(spacing: 10) {
                groupStepper(i)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 10) {
                labeledField("币种", placeholder: "CNY", text: $config.price.items[i].currency)
                targetField(i)
            }
            if let r = priceResults[config.price.items[i].uid] {
                Text(r)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(r.hasPrefix("✅") ? Color.green : Color.red)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func priceExtractField(_ i: Int) -> some View {
        if config.price.items[i].extract == "json" {
            labeledField("JSON 路径", placeholder: "如 data.price", text: $config.price.items[i].path)
        } else {
            labeledField("正则 pattern", placeholder: "如 \"price\": ([0-9.]+)", text: $config.price.items[i].pattern)
        }
    }

    private func extractPicker(_ i: Int) -> some View {
        HStack(spacing: 8) {
            Text("提取方式")
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            capsuleToggle("正则 regex", on: config.price.items[i].extract == "regex") {
                setExtract(i, "regex")
            }
            capsuleToggle("JSON 路径", on: config.price.items[i].extract == "json") {
                setExtract(i, "json")
            }
            Spacer(minLength: 0)
        }
    }

    private func groupStepper(_ i: Int) -> some View {
        HStack(spacing: 8) {
            Text("正则分组")
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            Stepper("", value: $config.price.items[i].group, in: 0...30)
                .labelsHidden()
                .onChange(of: config.price.items[i].group) { _, _ in
                    Task { await persist() }
                }
            Text("第 \(config.price.items[i].group) 组")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
    }

    private func targetField(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("目标价（可选）")
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("留空不提醒", text: targetBinding(i))
                .font(.system(size: Typography.subhead))
                .keyboardType(.decimalPad)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func targetBinding(_ i: Int) -> Binding<String> {
        Binding(get: {
            config.price.items.indices.contains(i) ? config.price.items[i].targetText : ""
        }, set: { v in
            guard config.price.items.indices.contains(i) else { return }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            config.price.items[i].target = t.isEmpty ? nil : Double(t)
        })
    }

    private func testButton(_ i: Int) -> some View {
        Button {
            testPrice(i)
        } label: {
            HStack(spacing: 4) {
                if priceTesting.contains(config.price.items[i].uid) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "bolt.fill").font(.system(size: Typography.tiny, weight: .semibold))
                }
                Text("试抓").font(.system(size: Typography.caption, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(PressStyle())
    }

    // MARK: 通用小组件

    private var rowDivider: some View {
        Divider().padding(.leading, 14)
    }

    private func iconBadge(_ icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: Typography.subhead, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Typography.subhead))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }

    private func subLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Typography.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func smallField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: Typography.subhead))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func labeledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            smallField(placeholder, text: text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deleteCircle(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(Color.red)
                .frame(width: 26, height: 26)
                .background(Color.red.opacity(0.12), in: Circle())
        }
        .buttonStyle(PressStyle())
    }

    private func addCapsule(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // v3.9.4：添加类胶囊只留文字（去图标）
            Text(title).font(.system(size: Typography.subhead, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.accentColor, in: Capsule())
        }
        .buttonStyle(PressStyle())
    }

    // v3.9.4：按用户要求「添加」类按钮一律只留文字 + 胶囊（去图标）；icon 参数保留仅为调用点兼容，不再绘制
    private func footerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: Typography.subhead, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(PressStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func capsuleToggle(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(on ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(PressStyle())
    }

    // MARK: 数据加载 / 保存

    private func load() async {
        loading = true
        if let j = await auth.jsonOrLog("/api/life/config") {
            if (j["ok"] as? Bool) == false {
                error = (j["error"] as? String) ?? "读取配置失败"
            } else {
                if let c = j["config"] as? [String: Any] { config = LifeConfig.parse(c) }
                if let p = j["presets"] as? [String: Any] { presets = LifePresets.parse(p) }
                if newPackageCarrier.isEmpty, let first = presets.carriers.first {
                    newPackageCarrier = first.code
                }
                error = ""
            }
        } else {
            error = "读取配置失败：网络或后端不可用"
        }
        loading = false
    }

    /// 每次改动立即整体保存；排队中的改动不会被返回值回灌覆盖。
    private func persist() async {
        if saving {
            pendingSave = true
            return
        }
        saving = true
        let j = await auth.jsonOrLog("/api/life/config", method: "POST", body: ["config": config.json])
        saving = false
        if let j {
            if (j["ok"] as? Bool) == false {
                error = (j["error"] as? String) ?? "保存失败"
            } else {
                error = ""
                if let p = j["presets"] as? [String: Any] { presets = LifePresets.parse(p) }
                if !pendingSave, let c = j["config"] as? [String: Any] {
                    config = LifeConfig.parse(c)
                }
                flashToast()
            }
        } else {
            error = "保存失败：网络或后端不可用"
        }
        if pendingSave {
            pendingSave = false
            await persist()
        }
    }

    private func flashToast() {
        toast = "已保存"
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if toast == "已保存" { toast = "" }
        }
    }

    // MARK: 变更动作（全部落到 persist）

    private func removeStock(_ i: Int) {
        guard config.stocks.indices.contains(i) else { return }
        config.stocks.remove(at: i)
        Task { await persist() }
    }

    private func addStock(_ p: LifeStockPreset) {
        let ref = LifeStockRef(market: p.market.isEmpty ? "1" : p.market, code: p.code)
        guard !config.stocks.contains(where: { $0.code == ref.code && $0.market == ref.market }) else { return }
        config.stocks.append(ref)
        Task { await persist() }
    }

    private func removeRss(_ i: Int) {
        guard config.rss.indices.contains(i) else { return }
        config.rss.remove(at: i)
        Task { await persist() }
    }

    private func addPresetRss(_ p: LifeRssPreset) {
        guard !config.rss.contains(where: { $0.url == p.url || $0.name == p.name }) else { return }
        config.rss.append(LifeRssSourceRef(name: p.name, url: p.url))
        Task { await persist() }
    }

    private func addCustomRss() {
        let name = newRssName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = newRssURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LifeRssSourceRef.isHTTPURL(url) else {
            rssError = "URL 必须以 http:// 或 https:// 开头"
            return
        }
        guard !name.isEmpty else {
            rssError = "请填写资讯源名称"
            return
        }
        guard !config.rss.contains(where: { $0.url == url }) else {
            rssError = "该地址已添加"
            return
        }
        rssError = ""
        config.rss.append(LifeRssSourceRef(name: name, url: url))
        newRssName = ""
        newRssURL = ""
        Task { await persist() }
    }

    private func addPackage() {
        let no = newPackageNo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !no.isEmpty else { return }
        let code = newPackageCarrier.isEmpty ? (presets.carriers.first?.code ?? "") : newPackageCarrier
        config.express.packages.append(LifeExpressPackage(no: no,
                                                          carrier: code,
                                                          name: presets.carrierName(code)))
        newPackageNo = ""
        Task { await persist() }
    }

    private func removePackage(_ i: Int) {
        guard config.express.packages.indices.contains(i) else { return }
        config.express.packages.remove(at: i)
        Task { await persist() }
    }

    private func setExpressType(_ type: String) {
        guard config.express.source.type != type else { return }
        config.express.source.type = type
        Task { await persist() }
    }

    private func addPriceItem() {
        var item = LifePriceItem()
        item.currency = "CNY"
        config.price.items.append(item)
        Task { await persist() }
    }

    private func removePriceItem(_ i: Int) {
        guard config.price.items.indices.contains(i) else { return }
        let uid = config.price.items[i].uid
        config.price.items.remove(at: i)
        priceResults[uid] = nil
        Task { await persist() }
    }

    private func setExtract(_ i: Int, _ mode: String) {
        guard config.price.items.indices.contains(i), config.price.items[i].extract != mode else { return }
        config.price.items[i].extract = mode
        Task { await persist() }
    }

    private func testPrice(_ i: Int) {
        guard config.price.items.indices.contains(i) else { return }
        let item = config.price.items[i]
        guard !item.url.isEmpty else {
            priceResults[item.uid] = "❌ 请先填写商品 URL"
            return
        }
        priceTesting.insert(item.uid)
        Task {
            let body: [String: Any] = ["url": item.url,
                                       "extract": item.extract,
                                       "pattern": item.pattern,
                                       "path": item.path,
                                       "group": item.group]
            let j = await auth.jsonOrLog("/api/life/price/test", method: "POST", body: body)
            priceTesting.remove(item.uid)
            if let j {
                if (j["ok"] as? Bool) == true {
                    priceResults[item.uid] = "✅ 取到价格 " + priceText(j["price"])
                } else {
                    priceResults[item.uid] = "❌ " + ((j["error"] as? String) ?? "抓取失败")
                }
            } else {
                priceResults[item.uid] = "❌ 请求失败（网络或后端不可用）"
            }
        }
    }

    private func priceText(_ v: Any?) -> String {
        if let d = v as? Double { return String(format: "%g", d) }
        if let i = v as? Int { return String(i) }
        if let n = v as? NSNumber { return n.stringValue }
        if let s = v as? String { return s }
        return "—"
    }
}

// MARK: - 股票搜索（防抖 300ms，空查询不请求）

struct StockSearchSheet: View {
    let presets: LifePresets
    let existing: [LifeStockRef]
    let onPick: (LifeStockPreset) -> Void

    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [LifeStockPreset] = []
    @State private var searching = false
    @State private var error = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                if !error.isEmpty {
                    Text(error)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                }
                if searching {
                    ProgressView().controlSize(.small).padding(.top, 12)
                }
                ScrollView { resultsArea }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("添加股票")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .onChange(of: query) { _, q in scheduleSearch(q) }
    }

    private var searchField: some View {
        TextField("输入代码或名称，如 601138 / 工业富联", text: $query)
            .font(.system(size: Typography.subhead))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 10)
    }

    @ViewBuilder
    private var resultsArea: some View {
        if results.isEmpty {
            Text(query.isEmpty ? "输入关键词搜索股票" : "没有匹配结果")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
        } else {
            VStack(spacing: 0) {
                ForEach(results.indices, id: \.self) { i in
                    resultRow(results[i])
                    if i < results.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .glassListCard()
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private func resultRow(_ item: LifeStockPreset) -> some View {
        let added = existing.contains(where: { $0.code == item.code })
        return Button {
            guard !added else { return }
            onPick(item)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name.isEmpty ? item.code : item.name)
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(presets.marketName(item.market) + " · " + item.code)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: Typography.title))
                    .foregroundStyle(added ? Color.green : Color.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(added)
    }

    private func scheduleSearch(_ raw: String) {
        searchTask?.cancel()
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            results = []
            searching = false
            error = ""
            return
        }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            await performSearch(q)
        }
    }

    private func performSearch(_ q: String) async {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        if let j = await auth.jsonOrLog("/api/life/stock/search?q=" + enc) {
            results = (j["items"] as? [[String: Any]] ?? []).compactMap { LifeStockPreset.parse($0) }
            error = ""
        } else {
            results = []
            error = "搜索失败，请检查网络"
        }
        searching = false
    }
}

// MARK: - 请求头键值对编辑器（快递 / 价格数据源共用）

struct LifeHeaderEditor: View {
    let title: String
    @Binding var headers: [LifeHeaderPair]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    headers.append(LifeHeaderPair())
                } label: {
                    // v3.9.4：只留文字 + 胶囊（去图标）
                    Text("添加")
                        .font(.system(size: Typography.caption, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(PressStyle())
            }
            if headers.isEmpty {
                Text("无自定义请求头")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
            ForEach(headers.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    headerField("键", text: $headers[i].key)
                    headerField("值", text: $headers[i].value)
                    Button {
                        headers.remove(at: i)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: Typography.body))
                            .foregroundStyle(Color.red.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func headerField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: Typography.subhead))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
