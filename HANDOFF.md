# 轻聊 App 项目交接文档

> 最后更新：2026-09-13
> 📖 **新接手先读 [RUNBOOK.md](RUNBOOK.md)** —— 5 分钟上手：统一入口 `ql.py`、三条主流程（发版/改后端/排查）、13 条硬约束、高频坑。本文件只留最近 3 版与待办。
> 最新版本：**v3.9.14/459（2026-09-13 已出包，tag `v3.9.14`，CI run #497 success，commit `413d2f4`）语音「边说边出字」修复 + 工具卡答完收起 + 录音态动效**：①**语音实时出字修复（本轮重点）**——用户报「按住说话录音中一个字都不上屏，必须点空白处退出才出字」。诊断串自证音频链路正常（`T21/D0/Y21` = 麦克风 21 次回调 / 0 丢弃 / 21 次全部投递 analyzer），拼接与发布逻辑也正确（`publish()` = baseline + finalized + volatile）→ 根因是**缺 `.fastResults`**：Apple 官方 `SpeechTranscriber.Preset` 对照表写明 `progressiveTranscription`（官方描述 "immediate transcription of live audio"）= `volatileResults` **+** `fastResults`，而 `transcription` / `transcriptionWithAlternatives` 两者皆 No —— 即「允许被替换的中间结果」与「更快地吐结果」是**两个独立开关**，只开 volatile 时识别器仍按默认节奏攒上下文、到收尾（finalize）才一次性给结果，与 v3.9.5 实测记录「录音中只有占位、松手才出字」完全吻合。⚠️ 属**基于官方文档的修复**，本机无 iOS 设备/SDK，需装机确认。②**录音态观感**——诊断串撤出正常录音态（v3.9.9 起「录音期间始终显示」会让输入框被 `V0/F0 T21/D0/Y21` 占住、看起来像文字被挡），收窄为只在 `liveStalled`（录音满 3s 零结果）时以 9pt 小字贴着显示；红点改脉动（新增 `PulsingRecordDot`：只对小圆做 scale/opacity，无 shadow、无每帧渐变，不碰 v3.2.3 渲染红线）；录音态发送键 waveform 改 `.symbolEffect(.variableColor.iterative, options: .repeating)` 持续波动（拆 if/else，避免两个 symbolEffect 的类型推断冲突）；无字时给人话占位「正在听…」/「没听清，靠近麦克风再说一次」。③**工具进度卡答完收起**——生成中逐条展开、答完折叠成一行「⚙️ N 步工具调用」+ 点开看明细、新一轮开始自动收回默认（原来 `toolNames` 只在切会话/发下一条才清 → 答完一直摊在对话里占地方）；摘要行抽成独立 struct `ToolStepsSummaryRow`（防 CI type-check 超时）。④`project.yml` 8 处版本号 3.9.13/458 → 3.9.14/459（SideStore 同名覆盖不生效，必须递增）。**验证**：`check_swift.sh` 全绿 + 工具卡同构真值表 **20 项全绿**（`/opt/data/scripts/ql_toolcards/truth_table_collapse.swift`：会话门控、新一轮重置端到端四步、报错图标语义）。**IPA 已校验 3.9.14/459**（主 App 与挂件 appex 版本逐字一致 + 扩展点 widgetkit-extension + NSSupportsLiveActivities + default.metallib + zip 结构 OK），md5 `58688eec2366110044b349ef31b7473e`（2,984,415 bytes），已转存 NAS `轻聊app/qingliao-3.9.14-unsigned.ipa`（NAS 侧 md5 回读一致）。**遗留待办**：语音诊断上报通路 —— 后端 `data/diag/reports.jsonl` 里 `voice` 记录为 0（52 条全是 crash），即「零结果时自动上报」没落到后端；若新包仍不出字，先修这条通路拿运行时数据（`firstResultMs`/locale/fmt）。
> 上一版：**v3.9.13/458（2026-09-13 已出包，tag `v3.9.13`，CI run #496 success〔首次 #495 失败于 Archive：`switch must be exhaustive` — 给 `MessageContentBlock.Kind` 加 `.file` 后`blockPlainText` 的 switch 漏分支；本机 check_swift.sh 只查语法，这类只有编译器知道〕，commit `ed2b37d`）灵动岛动效根治 + 工具进度卡 + 生成物预览 + 备忘录升级（8 个提交一版走完）**：①**灵动岛球/环动效根治**——用户报「球动几下就不动了」，四条叠加原因（保底步长在 20pt 环上只有 0.38pt/拍、progress 到 0.86 封顶即 return、thinking 阶段没起推手、挂件把动画放进 `TimelineView` 而实时活动无连续帧源）；修法=线性可见步长 + `ContentState.spin` 累计相位（不回绕）+ thinking||streaming 全程推手 + Canvas 只留静态球体。三轮只读审查各抓真缺陷并修（首 token 到达时新旧推手互斥→场上再无推手、切会话切回永久冻住、spin 回绕反向急扫、脉冲相位耦合错），真值表 52 条全绿。②**进度环再收小**——真机反馈「环左边碰到摄像头」：紧凑 20→16、展开 28→24，柔光外扩 0.18→0.10、占位 +6→+4（环的肉眼边界 = size + 描边 + 柔光；灵动岛是三段布局「球|传感器|环」，环越大左缘越顶中段，所以三处一起收而不是只改数字）。③**⑥ 对话内工具进度卡**——后端 `/api/stream/{taskId}` 带 `toolNames/lastTool/toolSeq`（后端已翻中文，App 不维护第二份映射表）；App 侧 `streamPoll` 返回 7 元组、`StreamClient` 透传（写入放在旧代 generation guard 之后）、`ChatView` 新增 `ToolStepRow` + `@ViewBuilder toolStepCards`（按 `currentStreamSessionId` 收窄防跨会话残留），真值表 27 项。④**⑧ AI 生成物 App 内预览**——后端 `/api/stream/media` 放开 pdf/md/csv/txt/json/log + `Content-Disposition`（**刻意不放开 .html/.svg**：免鉴权端点暴露可执行类型=自开 XSS 面）；App 侧 `MEDIA:` 按扩展名分流，文档走新 `AIFileCard` + `.quickLookPreview`（QuickLook 只吃本地文件 → 先下载到临时目录 + 文件名净化去 `/` `:`），真值表 27 项。⑤**备忘录体验升级**——可编辑（`MemoStore.update` 早有方法却一直没有 UI 入口）、置顶、相对时间（刚刚/今天/昨天/M月d日）、便签化卡片（0.8pt 描边与全站口径一致）、折叠（默认 3 条 + 「全部 N 条」）、来源改图标、空态改可点引导、**一键发给 AI**（复用任务中心「发送到当前会话」机制 + DockTabView 切回聊天页）。⑥**备忘录审查修复**——🔴 程序化切 tab 漏 `skipBurstOnce()`（v3.6.2 修过的烟花回归）；🟠 `loadLocal()` 解码策略与 `save()` 的 `.iso8601` 不一致 → 本地兜底从来就是失效的（每次冷启动为空；且「读失败 + 写成功」窄窗口下新增一条会把只含新条目的数组写回 NAS 覆盖其余备忘）→ `PinStore` 同款复制粘贴 bug 一并修；🟠 发备忘前没停朗读；🟡 详情页「来源·来源·时间」重复、编辑后本地时间与存储分叉、编辑态手滑丢草稿。真值表 39 项全绿（含旧 JSON 兼容、编辑不回滚、编解码对称性）。⑦ HANDOFF 同步。**IPA 已校验 3.9.13/458**（主 App 与挂件 appex 版本逐字一致 + 扩展点 + NSSupportsLiveActivities + default.metallib），md5 `396486ecac88093ba54b8c4aff07d6b3`（2,974,589 bytes），已转存 NAS `轻聊app/qingliao-3.9.13-unsigned.ipa`（NAS 侧 md5 回读一致）。**后端同期改动（已上线，不随发版）**：v3.9.14（recover 磁盘兜底 `done` 不再硬编码 true / 清理不再按 mtime 误删在跑任务 / 记忆损坏留档）、v3.9.15（任务中心卡片显示「第 N 步 + 工具名」，**旧版 App 即受益**）、v3.9.16（`/api/stream/{taskId}` 带工具字段）、v3.9.17（媒体服务扩展类型），备份链 `stream_api.py.bak-v3914~v3917` 可回滚；并补上任务中心「任务/通知」分区的生产者（Hermes cron 输出 → 轻聊 inbox 投递器 `/opt/data/scripts/ql_task_push.py`，job `b324f4400e2a`，每分钟）。**⑦ 危险确认闸门已按用户要求彻底移除**（App 代码已摘除 / Hermes 插件已删 / 后端 confirm_api 与两条路由已清，带 token 验证 5 个端点全 404）。
> 上一版：**v3.9.12/457（2026-09-12 已出包，tag `v3.9.12`，CI run 34704360596 success，commit `21cf473`）灵动岛尺寸定稿（球加大、环收小，主次分明）**：真机反馈「环太大了」+「球反而小了」——v3.9.11 曾把环做成与球等大，但环带描边 + 柔光，同尺寸时观感比球更重，像环压过球。按形态分别定档（单位 pt，直径）——**球**：紧凑 22→25→**27**、极简 20→22→**24**、展开 34→36→**36**、锁屏 38→42→**46**；**环**：紧凑 13→25→**20**、展开 16→36→**28**、锁屏 16→42→**33**（极简态无环）。规则：**展开态的球保持 36 不动**（那一行即灵动岛传感器区，可用高度约 36.67pt，再大会被圆角遮罩切上下边）；环统一收成球的约 **7–8 成**（球为主：品牌 + 阶段色；环为辅：本轮推进度）——带描边 + 柔光的环在同直径下视觉重量大于实心球，用户说「环要跟球一样大」时按 7 成落地并说明理由，别机械等大。本版只改尺寸常量与对应注释、无逻辑改动，`./check_swift.sh` 全绿（153 项 / exit 0）。IPA 已校验 **3.9.12/457**，md5 `8890138fc33730d18e606e7bf66598bc`（2,929,235 bytes），已转存 NAS `轻聊app/qingliao-3.9.12-unsigned.ipa` 并已发微信。
> 上一版：**v3.9.11/456（2026-09-12 已出包，tag `v3.9.11`，CI run 34703271024 success，commit `26a9b15`）灵动岛进度环持续推进 + 环/球同尺寸 + 设置页卡顿与诊断修复收口**：①**灵动岛「更活」（用户拍板：不要加计时，靠进度环推进）**——`ContentState` 新增 `progress`（语义=**本轮推进度**，不是总进度承诺）：思考 0.18 → 进入生成 0.35 → `LiveActivityManager.progressTicker` 每 1.5s 往前挪（>20 拍后 4s，指数逼近 0.86）→ 真结束才 1.0；推手生命周期线程安全（生成阶段启动，`finish`/`end`/换会话/关开关都停；代际 token 防「自我退出不清句柄 → 再也起不来」）；环与同形态的球**同尺寸**（紧凑 25/25、展开 36/36、锁屏 42/42）；思考脉冲外扩 1.15→1.08（按 r=size/2×0.86 算，1.08 时最大外径≈0.98×size，落在自身 frame 内；38 会顶到展开态顶行约 36.67pt 的传感器区被遮罩切边，故定 36）；计时维持「不显示」（v3.9.9 用户要求）。②**发版前双审查（diff + 全仓同类）**抓到并修掉：BLOCKER 同会话第二轮起进度环恒满格且推手空转（新一轮判定漏了「上一轮刚收尾 pendingDismissal」与「阶段 done|streaming→thinking」两条路径，`lastProgress` 还留着上一轮 `finish()` 落的 1.0，且新值在 `end()/clearState()` 复位之前算出、随后又被写回，复位等于白做 → 引入 `freshRound` + `baseProgress` 天花 0.86/思考下限 0.18 + 写回时机修正）；HIGH `finish()` 在代际校验之前改共享状态（600ms 等待窗口里新一轮会被写坏）；MEDIUM 切到别的会话时 `finish()` 提前 return → 该轮推手没有任何取消路径、一路空转到饱和；MEDIUM 推手自我退出不清句柄；LOW 到顶后 `continue` 造成活死循环；顺带修 `LiveSpeechTranscriber` 在「麦克风不可用/取消」早退时不 teardown（音频会话留在 `.record` 激活态 → 麦克风不释放、之后 TTS 无声，本仓记过的老坑）与 `SpeechManager` 的 zh-CN 兜底音色未进缓存。③验证：`./check_swift.sh` 全绿（153 项）+ 决策真值表 26 条（`/opt/data/scripts/qingliao_island/truth_table_progress.swift`，含「同会话第二轮不得满格」回归用例，本机可跑不依赖 Xcode）。IPA 已校验 **3.9.11/456**，md5 `a68cd2f927c39319ad4c5e88e6119c6d`（2,929,226 bytes），已转存 NAS `轻聊app/qingliao-3.9.11-unsigned.ipa`。
> 上一版：**v3.9.10/455（2026-09-12 已出包，tag `v3.9.10`，CI run 34701059842 success〔重发；首次 34700865462 failure〕，commit `4d0b921`）修 3.9.9 设置页主线程卡顿 + 诊断模块 17 条缺陷 + 灵动岛进度环**：①**卡顿根治**（用户真机报 7 条 3.2~6.7 秒卡顿，用 CI run 34697305974 的 dSYM 符号化钉死）——根因是 v3.9.9 把「系统音色列表」写成 SwiftUI 计算属性 → 每次 body 求值都调 `AVSpeechSynthesisVoice.speechVoices()`，该调用进 TextToSpeech 并被无障碍层 `axUnsafeForcedSync` 串行化同步等待 → 主线程卡 3~7 秒、界面「点不动」；修法：`SpeechManager` 音色目录改**后台线程枚举一次 + 缓存**（`SpeechVoiceOption` 纯 String 快照，文件作用域声明以避开 Swift 6 嵌套类型隔离推断）、`resolvedSystemVoice()` 只读缓存、音色对象按 id 缓存、新增 `voiceCatalog() async` 幂等入口；`SettingsModelSheets.voiceOptions` 改 `@State` + `onAppear` 异步取（body 里零 AVFoundation 调用）；`QingliaoApp` 启动预热一次 + 启动采集环境快照（此前不采集 → env 长期 `.unknown`）。②**诊断模块**：用户报「待上报数量都是 0」——查明不是采集坏了（记录后即时上报成功即出队，服务端 receivedAt 与事件同秒），顺带修 17 条缺陷。IPA 已校验 **3.9.10/455**，md5 `c15afd7a17124c15174e89450acc1cf3`（2,924,647 bytes），已转存 NAS `轻聊app/qingliao-3.9.10-unsigned.ipa`。
> 上一版：**v3.9.9/454（2026-09-12 已出包，tag `v3.9.9` 重发 3 次〔34696431368 failure / 34697104360 failure / **34697305974 success**〕，末次 commit `edb8e48`）语音转文字实时上屏根治 + 自动朗读触发源重做 + TTS 音色/语速 + 灵动岛亮起修复**：①**语音转文字「说话时不出字、点空白才一次性出字」根治**——音频 tap 回调的 buffer 改为**自持拷贝**再投 analyzer（回调返回后音频引擎会复用那块内存，analyzer 异步消费读到的是被覆盖的音频——Apple 文档点名的「缓冲有、UI 正常、却永远没有文字」）；采集顺序对齐官方示例（先 `analyzer.start(inputSequence:)` 再装 tap/起引擎）；转换失败/空输出/拷贝失败各自计数 + 首个原因，不再静默丢弃；新增三级计数 T/D/Y 每秒刷新（录音期间常显）+ `liveStalled` 有结果即复位；零中间结果的会话自动上报后端诊断便于事后取证。②**自动朗读**：触发源从「末条消息 id 变化」改为 `ChatStore` 落库 token（`assistantLandedToken` + `lastLandedAssistantUID`），只在**真正 append/insert 一条 assistant 回复**时自增——修 BLOCKER「切会话/冷启动会念刚打开会话的历史旧答案」、修「AI 回答中用户再发消息时本轮回复插在数组中段 → 原信号不变 → 永不朗读」、删消息/重新生成截断不再误触发；朗读对象改为「刚落库的那条」（按 uid 取）；抑制标记只在真正要念时消费（原来被生成期进度气泡吃掉 → 停止后的残句仍被念出来）；去重键改非可选 `uid ?? id`。③**TTS 音色**：自动朗读跟随设置「AI 语音朗读」开关；系统语音新增可调音色（优先 premium > enhanced > 默认，列表带「优质/增强/标准」标记）+ 语速三档；设置页在关闭神经 TTS 时显示「系统音色/语速」并引导下载增强/优质语音包。④**灵动岛「只在开关切换那次生效、第二次不亮」修复**：活动判断改为只看 `activityState == .active`（`end()` 之后已结束的活动仍在列表里闪现 → 按它判断就会去 update 一条已结束的活动 → 新活动永远建不出来）；`end()` 之后再确认一拍；`clearState()` 补清 `lastTitle/lastModel`（残留会让「内容没变」误命中）。⑤**灵动岛取消计时文字**（用户要求）→ 改阶段图标（思考/生成/完成）+ `contentTransition` 过渡。⑥其他：header 朗读胶囊只留图标、待发队列 key 提升为 `UserDefaultsKey.pendingQueue`、注释与实现对齐。**CI 三轮顺序揭示**：`sending 'activity' risks causing data races` 4 处（为「只认在显示的活动」加的静态计算属性返回 `[Activity]`，属 `@MainActor` 隔离上下文 → Apple nonisolated 的 `Activity.activities` 取出的值被「过一手」变成隔离值 → 送进 nonisolated async 的 `update/end` 即违规）→ 改 `hasActiveActivity` 返回 `Bool` + 真正要操作 `Activity` 本体的地方在使用点**直接**取；另两次 CI 失败分别是 `DiagnosticsPayload.makeEvent` 上报路径与 `phaseBadge` 参数标签。IPA 已校验 **3.9.9/454**，md5 `8163d2dd8d37c144e5f68c18079183d7`（2,897,362 bytes），已转存 NAS `轻聊app/qingliao-3.9.9-unsigned.ipa`。
> 上一版：**v3.9.8/453（2026-09-12 已出包，tag `v3.9.8`，CI run 34693812959 success，commit `8d7d4a8`）朗读胶囊开关 + 灵动岛停止入口收口 + 进度推送闸门收窄**：①`Header` 新增**「朗读」胶囊开关**（`@AppStorage qingliao_auto_read_reply`，默认关）：开 = AI 每轮回复结束自动朗读、关 = 不自动念（气泡上朗读按钮仍可手动）；走 `SpeechManager` 现成双引擎（系统 `AVSpeechSynthesizer` 默认，设置里开了大模型 TTS 才走后端神经音色）；新一轮开始先停上一轮朗读；**跳过推送气泡（isPush）与错误占位，只念真正的 AI 回答**。②**灵动岛「停止生成」补齐清队列那一半**（`LiveActivityActionBridge` 进程内通知）：原来只调 `stream.stop()`，漏掉 `clearPendingQueue()` → 点了停止，排队消息还会自己发出去；`StopGenerationIntent.perform()` 加 `@MainActor`（NotificationCenter 同步投递，防后台线程改 SwiftUI 状态）。③`InboxStore` 闸门收窄成**只放行 progress**（cron/system 仍等流结束再消费，避免流式期间被顺带消费 + 弹通知）。④`LiveActivityManager.finish()` 代际校验前置、活动列表空则放弃本轮（防重复建第二条活动）；挂件动画断言改正（实时活动无连续自走帧源，改为静态帧设计 + 依赖 update 过渡）。IPA 已校验 **3.9.8/453**，md5 `fbe11720fd8d961050d35f3b22bf4cb4`（2,878,362 bytes），已转存 NAS `轻聊app/qingliao-3.9.8-unsigned.ipa`。
> 上一版：**v3.9.7/452（2026-09-12 已出包，tag `v3.9.7`，CI run 484 success 一次过，commit `781d472`）灵动岛实时活动美化 A+B + 收件箱「进行中进度」气泡 + 语音态输入框去流光**：①**灵动岛/锁屏实时活动美化（攒着的方案 A+B，本批首次进 CI，一轮即过）**——A 视觉：轻聊球贯穿全部形态（`Canvas` + `TimelineView(.animation, minimumInterval: 1/20)` 呼吸；侧载无 APNs，唯一帧源是本地驱动，App 挂起即静止）；B 信息与交互：思考脉冲环 → 输出**不确定态旋转弧**（不画假百分比）→ 完成绿对勾保持 2s，展开态状态行 + 「停止生成」按钮 + 点岛回会话。三处 API 决策：**`LiveActivityIntent`**（在主 App 进程执行、不打开 App，故能真停掉 App 里的流；`openAppWhenRun` 已废弃且在 extension 里置 true 直接编译报错）、**`.widgetURL(qingliao://chat)`** 回会话（官方推荐、零新 API 风险；`DockTabView` 加 host 分支）、`LiveActivityManager` **只在 phase 变化时 update**（不跟每个 token 刷）+ 代际令牌 + 会话归属校验（防跨会话误收/进程被杀留残留）；脉冲环半径上限 `r×1.15`（防灵动岛遮罩切半圆）；`orbGradient` 由 `static let` 改计算属性（Swift 6 严格并发下静态存储要求 Sendable）。②**收件箱「进行中进度」气泡**（配合后端 v3.7.1，后端已上线并验证）：`task_type="progress"` → 会话 🔔 进度气泡（`isPush=true` 故**不进模型上下文**、不弹通知、不进任务中心）；`pollOnce` 的「流式进行中跳过整轮」改为**只跳过 reply 类**，回前台立刻看到过程留痕。③**语音转文字态输入框移除流光特效层**，只保留「发送键变收音图标」（撤销 v3.2.4 语音流光决定；语音期间输入栏已无每帧重绘视图）。IPA 已校验 **3.9.7/452**（主 App 与挂件 `.appex` 版本逐字一致 + `NSSupportsLiveActivities` + `default.metallib` 齐），md5 `570f341026666698338843409c98a1e2`（2,873,578 bytes），已转存 NAS `轻聊app/qingliao-3.9.7-unsigned.ipa`（NAS 侧 md5 回读一致）。⚠️ 真机复测重点：AI 回复时灵动岛球是否呼吸/三态是否对、展开态「停止生成」是否真能停、点灵动岛是否回聊天页；长任务中途退后台再回来，会话里是否出现 🔔 进度气泡（配后端「静默 30s 且有新增」规则）；语音态输入框不再有蓝紫流光。
> 上一版：**v3.9.6/451（2026-09-12 已出包，tag `v3.9.6`，CI run 34622070926 success，commit `f76d09b`） —— 语音录音中**实时文本直接上屏**（v3.9.5 只把胶囊去掉不够：录音全程框里只剩「输入消息…」占位，松手才一次性出字）
> 本版：**v3.9.6/451（2026-09-12 已出包，tag `v3.9.6`，CI run 34622070926 success，commit `f76d09b`）录音实时上屏根治**：v3.9.5 以为「输入框常显 + `onTextChange` 写 `inputText`」就能实时出字，**实测无效**（录音全程只有占位，松手才一次性出字 ⇒ 要么实时结果没到、要么「存下来的闭包写 @State / TextField 外部刷新」不可靠）。v3.9.6 不再赌这两条路：①录音态在输入栏**同一行位置直接用 `Text` 渲染 `liveSpeech.liveText`**（`@Published` 驱动，即旧胶囊那条已验证会刷新的路径），TextField 只在非录音态出现（观感仍是同一个输入框，不再是红色胶囊）②加 `.onChange(of: liveSpeech.liveText)` 把实时文本同步进 `inputText`（SwiftUI 原生更新周期写 @State，比存闭包写可靠），松手定稿后框内即最终文本 ③**诊断自证**：`LiveSpeechTranscriber` 新增 `volatileCount/finalCount/firstResultMs` 计数与 `liveStalled`（录音 3s 仍零结果才置位），输入栏**仅在 `liveStalled` 时**显示 `V0/F0` 小字——正常时界面零杂物，异常时一眼判定「实时结果根本没到」（该诊断是临时的，确认稳定后删）④点按消息区空白 = 停止语音输入（保留，注释写明）。IPA 已校验 **3.9.6/451**，md5 `f24aa4758e9a239b6bc2cbfcc8041cb8`（2,845,896 bytes），已转存 NAS `轻聊app/qingliao-3.9.6-unsigned.ipa`（NAS 侧 md5 回读一致）。⚠️ 真机复测重点：长按进语音后**说话即逐字上屏**；若框里仍不出字，右**侧会出现 `V0/F0` 小字**（把这一屏发我 = 直接定位是「实时结果没到」而不是 UI 问题）。**另：后端 `/api/asr` 语音转文字链路（asr_api + nginx location + relay + whisper_venv 431M/whisper_models 142M）已随本次整体下线**（App/PWA 均无引用），详见本文件「已移除」说明。
> 上一版：**v3.9.5/450（2026-09-12 已出包，tag `v3.9.5`，CI run 34619075064 success，commit `6f3ce3e`）语音录音态 UI 修正****v3.9.5/450（2026-09-12 已出包，tag `v3.9.5`，CI run 34619075064 success，commit `6f3ce3e`）语音录音态 UI 修正**：v3.9.3/v3.9.4 把录音中的输入区**整块换成红色「正在聆听…／实时文本」胶囊**，用户反馈「看不到输入框、也看不到转写全文」→ 改为**输入框全程常显**（设备端 volatile 结果本就经 `liveSpeech.onTextChange` 实时写进 `inputText`，落框即所见），仅保留左侧 7pt 红点作「正在听」标识；录音中给输入框加 `.allowsHitTesting(false)`（防误点弹键盘打断语音模式）；顺手清掉已无用的 `recordingText` 参数与 `ChatView` 传参。IPA 已校验 **3.9.5/450**，md5 `7f6e0c0b80a627c5a0b5ed606e3da07e`（2,838,637 bytes），已转存 NAS `轻聊app/qingliao-3.9.5-unsigned.ipa`（NAS 侧 md5 回读一致）。⚠️ 真机复测重点：长按进语音后输入框里是否**逐字上屏**；长句超过框高（6 行）后输入框是否跟到最新词（若跟不动，下一页再加自动滚尾）。
> 上一版：**v3.9.4/449（2026-09-11 已出包，tag `v3.9.4`，CI run 34617595239 success，commit `3ce8d1c`）语音转文字闪退根治 + 全站按钮统一「文字+胶囊」去图标 + AI 头像去底圆放大****v3.9.4/449（2026-09-11 已出包，tag `v3.9.4`，CI run 34617595239 success，commit `3ce8d1c`）语音转文字闪退根治 + 全站按钮统一「文字+胶囊」去图标 + AI 头像去底圆放大**：①**「一触发语音转文字就闪退」（用户报 Signal(5)）根治**——v3.9.3 新的设备端转写里 `LiveSpeechTranscriber.start()` 是 `@MainActor`，其中 `input.installTap(...) { [feeder] buffer, _ in … }` 的闭包字面量**继承 MainActor 隔离**，而麦克风 tap 在**音频线程**回调 ⇒ 进闭包即 Swift 6 隔离断言 SIGTRAP。用 v3.9.3 的 dSYM 符号化定案（`Qingliao + 偏移` 换算成 `0x100000000+偏移`，命中 `closure #1 (AVAudioPCMBuffer, AVAudioTime) -> () in LiveSpeechTranscriber.start(baseline:)`）。修法=闭包显式 `@Sendable`（闭包体只碰 @unchecked Sendable 的 feeder，安全）；同文件 `AVAudioApplication.requestRecordPermission` 回调一并补 `@Sendable`。**编译器零告警、`check_swift.sh` 查不出**——同族第二例（首例 v3.7.0 剪贴板），判据/符号化手法/本地等价实验已固化进技能 `references/v370-crash-clipboard-isolation.md`。②**全站按钮统一「文字 + 胶囊」、去图标**（用户逐条要求）：刷新 15 处（看板生活数据/资讯 header、看板空态、Docker 容器与镜像、路由器面板、诊断、日志、云端设置、本地模型、视觉模型、执行历史、模型管理 3 处导航栏图标刷新）、重新生成 2 处（看板智能建议胶囊、AI 错误占位气泡下的红色重试行）、添加/添加股票 5 处（看板「添加股票」、生活卡片设置页 footer×3、自定义模型「添加」、备忘录「添加」）；长按菜单项与纯「+」图标入口按「与同类保持一致」未动。③**AI 头像**：删掉 blue→indigo 蓝色底圆；上游导出的球半径 `uniforms[4]=0.72`（球径仅占头像格 72%）按用户要求提到 **0.98**（球径≈头像格，与原来底圆尺寸对齐；只是缩放，球内观感不变，边缘留 2% 不裁光晕），30pt 消息头像 / 38pt 思考头像 / 96pt 欢迎页 logo 同步生效；渲染器不可用时的兜底脑形标自带底圆（否则白图标看不见）。④**通知 delegate 加固**（并发审查发现）：`QingliaoAppDelegate` 因 `UIApplicationDelegate`（@MainActor 协议）被推断为 MainActor 隔离，而 `UNUserNotificationCenterDelegate` 非 @MainActor（Apple 文档仅 NSObjectProtocol、无线程承诺），原 `@preconcurrency` 只是把隔离断言**推迟到运行时** → witness 标 `nonisolated`（方法体只碰 UserDefaults，行为零变化）。⑤只读并发隔离审计（子代理，102 个 .swift 逐条比对 Apple 文档 JSON）：除上述外**无第二处必崩代码**；疑似 2 处（`SafariRelay` 的 ASWebAuthenticationSession 完成闭包、诊断模块非隔离读 UIDevice/UIApplication）按「无线程证据 + 属在跑主路径 / 仅编译告警」理由未动。IPA 已校验 **3.9.4/449**，md5 `51ebfee039a6cf9473e721b85017d910`（2,841,672 bytes），已转存 NAS `轻聊app/qingliao-3.9.4-unsigned.ipa`（NAS 侧 md5 回读一致）。⚠️ 真机复测重点：语音转文字长按（权限弹窗 + 首次模型下载、边说边出字、松手定稿回填、离线可用）、各处刷新/重新生成/添加按钮观感、AI 头像大小与透明度。
> 上一版：**v3.9.3/448（2026-09-11 已出包，tag `v3.9.3`，CI run 34614390334 success，commit `571c3af`）语音转文字全量改设备端 + 攒着的 v3.9.1/v3.9.2 全量（AI 头像 siri 液态玻璃球 / UI 打磨 5 批 / 性能省电 / 剪贴板误报修）**：①**语音转文字改「苹果系统自身」的设备端实时转写**（用户拍板：不用后端）——新增 `Core/LiveSpeechTranscriber.swift`：iOS 26 `SpeechAnalyzer` + `SpeechTranscriber`，`.volatileResults` **边说边出字**、音频不出设备、离线可用、无时长上限；语音模型走 `AssetInventory` 按需下载（不占 App 体积，**首次使用要等下载数十秒**）；权限只用麦克风（Speech 框架**不需要任何 entitlement**，历史「侧载必闪退」系权限串缺失误判）。**删掉整条旧链路**：`Core/VoiceRecorder.swift`（录音 m4a）+ `AuthStore.asrTranscribe`（上传后端 `/api/asr/transcribe`），App 启动时一次性清理历史遗留 `voice_asr_*.m4a`；**云端模式放开语音入口**（v3.0.4 的 `guard !isCloudMode` 撤销，本地/云端同一条路径）。`project.yml` 补 `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription`（此前一个都没有），CI Verify 加断言「两个权限串必须真进包」。②双只读审查（deleg_d15fbdce）13 处收口，含 7 个真缺陷：`SpeechTranscriber.isAvailable` 机型守卫（该 API 有硬件要求，`supportedLocales` 为空时**不能**兜底 en-US，否则 start 抛 unsupported locale）、准备期（下模型）不可重入（一个 bus 只能挂一个 tap，二次 installTap 抛异常）、准备期点 × 原来**是空操作**（cancelRequested 标志 + 作废启动代次）、`stop()`/`cancel()` 并发重入（共用同一收尾任务）、**录音态必须显示实时文本**（原来整块被「红点+松开上屏」替换，实时上字一个字都看不见）、结果流错误自愈（`CancellationError` 不误报「转写中断」）、Analyzer 不做音频转换（converter 为 nil 且格式不符时丢弃 buffer）。③CI 三轮顺序揭示（本机无 iOS SDK，类型/并发错误只有 CI 能报）：`MapClipboardDetector` 的 `probableWebURL` 在 Xcode 26 SDK 里是**非可选 `String`**（上轮按 `String?` 修过方向反了）、`LiquidOrbAvatar` 的 `deinit` 访问非 Sendable 属性（@MainActor 类 deinit 恒为 nonisolated，token 标 `nonisolated(unsafe)`）；同时清掉 `AVAudioConverter` 输入 block 的 4 条 Swift 6 并发告警。IPA 已校验 **3.9.3/448**（主 App 与挂件 appex 版本逐字一致 + 包内 `default.metallib` + 两个权限串齐），md5 `f73307da89cca243c47940e806b6ba9b`（2,841,421 bytes），已转存 NAS `轻聊app/qingliao-3.9.3-unsigned.ipa`（NAS 侧 md5 回读一致）。⚠️ **语音为全新链路，装机后请重点实测**：首次长按的权限弹窗与模型下载等待、边说边出字、停止后定稿回填、飞行模式离线可用、本地与云端两种模式都走通；观感/手感仍需真机确认（本机无法验证）。
> 上一版（内容已含在本版，未单独出包）：**v3.9.2/447（2026-09-11，tag `v3.9.2`）AI 头像 siri 液态玻璃球 + UI 全量打磨 + 性能省电 + 剪贴板误报修复（攒 5 批发一次）**：①**AI 头像换成开源项目 `lersent001/orb`（MIT）的 siri 液态玻璃球**——用该项目自带的 SwiftUI/Metal 导出器 + 用户给的 URL 全参数生成原生渲染器（参数零手抄，逐项核对一致），轻聊侧 4 处改造：内嵌 76KB Metal 字符串 → **编译期 `default.metallib`**（MSL 写错让 CI 的 Archive 抓，别等真机）；device/queue/三条管线提取为**进程级共享单例**（原来每个头像各建一套，长列表会爆）；**思考中 30fps 连续动画、不思考播完回落过渡即冻结成静态帧**（`isPaused` + 按需重绘 → 长列表静止头像零连续 GPU 开销）；初始化失败优雅降级（退回脑形标，不再 `preconditionFailure`）。接入点：消息头像 30pt（`streamingAvatar ? .thinking : .idle`）、思考中占位头像 38pt、欢迎页 logo 96pt；dock 智能球按用户要求**不动**。署名见 `docs/THIRD_PARTY_LICENSES.md`。②剪贴板提示只认位置链接（三道闸 + 跨启动去重，修「只要剪贴板有内容就提示发给 AI」；另修三态探测/记账时机/`geo:` 链接被丢）。③卡片圆角全量统一 16（唯一例外=看板空调 hero 卡 22）。④UI 打磨 5 批：动效令牌收口、zoom 转场 1→7 处、滚动层次感、**字号 22 档→8 档（749 处/46 文件）**、轻量骨架屏（方案见 `docs/UI_POLISH_PLAN.md`）。⑤性能省电：全屏发光特效 60fps→30fps（原来跑系统全帧率）、dock 球内层 Canvas 帧率可调、后台停探针与收件箱轮询、删 2 处真死配置。⚠️ **`.metal` 是本仓首个 Metal 源码**：CI 需 `xcodebuild -downloadComponent MetalToolchain`（Xcode 26 起不再随 Xcode 捆绑），workflow 已加该步 + Verify 断言包内 `default.metallib` 存在。双只读审查（deleg_a77718d6 / deleg_bf777edb）意见逐条处理后发版；CI 曾抓出 `ContainerSection` 用了未定义的 `busy`（本机无 UIKit/Metal 编译器，类型与 MSL 只有 CI 能验）；`probableWebURL` 的实际类型最终由 v3.9.3 的编译器实证为**非可选 `String`**（见上条）。
> 上一版：**v3.8.0/445（2026-09-11 已发版，tag `v3.8.0`，CI run 34600606983 success）灵动岛/锁屏实时活动 + 设置开关**：① 新增 `QingliaoWidget` app-extension target（`com.qingliao.app2.widget`、`NSExtensionPointIdentifier=com.apple.widgetkit-extension`），主 App embed 依赖 → `.appex` 编进 `Qingliao.app/PlugIns/`；主 App Info.plist 开 `NSSupportsLiveActivities`。② 挂件 UI：灵动岛紧凑态（图标 + 计时）／展开态（会话名 +「AI 正在回复 · 模型名」+ 计时）／minimal ／锁屏横幅，计时用 `Text(_:style:.timer)` 交系统自走（侧载免费签名无推送更新，App 被挂起后只有系统计时钟照走）。③ `LiveActivityManager`：本地 `request/update/end`；**不持有 `Activity` 本体**——`Activity` 非 Sendable 且 `update/end` 是 nonisolated async，存进 `@MainActor` 存储会报 `sending 'activity' risks causing data races`（CI 首轮 34599892145 实测），改为只存 Sendable 状态、每次从 `Activity.activities` 现取；不做 APNs（免费签名拿不到 Push 能力）。④ 设置开关「灵动岛实时活动」（默认开；`AppearanceSheet`「交互」区，本地/云端共用同一组件与 key）：关掉立即收起 + 启动收敛清上一进程遗留活动。⑤ 版本号 project.yml **8 处**同步（主 App Info.plist/settings + 挂件 Info.plist/settings）；CI Verify 步骤新增 `.appex` 精确路径 + 扩展点 + `NSSupportsLiveActivities` 校验。IPA 已校验 **3.8.0/445**，md5 `3542b0748723c730aa970c6dd8412176`，已转存 NAS `轻聊app/qingliao-3.8.0-unsigned.ipa`。⚠️ 侧载安装前须先在 SideStore 设置 → Advanced → User Customizations 打开 **Customize App Extensions**（否则新挂件会被当"多余扩展"静默删除），或卸载后全新安装。**✅ 用户 2026-09-11 真机实测通过**（SideStore 0.6.4，弹窗选 `Keep App Extensions (Use Main Profile)` 安装；AI 回复时灵动岛亮起 + 计时正常，设置里关开关立即收回）——侧载链路唯一需要真机验证的一环已确认。
> 上一版：**v3.7.1/444（2026-09-11 已发版，tag `v3.7.1`，CI run 34591881447 success）**：v3.7.0 生活页备忘录（含气泡存备忘录·整条/选中）+ 资讯长按复制/大爆炸 + 剪贴板地图入口 + AI 回复进度行下线；v3.7.1 修复 3.7.0 打开即闪退（剪贴板探测的 completion 闭包在后台线程执行 `@MainActor` 隔离体 → SIGTRAP）
> 上一版：**v3.5.2/436（2026-09-11 已发版，tag `v3.5.2`，CI run#460 success）复读根治 + 「AI 正在输入」不再丢失**：①**复读根治（双端）**：后端 `/api/stream/recover` 内存分支按 `createdAt` 取最新（原按 dict 插入序取到**最旧**任务，2026-09-10 实测复现：20 分钟前的旧答案被当本轮回复落库）、磁盘兜底按 `createdAt`/mtime 取最新；App 侧 `StreamClient.tryRecover` 收紧采纳闸门——**只采纳「本机这条任务」或「另一条仍在途的任务」**（在途任务的内容必属本轮），异任务且已完成一律不采纳（404 路径也不例外，改为报错收尾让用户重发）；候选被忽略时**归还**那次 recover 机会（原实现把忽略当已接管消费掉，弱网白丢续流机会）；换任务时 content/offset **整体重置**（不再新旧混拼/半截回复）。②**「AI 正在输入」不再静默消失**：探针 `probeRemoteBusy` 改为**服务器是唯一真相**——不再以本机持久化标记为前提，无标记也主动问服务器（无标记时 12s 降频省电），服务器说在途而本机没在收就**直接接回**（新 `adoptRemote`：整体重置内容 + 重落标记）；探针失败收起阈值 3→5 次（弱网抖动不再瞬间熄灭）。根因：本机标记在弱网 15 连败收尾/`finish()` 时被清 → 探针前提不成立 → 连问都不问服务器 → 前台彻底无提示、答案也回不来。③**跨会话串扰收口**：`restoreIfNeeded` 校验收持久化的 sessionId 属当前会话（防别的会话旧内容落进当前会话）；`sendFile`/`regenerate` 落库回调补「已切会话就丢弃」守卫（与 `startStream` 一致）。IPA 已校验 **3.5.2/436**，md5 `12a38af27499aec699641df638a6cf90`，已转存 NAS `轻聊app/qingliao-3.5.2-unsigned.ipa`
> 上一版：**v3.5.1/435（2026-09-10 已发版，tag `v3.5.1`，CI run 34495464274 success）「AI 正在输入」体验 + 空回复不再静默 + 长任务不再被截断**：①**聊天页 header 新增「AI 正在输入…」**（`PageHeader` 加 `busy` 参数 + 新 `BusyDots` 三点呼吸，只用 opacity 动画守 v3.2.3 渲染红线；`ChatView` 加 `remoteBusy` + 6s 探针走 `GET /api/stream/recover` 做服务器侧兜底=App 杀后台重开/切页回来仍显示；探针带会话守卫（标记属别的会话不显示也不误用本会话查询）、网络连续失败 3 次收起（防幽灵）、`aiBusy` 按会话收窄（A 会话在跑不污染 B 的 header））②**空回复不再静默**（本地流 success 但内容为空 → 发送/自动重试/重新生成/杀后台恢复/发文件 5 条路径落 27 字提示气泡「⚠️ 本轮空回复：点上方「重新生成」（长任务易被截断）」，`⚠️` 前缀命中 `isErrorPlaceholder` → 气泡自带一键「重新生成」；⚠️ 刻意**不 markFailed**（`failed` 全仓库无复位点，会让已送达消息永久挂红叹号、点击还删消息重发），文案必须 **≤30 字**（`upsertAssistant` 对 >30 字做全历史精确查重，超长会在第二次空回复时被静默吞掉））③**Hermes `agent.max_turns` 40 → 120**（NAS root 改 `/opt/data/config.yaml`，网关每轮热读无需重启）。**根因**：长任务被 40 步截断后 Hermes 流式接口未回吐最终文本 → 后端收到空内容落库 done → App 侧流结束 `isStreaming=false` → 停止按钮消失/灵动岛发光停止/用户看不到任何回复。IPA 已校验 **3.5.1/435**，md5 `8f36513d50d3bc77dffa49445e5af2c1`，已转存 NAS `轻聊app/qingliao-3.5.1-unsigned.ipa`
> 上一版：**v3.5.0/434（2026-09-10 已发版，tag `v3.5.0`，CI run 34492680289 success）四项能力**：Agent 结果卡片化（```ql-card 围栏协议 + 卡片渲染，零回归/流式安全）+ 看板「生活数据」卡片区（股票行情 + RSS/博客更新）+ 崩溃/卡顿自上报 + App 内诊断页 + 设置新增「阶跃 StepAudio」TTS（stepaudio-2.5-tts + 4 预置音色）+ 朗读无声根治（系统语音也显式激活 `.playback` 会话）+ tab bar 改常驻（`.never`）+ 预检脚本依赖源文件恢复；IPA 已校验 3.5.0/434，md5 `32f272388907a7e9253a087516f7e5ae`，已转存 NAS `轻聊app/qingliao-3.5.0-unsigned.ipa`
> 上一版：**v3.4.29/433（2026-09-10 已发版，tag `v3.4.29`，CI run 34479987326 success）**：①新建会话「+」= 静默重置 gateway 上下文（先做成等同 `/new`，再改静默无感）②UI 灵动轻快三批（批1 Motion 动效令牌/系统微交互/tab bar 滚动收缩；批2 图片 zoom 转场/会话行滚动层次感/tab 入场；批3 统一按压反馈 + 全屏粒子帧率减半）③首页首屏优化 + 欢迎页排版协调；IPA 已校验 3.4.29/433，md5 `ccd78ad1b7cf6a4b92856dc5eb3498b7`，已转存 NAS `轻聊app/qingliao-3.4.29-unsigned.ipa`
> 上一版：**v3.4.28/432（2026-09-10 已发版，tag `v3.4.28`，CI run 34467152250 success）**：弱网重连机制优化 + 攒改动合入；`MarkdownRenderer` append 类型修复（AttributedString 包 NSAttributedString 后入 NSMutableAttributedString，4 处）；IPA 已校验 3.4.28/432，md5 `262809e84adc870f068f66181091bc8a`，已转存 NAS `轻聊app/qingliao-3.4.28-unsigned.ipa`（2026-09-10 从 CI artifact 补转）
> 上一版：**v3.4.27/431（2026-09-09 已发版）**：版本号递增（本批实质内容并入 3.4.26）；IPA md5 `901e867a98170abe5c33d12efbae74c1`（NAS 有）
> 上一版：**v3.4.26/430（2026-09-08 已发版）三项体验优化**：①通知正文取 AI 回复首句（`notifyReply`，锁屏可见"答了什么"）②附件/相机钮纳入低透明胶囊语义（与发送/停止同族，去图标漂浮）③看板轮询去通知化（`DockTabView` 直传 isActive，30s 轮询收进 `.task(id:)`，切走即取消零空转）；另修拍照/相册连发纯图被吞（`sendCore` 60s 幂等签名加 image 指纹）+ 续聊芯片永不显示（新增消息区顶部 `continueChipsBar`）
> 上一版：**v3.4.25/429**：性能稳定性+UI创新 20 项；注册 `qingliao://` URL Scheme（分享面板更稳定出现轻聊）；任务中心查询改用 `/api/agent/tasks/active` 别名；CI 修复（`ChatInputBar` 参数序对齐声明序 + Swift 6 sending 检查 key 落 `String` 值拷贝）
> 上一版：**v3.4.24/428**：任务中心入口迁至聊天页 header 常驻小图标 + 地图定位分享接 AI 周边推荐（+ 补 `import CoreLocation`）
> 上一版：**v3.4.23/427**：任务中心「进行中」分区 + 推送搭载投递 + 图标玻璃美化 + App 角标；修任务中心入口可见性
> 上一版：**v3.4.22/425**：复读根治——`upsertAssistant` 全历史精确查重 + `sanitizeForContext` 全历史 assistant 去重
> 上一版：**v3.4.21/424**：控件语义统一——二元控件收敛胶囊形态 + 设置分组描边追平（同时并入 v3.4.20/19/18/17：UI 活力四项+任务中心铃铛遮挡修复 / 发送按钮三态（空闲淡灰·有字蓝紫渐变+发送回弹）/ 看板用量卡支持智谱 Coding Plan 双窗口余量 / 复读根治-历史净化补连续相同 user 去重）
> 上一版：**v3.4.16/419（2026-09-07 已发版，tag `v3.4.16`，CI run 34135361088 success）三项体验增强**：①**收件箱→任务中心**（后端 `inbox_api` 加 `task_type` 分类 reply/cron/system，App 非 reply 推送不再塞会话气泡而是进任务中心列表：新 `TaskCenterStore`(持久化+去重+标记完成) + 新 `TaskCenterView`(分类过滤/操作单) + `DockTabView` 右上角钟形悬浮入口(未读红点) + `ChatView` 监听 `.qingliaoTaskSend` 跳转发送；后端已部署容器验证 E2E，`push(text, task_id, task_type)` 签名已加载）②**发送可靠性三件套**（`PendingSend` 改 `Codable`，`pendingQueue` 落盘 `UserDefaults`，`persistPendingQueue`/`restorePendingQueue`/`clearPendingQueue` 接入 4 处 append + 2 处 removeFirst + onAppear 启动恢复自动补发——杀 App/断网重启不丢排队消息）③**存储自洁**（`RemoteDiskCache` 远程图磁盘缓存 150MB LRU 清理（`fileURL`/`write`/`read`/`enforceLimit`，重启复用省流量）+ 长会话超 300 条顶部归档提示条（`archiveBanner`+`exportArchiveSafe` 点击手动导出））。IPA 已校验 **3.4.16/419**，md5 `6dddebd5350a4a1a15e51f8e0972a112`，已转存 NAS `轻聊app/qingliao-3.4.16-unsigned.ipa`；发版通道本批走 **svg(origin) + Git Data API 快进**（github.com 443 被断，`api.github.com` 通，用 blobs/trees/commits/refs API 快进，blob+tree md5 逐字核对与本地一致）
> 上一版：**v3.4.14/417（2026-09-06 已发版，commit `a2da948`）系统分享接入口**：iOS 系统分享面板可分享会话内容
> 上一版：**v3.4.13/416（2026-09-06 已发版，commit `141bb5f`）看板磁盘布局调整**：①看板 NAS 面板移除「系统盘」分区卡片栏目（系统盘分区/数据卷分区详情全部收进磁盘弹窗 `DisksSheet`，按 `kind` 分组展示，卡片弹窗内容不变）②磁盘卡片改并入 NAS 面板 2 列栅格、与温度卡等尺寸（`MeterCard`），仍点击进 `DisksSheet`；IPA 已校验 3.4.13，md5 `d3ddcb6ac46981f92651d2960799846d`，已转存 NAS `轻聊app/qingliao-3.4.13-unsigned.ipa`（CI run 34037251162 success）
> 上一版：**v3.4.10/414（2026-09-06 已发版，commit `1399450`）X方案根治复读**：①App `startStream` 回退发「断种子净化完整历史」`chat.historyPayload()`（内置 sanitizeForContext 断 msgs[-2] 种子）②后端 `_build_hermes_messages` 改发净化历史（`_sanitize_history`+`_compress_long_assistants`+`_break_repeat_seed`）③**去掉 `X-Hermes-Session-Id`**（方案C分支+回退分支，Hermes 不再用 state.db 重建未净化原始会话 → 复读根因堵死；保留模型选择/图片/流式/工具）；IPA 已校验 3.4.10，md5 `1c431ce60c121f4958d0a96967a46f1a`，已转存 NAS `轻聊app/qingliao-3.4.10-unsigned.ipa`（CI run 34022566849 success）
> 上一版：**v3.4.9/413（2026-09-06 已发版，commit `2504ea7`）**：①方案C 会话托管根治复读（后端 `STREAM_HERMES_SESSION=1` 所有聊天恒走 Hermes agent，只发 system+最新user+会话头 `X-Hermes-Session-Id:ql_<sid>`，Hermes 从 state.db 按 ql_<sid> 续上下文=微信/QQ 机制；App 端 `startStream` 只传当前 user 消息、不再喂全量 historyPayload）②蜂窝+贴超长文本发送 SIGABRT 崩溃根治（`relayPayloadLength` 改纯字节估算，彻底移除 JSONSerialization）③App 端历史净化 `sanitizeForContext`（镜像后端 `_sanitize_history`+`_break_repeat_seed`）；IPA 已校验 3.4.9，md5 `128791b5a307c9ead476fbd095a1c459` 已转存 NAS `轻聊app/qingliao-3.4.9-unsigned.ipa`

