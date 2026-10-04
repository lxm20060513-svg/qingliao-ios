import SwiftUI

// MARK: - v3.9.88 登录页「使用指南」
//
// 给首次部署的用户一份 App 内教学：部署后端 → 部署 Hermes 插件 → 地址栏怎么填 →
// 初始用户名/密码。内容以两份公开仓 README 为真源（qingliao-backend /
// qingliao-hermes-plugin），文案全部脱敏（示例一律占位符，不含真实 IP/域名）。
// 排版口径：系统 sheet 玻璃底（不铺不透明底，见弹窗背景铁律）+ glassCard 分节卡 +
// 全 Theme 令牌；步骤数据驱动渲染，单 struct 保持小体量（防 type-check 超时）。
//
// 🚨 v4.0.47 文案纠错（2026-10-04，用户拍板「全改」）：此前与真实部署流程对不齐，
//    其中第 1 步是**硬错**——教用户直接改 compose 起服务，会漏掉必填的服务间 token。
//    · 第 1 步：改 compose 手填 → bash install.sh（token 自动生成，漏了收件箱/推送静默失效）
//    · 第 3 步：删「只填主机会自动补 https」的误导（App 对裸主机确实按 https，局域网明文必失败）
//    · 第 4 步：补「密码留空 = 随机生成在 data/initial_password.txt」
//    · 第 5 步：补 App 内「一键更新」与 ./update.sh --version
//    改文案只需动下面的 steps 字面量，无结构改动。

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
    /// v3.9.90：部署 skill 的下载地址（有值 = 在「自动部署」块里渲染成可点链接）
    let skillURL: String?
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
                "手动部署：克隆仓库 → 跑 bash install.sh（它会引导设置密码与上游 AI 端点）",
                "⚠️ 别跳过 install.sh：它自动生成 QL_INBOX_TOKEN / QL_PUSH_TOKEN；在 compose 里手填却漏了这两个，收件箱与推送会静默失效（没有任何报错）",
                "AI 记忆 / 文件管理等模块随服务开启；智能家居需另配 Home Assistant（QL_HA_URL / Token）",
            ],
            code: "# 手动部署（在装了 Docker 的机器上执行）\ngit clone https://github.com/lxm20060513-svg/qingliao-backend.git\ncd qingliao-backend\nbash install.sh          # 交互式：设密码 + 上游 AI 端点，并自动生成接口 token\ndocker compose logs -f   # 看启动日志（统一入口默认 9127）",
            skillCode: "# 第一步：下载部署 skill（GitHub），放进 Hermes 的 skills 目录\n# 第二步：对 Hermes 说一句「帮我部署轻聊」，\n# Hermes 会自动完成克隆、改配置、启动。",
            skillURL: "https://github.com/lxm20060513-svg/qingliao-backend/tree/main/skills/deployment/qingliao-deploy"
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
            skillCode: nil,
            skillURL: nil
        ),
        GuideStep(
            id: 3, icon: "globe", iconColor: .teal,
            title: "地址栏怎么填",
            brief: "回到登录页，在「服务器地址」里填后端所在机器的访问地址。",
            bullets: [
                "格式 = 协议 + 主机 + 端口：局域网填 http://你的NAS地址:9127，公网反代填 https://你的域名（非 443 端口要带上，如 https://你的域名:16666）",
                "只填主机不带协议时，App 会按 https 处理 —— 局域网明文部署请务必写成 http://你的地址:9127",
                "地址末尾带不带斜杠都行，App 会自动去掉；填完点「测试连接」验证连通后再登录",
                "历史地址会自动记住，下次从输入框右侧下拉快速切换",
            ],
            code: nil,
            skillCode: nil,
            skillURL: nil
        ),
        GuideStep(
            id: 4, icon: "person.text.rectangle", iconColor: .orange,
            title: "初始用户名和密码",
            brief: "后端首次启动会自动创建初始账号，无需手动注册。",
            bullets: [
                "用户名固定为 qingliao",
                "密码 = 部署时设置的 QL_PASSWORD（自动部署时 Hermes 会生成并告诉你）",
                // v4.0.47 复审修正：install.sh 的「回车留空」是**随机生成后静默写进 .env**
                //（install.sh:24-28 只 echo「.env 已生成」，不打印密码），并不落 initial_password.txt ——
                // 那个文件只在容器 QL_PASSWORD 真为空时由 auth_api.py:36-43 生成。原文案对 install.sh 路径
                //（= 本指南推荐的路径）是错的，照它去部署目录翻文件会找不到密码。
                "安装时直接回车让密码留空 = install.sh 随机生成一个并写进部署目录的 .env（不打印出来，用 cat .env 查看）",
                "只有没用 install.sh、QL_PASSWORD 真为空时，后端才会把随机密码写到 data/initial_password.txt",
                "登录后可在「设置 → 账号与安全 → 修改密码」改密码；开启「记住登录」可 7 天免登录",
            ],
            code: nil,
            skillCode: nil,
            skillURL: nil
        ),
        GuideStep(
            id: 5, icon: "arrow.triangle.2.circlepath", iconColor: .green,
            title: "以后怎么更新",
            brief: "后端出新版本后，用 App 内一键更新最省事；也可以到部署目录（你克隆仓库的那个文件夹）跑一条命令。不用重装、不用改配置。",
            bullets: [
                "最省事：App 内「设置 → 后端更新 → 一键更新」，有新版会挂提示，不用进终端（效果等同跑 update.sh）",
                "./update.sh —— 命令行更新到最新 + 自动重启。数据、会话、密码全部保留",
                "./update.sh --check 只看有没有新版；./update.sh --version v4.0.xx 更新到指定版本（要配套某个 App 版本时用）",
                "更新前会自动把数据备份到 backups/，万一新版有问题可回滚",
                "App「设置 → 关于轻聊」能看到当前后端版本，方便确认配套的是哪一版",
            ],
            code: "# 在后端目录里执行（把路径换成你自己的部署目录）\ncd 你的部署目录\n./update.sh",
            skillCode: nil,
            skillURL: nil
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 顶部导语：三步上手一览
    @ViewBuilder
    private var guideIntro: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("五步上手")
                .font(.system(size: Typography.headline, weight: .bold))
            Text("部署后端 → 部署插件 → App 登录。前三步约 10 分钟；以后更新只要一条命令（见第 5 步）。")
                .font(.system(size: Typography.subhead))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.sheetInset)
        // v3.9.90：glassCard 裸调 glassEffect 默认按 Capsule 渲染（clipShape 拦不住玻璃本体）
        // → 用户实机看到「每组文字上有大椭圆玻璃盖层」。改走全站卡底真源 dashboardCard
        // （显式 RoundedRectangle 16），与 AgentResultCard 先例同口径。
        .dashboardCard()
    }

    /// 底部备注
    @ViewBuilder
    private var guideFooter: some View {
        // v4.0.47：README 从「只在文字里提一句」改成可点链接（第 1 步有 skill 链接，页脚不该只有干文字）
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("更多细节（环境变量表、nginx 反代、可选模块）见两份 README：")
                .font(.system(size: Typography.caption))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: "https://github.com/lxm20060513-svg/qingliao-backend") {
                Link(destination: url) {
                    Label("后端仓库 README", systemImage: "arrow.up.right.square")
                        .font(.system(size: Typography.caption, weight: .semibold))
                }
            }
            if let url = URL(string: "https://github.com/lxm20060513-svg/qingliao-hermes-plugin") {
                Link(destination: url) {
                    Label("插件仓库 README", systemImage: "arrow.up.right.square")
                        .font(.system(size: Typography.caption, weight: .semibold))
                }
            }
        }
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
                    // v3.9.90：skill 下载地址渲染成可点链接（用户报「没看见下载地址」）
                    if let urlStr = step.skillURL, let url = URL(string: urlStr) {
                        Link(destination: url) {
                            Label("下载部署 skill（GitHub）", systemImage: "arrow.down.circle")
                                .font(.system(size: Typography.caption, weight: .semibold))
                                .foregroundStyle(step.iconColor)
                        }
                    }
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
        // v3.9.90：同上，裸 glassCard 的默认 Capsule 玻璃罩（大椭圆）→ dashboardCard 真源卡底。
        .dashboardCard()
    }
}
