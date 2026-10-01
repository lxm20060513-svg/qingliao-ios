import Foundation
//
//  v3.9.74 P1.5 连接器面板（Muse 借鉴）：AI 能连上的"数字生活"收拢成一页
//
//  Muse 的核心卖点之一是接入六大类数字生活；轻聊的对应底座早已存在，只是入口散在三处：
//    · MCP 工具服务（App 配 key → Hermes 原生 MCP 工具）→ 设置页弹窗 MCPSettingsSheet
//    · 智能家居（HomeKit 风格设备卡 / 场景 / 自动化 / 规则）→ 看板页若干栏目
//    · 生活卡片（股票 / 资讯 / 快递）→ 生活页 + 设置页 LifeCardsSettingsView
//  本面板不重复实现任何功能，只做"状态总览 + 直达入口"：状态卡各带在线/配置摘要，
//  点击跳到既有入口。零新后后端接口，全部复用看板 30s 轮询已有数据、
//  /api/mcp/servers、/api/mail/accounts、/api/agent/clouddrive/drives 与 AppPermissionKit。
//
//  v4.0.x 七项待办第 3 项「接入中心一页」：原来只有 MCP / 智能家居 / 生活卡片三张卡，
//  邮件与网盘的入口散在「设置」里，用户要翻两层才看到自己到底接了什么。
//  这里补齐 邮件 / 网盘 / 日历与提醒 三张卡，口径统一成「状态 + 能不能一键开」。
//    · 邮件：一键开关 = 「允许 AI 直接发信」；真闸门在后端账号配置（AppPermissionKit.status(.mail) 注释），
//      所以开关走**读改写**：GET /api/mail/accounts 拿全字段 → 只翻 allow_direct_send → POST 回去。
//      ⚠️ 绝不能只 POST {id, allow_direct_send}：后端 normalize() 会把没传的
//      imap_security/smtp_security 写成 ""、nickname 写成 ""、default 写成 false —— 那是破坏账号。
//    · 网盘：后端只有 add/remove、没有 enable 位，故只给状态 + 入口，不假造一个开关。
//    · 日历/提醒：系统授权 + 单项「允许 AI 操作」双闸门都是本地 UserDefaults/EventKit，可真一键开。
//

import SwiftUI