> ⚠️ 版本注：v3.4.10 含 3 个提交（6db1f45 dashboard 卡内存改 docker 实际值 + 7caf85d release + 1399450 ChatView X方案），本仓库有 `origin`(=`lxm20060513-svg`，主通道) + `apple`(备用) 两个 remote，tag/CI 默认推 `origin`（旧 HANDOFF 提及的 "apple remote" 在本仓库不存在，已过时）
> 上一版：**v3.4.8/412（2026-09-05 已发版，commit `4f87164`）**：inbox 推送 taskId 去重根治下拉刷新重复推送 + App 瘦身删死代码（418 行）
> 上一版：**v3.4.7/411（2026-09-05 已发版，commit `e1bff65`）**：①「切后台再进」流式回复+🔔推送气泡重复根治（InboxStore 去重未命中且流式已结束 isDone 时，延迟 1.5s 等落库/恢复稳定再重比对，仍不命中才注入；不违背"在看也推"语义）②CloudConfig 视觉识别补 stepfun ③stepfun 防复读强模型判定（后端早已部署）；IPA 已校验 3.4.7/411，md5 `0d029e98e0af860b6c8deab534cac389` 已转存 NAS `轻聊app/qingliao-3.4.7-unsigned.ipa`
> 上一版：v3.4.6/410（2026-09-05 已发版，commit `ee9b509`）：修复底部上拉拉取收件箱异常提示“拉取失败”（每次拉取前清空旧错误，避免历史失败持续残留）；IPA 已校验 3.4.6/410，md5 `379092441445e896263b981edf16e571` 已转存 NAS `轻聊app/qingliao-3.4.6-unsigned.ipa`（标准 IPA，含 Payload/ 目录）；服务端仍待补 Hermes state.db 去重 + 后端 frequency_penalty 兜底
> 上一版：v3.4.5/409（2026-09-05 已发版 svg 通道，commit `6e0ed7f`）：在 v3.4.4 基础上追加两项复读修复——①assistant 内容指纹去重（改写型重复也拦截）②发送侧同内容 60s 幂等窗口（防重投）；IPA 已校验 3.4.5/409，md5 `1d6f5f0e7322081711284df8b3eb18bf` 已转存 NAS `轻聊app/qingliao-3.4.5-unsigned.ipa`
> 上一版：v3.3.3/403（2026-09-04 svg 通道：错位复读锚定根治——assistant 落库锚定发起 user 消息；IPA md5 `0abd6e23`）
> 后端已上线：v3.2.7（方案C 上下文上移 Hermes）+ **v3.3.1 修复**：图片管道 multimodal 透传（`_build_hermes_messages` 保留 list）、语音 asr_server 修复（`asr_server.py` 已入 hermes-data 并拉起 9144 监听）

