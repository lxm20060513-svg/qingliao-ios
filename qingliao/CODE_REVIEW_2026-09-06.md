# 轻聊 iOS 全面 Code Review（2026-09-06）

> 3 并行子代理分模块审查（Core/Chat/Settings·Dashboard·Features），69 Swift 文件 / 2.2 万行。
> 纯只读审查，未改文件。统计：**0 紧急 / 6 高 / 18 中 / 26 低**。
> 同日已实施：Agent 智能回复开关移除（commit 6a9700c）+ 看板 eMMC 系统盘数据打通。
>
> **✅ 修复状态（2026-09-06 晚）：50/50 全部修复。**
> 主修复批次 commit `1d6181d`（33 文件 +680/-434）+ 补漏 `4623f17`（AuthStore remember=false Keychain）。
> 验证：swiftc -parse 全量通过 + CI macOS 编译预检 success（run 34034745716）。
> 待真机回归重点：流式滚底/撤回即时刷新/图片上传 NAS/新会话首条消息。


## 1. Core 层

### 🔴 高（4）

- 【ChatStore.swift:562-565,597-600】高：WiFi 图片上传主机错误——uploadImage/uploadImageChunked 用 CloudConfig.shared.activeConfig.baseURL（云端大模型厂商，如 api.deepseek.com/v1，CloudConfig.swift:112-118 本地模式无配置时也 seed DeepSeek）拼接 NAS 专属端点 /api/files/upload，而 ChatView.swift:1295 注释明言"上传 NAS 换 URL"；结果 WiFi 图片持久化恒打到错误主机静默失败（fallback base64），且第 569 行把 NAS 的 X-Auth-Token 发给了第三方云厂商（token 泄露面）；蜂窝分片路径(auth.request 走 NAS)却主机正确——同一功能两个目标主机自相矛盾。修复：改用 auth.serverURL 拼 NAS 端点（对照 AuthStore.uploadMultipart），cloud 模式按需另走图床。

- 【SafariRelay.swift:131-166】高：relay 请求可永久挂起——runASWAS 的 timeout 参数自始至终未被使用（函数体 138-165 行无任何超时逻辑）；session.start() 返回值未检查（163 行），start 失败时回调永不会触发 → continuation 永不 resume；且 activeSession 已置位但 releaseRelaySlot 只在回调里调用 → 后续所有排队请求（relayQueue）被永久堵死；Task 取消也不传播（无 onTermination/cancel 钩子），蜂窝主路径（登录/轮询/发送）全部依赖 relay 时= 网络层停摆。修复：start() 返回 false 立即 resume 错误并释放队列；加定时器超时后 session.cancel() + resume；用 withTaskCancellationHandler 传播取消。

- 【LocalToolRunner.swift:224-227,252,258-259,303】高：日历/提醒时间时区错误——ISO8601DateFormatter（224-227 行缓存实例未设 timeZone）默认按 GMT 解析，而注释与 schema 均声明"本地时间，无时区"且示例正是 "2026-08-21T15:00:00"（242 行）；模型按示例输出时被解析成 UTC 15:00 → UTC+8 用户实际日程/提醒建在当天 23:00，偏移 8 小时（只有带空格/无秒的格式才会落到 timeZone=.current 的 parseFlexibleDate 而碰巧正确）。修复：设 iso8601.timeZone = .current，或解析顺序改成先 flexible 后 ISO。

- 【VoiceRecorder.swift:59-71】高：start() 返回契约错误——AVAudioRecorder.record() 返回 false（无麦克风权限/会话配置失败）时，else 分支（66-70 行）只置标志，随后第 71 行仍无条件 return true；调用方 ChatViewVoice.swift:101 依赖返回值区分"录音已启动"与"麦克风失败"（失败走 voiceAuthFailed 提示），导致无权限时 UI 照常进入语音模式但实际没在录音、松手无文件。修复：record() == false 时 return false（与 catch 分支一致）。


### 🟡 中（7）

- 【AuthStore.swift:221-226】中：401 全量伪装 200 吞错——除登录接口外所有 401 都被包装成 statusCode=200 的假响应返回（224 行构造 fakeResp），连真正的 token 过期/被吊销 401 也一并吞掉，调用方永远无法触发重新登录（配套 APIError.unauthorized 573 行 case 全仓零构造点=死代码），并把 401 错误体当成功 JSON 交给 json()/jsonArray() 上层解析 → 缺键静默 no-op 或误报 badJSON。修复：改为按具体路径/仅 GET 状态类白名单降级，鉴权与写接口的 401 正常抛错并触发重登。

