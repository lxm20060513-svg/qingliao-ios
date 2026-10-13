// GoalEditKit 行为测试（#16a 长期目标可编辑 · 请求体构造 / 时间钳位 / 是否真改动）
//
// 编译运行（仓库根）：$SWIFT/swiftc -swift-version 6 -o /tmp/test_goal_edit \
//     qingliao/Core/GoalEditKit.swift <本文件>
// 纯 Foundation，无 UIKit/SwiftUI 依赖 → 本机 Linux 工具链可真跑。

import Foundation

nonisolated(unsafe) var failures = 0
func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

// MARK: - ① 区间口径（必须与新建表单 Stepper 逐字一致，护栏会比对源码）

check("早间区间 = 6...12", GoalEditKit.morningRange == 6...12)
check("晚间区间 = 18...23", GoalEditKit.eveningRange == 18...23)

// MARK: - ② 钳位：越界裁剪、边界不动

check("早间钳位 0 → 6", GoalEditKit.clampMorning(0) == 6)
check("早间钳位 13 → 12", GoalEditKit.clampMorning(13) == 12)
check("早间边界 6 / 12 不动", GoalEditKit.clampMorning(6) == 6 && GoalEditKit.clampMorning(12) == 12)
check("晚间钳位 17 → 18", GoalEditKit.clampEvening(17) == 18)
check("晚间钳位 24 → 23", GoalEditKit.clampEvening(24) == 23)
check("晚间边界 18 / 23 不动", GoalEditKit.clampEvening(18) == 18 && GoalEditKit.clampEvening(23) == 23)

// MARK: - ③ payload：键齐、值经钳位、标题去空白

let payload = GoalEditKit.payload(id: "g1", title: "  筹备发布  ",
                                  morningEnabled: true, eveningEnabled: false,
                                  morningHour: 30, eveningHour: 1)
check("payload 恰好 6 个键（不多不少）", payload.count == 6)
check("payload 与后端键名逐字对齐（写错键名后端会静默忽略）",
      Set(payload.keys) == ["id", "title", "morningEnabled", "eveningEnabled", "morningHour", "eveningHour"])
check("payload id 原样带回", payload["id"] as? String == "g1")
check("payload 标题去首尾空白", payload["title"] as? String == "筹备发布")
check("payload 开关保真", payload["morningEnabled"] as? Bool == true && payload["eveningEnabled"] as? Bool == false)
check("payload 时刻经钳位（30→12、1→18）",
      payload["morningHour"] as? Int == 12 && payload["eveningHour"] as? Int == 18)

// MARK: - ④ hasChanges：真改才发请求

func changed(title: String = "A", morning: Bool = true, evening: Bool = true, mh: Int = 9, eh: Int = 21,
             currentTitle: String = "A", currentMorning: Bool = true, currentEvening: Bool = true,
             currentMH: Int = 9, currentEH: Int = 21) -> Bool {
    GoalEditKit.hasChanges(currentTitle: currentTitle, currentMorningEnabled: currentMorning,
                           currentEveningEnabled: currentEvening, currentMorningHour: currentMH,
                           currentEveningHour: currentEH, title: title, morningEnabled: morning,
                           eveningEnabled: evening, morningHour: mh, eveningHour: eh)
}

check("原样不动 → false（不发请求、不白盖 updatedAt）", changed() == false)
check("只改标题 → true", changed(title: "B") == true)
check("只关早间 → true", changed(morning: false) == true)
check("只关晚间 → true", changed(evening: false) == true)
check("只挪早间时刻 → true", changed(mh: 10) == true)
check("只挪晚间时刻 → true", changed(eh: 22) == true)
check("标题首尾空白不算改动（「 A 」vs「A」）", changed(title: "  A  ") == false)
check("空标题不算改动（不可保存）", changed(title: "   ") == false)
check("钳位后同值不算改动（30 与 12 同为 12）", changed(mh: 30, currentMH: 12) == false)
check("钳位后确不同才算改动（30 与 11 → 12 vs 11）", changed(mh: 30, currentMH: 11) == true)

// MARK: - ⑤ 可保存判定

check("canSave：纯空白 → false", GoalEditKit.canSave(title: "   ") == false)
check("canSave：有字 → true", GoalEditKit.canSave(title: "筹备发布") == true)

print(failures == 0 ? "\n🎉 全部通过" : "\n❌ \(failures) 个失败")
exit(failures == 0 ? 0 : 1)
