import Foundation
import SwiftUI

/// v3.0.74：钉一钉数据层 —— 本地 JSON 持久化 + 后端 API 同步
/// 存储路径：默认 NAS /volume1/docker/hermes/微信文件/轻聊app/pins.json
/// 可在设置里自定义路径
@Observable
@MainActor
final class PinStore {
    static let shared = PinStore()

    private(set) var pins: [PinItem] = []
    private let storagePathKey = "qingliao_pin_storage_path"
    private let defaultFileName = "pins.json"

    /// 自定义存储路径（NAS 路径），空则用默认
    var storagePath: String {
        get { UserDefaults.standard.string(forKey: storagePathKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: storagePathKey) }
    }

    /// 钉一钉数据文件的完整路径（NAS 上）
    private var pinsFilePath: String {
        let base = storagePath.isEmpty
            ? "/volume1/docker/hermes/微信文件/轻聊web/data"
            : storagePath
        return "\(base)/\(defaultFileName)"
    }

    private init() {
        loadLocal()
    }

    // MARK: - CRUD

    /// 新增钉一钉
    func add(content: String, sourceSessionId: String? = nil, sourceRole: String? = nil) {
        let item = PinItem(content: content, sourceSessionId: sourceSessionId, sourceRole: sourceRole)
        pins.insert(item, at: 0) // 最新的在最上面
        save()
    }

    /// 删除钉一钉
    func delete(_ item: PinItem) {
        pins.removeAll { $0.id == item.id }
        save()
    }

    /// 左滑删除（SwipeActions 调用）
    func delete(at offsets: IndexSet) {
        pins.remove(atOffsets: offsets)
        save()
    }

    // MARK: - 按天分组

    /// 返回 [(日期key, [PinItem])]，最新日期在前
    var groupedByDate: [(String, [PinItem])] {
        var dict: [String: [PinItem]] = [:]
        for pin in pins {
            dict[pin.dateKey, default: []].append(pin)
        }
        return dict.sorted { $0.key > $1.key } // 降序：最新日期在前
    }

    // MARK: - 持久化

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(pins) else { return }

        // 写本地 UserDefaults 兜底
        UserDefaults.standard.set(data, forKey: "qingliao_pins_data")

        // v3.0.x fix：用 Task.detached 避免继承 @MainActor（原 Task 继承 MainActor → 网络 I/O 阻塞主线程）
        let path = pinsFilePath
        Task.detached { [weak auth] in
            await Self.writeToFile(auth: auth, path: path, data: data)
        }
    }

    private func loadLocal() {
        // 先从本地 UserDefaults 加载
        // v3.9.14 fix：与 save() 的 .iso8601 对齐（同 MemoStore 的问题：默认策略解字符串日期必失败，
        // 本地兜底等于没有）——这处是从 MemoStore 复制过去的同款 bug，一并修
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: "qingliao_pins_data"),
           let decoded = try? decoder.decode([PinItem].self, from: data) {
            pins = decoded
        }
    }

    /// 从 NAS 文件加载（App 启动时调用）
    /// v3.9.32 fix：读回后**并集合并**，不再整体替换。
    /// 此前 save() 是 Task.detached 异步写，刚钉完立刻切看板（或蜂窝下写慢）时，
    /// loadFromServer 读到的还是旧文件 → `pins = decoded` 把新条目抹掉，
    /// 之后任意一次 save 又把「丢了条目的版本」写回 NAS，本地兜底一并被覆盖。
    /// （MemoStore 修过同款，PinStore 漏了。）
    func loadFromServer() async {
        guard let data = await readFromFile() else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([PinItem].self, from: data) else { return }
        let remoteIDs = Set(decoded.map { $0.id })
        // 同 id 以远端内容为准（远端是权威副本）；本地独有条目一律保留（= 还没写成功的那些）
        let localOnly = pins.filter { !remoteIDs.contains($0.id) }
        var merged = decoded + localOnly
        merged.sort { $0.createdAt > $1.createdAt }
        pins = merged
    }

    // MARK: - 注入 AuthStore（由 App 启动时注入）
    weak var auth: AuthStore?

    func attach(auth: AuthStore) {
        self.auth = auth
    }

    // MARK: - 文件读写（通过后端 API）

    /// v3.0.x fix：static 方法，供 Task.detached 调用（避免捕获 self 导致 MainActor 隔离问题）
    private static func writeToFile(auth: AuthStore?, path: String, data: Data) async {
        guard let auth else { return }
        let body: [String: Any] = [
            "path": path,
            "data": data.base64EncodedString()
        ]
        _ = try? await auth.json("/api/files/pin_write", method: "POST", body: body)
    }

    private func readFromFile() async -> Data? {
        guard let auth else { return nil }
        guard let j = try? await auth.json("/api/files/pin_read?path=\(pinsFilePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pinsFilePath)"),
              let b64 = j["data"] as? String,
              let data = Data(base64Encoded: b64) else {
            return nil
        }
        return data
    }
}