---

## 一、项目概况

**轻聊** 是一个 iOS 原生 AI 聊天 App，Swift 6 + SwiftUI 开发，支持本地 AI 和云端 AI 双模式。

- **仓库**：双 remote——`origin` = `https://github.com/lxm20060513-svg/qingliao-ios`（**当前发版主通道**，tag/CI 在此触发，v3.4.x~v3.9.x 全打这）；`apple` = `https://github.com/lxm20060513-apple/qingliao-ios`（**备用通道**，origin runner 卡住/额度耗尽时把 tag 推这里触发 CI）。两账号都须把 `default_branch` 设为 `feature/handoff-301`（否则仓库默认分支指错，v3.4.30 前后踩过）
- **主分支**：`native-3.0`（v3.x 开发线，停在 v3.0.34 旧 commit，发版不走它）
- **开发分支**：`feature/handoff-301`（当前活跃，发版 commit 都打这）
- **旧分支**：`native-2.0`（v2.0.140 已冻结，带 tag `v2.0.140`）
- **Tag 规范**：`v3.X.Y` 推 **origin**（svg）触发 CI，查/盯 CI 看 `lxm20060513-svg/qingliao-ios` actions runs；origin 跑不动时才改推 apple remote。CI 触发条件是 tag（`on: push: tags: v*`）+ 手动 dispatch，**推分支不会触发构建**。token 从 `git remote get-url origin/apple` 里取（勿写入任何文档）

