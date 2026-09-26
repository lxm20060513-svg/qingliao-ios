#!/bin/bash
# 轻聊 2.0 本地 Swift 预检（无 Xcode 环境的替代验证）
# 用法: ./check_swift.sh   （在 ql_ipa2 目录下）
# HOME 固定为原路径：不同会话 HOME 变化会导致 clang 模块缓存路径错位（PCH path mismatch / missing SwiftShims）
# v3.9.72：钉死工作目录。各真值表都用**相对路径**读源码（qingliao/… / ../qingliaoWidget/…），
# 从非仓根 cwd 调用会读不到源码——哨兵会红（不会静默假绿），但一样是"环境抖动伪装成回归"。
cd "$(dirname "$0")" || exit 1
export HOME=/opt/data/home
export LD_LIBRARY_PATH=/opt/data/swift-libs
# v3.9.72：固定时区。第 8 步（定时提醒真值表）里有几条断言经 Calendar.current 取分量，
# 而 Swift 测试的 triggerComponents 用的是系统时区——调用方环境里没有 TZ 时会按 GMT 算，
# 于是"每周一 → weekday 2 / 每天 → 只有时分 / 一次性 → 年月日"三条**会随跑的人而红**
# （2026-09-24 实测：终端里（有 TZ）全绿、从 Python subprocess 里（无 TZ）红 3 条）。
# 这类"看起来像回归的环境抖动"最耗人，所以在脚本里钉死，不依赖调用方。
export TZ=Asia/Shanghai
SWIFT=/opt/data/swift-toolchain/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin

# 编译并运行一个单元测试可执行文件：run_unit <产物路径> <swiftc 参数...>
# 🚨 v3.9.41：2–5 步原先直接是「swiftc ... | head -N」+「跑二进制」两行，两个洞叠在一起必假绿：
#   (a) 管道让 swiftc 的退出码变成 head 的，编译失败也照样往下走；
#   (b) 编译失败时 /tmp 里若还留着上一轮编好的二进制，就又被跑一遍 → 用旧结果报绿。
#   （本机 swift 工具链不随仓走，编不过时产物正是这种残留。）
# 7、8 两步（v3.9.1）已各自用 `rm -f 产物` + `PIPESTATUS` 堵过，这里把同一口径收敛成一个函数。
run_unit() {
    local out="$1"; shift
    rm -f "$out"
    $SWIFT/swiftc -o "$out" "$@" 2>&1 | head -10
    [ ${PIPESTATUS[0]} -eq 0 ] || { echo "❌ 编译失败：$out"; exit 1; }
    "$out" || exit 1
}

echo "=== 1. 语法检查（全部 .swift） ==="
# 🚨 2026-09-17 实踩：原 glob 是 `qingliao/Features/*/*.swift`（只扫子目录），
# 而 Features 根目录下也有文件（TaskCenterView.swift 等）→ 它们**从未被本地预检覆盖**，
# TaskCenterView 的括号错位因此一路漏到 CI（一轮 20 分钟）。这里补上根目录那层。
$SWIFT/swiftc -parse qingliao/QingliaoApp.swift qingliao/Core/*.swift qingliao/Theme/*.swift qingliao/Features/*.swift qingliao/Features/*/*.swift 2>&1 | grep -v "^$" | head -10
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo "✅ 语法通过"
else
    echo "❌ 语法错误（如上）"
    exit 1
fi

echo "=== 2. parseResponse 单元测试 ==="
run_unit /tmp/test_parse scripts/test_parse.swift

echo "=== 3. relay 编解码单元测试 ==="
run_unit /tmp/test_relay scripts/test_relay.swift

echo "=== 4. 诊断上报组装 + 离线队列单元测试（v3.6.0）==="
# 多文件编译时只有 main.swift 允许顶层代码 → 复制一份到临时目录做 main.swift
rm -rf /tmp/ql_diag_main && mkdir -p /tmp/ql_diag_main
cp scripts/test_diag.swift /tmp/ql_diag_main/main.swift
run_unit /tmp/test_diag -swift-version 6 /tmp/ql_diag_main/main.swift \
    qingliao/Core/DiagnosticsPayload.swift qingliao/Core/DiagnosticsStore.swift

echo "=== 5. Agent 结果卡片解析单元测试 ==="
run_unit /tmp/test_agent_card -swift-version 6 \
    qingliao/Core/AgentCardParser.swift scripts/test_agent_card.swift

