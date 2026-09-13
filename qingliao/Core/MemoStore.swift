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
    /// v3.9.14：置顶（置顶的固定在列表最上，带图钉标）
    var pinned: Bool
    /// v3.9.14：最后修改时间——编辑与置顶都要更新它。
    /// 为什么非有它不可：`loadFromServer` 按时间取"较新的一条"做合并，原先只有 createdAt，
    /// 于是「内容改了但 createdAt 没变」的本地条目会被远端旧内容覆盖回去（编辑等于白改）。
    var updatedAt: Date

    init(id: String = UUID().uuidString, content: String,
         createdAt: Date = Date(), source: String = "manual",
         pinned: Bool = false, updatedAt: Date? = nil) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.source = source
        self.pinned = pinned
        self.updatedAt = updatedAt ?? createdAt
    }

    /// v3.9.14：**手写解码，不要删**。旧数据里没有 pinned/updatedAt 两个键，
    /// 用合成的 Codable 会因缺键直接抛错 → 解码失败 → 用户已有备忘全部消失。
    /// 规矩：以后新增任何字段都必须走 decodeIfPresent + 默认值。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        content = try c.decode(String.self, forKey: .content)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// 显式声明：解码是手写的、编码走合成，写出来避免歧义
    private enum CodingKeys: String, CodingKey {
        case id, content, createdAt, source, pinned, updatedAt
    }

    /// 排序与合并用的时间基准
    var sortDate: Date { updatedAt }

    /// 来源中文名
    var sourceLabel: String {
        switch source {
        case "chat": return "聊天"
        case "bigbang": return "选词"
        default: return "手记"
        }
    }

    /// 来源图标（v3.9.14：列表里用图标代替文字，省一行宽度）
    var sourceIcon: String {
        switch source {
        case "chat": return "bubble.left.fill"
        case "bigbang": return "wand.and.stars"
        default: return "square.and.pencil"
        }
    }

    /// 卡片副标题：来源 + 相对时间
    var subtitle: String { "\(sourceLabel) · \(timeText)" }

    /// 相对时间文案（v3.9.14）：刚刚 / 12 分钟前 / 今天 14:30 / 昨天 09:05 / 3月8日 / 2025年12月3日
    var timeText: String { MemoItem.relativeTime(updatedAt) }

    // formatter 建一次就够（原来每渲染一行就 new 一个 DateFormatter，滚动时是白开销）
    nonisolated(unsafe) private static let dayTimeFormatter: DateFormatter = {
        let df = DateFormatter(); df.dateFormat = "HH:mm"; return df
    }()
    nonisolated(unsafe) private static let monthDayFormatter: DateFormatter = {
        let df = DateFormatter(); df.dateFormat = "M月d日"; return df
    }()
    nonisolated(unsafe) private static let fullDateFormatter: DateFormatter = {
        let df = DateFormatter(); df.dateFormat = "yyyy年M月d日"; return df
    }()

    /// 纯函数，便于真值表验证（本机无 iOS SDK 也能跑）
    static func relativeTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let mins = Int(now.timeIntervalSince(date) / 60)
            if mins < 1 { return "刚刚" }
            if mins < 60 { return "\(mins) 分钟前" }
            return "今天 \(dayTimeFormatter.string(from: date))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(dayTimeFormatter.string(from: date))"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return monthDayFormatter.string(from: date)
        }
        return fullDateFormatter.string(from: date)
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
        memos.insert(MemoItem(content: text, source: source, updatedAt: Date()), at: 0)
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
        // v3.9.14：内容没变就别动 updatedAt（否则每次打开编辑页保存都会把这条顶到最前）
        guard memos[idx].content != text else { return }
        memos[idx].content = text
        memos[idx].updatedAt = Date()
        save()
    }

    /// v3.9.14：置顶/取消置顶（也更新 updatedAt → 与远端合并时以本地为准）
    func togglePin(_ item: MemoItem) {
        guard let idx = memos.firstIndex(where: { $0.id == item.id }) else { return }
        memos[idx].pinned.toggle()
        memos[idx].updatedAt = Date()
        save()
    }

    /// v3.9.14：列表顺序 = 置顶优先，其次按最后修改时间倒序。
    /// 视图一律读这个而不是 `memos`（`memos` 的顺序只是插入序）。
    var sorted: [MemoItem] {
        memos.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.sortDate > b.sortDate
        }
    }

    // MARK: - 持久化

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 注：编码走合成的 encode(to:)（含 pinned/updatedAt）——只有解码是手写的（见 MemoItem）
        guard let data = try? encoder.encode(memos) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)

        let path = filePath
        Task.detached { [weak auth] in
            await Self.writeToFile(auth: auth, path: path, data: data)
        }
    }

    private func loadLocal() {
        // v3.9.14 fix：解码策略必须与 save() 对齐（.iso8601）。原来这里用默认的
        // `.deferredToDate`（期望 Double 时间戳）去解 save() 写出的 .iso8601 字符串日期
        // → 永远 typeMismatch → 被 try? 吞掉 → 每次冷启动本地缓存都是空。
        // 危害不止"离线看不到"：此时若新增一条，save() 会把只含新条目的数组写回 NAS 覆盖其余备忘。
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? decoder.decode([MemoItem].self, from: data) {
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

        // 按 id 并集：同 id 取**最后修改**较新的一条；本地独有（远端还没收到）保留
        // v3.9.14：比较基准从 createdAt 改为 updatedAt —— 否则编辑/置顶过的条目
        // 会被远端那份旧内容覆盖回来（编辑白改、置顶白点）
        var byID: [String: MemoItem] = [:]
        for m in remote { byID[m.id] = m }
        for m in memos {
            if let r = byID[m.id] {
                byID[m.id] = r.sortDate >= m.sortDate ? r : m
            } else {
                byID[m.id] = m
            }
        }
        let merged = byID.values.sorted { $0.sortDate > $1.sortDate }
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
