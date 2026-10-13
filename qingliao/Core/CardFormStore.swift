import Foundation

// MARK: - v4.0.104（#25）：可交互表单卡的「提交回执」本地持久化
//
// 口径（改动务必保持）：
//   ① 指纹 = 卡片标题 + 全部字段 key 的 djb2（与 PlanProgressStore 同算法）；卡片内容变化 → 指纹变化
//      → 旧记录自然失效，不会串卡；
//   ② 记录内容 = 用户提交的字段值 + 合成文本摘要 + 时刻 —— 重进会话时卡片直接显示「已提交」，
//      输入控件不再出现 ⇒ **重复提交天然幂等**（同一张卡不会被提交两次）；
//   ③ 只落本地 UserDefaults，**不进后端、不进会话快照**（后端零改动）；视图不许自己读写 UserDefaults，
//      一切经本 Store（唯一写入口）；
//   ④ 记录有上限（maxRecords，超限淘汰最旧），否则聊过的表单卡会在 UserDefaults 里永久堆积。
//
// v4.0.104：无可变状态 + UserDefaults 线程安全 → @unchecked Sendable（同 PlanProgressStore 的 CI 修复口径）。

struct CardFormStore: @unchecked Sendable {

    static let shared = CardFormStore()

    /// 最多保留多少张卡的提交记录（超出淘汰最旧）
    static let maxRecords = 60

    private let defaults: UserDefaults
    /// 单键前缀：一张卡一条键（与 PlanProgressStore 的 keyPrefix 口径一致）
    private let keyPrefix = "qingliao_card_form_"
    /// 索引键：记录最近提交过的指纹（用于容量淘汰）
    private let indexKey = "qingliao_card_form_index"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    struct Submission: Equatable, Sendable {
        /// 用户填的字段值（key 为字段 key）
        let values: [String: String]
        /// 合成回传文本（同一份内容落盘，重进会话展示「已提交」摘要用）
        let summary: String
        let at: Date

        init(values: [String: String], summary: String, at: Date = Date()) {
            self.values = values
            self.summary = summary
            self.at = at
        }
    }

    /// 卡片稳定指纹：**消息种子 + 标题 + 内容签名**（djb2，分隔符防拼接碰撞）。
    ///
    /// ⚠️ 为什么不是「标题 + 字段 key」就够（审查实测 fpA == fpB 的口径事故）：
    ///   标题与 key 集合一致的两张卡（跨会话同题卡 / 同会话两张同类卡）会被判成同一张
    ///   → 第二张一进去就显示「已提交」、输入框永不出现。故必须并入：
    ///     · seed：消息维度（视图传所属消息 id）—— 不同消息天然不同卡；
    ///     · signature：form 内容签名（字段 label/单位/选项/默认值/模板）—— 同消息重出不同卡也分得开。
    static func fingerprint(seed: String, title: String, signature: String) -> UInt64 {
        var h: UInt64 = 5381
        for s in [seed, title, signature] {
            h = h &* 33 &+ UInt64(0x7C)   // '|'
            for b in s.utf8 { h = h &* 33 &+ UInt64(b) }
        }
        return h
    }

    /// 展示用文案：已提交 · HH:mm
    static func submittedText(_ at: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return "已提交 · " + f.string(from: at)
    }

    private func key(_ fp: UInt64) -> String { keyPrefix + String(fp) }

    // MARK: 读写

    func submission(for fp: UInt64) -> Submission? {
        guard let json = defaults.string(forKey: key(fp)),
              let data = json.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return Submission(values: stored.values,
                          summary: stored.summary,
                          at: Date(timeIntervalSince1970: stored.at))
    }

    func record(_ submission: Submission, for fp: UInt64) {
        let stored = Stored(values: submission.values,
                            summary: submission.summary,
                            at: submission.at.timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(stored),
           let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: key(fp))
        }
        touchIndex(fp)
    }

    func clear(for fp: UInt64) {
        defaults.removeObject(forKey: key(fp))
        var idx = index()
        idx.removeAll { $0 == fp }
        defaults.set(idx.map(String.init), forKey: indexKey)
    }

    /// 一键清空（隐私口径）。⚠️ 目前**没有**设置页入口：用户自救路径是每张卡回执行的「重填」
    /// （只清这一张）；本方法留给测试与将来的「数据与文件 → 清理」入口用，别当成已有 UI 能力。
    func clearAll() {
        for fp in index() { defaults.removeObject(forKey: key(fp)) }
        defaults.removeObject(forKey: indexKey)
    }

    // MARK: 容量

    /// 最近提交过的指纹（新的在前）
    func index() -> [UInt64] {
        (defaults.stringArray(forKey: indexKey) ?? []).compactMap { UInt64($0) }
    }

    /// 把指纹挪到最前并淘汰超限的最旧记录
    private func touchIndex(_ fp: UInt64) {
        var idx = index()
        idx.removeAll { $0 == fp }
        idx.insert(fp, at: 0)
        if idx.count > Self.maxRecords {
            for old in idx[Self.maxRecords...] { defaults.removeObject(forKey: key(old)) }
            idx = Array(idx.prefix(Self.maxRecords))
        }
        defaults.set(idx.map(String.init), forKey: indexKey)
    }

    /// 落盘结构（JSON 字符串存取：Linux corelibs 下嵌套字典经 JSONSerialization 读回是
    /// [AnyHashable: Any]，`as? [String: Any]` 必失败 ⇒ 一律走 Codable，别用 JSONSerialization）
    private struct Stored: Codable {
        let values: [String: String]
        let summary: String
        let at: TimeInterval
    }
}
