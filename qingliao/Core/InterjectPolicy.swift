import Foundation

/// v4.1.x（插话暂停-恢复）：App 侧插话判定的**单一真源**。
///
/// 为什么收成一个 enum：这些判据原本会散在「⚡键能不能点」「发送时再核一遍」「起流失败要不要
/// 退排队」「状态行写什么」四处，各写一份迟早漂移（本仓 v3.9.41 的 `thisSessionStreaming`、
/// v4.0.96 的 `ResumeInfo.canResume` 都为同一原因收过口）。真值表只钉这一份，改口径只改这里。
///
/// 与后端契约的对应（`/api/stream/interject`）：
///   · 只能插**本会话**正在跑的那条流 —— 别的会话在跑时，⚡键根本不出现（宿主按会话收窄）；
///   · 插话请求失败（老后端 404 / 开关关 501 / 父流状态不允许 400 / 网络）→ 静默退排队老路，
///     不落错误气泡（用户点的是一次抢占，不是一次提问）；
///   · 状态行只写**本机确知**的事（父流 id 是 App 自己写下的），不写「已接续」这类拿不到
///     可靠信号的服务端异步结论。
enum InterjectPolicy {

    /// 能不能走插话（⚡键出现条件 + 发送时再核一遍，两处同源）。
    ///
    /// - 必须真的在跑流：没跑就没有可暂停的父流，直接走普通发送。
    /// - 必须有 taskId：无主流（异常态）暂停不了，硬发只会换来一个 400。
    /// - 必须是**本会话**的流：单例只有一条流，插别的会话那条 = 掐掉别人正在等的回答。
    /// - **不能已有父流在等服务端接回**（v4.0.115 审查 P1）：后端暂停栈只有 1 层，二次插话会用
    ///   新子流顶掉上一条接回信息 → 第一个被挂起的父流永远接不回来（那截已生成的正文丢失）。
    static func canInterject(isStreaming: Bool, taskId: String,
                             streamSessionId: String, currentSessionId: String,
                             pausePending: Bool) -> Bool {
        guard isStreaming else { return false }
        guard !pausePending else { return false }
        guard !taskId.isEmpty else { return false }
        guard !streamSessionId.isEmpty, !currentSessionId.isEmpty else { return false }
        return streamSessionId == currentSessionId
    }

    /// 起流失败后要不要静默退排队（而不是像普通失败那样落一个错误气泡）。
    ///
    /// `started` 一律传「这条流到底有没有拿到 taskId」——不是猜的，是 `StreamClient.start()`
    /// 复位时清空、拿到 id 才写入的那个真值。
    static func shouldFallbackToQueue(isInterject: Bool, started: Bool) -> Bool {
        isInterject && !started
    }

    /// 输入框上方的插话状态行文案（空串 = 不显示该行）。
    static func note(streaming: Bool, pausedParentTaskId: String, pausedParentStep: Int) -> String {
        guard streaming, !pausedParentTaskId.isEmpty else { return "" }
        return pausedParentStep > 0
            ? "原回答已暂停（已完成 \(pausedParentStep) 步）· 插话中"
            : "原回答已暂停 · 插话中"
    }

    /// ⚡键可点判据：有实打实的文字（纯空白不算 —— 插话总得有话说）。
    static func canTapBolt(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