echo "=== 5b. 启动会话策略真值表（v4.0.0 自动/上次会话/新对话 + 15 分钟边界）==="
# 🚨 必须把生产源码编进来（审查抓出的真问题）：只编测试文件时，表内那份镜像实现
#    与生产代码各改各的 → 公式/常量/接线被改坏也全绿。现在编的就是 qingliao/Core/LaunchSession.swift。
# 入口：多文件一起编译时顶层只允许声明，调用代码由这里现生成一个 main.swift 承担。
# 入口文件名**必须**叫 main.swift —— swiftc 只在 main.swift 里允许顶层可执行表达式。
mkdir -p /tmp/ls_entry && cat > /tmp/ls_entry/main.swift <<'LSEOF'
import Foundation
// 现生成的测试入口（每次预检重建，不入库）。main.swift 不会自动 import Foundation → 显式写。
exit(LaunchSessionTruthTable.main())
LSEOF
run_unit /tmp/test_launch_session -swift-version 6 \
    qingliao/Core/LaunchSession.swift scripts/test_launch_session.swift /tmp/ls_entry/main.swift

echo "=== 5c. 宠物动画真值表（v4.0.0 走动搞怪 + 镜像/位移顺序坑）==="
run_unit /tmp/test_pet -swift-version 6 scripts/ql_pet/truth_table_pet.swift

