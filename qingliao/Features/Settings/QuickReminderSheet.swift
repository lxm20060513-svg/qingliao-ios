import SwiftUI

// MARK: - v3.9.32 一句话本地定时提醒（列表 / 新建 / 解析确认）
//
// 入口有两个：
//   · 设置 →「定时提醒」；
//   · 聊天消息长按 →「提醒我」（`presetText` 带该条消息内容，截断后作为默认提醒内容）。
//
// 为什么要有「确认解析结果」这一步：解析器是规则式的（不做 LLM 兜底），**必须**让用户看见
// 「到底定到了几点」再点创建——否则一句话理解偏了，用户要等到「该响的时候没响」才发现。
// 所以这里把 summary 用胶囊显式摆出来，解析失败也把可读原因原样显示（不静默）。
//
// 视觉沿用全站口径：SectionHeader + glassListCard 分组（与设置页同款）、间距/圆角/字号走
// Spacing / Radius / Typography 令牌、胶囊走 Pill();本文件不引入新的魔法数。

struct QuickReminderSheet: View {
    /// 默认提醒内容（聊天「提醒我」入口传入该条消息；会自动截断，用户可改）
    var presetText: String = ""

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var phrase = ""
    @FocusState private var phraseFocused: Bool
    /// 创建成功反馈（会自动消失，避免一直挂着）
    @State private var createdText: String?
    @State private var createError: String?

    private var store: QuickReminderStore { .shared }

    /// 时间那句话的解析结果（空输入不解析）
    private var parsed: QuickReminderParseResult? {
        let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        return QuickReminderParser.parseDetailed(p)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    SectionHeader("新建提醒")
                    composeCard
                    if store.auth == .denied { authBanner }
                    SectionHeader("待触发")
                    pendingCard
                    if !store.finished.isEmpty {
                        SectionHeader("已提醒")
                        finishedCard
                    }
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, Spacing.section)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)   // 不盖系统玻璃弹窗底（见 LiquidGlass.swift v3.9.23 决策）
            .navigationTitle("定时提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                await store.refreshAuth()
                await store.reconcile()
            }
            .onAppear {
                if text.isEmpty { text = QuickReminderParser.seedText(from: presetText) }
                if !presetText.isEmpty { phraseFocused = true }
            }
            .onChange(of: phrase) { _, _ in
                createdText = nil
                createError = nil
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 新建

    private var composeCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            TextField("提醒内容（可留空）", text: $text, axis: .vertical)
                .font(.system(size: Typography.body))
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
            Divider()
            HStack(spacing: Spacing.md) {
                Image(systemName: "clock")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(.secondary)
                TextField("什么时候（如：明天早上 7 点半）", text: $phrase)
                    .font(.system(size: Typography.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($phraseFocused)
                    .submitLabel(.done)
            }
            parseFeedback
            createRow
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.xxl)
        .glassListCard()
    }

    /// 解析结果 / 失败原因（用户确认「定到了几点」的那一行）
    @ViewBuilder
    private var parseFeedback: some View {
        if let result = parsed {
            switch result {
            case .success(let p):
                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                    Text(p.summary).pill(.page, tone: .accent)
                    Text(p.rule.repeats ? "\(p.rule.label) · 由系统准点弹出" : "仅响一次 · 由系统准点弹出")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            case .failure(let message):
                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        } else {
            Text("写一句话就行：「5 分钟后」「明天早上 7 点半」「后天下午 3 点」「每天 7:30」「下周一 9 点」")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
    }

    private var createRow: some View {
        HStack(spacing: Spacing.lg) {
            Button {
                Task { await create() }
            } label: {
                Text("创建提醒").pill(.primary, tone: .accent)
            }
            .buttonStyle(.plain)
            .disabled(parsed?.value == nil)
            .opacity(parsed?.value == nil ? 0.45 : 1)

            if let createdText {
                Label(createdText, systemImage: "checkmark.circle.fill")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else if let createError {
                Text(createError)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    /// 权限被拒横幅（App 内已无法再弹系统授权框，只能引导去设置）
    private var authBanner: some View {
        HStack(spacing: Spacing.xl) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: Typography.title))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("通知权限没开")
                    .font(.system(size: Typography.body, weight: .medium))
                Text("没权限就不会响——去系统设置 →「通知 → 轻聊」打开")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.sm)
            Button {
                QuickReminderStore.openSystemNotificationSettings()
            } label: {
                Text("去设置").pill(.page, tone: .accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.xxl)
        .dashboardCard()
        .padding(.top, Spacing.xxl)
    }

    // MARK: - 列表

    @ViewBuilder
    private var pendingCard: some View {
        if store.scheduled.isEmpty {
            emptyHint
        } else {
            VStack(spacing: 0) {
                ForEach(Array(store.scheduled.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, Spacing.rowDividerInset) }
                    reminderRow(item)
                }
                Divider()
                Text(footerText)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.vertical, Spacing.lg)
            }
            .glassListCard()
        }
    }

    private var footerText: String {
        store.pendingCount > 0
            ? "系统已登记 \(store.pendingCount) 条提醒——App 关掉 / 手机重启也会准点响"
            : "提醒交给系统登记，App 关掉也会准点响"
    }

    @ViewBuilder
    private var finishedCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.finished.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, Spacing.rowDividerInset) }
                reminderRow(item, finished: true)
            }
            Divider()
            Button {
                Task { await store.clearFinished() }
            } label: {
                Text("清空已提醒记录").pill(.page, tone: .neutral)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.lg)
        }
        .glassListCard()
    }

    private var emptyHint: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "bell.badge")
                .font(.system(size: Typography.titleXL))
                .foregroundStyle(Color.accentColor.opacity(0.7))
            Text("还没有提醒")
                .font(.system(size: Typography.title, weight: .semibold))
            Text("在上面写一句时间，或长按聊天里的消息选「提醒我」")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.section)
        .padding(.horizontal, Spacing.xxl)
        .dashboardCard()
    }

    /// 单条提醒行（长按菜单 / 右侧按钮都能删）
    private func reminderRow(_ item: QuickReminder, finished: Bool = false) -> some View {
        HStack(spacing: Spacing.xl) {
            Image(systemName: item.rule.repeats ? "arrow.clockwise" : (finished ? "bell.slash" : "bell.fill"))
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(finished ? Color.gray : (item.rule.repeats ? Color.indigo : Color.orange),
                            in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(item.text)
                    .font(.system(size: Typography.body, weight: .medium))
                    .foregroundStyle(finished ? .secondary : .primary)
                    .lineLimit(2)
                Text(finished ? "已提醒 · \(item.timeText)" : item.timeText)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: Spacing.sm)
            Button {
                Task { await delete(item) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除提醒 \(item.text)")
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        .contextMenu {
            Button(role: .destructive) {
                Task { await delete(item) }
            } label: {
                Label("删除提醒", systemImage: "trash")
            }
        }
    }

    // MARK: - 动作

    private func create() async {
        guard case .success(let p) = parsed else { return }
        let ok = await store.add(text: text, parse: p)
        if ok {
            Haptics.success()
            createdText = "已排上：\(p.summary)"
            createError = nil
            text = ""
            phrase = ""
        } else {
            Haptics.error()
            // v3.9.41（SR30）：登记失败的真实原因（如系统 64 条 pending 已满）原先只 NSLog
            createError = store.lastScheduleError
                ?? "没能排上——通知权限没开，去系统设置打开后再试"
        }
    }

    private func delete(_ item: QuickReminder) async {
        Haptics.tap()
        await store.delete(item)
    }
}
