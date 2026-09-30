import SwiftUI

struct HADeviceSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let title: String
    let domain: String

    @State private var entities: [HAEntity] = []
    @State private var loading = true
    @State private var busyID: String?
    /// v3.9.41：设备控制失败提示（此前 catch 是空的，失败只剩「转圈→开关弹回」）
    @State private var controlError = ""

    var body: some View {
        VStack(spacing: 0) {
            haSheetHeader

            haSheetContent
        }
        // v3.9.24：此处原有 systemBackground 实底 → 会盖住弹窗的系统材质（用户要求所有弹窗与「关于轻聊」一致 = 系统默认）→ 已删。
        // 注：v2.0.87l 那句"弹窗玻璃罩效果不佳"说的是当年的**自绘**玻璃，与 iOS 26 系统材质不是一回事，别据此回退
        .task { await load() }
        // v3.9.41：控制失败要有反馈（对齐场景卡的「场景执行结果」提示口径）
        .alert("设备控制失败", isPresented: Binding(
            get: { !controlError.isEmpty },
            set: { if !$0 { controlError = "" } }
        )) {
            Button("好的", role: .cancel) { controlError = "" }
        } message: {
            Text(controlError)
        }
    }

    // MARK: - v4.0.x HADeviceSheet 分区（巨型 body 拆分）
    //
    // 由头：此 body 单块 67 行，与本仓已踩过两次的「Unable to type-check this
    // expression in reasonable time」高危形态同源。设备内容区那段 if/else-if 三分支
    // （加载中 / 空态 / 灯网格 / 空调卡）合成一个大表达式，单独拆开即止。
    // **纯搬运**：视图顺序、层级、条件分支、闭包、修饰符逐字未变。

    /// 弹窗头部：标题 + 关闭键
    @ViewBuilder
    private var haSheetHeader: some View {
    HStack {
        Text(title)
            .font(.system(size: Typography.title, weight: .bold))
        Spacer()
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: Typography.titleXL))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
    }
    .padding(.horizontal, 18)
    .padding(.top, 18)
    .padding(.bottom, Spacing.md)
    }

    /// 设备内容区：加载中 / 空态 / 灯网格 / 空调模式卡
    @ViewBuilder
    private var haSheetContent: some View {
    if loading {
        // v3.9.42：设备是双列网格，行骨架不贴结构 → 收口转圈；
        // 保留原 Spacer（sheet 高度由它撑，去掉会让 sheet 在加载瞬间塌一截）
        Spacer()
        LoadingStateView(shape: .spinner(text: "正在加载设备…"))
        Spacer()
    } else if entities.isEmpty {
        Spacer()
        Text("暂无可用设备")
            .font(.system(size: Typography.subhead))
            .foregroundStyle(.tertiary)
        Spacer()
    } else if domain == "light" {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(entities) { e in
                    lightCard(e)
                }
            }
            .padding(.horizontal, Spacing.section)
            .padding(.bottom, 20)
        }
    } else {
        // 空调：模式控制卡
        ScrollView {
            VStack(spacing: 12) {
                ForEach(entities) { e in
                    climateCard(e)
                }
            }
            .padding(.horizontal, Spacing.section)
            .padding(.bottom, 20)
        }
    }
    }

    // MARK: - 灯卡（PWA HomeKit 复刻：渐变图标容器 + 圆形小开关）

    private func lightCard(_ e: HAEntity) -> some View {
        let isOn = e.state == "on"
        // 拆成 AnyShapeStyle 单一类型（三元 LinearGradient vs Color 会让编译器类型检查超时）
        let iconBG: AnyShapeStyle = isOn
            ? AnyShapeStyle(LinearGradient(colors: [Color.yellow.opacity(Tint.strong), Color.orange.opacity(Tint.soft)],
                                           startPoint: .top, endPoint: .bottom))
            : AnyShapeStyle(Color(uiColor: .systemGray6))
        return Button {
            toggle(e)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // 图标容器：点亮=黄色渐变光晕 / 熄灭=灰底
                    ZStack {
                        RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                            .fill(iconBG)
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: Typography.titleXL, weight: .medium))
                            .foregroundStyle(isOn ? Color.yellow : Color.gray.opacity(0.5))
                            .shadow(color: isOn ? Color.yellow.opacity(0.8) : .clear, radius: 8)
                    }
                    .frame(width: 46, height: 46)
                    Spacer()
                    // 圆形小开关（PWA .ha-toggle 同款）
                    ZStack {
                        Circle()
                            .fill(isOn ? Color.accentColor : Color(uiColor: .systemGray5))
                        if busyID == e.entityID {
                            ProgressView().tint(.white).scaleEffect(0.65)
                        } else {
                            Image(systemName: "power")
                                .font(.system(size: Typography.tiny, weight: .bold))
                                .foregroundStyle(isOn ? .white : Color.secondary)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .shadow(color: isOn ? Color.accentColor.opacity(0.45) : .clear, radius: 4)
                }
                Text(displayName(e))
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(isOn ? "已开启" : "已关闭")
                    .font(.system(size: Typography.tiny))
                    .fontWeight(isOn ? .semibold : .regular)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            }
            .padding(Spacing.xl)
            .frame(minHeight: 92)
            // v2.0.87h：弹窗液态玻璃下卡片扁平化（去白圆角底，仅极轻底区分）
            // v3.0.6 fix：卡片补描边（用户要求每个开关卡都描框）
            // v3.9.47（用户：弹窗里的卡片一律不要白底）：卡底换成和五个新弹窗同款的半透明毛玻璃
            // `frostedCard()`（16 圆角 + 0.8pt 描边 + 两层柔影），点亮态在毛玻璃上再叠一层强调色淡染。
            // 本卡即「开关卡片的卡片形式」基准 → 改了它，弹窗内的卡形才谈得上对齐。
            .background(isOn ? Color.accentColor.opacity(Tint.subtle) : Color.clear)
            .frostedCard()
        }
        .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
    }

    // MARK: - 空调卡（PWA climate-card 复刻：跨行渐变卡 + 电源圆钮 + 模式胶囊）

    private func climateCard(_ e: HAEntity) -> some View {
        let attrs = e.attributes
        let cur = (attrs["current_temperature"] as? Double) ?? 0
        let target = (attrs["temperature"] as? Double) ?? 24
        let step = (attrs["target_temp_step"] as? Double) ?? 1
        let modes = (attrs["hvac_modes"] as? [String]) ?? ["off", "auto", "cool", "dry", "heat", "fan_only"]
        // 关闭模式统一置顶（所有空调卡片一致）
        let orderedModes = ["off"] + modes.filter { $0 != "off" }
        let isOn = e.state != "off" && e.state != "unavailable"

        return VStack(alignment: .leading, spacing: 10) {
            // 顶部：图标 + 名称/状态 + 电源（关闭按钮统一在最右）
            HStack(spacing: 10) {
                Image(systemName: "snowflake")
                    .font(.system(size: Typography.titleXL))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName(e))
                        .font(.system(size: Typography.subhead, weight: .medium))
                        .lineLimit(1)
                    Text(isOn ? modeName(e.state) : "已关闭")
                        .font(.system(size: Typography.caption, weight: .semibold))
                        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                }
                Spacer()
                // 电源圆钮（统一贴最右）
                Button {
                    toggle(e)
                } label: {
                    ZStack {
                        Circle()
                            .fill(isOn ? Color.accentColor : Color(uiColor: .systemGray5))
                        Image(systemName: "power")
                            .font(.system(size: Typography.subhead, weight: .bold))
                            .foregroundStyle(isOn ? .white : Color.secondary)
                    }
                    .frame(width: 32, height: 32)
                    .shadow(color: isOn ? Color.accentColor.opacity(0.5) : .clear, radius: 6)
                }
                .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
            }

            // 温度：目标大字 + 室温 + 步进
            HStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.0f", target))
                        .font(.system(size: 32, weight: .bold))
                        .contentTransition(.numericText(value: target))   // v3.4.29：调温数字滚动
                        .animation(Motion.snap, value: target)
                    Text("°")
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.secondary)
                }
                Text("室温 \(String(format: "%.0f", cur))°")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    setTemp(e, value: target - step)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: Typography.subhead, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Color(uiColor: .systemGray5), in: Circle())
                }
                .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                Button {
                    setTemp(e, value: target + step)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: Typography.subhead, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Color(uiColor: .systemGray5), in: Circle())
                }
                .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
            }

            // 模式按钮行
            HStack(spacing: 8) {
                ForEach(orderedModes, id: \.self) { m in
                    Button {
                        setMode(e, mode: m)
                    } label: {
                        // v2.0.87k：判定 lowercased（HA 部分实体返回 "Off" 大写导致选中态不匹配）
                        let active = e.state.lowercased() == m
                        Text(modeName(m))
                            .font(.system(size: Typography.caption, weight: active ? .bold : .medium))
                            .foregroundStyle(active ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                    .fill(active ? Color.accentColor : Color(uiColor: .systemGray5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                    .strokeBorder(active ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.2)
                            )
                    }
                    .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                }
            }

            // v2.0.96：风速调节行（auto/低/中/高；关闭时禁用）
            if isOn {
                let fanModes = (attrs["fan_modes"] as? [String]) ?? []
                if !fanModes.isEmpty {
                    let curFan = (attrs["fan_mode"] as? String) ?? ""
                    HStack(spacing: 8) {
                        ForEach(fanModes, id: \.self) { f in
                            Button {
                                setFanMode(e, mode: f)
                            } label: {
                                let active = curFan.lowercased() == f.lowercased()
                                Text(fanModeName(f))
                                    .font(.system(size: Typography.caption, weight: active ? .bold : .medium))
                                    .foregroundStyle(active ? Color.white : Color.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, Spacing.md)
                                    .background(
                                        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                            .fill(active ? Color.indigo : Color(uiColor: .systemGray5))
                                    )
                            }
                            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                        }
                    }
                }
            }
        }
        .padding(Spacing.xxl)
        .background(
            // v2.0.87j：弹窗玻璃下扁平化（渐变末端白底 → 轻透明）
            LinearGradient(colors: [isOn ? Color.blue.opacity(Tint.soft) : Color.blue.opacity(Tint.faint), Color(uiColor: .secondarySystemGroupedBackground)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                .strokeBorder(isOn ? Color.accentColor.opacity(0.35) : Color.white.opacity(Tint.faint), lineWidth: 1)
        )
        .shadow(color: isOn ? Color.accentColor.opacity(Tint.soft) : .clear, radius: 10, y: 3)
    }

    /// 模式显示名
    private func modeName(_ m: String) -> String {
        switch m {
        case "off": "关闭"
        case "auto": "自动"
        case "cool": "制冷"
        case "heat": "制热"
        case "dry": "除湿"
        case "fan_only": "送风"
        default: m
        }
    }

    /// v2.0.96：风速显示名
    private func fanModeName(_ f: String) -> String {
        switch f.lowercased() {
        case "auto": "自动"
        case "low": "低"
        case "medium", "mid": "中"
        case "high": "高"
        case "sleep": "睡眠"
        default: f
        }
    }

    /// v2.0.96：风速调节
    private func setFanMode(_ e: HAEntity, mode: String) {
        callService(domain: "climate", service: "set_fan_mode", entityID: e.entityID,
                    extra: ["fan_mode": mode])
    }

    // MARK: - 服务调用（Task 内只捕获 Sendable 值）

    private func toggle(_ e: HAEntity) {
        // switch 域实体（NAS 插座/消毒柜追加进灯列表）用 switch 服务域
        if e.entityID.hasPrefix("switch.") {
            callService(domain: "switch", service: "toggle", entityID: e.entityID, extra: nil)
        } else if domain == "climate" {
            // v2.0.102：climate 域无 toggle 服务——开=auto，关=off（原调 climate.toggle 永远无效）
            callService(domain: "climate", service: "set_hvac_mode", entityID: e.entityID,
                        extra: ["hvac_mode": e.state == "off" ? "auto" : "off"])
        } else {
            callService(domain: domain, service: "toggle", entityID: e.entityID, extra: nil)
        }
    }

    private func setMode(_ e: HAEntity, mode: String) {
        callService(domain: "climate", service: "set_hvac_mode", entityID: e.entityID,
                    extra: ["hvac_mode": mode])
    }

    private func setTemp(_ e: HAEntity, value: Double) {
        callService(domain: "climate", service: "set_temperature", entityID: e.entityID,
                    extra: ["temperature": value])
    }

    private func callService(domain: String, service: String, entityID: String, extra: [String: Any]?) {
        guard busyID == nil else { return }
        busyID = entityID
        let id = entityID
        let path = "/api/ha/services/\(domain)/\(service)"
        var body: [String: Any] = ["entity_id": id]
        if let extra { body.merge(extra) { _, new in new } }
        Task {
            defer { busyID = nil }
            do {
                _ = try await auth.request(path, method: "POST", body: body)
            } catch {
                // v3.9.41：原来这里是空的 `catch {}` —— ha_proxy 是原样透传 Home Assistant 的
                // 状态码（`_proxy` 里 `send_response(status)`），而 `AuthStore.request` 对非 2xx
                // 一定抛错，所以失败其实拿得到，只是被吞了：用户只看得到转圈→开关弹回，
                // 分不清是「HA 拒绝」还是「网断了」。下面紧接的 load() 会把状态纠正回真值（保留）。
                controlError = "「\(id)」控制失败：\(error.localizedDescription)"
            }
            await load()
        }
    }

    private func load() async {
        if let arr = try? await auth.jsonArray("/api/ha/states") {
            let all = arr.compactMap { HAEntity.parse($0 as? [String: Any] ?? [:]) }
            var list = all.filter {
                $0.entityID.hasPrefix(domain + ".") && !$0.state.contains("unavailable")
            }
            if domain == "light" {
                // 灯列表过滤指示灯（NAS 查询指示灯等不参与），追加 NAS 插座/消毒柜 switch 实体（可控制）
                list = list.filter { !$0.entityID.contains("indicator_light") }
                let extraSwitches = all.filter {
                    ["switch.chuangmi_cn_237985068_m3_on_p_2_1",
                     "switch.lumi_cn_lumi_158d00039bca0b_v1_on_p_2_1"].contains($0.entityID)
                }
                list.append(contentsOf: extraSwitches)
            }
            entities = list
        }
        loading = false
    }

    /// 设备显示名：friendly_name 太长时取第一段
    private func displayName(_ e: HAEntity) -> String {
        var name = e.friendlyName
        if name.isEmpty {
            name = e.entityID
        } else {
            // 小米设备 friendly_name 常含重复（"客厅灯  客厅灯 开关"）→ 去重保留第一段
            let parts = name.split(separator: " ").filter { !$0.isEmpty }
            if parts.count >= 2 && parts[0] == parts[1] {
                name = String(parts[0])
            }
        }
        return name
    }
}

// MARK: - 磁盘弹窗（点看板"磁盘"卡弹出，2 列卡片）

struct DisksSheet: View {
    @Environment(\.dismiss) private var dismiss
    let disks: [NASDisk]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("全部磁盘")
                    .font(.system(size: Typography.title, weight: .bold))
                Spacer()
                Text("\(disks.count) 个分区")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.titleXL))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, Spacing.lg)

            ScrollView {
                // v3.0.36：按 kind 分组显示（系统盘分区 / 数据卷）
                let system = disks.filter { $0.isSystem }
                let data = disks.filter { !$0.isSystem }
                VStack(alignment: .leading, spacing: 14) {
                    if !system.isEmpty {
                        Text("系统盘分区")
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Spacing.section)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(system) { d in
                                DiskTile(disk: d)
                            }
                        }
                        .padding(.horizontal, Spacing.section)
                    }
                    if !data.isEmpty {
                        Text("数据卷")
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Spacing.section)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(data) { d in
                                DiskTile(disk: d)
                            }
                        }
                        .padding(.horizontal, Spacing.section)
                    }
                }
                .padding(.top, Spacing.md)
                .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - v2.0.96 场景项

