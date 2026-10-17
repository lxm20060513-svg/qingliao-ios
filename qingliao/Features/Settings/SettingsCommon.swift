// 本文件由 2026-09-27 工程治理「Settings 物理合并」生成：多份同域设置页文件合并为一，
// UI 入口与行为零改动，仅文件边界变化。合并前各文件的来源见下方 MARK 分段。

import Combine
import Foundation
import LocalAuthentication
import PDFKit
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: ===== 以下原为 Features/Settings/SettingsSheets.swift =====

// MARK: - 设置二级 Sheet（v3.0.80 自 SettingsView.swift 拆出，纯搬家无逻辑改动）
// 内容：服务器地址 / 钉一钉路径 / 修改密码 / 通用行组件 / 会话存储位置


// MARK: - 服务器地址修改

struct ServerSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var server = ""
    @State private var saved = false
    @State private var validationError: String?

    /// 校验服务器地址格式（host:port 或 URL；端口 1-65535）
    private func validate(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "请输入服务器地址" }
        let stripped = s.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        let parts = stripped.split(separator: ":")
        if parts.count > 2 {
            // v-review fix：冒号多于 1 段 → IPv6 字面量地址（fe80::1 / fe80::1:8123 等），
            // 不再按 host:port 拆分拒绝；仅做基本的非空/无空白与路径校验
            let ipv6 = stripped.trimmingCharacters(in: .whitespaces)
            guard !ipv6.isEmpty else { return "主机名不能为空" }
            if ipv6.contains(" ") || ipv6.contains("/") {
                return "IPv6 地址格式非法"
            }
            return nil
        }
        let host = String(parts[0]).trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return "主机名不能为空" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        if host.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "主机名含非法字符"
        }
        if parts.count == 2 {
            let portStr = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard let port = Int(portStr), port >= 1, port <= 65535 else {
                return "端口号须为 1-65535"
            }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("修改后需重新登录")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.sheetInset)
                    .padding(.top, Spacing.xs)

                TextField("server.example.com:8080", text: $server)
                    .font(.system(size: Typography.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(Spacing.xl)
                    .pastelFill(cornerRadius: Radius.inset)
                    .padding(.horizontal, Spacing.sheetInset)
                    .padding(.top, Spacing.xxl)
                    .onChange(of: server) { _, _ in validationError = nil }

                if let err = validationError {
                    Text(err)
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, Spacing.xs)
                }

                Button {
                    if let err = validate(server) {
                        validationError = err
                        return
                    }
                    // SR9：统一走 AuthStore 的规范化口径（原来这里补 http://，
                    // 而 SafariRelay/上传/后台刷新补 https://，同一裸地址两种协议）
                    let s = AuthStore.normalizedServerURL(server)
                    auth.serverURL = s
                    UserDefaults.standard.set(s, forKey: "qingliao_server")
                    saved = true
                    Task { try? await Task.sleep(for: .seconds(0.8)); auth.logout() }
                } label: {
                    Text("保存并重新登录")
                    .font(.system(size: Typography.body, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .pill(.primary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.sheetInset)
            .padding(.top, Spacing.xl)

            if saved {
                Text("已保存，正在返回登录...")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.green)
                    .padding(.top, Spacing.md)
            }

            Spacer()
        }
        .navigationTitle("服务器地址")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        .onAppear {
            server = auth.serverURL.replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: "")
        }
        }
    }
}


// MARK: - 钉一钉存储路径（v3.0.77：由系统 .alert 改为 App 统一底部 sheet，对齐 PasswordSheet 风格）