- 【ChatStore.swift:224-225 vs 249-259】中：注释与实现不符——historyPayload 注释称"只保留最后一条带图消息的 imageDataURL（前面已发过的图片不进 payload，防 base64 全量重复膨胀）"，但实现是逐条 m.asPayload()（92-106 行）无条件带上每条消息的 imageDataURL，没有任何"仅最后一张"的过滤 → 多图历史每次发送都携带全部 base64，payload 膨胀（与注释声称要防的问题正相反）。修复：按注释语义只保留最后一条带图消息的 data URL，其余降级为文本/[图片]占位。

- 【StreamHTTPClient.swift:46,199-211】中：不支持 chunked 传输编码——请求按 HTTP/1.1 发送（46 行），但 isResponseComplete 只认 Content-Length：遇到无 CL 的响应（nginx/gunicorn 对上游无 CL 会自动转 chunked）永不判完成，只能等 EOF（靠 Connection: close），EOF 后 handleEOF(390-399) 把带 chunk 帧（十六进制长度行+CRLF）的原始体当 body 返回 → JSON 解析失败/数据错乱，表现为偶发坏响应。修复：解析 Transfer-Encoding: chunked 按块长度累积，或对无 CL 响应在 EOF 后剥离 chunk 帧再解析。

- 【CloudSessionStore.swift:85-107】中：主线程全量序列化+同步磁盘写——persist() 是 @MainActor 同步方法，每次 upsert 都 JSONSerialization(prettyPrinted) 全量 sessions + data.write(.atomic) 落盘，且云模式消息 v3.4.x 起保留 imageDataURL(base64)（ChatStore.swift:306-317 每条消息后 500ms debounce 都会触发）→ 会话多/含大图时主线程卡顿，文件反复全量写放大 I/O。修复：encode/写盘移到后台（快照后 Task.detached 或串行队列），并考虑增量/节流合并写。

- 【AuthStore.swift:158-162】中：login 无视 remember 参数——remember=false（用户明确不记住登录）时，只要 FaceID 开关为默认开，密码仍写入 Keychain(FaceIDStore.save)，与"不记住"意图相悖（凭据跨启动常驻）。修复：remember=false 时不写 FaceIDStore，或 UI 上把 FaceID 开关与 remember 联动。

- 【Models.swift:283-284】中：死代码/空实现——NASStatus.hwCpuText/hwSsdText 恒返回 ""，注释称"硬件温度预格式化搬到模型层"但全仓（Features/Dashboard 等）无任何调用点，若 UI 曾依赖则温度展示被静默掏空。修复：删除或补全实现并接回调用方。

- 【NotificationHelper.swift:26-27】中：通知去重 identifier 用 String.hashValue——hashValue 带进程随机种子，跨启动相同 body 生成的 identifier 不同（"相同内容替换不堆叠"只在同进程内成立，App 重启后推送仍会堆叠）；且 abs(hash) 在 hash==Int.min 时崩溃（经典 abs 溢出 trap）。修复：用稳定哈希（如 ChatStore.stableHash 同款 djb2）并去掉 abs。


### 🟢 低（9）

- 【ChatMessage id / Models.swift:53-55】低：id 由 role+content 哈希+timestamp 拼成，timestamp 为 nil（旧数据/parse 缺字段）或同毫秒重复内容时两条消息 id 相同 → ForEach 重复 id（SwiftUI 未定义行为/渲染异常）且 Equatable(id 相等) 把不同消息判为同一条，影响去重与删除定位。修复：id 加 UUID 兜底或计入序号。

- 【StreamClient.swift:243-254 vs 274-287】低：杀后台恢复内容缺口——persistState 把 content 截断到 4096 字符但 offset 存的是完整值；restoreIfNeeded 恢复时用 4096 截断内容 + 真实 offset 续轮询 → 超过 4096 字的长回复恢复后正文中段（4096..offset）永久缺失（仅当后续 recover 成功时才被覆盖修复）。修复：持久化时同步截断 offset，或存完整内容分片/恢复后强制 recover 对齐。

