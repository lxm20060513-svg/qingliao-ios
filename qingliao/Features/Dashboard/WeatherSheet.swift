import SwiftUI

// MARK: - v3.9.25 天气弹窗（用户 2026-09-15 定稿：方案 C「玻璃 + 光晕」；左右滑动两页）
//
// 第 1 页「今天」：大温度 + 图标 + 天气描述 + 最高/最低
//   （用户定稿：三格数据 体感/湿度/风速 与逐时行**砍掉**，只留温度 —— 也正好不需要
//     apparent_temperature / humidity / wind / hourly 四个额外参数）
// 第 2 页「未来 5 天」：每行 = 星期 + 日期 + 图标 + 温度区间条 + 最低/最高
//   区间条按这 5 天的全局最低~最高映射，横向位置表示该日在区间里的相对位置（不含今天）
//
// 材质约定（守 v3.9.23 决策，勿改）：弹窗背景**不覆盖**系统材质；本视图只用「天气码驱动的
// 低透明度光晕」做氛围，不铺任何不透明底，也不套 glassCard —— 系统弹窗底本身就是玻璃，
// 再叠一层 glassEffect 会显旧（v3.9.22 已验证的观感回退）。
//
// 入口：本地模式看板天气徽章（此前无任何手势，本次新增）；云端模式徽章（原为换城市小弹窗，
// 换城市入口已挪进本视图右上角胶囊，旧的 220pt 小弹窗删除）。

struct WeatherSheet: View {
    /// 取数通路：.local 走后端（NAS 通道），.cloud 直连 Open-Meteo
    var mode: WeatherMode = .local

    @Environment(AuthStore.self) private var auth
    @Environment(\.colorScheme) private var scheme
    @AppStorage("qingliao_weather_city") private var savedCity = ""

    @State private var snap: WeatherSnapshot?
    @State private var errorText = ""
    @State private var loading = true
    @State private var page = 0
    @State private var showCityEdit = false
    @State private var cityInput = ""
    @State private var reloadToken = 0
    // v3.9.46：「重试」= 绕过天气缓存（其余路径命中缓存直接上屏）
    @State private var reloadForce = false
    // v3.9.30：第 1 页「展开更多」折叠区展开态
    @State private var extrasExpanded = false

    var body: some View {
        ZStack(alignment: .top) {
            glowLayer
            VStack(spacing: 0) {
                topBar
                content
            }
        }
        .task(id: reloadToken) { await loadWeather() }
        .alert("设置天气城市", isPresented: $showCityEdit) {
            TextField("如：上海 / 北京", text: $cityInput)
            Button("取消", role: .cancel) {}
            Button("保存") { saveCity() }
        } message: {
            Text("留空则用服务端默认城市（云端模式需填写城市）")
        }
    }

    // MARK: 顶部：城市 + 换城市（两页常驻，滑动换页也能点）

