#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
固定会话真值表 —— 钉死「两个固定会话」的六条口径，勿靠记忆。

背景（用户实测 v4.0.x）：主动 Agent（设置页有开关）的消息会**串进用户正在聊的正常会话**。
根因（代码取证，非猜测）：
  · 后端 `proactive_agent.deliver()` → `inbox_api.push(task_type="agent")`，
    而 push 的接口**没有 session_id 参数** → 消息只进 inbox 推送池；
  · App 侧 `InboxStore.consumeOne` 消费后执行 `chat.append(amsg)`，
    注入的是**当前会话** → 用户当时开着哪个会话，主动消息就落进哪个。
  唯一防护是 `InboxStore` 里 `chat.isDeliverySession` 那道闸门，它只是**排除**投递壳，
  并不给主动消息任何归属会话 —— 所以「串进正常会话」是必然。

v4.0.x 修法：给主动 Agent 一个**自己的固定会话** `qingliao_proactive`（「轻聊主动」）。
与投递壳「轻聊投递」的三点区别（本表逐条钉死，混了就是 bug）：
  ① 投递壳**只装不答**；主动会话**人机对话**，用户在里面正常回复、走 stream。
  ② 投递壳输入栏只读（ChatView `chat.isDeliverySession`）；主动会话**不设**这道闸门。
  ③ 投递壳内容以客户端为准；主动会话内容**以 NAS 为准**（后端 _CLIENT_WINS_IDS 不含它）。
  两者共同点：**都不可删除、标题锁定**。

本表只读生产源码 + 后端源码文本，不写镜像实现；含反向自证。
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
Q = os.path.join(ROOT, "qingliao")

fails = []


def check(desc, ok, detail=""):
    print("%s %s%s" % ("✅" if ok else "❌", desc, ("  → " + detail) if (detail and not ok) else ""))
    if not ok:
        fails.append(desc)


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def all_swift():
    out = []
    for dp, _dn, fns in os.walk(Q):
        for fn in fns:
            if fn.endswith(".swift"):
                out.append(os.path.join(dp, fn))
    return {p: read(p) for p in out}


SRC = all_swift()
def find(name):
    for p, s in SRC.items():
        if p.endswith("/" + name):
            return p, s
    return None, ""


# ═══ 1. 常量真源：id 只有一个定义处，且与后端一致 ═══
print("== 1. 固定会话 id 常量（唯一真源）")
p_chat, s_chat = find("ChatStore.swift")
check("ChatStore 定义 proactiveSessionId", "static let proactiveSessionId" in s_chat)
check("proactiveSessionId 值为 qingliao_proactive",
      'proactiveSessionId = "qingliao_proactive"' in s_chat)
check("deliverySessionId 仍在（同族）", 'deliverySessionId = "qingliao_delivery"' in s_chat)
# 全仓不得出现第二个字面量定义（防止某处硬编码 id 漂移）
dup = [os.path.relpath(p, ROOT) for p, s in SRC.items()
       if 'proactiveSessionId' in s and 'static let proactiveSessionId' not in s
       and '"qingliao_proactive"' in s]
check("id 字面量无第二处硬编码（只经常量引用）", not dup, "; ".join(dup))

# ═══ 2. 主动会话可回复：不套投递壳只读闸门 ═══
print("== 2. 主动会话可回复（区分点①：不套投递壳只读闸门）")
check("ChatStore 提供 isProactiveSession", "var isProactiveSession" in s_chat)
check("isProactiveSession 按 proactiveSessionId 判定",
      "sessionId == Self.proactiveSessionId" in s_chat)
check("有 isFixedSession 合并判定（都不可删）", "var isFixedSession" in s_chat)
p_view, s_view = find("ChatView.swift")
# 输入栏只读闸门必须**只**判投递壳（不能改成 isFixedSession，否则主动会话也不能回复）
ro_guard = re.search(r"if chat\.is(FixedSession|ProactiveSession)\s*\{", s_view)
check("ChatView 输入栏只读闸门仍只判 isDeliverySession（主动会话可回复）",
      ro_guard is None, "发现改成 %s" % (ro_guard.group(0) if ro_guard else ""))