### 核心架构

| 层 | 技术 |
|---|---|
| UI | SwiftUI，glassEffect 毛玻璃卡片，Siri 淡雅配色 |
| 网络层 | 注入式 HttpClient 协议，测试可 mock |
| 流式输出 | SSEStreamDecoder（SSE 逐 token 推送） |
| 数据层 | @Observable ViewModel + FileManager JSON 持久化 |
| 语音 | **iOS 26 设备端实时转写**（SpeechAnalyzer/SpeechTranscriber，输入栏/发送键长按触发；v3.9.3 起不用后端 ASR） |
| 云端工具 | CloudToolLoop + LocalToolRunner（日历/提醒/计时器/天气/剪贴板/计算器/通知） |

### 关键源文件

| 文件 | 职责 |
|---|---|
| `QingliaoApp.swift` | 入口 + GlobalEnvironment + 主题初始化 + 主题切换动画 + scenePhase 后台恢复 |
| `ContentView.swift` | 主界面 + 导航逻辑 |
| `ChatViewModel.swift` | 核心聊天逻辑，local/cloud 双模式 + 7 个工具 |
| `ChatComponents.swift` | MessageBubble / ChatInputBar / SiriBallView / BubbleTheme / MarkdownTableView |
| `ChatStore.swift` | 聊天数据持久化 + 导出功能（txt/Markdown/PDF） |
| `ChatView.swift` | 聊天页面 + 消息列表 + 语音转文字 + 导出菜单 + 钉一钉回调 |
| `LiveSpeechTranscriber.swift` | 设备端实时语音转写（SpeechAnalyzer + SpeechTranscriber；v3.9.3 起，替代 VoiceRecorder + 后端 ASR） |
| `StreamClient.swift` | SSE 流式轮询 + restartPolling 后台恢复 |
| `PinStore.swift` | 钉一钉数据层（CRUD + NAS JSON 持久化 + UserDefaults 兜底） |
| `PinCard.swift` | 钉一钉卡片组件（长按复制/删除） |
| `DockTabView.swift` | Tab 切换 + 淡入缩放动画 |
| `MarkdownRenderer.swift` | 正则解析 Markdown，渐进渲染 + 逐字显示 |
| `LiquidGlass.swift` | 主题系统 + AI 推荐卡片 + BubbleTheme + DashboardCardStyle |
| `DashboardView.swift` | 智能看板（NAS/HA/路由器/钉一钉） |
| `Models.swift` | 所有数据模型（含 cpuText/pctText/maxDiskPctText 预格式化） |
| `SettingsView.swift` | 设置页（8 个 @ViewBuilder section + 输入校验 + 钉一钉存储路径） |

