import AVFoundation
import CryptoKit   // v3.4.x：TTS 缓存 key 用 SHA256 摘要（避免原文作文件名含非法字符）
import Foundation

// MARK: - v2.0.81 AI 回复朗读 SpeechManager（全局单例，多消息共用；朗读中再点停止）
// v2.0.96c：语音输入曾改服务器 ASR（VoiceRecorder 录音上传），SFSpeechRecognizer 类移除。
// v3.9.3 纠正：当年「SideStore 闪退 = 侧载无语音识别 entitlement」是**误判**——iOS 上 Speech 框架
// 不需要任何 entitlement，真正缺的是权限串（本仓 Info.plist 当时一个都没声明）+ 可能强解包了 nil 识别器。
// 现语音输入已改回设备端（Core/LiveSpeechTranscriber.swift，iOS 26 SpeechAnalyzer），不再走服务器 ASR。
// v3.4.x code review fix（低）：文件名与内容对齐——原文件名为 SpeechRecognizer.swift，但内容实为
// 朗读/TTS 管理器 SpeechManager（AVSpeechSynthesizer + 云端神经 TTS），语音识别代码早已移除，
// 检索"语音识别"会误入此文件；已 git mv 为 SpeechManager.swift（类型名 SpeechManager 全仓引用不受影响）。
//
// v3.0.x：双引擎朗读 —— 系统 AVSpeechSynthesizer（默认） / 云端神经 TTS（小米 mimo-v2.5-tts）
//   - 由 CloudConfig.ttsEnabled 总开关控制：关 = 系统语音（现状不变）；开 = 调后端 /api/tts 拿音频用 AVAudioPlayer 播

/// v3.9.10：系统音色目录项（**纯 String**，Sendable；故意放**文件作用域**而不是嵌在
/// `@MainActor` 类里——嵌套类型容易带上类的隔离推断，非隔离的后台构造函数返回它会在
/// Swift 6 严格并发下报隔离错误）。
struct SpeechVoiceOption: Sendable, Identifiable {
    let id: String      // AVSpeechSynthesisVoice.identifier
    let label: String   // "丁丁 · 优质"
}

