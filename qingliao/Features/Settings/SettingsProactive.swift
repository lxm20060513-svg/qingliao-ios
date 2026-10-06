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
    @State private var fuBusy = false           // 「现在检查」在跑
    @State private var rowBusy: String?         // 正在勾销/忽略的条目正文
    @State private var toast: String?
    // v4.0.x 第 6 项：反思日记的回答输入 + 两个忙态（存回答 / 看今天到点没）
    @State private var journalDraft = ""
    @State private var journalBusy = false
    @State private var juBusy = false

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
                    followupCard
                    journalCard
                    reviewCard
                    manualCard
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.xl)
            }
            // v3.9.23 决策：弹窗背景一律不覆盖，让系统默认玻璃生效（勿再挂实色底）。
            // 原来这里挂了一行 systemGroupedBackground 实色底，正是它把主动 Agent 弹窗
            // 变成实色页、与其它半屏玻璃弹窗不统一。已在 v4.0.x 移除。
            .scrollContentBackground(.hidden)
            .navigationTitle("主动 Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
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
            .pastelCard()
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
                Divider().padding(.leading, Spacing.rowDividerInset)
                // v4.0.20（#2）：长期目标自动判定 —— 关掉后 AI 不再把闲聊误判成长期目标。
                // 后端 stream_api 按同一个 key 整段门控 goal.create 的动作说明；
                // 已存在的目标照常由 cron 推进（那个开关只管「要不要新认目标」）。
                SettingRow(icon: "target", iconColor: .pink, title: "长期目标自动判定",
                           value: boolText(cfg["goalAutoDetect"] as? Bool),
                           toggle: Binding(get: { cfg["goalAutoDetect"] as? Bool ?? true },
                                          set: { patch(["goalAutoDetect": $0]) }))
                Divider().padding(.leading, Spacing.rowDividerInset)
                // v4.0.25：待办升级建议 —— 同一类待办攒到 3 条（都还没做）时，
                // AI 会问一句「要不要升级成长期目标」。关掉就只留原样待办，不再提议。
                SettingRow(icon: "checklist", iconColor: .green, title: "待办升级建议",
                           value: boolText(cfg["todoCluster"] as? Bool),
                           toggle: Binding(get: { cfg["todoCluster"] as? Bool ?? true },
                                          set: { patch(["todoCluster": $0]) }))
            }
            .pastelCard()
        }
    }

    // ── ③ 待跟进（v4.0.x 第 5 项：到点追问 + App 内勾销）──
    private var followupCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("待跟进")
            let fu = state["followup"] as? [String: Any] ?? [:]
            let pending = fu["pending"] as? [[String: Any]] ?? []
            let asked = fu["asked"] as? [String: Any] ?? [:]
            let maxR = intOf(fu["maxRounds"], 3)
            let afterH = intOf(fu["afterHours"], 20)
            VStack(spacing: 0) {
                // 开关 + 到期阈值（写入后端 proactive_config.json，App 不存影子状态）
                SettingRow(icon: "bell.badge.fill", iconColor: .orange,
                           title: "到点主动追问",
                           value: boolText(cfg["followupEnable"] as? Bool),
                           toggle: Binding(get: { cfg["followupEnable"] as? Bool ?? true },
                                          set: { patch(["followupEnable": $0]) }))
                Divider().padding(.leading, Spacing.rowDividerInset)
                HStack {
                    Text("过了多久开始问").font(.system(size: Typography.body))
                    Spacer()
                    Stepper("\(intOf(cfg["followupAfterHours"], 20)) 小时",
                           value: Binding(get: { intOf(cfg["followupAfterHours"], 20) },
                                          set: { patch(["followupAfterHours": $0]) }),
                           in: 1...720)
                    .labelsHidden()
                    Text("\(intOf(cfg["followupAfterHours"], 20)) 小时")
                        .font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)

                if pending.isEmpty {
                    Divider().padding(.leading, Spacing.rowDividerInset)
                    Text("还没有待跟进的事。在记忆里把条目标成「待跟进」，到点我会主动问一句。")
                        .font(.system(size: Typography.tiny)).foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
                } else {
                    Divider().padding(.leading, Spacing.rowDividerInset)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("待跟进 \(pending.count) 条 · 满 \(afterH) 小时开始问，最多问 \(maxR) 遍")
                            .font(.system(size: Typography.tiny)).foregroundStyle(.secondary)
                        ForEach(Array(pending.enumerated()), id: \.offset) { i, r in
                            FollowupRow(
                                text: (r["text"] as? String) ?? "—",
                                asked: intOf((asked[(r["text"] as? String) ?? ""] as? [String: Any])?["asked"], 0),
                                maxRounds: maxR,
                                due: (r["due"] as? Bool) == true,
                                busy: rowBusy == (r["text"] as? String),
                                onSettle: { settle(r["text"] as? String ?? "", status: "active", done: "已勾销") },
                                onIgnore: { settle(r["text"] as? String ?? "", status: "stale", done: "已忽略") })
                            if i < pending.count - 1 { Divider() }
                        }
                    }
                    .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)

                    Divider().padding(.leading, Spacing.rowDividerInset)
                    Button {
                        Task { await checkFollowup() }
                    } label: {
                        HStack {
                            Text(fuBusy ? "正在检查…" : "现在检查哪些到点了")
                                .font(.system(size: Typography.body))
                            Spacer()
                            if fuBusy { ProgressView() }
                        }
                    }
                    .disabled(fuBusy || loaded == false)
                    .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
                    Text("只判定不投递：看哪几条已经到点，不会真发消息、也不会消耗「已问过」的次数。")
                        .font(.system(size: Typography.tiny)).foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.xxl).padding(.bottom, Spacing.lg)
                }
            }
            .pastelCard()
        }
    }

    // ── ④ 反思日记（v4.0.x 第 6 项：每日一问 + 周回顾）──
    // 问句、今天问没问、答没答全部读后端 /state 的 journal 段 —— 前端**不自造问句**，
    // 否则界面显示一句、真投递另一句（同第 5 项 due 口径漂移那个坑）。
    private var journalCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("反思日记")
            let j = state["journal"] as? [String: Any] ?? [:]
            let asked = (j["asked"] as? Bool) == true
            let answered = (j["answered"] as? Bool) == true
            let weekAsked = (j["weekAsked"] as? Bool) == true
            VStack(spacing: 0) {
                SettingRow(icon: "moon.stars.fill", iconColor: .indigo,
                           title: "睡前主动问我一句",
                           value: boolText(cfg["journalEnable"] as? Bool),
                           toggle: Binding(get: { cfg["journalEnable"] as? Bool ?? true },
                                          set: { patch(["journalEnable": $0]) }))
                Divider().padding(.leading, Spacing.rowDividerInset)
                HStack {
                    Text("每天几点开始问").font(.system(size: Typography.body))
                    Spacer()
                    Stepper("\(intOf(cfg["journalHour"], 22)) 点",
                           value: Binding(get: { intOf(cfg["journalHour"], 22) },
                                          set: { patch(["journalHour": $0]) }),
                           in: 0...23)
                    .labelsHidden()
                    Text("\(intOf(cfg["journalHour"], 22)) 点")
                        .font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
                Divider().padding(.leading, Spacing.rowDividerInset)
                VStack(alignment: .leading, spacing: 8) {
                    Text("今天这一问").font(.system(size: Typography.subhead))
                        .foregroundStyle(.secondary)
                    Text((j["question"] as? String) ?? "—")
                        .font(.system(size: Typography.body)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(asked ? "已问过" : "还没问")
                            .font(.system(size: Typography.tiny)).foregroundStyle(.secondary)
                        if answered {
                            Text("· 已答过").font(.system(size: Typography.tiny))
                                .foregroundStyle(Color.green)
                        }
                        Spacer()
                        Text("本周回顾\(weekAsked ? "已发" : "周一发")")
                            .font(.system(size: Typography.tiny)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)

                if answered, let a = j["answer"] as? String, !a.isEmpty {
                    Divider().padding(.leading, Spacing.rowDividerInset)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("你今天写的").font(.system(size: Typography.tiny))
                            .foregroundStyle(.secondary)
                        Text(a).font(.system(size: Typography.subhead))
                            .lineLimit(3).truncationMode(.tail)
                    }
                    .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
                }

                Divider().padding(.leading, Spacing.rowDividerInset)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("现在回一句（存进记忆）", text: $journalDraft, axis: .vertical)
                        .font(.system(size: Typography.body))
                        .lineLimit(1...3)
                    Button {
                        Task { await submitJournal() }
                    } label: {
                        HStack {
                            Text(journalBusy ? "正在存…" : "存进记忆")
                                .font(.system(size: Typography.body))
                            Spacer()
                            if journalBusy { ProgressView() }
                        }
                    }
                    .disabled(journalBusy || journalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("回答会作为一条记忆存下来（生效中），之后我能接着聊这件事。")
                        .font(.system(size: Typography.tiny)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)

                Divider().padding(.leading, Spacing.rowDividerInset)
                Button {
                    Task { await previewJournal() }
                } label: {
                    HStack {
                        Text(juBusy ? "正在看…" : "看看今天到点没")
                            .font(.system(size: Typography.body))
                        Spacer()
                        if juBusy { ProgressView() }
                    }
                }
                .disabled(juBusy || loaded == false)
                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
                Text("只判定不投递：到点了会告诉你，但不会真发消息、也不会算今天已经问过。")
                    .font(.system(size: Typography.tiny)).foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.xxl).padding(.bottom, Spacing.lg)
            }
            .pastelCard()
        }
    }

    // ── ⑤ 复盘看板 ──
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
            .pastelCard()
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
            .pastelCard()
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

    /// v4.0.x 第 5 项：勾销/忽略 = 翻状态离开 pending。
    /// 后端在状态离开 pending 的那一刻清掉这条的追问留痕，所以「我刚勾销它却还记着已问 2 遍」
    /// 这种幽灵状态不可能出现 —— 前端不需要（也不该）自己本地删。
    private func settle(_ text: String, status: String, done: String) {
        guard !text.isEmpty, rowBusy == nil else { return }
        rowBusy = text
        Task {
            defer { rowBusy = nil }
            guard let d = await auth.jsonOrLog("/api/memory/status", method: "POST",
                                               body: ["text": text, "status": status]),
                  (d["ok"] as? Bool) == true else {
                flash("操作失败，已还原"); return
            }
            flash(done)
            state = (await auth.jsonOrLog("/api/agent/proactive/state")) ?? state
        }
    }

    /// 只判定不投递：dry_run 由后端默认 true，不显式传 false。
    /// 传了 false 就等于「用户点一下就真发消息 + 消耗一次提问机会」，那不是这个按钮的语义。
    private func checkFollowup() async {
        fuBusy = true
        defer { fuBusy = false }
        guard let d = await auth.jsonOrLog("/api/agent/proactive/followup", method: "POST",
                                           body: ["dry_run": true]) else {
            flash("检查失败"); return
        }
        state = (await auth.jsonOrLog("/api/agent/proactive/state")) ?? state
        let n = intOf(d["produced"], 0)
        flash(n == 0 ? "还没有到点的（满 \(intOf(cfg["followupAfterHours"], 20)) 小时才问）"
                     : "有 \(n) 条到点，下一轮会问")
    }

    /// v4.0.x 第 6 项：回答今天这一问 → 后端落留痕 + 存进记忆（生效中）。
    /// 前端只发内容、不自己写记忆接口 —— 记忆写入只有 memory_store 一条真路，
    /// App 另开一条就会出现「界面说存了、记忆里没有」。
    private func submitJournal() async {
        let t = journalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !journalBusy else { return }
        journalBusy = true
        defer { journalBusy = false }
        guard let d = await auth.jsonOrLog("/api/agent/proactive/journal/answer", method: "POST",
                                           body: ["text": t]),
              (d["ok"] as? Bool) == true else {
            flash("保存失败"); return
        }
        journalDraft = ""
        state = (await auth.jsonOrLog("/api/agent/proactive/state")) ?? state
        flash((d["saved"] as? Bool) == true ? "已存进记忆" : "日记已记下（记忆写入失败，稍后可在记忆页补）")
    }

    /// 只判定不投递：显式传 dry_run=true。
    /// 后端默认也是 true，但显式传是为了让「不消耗今天提问机会」这件事在 App 侧可读、可被真值表钉住。
    private func previewJournal() async {
        juBusy = true
        defer { juBusy = false }
        guard let d = await auth.jsonOrLog("/api/agent/proactive/journal", method: "POST",
                                           body: ["dry_run": true]) else {
            flash("检查失败"); return
        }
        state = (await auth.jsonOrLog("/api/agent/proactive/state")) ?? state
        let n = intOf(d["produced"], 0)
        if n == 0 {
            flash("还没到 \(intOf(cfg["journalHour"], 22)) 点")
        } else if let t0 = ((d["detail"] as? [[String: Any]]) ?? []).first?["text"] as? String {
            flash("到点了，会问：\(String(t0.prefix(24)))")
        } else {
            flash("有 \(n) 条到点")
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

/// v4.0.x 第 5 项：一条待跟进记忆的行。
///
/// 两个动作 = 翻状态离开 pending（勾销=办完了回 active / 忽略=说它过时了回 stale），
/// **不在 App 本地删任何计数**：留痕清理由后端在状态离开 pending 那一刻做，
/// 前端自己删就会出现「界面归零、后端还记着 2 遍」的幽灵状态。
struct FollowupRow: View {
    let text: String
    let asked: Int
    let maxRounds: Int
    let due: Bool
    let busy: Bool
    let onSettle: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: due ? "bell.badge.fill" : "clock")
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(due ? Color.orange : Color.secondary)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(text)
                        .font(.system(size: Typography.subhead))
                        .lineLimit(2)
                    Text(due ? "已到点，会主动问一句"
                             : "还没到时间")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(due ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Spacing.lg) {
                Text("已问 \(asked)/\(maxRounds) 遍")
                    .font(.system(size: Typography.tiny)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: onSettle) {
                    Text(busy ? "…" : "已办完")
                        .font(.system(size: Typography.tiny))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy)
                Button(action: onIgnore) {
                    Text("不用管")
                        .font(.system(size: Typography.tiny))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy)
            }
        }
        .padding(.vertical, 4)
    }
}
