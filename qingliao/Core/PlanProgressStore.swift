import Foundation

// MARK: - v3.9.74 P2.6：plan 卡步骤勾选进度（本地持久化）
//
// Muse 式目标拆解的落地面：AI 发 plan 卡后，用户在卡上点步骤勾选，进度本地留存；
// 「继续下一步」按钮按当前进度把下一个未完成步骤作为消息发回聊天（复用 sendCore 全链路）。
//
// 存储口径：按卡片稳定指纹（标题+全部步骤标题的 djb2）存「已完成步骤下标集合」——
// 卡片内容不变则指纹稳定，跨重启可恢复；AI 重新生成内容变化的卡 = 新进度，旧记录自然废弃。

// v3.9.74c（CI 修复）：无可变状态 + UserDefaults 本身线程安全 → @unchecked Sendable，
// 让 static let shared 过 Swift 6 严格并发检查（Archive 实测报 static property not concurrency-safe）
struct PlanProgressStore: @unchecked Sendable {
    static let shared = PlanProgressStore()
    private let defaults: UserDefaults
    private let keyPrefix = "qingliao_plan_progress_"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 卡片稳定指纹：标题 + 各步骤标题（内容变化 → 指纹变化 → 进度自动失效，防串卡）
    static func fingerprint(title: String, stepTitles: [String]) -> UInt64 {
        var h: UInt64 = 5381
        for b in title.utf8 { h = h &* 33 &+ UInt64(b) }
        for t in stepTitles {
            h = h &* 33 &+ UInt64(0x7C)   // 分隔符 '|'，防「AB+CD」与「A+BCD」同哈希
            for b in t.utf8 { h = h &* 33 &+ UInt64(b) }
        }
        return h
    }

    private func key(_ fp: UInt64) -> String { keyPrefix + String(fp) }

    func completedIndexes(for fp: UInt64) -> Set<Int> {
        Set(defaults.stringArray(forKey: key(fp))?.compactMap { Int($0) } ?? [])
    }

    func setCompleted(_ indexes: Set<Int>, for fp: UInt64) {
        let arr = indexes.map(String.init).sorted { ($0 as NSString).intValue < ($1 as NSString).intValue }
        defaults.set(arr, forKey: key(fp))
    }

    /// 下一个未完成步骤下标（无则 nil = 全部完成）
    func nextPendingIndex(stepCount: Int, fp: UInt64) -> Int? {
        let done = completedIndexes(for: fp)
        return (0..<stepCount).first { !done.contains($0) }
    }

    /// 进度文案：已勾选 n / 共 m 步
    static func progressText(done: Int, total: Int) -> String {
        "已完成 \(done)/\(total) 步"
    }
}
