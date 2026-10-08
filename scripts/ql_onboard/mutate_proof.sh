#!/usr/bin/env bash
# P4 冷启动（条目 17/18）护栏的**反向变异自证**。
# 口径：故意把实现改坏 → 跑表 → 必须报红 → 改回 → 复绿。没红不算数（红不了的表等于没护栏）。
# 用法：bash scripts/ql_onboard/mutate_proof.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SC=/opt/data/swift-toolchain/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swiftc
export HOME=/opt/data/home LD_LIBRARY_PATH=/opt/data/swift-libs TZ=Asia/Shanghai
SW=scripts/ql_onboard/truth_table_onboard.swift
ONB=qingliao/Core/WorkbenchOnboard.swift
BOX=qingliao/Core/ComposerSeedBox.swift
CARD=qingliao/Features/OnboardGuideCard.swift
CHAT=qingliao/Features/Chat/ChatView.swift
LIFE=qingliao/Features/Life/LifeView.swift
BOARD=qingliao/Features/Dashboard/DashboardView.swift

run_app() {
  rm -rf /tmp/mut_onboard && mkdir -p /tmp/mut_onboard
  cp "$SW" /tmp/mut_onboard/main.swift
  $SC -swift-version 6 -o /tmp/tt_onboard_mut /tmp/mut_onboard/main.swift \
      "$ONB" qingliao/Core/WorkbenchScope.swift qingliao/Core/HomeCardOrder.swift \
      >/tmp/mut_onboard_build.log 2>&1 || { echo "BUILD_FAIL"; return 2; }
  /tmp/tt_onboard_mut 2>&1
}

pass=0; fail=0

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

echo "── 口径变异（改坏 qingliao/Core/WorkbenchOnboard.swift）"
mut "会话页文案退回无信息量占位（「暂无消息」）" "$ONB" \
  'title: "这里是干活的地方"' 'title: "暂无消息"'
mut "去掉「有内容就不出」闸门（引导长期霸屏）" "$ONB" \
  'guard empty else { return nil }' 'guard true else { return nil }'
mut "去掉生活模式闸门（生活页凭空多一张卡 —— 红线）" "$ONB" \
  'guard active else { return nil }' 'guard true else { return nil }'
mut "生活页动作落点改回自己那页（点了走不动）" "$ONB" \
  '            seed: "帮我建一个长期目标：每周整理一次家里账单",
            target: .chat),' '            seed: "帮我建一个长期目标：每周整理一次家里账单",
            target: .life),'
mut "动作按钮文案变长句（点下去干什么说不清）" "$ONB" \
  'action: "先建一个目标",' 'action: "点我帮你先建一个长期目标吧",'

echo "── 接线变异（视图层/投递位）"
mut "引导卡不投示例指令（动作变装饰按钮）" "$CARD" \
  'ComposerSeedBox.shared.put(guide.seed)' '_ = guide.seed'
mut "灌指令时顺手弹键盘（违反「未开不弹」）" "$CHAT" \
  'guard let seed = seedBox.take() else { return }' 'guard let seed = seedBox.take() else { return }
            inputFocus = true'
mut "视图自己抄一份文案（文案从此两处）" "$CHAT" \
  'OnboardGuideCard(guide: guide)
                    .padding(.top, 14)' 'Text("这里是干活的地方")
                    OnboardGuideCard(guide: guide)
                    .padding(.top, 14)'
mut "投递位取走不清（同一句话反复灌进来）" "$BOX" \
  'defer { text = nil }' 'if false { text = nil }'
mut "生活页冷启动判定漏掉习惯（有五条习惯也说「什么都没有」）" "$LIFE" \
  '            && HabitStore.shared.habits.isEmpty' ''
mut "看板冷启动判定只看场景（自动化空着也说「家里在跑」）" "$BOARD" \
  'empty: scenes.isEmpty && automations.isEmpty)' 'empty: scenes.isEmpty)'
mut "别的页也往投递位塞（多投手 = 来源说不清）" "$LIFE" \
  '                        OnboardGuideCard(guide: guide)' '                        ComposerSeedBox.shared.put("x")
                        OnboardGuideCard(guide: guide)'

echo
echo "变异自证：$pass 红 / $fail 漏"
[ $fail -eq 0 ] || exit 1
