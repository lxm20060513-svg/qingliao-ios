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

echo "=== 5a. AI 本地动作协议单元测试（v3.9.95 ql-action 围栏）==="
# ⚠️ 编的是**生产源码** qingliao/Core/AgentAction.swift，不是测试里的镜像实现 ——
#    镜像实现会与生产代码各改各的，协议改坏也全绿（同 5b 的教训）。
# AppPermissionKit 依赖 EventKit/Photos/UIKit，Linux 编不过 → 用 shims 里的枚举外壳。
run_unit /tmp/test_agent_action -swift-version 6 \
    qingliao/Core/AgentAction.swift scripts/shims/AppCapabilityShim.swift \
    scripts/test_agent_action.swift

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

echo "=== 31. 本轮夜间 code review 修复的回归护栏（读源码静态断言）==="
# 🚨 这 8 条是本轮 4 路只读审查 + 主代理复核后修掉的真 bug 的「不许退回去」护栏。
#    纯逻辑部分第 30 步的真值表已经能验（advance 拼接公式），
#    剩下这几条都落在 **SwiftUI 接线**上 —— 本机无 SDK，真值表编不了，
#    只能读源码断言；CI Archive 挂之前至少先把口径钉死。
fail=0
ck() {  # ck "说明" "grep -E 模式" 文件
    if grep -qE "$2" "$3"; then
        echo "✅ $1"
    else
        echo "❌ $1"
        fail=1
    fi
}
# 🚨 v4.0.x 同类风险审计抓到的教训：**只查字符串在全文件存在 = 假绿**。
#   例：'guard !chat\.isDeliverySession' 在记账那条路径上也有 → 删掉纪要那条照样绿；
#       'lastClipboardChange = pb\.changeCount' 在 probeClipboard 里也有 → 删掉正确那行照样绿；
#       'case \.clipboard:' 只证明分支存在 → 把整道 active 闸删掉照样绿。
#   ckIn "说明" "函数签名正则" "模式" 文件：只在该函数体范围内找模式，才算真断言。
ckNot() {  # 反向断言：**不该出现**的串。出现即失败（⚠️ 别用 `ck ... && fail=1` 写反了）
    if grep -qE "$2" "$3"; then
        echo "❌ $1"; fail=1
    else
        echo "✅ $1"
    fi
}
ckIn() {  # ckIn "说明" "函数签名正则" "grep -E 模式" 文件
    local body
    body=$(awk -v sig="$2" '
        $0 ~ sig { f=1 }
        f { print }
        f && /^    \}$/ { exit }
    ' "$4")
    if printf '%s' "$body" | grep -qE "$3"; then
        echo "✅ $1"
    else
        echo "❌ $1"
        fail=1
    fi
}
CV=qingliao/Features/Chat/ChatView.swift
MM=qingliao/Features/Chat/MeetingMinutesView.swift
SI=qingliao/Core/ShareIntake.swift
RS=qingliao/Core/RecordStore.swift
SC=qingliaoShare/ShareComposeModel.swift
DT=qingliao/Features/DockTabView.swift
CS=qingliao/Core/ChatStore.swift

ck "记账闸：sendCore 默认不记账（分享/任务/备忘不误记）" \
   'func sendCore\(text: String, imageData: String\?, quotedText: String\? = nil, allowExpense: Bool = false\)' "$CV"
ck "记账闸：两处记账调用都带 allowExpense 判断" \
   'if allowExpense \{ noteChatExpenseIfMatched' "$CV"
ck "记账闸：用户亲手发送的路径传 allowExpense: true" \
   'sendCore\(text: text, imageData: nil, quotedText: quotedText, allowExpense: true\)' "$CV"
ck "去重提示走独立位（不被意图动作条盖住）" \
   '@State var recordDedupNotice = false' "$CV"
ck "去重提示不再复用 intentNoContentHint" \
   'flashRecordDedup\(\)' "$CV"
ckIn "纪要卡也有投递会话护栏（**限定 insertMinutesCard 函数体内**，不能靠记账那条同串假绿）" \
   'func insertMinutesCard\(_ card: String\)' 'guard !chat\.isDeliverySession else \{ return \}' "$CV"