echo "=== 6. 挂件 Extension 语法检查（v3.8.0 实时活动）==="
$SWIFT/swiftc -parse qingliaoWidget/*.swift qingliao/Core/LiveActivityAttributes.swift qingliao/Core/LiveActivityActions.swift 2>&1 | grep -v "^$" | head -10
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo "✅ 挂件语法通过"
else
    echo "❌ 挂件语法错误（如上）"
    exit 1
fi
echo "=== 7. 剪贴板提示去重真值表（v3.8.1）==="
# 多文件编译时只有 main.swift 允许顶层代码 → 复制一份到临时目录做 main.swift
rm -rf /tmp/ql_clip_main && mkdir -p /tmp/ql_clip_main
cp scripts/test_clipboard_gate.swift /tmp/ql_clip_main/main.swift
rm -f /tmp/test_clip_gate   # v3.9.1：先删旧产物，否则编译失败时会跑到上一轮的残留二进制 → 假绿
$SWIFT/swiftc -o /tmp/test_clip_gate /tmp/ql_clip_main/main.swift qingliao/Core/ClipboardPromptGate.swift 2>&1 | head -10
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "❌ 剪贴板去重真值表编译失败"; exit 1; }
/tmp/test_clip_gate || exit 1
echo "=== 8. 一句话定时提醒解析真值表（v3.9.32）==="
# 纯 Foundation 解析器（不依赖 iOS SDK）→ 本机就能把「时间算错」这类必错项钉死
# 多文件编译时只有 main.swift 允许顶层代码 → 复制一份到临时目录做 main.swift
rm -rf /tmp/ql_reminder_main && mkdir -p /tmp/ql_reminder_main
cp scripts/test_quick_reminder.swift /tmp/ql_reminder_main/main.swift
rm -f /tmp/test_quick_reminder   # 先删旧产物，否则编译失败时会跑到上一轮残留二进制 → 假绿
$SWIFT/swiftc -swift-version 6 -o /tmp/test_quick_reminder /tmp/ql_reminder_main/main.swift \
    qingliao/Core/QuickReminder.swift 2>&1 | head -10
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "❌ 定时提醒真值表编译失败"; exit 1; }
/tmp/test_quick_reminder || exit 1
echo "=== 9. 模型用量卡片文案真值表（v3.9.54）==="
# 单文件（纯 Foundation，无项目依赖）→ run_unit 直接编跑
run_unit /tmp/test_provider_usage scripts/test_provider_usage.swift

echo "=== 10. TypeSafe 智能路由真值表（v3.9.56）==="
# 多文件编译时只有 main.swift 允许顶层代码 → 复制一份到临时目录做 main.swift
rm -rf /tmp/ql_ts_main && mkdir -p /tmp/ql_ts_main
cp scripts/test_typesafe_routing.swift /tmp/ql_ts_main/main.swift
rm -f /tmp/test_typesafe_routing   # 先删旧产物，否则编译失败时会跑到上一轮残留二进制 → 假绿
$SWIFT/swiftc -swift-version 6 -o /tmp/test_typesafe_routing /tmp/ql_ts_main/main.swift \
    qingliao/Core/TypesafeRouting.swift 2>&1 | head -10
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "❌ 智能路由真值表编译失败"; exit 1; }
/tmp/test_typesafe_routing || exit 1

echo "=== 11. 欢迎页特征智能球真值表（v3.9.57）==="
# 单文件（读源文件做护栏 + 镜像冻结判定，不 import 项目代码）→ run_unit 直接编跑
run_unit /tmp/test_orb scripts/ql_orb/truth_table_orb.swift

echo "=== 12. 智慧球长按快捷菜单真值表（v3.9.59 攒版）==="
# 单文件（读源文件做护栏 + 弧线几何纯计算镜像，不 import 项目代码）→ run_unit 直接编跑。
# 工作目录 = 仓根（真值表内用相对路径 "qingliao/Features/..." 读源）→ 必须从仓根跑。
run_unit /tmp/test_orbmenu scripts/ql_orbmenu/truth_table_orbmenu.swift

echo "=== 13. 图片发送串真值表（v3.9.60）==="
# 单文件（读源文件做护栏 + 镜像 ChatStore.sendableImageURL 纯函数）→ run_unit 直接编跑。
# 口径：payload 里只允许 base64，绝不许把自家（只有 IPv6 的）图片 URL 交给上游模型。
run_unit /tmp/test_imgsend scripts/ql_imgsend/truth_table_imgsend.swift

echo "=== 14. 输入栏两层化真值表（v3.9.61）==="
# 单文件（读源文件做护栏 + 高度算式镜像，不 import 项目代码）→ run_unit 直接编跑。
# 口径：两层恒定结构（messageRow/toolRow）、归属正确、旧单行形态清零。
run_unit /tmp/test_inputbar scripts/ql_inputbar/truth_table_inputbar.swift

echo "=== 15. 意图管道真值表（v3.9.71）==="
# 多文件编译时只有 main.swift 允许顶层代码 → 复制一份到临时目录做 main.swift。
# 口径：强格式判定（含反例占 1/3）+ 动作表映射 + 字段抽取 + 置信度门槛（兜底必须 <0.5）。
# datetime 判定复用生产代码 QuickReminderParser，所以 QuickReminder.swift 必须一起编进来。
rm -rf /tmp/ql_intent_main && mkdir -p /tmp/ql_intent_main
cp scripts/test_intent_pipeline.swift /tmp/ql_intent_main/main.swift
rm -f /tmp/test_intent_pipeline
$SWIFT/swiftc -swift-version 6 -o /tmp/test_intent_pipeline /tmp/ql_intent_main/main.swift \
    qingliao/Core/IntentPipeline.swift qingliao/Core/QuickReminder.swift qingliao/Core/RecordKit.swift 2>&1 | head -10
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "❌ 意图管道真值表编译失败"; exit 1; }
/tmp/test_intent_pipeline || exit 1

echo "=== 16. 跨文件复用私有类型护栏（v3.9.71）==="
# 背景（真实事故，不是洁癖）：MiniCapsule 在 MemoSection.swift / TodoSection.swift 里各有一份
# `private struct`（文件级私有 = 跨文件不可见），第三个使用者 RecordSection.swift 直接引用它 →
# 第 1 步的 `swiftc -parse` 全绿（纯语法解析、不做名字解析），只有 CI Archive 才报
# `cannot find 'MiniCapsule' in scope`。这类错误本地任何一步都抓不到，所以单列一步。
#
# 判据：文件级 `private struct/class/enum X` 的 X，若在**别的** .swift 文件里被"当类型用"
# （出现 X( / X{ / X< / : X 这种形态，且不是在注释行里），就是跨文件私有引用 → 报红。
# 注意排除注释里的同名提及（本仓确实有几处注释提到 MiniCapsule，那不算）。
type_conflicts=0
while IFS= read -r f; do
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    hits=$(grep -rlE "(^|[^A-Za-z0-9_/])${name}[[:space:]]*[(<{]" qingliao --include=*.swift 2>/dev/null \
           | grep -v "^$f$" | while IFS= read -r other; do
                 if grep -nE "(^|[^A-Za-z0-9_/])${name}[[:space:]]*[(<{]" "$other" 2>/dev/null \
                    | grep -vE "^[0-9]+:[[:space:]]*//" | grep -q .; then echo "$other"; fi
               done)
    if [ -n "$hits" ]; then
      echo "❌ $f 里的私有类型 $name 被别的文件引用：$(echo "$hits" | tr '\n' ' ')"
      echo "   → 要么把该类型抽成非 private 的共享组件，要么在使用方补一份同名声明（CI 才会真正报错）"
      type_conflicts=1
    fi
  done < <(grep -oE "^private (struct|class|enum) [A-Za-z_][A-Za-z0-9_]*" "$f" | awk '{print $3}' | sort -u)
