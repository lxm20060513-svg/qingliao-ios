// 本文件由 2026-09-27 工程治理「Settings 物理合并」生成：多份同域设置页文件合并为一，
// UI 入口与行为零改动，仅文件边界变化。合并前各文件的来源见下方 MARK 分段。

import Combine
import Foundation
import LocalAuthentication
import PDFKit
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: ===== 以下原为 Features/Settings/LifeCardsSettingsView.swift =====

// MARK: - 生活卡片设置页（v3.5.x）
//
// 看板「生活数据」的配置入口：股票卡片 / 资讯源 / 快递 三组，全部落
// 后端 GET|POST /api/life/config（v2 schema，见 Core/LifeConfig.swift）。
//
// 约定：
//   · 每次改动立即整体保存；保存成功后用返回值刷新本地状态（presets 同步刷新）
//   · 失败显示红色小字，绝不静默吞掉
//   · 视觉沿用设置页定稿：SectionHeader 分组 + pastelCard 渐变卡容器 + 0.8pt 描边 +
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


    // SR15：文本类输入的防抖保存任务（每敲一个字就 POST 会把编辑过程整段推给后端）
    @State private var persistTask: Task<Void, Never>?
    /// 配置是否成功读回。未读回时 config 还是默认值，此时任何 persist 都会把
    /// 一整份默认值 POST 上去、静默覆盖用户真实设置（v3.9.87 审查）。
    @State private var loadedOK = false

    /// SR15：包一层「写入即安排保存」。本页顶部约定写着「每次改动立即整体保存」，
    /// 但只有胶囊/Stepper/增删按钮那几条路径真的调了 persist()；
    /// 所有 `labeledField` 文本框（快递 URL 模板/密钥/字段名…）
    /// 与自定义请求头改完都不落库，而「完成」只 dismiss → 用户白填一张表，重开页面全是空。
    private func persisting<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding<T>(get: { binding.wrappedValue },
                  set: { v in
                      binding.wrappedValue = v
                      schedulePersist()
                  })
    }

    /// 后端把检测间隔钳在 60…86400，而 Picker 只能显示列出的档位。
    /// 配置里出现非档位值时，Picker 会渲染成空白且用户看不出当前值
    /// → 读侧夹到最近档位，并在 load 后一次性归一化（否则界面显示与真实值长期不一致）。
    /// 档位单一真源 = `expressIntervals`，改档位只改这一处。
    static let expressIntervals: [(label: String, seconds: Int)] = [
        ("15 分钟", 900), ("30 分钟", 1800), ("1 小时", 3600),
        ("2 小时", 7200), ("6 小时", 21600), ("24 小时", 86400),
    ]

    /// load() 成功后把非档位值归一化（静默，不 POST——下次用户改动才写回）
    func normalizeInterval() {
        let allowed = Self.expressIntervals.map(\.seconds)
        let v = config.notify.expressWatchEvery
        guard !allowed.contains(v) else { return }
        config.notify.expressWatchEvery =
            allowed.min(by: { abs($0 - v) < abs($1 - v) }) ?? 3600
    }

    private var clampedInterval: Binding<Int> {
        let allowed = Self.expressIntervals.map(\.seconds)
        let base = Binding<Int>(
            get: { config.notify.expressWatchEvery },
            set: { config.notify.expressWatchEvery = $0 })
        return Binding<Int>(
            get: {
                let v = base.wrappedValue
                return allowed.contains(v) ? v : (allowed.min(by: { abs($0 - v) < abs($1 - v) }) ?? 3600)
            },
            set: { persisting(base).wrappedValue = $0 })
    }

    /// 防抖 0.6s 后整体保存（连续输入只发一次）
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await persist()
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    noteRow
                    statusRow
                    stockSection
                    rssSection
                    expressSection
                    notifySection
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, 60)
            }
            .navigationTitle("生活卡片")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }   // 读失败时提示「下拉重试」——得真能下拉
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // SR15：先冲掉防抖窗口里的最后一笔改动再关页（原来只 dismiss，
                    // 关闭前 0.6s 内敲进去的内容会随任务一起消失）
                    Button("完成") {
                        persistTask?.cancel()
                        Task {
                            await persist()
                            dismiss()
                        }
                    }
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
            .padding(.horizontal, Spacing.xs)
            .padding(.top, Spacing.lg)
    }

    @ViewBuilder
    private var statusRow: some View {
        if !error.isEmpty {
            Text(error)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.xs)
                .padding(.top, Spacing.sm)
        } else if !toast.isEmpty {
            Text(toast)
                .font(.system(size: Typography.caption))
                .foregroundStyle(Color.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.xs)
                .padding(.top, Spacing.sm)
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
        .pastelCard()
    }

    private func stockRow(_ i: Int) -> some View {
        HStack(spacing: 10) {
            iconBadge("chart.line.uptrend.xyaxis", color: .green)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
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
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.md)
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
        .pastelCard()
    }

    private func rssRow(_ i: Int) -> some View {
        HStack(spacing: 10) {
            iconBadge("dot.radiowaves.left.and.right", color: .indigo)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
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
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.md)
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
            subLabel("内置资讯源目录").padding(.horizontal, Spacing.xxl)
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
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xxs)
        .padding(.bottom, Spacing.xl)
    }

    private func rssCatalogRow(_ p: LifeRssPreset) -> some View {
        let added = config.rss.contains(where: { $0.url == p.url || $0.name == p.name })
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Text(p.name)
                        .font(.system(size: Typography.subhead, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if p.builtin {
                        Text("内置")
                            .font(.system(size: Typography.tiny))
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xxs)
                            .background(Color.accentColor.opacity(Tint.subtle), in: Capsule())
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
                    .symbolEffect(.bounce, value: added)   // v4.0.61：状态切换弹一下（原生符号动效）
            }
            .buttonStyle(PressStyle())
            .disabled(added)
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.md)
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
        .pastelCard()

        SectionHeader("快递数据源")
        VStack(alignment: .leading, spacing: 10) {
            typePicker
            if config.express.source.isCustom { expressCustomFields }
            LifeHeaderEditor(title: "自定义请求头", headers: persisting($config.express.source.headers))
                .padding(.horizontal, Spacing.xxl)
        }
        .padding(.vertical, Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard()
    }

    private func packageRow(_ i: Int) -> some View {
        HStack(spacing: 10) {
            iconBadge("shippingbox.fill", color: .orange)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
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
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.md)
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
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xxs)
        .padding(.bottom, Spacing.xl)
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
        .padding(.horizontal, Spacing.xxl)
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
        .padding(.horizontal, Spacing.xxl)
    }

    // MARK: ⑤ 提醒推送（快递状态变化 / 生活周报）

    private static let notifyWeekDays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    @ViewBuilder
    private var notifySection: some View {
        SectionHeader("提醒推送")
        VStack(spacing: 0) {
            notifyToggle(icon: "shippingbox.fill", color: .orange,
                         title: "快递状态变化提醒",
                         subtitle: "轨迹有更新才推一条，不重复打扰",
                         isOn: persisting($config.notify.expressWatch))
            if config.notify.expressWatch {
                rowDivider
                notifyPickerRow(title: "检测间隔") {
                    Picker("", selection: persisting(clampedInterval)) {
                        ForEach(Self.expressIntervals, id: \.seconds) { item in
                            Text(item.label).tag(item.seconds)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            rowDivider
            notifyToggle(icon: "doc.text.image.fill", color: .blue,
                         title: "生活周报",
                         subtitle: "天气 / 快递 / 股票 / 待办 / 花费汇总成一条",
                         isOn: persisting($config.notify.weeklyReport))
            if config.notify.weeklyReport {
                rowDivider
                notifyPickerRow(title: "推送时间") {
                    HStack(spacing: Spacing.sm) {
                        Picker("", selection: persisting($config.notify.weeklyReportDay)) {
                            ForEach(0..<7, id: \.self) { i in
                                Text(Self.notifyWeekDays[i]).tag(i)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Picker("", selection: persisting($config.notify.weeklyReportHour)) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d:00", h)).tag(h)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            }
        }
        .pastelCard()

        Text("周报与快递提醒由后端定时任务推送，App 关着也能收到；关掉开关即停止推送。")
            .font(.system(size: Typography.caption))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.xs)
            .padding(.top, Spacing.sm)
    }

    private func notifyToggle(icon: String, color: Color, title: String,
                              subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            iconBadge(icon, color: color)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.system(size: Typography.body, weight: .medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.md)
            Toggle("", isOn: isOn).qingliaoSwitch()
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
    }

    private func notifyPickerRow<Content: View>(title: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: Typography.body))
                .foregroundStyle(.primary)
            Spacer(minLength: Spacing.md)
            content()
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.md)
    }

    // MARK: 通用小组件

    private var rowDivider: some View {
        Divider().padding(.leading, Spacing.xxl)
    }

    private func iconBadge(_ icon: String, color: Color) -> some View {
        // v3.9.28：26→28 与全站列表行图标底统一（SettingRow/toggleRow 均为 28）
        Image(systemName: icon)
            .font(.system(size: Typography.subhead, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Typography.subhead))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.xl)
    }

    private func subLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Typography.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xs)
    }

    private func smallField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: Typography.subhead))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
    }

    private func labeledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            smallField(placeholder, text: persisting(text))   // SR15：文本改动也要落库
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deleteCircle(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(Color.red)
                .frame(width: 26, height: 26)
                .background(Color.red.opacity(Tint.subtle), in: Circle())
        }
        .buttonStyle(PressStyle())
    }

    private func addCapsule(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // v3.9.4：添加类胶囊只留文字（去图标）
            // v3.9.35：实色底并入全站胶囊口径 topBar（淡底+同色细描边，用户拍板方案 A）
            Text(title)
            .pill(.topBar)
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
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.sm)
            .glassPillStroke()
        }
        .buttonStyle(PressStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
    }

    private func capsuleToggle(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.primary)
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.sm)
                .background(on ? Color.accentColor : Color.primary.opacity(Tint.faint), in: Capsule())
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
                loadedOK = j["config"] is [String: Any]
                if loadedOK { normalizeInterval() }
                error = loadedOK ? "" : "读取配置失败：后端未返回配置"
            }
        } else {
            error = "读取配置失败：网络或后端不可用"
        }
        loading = false
    }

    /// 每次改动立即整体保存；排队中的改动不会被返回值回灌覆盖。
    private func persist() async {
        // 未成功读回配置时，config 还是默认值：POST 上去等于用默认值覆盖用户真实设置
        guard loadedOK else {
            error = "配置尚未成功读取，改动未保存（请下拉重试后再改）"
            return
        }
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
                        .padding(.horizontal, Spacing.sheetInset)
                        .padding(.top, Spacing.sm)
                }
                if searching {
                    ProgressView().controlSize(.small).padding(.top, Spacing.xl)
                }
                ScrollView { resultsArea }
            }
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
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.lg)
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
                        Divider().padding(.leading, Spacing.xxl)
                    }
                }
            }
            .pastelCard()
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.xl)
        }
    }

    private func resultRow(_ item: LifeStockPreset) -> some View {
        let added = existing.contains(where: { $0.code == item.code })
        return Button {
            guard !added else { return }
            onPick(item)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
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
                    .symbolEffect(.bounce, value: added)   // v4.0.61：状态切换弹一下（原生符号动效）
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.lg)
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

// MARK: - 请求头键值对编辑器（快递数据源用）

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
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.xs)
                        .glassPillStroke()
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
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
    }
}

