import Foundation

/// v4.0.103 待做池 #5：聊天输入框**草稿持久化**（按会话记，切会话 / 杀后台回来都还在）。
///
/// 缺口来源（2026-10-13 实测）：`ChatView.inputText` 是纯 `@State`，全仓无任何
/// `UserDefaults` / `AppStorage` 读写 —— 切走再回来、或 App 被系统回收，输入框里
/// 打了一半的字全没了（对照微信：切会话各自的草稿都还在）。
///
/// 口径（用户拍板）：
///   ① **按会话记**：键 = `chat.sessionId`。切走时存自己那份，切回时原样取回。
///   ② **发送成功才清**：只有「确认发送」那一刻清（含长上下文弹窗 / 自动压缩之后那次发送）。
///      弹窗点「取消」保留草稿 —— 这是 v2.0.102 已修的行为，**不许回退**。
///   ③ **只落本地**：不进后端、不进会话快照（草稿是设备上的半成品，不是会话内容）。
///
/// ⚠️ 单一真源：唯一持久化键 = `UserDefaultsKey.chatDrafts`（Core/Models.swift）；
/// 唯一写入口 = 本类型。视图里不许自己拼键名、不许自己写 UserDefaults。
/// ⚠️ 容量：一份草稿一个键，上限 `maxSessions` 份，超出按**最后写入时刻**丢最旧 ——
/// 否则「聊过几百个会话」会变成几百条常驻 UserDefaults。
@MainActor
final class ChatDraftStore {
    static let shared = ChatDraftStore()

    /// 最多保留多少份会话草稿（超出丢最旧的）
    static let maxSessions = 50

    /// 生产用的落盘节流窗口（秒）。单独提成常量是为了：① 出厂口径在真值表里可被逐字钉住
    /// ② 行为表可以注入一个**很长**的窗口，把「没 flush 就不落盘」变成确定性事实，
    ///    而不是「0.4s 内主线程别被饿置」的赌注（CI 负载重时会假红）。
    /// ⚠️ 刻意取舍：窗口内被**强杀**（不是退到后台）会丢最后 0.4s 的输入；每键写盘的收益（省 0.4s 的字）
    ///    远小于代价（粘贴长文本时主线程反复序列化整表 + 全量 set）。「不丢」由 `flush()` 的两个时机点兜底
    ///    （离开前台 / 切会话）。**这是唯一的窗口真源 —— 别再声明第二个同名常量（曾因此出现双真源）。**
    nonisolated static let defaultCoalesceWindow: TimeInterval = 0.4

    private struct Entry {
        var text: String
        var at: Double      // 最后写入时刻（unix 秒）；只服务容量淘汰，不对外
    }

    private let defaults: UserDefaults
    private let coalesceWindow: TimeInterval
    private var entries: [String: Entry]

    /// 内存镜像相对盘上是否有未落盘的改动（脏标记）。
    /// 为什么需要：`scenePhase` 走 active→inactive→background 会**连续两次**触发 flush，
    /// 没有脏标记就是每次退后台白做两次「整表重建 + 整键写盘」（内容一模一样）。
    private var needsPersist = false

    init(defaults: UserDefaults = .standard, coalesceWindow: TimeInterval = ChatDraftStore.defaultCoalesceWindow) {
        self.defaults = defaults
        self.coalesceWindow = coalesceWindow
        self.entries = Self.load(from: defaults)
    }

    // MARK: - 读

    /// 取某会话的草稿；没有 → 空串。
    /// 空 sid 一律空串：还没有会话身份时不该造出 `"": "…"` 这种键（也就会在切会话时被误当一份独立草稿）。
    func draft(for sid: String) -> String {
        guard !sid.isEmpty else { return "" }
        return entries[sid]?.text ?? ""
    }

    // MARK: - 写

    /// 写入草稿。键盘每敲一下都会走这里 → **值没变整段跳过**（省掉一次字典序列化 + 写盘）。
    /// 传空串 = 删除该会话的草稿（不堆 `sid: ""` 空条目）。
    func set(_ text: String, for sid: String) {
        guard !sid.isEmpty else { return }
        if text.isEmpty {
            guard entries.removeValue(forKey: sid) != nil else { return }
        } else {
            guard entries[sid]?.text != text else { return }
            entries[sid] = Entry(text: text, at: Date().timeIntervalSince1970)
        }
        needsPersist = true
        evictIfNeeded()
        // 空串 = 用户把输入框清干净了（发送之外的明确语义点）→ 立即落盘，与 clear() 同口径；
        // 正常输入才走节流。
        if text.isEmpty { flush() } else { scheduleFlush() }
    }

    /// 清某会话的草稿（发送成功 / 用户把输入框清干净时调用）。
    /// 清空是明确语义点（用户刚点了发送）→ **立即落盘**，不等节流窗口：
    /// 否则「发完立刻被杀」会把已清掉的草稿又写回去，草稿复活。
    func clear(for sid: String) {
        guard !sid.isEmpty, entries.removeValue(forKey: sid) != nil else { return }
        needsPersist = true
        flush()
    }

    /// 立即落盘：取消未触发的节流写入，再把内存镜像整个写下去（**没脏就直接返回**）。
    /// 必须调用的两个时机（其余交给节流窗口）：
    ///   ① 离开前台（inactive / background）—— 系统随时可能回收进程
    ///   ② 切会话 —— 刚离开那个会话的正文要马上落地
    /// （原先还写了「③ 视图消失」，但全仓并没有接这个点；不接线就别在注释里承诺——
    ///   切 Tab 时 store 是单例、挂起的节流任务照样会落盘，没有丢数据风险，真值表按 2 处钉。）
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard needsPersist else { return }
        persist()
    }

    // MARK: - 内部

    /// 容量兜底：超出上限时按最后写入时刻保留最近 `maxSessions` 份。
    private var flushTask: Task<Void, Never>?

    private func scheduleFlush() {
        flushTask?.cancel()
        // 先把窗口取成局部值：闭包里 self 是 optional（weak），直接读实例属性要写 self?.
        let window = coalesceWindow
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func evictIfNeeded() {
        guard entries.count > Self.maxSessions else { return }
        let keep = Set(entries.sorted { $0.value.at > $1.value.at }
            .prefix(Self.maxSessions)
            .map(\.key))
        entries = entries.filter { keep.contains($0.key) }
    }

    private func persist() {
        // 值用**数组**而不是嵌套字典：嵌套字典读回来在 Linux（swift-corelibs-foundation）是
        // `[AnyHashable: Any]`，`as? [String: Any]` 会失败（实测），而本项真值表要在 Linux 上真跑
        // —— 不能写成「只有 iOS 能解」的形态。数组在 iOS/ Linux 两端都稳。
        defaults.set(entries.mapValues { [$0.text, $0.at] }, forKey: UserDefaultsKey.chatDrafts)
        needsPersist = false
    }

    /// 读盘：单键存全部草稿（值 = `[正文, 最后写入时刻]`）。
    /// 容错读取 —— 单条结构不对就跳过那条（宁可少一份草稿，也不要整个字典解不出来）。
    private static func load(from defaults: UserDefaults) -> [String: Entry] {
        guard let raw = defaults.dictionary(forKey: UserDefaultsKey.chatDrafts) else { return [:] }
        var out: [String: Entry] = [:]
        for (sid, value) in raw {
            guard !sid.isEmpty, let arr = value as? [Any], arr.count == 2,
                  let text = arr[0] as? String else { continue }
            let at = (arr[1] as? Double) ?? (arr[1] as? NSNumber)?.doubleValue ?? 0
            out[sid] = Entry(text: text, at: at)
        }
        return out
    }
}
