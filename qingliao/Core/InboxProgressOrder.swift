import Foundation

/// v3.9.76（用户定的一条规则）：「这类进度回复要按时间前后推，不要 20 步推在 17 步前」。
///
/// 进度推送（`task_type="progress"`，文案形如 `⏳ AI 正在回复（已生成 152 字，第 17 步 运行代码）`）
/// 是**状态快照**：后端 `_progress_tick` 每静默 30 秒才推一条，且取的是**推送那一刻**的实时字数与
/// 工具步数（`toolSeq`），所以正常送达顺序天然单调递增。
///
/// 唯一会乱序的来源是**投递层重投**：后端 `pop_pending` 会把「僵尸 sending」消息重置回 pending 重投
/// （App 拉到但没来得及 markDone），于是**旧快照可能落在更新的快照之后**被注入 —— 用户看到的就是
/// 「第 20 步」排在「第 17 步」前面。
///
/// 处理口径：**进度只有前进才有意义，迟到的旧快照直接丢弃**（丢弃也必须 markDone，否则后端会一直重投）。
/// ⚠️ 判据必须**按来源任务分组**——`toolSeq` 是每个任务独立计数的，跨任务比会把新任务的「第 3 步」
/// 误判成旧快照丢掉（用户连发两条消息时必现）。分组键用收件箱的 `source_task_id`。
///
/// 放纯 Foundation 文件（不 import UIKit）是为了进本机真值表：解析与判据都能在 Linux 上跑。
enum InboxProgressOrder {

    /// 从进度文案里解析出的快照
    struct Snapshot: Equatable {
        /// 工具调用步数；0 = 文案里没有「第 N 步」（该任务还没跑过工具）
        var step: Int
        /// 已生成字数
        var chars: Int
    }

    /// 解析进度文案；**不是进度文案 → nil**（普通推送/回复不受本机制影响）
    static func snapshot(from text: String) -> Snapshot? {
        guard text.contains("AI 正在回复") else { return nil }
        guard let chars = firstInt(in: text, pattern: "已生成 ([0-9]+) 字") else { return nil }
        return Snapshot(step: firstInt(in: text, pattern: "第 ([0-9]+) 步") ?? 0, chars: chars)
    }

    /// 这条快照该不该注入：只接受**严格前进**的（同一步数比字数；重复或回退一律丢弃）
    static func shouldAccept(_ new: Snapshot, after last: Snapshot?) -> Bool {
        guard let last else { return true }
        if new.step != last.step { return new.step > last.step }
        return new.chars > last.chars
    }

    /// 基准快照是否还「新鲜」（App 重启后内存分组表为空，只能拿会话里最后一条进度气泡兜底——
    /// 进度是单会话串行任务的产物，用时间窗把「上一条任务留下的旧气泡」排除掉，别拿它去比新任务）
    static func isFresh(baselineMs: TimeInterval?, nowMs: TimeInterval, windowMs: TimeInterval = 15 * 60 * 1000) -> Bool {
        guard let baselineMs else { return false }
        return nowMs - baselineMs <= windowMs && baselineMs <= nowMs
    }

    private static func firstInt(in text: String, pattern: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }
}
