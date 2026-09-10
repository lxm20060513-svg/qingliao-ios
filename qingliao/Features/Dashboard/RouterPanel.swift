import SwiftUI

// MARK: - 路由器面板（状态 + Clash 快捷指令，风格对齐 NAS 卡）

struct RouterStatus {
    var ok = false
    var hostname = "--"
    var load = "--"
    var cpuPct = 0.0
    var uptime = "--"
    var memTotal = 0.0
    var memFree = 0.0
    var temp = "--"
    var clashRunning = false
    var onlineDevices = 0   // v2.0.37：在线设备数（替代 hostname 显示）
    var error = ""
    var busy = false

    var memUsedText: String {
        String(format: "%.1fG / %.1fG", memTotal - memFree, memTotal)
    }
    var memPct: Double {
        memTotal > 0 ? (memTotal - memFree) / memTotal : 0
    }

    static func parse(_ j: [String: Any]) -> RouterStatus {
        var r = RouterStatus()
        r.ok = (j["ok"] as? Bool) ?? false
        r.hostname = j["hostname"] as? String ?? "--"
        r.load = j["load"] as? String ?? "--"
        r.cpuPct = j["cpu_pct"] as? Double ?? 0
        r.uptime = j["uptime"] as? String ?? "--"
        r.memTotal = j["mem_total_gb"] as? Double ?? 0
        r.memFree = j["mem_free_gb"] as? Double ?? 0
        r.temp = j["temp"] as? String ?? "--"
        r.clashRunning = (j["clash_running"] as? Bool) ?? false
        r.onlineDevices = (j["online_devices"] as? Int) ?? 0
        r.error = j["error"] as? String ?? ""
        return r
    }

    static func merge(_ old: RouterStatus, with j: [String: Any]) -> RouterStatus {
        var r = old
        if let ok = j["ok"] as? Bool { r.ok = ok }
        if let cr = j["clash_running"] as? Bool { r.clashRunning = cr }
        if let e = j["error"] as? String, !e.isEmpty { r.error = e }
        return r
    }
}

/// 路由器板块：NAS 同款卡片风格（MeterCard/ServiceCard）+ Clash 弹窗操作
struct RouterPanel: View {
    let router: RouterStatus
    var onStart: (() -> Void)? = nil
    var onStop: (() -> Void)? = nil
    var onRefresh: (() -> Void)? = nil

    @State private var showClashSheet = false
    // v2.0.65：状态点呼吸动画（在线时呼吸）
    @State private var breathe = false

    var body: some View {
        VStack(spacing: 8) {
            // 标题行：路由器 + 在线设备数（v2.0.37 替代 hostname）+ 状态点
            HStack(spacing: 6) {
                Text("📡 路由器")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(router.onlineDevices) 台在线")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(router.ok ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                    // v2.0.65：在线时呼吸（2s 循环透明度）
                    .opacity(router.ok ? (breathe ? 1.0 : 0.35) : 1.0)
                    .animation(router.ok ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : Motion.flow,
                               value: breathe)
                    .onAppear { breathe = true }
                Spacer()
                Button {
                    onRefresh?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(router.busy)
            }

            // 2x2 指标卡（同 NAS 面板 MeterCard/ServiceCard 风格）
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                MeterCard(name: "CPU", icon: "cpu.fill", value: String(format: "%.1f%%", router.cpuPct),
                          sub: "使用率", ratio: router.cpuPct / 100.0, color: .blue)
                MeterCard(name: "内存", icon: "memorychip.fill", value: router.memUsedText,
                          sub: "/ \(String(format: "%.1fG", router.memTotal))", ratio: router.memPct, color: .green)
                ServiceCard(name: "运行时间", icon: "clock.fill", running: true, detail: router.uptime)
                // Clash 卡：点击弹窗（同智能家居开关卡交互）
                ServiceCard(name: "Clash", icon: "bolt.shield.fill", running: router.clashRunning,
                            detail: router.clashRunning ? "代理已生效 · 点击管理" : "已停止 · 点击管理")
                    .onTapGesture { showClashSheet = true }
            }
            // v2.0.92：Clash 操作失败原因（后端以"服务已启动"输出为准，失败会带原因）
            if !router.error.isEmpty {
                Text(router.error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showClashSheet) {
            ClashSheet(router: router, onStart: { onStart?() }, onStop: { onStop?() })
                .presentationDetents([.height(240)])
        }
    }
}

/// Clash 管理弹窗（两张操作卡：打开 / 关闭）
struct ClashSheet: View {
    @Environment(\.dismiss) private var dismiss
    let router: RouterStatus
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("⚡ Clash 管理")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Circle()
                    .fill(router.clashRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(router.clashRunning ? "运行中" : "已停止")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                // 打开 Clash
                Button {
                    dismiss()
                    Task { try? await Task.sleep(for: .seconds(0.3)); onStart() }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                        Text("打开 Clash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("开启代理加速")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(router.busy)

                // 关闭 Clash
                Button {
                    dismiss()
                    Task { try? await Task.sleep(for: .seconds(0.3)); onStop() }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                        Text("关闭 Clash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("恢复直连")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(router.busy)
            }
            Spacer()
        }
        .padding(18)
        .padding(.top, 6)

    }
}