    private var topBar: some View {
        HStack(spacing: 8) {
            Text(displayCity)
                .font(.system(size: Typography.title, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            // v3.9.48：刷新胶囊（口径同生活页「刷新」= Text + .pill(.page)）——
            // v3.9.46 上了天气缓存（TTL 600s）之后，弹窗每次打开都可能命中缓存，
            // 想看"此刻"就得有个绕过缓存的出口；原先那个出口只藏在加载失败的「重试」里。
            if loading { ProgressView().controlSize(.small) }
            Button {
                Haptics.tap()
                reloadForce = true
                reloadToken += 1
            } label: {
                Text("刷新")
                    .pill(.page)
            }
            .buttonStyle(PressStyle(scale: 0.94))
            .disabled(loading)
            .accessibilityLabel("刷新天气（忽略缓存）")
            Button {
                cityInput = savedCity
                showCityEdit = true
            } label: {
                Text("换城市")
                    .pill(.page)   // 尺寸走 Pill 令牌（page：tiny + h10/v4，与原手写等价；原尾随 foregroundStyle 同值，已并入）
            }
            .buttonStyle(PressStyle(scale: 0.94))
            .accessibilityLabel("切换天气城市")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, Spacing.xs)
    }

    private var displayCity: String {
        if let c = snap?.city, !c.isEmpty { return c }
        return savedCity.isEmpty ? "天气" : savedCity
    }

    // MARK: 主体

    @ViewBuilder
    private var content: some View {
        if loading {
            // v3.9.30：加载态转圈 → 骨架屏（与 Sessions/Docker 同语言，预示"内容马上出现"）
            VStack(spacing: Spacing.lg) {
                SkeletonCard {
                    SkeletonBlock(width: 120, height: 14, cornerRadius: 7)
                    SkeletonBlock(width: 200, height: 40, cornerRadius: 10)
                    HStack(spacing: Spacing.md) {
                        ForEach(0..<5, id: \.self) { _ in
                            SkeletonBlock(width: 52, height: 64, cornerRadius: Radius.inset)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 30)
        } else if let snap {
            TabView(selection: $page) {
                todayPage(snap).tag(0)
                futurePage(snap).tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        } else {
            VStack(spacing: 10) {
                Image(systemName: "cloud.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(errorText.isEmpty ? "天气加载失败" : errorText)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Button {
                    reloadForce = true
                    reloadToken += 1
                } label: {
                    Text("重试")
                        .font(.system(size: Typography.subhead, weight: .medium))
                        .padding(.horizontal, Spacing.xxl)
                        .padding(.vertical, Spacing.sm)
                        .glassPillStroke()
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(PressStyle(scale: 0.94))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 30)
        }
    }

    // MARK: 第 1 页 · 今天

    private func todayPage(_ s: WeatherSnapshot) -> some View {
        let day = s.today
        let desc = WeatherCode.text(s.code)
        return VStack(spacing: 10) {
            Text("今天 \(todayLine(day))")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: WeatherCode.symbol(s.code))
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(WeatherCode.color(s.code))
                // 英雄数字：全库字号令牌上限是 28（display），大温度刻意不走令牌
                // —— 与看板空调高亮卡圆角 22 同属 hero 例外，改前先问
                Text(tempText(s.temp))
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(s.temp == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText())
            }
            if !desc.isEmpty {
                Text(desc)
                    .font(.system(size: Typography.headline, weight: .medium))
            }
            if let mx = WeatherService.degInt(day?.max), let mn = WeatherService.degInt(day?.min) {
                Text("最高 \(mx)° · 最低 \(mn)°")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
            }
            // v3.9.30：「展开更多」折叠区——体感/湿度/风速三格 + 未来 12 小时逐时。
            // 半屏口径不变：折叠区收起时只多一枚小胶囊；数据全缺（旧后端/缺字段）→ 入口整个不显示。
            if s.hasExtras {
                extrasCollapse(s)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 30)   // 给页码点留位
    }

    /// v3.9.30：折叠区展开态（三格 + 逐时横滑）。extrasExpanded 挂在 struct 顶层（@State）。
    private func extrasCollapse(_ s: WeatherSnapshot) -> some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(Motion.settle) { extrasExpanded.toggle() }
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                HStack(spacing: 5) {
                    Text(extrasExpanded ? "收起" : "展开更多")
                        .font(.system(size: Typography.caption))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(extrasExpanded ? 180 : 0))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.xs)
                .background(Color.primary.opacity(Tint.faint), in: Capsule())
            }
            .buttonStyle(PressStyle(scale: 0.94))

            if extrasExpanded {
                VStack(spacing: 12) {
                    // 三格：体感 / 湿度 / 风速（有哪个显示哪个）
                    HStack(spacing: 8) {
                        if let a = WeatherService.degInt(s.apparent) {
                            extraCell(icon: "thermometer.medium", label: "体感", value: "\(a)°")
                        }
                        if let h = WeatherService.degInt(s.humidity) {
                            extraCell(icon: "humidity", label: "湿度", value: "\(h)%")
                        }
                        if let w = s.wind {
                            extraCell(icon: "wind", label: "风速", value: "\(Int(w.rounded()))km/h")
                        }
                    }
                    // 逐时横滑（未来 12 小时）
                    if !s.hourly.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(s.hourly) { h in
                                    VStack(spacing: 4) {
                                        Text(h.hourText)
                                            .font(.system(size: Typography.caption))
                                            .foregroundStyle(.secondary)
                                        Image(systemName: WeatherCode.symbol(h.code))
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(WeatherCode.color(h.code))
                                        Text(WeatherService.degInt(h.temp).map { "\($0)°" } ?? "--")
                                            .font(.system(size: Typography.caption, weight: .semibold))
                                        if let p = h.pop, p > 0 {
                                            Text("\(p)%")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                }
                .padding(.vertical, Spacing.md)
                .padding(.horizontal, Spacing.lg)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(Tint.faint),
                            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// v3.9.30：折叠区三格中的一格
    private func extraCell(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: Typography.subhead, weight: .semibold))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func tempText(_ t: Double?) -> String {
        guard let i = WeatherService.degInt(t) else { return "--°" }
        return "\(i)°"
    }

    /// "9月15日 · 周二"（无逐日数据时退回今天本机日期）
    private func todayLine(_ day: WeatherDay?) -> String {
        let d = day.flatMap { WeatherService.date(from: $0.date) } ?? Date()
        return "\(WeatherService.monthDayText(d)) · \(WeatherService.weekdayText(d))"
    }

    // MARK: 第 2 页 · 未来 5 天

    private func futurePage(_ s: WeatherSnapshot) -> some View {
        let days = Array(s.future.prefix(5))
        let lo = days.compactMap { $0.min }.min() ?? 0
        let hi = days.compactMap { $0.max }.max() ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            Text("未来 5 天")
                .font(.system(size: Typography.title, weight: .bold))
            if days.isEmpty {
                Text("暂无未来天气数据")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(days) { d in
                    dayRow(d, lo: lo, hi: hi)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, Spacing.md)
        .padding(.bottom, 30)
    }

    private func dayRow(_ d: WeatherDay, lo: Double, hi: Double) -> some View {
        let dt = WeatherService.date(from: d.date)
        return HStack(spacing: 8) {
            Text(dt.map { WeatherService.weekdayText($0) } ?? "--")
                .font(.system(size: Typography.subhead, weight: .medium))
                .frame(width: 38, alignment: .leading)
            Text(dt.map { WeatherService.slashText($0) } ?? "")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Image(systemName: WeatherCode.symbol(d.code))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(WeatherCode.color(d.code))
                .frame(width: 20)
            Spacer(minLength: 4)
            rangeBar(d, lo: lo, hi: hi)
            Text(WeatherService.degInt(d.min).map { "\($0)°" } ?? "--")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
            Text(WeatherService.degInt(d.max).map { "\($0)°" } ?? "--")
                .font(.system(size: Typography.subhead, weight: .semibold))
                .frame(width: 32, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowA11y(d, dt: dt))
    }

    /// 当周区间条：底色是整周跨度，彩色段是该日跨度（位置即相对冷热）
    private func rangeBar(_ d: WeatherDay, lo: Double, hi: Double) -> some View {
        let width: CGFloat = 96
        let g = WeatherService.barGeometry(min: d.min, max: d.max, lo: lo, hi: hi, width: width)
        let c = WeatherCode.color(d.code)
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(Tint.faint))
                .frame(height: 4)
            Capsule()
                .fill(LinearGradient(colors: [c.opacity(0.55), c.opacity(0.95)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: g.w, height: 4)
                .offset(x: g.x)
        }
        .frame(width: width, height: 4)
    }

    private func rowA11y(_ d: WeatherDay, dt: Date?) -> String {
        var parts: [String] = []
        if let dt { parts.append(WeatherService.weekdayText(dt) + WeatherService.slashText(dt)) }
        let t = WeatherCode.text(d.code)
        if !t.isEmpty { parts.append(t) }
        if let mn = WeatherService.degInt(d.min), let mx = WeatherService.degInt(d.max) {
            parts.append("最低 \(mn) 度，最高 \(mx) 度")
        }
        return parts.joined(separator: "，")
    }

    // MARK: 光晕（方案 C：天气码驱动，深浅各自低透明度，不铺底）

    private var glowLayer: some View {
        let c = WeatherCode.color(snap?.code)
        return RadialGradient(colors: [c.opacity(scheme == .dark ? 0.34 : 0.20), c.opacity(0)],
                              center: .top, startRadius: 0, endRadius: 300)
            .frame(height: 360)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .top)
            .animation(Motion.flow, value: snap?.code)
    }

    // MARK: 取数

    private func loadWeather() async {
        errorText = ""
        let city = savedCity.trimmingCharacters(in: .whitespaces)
        // v3.9.46：命中缓存直接上屏（弹窗秒开，不再每次转骨架屏）。
        // 「重试」按钮显式作废这一城的缓存再走网络（reloadForce 用完即清，防止后续 task 重启被带跑）。
        if reloadForce {
            WeatherCache.invalidate(city: city)
            reloadForce = false
        } else if let hit = WeatherCache.value(city: city) {
            snap = hit
            loading = false
            return
        }
        loading = true
        if mode == .cloud {
            let (s, err) = await WeatherService.fetchCloud(city: city)
            snap = s
            errorText = err
            if let s, err.isEmpty { WeatherCache.put(city: city, snap: s) }
            loading = false
            return
        }
        let q = city.isEmpty ? "" : "?city=" + (city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        if let j = await auth.jsonOrLog("/api/weather\(q)") {
            let s = WeatherService.parseBackend(j)
            snap = s
            WeatherCache.put(city: city, snap: s)
        } else {
            snap = nil
            errorText = "天气查询失败（后端未连接）"
        }
        loading = false
    }

    private func saveCity() {
        let c = cityInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // v3.9.46：改了城市设置就是要看新城市的当前天气 ⇒ 作废该城缓存强制重取
        // （其他城市的条目不动，切回去 10 分钟内仍秒开）
        savedCity = c
        WeatherCache.invalidate(city: c.trimmingCharacters(in: .whitespaces))
        reloadToken += 1
    }
}
