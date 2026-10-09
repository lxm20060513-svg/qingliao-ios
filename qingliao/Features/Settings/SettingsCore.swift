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

// MARK: ===== 以下原为 Features/Settings/SettingsView.swift =====

// MARK: - 设置页（iOS 设置风格分组列表，全部功能行可用）

struct SettingsView: View {
    @Environment(AuthStore.self) var auth
    // v3.4.28：横屏限宽
    @Environment(\.horizontalSizeClass) private var hSizeSettings
    @AppStorage("qingliao_appearance") var appearance = "system"   // dark/light/system（默认跟随系统）
    /// v4.0.9 点击震动总开关（与 Haptics.enabledKey 同一个 key，两边共用勿各写一份）
    /// ⚠️ 必须放在 **struct 主体**（本行附近），不能放 extension ——
    /// extension 不许含存储属性，Archive 报 "extensions must not contain stored
    /// properties" + "declared inside an extension cannot have a wrapper"（-parse 查不出）。
    @AppStorage(Haptics.enabledKey) private var hapticsOn = true

    // v4.0.10（用户：「在设置里增加可以关掉首页快捷卡片功能」）：首页快捷卡片总开关。
    // 与聊天页绑同一个键（Core/HomeCardStore.enabledKey）→ 那边立刻跟着变。
    @AppStorage(HomeCardStore.enabledKey) private var homeCardsOn = HomeCardStore.enabledDefault

    // v4.0.69（用户 2026-10-07）：「聊天页宠物」开关已从本页搬到 **AI形象** 页（PetStudioSheet）。
    // 键仍是 PetKeys.headerVisible（单一真源），只是入口换了地方 —— 这里**不要再挂同名 @AppStorage**，
    // 否则就是「同一个开关两处入口」的回退（用户口径：跟形象相关的设置收进形象页）。

