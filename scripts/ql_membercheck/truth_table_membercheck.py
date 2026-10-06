#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v3.9.113 成员存在性护栏（退出码 0/1）

背景：v3.9.111 / v3.9.112 连续两轮 Archive 失败，全是**本机 -parse 拦不住**的类型错误：
  - `Typography.caption2` → type 'Typography' has no member 'caption2'
  - `motionOption(...)` → cannot find 'motionOption' in scope（搬 UI 时漏搬定义）
  - `@AppStorage` 写在 extension 里 → extensions must not contain stored properties
  - `Outcome.done(message:)` 漏传无默认值的 `undo`
  - `GoalTodoBridge` 未标 @MainActor → main actor-isolated from a nonisolated context

这类错误**只有 CI Archive 拦得住**，而每次发版要烧一轮 CI + 一个 tag（tag 不可复用）。
本表把这几类搬到本地，退出码 0/1，直接挂进 check_swift.sh。

用法：python3 scripts/ql_membercheck/truth_table_membercheck.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "qingliao")

fails = []
total = 0


def check(desc, cond, detail=""):
    global total
    total += 1
    if cond:
        print("✅ " + desc)
    else:
        print("❌ " + desc + ("｜" + detail if detail else ""))
        fails.append(desc)


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def swift_files():
    out = []
    for dp, _dn, fn in os.walk(SRC):
        for f in fn:
            if f.endswith(".swift"):
                out.append(os.path.join(dp, f))
    return out


ALL = swift_files()
# 常见噪声：系统自带 / SwiftUI / Foundation 的符号，不参与校验
SYSTEM_OK = {
    "Type", "Self", "Any", "Void", "Never", "Error", "String", "Int", "Bool", "Double",
    "Float", "CGFloat", "Color", "Font", "View", "Text", "Image", "HStack", "VStack",
    "ZStack", "Spacer", "Divider", "Button", "Toggle", "Section", "ForEach", "ScrollView",
    "LazyVStack", "LazyHStack", "List", "NavigationLink", "Shape", "Angle", "Edge",
    "Alignment", "UnitPoint", "Animation", "Transaction", "Namespace", "Opacity",
    "RoundedRectangle", "Circle", "Capsule", "Rectangle", "Path", "LinearGradient",
    "RadialGradient", "Gradient", "StrokeStyle", "Font", "State", "Binding", "UserDefaults",
    "Notification", "Task", "DispatchQueue", "MainActor", "Bundle", "Locale", "Calendar",
    "DateFormatter", "JSONDecoder", "JSONEncoder", "URL", "Data", "UUID", "Hashable",
}

# ── 1. 主题令牌成员存在性（Typography / Spacing / Radius / Pill …）──────────
# 真实成员从定义文件里抽出来，比手工维护白名单可靠。
_theme_members = {}
for _f in ALL:
    _s = read(os.path.relpath(_f, ROOT))
    for m in re.finditer(r"enum\s+(\w+)\s*\{", _s):
        name = m.group(1)
        i = m.end()
        d = 1
        j = i
        while j < len(_s) and d > 0:
            d += (_s[j] == "{") - (_s[j] == "}")
            j += 1
        body = _s[i : j - 1]
        mem = set(re.findall(r"static (?:let|var|func)\s+(\w+)", body))
        mem |= set(re.findall(r"case\s+(\w+)", body))
        if mem:
            _theme_members.setdefault(name, set()).update(mem)

_theme_files = {
    "Typography": "qingliao/Theme/Typography.swift",
    "Spacing": "qingliao/Theme/Spacing.swift",
    "Radius": "qingliao/Theme/Radius.swift",
}
_bad_theme = []
for _tname, _rel in _theme_files.items():
    if not os.path.exists(os.path.join(ROOT, _rel)):
        continue
    for _f in ALL:
        _relf = os.path.relpath(_f, ROOT)
        if _relf == _rel:
            continue
        _s = read(_relf)
        # 剥注释：注释里的 Typography.caption2 之类不是真调用
        _s_nc = re.sub(r"//[^\n]*", lambda mm: " " * len(mm.group(0)), _s)
        # 排除文件名文本（"Spacing.swift" 里的 .swift 不是成员访问）
        for m in re.finditer(re.escape(_tname) + r"\.(\w+)", _s_nc):
            if m.group(1) == "swift":
                continue
            # 前面紧邻标识符字符（如 LineSpacing.compact 里的 Spacing.compact）→ 是别的类型
            if m.start() > 0 and (_s_nc[m.start() - 1].isalnum() or _s_nc[m.start() - 1] == "_"):
                continue
            if m.group(1) not in _theme_members.get(_tname, set()):
                _ln = _s[: m.start()].count("\n") + 1
                _bad_theme.append("%s:%d %s.%s" % (_relf, _ln, _tname, m.group(1)))
check("主题令牌成员全部真实存在（Typography/Spacing/Radius）",
      not _bad_theme,
      "不存在: " + ", ".join(sorted(set(_bad_theme))[:8]))

