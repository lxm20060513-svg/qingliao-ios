# 轻聊 UI 打磨方案（v3.9.0）

> 用户诉求（2026-09-11）：**「针对优化一下UI，让界面更美观，动画更灵动」**
> 决策：① 排版做**全量**收敛 ② zoom 转场组**由我定** ③ **引入**轻量骨架屏
> 状态：**批 1–5 全部落地**（本机预检七步全绿逐批通过）。**未推 CI、未打 tag**，版本号仍为 3.8.0，
> v3.8.1 攒着的两项改动不受影响；这批 UI 工作算 v3.9.0，攒着一起发。

## 零、体检数据（grep 取证，不是感觉）

| 指标 | 数值 | 判读 |
|---|---|---|
| `deploymentTarget` | **26.0** / Swift 6 | 下列 API **全部无需 @available 门控** |
| 动效令牌 `Motion`（tap/snap/settle/emerge/flow） | v3.4.29 已建 | 框架在，但引用率低 |
| 残留硬编码 spring | 9 处 | 节奏不齐 = 观感"发黏"的机械根因 |
| `symbolEffect` | 5 处 | 系统微交互几乎没用起来 |
| `matchedGeometryEffect` | **0** | 无空间连续性 |
| `navigationTransition(.zoom)` | **1**（图片查看器） | 全站唯一 |
| `scrollTransition` | **1**（会话列表） | 长列表无滚动深度 |
| `defaultScrollAnchor` | **0** | 聊天首帧贴底靠脚本 scrollTo |
| `sensoryFeedback` | 0（旧式 Haptic 18 处） | 工作正常 → **不动** |
| 字号档位 | **15 档**（11/12/13 三档共 424 处） | 层级糊 —— "更美观"的最大头 |
| `NavigationLink` | **0** | 全站无 push 导航 → zoom 只能走 fullScreenCover / sheet |

## 一、分批方案（每批单独提交、单独可 revert）

| 批 | 内容 | 风险 | 状态 |
|---|---|---|---|
| **1** | 硬编码 spring → `Motion` 令牌（6 处）+ `symbolEffect` 补 5 处 | 极低 | ✅ 提交 `3a7373e` |
| **2** | 空间连续性 zoom 转场：聊天消息→大爆炸、生活资讯→大爆炸、看板 6 卡→详情弹窗 | 低（失效即退化普通转场） | ✅ 提交 `40d5f4c` |
| **3** | 滚动层次感令牌化 + 看板/生活卡片滚动深度 | 低 | ✅ 提交 `06c1c87` |
| **4** | 字号全量令牌化：**22 档 → 8 档**，749 处 / 46 文件 | 中（全站逐屏看） | ✅ 提交 `a675f9b` |
| **5** | 轻量骨架屏（会话列表 / 生活卡片 / Docker 容器首屏加载） | 中 | ✅ 本提交 |

## 二、批 1 落地明细（diff）

| 文件:行 | 原 | 现 | 语义依据 |
|---|---|---|---|
| `ChatView.swift` 附件面板 toggle | `spring(0.3, 0.2)` | `Motion.settle` | 面板进入 → settle |
| `ChatView.swift` 归档提示显隐 | `spring(0.3, 0.1)` | `Motion.settle` | 提示条出现 → settle |
| `ChatView.swift` 排队消息插入 | `spring(0.25, 0.15)` | `Motion.settle` | 列表插入 → settle |
| `ChatView.swift` 队列插入（发送中） | `spring(0.25, 0.15)` | `Motion.settle` | 同上 |
| `ChatView.swift` 单条消息插入 | `spring(0.25, 0.15)` | `Motion.settle` | 同上 |
| `ChatView.swift` 附件菜单关闭 | `spring(0.3, 0.2)` | `Motion.settle` | 面板退出 → settle |
| `BigBangView.swift` 词块选中切换 | `spring(0.25, 0.3)` | `Motion.snap` | 小状态变化 → snap |
| `DashboardView.swift` DeviceCard 图标 | — | `+ .symbolEffect(.bounce, value: status)` | 开关状态变化弹一下 |
| `DashboardView.swift` ServiceCard 图标 | — | `+ .symbolEffect(.bounce, value: running)` | 服务启停弹一下 |
| `LifeCardsSection.swift` LifeStockCard 图标 | — | `+ .symbolEffect(.bounce, value: stock.detailText)` | 行情刷新弹一下 |
| `DiagnosticsView.swift` 复制按钮 | — | `+ .symbolEffect(.bounce, value: copied)` | 复制成功弹一下 |
| `AgentResultCard.swift` 状态图标 | — | `+ .symbolEffect(.bounce, value: card.status?.text ?? "")` | 结果状态更新弹一下 |

### 偏差（有依据，非漏做）

| 计划项 | 实际 | 原因（已验证） |
|---|---|---|
| 发牌弹出发射动画也归一 | **保留原值** `spring(0.45, bounce 0.35)` | 这是刻意的"发牌"高回弹效果，令牌 emerge 的 extraBounce 0.08 会把观感压瘪 → 按"刻意不同的动画不动"处理 |
| `SplashView` 启动动画 | **保留原值** `spring(0.85)` | 启动页节奏独立，不套令牌（既有约定） |
| `ChatView` 键盘联动、`repeatForever` 循环 | **保留原值** | 同上 |
| symbolEffect 补到 ~12 处 | 实际 +5 | 另 2 个候选点（Docker 刷新图标、Diagnostics 刷新图标）**没有现成的加载态变量**，为它们新增 @State 属于"没收益的状态污染" → 不加 |

