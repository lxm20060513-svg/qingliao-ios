//  MARK: - 设备端实时语音转写（iOS 26 SpeechAnalyzer + SpeechTranscriber）
//
//  为什么从「后端 ASR」换成设备端（v3.9.3）：
//   1. 后端链路是「整段录音 → 上传 → 等返回」，**天然不可能实时**；设备端 volatile 结果可以边说边出字
//   2. 纯设备端：音频不上传、无时长上限（旧的 SFSpeechRecognizer 约 1 分钟/次）、无网络依赖
//   3. 本地/云端双模式都能用（原来云端模式因为「没有后端 ASR」把语音入口整个屏蔽了）
//
//  ⚠️ 历史坑务必保留这段（v2.0.85 的结论是误判）：
//   当年判定「侧载无语音识别 entitlement 必闪退」而整删语音输入，但 iOS 上 Speech 框架**不需要任何 entitlement**
//   （Apple 文档只要求 Info.plist 权限串 + 运行时授权）。当年 SIGTRAP 更可能是：
//     ① 整包没声明任何权限串（本项目 Info.plist 至今只有定位 + 实时活动，连麦克风都没有）
//     ② `SFSpeechRecognizer(locale:)` 返回 nil 被强解包（v2.0.83f 提交标题就在修「不可用时提示不闪退」）
//     ③ 当时跑在 LiveContainer 里（其 README 明写 App Permissions are globally applied，权限算宿主 App 的）
//   本版三条都已避开：两个权限串都声明 / 不用 SFSpeechRecognizer / 正常 SideStore 安装。
//
//  API 依据：WWDC25 session 277 + Apple 文档。签名一律按官方示例写法，勿凭记忆改。

import AVFoundation
import Foundation
import Speech

// MARK: - 音频 tap 搬运工