---


## 二、版本历史（v3.6.5 及更早已归档）

> 历史版本（v3.6.5 → v3.0.49，575 行）与旧的 CI/CD 手工发包流程已移到 **`HANDOFF-archive.md`**。
> 需要查某个老版本的改动细节时读归档；日常发版用 `ql.py ios release <版本>`。
>
> ⚠️ 原「三、CI/CD 发包流程」（手工 bump/push/盯包/转存）也已一并归档 —— 已由 `ql.py ios release` 自动化，
> 别照抄旧步骤。（后面章节编号保持不变，避免破坏文内交叉引用。）

## 四、NAS 部署结构

| 路径 | 内容 |
|---|---|
| `/docker/hermes/微信文件/轻聊web/backend/` | 后端代码（API 服务器，容器 qingliao） |
| `/docker/hermes/微信文件/轻聊web/frontend/` | Web 前端 |
| `/docker/hermes/微信文件/轻聊web/data/` | 钉一钉数据（pins.json，容器可写） |
| `/docker/hermes/微信文件/轻聊app/` | iOS IPA 文件存放 |
| `/docker/hermes/微信文件/轻聊app/qingliao.app/` | SideStore 打包用的 .app 目录 |

---

## 五、踩坑经验

### 1. project.yml 版本号
- **8 处**必须同步（主 App + 挂件扩展各 4 处：MARKETING_VERSION / CURRENT_PROJECT_VERSION / CFBundleShortVersionString / CFBundleVersion；两套逐字一致，CI Verify 会断言）
- `info.properties` 的 CFBundleVersion 会覆盖 settings 的 CURRENT_PROJECT_VERSION
- **发版前 grep 两处都对齐**，并解包产物核对 Info.plist

