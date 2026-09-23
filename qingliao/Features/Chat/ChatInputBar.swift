// MARK: - ChatInputBar（从 ChatComponents.swift 拆出）
import SwiftUI


// MARK: - v3.9.61 两层输入栏 · 几何常量（单一真源）
//
// 用户原话：「输入框在键盘弹出状态做两层处理，第一层作为消息输入层，无文字输入时显示输入消息，
// 光标也走这一层；第二层走工具，附件、相机图标自己模型选择放第二层」。
//
// 本机渲染不出文字宽度，这些数按**令牌算式**推出（Spacing/Typography 的实际档位）：
//   · 第一层 minHeight = textArea 单行高：`padding(.vertical, Spacing.xl)` 12×2
//     + 正文 15pt 行高 ≈17.9 ≈ **42**（v3.9.52 起 lineLimit 1...6 恒 1 行起）；
//   · 第二层 minHeight = **34**（v3.9.65 起）：附件/相机视觉 22 + 上下各 6
//     （v3.9.61~64 是 42 = 视觉 30 + 上下各 6；命中区走 hitArea44 的负 padding 外扩，
//     **不占布局**，所以行高 = 视觉占位不是命中区）。
// 两层同高时代（42+8+42=92）容器是稳定对称比例；v3.9.65 起第二层矮 8pt（42+8+34=**84**），
// 长文本态第一层长高、第二层仍保持 34。
enum ChatInputBarLayout {
    /// v3.9.65 起用户明确「加到 18」→ v3.9.66 再明确「圆角加到 20」：**明确数值规格**，
    /// 不套令牌档位梯度（Radius 6 档：8/10/12/14/16/22，20 落在 card 16 与 hero 22 之间，
    /// 为它新开中间档会破坏语义层级体系）。
    /// 落地形态 = 收进本 enum 做单一真源，四处（玻璃 in: / 聚焦蓝边 / 常态白边 / 流光）
    /// 全部引用它，仍是「不散落魔法数」；将来若要回 16 档只改这一处。
    /// 平坦段算式（Spacing.md = 12 → 容器上下 padding 24）：
    ///   展开态 84（42+8+34+24）− 20×2 = **44pt**，平坦段充裕；
    ///   收起态 66（42+24，第二层高与间距归 0）− 20×2 = **26pt**，弧顶仍不咬第一层文字。
    static let containerCornerRadius: CGFloat = 20
    /// 第一层（消息输入层）最小高度
    static let messageRowMinHeight: CGFloat = 42
    /// 第二层（工具层）最小高度
    /// v3.9.65：附件/相机图标变小 + 第二层变矮（用户「第二层的附件和相机图标变小降低第二层高度」）：
    /// 图标视觉面 32×30 → **22×22**，行高由图标视觉面 + 上下余量定 → 42 降到 **34**（22 + 6×2）。
    /// 命中区仍走 `hitArea44` 的负 padding 外扩（22+11×2=44，视觉占位零变化），「变小」减的是
    /// 视觉尺寸不是可点区域——Apple HIG 最小 44pt 命中区口径不变。
    /// 第一层仍保持 42 不动：这轮用户只点了第二层，输入框行高不属同一次改动面。
    static let toolRowMinHeight: CGFloat = 34
    /// 两层间距（与原单行 HStack 的 spacing 同参，视觉零差异）
    static let rowGap: CGFloat = Spacing.md
    /// 容器最小总高 = 42 + 8 + 34 = 84（读这个数的地方：注释算式、真值表镜像）
    static let containerMinHeight: CGFloat = 84
}

