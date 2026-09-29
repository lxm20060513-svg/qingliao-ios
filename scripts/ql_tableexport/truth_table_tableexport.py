#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v4.0.8 表格导出入口真值表（静态源码护栏，退出码 0/1）

背景：轻聊里表格有**两条渲染路径**——
  ① MarkdownTableView（chat/ChatComponents.swift）—— markdown 表格
  ② AgentCardTable（chat/AgentResultCard.swift）—— ql-card 里的表格
v3.5.0 只给①加了 CSV 导出按钮，②从那时起一直没有 → 用户报「聊天里的表格没有导出按钮」。

本表钉住：
  1. 两条路径都必须有导出按钮（防止下次只改一边又回归）
  2. CSV 生成必须是**单一真源** TableCSVExport，禁止各处 private 抄一份
     （MiniCapsule 踩过：各文件私藏副本 → 本机 -parse 全绿、CI Archive 报 cannot find X in scope）
  3. 导出的 CSV 必须带 UTF-8 BOM（Excel/WPS 开中文不乱码）+ RFC 4180 转义
  4. 分享面板用 ActivityShareSheet，CSV 为空/写失败时不开面板
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHAT = os.path.join(ROOT, "qingliao", "Features", "Chat")
CHAT_COMPONENTS = os.path.join(CHAT, "ChatComponents.swift")
AGENT_RESULT_CARD = os.path.join(CHAT, "AgentResultCard.swift")

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


def struct_body(src, name):
    """取 struct/enum 体内文本（按大括号配平），避免全文命中污染。"""
    i = src.find("struct " + name)
    if i < 0:
        i = src.find("enum " + name)
    if i < 0:
        return ""
    j = src.find("{", i)
    if j < 0:
        return ""
    depth = 0
    for k in range(j, len(src)):
        if src[k] == "{":
            depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0:
                return src[j:k]
    return src[j:]


cc = read(CHAT_COMPONENTS)
arc = read(AGENT_RESULT_CARD)

# ── 1. 两条渲染路径都得有导出按钮 ────────────────────────────
for label, src, struct in (
    ("markdown 表格(MarkdownTableView)", cc, "MarkdownTableView"),
    ("ql-card 表格(AgentCardTable)", arc, "AgentCardTable"),
):
    body = struct_body(src, struct)
    check(label + " 有导出按钮(square.and.arrow.up)", "square.and.arrow.up" in body)
    check(label + " 挂了分享面板(ActivityShareSheet)", "ActivityShareSheet" in body)
    check(label + " 有无障碍标签「导出表格」", 'accessibilityLabel("导出表格")' in body)
    check(label + " 分享面板用 showShare 状态驱动", "showShare" in body)

# ── 2. CSV 生成单一真源 ──────────────────────────────────────
check("存在公共真源 TableCSVExport", "enum TableCSVExport" in cc)
check("真源有 makeCSV", "static func makeCSV" in cc)
# 旧的 private 副本必须已删除
check("旧的 private static func makeCSV 已删（防两份实现漂移）",
      cc.count("static func makeCSV") == 1)
# 两条路径都必须走真源，不许自己造
check("markdown 路径调用 TableCSVExport.makeCSV",
      "TableCSVExport.makeCSV" in struct_body(cc, "MarkdownTableView"))
check("ql-card 路径调用 TableCSVExport.makeCSV",
      "TableCSVExport.makeCSV" in struct_body(arc, "AgentCardTable"))
# 全仓不许出现第二处 CSV 实现
csv_impls = 0
for dirpath, _, files in os.walk(os.path.join(ROOT, "qingliao")):
    for fn in files:
        if not fn.endswith(".swift"):
            continue
        try:
            s = read(os.path.join(dirpath, fn))
        except Exception:
            continue
        if "func makeCSV" in s:
            csv_impls += 1
check("全仓 makeCSV 实现只有 1 处（实测 %d 处）" % csv_impls, csv_impls == 1)

# ── 3. CSV 内容正确性 ────────────────────────────────────────
tb = struct_body(cc, "TableCSVExport")
check("CSV 带 UTF-8 BOM（Excel/WPS 中文不乱码）", "0xEF, 0xBB, 0xBF" in tb)
check("CSV 按 RFC 4180 转义（逗号/引号/换行加引号）",
      all(k in tb for k in [',"', '"', r"\n"]))
check("CSV 用 CRLF 换行（Excel 友好）", r"\r\n" in tb)
check("CSV 写入失败返回 nil（不崩、不假装成功）", "return nil" in tb)

# ── 4. 分享面板条件：CSV 为 nil 不开面板 ──────────────────────
for label, src, struct in (
    ("markdown", cc, "MarkdownTableView"),
    ("ql-card", arc, "AgentCardTable"),
):
    body = struct_body(src, struct)
    check(label + " 仅在 CSV 生成成功时开分享面板（showShare = csvURL != nil）",
          "showShare = csvURL != nil" in body)

print("")
if fails:
    print("失败 %d 条 ❌" % len(fails))
    sys.exit(1)
print("全部通过：%d 项 ✅" % total)
sys.exit(0)
