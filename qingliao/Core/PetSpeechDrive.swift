import Foundation
import Combine

/// v4.0.39：嘴型进度的**独立发布箱**（只有这一处写、PetAvatar 一处读）。
///
/// 为什么单独一个 ObservableObject：
///   `SpeechManager` 是 App 级共享单例，被聊天列表里每颗气泡观察 —— 逐字进度全程 ≈12.5Hz
///   （v3.9.77 已为此拆过一次 `SpokenProgress`，别把口型再挂回去连坐整片列表）。
///   本箱只在**开合度真的变了**时写（阈值 0.01），一次朗读大约写几十~上百次而非上千次，
///   且消费方只有页头宠物一只。
@MainActor
final class PetSpeechDrive: ObservableObject {
    static let shared = PetSpeechDrive()

    /// 当前开合度 0…1（PetAvatar 消费）
    @Published private(set) var amount: Double = 0

    /// v4.0.39：**是否正在朗读**也走本箱，不要让消费方去读 `SpeechManager.speakingID`。
    ///
    /// ⚠️ 实踩坑（审查命中）：`speakingID` 不是 PetAvatar 观察的对象，在 body 里读它
    ///   **不会触发刷新**。原来靠「每次收尾都恰好把 amount 从非 0 写回 0」才没露馅；
    ///   一旦出现 amount 已是 0 但画面仍需重画（例如停顿态嘴已是 0 → 要切回常态嘴），
    ///   就是静默不刷新。放进 @Published 后「开始念 / 念完」本身就是两次显式发布。
    @Published private(set) var isSpeaking: Bool = false

    private var units: [PetSpeechShape.Unit] = []

    private init() {}

    /// 新一段朗读开始：切好音节（纯函数），嘴先闭上
    func begin(_ text: String) {
        units = PetSpeechShape.units(text)
        if amount != 0 { amount = 0 }
        if !isSpeaking { isSpeaking = true }
    }

    /// 逐字进度推进 → 更新嘴型（值没变就不写，避免无谓重绘）
    func advance(toChar charIndex: Int) {
        let v = PetSpeechShape.mouth(atChar: charIndex, units: units)
        if abs(v - amount) > 0.01 { amount = v }
    }

    /// v4.0.40：**只闭嘴，不结束本段**（音频中断 `.began`：来电/Siri 抢走音频会话时用）。
    /// 音节表留着不动 —— `.ended` + shouldResume 续播时 willSpeakRange 会自然把嘴重新张开。
    func close() {
        if amount != 0 { amount = 0 }
    }

    /// 朗读结束 / 被停止：清空并闭嘴
    func clear() {
        units = []
        if amount != 0 { amount = 0 }
        if isSpeaking { isSpeaking = false }
    }
}