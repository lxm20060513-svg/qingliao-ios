import Foundation
import UIKit

// MARK: - v4.0.1 系统分享接收扩展的主 App 侧落点
//
// 把扩展送来的载荷落成**当前会话里的一条用户消息**。两条入口，同一套处理与去重：
//   ① `.onOpenURL` 收到 `qingliao://share?...`（扩展 `extensionContext.open` 成功时；
//      也可能来自用户手打同一个 scheme）；
//   ② 回前台 / 冷启动时发现系统剪贴板里有本协议的载荷（`open` 被 iOS 18 挡住时的兜底 ——
//      用户自己打开轻聊这条路径）。协议与两条通道的定义见 `ShareLinkCodec`。
//
// 不新造机制：文本与图片**都**走 `ShareRouter` + `.qingliaoShareIncoming`（v3.4.14 系统分享
// 那条既有通道）。投递前先 post `.qingliaoOpenChat` 请宿主切到聊天页 —— 载荷的两条落点都
// 挂在「ChatView 在视图树里」这个前提上。
// ⚠️ 文本**不再**走 `.qingliaoTaskSend`：那是无队列的一次性通知，投递那一刻 ChatView 不在
//    视图树（冷启动停在别的 tab / 切页没赶上）就永久丢失；收件匣有队列 + `onAppear` 兜底 drain。
@MainActor
enum ShareIntake {

    // MARK: - 时序档位（都取名字，不写魔法值）

    /// 投递延迟：`.onOpenURL` 可能在视图树就绪**之前**就回调（系统深链的已知行为），
    /// 而 `.qingliaoTaskSend` / `.qingliaoShareIncoming` 只有 ChatView 在视图树里才有人接
    /// （`onReceive` 挂在那里的 `.onReceive` 上）。冷启动 splash 最短 0.6s，与它取同一拍；
    /// 切页转场 0.2s 的那种短闸（DockTabView.askAI 用 0.35s）在冷启动路径上不够。
    private static let deliverDelay: Duration = .seconds(0.6)

    /// 剪贴板探测延迟：回前台那一瞬可能还在转场、窗口未就绪，而系统「允许粘贴」弹窗要求
    /// App 已经在前台（读早了会被判拒，且此后不再弹授权窗）→ 等一拍再读。
    private static let clipboardProbeDelay: Duration = .seconds(0.8)

    /// 去重令牌只留最近这些条：会话里连着分享十几次也不会把内存当账本用。
    private static let handledTokenLimit = 32
    /// 剪贴板消费记账的持久化键。
    /// 🚨 **必须持久化**（不能只用内存）：载荷在剪贴板里活 10 分钟，而 App 被强杀/升级重启后
    /// 内存储量与 `changeCount` 都会重来 → 同一份载荷会被**再消费一次**（会话里凭空多一条重复消息）。
    private static let clipboardChangeKey = "qingliao_share_intake_change"

    // MARK: - 状态

    private struct Incoming {
        var payload: ShareLinkCodec.Payload
        var imageJPEG: Data?
    }

    /// 本进程已处理过的令牌（同一份载荷可能从 URL 与剪贴板**同时**到达）
    private static var handledTokens: [String] = []
    /// 未登录时先收下，登录后再投（RootView 监听 `auth.isLoggedIn` 调 `flushPending`）
    private static var pendingWhileLoggedOut: [Incoming] = []

    private static var lastClipboardChange: Int {
        get { UserDefaults.standard.object(forKey: clipboardChangeKey) as? Int ?? -1 }
        set { UserDefaults.standard.set(newValue, forKey: clipboardChangeKey) }
    }

    // MARK: - 入口

