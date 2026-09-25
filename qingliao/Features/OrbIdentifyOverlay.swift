import SwiftUI
import PhotosUI
import UIKit

// MARK: - v3.9.76 智慧球「AI 识别」胶囊 → 球上悬浮结果层
//
// 用户要的：「长按智慧球增加 AI 识别和语音对话胶囊」；形态拍板 **变体 2**——
//   球留在原位 → 向外扩两圈扫描涟漪 → 结果卡浮在球上方，背景整体虚化。
//
// 刻意**不新造一套识别**（这是本文件最重要的设计约束）：
//   · 认内容：`IntentExtractor.extract(image:auth:)` —— 本机 OCR → 规则 → 端侧语义 → 云端兜底，
//     与聊天页「+ → 拍照 → 识别」是同一条管道，识别口径不会出现两个版本。
//   · 画结果 + 执行动作：直接嵌 `IntentActionBar` —— 类型徽标 / 动作胶囊 / 点即写 / 5 秒撤销 /
//     失败出声 / 低置信只给「问 AI · 复制」全都在里面，本文件一律不重写这些判断。
//   · 「问 AI」：动作条回调 → 宿主 post `.qingliaoTaskSend`（与任务中心、备忘录「发给 AI」
//     **同一条通道**）→ 文本以普通用户消息进入当前会话，后续对话上下文天然连贯。
//
// 本文件只负责「从球边起手 → 选图 → 扫描环 → 把结果卡摆到球上方」这一段**新形态**。
//
// v3.9.82（用户 2026-09-25「这个卡片改弹窗吧，跟 AI 速记弹窗一致」）：翻译拿到译文后**不在本层出卡**，
//   改为回调 `onTranslated` → 宿主弹 `TranslateSheet`（形态照 `QuickCaptureSheet` 抄）。
//   原来的「译文卡 + 限高 220 + 复制/换一张/发给AI」整套随之搬进那个文件；本层只剩 选图/识别/翻译中/失败。
//
// 几何：球心一律走 `DockOrbOverlay.orbCenterGlobal`（与可见球 / 长按菜单严格同源），
//       绝不在本文件里自己算等分（v3.9.59 的命中圈错位就是这么来的）。

struct OrbIdentifyOverlay: View {
    var barHeight: CGFloat
    var slotIndex: Int = 2
    var slotCount: Int = 5
    /// 「问 AI」交回宿主（宿主负责 post 通知 + 切聊天页；本层碰不到聊天流）
    var onAskAI: (String) -> Void
    /// v3.9.82：拿到译文立刻交回宿主弹「译文弹窗」（与 AI 速记同一形态）——本层不再渲染译文
    var onTranslated: (String, String) -> Void = { _, _ in }
    /// v3.9.82：「换一张」从译文弹窗回来时，直接以**翻译模式**起手（否则用户还得再点一次「AI 翻译」）
    var startInTranslateMode: Bool = false
    var onClose: () -> Void

