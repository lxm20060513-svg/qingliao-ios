#!/usr/bin/env python3
"""SwiftUI 子组件实参序护栏（v4.0.x 工程治理第 2 号整改）

问题：SwiftUI View 的**成员初始化器**要求「调用处实参序 = 结构体存储属性声明序」，
      写反了编译器报 `argument 'x' must precede argument 'y'`。
      而 `check_swift.sh` 的 `swiftc -parse` 只查语法（合法）、CI archive 才挂，一轮 20 分钟。
      历史同类坑见 skill swiftui-param-order（PageHeader trailing、ChatInputBar onSend…）。

做法（纯静态文本分析，不编译）：
  ① 解析 `struct X: View {` 的属性块，按声明序取**参与成员初始化器**的存储属性
     （排除 @State/@Environment/@Binding/@FocusState/@AppStorage 等包装属性与
       static/class let、let 常量、computed var、function）。
     闭包类型属性（(T) -> V / () -> V）单独标记：它们可以走尾随闭包，不参与顺序断言。
  ② 全仓找 `X(` 的调用点，用括号配对取出实参列表（尾随闭包天然在括号外，天然被排除），
     顶层逗号切分出实参标签（`name: value` 形式；位置参数下划线忽略）。
  ③ 断言标签序列在声明序上单调不减；漏传参数不在本守卫范围（默认值静默失效另有真值表）。

口径与已知边界：
  - 显式写了 `init(...)` 的结构体不参与（声明序由 init 形参决定，不在静态可推范围）→ 跳过。
  - 同一文件内自定义 extension 里的属性不参与（成员初始化器仍以主声明为准）→ 只取首次声明。
  - 属性默认值不影响标签，只有名字参与。
用法：python3 scripts/check_swiftui_param_order.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "qingliao")

WRAPPERS = ("@State", "@StateObject", "@ObservedObject", "@Environment", "@Binding",
            "@FocusState", "@AppStorage", "@SceneStorage", "@Namespace", "@GestureState",
            "@FetchRequest", "@Query")

# 参与成员初始化器：let/var 存储属性，且不排除
RE_PROP = re.compile(
    r"^(?P<indent>[ \t]*)(?P<attrs>(?:@[\w]+(?:\([^)]*\))?\s+)*)"
    r"(?P<kw>let|var)\s+(?P<name>[A-Za-z_]\w*)\s*(?::\s*(?P<type>[^={\n]+?))?\s*(?:=.*)?$"
)
RE_STRUCT = re.compile(r"^(?:@\w+\s+)*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?"
                       r"(?:final\s+)?struct\s+(?P<name>[A-Za-z_]\w*)\s*(?::[^{]*)?\{")
RE_FUNC = re.compile(r"^\s*(?:@\w+\s+)*(?:public\s+|private\s+|internal\s+|static\s+|"
                     r"class\s+|final\s+|override\s+|mutating\s+|private\(set\)\s+)*func\b")
RE_STATIC = re.compile(r"^\s*(?:public\s+|private\s+|internal\s+|fileprivate\s+)?"
                       r"(?:static\s+|class\s+)(?:let|var)\b")


def strip_comment(line):
    """去掉行尾 // 注释（简单口径：不处理字符串里的 //，源码里极少出现）"""
    out, i, n = [], 0, len(line)
    in_str = False
    while i < n:
        c = line[i]
        if in_str:
            if c == "\\":
                out.append(c)
                i += 1
                if i < n:
                    out.append(line[i])
                    i += 1
                continue
            if c == '"':
                in_str = False
            out.append(c)
        else:
            if c == '"':
                in_str = True
                out.append(c)
            elif c == "/" and i + 1 < n and line[i + 1] == "/":
                break
            else:
                out.append(c)
        i += 1
    return "".join(out).rstrip()


def is_closure_type(t):
    return "->" in t


def scan_structs(path):
    """返回 {结构体名: {"order": [(标签, 是否闭包)], "has_init": bool}}

    只收**结构体体第一层**的存储属性：用花括号深度跟踪，跳过 func/computed var/闭包体内的
    局部变量（早期版本按缩进收，把函数体里的 let s/sep/… 全当成属性，索引被冲淡成假绿）。
    """
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            lines = f.read().split("\n")
    except OSError:
        return {}

    res, i, n = {}, 0, len(lines)
    while i < n:
        m = RE_STRUCT.match(lines[i])
        if not m:
            i += 1
            continue
        name = m.group("name")
        depth = 0
        order, has_init, seen = [], False, set()
        j = i
        started = False
        while j < n:
            s = strip_comment(lines[j])
            if not started:
                started = True  # RE_STRUCT 行本身以 "{" 结尾
                depth = s.count("{") - s.count("}")
                j += 1
                continue
            body = s.strip()
            if depth == 1 and body:
                if re.search(r"\bfunc\s+init\b", body):
                    has_init = True
                elif not RE_STATIC.match(s) and not body.startswith(
                        ("func ", "init(", "init ", "typealias ", "subscript")):
                    pm = RE_PROP.match(s)
                    if pm and pm.group("name") not in seen:
                        seen.add(pm.group("name"))
                        attrs = pm.group("attrs") or ""
                        if not any(a in attrs for a in WRAPPERS):
                            ptype = (pm.group("type") or "").strip()
                            order.append((pm.group("name"), is_closure_type(ptype)))
            depth += s.count("{") - s.count("}")
            if depth <= 0 and j > i:
                break
            j += 1
        res.setdefault(name, {"order": order, "has_init": has_init})
        i = max(j, i + 1)
    return res


