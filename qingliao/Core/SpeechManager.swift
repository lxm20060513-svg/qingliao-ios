import AVFoundation
import Foundation

// MARK: - v2.0.81 AI 回复朗读 SpeechManager（全局单例，多消息共用；朗读中再点停止）
// v2.0.96c：语音输入已改服务器 ASR（VoiceRecorder 录音上传），SFSpeechRecognizer 类移除（SideStore 闪退）。
// v3.4.x code review fix（低）：文件名与内容对齐——原文件名为 SpeechRecognizer.swift，但内容实为
// 朗读/TTS 管理器 SpeechManager（AVSpeechSynthesizer + 云端神经 TTS），语音识别代码早已移除，
// 检索"语音识别"会误入此文件；已 git mv 为 SpeechManager.swift（类型名 SpeechManager 全仓引用不受影响）。
//
// v3.0.x：双引擎朗读 —— 系统 AVSpeechSynthesizer（默认） / 云端神经 TTS（小米 mimo-v2.5-tts）
//   - 由 CloudConfig.ttsEnabled 总开关控制：关 = 系统语音（现状不变）；开 = 调后端 /api/tts 拿音频用 AVAudioPlayer 播

@MainActor
final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate,
                           AVAudioPlayerDelegate {
    static let shared = SpeechManager()
    @Published var speakingID: String?

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var auth: AuthStore?
    // v3.0.x：TTS 代次 —— 每次 toggle/stop 递增；旧 Task 恢复后校验代次，丢弃过期结果（防陈旧异步覆盖）
    private var ttsGeneration = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    /// 注入 AuthStore（供 TTS 走后端 /api/tts）。在主环境设置一次即可。
    func attach(auth: AuthStore) {
        self.auth = auth
    }

    func toggle(_ raw: String, id: String) {
        if speakingID == id {
            stop()
            return
        }
        stop()
        // 去掉 markdown 符号 + 换行变句号
        let clean = raw
            .replacingOccurrences(of: #"[*#`>_~\[\]()!|\-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n+", with: "。", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        speakingID = id
        if CloudConfig.ttsEnabled {
            let gen = ttsGeneration
            Task { await speakViaCloud(clean, id: id, gen: gen) }
        } else {
            speakViaSystem(clean, id: id)
        }
    }

    func stop() {
        ttsGeneration += 1   // 每次停止/重载递增，使 in-flight 云端请求的代次校验失效
        synth.stopSpeaking(at: .immediate)
        if player?.isPlaying == true {
            player?.stop()
            // 打断播放中的云端音频 → 一并停用会话（否则 playback 会话残留）
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        player = nil
        speakingID = nil
    }

    // MARK: - 系统引擎（原逻辑）

    private func speakViaSystem(_ clean: String, id: String) {
        let ut = AVSpeechUtterance(string: clean)
        ut.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        ut.rate = 0.48
        synth.speak(ut)
    }

    // MARK: - 云端神经 TTS（小米 mimo-v2.5-tts，走后端 /api/tts）

    private func speakViaCloud(_ clean: String, id: String, gen: Int) async {
        guard let auth else {
            // 未注入 auth → 回退系统语音，保证可用
            speakViaSystem(clean, id: id)
            return
        }
        do {
            let voice = CloudConfig.ttsVoice
            let provider = CloudConfig.ttsProvider
            let model = CloudConfig.ttsModel
            let (data, resp) = try await auth.request("/api/tts", method: "POST",
                body: ["text": clean, "voice": voice, "provider": provider, "model": model])
            // 代次校验：请求期间用户已停止/切到别的朗读 → 丢弃过期结果
            guard gen == ttsGeneration else { return }
            guard resp.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let b64 = obj["audio"] as? String,
                  let audioData = Data(base64Encoded: b64) else {
                throw APIError.badResponse
            }
            try self.playAudio(audioData)
        } catch {
            // 代次过期不回退（用户已切走）；否则回退系统语音（不静默，保底可听）
            guard gen == ttsGeneration else { return }
            // 保留 speakingID（=id）：回退语音播放期间球仍呈"说话"态，且重触同条会停而非重播；
            // 播毕由 speechSynthesizer didFinish 代理清除 speakingID。
            self.speakViaSystem(clean, id: id)
        }
    }

    private func playAudio(_ audioData: Data) throws {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        let p = try AVAudioPlayer(data: audioData)
        p.delegate = self
        p.prepareToPlay()
        p.play()
        player = p
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // v3.0.x fix：云端 TTS 播放中 player != nil，系统 TTS didFinish 不清除 speakingID
            // → 状态泄漏。改为无条件检查：如果云端 player 也在播完状态，一并清除
            if self.speakingID != nil {
                // 如果云端 player 还在播放，不在此清除（等 audioPlayerDidFinish 处理）
                // 如果云端 player 已为 nil（已被 audioPlayerDidFinish 清除或本来就没用云端），直接清除
                if self.player == nil {
                    self.speakingID = nil
                }
            }
        }
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        // Swift 6：non-Sendable 的 p 不能捕获进 Task @MainActor（跨域 data race）。
        // 只传 Sendable 的 ObjectIdentifier，在 MainActor 上再比较身份。
        let pid = ObjectIdentifier(p)
        Task { @MainActor in
            guard let pl = self.player, ObjectIdentifier(pl) == pid else { return }
            self.player = nil
            self.speakingID = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

