# 轻聊 2.0（Qingliao）— 原生 iOS AI 助手

家庭 NAS 上的 AI 助手客户端，SwiftUI 原生（非 HTML 套壳），连接自部署后端（Hermes + 自研 Python 服务），提供 AI 对话、智能家居看板（Home Assistant）、NAS/路由器状态、Docker 管理、知识库、AI 记忆、密码管理、定时任务等能力。iOS 17+（实测 iOS 26/27），SideStore 侧载分发。

> 本文档面向**接手开发/发版的 AI 代理**：读完可独立完成「改功能 → 自查 → 发版 → 交付」全流程。

---

## 🚀 快速上手（开发环境）

- 仓库默认分支：**`native-2.0`**（唯一开发分支，也是远端默认分支——Actions 只认默认分支的 workflow）
- 工程由 **XcodeGen** 生成（`project.yml`），源文件目录 `qingliao/` 整体 glob，**新增 .swift 文件无需改 project.yml**
- `check_swift.sh`：Linux 下的 **swiftc -parse 纯语法检查**（全工程）。**⚠️ 只查语法不查类型/作用域/并发**——类型错误、方法插错 struct、@MainActor 违规只有 CI 编译才暴露（v2.0.90 实踩：方法误入 PasswordSheet struct，语法全过、CI 报 cannot find in scope）

```bash
./check_swift.sh        # 提交前必跑（输出"全部通过"）
```

## 🔧 发版流程（唯一 CI 触发方式）

CI 只在 **`v2.0.x` tag 推送**时触发（分支 push 不触发），产出 unsigned IPA artifact。

```bash
# 1) 版本号：project.yml 4 处必须一致（CFBundleShortVersionString / CFBundleVersion / MARKETING_VERSION / CURRENT_PROJECT_VERSION）
#    grep -n '"2.0.x"' project.yml 确认全部为最新版本，否则崩溃日志版本误导定位（v2.0.53 教训）
# 2) 自查（见下）+ ./check_swift.sh + commit
git push origin native-2.0
git tag v2.0.x && git push origin v2.0.x     # 触发 CI（约 15-20 分钟）
```

- **⚠️ 同 tag force push 不触发 CI**（GitHub 只认新建 tag）——失败重试必须**删远端 tag 重建**（`git push origin :refs/tags/vX`）或升新版本号
- **⚠️ 发版前必须问用户**：private 仓库 Actions 额度 2000 分钟/月、macOS runner 按 10 倍扣费，约 10-13 次构建/月，**攒 2-3 个改动发一版**
- CI 失败排查：`GET /actions/runs/{id}/jobs` → job_id → `GET /actions/jobs/{id}/logs` → `grep -n 'error:'`（编译错误全在日志里）。**0 steps 失败 = 额度耗尽/基础设施**，有具体 error: 行 = 真编译错误
- 构建成功 → 下载 workflow **artifact**（release asset 会停旧版，v2.0.85 教训）→ **解包校验 Info.plist 的 CFBundleShortVersionString == tag 版本**（双保险 + md5）→ 转存交付目录
- 版本号未随 tag 升 = 用户装了新版但崩溃日志显示旧版（v2.0.53 教训）

## 📋 编译前自查清单（每个改动必过）

