#!/usr/bin/env python3
"""v4.0.58 腿/脚几何体检（数值真值表）

为什么单独一个脚本：腿能不能看见 = 纯几何（脚掌 y − 身体下缘 y），而本机是 Linux，
跑不了 SwiftUI（没有渲染器，画不出宠物）。所以把「脚到底露出来多少 pt」算出来钉住 ——
比「看着像有脚」可靠：谁改了身体半径 / 髋点 / 脚的大小，这里的数字立刻变红。

常量**从 PetPainter.swift 现读**（单一真源），本脚本不重抄一份：
重抄一份就会出现「源码改了、体检还全绿」的经典事故。

检查项：
  1. 三只形象的脚在体外可见高度（>0 且 ≥ 4pt@96pt —— 低于这个值等于没画）
  2. 迈步横向步幅（抬脚相外摆）≥ 4pt@96pt，否则「走路」看不出在动
  3. 全周期（含踢腿）脚掌不出画布、且两只脚永不重叠（重叠会糊成一只脚）
"""
import math
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "qingliao/Features/Chat/PetPainter.swift"
src = SRC.read_text(encoding="utf-8")

failures: list[str] = []
checks = 0


def check(label: str, ok: bool, detail: str = "") -> None:
    global checks
    checks += 1
    if ok:
        print(f"  ✅ {label}{('  ' + detail) if detail else ''}")
    else:
        print(f"  ❌ {label}{('  ' + detail) if detail else ''}")
        failures.append(label)


def grab(pattern: str, name: str) -> float:
    m = re.search(pattern, src)
    if not m:
        print(f"❌ 读不到常量「{name}」（源码改写法了？本体检必须同步，不许静默跳过）")
        sys.exit(1)
    return float(m.group(1))


# ── 从源码读常量 ──
hip_off = grab(r"let hipX: CGFloat = 0\.5 \+ side \* ([0-9.]+)", "hipX 偏移")
hip_y = grab(r"let hipY: CGFloat = ([0-9.]+)", "hipY")
rest_y = grab(r"let stanceY: CGFloat = ([0-9.]+)", "站定脚 y")
lift_h = grab(r"footY = stanceY - CGFloat\(liftPhase\) \* ([0-9.]+)", "抬脚高度")
kick_h = grab(r"footY = stanceY - CGFloat\(liftPhase\) \* [0-9.]+ - kickAmount \* ([0-9.]+)", "踢腿抬高")
lift_dx = grab(r"let dx = \(CGFloat\(liftPhase\) \* ([0-9.]+)", "抬脚外摆")
kick_dx = grab(r"let dx = \(CGFloat\(liftPhase\) \* [0-9.]+ \+ kickAmount \* ([0-9.]+)\)", "踢腿外展")
pend = grab(r"let pendulum = CGFloat\(swing\) \* ([0-9.]+)", "钟摆项")
bone_w = grab(r"let bone = rounded\(hipX - ([0-9.]+),", "腿骨半宽")

# 三只形象的半径（按 drawLiquid / drawBeast / drawRobot 顺序）与脚掌半宽/半高
radii = [float(x) for x in re.findall(r"shell\(&layer, s, radius: ([0-9.]+),", src)]
feet = {}
for style, pattern in (
    ("liquid", r"case \.liquid:\n            boneColor = Pal\.liquidDeep\n            foot = Path\(ellipseIn: r\(hipX, footY, ([0-9.]+), ([0-9.]+), s\)\)"),
    ("beast", r"case \.beast:\n            boneColor = Pal\.beastBottom\n            foot = Path\(ellipseIn: r\(hipX, footY, ([0-9.]+), ([0-9.]+), s\)\)"),
    ("robot", r"case \.robot:\n            boneColor = Pal\.botBottom\n            foot = rounded\(hipX - ([0-9.]+), footY - ([0-9.]+), ([0-9.]+), ([0-9.]+), [0-9.]+, s\)"),
):
    m = re.search(pattern, src)
    if not m:
        print(f"❌ 读不到 {style} 的脚掌几何")
        sys.exit(1)
    if style == "robot":
        half_w, half_h = float(m.group(3)) / 2, float(m.group(4)) / 2
    else:
        half_w, half_h = float(m.group(1)), float(m.group(2))
    feet[style] = (half_w, half_h)

if len(radii) != 3:
    print("❌ 读到的 shell() 半径不是 3 只（源码结构变了？）")
    sys.exit(1)