/// 把麦克风 tap 的 buffer 转成 Analyzer 要的格式并投喂。
///
/// 单独拆出来的原因（Swift 6）：`installTap` 的 block 在**音频线程**回调，
/// 闭包里直接捕获 `@MainActor` 的转写器会报 capture of non-Sendable self；
/// 这里只捕获这个 `@unchecked Sendable` 搬运工，转换也在音频线程做完，不占主线程。
private final class AudioTapFeeder: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var builder: AsyncStream<AnalyzerInput>.Continuation?

    // v3.9.9：音频三级计数——排查"录音期间一个结果都不出（V0/F0）"这类静默失败时，
    // 光看 UI 是看不出断在哪一级的（官方文档也要求按阶段测量）。三段含义：
    //   T = 麦克风 tap 回调次数（有没有音频进来）
    //   D = 被丢弃的 buffer 数（转换失败/空输出/拷贝失败）
    //   Y = 真正投递给 analyzer 的 buffer 数
    private var tapCount = 0
    private var dropCount = 0
    private var yieldCount = 0
    private var lastDropNote = ""

    var stats: String {
        lock.lock(); defer { lock.unlock() }
        return "T\(tapCount)/D\(dropCount)/Y\(yieldCount)\(lastDropNote.isEmpty ? "" : " " + lastDropNote)"
    }

    func resetStats() {
        lock.lock(); defer { lock.unlock() }
        tapCount = 0; dropCount = 0; yieldCount = 0; lastDropNote = ""
    }

    private func noteDrop(_ why: String) {
        lock.lock(); defer { lock.unlock() }
        dropCount += 1
        if lastDropNote.isEmpty { lastDropNote = why }
    }

    func prepare(converter: AVAudioConverter?, targetFormat: AVAudioFormat,
                 builder: AsyncStream<AnalyzerInput>.Continuation) {
        lock.lock(); defer { lock.unlock() }
        self.converter = converter
        self.targetFormat = targetFormat
        self.builder = builder
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        converter = nil
        targetFormat = nil
        builder = nil
    }

    /// v3.9.9 关键修复：**自持一份 PCM 拷贝**。
    ///
    /// tap 回调交给我们的 buffer 只在回调期间有效，回调返回后音频引擎会复用那块内存；
    /// 而我们是「入队 AsyncStream → analyzer 稍后异步消费」，中间隔着一段时间差 ——
    /// 直接把回调 buffer 投进去，analyzer 读到的往往是被后续音频覆盖过的内存，
    /// 表现就是官方文档点名的 **"缓冲有、UI 正常、却永远没有文字"**。
    /// 两个方式（格式相同走拷贝 / 格式不同走转换输出）都必须给 analyzer 独立内存。
    private static func ownedCopy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        out.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = max(1, Int(buffer.format.channelCount))
        let interleaved = buffer.format.isInterleaved
        let buffersToCopy = interleaved ? 1 : channels
        let framesPerBuffer = interleaved ? frames * channels : frames

        if let src = buffer.floatChannelData, let dst = out.floatChannelData {
            for i in 0..<buffersToCopy { memcpy(dst[i], src[i], framesPerBuffer * MemoryLayout<Float>.size) }
        } else if let src = buffer.int16ChannelData, let dst = out.int16ChannelData {
            for i in 0..<buffersToCopy { memcpy(dst[i], src[i], framesPerBuffer * MemoryLayout<Int16>.size) }
        } else if let src = buffer.int32ChannelData, let dst = out.int32ChannelData {
            for i in 0..<buffersToCopy { memcpy(dst[i], src[i], framesPerBuffer * MemoryLayout<Int32>.size) }
        } else {
            return nil
        }
        return out
    }

    /// 音频线程调用：必要时重采样 → 投喂 Analyzer
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        tapCount += 1
        let converter = self.converter
        let target = self.targetFormat
        let builder = self.builder
        lock.unlock()
        guard let builder else { return }

        if let target, buffer.format != target {
            // 格式与 Analyzer 要求不一致：必须有转换器（Apple 文档：Analyzer 不做音频转换）
            guard let converter, let converted = Self.convert(buffer, using: converter, to: target) else {
                noteDrop("convFail")   // 文档警告：静默丢缓冲 = UI 看着健康却永远没文字，必须记数
                return
            }
            guard converted.frameLength > 0 else {
                noteDrop("convEmpty")  // 转换器吐了空输出（输入太短/转换状态未就绪）→ 同样不投递
                return
            }
            lock.lock(); yieldCount += 1; lock.unlock()
            builder.yield(AnalyzerInput(buffer: converted))
        } else {
            // 格式已匹配也不能直接投回调 buffer（会被音频引擎复用）→ 自持拷贝
            guard let owned = Self.ownedCopy(buffer) else {
                noteDrop("copyFail")
                return
            }
            lock.lock(); yieldCount += 1; lock.unlock()
            builder.yield(AnalyzerInput(buffer: owned))
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        let feed = ConverterFeed(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            guard let next = feed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return next
        }
        guard status != .error, error == nil else { return nil }
        return output
    }

    /// `AVAudioConverter.convert` 的输入 block 是 `@Sendable`，但它由 AVAudioConverter **同步回调**
    /// （就在调用线程上）。直接捕获可变 `var consumed` / 非 Sendable 的 `AVAudioPCMBuffer`，Swift 6
    /// 并发检查会报「mutation of captured var in concurrently-executing code」等告警（CI 实证 4 条）。
    /// 用一个 @unchecked Sendable 盒子把「一帧只投喂一次」的判断包起来，语义不变、告警消失。
    private final class ConverterFeed: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private var consumed = false
        private let lock = NSLock()

        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        /// 首次调用给出这一帧，之后返回 nil（转换器会拿到 `.noDataNow`）
        func take() -> AVAudioPCMBuffer? {
            lock.lock()
            defer { lock.unlock() }
            if consumed { return nil }
            consumed = true
            return buffer
        }
    }
}

// MARK: - 转写器

