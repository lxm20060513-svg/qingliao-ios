import Foundation

// MARK: - v3.9.76 语音对话轮次状态机
//
// 用户要的「语音对话」= 语音输入之外的**闭环**：说 → 自动发 → AI 回 → 自动念 → 自动续听。
// 本文件只管**轮次推进的判断**，不碰麦克风、不碰网络、不碰 UI —— 纯 Foundation，
// 所以能在没有 iOS SDK 的本机用 scripts/test_voice_dialog.swift 逐条断言。
//
// 为什么要把判断抽出来：这一层最容易出的两类错都**只在真机上偶发、复现极难**：
//   ① 判停太短 → 半句话被发出去（用户对着空气骂）；
//   ② 状态没退回 → 录满一轮后麦克风再也不开（"说第二句没反应"）。
// 把「何时该发、何时该停、何时该继续听」变成可枚举的输入输出，这两类错就能在本机拦住。
//
// 默认半双工：AI 朗读期间**停麦**（普通「语音对话」/语音输入都走这条）。
//   全双工要 AVAudioSession `.playAndRecord` + `.voiceChat` 做回声消除，本仓现有录音走 `.record`、
//   朗读走 `.playback`，是**切换式**的。所以 `fullDuplex` 默认 false，**只有通话页**在
//   `CallAudioSession` 激活成功后才置 true；其余路径一律保持半双工。
//   ⚠️ 全双工也不是「一直开麦」：送发时仍停麦、每轮朗读开始/结束都 restartMic 清缓冲，
//      回声闸门（CallEchoGate）负责把 AI 自己的声音剥掉。
//   半双工口径下：说话 → 发送**并立刻停麦** → 朗读 → 念完自动续听；想打断就点「打断」。
//   ⚠️ 停麦从「发送那一刻」就开始（不是等朗读开始才停），两个原因（v3.9.76 审查抓到的真问题）：
//     ① 发送到开口之间最长 25 秒，麦克风开着也没用——那段听到的内容会被 `.heard` 直接丢弃；
//     ② 更硬的是音频会话：停麦的收尾会 `setActive(false)`，若与朗读起播抢时序，会把刚开口的朗读掐掉。
//   所以 `Action.sendNow` 的语义 = **发出 + 停麦**，宿主必须两件事都做（见 VoiceDialogView.perform）。
//
// 超时兜底之后仍要能停麦：等回复超时会退回 `.listening` 并重新开麦（否则麦克风永久锁死），
//   但此刻 AI 的回复可能**才刚刚开始念** —— 这时 `speechStarted` 必须仍然有效（否则麦克风与扬声器同开，
//   录到自己的朗读 → 停顿 2 秒把 AI 的话发出去 = 自问自答）。用 `awaitingSpeech` 记住「这一轮还没念过」。

/// 轮次阶段。UI 只按它决定「显示什么 / 麦克风开不开」，不自己判断先后。
enum VoiceDialogPhase: Equatable {
    case idle          // 未开始
    case listening     // 收音中（可以有内容，也可以是空的）
    case sending       // 已发出（**已停麦**），等 AI 回复 / 等朗读开始
    case speaking      // AI 正在念（**期间不开麦**）
    case ended         // 已退出
}

struct VoiceDialogEngine {
    enum Mode: String {
        case auto      // 停顿到点自动发（用户拍板要这个）
        case manual    // 说完点「发送」才发（用户拍板两个都要）
    }

    /// 静音判停阈值：最后一次听到新内容后多久算「说完了」。用户拍板 2 秒。
    /// 为什么不是更短：1 秒会把「我想想…」这种正常停顿切在半句上；
    /// 为什么不是更长：超过 3 秒会让人怀疑"是不是没在听"。
    static let autoSendDelay: Double = 2.0
    /// 等回复/等朗读的兜底超时：流失败、朗读被关、模型很慢都可能让回调永不到来，
    /// 没有这条就会永久停在「正在回复」并把麦克风锁死。
    static let replyTimeout: Double = 25.0

