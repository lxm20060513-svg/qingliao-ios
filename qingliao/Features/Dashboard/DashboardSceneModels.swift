import SwiftUI

struct SceneItem: Identifiable {
    let id: String
    let name: String
    let actionCount: Int
    init(_ d: [String: Any]) {
        name = d["name"] as? String ?? ""
        id = name
        actionCount = (d["actions"] as? [[String: Any]])?.count ?? 0
    }
}

// MARK: - v2.0.104 定时自动化（倒计时卡片）

/// v3.9.21：自动规则一行（名称 + 条件摘要 + 开关；长按删除）

struct RuleRow: View {
    let item: RuleItem
    var onToggle: (Bool) -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.enabled ? "bolt.badge.clock.fill" : "bolt.slash")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(item.enabled ? Color.orange : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: Typography.subhead, weight: .medium))
                Text(subtitle)
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Toggle("", isOn: Binding(get: { item.enabled }, set: { onToggle($0) })).qingliaoSwitch(color: .orange)
        }
        .padding(.vertical, Spacing.xxs)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) { onDelete() } label: { Label("删除规则", systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)，\(item.enabled ? "已启用" : "已停用")，条件 \(item.summary)")
    }

    private var subtitle: String {
        var s = item.summary
        if let lr = item.lastRun {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            s += " · 上次 " + f.string(from: lr)
        } else if item.runCount == 0 {
            s += " · 未触发过"
        }
        return s
    }
}


struct AutomationItem: Identifiable {
    let id: String
    let name: String
    let remaining: Int
    let runAt: Date
    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? UUID().uuidString
        name = d["name"] as? String ?? "自动化"
        remaining = (d["remaining"] as? Int) ?? 0
        runAt = Date(timeIntervalSince1970: ((d["run_at"] as? Double) ?? 0))
    }
}

// MARK: - 磁盘磁贴（与 DeviceCard/MeterCard 同款 HomeKit 卡片风格）

