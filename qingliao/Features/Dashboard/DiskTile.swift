import SwiftUI

struct DiskTile: View {
    let disk: NASDisk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(shortName)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(disk.pctText)
                    .font(.system(size: Typography.subhead, weight: .bold))
                    .foregroundStyle(disk.pct > 90 ? .red : (disk.pct > 75 ? .orange : .primary))
            }
            Text(disk.pctText)
                .font(.system(size: Typography.headline, weight: .bold))
                .padding(.top, Spacing.sm)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: .systemGray5))
                    Capsule()
                        .fill(disk.pct > 90 ? Color.red : (disk.pct > 75 ? Color.orange : Color.green))
                        .frame(width: geo.size.width * min(max(disk.pct / 100.0, 0), 1))
                }
            }
            .frame(height: 4)
            .padding(.top, Spacing.md)
            Text("\(disk.usedText) / \(disk.totalText)")
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.tertiary)
                .padding(.top, Spacing.xs)
        }
        .padding(Spacing.xl)
        .dashboardCard()
    }

    /// 挂载点短名（/dev/mapper/... → volume1）
    private var shortName: String {
        let parts = disk.mnt.split(separator: "/").filter { !$0.isEmpty }
        return parts.last.map(String.init) ?? disk.mnt
    }
}
