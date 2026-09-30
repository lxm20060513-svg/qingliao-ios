// 本文件原为 Features/Settings/SettingsModels.swift 的物理拆分（纯搬运，UI 与行为零改动）。
// 上游文件保留 ModelSheet / provider 缓存 / 自定义模型组；本文件承载 自定义 provider 编辑表 + 关于页。

import Foundation
import SwiftUI

// MARK: - v3.0.74 添加自定义模型组表单（对齐云端 CloudProviderSheet 风格）

struct CustomProviderEditSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void

    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelsText = ""
    @State private var saving = false
    @State private var errMsg: String?
    // v3.0.82：一键拉取 /models（OpenAI 兼容端点）→ 勾选保存
    @State private var fetching = false
    @State private var fetchedModels: [String] = []
    @State private var selectedModels: Set<String> = []
    @State private var fetchMsg: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("连接信息") {
                    TextField("名称（如 我的厂商）", text: $name)
                    TextField("Base URL（https://.../v1）", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    // v3.0.82：填完 base_url+key 一键拉取模型列表
                    Button {
                        Task { await fetchModels() }
                    } label: {
                        HStack {
                            Label(fetching ? "拉取中…" : "拉取模型列表", systemImage: "arrow.down.circle")
                            Spacer()
                            if fetching { ProgressView().scaleEffect(0.8) }
                        }
                    }
                    .disabled(baseURL.isEmpty || apiKey.isEmpty || fetching)
                    if let fetchMsg {
                        Text(fetchMsg)
                            .font(.system(size: Typography.caption))
                            .foregroundStyle(fetchMsg.hasPrefix("✅") ? Color.green : Color.orange)
                    }
                }
                // v3.0.82：拉取成功 → 勾选列表（全选/清空快捷键）
                if !fetchedModels.isEmpty {
                    Section {
                        HStack {
                            Text("勾选要启用的模型（\(selectedModels.count)/\(fetchedModels.count)）")
                                .font(.system(size: Typography.subhead, weight: .medium))
                            Spacer()
                            Button(selectedModels.count == fetchedModels.count ? "清空" : "全选") {
                                if selectedModels.count == fetchedModels.count {
                                    selectedModels.removeAll()
                                } else {
                                    selectedModels = Set(fetchedModels)
                                }
                            }
                            .font(.system(size: Typography.subhead))
                            .buttonStyle(.borderless)
                        }
                        ForEach(fetchedModels, id: \.self) { m in
                            Button {
                                if selectedModels.contains(m) { selectedModels.remove(m) } else { selectedModels.insert(m) }
                            } label: {
                                HStack {
                                    Text(m)
                                        .font(.system(size: Typography.subhead))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if selectedModels.contains(m) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: Typography.subhead, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
                Section("模型名（每行一个）") {
                    TextEditor(text: $modelsText)
                        .frame(minHeight: fetchedModels.isEmpty ? 120 : 44)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .overlay(alignment: .topLeading) {
                            if modelsText.isEmpty && fetchedModels.isEmpty {
                                Text("deepseek-v4-flash\nglm-5.2\n…\n\n（或点上方「拉取模型列表」自动填充）")
                                    .font(.system(size: Typography.subhead))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, Spacing.md)
                                    .padding(.leading, Spacing.xs)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                if let errMsg {
                    Text(errMsg)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.red)
                }
                Section {
                    Button(saving ? "保存中…" : "保存") {
                        Task { await save() }
                    }
                    .disabled(name.isEmpty || baseURL.isEmpty || apiKey.isEmpty
                              || effectiveModels.isEmpty || saving)
                }
            }
            .navigationTitle("添加自定义模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// v3.0.82：生效模型 = 勾选结果（拉取过）∪ 手填行（兼容手动输入流程）
    private var effectiveModels: [String] {
        var models = selectedModels.sorted()
        let manual = modelsText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for m in manual where !models.contains(m) { models.append(m) }
        return models
    }

    /// v3.0.82：调后端拉取 OpenAI 兼容 /models（由后端请求避免 App 端 CORS/网络差异）
    private func fetchModels() async {
        fetching = true
        fetchMsg = nil
        defer { fetching = false }
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        do {
            let j = try await auth.json("/api/stream/fetch-models", method: "POST",
                                       body: ["base_url": base, "api_key": apiKey])
            if (j["ok"] as? Bool) == true, let list = j["models"] as? [String], !list.isEmpty {
                fetchedModels = list
                selectedModels = Set(list)   // 默认全选
                fetchMsg = "✅ 拉取到 \(list.count) 个模型，请勾选"
            } else {
                fetchMsg = "⚠️ \(j["error"] as? String ?? "未拉取到模型，可手动输入")"
            }
        } catch {
            fetchMsg = "⚠️ 拉取失败：\(error.localizedDescription)"
        }
    }

    private func save() async {
        saving = true
        errMsg = nil
        defer { saving = false }
        let models = effectiveModels
        let provider: [String: Any] = [
            "id": "custom-\(Int(Date().timeIntervalSince1970))",
            "name": name,
            "base_url": baseURL,
            "api_key": apiKey,
            "models": models
        ]
        do {
            let j = try await auth.json("/api/stream/custom-providers", method: "POST",
                                        body: ["action": "add", "provider": provider])
            if (j["ok"] as? Bool) == true {
                onSaved()
                dismiss()
            } else {
                errMsg = "保存失败：\(j["error"] as? String ?? "未知错误")"
            }
        } catch {
            errMsg = "保存失败：\(error.localizedDescription)"
        }
    }
}
// MARK: - 关于轻聊（软件介绍页）

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthStore.self) private var auth   // v3.0.8：拉 Hermes 版本
    // v3.0.8：Hermes 容器版本（项目版本说明，从 NAS /api/nas/status 实时读）
    @State private var hermesVersion = "读取中…"
    // v4.0.14：轻聊后端版本（从免鉴权 /api/version 读，装完 App 一眼确认后端配套哪版）
    @State private var backendVersion = "读取中…"

    var body: some View {
        VStack(spacing: 14) {
            // v2.0.34：关于页换新图标（淡青底微笑气泡，与 AppIcon 同款）
            Image("AboutLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)

            Text("轻聊")
                .font(.system(size: Typography.titleXL, weight: .bold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.0")")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)

            Divider().padding(.horizontal, 30)

            VStack(alignment: .leading, spacing: 10) {
                // v3.0.8：项目版本说明（iOS 客户端版本）
                aboutRow("项目版本", "轻聊 · iOS 客户端 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                // v3.0.3：统一介绍框架 —— 云端直连已于 v3.9.28 整体移除，本页只剩本地 AI 一种形态
                aboutRow("产品", "轻聊 —— 面向家庭的 AI 智能助手，SwiftUI 原生客户端，连接自家 NAS 上的 Hermes Agent，数据本地保存。")
                appModeRow()
                aboutRow("功能", "流式对话 · 语音对话 · 图片理解 · 知识库检索 · 会话同步 · NAS 面板 · Docker 管理 · 智能家居 · 定时任务")
                aboutRow("模型", "DeepSeek V4 / Kimi / StepFun 多模型聚合（OpenCode Go + 官方 API）")
                aboutRow("架构", "SwiftUI 原生 · Hermes Agent · 自建 NAS 后端（连接自家 NAS）")
                // v3.0.8：Hermes Agent 版本号固定放在介绍最后一行（本地模式读容器实时版本）
                HStack(alignment: .top) {
                    Text("Hermes Agent")
                        .font(.system(size: Typography.subhead, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 68, alignment: .leading)
                    Text(hermesVersion)
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.secondary)
                }
                // v4.0.14：轻聊后端版本（/api/version 免鉴权，失败只显示"未获取到"，不打扰用户）
                HStack(alignment: .top) {
                    Text("轻聊后端")
                        .font(.system(size: Typography.subhead, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 68, alignment: .leading)
                    Text(backendVersion)
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: Typography.subhead))
            .padding(.horizontal, 24)

            Spacer()
            Text("Nous Research · Hermes Agent")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
                .padding(.bottom, Spacing.xl)
        }
        .padding(.top, 22)
        // v3.0.8：拉取 Hermes 容器版本（v3.9.28 云端模式移除后不再需要分支）
        .task {
            if let j = try? await auth.json("/api/nas/status"),
               let svc = j["services"] as? [String: Any],
               let v = svc["hermes_version"] as? String, !v.isEmpty {
                hermesVersion = v
            } else {
                hermesVersion = "未获取到"
            }
            // v4.0.14：拉轻聊后端版本。/api/version 免鉴权，返回
            // {"version":"v4.0.13","commit":"8f2e181","built":"2026-10-01"}。
            // version 为空 = 部署方没注入版本信息（很常见），此时只显示 commit 或提示，
            // 不算错误 —— 所以不写死"未获取到"当错误态。
            if let j = try? await auth.json("/api/version") {
                let ver = (j["version"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let commit = (j["commit"] as? String) ?? ""
                let built = (j["built"] as? String) ?? ""
                var parts: [String] = []
                if !ver.isEmpty { parts.append(ver) }
                if !commit.isEmpty { parts.append("(\(commit))") }
                if !built.isEmpty { parts.append("· \(built)") }
                backendVersion = parts.isEmpty ? "未标注版本" : parts.joined(separator: " ")
            } else {
                backendVersion = "未获取到"
            }
        }
    }

    /// v3.0.3：当前模式行（v3.9.28 云端直连移除后恒为本地 AI）
    private func appModeRow() -> some View {
        aboutRow("当前模式", "本地 AI —— 连接自家 NAS 上的 Hermes Agent，对话/读图/语音/知识库/智能家居全掌控。")
    }

    private func aboutRow(_ title: String, _ content: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(content)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.primary)
        }
    }
}