    /// URL 入口。返回 true = 是本协议的 URL（已接管），false = 不是（交给别的处理器，如 DockTabView）。
    /// ⚠️ 同一场景里挂多个 `.onOpenURL` 时 SwiftUI 会**逐个回调**，所以这里必须先判「是不是我的」
    /// 再动手；不是就立刻返回，绝不改别人的 URL 处理结果。
    @discardableResult
    static func handle(url: URL, loggedIn: Bool) -> Bool {
        guard let p = ShareLinkCodec.payload(from: url) else { return false }
        switch p.kind {
        case .inline:
            // 正文全在 URL 里 → 不碰剪贴板（一次「允许粘贴」弹窗都不会有）
            accept(Incoming(payload: p, imageJPEG: nil), loggedIn: loggedIn)
        case .clipboard:
            // 正文/图都在剪贴板里：读一次（跨 App 读 → 可能弹一次「允许粘贴」）
            if let got = readClipboardPayload(expectedID: p.id) {
                accept(Incoming(payload: got.payload, imageJPEG: got.imageJPEG), loggedIn: loggedIn)
            } else {
                reportMissingPayload(loggedIn: loggedIn)
            }
        }
        return true
    }

    /// 剪贴板入口（回前台 / 冷启动调用）。**多次调用安全**：记账 + 令牌双重去重。
    static func resume(loggedIn: Bool) {
        Task { @MainActor in
            try? await Task.sleep(for: clipboardProbeDelay)
            probeClipboard(loggedIn: loggedIn)
        }
    }

    /// 登录成功后的重投（RootView 在 `auth.isLoggedIn` 变真时调用）
    static func flushPending(loggedIn: Bool) {
        guard loggedIn, !pendingWhileLoggedOut.isEmpty else { return }
        let items = pendingWhileLoggedOut
        pendingWhileLoggedOut.removeAll()
        for item in items { deliver(item) }
    }

    // MARK: - 剪贴板通道

    /// 探测并消费剪贴板里的载荷。
    /// 🚨 顺序不能反：先 `contains`（**不读内容**、无授权弹窗）再 `items`（= 真读，跨 App 会弹
    ///    「允许粘贴」）。反了就是「每次回前台都弹一次授权」——用户最烦的那类打扰。
    private static func probeClipboard(loggedIn: Bool) {
        let pb = UIPasteboard.general
        guard pb.contains(pasteboardTypes: [ShareLinkCodec.pasteboardType]) else { return }
        let cc = pb.changeCount
        guard cc != lastClipboardChange else { return }   // 这一版已经消费过
        lastClipboardChange = cc                          // 无论成败都记账：同一版只处理一次
        guard let item = pb.items.first,
              let decoded = ShareLinkCodec.payload(fromClipboardItem: item) else {
            reportMissingPayload(loggedIn: loggedIn)      // 有我们的类型却读不出内容 → 出声
            return
        }
        accept(Incoming(payload: decoded.payload, imageJPEG: decoded.imageJPEG), loggedIn: loggedIn)
    }

    /// 按令牌读回剪贴板载荷（URL 通道用）。
    /// 令牌不符 = 剪贴板里是**上一次**分享的残留（或已过 10 分钟失效）→ 返回 nil，
    /// 由调用方走「没读到手」的出声路径，绝不把旧内容当成这一次的分享发出去。
    private static func readClipboardPayload(expectedID: String)
        -> (payload: ShareLinkCodec.Payload, imageJPEG: Data?)? {
        let pb = UIPasteboard.general
        guard pb.contains(pasteboardTypes: [ShareLinkCodec.pasteboardType]) else { return nil }
        // 探到这一版就记账（无论成败）：成功 = 已消费；失败 = 同一版别再重复弹授权、也别重复出声
        lastClipboardChange = pb.changeCount
        guard let item = pb.items.first,
              let decoded = ShareLinkCodec.payload(fromClipboardItem: item),
              decoded.payload.id == expectedID else { return nil }
        return decoded
    }

    // MARK: - 去重 / 投递

    private static func accept(_ incoming: Incoming, loggedIn: Bool) {
        guard !handledTokens.contains(incoming.payload.id) else { return }
        handledTokens.append(incoming.payload.id)
        if handledTokens.count > handledTokenLimit {
            handledTokens.removeFirst(handledTokens.count - handledTokenLimit)
        }
        guard loggedIn else {
            pendingWhileLoggedOut.append(incoming)   // 未登录：先收下，登录后 flushPending
            return
        }
        deliver(incoming)
    }

