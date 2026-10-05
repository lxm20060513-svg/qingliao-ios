#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
框架回调闭包隔离护栏（第 39 段）

背景（2026-09-27 v3.9.97 真机 4 次 Signal(5)、2026-10-05 v4.0.57 真机 1 次 Signal(5) 定案）：
  ObjC 桥接进来的 completion 参数**多数没有 @Sendable**。当闭包字面量写在 `@MainActor` 类型/方法里时，
  它**继承 MainActor 隔离**；框架在自己的后台队列回调它 → 进入闭包即做隔离检查 → SIGTRAP。
  符号化后的栈：`dispatch_assert_queue_not ← libswift_Concurrency ← closure #1 ([EKReminder]?) -> ()`
  崩溃点 = `AgentActionExecutor.listReminders` 里的 `store.fetchReminders(matching:) { list in }`。

  v4.0.57 同一形态：`dispatch_assert_queue_not ← libswift_Concurrency ← closure #1 () -> () in deletePhoto`
  崩溃点 = 相册删除的 `PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }`。
  （删相册照片每次都崩；反汇编该闭包入口可见 `swift_task_isCurrentExecutor` + `swift_task_reportUnexpectedExecutor`，
   参数里还带 `Qingliao/AgentActionExecutor.swift` + 行号 → 隔离前置检查确凿。
   修法 = 把字面量搬进 nonisolated 函数，字面量不再继承隔离，编译器也就不插这个检查。）

  这类错**编译器全程沉默**：`swiftc -parse` 无输出、CI archive 照过、零告警，只有真机崩 → 必须靠源码护栏。

判定（本脚本只认「实测会崩」的名单，宁少勿滥，避免误报把护栏变噪音）：
  被点名 API 的那次调用里，闭包字面量**必须显式带 `@Sendable`**；
  或所在函数整体标 `nonisolated`（此时字面量不继承隔离，也是合法解）。

两种闭包形态都要认（第 40 段补的老漏检）：
  ① 带括号：`store.fetchReminders(matching: x) { list in }`
  ② 尾随闭包：`PHPhotoLibrary.shared().performChanges { … }`
  —— performChanges 只有形态 ②，而早先只匹配 `api(`，于是该 API 从未被扫到：
     护栏看起来在跑，实际空转，删相册崩到真机才暴露。所以现在**先自证再扫描**。
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
    "performChanges": "Photos PHPhotoLibrary 变更块（Photos 私有后台队列，v4.0.57 删相册实测必崩）",
}

ROOT = "qingliao"
FUNC_RE = re.compile(r"\b(func|init)\s+[A-Za-z_]")


def enclosing_decl(lines, idx):
    """向上找最近的函数声明行（用来判是不是 nonisolated）。"""
    for j in range(idx, max(-1, idx - 80), -1):
        if FUNC_RE.search(lines[j]):
            return lines[j].strip()
    return ""


def risky_hits(code):
    """命中名单 API → 返回 API 名列表（两种闭包形态都认，见文件头说明）。"""
    out = []
    for a in RISKY:
        if a + "(" in code or re.search(re.escape(a) + r"\s*\{", code):
            out.append(a)
    return out


def check_source(text, path="<sample>"):
    """扫一段源码，返回违规调用点 [(path, 行号, api, 所在函数声明)]。抽出来是为了能自证。"""
    lines = text.split("\n")
    bad = []
    for i, line in enumerate(lines):
        code = line.split("//")[0]          # 丢掉行尾注释，避免注释里的 API 名被当成调用
        hit = risky_hits(code)
        if not hit:
            continue
        if "{" not in code:                 # 回调不在这一行（可能换行/或不是闭包形式）→ 看下一行
            nxt = lines[i + 1].split("//")[0] if i + 1 < len(lines) else ""
            if "{" not in nxt:
                continue
            window = lines[i:i + 4]
        else:
            window = lines[i:i + 3]
        if "@Sendable" in "".join(window):
            continue
        decl = enclosing_decl(lines, i)
        if "nonisolated" in decl:
            continue
        bad.append((path, i + 1, hit[0], decl))
    return bad


