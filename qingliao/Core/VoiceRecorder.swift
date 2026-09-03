import AVFoundation

// MARK: - v2.0.96c 语音转文字录音器（服务器 ASR：AVAudioRecorder 录音 → 上传转写）
// 侧载兼容：AVAudioRecorder 仅需麦克风权限（无 speech-recognition entitlement 限制），
// 替代 v2.0.85 因 SideStore SIGTRAP 移除的 SFSpeechRecognizer。
// v3.2.4+（回归最原始基线）：v3.0.85 加 .voiceChat 系统降噪/回声消除 → 语音入口必现卡死；
// v3.1.2/3.1.4/3.1.7 三连在音频层打转（.voiceChat→.playAndRecord→后台异步配置）均未根治
// （真根因=渲染层，v3.2.3 已修）；且 v3.1.7 异步化引入"松手太快→stop()=nil→静默吞掉"的转不出文字。
// 现整体回退 v3.0.85 前久经考验的最简配置：同步 setCategory(.record)+setActive(true)，
// 零降噪零回声消除零后台异步——触发即录、松手必有文件。

@MainActor
final class VoiceRecorder: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate {
    @Published var isRecording = false

    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    /// v3.0.78 诊断：AVAudioRecorder.record() 返回值（false=录音未真正开始，多因麦克风权限/会话未激活）
    private(set) var lastRecordOK: Bool? = nil

    /// v3.0.76：每个录音段用独立文件名（避免分段流式反复 stop/resume 同一 URL 的数据竞争 / 读到空段）
    /// v3.0.x fix：加单调递增计数器，防止高频调用时时间戳重复产生相同文件名
    private static var _urlCounter: Int = 0
    private func makeURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        Self._urlCounter += 1
        let name = "voice_asr_\(Int(Date().timeIntervalSince1970 * 1000))_\(Self._urlCounter).m4a"
        return dir.appendingPathComponent(name)
    }

    /// 开始录音（同步：立即配置会话并开录——v3.2.4 回归 v3.0.85 前最简基线）
    /// 返回是否成功；失败 = 无麦克风权限 / 会话配置失败
    func start() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            // v3.2.4：.record + .default —— 回归最原始，无 .voiceChat 降噪/回声消除（v3.0.85 引入后卡死）、
            // 无 .playAndRecord/.defaultToSpeaker（v3.1.4 引入）、无后台异步配置（v3.1.7 引入 →
            // 松手太快会 stop()=nil 静默吞掉，转不出文字且无提示）。.record 配置开销极小，主线程无感知。
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            NSLog("[VOICE] session config failed: \(error)")
            recorder = nil
            audioURL = nil
            lastRecordOK = false
            isRecording = false
            return false
        }
        let url = makeURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            let ok = r.record()
            self.lastRecordOK = ok
            NSLog("[VOICE] record()->\(ok) url=\(url.lastPathComponent) mode=record")
            if ok {
                recorder = r
                audioURL = url
                isRecording = true
            } else {
                isRecording = false
                audioURL = nil
                lastRecordOK = false
            }
            return true
        } catch {
            NSLog("[VOICE] recorder create failed: \(error)")
            recorder = nil
            audioURL = nil
            lastRecordOK = false
            return false
        }
    }

    /// 停止录音，返回音频文件（用于上传转写）
    /// v2.0.102：恢复音频会话为 playback 并停用——否则 TTS 朗读无声
    func stop() -> URL? {
        if let r = recorder { r.stop() }
        let url = audioURL
        isRecording = false
        recorder = nil
        audioURL = nil

        if let u = url {
            let sz: Int = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int ?? -1
            NSLog("[VOICE] stop() url=\(u.lastPathComponent) size=\(sz)")
        }

        // v2.0.102：恢复 playback 并停用会话（.record 未恢复会导致 TTS 无声）
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        return url
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        isRecording = false
    }
}
