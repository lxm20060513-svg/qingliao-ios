import SwiftUI

// MARK: - 后端更新（v4.0.19）
//
// 目标：用户花最少成本把自部署后端更到最新。
//   1. App 内置「本版配套的后端最低版本」常量 → 打开设置页自动比对 → 落后时挂提示行
//   2. 点进去：检查更新（/api/selfupdate check）/ 一键更新（run）/ 轮询进度
//
// 链路设计：
//   - /api/version 免鉴权 → 只能比版本号（所有部署都可用）
//   - /api/selfupdate 需鉴权 → 能拿到「落后 N 个提交」并触发更新；
//     老后端（没有该接口）或未配置 QL_REPO_DIR 时自动降级为「展示手动更新命令」，
//     永不把降级当错误打扰用户。
//   - 更新会重启后端容器：轮询期间连接失败视为「正在重启」，持续轮询直到回来或超时。

/// 本 App 版本配套的后端最低版本。发新版 App 时若要求新后端，bump 这里。
let QLCompatibleBackendVersion = "v4.0.15"

enum BackendUpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case available(behind: Int)
    case updating
    case restarting          // run 已发出、后端暂时失联
    case done                // 更新完成、后端已回来
    case failed(String)
}

/// 语义化版本比较："v4.0.9" < "v4.0.13"（按数字段比，非字典序）
func qlCompareBackendVersion(_ a: String, _ b: String) -> Int {
    let nums = { (s: String) -> [Int] in
        s.trimmingCharacters(in: CharacterSet(charactersIn: "v "))
            .split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
    }
    let (xa, xb) = (nums(a), nums(b))
    for i in 0..<max(xa.count, xb.count) {
        let l = i < xa.count ? xa[i] : 0
        let r = i < xb.count ? xb[i] : 0
        if l != r { return l < r ? -1 : 1 }
    }
    return 0
}

@MainActor
@Observable
final class BackendUpdateModel {
    var phase: BackendUpdatePhase = .idle
    var currentVersion = ""      // 后端报的版本（可能为空=未注入）
    var logTail = ""
    var manualCommand = "cd qingliao-backend && ./update.sh"

    private var auth: AuthStore?
    private var pollTask: Task<Void, Never>?

    func bind(_ auth: AuthStore) {
        guard self.auth == nil || self.auth !== auth else { return }
        self.auth = auth
    }

    /// 与 /api/version 快速比对（免鉴权，设置页 .task 里调）
    func quickCheck() async {
        guard let auth else { return }
        phase = .checking
        do {
            let j = try await auth.json("/api/version")
            let ver = (j["version"] as? String) ?? ""
            currentVersion = ver
            if ver.isEmpty {
                // 部署方没注入版本号 → 无法自动判断，静默不动（不打扰）
                phase = .idle
                return
            }
            phase = qlCompareBackendVersion(ver, QLCompatibleBackendVersion) < 0
                ? .available(behind: -1)      // -1 = 具体落后几个提交未知（没问 selfupdate）
                : .upToDate
        } catch {
            phase = .idle                   // 后端连不上 ≠ 需要更新，静默
        }
    }

    /// 精确检查：走 /api/selfupdate（老后端/未配置时降级回 quickCheck 的结论）
    func preciseCheck() async {
        guard let auth else { return }
        // v4.0.19 审查修复②：更新在途（轮询没停）时重开 sheet 不得覆写状态、更不得二次触发 run
        if let pollTask, !pollTask.isCancelled { return }
        if case .updating = phase { return }
        if case .restarting = phase { return }
        phase = .checking
        do {
            let (data, code) = try await auth.request("POST", "/api/selfupdate",
                                                      body: ["action": "check"])
            guard code == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // 404=老后端 / 401=未登录 / 其他：回到版本号比对结论
                await quickCheck()
                return
            }
            if j["ok"] as? Bool == true {
                if j["update_available"] as? Bool == true {
                    phase = .available(behind: (j["behind"] as? Int) ?? -1)
                } else {
                    phase = .upToDate
                }
                logTail = (j["log"] as? String) ?? ""
            } else {
                // 未配置 QL_REPO_DIR 等 → 展示手动命令
                phase = .failed((j["error"] as? String) ?? "无法自动检查")
            }
        } catch {
            await quickCheck()
        }
    }

    /// 一键更新 + 轮询直到后端回来
    func startUpdate() {
        guard case .available = phase else { return }
        pollTask?.cancel()
        phase = .updating
        pollTask = Task { [weak self] in
            guard let self, let auth = self.auth else { return }
            // 轮询收尾迁移统一走这个守卫：只允许从 updating/restarting 迁走，
            // 防止把状态写到已被（重开 sheet 的检查）覆写的 phase 上
            func setPhase(_ new: BackendUpdatePhase) async {
                await MainActor.run {
                    switch self.phase {
                    case .updating, .restarting: self.phase = new
                    default: break
                    }
                }
            }
            do {
                let (data, code) = try await auth.request("POST", "/api/selfupdate",
                                                          body: ["action": "run"])
                guard code == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      j["ok"] as? Bool == true else {
                    let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                        .flatMap { $0["error"] as? String }) ?? "启动更新失败（后端不支持或未配置）"
                    await setPhase(.failed(msg))
                    return
                }
                await setPhase(.restarting)
                // 轮询：后端会重启失联 1~3 分钟；失联=继续等，回来后看版本
                let deadline = Date().addingTimeInterval(8 * 60)
                while Date() < deadline, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    do {
                        let j2 = try await auth.json("/api/version")
                        let ver = (j2["version"] as? String) ?? ""
                        await MainActor.run {
                            guard case .restarting = self.phase else { return }
                            self.currentVersion = ver
                            self.phase = qlCompareBackendVersion(
                                ver, QLCompatibleBackendVersion) < 0
                                ? .failed("后端已恢复但版本仍偏旧（\(ver)），请稍后重试")
                                : .done
                        }
                        return
                    } catch {
                        continue      // 失联中 → 继续轮询
                    }
                }
                await MainActor.run {
                    if case .restarting = self.phase {
                        self.phase = .failed("等待超时：请检查后端容器是否正常，或手动查看更新日志")
                    }
                }
            } catch {
                await setPhase(.failed("网络错误：\(error.localizedDescription)"))
            }
        }
    }
}

