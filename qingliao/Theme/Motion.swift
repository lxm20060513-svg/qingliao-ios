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
    // MARK: - 第 12 项：特效总档（关 / 标准 / 丰富，见 Core/EffectsLevel.swift）

    /// 总档收敛点（**唯一**）：`关` 档把任何曲线退化成零时长 —— 内容照常出现，只是不再位移/缩放/淡入。
    ///
    /// 为什么收在令牌层而不在调用点判：全仓令牌调用点 200+ 处，逐点判必然漏；令牌是唯一入口，
    /// 一处生效即全站生效。语义等价于既有的「减弱动态效果」替代路径（那条仍由各视图的
    /// `accessibilityReduceMotion` 单独承担，两者互不替代）。
    private static func tuned(_ animation: Animation) -> Animation {
        // 🚨 审查 P0（本轮）：这里原先写成了恒等 `animation` —— 「关」档整档空转，
        // 而 check_swift 的断言恰好被上面注释里的同一串命中 → 预检全绿把空转放过去了。
        // 修法与护栏见 check_swift.sh 第 105 组（改成抽函数体断言 + 令牌漏包计数）。
        EffectsLevel.current.isOff ? .linear(duration: 0.001) : animation
    }

    /// 按压 / 开关 / 小状态：几乎瞬时
    static var tap: Animation { tuned(.snappy(duration: 0.12)) }

    /// tab 切换、气泡展开、行状态变化
    // 🚨 审查 P1：snap 原先是唯一没套 `tuned` 的令牌，而它有 70+ 调用点（tab 切换 / 码档切换 /
    // 列表行增删）→ 「关」档下这些照旧播动效，档位的承诺就不成立。补包后全仓 14 枚令牌一致。
    static var snap: Animation { tuned(.snappy(duration: 0.20)) }

    /// 整页横移（会话首页 ↔ 对话页双态切换，v4.0.114）。
    ///
    /// 用户 2026-10-15「聊天详情手势滑动返回聊天首页的过渡太生硬」：这两态原先用 `tap`
    /// （`.snappy(0.12)` —— 那枚令牌自己的注释就是「按压/开关/小状态：**几乎瞬时**」）。
    /// 小控件要的是"立刻响应"，但**整页位移**必须让眼睛看得见位移过程，0.12 读作「啪一下闪过去」。
    /// 故单开一枚：时长够看清横移、仍用 snappy 保持"跟手不飘"。
    /// ⚠️ 只给整页横移用，别挪去驱动小控件（那边的 0.12 是刻意快）。
    /// v4.0.115（用户「还是动效生硬」）：`.snappy` → **`.smooth`**。
    /// snappy 是「快起 + 收尾一点点回弹」的弹簧，小控件上读作"跟手"，但**整屏位移**上
    /// 那点回弹读作到位时「顿一下 / 顶一下」。.smooth 无回弹、首尾对称，读作「滑过去」。
    /// ⚠️ 时长 0.34 不动（v4.0.114 定的：短于 0.3 读作闪、长于 0.4 读作拖沓）。
    static var page: Animation { tuned(.smooth(duration: 0.34)) }

    /// 卡片 / 面板进入、列表插入
    static var settle: Animation { tuned(.snappy(duration: 0.30)) }

    /// 生活页卡片「点一下弹开」的展开 / 收起曲线（v4.0.100 用户 2026-10-12「点击弹开动画也再丝滑一点」）。
    ///
    /// 与通用 `settle` 的区别 = **更长 + 更无回弹**：卡片展开是「一整块内容从卡下长出来」，
    /// settle（.snappy 0.30）那点加速度读作「顶一下」，拉到 0.38 的 .smooth 读作「丝滑地滑出来」。
    /// ⚠️ **只给生活页四张卡（待办 / 习惯 / 记录 / 备忘）的展开 + 两处逐条错峰用**。
    /// 别图省事把 `settle` 全局改慢 —— 它同时驱动聊天流式气泡生长（ChatMessageBubble 的
    /// `.animation(Motion.settle, value: stream.displayContent)`），慢下来会让流式文字读作卡顿。
    /// 两处语义本就不同（卡片弹开 vs 内容生长），所以是两个令牌，不是一处。
    static var cardExpand: Animation { tuned(.smooth(duration: 0.38)) }

    /// 大块浮现（弹窗、浮层、空态），带轻微回弹
    static var emerge: Animation { tuned(.bouncy(duration: 0.42, extraBounce: 0.08)) }

    /// 持续型（呼吸 / 流光收尾），不加回弹
    static var flow: Animation { tuned(.smooth(duration: 0.28)) }

    /// 新消息气泡上滑入位（y:8→0 + opacity 0→1，v3.9.31）
    ///
    /// v4.0.39：dampingFraction 0.8 → 0.72（**轻微过冲**）。这是本轮唯一一次全局改动 enter 的理由：
    /// 插入动画由 ChatStore.append / upsertAssistant 的 withAnimation 统一驱动，用户发送气泡与
    /// AI 回答落库共用同一条事务，改这一处就同时拿到「发送弹出」与「流式收尾落位回弹」两种回弹，
    /// 不必在视图层各挂一套 keyframe（keyframeAnimator 会在降频/后台时凝帧，本仓三点动画已因此翻车）。
    /// 过冲幅度刻意压得很小（约 3~4%），只到「弹了一下」的观感，不会像弹窗 emerge 那样夸张。
    static var enter: Animation { tuned(.spring(response: 0.20, dampingFraction: 0.72)) }

    /// v4.0.76：锚定菜单入场（AnchorMenuOverlay 专用，审查意见：入场动画走 Motion 真源不裸写 spring）
    static var anchorMenu: Animation { tuned(.spring(response: 0.38, dampingFraction: 0.78)) }

    // 🚨 v4.0.106：v4.0.105 给长按菜单加的那组「微缩 → 抬起」令牌**已整体移除**
    //（`menuLift` / `pressDown` / `pressScale` / `liftScale` / `liftRise`）。
    // 用户装包真机拍板：「这不是我想要的效果，还是把背景模糊化，只保留胶囊菜单」⇒
    // 长按后内容原位不动，锚定菜单只保留 `anchorMenu` 入场 + 逐颗错峰（菜单内部自带的 spring）。
    // 别再为「抬起预览」重新引入这些令牌。

    /// v4.0.120（用户 2026-10-17「底栏换页改成内容层按槽位方向定向滑入，圆扩散只留启动页」）：
    /// 底栏换页入场 = **内容层按槽位方向定向滑入**（新槽在右 → 从右进，起点位移 `pageEnterShift`）。
    /// 方向按**新旧槽位序号差**判（不是写死的左右）；离场那页一动不演（不做反向播）。
    /// ⚠️ 只动内容层位移，**不碰整页透明度** —— 低起点整页淡入是治了几轮的老病（见 check_swift「回退⑯a~⑯j」组）。
    /// 🚨 曲线与位移的字面量同时钉在 check_swift.sh「回退⑯a」组、ql_themegrad ⑧c 与 ql_docklayout 表，改这里必须同步那几处。
    static var pageEnterSlide: Animation {
        // 第 12 项：`丰富` 档把这条加长（0.32 → 0.46）——「丰富只加长切页」，曲线种类与位移量都不动。
        // ⚠️ 0.32 仍是标准档字面值：check_swift「回退⑯a」组 / ql_themegrad ⑧c / ql_docklayout 表
        //    钉的就是它，别把它删成只有 0.46。
        tuned(EffectsLevel.current.isRich ? .smooth(duration: 0.46) : .smooth(duration: 0.32))
    }

    /// **左缘跟手返回的收尾**专用（v4.0.149 立项）。管两处，必须同一枚：
    /// 松手收敛（位移走完剩下的路）与未过阈值回弹（归位）。
    /// 手感（不变）：`.spring(bounce: 0)` 的**软着陆** —— 落地段渐渐减速，不是 .smooth 那种到点即停；
    /// v4.0.149 用户明确反馈过「.smooth 0.34 读作嗖一下被推走 + 硬停 = 生硬」，
    /// 所以**不许为了调速度把它退回 `.smooth`**（要改只能改 duration）。
    /// 速度（v4.0.151，用户 2026-10-23「改成跟滑动/tap 切换一样的速度就行，现在的有点慢了」）：
    /// duration 0.52 → **0.32** = 底栏切页 `pageEnterSlide` 的 0.32（滑页 / 点 tab 切档同速）。
    /// **bounce 必须 0**：回弹那条（位移 → 0）若有回弹会越过原位再荡回来，观感是「页面抖一下」。
    /// ⚠️ 时长/等待都从下面两个常量派生（v4.0.148 审查：原先 0.62 在两处 sleep 里各写一份字面量，
    /// 调手感时必漏一处 → 切态切在半路，且预检与 CI 都查不出来）。
    /// ⚠️ 别改回 `Motion.page`，也别去动 `page` 本身（进对话页 / 底栏两态都在用，顺手改 = 误伤在用动效）。
    /// 页头返回按钮（`backToSessionHome`）仍用 `Motion.page`：那是点按的离散动作、没有手指可跟，口径不同。
    static let sessionBackSettleDuration: Double = 0.32

    /// 切态等待 = 动画时长 + 裕量。「关」档 `tuned` 已退化成 0.001s 线性，
    /// 等待必须一起收短，否则整页瞬移完还要白等 0.6s 才翻状态。
    static var sessionBackSettleWait: Double {
        EffectsLevel.current.isOff ? 0.05 : sessionBackSettleDuration + 0.10
    }

    static var sessionBackSettle: Animation { tuned(.spring(duration: sessionBackSettleDuration, bounce: 0)) }

    /// 🚨 v4.0.117（用户 2026-10-15 真机反馈「滑动返回聊天主页的扩散**就是太快**」）：**返回那条链单独放慢**。
    /// 口径（v4.0.120 起）：圆扩散只留两处 —— **滑动返回**（对话页 → 会话首页，`SessionHomeRevealModifier`）
    /// 与**启动页**（`launchReveal`）；底栏切页已改定向滑入（`pageEnterSlide`），不再走扩散。
    /// 为什么必须分家：返回的圆心在屏幕**左侧中部**（起手被左缘 24pt 钉住），到最远角的行程比切页长，
    /// 同一条 0.75 读作「刷一下扫完」= 用户口径的「太快」；而切页的 0.75 是他自己拍板的，顺手改 = 误伤。
    /// ⚠️ 字面量钉在 check_swift.sh「回退⑯」组（⑯k/⑯l）与 ql_docklayout 表，改这里同步改那两处。
    static var sessionBackReveal: Animation { tuned(.smooth(duration: 1.10)) }

    /// 扩散圆的最大半径（pt）：必须 ≥「屏幕最远角到圆心」的距离（15 Pro Max 底部槽位 ≈ 874pt），
    /// 取 1200 兜住全部机型与横屏。**滑动返回 + 启动页共用同一个常量**，别各写一个字面量。
    static let pageRevealMaxRadius: CGFloat = 1200

    /// v4.0.120：底栏换页定向滑入的起点位移（pt）= 28 —— 看得出方向，又不至于读作「整页搬家」。
    /// 别加大到 ≥40（页边露底太多、像页面没铺满）；也别缩到 ≤16（看不出方向 = 退回硬切）。
    static let pageEnterShift: CGFloat = 28

    /// 第 11 项整改（用户 2026-10-18「自绘浮层全部对齐备忘录那套」）：**面板入场几何的两枚唯一真源**。
    /// 面板从 0.94 倍 + 下方 24pt 浮起（`Motion.emerge` 驱动；关闭走 `Motion.settle` 反向收敛）。
    /// 定义落在这里、别在各浮层各写一份字面量：`MemoGlassOverlay`（参照物）、`OrbIdentifyOverlay`
    /// 等都引用本常量，改档只改这一处。
    /// ⚠️ **球心锚定型浮层豁免位移**：`OrbQuickMenu` 的重心是智慧球/宠物，胶囊自锚点弹射，
    /// 强套 24pt 上浮会脱开锚点（观感「胶囊和球分家」）——该层只保留缩放语义，位移豁免；
    /// 豁免点在 check_swift.sh「第 105 组」有断言钉着。
    static let panelEnterScale: CGFloat = 0.94
    static let panelEnterRise: CGFloat = 24

    /// 第 12 项丰富档：**符号替换的时长档**（用户口径「丰富只加长切页和符号替换」）。
    /// 丰富档 → `.speed(0.6)`：替换过程拉长，读得出「这颗图标换成了另一颗」而不是「闪了一下」。
    /// 标准 / 关档 → `.speed(1.0)` = 系统默认速率，与改造前完全一致（零观感变化）。
    /// ⚠️ 这里**刻意不用 `SymbolEffectOptions.default`**：那枚成员在部分 SDK 里不公开，
    ///    本机无 Xcode、编译只在 CI Archive 露头（swift-preflight-blindspots）—— 用公开的
    ///    `.speed(1.0)` 表达「原速」，语义等价且 API 面确定。
    /// ⚠️ 只调节**既有效果的节奏参数**，不新造第二套时钟（EffectsLevel 的口径同此）。
    static var symbolReplaceOptions: SymbolEffectOptions {
        .speed(EffectsLevel.current.isRich ? 0.6 : 1.0)
    }

    /// v4.0.117：启动页圆形遮罩的扩散曲线（`.easeIn` = 用户要的「先慢后快」）。
    /// ⚠️ **别拿 `sessionBackReveal` 顶替**：那枚是 `.smooth`（首尾对称）语义的匀速扫过；
    /// 启动页这一拍用户明说「先慢后快」，两枚令牌各管一段，不是一处。
    /// 时长 0.7 与 `SplashView.revealDuration` 必须同值（check_swift.sh 同钉两处）。
    static var launchReveal: Animation { tuned(.easeIn(duration: 0.7)) }

    /// v4.0.117：首页各块次第上浮（`.smooth`，无回弹）。每块错峰 60ms、上浮 18pt 见
    /// `SplashView.riseStagger` / `riseOffset`。⚠️ 这枚只管**块内**的位移曲线，
    /// 整页级的入场仍是圆形扩散（回退⑯ 的禁令不变：整页缩放/上浮/低起点淡入都不许回来）。
    static var launchRise: Animation { tuned(.smooth(duration: 0.40)) }

    /// 用户发送气泡的位移量（pt，配合上面的过冲读作「弹上来」）
    static let bubbleRise: CGFloat = 12

    /// 流式气泡首帧浮现（淡入 + 上浮）。比 enter 更快更钝：流式首帧没有「弹」的语义，只是「长出来」。
    static var streamBorn: Animation { tuned(.easeOut(duration: 0.22)) }

    /// 流式期间那道下扫光带的单程时长（秒，往返 = 2×）
    static let streamSweepDuration: Double = 1.2

    /// 流式光带的最大不透明度。**必须极淡**（3.5%）：这条光带靠 repeatForever 驱动，
    /// 而 repeatForever 属官方定义的 pausable schedule（子树无 Core Animation 活动时会被降频/暂停，
    /// 本仓 v4.0.19 三点动画「动一会儿就停」同源）。压到肉眼近乎不可见，冻结时无感知，
    /// 跑起来时也只当一层极淡的空气感，绝不抢正文可读性。
    static let streamSweepOpacity: Double = 0.035
}
