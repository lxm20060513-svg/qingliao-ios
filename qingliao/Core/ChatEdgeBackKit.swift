//
//  ChatEdgeBackKit.swift
//  轻聊
//
//  v4.0.82：聊天内容页「左缘右滑 → 返回会话列表」的手势判定（纯逻辑，无 SwiftUI 依赖）。
//
//  为什么单独抽文件：本仓规矩「新写的纯计算先落真值表编译跑一遍再推 CI」，
//  而真值表只能用 swiftc 编译**纯源码**（混进 SwiftUI 依赖就编不过）→
//  单测与源护栏见 scripts/ql_docklayout/truth_table_docklayout.swift。
//
//  用户口径（2026-10-09）：「在聊天内容页增加边缘手势返回会话页功能」。
//  页面层级背景：v4.0.81 起「会话页」已并入聊天 tab（一页两态：首页 ↔ 对话页），
//  所以这条手势**不是切 tab**、也不碰 NavigationStack。
//
//  🚨 v4.0.122（用户 2026-10-18 对着参考截图拍板「要这种跟手滑动返回」）：判定语义**整条换掉**。
//    旧口径 = 「抬手位移 ≥ minTranslation 才认，认了就跳转」——**不跟手**：手指滑、页面一动不动，
//    松手才闪切。新口径 = **跟手**：每帧把位移交给宿主（整页右移、会话首页从左侧同步露出来），
//    松手再按位移/甩动预测判「完成 or 回弹」（微信同款）。
//  三件判定仍在，但门的位置变了：
//    ① 起手门 `isBackStart`：v4.0.125 起**任意位置**都算（用户 2026-10-19 口径）；旧口径是左缘 `edgeWidth`；
//    ② 起手后头一帧就要「够横」（`isHorizontal`：位移 ≥ followStart 且 ≥ |dy| × horizontalBias）
//       —— 挡纵向滚动与斜划；此后本轮不再重复过门（调用方记住 `following`，见 ChatEdgeBackModifier）；
//    ③ 松手判完成（`shouldComplete`）：位移过半，**或**甩动预测终点过半（轻甩也翻页）。
//

import Foundation

/// 左缘右滑跟手返回的判定与阈值（**唯一真源**：改阈值只改这里，别在视图里内联第二套）。
enum ChatEdgeBackKit {
    /// 起手区宽度：手指必须落在屏幕左缘这条带内（pt）
    /// v4.0.125：**默认不再使用**（见 `allowsAnywhereStart`）；保留给「只认左缘」的旧口径与单测。
    static let edgeWidth: CGFloat = 24
    /// v4.0.125（用户 2026-10-19：「聊天页增加任意界面右滑返回聊天首页」）：
    /// 起手不再限左缘 —— 对话页任意位置右滑都能跟手返回首页。
    /// 安全性靠另外两道门：① `isHorizontal`（横向位移 ≥ 8pt 且 ≥ |dy| × 1.8）挡纵向滚动/斜划；
    /// ② 跟手期间页内滚动被 `scrollDisabled` 关掉（见 ChatView）。别为了「更灵敏」把这两道门也拆了。
    static let allowsAnywhereStart = true
    /// 跟手起手位移：横向右移 ≥ 它才认这条手势（pt）
    /// 🚨 这枚是**跟手**口径。旧值 70（`minTranslation`）是「抬手才发现自己该跳转」用的：
    ///    70pt 才起步 = 手指已滑出去一大截页面还没动，用户口径的「跟手」当场破功。
    static let followStart: CGFloat = 8
    /// 方向纯度：水平位移必须 ≥ 竖直位移 × 它（挡纵向滚动与斜划）
    static let horizontalBias: CGFloat = 1.8
    /// 松手判完成：位移 ≥ 屏宽 × 它 → 返回；否则回弹（用户口径「松手过半即完成」）
    static let completeRatio: CGFloat = 0.5

    /// v4.0.125：起手门（**视图唯一该调的入口**）——默认任意位置都算（见 `allowsAnywhereStart`）。
    static func isBackStart(x: CGFloat) -> Bool { allowsAnywhereStart || isEdgeStart(x: x) }

    /// 起手是否落在左缘。
    /// 参数取手势的**全局**起手 x（`DragGesture.Value.startLocation.x`，`.global` 即 window 坐标）。
    static func isEdgeStart(x: CGFloat) -> Bool { x <= edgeWidth }

    /// 这一帧的位移够不够「横」——够横才认这条手势（此后由调用方记住，不再逐帧过门）。
    static func isHorizontal(dx: CGFloat, dy: CGFloat) -> Bool {
        dx >= followStart && dx >= abs(dy) * horizontalBias
    }

    /// 跟手位移：负位移/回拉归 0（页面不许被拖到左边去），且不越过屏宽（拖不出屏外）。
    static func followOffset(dx: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(max(0, dx), width)
    }

    /// 松手：算不算「完成返回」。
    /// - Parameters:
    ///   - dx: 松手时的水平位移（pt）
    ///   - projectedEnd: 甩动预测终点（`DragGesture.Value.predictedEndTranslation.width`）
    ///     —— 位移没过半但甩得快也算完成（微信同款：轻甩就翻页）。它不是 pt/s，是系统按当前
    ///     速度**外推**的落点，所以判据与位移共用同一条线（屏宽 × completeRatio）即可。
    ///   - width: 屏宽（pt）
    static func shouldComplete(dx: CGFloat, projectedEnd: CGFloat, width: CGFloat) -> Bool {
        guard width > 0, dx > 0 else { return false }
        let line = width * completeRatio
        return dx >= line || projectedEnd >= line
    }
}
