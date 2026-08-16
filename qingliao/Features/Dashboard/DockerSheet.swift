import SwiftUI

// MARK: - v2.0.74 Docker 管理（液态玻璃卡片化：部署卡 + 容器列表卡，易操作）

struct DockerSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var yaml = ""
    @State private var containers: [DockerContainer] = []
    @State private var message: (ok: Bool, text: String)?
    @State private var busy = false
    @FocusState private var focused: Bool
    @State private var confirmTarget: DockerContainer?
    @State private var confirmAction: (name: String, act: String)?   // v2.0.113：停止/重启确认
    // v2.0.87：升级确认
    @State private var confirmUpgrade: DockerContainer?
    @State private var upgrading = false
    // v2.0.87p：可升级容器（容器名 → 有更新）
    @State private var updates: [String: Bool] = [:]
    // v2.0.86：镜像管理
    @State private var images: [DockerImage] = []
    @State private var confirmImage: DockerImage?

    /// YAML 常用模板（一键插入）
    static let nginxTemplate = """
    services:
      app:
        image: nginx:latest
        container_name: app
        ports:
          - "8080:80"
        restart: unless-stopped
    """

    /// v2.0.86g：YAML 空态提示常量（拆分复杂字符串，规避 Swift 6 类型检查超时）
    static let yamlHint = "services:\n  app:\n    image: nginx:latest\n    ports:\n      - \"8080:80\""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // v2.0.87h：顺序调整——容器/镜像常用在前，新建部署移到最后
                    // ===== 已部署容器卡（v2.0.86i：拆子视图减类型检查负载）=====
                    ContainerSection(containers: containers,
                                     onRefresh: { await load() },
                                     // v2.0.113：停止/重启加确认（防误触，删除已有确认）
                                     onAction: handleContainerAction,
                                     onDelete: { confirmTarget = $0 },
                                     onUpgrade: { confirmUpgrade = $0 },
                                     updates: updates)
                    // ===== v2.0.86 镜像管理（v2.0.86i：拆子视图）=====
                    ImageSection(images: images,
                                 onRefresh: { await loadImages() },
                                 onDelete: { confirmImage = $0 })
                    // ===== 新建部署（v2.0.86j：拆子视图；v2.0.87h：移到末尾）=====
                    DeploySection(name: $name, yaml: $yaml, message: $message,
                                  busy: busy, onDeploy: { await deploy() })
        }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Docker 管理")
            .navigationBarTitleDisplayMode(.inline)

            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    // v2.0.120 fix：iOS 17 TextEditor FocusState 偶发不收回键盘——强制 resign
                    Button("完成") {
                        focused = false
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil, from: nil, for: nil)
                    }
                }
            }
            .confirmationDialog("删除容器？", isPresented: .init(
                get: { confirmTarget != nil },
                set: { if !$0 { confirmTarget = nil } }
            ), presenting: confirmTarget) { c in
                Button("删除", role: .destructive) {
                    let target = c
                    confirmTarget = nil
                    Task { await action(target.name, "rm") }
                }
                Button("取消", role: .cancel) { confirmTarget = nil }
            } message: { c in
                Text(c.isComposeProject
                     ? "将移除容器「\(c.name)」（配置目录保留，可重新部署）"
                     : "⚠️「\(c.name)」不是 Docker 管理项目创建的容器，删除后不可恢复，请确认！")
            }
            // v2.0.113：停止/重启确认（防误触）
            .confirmationDialog(confirmAction?.act == "restart" ? "重启容器？" : "停止容器？",
                                isPresented: .init(
                                    get: { confirmAction != nil },
                                    set: { if !$0 { confirmAction = nil } }
                                ), presenting: confirmAction) { ca in
                Button(ca.act == "restart" ? "重启" : "停止", role: .destructive) {
                    let target = ca
                    confirmAction = nil
                    Task { await action(target.name, target.act) }
                }
                Button("取消", role: .cancel) { confirmAction = nil }
            } message: { ca in
                Text("将\(ca.act == "restart" ? "重启" : "停止")容器「\(ca.name)」，确认继续？")
            }
            // v2.0.86：镜像删除确认
            .confirmationDialog("删除镜像？", isPresented: .init(
                get: { confirmImage != nil },
                set: { if !$0 { confirmImage = nil } }
            ), presenting: confirmImage) { img in
                Button("删除", role: .destructive) {
                    let target = img
                    confirmImage = nil
                    Task { await rmImage(target.id) }
                }
                Button("取消", role: .cancel) { confirmImage = nil }
            } message: { img in
                Text("删除镜像「\(img.name)」？\n若仍有容器使用会删除失败")
            }
            // v2.0.87：升级确认弹窗
            .confirmationDialog("升级容器？", isPresented: .init(
                get: { confirmUpgrade != nil },
                set: { if !$0 { confirmUpgrade = nil } }
            ), presenting: confirmUpgrade) { c in
                Button(upgrading ? "升级中…" : "升级") {
                    let target = c
                    confirmUpgrade = nil
                    Task { await upgradeContainer(target) }
                }
                .disabled(upgrading)
                Button("取消", role: .cancel) { confirmUpgrade = nil }
            } message: { c in
                Text("将拉取「\(c.name)」最新镜像并重建容器（约需 1-5 分钟，视镜像大小）")
            }
            .task { await load(); await loadImages(); await loadUpdates() }
        }
    }

    private func load() async {
        if let j = try? await auth.json("/api/docker/ps") {
            let arr = j["containers"] as? [[String: Any]] ?? []
            containers = arr.compactMap { d in
                guard let n = d["name"] as? String else { return nil }
                return DockerContainer(name: n,
                                       status: d["status"] as? String ?? "",
                                       ports: d["ports"] as? String ?? "",
                                       isComposeProject: (d["is_compose"] as? Bool) ?? false)
            }
        }
    }

    private func deploy() async {
        // v2.0.120：提交部署时立即收键盘（不等部署完成）
        focused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        busy = true
        defer { busy = false }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let j = try? await auth.json("/api/docker/deploy", method: "POST",
                                        body: ["name": n, "yaml": yaml]) {
            let ok = (j["ok"] as? Bool) ?? false
            message = (ok, j["message"] as? String ?? (ok ? "部署成功" : "部署失败"))
            if ok {
                name = ""
                yaml = ""
            }
        } else {
            message = (false, "请求失败，请检查连接")
        }
        await load()
    }

    private func action(_ n: String, _ act: String) async {
        // v2.0.102：网络失败明确反馈（原 try? 失败时 message 不变，点了毫无反应）
        guard let j = try? await auth.json("/api/docker/\(act)", method: "POST", body: ["name": n]) else {
            message = (false, "请求失败，请检查网络连接")
            await load()
            return
        }
        let ok = (j["ok"] as? Bool) ?? false
        message = (ok, j["message"] as? String ?? "")
        await load()
    }

    /// v2.0.113：容器操作分发——停止/重启先确认（防误触），其余直接执行
    private func handleContainerAction(_ c: DockerContainer, _ act: String) {
        if act == "stop" || act == "restart" {
            confirmAction = (c.name, act)
        } else {
            Task { await action(c.name, act) }
        }
    }
}

