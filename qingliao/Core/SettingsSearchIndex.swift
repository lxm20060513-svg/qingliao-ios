import Foundation

// MARK: - v4.0.22 设置页搜索（纯逻辑层）
//
// 用户诉求：「设置项太多，想搜自己知道名字的那一项」（顶部搜索框）。
//
// 为什么把索引/匹配放 Core 的纯逻辑文件里（无 SwiftUI）：
//   · 真值表能直接编译本文件断言匹配规则（多词、大小写、空查询、无命中）；
//   · 还能断言「每条 route 都真的在 SettingsCore 里被处理」——设置项改名/删弹窗时，
//     索引不会悄悄指向一个不存在的目的地（那种坏法是：搜到了，点下去毫无反应）。
//
// ⚠️ route 约定（与 SettingsCore.openSearchEntry 的 switch 一一对应，真值表钉着）：
//   · 弹窗类：`<flag 去 show 前缀>`（如 "model" → showModelSheet = true）
//   · 行内展开类：`<flag 去 show 前缀>`（如 "agentHelp" → showAgentHelp = true，同时滚到所在分组）
//   · 需要滚到分组看的开关类：`sec:<分组>`（结果行点下去清空搜索并滚到那个分组）

/// 一条可搜索的设置项
struct SettingsSearchEntry: Identifiable, Equatable {
    /// 打开方式（见文件头约定）
    let route: String
    /// 行标题，与设置页显示**逐字一致**（搜到的和看到的是同一个东西）
    let title: String
    /// SF Symbol（与设置页那一行同图标）
    let icon: String
    /// 所属分组名（结果行副标题 + 无命中时的提示语）
    let group: String
    /// 额外检索词：别名 / 场景词 / 英文名（用户想不起来标题时会用的词）
    let keywords: [String]

    /// ForEach 用；title 全表唯一，route 会复用（三个开关都滚到同一个分组）→ 两者拼起来才唯一
    var id: String { route + "|" + title }
}

enum SettingsSearchIndex {

