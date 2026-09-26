import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// 分享扩展的**取数 + 发送**逻辑（UI 只负责展示，逻辑集中在这里，便于逐条对照真机行为）。
///
/// 数据流（协议定义见 `ShareLinkCodec`）：
///   系统分享 → 本模型读出内容 → 用户确认/补充说明 → ① 需要时写剪贴板 ② 尽力 `open` 唤起轻聊
///   → 主 App 侧 `ShareIntake` 落成当前会话里的一条用户消息。
@MainActor
@Observable
final class ShareComposeModel {

    // MARK: - 状态机（每个状态都有对应 UI，没有「占位」态）

    enum Phase: Equatable {
        /// 正在读系统给过来的内容
        case loading
        /// 内容就绪，等用户点「发送到轻聊」
        case ready
        /// 系统没给可用内容（带原因文案，只留「取消」）
        case empty(String)
        /// 正在写剪贴板 / 尽力唤起主 App
        case sending
        /// 已交给轻聊（主 App 会自己接住，界面短暂提示后自动收起）
        case handedOff
        /// 扩展拉不起宿主 App（iOS 18+ 系统限制）→ 内容已在剪贴板，等用户手动打开轻聊
        case needsManualOpen(String)
    }

    // MARK: - 对外可读状态

    private(set) var phase: Phase = .loading
    /// 分享进来的正文（文本 / 链接）。链接**原样**保留，不做任何"美化"
    private(set) var text = ""
    /// 来源标题（`NSExtensionItem.attributedTitle`，网页标题等来源名；可空）
    private(set) var sourceName: String?
    /// 分享进来的图片（已按档位下采样；发送时再编成 JPEG 字节）
    private(set) var image: UIImage?
    /// 用户补充说明（可编辑；随消息一起发出，空 = 只发内容本身）
    var note = ""

    /// 「已交给轻聊」后的退场回调（由 VC 注入：先让用户看见状态再收起面板）
    var onHandedOff: (@MainActor () -> Void)?

    // MARK: - 内部

    /// 去重令牌：URL 与剪贴板两条通道共用同一个值（主 App 侧据此只处理一次）
    private let token = ShareLinkCodec.newID()
    /// 宿主上下文（`send` 里尽力唤起主 App 用）。**只在主线程上触碰**，不跨并发域传递
    private var context: NSExtensionContext?
    /// 还在等回调的 provider 数（读完了才从 loading 进 ready / empty）
    private var pending = 0
    /// 只收第一张图、第一份文本（规则见 `load`）
    private var didTakeImage = false
    private var didTakeText = false

    // MARK: - 档位（不写魔法值）

    /// provider 全都没回调时的兜底时限：别让界面永远停在「正在读取」
    private static let loadTimeout: Duration = .seconds(3)

    // MARK: - 取数

