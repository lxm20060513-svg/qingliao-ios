# 轻聊 UI 打磨方案（v3.9.0）

> 用户诉求（2026-09-11）：**「针对优化一下UI，让界面更美观，动画更灵动」**
> 决策：① 排版做**全量**收敛 ② zoom 转场组**由我定** ③ **引入**轻量骨架屏
> 状态：**本文件 + 批 1 已落地**；批 2/3/4/5 进行中。零 CI 推送，版本号仍为 3.8.0（v3.8.1 攒着的改动不受影响）。

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
| **1** | 硬编码 spring → `Motion` 令牌（6 处）+ `symbolEffect` 补 5 处 | 极低 | ✅ 已完成 |
| **2** | 空间连续性 zoom 转场：聊天消息→大爆炸、生活资讯→大爆炸、看板卡→详情弹窗 | 低（原生语义，失效即退化为普通转场） | 🔄 进行中 |
| **3** | 滚动深度：`scrollTransition`（聊天/生活/看板）+ 聊天 `defaultScrollAnchor(.bottom)`（单独验证） | 中 | ⏳ |
| **4** | 排版全量收敛：15 档 → 6 档语义字阶 | 中（全站逐屏看） | ⏳ |
| **5** | 轻量骨架屏（列表/卡片加载态），替换现有"转圈/空白" | 中 | ⏳ |

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
