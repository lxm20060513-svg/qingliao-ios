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

    /// 整页横移（会话首页 ↔ 对话页双态切换，v4.0.114）。
    ///
    /// 用户 2026-10-15「聊天详情手势滑动返回聊天首页的过渡太生硬」：这两态原先用 `tap`
    /// （`.snappy(0.12)` —— 那枚令牌自己的注释就是「按压/开关/小状态：**几乎瞬时**」）。
    /// 小控件要的是"立刻响应"，但**整页位移**必须让眼睛看得见位移过程，0.12 读作「啪一下闪过去」。
    /// 故单开一枚：时长够看清横移、仍用 snappy 保持"跟手不飘"。
    /// ⚠️ 只给整页横移用，别挪去驱动小控件（那边的 0.12 是刻意快）。
    static var page: Animation { .snappy(duration: 0.34) }

    /// 卡片 / 面板进入、列表插入
    static var settle: Animation { .snappy(duration: 0.30) }

    /// 生活页卡片「点一下弹开」的展开 / 收起曲线（v4.0.100 用户 2026-10-12「点击弹开动画也再丝滑一点」）。
    ///
    /// 与通用 `settle` 的区别 = **更长 + 更无回弹**：卡片展开是「一整块内容从卡下长出来」，
    /// settle（.snappy 0.30）那点加速度读作「顶一下」，拉到 0.38 的 .smooth 读作「丝滑地滑出来」。
    /// ⚠️ **只给生活页四张卡（待办 / 习惯 / 记录 / 备忘）的展开 + 两处逐条错峰用**。
    /// 别图省事把 `settle` 全局改慢 —— 它同时驱动聊天流式气泡生长（ChatMessageBubble 的
    /// `.animation(Motion.settle, value: stream.displayContent)`），慢下来会让流式文字读作卡顿。
    /// 两处语义本就不同（卡片弹开 vs 内容生长），所以是两个令牌，不是一处。
    static var cardExpand: Animation { .smooth(duration: 0.38) }

    /// 大块浮现（弹窗、浮层、空态），带轻微回弹
    static var emerge: Animation { .bouncy(duration: 0.42, extraBounce: 0.08) }

    /// 持续型（呼吸 / 流光收尾），不加回弹
    static var flow: Animation { .smooth(duration: 0.28) }

    /// 新消息气泡上滑入位（y:8→0 + opacity 0→1，v3.9.31）
    ///
    /// v4.0.39：dampingFraction 0.8 → 0.72（**轻微过冲**）。这是本轮唯一一次全局改动 enter 的理由：
    /// 插入动画由 ChatStore.append / upsertAssistant 的 withAnimation 统一驱动，用户发送气泡与
    /// AI 回答落库共用同一条事务，改这一处就同时拿到「发送弹出」与「流式收尾落位回弹」两种回弹，
    /// 不必在视图层各挂一套 keyframe（keyframeAnimator 会在降频/后台时凝帧，本仓三点动画已因此翻车）。
    /// 过冲幅度刻意压得很小（约 3~4%），只到「弹了一下」的观感，不会像弹窗 emerge 那样夸张。
    static var enter: Animation { .spring(response: 0.20, dampingFraction: 0.72) }

    /// v4.0.76：锚定菜单入场（AnchorMenuOverlay 专用，审查意见：入场动画走 Motion 真源不裸写 spring）
    static var anchorMenu: Animation { .spring(response: 0.38, dampingFraction: 0.78) }

    // 🚨 v4.0.106：v4.0.105 给长按菜单加的那组「微缩 → 抬起」令牌**已整体移除**
    //（`menuLift` / `pressDown` / `pressScale` / `liftScale` / `liftRise`）。
    // 用户装包真机拍板：「这不是我想要的效果，还是把背景模糊化，只保留胶囊菜单」⇒
    // 长按后内容原位不动，锚定菜单只保留 `anchorMenu` 入场 + 逐颗错峰（菜单内部自带的 spring）。
    // 别再为「抬起预览」重新引入这些令牌。

    /// v4.0.97：dock 切页**圆形扩散**入场（用户 2026-10-11：「dock 栏 tap 页切换采用圆形扩散转场特效：
    /// 点击底部 tap，新页面就从手指按下的位置向外扩散直到铺满整个屏幕」）—— 取代 v4.0.85 的
    /// 「横向滑入 + 渐显」（那套历轮为躲「闪 / 露白」一路压小到 ≈硬切；用户既点名要扩散，就整条换掉）。
    /// 曲线取 .smooth(0.75)：0.42（v4.0.97 初版）→ 0.60（v4.0.98 用户「放慢一点」）
    /// → **0.75（用户 2026-10-12「速度再放慢一点」）**。扩散要有「扫过去」的行程感 ——
    /// 过短 = 硬切，过长 = 拖沓；再往上加（≥0.9）就该先问用户，别一路摊成慢动作。
    /// ⚠️ 曲线与半径的字面量同时钉在 check_swift.sh 的「回退⑯」组与 ql_themegrad ⑧c，改这里必须同步改那两处。
    static var pageReveal: Animation { .smooth(duration: 0.75) }

    /// 扩散圆的最大半径（pt）：必须 ≥「屏幕最远角到圆心」的距离（15 Pro Max 底部槽位 ≈ 874pt），
    /// 取 1200 兜住全部机型与横屏。**两处 modifier 共用同一个常量**，别各写一个字面量。
    static let pageRevealMaxRadius: CGFloat = 1200

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
