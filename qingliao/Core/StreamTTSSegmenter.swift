import Foundation

/// v4.0.x 流式 TTS 分段队列（功能：AI 逐字流式输出满一条聊天气泡时同步启动 TTS 朗读）。
///
/// 需求原话：流式增量每凑满一个气泡段落就送 TTS 朗读，而不是整条回复输出完才启动。
/// 归属：StreamClient 持有本队列（feedStreamingTTS 唯一写入口）；SpeechManager.speakSegment
/// 负责逐段出声（系统引擎 synth 自串行 / 云端引擎 FIFO，见彼处）。其余路径（手动朗读 /
/// 语音对话页 / 移交后台的流 / 非当前会话）不写入 → 落库边沿的整段自动朗读保持原样。
///
/// - 「气泡段落」口径 = MessageBubble.splitParagraphs（空行 + 代码围栏），与本仓 UI 拆气泡
///   唯一真源一致；代码围栏（``` 块）不进 TTS（自动化测试会念出来）。
/// - 纯 Foundation，无 UI 依赖：切分逻辑进本机真值表编译。
struct StreamTTSSegmenter {
    /// 本流已送朗读的段落数（含正在念的）；-1 = 队列未启用。
    private(set) var fedCount = -1

    /// 带存储属性的 enum 没有隐式 init → 显式给一个（真值表/StreamClient 都要新建）。
    init() {}

    var isActive: Bool { fedCount >= 0 }

    /// 新一轮开始 / 停流 / 移交后台时调用：队列停喂（已送出的段不收回，未凑满的段不再送）。
    mutating func reset() {
        fedCount = -1
    }

    /// 启用队列（每个新流第一个增量到达时由 feedStreamingTTS 调一次）。
    mutating func activate() {
        fedCount = 0
    }

    // MARK: - 增量喂入（纯逻辑，真值表直测）

    /// 切分规则：与 MessageBubble.splitParagraphs 同口径（空行分界、``` 围栏内空行不分段）。
    /// - 参数 keepTail：false（流式喂入）→ **扣住尾部未终止段**（末尾还在增长的不算凑满）；
    ///   true（收尾定格）→ 末尾段落照常收进（feed 的 isFinal 路径用）。
    /// 实现为独立同构副本：splitParagraphs 是 private static（跨文件引用会撞「跨文件 private」
    /// 预检护栏），真值表用源护栏钉住两边口径不漂移。
    static func splitSpeechParagraphs(_ text: String, keepTail: Bool = false) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var paras: [String] = []
        var cur: [String] = []
        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if trimmed.isEmpty && !inFence {
                if !cur.isEmpty { paras.append(cur.joined(separator: "\n")); cur = [] }
            } else {
                cur.append(line)
            }
        }
        if keepTail, !cur.isEmpty { paras.append(cur.joined(separator: "\n")) }
        return paras.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 喂入累计全文，返回本轮**新凑满**的段落（可能 0~n 条）。非围栏段落原样返回；
    /// 段落判「纯代码块」（整体被 ``` 围栏包住）时改判未完成 → 跳过不送朗读。
    /// - 参数 isFinal：流收尾时 true——尾部没有空行终止符的「最后一行」此刻已定格，
    ///   作为末段送出（否则落库边沿整段朗读已被 hasStreamingSpeech 守卫跳过，末段永远没人念）。
    ///   流式中（默认）尾部未凑满的段**扣住不送**（它还在长，送了会念半截）。
    /// 复杂度 O(delta)：从 tail 已核对边界继续扫，不重扫全文。
    mutating func feed(full: String, isFinal: Bool = false) -> [String] {
        guard fedCount >= 0 else { return [] }
        // 流式中（isFinal=false）只取「已被空行终止」的段：尾部还在增长的段扣住不送（念了是半截）。
        // 收尾（isFinal=true）时全文定格 → 尾段照常收进（末段必须有人念——落库边沿整段朗读已被守卫跳过）。
        let paras = Self.splitSpeechParagraphs(full, keepTail: isFinal)
        guard fedCount < paras.count else { return [] }
        var out: [String] = []
        while fedCount < paras.count {
            let p = paras[fedCount]
            if Self.isPureCodeFence(p) { fedCount += 1; continue }
            fedCount += 1
            out.append(p)
        }
        return out
    }

    /// 段落是否纯代码块：首非空行以 ``` 开头 → 整段跳过（流式中围栏未闭合时该段持续增长，
    /// 永远不会误送半截；闭合后下一段正常）。
    static func isPureCodeFence(_ para: String) -> Bool {
        let t = para.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("```")
    }
}
