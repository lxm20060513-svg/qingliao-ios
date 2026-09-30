#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""价格监控功能移除的 iOS 端护栏（静态断言，读源码）。

反向自证要求见 skill swift-preflight-blindspots：-parse 查不出「删干净了没有」，
所以这里对每个删除点做「必须为 0」断言，并反向断言「保留物必须还在」
（股票行情 price 字段、快递卡、lifeNumber/lifeInt 等共用工具）。

用法: python3 qingliao_ios/scripts/ql_life_noprice/guard_price_removed.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROOT = "/opt/data/qingliao_ios"

FILES = {
    "Core/LifeConfig.swift": "qingliao/Core/LifeConfig.swift",
    "Core/LifeCards.swift": "qingliao/Core/LifeCards.swift",
    "Features/Settings/SettingsLifeCards.swift": "qingliao/Features/Settings/SettingsLifeCards.swift",
    "Features/Dashboard/LifeExpressPriceCards.swift": "qingliao/Features/Dashboard/LifeExpressPriceCards.swift",
    "Features/Dashboard/LifeCardsSection.swift": "qingliao/Features/Dashboard/LifeCardsSection.swift",
}

# 🚨 v4.0.x 工程瘦身（2026-09-30）：SettingsLifeCards.swift 被拆分，新文件默认**不在**上面的
# FILES 里 → 第 1 段「文件存在且可读」不检查它、第 2 段「已删干净」也不查它 → 被移除的
# 价格监控代码只要整块搬进新文件，本护栏**照样全绿**。这是「负向断言因搬运而静默失效」
# 的典型：绿灯反而是坑（同类坑已在 DashboardView/SettingsModels 拆分时核实过）。
#
# 修法 = 把 GONE 断言改成**全目录扫描**：Settings 目录下任何 .swift 都不得再出现这些符号。
# 只要有人把价格监控代码搬进任何一个新文件，第 2 段立刻见红。
GONE_SCOPE_DIRS = {
    # key 沿用 FILES 的键名，仅用于报告；扫描范围是该目录下全部 .swift
    "Features/Settings/SettingsLifeCards.swift": "qingliao/Features/Settings",
    "Features/Dashboard/LifeExpressPriceCards.swift": "qingliao/Features/Dashboard",
    "Features/Dashboard/LifeCardsSection.swift": "qingliao/Features/Dashboard",
}

# 每个文件里「必须已经完全不存在」的符号
GONE = {
    "Core/LifeConfig.swift": ["LifePrice", "LifePriceItem", "LifePriceSource", "价格监控", '"price"'],
    "Core/LifeCards.swift": ["LifePriceCard", "LifePriceWatchItem", "价格监控", 'case "price"'],
    "Features/Settings/SettingsLifeCards.swift": [
        "LifePriceItem", "priceSection", "priceItemCard", "addPriceItem", "removePriceItem",
        "setExtract", "testPrice", "testButton", "priceTesting", "priceResults",
        "/api/life/price/test", "价格监控", "正则 pattern", "目标价", "币种",
    ],
    "Features/Dashboard/LifeExpressPriceCards.swift": ["LifePriceCardView", "LifePriceRow", "价格监控"],
    "Features/Dashboard/LifeCardsSection.swift": ["LifePriceCardView", "expressPriceBlock", "价格监控", "data.price"],
}

# 必须还在的东西（防误伤）
KEEP = {
    "Core/LifeConfig.swift": ["struct LifeNotify", "struct LifeExpress", "struct LifeConfig",
                              "var json: [String: Any]", "lifeString", "lifeInt", "lifeNumber"],
    "Core/LifeCards.swift": ['case "stock"', 'case "rss"', 'case "express"',
                             "struct LifeExpressCard", "struct LifePlaceholderItem",
                             "var hasLifeCards", "struct LifeStock", "let price: Double?",
                             "var priceText: String", "price: number(j[\"price\"])"],
    "Features/Settings/SettingsLifeCards.swift": ["LifeHeaderEditor", "stockSection",
                                                      "rssSection", "expressSection"],
    "Features/Dashboard/LifeExpressPriceCards.swift": ["struct LifeExpressCardView", "LifeCardHeaderRow"],
    "Features/Dashboard/LifeCardsSection.swift": ["expressBlock", "LifeExpressCardView", "stockCell", "placeholderCard"],
}

fails = []


def ck(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (("  | " + detail) if detail else ""))
    if not cond:
        fails.append(name)