struct ChatInputBar: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    var streaming: Bool
    var onSend: () -> Void
    var onStop: () -> Void = {}
    var onPickAttachment: () -> Void = {}
    var onCamera: () -> Void = {}   // v2.0.38 拍照输入
    // 语音输入（按住说话）
    var isRecording: Bool = false
    var onVoiceStart: () -> Void = {}
    var onVoiceEnd: () -> Void = {}
    // v2.0.96：语音转文字模式（长按发送按钮进入；Siri 彩色图标）
    // v3.9.7：语音态**不再**给输入框加流光特效——只保留「发送键变收音图标」这一个视觉提示
    var voiceMode: Bool = false
    var onVoiceModeToggle: () -> Void = {}
    // v2.0.100：转写中动画（输入框「语音转换中…」+ 按钮转圈）
    var transcribing: Bool = false
    // v2.0.101：转写停止按钮回调
    var onCancelTranscribe: () -> Void = {}
    // v2.0.106：长按输入框触发语音转文字（效果与长按发送键一致，不弹键盘）
    // v2.0.109b：onChanged 记录按下瞬间键盘可见状态（down 时键盘未弹/已弹，比时间戳推断可靠）
    var onLongPressInput: (Bool) -> Void = { _ in }
    // 语音功能启用开关（v3.9.3：设备端识别不依赖后端，本地/云端恒为 true；参数保留以便将来按需关闭）
    var voiceEnabled: Bool = true
    /// v3.9.6：录音中的实时文本（直接来自 @Published liveText，录音态由它在输入栏上屏）
    var recordingText: String = ""
    /// v3.9.6 临时诊断：实时结果计数（V=volatile 中间结果 / F=final 定稿）
    var recordingDiag: String = ""
    /// v3.9.14：录音满 3s 仍无任何识别结果（LiveSpeechTranscriber.liveStalled）。
    /// 用户反馈「录音时输入框被一串诊断码占住、看不到文字上屏」——诊断码收窄成**只在这种异常态**显示，
    /// 正常录音时输入框保持干净（识别文本 + 脉动红点）。
    var recordingStalled: Bool = false
    @Environment(KeyboardObserver.self) private var kbEnv
    // v3.4.28：横屏限宽
    @Environment(\.horizontalSizeClass) private var hSizeInput
    @State private var pressKeyboardUp = false
    // v-review fix（维度3）：输入框流光开关与设置页同源 @AppStorage 默认 true——
    // 原 UserDefaults.standard.bool 无默认(false)：全新安装设置页显示「开」但门控不生效，拨动一次才对齐
    @AppStorage("qingliao_input_glow") private var inputGlowOn = true
    // v3.4.25：上下文阈值预警——外部传入上下文使用率（0-1），超 0.8 发送键变橙轻提醒
    var contextUsage: Double = 0
    /// v3.9.48：模型快选——当前模型名（空串 = 整块不显示）+ 点击回调。
    /// ⚠️ 追加在 `contextUsage` 之后：调用点走成员初始化器且按声明序传参，插在中间会错位
    var modelLabel: String = ""
    var onPickModel: () -> Void = {}
    // v3.4.29：发送动作图标弹一下（symbolEffect 驱动，无自定义动画开销）
    // v3.9.42：同一个 tick 兼作发送键关键帧的 trigger（原来另有一个 sendScale + 两段 withAnimation）
    @State private var sendBounceTick = 0
    /// v3.9.42：「减弱动态效果」→ 不给关键帧喂新 trigger，发送反馈只剩图标 symbolEffect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 发送按钮配色三态：语音模式=Siri 彩、空文本=淡灰、有字=蓝紫渐变
    // v3.4.25：+第四态——上下文使用率超 80% 时有字状态变橙（轻提醒，不阻断发送）
    private var sendColors: [Color] {
        if voiceMode { return [.blue, .indigo, .pink] }
        if text.isEmpty { return [Color(uiColor: .systemGray4), Color(uiColor: .systemGray3)] }
        if contextUsage > 0.8 { return [.orange, .yellow.opacity(0.9)] }
        return [.blue, .indigo]
    }

    // 发送触发：一次 tick 同时驱动图标弹动与按钮关键帧（长按转文字路径不走这里，不弹反馈）
    private func fireSend() {
        sendBounceTick += 1
        Haptics.tap()   // v3.4.25：统一触感——发送 = 轻点
        onSend()
    }

    // v3.6.2：智能球已迁至 dock 聊天槽位，输入栏不再有"球态"——恒为完整输入栏
    var body: some View {
        fullInputBar
            // v3.4.28：横屏限宽居中（竖屏 .infinity 不变）
            .frame(maxWidth: AdaptiveLayout.contentMaxWidth(hSizeInput))
            .frame(maxWidth: .infinity)
    }

    /// v3.9.53（真机 497 后用户拍板：「输入框样式还是改回 3.9.46 版本的样式吧，现在的不行，
    /// 在 3.9.46 基础上加上模型切换就行」）——**样式整条回退到 v3.9.46**，只留模型切换：
    /// 玻璃回到液态玻璃底、常态白边 + 聚焦蓝边回到 v3.4.20 两层写法、
    /// 外层 `.shadow(0.3 / 14 / 5)` 加回来（仍排在流光 overlay **之前**，v3.2.3 红线不动）。
    ///
    /// v3.9.62：外层玻璃容器由 **Capsule 改 RoundedRectangle(cornerRadius: Radius.field 14)**——
    /// 用户原话「输入框圆角太大了，很不协调，改成常规圆角」。42 高的两层内容配全圆角胶囊，
    /// 弧顶几乎咬到内容上下缘；改 14pt（Radius.field 输入框档）后上缘出现 28pt 平坦段，
    /// 输入文字与工具图标不再贴着弧线，与全站输入类控件（附件卡/内嵌面板）同一圆角口径。
    ///
    /// v3.9.64：用户原话「外部方形框圆角稍微再加一点」——14 档整体进到 **16 档（Radius.card）**：
    /// 令牌体系里 14 的下一档就是 16，步进 2pt 即「稍微」；不新开中间档（Radius 是 6 档语义层级）。
    /// 玻璃底 / 聚焦蓝边 / 常态白边 / 流光四处同步换档，平坦段 64pt → 60pt（仍远大于内容高）。
    /// 同轮用户原话「把输入框流光填满外部的方形框」——流光本体由 Capsule 改为同形圆角矩形。
    ///
    /// v3.9.65：用户原话「输入框圆角加到 18」——**明确数值规格**，18 落在 Radius 的 card(16) 与
    /// hero(22) 之间，为它新开令牌档会破坏 6 档语义层级；改为 `ChatInputBarLayout.containerCornerRadius`
    /// 单一真源常量（=18），四处同形引用它。平坦段随第二层变矮重算：84 − 18×2 = 48pt。
    ///
    /// v3.9.61：由 v3.9.46 的单行 HStack 改为**恒定两层 VStack**。
    ///   第一层 `messageRow` = 消息输入层：textArea（占位符「输入消息…」/ 光标都走这一层）
    ///                          + trailingButtons（停止 / 发送，与输入同行）；
    ///   第二层 `toolRow`    = 工具层：附件 + 相机 + 模型快选。
    /// 收益（令牌算式）：输入框可用宽 169pt → ≈297pt（屏宽 393 − 左右 28 − 发送键 32 − 间距 8），
    /// 原来它被附件/相机/模型名三面夹击，只剩约四成宽。
    ///
    /// v3.9.66（用户：「做 1，另外输入框圆角加到 20」——「做 1」= 上一轮评估里的方案 1：
    /// **未弹键盘只显示第一层，点输入框弹键盘后两层都显示**）：
    /// 收起态容器高 = padding(.vertical) Spacing.md 12×2 + 第一层 42 ≈ **66**（原两层态 84，
    /// 矮约 18pt；第二层高度与两层间距同步归 0）。
    /// 实现纪律（v3.9.53 键盘弹一下又收回的坑 + 真值表 `ql_inputbar` 钉住）：
    ///   · 两层**恒渲染**，绝不用 `if kbEnv.isVisible { toolRow }` 切结构 —— VStack 子节点
    ///     从两层变一层就是类型变化 → TextField 换父级 → 重建 → 键盘刚弹出就收回；
    ///   · 只动**不改变类型**的属性：第二层 `opacity` 与 `frame(height:)`（收起 0/0，展开 nil/34），
    ///     VStack spacing 收起归 0（间距与层同属一组，一并动画才不残留一道缝）；
    ///   · 判据 `focused || kbEnv.isVisible`：iPad 接蓝牙键盘时软键盘不弹，只用键盘高度判
    ///     会让第二层永远不出现；focused 已在用（聚焦蓝边），带上它更稳；
    ///   · 动画走 `Motion.snap`（与聚焦蓝边同一条），键盘联动期间高度变化与键盘同节奏。
    /// 收起态副作用（即用户要的行为）：附件/相机/模型快选不可见——发图、切模型要先点输入框
    /// 唤起键盘；长按输入框录音时键盘会收，那期间同样只剩第一层（语音走第一层 Text 上屏，
    /// 发送键在第一层，随时可发）。
    //
    /// v3.9.66（用户：「做 1」）：v3.9.61 起两层恒定 VStack —— 展开态 spacing 走 Layout.rowGap(8)，
    /// 收起态（键盘未弹）spacing 归 **0**；这与第二层 height/opacity 同属一组动画，
    /// 三者分开动画会残留一道 8pt 缝隙（层高已 0 但间距还在）。
    ///
    /// ⚠️ **两层恒渲染、不用 `if focused` 切结构**：任何让 TextField 父级类型/兄弟集合变化的
    /// 写法都会重建它 → 键盘弹一下又收回（v3.9.53 同款坑）。恒定结构下聚焦/失焦/录音态切换
    /// 只改布局不改父级；真值表 `ql_inputbar` 钉住这条（禁 if focused 包层、禁改类型）。
    private var fullInputBar: some View {
        VStack(spacing: toolLayerExpanded ? ChatInputBarLayout.rowGap : 0) {
            messageRow
            toolRow
        }
        .animation(Motion.snap, value: toolLayerExpanded)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        // v2.0.87e：原生液态玻璃输入栏（iOS 26+）
        // v3.9.62：玻璃形状 Capsule → 14pt 档圆角矩形（Radius.field，输入框档）。
        // v3.9.63：v3.9.62 的写法 `.background { RoundedRectangle(...).glassEffect() }` **不成立**——
        //   Apple 官方明确 glassEffect 的默认形状是 Capsule（`DefaultGlassEffectShape`；原文「applies
        //   the given effect within a Capsule shape behind the view's content」），宿主 Shape 是圆角矩形
        //   也拦不住：玻璃本体仍按胶囊渲染（两端半径 = 容器高/2 ≈54），衬在圆角矩形白边**里面**——
        //   用户看到的就是「方形圆角框里还套一层椭圆玻璃」。正确做法 = 官方 `in:` 参数把玻璃钉进
        //   RoundedRectangle：`.glassEffect(.regular, in: RoundedRectangle(...))`，玻璃与描边同形，
        //   整个容器只剩一个形状。
        // 半径历史：v3.9.62 用 Radius.field(14) → v3.9.64 用 Radius.card(16) →
        //   v3.9.65 起用户明确「加到 18」→ ChatInputBarLayout.containerCornerRadius（单一真源，见 enum 定义）。
        // 外层玻璃容器其余件（白边/聚焦蓝边/流光）全部换成同一个形状（四处同形真值表钉住）。
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ChatInputBarLayout.containerCornerRadius, style: .continuous))
        // v3.4.20：聚焦态光晕——输入框获得焦点时边缘亮起淡蓝细描边（0.8pt 与全站描边同参），失焦淡出。
        // 静态描边（非每帧重绘），无 shadow 叠加，不触碰 v3.2.3 渲染卡死红线。
        .overlay {
            RoundedRectangle(cornerRadius: ChatInputBarLayout.containerCornerRadius, style: .continuous)
                .strokeBorder(Color.blue.opacity(focused ? 0.45 : 0), lineWidth: 0.8)
                .allowsHitTesting(false)
        }
        .animation(Motion.snap, value: focused)
        // v3.2.3 渲染卡死根治：外层阴影移到流光 overlay **之前**——阴影只对静态背景/内容生效，
        // 不再因流光每帧变化触发阴影 CGPath 重算（.ips 8BADF00D 主线程栈铁证：
        // ShapeLayerShadowHelper.updateShadow → Path.cgPath → RenderBox CG::stroker 病态递归卡死）
        .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
        // v2.0.87s：等待回复特效（v2.0.87ay：改回 87 版效果——内部旋转流光，Siri 淡雅）
        .overlay {
            // v3.9.7：语音转文字过程中输入框**不加这层特效**，保持普通输入框形态——
            //         语音态唯一的视觉提示是「发送键变收音图标」。流光只在 streaming（等待回复）态出现。
            // 卡死防护靠 v3.2.3 三件套（流光无 shadow + 15fps + 外层阴影静态化在 overlay 前）。
            if streaming && inputGlowOn {
                // v2.0.139 性能：流光 60→30fps；v3.2.3：30→15fps + **去掉 .shadow**
                let schedule: AnimationTimelineSchedule = .animation(minimumInterval: 1.0 / 15.0)
                TimelineView(schedule) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let angle = (t * 70).truncatingRemainder(dividingBy: 360)
                    // v3.9.64：用户原话「把输入框流光填满外部的方形框」——流光本体由 **Capsule 改为
                    //   与容器同形的圆角矩形**。Capsule 版两端半径 = 容器高/2，流光被压成
                    //   「两端大弧」的条状；同形矩形后流光铺满整个方形圆角框的四边与四角
                    //   （含圆角处）——玻璃/白边/聚焦蓝边/流光四处同一个形状（v3.9.63 定稿口径）。
                    // v3.9.65：容器圆角随「加到 18」走同一常量 containerCornerRadius，流光仍是同形。
                    RoundedRectangle(cornerRadius: ChatInputBarLayout.containerCornerRadius, style: .continuous).fill(
                        AngularGradient(
                            colors: [.blue.opacity(0.22), .indigo.opacity(0.22),
                                     .pink.opacity(0.22), .red.opacity(0.16), .blue.opacity(0.22)],
                            center: .center, angle: .degrees(angle)
                        )
                    )
                    .allowsHitTesting(false)   // v2.0.87al：不拦截点击（停止按钮可点）
                }
            } else {
                RoundedRectangle(cornerRadius: ChatInputBarLayout.containerCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(Tint.subtle), lineWidth: 0.8)
            }
        }
        .padding(.horizontal, 18)   // v2.0.87aw：输入框宽度收窄（12→18）
    }

    /// 第一层（消息输入层）：输入框 + 停止/发送键。
    ///
    /// v3.9.61：从原来的单行 HStack 里拆出——附件/相机/模型名挪去 `toolRow` 后，
    /// 输入框可用宽由 ≈169pt 扩到 ≈297pt（屏宽 393 − 左右 padding 28 − 发送键 32 − 间距 8）。
    /// 顺序刻意保持「输入框在左、发送在右」（与微信/主流 IM 一致）：用户原话只要求把
    /// 工具/附件/相机/模型放第二层，没说要把发送键也搬下去。
    /// ⚠️ textArea 在这层里**恒存在**（不是 if 分支里的成员）→ 聚焦/失焦不改这层类型。
    /// `minHeight` 用常量不写死数字（用户放大系统字号时 42 不够会由内容顶上，不会裁字）。
    private var messageRow: some View {
        HStack(spacing: 8) {
            textArea
            trailingButtons
        }
        .frame(minHeight: ChatInputBarLayout.messageRowMinHeight)
    }

    /// v3.9.66（用户：「做 1」）——**第二层可见性判据**（单一真源，VStack spacing / toolRow
    /// 的 height+opacity 三处都读它，三者必须同源否则高度动画与内容淡入不同步）。
    ///
    /// `focused || kbEnv.isVisible` 两个条件的理由：
    ///   · `kbEnv.isVisible`：主路径——点输入框弹起软键盘 → 第二层现身；
    ///   · `focused`：兜底路径——iPad 外接蓝牙键盘时**软键盘不弹**（isVisible 恒 false），
    ///     只用键盘高度判会让第二层永远不出现；focused 也覆盖「键盘已开但系统还没发
    ///     WillShow 通知」的那一帧，不会出现两层空档在键盘升起前才闪一下。
    /// 收键盘路径同理：失焦 + 键盘收起 → 只剩第一层。
    ///
    /// ⚠️ 本判定只驱动**不改变类型**的属性（height/opacity/spacing），绝不可拿去 if 包裹
    /// toolRow 本身 —— 那会改变 VStack 子节点集合 → TextField 换父级 → 键盘弹一下又收回
    /// （v3.9.53 同款坑，真值表 `ql_inputbar` 钉住）。
    private var toolLayerExpanded: Bool {
        focused || kbEnv.isVisible
    }

    /// 第二层（工具层）：附件 + 相机 + 模型快选（模型名右对齐）。
    ///
    /// v3.9.61：`modelButton` 保留 displayIf 条件（`modelLabel` 为空时整块不渲染）。
    /// 这对输入框**零风险**：textArea 在第一层 `messageRow` 里、且不是条件分支的成员，
    /// 第二层的兄弟集合怎么变都碰不到它的父级链 → 不会重建 TextField / 不掉 first responder。
    /// （反面教材是 v3.9.53 单行时的约束：那时 textArea 与 modelButton 是同一 HStack 的兄弟。）
    ///
    /// v3.9.66（用户：「做 1」）：收起态（键盘未弹）**高度归 0 + 透明**，展开态回常量高度。
    /// 三个纪律：
    ///   ① `opacity` 与 `frame(height:)` 都不改变视图类型 —— 收起只是「量」变，VStack 的
    ///      子节点集合（messageRow + toolRow）恒为两个，TextField 父级链零变化；
    ///   ② 高度给 0 而**不给 nil**：`nil` 会让 frame 回退到内容固有高度（34），收起态容器
    ///      就会残留 34pt 空白；给 0 才是真的收到底；
    ///   ③ `allowsHitTesting(false)` 同步切：收起态那一层虽然看不见，命中区若还在，
    ///      输入框底部一片空白会把点击吞掉（用户会以为「点输入框没反应」）。
    private var toolRow: some View {
        HStack(spacing: 8) {
            attachButtons
            Spacer(minLength: 0)
            if !modelLabel.isEmpty {
                modelButton
            }
        }
        .frame(minHeight: toolLayerExpanded ? ChatInputBarLayout.toolRowMinHeight : 0)
        .opacity(toolLayerExpanded ? 1 : 0)
        .allowsHitTesting(toolLayerExpanded)
    }

    /// 左侧两枚次级按钮（附件 / 相机）——纯拆分，与单行 HStack 里的写法视觉零差异
    /// v3.9.65：用户原话「第二层的附件和相机图标变小降低第二层高度」——图标视觉面 32×30 → 22×22，
    /// 命中区外扩量随之改为 11（22+11×2 = 44，HIG 最小可点尺寸仍成立、间距零变化）。
    private var attachButtons: some View {
        HStack(spacing: 8) {
            Button(action: onPickAttachment) {
                Image(systemName: "paperclip")
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    // v3.4.26：附件/相机纳入胶囊语义——低透明外圈（次级操作，弱于实底发送钮）
                    .background(Color.primary.opacity(Tint.faint), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8))
            }
            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
            // v3.9.65：命中区 44×44（视觉 22×22 → 外扩 11；原来是 32×30 视觉 + 外扩 6/7）
            .hitArea44(h: 11, v: 11)

            // v2.0.38：拍照输入
            Button(action: onCamera) {
                Image(systemName: "camera")
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(Tint.faint), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8))
            }
            .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
            // v3.9.65：命中区 44×44（视觉 22×22 → 外扩 11；原来是 32×30 视觉 + 外扩 6/7）
            .hitArea44(h: 11, v: 11)
        }
    }

    /// v3.9.50 #2（用户参考图）：模型名 = **纯灰文字**，不带图标、不带胶囊壳——
    /// 玻璃栏里再画一枚带底带边的壳，读起来还是"两层"。点按 → `ComposerModelSheet`。
    /// v3.9.53：样式回退 v3.9.46 后，它是**唯一保留**的新增件——恒挂在单行 HStack 里、
    /// 排在 textArea 之后（不能排在前面：换 TextField 的 TupleView index 会重建它 → 丢键盘）。
    private var modelButton: some View {
        Button(action: onPickModel) {
            Text(modelLabel)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        // 文字视觉高约 18 → 外扩到 44 高（横向给足，长名截断本身就贴着右半段）
        .hitArea44(h: Spacing.lg, v: 13)
        .accessibilityLabel("模型快选，当前 \(modelLabel)")
    }

    /// 文本区（录音态上屏文本 / TextField）——v3.9.48 从 `fullInputBar` 原样搬出，
    /// 内容与 v3.9.46 逐字一致（纯拆分，只为让 `fullInputBar` 的容器链那段好看清）
    @ViewBuilder
    private var textArea: some View {
        if isRecording {
            // v3.9.6：录音中**直接上屏** —— 在输入框同一行位置实时渲染识别文本。
            // 文本源取 liveSpeech.liveText（@Published），不再依赖 onTextChange 写 @State
            // 或 TextField 的 binding 刷新（v3.9.5 实测：录音中框里始终只有「输入消息…」占位、
            // 松手才一次性出字 = 实时链路没上屏）。红点=正在听；无字时保持空白。
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // v3.9.14：红点改脉动（用户反馈「录音图标是静态的，不会动」）
                    PulsingRecordDot()
                    Text(recordingText.isEmpty
                         ? (recordingStalled ? "没听清，靠近麦克风再说一次" : "正在听…")
                         : recordingText)
                        .font(.system(size: Typography.body))
                        .foregroundStyle(recordingText.isEmpty ? Color.secondary : Color.primary)
                        // v3.9.62：与 TextField 的 `.multilineTextAlignment(.leading)` 同侧
                        .multilineTextAlignment(.leading)
                        .lineLimit(1...6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsHitTesting(false)
                }
                // v3.9.14：诊断串只在「录了 3 秒一个结果都没有」时贴着显示——
                // 排查价值保留（V/F 识别计数、T/D/Y 音频三级计数），但不再挤占正常录音时的文本区
                if recordingStalled, !recordingDiag.isEmpty {
                    Text(recordingDiag)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            .padding(.vertical, Spacing.xl)
            .padding(.horizontal, Spacing.xxs)
        } else {
            TextField("", text: $text, axis: .vertical)
                .font(.system(size: Typography.body))
                // v3.9.52：**恒 1 行起**。v3.9.48 让展开态 `2...6` 是为了"点一下就变大"，
                // 真机 496 报「光标不居中了」——两行块里占位符整块居中、光标坐在第一行，两者错开。
                // 这条坑本仓 v2.0.35 就踩过一次（当时的注释原话："2...6 最小2行高→单行光标/文字偏上不居中"），
                // v3.9.48 又把它请回来了。行高改由内容驱动：打字/换行才长，`fixedSize` 负责撑。
                .lineLimit(1...6)
                // v3.9.62：**显式靠左**。SwiftUI 对空 label + axis .vertical 的 TextField
                //   默认对齐不保证（真机曾观感居中/光标与文字错位），这里把「输入的消息文本」
                //   钉成 leading，与同层占位符 overlay 的 `.leading` 严格同侧——用户原话：
                //   「第一层的输入消息有没有靠左？我想，按照靠左而不是居中」。
                .multilineTextAlignment(.leading)
                // v2.0.93f：9→12 输入框加高（用户反馈太窄）
                .padding(.vertical, Spacing.xl)
                .padding(.horizontal, Spacing.xxs)
                .fixedSize(horizontal: false, vertical: true)   // 文字超宽自动增高输入框，旧文字始终可见
                .focused($focused)
                // v2.0.106：长按输入框 = 进入语音转文字（与长按发送键同效；收键盘由 ChatView 处理）
                // v2.0.106b：onLongPressGesture 被 UITextField 内置长按(放大镜/选择)拦截不触发
                //           → 改 simultaneousGesture 与系统手势共存触发
                // v2.0.109b：onChanged（down 瞬间）记录键盘可见状态——键盘开=true 保持，关=false 收回
                // v3.9.3：语音恒可用（设备端）——voiceEnabled 现恒为 true，保留判断以便按需关闭
                //           （用 .simultaneousGesture 里 if/else 各自挂同类型 LongPressGesture，规避泛型不一致）
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: voiceEnabled ? 0.4 : 3600)
                        .onChanged { _ in
                            pressKeyboardUp = kbEnv.isVisible
                        }
                        .onEnded { _ in
                            guard voiceEnabled else { return }
                            onLongPressInput(pressKeyboardUp)
                        }
                )
                .overlay {
                    if text.isEmpty {
                        if transcribing {
                            // v2.0.100：转写中动画（waveform 图标 + 文字脉冲）
                            HStack(spacing: 6) {
                                Image(systemName: "waveform")
                                    .font(.system(size: Typography.subhead))
                                    .symbolEffect(.pulse)
                                Text("语音转换中…")
                                    .font(.system(size: Typography.body))
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .allowsHitTesting(false)
                        } else {
                            Text("输入消息...")
                                .font(.system(size: Typography.body))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .allowsHitTesting(false)
                        }
                    }
                }
        }
    }

    /// 右侧那一族：停止（流式时）+ 发送/转写按钮——v3.9.50 从 `fullInputBar` 拆出的纯拆分。
    /// 内部 `HStack(spacing: 8)` 与外层行距同参 → 拆前拆后视觉零差异。
    private var trailingButtons: some View {
        HStack(spacing: 8) {
            // v2.0.88：AI 回答中也可继续发送（消息排队，答完自动逐条回）；
            // 停止按钮独立保留（取消当前回答 + 清空队列）
            if streaming {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: Typography.subhead, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        // v3.4.21：停止按钮 Circle → 红胶囊（与发送按钮 Capsule 同族，二元控件形态统一）
                        .background(Color.red.opacity(0.8), in: Capsule())
                }
                .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                // v3.9.34：命中区 44×44（停止红胶囊视觉 32×32、间距零变化）
                .hitArea44(h: 6, v: 6)
            }

            // v2.0.96：发送按钮——普通发送；语音模式下点击=退出；长按=进入语音转文字（Siri 彩色图标）
            // v2.0.96b：Button 内置手势会拦截 onLongPressGesture → 改自定义视图 + 显式 Tap/LongPress
            // v2.0.98：onTapGesture+onLongPressGesture 叠加 = 两个独立手势系统在手势激活中改
            //          视图树（voiceMode 切换重建按钮）→ 实测 SIGTRAP 闪退（crash_reports 4 次）。
            //          改用 ExclusiveGesture（长按优先、互斥），onEnded 时手势已结束，视图重建安全。
            // v2.0.100：transcribing 时按钮显示转圈（转换中动画）
            // v2.0.101：转圈旁加红色停止按钮（随时中断转换）；手势只在非转写时挂载（停止按钮独立可点）
            Group {
                if transcribing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .tint(.white)
                            .frame(width: 32, height: 32)
                        Button(action: onCancelTranscribe) {
                            Image(systemName: "xmark")
                                .font(.system(size: Typography.caption, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                // v3.4.21：红胶囊（与停止/发送按钮同族）
                                .background(Color.red.opacity(0.85), in: Capsule())
                        }
                        .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
                        // v3.9.34：命中区 44×44（xmark 视觉 26×26、间距零变化）
                        .hitArea44(h: 9, v: 9)
                    }
                } else {
                    // v3.9.14：录音态 waveform 图标持续波动（用户反馈「录音图标静态不动」）。
                    // 拆 if/else 而非三元 —— 两个 symbolEffect 类型不同，三元会触发类型推断冲突（本仓踩过）。
                    Group {
                        if voiceMode {
                            Image(systemName: "waveform")
                                .symbolEffect(.variableColor.iterative, options: .repeating)
                        } else {
                            Image(systemName: "arrow.up")
                                .symbolEffect(.bounce, value: sendBounceTick)   // v3.4.29：发送图标弹动
                        }
                    }
                    .font(.system(size: Typography.body, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                        .contentShape(Circle())
                        // v3.9.34：命中区 44×44（发送键视觉 32×32、间距零变化）
                        .hitArea44(h: 6, v: 6)
                        // v3.4.19：发送回弹缩放（仅轻点发送路径，长按转文字不缩放）
                        // v3.9.42：两步 withAnimation + Task.sleep → 一条关键帧轨道（见 sendPulse 定义处）
                        .sendPulse(trigger: reduceMotion ? 0 : sendBounceTick)
                        .gesture(
                            LongPressGesture(minimumDuration: 0.4)
                                .exclusively(before: TapGesture())
                                .onEnded { value in
                                    // .first = 长按成功（语音模式开关）；.second = 轻点（发送/退出）
                                    switch value {
                                    case .first:
                                        // v3.0.4：云端无语音 → 长按等同轻点发送
                                        if voiceEnabled {
                                            onVoiceModeToggle()
                                        } else {
                                            fireSend()
                                        }
                                    case .second:
                                        if voiceMode {
                                            onVoiceModeToggle()
                                        } else {
                                            fireSend()
                                        }
                                    }
                                }
                        )
                }
            }
            .background(
                // v3.4.19：三态配色（语音=Siri 彩/空=淡灰/有字=蓝紫），渐变过渡动画
                LinearGradient(colors: sendColors,
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Capsule()
            )
            .animation(Motion.snap, value: sendColors)
        }
    }
}


/// v3.9.14：录音中的脉动红点。
///
/// 用户反馈「录音图标是静态的，不会动」—— 原来就是一个静止的 7pt 红点。
/// 只对这个小圆做 scale/opacity 的 repeatForever 动画：**无 shadow、无每帧渐变重绘**，
/// 不触碰 v3.2.3 那条渲染卡死红线（红线触发条件是「每帧变化的渐变 + 阴影路径重算」）。
private struct PulsingRecordDot: View {
    // v3.9.19：无障碍——「降低动态效果」时不做循环脉冲
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 7, height: 7)
            .scaleEffect(pulsing ? 1.45 : 0.85)
            .opacity(pulsing ? 1.0 : 0.5)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.65).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
            .allowsHitTesting(false)
    }
}


