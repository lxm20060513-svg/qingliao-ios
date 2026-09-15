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
            Button {
                cityInput = savedCity
                showCityEdit = true
            } label: {
                Text("换城市")
                    .font(.system(size: Typography.tiny))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(Tint.subtle), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(PressStyle(scale: 0.94))
            .accessibilityLabel("切换天气城市")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private var displayCity: String {
        if let c = snap?.city, !c.isEmpty { return c }
        return savedCity.isEmpty ? "天气" : savedCity
    }

    // MARK: 主体

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在获取天气…")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
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
                    reloadToken += 1
                } label: {
                    Text("重试")
                        .font(.system(size: Typography.subhead, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(Tint.subtle), in: Capsule())
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 30)   // 给页码点留位
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
        .padding(.top, 8)
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
        loading = true
        errorText = ""
        let city = savedCity.trimmingCharacters(in: .whitespaces)
        if mode == .cloud {
            let (s, err) = await WeatherService.fetchCloud(city: city)
            snap = s
            errorText = err
            loading = false
            return
        }
        let q = city.isEmpty ? "" : "?city=" + (city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        if let j = await auth.jsonOrLog("/api/weather\(q)") {
            snap = WeatherService.parseBackend(j)
        } else {
            snap = nil
            errorText = "天气查询失败（后端未连接）"
        }
        loading = false
    }

    private func saveCity() {
        let c = cityInput.trimmingCharacters(in: .whitespacesAndNewlines)
        savedCity = c
        reloadToken += 1
    }
}