ck "纪要放弃标记不被整理复位（abandoned 不在 summarize 里清）" \
   'resetForNewTake\(\)' "$MM"
ck "retry 与 restart 共用同一份重置" \
   'resetForNewTake\(\)' "$MM"
ckIn "剪贴板读失败不记账（**限定 readClipboardPayload 函数体内**；probeClipboard 里那处是故意的「无论成败都记账」，不能算）" \
   'func readClipboardPayload\(expectedID: String\)' 'lastClipboardChange = pb\.changeCount' "$SI"
ckIn "URL 通道剪贴板也走 active 闸（**限定 handle(url:) 函数体内**，光有 case .clipboard 不算）" \
   'static func handle\(url: URL, loggedIn: Bool' 'try\? await Task\.sleep\(for: clipboardProbeDelay\)' "$SI"
ck "撤销留墓碑（远端并集不会把删掉的复活）" \
   'tombstones\.insert\(item\.id\)' "$RS"
ck "远端合并跳过墓碑 id" \
   'for r in remote where !tombstones\.contains\(r\.id\)' "$RS"
ck "写库串行链（撤销不会被慢的旧快照覆盖）" \
   'await prev\.value' "$RS"
ck "迟到回调把空态救回 ready（分享扩展有发送入口）" \
   'if case \.empty = phase, hasContent \{ phase = \.ready \}' "$SC"
ck "分享图片字节复用（不再重编谎报 hasImage）" \
   'let jpeg = imageJPEG \?\? image\.flatMap' "$SC"
ck "onOpenURL 双挂加固（DockTabView 也接 share，且闸内重取登录态）" \
   'if ShareIntake\.handle\(url: url, loggedIn: auth\.isLoggedIn, loggedInProvider: \{ auth\.isLoggedIn \}\) \{ return \}' "$DT"
ck "自动命名不把本地卡算成对话（isPush 排除）" \
   'let conversational = msgs\.filter \{ !\$0\.isPush && !\$0\.isErrorPlaceholder \}\.count' "$CS"
ck "自动命名用的是 conversational 而不是 msgs.count" \
   'SessionAutoName\.shouldFire\(messageCount: conversational' "$CS"
ck "冷启动补投扩展 pending 载荷" \
   'ShareIntake\.flushPending\(loggedIn: true\)' qingliao/QingliaoApp.swift

[ $fail -eq 0 ] || { echo "❌ 第 31 段有护栏失守"; exit 1; }
echo "✅ 夜间 review 修复的 19 条回归护栏全绿"

echo "=== 32. 启动会话设置：外观页入口不许被删（v3.9.94）==="
# 🚨 这段 UI 是**补的入口**，不是新功能：LaunchSession.swift 的判定逻辑与两个 UserDefaults key
# 早就存在，但 AppearanceSheet 从来没有入口 → 用户根本设不了，永远吃默认的 .auto + 15 分钟。
# 所以护栏盯的是「入口不许被删 / 阈值只对 auto 生效」这两类退化。
AP=qingliao/Features/Settings/SettingsCommon.swift
LS=qingliao/Core/LaunchSession.swift
ck "启动会话两个 key 已声明" 'launchSessionMode' qingliao/Core/Models.swift
ck "外观页读到了 launchSessionMode" '@AppStorage\(' "$AP"
ck "外观页读到了 launchSessionMins" '@AppStorage\(' "$AP"
ck "外观页确实消费 launchSessionMode" 'launchSessionMode' "$AP"
ck "外观页确实消费 launchSessionMins" 'launchSessionMins' "$AP"
ck "三选一入口：自动" '自动' "$AP"
ck "三选一入口：上次会话（标题取自枚举 title，在 LaunchSession.swift）" '上次会话' "$LS"
ck "三选一入口：新对话" '新对话' "$AP"
ck "阈值说明跟着阈值走（不是写死 15）" '就自动开一个新对话；不足则接着上次那个聊' "$AP"
ck "启动会话标题取自枚举 title（单一真源，不在 UI 里另写一份中文）" 'mode.title' "$AP"
ck "档位取自 idleOptions（单一真源）" 'idleOptions' "$LS"
ck "三选一走 allCases 遍历（加档位不会漏界面）" 'LaunchSessionMode.allCases' "$AP"
ck "默认阈值 15 分钟就是需求里的那个数" 'defaultIdleMinutes = 15' "$LS"
ck "判定逻辑真被 ChatStore 消费" 'launchSessionMode' qingliao/Core/ChatStore.swift
ck "只有 auto 模式才看超时阈值（另两档是恒定行为，不该出现阈值分支）" \
   'case .auto:' qingliao/Core/LaunchSession.swift