    @Environment(AuthStore.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 状态机（`.result` 直接带意图 —— 卡片的全部内容都由它渲染，本层不解析字段）。
    /// v3.9.79 起翻译模式多两段：`.translating`（AI 在翻）/ `.translateFailed`（没拿到译文：
    /// 给「重试 / 换一张」，别静默退回选区）。
    /// v3.9.82：`.translated` **已删** —— 拿到译文即回调宿主弹 `TranslateSheet`，本层不再有译文态。
    private enum Phase: Equatable {
        case pick                          // 还没选图：拍照 / 相册
        case scanning                      // 识别中：扫描环加速
        case result(RecognizedIntent)       // 认出来了：交给 IntentActionBar
        case blank                         // 图里没认出可用内容（**不是**失败，文案别带报错口气）
        case translating                   // 翻译中：字已取到，在等 AI 回译文
        case translateFailed              // 没拿到译文：给「重试 / 换一张」，别静默退回选区
    }
    @State private var phase: Phase = .pick
    /// v3.9.79「AI 翻译」胶囊：为真时选图后**只取字 → 直接出译文**（不进 IntentActionBar）。
    /// 每次进浮层复位（onAppear），选中态可见（胶囊变「退出翻译」），错点一下能退回识别模式。
    @State private var translateMode = false
    /// 翻译失败后「重试」要用的原图（只在这一个流程里用，进浮层即清空）
    @State private var lastImage: UIImage?
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var appeared = false
    @State private var ringOut = false

    /// 结果卡底边与球心之间留的呼吸（球半径 34 + 间距 26）
    private static let cardSpacing: CGFloat = 60

    var body: some View {
        GeometryReader { geo in
            let g = geo.frame(in: .global)
            let ball = absoluteBallCenter(in: g)
            ZStack {
                backdrop
                scanRings(center: ball)
                // 卡片区：**底边对齐**到球上方 cardSpacing 处（用 alignment 而非 position 计算高度，
                // 卡片内容高度交给 SwiftUI 自适应——动作条的动作数量会变，写死高度必然裁切）
                cardSlot
                    .frame(width: geo.size.width,
                           height: max(0, ball.y - Self.cardSpacing),
                           alignment: .bottom)
                    .position(x: geo.size.width / 2,
                              y: max(0, ball.y - Self.cardSpacing) / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    recognize(img)
                } else {
                    phase = .blank
                }
                // 复位：同一张图连选两次也要能再次触发（否则 onChange 不响 =「点了没反应」）
                photoItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            // 相机内容必须 ignoresSafeArea：只换 fullScreenCover 容器不够，
            // 内容默认仍受安全区约束 → 顶部露出宿主黑边（v3.9.75 用户实测报「系统相机顶部有黑边」）
            CameraPicker { img in recognize(img) }
                .ignoresSafeArea()
        }
        .onAppear {
            // v3.9.79：每次进浮层都从「识别模式」起手（AI 翻译模式不留到下一次，免得下次拍照莫名其妙出译文）
            // v3.9.82：例外 —— 译文弹窗里的「换一张」回来时宿主显式传 true（用户明确要接着翻，别再点一次「AI 翻译」）
            translateMode = startInTranslateMode
            lastImage = nil            // 上一轮的重试原图不留到下一次
            if reduceMotion { appeared = true }
            else { withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { appeared = true } }
        }
        .onChange(of: phase) { _, _ in
            // 识别中 / 翻译中都算「忙」：环继续转（否则取字完到 AI 回译文这段环会突然停一下）
            if isBusy { startScanLoop() } else { ringOut = false }
        }
    }

    /// 「忙」的两段（识别中 / 翻译中）：卡片文案各自不同，但扫描环这套视觉语言共用
    private var isBusy: Bool {
        if case .scanning = phase { return true }
        if case .translating = phase { return true }
        return false
    }

    /// 球心（global → 本层局部）。同源 + 兜底同一个默认条高，别各自写一份。
    private func absoluteBallCenter(in g: CGRect) -> CGPoint {
        let barH = barHeight > 1 ? barHeight : DockOrbOverlay.fallbackBarHeight
        let c = DockOrbOverlay.orbCenterGlobal(slotIndex: slotIndex, slotCount: slotCount, barHeight: barH)
        return CGPoint(x: c.x - g.minX, y: c.y - g.minY)
    }

    // MARK: 背景虚化（用户拍板「虚化背景」）

    private var backdrop: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .contentShape(Rectangle())          // 不补 contentShape，空白处点不到 = 收不起来（本仓已知坑）
            .onTapGesture(perform: onClose)
            .opacity(appeared ? 1 : 0)
    }

    // MARK: 球心扫描涟漪（变体 2 的「正在识别」语义）

    private func scanRings(center: CGPoint) -> some View {
        ZStack {
            // 常驻柔光：与长按菜单同一套视觉语言（球心光晕，不做全屏磨砂）
            Circle()
                .fill(RadialGradient(colors: [Color.accentColor.opacity(0.26), .clear],
                                     center: .center, startRadius: 0, endRadius: 96))
                .frame(width: 200, height: 200)
                .scaleEffect(appeared ? 1 : 0.4)
            if isBusy {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .stroke(Color.accentColor.opacity(ringOut ? 0 : 0.45), lineWidth: 1.5)
                        .frame(width: 116 + CGFloat(i) * 54, height: 116 + CGFloat(i) * 54)
                        .scaleEffect(ringOut ? 1.22 : 0.86)
                }
            }
        }
        .position(center)
        .allowsHitTesting(false)      // 纯视觉层：绝不能吃触摸（否则卡片/空白收起的点击被它吞掉）
    }

    private func startScanLoop() {
        guard !reduceMotion else { ringOut = true; return }   // 减弱动态效果：留一圈静态环
        ringOut = false
        withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { ringOut = true }
    }

    // MARK: 球上方的操作区（四态）