struct ConnectorPanelSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    // MARK: - 入口回调（宿主注入，跳既有页面/弹窗）
    var onOpenMCP: () -> Void
    var onOpenLifeCards: () -> Void
    /// v4.0.x 第 3 项：邮件接入设置页（设置 → 邮件）
    var onOpenMail: () -> Void
    /// v4.0.x 第 3 项：网盘接入设置页（设置 → 文件管理）
    var onOpenCloudDrive: () -> Void

    // MARK: - 状态（看板已在轮询的派生值直传；MCP/邮件/网盘数量本页自查）
    var haCount: Int
    var sceneCount: Int
    var automationCount: Int
    var ruleCount: Int

    @State private var mcpServers: [String] = []
    @State private var mcpLoading = true
    @State private var mcpError = false

    // v4.0.x 第 3 项：邮件
    @State private var mailAccounts: [MailAccountItem] = []
    @State private var mailLoading = true
    @State private var mailError = false
    @State private var mailBusy = false
    @State private var mailNote: String?

    // v4.0.x 第 3 项：网盘
    @State private var drives: [CloudDriveItem] = []
    @State private var driveLoading = true
    @State private var driveError = false

    // v4.0.x 第 3 项：日历 / 提醒（EventKit 授权 + AI 单项闸门）
    @State private var calState: PermissionState = .notDetermined
    @State private var remState: PermissionState = .notDetermined
    @State private var calAI = false
    @State private var remAI = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    mailCard
                    driveCard
                    calendarCard
                    mcpCard
                    smartHomeCard
                    lifeCardsCard
                    hintFooter
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // v3.9.23 决策：弹窗背景一律不覆盖，让系统默认玻璃生效。
            // 原来这里挂了 .background(easedBackground) → Color(.systemGroupedBackground) 实色底，
            // 把「连接器」弹窗变成实色页、与其它半屏玻璃弹窗不统一。v4.0.x 移除（连带 easedBackground 属性）。
            .navigationTitle("连接器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await loadAll() }
        }
    }

    // MARK: - 邮件接入（v4.0.x 第 3 项）
    private var mailCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            connectorCard(
                icon: "envelope.fill", tint: .blue,
                title: "邮件接入",
                status: mailStatusText,
                detail: mailStatusDetail,
                tap: { onOpenMail() })
            // 一键开关：允许 AI 直接发信（后端账号真闸门）。
            // 只在**恰好一个**账号时给开关 —— 多账号时每个账号各有自己的闸门，
            // 一个总开关说清不了"到底哪个账号能发"，那种情况下引导去邮件页逐个配。
            if let acc = soleMailAccount {
                Toggle(isOn: Binding(
                    get: { acc.allowDirectSend && !mailBusy },
                    set: { newVal in Task { await setDirectSend(acc, on: newVal) } }
                )) {
                    Text("允许 AI 直接发信")
                        .font(.system(size: Typography.subhead))
                }
                .qingliaoSwitch(hideLabel: false)
                .disabled(mailBusy)
                if let n = mailNote {
                    Text(n)
                        .font(.system(size: Typography.tiny))
                        .foregroundStyle(n.hasPrefix("❌") ? Color.red : Color.secondary)
                }
            }
        }
    }

    private var soleMailAccount: MailAccountItem? {
        mailAccounts.count == 1 ? mailAccounts[0] : nil
    }

    private var mailStatusText: String {
        if mailLoading { return "加载中…" }
        if mailError { return "状态未知（点开查看）" }
        if mailAccounts.isEmpty { return "未接入 · 点开添加" }
        let direct = mailAccounts.filter { $0.allowDirectSend }.count
        if direct == 0 { return "已接入 \(mailAccounts.count) 个账号 · AI 只出草稿" }
        return "已接入 \(mailAccounts.count) 个账号 · \(direct) 个可直发"
    }

    private var mailStatusDetail: String {
        if mailError { return "读不到邮件账号状态：" + (mailNote ?? "网络错误") }
        return mailAccounts.map(\.email).joined(separator: " · ")
    }

    /// 翻「允许 AI 直接发信」：读全字段 → 只改这一位 → 整份写回。
    /// 后端 save_account 走 normalize()，**没传的字段会被写成空值**（见文件头警告），
    /// 所以这里必须把 _public() 的全字段带齐，只翻 allow_direct_send。
    private func setDirectSend(_ a: MailAccountItem, on: Bool) async {
        mailBusy = true
        mailNote = nil
        defer { mailBusy = false }
        let body: [String: Any] = [
            "id": a.id, "email": a.email, "nickname": a.nickname,
            "imap_host": a.imapHost, "imap_port": a.imapPort, "imap_security": a.imapSecurity,
            "smtp_host": a.smtpHost, "smtp_port": a.smtpPort, "smtp_security": a.smtpSecurity,
            "allow_direct_send": on, "default": a.isDefault,
        ]
        do {
            let d = try await auth.json("/api/mail/accounts", method: "POST", body: body)
            guard (d["ok"] as? Bool) ?? false else {
                mailNote = "❌ 保存失败：" + (d["error"] as? String ?? "服务器拒绝")
                return
            }
            mailNote = on ? "已开启：AI 可直接发信" : "已关闭：AI 只出草稿"
            await loadMail()
        } catch {
            mailNote = "❌ 保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 网盘接入（v4.0.x 第 3 项）
    private var driveCard: some View {
        connectorCard(
            icon: "externaldrive.fill", tint: .teal,
            title: "网盘接入",
            status: driveStatusText,
            detail: driveStatusDetail,
            tap: { onOpenCloudDrive() })
    }

    private var driveStatusText: String {
        if driveLoading { return "加载中…" }
        if driveError { return "状态未知（点开查看）" }
        if drives.isEmpty { return "未接入 · 点开添加" }
        let bad = drives.filter { !$0.isReady }.count
        return bad == 0 ? "已接入 \(drives.count) 个 · 全部可用"
                        : "已接入 \(drives.count) 个 · \(bad) 个异常"
    }

    private var driveStatusDetail: String {
        if drives.isEmpty { return "接入网盘后，AI 可直接浏览和读取你的文件" }
        return drives.map { $0.nickname.isEmpty ? $0.name : $0.nickname }
            .joined(separator: " · ")
    }

    // MARK: - 日历 / 提醒（v4.0.x 第 3 项：唯一两个能真一键开的）
    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            connectorCard(
                icon: "calendar", tint: .orange,
                title: "日历与提醒",
                status: calStatusText,
                detail: "AI 可读日程与待办查空闲；经你确认后新建日程、提醒。",
                tap: { Task { await requestCalendar() } })
            HStack(spacing: Spacing.lg) {
                gateToggle("日历", state: calState, aiOn: calAI) { newVal in
                    Task { await setGate(.calendar, on: newVal, state: $calState, ai: $calAI) }
                }
                gateToggle("提醒", state: remState, aiOn: remAI) { newVal in
                    Task { await setGate(.reminders, on: newVal, state: $remState, ai: $remAI) }
                }
            }
        }
    }

    private var calStatusText: String {
        let cal = calState == .granted
        let rem = remState == .granted
        switch (cal, rem) {
        case (true, true):  return "已授权 · AI 可读写"
        case (true, false): return "日历已授权 · 提醒未授权"
        case (false, true): return "提醒已授权 · 日历未授权"
        case (false, false): return "未授权 · 点下方开关"
        }
    }

    /// 一个能力 = 系统授权 + 「允许 AI 操作」。系统授权只能真弹框请求，
    /// 所以开关打开时若还没授权，先请求系统授权；用户拒绝就**把开关弹回去**，不许留一个假绿。
    private func gateToggle(_ name: String, state: PermissionState, aiOn: Bool,
                           _ onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(
            get: { aiOn && state == .granted },
            set: onChange
        )) {
            Text(name)
                .font(.system(size: Typography.subhead))
        }
        .qingliaoSwitch(hideLabel: false)
    }

    private func requestCalendar() async {
        calState = await AppPermissionKit.request(.calendar)
        remState = await AppPermissionKit.request(.reminders)
    }

    private func setGate(_ c: AppCapability, on: Bool,
                         state: Binding<PermissionState>, ai: Binding<Bool>) async {
        if on {
            let st = await AppPermissionKit.request(c)
            state.wrappedValue = st
            guard st == .granted else {
                ai.wrappedValue = false
                return
            }
            // 总闸没开时单项开关开了也不生效（AppPermissionKit.aiControlEnabled 首行就查总闸）。
            // 这里不偷偷替用户改总闸 —— 那是另一个决定，只在提示里说清。
            ai.wrappedValue = true
            AppPermissionKit.setAIControlEnabled(true, for: c)
        } else {
            ai.wrappedValue = false
            AppPermissionKit.setAIControlEnabled(false, for: c)
        }
    }

    // MARK: - MCP 工具服务
    private var mcpCard: some View {
        connectorCard(
            icon: "puzzlepiece.extension.fill", tint: .teal,
            title: "MCP 工具服务",
            status: mcpLoading ? "加载中…"
                : mcpError ? "状态未知（点开查看）"
                : mcpServers.isEmpty ? "未配置 · 点开添加"
                : "已连接 \(mcpServers.count) 个服务",
            detail: mcpServers.isEmpty ? "接入外部工具后，AI 可以直接查快递、搜网页、控制更多设备"
                                       : mcpServers.joined(separator: " · "),
            tap: { onOpenMCP() })
    }

    // MARK: - 智能家居
    private var smartHomeCard: some View {
        connectorCard(
            icon: "house.fill", tint: .orange,
            title: "智能家居",
            status: haCount > 0 ? "在线 · \(haCount) 个可用实体" : "未读到设备",
            detail: "场景 \(sceneCount) · 自动化 \(automationCount) · 自动规则 \(ruleCount)，看板可控制与编辑",
            tap: { dismiss() })   // 关面板即回看板（智能家居栏目就在看板上）
    }

    // MARK: - 生活卡片
    private var lifeCardsCard: some View {
        connectorCard(
            icon: "rectangle.grid.2x2.fill", tint: .green,
            title: "生活卡片",
            status: "股票 · 资讯 · 快递",
            detail: "在生活页常驻展示，点开可配置订阅项",
            tap: { onOpenLifeCards() })
    }

    // MARK: - 通用卡片样式（沿用看板 dashboardCard 口径）
    private func connectorCard(icon: String, tint: Color, title: String,
                               status: String, detail: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: Typography.title))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(Tint.subtle), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: Typography.body, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(status)
                        .font(.system(size: Typography.subhead))
                        .foregroundStyle(tint)
                    Text(detail)
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(.tertiary)
            }
            .padding(Spacing.lg)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    private var hintFooter: some View {
        Text("AI 在聊天里可直接使用以上能力：让 Agent 查快递、执行场景、报价监控，都会自动调用。")
            .font(.system(size: Typography.caption))
            .foregroundStyle(.tertiary)
            .padding(.top, Spacing.sm)
    }

    // v3.9.23 决策：背景不覆盖，让系统默认玻璃生效。
    // v4.0.x 移除了 easedBackground（Color(.systemGroupedBackground).ignoresSafeArea()）——
    // 它是 sheet 根视图上的实色底，正是「弹窗风格不统一」的成因之一。

    // MARK: - 数据（复用 /api/mcp/servers，与 MCPSettingsSheet 同一接口）
    /// v4.0.x 第 3 项：四路并发加载。串行会白等 4 个 RTT，弹窗打开明显发木。
    private func loadAll() async {
        mcpLoading = true; mcpError = false
        mailLoading = true; mailError = false
        driveLoading = true; driveError = false
        async let a = loadMCP()
        async let b = loadMail()
        async let c = loadDrives()
        // 日历/提醒状态是本地同步读，不占网络
        calState = await AppPermissionKit.status(of: .calendar)
        remState = await AppPermissionKit.status(of: .reminders)
        calAI = AppPermissionKit.aiControlEnabled(.calendar)
        remAI = AppPermissionKit.aiControlEnabled(.reminders)
        _ = await (a, b, c)
    }

    private func loadMCP() async {
        mcpLoading = true
        mcpError = false
        defer { mcpLoading = false }
        do {
            let d = try await auth.json("/api/mcp/servers")
            guard let ok = d["ok"] as? Bool, ok,
                  let sv = d["servers"] as? [String: Any] else {
                mcpError = true
                return
            }
            mcpServers = sv.keys.sorted()
        } catch {
            mcpError = true
        }
    }

    /// v4.0.x 第 3 项：邮件账号状态（复用 MailSettingsSheet 同一接口 /api/mail/accounts）
    private func loadMail() async {
        defer { mailLoading = false }
        do {
            let d = try await auth.json("/api/mail/accounts")
            guard (d["ok"] as? Bool) ?? false else {
                mailError = true
                return
            }
            mailAccounts = SettingsLoad.list(d, key: "accounts", make: MailAccountItem.init)
        } catch {
            mailError = true
        }
    }

    /// v4.0.x 第 3 项：网盘状态。⚠️ 必须走 /api/agent/clouddrive 别名（lucky 16666 白名单口径，
    /// 原 /api/clouddrive 在 App 主链路被 404，见 CloudDriveSettingsSheet.load 的注释）。
    private func loadDrives() async {
        defer { driveLoading = false }
        do {
            let d = try await auth.json("/api/agent/clouddrive/drives")
            guard (d["ok"] as? Bool) ?? false else {
                driveError = true
                return
            }
            drives = SettingsLoad.list(d, key: "drives", make: CloudDriveItem.init)
        } catch {
            driveError = true
        }
    }
}