# 🚨 反向自证 1：UI 不得出现 LaunchSessionMode.xxx 形式的 case 引用（凭空造成员头号来源）
#    —— 正确姿势是 allCases 遍历 + mode 传参。用抽样名单反证。
for bogus in lastSession newSession lastConv newChat alwaysNew; do
    if grep -qE "LaunchSessionMode\.$bogus\b" "$AP"; then
        echo "❌ UI 引用了不存在的 case LaunchSessionMode.$bogus（枚举真名是 .last/.new，CI 才挂）"
        fail=1
    fi
done
echo "✅ UI 未引用任何不存在的 case（逐个抽样反证）"
[ $fail -eq 0 ] || { echo "❌ 第 32 段有护栏失守"; exit 1; }
echo "✅ 启动会话设置入口的 20 条护栏全绿"

CVE=qingliao/Features/Chat/ChatViewExport.swift
echo "=== 33. v4.0.x 两路复审回归护栏（P0/P1 逐条钉死）==="
# 🚨 这些是 dispatch 两路只读审查（diff 严格审查 + 同类风险全仓审计）抓出来的真问题。
# 修完必须钉住，否则下次重构又会退回「A 路径修了、B 路径漏改」的形态。
ckIn "P0: probeClipboard 读失败不记账（限定 probeClipboard 函数体内）" \
   'func probeClipboard\(' 'reportMissingPayload' "$SI"
ckIn "P0: probeClipboard 消费成功才记账" \
   'func probeClipboard\(' 'lastClipboardChange = pb\.changeCount' "$SI"
# ⚠️ 用**行号先后**判真假顺序（只查「同在函数体内」区分不出前后，那等于没钉）：
#   正确形态 = 先 guard 判空 return（读失败不记账），再 lastClipboardChange = ...（消费成功才记账）。
# 用 awk 取 **probeClipboard 函数体内**的行号（readClipboardPayload 里也有同名赋值，不限定会取成多行）
_pc=$(awk '/func probeClipboard\(/{f=1} f&&/lastClipboardChange = pb\.changeCount/{print NR; exit}' "$SI")
_pe=$(awk '/func probeClipboard\(/{f=1} f&&/reportMissingPayload\(loggedIn: loggedIn\)/{print NR; exit}' "$SI")
if [ -n "$_pc" ] && [ -n "$_pe" ] && [ "$_pe" -lt "$_pc" ]; then
    echo "✅ P0: probeClipboard 是「读失败先 return、真正消费掉才记账」（行 $_pe < $_pc）"
else
    echo "❌ P0: probeClipboard 记账时机不对（消费行 $_pc 必须晚于失败行 $_pe）"; fail=1
fi
ck "P1: sendPendingNow 透传 allowExpense（用户亲手发的后半程不能丢记账闸）" \
   'func sendPendingNow\(_ p: \(text: String, imageData: String\?), allowExpense: Bool' "$CV"
ck "P1: sendFile 上传后二次查流占用（防静默掐断别的会话的答案）" \
   'if stream\.isStreaming \{' "$CVE"
# 字段声明不是函数体，ckIn 的「遇到收尾 } 就停」会切在它前面 → 这几条用 ck（全文件唯一串），
# 但保留「唯一性」：下面紧跟的计数断言保证每仓只有一处。
for st in MemoStore TodoStore PinStore; do
  ck "$st 也有 NAS 写链 FIFO 字段" 'private var writeChain: Task<Void, Never> = Task' "qingliao/Core/$st.swift"
  ck "$st 的 writeChain 在 save() 里被 await" 'let prev = writeChain' "qingliao/Core/$st.swift"
