import Foundation
import UIKit

// MARK: - v3.6.0 环境快照（唯一 import UIKit 的诊断文件）
//
// DiagnosticsPayload / DiagnosticsStore 保持纯 Foundation 以便本机单测；
// 设备型号、系统版本、网络类型统一由这里采集后写入 Store。
// 只采白名单字段（型号 / 系统版本 / 网络类型），不采 IDFA / 序列号 / 用户名等任何可识别信息。

enum DiagnosticsEnv {
    /// 采集当前环境快照（主线程：UIDevice 与 NetworkMonitor 都是主线程读取）
    static func snapshot() -> DiagEnv {
        var version = ""
        var build = ""
        if let info = Bundle.main.infoDictionary {
            version = (info["CFBundleShortVersionString"] as? String) ?? ""
            build = (info["CFBundleVersion"] as? String) ?? ""
        }
        // v3.9.10：先按当前网络路径即时刷新一次，避免上报里带着上一跳的网络类型
        NetworkMonitor.shared.refreshFromCurrentPath()
        return DiagEnv(
            version: version,
            build: build,
            device: Self.hardwareModel(),
            os: UIDevice.current.systemVersion,
            network: DiagnosticsPayload.networkLabel(
                isCellular: NetworkMonitor.shared.isCellular,
                isSatisfied: NetworkMonitor.shared.isSatisfied)
        )
    }

    /// v3.9.10 fix：硬件标识（"iPhone17,2"这种）。原来用 `UIDevice.current.model`，
    /// 它只是设备族名（恒为 "iPhone"/"iPad"）→ 服务端无法按机型聚合卡顿/崩溃，
    /// 而异构机型差异恰恰是 iOS 26 卡顿类问题的关键变量。仍不含任何用户可识别信息。
    static func hardwareModel() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return UIDevice.current.model }
        let mirror = Mirror(reflecting: info.machine)
        let id = mirror.children.reduce(into: "") { acc, el in
            guard let v = el.value as? Int8, v != 0 else { return }
            acc.append(Character(UnicodeScalar(UInt8(bitPattern: v))))
        }
        return id.isEmpty ? UIDevice.current.model : id
    }

    /// 刷新并写入 Store（诊断页 / 上报前 / 启动时调用）
    @MainActor
    static func refresh() {
        DiagnosticsStore.setEnv(snapshot())
    }
}
