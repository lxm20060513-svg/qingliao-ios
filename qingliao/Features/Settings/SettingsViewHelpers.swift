import SwiftUI
import LocalAuthentication

// MARK: - 共用组件（toggle 行 / Siri 滑条）

extension SettingsView {

    func toggleRow(icon: String, iconColor: Color, title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(iconColor, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
            if let subtitle {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title).font(.system(size: Typography.body, weight: .medium))
                    Text(subtitle).font(.system(size: Typography.caption)).foregroundStyle(.tertiary)
                }
            } else {
                Text(title).font(.system(size: Typography.body)).foregroundStyle(.primary)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().scaleEffect(0.8).tint(.green)
        }
        .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.lg)
    }
}

// MARK: - 辅助函数

extension SettingsView {

    /// v2.0.117：加载本地模型状态（容器 + 已装模型）——后端为源：
    /// v-review fix：依据 /api/local/status 的 container 状态回写开关，防 UI 与后端脱钩
    func loadLocalStatus() async {
        if let j = try? await auth.json("/api/local/status") {
            let up = (j["container"] as? String) == "up"
            let models = (j["models"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "" }
            if up {
                localStatusText = "运行中" + (models.isEmpty ? "" : " · " + models.prefix(2).joined(separator: " / "))
            } else {
                localStatusText = "已停止（点开关开启）"
            }
            // 回写开关（加守卫防 onChange 回声 POST 循环）
            if localModelOn != up {
                localModelSyncing = true
                localModelOn = up
                localModelSyncing = false
            }
        } else {
            localStatusText = "状态获取失败"
        }
    }

    /// v2.0.117：检查模型更新
    func checkLocalUpdate() async {
        guard !localChecking else { return }
        localChecking = true
        defer { localChecking = false }
        if let j = try? await auth.json("/api/local/check-update") {
            localUpdateText = (j["message"] as? String) ?? "检查完成"
        } else {
            localUpdateText = "检查失败，请稍后重试"
        }
    }

    /// v2.0.102：加载凭据/记忆计数（设置页行尾显示）
    func loadCounts() async {
        if let j = try? await auth.json("/api/secrets") {
            secretCount = (j["secrets"] as? [Any])?.count ?? 0
        }
        if let j = try? await auth.json("/api/memory/list") {
            memoryCount = (j["entries"] as? [String] ?? []).count
        }
        // v2.0.113：同步微信推送开关（后端为准）
        if let j = try? await auth.json("/api/push/settings"),
           let v = j["pushWeixin"] as? Bool {
            pushWeixin = v
        }
        // v2.0.113：Agent 记忆条数（行尾数字）
        if let j = try? await auth.json("/api/agent/rules") {
            agentRuleCount = (j["rules"] as? [Any] ?? []).count
        }
    }

    var appearanceName: String {
        switch appearance {
        case "light": return "浅色"
        case "system": return "跟随系统"
        default: return "深色"
        }
    }

    /// 当前默认模型（UserDefaults）
    var currentModel: String {
        UserDefaults.standard.string(forKey: "qingliao_model") ?? "deepseek-v4-flash"
    }

    // v3.0.19：微信通道当前模型（UserDefaults 缓存，进弹窗时刷新）
    var wechatChannelModel: String {
        UserDefaults.standard.string(forKey: "qingliao_wechat_channel_model") ?? "跟随默认"
    }

    /// v2.0.89f：打开 Face ID 开关时立即申请系统权限（用户实测"点开关没有权限申请"）
    func requestFaceIDAuth() {
        let context = LAContext()
        var err: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            faceIDLogin = false   // 设备不支持/已被拒绝 → 回滚开关
            faceIDAuthFailed = true
            return
        }
        context.localizedReason = "用于登录页一键登录轻聊"
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "用于登录页一键登录轻聊") { success, error in
            DispatchQueue.main.async {
                if success { return }
                // v2.0.102：用户主动取消（userCancel）不算失败——保留开关不弹提示
                if let la = error as? LAError, la.code == .userCancel { return }
                // 拒绝/系统错误 → 回滚开关，提示去系统设置开启
                faceIDLogin = false
                faceIDAuthFailed = true
            }
        }
    }

    /// v2.0.92：打开 App 锁开关时申请权限（逻辑同 Face ID 登录）
    func requestAppLockAuth() {
        let context = LAContext()
        var err: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            appLockOn = false
            appLockAuthFailed = true
            return
        }
        context.localizedReason = "用于启动时解锁轻聊"
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "用于启动时解锁轻聊") { success, error in
            DispatchQueue.main.async {
                if success { return }
                // v2.0.102：用户主动取消不算失败——保留开关不弹提示
                if let la = error as? LAError, la.code == .userCancel { return }
                appLockOn = false
                appLockAuthFailed = true
            }
        }
    }
}

