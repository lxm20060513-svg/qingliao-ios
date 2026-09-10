import SwiftUI

// MARK: - v3.0.18 设备一键体检（后端 /api/nas/diagnose 六维诊断）

/// 单条体检项（与后端 _collect_diagnose 结构一致）
struct DiagnoseItem: Identifiable {
    let id: String
    let name: String
    let status: String      // ok / warn / error
    let detail: String
    let advice: String
}

/// 一键体检卡片：未检 → 按钮；检查中 → 转圈；完成 → 等级行 + 明细列表
/// 拆独立文件/视图：防 DashboardView 巨型 body type-check 超时
struct DiagnoseCard: View {
    let items: [DiagnoseItem]
    let level: String        // ok / warn / error
    let summary: String
    let error: String
    let diagnosing: Bool
    let onRun: () -> Void

    @State private var expanded = true

    private var iconName: String {
        switch level {
        case "ok": return "checkmark.seal.fill"
        case "warn": return "exclamationmark.triangle.fill"
        default: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch level {
        case "ok": return .green
        case "warn": return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if diagnosing {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(Color.accentColor)
                    Text("体检中…")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 6)
            } else if !error.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 6)
            } else if items.isEmpty {
                Button {
                    onRun()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "stethoscope.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(LinearGradient(colors: [.blue, .indigo, .pink],
                                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("一键体检")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text("检查服务 / 磁盘 / 容器 / 负载 / 内存 / 温度")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            } else {
                // 已完成：等级行
                Button {
                    withAnimation(Motion.snap) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: iconName)
                            .font(.system(size: 22))
                            .foregroundStyle(tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level == "ok" ? "设备状态良好" : (level == "warn" ? "有需要留意的项" : "有异常需要处理"))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)

                if expanded {
                    ForEach(items) { item in
                        DiagnoseRow(item: item)
                    }
                }

                Button {
                    onRun()
                } label: {
                    Label("重新体检", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
    }
}

/// 单条体检项：状态色点 + 名称 + 明细；warn/error 显示建议
struct DiagnoseRow: View {
    let item: DiagnoseItem

    private var tint: Color {
        switch item.status {
        case "ok": return .green
        case "warn": return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(item.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            if item.status != "ok" && !item.advice.isEmpty {
                Text("💡 " + item.advice)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
            }
        }
        .padding(.vertical, 3)
    }
}