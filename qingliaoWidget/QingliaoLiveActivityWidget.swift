import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// 灵动岛 / 锁屏实时活动：轻聊球 + 阶段 + 计时 +（可选）停止生成。
///
/// 四条设计约束（都是硬约束，别绕）：
/// 1. ~~计时用 `Text(_:style: .timer)` 交给系统自走~~ **v3.9.9 已移除计时文字**（用户要求），
///    右侧改为阶段指示（v3.9.10 起是渐变进度环 phaseRing）。原注释保留一句为什么当初用它——侧载免费签名没有推送更新，App 被挂起后
///    文本不会再刷新，只有系统计时钟照走，所以「已用时」必须靠它。
/// 2. **动效的唯一可靠来源是「数据更新」**（Apple《Animating data updates in widgets and Live
///    Activities》原文：动画随数据更新发生，**最长 2 秒**；常亮屏下系统不播动画；iOS 16 及更早会
///    直接忽略动画修饰符），**实时活动没有连续自走的帧源**（`TimelineView(.animation)` 在这里不成立）。
///    v3.9.13 据此重做（用户报「动几下就不动了」）：球体本体仍是 `Canvas` 静态帧（已删掉徒劳的
///    `TimelineView`），而脉冲环 / 旋转弧 / 环上跑动短弧全部改由 `ContentState.spin` 驱动 +
///    `.animation(_, value: spin)` 过渡——过渡时长**由 `state.beatSeconds` 现算**
///    （`OrbBeat.duration`，= `min(cap, max(floor, 拍 − leadIn))`），与 App 侧真实拍间隔对齐，
///    两拍之间只留不到 0.1s 的缝。
///    **v3.9.37 修「动画还是会断」**：旧实现把过渡写死 1.1s（只匹配 1.2s 快档），
///    而长回答（>36s）后 App 侧降频到 2.5s 一拍 → 每拍尾部有约 1.4s 完全静止（顿挫）。
///    根因是「节奏只在 App 侧、挂件不知道」→ 现在节奏随数据下发，且慢档收到 2.0s
///    （Apple 侧过渡 >2s 不保证播完，取 1.95s 为上限），两侧永远同一口径。
/// 3. **不画假的总进度**：流式回答没有真实总长，所以环显示的是 `progress` = **本轮推进度**
///    （思考 0.18 → 开始生成 0.35 → 逐步逼近 0.86，真结束才 1.0），语义是「在推进」而不是
///    「已完成 72% 的答案」。字段名与注释都按这个语义写，别把它当成真实百分比展示给用户。
/// 4. 状态行只说确证的事实（阶段 + 模型名），不虚构「联网搜索 / 写代码」这类没有数据源的措辞。
struct QingliaoLiveActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QingliaoActivityAttributes.self) { context in
            // 锁屏 / 不支持灵动岛设备的横幅
            self.lockScreenBanner(state: context.state)
                // v3.9.61：0.35 → 0.18。tint 是「铺满整个横幅卡片的纯色蒙版」（官方只有这一个接口），
                // 调低才能透出锁屏壁纸——玻璃感的前提是底下有真实内容可折射。
                .activityBackgroundTint(Color.black.opacity(0.18))
                .activitySystemActionForegroundColor(.white)
                // v3.9.7：点横幅回聊天页（主 App 已注册 qingliao:// scheme）
                .widgetURL(QingliaoLiveActivityWidget.chatURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // 尺寸沿革：34 → 36（v3.9.11「球大一点」）。**不要再往上加**：展开态顶行就是传感器区，
                    // 高度约 36.67pt，38 会顶到灵动岛圆角遮罩被切上下边（本机无 iOS SDK，这类几何只能真机定论）。
                    OrbView(size: 36, phase: context.state.phase, spin: context.state.spin,
                            beat: context.state.beatSeconds)
                        .padding(.leading, 1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // 尺寸沿革：36（与球等大，压过球）→ 28（v3.9.12，球的 78%）→ **24**（v3.9.13，
                    // 真机反馈环碰到中段摄像头区，与紧凑态同步收一档，维持「环≈球的 2/3」的主次关系）。
                    self.phaseRing(state: context.state, size: 24)
                        .padding(.trailing, 1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    self.expandedBottom(state: context.state)
                }
            } compactLeading: {
                // v3.9.12：25 → 27（真机反馈「球反而小了」——球再加大一档，环同时收小，主次才分明）
                OrbView(size: 27, phase: context.state.phase, spin: context.state.spin,
                        beat: context.state.beatSeconds)
            } compactTrailing: {
                self.compactTrailing(state: context.state)
            } minimal: {
                OrbView(size: 24, phase: context.state.phase, spin: context.state.spin,
                        beat: context.state.beatSeconds)
            }
            .keylineTint(OrbPalette.accent)
            // v3.9.7：点岛回聊天页
            .widgetURL(QingliaoLiveActivityWidget.chatURL)
        }
    }

    /// 「回到会话」深链（URL 传参不需要 App Groups——免费签名拿不到那个能力）
    static let chatURL = URL(string: "qingliao://chat")

    // MARK: - 各形态内容

    /// 紧凑态右侧：渐变进度环（v3.9.9 起不再显示计时数字；v3.9.10 起不用系统气泡图标）
    /// 尺寸沿革：13（v3.9.10 前，偏小）→ 25（与球等大，用户看过觉得偏大）→ 20（v3.9.12，球的 7 成）
    /// → **16**（v3.9.13，真机反馈「环再小一点，左边碰到摄像头了」）。
    /// 为什么是 16 而不是随手收一点：紧凑态布局是「球(leading) | 传感器/摄像头(中段) | 环(trailing)」，
    /// 环越大，它的**左边缘**越往中段顶。环的视觉宽度不止 size——还有描边（size*0.13）与柔光外扩
    /// （size*0.10，v3.9.13 从 0.18 收窄），三者相加才是肉眼看到的边界。
    @ViewBuilder
    private func compactTrailing(state: QingliaoActivityAttributes.ContentState) -> some View {
        self.phaseRing(state: state, size: 16)
    }

    /// 展开态底部：会话标题 + 状态行（+ 进行中显示「停止生成」按钮）
    private func expandedBottom(state: QingliaoActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.sessionTitle.isEmpty ? "轻聊" : state.sessionTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(self.statusText(state))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // v3.9.10：用户明确要求**不加计时**（3.9.9 刚去掉，别再加回来）；
                // 灵动岛的“在动”感靠 progress 推进的环，不靠数字跳秒。
                Spacer(minLength: 6)
                if state.canStop {
                    stopButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 2)
        // v3.9.72（用户：展开态能不能改玻璃背景）：岛内背景归系统黑底，Apple 的
        // `activityBackgroundTint` 官方口径只管「Lock Screen 上的实时活动」；材质/glassEffect 又要采样
        // 背景（挂件进程拿不到）。所以玻璃观感只能在岛内**自绘**——见 expandedGlass。
        .background(alignment: .top) { self.expandedGlass }
    }

    /// v3.9.72：展开态底部区域的玻璃底衬（**自绘**）。
    /// 两层静态图层堆出玻璃观感：
    ///   ① 上缘亮边高光（顶部 10pt 白 0.12 渐隐）——玻璃接受环境光的亮边
    ///   ② 内侧柔光（白 0.05 向下渐隐）——光在玻璃里漫射
    /// 🚨 **刻意不画描边**（v3.9.72 审查修正）：横幅 bannerGlass 能用 `RoundedRectangle(radius: 10)`
    /// 是因为它铺满锁屏横幅**整张卡**（卡面圆角就是 10）；岛内 `.bottom` 只是岛的一块**区域**，
    /// 外面还有系统自己的大圆角遮罩——在这里画 radius 10 的小圆角描边，真机上更可能看到
    /// 「岛里又套了一个小方框 + 一条横线」，而不是底衬。岛内没有等价卡面可用，所以只做上缘高光 +
    /// 内侧柔光；要不要补边线**等真机看过再定**，别在没装机的前提下照横幅参数硬套。
    /// 岛内底色纯黑，玻璃感主要靠亮边；**不要**为了更"透"去加 Material/glassEffect
    /// （挂件进程拿不到背景采样，会整块不渲染 —— 见停止按钮那次真机事故）。
    private var expandedGlass: some View {
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.12), Color.clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 10)
                .frame(maxHeight: .infinity, alignment: .top)
            LinearGradient(colors: [Color.white.opacity(0.05), Color.clear],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }

    /// 灵动岛内唯一的可点操作（v3.9.7）。
    /// `StopGenerationIntent` 是 `LiveActivityIntent`——Apple 文档：它在**主 App 进程**执行且不打开 App，
    /// 所以能真的把 App 里正在跑的流停掉（`AppIntent` 只放挂件里会固定在挂件进程执行，触不到流）。
    /// 只在 `state.canStop` 为真时由调用方渲染：云端流没有停止接口，别显示一个点了没反应的按钮。
    private var stopButton: some View {
        Button(intent: StopGenerationIntent()) {
            Text("停止生成")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                // 🚨 v3.9.72 回退（用户真机报「灵动岛展开态胶囊不显示内容」）：v3.9.61 把这里的
                // accent 淡底换成了 `glassEffect(.regular.interactive())`，当时记录的是「小元素上的
                // 玻璃在挂件里可渲染（装机确认）」。**真机实证推翻**：岛上只剩一圈描边、里面连字都没有 ——
                // 这正是「按钮本体整块没渲染，而 `.overlay(Capsule().strokeBorder(…))` 是独立图层照旧画」
                // 的形状。原因：glassEffect 要采样背景（走 App 进程的渲染服务），挂件 / Live Activity
                // 进程拿不到。**结论：岛内不碰 glassEffect**，玻璃感靠静态图层自绘。
                .background {
                    ZStack {
                        Capsule().fill(OrbPalette.accent.opacity(0.22))
                        // 顶部亮边：上缘渐隐高光（玻璃接受环境光的亮边，与锁屏横幅 bannerGlass 同口径）
                        Capsule()
                            .fill(LinearGradient(stops: [
                                .init(color: Color.white.opacity(0.20), location: 0.00),
                                .init(color: Color.white.opacity(0.05), location: 0.45),
                                .init(color: Color.clear, location: 1.00),
                            ], startPoint: .top, endPoint: .bottom))
                    }
                }
                .overlay(Capsule().strokeBorder(OrbPalette.accent.opacity(0.28), lineWidth: 0.8))
                .foregroundStyle(OrbPalette.accent)
        }
        .buttonStyle(.plain)
    }

    /// v3.9.10：右侧阶段指示改为**渐变进度环**。
    ///
    /// 上一版用的是 SF Symbol（`ellipsis.bubble.fill` / `text.bubble.fill`）——用户反馈"信息气泡图标太丑"。
    /// 改成环，而不是再挑一个系统图标，理由是：
    ///   ① 观感能对齐 App 内既定语汇（OrbPalette 淡雅蓝紫 + 圆头描边 + 一点柔光），不是"系统默认感"；
    ///   ② 三阶段可以用**环的填充比例**表达（思考 18% / 生成 35%→86% / 完成 100%），比换图标信息量更大；
    ///   ③ 环天然会"长"，阶段变化时由系统播一次过渡，比 symbolEffect 更含蓄。
    ///
    /// 仍守住 Apple 的边界：动画**只随数据更新发生**（AOD 常亮屏不播），不做连续自走动画——
    /// 但 v3.9.10 起 `LiveActivityManager` 按节拍推 progress（v3.9.13 起 1.2s 一拍、思考期也在推），
    /// 所以环会**一跳一跳持续往前长**，观感上就是「在动」，而不是只换三次阶段。
    /// 注意：云端流只在「思考」档（`ChatView.liveActivityPhase` 要求本地 `stream.isStreaming` 才算生成），
    /// 所以云模式的进度环会停在 35% 不再前进，只有环上跑动短弧在转——这是预期，别当 bug 修。
    private func phaseRing(state: QingliaoActivityAttributes.ContentState, size: CGFloat) -> some View {
        let streaming = state.phase == QingliaoActivityAttributes.Phase.streaming.rawValue
        let failed = state.phase == QingliaoActivityAttributes.Phase.failed.rawValue   // v3.9.30
        // 夹在 0.06…1.0：0 会让环看上去像没在做事，>1 会画过头
        let progress: Double = !state.isAnswering ? 1.0 : min(1.0, max(0.06, state.progress))
        // v3.9.30：failed → 红环；done → 绿环；streaming → 紫；thinking → 蓝
        let tint: Color = failed ? OrbPalette.fail
            : (!state.isAnswering ? OrbPalette.success : (streaming ? OrbPalette.tail : OrbPalette.accent))
        let line = max(1.8, size * 0.13)
        return ZStack {
            // 底环：极淡，保证小尺寸下也有环的形状（灵动岛背景本身是黑的，太透明会看不见）
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: line)
            // 进度弧：淡蓝 → 蓝 → 紫（或完成态全绿），圆头 + 一点柔光
            Circle()
                .trim(from: 0, to: progress)
                .stroke(AngularGradient(gradient: Gradient(colors: [OrbPalette.highlight, OrbPalette.mid, tint]),
                                        center: .center,
                                        startAngle: .degrees(-90),
                                        endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.5), radius: size * 0.10)   // v3.9.13：0.18→0.10，柔光少外扩，环不往摄像头区顶
            // v3.9.13：环上还有一道**跑动短弧**（由 `spin` 每拍转 45°）。
            // 为什么需要它：`progress` 会在 0.86 封顶（不能假装知道答案总长），
            // 封顶后光看进度弧就完全静止了 —— 用户报的「动几下就不动了」正是这个。
            // 短弧只表「在跑」，不表达进度，所以封顶后它继续转，环始终有变化。
            if state.isAnswering {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(Color.white.opacity(0.85),
                            style: StrokeStyle(lineWidth: line * 0.9, lineCap: .round))
                    .rotationEffect(.degrees(-90 + state.spin * 360))
                    // 过渡挂在**短弧自己**身上（而不是外层 ZStack）：同拍里 progress 与 spin 会同时变，
                    // 挂同一棵子树上取哪个过渡由修饰符嵌套顺序决定，进度弧可能被拖成线性——
                    // 拆开各管各的：进度弧走下面 ZStack 的 easeOut，短弧走这里的 linear。
                    // v3.9.37：时长不再写死 1.1s，改按本拍的真实间隔算（见 OrbBeat）——
                    // 长回答降频到 2.0s 一拍的阶段，写死 1.1s 会留出静止段（用户报的「还是会断」）。
                    .animation(OrbBeat.animation(state.beatSeconds), value: state.spin)
            }
            if !state.isAnswering {
                if failed {
                    // v3.9.30：失败态环心——红叹号（与球体白叹号同语言）
                    Image(systemName: "exclamationmark")
                        .font(.system(size: size * 0.46, weight: .bold))
                        .foregroundStyle(OrbPalette.fail)
                        .transition(.opacity)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.46, weight: .bold))
                        .foregroundStyle(OrbPalette.success)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: size, height: size)
        // 只在 progress 变化（= 阶段推进）时播一次缓出过渡。
        // 跑动短弧的过渡挂在短弧自身（见上），避免同拍双变量时互相干扰。
        .animation(.easeOut(duration: 0.35), value: progress)
        .frame(maxWidth: size + 4)   // 固定占位（v3.9.13：+6→+4，随环一起收）：避免旁边的文字随环大小回跳
    }

    /// 状态行文案：阶段 + 模型名（模型名取自发送路径同一套选型，见 ChatView.liveActivityModelName）
    private func statusText(_ state: QingliaoActivityAttributes.ContentState) -> String {
        if state.phase == QingliaoActivityAttributes.Phase.failed.rawValue { return "生成失败" }   // v3.9.30
        if !state.isAnswering { return "已完成" }
        let phaseText: String
        if !state.actionText.isEmpty {
            phaseText = state.actionText
        } else if state.phase == QingliaoActivityAttributes.Phase.streaming.rawValue {
            phaseText = "正在生成回答"
        } else {
            phaseText = "正在理解你的问题"
        }
        return state.modelName.isEmpty ? phaseText : "\(phaseText) · \(state.modelName)"
    }

    /// 锁屏横幅（与展开态同风格，避免两套观感割裂——轻聊本地/云端 UI 统一是既定红线）
    ///
    /// v3.9.61「液态玻璃观感」（用户：灵动岛/锁屏横幅没有玻璃质感）：
    /// ActivityKit **只给 tint（纯色+透明度）**，没有材质/glass 接口，所以玻璃层只能自绘。
    /// 三层伪玻璃 + 一个内容底衬（都是锁屏横幅专用，不影响灵动岛三态）：
    ///   ① `bannerGlass`：铺满整卡 —— 顶部亮边高光（上缘 14pt 白色 0.07 渐隐 + 左右各一道同款）
    ///      + 内侧上下缘柔光（5pt，白 0.05/0.04）+ 白色 0.15 / 0.8pt 描边（iOS 26 玻璃的通透感
    ///      来自「边缘一圈细亮线」，与全站玻璃卡 0.8pt 描边同一口径）。
    ///   ② `.shadow`：内容投到玻璃上的层影（玻璃有厚度才有影）。
    ///   ③ `.activityBackgroundTint` 同步降到 0.18（见调用处）——玻璃要能透出壁纸，底下不能是死黑。
    /// ⚠️ 灵动岛**不套**这些：Apple 官方明说岛内背景不可改，而且挂件里 TimelineView 不渲染，
    ///    自绘层在岛上只会添一层多余蒙版。这里只改锁屏横幅。
    private func lockScreenBanner(state: QingliaoActivityAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            OrbView(size: 46, phase: state.phase, spin: state.spin, beat: state.beatSeconds)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.sessionTitle.isEmpty ? "轻聊" : state.sessionTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(statusText(state))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            phaseRing(state: state, size: 33)   // v3.9.12：环收小（42 → 33），球同时加大到 46，主次分明
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // 内容投在玻璃上的层影（玻璃有厚度）
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        .background(alignment: .top) { self.bannerGlass }
    }

    /// 横幅玻璃层：顶部亮边高光 + 1pt 白色细描边 + 内侧柔光。
    /// 观感参照 iOS 26 玻璃卡（顶部微亮、边缘一圈细亮线、内侧透光），不是 Android 式高光带。
    private var bannerGlass: some View {
        GeometryReader { geo in
            ZStack {
                // 顶部亮边：上缘一条渐隐高光（玻璃接受环境光的亮边）
                LinearGradient(colors: [Color.white.opacity(0.07), Color.clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 14)
                    .frame(maxHeight: .infinity, alignment: .top)
                // 整体亮线：垂直于上缘方向 = 左右各一道渐隐（玻璃卡边缘的亮边是两侧都有）
                LinearGradient(colors: [Color.white.opacity(0.05), Color.clear],
                               startPoint: .top, endPoint: .bottom)
                    .rotationEffect(.degrees(90))
                    .frame(height: 14)
                // 内侧柔光：上下内缘压一层极淡的白，制造「光在玻璃里漫射」
                VStack(spacing: 0) {
                    LinearGradient(colors: [Color.white.opacity(0.05), Color.clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 5)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [Color.clear, Color.white.opacity(0.04)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 5)
                }
                // 全程 0.8pt 白描边（口令与全站玻璃卡一致，见 Pill.swift / dashboardCard）
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.8)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 轻聊球

/// 轻聊球调色板——与 App 主色一致（Assets 里 AccentColor = #0A84FF），高光/尾部各一段淡雅蓝紫。
enum OrbPalette {
    static let highlight = Color(red: 0.81, green: 0.92, blue: 1.00)   // #CFEBFF
    static let mid = Color(red: 0.24, green: 0.61, blue: 1.00)         // #3E9BFF
    static let accent = Color(red: 0.04, green: 0.52, blue: 1.00)      // #0A84FF（App 主色）
    static let tail = Color(red: 0.36, green: 0.23, blue: 1.00)        // #5B3BFF
    static let success = Color(red: 0.19, green: 0.82, blue: 0.35)     // #30D158
    static let fail = Color(red: 1.00, green: 0.27, blue: 0.23)        // #FF453A（v3.9.30 失败态）
}

/// 拍间隔 → 挂件过渡时长的换算（**数值真源在共享的 `LiveActivityAttributes.swift` 里**，
/// 主 App 的推手节奏也取同一份，别再往这里写数字）。
///
/// 这里只做 SwiftUI 包装：属性文件不 import SwiftUI，`Animation` 只在挂件侧需要。
/// 写成 `enum` 静态命名空间而非 `static let Animation`：Swift 6 严格并发下静态存储要求类型 Sendable，
/// `Animation` 的 Sendable 性不在本机可验证范围（Linux 无 SwiftUI）——函数零风险。
extension OrbBeat {
    static func animation(_ beat: Double) -> Animation {
        .linear(duration: duration(beat))
    }
}

/// 品牌球体：三态共用同一颗球。
/// · thinking  → 外圈呼吸光晕（脉冲）
/// · streaming → 球外一圈不确定态旋转弧
/// · done      → 绿球 + 白对勾
/// · failed    → 红球 + 白叹号（v3.9.30：失败态，此前失败时岛上无感知）
///
/// **v3.9.13 重做（用户报「动几下就不动了」）**：原来球体 + 脉冲/旋转弧全在
/// `TimelineView(.animation)` 包的 `Canvas` 里，指望挂件进程 20fps 自走。
/// 但实时活动**没有连续帧源**（Apple：视图只在数据更新时重绘），所以那套帧源在真机上基本不跑——
/// 观感就是「动几下（几次 update 各跳一下）然后彻底静止」。
///
/// 现在拆开：
/// - **Canvas 只画球体本体**（径向渐变 + 完成对勾 + 描边）= 纯静态帧，`t=0` 就是完整画面，
///   且不再需要 `TimelineView`（少一整套 20fps 重绘尝试，省电也少一层不确定性）。
/// - **脉冲环 / 旋转弧改用 SwiftUI 的 `Circle().stroke()` + `rotationEffect` / `frame` 表达，
///   由 `spin` 驱动**（App 侧每拍 update 推进 0.125）+ `.animation(…, value: spin)` 挂过渡：
///   动画是「随数据更新发生」的（Apple 文档明确支持，最长 2s），所以每拍系统会平滑播一段，
///   过渡时长 ≈ 拍间隔（`OrbBeat.animation`），拍与拍之间几乎接得上 → 观感上就是连续在转。
struct OrbView: View {

    var size: CGFloat
    var phase: String
    /// - spin：不确定态的**累计相位**（不回绕，首帧默认 0；由 `LiveActivityManager` 每拍 +0.125 推进）。
    ///   需要 0…1 循环量的地方自己取余并乘上想要的圈速（见 `pulseRings`）。
    /// 默认 0 → 首帧（没有任何 update 时）也画出完整的球 + 一段弧，不会空白。
    var spin: Double = 0
    /// v3.9.37：**当前拍间隔（秒）**——由 `ContentState.beatSeconds` 透传进来，过渡时长按它现算
    /// （见 `OrbBeat.animation`）。旧实现写死 1.1s，长回答时 App 侧降频到慢档，每拍尾部就多出
    /// 静止段（用户报的「动画还是会断」）。
    /// ⚠️ **刻意不给默认值**：漏传就必须编译不过 —— 有默认值时会静默按起步节奏渲染，
    /// 慢档下原地复现这次事故（4 处调用点全部显式透传）。
    var beat: Double

    var body: some View {
        ZStack {
            // 球体本体（静态帧；实时活动里没有帧源，所以不依赖 TimelineView）
            Canvas { gc, canvasSize in
                draw(gc, size: canvasSize)
            }
            if phase == QingliaoActivityAttributes.Phase.thinking.rawValue {
                pulseRings
            }
            if phase == QingliaoActivityAttributes.Phase.streaming.rawValue {
                spinningArc
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// 思考中：两圈错相位脉冲环（呼吸感），相位由 `spin` 推进
    private var pulseRings: some View {
        // 外扩上限 1.08（v3.9.10：从 1.15 收到 1.08，为球放大让路）。按 r = size/2 × 0.86 计算，
        // 1.08 时最大外径 ≈ 0.93 × size + 描边 ≈ 0.98 × size，**完全落在自身 frame 内**，
        // 所以「会不会被遮罩切」取决于 frame（紧凑 27 / 极简 24 / 展开 36 / 锁屏 46）本身不超出区域尺寸。
        ForEach(0..<2, id: \.self) { i in
            // 相位：`spin` 每拍 +0.125，乘 5 后每拍走 0.625 圈 → 每拍 0.625 圈（秒数随档位变，
            // 别再往注释里写死秒数：起点档 ≈1.9s 一圈、慢档 ≈3.2s 一圈。对齐 v3.9.9 之前
            // Canvas 版的 1.8s；那时删掉 Canvas 后这里一度是 9.6s 一圈，思考期球看起来像静图——
            // 第二轮静态审查抓到的观感回归）。
            // 口径（第三轮审查确认）：0.625 圈/拍是非整数，取余后采样序列是「两圈反相、交替胀缩」的
            // 呼吸（8 拍覆盖 8 个离散尺寸），**不是**单调外扩的一圈；d 与 opacity 恒反相，
            // 所以每拍都是「外扩+淡出」或「回缩+显影」，方向不矛盾。
            // ⚠️ 不要照「每拍整圈」写成 ×8：取余后每拍 p 完全相同 → SwiftUI 判定值未变、不重绘，反而彻底不动。
            let p = (spin * 5 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
            // 显式 CGFloat：`size * 0.86 * (1.0 + 0.08 * p)` 会因 SE-0307 隐式转换让 d 变成 Double
            // （能编译但语义混浊），写明类型省掉这层推断
            let d: CGFloat = size * 0.86 * (1.0 + 0.08 * CGFloat(p))
            Circle()
                .stroke(OrbPalette.accent.opacity(0.45 * (1 - p)), lineWidth: max(1, size * 0.05))
                .frame(width: d, height: d)
                .animation(OrbBeat.animation(beat), value: spin)
        }
    }

    /// 输出中：不确定态旋转弧（不是进度，只是「在跑」）。
    /// 弧长 0.30 圈，起点随 `spin` 每拍转 45°；线性过渡按本拍真实间隔算（`OrbBeat.animation`），
    /// 接住两拍之间的空隙。
    private var spinningArc: some View {
        let d = size * 0.86 * 1.03
        return Circle()
            .trim(from: 0, to: 0.30)
            .stroke(OrbPalette.accent.opacity(0.9),
                    style: StrokeStyle(lineWidth: max(1.5, size * 0.07), lineCap: .round))
            .frame(width: d, height: d)
            .rotationEffect(.degrees(spin * 360))
            .animation(OrbBeat.animation(beat), value: spin)
    }

    private func draw(_ gc: GraphicsContext, size canvasSize: CGSize) {
        let full = min(canvasSize.width, canvasSize.height)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let r = full / 2 * 0.86
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let isDone = (phase == QingliaoActivityAttributes.Phase.done.rawValue)
        let isFailed = (phase == QingliaoActivityAttributes.Phase.failed.rawValue)   // v3.9.30

        // 球体本体（径向渐变：左上高光 → 主色 → 尾部紫；failed = 红球）
        gc.fill(Path(ellipseIn: rect),
                with: .radialGradient(isFailed ? Self.failedGradient
                                      : (isDone ? Self.doneGradient : Self.orbGradient),
                                      center: CGPoint(x: center.x - r * 0.34, y: center.y - r * 0.44),
                                      startRadius: 0,
                                      endRadius: r * 1.25))

        // 完成：白对勾
        if isDone {
            let mark = Path { p in
                p.move(to: CGPoint(x: center.x - r * 0.40, y: center.y + r * 0.02))
                p.addLine(to: CGPoint(x: center.x - r * 0.10, y: center.y + r * 0.32))
                p.addLine(to: CGPoint(x: center.x + r * 0.42, y: center.y - r * 0.28))
            }
            gc.stroke(mark, with: .color(.white),
                      style: StrokeStyle(lineWidth: max(1.5, r * 0.24), lineCap: .round, lineJoin: .round))
        }

        // v3.9.30：失败——白叹号（竖条 + 点，与系统 error 观感一致）
        if isFailed {
            let bar = Path { p in
                p.move(to: CGPoint(x: center.x, y: center.y - r * 0.46))
                p.addLine(to: CGPoint(x: center.x, y: center.y + r * 0.14))
            }
            gc.stroke(bar, with: .color(.white),
                      style: StrokeStyle(lineWidth: max(1.5, r * 0.24), lineCap: .round))
            let dot = CGRect(x: center.x - r * 0.11, y: center.y + r * 0.32,
                             width: r * 0.22, height: r * 0.22)
            gc.fill(Path(ellipseIn: dot), with: .color(.white))
        }

        // 边缘细描边（与 App 卡片 0.8pt 描边规范同一语气）
        gc.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.22)), lineWidth: 1)
    }

    /// 渐变**写成计算属性**而非 `static let`：Swift 6 严格并发下，全局/静态存储要求类型 Sendable，
    /// `Gradient` 是否 Sendable 不在本机可验证范围（Linux 无 SwiftUI）——计算属性不走全局存储，零风险。
    private static var orbGradient: Gradient {
        Gradient(stops: [
            .init(color: OrbPalette.highlight, location: 0.00),
            .init(color: OrbPalette.mid, location: 0.42),
            .init(color: OrbPalette.accent, location: 0.78),
            .init(color: OrbPalette.tail, location: 1.00),
        ])
    }

    private static var doneGradient: Gradient {
        Gradient(stops: [
            .init(color: Color(red: 0.68, green: 0.98, blue: 0.78), location: 0.00),
            .init(color: OrbPalette.success, location: 0.55),
            .init(color: Color(red: 0.05, green: 0.55, blue: 0.28), location: 1.00),
        ])
    }

    /// v3.9.30：失败态红球（与系统红 error 观感一致）
    private static var failedGradient: Gradient {
        Gradient(stops: [
            .init(color: Color(red: 1.00, green: 0.76, blue: 0.76, opacity: 1), location: 0.00),
            .init(color: Color(red: 1.00, green: 0.27, blue: 0.23, opacity: 1), location: 0.55),
            .init(color: Color(red: 0.62, green: 0.09, blue: 0.07, opacity: 1), location: 1.00),
        ])
    }
}
