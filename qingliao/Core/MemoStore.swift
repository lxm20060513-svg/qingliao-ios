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
        case "orb": return "智能球"   // v3.9.59：dock 智慧球长按 → AI 速记
        case "intent": return "识别"   // v3.9.71：意图管道（识别出来的内容一键存）
        case "meeting": return "会议纪要"   // v4.0.x：会话纪要页（现场长录音 → 转写 → 整理）
        default: return "手记"
        }
    }

    /// 来源图标（v3.9.14：列表里用图标代替文字，省一行宽度）
    var sourceIcon: String {
        switch source {
        case "chat": return "bubble.left.fill"
        case "bigbang": return "wand.and.stars"
        case "orb": return "circle.dashed"   // v3.9.59：智能球来源
        case "intent": return "sparkles"     // v3.9.71：识别来源
        case "meeting": return "doc.text.fill"   // v4.0.x：会议纪要来源（页面里备忘指向用的是同一个符号）
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

    // v3.9.41（SR33）：改为**强引用**。原先 weak → 快捷指令（AddMemoIntent）自己 new 的临时
    // AuthStore 在 perform() 返回瞬间就没人持有，本单例的 auth 随即变 nil：
    // save() 那条 detached 写 NAS 的任务在 `guard let auth` 处静默 return，
    // 而 Siri 已经念过「已记到轻聊备忘录」→ 备忘只活在本地，NAS 上永远缺这一条。
    // 本类是进程级单例、AuthStore 由 App/extension 长期持有，强引用不会造成泄漏或环。
    var auth: AuthStore?

    func attach(auth: AuthStore) {
        self.auth = auth
    }

    /// 自定义存储目录（NAS 路径），空则用默认（与钉一钉同目录）
    var storagePath: String {
        get { UserDefaults.standard.string(forKey: storagePathKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: storagePathKey) }
    }

    /// v4.0.x 复核补：NAS 写链 FIFO（等前一次写完再写本次快照），防并发写同一 path 时
    /// 慢的旧快照后到 → 远端复活已删条目。排队形态由 SyncedStore 统一注释说明
    /// （5 个 Store 的写链是同一份修法，见 Core/SyncedStore.swift 的「FIFO 写链」段）。
    private var writeChain: Task<Void, Never> = Task {}

    private var filePath: String {
        SyncedStore.remotePath(storagePath: storagePath, fileName: fileName)
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

    /// 全部删除（含已完成/置顶）——「全部备忘」弹窗顶栏「清空」胶囊用。
    /// 必须走 save() 同一条 FIFO 写链：否则远端留旧快照，loadFromServer 的并集合并会把条目复活。
    @discardableResult
    func removeAll() -> Int {
        let n = memos.count
        guard n > 0 else { return 0 }
        memos.removeAll()
        save()
        return n
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
        // 注：编码走合成的 encode(to:)（含 pinned/updatedAt）——只有解码是手写的（见 MemoItem）
        // 编解码策略（.iso8601）与解码端对齐由 SyncedStore 统一持有。
        guard let data = SyncedStore.encode(memos) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)

        let path = filePath
        // SR33：这里必须**强**捕获 auth（先绑成局部常量再进链）。写任务真正跑起来
        // 时调用方栈早已退出，弱引用可能在调度间隙被清空 → 整次 NAS 回写静默丢失
        //（本地 UserDefaults 有、界面无异状，只在另一台设备上看得到缺条）。
        let authForWrite = auth
        // v4.0.x 复核补：原来每次 save 各起一个
        // `Task.detached` **并发**写同一 NAS path ——「删除 A」与「编辑 B」并发时慢的旧快照
        // 后到，已删条目在远端复活；而这几个 Store 的 loadFromServer 都是**并集**合并
        // （替换会让未落远端的条目消失），所以复活后没有任何墓碑/版本号能挡住它。
        // 正解：FIFO 串行写链，排队形态见 Core/SyncedStore.swift 的「FIFO 写链」段。
        let prev = writeChain
        writeChain = Task {
            await prev.value                                  // FIFO：等前一次写完再写本次快照
            await SyncedStore.writeToFile(auth: authForWrite, path: path, data: data)
        }
    }

    private func loadLocal() {
        // v3.9.14 fix：解码策略必须与 save() 对齐（.iso8601）。原来这里用默认的
        // `.deferredToDate`（期望 Double 时间戳）去解 save() 写出的 .iso8601 字符串日期
        // → 永远 typeMismatch → 被 try? 吞掉 → 每次冷启动本地缓存都是空。
        // 危害不止"离线看不到"：此时若新增一条，save() 会把只含新条目的数组写回 NAS 覆盖其余备忘。
        if let decoded = SyncedStore.readLocal([MemoItem].self, defaultsKey: defaultsKey) {
            memos = decoded
        }
    }

    /// 从 NAS 拉取（生活页 .task / App 启动时调用）
    /// ⚠️ 必须**合并**而不是整体替换：save() 是 detached 异步写 NAS，刚添加的备忘可能
    /// 还没落远端；直接 `memos = decoded` 会让它从界面上"消失"（重启才由 UserDefaults 找回）。
    func loadFromServer() async {
        // 远端读盘 + 解码：与 loadLocal 共用同一套 .iso8601 策略（见 SyncedStore）
        guard let remote = await SyncedStore.readRemote([MemoItem].self, auth: auth, path: filePath) else { return }

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
        // v3.9.41（SR40）：原先只比**条数**——编辑内容时 id 集合不变 → 永不回写，
        // NAS 那份对这台设备无限期失真，直到碰巧发生一次增/删才连带修复。改成逐条比对。
        // 时间按整秒比：JSONEncoder 的 .iso8601 不保留小数秒，直接比 Date 会把同一份内容
        // 判成「有差异」→ 每次拉取都白写一次 NAS。
        var remoteByID: [String: MemoItem] = [:]
        for r in remote { remoteByID[r.id] = r }
        let changed = merged.count != remote.count || merged.contains { m in
            guard let r = remoteByID[m.id] else { return true }   // 本地独有 → 回写补齐
            return m.content != r.content || m.pinned != r.pinned || m.source != r.source
                || Int(m.updatedAt.timeIntervalSince1970) != Int(r.updatedAt.timeIntervalSince1970)
        }
        memos = merged
        if changed { save() }   // 本地有远端没有/内容更新 → 回写一次补齐 NAS
    }
}
