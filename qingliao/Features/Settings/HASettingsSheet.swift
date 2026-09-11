import SwiftUI

// MARK: - HA 设置（Home Assistant 地址 + Token，联动看板智能家居卡片）

struct HASettingsSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var token = ""
    @State private var hasToken = false
    @State private var saving = false
    @State private var toast = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Home Assistant 连接配置，保存后看板「智能家居」卡片自动使用新配置")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("HA 地址")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                TextField("如 http://ha.example.com:8123", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("长期访问 Token")
                    .font(.system(size: Typography.subhead, weight: .semibold))
                SecureField(hasToken ? "已配置（输入新值可替换）" : "粘贴 HA 长期访问令牌", text: $token)
                    .textFieldStyle(.roundedBorder)
                if hasToken && token.isEmpty {
                    Text("当前已有 Token，留空保持不变")
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                save()
            } label: {
                HStack {
                    Spacer()
                    if saving { ProgressView().tint(.white) }
                    else { Text("保存") }
                    Spacer()
                }
                .padding(.vertical, 11)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
                .font(.system(size: Typography.body, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(saving || address.isEmpty)

            if !toast.isEmpty {
                Text(toast)
                    .font(.system(size: Typography.subhead))
                    .foregroundStyle(toast.hasPrefix("✅") ? .green : .red)
            }

            Spacer()
        }
        .padding(18)
        .navigationTitle("HA 设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        .task {
            if let j = try? await auth.json("/api/ha/config") {
                address = j["address"] as? String ?? ""
                hasToken = (j["has_token"] as? Bool) ?? false
            }
        }
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            var body: [String: Any] = ["address": address]
            if !token.isEmpty { body["token"] = token }
            do {
                let j = try await auth.json("/api/ha/config", method: "POST", body: body)
                if (j["ok"] as? Bool) == true {
                    toast = "✅ 已保存，看板智能家居卡片已联动"
                    if !token.isEmpty { token = ""; hasToken = true }
                } else {
                    toast = "保存失败：\((j["error"] as? String) ?? "未知错误")"
                }
            } catch {
                toast = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}