## 三、明确**别动**（已定稿的美术方向，本轮不重开讨论）

Siri 呼吸光晕（22pt 光带 / blur 8 / 不旋转）· Dock 用系统原生 `TabView`（不再手搓 glassEffect）·
弹窗不用玻璃、列表用毛玻璃 · 卡片 16 圆角 + 0.8pt 描边 · 开关绿底小号 / 二元控件 Capsule ·
启动动画 0.85s · 键盘联动曲线 · `repeatForever` 循环 · **流式渲染路径（48ms 打字机 tick、首 token 平滑）绝对不碰** ·
触感体系不动（旧式 Haptic 工作正常，改声明式只有 churn 无收益）。

## 四、验证纪律

- 本机**无 Xcode/SDK** → 只能 `./check_swift.sh`（`-parse` 语法级 + 单元测试）；类型/实参序/并发错误**只有 CI 真编译能暴露**。
- 动手前 grep 全部调用点，确认新参数被真实透传（透明 Optional 默认值会静默关掉分支）。
- 真机手感与观感**必须由用户确认**——本文件不声称已验证视觉效果。
- **用户点头前不推 CI**；积攒发版。


## 五、批 3 / 4 / 5 落地明细

### 批 3 — 滚动层次感
- `Theme/LiquidGlass.swift` 新增 `ScrollDepth` + `.scrollDepth()`：把原先只有会话列表手写的 `0.965 / 0.75` 收进一处令牌。
- 挂在 **组件内部**（DeviceCard / ServiceCard / MeterCard / LifeStockCard 的 `.dashboardCard()` 之后）=
  等价于挂在列表行上，**各调用点零改动**；不在 Lazy 容器里时自动 no-op。
- `SessionsView` 行内实现改为复用 `.scrollDepth()`（行为不变，数值同源）。

### 批 4 — 字号令牌化（22 档 → 8 档）
| 令牌 | 值 | 吸收原档位 | 处数 |
|---|---|---|---|
| `tiny` | 10 | 7.5 / 8.5 / 9 / 9.5 / 10 / 10.5 | 87 |
| `caption` | 11 | 11 / 11.5 | 162 |
| `subhead` | 13 | 12 / 12.5 / 13 / 13.5 | 276 |
| `body` | 15 | 14 / 15 | 141 |
| `title` | 17 | 16 / 17 | 36 |
| `headline` | 20 | 18 / 19 / 20 | 20 |
| `titleXL` | 24 | 22 / 24 | 18 |
| `display` | 28 | 26 / 28 / 30 | 9 |

≥32 的 11 处（启动页 76 / 34、登录大图标 52、空态插画 40、任务中心 44）为**装饰字号，保持原值**。

### 批 5 — 轻量骨架屏
- 新增 `Theme/Skeleton.swift`：`SkeletonBlock`（呼吸灰块，opacity 循环，**不用 TimelineView**，尊重「减弱动态效果」）+
  `SkeletonCard`（与 `.dashboardCard()` 同圆角 16）+ `SkeletonRow`。
- 接入 3 个首屏加载面：会话列表（原转圈）、生活卡片（原"加载中…"小字）、Docker 容器列表（原来"暂无容器"会与加载混淆）。
- **失败/未接线路径一律不变**（仍走原有小字降级，"不空白、不转圈卡住"的约定保持）。

## 六、偏差表（全部有验证依据，非漏做）

| 计划项 | 实际 | 原因 |
|---|---|---|
| 字号收敛到 6 档 | 实际 **8 档** | 代码里 18/19/20 与 22/24 混用广泛，硬压会让卡片标题/大数字变形；**每处移动 ≤2pt** 是刻意的风险控制（本机无 SDK、无法目视验证）。要更狠的收敛应在真机逐屏确认后单独做一轮 |
| 聊天消息行加滚动动效 | **不加** | 流式渲染路径是红线：滚动动效会叠加在 48ms 打字机 tick 上（用户最在意的性能/稳定性） |
| 聊天 `defaultScrollAnchor(.bottom)` | **不做** | 可能与既有 `ScrollViewReader + scrollTo` 首帧贴底逻辑相互打架；现有逻辑已保证贴底，"为改而改"风险大于收益 |
| 看板加骨架屏 | **不加** | 看板数据是逐字段刷新（NAS/HA 多路并发），没有整体 loading 态；强行加会与"部分数据已到"的状态冲突 |
| symbolEffect 补到 ~12 处 | 实际 +5 | 另 2 个候选点没有现成的加载态变量，为它们新增 @State 是无收益的状态污染 |

## 七、待真机验证清单（本机只能语法级验证）

1. zoom 转场：看板 6 张卡 → 详情弹窗（**sheet 上 zoom 是否生效需实测**，仓库内已有先例只有 fullScreenCover）；聊天气泡 → 大爆炸；生活资讯行 → 大爆炸。
2. 字号收敛后**逐屏看有没有截断/换行**：会话列表、看板卡片、设置页（SettingsModelSheets 改了 84 处）、生活卡片（51 处）。
3. 滚动层次感在看板/生活网格里是否顺滑（低端机是否会掉帧）。
4. 骨架屏首次加载观感；「减弱动态效果」开启时是否静态。
5. 动效节奏：附件面板、消息插入、BigBang 词块选中的手感是否比之前"顺"。