struct PinPathSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("默认: /volume1/.../轻聊app", text: $path)
                    .font(.system(size: Typography.body))
                    .padding(Spacing.xl)
                    .pastelFill(cornerRadius: Radius.inset)
                    .padding(.horizontal, Spacing.sheetInset)
                    .padding(.top, Spacing.xxl)

                Text("NAS 上的存储目录路径，pins.json 保存在此目录下")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.sheetInset)
                    .padding(.top, Spacing.lg)

                Button {
                    PinStore.shared.storagePath = path.trimmingCharacters(in: .whitespaces)
                    dismiss()
                } label: {
                    Text("确定")
                        .font(.system(size: Typography.body, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .pill(.primary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.top, Spacing.xl)

                Button {
                    PinStore.shared.storagePath = ""
                    dismiss()
                } label: {
                    Text("恢复默认")
                        .font(.system(size: Typography.body, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.xl)
                        .pastelFill(cornerRadius: Radius.inset)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.top, Spacing.lg)

                Spacer()
            }
            .navigationTitle("钉一钉存储路径")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear { path = PinStore.shared.storagePath }
    }
}

// MARK: - 修改密码

struct PasswordSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""   // v2.0.83c：新密码二次确认
    @State private var result: String?
    @State private var busy = false
    // v4.0.116：改密后一键同步后端环境（宿主 .env / .ql_cred 副本）
    @State private var supportsEnvSync = false   // 后端是否支持（老后端不弹，保持原行为）
    @State private var showEnvSyncPrompt = false
    @State private var pendingSyncPassword = ""  // 只在内存里留存，用于同步时自证身份

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SecureField("当前密码", text: $oldPassword)
                .font(.system(size: Typography.body))
                .padding(Spacing.xl)
                .pastelFill(cornerRadius: Radius.inset)
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.top, Spacing.xxl)

            SecureField("新密码", text: $newPassword)
                .font(.system(size: Typography.body))
                .padding(Spacing.xl)
                .pastelFill(cornerRadius: Radius.inset)
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.top, Spacing.lg)

            // v2.0.83c：新密码二次确认（两次一致才可提交）
            SecureField("确认新密码", text: $confirmPassword)
                .font(.system(size: Typography.body))
                .padding(Spacing.xl)
                .pastelFill(cornerRadius: Radius.inset)
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.top, Spacing.lg)
            if !confirmPassword.isEmpty && confirmPassword != newPassword {
                Text("两次输入的密码不一致")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.sheetInset)
                    .padding(.top, Spacing.xs)
            }

            Button {
                changePassword()
            } label: {
                Text(busy ? "提交中..." : "确认修改")
                    .font(.system(size: Typography.body, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .pill(.primary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.sheetInset)
            .padding(.top, Spacing.xl)

            if let r = result {
                Text(r)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle((r.contains("成功") || r.contains("已同步")) ? Color.green : Color.red)
                    .padding(.top, Spacing.md)
            }

            Spacer()
        }
        .navigationTitle("修改密码")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        // v4.0.116：老后端没有该接口 → 探测失败就不弹窗，保持原「改完即登出」行为
        .task {
            if await auth.jsonOrLog("/api/auth/sync-env") != nil { supportsEnvSync = true }
        }
        .alert("同步后端环境？", isPresented: $showEnvSyncPrompt) {
            Button("一键同步") { syncBackendEnv() }
            Button("稍后", role: .cancel) { finishAfterChange() }
        } message: {
            Text("改密后，后端服务里的密码副本会过期（自动化规则等后台功能可能失效）。\n同步约需 15 秒，期间 App 会短暂失联，完成后请重新登录。")
        }
        }
    }

    private func changePassword() {
        // v2.0.83c：新密码二次确认校验
        guard !oldPassword.isEmpty, !newPassword.isEmpty, !busy else { return }
        guard newPassword == confirmPassword else {
            result = "两次输入的密码不一致"
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let j = try await auth.json("/api/auth/change-password", method: "POST", body: [
                    "old": oldPassword, "new": newPassword
                ])
                if (j["ok"] as? Bool) ?? false {
                    if supportsEnvSync {
                        // v4.0.116：改密后后端 env 里的密码副本会过期 → 先问要不要一键同步
                        result = "✅ 修改成功"
                        pendingSyncPassword = newPassword
                        showEnvSyncPrompt = true
                    } else {
                        result = "✅ 修改成功，请重新登录"
                        Task { try? await Task.sleep(for: .seconds(1.2)); auth.logout() }
                    }
                } else {
                    result = "⚠️ " + ((j["error"] as? String) ?? "修改失败")
                }
            } catch {
                result = "❌ 修改失败，请检查当前密码"
            }
        }
    }

    /// 收尾：清掉内存里的密码，稍后登出（等弹窗/提示被看见）
    private func finishAfterChange(after: Double = 1.0) {
        pendingSyncPassword = ""
        // v4.0.116 fix（发版审查 P2）：本批把明文驻留窗口从 ~1.2s 拉长到最长 ~120s，而原来只清
        // pendingSyncPassword —— 三个输入框的状态会一直留到视图销毁。收尾连输入一并清掉。
        oldPassword = ""
        newPassword = ""
        confirmPassword = ""
        Task { try? await Task.sleep(for: .seconds(after)); auth.logout() }
    }

    /// v4.0.116：用新密码自证身份发起同步 → 轮询进度（容器重建期间连接失败 = 正在重启，继续轮）
    private func syncBackendEnv() {
        let pw = pendingSyncPassword
        guard !pw.isEmpty, !busy else { finishAfterChange(); return }
        busy = true
        Task {
            defer { busy = false }
            result = "⏳ 正在同步后端环境…"
            var started = false
            do {
                let j = try await auth.json("/api/auth/sync-env", method: "POST", body: ["password": pw])
                started = (j["ok"] as? Bool) ?? false
                if !started { result = "⚠️ " + ((j["error"] as? String) ?? "同步未能启动") }
            } catch {
                // v4.0.116 fix（发版审查 P1）：后端 `start_sync` 的**所有失败**都是 ok:false + HTTP 400
                // （密码不正确／已有同步任务在进行中／本部署未暴露 compose 目录／启动 helper 失败），
                // 而 auth.json 在解析 body 之前就按状态码抛 APIError.server(400) → 旧写法一律落进
                // 「后端未支持自动同步」——把「启动失败」谎报成「不支持」，用户既看不到原因也以为功能不存在。
                // 400 恰恰证明后端**支持**本功能（不支持是 404 落到 .server(404) 或网络层错误）。
                if case APIError.server(let code) = error, code == 400 {
                    result = "⚠️ 同步未能启动：这条链路本该由后端接管，可能是部署侧不具备条件；重新登录后可在设置页再触发一次"
                } else {
                    result = "ℹ️ 后端未支持自动同步，已跳过"
                }
            }
            guard started else { finishAfterChange(after: 3.0); return }
            pendingSyncPassword = ""     // 已送出，不再留存
            result = "⏳ " + "正在改写宿主配置并重建后端（约 15 秒）…"
            for _ in 0..<40 {
                try? await Task.sleep(for: .seconds(3))
                guard let j = await auth.jsonOrLog("/api/auth/sync-env") else { continue }
                let st = (j["status"] as? String) ?? ""
                if st == "done" { result = "✅ 后端环境已同步，请重新登录"; break }
                if st == "failed" {
                    result = "⚠️ 同步失败：" + ((j["error"] as? String) ?? "未知原因")
                    break
                }
                result = "⏳ " + ((j["step"] as? String) ?? "同步中…")
            }
            // v4.0.116 fix（发版审查 P2）：本循环只轮 120s，而后端把超 600s 的 running 才归一化成
            // failed —— 容器冷拉/镜像缺失等慢场景下，用户会拿着「同步中…」被直接登出、永远等不到结论。
            // 耗尽时如实交代状态与后续动作，别让「还在转」的文案被登出吞掉。
            if result?.hasPrefix("⏳") == true {
                result = "⏳ 同步仍在进行（后端最长约 10 分钟），稍后用新密码登录即可确认结果"
            }
            finishAfterChange(after: 2.5)   // 同步耗时长：结果多留一会儿再登出
        }
    }
}

