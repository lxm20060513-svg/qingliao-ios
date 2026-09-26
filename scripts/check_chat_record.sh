#!/bin/bash
# 一句话记账（聊天页入口 · v4.0.x 口径 1a）真值表 —— 本机（无 Xcode）可跑的部分
#
# 已并入 check_swift.sh **第 28 段**（v4.0.x 收尾：三条新真值表登记完成）。
# 本脚本保留为「单跑这一张表」的便捷入口；要删可删（check_swift.sh 那段是权威入口）。
#
# 覆盖：识别（裸数字 / 带单位复用 IntentPipeline）· 反例占比哨兵 · 分类与 note · 卡片能被真解析器解出 ·
#       去重签名与时间文案。UI（卡片渲染位置 / 撤销动作条）本机无法验，只能真机看。
#
# 用法：./scripts/check_chat_record.sh
cd "$(dirname "$0")/.." || exit 1
export HOME=/opt/data/home
export LD_LIBRARY_PATH=/opt/data/swift-libs
export TZ=Asia/Shanghai
SWIFT=/opt/data/swift-toolchain/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin

OUT=/tmp/test_chat_record
rm -f "$OUT"          # 先删旧产物：编译失败时若还留着上一轮的二进制就会被骗成绿
$SWIFT/swiftc -swift-version 6 -o "$OUT" \
    scripts/test_chat_record.swift \
    qingliao/Core/ChatRecordKit.swift \
    qingliao/Core/IntentPipeline.swift \
    qingliao/Core/QuickReminder.swift \
    qingliao/Core/RecordKit.swift \
    qingliao/Core/AgentCardParser.swift 2>&1 | head -20
[ ${PIPESTATUS[0]} -eq 0 ] || { echo "❌ 一句话记账真值表编译失败"; exit 1; }
"$OUT" || exit 1
