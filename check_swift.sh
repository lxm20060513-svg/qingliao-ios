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
# 🚨 v4.0.104：21 个真值表都用 `env["QL_REPO"] ?? cwd` 定位仓库根 —— 调用方若残留一个指向
# 别处（或已不存在）的 QL_REPO，表就读错树：轻则哨兵红（像回归），最坏读到旧镜像产出**假绿**。
# 这里钉死成「本脚本所在目录」，不再信任调用方环境。
export QL_REPO="$(pwd)"
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

# v4.0.22：纯逻辑真值表若编在 Swift 5 模式下，「本地绿、CI Archive 才炸」的严格并发问题会漏检。
# 新表（ql_bill / ql_settings_search）走这条：显式 -swift-version 6，与 CI 严格并发口径一致。
run_unit6() {
    local out="$1"; shift
    rm -f "$out"
    $SWIFT/swiftc -swift-version 6 -o "$out" "$@" 2>&1 | head -10
    [ ${PIPESTATUS[0]} -eq 0 ] || { echo "❌ 编译失败（Swift 6 模式）：$out"; exit 1; }
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

echo "=== 5d. 通知文案规范化真值表（v4.0.91 · iOS 27 快捷指令可判别前缀）==="
# 编的是**生产源码** qingliao/Core/QingliaoNotifyCopy.swift（纯 Foundation，Linux 可编）——
# 不是测试里的镜像实现。这一层是「快捷指令按通知标题筛类别」的契约：
# 前缀改一个字，用户在自动化里写的「标题包含『轻聊·提醒』」就静默失效（界面看不出异常）。
# ⚠️ run_unit6（Swift 6 口径）：表里 ck() 标了 @MainActor —— 顶层全局变量在 Swift 6 下是
#    MainActor 隔离的，非隔离函数改不了它（本地实测：main actor-isolated var 'pass' can not
#    be mutated from a nonisolated context）。别把 @MainActor 去掉。
rm -rf /tmp/ql_notifycopy_main && mkdir -p /tmp/ql_notifycopy_main
cp scripts/ql_notifycopy/test_notifycopy.swift /tmp/ql_notifycopy_main/main.swift
run_unit6 /tmp/test_notifycopy /tmp/ql_notifycopy_main/main.swift \
    qingliao/Core/QingliaoNotifyCopy.swift
# 结构契约（分类表只有一份 / 11 个弹通知点一个不漏 / 老标题写法无残留）——单文件口径，直接编跑
run_unit /tmp/tt_notifycopy scripts/ql_notifycopy/truth_table_notifycopy.swift

echo "=== 5e. iOS 27 快捷指令联动动作源码契约（v4.0.91 · AppEntity + 划词）==="
# AppIntents 在本机（Linux，无 iOS SDK）**编不了** → 本地只能 `swiftc -parse`（步骤 1）。
# 这条把「真机能不能认出来」的硬约束钉在源码文本上：实体完整性（defaultQuery/EntityQuery 方法）、
# 三条隔离纪律（查询不触网 / 走 MainActor.run / 不占 Siri 短语名额）、划词参数必须是 String。
# 漏一条的症状是「Archive 过了、真机 Siri 里看不见这个动作」—— 那要 20 分钟一轮 CI 才发现。
run_unit /tmp/tt_ios27 scripts/ql_ios27/truth_table_ios27_intents.swift

# v4.0.58 会走路的小脚 —— 纯几何体检（本机是 Linux，跑不了 SwiftUI 渲染：
# 把「脚露在体外多少 pt / 步幅多少 pt / 会不会出画布 / 两脚会不会重叠」算出来钉住。
# 常量从 PetPainter.swift 现读，源码改写法即红）
if python3 scripts/ql_pet/check_leg_geometry.py >/tmp/tt_leggeo.log 2>&1; then
  echo "✅ v4.0.58 腿/脚几何体检 $(grep -oE '[0-9]+ 项' /tmp/tt_leggeo.log | tail -1)"
else
  echo "❌ v4.0.58 腿/脚几何体检"
  cat /tmp/tt_leggeo.log
  exit 1
fi

# v4.0.40 TTS 朗读时页头宠物跟着开口说话（PetSpeechShape 音节切分 + mouth 采样 + 接线护栏）
# 多文件编译时只有 main.swift 允许顶层代码 → 复制一份到临时目录（与第 4 段同一手法）
rm -rf /tmp/ql_petspeech_main && mkdir -p /tmp/ql_petspeech_main
cp scripts/ql_petspeech/truth_table_petspeech.swift /tmp/ql_petspeech_main/main.swift
run_unit6 /tmp/test_petspeech /tmp/ql_petspeech_main/main.swift qingliao/Core/PetSpeechShape.swift

# v4.0.9 点击震动总开关（闸门 + 裸 generator 清零）
if python3 scripts/ql_haptics/truth_table_haptics.py >/tmp/tt_haptics.log 2>&1; then
  echo "✅ v4.0.9 震动开关真值表 $(grep -oE '[0-9]+ 项' /tmp/tt_haptics.log | tail -1)"
else
  echo "❌ v4.0.9 震动开关真值表"
  cat /tmp/tt_haptics.log
  exit 1
fi

# v4.0.8 表格导出入口（两条渲染路径都得有导出，防回归）
if python3 scripts/ql_tableexport/truth_table_tableexport.py >/tmp/tt_tableexport.log 2>&1; then
  echo "✅ v4.0.8 表格导出真值表 $(grep -oE '[0-9]+ 项' /tmp/tt_tableexport.log | tail -1)"
else
  echo "❌ v4.0.8 表格导出真值表"
  cat /tmp/tt_tableexport.log
  exit 1
fi

# v3.9.113 成员存在性护栏（Typography/Spacing/Radius 假令牌、搬 UI 漏定义、
# extension 内存储属性、Outcome.undo 漏参、@MainActor 隔离、static @AppStorage）
# 这 6 类都是 -parse 拦不住、只有 CI Archive 拦得住的错误类型
if python3 scripts/ql_membercheck/truth_table_membercheck.py >/tmp/tt_membercheck.log 2>&1; then
  echo "✅ v3.9.113 成员存在性真值表 $(grep -oE '[0-9]+ 项' /tmp/tt_membercheck.log | tail -1)"
else
  echo "❌ v3.9.113 成员存在性真值表"
  cat /tmp/tt_membercheck.log
  exit 1
fi

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

echo "=== 14. 输入栏两层化真值表（v4.0.10 · 121 项）==="
# 单文件（读源文件做护栏 + 高度算式镜像，不 import 项目代码）→ run_unit 直接编跑。
# 口径：两层恒定结构（messageRow/toolRow）、归属正确、旧单行形态清零；
#   v4.0.10 加**发送锁/幂等闸门**护栏（真机故障「输入内容点发送没反应、消息不上屏、后端零请求」）：
#   发送锁只靠流收尾回调解锁是**承重墙裂缝**——「＋新建会话」把在跑的流移交给后台 runner 时走
#   StreamClient.detachLocally()（刻意 onFinished = nil），回调永不执行 → 锁永久为真 → 此后每次
#   发送都在 sendCore 第一道 guard 静默 return。护栏钉：锁必须有 0.8s 窗口上限 + 超窗自愈、
#   上位处同步记时刻、移交路径显式解锁、幂等只对自动路径生效（`!allowExpense`，用户亲手发的永不去重）。
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

echo "=== 21. AI 记住瞬间真值表（v4.0.120 第 2 项）==="
# 单文件纯逻辑（memoAdded 两道闸门的镜像模型，不 import 项目代码）+ 源级接线断言。
# 口径：① 后端 memoAdded 是「整流只增不减」的累积数组，0.15s 轮询下同一条只能触发一次
#      ② 复位与工具进度同生命周期（切会话/起新流后同一条是新事件，该再弹）
#      ③ 撤销必须真删且不被后端重发弹回（不接 memoDismissed 就会「删了又弹」）
#      ④ 源级：bar 真挂进槽位 / 撤销真打 delete 端点（镜像模型证明不了接线）
run_unit /tmp/test_memo_added scripts/ql_memo_added/truth_table_memo_added.swift
# 后端表跑 NAS 上**线上那份字节**（ql.py nas read 现拉），不拿本地副本凑假绿。
# 🚨 该表 import 线上 memory_store.py 会在临时目录里跑（QL_DATA_DIR 先设好），
#    绝不能指向真实 data/memory.json —— 表内第一项就是断言这点。
MB_TMP=/opt/data/cache/scratch
if python3 /opt/data/scripts/ql.py nas read 微信文件/轻聊web/backend/memory_store.py > "$MB_TMP/mem_store_live.py" 2>/dev/null \
   && python3 /opt/data/scripts/ql.py nas read 微信文件/轻聊web/backend/memory_api.py > "$MB_TMP/mapi_live.py" 2>/dev/null \
   && python3 /opt/data/scripts/ql.py nas read 微信文件/轻聊web/backend/stream_api.py > "$MB_TMP/stream_api_live.py" 2>/dev/null \
   && [ -s "$MB_TMP/mem_store_live.py" ] && [ -s "$MB_TMP/mapi_live.py" ] && [ -s "$MB_TMP/stream_api_live.py" ]; then
  ( cd scripts/ql_memo_added && python3 truth_table_memo_added_be.py ) 2>&1 | tee /tmp/tt_memo_be.log
  # ⚠️ 必须 exit 1 不能用 fail=1：本段在第 417 行 `fail=0` **之前**，
  # 那时 fail 还没初始化，写进去会被后面无条件重置抹掉 → 恒假绿（同 21a 段同款坑）。
  if grep -q '❌' /tmp/tt_memo_be.log; then echo "❌ 第 21 项后端表有失守"; exit 1; fi
else
  echo "⚠️ 拉不到线上后端副本（离线），第 21 项后端表本轮未跑"
fi

echo "=== 21b. 长任务断点续传「稳妥档」真值表（待做池⑥ · v4.0.38）==="
# 后端表跑 NAS 上**线上那份字节**（复用上面 21 项刚拉的 $MB_TMP/stream_api_live.py）。
# 用 AST 抽出目标函数源码 → 在最小命名空间里真调，验证的是线上代码本身（非仿制）。
# 口径（用户拍板「稳妥档」）：① 启动对账把 streaming 孤儿判为 error + outcome_unknown，
#   已生成内容与已完成步(toolSpans/toolSeq)原样保留 = 不重放、不丢断点；
#   ② 已完成(done)任务绝不被误伤；③ 落盘工具步走 _persist_state 不污染 updatedAt（静默真值）。
# ⚠️ 必须 exit 1 不能用 fail=1：本段在 fail 初始化之前，会被无条件重置抹掉。
if [ -s "$MB_TMP/stream_api_live.py" ]; then
  python3 scripts/ql_resume/truth_table_resume.py "$MB_TMP/stream_api_live.py" 2>&1 | tee /tmp/tt_resume.log
  if grep -q '❌' /tmp/tt_resume.log; then echo "❌ 第 21b 项断点续传真值表有失守"; exit 1; fi
else
  echo "❌ 第 21b 项拿不到线上 stream_api.py 字节，断点续传护栏本轮无法自证"
  exit 1
fi

# v4.0.109：原「21a. 接入中心一页真值表」（scripts/ql_connector/）随用户要求
#   「删掉看板页的连接器栏目」整块退役 —— 面板 ConnectorPanelSheet.swift 已删，表没有被测对象了。
#   该表里唯一还活着的一条口径 ——「邮件『允许 AI 直接发信』开关不许写成局部 PATCH
#   （save_account 会把没传的字段写成空值）」—— 仍由 20b 的 ql_mail 表覆盖
#   （它钉了提交/回显两份字段集合，含 allow_direct_send），护栏不丢。

echo "=== 20b. 邮件接入设置页真值表（v4.0.x：安全边界/后端契约/接线）==="
run_unit /tmp/test_mail scripts/ql_mail/truth_table_mail.swift

echo "=== 20b1. 工作台·工具格真值表（v4.0.113：定时提醒/文件管理 设置页 → 工作台）==="
# 钉：8 格逐格标题/图标/色（新增两格沿用设置页原色 pink/indigo）、8 个工具体的 sheet 挂载、
#     新两格挂 workspaceCold1 且 detents 与设置页时代同口径、冷组顶层 ≤4（§77）、
#     设置页四面零残留（入口行 / sheet / @State / 搜索 case）+ 搜索索引零残留（34 → 32）、
#     功能本体（QuickReminderSheet / FilesManagerSheet / QuickReminderStore）仍在。
# 全是**编译不报、手点才现**的坏法：只搬入口不搬 sheet = 点了没反应；搬了忘撤 = 两处并存。
run_unit /tmp/tt_wstools scripts/ql_wstools/truth_table_wstools.swift

echo "=== 20b1b. 工作台·进行项目真值表（v4.0.143：项目维度 / 不编进度 / 失败保留旧快照）==="
# 钉：挂点唯一且顺序对（进行中 → 进行项目 → 长期目标）/ 空态不摆空壳 / 拉取失败保留旧快照 /
#    无清单不画进度条 / 只用 /api/agent/projects（lucky 白名单）/ 6 小时过期标记 / 完成按钮在左。
# 全是编译不报、真机才现的坏法。
run_unit /tmp/tt_projects scripts/ql_projects/truth_table_projects.swift

echo "=== 20b1c. 清单「滑掉」状态真值表（v4.0.149 · 指纹稳定 / 换批次自动回来 / 撤销只删自己）==="
# 钉：djb2 指纹（跨启动稳定，禁 String.hashValue）/ 按本批指纹判收起 / 换批次自动重新显示 /
#    多项目各自独立 / 脏 AppStorage 不炸。全是「重启才现、隔几天才现」的坏法 → 纯逻辑跑。
rm -rf /tmp/ql_batch_main && mkdir -p /tmp/ql_batch_main
cp scripts/ql_projects/test_batch_dismissal.swift /tmp/ql_batch_main/main.swift
rm -f /tmp/test_batch_dismissal
$SWIFT/swiftc -swift-version 6 -o /tmp/test_batch_dismissal /tmp/ql_batch_main/main.swift \
    qingliao/Core/ProjectBatchDismissal.swift 2>&1 | head -10
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "❌ 清单滑掉真值表编译失败"; exit 1; }
/tmp/test_batch_dismissal || exit 1

echo "=== 20b2. 自定义下拉刷新（液体杯子）真值表（v4.0.x：用户 2026-10-14 定案）==="
# 钉：五页挂点/旧 API 已撤/核心机制（几何+相位+摇晃+@MainActor）/手感口径（medium 触觉、防重入、
#     Motion 令牌回位）/设置类反例（本批范围外）。全是**静默失效**：挂错层、并存 .refreshable、
#     下拉撞页面 3 秒节流（杯子照涨、数据不重拉）都不报错，只有真机下拉才知道。
run_unit /tmp/test_refresh scripts/ql_refresh/truth_table_refresh.swift

echo "=== 20b3. 长按锚定菜单手势优先级真值表（v4.0.x：用户 2026-10-14 报「目标卡长按不出菜单」）==="
# 钉：手势必须 highPriorityGesture（普通优先级挂在 Button 外层 = 长按全无反应，编译/其它表全绿）、
#     出菜单后打 tap 抑制窗口、被长按卡片的 tap 首行读它。纯真机才发现的一类静默失效。
run_unit /tmp/test_longpress scripts/ql_longpress/truth_table_longpress.swift

echo "=== 20b4. 蜂窝网络路径口径真值表（v4.0.x：用户 2026-10-14 报「蜂窝下载/预览」）==="
# 钉：downloadFile 蜂窝必须先直连（CFStream 免弹窗）、失败才降级 relay；relay = ASWAS 弹窗通道。
# 这类「特判走错路径」编译与真机日志都不报错，只有用户手指能发现。
run_unit /tmp/test_netpath scripts/ql_netpath/truth_table_netpath.swift

echo "=== 20b5. 定时任务推送通道真值表（v4.0.112：用户 2026-10-14「定时任务增加信息推送通道设置」）==="
# 钉：App 只传 channel 四档（both/wechat/app/none），绝不自己拼 Hermes 的 deliver；
#     新建/编辑两个请求体都要带 channel；老后端不下发该键时列表不显示假通道。
#     三处真值（iOS CronChannel / cron_api.CHANNELS / ql_task_push.APP_PUSH_CHANNELS）必须逐字对齐。
run_unit /tmp/test_cronchannel scripts/ql_cron_channel/truth_table_cron_channel.swift

echo "=== 20c. 网盘接入真值表（v4.0.x：位置口径/安全边界/后端契约/浏览护栏）==="
# 单文件（读源文件做护栏，不 import 项目代码）→ run_unit 直接编跑。
# 口径：①网盘入口只在工作区页（v4.1.x 起设置页四件套入口移除；看板连接器面板 v4.0.109 已退役）；
#      ②授权码/技能地址明文不落 App；③路径与 clouddrive_api.py 对齐；④浏览页 fid 栈与蜂窝闸。
run_unit /tmp/test_clouddrive scripts/ql_clouddrive/truth_table_clouddrive.swift

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