styles = ["liquid", "beast", "robot"]
print("腿/脚几何体检（@96pt = 聊天页页头尺寸；@60pt = 快捷菜单悬浮球那档；@24pt = 灵动岛）")
print(f"  常量：髋 x偏移={hip_off} 髋y={hip_y} 站定脚y={rest_y} 抬脚={lift_h}(横向 {lift_dx}) "
      f"踢腿抬高={kick_h}(外展 {kick_dx}) 钟摆={pend} 腿骨半宽={bone_w}")
print(f"  {'形象':<8}{'体半径':>7}{'下缘y':>8}{'脚掌可见':>10}{'步幅':>8}   各尺寸可见脚高(pt)")
sizes = [24, 60, 96]

for style, radius in zip(styles, radii):
    half_w, half_h = feet[style]
    body_bottom = 0.5 + radius
    foot_bottom = rest_y + half_h

    # 1. 脚掌露在体外的可见高度（整只脚都在下缘之下时 = 脚高）
    foot_top = rest_y - half_h
    visible = foot_bottom - max(body_bottom, foot_top)
    # 抬到最高时脚掌上移 → 仍以「站定」与「抬到最高」的较小者为准（走路全程都要看得见）
    visible_worst = (rest_y - lift_h + half_h) - body_bottom
    per_size = ", ".join(f"{s}pt:{visible_worst * s:4.1f}" for s in sizes)
    print(f"  {style:<8}{radius:>7.2f}{body_bottom:>8.2f}{visible:>10.3f}{lift_dx:>8.2f}   {per_size}")

    check(f"{style} 脚掌在体外可见（站定 ≥ 4pt@96）",
          visible_worst * 96 >= 4.0, f"{visible_worst * 96:.1f}pt@96")
    check(f"{style} 腿骨有一截露在体外（髋→脚之间有可见段）",
          foot_bottom - body_bottom > 0.03, f"{(foot_bottom - body_bottom):.3f}")
    check(f"{style} 迈步横向步幅 ≥ 4pt@96（否则看不出在迈步）",
          lift_dx * 96 >= 4.0, f"{lift_dx * 96:.1f}pt@96")

# 3. 全周期扫描：脚不出画布 + 两脚不重叠（含踢腿两种取值）
worst_gap = 9.9
min_x, max_x = 9.9, -9.9
max_bottom = -9.9
step_n = 200


def foot_box(side, t, kick_amount, kick_side, half_w, half_h):
    tt = t if side < 0 else t + 0.5
    ang = 2 * math.pi * tt
    lift = max(0.0, -math.sin(ang))
    swing = math.cos(ang)
    k = kick_amount if (kick_side < 0 and side < 0) or (kick_side > 0 and side > 0) else 0.0
    outward = -1.0 if side < 0 else 1.0
    dx = (lift * lift_dx + k * kick_dx) * outward
    dx += swing * pend * outward
    y = rest_y - lift * lift_h - k * kick_h
    x = 0.5 + side * hip_off + dx
    return x - half_w, x + half_w, y + half_h  # 左缘、右缘、下缘


for style, radius in zip(styles, radii):
    half_w, half_h = feet[style]
    for kick_amount, kick_side in ((0.0, -1.0), (1.0, -1.0), (1.0, 1.0)):
        t = 0.0
        while t < 1.0:
            lb, rb, lbottom = foot_box(-1, t, kick_amount, kick_side, half_w, half_h)
            rb2, lb2, rbottom = foot_box(1, t, kick_amount, kick_side, half_w, half_h)
            # 间隙 = 右脚左缘(rb2) − 左脚右缘(rb)；写 lb2(B右缘)−rb 会让 half_w 相消，
            # 变成只比两脚中心距 → 脚掌加宽到视觉糊成一只脚也判绿
            worst_gap = min(worst_gap, rb2 - rb)
            min_x = min(min_x, lb, rb2)
            max_x = max(max_x, rb, lb2)
            max_bottom = max(max_bottom, lbottom, rbottom)
            t += 1.0 / step_n

check("脚掌全程不出画布（左右缘 0.02~0.98、下缘 ≤0.995）",
      min_x >= 0.02 and max_x <= 0.98 and max_bottom <= 0.995,
      f"x∈[{min_x:.3f},{max_x:.3f}] 下缘 {max_bottom:.3f}")
check("两只脚全程不重叠（重叠会糊成一只脚，看着像少了一条腿）",
      worst_gap > 0.0, f"最小间隙 {worst_gap:.3f}（≈{worst_gap * 96:.1f}pt@96）")

print()
if failures:
    print(f"❌ v4.0.58 腿/脚几何体检：{len(failures)} 项不通过 —— {'; '.join(failures)}")
    sys.exit(1)
print(f"✅ v4.0.58 腿/脚几何体检 {checks} 项全通过")
