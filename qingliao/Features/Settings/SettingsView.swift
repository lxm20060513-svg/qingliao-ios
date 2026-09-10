import SwiftUI
import LocalAuthentication

// MARK: - 设置页（iOS 设置风格分组列表，全部功能行可用）

struct SettingsView: View {
    @Environment(AuthStore.self) var auth
    // v3.4.28：横屏限宽
    @Environment(\.horizontalSizeClass) private var hSizeSettings
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
    var pinPathDisplay: String {
        let p = PinStore.shared.storagePath
        return p.isEmpty ? "默认路径" : (p.count > 20 ? "..." + p.suffix(17) : p)
    }
    @State var showAppearance = false   // v3.0.4：外观弹窗（与云端统一）
    @State var scrollPos = ScrollPosition()
    @State var showModelSheet = false
    @State var showWechatChannel = false   // v3.0.19：微信窗通道模型设置
    @State var showAbout = false
    @State var confirmLogout = false   // v3.0.5 review fix：退出登录二次确认（与云端一致）
    @State var secretCount = 0
    @State var showHASettings = false
    // v3.5.0：MCP 工具服务管理弹窗
    @State var showMCPSettings = false
    // v3.5.x：生活卡片设置（股票 / 资讯 / 快递 / 价格监控）
    @State var showLifeCards = false
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
    // v3.0.10：视觉模型配置弹窗（已移至模型管理弹窗内）
    // v2.0.113：微信推送开关（同步后端 push_settings.json）
    @AppStorage("qingliao_push_weixin") var pushWeixin = true
    // v3.0.81：上下文管理
    @AppStorage("qingliao_context_auto_compress") var contextAutoCompress = false
    @AppStorage("qingliao_context_threshold") var contextThreshold = 4000
    // v2.0.88：Face ID 登录开关（关闭后删除 Keychain 凭据，登录页不再显示快捷按钮）
    @AppStorage("qingliao_faceid_login") var faceIDLogin = true
    @State var faceIDAuthFailed = false   // v2.0.89f：开关打开时系统授权失败提示
    // v2.0.92：App 锁开关（启动时 Face ID 验证）
    @AppStorage("qingliao_app_lock") var appLockOn = false
    @State var appLockAuthFailed = false
    // v2.0.128：AI 输出行高（0-6 步进 0.5，默认 1.0 = 紧凑；滑条控制）已随死代码外观块删除——
    // 行高/流光/Siri 发光/智能球全部统一由 AppearanceSheet 管理（与云端同一组件）
    // v2.0.102：切回设置页刷新计数（密码管理/记忆增删后行尾数字即时更新，原只有 .task 首刷）
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
                // v3.4.28：横屏限宽居中
                .frame(maxWidth: .infinity)
                .frame(maxWidth: AdaptiveLayout.contentMaxWidth(hSizeSettings))
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
        // v3.5.0：MCP 工具服务管理
        .sheet(isPresented: $showMCPSettings) {
            MCPSettingsSheet()
                .presentationDetents([.medium, .large])
        }
        // v3.5.x：生活卡片设置页（股票 / 资讯 / 快递 / 价格监控）
        .sheet(isPresented: $showLifeCards) {
            LifeCardsSettingsView()
                .presentationDetents([.medium, .large])
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
        // v3.6.0：原「崩溃日志」行整合为「诊断」页（App 自身诊断：版本/设备/网络/后端连通性/
        // 崩溃与卡顿记录/一键复制导出/手动上报），崩溃日志查看导出在该页内，入口不再重复。
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
                .presentationDetents([.medium, .large])
        }
        // v2.0.118：本地模型管理弹窗
        .sheet(isPresented: $showLocalModels) {
            LocalModelsSheet()
        }
        // v2.0.102：切回设置页刷新计数（密码管理/记忆增删后行尾数字即时更新，原只有 .task 首刷）
        .onAppear { Task { await loadCounts() } }
        .task {
            await loadCounts()
            await loadLocalStatus()   // v-review fix：进入设置页即以后端 /api/local/status 校准本地模型开关
        }
    }
}
