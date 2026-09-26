import SwiftUI

// MARK: - v4.0.x 会话纪要页：现场长录音 → 设备端转写 → AI 整理 → 存备忘 + 往当前会话插一张纪要卡
//
// 入口：`MeetingMinutesView()`（**无参**，另一个 agent 从 fullScreenCover 呈现；页内自带 dismiss）。
//
// 三条硬口径（改动前先读）：
//   ① **按段渲染**：录音中只重绘「已定稿段 + 当前尾巴」（MinutesKit.MinutesSegments），
//      绝不 `Text(liveText)` 整篇重绘 —— 长录音下那是每秒把几千字重排一遍。
//   ② **不静默失败**：无权限 / 起麦失败 / 机型不支持 / 没识别到内容 / 整理失败 / 超长，
//      每一种都有明确文案 + 「重试」入口（文案全在 MinutesKit，这里只管摆）。
//   ③ **不丢已转写内容**：中途关掉 / 整理失败，都给「存原文备忘」这条退路（文字先落地）。
//
// 摘要链路：`QingliaoIntentClient.oneShot`（复用既有非流式一问一答，120s 上限）。
// 长转写由 MinutesKit 切片走 map-reduce：每片一条 map 提示词 + 最后一条 reduce 汇总（N 片 = N+1 次调用）。

@MainActor
struct MeetingMinutesView: View {

    @Environment(\.dismiss) private var dismiss

    /// 设备端转写器（与聊天页/语音对话页同一个类；本页只读 liveText 之外的发布态）
    @StateObject private var liveSpeech = LiveSpeechTranscriber()

    @State private var phase: Phase = .preparing
    /// onAppear 会被重复调用，起麦只许一次
    @State private var didBegin = false
    /// 防连点（起麦 / 停录 / 退出都是异步的）
    @State private var busy = false
    /// 用户在整理途中退到「已停止」：后续的存备忘 / 发卡都不做了，但文字留着
    @State private var abandoned = false

    /// 分段状态机：已定稿段只增不改（按段渲染的数据源）
    @State private var segments = MinutesKit.MinutesSegments.empty
    @State private var startedAt: Date?
    /// 停录后定格的时长（停止之后不再走秒）
    @State private var elapsed: TimeInterval = 0
    /// 定稿全文（stop() 返回串与自累积串取更全的那份）
    @State private var rawTranscript = ""

    @State private var progress = Progress()
    @State private var summary: MinutesKit.Summary?
    @State private var failureText: String?
    @State private var startFailure: StartFailure?
    /// 轻提示（分段有几段没整理 / 已存原文备忘）
    @State private var notice: String?
    @State private var savedMemo = false
    @State private var savedRawMemo = false
    @State private var postedCard = false

    /// 段列表滚到底用的锚点
    private let bottomAnchor = "minutes-transcript-bottom"

    // MARK: - 页面阶段

    enum Phase: Equatable {
        case preparing      // 起麦中
        case recording      // 录音中
        case stopped        // 已停录，正在收尾
        case summarizing    // 整理中
        case done           // 整理完成（已存备忘 / 已发卡）
        case failed         // 明确失败（起不来 / 空 / 抽不出 / 超长 / 用户停下）
    }

    /// 起麦失败的三类原因（文案不同，处理不同）
    enum StartFailure: Equatable {
        case denied         // 没权限
        case unsupported    // 机型/系统不支持设备端识别
        case unknown(String)

        var hint: String {
            switch self {
            case .denied: return MinutesKit.micDeniedHint
            case .unsupported: return MinutesKit.unsupportedHint
            case .unknown(let reason): return MinutesKit.failedHint(reason.isEmpty ? nil : reason)
            }
        }
    }

