import Foundation

/// 快照写 NAS 失败时的**待补传队列**（v4.0.60）。
///
/// 背景：`SyncedStore.writeToFile` 原实现是 `try?` 静默吞错——写不上去就只留本地快照，
/// 换设备/重装才会发现缺条（2026-10-05 用户报「待办没有被创建」即此类：蜂窝下写失败被吞）。
/// v4.0.60 把写快照改成「只走直连、不降级 relay」（自动写不该弹 ASWAS 授权窗），
/// 失败即入队，等网络/前台恢复补传 —— 本地与远端最终一致。
///
/// 语义：
/// - 按 path 去重，**同一 path 只留最新快照**（快照是全量的，新的更权威；旧的后写会复活已删条目）
/// - FIFO 补传；成功的单条删除，失败的留到下一轮
/// - `discard(path:)`：该 path 又写成功时清掉队列里的旧副本（防旧快照覆盖新快照）
@MainActor
enum PendingPinWrites {
    private static let key = "qingliao_pending_pin_writes_v1"
    private static let corruptKey = "qingliao_pending_pin_writes_v1_corrupt"
    /// 队列上限：超了先丢最老的（防长期离线把 UserDefaults 撑大）
    private static let maxEntries = 50
    /// 一轮补传里连续失败到这个数就收工（网络显然还不通，别 N 条 × 20s 白等）
    private static let failStreakLimit = 3
    private static var flushing = false

    private struct Entry: Codable {
        let path: String
        let data: String        // base64 快照
        let ts: Double          // 入队时间（诊断用）
    }

    /// 待补传条数（诊断/调试用）
    static var pendingCount: Int { load().count }

    // MARK: - 入队 / 出队

    /// 排队一次失败的写。同一 path 已有条目 → 移除旧的、新的排到队尾（FIFO + 最新快照胜出）。
    static func enqueue(path: String, data: Data) {
        var list = load().filter { $0.path != path }
        list.append(Entry(path: path, data: data.base64EncodedString(),
                          ts: Date().timeIntervalSince1970))
        if list.count > maxEntries {
            // 别静默丢用户改动：淘汰前留一条日志（真丢过东西时有迹可循）
            let dropped = list.prefix(list.count - maxEntries).map(\.path)
            NSLog("[PendingPinWrites] 队列超上限 %d，丢弃最老条目：%@", maxEntries, dropped.joined(separator: ", "))
            list.removeFirst(list.count - maxEntries)
        }
        save(list)
        print("[PendingPinWrites] 入队待补传：\(path)（共 \(list.count) 条）")
    }

    /// 该 path 已写入成功 → 队列里的旧副本作废（防「旧快照后到覆盖新快照」）。
    @discardableResult
    static func discard(path: String) -> Bool {
        let list = load()
        let kept = list.filter { $0.path != path }
        guard kept.count != list.count else { return false }
        save(kept)
        return true
    }

    /// 补传（前台激活 / 网络恢复时调用）：逐条推 NAS；成功的单条删除，失败的留待下轮。
    /// 只走 `auth.pushSnapshot`（直连、不降级 relay）—— 补传是后台动作，不能弹授权窗。
    ///
    /// ⚠️ 两条别改回去的口径（2026-10-05 双只读审查抓到；v3.9.10 在 DiagnosticsUploader 已踩过同款）：
    ///  ① **不许用「内存快照整体 save」**：`await pushSnapshot` 会挂起（蜂窝 15s / 非蜂窝 20s），
    ///     期间别的写失败会 enqueue() 新条目 —— 最后整体 `save(remaining)` 会把它们一起抹掉 = 真丢数据。
    ///     正确做法：每成功一条就 load → filter 掉这一条 → save（见 remove(_:)）。
    ///  ② **一条失败别 break**：队头永久失败的条目（恒 4xx）会卡死它后面所有 path 的补传（队头阻塞）。
    ///     改成 continue，连续失败到 failStreakLimit 才收工。
    static func flush(auth: AuthStore) async {
        guard !flushing else { return }
        let list = load()
        guard !list.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        var failStreak = 0
        for entry in list {
            guard let data = Data(base64Encoded: entry.data) else {
                remove(entry)                       // 数据坏了：删这一条，别让它卡住后面的
                print("[PendingPinWrites] 条目数据损坏，丢弃：\(entry.path)")
                continue
            }
            if await auth.pushSnapshot(path: entry.path, data: data) {
                remove(entry)
                failStreak = 0
                print("[PendingPinWrites] 补传成功：\(entry.path)")
            } else {
                failStreak += 1
                print("[PendingPinWrites] 补传失败，留待下轮：\(entry.path)")
                if failStreak >= failStreakLimit { break }
            }
        }
    }

    /// 只删指定那一条（load → filter → save）。绝不用「内存快照整体覆盖」，见 flush 注释①。
    private static func remove(_ e: Entry) {
        save(load().filter { !($0.path == e.path && $0.ts == e.ts) })
    }

    // MARK: - 存盘

    private static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        if let list = try? JSONDecoder().decode([Entry].self, from: data) { return list }
        // 解码失败：先把坏数据另存一份留证再当空队列 —— 别让「一处损坏 = 静默清空所有待补传」（2026-10-05 审查）
        if UserDefaults.standard.data(forKey: corruptKey) == nil {
            UserDefaults.standard.set(data, forKey: corruptKey)
            NSLog("[PendingPinWrites] 队列数据损坏，已另存 %@ 留证", corruptKey)
        }
        return []
    }

    private static func save(_ list: [Entry]) {
        if list.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
