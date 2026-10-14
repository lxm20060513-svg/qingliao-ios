#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
弹窗 zoom 配对真值表 —— 钉死「卡片 → 详情弹窗」的源/目标必须成对。

事故（用户 2026-10-12 报障）：「看板页有些卡片的点击的弹窗位置没跟着卡片位置弹出，
而是统一居中弹出」。根因：那张卡只挂了**目标侧**
  navigationTransition(.zoom(sourceID: DashboardSheet.<case>.id, in: sheetZoomNS))
源侧没挂
  matchedTransitionSource(id: DashboardSheet.<case>.id, in: sheetZoomNS)
（当时报障的正是「连接器」卡；该卡已于 v4.0.109 随该栏目一并退役 —— 本表覆盖的是**全族**配对，
 不依赖任何单张卡在场，故只需把第 4 段自证锚点换到仍在的一对上。）


机制（为什么必须代码级钉）：zoom 转场靠「屏上有个视图挂着同名 id」定位放大起点。
源缺失、或源/目标 id 差一个字、或屏上没有源，**都不报编译错、不打运行日志**，
只是退化成普通弹出（从屏幕正中冒出来）—— 靠人眼回归必然漏。

本表钉三件事：
  ① 每个 zoom 目标都有源（缺源 = 用户报的那个症状）；
  ② 每个源都有目标（只加一头 = 白挂一眼看不出来）；
  ③ 源/目标用的是同一个命名空间（Namespace.ID 混用同样静默失效）。
外加一条反向自证：把源删掉必须判红。

范围：只扫 DashboardView.swift 里 DashboardSheet 系的弹窗（用户报障的那一族）。
其它处（LifeCardsSection 的 RSS 行大爆炸、ChatImageViewer 等）各有各的源/目标转发方式
（sourceID 走变量传参），不纳入本表，避免假阳性。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VIEW = os.path.join(ROOT, "qingliao", "Features", "Dashboard", "DashboardView.swift")

fails = []


def check(desc, ok, detail=""):
    tag = "✅" if ok else "❌"
    print("%s %s%s" % (tag, desc, (("  → " + detail) if (detail and not ok) else "")))
    if not ok:
        fails.append(desc)


def read_source():
    with open(VIEW, encoding="utf-8") as f:
        return f.read()


# 源侧：.matchedTransitionSource(id: DashboardSheet.<case>.id, in: <ns>)
SRC_RE = re.compile(
    r"matchedTransitionSource\(id:\s*DashboardSheet\.(\w+)\.id\s*,\s*in:\s*(\w+)\)"
)
# 目标侧：.navigationTransition(.zoom(sourceID: DashboardSheet.<case>.id, in: <ns>))
TGT_RE = re.compile(
    r"navigationTransition\(\.zoom\(sourceID:\s*DashboardSheet\.(\w+)\.id\s*,\s*in:\s*(\w+)\)\)"
)
# 弹窗入口：activeSheet = .<case>
ENTRY_RE = re.compile(r"activeSheet\s*=\s*\.(\w+)")


def pairs(text):
    srcs = [(m.group(1), m.group(2)) for m in SRC_RE.finditer(text)]
    tgts = [(m.group(1), m.group(2)) for m in TGT_RE.finditer(text)]
    return srcs, tgts


src = read_source()
srcs, tgts = pairs(src)
src_cases = {c for c, _ in srcs}
tgt_cases = {c for c, _ in tgts}
entry_cases = set(ENTRY_RE.findall(src))

print("== 0. 取证（把盘出来的数摆出来，不写死期望值）")
print("   弹窗入口 activeSheet = .X ：%d 个 → %s" % (len(entry_cases), ", ".join(sorted(entry_cases))))
print("   zoom 源  matchedTransitionSource：%d 处 → %s" % (len(srcs), ", ".join(sorted(src_cases))))
print("   zoom 目标 navigationTransition  ：%d 处 → %s" % (len(tgts), ", ".join(sorted(tgt_cases))))
check("源、目标都取到了（正则没被改版冲掉）", bool(srcs) and bool(tgts))

print("")
print("== 1. 每个 zoom 目标都有源（缺源 = 从屏幕正中冒出，静默失效）")
missing_src = sorted(tgt_cases - src_cases)
check(
    "看板 %d 个 zoom 目标全部有对应源" % len(tgt_cases),
    not missing_src,
    "缺源: " + ", ".join(missing_src) + "（补 matchedTransitionSource(id: DashboardSheet.<case>.id, in: sheetZoomNS)）",
)