- 【ImageCache.swift:97-103】低：remoteCacheKey 只取 URL.path——同 path 不同 query（如缩略尺寸 ?w=100 vs ?w=800、版本参数）及不同 host 的资源会共用缓存条目串图；且去 query 的本意（token/时间戳）与"query 决定内容"的服务器冲突。修复：key 改为 host+path+白名单 query 或按内容协商头区分。

- 【ImageCache.swift:9-10 vs 34-50】低：注释与实现不符——文件头注释称"base64 解码放到后台队列避免大图片阻塞主线程"，但同步版 dataURLImage 对 ≥100KB 大图仍在主线程 UIImage(data:) 解码（43-50 行），后台解码只在另一入口 asyncDataURLImage；37/46 行对已被 initImageCacheLimit 初始化过的 totalCostLimit 重复判 0 设置属冗余。修复：统一入口或修正注释/引导调用方。

- 【AuthStore.swift:224,230-231】低：构造假响应用 URL(string: serverURL + path)! 强解包——虽因能收到响应意味着 URL 先前可解析、实际崩溃面很小，但属无谓强解包，未来路径含特殊字符即崩。修复：与 directHTTP 一致用 guard + APIError.badURL。

- 【AuthStore.swift:573-590】低：死代码枚举 case——APIError.unauthorized 与 .timeout 全仓无构造点（401 被 221-226 行吞掉、超时统一走 timeoutDetail/badResponse），errorDescription 分支永不执行。修复：删除或恢复真实触发路径。

- 【SpeechRecognizer.swift】低：文件名与内容不符——SFSpeechRecognizer 已移除（注释自述），文件内实为朗读管理器 SpeechManager(AVSpeechSynthesizer+TTS)，与"SpeechRecognizer"文件名/头注释完全脱节，检索语音识别代码会误入此文件。修复：重命名为 SpeechManager.swift。

- 【Models.swift:59-83 / ChatMessage.parse】低：parse 对 content 数组形态只拼 text、image 只留"[图片]"占位（68-73 行），v3.4.x 起 imageDataURL 独立字段可恢复 URL 但旧数据/多模态 content 里的 image_url 变体（type=image_url 带 url 的块）仍丢图。修复：image_url 块解析 url 写入 imageDataURL。

- 【CloudConfig.swift:107-119】低：init 在本地(local)模式也强制 seed 一个 DeepSeek 空配置并置 activeProviderID="deepseek"（112-118 行），导致本地模式 activeConfig 恒指向云端厂商（与 uploadImage 主机错误叠加放大误导）；无云配置的本地用户 isConfigured/activeConfig 语义失真。修复：仅在 mode==.cloud 或用户进入云配置页时 seed。


## 2. Chat 层

### 🔴 高（2）

- 【ChatViewExport.swift:8-13 + ChatView.swift:241-247/1043-1049】高｜就地元素修改不触发可见消息缓存刷新，撤回 UI 永不更新。visibleMessagesCache 仅在 chat.messages.count 变化、displayLimit 变化、.task 首跑三处重建（ChatView.swift:1043-1049、1066-1068），而 withdrawMessage 走 chat.messages[idx].withdrawn=true（ChatViewExport.swift:10），count 不变 → 缓存里的 MessageRowItem 仍是 withdrawn=false 的 struct 快照（ChatView.swift:244-246），ForEach(visibleMessagesCache) 渲染出的气泡（ChatMessageBubble.swift:148 判 message.withdrawn）永远显示原文；同族问题还有 sendQueued/clearPendingQueue 置 queued=false（ChatView.swift:1665/1674-1676）不会即时去掉「排队中」角标。修复：把缓存失效条件从『count 变化』扩为『messages 内容指纹变化』（如 onChange(of: chat.messages.map(\.id))），或撤回/queued 修改后显式调 refreshVisibleMessages()。

