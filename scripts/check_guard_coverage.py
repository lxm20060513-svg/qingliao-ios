#!/usr/bin/env python3
"""护栏覆盖率守卫（v4.0.x · 工程治理第 1 号整改）

问题：scripts/ql_* 下每个真值表目录，历史上出现过"写好了但从没被 check_swift.sh 调用"
      —— 本地/CI 都不跑，等于没有护栏。本脚本把这件事变成硬断言。

两条判据：
  ① 无孤儿：scripts/ql_*/ 里的每个真值表/脚本，都必须在 check_swift.sh 里被引用；
  ② 不断链：真值表里 src()/read 读到的 qingliao/… 源文件路径必须真实存在
     （防止重构改了文件名、真值表默默读空字符串后一路假绿 —— 与 ql_settings_ui
     剥注释那次的动机一致）。

用法：python3 scripts/check_guard_coverage.py   （check_swift.sh 第 41 段调用）
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")
CHECK_SH = os.path.join(ROOT, "check_swift.sh")

fails = []


def read(path):
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            return f.read()
    except OSError:
        return ""


sh = read(CHECK_SH)
if not sh:
    print("❌ 读不到 check_swift.sh，本守卫无法自证")
    sys.exit(1)

# ① 孤儿真值表
guard_dirs = sorted(
    d for d in os.listdir(SCRIPTS)
    if d.startswith("ql_") and os.path.isdir(os.path.join(SCRIPTS, d))
)
wired = 0
for d in guard_dirs:
    ref = ("scripts/%s/" % d) in sh or (d + "/") in sh
    if ref:
        wired += 1
    else:
        fails.append("孤儿真值表：scripts/%s/ 未被 check_swift.sh 引用（本地和 CI 都不会跑）" % d)

# 顶层 scripts/*.py 守卫同样不能漏挂；运维/一次性脚本不在此列（由 RUNBOOK 约定手动跑）
OPS_SCRIPTS = {"sync_vision_model.py", "watch_ipa_ci.py"}
for f in sorted(os.listdir(SCRIPTS)):
    if f.endswith(".py") and f not in OPS_SCRIPTS and f != os.path.basename(__file__):
        if f not in sh:
            fails.append("孤儿脚本：scripts/%s 未被 check_swift.sh 引用" % f)

# ② 真值表「读进来断言」的源码路径必须存在
#    只认 src("…") / read(...) 这类主动读取；fileExists(atPath:) 是「必须不存在」的负向
#    断言（例：断言 PhotoAskView 已被删干净），那种路径本就不该存在，不能算断链。
SRC_RE = re.compile(r'(?:src|read|contentsOfFile|readFile)\(\s*(?:ofFile|path)?\s*:?\s*"(qingliao(?:/[\w.\-]+)+\.swift|qingliaoShare/[\w.\-]+\.swift|qingliaoWidget/[\w.\-]+\.swift)"')
checked = 0
missing = set()
for d, _, files in os.walk(SCRIPTS):
    for f in files:
        if not f.endswith(".swift"):
            continue
        for m in SRC_RE.findall(read(os.path.join(d, f))):
            checked += 1
            if not os.path.exists(os.path.join(ROOT, m)):
                missing.add(m)

for m in sorted(missing):
    fails.append("断链：真值表引用的 %s 不存在（重构后未同步，会一路假绿）" % m)

if fails:
    for x in fails:
        print("❌ " + x)
    sys.exit(1)

print("✅ 护栏覆盖：%d 个真值表目录全部挂进 check_swift.sh；%d 处源码引用无断链" % (wired, checked))