print("")
print("== 2. 每个源都有目标（只加一头看不出来，反向也钉）")
missing_tgt = sorted(src_cases - tgt_cases)
check(
    "看板 %d 个 zoom 源全部有对应目标" % len(src_cases),
    not missing_tgt,
    "只挂了源没挂目标: " + ", ".join(missing_tgt),
)

print("")
print("== 3. 源 / 目标共用同一命名空间（混用 Namespace.ID 同样静默失效）")
namespaces = {ns for _, ns in srcs} | {ns for _, ns in tgts}
check(
    "源与目标都在同一个 sheetZoomNS 里",
    namespaces == {"sheetZoomNS"},
    "出现的命名空间: " + ", ".join(sorted(namespaces)),
)

print("")
print("== 3b. 看板危险动作确认 —— 必须从触发卡片弹出（锚定浮层），不许回退系统弹窗")
# 由头：用户 2026-10-12「看板页有些卡片的点击的弹窗位置没跟着卡片位置弹出，而是统一居中弹出」，
# 举例「撤防卡片」。根因 = 走 confirmationDialog，iPhone 上系统**固定从屏幕底部升起**，锚不到卡片。
# 三处已改锚定浮层（安防卡 / 危险场景卡 / token 用量卡），这里钉死不许回退。
def live_dialogs(text):
    """只看**真代码行**里的 confirmationDialog —— 注释里提到它（「原 .confirmationDialog(…) 已删」）不算。"""
    return [l for l in text.splitlines()
            if "confirmationDialog(" in l and not l.strip().startswith("//")]


check("看板已无「确认变更安防状态？」系统弹窗",
      not [l for l in live_dialogs(src) if '确认变更安防状态？' in l])
check("看板已无「确认执行场景？」系统弹窗",
      not [l for l in live_dialogs(src) if '确认执行场景？' in l])
check("安防确认浮层锚到安防卡（armAnchor）", "anchorFrame: armAnchor" in src)
check("场景确认浮层锚到被点那张卡（sceneFrames[s.id]）", "anchorFrame: sceneFrames[s.id] ?? .zero" in src)
check("用量卡重置确认浮层锚到用量卡（usageResetAnchor）", "anchorFrame: usageResetAnchor" in src)
check("安防卡在采锚点（onGeometryChange → armAnchor）", "armAnchor = $0" in src)
check("场景卡在采锚点（按 id 存，否则 ForEach 里只剩最后一张）", "sceneFrames[s.id] = rect" in src)

USAGE = os.path.join(ROOT, "qingliao", "Features", "Dashboard", "UsageCard.swift")
usage_src = open(USAGE, encoding="utf-8").read()
check("用量卡不再自己弹系统弹窗（浮层必须归宿主页最外层，挂卡片上会被后续卡片盖住）",
      not live_dialogs(usage_src), "UsageCard.swift 里又出现了 confirmationDialog")
check("用量卡把自身 frame 报给宿主", "onReset?(cardFrame)" in usage_src and "cardFrame = $0" in usage_src)

AMO = os.path.join(ROOT, "qingliao", "Features", "Chat", "AnchorMenuOverlay.swift")
amo_src = open(AMO, encoding="utf-8").read()
check("锚定浮层有 message 档（危险动作要「明示后果」）",
      "var message: String" in amo_src and "if !message.isEmpty" in amo_src,
      "AnchorMenuOverlay 的说明文字档被删了，确认框会丢掉后果提示")

print("")
print("== 3c. 设置页 / 生活页危险动作确认 —— 同样必须从触发元素弹出（不许回退系统弹窗）")
# 由头：同一批（用户 2026-10-12「1，顺便把所有卡片都排一遍，有同样问题的都修改」）——
# 全仓 confirmationDialog 共 35 处，除看板 3 处（见 3b）外，以下 11 处同样锚不到触发元素：
#   生活页 3：待办「清理已完成」「清空全部」、长期目标「清空全部」
#   设置页 8：文件删除 / 执行历史清空 / MCP 服务删除 / 知识库文档删除 / 记忆删除 /
#             退出登录 / 网盘解绑 / 邮箱删除
# 生活页三处必须走**页级单例 + 页级宿主** —— 栏目自己挂浮层会被后面的 Section 盖住
#（v4.0.77 教训：`.overlay` 挂在被同级兄弟覆盖的区域里等于没挂）。
FEAT = os.path.join(ROOT, "qingliao", "Features")


def feat(*parts):
    p = os.path.join(FEAT, *parts)
    with open(p, encoding="utf-8") as f:
        return f.read()