done
# 同理只查代码形态：`Task.detached { [weak auth] in` 才算真用弱捕获。
ckNot "PinStore 不再用 [weak auth] 捕获（SR33：弱引用会被清空 → 整次 NAS 回写静默丢失）" \
   'Task\.detached \{ \[weak auth\]' "qingliao/Core/PinStore.swift"
ck "P1: handle(url:) 闸内重取登录态（不再把 loggedIn 冻结在 Task 外）" \
   'let isLoggedIn = loggedInProvider\?\(\) \?\? loggedIn' "$SI"
ck "P1: handle(url:) 保留 loggedIn 兜底参数（不传 provider 也不崩）" \
   'loggedInProvider: \(\(\) -> Bool\)\? = nil' "$SI"
ckNot "ShareIntake 不再声称扩展会落盘 pending（该机制不存在）" \
   '扩展留在 pending 目录里的载荷补投进会话' "qingliao/QingliaoApp.swift"
_n=$(grep 'allowExpense: true' "$CV" | grep -vc '^ *//')
[ "$_n" = "2" ] && echo "✅ 只有输入栏 send() 那 2 处传 allowExpense: true（分享/任务/备忘/问AI 全部默认 false）" || { echo "❌ allowExpense: true 传点是 $_n 处（应 2），有人给非用户亲手路径开了记账闸"; fail=1; }
[ $fail -eq 0 ] || { echo "❌ 第 33 段有护栏失守"; exit 1; }
echo "✅ 两路复审 P0/P1 回归护栏全绿"

echo "=== 34. 拍照识别就地看真值表（v4.0.x · 2026-09-27 口径变更）==="
# 多文件编译时只有 main.swift 允许顶层代码 → 复制一份到临时目录做 main.swift。
# 口径：长按菜单「拍照识别」拍完**就地**进「AI 识别」浮层看图回答（球上浮层卡 + 背景虚化 + 球心扫描环，
#      与 AI 识别同形态）—— 不发进当前会话、不切聊天页、不落 ChatStore；提示词/超时/三态文案全在
#      PhotoAskKit 一处；图块仍只有 ImageBlocks 一个构造点。
# PhotoAskKit 是纯 Foundation（不 import UIKit/SwiftUI）→ 可以和表一起编，直接调它的值做回归。
rm -rf /tmp/ql_photoask_main && mkdir -p /tmp/ql_photoask_main
cp scripts/ql_photoask/truth_table_photoask.swift /tmp/ql_photoask_main/main.swift
rm -f /tmp/test_photoask
$SWIFT/swiftc -o /tmp/test_photoask /tmp/ql_photoask_main/main.swift \
    qingliao/Core/PhotoAskKit.swift 2>&1 | head -10
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "❌ 编译失败：/tmp/test_photoask"; exit 1; }
/tmp/test_photoask || exit 1

echo "=== 35. 快捷指令 / Siri「打开某页」真值表（v4.0.x · 2026-09-27 报错修复）==="
# 口径：用户真机跑快捷指令自动化「打开轻聊看板」当场报
#   `The provided URL scheme `qingliao` is unsupported; launch is prohibited`
#   → 旧写法（intent 返回 `.result(opensIntent: OpenURLIntent(qingliao://<tab>))`，请系统 launch
#     自己的 scheme）在 iOS 26 被拒。新链路：intent 走前台模式（supportedModes）+
#     `QingliaoRouteHandoff` 进程内投递 → DockTabView 的 applyRoute 落地（广播 + 冷启动补读）。
# QingliaoIntentSupport.swift 是纯 Foundation → 可以和表一起编，直接跑投递件的真值。
rm -rf /tmp/ql_intents_main && mkdir -p /tmp/ql_intents_main
cp scripts/ql_intents/truth_table_intents.swift /tmp/ql_intents_main/main.swift
rm -f /tmp/test_intents
$SWIFT/swiftc -o /tmp/test_intents /tmp/ql_intents_main/main.swift \
    qingliao/Core/QingliaoIntentSupport.swift 2>&1 | head -10
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "❌ 编译失败：/tmp/test_intents"; exit 1; }
/tmp/test_intents || exit 1