    var mode: Mode = .auto
    /// 全双工：AI 朗读期间麦克风不关，用户随时可插话。默认关 —— 只有通话页在
    /// `CallAudioSession` 激活成功后才置 true；普通语音输入/语音对话仍是半双工。
    var fullDuplex: Bool = false
    private(set) var phase: VoiceDialogPhase = .idle
    /// 已完成轮次（用于 UI 上的「第 N 轮」）
    private(set) var rounds = 0
    /// 本轮已听到的文本（发送后清空，下一轮重新累积）
    private(set) var draft = ""
    /// 最后一次内容变化的时间（判停基准）
    private(set) var lastHeardAt: Date?
    /// 最近一次「发出等待」开始的时间（超时基准）
    private(set) var waitingSince: Date?
    /// 已发出、但**还没开始念**的这一轮。超时兜底把阶段退回 `.listening` 之后，
    /// 这条标记让迟到的 `speechStarted` 依然能停麦（见文件头最后一段）。
    private(set) var awaitingSpeech = false
    /// 插话发生后、AI 已念出的文本快照。麦没重开，后续转写仍带这段回声前缀 →
    /// `.heard` 每次都要继续剥离（清空时机：发送 / 念完 / 退出 / 新一轮开始）。
    private var bargeInSpoken = ""

    enum Event: Equatable {
        case start
        case heard(String)
        /// 全双工专用：插话后继续收音时，带**当前**已念文本（不是插话瞬间的快照），
        /// 用于剥掉停止朗读前残余的 0.2~1s 回声。
        case heardWithSpoken(String, spoken: String)
        /// 全双工专用：AI 朗读期间听到的内容。带 `spoken`（已念出的文本）用于回声闸门。
        case heardDuringSpeech(String, spoken: String)
        case tick(Date)        // 宿主定时器（0.25s 一次足够）
        case send              // 手动点「发送」
        /// 全双工专用：分段朗读的**下一段**起播（流还没结束）。宿主只在
        /// `finishSeq == 本轮基准`（这一轮确实还在生成）时发，避免把手动朗读/推送朗读推进 speaking。
        case speechSegmentStarted
        case speechStarted     // SpeechManager 开始念
        case speechEnded       // SpeechManager 念完
        case stop
    }

    enum Action: Equatable {
        case none
        /// 让宿主把这段文本作为用户消息发出去，**并立即停麦**（两个动作是一体的：
        /// 只发不停麦 = 发送到开口那段窗口还在收音，且停麦收尾会和朗读起播抢音频会话）。
        /// 发送失败由宿主体现在 UI 上。
        case sendNow(String)
        case openMic
        case closeMic
        /// 全双工换轮：先停麦再立刻开麦（清空上一轮的转写缓冲，但保留音频会话）。
        case restartMic
        /// 检测到用户插话：停朗读、保持麦克风、把这句话作为新一轮草稿。
        case interruptAndListen
    }

