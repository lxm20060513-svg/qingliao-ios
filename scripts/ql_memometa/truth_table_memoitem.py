#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第 4 项「记忆条目结构化」App 侧真值表 —— 从生产源码 MemoryEntry.swift / MemoryView 解析。

为什么不写镜像 Swift 逻辑：真值表的价值是**钉生产源码**。镜像一份实现等于自己骗自己。
所以本表真去读 qingliao/Features/Settings/MemoryEntry.swift 与 SettingsAgent.swift，断言：
  1) App 侧状态取值与后端 memory_store.STATUSES **逐字一致**（两边漂了就有一端显示空白胶囊）
  2) 状态标题/图标走**同一份** switch（不许两份各写一份）
  3) MemoryView 已不再依赖后端 entries 字段做列表渲染（回落只允许在 MemoryEntry.parse 里）
  4) 条目 id 用正文（后端 meta 以正文为键）—— 改成 UUID 会让 status 永远打不中
  5) 时间戳按**秒**解析且有毫秒兜底（真实事故：写成毫秒 → 2093 年）
  6) 解析失败/脏数据不许把整页清空（用户会以为"记忆全丢了"）

跑法：python3 truth_table_memoitem.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# 脚本在 <repo>/scripts/ql_memometa/，往上两级才是仓库根（原来写成三级 → 找错目录）
IOS = os.environ.get("QL_IOS_ROOT") or os.path.normpath(os.path.join(HERE, "..", ".."))
MEMO = os.path.join(IOS, "qingliao/Features/Settings/MemoryEntry.swift")
AGENT = os.path.join(IOS, "qingliao/Features/Settings/SettingsAgent.swift")

_res = []


def check(name, cond, extra=""):
    _res.append((name, bool(cond), extra))


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


for p in (MEMO, AGENT):
    if not os.path.exists(p):
        print("❌ 找不到生产源码：%s（用 QL_IOS_ROOT 指定仓库根）" % p)
        sys.exit(1)
memo = read(MEMO)
agent = read(AGENT)

# ── 1. App 侧状态取值 = 后端 STATUSES ──
st = re.search(r"static let allStatuses\s*=\s*\[([^\]]+)\]", memo)
check("MemoryEntry 声明了 allStatuses", st is not None)
listed = re.findall(r"status(Active|Pending|Stale)", st.group(1)) if st else []
check("App 三状态齐全 active/pending/stale",
      set(listed) == {"Active", "Pending", "Stale"}, str(listed))
for name in ("statusActive = \"active\"", "statusPending = \"pending\"", "statusStale = \"stale\""):
    check("字面量一致：%s" % name, name in memo)

# ── 2. 标题/图标只有一份 switch（实例版必须转发到静态版）──
check("statusTitle 实例版转发到静态版",
      "MemoryEntry.statusTitle(status)" in memo)
check("statusIcon 实例版转发到静态版",
      "MemoryEntry.statusIcon(status)" in memo)
check("存在静态 statusTitle(_:)",
      "static func statusTitle(_ s: String)" in memo)
check("存在静态 statusIcon(_:)",
      "static func statusIcon(_ s: String)" in memo)
# 反向：静态函数体里不得再写第二份实例版转发（会漂）。
# 判据只看**该函数自己的 switch**（按下一个函数声明切段），否则后面 statusColor 的
# normalizedStatus 会漏进来 → 上一版把合法代码误判成失败。
for fn, nxt in (("statusTitle", "static func statusIcon"),
                ("statusIcon", "var statusColor")):
    seg = memo.split("static func %s(_ s: String)" % fn, 1)
    check("%s 静态版存在" % fn, len(seg) == 2)
    if len(seg) == 2:
        body = seg[1].split(nxt, 1)[0]
        check("%s 静态版未嵌套实例版转发" % fn,
              "normalizedStatus" not in body, body[:120])

# ── 3. MemoryView 不再直接读后端 entries 字段 ──
check("MemoryView 已无 @State private var entries",
      "private var entries: [String]" not in agent)
check("MemoryView 改为 items: [MemoryEntry]", "private var items: [MemoryEntry]" in agent)
# 任何 `j["entries"] as? [String]` 都不该再出现在 SettingsAgent 里
check("不再直接解包后端 entries 字段",
      'j["entries"] as? [String]' not in agent)