struct DockerContainer: Identifiable {
    let name: String
    let status: String
    let ports: String
    let isComposeProject: Bool
    var id: String { name }
}

// MARK: - v2.0.75 容器卡片（对标智能家居 DeviceCard：名称+状态点+运行状态+端口）

struct DockerContainerCard: View {
    let container: DockerContainer
    var hasUpdate = false   // v2.0.87p：检测到可升级才显示箭头
    var onUpgrade: () -> Void = {}   // v2.0.87：compose 项目升级按钮

    private var running: Bool { container.status.contains("Up") }
    private var color: Color { running ? .green : .red }

    /// v2.0.81：端口简化并入提示行（取第一个映射），所有卡片固定 3 行等高
    private var portSuffix: String {
        let tip = running ? "单击停止 · 长按删除" : "单击启动 · 长按删除"
        guard !container.ports.isEmpty else { return tip }
        let p = container.ports.components(separatedBy: ", ").first ?? container.ports
        return "\(tip) · \(p)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(container.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.6), radius: 4)
            }
            Text(running ? "运行中" : "已停止")
                .font(.system(size: 13.5, weight: .semibold))   // v2.0.86o：大字状态改小
                .foregroundStyle(.primary)
                .padding(.top, 6)
            // v2.0.87p：有更新才显示向上箭头（v2.0.87ao：网络由用户路由器解决，恢复箭头方案）
            HStack(spacing: 6) {
                Text(portSuffix)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if container.isComposeProject && hasUpdate {
                    Spacer(minLength: 4)
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onUpgrade()
                    } label: {
                        // v2.0.87ap：圆形升级按钮（圆底浅色 + 箭头）
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.14))
                            Image(systemName: "arrow.up")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(height: 96, alignment: .top)   // v2.0.81：固定高度 → 所有卡片等高统一
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // 单击停止 / 长按删除 提示
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - v2.0.86 镜像

struct DockerImage: Identifiable {
    let name: String
    let id: String
    let size: String
    let inUse: Bool   // v2.0.86n：被容器使用（绿点）/ 空镜像（红点）
    var idStr: String { id }
}

extension DockerSheet {
    func loadImages() async {
        if let j = try? await auth.json("/api/docker/images") {
            let arr = j["images"] as? [[String: Any]] ?? []
            images = arr.compactMap { d in
                guard let n = d["name"] as? String, let i = d["id"] as? String else { return nil }
                return DockerImage(name: n, id: i, size: d["size"] as? String ?? "",
                                   inUse: (d["in_use"] as? Bool) ?? false)
            }
        }
    }

