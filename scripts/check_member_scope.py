#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""编译盲区护栏：View 成员被搬到文件顶层（脱离所属 struct）。

背景（2026-09-27 CI run #600 真实踩坑）：
  拆 DashboardView 巨型 body 时，把 3 个成员（sheetContent / dashboardSheetDismiss /
  dashboardTask）追加到了**文件末尾**，而文件末尾在 struct DashboardView 之外 ——
  语法完全合法（-parse / 本地 check 全绿），但这些成员引用 sheetZoomNS / nas /
  lockEntities 等 struct 内状态，编译器报 "cannot find X in scope"，只有 CI archive 才挂。

本护栏的判定（纯文本，零编译）：
  1. 找出所有 `struct X: View {` 块（按花括号深度配对，跳过注释/字符串里的花括号）；
  2. 找出所有顶格（0 缩进）以 4 空格缩进开始的成员声明行（`@X`、`private var`、
     `func`、`// MARK:` 段首）—— 这些行必须落在**某个** struct/extension 块内；
  3. 落在所有块之外 → 报「成员在顶层」。
  为什么能防：Swift 里 struct/extension 同级成员必须缩进；顶格 4 空格缩进出现在
  任何块外，只可能是搬运事故（本仓两次拆分都栽在这）。
"""
import glob
import os
import re
import sys

# scripts/ 在仓根下一层：<repo>/scripts/check_member_scope.py → repo = dirname(dirname(__file__))
ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'qingliao')
MEMBER_RE = re.compile(
    r'^ {4}(?:@|private\s|fileprivate\s|public\s|internal\s|static\s|final\s)*'
    r'(?:var|let|func|subscript|typealias)\s')
MARK_RE = re.compile(r'^ {4}// MARK:')


def strip_noise(line):
    """去掉行内注释与字符串里的花括号，避免注释掉的 case 破坏深度配对。"""
    out, in_str, esc = [], False, False
    for ch in line:
        if in_str:
            if esc:
                esc = False
            elif ch == '\\':
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == '/' and out and out[-1] == '/':
            break
        else:
            out.append(ch)
    return ''.join(out)


def main():
    bad = []
    for p in sorted(glob.glob(ROOT + '/**/*.swift', recursive=True)):
        lines = open(p, encoding='utf-8').read().split('\n')
        # 深度 0 = 文件顶层。记录每个块的范围
        depth = 0
        stack = []          # [(start_line, header)]，depth = len(stack)
        for i, raw in enumerate(lines):
            # 判定用**进入本行之前**的深度：结构体头部 `struct X {` 这一行深度还是外层，
            # 其后的成员行才落在块内 —— 顺序反了会把所有成员误判成顶层。
            if not stack and (MEMBER_RE.match(raw) or MARK_RE.match(raw)):
                bad.append((p, i + 1, raw.strip()[:60],
                            '顶格 4 空格成员/MARK 在任何 struct/extension 之外'
                            '（疑成员被搬到文件末尾 → CI archive 才报 cannot find x in scope）'))
            code = strip_noise(raw)
            for ch in code:
                if ch == '{':
                    stack.append((i + 1, raw.strip()[:50]))
                elif ch == '}':
                    if stack:
                        stack.pop()
    if bad:
        for p, ln, txt, why in bad:
            print('❌ %s:%d %s\n     %s' % (os.path.relpath(p, ROOT), ln, why, txt))
        sys.exit(1)
    print('✅ 成员作用域护栏：无成员被搬到文件顶层')


if __name__ == '__main__':
    main()
