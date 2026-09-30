// v4.0.x 上下文参数单一真源
//
// 为什么抽出来：压缩阈值此前散在 5 处（设置页 @AppStorage 默认值、发送路径兜底、
// ChatStore.needsCompress 默认参数、输入框使用率分母、浮动指示器分母），而且值并不一致
// （设置页 6000 vs 分母 4000 vs ChatStore 默认 8000）——同一屏里"阈值 6000 / 进度条按 4000 算"，
// 用户看到的使用率与实际压缩时机对不上。改一处漏另一处不会编译报错，只会静默漂移。
//
// 口径：
//   · **压缩阈值**（超过就触发 AI 摘要）= ContextTuning.threshold，读用户设置 + 兜底 defaultThreshold。
//   · **使用率分母**（发送键变色 / 浮动指示器）= 同一个 threshold，**不再另立一套数**
//     —— 使用率就是"离压缩还有多远"，两者必须是同一个数才有意义。
//   · 老设备升级后 UserDefaults 里还留着旧默认 4000，@AppStorage 只在键不存在时才用新默认，
//     所以读取时做一次"等于历史旧默认就当没设过"的一次性纠正（见 migrateIfLegacy）。
import Foundation

enum ContextTuning {
    /// UserDefaults 键（与设置页 @AppStorage 同名，改名要同步两处）
    static let thresholdKey = "qingliao_context_threshold"

    /// 新默认压缩阈值（v4.0.x 从 4000 上调到 6000）
    static let defaultThreshold = 6000

    /// 历史旧默认：老设备 UserDefaults 里存的就是它。读到它说明用户从没手动调过这档，
    /// 应当按新默认走；用户手动调过别的值则一律尊重用户选择。
    static let legacyThreshold = 4000

    /// 老设备一次性迁移：UserDefaults 里存着历史旧默认 4000 时说明用户从没手动调过这档，
    /// 按新默认改写。必须在**设置页渲染前**调（否则 AppStorage 仍显示 4000，与实际压缩口径不符）。
    /// 只改 legacyThreshold 这一个值；用户调过的其它值一律不碰。
    @discardableResult
    static func migrateIfNeeded() -> Bool {
        let raw = UserDefaults.standard.integer(forKey: thresholdKey)
        guard raw == legacyThreshold else { return false }
        UserDefaults.standard.set(defaultThreshold, forKey: thresholdKey)
        return true
    }

    /// 实际生效的压缩阈值：读用户设置，缺失/非法/等于历史旧默认时回落到新默认。
    /// 设置页的 @AppStorage 默认值也写 defaultThreshold，两边同源。
    static var threshold: Int {
        let raw = UserDefaults.standard.integer(forKey: thresholdKey)
        if raw <= 0 || raw == legacyThreshold { return defaultThreshold }
        return raw
    }
}