# Swift 声明修饰符 / 关键字：后面跟 ( 也可能不是调用
_MODIFIERS = {
    "init", "deinit", "subscript", "private", "fileprivate", "public", "internal",
    "open", "convenience", "required", "mutating", "override", "static", "final",
    "lazy", "weak", "unowned", "indirect", "nonmutating", "prefix", "postfix",
    "infix", "dynamic", "optional", "class", "protocol", "some", "any", "case",
    "nonisolated", "isolated", "distributed", "borrowing", "consuming", "each",
    "unsafe", "package", "if", "for", "while", "switch", "return", "guard",
    "let", "var", "func", "else", "catch", "try", "await", "in", "where",
    # SwiftUI 视图修饰符 / 环境方法 / 参数修饰（后面跟 ( 也不是函数定义）
    "inout", "dismiss", "modifier", "keyframeAnimator", "animation", "transition",
    "gesture", "sensoryFeedback", "onChange", "onDisappear", "onAppear", "task",
    "alert", "confirmationDialog", "sheet", "popover", "fullScreenCover", "overlay",
    "background", "backgroundLayer", "containerBackground", "symbolEffect", "containerRelativeFrame",
    "presentationDetents", "presentationDragIndicator", "scrollPosition", "scrollTargetLayout",
    "matchedGeometryEffect", "phaseAnimator", "contentTransition", "visualEffect",
    "onSubmit", "onDrag", "onDrop", "onMove", "onDelete", "onTapGesture", "onLongPressGesture",
    "focused", "refreshable", "searchable", "fileImporter", "fileExporter", "dropDestination",
    "onChangeCommand", "onExitCommand", "defaultAction", "commands", "help", "accessibilityLabel",
    "scrollTo", "scrollToItem", "escaping", "selector", "configure", "register",
    # Foundation / Darwin 数学与工具函数
    "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "ceil", "floor", "round",
    "log", "log10", "exp", "pow", "hypot", "fmod", "remainder", "gcd", "lcm",
    "sqrt", "sqrtf", "cbrt", "fmax", "fmin", "copysign", "fabs", "fma",
    # GraphicsContext / SwiftUI 绘制（paint/transform/resolve 都是 GraphicsContext 方法）
    "paint", "transform", "resolve", "resolveSymbol", "clip", "blendMode",
    # ViewBuilder 同文件方法（如 GoalsSection.deleteConfirm(on:)）
    "deleteConfirm", "print", "padding", "debugPrint", "dump", "assert", "precondition",
    "fatalError", "nslog", "type",
}

# ── 2. 同文件私有成员：调用了但全仓无定义（专治「搬 UI 只搬调用点、漏定义」）──
# 放行两类：① 本仓确实定义的符号（含 enum case 构造）
#           ② 系统/标准库符号（所在文件 import Darwin/Foundation/Glibc/UIKit，或 Swift with* 家族）
_SRC_ALL = "\n".join(read(os.path.relpath(_f, ROOT)) for _f in ALL)
_defined = set(re.findall(r"\bfunc\s+(\w+)\s*\(", _SRC_ALL))
# v4.0.65：泛型函数定义（func foo<T>(…) / func foo<T: View>(…) / func foo<T, U>(…)）也算已定义。
# 旧正则要求函数名后**紧跟 "("**，而泛型签名的名字后面是 "<"，于是这类函数的**调用处**
# 被误判成「疑似未定义」（LifeBadges 的 badgeShell<C: View> 就这么白红过一次）。
# 只补「泛型签名」这一种形态的识别，不放宽任何其它判定——匹配不到时行为与旧版逐字一致。
_defined |= set(re.findall(r"\bfunc\s+(\w+)\s*<[^>]*>\s*\(", _SRC_ALL))
_defined |= set(re.findall(r"\b(?:let|var)\s+(\w+)\s*[:=]", _SRC_ALL))
_defined |= set(re.findall(r"\b(?:struct|enum|class|actor|protocol)\s+(\w+)", _SRC_ALL))
_defined |= set(re.findall(r"\bcase\s+(\w+)", _SRC_ALL))
_defined |= {"withAnimation", "withTransaction", "getenv", "abs", "min", "max", "sleep"}

_system_files = set()
for _f in ALL:
    _relf = os.path.relpath(_f, ROOT)
    if re.search(r"^\s*import\s+(Darwin|Foundation|Glibc|UIKit|os)\s*$", read(_relf), re.M):
        _system_files.add(_relf)

# Swift 标准库 with* 家族：只在非系统文件里出现的才可能是本仓自造
_STDLIB_WITH = set(re.findall(r"\b(with[A-Z]\w*)\s*\(", "\n".join(
    read(os.path.relpath(_f, ROOT)) for _f in ALL
    if os.path.relpath(_f, ROOT) not in _system_files)))