echo "=== 26b. 流式分段朗读真值表（v4.0.x · 满一条气泡段落即送 TTS）==="
# 两文件编译：真值表 + qingliao/Core/StreamTTSSegmenter.swift（纯 Foundation，无 UI 依赖），
# 切分口径再由表内源护栏钉住与 MessageBubble.splitParagraphs 不漂移。
# 口径：feed 只吐新凑满段、纯代码围栏段跳过不占序号、未闭合围栏永不送半截；接线钉住
# 「增量处 feed（不等 finish）+ 落库边沿 hasStreamingSpeech 守卫 + speakSegment 不先 stop」。
run_unit /tmp/test_streamtts scripts/ql_streamtts/truth_table_streamtts.swift \
    qingliao/Core/StreamTTSSegmenter.swift

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
ckNotIn() {  # ckNotIn "说明" "函数签名正则" "不该出现的模式" 文件 —— 函数体内出现即失败
    local body
    body=$(awk -v sig="$2" '
        $0 ~ sig { f=1 }
        f { print }
        f && /^    \}$/ { exit }
    ' "$4")
    if printf '%s' "$body" | grep -qE "$3"; then
        echo "❌ $1"
        fail=1
    else
        echo "✅ $1"
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
# v4.0.19：flashRecordDedup 加 itemID 参数（候选池⑯），原「无参签名存在」断言会假红。
# 本条真意 = 去重提示不得复用 intentNoContentHint 路径：钉「函数体内不含 intentNoContentHint」。
ck "去重提示不再复用 intentNoContentHint" \
   'private func flashRecordDedup' "$CV"
ckNotIn "去重提示体内不落 intentNoContentHint（复用=回归）" \
   'private func flashRecordDedup' 'intentNoContentHint' "$CV"
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
# 名单**动态推导**（按「真的调用了 SyncedStore」筛），不再手写 ——
#   v4.0.x 原名单只有 Memo/Todo/Pin，抽 SyncedStore 时新纳入的 Goal/Record 漏在名单外，
#   护栏对它们完全失守（假绿）。手写名单每加一个 Store 就会漏一次。
#   ⚠️ 不能用 `ls *Store.swift`：Core 下还有 Auth/Chat/Inbox/Diagnostics/PlanProgress/
#   SessionTag 等 6 个不同构的 Store（审计已实证：无 ISO8601+NAS 快照双写通道）。
_store_list=$(grep -ln 'SyncedStore\.' qingliao/Core/*Store.swift 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.swift$//' | grep -v '^SyncedStore$' | sort)
_store_n=$(echo "$_store_list" | grep -c .)
if [ "$_store_n" != "6" ]; then
  echo "❌ P0: 走 SyncedStore 体系的 Store 数量是 $_store_n（期望 6）：$_store_list"
  echo "      新增/删除 Store 后必须同步本段护栏名单，别让新 Store 悄悄失守"
  fail=1
fi
for st in $_store_list; do
  f="qingliao/Core/$st.swift"
  ck "$st 也有 NAS 写链 FIFO 字段" 'private var writeChain: Task<Void, Never> = Task' "$f"
  # 钉「await prev.value」而不是裸 'let prev = writeChain'：后者全文件匹配，
  # 把这行挪到任何位置（包括另一条死路径）照样绿 —— 护栏要守的是 save() 里真的等前一次写完。
  ck "$st 的 writeChain 在写链里被 await（FIFO 行为，非仅声明存在）" 'await prev\.value' "$f"
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
# v4.1.x（插话）：第三处在 interjectSendCore —— ⚡路径同样是**用户亲手**敲的那句（条件是插话走不通、
# 回落成普通发送），记账闸该开。只放行这一处，别处多一个照样红（居高临下的白名单，不是放宽阈值）。
_ij=$(awk '/private func interjectSendCore/{f=1;next} f&&/^    \}$/{exit} f' "$CV" | grep -c 'allowExpense: true')
[ "$_n" = "3" ] && [ "$_ij" = "1" ] \
  && echo "✅ allowExpense: true 共 3 处 = send() 2 处 + 插话回落 1 处（分享/任务/备忘/问AI 全部默认 false）" \
  || { echo "❌ allowExpense: true 传点 $_n 处（应 3，其中插话回落应 1、实为 $_ij），有人给非用户亲手路径开了记账闸"; fail=1; }
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

echo "=== 44. 成员作用域护栏（v4.0.x 工程治理第 3 号整改：CI #600 烧出来的）==="
# 机制：拆巨型 View 时把成员追加到**文件末尾** → 落在 struct 之外 → 语法全绿（-parse 查不出），
#   但成员引用 struct 内状态时，编译器报 "cannot find x in scope"，只有 CI Archive 才暴露。
#   2026-09-27 CI run #600 实踩：DashboardView 拆 body 时 sheetContent / dashboardSheetDismiss /
#   dashboardTask 三段被搬到文件尾，Archive 报 12 个 cannot find 'sheetZoomNS'/'nas' in scope。
# 判定：顶格 4 空格缩进的成员声明或 // MARK: 出现在任何 struct/extension 块之外 = 搬运事故。
# 双向自测已在写码时做过（好树绿 / 坏树红 3 条），改本脚本后请用 git show 旧版 DashboardView 复验。
python3 scripts/check_member_scope.py || exit 1

echo "=== 45. AI 消息图片渲染真值表（v4.0.x）==="
# 单文件（读源文件做护栏，不 import 项目代码）→ run_unit 直接编跑。工作目录 = 仓根。
# 口径：加载态用现成骨架屏（与真图同圆角 Radius.inset）、换入淡入且尊重「减弱动态效果」、
#   缓存命中不加动画、两条网络路径（含自签降级）都接线。
run_unit /tmp/test_aiimage scripts/ql_aiimage/truth_table_aiimage.swift

echo "=== 46. 上拉指示器挡板真值表（v4.0.x · 2026-09-28 用户报「AI 思考回复中不要出现」）==="
# 单文件（读源文件做护栏，不 import 项目代码）→ run_unit 直接编跑。工作目录 = 仓根。
# 口径：挡板改用 aiBusy（覆盖思考阶段的 remoteBusy 探测）；残留进度由 .onChange(of: aiBusy)
#   驱动的 inboxPullReset 清（AI 忙时滚动投影恒 0、回调不触发，写在回调里等于没写）。
run_unit /tmp/test_inboxpull scripts/ql_inboxpull/truth_table_inboxpull.swift

echo "=== 47. 流式轮次代次真值表（v4.0.x · startSeq 只增序号）==="
# 单文件（读源文件做护栏，不 import 项目代码）→ run_unit 直接编跑。工作目录 = 仓根。
# 口径：isStreaming 的 false→true 会被 finish 同帧续发吞掉，UI 端一律改看只增的 startSeq；
#   三个开跑入口（start / restoreIfNeeded / adoptRemote）都要自增。
run_unit /tmp/test_streamseq scripts/ql_streamseq/truth_table_streamseq.swift

echo "=== 48. AI 中途追问「问题卡」真值表（v3.9.110）==="
# 单文件（读源文件做护栏，不 import 项目代码）→ run_unit 直接编跑。工作目录 = 仓根。
# 口径：问题卡必须从 MessageBubble.body 早退到独立组件（漏 = 退化成普通气泡）；作答先本地
#   落地再发网络；两端题干格式（iOS splitQuestion ↔ 后端 OPT_SEP_LINE）必须一致。
run_unit /tmp/test_askquestion scripts/ql_askquestion/truth_table_askquestion.swift

echo "=== 49. 首页「方块卡片」真值表（v4.0.10 起 · 153 项 · v4.0.93 补取件码段）==="
# 多文件编译：被测真源是**纯 Foundation** 的 HomeCardOrder.swift（无 SwiftUI 依赖），
# 直接编真实实现而不是照抄一份镜像 → 不存在「表与实现漂移」这个洞。
# 多文件时只有 main.swift 允许顶层代码（第 4 步同口径），故先 cp 成 main.swift。
# 口径：相对位移拖拽（微抖不甩位）、写回保位（关掉的卡留原槽）、至少留一张真卡（全关只剩空槽位
#   用户会当 App 坏了）、键字面量单一真源、UI 不自算几何、ChatView 挂载形态、
#   v4.0.10 真机坏形三条：**卡高恒定**（副标题恒单行，禁 .fixedSize 竖直撑开——双行会让
#   内容 94pt 顶在 84pt 槽位里居中溢出）、**长按拖动不被 Button 抢**（simultaneousGesture +
#   拖完不吃轻点）、**栏目头「自定义」胶囊变矮**（借聊天页顶栏那档 27pt → 新栏目头档 23pt，
#   只压高度，且聊天页那两枚不许跟着变），三条都配真机报修图/原话；
#   v4.0.10 再加**总开关**（用户要求）：设置「通用」（v4.1.0 前叫「外观与显示」）里一行「首页快捷卡片」，关掉 = 整块不渲染
#   且不留空占位；键缺失 = 开（老用户行为不变），默认值走 HomeCardStore.enabledDefault 单一真源。
#   v4.0.93（用户：「app 聊天首页增加取件码卡片，卡片上可以显示取件码，点开弹窗取件码」）：
#   新增 ⑬ 段 —— 编译列表加 PickupCodeKit.swift（纯 Foundation 的取件码解析，视图里不许另写一套），
#   并补三处护栏：HomeCardLabels 三表覆盖全部 kind（本批阻断就是漏 icon）／两宿主分派行／
#   detail 必须从「取件码」锚点之后定位。数据源 = 本地 TodoStore.sorted，零后端改动。
rm -rf /tmp/ql_homecards_main && mkdir -p /tmp/ql_homecards_main
cp scripts/ql_chat_home/truth_table_homecards.swift /tmp/ql_homecards_main/main.swift
run_unit /tmp/test_homecards -swift-version 6 /tmp/ql_homecards_main/main.swift \
    qingliao/Core/HomeCardOrder.swift \
    qingliao/Core/PickupCodeKit.swift

echo "=== 50b. Dock 栏顺序/隐藏真值表（v4.0.82：用户可配 dock 档序 + 隐藏，设置页恒不可隐藏）==="
rm -rf /tmp/ql_docklayout_main && mkdir -p /tmp/ql_docklayout_main
cp scripts/ql_docklayout/truth_table_docklayout.swift /tmp/ql_docklayout_main/main.swift
run_unit /tmp/test_docklayout -swift-version 6 /tmp/ql_docklayout_main/main.swift \
    qingliao/Core/DockLayoutKit.swift \
    qingliao/Core/ChatEdgeBackKit.swift

echo "=== 50c. 启动页三拍转场真值表（v4.0.117：Logo 呼吸 → 圆形遮罩扩散铺满 → 首页各块次第上浮）==="
# 用户 2026-10-15：启动页做成「拉开幕布」——呼吸一次 → 以 Logo 为圆心挖洞扩散 → 首页从圆里露出来 →
#   首页各块自下而上次第浮起（每块 60ms）。四拍全靠时序串起来，被后人「顺手简化」不会有编译错也不崩，
#   只能代码级钉（详见表头注释）。
rm -rf /tmp/ql_launch_main && mkdir -p /tmp/ql_launch_main
cp scripts/ql_launch/truth_table_launch.swift /tmp/ql_launch_main/main.swift
run_unit /tmp/test_launch -swift-version 6 /tmp/ql_launch_main/main.swift

echo "=== 50d. MCP 工具服务行图标真值表（v4.0.117：后端模板 icon + App 按名兜底映射）==="
# 用户 2026-10-15：MCP 列表每行原先把拼图图标写死，所有服务长得一样。
# 现为「后端模板自带 icon/color → 空则按服务名关键字兜底 → 拼图块」。
# 表里拿**用户 NAS 上真实注册的 5 个 MCP**（browser-agent / luckin / office / wenyan /
# xunlei-download）复刻匹配语义跑一遍 —— 关键字表被后人改窄/改错，这里当场红。
# ⚠️ 表内 resolve() 标了 @MainActor（Swift 6 下顶层变量是 MainActor 隔离的），别去掉。
run_unit6 /tmp/test_mcpicon scripts/ql_mcpicon/truth_table_mcpicon.swift

echo "=== 50. 智慧球菜单胶囊几何真值表（v4.0.x）==="
# 事故：v3.9.96 把最上排改成 3 列时，center() 的列位算式写成
#   CGFloat(i >= 6 ? i - 7 : i % 3) - 1 —— 外面那个 -1 把 6/7/8 映射成 −2/−1/0，
#   整排左移一列，「会话纪要」在 375pt 屏上中心 x=−48.5pt、左缘 −99pt，整颗飞出屏幕左侧。
# 正确形态：−1 只作用于 i<6 那段（i%3 − 1）；i≥6 段本身即 −1/0/+1、不再减。
#   —— 直接删掉那个 -1 会引入第二个 bug：下/中排列位变 0/1/2，430pt 屏最右列飞出右边。
# 本表从生产源码解析列位算式（不写镜像实现），并对两个历史事故形态各钉一条反向断言。
python3 scripts/ql_orbmenu/truth_table_orbmenu_geom.py || exit 1

echo "=== 51. 弹窗风格真值表（v4.0.x）==="
# 事故：v4.0.11 主动 Agent 弹窗自带实色底（systemGroupedBackground）+ 锁 [.large] 全屏，
#       与其它半屏玻璃弹窗不统一（用户口径：「其他弹窗是弹窗一半，背景是半透明毛玻璃」）。
# 真源决策：qingliao/Theme/LiquidGlass.swift:471-487（v3.9.23，勿再尝试挂 presentationBackground 材质）。
# 本表把口径钉成代码级断言 —— 风格不许靠记忆。
python3 scripts/ql_sheet_style/truth_table_sheet_style.py 2>&1 | tee /tmp/tt_sheet.log
grep -q '✅ ALL PASS' /tmp/tt_sheet.log || fail=1

echo "=== 52. 固定会话真值表（v4.0.x proactive）==="
# 用户实测 bug：「主动 Agent 消息串进正常会话」。根因：proactive_agent.deliver() 走
# inbox_api.push(task_type="agent")，而 push 无 session_id 参数 → 消息只进 inbox 池，
# App 侧 InboxStore.consumeOne 再 chat.append 注入「当前会话」。v4.0.x 给它自己的
# 固定会话 qingliao_proactive（轻聊主动），与投递壳「轻聊投递」区分：可回复、NAS 为准。
python3 scripts/ql_fixed_session/truth_table_fixed_session.py 2>&1 | tee /tmp/tt_fixed.log
grep -q '✅ ALL PASS' /tmp/tt_fixed.log || fail=1

echo "=== 53. 记忆条目结构化真值表（v4.0.x 第 4 项）==="
# 事故背景：本项**故意没改**后端 entries 的结构（仍是 [str]），只在旁边挂 meta 表。
#   理由：entries 是全仓最热共享结构（App 三处 + WebUI qllm.js + prompt_block 注入 +
#   proactive 偏好块全按字符串读它），换成 [dict] 会让那些地方**静默渲染成空白**。
#   本表钉两件事：① App 侧状态取值与后端 memory_store.STATUSES 逐字一致（漂了就空白胶囊）
#   ② MemoryView 已彻底不直接读后端 entries 字段渲染（回落只允许在 MemoryEntry.parse 里）。
python3 scripts/ql_memometa/truth_table_memoitem.py 2>&1 | tee /tmp/tt_memoitem.log
grep -q '✅ ALL PASS' /tmp/tt_memoitem.log || fail=1

echo "=== 54. 主动跟进闭环真值表（v4.0.x 第 5 项）==="
# 两张表都要跑：后端表验「到没到点 + 次数上限 + 剪枝」，App 表验「界面不自己重算到期 /
# 检查按钮不真投递 / 勾销不在前端删计数」。缺任一张都会漏事故：后端全对而 App 误传
# dry_run:false，点一下「现在检查」就真发消息并吃掉一次提问机会。
# 后端表跑的是 NAS 上**线上那份字节**（ql.py nas read 现拉），不是镜像实现；
# 拉不到（离线/NAS 不可达）时明确跳过而不是拿本地副本凑一个假绿。
FU_DIR=scripts/ql_followup
FU_TMP=/opt/data/cache/scratch
# ql.py = 本机统一入口（/opt/data/scripts/ql.py，仓外）；这里只用来现拉线上字节，
# 表本身已随仓走（scripts/ql_followup/）。离线时走 else 分支明确跳过，不凑假绿。
if python3 /opt/data/scripts/ql.py nas read 微信文件/轻聊web/backend/proactive_agent.py > "$FU_TMP/pa_live.py" 2>/dev/null \
   && python3 /opt/data/scripts/ql.py nas read 微信文件/轻聊web/backend/memory_api.py > "$FU_TMP/mapi_live.py" 2>/dev/null \
   && [ -s "$FU_TMP/pa_live.py" ] && [ -s "$FU_TMP/mapi_live.py" ]; then
  ( cd "$FU_DIR" && python3 truth_table_followup.py ) 2>&1 | tee /tmp/tt_fu_be.log
  if grep -q '❌' /tmp/tt_fu_be.log; then fail=1; echo "❌ 第 5 项后端表有失守"; fi
else
  echo "⚠️ 拉不到线上后端副本（离线），第 5 项后端表本轮未跑"
fi
run_unit /tmp/test_fu_app scripts/ql_followup/truth_table_followup_app.swift | tee /tmp/tt_fu_app.log
grep -q '0 失败' /tmp/tt_fu_app.log || fail=1

echo "=== 55. 反思日记真值表（v4.0.x 第 6 项）==="
# 后端表验「几点问 / 一天一次 / 周一才发周回顾 / 答案截断 / 90 天剪枝 / 总开关」，
# App 表验「问句不自造 / 预览不真投递 / 答问不谎报已存 / Stepper 区间与后端一致」。
# 后端表同样跑线上那份字节（QL_PA_SRC 指向现拉的副本），离线时明确跳过不凑假绿。
JN_DIR=scripts/ql_journal
if python3 /opt/data/scripts/ql.py nas read 微信文件/轻聊web/backend/proactive_agent.py > "$FU_TMP/pa_journal_live.py" 2>/dev/null \
   && [ -s "$FU_TMP/pa_journal_live.py" ]; then
  ( cd "$JN_DIR" && QL_PA_SRC="$FU_TMP/pa_journal_live.py" python3 truth_table_journal.py ) 2>&1 | tee /tmp/tt_jn_be.log
  if grep -q '❌' /tmp/tt_jn_be.log; then fail=1; echo "❌ 第 6 项后端表有失守"; fi
else
  echo "⚠️ 拉不到线上后端副本（离线），第 6 项后端表本轮未跑"
fi
run_unit /tmp/test_jn_app.bin scripts/ql_journal/truth_table_journal_app.swift | tee /tmp/tt_jn_app.log
grep -q '0 失败' /tmp/tt_jn_app.log || fail=1

echo "=== 56. 记账账本真值表（候选池 ⑤ 明细 / ⑥ 趋势 / ⑦ 预算 / ⑨ 固定支出 / ⑫ 导出 / ⑬ 周趋势）==="
# 表在仓内 scripts/ql_record/truth_table_record.swift（纯 Foundation，不依赖 UI）。
# 钉死的口径：① 明细按 createdAt 分日（编辑不改发生日）② 日/周/月小计**只算「元」**，度数不进钱、
# ③ 收入单列绝不并进支出 ④ 近 N 天窗口含今天且左边界闭区间 ⑤ 月末预估不除零、空账本不出 NaN。
# 这几条漏一条，用户看到的就是假数字 —— 所以反例（读数/收入/跨窗口旧账）占本表近一半。
run_unit /tmp/test_record_stats scripts/ql_record/truth_table_record.swift qingliao/Core/RecordKit.swift | tee /tmp/tt_record.log
grep -q '0 失败' /tmp/tt_record.log || fail=1

# 候选池 ⑦⑨⑫ 的 UI 入口存在性：入口被误删时功能是「悄悄消失」的，编译不会报错、真值表也测不到 UI。
grep -q 'private struct RecordBudgetSheet' qingliao/Features/Life/RecordSection.swift \
  || { echo "❌ 缺月预算弹窗（候选池⑦）"; fail=1; }
grep -q 'private struct FixedExpenseSheet' qingliao/Features/Life/RecordSection.swift \
  || { echo "❌ 缺固定支出管理（候选池⑨）"; fail=1; }
grep -q 'store.applyFixedExpenses()' qingliao/Features/Life/RecordSection.swift \
  || { echo "❌ 固定支出没有入账触发点（设了也不会自动记）"; fail=1; }
grep -q 'TableCSVExport.makeCSV(rows: RecordKit.csvRows' qingliao/Features/Life/RecordSection.swift \
  || { echo "❌ 缺账本 CSV 导出（候选池⑫）"; fail=1; }
grep -q 'RecordKit.budgetLevel' qingliao/Features/HomeCards.swift \
  || { echo "❌ 首页卡没接预算水位（候选池⑦⑬：超支了卡片看不出来）"; fail=1; }

echo "=== 57. 气泡来源角标真值表（v4.0.20 · 区分 cron/主动 Agent/系统/后台推进/回复）==="
# 用户诉求：「我不知道当前任务是前台任务还是触发了后台自主推进任务」→ 气泡角标按来源分色。
# 表钉的是**纯映射**（PushKind.style）+ 源接线（InboxStore 每类消息都真的赋了 kind）。
run_unit /tmp/test_pushkind scripts/ql_pushkind/truth_table_pushkind.swift

echo "=== 58. 目标后台状态真值表（v4.0.20 · 交接回执 / 健康点 / 推进时间线 / 第几步标注）==="
# 覆盖：① 交接待办卡回执 ② 目标卡后台状态条 ③ 推进时间线 ④ 任务中心「第 k/N 步」角标
# ⑤ 后端接线护栏 —— 只有能看见线上后端源时第 ⑤ 段才真跑（CI 里打印「⚠️ 跳过」）。
# 想本地覆盖后端那几条：先 `ql backend fetch` 拉到副本，或设 QL_BE 指向后端目录。
run_unit /tmp/test_goalbg scripts/ql_goalbg/truth_table_goalbg.swift

echo "=== 59. 看板拖拽排序真值表（v4.0.20 · 归一化 / 落位几何 / 键单一真源）==="
# 本表**直接编译 BoardCardOrder.swift 真源**（不是镜像 → 没有表/实现漂移的洞）。
# 多文件编译时顶层代码只允许待在 main.swift → 先拷成 main.swift 再编
# （等价形态见 scripts/ql_record/truth_table_record.swift 头部注释）。
rm -rf /tmp/ql_board_main && mkdir -p /tmp/ql_board_main
cp scripts/ql_board/truth_table_board.swift /tmp/ql_board_main/main.swift
run_unit /tmp/test_board /tmp/ql_board_main/main.swift qingliao/Core/BoardCardOrder.swift

echo "=== 60. 扫账单真值表（v4.0.22 候选池⑪ App 入口 · 金额缺失 / 失败口径 / 分类白名单 / 浮点）==="
# 表在仓内 scripts/ql_bill/truth_table_bill.swift（纯 Foundation，编译真源 Core/BillScanKit.swift）。
# 钉死的口径：① amount 缺失 → 草稿出但金额 nil（不许拿 0 冒充）② amount+item 双空 → 判失败
# ③ ok 才是成败判据（HTTP 一律 200）④ category 越界收敛成「其他」⑤ 进账本前四舍五入到分。
run_unit6 /tmp/test_bill scripts/ql_bill/truth_table_bill.swift qingliao/Core/BillScanKit.swift | tee /tmp/tt_bill.log
grep -q '0 失败' /tmp/tt_bill.log || fail=1

echo "=== 61. 设置页搜索真值表（v4.0.22 · 匹配规则 + 路由真值 + 视图接线）==="
# 表在仓内 scripts/ql_settings_search/truth_table_settings_search.swift（编译真源 Core/SettingsSearchIndex.swift）。
# 除了匹配规则，本表还做**源级路由核验**：索引每条 route 都必须在 SettingsCore.openSearchEntry 里被处理，
# sec:* 路由必须有 .id("…") 锚点 —— 漏一条就是「搜到了点下去没反应」。
run_unit6 /tmp/test_settings_search scripts/ql_settings_search/truth_table_settings_search.swift qingliao/Core/SettingsSearchIndex.swift | tee /tmp/tt_settings_search.log
grep -q '0 失败' /tmp/tt_settings_search.log || fail=1

echo "=== 62. 流式平滑层推进真值表（v4.0.23 · 空气泡回归）==="
# 事故：v3.4.20 平滑层推进在 smoothedContent 自己的副本上切片 → 空串起步 index(offsetBy:limitedBy:)
# 恒 nil → 每 tick 切出空串 → 流式期间 displayContent 恒空（聊天页气泡是空壳，思考三点被顶掉），
# 收尾 stopSmooth 才一次性补齐全文。2026-10-02 真机反馈「工具调用一出来思考气泡动画就消失」。
# A 段验算法本身（Core/SmoothRelease.swift），B 段读 StreamClient.swift 钉死接线、防旧写法复活。
run_unit6 /tmp/test_smooth scripts/test_smooth.swift qingliao/Core/SmoothRelease.swift

echo "=== 63. 聊天页贴底推进真值表（v4.0.36 · 流式气泡不往上顶）==="
# 事故：贴底判定原先是内联闭包里一个 Bool（“现在在不在底部”）直接赋给 isScrollPinned，
# 分不清「谁让内容不在底部」→ 流式 delta 让内容长高时同帧 offset 未动，被判成「用户上滑」，
# 自动滚底整段熄火，最新一行一路沉到输入栏下面（2026-10-03 用户实报）。
# A 段验推进算法本体（Core/ChatScrollPin.swift），B 段读 ChatView.swift 钉死接线与旧形态清除。
run_unit6 /tmp/test_scrollpin scripts/ql_scrollpin/truth_table_scrollpin.swift qingliao/Core/ChatScrollPin.swift | tee /tmp/tt_scrollpin.log
grep -q '0 失败' /tmp/tt_scrollpin.log || fail=1

echo "=== 63b. 上下文压缩按体量真值表（v4.0.154 · ContextBudget）==="
# 口径：手动压缩从「保留最近 20 条」改成「按字符预算从最新往回累计」。
# 旧口径对「20 条 / 14 万字（单条 13 万字）」的会话直接静默返回 false = 用户实报的「压缩失效」。
run_unit6 /tmp/test_contextbudget scripts/ql_contextbudget/truth_table_contextbudget.swift qingliao/Core/ContextBudget.swift | tee /tmp/tt_contextbudget.log
grep -q '0 失败' /tmp/tt_contextbudget.log || fail=1

echo "=== 64. 任务中心结构化步骤真值表（v4.0.37 · plan[]）==="
# 口径（OpenMuse 借鉴⑧）：任务中心原先进度只有一行拼出来的字符串，看不出「几步 / 到哪步 / 每步多久」。
# 后端 /api/agent/tasks/active 的流式任务补 plan[] + planSeq（复用 toolSpans/toolSeq 埋点，零新增采集），
# 任务中心渲染成步骤清单。表分三段：plan[] 解析语义（编译真实 Core/ActiveTaskPlan.swift）、
# App 接线、后端下发（读 NAS 运行源）。
run_unit6 /tmp/test_taskplan scripts/ql_taskplan/truth_table_taskplan.swift qingliao/Core/ActiveTaskPlan.swift | tee /tmp/tt_taskplan.log
grep -q '0 失败' /tmp/tt_taskplan.log || fail=1

# v4.0.22 两处新入口的存在性：入口被误删时功能是「悄悄消失」的（编译不报、真值表也测不到 UI）。
# ⚠️ 一律**先剥行注释再匹配**（注释里出现同名串不算数，否则就是假绿护栏 —— 审查实测删掉真入口后
# 原版 `grep -q '扫账单'` 仍命中注释照样绿）。匹配串取**代码形态**（调用实参/成员访问），不取裸词。
strip_comments() { sed 's://.*::' "$1"; }
strip_comments qingliao/Features/Life/RecordSection.swift | grep -q 'secondaryAction: (title: "扫账单", action:' \
  || { echo "❌ 记录页缺「扫账单」入口（候选池⑪ App 入口）"; fail=1; }
strip_comments qingliao/Features/Life/RecordSection.swift | grep -q 'BillScanSheet().id(billScanSession)' \
  || { echo "❌ 扫账单弹窗没挂 .id(会话号)：SwiftUI 复用上次状态（重开带旧图/旧金额）"; fail=1; }
strip_comments qingliao/Features/Life/LifeSectionScaffold.swift | grep -q 'Button(action: secondaryAction.action)' \
  || { echo "❌ 页级标题行没消费次要动作槽位（入口没地方挂）"; fail=1; }
strip_comments qingliao/Features/Life/BillScanSheet.swift | grep -q '"/api/agent/intent/bill"' \
  || { echo "❌ 扫账单没打后端识别接口（App 端自造识别=假数据）"; fail=1; }
strip_comments qingliao/Features/Settings/SettingsCore.swift | grep -q 'SettingsSearchBar(text: \$settingsQuery)' \
  || { echo "❌ 设置页缺搜索框"; fail=1; }

echo "=== 66. 气泡动画真值表（v4.0.39 · 发送弹出 / 流式光带 / 三点上浮）==="
# 三处动画全是 SwiftUI 修饰符挂载（无 SwiftUI 的 headless Linux 跑不了真视图），所以这张表
# 全是源级断言：钉挂载点、钉调度纪律（禁 keyframeAnimation —— 本仓三点动画 v4.0.12/v4.0.14/v4.0.19
# 三次在 pausable schedule 上翻车）、钉旧形态已清除，末段还做 4 条反向自证防恒真。
# 本轮实踩：patch 锚点 `骨架换真图走淡入` 在 AIImageView 里也出现 → 光带组件被塞进修饰符链，
# 能编译、语义全错。B7 专钉这个。
# ⚠️ 多文件一起编译时 swiftc 只允许 main.swift 里有顶层代码 → 复制成 main.swift 再编。
# B6c 段要实跑 MessageInsertAnim 这个纯函数（v4.0.40 补的测试网，之前零覆盖）。
mkdir -p /tmp/ql_bubbleanim_main && cp scripts/ql_bubbleanim/truth_table_bubbleanim.swift /tmp/ql_bubbleanim_main/main.swift
run_unit6 /tmp/test_bubbleanim /tmp/ql_bubbleanim_main/main.swift qingliao/Core/MessageInsertAnim.swift | tee /tmp/tt_bubbleanim.log
# ⚠️ 这里不能用 `grep -q '0 失败'`：本表末尾打的是「✅ 全部通过 N」（无「失败」二字），
# 那条 grep 会恒红、fail 被永久置 1 → 全量预检收尾必报「有护栏失守」（踩过一次）。
# 断言口径与 run_unit6 的退出码一致：非 0 即红。
grep -q '✅ 全部通过' /tmp/tt_bubbleanim.log || fail=1

echo "=== 67. 建议池① 提问推荐「猜你想问」真值表（v4.0.42）==="
# 三段：FollowUpSuggest 纯函数（真编译真跑）+ ChatStore 锚点算法（影子实现跑同款语义）
#        + 源级接线断言（点候选不重复插消息 / 换一批是替换 / 空候选不渲染 / 不落库不进 id）。
# 后端那条链由 scripts/ql_followup_suggest/test_suggest_api.py 覆盖（跑线上字节）。
# 走 run_unit6：与 CI 严格并发口径对齐（v4.0.22 教训：Swift 5 编过的表本地绿、CI 才炸）。
mkdir -p /tmp/ql_sug_main && cp scripts/ql_suggest/truth_table_suggest.swift /tmp/ql_sug_main/main.swift
run_unit6 /tmp/test_suggest /tmp/ql_sug_main/main.swift qingliao/Core/FollowUpSuggest.swift | tee /tmp/tt_suggest.log
grep -q '0 失败' /tmp/tt_suggest.log || fail=1
# 源级入口存在性：候选区视图真挂在 messageRow 里（剥行注释再匹配代码形态，防注释喂绿）
strip_comments qingliao/Features/Chat/ChatView.swift | grep -q 'followUpSuggestionsRow(msg)' \
  || { echo "❌ messageRow 没挂追问候选区"; fail=1; }
strip_comments qingliao/Core/ChatStore.swift | grep -q 'func applySuggestions(_ questions: \[String\], afterUserID: String?)' \
  || { echo "❌ ChatStore 缺 applySuggestions（候选无处可挂）"; fail=1; }
strip_comments qingliao/Core/FollowUpSuggest.swift | grep -q 'static let endpoint = "/api/agent/suggest_questions"' \
  || { echo "❌ 端点字面量不在纯逻辑单一真源里"; fail=1; }

echo "=== 68. 长期目标 5 项改进真值表（v4.0.40 · 现在开始推进/任务中心/推原会话/自动划掉/开始时间）==="
# 覆盖：① 步骤时间文案与「无戳不渲染」② 完成判定与未完成优先排序 ③ needs-user 解析口径
#      ④ iOS 新字段解码兜底 + 胶囊接线 + 已完成折叠 ⑤ 后端 push_now / bgjobs 落盘 / 待办联动
# 与第 58 项（ql_goalbg）的分工：那表钉「后台状态可见性」，本表钉「手动推进 + 自动收尾闭环」。
run_unit /tmp/test_goal_pushnow scripts/ql_goal_pushnow/truth_table_goal_pushnow.swift

# v4.0.42 run #668 实踩：删掉 GoalsSection.stamp 时漏改了另外 4 处 `Self.stamp(...)`，
# 而 `-parse` 不查成员存在性 → 预检全绿、CI Archive 才报 has no member 'stamp'。
# 类级教训：删/改一个成员前，全仓 grep 该成员的全部引用点逐个改，别只改「看到的那几处」。
ckNot "残留 Self.stamp（stamp 已迁到 GoalRowCard，GoalsSection 上不存在）" \
  "Self\\.stamp\\(" qingliao/Features/Life/GoalsSection.swift
ck "GoalRowCard.stamp 必须是 nonisolated static 且非 private（供 GoalsSection 跨类型调用）" \
  "^    static func stamp\\(_ d: Date\\) -> String" qingliao/Features/Life/GoalsSection.swift

echo "=== 69. 长期目标后台推进闭环真值表（v4.0.44 · 报告回写 / 每步通知 / 确认卡 / 步骤序号 / 下一步状态）==="
# 用户 7 条要求里的 ③④⑤⑥ 段对应的实现口径：
#   ① 报告回写：cron 桥 ql_task_push.py → 后端 goals_report_from_cron（按 cronJobID 精确匹配，
#      job 名不可信——生产上真实目标的 job 名是自定义的；非目标 job → skipped 不算失败）
#   ② 每步完成 → 推一条 system 进轻聊投递 + **单步**待办联动划掉（不是只在全完成时一把划）
#   ③ 需要拍板 → question 卡（可点选/可手输）+ 答案回写目标时间线 + 注入原会话
#   ④ 进行中作业详情带「正在推进 第 k/N 步」 ⑤ 下一步标「进行中 / 预计 X 开始 / 待开始」
#   ⑥ 步骤清单显式「第 N 步」（enumerated + 保 element.id）
# 纯逻辑走**镜像**：GoalSchedule.swift 里的 GoalItem 扩展依赖 GoalStore.swift（import SwiftUI），
# 本机无 SwiftUI 编不了 → 与第 68 段同口径（镜像口径 + 剥注释后的源级断言双保险）。
# ⚠️ 不写 `run_unit6 … | tee`：管道会把 run_unit6 内部的 `exit 1` 吞进子壳（脚本照常往下走），
# 且 `grep -q '0 失败'` 会被「10 失败 / 20 失败」子串误命中 → 两条假绿通道（审查抓到）。
# 改为自己编自己跑：退出码 + 收紧的结论行判据，双闸门。
rm -f /tmp/test_goal_loop
if ! $SWIFT/swiftc -swift-version 6 -o /tmp/test_goal_loop scripts/ql_goal_loop/truth_table_goal_loop.swift > /tmp/tt_goal_loop.log 2>&1; then
  echo "❌ 第 69 段真值表编译失败"; tail -5 /tmp/tt_goal_loop.log; fail=1
elif /tmp/test_goal_loop >> /tmp/tt_goal_loop.log 2>&1; then
  echo "  $(tail -1 /tmp/tt_goal_loop.log)"
  grep -qE '/ 0 失败$' /tmp/tt_goal_loop.log || { echo "❌ 第 69 段结论行异常（须以「/ 0 失败」结尾）"; fail=1; }
else
  echo "❌ 第 69 段真值表判定失败（改坏必红）"; tail -6 /tmp/tt_goal_loop.log; fail=1
fi

echo "=== 70. 改口重答真值表（v4.0.44 待做池 3 · 只允许改最后一条 user / 旧回答折叠「已修改」/ 失败还原）==="
# 用户 2026-10-04 卡片拍板：① 折叠态复用现有灰气泡（与「撤回」同款）② 只允许改最后一条 user 消息。
# A 段**真编译真跑** qingliao/Core/MessageEditKit.swift（纯 Foundation，与实现同一份文件 →
# 没有「表/实现漂移」的洞）：钉「哪条能改（最后一条 user，排除失败/撤回/推送/问题卡）」与
# 「折叠哪几条（锚点之后的回答，问题卡与推送不折叠）」。
# B 段用**剥注释**的源级断言钉接线与四条护栏：① 折叠只 flip 标记、不清正文（原文留给回退/导出/分享）
# ② 失败还原不留白 ③ 折叠不进模型上下文 ④ AI 侧菜单没有「编辑」 ⑥ edited 不复用 withdrawn。
# ⚠️ 不写 `run_unit6 … | tee`（与第 69 段同因：管道吞 exit 1，且 '0 失败' 会被「10 失败」误命中）。
rm -f /tmp/test_editmsg
if ! $SWIFT/swiftc -swift-version 6 -o /tmp/test_editmsg \
     scripts/ql_editmsg/truth_table_editmsg.swift qingliao/Core/MessageEditKit.swift > /tmp/tt_editmsg.log 2>&1; then
  echo "❌ 第 70 段真值表编译失败"; tail -5 /tmp/tt_editmsg.log; fail=1
elif /tmp/test_editmsg >> /tmp/tt_editmsg.log 2>&1; then
  echo "  $(tail -1 /tmp/tt_editmsg.log)"
  grep -qE '/ 0 失败$' /tmp/tt_editmsg.log || { echo "❌ 第 70 段结论行异常（须以「/ 0 失败」结尾）"; fail=1; }
else
  echo "❌ 第 70 段真值表判定失败（改坏必红）"; tail -6 /tmp/tt_editmsg.log; fail=1
fi

echo "=== 71. 生活数据报表真值表（v4.0.45 待做池 4 · 逐日序列 / 只算元支出 / 就绪门槛 / 同源 / 入口）==="
# 纯逻辑**真编译真跑** qingliao/Core/RecordKit.swift：钉 dailySeries（近 N 天升序、缺天补 0）、
# daysWithExpense / trendReady / seriesPeak 的口径；A–E 段含零值/单点/窗口边界/收入与读数排除/同源对拍。
# F 段用**剥注释**的源级断言钉接线与护栏：报表视图必须调 RecordKit 纯函数喂数（禁视图内二次聚合）、
# 折线(addLine)与环图(addArc)都真在、配色复用 RecordCategoryColor、入口已接线。
# ⚠️ 不写 `run_unit … | tee`（与 69/70 段同因：管道吞 exit 1，'0 失败' 会被「10 失败」误命中）。
rm -f /tmp/test_qlreport
if ! $SWIFT/swiftc -swift-version 6 -o /tmp/test_qlreport \
     scripts/ql_report/truth_table_report.swift qingliao/Core/RecordKit.swift > /tmp/tt_report.log 2>&1; then
  echo "❌ 第 71 段真值表编译失败"; tail -5 /tmp/tt_report.log; fail=1
elif /tmp/test_qlreport >> /tmp/tt_report.log 2>&1; then
  echo "  $(tail -1 /tmp/tt_report.log)"
  grep -qE '/ 0 失败$' /tmp/tt_report.log || { echo "❌ 第 71 段结论行异常（须以「/ 0 失败」结尾）"; fail=1; }
else
  echo "❌ 第 71 段真值表判定失败（改坏必红）"; tail -6 /tmp/tt_report.log; fail=1
fi

# 入口/视图存在性（剥注释 → 只看代码形态，本仓「注释里写了就假绿」的老坑）
[ -f qingliao/Features/Life/RecordReportSheet.swift ] \
  || { echo "❌ 缺数据报表页（待做池④）"; fail=1; }
strip_comments qingliao/Features/Life/RecordSection.swift | grep -q '\.sheet(isPresented: \$showReport) { RecordReportSheet() }' \
  || { echo "❌ 报表入口未接线（待做池④）"; fail=1; }
strip_comments qingliao/Features/Life/RecordSection.swift | grep -q 'accessibilityLabel("数据报表")' \
  || { echo "❌ 报表入口缺可访问标签（待做池④）"; fail=1; }

echo "=== 72. 习惯打卡真值表（v4.0.46 待做池⑤ · v4.0.104 扩计量维度 · 每天一次 / 不可补签 / 本地日归日）==="
# 口径（**用户 2026-10-04 在 App 选项卡拍板**，见台账待做池⑤）：每天一次 + **不可补签**，
# 连续天数=连续自然日、漏一天归零；频次不做「每周 N 次」。
# A–D 段**真编译真跑** qingliao/Core/HabitKit.swift（纯 Foundation，与实现同一份文件 →
# 没有「表/实现漂移」的洞）：钉打卡幂等、本地日切分（23:59 vs 次日 00:01、跨时区不写死 UTC）、
# 连续天数归零 / bestStreak 保留历史 / currentStreak 今天未打卡从昨天数（不谎报）、
# 空习惯不崩、lastNDays 升序缺天补 false。
# E 段用**剥注释**的源级断言钉接线与口径：① 不可补签——HabitKit/HabitStore 代码里不得出现补签路径
# ② 视图不越权重算连续天数/不直接改 days（口径收在 HabitKit）③ 生活页几何单一来源
# （MemoCardMetrics / LifeEmptyStateCard / LifeSectionHeader）④ Store 走 SyncedStore FIFO 写链 +  NAS 双写
# ⑤ 生活页栏目已接线（LifeSection .habit / LifeView switch / App attach）。
# ⚠️ 不写 `run_unit … | tee`（与 69/70/71 段同因：管道吞 exit 1，'0 失败' 会被「10 失败」误命中）。
rm -f /tmp/test_habit
if ! $SWIFT/swiftc -swift-version 6 -o /tmp/test_habit \
     scripts/ql_habit/truth_table_habit.swift qingliao/Core/HabitKit.swift > /tmp/tt_habit.log 2>&1; then
  echo "❌ 第 72 段真值表编译失败"; tail -5 /tmp/tt_habit.log; fail=1
elif /tmp/test_habit >> /tmp/tt_habit.log 2>&1; then
  echo "  $(tail -1 /tmp/tt_habit.log)"
  grep -qE '/ 0 失败$' /tmp/tt_habit.log || { echo "❌ 第 72 段结论行异常（须以「/ 0 失败」结尾）"; fail=1; }
else
  echo "❌ 第 72 段真值表判定失败（改坏必红）"; tail -6 /tmp/tt_habit.log; fail=1
fi

# 入口/视图存在性（剥注释 → 只看代码形态，本仓「注释里写了就假绿」的老坑）
[ -f qingliao/Features/Life/HabitSection.swift ] \
  || { echo "❌ 缺习惯栏目视图（待做池⑤）"; fail=1; }
[ -f qingliao/Core/HabitStore.swift ] \
  || { echo "❌ 缺习惯 Store（待做池⑤）"; fail=1; }
strip_comments qingliao/Features/Life/LifeSection.swift | grep -q 'case habit' \
  || { echo "❌ LifeSection 未加 .habit（待做池⑤）"; fail=1; }
strip_comments qingliao/Features/Life/LifeView.swift | grep -q 'case \.habit: HabitSection()' \
  || { echo "❌ 生活页 switch 未接线 .habit → HabitSection()（待做池⑤）"; fail=1; }
strip_comments qingliao/QingliaoApp.swift | grep -q 'HabitStore\.shared\.attach(auth: auth)' \
  || { echo "❌ App 启动未 attach HabitStore（待做池⑤）"; fail=1; }

echo "=== 73. 问题卡投递路由真值表（v4.0.46 · question 必须落会话可作答，不得被投递壳短路吞掉）==="
# ⚠️ v4.0.46 提交漏挂（→ §42 护栏覆盖率守卫会红并 exit 1，把 §43 起的全部真值表/守卫**整段跳过**，
#    本地预检等于半瘫）。本段补挂；表本身实测 43/0 绿。口径：question 卡不得走「归属=投递壳 → 静默 markDone」。
run_unit /tmp/test_ask_card scripts/ql_ask_card/truth_table_ask_card.swift

echo "=== 74. 长期目标卡片口径真值表（v4.0.46 · 首页卡只显当前进行中那一步）==="
# 同上（v4.0.46 漏挂补挂）；实测 16/0 绿。口径：compact 卡不画已完成行/折叠计数，全量只在详情页。
run_unit /tmp/test_goal_card scripts/ql_goal_card/truth_table_goal_card.swift

echo "=== 75. SyncedStore 宽松 ISO8601 真值表（v4.0.46 · 时间戳口径统一）==="
# 同上（v4.0.46 漏挂补挂）；实测 39/0 绿。口径：naive 无时区 / 带微秒 / Z 三种时间戳都要能解。
run_unit /tmp/test_goal_ts scripts/ql_goal_ts/truth_table_synced_ts.swift

echo "=== 76. 登录页使用指南文案真值表（v4.0.47 · 指南 = 真实部署流程：install.sh / 必填 token / 地址口径 / 一键更新）==="
# 本表为什么存在：LoginGuideSheet 是全 App 唯一面向用户的教学文案，**此前零护栏** ——
# v3.9.88 起一直教「编辑 docker-compose.yml 设密码」，而 QL_INBOX_TOKEN / QL_PUSH_TOKEN 是必填
# （compose 默认空 → 后端 inbox/push 接口一律拒绝放行且**不报错**），文案与后端 README 漂移
# 没有任何真值表拦得住。用户 2026-10-04 评审后拍板「全改」→ 顺手把这件事变成硬断言。
# 纯文本级断言（无可跑逻辑）；真源 = 后端仓 README:41/121-123 + install.sh:35 + 本仓 AuthStore.swift:133。
# 反向变异已验证：把旧口径改回去 → 7 处红 + exit 1（非假绿）。
run_unit6 /tmp/test_qlguide scripts/ql_guide/truth_table_guide.swift

echo "=== 77. 启动期类型栈深度真值表（v4.0.48 · 根治 4.0.47 真机启动闪退）==="
# 本表为什么存在：v4.0.47 侧载后**一点开就闪退**，.ips 实证 = 主线程栈溢出
# （swift_getTypeByMangledNameInContext2 里 demangler 递归 ~112 帧）。定量根因 =
# messageList 的 LazyVStack 元组类型静态嵌套 21 层（最深两条链：三点行 12 层 / 工具卡 9 层）。
# 修法 = 类型擦除（AnyView），21 层 → ~11 层。这类事故本地预检查不出来（要真机启动才炸），
# 但「顺手把 AnyView 去掉」是极自然的重构 → 必须钉死，否则必崩包会再发一次。
# 纯文本级断言；实测 14/0 绿（含 2 条负断言：裸链形态、三条分散 padding）。
run_unit6 /tmp/test_qltypestack scripts/ql_typestack/truth_table_typestack.swift

echo "=== 78. 断点续传 App 半程真值表（待做池⑥ · 后端「稳妥档」的 App 侧消费）==="
# 本表为什么存在：后端「稳妥档」已把「中断任务」判死并标 outcome=outcome_unknown、
# 保留已完成步（plan/planSeq），但 App 侧 streamRecover 原先只解 5 个字段 → 断点信息全丢，
# 用户只看到笼统的「连接中断，请重试」。本表钉死：① 中断任务如实外显「已完成第 k 步 ·
# 结果未知 · 未自动重放」② 非中断**绝不误伤**原错误文案 ③ 队列总览口径（只统计当前会话 /
# 序号从 1 起 / 空文本跳过 / 长文本截断）。A/B 段真编译真跑（ResumeInfo + SendQueueOverview），
# C 段剥注释源级钉接线。实测 33 正 / 12 反 / 0 失败。
# ⚠️ 双闸门（退出码 + 结论行须以「/ 0 失败」结尾），防「10 失败」子串假绿——与 69/70/71/72 同款。
rm -f /tmp/test_resume_ui
if ! $SWIFT/swiftc -swift-version 6 -o /tmp/test_resume_ui \
     scripts/ql_resume_ui/truth_table_resume_ui.swift \
     qingliao/Core/ResumeInfo.swift qingliao/Core/SendQueueOverview.swift \
     qingliao/Core/ActiveTaskPlan.swift qingliao/Features/Chat/ChatPendingSend.swift > /tmp/tt_resume_ui.log 2>&1; then
  echo "❌ 第 78 段真值表编译失败"; tail -5 /tmp/tt_resume_ui.log; fail=1
elif /tmp/test_resume_ui >> /tmp/tt_resume_ui.log 2>&1; then
  echo "  $(tail -1 /tmp/tt_resume_ui.log)"
  grep -qE '/ 0 失败$' /tmp/tt_resume_ui.log || { echo "❌ 第 78 段结论行异常（须以「/ 0 失败」结尾）"; fail=1; }
else
  echo "❌ 第 78 段真值表判定失败（改坏必红）"; tail -6 /tmp/tt_resume_ui.log; fail=1
fi

echo "=== 79. 手写圈注（图片圈注）真值表（待做池⑦ · 用户拍板「只做图片圈注」）==="
# 本表为什么存在：图片链路（pendingImage / compressImage / 发送）早已现成，本项只加了
# 「画布采集 → 归一化 → 烘焙进原图」一层；但口径一旦写错，真机就是「圈的位置跟手指对不上/
# 输出被拉伸/撤销撤错」——而这类几何缺陷本地 `swiftc -parse` 全查不出。故把几何口径收进
# Core/ImageAnnotationKit.swift（纯 Foundation）用真值表真跑：
#   · 归一化 0…1 夹取、aspect-fit 等比矩形 → **标注与原图按比例对齐、不拉伸**（换屏宽不变）
#   · 落点去抖、换色/换宽另起一笔、撤销回退一笔、清空归零
#   · 源级钉接线：圈注入口 / 面板接线 / 烘焙尺寸取原图（长宽比一致）/ 完成胶囊左位
# ⚠️ 双闸门（退出码 + 结论行须以「/ 0 失败」结尾），防「10 失败」子串假绿——与 69~72/78 同款。
rm -f /tmp/test_annotate
if ! $SWIFT/swiftc -swift-version 6 -o /tmp/test_annotate \
     scripts/ql_annotate/truth_table_annotate.swift \
     qingliao/Core/ImageAnnotationKit.swift > /tmp/tt_annotate.log 2>&1; then
  echo "❌ 第 79 段真值表编译失败"; tail -5 /tmp/tt_annotate.log; fail=1
elif /tmp/test_annotate >> /tmp/tt_annotate.log 2>&1; then
  echo "  $(tail -1 /tmp/tt_annotate.log)"
  grep -qE '/ 0 失败$' /tmp/tt_annotate.log || { echo "❌ 第 79 段结论行异常（须以「/ 0 失败」结尾）"; fail=1; }
else
  echo "❌ 第 79 段真值表判定失败（改坏必红）"; tail -6 /tmp/tt_annotate.log; fail=1
fi

echo "=== 80. 链接预览卡片真值表（待做池⑧ · 微信式 · 首个链接 / 失败不出空卡 / 无图降级）==="
# 本表为什么存在：链接预览的坑全在「判定」上 —— 一条消息里多个 URL 该取哪个、末尾标点算不算
# 链接、抓取失败时会不会留一张空卡、缩略图加载不到会不会显示破图。这些错 `swiftc -parse` 全查不出，
# 真机才暴露（且是「偶尔一张空卡」这种最难复现的形态）。故把判定收进 Core/LinkPreviewKit.swift
# （纯 Foundation）用真值表真跑 + 源级钉接线（入口行 / 卡片 / 缓存 store / 重抓 / 关闭）。
# ⚠️ 双闸门（退出码 + 结论行须以「/ 0 失败」结尾），防「10 失败」子串假绿——与 69~72/78/79 同款。
rm -f /tmp/test_linkpreview
if ! $SWIFT/swiftc -swift-version 6 -o /tmp/test_linkpreview \
     scripts/ql_linkpreview/truth_table_linkpreview.swift \
     qingliao/Core/LinkPreviewKit.swift > /tmp/tt_linkpreview.log 2>&1; then
  echo "❌ 第 80 段真值表编译失败"; tail -5 /tmp/tt_linkpreview.log; fail=1
elif /tmp/test_linkpreview >> /tmp/tt_linkpreview.log 2>&1; then
  echo "  $(tail -1 /tmp/tt_linkpreview.log)"
  grep -qE '/ 0 失败$' /tmp/tt_linkpreview.log || { echo "❌ 第 80 段结论行异常（须以「/ 0 失败」结尾）"; fail=1; }
else
  echo "❌ 第 80 段真值表判定失败（改坏必红）"; tail -6 /tmp/tt_linkpreview.log; fail=1
fi

echo "=== 81. 会话分享卡片（长图版）真值表（待做池⑨ · 长图上限截断+尾注 / 新 logo / 微信式气泡）==="
# 本表为什么存在：长图化的坑全在「上限与截断」上 —— 超长会话把 ImageRenderer 一次渲染爆内存（watchdog/OOM）、
# 尾注漏出（静默丢）/乱出（没截断也出）、从**最新端**倒着丢（把用户刚发的丢掉）、切断半条消息。
# 这些错 `swiftc -parse` 全查不出、本机无 SDK 也目视不了，只好收进 Core/SessionCardKit.swift（纯 Foundation）
# 用真值表真跑：条数/高度双上限、丢最早整条、至少留最新 1 条、时间序不变、空会话不出卡 + 源级钉接线。
# ⚠️ 双闸门（退出码 + 结论行须以「/ 0 失败」结尾），防「10 失败」子串假绿——与 69~72/78/79/80 同款。
rm -f /tmp/test_sessioncard
if ! $SWIFT/swiftc -swift-version 6 -o /tmp/test_sessioncard \
     scripts/ql_sessioncard/truth_table_sessioncard.swift \
     qingliao/Core/SessionCardKit.swift > /tmp/tt_sessioncard.log 2>&1; then
  echo "❌ 第 81 段真值表编译失败"; tail -5 /tmp/tt_sessioncard.log; fail=1
elif /tmp/test_sessioncard >> /tmp/tt_sessioncard.log 2>&1; then
  echo "  $(tail -1 /tmp/tt_sessioncard.log)"
  grep -qE '/ 0 失败$' /tmp/tt_sessioncard.log || { echo "❌ 第 81 段结论行异常（须以「/ 0 失败」结尾）"; fail=1; }
else
  echo "❌ 第 81 段真值表判定失败（改坏必红）"; tail -6 /tmp/tt_sessioncard.log; fail=1
fi

echo "=== 82. AI 回复双投真值表（v4.0.56 · 链内复检 / 注入查重 / 事故反向自证）==="
# 事故实据（2026-10-05）：同一句回复在同一会话里落两条，相隔 107ms（agent:true + isPush:true，内容 md5 相同）。
# body_dump 该轮只有一次模型调用 → 不是模型复读、不是生成两次，是「判定读#1 / 写入读#2 不同新鲜度」的双投。
# 覆盖：① 查重口径唯一（hasSameAssistantContent 一份规则三处共用）② 判定数据=写入数据（链内复检在 append 之前）
#      ③ 注入侧不裸 append（appendPushReplyIfNew）④ 谓词镜像真值表 ⑤ 事故重现（读#1 漏 / 读#2 拦）
#      ⑥ 反向自证（删掉链内复检 / 改回裸 append → 必红）。
run_unit6 /tmp/test_pushdedup scripts/ql_pushdedup/truth_table_pushdedup.swift

echo "=== 83. 迟到回复落库同族收口真值表（v4.0.57 · 链内重读 / 回落兜底 / 覆盖语义反向自证）==="
# 同族第二条（2026-10-05 只读审查指出）：BackgroundStreamRunner.finish 与 ChatView.landAwayReply
# 都拿「发起时快照 + 回复」整份写服务端会话，而后端 merge 对同 id 是整会话覆盖 →
# 流跑着期间落进该会话的其他写者内容（收件箱推送 / 其他端）会被旧数组抹掉（丢消息，比多一条更糟）。
# 覆盖：① 两处都走链内 appendMessageToOwnedSession（链内重读 + 查重）② 旧快照降级为 .targetMissing 回落兜底
#      ③ 兜底仍带「空快照不覆盖」守卫（2026-09-30 真数据破坏那条）④ 覆盖语义镜像（旧写法丢消息 / 新写法保住）
#      ⑤ 反向自证（任一处退回整份写 / 兜底丢守卫 → 必红）
#      v4.0.57b（2026-10-05 只读审查复审 3 条应改）：⑦ 两处 away 判重口径必须 .authoritativeReply（宽口径的
#      「新回答包含旧回答」会把带新内容的回答判成重复 → 只活在内存）⑧ 回落兜底加正向缺席门禁
#      writeBackSnapshotIfSessionAbsent（".targetMissing 也可能是这次列表读失败"→不许拿旧快照整份覆盖）
#      ⑨ patchAwayLanded 与落库侧同判据（hasSameAssistantContent），不再整串精确 ==
run_unit6 /tmp/test_snapshotwrite scripts/ql_snapshotwrite/truth_table_snapshotwrite.swift

echo "=== 84. 会话列表禁止 .scrollDepth()（List 行恒非 identity → 每行常驻 0.965 缩放）==="
# 事故（2026-10-05，用户报「轻聊 agent 这个框框的长度和下面的会话框框长度不一样」）：
#   根因 = SessionRow 上挂了 .scrollDepth()。它在 ScrollView/LazyVStack 里按位置算 identity（看板/生活卡片正常），
#   但在 **List 行**里 SwiftUI 恒返回「非 identity」→ 每行常驻 scaleEffect(0.965) + opacity(0.75)，
#   卡宽比同一 List 内未挂它的卡（agent 卡 / 后台浮条 / 空态 / 搜索命中行）窄 ~14pt。
#   实测 1179px 宽截图：agent 卡右缘 1137px = 14pt 边距（Spacing.xxl 设计值）vs 会话卡 1117px = 20.7pt（= 0.965x 缩放）。
# 判据：SessionsView.swift 的**代码**里不得出现 scrollDepth（注释里可以提，故先剥注释再 grep：
#   源码注释里刻意留了「不要挂 .scrollDepth()」的警示，直接 grep 会被自己的注释判红）。想恢复滚动层次感
#   只有一条正路 —— 去掉 List 外壳（改回 ScrollView + LazyVStack），别只把这一行加回来。
if sed 's://.*::' qingliao/Features/Sessions/SessionsView.swift | grep -qE 'scrollDepth|ScrollDepth'; then
  echo "❌ 第 84 段 会话列表代码里又出现 .scrollDepth()（List 行恒非 identity → 会话卡比 agent 卡窄 ~14pt）"; fail=1
else
  echo "✅ 第 84 段 会话列表代码无 .scrollDepth()（注释里的警示不算）"
fi

echo "=== 85. 页头图标胶囊真值表（v4.0.64 · 会话/聊天页取消滚边玻璃 + 滚动边缘效果）==="
# 钉：尺寸只有一个真源（icon 12 / 横 11 / 纵 5 / 间距 8；禁用 .pill(.topBar) 回退，回退 = 胶囊涨回 41×31）；
#     会话页右上三颗 + 聊天页两颗一律**圆环家族**——裸字形与带框混排就是从 v4.0.61 一路被吐槽到 v4.0.62 的病根，
#     且 v4.0.61「外环 + 胶囊底 = 双圈」的顾虑已被用户看稿后否决（不要再改回裸字形）；
#     会话页页头**不进滚动视图**（v4.0.63 用户拍板取消滚边玻璃 → 回 VStack 第一行、safeAreaBar 计数 0）；
#     **会话页 List 与聊天页消息区一律关掉 iOS 26 系统滚动边缘效果**（v4.0.64 用户复测第 2 条；看板/生活
#     两页不许跟着关，也不许改用 .scrollEdgeEffectStyle 把模糊放回来）；
#     看板页 PageHeader 不许挪回 VStack 第一行（回退 = 滚边玻璃整页失效）；记录卡首页 prefix(1)
#     （`count > 1` 与 `count - 1` 必须同时改，只改一处会显示「还有 0 条」）。
# 变异自证（**历史记录** · 尺寸定稿版实跑，未在本版重跑，数字仅供溯源）：HStack(spacing: 12) /
#   archivebox.circle.fill→tray.full / hPad 11→14 / prefix(1)→prefix(2) / 拆掉看板 safeAreaBar —— 五处各判红；
#   v4.0.63 批（2026-10-05 在该版实跑，各判红、每次恰 1 项失败 = 29 通过 / 1 失败）：会话页加回
#     .safeAreaBar → 反向③ / 页头复制成两处 → 反向③′ / 页头前插 Spacer 挪出第一行 → ③ / 分支重贴 PageHeader( → 反向③″；
#   v4.0.64 批（2026-10-05 **在本版实跑**）：删聊天页隐藏修饰符 → 33/1 · 删会话页 → 33/1 ·
#     看板页私自加（越界）→ 33/1 · 会话页改 .scrollEdgeEffectStyle → **32/2**（正向⑦ + 反向⑦′ 双红）；
#     还原后 34 通过 / 0 失败。
run_unit /tmp/test_headerpill scripts/ql_headerpill/truth_table_headerpill.swift

echo "=== 86. 记录分类图标真值表（v4.0.65 · 用户看对比稿拍板方案 B：色块 36 + 白符号 + 保留分类名）==="
# 钉：分类图标只有一个出口 RecordKit.categoryIcon（明细行 / 筛选胶囊 / 分类选择器共用；另写一份即漂移）；
#     色块几何 36 / 圆角 0.305×边长 / 符号字号 0.5×边长；**配色不许顺手改成语义色**（会牵动占比条与报告）；
#     空分类也画色块（否则有/无图标行左边缘参差）；「全部」胶囊不配图标；Picker 不得回退裸 Text(c).tag(c)。
run_unit /tmp/test_record_icons scripts/ql_record/truth_table_record_icons.swift

echo "=== 90. 记录页卡真值表（v4.0.98 · 用户 2026-10-11：点卡就地向下展开内部卡片 + 三处圆角 22）==="
# 钉：点页卡 = 就地展开（不许再弹全屏「全部记录」；入口挪到展开态底部那行，仍在）；内部行卡复用浮层同一张
#     RecordRowCard（另写一套 = 同一条记录两处长得不一样）；收起态那一截只在未展开时画（否则第一条出现两次）；
#     页卡/详情行卡/月度统计卡三处圆角 22，且 Radius.card 全局默认仍是 16（改它=连带设置页/会话页所有卡）。
# 与第 86 段（分类图标）同读 RecordSection.swift —— 改这张卡时两段一起看。
run_unit /tmp/test_record_card scripts/ql_record/truth_table_record_card.swift

echo "=== 91. 生活页四卡交互/视觉对齐真值表（v4.0.101 · 用户 2026-10-12 六条要求）==="
# 钉：记录卡面不再画「最近 1 条」（全在展开条目里）；待办/长期目标栏目**不许再有栏目级环境光晕**
#     （根因：那层 LinearGradient 从栏目最顶边铺 → 玻璃标题行半透，底色串到标题栏）；
#     待办环 = 三重同心环（外绿/中紫/内橙，底色轨各用自色，外径仍 70、线宽 6）；
#     目标环环心显示百分比（与习惯环逐字同口径）；**长期目标点卡 = 卡下逐条弹出目标卡
#     （v4.0.101，用户真机「不是弹窗显示…跟待办清单卡片弹出方式一样」；「全部目标」浮层已撤，
#     展开内容 = 目标卡不是步骤行）**；习惯点卡 = **就地展开**（入口在展开区底部那行）；
#     四处展开区（待办/目标/习惯/记录）10/8 同值；勾选圈只有 LifeCheckCircle 一个出口、尺寸只有
#     `LifeCheckCircle.defaultSize` 一处真源（v4.0.100 由 24/26/18 三档统一到 20）；
#     卡片弹开曲线走专用 `Motion.cardExpand`（不是把通用 settle 改慢 —— 那会拖累聊天流式生长）。
#     这些都是静默错（点卡又弹浮层 / 底色轨退回灰 / 光晕加回来串色），不报错，只等用户下次吐槽。
run_unit /tmp/test_life_align scripts/ql_life_align/truth_table_life_align.swift

echo "=== 92. 动作卡执行回执真值表（v4.0.100 · 用户 2026-10-12「执行完的动作卡下次打开还是未执行」）==="
# 钉：动作卡的执行态**必须落库**（ChatMessage.actionOutcomes，键 = AgentAction.stateKey）。
#     原先只是视图级 @State phase → 重启/切会话/消息重建全丢：只读卡每次重进都重跑一遍，
#     写/删卡的「执行」胶囊重新长出来 —— **用户再点一次就是第二个日程、第二个目标**（静默重复副作用，
#     不报错，只等用户发现多了件事）。三条口径：成功落回执 / 失败**不落**（授权后要能重试）/
#     撤销**抹掉**（撤销=这件事没有发生）。反例还钉了：回执不许进 historyPayload（模型上下文）
#     也不许进 ChatMessage.id（进了每执行一次都换 id）。
# ⚠️ 编进来的是**生产源码** AgentAction.swift（stateKey 真跑，不是镜像实现）；
#    多文件时顶层代码必须收进 @main（同 5a 的坑）。
run_unit6 /tmp/test_action_receipt \
    qingliao/Core/AgentAction.swift scripts/shims/AppCapabilityShim.swift \
    scripts/ql_action_receipt/truth_table_action_receipt.swift

echo "=== 93. 生活页三张卡拆分真值表（v4.0.101 · 用户 2026-10-12「把股票，博客/资讯，快递单独拆开」）==="
# 拆前：股票/资讯/快递挤在同一个 LifeCardsSection 里（一个页级标题行「股票」+ 一颗折叠键）。
# 拆后：LifeSection 各占一个 case（.lifeCards=股票 / .rss=博客·资讯 / .express=快递），
#       各自成板块 → 有自己的标题行、自己的折叠键、自己的刷新胶囊，可在「自定义板块」单独排序/隐藏。
# 本段钉**拆开了没** + **拆的时候没拆坏什么**：
#   ① 三个 case / 三个 struct / 三处接线；② 数据源仍是一份（拆的是渲染不是请求）；
#   ③ 折叠键口径（股票/资讯沿用旧键 → 老用户折叠态不丢；快递新增独立键）；
#   ④ 老用户顺序串迁移：新 case 贴着 .lifeCards 补位（否则资讯/快递跑到页面最末，像「消失了」）；
#   ⑤ 反向：旧的单块结构（LifeCardsSection / rssSection 包裹层 / noteCard·noteRow）不许还魂。
# ⚠️ 走 run_unit6（严格并发口径同 CI）；断言全在**剥注释**后的文本上做（本仓「注释里写了就假绿」老坑）。
run_unit6 /tmp/test_life_split scripts/ql_life_split/truth_table_life_split.swift

echo "=== 87. 备忘/待办图标真值表（v4.0.65 · 用户拍板「待办走 B / 备忘走 A」）==="
# 钉：来源→颜色只有 SourceStyle 一个出口（另写一份 = 同一来源在待办页/备忘页长出两种色）；
#     页级单卡不许跟着放大（用户 v3.9.37 明确要求备忘单卡「连图标也不要」）；
#     备忘方案 A 的元信息行保持灰（不许顺手染来源色）；待办时间保持灰基线不抢视觉。
run_unit /tmp/test_life_badges scripts/ql_lists/truth_table_life_badges.swift

echo "=== 88. 主题淡彩迁移真值表（v4.0.67 · 页底环境渐变铺全站 / 卡口径 pastelCard / P5 浮层换底）==="
# 钉：页底只铺一层 EnvironmentGlowLayers（手刷系统底会盖死光晕）；彩底上的卡一律 pastelCard，
#     生活页/设置页目录里旧玻璃口径（dashboardCard / glassListCard）清零；
#     大爆炸/语音页换底但语音页 accent 柔光（v3.9.77「科幻感」）必须留着；
#     分享扩展主色与主题蓝紫亮色首档同值（扩展编不到 Theme，只能字面写 → 最易漂移）。
run_unit /tmp/test_themegrad scripts/ql_themegrad/truth_table_themegrad.swift

echo "=== 89. dock 回退真值表（v4.0.72 · 用户 2026-10-07 拍板：整体回退 4.0.69）==="
# 钉：v4.0.72 整体回退到 4.0.69 形态（用户 2026-10-07 拍板「dock 恢复到 4.0.69」）——
#     v4.0.70 的 6 项（顺序自定义/角标/重击回顶/接缝线/tabSwitch+淡入/ChatEntryZoom unfold）全部不许回来；
#     v4.0.73 起切页入场 = 内容原地淡入（Motion.snap，无缩放/上浮/无低起点淡入；页底渐变常驻不动）。
#     白闪根治 = TabView 底下垫静态 EnvironmentGlowLayers（缩放露环=渐变而非窗口白底）。
SSV=qingliao/Features/Sessions/SessionsView.swift
SCS=qingliao/Features/Settings/SettingsCommon.swift
MDL=qingliao/Core/Models.swift

ckNot "回退①：dock 顺序自定义已拆（出厂串不许回来）" 'defaultDockOrderRaw' "$DT"
ckNot "回退②：可换位集合已拆" 'orderableTabs' "$DT"
# v4.0.82（用户 2026-10-09 拍板）：Dock 栏顺序/隐藏**重新可配**（设置页 DockLayoutSheet）→
# v4.0.72「顺序自定义必须不存在」的口径**反转**：现在要求取序**必须**经 DockLayoutKit 净化，
# 且净化器兜底必须在（脏串一律回出厂序，宁可回默认也不许悄悄少一格，见 ql_docklayout ①）。
ck "回退③（v4.0.82 口径反转）：Dock 顺序经 DockLayoutKit.sanitizedOrder 净化后取用" \
   'DockLayoutKit\.sanitizedOrder\(' "$DT"
ckNot "回退④：外观页 Dock 顺序入口已拆" 'Section\("Dock 顺序"\)' "$SCS"
ckNot "回退⑤：dockOrder key 已从模型删除" 'static let dockOrder = "qingliao_dock_order"' "$MDL"
ckNot "回退⑥：槽位角标已拆" 'sessionsBadge' "$DT"
ckNot "回退⑦：重击回顶通知已拆（dock 侧）" 'qingliaoDockRetap' "$DT"
ckNot "回退⑧：重击回顶消费已拆（会话页侧）" 'qingliaoDockRetap' "$SSV"
ckNot "回退⑨：接缝线层已拆" 'DockSeamOverlay' "$DT"
ckNot "回退⑩：tabSwitch 令牌已删（Motion 里不许再出现）" 'tabSwitch' "qingliao/Theme/Motion.swift"
ckNot "回退⑪：unfold 令牌已删" 'static let unfold' "qingliao/Theme/Motion.swift"
ckNot "回退⑫：ChatEntryZoom 机制文件已删" 'ChatEntryZoom' "$DT"
ckNot "回退⑬：会话页无 ChatEntryZoom 残留" 'ChatEntryZoom' "$SSV"
ckNot "回退⑭：整页淡入不许回来（0.35 起手的老病）" '\.opacity\(0\.35 \+ 0\.65 \* phase\)' "$DT"
ckNot "回退⑮：0.9 淡入（v4.0.71 未根治版）也不许回来" '\.opacity\(0\.9 \+ 0\.1 \* phase\)' "$DT"
# v4.0.73（方案 A 拍板）= 内容原地淡入（Motion.snap 0.20s）→ **v4.0.78 改柔滑滑入**：
# 用户真机反馈「dock 栏 tap 切换太闪了」（根因：opacity 走 snap 0.20s、位移走 flow 0.28s，两条曲线不同拍
# 又都从 phase=0 起手 = 内容先整个消失再出现）→ **v4.0.85** 整体加重（起点 0.75 / 位移 60pt / pageSlide 弹簧，
# 历轮为躲「闪 / 露白」一路压到 ≈硬切）。
# 🚨 **v4.0.120（用户 2026-10-17「圆扩散只留启动页」）**：底栏切页整条换成**内容层定向滑入** ——
# 新页内容按槽位方向位移进场（起点 ±Motion.pageEnterShift(28pt)，曲线 Motion.pageEnterSlide(.smooth 0.32)，
# 方向按新旧槽位在 order 里的序号差判）。圆扩散只剩**两处**：滑动返回（SessionHomeReveal，见本组 ⑯k/⑯l）
# 与启动页（SplashView 的 launchReveal）。
# 曲线 / 位移 / 方向三处与 ChatZoomEntryModifier 逐字成对，别只改一边（ql_themegrad ⑧c、ql_docklayout 表同钉）。
# 位移期间不露白的理由：TabView 底下常驻同款 `EnvironmentGlowLayers` 垫底（回退⑰）—— 那 28pt 露出的就是
# 这层渐变 = 与页底逐帧一致 —— v4.0.73~0.85 反复治的「先白一下」不会复发。
# 禁令不变：整页缩放（0.96 那套）/ y 轴上浮 / 低起点整页淡入（0.35 起手）/ 旧横向微滑（pageSlideShift）一概不许回来。
cnt=$(grep -cF 'withAnimation(Motion.pageEnterSlide) { slideOffset = 0 }' "$DT"); [ "$cnt" -eq 2 ] \
  || { echo "❌ 回退⑯：**切页**入场应为同一个 withAnimation(Motion.pageEnterSlide) { slideOffset = 0 }（两处 modifier 各一份，实得 $cnt）"; fail=1; }
cnt=$(grep -cF 'direction(from: oldVal) * Motion.pageEnterShift' "$DT"); [ "$cnt" -eq 2 ] \
  || { echo "❌ 回退⑯f：切页入场起点应为按槽位方向取的 ±Motion.pageEnterShift（两处 modifier 各一份，实得 $cnt）"; fail=1; }
# v4.0.143（用户「聊天页滑动返回主页掉帧非常严重，从根源修复」）：返回扩散从「常驻 clipShape +
# compositingGroup」换成 RevealHoleMask overlay —— 旧裁剪必须归零，新遮罩必须恰一处。
cnt=$(grep -cF 'RevealHoleMask(center: localCenter, radius: revealRadius)' "$DT"); [ "$cnt" -eq 1 ] \
  || { echo "❌ 回退⑯i：返回扩散应为 RevealHoleMask overlay（轻量遮罩，实得 $cnt）"; fail=1; }
cnt=$(grep -cF 'clipShape(RevealCircleShape(center: localCenter, radius: revealRadius))' "$DT"); [ "$cnt" -eq 0 ] \
  || { echo "❌ 回退⑯i0：返回扩散不许再用常驻 clipShape（跟手每帧重合成 = 掉帧主因，实得 $cnt）"; fail=1; }
cnt=$(grep -cF '.compositingGroup()' "$DT"); [ "$cnt" -eq 0 ] \
  || { echo "❌ 回退⑯i1：会话首页不许再挂合成组（内容一动就整屏重栅格化，实得 $cnt）"; fail=1; }
# v4.0.97 审查（medium）：shape 的 path 在**页面局部坐标系**里，圆心却是 window 坐标 →
# 必须经 localCenter 减掉页面原点（安全区 ≈59pt），否则整圆偏下一个状态栏。v4.0.120 起只剩返回那一处。
cnt=$(grep -cF 'CGPoint(x: revealCenter.x - pageOrigin.x, y: revealCenter.y - pageOrigin.y)' "$DT"); [ "$cnt" -eq 1 ] \
  || { echo "❌ 回退⑯i2：返回那支的圆心必须做 window → 页面坐标换算（实得 $cnt）"; fail=1; }
cnt=$(grep -cF 'withAnimation(nil) { revealRadius = 0 }' "$DT"); [ "$cnt" -eq 1 ] \
  || { echo "❌ 回退⑯e：返回扩散入场起点应为半径瞬归 0（withAnimation(nil)，恰好一处，实得 $cnt）"; fail=1; }
cnt=$(grep -cF 'static let pageRevealMaxRadius: CGFloat = 1200' qingliao/Theme/Motion.swift); [ "$cnt" -ge 1 ] \
  || { echo "❌ 回退⑯g：扩散圆最大半径应为 Motion.pageRevealMaxRadius = 1200（实得 $cnt）"; fail=1; }
ckNot "回退⑯h：pageReveal 令牌已退役（v4.0.120 切页改定向滑入后无人消费；扩散只留 launchReveal / sessionBackReveal）" 'static var pageReveal' "qingliao/Theme/Motion.swift"
ckNot "回退⑯h2：切页那两处不许再走 pageReveal 圆扩散事务（返回那条走 ⑯l）" 'withAnimation\(Motion\.pageReveal\) \{ revealRadius' "$DT"
# v4.0.117（用户 2026-10-15 真机拍板「滑动返回的扩散就是太快，再慢一点」）：返回这条链**单独一枚更慢的曲线**。
# 为什么不能直接改 pageReveal：0.75 是用户为 **dock 切页**三轮调定的（0.42→0.60→0.75），
# 顺手加长 = 误伤已在用的切页动效（用户口径「修复勿误伤在用功能」）。
# 第 12 项（2026-10-18 特效总档）：令牌形态变为 tuned(.smooth(...)) —— 断言只钉**曲线 + 时长字面**，
# 不再钉整行（否则「关档」包装一进来就误报；改时长或换曲线照样红）。
cnt=$(grep -cF '.smooth(duration: 1.10)' qingliao/Theme/Motion.swift); [ "$cnt" -ge 1 ] \
  || { echo "❌ 回退⑯k：滑动返回专用曲线令牌应为 Motion.sessionBackReveal（.smooth 1.10，实得 $cnt）"; fail=1; }
# 恰好一处（只有 SessionHomeRevealModifier 的 enter 该用它；多一处 = 有人拿它顺手改了切页那条）。
cnt=$(grep -cF 'withAnimation(Motion.sessionBackReveal) { revealRadius = Motion.pageRevealMaxRadius }' "$DT"); [ "$cnt" -eq 1 ] \
  || { echo "❌ 回退⑯l：滑动返回的圆形扩散应唯一走 Motion.sessionBackReveal（实得 $cnt）"; fail=1; }
ckNot "回退⑯a：旧 snap 起手（phase 从 0 开始，实测会闪）不许回来" 'withAnimation\(Motion\.snap\) \{ phase = 1 \}' "$DT"
ckNot "回退⑯b：整页缩放入场（0.96 那套）不许回来" 'scaleEffect\(0\.96 \+ 0\.04 \* phase' "$DT"
ckNot "回退⑯c：整页上浮（10pt 那条）不许回来" 'offset\(y: 10 \* \(1 - phase' "$DT"
ckNot "回退⑯d：原地淡入 .opacity(phase) 不许回来（v4.0.97 起入场是圆形扩散，不再改整页透明度）" '^[[:space:]]*\.opacity\(phase\)' "$DT"
ckNot "回退⑯j：横向微滑（pageSlideShift / dx 那套）不许回来（v4.0.97 已整条换掉）" 'Motion\.pageSlideShift' "$DT"
ck "回退⑰：TabView 底下垫了静态渐变底（切页缩放露环=渐变，根治「先白后切」）" 'EnvironmentGlowLayers\(scheme: colorScheme\)' "$DT"
ln=$(grep -n 'EnvironmentGlowLayers(scheme: colorScheme)' "$DT" | head -1 | cut -d: -f1); [ -n "$ln" ] \
  || { echo "❌ 回退⑰：垫底渐变层不存在"; fail=1; }
if [ -n "$ln" ]; then win=$(sed -n "${ln},$((ln+3))p" "$DT"); case "$win" in *allowsHitTesting\(false\)*) ;; \
  *) echo "❌ 回退⑱：垫底层(第 $ln 行起3行内)缺 allowsHitTesting(false)"; fail=1;; esac; fi

echo "=== 93c. 左缘右滑**跟手**返回（v4.0.122 · 用户 2026-10-18 对着参考截图拍板「要这种跟手滑动返回」）==="
# 被换掉的老行为（就是本次要治的病）：起手在左缘 → 抬手位移 ≥ 70pt 就跳转，**页面本身不跟手** ——
#   手指在滑、页面一动不动，松手才闪切。新口径 = 拖动中每帧位移整页（对话页贴着手指右移、
#   会话首页从左侧同步露出来），松手按「位移过半 / 甩动预测终点过半」判完成或回弹（微信同款）。
# 为什么代码级钉：这条链全是「时序 + 谁写状态」的口径，改错了不报错、不崩、其它断言全绿，
#   只有真机手感能发现 —— 而本机无 iOS SDK，真机要等发版。判定的纯逻辑那半在 ql_docklayout 表
#   Ⓟ 段用**编译真值**钉（ChatEdgeBackKit.swift 已加进那张表的编译行），这里钉挂载点与时序面。
# 🚨 v4.0.149（掉帧根治）：位移挂载点从 body 里的三元表达式搬进 ChatPageBackMotion（读 @Observable）。
#   旧字符串 `.offset(x: backFollowLive ? backFollowOffset : 0)` 直接写在 DockTabView.body 里 —— 每帧一读
#   就把整页 body 绑在逐帧状态上（见 ⑲v/⑲w）。钉「搬进修饰器后的那一处」+ 钉「body 里不许再直读」。
cnt=$(grep -cF '.offset(x: follow.live ? follow.offset : 0)' "$DT"); [ "$cnt" -eq 1 ] \
  || { echo "❌ 回退⑲a：跟手位移应恰好挂一处 .offset(x: follow.live ? follow.offset : 0)（整页走，且不跟手恒 0、只在修饰器里读，实得 $cnt）"; fail=1; }
cnt=$(grep -cF 'withAnimation(Motion.sessionBackSettle) { backFollowOffset = width }' "$DT"); [ "$cnt" -eq 1 ] \
  || { echo "❌ 回退⑲b：松手**完成**应收敛到屏宽、且走返回专用令牌 Motion.sessionBackSettle（恰好一处，实得 $cnt）"; fail=1; }
cnt=$(grep -cF 'withAnimation(Motion.sessionBackSettle) { backFollowOffset = 0 }' "$DT"); [ "$cnt" -eq 1 ] \
  || { echo "❌ 回退⑲c：松手**回弹**应归 0、且与收敛同一枚 Motion.sessionBackSettle（恰好一处，实得 $cnt）"; fail=1; }
ck "回退⑲d：跟手帧必须是**裸赋值**（每帧贴手指；过动画事务就落在手指后面）" 'backFollowOffset = dx' "$DT"
ckNot "回退⑲e：跟手帧不许进 withAnimation（回退⑲e 守的就是本次病根：页面不跟手）" 'withAnimation\(Motion\.(page|tap)\) \{ backFollowOffset = dx' "$DT"
ck "回退⑲f：两态是 ZStack **双页同框**（跟手要「首页作为垫底页在场」那一帧）" 'if showSessionHome \|\| backFollowLive \{' "$DT"
ckNot "回退⑲g：不许退回 if/else 单页结构（位移一开左侧露出的是渐变垫底 = 断层）" '^[[:space:]]*if showSessionHome \{' "$DT"
ckNot "回退⑲h：手势那条不许再拿抬手位置当扩散圆心（跟手不等抬手；圆心只剩页头按钮那条）" 'onBack\(value\.location\)' qingliao/Features/Chat/ChatView.swift
ckNot "回退⑲i：不许在 end 帧直接跳转（抬手才认 = 不跟手，老 shouldGoBack 病根）" 'ChatEdgeBackKit\.shouldGoBack' qingliao/Features/Chat/ChatView.swift
cnt=$(grep -cF 'ChatEdgeBackKit.isBackStart(x: value.startLocation.x)' qingliao/Features/Chat/ChatView.swift); [ "$cnt" -eq 1 ] \
  || { echo "❌ 回退⑲j：起手门必须走 Kit（isBackStart + 全局起手 x，v4.0.125 起任意位置可起手），恰好一处（实得 $cnt）"; fail=1; }
cnt=$(grep -cF '@State private var claimedStart: CGPoint? = nil' qingliao/Features/Chat/ChatView.swift); [ "$cnt" -eq 1 ] \
  || { echo "❌ 回退⑲k：跟手锁存必须是**起手点** claimedStart（有记忆性：手指一偏 |dy| 变大不逐帧归 0；又能判新手势，实得 $cnt）"; fail=1; }
ckNot "回退⑲l：跟手帧不许自己 clamp / 算阈值（一律走 ChatEdgeBackKit，视图里不许内联第二套）" 'min\(max\(0, dx\)' qingliao/Features/Chat/ChatView.swift
# 🚨 v4.0.122 审查补（独立评审抓的两个必修，2026-10-18 夜）：跟手状态原来只有「正常抬手」一个出口 ——
#   手势被打断（onEnded 压根不来：来电/通知/进后台/视图被摘下）就会残留：页面停在半路、首页一直当垫底页，
#   更狠的是残留锁存会让下一轮**任意**拖动都跳过起手门与方向门（把整页推走）。
ckNot "回退⑲m：老 Bool 锁存不许复活（打断后残留 → 下一轮任意拖动跳过起手门与方向门）" 'private var following = false' qingliao/Features/Chat/ChatView.swift
ck "回退⑲n：换手势必须收回上一轮（用起手点判新手势，不依赖 onEnded）" 'claimed != value.startLocation' qingliao/Features/Chat/ChatView.swift
ck "回退⑲o：跟手期间禁掉页内滚动（simultaneousGesture 不抢识别，斜划会「整页横移 + 列表纵向滚」同时发生）" '\.scrollDisabled\(claimedStart != nil\)' qingliao/Features/Chat/ChatView.swift
cnt=$(grep -cF 'withAnimation(Motion.page) { resetBackFollow(); showSessionHome = false }' "$DT"); [ "$cnt" -eq 1 ] \
  || { echo "❌ 回退⑲p：进对话页收口必须先 resetBackFollow()（否则 0.4s 收尾任务把这次点击覆盖回去 = 点了没反应，实得 $cnt）"; fail=1; }
ckNot "回退⑲q：手势壳不许再接 onBack（页头返回按钮那条直连 onBackToHome，别让人改错一侧）" 'ChatEdgeBackModifier\(onBack:' qingliao/Features/Chat/ChatView.swift
# v4.0.148（用户 2026-10-22「从项目详情页滑回上一级挺流畅，聊天页改成一样的形式」）：
#   系统 interactive pop 是**两页同框一起走** —— 被压住的上一页从左侧 30% 屏宽处视差滑回 0，
#   移动页左缘还有一道投影把两页分开。只动移动页（首页静止被揭开）= 「一张纸盖回去」，不是 pop。
cnt=$(grep -cF '.modifier(HomeParallaxOffset(follow: follow))' "$DT"); [ "$cnt" -eq 1 ] \
  || { echo "❌ 回退⑲r：首页视差应恰好挂一处 HomeParallaxOffset（系统 pop 同形制；两页同向一起走，实得 $cnt）"; fail=1; }
ck "回退⑲r2：视差真值只走 ChatEdgeBackKit.homeOffset（修饰器里读同一处）" 'ChatEdgeBackKit\.homeOffset\(follow: follow\.offset,' "$DT"
ckNot "回退⑲s：视差比例不许内联在视图里（真值只在 ChatEdgeBackKit.homeOffset）" 'width \* 0\.3 \* \(1 -' "$DT"
ck "回退⑲t：移动页左缘投影在场（系统 pop 的两页分隔）" 'LinearGradient\(colors: \[Color\.black\.opacity\(0\.18 \* progress\), \.clear\]' "$DT"
ckNot "回退⑲u：跟手投影不许改整页 \.shadow（每帧离屏栅格化 = 跟手掉帧）" '\.shadow\(color: \.black\.opacity\(0\.18 \* progress\)' "$DT"

echo "=== 93e. 自绘 dock 条长自适应档数（v4.0.148 · 用户 2026-10-22）==="
# 用户原话：「滑动模式下 dock 条长度没有根据 tab 数量减少而自适应缩短」。
# 机制：改造前每格 `frame(maxWidth: .infinity)` → HStack 吃满整条；隐藏几档只是每格变宽、
#   整条长度不变（空胶囊）。纯几何退化不报错、不崩、其它断言全绿，只有真机看得出 → 代码级钉。
PB=qingliao/Features/DockPagingBar.swift
cnt=$(grep -cF '.frame(maxWidth: barMaxWidth)' "$PB"); [ "$cnt" -eq 1 ] \
  || { echo "❌ 回退⑳a：整条宽上限必须由 barMaxWidth 单一真源给、且用 maxWidth（上限，不是死宽），恰好一处（实得 $cnt）"; fail=1; }
ck "回退⑳b：条长算式读档数（cellWidth × max(1, tabs.count) + 内衬 × 2）" 'Self\.cellWidth \* CGFloat\(max\(1, tabs\.count\)\) \+ Self\.innerPadding \* 2' "$PB"
ckNot "回退⑳c：dock 条不许再按「每格定宽 / 整条死宽」写第二套（同一秒两份算式必然漂移）" 'frame\((width: (barWidth|cellW)|width: cellW)\)' "$PB"
# v4.0.148（审查 P2）：条长收窄居中后，「按整条等分」算锚点会偏（4 档最多 ≈42pt、3 档末格 ≈61pt）。
#   锚点球飘到隔壁格 = 「球看着在那儿、按上去没反应」那类隐蔽 bug → 钉住锚点走同源几何。
ck "回退⑳d：锚点槽位几何走 DockPagingBar.slotCenterX（与条长同源，不许在浮层里另写等分）" 'DockPagingBar\.slotCenterX\(index: slotIndex, count: slotCount,' qingliao/Features/Chat/ChatEffects.swift
ck "回退⑳e：slotCenterX 几何读同一组常量（cellWidth/innerPadding/outerPadding）" 'min\(screenWidth - outerPadding \* 2, cellWidth \* n \+ innerPadding \* 2\)' "$PB"
# v4.0.148（审查 P1）：投影必须挂在 `.offset` 内层（.offset 是渲染位移、不改布局框；后挂 overlay
#   按未位移的框对齐 → 条钉在屏左缘、页左缘没投影、返回收尾留暗带）。按**行号先后**钉，不靠 contains。
DP=qingliao/Features/DockTabView.swift
# v4.0.148（审查 P2）：别锚「文件里第一处同形 overlay」（通用写法，将来再挂一处就拿错行号照样绿）
#   → 只认**紧跟 `if follow.live {` 的那一处**，即移动页投影本体。
ol=$(awk 'prev ~ /\.overlay\(alignment: \.leading\) \{/ && $0 ~ /if follow\.live \{/ { print NR-1; exit } { prev=$0 }' "$DP")
mk=$(grep -nF '.offset(x: follow.live ? follow.offset : 0)' "$DP" | cut -d: -f1 | head -1)
[ -n "$ol" ] && [ -n "$mk" ] && [ "$ol" -lt "$mk" ] \
  || { echo "❌ 回退⑳f：移动页投影必须在 .offset **之前**（overlay 行 $ol / offset 行 $mk；后挂 = 投影钉死在屏左缘）"; fail=1; }

# 🚨 v4.0.149（用户 2026-10-22「优化掉帧问题」）：跟手逐帧状态**必须**装在 @Observable 里，
#   且任何「逐帧位移」都不许出现在 DockTabView.body 的表达式里。
#   病因（真机「一拖就掉帧」的根）：@State 每帧一写 → 整棵 DockTabView.body 重算 → 传给
#   SessionsView / ChatView 的闭包参数每帧都是新值 → 两个整页 body 跟着每帧重算
#   （消息 LazyVStack diff 几百行 + 首页卡片材质重采样）。改回去不报错、不崩、其它断言全绿，只有真机手感能发现。
ck "回退⑳g：逐帧跟手状态装在 @Observable（只让两个小修饰器重算，不牵动整页 body）" 'final class BackFollowMotionState' "$DT"
ckNot "回退⑳h：逐帧位移不许退回 @State（每帧写 = 整个 DockTabView.body 重算 = 跟手掉帧根）" '@State private var backFollowOffset' "$DT"
ckNot "回退⑳i：body 里不许直读逐帧位移（读一次 = 把整页 body 绑回逐帧状态）" 'offset\(x: backFollowLive \? backFollowOffset' "$DT"
ck "回退⑳j：位移/投影都走 ChatPageBackMotion 单一修饰器（overlay 与 offset 同在，顺序不会被拆）" 'ChatPageBackMotion\(follow: follow\)' "$DT"

# 🚨 v4.0.149（用户 2026-10-22「设置里面 dock 栏切换方式胶囊没对齐其他胶囊位置」）：
# 带标题的开关必须写成 `HStack { 文案; Spacer; Toggle("") }`。写成 `Toggle(isOn:) { 自定义 label }`
# 时自定义 label 撑出固有宽度 → 开关紧贴文案、不落行尾，胶囊和同页其他行差一截。
# 这种偏差不报错、不崩、其它断言全绿，只有真机看得出 → 代码级钉。
DS=qingliao/Features/Settings/DockLayoutSheet.swift
ckNot "回退㉑a：带标题开关不许再用 Toggle(isOn:){…} + labelsHidden（自定义 label 撑宽 → 胶囊不落行尾）" 'Toggle\(isOn: \$dockPaging\)' "$DS"
ck "回退㉑b：切换方式行必须是 HStack + Spacer + Toggle(\"\")（与全仓带标题开关同一长相）" 'Toggle\("", isOn: \$dockPaging\)' "$DS"

echo "=== 93d. 全仓确认框收敛真值表（v4.0.102 · 用户 2026-10-12「方案 2：全改」）==="
# 口径：iPhone 上 confirmationDialog 固定从屏幕底部升起、锚不到触发元素 → **危险/破坏性动作的确认**
#   一律走 AnchorMenuOverlay 锚定浮层（「从哪点从哪弹」）；`.alert`（居中模态、非底部升起）按
#   v4.0.76 口径**刻意保留**，不算残留。
# 事故面：改造后若有人图省事把某处写回 confirmationDialog，会静默退化成「从底部升起」——
#   没有编译错、没有运行日志、其它断言也全绿，人眼回归必漏，只能代码级钉。
# 本表钉两件事：① live confirmationDialog 必须为 0（注释里的历史说明不算）② 浮层调用点不许被删空。
cd_live=$(grep -rn 'confirmationDialog' qingliao/ --include=*.swift | grep -v ':[0-9]*:[[:space:]]*//' | wc -l | tr -d ' ')
[ "$cd_live" -eq 0 ] \
  || { echo "❌ 回退㊾：全仓不应再有 live confirmationDialog（破坏性确认应全走 AnchorMenuOverlay；.alert 口径外不算，实得 $cd_live）"; fail=1; }
anchor_calls=$(grep -rn 'AnchorMenuOverlay(' qingliao/ --include=*.swift | grep -v ':[0-9]*:[[:space:]]*//' | wc -l | tr -d ' ')
[ "$anchor_calls" -ge 19 ] \
  || { echo "❌ 回退㊿：锚定浮层调用点数量异常（全仓应 ≥19 处，实得 $anchor_calls）"; fail=1; }

echo "=== 94. 弹窗 zoom 配对真值表（v4.0.102 · 用户 2026-10-12「看板页有些卡片的弹窗没跟着卡片位置弹出，统一居中」）==="
# 事故（当时报障的是连接器卡；该卡已于 v4.0.109 随「连接器」栏目退役，机制不变）：
#   只挂**目标侧** navigationTransition(.zoom(sourceID: DashboardSheet.<case>.id…))，源侧漏挂 .matchedTransitionSource。
#   机制：zoom 靠「屏上有个视图挂着同名 id」定位起点；源缺失 / 源与目标 id 差一个字 / 命名空间混用，
#   **都不报编译错、不打运行日志**，只是退化成普通弹出（从屏幕正中冒）—— 人眼回归必漏，只能代码级钉。
# 本表钉三件事：① 目标↔源成对（缺一头即红）② 同一命名空间 ③ 含反向自证（源 id 改错必须判红）。
python3 scripts/ql_zoom_pair/truth_table_zoom_pair.py 2>&1 | tee /tmp/tt_zoompair.log
grep -q '✅ ALL PASS' /tmp/tt_zoompair.log || fail=1

echo "=== 95. 聊天输入框草稿真值表（v4.0.103 待做池 #5 · 按会话记 / 发送才清）==="
# 口径（用户 2026-10-13 拍板）：输入框正文按会话持久化，切会话 / 杀后台回来仍在；确认发送才清。
# 事故面：草稿链路的退化**全是静默的** —— 输入栏改回 `text: $inputText` 直绑、别处新添一行
#   `inputText = x` 绕过写入口、清空时机挪成「点发送就清」……编译过、-parse 过、其它 60+ 张表
#   照旧全绿，只有用户装机后才发现「打的字又没了 / 切回来草稿变成上一个会话的」。故钉死。
# 分工：test_draft 真跑生产源码 ChatDraftStore 的行为（按会话隔离 / 重载仍在 / 清空落盘 / 容量上限 / 节流）；
#   truth_table_draft 钉接线形态（写入口唯一 + 四个时机 + 键单一真源 + 直写白名单 + 先存后取顺序 + 落盘节流）。
# ⚠️ 扫描面 = `qingliao/Features/Chat/*.swift` **全目录**（第一版只扫 ChatView.swift，漏了同类型的
#   ChatViewVoice.swift → 语音定稿那处直写全程假绿；只读审查才发现，故扫描面本身也加断言）。
# ⚠️ 替身 keyconf.swift 只给 UserDefaultsKey.chatDrafts 一个常量（Models.swift 带 SwiftUI，Linux 编不了）；
#   真值表会读 Models.swift 与替身逐字比对键字面量，两处漂移即红。
rm -rf /tmp/ql_draft_main && mkdir -p /tmp/ql_draft_main
cp scripts/ql_draft/test_draft.swift /tmp/ql_draft_main/main.swift
cp scripts/ql_draft/keyconf.swift /tmp/ql_draft_main/keyconf.swift
run_unit6 /tmp/test_ql_draft /tmp/ql_draft_main/main.swift /tmp/ql_draft_main/keyconf.swift \
    qingliao/Core/ChatDraftStore.swift
run_unit6 /tmp/tt_draft scripts/ql_draft/truth_table_draft.swift

echo "=== 96. 专注计时（番茄钟）真值表（v4.0.104 待做池⑫ · 剩余现算 / 杀 App 不丢 / 记录整分钟）==="
# 口径（用户 2026-10-13 拍板开 #12：习惯支持「量/时长」+ 新增专注计时，专注时长记进当天习惯）。
# 事故面：这功能的退化**全是静默的** —— 剩余改成逐秒递减（一挂起就停表，人眼只看到「回来还剩 12:30」）、
#   会话不落盘（切后台被系统杀掉 → 这一轮白干）、归日挪到结束那天（23:50 那轮把时长劈给两天）、
#   回调没接线时把「到点」那轮直接丢掉、提前结束按计划分钟记（没专注却记满）。
#   以上编译过、-parse 过、其它 65+ 张表照旧全绿，只有装机后才发现，故钉死。
# 分工：sectionA/B **真跑**生产源码 FocusTimerStore（会话持久化 / 挂起对表 / 到点落账 / 提前结束 /
#   放弃不记 / 冷启动补账 / 垃圾数据不崩）；sectionC 用剥注释的源级断言钉 App 接线与 UI 入口形态。
# ⚠️ 本机工具链的 libswiftObservation.so 有一个未解析符号（swift::threading::fatal 没被 libswiftCore
#   导出）→ 直接编 @Observable 的类会**链接失败**。obs_shim.cpp 提供一个行为等价的实现（打印 + abort），
#   只为让状态机能在本地真跑；iOS 侧走 Xcode 自带 runtime，不受影响（详见该文件顶部注释）。
rm -f /tmp/ql_obs_shim.o
g++ -c -O1 -o /tmp/ql_obs_shim.o scripts/ql_focus/obs_shim.cpp > /tmp/ql_obs_shim.log 2>&1 \
  || { echo "❌ 第 96 段垫片编译失败（g++ 不可用？）"; tail -5 /tmp/ql_obs_shim.log; fail=1; }
run_unit6 /tmp/tt_focus scripts/ql_focus/truth_table_focus.swift scripts/ql_focus/keyconf.swift \
    qingliao/Core/HabitKit.swift qingliao/Core/FocusTimerStore.swift /tmp/ql_obs_shim.o

echo "=== 97. 可交互表单卡真值表（v4.0.104 待做池 #25 · 卡内提交 / 降级只读 / 提交幂等）==="
# 口径（台账待做池 #25 原文）：ql-card 支持「卡片内提交 / 算数」；卡片动作必须**走既有白名单**、
#   不可用时**降级只读**、反复提交**幂等**。
# 事故面（全静默，装机才发现）：提交回调没接上（卡永远只读，用户以为 AI 不会问话）、
#   视图自己拼合成文本（与解析层口径分叉）、先回调后落账（提交瞬间杀 App 丢回执 → 重进能再提交一遍）、
#   视图自读写 UserDefaults（单一真源破）、只读分支排到交互分支之前（有回调也点不了）、
#   视图直接执行动作（绕过白名单与权限闸门）。
# 分工：test_cardform **真跑**回执存储（指纹 / 幂等覆盖 / 卡间隔离 / 容量淘汰 / 一键清空）；
#   truth_table_cardform 用剥注释的源级断言钉协议、空卡判定、分支与实参顺序、宿主接线。
mkdir -p /tmp/ql_cardform_main
cp scripts/ql_cardform/test_cardform.swift /tmp/ql_cardform_main/main.swift
run_unit6 /tmp/test_cardform qingliao/Core/AgentCardParser.swift qingliao/Core/CardFormStore.swift \
    /tmp/ql_cardform_main/main.swift
run_unit /tmp/tt_cardform scripts/ql_cardform/truth_table_cardform.swift

echo "=== 98. 目标可编辑真值表（v4.0.104 待做池 #16a · 建完能改 / 复用同一份表单 / 推后端）==="
# 口径：目标建完就改不了（标题 + 早/晚提醒开关与时刻本该能改；后端 goal_module.goals_update 早支持）。
# 事故面（全静默）：① 另起一套编辑表单 → 与新建的时刻区间/落库口径分叉；② 表单能选 13 点、
#   payload 按别的区间裁 → 用户以为改了其实后端收到别的值；③ 只改本地不推后端 → 每天两段推送还是旧的；
#   ④ 推失败静默 → 用户毫无提示；⑤ 编辑入口顶掉「暂停/删除」；⑥ 没改动也发请求 → 白盖 updatedAt。
# 分工：test_goal_edit **真跑**纯逻辑（区间/钳位/payload 键集/是否真改动）；truth_table_goal_edit
#   源级钉「复用同一份表单、区间逐字一致、入口顺序、先本地后异步、推失败有提示」。
mkdir -p /tmp/ql_goal_edit_main
cp scripts/ql_goal_edit/test_goal_edit.swift /tmp/ql_goal_edit_main/main.swift
run_unit6 /tmp/test_goal_edit qingliao/Core/GoalEditKit.swift /tmp/ql_goal_edit_main/main.swift
run_unit /tmp/tt_goal_edit scripts/ql_goal_edit/truth_table_goal_edit.swift

echo "=== 99. AI 成品文件卡真值表（#17 · 文件段解析 / 容错丢弃 / 共享下载 / QuickLook）==="
# 口径（协议已与后端约定，不要改字段名）：ql-card JSON 里与 form 同级、互斥的可选段 file：
#   {"type":"file","title":"周报.docx","file":{"path":"office/周报.docx","name":"周报.docx","kind":"docx","size":36765}}
#   path 必填（相对后端允许根的路径，本批只有 `office/` 这一条别名根）；name 缺省用 path 最后一段；
#   kind 缺省由 name 扩展名推断（只认 docx/xlsx/pptx/pdf/image/other，未知一律 other）；size 缺省 0（未知不显示）。
#   **缺 path / path 为空 → 整段丢弃**（退化成普通只读卡，绝不能崩、不能出「查看」按钮）。
# 事故面（全静默，装机才发现）：解析没收 file 段（卡永远不出现）、缺 path 没丢（空壳按钮/空路径下载）、
#   下载 URL 在视图里再拼一次（与共享入口分叉，query 编码/别名根前缀漂移）、卡片自写 UserDefaults、
#   漏 `import QuickLook`（本地 -parse 不报、CI Archive 才炸）。
# 分工：**行为测试**并入 §97 的 test_cardform（真跑生产源码 AgentCardParser：file 段解析 / 缺 path 丢弃 /
#   kind 归一化 / plainText 含文件名）；本段 truth_table_file 用剥注释的源级断言钉解析结构、缺 path 丢弃、
#   下载路径单一真源、共享入口（RemoteFiles.fetchData/fetchToTemp）、QuickLook import 与接线形态。
run_unit /tmp/tt_file scripts/ql_file/truth_table_file.swift

echo "=== 98b2. 任务中心真值表（v4.0.114：「清理已完成」二次确认）==="
# 被测：Features/TaskCenterView.swift（Features **根目录**下，历史上只被语法检查覆盖）。
# 由来：全仓破坏性动作一律二次确认，而「清理已完成」原先**直接删**（点一下已完成任务全没、无法恢复）。
# 形态必须是 v4.0.102 全仓口径：**锚定浮层 AnchorMenuOverlay，不用 confirmationDialog**
#（后者在 iPhone 上固定从底部升起、锚不到触发按钮，仓内已逐个搬走）；且浮层要挂
# NavigationStack **之外**（整页最外层），轻纱才盖得住导航栏（v4.0.77 口径）。
# 全是**编译不报、手点才现**的坏法：漏确认=误删；挂错层=轻纱盖不住导航栏；不采锚点=弹屏幕左上角。
run_unit6 /tmp/tt_taskcenter scripts/ql_taskcenter/truth_table_taskcenter.swift

echo "=== 99b. 工作区「待你处理」真值表（v4.0.109 · 跨会话未答问题卡聚合）==="
# 被测：Core/WorkspacePendingKit.swift（纯逻辑，只 import Foundation）。
# 事故面（**全静默**，装机才发现）：① 字段名与 Core/Models.swift 的 ChatMessage.parse 分叉
#   → 工作区那一块永远空的（不报错、不红字）；② 已答的卡没滤掉（用户点进去发现早答过了）；
#   ③ 同卡重复投递没去重（列表里同一件事出现两遍）；④ 正文没清洗（把「选项：要|不用」当问题显示）；
#   ⑤ 时间单位搞错（毫秒当秒 →「14346 小时前」）；⑥ 逻辑层拖进 SwiftUI → 这张表再也编不过（护栏自毁）。
# 本机无 Xcode SDK → 这张表是推 CI 前唯一能真跑这段解析的地方。
rm -rf /tmp/ql_wspending_main && mkdir -p /tmp/ql_wspending_main
cp scripts/ql_wspending/truth_table_wspending.swift /tmp/ql_wspending_main/main.swift
run_unit6 /tmp/test_wspending /tmp/ql_wspending_main/main.swift qingliao/Core/WorkspacePendingKit.swift

echo "=== 100. 斜杠命令层真值表（#3 · 解析单一真源 / 未知命令不发 LLM / 面板 overlay 常驻）==="
# 口径（方案 .hermes/plans/2026-10-05_235848-qingliao-slash-commands.md）：v1 六条命令
#   /new /model /stop /usage /记一笔 /help，全部复用 App 既有能力（零后端改动、零新依赖）。
# 事故面（全静默，装机才发现）：① 后端 api_server **没有命令分发** → 命令层只能 App 侧拦输入；
#   拦截一旦从 send() 顶部挪走/被别的分支抢先，命令文本就被当普通消息发给模型（污染上下文 / 复读源）；
#   ② 未知命令（/foobar）返回 nil → 同样直通 LLM；③ 命令注册表被复制成第二份（面板/帮助卡各写一份）
#   → 加命令只改一处，两条清单必然漂移；④ 面板改回 `if 命令模式 { … }` 插进输入栏 VStack 子节点
#   → 改 TextField 父级/兄弟集合 → 键盘弹一下又收回（本仓老坑）；⑤ /usage 端点/解析在视图里再写一遍
#   → 与看板分叉；⑥ 命令卡绕过 isPush → 卡 JSON 进 historyPayload（模型把自己的卡读进上下文）。
# 分工：test_slash **真跑**生产源码 Core/SlashCommands.swift（解析容错 / 六条命令 / 面板过滤 / 金额抽取）；
#   truth_table_slash 用剥注释的源级断言钉注册表单一真源、send() 顶部拦截、面板 overlay 常驻、
#   逐条命令复用既有能力、/usage 单一真源、记账同口径与 isPush 落卡。
# ⚠️ cwd 必须 = 仓库根（真值表里全是相对路径，漂移会静默全绿 → 前置哨兵会报红）。
rm -rf /tmp/ql_slash_main && mkdir -p /tmp/ql_slash_main
cp scripts/ql_slash/test_slash.swift /tmp/ql_slash_main/main.swift
run_unit6 /tmp/test_ql_slash qingliao/Core/SlashCommands.swift /tmp/ql_slash_main/main.swift
run_unit /tmp/tt_slash scripts/ql_slash/truth_table_slash.swift

echo "=== 101. 剪贴板历史真值表（v4.0.104 待做池 #11 · 只在主动动作时读 / 唯一写入口 / 一键入待办走 RecordStore）==="
# 口径：iOS **禁止**后台监听剪贴板；程序化读 UIPasteboard.general.string 会弹系统「允许粘贴」提示。
#   所以本项沿用既有口径（HomeCards 剪贴板卡注释）：**只在用户主动动作的那一刻读，绝不轮询、绝不在 body/渲染期读**。
# 事故面（全静默，装机才发现）：① 某处读挪进 body → 每次开首页/进设置弹系统「粘贴」提示；
#   ② 视图自己拼键名 / 自己写 UserDefaults → 绕过唯一写入口，两处真源漂移；
#   ③ 入待办自己拼落库（不走 RecordStore）→ 与账本/生活页口径分叉；
#   ④ 上限常量改名/改值 → 容量兜底失效；⑤ 设置页只加行没挂 .sheet → 点了没反应。
# 分工：test_clipboard **真跑**生产源码 ClipboardHistoryStore（空串/trim/去重/上限 100 淘汰最旧/超长拒收/
#   清空/删单条/关开关不动库/remove 不存在 id 不崩/重载仍在/坏条容错）；
#   truth_table_clipboard 用剥注释的源级断言钉键单一真源、唯一写入口、只在用户动作函数体内读、入待办走 RecordStore、设置页入口与挂 sheet、上限常量逐字。
# ⚠️ cwd 必须 = 仓库根（真值表里全是相对路径，漂移会静默全绿 → 前置哨兵会报红）。
rm -rf /tmp/ql_clipboard_main && mkdir -p /tmp/ql_clipboard_main
cp scripts/ql_clipboard/test_clipboard.swift /tmp/ql_clipboard_main/main.swift
run_unit6 /tmp/test_clipboard qingliao/Core/ClipboardHistoryStore.swift /tmp/ql_clipboard_main/main.swift
run_unit /tmp/tt_clipboard scripts/ql_clipboard/truth_table_clipboard.swift

echo "=== 102. 技能库真值表（#24 · 六端封装 / 别名前缀 / 走现成封装 / 启停软删可撤销 / 沉淀为技能）==="
# 口径：后端六端统一走**别名前缀 `/api/agent/skills`** —— 蜂窝 relay 白名单只放行 `/api/agent`，
#   写死 `/api/skills` 在 Wi-Fi 下看着能过、一到蜂窝就整片死（用户报「蜂窝里技能库打不开」）。
#   传输层抽成可注入闭包，默认注入 App 现成封装 auth.request（自动 Wi-Fi/蜂窝分流 + X-Auth-Token + 假 401 自愈）。
# 事故面（全静默）：① 端点漂移/裸 /api/skills → 蜂窝死；② 自己拼 URL / 自己读 token → 绕过分流必挂；
#   ③ 缺字段/ok:false 解码崩或当成功 → 整页白屏/假成功；④ 删除二次确认用 confirmationDialog → 底部升起锚不到；
#   ⑤ 设置页入口或 .sheet 漏挂 → 点不开；⑥ 搜索索引漏条 → 肉眼可见却搜不到；
#   ⑦ 后端 save 要求 frontmatter 的 name 与保存名一致 → 不对齐一存就 400。
# 分工：test_skills **真跑**生产源码 SkillsClient（假传输：正常/空/缺字段/ok:false/HTTP500/超时/name 校验/
#   frontmatter 对齐/恢复）；truth_table_skills 源级钉端点前缀、走现成封装、不读 token、body 不发请求、
#   AnchorMenuOverlay 二次确认、MarkdownRenderer 详情、设置页入口与挂 sheet、搜索索引、§102 注册。
# ⚠️ cwd 必须 = 仓库根（真值表里全是相对路径，漂移会静默全绿 → 前置哨兵会报红）。
run_unit6 /tmp/test_skills -parse-as-library qingliao/Core/SkillsClient.swift scripts/ql_skills/test_skills.swift
run_unit /tmp/tt_skills scripts/ql_skills/truth_table_skills.swift

echo "=== 103. 阶段总结标记真值表（v4.0.112 · 没跑完的收尾总结不许冒充正常答完）==="
# 口径：Hermes 打满迭代上限时会多写一版**收尾总结**，但它在 wire 上就是一段普通 assistant 正文 ——
#   App 分不出它和「正常答完」，用户会把「我没跑完，先给你这些」当成最终答案。故全链带一个标记：
#   Hermes `hermes.budget_exhausted` → 后端 `st["notice"]="budget"`（只记标记、不碰 content）
#   → 轮询体多 `notice` 键 → App 落库/读回 → 气泡出「阶段总结」角标。
# 事故面（全静默，编译过 / 预检绿，只有真机能看出来）：
#   ① messagesPayload 漏写 notice → 重启 / 切会话后标记丢失，这条总结又冒充正常答完（同 withdrawn/edited 教训）；
#   ② 新一轮不复位 → 上一轮的标记粘到下一轮的正常回答上（假警报）；③ 后台跑流器漏带 → 后台回的消息永无标记；
#   ④ 角标视图写了却没挂进 normalBubbleBody → 用户永远看不到；⑤ 气泡里硬编码 "budget" → 取值真源分叉。
# 分工：本表把 `MessageNotice` 编进来**真跑**（budget / nil / 空串 / 未知取值），其余用剥注释的源级断言钉
#   接线形态（字段 / parse 读回 / 不进 id 与 asPayload / 落库 / 复位 / 后台透传 / 挂载点 / 版本号一致）。
# ⚠️ cwd 必须 = 仓库根（真值表里全是相对路径，漂移会静默全绿 → 前置哨兵会报红）。
# ⚠️ 多文件编译时顶层代码必须在名为 main.swift 的文件里（否则「expressions are not allowed at the top level」）。
rm -rf /tmp/ql_notice_main && mkdir -p /tmp/ql_notice_main
cp scripts/ql_notice/truth_table_notice.swift /tmp/ql_notice_main/main.swift
run_unit6 /tmp/test_notice qingliao/Core/MessageNotice.swift /tmp/ql_notice_main/main.swift

echo "=== 106. 日程预排真值表（v4.0.118 · ① 已知时刻事件预排系统级通知）==="
# 起因（用户 2026-10-16 拍板「123」三条一起做，这是第 ① 条）：后台唤醒时刻由 iOS 定（②③ 只能压时延），
#   而 UNCalendarNotificationTrigger 是**系统闹钟** —— 到点必响：App 被杀 / 手机重启 / 从没打开过都照样响。
#   链路：Hermes push_schedule.py（读 cron/jobs.json 展开 48h 时刻表）→ 后端 schedule_api.py（只存+校验）
#   → App ScheduleStore（拉清单 → 按 SchedulePlanner 判据登记系统通知 → 清孤儿）。
# 事故面（全静默：编译过、预检绿，只有真机或隔天才看得出来）：
#   ① identifier 每次现造 → 重排变**新增**，同一条任务弹 N 遍；
#   ② 不清孤儿 → 任务被删/时间被改后旧请求永远留在系统里继续响（用户以为任务没删掉）；
#   ③ 前缀与用户自建提醒（quick_reminder_）混用 → 两边对账互删对方的通知；
#   ④ 把过去时刻也排进去 → 一条永远不响的哑通知白占配额（iOS 每 App 上限 64 条挂起通知）；
#   ⑤ 不设条数上限 → 排满 64 条，把用户自建提醒一起挤掉；
#   ⑥ 拉不到时刻表就清空 → 断网一次把已排好的闹钟全拆了；
#   ⑦ 启动时顺手申请权限 → 抢同一次系统弹窗，首条推送/提醒页那处回调拿到 false（v3.9.x 老账）；
#   ⑧ 登记失败只打日志不上屏 → 「清单里有、到点没响」用户完全无从查起；
#   ⑨ 路径写成 /api/schedule → 只有 9127 直连通，lucky/蜂窝 relay/nginx 三处全 404（实测已复核）。
# 分工：SchedulePlanner + QingliaoNotifyCopy **编进来真跑**（解析/排期/identifier/孤儿/文案/类别/常量），
#   接线形态用剥注释的源级断言钉住（ScheduleStore / QingliaoApp / ChatAppDelegate）。
# ⚠️ cwd 必须 = 仓库根（表里全是相对路径）；⚠️ 多文件编译时顶层代码只能在 main.swift 里。
rm -rf /tmp/ql_sched_main && mkdir -p /tmp/ql_sched_main
cp scripts/ql_schedule/truth_table_schedule.swift /tmp/ql_sched_main/main.swift
run_unit6 /tmp/test_sched qingliao/Core/SchedulePlanner.swift qingliao/Core/QingliaoNotifyCopy.swift /tmp/ql_sched_main/main.swift

echo "=== 105. 推送及时性 & 后台保活真值表（v4.0.118 · ② 后台补拉收件箱 + ③ BGAppRefreshTask/唤醒台账）==="
# 起因（用户 2026-10-16）：「如何提高轻聊本地推送的及时性和后台保活？」
#   代码级事实：performFetch 原来**只查流式任务**（UserDefaults 有 qingliao_stream_pending 才动），
#   Hermes 推进收件箱的消息（任务中心 / 告警 / 目标日报 / AI 追问）在 App 挂起期间一条都弹不出来 ——
#   这就是"推送不及时"最大的洞。② 补收件箱腿；③ 换 BGAppRefreshTask + 记唤醒台账（把及时性变成可测数字）。
# 事故面（全静默，编译过 / 预检绿，只有真机或隔天才看出来）：
#   ① 退回「只有 stream pending 才动」→ 后台继续静默丢推送（表里有反例断言钉住）；
#   ② identifier 不在 project.yml 的 BGTaskSchedulerPermittedIdentifiers 里 →
#      BGTaskScheduler.register **抛异常**（真机冷启动崩，-parse 与 CI archive 都查不出）；
#      且代码里再写一遍字面量 → 两处漂移后同样崩（表里既查逐字一致、也查代码只用常量）；
#   ③ BGTask 回调在后台队列，方法体进 MainActor 隔离 = SIGTRAP（v3.9.4 通知回调同源坑）；
#   ④ 忘记重排下一次 = 只响一次就断供（系统同时只保留一个未完成请求）；
#   ⑤ 以 applicationDidEnterBackground 为入口 —— 本 App 是 scene 化进程，它**永不被调用**；
#   ⑥ 两条腿各回调一次 completion（未定义行为）；⑦ 已消费键名各写一份 → 同一条推送弹两次；
#   ⑧ 后台补拉不跳 progress / 不设上限 → 一次唤醒刷满通知中心，用户当成故障。
# 分工：InboxBackgroundPlan / BackgroundWakeLog 编进来**真跑**（规则 + 台账格式/摘要），
#   其余用剥注释的源级断言钉接线形态（含 project.yml 白名单逐字一致）。
# ⚠️ cwd 必须 = 仓库根（表里全是相对路径）；⚠️ 多文件编译时顶层代码只能在 main.swift 里。
rm -rf /tmp/ql_bg_main && mkdir -p /tmp/ql_bg_main
cp scripts/ql_bg/truth_table_bg.swift /tmp/ql_bg_main/main.swift
run_unit6 /tmp/test_bg qingliao/Core/BackgroundWake.swift qingliao/Core/InboxBackgroundPlan.swift /tmp/ql_bg_main/main.swift

echo "=== 104. 插话（暂停-恢复）真值表（v4.1.x · 只能插本会话那条流 / 起流失败退排队不丢消息）==="
# 口径：输入栏 ⚡键 = 把本会话正在跑的那条流交给服务端挂起（保留断点现场），本条立刻抢答；
#   原任务在插话流收尾后由服务端自动接回（接回是新任务，本页 6~12s 探针自动接回显示，无需额外代码）。
# 事故面（编译过 / 预检绿，只有真机能看出来）：
#   ① 忘了判「本会话」→ 在 B 会话点 ⚡ 掐掉 A 会话正在等的回答（同 v3.9.41 红色停止键那次的教训）；
#   ② 起流失败（老后端 404 / 开关关 501 / 父流不允许 400）时按普通失败落错误气泡 → 消息看着发丢了，
#      其实该静默退排队；③ 反过来「已起来后中途失败」也退排队 → 同一句被再排一遍 = 重发；
#   ④ 轮询元组从 13 长到 17，三处解包漏改一处 → 静默串位（不报错、拿到的是隔壁字段）；
#   ⑤ 声明序/实参序错位 → 本地查不出、CI Archive 才炸（swiftui-param-order 老账）。
# 分工：InterjectPolicy 编进来**真跑**；接线形态用剥注释的源级断言钉。
# ⚠️ cwd 必须 = 仓库根（真值表里全是相对路径，漂移会静默全绿 → 前置哨兵会报红）。
rm -rf /tmp/ql_ij_main && mkdir -p /tmp/ql_ij_main
cp scripts/ql_interject/truth_table_interject.swift /tmp/ql_ij_main/main.swift
run_unit6 /tmp/test_interject qingliao/Core/InterjectPolicy.swift /tmp/ql_ij_main/main.swift

echo "=== 105. 第 7–12 项 UI 打磨真值表（用户 2026-10-18 清单条目）==="
# 事故面：这六项全是「观感统一」类改动 —— 编译过、预检绿、没有运行日志，只有真机才看得出，
#   人眼回归必漏 ⇒ 只能代码级钉。任何一项被改回旧形态，本组立刻报红。
# —— 第 7 项：交互色（链接/选中/发送）收成一支品牌色；分类色改固定表；深色图标底压一档彩度 ——
cnt=$(grep -cF 'enum BrandColor' qingliao/Theme/Brand.swift | tr -d ' ')
[ "$cnt" -eq 1 ] || { echo "❌ 第 7 项：品牌交互色单一真源 Theme/Brand.swift 不存在（实得 $cnt）"; fail=1; }
cnt=$(grep -cF 'BrandColor.interactiveGradientColors(scheme)' qingliao/Theme/EnvironmentGradient.swift | tr -d ' ')
[ "$cnt" -eq 1 ] || { echo "❌ 第 7 项：发送键/用户气泡应走 BrandColor.interactiveGradientColors（实得 $cnt）"; fail=1; }
cnt=$(grep -cF 'if let c = fixed[name] { return c }' qingliao/Features/Life/RecordSection.swift | tr -d ' ')
[ "$cnt" -eq 1 ] || { echo "❌ 第 7 项：分类色应先命中固定表再回落哈希（实得 $cnt）"; fail=1; }
cnt=$(grep -cF 'static let darkSaturation: Double = 0.82' qingliao/Features/Life/LifeBadges.swift | tr -d ' ')
cnt2=$(grep -cF '.saturation(scheme == .dark ? BadgeShell.darkSaturation : 1)' qingliao/Features/Life/LifeBadges.swift | tr -d ' ')
{ [ "$cnt" -eq 1 ] && [ "$cnt2" -eq 1 ]; } || { echo "❌ 第 7 项：深色图标底未压彩度（常量实得 $cnt / 消费实得 $cnt2）"; fail=1; }
# —— 第 8 项：彩色淡底 浅 0.15 / 深 0.22（新写法一律走 Tint.coloredFill，别再写裸 opacity(0.15)） ——
cnt=$(grep -cF 'scheme == .dark ? strong : 0.15' qingliao/Theme/Tint.swift | tr -d ' ')
[ "$cnt" -eq 1 ] || { echo "❌ 第 8 项：彩色淡底深色档不在 Tint.coloredFill（实得 $cnt）"; fail=1; }
cnt=$(grep -rlF 'Tint.coloredFill(' qingliao/ --include=*.swift | wc -l | tr -d ' ')
[ "$cnt" -ge 5 ] || { echo "❌ 第 8 项：彩色淡底调用点不足 5 个文件（实得 $cnt）—— 有人又写裸 opacity(0.15)"; fail=1; }
# —— 第 9 项：状态图标走符号替换；未读/待办/用量计数走数字过渡 ——
# ⚠️ 触发值必须挂**真正会变的量**（审查 P1 实测）：原先断言钉的是 `value: item.bounceTick`，
#    而 bounceTick 只有「新建会话」那颗会自增、那颗 systemName 写死（符号不变）→ 断言绿、效果全站空转。
# ⚠️ 第 12 项起本行同时带 `options:`（丰富档加长替换节奏）—— 断言匹配的是「挂 systemName」这个语义，
#    形态上带 options 也算真挂；不带 options 的旧形态已不存在（改回旧形态会在下面第 12 项那段报红）。
# 形态=contentTransition（`.symbolEffect(_:options:value:)` 要求 DiscreteSymbolEffect，Replace 不符合，
# CI 首轮 Archive 已实踩）+ 触发值仍是会变的 systemName（缺 animation 触发器 = 替换永不生效）。
cnt=$(grep -cF '.contentTransition(.symbolEffect(.replace, options: Motion.symbolReplaceOptions))' qingliao/Theme/HeaderPillButton.swift | tr -d ' ')
cnt2=$(grep -cF '.animation(Motion.snap, value: item.systemName)' qingliao/Theme/HeaderPillButton.swift | tr -d ' ')
{ [ "$cnt" -eq 1 ] && [ "$cnt2" -eq 1 ]; } || { echo "❌ 第 9 项：页头胶囊的符号替换没挂真正会变的量（contentTransition $cnt / 触发 $cnt2，各应 1）"; fail=1; }
cnt=$(grep -cF '.symbolEffect(.replace, value: item.bounceTick)' qingliao/Theme/HeaderPillButton.swift | tr -d ' ')
[ "$cnt" -eq 0 ] || { echo "❌ 第 9 项：符号替换又被挂回恒 0 的 bounceTick（符号不变 = 空转）"; fail=1; }
cnt=$(grep -cF '.symbolEffect(.bounce, value: item.bounceTick)' qingliao/Theme/HeaderPillButton.swift | tr -d ' ')
[ "$cnt" -eq 1 ] || { echo "❌ 第 9 项：点击弹动反馈（bounce×tick）被删（实得 $cnt）—— 换 replace 不许误伤既有反馈"; fail=1; }
# 负断言：栏头图标是常量，挂 replace 就是死代码（值不变、结构上不可能触发）→ 不许回来
cnt=$(grep -cF 'symbolEffect(.replace, value: sectionIcon)' qingliao/Features/Life/LifeSectionScaffold.swift | tr -d ' ')
[ "$cnt" -eq 0 ] || { echo "❌ 第 9 项：栏头又挂了常量值的符号替换（死代码）—— 要么删，要么让图标真随状态变"; fail=1; }
cnt=$(grep -cF 'contentTransition(.numericText())' qingliao/Features/Sessions/SessionsView.swift | tr -d ' ')
[ "$cnt" -ge 2 ] || { echo "❌ 第 9 项：未读角标未走数字过渡（两处，实得 $cnt）"; fail=1; }
# —— 第 10 项：滚动景深补挂（容器必须惰性堆叠；挂 List 上会让整行常驻缩小变淡） ——
cnt=$(grep -cF '.scrollDepth()' qingliao/Features/Chat/LongReplySheet.swift | tr -d ' ')
[ "$cnt" -ge 1 ] || { echo "❌ 第 10 项：长回复页未挂滚动景深（实得 $cnt）"; fail=1; }
# —— 第 11 项：自绘浮层节拍对齐备忘录（罩 Motion.flow / 面板 Motion.emerge，不再硬编码弹簧） ——
cnt=$(grep -cF 'withAnimation(Motion.flow) { scrimOn = true }' qingliao/Features/OrbIdentifyOverlay.swift | tr -d ' ')
[ "$cnt" -eq 1 ] || { echo "❌ 第 11 项：识别浮层的背景罩未走 Motion.flow（实得 $cnt）"; fail=1; }
cnt=$(grep -cF 'withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { appeared = true }' qingliao/Features/OrbIdentifyOverlay.swift | tr -d ' ')
[ "$cnt" -eq 0 ] || { echo "❌ 第 11 项：识别浮层仍在用硬编码弹簧入场（应走 Motion.emerge）"; fail=1; }
cnt=$(grep -cF 'withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { shown = true }' qingliao/Features/OrbQuickMenu.swift | tr -d ' ')
[ "$cnt" -eq 0 ] || { echo "❌ 第 11 项：智慧球菜单仍在用硬编码弹簧入场（应走 Motion.emerge）"; fail=1; }
# —— 第 12 项：特效总档三选一（关 / 标准 / 丰富）+ 令牌层收敛点 + 设置页入口 ——
for lv in 'case off' 'case standard' 'case rich'; do
  cnt=$(grep -cF "$lv" qingliao/Core/EffectsLevel.swift | tr -d ' ')
  [ "$cnt" -ge 1 ] || { echo "❌ 第 12 项：EffectsLevel 缺档 $lv"; fail=1; }
done
# 🚨 断言必须抽**函数体**，不能裸 grep（本轮实测踩坑）：同一串曾只出现在注释里，
#    裸 `grep -cF` 照样返回 1 → 预检全绿，而 tuned 其实是恒等函数、整个「关」档空转（审查 P0）。
tunedBody=$(awk '/private static func tuned\(/,/^    }/' qingliao/Theme/Motion.swift)
case "$tunedBody" in
  *'EffectsLevel.current.isOff ? .linear(duration: 0.001) : animation'*) : ;;
  *) echo "❌ 第 12 项：Motion.tuned 没有真收敛（「关」档空转）—— 函数体里找不到零时长分支"; fail=1 ;;
