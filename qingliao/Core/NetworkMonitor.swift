import Foundation
import Network
import os

/// 网络类型监测：iOS 27 蜂窝下侧载 App 上行被管控（必须走 Safari relay）；
/// Wi-Fi 下 URLSession 直连即可（免 relay 弹窗）。
/// 单例 + MainActor 读取（App 所有请求都在主线程发起），main 队列写入。
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "qingliao.network.monitor")
    /// v3.0.x fix：保护 isCellular 多线程读写（callback 在 monitor queue，读取在主线程）
    private var unfairLock = os_unfair_lock()

    /// 当前是否蜂窝网络（蜂窝 → 需要 relay；Wi-Fi/其他 → 直连）
    private(set) var isCellular: Bool {
        get {
            os_unfair_lock_lock(&unfairLock)
            defer { os_unfair_lock_unlock(&unfairLock) }
            return _isCellular
        }
        set {
            os_unfair_lock_lock(&unfairLock)
            defer { os_unfair_lock_unlock(&unfairLock) }
            _isCellular = newValue
        }
    }
    /// 存储属性
    private var _isCellular = false

    /// v3.4.x 弱网重连：当前网络是否可用（NWPath satisfied）——断网时流式轮询暂停等待恢复
    private(set) var isSatisfied: Bool {
        get {
            os_unfair_lock_lock(&unfairLock)
            defer { os_unfair_lock_unlock(&unfairLock) }
            return _isSatisfied
        }
        set {
            os_unfair_lock_lock(&unfairLock)
            defer { os_unfair_lock_unlock(&unfairLock) }
            _isSatisfied = newValue
        }
    }
    private var _isSatisfied = true

    private init() {
        // v2.0.102：同步读取当前路径——避免首帧请求误判 Wi-Fi（蜂窝下首请求必失败一次）
        let p = monitor.currentPath
        let hasLAN = p.availableInterfaces.contains { $0.type == .wifi || $0.type == .wiredEthernet }
        _isCellular = !hasLAN && (p.isExpensive || p.availableInterfaces.contains { $0.type == .cellular })
        _isSatisfied = (p.status == .satisfied)
        monitor.pathUpdateHandler = { [weak self] path in
            // v2.0.67：有 WiFi/有线接口时绝不判蜂窝（此前 isExpensive 在 WiFi 低数据模式/
            // iOS 27 偶发 true → 误判蜂窝 → 登录走 Safari relay 弹窗，用户实测）
            let hasLAN = path.availableInterfaces.contains { $0.type == .wifi || $0.type == .wiredEthernet }
            let cellular = !hasLAN && (path.isExpensive
                || path.availableInterfaces.contains { $0.type == .cellular })
            let satisfied = (path.status == .satisfied)
            DispatchQueue.main.async {
                self?.isCellular = cellular
                self?.isSatisfied = satisfied
            }
        }
        monitor.start(queue: queue)
    }

    /// v3.9.10：用 NWPathMonitor 的**当前路径**即时刷新一次。
    /// 为什么需要：pathUpdateHandler 的值是经 `DispatchQueue.main.async` 投递到主线程的，
    /// 主线程繁忙时（正是在诊断卡顿的时候）会滞后 —— 切 Wi-Fi/蜂窝后的第一条诊断事件
    /// 往往还报着上一跳的网络类型，于是「蜂窝下卡还是 Wi-Fi 下卡」这个关键区分当场失效。
    /// `NWPathMonitor.currentPath` 可在任意线程安全读取；判定规则与 init / pathUpdateHandler 保持一致
    ///（有 WiFi/有线接口时绝不判蜂窝）。
    func refreshFromCurrentPath() {
        let p = monitor.currentPath
        let hasLAN = p.availableInterfaces.contains { $0.type == .wifi || $0.type == .wiredEthernet }
        isCellular = !hasLAN && (p.isExpensive || p.availableInterfaces.contains { $0.type == .cellular })
        isSatisfied = (p.status == .satisfied)
    }
}
