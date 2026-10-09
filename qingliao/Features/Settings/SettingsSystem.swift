// 本文件由 2026-09-27 工程治理「Settings 物理合并」生成：多份同域设置页文件合并为一，
// UI 入口与行为零改动，仅文件边界变化。合并前各文件的来源见下方 MARK 分段。

import Combine
import Foundation
import LocalAuthentication
import PDFKit
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: ===== 以下原为 Features/Settings/DiagnosticsView.swift =====

// MARK: - v3.6.0 设置 → 诊断（App 自身诊断页）
//
// 与旧「崩溃日志」入口整合：原单独一行的「崩溃日志」已并入本页（本页底部「崩溃日志」分组
// 提供查看/导出/复制，行为不变），避免两个功能重复又互相矛盾的入口。
//
// 视觉：沿用设置页定稿——SectionHeader 分组 + pastelCard 渐变卡容器级 0.8pt 描边（不做行级描边）、
// 胶囊按钮、动效走 Theme/Motion 令牌。

struct DiagnosticsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var env: DiagEnv = .unknown
    @State private var events: [DiagEvent] = []
    @State private var pendingCount = 0
    /// v3.9.10：上报统计（累计条数 / 上次结果）——「待上报」长期为 0 时用它自证链路是通的
    @State private var uploadStats = DiagnosticsStore.UploadStats()
    /// v3.9.10：队列变化通知的合并闸（防一次上报的多条通知各刷一遍全量读盘）
    @State private var refreshScheduled = false
    @State private var expanded: Set<String> = []
    @State private var copied = false
    @State private var showExporter = false
    @State private var exportText = ""
    @State private var showCrashSheet = false
    /// v3.6.4：清除本机诊断记录（崩溃 / 卡顿）二次确认
    @State private var showClearAlert = false
    @State private var uploading = false
    @State private var uploadText = ""
    @State private var uploadOK = false
    @State private var pingText = "未检测"
    @State private var pingOK = false
    @State private var pinging = false
    // 卡顿检测开关 / 阈值（与 HangWatchdog 同键）
    @AppStorage(HangWatchdog.keyEnabled) private var hangEnabled = true
    @AppStorage(HangWatchdog.keyThreshold) private var hangThreshold = HangWatchdog.defaultThresholdMs

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    deviceSection
                    connectivitySection
                    reportSection
                    recordsSection
                    crashLogSection
                    privacySection
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, 30)
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 16) {
                        Button {
                            copyAll()
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(Color.accentColor)
                                .symbolEffect(.bounce, value: copied)   // v3.9.0：复制成功弹一下
                        }
                        Button {
                            exportText = bundleText()
                            showExporter = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(Color.accentColor)
                        }
                        // v3.9.35：刷新改回系统裸按钮——与「完成」同款系统玻璃胶囊（iOS 26 工具栏自动渲染）
                        Button("刷新") { Task { await reload() } }
                    }
                }
            }
            .task { await reload() }
            // v3.9.10：队列/上报统计变化即刷新（看门狗在后台记录并上报时，页面上数字要跟着动）
            .onReceive(NotificationCenter.default.publisher(
                for: DiagnosticsStore.queueChangedNotification)) { _ in
                // v3.9.10 fix（审查抓到）：一次兜底 flush 最多 10 批 → 出队/记账各自发通知，
                // 每次都同步三读（pending/stats/history，最多 50+30 条 × 4000 字栈 + JSON 解码）。
                // 这会让诊断页自己在主线程忙起来——正好叠在刚恢复的主线程上，可能被看门狗
                // 记成一条「真卡顿」（自证式假阳性）。合并 300ms 内的连续通知，只刷一次。
                if refreshScheduled { return }
                refreshScheduled = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    refreshScheduled = false
                    await reload()
                }
            }
            .onChange(of: hangEnabled) { _, _ in HangWatchdog.shared.refreshSettings() }
            .onChange(of: hangThreshold) { _, _ in HangWatchdog.shared.refreshSettings() }
            .sheet(isPresented: $showExporter) {
                ActivityShareSheet(items: [exportText])
            }
            .sheet(isPresented: $showCrashSheet) {
                CrashAlertSheet(logText: CrashReporter.latestLogText(), allowDismiss: false)
                    .presentationDetents([.medium, .large])
            }
            .alert("清除全部诊断记录？", isPresented: $showClearAlert) {
                Button("取消", role: .cancel) { }
                Button("清除", role: .destructive) { clearRecords() }
            } message: {
                Text("将清空本机保存的崩溃 / 卡顿记录，以及待上报队列（\(pendingCount) 条待上报也会一并清除）。已上报到服务器的记录不受影响。")
            }
        }
    }

    // MARK: 设备与版本

    @ViewBuilder private var deviceSection: some View {
        SectionHeader("设备与版本")
        VStack(spacing: 0) {
            SettingRow(icon: "app.badge.fill", iconColor: .blue, title: "App 版本",
                       value: env.version.isEmpty ? "未知" : env.version)
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "number.square.fill", iconColor: .indigo, title: "构建号",
                       value: env.build.isEmpty ? "未知" : env.build)
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "iphone.gen3", iconColor: .gray, title: "设备型号",
                       value: env.device.isEmpty ? "未知" : env.device)
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "gear.badge.checkmark", iconColor: .teal, title: "系统版本",
                       value: env.os.isEmpty ? "未知" : env.os)
        }
        .pastelCard()
    }

    // MARK: 网络与后端

    @ViewBuilder private var connectivitySection: some View {
        SectionHeader("网络与后端")
        VStack(spacing: 0) {
            SettingRow(icon: "wifi", iconColor: .green, title: "网络状态",
                       value: env.network.isEmpty ? "未知" : env.network)
            Divider().padding(.leading, Spacing.rowDividerInset)
            Button {
                Task { await checkPing() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("后端连通性").font(.system(size: Typography.body))
                        if !pingText.isEmpty {
                            Text(pingText)
                                .font(.system(size: Typography.caption))
                                .foregroundStyle(pingOK ? Color.green : Color.orange)
                        }
                    }
                    Spacer()
                    if pinging { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .pastelCard()
    }

    // MARK: 上报

    @ViewBuilder private var reportSection: some View {
        SectionHeader("上报")
        VStack(spacing: 0) {
            SettingRow(icon: "tray.full.fill", iconColor: .purple, title: "待上报记录",
                       value: pendingText)
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "checkmark.seal.fill",
                       iconColor: uploadStats.lastOK ? .green : .orange,
                       title: "上报统计",
                       value: uploadStatsText)
            Divider().padding(.leading, Spacing.rowDividerInset)
            Button {
                Task { await manualUpload() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("立即上报").font(.system(size: Typography.body))
                        if !uploadText.isEmpty {
                            Text(uploadText)
                                .font(.system(size: Typography.caption))
                                .foregroundStyle(uploadOK ? Color.green : Color.orange)
                        }
                    }
                    Spacer()
                    if uploading { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(uploading)
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "gauge.with.dots.needle.67percent", iconColor: .red, title: "卡顿检测",
                       value: hangEnabled ? "阈值 \(hangThreshold)ms" : "已关闭",
                       toggle: $hangEnabled)
            if hangEnabled {
                Divider().padding(.leading, Spacing.rowDividerInset)
                HStack(spacing: 10) {
                    Text("卡顿阈值").font(.system(size: Typography.body))
                    Spacer()
                    Text("\(hangThreshold) ms")
                        .font(.system(size: Typography.body)).foregroundStyle(.secondary)
                    Stepper("", value: $hangThreshold, in: 200...3000, step: 100)
                        .labelsHidden()
                }
                .padding(.horizontal, Spacing.section).padding(.vertical, Spacing.lg)
            }
            Divider().padding(.leading, Spacing.rowDividerInset)
            Button {
                simulateHang()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "ladybug.fill")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.pink, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("写入一条测试记录").font(.system(size: Typography.body))
                        Text("仅本地记录，用于验证上报链路")
                            .font(.system(size: Typography.caption)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .pastelCard()
    }

    // MARK: 上报计数文案（v3.9.10）

    /// 「待上报」/「上报统计」—— 实现统一在 DiagnosticsPayload（导出文本与页面共用同一份文案）
    private var pendingText: String {
        DiagnosticsPayload.pendingText(pendingCount, stats: uploadStats)
    }

    private var uploadStatsText: String {
        DiagnosticsPayload.uploadStatsText(uploadStats)
    }

    // MARK: 最近记录

    @ViewBuilder private var recordsSection: some View {
        SectionHeader("最近记录（崩溃 / 卡顿）")
        VStack(spacing: 0) {
            if events.isEmpty {
                HStack {
                    Text("暂无记录")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.xxl)
            } else {
                ForEach(events) { e in
                    recordRow(e)
                    if e.id != events.last?.id {
                        Divider().padding(.leading, Spacing.rowDividerInset)
                    }
                }
                Divider().padding(.leading, Spacing.xxl)
                clearAllButton
            }
        }
        .pastelCard()
    }

    /// v3.6.4：清除全部记录（本机）——危险操作，走二次确认
    private var clearAllButton: some View {
        Button {
            showClearAlert = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                Text("清除全部记录")
                    .font(.system(size: Typography.subhead, weight: .semibold))
            }
            .foregroundStyle(Color.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xl)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("清除全部诊断记录")
    }

    @ViewBuilder private func recordRow(_ e: DiagEvent) -> some View {
        let isOpen = expanded.contains(e.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: e.kind == "crash" ? "exclamationmark.triangle.fill" : "hourglass")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(e.kind == "crash" ? Color.red : Color.orange,
                                in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(DiagnosticsPayload.kindLabel(e.kind) + " · " + e.summary)
                        .font(.system(size: Typography.body))
                        .lineLimit(isOpen ? 3 : 1)
                        .foregroundStyle(.primary)
                    Text(DiagnosticsPayload.timeText(e.ts))
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Motion.snap) {
                    if isOpen { expanded.remove(e.id) } else { expanded.insert(e.id) }
                }
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    Text(DiagnosticsPayload.detailText(e))
                        .font(.system(size: Typography.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = DiagnosticsPayload.detailText(e)
                    } label: {
                        Text("复制这条")
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.sm)
                            .background(Color.secondary.opacity(Tint.soft), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.xxl).padding(.bottom, Spacing.xl)
                .transition(.opacity)
            }
        }
        .clipped()
    }

    // MARK: 崩溃日志（原设置页「崩溃日志」入口整合至此）

    @ViewBuilder private var crashLogSection: some View {
        SectionHeader("崩溃日志")
        VStack(spacing: 0) {
            SettingRow(icon: "exclamationmark.triangle.fill",
                       iconColor: .red,
                       title: "最近一次崩溃",
                       value: CrashReporter.hasPendingLog() ? "有待查看" : "查看 / 导出",
                       chevron: true)
                .onTapGesture { showCrashSheet = true }
        }
        .pastelCard()
    }

    // MARK: 隐私说明

    @ViewBuilder private var privacySection: some View {
        SectionHeader("隐私说明")
        VStack(alignment: .leading, spacing: 6) {
            Text("上报内容仅含：版本、构建号、设备型号、系统版本、网络类型、时间、错误摘要与调用栈。")
            Text("不采集也不上传：聊天内容、图片、密码/令牌等任何凭据，以及任何设备唯一标识。")
            Text("上报失败时事件缓存在本机（最多 \(DiagnosticsPayload.maxPendingEvents) 条），下次启动自动补传。")
        }
        .font(.system(size: Typography.subhead))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.section).padding(.vertical, Spacing.xxl)
        .pastelCard()
    }

    // MARK: 数据加载与动作

    /// v3.6.4：清除本机诊断记录 —— history（列表显示的历史）+ pending（待上报队列）。
    /// 只清本机：已上报到服务器的记录由服务端保留。
    private func clearRecords() {
        DiagnosticsStore.removePending(ids: DiagnosticsStore.pendingEvents().map { $0.id })
        DiagnosticsStore.clearHistory()
        expanded = []
        events = []
        pendingCount = 0
        Task { await reload() }
    }

    private func reload() async {
        DiagnosticsEnv.refresh()
        env = DiagnosticsStore.env()
        events = DiagnosticsStore.historyEvents()
        pendingCount = DiagnosticsStore.pendingCount()
        uploadStats = DiagnosticsStore.stats()
        DiagnosticsUploader.attach(auth: auth)
        await checkPing()
    }

    private func checkPing() async {
        guard !pinging else { return }
        pinging = true
        defer { pinging = false }
        DiagnosticsUploader.attach(auth: auth)
        let r = await DiagnosticsUploader.ping()
        pingOK = r.ok
        pingText = r.message
        // 网络状态可能已变，刷新一次
        DiagnosticsEnv.refresh()
        env = DiagnosticsStore.env()
    }

    private func manualUpload() async {
        guard !uploading else { return }
        uploading = true
        defer { uploading = false }
        DiagnosticsUploader.attach(auth: auth)
        let r = await DiagnosticsUploader.flushPending()
        uploadOK = r.ok
        uploadText = r.message
        withAnimation(Motion.snap) {
            pendingCount = DiagnosticsStore.pendingCount()
            uploadStats = DiagnosticsStore.stats()
            events = DiagnosticsStore.historyEvents()
        }
    }

    /// 写入一条测试记录（仅本地 + 队列），用于在真机上验证「记录 → 上报」链路
    private func simulateHang() {
        DiagnosticsEnv.refresh()
        // v3.9.10：用独立 kind=selftest，服务端统计卡顿时可据此剔除
        DiagnosticsStore.recordSelfTest(durationMs: hangThreshold + 37,
                                        stack: "(自测记录 · 非真实卡顿)")
        withAnimation(Motion.snap) {
            pendingCount = DiagnosticsStore.pendingCount()
            uploadStats = DiagnosticsStore.stats()
            events = DiagnosticsStore.historyEvents()
        }
        uploadText = "已写入一条测试记录（\(pendingCount) 条待上报）"
        uploadOK = true
    }

    private func bundleText() -> String {
        DiagnosticsPayload.bundleText(env: env, events: events,
                                      backend: pingText, pendingCount: pendingCount,
                                      uploadStats: uploadStats)
    }

    private func copyAll() {
        UIPasteboard.general.string = bundleText()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

// MARK: ===== 以下原为 Features/Settings/AppPermissionsSheet.swift =====

// MARK: - v3.9.95 权限与 AI 操控（设置页）
//
// 页面只做三件事，**不含任何执行逻辑**（全在 AppPermissionKit / AgentActionExecutor）：
//   1. 显示每项能力的系统授权状态 + 引导去请求/去系统设置
//   2. 逐项「允许 AI 操作」开关 + 一个总闸
//   3. 写清能力边界（哪些能做、哪些 Apple 压根没给 API）
//
// 交互口径：状态胶囊点一下 = 去请求授权（未授权时）或跳系统设置（已拒绝时）。
// 已拒绝后**不能**再弹系统框（iOS 只让请求一次），必须跳设置 —— 这是最常踩的坑。

struct AppPermissionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var states: [AppCapability: PermissionState] = [:]
    @State private var loading = true
    @State private var requesting: AppCapability?
    @AppStorage("qingliao_ai_control_master") private var masterOn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    masterCard
                    ForEach(AppCapability.allCases) { cap in
                        capabilityCard(cap)
                    }
                    boundaryNote
                }
                .padding(Spacing.xxl)
            }
            .background(Color.clear)
            .navigationTitle("权限与 AI 操控")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await refresh() }
        }
    }

    // MARK: 总闸

    private var masterCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                // v4.0.83（用户：「app 里面小图标统一圆角多彩」）：总闸卡片头部图标也统一成「圆角色块 + 白符号」，
                // 与同文件其余行图标（:158/:199/:245/:323）同款。
                Image(systemName: "brain.head.profile")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor,
                                in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                Text("允许 AI 操作我的数据")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                Spacer()
                Toggle("", isOn: $masterOn).qingliaoSwitch()
                    .onChange(of: masterOn) { _, _ in
                        AppPermissionKit.aiControlMasterEnabled = masterOn
                        Haptics.tap()
                    }
            }
            Text("总闸关闭时，下面每项的开关一律无效 —— AI 不会读也不会改任何本地数据。删操作永远需要你单独确认。")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.lg)
        .pastelCard()
    }

    // MARK: 单项能力

    @ViewBuilder
    private func capabilityCard(_ cap: AppCapability) -> some View {
        let st = states[cap] ?? .notDetermined
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 12) {
                // v4.0.83（用户：「app 里面小图标统一圆角多彩」）：能力行图标也统一成「圆角色块 + 白符号」。
                // 可被 AI 操作 → 强调色块（与右侧状态徽标同一语义）；不可操作 → 灰块（弱化但保持同一形状语言）。
                Image(systemName: cap.sfSymbol)
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(cap.aiControllable ? Color.accentColor : Color.gray,
                                in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                Text(cap.displayName)
                    .font(.system(size: Typography.subhead, weight: .semibold))
                Spacer()
                stateChip(st, for: cap)
            }
            Text(cap.blurb)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)

            if cap.aiControllable {
                Divider().padding(.vertical, Spacing.xxs)
                HStack {
                    Text("允许 AI 操作\(cap.displayName)")
                        .font(.system(size: Typography.caption))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { AppPermissionKit.aiControlEnabled(cap) },
                        set: { newValue in
                            AppPermissionKit.setAIControlEnabled(newValue, for: cap)
                            Haptics.tap()
                        }
                    )).qingliaoSwitch()
                    .disabled(!masterOn || st != .granted)
                }
            }
        }
        .padding(Spacing.lg)
        .pastelCard()
    }

    /// 状态胶囊。未授权/已拒绝的点一下去授权或跳系统设置。
    private func stateChip(_ st: PermissionState, for cap: AppCapability) -> some View {
        let tappable: Bool = st != .granted && st != .unavailable
        return Text(st.label)
            .font(.system(size: Typography.caption, weight: .medium))
            .foregroundStyle(color(st))
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(color(st).opacity(0.15), in: Capsule())
            .onTapGesture {
                guard tappable else { return }
                Haptics.tap()
                tapOn(cap)
            }
    }

    private func color(_ st: PermissionState) -> Color {
        switch st {
        case .granted:     return .green
        case .notDetermined: return .orange
        case .denied, .restricted, .unavailable: return .secondary
        }
    }

    // MARK: 交互

    private func tapOn(_ cap: AppCapability) {
        Task {
            switch await AppPermissionKit.status(of: cap) {
            case .notDetermined:
                requesting = cap
                _ = await AppPermissionKit.request(cap)
                requesting = nil
                Haptics.success()
            case .denied, .restricted:
                // iOS 只允许请求一次；再请求系统不会再弹窗。必须跳系统设置。
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    await UIApplication.shared.open(url)
                }
            case .granted, .unavailable:
                break
            }
            await refresh()
        }
    }

    // MARK: 边界说明

    private var boundaryNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("能力边界", systemImage: "info.circle")
                .font(.system(size: Typography.caption, weight: .semibold))
            Text("""
            · 提醒事项：可以读写了（EventKit，和日历同一套框架）。这里此前写的「Apple 未开放接口」是错的，已更正。
            · 文件读写：只限轻聊自己的目录（「文件」App → 我的 iPhone → 轻聊），碰不到其它 App 的文件。
            · 剪贴板：写入不需要许可；每次读取 iOS 会弹一次系统「粘贴」提示，这是系统行为，App 关不掉。
            · 邮件：能代你发（走你在「设置 → 邮件」配好的账号，需该账号开启「允许 AI 直接发信」）；读信/搜信目前做不到。
            · 微信等第三方 App 的数据、系统闹钟、短信与通话记录、备忘录正文：Apple 未开放接口，只能跳转打开。
            · 家庭（HomeKit）：需开发者证书授权，侧载安装无法使用。
            · 读你的数据前要先在系统里授权对应 App；写和删还要在上面单独打开「允许 AI 操作」，并在动作卡上点一次确认。
            · 删除照片不可撤销（App 里没撤销按钮），但会进相册「最近删除」保留 30 天；删除提醒/事件则可 5 秒内撤销。
            """)
            .font(.system(size: Typography.caption))
            .foregroundStyle(.secondary)
        }
        .padding(Spacing.lg)
        .pastelCard()
    }

    // MARK: 刷新

    private func refresh() async {
        loading = true
        var out: [AppCapability: PermissionState] = [:]
        for c in AppCapability.allCases { out[c] = await AppPermissionKit.status(of: c) }
        states = out
        loading = false
    }
}