### 2. NAS SFTP 路径
- SFTP chroot 到 `/volume1/`，用相对路径 `docker/hermes/...`
- 绝对路径 `/volume1/docker/...` 会 ENOENT
- 目标目录属主 root → 需 sudo cp

### 3. NAS 上传流程
- SFTP put 到可写路径（`docker/hermes/_upload.ipa`）→ sudo cp 到目标 → chmod 644
- exec_command cat + stdin 大文件会 Socket closed → 用 SFTP
- sudo -S 必须立即 stdin.write 密码

### 4. Git push 卡死
- `git -c http.version=HTTP/1.1 -c http.lowSpeedLimit=0 -c http.lowSpeedTime=999 push`
- 重试循环最多 8 次，间隔 10s

### 5. CI 失败重发
- 删 tag 重建 + 重推（**主通道 `origin`**；origin 卡住时把 `origin` 换成 `apple`）：`git push origin :refs/tags/vX` + 本地 `git tag -d vX` + `git tag vX` + `git push origin feature/handoff-301 vX`

### 6. 智能球语音功能（v3.0.73 已移除，⚠️ v3.1.7 起球长按语音转文字回归，勿照本操作）
- v3.0.70-72 三次尝试修复语音松手上屏 bug 均失败
- 根因链：DragGesture 移除 → 透明 overlay 拦截松手 → overlay 改 allowsHitTesting(false) → 仍有问题
- 最终方案（v3.0.73）：球的**语音对讲/按住说话**功能全部移除（-335 行）；语音转文字保留在输入栏（send 按钮/输入框长按）
- ⚠️ **v3.1.7 起 `SiriBallView` 加回「长按=语音转文字」（`ExclusiveGesture(LongPress, Tap)`，v2.0.98 SIGTRAP 教训：勿叠加 onTap+onLongPress）**——与输入栏长按同路径 `toggleVoiceMode`，单击仍展开输入框。本条"球无语音"结论已不适用于 v3.1.7+

### 7. 容器文件系统只读
- NAS 容器对 `/volume1/docker/hermes/微信文件/轻聊app/` 是只读的
- 钉一钉数据存储在 `/volume1/docker/hermes/微信文件/轻聊web/data/`（容器可写）
- 后端 API（files_api.py）通过 pin_write/pin_read 端点读写

### 8. 音频会话未释放
- 多次录音后 `AVAudioSession.setCategory(.record)` 可能失败（上次录音未正确释放）
- v3.0.74 曾试"录音前先 `try? session.setActive(false)`" → ⚠️ **v3.0.76 已回退**（该改动实测导致录音采不到字节、松手必弹"录音太短"）
- 当前（v3.2.4 回归 .record 同步基线）不前置 setActive(false)：会话还原靠 `stop()` 内 `setCategory(.playback)` + `setActive(false, .notifyOthersOnDeactivation)`（v2.0.102 起，同时保证 TTS 朗读有声）

### 9. token 迁 Keychain 遗漏升级用户 → 全接口 401（v3.0.84 引入，v3.0.86 修复）
- v3.0.84 把 token 从 UserDefaults 明文迁到 Keychain，但 `AuthStore.init()` **只从 Keychain 读**，**没兜底升级用户**——升级用户此前 token 一直存 UserDefaults、Keychain 为空，但登录布尔(UserDefaults)仍为 `true`。
- 症状：能进主界面（假登录），一发消息 `/api/stream/start` 返回 401（非 AUTO_LOGIN 时 `check_auth` 要求 `X-Auth-Token` 有效，token 空即 401）。
- 修复：`init()` 改「Keychain 优先 → 空则回退 UserDefaults 旧 token 迁入 Keychain 并清明文残留 → 仍空且已登录则强制 `isLoggedIn=false` 回登录页」。
- 类级：**任何「存储迁移」都要考虑升级用户的旧数据兜底**，不能只读新位置。排查「能登录不能聊天」先看客户端 token 是否为空（401 根因），再谈服务端鉴权。

### 10. 收件箱推送 vs 会话流式回复重复（v3.0.87 初版失效，v3.0.88 修复）
- AI 回复完成后端 `_maybe_push_app` 把回复摘要推入收件箱（方案A：每条都推）；App InboxStore 又把收件箱消息注入当前会话（方案B）→ **同一条回复出现两次**（流式气泡 + 🔔推送气泡）。
- 修复（v3.0.88）：App `InboxStore.pollOnce` 注入前调 `shouldSkipDuplicate(push:in:)`——当前会话最后一条 assistant(非推送) 文本**压缩空白后**已含推送正文（去尾部省略号）→ 判定重复，仅标记已读（`markDone`）不注入。
- ⚠️ v3.0.87 初版只用 `contains` 直比：后端用 `re.sub(r"\s+"," ",...)` 把回复压成单行、流式 content 保留换行 → 匹配不上失效。v3.0.88 加 `normalizeWhitespace`（换行/多空格→单空格）双向比对 + `hasPrefix` 截断前缀兜底才生效。
- ⚠️ v3.0.90 再补**时序竞态**：v3.0.88 只在「回复已落库」时能去重，但后端 done 即推、App 落库要等 `finish→upsertAssistant`——InboxStore 轮询抢在落库前拉到推送就漏。修复：流式进行中（`stream.isStreaming`）本轮不注入，等落库后下一轮必命中。类级：**比对类去重必须考虑「数据还没写入」的竞态窗口，不能只比对已存在的消息**。
- 类级：**两个独立链路（后端自动推 + App 端注入）叠加在同一会话时，必须先想清楚会不会重复**；比对文本务必先统一空白格式（推送可能压行、会话保留换行），否则 contains 匹配失败。
- ⚠️ v3.2.2（2026-09-03）**根治**：前面 v3.0.88/90 都是 App 端**被动去重**（依赖时序命中），仍会在竞态缝隙漏网（用户实测「流式回复 + 🔔推送」重复再现）。**曾试方案A**：后端 `_maybe_push_app` 加「用户在看则不推」门控（复用 `PUSH_IDLE_SECONDS=30`，用户正盯着 App 看流式回复就不推收件箱）——**用户拍板否决"看不推"**（明确"希望在看也推"），已回滚为"完成即推"。**最终方案（v3.2.2 定案）= 后端完成即推 + App 端 `shouldSkipDuplicate` 加 `extra: stream.content` 兜底**（流式回复一定在 `stream.content`，即使 `chat.messages` 因时序暂缺也能命中去重）。**类级教训：去重逻辑的比对源必须是"数据源本身"（流式缓冲）而不只是"已落库消息"，落库与比对存在时间差必有竞态缺口；"要不要加门控"是产品语义决策，先问用户拍板再改，改了要能干净回滚（`.bak322gate` 留档）。**

