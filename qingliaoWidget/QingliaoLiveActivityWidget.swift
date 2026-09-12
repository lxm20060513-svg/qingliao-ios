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
///    直接忽略动画修饰符）。所以**连续自走动画在实时活动里没有帧源**——本文件仍用
///    `TimelineView(.animation)` 包着 `Canvas`，但只当「万一系统给帧」的加分项：
///    `t=0` 那一帧本身就是完整的球 + 环（静态帧就好看），不动只是少一层装饰，观感不会塌。
///    真正的变化感来自 `LiveActivityManager` 在 thinking→streaming→done 的 update（系统会播过渡）。
/// 3. **不画假进度**：流式回答没有真实总长，所以「输出中」用**不确定态旋转弧**（活动指示器语义），
///    绝不画一个百分比弧——`progress` 这种字段也不伪造成总进度。
/// 4. 状态行只说确证的事实（阶段 + 模型名），不虚构「联网搜索 / 写代码」这类没有数据源的措辞。
struct QingliaoLiveActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QingliaoActivityAttributes.self) { context in
            // 锁屏 / 不支持灵动岛设备的横幅
            self.lockScreenBanner(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
                // v3.9.7：点横幅回聊天页（主 App 已注册 qingliao:// scheme）
                .widgetURL(QingliaoLiveActivityWidget.chatURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    OrbView(size: 34, phase: context.state.phase)
                        .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    self.phaseRing(state: context.state, size: 16)
                        .padding(.trailing, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    self.expandedBottom(state: context.state)
                }
            } compactLeading: {
                OrbView(size: 22, phase: context.state.phase)
            } compactTrailing: {
                self.compactTrailing(state: context.state)
            } minimal: {
                OrbView(size: 20, phase: context.state.phase)
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
    @ViewBuilder
    private func compactTrailing(state: QingliaoActivityAttributes.ContentState) -> some View {
        self.phaseRing(state: state, size: 13)
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
                Spacer(minLength: 6)
                if state.canStop {
                    stopButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 2)
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
                .background(OrbPalette.accent.opacity(0.22), in: Capsule())
                .foregroundStyle(OrbPalette.accent)
        }
        .buttonStyle(.plain)
    }

    /// v3.9.10：右侧阶段指示改为**渐变进度环**。
    ///
    /// 上一版用的是 SF Symbol（`ellipsis.bubble.fill` / `text.bubble.fill`）——用户反馈"信息气泡图标太丑"。
    /// 改成环，而不是再挑一个系统图标，理由是：
    ///   ① 观感能对齐 App 内既定语汇（OrbPalette 淡雅蓝紫 + 圆头描边 + 一点柔光），不是"系统默认感"；
    ///   ② 三阶段可以用**环的填充比例**表达（思考 26% / 生成 72% / 完成 100%），比换图标信息量更大；
    ///   ③ 环天然会"长"，阶段变化时由系统播一次过渡，比 symbolEffect 更含蓄。
    ///
    /// 仍守住 Apple 的边界：动画**只随数据更新发生、最长 2s、常亮屏(AOD)不播**，不做连续自走动画。
    private func phaseRing(state: QingliaoActivityAttributes.ContentState, size: CGFloat) -> some View {
        let streaming = state.phase == QingliaoActivityAttributes.Phase.streaming.rawValue
        let progress: Double = !state.isAnswering ? 1.0 : (streaming ? 0.72 : 0.26)
        let tint: Color = !state.isAnswering ? OrbPalette.success : (streaming ? OrbPalette.tail : OrbPalette.accent)
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
                .shadow(color: tint.opacity(0.5), radius: size * 0.18)
            if !state.isAnswering {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(OrbPalette.success)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        // 只在 progress 变化（= 阶段推进）时播一次缓出过渡
        .animation(.easeOut(duration: 0.35), value: progress)
        .frame(maxWidth: 44)   // 与上一版一致：给灵动岛右侧固定占位，避免旁边的文字回跳
    }

    /// 状态行文案：阶段 + 模型名（模型名取自发送路径同一套选型，见 ChatView.liveActivityModelName）
    private func statusText(_ state: QingliaoActivityAttributes.ContentState) -> String {
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
    private func lockScreenBanner(state: QingliaoActivityAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            OrbView(size: 38, phase: state.phase)
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
            phaseRing(state: state, size: 16)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
}

/// 品牌球体：三态共用同一颗球。
/// · thinking  → 外圈呼吸光晕（脉冲）
/// · streaming → 球外一圈不确定态旋转弧
/// · done      → 绿球 + 白对勾
///
/// 动画由 `TimelineView(.animation)`（≤20fps）在挂件进程本地自走；t=0 那一帧本身就是一颗完整的球，
/// 所以万一系统在实时活动里不跑 TimelineView，降级后只是「不动」，观感不会塌。
struct OrbView: View {

    var size: CGFloat
    var phase: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { ctx in
            Canvas { gc, canvasSize in
                draw(gc, size: canvasSize, t: ctx.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func draw(_ gc: GraphicsContext, size canvasSize: CGSize, t: Double) {
        let full = min(canvasSize.width, canvasSize.height)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let r = full / 2 * 0.86
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let isThinking = (phase == QingliaoActivityAttributes.Phase.thinking.rawValue)
        let isStreaming = (phase == QingliaoActivityAttributes.Phase.streaming.rawValue)
        let isDone = (phase == QingliaoActivityAttributes.Phase.done.rawValue)

        // 思考中：两圈错相位脉冲环（呼吸感）
        // 半径上限 r × 1.15：紧凑区只有 22pt、极简 20pt，外扩过多会被灵动岛的遮罩切掉半圆
        if isThinking {
            for i in 0..<2 {
                let p = (t / 1.8 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                let ringR = r * (1.0 + 0.15 * p)
                let ringRect = CGRect(x: center.x - ringR, y: center.y - ringR,
                                      width: ringR * 2, height: ringR * 2)
                gc.stroke(Path(ellipseIn: ringRect),
                          with: .color(OrbPalette.accent.opacity(0.45 * (1 - p))),
                          lineWidth: max(1, full * 0.05))
            }
        }

        // 输出中：不确定态旋转弧（不是进度，只是「在跑」）
        if isStreaming {
            let arcR = r * 1.03
            let start = (t / 1.4).truncatingRemainder(dividingBy: 1)
            var arc = Path()
            arc.addArc(center: center, radius: arcR,
                       startAngle: .radians(start * 2 * .pi),
                       endAngle: .radians((start + 0.30) * 2 * .pi),
                       clockwise: false)
            gc.stroke(arc, with: .color(OrbPalette.accent.opacity(0.9)),
                      style: StrokeStyle(lineWidth: max(1.5, full * 0.07), lineCap: .round))
        }

        // 球体本体（径向渐变：左上高光 → 主色 → 尾部紫）
        gc.fill(Path(ellipseIn: rect),
                with: .radialGradient(isDone ? Self.doneGradient : Self.orbGradient,
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
}