    /// 唯一入口：喂事件，拿该做的动作。宿主**只执行动作、不自己改状态**。
    /// `now` 可注入：判停/超时都按它算，测试因此能精确断言「1.9 秒不发、2.0 秒发」这类边界
    /// （用 Date() 内部取时间的话，这条路就永远只能靠真机手感验，回归不住）。
    mutating func handle(_ event: Event, now: Date = Date()) -> Action {
        switch event {
        case .start:
            guard phase == .idle || phase == .ended else { return .none }
            phase = .listening
            draft = ""
            lastHeardAt = nil
            waitingSince = nil
            awaitingSpeech = false
            bargeInSpoken = ""
            return .openMic

        case .heard(let text):
            return handleHeard(text, spoken: nil, now: now)

        case .heardWithSpoken(let text, let spoken):
            return handleHeard(text, spoken: spoken, now: now)

        case .heardDuringSpeech(let text, let spoken):
            // 全双工：朗读期间听到的字先过回声闸门。只有「不是 AI 自己念的」才算插话。
            guard fullDuplex, phase == .speaking else { return .none }
            // TTS 还没真正开口（charCount==0）时，任何环境噪声都不算插话 —— 起播瞬间
            // `.voiceChat` 路由切换本来就有瞬态，误判会把刚起播的回复掐掉。
            guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .none }
            // AEC 失效时转写可能是「AI 已念的一段 + 用户插话」拼在一起 —— 剥掉回声前缀，
            // 只把用户那截当草稿；整段都是回声则丢弃。
            let userText = CallEchoGate.userPart(trimmed, spoken: spoken)
            // 少于 3 个字不打断：咳嗽/环境音/单个语气词不值得杀掉一轮回答；
            // 真要立刻停，页面上还有「打断」按钮。
            guard userText.count >= 3 else { return .none }
            phase = .listening
            draft = userText
            bargeInSpoken = spoken
            lastHeardAt = now
            waitingSince = nil
            awaitingSpeech = false
            return .interruptAndListen

        case .tick(let now):
            switch phase {
            case .listening:
                guard mode == .auto, !draft.isEmpty, let last = lastHeardAt else { return .none }
                guard now.timeIntervalSince(last) >= Self.autoSendDelay else { return .none }
                return emitSend(now: now)
            case .sending:
                // 兜底：迟迟没等到朗读开始（朗读关了 / 回复失败）→ 回收音，别把麦克风锁死。
                // ⚠️ `awaitingSpeech` **不清**：回复可能下一秒才开始念，那次 speechStarted 还得能停麦。
                if let since = waitingSince, now.timeIntervalSince(since) >= Self.replyTimeout {
                    phase = .listening
                    draft = ""
                    waitingSince = nil
                    return .openMic
                }
                return .none
            default:
                return .none
            }

        case .send:
            // 手动发送：不限 mode（自动模式下也可以提前点发送，用户拍板「两个都要」）
            guard phase == .listening else { return .none }
            return emitSend(now: now)

        case .speechStarted:
            // 只在「等待中」或「发过但还没念、超时已回收音」时才有意义：
            // 手动点气泡朗读不该把语音对话推进到 speaking（那时 awaitingSpeech 是 false）。
            let waiting = (phase == .sending) || (phase == .listening && awaitingSpeech)
            guard waiting else { return .none }
            phase = .speaking
            awaitingSpeech = false
            // 半双工：念的时候必须停麦；全双工：反过来要保证麦是开的、且缓冲是空的。
            // 用 restartMic（不是 openMic）—— 发送时的停麦可能还没收尾，openMic 会被
            // `isRunning` 挡掉，留下上一轮的缓冲 → 一开口就被判成插话（自问自答）。
            return fullDuplex ? .restartMic : .closeMic

        case .speechSegmentStarted:
            // 分段朗读的下一段：只在全双工、且当前确实在收音态时接管。
            // （流是否还在生成由宿主用 finishSeq 判，本状态机不碰网络。）
            guard fullDuplex, phase == .listening, !awaitingSpeech else { return .none }
            phase = .speaking
            return .restartMic

        case .speechEnded:
            guard phase == .speaking else { return .none }
            phase = .listening
            draft = ""
            lastHeardAt = nil
            waitingSince = nil
            awaitingSpeech = false
            bargeInSpoken = ""
            rounds += 1
            // 全双工期间麦一直开着、缓冲里混着 AI 自己念的字；换轮必须重开一次把缓冲清干净，
            // 否则下一轮会把上一轮的残留当成用户输入（自问自答的另一种形态）。
            return fullDuplex ? .restartMic : .openMic

        case .stop:
            guard phase != .ended else { return .none }
            phase = .ended
            draft = ""
            awaitingSpeech = false
            bargeInSpoken = ""
            return .closeMic
        }
    }

    /// 收音态的统一入口（`.heard` / `.heardWithSpoken` 共用）。
    /// - Parameter spoken: 传 nil 时用插话瞬间的快照 `bargeInSpoken`；传值时用当前已念全文，
    ///   能剥掉「停止朗读生效前残余的那 0.2~1s」。
    private mutating func handleHeard(_ text: String, spoken: String?, now: Date) -> Action {
        // 非收音阶段听到的内容一律丢弃：AI 说话时麦克风漏进来的字**绝不能**进草稿
        // （否则下一轮会带着半句 AI 的话一起发出去）
        guard phase == .listening else { return .none }
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let echoRef = spoken ?? bargeInSpoken
        if fullDuplex, !echoRef.isEmpty {
            trimmed = CallEchoGate.userPart(trimmed, spoken: echoRef)
            guard !trimmed.isEmpty else { return .none }
        }
        guard trimmed != draft else { return .none }   // 同一段重复回调不算「新内容」，不刷新判停
        draft = trimmed
        lastHeardAt = now
        return .none
    }

    private mutating func emitSend(now: Date) -> Action {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }      // 空草稿不发（防"停顿到点把空气发出去"）
        draft = ""
        phase = .sending
        waitingSince = now
        lastHeardAt = nil
        awaitingSpeech = true                          // 这一轮还没念过
        bargeInSpoken = ""
        return .sendNow(text)                          // 语义含「停麦」，宿主必须一起做
    }
}