check("ChatView 存在投递会话只读提示", "不支持回复" in s_view)

# ═══ 3. 主动消息注入固定会话，不再注入当前会话 ═══
print("== 3. 区分点③：agent 消息注入目标固定（核心修复）")
p_inbox, s_inbox = find("InboxStore.swift")
check("InboxStore 有 injectToProactiveSession", "func injectToProactiveSession" in s_inbox)
# 关键：agent 分支里**不得**再出现裸 chat.append —— 那就是「串进当前会话」本体
agent_blk = None
for m in re.finditer(r'if taskType == "agent"\s*\{', s_inbox):
    seg = s_inbox[m.start(): m.start() + 2000]
    if "amsg" in seg:
        agent_blk = seg
        break
check("能定位 agent 注入分支", agent_blk is not None)
if agent_blk:
    head = agent_blk[: agent_blk.find("return\n        }") + 20]
    check("agent 分支调用 injectToProactiveSession", "injectToProactiveSession(amsg)" in head)
    check("🚫 agent 分支不再裸 chat.append（否则又串进当前会话）",
          "chat.append(amsg)" not in head,
          "发现裸 append：%r" % head[:200])
    check("通知跳转指向主动会话",
          "sessionId: ChatStore.proactiveSessionId" in head)
# 注入函数本体：只在正停在主动会话时才碰内存
inj = re.search(r"private func injectToProactiveSession.*?\n    \}", s_inbox, re.DOTALL)
check("能定位 injectToProactiveSession 函数体", inj is not None)
if inj:
    body = inj.group(0)
    check("注入前先判当前是否就在主动会话", "chat.sessionId == ChatStore.proactiveSessionId" in body)
    check("🚫 注入不调用 loadById（会清空用户正在看的对话）", "loadById" not in body)
    check("🚫 注入不做 App 侧写库（全量 merge 会覆盖 NAS）", "/api/sessions" not in body)

# ═══ 4. 不可删：三处入口都拦 ═══
print("== 4. 不可删除（单条 / 批量 / 菜单入口）")
p_sess, s_sess = find("SessionsView.swift")
check("SessionsView 引入固定会话删除拦截", "proactiveSessionId" in s_sess)
check("单条 delete() 拦固定会话", "是固定会话，不能删除" in s_sess)
d = re.search(r"private func delete\(_ s: ChatSession\)\s*\{(.*?)\n    \}", s_sess, re.DOTALL)
check("拦截在 delete() 最开头（发请求前就拦）",
      d is not None and "proactiveSessionId" in d.group(1)[:400])
b = re.search(r"private func deleteSelected\(\)\s*\{(.*?)\n        let idsCopy", s_sess, re.DOTALL)
check("批量删除过滤掉固定会话（否则后端部分拒绝→走失败分支）",
      b is not None and "filter" in b.group(1))
# 菜单入口：不该出现"点了会报错"的删除按钮
check("contextMenu 对固定会话不显示删除入口",
      s_sess.count("if s.id != ChatStore.deliverySessionId && s.id != ChatStore.proactiveSessionId") >= 2)

# ═══ 4b. 清空口 / 改名口 ═══
# v4.0.18 语义反转（用户拍板）：固定会话（投递壳 / 轻聊主动）**允许清空**——
#   投递壳本就走后端 _CLIENT_WINS_IDS（v3.9.72 内容以客户端为准）；
#   主动会话由 merge_sessions 空数组特判采纳（显式清空意图；非空快照仍以 NAS 为准防丢回复）。
# 但清空口仍须有护栏：本会话正在收流时拦（流式回复的落库写会把刚清空的会话又写满）。
#   改名口维持锁定（后端标题锁定 + 前端不给入口）。
print("== 4b. 清空口 / 改名口（固定会话可清空 + 流拦截护栏）")
p_cv, s_cv = find("ChatView.swift")
cl = re.search(r'Button\("清空本会话消息".*?\n        \}', s_cv, re.DOTALL)
check("能定位清空按钮", cl is not None)
if cl:
    check("清空口不再拦固定会话（v4.0.18 反转：两固定会话都可清）",
          "isFixedSession" not in cl.group(0), "清空口又把固定会话拦了（旧护栏复活）")
    check("清空口拦正在收流的会话（防流式落库写盖回）",
          "thisSessionStreaming" in cl.group(0), "流拦截缺失")
    check("流拦截在 clearMessages() 之前（不能先清再拦）",
          cl.group(0).find("thisSessionStreaming") < cl.group(0).find("clearMessages()"))
    check("有可见提示（不给点了没反应的按钮）", "clearBlockedHint" in cl.group(0))
    check("发空写前排空在途写链（flushPendingWrites，防旧快照盖回）",
          "flushPendingWrites" in cl.group(0), "写链闸门缺失")