    func rmImage(_ imageID: String) async {
        if let j = try? await auth.json("/api/docker/image/rm", method: "POST",
                                        body: ["id": imageID]) {
            message = ((j["ok"] as? Bool) ?? false, j["message"] as? String ?? "")
        } else {
            message = (false, "请求失败")
        }
        await loadImages()
    }
}

// MARK: - v2.0.86c 镜像卡片（1x2 网格，对标容器卡样式；单击=删除确认）

private struct DockerImageCard: View {
    let image: DockerImage

    private var inUse: Bool { image.inUse }
    private var color: Color { inUse ? .green : .red }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(image.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                // v2.0.86n：绿点=被容器使用，红点=空镜像
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.6), radius: 4)
            }
            Text(inUse ? "使用中" : "未使用")
                .font(.system(size: 13.5, weight: .semibold))   // v2.0.86o：大字状态改小
                .foregroundStyle(.primary)
                .padding(.top, 6)
            Text("\(image.id) · \(image.size) · 长按删除")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.top, 4)
        }
        .padding(12)
        .frame(height: 96, alignment: .top)   // 与容器卡等高
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - v2.0.86i 容器区 / 镜像区子视图（拆出主 body，规避 Swift 6 类型检查超时）

private struct ContainerSection: View {
    let containers: [DockerContainer]
    var onRefresh: () async -> Void
    var onAction: (DockerContainer, String) async -> Void
    var onDelete: (DockerContainer) -> Void
    var onUpgrade: (DockerContainer) -> Void   // v2.0.87 升级
    var updates: [String: Bool] = [:]   // v2.0.87p：容器名 → 有更新

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("已部署容器", systemImage: "shippingbox.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text("\(containers.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    Task { await onRefresh() }
                } label: {
                    // v2.0.92：刷新按钮胶囊化（图标+文字，点击区域大、不易误触）
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("刷新")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if containers.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("暂无容器，输入 YAML 点击部署")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                // 单击卡片 = 停止（运行中）或启动（已停止）；长按 = 删除确认
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(containers) { c in
                        DockerContainerCard(container: c, hasUpdate: updates[c.name] == true, onUpgrade: { onUpgrade(c) })
                            .onTapGesture {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                let act = c.status.contains("Up") ? "stop" : "start"
                                Task { await onAction(c, act) }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                                    onDelete(c)
                                } label: {
                                    Label("删除容器", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
    }
}

private struct ImageSection: View {
    let images: [DockerImage]
    var onRefresh: () async -> Void
    var onDelete: (DockerImage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("镜像管理", systemImage: "photo.stack")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.indigo)
                Spacer()
                Text("\(images.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    Task { await onRefresh() }
                } label: {
                    // v2.0.92：刷新按钮胶囊化（图标+文字，点击区域大、不易误触）
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("刷新")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.indigo)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.indigo.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if images.isEmpty {
                Text("暂无镜像")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                // v2.0.86n：2 列网格（同容器卡风格）+ 长按删除
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(images) { img in
                        DockerImageCard(image: img)
                            .contextMenu {
                                Button(role: .destructive) {
                                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                                    onDelete(img)
                                } label: {
                                    Label("删除镜像", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
    }
}

// MARK: - v2.0.86j 新建部署子视图（拆出主 body，规避 Swift 6 类型检查超时）

private struct DeploySection: View {
    @Binding var name: String
    @Binding var yaml: String
    @Binding var message: (ok: Bool, text: String)?
    var busy: Bool
    var onDeploy: () async -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("新建部署", systemImage: "plus.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            TextField("项目名（如 myapp）", text: $name)
                .font(.system(size: 14))
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                )
            if !name.isEmpty {
                Text("目录：/volume1/docker/\(name)/")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            // YAML 编辑器
            ZStack(alignment: .topTrailing) {
                TextEditor(text: $yaml)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .frame(minHeight: 180)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                    )
                    .overlay(alignment: .topLeading) {
                        if yaml.isEmpty {
                            Text(DockerSheet.yamlHint)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary.opacity(0.6))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
                if yaml.isEmpty {
                    Button {
                        yaml = DockerSheet.nginxTemplate
                    } label: {
                        Label("模板", systemImage: "text.badge.plus")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            }

            Button {
                focused = false
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { await onDeploy() }
            } label: {
                HStack(spacing: 8) {
                    if busy {
                        ProgressView().tint(.white)
                    }
                    Text(busy ? "部署中…" : "部署")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(colors: [.blue, .indigo],
                                   startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .foregroundStyle(.white)
                .shadow(color: .blue.opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty
                         || yaml.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(busy || name.trimmingCharacters(in: .whitespaces).isEmpty
                       || yaml.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )

        // 结果提示
        if let m = message {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: m.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(m.ok ? .green : .red)
                Text(m.text)
                    .font(.system(size: 12))
                    .foregroundStyle(m.ok ? Color.primary : Color.red)   // v2.0.86k：显式 Color（.primary 是 HierarchicalShapeStyle，三元类型冲突）
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((m.ok ? Color.green : Color.red).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - v2.0.87 容器升级

extension DockerSheet {
    func upgradeContainer(_ c: DockerContainer) async {
        guard !upgrading else { return }
        upgrading = true
        defer { upgrading = false }
        if let j = try? await auth.json("/api/docker/upgrade", method: "POST",
                                        body: ["name": c.name]) {
            let ok = (j["ok"] as? Bool) ?? false
            message = (ok, j["message"] as? String ?? (ok ? "升级完成" : "升级失败"))
        } else {
            message = (false, "请求失败，请检查连接")
        }
        await load()
        await loadImages()
        await loadUpdates()   // v2.0.102：升级后刷新更新状态（原升级箭头残留到重开弹窗）
    }
}

// MARK: - v2.0.87p 更新检测（有更新才显示升级箭头）

extension DockerSheet {
    func loadUpdates() async {
        if let j = try? await auth.json("/api/docker/updates") {
            updates = (j["updates"] as? [String: Bool]) ?? [:]
        }
    }
}
