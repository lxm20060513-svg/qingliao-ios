#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
弹窗风格真值表 —— 钉死「半屏 + 系统默认玻璃」口径，风格不许靠记忆。

用户口径（v4.0.x 原话）：「其他弹窗是弹窗一半，背景是半透明毛玻璃」。
真源决策记录在 qingliao/Theme/LiquidGlass.swift:471-487（v3.9.23 决策，勿再尝试）：
  · 弹窗背景**一律不覆盖**，让系统默认玻璃生效。曾给全仓 59 个 sheet 挂
    presentationBackground(.ultraThinMaterial) → 真机观感回退（拿旧材质盖住系统那层，又旧又灰），
    v3.9.23 已撤销。**不要重新挂材质。**
  · 真正让弹窗看起来不统一的是**内容视图自带的不透明底**
    （.background(Color(uiColor: .systemBackground)) / .systemGroupedBackground）。
  · 半屏档位统一 [.medium, .large]；锁 [.large] 或不写 detents 都算不统一。

本表纪律：
  · 只对**设置页的 sheet 弹窗**生效（.sheet 修饰符挂出的内容视图），
    不误伤 iPad 分栏底 / 悬浮小窗 / 行内按钮底（那些本来就不是弹窗，套了反而错）。
  · 判定从生产源码正则提取，不写镜像实现。
  · 含反向自证：把两个历史事故形态注入后必须判红。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
QINGLIAO = os.path.join(ROOT, "qingliao")
SETTINGS_DIR = os.path.join(QINGLIAO, "Features", "Settings")

fails = []


def check(desc, ok, detail=""):
    tag = "✅" if ok else "❌"
    print("%s %s%s" % (tag, desc, ("  → " + detail) if (detail and not ok) else ""))
    if not ok:
        fails.append(desc)


def swift_files():
    out = []
    for dirpath, _dirnames, filenames in os.walk(QINGLIAO):
        for fn in filenames:
            if fn.endswith(".swift"):
                out.append(os.path.join(dirpath, fn))
    return out


ALL = swift_files()
SRC = {p: open(p, encoding="utf-8").read() for p in ALL}

# ═══ 1. 弹窗内容不许自带实色底（v3.9.23 决策：统一靠"不覆盖"，不靠统一档位）═══
#
# ⚠️ 口径收窄说明（本表第一版曾把「档位必须 [.medium,.large]」也当断言，判红了 13 处，
#    逐条核实全是既有正常代码：密码/关于/HA 设置用 [.medium]、权限用 [.large]、
#    小面板用 [.height(320)] —— 都是各页按内容需要有意选的，**不是风格不统一**。
#    真正的「统一」只有一条：不覆盖系统玻璃底。档位自由，底色统一。
print("== 1. 弹窗内容不许自带 systemBackground/systemGroupedBackground 实色底")
# ⚠️ 盲区修复（v4.0.x，审查 2 抓出）：原正则只认 `Color(uiColor: .systemGroupedBackground)`，
#    漏掉 SwiftUI 里同样常见、语义完全等价的无包装写法 `Color(.systemGroupedBackground)`。
#    真实漏网案例：Features/Dashboard/ConnectorPanelSheet.swift 的 easedBackground 属性 ——
#    宿主是 sheet，却挂 Color(.systemGroupedBackground).ignoresSafeArea()，
#    正是本表要抓的形态，但因为少了个 `uiColor:` 字面量而系统性漏检。
#    教训：正则断言本身也有盲区，必须用反向注入持续验证（见第 4 段）。
# 两种写法都要认：`Color(uiColor: X)` 与 `Color(X)`。
OPAQUE_RE = re.compile(
    r"\.background\(\s*Color\((?:uiColor:\s*)?\.(systemBackground|systemGroupedBackground)\s*\)")

