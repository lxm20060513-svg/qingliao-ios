import SwiftUI

enum QLServiceKind: String {
    case qingliao, hermes

    var title: String {
        switch self {
        case .qingliao: return "轻聊后端"
        case .hermes: return "Hermes 网关"
        }
    }

    var icon: String {
        switch self {
        case .qingliao: return "server.rack"
        case .hermes: return "sparkles"
        }
    }

    var subtitle: String {
        switch self {
        case .qingliao: return "轻聊后端服务"
        case .hermes: return "Hermes 网关服务"
        }
    }

    var restartBody: [String: Any] { ["service": rawValue] }
}

struct ServiceControlSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    let service: QLServiceKind

    @State private var busy = false
    @State private var info: String
    @State private var running: Bool?   // 真实运行状态
    @State private var showStopConfirm = false

    init(service: QLServiceKind) {
        self.service = service
        _info = State(initialValue: service == .qingliao ? "管理轻聊后端服务" : "管理 Hermes 网关服务")
    }

    var body: some View {
        VStack(spacing: 0) {
            serviceHeader

            serviceInfoCard

            serviceRetryCard

            serviceStopCard

            Spacer()
        }
    }

    // MARK: - v4.0.x ServiceControlSheet 分区（巨型 body 拆分）
    //
    // 由头：此 body 单块 145 行，是本仓已踩过两次的「Unable to type-check this
    // expression in reasonable time」高危形态（一次漏检 = 20 分钟 CI 循环）。
    // 停止卡那段尤其重：Button label 内 HStack + 链式 overlay，且尾部还挂着
    // confirmationDialog（带闭包的修饰符留在块内，不留在调用点）。
    // 这里每个栏目原样搬成独立 @ViewBuilder 属性 —— **纯搬运**：视图顺序、层级、
    // 条件分支、闭包、修饰符逐字未变，渲染结果与拆分前一致。

    /// 弹窗头部：标题 + 关闭键
    @ViewBuilder
    private var serviceHeader: some View {
    HStack {
        Text(service.title)
            .font(.system(size: Typography.title, weight: .bold))
        Spacer()
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: Typography.titleXL))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
    }
    .padding(.horizontal, 18)
    .padding(.top, 18)
    .padding(.bottom, Spacing.xl)
    }

    /// 服务信息卡：图标 + 状态灯（首屏拉 /api/nas/status）
    @ViewBuilder
    private var serviceInfoCard: some View {
    // 服务信息卡
    HStack(spacing: 12) {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                .fill(Color.blue.opacity(Tint.soft))
            Image(systemName: service.icon)
                .font(.system(size: Typography.headline, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: 42, height: 42)

        VStack(alignment: .leading, spacing: 3) {
            Text(service.subtitle)
                .font(.system(size: Typography.body, weight: .semibold))
            Text(info)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        Spacer()
        HStack(spacing: Spacing.xs) {
            Circle()
                .fill(running == true ? Color.green : (running == false ? Color.red : Color.gray))
                .frame(width: 7, height: 7)
            Text(running == true ? "运行中" : (running == false ? "已停止" : "检测中"))
                .font(.system(size: Typography.tiny, weight: .semibold))
                .foregroundStyle(running == true ? Color.green : (running == false ? Color.red : Color.secondary))
        }
    }
    .padding(Spacing.xxl)
    .background(Color(uiColor: .secondarySystemGroupedBackground))  // v2.0.87h：弹窗玻璃下扁平化
    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    .padding(.horizontal, Spacing.section)
    .task {
        // 真实运行状态
        if let n = await auth.jsonOrLog("/api/nas/status") {
            let st = NASStatus.parse(n)
            running = service == .qingliao ? st.qingliaoAlive : st.hermesAlive
        }
    }
    }

    /// 重试（重启）卡
    @ViewBuilder
    private var serviceRetryCard: some View {
    // 重试卡
    Button {
        restart()
    } label: {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor)
                if busy {
                    ProgressView().tint(.white).scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: Typography.body, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("重试服务")
                    .font(.system(size: Typography.body, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(service == .qingliao ? "重启轻聊后端进程" : "重启 Hermes 网关进程")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(Spacing.xxl)
        .background(Color(uiColor: .secondarySystemGroupedBackground))  // v2.0.87h：弹窗玻璃下扁平化
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
    .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
    .padding(.horizontal, Spacing.section)
    .padding(.top, Spacing.lg)
    }

    /// 停止服务卡 + 停止确认（仅轻聊后端，Hermes 网关不支持停止）
    @ViewBuilder
    private var serviceStopCard: some View {
    // 停止卡（Hermes 网关不支持停止，隐藏）
    if service == .qingliao {
        Button {
            showStopConfirm = true
        } label: {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.red.opacity(Tint.soft))
                Image(systemName: "stop.fill")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.red)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("停止服务")
                    .font(.system(size: Typography.body, weight: .semibold))
                    .foregroundStyle(.red)
                Text("停止后轻聊将不可用")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(Spacing.xxl)
        .background(Color.red.opacity(Tint.faint))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.red.opacity(Tint.strong), lineWidth: 1)
        )
    }
    .buttonStyle(PressStyle())   // v3.4.29：统一按压反馈
    .padding(.horizontal, Spacing.section)
    .padding(.top, Spacing.lg)
    .confirmationDialog("停止后轻聊将完全不可用，需在 NAS 上手动启动", isPresented: $showStopConfirm, titleVisibility: .visible) {
        Button("停止服务", role: .destructive) {
            stopService()
        }
        Button("取消", role: .cancel) {}
    }
    }
    }

    private func restart() {
        guard !busy else { return }
        busy = true
        info = "正在重启服务..."
        Task {
            defer { busy = false }
            do {
                _ = try await auth.request("/api/nas/service/restart", method: "POST",
                                           body: service.restartBody)
                info = "重试指令已发送，服务即将重启"
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled { dismiss() }
                }
            } catch {
                info = "发送失败，请检查连接"
            }
        }
    }

    private func stopService() {
        guard !busy else { return }
        busy = true
        info = "正在停止服务..."
        Task {
            defer { busy = false }
            do {
                _ = try await auth.request("/api/nas/service/stop", method: "POST",
                                           body: service.restartBody)
                info = "停止指令已发送"
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if !Task.isCancelled { dismiss() }
                }
            } catch {
                info = "发送失败，请检查连接"
            }
        }
    }
}

// MARK: - HA 设备控制 sheet（HomeKit 风格：灯=卡片网格 / 空调=模式控制卡）