# === 5b. Swift 编译盲区护栏（-parse 抓不到、CI archive 才挂的类型错）===
chk_fail=0
# ① 计算属性里误用「换行 get {}」—— 单行 get { ... } 全项目合法，只有换行版才会挂
#    判据：static var/func 开头的行以 { 结尾，下一行是 get {
if grep -nE '^\s*static (func|var).*\{[[:space:]]*$' -A1 qingliao/Core/AppPermissionKit.swift 2>/dev/null | grep -qE '^[0-9]+-[[:space:]]*get \{[[:space:]]*$'; then
  echo "❌ AppPermissionKit：计算属性里出现 get {}（CI 必挂 cannot find 'get' in scope）"; chk_fail=1
fi
# ② mutationGuard 返回 String?，必须用 if let 收，不能 guard let
if grep -rn 'guard let .* = await AppPermissionKit.mutationGuard' qingliao/ 2>/dev/null | grep -q .; then
  echo "❌ mutationGuard 被 guard let 接收（返回 nil=放行，应写 if let）"; chk_fail=1
fi
# ③ PHAsset.fetchAssets 返回非 Optional，不能条件绑定
if grep -rn 'let assets = PHAsset.fetchAssets' qingliao/ 2>/dev/null | grep -q .; then
  if grep -rnE 'guard let assets = PHAsset.fetchAssets' qingliao/ 2>/dev/null | grep -q .; then
    echo "❌ PHAsset.fetchAssets 被 guard let 绑定（PHFetchResult 非 Optional）"; chk_fail=1
  fi
fi
# ④ SF Symbol 字符串误传给只收 SoftWave? 的参数
if grep -rnE 'tagView\("[a-z]' qingliao/ 2>/dev/null | grep -q .; then
  echo "❌ tagView(\"...\") 传了字符串（该参数是 SoftWave?，纯图标请用 iconTag）"; chk_fail=1
fi
[ $chk_fail -eq 0 ] || { echo "❌ 第 36 段有护栏失守"; exit 1; }
echo "✅ 编译盲区护栏 4 项全绿"

echo "=== 37. AI 本地动作 / 能力扩容一致性护栏（v4.0.x：5 类新能力 + 7 个新动作）==="
# 为什么单独成脚本：「动作表」这一轮被复制到 8 个接线点（能力枚举 / Linux shim / rawValue /
# 执行器分派 / 卡片图标 / 单测分级表 / project.yml 权限串 / 后端 QLACTION_PROMPT），
# 任何一处漏改**本地都不报错**：有的是运行期才现形（"内部错误"、静默按错分级），
# 有的只在 CI archive 挂（switch 不穷尽），有的是真机第一次用就 SIGABRT（缺权限串）。
python3 scripts/check_action_capabilities.py || exit 1

echo "=== 38. 会话列表「进行中」标识真值表（v4.0.x · 2026-09-27 用户拍板）==="
# 单文件（读源文件做护栏，不 import 项目代码）→ run_unit 直接编跑。
# 口径（用户从编号选项里拍板）：位置 = **替换右列 chevron**；形态 = **呼吸脉冲圆点**（减弱动态效果时静止常亮）；
#   判定 = **本机这条流没结束就算**（切到别的会话、App 切后台都照显；App 被杀/重启不还原 —— 服务端没这字段）。
# 钉的是最容易静默出错的几处：归属 id 结束后不清空（必须配 isStreaming/isDone 双判）、多选编辑态优先、
#   行内不许读 stream.content（每 token 变化 = 列表每 token 重算）。
run_unit /tmp/test_sessions scripts/ql_sessions/truth_table_sessions.swift

