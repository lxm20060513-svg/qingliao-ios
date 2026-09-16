import SwiftUI

// MARK: - v3.9.25 天气数据服务（WMO 映射单一真源 + 两通路取数）
//
// 背景：天气码 → 图标/颜色的映射原先只写在 WeatherBadge 里（private var），中文描述只写在
// 原 LocalToolRunner.weatherText 里 —— 同一套 WMO 规则散在两处，天气弹窗若再抄一遍就是第三份。
// 这里收敛为单一真源：
//   · WeatherBadge 改为转调本文件（逐字照搬，**唯一有意变更**：85/86 阵雪由原 default 的
//     cloud.fill 改为 cloud.snow.fill，与 WeatherCode.text 的「阵雪」对齐；颜色未动）
//   · 原 LocalToolRunner.weatherText 改为转调本文件（纯照搬，行为一致；该工具已随云端模式移除）
//   · 新增的 WeatherSheet 直接用
//
// 取数两通路（用户 2026-09-15 定稿：只扩后端 + 云端沿用直连）：
//   · .local —— 走 NAS 后端 GET /api/weather（后端同步扩 daily 6 天，蜂窝下最稳）
//   · .cloud —— App 直连 Open-Meteo（geocode + current + daily），不经后端
//
// ⚠️ iconColor 的 case 顺序是**照搬原 WeatherBadge 的原顺序**（51...82 在 71...77 之前，
//    导致雪码取到 blue 而非 cyan）。这是既有的潜在小瑕疵，本次刻意不改 —— 保持"行为不变"，
//    要改另开一次（改了全站徽章雪天变色，属于观感变更）。

enum WeatherMode { case local, cloud }

/// 单日预报（后端 daily 与 Open-Meteo daily 的公共形态）
struct WeatherDay: Identifiable, Equatable {
    let date: String      // yyyy-MM-dd
    let code: Int?
    let max: Double?
    let min: Double?
    var id: String { date }
}

/// 一次天气查询的结果快照
struct WeatherSnapshot {
    var temp: Double?
    var code: Int?
    var city: String = ""
    /// 含今天（后端 forecast_days=6 → 今天 + 未来 5 天）
    var days: [WeatherDay] = []
    /// 未来 N 天（不含今天）—— 弹窗第 2 页
    var future: [WeatherDay] { Array(days.dropFirst()) }
    /// 今天（弹窗第 1 页的最高/最低）
    var today: WeatherDay? { days.first }
}

// MARK: - WMO 天气码映射（单一真源）