    private static func deliver(_ incoming: Incoming) {
        let p = incoming.payload
        let message = ShareLinkCodec.message(for: p)
        // 🚨 先请宿主把聊天页切进来（`DockTabView` 收 `.qingliaoOpenChat` → 切页）。
        //   载荷的两个落点都是 ChatView 挂的 `onReceive`，它不在视图树里 = 通知落空
        //   （本仓口径：不切页 = 消息静默消失）。切页通知**立即**发（DockTabView 进程内常驻、
        //   收到即切），载荷再等下面那拍闸 —— 与 `DockTabView.askAI` / `handleCameraShot`
        //   的「先切页、0.35s 后投递」同款，只是这里闸更长（冷启动 splash 0.6s）。
        NotificationCenter.default.post(name: .qingliaoOpenChat, object: nil)
        Task { @MainActor in
            try? await Task.sleep(for: deliverDelay)
            if let jpeg = incoming.imageJPEG {
                guard let image = UIImage(data: jpeg) else {
                    // 字节解不成图（极少见，但**不能静默**）：出声走下面那条可见消息
                    notify("⚠️ 分享的图片解码失败，没能发进会话。请重新分享一次。", loggedIn: true)
                    return
                }
                // 带图 → 走既有**分享收件匣**（`ShareRouter` + `.qingliaoShareIncoming`）：
                // `.qingliaoTaskSend` 的载荷是**纯字符串**（ChatView 侧签名 `note.object as? String`），
                // 带不了图；收件匣是 v3.4.14 就有的系统分享落点，图片消息口径也由它统一。
                // （纯图消息的 text 就是空串：ChatView.drainShareInbox 走 `sendCore(text:imageData:)`，
                //   那里 `guard !text.isEmpty || imageData != nil` 放行纯图。）
                ShareRouter.shared.enqueue(SharedPayload(text: message,
                                                         image: image,
                                                         sourceName: p.sourceName))
                NotificationCenter.default.post(name: .qingliaoShareIncoming, object: nil)
            } else if !message.isEmpty {
                // 文本 / 链接 → 与图片**同一条收件匣**（`ShareRouter` + `.qingliaoShareIncoming`）。
                //   走到这里说明宿主已经收过切页通知，但**不能**因此假设 ChatView 一定在树里
                //   （冷启动时该通知可能早于 DockTabView 注册；转场也可能还没落定）——
                //   收件匣有队列且 `ChatView.onAppear` 会兜底 drain，任何时刻都补得上。
                ShareRouter.shared.enqueue(SharedPayload(text: message,
                                                         image: nil,
                                                         sourceName: p.sourceName))
                NotificationCenter.default.post(name: .qingliaoShareIncoming, object: nil)
            }
        }
    }

    /// 「读不到 / 解不开」的统一出声。仓库口径是**失败必出声**（静默 = 用户以为分享成功了，
    /// 而会话里什么都没有）。App 侧此刻没有别的可用出口：ChatView 的提示条由它内部的
    /// `flashNoContent` 管（那是别人的文件，本任务不碰），所以这里落成一条可见消息。
    /// 代价是 AI 会回一句 —— 比无声失败可接受。
    private static func notify(_ text: String, loggedIn: Bool) {
        accept(Incoming(payload: ShareLinkCodec.Payload(id: ShareLinkCodec.newID(),
                                                        kind: .inline,
                                                        text: text,
                                                        note: "",
                                                        sourceName: nil,
                                                        hasImage: false),
                        imageJPEG: nil),
                loggedIn: loggedIn)
    }

    private static func reportMissingPayload(loggedIn: Bool) {
        notify("⚠️ 分享的内容没读到（剪贴板里没有，或系统未允许粘贴）。请重新分享一次，并在系统弹窗里点「允许粘贴」。",
               loggedIn: loggedIn)
    }
}
