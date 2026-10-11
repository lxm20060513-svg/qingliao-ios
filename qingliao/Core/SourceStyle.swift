import SwiftUI

/// 内容来源配色真源（v4.0.65 · 用户 2026-10-06 看对比稿拍板「待办走 B / 备忘走 A」）
///
/// 备忘与待办的**列表行**都按「这条内容从哪来」上色，色板与记录分类卡（RecordCategoryColor）
/// 同一套语言（蓝 / 紫 / 青 / 靛 / 橙 / 灰）——三处列表看起来才是一家人。
///
/// ⚠️ 单一出口：来源 → 颜色只此一处。谁在别的文件里再写一份 switch，同一个「聊天」来源
/// 就会在待办页和备忘页长出两种蓝（静默错，不报错）。
/// 来源**符号名**仍归 MemoItem / TodoItem 各自持有（那是数据域，不是配色），本表只管颜色。
enum SourceStyle {
    /// 来源 → 语义色（走系统语义色：深色模式自动适配，与 RecordCategoryColor.palette 同口径）
    static func tint(_ source: String) -> Color {
        switch source {
        case "chat":            return .blue     // 聊天
        case "ai", "intent":    return .purple   // AI / 识别（识别产出的同样是 AI 内容，同色）
        case "orb":             return .teal     // 智能球
        case "bigbang":         return .indigo   // 选词
        case "meeting":         return .orange   // 会议纪要
        case "goal":            return .orange   // 目标（v4.0.92：目标步骤灌进待办，与生活页目标区同色）
        case "shortcut":        return .indigo   // 快捷指令 / 自动化（v4.0.92：与「选词」共靛 —— 色板六色
                                                // 已是全部家当，同为「工具」语义宁可共用，不许落「未知来源」灰）
        default:                return .gray     // 手记 / 手动 / 未知来源
        }
    }
}
