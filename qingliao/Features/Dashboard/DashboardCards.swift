import SwiftUI

enum DeviceStatus { case on, off, warn }

struct DeviceCard: View {
    let name: String
    let icon: String   // v2.0.85e 图标
    let value: String
    let sub: String
    let status: DeviceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(status == .on ? Color.accentColor : Color.secondary)
                    .symbolEffect(.bounce, value: status)   // v3.9.0：设备开关状态变化弹一下
                Text(name)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.6), radius: 4)
            }
            Text(value)
                .font(.system(size: Typography.headline, weight: .bold))
                .padding(.top, Spacing.sm)
            Text(sub)
                .font(.system(size: Typography.tiny))
                .foregroundStyle(.tertiary)
                .padding(.top, Spacing.xxs)
        }
        .padding(Spacing.xl)
        .dashboardCard()
        .scrollDepth()   // v3.9.0：滚动层次感
    }

    private var color: Color {
        switch status {
        case .on: .green
        case .off: .gray
        case .warn: .orange
        }
    }
}

struct MeterCard: View {
    let name: String
    let icon: String   // v2.0.85c 图标
    let value: String
    let sub: String?
    let ratio: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(color)
                Text(name).font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                Spacer()
                // 真实状态点：按使用率阈值（<75% 绿 / 75-90% 橙 / >90% 红）
                Circle()
                    .fill(ratio > 0.9 ? Color.red : (ratio > 0.75 ? Color.orange : Color.green))
                    .frame(width: 8, height: 8)
            }
            Text(value)
                .font(.system(size: Typography.headline, weight: .bold).monospacedDigit())   // v3.9.19：等宽数字
                .contentTransition(.numericText())            // v3.4.29：数值滚动而非硬跳
                .animation(Motion.snap, value: value)
                .padding(.top, Spacing.sm)
            if let sub {
                Text(sub)
                    .font(.system(size: Typography.tiny))
                    .foregroundStyle(.tertiary)
                    .padding(.top, Spacing.xxs)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: .systemGray5))
                    Capsule().fill(color).frame(width: geo.size.width * min(max(ratio, 0), 1))
                }
            }
            .frame(height: 4)
            .padding(.top, Spacing.md)
        }
        .padding(Spacing.xl)
        // v2.0.83：NAS 面板卡片等高（与 ServiceCard 同高，进度条自适应剩余空间）
        // v2.0.86b：卡片统一再矮一点
        .frame(height: 88, alignment: .top)
        .dashboardCard()
        .scrollDepth()   // v3.9.0：滚动层次感
    }
}

struct ServiceCard: View {
    let name: String
    let icon: String   // v2.0.85c 图标
    let running: Bool
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(running ? Color.green : Color.red)
                    .symbolEffect(.bounce, value: running)   // v3.9.0：服务启停弹一下
                Text(name).font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(running ? Color.green : Color.red).frame(width: 8, height: 8)
            }
            Text(running ? "运行中" : "已停止")
                .font(.system(size: Typography.body, weight: .bold))
                .padding(.top, Spacing.sm)
            Text(detail).font(.system(size: Typography.tiny)).foregroundStyle(.tertiary).padding(.top, Spacing.xxs)
        }
        .padding(Spacing.xl)
        // v2.0.83：NAS 面板卡片等高（与 MeterCard 同高）
        // v2.0.86b：卡片统一再矮一点
        .frame(height: 88, alignment: .top)
        .dashboardCard()
        .scrollDepth()   // v3.9.0：滚动层次感
    }
}

// MARK: - v2.0.87u 天气徽章（右上角小图标 + 温度）

struct WeatherBadge: View {
    let temp: Double?
    let code: Int?
    var city = ""   // v2.0.87ag：具体地点

    // v3.9.25：WMO 映射统一到 WeatherService（原先图标/颜色只写在这里，中文描述写在
    // 原云端工具器，已移除）。除 85/86 阵雪由 default 的 cloud.fill 修正为
    // cloud.snow.fill（与「阵雪」描述对齐）外逐字照搬，颜色未动。
    private var icon: String { WeatherCode.symbol(code) }
    private var iconColor: Color { WeatherCode.color(code) }

    var body: some View {
        // v2.0.87x：胶囊下方标注"当前定位"（v2.0.87ab：去掉胶囊内定位图标，更简洁）
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(iconColor)
                if let t = temp {
                    Text(String(format: "%.0f°", t))
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.primary)
                } else {
                    Text("--°")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.6))
            // v2.0.87aj：只显示城市名（去掉"当前定位"前缀）
            if !city.isEmpty {
                Text(city)
                    .font(.system(size: Typography.tiny, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