- 【ChatView.swift:225-247/1007-1019/1043-1049】高｜新建会话或会话装载经过『空态/卸载态』后，首条消息错显旧会话内容。两步走清空流程先切欢迎页卸载 ScrollView（clearing=true，886 行）再清 messages，此时挂在 ScrollView 上的 onChange(of: chat.messages.count)（1043 行）随视图卸载而失效；清空后旧会话的行仍留在 visibleMessagesCache。新会话用户发送第 1 条消息时 count 0→1 使列表重新挂载，onChange 捕获初始值 1 不触发 → ForEach 直接渲染上一会话的缓存行（旧会话内容闪现、用户自己的消息不可见），直到下一条 append/assistant 落库触发 count 变化才被 refreshVisibleMessages 纠正。ChatStore.load(_:)（ChatStore.swift:57-63）整组替换 messages 且新旧会话消息数相同时同样漏刷新。修复：refreshVisibleMessages 同时在 onChange(of: chat.sessionId) 与消息数组整体替换时调用（当前该 onChange 只做清队列，且挂在会随欢迎页卸载的 ScrollView 上，应上提到 ZStack 层）。


### 🟡 中（3）

- 【ChatMessageBubble.swift:169-177 + 92-99（对照 65 行注释）】中｜流式输出每帧对『整段累积文本』全量 markdown 解析 + AttributedString 转换 + 排版，O(n²) 且与注释矛盾。streaming 分支无条件走 Text(cachedRenderText(text))，cachedRenderText 按 text.hashValue|fontSize 判键，流式每 delta 文本不同 → 每帧全量 MarkdownRenderer 解析整个已输出文本；65 行注释称『流式跳过 markdown 解析/纯 Text 渲染』与实现不符（streaming 只让 blocks() 跳过分块，没跳解析）；>6000 字静态文本有 UITextView 兜底（189-211 行）但流式长文无兜底。云模式有 50ms 节流（ChatView.swift:1477-1483），本地模式无节流，长回复尾部卡顿风险。修复：流式中改为直接 Text(纯文本) 或只解析新增增量/限制流式渲染长度，并给本地模式流式 content 更新加同样的时间节流。

- 【ChatView.swift:1050-1052 + 1206-1214】中｜流式中每次 stream.content 变化都无条件 withAnimation scrollTo 底部，无『用户是否已上翻/是否贴底』判断。用户在 AI 回答期间上翻阅读历史会被下一个 delta 强制拽回底部，无法并行阅读；且每个 delta 重启 0.15s 动画，高频 delta 下动画互相打断。修复：用已接入的 onScrollGeometryChange 记录是否贴底（pinned），仅当 pinned 时才自动滚底，并去掉 scrollBottom 内层动画或加节流。

- 【ChatViewExport.swift:59-65】中｜deleteMessage 按 timestamp+role+content 三元组匹配而非按 msg.id 删除，内容相同时可能删错消息。证据：相同内容可合法存在多条——蜂窝分段的同文队列消息（ChatView.swift:1330-1336）、用户重复发送同一句话；同一毫秒内 append 的两条相同文本 timestamp 相同 → firstIndex 命中最早那条而非用户长按的那条，且 62 行 pendingQueue.removeAll 也按内容把同文排队项一并清掉。同文件 retryMessage/regenerate 均按 id 操作，仅此处不一致。修复：直接 firstIndex(where: { $0.id == msg.id })。


### 🟢 低（7）

- 【ChatViewVoice.swift:71-75】低｜转写失败 catch 分支先置 transcribing=false 再校验 transcribeToken 代次，与成功分支（61-62 行先 guard 后复位）顺序相反。旧代次 Task 网络失败时会把新一轮正在进行的转写动画提前关掉（新 Task 仍真在转写，UI 已显示可发送）。修复：catch 内把 guard token == transcribeToken else { return } 提到 transcribing=false 之前。

- 【ChatView.swift:1073-1074 + 1816-1834 + 1549-1560 + 1076-1079 + 986-989】低｜ChatView 残留多处死代码：①1073-1074 空 if 分支（Bot 列表加载已删，只剩空壳）；②1816 attachButton 全文件无调用（实际用 DealAttachmentButton/menuButton）；③1549 cloudUpsertDelta 无调用（若误启用还会丢掉 agent/audioPath 等字段重建消息）；④1076 ModelSheet sheet 无任何置 showModelSheet=true 的入口（ChatView 内死 sheet）；⑤986-989 每帧向 ScrollOffsetKey 写 preference，但全工程无 onPreferenceChange 消费方（v3.4.1 换 onScrollGeometryChange 后遗留，白做每帧 geometry 上报）。建议逐一删除或补接线。

