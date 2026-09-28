import SwiftUI

// MARK: - v3.9.88 登录页「使用指南」
//
// 给首次部署的用户一份 App 内教学：部署后端 → 部署 Hermes 插件 → 地址栏怎么填 →
// 初始用户名/密码。内容以两份公开仓 README 为真源（qingliao-backend /
// qingliao-hermes-plugin），文案全部脱敏（示例一律占位符，不含真实 IP/域名）。
// 排版口径：系统 sheet 玻璃底（不铺不透明底，见弹窗背景铁律）+ glassCard 分节卡 +
// 全 Theme 令牌；步骤数据驱动渲染，单 struct 保持小体量（防 type-check 超时）。

/// 单个部署步骤的数据（步骤卡片按此渲染）
private struct GuideStep: Identifiable {
    let id: Int
    let icon: String
    let iconColor: Color
    let title: String
    let brief: String
    let bullets: [String]
    let code: String?
    /// v3.9.89：自动部署 skill 的安装命令（有值 = 该步骤支持「丢给 Hermes 自动部署」）
    let skillCode: String?
}

struct LoginGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// 步骤数据（集中声明，body 只做渲染）
    private let steps: [GuideStep] = [
        GuideStep(
            id: 1, icon: "server.rack", iconColor: .blue,
            title: "部署后端",
            brief: "在一台装有 Docker 的机器（NAS / 服务器 / 电脑）上拉起轻聊后端服务。推荐方式：把官方部署 skill 交给你的 AI 助手，说一句「帮我部署轻聊」即可自动完成。",
            bullets: [
                "自动部署（推荐）：下载部署 skill → 丢给 Hermes → 说「帮我部署轻聊」",
                "手动部署：克隆仓库 → 编辑 docker-compose.yml 设置密码与上游 AI 端点",
                "启动后 AI 记忆 / 智能家居 / 文件管理等模块自动随服务开启",
            ],
            code: "# 编辑 docker-compose.yml 设置密码与上游 AI 端点\ndocker compose up -d\n# 查看启动日志确认端口（默认 9127）\ndocker compose logs -f",
            skillCode: "# 部署 skill 走自动流程：把 skill 交给你的 Hermes，\n# 然后说一句「帮我部署轻聊」，Hermes 会自动完成克隆、改配置、启动。"
        ),
        GuideStep(
            id: 2, icon: "puzzlepiece.extension", iconColor: .indigo,
            title: "部署插件（接入 AI）",
            brief: "Hermes 平台插件把轻聊接入 AI 智能体，让 AI 能真正干活：查状态、控设备、执行任务。部署 skill 的第 4 步会自动完成本步。",
            bullets: [
                "一键安装脚本把插件放进 AI 网关的 plugins/ 目录",
                "在网关 config.yaml 启用 qingliao 平台并重启网关",
                "已有自建 AI 端点的话，后端也可直连（QL_HERMES_URL 填该端点即可跳过本步）",
            ],
            code: "bash <(curl -fsSL https://raw.githubusercontent.com/lxm20060513-svg/qingliao-hermes-plugin/main/install.sh) <你的profile>/plugins/qingliao-platform",
            skillCode: nil
        ),
        GuideStep(
            id: 3, icon: "globe", iconColor: .teal,
            title: "地址栏怎么填",
            brief: "回到登录页，在「服务器地址」里填后端所在机器的访问地址。",
            bullets: [
                "格式 = 协议 + 主机 + 端口：局域网如 http://192.168.1.100:9127，公网反代如 https://你的域名",
                "只填主机不确定协议时，App 会自动补 https",
                "地址末尾不要带斜杠；填完点「测试连接」验证连通后再登录",
                "历史地址会自动记住，下次从输入框右侧下拉快速切换",
            ],
            code: nil,
            skillCode: nil
        ),
        GuideStep(
            id: 4, icon: "person.text.rectangle", iconColor: .orange,
            title: "初始用户名和密码",
            brief: "后端首次启动会自动创建初始账号，无需手动注册。",
            bullets: [
                "用户名固定为 qingliao",
                "密码 = 部署时设置的 QL_PASSWORD（自动部署时 Hermes 会生成并告诉你）",
                "登录后可在「设置 → 账号与安全」修改密码；开启「记住登录」可 7 天免登录",
            ],
            code: nil,
            skillCode: nil
        ),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    guideIntro
                    ForEach(steps) { step in
                        GuideStepCard(step: step)
                    }
                    guideFooter
                }
                .padding(.horizontal, Spacing.sheetInset)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.section)
            }
            .navigationTitle("使用指南")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 顶部导语：三步上手一览
    @ViewBuilder
    private var guideIntro: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("三步上手")
                .font(.system(size: Typography.headline, weight: .bold))
            Text("部署后端 → 部署插件 → App 登录。全程约 10 分钟，跟着下面的步骤做即可。")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.sheetInset)
        .glassCard()
    }

    /// 底部备注
    @ViewBuilder
    private var guideFooter: some View {
        Text("更多细节（环境变量表、nginx 反代、可选模块）见后端与插件仓库的 README。")
            .font(.system(size: Typography.caption))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.xs)
    }
}

/// 单个步骤卡片：编号圆标 + 图标 + 标题，下接简介、要点列表、可选命令块
private struct GuideStepCard: View {
    let step: GuideStep

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            // 标题行：编号圆标 + 图标 + 标题
            HStack(spacing: Spacing.lg) {
                Text("\(step.id)")
                    .font(.system(size: Typography.subhead, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(step.iconColor, in: Circle())
                Image(systemName: step.icon)
                    .font(.system(size: Typography.body))
                    .foregroundStyle(step.iconColor)
                Text(step.title)
                    .font(.system(size: Typography.title, weight: .semibold))
                Spacer(minLength: 0)
            }
            // 简介
            Text(step.brief)
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 要点列表（自绘小圆点，缩进对齐）
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(Array(step.bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Circle()
                            .fill(step.iconColor.opacity(0.65))
                            .frame(width: 5, height: 5)
                        Text(bullet)
                            .font(.system(size: Typography.subhead))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // 可选命令块（等宽字体 + 深色底，可长按选择复制）
            if let code = step.code {
                Text(code)
                    .font(.system(size: Typography.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.xl)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                            .strokeBorder(.white.opacity(Tint.subtle), lineWidth: 0.8)
                    )
            }
            // v3.9.89：自动部署 skill 块（淡主色底以示「推荐路径」，与手动命令块区分）
            if let skillCode = step.skillCode {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Label("自动部署", systemImage: "wand.and.stars")
                        .font(.system(size: Typography.caption, weight: .semibold))
                        .foregroundStyle(step.iconColor)
                    Text(skillCode)
                        .font(.system(size: Typography.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Spacing.xl)
                .background(step.iconColor.opacity(Tint.faint),
                            in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                        .strokeBorder(step.iconColor.opacity(0.22), lineWidth: 0.8)
                )
            }
        }
        .padding(Spacing.sheetInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
