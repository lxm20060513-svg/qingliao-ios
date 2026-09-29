#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v4.0.9 点击震动总开关真值表（静态源码护栏，退出码 0/1）

背景：用户要求「设置里增加 App 点击震动开关，可以关掉」。
全站有 144 处 `Haptics.*` 调用点 + 此前 17 处绕过封装的裸 FeedbackGenerator。

设计：闸门只加在 Core/Haptics.swift 的语义入口（tap/press/success/error + 收编入口），
**不在 144 个调用点逐个加 if** —— 那样漏一处就漏一处震动，且以后新增调用点还会再漏。

本表钉住：
  1. 闸门存在：所有震动入口都有 guard，且覆盖全部分支
  2. 裸 FeedbackGenerator 在业务代码里**清零**（那种写法绕过闸门，关了开关照震）
  3. 设置页有唯一 UI 入口，且与 Haptics.enabledKey 共用同一个 key（勿各写一份字符串）
  4. 默认开（key 缺失 = 老用户行为不变）
  5. 闸门 key 在 Haptics 与设置页两侧字面一致
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "qingliao")
HAPTICS = os.path.join(SRC, "Core", "Haptics.swift")
SETTINGS = os.path.join(SRC, "Features", "Settings", "SettingsCore.swift")

fails = []
total = 0


def check(desc, cond):
    global total
    total += 1
    if cond:
        print("✅ " + desc)
    else:
        print("❌ " + desc)
        fails.append(desc)


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


h = read(HAPTICS)
s = read(SETTINGS)

# ── 1. 闸门存在且覆盖全入口 ─────────────────────────────────
ENTRIES = ["tap", "press", "success", "error",
           "light", "medium", "heavy", "rigid", "selection", "prepareHeavy"]
for name in ENTRIES:
    m = re.search(r'static func %s\(\)\s*\{(.*?)\n    \}' % name, h, re.S)
    check("入口 %s() 有闸门 guard" % name, bool(m) and "gated()" in m.group(1))

m = re.search(r'static func notify\((.*?)\)\s*\{(.*?)\n    \}', h, re.S)
check("入口 notify() 有闸门 guard", bool(m) and "gated()" in m.group(2))

# ── 2. 裸 FeedbackGenerator 在业务代码里清零 ────────────────
offenders = []
for dirpath, _, files in os.walk(SRC):
    for fn in files:
        if not fn.endswith(".swift"):
            continue
        path = os.path.join(dirpath, fn)
        if os.path.abspath(path) == os.path.abspath(HAPTICS):
            continue  # 封装自身不算
        src = read(path)
        if re.search(r'UI(Impact|Selection)FeedbackGenerator\(\)', src) or \
           re.search(r'UINotificationFeedbackGenerator\(\)\.notificationOccurred', src):
            offenders.append(os.path.relpath(path, ROOT))
check("业务代码无裸 FeedbackGenerator（实测 %d 处）" % len(offenders),
      len(offenders) == 0)
for o in offenders:
    print("     ↳ " + o)

# ── 3. 设置页有唯一 UI 入口，且共用同一个 key ─────────────
check("设置页有「震动反馈」行", 'title: "震动反馈"' in s)
check("设置页该行挂在 toggle: 上", re.search(r'title: "震动反馈"', s) is not None
      and "toggle: $hapticsOn" in s)
check("设置页用 Haptics.enabledKey（不另写字符串）",
      "@AppStorage(Haptics.enabledKey) private var hapticsOn" in s)
check("Haptics 暴露 enabledKey 常量", 'static let enabledKey' in h)
# key 字面只允许在 Haptics 里出现一次
key_lit = re.findall(r'"(qingliao_haptics_enabled)"', h + s)
check("key 字面只出现 1 次（防两边各写一份漂移），实测 %d" % len(key_lit),
      len(key_lit) == 1)

# ── 4. 默认开（老用户行为不变）────────────────────────────
# v3.9.111：改为直读 UserDefaults（Swift 不允许 property wrapper 应用于 static
# 存储属性，wrappedValue 初始化处编译报错）。默认值口径不变：读不到 = 开。
check("默认值为 true（key 缺失 = 开）",
      re.search(r'as\? Bool\)\s*\?\? true', h) is not None)
check("开关直读 UserDefaults.enabledKey（不再用 static @AppStorage）",
      re.search(r'UserDefaults\.standard\.object\(forKey: enabledKey\)', h) is not None)
check("设置页默认 true", re.search(r'private var hapticsOn = true', s) is not None)

# ── 5. 闸门语义：early-return，不能是「照震只是调轻」─────
check("闸门是 early-return（guard gated() else { return }）",
      h.count("guard gated() else { return }") >= len(ENTRIES) + 1)

# ── 6. 中等强度手感未被改动（防手滑改 press() 的力度）─────
m = re.search(r'static func press\(\)\s*\{(.*?)\n    \}', h, re.S)
check("press() 仍用 mediumGen（v4.0.9 曾手滑改成 heavy，已修）",
      bool(m) and "mediumGen.impactOccurred()" in m.group(1))
check("mediumGen 仍是 .medium（不是 .heavy）",
      re.search(r'private static let mediumGen = UIImpactFeedbackGenerator\(style: \.medium\)', h) is not None)

# ── 7. 禁止 static @AppStorage（v3.9.111 阻断2 专用护栏）──────────────
# Swift **不允许** property wrapper 应用于 static 存储属性，且 -parse 放行，
# 全仓无 static @AppStorage 先例可援引 → 只能靠 CI Archive 炸出来。
for _p in ("qingliao/Core/Haptics.swift", "qingliao/Features/Settings/SettingsCore.swift"):
    _s = open(os.path.join(ROOT, _p), encoding="utf-8").read()
    check("%s 无 static @AppStorage（属性包装器不适用于 static 存储属性）" % _p,
          re.search(r'@AppStorage\([^)]*\)\s*(private\s+)?static\s+var', _s) is None)

# ── 8. 闸门必须走单一真源，不许有第二份开关状态 ──────────────
check("gated() 走单一真源 enabled（无第二份状态）",
      "private static func gated() -> Bool { enabled }" in h)

print("")
if fails:
    print("失败 %d 条 ❌" % len(fails))
    sys.exit(1)
print("全部通过：%d 项 ✅" % total)
sys.exit(0)
