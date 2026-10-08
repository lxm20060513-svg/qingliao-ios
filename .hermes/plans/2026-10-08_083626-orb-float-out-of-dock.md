# 智慧球从 dock 摘出 · 改动清单（v4.0.80 草案）

**目标：** 把智慧球从 dock 第 3 槽摘出来，浮在 dock 上方居中（球外框 64）；聊天页默认「球态」（点球展开输入框）；设置里新增「显示智慧球」+ 逐个 tab 显隐开关（聊天不可藏，最少剩 1 槽）。

**基准版本：** 4.0.78 / build 634（`4c7348a`）
**性质：** 计划模式 —— 本文件只出清单，不动任何应用代码。

---

## 一、代码现状（已核准的事实，含行号）

| 事实 | 位置 |
| --- | --- |
| `DockTab.chat.slotIndex == 2`，注释明写「球必须留在第 3 槽，几何按 slotIndex 硬编码」 | `Features/DockTabView.swift:7,10-11` |
| `dockSlotCount = 5`（硬编码常量） | `Features/DockTabView.swift:92` |
| 聊天槽 iPhone 分支：`tabItem { Text("").accessibilityLabel("聊天") }` → 槽位视觉为空，球由浮层盖在上面 | `Features/DockTabView.swift:189` |
| 球几何唯一真源：`DockOrbOverlay.orbCenterGlobal / ballCenterFromBottom`（读真实 UITabBar 槽位坐标 + bar 高） | `Features/Chat/ChatEffects.swift:234+` |
| 球径 `defaultBallSize = 52` | `Features/Chat/ChatEffects.swift:241` |
| iPad 宽屏 `orbInDock = hSize != .regular` → 宽屏不画球、用系统 message 图标 | `Features/DockTabView.swift:90,171` |
| 球心（几何真源）的 5 处消费者 | 球体/命中层（`ChatEffects.swift`、`OrbQuickMenu.swift:189`）、菜单锚点 `:792`、识别浮层锚点 `:872`、烟花原点 `:1011`（`ballCenterFromBottom(index: 2, count: dockSlotCount)`） |
| 设置里唯一 dock 相关项：「烟花粒子特效」`qingliao_dock_burst` | `Features/Settings/SettingsCommon.swift:893,925` |
| 输入栏整体 `chatComposerArea`（上方是互斥浮条槽位：记账/记忆/待发队列/去重） | `Features/Chat/ChatView.swift:1635,1915` |
| 输入栏内部已有 `onGeometryChange` 上报先例（思考档位胶囊） | `Features/Chat/ChatInputBar.swift:374` |
| 子视图向上回报宿主已有通道先例（通知，因 `@State` 宿主摸不到） | `Features/Chat/ChatView.swift:1349` 注释 |

**几何真值（已用 393×852 像素级验证）：** dock 内容高 49 · 安全区 34 · dock 顶边 769 · 输入栏高 50、顶边 715 · 球与下方物恒定 6pt · 球外框 64（球体 50.1）· 5 槽槽位中心 39.3/117.9/196.5/275.1/353.7 · 4 槽 49.1/147.4/245.6/343.9 · 球心恒定 x=196.5。

---

## 二、任务分解（每步可独立编译 + 单独验证）

### Task 1 新增「浮动球几何」真源（不接 UI）

**改：** `Features/Chat/ChatEffects.swift`（`DockOrbOverlay`）

- 新增 `static let floatingBallSize: CGFloat = 64`（原 `defaultBallSize = 52` 保留给旧路径/回退，不改旧值）
- 新增 `static func floatingOrbCenter(ballSize:) -> CGPoint`：`x = 窗口宽/2`，`y = 窗口高 − 安全区 − dockBarHeight − 6 − ballSize/2`
- 旧函数（读槽位坐标的 `orbCenterGlobal` / `ballCenterFromBottom`）**先留着**，Task 2 切完再决定是否删（保留可一键回退）

**验证：** `check_swift.sh` 预检通过；函数纯计算，无 UI 副作用。

### Task 2 球改挂载点 + 聊天槽补回图标

**改：** `Features/DockTabView.swift`、`Features/Chat/ChatEffects.swift`、`Features/OrbQuickMenu.swift`、`Features/OrbIdentifyOverlay.swift`

