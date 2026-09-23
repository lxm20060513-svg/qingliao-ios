#!/bin/bash
# 轻聊 2.0 本地 Swift 预检（无 Xcode 环境的替代验证）
# 用法: ./check_swift.sh   （在 ql_ipa2 目录下）
# HOME 固定为原路径：不同会话 HOME 变化会导致 clang 模块缓存路径错位（PCH path mismatch / missing SwiftShims）
export HOME=/opt/data/home
export LD_LIBRARY_PATH=/opt/data/swift-libs
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

exit $?