### 11. NAS 发版脚本 cp 弹 overwrite 交互卡死（v3.0.90 实踩）
- NAS root shell 的 `cp` 是 `cp -i` 别名（`cp -f` 也弹「overwrite?」）→ 自动化脚本用 `cp` 传 IPA 会卡在交互确认，md5 校验拿不到。
- 解法：用 `\cp -f`（反斜杠绕别名）或绝对路径 `/bin/cp -f`。
- 配套：>100KB 文件别走 base64 PTY 上传（超时），用 **SFTP put 到可写路径 → \\cp -f 到目标 → chmod 644 → md5sum 两端比对**；GitHub artifact 下载 302 到 Azure blob 时 urllib 默认跟随会带 Authorization 头致 401 → NoRedirect 拦截 + 手动跟随不带 auth。

### 12. Agent agent_msgs 跨请求污染导致模型回复旧答案（v3.1.5 引入，v3.1.7 修复）
- `_agent_loop` 返回的 `agent_msgs`（含工具调用+结果+system prompt）被 `_worker` 存储到 `st["agent_msgs"]`，`_build_messages` 优先使用它。
- **症状**：用户发新问题，模型回复旧答案（因为旧的 agent_msgs 混入新请求上下文，模型被旧内容"带跑偏"）。
- **诊断**：`stream_ctx_debug.log` 显示 `msgs=N` 正确（新消息确实在），但模型忽略最后一条。
- **修复**：移除 `st["agent_msgs"]` 跨请求持久化，`_build_messages` 始终用原始 `st["messages"]`。
- **类级**：**agent loop 的富化上下文仅在本次请求内有效，不能持久化到 st 供下次复用**——旧工具调用会污染新请求，模型注意力被旧内容分散。

### 13. Agent 不知道自己在 NAS 上（v3.1.5 实踩）
- 模型说"当前这台机器没有 /volume1"并写脚本让用户手动执行，而非直接调用工具。
- **根因**：agent system prompt 没告诉模型它的运行环境和可用工具。
- **修复**：system prompt 明确列出"运行在 NAS 上，/volume1 可直接访问"+6类工具能力+行为约束（"用户说帮我做X时直接调用工具"）。

### 14. @AppStorage 默认值 ≠ 写入 UserDefaults（v3.2.1 实踩，agentEnabled 发 false）
- **病根**：设置页 `@AppStorage(UserDefaultsKey.agentEnabled) var agentOn = true`，默认值 `true` 只在 UI 层生效、**不写盘**（除非用户实际拨动过 Toggle）。而 `AuthStore.streamStart()` 用 `UserDefaults.standard.bool(forKey:)` 读取——**key 从未被写入时返回 false** → UI 显示"开"但请求发出 `agentEnabled: false` → 后端 `agent_on=False` 走普通 LLM（不做工具调用）。
- **诊断**：后端 `/tmp/stream_agent_debug.log` 里 `agent_on=False` 大量出现，但设置页明明开。grep `registerDefaults` 全仓库无结果，确认无"首启写默认值"逻辑。
- **修复（双保险）**：① `QingliaoApp.init()` 加 `UserDefaults.standard.register(defaults: [key: true])`；② AuthStore 读取改 `(UserDefaults.standard.object(forKey:) as? Bool) ?? true`（`object(as? Bool)` 对缺失/nil 返回 nil 走兜底 true，且不误伤用户显式关闭——存了 false 仍尊重）。
- **类级**：**`@AppStorage` 默认值 ≠ 真正写入 UserDefaults**。凡「设置页显示默认开（@AppStorage 默认 true / 默认值）+ 别处用 `bool(forKey:)` 读」的组合必踩坑。排查"UI 显示 X 但请求却 Y"先 grep 读取方用 `bool(forKey:)` 还是 `@AppStorage`，再查有无 `registerDefaults` 初始化。

### 15. Agent 工具循环必须用支持 tool calling 的模型，不能跟随聊天主模型（v3.2.1 实踩，Agent 400）
- **病根**：`_worker` 调 `_agent_loop` 时把聊天主模型的 `model/provider`（如 `mimo-v2.5`/`xiaomi`）传进去，`_agent_loop` 带 `tools` 参数发请求 → **mimo-v2.5 不支持 OpenAI 原生 tool calling** → `HTTP Error 400 Bad Request`。
- **诊断**：`/tmp/stream_agent_debug.log` 显示 Agent 分流行 `agent_on=True is_agent=True model=mimo-v2.5 provider=xiaomi`——分流成功但用错了模型。
- **修复**：`_worker` 调用改 `_agent_loop(st["messages"], task)`，**不再传 model/provider**，`_agent_endpoint(None, None)` 回退 `AGENT_URL/AGENT_KEY/AGENT_MODEL`（deepseek，支持 tool calling）。
- **类级**：**聊天主模型（mimo）≠ 工具调用模型（deepseek），二者必须解耦**。v3.0.30 曾把 Agent 模型改成"跟随设置页选定模型"，是背离 v3.1.8 已验证决策的回归。排查"Agent 分流生效但 400/空回复"先看 debug 日志的 `model/provider`——若 Agent 行显示 mimo/xiaomi 即用错模型，Agent 必须走 deepseek 等支持 tool calling 的 provider。
- ⚠️ 本机相关 provider 速记：`mimo-v2.5`(xiaomi) 不支持原生 tool calling；`deepseek`(deepseek) 支持。Agent 恒用 deepseek。

### 16. 后端代码部署：先 docker inspect mounts 实测，再决定重建 or 重启（v3.2.3 更新，原"必须重建镜像"结论已被实证推翻）
> ⚠️ **本节下方旧结论（必须重建镜像）在 v3.2.2 之后已过时**——compose 已变：`docker inspect qingliao` 实测 mounts 含 `/volume1/docker/hermes/微信文件/轻聊web => 同路径 (rw)`（宿主 backend 容器内直读）+ `/tmp (rw)` + `/volume1 (ro)` + docker.sock。
> - **v3.2.3 实证**：改宿主 `tool_executor.py` → 只 `docker rm -f qingliao && docker compose up -d` 重启 → 容器内实测函数输出新逻辑 ✓ 生效，**无需重建镜像**。
> - ⚠️ **陷阱**：容器内 `/app/backend/*.py` 仍是镜像 COPY 残留的**旧文件**（md5/日期对不上宿主）——**别拿 `/app/backend` md5 判断部署是否生效**（会误判"没生效"白重建镜像）。运行中的 qingliao_all.py 实际加载宿主 bind mount 路径；生效判据 = **docker exec 实测函数输出**，不是文件 md5。
> - **决策流程**：① `docker inspect qingliao --format '{{range .Mounts}}{{.Source}} => {{.Destination}} ({{.Mode}}){{println}}{{end}}'` ② 有 轻聊web => 同路径/含 backend 的 rw bind mount → 改宿主 + 重启容器（rm -f + compose up -d）；无 → 走下方旧流程重建镜像。

以下为 v3.2.2 之前（compose 无 bind mount 时期）的旧记录，保留备查：

- **现象**：反复改进宿主 `backend/stream_api.py`（复读修复/Agent400修复都用 `docker exec qingliao sh -c 'md5sum /volume1/.../backend/stream_api.py'` 验证到了新函数），但 App 复读还在、Agent 还 400——**声称部署的修复始终不生效**。
- **根因**：容器**实际运行的不是 bind mount 的宿主 backend，而是镜像内 `COPY backend/` 固化的 `/app/backend`**！
  - 容器挂载只有 3 项：`/usr/bin/docker`、`/data`、`/var/run/docker.sock` —— **根本没挂宿主 backend 到 `/app/backend`**
  - 容器进程 `cat /proc/1/cmdline` = `python3 /app/backend/qingliao_all.py`，cwd=`/app/backend`
  - 容器内 `/app/backend/stream_api.py` md5=`9075c808`（Aug 22 旧版），`_break_repeat_seed`=**0**（无修复）
  - 宿主 `/volume1/.../backend/stream_api.py` md5=`77634dfc`（含修复）——**改的不是容器跑的那份**
- **诊断方法（必须做）**：改 backend 后**校验容器内 `/app/backend/stream_api.py` 的 md5 是否等于宿主新代码**，而不是只 grep 宿主路径。`docker exec qingliao sh -c 'md5sum /app/backend/stream_api.py'`。
- **修复（重建镜像）**：
  1. Dockerfile 修正为 `/app` 路径：`COPY backend/ /app/backend/` + `WORKDIR /app/backend` + `CMD ["python3", "/app/backend/qingliao_all.py"]`（与镜像历史结构对齐）
  2. build context 必须是**同时含 `backend/` 和 `docker/` 子目录的父目录**（`/volume1/docker/hermes/微信文件/轻聊web/`），因 Dockerfile 用 `COPY docker/curl-wrap` 和 `COPY backend/`
  3. `cd 轻聊web/ && docker build -f docker/Dockerfile -t qingliao-backend:latest .`（约 1-3 分钟，pip install pyyaml/cryptography）
  4. `docker rm -f qingliao && docker compose up -d`（compose 用 `image:` 无 `build:`，故容器重建即加载新镜像）
- **验证**：`docker exec qingliao md5sum /app/backend/stream_api.py` == 宿主 md5；`grep -c _break_repeat_seed` ≥3；容器内 `_agent_endpoint(None,None)` 返回 deepseek。
- **类级**：**改后端代码 ≠ 重启容器，必须重建镜像**（除非 bind mount 生效；本 compose bind mount 的是 `/volume1/...` 只读挂载整个 web 目录、不是 `/app/backend`）。镜像内 `COPY backend/` 固化旧代码，compose `image:` 不会自动 rebuild。验证必须看容器实际加载路径（`/proc/1/cwd` + `/app/backend` md5），不能只看宿主 grep——**之前多轮改宿主 backend 却容器跑镜像副本，是"始终没生效"的总根源**。

