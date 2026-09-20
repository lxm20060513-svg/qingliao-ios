import SwiftUI

// MARK: - v3.9.46 看板卡片详情弹窗（门锁 / 温度 / 猫眼 / CPU / 内存）
//
// 由来：用户 2026-09-20 点名「这些卡片点击要能弹窗看细节」，并要求
// **「所有弹窗统一用目前的弹窗样式」**。样式口径逐字对齐 DisksSheet / HADeviceSheet /
// ServiceControlSheet / WeatherSheet 那套既有头部（`Typography.title` bold + Spacer +
// 次级计数文案 + `xmark.circle.fill` 关闭钮），本次把该头部抽成 `BoardSheetHeader`，
// 新弹窗一律用它，不再抄第五份。
//
// ⚠️ 两条既有红线（改前先读）：
//   ① 弹窗背景**不覆盖系统材质**（v3.9.23 决策，见 WeatherSheet 头注释）——这里一个 background 都不铺；
//   ② 挂载一律走 DashboardView 的 `.sheet(item: $activeSheet)` + `.presentationDetents` +
//      `matchedTransitionSource`/`navigationTransition(.zoom)`，与磁盘/Docker 弹窗同一条路。
//
// 数据侧零新增接口：三个设备弹窗吃看板已在轮询的 `/api/ha/states`（`haEntities`），
// CPU/内存弹窗吃 `/api/nas/status`（`NASStatus`）+ `/api/hw/status`（hwCpu/hwSsd）。

// MARK: - 统一头部

/// 看板详情弹窗的统一头部（标题 + 可选右侧计数 + 关闭钮）
struct BoardSheetHeader: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var detail: String = ""

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: Typography.title, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer()
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Typography.titleXL))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, Spacing.lg)
    }
}

// MARK: - 通用容器/行

/// 弹窗内的分组卡（标题 + 若干行），卡面走全站 `dashboardCard()`
private struct SheetSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.lg)
                .padding(.bottom, Spacing.xs)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }
}

/// 左标签右值的一行
struct SheetKVRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            Spacer(minLength: Spacing.md)
            Text(value)
                .font(.system(size: Typography.body, weight: .semibold))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
    }
}

// MARK: - HA 实体 → 中文状态

/// Home Assistant 实体状态中文化。
/// 只做**确定性的通用映射**：认不出的状态原样显示（HA 的 state 是字符串，各家插件自定义值
/// 没法穷举），数值型按 device_class / unit_of_measurement 补单位。
enum HAStateText {
    static func mapped(_ e: HAEntity) -> String {
        let st = e.state
        if st.isEmpty { return "--" }
        if st.contains("unavailable") || st == "unknown" { return "离线" }
        switch st {
        case "locked": return "已上锁"
        case "unlocked": return "已解锁"
        case "jammed": return "卡锁"
        case "open": return "已打开"
        case "opened", "closing": return "开合中"
        case "closed": return "已关闭"
        case "on": return "开"
        case "off": return "关"
        case "home": return "在家"
        case "away": return "离家"
        case "night": return "夜间"
        case "armed_away", "布防": return "布防"
        case "armed_home": return "在家布防"
        case "disarmed", "撤防": return "撤防"
        case "idle", "standby": return "待机"
        case "running": return "运行中"
        case "paused": return "已暂停"
        case "drying": return "烘干中"
        case "auto": return "自动"
        case "cool": return "制冷"
        case "heat": return "制热"
        case "heat_cool": return "冷暖"
        case "fan_only": return "送风"
        case "dry": return "除湿"
        default: break
        }
        if let v = Double(st) {
            let dc = (e.attributes["device_class"] as? String) ?? ""
            if dc == "temperature" || e.entityID.contains("temperature") {
                return String(format: "%.1f°", v)
            }
            if dc == "humidity" || dc == "battery" || e.entityID.contains("battery") {
                return "\(Int(v.rounded()))%"
            }
            if let u = (e.attributes["unit_of_measurement"] as? String), !u.isEmpty {
                return "\(st) \(u)"
            }
            return st
        }
        return st
    }

