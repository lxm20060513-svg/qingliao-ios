import Foundation

/// v4.0.104 待做池 #11：**剪贴板历史**（本地回看 / 一键入待办 / 首页剪贴板卡顺手入库）。
///
/// ⚠️ 能力边界（本功能的设计前提，别绕）：
///   iOS **禁止**后台监听剪贴板；程序化读 `UIPasteboard.general.string` 会弹系统「允许粘贴」提示。
///   所以本仓既有口径（见 `Features/HomeCards.swift` 剪贴板卡注释）必须沿用：
///   **只在用户主动动作的那一刻读，绝不轮询、绝不在 body/渲染期读**。
///   本 Store 自己**不碰 UIPasteboard** —— 它只负责「把调用方主动读到的那段文本存下来」。
///   读剪贴板的只有两处用户动作：首页剪贴板卡 `tapClipboard()`、设置页 sheet 的「读取当前剪贴板」。
///
/// ⚠️ 单一真源：唯一持久化键 = `UserDefaultsKey.clipboardHistory`（Core/Models.swift）；
///   开关键 = `UserDefaultsKey.clipboardHistoryEnabled`（同样进 UserDefaultsKey，默认开）。
///   唯一写入口 = 本类型。视图里不许自己拼键名、不许自己写 UserDefaults。
@MainActor
final class ClipboardHistoryStore {
    static let shared = ClipboardHistoryStore()

    /// 最多保留多少条历史（超出按时间戳淘汰最旧）。
    /// internal 常量（非 private）：真值表要能逐字读它 + 行为表直接引用，避免两处各写一个 100。
    static let maxEntries = 100

    /// 单条记录正文的最大长度。> 此长度的内容一律拒收（调用方提示「太长不记录」）。
    /// 上限存在的原因：剪贴板里可能躺着一整本书 / 一坨 base64，逐字塞进 UserDefaults 会把首页
    /// 之后的每次读写都拖慢（与 ChatDraftStore 的容量取舍同源）。
    static let maxLength = 2000

    struct Entry: Identifiable, Equatable, Sendable {
        let id: String
        var text: String
        /// 最后写入时刻（unix 秒）。去重命中时会被刷新为「现在」→ 置顶。
        var at: Double
        var source: String
    }

    private let defaults: UserDefaults
    /// 内存镜像，恒按 `at` 倒序（最新在前）。
    private var entries: [Entry]

    /// 为可测性暴露注入（照 ChatDraftStore 的做法：默认 `.standard`）。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = Self.load(from: defaults)
    }

    // MARK: - 开关

    /// 剪贴板历史总开关（默认开）。关掉后 `record` 一律不入库（既不入档返回 nil）。
    var isEnabled: Bool {
        get { defaults.object(forKey: UserDefaultsKey.clipboardHistoryEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: UserDefaultsKey.clipboardHistoryEnabled) }
    }

    // MARK: - 读

    /// 全部记录，按时间倒序（最新在前）。
    var allEntries: [Entry] { entries }

    var count: Int { entries.count }

    // MARK: - 写

    /// 唯一写入口。
    ///
    /// 收纳规则（顺序即判定顺序）：
    ///   ① 开关关 → nil（不动库）
    ///   ② trim 空白后为空 → nil
    ///   ③ 长度 > `maxLength`(2000) → nil（调用方据此提示「太长不记录」）
    ///   ④ 正文**完全相同** → 不新增，只把该条 `at` 刷成现在并置顶（返回该条）
    ///   ⑤ 否则新增一条
    /// 之后按容量淘汰最旧并落盘。
    @discardableResult
    func record(_ text: String, source: String) -> Entry? {
        guard isEnabled else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= Self.maxLength else { return nil }

        let now = Date().timeIntervalSince1970
        var result: Entry
        if let idx = entries.firstIndex(where: { $0.text == trimmed }) {
            // 命中已有同文条目：只刷新时间戳并置顶，**source 保持首次来源不刷新**
            // （有意为之：来源记录「它第一次是从哪来的」，反复复制粘贴不该把它改写）。
            entries[idx].at = now
            result = entries[idx]
        } else {
            let e = Entry(id: UUID().uuidString, text: trimmed, at: now, source: source)
            entries.append(e)
            result = e
        }
        evictIfNeeded()
        sortAndPersist()
        return result
    }

    /// 删单条。找不到该 id → 返回 false（不崩、不静默当成功）。
    @discardableResult
    func remove(id: String) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: idx)
        persist()
        return true
    }

    /// 清空全部。
    func clearAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        persist()
    }

    // MARK: - 内部

    /// 容量兜底：超出上限时按时间戳保留最近 `maxEntries` 条。
    private func evictIfNeeded() {
        guard entries.count > Self.maxEntries else { return }
        entries = Array(entries.sorted { $0.at > $1.at }.prefix(Self.maxEntries))
    }

    private func sortAndPersist() {
        entries.sort { $0.at > $1.at }
        persist()
    }

    /// 落盘。值 = **数组的数组**，每条 = `[正文, 时间戳, 来源, id]`。
    /// ⚠️ 绝不用嵌套字典（`as? [String: Any]`）：Linux（swift-corelibs-foundation）读回嵌套字典是
    /// `[AnyHashable: Any]`，类型转换必失败 —— 本仓 ChatDraftStore 注释里就是踩过这个坑，
    /// 而本项真值表要在 Linux 上真跑，所以格式必须是两端都能解的「数组 + 下标」。
    private func persist() {
        defaults.set(entries.map { [$0.text, $0.at, $0.source, $0.id] },
                     forKey: UserDefaultsKey.clipboardHistory)
    }

    /// 读盘。容错：单条结构不对（不是长度 4 的数组 / 正文不是字符串）**只跳过那条**，
    /// 不整表丢弃 —— 宁可少一条历史，也不要整份解不出来。
    private static func load(from defaults: UserDefaults) -> [Entry] {
        guard let raw = defaults.array(forKey: UserDefaultsKey.clipboardHistory) else { return [] }
        var out: [Entry] = []
        for value in raw {
            guard let arr = value as? [Any], arr.count == 4,
                  let text = arr[0] as? String,
                  let source = arr[2] as? String,
                  let id = arr[3] as? String else { continue }
            let at = (arr[1] as? Double) ?? (arr[1] as? NSNumber)?.doubleValue ?? 0
            out.append(Entry(id: id, text: text, at: at, source: source))
        }
        return out.sorted { $0.at > $1.at }
    }
}
