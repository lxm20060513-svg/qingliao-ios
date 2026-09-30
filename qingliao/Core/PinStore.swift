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

    /// v4.0.x 复核补：NAS 写链 FIFO（等前一次写完再写本次快照），防并发写同一 path 时
    /// 慢的旧快照后到 → 远端复活已删条目。排队形态由 SyncedStore 统一注释说明
    /// （5 个 Store 的写链是同一份修法，见 Core/SyncedStore.swift 的「FIFO 写链」段）。
    private var writeChain: Task<Void, Never> = Task {}

    /// 钉一钉数据文件的完整路径（NAS 上）
    private var pinsFilePath: String {
        SyncedStore.remotePath(storagePath: storagePath, fileName: defaultFileName)
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

    // MARK: - 持久化

    private func save() {
        // 编解码策略（.iso8601）由 SyncedStore 统一持有，两端天然对齐
        guard let data = SyncedStore.encode(pins) else { return }

        // 写本地 UserDefaults 兜底
        UserDefaults.standard.set(data, forKey: "qingliao_pins_data")

        let path = pinsFilePath
        // SR33：必须**强**捕获 auth（先绑成局部常量）。原来这里是 `[weak auth]` —— 写任务真正跑起来时
        // 调用方栈早已退出，弱引用可能在调度间隙被清空 → 整次 NAS 回写静默丢失
        //（本地 UserDefaults 有、界面无异状，只在另一台设备上看得到缺条）。与 MemoStore 同款。
        let authForWrite = auth
        // v4.0.x 复核补：FIFO 串行写链，防并发写同一 path 时慢的旧快照后到 → 远端复活已删便签。
        // PinStore 的 loadFromServer 也是**并集**合并，复活后没有墓碑能挡住。
        // 排队形态见 Core/SyncedStore.swift 的「FIFO 写链」段。
        let prev = writeChain
        writeChain = Task {
            await prev.value                                  // FIFO：等前一次写完再写本次快照
            await SyncedStore.writeToFile(auth: authForWrite, path: path, data: data)
        }
    }

    private func loadLocal() {
        // 先从本地 UserDefaults 加载
        // v3.9.14 fix：解码策略与 save() 的 .iso8601 对齐（同 MemoStore 的问题：默认策略解字符串日期必失败，
        // 本地兜底等于没有）——这处是从 MemoStore 复制过去的同款 bug，一并修
        if let decoded = SyncedStore.readLocal([PinItem].self, defaultsKey: "qingliao_pins_data") {
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
        // 远端读盘 + 解码（与 loadLocal 共用同一套 .iso8601 策略，见 SyncedStore）
        guard let decoded = await SyncedStore.readRemote([PinItem].self, auth: auth, path: pinsFilePath) else { return }
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
    //
    // v4.0.x：pin_write / pin_read 这对后端接口与编解码策略已收进 Core/SyncedStore.swift
    // （5 个 Store 共用，单一真源）——这里不再各抄一份 static 方法。
}