// MARK: - 设置页提示行 + 更新弹窗

struct BackendUpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: BackendUpdateModel
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    if case .available(let behind) = model.phase {
                        updateButton(behind: behind)
                    }
                    if case .failed(let msg) = model.phase {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.orange)
                        manualCommandCard
                    }
                    if !model.logTail.isEmpty {
                        logCard
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("后端更新")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await model.preciseCheck() }
        }
    }

    @ViewBuilder private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(statusTitle, systemImage: statusIcon)
                .font(.system(size: Typography.headline, weight: .semibold))
                .foregroundStyle(statusColor)
            Text(statusDetail)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassListCard()
    }

    private var statusTitle: String {
        switch model.phase {
        case .checking: return "正在检查…"
        case .upToDate: return "已是最新 ✅"
        case .available: return "有新版本 🔄"
        case .updating: return "正在更新…"
        case .restarting: return "后端重启中，请稍候…"
        case .done: return "更新完成 🎉"
        case .failed: return "无法自动更新"
        case .idle: return "未检查"
        }
    }
    private var statusIcon: String {
        switch model.phase {
        case .checking, .updating, .restarting: return "arrow.triangle.2.circlepath"
        case .upToDate, .done: return "checkmark.seal.fill"
        case .available: return "arrow.down.circle.fill"
        case .failed: return "wrench.and.screwdriver.fill"
        case .idle: return "info.circle"
        }
    }
    private var statusColor: Color {
        switch model.phase {
        case .available: return .orange
        case .upToDate, .done: return .green
        case .failed: return .red
        default: return .primary
        }
    }
    private var statusDetail: String {
        switch model.phase {
        case .checking:
            return "正在与最新版比对"
        case .upToDate:
            return "当前后端 \(model.currentVersion) 已满足 App \(QLCompatibleBackendVersion) 的要求"
        case .available(let behind) where behind > 0:
            return "当前 \(model.currentVersion)，落后 \(behind) 个提交。更新约需 1–3 分钟，期间后端会短暂失联"
        case .available:
            return "当前 \(model.currentVersion) 低于 App 配套版本 \(QLCompatibleBackendVersion)，建议更新（约 1–3 分钟）"
        case .updating:
            return "已通知后端开始更新，代码拉取与镜像重建中"
        case .restarting:
            return "后端容器正在用新代码重启，通常 1–3 分钟内恢复，请保持页面打开"
        case .done:
            return "后端已运行 \(model.currentVersion)，一切就绪"
        case .failed(let msg):
            return msg + "。也可以在 NAS 上手动执行下方命令更新"
        case .idle:
            return ""
        }
    }

    @ViewBuilder private func updateButton(behind: Int) -> some View {
        Button {
            model.startUpdate()
        } label: {
            HStack {
                Spacer()
                Label(behind > 0 ? "一键更新（\(behind) 个提交）" : "一键更新",
                      systemImage: "arrow.triangle.2.circlepath.circle.fill")
                Spacer()
            }
            .font(.system(size: Typography.body, weight: .semibold))
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
    }

    @ViewBuilder private var manualCommandCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手动更新（在 NAS 的后端仓库目录执行）")
                .font(.system(size: Typography.subhead, weight: .medium))
                .foregroundStyle(.secondary)
            HStack {
                Text(model.manualCommand)
                    .font(.system(size: Typography.subhead, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    UIPasteboard.general.string = model.manualCommand
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: Typography.subhead))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .glassListCard()
    }

    @ViewBuilder private var logCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("更新日志（尾部）")
                .font(.system(size: Typography.subhead, weight: .medium))
                .foregroundStyle(.secondary)
            Text(model.logTail)
                .font(.system(size: Typography.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(12)
        }
        .padding(14)
        .glassListCard()
    }
}

/// 设置页「后端更新」行：落后时橙点提示，点击进更新弹窗
struct BackendUpdateRow: View {
    @Environment(AuthStore.self) var auth
    @State private var model = BackendUpdateModel()
    @State private var showSheet = false

    var body: some View {
        SettingRow(icon: "arrow.triangle.2.circlepath.circle.fill",
                   iconColor: rowColor,
                   title: "后端更新",
                   value: rowValue,
                   chevron: true)
            .tapButton { showSheet = true }
            .sheet(isPresented: $showSheet) {
                BackendUpdateSheet(model: model)
            }
            .task {
                model.bind(auth)
                await model.quickCheck()
            }
    }

    private var rowColor: Color {
        if case .available = model.phase { return .orange }
        if case .upToDate = model.phase { return .green }
        return .teal
    }
    private var rowValue: String {
        switch model.phase {
        case .available: return "有新版本"
        case .upToDate: return "最新"
        case .updating, .restarting: return "更新中"
        case .done: return "已完成"
        case .checking: return "检查中"
        default: return model.currentVersion.isEmpty ? "" : model.currentVersion
        }
    }
}
