#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
框架回调闭包隔离护栏（第 39 段）

背景（2026-09-27 v3.9.97 真机 4 次 Signal(5) 定案）：
  ObjC 桥接进来的 completion 参数**多数没有 @Sendable**。当闭包字面量写在 `@MainActor` 类型/方法里时，
  它**继承 MainActor 隔离**；框架在自己的后台队列回调它 → 进入闭包即做隔离检查 → SIGTRAP。
  符号化后的栈：`dispatch_assert_queue_not ← libswift_Concurrency ← closure #1 ([EKReminder]?) -> ()`
  崩溃点 = `AgentActionExecutor.listReminders` 里的 `store.fetchReminders(matching:) { list in }`。

  这类错**编译器全程沉默**：`swiftc -parse` 无输出、CI archive 照过、零告警，只有真机崩 → 必须靠源码护栏。

判定（本脚本只认「实测会崩」的名单，宁少勿滥，避免误报把护栏变噪音）：
  被点名 API 的那次调用里，闭包字面量**必须显式带 `@Sendable`**；
  或所在函数整体标 `nonisolated`（此时字面量不继承隔离，也是合法解）。
"""
import os
import re
import sys

# API → 框架/回调线程说明。只加「实测在后台队列回调且参数非 @Sendable」的，不要凭印象扩表。
RISKY = {
    "fetchReminders": "EventKit 提醒事项（私有后台队列）",
    "detectPatterns": "UIKit UIPasteboard 精确探测（后台队列）",
    "installTap": "AVAudioEngine 音频线程",
    "requestRecordPermission": "AVAudioApplication 权限（非主线程回调）",
}

ROOT = "qingliao"
FUNC_RE = re.compile(r"\b(func|init)\s+[A-Za-z_]")


def enclosing_decl(lines, idx):
    """向上找最近的函数声明行（用来判是不是 nonisolated）。"""
    for j in range(idx, max(-1, idx - 80), -1):
        if FUNC_RE.search(lines[j]):
            return lines[j].strip()
    return ""


def main():
    if not os.path.isdir(ROOT):
        print(f"❌ 找不到源码目录 {ROOT}/（护栏路径错了，等于没查）")
        return 1

    scanned = 0
    sites = []      # 命中名单的调用点
    bad = []
    for dirpath, _dirnames, filenames in os.walk(ROOT):
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            scanned += 1
            lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
            for i, line in enumerate(lines):
                code = line.split("//")[0]          # 丢掉行尾注释，避免注释里的 API 名被当成调用
                hit = [a for a in RISKY if a + "(" in code]
                if not hit:
                    continue
                if "{" not in code:                 # 回调不在这一行（可能换行/或不是闭包形式）→ 看下一行
                    nxt = lines[i + 1].split("//")[0] if i + 1 < len(lines) else ""
                    if "{" not in nxt:
                        continue
                    look = nxt
                    window = lines[i:i + 4]
                else:
                    look = code
                    window = lines[i:i + 3]
                decl = enclosing_decl(lines, i)
                sites.append((path, i + 1, hit[0], decl, "@Sendable" in "".join(window)))
                if "@Sendable" in "".join(window):
                    continue
                if "nonisolated" in decl:
                    continue
                bad.append((path, i + 1, hit[0], decl))

    if scanned < 100:
        print(f"❌ 只扫到 {scanned} 个 .swift 文件（应 >100，路径/工作目录不对）")
        return 1

    print(f"扫描 {scanned} 个 .swift 文件，命中名单调用点 {len(sites)} 处：")
    for path, ln, api, decl, ok in sites:
        mark = "✅" if ok else "❔"
        print(f"  {mark} {path}:{ln} [{api}] ← {decl[:80] or '(顶层)'}")

    if bad:
        print("\n❌ 以下框架回调字面量没有 `@Sendable`，且所在函数不是 nonisolated：")
        for path, ln, api, decl in bad:
            print(f"   {path}:{ln}  {api}  ← {decl[:90]}")
        print(f"   风险：{RISKY[bad[0][2]]} —— 字面量继承 @MainActor 隔离，框架后台队列回调即 SIGTRAP")
        print("   改法：字面量原地加 `@Sendable`（如 `{ @Sendable list in`），别改调用形态。")
        return 1

    if not sites:
        print("❌ 一处都没命中——护栏空转（名单里的 API 是不是被改名/删了？）")
        return 1
    print(f"✅ 框架回调闭包隔离 {len(sites)} 处全部带 @Sendable / 或位于 nonisolated 函数")
    return 0


if __name__ == "__main__":
    sys.exit(main())
