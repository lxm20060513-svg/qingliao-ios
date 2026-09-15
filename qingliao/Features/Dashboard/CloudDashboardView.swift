import SwiftUI

// MARK: - v3.0 云端模式看板：只保留天气（直连 Open-Meteo，无需服务器）+ 其余待开发占位

struct CloudDashboardView: View {
    @Environment(ChatStore.self) private var chat
    @State private var temp: Double?
    @State private var code: Int?
    @State private var city = UserDefaults.standard.string(forKey: "qingliao_weather_city") ?? ""
    @State private var loading = true
    @State private var errorText: String?
    // v3.9.25：徽章点击 → 天气弹窗（原来弹的是 220pt 换城市小弹窗；换城市入口已挪进弹窗右上角）
    @State private var showWeatherSheet = false
    // v3.9.25：weatherURL / geocodeURL 常量随取数一起搬进 WeatherService（此处不再需要）

    var body: some View {
        VStack(spacing: 0) {
            // v3.0.1：天气与本地 AI 同位置——右上角 WeatherBadge（小图标+温度+城市）
            // v3.9.25：点击改为打开天气弹窗（与本地模式一致），换城市入口在弹窗内
            PageHeader(title: "看板",
                       subtitle: "云端模式",
                       trailing: AnyView(
                           Button {
                               showWeatherSheet = true
                           } label: {
                               WeatherBadge(temp: temp, code: code, city: city)
                           }
                           .buttonStyle(PressStyle(scale: 0.94))
                           .accessibilityLabel("查看天气")
                       ))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // v3.0.27：用量统计卡片
                    UsageStatsCard(chat: chat)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
        .task { await loadWeather() }
        // v3.9.25：天气弹窗（两页：今天 / 未来 5 天），与本地模式同一组件；换城市在弹窗右上角。
        // 原 220pt「设置天气城市」小弹窗已删除。注：设置页「天气」分组仍可改城市（既有入口，
        // 本次未动；改后本页不自动刷新，属既有缺口，另行排期）
        .sheet(isPresented: $showWeatherSheet, onDismiss: {
            // v3.9.25：重读城市（含**清空**场景 —— 原写法 `if !c.isEmpty` 会吞掉清空，
            // 用户清掉城市后徽章仍显示旧城市天气）；空城市由 fetchCloud 回提示文案
            city = UserDefaults.standard.string(forKey: "qingliao_weather_city") ?? ""
            Task { await loadWeather() }
        }) {
            WeatherSheet(mode: .cloud)
                .presentationDetents([.height(585)])
                .presentationDragIndicator(.visible)
        }
    }

    /// 直连 Open-Meteo（geocode → current + daily）。
    /// v3.9.25：取数与解析搬到 WeatherService（徽章与弹窗共用一份）；旧版用的是
    /// `current_weather=true`，既不返回 daily 也拿不到新字段 —— 5 天预报必需新参数。
    private func loadWeather() async {
        loading = true
        errorText = nil
        let (snap, err) = await WeatherService.fetchCloud(city: city)
        // v3.9.25：失败/清空城市时必须显式清 nil —— 只在成功赋值会让徽章挂着上一座城市的温度，
        // 而城市名已经清空，看起来就是「一个没有城市的旧温度」
        temp = snap?.temp
        code = snap?.code
        if let c = snap?.city, !c.isEmpty { city = c }
        errorText = err.isEmpty ? nil : err
        loading = false
    }
}

// MARK: - v3.0.27 用量统计卡片

struct UsageStatsCard: View {
    let chat: ChatStore
    @State private var sessionCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.blue)
                Text("用量统计")
                    .font(.system(size: Typography.body, weight: .semibold))
                Spacer()
            }

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 10) {
                StatCell(title: "当前消息", value: "\(chat.messages.count)", icon: "message.fill")
                StatCell(title: "估算 Token", value: "\(chat.contextInfo.tokens)", icon: "cpu.fill")
                StatCell(title: "历史会话", value: "\(sessionCount)", icon: "folder.fill")
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))   // v3.8.1：云端看板统计卡圆角 14 → 16，与本地看板一致
        .task {
            await loadStats()
        }
    }

    private func loadStats() async {
        // 从 CloudSessionStore 读取会话数（v-review fix：totalMessages 赋值后从未被读取，已删）
        let store = CloudSessionStore.shared
        store.load()
        sessionCount = store.sessions.count
    }
}

private struct StatCell: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: Typography.title))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: Typography.title, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(title)
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))   // v3.8.1：10 → 16，与看板卡片统一
    }
}