    /// 一行次要摘要（电量 / 信号 / 电压），没有任何一项就返回空串不占行
    /// （取数用 WeatherService.num —— 那是全仓共用的「JSON 数字可能是 Int/Double/NSNumber/String」
    ///   兼容解析 + NaN/超范围护栏，别再手写第四份）
    static func summary(_ e: HAEntity) -> String {
        var parts: [String] = []
        if let b = WeatherService.num(e.attributes["battery_level"]) {
            parts.append("电量 \(Int(b.rounded()))%")
        }
        if let s = WeatherService.num(e.attributes["signal_strength"]) {
            parts.append("信号 \(Int(s.rounded()))dBm")
        }
        if let v = WeatherService.num(e.attributes["voltage"]) {
            parts.append(String(format: "电压 %.1fV", v))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 设备详情弹窗（门锁 / 猫眼 / 各房间温度 共用）

/// 一组 HA 实体的详情弹窗。调用方负责把实体筛好（看板已有 `haEntities` 全量列表）。
/// 每张卡 = 设备名 + 主状态 + 电量/信号摘要 + 可展开的原始属性。
struct HADeviceDetailSheet: View {
    let title: String
    let detail: String
    let entities: [HAEntity]
    var emptyTitle: String = "没有读到这个设备的实体"
    var emptySubtitle: String = "看板每 30 秒随状态轮询刷新，也可以下拉看板重取"

    var body: some View {
        VStack(spacing: 0) {
            BoardSheetHeader(title: title, detail: detail)
            ScrollView {
                if entities.isEmpty {
                    EmptyStateView(icon: "wifi.slash", title: emptyTitle, subtitle: emptySubtitle)
                        .padding(.top, Spacing.section)
                } else {
                    VStack(spacing: Spacing.md) {
                        ForEach(entities) { e in
                            HADeviceRow(entity: e)
                        }
                    }
                    .padding(.horizontal, Spacing.section)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, 24)
                }
            }
        }
    }
}

/// 属性表一行（元组不能当 ForEach 元素：Swift 不支持对元组成员取 KeyPath，故用 Identifiable 结构体）
struct HAAttrRow: Identifiable {
    let key: String
    let value: String
    var id: String { key }
}

/// 单个实体一行（属性折叠展开）
struct HADeviceRow: View {
    let entity: HAEntity
    @State private var showAttrs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(displayName)
                    .font(.system(size: Typography.body, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: Spacing.md)
                Text(HAStateText.mapped(entity))
                    .font(.system(size: Typography.headline, weight: .bold))
                    .foregroundStyle(stateColor)
            }
            let summary = HAStateText.summary(entity)
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                    .padding(.top, Spacing.xs)
            }
            if !attrRows.isEmpty {
                Button {
                    withAnimation(Motion.snap) { showAttrs.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(showAttrs ? "收起原始属性" : "查看原始属性")
                            .font(.system(size: Typography.tiny))
                        Image(systemName: showAttrs ? "chevron.up" : "chevron.down")
                            .font(.system(size: Typography.tiny, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, Spacing.md)
                if showAttrs {
                    VStack(spacing: Spacing.xs) {
                        ForEach(attrRows) { row in
                            SheetKVRow(label: row.key, value: row.value,
                                       valueColor: Color.secondary)
                                .font(.system(size: Typography.caption))
                        }
                    }
                    .padding(.top, Spacing.sm)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    /// 设备名：friendly_name 优先；小米常见重复（"客厅灯 客厅灯 开关"）→ 取不重复的前两段
    private var displayName: String {
        let raw = entity.friendlyName.isEmpty ? entity.entityID : entity.friendlyName
        let parts = raw.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2, parts[0] == parts[1] {
            return parts.prefix(2).joined(separator: " ")
        }
        return raw
    }

    private var stateColor: Color {
        let st = entity.state
        if st.isEmpty || st.contains("unavailable") || st == "unknown" { return .secondary }
        return Color.accentColor
    }

    /// 原始属性表白名单优先（电量/型号/固件等），其余按 key 排序补齐，总数与单值长度都设上限，
    /// 免得某个插件塞回一大坨数组把弹窗撑爆。
    private var attrRows: [HAAttrRow] {
        let skip: Set<String> = ["friendly_name", "entity_id"]
        let preferred = ["battery_level", "device_class", "state_class", "unit_of_measurement",
                         "model", "sw_version", "hw_version", "manufacturer",
                         "signal_strength", "voltage", "icon"]
        var out: [HAAttrRow] = []
        var used = skip
        for k in preferred where entity.attributes[k] != nil {
            used.insert(k)
            if let v = text(entity.attributes[k]) { out.append(HAAttrRow(key: k, value: v)) }
        }
        for k in entity.attributes.keys.sorted() where !used.contains(k) {
            if out.count >= 12 { break }
            if let v = text(entity.attributes[k]) { out.append(HAAttrRow(key: k, value: v)) }
        }
        return out
    }

    private func text(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let s = any as? String { return s.isEmpty ? nil : String(s.prefix(60)) }
        if let n = any as? NSNumber { return n.stringValue }
        if let arr = any as? [Any] { return arr.isEmpty ? nil : "\(arr.count) 项" }
        if let dict = any as? [String: Any] { return dict.isEmpty ? nil : "\(dict.count) 项" }
        return String(describing: any).prefix(60).description
    }
}

// MARK: - NAS CPU / 内存详情弹窗

enum NASMetricKind: String {
    case cpu, memory

    var sheetTitle: String { self == .cpu ? "CPU 详情" : "内存详情" }
    var heroLabel: String { self == .cpu ? "当前使用率" : "已用 / 总量" }
}

/// CPU / 内存共用一张详情弹窗（同一套数据、只差关注点），入口是 NAS 面板那两张 MeterCard。
/// ⚠️ 后端 `/api/nas/status` 目前**只有整机单值** cpu% 与 mem{total,used}：
/// 没有每核占用、没有 load average、没有进程榜，所以这里不画假精度条，只把已有字段
/// 讲清楚（含两个容器各自的内存），并注明粒度所限。
struct NASMetricSheet: View {
    let kind: NASMetricKind
    let nas: NASStatus
    var hwCpu: Double? = nil
    var hwSsd: Double? = nil

    var body: some View {
        VStack(spacing: 0) {
            BoardSheetHeader(title: kind.sheetTitle, detail: nas.hostname)
            ScrollView {
                VStack(spacing: Spacing.md) {
                    heroBlock
                    SheetSection(title: "占用来源") { sourceRows }
                    SheetSection(title: "整机") { machineRows }
                }
                .padding(.horizontal, Spacing.section)
                .padding(.top, Spacing.sm)
                .padding(.bottom, 24)
            }
        }
    }

    private var ratio: Double {
        kind == .cpu ? Swift.min(Swift.max(nas.cpu / 100.0, 0), 1) : Swift.min(Swift.max(nas.memPct, 0), 1)
    }

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(kind.heroLabel)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(kind == .cpu ? nas.cpuText
                                  : "\(nas.memUsedText) / \(nas.memTotalText)")
                    // hero 数字刻意不走字号令牌（全站上限 28），与天气弹窗大温度同口径
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Spacer()
                Text("\(Int((ratio * 100).rounded()))%")
                    .font(.system(size: Typography.headline, weight: .semibold))
                    .foregroundStyle(barColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: .systemGray5))
                    Capsule().fill(barColor)
                        .frame(width: geo.size.width * CGFloat(ratio))
                }
            }
            .frame(height: 6)
            Text(kind == .cpu
                 ? "整机单值（后端不区分每核占用，也没有负载均值/进程榜）"
                 : "剩余 \(nas.memTotal > 0 ? (nas.memTotal - nas.memUsed).byteText : "--")（后端 mem.used 口径，不含缓存回收）")
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.tertiary)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    @ViewBuilder
    private var sourceRows: some View {
        SheetKVRow(label: "轻聊后端 内存", value: nas.qingliaoMemText)
        SheetKVRow(label: "轻聊容器 内存", value: nas.qingliaoDockerMemText)
        SheetKVRow(label: "Hermes 网关 内存", value: nas.hermesMemText,
                   valueColor: nas.hermesAlive ? .primary : .red)
        SheetKVRow(label: "Hermes 版本", value: nas.hermesVersion.isEmpty ? "--" : nas.hermesVersion)
    }

    @ViewBuilder
    private var machineRows: some View {
        SheetKVRow(label: "CPU 温度", value: hwCpu.map { String(format: "%.0f°C", $0) } ?? "--")
        SheetKVRow(label: "SSD 温度", value: hwSsd.map { String(format: "%.0f°C", $0) } ?? "--")
        SheetKVRow(label: "运行时间", value: nas.uptime.isEmpty ? "--" : nas.uptime)
        SheetKVRow(label: "主机名", value: nas.hostname.isEmpty ? "--" : nas.hostname)
    }

    private var barColor: Color {
        ratio > 0.9 ? .red : (ratio > 0.75 ? .orange : (kind == .cpu ? .blue : .green))
    }
}
