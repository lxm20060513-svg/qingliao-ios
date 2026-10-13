import Foundation

// MARK: - v4.0.104（#16a）：长期目标「编辑」的纯逻辑层
//
// 由头：目标建完就改不了 —— 标题、早/晚提醒开关与时刻全钉死在建的那一刻，只能删了重建。
// 后端 `goal_module.goals_update`（PATCH /api/life/goal）早就支持 `title / morningEnabled /
// eveningEnabled / morningHour / eveningHour`，缺的只是 App 侧的编辑入口 + 落库口径。
//
// 为什么把请求体构造与时间钳位单独抽一个文件：
//   ① **唯一真源**：编辑表单、Store 推后端、真值表三处必须用同一份 payload/钳位口径，
//      否则「表单能选 13 点、后端收到被裁成 12 点」这类分叉没人发现；
//   ② 纯 Foundation（不碰 GoalItem/SwiftUI）→ 能在本机 Linux 工具链**真跑**单测
//      （见 scripts/ql_goal_edit/test_goal_edit.swift）。
//
// ⚠️ 区间口径必须与新建表单的 Stepper 一致（GoalsAddBody 里 `6...12` / `18...23`），
//    护栏会逐字比对 —— 改一处就得改两处，这是刻意的。

enum GoalEditKit {

    /// 早间推进提醒可选整点（与新建表单 Stepper 区间一致）
    static let morningRange = 6...12
    /// 晚间复盘可选整点（同上）
    static let eveningRange = 18...23

    static func clampMorning(_ hour: Int) -> Int {
        min(max(hour, morningRange.lowerBound), morningRange.upperBound)
    }

    static func clampEvening(_ hour: Int) -> Int {
        min(max(hour, eveningRange.lowerBound), eveningRange.upperBound)
    }

    /// 标题可用（非空）
    static func canSave(title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 后端 PATCH /api/life/goal 的请求体（键名与 `goal_module.goals_update` 支持的键一一对应）
    static func payload(id: String,
                        title: String,
                        morningEnabled: Bool,
                        eveningEnabled: Bool,
                        morningHour: Int,
                        eveningHour: Int) -> [String: Any] {
        [
            "id": id,
            "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
            "morningEnabled": morningEnabled,
            "eveningEnabled": eveningEnabled,
            "morningHour": clampMorning(morningHour),
            "eveningHour": clampEvening(eveningHour)
        ]
    }

    /// 编辑是否真的改了东西 —— 没改就别发请求、别白盖 updatedAt（也避免多设备把旧快照推回）
    static func hasChanges(currentTitle: String,
                           currentMorningEnabled: Bool,
                           currentEveningEnabled: Bool,
                           currentMorningHour: Int,
                           currentEveningHour: Int,
                           title: String,
                           morningEnabled: Bool,
                           eveningEnabled: Bool,
                           morningHour: Int,
                           eveningHour: Int) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }       // 空标题不算「改动」，调用方按不可保存处理
        return t != currentTitle
            || morningEnabled != currentMorningEnabled
            || eveningEnabled != currentEveningEnabled
            || clampMorning(morningHour) != clampMorning(currentMorningHour)
            || clampEvening(eveningHour) != clampEvening(currentEveningHour)
    }
}