1. **新增/移动方法或属性 → 核对 struct 边界**：`grep -n "^struct \|^}"` 确认落点；方法插进别的 struct 语法合法但 CI 必挂（v2.0.90 实踩）
2. **组件加参数 → grep 全部调用处**（v2.0.85 MeterCard 加 icon 漏 RouterPanel → CI 失败）
3. **@AppStorage 同一 key 多处读取 → 默认值必须逐处一致**（不一致 = 显示状态≠实际状态，v2.0.45 教训；Siri 发光参数在 LiquidGlass + SettingsView 两处，默认值 1.0/2.2/0.18/22.0 必须同步）
4. **复杂 ViewBuilder 表达式（字典索引+插值+嵌套+闭包）→ 拆独立子视图**，否则 "unable to type-check in reasonable time"（KBView/DockerSheet 教训）；ForEach 行内避免 `d["key"] as? X`
5. **删除/重构用精确 patch，禁用正则批量删**（v2.0.83 误删 140 行教训）
6. **改 UserDefaults 驱动的显示 → 用 @AppStorage 不用 computed property 直读**（否则设置改了界面不刷新，v2.0.48 教训）
7. **Swift 6 并发坑速查**：
   - PreferenceKey.defaultValue 必须 `static let`（v2.0.49）
   - 全局可变缓存/单例（NSCache 等）→ `@MainActor` 隔离（v2.0.87f）
   - 系统 delegate 协议（CLLocation/UNUserNotification）配 @MainActor 类 → conformance 交叉报错，改 `@unchecked Sendable` 非隔离类（v2.0.87w2）
   - `.foregroundStyle` 三元两个分支必须是同一具体类型（.tertiary 与 Color 混用必编译错，v2.0.78）

## 🏗 架构地图

```
QingliaoApp.swift        入口：登录门禁（auth.isLoggedIn ? DockTabView : LoginView）+ 崩溃上报 + Siri 发光根层
Core/
├── AuthStore.swift      登录/统一请求入口（网络分流）+ Face ID 凭据保存
├── StreamClient.swift   流式轮询（0.15s 高频/0.4s 空轮询自适应，taskId+offset）
├── ChatStore.swift      会话/消息（append/upsertAssistant/historyPayload）
├── NetworkMonitor.swift 蜂窝判定（有 WiFi/有线接口绝不判蜂窝）
├── SafariRelay.swift    蜂窝兜底（iOS 27 管控）
├── KeychainHelper.swift Face ID 登录凭据（Keychain）
├── Models.swift         ChatMessage（含 queued 排队标记）/ ChatSession / HAEntity
├── CrashReporter.swift  signal-safe 崩溃上报（handler 内只用 POSIX + C 字面量）
└── ImageCache.swift     dataURL → UIImage（@MainActor NSCache）
Features/
├── Chat/ChatView.swift  聊天页（发送/排队/分享/引用/图片查看/搜索定位）
├── Chat/ChatComponents.swift  气泡/输入栏/组件
├── Sessions/            会话列表
├── Dashboard/           看板（智能家居 HA / NAS / 路由器 / Docker / 天气）
├── Settings/            设置（连接/模型/外观/密码管理/知识库/AI 记忆/HA）
└── Auth/LoginView.swift 登录页（Face ID 快捷登录）
Theme/LiquidGlass.swift  玻璃主题 + SiriGlowOverlay（参数化发光）
```

### 关键设计决策（改动前必读）

- **iOS 27 蜂窝管控**：蜂窝下直连 POST 被系统拦截 → CFStream 直连优先、失败降级 Safari Relay（ASWAS 弹窗可接受，蜂窝可用优先）；**WiFi 绝不判蜂窝**（hasLAN 保护）。自动触发类请求（scenePhase 恢复重连）只走静默直连试探，**绝不走 relay**（否则每次回前台弹授权窗，v2.0.87ar）
- **流式**：后端 stream_api 按 taskId 存内存+落盘，App 轮询；首 token 10-20s 属正常（上游 agent loop 思考），等待期必须有 TypingIndicator
- **连续发消息（v2.0.88）**：AI 回答中发送 → 消息上屏标记 `queued` + 入 `pendingQueue` → 回答完成回调自动发下一条（复用已上屏消息，不重复插入）；停止按钮清队列；切换会话清队列。**禁止直接清空 messages 数组**（列表从有到无同帧 SIGTRAP 铁律：flag + ChatView onChange 两步走，v2.0.58）
- **微信分享（v2.0.88）**：微信分享扩展不支持纯文本 → 图片消息分享原图 / 纯链接分享 URL / 文本渲染白底文字图片；iPad 必须有 popover 锚点
- **Face ID 登录（v2.0.88-90）**：登录成功存 {server,username,password} 到 Keychain；登录页按钮开关开即显示（无凭据点击提示先登录）；设置开关打开时**立即申请系统权限**（失败回滚+提示）；`deviceOwnerAuthentication`（带密码回退）
- **Siri 发光（v2.0.87bb→bn 定稿 + v2.0.91 参数化）**：RootView ZStack 顶层 zIndex(20)，只 `ignoresSafeArea(.top)`（全边会破坏底部 safe area 致 dock 偏位，v2.0.87bl 教训），GeometryReader 容器 + 顶部补偿；4 参数 @AppStorage：`qingliao_siri_glow_brightness`(1.0)/`_freq`(2.2)/`_amp`(0.18)/`_width`(22.0)，设置页滑条实时生效
- **崩溃上报**：signal handler 只允许 POSIX open/write/close/getenv/strcpy + C 字符串字面量直写（任何 Swift String 构造都非 signal-safe）；完整栈走 NSException handler；崩溃信息下次启动 flush 上传
- **列表崩溃三连排查**：①从有到无同帧 → VStack+分帧两步走；②TabView 隐藏页清空 → 换掉 .scrollPosition（PreferenceKey 方案）；③数组就地 removeAll + ForEach diff → 后端驱动 + load() 整体替换

