import SwiftUI

// v4.0.85：看板栏目标题行的行首图标（口径与生活页板块头 v4.0.84 方案 B① 同款）。
//
// 用户 2026-10-09 真机口径：「看板页的各个标题头，像设备体检，智能家居，NAS 面板，模型使用量，
// token 用量，路由器都加上圆角多彩图标」—— 12 个栏目一律加（只加被点名的那几个会在同页留下一半裸文字）。
//
// 为什么单开一个文件：`enum BoardCard` 住在 Core/BoardCardOrder.swift（**纯 Foundation**，
// 看板真值表 scripts/ql_board 直接编译它，混 SwiftUI 依赖就编不过）—— 那里放不了 `Color`。
// 于是「图标 + 配色」这对**必须成对同改**的映射并置在这里（仿 Features/Life/LifeSection.swift
// 把 icon/tint 写在同一个 enum 里的做法，理由同：图标与配色只此一处，别在两处各写一份）。
//
// ⚠️ 标题行的**几何**不在这里：栏目头走 `BadgeShell(size: 20, …)`（Features/Life/LifeBadges.swift
//    的唯一边长/圆角真源），本文件只提供「哪个符号、什么颜色」。
// ⚠️ 符号全部取仓内已被别处用过的 SF Symbol（或 iOS 13 起的经典符号）—— 本机没有 iOS SDK，
//    拼错的符号名不会编译报错，只会渲染成空白色块（真机才发现）。新增符号前先在仓里 grep 一次。
extension BoardCard {

    /// 栏目头行首符号（20pt 色块用的白符号）
    var icon: String {
        switch self {
        case .suggestion: return "lightbulb.fill"          // 建议 → 灯泡
        case .home: return "house.fill"                    // 智能家居（同 ConnectorPanelSheet 的家居映射）
        case .scenes: return "wand.and.stars"              // 场景 → 魔法棒
        case .automations: return "gearshape.fill"         // 自动化 → 齿轮
        case .rules: return "slider.horizontal.3"          // 规则 → 阈值滑杆
        case .nas: return "externaldrive.fill"             // NAS 面板（同网盘/存储既有映射）
        case .usage: return "dollarsign.circle.fill"       // 模型使用量 = 余额
        case .tokens: return "chart.bar.fill"              // token 用量
        case .diagnose: return "stethoscope"               // 设备体检（同「诊断」既有映射）
        case .router: return "network"                     // 路由器 → 网络
        case .pin: return "pin.fill"                       // 钉一钉（同「钉一钉存储」既有映射）
        case .connectors: return "link"                    // 连接器 → 接入
        }
    }

    /// 栏目头行首底色（与 icon 同处一份映射；取各栏目语义色，深浅模式由系统色自适应）
    /// ⚠️ 12 个栏目取 12 种不同颜色（真值表 ql_uitokens 钉了「去重后仍是 12 种」）——
    ///    同页多个栏目用同一个颜色 = 又退回「一片同色的色块墙」，等于白加。
    var tint: Color {
        switch self {
        case .suggestion: return .yellow
        case .home: return .orange
        case .scenes: return .purple
        case .automations: return .blue
        case .rules: return .brown
        case .nas: return .teal
        case .usage: return .green
        case .tokens: return .mint
        case .diagnose: return .red
        case .router: return .indigo
        case .pin: return .pink
        case .connectors: return .cyan
        }
    }
}