def match_paren(text, open_idx):
    """返回 (闭括号下标, 括号内文本)"""
    depth, i, n, in_str = 0, open_idx, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i, text[open_idx + 1:i]
        i += 1
    return -1, ""


def split_top(inner):
    """顶层逗号切分（跳过括号/方括号/尖括号内与字符串内）"""
    parts, buf = [], []
    depth = 0
    in_str = False
    i, n = 0, len(inner)
    while i < n:
        c = inner[i]
        if in_str:
            buf.append(c)
            if c == "\\":
                if i + 1 < n:
                    buf.append(inner[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            buf.append(c)
        elif c in "([{<":
            depth += 1
            buf.append(c)
        elif c in ")]}>":
            depth -= 1
            buf.append(c)
        elif c == "," and depth == 0:
            parts.append("".join(buf).strip())
            buf = []
        else:
            buf.append(c)
        i += 1
    if "".join(buf).strip():
        parts.append("".join(buf).strip())
    return parts


RE_CALL = re.compile(r"(?<![A-Za-z0-9_\.])(\w+)\(")


def arg_label(part):
    m = re.match(r"([A-Za-z_]\w*)\s*:(?!:)", part)
    return m.group(1) if m else None


SELF_TEST_SRC = """import SwiftUI
struct Demo: View {
    let title: String
    let count: Int
    let onTap: () -> Void
    var body: some View { Text(title) }
}
struct Other: View {
    let a: Int
    let b: Int
    var body: some View { Text("x") }
}
struct Bad1: View {
    var body: some View { Other(b: 1, a: 2) }
}
struct Ok1: View {
    var body: some View { Other(a: 1, b: 2) }
}
struct Bad2: View {
    var body: some View { Demo(count: 1, title: "x") { } }
}
"""


def self_test():
    """内置样例：必须抓到 2 处乱序（Other(b,a) / Demo(count,title)），放过 1 处正确序。
    抓到 0 条说明解析器失效 —— 那是最大的坑（静默假绿）。"""
    import tempfile
    d = tempfile.mkdtemp(prefix="ql_argorder_")
    with open(os.path.join(d, "Demo.swift"), "w", encoding="utf-8") as f:
        f.write(SELF_TEST_SRC)
    out, _rc = run([os.path.join(d, "Demo.swift")])
    fails = [l for l in out.split("\n") if l.startswith("❌")]
    ok = len(fails) == 2 and any("Other(" in l for l in fails) \
        and any("Demo(" in l for l in fails)
    print(("✅ 自测：抓到 2 处乱序 + 放过正确序" if ok
           else "❌ 自测失败（应 2 条实为 %d 条）:\n%s" % (len(fails), out)))
    return 0 if ok else 1


def main():
    if "--self-test" in sys.argv:
        return self_test()
    swift = []  # noqa
    for dirpath, _dirs, files in os.walk(SRC):
        for f in files:
            if f.endswith(".swift"):
                swift.append(os.path.join(dirpath, f))
    swift.sort()

    out, rc = run(swift)
    print(out)
    return rc


def run(swift):
    structs = {}
    for p in swift:
        for name, info in scan_structs(p).items():
            structs.setdefault(name, info)

    usable = {k: v for k, v in structs.items()
              if len(v["order"]) >= 2 and not v["has_init"]}
    lines = []
    if not usable:
        lines.append("❌ 没解析出任何可断言的结构体（解析器失效？静默假绿是最大的坑）")
        return "\n".join(lines), 1

    index = {k: {label: i for i, (label, _c) in enumerate(v["order"])}
             for k, v in usable.items()}
    closable = {k: {label for label, c in v["order"] if c} for k, v in usable.items()}

    checked, calls, fails, unknown = 0, 0, [], 0
    for p in swift:
        try:
            with open(p, encoding="utf-8", errors="ignore") as f:
                text = f.read()
        except OSError:
            continue
        for name in usable:
            for m in RE_CALL.finditer(text):
                if m.group(1) != name:
                    continue
                close, inner = match_paren(text, m.end() - 1)
                if close < 0:
                    continue
                labels = [lab for lab in (arg_label(x) for x in split_top(inner))
                          if lab]
                if len(labels) < 2:
                    continue
                # 声明顺序里完全不存在的标签（扩展属性 / 计算属性 / init 参数）→ 放过
                known = [l for l in labels if l in index[name] or l in closable[name]]
                if len(known) < len(labels):
                    unknown += 1
                if len(known) < 2:
                    continue
                calls += 1
                seq = [index[name][l] for l in known if l in index[name]]
                line = text.count("\n", 0, m.start()) + 1
                rel = os.path.relpath(p, ROOT)
                if any(seq[i] >= seq[i + 1] for i in range(len(seq) - 1)):
                    fails.append("%s:%d  %s(...) 实参序 %s 与声明序 %s 不一致"
                                 % (rel, line, name, known,
                                    [l for l, _ in usable[name]["order"]]))
                else:
                    checked += 1

    lines.append("✅ 参数序护栏：解析到 %d 个可断言结构体，扫描 %d 个调用点，"
                 "通过 %d，乱序 %d（放行非成员初始化器标签 %d 处）"
                 % (len(usable), calls, checked, len(fails), unknown))
    for f in fails:
        lines.append("❌ " + f)
    return "\n".join(lines), (1 if fails else 0)


if __name__ == "__main__":
    sys.exit(main())
