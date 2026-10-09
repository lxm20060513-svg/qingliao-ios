import SwiftUI

// MARK: - v4.0.84 生活页入场错峰（四拍之拍 1，本页唯一 heavy beat）
//
// 动机（用户 2026-10-09 看对比稿拍板「B 加动效一起做一版」）：
//   生活页此前 Motion 令牌 0 处、withAnimation 0 处 —— 切进来六张板块卡是一起硬切出现，
//   读起来像静态表单，与聊天链（withAnimation 上百处）断崖。
//
// 为什么写成 ViewModifier，而不是在 LifeView 里逐行 .onAppear 改 @State：
//   · LifeView.body 已经是「VStack + ScrollView + LazyVStack + switch 7 个板块 + 5 层 .overlay」
//     的重型 body，再往里塞状态与动画表达式有 type-check 超时风险（本仓踩过，而且只有 CI 报）。
//   · 逐行各写一份 @State 迟早漂移（同 BadgeShell「尺寸与圆角只此一处」的理由）。
//
// 🚨 「入场态」必须由**不会被回收的宿主**持有（LifeView 的 @State），不能放在本 modifier 内部：
//   本页是 LazyVStack，行滚出视口会被回收，重建时 modifier 内的 @State 重置回初值 →
//   onAppear 再翻一次 → **每次滚回来都重放一遍入场淡入 + 上浮**（无报错，只有手感）。
//   2026-10-09 发版前只读审查实测抓到的就是这条。改成 `ready: Bool` 入参后，
//   后建出来的行拿到 ready = true，直接落终态 —— 顺带满足「只有首屏那一批错峰入场」。
//
// 减动效（accessibilityReduceMotion）= composed still，不是「关掉」：
//   动效走 .animation(_:value:) 而不是 withAnimation —— reduceMotion 时传 nil，状态变化瞬间到位，
//   页面停在**完全相同的终态**（六张卡都在、都可读、都可点），只是没有过程。
//   finesse-ui motion §0 第③条要求的 terminal state 就是这条。
//
// rise / step / from 刻意留在本文件、不进 Theme/Motion.swift：它们是「入场编排」参数，
// 不是全站通用节奏；通用节奏仍以 Motion.swift 六档为唯一真源。

/// 入场错峰：初态（下移 rise pt + 不透明度 from）→ 终态（原位 + 全不透明）。
/// 延迟按 index 递增，读作「这一页是一张张拼起来的」；index 超过 capIndex 后不再累加延迟，
/// 免得下面几屏的卡滚到眼前还要等半秒才现身。
struct StaggerAppear: ViewModifier {
    /// 本卡在页面里的序号（0 = 第一张）
    let index: Int
    /// 入场开关：由宿主一次性置真（见头注 —— 放这里而不是本 modifier 的 @State，是为了防行回收后重放）
    let ready: Bool
    /// 上浮距离（pt）
    var rise: CGFloat = 14
    /// 每张之间的错峰（秒）
    var step: Double = 0.045
    /// 初态不透明度。
    ///
    /// ⚠️ 0.70 而不是 0.55，是**跨文件叠加**算出来的（2026-10-09 落地时发现）：
    ///   生活页整页被 DockTabView 的切页入场包着 —— 那层是 `.opacity(phase)`，phase 从 **0.6** 起手、
    ///   走 `Motion.flow` 0.28s（见 DockTabView.swift `TabTransitionModifier`）。
    ///   两层不透明度是**相乘**的：若这里取 0.55，进场首帧合成 = 0.55 × 0.6 = 0.33 ——
    ///   比切页自身的 0.6 还暗一大截，读起来就是「内容先整个暗一下再出来」，
    ///   正是用户报过的「dock 栏 tap 切换太闪了」（v4.0.72 回退⑯ 那一族）。
    ///   取 0.70 → 合成 0.42，与切页自身的 0.6 同一量级，只补一点错峰、不另起一条暗曲线。
    var from: Double = 0.70
    /// 延迟累加上限（序号超过它的卡共用同一延迟）
    var capIndex: Int = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 本张的入场延迟
    private var delay: Double { step * Double(min(index, capIndex)) }

    func body(content: Content) -> some View {
        // 显式声明成 Animation?：三元里 nil 与 Animation 混用，交给类型推断在 CI 上偶发歧义
        //（同写法仓内先例：LoginView.swift `frozen ? nil : Motion.emerge.delay(...)`）
        let anim: Animation? = reduceMotion ? nil : Motion.emerge.delay(delay)
        return content
            .opacity(ready ? 1 : from)
            .offset(y: ready ? 0 : rise)
            .animation(anim, value: ready)
    }
}

extension View {
    /// 生活页板块入场错峰（见 StaggerAppear 头注）。
    /// `ready` 必须由不会被回收的宿主持有（LifeView 的 @State + 一次 onAppear）。
    func staggerAppear(_ index: Int, ready: Bool) -> some View {
        modifier(StaggerAppear(index: index, ready: ready))
    }
}
