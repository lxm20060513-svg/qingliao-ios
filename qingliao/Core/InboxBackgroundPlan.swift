import Foundation

// MARK: - ② 后台唤醒补拉收件箱：**纯逻辑**（本机真值表可验，无网络/无 IO）
//
// 起因（代码级事实）：`QingliaoAppDelegate.performFetchWithCompletionHandler` 自 v2.0.110 起
// 只在 UserDefaults 里有 `qingliao_stream_pending`（**上一轮 AI 回复还没跑完**）时才去查
// `/api/stream/{taskId}`，查到 done/error 就弹一条通知 —— 它**从不查收件箱**。
// 于是 Hermes 推进收件箱的消息（任务中心 / 告警 / 目标日报 / AI 追问）在 App 挂起期间
// 一条也弹不出来：用户不开 App 就永远不知道。这就是"推送不及时"里最大的那个洞。
//
// 本类型只回答「一次唤醒该为哪几条弹通知」，网络与弹通知分别由
// `QingliaoAppDelegate.checkInbox` 与 `NotificationHelper` 负责。
//
// 与前台口径的关系（别各改一套）：
//   · `consumedIds` = 前台 `InboxStore` 维护的「已注入并弹过通知」集合 ⇒ 命中即跳过，
//     不会出现"前台弹过、后台又弹一遍"；
//   · 后台**不 markDone**、也不注入会话气泡（那是前台的事）⇒ 条目留在队列里等前台拉取。
//     代价是前台随后会用**同内容**再弹一次，靠 `NotificationHelper` 的稳定 identifier
//     （正文哈希）就地替换同一张通知 ⇒ 不堆叠（v3.0.x 起就是这个口径）。
enum InboxBackgroundPlan {

    /// 一次唤醒最多弹几条：App 被关了几小时、队列里攒了十几条时，
    /// 一次性刷满通知中心比少弹几条更糟（用户会当成故障）。剩下的交给前台拉取。
    static let maxPerWake = 5

    /// 后台**不补发**的 task_type：
    /// `progress` 是"AI 正在干活"的实时指示器（必须在会话里连着看才有意义），
    /// 后台补发只会是迟到残片 —— 与 v4.0.11「任务落地后丢弃同任务残片」同源。
    static let skippedTypes: Set<String> = ["progress"]

    /// 问题卡的「题干」切法（`选项：` 独立分隔行之前的部分）—— 与前台
    /// `ChatMessage.splitQuestion(_:).body` **同一口径**。
    ///
    /// 🚨 为什么这里自己切一刀、而不是直接调 `ChatMessage.splitQuestion`：本文件是**纯 Foundation**
    ///    （要进本机真值表真跑），而 `Models.swift` 带 `import SwiftUI` ⇒ 这里引用不到那个类型。
    ///    而正文口径一旦分叉：`NotificationHelper` 的通知 identifier 是**正文哈希** ⇒ 同一条追问
    ///    在通知中心留两条（后台那条还带着选项清单），而前台/后台各自看都对（只有真机能看出重复）。
    ///    护栏：`scripts/ql_bg/truth_table_bg.swift` 既钉本函数的切法，也钉 `Models.swift` 里那个
    ///    函数仍以 `选项：` 为分隔行（改一边就转红）。
    static func questionBody(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let sep = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "选项："
        }) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let body = lines[..<sep].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? text : body   // 与 splitQuestion 的兜底逐字一致
    }

    /// 一条待补发的通知
    struct Item: Equatable, Sendable {
        let id: String          // 收件箱条目 id（去重靠它）
        let kind: String        // 后端 task_type，交给 QingliaoNotifyKind.fromTaskType
        let body: String
        let detail: String?     // 目前只有 question 用（"需要你确认"，与前台口径一致）
        let sessionId: String?  // 归属会话（点通知直达）
    }

    /// 决定「这次唤醒弹哪几条」
    /// - Parameters:
    ///   - items: `GET /api/inbox` 的 items（原始字典，字段 id / text / task_type / session_id）
    ///   - consumedIds: 前台已消费过的 id 集合
    ///   - limit: 上限（测试用；生产走默认值 `maxPerWake`）
    static func plan(items: [[String: Any]], consumedIds: Set<String>,
                     limit: Int = InboxBackgroundPlan.maxPerWake) -> [Item] {
        guard limit > 0 else { return [] }
        var out: [Item] = []
        for d in items {
            // ① 无 id / 正文为空的不弹（空通知是纯骚扰；老后端字段名不同也在这里被挡掉）
            guard let id = (d["id"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
                  let text = (d["text"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty
            else { continue }
            // ② 前台已注入并弹过 → 跳过（否则同一条会弹两次）
            guard !consumedIds.contains(id) else { continue }
            let type = (d["task_type"] as? String) ?? "reply"
            // ③ 实时进度类不补发（见 skippedTypes 说明）
            guard !skippedTypes.contains(type) else { continue }
            // ④ 正文口径与前台对齐：question 的正文是「题干」（`选项：` 那段剥掉），
            //    不能直接塞原始 text（见 questionBody 的说明），否则同一条追问弹两条。
            let body = (type == "question") ? questionBody(text) : text
            // ⑤ detail 只在 question 上给（与前台 `consumeOne` 的文案一致）
            let detail = (type == "question") ? "需要你确认" : nil
            out.append(Item(id: id, kind: type, body: body, detail: detail,
                            sessionId: d["session_id"] as? String))
            if out.count >= limit { break }
        }
        return out
    }
}
