# 轻聊 iOS · 工程治理整改清单（v4.0.x）

盘完 201 个 Swift 文件 / 6.4 万行、19 个真值表目录的实测数据后出的。功能维度已经过剩，
瓶颈在「回归保障 + 代码结构」。每项都可验证，判据写死在判据栏。

现状数据（2026-09-27 实测）：
- 源文件 201 个，6.4 万行；未覆盖文件 130 个（Settings 18 / Chat 14 / Dashboard 9 / Life 7）
- Core 69 个文件，Settings 25 个文件 9667 行；最大 ChatView.swift 4160 行
- 真值表 19 个目录全部挂在 check_swift.sh；本轮抓到 1 个孤儿（ql_life_noprice）
- CI 只有 build-ios.yml 一个 workflow，靠 archive 兜底

## P0 · 本轮已落地并验证

### 1. 护栏覆盖率守卫 ✅ 已完成
- 做什么：新建 scripts/check_guard_coverage.py，挂成 check_swift.sh 第 42 段。
- 判据：① scripts/ql_*/ 每个真值表目录、每个 scripts/*.py 守卫必须被 check_swift.sh 引用，
  否则红；② 真值表里 src()/read() 读到的 qingliao/… 源码路径必须真实存在（负向断言
  fileExists(atPath:) 不算断链）。
- 实测抓到：ql_life_noprice（价格监控移除守卫）从未被调用过 → 已补挂为第 41 段，实跑全绿。
- 验证：./check_swift.sh 42 段全绿，EXIT=0。

### 2. 孤儿守卫补挂 ✅ 已完成
- 做什么：第 41 段接 guard_price_removed.py（价格监控「已删干净 + 未误伤」双向断言，80+ 断言）。
- 判据：价格符号在 App 源码里必须 0 命中，LifeConfig.json 不含 price 键，保留物（stock/rss/
  express/快递卡）必须还在。
- 验证：单跑全绿（80 PASS / 0 FAIL），并在全量预检里通过。

## P1 · 下一步（按收益排序）

### 3. SwiftUI 参数序静态检查 ✅ 已完成
- 落地：scripts/check_swiftui_param_order.py，挂 check_swift.sh 第 43 段（--self-test 双跑）。
- 判据：解析 174 个可断言结构体，扫描 317 个调用点，实参序 ≠ 声明序即红；非成员初始化器标签放行。
- 验证：自测抓到 2 处乱序 + 放过正确序（防解析器假绿），全量 EXIT=0。

### 4. 大文件拆分（ChatView 4160 行 → 目标 ≤1500）🟡 进行中（第 1 刀已落）
- 第 1 刀（纯搬运，零逻辑改动）：9 个顶层独立类型从 ChatView.swift 拆出 5 个文件
  - ChatAppDelegate.swift（通知名单 + QingliaoAppDelegate，145 行）
  - ChatToolStepCards.swift（ToolStepRow / TruncationNote / ProgressNote / SummaryRow，143 行）
  - ChatTOCSheet.swift（WelcomeSuggestion / TOCSheet，53 行）
  - ChatPendingSend.swift（25 行）/ ChatDealAttachmentButton.swift（44 行）
  - ChatView.swift 4160 → 3738 行。
- 拆分踩的坑（已修，判据写进真值表注释）：真值表/单测**硬编码路径读 ChatView.swift 拿「通知名定义」或
  「工具卡 struct 定义」**，文件一搬就假红——本轮实测 4 个真值表 9 条假红（ql_orb / ql_orbmenu /
  ql_toolsteps / ql_progressnote / test_minutes）。修法：定义端读新文件、消费端仍读 ChatView.swift，
  计数类断言改跨文件合计。**教训：拆文件必须同步改真值表路径，且「一真源」断言要按全仓计数，不是按文件。**
- 剩余：ChatView.swift 仍 3738 行（主体是单个 3700+ 行 struct ChatView），要再拆必须做
  computed property → 子视图 + 传参，风险高于纯搬运，需真机复测。暂缓到发版后。
- 判据：xcodegen sources 是整目录 qingliao/（自动收录新文件，无需改 project.yml）；
  ./check_swift.sh 43 段 EXIT=0 已验证。

### 6. Settings 物理合并（25 文件 9667 行 → 8 文件）✅ 已完成（2026-09-27）
- 做什么：走用户拍板的「入口一个不少」路线，只搬文件不改 UI。按领域合 8 个：
  - SettingsCore.swift（SettingsView + Sections + Helpers，主体与分区）929 行
  - SettingsCommon.swift（SettingsSheets + Pages + AppearanceSheet，通用组件/页面/外观）1202 行
  - SettingsModels.swift（ModelSheets + Vision + LocalModels，模型能力）2447 行
  - SettingsAccess.swift（Conn + Secrets + MCP + HA + KB，接入与密钥）1410 行
  - SettingsAgent.swift（Agent 关键词/记忆/AI 记忆）529 行
  - SettingsLifeCards.swift（生活卡片 + 提醒 + 卡片画廊）1590 行
  - SettingsData.swift（文件管理 + 历史 + 桌面快捷）990 行
  - SettingsSystem.swift（诊断 + 权限）675 行
- 合并前预检（这一步不能省）：① 用 git HEAD 版抽出 57 个顶层类型清单，新旧逐一比对，
  丢失/多出均为 0；② 7 个文件级 private 声明跨文件撞名 0（FlowText / UploadDirSheet /
  KBRow / PasteKBSheet / filesFailureReason / FilesManagerRow / FileRenameSheet）。
- 坑：真值表/守卫**按硬编码路径读源码**共 8 处（ql_settings_ui 3 处、ql_homeshortcuts 3 处、
  ql_orb 1、ql_orbmenu 1、check_swift.sh 1、check_action_capabilities 1、ql_life_noprice 1）。
  合并后全部改指新文件；ql_settings_ui 的「目录可枚举 > 10 个文件」门槛改为 >= 8。
  首轮全量跑出的 2 条红正是这类假红（svSrc 指向已删的 SettingsView.swift → 空真）。
- 验证：./check_swift.sh 全量 43 段 EXIT=0，❌/FAIL 计数 0。

## P2 · 中期

### 5. 覆盖缺口三件套
### 7. 未覆盖 130 文件的护栏补齐
### 8. CI 加「预检红则不进 archive」

### 9. Settings 30% 文件零护栏覆盖

## 附：不做的事
- 不做单元测试框架（XCUItest/Tests target）——个人自用没有覆盖需求，护栏脚本这套更划算。
- 不做全量重写，不要「为了架构而架构」。拆分必须保持frame(height:0) 收起闸与协议表面不变。

## 附：开工前待用户拍板
1. 参数序检查覆盖范围：先 3 个文件（ChatView / ChatMessageBubble / ChatComponents）还是全部 Chat 目录
2. 大文件拆分顺序：ChatView(4160) 先拆 还是 DashboardView(2683) 先拆
3. Settings 合并后入口可能变少，是否接受（可发现性 vs 心智负担）

## 附：拆分时的护栏红线
- 收起工具层 frame(height:0) 硬钳不得回退 minHeight（见 memory / skill qingliao-ui-touchups）
- 拆大文件后必须验括号深度（见 skill swiftui-large-view-refactoring）
- 改完攒着不 commit，台账 /opt/data/cache/qingliao_pending_changes.md