/// 设备端实时语音转写（边说边出字；音频不出设备）
@MainActor
final class LiveSpeechTranscriber: ObservableObject {
    /// 当前完整文本（= 进入语音模式前输入框内容 + 已定稿 + 正在识别的 volatile 尾巴）
    @Published private(set) var liveText = ""
    /// 录音/识别进行中
    @Published private(set) var isRunning = false
    /// 首次准备（下载语音模型）中
    @Published private(set) var isPreparing = false
    /// 诊断信息（真机日志 + 提示弹窗用，沿用旧的 voiceDiag 通道）
    @Published private(set) var diagnostics = ""
    /// 需要用户去设置里开权限
    @Published private(set) var needsPermission = false
    /// 最后一次失败原因（给 UI 提示）
    @Published private(set) var lastError: String?
    /// 本次 stop 识别到的内容（不含基线）——UI 用它区分「没识别到」与「识别到但与基线相同」
    @Published private(set) var lastRecognizedText = ""

    // MARK: v3.9.6 临时诊断（实时出字排查用，确认稳定后整块删除）
    /// 本次录音收到的实时（volatile）中间结果条数
    @Published private(set) var volatileCount = 0
    /// 本次录音收到的定稿（final）结果条数
    @Published private(set) var finalCount = 0
    /// 首条结果延迟（毫秒；-1 = 本次还没有任何结果）
    @Published private(set) var firstResultMs = -1
    private var startedAt: Date?

    /// 诊断串（输入栏录音态临时显示）
    var resultStats: String { "V" + String(volatileCount) + "/F" + String(finalCount) }
    /// 录音 3s 后仍无任何结果（实时出字未生效）——仅在异常时为 true，UI 平时不显示诊断
    @Published private(set) var liveStalled = false
    /// v3.9.9：音频三级计数（T=麦克风 tap 回调 / D=丢弃 / Y=实际投递 analyzer），每秒刷新。
    /// 录音期间**必须**能看见它——否则"没出字"到底断在采集、转换还是识别只能靠猜。
    @Published private(set) var pipeStats = ""
    private var statsTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?

    /// 文本变化回调（ChatView 用它把实时文本回填输入框）
    var onTextChange: (@MainActor (String) -> Void)?
    /// 运行期错误回调（结果流中断等，UI 弹窗提示用）
    var onError: (@MainActor (String) -> Void)?

    private let engine = AVAudioEngine()
    private let feeder = AudioTapFeeder()
    private var analyzer: SpeechAnalyzer?
    private var builder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var resultsFinished = false
    private var tapInstalled = false

    /// 准备期取消（模型下载/权限弹窗期间点 ×）——start() 在每个 await 之后检查它
    private var cancelRequested = false
    /// stop() 重入保护：退出与取消可能同时发生，共用同一个收尾任务避免并发 finalize
    private var stopTask: Task<String, Never>?

    private var baseline = ""        // 进入语音模式前输入框已有内容
    private var finalizedText = ""   // 已定稿分段
    private var volatileText = ""    // 正在识别的尾段（会被后续结果替换）

    // MARK: 旧数据清理

    /// v3.9.3：清掉旧「录音上传」流程在 Documents 里留下的 voice_asr_*.m4a
    /// （新流程完全不落盘音频 —— 设备端直接转写，音频不出设备）。启动时调一次即可，重复调用无害。
    nonisolated static func cleanupLegacyRecordings() {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        var removed = 0
        for item in items where item.lastPathComponent.hasPrefix("voice_asr_") && item.pathExtension == "m4a" {
            try? fm.removeItem(at: item)
            removed += 1
        }
        if removed > 0 { NSLog("[VOICE] 清理旧录音文件 \(removed) 个") }
    }

    // MARK: 权限