- 【ChatView.swift:315】低｜confirmationDialog 里『上下文：约 N tokens · M 条』做成空 action Button，点击无任何效果（纯信息行不应是可交互按钮，且该行本可并入 dialog 的 message）。修复：移除该 Button 或改为不可交互视图。

- 【ChatMessageBubble.swift:408-424】低｜代码块拆分假设 fence 严格成对（components(separatedBy: "") + i%2==1 判代码块）：AI 输出含单个不配对 （或行内以  开头未闭合）时，其后的整段 markdown 会被整体当作代码块渲染（丢排版、等宽黑底）。修复：逐行计数 fence 状态（splitParagraphs 已用 inFence 思路），异常时不配对则按原文处理。

- 【ChatView.swift:609-614 + 1946-1974】低｜『长文目录』sheet 的 TOCItem 行不是按钮、无 onTap/scrollTo 动作，点击无任何反应——注释宣称『大纲导航』实为纯静态列表。修复：给每行接点击，把目标消息 id/行号回传给 ChatView 执行 scrollTo（需让 extractHeaders 返回的 lineIndex 关联到具体消息）。

- 【CameraPicker.swift:9-14】低｜未做 UIImagePickerController.isSourceTypeAvailable(.camera) 检查；在无摄像头设备（iPad 侧栏模式仍走 ChatView 入口）或模拟器上 sourceType=.camera 会抛 NSInvalidArgumentException。修复：present 前检查可用性，不可用时 fallback 提示或改走相册。

- 【ChatView.swift:1086-1099 / 1104-1117 / 1269-1280】低｜同一段『pendingSend 解包 → 清输入框/图片 → persistImageIfNeeded → sendCore』逻辑在长上下文弹窗两个按钮与自动压缩完成后重复 3 份（历史遗留拷贝），后续改动极易只改一处导致三处行为分叉（如清空时机、错误处理）。修复：抽成一个 sendPendingNow(_ p: (text,imageData)) 方法统一调用。


## 3. Settings/Dashboard/Features 层

### 🟡 中（8）

- 【Features/Settings/VisionModelSheet.swift:68,124,213,219,339】中 字符串转义多打一层反斜杠（共6处，实测为双反斜杠 `\(` 与 `\n`）：L68 主模型行显示字面 `\(mainModel)`（不插值）、L124 空态不换行、L213 statusText、L219 sharedVisionDisplay、L339 保存成功提示均把占位文本原样显示给用户。修复：去掉一层转义，改为 `\(mainModel)` / `\n`。

- 【Features/Settings/SettingsViewSections.swift:218-246（+SettingsView.swift:28,83 +SettingsViewHelpers.swift:87-103）】中 死代码分支：`if showAppearanceOptions` 整段（深浅色 chips、输入框流光、Siri 发光+4滑条、AI 输出行高、智能球）永不显示——showAppearanceOptions 全仓库唯一写点 SettingsViewHelpers.swift:90 只置 false、从不置 true；L216-217 点「外观」实际打开的是 showAppearance 的 AppearanceSheet。本地设置页形成不可达双实现，与云端 AppearanceSheet 各维护一套样式/默认值。修复：删除 L218-246 死块及相关状态与 appearanceOption() 辅助函数，统一走 AppearanceSheet。

- 【Features/Settings/CloudSettingsView.swift:238-242 + 262】中 @AppStorage 默认值 vs UserDefaults 直读不一致（维度3）：appearanceSummary 用 `UserDefaults.standard.bool(forKey: "qingliao_ball_input")`（缺省 false），而消费方 ChatInputBar.swift:32 与 AppearanceSheet L262 @AppStorage 默认均 true——全新安装摘要行显示「输入框」，实际智能球已开启，UI 自相矛盾。修复：摘要改用与消费方同源的 @AppStorage 读取。

- 【Features/Settings/CloudSettingsView.swift:268（AppearanceSheet）+ SettingsView.swift:67】中 输入流光开关默认值与应用门控不一致（维度3）：设置页 @AppStorage("qingliao_input_glow") 默认 true（开关显示「开」），生效门控 ChatInputBar.swift:252 用 UserDefaults bool 无默认值（false）→ 全新安装显示开但效果不触发，需拨动一次才对齐。修复：门控改 @AppStorage 默认 true 或设置默认统一为 false。

