import SwiftUI

// MARK: - v3.9.19 胶囊尺寸口径（PillSize / PillTone）
//
// 背景：`.padding(...) + Capsule()` 的组合散落全仓（光 h10 就 30 处，纵向外边距 4/5/6/9/12 各有若干），
// 同类胶囊在不同页面尺寸不一（栏目头的、顶栏的、主操作的各不相同又互相接近）。
// 收敛为**三种口径**（用户 2026-09-14 拍板）：
//
//   page     页级栏目头 —— tiny + h10/v4（「生活数据」右侧 添加股票 / 刷新）
//   topBar   顶栏 / 工具条 —— subhead + h12/v5（备忘录详情的 关闭 / 编辑 / 复制、「全部备忘」的 完成）
//            v3.9.22：原 tiny + h10 文字被反馈太小 → 提字号至 subhead、横向放宽到 12（高度不变，仍是小按钮）
//   primary  主操作 —— body + h14/v12（备忘录详情底部的 置顶 / 发给 AI / 删除这条备忘）
//
// ⚠️ **不在口径内的不要硬套**（各自合适即可）：聊天输入栏、会话列表标签、筛选 chip、状态徽标、
// 文章内小标签（tiny + h6/v1）等 —— 它们不是"操作胶囊"，套上来只会变大变笨。

enum PillSize {
    /// 页级栏目头：tiny + h10/v4
    case page
    /// 顶栏 / 工具条：tiny + h10/v5
    case topBar
    /// 主操作：body + h14/v12
    case primary

    var fontSize: CGFloat {
        switch self {
        case .page: return Typography.tiny
        // v3.9.22：用户反馈「完成/关闭/编辑」这类顶栏胶囊**文字**太小（10pt）
        // ——注意诉求是文字小，不是胶囊大：所以只提字号并略放宽横向，高度仍保持紧凑
        case .topBar: return Typography.subhead
        case .primary: return Typography.body
        }
    }

    var hPad: CGFloat {
        switch self {
        case .page: return 10
        case .topBar: return 12          // v3.9.22：随字号一起放宽，避免 13pt 文字挤在 10pt 边距里
        case .primary: return 14
        }
    }

    var vPad: CGFloat {
        switch self {
        case .page: return 4
        case .topBar: return 5
        case .primary: return 12
        }
    }
}

/// 胶囊色调：一律"淡底 + 同色文字"（用户明确否决过实色胶囊）
enum PillTone {
    /// 主题色淡底（默认）
    case accent
    /// 危险动作淡底（删除类）
    case danger
    /// 次要中性（关闭 / 取消类）
    case neutral

    var bg: Color {
        switch self {
        case .accent: return Color.accentColor.opacity(Tint.subtle)
        case .danger: return Color.red.opacity(Tint.subtle)
        case .neutral: return Color.secondary.opacity(Tint.subtle)
        }
    }

    var fg: Color {
        switch self {
        case .accent: return Color.accentColor
        case .danger: return Color.red
        case .neutral: return Color.primary
        }
    }
}

extension View {
    /// 操作胶囊统一入口（尺寸 + 色调一处定义，改口径只改这里）
    func pill(_ size: PillSize, tone: PillTone = .accent) -> some View {
        self
            .font(.system(size: size.fontSize))
            .foregroundStyle(tone.fg)
            .padding(.horizontal, size.hPad)
            .padding(.vertical, size.vPad)
            .background(tone.bg, in: Capsule())
    }
}
