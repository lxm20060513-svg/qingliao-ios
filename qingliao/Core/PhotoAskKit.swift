import Foundation

// MARK: - v4.0.x 拍照识别（球上浮层卡）的纯口径
//
// 用户口径（2026-09-27 拍板）：「长按智慧球的拍照识别改成**不发送当前对话框**，直接在当页做」——
//   呈现形态 = **球上浮层卡**（与现有「AI 识别」同一形态：背景虚化 + 球心扫描环；用户先选过全屏页、
//   随即改回本形态），结果不落会话、不切聊天页。
//   所以本文件里的一切都是「就地看」这条口径的常量，提示词沿用旧口径（发进会话时那句）逐字不变。
//
// 纯 Foundation（不 import UIKit / SwiftUI）→ 本机没有 iOS SDK 也能编进真值表，
// 口径漂移（有人顺手改了提示词 / 超时 / 文案）能被 `scripts/ql_photoask` 当场钉住。

enum PhotoAskKit {

    /// 发给 AI 的提示词 —— 与 v3.9.93 旧口径（拍完发进当前会话那条）**逐字一致**：
    /// 用户要的是「内容跟现在发给 AI 的一样，只是就地显示」，不是换一个问法。
    static let prompt = "帮我看看这张照片"

    /// 一问一答超时：与 `QingliaoIntentClient.oneShot` 默认值同源（后端要跑 Hermes agent 工具循环，
    /// 给小了长回答会被掐断；这条链路的默认值散在两处必然漂移，所以这里显式钉一份）。
    static let timeout: TimeInterval = 120

    /// 拿到回答前的等待文案
    static let waitingTitle = "正在看图…"
    static let waitingDetail = "看完即走，不会发进会话"

    /// 失败态标题（**不留白**：静默退回等于让用户以为「点了没反应」，本仓明令禁止）
    static let failureTitle = "没拿到回答"

    /// 失败详情：带上真因（网络 / 上游 502 / 超时），别只说「失败」（真因查不出来时用户只能瞎猜）。
    /// 用 `localizedDescription` 而不是 `"\(error)"`：前者对 `LocalizedError`（本仓的
    /// `QingliaoIntentError` 就是）拿到的是人话，后者拿到的是结构体 dump（「FakeError()」那种）。
    static func failureDetail(_ error: Error?) -> String {
        guard let error else { return "图片没压好，换一张或重试" }
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneLine = text.split(separator: "\n").first.map(String.init) ?? text
        return oneLine.isEmpty ? "网络或后端没回，可以重试" : String(oneLine.prefix(80))
    }
}
