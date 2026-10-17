#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""检出「修饰符挂在 if/else 语句上」的形态 —— SwiftUI 里编译不过，且只有 CI Archive 报：
        error: instance member 'animation' cannot be used on type 'View'
    （if 三分支共同类型被推成存在类型 `View`，而 `.animation` 是 View 协议扩展成员 → 挂不上）

实踩（v4.0.120）：TaskCenterView 的 body 里三分支直接写、`.animation(Motion.settle, value:)` 挂在
`if/else` 语句的收尾 `}` 之后 —— 本机 `-parse` 全绿、全部真值表也照不到，连烧三轮 Archive 才定住。
正解：把分支收进 `@ViewBuilder` 计算属性（或 `Group {}`）后，再挂在具体视图表达式上。

判据：某行形如 `if … {` / `else if … {`（整行以 `{` 收尾），其花括号**配平之后**的第一非注释、
      非空行若以 `.` 开头且**缩进与该 if 行相同** → 命中（该修饰符挂到了语句上，不是挂在视图上）。

用法：python3 scripts/check_if_chain_modifier.py [根目录，默认 qingliao]
      命中则逐条打印 `文件:if行号 -> .modifier` 并 exit 1；无命中打印 OK 并 exit 0。
"""
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else 'qingliao'
IF_RE = re.compile(r'^(\s*)(if|else if)\b.*\{\s*$')
MOD_RE = re.compile(r'^(\s*)\.([A-Za-z_]\w*)')


def scan(path):
    out = []
    with open(path, encoding='utf-8') as fh:
        lines = fh.read().split('\n')
    i = 0
    while i < len(lines):
        m = IF_RE.match(lines[i])
        if not m:
            i += 1
            continue
        indent = len(m.group(1))
        depth, j = 0, i
        while j < len(lines):
            depth += lines[j].count('{') - lines[j].count('}')
            if depth <= 0 and j > i:
                break
            j += 1
        k = j + 1
        while k < len(lines) and (not lines[k].strip() or lines[k].strip().startswith('//')):
            k += 1
        if k < len(lines):
            nm = MOD_RE.match(lines[k])
            if nm and len(nm.group(1)) == indent:
                out.append('%s:%d: if(%d) 之后的 .%s' % (path, k + 1, i + 1, nm.group(2)))
        i = j + 1
    return out


def main():
    bad = []
    for base, _dirs, files in os.walk(ROOT):
        for f in files:
            if f.endswith('.swift'):
                bad += scan(os.path.join(base, f))
    if bad:
        for b in bad:
            print(b)
        print('❌ 有 %d 处修饰符挂在 if/else 语句上 —— 收进 @ViewBuilder 计算属性或 Group 后再挂'
              % len(bad))
        sys.exit(1)
    print('OK 无「修饰符挂在 if/else 语句上」的形态（%s）' % ROOT)


if __name__ == '__main__':
    main()