check("ChatView 声明 clearBlockedHint 状态", "@State var clearBlockedHint" in s_cv)
check("clearBlockedHint 挂在 alert 上（提示真能弹出来）",
      'alert("无法清空"' in s_cv and "clearBlockedHint != nil" in s_cv)
# 会话列表：清空入口对固定会话可见（入口必须可用），删除入口仍隐藏
check("contextMenu 清空入口对固定会话可见（不含固定会话排除判断的清空按钮）",
      "confirmClear = s" in s_sess and
      "清空会话内容" in s_sess)
check("contextMenu 删除入口仍对固定会话隐藏（两处排除判断：改名+删除）",
      s_sess.count("if s.id != ChatStore.deliverySessionId && s.id != ChatStore.proactiveSessionId") >= 2)
# v4.0.68：固定会话改成顶部并排卡 —— 长按菜单现在由**卡片**承载。
#   只断言「字符串还在 sessionCell 里」是假绿（会话行对固定会话已不再渲染）；必须钉卡片这条路。
check("v4.0.68：并排卡挂同一份 sessionRowMenu（清空入口在卡片上也可达）",
      ".contextMenu { sessionRowMenu(s) }" in s_sess)
check("v4.0.68：长按菜单单一真源（confirmClear 赋值点唯一，卡片不另抄一份）",
      s_sess.count("confirmClear = s") == 1)
check("v4.0.68：多选态不渲染并排卡（不可勾选的卡不许留在屏上）",
      "!fixedChannelSessions.isEmpty && !editing" in s_sess)
check("v4.0.68：固定会话在编辑态不当勾选目标（showCheck 与 onTap 双闸）",
      "showCheck: editing && !isFixedSession(s.id)" in s_sess
      and "if editing && !isFixedSession(s.id) {" in s_sess)
check("clearContent 不再拦固定会话（v4.0.18 反转）",
      "固定会话，不能清空" not in s_sess, "SessionsView 清空闸门未放开")
rn = re.search(r'if s\.id != ChatStore\.deliverySessionId.*?renameText = s\.title', s_sess, re.DOTALL)
check("改名口对固定会话不显示入口", rn is not None, "护栏未抓到改名口缺口")
check("renameTarget 赋值点唯一（没有第二个漏护的改名入口）",
      s_sess.count("renameTarget = s") == 1)

# ═══ 5. 标题锁定 / 自动命名闸门覆盖两个固定会话 ═══
print("== 5. 标题锁定（自动命名闸门覆盖两个固定会话）")
p_nm, s_nm = find("SessionAutoName.swift")
check("ChatStore 命名闸门同时判两个固定会话",
      "sid == Self.deliverySessionId || sid == Self.proactiveSessionId" in s_chat)
check("SessionAutoName 注释已更新为「固定会话」语义",
      "固定会话" in s_nm)

# ═══ 6. 后端源码（若可取）：id / 受保护 / 客户端优先范围 ═══
print("== 6. 后端（可选，容器不可达时跳过）")
try:
    r = subprocess.run(
        ["python3", os.path.join(os.path.dirname(ROOT), "scripts", "ql.py"),
         "nas", "exec",
         "docker exec qingliao sh -c \"grep -n 'PROACTIVE_SESSION_ID\\|_PROTECTED_IDS =\\|_CLIENT_WINS_IDS =\\|append_proactive_message\\|主动会话显式清空采纳' '/volume1/docker/hermes/微信文件/轻聊web/backend/sessions_api.py'\""],
        cwd=os.path.dirname(ROOT), capture_output=True, text=True, timeout=90)
    be = r.stdout