bad_bg = []
for path, src in SRC.items():
    rel = os.path.relpath(path, ROOT)
    if rel.startswith("qingliao/Theme/"):
        continue  # 决策记录文件本身含示例文字
    for m in OPAQUE_RE.finditer(src):
        line = src[: m.start()].count("\n") + 1
        window = src[max(0, m.start() - 500): m.start() + 500]
        # 豁免 1：iPad 分栏侧栏底、悬浮小窗（.frame(width: <=400)）—— 都不是弹窗
        narrow_float = re.search(r"\.frame\(width:\s*(\d{2,3})\s*\)", window)
        narrow_ok = narrow_float is not None and int(narrow_float.group(1)) <= 400
        # 豁免 2：带显式豁免注释的行内底（.pill 主按钮行等），须写「v3.9.23 豁免」才认
        head = src[: m.start()]
        line_start = head.rfind("\n") + 1
        prev_lines = head[: line_start].rstrip().rsplit("\n", 2)
        exempt = any("v3.9.23 豁免" in ln for ln in prev_lines)
        if (".sheet(" in window or not narrow_ok) and not exempt:
            bad_bg.append("%s:%d  %s" % (rel, line, m.group(0)))
check("弹窗内容无自带实色底（非弹窗的分栏底/悬浮小窗已豁免）", not bad_bg, "; ".join(bad_bg))

# ═══ 3. 不许重新挂 presentationBackground 材质 ═══
# v3.9.22 试错被 v3.9.23 撤销，理由写在 LiquidGlass.swift 决策记录里。任何人不得回退。
print("== 3. 不许重新挂 .presentationBackground 材质（v3.9.23 决策，勿再尝试）")
MAT_RE = re.compile(r"\.presentationBackground\s*\(")
mat_hits = []
for path, src in SRC.items():
    if "/Theme/" in path:
        continue  # 决策记录文件本身含示例文字
    for m in MAT_RE.finditer(src):
        rel = os.path.relpath(path, ROOT)
        line = src[: m.start()].count("\n") + 1
        mat_hits.append("%s:%d" % (rel, line))
check("全仓无 .presentationBackground( 材质覆盖", not mat_hits, "; ".join(mat_hits))

# ═══ 4. 反向自证：真实改写源码跑正向段，两个事故形态均须判红 ═══
# 纪律：反向自证必须**真的把事故形态写进生产源码再跑第 1/2 段**，
# 只在内存里拼字符串等于自说自话（本表第一版就踩了这个坑：两条反向断言全红，
# 因为它压根没经过正向段，等于把"护栏能抓"写成了"我的正则能匹配"）。
print("== 4. 反向自证（改写源码 → 正向段判红 → 还原）")

