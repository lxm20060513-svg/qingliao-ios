import AVFoundation
import Foundation

// MARK: - v4.1.x 通话音频会话（「打电话给 Hermes」唯一会话所有者）
//
// 为什么必须单独有一个所有者：本仓录音走 `.record`、朗读走 `.playback`，是**切换式**的
// （见 VoiceDialogEngine 文件头）。全双工要求录音与播放同时存在，只能把会话切成
// `.playAndRecord` + `.voiceChat`（系统回声消除）并**全程不再切类别**——任何一处再调
// `setCategory(.record/.playback)` 都会把另一条路掐掉。
//
// 历史坑：v3.0.85 引入 `.voiceChat`、v3.1.4 用 `.playAndRecord` 都出现过卡死，所以：
//   · 只在通话页 onAppear 激活一次，失败/超时一律回退半双工（调用方负责）；
//   · 通话期间 LiveSpeechTranscriber / SpeechManager 都不许再改类别（各自有 policy 闸门）；
//   · 退出统一恢复 `.playback`，否则聊天页 TTS 会无声（本仓老坑）。
@MainActor
final class CallAudioSession {
    static let shared = CallAudioSession()

    private(set) var isActive = false
    private(set) var speakerOn = true
    private(set) var lastError: String?
    /// 当前通话页的 owner（每次 onAppear 生成新 UUID）。退出时只关自己那份，
    /// 不能误关用户刚重进的新通话；同一页内来电恢复不算换 owner。
    private(set) var owner: UUID?

    private init() {}

    /// 激活全双工会话。返回 false = 当前设备/路由不接受，调用方必须回退半双工。
    /// - Parameter owner: 通话页标识；退出时用同一个 owner 收尾，避免旧页面误关新通话。
    @discardableResult
    func activate(owner: UUID? = nil) -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            isActive = true
            lastError = nil
            speakerOn = true
            self.owner = owner
            return true
        } catch {
            lastError = error.localizedDescription
            isActive = false
            // 失败时尽量把会话恢复到朗读口径，别把 App 留在半激活态。
            // 若 setCategory 成功而 setActive 抛错，这里不显式停用会留下一个 active 的
            // .playAndRecord 会话（deactivate 的 isActive 守卫会短路）。
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(.playback, mode: .default)
            return false
        }
    }

    /// 免提开/关（听筒 ↔ 扬声器）。只在通话会话激活时有效。
    /// ⚠️ 不能只 `overrideOutputAudioPort(.none)`：类别里带着 `.defaultToSpeaker` 时，
    /// `.none` 就是「回类别默认」= 扬声器，按钮会显示「关」但声音还在扬声器。
    /// 正解 = 重设类别（听筒时去掉 `.defaultToSpeaker`）+ override。
    func setSpeaker(_ on: Bool) {
        guard isActive else { return }
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = on
            ? [.defaultToSpeaker, .allowBluetooth]
            : [.allowBluetooth]
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            try session.overrideOutputAudioPort(on ? .speaker : .none)
            speakerOn = on
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 退出通话：先停用再恢复朗读类别。顺序不能反（先切类别会让正在播的音频报错）。
    /// - Parameter owner: 只在该 owner 仍是当前会话时收尾；旧页面迟到的收尾不能关新通话。
    func deactivate(owner: UUID? = nil) {
        if let owner, self.owner != owner { return }
        guard isActive else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.playback, mode: .default)
        isActive = false
        speakerOn = true
        self.owner = nil
    }
}
