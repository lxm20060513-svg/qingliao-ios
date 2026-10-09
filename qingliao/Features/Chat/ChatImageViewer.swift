// MARK: - 图片大图查看器（从 ChatComponents.swift 拆出）
import SwiftUI
import Photos

// MARK: - v2.0.36 图片大图查看器（双击/捏合缩放 + 保存相册）

struct ImageViewPayload: Identifiable {
    let id = UUID()
    let images: [UIImage]   // v2.0.62：全部图片消息（相册翻页）
    var index: Int
    // v3.4.29：zoom 转场源 id（被点气泡的消息 id）；空 = 不做转场（走系统默认呈现）
    var sourceID: String = ""
}

// MARK: - v3.4.29 图片 zoom 转场源修饰器
// iOS 18+ matchedTransitionSource 需与目标侧 .navigationTransition(.zoom(sourceID:in:)) 配对；
// ns 为空时原样返回（不参与转场）。抽成修饰器避免在每个图片分支写 if 分支。
struct ZoomSourceModifier: ViewModifier {
    let id: String
    let ns: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let ns {
            content.matchedTransitionSource(id: id, in: ns)
        } else {
            content
        }
    }
}

extension View {
    func zoomSource(id: String, ns: Namespace.ID?) -> some View {
        modifier(ZoomSourceModifier(id: id, ns: ns))
    }
}

// v2.0.62：相册式查看器——横向滑动翻页 + 每页双击/捏合缩放 + 保存
struct ImageViewer: View {
    let images: [UIImage]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss
    /// v4.0.83（用户 2026-10-09：「AI 发送的图片保存到相册功能不生效」）：
    /// 原实现 `UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)` —— 不申请授权、completion 传 nil。
    /// 用户此前若拒过相册权限（或系统不给弹框），该调用**静默失败**：点了没反应、相册里也没有，
    /// 从用户视角就是「功能不生效」。现在保存结果一律给可见提示。
    @State private var albumTip: String?
    @State private var savingToAlbum = false

