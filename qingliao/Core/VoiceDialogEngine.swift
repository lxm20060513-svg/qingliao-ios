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
// 半双工口径（重要，别改成全双工）：AI 朗读期间**必须停麦**。
//   全双工要 AVAudioSession `.playAndRecord` + `.voiceChat` 做回声消除，本仓现有录音走 `.record`、
//   朗读走 `.playback`，是**切换式**的。不改音频会话就全双工 = 麦克风把自己的朗读录进去 → 自问自答。
//   v1 明确按半双工做：说话 → 发送**并立刻停麦** → 朗读 → 念完自动续听；想打断就点「打断」。
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

    enum Event: Equatable {
        case start
        case heard(String)
        case tick(Date)        // 宿主定时器（0.25s 一次足够）
        case send              // 手动点「发送」
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
            return .openMic

        case .heard(let text):
            // 非收音阶段听到的内容一律丢弃：AI 说话时麦克风漏进来的字**绝不能**进草稿
            // （否则下一轮会带着半句 AI 的话一起发出去）
            guard phase == .listening else { return .none }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != draft else { return .none }   // 同一段重复回调不算「新内容」，不刷新判停
            draft = trimmed
            lastHeardAt = now
            return .none

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
            return .closeMic

        case .speechEnded:
            guard phase == .speaking else { return .none }
            phase = .listening
            draft = ""
            lastHeardAt = nil
            waitingSince = nil
            awaitingSpeech = false
            rounds += 1
            return .openMic

        case .stop:
            phase = .ended
            draft = ""
            awaitingSpeech = false
            return .closeMic
        }
    }

    private mutating func emitSend(now: Date) -> Action {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }      // 空草稿不发（防"停顿到点把空气发出去"）
        draft = ""
        phase = .sending
        waitingSince = now
        lastHeardAt = nil
        awaitingSpeech = true                          // 这一轮还没念过
        return .sendNow(text)                          // 语义含「停麦」，宿主必须一起做
    }
}
