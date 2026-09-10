import AVFoundation
import CryptoKit   // v3.4.x：TTS 缓存 key 用 SHA256 摘要（避免原文作文件名含非法字符）
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
    /// v3.5.x：本次朗读是否降级到系统语音（云端 TTS 不可用——如额度用尽 429）。
    /// 用于气泡上显示「系统」小字，避免用户以为「朗读没反应/没声音」。
    @Published private(set) var cloudDegraded = false

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
        cloudDegraded = false
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
        cloudDegraded = false
    }

    // MARK: - v3.5.x 朗读音频会话（系统 / 云端两套引擎共用）

    /// 朗读前统一激活 .playback 会话。
    /// v3.5.x bug fix：云端 TTS 不可用时会回退系统 AVSpeechSynthesizer，而系统语音若沿用默认
    /// 会话类别（soloAmbient）在「静音拨片打开」或锁屏状态下**完全无声**——用户看到气泡上音柱在跳
    /// （speakingID 已置位）却听不到任何声音，即线上报的「TTS 播放无声音」。.playback 类别无视静音
    /// 拨片，两套引擎都先走这里，回退路径也一定出声。
    private func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    // MARK: - 系统引擎（原逻辑）

    private func speakViaSystem(_ clean: String, id: String) {
        // v3.5.x：系统语音同样要显式激活 .playback —— 否则静音拨片/锁屏下无声（回退路径的无声根因）
        activatePlaybackSession()
        let ut = AVSpeechUtterance(string: clean)
        ut.voice = Self.bestChineseVoice()
        ut.rate = 0.48
        synth.speak(ut)
    }

    /// v3.5.x：系统语音优先挑最高音质的中文音色（premium > enhanced > 默认）——
    /// 云端 TTS 不可用而降级时，听感尽量接近原云端神经语音。
    private static func bestChineseVoice() -> AVSpeechSynthesisVoice? {
        if #available(iOS 16.0, *) {
            let zh = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh-CN") }
            if let premium = zh.first(where: { $0.quality == .premium }) { return premium }
            if let enhanced = zh.first(where: { $0.quality == .enhanced }) { return enhanced }
        }
        return AVSpeechSynthesisVoice(language: "zh-CN")
    }

    // MARK: - 云端神经 TTS（小米 mimo-v2.5-tts，走后端 /api/tts）

    private func speakViaCloud(_ clean: String, id: String, gen: Int) async {
        guard let auth else {
            // 未注入 auth → 回退系统语音，保证可用
            speakViaSystem(clean, id: id)
            return
        }
        let voice = CloudConfig.ttsVoice
        let provider = CloudConfig.ttsProvider
        let model = CloudConfig.ttsModel
        // v3.4.x：TTS 本地缓存——同一段话(同 voice/provider/model)不重复请求云端，命中直接播省额度更快。
        // 代次校验先行：缓存命中回放仍需 gen 有效（用户已切走则丢弃，不播陈旧音频）。
        // v3.4.x fix：缓存命中不再"必然 return"——缓存文件可能损坏/为空导致 AVAudioPlayer 初始化
        // 失败（原 try? 静默吞掉 → 用户看到"点了没反应"）。改为：缓存播放成功才算完成；
        // 失败清掉坏缓存，继续走下方云端请求（再失败还有系统语音兜底）。
        guard gen == ttsGeneration else { return }
        if let cached = Self.readTTSCache(clean: clean, voice: voice, provider: provider, model: model) {
            do {
                try playAudio(cached)
                return
            } catch {
                try? FileManager.default.removeItem(at: Self.ttsCachePath(clean: clean, voice: voice, provider: provider, model: model))
                NSLog("[TTS] 缓存播放失败已清除坏缓存，转云端请求: \(error)")
            }
        }
        do {
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
            Self.writeTTSCache(audioData, clean: clean, voice: voice, provider: provider, model: model)
            try self.playAudio(audioData)
        } catch {
            // 代次过期不回退（用户已切走）；否则回退系统语音（不静默，保底可听）
            guard gen == ttsGeneration else { return }
            // v3.5.x：回退时置降级标记 + 记录原因（气泡上显示「系统」小字，便于定位云端不可用）
            cloudDegraded = true
            NSLog("[TTS] 云端 TTS 失败，回退系统语音: \(error)")
            // 保留 speakingID（=id）：回退语音播放期间球仍呈"说话"态，且重触同条会停而非重播；
            // 播毕由 speechSynthesizer didFinish 代理清除 speakingID。
            self.speakViaSystem(clean, id: id)
        }
    }

    private func playAudio(_ audioData: Data) throws {
        activatePlaybackSession()
        let p = try AVAudioPlayer(data: audioData)
        p.delegate = self
        p.prepareToPlay()
        p.play()
        player = p
    }

    // MARK: - v3.4.x TTS 本地缓存（同一段话不重复请求云端 /api/tts）

    /// TTS 缓存目录：Documents/TTSCache。
    private static var ttsCacheDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TTSCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 缓存文件路径 = SHA256(text|voice|provider|model) 十六进制 + .mp3
    private static func ttsCachePath(clean: String, voice: String, provider: String, model: String) -> URL {
        let combo = "\(clean)|\(voice)|\(provider)|\(model)"
        let digest = SHA256.hash(data: Data(combo.utf8)).map { String(format: "%02x", $0) }.joined()
        return ttsCacheDir.appendingPathComponent(digest + ".mp3")
    }

    /// 命中缓存返回音频 Data；未命中/读取失败返回 nil。
    private static func readTTSCache(clean: String, voice: String, provider: String, model: String) -> Data? {
        let url = ttsCachePath(clean: clean, voice: voice, provider: provider, model: model)
        return try? Data(contentsOf: url)
    }

    /// 写缓存（失败静默，不影响播放）；写后做容量控制。
    private static func writeTTSCache(_ audio: Data, clean: String, voice: String, provider: String, model: String) {
        let url = ttsCachePath(clean: clean, voice: voice, provider: provider, model: model)
        try? audio.write(to: url)
        evictTTSCacheIfNeeded()
    }

    /// 缓存文件超过 128 条时删最旧（按 mtime），防无限膨胀。
    private static func evictTTSCacheIfNeeded() {
        let dir = ttsCacheDir
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
            files.count > 128 else { return }
        let sorted = files.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d0 < d1
        }
        for f in sorted.prefix(files.count - 128) {
            try? FileManager.default.removeItem(at: f)
        }
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
                    self.cloudDegraded = false
                    // v3.5.x：系统语音播毕也回收播放会话（与云端播毕路径对齐，不长期占用音频焦点）
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