    /// 麦克风权限（首次进入语音模式时请求，符合 Apple「用到才请求」的要求）
    static func ensureMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        default:
            return await withCheckedContinuation { continuation in
                // 同 v3.9.4 铁律：系统回调闭包一律显式 @Sendable（TCC 回调队列不保证是主线程）
                AVAudioApplication.requestRecordPermission { @Sendable granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    // MARK: 语言与模型

    /// 中文优先（本 App 用户说中文），其次系统首选语言；**没有可用语言就返回 nil**（不要兜底到不支持的语言）
    ///
    /// ⚠️ Apple 文档：`SpeechTranscriber.supportedLocales` 在**机型不支持**时返回空数组
    /// （SpeechTranscriber 有硬件要求，并非所有 iOS 26 设备都能用）。此时如果硬拿 en-US 去初始化，
    /// start() 会抛 "SpeechTranscriber initialized with unsupported locale"。
    private static func resolvedLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        guard !supported.isEmpty else { return nil }
        let supportedIDs = Set(supported.map { $0.identifier(.bcp47) })
        let candidates = [Locale(identifier: "zh-CN")]
            + Locale.preferredLanguages.map { Locale(identifier: $0) } + [Locale.current]
        for candidate in candidates where supportedIDs.contains(candidate.identifier(.bcp47)) {
            return candidate
        }
        // 语言级兜底（例如系统是 zh-Hans-CN 而支持列表里只有 zh_CN）
        for candidate in candidates {
            guard let code = candidate.language.languageCode?.identifier else { continue }
            if let match = supported.first(where: { $0.language.languageCode?.identifier == code }) {
                return match
            }
        }
        return nil
    }

    /// 模型资产：未安装则下载（只在首次使用 / 换语言时发生，系统留存不占 App 体积）
    private static func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let target = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == target }) { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            NSLog("[VOICE] 正在安装语音模型 locale=\(target)")
            try await request.downloadAndInstall()
            NSLog("[VOICE] 语音模型安装完成 locale=\(target)")
        }
    }

    // MARK: 生命周期

    /// 开始实时转写
    /// - Parameter baseline: 进入语音模式时输入框已有内容（实时文本会接在它后面）
    /// - Returns: 是否成功启动
    @discardableResult
    func start(baseline: String) async -> Bool {
        // ⚠️ 准备期必须挡住重入：首次要下模型（数秒~数十秒），期间用户再长按一次会走第二次 start()，
        // 而 AVFoundation 规定**一个 bus 只能挂一个 tap**（官方文档），第二次 installTap 会抛异常。
        // isRunning 直到最后才置 true，所以这里必须同时看 isPreparing。
        guard !isRunning, !isPreparing else { return isRunning }
        // 机型/系统不支持设备端识别（SpeechTranscriber 有硬件要求）→ 明确报错，不要用不支持的语言去初始化
        guard SpeechTranscriber.isAvailable else {
            lastError = "此机型不支持设备端语音识别"
            diagnostics = "SpeechTranscriber.isAvailable=false"
            NSLog("[VOICE] 设备不支持设备端识别")
            return false
        }
        cancelRequested = false
        isPreparing = true
        defer { isPreparing = false }
        self.baseline = baseline
        finalizedText = ""
        volatileText = ""
        lastRecognizedText = ""
        volatileCount = 0
        finalCount = 0
        firstResultMs = -1
        // v3.9.9：采集三级计数归零 + 每秒刷到 UI（结果为零时尤其要看它）
        feeder.resetStats()
        pipeStats = ""
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRunning || self.isPreparing else { return }
                self.pipeStats = self.feeder.stats
            }
        }
        startedAt = Date()
        liveText = baseline
        lastError = nil
        needsPermission = false
        diagnostics = ""

        guard await Self.ensureMicrophonePermission() else {
            needsPermission = true
            lastError = "未获得麦克风权限"
            diagnostics = "mic=denied"
            NSLog("[VOICE] 麦克风权限未授予 → 不启动")
            return false
        }

        do {
            guard let locale = await Self.resolvedLocale() else {
                lastError = "系统没有可用的语音识别语言包"
                diagnostics = "supportedLocales 为空"
                return false
            }
            if cancelRequested { return false }   // 准备期间用户已取消
            let transcriber = SpeechTranscriber(locale: locale,
                                                transcriptionOptions: [],
                                                reportingOptions: [.volatileResults],
                                                attributeOptions: [])
            try await Self.ensureAssets(for: transcriber, locale: locale)
            if cancelRequested { return false }   // 模型下载期间用户已取消 → 不再启动
            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]
            ) else {
                lastError = "系统未提供可用的音频格式"
                diagnostics = "no analyzerFormat"
                return false
            }

            // 音频会话：沿用旧 VoiceRecorder 的最简基线（.record + .default）——
            // v3.0.85 引入 .voiceChat 后卡死、v3.1.4 的 .playAndRecord 也有问题，这里不再尝试那些
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                lastError = "麦克风输入不可用"
                diagnostics = "inputFormat=\(inputFormat.channelCount)ch/\(inputFormat.sampleRate)Hz"
                return false
            }
            if cancelRequested { return false }

            let (stream, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
            builder = inputBuilder
            feeder.prepare(converter: AVAudioConverter(from: inputFormat, to: analyzerFormat),
                           targetFormat: analyzerFormat,
                           builder: inputBuilder)

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer

            resultsFinished = false
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self else { return }
                        let piece = String(result.text.characters)
                        if self.firstResultMs < 0, let t0 = self.startedAt {
                            self.firstResultMs = Int(Date().timeIntervalSince(t0) * 1000)
                        }
                        if result.isFinal {
                            self.finalCount += 1
                            self.finalizedText += piece
                            self.volatileText = ""
                        } else {
                            self.volatileCount += 1
                            self.volatileText = piece
                        }
                        self.publish()
                    }
                } catch is CancellationError {
                    // 正常收尾（stop() 会取消这个任务）—— 不当错误
                } catch {
                    guard let self else { return }
                    NSLog("[VOICE] 结果流中断: \(error)")
                    self.lastError = "转写中断：\(error.localizedDescription)"
                    self.isRunning = false
                    self.teardown()   // 自愈：否则 UI 永远停在"录音中"
                    self.onError?("转写中断：\(error.localizedDescription)")
                }
                self?.resultsFinished = true
            }

            // ⚠️ 这行是"开始分析"的全部——官方语义是 **立即返回**（后台自主消费输入序列），
            // 所以它必须在装 tap 之前调用（先让分析器就绪，再灌音频）。
            try await analyzer.start(inputSequence: stream)

            // v3.9.9：**先让 analyzer 起来、再开麦克风**（对齐 Apple 官方示例顺序）。
            // 原来是反过来：tap 先开始灌音频、analyzer 后启动，音频先堆在 AsyncStream 里。
            // 官方示例是 "try await analyzer.start(inputSequence:) → startMic()"，照它来少一个变数。
            // 防御：极端情况下（上次异常退出）残留 tap 会让 installTap 抛异常
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            // 🚨 v3.9.4 关键：闭包**必须显式 @Sendable**。
            // 它写在 @MainActor 的 start() 里 —— 不加 @Sendable 的闭包字面量会**继承 MainActor 隔离**，
            // 而 AVAudioEngine 在**音频线程**回调它 ⇒ 进闭包即做隔离检查 → 失败 SIGTRAP（v3.9.3 真机
            // 「长按语音转文字立刻闪退」的根因，dSYM 符号化证实崩溃帧就是这个闭包）。
            // 编译期不报错、check_swift(-parse) 查不出（与 v3.7.0 剪贴板 completion 同类）。
            // @Sendable 后闭包成为非隔离闭包；闭包体只碰 @unchecked Sendable 的 feeder，安全。
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable [feeder] buffer, _ in
                feeder.feed(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            isRunning = true
            liveStalled = false
            stallTask?.cancel()
            stallTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.isRunning, self.volatileCount == 0, self.finalCount == 0 else { return }
                self.liveStalled = true
                NSLog("[VOICE] 录音 3s 仍无任何识别结果（实时出字未生效 → UI 会显示诊断串）")
            }
            diagnostics = "locale=\(locale.identifier(.bcp47)) fmt=\(analyzerFormat.sampleRate)Hz/"
                + "\(analyzerFormat.channelCount)ch(输入 \(inputFormat.sampleRate)Hz)"
            NSLog("[VOICE] 设备端转写启动 \(diagnostics)")
            return true
        } catch {
            NSLog("[VOICE] 启动失败: \(error)")
            lastError = error.localizedDescription
            diagnostics = "start failed: \(error.localizedDescription)"
            teardown()
            return false
        }
    }

    /// 结束并定稿，返回最终文本
    ///
    /// 重入保护：退出（exitVoiceMode）与取消（× 按钮）可能几乎同时发生，
    /// 两次并发进入会各自 finalize/publish，互相覆盖输入框内容 —— 共用同一个收尾任务。
    func stop() async -> String {
        if let stopTask { return await stopTask.value }
        let task = Task { @MainActor in await self.performStop() }
        stopTask = task
        let text = await task.value
        stopTask = nil
        return text
    }

    private func performStop() async -> String {
        guard isRunning || analyzer != nil || cancelRequested else { return liveText }
        if analyzer == nil { resultsFinished = true }   // 还没启动到 analyzer（准备期取消）→ 无需等结果
        isRunning = false
        builder?.finish()
        builder = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        // finalize 后 results 序列会结束并吐出最后一段定稿；等它落地（最多 1s），否则最后一句会丢
        var waited = 0
        while !resultsFinished && waited < 20 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        resultsTask?.cancel()
        resultsTask = nil
        let recognized = finalizedText + volatileText
        // 被取消 → 回填进入前的内容；正常结束 → 回填识别结果
        let text = cancelRequested ? baseline : baseline + recognized
        lastRecognizedText = cancelRequested ? "" : recognized
        teardown()
        finalizedText = ""
        volatileText = ""
        liveText = text
        onTextChange?(text)
        NSLog("[VOICE] 定稿 len=\(text.count) canceled=\(cancelRequested) finished=\(resultsFinished)")
        // v3.9.10 fix（审查抓到）：firstResultMs == -1 是「本次一个中间结果都没出」的哨兵，
        // 直接拼成 "first-1ms" 会被当成假耗时上报到服务端 —— 而这恰恰是要排查的那个故障
        // （volatileCount == 0）必然踩到的分支，等于在诊断数据里造假。
        let firstText = firstResultMs >= 0 ? "first\(firstResultMs)ms" : "first=无结果"
        diagnostics = diagnostics + " " + resultStats + " " + firstText
        return text
    }

    /// 放弃本次转写（回到进入前的输入框内容）
    /// v3.9.3：**准备期也有效**（首次下模型可能几十秒，期间用户点 × 必须能取消）——
    /// cancelRequested 会被 start() 的每个 await 之后检查到并中止启动。
    func cancel() async {
        cancelRequested = true
        if isRunning || analyzer != nil {
            _ = await stop()
        }
        liveText = baseline
        onTextChange?(baseline)
        NSLog("[VOICE] cancel（running=\(isRunning) preparing=\(isPreparing)）")
    }

    private func publish() {
        // v3.9.9：一旦有结果就不再是"卡住"状态（原来 liveStalled 一旦置位永不复位，
        // 界面会一直挂着 V0/F0 诊断串，反而误导排查）
        if liveStalled, volatileCount + finalCount > 0 { liveStalled = false }
        liveText = baseline + finalizedText + volatileText
        onTextChange?(liveText)
    }

    /// 停引擎 / 摘 tap / 释放 analyzer / 恢复音频会话（不恢复 .playback 会导致 TTS 无声——旧 VoiceRecorder 的教训）
    private func teardown() {
        statsTask?.cancel()
        statsTask = nil
        stallTask?.cancel()
        stallTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        feeder.invalidate()
        analyzer = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }
}