// MARK: - v3.9.42 发送键合成反馈（keyframeAnimator 首次入场）
//
// 背景：原来"发送弹一下"是手写的两段动画 —— `withAnimation { scale = 1.25 }` +
// `Task.sleep(0.12)` + `withAnimation { scale = 1.0 }`。两个问题：
//   ① 节拍靠 sleep 对齐，主线程一卡（流式 token 正在刷）就会"弹了不收回"或连弹；
//   ② 只有一维缩放，做不到"按下先压缩再冲高"这种带方向感的复合手感（要三段就得再叠 sleep）。
// keyframeAnimator（iOS 17+）把多轨时间线交给系统排，一次 trigger 跑完，无需 @State 中间值。
//
// 拆成独立 View 扩展而非内联在 fullInputBar 里：本文件 body 已是全仓最长的之一，
// keyframe 的多轨泛型推断塞进去容易撞 CI 类型检查超时（v3.9.x 踩过多次，见 ChatEffects 的拆法）。

/// 关键帧取值：一轨缩放 + 一轨上抛。字段用 Double（SwiftUI 里 Double 是 Animatable/VectorArithmetic，
/// 别用 CGFloat —— 泛型约束在 CI 端少一分不确定），用图时再转 CGFloat。
private struct SendPulse {
    var scale: Double = 1
    var lift: Double = 0
}

extension View {
    /// 发送键一次性合成反馈：压到 0.9 → 冲高 1.16 → 落定，同时整体上抛 3pt 再回落（"弹射出去"）。
    /// `trigger` 变化即播一轮；调用方传 0 常量 = 关掉反馈（「减弱动态效果」走这条路）。
    func sendPulse(trigger: Int) -> some View {
        keyframeAnimator(initialValue: SendPulse(), trigger: trigger) { content, value in
            content
                .scaleEffect(CGFloat(value.scale))
                .offset(y: CGFloat(value.lift))
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(0.9, duration: 0.07)
                SpringKeyframe(1.16, duration: 0.19)
                SpringKeyframe(1.0, duration: 0.22)
            }
            KeyframeTrack(\.lift) {
                LinearKeyframe(0, duration: 0.07)
                CubicKeyframe(-3, duration: 0.12)
                SpringKeyframe(0, duration: 0.29)
            }
        }
    }
}