// MARK: ===== 以下原为 Features/Settings/QuickReminderSheet.swift =====

// MARK: - v3.9.32 一句话本地定时提醒（列表 / 新建 / 解析确认）
//
// 入口有两个：
//   · 设置 →「定时提醒」；
//   · 聊天消息长按 →「提醒我」（`presetText` 带该条消息内容，截断后作为默认提醒内容）。
//
// 为什么要有「确认解析结果」这一步：解析器是规则式的（不做 LLM 兜底），**必须**让用户看见
// 「到底定到了几点」再点创建——否则一句话理解偏了，用户要等到「该响的时候没响」才发现。
// 所以这里把 summary 用胶囊显式摆出来，解析失败也把可读原因原样显示（不静默）。
//
// 视觉沿用全站口径：SectionHeader + pastelCard 渐变卡分组（与设置页同款）、间距/圆角/字号走
// Spacing / Radius / Typography 令牌、胶囊走 Pill();本文件不引入新的魔法数。

struct QuickReminderSheet: View {
    /// 默认提醒内容（聊天「提醒我」入口传入该条消息；会自动截断，用户可改）
    var presetText: String = ""

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var phrase = ""
    @FocusState private var phraseFocused: Bool
    /// 创建成功反馈（会自动消失，避免一直挂着）
    @State private var createdText: String?
    @State private var createError: String?