    /// 设置页全部可搜索项。**新增设置行时同步加一条**，否则就是「肉眼可见却搜不到」，
    /// 用户只会觉得搜索坏了。分组顺序与设置页从上到下一致。
    static let entries: [SettingsSearchEntry] = [
        // ── 账号与安全 ──
        .init(route: "password", title: "修改密码", icon: "key.horizontal.fill", group: "账号与安全",
              keywords: ["密码", "改密码", "登录密码"]),
        .init(route: "sec:account", title: "Face ID 登录", icon: "faceid", group: "账号与安全",
              keywords: ["面容", "人脸", "解锁", "biometric"]),
        .init(route: "sec:account", title: "App 锁", icon: "lock.fill", group: "账号与安全",
              keywords: ["启动锁", "锁屏", "安全"]),

        // ── 连接与模型 ──
        .init(route: "conn", title: "连接设置", icon: "globe.asia.australia.fill", group: "连接与模型",
              keywords: ["服务器", "地址", "端口", "后端", "登录"]),
        .init(route: "model", title: "模型管理", icon: "cpu.fill", group: "连接与模型",
              keywords: ["模型", "主模型", "供应商", "model", "provider"]),
        .init(route: "wechatChannel", title: "微信通道模型", icon: "message.fill", group: "连接与模型",
              keywords: ["微信", "通道", "通道模型"]),
        .init(route: "ha", title: "HA 设置", icon: "house.fill", group: "连接与模型",
              keywords: ["智能家居", "home assistant", "家居", "设备"]),
        .init(route: "mcp", title: "MCP 工具服务", icon: "puzzlepiece.extension.fill", group: "连接与模型",
              keywords: ["mcp", "工具", "插件", "服务"]),
        .init(route: "mail", title: "邮件接入", icon: "envelope.fill", group: "连接与模型",
              keywords: ["邮箱", "邮件", "163"]),
        .init(route: "cloudDrive", title: "网盘接入", icon: "externaldrive.fill", group: "连接与模型",
              keywords: ["网盘", "云盘", "夸克", "上传"]),
        .init(route: "appPermissions", title: "权限与 AI 操控", icon: "lock.shield.fill", group: "连接与模型",
              keywords: ["权限", "授权", "ai 操控", "操控"]),
        .init(route: "localModels", title: "管理模型", icon: "shippingbox.fill", group: "连接与模型",
              keywords: ["本地模型", "下载模型", "ollama", "本地"]),

        // ── AI 智能 ──
        .init(route: "kb", title: "知识库", icon: "books.vertical.fill", group: "AI 智能",
              keywords: ["知识库", "文档", "检索", "问答"]),
        .init(route: "memory", title: "AI 记忆", icon: "brain.head.profile", group: "AI 智能",
              keywords: ["记忆", "长期记忆", "记住"]),
        .init(route: "cardGallery", title: "能力示例", icon: "rectangle.grid.2x2.fill", group: "AI 智能",
              keywords: ["能力", "示例", "卡片形态", "卡片"]),
        .init(route: "sec:ai", title: "上下文自动压缩", icon: "arrow.down.right.and.arrow.up.left", group: "AI 智能",
              keywords: ["压缩", "token", "上下文", "历史消息"]),
        .init(route: "sec:ai", title: "智能路由", icon: "arrow.triangle.branch", group: "AI 智能",
              keywords: ["路由", "分流", "自动选择"]),
        .init(route: "sec:ai", title: "微信推送", icon: "paperplane.fill", group: "AI 智能",
              keywords: ["推送", "微信", "通知", "自动化"]),

        // ── 数据与自动化 ──
        .init(route: "secrets", title: "密码管理", icon: "key.fill", group: "数据与自动化",
              keywords: ["凭据", "密码", "密钥", "账号"]),
        .init(route: "tasks", title: "定时任务", icon: "clock.badge.fill", group: "数据与自动化",
              keywords: ["定时", "任务", "cron", "计划"]),
        .init(route: "history", title: "执行历史", icon: "clock.arrow.circlepath", group: "数据与自动化",
              keywords: ["历史", "执行记录", "记录"]),
        .init(route: "logs", title: "日志", icon: "doc.text.fill", group: "数据与自动化",
              keywords: ["日志", "log", "排错"]),
        .init(route: "diagnostics", title: "诊断", icon: "stethoscope", group: "数据与自动化",
              keywords: ["诊断", "排障", "上报", "崩溃"]),
        .init(route: "pinPath", title: "钉一钉存储", icon: "pin.fill", group: "数据与自动化",
              keywords: ["钉一钉", "pin", "存储路径"]),
        .init(route: "lifeCards", title: "生活卡片", icon: "rectangle.grid.2x2", group: "数据与自动化",
              keywords: ["生活卡片", "首页卡片", "卡片"]),
        .init(route: "quickReminder", title: "定时提醒", icon: "bell.badge.fill", group: "数据与自动化",
              keywords: ["提醒", "闹钟", "定时提醒"]),
        .init(route: "filesManager", title: "文件管理", icon: "folder.fill", group: "数据与自动化",
              keywords: ["文件", "上传", "下载", "管理"]),

        // ── Agent 设置 ──
        .init(route: "proactive", title: "主动 Agent", icon: "bolt.horizontal.circle.fill", group: "Agent 设置",
              keywords: ["主动", "开口", "预算", "静默", "复盘"]),
        .init(route: "agentModel", title: "Agent 模型", icon: "cpu.fill", group: "Agent 设置",
              keywords: ["agent", "模型", "智能体"]),
        .init(route: "agentHelp", title: "使用说明", icon: "questionmark.circle.fill", group: "Agent 设置",
              keywords: ["说明", "用法", "帮助", "怎么用", "agent 说明"]),
        .init(route: "agentKeywords", title: "Agent 关键词", icon: "text.badge.plus", group: "Agent 设置",
              keywords: ["关键词", "分流词", "匹配词"]),
        .init(route: "agentMemory", title: "Agent 记忆", icon: "brain.head.profile", group: "Agent 设置",
              keywords: ["agent 记忆", "规则", "记忆"]),

        // ── 外观与显示 ──
        // P0-1 界面模式（工作模式 / 生活模式）：排在分组最前，与设置页那一行的位置一致
        .init(route: "uiMode", title: "界面模式", icon: "rectangle.2.swap", group: "外观与显示",
              keywords: ["界面", "模式", "工作模式", "生活模式", "工作台", "切换"]),
        .init(route: "appearance", title: "外观", icon: "circle.lefthalf.filled", group: "外观与显示",
              keywords: ["主题", "深浅色", "暗黑", "行高", "流光"]),
        .init(route: "pet", title: "AI形象", icon: "face.smiling.inverse", group: "外观与显示",
              keywords: ["宠物", "卡通", "形象", "头像", "表情"]),
        .init(route: "sec:appearance", title: "震动反馈", icon: "iphone.radiowaves.left.and.right", group: "外观与显示",
              keywords: ["震动", "触感", "haptic", "反馈"]),
        .init(route: "sec:appearance", title: "首页快捷卡片", icon: "rectangle.grid.2x2.fill", group: "外观与显示",
              keywords: ["快捷卡片", "首页卡片", "网格", "开关"]),
        .init(route: "pet", title: "聊天页宠物", icon: "eye.slash", group: "外观与显示",
              keywords: ["宠物", "卡通", "聊天页", "header", "显示", "开关"]),
        .init(route: "homeShortcuts", title: "桌面快捷方式", icon: "square.grid.2x2.fill", group: "外观与显示",
              keywords: ["桌面", "快捷方式", "长按图标"]),

        // ── 关于 ──
        .init(route: "about", title: "关于轻聊", icon: "info.circle.fill", group: "关于",
              keywords: ["关于", "版本", "更新", "版本号"]),
    ]

    /// 模糊匹配：空格分词 → **每个词都要命中**（"模型 管理" 这种多词查询才符合直觉）；
    /// 大小写不敏感；中文按整体子串匹配（不引分词库 —— 设置项标题都很短，子串足够）。
    ///
    /// ⚠️ 检索范围 = **标题 + 关键词**，**不含分组名**：分组名如「连接与模型」含「模型」二字，
    /// 一旦把分组名算进去，搜「模型」会把整个分组的 9 项（连接设置/HA/MCP/邮件/网盘…）全带出来
    /// —— 结果越准用户才越敢用（反例见真值表）。
    /// 空查询返回空数组（调用方据此隐藏结果区），不是返回全部。
    static func match(_ query: String) -> [SettingsSearchEntry] {
        let tokens = query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return [] }
        return entries.filter { entry in
            let haystack = (entry.title + " " + entry.keywords.joined(separator: " ")).lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }
}
