import Foundation
import HealthKit

// MARK: - v4.0.60 iOS 健康数据接入（HealthKit，只读）
//
// 用途：用户问「我昨天睡得好吗 / 今天走了多少步 / 最近心率怎么样」时，AI 发 `health.query`，
//      这里把 HealthKit 的数据聚合成一段紧凑中文，显示在动作卡上。只读动作免确认。
//
// 🚨 侧载下的 entitlement 真相（2026-10-05 查证 + 双只读审查后重写，别再凭印象说「侧载一定不行」）：
//   HealthKit 需要 `com.apple.developer.healthkit` entitlement。**免费 Apple ID 侧载也能拿到**，
//   前提是 **IPA 里带着 ad-hoc entitlement 声明** —— SideStore/AltStore 重签时读 IPA 的
//   entitlements，据此给这个 App ID 开通对应能力（社区项目 NOOP 就是靠这个办法在免费账号下用
//   HealthKit，见其 docs/IOS.md 的「replaceable ad-hoc capability template」）。本仓因此多了两件
//   东西：`Config/Qingliao.entitlements`（只声明 healthkit）+ CI 打包前的 ad-hoc 签名步骤。
//
// 🚨 「没声明上」时**绝不能碰 HKHealthStore 的请求/查询 API**：缺 entitlement 时那几个调用抛的是
//   ObjC 异常（NSInvalidArgumentException），Swift 的 try/catch **抓不住**，直接闪退。所以：
//     ① 一切入口先过 `isAvailable`（= 设备支持健康 **且** 本安装真带 entitlement）；
//     ② 不可用就如实向上报「当前安装方式读不到健康数据」，一个 HealthKit 查询都不发；
//     ③ 只在用户点按钮 / AI 发动作时触发，App 启动路径不碰 HealthKit。
//
//   entitlement 怎么查：**读 App 包里的 embedded.mobileprovision**（见 hasHealthKitEntitlement）。
//   ⚠️ 别改回 `SecTaskCopyValueForEntitlement`：那两个符号只有 macOS / Mac Catalyst 的 SDK 有，
//   iOS SDK 里根本没有 SecTask.h —— 在 iOS 工程里写它就是**编译错误**（v4.0.60 首版真踩过）。
//
// 🚨 「读授权」不能拿 authorizationStatus(for:) 当判据（v4.0.60 首版真踩过）：Apple 文档写明它查的是
//   **写（sharing）**授权，三态全叫 sharingXxx；本 App `toShare: []` 从没请求过写 → 恒 `.notDetermined`
//   → 用户授权了也永远判成「未授权」，功能静默失效。HealthKit 出于隐私**不回传读权限**（读被拒时查询
//   只返回空）。所以本类改成「以真读到的数据为准」：requestAccess 后跑一次探针（近 7 天任一类型有样本
//   = 读通了）记在本地；summary 真读到数据时也自动补记（用户去系统设置开权限的场景自愈）。
//
// ⚠️ Swift 6 并发口径（别改回直接捕获 HKUnit）：query 回调是 nonisolated 的，只允许捕获 Sendable 值 ——
//   所以下面一律「传枚举、回调里现造 HKUnit」，回调只把 Double / 元组 resume 回去；`store.execute(q)`
//   一律留在闭包**外**（闭包别捕获 MainActor 属性）。
//   另：`hasHealthKitEntitlement` / `isAvailable` 必须 `nonisolated` —— 它们被 nonisolated 的
//   `AppCapability.aiControllable` 同步读（写成 MainActor 隔离 = Swift 6 编译错误，首版真踩过）。

/// 查询要用的单位口径（Sendable 枚举，代替直接捕获 HKUnit）
private enum HealthUnitKind: Sendable {
    case count, kilometer, kilocalorie, perMinute
}

private func healthUnit(_ kind: HealthUnitKind) -> HKUnit {
    switch kind {
    case .count:       return .count()
    case .kilometer:   return .meterUnit(with: .kilo)
    case .kilocalorie: return .kilocalorie()
    case .perMinute:   return HKUnit.count().unitDivided(by: .minute())
    }
}

/// 睡眠样本里算「睡着了」的那些类型（iOS 16+ 的四档）
private let healthAsleepValues: Set<Int> = [
    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
]

/// 运动类型 → 中文名（回调里要调，必须是 nonisolated 的全局函数）
private func healthWorkoutName(_ t: HKWorkoutActivityType) -> String {
    switch t {
    case .running:            return "跑步"
    case .walking:            return "步行"
    case .cycling:            return "骑行"
    case .swimming:           return "游泳"
    case .hiking:             return "徒步"
    case .yoga:               return "瑜伽"
    case .functionalStrengthTraining, .traditionalStrengthTraining: return "力量训练"
    case .highIntensityIntervalTraining: return "HIIT"
    case .elliptical:         return "椭圆机"
    case .rowing:             return "划船"
    case .stairClimbing, .stairs: return "爬楼"
    case .jumpRope:           return "跳绳"
    case .badminton:          return "羽毛球"
    case .basketball:         return "篮球"
    case .soccer:             return "足球"
    case .tableTennis:        return "乒乓球"
    case .tennis:             return "网球"
    default:                  return "运动"
    }
}

