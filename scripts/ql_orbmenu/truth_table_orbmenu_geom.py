#!/usr/bin/env python3
# OrbQuickMenu 胶囊几何真值表 —— 必须解析生产源码，不写镜像实现
#
# 事故 1（v3.9.96 引入）：最上排整体左移一列 —— col 算式写成
#       CGFloat(i >= 6 ? i - 7 : i % 3) - 1，外面的 -1 把 6/7/8 映射成 −2/−1/0。
#       375pt 屏 index 6「会话纪要」中心 x = −48.5pt、左缘 −99pt，整颗落在屏幕左侧之外。
# 事故 2（修事故 1 时我自己引入）：直接删掉那个 -1 → 下/中排也失去 -1，列位成 0/1/2，
#       最右一列中心 451pt、右缘 501.5pt，在 430pt 屏上飞出右边。
# 正确形态：-1 只作用于 i<6 那段（i%3 − 1），i≥6 段本身就是 −1/0/+1、不再减。
#
# 纪律：本表从 OrbQuickMenu.swift 解析列位算式，源码改了就必须同步表；
#       两个事故形态各自钉一条反向自证，任一形态回归都必须判红。
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / "qingliao" / "Features" / "OrbQuickMenu.swift").read_text(encoding="utf-8")

fails = []


def ck(desc, cond):
    print(("PASS  " if cond else "FAIL  ") + desc)
    if not cond:
        fails.append(desc)


def grab(name):
    m = re.search(rf"static let {name}: CGFloat = ([\d.]+)", src)
    assert m, f"常量 {name} 解析失败（源码结构变了？）"
    return float(m.group(1))


columnDX = grab("columnDX")
topDY, upperDY, lowerDY = grab("topDY"), grab("upperDY"), grab("lowerDY")
PILL_W, PILL_H = 101.0, 36.0

# 解析 center() 的列位算式；只接受「两段各自 −1/0/+1」的正确形态
m = re.search(
    r"let col: CGFloat = CGFloat\(i >= 6 \? i - (\d+) : i % (\d+)\) - \(i >= 6 \? 0 : (\d+)\)",
    src,
)
if m:
    _hi_shift, _lo_mod, _lo_shift = int(m.group(1)), int(m.group(2)), int(m.group(3))
    _hi_extra_shift = 0                      # 正确形态：i≥6 段不再减
    _mode = "split"
elif re.search(r"let col: CGFloat = CGFloat\(i >= 6 \? i - 7 : i % 3\) - 1", src):
    _hi_shift, _lo_mod, _lo_shift = 7, 3, 1
    _hi_extra_shift = 1                      # 事故 1：−1 同样作用于 i≥6 段 → 6/7/8 变 −2/−1/0
    _mode = "bug_uniform_minus1"             # 事故 1 形态
elif re.search(r"let col: CGFloat = CGFloat\(i >= 6 \? i - 7 : i % 3\)\s*(?://.*)?$", src, re.M):
    _hi_shift, _lo_mod, _lo_shift = 7, 3, 0
    _hi_extra_shift = 0                      # 事故 2：完全不减 → 下/中排列位变 0/1/2
    _mode = "bug_no_minus1"                  # 事故 2 形态
else:
    print("FAIL  无法解析 center() 的列位算式（源码结构变了，需同步本表）")
    sys.exit(1)


def center(index, cx):
    i = ((index % 9) + 9) % 9
    col = float((i - _hi_shift - _hi_extra_shift) if i >= 6 else (i % _lo_mod - _lo_shift))
    dy = topDY if i >= 6 else (upperDY if i >= 3 else lowerDY)
    return cx + col * columnDX, dy


print("== 解析到的生产几何")
print(f"   columnDX={columnDX} topDY={topDY} upperDY={upperDY} lowerDY={lowerDY}")
print(f"   列位算式模式 = {_mode}（hi_shift={_hi_shift} lo_mod={_lo_mod} lo_shift={_lo_shift}）")
TITLES = ["新建会话", "AI 速记", "今日待办", "AI 识别", "语音对话", "语音输入",
          "会话纪要", "拍照识别", "记一笔"]

print("\n== 1. 九颗列位（两段都须是 −1/0/+1）")
for i in range(9):
    cx = center(i, 187.5)[0]
    got = (cx - 187.5) / columnDX
    ck(f"index {i} {TITLES[i]} 列位 = {got:+.0f}", got in (-1, 0, 1))

print("\n== 2. 事故场景：会话纪要(index 6) 不得飞出屏幕")
for sw in (375, 393, 402, 430):
    for i in (6, 7, 8):
        x, _ = center(i, sw / 2)
        left, right = x - PILL_W / 2, x + PILL_W / 2
        ck(f"{sw}pt {TITLES[i]} 左缘 {left:.1f} ≥ 8", left >= 8)
        ck(f"{sw}pt {TITLES[i]} 右缘 {right:.1f} ≤ {sw - 8}", right <= sw - 8)

print("\n== 3. 全九颗 × 三种屏宽都不越界")
for sw in (375, 393, 430):
    for i in range(9):
        x, _ = center(i, sw / 2)
        ck(f"{sw}pt {TITLES[i]} [{x - PILL_W/2:.1f}, {x + PILL_W/2:.1f}] 在屏内",
           x - PILL_W / 2 >= 8 and x + PILL_W / 2 <= sw - 8)

print("\n== 4. 同排相邻间隙 ≥ 12pt（不糊成一团）")
for row, idxs in (("下排", (0, 1, 2)), ("中排", (3, 4, 5)), ("最上排", (6, 7, 8))):
    for a, b in zip(idxs, idxs[1:]):
        gap = abs(center(b, 187.5)[0] - center(a, 187.5)[0]) - PILL_W
        ck(f"{row} {TITLES[a]}↔{TITLES[b]} 间隙 {gap:.0f}pt ≥ 12", gap >= 12)

print("\n== 5. 三排纵向间隙 ≥ 12pt")
ck(f"下↔中 {upperDY - lowerDY - PILL_H:.0f}pt ≥ 12", upperDY - lowerDY - PILL_H >= 12)
ck(f"中↔上 {topDY - upperDY - PILL_H:.0f}pt ≥ 12", topDY - upperDY - PILL_H >= 12)

print("\n== 6. 反向自证：两个历史事故形态都必须判红")
# 事故 1 形态：统一再减 1 → index 6 变 −2 列
x = 187.5 + (6 - 7 - 1) * columnDX
ck(f"事故1（统一 -1）会话纪要左缘 {x - PILL_W/2:.1f} < 8 → 会被判红", x - PILL_W / 2 < 8)
# 事故 2 形态：完全不减 → 下/中排最右列变 +2 列，430pt 屏飞出右边
x = 215.0 + (2 + 0) * columnDX
ck(f"事故2（不减）430pt 最右列右缘 {x + PILL_W/2:.1f} > 422 → 会被判红", x + PILL_W / 2 > 422)

print("\n" + ("✅ ALL PASS" if not fails else f"❌ FAILED {len(fails)}"))
sys.exit(1 if fails else 0)