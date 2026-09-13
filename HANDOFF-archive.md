# HANDOFF 历史归档（版本沿革 + 旧发版流程）

> 这是 `HANDOFF.md` 的归档部分，**只在查历史细节时读**。
> 主文件保留：最近 3 版 / 项目概况 / NAS 部署结构 / 踩坑经验 / 快速定位。
> 发版流程请用 `ql.py ios release <版本>`（见 `RUNBOOK.md`），本归档里的手工流程已过时。

## 二、版本历史

### v3.6.5（模型思考胶囊 + dock 球几何居中/加大，2026-09-11 已发版，tag `v3.6.5`，CI run#469 success）
| 改动 | 文件 | 说明 |
|---|---|---|
| **模型思考胶囊（新功能）** | ChatView / ReasoningLevel.swift（新）/ AuthStore | 聊天页 header「任务中心」左侧新增档位胶囊（**不思考 / 低 / 中 / 高**），点开选择、当前档位带 ✓；选择存 UserDefaults（`qingliao_reasoning_level`，默认 low）并随 `streamStart` 以 `reasoning` 字段下发。后端译成 Hermes **按次** 思考配置 `model_options.reasoning`，只作用于轻聊请求、不动 Hermes 全局。**仅本地模式显示**（云端由服务商决定思考策略，且云端侧按约定暂不改动） |
| dock 球几何居中 | ChatEffects | 球心 y 改**几何定位**：屏高 − 底部安全区 − tabBar高/2 + 6.3pt（= 799.8pt，与截图实测内容中心一致）。不再取 `UITabBar`/`UITabBarButton` 的 bounds 中心——按钮 bounds 是否撑满 tab bar 无法本地证实，若撑满则 `br.midY == tr.midY` 改基准等于没改，且两条路径差 6.3pt 会跳变 |
| 球尺寸 | ChatEffects | 50 → **52**（可见球体 ≈41pt）|
| 自查加固（review 采纳）| ChatView / ChatEffects | 胶囊抽独立属性降 type-check 压力；触摸区 ~46×24pt；「关闭」改名「不思考」（避与弹窗「取消」混淆）；`estimateBodyBytes` 补 reasoning 字段开销（蜂窝分段判定防线）|
| 版本号 | project.yml | 3.6.4(441) → 3.6.5(442) |

**后端（已单独上线，无需等 App 包）**
- 思考档位链路：`/api/stream/start` 读 `reasoning`（none/low/medium/high）存 task.state → 两处请求体构造 `_reasoning_options(st.get("reasoning"))`。容器内端到端验证 **PASS**：`none → reasoning.enabled=false`、`low/medium/high → effort 透传`、未传 → 默认 low。

**⚠️ CI #468 失败实录（首发），两处都是工具层自查漏项：**
1. `ChatEffects.swift:318: error: declaration can not have multiple global actor attributes ('MainActor' and 'MainActor')` —— 用脚本删除 `ballCenterFromBottom` 时**只删了函数体**，其文档注释与 `@MainActor` 残留，与新邻居的 `@MainActor` 相邻。
2. `DockTabView.swift:116: error: type 'DockOrbOverlay' has no member 'ballCenterFromBottom'` —— 删**公有成员**前只 grep 了 ChatEffects，漏了 DockTabView 的烟花原点调用。
   处置：清残留注释；按几何口径恢复该属性（`dockBarHeight/2 − dockContentCenterDrop` = 18.2pt，与新球位同源）并在源码内加警示注释。
   **规则沉淀：删除/改名任何成员前必须全仓 grep（`grep -rn <名字> qingliao/`）；脚本删函数要连带其紧邻的文档注释与修饰符一并删。**

**IPA 校验**：**3.6.5/442**、MinOS 26.0，md5 `ac3dc89a844c7764fca001ff98640fe5`，已转存 NAS `轻聊app/qingliao-3.6.5-unsigned.ipa`。
**发版通道**：github.com:443 仍不通（GnuTLS -110），继续走 **Git Data API**（远端 commit `4266444`）；期间 API 也出现过 SSL EOF 抖动 → 盯包脚本需带重试。
**待装机确认**：①思考胶囊位置/交互（点开四档、✓ 标记、选择是否生效——选「不思考」后回复应明显更快）；②球是否在 dock 内上下居中（若仍偏差，用 `verticalNudge` 微调 1~2pt）；③胶囊与「任务中心/更多」两个图标在窄屏是否挤压标题。

### v3.6.4（dock 球上下居中+加大 / 诊断记录清除 / 首 token 提速，2026-09-11 已发版，tag `v3.6.4`，CI run#467 success）
| 改动 | 文件 | 说明 |
|---|---|---|
| dock 智能球上下居中 | ChatEffects.swift | 装机反馈"球不居中"：原球心取的是**槽位按钮中心**，而按钮 bounds 含「图标 + 文字」两行、中心比 dock 中心偏上。改为 x 用按钮中心（水平对准槽位）、**y 用 `UITabBar` 自身的垂直中心**（`tabBar.convert(bounds, to: nil).midY`）→ 球真正居中于 dock 内 |
| 球尺寸 | ChatEffects.swift | 44 → **50**（球体 ≈34pt → ≈39pt）；dock 高 49pt，上下各留约 5pt |
| 诊断记录清除 | DiagnosticsView.swift | 「最近记录（崩溃 / 卡顿）」卡片底部新增 **「清除全部记录」**（红色，有记录时才显示）+ 二次确认，清本机 `historyEvents` 与 `pendingEvents`（待上报队列一并清）；**已上报服务器的记录不受影响** |
| 版本号 | project.yml | 3.6.3(440) → 3.6.4(441) |

**后端（已单独上线，无需等 App 包）**
1. **价格监控「点了添加立刻回退」根治** `life_api.py`：App 添加 = 追加空卡片再落库，后端 `_norm_price` 把 url 非 http 的项直接丢弃 → 回读覆盖本地 → 卡片消失（只有该入口无前端校验）。改为"未完成项（url 未填）原样保留，填了才校验/去重"，抓取侧给「未填写商品 URL」友好占位。容器内实测 PASS 并还原原配置一致。
2. **首 token 提速** `stream_api.py`：Hermes 全局 `agent.reasoning_effort=medium` 导致模型每轮先吐几百字思考再出正文，而轻聊后端**完全丢弃** reasoning（等于用户白等）。实测同问题（9123 打 2 轮）：medium 正文首字 3.4~3.8s → **low 1.6~2.2s** → enabled=false 0.9~1.7s。改为**按次传** `model_options={"reasoning":{"enabled":true,"effort":"low"}}`（只影响轻聊，不动 Hermes 全局），env `QL_REASONING=off` 可切完全禁思考。
   ⚠️ 结论留存：**"把思考显示给用户"在当前架构下做不到** —— Hermes 的 OpenAI 兼容层（9123 `api_server_openai_routes.py`）只发 `output_text.delta/done` 与 `output_item` 事件，**没有任何 reasoning 事件构造**（两轮实测 reasoning 字符=0）；`display.show_reasoning` 是 CLI/Web UI 层能力，不影响该端点。

**IPA 校验**：**3.6.4/441**、MinOS 26.0，md5 `5f29663ddb08ba1e4a1f6aebc34aeb06`，已转存 NAS `轻聊app/qingliao-3.6.4-unsigned.ipa`。
**发版通道**：github.com:443 仍不通，继续走 **Git Data API**（远端 commit `6738acb`）。
**待装机确认**：球是否上下居中于 dock、大小是否合适（仍有偏差可用 `ballSize`/`verticalNudge` 微调）；诊断页清除后列表应立刻变空。

### v3.6.3（dock 球定位根治 + 资讯字号 + 价格监控添加修复，2026-09-11 已发版，tag `v3.6.3`，CI run#466 success）
| 改动 | 文件 | 说明 |
|---|---|---|
| dock 智能球位置修正 | ChatEffects.swift | 根因：叠加层被系统 tab bar 吃掉底部安全区，原公式 `cy = h - (safeBottom + 49/2)` 把安全区**算了两遍** → 球比图标高约 34pt（装机截图证实球悬浮在 tab bar 上方）。改为**读系统真实槽位**：递归找 `UITabBar` → **递归**收集类名含 `TabBarButton` 的子视图（只扫直接子视图会漏，按钮可能裹在中间容器里）→ 按 minX 排序取第 3 个 → `convert(bounds, to: nil)` 得 window 坐标；按钮数与槽位数不符则回退（统一 window 坐标换算，不含双算） |
| 球尺寸 | ChatEffects.swift | 36 → **44**（球体 ≈28pt → ≈34pt），装机反馈"太小、比 dock 图标还小" |
| 坐标刷新加固 | ChatEffects.swift | 连读 3 次（0.15/0.6/1.6s）取**最后一次**有效值（转屏/后台恢复不再锁死旧 frame）+ `scenePhase` 回前台重读 + `Task.isCancelled` 守卫（`try? await sleep` 会吞取消，否则视图消失后仍写 @State） |
| 烟花原点坐标系 | ChatEffects.swift | `ballCenterFromBottom` 改为「距**叠加层底**」（与 BurstCanvas 的 `h - originFromBottom` 同一坐标系）；原窗口坐标会让烟花原点偏离球心一个安全区；`UIScreen.main`（iOS 26 已弃用）改用 key window / scene `coordinateSpace` |
| 资讯卡片字号放大 | LifeCardsSection.swift | 用户反馈字体偏小：条目标题 12→**15**、展开正文 13→**15**、来源/时间 9→11、卡片标题 12→13、刷新按钮与更新时间 10→11、读取中提示 11→13、失败文案与标签 +1（共 14 处，只动资讯卡片，股票/快递/价格卡片未动） |
| 价格监控「点了添加立刻回退」 | 后端 life_api.py（**已单独上线，无需等 App 包**） | 根因：App 添加 = 先追加空卡片再落库，后端 `_norm_price` 把 url 非 http 的项**直接丢弃** → 回读的 config 没这条 → App 覆盖本地 → 卡片消失（只有该入口没有前端校验）。修法：未完成项（url 未填）原样保留，填了才校验/去重；抓取侧给「未填写商品 URL」友好占位，不再请求空地址。容器内实测 PASS 并在 finally 还原原配置、与原始 JSON 完全一致 |
| 版本号 | project.yml | 3.6.2(439) → 3.6.3(440) |

