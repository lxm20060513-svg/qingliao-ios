// v4.0.x 设置页「后端列表响应」的统一解码（工作线 C：16 份 load() 收敛）
//
// 为什么有这个小文件：Settings 下有一批设置页的加载路径，末段形态逐字相同——
//   取 d[key] 里的 [[String: Any]] → 映射成具体条目类型
// （CloudDriveItem / MailAccountItem / AgentRuleItem / HistoryItem / LocalModelInfo 各一份）
// 过去每处各写一遍。抄漏过一次真事故：CloudDriveBrowserSheet 少抄了 ok 闸那一支
// （后端 200 里包 ok:false 被当成成功、列表被清空），所以把这半截解码钉成单一真源。
//
// ⚠️ 口径边界（**不要顺手扩大**）：
// 1) **只收「取数组 + 映射」这一半，ok 闸不许挪进来**。带 ok 闸的两个调用点
//    （CloudDriveSettingsSheet/MailSettingsSheet）各自被真值表 ql_clouddrive / ql_mail
//    按源码文本钉住 `guard let ok = d["ok"] as? Bool, ok else`——ok 闸留在原地是刻意的，
//    它标记的是「这个后端把异常包在 200 里」这条契约，不是可复用的解码步骤。
// 2) 另有一批接口根本不查 ok（/api/agent/rules、/api/history、/api/local/models：
//    后端从不包错误的约定）。给它们加 ok 闸等于改行为（200+ok:false 会静默变空列表），
//    那是修 bug、不属于本次重构。
// 3) 用 `?? []` 兜底：字段缺失 = 空列表，与这 5 处原实现逐字一致。
//    真正需要「形状不对就报错」的（如 /api/files/list 的 entries）另有形状闸，不走这里。
//
// 纯函数，不碰 AuthStore、不持有状态 → 非隔离，调用点在 @MainActor 的 View 里也安全。

import Foundation

enum SettingsLoad {
    /// 从响应字典的 `key` 字段取出 `[[String: Any]]` 并逐条映射成具体类型。
    /// 字段缺失/类型不符 → 空数组（与各调用点原行为一致，不静默变错误态）。
    static func list<T>(_ d: [String: Any], key: String,
                        make: ([String: Any]) -> T) -> [T] {
        (d[key] as? [[String: Any]] ?? []).map(make)
    }
}