### 17. 灵动岛/实时活动「球动几下就不动了」（v3.9.13 定案，用户真机报，类级）
- **四条叠加根因**：①推进步长是「指数收敛 + 保底 0.006」，在 20pt 环（周长 62.8pt）上只有 **0.38pt/拍** → 头几拍后肉眼看不见（判定阈值：**一拍弧长 ≥1pt 才算可见**，`周长 = π × 直径` 换算自查）；②`progress` 到封顶（0.86）就 `return` 收工 → 此后不再 update = **画面彻底静止**（只要是真「进度」，必然有封顶；**封顶后必须另有「不确定态相位」在变**）；③`thinking` 阶段根本没起推进器（首 token 前 10–20s 全静止）；④动画画在 `TimelineView(.animation)` 包的 `Canvas` 里 —— **实时活动没有连续帧源**（Apple：动画只随数据更新发生、≤2s、AOD 不播），真机等于不跑（`Canvas` 内容也不参与 SwiftUI 插值）。
- **推手（节拍 Task）三个反模式，每个都让画面永久冻住**（真机必现、CI 完全查不出 → 只能把状态机镜像成真值表测）：①起表用 `guard handle == nil`：旧表被代际作废但还挂在 `Task.sleep` 上（尚未执行 defer 清句柄）时新表被挡下、旧表醒来又自退 → **场上再无推手**（症状：思考期动几拍，首 token 一到就静止）。改用「**活着的直接复用**」。②改成「代际变了就重建」：sync 每次走到 update 路径都会 `generation += 1`，于是每次 sync 都 cancel + 重起 → 推手永远跑不满一拍、等于不动。③**sync 内容去重的早返回里不重新武装推手**：任何一次外部停表（切会话触发 `finish()` 不匹配分支、安全阀到期、活动被系统清掉）之后，只要字段与上次全同（已进入 streaming 的一轮不会再变）就永远不重起 = **永久冻住**；修法：早返回前补一次**幂等起表**。配套：句柄用**单调递增令牌**记归属，`defer` 只在令牌仍归自己时清（否则退场中的旧表会误清新表句柄）。
- **相位（`spin`）必须累计、不回绕**：取模回绕会让弧角度从 315° 倒插回 0°（每轮约 9.6s **反向急扫一圈**）；需要 0…1 的地方在挂件自己取余，**且圈速倍数不能是整数圈**（×8 取余后每拍值相同 → 系统判定值未变、不重绘，反而彻底不动；本项目用 `spin * 5` ≈1.9s/圈）。
- **硬限制**：侧载免签无 APNs，**App 被系统挂起后无法再 update** → 锁屏/切走久了停在最后一帧（框架边界，别当 bug 修；想挂起期也动只能后台保活，耗电且系统仍会掐，须用户点头）。
- 判据/修法已固化进技能 `ios-widget-live-activity`（「球/环到底该怎么动」节）与 `qingliao-ios-native`（灵动岛条目）；真值表 `/opt/data/scripts/qingliao_island/truth_table_progress.swift`（**52 条**，含「旧实现必现静止」的事故证据链）本机可复跑，不依赖 Xcode。

### 18. SwiftUI 计算属性里调 AVFoundation → 主线程卡 3~7 秒（v3.9.9 引入 / v3.9.10 修复，类级）
- **症状**：设置页「点不动」，用户真机抓到 7 条 3.2~6.7 秒卡顿。
- **根因**：把「系统音色列表」写成 SwiftUI 计算属性 → **每次 `body` 求值都调** `AVSpeechSynthesisVoice.speechVoices()`，该调用进 TextToSpeech 并被无障碍层 `axUnsafeForcedSync` 串行化同步等待 → 主线程卡死。
- **修法**：后台线程枚举一次 + 缓存（纯值快照类型，文件作用域声明以避开 Swift 6 嵌套类型隔离推断）；UI 侧改 `@State` + `onAppear` 异步取，`body` 里零 AVFoundation 调用。
- **类级**：**`body` / SwiftUI 计算属性里绝不能调昂贵或会同步阻塞的系统 API**（AVFoundation/TTS、磁盘遍历、`Process`、网络）。判定靠 **dSYM 符号化**（CI run 的 dSYM）而不是猜。


---

---

## 六、快速定位信息（接手者先读）

> 围绕「轻聊」三大定位：源码在哪、推送/微信/token 相关文件名、想了解什么。所有路径为脱敏版（不含密码/token）。

### 1. 源码位置

| 环节 | 路径 |
|---|---|
| **git 仓库** | 双 remote：`origin`=`lxm20060513-svg`（**发版主通道**，tag/CI 在这触发）/ `apple`=`lxm20060513-apple`（**备用**，origin runner 卡住时换）。token 内嵌在 remote URL 里（勿写进文档），两账号都把 `default_branch` 设为 `feature/handoff-301` |
| **App 本地仓库** | `/opt/data/qingliao_ios/`（**主开发+发版副本**，分支 `feature/handoff-301`；发版 commit/tag 都打这，**勿放 /tmp 会被重启清空**；旧副本 ql_ipa2 已删） |
| **NAS 后端（线上运行）** | `/volume1/docker/hermes/微信文件/轻聊web/backend/`（容器 `qingliao` 挂载，**非** `/opt/data/ql_backend` 历史副本） |
| **NAS 前端** | `/volume1/docker/hermes/微信文件/轻聊web/frontend/` |
| **NAS IPA 存放** | `/volume1/docker/hermes/微信文件/轻聊app/` |
| **Hermes 数据（容器内=宿主）** | `/opt/data` == 宿主 `/volume1/docker/hermes/hermes-data` |

### 2. 具体文件

**推送服务（微信 + App 收件箱，两条链路别混淆）**

| 文件 | 位置 | 职责 |
|---|---|---|
| `push_api.py` | NAS backend | **微信推送队列**（9147，现统一走 9127 `/api/push`）：enqueue/pending/done + 即时投递 relay；存储 `push_queue.json` |
| `inbox_api.py` | NAS backend | **App 收件箱**（v3.0.83 新增，走 9127 `/api/inbox`）：App 轮询 / 标记已读 / Hermes push；存储 `inbox_queue.json` |
| `ql_push_relay.py` | Hermes `scripts/` | 微信投递 relay（监听 9460），`POST /send` + `X-Push-Token` 鉴权，内部调 `send_weixin_direct` |
| `ql_push_send.py` | Hermes `scripts/` | 微信直发辅助 |
| `ql_push_poller.sh` | Hermes `scripts/`（两份） | cron 兜底投递（push_queue → 微信，relay 挂了才用） |
| ~~`ql_push_app.sh`~~ | — | ⚠️ **2026-09-13 核实：该脚本已不存在**（`find /opt/data -name ql_push_app.sh` 无结果；`wechat-profile` 也已删，微信通道由 default profile 服务）。需要 Hermes→App 主动推送时，直接 POST NAS `inbox_api` 的 push 端点，token 取 `/opt/data/.inbox_token` |
| `hermes_watchdog.py/.sh` | Hermes `scripts/` | relay 保活（每 2 分钟查 9460/health，挂了拉起） |

**微信接入模块**

| 文件 | 位置 | 职责 |
|---|---|---|
| Hermes weixin 通道 | 内置 `platforms.weixin`（config.yaml 88/119/146/219 行） | 微信收发；账户轮询状态在 `/opt/data/weixin/accounts/*.sync.json` |
| `channel_api.py` | NAS backend | 轻聊内与微信通道交互的 API |

**Token / 配置**

| 文件 | 位置 | 内容 |
|---|---|---|
| `/opt/data/config.yaml` | Hermes | 主配置（provider + platform.weixin） |
| `/opt/data/.env` | Hermes | 环境变量（token 来源） |
| `docker-compose.yml` | NAS `/volume1/docker/hermes/hermes-data/ql_docker/` | qingliao 容器环境变量（**QL_INBOX_TOKEN / QL_PUSH_TOKEN / QL_PASSWORD 注入处**） |
| `/opt/data/.nas_cred` | Hermes | NAS SSH 凭证（值脱敏） |
| `/opt/data/.gh_cred` | Hermes | GitHub token（值脱敏） |
| `/opt/data/.inbox_token` | Hermes | 新生成 192-bit 强 `QL_INBOX_TOKEN`（值脱敏，供 ql_push_app.sh 读） |

### 3. 若你想了解

- **🅰️ 整体架构**（消息怎么进出、怎么推到 App）：读「一、核心架构」+「★ 2026-08-22 推送延迟优化」+ `app-active-push-inbox.md`（skill reference）。核心：App 是「App 主动请求→服务端响应」，无服务端主动塞消息通道；服务端主动推 = inbox 收件箱 + App 15s 轮询。
- **🅱️ 某个 bug 排查**：读「五、踩坑经验」+ 各版本历史对应条目；定位后按 skill `qingliao-webui` 的排查链走（先区分通道死 vs agent 慢、先日志定位再改）。
- **🅲️ "文件自动归档"**：见 `wechat-file-organize`（收到微信文件按扩展名分类存储）——轻聊侧对接在 `files_api`/`media_convert`，按需另开启。
- **🅳️ 鉴权/安全机制**：App 端 `X-Auth-Token`（auth_api.check_auth，login 签发）；Hermes 侧 `X-Inbox-Token`/`X-Push-Token`（服务间 token，compose 注入）；详见 `v2116-backend-security-review` + `app-active-push-inbox.md`。

---

## 七、Hermes 容器运维踩坑（非轻聊，接手者注意）

### Hermes 容器 `gateway-default` 重生风暴 → CPU 100%（2026-08-31 实测修复）
- **现象**：`hermes-hermes-1` 容器 CPU 持续占满一核（`ps` 见 103% 进程）。日志 `/opt/data/logs/errors.log`：`Gateway (re)started 6-7 times in 120s — backing off`、`Previous gateway life ... exited UNCLEANLY (SIGKILL)`，pid 每 18-20s 递增。
- **根因**：s6 服务里 `gateway-default`（`hermes gateway run --replace`，**无 `-p`**，跑 default/root profile）被 auto-start。`/opt/data/gateway_state.json` 的 `desired_state: "running"`，`container_boot`（`_AUTOSTART_STATES={"running"}`）据此启动它，但它启动即反复被 SIGKILL→s6 立即重启→风暴吃满一核。真正在用的 `gateway-wechat-profile`（`-p wechat-profile`）正常，不受影响。
- **排查链**：`ps aux --sort=-%cpu`（找无 `-p` 的高 CPU gateway 进程）→ `tail /opt/data/logs/errors.log`（respawn storm）→ `/etc/cont-init.d/02-reconcile-profiles` 调 `hermes_cli.container_boot`（注释：per-profile gateways 运行时动态登记到 `/run/service/`）。
- **止血（运行时）**：`/command/s6-svc -d /run/service/gateway-default`（容器内 s6-svc 不在 PATH，在 `/command/`）。
- **持久（防容器重启复活）**：把 `/opt/data/gateway_state.json` 的 `desired_state` 改成 `"stopped"`——`container_boot` 只 auto-start `running`，非 running 只登记 down slot 不启动。**切勿动** `profiles/wechat-profile/gateway_state.json`（那才是真正在用的 profile）。
- **改法**：容器内 `python3` 改 JSON（root：`docker exec -u root hermes-hermes-1 python3`），用 base64 管道避免 PTY 引号地狱。
- **关键点**：`/opt/hermes` 是**镜像层**，改代码/脚本不持久（重启重映射）；必须改 `/opt/data`（**持久卷**）里的数据。`gateway-default` slot 总会登记（供 `hermes gateway start` 无 `-p` 用），但只要 `desired_state` 非 running 就停在 down，不烧 CPU。

---

*文档完。每次发版后请更新此文档的版本号和改动记录。*
