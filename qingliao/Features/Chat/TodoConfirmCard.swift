import SwiftUI

// MARK: - v4.0.25 待办候选确认卡（AI 提取确认制）
//
// 背景：v3.9.35 起 AI 回复里的勾选框/计划卡是**静默落库**——AI 每轮重复产出、
// 提取口径偶发误收，清单很快被噪音灌满（NAS todos.json 实测 22 条重复/过期项）。
// v4.0.25 改确认制：落库口只 stage 候选（TodoStore.stageCandidates），本卡挂在
// 该条 AI 气泡内容之下，用户勾选点「加入」才真落库；「忽略」则丢候选不再弹。
//
// 范式对齐 AgentActionCard：就地回填状态（idle → done），不另起消息；执行中防重复点击。
// 生命周期纯内存（TodoStore.pendingCandidates）：App 重启后候选自然消失 = 回到「不提取」，
// 静默丢候选好过静默灌清单（口径与 file 头注释一致）。

struct TodoConfirmCard: View {
    /// 挂账的消息 id（= 该条 AI 回复的 ChatMessage.id）
    let messageID: String

    @State private var store = TodoStore.shared

    var body: some View {
        Group {
            if let cands = store.pendingCandidates[messageID], !cands.isEmpty {
                card(cands)
            } else if let n = store.confirmedCounts[messageID] {
                receipt(n)
            }
        }
    }

    // MARK: 候选态

    private func card(_ cands: [TodoStore.TodoCandidate]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("发现 \(cands.count) 条待办")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                Spacer()
                Text("勾选后加入")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(cands.enumerated()), id: \.element.id) { idx, c in
                Button {
                    store.toggleCandidate(messageID: messageID, index: idx)
                    Haptics.tap()
                } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: c.selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(c.selected ? Color.green : Color.secondary.opacity(0.6))
                        Text(c.content)
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: Spacing.md) {
                Button {
                    Haptics.success()
                    store.confirmCandidates(messageID: messageID)
                } label: {
                    Text("加入 \(cands.filter { $0.selected }.count) 条")
                        .pill(.topBar, tone: .accent)
                }
                .buttonStyle(PressStyle())
                .disabled(cands.filter { $0.selected }.isEmpty)   // 全不勾 = 无可加
                Button {
                    Haptics.tap()
                    store.dismissCandidates(messageID: messageID)
                } label: {
                    Text("忽略")
                        .font(.system(size: Typography.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(PressStyle())
                Spacer(minLength: 0)
            }
        }
        .padding(Spacing.lg)
        .glassListCard()
    }

    // MARK: 回执态（确认后就地变一行，不刷屏）

    private func receipt(_ n: Int) -> some View {
        Label(n > 0 ? "已加入 \(n) 条待办（生活 → 待办清单）" : "未加入任何待办",
              systemImage: n > 0 ? "checkmark.circle.fill" : "circle")
            .font(.system(size: Typography.tiny))
            .foregroundStyle(.secondary)
    }
}
