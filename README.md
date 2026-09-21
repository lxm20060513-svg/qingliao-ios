# 轻聊 3.0（Qingliao）— 原生 iOS AI 助手

家庭 NAS 上的 AI 助手客户端，SwiftUI 原生（非 HTML 套壳），连接自部署后端（Hermes + 自研 Python 服务），提供 AI 对话、智能家居看板（Home Assistant）、NAS/路由器状态、Docker 管理、知识库、AI 记忆、密码管理、定时任务等能力。iOS 17+（实测 iOS 26/27），SideStore 侧载分发。

> 🔗 **后端开源**：本 App 配套的后端服务（统一 API，Docker 部署）已开源至 [`github.com/lxm20060513-svg/qingliao-backend`](https://github.com/lxm20060513-svg/qingliao-backend)（MIT），含 `docker-compose` + `.env.example` + 完整部署文档，部署/升级请参照该仓库。

> 本文档面向**接手开发/发版的 AI 代理**：读完可独立完成「改功能 → 自查 → 发版 → 交付」全流程。
>
> 注：内部交接与运维文档（发版沿革、运维手册、内部体检记录）**不入本公开仓**，只保留在部署环境中。

---

## 🚀 快速上手（开发环境）

- 仓库默认分支：**`feature/handoff-301`**（当前的 3.x 开发与发版线，GitHub 上的 default branch）。`native-3.0` 是 3.0 早期主线，已落后本分支数百提交、不再是默认分支
- **2.0 已收官**（v2.0.140 终版）：历史冻结在 `native-2.0` 分支 + tag `v2.0.140`，2.0 产物归档于 NAS `轻聊app/archive/2.0-final/`；3.0 从 2.0 HEAD 切出，git 历史完整
- 工程由 **XcodeGen** 生成（`project.yml`），源文件目录 `qingliao/` 整体 glob，**新增 .swift 文件无需改 project.yml**
- `check_swift.sh`：Linux 下的 **swiftc -parse 纯语法检查**（全工程）。**⚠️ 只查语法不查类型/作用域/并发**——类型错误、方法插错 struct、@MainActor 违规只有 CI 编译才暴露（v2.0.90 实踩：方法误入 PasswordSheet struct，语法全过、CI 报 cannot find in scope）

```bash
./check_swift.sh        # 提交前必跑（输出"全部通过"）
```

## 🔧 发版流程（唯一 CI 触发方式）

CI 只在 **`v*` tag 推送**时触发（分支 push 不触发；版本线现为 `v3.9.x`），产出 unsigned IPA artifact，并覆盖上传到 release `qingliao-ipa-2`（NAS/Hermes 从这里取包）。

```bash
# 1) 版本号：project.yml **8 处**必须一致——主 App 与挂件 target（QingliaoWidget）各 4 处
#    （CFBundleShortVersionString / CFBundleVersion / MARKETING_VERSION / CURRENT_PROJECT_VERSION）
#    grep -nE 'CFBundleShortVersionString:|MARKETING_VERSION:|^ *CFBundleVersion:|CURRENT_PROJECT_VERSION:' project.yml
#    —— 8 行必须全是最新版本，否则崩溃日志版本误导定位（v2.0.53 教训）；CI 的 Check version literals 步骤
#    会在 Archive 前用同一口径再判一次，并把 tag 名与 project.yml 版本对比
#    新增 target（widget/extension）必须写它自己的 Info.plist 版本号，否则 XcodeGen 默认落 1.0/1（v3.8.0 教训）
# 2) 自查（见下）+ ./check_swift.sh + commit
git push origin feature/handoff-301
git tag v3.9.x && git push origin v3.9.x     # 触发 CI（约 15-20 分钟）
```

- **⚠️ 同 tag force push 不触发 CI**（GitHub 只认新建 tag）——失败重试必须**删远端 tag 重建**（`git push origin :refs/tags/vX`）或升新版本号
- **⚠️ 发版前必须问用户**：本仓库是 **public**，Actions 的 macOS 分钟不占账号额度（旧纪录里写的「private 2000 分钟/月、10 倍扣费」已不适用），但一次构建仍要 15-20 分钟 runner 时间 —— **攒 2-3 个改动发一版**，别一个改动一次 tag
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
8. **新增 target / App 扩展（widget、extension）→ 三件事必做**：① 给它写 `info.properties` 的 `CFBundleShortVersionString`/`CFBundleVersion`（不写 XcodeGen 落 1.0/1）；② 主 App 要声明 `dependencies: [{target: X, embed: true}]`，`.appex` 才会编进 `Payload/*.app/PlugIns/`；③ CI 的 Verify 步骤会校验 `.appex` 精确路径 + `NSExtensionPointIdentifier` + 主 App `NSSupportsLiveActivities`（v3.8.0 建立）

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
├── CrashReporter.swift  signal-safe 崩溃上报（handler 内只用 POSIX + C 字面量；NSException→crash_pending.json，信号→crash_pending_sig.json + crash_stack.txt）
├── ImageCache.swift     dataURL → UIImage（@MainActor NSCache）
├── LiveActivityManager.swift    灵动岛/锁屏实时活动（本地 request/update/end；不持有 Activity 本体——Swift 6 sending 限制）
└── LiveActivityAttributes.swift 实时活动共享属性（主 App 与挂件同编一份，改一处等于改两侧）
Features/
├── Chat/ChatView.swift  聊天页（发送/排队/分享/引用/图片查看/搜索定位）
├── Chat/ChatComponents.swift  气泡/输入栏/组件
├── Sessions/            会话列表
├── Dashboard/           看板（智能家居 HA / NAS / 路由器 / Docker / 天气）
├── Settings/            设置（连接/模型/外观/密码管理/知识库/AI 记忆/HA）
└── Auth/LoginView.swift 登录页（Face ID 快捷登录）
Theme/LiquidGlass.swift  玻璃主题 + SiriGlowOverlay（参数化发光）
Theme/StateView.swift    首屏三态组件：LoadingStateView（骨架/转圈两档）+ ErrorStateView（空态仍用 EmptyStateView）
QingliaoWidget/          挂件 Extension target（.appex）：灵动岛/锁屏实时活动 UI（ActivityConfiguration）
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
- **灵动岛 / 实时活动（v3.8.0）**：只做本地驱动（侧载免费签名拿不到 Push 能力，不做 APNs/push-to-start）；`LiveActivityManager` **不持有 `Activity` 本体**——存进 `@MainActor` 存储再 `await update/end` 会报 Swift 6 `sending 'activity' risks causing data races`，改为只存 Sendable 状态、每次从 `Activity.activities` 现取（且该列表最终一致，收尾空列表时等 600ms 再收一次）；计时用 `Text(_:style:.timer)` 交系统走（App 被挂起后文案不再刷新，这是设计内降级）；挂件与主 App 共用 `qingliao/Core/LiveActivityAttributes.swift`（同编一份，改一处等于改两侧）；开关 key `qingliao_live_activity`（默认开）
- **实时活动收尾口径（v3.9.42）**：判「这条活动还在不在」一律走 `LiveActivityManager.isCollectible(_:)` = `active | stale | pending`，**严禁再写 `== .active`**。理由：`ActivityState` 共五档（Apple 文档核过，无 `.inactive`），而 `.stale`（本仓 `staleDate` +15min，App 挂起/强杀期间推手停摆必转此档）**画面仍挂在锁屏与灵动岛上**，只认 `.active` 会让 `finish()`/启动收敛/推手全部对它失明 → 僵尸活动永久留屏，且 `hasLiveActivity` 认不出它还会 `request` 出第二条（锁屏同时两行）；`.ended`/`.dismissed` 才是真没了（前者再 end 一次会打断既定收起时机，后者是最终一致窗口的闪现残留）。**收尾驱动必须有 App 级接收者**：`finish()` 原唯一驱动是 `ChatView.onChange(of: aiBusy)`，v3.9.41 把 aiBusy 按会话收窄后「切走那个 ChatView」就再也收不到它的完成信号 → 现由 RootView（常驻不销毁）观察 `stream.finishSeq` 调 `finishOrphanedRound(...)` 兜底，并在每次 `scenePhase == .active` 调 `convergeOrphanActivities()` 扫孤儿（靠不变量「`currentSessionId == nil` ⇒ 系统里那条一定是孤儿」，流式中回前台会被内部守卫直接 return，不会误杀）
- **首屏三态（v3.9.42）**：新增页面的"这一屏还没内容"一律用 `Theme/StateView.swift` 的 `LoadingStateView`（列表结构可预测→`.rows(n)` 骨架；网格/分组→`.spinner(text:)`，别硬编假骨架）与 `ErrorStateView`（图标+标题+详情+重试），空态用既有 `EmptyStateView`。**不要**再手抄 `ProgressView()` 或"加载失败+重试"那 20 行。**行内"操作进行中"的小转圈（保存按钮、ping、刷新）不在此列**——那类要原地 14pt，换骨架会撑跑布局
- **减弱动态效果（accessibilityReduceMotion）**：任何循环/帧源动画必须有静态档——`repeatForever` 走 `reduceMotion ? nil : …`，`TimelineView` 呼吸层（Siri 边框光 / 灵动岛光）走"不建帧源、按正弦中值定稿一帧"，Metal 头像（`LiquidOrbAvatar`）走 `freezesMotion`（播完状态过渡即 `isPaused` 冻成静态图）。关键帧反馈（发送键 `sendPulse`）用 `trigger: reduceMotion ? 0 : tick` 关掉
- **聊天附件只发引用、不发全文（v3.9.44）**：`sendFile` 上传成功后消息正文只写 `[文件: 名字]（已上传 NAS：doc=<服务器 saved 名>）`，**不再**在客户端提取正文（原 txt/md 直读、PDF 走 PDFKit，各截 12000 字拼进消息）。根因：拼进正文的全文会随历史落库，之后**每一轮都重发给模型**（token 每轮重付 + 上下文被挤爆），而 docx/xlsx/pptx 客户端不提取、AI 反而读不到。现在正文由后端 `doc_ref.py` 在组装 prompt 时按需读原件（最新 user 轮全文、更早轮节选），App 端 `extractPDFText` 已删。⚠️ **上线顺序**：后端必须先于本 App 版本部署，否则 AI 只看得到文件名；`saved` 缺省（老后端不回该字段）时退回无 `doc=` 的旧标记

- **登录成功「卡片飞成首页」的交接窗口（v3.9.45）**：`RootView` 的门禁**不能**写成 `if isLoggedIn { Dock } else { Login }` —— 登录页自己的退场演出（0.2s 延迟 + 0.45s 上浮淡出）会在 `isLoggedIn` 翻真的那一帧被整块摘掉，用户只看到硬切。现在是 `if loggedIn { Dock }` + `if !loggedIn || loginHandoff { LoginView(revealed: !showSplash) }`：登录成功后 `loginHandoff` 让本页**多挂 0.95s** 演完再撤，`zIndex(loggedIn ? 2 : 0)` 保证它压在 DockTabView 之上但**在 AppLockView(5) 之下**（登录页永远不许盖住锁屏），并 `.allowsHitTesting(!loggedIn)` 让半透明的旧卡片那 0.95s 不吃点击。三个坑：① 递延倒计时由 `revealed: !showSplash` 驱动而不是 `onAppear`，否则整段进场被 0.6s Splash 盖住；② `reduceMotion` 下 `loginHandoff` 恒 false，走改动前的瞬间切换；③ 登录页的失败抖动是 `keyframeAnimator(trigger:)`，`errorMessage` 变化才 +1，静态档传 0 常量

- **iOS 26 系统玻璃的三条口径（v3.9.46 立，v3.9.47 补，v3.9.48 判终）**：① **空的 `ToolbarItem` 照样会拿到一层玻璃底**——条件按钮必须把 `if` 写在 `ToolbarItem` **外面**（一个 ToolbarItem 包两个 `if` 的写法，两个条件都不成立时残留一枚无文字空胶囊，即任务中心那个 bug）；② tab bar 的玻璃是系统自绘的（v3.0.64 起无自绘 DockBar），**`.toolbarBackground(.hidden, for: .tabBar)` 真机实测无效**（v3.9.46 上的方案 A，用户 2026-09-21 判「玻璃还在」）——iOS 26 只褪背景色、玻璃层照旧，别再当开关用；③ **UIKit 那条路也走过了，同样真机判无效**（v3.9.47 方案 B：`TabBarGlassProbe` 把真实 `UITabBar` 的 `standardAppearance/scrollEdgeAppearance` 换成 `configureWithTransparentBackground()` 副本）→ v3.9.48 用户判「回滚」，`Features/TabBarGlass.swift` 整块删除。**这就是终点：不再有第三条方案**，A/B 都不要复活。**两条红线不变**：不在 TabView 下层铺不透明色（掐死所有页的滚动边缘折射，v3.4.29）、弹窗背景不覆盖系统材质（v3.9.23）
- **弹窗内的卡片不用实色底（v3.9.47）**：`.dashboardCard()` 的 `secondarySystemGroupedBackground` 铺在**弹窗**那层系统材质上等于盖白板 → 弹窗里一律 `.frostedCard()`（`ultraThinMaterial` + 16 圆角 + 0.8pt 描边 + 两层柔影，卡形与 `dashboardCard()` 同参）。**注意与 `GlassListCard` 的浅色档区分**：那是 `Color.white.opacity(0.85)`，用户明确不要白底。看板/生活页的**网格卡不受本条约束**，仍走 `dashboardCard()`
- **滚动性能口径：`onScrollGeometryChange` 的投影必须"夹成常量"**（v3.9.48 立）：这条 API **只在投影值变化时**才调 `action`。所以投影表达式里凡是"正常滚动期间逐帧都在变"的量（典型：`contentOffset.y - bottomMax`，未过拉时是负数且每帧不同）**必须在投影里就夹成常量**（`<= 0 ? 0` 再取整），否则等于每帧回调 + 每帧写 `@Observable`——**Observation 不做等值比较，写同值一样标脏读它的视图**。聊天页那颗 `ultraThinMaterial` 上拉胶囊就这么被整场滚动期标脏过（v3.9.48 修）。判定用的 Bool 投影天然边沿触发，不受本条约束。**同一族的第二刀**：常驻视图（dock 智慧球 5 个 tab 全程可见）里"每帧变化的内容 + `.shadow`"= 每帧重算阴影。**但这一刀先过观感再动手**——v3.9.48 把智慧球阴影静态化，真机判"气色掉了"，v3.9.49 回滚：那层脉动投影是资产，不是免费的性能预算（v3.2.3 输入框那条讲的是"每帧变化的渐变+阴影"卡死，代价口径不同）
- **装饰链上的 `.animation(value:)` 必须放在最后一个会随它变化的图层之后**（v3.9.49 立，真机「输入框有两层重叠在一起」）：`.animation` 只对它**上游**的图层生效，写在中间就等于让后面的图层"瞬时跳变"——同一形状被两层 overlay 各画一遍时，一层插值一层不插值，观感就是两圈错开的轮廓。配套口径：**一个容器只画一圈边**（常态/聚焦是同一笔描边的两档配色，不是两层 overlay）；**玻璃里不再套玻璃**（内层小胶囊要底色 + 细边，不要再 `glassEffect`，见 `ChatInputBar.modelPill`）
- **`barShape.glassEffect()` 是错的用法：玻璃形状只认 `in:` 参数**（v3.9.51 定稿，Apple 文档实证签名 `glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape())`）。这条纠正了 v3.9.50 记的那句"glassEffect 不跟圆角插值"——**真实成因不是动画**：把修饰符挂在形状视图上时，`in:` 走默认值 `DefaultGlassEffectShape`，玻璃按系统默认形状画，`barShape` 只贡献了 bounds、那 22pt 根本没进渲染；再叠上容器自身那圈 `.shadow`（沿布局边界投影），就是"内圈大圆角 + 外圈方角"两圈。**正确写法：玻璃直接挂在内容上，形状显式传进去** —— `.padding(...).glassEffect(.regular, in: barShape)`，描边/流光 overlay 复用同一个 `barShape`，两圈不可能再错开。全仓可用先例：`Pill.swift` 的 `.padding(...).glassEffect(.regular.interactive())`（那些胶囊从没出过两圈）。配套：**玻璃容器外面不再另画 `.shadow`**（玻璃自带投影，画第二圈等于把外圈轮廓加回去）
- **两态换布局容器（HStack ↔ VStack）会重建 `TextField` → 键盘"弹一下又收回"**（v3.9.50 立，v3.9.51 真机判死并回退）：SwiftUI 的视图身份按结构路径算，把 TextField 从 HStack 的第二个子挪到 VStack 的第一个子 = 换父级 = 重建，重建瞬间掉 first responder。**⚠️ 换门控救不了**：v3.9.50 把 `expanded` 从 `focused` 换成 `kbEnv.isVisible`（系统通知驱动，理论上没有反馈回路），真机 495 报障照旧——因为回路不在 `focused` 上，在**键盘自身**：视图重建 → 承载 TextField 的 UIKit 视图被换掉 → 键盘跟着收。**唯一有效的口径是容器不换**：两态共用同一个 `HStack`，展开只改 `lineLimit` 与高度；要插条件子视图就插在 TextField **之后**（TupleView 里 TextField 的 index 不变，身份稳定）。同一族的历史坑：v2.0.98 发送键"两个手势叠着改视图树"实测 SIGTRAP

## 🆕 近期变更（v3.9.51，2026-09-21）

- **第三轮修"两圈"：病根是 `glassEffect` 的形状参数没传，不是圆角动画**（真机 495：「还是有两圈」，需真机验收）：Apple 文档实证签名为 `glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape())`，而 v2.0.87e 起输入栏写的是 `.background { barShape.glassEffect() }` —— 形状走默认档，玻璃按 `DefaultGlassEffectShape` 画，`barShape` 的 22pt 只贡献 bounds；外面那圈是容器自身 `.shadow(radius: 14)` 沿布局边界投出来的。现在改成玻璃**直接挂内容 + 形状显式传参**：`.padding(...).glassEffect(.regular, in: barShape)`，并把那圈 `.shadow` 整条删除（玻璃自带投影）。描边 overlay 与流光复用同一个 `barShape`，与玻璃边界同参 → 结构上不可能再错开。v3.9.50 那条"glassEffect 不跟圆角插值"的结论已在设计决策里改写
- **展开态布局回退单行**（真机 495：「点输入框弹一下又收回了」，需真机验收）：v3.9.50 的「文字在上、工具行在下」两行 = HStack ↔ VStack 换容器 = TextField 换父级重建，**换门控（`focused` → `kbEnv.isVisible`）没能切断它**，因为回路不在 `focused` 上而在键盘本身（承载视图被换掉 → 系统收键盘）。现在 `fullInputBar` 只有一套 `HStack { attachButtons; textArea; if expanded, !modelLabel.isEmpty { modelButton }; trailingButtons }`——条件块排在 textArea 之后，TextField 在 TupleView 里的 index 恒定不重建。展开态的"变大"只由 `lineLimit(2...6)` 与高度插值给出，文本区 `.padding(.vertical)` 两态都回到 `Spacing.xl`（v3.9.50 那档 `Spacing.xs` 的理由是"行距由 VStack 给"，VStack 没了它也就没了）。**代价：参考图那个"两行"结构做不了**，要它就得让 TextField 换父级

## 🆕 近期变更（v3.9.50，2026-09-21）

- **输入栏容器只留玻璃这一层**（真机第二轮：「还是内有大圆角、外有方形圆角」，需真机验收）：v3.9.49 那一轮把两笔描边并成一条、把 `.animation` 挪到链末，**没治好**——真正的病根是 `glassEffect` 不跟圆角插值：聚焦展开后玻璃还按收起时的胶囊画（内圈大圆角），描边 overlay 已经走到 22pt 方角（外圈），于是两圈不同圆角的轮廓。这轮从源头收：① `barShape` 圆角**恒定** `Radius.hero`(22)，不再有 999↔22 的插值（代价：收起态由纯胶囊变成 22pt 圆角矩形，栏高约 62 → 胶囊半径 31，只差 9pt）；② `edgeColor` 在展开态直接 `.clear`，玻璃外面不再浮第二圈描边（收起态与语音/录音/转写三态照 v3.4.20 原样保留蓝/白边）。展开态不再靠蓝环表意，"长开 + 第二行"本身就是聚焦提示。**→ v3.9.51 真机 495 判：仍在两圈，且成因不是插值而是 `in:` 没传（见上一条），本轮的"恒定圆角 + 展开不画描边"作为兜底保留**
- **模型胶囊：文字变灰**（用户：「输入框内模型用灰色字体」）：`Text(modelLabel).foregroundStyle(.secondary)`，图标留 accent。顺带记下那阵"图标和名字之间的空隙"从何而来：`frame(maxWidth: 120, alignment: .trailing)` 把短名推到了框右端——**这条已在下面的 #2 里连框带图标一起删掉，仅作踩坑记录**
- **展开态换成「文字在上、工具行在下」两行布局**（用户给参考图，选做 #1，需真机验收）：`ChatInputBar` 拆成 `collapsedBar`（逐字沿用 v3.9.47 那一行）与 `expandedBar`（`VStack { textArea; HStack { attachButtons; Spacer; modelButton; trailingButtons } }`），三块 `attachButtons` / `textArea` / `trailingButtons` 两态共用一份，`trailingButtons` 内部 `HStack(spacing: 8)` 与外层行距同参 → 收起态视觉零差异。文本区在展开时把 `.padding(.vertical, Spacing.xl)` 收成 `Spacing.xs`（行距改由 VStack 给）。**⚠️ 本轮最大的风险点：两态是两套容器，TextField 换父级会重建**，重建瞬间可能掉 first responder → 键盘收回 → 布局再翻回去，形成反馈回路。所以 `expanded` 的门控从 `focused` 换成 **`kbEnv.isVisible`**（键盘可见性由系统通知驱动，不受视图树重建影响，没有那条回路）。真机若出现"点输入框键盘弹一下又收回/闪"，第一嫌疑就是这里，回退方向是把布局改回单行而不是换门控。**→ v3.9.51 真机 495 正是这条报障，已按"回退单行"执行；换门控无效，别再往门控上找**
- **模型名连壳带图标一起撤掉，只留纯灰文字**（用户参考图，选做 #2）：v3.9.49 那枚非玻璃胶囊壳（`modelPill`）整块删除（连带 `extension View.modelPill`，已无调用点），`modelButton` = `Text(modelLabel)` + `Typography.subhead` + `.secondary` + 中部截断 + `hitArea44(h: 10, v: 13)` 撑到 44 命中高，排在工具行右半段（停止/发送左侧）。玻璃栏里再画一枚带底带边的壳，读起来仍然是"两层"，这次一并收

## 🆕 近期变更（v3.9.49，2026-09-21）

- **智慧球的投影回滚**（用户：「智慧球回滚」）：`ChatEffects.SiriBallView` 的球体阴影恢复成 `Color.indigo.opacity(0.45 * breathe)`，也就是**跟着呼吸一起脉动**。v3.9.48 为了省掉"每帧重算阴影"把它写成常量 0.22，真机结论是观感回退（球的气色掉了）——那层脉动投影是**资产不是预算**。回滚只动这一行，v3.9.48 另外两刀（聊天滚动投影、会话列表惰性）不受影响
- **tab bar 玻璃彻底收手**（用户：「tab bar 也回滚」）：v3.9.47 的方案 B 整块撤除——删 `Features/TabBarGlass.swift`（`TabBarGlassClearer` / `TabBarGlassProbe` 探针），`DockTabView` 上那句 `.background(TabBarGlassClearer(clear: selected == .chat))` 一并摘掉，`DockOrbOverlay.findTabBar(in:)` 收回 `private`（现在只剩它自己两处调用）。**方案 A 不复活**（`.toolbarBackground(.hidden, for: .tabBar)` 真机已判只褪背景色、玻璃照旧）。结论进「iOS 26 系统玻璃的三条口径」：A、B 两条路都走过都无效，**这就是终点**，第三条不要提，铺不透明层更不行（v3.4.29 红线）
- **输入栏容器只留一圈边**（真机：「输入框有两层重叠在一起」，需真机验收）：v3.9.48 把装饰整体上移到外层 VStack 后，容器同一条路径上其实画了**两笔描边**——`focusRing`（聚焦蓝 0.45）和 `glowOverlay` 的 else 分支（常态白 0.12），而 `.animation(Motion.snap, value: focused)` 夹在两者**中间**：白环拿不到这个 transaction，聚焦瞬间玻璃+蓝环在插值、白环已经跳到展开形状，两圈轮廓错开就是那"两层"。修法：删 `focusRing`，白/蓝两档配色并进唯一的 `edgeOverlay`（`focused ? 蓝 : 白`，streaming 时仍走流光），并把两句 `.animation` 挪到修饰符链**末尾**（阴影仍在 overlay 之前，v3.2.3 红线不动）。口径：**装饰链上任何 `.animation(value:)` 都必须放在最后一个会随它变化的图层之后**，否则后面的图层就是不动画的那一个
- **模型胶囊：去 provider、去玻璃、不贴边**（真机：「模型胶囊不用显示provider，只显示模型即可，不要超出输入框」）：`ChatView.composerModelLabel` 从 `provider/model` 改成只取 `resolveModel(...).0`——胶囊本来就窄，带前缀只装得下 `opencode/d…eek-v4-flash` 这种读不出来的截断串。样式从 `chatHeaderPill()`（内含 `glassEffect(.regular.interactive())`）换成本文件新增的 `modelPill()`：**形状/字号/内边距逐字照抄 `chatHeaderPill`，只把玻璃换成 `accentColor` 淡底 + 同色 0.8pt 细边**——玻璃栏里再浮一块玻璃就是第二层"重叠"。宽度：文字 `maxWidth` 150 → 120，行右侧再让 `Spacing.sm`(6)（容器横向内边距只有 `Spacing.lg`(10)，而玻璃可见边缘比布局边界还要再缩一圈，胶囊贴边画就等于压在线上）

## 🆕 近期变更（v3.9.48，2026-09-21）

- **聊天输入栏改成展开式 composer + 模型快选（需真机验收）**（用户：「点击输入框时候输入框变大，右下角可以选模型」）：`ChatInputBar` 从「一条 HStack 带全部装饰」重构成 **外层 VStack（装饰层）+ `inputRow`（第一行）+ `modelRow`（第二行）**。`expanded = focused && !isRecording && !voiceMode && !transcribing`——录音/语音/转写三态各有自己的输入栏形态，不参与"变大"。展开时文字区起判行高从 1 行抬到 2 行（`lineLimit(expanded ? 2...6 : 1...6)`），右下角浮出模型胶囊（`chatHeaderPill()` 同档，模型名 `frame(maxWidth: 150)` 中部截断，不撑破栏宽）。**容器形状不换类型**：`barShape` 恒为 `RoundedRectangle(style: .continuous)`，收起时半径 999（被夹成半高 = 与原来的 `Capsule()` 同形）、展开时收成 `Radius.hero`(22) → 半径可插值，切换是"长开"不是跳形，也省掉 `AnyShape` 擦除；玻璃底/聚焦描边/流光/阴影四层装饰整体上移到 VStack，`Capsule()` 全部换成 `barShape`（流光形状跟着长开；**这四层里两笔描边叠在同一路径、且其中一层不参与展开动画 = 真机看到的"两层重叠"，v3.9.49 已并成一圈，见上**），阴影仍在流光 overlay **之前**（v3.2.3 卡死红线）。新参数 `modelLabel` / `onPickModel` **追加在 `contextUsage` 之后**（调用点走成员初始化器按声明序传参）
- **`ComposerModelSheet`（`ChatSheets.swift`）= 短平快的切面板**：与设置里的 `ModelSheet` 分工——那边管 provider 增删/同步/TTS/视觉模型，这里只管"当场换一个接着聊"，选完即写 `qingliao_model`/`qingliao_provider`（与 `ModelSheet.setModel` 同一口径）+ `Haptics.success()` + 立即收起。**零网络**：列表直接读 `ModelProvidersCache.load()`（模型管理每次同步成功都落这份缓存），从没同步过才显示"去设置 › 模型管理 同步一次"。配了 Agent 模型时顶部挂 `ModelSheet.agentModelNotice` 同话术的提示（视觉 > Agent > 主模型，这里改主模型不生效）——**不静默骗人**。胶囊显示名走 `ChatView.composerModelLabel = resolveModel(hasImage: false)`（与灵动岛 `liveActivityModelName` 同口径），只读 `qingliao_model` 会在 Agent/视觉模型生效时报错模型（v3.8.0 实踩）
- **天气弹窗右上角补「刷新」胶囊**：`Text("刷新").pill(.page)` 排在「换城市」左侧（口径照生活页「刷新」，含 `loading` 时前置的 `ProgressView().controlSize(.small)`）。点击 = `reloadForce = true; reloadToken += 1`，即**绕过 v3.9.46 的天气缓存**强制回源。病根：缓存上线后"想看此刻"的出口只剩加载失败那张空态里的「重试」，正常态没有入口
- **登录页胶囊变窄**（用户："胶囊可以缩短"，追问确认为变窄不是变矮）：`LoginView.formH` 28 → 40，三枚输入框 / 登录 / Face ID / 两条状态横幅一并收进去，不再顶满屏宽（这个口径 v3.9.46 已收敛成一个常量，改一处即可）
- **滑动流畅性三处减负（需真机验收）**（用户："优化 app 滑动流畅性"）：全仓滚动热区排查后落三刀，都在"每帧/整页白干活"这一类，不动任何观感设计。
  ① **聊天页 `onScrollGeometryChange` 投影夹 0 + 取整**（`ChatView` 收件箱上拉那条）——这条回调**只在投影值变化时**才响，原先未过拉时返回逐帧变化的负 offset，等于**整个正常滚动过程每帧响一次、每帧写一次 `@Observable progress`**（`InboxPullState` 不做等值比较，写同值也标脏 `InboxPullLayer`，那层里还挂着一颗 `ultraThinMaterial` 胶囊）。改成 `overscroll <= 0 ? 0 : overscroll.rounded()`：正常滚动期投影恒 0 → 一次都不响；过拉本身只有 0~60pt 有意义，取整后拉满最多 60 次失效，指示器跟手位移看不出差别。`inboxPullHandleScroll` 另加一层"进度已归零且不在等回弹就早退"的兜底（`st.armed` 必须留在条件里，否则松手那一帧的触发动作被吃掉）
  ② **dock 智慧球的投影静态化**（`ChatEffects.SiriBallView`）——`.shadow(color: .indigo.opacity(0.45 * breathe))` 挂在一颗"每帧换色的渐变球"上，而此球 **5 个 tab 常驻**（空闲 15fps / 思考 30fps），任何一页滑动都在与它抢帧。阴影色改写死中值 0.22，呼吸感仍由外圈 halo + 球体两颗渐变圆承担，差的只是"投影不再脉动"。这与 v3.2.3 输入框那条同源：**把每帧变化的阴影静态化**（仓内 `repeatForever`/`TimelineView` 帧源已逐一核过，全部有帧率锁与 reduceMotion 静态档，没有裸 `.animation` 全屏帧源）　←　**本条已回滚（v3.9.49）**：真机结论是观感回退（球的气色掉了），
  阴影恢复 `0.45 * breathe` 脉动。这一刀的教训记下来：**这颗球的投影是观感的一部分，不是可牺牲的性能项**；
  要再动它得先给"滑动确实变差"的证据，别拿静态化阴影当免费午餐
  ③ **会话列表外层 `VStack` → `LazyVStack(alignment: .center)`**——内层 v2.0.133g 就为"会话多时全量渲染拖慢切页"改成了 LazyVStack，但它套在非懒 VStack 里等于白做：外层为定自己的尺寸向惰性子栈索取理想高，一问就把全部行实例化出来。**`alignment: .center` 不能省**（VStack 默认 center、LazyVStack 默认 leading，省了空态插画和 BotCard 会跑左边）。安全性依据 v2.0.56 那条老账：会话删除早已是"后端驱动 + `load()` 整体替换"，无就地 `removeAll` 的 ForEach diff 崩溃路径
- **本轮明确没动的**（都是"要用户拍板"的视觉账，不是代码账）：`dashboardCard()` 每卡两层柔影（v3.9.35 对比稿定稿）、设置页 `GlassListCard` 深色档逐行 `ultraThinMaterial`、Siri 边框光/灵动岛光 30fps（v3.9.1 拍板）、看板自动化卡 1Hz `TimelineView` 包整张 `DeviceCard`（1 秒一次，非帧级）。**要再压一档就得先接受观感回退**，说一声即可

## 🆕 近期变更（v3.9.47，2026-09-21）



- **弹窗里的卡片一律半透明毛玻璃（需真机验收）**（用户：「所有卡片不要白色背景，用毛玻璃，16 圆角」）：新增 `SheetFrostCard` / `.frostedCard()`（`Theme/LiquidGlass.swift`）= `.ultraThinMaterial` 底 + 16 圆角 + 0.8pt `Tint.line` 描边 + 两层柔影，**卡形与 `.dashboardCard()` 逐字同参，只把实色卡底换成真半透明材质**。改动三处：v3.9.46 五张详情弹窗的分组卡 / 设备行 / CPU·内存 hero 块（`DeviceDetailSheets.swift`），以及**开关弹窗的灯卡**——它是用户点名要对齐的「开关卡片形式」基准，不改它就没对齐可言（点亮态原先那层 `accent.opacity(Tint.subtle)` 淡染保留，叠在毛玻璃之上）。看板与生活页的**网格卡没动**，仍是 `dashboardCard()`
- **Dock 玻璃：方案 A 回退，改方案 B（需真机验收）**：v3.9.46 的 `.toolbarBackground(.hidden, for: .tabBar)` 真机只褪背景色、玻璃层照旧 → 两处调用删掉，`chatTab` 注释记下这个否定结论。新增 `Features/TabBarGlass.swift`：`TabBarGlassClearer(clear:)` 挂零尺寸探针 `TabBarGlassProbe` 在 **TabView 上（只挂一处）**，`selected == .chat` 时把真实 `UITabBar` 的 `standardAppearance`/`scrollEdgeAppearance` 换成 `configureWithTransparentBackground()` + `backgroundEffect = nil` 的副本，切走时**原样还原**（第一次改动前缓存系统原值；tab bar 被系统重建则重认重缓存）。`DockOrbOverlay.findTabBar(in:)` 由 `private` 开放为内部可见，不再各处抄一份递归
- 方案 B 的诚实边界：iOS 26 没承诺系统玻璃走 `UITabBarAppearance`，真机若仍在 → **止步于此**，不退回去铺不透明层（v3.4.29 红线），也不再追加第二轮赌注

## 🆕 近期变更（v3.9.46，2026-09-20）

- **看板卡片详情弹窗五连 + 弹窗样式统一**（用户点名 8~12 项）：门锁 / 各房间温度 / 猫眼 / CPU / 内存五张卡从"只读"变成可点，新建 `Features/Dashboard/DeviceDetailSheets.swift`。**零新增接口**：三个设备弹窗吃看板已在轮询的 `/api/ha/states`（新增 `lockEntities`/`doorbellEntities`/`roomTempEntities` 三个筛选切片），CPU/内存弹窗吃 `/api/nas/status` + `/api/hw/status`。「统一样式」落成代码：把 DisksSheet/HADeviceSheet/ServiceControlSheet/WeatherSheet 各自手抄的那套头部抽成 `BoardSheetHeader`（`Typography.title` bold + Spacer + 次级计数 + `xmark.circle.fill` 关闭钮 + 18/18/`Spacing.lg` 边距），新弹窗一律它 + `.dashboardCard()` 分组卡（**v3.9.47 已换成 `.frostedCard()`**） + `[.medium(,.large)]` detents + `matchedTransitionSource`/`.navigationTransition(.zoom)`，挂载仍走 `.sheet(item: $activeSheet)`。**CPU/内存弹窗只讲后端真有的数**：整机单值 cpu%、mem{total,used}、两个容器各自内存、CPU/SSD 温度——没有每核占用/负载均值/进程榜，就在脚注里写明白，不画假精度条
- **安防卡可点布防/撤防**：`requestArm` → `confirmationDialog`（危险动作既有方言，同「执行场景」）→ `applyArm` 走 `POST /api/ha/services/switch/turn_on|turn_off` + `entity_id`（Aqara 网关警戒模式本体是个 switch 实体）。**不做乐观更新**，成功后立即 `loadHA()` 回读真值；失败必须出声（`alarmError` → alert + `Haptics.error()`，v3.9.41「静默吞掉 HA 控制失败」的同款教训）；`alarmBusy` 吞在途连点；找不到 `guard_mode` 实体时卡片副标题直接写「未找到网关警戒开关」而不是骗人写「点击布防」。动态按钮单独抽成 `armDialogButtons`（塞进 body 大表达式撞过类型检查超时）
- **天气进程内缓存**（`WeatherCache`，`Core/WeatherService.swift`）：客户端原先零缓存，同一个 `/api/weather` 三条重复路径（看板切回首刷 / 弹窗每次打开 / 弹窗关闭同步城市名）。TTL 600s **刻意小于后端自己的 30min**，保证不会读到比后端更旧的数据；换城市（`saveCity`）与「重试」（`reloadForce`）显式作废该城条目，其他城市照旧秒开。弹窗命中缓存时连骨架屏都不闪
- **聊天页头部两枚胶囊尺寸统一**：思考档位与朗读原先各自手写「字号 + padding + `glassPillStroke`」，v3.9.43 已把 padding 对齐却仍差 1~2pt——**病根不是 padding 而是内容固有高度**（10pt 图标 + 11pt 文字 vs 光 11pt 图标，SF Symbol 行高≠文字行高）。新增 `chatHeaderPill()`（`Theme/Pill.swift`）把内容 `frame(height: 15)` 框死再套同一档 padding；它不属于 `PillSize` 三档「操作胶囊」口径，故单独一个方法而不是硬套 `.pill()`
- **修任务中心右上角空玻璃胶囊**：iOS 26 的 tab/toolbar 玻璃是系统自绘的，**空 `ToolbarItem` 依然会拿到一层玻璃底**——原来两个按钮写在同一个 `ToolbarItem` 的空 `HStack` 里，两个 `if` 都不成立时胶囊还在、字没了。改为把条件判定提到 `ToolbarItem` 外层（`@ToolbarContentBuilder` 支持 `if`），没有按钮就根本不产生 toolbar item
- **智慧球那一 tab 不铺玻璃（方案 A，需真机验收）** ← **真机结论：无效，v3.9.47 已回退**（用户：玻璃还在）：`.toolbarBackground(.hidden, for: .tabBar)` 挂在聊天页根内容上（两个分支都挂）= 只有这一页褪玻璃，其他 tab 照旧。两个未知数与退路写在 `DockTabView.chatTab` 注释里；**红线仍然有效**：不许在 TabView 下层铺不透明色（v3.9.46 之前 v3.4.29 的教训——会掐死所有页的滚动边缘折射）
- **登录页视觉美化**（接 v3.9.45 动效四件套）：背景补 SplashView 同款三团模糊光斑（蓝/靛/青，静态不放动，纯装饰 `allowsHitTesting(false)`）；logo 从 52pt 无底无影的扁符号升到 64pt + 背后主色光晕 + 蓝色投影，副标题 `tracking(1.2)`；主操作按钮补 `shadow(blue 0.32, r14, y7)`（成功态不投影）；**层级重排**——Face ID 保持淡底 + 同色细描边（次级），「测试连接」从一模一样的大胶囊降为纯文字小按钮（三级，原先两个按钮同样式互相抢视线）；错误与测试结果从裸 Text 换成 `LoginNotice` 状态横幅（淡底 + 同色图标 + 同色细描边，测试结果串自带的 ✅/⚠️/❌ 前缀剥掉由图标表态）；服务器历史下拉从 `secondarySystemBackground` 换成与输入框同款的 `ultraThinMaterial` + 细描边；三枚按钮 `.plain` → `PressStyle()` 补按压手感；5 处各写一遍的 `.padding(.horizontal, 28)` 收敛成 `Self.formH`
- **登录页两个功能缺口**：① 键盘 return 串联——`GlassField` 新增 `submitLabel` / `onSubmitAction`（**必须声明在 `focus` 之后**，现有调用点按位走成员初始化器），服务器→用户名→密码→`submitLogin()` 一条链；② 密码框加眼睛切换明文（原先全程盲打，输错只能靠失败抖动反推），`SecureField ↔ TextField` 是两个视图会掉焦点，切换后显式 `focus.wrappedValue = field` 抢回来

## 🆕 近期变更（v3.9.45，2026-09-20）

- **登录页动效四件套（需真机验收）**：① 进场递延——Splash 淡出后 8 段视图按 45ms 逐档上浮入位（`stagedIn`，原来整页同时硬现）；② 输入框焦点形变——`@FocusState<LoginField?>` 单选焦点，聚焦框描边走主色 + 图标点亮 + 一层极淡主色底 + 1.012 微放大（原来四个框长一个样，眼睛跟不上光标）；③ 发送键三态直出——空闲「登 录」/ 登录中环形进度 / 成功绿勾，`frame(height: 26)` 等高压掉换态跳动，成功时渐变转绿并轻微顶起，同时 `Haptics.success()`；④ 登录成功「卡片飞成首页」交接——整页上浮淡出 0.45s，DockTabView 在它下面就位（详见上方关键设计决策那条的挂载窗口）
- **登录失败不再静默**：`errorMessage` 一变即 `Haptics.error()` + 整列水平抖动一次（`keyframeAnimator` 一条 x 轨串五个关键帧 -9/8/-6/3/回弹，靠 trigger 计数触发，不用 sleep 对节拍）。背景色块不参与抖动，所以不会出现边缘漏白
- 四件套全部有静态档：`reduceMotion` 下递延直出满位、抖动 trigger 传 0、交接窗口不挂载（回到改动前的瞬间切换）

## 🆕 近期变更（v3.9.7，2026-09-12）

- **灵动岛 / 锁屏实时活动美化（方案 A+B 合并）**：A 视觉——轻聊球贯穿全部形态（`Canvas` + `TimelineView(.animation, minimumInterval: 1/20)` 呼吸；侧载免费签名无 APNs，唯一帧源是本地驱动）；B 信息与交互——思考脉冲环 → 输出**不确定态旋转弧**（不画假百分比）→ 完成绿对勾保持 2s 三态、展开态状态文案 + 「停止生成」按钮（`StopGenerationIntent` 用 `LiveActivityIntent`：在**主 App 进程**执行且**不打开 App**，才能真停掉 App 里的流；`openAppWhenRun` 已废弃且在 extension 里置 true 直接编译报错），点灵动岛 `.widgetURL(qingliao://chat)` 回聊天页（官方推荐方式，零新 API 风险）；`LiveActivityManager` 只在 phase 变化时 update（不跟 token 刷）+ 代际令牌 + 会话归属校验；脉冲环半径上限 `r×1.15` 防灵动岛遮罩切半圆
- **收件箱「进行中进度」气泡**（配合后端 v3.7.1，后端已上线）：`task_type="progress"` → 会话 🔔 进度气泡（`isPush=true` 故**不进模型上下文**、不弹本地通知、不进任务中心）；`pollOnce` 的「流式进行中跳过整轮」改为**只跳过 reply 类**——回前台立刻看到过程留痕，不再压到流结束才一起涌出
- **语音转文字态输入框去掉流光特效层**：只保留「发送键变收音图标」（撤销 v3.2.4「语音模式保留流光」的决定；顺带语音期间输入栏已无每帧重绘视图）

## 🆕 近期变更（v3.9.6，2026-09-12）

- **语音录音「实时上屏」根治**：v3.9.5 只把红色胶囊去掉、让输入框常显，实测录音全程仍只有「输入消息…」占位、松手才一次性出字 → v3.9.6 录音态**直接渲染 `liveSpeech.liveText`**（`@Published` 驱动，必然刷新）在输入栏同一行位置，并加 `.onChange(of: liveSpeech.liveText)` 同步进 `inputText`（不再依赖「闭包捕获的 @State 写入 + TextField 外部刷新」这两条不可靠路径）
- **诊断自证**：`LiveSpeechTranscriber` 统计 `volatileCount/finalCount/firstResultMs`，录音 3s 仍零结果才置 `liveStalled` → 输入栏仅在此时显示 `V0/F0` 小字（正常时零杂物，异常时一眼看出「实时结果没到」）
- **后端 ASR 整体下线**：`asr_api.py` + `unified_router` 的 `/api/asr`、`/r/asr` + `stream_api._proxy_asr`/relay 白名单 + nginx 三份 conf 的 `location /api/asr` + compose/.env 的 `QL_ASR_*` + 引擎（whisper_venv 431M、whisper_models 142M、asr_server.py、scripts/asr）全部清除；App/PWA 已 grep 确认零引用

## 🆕 近期变更（v3.9.5，2026-09-12）

- **语音录音态 UI 修正（用户实测反馈）**：录音中不再用红色「正在聆听…」胶囊**整块顶掉输入框**——那样既看不见输入框、也看不见转写全文（长句还被单行截断）→ 改为**输入框全程常显**，设备端识别结果（`liveSpeech.onTextChange`）实时落进框里，边说边看
- 仅保留左侧 **7pt 红点**作「正在听」标识；录音中给输入框加 `.allowsHitTesting(false)`，防误触弹键盘打断语音模式
- 清理已无用的 `recordingText` 参数与 `ChatView` 传参（实时文本改由 `inputText` 直接承载）

## 🆕 近期变更（v3.9.4，2026-09-11）

- **修「一按语音转文字就闪退」**（v3.9.3 引入的回归，用户报 `Signal(5)`）：设备端转写的 `LiveSpeechTranscriber.start()` 是 `@MainActor`，其中 `installTap` 的闭包字面量**继承 MainActor 隔离**，而麦克风 tap 在**音频线程**回调 ⇒ 进闭包即 Swift 6 隔离断言 SIGTRAP。用 v3.9.3 的 dSYM 符号化定案（崩溃帧就是这个闭包），修复=闭包显式 `@Sendable`；`requestRecordPermission` 回调一并补 `@Sendable`
- **这类错编译器零告警、`check_swift.sh`(-parse) 查不出**（同族首例 = v3.7.0 剪贴板闪退）：判据是「查 Apple 文档 JSON 该形参有没有 @Sendable」，没有就必须显式 `@Sendable` 或改官方 async 桥接；`@preconcurrency` conformance ≠ 安全（只是把断言推迟到运行时）
- **按钮统一「文字 + 胶囊」去图标**：刷新 15 处（看板生活数据/资讯/空态、Docker 容器与镜像、路由器面板、诊断、日志、云端设置、本地模型、视觉模型、执行历史、模型管理导航栏）、重新生成 2 处、添加/添加股票 5 处；长按菜单项与纯「+」图标入口保持原样
- **AI 头像**：去掉蓝色渐变底圆；玻璃球半径 `uniforms[4]` 由上游默认 `0.72` 提到 `0.98`（球径≈头像格，与原来底圆尺寸对齐），30pt 消息头像 / 38pt 思考头像 / 96pt 欢迎页 logo 同步生效
- **通知 delegate 加固**：`UNUserNotificationCenterDelegate` 协议非 @MainActor 且无线程承诺，原 `@preconcurrency` 只是把隔离断言推迟到运行时 → witness 标 `nonisolated`（方法体只碰 UserDefaults，行为零变化）
- 只读并发隔离审计扫全仓 102 个 .swift（逐条比对 Apple 文档 JSON）：除上述外无第二处必崩代码

## 🆕 近期变更（v3.9.3，2026-09-11）

- **语音转文字改 iOS 设备端实时转写**（用户拍板「不需要后端了，只用苹果系统自身」）：iOS 26 `SpeechAnalyzer` + `SpeechTranscriber`，**边说边出字**（`.volatileResults`）、音频不出设备、可离线、无时长上限；新增 `Core/LiveSpeechTranscriber.swift`；语音模型走 `AssetInventory` 按需下载（不占 App 体积，**首次使用要等下载数十秒**）
- **删掉旧链路**：`Core/VoiceRecorder.swift`（录音 m4a）+ `AuthStore.asrTranscribe`（上传后端 `/api/asr/transcribe`）整条下线，App 启动时一次性清理历史遗留 `voice_asr_*.m4a`；**云端模式放开语音入口**（v3.0.4 的屏蔽撤销，本地/云端共用同一条路径）
- **权限**：`project.yml` 补 `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription`（此前一个都没有）；Speech 框架**不需要任何 entitlement**，历史「侧载无语音 entitlement 必闪退」系权限串缺失的误判；CI Verify 加断言「两个权限串必须真进包」
- **接入要点（真机首次必撞的坑，均已处理）**：`SpeechTranscriber` 有硬件要求 → 先查 `isAvailable`/`supportedLocales` 是否为空（不支持要明确提示，别拿 en-US 兜底去初始化）；准备期（下模型/权限弹窗）**不可重入**（一个 bus 只能挂一个 tap，二次 `installTap` 抛异常）、点 × 必须真取消（原来 cancel 在准备期是空操作）；**录音态必须显示实时文本**（原来整块被「红点+松开上屏」替换，边说边出字用户一个字都看不见）；结果流中断要自愈且 `CancellationError` 不误报「转写中断」；`Analyzer` 不做音频转换（converter 为 nil 且格式不符时必须丢弃 buffer）
- 与 v3.9.1/v3.9.2 攒的改动一起出包：AI 头像换 siri 液态玻璃球（思考中动 / 不思考静态）、UI 打磨 5 批（动效令牌/zoom 转场/滚动层次/字号 8 档/骨架屏）、性能省电 4 项、剪贴板误报修复

## 🆕 近期变更（v3.8.0，2026-09-11）

- **灵动岛 / 锁屏实时活动**：AI 回复中在灵动岛显示（紧凑态图标 + 计时；展开态会话名 +「AI 正在回复 · 模型名」+ 计时），结束自动收起。新增 `QingliaoWidget` app-extension target（**项目首个 widget extension**）+ `LiveActivityManager`（本地驱动，不依赖 APNs）
- **设置开关**：设置 → 外观 → 交互 →「灵动岛实时活动」（默认开）。关掉立即收回正在显示的活动；启动时会清理上一进程遗留的活动（防"锁屏一直挂着、计时还在跑"）
- **侧载安装提示**：装这版前先在 SideStore → Advanced → User Customizations 打开 **Customize App Extensions**（否则新挂件会被当"多余扩展"静默删除），弹窗选 **Keep App Extensions (Use Main Profile)**（不额外注册 App ID，不占 10 个/7 天额度）
- **发版链路加强**：CI Verify 新增 `.appex` 精确路径 + `NSExtensionPointIdentifier` + `NSSupportsLiveActivities` 校验；版本号从 4 处变 **8 处**

## 🆕 近期变更（v3.0.27，2026-08-21）

- **⑧长文目录/大纲导航**：MarkdownRenderer 提取标题生成目录，ChatView 新增 TOC Sheet，长对话可快速跳转到指定章节
- **⑨会话文件夹/标签**：CategoryStore + SessionsView 分类菜单，会话支持按文件夹分组管理
- **⑦图片持久化**：ChatStore.uploadImage 将图片上传到服务器，云端对话图片不再丢失
- **⑩用量统计**：CloudDashboardView 新增 UsageStatsCard 显示消息/Token/会话数
- **Dock胶囊高亮修复**：DockTabView ultraThinMaterial 改用 View modifier（Shape 方法在 iOS 27 不生效）
- **ChatView底部间距补回**：v3.0.24 丢失的底部 76pt padding 已恢复

## 🆕 近期变更（v3.0.20~26，2026-08-20~21）

- **视觉模型配置（v3.0.21）**：CloudConfig 新增视觉模型 UserDefaults 存储 + VisionModelSheet 选择弹窗；ChatStore 自动切换视觉模型（主模型支持视觉→用主模型；不支持→用配置视觉模型；未配置→降级文本）
- **看板重构（v3.0.20）**：卡片统一 dashboardCard() 修饰符；空态折叠；SettingsView 拆分 500 行 body → 8 个 @ViewBuilder + 共用组件；模型层格式化搬到 NASStatus/NASDisk
- **统一弹窗风格**：所有设置弹窗统一 NavigationStack + toolbar 完成按钮，移除手动 header + xmark
- **v3.0.22 cherry-pick**：ServerSheet URL/端口校验、主题切换过渡动画、hwCpuText/hwSsdText 预格式化、exportMarkdown 导出、txt/md/pdf 三选导出菜单
- **v3.0.25**：视觉模型配置移入模型管理弹窗 + 微信通道视觉模型
- **v3.0.26**：DockTabView @Environment 转义修复

## 🆕 近期变更（v3.0.19，2026-08-20）

- **⭐ 语音指令闭环**：长按智能球从"语音转文字"改为**语音指令**——按住说话"打开客厅灯"→ 松手自动识别 → 直接执行（不确认）→ TTS 播报结果（"客厅灯已打开"）。工具类指令播结果、闲聊播回复摘要；执行中球转圈；语音指令消息带 🎤 标记；**输入框内语音按钮保留原"语音转文字"功能**（两条入口独立）。云端模式新增 **control_ha**（灯/空调/开关控制：toggle/turn_on/turn_off/设温度/切模式，按设备名自动匹配实体）和 **control_docker**（容器启停/重启）两个工具，写操作走确认弹窗
- **⭐ 微信窗通道模型设置**：本地 AI 设置 →「连接与模型」新增"微信窗通道模型"——可为 **Hermes 微信通道单独选择模型**（模型列表与模型管理一致），设置后重启 gateway 生效，**只影响微信通道，其他通道不受影响**。实现：独立 wechat-profile + profile_routes 路由 + 后端 channel API（9152）
- **限流友好提示**：本地模式流式中途遇到 429/tpm exhausted（sensenova 等免费额度爆了）时，消息内直接提示"额度限流，请到模型管理换 provider 路由"，不再只显示裸错误

## 🆕 近期变更（v3.0.18，2026-08-20）

- **AI 消息"字挤小框"彻底根治**：v3.0.17 只把**流式中**的 AI 长文改成 SwiftUI Text 渲染（落库后切回 UITextView 仍复现锁窄 bug）——v3.0.18 AI 消息**全程**（含落库后）用 SwiftUI Text 渲染，长按菜单改用 contextMenu 提供（复制/引用/分享/大爆炸/重新生成/删除），`.textSelection(.enabled)` 保系统原生选词复制；用户消息保持 UITextView（短文本无此问题）
- **云端模式流式气泡统一**：云端直连（SSE）流式输出改用 `stream.content` 驱动 streamingBubble——粒子头像 + SwiftUI Text 渲染与本地模式完全一致；流中报错直接显示错误消息不再留残留气泡
- **思考期头像改为彩色粒子球**：AI 思考中（三点动画旁）的 bot 头像从静态图标改为粒子球（38pt 蓝紫粉白四色），与输出中粒子球头像全程一致
- **⭐ 云端 AI 本地工具调用（function calling）**：云端模式对话中模型可调用手机本地工具并自动执行——**日历建事件 / 提醒事项 / 计时器 / 天气 / 剪贴板 / 计算器 / 本地通知** 7 个工具（纯 App 内闭环，不经 NAS 后端）。说"明天下午3点提醒我开会"→ 模型调 create_reminder → 确认弹窗 → 提醒创建。日历/提醒/计时器写操作弹确认框，查询类直接执行；工具执行卡片显示在气泡上方；最多 3 轮工具循环防死循环；设置页"本地工具"开关可关
- **看板新增设备一键体检**：NAS 面板下方新增"设备体检"卡（六维诊断：服务/磁盘/容器/负载/内存/温度）——点击一键体检，完成显示等级（良好/留意/异常）+ 明细列表（状态色点 + 建议），可展开收起/重新体检；后端 `/api/nas/diagnose` 聚合 15 项诊断（阈值：磁盘 80/90、负载 0.5/1.0 核、内存 25/15%、CPU 温度 70/80、SSD 65）

## 🆕 近期变更（v2.0.139，2026-08-18）

- **特效全面减负（第三轮性能优化）**：①粒子爆发 160→120 颗、光晕大圆只对半数粒子绘制，每帧绘制调用 320→~180（-44%）；②输入框流光 60→30fps（流式回复时重绘开销减半）；③球呼吸外发光 blur 8→6、光晕 88→84pt（blur 开销随半径超线性下降）。视觉密度几乎无差，卡顿进一步消除

## 🆕 近期变更（v2.0.138，2026-08-18）

- **移除圆环波纹特效**：点智能球的"圈圈放大扩散"波纹在 60fps 下持续全屏放大插值仍卡顿（v2.0.135 改 Core Animation 隐式动画后依旧），按用户要求直接移除波纹层，只保留彩色粒子爆发——特效更轻，不再有卡顿感

## 🆕 近期变更（v2.0.137，2026-08-18）

- **粒子爆发冲灵动岛**：点智能球的烟花粒子不再只在下半屏——粒子提速（480-950）提寿命（0.9-1.45s）+ 重力下拉减到 25pt，最大飞行距离约 826pt 能直冲屏幕顶部灵动岛；向上粒子占比 92%、扇形收窄更集中朝上
- **智能球下沉贴近 Dock**：球态底部间距 26→40pt（球底距 Dock 顶约 12pt），爆发原点同步跟随球心，烟花/波纹从新球心散开

## 🆕 近期变更（v2.0.135，2026-08-18）

- **圆环波纹卡顿修复**：点智能球的"圆环波一圈圈向外扩"特效不再卡——波纹原在 Canvas 里每帧全屏重绘（3 个大椭圆描边），改为 Core Animation 隐式动画（GPU 合成、零逐帧重绘），粒子层保留 Canvas 160 颗；视觉效果不变（3 层错相循环扩散 + 淡出）
- **键盘收回修复**：键盘打开时点聊天区任意空白即可收回（此前只有点居中 logo 才收）——根因是收键盘手势挂在无 contentShape 的透明容器上，空白处不可命中，且 ScrollView 区域点击不冒泡；修复：消息区补 contentShape + ScrollView 自身挂收键盘手势 + 输入栏消费点击不误收

## 🆕 近期变更（v2.0.134，2026-08-17）

- **粒子纯烟花效果**：去掉末段闪烁与十字星芒，只保留满天烟花粒子（160 颗，先快后慢 + 1.2s 平滑淡出）
- **粒子 Canvas 性能再优化**：单位圆 Path 复用（原每帧 320 次对象分配 → 1 次）+ 特效层锁 60fps——粒子动画不再拖慢点球展开
- **键盘衔接优化**：弹键盘顺延到展开动画完成之后（0.4s，完全串行不抢帧）+ 输入框贴键盘动画跟随系统键盘时长/曲线——点球到打字全程平滑无跳变

## 🆕 近期变更（v2.0.133，2026-08-17）

- **智能球动效性能优化**：删局部 BurstEffect（与全屏特效重叠）+ 去掉 blurReplace 过渡（最吃 GPU 的离屏模糊）+ 展开动画 0.5s→0.35s + 键盘弹出顺延 0.28s——点球展开不再掉帧，键盘衔接更顺
- **智能球呼吸降帧率**：常驻呼吸动画 60fps→30fps（肉眼无差，常驻开销减半）
- **粒子放烟花效果**：160 颗粒子 + 速度放缓（先快后慢的爆开轨迹）+ 寿命延至 1.2s + 末段星辰闪烁淡出——点击智能球像烟花绽放、满天星辰

## 🆕 近期变更（v2.0.132，2026-08-17）

- **模型管理同步补拉 opencode**：同步按钮拉取 Go 订阅全部 26 个模型（原硬编码 7 个），显示名映射 + 本地兜底 + UserDefaults 持久化
- **智能球满屏粒子爆发（v2.0.132）**：点击球瞬间 Canvas 90 粒全屏散开 + 超大波纹 + 十字星芒（0.95s 自动消失，Siri 蓝紫粉配色）
- **智能球语音激活反馈**：长按进语音 → 球变珊瑚红渐变 + 呼吸加速 + waveform 波形图标（替代原小红点）——视觉一眼可辨进入语音输入
- **长聊天记录流畅性**：消息列表 VStack → LazyVStack（仅渲染可见气泡，长文本滑动/左右切页不再卡）；SELECTABLETEXTLABEL 内容指纹跳过重复 layoutIfNeeded
- **智能建议主动生成**：进看板无建议时自动生成一次 + 30 分钟本地缓存（轮询/重启不重复生成），不用再手动点
- **执行历史管理**：滑动单条删除 + 编辑模式多选/全选删除 + 全部清除（后端新增 DELETE /api/history，含存量数据 id 兼容）
- **设置页文案**：「Siri 圆球输入」改名「智能球」

## 🆕 近期变更（v2.0.125，2026-08-16，回滚后重建）

- **v2.0.125**：聊天文字长按菜单新增「选择文本」（v2.0.120 基础上重建；v2.0.122-124 被另一模型改坏已回滚，备份分支 `backup-v2.0.124-20260816`）
  - 新文件 `SelectableTextLabel.swift`：文字渲染 Text → UITextView 包装（isSelectable），长按弹原生编辑菜单：复制/引用/分享/大爆炸/**选择文本**/重新生成/撤回/删除
  - 点「选择文本」→ 选中手按位置的词（tokenizer.rangeEnclosingPosition）+ 原生拖动手柄，可自由拖动复制
  - **⚠️ iOS 26+ 双 API 必须都实现**：新 `textView(_:editMenuForTextInRanges:)`（ranges 为 [NSValue] 包装 UITextRange，取首个转 UITextRange）+ 旧 `editMenuForTextIn`，共用 buildMenu；只实现旧 API 则 iOS 27 自定义菜单全丢（v2.0.123 坑）
  - **⚠️ 选中文字用标准 `selectedTextRange`（UITextRange 版）**：iOS 26 弃用的是 UITextView.selectedRange（NSRange 版），selectedTextRange 未弃用；v2.0.124 误信"selectedTextRange 弃用"改 selectedRanges NSRange 换算 → 改坏根源
  - **⚠️ 气泡级 contextMenu 必须移除**：抢占 UITextView 长按手势致编辑菜单弹不出（v2.0.122 实测）；菜单按区域分发——文字区 UITextView 菜单 / 图片与文件卡片 `cardMenu` / 代码块与表格 `MessageBlockView` 内 SwiftUI 菜单
  - AI 回复行距缩小：markdown 段 lineSpacing 3→2（用户要求"行跟行中间太宽"，字号不变）
  - 设置页 9 处开关统一绿底小号（`tint(.green)` + `scaleEffect(0.8)`）
  - **蜂窝 relay 3.5KB 限制自动分段**（用户实测粘贴长文本被裁）：`sendCore` 发送前用 `relayPayloadLength`（模拟 base64url URL 长度）预判，超 3400 自动 `splitLongText` 二分拆段；第一段先发，后续段 queued 入队（流式/非流式顺序均正确，递归不再触发分段）；`startStream` 蜂窝下 `relaySafeHistory` 从后往前保留历史至 payload 达标——长文本不再被裁，AI 逐段收到完整内容
- **v2.0.127（修复 125 实测 bug）**：
  - **🚨🚨 长按菜单全丢根因（v2.0.124/125 都栽在这）**：iOS 26 全面转向 NSRange 体系（`selectedRanges: [NSRange]`、UITextField 新 API 直接 `[NSRange]`），`editMenuForTextInRanges` 的 `ranges: [NSValue]` 包装的是 **NSRange**——必须 `rangeValue` 取；124/125 用 `nonretainedObjectValue as? UITextRange` 转换必然失败 → 返回 nil → **Apple 文档：返回 nil = 显示系统默认菜单**（自定义项全丢、长按直接变文本选择）。修复：`rangeValue` 取 NSRange（兼容 UITextRange 双分支），"选择文本"用 iOS 26 新属性 `textView.selectedRanges = [range]`，旧 API `editMenuForTextIn` 直接删除（部署目标 26.0 永不调用）
  - AI 回复行距再缩小：lineSpacing 2→1（用户实测 UITextView 渲染视觉比 SwiftUI Text 宽，数值需更小）
- **v2.0.128**：
  - **AI 直接发图**：AI 回复中的 markdown 图片语法 `![alt](url)` 自动解析为图片块（`MessageContentBlock.image`），气泡内渲染圆角图（240 上限，与用户图片一致），点击打开大图查看器（含流式中可点）
    - ⚠️ **自签证书双通道加载**（用户 NAS 就是自签）：URLSession 加载外部公开图，失败降级 `StreamHTTPClient`（忽略证书链校验）——纯 AsyncImage 会因自签证书必失败
    - 远程图片 NSCache 缓存（`cachedRemoteImage`，40MB，滚动复用不重复下载）；data URL 复用 `dataURLImage`
    - 折叠消息（>800字）预览中图片语法替换为 `[图片]` 占位
    - 能力边界：Hermes/后端回复含 markdown 图片 URL 即显示；生图工具未接（NAS 无 GPU）
  - **设置页 AI 输出行高滑条**：`@AppStorage("qingliao_ai_line_spacing")` 0-6 步进 0.5 默认 1.0（字体大小滑条同款交互，indigo 图标），AI markdown/折叠消息实时生效
- **v2.0.129**：
  - **Siri 圆球输入**（用户深夜设计，默认开，设置开关 `qingliao_ball_input`）
    - 默认状态聊天输入区 = Siri 多彩光晕圆球（TimelineView + AngularGradient 蓝紫粉呼吸，复用 Siri 发光配色）
    - **单击球** → spring 动画展开成完整输入框（文字/附件/拍照/发送功能与原来一致）+ 自动弹键盘
    - **长按球** → 语音转文字（球保持特效不展开输入框）；录音中红圈脉冲"松开结束"，转写中转圈，**转写完成自动展开输入框 + 弹键盘**（用户细节③）
    - 展开态保留直到切换会话（`.id(chat.sessionId)` 重建复位回球，用户细节②）；转写中点击球不响应
    - ⚠️ 手势 ExclusiveGesture(LongPress, Tap) 互斥（v2.0.98 SIGTRAP 教训，勿叠加 onTap+onLongPress）
    - 球态居中，独立渲染（不继承输入栏胶囊背景）；`SiriBallView` 组件独立
- **v2.0.130**：
  - **修复 AI 长消息文字截断断句**（用户截图实测：气泡底部最后一行只显示一半）：根因 = SwiftUI 用 intrinsicContentSize 布局时宽度未定，UITextView 按单行算高度 → 多行被裁；`SelectableTextLabel` 实现 `sizeThatFits(_:uiView:context:)` 用提案宽度精确计算换行高度，宽度钳制到气泡最大宽（屏幕-60）防 `.infinity` 提案再次单行
  - **修复行高滑条不生效**：AI 消息行距改为 UserDefaults 直读（`lineSpacingFromSettings`，不依赖 SwiftUI 参数传递时机），主显示 + 折叠消息两处同步
  - **圆球放大**：主体 44→**72pt**（= 首页"你好，我是轻聊"Logo 同尺寸），外光晕 52→88，整体 56→92，录音红圈同步 92
  - **球中心样式**（用户指定）：默认态 mic 图标 → **录音圆形 logo 声呐波纹**（3 层圆环 120° 相位差扩散 + 中心白点白光晕，动效+光晕）；录音中红点+松开结束 11pt；转写中转圈 24pt

## 🔀 分支与版本

- `feature/handoff-301`：**当前默认分支**，3.9.x 的开发与发版线
- `native-3.0`：3.0 早期主线，已停更（不再是默认分支，勿再作为发版基线）
- `native-2.0`：2.0 历史冻结（终版 tag `v2.0.140`）；旧 `master` 本地残留可忽略（勿 push）
- 版本演进记录在提交信息（v2.0.87bn 起每提交带版本后缀）；发版 tag = `v3.9.x` 递增，`project.yml` 的 build 号（`CFBundleVersion`/`CURRENT_PROJECT_VERSION`）同步 +1
- 仓库为 public：**任何提交不得包含真实服务器域名/公网 IP/内网 IP/密码/token**（此前已做全历史脱敏，v2.0.52-54；新引入敏感信息即泄露）

## 📁 仓库外运维（宿主本机，不在 git）

- `/opt/data/qingliao_icon/`：`watch_ci_v2034.py`（轮询 CI → 下载 artifact，改 RUN_ID/EXPECT_SHA 后运行）、`ship_ipa.py`（paramiko 转存 IPA 到交付目录，stdin base64 管道 + md5 校验）、`sync_app_dir.py`；**脚本目录可能被系统清理，丢失从会话历史重建**
- 后端（自部署 Python 服务）与完整开发经验沉淀在 Hermes 技能 `qingliao-ios-native` / `qingliao-webui`（改后端前必读）