SETTINGS_FILES = [
    (("Settings", "SettingsData.swift"), "文件删除 / 执行历史清空"),
    (("Settings", "SettingsAccess.swift"), "MCP 服务删除 / 知识库文档删除"),
    (("Settings", "SettingsAgent.swift"), "记忆删除"),
    (("Settings", "SettingsCore.swift"), "退出登录"),
    (("Settings", "CloudDriveSettingsSheet.swift"), "网盘解绑"),
    (("Settings", "MailSettingsSheet.swift"), "邮箱删除"),
]
for parts, what in SETTINGS_FILES:
    name = parts[-1]
    t = feat(*parts)
    live = live_dialogs(t)
    check("%s：已无系统确认弹窗（%s）" % (name, what), not live,
          "仍有: " + " | ".join(l.strip()[:60] for l in live))
    check("%s：锚定浮层在场" % name, "AnchorMenuOverlay(" in t)
    check("%s：在采锚点（onGeometryChange）" % name, "onGeometryChange" in t)

todo_src = feat("Life", "TodoSection.swift")
goals_src = feat("Life", "GoalsSection.swift")
base_src = feat("Life", "LifeGlassPresenterBase.swift")
check("待办：已无「清理已完成 / 清空全部」系统弹窗",
      not [l for l in live_dialogs(todo_src) if "清理已完成" in l or "清空全部" in l],
      " | ".join(l.strip()[:60] for l in live_dialogs(todo_src)))
check("长期目标：已无「清空全部目标」系统弹窗",
      not [l for l in live_dialogs(goals_src) if "清空全部目标" in l],
      " | ".join(l.strip()[:60] for l in live_dialogs(goals_src)))
check("页级 Presenter 基类提供 confirmKind 档（栏目浮层会被后一个 Section 盖住 → 必须走页级宿主）",
      "var confirmKind: LifeConfirmKind?" in base_src and "var confirmAnchor: CGRect" in base_src,
      "LifeGlassPresenterBase 的确认浮层档被删了")
check("待办页级宿主渲染确认浮层（挂在 ZStack 最上层）",
      "AnchorMenuOverlay(" in todo_src and "glass.confirmKind" in todo_src)
check("长期目标页级宿主渲染确认浮层（挂在 ZStack 最上层）",
      "AnchorMenuOverlay(" in goals_src and "glass.confirmKind" in goals_src)
check("待办展开区把按钮条 frame 报给宿主（onClearCompleted: (CGRect) -> Void）",
      "onClearCompleted: (CGRect) -> Void" in todo_src and "clearButtonsFrame" in todo_src)
check("目标展开区把「清空」frame 报给宿主（onClearAll: (CGRect) -> Void）",
      "onClearAll: (CGRect) -> Void" in goals_src and "clearButtonFrame" in goals_src)

print("")
print("== 4. 反向自证（把一对里的源 id 改错 → 第 1 段必须判红）")
# v4.0.109：原锚点（连接器卡的源）随「连接器」栏目退役 → 改挂天气徽章那条源
#   （唯一一条 weather 源，目标在 sheetContent 的 .weather 分支，成对在场）。
#   ⚠️ 锚点必须挑「源与目标都还在」的一对：若挑只剩目标的那对，变异后 m_missing 恒为空 → 自证假绿。
INJECT = ".matchedTransitionSource(id: DashboardSheet.weather.id, in: sheetZoomNS)"
if INJECT not in src:
    print("   ⚠️ 未能注入（天气徽章源的源码形态变了，去更新本段自证片段）")
    check("反向自证片段仍能命中源码", False, "源码形态变了，护栏本身要跟着改")
else:
    mutated = src.replace(INJECT, ".matchedTransitionSource(id: DashboardSheet.licensePlatePanel.id, in: sheetZoomNS)")
    m_srcs, m_tgts = pairs(mutated)
    m_missing = {c for c, _ in m_tgts} - {c for c, _ in m_srcs}
    check(
        "🚫 反向：源 id 与目标不一致时被第 1 段判红",
        "weather" in m_missing,
        "护栏没抓到「源/目标 id 不一致」这个静默失效形态",
    )
check("反向自证未改动源码（纯字符串比对，不写文件）", read_source() == src)

print("")
if fails:
    print("❌ FAILED %d:" % len(fails))
    for f in fails:
        print("   - " + f)
    sys.exit(1)
print("✅ ALL PASS（看板卡片 → 详情弹窗的 zoom 源/目标成对：缺一头就会被这条挡下）")
