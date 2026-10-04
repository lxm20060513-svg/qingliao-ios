import Foundation

/// 待做池第 8 项：链接预览的**会话内缓存**（按消息 id 存，避免同一条反复打后端）。
///
/// 状态机：`nil`（未抓）→ `.loading` → `.ready` / `.failed`。
/// 口径：
///  · 失败**不自动重试**（防「网络不通 → 每条消息反复打后端」），要重试走 `force`（长按卡「重新抓取」）；
///  · 已 `dismiss`（用户关掉卡）的消息**不再抓**（`load` 直接短路）；
///  · 消息里没有 http(s) 链接 → 不存任何状态（行不渲染）。
@MainActor
@Observable
final class LinkPreviewStore {

    enum State: Equatable {
        case loading
        case ready(LinkPreviewKit.LinkPreview)
        case failed
    }

    private(set) var states: [String: State] = [:]
    private(set) var dismissed: Set<String> = []

    /// 进程内单例：与 `GoalStore.shared` 同款（View 里以 `@State private var x = X.shared` 持有，
    /// 是该仓在 Swift 6 严格并发下**已被编译验证**的写法）；顺带让「已关掉的预览」跨重绘保持关闭。
    static let shared = LinkPreviewStore()

    init() {}

    func state(for id: String) -> State? { states[id] }
    func isDismissed(_ id: String) -> Bool { dismissed.contains(id) }

    func dismiss(_ id: String) {
        dismissed.insert(id)
        states[id] = nil
    }

    /// 拉取一条消息首个链接的预览。`force = true` 用于「重新抓取」。
    func load(id: String, text: String, auth: AuthStore, force: Bool = false) async {
        if dismissed.contains(id) { return }
        guard let urlStr = LinkPreviewKit.candidateURL(in: text) else {
            states[id] = nil
            return
        }
        if !force {
            switch states[id] {
            case .loading?, .ready?, .failed?: return   // 已有结果/在途/失败过 → 不重复打
            case nil: break
            }
        }
        states[id] = .loading
        do {
            let obj = try await auth.json("/api/agent/linkpreview", method: "POST",
                                          body: ["url": urlStr], timeout: 12)
            states[id] = LinkPreviewKit.parse(obj).map { State.ready($0) } ?? .failed
        } catch {
            states[id] = .failed
        }
    }
}
