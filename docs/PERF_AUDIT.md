# 轻聊 iOS — 性能 / 省电 / 死代码 / 瘦身 体检报告

> 触发：用户「针对性能优化，省电，死代码，瘦身这些都看一下有没有优化空间」（2026-09-11）
> 方式：全仓量化取证（103 个 Swift 文件 / 31,820 行）+ IPA 实测体积；**本报告只出结论，代码尚未改动**
> 结论一句话：**App 已经很省**——真正值得动的只有 3 件事（1 个省电大项 + 1 个省电小项 + 2 处真死配置），
> **瘦身没有任何值得做的空间**。
>
> ## ⚠️ 报告已更正（同日）
> 初版把 `qingliao_local_model` / `qingliao_push_weixin` 判为「真死设置」，**这是误报**。根因：脚本只统计了
> **属性在自己文件内**的引用次数，而 `SettingsViewSections.swift` / `SettingsViewHelpers.swift` 是
> `extension SettingsView {}` —— **跨文件扩展用法被漏掉**。全仓复验结果：
> - `localModelOn` 活（8 处 / 3 文件，Toggle + POST `/api/local/toggle`，后端 `local_api.py` 在线）
> - `pushWeixin` 活（6 处 / 3 文件，Toggle + POST `/api/push/settings`，后端 `push_api.py` → relay → Hermes 微信网关在线）
> - 其余 6 个「冗余声明」同样全部是活的（跨文件扩展）
> - **真死的只有 2 个**：`mainProvider`（AgentModelSheet 内声明、全仓 0 引用）与
>   `NSLocationWhenInUseUsageDescription`（无任何 `CLLocationManager`）
> 教训已写进 `codebase-audit` 技能：**属性/类型引用必须全仓统计，先确认目标类型不是跨文件 `extension`**。

## 一、体积实测（瘦身维度）

| 项 | 数值 | 判读 |
|---|---|---|
| IPA 总大小 | **2.58 MB** | 极小（同体量 App 通常 20–80MB） |
| 主二进制（解压） | 5.83 MB | 31,820 行 Swift，正常 |
| `Assets.car` | **144 KB** | 只有 AppIcon（浅/深 1024）+ AboutLogo，无冗余素材 |
| 挂件 `.appex` | 91 KB | 实时活动挂件，符合预期 |
| 外部字体 / 大图 / 多余 framework | **无** | — |
| dSYM 是否进包 | **无**（CI 单独产出） | ✅ |

**结论：瘦身维度不建议做任何改造。** 删死代码只省几 KB，为省几十 KB 做重构属于净负收益。
真要更小，唯一有意义的是「上 App Store 用 Asset Catalog 压缩 + bitcode/ABI 无关」——侧载链路用不上。

## 二、省电 / 性能

### 值得改（2 项）

| # | 级别 | 位置 | 问题（取证） | 建议 | 依据 |
|---|---|---|---|---|---|
| P1 | **中** | `Theme/LiquidGlass.swift:201` `SiriGlowOverlay`、`:250` `IslandGlowOverlay` | 两处都用 `TimelineView(.animation)`（**系统全帧率，ProMotion 最高 120fps**），每帧重绘「AngularGradient + mask(Path) 全屏挖洞 + blur(8)」；两个开关可**同时**打开 → 流式回答时是全场最贵的画面 | 改成 `.animation(minimumInterval: 1.0/30.0)`（呼吸是 0.55s 慢正弦，30fps 肉眼无差） | 仓库已有同款先例：`ChatEffects.swift:24` 全屏粒子注释「锁 60fps…ProMotion 120Hz 下每帧全屏 Canvas 重绘开销大」；`OrbEngine.swift:208` 也是 30fps |
| P2 | 低 | `Features/Chat/ChatView.swift:2080` `busyProbeLoop()` | 6s 一次的「服务器真相」探针挂在 `.task {}` 上，只在视图销毁时取消；**App 进后台视图不销毁 → 每 6s 仍发请求**直到系统挂起 | 循环内加 `scenePhase == .active` 判断，后台跳过本轮 | 现有 `QingliaoApp.swift:51` 已有 scenePhase 写法可复用；后台跳过一次请求既省电也少一次注定超时的调用 |

### 已达标，不要动（避免"为改而改"）

