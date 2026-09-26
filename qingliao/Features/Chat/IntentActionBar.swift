import SwiftUI

// MARK: - v3.9.71 意图动作条（底部浮层）
//
// 三个入口（输入栏粘贴识别 / 大爆炸选词 / 图片 OCR）识别出内容后统一弹这一条：
//   「类型徽标 + 一行摘要」+ 一排可执行动作 + 执行后的「撤销」。
//
// 硬口径：
//   · **绝不弹二次确认**：写入类动作点即写（用户明确说过不喜欢整天审批），然后给 5 秒撤销。
//   · **低置信只给「问 AI / 复制」**：置信 < 0.5 时不给任何写入动作（IntentPipeline 同口径）。
//   · **失败必须出声**：红字 + 震动，不静默。
//   · 浮层挂在输入栏**之外**（输入栏那套两层结构是历史雷区，一律不碰），由宿主用 overlay 定位。

struct IntentActionBar: View {
    let intent: RecognizedIntent
    /// 交给宿主发到聊天流（动作条自己发不了流）
    var onAskAI: (String) -> Void
    var onClose: () -> Void

    @Environment(AuthStore.self) private var auth
    @State private var busy = false
    @State private var message: String?
    @State private var undo: (() async -> Void)?
    @State private var errorText: String?
    @State private var undoTask: Task<Void, Never>?

    /// 写入类动作的门槛（与 IntentPipeline 的兜底置信 0.3 呼应：兜底永远够不到这条线）
    private static let writeGate = 0.5
    /// 撤销窗口
    private static let undoWindow: Duration = .seconds(5)

    private var visibleActions: [IntentAction] {
        intent.actions.filter { a in
            if a == .askAI || a == .copy { return true }
            return intent.confidence >= Self.writeGate
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            chips
            if let errorText {
                Text(errorText)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if let message { resultRow(message) }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 玻璃口径（v4.0.0 现行）：走 `dashboardCard()`，理由见下方注释。
        // ⚠️ v3.9.78 曾在此处挂一整段「方案 C：22 圆角 + .ultraThinMaterial + 白亮边 + 投影留调用点」
        //   的注释，但 v4.0.0 已把本体换成 dashboardCard()（16 圆角 / .glassEffect(.regular) /
        //   投影 10-4 且在口径里）—— 那段注释留着会让人照着改回旧口径。已删，别再加回来。
        //
        // 🚨 v4.0.0（用户 2026-09-26 真机报：「这张卡背景像实心白卡，换成跟门锁卡一样的透明底」）：
        //   真因 —— `.ultraThinMaterial` 背后是**浅色对话底**时，模糊后仍是接近白的实色观感，
        //   玻璃的「透」在浅底上根本不成立（真机看图 = 白卡片）。门锁卡（`PinCard`）走
        //   `.dashboardCard()` = **`.glassEffect(.regular, in: RoundedRectangle(16))`** 原生玻璃，
        //   同样浅底上能透出层次 → 用户要的就是这一档。
        //   本卡改走 `dashboardCard()`：**不新增第三套玻璃口径**，直接复用门锁卡那套已被真机认可的
        //   `DashboardCardStyle`（圆角 16 / 白 0.8pt 描边浅 0.12 深 0.22 / 柔影 10-4）。
        //   识别浮层、速记待办、译文卡**保持 `overlayGlassCard` 不动**（那是用户 2026-09-25 单独拍板的另一档，
        //   它们各自在弹窗/浮层里有系统材质垫底，ultraThin 在那里是透的）。
        .dashboardCard()
        .padding(.horizontal, Spacing.section)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onDisappear { undoTask?.cancel() }
    }

    // MARK: 头行：类型徽标 + 摘要 + 关闭

    private var header: some View {
        HStack(spacing: 8) {
            Text(kindLabel)
                .pill(.topBar, tone: .accent)
            Text(intent.title.isEmpty ? String(intent.raw.prefix(20)) : intent.title)
                .font(.system(size: Typography.subhead))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(provenanceLabel)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("关闭")
        }
    }

    // MARK: 动作胶囊（横向滚动，动作多也不挤压）

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleActions, id: \.rawValue) { action in
                    Button {
                        perform(action)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: actionIcon(action))
                                .font(.system(size: Typography.caption))
                            Text(actionLabel(action))
                        }
                        .pill(.topBar, tone: action == .askAI ? .accent : .neutral)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressStyle())
                    .disabled(busy)
                    .accessibilityLabel(actionLabel(action))
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: 执行结果行（成功 + 可撤销）

    @ViewBuilder
    private func resultRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: Typography.caption))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if undo != nil {
                Button {
                    undoNow()
                } label: {
                    Text("撤销").pill(.topBar, tone: .neutral)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("撤销刚才的操作")
            }
        }
    }

    // MARK: 执行

    private func perform(_ action: IntentAction) {
        guard !busy else { return }
        busy = true
        errorText = nil
        Task {
            let outcome = await IntentActionRunner.run(action, intent: intent, auth: auth)
            busy = false
            switch outcome {
            case .done(let msg, let u):
                message = msg
                undo = u
                Haptics.success()
                if u != nil { startUndoWindow() }
            case .handedOff:
                onClose()
            case .askAI(let text):
                onAskAI(text)
                onClose()
            case .failed(let err):
                errorText = err
                Haptics.error()       // 失败必须出声（v3.9.41 教训）
            }
        }
    }

    private func startUndoWindow() {
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            undo = nil               // 窗口过期：撤销按钮消失（结果提示保留）
        }
    }

    private func undoNow() {
        guard let u = undo else { return }
        undo = nil
        undoTask?.cancel()
        Task {
            await u()
            message = message.map { "已撤销（\($0)）" } ?? "已撤销"
            Haptics.tap()
        }
    }

    // MARK: 文案 / 图标

    private var kindLabel: String {
        switch intent.kind {
        case .express: return "快递单号"
        case .address: return "地址"
        case .contact: return intent.fields["type"] == "email" ? "邮箱" : "电话"
        case .link: return "链接"
        case .amount: return "金额"
        case .datetime: return "日程"
        case .text: return "内容"
        }
    }

    private var provenanceLabel: String {
        switch intent.provenance {
        case .rule: return "本机识别"
        case .ocr: return "图片识别"
        case .onDevice: return "端侧 AI"
        case .cloud: return "云端 AI"
        }
    }

    private func actionLabel(_ a: IntentAction) -> String {
        switch a {
        case .storeRecord: return "记一笔"
        case .addTodo: return "加待办"
        case .addReminder: return "建提醒"
        case .saveMemo: return "存备忘录"
        case .saveToKB: return "存知识库"
        case .openMap: return "打开地图"
        case .call: return "拨打"
        case .mailto: return "写邮件"
        case .copy: return "复制"
        case .askAI: return "问 AI"
        }
    }

    private func actionIcon(_ a: IntentAction) -> String {
        switch a {
        case .storeRecord: return "sum"
        case .addTodo: return "checklist"
        case .addReminder: return "alarm"
        case .saveMemo: return "note.text"
        case .saveToKB: return "books.vertical"
        case .openMap: return "map"
        case .call: return "phone"
        case .mailto: return "envelope"
        case .copy: return "doc.on.doc"
        case .askAI: return "sparkles"
        }
    }
}
