import SwiftUI

// MARK: - v3.9.58 生活页「定时任务」聚合卡
//
// 是什么：AI 帮用户建的延时任务（automation_create → /api/automations/list）此前只在
// 看板自动化列表可见；生活页放一张聚合卡：「我帮你定的 N 个提醒」，按时间排序、
// 单条左滑/按钮取消（DELETE /api/automations/{id}）。
//
// 设计要点：
//   · 空列表整卡不显示（不在生活页占位——用户没建过任务时不打扰）
//   · 数据加载失败 = 卡内一行小字，不空白不转圈（与生活页其他卡同款约定）
//   · 倒计时文案每 30s 本地刷新（runAt 是绝对时刻，无需轮询后端）

struct AutomationsSection: View {
    @Environment(AuthStore.self) private var auth
    @State private var items: [LifeAutomationItem] = []
    @State private var loadError = ""
    @State private var cancelConfirm: LifeAutomationItem?   // 取消确认（任务不可恢复）

    var body: some View {
        // 空列表 → 整卡隐藏（含加载失败且从未有过数据的情况：留一行小字引导重试）
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "alarm")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("我帮你定的提醒 · \(items.count)")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { it in
                        row(it)
                        if it.id != items.last?.id {
                            Divider().overlay(Color.primary.opacity(Tint.faint))
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                        .strokeBorder(Color.primary.opacity(Tint.faint), lineWidth: 0.8)
                )
            }
        } else if !loadError.isEmpty {
            Text("定时任务加载失败 · 下拉刷新重试")
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.xs)
        }
    }

    private func row(_ it: LifeAutomationItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: Typography.body))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(it.name)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(it.countdownText)
                    .font(.system(size: Typography.tiny).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                cancelConfirm = it
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("取消「\(it.name)」")
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .alert("取消这个提醒？", isPresented: Binding(
            get: { cancelConfirm != nil },
            set: { if !$0 { cancelConfirm = nil } })) {
            Button("取消任务", role: .destructive) {
                if let it = cancelConfirm { Task { await cancel(it) } }
            }
            Button("留着", role: .cancel) {}
        } message: {
            Text(cancelConfirm.map { "「\($0.name)」· \($0.countdownText)后执行" } ?? "")
        }
    }

    private func cancel(_ it: LifeAutomationItem) async {
        // DELETE 成功返回 {ok:true}——用通用 json() 解析，不用不存在的方法
        guard let j = try? await auth.json("/api/automations/\(it.id)", method: "DELETE"),
              (j["ok"] as? Bool) == true else {
            Haptics.error()
            return
        }
        items.removeAll { $0.id == it.id }
        Haptics.success()
    }
}

// MARK: - 模型（与 DashboardView.AutomationItem 同源 JSON，独立小类型避免跨页耦合）

struct LifeAutomationItem: Identifiable {
    let id: String
    let name: String
    let runAt: Date

    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? UUID().uuidString
        name = d["name"] as? String ?? "定时任务"
        runAt = Date(timeIntervalSince1970: ((d["run_at"] as? Double) ?? 0))
    }

    /// 人话倒计时：<'1分' 秒级 / <'1时' 分级 / <'1天' 时分 / ≥1天 天+时
    var countdownText: String {
        let s = max(0, Int(runAt.timeIntervalSinceNow))
        if s < 60 { return "\(s) 秒后" }
        if s < 3600 { return "\(s / 60) 分钟后" }
        if s < 86400 { return "\(s / 3600) 小时 \((s % 3600) / 60) 分后" }
        return "\(s / 86400) 天后"
    }
}

// MARK: - 数据加载（挂 LifeView 生命周期；独立 extension 防止撑大 LifeView body）

extension LifeView {
    /// 拉定时任务列表（空/失败都静默——空=不显示卡，失败=卡内小字）
    func loadAutomations() async {
        if let j = await auth.jsonOrLog("/api/automations/list") {
            let list = (j["automations"] as? [[String: Any]] ?? []).map(LifeAutomationItem.init)
            items = list
            loadError = ""
        } else if items.isEmpty {
            loadError = "load_failed"
        }
    }
}
