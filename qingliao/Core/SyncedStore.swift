import Foundation

/// v4.0.x 瘦身：5 个 Store（Pin/Memo/Todo/Record/Goal）共有的持久化底座 —— **单一真源**。
///
/// 抽出来的理由（不是「看着像就抽」）：
/// 1. **FIFO 串行写链**。这 5 个 Store 的 `loadFromServer` 全是**并集**合并，替换会让没落远端的
///    条目消失，所以远端一旦被旧快照覆盖/复活，没有墓碑或版本号能挡住。修法只有一条：写同一
///    path 必须排队。此前每个 Store 各抄一份 `writeChain`，PinStore 注释里自认「同一份修法，保持
///    单一真源」，而历史上确实抄漏过 bug（PinStore 漏了并集合并、漏了强捕获 auth）。
/// 2. **ISO8601 编解码必须两端对齐**。save 用 `.iso8601` 写，load 若用默认 `.deferredToDate`
///    （期望 Double 时间戳）去解 → 永远 typeMismatch → 被 `try?` 吞掉 → 每次冷启动本地兜底恒空，
///    且此刻若新增一条还会把只含新条目的数组写回 NAS 覆盖其余条目。这坑 5 个 Store 都各踩过一次。
/// 3. **NAS 文件通道**（`/api/files/pin_write` / `pin_read`，base64 载荷）是同一份 HTTP 协议。
///
/// 刻意**没有**抽进来的部分（各自差异大，强行统一只会更绕）：
/// - 远端合并策略：PinStore 是「远端为准 + 本地独有保留」，其余 4 个是「按 id 取较新」，
///   Record/Goal 还各带墓碑。
/// - 「changed 判定要回写 NAS」的字段清单 4 个 Store 各不相同（memo 比 content/pinned/source，
///   todo 比 content/done/source，record 比 title/amount/unit/note/kind/source，goal 还比 steps 数量）。
/// - 条目类型、排序口径、UserDefaults key、文件名。
/// 这些留在各自 Store 里 —— 合并策略是产品语义，抽成参数表只是把重复从代码搬到参数里。
enum SyncedStore {

    // MARK: - 路径

    /// 远端 JSON 文件的完整路径。空 storagePath 时落到默认 NAS 目录（5 个 Store 同一处）。
    static func remotePath(storagePath: String, fileName: String) -> String {
        let base = storagePath.isEmpty
            ? "/volume1/docker/hermes/微信文件/轻聊web/data"
            : storagePath
        return "\(base)/\(fileName)"
    }

