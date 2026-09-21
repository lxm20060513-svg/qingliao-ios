import SwiftUI

// MARK: - v3.9.46 看板卡片详情弹窗（门锁 / 温度 / 猫眼）
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
// v3.9.47（用户 2026-09-21 定稿）：弹窗内的卡片一律 `.frostedCard()`（半透明毛玻璃 + 圆角 16），
// 不再用 `.dashboardCard()` 的实色卡底——实色铺在弹窗材质上等于盖了块白板。
// 卡形（内边距 Spacing.xl / 0.8pt 描边 / 两层柔影 / 16 圆角）与开关弹窗里那张灯卡同参。
//
// v3.9.54（用户 2026-09-21 四条点名，本文件随之收口）：
//   · **卡形抄磁盘分区卡**：`HADeviceRow`（一长条：名称 + 状态 + 展开属性）换成 `HADeviceTile`
//     —— 结构与看板 `DiskTile`（DashboardView.swift 末尾）逐笔对齐：上行「名称 + 右上角短标签」、
//     大字主值、4pt 细进度条、tiny 说明行，`Spacing.xl` 内边距；弹窗内容改两列 `LazyVGrid`
//     （与 DisksSheet 同款排布）。**「原始属性」展开器整块删除**——它撑破卡形，
//     而磁盘卡本来就没有可展开的东西（要看细节去 HA）。
//     卡底仍走 `.frostedCard()` 而不是磁盘那枚 `.dashboardCard()`：两者圆角/描边/柔影逐字同参，
//     只差底材，而"弹窗内不许铺实色白板"是 v3.9.47 用户自己定的更高优先级的口径。
//   · **离线的卡片不再显示**（用户：「只保留可用卡片，离线卡片不显示」）——过滤在调用方
//     （DashboardView 的 `lockEntities` / `doorbellEntities` / `roomTempEntities` 共用 `isAvailable`）。
//   · **CPU / 内存详情弹窗删除**（用户：「去掉CPU和内存卡片的弹窗，只显示卡片，点击不再弹窗」）——
//     原 `NASMetricSheet` / `NASMetricKind` / 只有它在用的 `SheetSection` 一并删除。
//
// 数据侧零新增接口：三个设备弹窗吃看板已在轮询的 `/api/ha/states`（`haEntities`）。

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

/// 一组 HA 实体的详情弹窗。调用方负责把实体筛好（看板已有 `haEntities` 全量列表，
/// 并且已经把**离线的滤掉**——见 DashboardView 的 `isAvailable`）。
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
                    // v3.9.54：两列网格（与磁盘弹窗同排布），卡形抄 DiskTile
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(entities) { e in
                            HADeviceTile(entity: e)
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

/// 单个设备卡 —— **形态抄看板磁盘分区卡 `DiskTile`**（v3.9.54 用户点名）：
/// 上行「名称 + 右上角短标签」→ 大字主值 → 4pt 细进度条（有百分比可画时才有）→ tiny 说明行。
struct HADeviceTile: View {
    let entity: HAEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(displayName)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(kindLabel)
                    .font(.system(size: Typography.subhead, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Text(HAStateText.mapped(entity))
                .font(.system(size: Typography.headline, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, Spacing.sm)
            if let ratio = barRatio {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(uiColor: .systemGray5))
                        Capsule()
                            .fill(barColor(ratio))
                            .frame(width: geo.size.width * min(max(ratio, 0), 1))
                    }
                }
                .frame(height: 4)
                .padding(.top, Spacing.md)
            }
            let caption = captionText
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, barRatio == nil ? Spacing.md : Spacing.xs)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedCard()
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

    /// 右上角短标签：**说这张卡是什么量**，不重复大字里的值。
    /// 数值型实体取 device_class（温度/电量/湿度…），开关量按域名给（锁体/开关/传感器）。
    private var kindLabel: String {
        let dc = (entity.attributes["device_class"] as? String) ?? ""
        switch dc {
        case "temperature": return "温度"
        case "battery": return "电量"
        case "humidity": return "湿度"
        case "power": return "功率"
        case "voltage": return "电压"
        case "signal_strength": return "信号"
        default: break
        }
        let id = entity.entityID
        if id.contains("battery") { return "电量" }
        if id.contains("temperature") { return "温度" }
        if id.contains("humidity") { return "湿度" }
        if id.hasPrefix("lock.") { return "锁体" }
        if id.hasPrefix("switch.") { return "开关" }
        if id.hasPrefix("camera.") || id.contains("doorbell") { return "摄像头" }
        return "状态"
    }

    /// 进度条比例：只有**本身就是百分数**的实体才画（电量/湿度，或状态带 `%` 单位）。
    /// 温度不画 —— 硬编一条 0~40° 的刻度尺就是假精度，宁可少一层。
    private var barRatio: Double? {
        guard let v = Double(entity.state) else { return nil }
        let dc = (entity.attributes["device_class"] as? String) ?? ""
        let unit = (entity.attributes["unit_of_measurement"] as? String) ?? ""
        let isPercent = dc == "battery" || dc == "humidity" || unit == "%" || entity.entityID.contains("battery")
        guard isPercent else { return nil }
        return min(max(v / 100.0, 0), 1)
    }

    private func barColor(_ ratio: Double) -> Color {
        let pct = ratio * 100
        // 电量：越低越急；湿度/其它百分数：高一点不报警（与磁盘卡的 90/75 分档同源，但反向阈值另说）
        if kindLabel == "电量" {
            return pct <= 20 ? .red : (pct <= 45 ? .orange : .green)
        }
        return pct > 90 ? .red : (pct > 75 ? .orange : .green)
    }

    /// 说明行：电量/信号/电压摘要打头；没有摘要时退到实体后缀（认得出这是哪一枚实体）
    private var captionText: String {
        let summary = HAStateText.summary(entity)
        // 摘要里已经有"电量 xx%"时，别把同一个数再抄一遍到尾巴上
        if !summary.isEmpty { return summary }
        let tail = entity.entityID.split(separator: ".").dropFirst().joined(separator: ".")
        return tail.isEmpty ? entity.entityID : String(tail)
    }
}