// MARK: - 同步后端环境（v4.0.116：独立补同步入口）
// 为什么需要它：改密后的同步只挂在 PasswordSheet 那一个分支里，一旦那一次没成
// （旧密码已失效、或部署侧不具备重建条件），用户此时只能重新登录，就再也没有地方能
// 触发第二次 —— 而宿主 .env / .ql_cred 里的密码副本仍是旧的，规则等后台功能会静默失效。
// 这里用「当前登录密码」自证身份，任何时候都能补同步（同步接口幂等，且后端同时只允许一个任务）。
struct EnvSyncSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var result: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("把当前登录密码同步给后端服务，更新宿主 .env / .ql_cred 里的密码副本（自动化规则等后台功能依赖它）。\n约需 15 秒，期间 App 会短暂失联。")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.sheetInset)
                    .padding(.top, Spacing.xxl)

                SecureField("当前登录密码", text: $password)
                    .font(.system(size: Typography.body))
                    .padding(Spacing.xl)
                    .pastelFill(cornerRadius: Radius.inset)
                    .padding(.horizontal, Spacing.sheetInset)
                    .padding(.top, Spacing.xl)

                Button {
                    runSync()
                } label: {
                    Text(busy ? "同步中..." : "开始同步")
                        .font(.system(size: Typography.body, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .pill(.primary)
                }
                .buttonStyle(.plain)
                .disabled(busy || password.isEmpty)
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.top, Spacing.xl)

                if let r = result {
                    Text(r)
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(r.hasPrefix("✅") ? Color.green
                                         : (r.hasPrefix("⏳") ? Color.secondary : Color.red))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.sheetInset)
                        .padding(.top, Spacing.md)
                }

                Spacer()
            }
            .navigationTitle("同步后端环境")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// POST 自证身份 → 轮询进度（容器重建期间连接失败 = 正在重启，继续轮）
    /// 判据与 PasswordSheet 保持一致：后端 start_sync 的失败一律是 ok:false + HTTP 400，
    /// 而 auth.json 按状态码先抛且不带 body —— 所以 400 要读成「支持但启动失败」，不是「不支持」。
    private func runSync() {
        let pw = password
        guard !pw.isEmpty, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            result = "⏳ 正在同步后端环境…"
            var started = false
            do {
                let j = try await auth.json("/api/auth/sync-env", method: "POST", body: ["password": pw])
                started = (j["ok"] as? Bool) ?? false
                if !started { result = "⚠️ " + ((j["error"] as? String) ?? "同步未能启动") }
            } catch {
                if case APIError.server(let code) = error, code == 400 {
                    result = "⚠️ 同步未能启动（密码不正确，或后端不具备重建条件）"
                } else {
                    result = "ℹ️ 后端未支持自动同步，已跳过"
                }
            }
            guard started else { password = ""; return }
            password = ""     // 已送出，不再留存明文
            for _ in 0..<40 {
                try? await Task.sleep(for: .seconds(3))
                guard let j = await auth.jsonOrLog("/api/auth/sync-env") else { continue }
                let st = (j["status"] as? String) ?? ""
                if st == "done" { result = "✅ 后端环境已同步，请重新登录"; break }
                if st == "failed" {
                    result = "⚠️ 同步失败：" + ((j["error"] as? String) ?? "未知原因")
                    break
                }
                result = "⏳ " + ((j["step"] as? String) ?? "同步中…")
            }
            if result?.hasPrefix("⏳") == true {
                result = "⏳ 同步仍在进行（后端最长约 10 分钟），可稍后再进来查看结果"
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int? = nil   // v4.1.0 方案C降噪：组标题升页级大标题 + 右侧「N 项」
    init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }
    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(title)
                .font(.system(size: Typography.title, weight: .bold))
                .foregroundStyle(.primary)
            if let count {
                Text("\(count) 项")
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.sheetInset)
        .padding(.top, Spacing.xxl)
        .padding(.bottom, Spacing.xs)
    }
}