    /// v4.0.86：图内二维码（用户 2026-10-09：「AI 发送的二维码要能长按识别跳 App」——微信式）
    /// nil = 还没识别过 / 没检出；非 nil = 检出了（isQR 才弹识别条）
    @State private var qrResult: QRCodeScanner.Result?
    @State private var qrTip: String?
    @State private var scanning = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(0..<images.count, id: \.self) { i in
                    ImageViewerPage(image: images[i])
                        .tag(i)
                        // v4.0.86：长按识别二维码（挂在每页上，翻页后 index 变、识别跟随当前页）
                        .onLongPressGesture(minimumDuration: 0.35) {
                            scanQR(at: i)
                        }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .onChange(of: index) { _, _ in
                // 翻页清掉上一页的识别结果（提示条别串页）
                qrResult = nil
                qrTip = nil
            }
            VStack {
                HStack {
                    if images.count > 1 {
                        Text("\(index + 1) / \(images.count)")
                            .font(.system(size: Typography.subhead, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, Spacing.xl)
                            .padding(.vertical, Spacing.xs)
                            // v4.0.61：图片上的悬浮控件改走原生玻璃出口（底是真实图片，玻璃才折射得出来）
                            .a11yGlass(.regular, in: Capsule(), stroke: .clear, fallback: Color.black.opacity(0.9))
                            .padding(.leading, Spacing.section)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: Typography.display))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(Spacing.section)
                }
                Spacer()
                Button {
                    saveToAlbum()
                } label: {
                    Label(savingToAlbum ? "保存中…" : "保存到相册", systemImage: "square.and.arrow.down")
                        .font(.system(size: Typography.body, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, Spacing.md)
                }
                .buttonStyle(.plain)
                // v4.0.61：玻璃从 label 的 background 移到 **Button 本身** ——
                // `interactive()` 只有作用在交互控件上才有按压反馈（挂在 background 上等于静态装饰，
                // 这是本仓 Pill / dock 的定版写法，别退回 background）
                .a11yGlass(.regular.interactive(), in: Capsule(), stroke: .clear, fallback: Color.black.opacity(0.9))
                .padding(.bottom, 44)
            }
            // v4.0.83：保存结果提示 —— 成功/失败都必须看得见（本仓口径：静默失败 = 用户眼里的「功能不生效」）
            if let albumTip {
                Text(albumTip)
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.section)
                    .padding(.vertical, Spacing.md)
                    .a11yGlass(.regular, in: Capsule(), stroke: .clear, fallback: Color.black.opacity(0.85))
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, 108)            // 让开下面那颗「保存到相册」
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            // v4.0.86：识别条（微信式）—— 检出二维码 → 底部弹「识别图中二维码」；纯文本码 → 文本+复制
            if let qr = qrResult, qr.isQR, let payload = qr.payloadString {
                HStack(spacing: Spacing.md) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: Typography.headline))
                        .foregroundStyle(.white)
                    Text("识别图中二维码")
                        .font(.system(size: Typography.body, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer(minLength: Spacing.xs)
                    Button {
                        openQR(payload)
                    } label: {
                        Text("识别").pill(.primary, tone: .accent)
                    }
                    .buttonStyle(PressStyle(scale: 0.96))
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.vertical, Spacing.lg)
                .a11yGlass(.regular.interactive(), in: Capsule(), stroke: .clear, fallback: Color.black.opacity(0.9))
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, 108)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .transition(.opacity)
            }
            // v4.0.86：扫码结果提示（打开回执 / 纯文本码 / 没检出）
            if let qrTip {
                Text(qrTip)
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, Spacing.section)
                    .padding(.vertical, Spacing.md)
                    .a11yGlass(.regular, in: Capsule(), stroke: .clear, fallback: Color.black.opacity(0.85))
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, 108)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.settle, value: albumTip)
        .animation(Motion.settle, value: qrResult)
        .animation(Motion.settle, value: qrTip)
    }

    // MARK: - v4.0.86 长按识别二维码

    /// 后台识别第 i 页图片。非阻断：识别中再长按直接忽略（scanning 闸）。
    ///
    /// ⚠️ Swift 6 实参序/并发口径（逐字沿用 IntentExtractor.scanImage 的实踩结论，-parse 查不出）：
    /// `UIImage` 非 Sendable，@Sendable 闭包直接捕获编译不过 →
    /// `nonisolated(unsafe)` 一次性交出（交出后主线程不再触碰），Vision 的同步 perform()
    /// 在全局队列跑，结果经 continuation 收回主 actor。
    private func scanQR(at i: Int) {
        guard !scanning else { return }
        scanning = true
        Haptics.tap()
        // v4.0.86（审查 P1-2）：冷却期别静默吞长按——先给「识别中…」，识别结果回来即被覆盖/清除
        qrTip = "识别中…"
        let image = images[i]
        nonisolated(unsafe) let img = image
        Task {
            let result = await withCheckedContinuation { (cont: CheckedContinuation<QRCodeScanner.Result?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: QRCodeScanner.detect(in: img))
                }
            }
            qrResult = result
            // v4.0.86（审查 P1-1）：提示条件从「没检出/非QR」收窄为「识别条不会出现」——
            // 检出二维码但 payload 是二进制（payloadString==nil）时识别条出不来，
            // 旧条件会让这种码完全静默。现在：无 payload 或非 QR 都给提示。
            let barWillShow = (result?.isQR == true && result?.payloadString != nil)
            if barWillShow {
                // 识别条出现 → 收掉「识别中…」，别让它常驻
                qrTip = nil
            } else {
                // 没检出 / 检出的是一维码（商品条码，跳不了 App）：轻提示一下就收
                //（别让用户猜长按有没有生效）。isQR 的那档走识别条，不进这里。
                qrTip = "未识别到二维码"
                try? await Task.sleep(for: .seconds(1.6))
                if qrTip == "未识别到二维码" { qrTip = nil }
            }
            scanning = false
        }
    }

    /// 点「识别」：URL 码跳对应 App（装了才跳，网页码落 Safari）；纯文本码弹内容+复制。
    private func openQR(_ payload: String) {
        Task {
            switch await QRCodeScanner.open(payload) {
            case .openedURL:
                Haptics.success()
                qrTip = nil
                qrResult = nil
            case .text(let txt):
                UIPasteboard.general.string = txt
                Haptics.success()
                qrTip = "码内容已复制：\n\(txt)"
                qrResult = nil
                try? await Task.sleep(for: .seconds(2.6))
                if qrTip?.hasPrefix("码内容已复制") == true { qrTip = nil }
            }
        }
    }

    /// v4.0.83：把当前页图片存进相册。
    ///
    /// 修的三处（用户报「保存到相册不生效」）：
    ///   ① **没有授权**：老 API 在「权限曾被拒/未决定」时会静默失败 → 现在先按 `.addOnly` 请求授权
    ///      （写相册只需这个，不必索取读权限，弹框文案也更轻）；
    ///   ② **没有回调**：completion 传 nil 时成功失败都无感知 → 现在成功/失败都给提示；
    ///   ③ 该老 API 走同步写盘，大图会卡一下 → 改走 PHPhotoLibrary 的异步写入（见 AlbumSaver）。
    private func saveToAlbum() {
        guard !savingToAlbum else { return }
        savingToAlbum = true
        let image = images[index]
        Task {
            do {
                try await AlbumSaver.save(image)
                Haptics.success()
                albumTip = "已存入相册"
            } catch AlbumSaver.Failure.denied {
                Haptics.error()
                albumTip = "没有相册权限：「设置 → 隐私与安全性 → 照片 → 轻聊」里选「添加照片」"
            } catch AlbumSaver.Failure.restricted {
                // v4.0.83：系统级限制（家长控制 / MDM 描述文件）用户自己改不了 → 不引导去设置，免得白折腾
                Haptics.error()
                albumTip = "相册访问被系统限制，暂时无法保存"
            } catch {
                Haptics.error()
                albumTip = "保存失败：\(error.localizedDescription)"
            }
            savingToAlbum = false
            // 2.6s 后自动收起（不长期挡住看图）
            try? await Task.sleep(for: .seconds(2.6))
            albumTip = nil
        }
    }
}