    // MARK: - 编解码（宽松 ISO8601 两端对齐）
    //
    // ⚠️ 同一份文件有**两个写入方**：App 自己（`.iso8601` → `2026-10-04T03:14:51Z`）和后端
    //    （goals/todos 由 goal_module、proactive_agent 回写）。后端历史上用
    //    `datetime.now().isoformat()` 写过 naive + 微秒（`2026-10-04T09:59:58.666916`），
    //    而 `.iso8601` 解码策略**只认**「带时区 + 无小数秒」→ 整个数组 dataCorrupted →
    //    被下面 `try?` 吞掉 → loadFromServer 静默 return → 界面永远停在本地旧快照
    //    （待办不自动划、目标步骤与任务中心不对应、卡片看不到报告）。后端写入侧已统一成
    //    `…Z`，这里同时把解码做成宽松，防任何写入方再犯（真值表 scripts/ql_goal_ts）。

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601     // App 写出的形态 `…Z`，后端 fromisoformat 照常解析
        return e
    }

    /// 宽松解析两种来源的 ISO8601 串；返回 nil 表示不是可识别的时间格式。
    static func parseISO(_ s: String, frac: ISO8601DateFormatter,
                         plain: ISO8601DateFormatter, naive: DateFormatter) -> Date? {
        if let d = frac.date(from: s) { return d }     // `…T09:59:58.666Z`（带小数秒）
        if let d = plain.date(from: s) { return d }    // `…T09:59:58Z` / `…+08:00`
        // 尾缀 Z 落到这里只说明小数秒位数（6 位）没被上面认出来 —— naive 按 UTC 解仍正确（只丢亚秒精度）；
        // 但**带显式偏移**（+08:00 / -05:00）也落到这里，naive 会把本地时间当 UTC 硬解、整条差 8 小时。
        // 那种串宁可判「不认识」（返回 nil），也不给出错 8 小时的时间。
        if !s.hasSuffix("Z"), !s.hasSuffix("z"),
           s.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil { return nil }
        // 无时区（历史值）：容器 TZ=UTC，故按 UTC 解释；小数秒直接截掉（毫秒精度对展示无影响）
        let head = s.split(separator: ".").first.map(String.init) ?? s
        return naive.date(from: head)
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        // 每次 makeDecoder 建一次 formatter（不放 static let：Swift 6 下静态 mutable 对象要过并发检查，
        // 而这里每次 load 只创建一次，开销可忽略）
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "en_US_POSIX")
        naive.timeZone = TimeZone(identifier: "UTC")
        naive.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parseISO(s, frac: frac, plain: plain, naive: naive) else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "无法解析的时间戳：\(s)")
            }
            return date
        }
        return d
    }

    /// 快照编码。失败返回 nil（调用方直接放弃这次保存，与原实现一致）。
    static func encode<T: Encodable>(_ items: [T]) -> Data? {
        try? makeEncoder().encode(items)
    }

    static func decode<T: Decodable>(_ type: [T].Type, from data: Data) -> [T]? {
        try? makeDecoder().decode(type, from: data)
    }

    // MARK: - 本地兜底

    /// 从 UserDefaults 读本地快照（策略与 save 对齐，见上方 2）。
    static func readLocal<T: Decodable>(_ type: [T].Type, defaultsKey: String) -> [T]? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return decode(type, from: data)
    }

    // MARK: - NAS 文件通道

    /// POST /api/files/pin_write：把快照落到 NAS 同一 path。
    /// SR33 教训：auth 必须**强**传递进来（调用方先绑成局部常量）——
    /// 弱引用会在调度间隙被清空 → 整次回写静默丢失（本地有、界面无异状，只在另一台设备上缺条）。
    @MainActor
    static func writeToFile(auth: AuthStore?, path: String, data: Data) async {
        guard let auth else { return }
        // v4.0.60：写快照**只走直连、不降级 relay**（自动写不该弹 ASWAS 授权窗），失败即入待补传队列。
        // 此前是 `try?` 静默吞错：蜂窝下写失败就只剩本地快照，换设备/重装才发现缺条
        // （用户 2026-10-05 报「待办没有被创建」即此类）。成功则清掉队列里该 path 的旧副本
        // ——防「旧快照补传后到、覆盖掉更新的快照」。
        if await auth.pushSnapshot(path: path, data: data) {
            PendingPinWrites.discard(path: path)
        } else {
            PendingPinWrites.enqueue(path: path, data: data)
        }
    }

    /// GET /api/files/pin_read：读远端快照并解码。读不到/解不开一律返回 nil（保持调用方原语义）。
    @MainActor
    static func readRemote<T: Decodable>(_ type: [T].Type, auth: AuthStore?, path: String) async -> [T]? {
        guard let auth else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        guard let j = try? await auth.json("/api/files/pin_read?path=\(encoded)"),
              let b64 = j["data"] as? String,
              let data = Data(base64Encoded: b64) else { return nil }
        return decode(type, from: data)
    }

    // MARK: - FIFO 写链
    //
    // 为什么必须 FIFO（各 Store 的 save() 里那两行的由来）：5 个 Store 的远端合并都是**并集**，
    // 替换式写链里慢的旧快照后到 NAS = 已删条目在远端复活，下次 loadFromServer 又被并集拉回来。
    // 正解形态（每个 Store 各留两行，因为它同时是「本仓的链头持有者」和护栏钉死的口径）：
    //
    //     let prev = writeChain
    //     writeChain = Task {
    //         await prev.value                               // FIFO：等前一次写完再写本次快照
    //         await SyncedStore.writeToFile(auth: authForWrite, path: path, data: data)
    //     }
    //
    // 这两行**刻意没有**再抽一层：v4.0.x 起它被第 31 段护栏以「RecordStore.swift 里必须出现
    // `await prev.value`」的形式钉死（守的是「撤销不会被慢的旧快照覆盖」这个行为）。
    // 再包一层就要靠一条 grep 护栏去盯一个函数调用，护栏强度下降、而省下的只有两行 —— 不划算。
}