// MARK: - 全双工回声闸门（纯函数，本机可测）
//
// 全双工下麦克风会把扬声器里 AI 自己的声音也收进来（`.voiceChat` 有 AEC，但不保证 100%）。
// 判据：把「已念文本」和「转写」都去标点，取最长公共前缀；
//   · 整段转写都被已念文本包含 / 等于其前缀 → 回声；
//   · 否则剥掉公共前缀，剩下的那截才是用户插话（`.userPart`）。
//   · 开头就不一样（公共前缀 < 2 字）→ 判定为用户从头说的，原样返回。
//
// ⚠️ 代价：用户如果原样重复 AI 刚说过的话，会被当成回声忽略。这是有意的取舍 ——
//    误判成插话会让 AI 自己打断自己（更糟），而重复原话本身没有信息量。
enum CallEchoGate {
    /// 只留字母/数字：中文按 CharacterSet.alphanumerics 会保留汉字，标点与空格全部去掉。
    static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func isEcho(_ heard: String, spoken: String) -> Bool {
        userPart(heard, spoken: spoken).isEmpty
    }

    /// 返回「去掉回声前缀后、用户真正说的那截」。整段都是回声 → 空串。
    ///
    /// 做法：按去标点后的最长公共前缀定位。AEC 正常时公共前缀≈0，原样返回；
    /// AEC 失效时公共前缀就是 AI 已念的那段，从原文里按「第 N 个字母/数字」的位置切掉。
    static func userPart(_ heard: String, spoken: String) -> String {
        let h = normalized(heard)
        guard !h.isEmpty else { return "" }
        let s = normalized(spoken)
        guard !s.isEmpty else { return heard }
        // 转写只要**整段**出现在已念文本里就是回声（麦可能在中间才开）。
        // 注意不能只拿末尾 3~6 字去比：用户说「别订机票」时，末尾「订机票」
        // 会命中 AI 的「帮你订机票」，但那是一句真实插话 —— 必须按整段判。
        if h.count >= 3, s.contains(h) { return "" }
        var common = 0
        for (a, b) in zip(h, s) {
            guard a == b else { break }
            common += 1
        }
        guard common >= 2 else { return heard } // 开头就不一样 = 一开始就是用户说的
        var seen = 0
        var idx = heard.startIndex
        while idx < heard.endIndex {
            let ch = heard[idx]
            if ch.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
                if seen == common { break }
                seen += 1
            }
            idx = heard.index(after: idx)
        }
        return String(heard[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