| 面 | 现状（取证） |
|---|---|
| 图片链路 | `Core/ImageCache.swift`：ImageIO `CGImageSourceCreateThumbnailAtIndex` 下采样 + NSCache LRU；发送前 `resizeImage` 压到 **480px / 0.45**（`ChatView.swift:2658` 注释「body ~20KB，提高蜂窝直连通过率」）——省内存/省流量都已做到位 |
| 流式渲染（红线） | 打字机 **48ms** tick + `visibleMessagesCache`（只在数量变化时重建 O(visible)）+ `ChatMessage: Equatable` 快照 → 未变更行不重绘。`ChatView.swift:246-273` |
| DateFormatter | `Models.swift:163/465/471` 已改 **static let 缓存**，注释写明「原每次调用创建新实例，列表滚动时大量浪费」 |
| 轮询 | 看板/生活各 30s，且由 `isActive` 直传门控（切走 = task 取消即停，隐藏页零轮询）；`InboxStore` 有 `refreshOnActive/stopPolling` 前台恢复机制 |
| 帧率分级 | dock 智能球**空闲 15fps / 思考 30fps**（`ChatEffects.swift:143-145` 注释写明「省电」）；输入栏 15fps；粒子 30fps 有意锁 |
| 冷路径 DateFormatter | `ChatComponents.swift:792` 导出页 `formattedDate` 每次访问新建 —— 只在一张卡片渲染时用到，属冷路径，不值得改 |
| 后台模式 | `project.yml` **未声明任何 UIBackgroundModes**（无 audio/location/voip 常驻）→ 系统正常挂起，省电正确 |
| NSLog 20 处 / print 7 处 | **这是唯一的真机诊断通道**（本机无 Xcode、只能装机看），不要清理 |

## 三、死代码 / 死配置

| # | 级别 | 位置 | 取证（全仓） | 状态 |
|---|---|---|---|---|
| D1 | ✅ 无需处理 | `SettingsView.swift` `@AppStorage("qingliao_local_model") localModelOn` | 活：SettingsViewSections 里就是「本地模型」开关本体（Toggle + 失败回滚 + POST `/api/local/toggle`） | **初版误报**，功能一直是通的 |
| D2 | ✅ 无需处理 | `SettingsView.swift` `@AppStorage("qingliao_push_weixin") pushWeixin` | 活：SettingsViewSections:156 `Toggle("微信推送")` + POST `/api/push/settings`；后端 `push_api.py` → hermes relay → 微信网关 | **初版误报** |
| D3 | 低 → **已修** | `project.yml` `NSLocationWhenInUseUsageDescription` | 全仓无 `CLLocationManager` / `startUpdatingLocation`（定位已改人工城市） | 死权限串，已删除 |
| D4 | 低 → **已修** | `Features/Settings/SettingsModelSheets.swift` `@AppStorage("qingliao_provider") mainProvider` | 声明于 `AgentModelSheet`，全仓引用 **0** 次（同文件用的是 `agentProvider` / `mainModel`） | 真死属性，已删除 |
| D5 | — | 类型级扫描（含缩进声明复扫） | **0 个**死类型 | ✅ |
| D6 | — | private func 扫描 | **0 个**从未调用 | ✅ |
| D7 | — | 注释掉的代码 | 仅 3 处 | ✅ |

> 结论：**死代码基本没有**。唯一真死的两处都是配置级（一个权限串 + 一个冗余 @AppStorage），已在本轮清掉。

## 四、执行状态（本轮已全部落地，攒进 v3.9.1）

1. ✅ **P1 发光特效 30fps**：`LiquidGlass.swift` SiriGlowOverlay / IslandGlowOverlay 两处
   `TimelineView(.animation)` → `.animation(minimumInterval: 1/30)`（与粒子「锁 30fps」同约定）
2. ✅ **P2 后台停探针**：`ChatView.busyProbeLoop()` 加 `scenePhase == .active` 门控
3. ✅ **D3 死权限串**删除（project.yml `NSLocationWhenInUseUsageDescription`）
4. ✅ **D4 真死属性**删除（`mainProvider`）
5. ⛔ **D1/D2 无需处理**：用户答「接上功能」，但复验发现**功能本来就是通的**（初版误报）→ 不做改动

## 五、本报告未覆盖的范围（诚实声明）

- 真机实测功耗/帧率：本机无 Xcode/SDK，**只能做静态取证**，P1 的省电幅度是机理推断（全帧率 → 30fps、两层叠加 → 仍两层），
  没有 Instruments 数据；要量化需在真机上用 Xcode Instruments / 设置-电池 对比。
- 后端（Python `轻聊web`）与 NAS 侧未在本次范围内。