struct SettingRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var value: String? = nil
    var chevron: Bool = false
    // v2.0.87az：行尾开关（替代独立 Toggle 行，避免错位）
    var toggle: Binding<Bool>? = nil

    var body: some View {
        HStack(spacing: 12) {
            // v4.0.114（用户「设置页图标改回多彩圆角图标」）：**撤销** v4.1.0「方案C降噪」的 mono 口径——
            // 那次把 9 色图标统一成 accent 淡底单色；用户明确要回多彩（他一贯反对为统一收敛成单色系）。
            // 形态即 4.0.107 之前：实色圆角底 + 白符号。53 处调用的 iconColor 一直还在传，
            // 所以只改这一个共用组件，设置页全部行一起恢复。
            Image(systemName: icon)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(iconColor, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
            Text(title)
                .font(.system(size: Typography.body))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)   // 与 SettingsModelSheets 的音色行同口径（显式留最小间距）
            if let value {
                // v3.9.80：行尾值钉单行——值折成两行时左标题会被垂直居中夹住 = 真机报过的
                // 「系统音色文字错位」同款（那一行已修；这里是共用的行组件，一处修覆盖设置页所有行）
                Text(value)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            // v2.0.87az：行尾开关
            if let toggle {
                Toggle("", isOn: toggle).qingliaoSwitch()
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
        // v4.0.68：这行原来是 Color(uiColor: .secondarySystemGroupedBackground)（纯白面），
        // 压在已彩化的外层 pastelCard 上就是用户报的那块「白底」→ 行底交给外层卡片，不再自己涂料。
        .contentShape(Rectangle())
    }
}

// v4.1.0 方案C收纳：折叠分组 —— 折叠时一行摘要卡（组名 + N 项 + chevron），展开时 = SectionHeader + 内容。
// 每组展开状态由宿主 @AppStorage 记忆（默认只展开「账号与安全」）。
struct FoldSection<Content: View>: View {
    let title: String
    var count: Int
    @Binding var isFolded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        // v4.0.114（审查 P2）：垂直外边距提到 if/else **外层** —— 原先只加在折叠态，
        // 展开/折叠来回切时该分组与相邻卡的间距会跳 12pt（本批刚为「过于紧凑」补的常量反成抖动源）。
        Group {
            if isFolded {
                Button {
                    withAnimation(Motion.snap) { isFolded = false }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Text(title)
                            .font(.system(size: Typography.body, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: Spacing.md)
                        Text("\(count) 项")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.tertiary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: Typography.caption, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.vertical, Spacing.lg)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pastelCard()
            } else {
                // v4.0.114（用户「设置页展开后不能再折叠」——**确实是缺陷**）：展开态原来只有
                // `SectionHeader`（纯展示标题）+ 内容，**没有任何收起入口**，展开了就回不去
                // （4 个分组全展开要一路滚到底，想收只能退出重进）。
                // 这里把标题行做成「点一下收起」，与折叠态的摘要行对称（那边点一下展开）。
                // ⚠️ 不动共用的 `SectionHeader`（别处还在当纯标题用），只在外面套按钮 + 加一枚 chevron.up。
                Button {
                    withAnimation(Motion.snap) { isFolded = true }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        SectionHeader(title, count: count)
                        Image(systemName: "chevron.up")
                            .font(.system(size: Typography.caption, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, Spacing.sheetInset)
                            .padding(.top, Spacing.xxl)   // 与 SectionHeader 的 top 内衬对齐
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                content()
            }
        }
        // v4.0.114（用户「设置页折叠栏目位置过于紧凑」）：宿主是 VStack(spacing: 0)、卡片自身无外边距
        // —— 4 个折叠摘要行原来**零间距贴成一整块**。补一圈垂直外边距（相邻卡之间 = 2×6 = 12pt）。
        // 要更松/更紧只动这一个常量（Spacing.xs=4 / sm=6 / md=8 / xl=12）。
        .padding(.vertical, Spacing.sm)
    }
}

// MARK: - 会话存储位置设置（NAS 目录，服务器持久化）

struct SessionLocSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let currentPath: String
    @State private var path = ""
    @State private var result: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("设置 NAS 上存储会话记录的目录（需为服务器可写路径）")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
            TextField("如 /volume1/docker/轻聊数据/sessions", text: $path)
                .font(.system(size: Typography.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(Spacing.xl)
                .pastelFill(cornerRadius: Radius.inset)
            if let result {
                Text(result)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(result.hasPrefix("✅") ? Color.green : Color.red)
            }
            Button {
                save()
            } label: {
                HStack {
                    Spacer()
                    if saving { ProgressView() } else { Text("保存") }
                    Spacer()
                }
                .font(.system(size: Typography.body, weight: .semibold))
                .frame(maxWidth: .infinity)
                .pill(.primary)
            }
            .buttonStyle(.plain)
            .disabled(saving)
            Spacer()
        }
        .padding(Spacing.sheetInset)
        .navigationTitle("会话存储位置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        .onAppear { path = currentPath }
        }
    }

    private func save() {
        saving = true
        result = nil
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { saving = false }
            do {
                let j = try await auth.json("/api/sessions/location", method: "POST", body: ["path": p])
                if (j["ok"] as? Bool) == true {
                    result = "✅ 已保存：" + (j["path"] as? String ?? p)
                } else {
                    result = "❌ " + ((j["error"] as? String) ?? "保存失败")
                }
            } catch {
                result = "❌ 请求失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: ===== 以下原为 Features/Settings/SettingsPages.swift =====

// MARK: - 文件管理页（浏览 NAS 文件 / 下载分享 / 上传）



// MARK: - 定时任务页

/// v4.0.112（用户 2026-10-14「定时任务增加信息推送通道设置」）：任务结果的推送通道。
///
/// 通道其实是**两条独立的腿**——微信那条由 Hermes 的 `deliver` 决定，App 任务中心那条由
/// `ql_task_push.py` 决定；用户只要一个选择，所以后端把它折成四档，一份记录写两处真值
/// （`deliver` + `data/cron_channels.json`）。这里的 id 与后端 `cron_api.CHANNELS` **逐字对应**，
/// 改一边必须改另一边。
///
/// ⚠️ 别把通道塞进 Hermes 的 `deliver` 当自造 token（如 `deliver="app"`）：Hermes 解析不到
/// 任何投递目标 → 每次运行记 `last_delivery_error`、`last_status` 打成 `delivery_failed`，
/// App 任务行会显示成失败。这就是「只推 App」得单独记一份开关的原因。
struct CronChannel {
    let id: String
    let label: String

    static let all: [CronChannel] = [
        CronChannel(id: "both", label: "微信 + App"),
        CronChannel(id: "wechat", label: "仅微信"),
        CronChannel(id: "app", label: "仅 App"),
        CronChannel(id: "none", label: "不推送"),
    ]

    /// 新建任务默认「微信 + App」= 改动前的老口径，不改变既有习惯
    static let defaultID = "both"

    /// 后端值 → 界面文案。认不出来时说「未知通道」，不硬套一个看起来正常的档位。
    static func label(_ id: String) -> String {
        all.first { $0.id == id }?.label ?? "未知通道"
    }
}

struct CronTask: Identifiable {
    let id: String
    let name: String
    let cron: String
    let prompt: String
    let enabled: Bool
    let nextRunAt: String?
    /// v4.0.112：推送通道（both / wechat / app / none）。老后端不下发这个键 → nil，
    /// 列表就不显示通道行（宁可少一行，也不要显示一个假通道）。
    let channel: String?

    var nextRunText: String {
        guard let nextRunAt, !nextRunAt.isEmpty else { return "待定" }
        return nextRunAt
    }

    var channelLabel: String? {
        channel.map { CronChannel.label($0) }
    }
}

struct TasksView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var tasks: [CronTask] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if loading {
                    // v3.9.42：首屏改骨架（列表结构可预测，行式与下方真列表同形）
                    LoadingStateView(shape: .rows(4))
                } else if tasks.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Text("暂无定时任务")
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.tertiary)
                    if let loadError {
                        Text(loadError)
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                        Button("重试") {
                            Task { await load() }
                        }
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    } else {
                        Text("下拉可刷新")
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(tasks) { t in
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                        .fill(Color.indigo.opacity(Tint.soft))
                                    Image(systemName: "clock.badge.fill")
                                        .font(.system(size: Typography.body))
                                        .foregroundStyle(Color.indigo)
                                }
                                .frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(t.name)
                                        .font(.system(size: Typography.subhead, weight: .semibold))
                                        .lineLimit(1)
                                    Text(t.cron)
                                        .font(.system(size: Typography.tiny, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    if t.enabled {
                                        Text("运行中 · \(t.nextRunText)")
                                            .font(.system(size: Typography.tiny))
                                            .foregroundStyle(Color.green)
                                    } else {
                                        Text("已停用")
                                            .font(.system(size: Typography.tiny))
                                            .foregroundStyle(Color.secondary)
                                    }
                                    // v4.0.112：推送通道（老后端不下发 channel → 这行不出现）
                                    if let ch = t.channelLabel {
                                        HStack(spacing: 3) {
                                            Image(systemName: "paperplane.fill")
                                                .font(.system(size: 8))
                                            Text(ch)
                                                .font(.system(size: Typography.tiny))
                                        }
                                        .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                // 启用/禁用切换
                                Button {
                                    toggleTask(t)
                                } label: {
                                    Image(systemName: t.enabled ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: Typography.headline))
                                        .foregroundStyle(t.enabled ? Color.orange : Color.green)
                                }
                                .buttonStyle(.plain)
                                // 立即运行
                                Button {
                                    runTask(t)
                                } label: {
                                    Image(systemName: "bolt.circle.fill")
                                        .font(.system(size: Typography.headline))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, Spacing.xxl)
                            .padding(.vertical, Spacing.lg)
                            // 长按：编辑 / 删除
                            // v4.0.105：系统 .contextMenu → 全局同款锚定胶囊菜单（微缩抬起 + 轻纱模糊变暗 + 弹簧错峰）
                            .anchorLongPressMenu(items: scheduledTaskMenuList(), title: "定时任务") { item in
                                switch item.id {
                                case "edit":
                                    // v3.9.40（#17）：编辑任务名/Cron/提示词（PATCH 依赖 unified_router
                                    // 补上的 do_PATCH，之前 501）
                                    editingTask = t
                                case "delete":
                                    deleteTask(t)
                                default:
                                    break
                                }
                            }
                            Divider().padding(.leading, Spacing.rowDividerInsetWide)
                        }
                    }
                    .pastelFill(cornerRadius: Radius.field)
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.bottom, 20)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("定时任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewTask = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .task { await load() }
        // 关闭后重载：新建/编辑原先都要手动下拉刷新才看得到结果
        .sheet(isPresented: $showNewTask, onDismiss: { Task { await load() } }) {
            NewTaskSheet()
                // v4.0.112：多了「推送通道」一行，medium 会顶到保存按钮 → 允许上拉到 large
                .presentationDetents([.medium, .large])
        }
        // v3.9.40（#17）：编辑既有任务
        .sheet(item: $editingTask, onDismiss: { Task { await load() } }) { t in
            NewTaskSheet(editing: t)
                .presentationDetents([.medium, .large])
        }
        }
    }

    @State private var showNewTask = false
    @State private var editingTask: CronTask?   // v3.9.40（#17）：非空即打开编辑弹窗
    @State private var loadError: String?

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let arr = try await auth.jsonArray("/api/cron/tasks")
            tasks = arr.compactMap { d in
                guard let d = d as? [String: Any], let id = d["id"] as? String else { return nil }
                return CronTask(id: id,
                                name: d["name"] as? String ?? "未命名",
                                cron: d["cron"] as? String ?? "",
                                prompt: d["prompt"] as? String ?? "",
                                enabled: (d["enabled"] as? Bool) ?? true,
                                nextRunAt: d["next_run_at"] as? String,
                                channel: d["channel"] as? String)
            }
            loadError = nil
        } catch {
            tasks = []
            loadError = "加载失败：\(error.localizedDescription)"
        }
    }

    /// 立即运行任务（POST /api/cron/tasks/{id}/run）
    private func runTask(_ t: CronTask) {
        Task {
            _ = try? await auth.request("/api/cron/tasks/\(t.id)/run", method: "POST", body: nil)
            await load()
        }
    }

    /// 启用/禁用任务（PATCH /api/cron/tasks/{id}）
    private func toggleTask(_ t: CronTask) {
        Task {
            _ = try? await auth.request("/api/cron/tasks/\(t.id)", method: "PATCH",
                                        body: ["enabled": !t.enabled])
            await load()
        }
    }

    /// 删除任务（DELETE /api/cron/tasks/{id}）
    private func deleteTask(_ t: CronTask) {
        Task {
            _ = try? await auth.request("/api/cron/tasks/\(t.id)", method: "DELETE", body: nil)
            await load()
        }
    }
}

// MARK: - 日志页

struct LogsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var logs: [String] = []
    @State private var loading = true
    @State private var exportText = ""
    @State private var showExporter = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if loading {
                    // v3.9.42：日志是整宽纯文本行，用头像骨架会骗人 → 收口转圈
                    LoadingStateView(shape: .spinner(text: "正在读取日志…"))
                } else if logs.isEmpty {
                Spacer()
                Text("暂无日志")
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: Typography.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Spacing.xl)
                                .padding(.vertical, Spacing.xs)
                        }
                    }
                    .pastelFill(cornerRadius: Radius.field)
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.bottom, 20)
                }
            }
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 16) {
                    Button {
                        UIPasteboard.general.string = logs.joined(separator: "\n")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(Color.accentColor)
                    }
                    Button {
                        exportText = logs.joined(separator: "\n")
                        showExporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Color.accentColor)
                    }
                    // v3.9.35：刷新改回系统裸按钮——与「完成」同款系统玻璃胶囊
                    Button("刷新") { Task { await load() } }
                }
            }
        }
        .task { await load() }
        .fileExporter(isPresented: $showExporter,
                      document: LogDocument(text: exportText),
                      contentType: .plainText,
                      defaultFilename: "qingliao-logs") { _ in }
        }
    }

    /// 日志导出文档
    struct LogDocument: FileDocument {
        var text: String
        static var readableContentTypes: [UTType] { [.plainText] }
        init(text: String) { self.text = text }
        init(configuration: ReadConfiguration) throws {
            text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
        }
        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
            FileWrapper(regularFileWithContents: Data(text.utf8))
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let j = try await auth.json("/api/logs/sys")
            if let arr = j["logs"] as? [String] {
                logs = arr
            } else if let arr = j["logs"] as? [[String: Any]] {
                logs = arr.compactMap { $0["msg"] as? String ?? $0["message"] as? String ?? $0["line"] as? String }
            }
        } catch {
            logs = []
        }
    }
}