**发版过程踩坑（已写进技能 `qingliao-ios-native` references）**：首次 run#465 在 Archive 阶段失败，报 `ChatEffects.swift:221 error: type '()' cannot conform to 'View'` —— `GeometryReader` 的 ViewBuilder 里写了 `let target: CGPoint` + `if/else` 赋值语句，ViewBuilder 只接受表达式，那个 `if` 被当作条件视图构建。**本地 `swiftc -parse` 全绿也查不出这类类型错误**（只有 Xcode 编译阶段才报）→ 改 `liveCenter.map { ... } ?? ...`。
**发版通道**：github.com:443 仍不通，继续走 **Git Data API**（远端 commit `99646ca`，顺带把默认分支保持为 feature/handoff-301）。
**IPA 校验**：**3.6.3/440**、MinOS 26.0，md5 `0b9430fe953738f0b55f7e6916899549`，已转存 NAS `轻聊app/qingliao-3.6.3-unsigned.ipa`。
**待装机确认**：球是否精确落在 dock 第 3 槽位（若仍有偏差，先用 `ballSize` / `verticalNudge` 微调；若 iOS 26 玻璃 tab bar 结构再变，`collectTabButtons` 的类名匹配需同步）。

### v3.6.2（dock 智能球 + 生活 tab + 资讯 AI 全文，2026-09-11 已发版，tag `v3.6.2`，CI run#464 success）
| 改动 | 文件 | 说明 |
|---|---|---|
| dock 顺序重排 | DockTabView.swift | 会话 → 看板 → 聊天 → 生活 → 设置；新增 `DockTab.life`（图标 sparkles） |
| 聊天槽位改动态智能球 | DockTabView.swift / ChatEffects.swift | iOS 26 原生 TabView 的 tab item 只吃系统图标（无自定义视图 API）→ 该槽位 `.tabItem { Text("").accessibilityLabel("聊天") }` + `DockOrbOverlay` 叠加自绘球（**`allowsHitTesting(false)`** 触摸穿透给系统 item，点球=系统切页）；空闲 15fps 呼吸 / 流式思考 30fps orbits；切到聊天页放全屏烟花（分享、深链等程序化切页跳过） |
| 新增「生活」页 | Features/Life/LifeView.swift（新） | 原看板「生活数据」（股票行情 / 博客资讯 / 快递 / 价格监控）整体迁入独立 tab，`isActive` 驱动 30s 轮询；看板删除相关 state/section/sheet/loadLife/deleteStock 共 -68 行 |
| 移除聊天页智能球 | ChatInputBar.swift / ChatView.swift / CloudSettingsView.swift | 球态分支、`qingliao_ball_input`、键盘收起回收球 onChange、外观页「智能球输入」开关全删；`SiriBallView` 尺寸/帧率参数化（基准 92，dock 传 36） |
| 资讯点击展开 AI 全文（不再跳浏览器） | LifeCardsSection.swift / Core/LifeCards.swift / LifeView.swift + 后端 life_api.py | 后端新增 `POST /api/life/article`：抓 HTML → 清洗正文 → 模型整理 → **按 URL 缓存 6h**（失败仅缓存 10min 便于重试），模型不可用降级返回清洗原文（`source=raw`）；App 侧就地展开三态（读取中 / 正文 / 失败可点重试），展开态由单一 `expandedArticleID` 控制（同时只展开一条） |
| 资讯刷新真正生效 | LifeCardsSection.swift / LifeView.swift | 资讯卡片标题行加专用刷新按钮；整块刷新与资讯刷新都带 **`?fresh=1`** 强制绕后端缓存（原实现不带 fresh，受 RSS 900s 缓存限制——点了 15 分钟内不出新内容，这是「刷新没反应」的根因） |
| 请求层可选超时 | Core/AuthStore.swift | `request/json/jsonOrLog` 加可选 `timeout`（默认行为完全不变）；资讯正文请求用 45s（后端抓取+模型整理实测 6.7s，蜂窝直连默认 10s 会误报失败） |
| 版本号 | project.yml | 3.6.1(438) → 3.6.2(439)，四处一致 |

**发版通道**：github.com:443 不通（git push 连续 GnuTLS/Auth 失败）→ 走 **Git Data API 快进**（远端 commit `4ee74895`，分支与 tag 同步；顺带把仓库默认分支从 `native-3.0` 修正回 `feature/handoff-301`）。IPA 已校验 **3.6.2/439**、MinOS 26.0，md5 `4076c8e625967d8d0046a2e10f0f5b8b`，已转存 NAS `轻聊app/qingliao-3.6.2-unsigned.ipa`。
**两轮独立 code review 的修复**：①资讯展开收不起来（渲染只看缓存字典不看展开态）→ 单一展开 id 控制；②dock 球在 5 个 tab 全程 30fps → 空闲降 15fps；③蜂窝默认 10s 超时 < AI 整理耗时 → 请求层可选超时；④分享/深链切聊天页误放烟花 → 程序化切页跳过；⑤资讯刷新成功后旧错误行残留 → 同步清掉。

### v3.6.1（流式行级小气泡，2026-09-11 已发版）
| 改动 | 文件 | 说明 |
|---|---|---|
| 流式中按行拆独立小气泡 | ChatMessageBubble.swift | splitParagraphs 加 lineMode：流式中💭心跳/🔧工具行/正文段各自独立气泡逐个蹦出；落库后仍按空行拆段 |
| 版本号 | project.yml | 3.6.0(437) → 3.6.1(438) |


### v3.3.3（2026-09-04 已发版 svg 通道，commit `f685ba5`：错位复读锚定根治）

**错位复读根治（2026-09-04 用户报"聊天过程中重复了几次一样的回答"）**：stream 文件铁证——App POST 的 messages 里旧 assistant 回答被错位粘贴（胡志明答贴到"轻聊app开发"后、MiMo 旧答贴到"告诉我哪个版本"后、v56 比 v3.3.1 还晚落库），Hermes transcript 全程正常 = 模型无辜，纯 App 落库锚点缺陷。根治 = `ChatStore.upsertAssistant` 支持 `afterUserID` 锚定（回答插到发起它的 user 消息之后，同轮回复区去重，杜绝延迟完成回调/杀后台恢复/排队场景把旧答 append 到新 user 后）；`StreamClient.persistState` 增 `userMsgId` 跨进程传锚点；全部落库路径锚定（startStream/restoreIfNeeded/regenerate/sendFile/云端 4 处）。改动 4 文件 +62/-19。旧会话错位历史（763E/BEB57A）清洗待发版后执行。

### v3.3.1（2026-09-04 已发版 svg 通道，commit `91b71fb`/`7e4afd2`：bot 模式移除 + vision 模型识别修复(mimo) + 后端图片/语音修复）

> 背景：用户拍板「彻底移除 bot 模式」（旧 bot 会话弃，不兼容保留）+ 反馈「消息不被落盘」「图片不识别」。本版 iOS 侧移除 bot + 修消息落盘；后端同步部署图片 multimodal 透传 + 语音 asr_server 修复。

**① iOS 侧（commit `91b71fb`）**：
- **bot 模式彻底移除**：删 `BotStore`/`BotManageSheet`/`botSelectorBar`/`botId`/`QingliaoBot` 模型/会话 `bot:<id>:<sid>` 命名空间（前后端删净，旧 bot 会话弃）；后端 `_apply_bot`/`_build_messages` bot 分支已删
- **消息落盘修复**：`sendCore` 主路径 append 后**立即 `saveToServer`**，防 App 被杀/断网丢用户消息；轮询间隔 15s→5s + 流式结束 1s 快拉 3 轮（侧载无 APNs 只能靠轮询）

**② 后端同步修复（v3.3.1，本会话部署）**：
- **图片管道 multimodal 透传**：`_build_hermes_messages`/`_build_hermes_agent_prompt` 保留 `isinstance(last_user,list)` 原样透传（不 `str()` 打平），`_worker` 提取 `last_user_text` 与原始 `last_user` 分离——App 发图不再被后端丢 image_url 块
- **语音"一直转换中"根治**：根因=`asr_server.py` 从未放入容器挂载的 `hermes-data`（容器 `/opt/data`），`_ensure_server` 拉起时报 `can't open file /opt/data/asr_server.py` → 9144 永不监听 → 转写超时。修复=`asr_server.py`（2006B）写入 `/opt/data`（=容器挂载目录）并拉起，`[asr] listening on 127.0.0.1:9144`，9144 探测 501 正常