- 【Features/Settings/SettingsModelSheets.swift:144-157（对比 CloudSettingsView.swift:47-64）】中 免费模型开关双实现行为分叉：ModelSheet 顶部开关（本地设置与 ChatView.swift:1077 模型管理共用，云端也会用到）ON 不写 qingliao_cloud_free_prev、OFF 不恢复 prev/activeProviderID；云端设置卡才有完整 prev 逻辑。云端经 ModelSheet 关闭免费档后 activeProviderID 仍停在 opencode-free → 显示关、请求仍走免费档。修复：抽公共 enableFreeModel(Bool) 供两处开关复用。

- 【Features/Settings/SettingsViewSections.swift:59-104 + SettingsViewHelpers.swift:44-54】中 本地模型开关 UI 与后端状态脱钩：Toggle 绑定 AppStorage qingliao_local_model，loadLocalStatus() 只改文字不回写开关；后端启动失败/超时时开关保持 ON 而文字显示「已停止（点开关开启）」；反向进入（容器在跑、开关未开）同样矛盾。修复：依据 /api/local/status 的 container 状态回写开关、失败回滚。

- 【Features/Dashboard/DockTabView.swift:83-93】中 通知直达会话深链仅查 NAS /api/sessions/list，未按 isCloudMode 分支：云端会话存 CloudSessionStore（本地），sid 必然找不到且会向 auth.serverURL 发无谓请求——云端点通知无法直达会话。修复：cloud 分支从 CloudSessionStore.shared.sessions 查找并 chat.load。

- 【Features/Settings/VisionModelSheet.swift:122-126】中 空态判定漏 opencodeAppleModels/stepfunModels/sensenovaModels 三个源（只判 deepseek+local+allProviders）：只同步过这三者之一时，界面同时显示「暂无可用模型…」与实际模型列表。修复：空态条件补齐全部模型源。


### 🟢 低（10）

- 【Features/Settings/SettingsView.swift:23,37】低 死状态变量：pinPathEdit、haAddress 声明后全仓库无任何读写点。修复：删除。

- 【Features/Dashboard/CloudDashboardView.swift:154,189】低 死状态变量：totalMessages 赋值后从未被读取（StatCell 只用 sessionCount）。修复：删除。

- 【Features/Dashboard/CloudDashboardView.swift:117-147】低 死代码：WeatherBadge.icon(for:)/color(for:) 静态方法无任何调用点。修复：删除或由实例方法复用。

- 【Features/Settings/SettingsView.swift:69】低 潜在默认值错位：siriGlowOn @AppStorage 默认 true，而全局门控 QingliaoApp.swift:147 与 AppearanceSheet（CloudSettingsView.swift:259）默认均 false（该声明目前只服务死代码，复活即错位）。修复：统一默认 false。

- 【Features/Settings/CloudLoginView.swift:226 + CloudSettingsView.swift:209-213】低 CloudProviderSheet 的 existing 参数从未使用（无编辑已有厂商能力），「添加/编辑厂商」名不副实，只能删除重建。修复：去掉参数或实现编辑。

- 【Features/Settings/HistorySheet.swift:146-152】低 滑动删除乐观移除无回滚：deleteRows 先本地 remove 再发 DELETE，失败静默，条目本次会话消失、重进恢复，与同文件其余删除（后端列表驱动）不一致。修复：失败恢复并提示。

- 【Features/Settings/SettingsSheets.swift:22-23】低 ServerSheet 校验按 ':' split 且限 ≤2 段，IPv6 字面量地址（fe80::1:8123）被误拒。修复：冒号多于 1 段时按 IPv6 处理。

- 【Core/BigBangParser.swift:28-29】低 tokenizer 创建失败的降级路径按 UTF-16 码元切分，emoji 等代理对被拆成两个孤立码元显示乱码（仅异常兜底路径）。修复：改用 unicodeScalars 遍历。

- 【Features/Auth/LoginView.swift:206-211】低 Face ID 快捷登录服务器比对为字符串级 `server.trimmed != cred.server`，未归一化 scheme/大小写/尾斜杠，格式略异即误报「服务器地址不一致」阻断一键登录。修复：归一化后比对。

- 【Features/Settings/SettingsModelSheets.swift:415-417】低 onAppear 中 ModelProvidersCache.load() 调用了两次（判空一次+赋值一次）。修复：缓存到局部变量。
