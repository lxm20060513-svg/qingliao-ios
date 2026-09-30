// v4.0.11：主动 Agent 设置页（后端 proactive_agent 的唯一 UI 面）。
//
// 定位：后端是唯一真源（proactive_config.json），本页**不存本地影子状态**——
// 与 v3.9.56 TypeSafe 开关同口径：本地存一份就会在换设备/运维改后端时显示假状态。
// 每次 onAppear / 改开关都直接读写 /api/agent/proactive/*。
//
// 三个分区：
//   ① 打扰预算：总开关 + 每日条数 + 静默时段 + 置信度阈值（自适应值只读展示）
//   ② 事件源：HA 状态差分 / 目标停滞 nudge / LLM 判定
//   ③ 复盘看板：今日剩余条数、采纳/忽略、置信度自适应结果、最近判定留痕 + 手动跑一轮

import SwiftUI

struct ProactiveAgentSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var cfg: [String: Any] = [:]
    @State private var state: [String: Any] = [:]
    @State private var loaded = false
    @State private var loadErr: String?
    @State private var busy = false            // 手动 run 中
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if let loadErr {
                        Text(loadErr).font(.system(size: Typography.subhead))
                            .foregroundStyle(Color.red)
                    }
                    budgetCard
                    sourceCard
                    reviewCard
                    manualCard
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.xl)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .scrollContentBackground(.hidden)
            .navigationTitle("主动 Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await reload() }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.system(size: Typography.subhead))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.md)
                        .background(Color.black.opacity(0.75), in: Capsule())
                        .padding(.bottom, Spacing.xxl)
                        .transition(.opacity)
                }
            }
        }
    }

    // ── ① 打扰预算 ──
    private var budgetCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("打扰预算")
            VStack(spacing: 0) {
                SettingRow(icon: "bolt.horizontal.circle.fill", iconColor: .orange,
                           title: "主动开口", value: boolText(cfg["enabled"] as? Bool),
                           toggle: Binding(
                            get: { cfg["enabled"] as? Bool ?? true },
                            set: { nv in patch(["enabled": nv]) }))
                Divider().padding(.leading, Spacing.rowDividerInset)
                HStack {
                    Text("每日上限").font(.system(size: Typography.body))
                    Spacer()
                    Stepper("\(intOf(cfg["dailyMax"], 6)) 条",
                           value: Binding(get: { intOf(cfg["dailyMax"], 6) },
                                          set: { patch(["dailyMax": $0]) }),
                           in: 1...20)
                    .labelsHidden()
                    Text("\(intOf(cfg["dailyMax"], 6)) 条").font(.system(size: Typography.subhead))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
                Divider().padding(.leading, Spacing.rowDividerInset)
                // 静默时段：起止两小时各一个 Stepper（不引 DatePicker——纯数字选择更省事，
                // 且这个值只影响后端每轮判定的「要不要闭嘴」，不需要日期语义）
                HStack(spacing: Spacing.lg) {
                    Text("静默时段").font(.system(size: Typography.body))
                    Spacer()
                    hourPicker("起", key: "quietStart", dflt: 23)
                    Text("–").foregroundStyle(.secondary)
                    hourPicker("止", key: "quietEnd", dflt: 7)
                }
                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
                Divider().padding(.leading, Spacing.rowDividerInset)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("置信度门槛").font(.system(size: Typography.body))
                        Spacer()
                        Text(String(format: "%.2f", dblOf(cfg["minScore"], 0.55)))
                            .font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { dblOf(cfg["minScore"], 0.55) },
                                           set: { patch(["minScore": $0]) }),
                           in: 0...1)
                    Text("低于这个分数不打扰。实际阈值会按你的「有用/没用」反馈自动微调："
                         + String(format: "当前自适应 %.2f", dblOf(state["threshold"], 0.55)))
                        .font(.system(size: Typography.tiny)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
            }
            .glassListCard()
        }
    }

    // ── ② 事件源 ──
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("事件源")
            VStack(spacing: 0) {
                SettingRow(icon: "house.fill", iconColor: .teal, title: "家居状态变化",
                           value: boolText(cfg["haWatch"] as? Bool),
                           toggle: Binding(get: { cfg["haWatch"] as? Bool ?? true },
                                          set: { patch(["haWatch": $0]) }))
                Divider().padding(.leading, Spacing.rowDividerInset)
                SettingRow(icon: "flag.checkered", iconColor: .indigo, title: "目标停滞提醒",
                           value: boolText(cfg["goalNudge"] as? Bool),
                           toggle: Binding(get: { cfg["goalNudge"] as? Bool ?? true },
                                          set: { patch(["goalNudge": $0]) }))
                Divider().padding(.leading, Spacing.rowDividerInset)
                SettingRow(icon: "brain.head.profile", iconColor: .purple, title: "LLM 判定该不该说",
                           value: boolText(cfg["llmJudge"] as? Bool),
                           toggle: Binding(get: { cfg["llmJudge"] as? Bool ?? true },
                                          set: { patch(["llmJudge": $0]) }))
            }
            .glassListCard()
        }
    }

    // ── ③ 复盘看板 ──
    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("复盘")
            let b = state["budget"] as? [String: Any] ?? [:]
            let fb = state["feedback"] as? [String: Any] ?? [:]
            VStack(spacing: 0) {
                HStack {
                    metric("今日剩余", "\(intOf(b["left"], 0)) / \(intOf(b["dailyMax"], 6))")
                    Divider().frame(height: 30)
                    metric("有用", "\(intOf(fb["adopted"], 0))")
                    Divider().frame(height: 30)
                    metric("没用", "\(intOf(fb["ignored"], 0))")
                }
                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
                let recent = state["recent"] as? [[String: Any]] ?? []
                if !recent.isEmpty {
                    Divider().padding(.leading, Spacing.rowDividerInset)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("最近判定").font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                        ForEach(Array(recent.reversed().prefix(8).enumerated()), id: \.offset) { _, e in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: (e["spoke"] as? Bool) == true
                                      ? "bubble.left.and.bubble.right.fill" : "circle.dashed")
                                    .font(.system(size: Typography.tiny))
                                    .foregroundStyle((e["spoke"] as? Bool) == true ? Color.green : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((e["signal"] as? String) ?? "—")
                                        .font(.system(size: Typography.subhead)).lineLimit(2)
                                    Text("\(e["gate"] as? String ?? "—") · 分数 \(fmt(e["score"]))")
                                        .font(.system(size: Typography.tiny)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
                }
            }
            .glassListCard()
            if (state["quiet"] as? Bool) == true {
                Text("🌙 当前处于静默时段，主动消息只入队不出声。")
                    .font(.system(size: Typography.tiny)).foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.xl)
            }
        }
    }

    // ── 手动跑一轮 ──
    private var manualCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("调试")
            VStack(spacing: 0) {
                Button {
                    Task { await runNow() }
                } label: {
                    HStack {
                        Text(busy ? "正在跑…" : "立刻跑一轮（dry-run）")
                            .font(.system(size: Typography.body))
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy || loaded == false)
                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
                Text("只判定不投递：看今天该不该说话、判定分多少，不会真发消息。")
                    .font(.system(size: Typography.tiny)).foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.xxl).padding(.bottom, Spacing.lg)
            }
            .glassListCard()
        }
    }

    private func metric(_ t: String, _ v: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.system(size: Typography.title, weight: .semibold))
            Text(t).font(.system(size: Typography.tiny)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 数据

    private func reload() async {
        guard let c = await auth.jsonOrLog("/api/agent/proactive/config"),
              let ok = c["config"] as? [String: Any] else {
            loadErr = "读取主动 Agent 配置失败（后端可能未启动）"
            return
        }
        loadErr = nil
        cfg = ok
        loaded = true
        state = (await auth.jsonOrLog("/api/agent/proactive/state")) ?? [:]
    }

    private func patch(_ kv: [String: Any]) {
        // 先本地生效（滑条/开关要跟手），失败回滚 + 提示
        let snapshot = cfg
        for (k, v) in kv { cfg[k] = v }
        Task {
            if let d = await auth.jsonOrLog("/api/agent/proactive/config", method: "POST", body: kv),
               (d["ok"] as? Bool) == true {
                if let c = d["config"] as? [String: Any] { cfg = c }
                state = (await auth.jsonOrLog("/api/agent/proactive/state")) ?? state
            } else {
                cfg = snapshot
                flash("保存失败，已还原")
            }
        }
    }

    private func runNow() async {
        busy = true
        defer { busy = false }
        guard let d = await auth.jsonOrLog("/api/agent/proactive/run", method: "POST",
                                           body: ["dry_run": true]),
              let rs = d["results"] as? [[String: Any]] else {
            flash("跑一轮失败"); return
        }
        if rs.isEmpty { flash("没有待判定的事件（事件源还没产生信号）") }
        else if let s = rs[0]["score"] as? Double, let g = rs[0]["gate"] as? String {
            flash(String(format: "首条判定：%@ · 分数 %.2f", g, s))
        } else { flash("已完成 \(rs.count) 条判定") }
        state = (await auth.jsonOrLog("/api/agent/proactive/state")) ?? state
    }

    @ViewBuilder
    private func hourPicker(_ label: String, key: String, dflt: Int) -> some View {
        // 后端存 0..23 整点；这里用 Menu 走「改一次就提交一次」而不是拖 Stepper
        // （Stepper 每点一格就 POST 一次，23 格滑过去 = 23 次写配置）
        Menu {
            ForEach(0..<24, id: \.self) { h in
                Button {
                    patch([key: h])
                } label: {
                    Text(String(format: "%02d:00", h))
                }
            }
        } label: {
            Text("\(label) \(intOf(cfg[key], dflt)):00")
                .font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
        }
    }

    private func flash(_ s: String) { withAnimation(Motion.snap) { toast = s } }

    private func boolText(_ b: Bool?) -> String { (b ?? true) ? "开" : "关" }
    private func intOf(_ a: Any?, _ d: Int) -> Int { (a as? Int) ?? (a as? NSNumber)?.intValue ?? d }
    private func dblOf(_ a: Any?, _ d: Double) -> Double { (a as? Double) ?? (a as? NSNumber)?.doubleValue ?? d }
    private func fmt(_ a: Any?) -> String {
        guard let n = (a as? Double) ?? (a as? NSNumber)?.doubleValue else { return "—" }
        return String(format: "%.2f", n)
    }
}
