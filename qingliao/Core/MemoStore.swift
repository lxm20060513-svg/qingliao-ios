import Foundation
import SwiftUI

// MARK: - v3.7.0 备忘录（生活页栏目 + 聊天气泡「加入备忘录」）
//
// 定位：随手记 —— 从聊天气泡/大爆炸/生活页手动添加的短文本，看板生活页置顶卡片展示。
// 存储：本地 UserDefaults 兜底 + NAS JSON 双写（复用 v3.0.74 钉一钉的 pin_write/pin_read 文件通道，
//       零后端改动；文件与 pins.json 同目录：轻聊web/data/memos.json）。
// 与 PinStore 的差异：备忘录不需要"来源会话"跳转，只需内容 + 时间 + 来源标签。

struct MemoItem: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var content: String
    var createdAt: Date
    /// 来源标签：chat（聊天气泡）/ bigbang（大爆炸选词）/ manual（生活页手写）
    var source: String

    init(id: String = UUID().uuidString, content: String,
         createdAt: Date = Date(), source: String = "manual") {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.source = source
    }

    /// 卡片副标题：来源 + 时间
    var subtitle: String {
        let tag: String
        switch source {
        case "chat": tag = "聊天"
        case "bigbang": tag = "选词"
        default: tag = "手记"
        }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return "\(tag) · \(df.string(from: createdAt))"
    }
}

@Observable
@MainActor
final class MemoStore {
    static let shared = MemoStore()

    private(set) var memos: [MemoItem] = []
    private let storagePathKey = "qingliao_memo_storage_path"
    private let fileName = "memos.json"
    private let defaultsKey = "qingliao_memos_data"

    weak var auth: AuthStore?

    func attach(auth: AuthStore) {
        self.auth = auth
    }

    /// 自定义存储目录（NAS 路径），空则用默认（与钉一钉同目录）
    var storagePath: String {
        get { UserDefaults.standard.string(forKey: storagePathKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: storagePathKey) }
    }

    private var filePath: String {
        let base = storagePath.isEmpty
            ? "/volume1/docker/hermes/微信文件/轻聊web/data"
            : storagePath
        return "\(base)/\(fileName)"
    }

    private init() {
        loadLocal()
    }

    // MARK: - CRUD

    /// 新增（最新的排最前）
    @discardableResult
    func add(content: String, source: String = "manual") -> Bool {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        // 同内容去重：连点两次不产生两条一样的备忘（5 分钟内）
        if let first = memos.first, first.content == text,
           Date().timeIntervalSince(first.createdAt) < 300 {
            return true
        }
        memos.insert(MemoItem(content: text, source: source), at: 0)
        save()
        return true
    }

    func delete(_ item: MemoItem) {
        memos.removeAll { $0.id == item.id }
        save()
    }

    func update(_ item: MemoItem, content: String) {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let idx = memos.firstIndex(where: { $0.id == item.id }) else { return }
        memos[idx].content = text
        save()
    }

    // MARK: - 持久化

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(memos) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)

        let path = filePath
        Task.detached { [weak auth] in
            await Self.writeToFile(auth: auth, path: path, data: data)
        }
    }

    private func loadLocal() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([MemoItem].self, from: data) {
            memos = decoded
        }
    }

    /// 从 NAS 拉取（生活页 .task / App 启动时调用）
    /// ⚠️ 必须**合并**而不是整体替换：save() 是 detached 异步写 NAS，刚添加的备忘可能
    /// 还没落远端；直接 `memos = decoded` 会让它从界面上"消失"（重启才由 UserDefaults 找回）。
    func loadFromServer() async {
        guard let auth else { return }
        guard let path = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let j = try? await auth.json("/api/files/pin_read?path=\(path)"),
              let b64 = j["data"] as? String,
              let data = Data(base64Encoded: b64) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let remote = try? decoder.decode([MemoItem].self, from: data) else { return }

        // 按 id 并集：同 id 取 createdAt 较新的一条；本地独有（远端还没收到）保留
        var byID: [String: MemoItem] = [:]
        for m in remote { byID[m.id] = m }
        for m in memos {
            if let r = byID[m.id] {
                byID[m.id] = r.createdAt >= m.createdAt ? r : m
            } else {
                byID[m.id] = m
            }
        }
        let merged = byID.values.sorted { $0.createdAt > $1.createdAt }
        let changed = merged.count != remote.count
        memos = merged
        if changed { save() }   // 本地有远端没有 → 回写一次补齐 NAS
    }

    private static func writeToFile(auth: AuthStore?, path: String, data: Data) async {
        guard let auth else { return }
        let body: [String: Any] = ["path": path, "data": data.base64EncodedString()]
        _ = try? await auth.json("/api/files/pin_write", method: "POST", body: body)
    }
}