done < <(grep -rlE "^private (struct|class|enum) " qingliao --include=*.swift 2>/dev/null)
if [ $type_conflicts -eq 0 ]; then
  echo "✅ 未发现跨文件复用文件级私有类型"
else
  echo "❌ 存在跨文件私有类型引用（本地预检本来查不出，CI Archive 必挂）"
  exit 1
fi

echo "=== 17. 入口行为真值表（v3.9.76 攒版）==="
# 单文件（读源文件做护栏，不 import 项目代码）→ run_unit 直接编跑。
# 口径：① 会话列表 open(_:) 是唯一进会话入口，不许按标题特判「投递」（v3.9.75 曾特判成开任务中心，
#       用户真机实测否掉：「点进去应该看到投递信息详情」）② 相机 fullScreenCover 内容必须
#       .ignoresSafeArea()（缺它 = 取景层只铺满安全区，顶部状态栏高度露黑底）。
run_unit /tmp/test_entry scripts/ql_entry/truth_table_entry.swift

echo "=== 18. 进度推送顺序真值表（v3.9.76 用户规则）==="
# 纯逻辑（不 import UIKit）→ 本机可编可跑。
# 口径：用户 2026-09-25 定的规则——「进度这类回复要按时间前后推，不要 20 步推在 17 步前」。
#      进度是**状态快照**，迟到的旧快照（投递层把僵尸 sending 重置回 pending 重投）必须丢弃；
#      判据按 source_task_id 分组——toolSeq 每任务独立计数，跨任务比会误丢新任务的第一条进度。
# 多文件编译时只有 main.swift 允许顶层代码 → 复制一份到临时目录做 main.swift（同第 7 步）
rm -rf /tmp/ql_progress_main && mkdir -p /tmp/ql_progress_main
cp scripts/test_inbox_progress.swift /tmp/ql_progress_main/main.swift
rm -f /tmp/test_inbox_progress   # 先删旧产物，否则编译失败时会跑到上一轮残留二进制 → 假绿
$SWIFT/swiftc -o /tmp/test_inbox_progress /tmp/ql_progress_main/main.swift qingliao/Core/InboxProgressOrder.swift 2>&1 | head -10
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "❌ 进度顺序真值表编译失败"; exit 1; }
/tmp/test_inbox_progress || exit 1

echo "=== 19. 语音对话轮次真值表（v3.9.76 新功能）==="
# 纯逻辑（不 import UIKit）→ 本机可编可跑。
# 口径：用户拍板「自动发和点一下发都要」+ 停顿 2 秒；AI 回复全念 → 念的时候必须停麦（半双工）。
# 多文件编译时只有 main.swift 允许顶层代码 → 复制一份做 main.swift（同第 7/18 步）
rm -rf /tmp/ql_voice_main && mkdir -p /tmp/ql_voice_main
cp scripts/test_voice_dialog.swift /tmp/ql_voice_main/main.swift
rm -f /tmp/test_voice_dialog   # 先删旧产物，否则编译失败时会跑到上一轮残留二进制 → 假绿
$SWIFT/swiftc -o /tmp/test_voice_dialog /tmp/ql_voice_main/main.swift qingliao/Core/VoiceDialogEngine.swift 2>&1 | head -10
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "❌ 语音对话真值表编译失败"; exit 1; }
/tmp/test_voice_dialog || exit 1

echo "=== 20. 工具步数显示真值表（v3.9.80 真机反馈修复）==="
# 单文件（读源文件做护栏 + 步数算式 max(toolSeq, toolNames.count) 纯计算镜像，不 import 项目代码）。
# 口径（用户原话）：「这个目前最多就显示10步，改成显示实际步数」——
# 后端为控体积只下发最近 10 步明细，全量步数走同一响应的 toolSeq，摘要行必须吃它。
run_unit /tmp/test_toolsteps scripts/ql_toolsteps/truth_table_toolsteps.swift

echo "=== 21. 设置页间距口径真值表（v3.9.80 baseline-ui 打磨）==="
# 单文件（读源 + 扫 Settings 目录，不 import 项目代码）→ run_unit 直接编跑。
# 口径：分隔线缩进与「非卡片内容左右留白」各收成命名令牌（54/62 与 18），字面量清零。
run_unit /tmp/test_settings_ui scripts/ql_settings_ui/truth_table_settings_ui.swift

