import SwiftUI
import LocalAuthentication

// MARK: - 设置页（iOS 设置风格分组列表，全部功能行可用）

struct SettingsView: View {
    @Environment(AuthStore.self) var auth
    @AppStorage("qingliao_appearance") var appearance = "system"   // dark/light/system（默认跟随系统）

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
    // v3.0.74：钉一钉存储路径
    @State var showPinPath = false
    @State var pinPathEdit = ""
    var pinPathDisplay: String {
        let p = PinStore.shared.storagePath
        return p.isEmpty ? "默认路径" : (p.count > 20 ? "..." + p.suffix(17) : p)
    }
    @State var showAppearanceOptions = false
    @State var showAppearance = false   // v3.0.4：外观弹窗（与云端统一）
    @State var scrollPos = ScrollPosition()
    @State var showModelSheet = false
    @State var showWechatChannel = false   // v3.0.19：微信窗通道模型设置
    @State var showAbout = false
    @State var confirmLogout = false   // v3.0.5 review fix：退出登录二次确认（与云端一致）
    @State var secretCount = 0
    @State var showHASettings = false
    @State var haAddress = ""
    // v3.0.17：聊天字体大小从一级菜单移除（外观二级菜单持有），fontSize 声明一并清理
    // v3.0.9：外观下天气城市已移除（天气城市设定在看板 WeatherBadge 点按处），相关状态一并清理
    // v2.0.101：Agent 使用说明内联展开
    @State var showAgentHelp = false
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
    // v2.0.117：本地模型（Ollama 断网兜底）
    @AppStorage("qingliao_local_model") var localModelOn = false
    @State var localStatusText = "未开启"
    @State var localUpdateText = "断网兜底用本地模型"
    @State var localChecking = false
    // v2.0.118：本地模型管理弹窗
    @State var showLocalModels = false
    // v3.0.10：视觉模型配置弹窗（已移至模型管理弹窗内）
    // v2.0.113：微信推送开关（同步后端 push_settings.json）
    @AppStorage("qingliao_push_weixin") var pushWeixin = true
    // v3.0.81：上下文管理
    @AppStorage("qingliao_context_auto_compress") var contextAutoCompress = false
    @AppStorage("qingliao_context_threshold") var contextThreshold = 4000
    // v2.0.87ax：输入框流光光效开关
    @AppStorage("qingliao_input_glow") var glowOn = true
    // v2.0.87bb：Siri 边框发光开关
    @AppStorage("qingliao_siri_glow") var siriGlowOn = true
    // v2.0.90a：Siri 动效自定义参数（默认 = v2.0.87bn 定稿效果）
    @AppStorage("qingliao_siri_glow_brightness") var glowBrightness = 1.0
    @AppStorage("qingliao_siri_glow_freq") var glowFreq = 2.2
    @AppStorage("qingliao_siri_glow_amp") var glowAmp = 0.18
    @AppStorage("qingliao_siri_glow_width") var glowWidth = 22.0
    // v2.0.88：Face ID 登录开关（关闭后删除 Keychain 凭据，登录页不再显示快捷按钮）
    @AppStorage("qingliao_faceid_login") var faceIDLogin = true
    @State var faceIDAuthFailed = false   // v2.0.89f：开关打开时系统授权失败提示
    // v2.0.92：App 锁开关（启动时 Face ID 验证）
    @AppStorage("qingliao_app_lock") var appLockOn = false
    @State var appLockAuthFailed = false
    // v2.0.128：AI 输出行高（0-6 步进 0.5，默认 1.0 = 紧凑；滑条控制）
    @AppStorage("qingliao_ai_line_spacing") var aiLineSpacing = 1.0
    @State var showLineSpacingOptions = false
    // v2.0.129：Siri 圆球输入（默认开——输入框区显示多彩圆球，单击展开 / 长按语音转文字）
    @AppStorage("qingliao_ball_input") var ballInput = true
    // v2.0.98：Agent 智能回复开关（关闭后请求不带 agent 能力，走普通 LLM 回复）
    @AppStorage(UserDefaultsKey.agentEnabled) var agentOn = true

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "设置")
            ScrollView {
                VStack(spacing: 0) {
                    accountSection
                    connectionSection
                    aiSection
                    dataSection
                    agentSection
                    appearanceSection
                    aboutSection
                    logoutButton
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 100)
            }
            .scrollPosition($scrollPos)
        }
        .sheet(isPresented: $showPasswordSheet) {
            PasswordSheet()
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showAppearance) {
            // v3.0.4：外观弹窗（与云端共用同一组件，样式统一）
            AppearanceSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showTasks) {
            TasksView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showLogs) {
            LogsView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showConnSettings) {
            ConnSettingsView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showModelSheet) {
            ModelSheet(current: currentModel)
                .presentationDetents([.medium, .large])
        }
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
        }
        // v2.0.87：AI 记忆
        .sheet(isPresented: $showMemory) {
            MemoryView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showHASettings) {
            HASettingsSheet()
                .presentationDetents([.medium])
        }
        // v2.0.105：Agent 关键词管理
        .sheet(isPresented: $showAgentKeywords) {
            AgentKeywordsSheet()
        }
        // v2.0.113：Agent 记忆弹窗（同 AI 记忆样式）
        .sheet(isPresented: $showAgentMemory) {
            AgentMemorySheet()
        }
        // v3.0.20：Agent 模型选择弹窗
        .sheet(isPresented: $showAgentModelSheet) {
            AgentModelSheet()
                .presentationDetents([.medium, .large])
        }
        // v2.0.116：执行历史弹窗
        .sheet(isPresented: $showHistory) {
            HistorySheet()
        }
        // v2.0.118：本地模型管理弹窗
        .sheet(isPresented: $showLocalModels) {
            LocalModelsSheet()
        }
        // v2.0.102：切回设置页刷新计数（密码管理/记忆增删后行尾数字即时更新，原只有 .task 首刷）
        .onAppear { Task { await loadCounts() } }
        .task { await loadCounts() }
    }
}
