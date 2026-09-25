import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// 轻聊形象 + 阶段 + 计时 +（可选）停止生成。
///
/// v3.9.79 两处形态变更（用户 2026-09-25 真机反馈，**灵动岛与锁屏横幅一起改**）：
///   · 左侧图标：球 → **用户在外观设置里选的卡通形象**（`PetOrbView`，随 `ContentState.petStyle` 下发）
///   · 右侧：阶段环 `phaseRing` → **线性进度条** `phaseBar`（语义仍是「本轮推进度」，不是答案完成度）
///   球的渲染器 `OrbView` 与环 `phaseRing` **都已删除**（没有任何调用点了）；要回滚从 git 历史取。
///   `OrbPalette` 仍是在用的配色真源（进度条渐变 / 停止按钮 / keylineTint），别一起删。
///
/// 四条设计约束（都是硬约束，别绕）：
/// 1. ~~计时用 `Text(_:style: .timer)` 交给系统自走~~ **v3.9.9 已移除计时文字**（用户要求），
///    右侧改为阶段指示（v3.9.10 起是渐变进度环 → v3.9.79 起是线性进度条）。原注释保留一句为什么当初用它——
///    侧载免费签名没有推送更新，App 被挂起后文本不会再刷新，只有系统计时钟照走，所以「已用时」必须靠它。
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
                    // v3.9.79：图标从「球」换成**用户选的卡通形象**（用户 2026-09-25：「加改一条，
                    // 灵动岛球图标跟随卡通形象动态图」）。形象随 ContentState.petStyle 下发，尺寸口径不变。
                    PetOrbView(size: 36, styleRaw: context.state.petStyle, phase: context.state.phase,
                               spin: context.state.spin, beat: context.state.beatSeconds)
                        .padding(.leading, 1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // v3.9.79（用户 2026-09-25：「灵动岛右边的圈圈也改成进度条」）：阶段环 → **线性进度条**。
                    // 条比环省横向空间、读数更直白；语义不变——长度是**本轮推进度**（0.18→0.35→0.86→1.0），
                    // 不是「已完成 72% 的答案」（见文件头第 3 条硬约束）。
                    // 尺寸：宽 54 × 高 6.5（环时代占位 24+4=28pt 宽，条更宽但更矮，不会往中段摄像头区顶高）。
                    self.phaseBar(state: context.state, width: 54, height: 6.5)
                        .padding(.trailing, 1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    self.expandedBottom(state: context.state)
                }
            } compactLeading: {
                // v3.9.12：25 → 27（真机反馈「球反而小了」——球再加大一档，环同时收小，主次才分明）
                // v3.9.79：同上，换卡通形象（27 仍取 36 的 3/4，主次关系不变）
                PetOrbView(size: 27, styleRaw: context.state.petStyle, phase: context.state.phase,
                           spin: context.state.spin, beat: context.state.beatSeconds)
            } compactTrailing: {
                self.compactTrailing(state: context.state)
            } minimal: {
                PetOrbView(size: 24, styleRaw: context.state.petStyle, phase: context.state.phase,
                           spin: context.state.spin, beat: context.state.beatSeconds)
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
    /// → 16（v3.9.13，真机反馈「环再小一点，左边碰到摄像头了」）。
    /// v3.9.79（用户 2026-09-25：「灵动岛右边的圈圈也改成进度条」）：环 → **线性进度条**。
    /// 尺寸口径：宽 28 × 高 5.5。宽度略大于环时代的占位（16+4=20pt），但因为条是**窄高比极低**的
    /// 横向元素，视觉重心比等宽环低得多，不会像环那样往中段摄像头区顶（v3.9.13 那次真机反馈的坑）。
    @ViewBuilder
    private func compactTrailing(state: QingliaoActivityAttributes.ContentState) -> some View {
        self.phaseBar(state: state, width: 28, height: 5.5)
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

    /// v3.9.79：岛内右侧的**线性进度条**（用户 2026-09-25：「灵动岛右边的圈圈也改成进度条」）。
    ///
    /// 与环共用同一份语义与颜色口径（只换形状，别让两处口径分叉）：
    ///   · 长度 = **本轮推进度**（思考 18% → 生成 35%→86% → 完成 100%）。**不是**「已完成 72% 的答案」
    ///     —— 流式回答没有真实总长（文件头第 3 条硬约束，别把条当百分比展示承诺）。
    ///   · 颜色：thinking 蓝 / streaming 紫 / done 绿 / failed 红（同原 `phaseRing`）。
    ///   · 「在动」的兜底：生成中条上跑一段白色高光，由 `spin` 驱动（对应环时代的「跑动短弧」）。
    ///     ⚠️ 高光位置用**折返（三角波）**而不是取余：取余到 1 会瞬跳回 0 → 白块每轮倒着闪一下
    ///     （环时代的审查踩过同一个坑：`spin.truncatingRemainder` 直接当旋转角会让弧倒扫一圈）。
    ///   · 不做连续自走动画：动效**只随数据更新发生**（文件头第 2 条硬约束）。
    ///   · 完成/失败态不画高光：那两态 `progress = 1.0`，条已满，再跑高光会显得还在算。
    private func phaseBar(state: QingliaoActivityAttributes.ContentState, width: CGFloat, height: CGFloat) -> some View {
        let streaming = state.phase == QingliaoActivityAttributes.Phase.streaming.rawValue
        let failed = state.phase == QingliaoActivityAttributes.Phase.failed.rawValue
        let done = !state.isAnswering
        // 夹在 0.06…1.0：0 会让条看上去像没在做事，>1 会画过头（与环同口径）
        let progress: Double = done ? 1.0 : min(1.0, max(0.06, state.progress))
        let tint: Color = failed ? OrbPalette.fail
            : (done ? OrbPalette.success : (streaming ? OrbPalette.tail : OrbPalette.accent))
        let knobW: CGFloat = width * 0.22
        // 折返相位：spin 每拍 +OrbBeat.spinStep（0.125）→ 乘 2 得每拍推进 0.25，
        // 取模 2 后在 0↔1 之间折返（速度恒定、每半程换向），全程连续、无跳变。
        let phase = state.spin * 2
        let half = phase.truncatingRemainder(dividingBy: 2)
        let shuttle: CGFloat = half <= 1 ? CGFloat(half) : CGFloat(2 - half)
        return ZStack(alignment: .leading) {
            // 底条：极淡，保证小黑底上也看得见条的形状
            Capsule().fill(Color.white.opacity(0.16))
            // 已推进部分：淡蓝 → 蓝 → 紫（完成态全绿 / 失败态红）
            Capsule()
                .fill(LinearGradient(colors: [OrbPalette.highlight, OrbPalette.mid, tint],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: max(height, width * CGFloat(progress)))
                .shadow(color: tint.opacity(0.5), radius: height * 0.7)
                .animation(.easeOut(duration: 0.35), value: progress)
            // 生成中：条上跑一段高光（progress 在 0.86 封顶后条不再长，全靠它表示「还在跑」）
            // 判据与上面注释的 done/failed 口径**逐字一致**（审查④ F7a：原来只判 isAnswering，
            // 一旦出现 phase=failed 且 isAnswering=true 的非法组合就会画成「红条 + 跑高光」）
            if !done && !failed {
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: knobW, height: height * 0.72)
                    .offset(x: (width - knobW) * shuttle)
                    .animation(OrbBeat.animation(state.beatSeconds), value: state.spin)
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    /// v3.9.10：右侧阶段指示改为**渐变进度环**。
    /// ⚠️ **v3.9.79 整块退役**（用户真机：「灵动岛右边的圈圈也改成进度条」，随后回「1」把锁屏横幅也一起改）：
    ///    岛内与横幅现在都走 `phaseBar(...)`，本函数已删除 —— 要回滚请从 git 历史取，别凭记忆重写。
    ///    环时代付过的代价已写进 `phaseBar` 的注释：取余会让高光每轮倒着闪、柔光外扩会顶到中段摄像头区。
    ///    保留 `///` 而不降级成 `//`：**这行是两个真值表切片的终点锚点**（stopBtnSlice / phaseBarSlice），
    ///    改样式就等于改锚点，不划算（审查 F9 建议降级，这里按锚点稳定性否决）。

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
            // v3.9.79（用户回「1」拍板：锁屏横幅也换）：球 → 卡通形象，与灵动岛三处同一份画法/同一份状态下发
            PetOrbView(size: 46, styleRaw: state.petStyle, phase: state.phase,
                       spin: state.spin, beat: state.beatSeconds)
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
            // v3.9.79：环 → 进度条（与岛内同一函数，只差尺寸；横幅通栏、没有中段摄像头位，所以可以给到 52 宽）
            phaseBar(state: state, width: 52, height: 7)
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

/// v3.9.79：**灵动岛图标 = 用户在设置里选的卡通形象**（用户 2026-09-25：「加改一条，
/// 灵动岛球图标跟随卡通形象动态图」）。
///
/// 三个硬约束（抄送一份，省得下次重新踩）：
///  1. **形象靠数据下发，不靠挂件自己读设置**：侧载免费签名拿不到 App Groups，
///     扩展进程的 `UserDefaults.standard` 跟主 App 不是同一个域 → 只能走 `ContentState.petStyle`。
///  2. **复用主 App 的矢量绘制**（`PetPainter`，纯 `Canvas + Path`、零依赖）——同一份源码
///     在 project.yml 里同时编进主 App 与挂件两个 target，画法永远一致，不用在挂件里再抄一套造型。
///  3. **动效只随数据更新发生**（文件头第 2 条硬约束）：实时活动**没有连续帧源**，
///     所以形象的「呼吸」不做 `repeatForever`/`TimelineView(.animation)`，而是**每拍换向一次**
///     （`spin` 每拍 +`OrbBeat.spinStep` → 取第几拍的奇偶决定缩放/起伏的哪一端），
///     过渡时长按本拍真实间隔现算（`OrbBeat.animation`）→ 两拍接得上，观感是持续起伏。
///     眨眼同理**不做**：0.06s 的瞬时眨眼在「1.2s～2s 一段过渡」的粒度下渲染不出来，
///     硬做只会变成慢速眯眼，比不眨更怪（表情仍由 `state` 切换：思考 = 睁眼思考脸，失败 = alert 脸）。
struct PetOrbView: View {

    var size: CGFloat
    /// `PetStyle.rawValue`（由 `ContentState.petStyle` 透传；认不出的值落回液态小生物）
    var styleRaw: String
    /// 阶段字符串（`QingliaoActivityAttributes.Phase`）
    var phase: String
    /// 累计相位（同 OrbView.spin，每拍 +0.125，不回绕）
    var spin: Double = 0
    /// 同 `OrbView.beat`：**刻意不给默认值**，漏传必须编译不过（慢档下会静默变快，见 OrbView 注释）
    var beat: Double

    private var style: PetStyle { PetStyle.from(styleRaw) }

    /// 阶段 → 形象表情（与球时代同口径：thinking/streaming = 思考脸，failed = alert 脸，done = 常态）
    private var petState: PetState {
        switch phase {
        case QingliaoActivityAttributes.Phase.failed.rawValue:
            return .alert
        case QingliaoActivityAttributes.Phase.thinking.rawValue,
             QingliaoActivityAttributes.Phase.streaming.rawValue:
            return .thinking
        default:
            return .idle        // done / 未知值
        }
    }

    /// 本拍是「吸气」还是「呼气」：按拍数取奇偶（用共享步长换算，别自己写 0.125）
    private var inhale: Bool {
        Int((spin / OrbBeat.spinStep).rounded()) % 2 == 0
    }

    var body: some View {
        Canvas { gc, canvasSize in
            PetPainter(style: style,
                       state: petState,
                       blink: false,       // 见上：实时活动渲染不出瞬时眨眼，硬做会变成慢速眯眼
                       // 岛内尺寸 24 ~ 36pt 全在 76pt 简化阈值以下：只画头 + 眼 + 嘴。
                       // 这里显式写成尺寸判断（而不是靠 PetAvatar 的 76pt 阈值），是因为本视图
                       // 不经过 PetAvatar，别让「简化口径」变成第二处真源。
                       simplify: size < PetKeys.simplifyBelow)
                .draw(&gc, size: canvasSize)
        }
        .frame(width: size, height: size)
        // 呼吸：整层缩放 + 极轻的上下起伏（不重绘 Canvas，最省）——每拍换向，过渡 = 本拍间隔
        // v3.9.79：呼吸改成**只往内收**（0.97）+ 向下极轻起伏。
        // 原来用 1.03 外扩 + 向上 offset：36pt 展开态会顶出布局框约 1.26pt，而同一区域上方就是传感器区
        // （见 44-46 行：36.67pt 顶行，38 就会被圆角遮罩切上下边）——审查 F5 推算出来的真机切边风险。
        // 改内收后任何尺寸都不越框，动感不变（缩放方向反过来而已）。
        .scaleEffect(inhale ? 0.97 : 1.0)
        .offset(y: inhale ? 0 : size * 0.015)
        .animation(OrbBeat.animation(beat), value: spin)
        .accessibilityHidden(true)
    }
}

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

// ⚠️ v3.9.79：球体视图 `OrbView` **已整体退役**——灵动岛三处 + 锁屏横幅现在都画用户的卡通形象（`PetOrbView`），
//    没有任何调用点了，所以整块删掉（球时代的脉冲环/旋转弧/对勾/叹号一并退场，动画改由 `PetOrbView` 的每拍呼吸承担）。
//    要回滚请从 git 历史取，别凭记忆重写；`OrbPalette` 仍在用（进度条配色 / 停止按钮 / keystore tint），别一起删。