src = {}
print("== 1. 文件存在且可读")
for k, rel in FILES.items():
    p = os.path.join(ROOT, rel)
    ok = os.path.isfile(p)
    ck(rel, ok)
    if ok:
        src[k] = open(p, encoding="utf-8").read()

# 1.5 扫描范围内的全部 .swift（含拆分产生的新文件）—— 见 GONE_SCOPE_DIRS 注释
scope_src = {}   # rel_path -> 源码
for _k, _d in GONE_SCOPE_DIRS.items():
    _abs = os.path.join(ROOT, _d)
    if not os.path.isdir(_abs):
        continue
    for _f in sorted(os.listdir(_abs)):
        if not _f.endswith(".swift"):
            continue
        _rel = os.path.join(_d, _f)
        scope_src[_rel] = open(os.path.join(_abs, _f), encoding="utf-8").read()
ck("扫描范围内有 .swift 可读（拆分新文件也会被扫到）", len(scope_src) > 0,
   "scanned=%d" % len(scope_src))

print("== 2. 已删干净（每个符号必须 0 命中）")
for k, syms in GONE.items():
    s = src.get(k)
    if s is None:
        continue
    for sym in syms:
        n = s.count(sym)
        ck("%s 无 %r" % (k.split("/")[-1], sym), n == 0, "count=%d" % n)

print("== 2.5 全目录扫描：被移除的符号不得出现在任何拆分新文件里")
# 关键：范围 = 该 GONE 键所在目录下的**每一个** .swift（含不在 FILES 里的新文件）
for k, syms in GONE.items():
    scope_dir = GONE_SCOPE_DIRS.get(k)
    if not scope_dir:
        continue
    for sym in syms:
        bad = [rel for rel, s in scope_src.items()
               if rel.startswith(scope_dir + os.sep) and sym in s]
        ck("%s/ 全目录无 %r" % (scope_dir.split("/")[-1], sym), not bad,
           ("命中: " + ", ".join(os.path.basename(b) for b in bad)) if bad else "")

print("== 3. 未误伤（保留物必须还在）")
for k, syms in KEEP.items():
    s = src.get(k)
    if s is None:
        continue
    for sym in syms:
        ck("%s 仍含 %r" % (k.split("/")[-1], sym), sym in s)

print("== 4. 替换字符（乱码）不得残留")
for k, s in src.items():
    ck("%s 无 U+FFFD" % k.split("/")[-1], "�" not in s)

print("== 5. 括号/大括号配平（删大段代码后最易破的坑）")
for k, s in src.items():
    body = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', s)      # 去字符串字面量
    body = re.sub(r"//[^\n]*", "", body)                 # 去行注释
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)    # 去块注释
    for o, c, name in (("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")):
        d = body.count(o) - body.count(c)
        ck("%s %s配平" % (k.split("/")[-1], name), d == 0, "delta=%d" % d)

print("== 6. LifeConfig 序列化不含 price 键（App 回传不该再带 price）")
lc = src.get("Core/LifeConfig.swift", "")
# 必须锚在 struct LifeConfig 之后：文件里还有别的 `var json`，贪婪匹配会抓错块
_i = lc.find("struct LifeConfig")
ck("struct LifeConfig 存在", _i != -1)
_seg = lc[_i:] if _i != -1 else ""
m = re.search(r"var json: \[String: Any\] \{(.*?)\n    \}", _seg, re.S)
ck("LifeConfig.json 存在", bool(m))
if m:
    ck("LifeConfig.json 不含 price", '"price"' not in m.group(1))
    for need in ('"version"', '"stocks"', '"rss"', '"express"', '"notify"'):
        ck("LifeConfig.json 仍含 %s" % need, need in m.group(1))

print("== 7. LifeCardsData 无 price 字段 / hasLifeCards 只判快递")
d = src.get("Core/LifeCards.swift", "")
ck("LifeCardsData 无 var price:", "var price: LifePriceCard?" not in d)
hb = re.search(r"var hasLifeCards: Bool \{(.*?)\n    \}", d, re.S)
ck("hasLifeCards 存在", bool(hb))
if hb:
    ck("hasLifeCards 只看 express", "express" in hb.group(1) and "price" not in hb.group(1),
       hb.group(1).strip()[:60])

print()
if fails:
    print("❌ FAILED %d:" % len(fails))
    for f in fails:
        print("   - " + f)
    sys.exit(1)
print("✅ ALL PASS（价格监控 iOS 端已移除，未误伤其它功能）")
