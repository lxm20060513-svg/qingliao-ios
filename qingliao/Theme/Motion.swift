// MARK: - v3.4.29 全站动效令牌（统一节奏，替代散落魔法数）
//
// 背景：改造前全工程动画时长散落 10 档（0.12/0.15/0.2/0.25/0.3/0.35/0.45/0.6/0.85/1.0），
// spring 还有两种写法混用（duration+bounce 与 response+dampingFraction）——
// 同一次交互里两处动画节奏不一致，观感就"黏"。
//
// 语义分层（越往下越重，不要跨层乱用）：
//   tap    → 按压 / 开关 / 小状态，几乎瞬时，只用来"去硬边"
//   snap   → tab 切换、气泡展开、行状态变化
//   settle → 卡片/面板进入、列表插入
//   emerge → 大块浮现（弹窗、浮层、空态），带轻微回弹
//   flow   → 持续型（呼吸/流光收尾），不加回弹
//
// 注意：键盘联动曲线（跟 kb.animationDuration）、启动动画（SplashView 0.85s）、
//       repeatForever 循环动效一律保持原值，不套令牌。
//
// 用 static var（计算属性）而非 static let：Swift 6 严格并发下 Animation 全局常量
// 易触发隔离告警；动画值每次构造开销可忽略。

import SwiftUI

enum Motion {
    /// 按压 / 开关 / 小状态：几乎瞬时
    static var tap: Animation { .snappy(duration: 0.12) }

    /// tab 切换、气泡展开、行状态变化
    static var snap: Animation { .snappy(duration: 0.20) }

    /// 卡片 / 面板进入、列表插入
    static var settle: Animation { .snappy(duration: 0.30) }

    /// 大块浮现（弹窗、浮层、空态），带轻微回弹
    static var emerge: Animation { .bouncy(duration: 0.42, extraBounce: 0.08) }

    /// 持续型（呼吸 / 流光收尾），不加回弹
    static var flow: Animation { .smooth(duration: 0.28) }

    /// 会话卡 → 聊天页的整页展开（v4.0.70）
    ///
    /// 为什么换掉原来的 `settle`（snappy 0.30）：那是「卡片/面板进入」的节奏，收得又急又平，
    /// 整页从会话卡大小一帧绷到全屏，看不出「展开」的过程（用户 2026-10-07 真机：
    /// 「聊天页展开动画不好看，换一个灵动有动画感的」）。
    /// 这里要的是**看得见落点**的展开：response 拉到 0.46s、dampingFraction 0.80（留约 2~3% 过冲），
    /// 页面像弹开一样铺满屏幕，落定时轻轻顿一下 —— 过冲刻意压小，弹的是「展开的收尾」而不是整屏晃。
    /// 配合 `ChatZoomEntryModifier` 里那段 opacity 0.12 → 1：先是一层淡淡的影子，再落到实，
    /// 这样就不会让人盯着被压扁的文字看完整段动画（那正是「生硬」的主要来源）。
    static var unfold: Animation { .spring(response: 0.46, dampingFraction: 0.80) }

    /// dock 切页（v4.0.70）
    ///
    /// 原用 `settle`（snappy 0.30，纯收束、无回弹）：切页只有「缩放 4% + 下移 10pt」一路收进去，
    /// 四页共用同一条曲线时观感偏硬（用户 2026-10-07：dock 优化「切页动效分层」）。
    /// 这里换 spring(response 0.32 / dampingFraction 0.86)：比 unfold 快一档（切页要跟手，
    /// 不能像整页展开那样 0.46s），留约 1~2% 过冲让落点「顿」一下；配合 TabTransitionModifier
    /// 里的 opacity 0.35 → 1 淡入，页面就不是「整块硬切上来」而是「浮上来的」。
    static var tabSwitch: Animation { .spring(response: 0.32, dampingFraction: 0.86) }

    /// 新消息气泡上滑入位（y:8→0 + opacity 0→1，v3.9.31）
    ///
    /// v4.0.39：dampingFraction 0.8 → 0.72（**轻微过冲**）。这是本轮唯一一次全局改动 enter 的理由：
    /// 插入动画由 ChatStore.append / upsertAssistant 的 withAnimation 统一驱动，用户发送气泡与
    /// AI 回答落库共用同一条事务，改这一处就同时拿到「发送弹出」与「流式收尾落位回弹」两种回弹，
    /// 不必在视图层各挂一套 keyframe（keyframeAnimator 会在降频/后台时凝帧，本仓三点动画已因此翻车）。
    /// 过冲幅度刻意压得很小（约 3~4%），只到「弹了一下」的观感，不会像弹窗 emerge 那样夸张。
    static var enter: Animation { .spring(response: 0.20, dampingFraction: 0.72) }

    /// 用户发送气泡的位移量（pt，配合上面的过冲读作「弹上来」）
    static let bubbleRise: CGFloat = 12

    /// 流式气泡首帧浮现（淡入 + 上浮）。比 enter 更快更钝：流式首帧没有「弹」的语义，只是「长出来」。
    static var streamBorn: Animation { .easeOut(duration: 0.22) }

    /// 流式期间那道下扫光带的单程时长（秒，往返 = 2×）
    static let streamSweepDuration: Double = 1.2

    /// 流式光带的最大不透明度。**必须极淡**（3.5%）：这条光带靠 repeatForever 驱动，
    /// 而 repeatForever 属官方定义的 pausable schedule（子树无 Core Animation 活动时会被降频/暂停，
    /// 本仓 v4.0.19 三点动画「动一会儿就停」同源）。压到肉眼近乎不可见，冻结时无感知，
    /// 跑起来时也只当一层极淡的空气感，绝不抢正文可读性。
    static let streamSweepOpacity: Double = 0.035
}