// 单图页：v3.9.27 双击/捏合缩放 + **放大后可随意拖动**（用户反馈：放大后不能拖动看边角）。
// 拖动只在 scale > 1 时生效；松手按边界夹紧回弹，拖不动时整体回中。
// 独立小 struct（本仓类级坑：深嵌套大 body 里塞手势易触发 CI type-check 超时）。
struct ImageViewerPage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    // 拖动偏移（pt 值）
    @State private var offset: CGSize = .zero
    // 拖动起点时的 offset 快照（手势 onChanged 里 translation + startOffset = 新位置；
    // 不冻结快照就会以「当前 offset」为基底逐帧累加 = 位移翻倍飞出）
    @State private var dragStartOffset: CGSize = .zero
    // 手势进行中标记（首帧冻结 dragStartOffset 用）
    @State private var dragging = false
    // 捏合进行中的基准值：MagnificationGesture 是增量值（从 1 开始），必须乘上当前 scale
    @State private var gestureBase: CGFloat = 1

    /// 当前缩放下允许的最大拖动距离：放大 N 倍时可视窗口外多出 (N-1)/2 倍宽/高
    /// v3.9.41（SR57）：改用容器尺寸——调用方全是 GeometryReader 的 geo.size，
    /// 原先写死 `UIScreen.main.bounds`：① iOS 26 已弃用该 API；② 屏幕 ≠ 本页容器，
    /// 转屏/分屏/安全区下边界会算多，图片拖出可视框还回不来。参数本来就传了，之前没被用上。
    private func maxOffset(size: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1 else { return .zero }
        // 显示尺寸按 scaledToFit 近似：图片以短边贴容器；用宽高各半的富余量夹紧
        let w = (size.width * (scale - 1)) / 2
        let h = (size.height * (scale - 1)) / 2
        return CGSize(width: max(0, w), height: max(0, h))
    }

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .animation(Motion.snap, value: scale)
                .animation(Motion.snap, value: offset)
                .gesture(MagnificationGesture()
                    .onChanged { value in
                        // 捏合起点以当前 scale 为基准（否则每次捏合都从 1 重算，先拖后捏会跳变）
                        if gestureBase == 1 { gestureBase = scale }
                        scale = max(1, min(gestureBase * value, 6))
                    }
                    .onEnded { _ in
                        gestureBase = 1
                        if scale <= 1.02 {   // 回缩到 ≈1 时一并归位（吸附）
                            scale = 1
                            offset = .zero
                        } else {
                            clampOffset(container: geo.size)
                        }
                    })
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            guard scale > 1 else { return }
                            if !dragging { dragging = true; dragStartOffset = offset }
                            // 跟手拖动：超出边界给 0.35 的阻尼（微信式橡皮筋）
                            let m = maxOffset(size: geo.size, scale: scale)
                            offset = CGSize(width: damped(value.translation.width + dragStartOffset.width, max: m.width),
                                            height: damped(value.translation.height + dragStartOffset.height, max: m.height))
                        }
                        .onEnded { _ in
                            dragging = false
                            clampOffset(container: geo.size)
                        })
                .onTapGesture(count: 2) {
                    if scale > 1 {
                        scale = 1
                        offset = .zero
                    } else {
                        scale = 2.2
                    }
                }
                .contentShape(Rectangle())
        }
    }

    private func damped(_ v: CGFloat, max m: CGFloat) -> CGFloat {
        if v > m { return m + (v - m) * 0.35 }
        if v < -m { return -m + (v + m) * 0.35 }
        return v
    }

    /// 松手后把 offset 夹回允许范围（越界部分回弹）
    private func clampOffset(container: CGSize) {
        let m = maxOffset(size: container, scale: scale)
        offset = CGSize(width: max(-m.width, min(m.width, offset.width)),
                        height: max(-m.height, min(m.height, offset.height)))
    }
}