**③ 版本号**：project.yml 3.3.1/401（4 处）。**发版通道 svg(origin)**：分支预检 CI success（run 397），tag `v3.3.1` 推 origin 触发发版 CI success（run 398），IPA 校验 3.3.1/401 通过，md5 `0e608b44` 转存 NAS `轻聊app/qingliao-3.3.1.ipa`。

### v3.3.0（2026-09-04 已发版 svg 通道，commit `2354847`：多选合并发送 + 三处 type-check 超时块抽离）

> 背景：用户反馈"AI 每轮新回答都变成同一段旧话"（复读）。方案C（上下文托管上移 Hermes）已在后端根治（见下方后端 v3.2.7）。iOS 侧本次主要是多选合并功能 + 编译修复。

**① 多选合并发送**（v3.3.0 核心功能，commit `07567cd`/`6b87af1`）：
- 右上角菜单 / 长按菜单「多选」进入勾选模式（流式中拦截提示，上限 99 条）
- 全行点击勾选 + 圆圈指示；底部操作条（全选/取消/已选计数/合并发送）
- `ChatViewExport.mergeAndShare` 按时间序打包选中消息 → SessionCardView 卡片图(@3x) → 系统分享（微信可发）
- 只丢原文，图片/语音/撤回降级占位

**② 编译修复（关键，否则 v3.3.0 无法编译）**：
- **删多余闭合 `}`**：v3.3.0 抽离 `contextUsageBar` 时在 ChatView.body 残留一个多余闭合大括号（原属于被替换掉的 `if chat.contextInfo.count > 10 {...}`），导致 `struct ChatView` 提前闭合 → `downloadImage`（static func）被挤出类型作用域 → "static methods may only be declared on a type" + 顶层 extraneous '}'。已删。
- **三处 type-check 超时块抽离**（Xcode 26 type-check "unable to type-check in reasonable time"）：body 太重是根因，逐次报错 462→508→665，三处分别是：
  - `headerTrailingItems`（PageHeader 的 `AnyView(HStack{...})` 内联过复杂）
  - `chatActionDialogContent`（confirmationDialog 内联 Menu + 8 Button 过大）
  - `inputArea`（`if selectMode/else(ChatInputBar 17参+多closure)` 内联，v3.3.0 最大新增块）
- 每次改后 `check_swift.sh` 语法预检通过；最终 CI success。

**③ 版本号**：project.yml 3.3.0 / 400。**发版通道：svg(origin)**（记忆：apple token 已失效，svg 为可用通道）。tag `v3.3.0` 推 origin，CI success，IPA 校验 3.3.0/400 通过，md5 `c44165fe` 已下载待转存 NAS。

### 后端 v3.2.7（2026-09-04 已部署重启，**方案C**：上下文托管上移 Hermes，根治复读）

> 用户拍板走方案C（"我愿意走C，不然很难成为生产力工具"）+ "同步移除bot模式" + "统一走hermes"。方案C 让轻聊从「上下文管理者」退化为「流式转发代理」——历史由 Hermes 按 sessionId 服务端托管续接，从架构层面根治复读（不再靠启发式防复读压缩）。

