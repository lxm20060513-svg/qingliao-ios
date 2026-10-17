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
    /// v4.0.x（2026-09-27 改口径）：长按菜单「拍照识别」——宿主拍完把照片交进来，**就地**让 AI 看图回答。
    /// 与「AI 识别」**同一套 cardSlot 内容**，差别只在起点与去向：
    ///   · 起点：图已在手（用户刚拍的），不像 AI 识别要先选图；
    ///   · 去向：自由文本回答**就地出卡**，不进会话、不切聊天页、不落 ChatStore。
    ///   · 呈现（2026-10-16 方案C 确认稿）：图已定 → 照片全屏铺底 + 底部玻璃面板；图未定 → 虚化 + 球上卡。
    /// nil（默认）= 原「AI 识别 / AI 翻译」流程一字不变。
    var photoAskImage: UIImage? = nil
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
        // v4.0.x「拍照识别」三段（照片已定 → 问 AI → **就地**出回答，不进会话）
        case askingPhoto                   // 照片已定，在等 AI 看完回答（扫描环继续转）
        case photoAnswer(String)           // AI 的看图回答：就地出卡
        case photoFailed(String)           // 没拿到回答：给「重拍 / 重试 / 关闭」，别静默退回选区
    }
    @State private var phase: Phase = .pick
    /// v3.9.79「AI 翻译」胶囊：为真时选图后**只取字 → 直接出译文**（不进 IntentActionBar）。
    /// 每次进浮层复位（onAppear），选中态可见（胶囊变「退出翻译」），错点一下能退回识别模式。
    @State private var translateMode = false
    /// v4.0.x「拍照识别」模式：本次进场由宿主带着照片来（`photoAskImage`）—— 之后选到图走 `askPhoto`
    /// 而不是 `recognize`（识别 / 翻译那两条链完全不参与）。
    @State private var photoAskMode = false
    /// 翻译失败后「重试」要用的原图（只在这一个流程里用，进浮层即清空）
    @State private var lastImage: UIImage?
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var appeared = false
    /// 第 11 项整改（用户 2026-10-18「把其它自绘浮层对齐到备忘录那套」）：
    /// 背景罩**独立相位** —— 罩走 `Motion.flow`（0.28s，先一步到位），
    /// 卡片与球心涟漪仍走 `appeared`（`Motion.emerge` 浮起）。改造前罩与卡共用一个硬编码
    /// `spring(0.42/0.78)`：罩和卡同时到场，读不出「背景先模糊、内容再浮起」的层次。
    @State private var scrimOn = false
    @State private var ringOut = false
    /// v4.0.x 方案C「全屏沉浸」：当前铺底的照片（拍照识别带进的 / AI 识别刚选的）。
    /// nil = 选图区，走老呈现（虚化 + 球心扫描环 + 球上方卡）；非 nil = 照片全屏铺底 + 底部玻璃面板。
    @State private var displayImage: UIImage?
    /// 铺底照片的来源标注（等待态左下小胶囊用；「重试」不传参 = 沿用上一次的来源）
    @State private var photoSourceLabel: String?
    /// 在途的看图请求（等待态「取消」要能掐掉，否则 120s 内既无可重选也无取消）
    @State private var askTask: Task<Void, Never>?
    /// 等待态不确定进度条的扫描位（时长不可知 → 光带来回扫表达「在跑」）
    @State private var barSweep = false
    /// 「复制」按下后的短暂确认态（胶囊文案变「已复制」1.6s）
    @State private var copiedAnswer = false
    @Environment(\.colorScheme) private var colorScheme

    /// 结果卡底边与球心之间留的呼吸（球半径 34 + 间距 26）
    private static let cardSpacing: CGFloat = 60

    var body: some View {
        GeometryReader { geo in
            let g = geo.frame(in: .global)
            let ball = absoluteBallCenter(in: g)
            ZStack {
                if let img = displayImage {
                    // v4.0.x 方案C：图已定 → 照片全屏铺底，等待/回答/失败都收进底部玻璃面板
                    // bottomInset：body 链 ignoresSafeArea 吃掉了安全区，底部要手动垫回去（审查 P1：
                    // 面板不垫 = 动作胶囊压进 home indicator 遮挡区，底部按钮可点性受损）
                    photoStage(img, size: geo.size, bottomInset: geo.safeAreaInsets.bottom)
                } else {
                    // 选图区：老呈现不动（虚化背景 + 球心扫描环 + 球上方卡）
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
                    if photoAskMode { photoSourceLabel = PhotoAskKit.sourceAlbum; askPhoto(img) } else { recognize(img) }
                } else {
                    // 加载失败分叉（审查 P2）：photoAsk 模式下别让「老照片铺底 + 没认出内容」同框——
                    // 用户刚选的新图没读出来，呈现成老图没认出是语义错位；退回选图区重新选。
                    if photoAskMode { displayImage = nil; phase = .pick } else { phase = .blank }
                }
                // 复位：同一张图连选两次也要能再次触发（否则 onChange 不响 =「点了没反应」）
                photoItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            // 相机内容必须 ignoresSafeArea：只换 fullScreenCover 容器不够，
            // 内容默认仍受安全区约束 → 顶部露出宿主黑边（v3.9.75 用户实测报「系统相机顶部有黑边」）
            CameraPicker { img in
                // v4.0.x：拍照识别模式（含卡里那颗「重拍」）走 askPhoto，别掉回「识别内容」那条链
                //（⚠️ 这行是 ql_orbmenu 真值表的逐字锚点，别改写；来源胶囊在 openCameraOrAlbum 处标）
                if photoAskMode { askPhoto(img) } else { recognize(img) }
            }
                .ignoresSafeArea()
        }
        // 浮层任何方式收起（点空白 / 宿主 onClose / 收起图片出口外的路径）都掐掉在途请求，
        // 与「取消」按钮同口径——不掐 = 在途看图请求白跑满 120s（审查 P2）
        .onDisappear {
            askTask?.cancel()
            askTask = nil
        }
        .onAppear {
            // v3.9.79：每次进浮层都从「识别模式」起手（AI 翻译模式不留到下一次，免得下次拍照莫名其妙出译文）
            // v3.9.82：例外 —— 译文弹窗里的「换一张」回来时宿主显式传 true（用户明确要接着翻，别再点一次「AI 翻译」）
            translateMode = startInTranslateMode
            // v4.0.x：宿主带照片进来 = 「拍照识别」就地看图模式（与翻译模式同一套「本次进场专用」口径）。
            // ⚠️ 宿主关浮层时必须把照片清掉（`identifyPhoto = nil`），否则下一次点普通「AI 识别」
            //   会莫名其妙又对上一张老照片提问（本仓「状态没复位 = 点了没反应」那一类坑）。
            lastImage = nil            // 上一轮的重试原图不留到下一次
            displayImage = nil         // 方案C：上一轮的全屏铺底照片也不留到下一次
            photoSourceLabel = nil
            if let img = photoAskImage {
                photoAskMode = true
                photoSourceLabel = PhotoAskKit.sourceCamera   // 宿主带进来的 = 刚拍的
                askPhoto(img)          // 内部会把 lastImage 设成这张（失败「重试」要用）——
                                       // ⚠️ 这行必须排在上面「清 lastImage」之后，否则刚存的原图被当场清掉
            }
            // 第 11 项：节拍对齐备忘录毛玻璃浮层（MemoGlassOverlay）—— 罩 `Motion.flow`、
            // 卡片 `Motion.emerge`。几何各自保留（本浮层的重心在智慧球，不强套 24pt 上浮，否则脱开球心）。
            if reduceMotion { appeared = true; scrimOn = true }
            else {
                withAnimation(Motion.flow) { scrimOn = true }
                withAnimation(Motion.emerge) { appeared = true }
            }
        }
        .onChange(of: phase) { _, newPhase in
            // 识别中 / 翻译中都算「忙」：环继续转（否则取字完到 AI 回译文这段环会突然停一下）
            if isBusy { startScanLoop() } else { ringOut = false }
            // 方案C：等待态换不确定进度条扫描（全屏铺底下没有球心环可转）
            if case .askingPhoto = newPhase { startBarSweep() }
            copiedAnswer = false
        }
    }

    /// 「忙」的两段（识别中 / 翻译中）：卡片文案各自不同，但扫描环这套视觉语言共用
    private var isBusy: Bool {
        if case .scanning = phase { return true }
        if case .translating = phase { return true }
        if case .askingPhoto = phase { return true }   // v4.0.x 拍照识别：等 AI 看图时环也要转
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
            .opacity(scrimOn ? 1 : 0)     // 第 11 项：罩跟自己的相位（flow），不跟卡片的 emerge
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

    // MARK: v4.0.x 方案C「全屏沉浸」看图台（2026-10-16 确认稿：照片全屏铺底 + 底部玻璃面板）
    //
    // 图已定 → 照片铺底（轻虚化，dark 下压暗一档保面板对比），等待/回答/失败收进底部面板；
    // 图未定（选图区）→ 老呈现。两条呈现共用同一套 cardSlot 内容，形态不分叉。
    // 点照片空白处 = 收起（与虚化背景「点空白即走」同口径）。

    private func photoStage(_ img: UIImage, size: CGSize, bottomInset: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .blur(radius: reduceMotion ? 0 : 3)
                .scaleEffect(reduceMotion ? 1 : 1.08)   // 吃掉 blur 贴边产生的透明毛边
                .overlay(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.06))
                .contentShape(Rectangle())               // 不补 contentShape，空白处点不到 = 收不起来（本仓已知坑）
                .onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: Spacing.md) {
                // 来源小胶囊只在等待态显示（设计稿元素：区分拍照识别 / AI 识别选图两个入口）
                if case .askingPhoto = phase, let src = photoSourceLabel {
                    sourceChip(src)
                }
                cardSlot
            }
            // 几何按确认稿：面板左右 26 / 底 24 + 安全区垫底（24 从安全区底起算，不压 home indicator）
            .padding(.horizontal, 26)
            .padding(.bottom, 24 + bottomInset)
        }
        .opacity(appeared ? 1 : 0)
    }

    /// 「来自相机 / 来自相册」来源胶囊
    private func sourceChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Typography.caption))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(.ultraThinMaterial, in: Capsule())
    }

    /// 等待态的不确定进度条：后端要跑工具循环，时长不可知 → 光带单向循环扫（减弱动态 = 静止半格）
    private var scanBar: some View {
        GeometryReader { gp in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.accentColor.opacity(Tint.coloredFill(colorScheme)))
                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: max(24, gp.size.width * 0.42))
                    .offset(x: barSweep ? gp.size.width * 0.62 : -gp.size.width * 0.12)
            }
        }
        .frame(height: 6)
        .clipped()
    }

    private func startBarSweep() {
        guard !reduceMotion else { barSweep = true; return }
        barSweep = false
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { barSweep = true }
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
        // v4.0.x「拍照识别」三段
        case .askingPhoto:
            askingPhotoCard
        case .photoAnswer(let text):
            photoAnswerCard(text)
        case .photoFailed(let detail):
            photoFailedCard(detail)
        }
    }

    private var pickRow: some View {
        VStack(spacing: Spacing.lg) {
            // photoAsk 模式（取消回答后回到这里）专属文案：这轮选图仍走「看图回答」，不认翻译/动作条
            //（审查 P2：通用文案 + AI 翻译胶囊在这模式下是「按钮承诺与实际路由不符」）
            Text(photoAskMode ? "拍一张或选一张，AI 看图回答（不进会话）"
                 : translateMode ? "拍一张或选一张，AI 直接给你译文"
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
                // photoAsk 模式不显示（onChange 里选图必走 askPhoto，翻译胶囊点了也翻不了）。
                if !photoAskMode {
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

    // MARK: v4.0.x「拍照识别」三段卡（2026-10-16 方案C 确认稿：底部玻璃面板形态）

    /// 照片已定，等 AI 看完回答：菊花 + 文案一行排布，下接扫描条 + 「取消」（120s 等待有了出口）
    private var askingPhotoCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                ProgressView().controlSize(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PhotoAskKit.waitingTitle).font(.system(size: Typography.subhead))
                    Text(PhotoAskKit.waitingDetail)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                }
            }
            scanBar
            Button(action: cancelAsk) {
                Text("取消").pill(.primary, tone: .neutral)
            }
        }
        .padding(Spacing.xxl)
        .overlayGlassCard()
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    /// AI 的看图回答 —— **就地出卡**（用户 2026-09-27：「不发送当前对话框，直接在当页做」）。
    /// 方案C 面板：标题头声明「AI 的回答」，长回答卡内滚动限高 240（不限高会把面板顶出屏幕），
    /// 动作 = 重拍 / 复制（剪贴板，不进会话）/ 收起图片（收掉全屏铺底回聊天）。
    private func photoAnswerCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PhotoAskKit.answerTitle).font(.system(size: Typography.subhead))
                Text(PhotoAskKit.answerDetail)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(text)
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)          // 想抄走就手动选，页里不主动发去会话
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            HStack(spacing: Spacing.xl) {
                Button { openCameraOrAlbum() } label: {
                    Text("重拍").pill(.primary, tone: .accent)
                }
                Button {
                    UIPasteboard.general.string = text
                    copiedAnswer = true
                    Haptics.success()
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.6))
                        copiedAnswer = false
                    }
                } label: {
                    Text(copiedAnswer ? "已复制" : "复制").pill(.primary, tone: .neutral)
                }
                Button { onClose() } label: {
                    Text("收起图片").pill(.primary, tone: .neutral)
                }
            }
        }
        .padding(Spacing.xxl)
        .overlayGlassCard()
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    /// 失败留在卡里（别静默退回选区）：真因可能是网络/后端没回/图没压好 —— 红色徽标 + 真因 + 重试
    private func photoFailedCard(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 22))
                Text(PhotoAskKit.failureTitle).font(.system(size: Typography.subhead))
            }
            Text(detail)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
            HStack(spacing: Spacing.xl) {
                Button {
                    guard let img = lastImage else { phase = .pick; return }
                    askPhoto(img)                     // 原图还在，直接重问一次（来源胶囊沿用上一次）
                } label: {
                    Text("重试").pill(.primary, tone: .accent)
                }
                Button { onClose() } label: {
                    Text("关闭").pill(.primary, tone: .neutral)
                }
            }
        }
        .padding(Spacing.xxl)
        .overlayGlassCard()
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    /// 「拍照识别」：把照片**就地**问 AI（非流式一问一答，与 AI 翻译同一条链，差别只在提示词与结果去向）。
    /// 图片走 base64 data URL（`ImageDownscale.dataURL`，与聊天页同一档压缩判据）——
    /// 图块构造仍只有 `ImageBlocks` 一个点，「绝不把自家 URL 交给上游」那条决策不受影响。
    /// v4.0.x 方案C：请求存进 `askTask`（等待态「取消」能掐掉）；来源胶囊在各入口处先行标注。
    private func askPhoto(_ image: UIImage) {
        guard phase != .askingPhoto else { return }      // 防连点：等回答时再拍一张不叠第二次
        lastImage = image                                // 失败「重试」要用
        displayImage = image                             // 方案C：图定即全屏铺底
        phase = .askingPhoto
        Haptics.tap()
        askTask = Task { @MainActor in
            let dataURL = await ImageDownscale.dataURL(from: image,
                                                       maxSide: ImageDownscale.currentMaxSide,
                                                       quality: ImageDownscale.currentQuality)
            guard let dataURL else {
                guard !Task.isCancelled else { return }  // 用户已取消：别把取消报成失败
                phase = .photoFailed(PhotoAskKit.failureDetail(nil))
                Haptics.press()
                return
            }
            do {
                let reply = try await QingliaoIntentClient.oneShot(PhotoAskKit.prompt,
                                                                  auth: auth,
                                                                  imageDataURL: dataURL,
                                                                  timeout: PhotoAskKit.timeout)
                // 空正文在这里不可达：`QingliaoIntentClient.oneShot` 已经先 `throw`
                //（「轻聊没有返回内容」）→ 走下面的 catch 显示真因；别再加一个「空回答」分支当摆设。
                guard !Task.isCancelled else { return }  // 回答回来前用户点了取消：丢弃，别顶掉选图区
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                phase = .photoAnswer(text)
                Haptics.success()
            } catch {
                guard !Task.isCancelled else { return }  // 取消引发的取消型错误不算失败
                phase = .photoFailed(PhotoAskKit.failureDetail(error))
                Haptics.press()
            }
        }
    }

    /// 等待态「取消」：掐掉在途请求、收掉全屏铺底，回到选图区（浮层不关，可直接重拍/换一张）
    private func cancelAsk() {
        askTask?.cancel()
        askTask = nil
        displayImage = nil
        photoSourceLabel = nil
        phase = .pick
    }

    // MARK: 选图 / 识别

    /// 无摄像头设备（模拟器 / 部分 iPad）走相册，否则 present .camera 会抛 NSInvalidArgumentException
    /// —— 与 ChatView v3.0.86 同一道闸，别在两处写出不同判据。
    private func openCameraOrAlbum() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            photoSourceLabel = PhotoAskKit.sourceCamera   // 方案C：来源胶囊在入口处标注（相机回调是逐字锚点，不动）
            showCamera = true
        } else {
            photoSourceLabel = PhotoAskKit.sourceAlbum
            showPhotoPicker = true
        }
    }

    private func recognize(_ image: UIImage) {
        guard phase != .scanning, phase != .translating else { return }   // 防连点：忙时再拍一张不叠第二次
        let translating = translateMode               // 先取值
        displayImage = image                          // 方案C：AI 识别/翻译选完图同样全屏铺底（两入口形态统一）
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