echo "=== 39. 框架回调闭包隔离护栏（v3.9.97 真机 Signal(5) 定案）==="
# 机制：ObjC 桥接的 completion 参数**多数没有 @Sendable**；闭包字面量写在 @MainActor 类型里会**继承 MainActor 隔离**，
#   框架在后台队列回调它时做隔离检查 → SIGTRAP（栈：dispatch_assert_queue_not ← libswift_Concurrency ← closure #1 ([EKReminder]?) -> ()）。
#   编译器全程沉默：-parse 无输出、CI archive 照过、零告警，只有真机崩（v3.9.97「查看待办」动作 100% 复现）。
# 名单只列**实测崩溃**的 API（fetchReminders / detectPatterns / installTap / requestRecordPermission），宁少勿滥防误报；
# 判定 = 闭包字面量显式带 @Sendable，或所在函数标 nonisolated。
python3 scripts/check_framework_callback_isolation.py || exit 1

echo "=== 40. 聊天页工具卡进度小字真值表（v3.9.81 · 2026-09-27 用户拍板 1a）==="
# 单文件（读源文件做护栏 + 文案算式镜像，不 import 项目代码）→ run_unit 直接编跑。
# 用户原话（真机反馈，配图任务中心「进行中」卡片）：「在聊天页的工具调用下面同步显示这段小字，也是用小字」。
# 口径（用户从编号选项拍板）：位置 = 摘要行「N 步工具调用」**下面固定一行**（收起/展开都看得到）；
#   文案 = **2b**（`工具名 · N 字 · 静默 X · 最近：…`——去掉「第 N 步」前缀，摘要行已写步数；
#   工具名 / 字数 / 静默 / 最近 照旧）；时机 = 流式进行中显示、收尾即隐藏。
# 钉的是最容易静默出错的两处：① **两端同口径**（直接读后端 stream_api.py 的格式串 / 尾部长度 / 静默分档，
#   任一端改了这里就红——后端源码不在本机时该段 ⚠️ 跳过并计数，不冒充绿）；
#   ② 静默锚点 contentGrowAt 的 6 个写入点齐（漏一处 = 静默永远 0 秒，真机看着像卡死）。
run_unit /tmp/test_progressnote scripts/ql_progressnote/truth_table_progressnote.swift

echo "=== 41. 价格功能已移除的静态护栏（v4.0.x 工程治理：补挂孤儿真值表）==="
# 为什么不早发现：价格监控已从 App 删除，guard_price_removed.py 断言「每个删除点必须为 0」。
# 它写在 scripts/ql_life_noprice/ 下却**从未被 check_swift.sh 调用** —— 本地和 CI 都不跑，
# 于是「价格代码被误加回来」这类回归没有任何拦截（scripts/check_guard_coverage.py 抓到的第 1 例）。
# 口径：价格监控移除后不得再有 price/价格 字段的写入路径。
python3 scripts/ql_life_noprice/guard_price_removed.py || exit 1

echo "=== 42. 护栏覆盖率守卫（v4.0.x 工程治理第 1 号整改：孤儿/断链断言）==="
# 防「回归保障」这条短板自我复制：任何新建真值表或 scripts/*.py 守卫，必须挂进本脚本，
# 否则本地和 CI 都不会跑它。新建时它会红，提示你补 check_swift.sh 那一段。
python3 scripts/check_guard_coverage.py || exit 1

echo "=== 43. SwiftUI 参数序护栏（v4.0.x 工程治理第 2 号整改：本地/CI 都查不出的编译错）==="
# 机制：SwiftUI View 的**成员初始化器**要求「调用处实参序 = 存储属性声明序」，写反了编译器报
#   `argument 'x' must precede argument 'y'`。而 -parse 只查语法（完全合法、零告警），
#   只有 CI Archive 才暴露，一轮 20 分钟；历史同类坑见 skill swiftui-param-order。
# 自测先行：脚本内置样例必须抓到 2 处乱序 —— 抓到 0 条 = 解析器失效，那才是最大的坑
#   （本守卫第一版就因正则漏了名字替换而「扫描 0 个调用点」假绿过一轮，已修）。
python3 scripts/check_swiftui_param_order.py --self-test || exit 1
python3 scripts/check_swiftui_param_order.py || exit 1

[ $fail -eq 0 ] || { echo "❌ 有护栏失守"; exit 1; }
exit 0