**① 核心机制**（`stream_api.py`）：
- 新增 `_use_hermes_session()`（读 env `STREAM_HERMES_SESSION`，=1 启用，=0 回退现状）+ `_hermes_session_header()`（`ql_<sessionId>` 前缀头）
- 请求体只传**最新 user 消息** + `X-Hermes-Session-Id: ql_<sessionId>` 头；历史由 Hermes 从 state.db 按 sessionId 续接（微信通道同款机制）
- 所有 provider（deepseek/mimo/**local/Ollama**）统一走 Hermes 9123，靠 body 里 `provider` 字段精确路由
- Agent 工具循环也交给 Hermes `run_conversation`（86+ 工具），走 SSE 流式；`_hermes_stream_worker` 保留 `_maybe_push`/`_maybe_push_app` 推送链
- 回退路径保留：`_agent_loop`/`tool_executor`/防复读函数仅作回退（用户要求可回退，不删）

**② bot 模式废除**：`_apply_bot` 函数、`_build_messages` bot 分支、`stream_start` bot 字段处理全部移除（后端忽略 bot 字段保持兼容）。

**③ 验证**：
- 普通路径 E2E PASS：让记住 `/opt/data/qingliao_ios/HANDOFF.md` → 回复"已记住" → 第二轮问路径 → 精确复述
- Agent 路径 E2E PASS：「查内存」→ Hermes 工具循环返回真实 NAS 数据（19.8G/已用5.6G/可用14.2G/28%）
- code review 7 项全过；`_hermes_stream_worker` 确认推送链保留
- 容器重建后 `_use_hermes_session()=True` 生效；compose 第24行加 `STREAM_HERMES_SESSION=1`

**④ 部署**：备份 `.bak327`；compose 加 env；`docker rm -f + docker compose up -d` 重建容器（⚠️ 裸 `docker start` 不应用 compose 改动）。**方案C 后端与 iOS 无耦合（sessionId 已在 iOS 稳定持久），iOS 无需改动。**

### v3.2.5（2026-09-03 后端已部署重启：复读补强——状态播报型 assistant 也压）

> 背景：用户反馈"正常交流中间会插一段已回复过的查内存回复"。v3.2.4 的 `_compress_long_assistants` 只压 **超长(>80字)** assistant，而"查内存/CPU/温度/容器"这类**工具播报型结语约 50-60 字(<80)**逃过压缩、又不在紧贴最新user的 `msgs[-2]`（`_break_repeat_seed` 也漏）→ 原文进上下文被模型整段复述 + 顺杆爬（"现在有空间了，我来整理记忆"）。

**改动（仅 `stream_api.py`）**：
- 新增 `_is_status_verbose(text)` + `_STATUS_VERBOSE_RE`：识别系统状态播报句（内存/CPU/SSD/磁盘/负载 + 已用/可用/占比/GB/MB/°C 等数据特征；或服务器/容器状态）
- `_compress_long_assistants` 压缩条件扩展：`len>80` **或** `_is_status_verbose` → 一律压为占位（无论长短）
- **验证**（容器内实测）：`_is_status_verbose("内存：共19.4GB，已用5.6GB，可用13.8GB（28%）")`=True；`_is_status_verbose("你好呀，今天天气不错")`=False；含播报句的 assistant 被压缩为占位 ✓
- 部署：备份 `.bak325`，md5=`8b0cf62f`，`docker stop/start` 重启，容器 `CONT_SYNTAX_OK`
- ⚠️ 误伤权衡：状态播报句本就不承载可持续对话信息（每轮可重新生成），压掉仅防复读，不影响正常对话
- **iOS v3.2.4 发版通道（2026-09-03 转 svg 成功，⚠️ 修正 v3.2.1 前旧认知）**：`apple` remote 原写权限 token（**值不记录**；该 token 已失效需换新 PAT）**已失效**（push 403 / ls-remote Auth failed）；`.gh_cred` 的 token 属 **lxm20060513-svg**（读 apple 仓库 OK 但无写，push 报 `denied to lxm20060513-svg`）。**结论：svg 仓库(origin) 也是可用的发版通道**——svg 是 `public`（无 private 额度限制）、CI 至今健康（v3.1.8 2026-09-03 02:02 还在 svg 成功）、workflow unsigned 不嵌签名 secret、svg token 有写权限。**本次 v3.2.4 即走 svg 发版成功**（tag 推 `origin`，run 33776506689 success，IPA 校验 3.2.4/399 通过，md5 `cc1ca046` 转存 NAS）。下次发版优先 svg（origin）；仅当 svg 出问题时才需 apple 新 PAT。

### v3.2.4（2026-09-03 已发版 svg：语音转文字回归最原始基线）

> 背景：用户反馈 v3.2.3/398 后"触发语音转文字还是会卡死，偶尔不卡死也转不出文字"，拍板"去掉系统降噪功能回归最原始"；中途确认**语音模式流光动画保留**。

**① `VoiceRecorder.swift` 回归 v3.0.85 前最简基线（核心）**
- **去掉 `.voiceChat` 系统降噪/回声消除**（v3.0.85/9-01 引入，语音问题时间线起点——卡死即此后被报）
- **去掉 `.playAndRecord + .defaultToSpeaker`**（v3.1.4 引入）与 **后台异步配置**（v3.1.7 引入）
- 改回 `setCategory(.record, mode: .default)` **同步** start/stop：触发即录、松手必有文件
- 修复"偶尔转不出文字"根因：v3.1.7 异步化后松手太快 → `stop()=nil` → 静默吞掉（无提示无文字）；同步后此路径消除
- 删除死代码 `stopCurrentSegment()/resumeSegment()`（v3.0.77 起整段录音，无调用者）
- ⚠️ **v3.1.2/3.1.4/3.1.7 三轮音频层修复方向均被 v3.2.4 回退**——v3.2.3 的 .ips 铁证卡死根因在渲染层（流光阴影 stroker），音频会话阻塞（100ms-1s 卡顿层）≠ 5s 冻结。回归 .record 同步开销极小，主线程无感知

**② `ChatInputBar.swift` 录音中 UI 静态化**
- 去掉 v3.0.85 加的录音计时器（0.1s TimelineView 驱动 `recordingDuration`）+ 1Hz 红点闪烁
- 回归静态"红点 + 松开上屏"（v3.0.85 前样式），删 `recordingStartTime/recordingDuration/formatDuration`
- **流光保留**：`(streaming || voiceMode)` 均启用（用户拍板）。voiceMode 期间唯一动态视图即此流光，无 shadow 不触发 stroker；卡死防护靠 v3.2.3 三件套（流光无 shadow + 15fps + 外层阴影静态化在 overlay 前）

**③ 版本号**：project.yml 3.2.4 / 399（4 处同步）。全量 swiftc 语法预检通过。**2026-09-03 已发版（svg 通道）**：tag `v3.2.4` 推 `origin`，run 33776506689 success，IPA 校验 3.2.4/399 通过，md5 `cc1ca046` 转存 NAS `轻聊app/qingliao-3.2.4.ipa`。

### v3.2.3（2026-09-03 已发版 398，commit `6698364`：语音转文字卡死真根因定案——渲染层，非音频层）

- **现象**：任意语音入口（智能球/输入框/发送键长按）触发 → 整 App 无响应每次必现；v3.1.2/3.1.4/3.1.7 三轮音频层修复全无效
- **决定性证据**：用户 iPhone 系统 `.ips` watchdog 日志（bug_type 309 / 0x8BADF00D / FRONTBOARD kill 5s）主线程栈：`ShapeLayerShadowHelper.updateShadow → Path.cgPath → RB::Path::Mapper::add_rounded_rect → CG::stroker::path_stroke_round_cube_offset` 自我递归（SIGKILL 捕不到，App 崩溃上报拿不到此栈，只能让用户从「设置→隐私→分析与改进→分析数据」导 qingliao 开头 .ips）
- **根因**：voiceMode 激活输入栏流光 overlay（TimelineView 30fps 每帧重建圆角 Capsule 渐变）+ 流光自带 `.shadow(6)` + 外层整栏 `.shadow(14)` 双叠 → 每帧逼 iOS 27 stroker 重算圆角阴影路径 → 病态递归 100% CPU 主线程冻结。Circle 阴影走不同 mapper 不触发（球态 30fps 呼吸不卡的原因）
- **修复（仅 ChatInputBar.swift）三件套**：① 流光层去 `.shadow` ② 30fps→15fps ③ 外层 `.shadow(radius 14)` modifier 移到 `.overlay{流光}` 之前（`.background → .shadow → .overlay(动态层)` 顺序 = 阴影只覆盖静态层）
- **类级教训**：「每帧变化的视图 + .shadow」是 iOS 27 主线程卡死高危组合；排查"整 App 无响应"先分崩溃 vs 卡死（卡死=系统 .ips bug_type 309；崩溃看 Documents 下 **crash_pending_sig.json**（信号/abort 类，v3.9.10 起从 crash_pending.json 分出来，配套 crash_stack.txt）+ **crash_pending.json**（NSException 类）；解析失败的文件会被隔离成 `*.bad` / `*.corrupt-*` 留证不删），主线程栈只能靠导 .ips

### v3.2.2（2026-09-03 已发版 397：回复+推送重复根治——用户拍板"在看也推 + App端去重"）

- App `InboxStore.shouldSkipDuplicate` 加 `extra: stream.content` 兜底（流式回复一定在 stream.content，即使 chat.messages 暂缺也能命中去重，稳住去重竞态）
- 后端 `_maybe_push_app` 曾试加"用户在看则不推"门控（`lastPoll` 判断）→ **按用户意愿回滚**为"完成即推"（用户明确"希望在看也推"，重复由 App 端拦截）。`.bak322gate` 留档
- ⚠️ 修正踩坑第 10 条：最终方案不是门控，是"完成即推 + App 端 stream.content 兜底去重"

### v3.1.7（2026-09-03 已发版：语音卡死修复 + 502修复 + SiriBall长按语音）
> ⚠️ **① 的音频层异步化方案已被 v3.2.4 整体回退**（真根因是 v3.2.3 定案的渲染层，且异步化引入"松手太快 stop()=nil 静默吞掉"新问题）。保留此记录仅作历史；接手语音问题先读 v3.2.4/v3.2.3。

**① 语音转文字卡死修复**（`VoiceRecorder.swift`）：
- **根因**：`start()` 中 `AVAudioSession.setCategory(.playAndRecord)` + `setActive(true)` 在主线程同步执行，首次调用初始化音频管线阻塞 100-500ms → UI 冻结
- **修复**：音频会话配置移到 `DispatchQueue.global(qos: .userInitiated)` 后台线程，UI 立即切换到录音状态（`isRecording=true`），录音就绪后自动开始
- `stop()` 的 `setActive(false)` 也移到后台线程，避免阻塞主线程
- `settings` 字典在 `Task { @MainActor }` 闭包内创建，避免 Swift 6 跨 actor 数据竞争

**② SiriBall 长按语音入口**（`ChatEffects.swift` + `ChatInputBar.swift`）：
- `SiriBallView` 新增 `onLongPress` / `voiceEnabled` 参数
- 手势改为 `ExclusiveGesture(LongPressGesture(0.4s), TapGesture())`：长按进入语音转文字，单击展开输入框
- `ChatInputBar` 传入 `onLongPress: { onVoiceModeToggle() }` + `voiceEnabled`

**③ 后端 502 修复**（`stream_api.py` + `unified_router.py`）：
- `unified_router.py` 路由表新增 `/api/agent/tool → stream_api.StreamHandler`（此前被路由到 `agent_api` 模块，无此端点）
- `stream_api.py` `/api/agent/tool` 端点两个 bug：
  - `path` 未定义 → 改为 `self.path`（`NameError` → 500）
  - `rfile` 二次读取 → 使用已解析的 `data` 变量（body 已被上游消费）

### v3.2.1（2026-09-03 已发版 App + 已部署后端：复读根治 + agentEnabled 双保险 + Agent 400 修复）

**① App agentEnabled 双保险**（`QingliaoApp.swift` + `AuthStore.swift`）：
- **根因**：设置页「Agent 智能回复」用 `@AppStorage(...) var agentOn = true`（默认值只在 UI 层生效不写盘），而 `AuthStore.streamStart` 用 `UserDefaults.standard.bool(forKey:)` 读取——**key 从未被写入 UserDefaults 时返回 false** → UI 显示"开"但请求发 `agentEnabled: false` → 后端 `agent_on=False` 走普通 LLM
- **修复**：
  - `QingliaoApp.init()` 加 `UserDefaults.standard.register(defaults: [UserDefaultsKey.agentEnabled: true])`（key 缺失兜底 true）
  - `AuthStore.streamStart()` 改为 `(UserDefaults.standard.object(forKey:) as? Bool) ?? true`（双保险，不误伤用户显式关闭）

**② 后端复读根治**（`stream_api.py`，v3.2.1 已上线即时生效）：
- **根因**（msg_debug `[04:02:53]` 铁证）：模型会"续写"最新 user 前紧贴的那条**旧 assistant 长回复**（如"好的，简要说明我的上下文理解机制..."整段被原样复活），而非回答新问题。v3.1.12 的 `_sanitize_history` 只保证"列表以 user 结尾"，没处理"最新 user 前紧贴的 assistant"；且把 v3.1.10 的 KEEP_MSGS=2 放宽到 6，诱因重新进入上下文 → 复读回退
- **修复**：
  - 新增 `_break_repeat_seed(msgs)`：把最新 user 前紧贴的 assistant 压缩为占位"（上一轮回复已省略，请直接回答最新用户消息，不要续写或复述此条内容）"，断掉续写素材。普通模式 + Agent 模式两路统一调用
  - 新增 `_log_sent_messages(tag, msgs)`：恢复 `stream_msg_debug.log` 诊断写点（v3.1.12 曾删除，导致无法观察部署后发给模型的内容）
  - 本机上一条 stream_api.py 增改：`_break_repeat_seed` = 定义+2调用共3处，`_log_sent_messages` = 定义+3调用共4处

**③ Agent 模式 400 Bad Request 修复**（`stream_api.py`，已部署）：
- **根因**（`/tmp/stream_agent_debug.log [13:29:18]` 铁证）：`agent_on=True is_agent=True model=mimo-v2.5 provider=xiaomi` —— `_worker` 把聊天主模型 model/provider（mimo/xiaomi）传给 `_agent_loop`，Agent 带 `tools` 参数请求 → **mimo-v2.5 不支持 OpenAI 原生 tool calling** → 400
- **症结**：v3.0.30 把 Agent 模型改成"跟随设置页选定模型"（回归），背离 v3.1.8 已验证的"Agent 恒用 deepseek（支持 tool calling）"
- **修复**：`_worker` 调用改 `_agent_loop(st["messages"], task)`——不再传 model/provider，`_agent_endpoint(None,None)` 回退 AGENT_URL（deepseek）
- **验证**：容器内 `_agent_endpoint(None,None)` 返回 `deepseek-chat` ✓
- **⚠️ 前提（决定性）**：v3.2.1 后端修复要真正生效，**必须重建镜像**——容器实际跑的是镜像内 `COPY backend/` 固化的 `/app/backend`（非宿主 bind mount）。本会话曾因只改宿主 backend + 重建容器，导致复读/Agent400 修复"始终不生效"；后 `docker build` 重建镜像 + `compose up -d` 才真正加载。详见踩坑经验第16条。

### v3.2.0（2026-09-03 已发版：后台推送恢复）

- 后端 v3.1.13 恢复 `_maybe_push_app` 函数 + 5 挂载（v3.1.x 防复读迭代重写 `_worker` 时丢失全部挂载 → App 收不到 AI 回复完成推送）
- iOS 修 `triggerFastPoll` 死代码（消费 `fastPollRemaining`）+ 本地/云端流式完成触发快拉

### v3.1.12（2026-09-03 已部署后端，iOS v3.1.9/394 已发版：防复读根治）

- 后端 `_sanitize_history()`：剔脏占位（⚠️/HTTP Error/连接中断/请求失败/网络错误/Unauthorized/无返回内容）+ 连续相同 assistant 去重 + 保证以 user 结尾
- `KEEP_MSGS=6` 轮次收窄（`STREAM_KEEP_MSGS` 可调），旧历史 system 标记占位
- 恢复引导型 system prompt（"每次回复只针对用户最新一条消息...不要重复、复述或续写"）
- Agent 入口 `_agent_loop` 同规则净化
- ⚠️ **教训**：v3.1.11 改写 `_build_messages` 时误删了 v3.1.10 的"始终只保留最近2条"逻辑 → 防复读回退，用户反馈仍复读。**"始终没解决"必须拉线上代码比对声称部署的修复是否真在**（版本迭代会静默删上轮修复）

### v3.1.11（2026-09-03）：base_sys=[] 清空 + 禁用 memory 注入（误删 v3.1.10 截断逻辑 → 复读回退）

### v3.1.10（2026-09-03）：防复读根治（始终截断到最近2条）+ 中文引号修复 + Agent 关键词扩展

### v3.1.9（2026-09-03）：防复读 v1（8条限制+关键词检测+prompt指令）→ 被 v3.1.10 替代

### v3.1.8（2026-09-03 已发版）：Agent 模式用 deepseek 替代 mimo-v2.5（tool calling 支持）+ Agent 循环安全阀 + 对话历史限制10条

### v3.1.6（2026-09-02 已发版：Agent工具链对齐Hermes + 全量Hermes模式）

**① 新增10个NAS桥接工具**（`LocalToolRunner.swift` + `tool_executor.py`）：
- `web_extract`、`patch_file`、`todo`、`image_generate`、`text_to_speech`
- `terminal`、`process`、`cronjob`、`video_generate`、`video_analyze`
- 经 `POST /api/agent/tool` 调 NAS 后端执行，写操作需用户确认弹窗

**② 全量 Hermes 模式**（`stream_api.py`）：
- 新增 `hermesMode` 开关（App 端传递），开启时 `_hermes_full_agent()` 整个 agent loop 交给 Hermes 9123
- 一次性获得全部 86+ 工具（browser/clarify/MCP 等有状态工具）
- `_agent_loop()` 返回 `(content, enriched_msgs)` 元组，保留完整工具调用历史

**③ 后端配套**（`stream_api.py`）：
- `_build_messages()` 智能摘要：超40条消息时用当前模型压缩旧消息为200字摘要
- system prompt 改为引导性指令（"回答要有内容"）替代限制性指令（"不要输出思考过程"）
- 推理模型自动带 `reasoning_effort: medium`

### v3.1.5（2026-09-02 已发版：上下文丢失修复 + 智能摘要 + Agent工具链对齐Hermes）


**① App 启动自动加载上次会话**（解决"重启后忘记上下文"）：
- `ChatStore.swift` 新增 `loadLastSession(auth:)` — 从后端/本地存储自动加载当前 sessionId 的消息
- `QingliaoApp.swift` `.task` 登录后调用，让 `historyPayload()` 有上下文可发
- 云端模式从 `CloudSessionStore`（init 已加载）直接取；本地模式拉 `/api/sessions/list`

**② 后端智能摘要替代硬截断**（长对话不再丢弃旧上下文）：
- `_summarize_old_messages()` — 超40条消息时用当前模型压缩旧消息为200字摘要
- `_summary_cache` — 缓存防重复摘要；摘要失败自动 fallback 到旧逻辑

**③ System prompt 对齐 Hermes 风格**（模型从"闲聊助手"变为"高效执行者"）：
- 普通模式：从"你是轻聊的 AI 助手，用中文简洁友好地回答"改为"智能、高效、直接...对于任务型请求，直接执行并给出结果"
- Agent 模式：明确列出6类工具能力 + 环境感知（"运行在 NAS 上，/volume1 直接可访问"）+ 行为约束（"用户说帮我做X时直接调用工具"）

**④ Agent 工具链扩展**（10→16个工具，接近 Hermes 完整能力）：
- `web_search`：DuckDuckGo 搜索（免费无需 key）
- `read_file`：读取文件内容（支持 offset/limit）
- `write_file`：写入文件（自动创建目录）
- `list_files`：列出目录内容
- `search_files`：按文件名搜索
- `execute_code`：执行 Python/Shell 代码（30秒超时）
- `delegate_task`：委派子 Agent（通过 Hermes gateway）

**⑤ v3.1.7 修复：Agent 上下文污染**（模型回复旧答案问题）：
- **根因**：`_agent_loop` 返回的 `agent_msgs`（含旧工具调用+system prompt）被 `_build_messages` 优先使用，导致旧上下文混入新请求，模型忽略新消息
- **修复**：移除 `st["agent_msgs"]` 跨请求持久化，`_build_messages` 始终用原始 `st["messages"]`
- **效果**：每次请求独立，模型只看当前对话历史，不会被旧内容带跑偏

### v3.1.4（2026-09-02 已发版：语音转文字卡死修复）

- 去掉主线程 `setActive(.voiceChat)` AEC 阻塞，改用 `.playAndRecord`
- 删除 v3.1.2 并发预热（引入竞争 + `stop()` 致 `voiceChatReady` 失真）
- `VoiceRecorder.swift` 改动

### v3.1.3（2026-09-02 已发版：finish()防重入）

- 修复 poll+recover 竞态导致 `onFinished` 重复触发队列发送
- `StreamClient.swift` 改动

### v3.1.2（2026-09-02 已发版：语音触发卡死）

- `.voiceChat` 后台预热 + 主线程不阻塞 + 降级兜底
- 后被 v3.1.4 取代（删除并发预热方案）

### v3.1.1（2026-08-31 已发版：去省略号 + 移除进度卡 + 用量卡片修复）

**① 去除 AI 长回复折叠省略号**：用户反馈"AI 回复用…省略很多文字"——ChatMessageBubble 的 v2.0.65/v3.0.50 超长折叠逻辑（单段落 >600 字符 → 只显示 5 行 + "展开全文"）已**整体移除**，长回复完整渲染全文，删 `aiExpanded`/`foldThreshold`/`isLongMsg` 死代码（注意删折叠分支时的括号配对）。

**② 移除 v3.1.0 Agent 任务进度卡**（用户实测"废话有点多"）：功能整体拿掉——
- 后端：`stream_api.py` 的 `TOOL_STEP_TEXT`/`_agent_loop` 步骤上报/`step_cb` 回调/poll `steps` 字段**全部还原**（线上 `.bak-v310-20260831` 是 v3.1.0 版勿用于还原；按 4 处反 patch 还原）
- App：`git revert bdd8249` —— `AgentStep.swift` 删除、`AuthStore.streamPoll` 还原 5 元组、`StreamClient.steps` 移除、`CloudToolLoop.toolStep` 移除、`ChatView` 步骤卡 UI/事件/`stepsExpanded` 移除
- 保留：v3.0.90 收件箱推送去重竞态修复

**③ 模型用量卡片修复（"新增 API 自动生成用量卡片"）**：
- 根因：`usage_api.collect_usage()` 只遍历后端 config.yaml providers 段；App 云端模式新增的 API 存 App 本地（UserDefaults/Keychain），后端无记录 → 看板不出卡片
- 后端（已部署重启）：`usage_api.py` 合并 `custom_providers.json`（App「自定义模型组」通道新增自动出卡片）+ 新增 `query_siliconflow()` 硅基流动余额（官方 GET /v1/user/info，balance/totalBalance/chargeBalance）+ deepseek/stepfun 的 key 优先取自定义
- App（95d91ba）：`DashboardView.loadProviderUsage` 合并 `CloudConfig.providers`（云端模式本地新增 → 补 unsupported 卡片"控制台查看"），新增 API 必出卡片

**后端配套（与进度卡无关，保留）**：auth_config.json 密码哈希错位根治（8-25 重置因 pbkdf2_hmac 误用 .hexdigest() 失败遗留，人人登不进）→ 已重置为容器 env 密码 `Qingliao@2026x` + 重启；**用户 App 下次重新登录需用此密码**（用户名 `qingliao`，非 admin）。


### v3.0.90（2026-08-31 待发版，收件箱推送去重竞态修复）

修复 v3.0.88 去重的**时序竞态**：后端 AI 回复 done 即 `_maybe_push_app` 推收件箱，而 App 流式回复要等 `done → finish → upsertAssistant` 才落库；InboxStore 独立 15s 轮询若抢在落库前拉到推送，`shouldSkipDuplicate` 遍历不到这条回复 → 误判不重复 → 重复注入（AI 回答气泡 + 🔔推送气泡同内容）。改为**流式进行中本轮不注入**（不 markDone，消息留队列），流结束 15s 后下一轮比对必命中。

| 改动 | 文件 | 说明 |
|---|---|---|
| 流式感知去重 | `Core/InboxStore.swift` | attach 注入 `StreamClient`（weak），`pollOnce` 注入前 `if stream.isStreaming { return }`——避开「推送已入队、回复未落库」窗口 |
| attach 传参 | `QingliaoApp.swift` | `InboxStore.shared.attach(auth:chat:stream:)` |

关键点：`finish()` 同步置 `isStreaming=false` 后立即同步调 `onFinished` → `upsertAssistant` 落库，故看到 `isStreaming=false` 时消息必已落库，无二次竞态。云端模式（App 直连不走后端）无推送链路不受影响。自检：`check_swift.sh` 全绿。版本号 3.0.90 / 385。

### v3.0.89（2026-08-31 后端热改，推送完整内容）
后端 `_maybe_push_app` 取消 150 字截断：用户反馈推送气泡里内容被 `…` 省略致缺失。改为 `inbox_api.push(content)` 推**完整回复**（保留换行/段落）。已 `docker restart qingliao` 部署生效（线上 `grep brief[:150]`=0、`push(content)`=1），**无需重发 App**。注意与 `_maybe_push`（推微信，仍保留摘要）区分——只有 App 收件箱推送去截断。

### v3.0.88（2026-08-31 发版，推送去重 v2）

修复 v3.0.87 去重因**空白格式不匹配失效**：后端 `_maybe_push_app` 用 `re.sub(r"\s+"," ",...)` 把回复压成单行摘要，而会话流式回复 `content` 保留换行/段落，直接 `contains` 比对匹配不上 → 仍重复注入。改为**双方先压缩空白再双向比对 + 截断前缀兜底**。

| 改动 | 文件 | 说明 |
|---|---|---|
| 去重空白规范化 | `Core/InboxStore.swift` | `shouldSkipDuplicate` 加 `normalizeWhitespace`（换行/多空格→单空格），`cm.contains(core) || core.contains(cm)`，并加 `core.count>=10 && cm.hasPrefix(core)` 截断前缀兜底 |

自检：`check_swift.sh` 全绿。版本号 3.0.88 / 384。

### v3.0.87（2026-08-31 发版，收件箱推送去重）

修复「AI回复与推送重复」：AI 回复完成后端 `_maybe_push_app` 会把摘要推收件箱，App InboxStore 又注入当前会话 → 同一条回复出现两次（流式气泡 + 🔔推送气泡）。App 端注入前按「当前会话最后一条 assistant(非推送) 是否已含推送正文」去重，重复则仅标记已读不注入。

| 改动 | 文件 | 说明 |
|---|---|---|
| 收件箱推送去重 | `Core/InboxStore.swift` | `shouldSkipDuplicate(push:in:)`：当前会话最后一条 assistant(非推送) 文本已含推送正文（去尾部省略号）→ 判定重复，跳过注入仅标已读。修复流式回复 + 🔔推送重复显示 |

自检：`check_swift.sh` 全绿。版本号 3.0.87 / 383。

### v3.0.86（2026-08-31 发版，401 修复）

token 迁 Keychain 遗漏「升级用户」：UserDefaults 仍留旧 token、Keychain 为空时，init 只从 Keychain 读 → token 空但 isLoggedIn 仍 true → 接口全 401（stream start 等）。补迁移兜底 + 强制回登录页。

| 改动 | 文件 | 说明 |
|---|---|---|
| token 迁移兜底 | `Core/AuthStore.swift` | init：Keychain 优先；空则回退 UserDefaults 旧 token 迁入 Keychain 并清明文残留；仍空且已登录 → 强制 isLoggedIn=false 回登录页 |

自检：`check_swift.sh` 全绿。版本号 3.0.86 / 382。

### v3.0.85（2026-08-30 发版，P0#4/6/7 + P1#8/#13）

code review 第二轮落地：云端功能修复 + 安全加固 + 工具循环崩溃修复。**P1#9（云端流无法停止）/ #10（不走 resolveModel）本轮不做**。

| 改动 | 文件 | 说明 |
|---|---|---|
| P0#6 云端 regenerate 误打本地 | `Features/Chat/ChatView.swift` | `regenerate()` 加 `isCloudMode` 分支 → 云端走 `startCloudStream`（原直接 `stream.start` 打本地 NAS，云端重生成全废） |
| P0#7 云端 sendFile 误打本地 | `Features/Chat/ChatViewExport.swift` | 云端文件消息走 `startCloudStream`；`startCloudStream` private→internal 供跨文件 extension 调用 |
| P0#4 本地 token 明文存 UserDefaults | `Core/AuthStore.swift` + `ChatView.swift` | NAS token 迁 **Keychain**（kSecClassGenericPassword），UserDefaults 只留登录布尔；login/logout/后台刷新三处同步改，并清历史明文残留 |
| P1#8 云端工具 content:nil 序列化崩溃 | `Core/CloudToolLoop.swift` | 两处 `"content": nil` 入 `[String:Any]` 字典（JSONSerialization 必崩），改为为空时不写键 |
| P1#13 consumedIds 不持久化 | `Core/InboxStore.swift` | consumedIds 从内存 Set 改 **UserDefaults 持久化**（上限 200），重启不再重复注入/重复通知 |

自检：`check_swift.sh` 三项全绿。版本号升 3.0.85 / 381。

### v3.0.84（2026-08-30 发版，P0#3/#P0#2 修复）

code review 三项高危中的两项落地（P0#1 SafariRelay token 泄漏待定深度）。核心：**isPush 推送消息不再污染模型上下文 + 标签持久化**。

| 改动 | 文件 | 说明 |
|---|---|---|
| isPush 过滤出模型上下文 | `Core/ChatStore.swift` | `historyPayload()` 新增 `messages.filter { !$0.isPush }`——推送消息（Hermes 注入的不该喂模型）不再作为历史发给模型；保留在会话 UI 展示 |
| isPush/agent 读回 | `Core/Models.swift` | `ChatMessage.parse()` 补读 `isPush`/`agent`（此前读回丢失，重开 App 标签消失） |
| isPush/agent 落库 | `Core/ChatStore.swift` | `saveToServer()` msgsPayload 补 `isPush`/`agent`（本地模式写后端） |
| isPush/agent 云端落库 | `Core/CloudSessionStore.swift` | `saveChat()` + `persist()` 两处序列化补 `isPush`/`agent`（云端模式） |
| rename 补 isPush/agent | `Features/Sessions/SessionsView.swift` | `rename()` 回传 messages 的 map 补 `isPush`/`agent`（防改名后推送标记丢失，同时修 P0#2 串库导致标记不一致） |

自检：`check_swift.sh` 三项全绿（语法 / parseResponse 单测 / relay 编解码单测）。版本号升 3.0.84 / 380。

### v3.0.83（2026-08-30 已发版）

Hermes 主动推送收件箱（inbox）：让 Hermes 能主动推消息给轻聊App（此前 App 只有"请求-响应"模型，服务端无法主动塞消息）。

| 改动 | 文件 | 说明 |
|---|---|---|
| 后端收件箱 API | `inbox_api.py`（NAS 新增） | GET /api/inbox（App 轮询拉取）、POST /api/inbox/{id}/done（标记已读）、POST /api/inbox/push（Hermes 主动推，鉴权 X-Inbox-Token）；存储 inbox_queue.json，复用 push_api 的 RLock 队列模式 |
| 后端路由挂载 | `unified_router.py`（NAS） | 路由表加 `/api/inbox`（已验证容器日志 `[router] /api/inbox -> inbox_api.Handler: ok`） |
| **AI回复完成→推App收件箱** | `stream_api.py`（NAS） | 新增 `_maybe_push_app(st)`：AI 回复 done 且内容≥1字就调 inbox_api.push(摘要)（**不受"用户是否在看/pushEnabled"门控，每条都推**，用户选方案A）。5 个 done 路径 + 2 个异常兜底都挂载（error/cancelled 不推） |
| **推理模型流式兼容** | `stream_api.py`（NAS） | 三处流式 delta 解析 `.get("content")` → `content 优先，空则回退 reasoning_content`。修复 App 用 stepfun step-3.7-flash 等推理模型时空回复（正文在 reasoning_content，旧逻辑只取 content） |
| App 收件箱轮询 | `InboxStore.swift`（新增） | 每 15s 轮询 /api/inbox，拉到消息 → 注入当前会话（assistant+isPush）→ 弹本地通知 → 标记已读 → 保存会话；方案B（进当前聊天会话，用户确认） |
| 推送标记字段 | `Models.swift` | ChatMessage 加 `isPush: Bool` |
| 推送标签 UI | `ChatMessageBubble.swift` | isPush 消息气泡显示「🔔 推送」蓝色小标签（区别于渐变"Agent 回复"） |
| App 注入与轮询 | `QingliaoApp.swift` | @State inbox + .task 里 attach(auth,chat:)+startPolling() + scenePhase 前台恢复 refreshOnActive() |
| 鉴权加固 | `docker-compose.yml`（NAS） | 注入 192-bit 强 `QL_INBOX_TOKEN`（旧默认 ql-inbox-default 已失效 401） |
| Hermes 推送入口 | `profiles/wechat-profile/scripts/ql_push_app.sh` | Hermes/cron 主动推：`ql_push_app.sh "消息"` 或 stdin |

> ✅ 后端已全部上线验证：inbox_api + 路由 + stream_api 的 `_maybe_push_app` + QL_INBOX_TOKEN 强 token + ql_push_app.sh（md5 一致 / docker restart / 端口回读 / 容器日志 / 端到端 `[push] App收件箱推送 True: 已推送`）。App 端已过 check_swift.sh（v3.0.83 已发版，用户装 v3.0.83 IPA 真机）。Hermes→App 主动推送 + AI回复→App收件箱 双双打通。

### v3.0.79（2026-08-30 已发版）

| 改动 | 文件 | 说明 |
|---|---|---|
| 语音转文字 WiFi 分流修复 | `AuthStore.swift` | asrTranscribe 加 isCellular 分流：蜂窝走 CFStream /r/asr（已通）；WiFi 走 URLSession /api/asr——修复「蜂窝能转写、WiFi 仍报太短」（根因：asrTranscribe 漏网络分流） |
| 点按空白处停止录音 | `ChatView.swift` | 录音中（voiceMode&&isRecording）点消息区空白处 → exitVoiceMode（停止+转写），补上 exitVoiceMode 注释原本的「按钮/空白点击共用」 |
| 版本号 | `project.yml` | 3.0.79 / build 376 |
### v3.0.78（2026-08-29 已发版）

| 改动 | 文件 | 说明 |
|---|---|---|
| 录音链路诊断版 | `VoiceRecorder.swift`+`ChatView.swift` | record()返回值/文件大小/data计数/App版本显示于"录音太短"弹窗——用户反馈讲很久仍太短，先诊断录音拿不到数据的具体环节（record未开始/文件读不到/数据小），据以根治 |
| 版本号 | `project.yml` | 3.0.78 / build 375 |
### v3.0.77（2026-08-29 已发版）

| 改动 | 文件 | 说明 |
|---|---|---|
| 语音转文字根治 | `ChatView.swift` | 回退 v3.0.36 分段流式，改回整段录音一次转写——分段每 2s stop/resume（局部/独立文件名）导致段音频读不到、恒判"录音太短"，讲多久都失败 |
| 钉一钉存储弹窗对齐 | `SettingsView.swift` | 由系统 .alert 改为 App 统一底部 .sheet（对齐 PasswordSheet/ModelSheet 风格） |
| 版本号 | `project.yml` | 3.0.77 / build 374 |
### v3.0.76（2026-08-29 已发版）

| 改动 | 文件 | 说明 |
|---|---|---|
| 语音转文字修复 | `VoiceRecorder.swift` | 回退 v3.0.74 破坏录音的 setActive(false,.notifyOthersOnDeactivation)（录音采不到字节）+ 分段录音改独立文件名（杜绝 stop/resume 同一文件的数据竞争/读到空段） |
| 语音转文字不跳球 | `ChatComponents.swift` | voiceMode 期间保持输入框形态（v3.0.68 收球逻辑会在语音转文字期间收成智能球） |
| 版本号 | `project.yml` | 3.0.76 / build 373 |
### v3.0.75（2026-08-29 已发版）

| 改动 | 文件 | 说明 |
|---|---|---|
| 自定义 provider 模型组 | `SettingsView.swift` | App 模型管理页新增「自定义模型」区块 + 添加表单，用户自主增删模型组（Base URL / API Key / 模型名），免更新 App |
| 后端自定义 provider 接口 | `stream_api.py` | 存储 + 聚合合并 + GET/POST /api/stream/custom-providers；本地 AI 聊天 `_agent_endpoint`/`_worker` 均支持自定义 provider |
| 版本号 | `project.yml` | 3.0.75 / build 372 |
### v3.0.74（2026-08-29 已发版）

钉一钉功能完整实现 + 后台流式恢复 + tab 切换动画 + 录音修复。

| 改动 | 文件 | 说明 |
|---|---|---|
| 钉一钉数据层 | `PinStore.swift` | CRUD + NAS JSON 持久化（pin_write/pin_read API）+ UserDefaults 兜底 |
| 钉一钉卡片 | `PinCard.swift` | 长卡片组件（对齐看板风格），长按菜单：复制内容 / 删除 |
| 钉一钉看板集成 | `DashboardView.swift` | 路由器下方显示钉一钉区段（始终显示，空态有引导文案）；.task 加载 NAS 数据 |
| 钉一钉聊天集成 | `ChatComponents.swift` | MessageBlockView + MessageBubble 的 onPin 参数（传当前段落文字） |
| 钉一钉聊天调用 | `ChatView.swift` | 长按菜单「钉一钉」→ 钉当前段落到看板 |
| 钉一钉设置 | `SettingsView.swift` | 数据与自动化 section 新增「钉一钉存储」路径编辑 |
| 后端 API | `files_api.py`（NAS） | POST /api/files/pin_write + GET /api/files/pin_read（base64 JSON） |
| 后台流式恢复 | `StreamClient.swift` | restartPolling()：后台回来停旧 Task + 起新轮询 |
| 后台流式恢复 | `QingliaoApp.swift` | scenePhase .active 时检查 isStreaming && !isDone → 调 restartPolling |
| 录音修复 | `VoiceRecorder.swift` | 录音前先 setActive(false) 释放旧音频会话（解决多次录音后 setCategory 失败） |
| tab 切换动画 | `DockTabView.swift` | TabTransitionModifier：scaleEffect 0.97→1 + 0.2s easeInOut（保留原生玻璃 tab bar） |
| AuthStore 注入 | `PinStore.swift` + `QingliaoApp.swift` | weak var auth + attach(auth:) 注入式（替代 AuthStore.shared） |
| 版本号 | `project.yml` | 3.0.73 → 3.0.74（build 371） |

### v3.0.73（2026-08-29 已发版）

智能球语音功能全部移除（-335 行），仅保留核心交互。

| 改动 | 文件 | 说明 |
|---|---|---|
| SiriBallView 精简 | `ChatComponents.swift` | 移除 isRecording/voiceMode/transcribing/isSpeaking/onLongPress/onRelease + LongPressGesture/DragGesture；保留点击展开输入框 + 思考动画 |
| ChatInputBar 参数清理 | `ChatComponents.swift` | 移除 onBallLongPress/onRelease/voiceChatActive/onExitVoiceChat/isSpeaking + onChange(of: transcribing) 自动展开 |
| ChatView 语音对讲清理 | `ChatView.swift` | 移除 voiceCommandMode/voiceChatActive/voiceTurns/voiceStream/isAiSpeaking/pendingVoiceSpeak 状态 + startVoiceCommand/handleVoiceChatLongPress/exitVoiceChat/startVoiceReply/speakVoiceChat/stopVoiceStream 等函数 |
| 灰色遮罩清除 | `ChatView.swift` | 移除 Color.black.opacity(0.15) overlay + messageList .background(Color.clear) |
| 保留：输入栏语音转文字 | `ChatComponents.swift` + `ChatView.swift` | 发送键长按 / 输入框长按 → toggleVoiceMode → 录音 → 松手停止 → ASR 转写上屏 |
| 保留：键盘收起自动回球 | `ChatComponents.swift` | onChange(of: kbEnv.isVisible) 键盘收起 + 输入框空 → 自动收回成球 |
| 版本号 | `project.yml` | 3.0.72 → 3.0.73（build 370） |

### v3.0.72（2026-08-28 已发版，被 v3.0.73 取代）

| 改动 | 文件 | 说明 |
|---|---|---|
| 透明 overlay 松手修复 | `ChatView.swift` | overlay 改 allowsHitTesting(false)；恢复球的 DragGesture 检测松手。根因：透明拦截层(.contentShape+.onTapGesture)覆盖全屏，SwiftUI 把手指抬起事件路由到 overlay 的 onTapGesture |

### v3.0.71（2026-08-28 已发版，被 v3.0.72 取代）

| 改动 | 文件 | 说明 |
|---|---|---|
| 语音录音松手继续 | `ChatComponents.swift` | 移除 SiriBallView DragGesture.onEnded 松手停止录音逻辑 |
| voiceChatActive 透明层 | `ChatView.swift` | 放开 voiceChatActive 时隐藏点击退出层的限制 |

### v3.0.70（2026-08-28 已发版）

| 改动 | 文件 | 说明 |
|---|---|---|
| 语音对讲松手修复 | `ChatComponents.swift` | ChatView 调用 ChatInputBar 时漏传 isRecording，导致 SiriBallView 的 DragGesture.onEnded 松手检测与声波粒子分支全因 isRecording 恒 false 静默失效。补传 isRecording: voiceRecorder.isRecording |
| 后端 nginx /api/tts | nginx conf | 三个轻聊 server 块补 /api/tts → 9132 location |

### v3.0.69（2026-08-28 已发版）

| 改动 | 文件 | 说明 |
|---|---|---|
| 语音对讲浮层 | `ChatComponents.swift` + `ChatView.swift` | 声波涟漪粒子 + TTS 模型选择（小米mimo/智谱glm-tts）+ 键盘回球 |

### v3.0.68（2026-08-28 已发版）

| 改动 | 文件 | 说明 |
|---|---|---|
| 神经 TTS | `ChatComponents.swift` + `ChatView.swift` | 语音对讲多轮 + 粒子拟人表情 |

### v3.0.67（2026-08-27 已发版）

| 改动 | 文件 | 说明 |
|---|---|---|
| 输入框与键盘留 10pt | `ChatView.swift` | `.padding(.bottom, kb.isVisible ? 0 : 10)` 改常量 10——键盘也要留隙 |
| 版本号 | `project.yml` | 3.0.66 → 3.0.67（build 364） |

### v3.0.66（2026-08-27 已发版）

| 改动 | 文件 | 说明 |
|---|---|---|
| 输入框与 dock 留 10pt | `ChatView.swift` | 键盘收起时留 10pt 呼吸间距 |
| 智能球与 dock 间距 | `ChatComponents.swift` | 球态自 padding 4→0，间隙由外层统一留 |
| 版本号 | `project.yml` | 3.0.65 → 3.0.66（build 363） |

### v3.0.65（2026-08-27 已发版）

| 改动 | 文件 | 说明 |
|---|---|---|
| 输入框贴键盘 | `ChatView.swift` | 移除手动键盘高度 padding，改原生键盘避让 |
| 移除 Dock 设置项 | `SettingsView.swift` + `CloudSettingsView.swift` | 移除「隐藏 Dock 栏」开关 + 「Dock 透明度」滑条 + DockVisibility 死类 |
| 版本号 | `project.yml` | 3.0.64 → 3.0.65（build 362，修复 build 号漂移） |

### v3.0.64（2026-08-27 已发版）

| 改动 | 文件 | 说明 |
|---|---|---|
| Dock 改原生 TabView | `DockTabView.swift` | 弃自定义 DockBar，改用 iOS 26 系统 TabView 原生液态玻璃 tab bar。用户拍板定版。 |

> **Dock 演进复盘**：v3.0.61 恢复真液态玻璃 → v3.0.62 每 tab 各自 glassEffect（否决）→ v3.0.63 整条玻璃+手动按压（嫌弃非原生）→ v3.0.64 改用系统原生 tab bar。**核心结论：要原生液态玻璃别手搓，直接上 iOS 26 系统组件。**

### v3.0.59-63（2026-08-27 已发版）

详见 v3.0.64 演进复盘。主要改动：流式气泡文本截断修复 / 智谱 GLM 模型 / 灵动岛发光微调 / 免费模型开关 / 云端厂商删除。

### v3.0.51（2026-08-26 已发版）

| 改动 | 文件 | 说明 |
|---|---|---|
| 多气泡段落流式 | `ChatComponents.swift` + `ChatView.swift` | AI 长回复按空行拆成多个独立气泡 |
| 图片持久化增强 | `ChatStore.swift` + `ChatView.swift` | retryPendingImageUploads 指数退避重传 |
| 长会话分页 | `ChatView.swift` | 极长会话只渲染尾部 300 条 + 顶部「加载更早」 |
| 会话标签 | `SessionTagStore.swift` + `SessionsView.swift` | 预置 工作/学习/生活 + 自定义，彩色小胶囊 |

### v3.0.50（2026-08-25 已发版）

| 改动 | 文件 | 说明 |
|---|---|---|
| 扫码球整体移除 | `ScanOrbView.swift`(整删) + 多文件 | 用户拍板「全部拿掉」；保留 SiriBallView 智能球 |
| ChatMessage.id 稳定化 | `Models.swift` | djb2 稳定哈希替代 content.hashValue |
| StreamClient 竞态修复 | `StreamClient.swift` | generation 递增防旧流污染新流 |
| 超长消息折叠 | `ChatComponents.swift` | >600 字 AI 消息默认折叠 |

### v3.0.49 及更早

详见历史版本记录。

---

## 三、CI/CD 发包流程

> ⚠️ 2026-09-03 修正：**svg(origin) 是可用的发版通道（本次 v3.2.4 走 svg 成功）**，且 token 有效无需额外操作；apple 是备用通道（token 已失效需换新 PAT）。**优先推 svg(origin)**。

### 触发条件

`feature/handoff-301` 分支上推送 `v*` tag 到 **origin(svg)** 会自动触发 `.github/workflows/build-ios.yml`（查 CI 状态查 `lxm20060513-svg/qingliao-ios`；该仓库 public 无额度限制、CI 无签名 secret、svg token 有写权限）。

### 完整流程

```bash
# 1. 进入本地仓库（主副本，发版用这份；勿放 /tmp 会被重启清空）
cd /opt/data/qingliao_ios

# 2. check_swift 语法检查（全量 parse + 单测）
bash check_swift.sh

# 3. 改版本号（project.yml **8 处**同步：主 App + 挂件 target 各 4 处 —— CFBundleShortVersionString / CFBundleVersion / MARKETING_VERSION / CURRENT_PROJECT_VERSION）
#    ⚠️ SideStore 同名覆盖不生效——版本号必须递增
#    ⚠️ 新增任何 target（如 widget/extension）都要给它写 Info.plist 版本号，否则 XcodeGen 默认 1.0/1

# 4. commit + 推 svg(origin)（token 内嵌 origin remote URL，直接 push 即可）
git add -A && git commit -m "fix: ... (vX.Y.Z)"
git tag vX.Y.Z
git -c http.version=HTTP/1.1 -c http.lowSpeedLimit=0 -c http.lowSpeedTime=999 push origin feature/handoff-301:feature/handoff-301 vX.Y.Z

# 5. 等 CI 完成（~15-20 分钟），盯 svg 仓库 runs（token 从 .gh_cred 读）：
TOKEN=$(cat /opt/data/.gh_cred|tr -d ' \n')
curl -s -H "Authorization: token $TOKEN" "https://api.github.com/repos/lxm20060513-svg/qingliao-ios/actions/runs?per_page=3"

# 6. 下载 IPA（artifact 302 重定向到 Azure blob，urllib 会 403，用 curl -sSL + Bearer + Accept json）：
curl -sSL -o artifact.zip -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" <archive_download_url>
#    解包得 qingliao-2.0-unsigned.ipa → 必须校验 Info.plist 的 CFBundleShortVersionString == tag 版本（v2.0.53 教训）
# 7. 转存 NAS：SFTP put 到 docker/hermes/_upload.ipa → sudo cp(chmod 644) 到 轻聊app/qingliao-<ver>.ipa → md5sum 两端比对
```

### 关键点

- **project.yml 版本号 8 处**（**主 App + 挂件扩展各 4 处**，v3.8.0 起加挂件后翻倍）：MARKETING_VERSION / CURRENT_PROJECT_VERSION / CFBundleShortVersionString / CFBundleVersion；**两套必须逐字一致**，漏改挂件那套 → CI Verify 的版本一致性断言失败
- **发版主通道 = `origin`(svg)**：tag 推 `origin`（v3.4.x~v3.9.12 全走这条成功）；`apple` = lxm20060513-apple/qingliao-ios 是**备用通道**（origin runner 卡住/额度耗尽时才换）。⚠️ 2026-09-13 核对：本条此前写成「发版走 apple」是**旧认知已过时**，与同文件 51/55 行矛盾，以本行为准
- **NAS SFTP chroot**：根目录是 `/volume1/`，SFTP 用相对路径 `docker/hermes/...`（写绝对路径会双写前缀 `/volume1/volume1/` → ENOENT）
- **NAS 上传**：SFTP put 到 `docker/hermes/_upload.ipa` → sudo cp（用 `/bin/cp` 或 `\cp` 绕 `cp -i` 别名，防 overwrite 交互卡死）到目标 → chmod 644
- **NAS 凭据**：`/opt/data/.nas_cred`（单行纯密码，含 @ 勿截断）
- **GitHub 凭据**：两个 remote URL 都内嵌 token（`git remote get-url origin` / `git config --get remote.apple.url`，取冒号后 40 位；**勿写入任何文档**）；`/opt/data/.gh_cred` 可能过期，优先用 remote URL 里的
- **git push 重试**：`for i in $(seq 1 8); do git -c http.version=HTTP/1.1 ... && break; sleep 10; done`
- **盯 CI cron**：构建成功后删 cron，勿空转复读
- **现役「盯 CI + 下载 + 校验 + 转存」一条龙脚本**（2026-09-13 核实）：`python3 /opt/data/scripts/ql_release/watch_ci.py <tag> <ver> <build>`（加 `--check` 只查一次状态；输出末尾固定 `RESULT=...` 便于外部判定）。⚠️ 技能里提到的 `watch_ci_352.py` 是旧名，现已通用化，别再找那个文件名
- **Swift 预检**：`export HOME=/opt/data/home LD_LIBRARY_PATH=/opt/data/swift-libs && /opt/data/swift-toolchain/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swiftc -parse <files>`（或 bash check_swift.sh）

---
