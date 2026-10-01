#!/usr/bin/env python3
# 接入中心一页 真值表 v4.0.x（七项待办第 3 项）
#
# 为什么这一项要单独一张表：第 3 项的**唯一真风险是破坏用户已有的邮件/网盘配置**。
# 面板新加的「允许 AI 直接发信」开关走 POST /api/mail/accounts，而后端 save_account
# 会走 normalize() —— **没传的字段一律写成空值**（nickname→""、imap_security→""、
# default→false）。也就是说只 POST {"id":..., "allow_direct_send":true}
# 会静默把用户的邮箱昵称/安全协议/默认标记全清空 —— 真事故，且用户不会立刻发现。
# 所以这里钉死三件事：
#   ① 开关必须带齐 _public() 的全字段（读改写，不是局部 PATCH）
#   ② 状态口径不许凭空乐观（读不到就说"状态未知"，不许显示"已接入"）
#   ③ 网盘/日历/提醒不许假造 enable 位（后端只有 add/remove）
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
QINGLIAO = os.environ.get("QL_IOS_ROOT") or os.path.normpath(
    os.path.join(_HERE, "..", "..")) + "/qingliao"
PANEL = os.path.join(QINGLIAO, "Features", "Dashboard", "ConnectorPanelSheet.swift")
DASH = os.path.join(QINGLIAO, "Features", "Dashboard", "DashboardView.swift")
MAIL = os.path.join(QINGLIAO, "Features", "Settings", "MailSettingsSheet.swift")
CLOUD = os.path.join(QINGLIAO, "Features", "Settings", "CloudDriveSettingsSheet.swift")
PERM = os.path.join(QINGLIAO, "Core", "AppPermissionKit.swift")
# 设置页那两个 sheet 宿主在 SettingsCore.swift，不在 DashboardView —— 别只在 DashboardView 里数
SETTINGS = os.path.join(QINGLIAO, "Features", "Settings", "SettingsCore.swift")

P = F = 0


def check(name, cond, detail=""):
    global P, F
    if cond:
        P += 1
        print(f"  ✅ {name}" + (f"  ← {detail}" if detail else ""))
    else:
        F += 1
        print(f"  ❌ {name}" + (f"  ← {detail}" if detail else ""))


def strip_comments(src):
    """去掉 // 行注释与 /* */ 块注释 —— 注释里出现"不能只 POST"不算实现。"""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return "\n".join(re.sub(r"//.*$", "", ln) for ln in src.splitlines())