// MARK: - v3.9.56 TypeSafe 智能路由（读回来显示 + 改完回写；后端是唯一真源）

extension SettingsView {

    /// 开关绑定。set 里先动 UI（开关手感不等网络），POST 失败再拉回后端现状
    /// —— 防「开关显示 ON 但后端其实没开」这种脱钩（同 localModelToggle 的处置）。
    var tsEnabledBinding: Binding<Bool> {
        Binding(
            get: { tsRouting.enabled },
            set: { new in
                tsRouting.enabled = new
                guard !tsSyncing else { return }   // 读回来造成的写入不回写（否则回声 POST 循环）
                Task { await saveTypesafeRouting(["enabled": new]) }
            }
        )
    }

    /// 阈值绑定（每步一次 POST；后端改配置免重启，即时生效）
    var tsThresholdBinding: Binding<Double> {
        Binding(
            get: { tsRouting.threshold },
            set: { new in
                tsRouting.threshold = new
                guard !tsSyncing else { return }
                Task { await saveTypesafeRouting(["threshold": new]) }
            }
        )
    }

    /// 读后端真实状态（进设置页 / 熔断轮询 / 保存失败回滚，都走这一处）
    func loadTypesafeRouting() async {
        guard let j = try? await auth.json("/api/agent/typesafe/routing") else {
            tsError = "状态获取失败，请检查连接后重进本页"
            return
        }
        applyTypesafeRouting(j)
    }

    /// 把后端响应整体写进影子状态；解析失败的那一段保留上一次的值（不拿兜底值冒充后端现状）
    func applyTypesafeRouting(_ j: [String: Any]) {
        tsSyncing = true
        if let raw = j["routing"] as? [String: Any], let cfg = TypesafeRouting(json: raw) {
            tsRouting = cfg
        }
        if let raw = j["breaker"] as? [String: Any] {
            tsBreaker = TypesafeBreaker(json: raw) ?? .closed
        }
        tsSyncing = false
        tsError = ""
    }

    /// 回写（部分字段补丁）：成功以响应为准刷新；失败拉回后端现状 + 红字，绝不留下假状态。
    func saveTypesafeRouting(_ patch: [String: Any]) async {
        guard !tsBusy else { return }
        tsBusy = true
        defer { tsBusy = false }
        do {
            let j = try await auth.json("/api/agent/typesafe/routing", method: "POST", body: patch)
            if (j["ok"] as? Bool) == false {
                tsError = (j["error"] as? String) ?? "保存失败"
                await loadTypesafeRouting()
            } else {
                applyTypesafeRouting(j)
            }
        } catch {
            tsError = "保存失败，请检查连接"
            await loadTypesafeRouting()
        }
    }

    /// 参数区小胶囊。选中 = 主题色淡底 + 同色文字 + 0.8pt 同色细描边；未选中 = 中性淡底
    /// —— 走 v3.9.35「三件套」口径，不用实色胶囊（用户明确否决过实色）。
    func tsCapsule(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.sm)
                .background(on ? Color.accentColor.opacity(Tint.subtle) : Color.primary.opacity(Tint.faint),
                            in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Color.accentColor.opacity(0.28)
                                                   : Color.secondary.opacity(0.22),
                                                lineWidth: 0.8))
        }
        .buttonStyle(PressStyle())
    }
}
