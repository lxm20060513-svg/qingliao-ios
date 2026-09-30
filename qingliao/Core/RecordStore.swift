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
    private let tombstonesKey = "qingliao_records_tombstones"

    /// 撤销过的记录 id（墓碑）。合并远端时跳过这些 id，防止「撤销完又复活」。
    /// 远端确认已无该 id 后由 loadFromServer 摘除，因此不会无限增长。
    private(set) var tombstones: Set<String> = []

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
        SyncedStore.remotePath(storagePath: storagePath, fileName: fileName)
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

    /// 一句话记账（聊天页入口 · v4.0.x）：把解析好的草稿写成一笔金额记录。
    ///
    /// 为什么这层薄包装要放在 Store 而不是聊天页里拼 addDetailed 参数：
    /// `kind=amount` / `unit=元` / `source=chat`（RecordKit 的 source 注释里预留的那个值）
    /// / `note=分类+原话` 这四处口径必须**只有一份** —— 聊天页、意图条、生活页三个入口写出来的
    /// 记录，才能被生活页同一套「本月合计 / 最近 3 条」逻辑无差别显示（口径散在调用点 = 下一个
    /// 入口照抄时必改歪）。真值表在 scripts/test_chat_record.swift 里连卡片文案一起钉住。
    @discardableResult
    func addExpense(_ draft: ChatExpenseDraft) -> (item: RecordItem, inserted: Bool)? {
        addDetailed(kind: "amount", title: draft.item, amount: draft.amount, unit: draft.unit,
                    note: draft.storeNote, source: "chat")
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
        // 🚨 v4.0.x：留墓碑。loadFromServer 是**并集**合并（远端有、本地没有 → 保留），
        // 原来撤销只删本地 + 改本地 UserDefaults；远端那份还在（写链在途/写失败）时，
        // 下次进 App 这条就被并集拉回来 = 用户看到「撤销完又活过来了」。
        // 墓碑让合并跳过这些 id；loadFromServer 见到远端**已经没有**它时再把墓碑摘掉
        // （= 远端终于接受了这次删除），所以墓碑集合不会无限增长。
        tombstones.insert(item.id)
        save()
    }

    /// 撤销删除（动作条撤销窗口用）
    func restore(_ item: RecordItem) {
        guard !records.contains(where: { $0.id == item.id }) else { return }
        // 显式加回来 = 这条不该再被墓碑挡住（否则 save 后的下一次合并又把它当已删）
        if tombstones.remove(item.id) != nil {
            UserDefaults.standard.set(Array(tombstones), forKey: tombstonesKey)
        }
        records.append(item)
        save()
    }

    // MARK: - 派生（一律委托 RecordKit，别在这里重算）

    var sorted: [RecordItem] { RecordKit.sorted(records) }

    var monthTotal: (amount: Double, count: Int) { RecordKit.monthTotal(records) }

    var latestMeter: RecordItem? { RecordKit.latestMeter(records) }

    // MARK: - 持久化

    /// v4.0.x：NAS 写库串行链——**这条是撤销能不能真生效的前提**。
    /// 原来每次 save 都各起一个 `Task.detached` 并发 pin_write 同一 path：「记账(A)」与「撤销(B=A-1)」
    /// 谁后到 NAS 不保证，慢的旧快照 A 后到 = 已撤销的记录在远端复活，下次 loadFromServer 又并集拉回来。
    /// 排队形态见 Core/SyncedStore.swift 的「FIFO 写链」段（5 仓同一份修法）。
    private var writeChain: Task<Void, Never> = Task {}

    private func save() {
        // 编解码策略（.iso8601）由 SyncedStore 统一持有，两端天然对齐
        guard let data = SyncedStore.encode(records) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)

        let path = filePath
        // 坑 2：先绑局部强引用再进写链
        let authForWrite = auth
        let prev = writeChain
        writeChain = Task {
            await prev.value                                  // FIFO：等前一次写完再写本次快照
            await SyncedStore.writeToFile(auth: authForWrite, path: path, data: data)
        }
    }

    private func loadLocal() {
        // 解码策略必须与 save() 的 .iso8601 对齐（不对齐 = 本地兜底恒空）
        if let decoded = SyncedStore.readLocal([RecordItem].self, defaultsKey: defaultsKey) {
            records = decoded
        }
        // 本地已不存在的 id 不该还留着墓碑（那说明它又被别处加回来了）
        tombstones = Set((UserDefaults.standard.stringArray(forKey: tombstonesKey) ?? [])
            .filter { id in !records.contains { $0.id == id } })
    }

    func loadFromServer() async {
        guard let remote = await SyncedStore.readRemote([RecordItem].self, auth: auth, path: filePath) else { return }

        // 🚨 v4.0.x：远端已确认没有的墓碑摘掉（删除终于被远端接受了），墓碑不会无限堆积
        let remoteIDs = Set(remote.map(\.id))
        if !tombstones.subtracting(remoteIDs).isEmpty {
            tombstones.formIntersection(remoteIDs)
            UserDefaults.standard.set(Array(tombstones), forKey: tombstonesKey)
        }

        var byID: [String: RecordItem] = [:]
        for r in remote where !tombstones.contains(r.id) { byID[r.id] = r }
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
}