SELF_TEST_CASES = [
    # (样本, 期望违规数, 说明)
    (
        "enum E {\n"                                   # ① 老盲区：尾随闭包 + 非 nonisolated 上下文
        "    static func f() async {\n"
        "        try? await PHPhotoLibrary.shared().performChanges {\n"
        "            PHAssetChangeRequest.deleteAssets(assets)\n"
        "        }\n"
        "    }\n}\n",
        1, "尾随闭包形态 performChanges { … } 必须被匹配（v4.0.57 漏检的那种）"),
    (
        "enum E {\n"                                   # ② 修法：nonisolated 函数里
        "    private nonisolated static func f() async throws {\n"
        "        try await PHPhotoLibrary.shared().performChanges {\n"
        "            PHAssetChangeRequest.deleteAssets(assets)\n"
        "        }\n"
        "    }\n}\n",
        0, "nonisolated 函数里的字面量不继承隔离，合法解"),
    (
        "enum E {\n"                                   # ③ 修法：原地 @Sendable
        "    static func f() async {\n"
        "        _ = try? await store.fetchReminders(matching: p) { @Sendable list in\n"
        "            _ = list\n"
        "        }\n"
        "    }\n}\n",
        0, "字面量显式 @Sendable，合法解"),
    (
        "enum E {\n"                                   # ④ 带括号形态的旧写法仍要抓
        "    static func f() async {\n"
        "        _ = try? await store.fetchReminders(matching: p) { list in\n"
        "            _ = list\n"
        "        }\n"
        "    }\n}\n",
        1, "带括号形态漏 @Sendable 仍要报"),
]


def self_test():
    """护栏自证：坏样本必须报、好样本必须过。不通过就别信这轮绿灯。"""
    bad = []
    for text, want, why in SELF_TEST_CASES:
        got = len(check_source(text))
        if got != want:
            bad.append("自证失败：期望 %d 处违规、实际 %d 处 —— %s" % (want, got, why))
    return bad


def main():
    if not os.path.isdir(ROOT):
        print(f"❌ 找不到源码目录 {ROOT}/（护栏路径错了，等于没查）")
        return 1

    st = self_test()
    if st:
        print("❌ 护栏自证没过（护栏本身坏了，绿了也不算）：")
        for x in st:
            print("   " + x)
        return 1

    scanned = 0
    sites = []      # 命中名单的调用点 (path, 行号, api, 所在函数, 是否合规)
    bad = []
    for dirpath, _dirnames, filenames in os.walk(ROOT):
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            scanned += 1
            text = open(path, encoding="utf-8", errors="replace").read()
            lines = text.split("\n")
            violations = check_source(text, path)
            bad.extend(violations)
            bad_lines = {v[1] for v in violations}
            for i, line in enumerate(lines):
                code = line.split("//")[0]
                hit = risky_hits(code)
                if not hit:
                    continue
                if "{" not in code:                     # 尾随闭包不在同一行 → 看下一行
                    nxt = lines[i + 1].split("//")[0] if i + 1 < len(lines) else ""
                    if "{" not in nxt:
                        continue
                    window = line + nxt
                else:
                    window = line
                decl = enclosing_decl(lines, i)
                ok = ("@Sendable" in window) or ("nonisolated" in decl) or (i + 1 not in bad_lines)
                sites.append((path, i + 1, hit[0], decl, ok))

    if scanned < 100:
        print(f"❌ 只扫到 {scanned} 个 .swift 文件（应 >100，路径/工作目录不对）")
        return 1

    print(f"扫描 {scanned} 个 .swift 文件，命中名单调用点 {len(sites)} 处：")
    for path, ln, api, decl, ok in sites:
        mark = "✅" if ok else "❌"
        print(f"  {mark} {path}:{ln} [{api}] ← {decl[:80] or '(顶层)'}")

    if bad:
        print("\n❌ 以下框架回调字面量没有 `@Sendable`，且所在函数不是 nonisolated：")
        for path, ln, api, decl in bad:
            print(f"   {path}:{ln}  {api}  ← {decl[:90]}")
        print(f"   风险：{RISKY[bad[0][2]]} —— 字面量继承 @MainActor 隔离，框架后台队列回调即 SIGTRAP")
        print("   改法：① 字面量原地加 `@Sendable`（如 `{ @Sendable list in`）；")
        print("        ② 或把这次调用搬进一个 `nonisolated func`（相册那两处就是这么修的）。")
        return 1

    if not sites:
        print("❌ 一处都没命中——护栏空转（名单里的 API 是不是被改名/删了？）")
        return 1
    print(f"✅ 框架回调闭包隔离 {len(sites)} 处全部带 @Sendable / 或位于 nonisolated 函数")
    return 0


if __name__ == "__main__":
    sys.exit(main())