_bad_call = []
for _f in ALL:
    _relf = os.path.relpath(_f, ROOT)
    _s = read(_relf)
    # 剥注释但保留行号（替换成等长空白），否则报错行号错位
    _s_nc = re.sub(r"//[^\n]*", lambda mm: " " * len(mm.group(0)), _s)
    for m in re.finditer(r"(?<![\.\w])([a-z]\w+)\s*\(", _s_nc):
        fn = m.group(1)
        if fn in _defined or fn in SYSTEM_OK:
            continue
        # 捕获到的 fn 本身就是关键字（return ( / for ( / if ( …）→ 不是函数调用
        if fn in _MODIFIERS:
            # ⚠️ 只能靠 fn 自身判定，不能看「紧邻前缀词」——闭包参数 `{ motion in`
            #    里的 in 会被误当关键字，把真正的漏定义调用整条放行（motionOption
            #    就是这样被放过的）。fn 自身是关键字才是 return ( / for ( 这类用法。
            continue
        _line_start = _s_nc.rfind("\n", 0, m.start()) + 1
        _line_txt = _s_nc[_line_start : m.start()]
        if _line_txt.lstrip().startswith("case "):
            continue                      # enum case 声明行
        _pre = _s_nc[: m.start()].rstrip()
        if _pre.endswith("."):
            continue                      # 方法调用 / 成员访问
        if fn in _STDLIB_WITH:
            continue
        if _relf in _system_files:
            continue                      # 系统符号（sigaction / utsname / ...）
        _ln = _s_nc[: m.start()].count("\n") + 1
        _bad_call.append("%s:%d %s()" % (_relf, _ln, fn))
check("裸函数调用都有定义（防「搬 UI 漏搬定义」）",
      not _bad_call,
      "疑似未定义: " + ", ".join(sorted(set(_bad_call))[:8]))

# ── 3. extension 内不得有存储属性（@AppStorage / @State / @StateObject）──────
_bad_ext = []
for _f in ALL:
    _relf = os.path.relpath(_f, ROOT)
    _s = read(_relf)
    for m in re.finditer(r"^extension\s+[^\n{]*\{", _s, re.M):
        i = m.end()
        d = 1
        j = i
        while j < len(_s) and d > 0:
            d += (_s[j] == "{") - (_s[j] == "}")
            j += 1
        body = _s[i : j - 1]
        for mm in re.finditer(
            r"@(AppStorage|State|StateObject|Environment|ObservedObject|StateObject)"
            r"\s*(\([^)]*\))?\s*(?:@[\w]+\s*)*(private\s+|fileprivate\s+|public\s+|internal\s+)?"
            r"(var|let)\s+\w+",
            body,
        ):
            _ln = _s[: i + mm.start()].count("\n") + 1
            _bad_ext.append("%s:%d @%s" % (_relf, _ln, mm.group(1)))
check("extension 内无存储属性（Archive: extensions must not contain stored properties）",
      not _bad_ext,
      "违规: " + ", ".join(_bad_ext[:8]))

# ── 4. 无默认值的 associated value：单行调用必须传全 ───────────────────────
_ex = read("qingliao/Core/AgentActionExecutor.swift")
_done_sig = re.search(r"case done\(message:\s*String,\s*undo:\s*\(\(\)\s*async\s*->\s*Void\)\?\)", _ex)
check("Outcome.done 的 undo 确为无默认值（所以单行调用必须用 doneNoUndo）",
      bool(_done_sig))
_bad_done = [
    i for i, l in enumerate(_ex.splitlines(), 1)
    if re.search(r"\.done\(message:.*\)\s*$", l) and not l.rstrip().endswith(",")
]
check("无「单行 .done 漏传 undo」写法", not _bad_done,
      "行 %s" % _bad_done if _bad_done else "")

# ── 5. 摸 @MainActor @Observable 单例的桥接类型必须标 @MainActor ────────────
_ts = read("qingliao/Features/Life/GoalsSection.swift")
check("GoalTodoBridge 标了 @MainActor", re.search(r"@MainActor\s*\n\s*enum GoalTodoBridge", _ts) is not None)

# ── 6. 静态存储属性不得用 property wrapper ─────────────────────────────────
_bad_static = []
for _f in ALL:
    _relf = os.path.relpath(_f, ROOT)
    _s = read(_relf)
    for m in re.finditer(r"@(AppStorage|State)\([^)]*\)\s*(private\s+)?static\s+var", _s):
        _ln = _s[: m.start()].count("\n") + 1
        _bad_static.append("%s:%d" % (_relf, _ln))
check("无 static @AppStorage/@State（属性包装器不适用于 static 存储属性）",
      not _bad_static,
      "违规: " + ", ".join(_bad_static[:6]))

# ── 7. 开关 key 全仓单一真源 ───────────────────────────────────────────────
_hap = read("qingliao/Core/Haptics.swift")
check("震动开关默认开（读不到 = 开，老用户行为不变）",
      re.search(r"as\? Bool\)\s*\?\? true", _hap) is not None)
check("Haptics 直读 UserDefaults（不再 static @AppStorage）",
      "UserDefaults.standard.object(forKey: enabledKey)" in _hap)

print("")
if fails:
    print("失败 %d 条 ❌" % len(fails))
    sys.exit(1)
print("全部通过：%d 项 ✅" % total)
sys.exit(0)