    private var store: QuickReminderStore { .shared }

    /// 时间那句话的解析结果（空输入不解析）
    private var parsed: QuickReminderParseResult? {
        let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        return QuickReminderParser.parseDetailed(p)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    SectionHeader("新建提醒")
                    composeCard
                    if store.auth == .denied { authBanner }
                    SectionHeader("待触发")
                    pendingCard
                    if !store.finished.isEmpty {
                        SectionHeader("已提醒")
                        finishedCard
                    }
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, Spacing.section)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)   // 不盖系统玻璃弹窗底（见 LiquidGlass.swift v3.9.23 决策）
            .navigationTitle("定时提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                await store.refreshAuth()
                await store.reconcile()
            }
            .onAppear {
                if text.isEmpty { text = QuickReminderParser.seedText(from: presetText) }
                if !presetText.isEmpty { phraseFocused = true }
            }
            .onChange(of: phrase) { _, _ in
                createdText = nil
                createError = nil
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 新建

    private var composeCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            TextField("提醒内容（可留空）", text: $text, axis: .vertical)
                .font(.system(size: Typography.body))
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
            Divider()
            HStack(spacing: Spacing.md) {
                Image(systemName: "clock")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.secondary)
                TextField("什么时候（如：明天早上 7 点半）", text: $phrase)
                    .font(.system(size: Typography.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($phraseFocused)
                    .submitLabel(.done)
            }
            parseFeedback
            createRow
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.xxl)
        .pastelCard()
    }

    /// 解析结果 / 失败原因（用户确认「定到了几点」的那一行）
    @ViewBuilder
    private var parseFeedback: some View {
        if let result = parsed {
            switch result {
            case .success(let p):
                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                    Text(p.summary).pill(.page, tone: .accent)
                    Text(p.rule.repeats ? "\(p.rule.label) · 由系统准点弹出" : "仅响一次 · 由系统准点弹出")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            case .failure(let message):
                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        } else {
            Text("写一句话就行：「5 分钟后」「明天早上 7 点半」「后天下午 3 点」「每天 7:30」「下周一 9 点」")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
    }

    private var createRow: some View {
        HStack(spacing: Spacing.lg) {
            Button {
                Task { await create() }
            } label: {
                Text("创建提醒").pill(.primary, tone: .accent)
            }
            .buttonStyle(.plain)
            .disabled(parsed?.value == nil)
            .opacity(parsed?.value == nil ? 0.45 : 1)

            if let createdText {
                Label(createdText, systemImage: "checkmark.circle.fill")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else if let createError {
                Text(createError)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    /// 权限被拒横幅（App 内已无法再弹系统授权框，只能引导去设置）
    private var authBanner: some View {
        HStack(spacing: Spacing.xl) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: Typography.title))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("通知权限没开")
                    .font(.system(size: Typography.body, weight: .medium))
                Text("没权限就不会响——去系统设置 →「通知 → 轻聊」打开")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.sm)
            Button {
                QuickReminderStore.openSystemNotificationSettings()
            } label: {
                Text("去设置").pill(.page, tone: .accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.xxl)
        .pastelCard()
        .padding(.top, Spacing.xxl)
    }

    // MARK: - 列表

    @ViewBuilder
    private var pendingCard: some View {
        if store.scheduled.isEmpty {
            emptyHint
        } else {
            VStack(spacing: 0) {
                ForEach(Array(store.scheduled.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, Spacing.rowDividerInset) }
                    reminderRow(item)
                }
                Divider()
                Text(footerText)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.vertical, Spacing.lg)
            }
            .pastelCard()
        }
    }

    private var footerText: String {
        store.pendingCount > 0
            ? "系统已登记 \(store.pendingCount) 条提醒——App 关掉 / 手机重启也会准点响"
            : "提醒交给系统登记，App 关掉也会准点响"
    }

    @ViewBuilder
    private var finishedCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.finished.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, Spacing.rowDividerInset) }
                reminderRow(item, finished: true)
            }
            Divider()
            Button {
                Task { await store.clearFinished() }
            } label: {
                Text("清空已提醒记录").pill(.page, tone: .neutral)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.lg)
        }
        .pastelCard()
    }

    private var emptyHint: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "bell.badge")
                .font(.system(size: Typography.titleXL))
                .foregroundStyle(Color.accentColor.opacity(0.7))
            Text("还没有提醒")
                .font(.system(size: Typography.title, weight: .semibold))
            Text("在上面写一句时间，或长按聊天里的消息选「提醒我」")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.section)
        .padding(.horizontal, Spacing.xxl)
        .pastelCard()
    }

    /// 单条提醒行（长按菜单 / 右侧按钮都能删）
    private func reminderRow(_ item: QuickReminder, finished: Bool = false) -> some View {
        HStack(spacing: Spacing.xl) {
            Image(systemName: item.rule.repeats ? "arrow.clockwise" : (finished ? "bell.slash" : "bell.fill"))
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(finished ? Color.gray : (item.rule.repeats ? Color.indigo : Color.orange),
                            in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(item.text)
                    .font(.system(size: Typography.body, weight: .medium))
                    .foregroundStyle(finished ? .secondary : .primary)
                    .lineLimit(2)
                Text(finished ? "已提醒 · \(item.timeText)" : item.timeText)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: Spacing.sm)
            Button {
                Task { await delete(item) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除提醒 \(item.text)")
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .contextMenu {
            Button(role: .destructive) {
                Task { await delete(item) }
            } label: {
                Label("删除提醒", systemImage: "trash")
            }
        }
    }

    // MARK: - 动作

    private func create() async {
        guard case .success(let p) = parsed else { return }
        let ok = await store.add(text: text, parse: p)
        if ok {
            Haptics.success()
            createdText = "已排上：\(p.summary)"
            createError = nil
            text = ""
            phrase = ""
        } else {
            Haptics.error()
            // v3.9.41（SR30）：登记失败的真实原因（如系统 64 条 pending 已满）原先只 NSLog
            createError = store.lastScheduleError
                ?? "没能排上——通知权限没开，去系统设置打开后再试"
        }
    }

    private func delete(_ item: QuickReminder) async {
        Haptics.tap()
        await store.delete(item)
    }
}

// MARK: ===== 以下原为 Features/Settings/CardGallerySheet.swift =====

// MARK: - v3.9.26 能力示例（卡片画廊）
//
// 背景：AI 回复里支持 ```ql-card 围栏协议（见 Core/AgentCardParser.swift + docs/agent-card-protocol.md），
// 有 5 种形态（result / metrics / list / table / status）。但用户在聊天里只能「碰运气」遇到，
// 没有任何地方能看到「AI 能出什么样的卡」。
//
// 本页把 5 种形态各用样例数据渲染一张，入口在 设置 → AI 智能 → 能力示例。
// **零后端**：AgentCard 是普通 struct（memberwise init），样例数据在 App 内直接构造，
// 不走 Hermes、不改后端 schema；渲染**直接复用聊天里的 AgentResultCard**——
// 所见即聊天里所得，不做「演示专用样式」（否则展示与真实渲染会漂移）。
//
// ⚠️ 维护提醒：AgentCard 加新字段/新形态时，本页要同步补一个样例（否则画廊与真实能力脱节）。

struct CardGallerySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    protocolGuide
                    ForEach(Self.samples) { sample in
                        VStack(alignment: .leading, spacing: 6) {
                            caption(sample)
                            // 与聊天里同一渲染路径（不是演示样式）
                            AgentResultCard(card: sample.card)
                        }
                    }
                    // v3.9.27：协议速览（卡片怎么触发的，一眼明白）
                    footerNote
                }
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.vertical, Spacing.section)
            }
            .scrollContentBackground(.hidden)   // v3.9.27：同款规则——列表自带底别盖系统玻璃
            .navigationTitle("能力示例")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: 协议速览（v3.9.27：结果类回复自动出卡 + 示例可复制）

    @State private var exampleCopied = false

    /// 卡片 JSON 示例（与后端 system prompt 注入的示例同款，可直接复制到聊天里试渲染）
    private static let exampleJSON =
        """
        ```ql-card
        {"type":"result","title":"NAS 体检","status":{"text":"全部正常","tone":"ok"},
         "fields":[{"key":"存储池","value":"健康","tone":"ok"},
                   {"key":"内存","value":"62%","tone":"info"}],
         "metrics":[{"label":"CPU","value":"12","unit":"%"}],
         "footer":"检查时间 今天 09:20"}
        ```
        """

    @ViewBuilder
    private var protocolGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("卡片是怎么出现的？")
                .font(.system(size: Typography.subhead, weight: .semibold))
            Text("AI 回复检查、诊断、清单、对比这类结果时，会自动把关键信息整理成卡片附在文字后面——不用你开口要。闲聊和普通问答不会出卡片。")
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                UIPasteboard.general.string = Self.exampleJSON
                exampleCopied = true
                Haptics.selection()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    exampleCopied = false
                }
            } label: {
                Label(exampleCopied ? "已复制，去聊天里粘贴发送试试" : "复制示例，去聊天里试试",
                      systemImage: exampleCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: Typography.caption, weight: .medium))
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .glassPillStroke()
            }
            .buttonStyle(PressStyle())
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(Tint.faint), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    @ViewBuilder
    private var footerNote: some View {
        Text("卡片完全离线解析，失败时自动退回普通文字显示，不会丢内容。")
            .font(.system(size: Typography.tiny))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 顶部说明（三段式：图标 + 标题 + 一句人话）

    @ViewBuilder
    private var intro: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: Typography.caption, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(Tint.subtle), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 会把结构化结果整理成卡片")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                Text("下面 5 种是当前支持的形态，聊天里自动出现，不需要你去要。")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 每张卡上方的说明行（参考图的三段式：图标 + 粗体名 + 一句灰字）

    @ViewBuilder
    private func caption(_ s: Sample) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: s.icon)
                .font(.system(size: Typography.tiny, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name)
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(s.desc)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 样例

    struct Sample: Identifiable, Sendable {
        let id: String
        let icon: String
        let name: String
        let desc: String
        let card: AgentCard
    }

    static let samples: [Sample] = [
        Sample(
            id: "result", icon: "checkmark.seal.fill",
            name: "结论卡",
            desc: "跑完检查后给一句结论 + 关键项，不用读完整段日志",
            card: AgentCard(
                kind: .result, title: "NAS 体检", subtitle: "3 项检查完成",
                status: AgentCard.Status(text: "全部正常", tone: .ok),
                fields: [
                    .init(key: "存储池", value: "健康", tone: .ok),
                    .init(key: "内存占用", value: "62%", tone: .info),
                    .init(key: "容器", value: "6 个运行中", tone: .ok),
                ],
                metrics: [], items: [], table: nil,
                footer: "检查时间 今天 09:20"
            )
        ),
        Sample(
            id: "metrics", icon: "chart.bar.fill",
            name: "指标卡",
            desc: "数值类结果用大号数字排开，变化时数字会滚动",
            card: AgentCard(
                kind: .metrics, title: "实时占用", subtitle: "每 10 秒刷新",
                status: nil,
                fields: [],
                metrics: [
                    .init(label: "CPU", value: "12", unit: "%", tone: .ok),
                    .init(label: "内存", value: "3.8", unit: "GB", tone: .warn),
                    .init(label: "温度", value: "46", unit: "°C", tone: .info),
                ],
                items: [], table: nil, footer: nil
            )
        ),
        Sample(
            id: "list", icon: "checklist",
            name: "清单卡",
            desc: "多条待办/多步任务，逐条带状态色",
            card: AgentCard(
                kind: .list, title: "今天要做的事", subtitle: "3 条",
                status: nil, fields: [], metrics: [],
                items: [
                    .init(title: "把照片备份到 NAS", subtitle: "还剩 12 GB 没传", status: "进行中", tone: .warn),
                    .init(title: "检查路由器固件", subtitle: nil, status: "已完成", tone: .ok),
                    .init(title: "给绿萝浇水", subtitle: nil, status: "未开始", tone: .info),
                ],
                table: nil, footer: "睡前提醒一次"
            )
        ),
        Sample(
            id: "table", icon: "tablecells.fill",
            name: "表格卡",
            desc: "多列对比（各模型用量、各设备状态）不走样",
            card: AgentCard(
                kind: .table, title: "本周模型用量", subtitle: "按调用次数排序",
                status: nil, fields: [], metrics: [], items: [],
                table: AgentCard.Table(
                    columns: ["模型", "调用", "花费"],
                    rows: [
                        ["deepseek-flash", "128", "¥0.42"],
                        ["glm-5.2", "31", "¥0.18"],
                        ["mimo-v2.5", "9", "免费"],
                    ]
                ),
                footer: nil
            )
        ),
        Sample(
            id: "plan", icon: "list.clipboard.fill",
            name: "任务计划卡",
            desc: "多步任务收尾时按执行顺序汇报各步完成度",
            card: AgentCard(
                kind: .plan, title: "备份照片到 NAS", subtitle: "3 步任务",
                status: AgentCard.Status(text: "2/3 完成", tone: .ok),
                fields: [], metrics: [],
                items: [
                    .init(title: "扫描相册", subtitle: "发现 128 张新照片", status: "完成", tone: .ok),
                    .init(title: "上传到 NAS", subtitle: "已传 86 张", status: "进行中", tone: .warn),
                    .init(title: "生成缩略图", subtitle: nil, status: "待开始", tone: .info),
                ],
                table: nil, footer: nil
            )
        ),
        Sample(
            id: "status", icon: "waveform.path.ecg",
            name: "状态卡",
            desc: "多服务/多设备巡检，异常项一眼看见",
            card: AgentCard(
                kind: .status, title: "服务状态", subtitle: "4 项巡检",
                status: AgentCard.Status(text: "1 项异常", tone: .error),
                fields: [
                    .init(key: "轻聊后端", value: "运行中", tone: .ok),
                    .init(key: "Hermes 网关", value: "运行中", tone: .ok),
                    .init(key: "语音识别", value: "未响应", tone: .error),
                ],
                metrics: [], items: [], table: nil,
                footer: "上次巡检 今天 09:20"
            )
        ),
    ]
}
