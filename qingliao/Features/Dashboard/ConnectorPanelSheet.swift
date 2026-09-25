import Foundation
//
//  v3.9.74 P1.5 连接器面板（Muse 借鉴）：AI 能连上的"数字生活"收拢成一页
//
//  Muse 的核心卖点之一是接入六大类数字生活；轻聊的对应底座早已存在，只是入口散在三处：
//    · MCP 工具服务（App 配 key → Hermes 原生 MCP 工具）→ 设置页弹窗 MCPSettingsSheet
//    · 智能家居（HomeKit 风格设备卡 / 场景 / 自动化 / 规则）→ 看板页若干栏目
//    · 生活卡片（股票 / 资讯 / 快递 / 价格监控）→ 生活页 + 设置页 LifeCardsSettingsView
//  本面板不重复实现任何功能，只做"状态总览 + 直达入口"：四张状态卡各带在线/配置摘要，
//  点击跳到既有入口。零新后端接口，全部复用看板 30s 轮询已有数据与 /api/mcp/servers。
//

import SwiftUI

struct ConnectorPanelSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    // MARK: - 入口回调（宿主注入，跳既有页面/弹窗）
    var onOpenMCP: () -> Void
    var onOpenLifeCards: () -> Void

    // MARK: - 状态（看板已在轮询的派生值直传；MCP 数量本页自查）
    var haCount: Int
    var sceneCount: Int
    var automationCount: Int
    var ruleCount: Int

    @State private var mcpServers: [String] = []
    @State private var mcpLoading = true
    @State private var mcpError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    mcpCard
                    smartHomeCard
                    lifeCardsCard
                    hintFooter
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(easedBackground)
            .navigationTitle("连接器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await loadMCP() }
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
            status: "股票 · 资讯 · 快递 · 价格监控",
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

    private var easedBackground: some View {
        Color(.systemGroupedBackground).ignoresSafeArea()
    }

    // MARK: - 数据（复用 /api/mcp/servers，与 MCPSettingsSheet 同一接口）
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
}