// MARK: - 新建 / 编辑定时任务

struct NewTaskSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    /// v3.9.40（#17）：nil = 新建（POST），非 nil = 编辑（PATCH 该任务）
    let editing: CronTask?
    @State private var name = ""
    @State private var cron = "0 9 * * *"
    @State private var prompt = ""
    /// v4.0.112：推送通道（both / wechat / app / none）——与后端 cron_api.CHANNELS 同集合
    @State private var channel = CronChannel.defaultID
    @State private var saving = false
    @State private var errorText: String?

    init(editing: CronTask? = nil) {
        self.editing = editing
        let c = editing?.cron ?? ""
        _name = State(initialValue: editing?.name ?? "")
        _cron = State(initialValue: c.isEmpty ? "0 9 * * *" : c)
        _prompt = State(initialValue: editing?.prompt ?? "")
        // 老后端不下发 channel（nil）→ 落到默认档，保存时会把通道显式写进去
        _channel = State(initialValue: editing?.channel ?? CronChannel.defaultID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(editing == nil ? "新建定时任务" : "编辑定时任务")
                    .font(.system(size: Typography.title, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.titleXL)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }

            TextField("任务名称（如：每日早报）", text: $name)
                .font(.system(size: Typography.body))
                .textFieldStyle(.roundedBorder)
            TextField("Cron 表达式（如 0 9 * * *）", text: $cron)
                .font(.system(size: Typography.subhead, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            // v4.0.112：推送通道（四档单选）。放在 Cron 与提示词之间——「什么时候跑」定完
            // 紧接着就是「跑完推哪儿」，与用户脑子里的顺序一致。
            VStack(alignment: .leading, spacing: 6) {
                Text("推送通道")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(CronChannel.all, id: \.id) { c in
                        MiniCapsule(title: c.label, accent: channel == c.id, size: .page) {
                            channel = c.id
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("推送通道")
            TextEditor(text: $prompt)
                .font(.system(size: Typography.subhead))
                .frame(height: 110)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.icon)
                        .strokeBorder(Color.secondary.opacity(Tint.strong), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("任务提示词（发给 AI 的执行指令）")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.tertiary)
                            .padding(Spacing.md)
                    }
                }
            if let errorText {
                Text(errorText).font(.system(size: Typography.subhead)).foregroundStyle(.red)
            }
            Button {
                save()
            } label: {
                HStack {
                    Spacer()
                    if saving { ProgressView() } else { Text("保存任务") }
                    Spacer()
                }
                .font(.system(size: Typography.body, weight: .semibold))
                .frame(maxWidth: .infinity)
                .pill(.primary)
            }
            .buttonStyle(.plain)
            .disabled(saving || name.isEmpty || cron.isEmpty || prompt.isEmpty)
            Spacer()
        }
        .padding(Spacing.sheetInset)
    }

    private func save() {
        saving = true
        errorText = nil
        Task {
            defer { saving = false }
            do {
                if let t = editing {
                    // PATCH 由 cron_api 原样转发 Hermes 的响应，没有统一 ok 字段 → 不带 error 即成功
                    let j = try await auth.json("/api/cron/tasks/\(t.id)", method: "PATCH",
                                                body: ["name": name, "cron": cron, "prompt": prompt,
                                                       "channel": channel])
                    if let err = j["error"] as? String {
                        errorText = err
                    } else {
                        dismiss()
                    }
                } else {
                    let j = try await auth.json("/api/cron/tasks", method: "POST", body: [
                        "name": name, "cron": cron, "prompt": prompt, "channel": channel
                    ])
                    if (j["ok"] as? Bool) == true {
                        dismiss()
                    } else {
                        errorText = (j["error"] as? String) ?? "保存失败"
                    }
                }
            } catch {
                errorText = "请求失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: ===== 以下原为 Features/Settings/AppearanceSheet.swift =====

// v3.9.28：外观设置弹窗——从 CloudSettingsView 拆出独立文件（云端模式移除时误删，
// 但设置页「外观」入口仍在引用 → 灵动岛/流光/字体/行高/天气城市开关全丢了）。
struct AppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    // v3.0.2：全部用本地真实 key + 本地交互（主题用 qingliao_appearance，字体用 qingliao_font_size）
    @AppStorage("qingliao_appearance") private var appearance = "system"   // dark/light/system（对齐本地主题）
    @AppStorage("qingliao_font_size") private var fontSize = 15.0          // 12-20 聊天字体（对齐本地）
    @AppStorage("qingliao_ai_line_spacing") private var aiLineSpacing = 1.0  // AI 输出行高
    @AppStorage("qingliao_siri_glow") private var siriGlow = false
    // v3.0.36：灵动岛发光（独立开关，复用 Siri 发光 4 参数）
    @AppStorage("qingliao_island_glow") private var islandGlow = false
    // v3.8.0：灵动岛/锁屏实时活动（AI 回复中显示进度）——与 LiveActivityManager 共用同一 key（默认开）
    @AppStorage(LiveActivityManager.enabledKey) private var liveActivityOn = true
    @AppStorage("qingliao_siri_glow_brightness") private var glowBrightness = 1.0
    @AppStorage("qingliao_siri_glow_freq") private var glowFreq = 2.2
    @AppStorage("qingliao_siri_glow_amp") private var glowAmp = 0.18
    @AppStorage("qingliao_siri_glow_width") private var glowWidth = 22.0
    // v3.0.4：补全本地外观独有项（输入框流光 / 天气城市）
    @AppStorage("qingliao_input_glow") private var glowOn = true
    // v4.0.7：烟花粒子特效开关（DockTabView.fireDockBurst 读同一 key）
    @AppStorage("qingliao_dock_burst") private var dockBurstOn = true
    // v4.0.6：聊天页形象/表情/动作/动画档四组 key 已搬去 PetStudioSheet（外观页不再重复持有，
    // 否则两处 @AppStorage 同 key 也能跑，但「外观页改动不刷新预览」这类半联动问题会很难查）。
    @State private var weatherCity = UserDefaults.standard.string(forKey: "qingliao_weather_city") ?? ""
    @State private var showWeatherCityField = false
    // v3.9.94：启动会话（逻辑早已接好，见 LaunchSession.swift / ChatStore.swift:158-165，
    // 但外观页一直没给入口 → 用户根本设不了，永远吃默认值 .auto + 15 分钟）。
    // ⚠️ 必须用 @AppStorage 直接绑 UserDefaultsKey.*，不要自己在 onChange 里写回去：
    //    ChatStore 读的就是这两个 key，绕一层就可能与真值表/预检断言脱钩。
    // 第 12 项：特效总档（关 / 标准 / 丰富）。走 @AppStorage 直接绑 key ——
    // EffectsLevel.current 读的就是它，绕一层会与预检断言脱钩。
    @AppStorage(UserDefaultsKey.effectsLevel) private var effectsLevel = EffectsLevel.fallback.rawValue
    @AppStorage(UserDefaultsKey.launchSessionMode) private var launchSessionMode = LaunchSessionMode.auto.rawValue
    @AppStorage(UserDefaultsKey.launchSessionMins) private var launchSessionMins = Double(LaunchSessionMode.defaultIdleMinutes)

    var body: some View {
        NavigationStack {
            Form {
                // 主题模式（对齐本地 appearanceOption 三段选择）
                Section("主题") {
                    HStack(spacing: 10) {
                        appearanceOption("浅色", value: "light")
                        appearanceOption("深色", value: "dark")
                        appearanceOption("跟随系统", value: "system")
                    }
                    .padding(.vertical, Spacing.xs)
                }
                // v3.9.78 的「聊天页形象」段（形象三选一 + 动画三档）**已于 v4.0.6 搬去 PetStudioSheet**
                // （用户：「外观里面的聊天页选项就可以移动到卡通宠物头像的设置里」）。
                // 搬走而非复制：两处都能改迟早会不一致，且外观页那个 petOption/motionOption 已无调用点。
                // 聊天页顶部仍是同一只宠物（共用 PetKeys.style/.motion/.quirks/.face 四个 key）。
                // 交互
                Section("交互") {
                    Toggle("输入框流光光效", isOn: $glowOn).qingliaoSwitch(hideLabel: false)   // v3.0.4：补全本地独有项
                    // v4.0.7：点 dock 智慧球的烟花粒子特效（用户：烟花也做个开关放设置里）
                    Toggle("烟花粒子特效", isOn: $dockBurstOn).qingliaoSwitch(hideLabel: false)
                    // v3.8.0：灵动岛/锁屏实时活动——AI 回复中亮起、结束收起；关掉立即收起正在显示的活动
                    Toggle("灵动岛实时活动", isOn: $liveActivityOn).qingliaoSwitch(hideLabel: false)
                        .onChange(of: liveActivityOn) { _, on in
                            if !on { Task { @MainActor in await LiveActivityManager.shared.end() } }
                        }
                }
                // 第 12 项整改（用户 2026-10-18「加一档三选：关 / 标准 / 丰富」）：
                // 全站特效总档 —— 只作用于既有 14 枚 Motion 令牌（调用点 200+），**不新造第二套时钟**。
                // ⚠️ 边界（审查复核实测，文案已按此写）：`.symbolEffect` 家族（15 处弹动/替换/脉动）、
                //    7 处无参 `withAnimation`、循环动效（宠物呼吸 / 烟花粒子 / 输入框流光 / 扫描环）
                //    都**不在本档内** —— 前两类是历史裸用法（列为待办，本版不动），后一类是用户明说的各自开关。
                // ⚠️ 令牌是计算属性、读过即定值：切档后**已在屏且在冻结中的页面**要到下次 body 求值才换档，
                //    返回/切页即重算 → 实测观感上「切完切页立刻生效」。别为此给根视图挂 `.id`（重建整树，代价大）。
                // 键名真源：`Core/EffectsLevel.storageKey` → `UserDefaultsKey.effectsLevel`。
                Section("动效特效") {
                    HStack(spacing: 10) {
                        ForEach(EffectsLevel.allCases) { lv in
                            effectsOption(lv.label, value: lv)
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                    Text(currentEffects.detail)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.secondary)
                }
                // v3.9.94：启动会话（用户拍板「设置里面增加启动会话设置……放在外观设置里」）
                // ⚠️ 这段 UI 是**补的入口**，不是新功能：判定逻辑在 LaunchSession.swift 早就有，
                //    ChatStore.swift:158-165 也一直在读这两个 key，只是外观页没给入口，
                //    所以用户一直只能吃默认的「自动 + 15 分钟」。
                Section("启动会话") {
                    HStack(spacing: 10) {
                        // ⚠️ case 名是 .last / .new（不是 .lastSession/.newSession）——
                        //    凭空造成员本机 -parse 查不出，CI Archive 才挂。
                        // 标题取 mode.title（单一真源），别在这里另写一份中文。
                        ForEach(LaunchSessionMode.allCases) { mode in
                            launchSessionOption(mode.title, value: mode)
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                    // 只有「自动」模式下阈值才有意义，另外两选一是恒定行为（跟随 / 强制新开）
                    if LaunchSessionMode(rawValue: launchSessionMode) == .auto {
                        // 档位跟 LaunchSessionMode.idleOptions 走（5/10/15/30/60/120），
                        // 不用随手写的 Slider 5...60 step 5：那样 UI 会漏掉 120 档，
                        // 而且以后加档位得改两处，容易漂。
                        HStack(spacing: 10) {
                            Text("闲置超时").font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(launchSessionMins)) 分钟")
                                .font(.system(size: Typography.subhead))
                                .foregroundStyle(.secondary)
                        }
                        // 6 档用两行网格，别挤在一行（外放页左右余量只有 ~60pt/档，标签会压缩到认不出）
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 3), spacing: Spacing.sm) {
                            ForEach(LaunchSessionMode.idleOptions, id: \.self) { m in
                                idleOption(m)
                            }
                        }
                        Text("上次打开 App 距今超过 \(Int(launchSessionMins)) 分钟，就自动开一个新对话；不足则接着上次那个聊。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                // AI 回答发光（对齐本地 Siri 发光 4 参数）
                Section("AI 回答发光") {
                    Toggle("边框光晕", isOn: $siriGlow).qingliaoSwitch(hideLabel: false)
                    // v3.0.36：灵动岛光晕（独立开关）
                    Toggle("灵动岛光晕", isOn: $islandGlow).qingliaoSwitch(hideLabel: false)
                    if siriGlow || islandGlow {
                        sliderRow("亮度", value: $glowBrightness, range: 0.2...1.5, suffix: { String(format: "%.0f%%", $0 * 100) })
                        sliderRow("呼吸频率", value: $glowFreq, range: 0.5...6.0, suffix: { String(format: "%.1f", $0) })
                        sliderRow("呼吸幅度", value: $glowAmp, range: 0...0.4, suffix: { String(format: "%.2f", $0) })
                        sliderRow("光带范围", value: $glowWidth, range: 10...44, suffix: { String(format: "%.0fpt", $0) })
                    }
                }
                // 文本（对齐本地：字体大小滑条 + AI 行高滑条）
                Section("文本") {
                    HStack {
                        Text("聊天字体大小")
                            .font(.system(size: Typography.body))
                        Spacer()
                        Text("\(Int(fontSize))")
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Text("小").font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                        Slider(value: $fontSize, in: 12...20, step: 1)
                            .tint(Color.accentColor)
                        Text("大").font(.system(size: Typography.title)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("AI 输出行高")
                            .font(.system(size: Typography.body))
                        Spacer()
                        Text(String(format: "%.1f", aiLineSpacing))
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Text("紧凑").font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                        Slider(value: $aiLineSpacing, in: 0...6, step: 0.5)
                            .tint(Color.accentColor)
                        Text("宽松").font(.system(size: Typography.title)).foregroundStyle(.secondary)
                    }
                }
                // 天气（v3.0.4：补全本地外观独有项）
                Section("天气") {
                    HStack {
                        Text("天气城市")
                            .font(.system(size: Typography.body))
                        Spacer(minLength: 8)
                        Text(weatherCity.isEmpty ? "未设置" : weatherCity)
                            .font(.system(size: Typography.subhead))
                            .foregroundStyle(.secondary)
                            // v3.9.80：钉单行（城市名长时折行会把左标题夹成垂直居中，与设置页行口径一致）
                            .lineLimit(1)
                    }
                    if showWeatherCityField {
                        HStack(spacing: 10) {
                            TextField("如：上海 / 北京", text: $weatherCity)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never)
                            Button("保存") {
                                UserDefaults.standard.set(weatherCity.trimmingCharacters(in: .whitespaces), forKey: "qingliao_weather_city")
                                showWeatherCityField = false
                            }
                            .font(.system(size: Typography.subhead, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        }
                    } else {
                        Button("设置城市") {
                            withAnimation(Motion.snap) { showWeatherCityField = true }
                        }
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .navigationTitle("外观设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 主题选项（对齐本地 appearanceOption：选中高亮段）
    private func appearanceOption(_ name: String, value: String) -> some View {
        Button {
            appearance = value
        } label: {
            Text(name)
                .font(.system(size: Typography.subhead, weight: .medium))
                .foregroundStyle(appearance == value ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(appearance == value ? Color.accentColor : Color(uiColor: .systemGray5))
                )
        }
        .buttonStyle(.plain)
    }

    /// 第 12 项：当前特效档（读不到 / 存了非法值 → 标准档，观感零变化）
    private var currentEffects: EffectsLevel {
        EffectsLevel(rawValue: effectsLevel) ?? EffectsLevel.fallback
    }

    /// 第 12 项：特效总档选项（三选一）——与 appearanceOption / launchSessionOption 同一 idiom（选中高亮段）。
    /// ⚠️ 实参序＝声明序（label: String, value: EffectsLevel），错位只有 CI Archive 报得出。
    private func effectsOption(_ label: String, value: EffectsLevel) -> some View {
        let selected = currentEffects == value
        return Button {
            effectsLevel = value.rawValue
        } label: {
            Text(label)
                .font(.system(size: Typography.subhead, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(selected ? Color.accentColor : Color(uiColor: .systemGray5))
                )
        }
        .buttonStyle(.plain)
    }

    /// v3.9.94：启动会话选项（三选一）——与 appearanceOption 同一 idiom（选中高亮段），
    /// 实参序＝声明序（name: String, value: LaunchSessionMode），错位只有 CI Archive 报得出
    private func launchSessionOption(_ name: String, value: LaunchSessionMode) -> some View {
        let selected = launchSessionMode == value.rawValue
        return Button {
            launchSessionMode = value.rawValue
        } label: {
            Text(name)
                .font(.system(size: Typography.subhead, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(selected ? Color.accentColor : Color(uiColor: .systemGray5))
                )
        }
        .buttonStyle(.plain)
    }

    /// v3.9.94：闲置超时档位按钮（5/10/15/30/60/120，档位表来自 LaunchSessionMode.idleOptions）
    /// 实参序＝声明序（minutes: Int）
    private func idleOption(_ minutes: Int) -> some View {
        let selected = Int(launchSessionMins) == minutes
        return Button {
            launchSessionMins = Double(minutes)
        } label: {
            Text("\(minutes)")
                .font(.system(size: Typography.subhead, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(selected ? Color.accentColor : Color(uiColor: .systemGray5))
                )
        }
        .buttonStyle(.plain)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           suffix: @escaping (Double) -> String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: Typography.subhead)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range).tint(Color.accentColor)
            Text(suffix(value.wrappedValue)).font(.system(size: Typography.subhead)).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, Spacing.xxs)
    }
}

// MARK: - v4.0.105 定时任务行长按菜单的数组版项（原 `.contextMenu` 的 `Button` 逐条等价）
private func scheduledTaskMenuList() -> [AnchorMenuItem] {
    [
        AnchorMenuItem(id: "edit", title: "编辑任务", icon: "square.and.pencil"),
        AnchorMenuItem(id: "delete", title: "删除任务", icon: "trash", destructive: true),
    ]
}