# 空态判据必须跟着换
check("空态判据已改成 items.isEmpty", "if items.isEmpty {" in agent)
check("ForEach 用 Identifiable 的 items（不再 id: \\.self）",
      "ForEach(items)" in agent)

# ── 4. 条目 id = 正文（后端 meta 以正文为键）──
check("MemoryEntry.id 取正文", "var id: String { text }" in memo)

# ── 5. 时间戳按秒 + 毫秒兜底 ──
check("按 Unix 秒解析", "timeIntervalSince1970" in memo)
check("有毫秒兜底（1e12 阈值）", "1_000_000_000_000" in memo)
check("非正时间戳归 nil（不编假日期）", "v.doubleValue > 0" in memo)

# ── 6. 脏数据不许清空整页 ──
check("parse 优先 items", 'json["items"] as? [Any]' in memo)
check("parse 有 entries 兜底（灰度期不白屏）",
      'json["entries"] as? [String]' in memo)
check("MemoryEntry 提供 hasListField（区分『字段缺失』与『后端真的空了』）",
      "static func hasListField(_ json: [String: Any]) -> Bool" in memo)
check("hasListField 认 items 与 entries 两个字段",
      'json["items"] is [Any]' in memo and 'json["entries"] is [Any]' in memo)
check("load 里按字段在不在决定是否覆盖（后端真返回空列表必须清空）",
      "if parsed.isEmpty && !items.isEmpty && !MemoryEntry.hasListField(j) { return }" in agent)
# parse 返回非 Optional —— `if let p = ...` 是编译错（conditional binding must have Optional type）
# v4.0.15：旧写法 `if !p.isEmpty { items = p }` 判据是错的（删光最后一条时跳过赋值 → 看着删不掉），
# 已换成 hasListField；这里钉住新契约，并反向断言旧写法不再存在。
check("写操作一律用 hasListField 刷列表",
      agent.count("let p = MemoryEntry.parse(j)") == 0
      and agent.count("items = MemoryEntry.parse(j)") == 4)
check("旧写法 if !p.isEmpty 已从 SettingsAgent 清干净",
      "if !p.isEmpty { items = p }" not in agent)
check("不再用 if let 绑非 Optional 的 parse 结果",
      "if let p = MemoryEntry.parse(j)" not in agent)
check("parse 声明为非 Optional 数组",
      "static func parse(_ json: [String: Any]) -> [MemoryEntry]" in memo)
check("单条脏数据只跳过那一条（compactMap）", "compactMap { MemoryEntry.from($0) }" in memo)

# ── 7. 状态端点是独立端点（不复用 update 改正文）──
check("App 调 /api/memory/status", '"/api/memory/status"' in agent)
check("setStatus 失败时保持原状态并报错",
      "状态更新失败：请求失败" in agent)
check("同状态不打接口", "guard status != item.normalizedStatus" in agent)

# ── 8. stale 标灰但不清空（它仍会注入 prompt）──
check("isDimmed 只给 stale", 'normalizedStatus == Self.statusStale' in memo)
check("状态胶囊已渲染到列表", "MemoStatusChip(item: item)" in agent)
check("来源已渲染（仅 hasSource 时）", "if item.hasSource {" in agent)
check("日期已渲染（仅 displayDate 非空时）", "if let d = item.displayDate {" in agent)

# ── 9. 只用真令牌（不许发明 Typography.caption2）──
used = set(re.findall(r"Typography\.(\w+)", memo))
check("MemoryEntry 只用真存在的 Typography 令牌",
      "caption2" not in used and used <= {"caption"}, "用到 " + str(used))
used_r = set(re.findall(r"Radius\.(\w+)", memo))
check("Radius 令牌存在（chip）", used_r <= {"chip"}, str(used_r))
used_s = set(re.findall(r"Spacing\.(\w+)", memo))
check("Spacing 令牌存在（sm）", used_s <= {"sm"}, str(used_s))

# ── 输出 ──
ok = sum(1 for _, c, _ in _res if c)
for n, c, e in _res:
    print(("  ✅ " if c else "  ❌ ") + n + (("  → " + e) if (e and not c) else ""))
print("\n第 4 项 App 侧真值表：%d/%d 通过" % (ok, len(_res)))
if ok == len(_res):
    print("✅ ALL PASS")
sys.exit(0 if ok == len(_res) else 1)