@MainActor
final class HealthStore {
    static let shared = HealthStore()
    private let store = HKHealthStore()
    private init() {}

    // MARK: - 闸门（碰 HealthKit 之前的唯一入口）

    /// 本安装是否真带 HealthKit entitlement。
    /// 做法：读 App 包里的 `embedded.mobileprovision`（真机/侧载安装都有），从 CMS 包裹里截出 plist 段，
    /// 看 Entitlements 里有没有 com.apple.developer.healthkit —— 纯 Foundation 公开 API，无私有符号。
    /// 必须 `nonisolated`：被 nonisolated 的 AppCapability.aiControllable 同步读。
    nonisolated static let hasHealthKitEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let text = String(data: raw, encoding: .isoLatin1),
              let head = text.range(of: "<?xml"),
              let tail = text.range(of: "</plist>"),
              head.lowerBound < tail.lowerBound,
              let plistData = String(text[head.lowerBound..<tail.upperBound]).data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let ents = plist["Entitlements"] as? [String: Any]
        else { return false }
        return ents["com.apple.developer.healthkit"] != nil
    }()

    /// 能用 = 这台设备支持健康数据 **且** 本安装真带 entitlement（缺了碰了会闪退，见文件头）
    nonisolated static var isAvailable: Bool {
        hasHealthKitEntitlement && HKHealthStore.isHealthDataAvailable()
    }

    /// 「读」通了没。HealthKit 不回传读权限，只能靠「真读到过数据」自证（见文件头）。
    private static let probeKey = "qingliao_health_read_ok_v1"
    private static var readProbePassed: Bool {
        get { UserDefaults.standard.bool(forKey: probeKey) }
        set { UserDefaults.standard.set(newValue, forKey: probeKey) }
    }

    /// 读授权态（只三态：不可用 / 读通了 / 还没读通）。给权限页与动作卡看。
    var authorizationState: PermissionState {
        guard Self.isAvailable else { return .unavailable }
        return Self.readProbePassed ? .granted : .notDetermined
    }

    /// 弹系统健康授权框。**不可用时直接 false，绝不调用 requestAuthorization**（会闪退，见文件头）。
    /// 返回 true = 请求走完 **且探针读到数据**（= 读授权真生效）。
    func requestAccess() async -> Bool {
        guard Self.isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes)
        } catch {
            NSLog("[HEALTH] requestAuthorization failed: \(error)")
            return false
        }
        let ok = await probeAnySample()
        Self.readProbePassed = ok
        return ok
    }

    // MARK: - 读取类型（只读；绝不写健康数据）

    private static var readTypes: Set<HKObjectType> {
        [
            HKQuantityType(.stepCount),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.heartRate),
            HKQuantityType(.restingHeartRate),
            HKCategoryType(.sleepAnalysis),
            HKObjectType.workoutType(),
        ]
    }

    /// 探针用的四类（正常 iPhone 用户近 7 天至少命中其一）
    private static var probeTypes: [HKObjectType] {
        [HKQuantityType(.stepCount), HKQuantityType(.heartRate),
         HKCategoryType(.sleepAnalysis), HKObjectType.workoutType()]
    }

    /// 近 7 天里任一类能读到样本 → 读授权确实生效
    private func probeAnySample() async -> Bool {
        let end = Date()
        let start = end.addingTimeInterval(-7 * 86400)
        for t in Self.probeTypes {
            let hit: Bool = await withCheckedContinuation { cont in
                let q = HKSampleQuery(sampleType: t,
                                      predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []),
                                      limit: 1,
                                      sortDescriptors: nil) { _, samples, _ in
                    cont.resume(returning: !(samples ?? []).isEmpty)
                }
                store.execute(q)
            }
            if hit { return true }
        }
        return false
    }

    // MARK: - 汇总（给 AI 也给你看的一段中文）

    /// 最近 N 天（含今天）健康摘要。返回 nil = **一条都没读到**（不可用 / 没授权 / 确实没记录）
    func summary(days rawDays: Int, metric: String?) async -> String? {
        guard Self.isAvailable else { return nil }
        let days = max(1, min(rawDays, 7))
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: now))
            ?? now.addingTimeInterval(-86400)

        // 不认识的 metric 一律按「全部」处理 —— 别把「参数写错」当成「没数据」回给用户（2026-10-05 审查）
        let raw = (metric ?? "all").lowercased()
        let known = ["all", "steps", "activity", "heart", "hr", "sleep", "workout", "workouts", "sport"]
        let want = known.contains(raw) ? raw : "all"

        var lines: [String] = []

        if want == "all" || want == "steps" || want == "activity" {
            if let steps = await sum(.stepCount, kind: .count, from: start, to: now) {
                var seg = "步数 \(Int(steps.rounded())) 步"
                if let km = await sum(.distanceWalkingRunning, kind: .kilometer, from: start, to: now) {
                    seg += "、步行+跑步 \(String(format: "%.1f", km)) km"
                }
                if let kcal = await sum(.activeEnergyBurned, kind: .kilocalorie, from: start, to: now) {
                    seg += "、活动能量 \(Int(kcal.rounded())) kcal"
                }
                lines.append("· " + seg)
            }
        }
        if want == "all" || want == "heart" || want == "hr" {
            if let hr = await stats(.heartRate, kind: .perMinute, from: start, to: now) {
                var seg = "心率 平均 \(Int(hr.avg.rounded()))、最低 \(Int(hr.min.rounded()))、最高 \(Int(hr.max.rounded())) 次/分"
                if let rhr = await stats(.restingHeartRate, kind: .perMinute, from: start, to: now) {
                    seg += "（静息 \(Int(rhr.avg.rounded()))）"
                }
                lines.append("· " + seg)
            }
        }
        if want == "all" || want == "sleep" {
            if let hours = await sleepHours(from: start, to: now), hours > 0.05 {
                lines.append("· 睡眠 \(Self.hoursText(hours))")
            }
        }
        if want == "all" || want == "workout" || want == "workouts" || want == "sport" {
            let list = await workouts(from: start, to: now)
            if !list.isEmpty {
                let top = list.prefix(3)
                    .map { "\($0.name) \(Int($0.minutes.rounded())) 分钟" }
                    .joined(separator: "、")
                lines.append("· 运动 \(list.count) 次：\(top)")
            }
        }

        guard !lines.isEmpty else { return nil }     // 一条都没读到 → 交给上层照实说，别自己编
        Self.readProbePassed = true                  // 真读到数据 = 读授权确实生效（用户去系统设置开权限的自愈路径）
        let title = days == 1 ? "近 24 小时" : "最近 \(days) 天"
        let head = "【健康数据 · \(title)】\(Self.dayText(start)) ~ \(Self.dayText(now))"
        return ([head] + lines).joined(separator: "\n")
    }

    // MARK: - 查询实现（回调里只带 Sendable 值回来；execute 一律在闭包外）

    private func quantityValues(_ id: HKQuantityTypeIdentifier,
                                kind: HealthUnitKind,
                                from: Date, to: Date,
                                _ done: @escaping @Sendable ([Double]) -> Void) {
        let q = HKSampleQuery(sampleType: HKQuantityType(id),
                              predicate: HKQuery.predicateForSamples(withStart: from, end: to, options: []),
                              limit: HKObjectQueryNoLimit,
                              sortDescriptors: nil) { _, samples, _ in
            let unit = healthUnit(kind)
            let vals = (samples as? [HKQuantitySample])?.map { $0.quantity.doubleValue(for: unit) } ?? []
            done(vals)
        }
        store.execute(q)
    }

    private func sum(_ id: HKQuantityTypeIdentifier, kind: HealthUnitKind, from: Date, to: Date) async -> Double? {
        await withCheckedContinuation { cont in
            quantityValues(id, kind: kind, from: from, to: to) { vals in
                cont.resume(returning: vals.isEmpty ? nil : vals.reduce(0, +))
            }
        }
    }

    private func stats(_ id: HKQuantityTypeIdentifier, kind: HealthUnitKind, from: Date, to: Date) async -> (avg: Double, min: Double, max: Double)? {
        await withCheckedContinuation { cont in
            quantityValues(id, kind: kind, from: from, to: to) { vals in
                guard !vals.isEmpty else { cont.resume(returning: nil); return }
                cont.resume(returning: (vals.reduce(0, +) / Double(vals.count), vals.min() ?? 0, vals.max() ?? 0))
            }
        }
    }

    private func sleepHours(from: Date, to: Date) async -> Double? {
        await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis),
                                  predicate: HKQuery.predicateForSamples(withStart: from, end: to, options: []),
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, _ in
                let cats = (samples as? [HKCategorySample]) ?? []
                let seconds = cats.reduce(0.0) { acc, s in
                    guard healthAsleepValues.contains(s.value) else { return acc }
                    return acc + s.endDate.timeIntervalSince(s.startDate)
                }
                cont.resume(returning: seconds > 0 ? seconds / 3600 : nil)
            }
            store.execute(q)
        }
    }

    private func workouts(from: Date, to: Date) async -> [(name: String, minutes: Double, kcal: Double)] {
        await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(),
                                  predicate: HKQuery.predicateForSamples(withStart: from, end: to, options: []),
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, _ in
                var list: [(name: String, minutes: Double, kcal: Double)] = []
                for w in (samples as? [HKWorkout]) ?? [] {
                    let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?
                        .sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                    list.append((healthWorkoutName(w.workoutActivityType), w.duration / 60, kcal))
                }
                cont.resume(returning: list)
            }
            store.execute(q)
        }
    }

    // MARK: - 文案

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    private static func dayText(_ d: Date) -> String { dayFormatter.string(from: d) }

    private static func hoursText(_ h: Double) -> String {
        let total = Int((h * 60).rounded())
        return "\(total / 60) 小时 \(total % 60) 分"
    }
}