    // v2.0.83c：连接设置二级页（服务器地址/测试连接/会话存储位置收进二级）
    @State var showConnSettings = false
    @State var showPasswordSheet = false
    @State var showSecrets = false
    // v2.0.81：知识库页面
    @State var showKB = false
    // v2.0.87：AI 记忆
    @State var showMemory = false
    @State var memoryCount = 0
    @State var showTasks = false
    @State var showLogs = false
    /// v4.0.61：搜索「钉一钉存储」直达——钉一钉存储行已搬进「连接设置」页（用户 2026-10-05），
    /// 本开关只负责「打开连接设置并让它自己把那颗 sheet 弹出来」，页内 UI 归 ConnSettingsView
    @State var connOpenPinPath = false
    @State var showAppearance = false   // v3.0.4：外观弹窗（与云端统一）
    // v3.9.82：桌面图标长按快捷方式（候选清单里自己挑 4 项显示；iOS 桌面长按菜单上限就是 4）
    // v4.0.x：候选已随 OrbQuickAction.all 长到 8 项 —— 候选列表是动态的（HomeShortcut.candidates），
    //         这里与弹窗都不许再写死项数。
    @State var showHomeShortcuts = false
    @AppStorage(HomeShortcutStore.defaultsKey) var homeShortcutsRaw = ""
    @State var scrollPos = ScrollPosition()
    @State var showModelSheet = false
    @State var showWechatChannel = false   // v3.0.19：微信窗通道模型设置
    @State var showAbout = false
    @State var confirmLogout = false   // v3.0.5 review fix：退出登录二次确认（与云端一致）
    @State var secretCount = 0
    @State var showHASettings = false
    // v3.5.0：MCP 工具服务管理弹窗
    @State var showMCPSettings = false
    // v3.9.95：权限与 AI 操控（日历/相册/通知/HomeKit 的授权与 AI 开关）
    @State var showAppPermissions = false
    // v4.0.x：邮件接入（IMAP/SMTP 邮箱账号，AI 可收发邮件）
    @State var showMailSettings = false
    // v4.0.x：网盘接入（夸克等官方 skill 包 + 授权码；用户口径=放设置，不进连接器面板）
    @State var showCloudDrive = false
    // v3.5.x：生活卡片设置（股票 / 资讯 / 快递）
    @State var showLifeCards = false
    /// v4.0.82：Dock 栏设置（顺序 / 隐藏）—— 用户 2026-10-09 要求
    @State var showDockLayout = false
    // v3.9.32：一句话本地定时提醒 / 文件管理
    @State var showQuickReminder = false
    @State var showFilesManager = false
    // v3.0.17：聊天字体大小从一级菜单移除（外观二级菜单持有），fontSize 声明一并清理
    // v3.0.9：外观下天气城市已移除（天气城市设定在看板 WeatherBadge 点按处），相关状态一并清理
    // v2.0.101：Agent 使用说明内联展开
    @State var showAgentHelp = false
    // v4.0.11：主动 Agent 设置弹窗（后端 proactive_agent：总开关/预算/静默/事件源/复盘）
    @State var showProactive = false
    // v2.0.105：Agent 关键词管理弹窗
    @State var showAgentKeywords = false
    // v2.0.113：Agent 记忆弹窗 + 计数
    @State var showAgentMemory = false
    @State var agentRuleCount = 0
    // v3.0.20：Agent 模型自定义（独立于主模型，可单独指定 Agent 使用的模型）
    @State var showAgentModelSheet = false
    @AppStorage(UserDefaultsKey.agentModel) var agentModel = ""
    @AppStorage(UserDefaultsKey.agentProvider) var agentProvider = ""
    // v2.0.116：执行历史弹窗
    @State var showHistory = false
    // v3.4.25：崩溃日志查看/导出弹窗
    // v3.6.0：原独立「崩溃日志」弹窗整合进「诊断」页（DiagnosticsView 内含崩溃日志分组），
    //         避免两个重复又可能互相矛盾的入口；本页不再单独持有该弹窗状态。
    @State var showDiagnostics = false
    // v2.0.117：本地模型（Ollama 断网兜底）
    @AppStorage("qingliao_local_model") var localModelOn = false
    @State var localModelSyncing = false   // v-review fix：程序化回写开关时抑制 onChange 回声 POST
    @State var localStatusText = "未开启"
    @State var localUpdateText = "断网兜底用本地模型"
    @State var localChecking = false
    // v2.0.118：本地模型管理弹窗
    @State var showLocalModels = false
    @State var showCardGallery = false   // v3.9.26：能力示例（卡片画廊）
    // v3.0.10：视觉模型配置弹窗（已移至模型管理弹窗内）
    // v2.0.113：微信推送开关（同步后端 push_settings.json）
    @AppStorage("qingliao_push_weixin") var pushWeixin = true
    // v3.0.81：上下文管理（v4.0.x：默认值与真源 ContextTuning.defaultThreshold 同源，勿再写字面量）
    @AppStorage("qingliao_context_auto_compress") var contextAutoCompress = false
    @AppStorage("qingliao_context_threshold") var contextThreshold = ContextTuning.defaultThreshold
    // v3.9.56：TypeSafe 智能路由（设置页开关 + 就地展开）。后端是唯一真源，所以用 @State 影子状态
    // 而不是 @AppStorage —— 本地也存一份的话，换设备/运维改了后端配置，UI 就会显示假状态。
    @State var tsRouting = TypesafeRouting.fallback
    @State var tsBreaker = TypesafeBreaker.closed
    @State var tsSyncing = false   // 读回来时抑制回声 POST（同 localModelSyncing 口径）
    @State var tsBusy = false
    @State var tsError = ""
    // v2.0.88：Face ID 登录开关（关闭后删除 Keychain 凭据，登录页不再显示快捷按钮）
    @AppStorage("qingliao_faceid_login") var faceIDLogin = true
    @State var faceIDAuthFailed = false   // v2.0.89f：开关打开时系统授权失败提示
    // v2.0.92：App 锁开关（启动时 Face ID 验证）
    @AppStorage("qingliao_app_lock") var appLockOn = false
    @State var appLockAuthFailed = false
    // v2.0.128：AI 输出行高（0-6 步进 0.5，默认 1.0 = 紧凑；滑条控制）已随死代码外观块删除——
    // 行高/流光/Siri 发光全部统一由 AppearanceSheet 管理（与云端同一组件）
    // v2.0.102：切回设置页刷新计数（密码管理/记忆增删后行尾数字即时更新，原只有 .task 首刷）
    // v4.0.6：卡通宠物自定义页 + 大头像摘要所需的 key
    // （与 PetStudioSheet 共用同一组 @AppStorage，所以摘要改完立刻刷新，不需要额外通知）
    @State var showPetStudio = false
    // v4.0.22：设置页搜索（顶部搜索框 + 结果区；索引见 Core/SettingsSearchIndex.swift）
    @State var settingsQuery = ""
    @State var searchScrollTarget: String?   // 结果里「滚到分组看」的锚点（sec-account / sec-ai / sec-appearance）
    @AppStorage(PetKeys.style) var petStyle: PetStyle = .liquid
    @AppStorage(PetKeys.face) var petFace: PetFace = .calm
    @Environment(\.colorScheme) private var colorSchemeEnv   // v4.0.67：环境渐变页底深浅自适应
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "设置")
            // v4.0.22：设置项越堆越多，顶部给一行搜索框（索引与匹配见 Core/SettingsSearchIndex.swift）
            SettingsSearchBar(text: $settingsQuery)
            ScrollView {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        // v4.0.22：搜索结果插在最上面；下面各分组照旧全在 —— 点「滚到分组看」那条结果时
                        // 锚点一定在树上，不需要「先清查询、等一帧再滚」的时序把戏
                        if !settingsQuery.isEmpty {
                            SettingsSearchList(query: settingsQuery) { openSearchEntry($0) }
                        }
                        // v4.0.6：卡通宠物大头像（设置页顶部，点进去自定义）
                        AnyView(petStudioBanner)
                        AnyView(accountSection.id("sec-account"))
                        AnyView(connectionSection)
                        AnyView(aiSection.id("sec-ai"))
                        AnyView(dataSection)
                        AnyView(agentSection)
                        AnyView(appearanceSection.id("sec-appearance"))
                        AnyView(aboutSection)
                        AnyView(logoutButton)
                    }
                    .onChange(of: searchScrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation(Motion.snap) { proxy.scrollTo(target, anchor: .top) }
                        searchScrollTarget = nil
                    }
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.bottom, 100)
                    // v3.4.28：横屏限宽居中
                    .frame(maxWidth: .infinity)
                    .frame(maxWidth: AdaptiveLayout.contentMaxWidth(hSizeSettings))
                }
            }
            .scrollPosition($scrollPos)
        }
        .background(settingsCold1())
        .background(settingsCold2())
        .background(settingsCold3())
        .background(settingsCold4())
        .background(settingsCold5())
        .background(settingsCold6())
        .background(settingsCold7())
        .background(settingsCold8())
        .background(settingsCold9())
        // v4.0.67 P4：设置页页底铺环境渐变（C 口径，与聊天页同源单层）——
        //   列表卡已换 pastelCard 渐变卡，页底同步彩化；只铺一层不叠团。
        //   ⚠️ 必须挂**链尾**（= 垫在所有 cold 层之下）：本仓口径是「先挂的 background 画得更靠前」，
        //   聊天页/生活页也都是链尾（chatColdChrome13 / lifeCold2 之后）。cold 层今天全是 Color.clear，
        //   挂错位置今天看不出差别——将来哪个 cold 里塞进可见内容，光晕就会被整块盖死。
        .background(EnvironmentGlowLayers(scheme: colorSchemeEnv))
    }

    /// 深度治理：行为型深层修饰器下沉背景层（.background 不影响布局，语义等价）
    private func settingsCold1() -> some View {
        Color.clear
        .sheet(isPresented: $showPasswordSheet) {
            PasswordSheet()
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showAppearance) {
            // v3.0.4：外观弹窗（与云端共用同一组件，样式统一）
            AppearanceSheet()
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $showPetStudio) {
            // v4.0.6：卡通宠物自定义（形象 / 表情 / 行为动作 / 动画档；改完聊天页联动）
            PetStudioSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showHomeShortcuts) {
            // v3.9.82：桌面快捷方式选择（动态 shortcutItems，最多 4 项）
            HomeShortcutSheet()
                .presentationDetents([.medium, .large])
        }
    }

    /// 深度治理：行为型深层修饰器下沉背景层（.background 不影响布局，语义等价）
    private func settingsCold2() -> some View {
        Color.clear
        .sheet(isPresented: $showTasks) {
            TasksView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showLogs) {
            LogsView()
                .presentationDetents([.medium, .large])
        }
        // v4.0.61：弹窗关闭时清掉「搜索直达」标记。
        // ⚠️ `onDismiss` 是 `sheet(isPresented:onDismiss:content:)` 的**参数**，不是 View 修饰符 ——
        //    挂到内容视图上会报 `value of type 'some View' has no member 'onDismiss'`，
        //    本机 `-parse` 全绿、只有 Archive 抓得到（CI run #694 实踩）。
        .sheet(isPresented: $showConnSettings, onDismiss: { connOpenPinPath = false }) {
            ConnSettingsView(initiallyShowPinPath: connOpenPinPath)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showModelSheet) {
            ModelSheet(current: currentModel)
                .presentationDetents([.medium, .large])
        }
    }

    /// 深度治理：行为型深层修饰器下沉背景层（.background 不影响布局，语义等价）
    private func settingsCold3() -> some View {
        Color.clear
        .sheet(isPresented: $showWechatChannel) {
            WechatChannelSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSecrets) {
            SecretsView()
                .presentationDetents([.medium, .large])
        }
        // v2.0.81：知识库
        .sheet(isPresented: $showKB) {
            KBView()
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
        }
        // v2.0.87：AI 记忆
    }

    /// 深度治理：行为型深层修饰器下沉背景层（.background 不影响布局，语义等价）
    private func settingsCold4() -> some View {
        Color.clear
        .sheet(isPresented: $showMemory) {
            MemoryView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showHASettings) {
            HASettingsSheet()
                .presentationDetents([.medium])
        }
        // v3.5.0：MCP 工具服务管理
        .sheet(isPresented: $showMCPSettings) {
            MCPSettingsSheet()
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
        }
        // v4.0.x：邮件接入
        .sheet(isPresented: $showMailSettings) {
            MailSettingsSheet()
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
        }
        // v4.0.x：网盘接入
    }

    /// 深度治理：行为型深层修饰器下沉背景层（.background 不影响布局，语义等价）
    private func settingsCold5() -> some View {
        Color.clear
        .sheet(isPresented: $showCloudDrive) {
            CloudDriveSettingsSheet()
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
        }
        // v3.9.95：权限与 AI 操控
        .sheet(isPresented: $showAppPermissions) {
            AppPermissionsSheet()
                .presentationDetents([.large])
                .scrollContentBackground(.hidden)
        }
        // v3.5.x：生活卡片设置页（股票 / 资讯 / 快递）
        .sheet(isPresented: $showLifeCards) {
            LifeCardsSettingsView()
                .presentationDetents([.medium, .large])
        }
        // v3.9.32：定时提醒（纯本地 UNCalendarNotificationTrigger，无后端依赖）
        .sheet(isPresented: $showQuickReminder) {
            QuickReminderSheet()
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
        }
        // v3.9.32：文件管理（上传目录浏览：预览 / 分享 / 重命名 / 删除）
    }

    /// 深度治理：行为型深层修饰器下沉背景层（.background 不影响布局，语义等价）
    private func settingsCold6() -> some View {
        Color.clear
        .sheet(isPresented: $showFilesManager) {
            FilesManagerSheet()
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
        }
        // v4.0.11：主动 Agent（后端 proactive_agent 的唯一 UI 面）
        .sheet(isPresented: $showProactive) {
            ProactiveAgentSheet()
                // v4.0.x：原为 [.large]（锁死全屏），与全站半屏弹窗不一致 → 统一为 [.medium, .large]
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
        }
        // v2.0.105：Agent 关键词管理
        .sheet(isPresented: $showAgentKeywords) {
            AgentKeywordsSheet()
                .scrollContentBackground(.hidden)
        }
        // v2.0.113：Agent 记忆弹窗（同 AI 记忆样式）
        .sheet(isPresented: $showAgentMemory) {
            AgentMemorySheet()
                .scrollContentBackground(.hidden)
        }
        // v3.0.20：Agent 模型选择弹窗
    }

    /// 深度治理：行为型深层修饰器下沉背景层（.background 不影响布局，语义等价）
    private func settingsCold7() -> some View {
        Color.clear
        .sheet(isPresented: $showAgentModelSheet) {
            AgentModelSheet()
                .presentationDetents([.medium, .large])
        }
        // v2.0.116：执行历史弹窗（v3.9.35：补 presentationDetents——漏挂导致默认全屏，
        // 与全站弹窗「默认半屏 medium、可上拉 large」不一致）
        .sheet(isPresented: $showHistory) {
            HistorySheet()
                .presentationDetents([.medium, .large])
        }
        // v3.6.0：原「崩溃日志」行整合为「诊断」页（App 自身诊断：版本/设备/网络/后端连通性/
        // 崩溃与卡顿记录/一键复制导出/手动上报），崩溃日志查看导出在该页内，入口不再重复。
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
                .presentationDetents([.medium, .large])
        }
        // v2.0.118：本地模型管理弹窗
        .sheet(isPresented: $showLocalModels) {
            LocalModelsSheet()
                .scrollContentBackground(.hidden)
        }
        // v3.9.26：能力示例（5 种卡片形态展示，零后端、纯 App 内样例数据）
        // v3.9.27：补 .scrollContentBackground(.hidden)——ScrollView 自带底会盖住系统玻璃弹窗底
        //（与 v3.9.23「清遮挡层、不覆盖材质」定稿同规则，用户报的「能力示例弹窗圆角背景不对」即此）
    }

    /// 深度治理：行为型深层修饰器下沉背景层（.background 不影响布局，语义等价）
    private func settingsCold8() -> some View {
        Color.clear
        .sheet(isPresented: $showCardGallery) {
            CardGallerySheet()
                .presentationDetents([.medium, .large])
                .scrollContentBackground(.hidden)
        }
        // v2.0.102：切回设置页刷新计数（密码管理/记忆增删后行尾数字即时更新，原只有 .task 首刷）
        .onAppear { Task { await loadCounts() } }
        .task {
            await loadCounts()
            await loadLocalStatus()   // v-review fix：进入设置页即以后端 /api/local/status 校准本地模型开关
            await loadTypesafeRouting()   // v3.9.56：进设置页即读后端真实路由开关/熔断状态
        }
    }

    /// v4.0.82：Dock 栏设置（顺序 / 隐藏）的弹出宿主。
    /// ⚠️ 为什么不并进 settingsCold5：那组顶层已有 4 条深层修饰器，而本仓口径是**每组 ≤4**
    ///    （类型栈深度真值表 ③⁗ 钉死：多一条就把宿主类型深度推回爆栈危险区），故单开一组。
    private func settingsCold9() -> some View {
        Color.clear
        .sheet(isPresented: $showDockLayout) {
            DockLayoutSheet()
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - v4.0.22 设置页搜索

    /// 搜索结果点开：弹窗类直接开对应弹窗，开关类滚到所属分组（清空查询后各分组就在下面）。
    /// 这些 route 字面量与 Core/SettingsSearchIndex.swift 的 entries 一一对应 ——
    /// 真值表反向核验「索引里每条 route 都在这里被处理」，漏一条就是「搜到了、点下去没反应」。
    private func openSearchEntry(_ entry: SettingsSearchEntry) {
        settingsQuery = ""
        switch entry.route {
        case "password": showPasswordSheet = true
        case "conn":
            connOpenPinPath = false
            showConnSettings = true
        case "model": showModelSheet = true
        case "wechatChannel": showWechatChannel = true
        case "ha": showHASettings = true
        case "mcp": showMCPSettings = true
        case "mail": showMailSettings = true
        case "cloudDrive": showCloudDrive = true
        case "appPermissions": showAppPermissions = true
        case "localModels": showLocalModels = true
        case "kb": showKB = true
        case "memory": showMemory = true
        case "cardGallery": showCardGallery = true
        case "secrets": showSecrets = true
        case "tasks": showTasks = true
        case "history": showHistory = true
        case "logs": showLogs = true
        case "diagnostics": showDiagnostics = true
        case "pinPath":
            // v4.0.61：钉一钉存储已搬进「连接设置」→ 打开该页并直达它的 sheet
            connOpenPinPath = true
            showConnSettings = true
        case "lifeCards": showLifeCards = true
        case "quickReminder": showQuickReminder = true
        case "filesManager": showFilesManager = true
        case "proactive": showProactive = true
        case "agentModel": showAgentModelSheet = true
        case "agentHelp":
            // 使用说明是**行内展开**（不是弹窗）：点结果就把那一段展开，并滚到它所在的分组
            showAgentHelp = true
            searchScrollTarget = "sec-ai"
        case "agentKeywords": showAgentKeywords = true
        case "agentMemory": showAgentMemory = true
        case "appearance": showAppearance = true
        case "pet": showPetStudio = true
        case "homeShortcuts": showHomeShortcuts = true
        case "about": showAbout = true
        case "sec:account": searchScrollTarget = "sec-account"
        case "sec:ai": searchScrollTarget = "sec-ai"
        case "sec:appearance": searchScrollTarget = "sec-appearance"
        default: break
        }
    }
}

// MARK: ===== 以下原为 Features/Settings/SettingsViewSections.swift =====

// MARK: - Section 计算属性（body 瘦身：500 行 → 8 个独立段，SwiftUI diff 只遍历变化段）

extension SettingsView {

    @ViewBuilder var accountSection: some View {
        SectionHeader("账号与安全")
        VStack(spacing: 0) {
            SettingRow(icon: "person.crop.circle.fill", iconColor: .blue, title: auth.username, value: "已登录")
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "key.horizontal.fill", iconColor: .gray, title: "修改密码", chevron: true)
                .tapButton { showPasswordSheet = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            toggleRow(icon: "faceid", iconColor: .blue, title: "Face ID 登录", isOn: $faceIDLogin)
                .onChange(of: faceIDLogin) { _, on in
                    if on { requestFaceIDAuth() } else { FaceIDStore.clear() }
                }
                .alert("Face ID 未授权", isPresented: $faceIDAuthFailed) {
                    Button("好的", role: .cancel) {}
                } message: {
                    Text("未通过系统 Face ID 验证，登录页快捷登录不可用。")
                }
            Divider().padding(.leading, Spacing.rowDividerInset)
            toggleRow(icon: "lock.fill", iconColor: .green, title: "App 锁", isOn: $appLockOn)
                .onChange(of: appLockOn) { _, on in
                    if on { requestAppLockAuth() }
                }
                .alert("Face ID 未授权", isPresented: $appLockAuthFailed) {
                    Button("好的", role: .cancel) {}
                } message: {
                    Text("未通过系统 Face ID 验证，App 锁不可用。")
                }
        }
        .pastelCard()
    }

    @ViewBuilder var connectionSection: some View {
        SectionHeader("连接与模型")
        VStack(spacing: 0) {
            SettingRow(icon: "globe.asia.australia.fill", iconColor: .green, title: "连接设置", chevron: true)
                .tapButton { showConnSettings = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            // v4.0.15：后端一键更新（落后自动挂橙点提示；详见 BackendUpdate.swift）
            BackendUpdateRow()
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "cpu.fill", iconColor: .orange, title: "模型管理", value: currentModel, chevron: true)
                .tapButton { showModelSheet = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "bubble.left.and.bubble.right.fill", iconColor: .blue,
                       title: "微信通道模型", value: wechatChannelModel, chevron: true)
                .tapButton { showWechatChannel = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "house.fill", iconColor: .purple, title: "HA 设置", chevron: true)
                .tapButton { showHASettings = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            // v3.5.0：MCP 工具服务（App 配 key → Hermes 原生 MCP 工具）
            SettingRow(icon: "puzzlepiece.extension.fill", iconColor: .teal, title: "MCP 工具服务", chevron: true)
                .tapButton { showMCPSettings = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            // v4.0.x：邮件接入（配一次邮箱，AI 就能收发邮件）
            SettingRow(icon: "envelope.fill", iconColor: .blue, title: "邮件接入", chevron: true)
                .tapButton { showMailSettings = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            // v4.0.x：网盘接入（位置按用户要求放设置，不塞连接器面板）
            SettingRow(icon: "externaldrive.fill", iconColor: .teal, title: "网盘接入", chevron: true)
                .tapButton { showCloudDrive = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            // v3.9.95：权限与 AI 操控（授权状态 + 逐项「允许 AI 操作」开关 + 能力边界）
            SettingRow(icon: "lock.shield.fill", iconColor: .indigo, title: "权限与 AI 操控", chevron: true)
                .tapButton { showAppPermissions = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            localModelToggle
        }
        .pastelCard()
    }

    @ViewBuilder var localModelToggle: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: Typography.subhead, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.indigo, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("本地模型").font(.system(size: Typography.body, weight: .medium))
                Text(localStatusText).font(.system(size: Typography.caption)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: $localModelOn).qingliaoSwitch()
                .onChange(of: localModelOn) { _, new in
                    guard !localModelSyncing else { return }
                    Task {
                        do {
                            _ = try await auth.json("/api/local/toggle", method: "POST", body: ["on": new])
                            await loadLocalStatus()
                        } catch {
                            // v-review fix：切换失败回滚开关（防「开关 ON 但后端未启动/超时」脱钩）
                            if localModelOn == new {
                                localModelSyncing = true
                                localModelOn = !new
                                localModelSyncing = false
                                localStatusText = "切换失败，请检查连接后重试"
                            }
                        }
                    }
                }
        }
        .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.sm)
        if localModelOn {
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "shippingbox.fill", iconColor: .indigo, title: "管理模型",
                       value: "已装列表 / 拉取新模型", chevron: true)
                .tapButton { showLocalModels = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            Button { Task { await checkLocalUpdate() } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: Typography.subhead, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.teal, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("检查模型更新").font(.system(size: Typography.body, weight: .medium))
                        Text(localUpdateText).font(.system(size: Typography.caption)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if localChecking { ProgressView().controlSize(.small) }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.sm)
        }
    }

    @ViewBuilder var aiSection: some View {
        SectionHeader("AI 智能")
        VStack(spacing: 0) {
            SettingRow(icon: "books.vertical.fill", iconColor: .green, title: "知识库", value: "文档检索问答", chevron: true)
                .tapButton { showKB = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "brain.head.profile", iconColor: .pink, title: "AI 记忆", value: "\(memoryCount) 条", chevron: true)
                .tapButton { showMemory = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            // v3.9.26：能力示例（卡片画廊）——让「AI 能出什么卡」可见，不用靠碰运气触发
            SettingRow(icon: "rectangle.grid.2x2.fill", iconColor: .indigo, title: "能力示例", value: "5 种卡片形态", chevron: true)
                .tapButton { showCardGallery = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            // v3.0.81：上下文自动管理
            toggleRow(icon: "arrow.down.circle.fill", iconColor: .purple,
                      title: "上下文自动压缩", subtitle: "token超限时AI摘要压缩历史消息", isOn: $contextAutoCompress)
                .onChange(of: contextAutoCompress) { _, new in
                    UserDefaults.standard.set(new, forKey: "qingliao_context_auto_compress")
                }
            if contextAutoCompress {
                Divider().padding(.leading, Spacing.rowDividerInset)
                HStack {
                    Text("压缩阈值")
                        .font(.system(size: Typography.body))
                    Spacer()
                    Text("\(contextThreshold) tokens")
                        .font(.system(size: Typography.body))
                        .foregroundStyle(.secondary)
                    Stepper("", value: $contextThreshold, in: 1000...16000, step: 500)
                        .labelsHidden()
                }
                .padding(.horizontal, Spacing.section)
                .padding(.vertical, Spacing.lg)
                .onChange(of: contextThreshold) { _, new in
                    UserDefaults.standard.set(new, forKey: "qingliao_context_threshold")
                }
            }
            Divider().padding(.leading, Spacing.rowDividerInset)
            // v3.9.56：智能路由（TypeSafe 判定开关）——用户 2026-09-21 拍板「开关 + 就地展开」方案。
            // 后端为真源：开关/模式/阈值改动当场写后端（免重启即时生效），本地不存一份。
            toggleRow(icon: "arrow.triangle.branch", iconColor: .purple,
                      title: "智能路由", subtitle: tsRouting.subtitleText, isOn: tsEnabledBinding)
            if tsRouting.enabled {
                tsRoutingParams
            }
            Divider().padding(.leading, Spacing.rowDividerInset)
            toggleRow(icon: "message.badge.filled.fill", iconColor: .green,
                      title: "微信推送", subtitle: "自动化执行结果推送到微信", isOn: $pushWeixin)
                .onChange(of: pushWeixin) { _, new in
                    Task { _ = try? await auth.json("/api/push/settings", method: "POST", body: ["pushWeixin": new]) }
                }
        }
        .pastelCard()
    }

    /// v3.9.56：智能路由「就地展开」参数区。
    /// 沿用「上下文自动压缩 → 压缩阈值」的既有展开形态（Divider + 行），不新增 sheet / 文件。
    @ViewBuilder var tsRoutingParams: some View {
        Divider().padding(.leading, Spacing.rowDividerInset)

        // 判定模式：两枚胶囊。没有「关闭」档 —— 关掉上面那个开关就是不判定
        HStack(spacing: Spacing.md) {
            Text("判定模式").font(.system(size: Typography.body))
            Spacer(minLength: Spacing.md)
            tsCapsule("智能分流", on: tsRouting.mode == "smart") {
                Task { await saveTypesafeRouting(["mode": "smart"]) }
            }
            tsCapsule("强制 Agent", on: tsRouting.mode == "force_agent") {
                Task { await saveTypesafeRouting(["mode": "force_agent"]) }
            }
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.lg)

        // 后端被 CLI 设成 mode=off 时如实说明（App 里设不出这一档，但读得到）
        if tsRouting.mode == "off" {
            tsParamNote(TypesafeRouting.modeOffHint, warn: true)
        }

        Divider().padding(.leading, Spacing.rowDividerInset)

        // 判定阈值：概率 ≥ 该值 → 判「要干活」。后端允许 0~1，UI 收窄到有意义的区间
        HStack(spacing: Spacing.md) {
            Text("判定阈值").font(.system(size: Typography.body))
            Spacer(minLength: Spacing.md)
            Text(tsRouting.thresholdText)
                .font(.system(size: Typography.body))
                .foregroundStyle(.secondary)
            Stepper("", value: tsThresholdBinding, in: 0.30...0.95, step: 0.05).labelsHidden()
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.lg)

        Divider().padding(.leading, Spacing.rowDividerInset)

        // 判定超时：超时即回退关键词规则（不让用户等判定）
        HStack(spacing: Spacing.md) {
            Text("判定超时").font(.system(size: Typography.body))
            Spacer(minLength: Spacing.md)
            Text(tsRouting.timeoutText)
                .font(.system(size: Typography.body))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.lg)

        Divider().padding(.leading, Spacing.rowDividerInset)

        // 熔断状态：key 失效/上游挂掉连续失败 → 判定自动停 X 秒，期间零上游调用（不再白等）
        HStack(spacing: Spacing.sm) {
            Circle()
                .fill(tsBreaker.open ? Color.red : Color.secondary.opacity(Tint.soft))
                .frame(width: 6, height: 6)
            Text(tsBreaker.statusText(tsRouting))
                .font(.system(size: Typography.caption))
                .foregroundStyle(tsBreaker.open ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.lg)
        // 熔断期间每 5 秒跟一次后端：倒计时会走，后端半开重试成功后状态自己翻回来
        .task(id: tsBreaker.open) {
            guard tsBreaker.open else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await loadTypesafeRouting()
                if !tsBreaker.open { break }
            }
        }

        HStack(spacing: Spacing.md) {
            tsCapsule("立即复位熔断", on: false) {
                Task { await saveTypesafeRouting(["reset_breaker": true]) }
            }
            if tsBusy { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.section)
        .padding(.bottom, Spacing.lg)

        if !tsError.isEmpty {
            tsParamNote(tsError, warn: true)
        }
        tsParamNote(TypesafeRouting.footerText, warn: false)
    }

    /// v3.9.56：参数区小字说明（warn = 红字，否则 tertiary 灰字）
    @ViewBuilder func tsParamNote(_ text: String, warn: Bool) -> some View {
        HStack {
            Text(text)
                .font(.system(size: Typography.caption))
                .foregroundStyle(warn ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.section)
        .padding(.bottom, Spacing.lg)
    }

    @ViewBuilder var dataSection: some View {
        SectionHeader("数据与自动化")
        VStack(spacing: 0) {
            SettingRow(icon: "key.fill", iconColor: .teal, title: "密码管理", value: "\(secretCount) 条凭据", chevron: true)
                .tapButton { showSecrets = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "clock.badge.fill", iconColor: .red, title: "定时任务", chevron: true)
                .tapButton { showTasks = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "clock.arrow.circlepath", iconColor: .orange, title: "执行历史",
                       value: "自动化/场景执行记录", chevron: true)
                .tapButton { showHistory = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "doc.text.fill", iconColor: .orange, title: "日志", chevron: true)
                .tapButton { showLogs = true }
            // v3.6.0：崩溃日志入口整合为「诊断」页（App 自身诊断 + 崩溃/卡顿自上报）
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "stethoscope", iconColor: .red, title: "诊断",
                       value: CrashReporter.hasPendingLog() ? "有待查看" : "设备/网络/崩溃记录",
                       chevron: true)
                .tapButton { showDiagnostics = true }
            // v3.5.x：生活卡片设置（股票 / 资讯 / 快递）
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "rectangle.grid.2x2", iconColor: .green, title: "生活卡片",
                       value: "股票 / 资讯 / 快递", chevron: true)
                .tapButton { showLifeCards = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            // v3.9.32：一句话本地定时提醒（与上面「定时任务」不同：纯本地系统通知，App 不在也响）
            SettingRow(icon: "bell.badge.fill", iconColor: .pink, title: "定时提醒",
                       value: "一句话定时间", chevron: true)
                .tapButton { showQuickReminder = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            // v3.9.32：文件管理（上传目录浏览：预览 / 分享 / 重命名 / 删除）
            SettingRow(icon: "folder.fill", iconColor: .indigo, title: "文件管理",
                       value: "上传目录里的文件", chevron: true)
                .tapButton { showFilesManager = true }
        }
        .pastelCard()
    }

    @ViewBuilder var agentSection: some View {
        // v3.4.12：移除「Agent 智能回复」开关——后端主链路（STREAM_HERMES_SESSION=1）v3.4.8 起
        // 所有聊天恒走 Hermes agent 工具循环，开关已无实权（只影响日志/回退路径），移除 UI 防误导；
        // Agent 模型/关键词/记忆入口保留（模型仍影响 resolveModel 选型，关键词/记忆管理后端端点仍活）。
        SectionHeader("Agent 设置")
        VStack(spacing: 0) {
            // v4.0.11：主动 Agent 入口（放最前——这是「AI 会自己开口」的总闸，用户第一眼要看它）
            SettingRow(icon: "bolt.horizontal.circle.fill", iconColor: .orange, title: "主动 Agent",
                       value: "AI 主动开口 · 预算/静默/复盘", chevron: true)
                .tapButton { showProactive = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            // v3.0.20：Agent 模型自定义（可单独指定 Agent 使用的模型，不依赖主模型）
            SettingRow(icon: "cpu.fill", iconColor: .indigo, title: "Agent 模型",
                       value: agentModel.isEmpty ? "跟随主模型" : agentModel, chevron: true)
                .tapButton { showAgentModelSheet = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "questionmark.circle.fill", iconColor: .gray, title: "使用说明", chevron: false)
                .tapButton { withAnimation(Motion.snap) { showAgentHelp.toggle() } }
            if showAgentHelp {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent 回复恒走 Hermes 智能体：查磁盘/内存、控制设备等自动调用工具")
                    Text("▸ 直接问：查磁盘/内存/温度、控制设备、执行场景，自动调用工具回复")
                    Text("▸ 记忆规则：说「以后XX都用agent」，下次同类问题直接 Agent 处理")
                    Text("▸ 复杂任务（联网搜索/写脚本/操作文件）自动转交 Hermes 执行")
                    Text("▸ 普通聊天走 Hermes（带 AI 记忆）；Agent 只参考轻聊记忆与规则")
                }
                .font(.system(size: Typography.subhead)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.xxl).padding(.bottom, Spacing.xl)
            }
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "text.badge.plus", iconColor: .orange, title: "Agent 关键词", value: "分流匹配词管理", chevron: true)
                .tapButton { showAgentKeywords = true }
            Divider().padding(.leading, Spacing.rowDividerInset)
            SettingRow(icon: "brain.head.profile", iconColor: .purple, title: "Agent 记忆",
                       value: agentRuleCount > 0 ? "\(agentRuleCount) 条规则" : "暂无", chevron: true)
                .tapButton { showAgentMemory = true }
        }
        .pastelCard()
    }

    /// v4.0.82：Dock 栏那行的行尾摘要 —— 读同一对 UserDefaults 键（@AppStorage 跨视图同键自动同步，
    /// 在 DockLayoutSheet 里改完回到这一行立即刷新）。中文页面名在视图层取（DockTab.title）。
    private var dockLayoutSummary: String {
        let orderRaw = UserDefaults.standard.string(forKey: UserDefaultsKey.dockOrder) ?? DockLayoutKit.defaultOrderRaw
        let hiddenRaw = UserDefaults.standard.string(forKey: UserDefaultsKey.dockHidden) ?? ""
        let visible = DockLayoutKit.visibleRaw(orderRaw: orderRaw, hiddenRaw: hiddenRaw)
            .compactMap { DockTab(rawValue: $0)?.title }
        let hiddenNames = DockLayoutKit.sanitizedHidden(hiddenRaw).compactMap { DockTab(rawValue: $0)?.title }
        return hiddenNames.isEmpty
            ? "\(visible.count) 档 · \(visible.joined(separator: "/"))"
            : "\(visible.count) 档 · 隐藏 \(hiddenNames.joined(separator: "/"))"
    }

    @ViewBuilder var appearanceSection: some View {
        SectionHeader("外观与显示")
        VStack(spacing: 0) {
            SettingRow(icon: "circle.lefthalf.filled", iconColor: .purple, title: "外观", value: appearanceName, chevron: true)
                .tapButton { withAnimation(Motion.snap) { showAppearance = true } }
            // v4.0.6：宠物配置行（顶部大头像是主入口，这里是滚动后的兜底入口，同一个 sheet）
            SettingRow(icon: "face.smiling.inverse", iconColor: .pink, title: "AI形象",
                       value: petSummary, chevron: true)
                .tapButton { showPetStudio = true }
            // v4.0.9：点击震动总开关。闸门在 Core/Haptics.swift 的 4+5 个语义入口统一 early-return，
            // 覆盖全站 144 处 Haptics.* 调用点；这里只是那个开关的唯一 UI 入口。
            // 默认开（key 缺失 = 开）→ 老用户行为不变。
            SettingRow(icon: "iphone.radiowaves.left.and.right", iconColor: .teal, title: "震动反馈",
                       toggle: $hapticsOn)
            // v4.0.10（用户要求）：首页快捷卡片**总开关**。关掉 = 聊天页首页那一整块网格
            // （含「自定义」入口）都不渲染；卡片的逐张开关与排序**原样留着**，再打开照旧。
            // 关掉后想加回来就走这里（首页没有入口可点了，所以这一行必须恒在）。
            SettingRow(icon: "rectangle.grid.2x2.fill", iconColor: .blue, title: "首页快捷卡片",
                       toggle: $homeCardsOn)
            // v4.0.69（用户 2026-10-07）：「聊天页宠物」开关已搬去 **AI形象** 页（PetStudioSheet）——
            // 用户口径「设置里聊天页宠物开关移动到 AI 形象里」。这里只留路标，不要再挂 SettingRow。
            // v3.9.82：桌面图标长按快捷方式（长按桌面「轻聊」图标即可看到选中的几项）。
            // 行尾计数读 @AppStorage 原始串（HomeShortcutStore.ids(from:)）→ 弹窗里改完立即刷新。
            SettingRow(icon: "square.grid.2x2.fill", iconColor: .indigo, title: "桌面快捷方式",
                       value: "已选 \(HomeShortcutStore.ids(from: homeShortcutsRaw).count)/\(HomeShortcut.maxCount)",
                       chevron: true)
                .tapButton { showHomeShortcuts = true }
            // v4.0.82（用户 2026-10-09）：「设置里面增加 dock 栏设置，聊天、生活、看板、设置页可以调整顺序，
            // 可以隐藏某一页，唯独设置页不能隐藏」。行尾摘要 = 当前档数 + 隐藏项（改完立即刷新）。
            // 真源：Core/DockLayoutKit.swift（顺序串 / 隐藏串），本行只做入口。
            SettingRow(icon: "dock.rectangle", iconColor: .blue, title: "Dock 栏",
                       value: dockLayoutSummary, chevron: true)
                .tapButton { showDockLayout = true }
            // v3.x review fix：showAppearanceOptions 死代码块（深浅色 chips/输入框流光/Siri 发光滑条/
            // AI 输出行高）永不显示（唯一写点恒置 false）——已删除，统一由 AppearanceSheet 管理
        }
        .pastelCard()
    }

    // v4.0.6：卡通宠物大头像入口（设置页顶部居中）。
    //
    // 为什么放最顶：宠物是 App 的表情门面，入口要显眼；同时「聊天页形象」段已从外观页搬进
    // 那一层（用户 v4.0.6 拍板），所以这里就是**唯一**的宠物配置入口。
    //
    // ⚠️ 尺寸口径：直接 `PetAvatar(size: 96)` 画，**不要**再套 `.frame` 去"缩"（v3.9.78 真机报修：
    // frame 只改布局槽位、不缩放画面，96pt 画布会溢出 52pt 槽位压住边框和文字）。真要小就传小 size。
    @ViewBuilder var petStudioBanner: some View {
        // v4.0.11：只留卡通头像本体 + 头像下方一行名称（petSummary），角标/提示文字撤掉
        Button {
            showPetStudio = true
        } label: {
            VStack(spacing: Spacing.xs) {
                PetAvatar(size: 96, state: .idle, keepDetail: true)
                Text(petStyle.name)
                    .font(.system(size: Typography.subhead, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            // v4.0.68（用户 2026-10-07 拍板「卡底统一成品牌淡色系」）：形象卡原本是「纯白 0.6」，
            // 是设置页最后一块白 —— 换品牌淡彩卡（与下面分组卡同族）。
            .pastelCard(cornerRadius: Radius.card)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("卡通宠物：\(petSummary)")
        .accessibilityHint("轻点进入自定义")
        .padding(.bottom, Spacing.sm)
    }

    /// 行尾/角标摘要：形象 + 表情 + 动作数（一行说完，别让人点进去才发现是空的）
    private var petSummary: String {
        let on = PetKeys.enabledQuirks().count
        return "\(petStyle.name) · \(petFace.name)脸 · 动作 \(on)/\(Quirk.pool.count)"
    }

    @ViewBuilder var aboutSection: some View {
        SectionHeader("关于")
        VStack(spacing: 0) {
            SettingRow(icon: "info.circle.fill", iconColor: .gray, title: "关于 Qimo（轻聊）", chevron: true)
                .tapButton { showAbout = true }
        }
        .pastelCard()
    }

    @ViewBuilder var logoutButton: some View {
        SectionHeader("")
        Button {
            confirmLogout = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: Typography.body, weight: .semibold))
                Text("退出登录")
                    .font(.system(size: Typography.body, weight: .semibold))
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 40).padding(.vertical, Spacing.xl)
            .background(Color.red.opacity(0.35), in: Capsule())
        }
        .buttonStyle(.plain)
        .confirmationDialog("退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { auth.logout() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后回到登录页，可切换本地 AI / 云端 AI 模式。云端配置（API Key）仍保留在手机本地。")
        }
        .padding(.top, Spacing.xxs)
    }
}

// MARK: ===== 以下原为 Features/Settings/SettingsViewHelpers.swift =====

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
            Toggle("", isOn: isOn).qingliaoSwitch()
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
