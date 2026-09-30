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

    // MARK: - 编解码（.iso8601 两端对齐）

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
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
        let body: [String: Any] = ["path": path, "data": data.base64EncodedString()]
        _ = try? await auth.json("/api/files/pin_write", method: "POST", body: body)
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