/// 音色目录快照（只在 SpeechManager.swift 内部用）
private struct SpeechVoiceCatalog: Sendable {
    let options: [SpeechVoiceOption]
    let hasHigh: Bool
}

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
        start(raw, id: id, preferSystem: false)
    }

    /// v3.9.8：语义是「念」而不是「切换」——已经在念同一条也从头念（自动朗读用；
    /// 用 toggle 会因为同 id 被当成「再点一次」而把正在念的掐断）。
    /// preferSystem：跳过云端神经 TTS，固定系统语音（免费、离线、不上传全文）。
    func speak(_ raw: String, id: String, preferSystem: Bool = false) {
        start(raw, id: id, preferSystem: preferSystem)
    }

    private func start(_ raw: String, id: String, preferSystem: Bool) {
        stop()
        // 去掉 markdown 符号 + 换行变句号
        let clean = raw
            .replacingOccurrences(of: #"[*#`>_~\[\]()!|\-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n+", with: "。", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        speakingID = id
        cloudDegraded = false
        if !preferSystem, CloudConfig.ttsEnabled {
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
        // v3.9.9：跟随用户选定音色（没选 = 目录里排名第一的）+ 可调语速
        // v3.9.10 hotfix：这里**只读缓存**，绝不在主线程枚举音色（原因见下方音色目录注释）
        ut.voice = Self.resolvedSystemVoice()
        ut.rate = Self.systemRate
        synth.speak(ut)
    }

    // MARK: - v3.9.9 / v3.9.10 系统音色可调（音色目录必须**离主线程**）
    //
    // ⚠️ v3.9.10 hotfix —— 3.9.9 真机 7 条 3.2~6.7 秒主线程卡顿（界面"点不动"），dSYM 符号化铁证：
    //   卡顿栈 = AXCoreUtilities.axUnsafeForcedSync ← TextToSpeech(BufferAllocator::instance /
    //   CAStreamBasicDescription::FromText) ← SpeechManager.systemVoiceChoices() ← ModelSheet.body.getter
    // 即 `AVSpeechSynthesisVoice.speechVoices()` 会进 TextToSpeech，并被无障碍层**串行化同步等待**；
    // 把它当 SwiftUI body 的计算属性来调 = 每次渲染卡 3~7 秒。所以本版改为：
    //   ① 枚举只在**后台任务**里做一次（阻塞后台线程，不阻塞主线程）；
    //   ② 主线程只读已算好的**字符串快照**（VoiceOption 全为 String，Sendable，跨线程安全）；
    //   ③ 真正要用的 AVSpeechSynthesisVoice 对象按 id 缓存，每个音色只在主线程构造一次；
    //   ④ 设置页只把快照取回填 @State，body 里不再有任何 AVFoundation 调用。

    // MARK: - v3.9.9 系统语音可调（用户反馈「TTS 语音太生硬」）
    //
    // 生硬的根因是**音质档**：系统语音默认给的是 compact 音质（机械感主要来自它）。
    // 用户在 iOS 设置里下载「增强 / 优质」中文语音包后，音色目录里就会出现带
    // 「增强 / 优质」标记的音色，自动挑选逻辑也会优先命中它们。
    // App 不能代用户下载音色包，所以只能在设置页把可选音色列出来 + 提示下载路径。
    private static let systemVoiceKey = "qingliao_system_voice_id"
    private static let systemRateKey = "qingliao_system_rate_index"

    /// 用户在设置里选定的系统音色 id（空 = 自动挑最优）
    static var systemVoiceID: String {
        UserDefaults.standard.string(forKey: systemVoiceKey) ?? ""
    }

    static func setSystemVoiceID(_ id: String) {
        UserDefaults.standard.set(id, forKey: systemVoiceKey)
    }

    /// 语速三档：0 慢 / 1 标准 / 2 快
    static var systemRateIndex: Int {
        UserDefaults.standard.object(forKey: systemRateKey) as? Int ?? 1
    }

    static func setSystemRateIndex(_ idx: Int) {
        UserDefaults.standard.set(idx, forKey: systemRateKey)
    }

    static var systemRate: Float {
        switch systemRateIndex {
        case 0: return 0.42
        case 2: return 0.55
        default: return 0.48
        }
    }

    @MainActor private(set) static var voiceOptions: [SpeechVoiceOption] = []
    @MainActor private(set) static var hasHighQualityVoice = false
    @MainActor private(set) static var voiceCatalogLoaded = false
    @MainActor private static var voiceCatalogTask: Task<Void, Never>?
    /// 已构造过的音色对象（按 id）——每个音色只在主线程构造一次，避免朗读时反复进 TextToSpeech
    @MainActor private static var voiceObjectCache: [String: AVSpeechSynthesisVoice] = [:]

    /// 取音色目录：幂等 + **只枚举一次**，且枚举跑在后台线程。
    /// 设置页 onAppear 与 App 启动预热都调它；不要在 SwiftUI body 里调（body 会被反复求值）。
    static func voiceCatalog() async -> [SpeechVoiceOption] {
        if voiceCatalogLoaded { return voiceOptions }
        if let running = voiceCatalogTask {
            await running.value
            return voiceOptions
        }
        let task = Task { @MainActor in
            let built = await Task.detached(priority: .utility) { Self.buildVoiceCatalog() }.value
            voiceOptions = built.options
            hasHighQualityVoice = built.hasHigh
            voiceCatalogLoaded = true
            voiceCatalogTask = nil
        }
        voiceCatalogTask = task
        await task.value
        return voiceOptions
    }

    /// ⚠️ 只允许在**后台线程**调用：`speechVoices()` 会进 TextToSpeech 并被无障碍层串行化同步等待。
    nonisolated private static func buildVoiceCatalog() -> SpeechVoiceCatalog {
        let zh = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
        let ranked = zh.sorted { a, b in
            let ra = qualityRank(a), rb = qualityRank(b)
            if ra != rb { return ra < rb }
            return a.name < b.name
        }
        let options = ranked.map { SpeechVoiceOption(id: $0.identifier, label: "\($0.name) · \(qualityTag($0))") }
        return SpeechVoiceCatalog(options: options, hasHigh: zh.contains { $0.quality != .default })
    }

    nonisolated private static func qualityRank(_ v: AVSpeechSynthesisVoice) -> Int {
        switch v.quality {
        case .premium: return 0
        case .enhanced: return 1
        default: return 2
        }
    }

    nonisolated private static func qualityTag(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "优质"
        case .enhanced: return "增强"
        default: return "标准"
        }
    }

    /// 设置页提示（只读缓存状态，零 AVFoundation 调用）
    static var systemVoiceHint: String {
        guard voiceCatalogLoaded else {
            return "正在后台读取系统音色，稍等片刻；列表暂时为空不代表没装语音包。"
        }
        return hasHighQualityVoice
            ? "优先选带「优质 / 增强」标记的音色，听感明显比「标准」自然。"
            : "想更自然：iOS 设置 → 辅助功能 → 朗读内容 → 声音 → 中文，下载「增强」或「优质」音色（App 不能代你下载），回到这里即可选中。"
    }

    /// 实际使用的系统音色：**只读缓存**。
    /// 缓存还没就绪时返回 nil（= 用系统默认音色先念），绝不为了取音色在主线程枚举。
    /// 已查过但系统里不存在的音色 id（负结果缓存）：命中后不再进 AVFoundation，
    /// 否则用户存过的音色被卸载后，**每一句朗读**都会在主线程重跑一次解析。
    private static var voiceMisses: Set<String> = []

    static func resolvedSystemVoice() -> AVSpeechSynthesisVoice? {
        // ① 目录已就绪时先剔掉「已被系统卸载」的存量选择：否则 UI 一直显示一个不存在的音色
        if voiceCatalogLoaded, !systemVoiceID.isEmpty,
           !voiceOptions.contains(where: { $0.id == systemVoiceID }) {
            voiceMisses.insert(systemVoiceID)
            setSystemVoiceID("")   // 只读计算属性，写入必须走 setter
        }
        // ② 目标音色：用户选的（已知失效则跳过）→ 「自动」= 目录排名第一（premium > enhanced > 标准）
        var target = systemVoiceID
        if target.isEmpty || voiceMisses.contains(target) { target = voiceOptions.first?.id ?? "" }
        if !target.isEmpty, !voiceMisses.contains(target) {
            if let cached = voiceObjectCache[target] { return cached }
            if let voice = AVSpeechSynthesisVoice(identifier: target) {
                voiceObjectCache[target] = voice
                return voice
            }
            voiceMisses.insert(target)
        }
        // ③ v3.9.10 fix（审查抓到）：兜底不能用「设备默认」——中文机器上默认常是 en-US，
        // 中文文本会被英文音素念出来（正是用户说的「生硬」）。目录还没预热好（启动预热要几秒）
        // 或目标失效时，回到与旧实现一致的语言兜底。
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

