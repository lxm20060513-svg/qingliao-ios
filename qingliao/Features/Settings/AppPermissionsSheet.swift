import SwiftUI
import UIKit

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
                ToolbarItem(placement: .confirmationAction) {
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
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(Color.accentColor)
                Text("允许 AI 操作我的数据")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                Spacer()
                Toggle("", isOn: $masterOn)
                    .labelsHidden()
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
        .glassListCard()
    }

    // MARK: 单项能力

    @ViewBuilder
    private func capabilityCard(_ cap: AppCapability) -> some View {
        let st = states[cap] ?? .notDetermined
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 12) {
                Image(systemName: cap.sfSymbol)
                    .foregroundStyle(cap.aiControllable ? Color.accentColor : .secondary)
                    .frame(width: 22)
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
                    ))
                    .labelsHidden()
                    .disabled(!masterOn || st != .granted)
                }
            }
        }
        .padding(Spacing.lg)
        .glassListCard()
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
            · 提醒事项（Reminders）：Apple 未开放任何接口，只能跳转系统 App 由你手点。
            · 微信等第三方 App 的数据：同样无接口，只能跳转打开。
            · 家庭（HomeKit）：需开发者证书授权，侧载安装无法使用。
            · AI 读取你的数据前，需要你先在系统里授权对应 App。
            """)
            .font(.system(size: Typography.caption))
            .foregroundStyle(.secondary)
        }
        .padding(Spacing.lg)
        .glassListCard()
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