// MARK: - v4.0.83 相册写入助手（界面侧「保存到相册」的唯一写入口）

/// 为什么单独抽一层：`PHPhotoLibrary.performChanges` 的变更块由 Photos 在**自己的后台队列**回调，
/// 闭包字面量若写在 `@MainActor` 上下文里会继承 MainActor 隔离 → 框架在后台队列上做隔离检查 → SIGTRAP
/// （v4.0.57 删相册真机必崩，符号化栈与详细推导见 Core/AgentActionExecutor.swift 的相册段头注）。
/// 解 = 把字面量放进 `nonisolated` 函数（不继承隔离，编译器也就不插那个检查）。
/// 护栏：scripts/check_framework_callback_isolation.py（RISKY 名单含 performChanges）。
///
/// 与 AgentActionExecutor.savePhoto 的关系：那条是 **AI 动作路径**（含 mutationGuard 确认闸与撤销），
/// 本条是 **界面路径**（用户点按钮，同步给提示）。底层写盘写法两条一致，改一处记得看另一处。
enum AlbumSaver {
    /// ⚠️ 实现 `LocalizedError`：否则 `error.localizedDescription` 落到通用 catch 只会显示「(Failure error 2.)」这类占位。
    /// `restricted` 单列：家长控制 / MDM 描述文件限制时用户**自己改不了**，提示不能说「去设置里打开权限」。
    enum Failure: Error, LocalizedError {
        case denied, restricted, encode

        var errorDescription: String? {
            switch self {
            case .denied:     return "没有相册权限"
            case .restricted: return "相册访问被系统限制"
            case .encode:     return "图片编码失败"
            }
        }
    }

    /// 存一张图到相册。成功即返回；失败抛 Failure 或 Photos 的原始错误。
    static func save(_ image: UIImage) async throws {
        // 只请求 .addOnly：写相册不需要读权限（别用 .readWrite 索要多余权限）
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        switch status {
        case .authorized, .limited:
            break
        case .restricted:
            throw Failure.restricted     // 系统限制，用户改不了 → 提示层要区别对待
        default:
            throw Failure.denied         // .denied / .notDetermined（刚被拒）
        }
        guard let data = image.jpegData(compressionQuality: 0.95) ?? image.pngData() else {
            throw Failure.encode
        }
        try await write(data)
    }

    /// ⚠️ 必须 nonisolated（原因见本 enum 头注；护栏脚本按这个关键字判定）
    private nonisolated static func write(_ data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: data, options: nil)
        }
    }
}

// MARK: - v2.0.36 会话导出文档（.txt）
