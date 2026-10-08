#!/usr/bin/env bash
# P3 深度（条目 13/14/15/16）护栏的**反向变异自证**。
# 口径：故意把实现改坏 → 跑表 → 必须报红 → 改回 → 复绿。没红不算数（红不了的表等于没护栏）。
# 用法：bash scripts/ql_insight/mutate_proof.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SC=/opt/data/swift-toolchain/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swiftc
export HOME=/opt/data/home LD_LIBRARY_PATH=/opt/data/swift-libs TZ=Asia/Shanghai
SW=scripts/ql_insight/truth_table_insight.swift
INS=qingliao/Core/WorkbenchInsight.swift
BAR=qingliao/Features/Workbench/VerdictBar.swift
MOD=qingliao/Core/Models.swift

run_app() {
  rm -rf /tmp/mut_insight && mkdir -p /tmp/mut_insight
  cp "$SW" /tmp/mut_insight/main.swift
  $SC -swift-version 6 -o /tmp/tt_insight_mut /tmp/mut_insight/main.swift \
      "$INS" qingliao/Core/WorkbenchScope.swift qingliao/Core/HabitKit.swift \
      qingliao/Core/HomeCardOrder.swift >/tmp/mut_insight_build.log 2>&1 || { echo "BUILD_FAIL"; return 2; }
  /tmp/tt_insight_mut 2>&1
}

pass=0; fail=0

# 变异：改坏 → 期望报红 → 复原
mut() {
  local label="$1" file="$2" from="$3" to="$4"
  local bak; bak=$(mktemp); cp "$file" "$bak"
  python3 - "$file" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
assert a in s, "变异锚点不存在：" + a
open(p, 'w', encoding='utf-8').write(s.replace(a, b, 1))
PY
  if [ $? -ne 0 ]; then echo "  ⚠️ 锚点没命中，跳过：$label"; cp "$bak" "$file"; rm -f "$bak"; return; fi
  local out rc
  out=$(run_app); rc=$?
  cp "$bak" "$file"; rm -f "$bak"
  if [ $rc -ne 0 ] && echo "$out" | grep -q '❌'; then
    pass=$((pass+1)); echo "  ✅ 变异报红：$label"
  else
    fail=$((fail+1)); echo "  ❌ 变异没红（护栏失守）：$label  rc=$rc"
    echo "$out" | tail -3 | sed 's/^/      /'
  fi
}

echo "── 基线（未变异必须绿）"
o=$(run_app); rc=$?
if [ $rc -eq 0 ] && ! echo "$o" | grep -q '❌'; then
  pass=$((pass+1)); echo "  ✅ 基线绿：$(echo "$o" | grep '共 .* 条断言')"
else
  fail=$((fail+1)); echo "  ❌ 基线就红"; echo "$o" | tail -6 | sed 's/^/      /'
fi

echo "── 判定逻辑变异（改坏 qingliao/Core/WorkbenchInsight.swift）"
mut "停滞阈值被悄悄改成 1 天（界面说 3 天、实际 1 天就报警）" "$INS" \
  'static let stallThresholdDays = 3' 'static let stallThresholdDays = 1'
mut "停滞不排除「已暂停」（用户自己按的暂停也算凉了）" "$INS" \
  'guard !g.finished, !g.paused else { return nil }' 'guard !g.finished else { return nil }'
mut "断签把「今天还没结束」算成漏打卡（天天冤枉用户）" "$INS" \
  'if dayKeys.contains(HabitKit.dayKey(today, calendar: calendar)) { return nil }' 'if false { return nil }'
mut "断签空洞不做上限（脏数据里日期跳过 → 白算上万天）" "$INS" \
  'while gap < 366, !dayKeys.contains(' 'while gap < 3, !dayKeys.contains('
mut "用量趋势去掉「全 0 就不出」闸门（没数据也画一排空柱子）" "$INS" \
  'guard maxTotal > 0 else { return nil }' 'guard maxTotal >= 0 else { return nil }'
mut "负值不钳 0（脏数据画负高度、比例算出负数）" "$INS" \
  'Double(max(d.total, 0)) / Double(maxTotal)' 'Double(d.total) / Double(maxTotal)'
mut "断签去掉生活模式闸门（生活页凭空多一行断签）" "$INS" \
  'guard active else { return nil }' 'guard true else { return nil }'

echo "── 接线/口径变异（视图层与解析层是文本断言，不进编译）"
mut "结论条不再读 store 的个数（写死 3，数字说了不算）" "$BAR" \
  'WorkbenchInsight.stallHint(store.stalledGoalCount)' 'WorkbenchInsight.stallHint(3)'
mut "失败原因那行改成永远画（没原因也占位一行）" "$BAR" \
  'if let why = WorkbenchInsight.failureReason(t.reason)' 'if true'
mut "用量日序列不钳负（坏值直接进卡片）" "$MOD" 'max(0, n)' 'n'

echo
echo "变异自证：$pass 红 / $fail 漏"
[ $fail -eq 0 ] || exit 1
