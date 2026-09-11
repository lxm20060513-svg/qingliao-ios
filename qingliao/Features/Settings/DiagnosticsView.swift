import SwiftUI

// MARK: - v3.6.0 设置 → 诊断（App 自身诊断页）
//
// 与旧「崩溃日志」入口整合：原单独一行的「崩溃日志」已并入本页（本页底部「崩溃日志」分组
// 提供查看/导出/复制，行为不变），避免两个功能重复又互相矛盾的入口。
//
// 视觉：沿用设置页定稿——SectionHeader 分组 + glassListCard 容器级 0.8pt 描边（不做行级描边）、
// 胶囊按钮、动效走 Theme/Motion 令牌。

struct DiagnosticsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var env: DiagEnv = .unknown
    @State private var events: [DiagEvent] = []
    @State private var pendingCount = 0
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
                .padding(.horizontal, 14)
                .padding(.bottom, 30)
            }
            .background(Color(uiColor: .systemBackground))
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
                        Button {
                            Task { await reload() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .task { await reload() }
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
            Divider().padding(.leading, 52)
            SettingRow(icon: "number.square.fill", iconColor: .indigo, title: "构建号",
                       value: env.build.isEmpty ? "未知" : env.build)
            Divider().padding(.leading, 52)
            SettingRow(icon: "iphone.gen3", iconColor: .gray, title: "设备型号",
                       value: env.device.isEmpty ? "未知" : env.device)
            Divider().padding(.leading, 52)
            SettingRow(icon: "gear.badge.checkmark", iconColor: .teal, title: "系统版本",
                       value: env.os.isEmpty ? "未知" : env.os)
        }
        .glassListCard()
    }

    // MARK: 网络与后端

    @ViewBuilder private var connectivitySection: some View {
        SectionHeader("网络与后端")
        VStack(spacing: 0) {
            SettingRow(icon: "wifi", iconColor: .green, title: "网络状态",
                       value: env.network.isEmpty ? "未知" : env.network)
            Divider().padding(.leading, 52)
            Button {
                Task { await checkPing() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
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
                .padding(.horizontal, 14).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .glassListCard()
    }

    // MARK: 上报

    @ViewBuilder private var reportSection: some View {
        SectionHeader("上报")
        VStack(spacing: 0) {
            SettingRow(icon: "tray.full.fill", iconColor: .purple, title: "待上报记录",
                       value: "\(pendingCount) 条")
            Divider().padding(.leading, 52)
            Button {
                Task { await manualUpload() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
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
                .padding(.horizontal, 14).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(uploading)
            Divider().padding(.leading, 52)
            SettingRow(icon: "gauge.with.dots.needle.67percent", iconColor: .red, title: "卡顿检测",
                       value: hangEnabled ? "阈值 \(hangThreshold)ms" : "已关闭",
                       toggle: $hangEnabled)
            if hangEnabled {
                Divider().padding(.leading, 52)
                HStack(spacing: 10) {
                    Text("卡顿阈值").font(.system(size: Typography.body))
                    Spacer()
                    Text("\(hangThreshold) ms")
                        .font(.system(size: Typography.body)).foregroundStyle(.secondary)
                    Stepper("", value: $hangThreshold, in: 200...3000, step: 100)
                        .labelsHidden()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            Divider().padding(.leading, 52)
            Button {
                simulateHang()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "ladybug.fill")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.pink, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("写入一条测试记录").font(.system(size: Typography.body))
                        Text("仅本地记录，用于验证上报链路")
                            .font(.system(size: Typography.caption)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .glassListCard()
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
                .padding(.horizontal, 14).padding(.vertical, 14)
            } else {
                ForEach(events) { e in
                    recordRow(e)
                    if e.id != events.last?.id {
                        Divider().padding(.leading, 52)
                    }
                }
                Divider().padding(.leading, 14)
                clearAllButton
            }
        }
        .glassListCard()
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
            .padding(.vertical, 12)
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
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
            .padding(.horizontal, 14).padding(.vertical, 11)
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
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
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
        .glassListCard()
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
        .padding(.horizontal, 16).padding(.vertical, 14)
        .glassListCard()
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
            events = DiagnosticsStore.historyEvents()
        }
    }

    /// 写入一条测试记录（仅本地 + 队列），用于在真机上验证「记录 → 上报」链路
    private func simulateHang() {
        DiagnosticsEnv.refresh()
        DiagnosticsStore.recordHang(durationMs: hangThreshold + 37,
                                    stack: "(自测记录 · 非真实卡顿)")
        withAnimation(Motion.snap) {
            pendingCount = DiagnosticsStore.pendingCount()
            events = DiagnosticsStore.historyEvents()
        }
        uploadText = "已写入一条测试记录（\(pendingCount) 条待上报）"
        uploadOK = true
    }

    private func bundleText() -> String {
        DiagnosticsPayload.bundleText(env: env, events: events,
                                      backend: pingText, pendingCount: pendingCount)
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
