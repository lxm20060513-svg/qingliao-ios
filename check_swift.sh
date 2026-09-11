#!/bin/bash
# 轻聊 2.0 本地 Swift 预检（无 Xcode 环境的替代验证）
# 用法: ./check_swift.sh   （在 ql_ipa2 目录下）
# HOME 固定为原路径：不同会话 HOME 变化会导致 clang 模块缓存路径错位（PCH path mismatch / missing SwiftShims）
export HOME=/opt/data/home
export LD_LIBRARY_PATH=/opt/data/swift-libs
SWIFT=/opt/data/swift-toolchain/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin

echo "=== 1. 语法检查（全部 .swift） ==="
$SWIFT/swiftc -parse qingliao/QingliaoApp.swift qingliao/Core/*.swift qingliao/Theme/*.swift qingliao/Features/*/*.swift 2>&1 | grep -v "^$" | head -10
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo "✅ 语法通过"
else
    echo "❌ 语法错误（如上）"
    exit 1
fi

echo "=== 2. parseResponse 单元测试 ==="
$SWIFT/swiftc -o /tmp/test_parse scripts/test_parse.swift 2>&1 | head -3
/tmp/test_parse || exit 1

echo "=== 3. relay 编解码单元测试 ==="
$SWIFT/swiftc -o /tmp/test_relay scripts/test_relay.swift 2>&1 | head -3
/tmp/test_relay || exit 1

echo "=== 4. 诊断上报组装 + 离线队列单元测试（v3.6.0）==="
# 多文件编译时只有 main.swift 允许顶层代码 → 复制一份到临时目录做 main.swift
rm -rf /tmp/ql_diag_main && mkdir -p /tmp/ql_diag_main
cp scripts/test_diag.swift /tmp/ql_diag_main/main.swift
$SWIFT/swiftc -swift-version 6 -o /tmp/test_diag /tmp/ql_diag_main/main.swift \
    qingliao/Core/DiagnosticsPayload.swift qingliao/Core/DiagnosticsStore.swift 2>&1 | head -10
/tmp/test_diag || exit 1

echo "=== 5. Agent 结果卡片解析单元测试 ==="
$SWIFT/swiftc -swift-version 6 -o /tmp/test_agent_card qingliao/Core/AgentCardParser.swift scripts/test_agent_card.swift 2>&1 | head -10
/tmp/test_agent_card || exit 1

echo "=== 6. 挂件 Extension 语法检查（v3.8.0 实时活动）==="
$SWIFT/swiftc -parse qingliaoWidget/*.swift qingliao/Core/LiveActivityAttributes.swift 2>&1 | grep -v "^$" | head -10
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
exit $?