    /// 整理进度（第几段 / 共几段）
    struct Progress: Equatable {
        var done = 0
        var total = 0
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            actions
        }
        .glassPageBackground()
        // 录音/整理中不许手滑划走（要退就点右上角 ✕，那条路会把文字留下）
        .interactiveDismissDisabled(phase == .recording || phase == .summarizing)
        .onAppear {
            guard !didBegin else { return }
            Task { await begin() }
        }
        .onDisappear {
            // 退出必然停麦：不停的话状态栏麦克风一直红着（全仓语音红线）
            Task { await liveSpeech.cancel() }
        }
    }

    // MARK: - 头部

    private var header: some View {
        PageHeader(title: "会话纪要", subtitle: subtitleText, trailing: AnyView(closeButton))
    }

    private var subtitleText: String {
        switch phase {
        case .preparing: return "正在准备设备端识别…"
        case .recording: return "正在录 · 说完点「停止并整理」"
        case .stopped: return "正在收尾…"
        case .summarizing: return "正在整理（第 \(max(1, progress.done + 1))/\(max(1, progress.total)) 段）"
        case .done: return savedMemo ? MinutesKit.memoSavedHint : "已整理完成"
        case .failed: return "没能完成"
        }
    }

    private var closeButton: some View {
        Button {
            closeTapped()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: Typography.subhead, weight: .semibold))
                .frame(width: 15, height: 15)
                .padding(Spacing.md)
                .glassPillStroke()
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preparing:
            preparingView
        case .recording, .stopped:
            recordingView
        case .summarizing:
            summarizingView
        case .done:
            doneView
        case .failed:
            failedView
        }
    }

    private var preparingView: some View {
        VStack(spacing: Spacing.section) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("正在准备设备端识别…")
                .font(.system(size: Typography.body))
            Text("首次使用要下载语音模型，可能要几十秒。")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordingView: some View {
        VStack(spacing: 0) {
            meterRow
            transcriptList
        }
    }

    /// 计时 / 字数 / 音量（音量单独一小块按 0.06s 刷新，整页不为它重排）
    private var meterRow: some View {
        HStack(spacing: Spacing.md) {
            timerTag
            textTag(MinutesKit.countText(segments.charCount))
            Spacer(minLength: Spacing.md)
            LevelBars(level: { liveSpeech.currentInputLevel() }, active: phase == .recording)
                .frame(width: 58, height: 22)
        }
        .padding(.horizontal, Spacing.sheetInset)
        .padding(.vertical, Spacing.xxl)
    }

    /// 计时：录音中按 1s 走（只有这一小块重绘），停录后定格
    private var timerTag: some View {
        Group {
            if phase == .recording, let startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    tagView("waveform", MinutesKit.clockText(ctx.date.timeIntervalSince(startedAt)))
                }
            } else {
                tagView("waveform", MinutesKit.clockText(elapsed))
            }
        }
    }

    private func textTag(_ text: String) -> some View {
        tagView("textformat", text)
    }

    /// 展示用小标签：淡底胶囊（**不上玻璃** —— 玻璃只给交互控件，见 Pill.swift 头注）
    private func tagView(_ icon: String, _ text: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: Typography.tiny))
            Text(text)
                .font(.system(size: Typography.caption, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(Color.secondary.opacity(Tint.subtle), in: Capsule())
    }

    /// 转写按**段**渲染：已定稿段（只增不改）+ 当前尾巴（会反复重写的那句）
    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    if segments.closed.isEmpty && segments.open.isEmpty {
                        Text("开始说吧，文字会一句句落在这里。")
                            .font(.system(size: Typography.body))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(segments.closed.enumerated()), id: \.offset) { idx, line in
                        segmentRow(idx + 1, line, isOpen: false)
                    }
                    if !segments.open.isEmpty {
                        segmentRow(segments.closed.count + 1, segments.open, isOpen: true)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.vertical, Spacing.xl)
            }
            .onChange(of: segments.closed.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
        }
    }

    private func segmentRow(_ index: Int, _ text: String, isOpen: Bool) -> some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            Text("\(index)")
                .font(.system(size: Typography.tiny, weight: .medium))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(width: 20, alignment: .trailing)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: Typography.body))
                .foregroundStyle(isOpen ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }

    private var summarizingView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.md) {
                    ProgressView()
                    Text("正在整理（第 \(max(1, progress.done + 1))/\(max(1, progress.total)) 段）")
                        .font(.system(size: Typography.body, weight: .medium))
                    Spacer()
                }
                Text("长录音会先分段看，再汇总成一份纪要。现在关掉也会把原文给你留着。")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            .padding(Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardCard()
            .padding(.horizontal, Spacing.sheetInset)
            .padding(.top, Spacing.xl)

            transcriptList
        }
    }

    private var doneView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                if let summary {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        Text(summary.theme)
                            .font(.system(size: Typography.headline, weight: .semibold))
                        HStack(spacing: Spacing.md) {
                            tagView("clock", MinutesKit.durationText(summary.duration))
                            textTag(MinutesKit.countText(summary.charCount))
                            tagView("checklist", MinutesKit.todoText(summary.todoCount))
                        }
                        Divider().opacity(0.4)
                        Text(summary.body)
                            .font(.system(size: Typography.body))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(Spacing.section)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dashboardCard()
                }
                memoTip
                if let notice { noticeTip(notice) }
            }
            .padding(Spacing.sheetInset)
        }
    }

    /// 「已存备忘」指向（存成功才有指向；失败就说清没存上）
    private var memoTip: some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: savedMemo ? "tray.full.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(savedMemo ? Color.accentColor : Color.orange)
            Text(savedMemo ? MinutesKit.memoSavedHint : "纪要没能存进备忘，可以点「再录一次」重来。")
                .font(.system(size: Typography.subhead))
                .frame(maxWidth: .infinity, alignment: .leading)
            if postedCard {
                Text("已放进会话")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(Tint.faint), in: RoundedRectangle(cornerRadius: Radius.inset))
    }

    private var failedView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(alignment: .top, spacing: Spacing.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(failureText ?? MinutesKit.startFailedHint)
                        .font(.system(size: Typography.body))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let reason = liveSpeech.lastError, !reason.isEmpty, startFailure == nil {
                    Text("底层信息：\(reason)")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.secondary)
                }
                if segments.charCount > 0 {
                    Text("已转写 \(MinutesKit.countText(segments.charCount))，下面这些字不会丢。")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardCard()
            .padding(.horizontal, Spacing.sheetInset)
            .padding(.top, Spacing.xl)

            if segments.charCount > 0 {
                transcriptList
            } else {
                Spacer()
            }

            if let notice { noticeTip(notice).padding(.horizontal, Spacing.sheetInset) }
        }
    }

    private func noticeTip(_ text: String) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: Typography.caption))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(Tint.faint), in: RoundedRectangle(cornerRadius: Radius.inset))
    }

    // MARK: - 底部操作

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: Spacing.lg) {
            switch phase {
            case .preparing:
                smallButton("取消") { closeTapped() }
            case .recording:
                mainButton("停止并整理", icon: "stop.circle.fill") {
                    Task { await stopRecording() }
                }
                smallButton("取消录音") {
                    Task { await cancelRecording() }
                }
            case .stopped, .summarizing:
                smallButton("关掉（保留原文）") { closeTapped() }
            case .done:
                mainButton("再录一次", icon: "arrow.clockwise") { restart() }
                smallButton("关掉") { dismiss() }
            case .failed:
                mainButton("重试", icon: "arrow.clockwise") { retry() }
                if segments.charCount > 0 && !savedRawMemo {
                    smallButton("存原文备忘") { saveRawMemo() }
                }
                smallButton("关掉") { dismiss() }
            }
        }
        .padding(.horizontal, Spacing.sheetInset)
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.section)
    }

    private func mainButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.press()
            action()
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                Text(title)
            }
            .frame(maxWidth: .infinity)
            .pill(PillSize.primary, tone: .accent)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .pill(PillSize.topBar, tone: .neutral)
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }

    // MARK: - 起手：权限 → 起麦（每一步失败都有明确出口）

    private func begin() async {
        guard !didBegin, !busy else { return }
        busy = true
        didBegin = true
        phase = .preparing
        startFailure = nil
        failureText = nil
        notice = nil

        // 转写回调：只增不改地累积分段（phase 一离开 .recording 就不再收 —— 停录后文本要冻结）
        liveSpeech.onTextChange = { text in
            guard phase == .recording || phase == .preparing else { return }
            segments = MinutesKit.advance(segments, with: text)
        }
        liveSpeech.onError = { msg in
            // 转写中途报错不打断整段录音：文字有多少留多少（真起不来那步已经在下面判了）
            notice = msg.isEmpty ? nil : "识别中途出过问题：\(msg)"
        }

        guard await LiveSpeechTranscriber.ensureMicrophonePermission() else {
            startFailure = .denied
            failureText = StartFailure.denied.hint
            phase = .failed
            busy = false
            return
        }

        let started = await liveSpeech.start(baseline: "")
        guard started else {
            let failure = classifyStartFailure()
            startFailure = failure
            failureText = failure.hint
            phase = .failed
            busy = false
            return
        }

        startedAt = Date()
        elapsed = 0
        phase = .recording
        busy = false
    }

    /// 起麦失败归因（用转写器自己给出的诊断，不靠猜）
    private func classifyStartFailure() -> StartFailure {
        if liveSpeech.needsPermission { return .denied }
        if liveSpeech.diagnostics.contains("isAvailable=false") { return .unsupported }
        return .unknown(liveSpeech.lastError ?? "")
    }

    // MARK: - 停录 → 整理

    private func stopRecording() async {
        guard phase == .recording, !busy else { return }
        busy = true
        phase = .stopped
        elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        let stopped = await liveSpeech.stop()
        // 定稿文本取 stop() 返回串与自累积串里更全的那份（volatile 重写偶发丢尾 → 一律取长）
        rawTranscript = MinutesKit.bestTranscript(stopped, segments.text)
        // 页面上也按定稿全文重算一次分段：显示的就是要送去整理的
        if rawTranscript.count > segments.text.count {
            segments = MinutesKit.segments(of: rawTranscript)
        }
        busy = false
        await summarize()
    }

    /// 整理：短转写 1 次调用；超长由 MinutesKit 切片后 map-reduce（N 片 = N+1 次）
    private func summarize() async {
        guard !busy else { return }
        busy = true
        abandoned = false
        failureText = nil
        notice = nil

        let transcript = rawTranscript.isEmpty ? segments.text : MinutesKit.bestTranscript(rawTranscript, segments.text)
        rawTranscript = transcript

        // 空 / 超长：判一次就定，别把空串或 6 万字整篇送进模型
        let state = MinutesKit.state(of: transcript)
        if state != .ok {
            failureText = MinutesKit.hint(for: state) ?? MinutesKit.emptyTranscriptHint
            phase = .failed
            busy = false
            return
        }

        phase = .summarizing
        let plan = MinutesKit.plan(for: transcript)
        progress = Progress(done: 0, total: plan.askCount)

        let auth: AuthStore
        do {
            auth = try QingliaoIntentClient.auth()
        } catch {
            failureText = MinutesKit.loginHint
            phase = .failed
            busy = false
            return
        }
        // 先把 auth 挂上：备忘 add() 时要靠它同步到 NAS
        MemoStore.shared.attach(auth: auth)

        var partials: [String] = []
        var failedChunks = 0
        var lastReason: String?

        for (index, prompt) in plan.mapPrompts.enumerated() {
            if abandoned { busy = false; return }
            do {
                let answer = try await QingliaoIntentClient.oneShot(prompt, auth: auth, timeout: MinutesKit.mapTimeout)
                partials.append(answer)
            } catch {
                failedChunks += 1
                lastReason = error.localizedDescription
            }
            progress.done = index + 1
        }

        if abandoned { busy = false; return }
        guard !partials.isEmpty else {
            failureText = MinutesKit.failedHint(lastReason)
            phase = .failed
            busy = false
            return
        }

        var raw = partials[0]
        if plan.needsReduce {
            do {
                raw = try await QingliaoIntentClient.oneShot(MinutesKit.reducePrompt(partials: partials),
                                                            auth: auth,
                                                            timeout: MinutesKit.reduceTimeout)
            } catch {
                // 汇总失败不把等来的东西丢光：各段要点原样拼上（页面还会提示有几段没成）
                raw = partials.joined(separator: "\n\n")
                failedChunks += 1
                lastReason = error.localizedDescription
            }
            progress.done += 1
        }

        if abandoned { busy = false; return }
        guard let made = MinutesKit.summary(raw: raw, duration: elapsed, charCount: transcript.count) else {
            failureText = MinutesKit.emptySummaryHint
            phase = .failed
            busy = false
            return
        }

        summary = made
        // ① 存备忘（来源 = 会议纪要；MemoStore 自己落 memos.json 并同步 NAS）
        savedMemo = MemoStore.shared.add(content: MinutesKit.memoText(made), source: MinutesKit.memoSrc)
        // ② 往当前会话插一张纪要卡（通知由聊天页接，插的是本地卡、不进模型上下文）
        let card = MinutesKit.cardText(made)
        if !card.isEmpty {
            NotificationCenter.default.post(name: Notification.Name.qingliaoMinutesCard, object: card)
            postedCard = true
        }
        if failedChunks > 0 { notice = MinutesKit.partialHint(failedChunks) }

        phase = .done
        busy = false
        Haptics.success()
    }

    // MARK: - 取消 / 退出 / 重来

    /// 右上角 ✕：录音中 = 停麦但把文字留下；整理中 = 放弃结果但把原文留下；其它 = 直接关
    private func closeTapped() {
        switch phase {
        case .recording:
            Task { await cancelRecording() }
        case .stopped, .summarizing:
            abandoned = true
            failureText = MinutesKit.cancelledHint
            phase = .failed
        default:
            dismiss()
        }
    }

    /// 中途取消：**不丢已转写文字** —— 有字就进「已停止」态给「存原文备忘」这条退路
    private func cancelRecording() async {
        guard !busy else { return }
        busy = true
        await liveSpeech.cancel()
        elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        // cancel() 会把 liveText 回填成 baseline（""），所以真源只能是页面自累积的分段
        rawTranscript = MinutesKit.bestTranscript("", segments.text)
        busy = false
        if MinutesKit.state(of: rawTranscript) == .ok {
            failureText = MinutesKit.cancelledHint
            phase = .failed
            Haptics.tap()
        } else {
            dismiss()
        }
    }

    /// 转写失败/取消后的退路：把原文存成备忘（至少文字不丢）
    private func saveRawMemo() {
        let text = rawTranscript.isEmpty ? segments.text : rawTranscript
        guard MinutesKit.isUsableTranscript(text) else {
            notice = MinutesKit.emptyTranscriptHint
            return
        }
        // 没登录也要能存本地：auth 拿不到就不挂，add() 仍会落本地
        if let auth = try? QingliaoIntentClient.auth() { MemoStore.shared.attach(auth: auth) }
        let stored = MemoStore.shared.add(content: MinutesKit.rawMemoText(text, duration: elapsed), source: MinutesKit.memoSrc)
        savedRawMemo = stored
        // 存上了才说存上了（add 自己会挡空串/5 分钟内重复）
        notice = stored ? MinutesKit.rawMemoSavedHint : MinutesKit.emptyTranscriptHint
        if stored { Haptics.success() } else { Haptics.error() }
    }

    /// 整理失败后的重试：转写还在就重跑整理，没录上就重新起麦
    private func retry() {
        if MinutesKit.state(of: rawTranscript) == .ok {
            Task { await summarize() }
        } else {
            didBegin = false
            startFailure = nil
            failureText = nil
            notice = nil
            Task { await begin() }
        }
    }

    /// 「再录一次」：清空本次状态重新起麦（上一次的纪要已经存进备忘/会话了）
    private func restart() {
        summary = nil
        failureText = nil
        startFailure = nil
        notice = nil
        savedMemo = false
        savedRawMemo = false
        postedCard = false
        abandoned = false
        busy = false
        segments = MinutesKit.MinutesSegments.empty
        rawTranscript = ""
        elapsed = 0
        startedAt = nil
        progress = Progress()
        didBegin = false
        phase = .preparing
        Task { await begin() }
    }
}

// MARK: - 音量指示：只在自己这一小块按 0.06s 取电平重绘
//
// 电平走 `currentInputLevel()`（**故意不是 @Published**，见 LiveSpeechTranscriber 头注）——
// 若把电平发布出去，整页 body（含分段列表）会跟着每 0.06s 重排一次，长录音必卡。
@MainActor
private struct LevelBars: View {

    let level: @MainActor () -> Float
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barHeights: [CGFloat] = [6, 11, 16, 11, 6]

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 0.4 : 0.06)) { _ in
            let value = active ? CGFloat(min(1, max(0, level()))) : 0
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(barHeights.enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.25 + 0.6 * Double(value)))
                        .frame(width: 3, height: max(3, height * (0.35 + 0.65 * value)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}