def src(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def body_of(text, anchor):
    """取 anchor 所在的大括号块（粗略但够用：数大括号配平）。"""
    i = text.find(anchor)
    if i < 0:
        return ""
    j = text.find("{", i)
    depth, k = 0, j
    while k < len(text):
        if text[k] == "{":
            depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0:
                return text[j:k + 1]
        k += 1
    return ""


for p in (PANEL, DASH, MAIL, CLOUD, PERM, SETTINGS):
    check(f"源可读 {os.path.basename(p)}", os.path.exists(p))

panelRaw = src(PANEL)
panel = strip_comments(panelRaw)
dash = strip_comments(src(DASH))
settings = strip_comments(src(SETTINGS))
mail = strip_comments(src(MAIL))

# ─────── ① 读改写：开关必须带齐全字段（防 normalize() 清空账号）───────
print("── ① 邮件开关走读改写，绝不局部 PATCH（真事故防线）")
setDirect = body_of(panel, "private func setDirectSend(")
check("开关落在独立函数 setDirectSend 里", bool(setDirect))
# 后端 _public() 暴露的字段全集（缺一个就会被 normalize 写成空/默认值）
must_carry = ["id", "email", "nickname", "imap_host", "imap_port", "imap_security",
              "smtp_host", "smtp_port", "smtp_security", "allow_direct_send", "default"]
missing = [k for k in must_carry if f'"{k}"' not in setDirect]
check("POST 体带齐 _public() 全字段", not missing,
      "缺 " + ",".join(missing) if missing else f"{len(must_carry)} 个字段齐全")
check("回写后重新拉取列表（不靠本地乐观更新）", "loadMail()" in setDirect)
check("必须查 ok（后端异常包在 200 里）", re.search(r'\["ok"\].*as\? Bool', setDirect) is not None)
# 危险写法：POST 只带 id + allow_direct_send
bad_patch = re.search(r'"/api/mail/accounts".{0,200}allow_direct_send', setDirect, re.S) and \
    not all(f'"{k}"' in setDirect for k in must_carry)
check("不存在『只 POST 两个字段』的破坏性写法", not bad_patch)
check("secret 不在回写体里（留空=不修改，符合后端语义）",
      '"secret"' not in setDirect,
      "后端 secret 留空即沿用旧密文，传空串也安全但不写更清楚")

# ─────── ② 状态口径不许凭空乐观 ───────
print("── ② 状态口径（读不到就说读不到）")
check("邮件：加载中/未知/未接入三态齐全",
      all(k in panel for k in ["加载中…", "状态未知（点开查看）", "未接入 · 点开添加"]))
check("邮件错误态不显示成已接入",
      "读不到邮件账号状态" in panel and panel.find("mailError") < len(panel))
check("网盘：加载中/未知/未接入三态齐全",
      all(k in panel for k in ["加载中…", "状态未知（点开查看）", "未接入 · 点开添加"]))
check("网盘区分异常盘（status != ready）", "isReady" in panel and "异常" in panel)
check("MCP 原三态未被改坏",
      all(k in panel for k in ["未配置 · 点开添加", "已连接"]))
# mailLoading/mailError 为真时不得走「已接入 N 个」分支
mailText = body_of(panel, "private var mailStatusText")
check("mailStatusText 先判 loading 再判 error 最后才判数据",
      mailText.find("mailLoading") < mailText.find("mailError") < mailText.find("mailAccounts.isEmpty"),
      "顺序错了会在加载中闪出旧数据")

# ─────── ③ 不假造 enable 位 ───────
print("── ③ 网盘/日历口径与后端能力对齐")
check("网盘只给状态+入口（后端只有 add/remove，无 enable 位）",
      "onOpenCloudDrive" in panel and panel.count("drives") > 0)
check("网盘接口走 /api/agent/clouddrive 别名（lucky 白名单口径）",
      "/api/agent/clouddrive/drives" in panel and "/api/clouddrive/drives" not in panel)
check("日历开关走 AppPermissionKit 双闸门（不是自造 UserDefaults key）",
      "AppPermissionKit.setAIControlEnabled" in panel)
check("授权未过就把开关弹回去（不留假绿）",
      re.search(r"guard st == \.granted else \{\s*\n\s*ai\.wrappedValue = false", panel) is not None)
check("不替用户偷改 AI 总闸（总闸=另一个决定）",
      "aiControlMasterEnabled = " not in panel and "setAIControlEnabled" in panel)
check("请求授权是 MainActor 路径（AppPermissionKit.request 内部已 @MainActor）",
      "AppPermissionKit.request(" in panel)

# ─────── ④ 宿主接线：入口齐全 + 复用同一份 sheet（不新做一套 UI）───────
print("── ④ 宿主接线")
for cb in ["onOpenMail", "onOpenCloudDrive"]:
    check(f"面板暴露回调 {cb}", f"var {cb}: () -> Void" in panel)
    check(f"DashboardView 注入 {cb}", f"{cb}:" in dash)
check("AfterPanelSheet 新增 mail/cloudDrive 两个 case",
      "case mcp, lifeCards, mail, cloudDrive" in dash)
for c in ["case .mail:", "case .cloudDrive:"]:
    check(f"AfterPanelSheet 宿主渲染 {c}", c in dash)
# 复用同一份 sheet：设置页在 SettingsCore.swift 弹一次、接入中心在 DashboardView 弹一次，
# 两处必须是**同一个** MailSettingsSheet()/CloudDriveSettingsSheet()，不是各造一套。
mailRefs = dash.count("MailSettingsSheet()") + settings.count("MailSettingsSheet()")
check("邮件直达复用设置页那同一份 MailSettingsSheet（无二套 UI）",
      mailRefs >= 2 and "ConnectorMailSheet" not in dash + panel,
      f"全仓宿主 {mailRefs} 处（设置页 1 + 接入中心 1）")
driveRefs = dash.count("CloudDriveSettingsSheet()") + settings.count("CloudDriveSettingsSheet()")
check("网盘直达复用设置页那同一份 CloudDriveSettingsSheet（无二套 UI）",
      driveRefs >= 2 and "ConnectorDriveSheet" not in dash + panel,
      f"全仓宿主 {driveRefs} 处")
check("面板关闭后再弹设置页（防 sheet 叠 sheet，老口径不变）",
      "pendingSheetAfterPanel" in dash and "pendingSheetAfterPanel = .mail" in dash)

# ─────── ⑤ 弹窗风格与并行加载 ───────
print("── ⑤ 风格与性能口径")
check("未挂 .presentationBackground 实色底（v3.9.23 决策）",
      "presentationBackground" not in panel and "easedBackground" not in panel)
check("卡片沿用既有 connectorCard 样式（不新造视觉）",
      panel.count("connectorCard(") >= 7,
      f"{panel.count('connectorCard(')} 处（6 状态卡 + 1 样式定义）")
check("六类接入全部有卡：邮件/网盘/日历/MCP/智能家居/生活卡片",
      all(k in panel for k in ['title: "邮件接入"', 'title: "网盘接入"',
                                'title: "日历与提醒"', 'title: "MCP 工具服务"',
                                'title: "智能家居"', 'title: "生活卡片"']))
check("四路并发加载（串行会白等 4 个 RTT）",
      panel.count("async let") >= 3 and "loadAll()" in panel)
check("开关用 qingliaoSwitch 统一外观（不写裸 Toggle）",
      panel.count("qingliaoSwitch") >= 2 and "Toggle(" in panel,
      f"{panel.count('qingliaoSwitch')} 处：邮件开关 1 + 日历/提醒共用 gateToggle 1")

print(f"\n通过 {P} / 失败 {F}")
sys.exit(0 if F == 0 else 1)