    @ViewBuilder
    private var cardSlot: some View {
        switch phase {
        case .pick:
            pickRow
        case .scanning:
            scanningCard
        case .result(let intent):
            // 复用聊天页同一条动作条：口径完全一致（含撤销、失败红字、低置信降级）
            IntentActionBar(intent: intent,
                            onAskAI: { text in onAskAI(text) },
                            onClose: onClose)
        case .blank:
            blankCard
        case .translating:
            translatingCard
        case .translateFailed:
            translateFailedCard
        }
    }

    private var pickRow: some View {
        VStack(spacing: Spacing.lg) {
            Text(translateMode ? "拍一张或选一张，AI 直接给你译文"
                               : "拍一张或选一张，AI 认内容并给出可用动作")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
            HStack(spacing: Spacing.xl) {
                Button { openCameraOrAlbum() } label: {
                    Label("拍照", systemImage: "camera.fill").pill(.primary, tone: .accent)
                }
                Button { showPhotoPicker = true } label: {
                    Label("相册", systemImage: "photo.on.rectangle").pill(.primary, tone: .neutral)
                }
                // v3.9.79（用户拍板）：「AI 翻译」——点它进翻译模式，再拍照/选图 → 直接出译文（不给动作条）。
                // 翻译模式开着时这颗变「退出翻译」（accent = 特殊模式可见），错点一下就能退回识别。
                if translateMode {
                    Button { translateMode = false } label: {
                        Label("退出翻译", systemImage: "xmark").pill(.primary, tone: .accent)
                    }
                } else {
                    Button { translateMode = true } label: {
                        Label("AI 翻译", systemImage: "character.book.closed").pill(.primary, tone: .neutral)
                    }
                }
            }
        }
        .padding(.bottom, Spacing.xl)
    }

