import Foundation

/// v4.0.37：任务中心「进行中」卡片的结构化步骤（后端 `/api/agent/tasks/active` 的 `plan[]`）。
///
/// 背景（OpenMuse 借鉴⑧，真缺口）：任务中心原先只有一行拼出来的进度字符串
/// （`stream_api.py::_stream_progress_detail`：第 N 步 工具 · N 字 · 静默 X · 最近：…），
/// 用户看不出「一共几步 / 跑到第几步 / 每步花了多久」。
/// 后端补了 `plan[]`（**零新增采集**，复用流式过程中已有的 `toolSpans` / `toolSeq` / `lastTool` 埋点，
/// 见 `stream_api.py::_task_plan`），这里只负责解析与文案口径。
///
/// 抽成纯 Foundation 类型（不 import SwiftUI、不含几何）：解析语义可被真值表**直接编译**验证
/// （`run_unit6` 把本文件与 `scripts/ql_taskplan/truth_table_taskplan.swift` 一起编），
/// 不必起 App、不必看真机 —— 与本仓 `ChatScrollPin` / `BillScanKit` 同一套做法。
enum ActiveTaskPlan {

    /// 单步状态（后端 `st` 字段）。
    /// ⚠️ 只有后端**明确**说 `running` 才画成在跑；缺键、未知值一律按已完成（保守口径：
    /// 宁可把在跑的步画成已完成，也不要把已完成的步画成一直在转圈）。
    enum StepState: String {
        case done
        case running
    }

    struct Step: Identifiable, Hashable {
        let id: Int
        let title: String
        let state: StepState
        /// 已完成步的耗时（秒）。nil = 后端没给（老后端 / 在跑步 / 数值坏了）→ 不显示，也不编 0。
        let seconds: Double?

        var done: Bool { state == .done }
    }

    /// 解析后端 `plan[]`。
    /// · 老后端无此键 / 不是数组 → `[]`（任务中心整块不渲染，优雅退化）
    /// · 项不是字典、缺 `n`、`n` 全空白 → 丢弃该项（不画空行、不错位）
    /// · `st == "running"` → 在跑（耗时不显示：还没结束，显示 0.0s 是假的）
    /// · `s` 非数值（后端脏数据）→ nil（不显示成 0.0s）
    /// · id 按下标给，保证稳定（后端 plan 是追加序，只增不减）
    static func parse(_ raw: Any?) -> [Step] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.enumerated().compactMap { idx, item in
            guard let n = item["n"] as? String,
                  !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let running = (item["st"] as? String) == StepState.running.rawValue
            let secs = (item["s"] as? Double) ?? (item["s"] as? Int).map(Double.init)
            return Step(id: idx,
                        title: n,
                        state: running ? .running : .done,
                        seconds: running ? nil : secs)
        }
    }

    /// 「更早的 N 步未列出」的判据：后端全量步数（`planSeq`）比明细条数多 → 返回被裁步数，否则 nil。
    /// 与聊天页工具卡同一口径（那边是 `toolSteps > toolNames.count` 出 `ToolStepsTruncationNote`）：
    /// 不提示的话摘要写 25 步、明细只列 20 行，看着像丢了几步。
    static func hiddenCount(planSeq: Int, shown: Int) -> Int? {
        let h = planSeq - shown
        return h > 0 ? h : nil
    }

    /// 已收口步数 —— 截断提示的两处数字（「更早 N 步」「只留最近 M 步」）都只能数这项：
    /// 聊天页数的是 `toolNames/toolSpans`（已完成明细），不含「正在跑」那条。若把 running 行也算进去，
    /// 同一任务在聊天页写「更早 1 步未列出」、任务中心却因条数相等**不出提示**，两端口径就分叉了。
    static func doneCount(_ steps: [Step]) -> Int {
        steps.filter { $0.done }.count
    }
}