- `:189` → `tabItem { Label("聊天", systemImage: DockTab.chat.icon) }`（槽位不再留空）
- 5 处消费者统一改用 Task 1 的新真源，**删掉各自的 `slotIndex:` / `count:` 入参**（禁止各算一份，这是这次最容易漏的地方）
- `:1011` 烟花原点：`ballCenterFromBottom(index: 2, count: dockSlotCount)` → 新真源

**验证：** 编译；真机看：球位置（贴 dock 上方 6pt、居中）/ 点球切页 / 长按菜单锚点 / 识别浮层锚点 / 烟花从球心炸开。

### Task 3 tab 逐个显隐 + 动态槽位

**改：** `Features/DockTabView.swift`（+ 常量集中处）

- 新增 5 个 key：`qingliao_tab_visible_{sessions,life,chat,dashboard,settings}`，默认 true；**聊天那个 key 只读不写**（UI 锁定，代码里过滤时强制保留）
- tab 渲染列表按 key 过滤后再交给 TabView（系统自动等分重排）
- **去 `slotIndex` 硬编码**：`:580` / `:646` 的切页微滑方向改按「当前可见列表里的索引差」算（`dx = newIdx > oldIdx ? 22 : -22`）
- **兜底（必须做）**：被隐藏的 tab 正好是当前页 → 在同一 transaction 内自动切到一个仍可见的页（优先级：聊天 → 会话 → 生活 → 看板 → 设置），否则选中项指向不存在的 tab 会白屏

**验证：** 逐个关掉开关后重启，看槽位等分 / 切页方向 / 隐藏当前页时的跳转无闪；确认「聊天」开关点不动。

### Task 4 设置页「底部栏」区块

**改：** `Features/Settings/SettingsCommon.swift`（`dockBurstOn` 那段区块附近）

- 新区块「底部栏」= 6 行：`显示智慧球` + 5 行 tab 开关（聊天行 `disabled` + 灰置）
- 复用既有 `qingliaoSwitch(hideLabel:)` 组件与 `@AppStorage` 写法（与 `:893/:925` 的烟花项同款）

**验证：** 开关即时生效；聊天行点不动；与「烟花粒子特效」互不影响。

### Task 5 聊天页「球态 ↔ 输入框态」（风险最高，单独一轮）

**改：** `Features/Chat/ChatView.swift`（+ 与宿主的回报通道）

- 新增状态 `composerExpanded`（默认 false = 球态）
- 球态：`chatComposerArea` 不渲染输入栏（`:928` 那个挂载点做条件化）
- 点球 → `composerExpanded = true`（是否同时弹键盘需你定：我倾向弹，因为点球是显式意图）
- 回收：**发出消息 && 键盘收起** → 回球态
- 列表底部在球态下加 **+70pt** 留白（否则最后 1~2 条永久被球挡）
- ⚠️ 架构冲突点：球由**宿主的浮层**画（页面级），而切换逻辑在 ChatView 内 → 需要「当前是否要显示球」回传宿主。宿主已有通知通道先例（`:1349` 注释），按同一套走，别新造第二套
- ⚠️ 既有能力影响：附件面板 / 相机 / 语音 / 模型档位 / 待发队列条**全在输入栏内**，球态下都不可见 → 要发图/语音必须先点球展开

**验证：** 真机走一遍：发文字 / 发图 / 语音 / 待发队列回流 / 草稿保存 / 切页后再回来。

### Task 6 提示落点搬家

**改：** `Features/DockTabView.swift`（`orbUnseen` / `orbFailed` 的绘制处）

- 隐藏智慧球时，把「AI 答完 / 失败」提示改落在 **dock 聊天槽的红点**上（球没了就没地方显示）

### Task 7 真值表与文档

- 更新 `ql_dock` / `ql_orbmenu` 域真值表：球心几何（改用不依赖槽位的新真源）、槽位居中、球径 64、tab 显隐
- `HANDOFF / START-HERE` 的 UI 章节同步

---

## 三、影响文件（8 个）

`Features/DockTabView.swift` · `Features/Chat/ChatEffects.swift` · `Features/Chat/ChatView.swift` · `Features/Chat/ChatInputBar.swift` · `Features/OrbQuickMenu.swift` · `Features/OrbIdentifyOverlay.swift` · `Features/Settings/SettingsCommon.swift` · 真值表/文档

---

## 四、风险与待定