    private var scanningCard: some View {
        VStack(spacing: Spacing.md) {
            ProgressView().controlSize(.large)
            Text("正在识别…").font(.system(size: Typography.subhead))
            Text("本机 OCR 先出字，认不出的部分再走云端")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.xxl)
        // v3.9.78（用户「同口径也推到其它弹窗」）：与聊天页意图动作卡**同一口径** ——
        // 毛玻璃最薄档 `.ultraThinMaterial` + 圆角 `Radius.hero`(22) + 白 0.8pt 亮边，收在 `.overlayGlassCard()`。
        // 原口径 = `.regularMaterial` + `Radius.inset`(12) + `Color.primary.opacity(0.06)` 暗发丝线（实心卡观感）。
        .overlayGlassCard()
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.bottom, Spacing.xl)
    }

    private var blankCard: some View {
        VStack(spacing: Spacing.md) {
            Text("这张图里没认出可用内容")
                .font(.system(size: Typography.subhead))
            // ⚠️ 别在这写「或直接发给 AI 让它看」：这一层只有「重拍 / 换一张」两个按钮，
            //   而「问 AI」只出现在识别成功后的动作条里、且送的是**文本**发不了图 ——
            //   承诺一个用户找不到的入口。要走 AI 看原图，就退出后在聊天页用「+」发图。
            Text("换一张更清楚的，或退出后在聊天页发图给 AI")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
            HStack(spacing: Spacing.xl) {
                Button { phase = .pick; openCameraOrAlbum() } label: {
                    Text("重拍").pill(.primary, tone: .accent)
                }
                Button { phase = .pick; showPhotoPicker = true } label: {
                    Text("换一张").pill(.primary, tone: .neutral)
                }
            }
        }
        .padding(Spacing.xxl)
        // v3.9.78（用户「同口径也推到其它弹窗」）：与聊天页意图动作卡**同一口径** ——
        // 毛玻璃最薄档 `.ultraThinMaterial` + 圆角 `Radius.hero`(22) + 白 0.8pt 亮边，收在 `.overlayGlassCard()`。
        // 原口径 = `.regularMaterial` + `Radius.inset`(12) + `Color.primary.opacity(0.06)` 暗发丝线（实心卡观感）。
        .overlayGlassCard()
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.bottom, Spacing.xl)
    }

    // MARK: v3.9.79 AI 翻译三态（用户拍板：「译文别回聊天页，就地显示在球上方那张卡里」）

    private var translatingCard: some View {
        VStack(spacing: Spacing.md) {
            ProgressView().controlSize(.large)
            Text("正在翻译…").font(.system(size: Typography.subhead))
            Text("字已认出，正在让 AI 翻").font(.system(size: Typography.caption)).foregroundStyle(.secondary)
        }
        .padding(Spacing.xxl)
        .overlayGlassCard()
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.bottom, Spacing.xl)
    }

    // v3.9.82：译文卡**已删除** —— 整套（原文 2 行 / 玻璃卡内滚动译文 / 关闭·复制·换一张·发给AI）
    //   搬进 `Features/TranslateSheet.swift`，形态照 AI 速记弹窗（用户 2026-09-25 拍板）。
    //   🚫 别再往本文件加译文态卡片：译文一律回宿主弹窗（单一出口，防两套形态并存）。

    /// 失败也留在卡里：别静默退回选区让用户以为「拍糊了」（真原因可能是网络/后端没回）
    private var translateFailedCard: some View {
        VStack(spacing: Spacing.md) {
            Text("没拿到译文").font(.system(size: Typography.subhead))
            Text("网络或后端没回，可以重试一次").font(.system(size: Typography.caption)).foregroundStyle(.secondary)
            HStack(spacing: Spacing.xl) {
                Button {
                    guard let img = lastImage else { phase = .pick; return }
                    recognize(img)                     // 走同一条翻译链（不再重新 OCR 之前的图也还在）
                } label: {
                    Text("重试").pill(.primary, tone: .accent)
                }
                Button { restartTranslate() } label: {
                    Text("换一张").pill(.primary, tone: .neutral)
                }
            }
        }
        .padding(Spacing.xxl)
        .overlayGlassCard()
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.bottom, Spacing.xl)
    }

    /// 「换一张」：只把相册弹出来，**保留当前 phase**（用户点取消时原样回到刚看的那一步，
    /// 而不是掉回空白选区 —— 审查① 指出这会让「取消」变成丢内容）。
    /// v3.9.82：译文弹窗里那颗「换一张」走宿主（关弹窗 → 重开浮层 + 翻译模式），这一颗只留给
    ///          「翻译失败 / 没认出字」卡（重选一张图 = 最直接的补救）。
    private func restartTranslate() {
        translateMode = true
        showPhotoPicker = true
    }

    // MARK: 选图 / 识别

    /// 无摄像头设备（模拟器 / 部分 iPad）走相册，否则 present .camera 会抛 NSInvalidArgumentException
    /// —— 与 ChatView v3.0.86 同一道闸，别在两处写出不同判据。
    private func openCameraOrAlbum() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showCamera = true
        } else {
            showPhotoPicker = true
        }
    }

    private func recognize(_ image: UIImage) {
        guard phase != .scanning, phase != .translating else { return }   // 防连点：忙时再拍一张不叠第二次
        let translating = translateMode               // 先取值
        phase = .scanning
        Haptics.tap()
        Task { @MainActor in
            // v3.9.79「AI 翻译」分支（用户拍板：**就地出译文，不回聊天页**）
            //   OCR 只取字 → 交给后端一问一答（非流式，与 App 内「问 AI」同一条 /api/stream/chat）
            //   → v3.9.82 起译文回宿主弹窗显示（本层不再出卡）。
            // ⚠️ 刻意**不走** IntentExtractor.extract：那条路没字时会去叫云端视觉模型，
            //    会把「做个总结」之类的内容塞进译文提示词里。
            if translating {
                lastImage = image                     // 失败「重试」要用
                let text = await IntentExtractor.ocrText(in: image)
                let source = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty else {
                    // 与识别模式同一口径：没认出字 ≠ 失败，走 blank 卡（可重拍/换一张），翻译模式保持
                    phase = .blank
                    Haptics.press()
                    return
                }
                phase = .translating
                do {
                    // v3.9.79b：翻译这条链**不需要**后端的工具循环，默认 120s 超时意味着最坏情况下
                    // 这张卡 2 分钟内既无可重选也无取消（唯一出路是点空白关浮层）。翻译只要一问一答 → 30s。
                    let reply = try await QingliaoIntentClient.oneShot(TranslateKit.prompt(for: source),
                                                                      auth: auth, timeout: 30)
                    // v3.9.82（用户「这个卡片改弹窗吧，跟 AI 速记弹窗一致」）：译文不在本层渲染 ——
                    // 交回宿主弹 `TranslateSheet`；宿主在回调里同时收起本浮层（phase 停在 .translating
                    // 无妨，整个浮层随即被移除）。
                    Haptics.success()
                    onTranslated(source,
                                 reply.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    // 失败留在卡里（别静默退回选区，那会被当成「拍糊了」）
                    phase = .translateFailed
                    Haptics.press()
                }
                return
            }
            let found = await IntentExtractor.extract(image: image, auth: auth)
            if let found {
                phase = .result(found)
                Haptics.success()
            } else {
                // 没认出 ≠ 失败：给「重拍 / 换一张 / 发给 AI」，不当成错误报红
                phase = .blank
                Haptics.press()
            }
        }
    }
}