except Exception as e:
    be = "SKIP %s" % e
if "SKIP" in be or not be.strip():
    print("⚠️ 后端不可达，本段跳过（App 侧断言已覆盖）")
else:
    check("后端有 PROACTIVE_SESSION_ID 常量", "PROACTIVE_SESSION_ID" in be)
    check("后端有 _PROTECTED_IDS 且含主动会话", "_PROTECTED_IDS" in be and "PROACTIVE_SESSION_ID" in be)
    check("后端有 _CLIENT_WINS_IDS（主动会话不在其中）", "_CLIENT_WINS_IDS" in be)
    check("后端有 append_proactive_message", "append_proactive_message" in be)
    check("后端有主动会话显式清空特判（v4.0.18）",
          "主动会话显式清空采纳" in be, "空数组清空特判缺失——主动会话清空将不落库")

# ═══ 7. 反向自证：把修复形态改坏，断言必须变红 ═══
print("== 7. 反向自证（改坏 → 判红 → 还原）")
import shutil
SHOTS = {p: s for p, s in SRC.items()}
try:
    # 事故 A：agent 分支改回注入当前会话（串进正常会话的本体）
    bad = s_inbox.replace("injectToProactiveSession(amsg)", "chat.append(amsg); _ = 0", 1)
    if bad == s_inbox:
        print("   ⚠️ 事故A 注入失败（形态不符）")
        check("🚫 反向A：改回 chat.append 后第 3 段判红", False, "未能注入")
    else:
        red = False
        m = re.search(r'if taskType == "agent"\s*\{', bad)
        if m:
            seg = bad[m.start(): m.start() + 2000]
            head = seg[: seg.find("return\n        }") + 20]
            red = ("chat.append(amsg)" in head) and ("injectToProactiveSession(amsg)" not in head)
        check("🚫 反向A：改回 chat.append 后第 3 段判红", red, "护栏未抓到")

    # 事故 B：只读闸门误扩到 isFixedSession（主动会话将不能回复）
    bad2 = s_view.replace("if chat.isDeliverySession {", "if chat.isFixedSession {", 1)
    if bad2 == s_view:
        print("   ⚠️ 事故B 注入失败（形态不符）")
        check("🚫 反向B：只读闸门误扩后第 2 段判红", False, "未能注入")
    else:
        g = re.search(r"if chat\.is(FixedSession|ProactiveSession)\s*\{", bad2)
        check("🚫 反向B：只读闸门误扩后第 2 段判红", g is not None, "护栏未抓到")

    # 事故 C：注入函数里偷加 loadById（会清空用户正在看的对话）
    m3 = re.search(r"(private func injectToProactiveSession.*?\n    \})", s_inbox, re.DOTALL)
    if m3:
        bad3 = s_inbox.replace(
            "guard let chat, chat.sessionId == ChatStore.proactiveSessionId else { return }",
            "_ = chat?.loadById\n        guard let chat, chat.sessionId == ChatStore.proactiveSessionId else { return }", 1)
        seg = re.search(r"private func injectToProactiveSession.*?\n    \}", bad3, re.DOTALL)
        check("🚫 反向C：注入内混入 loadById 后判红",
              seg is not None and "loadById" in seg.group(0), "护栏未抓到")
    else:
        check("🚫 反向C：注入内混入 loadById 后判红", False, "未能定位函数")
finally:
    # 本表从不落盘，SHOTS 仅用于确认未被意外改动
    for p, s in SHOTS.items():
        if read(p) != s:
            print("   ⚠️ 源码被意外修改: %s" % p)
            fails.append("源码被意外修改: " + p)

print("")
if fails:
    print("❌ FAILED %d:" % len(fails))
    for f in fails:
        print("   - " + f)
    sys.exit(1)
print("✅ ALL PASS（两个固定会话口径固化：投递壳只装不答 / 轻聊主动可回复，均不可删+标题锁定）")