| # | 风险 | 说明 |
| --- | --- | --- |
| R1 | 球几何 5 处共享真源 | 漏改一处 = 球看得见、点不到（历史同类故障） |
| R2 | `slotIndex` 硬编码 6 处 | tab 动态化后静默错位，烟花原点这类最隐蔽 |
| R3 | 输入栏收起 | 影响附件/相机/语音/模型档位/待发队列 5 项既有能力，**本次最大不确定项** |
| R4 | iPad 宽屏分支 | `orbInDock = false` 这条路径本次没定：宽屏要不要也浮球？（建议本次宽屏维持现状） |
| Q1 | ~~点球是否同时弹键盘~~ | **已定（用户 2026-10-08）**：点球 = 球变输入框 + 同时弹键盘 |
| Q2 | 「只剩聊天」时聊天图标是否隐掉 | 球与聊天图标同一竖线；本次**维持显示**（后续可单独调） |
| Q3 | ~~iPad 宽屏是否也浮球~~ | **已定（用户 2026-10-08）：维持现状**（宽屏不画球、用系统 message 图标，`orbInDock == false` 那条路一字不动） |

**只能真机定的：** 系统 TabView 动态 tab 集合的重排动画与底部避让；球压列表时的滚动 + 长按共存；键盘弹起时其它页（会话页搜索框）与球的关系。

---

## 五、执行顺序

Task 1 → 2（球位置，可单独装机看）→ 3 + 4（tab 显隐 + 设置）→ 5（聊天页两态，单独一轮）→ 6 → 7。
每步走 `check_swift.sh` 预检 + 真机验收，通过才进下一步。

---

## 六、进度

**2026-10-08 · Task 1 + Task 2 已落地（待预检 + 真机）**

- `ChatEffects.swift`：球径 `defaultBallSize` 52 → **64**；新增 `floatingGap = 6`、`floatingOrbCenter(ballSize:barHeight:)`、
  `floatingBallCenterFromBottom(barHeight:ballSize:)`；`body` 改走浮动球心（不再读槽位坐标）。
- 旧「dock 内容中心差值」一族**整块删除**：`orbCenterGlobal` / `slotCenterGlobal` / `slotContentDrop` /
  `contentCenterDrop` / `dockContentCenterDrop` / `collectTabButtons` / `@State liveCenter`；刷新函数改名
  `refreshMeasuredBarHeight()`（只读 dock 真实高度）。
- 消费者切换：`OrbHitLayer`（去 `slotIndex/slotCount`、命中圈 68 → **80**）· `OrbQuickMenuOverlay`（同上）·
  `OrbIdentifyOverlay.absoluteBallCenter`（同上）· `DockTabView` 的 `DockOrbOverlay` 调用点与**烟花原点**。
- 真值表同步：`ql_orbmenu`（新护栏 = 单出口 + 命名常量 + 旧一族清零 + 命中层/菜单两处共用；`defaultBallSize` 断言 52 → 64）、
  `ql_orb`（烟花原点断言改 `floatingBallCenterFromBottom`）。
- 未做（留给 Task 3）：`DockTab.slotIndex`（切页微滑方向 `:580/:646`）与 `dockSlotCount` 的动态化——
  球已不依赖槽位，但**切页方向**仍读静态槽位序号。

**验证（2026-10-08）**
- `ql ios check`（语法 + switch 穷尽性 + 源护栏）：**全绿**（首轮 4 条哨兵类 ❌ 已修：`DockOrbOverlay(slotIndex: 2` 哨兵 → `DockOrbOverlay(thinking: stream.isStreaming`；`between()` 不含起始串，切片非空断言改 `!menuCall.isEmpty`）。
- `ql test`：`ql_orb` 107/0 ✅ · `ql_dock` 55/0 ✅（新增改 3 条：球心公式 / 烟花原点签名 / 槽位号退役）。
- ⚠️ 另有 9 条红**与本次改动无文件交集**，不是本次造成：`ql_v937`(3) 读的正是 `ChatView.swift`——该文件被**另一会话**在途改（首页备忘速记卡 → `QuickCaptureSheet`，同为 v4.0.80）；`ql_memo`(5) 读 `Features/Life/MemoSection.swift` + 共享卡片组件；`ql_ask_card`(1) 读 `InboxStore` / `ChatQuestionCard` / 后端。

**待办**：Task 3 → 4 → 5 → 6 → 7（等用户定：先出包验 Task 1+2，还是连 Task 3+4 一起）。