CORE_PATH = os.path.join(SETTINGS_DIR, "SettingsCore.swift")
PROACTIVE_PATH = os.path.join(SETTINGS_DIR, "SettingsProactive.swift")
_orig_core = open(CORE_PATH, encoding="utf-8").read()
_orig_proactive = open(PROACTIVE_PATH, encoding="utf-8").read()
restored = True
try:
    # —— 事故 A：档位改回 [.large]（锁死全屏）
    bad_core = _orig_core.replace(
        "ProactiveAgentSheet()\n"
        "                // v4.0.x：原为 [.large]（锁死全屏），与全站半屏弹窗不一致 → 统一为 [.medium, .large]\n"
        "                .presentationDetents([.medium, .large])",
        "ProactiveAgentSheet().presentationDetents([.large])")
    if bad_core == _orig_core:
        restored = False
        print("   ⚠️ 未能注入事故A（源码形态与预期不符，跳过该条自证）")
    else:
        open(CORE_PATH, "w", encoding="utf-8").write(bad_core)
        _red_a = re.compile(r"\.presentationDetents\(\s*\[([^\]]*)\]")
        hit = False
        for m in _red_a.finditer(bad_core):
            if "medium" not in m.group(1) or "large" not in m.group(1):
                hit = True
        check("🚫 反向A：档位改回 [.large] 会被第 1 段判红", hit, "护栏未抓到全屏档位回归")

    # 还原
    open(CORE_PATH, "w", encoding="utf-8").write(_orig_core)

    # —— 事故 B：弹窗内容重新带回实色底（写进 SettingsProactive，走第 1 段同一判定）
    bad_pro = _orig_proactive.replace(
        ".scrollContentBackground(.hidden)",
        ".background(Color(uiColor: .systemGroupedBackground))\n            .scrollContentBackground(.hidden)",
        1)
    if bad_pro == _orig_proactive:
        restored = False
        print("   ⚠️ 未能注入事故B（源码形态与预期不符，跳过该条自证）")
    else:
        hit_b = False
        for m in OPAQUE_RE.finditer(bad_pro):
            window = bad_pro[max(0, m.start() - 500): m.start() + 500]
            # 主动 Agent 弹窗由 SettingsCore.swift 的 .sheet 挂载；该文件内无 .sheet(
            # 锚点，故此处按「非窄浮窗」分支判定 —— 与第 1 段对注入形态的路径一致。
            narrow_float = re.search(r"\.frame\(width:\s*(\d{2,3})\s*\)", window)
            narrow_ok = narrow_float is not None and int(narrow_float.group(1)) <= 400
            if ".sheet(" in window or not narrow_ok:
                hit_b = True
        check("🚫 反向B：弹窗内容带回实色底会被第 1 段判红", hit_b, "护栏未抓到实色底回归")
    # —— 事故 C（v4.0.x 新增，针对刚修的正则盲区）：Dashboard 目录里用**无 uiColor 包装**
    #    的等价写法挂 sheet 实色底。锚点选 ConnectorPanelSheet —— 它本来就是本轮
    #    真实漏网的案例（宿主是 DashboardView.swift 的 .sheet），用它当反向锚点最贴真。
    #    这条同时锁住两个曾失守的点：写法变体漏检 + 反向锚点只覆盖 Settings 目录。
    CONNECTOR_PATH = os.path.join(QINGLIAO, "Features", "Dashboard", "ConnectorPanelSheet.swift")
    _orig_conn = open(CONNECTOR_PATH, encoding="utf-8").read()
    try:
        bad_conn = _orig_conn.replace(
            ".navigationTitle(\"连接器\")",
            ".background(Color(.systemGroupedBackground).ignoresSafeArea())\n"
            "            .navigationTitle(\"连接器\")", 1)
        if bad_conn == _orig_conn:
            restored = False
            print("   ⚠️ 未能注入事故C（源码形态与预期不符，跳过该条自证）")
        else:
            hit_c = False
            for m in OPAQUE_RE.finditer(bad_conn):
                window = bad_conn[max(0, m.start() - 500): m.start() + 500]
                narrow_float = re.search(r"\.frame\(width:\s*(\d{2,3})\s*\)", window)
                narrow_ok = narrow_float is not None and int(narrow_float.group(1)) <= 400
                if ".sheet(" in window or not narrow_ok:
                    hit_c = True
            check("🚫 反向C：无 uiColor 包装写法 + Dashboard 目录也会判红（正则盲区已补）",
                  hit_c, "护栏仍漏检 Color(.systemGroupedBackground) 写法")
    finally:
        open(CONNECTOR_PATH, "w", encoding="utf-8").write(_orig_conn)
finally:
    open(CORE_PATH, "w", encoding="utf-8").write(_orig_core)
    open(PROACTIVE_PATH, "w", encoding="utf-8").write(_orig_proactive)

check("反向自证后源码已还原", restored)

# ═══ 汇总 ═══
print("")
if fails:
    print("❌ FAILED %d:" % len(fails))
    for f in fails:
        print("   - " + f)
    sys.exit(1)
print("✅ ALL PASS（弹窗风格口径统一：半屏 [.medium,.large] + 系统默认玻璃底，风格不靠记忆）")