## 🆕 近期变更（2026-08-16，v2.0.117 → v2.0.120，接手必读）

- **v2.0.117**：智能建议长条卡；本地模型初版（设置开关）；Siri 快捷指令移除（QingliaoAppIntents.swift 已删，勿加回）
- **v2.0.118**：天气修复（`loadWeather` 带 city 参数——原无 city 走 IP 定位，NAS 出口无公网 IP → temp null 不显示温度）；设置页 6 分类重组（账号与安全 / 连接与模型 / AI 智能 / Agent 设置 / 数据与自动化 / 外观与显示）；本地模型自主管理（`LocalModelsSheet.swift` 新文件：动态列表 / 点选勾选 / 拉取新模型 / 左滑删除）；模型选择弹窗本地分组动态拉取 `/api/local/models`
- **v2.0.119**：智能建议卡门锁风格（标题左上 / 内容靠左 / 右上小胶囊）；本地模型列表选中勾选（`currentLocal` 对比 qingliao_provider==local）
- **v2.0.120**：智能建议卡浅色边框（strokeBorder 0.8pt）
- **v2.0.121（攒着未发）**：DockerSheet YAML 输入框键盘收回修复（iOS 17 FocusState 偶发失效 → `resignFirstResponder` 强制收回 + 提交部署时先收键盘）；设置页全部开关统一绿底小号（`tint(.green)` + `scaleEffect(0.8)`，9 处）
- 本地模型链路：聊天模型选择「本地模型（断网兜底）」→ provider=local + model=Ollama 模型名 → 后端 stream_api 直连 Ollama（不经 Hermes）

## 🔀 分支与版本

- `native-2.0`：唯一开发分支（默认分支）；旧 `master` 本地残留可忽略（勿 push）
- 版本演进记录在提交信息（v2.0.87bn 起每提交带版本后缀）；发版 tag = `v2.0.x` 整数递增
- 仓库为 public：**任何提交不得包含真实服务器域名/公网 IP/内网 IP/密码/token**（此前已做全历史脱敏，v2.0.52-54；新引入敏感信息即泄露）

## 📁 仓库外运维（宿主本机，不在 git）

- `/opt/data/qingliao_icon/`：`watch_ci_v2034.py`（轮询 CI → 下载 artifact，改 RUN_ID/EXPECT_SHA 后运行）、`ship_ipa.py`（paramiko 转存 IPA 到交付目录，stdin base64 管道 + md5 校验）、`sync_app_dir.py`；**脚本目录可能被系统清理，丢失从会话历史重建**
- 后端（自部署 Python 服务）与完整开发经验沉淀在 Hermes 技能 `qingliao-ios-native` / `qingliao-webui`（改后端前必读）