esac
# 令牌漏包计数：每条 `static var X: Animation {` 都该套一次 tuned（+1 = tuned 自身的定义行）。
# 审查 P1 实测：snap 当时是唯一漏包的一枚，却有 70+ 调用点，「关」档对它无效。
cntDecl=$(grep -cE '^    static var [A-Za-z]+: Animation \{' qingliao/Theme/Motion.swift | tr -d ' ')
cntTuned=$(grep -c 'tuned(' qingliao/Theme/Motion.swift | tr -d ' ')
[ "$cntTuned" -eq $((cntDecl + 1)) ] || { echo "❌ 第 12 项：有令牌漏套 tuned（声明 $cntDecl 条 / tuned 命中 $cntTuned，应等于声明+1）"; fail=1; }
cnt=$(grep -cF 'Section("动效特效")' qingliao/Features/Settings/SettingsCommon.swift | tr -d ' ')
[ "$cnt" -eq 1 ] || { echo "❌ 第 12 项：外观设置里没有特效总档入口（实得 $cnt）"; fail=1; }
cnt=$(grep -cF '@AppStorage(UserDefaultsKey.effectsLevel)' qingliao/Features/Settings/SettingsCommon.swift | tr -d ' ')
[ "$cnt" -eq 1 ] || { echo "❌ 第 12 项：总档入口没绑 UserDefaultsKey.effectsLevel（实得 $cnt）"; fail=1; }
# —— 第 7 项（本轮收口）：AccentColor 与 BrandColor 同源 ——
# 由头：全站 200+ 处 .accentColor（链接 / 选中态 / 开关 / 光标）不可能逐处改调用点，
#   只能让 colorset 与品牌色同值 —— 这一处一改，全部交互色自动收成一支。
#   脱钩的后果与「收成一支」正好相反：发送键一支、链接与选中另一支，用户一眼看出两支色。
cnt=$(grep -cF '"red" : "0.184"' qingliao/Assets.xcassets/AccentColor.colorset/Contents.json | tr -d ' ')
cnt2=$(grep -cF '"red" : "0.357"' qingliao/Assets.xcassets/AccentColor.colorset/Contents.json | tr -d ' ')
{ [ "$cnt" -eq 1 ] && [ "$cnt2" -eq 1 ]; } || { echo "❌ 第 7 项：AccentColor.colorset 与 BrandColor 脱钩（浅色命中 $cnt / 深色命中 $cnt2，各应 1）"; fail=1; }
cnt=$(grep -cF '0x2F / 255' qingliao/Theme/Brand.swift | tr -d ' ')
cnt2=$(grep -cF '0x5B / 255' qingliao/Theme/Brand.swift | tr -d ' ')
{ [ "$cnt" -eq 1 ] && [ "$cnt2" -eq 1 ]; } || { echo "❌ 第 7 项：BrandColor 色值真源缺失（浅 $cnt / 深 $cnt2）—— Brand.swift 与 colorset 必须两处一起改"; fail=1; }
# —— 第 9 项（本轮补）：用量 / 余额数字也走数字过渡（未读角标之外的第二类计数） ——
cnt=$(grep -cF 'contentTransition(.numericText())' qingliao/Features/Dashboard/UsageCard.swift | tr -d ' ')
[ "$cnt" -ge 2 ] || { echo "❌ 第 9 项：用量 / 余额数字未走数字过渡（实得 $cnt，应 ≥2）"; fail=1; }
# —— 第 10 项（负断言）：滚动景深只补惰性堆叠页 ——
# 转写流与聊天消息行同口径（只增、逐段重写）：挂上会让每段随位置常驻缩小变淡，读作闪。
cnt=$(grep -cF '.scrollDepth()' qingliao/Features/Chat/MeetingMinutesView.swift | tr -d ' ')
[ "$cnt" -eq 0 ] || { echo "❌ 第 10 项：会议转写流挂了滚动景深（与聊天消息行同口径，不许挂）"; fail=1; }
# —— 第 11 项（本轮补）：面板入场几何收成 Motion 单一真源 + 智慧球菜单的罩拆相位 ——
cnt=$(grep -cF 'static let panelEnterScale: CGFloat = 0.94' qingliao/Theme/Motion.swift | tr -d ' ')
cnt2=$(grep -cF 'static let panelEnterRise: CGFloat = 24' qingliao/Theme/Motion.swift | tr -d ' ')
{ [ "$cnt" -eq 1 ] && [ "$cnt2" -eq 1 ]; } || { echo "❌ 第 11 项：面板入场几何单一真源缺失（缩放 $cnt / 位移 $cnt2）"; fail=1; }
cnt=$(grep -cF 'scaleEffect(panelOn ? 1 : Motion.panelEnterScale)' qingliao/Features/Life/MemoGlassOverlay.swift | tr -d ' ')
cnt2=$(grep -cF 'offset(y: panelOn ? 0 : Motion.panelEnterRise)' qingliao/Features/Life/MemoGlassOverlay.swift | tr -d ' ')
{ [ "$cnt" -eq 1 ] && [ "$cnt2" -eq 1 ]; } || { echo "❌ 第 11 项：备忘录浮层未引用几何真源（缩放 $cnt / 位移 $cnt2）—— 别回写字面量 0.94 / 24"; fail=1; }
# v4.0.157：智慧球菜单的罩改短促相位 `Motion.menuScrim`（玻璃胶囊入场改为原地淡入的同一轮性能整改）。
#   语义没变（罩仍是独立相位、先于面板），只是不再吃 flow 的 0.28s 全屏材质淡入。
cnt=$(grep -cF 'withAnimation(Motion.menuScrim) { scrimOn = true }' qingliao/Features/OrbQuickMenu.swift | tr -d ' ')
[ "$cnt" -eq 1 ] || { echo "❌ 第 11 项：智慧球菜单的背景罩未拆相位（实得 $cnt，应为 Motion.menuScrim 独立相位）"; fail=1; }
cnt=$(grep -cF 'withAnimation(Motion.flow) { scrimOn = true }' qingliao/Features/OrbQuickMenu.swift | tr -d ' ')
[ "$cnt" -eq 0 ] || { echo "❌ v4.0.157 回退：智慧球菜单的罩又回到 flow 长淡入（实得 $cnt）—— 见 Motion.menuScrim 注释"; fail=1; }
# 负断言：本菜单是**球心锚定型** —— 套 panelEnterRise 会让胶囊脱开锚点（豁免口径写在 Motion.swift）
# ⚠️ 必须先剥注释再 grep：本文件注释里**刻意**写着 `Motion.panelEnterRise` 讲豁免口径，
#    裸 grep 会被自己的注释判红（第 84 段的 scrollDepth 踩过同一个坑）。
cnt=$(sed 's://.*::' qingliao/Features/OrbQuickMenu.swift | grep -cF 'Motion.panelEnterRise' | tr -d ' ')
[ "$cnt" -eq 0 ] || { echo "❌ 第 11 项：球心锚定型浮层套了面板位移（胶囊会脱开锚点）—— 豁免见 Motion.swift"; fail=1; }
# —— 第 12 项（本轮补）：丰富档只加长「切页 + 符号替换」两侧 ——
cnt=$(grep -cF 'static var symbolReplaceOptions: SymbolEffectOptions' qingliao/Theme/Motion.swift | tr -d ' ')
[ "$cnt" -eq 1 ] || { echo "❌ 第 12 项：丰富档的符号替换节奏真源缺失（实得 $cnt）"; fail=1; }
cnt=$(grep -cF '.contentTransition(.symbolEffect(.replace, options: Motion.symbolReplaceOptions))' qingliao/Theme/HeaderPillButton.swift | tr -d ' ')
[ "$cnt" -eq 1 ] || { echo "❌ 第 12 项：页头胶囊的符号替换未接丰富档（实得 $cnt）"; fail=1; }
# —— CI 首轮实踩的两种回退（各加一条负断言，防复发）——
# ① 带 options 的 view modifier 形态编译不过（DiscreteSymbolEffect 约束）
# ⚠️ 判据不能只数 `.symbolEffect(.replace, options:` —— 合法形态
#    `.contentTransition(.symbolEffect(.replace, options: …))` 也含这个子串（曾自己判自己红）。
#    正确口径：**每一次出现都必须带 contentTransition 前缀**。
cntA=$(grep -cF '.symbolEffect(.replace, options:' qingliao/Theme/HeaderPillButton.swift | tr -d ' ')
cntB=$(grep -cF '.contentTransition(.symbolEffect(.replace, options:' qingliao/Theme/HeaderPillButton.swift | tr -d ' ')
[ "$cntA" -eq "$cntB" ] || { echo "❌ 页头胶囊用回裸 `.symbolEffect(.replace, options:...)` —— 该重载要求 DiscreteSymbolEffect，Replace 不满足，Archive 必挂（裸形态 $((cntA-cntB)) 处）"; fail=1; }
# ② 把 map(\.id) 内联进 .animation(_:value:) 会把 body 类型检查拖爆（TaskCenterView 报过超时）
cnt=$(grep -nE '\.animation\([A-Za-z.]+, value: [a-zA-Z]+\.map\(' qingliao/Features/TaskCenterView.swift | wc -l | tr -d ' ')
[ "$cnt" -eq 0 ] || { echo "❌ TaskCenterView 又把 map(\.id) 内联进 .animation —— 请走显式类型的 taskIdsSignature（$cnt 处）"; fail=1; }
cnt=$(grep -cF 'private var taskIdsSignature: [String] {' qingliao/Features/TaskCenterView.swift | tr -d ' ')
[ "$cnt" -eq 1 ] || { echo "❌ TaskCenterView 的过渡判据签名缺失（实得 $cnt）"; fail=1; }
# ③ 修饰符不许挂在 if/else **语句**上（v4.0.120 第三轮 Archive 实踩）：三分支共同类型被推成存在类型
#    `View` → `instance member 'animation' cannot be used on type 'View'`；本机 `-parse` 与全部真值表
#    全绿、只有 Archive 报。判据/修法见脚本头注（收进 @ViewBuilder 计算属性或 Group 再挂）。
IFCHAIN=$(python3 scripts/check_if_chain_modifier.py qingliao 2>&1 || true)
case "$IFCHAIN" in
  OK*) : ;;
  *) echo "❌ 修饰符挂在 if/else 语句上（SwiftUI 编译不过，只有 Archive 报）→ 收进 @ViewBuilder 计算属性："; echo "$IFCHAIN"; fail=1 ;;
esac

[ $fail -eq 0 ] || { echo "❌ 有护栏失守"; exit 1; }
exit 0