echo "=== 22. 色彩令牌口径真值表（v3.9.80 improve-ui 审计落地）==="
# 单文件（读源做护栏，不 import 项目代码）→ run_unit 直接编跑。
# 口径：tone/tag 色**淡色胶囊底**一律走 Tint.subtle，不留字面 opacity（0.12/0.14 肉眼难辨，
# 但留字面量 = 改口径时被落下 → 又变回「每处各调一下」）。
run_unit /tmp/test_uitokens scripts/ql_uitokens/truth_table_uitokens.swift

echo "=== 23. 语音对话页正文两稿口径真值表（v3.9.82 贪婪容器收口）==="
# 单文件（读源做护栏，不 import 项目代码）→ run_unit 直接编跑。
# 口径：`ScrollView` + 定高上限 = 贪婪（吃掉提案给它的**全部**高度）→ 短回复也白撑上限；
# 改 ViewThatFits 两稿：稿 1 = 内容自然高度 / 稿 2 = 可滚动 + 上限（两稿共用同一 body）。
# 顺序断言是重点：两稿调换 = 退回白撑，本表会点名报红。
run_unit /tmp/test_voiceui scripts/ql_voiceui/truth_table_voiceui.swift

echo "=== 24. 桌面图标长按快捷方式真值表（v3.9.82 用户点名 6 项 / 系统上限 4 项；v3.9.83 修接收端）==="
# 钉：候选顺序 = 用户点名顺序 + 默认前 4；标题/图标只有 OrbQuickAction.all 一个真源（不许抄第二套）；
# 动作分发只经 handleOrbAction；**「全关」哨兵**（无此哨兵 = 最后一项点掉又自己亮回来）；
# 动态重建 shortcutItems（不用 plist 静态项）；接收点仍在 OrbMenuFromPetModifier（body 巨型链不多挂修饰符）。
# 🚨 v3.9.83（真机「点快捷方式只打开 App、不跳转」）：**SwiftUI 进程是 scene-based，快捷方式事件只发给
#    scene delegate**，AppDelegate 的 performActionFor 永远不会被调用 —— 本步还要钉「SceneDelegate 存在 +
#    两条入口 + AppDelegate 里 configurationForConnecting 注册它」，否则修好的链路下个版本又会被谁改回去。
run_unit /tmp/test_homeshortcuts scripts/ql_homeshortcuts/truth_table_homeshortcuts.swift

echo "=== 25. 译文弹窗真值表（v3.9.82 用户「改弹窗，跟 AI 速记弹窗一致」）==="
# 钉：形态逐条对齐参照物 QuickCaptureSheet（档位 medium+large / Spacing.section / 贴顶 / headline 粗体 /
# 玻璃正文卡 Radius.card / 背景不覆盖交给系统）；**识别浮层里不许再有译文卡**
# （translatedCard / copyTranslation / copiedTranslation / translationMaxHeight 全清零）；
# 译文只有一条出口（onTranslated → 宿主 .sheet(item:)）；宿主 onDismiss 复位；
# 「发给 AI」仍是唯一通道（askAI 单出口、.qingliaoTaskSend 只 post 一次）；
# 「换一张」接回翻译模式且事后必须复位（不然下次拍照莫名出译文）；速记那条路没被误伤。
run_unit /tmp/test_translatesheet scripts/ql_translatesheet/truth_table_translatesheet.swift

echo "=== 26. 长回复阅读真值表（v3.9.86 功能 4 · B 方案：半屏 sheet 放大）==="
# 单文件（读源做护栏，不 import 项目代码）→ run_unit 直接编跑。
# 口径（用户 2026-09-26 拍板「B 半屏 sheet 放大，沿用现有 detent」）：沿用 medium/large 不新增宿主、
# 复用 SelectableTextLabel/MarkdownRenderer 既有渲染与章节真源、分享走「先 dismiss 再 present」
# （同宿主互斥）、大纲是本 sheet 内一层、参数声明序 = 调用序。
run_unit /tmp/test_reading scripts/ql_reading/truth_table_reading.swift

echo "=== 27. 会话自动命名真值表（v3.9.90 首条消息后起一次名 / 人改过名字的不再自动改）==="
# 单文件（读源做护栏 + 镜像逐字校验 ChatStore 的接线与 SessionAutoName 的判断句，不 import 项目代码）→ run_unit 直接编跑。
# 工作目录 = 仓根（表内用相对路径 "Core/ChatStore.swift" / "Core/SessionAutoName.swift" 读源）→ 必须从仓根跑。
# 口径（用户拍板 3a）：① 触发点 = 首条消息落库口（writeSessionSnapshot）② 结果一律走既有落库链
#   ③ 失败/超时/输出不可用 → 静默回落 30 字兜底 ④ 幂等：已起过名 / 人改过名 / 投递壳会话都不再自动改。
run_unit /tmp/test_autoname scripts/ql_autoname/truth_table_autoname.swift

