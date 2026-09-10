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
        return DiagEnv(
            version: version,
            build: build,
            device: UIDevice.current.model,
            os: UIDevice.current.systemVersion,
            network: DiagnosticsPayload.networkLabel(
                isCellular: NetworkMonitor.shared.isCellular,
                isSatisfied: NetworkMonitor.shared.isSatisfied)
        )
    }

    /// 刷新并写入 Store（诊断页 / 上报前 / 启动时调用）
    @MainActor
    static func refresh() {
        DiagnosticsStore.setEnv(snapshot())
    }
}