    /// 从系统给来的 items 里读内容。
    /// 规则（刻意保守：宁可少收，不可错收成一条假消息）：
    ///   · 图片只收**第一张** —— 一次分享多图在轻聊里没有既有通道（`ShareRouter` 一条 = 一图一文本），
    ///     而且剪贴板载荷会成倍变大；
    ///   · 文本只收**第一个** URL / 纯文本 provider（系统常同时给 url 与 text，同一内容的两副面孔）；
    ///   · 只认这三类：**图片 / 链接 / 文本**（口径 1a：`project.yml` 的 activation rule 也只声明这三类，
    ///     不再有 File —— 文件类分享会出现一个「点进去只发文件名、内容还读不出」的入口，直接不给）。
    func begin(with items: [NSExtensionItem], context: NSExtensionContext?) {
        self.context = context
        sourceName = items.compactMap { $0.attributedTitle?.string }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            phase = .empty("没有收到可分享的内容")
            return
        }
        for provider in providers { load(provider) }
        Task { @MainActor in
            try? await Task.sleep(for: Self.loadTimeout)
            guard phase == .loading else { return }   // 已经读完 / 已被用户操作过就别覆盖
            phase = hasContent ? .ready : .empty("没读出可分享的内容")
        }
    }

    private var hasContent: Bool { !text.isEmpty || image != nil }

    private func load(_ provider: NSItemProvider) {
        // 认类型的顺序：图 → 链接 → 纯文本
        // （口径 1a：不再有 File/.data 兜底分支 —— project.yml 的 activation rule 也不再声明文件类型，
        //   留一个「收得进、读不出」的分支就是死代码 + 假入口）
        let ids = provider.registeredTypeIdentifiers
        let type: String
        let isImage: Bool
        if !didTakeImage, let t = ids.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            type = t; isImage = true
        } else if !didTakeText, let t = ids.first(where: { UTType($0)?.conforms(to: .url) == true }) {
            type = t; isImage = false
        } else if !didTakeText, let t = ids.first(where: { UTType($0)?.conforms(to: .plainText) == true }) {
            type = t; isImage = false
        } else {
            return
        }
        if isImage { didTakeImage = true } else { didTakeText = true }
        pending += 1
        Self.fetch(provider, typeIdentifier: type) { [weak self] text, jpeg in
            self?.apply(text: text, imageJPEG: jpeg)
        }
    }

    /// 读一个 provider（`loadItem` 的**唯一**调用点）。
    ///
    /// ⚠️ 必须 `nonisolated`：`loadItem` 的入参 `[AnyHashable : Any]?` 与出参 `any NSSecureCoding`
    /// 都不是 Sendable，在 @MainActor 上下文里直接调它，Swift 6 严格并发会判
    /// 「非 Sendable 值跨 actor 边界」——**编译错误**（Swift 论坛实测：同一次调用挪出 @MainActor
    /// 类就没有诊断）。所以调用点固定在这里，回调里只取 `String` / `Data` 两种 Sendable 值，
    /// 再 `Task { @MainActor in ... }` 送回主线程；`NSItemProvider` 本身按同步参数传进来
    /// （同步调用不跨边界，不触发那条诊断）。
    private nonisolated static func fetch(_ provider: NSItemProvider,
                                          typeIdentifier: String,
                                          onMain: @escaping @MainActor (String?, Data?) -> Void) {
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
            let text = text(from: item)
            let jpeg = imageJPEG(from: item)
            Task { @MainActor in onMain(text, jpeg) }
        }
    }

    private func apply(text newText: String?, imageJPEG: Data?) {
        if let newText, text.isEmpty, !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = newText
        }
        if let imageJPEG, image == nil, let decoded = UIImage(data: imageJPEG) {
            image = decoded
        }
        pending -= 1
        guard pending <= 0, phase == .loading else { return }
        phase = hasContent ? .ready : .empty("没读出可分享的内容")
    }

    // MARK: - item → 内容（非隔离：在回调线程上跑，UIKit 解码不吃主线程）

    /// item → 文本。链接原样返回；`Data` 解 UTF-8（部分 App 的纯文本 provider 走 Data 交付）。
    /// 文件 URL 一律**不接**（口径 1a 已删 File：真收到 file:// 只会在会话里塞一条没用的路径）。
    private nonisolated static func text(from item: NSSecureCoding?) -> String? {
        if let s = item as? String { return s }
        if let d = item as? Data { return String(data: d, encoding: .utf8) }
        if let url = item as? URL { return url.isFileURL ? nil : url.absoluteString }
        if let url = item as? NSURL { return url.isFileURL ? nil : url.absoluteString }
        return nil
    }

    /// item → 下采样后的 JPEG 字节（`UIImage` 不出这个函数）。
    /// ⚠️ 这里的**文件 URL 分支必须保留**：图片 provider（照片 App / 从文件 App 分享的图）常以临时
    /// 文件 URL 交付 —— 与口径 1a 删掉的「File 类型」不是同一件事，那条说的是入口不再收**文件类**内容。
    private nonisolated static func imageJPEG(from item: NSSecureCoding?) -> Data? {
        let image: UIImage?
        if let u = item as? UIImage {
            image = u
        } else if let url = item as? URL, url.isFileURL {
            image = UIImage(contentsOfFile: url.path)
        } else if let url = item as? NSURL, let path = url.path {
            image = UIImage(contentsOfFile: path)
        } else if let d = item as? Data {
            image = UIImage(data: d)
        } else {
            image = nil
        }
        guard let image else { return nil }
        return ShareImageEncoder.jpeg(image)
    }

    // MARK: - 发送

    /// 点「发送到轻聊」：
    ///   ① 需要走剪贴板的内容（图 / 超长文本）**先写剪贴板再唤起** —— 反了的话主 App 收到 URL
    ///      立刻回来看剪贴板，会读到旧内容或空；
    ///   ② 尽力 `open` 唤起主 App，成败都如实落到 UI 状态上（iOS 18 起系统会拒，那是常态不是异常）。
    func send() async {
        guard phase == .ready else { return }
        phase = .sending
        let payload = ShareLinkCodec.Payload(id: token,
                                             kind: ShareLinkCodec.kind(text: text, hasImage: image != nil),
                                             text: text,
                                             note: note,
                                             sourceName: sourceName,
                                             hasImage: image != nil)
        let jpeg = image.flatMap { ShareImageEncoder.jpeg($0) }
        if payload.kind == .clipboard {
            writeClipboard(payload, imageJPEG: jpeg)
        }
        guard let url = ShareLinkCodec.url(for: payload), let context else {
            fallBackToClipboard(payload, imageJPEG: jpeg)
            return
        }
        if await Self.open(url, in: context) {
            phase = .handedOff
            onHandedOff?()
        } else {
            fallBackToClipboard(payload, imageJPEG: jpeg)
        }
    }

    /// 唤起失败（iOS 18+ 的常态）→ 把内容放进剪贴板等人来取，并**如实**写在界面上。
    /// 只有 `.inline` 载荷需要在这里补写剪贴板：它的正文在 URL 里，主 App 若收不到 URL 就再没别的来源；
    /// `.clipboard` 载荷在 `send` 开头已经写过，不重复写（重复写会把剪贴板有效期的起点往后推）。
    private func fallBackToClipboard(_ payload: ShareLinkCodec.Payload, imageJPEG: Data?) {
        if payload.kind == .inline {
            writeClipboard(payload, imageJPEG: nil)
        }
        phase = .needsManualOpen(Self.manualHint)
        ShareNudge.notify()
    }

    /// 写系统剪贴板。只挂本协议的自定义类型，见 `ShareLinkCodec.pasteboardType` 的注释
    /// （不挂标准文本/图片类型，免得与 chat 页既有的剪贴板识别提示条互相干扰）；
    /// 有效期由系统负责清掉（同 SecretsView 里复制凭据的用法）。
    private func writeClipboard(_ payload: ShareLinkCodec.Payload, imageJPEG: Data?) {
        UIPasteboard.general.setItems(
            [ShareLinkCodec.clipboardItem(payload, imageJPEG: imageJPEG)],
            options: [.expirationDate: Date().addingTimeInterval(ShareLinkCodec.pasteboardTTLSeconds)]
        )
    }

    /// 尽力唤起主 App。用**完成回调**版 API，而不是 `try await context.open(url)`：
    /// 回调版的调用点是同步的（就在主线程上直接发出去），类型系统不需要对 `NSExtensionContext`
    /// （非 Sendable）做跨并发域判断；async 版在没 iOS SDK 的本机编不出来，风险只能在 CI/真机暴露。
    private static func open(_ url: URL, in context: NSExtensionContext) async -> Bool {
        await withCheckedContinuation { cont in
            context.open(url) { ok in cont.resume(returning: ok) }
        }
    }

    /// 手动兜底文案（与大白话一一对应：为什么不是「已发送」，因为系统真的不让）
    private static let manualHint = """
    系统不允许分享扩展直接打开轻聊（iOS 18 起的新限制）。内容已放进系统剪贴板：
    手动打开轻聊，它会自动进当前会话（首次会问一次「允许粘贴」）。
    剪贴板载荷 10 分钟内有效，这期间别再分享第二条，会覆盖掉这一条。
    """
}
