#!/usr/bin/env bash
# 建议池②「AI 记住反馈+撤销」护栏的**反向变异自证**。
# 口径：故意把实现改坏 → 跑表 → 必须报红 → 改回 → 复绿。没红不算数。
# 用法：bash scripts/ql_memo_added/mutate_proof.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SC=/opt/data/swift-toolchain/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swiftc
export LD_LIBRARY_PATH=/opt/data/swift-libs
SW=scripts/ql_memo_added/truth_table_memo_added.swift
BE=scripts/ql_memo_added/truth_table_memo_added_be.py
CV=qingliao/Features/Chat/ChatView.swift
MB=qingliao/Features/Chat/ChatMemoBar.swift
SC2=qingliao/Core/StreamClient.swift
MEM=/opt/data/cache/scratch/mem_store_live.py
STREAM=/opt/data/cache/scratch/stream_api_live.py

pass=0; fail=0
run_app() { rm -f /tmp/tt_memo_mut; $SC -o /tmp/tt_memo_mut "$SW" >/tmp/mut_build.log 2>&1 || { echo "BUILD_FAIL"; return 2; }
            QL_REPO="$ROOT" /tmp/tt_memo_mut 2>&1; }
run_be()  { ( cd scripts/ql_memo_added && python3 truth_table_memo_added_be.py 2>&1 ); }

# 变异：改坏 → 期望报红 → 复原
mut() {
  local label="$1" file="$2" from="$3" to="$4" runner="$5"
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
  out=$($runner); rc=$?
  cp "$bak" "$file"; rm -f "$bak"
  if [ $rc -ne 0 ] && echo "$out" | grep -q '❌'; then
    pass=$((pass+1)); echo "  ✅ 变异报红：$label"
  else
    fail=$((fail+1)); echo "  ❌ 变异没红（护栏失守）：$label  rc=$rc"
  fi
}

echo "── 基线（未变异，两表都必须绿）"
o1=$(run_app); r1=$?
o2=$(run_be);  r2=$?
if [ $r1 -eq 0 ] && ! echo "$o1" | grep -q '❌'; then pass=$((pass+1)); echo "  ✅ App 表基线绿：$(echo "$o1"|tail -1)"; else fail=$((fail+1)); echo "  ❌ App 表基线就红"; echo "$o1"|tail -5; fi
if [ $r2 -eq 0 ] && ! echo "$o2" | grep -q '❌'; then pass=$((pass+1)); echo "  ✅ 后端表基线绿：$(echo "$o2"|tail -2|head -1)"; else fail=$((fail+1)); echo "  ❌ 后端表基线就红"; echo "$o2"|tail -6; fi

echo "── App 侧变异"
mut "把提示条的挂载点删掉（bar 再也不显示）" "$CV" \
  '} else if !stream.memoAdded.isEmpty {' '' run_app
mut "撤销改成打错的端点（记忆删不掉）" "$CV" \
  '"/api/memory/delete"' '"/api/memory/delee"' run_app
mut "撤销 try? 吞错不判 ok（看着删了其实没删）" "$CV" \
  '(j["ok"] as? Bool) == true else {' 'true else {' run_app
mut "撤销失败不震动（失败静默=假装成功）" "$CV" \
  'Haptics.error()
                    if !deleted.isEmpty' 'if !deleted.isEmpty' run_app
mut "撤销成功不摘本流（后端重发→删了又弹）" "$CV" \
  '            Haptics.success()
            stream.forgetMemo(texts)' '            Haptics.success()' run_app
mut "去掉撤销屏蔽集闸门（memoDismissed 失效）" "$SC2" \
  '&& !memoDismissed.contains($0)' '' run_app
mut "复位不再清 memoAdded（切会话后旧条压住新条）" "$SC2" \
  '        memoAdded = []
        memoDismissed = []' '        memoDismissed = []' run_app
mut "自造胶囊样式（不走 PillSize.topBar）" "$MB" \
  '.pill(.topBar, tone: .danger)' '.background(Color.red)' run_app

echo "── 后端侧变异（改线上字节的**副本**，绝不碰 NAS 真身）"
bak=$(mktemp); cp "$MEM" "$bak"
python3 - "$MEM" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
a = "if add_entry(phrase, source=\"chat\", session_id=session_id):"
assert a in s, "锚点未命中"
open(p, 'w', encoding='utf-8').write(s.replace(a, "if False:", 1))
PY
if [ $? -ne 0 ]; then echo "  ⚠️ 后端锚点没命中，跳过"; cp "$bak" "$MEM"; rm -f "$bak"
else
  o=$(run_be); rc=$?
  cp "$bak" "$MEM"; rm -f "$bak"
  if [ $rc -ne 0 ] && echo "$o" | grep -q '❌'; then pass=$((pass+1)); echo "  ✅ 变异报红：自动写入被掐断（记住…永不落盘）"
  else fail=$((fail+1)); echo "  ❌ 变异没红：自动写入被掐断  rc=$rc"; fi
fi

bak=$(mktemp); cp "$STREAM" "$bak"
python3 - "$STREAM" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
a = '"memoAdded": [str(x) for x in (st.get("memoAdded") or [])],'
assert a in s, "锚点未命中"
# 改成只下发本次增量 → App 的差集/撤销屏蔽集两道闸门全废
open(p, 'w', encoding='utf-8').write(s.replace(a, '"memoAdded": [],', 1))
PY
if [ $? -ne 0 ]; then echo "  ⚠️ 后端锚点没命中，跳过"; cp "$bak" "$STREAM"; rm -f "$bak"
else
  o=$(run_be); rc=$?
  cp "$bak" "$STREAM"; rm -f "$bak"
  if [ $rc -ne 0 ] && echo "$o" | grep -q '❌'; then pass=$((pass+1)); echo "  ✅ 变异报红：poll 不下发 memoAdded（App 永远不弹条）"
  else fail=$((fail+1)); echo "  ❌ 变异没红：poll 不下发 memoAdded  rc=$rc"; fi
fi

echo
echo "变异自证：$pass 红 / $fail 漏"
[ $fail -eq 0 ] || exit 1