echo "=== 28. 一句话记账真值表（v4.0.x 聊天页入口 · 口径 1a）==="
# 多文件编译：真值表自带 @main 入口 → run_unit 直接编跑（同第 5 步）。
# 口径：① 反例 ≥ 1/3（「点即写」写错就进用户账本 → 宁漏不错账）② 带单位复用 IntentPipeline、
#   裸数字走本仓新增的窄门 ③ 卡片必须能被**真的** AgentCardParser 解出（不是手写字符串自证）
#   ④ 卡片不带动作段（真撤销按钮在 ChatRecordBar 上，卡里没有假按钮）。
run_unit /tmp/test_chat_record -swift-version 6 \
    scripts/test_chat_record.swift qingliao/Core/ChatRecordKit.swift qingliao/Core/IntentPipeline.swift \
    qingliao/Core/QuickReminder.swift qingliao/Core/RecordKit.swift qingliao/Core/AgentCardParser.swift

echo "=== 29. 分享接收扩展真值表 + 语法检查（v4.0.1 分享扩展 ↔ 主 App · ShareLinkCodec · 口径 1a）==="
# 🚨 分享扩展的源码**不在第 1 步的 glob 里**（那步只扫 qingliao/…，同第 6 步补挂件、这里补扩展）——
#    扩展里一行语法错，本机此前没有任何一步看得见（只有 CI Archive 才会报）。所以先 parse 再跑表。
$SWIFT/swiftc -parse qingliaoShare/*.swift 2>&1 | grep -v "^$" | head -10
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo "✅ 分享扩展语法通过"
else
    echo "❌ 分享扩展语法错误（如上）"
    exit 1
fi
# 多文件编译时只有 main.swift 允许顶层代码 → 复制一份到临时目录做 main.swift（同第 7/8/18/19 步）。
# 口径：URL / 剪贴板两条通道的往返无损（中文 / emoji / 换行 / URL 保留字符、base64url 的三种 padding、
#   4000 字节边界）、残载荷与版本不符整条丢弃、别的 scheme（含既有 qingliao://chat 深链）绝不接管。
rm -rf /tmp/ql_share_main && mkdir -p /tmp/ql_share_main
cp scripts/test_share_codec.swift /tmp/ql_share_main/main.swift
run_unit /tmp/test_share_codec -swift-version 6 /tmp/ql_share_main/main.swift qingliao/Core/ShareLinkCodec.swift

echo "=== 30. 会话纪要真值表（v4.0.x 录音页 + 摘要链路 · MinutesKit · 口径 1a）==="
# 多文件编译：真值表自带 @main 入口 → run_unit 直接编跑（同第 5/28 步）。
# 口径：① **不丢字**：切片是位置切分，chunks.joined() == 原文（4000 字边界 / 无标点硬切都算）
#   ② **超长走 map-reduce**：> 4000 字 → 每片一条 map + 最后一次 reduce（askCount = 片数 + 1）
#   ③ **不要输出思考过程**：single / map / reduce 三条提示词都显式带这句（模型爱写推理步骤）
#   ④ **卡片必须能被真的 AgentCardParser 解出**（type/title/fields/footer 逐项断言，不是手写字符串自证）
#   ⑤ **空转写不产卡**：抽不出内容 → 卡片 ""，页面只能走「重试 / 存原文备忘」
#   ⑥ **录音页护栏（读源码）**：不许 Text(整篇 liveText) 重绘、必须按段渲染、
#      必须 ensureMicrophonePermission + start(baseline:"") + stop() + MemoStore.add(source:"meeting")、
#      失败态必须有「重试」与「存原文备忘」。
#   本步只编纯 Foundation 的 MinutesKit + 真解析器；MeetingMinutesView 是 SwiftUI，本机没 SDK
#   （类型/并发只能 CI 暴露）→ 它的接线由第 ⑥ 组的读源码断言兜住，别把这段删了。
run_unit /tmp/test_minutes -swift-version 6 \
    scripts/test_minutes.swift qingliao/Core/MinutesKit.swift qingliao/Core/AgentCardParser.swift

exit $?
