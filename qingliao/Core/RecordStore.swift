import Foundation
import SwiftUI

// MARK: - v3.9.71 记录容器 Store
//
// 与 TodoStore（v3.9.35）同款：**本地 UserDefaults + NAS JSON 双写，零后端改动**
//（走 /api/files/pin_read | pin_write，路径 …/轻聊web/data/records.json）。
//
// 三个坑照抄自 TodoStore，别删（都是踩出来的）：
//   1. Codable 手写解码 + decodeIfPresent（在 RecordKit.RecordItem 里）——否则加字段 = 旧数据消失
//   2. `auth` 必须是**强引用**：weak 时调用方一返回，下面 detached 的 NAS 回写就在 `guard let auth`
//      处静默 return，表现为"本地有、NAS 永远没有"
//   3. loadFromServer **按 id 合并取较新，不整体替换**；回写判定要比内容（改内容/删条目时条数可能不变），
//      且时间按整秒比（.iso8601 丢小数秒 → 同一份内容被判成不同 → 每次拉取白写一次 NAS）
//
// 纯逻辑（合计/文案/排序/月份键）一律在 RecordKit.swift —— 那份没有 SwiftUI 依赖，
// 能在本机真值表里逐条断言（scripts/test_intent_pipeline.swift 第 7 节）。

@Observable
@MainActor
final class RecordStore {
    static let shared = RecordStore()

    private(set) var records: [RecordItem] = []
    private let storagePathKey = "qingliao_record_storage_path"
    private let fileName = "records.json"
    private let defaultsKey = "qingliao_records_data"

    /// 强引用（坑 2）
    var auth: AuthStore?

    func attach(auth: AuthStore) {
        self.auth = auth
    }

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

    /// 新增（带"这条到底有没有新建"的标志）。
    ///
    /// 为什么非要这个标志（v3.9.71 审查）：5 分钟同内容去重命中时，返回的是**已存在**那条，
    /// 而动作条拿到 id 就当"新建成功"给「撤销」→ 用户一按撤销会删掉几分钟前自己手动记的那笔。
    /// 记账场景里"同额两笔"是正常业务（同店同价、同额两笔），所以去重只能护连点，不能吞掉第二笔。
    @discardableResult
    func addDetailed(kind: String, title: String, amount: Double?, unit: String,
                     note: String = "", source: String = "manual") -> (item: RecordItem, inserted: Bool)? {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // 只防"2 秒内连点"这一种情况（原来是 5 分钟，会吞掉正当的第二笔）
        if let first = records.first, first.title == text, first.amount == amount,
           Date().timeIntervalSince(first.createdAt) < 2 {
            return (first, false)
        }
        let item = RecordItem(kind: kind, title: text, amount: amount, unit: unit,
                              note: note, source: source)
        records.insert(item, at: 0)
        save()
        return (item, true)
    }

    /// 新增（旧签名：生活页手写入口用；动作条走 addDetailed 拿 inserted）
    @discardableResult
    func add(kind: String, title: String, amount: Double?, unit: String,
             note: String = "", source: String = "manual") -> RecordItem? {
        addDetailed(kind: kind, title: title, amount: amount, unit: unit,
                    note: note, source: source)?.item
    }

    func delete(_ item: RecordItem) {
        records.removeAll { $0.id == item.id }
        save()
    }

    /// 撤销删除（动作条撤销窗口用）
    func restore(_ item: RecordItem) {
        guard !records.contains(where: { $0.id == item.id }) else { return }
        records.append(item)
        save()
    }

    // MARK: - 派生（一律委托 RecordKit，别在这里重算）

    var sorted: [RecordItem] { RecordKit.sorted(records) }

    var monthTotal: (amount: Double, count: Int) { RecordKit.monthTotal(records) }

    var latestMeter: RecordItem? { RecordKit.latestMeter(records) }

    // MARK: - 持久化

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)

        let path = filePath
        // 坑 2：先绑局部强引用再进 detached
        let authForWrite = auth
        Task.detached {
            await Self.writeToFile(auth: authForWrite, path: path, data: data)
        }
    }

    private func loadLocal() {
        // 解码策略必须与 save() 的 .iso8601 对齐（不对齐 = 本地兜底恒空）
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? decoder.decode([RecordItem].self, from: data) {
            records = decoded
        }
    }

    func loadFromServer() async {
        guard let auth else { return }
        guard let path = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let j = try? await auth.json("/api/files/pin_read?path=\(path)"),
              let b64 = j["data"] as? String,
              let data = Data(base64Encoded: b64) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let remote = try? decoder.decode([RecordItem].self, from: data) else { return }

        var byID: [String: RecordItem] = [:]
        for r in remote { byID[r.id] = r }
        for r in records {
            if let s = byID[r.id] {
                byID[r.id] = s.sortDate >= r.sortDate ? s : r
            } else {
                byID[r.id] = r
            }
        }
        let merged = byID.values.sorted { $0.sortDate > $1.sortDate }

        // 坑 3：条数一样也要比内容（改金额/删一条再加一条，条数不变）
        var remoteByID: [String: RecordItem] = [:]
        for r in remote { remoteByID[r.id] = r }
        let changed = merged.count != remote.count || merged.contains { r in
            guard let s = remoteByID[r.id] else { return true }
            return r.title != s.title || r.amount != s.amount || r.unit != s.unit
                || r.note != s.note || r.kind != s.kind || r.source != s.source
                || Int(r.updatedAt.timeIntervalSince1970) != Int(s.updatedAt.timeIntervalSince1970)
        }
        records = merged
        if changed { save() }
    }

    private static func writeToFile(auth: AuthStore?, path: String, data: Data) async {
        guard let auth else { return }
        let body: [String: Any] = ["path": path, "data": data.base64EncodedString()]
        _ = try? await auth.json("/api/files/pin_write", method: "POST", body: body)
    }
}