enum WeatherCode {
    /// WMO 码 → SF Symbol（照搬 WeatherBadge 原实现；85/86 阵雪补进 snow 一档）
    static func symbol(_ code: Int?) -> String {
        guard let c = code else { return "cloud.fill" }
        switch c {
        case 0: return "sun.max.fill"
        case 1: return "sun.min.fill"
        case 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...67: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    /// WMO 码 → 语义色（⚠️ case 顺序照搬原实现，见文件头说明）
    static func color(_ code: Int?) -> Color {
        guard let c = code else { return .secondary }
        switch c {
        case 0, 1: return .orange
        case 2: return .yellow
        case 3: return .secondary
        case 45, 48: return .gray
        case 51...82: return .blue
        case 71...77: return .cyan
        case 95...99: return .purple
        default: return .secondary
        }
    }

    /// WMO 码 → 中文描述（照搬原 LocalToolRunner.weatherText 映射）
    static func text(_ code: Int?) -> String {
        switch code ?? -1 {
        case 0: return "晴"
        case 1, 2: return "多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51, 53, 55, 56, 57: return "毛毛雨"
        case 61, 63, 65, 66, 67: return "雨"
        case 71, 73, 75, 77: return "雪"
        case 80, 81, 82: return "阵雨"
        case 85, 86: return "阵雪"
        case 95: return "雷暴"
        case 96, 99: return "雷暴+冰雹"
        default: return ""
        }
    }
}

// MARK: - 取数 + 解析 + 日期工具

enum WeatherService {
    // MARK: 云端直连（geocode → current + daily）

    /// 直连 Open-Meteo 取「当前 + 今天起 6 天」。
    /// 返回 (快照, 错误文案)；成功时错误文案为空串。
    static func fetchCloud(city: String) async -> (WeatherSnapshot?, String) {
        let c = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else {
            return (nil, "点右上角「换城市」设置天气城市")
        }
        // 1) 城市 → 坐标
        let enc = c.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? c
        guard let gURL = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(enc)&count=1&language=zh") else {
            return (nil, "城市名无效")
        }
        do {
            let (gData, _) = try await URLSession.shared.data(from: gURL)
            guard let gObj = try? JSONSerialization.jsonObject(with: gData) as? [String: Any],
                  let results = gObj["results"] as? [[String: Any]],
                  let first = results.first,
                  let lat = num(first["latitude"]),
                  let lon = num(first["longitude"]) else {
                return (nil, "未找到城市「\(c)」")
            }
            // 2) 当前 + 逐日（v3.9.25：current 参数替掉旧版 current_weather=，
            //    旧版不返回 weather_code 之外的字段，daily 也拿不到 → 5 天预报必需）
            let wstr = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
                + "&current=temperature_2m,weather_code"
                + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
                + "&timezone=Asia%2FShanghai&forecast_days=6"
            guard let wURL = URL(string: wstr) else { return (nil, "天气服务地址无效") }
            let (wData, _) = try await URLSession.shared.data(from: wURL)
            guard let wObj = try? JSONSerialization.jsonObject(with: wData) as? [String: Any] else {
                return (nil, "天气数据解析失败")
            }
            // 城市名用地理解析结果（中文名更友好）
            let name = (first["name"] as? String) ?? c
            let adm = (first["admin1"] as? String) ?? ""
            var snap = parseOpenMeteo(wObj, city: adm.isEmpty ? name : "\(name) · \(adm)")
            if snap.city.isEmpty { snap.city = c }
            return (snap, "")
        } catch {
            return (nil, "无法连接天气服务")
        }
    }

    // MARK: 解析

    /// 解析后端 GET /api/weather 的响应（老字段 temp/code/city 不变，新增 daily 数组）
    static func parseBackend(_ j: [String: Any]) -> WeatherSnapshot {
        var s = WeatherSnapshot()
        s.temp = num(j["temp"])
        s.code = int(j["code"])
        s.city = (j["city"] as? String) ?? ""
        s.days = parseDaily(j["daily"])
        return s
    }

    /// 解析 Open-Meteo 原始响应（current + daily）
    static func parseOpenMeteo(_ obj: [String: Any], city: String) -> WeatherSnapshot {
        var s = WeatherSnapshot()
        s.city = city
        let cur = obj["current"] as? [String: Any]
        s.temp = num(cur?["temperature_2m"])
        s.code = int(cur?["weather_code"])
        s.days = parseDaily(obj["daily"])
        return s
    }

    /// daily → [WeatherDay]。**两种形态都要吃**（缺列/长度不齐/脏数据都安全降级）：
    ///   ① 后端归一化形态（weather_api._daily 的输出，2026-09-15 线上实测）：
    ///      [{"date":"2026-09-15","code":3,"max":29.6,"min":22.5}, …]
    ///   ② Open-Meteo 原始列形态（云端直连）：{"time":[…],"weather_code":[…],…}
    /// ⚠️ 曾经只认 ②，那是真事故：本地模式走 ①，parseBackend 拿到数组 → guard 失败 →
    ///    days 恒空 → 第 2 页永远「暂无未来天气数据」。当时真值表绿，是因为用例 fixture
    ///    是照想象写的 ② 而没抓线上真实响应（教训见 qingliao-ios-native「真值表 fixture 必须实测抓包」）。
    static func parseDaily(_ any: Any?) -> [WeatherDay] {
        if let rows = any as? [[String: Any]] {
            return rows.compactMap { row in
                guard let d = row["date"] as? String, !d.isEmpty else { return nil }
                return WeatherDay(date: d,
                                  code: int(row["code"]),
                                  max: num(row["max"]),
                                  min: num(row["min"]))
            }
        }
        guard let d = any as? [String: Any] else { return [] }
        let dates = (d["time"] as? [String]) ?? []
        let codes = (d["weather_code"] as? [Any]) ?? []
        let maxs = (d["temperature_2m_max"] as? [Any]) ?? []
        let mins = (d["temperature_2m_min"] as? [Any]) ?? []
        var out: [WeatherDay] = []
        for (i, t) in dates.enumerated() {
            out.append(WeatherDay(date: t,
                                  code: i < codes.count ? int(codes[i]) : nil,
                                  max: i < maxs.count ? num(maxs[i]) : nil,
                                  min: i < mins.count ? num(mins[i]) : nil))
        }
        return out
    }

    // MARK: 数值兼容（JSON 里同一字段可能是 Int / Double / String）

    static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d.isFinite ? d : nil }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let s = v as? String, let d = Double(s) { return d.isFinite ? d : nil }
        return nil
    }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double {
            // ⚠️ Int(Double.nan) 与 Int(1e20) 都会直接 trap（不是返回 nil）——必须两道护栏。
            //    JSON 里的数字经 NSNumber → as? Double 会先命中这一支，所以护栏必须放在这里。
            guard d.isFinite, d > -9.0e15, d < 9.0e15 else { return nil }
            return Int(d.rounded())
        }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let i = Int(s) { return i }
        return nil
    }

    /// 显示用取整（温度）。Int(Double) 对 NaN/Inf/超范围是 **trap**，不是返回 nil；
    /// 温度是 Double?（不是 Any），走不了 int()，故单列一支，UI 侧一律用它。
    static func degInt(_ v: Double?) -> Int? {
        guard let v, v.isFinite, v > -9.0e15, v < 9.0e15 else { return nil }
        return Int(v.rounded())
    }

    // MARK: 日期（不用 DateFormatter —— Swift 6 严格并发下静态 DateFormatter 不可 Sendable）

    static func date(from str: String) -> Date? {
        let p = str.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        return Calendar.current.date(from: comps)
    }

    static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    static func weekdayText(_ d: Date) -> String {
        let i = Calendar.current.component(.weekday, from: d)   // 1 = 周日
        guard i >= 1, i <= 7 else { return "" }
        return weekdayNames[i - 1]
    }

    /// "9月15日"
    static func monthDayText(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    /// "9/16"
    static func slashText(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    /// 温度区间条几何：把 [lo, hi] 的当周区间映射到轨道宽度，返回 (起点, 宽度)。
    /// 护栏：hi == lo（全周同温）时给满宽，绝不除零。
    /// ⚠️ 参数名 min/max 会遮蔽全局函数 min/max —— 必须写 Swift.min / Swift.max，
    ///    否则「cannot call value of non-function type 'Double?'」（check_swift.sh 只做
    ///    -parse 语法检查，抓不到这个，只有 Xcode 全类型检查/CI 会挂）
    static func barGeometry(min: Double?, max: Double?, lo: Double, hi: Double, width: CGFloat) -> (x: CGFloat, w: CGFloat) {
        guard let mn = min, let mx = max else { return (0, 6) }
        let span = hi - lo
        guard span > 0.01 else { return (0, width) }
        let x0 = CGFloat((mn - lo) / span) * width
        let x1 = CGFloat((mx - lo) / span) * width
        let w = Swift.max(x1 - x0, 6)
        let x = Swift.min(Swift.max(Swift.min(x0, width - w), 0), Swift.max(width - w, 0))
        return (x, Swift.min(w, width))
    }
}
